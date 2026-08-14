//
//  MaintainIncidentCoordinator.swift
//  leanring-buddy
//
//  The ladder that turns raw signals into (at most) one careful question.
//
//      L1  crash artifact arrives            (CrashArtifactWatcher, free)
//      L3  hang confirmed                    (HangProbe, near-free)
//      L5  signature + recipe cache lookup   (one HTTP GET, zero tokens)
//      L6  ask the user                      (rate-limited, mutable, honest)
//      —   on "yes": file to the pool        (the D2 filing)
//
//  The ask is the accuracy layer, not a courtesy. Vision-based bug detection
//  tops out near 50–72% precision in the published record; a detector that
//  acts on its own suspicion becomes a nag nobody trusts. So: crashes and
//  confirmed hangs may ask; nothing else in v1. One unsolicited ask per app
//  per 24 hours. "No, that was me" suppresses that signature for this
//  machine. "Don't ask about this app" is permanent and surfaced in
//  settings. No model call happens before a "yes" — there is no model call
//  in this file at all; Tier B/C fix work is downstream and BYO-gated.
//

import AppKit
import Combine
import Foundation

/// A question maintain mode wants to ask, rendered by the panel.
struct MaintainAsk: Identifiable, Equatable {
    let id: String
    let appSlug: String
    let appName: String
    /// One line of evidence, in the user's terms — never a stack trace.
    let evidenceSentence: String
    /// The signature behind the ask, carried through to filing on "yes".
    let signatureId: String
}

/// What the user answered. Every branch is recorded; a "no" is a labeled
/// negative worth exactly as much as a "yes".
enum MaintainAskAnswer {
    case somethingIsBroken
    case thatWasMe
    case neverAskAboutThisApp
}

@MainActor
final class MaintainIncidentCoordinator: ObservableObject {

    // MARK: - Published state (the panel reads these)

    @Published private(set) var pendingAsk: MaintainAsk?
    /// The recipes matched for the pending ask's signature, already ranked
    /// by the server. Empty until the lookup lands; shown after a "yes".
    @Published private(set) var recipesForPendingAsk: [PooledFixRecipe] = []

    /// The evidence sentence of the most recent confirmed break — the fix's
    /// human title for the commit, the PR, and the fix log.
    private(set) var lastConfirmedDiagnosisTitle: String?

    /// After a "yes": what the fix attempt is doing / did, for the card.
    /// One line, user-facing, honest ("Applying a known fix…", "Fixed and
    /// rebuilt — restart WhimprFlow to pick it up", "The known fix didn't
    /// apply to your version").
    @Published private(set) var fixStatusLine: String?
    /// Guidance-recipe steps to show after a "yes", when the known fix is
    /// instructions rather than a patch.
    @Published private(set) var fixGuidanceSteps: [String] = []

    // MARK: - Budget latch (mirrors GuideAutopilotRunner's shape)

    static let maximumIncidentsPerAppPerDay = 3
    static let minimumSecondsBetweenAsksPerApp: TimeInterval = 24 * 3600

    // MARK: - Collaborators

    private let poolClient: MaintainPoolClient
    private let provenanceStore: InstallProvenanceStore
    private let replayEngine: RecipeReplayEngine
    private let userDefaults: UserDefaults

    /// Answers "is this process one of ours" — CompanionManager adapts
    /// AppInventoryService into this.
    var catalogAppMatcher: ((_ processName: String, _ bundleIdentifier: String?) -> (slug: String, name: String, stack: BreakAppStack)?)?
    /// The installed version of a catalog app, for applicability ranges.
    var installedVersionLookup: ((_ appSlug: String) -> String?)?
    /// Backs a verified fix branch up to the user's fork. Returns the one-line
    /// summary to show, or nil when backup is unavailable/not connected —
    /// which is not an error; the fix is safe locally either way.
    var backUpFixBranch: ((_ branchName: String, _ appSlug: String) async -> String?)?
    /// Tier C: derive a novel fix under the user's own model key. Returns the
    /// branch name on success, or nil. Present only when a BYO/OpenAI key
    /// exists — its absence is the honest funded-tier ceiling.
    var attemptNovelFix: ((_ appSlug: String, _ stack: BreakAppStack, _ signatureId: String, _ evidence: String) async -> String?)?

    // MARK: - Persistence keys

    private static let mutedAppsKey = "iris:maintain:muted-apps"
    private static let suppressedSignaturesKey = "iris:maintain:suppressed-signatures"
    private static let askTimestampsKey = "iris:maintain:last-ask-by-app"
    private static let incidentCountsKey = "iris:maintain:incident-counts"

    private var mutedAppSlugs: Set<String>
    private var suppressedSignatureIds: Set<String>
    private var lastAskDateByAppSlug: [String: Date]
    /// "day-string|slug" → count, pruned to today on load.
    private var incidentCountsByDayAndApp: [String: Int]

    /// The signature objects behind pending/answered asks, kept out of the
    /// published struct so the UI layer never holds frame data.
    private var signaturesByAskId: [String: BreakSignature] = [:]
    private var appVersionsByAskId: [String: String] = [:]
    /// The frozen, scrubbed crash evidence per ask — Tier C's only bug
    /// description. The proto signature is already normalized and PII-free.
    private var evidenceByAskId: [String: String] = [:]

    init(
        poolClient: MaintainPoolClient,
        provenanceStore: InstallProvenanceStore,
        replayEngine: RecipeReplayEngine,
        userDefaults: UserDefaults = .standard
    ) {
        self.poolClient = poolClient
        self.provenanceStore = provenanceStore
        self.replayEngine = replayEngine
        self.userDefaults = userDefaults
        mutedAppSlugs = Set(userDefaults.stringArray(forKey: Self.mutedAppsKey) ?? [])
        suppressedSignatureIds = Set(userDefaults.stringArray(forKey: Self.suppressedSignaturesKey) ?? [])
        lastAskDateByAppSlug = (userDefaults.dictionary(forKey: Self.askTimestampsKey) as? [String: Date]) ?? [:]
        incidentCountsByDayAndApp = (userDefaults.dictionary(forKey: Self.incidentCountsKey) as? [String: Int]) ?? [:]
    }

    // MARK: - Signal entry points

    /// A crash artifact for one of ours. The only path that may ask
    /// immediately — a crash is unambiguous evidence something ended wrong.
    func handleCrashArtifact(_ artifact: DetectedCrashArtifact) {
        let signature = BreakSignatureService.nativeCrashSignature(
            fromParsedReport: artifact.report,
            appSlug: artifact.catalogAppSlug,
            appStack: artifact.catalogAppStack
        )
        considerAsking(
            signature: signature,
            appSlug: artifact.catalogAppSlug,
            appName: artifact.report.appName,
            appVersion: artifact.report.appVersion,
            evidenceSentence: "\(artifact.report.appName) quit unexpectedly a moment ago.",
            // Tier C's bug description: the exception, the walked frames, and
            // the pre-hash composite — all normalized and PII-free already.
            frozenEvidence: Self.evidence(from: signature, report: artifact.report)
        )
    }

    private static func evidence(from signature: BreakSignature, report: ParsedCrashReport) -> String {
        var lines = ["Exception: \(report.exceptionType ?? "unknown") \(report.exceptionSignal ?? "")"]
        lines.append("Signature: \(signature.protoSignature)")
        for frame in signature.topFrames {
            lines.append("  at \(frame.module)!\(frame.function)\(frame.sourceFile.map { " (\($0))" } ?? "")")
        }
        return lines.joined(separator: "\n")
    }

    /// A hang that recovered or ended — asked about after the fact, never
    /// mid-hang. The probe's gating already required N consecutive failures.
    func handleConfirmedHang(appSlug: String, appName: String, appStack: BreakAppStack, unresponsiveSeconds: Int) {
        let signature = BreakSignatureService.hangSignature(
            appSlug: appSlug, appStack: appStack, blockedTopFrame: nil
        )
        considerAsking(
            signature: signature,
            appSlug: appSlug,
            appName: appName,
            appVersion: nil,
            evidenceSentence: "\(appName) stopped responding for about \(unresponsiveSeconds) seconds.",
            // A hang has no stack to hand Tier C; the pool/replay path is
            // where a hang gets fixed, not novel derivation.
            frozenEvidence: "Hang: \(signature.protoSignature) (unresponsive ~\(unresponsiveSeconds)s)"
        )
    }

    // MARK: - The ask gate

    private func considerAsking(
        signature: BreakSignature,
        appSlug: String,
        appName: String,
        appVersion: String?,
        evidenceSentence: String,
        frozenEvidence: String
    ) {
        guard pendingAsk == nil else {
            irisTrace("maintain: ask suppressed (one already pending)")
            return
        }
        guard !mutedAppSlugs.contains(appSlug) else {
            irisTrace("maintain: ask suppressed (\(appSlug) muted)")
            return
        }
        guard !suppressedSignatureIds.contains(signature.signatureId) else {
            irisTrace("maintain: ask suppressed (signature marked benign by the user)")
            return
        }
        if let lastAsk = lastAskDateByAppSlug[appSlug],
           Date().timeIntervalSince(lastAsk) < Self.minimumSecondsBetweenAsksPerApp {
            irisTrace("maintain: ask suppressed (\(appSlug) asked within 24h)")
            return
        }
        let dayKey = Self.dayKey(forAppSlug: appSlug)
        if incidentCountsByDayAndApp[dayKey, default: 0] >= Self.maximumIncidentsPerAppPerDay {
            irisTrace("maintain: ask suppressed (\(appSlug) at daily incident cap)")
            return
        }

        incidentCountsByDayAndApp[dayKey, default: 0] += 1
        lastAskDateByAppSlug[appSlug] = Date()
        persistCounters()

        let ask = MaintainAsk(
            id: UUID().uuidString,
            appSlug: appSlug,
            appName: appName,
            evidenceSentence: evidenceSentence,
            signatureId: signature.signatureId
        )
        signaturesByAskId[ask.id] = signature
        if let appVersion { appVersionsByAskId[ask.id] = appVersion }
        evidenceByAskId[ask.id] = frozenEvidence
        pendingAsk = ask
        irisTrace("maintain: ASK raised for \(appSlug) (\(signature.kind.rawValue) \(signature.signatureId))")

        // The cache lookup starts now (zero tokens, one GET) so a "yes" can
        // show a known fix immediately instead of a spinner.
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.poolClient.lookupRecipes(for: signature)
            guard self.pendingAsk?.id == ask.id else { return }
            self.recipesForPendingAsk = answer.recipes
            if let matched = answer.matchedBy {
                irisTrace("maintain: cache HIT via \(matched) — \(answer.recipes.count) recipe(s)")
            }
        }
    }

    // MARK: - Answers

    func answerPendingAsk(_ answer: MaintainAskAnswer) {
        guard let ask = pendingAsk else { return }
        let signature = signaturesByAskId[ask.id]
        pendingAsk = nil
        signaturesByAskId[ask.id] = nil
        let appVersion = appVersionsByAskId.removeValue(forKey: ask.id)

        switch answer {
        case .somethingIsBroken:
            irisTrace("maintain: user CONFIRMED break for \(ask.appSlug)")
            lastConfirmedDiagnosisTitle = ask.evidenceSentence
            guard let signature else { return }
            let bestRecipe = recipesForPendingAsk.first
            // The D2 filing: consent was collected at signup; a confirmed
            // break files without a second prompt. Publishing a FIX under
            // the user's name stays a separate explicit ask downstream.
            Task { [weak self] in
                guard let self else { return }
                let breakId = await self.poolClient.fileConfirmedBreak(ConfirmedBreakFiling(
                    signature: signature,
                    title: ask.evidenceSentence,
                    appVersion: appVersion
                ))
                irisTrace("maintain: filed break → \(breakId ?? "FAILED, staged for retry")")
            }
            // Tier A/B: a pooled recipe exists — replay or adapt it. No
            // recipe → Tier C if the user brought a model key and this is a
            // patchable source clone; otherwise the honest funded-tier dead
            // end ("filed; a pooled fix will reach you when one exists").
            if let bestRecipe {
                runReplay(recipe: bestRecipe, ask: ask, signature: signature, appVersion: appVersion)
            } else if let attemptNovelFix,
                      provenanceStore.localPatchingIsPermitted(forAppSlug: ask.appSlug) {
                runNovelFix(ask: ask, signature: signature)
            } else {
                fixStatusLine = "Filed. No known fix yet — when one lands in the pool, Iris will offer it."
            }

        case .thatWasMe:
            // A labeled negative: this signature is benign on this machine
            // (an app that exits non-zero on quit, a kill the user meant).
            if let signature {
                suppressedSignatureIds.insert(signature.signatureId)
                persistCounters()
            }
            irisTrace("maintain: user said benign — signature suppressed")

        case .neverAskAboutThisApp:
            mutedAppSlugs.insert(ask.appSlug)
            persistCounters()
            irisTrace("maintain: \(ask.appSlug) permanently muted by the user")
        }
        recipesForPendingAsk = []
    }

    /// The Tier-A replay, narrated honestly to the card at each stage.
    private func runReplay(
        recipe: PooledFixRecipe, ask: MaintainAsk, signature: BreakSignature, appVersion: String?
    ) {
        fixStatusLine = "Applying a known fix…"
        Task { [weak self] in
            guard let self else { return }
            let result = await self.replayEngine.replay(
                recipe: recipe,
                appSlug: ask.appSlug,
                appStack: signature.appStack,
                installedAppVersion: appVersion ?? self.installedVersionLookup?(ask.appSlug),
                signatureId: signature.signatureId
            )
            switch result {
            case .guidanceToShow(let steps):
                self.fixStatusLine = "A known fix exists — here's what to do:"
                self.fixGuidanceSteps = steps
            case .patchAppliedAndVerified(let branchName):
                self.fixStatusLine =
                    "Fixed and rebuilt (branch \(branchName)). Relaunch \(ask.appName) to pick it up."
                // The fork backup rides behind the fix, silently once
                // connected. Its absence never dims the fix itself.
                if let backUpFixBranch = self.backUpFixBranch,
                   let summary = await backUpFixBranch(branchName, ask.appSlug) {
                    self.fixStatusLine = (self.fixStatusLine ?? "") + " \(summary)."
                }
            case .patchRevertedAfterFailedVerification(let blockedStage):
                self.fixStatusLine =
                    "The known fix applied but failed verification (\(blockedStage)) — reverted, nothing changed."
            case .patchDidNotApply:
                self.fixStatusLine = "The known fix doesn't fit your version. Filed, so a refreshed fix can pool."
            case .patchingNotPermittedForThisInstall:
                self.fixStatusLine = "A code fix exists, but this install isn't a source build Iris may patch."
            case .outsideApplicabilityRange:
                self.fixStatusLine = "A fix exists for other versions, but not yours yet. Filed."
            }
        }
    }

    /// Tier C: no pooled recipe fit, but the user has a model key and this is
    /// a source clone. Derive a fix from scratch, jailed and bounded, then
    /// through the same verification gate. Filing already happened.
    private func runNovelFix(ask: MaintainAsk, signature: BreakSignature) {
        guard let attemptNovelFix else { return }
        let evidence = evidenceByAskId[ask.id] ?? signature.protoSignature
        fixStatusLine = "No known fix — Iris is trying to work one out under your model key…"
        Task { [weak self] in
            guard let self else { return }
            let branchName = await attemptNovelFix(
                ask.appSlug, signature.appStack, signature.signatureId, evidence
            )
            self.evidenceByAskId[ask.id] = nil
            if let branchName {
                self.fixStatusLine =
                    "Worked out a fix and verified it (branch \(branchName)). Relaunch \(ask.appName) to pick it up."
                if let backUpFixBranch = self.backUpFixBranch,
                   let summary = await backUpFixBranch(branchName, ask.appSlug) {
                    self.fixStatusLine = (self.fixStatusLine ?? "") + " \(summary)."
                }
            } else {
                self.fixStatusLine =
                    "Iris couldn't work out a fix this time. It's filed, so a pooled fix can still reach you."
            }
        }
    }

    /// The card's dismiss for the post-answer status.
    func clearFixStatus() {
        fixStatusLine = nil
        fixGuidanceSteps = []
    }

    /// Settings surface: the mute list, readable and reversible.
    var mutedApps: [String] { mutedAppSlugs.sorted() }

    func unmuteApp(_ appSlug: String) {
        mutedAppSlugs.remove(appSlug)
        persistCounters()
    }

    // MARK: - Persistence

    private func persistCounters() {
        userDefaults.set(Array(mutedAppSlugs), forKey: Self.mutedAppsKey)
        userDefaults.set(Array(suppressedSignatureIds), forKey: Self.suppressedSignaturesKey)
        userDefaults.set(lastAskDateByAppSlug, forKey: Self.askTimestampsKey)
        // Prune to today so the dictionary cannot grow a key per app per day
        // forever.
        let today = Self.todayString()
        incidentCountsByDayAndApp = incidentCountsByDayAndApp.filter { $0.key.hasPrefix(today) }
        userDefaults.set(incidentCountsByDayAndApp, forKey: Self.incidentCountsKey)
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private static func dayKey(forAppSlug appSlug: String) -> String {
        "\(todayString())|\(appSlug)"
    }
}
