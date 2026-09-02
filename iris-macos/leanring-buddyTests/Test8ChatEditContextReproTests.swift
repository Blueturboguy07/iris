//
//  Test8ChatEditContextReproTests.swift
//  leanring-buddyTests
//
//  THE GENERAL-CHAT / EDIT-CONTEXT MISMATCH (Test 8 field report, Iris 0.9.4).
//
//  The reader had an on-demand EDIT PLAN on screen and asked general chat about
//  it. Chat could not see it. In his own words:
//
//      "the chat below is unrelated to the editing of software"
//      "it can't see Iris plan for editing software which can be an issue when
//       trying to debug Iris itself, or someone trying to learn the software
//       there"
//      — and, in general chat, asked "is the above plan a good plan?", the
//      answer came back "i can't see what plan you're asking about."
//
//  The chat pipeline already had a seam for the OTHER thing Iris can have the
//  reader in the middle of — an install guide
//  (`GuideSessionController.chatContextForTheAssistant()`), so "why is step 7
//  failing" is answered from the real step. There was NO equivalent for an
//  active on-demand edit: with a plan card, a blocked card, or a running edit
//  on screen, chat was handed nothing about it and truthfully said so.
//
//  ── What these tests do ─────────────────────────────────────────────────────
//
//  Two layers, mirroring the sibling repro suites (Test6/Test7):
//
//    1. The REAL flow, driven the way the reader did — pick an app, describe a
//       change, answer any clarification, and stop on the PLAN (or let a
//       scripted engine BLOCK) — against a real, clean, home-contained git
//       clone. Then read exactly what chat would be handed
//       (`OnDemandEditCoordinator.chatContextForTheAssistant()`) and assert the
//       plan / blocked reason is IN it. This needs the same machine capability
//       every real edit needs (a connected editing credential + the Seatbelt
//       jail), so on a box that cannot run an edit it no-ops rather than fail
//       for the wrong reason — the same graceful skip Test6/OnDemandEditEngine
//       use. That is recreating the tester's machine, not working around it:
//       his run reached a real plan.
//
//    2. Machine-INDEPENDENT observations that run on any box: a refusal is
//       visible to chat (reached with no credential at all, since the
//       provenance gate fails first), chat is handed NOTHING before an edit is
//       reader-facing, and the pipeline's own guide-vs-edit chooser
//       (`CompanionManager.assistantSelfStateContext`) prefers the active edit,
//       falls back to the guide, and holds the "an open guide and an active
//       edit are never both on screen" invariant.
//
//  Nothing here greps source. Every assertion is on the string the running app
//  would actually hand the chat model.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized)
struct Test8ChatEditContextReproTests {

    // MARK: - 1. The real flow: a PLAN on screen must be visible to chat

    /// THE REPORTED SYMPTOM, recreated: a plan is on screen and chat is asked
    /// "is the above plan a good plan?" The context Iris hands the chat model
    /// must NAME the app, the kind, the reader's own request, and the plan —
    /// otherwise the only honest answer is the one the reader got, "i can't see
    /// what plan you're asking about."
    @Test func aPlanOnScreenIsHandedToChat() async throws {
        guard theMachineCanRunAnEdit else { return }

        let clonePath = try Self.makeCleanSourceCloneInsideHome()
        defer { Self.removeDirectory(clonePath) }

        let slug = "test8-plan-\(UUID().uuidString.prefix(8))"
        defer { Self.removeRunArtifacts(forAppSlug: slug) }
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        provenanceStore.recordGuideSourceClone(
            appSlug: slug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )
        let coordinator = Self.makeCoordinator(
            provenanceStore: provenanceStore, scriptedResults: []
        )

        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was refused before the flow could start: \(coordinator.phase)")
            return
        }

        let theReadersRequest = "add a dark mode toggle to the settings screen"
        await Self.driveFromDescribeToThePlan(coordinator, request: theReadersRequest, kind: .feature)

        guard coordinator.phase == .presentingPlan else {
            Issue.record("the plan was never presented; phase is \(coordinator.phase)")
            return
        }

        // What chat would actually be handed.
        let editContext = coordinator.chatContextForTheAssistant()
        guard let editContext else {
            Issue.record("with a plan on screen, chat was handed NOTHING about the edit")
            return
        }
        // The app, the kind, the reader's own words, and the plan state — the
        // exact things "is the above plan good?" is about.
        #expect(editContext.contains("Repro App"))
        #expect(editContext.contains("add a feature to"))
        #expect(editContext.contains("dark mode toggle"))
        #expect(
            editContext.contains("plan") && editContext.contains("approve"),
            "the plan context did not describe a plan awaiting approval: \(editContext)"
        )
    }

    // MARK: - 1b. The real flow: a BLOCKED card must be visible to chat

    /// The other reader-facing state the report calls out — a blocked card. When
    /// Iris blocks the edit with its own explanation (and optional question),
    /// chat must be able to see the blocked reason so "why did it stop?" is
    /// answerable from the real sentence, not guessed.
    @Test func aBlockedCardIsHandedToChat() async throws {
        guard theMachineCanRunAnEdit else { return }

        let clonePath = try Self.makeCleanSourceCloneInsideHome()
        defer { Self.removeDirectory(clonePath) }

        let slug = "test8-blocked-\(UUID().uuidString.prefix(8))"
        defer { Self.removeRunArtifacts(forAppSlug: slug) }
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        provenanceStore.recordGuideSourceClone(
            appSlug: slug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let blockedExplanation = "This is a design decision only you can make, not a source bug."
        let blockedQuestion = "Which of the two layouts did you have in mind?"
        let coordinator = Self.makeCoordinator(
            provenanceStore: provenanceStore,
            scriptedResults: [
                .blockedByModel(explanation: blockedExplanation, questionForUser: blockedQuestion)
            ]
        )

        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was refused before the flow could start: \(coordinator.phase)")
            return
        }
        await Self.driveFromDescribeToTheRun(coordinator, request: "make it prettier", kind: .feature)

        let blocked = await Self.waitUntil {
            if case .blockedByModel = coordinator.phase { return true }
            return false
        }
        guard blocked else {
            Issue.record("the run never reached the blocked card; phase is \(coordinator.phase)")
            return
        }

        let editContext = coordinator.chatContextForTheAssistant()
        guard let editContext else {
            Issue.record("with a blocked card on screen, chat was handed NOTHING about the edit")
            return
        }
        #expect(editContext.contains(blockedExplanation))
        #expect(editContext.contains(blockedQuestion))
    }

    // MARK: - 2. Machine-independent observations (run on any box)

    /// A refusal is a reader-facing card too, and reached with NO credential at
    /// all — the provenance gate refuses first — so this runs everywhere. A
    /// reader asking chat "why can't I edit this?" should not be met with
    /// silence about the very refusal on their screen.
    @Test func aRefusalIsVisibleToChat() {
        // No clone recorded → the provenance gate refuses before the credential
        // gate is even reached, so this is independent of any machine key.
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        let coordinator = Self.makeCoordinator(provenanceStore: provenanceStore, scriptedResults: [])

        coordinator.pickApp(slug: "test8-refusal", name: "Repro App", stack: .tauri)
        guard case .notEligible = coordinator.phase else {
            Issue.record("expected a refusal with no provenance; phase is \(coordinator.phase)")
            return
        }

        let editContext = coordinator.chatContextForTheAssistant()
        guard let editContext else {
            Issue.record("a refusal card was on screen and chat was handed nothing about it")
            return
        }
        #expect(editContext.contains("Repro App"))
        #expect(
            editContext.contains("refused") || editContext.contains("can only edit"),
            "the refusal context did not carry the refusal: \(editContext)"
        )
    }

    /// Chat is handed NOTHING before an edit is reader-facing — a freshly
    /// constructed coordinator (nothing picked) is silent, exactly as the guide
    /// context is silent before a guide is open. This is the "does not intrude
    /// on ordinary chat" half of the fix.
    @Test func chatGetsNothingBeforeAnEditIsReaderFacing() {
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        let coordinator = Self.makeCoordinator(provenanceStore: provenanceStore, scriptedResults: [])
        #expect(coordinator.phase == .pickApp)
        #expect(
            coordinator.chatContextForTheAssistant() == nil,
            "chat was handed edit context when no edit was even in progress"
        )
    }

    // MARK: - Harness (mirrors Test6OverlayReproTests)

    /// Everything the fail-closed eligibility gate demands except the one thing
    /// a test cannot fabricate — a connected editing credential. The tester HAD
    /// one (his run reached a real plan), so this is recreating his machine.
    private var theMachineCanRunAnEdit: Bool {
        MaintainSandbox.isAvailable && MaintainModelProviderResolver.firstAvailable() != nil
    }

    /// describe → answer any clarification → STOP on the plan (never approving
    /// it), so the coordinator is parked exactly where the reader's was: a plan
    /// on screen, nothing running.
    private static func driveFromDescribeToThePlan(
        _ coordinator: OnDemandEditCoordinator, request: String, kind: OnDemandEditKind
    ) async {
        #expect(coordinator.describeRequest(request, kind: kind))
        let settled = await waitUntil {
            coordinator.phase == .clarifying || coordinator.phase == .presentingPlan
        }
        guard settled else {
            Issue.record("the describe step never advanced; phase is \(coordinator.phase)")
            return
        }
        if coordinator.phase == .clarifying {
            var answers: [String: String] = [:]
            for question in coordinator.clarificationQuestions {
                // Never the "Stop…" option — that is the reader declining.
                answers[question.id] = question.options.first {
                    !$0.lowercased().hasPrefix("stop")
                } ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answers)
        }
        _ = await waitUntil { coordinator.phase == .presentingPlan }
    }

    /// describe → answer any clarification → approve the plan → run (the scripted
    /// engine then delivers whatever outcome the test wants).
    private static func driveFromDescribeToTheRun(
        _ coordinator: OnDemandEditCoordinator, request: String, kind: OnDemandEditKind
    ) async {
        await driveFromDescribeToThePlan(coordinator, request: request, kind: kind)
        guard coordinator.phase == .presentingPlan else {
            Issue.record("the plan was never presented; phase is \(coordinator.phase)")
            return
        }
        coordinator.confirmPlanAndStart()
    }

    @discardableResult
    private static func waitUntil(
        timeoutSeconds: Double = 30, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    /// A coordinator whose only stand-in is the jailed engine, replaced by a
    /// recorder that returns scripted outcomes. Everything else — eligibility,
    /// the clone, the phase machine — is the real thing.
    private static func makeCoordinator(
        provenanceStore: InstallProvenanceStore,
        scriptedResults: [MaintainOnDemandEditResult]
    ) -> OnDemandEditCoordinator {
        let recorder = ScriptedEngine(scriptedResults: scriptedResults)
        return OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(baseDirectoryURL: temporaryDirectoryURL()),
            // A private latch, so a real run elsewhere on this Mac can never
            // block the test and the test can never block a real run.
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: {
                _, _, _, _, _, _, _, _, _, _, _ in
                await MainActor.run { recorder.next() }
            }
        )
    }

    /// Returns scripted outcomes in order; the last repeats. `couldNotComplete`
    /// stands in when nothing was scripted (the plan tests never reach the run).
    @MainActor
    final class ScriptedEngine {
        private let scriptedResults: [MaintainOnDemandEditResult]
        private var callCount = 0
        init(scriptedResults: [MaintainOnDemandEditResult]) {
            self.scriptedResults = scriptedResults
        }
        func next() -> MaintainOnDemandEditResult {
            defer { callCount += 1 }
            guard !scriptedResults.isEmpty else {
                return .couldNotComplete(reason: "no scripted result")
            }
            return callCount < scriptedResults.count
                ? scriptedResults[callCount]
                : scriptedResults[scriptedResults.count - 1]
        }
    }

    /// A real git clone, clean, inside $HOME, with a build recipe Iris can
    /// resolve — clears every gate in `eligibility(...)` and survives the live
    /// re-check and the dirty-tree refusal at start.
    private static func makeCleanSourceCloneInsideHome() throws -> String {
        let repositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iris-test8-repro", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repositoryURL, withIntermediateDirectories: true
        )
        let repositoryPath = repositoryURL.path
        try "{\"name\":\"repro-app\",\"version\":\"1.0.0\",\"private\":true,"
            .appending("\"scripts\":{\"build\":\"true\",\"test\":\"true\"}}\n")
            .write(toFile: repositoryPath + "/package.json", atomically: true, encoding: .utf8)
        try "console.log('hello')\n"
            .write(toFile: repositoryPath + "/index.js", atomically: true, encoding: .utf8)
        git(["init", "-q"], in: repositoryPath)
        git(["config", "user.email", "repro@example.invalid"], in: repositoryPath)
        git(["config", "user.name", "repro"], in: repositoryPath)
        git(["add", "-A"], in: repositoryPath)
        git(["commit", "-qm", "base"], in: repositoryPath)
        return repositoryPath
    }

    private static func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func removeRunArtifacts(forAppSlug appSlug: String) {
        let runsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Iris/edit-runs", isDirectory: true)
        for directoryURL in [runsDirectoryURL, runsDirectoryURL.appendingPathComponent("index", isDirectory: true)] {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
            for entry in entries where entry.contains(appSlug) {
                try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(entry))
            }
        }
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func ephemeralDefaults() -> UserDefaults {
        UserDefaults(suiteName: "iris.test8.repro.\(UUID().uuidString)")!
    }

    private static func temporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-test8-repro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - The pipeline's guide-vs-edit chooser (pure; runs on any box)

/// `CompanionManager.assistantSelfStateContext` is the one place the chat
/// pipeline decides which of Iris's own two "reader is mid-something" states to
/// append, and how the new edit context rides the SAME slot the guide context
/// already used — the exact thing that must "not double-count or override guide
/// context." Pure and static precisely so this decision is testable without the
/// screenshot pipeline it lives in.
@MainActor
@Suite struct Test8AssistantSelfStateContextTests {

    @Test func anActiveEditIsPreferredOverARememberedGuide() {
        // The reported situation: an edit is on screen; a guide was followed
        // earlier and is now closed, so its context still speaks to a remembered
        // install. The edit is what is on screen, so it wins.
        let chosen = CompanionManager.assistantSelfStateContext(
            editContext: "[EDIT CONTEXT]",
            guideContext: "[remembered guide context]",
            aGuideIsOpenOnScreen: false
        )
        #expect(chosen == "[EDIT CONTEXT]")
    }

    @Test func theGuideIsUsedWhenNoEditIsActive() {
        let chosen = CompanionManager.assistantSelfStateContext(
            editContext: nil,
            guideContext: "[GUIDE CONTEXT]",
            aGuideIsOpenOnScreen: true
        )
        #expect(chosen == "[GUIDE CONTEXT]")
    }

    @Test func nothingIsAppendedWhenNeitherIsActive() {
        let chosen = CompanionManager.assistantSelfStateContext(
            editContext: nil,
            guideContext: nil,
            aGuideIsOpenOnScreen: false
        )
        #expect(chosen == nil)
    }

    /// The invariant the edit context leans on: an ACTIVE edit and an OPEN guide
    /// are never the reader-facing thing at once, so preferring the edit here
    /// never silently clobbers a guide that is genuinely open. When an edit is
    /// active and no guide is open, the chooser returns the edit without
    /// tripping its own assertion.
    @Test func anActiveEditWithNoOpenGuideChoosesTheEditCleanly() {
        let chosen = CompanionManager.assistantSelfStateContext(
            editContext: "[EDIT CONTEXT]",
            guideContext: nil,
            aGuideIsOpenOnScreen: false
        )
        #expect(chosen == "[EDIT CONTEXT]")
    }
}
