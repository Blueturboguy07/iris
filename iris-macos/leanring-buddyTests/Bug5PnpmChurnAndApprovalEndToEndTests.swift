//
//  Bug5PnpmChurnAndApprovalEndToEndTests.swift
//  leanring-buddyTests
//
//  THE WHOLE CYCLE, driven the way the reader drove it. Bug 5 is two defects
//  that feed each other, and `Bug5PnpmChurnAndApprovalReproTests` pins each one
//  against the piece that owns it — the composed build command, and
//  `OnDemandEditDirtyTreeReport`. Neither of those, on its own, is what Akrit
//  did. What he did was tap "fix this", and this file is that tap:
//
//      pick the app → describe the change → approve the plan → start
//        → the preflight gate reads `git status --porcelain`
//        → the jailed edit loop writes real code into the clone
//        → the un-jailed verification build runs the command Iris composed
//        → the change is committed on an `iris/edit-…` branch
//        → the card says "Applied on branch …"
//        → and what the finished run leaves behind does not refuse the next one.
//
//  Everything above is production code. The ONLY thing faked is the model
//  transport: a `MaintainModelProviding` that replays two turns instead of
//  reaching a network. The coordinator and its gates, `MaintainTierCFixer`, the
//  Seatbelt jail, `MaintainShellRunner`, `RepoRecipeService`,
//  `VerificationHarness`, git, pnpm, esbuild and cargo are all real, and the
//  repository is a real one on disk.
//
//  WHY THIS EXISTS SEPARATELY FROM THE REPRO. The repro proves the two rules.
//  It cannot prove they COMPOSE: that a run which is no longer refused reaches
//  a build that now works; that the build actually COMPILED the change rather
//  than merely exiting 0; and that what the finished run leaves behind does not
//  refuse the run after it. Each of those is a seam between the two halves, and
//  a seam is where a fix to one half quietly fails the other. Measured against
//  the pre-fix tree (0f421ba) the first test below fails at the gate, before the
//  engine is entered; had only the gate been fixed it would fail at the build
//  instead, with `ui/dist/main.js` never written.
//
//  It is deliberately self-contained — its own fixture, its own driver — so it
//  can be compiled and run alone, which is what a regression guard is asked to
//  do at the moment somebody suspects a regression.
//

import Foundation
import Testing

// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

/// Serialized: every test here stands up a real git repository, spawns real
/// pnpm and cargo through a login shell, and drives the real Seatbelt jail.
@MainActor
@Suite(.serialized)
struct Bug5PnpmChurnAndApprovalEndToEndTests {

    /// THE CYCLE, closed. The clone starts the way his did: a rebuild he ran
    /// himself failed and left a file behind that he never typed.
    ///
    /// Four things have to be true, in this order, and each is a different part
    /// of the bug:
    ///
    ///   1. the run STARTS (half 2 — the gate no longer reads what a package
    ///      manager wrote for itself as the reader's work);
    ///   2. the change LANDS: the verification build passes on this clone
    ///      (half 1 — the composed command now carries its own build approval)
    ///      and is committed on a branch the card names;
    ///   3. the build actually COMPILED the change — `ui/dist/main.js`, which
    ///      esbuild writes only if pnpm let the install finish. This is exactly
    ///      what his run never reached: pnpm died inside an install it started
    ///      for itself, and he was told his change did not build;
    ///   4. and the loop is over rather than paused: the reader's own rebuild —
    ///      the command that failed on this same clone before the tap — passes
    ///      now, and leaves nothing the next tap would be refused over.
    @Test func theReaderTapsFixOverTheDirtHisOwnRebuildLeftAndTheChangeLandsInsteadOfLooping() async throws {
        let clone = try Bug5EndToEndWhimprflowClone.make()
        defer { clone.remove() }
        guard try await clone.theToolchainThisGuardNeedsIsReachable() else { return }

        // The state he found the clone in — not written by hand. The project's
        // OWN frontend hook is run un-wrapped, the way everything outside
        // Iris's composed command runs it, and it fails the way it failed for
        // him, leaving a file behind that he never typed.
        let hisOwnRebuildFailed = await clone.dirtyTheCloneTheWayHisOwnRebuildDid()
        #expect(
            hisOwnRebuildFailed,
            """
            the project's own hook did not fail on this fixture, so this Mac is \
            not reproducing the condition the reader was in and nothing below \
            means what it says
            """
        )
        let porcelainBeforeTheTap = try await clone.rawPorcelainTheGateReads()
        #expect(
            porcelainBeforeTheTap.isEmpty == false,
            """
            the fixture never got dirty, so nothing below is proving anything. \
            Read through git itself, not through the report under test — the \
            report's whole job here is to look past this dirt, so asking IT \
            whether the fixture worked would always answer no.
            """
        )

        let readerSession = Bug5EndToEndReaderSession(clone: clone)
        await readerSession.tapFixAndWaitForTheRunToEnd(request: "make the hotkey configurable")

        // 1. Started. Asserted apart from the outcome because "refused at the
        //    gate" and "the run failed" read identically in a phase dump, and
        //    they are opposite diagnoses.
        #expect(
            readerSession.wasTurnedAwayAtTheDirtyTreeGate == false,
            """
            Iris refused to start over \(porcelainBeforeTheTap.trimmingCharacters(in: .whitespacesAndNewlines)) \
            — written by a tool Iris ran, not by the reader. It said: \
            \(readerSession.terminalFailureReason ?? "(no reason recorded)")
            """
        )
        #expect(
            readerSession.theEngineWasEntered,
            "the edit the reader asked for never ran — \(readerSession.phaseDescription)"
        )

        // 2. The change landed: verification green, committed on a branch, and
        //    the card says so in the words the reader reads.
        #expect(
            readerSession.appliedBranchName != nil,
            """
            the run did not end in an applied change. Phase: \(readerSession.phaseDescription).
            What the reader watched:
            \(readerSession.terminalTranscriptForDiagnostics)
            """
        )
        #expect(
            readerSession.statusLine?.contains("Applied on branch") == true,
            "the card never told the reader the change was applied; it said: \(readerSession.statusLine ?? "(nothing)")"
        )

        // 3. The build compiled the change, rather than some command exiting 0.
        //    esbuild writes this file only once pnpm let the install finish.
        #expect(
            clone.builtFrontendBundleContents.contains(
                Bug5EndToEndScriptedEditModel.markerTheModelWritesIntoTheFrontendEntryPoint
            ),
            """
            the verification build never compiled the edit — ui/dist/main.js does \
            not carry it. That is the failure the reader was shown as "your change \
            doesn't build". The bundle holds: \
            \(clone.builtFrontendBundleContents.isEmpty ? "(no bundle at all)" : clone.builtFrontendBundleContents)
            """
        )

        // 4. The loop is OVER, not paused. The reader's own rebuild is run again
        //    — the identical un-wrapped hook that failed at the top of this test
        //    — and it passes now, because the run left his dependency tree
        //    installed and its lockfile committed rather than lying dirty in the
        //    way of the next tap. That is the difference between fixing the run
        //    and fixing the cycle: on his machine every rebuild re-armed the
        //    refusal that stopped the run after it.
        let theSameRebuildAfterTheRun = await clone.runTheProjectsOwnHookTheWayEverythingOutsideIrisRunsIt()
        #expect(
            theSameRebuildAfterTheRun?.succeeded == true,
            """
            the reader's own rebuild still fails after Iris's run, so the next \
            one walks back into 11:49:33. It said: \
            \(Bug5EndToEndWhimprflowClone.lastLines(ofOutput: theSameRebuildAfterTheRun?.outputTail ?? "", count: 8))
            """
        )
        let porcelainAfterTheRun = try await clone.rawPorcelainTheGateReads()
        let dirtTheGateWouldRefuseOver = try await clone.dirtyPathsTheGateWouldSee()
        #expect(
            dirtTheGateWouldRefuseOver.isEmpty,
            """
            the next run stops before touching anything: the clone has uncommitted \
            changes (\(dirtTheGateWouldRefuseOver)) — which is 11:49:33 all over again. \
            git's own answer was: \(porcelainAfterTheRun.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        )
    }

    /// THE GUARD RAIL, through the reader's own surface rather than through the
    /// report type. The repro asserts this rule against
    /// `OnDemandEditDirtyTreeReport`; this asserts what the reader is SHOWN,
    /// which is the part that must not regress: their own uncommitted work
    /// still stops the run, the refusal still names the file, and the "Set aside
    /// and continue" offer is still published so the card can render it in the
    /// same frame as the refusal.
    ///
    /// The gate exists because the engine reverts with `git clean -fd`. Making
    /// the assertions above pass by simply not refusing any more would hand that
    /// command a reader's uncommitted work, and this is what stands in the way.
    @Test func aReadersOwnEditToTheSameWorkspaceFileStillStopsTheRunAndOffersToSetItAside() async throws {
        let clone = try Bug5EndToEndWhimprflowClone.make()
        defer { clone.remove() }

        // Not pnpm's approval keys — the reader's own package globs, in the very
        // file pnpm also writes to, which is the case a basename allowlist would
        // wave away.
        clone.append(toFile: "ui/pnpm-workspace.yaml", "  - 'packages/*'\n")

        let readerSession = Bug5EndToEndReaderSession(clone: clone)
        await readerSession.tapFixAndWaitForTheRunToEnd(request: "make the hotkey configurable")

        #expect(
            readerSession.wasTurnedAwayAtTheDirtyTreeGate,
            """
            a reader's own uncommitted edit no longer stops the run, so the \
            engine's `git clean -fd` would have deleted it. Phase: \(readerSession.phaseDescription)
            """
        )
        #expect(
            readerSession.theEngineWasEntered == false,
            "the engine ran over the reader's uncommitted work"
        )
        #expect(
            readerSession.terminalFailureReason?.contains("ui/pnpm-workspace.yaml") == true,
            """
            the refusal did not name the file it was about, which is the whole \
            reason Test 7's reader answered "i made no changes this doesn't make \
            sense". It said: \(readerSession.terminalFailureReason ?? "(nothing)")
            """
        )
        #expect(
            readerSession.setAsideOfferWasPublished,
            "the reader was refused with no way forward — the Set aside offer never reached the card"
        )
    }
}

// MARK: - The model, and only the model, is faked

/// Replays a fixed pair of turns — one real edit, then DONE — and clears the
/// independent review. It never reaches a network, and it is the ONLY seam in
/// this file that is not production code.
///
/// It answers by ROLE rather than by call count, because the on-demand engine
/// makes two different kinds of call: the edit loop's turns, and one
/// fresh-context adversarial review (L6) whose reply obeys a different
/// protocol. Counting calls would silently feed the reviewer a bash block the
/// moment the loop's step count changed.
@MainActor
final class Bug5EndToEndScriptedEditModel: MaintainModelProviding {
    let displayName = "scripted-edit-model (end-to-end guard)"
    let identifier = "test-provider-bug5-end-to-end"
    let isAvailable = true

    /// Written into the frontend's bundle ENTRY POINT, so esbuild must actually
    /// have run for it to appear in `ui/dist/main.js`. That file is the only
    /// evidence separating "the build command exited 0" from "the build
    /// compiled the change" — and the second is what Bug 5 destroyed.
    static let markerTheModelWritesIntoTheFrontendEntryPoint = "hotkeyIsConfigurable"

    /// One command, one DONE. Deliberately the smallest possible real change:
    /// anything larger would give the diff-scope gate and the cheat-signature
    /// scan opinions of their own, and this guard is not about them.
    private let turnsOfTheEditLoop = [
        """
        Adding the setting to the frontend entry point.

        ```bash
        printf 'export const main = 1\\nexport const \(markerTheModelWritesIntoTheFrontendEntryPoint) = true\\n' > ui/src/main.js
        ```
        """,
        "The change is in place.\nDONE",
    ]
    private var nextEditLoopTurnIndex = 0

    func respond(
        systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
    ) async throws -> String {
        // The adversarial reviewer is a separate role in a fresh context, and
        // its system prompt is the one that teaches the VERDICT protocol. It
        // only reports (it never blocks), so a clean verdict keeps the run's
        // evidence ladder honest without deciding anything asserted here.
        if systemPrompt.contains(FeatureEditAdversarialReviewer.verdictLineMarker) {
            return "\(FeatureEditAdversarialReviewer.verdictLineMarker) "
                + FeatureEditAdversarialReviewer.cleanVerdictToken
        }
        defer { nextEditLoopTurnIndex += 1 }
        return nextEditLoopTurnIndex < turnsOfTheEditLoop.count
            ? turnsOfTheEditLoop[nextEditLoopTurnIndex]
            : "DONE"
    }
}

// MARK: - The reader's session, driven through the real coordinator

/// One reader, one tap: pick the app, describe the change, approve the plan,
/// start, and wait for the run to end. Every gate along the way is the real one
/// — the coordinator is built with production defaults except for the two seams
/// it already exposes for exactly this:
///
///   • `probeRequestTriggers`, the pre-edit clarification probe, which is a
///     MODEL call and is answered all-quiet here (its own fail-open watchdog
///     does the same when a network stalls);
///   • `performOnDemandEdit`, wired to the SAME `MaintainTierCFixer` call
///     production wires it to, with the scripted provider standing in for the
///     reader's resolved one.
///
/// The delivery closures (`packageEditedAppFromClone`,
/// `terminateAndRelaunchEditedApp`) are left nil, which is a supported
/// production state: a successful run then ends at `.done` having committed the
/// branch, without packaging or relaunching anything. That matters here — this
/// Mac's Iris is running and must not be rebuilt or replaced by a test.
@MainActor
final class Bug5EndToEndReaderSession {

    let coordinator: OnDemandEditCoordinator
    private let engineEntry = Bug5EndToEndEngineEntryFlag()

    /// True once the jailed edit loop was actually entered — the difference
    /// between "Iris refused" and "Iris tried".
    var theEngineWasEntered: Bool { engineEntry.wasEntered }

    init(clone: Bug5EndToEndWhimprflowClone) {
        // A private defaults suite per session, so one session's provenance
        // cannot leak into another's — or into the Iris running on this Mac.
        let installProvenanceStore = InstallProvenanceStore(
            userDefaults: UserDefaults(suiteName: "iris.bug5.e2e.\(UUID().uuidString)")!
        )
        installProvenanceStore.recordGuideSourceClone(
            appSlug: Bug5EndToEndWhimprflowClone.appSlug,
            clonePath: clone.path,
            pinnedCommit: nil,
            canonicalRepo: nil
        )
        let scriptedEditModel = Bug5EndToEndScriptedEditModel()
        let engineEntry = self.engineEntry
        self.coordinator = OnDemandEditCoordinator(
            installProvenanceStore: installProvenanceStore,
            patchQueue: PatchQueue(
                baseDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("iris-bug5-e2e-\(UUID().uuidString)")
            ),
            // Never `.shared`: a lock held by this Mac's real Iris, or by a
            // sibling test, would refuse the run for a reason with nothing to
            // do with Bug 5.
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: {
                resolvedClonePath, appSlug, appStack, changeId, scrubbedRequest, kind,
                progressHandler, cancellationCheck, runtimeEvidence,
                additionalPromptSections, manifestChangeApproval in
                engineEntry.markEntered()
                // What `defaultPerformOnDemandEdit` does, minus the provider
                // resolution — so the recipe derivation, the verification
                // commands, the repair rounds and the independent review are all
                // the production ones.
                let fixer = MaintainTierCFixer(provider: scriptedEditModel)
                return await fixer.attemptOnDemandEdit(
                    clonePath: resolvedClonePath,
                    appSlug: appSlug,
                    appStack: appStack,
                    changeId: changeId,
                    request: scrubbedRequest,
                    kind: kind,
                    progressHandler: progressHandler,
                    cancellationCheck: cancellationCheck,
                    runtimeLogContext: runtimeEvidence.runtimeLogText,
                    appWindowScreenshotPNG: runtimeEvidence.appWindowScreenshotPNG,
                    additionalPromptSections: additionalPromptSections,
                    manifestChangeApproval: manifestChangeApproval
                )
            }
        )
    }

    // MARK: What the reader ends up looking at

    var phaseDescription: String { String(describing: coordinator.phase) }
    var statusLine: String? { coordinator.statusLine }

    var terminalFailureReason: String? {
        switch coordinator.phase {
        case .failed(let reason), .notEligible(let reason): return reason
        default: return nil
        }
    }

    /// The dirty-tree refusal specifically, told apart from every other way a
    /// run can end badly by the phrase that refusal — and only that refusal —
    /// opens with (`OnDemandEditDirtyTreeReport.refusalSentence`).
    var wasTurnedAwayAtTheDirtyTreeGate: Bool {
        terminalFailureReason?.contains("stopped before touching anything") == true
    }

    /// Published the frame before the refusal lands, so the card can offer "Set
    /// aside and continue" alongside it.
    var setAsideOfferWasPublished: Bool { coordinator.dirtyCloneRefusal != nil }

    /// The branch the change was committed on, or nil when the run did not end
    /// in an applied change.
    var appliedBranchName: String? {
        guard case .appliedAndRebuilt(let branchName, _, _, _, _) = coordinator.lastResult else {
            return nil
        }
        return branchName
    }

    /// The run as the reader watched it, so a failure here can be diagnosed
    /// without re-running anything.
    var terminalTranscriptForDiagnostics: String {
        coordinator.editRunner.transcript.map { entry in
            switch entry {
            case .stepHeading(let stepTitle, _, _): return "== \(stepTitle)"
            case .commandFromTheGuide(let text): return "$ \(text)"
            case .commandFromAFix(let text, _, _, _): return "$ \(text)"
            case .output(let line): return "   \(line)"
            case .exitStatus(let code, _): return "   exit \(code)"
            case .awaitingConfirmation(let request): return "   ? \(request.commandText)"
            case .explanation(let text): return " . \(text)"
            }
        }.joined(separator: "\n")
    }

    // MARK: The tap

    /// Pick → describe → (clarify) → approve the plan → start, then wait for a
    /// terminal phase. Mirrors the order the card walks the reader through;
    /// nothing here reaches around the coordinator's own steps.
    func tapFixAndWaitForTheRunToEnd(request: String) async {
        coordinator.pickApp(
            slug: Bug5EndToEndWhimprflowClone.appSlug,
            name: Bug5EndToEndWhimprflowClone.appName,
            stack: .tauri
        )
        guard coordinator.phase == .describe else {
            // Loud rather than silent. The eligibility gate needs a connected
            // model provider and an available sandbox, neither of which is
            // stubbable — and a guard that goes green because the machine could
            // not reach the code is worse than no guard.
            Issue.record("the app was not eligible to edit: \(phaseDescription)")
            return
        }

        // A FEATURE, not a bug fix: a bug fix asks the model for a repro command
        // and runs three extra legs around it, which is a different subject and
        // would make this guard an oracle for it.
        coordinator.describeRequest(request, kind: .feature)
        _ = await Bug5EndToEndWait.until(timeout: 30) {
            self.coordinator.phase == .presentingPlan || self.coordinator.phase == .clarifying
        }

        // The clarification batch is code-authored, so answering it the way a
        // reader would — the first option that is not "Stop" — is a
        // deterministic choice rather than a guess.
        if coordinator.phase == .clarifying {
            var answersByQuestionId: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                answersByQuestionId[question.id] =
                    question.options.first { !$0.lowercased().hasPrefix("stop") }
                    ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answersByQuestionId)
        }
        _ = await Bug5EndToEndWait.until(timeout: 30) {
            self.coordinator.phase == .presentingPlan
        }
        guard coordinator.phase == .presentingPlan else {
            Issue.record("the plan was never presented, so there was nothing to approve: \(phaseDescription)")
            return
        }

        coordinator.confirmPlanAndStart()
        // Generous, because this wait covers a real pnpm install, a real esbuild
        // bundle and a real cargo release build. Measured at a few seconds on
        // this Mac with a warm pnpm store and a warm cargo registry; the ceiling
        // is for cold ones.
        let reachedAnEnding = await Bug5EndToEndWait.until(timeout: 600) {
            self.runHasReachedATerminalPhase
        }
        if !reachedAnEnding {
            Issue.record("the run never finished — it is still \(phaseDescription)")
        }
    }

    /// Every phase a run can come to rest in. `.done` covers both endings a
    /// finished run has: applied, and stopped by the reader.
    private var runHasReachedATerminalPhase: Bool {
        switch coordinator.phase {
        case .done, .failed, .notEligible, .blockedByModel, .awaitingMachineCommandConsent:
            return true
        default:
            return false
        }
    }
}

/// Records whether the engine seam was entered. A class, so the performer
/// closure and the test can share one answer across concurrency domains.
final class Bug5EndToEndEngineEntryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    func markEntered() {
        lock.lock()
        entered = true
        lock.unlock()
    }
    var wasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }
}

// MARK: - The repository, real and on disk

/// A real git repository shaped like WhimprFlow — a Rust crate under
/// `src-tauri/`, the frontend and its `build` script under `ui/` — living under
/// $HOME because `GitInspectionService.allowedRepositoryPath` refuses anything
/// outside it, and named so no path component reads as Iris's own source tree
/// (which the coordinator refuses structurally).
@MainActor
struct Bug5EndToEndWhimprflowClone {

    let path: String
    let runner: MaintainShellRunner

    /// Deliberately NOT the real "whimprflow" slug. The engine injects a
    /// per-app memory of earlier runs by slug, from a store shared with the
    /// Iris running on this Mac, so borrowing the real slug would both feed this
    /// guard a stranger's history and write this guard's runs into it.
    static let appSlug = "whimprflow-bug5-guard"
    static let appName = "whimprflow"

    /// Pinned through `ui/package.json`'s `packageManager` field, for reasons
    /// that had to be measured rather than assumed:
    ///
    ///   • this Mac's default pnpm is 10.0.0, whose ignored-build handling is a
    ///     WARNING that exits 0 — a fixture that let the machine's own pnpm
    ///     decide would go green while proving nothing;
    ///   • pnpm 11, whose defaults match his log exactly, cannot run through
    ///     `MaintainShellRunner` at all: `/bin/zsh -l` resolves `node` to this
    ///     Mac's v21.5.0, which pnpm 11 dies on before reading a config file.
    ///
    /// 10.30.0 runs on that node and enforces the gate this bug is about: its
    /// dependency-status check spawns its own `pnpm install` before the script,
    /// and that install hard-fails on an unreviewed build script.
    static let pinnedPnpmVersion = "10.30.0"

    static func make() throws -> Bug5EndToEndWhimprflowClone {
        let containingDirectory = NSHomeDirectory() + "/.iris-bug5-e2e-clones/\(UUID().uuidString)"
        let clonePath = containingDirectory + "/whimprflow"
        let fileManager = FileManager.default
        for subdirectory in ["src-tauri/src", "ui/src"] {
            try fileManager.createDirectory(
                atPath: clonePath + "/" + subdirectory, withIntermediateDirectories: true
            )
        }
        let clone = Bug5EndToEndWhimprflowClone(
            path: clonePath, runner: try MaintainShellRunner(repoRootPath: clonePath)
        )

        // Ignored the way a real project ignores them, so the dirt a build
        // leaves is the bookkeeping this bug is about and not a node_modules
        // tree nobody would ever count as the reader's work.
        clone.write(".gitignore", "node_modules/\ntarget/\ndist/\n")

        // The Tauri config carrying the frontend hook the detector lifts.
        clone.write("src-tauri/tauri.conf.json", """
        {
          "build": {
            "beforeBuildCommand": "pnpm build",
            "frontendDist": "../ui/dist"
          }
        }
        """)
        clone.write("src-tauri/Cargo.toml", """
        [package]
        name = "whimprflow"
        version = "0.1.0"
        edition = "2021"

        [[bin]]
        name = "whimprflow"
        path = "src/main.rs"
        """)
        clone.write("src-tauri/src/main.rs", "fn main() { println!(\"whimprflow\"); }\n")

        // The frontend package. No package.json at the repo root — the
        // WhimprFlow shape, and the reason the hook needs its own `cd`.
        clone.write("ui/package.json", """
        {
          "name": "whimprflow-ui",
          "private": true,
          "packageManager": "pnpm@\(pinnedPnpmVersion)",
          "scripts": { "build": "esbuild src/main.js --bundle --outfile=dist/main.js" },
          "devDependencies": { "esbuild": "0.25.0" }
        }
        """)
        // The two behaviours that are pnpm 11's defaults — and that his machine
        // therefore had for free — declared explicitly, so the pinned 10.30.0
        // behaves the way his pnpm behaved: an install runs before
        // `pnpm <script>`, and an unreviewed dependency build script FAILS that
        // install rather than warning about it. `packages:` sits last so a later
        // append reads as a plausible edit to it, which is what the guard-rail
        // test does.
        clone.write(
            "ui/pnpm-workspace.yaml",
            "strictDepBuilds: true\nverifyDepsBeforeRun: install\npackages:\n  - '.'\n"
        )
        // `main.js` is the bundle's entry point — the file the model edits, and
        // the only one whose contents can reach `ui/dist/main.js`.
        clone.write("ui/src/main.js", "export const main = 1\n")
        for sourceFileName in ["recorder", "transcript", "settings", "hotkey"] {
            clone.write("ui/src/\(sourceFileName).js", "export const \(sourceFileName) = 1\n")
        }

        clone.git(["init", "-q"])
        clone.git(["config", "user.email", "t@t"])
        clone.git(["config", "user.name", "t"])
        clone.git(["add", "-A"])
        clone.git(["commit", "-qm", "base"])
        return clone
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    // MARK: The reader's own rebuild, and what it leaves behind

    /// The project's own `beforeBuildCommand`, run the way everything OUTSIDE
    /// Iris's composed verification command runs it — Tauri's pipeline during
    /// `cargo tauri build` (`AppRelaunchService`), a guided-install step, or the
    /// reader at a terminal. Nothing wraps it, which is the whole point: before
    /// the fix this is the command that failed on him, and after it this is the
    /// command that has to work again.
    func runTheProjectsOwnHookTheWayEverythingOutsideIrisRunsIt() async -> MaintainCommandResult? {
        try? await runner.run("(cd 'ui' && pnpm build)", deadline: 600)
    }

    /// The clone as he found it: that same un-wrapped hook, failing on this
    /// pinned pnpm exactly as it failed for him and leaving a generated lockfile
    /// nobody typed. Returns whether it really did fail, because a fixture that
    /// quietly succeeded would make every assertion after it meaningless.
    ///
    /// The half-installed dependency tree that failure also leaves is then
    /// REMOVED, and since that deletion is the one arrangement in this fixture,
    /// here is exactly why. Measured on this Mac, 2026-09-03, both ways:
    ///
    ///   • pnpm 11.2.0 — HIS version — over a lockfile plus a half-installed
    ///     tree, `pnpm install --config.dangerously-allow-all-builds=true`
    ///     succeeds and runs esbuild's postinstall. The fix cures his machine.
    ///   • pnpm 10.30.0 — the newest pnpm the login shell's node v21 can run,
    ///     and therefore the only one this guard can drive — short-circuits that
    ///     same install ("Lockfile is up to date, resolution step is skipped /
    ///     Already up to date") and re-raises ERR_PNPM_IGNORED_BUILDS with the
    ///     flag set. Either half of that state alone is fine; only the two
    ///     together defeat it, and `--force` does not help.
    ///
    /// Keeping the tree would therefore pin a 10.30-only quirk rather than this
    /// bug, and would fail a fix that is correct for the reader who reported it.
    /// `node_modules` is git-ignored, so removing it changes nothing the gate
    /// under test can see — the dirt this method exists to create stays exactly
    /// as pnpm wrote it.
    func dirtyTheCloneTheWayHisOwnRebuildDid() async -> Bool {
        let hookRun = await runTheProjectsOwnHookTheWayEverythingOutsideIrisRunsIt()
        try? FileManager.default.removeItem(atPath: path + "/ui/node_modules")
        return hookRun?.succeeded == false
    }

    /// The last few lines of a command's output: a failure message is at the
    /// end, and the whole tail would bury it in install progress.
    static func lastLines(ofOutput output: String, count: Int) -> String {
        output.components(separatedBy: "\n").suffix(count).joined(separator: "\n")
    }

    /// What `git status --porcelain` says, untouched — the same command the
    /// preflight gate runs (OnDemandEditCoordinator.swift:1163), read here
    /// WITHOUT the report that is under test, so a fixture check and the
    /// behaviour it is checking can never be the same opinion.
    func rawPorcelainTheGateReads() async throws -> String {
        try await runner.run("git status --porcelain", deadline: 60).outputTail
    }

    /// The paths the preflight gate would refuse over: git's own answer, read by
    /// the gate's own report type. Untrimmed on the way in, exactly as the
    /// coordinator passes it — porcelain's first status column is usually a
    /// space, and trimming eats the first character of the first path.
    func dirtyPathsTheGateWouldSee() async throws -> String {
        OnDemandEditDirtyTreeReport.read(
            porcelainOutput: try await rawPorcelainTheGateReads(), repoRootPath: path
        ).pathsForTheRunLog
    }

    /// What esbuild wrote, or "" when it never ran. Git-ignored, so no revert or
    /// clean removes it — which is what makes it readable as evidence AFTER the
    /// engine has finished with the tree.
    var builtFrontendBundleContents: String {
        (try? String(contentsOfFile: path + "/ui/dist/main.js", encoding: .utf8)) ?? ""
    }

    /// Whether the three tools this guard genuinely needs answer through the
    /// runner Iris itself would use. Recorded as a failure rather than skipped
    /// silently: a guard that goes green because pnpm was unreachable is worse
    /// than no guard.
    func theToolchainThisGuardNeedsIsReachable() async throws -> Bool {
        let probe = try await runner.run(
            "command -v pnpm && command -v cargo && command -v node", deadline: 120
        )
        guard probe.succeeded else {
            Issue.record(
                "this guard needs pnpm, cargo and node on the runner's PATH; it saw: \(probe.outputTail)"
            )
            return false
        }
        return true
    }

    // MARK: Files and git

    func write(_ relativePath: String, _ contents: String) {
        try? contents.write(toFile: path + "/" + relativePath, atomically: true, encoding: .utf8)
    }

    func contents(_ relativePath: String) -> String {
        (try? String(contentsOfFile: path + "/" + relativePath, encoding: .utf8)) ?? ""
    }

    func append(toFile relativePath: String, _ addition: String) {
        write(relativePath, contents(relativePath) + addition)
    }

    @discardableResult
    func git(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        let standardOutputPipe = Pipe()
        process.standardOutput = standardOutputPipe
        process.standardError = Pipe()
        try? process.run()
        let data = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Polls a @MainActor condition. The coordinator publishes its phase from Tasks
/// it owns, so a test that drives it has to wait on state rather than on a
/// completion handler it was never given.
enum Bug5EndToEndWait {
    @MainActor
    static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}
