//
//  Test6OverlayReproTests.swift
//  leanring-buddyTests
//
//  ROOT CAUSES F AND I — the edit overlay's primary action is a lie, and it
//  drops the thread.
//
//  ── F. "Answer and retry" does not retry ────────────────────────────────────
//
//  Iris blocked an edit with a question of its own:
//
//      "Verification invokes `pnpm build`, but the environment has no `pnpm`
//       executable… Please install pnpm 11 or add it to the verification
//       process's PATH, then rerun verification."
//
//  The reader typed his answer into the blocked card — "im fine with you doing
//  that" — pressed the card's one primary button, and reported, verbatim:
//
//      "Hit answer and retry and it didnt do anything."
//
//  He is describing the button honestly. `retryAfterAnsweringBlockedQuestion`
//  runs no edit: it calls `pickApp`, which calls `resetInFlightState()` and
//  drops the machine back on the describe form, and then writes the answer into
//  `describePrefillText` — a hint for a text field, not a request. The engine is
//  never invited to try again, so the answer the reader was asked for reaches
//  nothing that could act on it.
//
//  (The block itself was ROOT CAUSE A — the launchd PATH — and another cluster
//  owns that. This file is only about the button: pressing it must re-run the
//  edit with the answer supplied.)
//
//  ── I. The overlay throws away the conversation ─────────────────────────────
//
//  The same reader, on the same machine, in his own words:
//
//      "Clicked off Iris, and then back on, still can't see the chat history
//       with feature or bug overlay, so can't be sure it's working."
//      "Can't send a follow up prompt after the plan into bug feature overlay
//       since it is gone."
//      "When I click out of Iris it doesn't save that chat in the chatbox there."
//      "The follow up view after clicking done doesn't allow me to edit the app,
//       the only way to do that that is clear is by going into the menu and
//       selecting it every time, very annoying for ease of use."
//
//  He got a REAL result out of that run — runtime finding 6 confirms Iris wrote
//  `docs/OPENROUTER-PLAN.md` — and then had no way to see it, follow it up, or
//  get back in except the menu bar. `OnDemandEditCoordinator.cancel()` is what
//  the result card's "Done" button calls, and it erases the app identity, the
//  engine's result, and the status line, leaving the machine at `.pickApp` —
//  the one phase `OnDemandEditCard` draws as `EmptyView()`. The work happened
//  and the UI discarded the thread.
//
//  ── What these tests do ─────────────────────────────────────────────────────
//
//  They drive the REAL coordinator through the REAL flow the reader walked —
//  pick an app, describe the change, answer any clarification, approve the
//  plan, let the engine come back — against a real, clean, home-contained git
//  clone. The only stand-in is the engine itself (a recorder that says what it
//  was asked to do and returns a scripted outcome), because the defects are in
//  what the coordinator does with an outcome, not in the outcome.
//
//  Nothing here greps source. Every assertion is on state the running app
//  actually reaches.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized)
struct Test6OverlayReproTests {

    // MARK: - Recording what the engine was asked to do

    /// Stands in for the jailed edit loop. It records every invitation the
    /// coordinator sends it — which is the whole point: root cause F is that
    /// the retry sends none.
    @MainActor
    final class EngineCallRecorder {
        struct Call {
            let scrubbedRequest: String
            let additionalPromptSections: [String]
        }

        private(set) var calls: [Call] = []
        /// Returned in order; the last one repeats if the coordinator ever asks
        /// for more than were scripted.
        var scriptedResults: [MaintainOnDemandEditResult] = []

        func recordAndAnswer(
            scrubbedRequest: String, additionalPromptSections: [String]
        ) -> MaintainOnDemandEditResult {
            calls.append(Call(
                scrubbedRequest: scrubbedRequest,
                additionalPromptSections: additionalPromptSections
            ))
            let index = calls.count - 1
            guard !scriptedResults.isEmpty else {
                return .couldNotComplete(reason: "no scripted result")
            }
            return index < scriptedResults.count ? scriptedResults[index] : scriptedResults[scriptedResults.count - 1]
        }

        /// Everything the engine was told on its most recent invitation — the
        /// request plus the extra prompt sections — as one searchable string.
        var everythingTheEngineWasLastTold: String {
            guard let last = calls.last else { return "" }
            return ([last.scrubbedRequest] + last.additionalPromptSections).joined(separator: "\n")
        }
    }

    // MARK: - F: "Answer and retry"

    /// THE REPORTED SYMPTOM: "Hit answer and retry and it didnt do anything."
    ///
    /// Iris blocks with a question, the reader answers it, and presses the
    /// card's primary button. That button's promise is in its label: answer,
    /// AND RETRY. So the engine must be invited to try again, and it must be
    /// told the answer — otherwise the retry could only fail the same way.
    @Test func answerAndRetryMustReRunTheEditWithTheReadersAnswer() async throws {
        guard theMachineCanRunAnEdit else { return }

        let clonePath = try Self.makeCleanSourceCloneInsideHome()
        defer { Self.removeDirectory(clonePath) }

        let slug = "overlay-repro-f-\(UUID().uuidString.prefix(8))"
        defer { Self.removeRunArtifacts(forAppSlug: slug) }
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        provenanceStore.recordGuideSourceClone(
            appSlug: slug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let recorder = EngineCallRecorder()
        // First attempt: the model blocks and asks the reader something — the
        // exact shape of the reported run. Second attempt (if one ever comes):
        // it succeeds, so a real resume has somewhere to land.
        recorder.scriptedResults = [
            .blockedByModel(
                explanation: "Verification invokes `pnpm build`, but the environment has no `pnpm` executable.",
                questionForUser: "May I install pnpm, or would you rather add it to the PATH yourself?"
            ),
            .appliedAndRebuilt(
                branchName: "iris/edit-repro", changeId: "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0",
                kind: .feature, suitePassed: true
            ),
        ]
        let coordinator = Self.makeCoordinator(provenanceStore: provenanceStore, recorder: recorder)

        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was refused before the flow could start: \(coordinator.phase)")
            return
        }

        await driveFromDescribeToTheRun(
            coordinator, request: "write me a plan for adding OpenRouter support", kind: .feature
        )

        let blocked = await waitUntil {
            if case .blockedByModel = coordinator.phase { return true }
            return false
        }
        guard blocked else {
            Issue.record("the run never reached the blocked card; phase is \(coordinator.phase)")
            return
        }
        #expect(recorder.calls.count == 1)
        #expect(coordinator.blockedQuestionForUser != nil)

        // The reader types his answer and presses the one primary button.
        let theReadersAnswer = "im fine with you doing that"
        coordinator.retryAfterAnsweringBlockedQuestion(theReadersAnswer)

        // A RETRY IS AN ATTEMPT. The first one landed in under a second, so
        // ten is a generous window for the second.
        let retried = await waitUntil(timeoutSeconds: 10) { recorder.calls.count >= 2 }

        // 1. The button must actually re-run the edit.
        #expect(
            retried,
            "\"Answer and retry\" ran no edit: the engine was invited \(recorder.calls.count) time(s), not 2"
        )
        // 2. And the retry must carry the answer it just asked the reader for —
        //    a retry that does not know the answer can only block again.
        #expect(
            recorder.everythingTheEngineWasLastTold.contains(theReadersAnswer),
            "the retry never told the engine the reader's answer"
        )
        // 3. It must not bounce the reader back to the empty describe form,
        //    which is what "it didnt do anything" looked like from the outside.
        #expect(
            coordinator.phase != .describe,
            "\"Answer and retry\" reset the flow to the describe form instead of retrying"
        )
    }

    // MARK: - I: the overlay throws away the conversation

    /// THE REPORTED SYMPTOM: "The follow up view after clicking done doesn't
    /// allow me to edit the app, the only way to do that that is clear is by
    /// going into the menu and selecting it every time, very annoying for ease
    /// of use." — and, for the same reason, "Clicked off Iris, and then back
    /// on, still can't see the chat history with feature or bug overlay."
    ///
    /// A completed edit is a finished exchange. Closing its result card must
    /// not delete it: the reader must still be able to see what Iris did, and
    /// must still be pointed at the app they were editing so a follow-up is a
    /// tap rather than a trip back through the menu bar.
    @Test func finishingAnEditMustNotEraseTheThreadOrForgetTheApp() async throws {
        guard theMachineCanRunAnEdit else { return }

        let clonePath = try Self.makeCleanSourceCloneInsideHome()
        defer { Self.removeDirectory(clonePath) }

        let slug = "overlay-repro-i-\(UUID().uuidString.prefix(8))"
        defer { Self.removeRunArtifacts(forAppSlug: slug) }
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        provenanceStore.recordGuideSourceClone(
            appSlug: slug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let recorder = EngineCallRecorder()
        // The reader's actual run: it WORKED. Iris wrote a plan document and
        // committed it on a branch.
        recorder.scriptedResults = [
            .appliedAndRebuilt(
                branchName: "iris/edit-openrouter-plan",
                changeId: "abcdefabcdefabcdefabcdefabcdefab",
                kind: .feature, suitePassed: nil
            ),
        ]
        let coordinator = Self.makeCoordinator(provenanceStore: provenanceStore, recorder: recorder)

        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was refused before the flow could start: \(coordinator.phase)")
            return
        }

        await driveFromDescribeToTheRun(
            coordinator, request: "write me a plan for adding OpenRouter support", kind: .feature
        )

        let finished = await waitUntil { coordinator.phase == .done }
        guard finished else {
            Issue.record("the run never finished; phase is \(coordinator.phase)")
            return
        }

        // Sanity: while the result card is up, the exchange IS all there. This
        // is the state the reader saw, and the state that must survive.
        #expect(coordinator.activeAppSlug == slug)
        #expect(coordinator.lastResult != nil)
        #expect(coordinator.statusLine?.isEmpty == false)

        // The reader taps "Done" on the result card — the only button there is.
        coordinator.cancel()

        // 1. The thread must survive being closed. Right now the result and the
        //    line describing it are both deleted, so re-opening the overlay
        //    shows nothing at all — "still can't see the chat history".
        #expect(
            coordinator.lastResult != nil,
            "closing the result card deleted the engine's result — nothing is left of the exchange"
        )
        #expect(
            coordinator.statusLine?.isEmpty == false,
            "closing the result card deleted what Iris said it did"
        )
        // 2. Iris must still know which app was just edited, or a follow-up
        //    edit has no target and the menu bar is the only way back in.
        #expect(
            coordinator.activeAppSlug == slug,
            "closing the result card forgot which app was being edited — the only way back is the menu bar"
        )
        // 3. `.pickApp` is the phase the card draws as EmptyView. Landing there
        //    is exactly "the overlay is gone".
        #expect(
            coordinator.phase != .pickApp,
            "finishing an edit dropped the overlay back to the empty app-picker phase"
        )
    }

    /// THE REPORTED SYMPTOM: "When I click out of Iris it doesn't save that chat
    /// in the chatbox there."
    ///
    /// A second edit must not silently swallow the first. Today `pickApp` calls
    /// `resetInFlightState()` and nils `lastResult`, so the session keeps
    /// exactly one exchange and the previous one leaves no trace anywhere —
    /// there is nothing for a re-opened overlay to show.
    @Test func aSecondEditMustNotEraseTheFirstOnesResult() async throws {
        guard theMachineCanRunAnEdit else { return }

        let clonePath = try Self.makeCleanSourceCloneInsideHome()
        defer { Self.removeDirectory(clonePath) }

        let slug = "overlay-repro-i2-\(UUID().uuidString.prefix(8))"
        defer { Self.removeRunArtifacts(forAppSlug: slug) }
        let provenanceStore = InstallProvenanceStore(userDefaults: Self.ephemeralDefaults())
        provenanceStore.recordGuideSourceClone(
            appSlug: slug, clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )

        let recorder = EngineCallRecorder()
        recorder.scriptedResults = [
            .appliedAndRebuilt(
                branchName: "iris/edit-first", changeId: "11111111111111111111111111111111",
                kind: .feature, suitePassed: nil
            ),
        ]
        let coordinator = Self.makeCoordinator(provenanceStore: provenanceStore, recorder: recorder)

        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("the app was refused before the flow could start: \(coordinator.phase)")
            return
        }
        await driveFromDescribeToTheRun(
            coordinator, request: "write me a plan for adding OpenRouter support", kind: .feature
        )
        guard await waitUntil({ coordinator.phase == .done }) else {
            Issue.record("the first run never finished; phase is \(coordinator.phase)")
            return
        }
        let firstRequest = coordinator.activeRequestText
        #expect(firstRequest?.contains("OpenRouter") == true)

        // The reader starts a second edit on the same app.
        coordinator.pickApp(slug: slug, name: "Repro App", stack: .nextjs)
        #expect(coordinator.phase == .describe)

        // The first exchange must still be somewhere. It is the thing the
        // reader went looking for when he clicked back into Iris.
        #expect(
            coordinator.lastResult != nil,
            "starting a second edit erased every trace of the first one's result"
        )
    }

    // MARK: - Driving the flow the way a reader does

    /// describe → (answer whatever Iris asks) → approve the plan → run.
    private func driveFromDescribeToTheRun(
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
                // Never the "Stop…" option — that is the reader declining, and
                // this reader did not decline.
                answers[question.id] = question.options.first {
                    !$0.lowercased().hasPrefix("stop")
                } ?? question.options[0]
            }
            coordinator.submitClarificationAnswers(answers)
        }

        guard coordinator.phase == .presentingPlan else {
            Issue.record("the plan was never presented; phase is \(coordinator.phase)")
            return
        }
        coordinator.confirmPlanAndStart()
    }

    @discardableResult
    private func waitUntil(
        timeoutSeconds: Double = 30, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    // MARK: - Akrit's machine, recreated

    /// Everything the coordinator's fail-closed eligibility gate demands, minus
    /// the one condition a test cannot fabricate: a connected editing
    /// credential. Akrit HAD one — his run produced a real committed change —
    /// so this is part of recreating his machine, not a way around it. On a box
    /// with no credential the flow cannot be entered at all, and these tests
    /// no-op rather than fail for the wrong reason (the same graceful skip
    /// `OnDemandEditEngineTests` uses for the Seatbelt jail).
    private var theMachineCanRunAnEdit: Bool {
        MaintainSandbox.isAvailable && MaintainModelProviderResolver.firstAvailable() != nil
    }

    private static func makeCoordinator(
        provenanceStore: InstallProvenanceStore, recorder: EngineCallRecorder
    ) -> OnDemandEditCoordinator {
        OnDemandEditCoordinator(
            installProvenanceStore: provenanceStore,
            patchQueue: PatchQueue(baseDirectoryURL: temporaryDirectoryURL()),
            // A private latch, so a real run elsewhere on this Mac can never
            // block the test and the test can never block a real run.
            clonePathLock: MaintainClonePathLock(),
            topRequestsForApp: { _ in [] },
            // The §7 probe is a model call; all-quiet is its own fail-open
            // verdict and keeps the flow deterministic.
            probeRequestTriggers: { _, _ in .allQuiet },
            performOnDemandEdit: {
                _, _, _, _, scrubbedRequest, _, _, _, _, additionalPromptSections, _ in
                await MainActor.run {
                    recorder.recordAndAnswer(
                        scrubbedRequest: scrubbedRequest,
                        additionalPromptSections: additionalPromptSections
                    )
                }
            }
        )
    }

    /// A real git clone, clean, inside $HOME, with a build recipe Iris can
    /// resolve — i.e. one that clears every gate in `eligibility(...)` and
    /// survives the live re-check and the dirty-tree refusal at start.
    private static func makeCleanSourceCloneInsideHome() throws -> String {
        let repositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iris-overlay-repro", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: repositoryURL, withIntermediateDirectories: true
        )
        let repositoryPath = repositoryURL.path

        // A Node app with real build/test scripts, so `RepoRecipeService`
        // derives a buildable recipe and the "Iris doesn't know how to rebuild
        // this kind of app" refusal never fires.
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

    /// A real run writes a transcript and a memory record under
    /// ~/Library/Logs/Iris/edit-runs. These are real runs, so they really write
    /// them — and a test must not leave its litter in the reader's own logs.
    private static func removeRunArtifacts(forAppSlug appSlug: String) {
        let runsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Iris/edit-runs", isDirectory: true)
        // The transcript lives in the directory itself; the memory record the
        // next run would read lives in `index/`.
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
        UserDefaults(suiteName: "iris.overlay.repro.\(UUID().uuidString)")!
    }

    private static func temporaryDirectoryURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-overlay-repro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
