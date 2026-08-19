//
//  GuideAutopilotRunnerTests.swift
//  leanring-buddyTests
//
//  The state machine, driven by fakes — no pty, no network. These pin the
//  behaviour the whole feature turns on: a clean command advances, a failure
//  climbs the ladder and no further, budgets actually cap, a sensitive step
//  is never executed, a risky fix waits for a tap and never runs itself, and
//  the ladder gives up gracefully instead of looping.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct GuideAutopilotRunnerTests {

    // MARK: - Fakes

    final class FakeShellSession: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/x/app"
        var resolvedSearchPath: String? = "/usr/bin:/bin"
        var modelTail = "some scrubbed output"

        /// Scripted outcomes, consumed in order; the last repeats.
        var outcomes: [GuideAutopilotCommandOutcome]
        private(set) var commandsRun: [String] = []
        /// How many times the escape hatch asked this session to cancel — the
        /// red button must reach BOTH the main and the long-running session.
        private(set) var cancelCount = 0

        init(outcomes: [GuideAutopilotCommandOutcome]) {
            self.outcomes = outcomes
        }

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async { cancelCount += 1 }
        func tailForTheModel() -> String { modelTail }

        func run(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            if outcomes.count > 1 { return outcomes.removeFirst() }
            return outcomes.first ?? .succeeded(workingDirectory: currentWorkingDirectory)
        }
    }

    final class FakeFixProposer: GuideAutopilotFixProposing {
        var fixesForRungA: [GuideAutopilotProposedFix?]
        var fixesForRungB: [GuideAutopilotProposedFix?]
        private(set) var rungACalls = 0
        private(set) var rungBCalls = 0

        init(rungA: [GuideAutopilotProposedFix?] = [], rungB: [GuideAutopilotProposedFix?] = []) {
            self.fixesForRungA = rungA
            self.fixesForRungB = rungB
        }

        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? {
            defer { rungACalls += 1 }
            return fixesForRungA.isEmpty ? nil : fixesForRungA.removeFirst()
        }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? {
            defer { rungBCalls += 1 }
            return fixesForRungB.isEmpty ? nil : fixesForRungB.removeFirst()
        }
    }

    private static func runner(
        shell: FakeShellSession,
        longRunning: FakeShellSession? = nil,
        proposer: FakeFixProposer? = nil
    ) -> GuideAutopilotRunner {
        let proposer = proposer ?? FakeFixProposer()
        return GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: longRunning ?? FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")]),
            fixProposer: proposer,
            guideContext: GuideAutopilotGuideContext(
                slug: "whimprflow", version: 3, appName: "WhimprFlow",
                platformLabel: "macOS",
                hostsReachedByTheGuide: ["github.com"]
            ),
            // No artificial hold in tests: a fake shell returns instantly and
            // the suite must stay fast and deterministic. The pacing floor is
            // exercised on its own in `pacingHoldsAFastCommandButNotASlowOne`.
            pacing: .instant
        )
    }

    private static func step(
        id: String = "package",
        command: String?,
        sensitive: Bool = false
    ) -> IrisGuideStep {
        IrisGuideStep(
            id: id, kind: .terminal, title: "Build the app", body: "…",
            command: command,
            watch: sensitive ? IrisStepWatch(expect: [], sensitive: true) : nil
        )
    }

    // MARK: - The escape hatch

    @Test func theRedButtonCancelsBothTheMainAndTheLongRunningSession() async {
        // A run-from-source step (`npm run app`, a dev server) runs on the
        // LONG-RUNNING session. The escape hatch must reach it, not only the
        // main session — otherwise the red button cannot stop the setup and the
        // reader is stuck (the NitroAI `npm run app` freeze).
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let runner = Self.runner(shell: main, longRunning: long)

        await runner.abortTheCurrentStepBecauseTheReaderAskedToStop()

        #expect(main.cancelCount == 1)
        #expect(long.cancelCount == 1, "the red button must cancel the long-running session too")
    }

    // MARK: - Pacing

    @Test func pacingHoldsAFastCommandButNotASlowOne() {
        let paced = GuideAutopilotPacing.humanPaced
        // A command that finished in a blink is held to the floor…
        #expect(abs(paced.remainingHold(afterElapsed: 0.005) - 1.195) < 0.0001)
        // …but a command that already ran longer than the floor gets no hold,
        // so a real install is never slowed.
        #expect(paced.remainingHold(afterElapsed: 3.0) == 0)
        #expect(paced.remainingHold(afterElapsed: 1.2) == 0)
        #expect(paced.remainingHold(afterElapsed: 100) >= 0)
        // The test/rehearsal pacing never holds at all.
        #expect(GuideAutopilotPacing.instant.remainingHold(afterElapsed: 0) == 0)
    }

    // MARK: - Happy path

    @Test func aCleanCommandSucceedsAndTheExitStatusIsRecorded() async {
        let shell = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let runner = Self.runner(shell: shell)
        let result = await runner.executeStepCommand(
            step: Self.step(command: "npm ci"), stepIndex: 0, totalSteps: 5
        )
        #expect(result == .succeeded)
        #expect(shell.commandsRun == ["npm ci"])
        let recordedAZeroExit = runner.transcript.contains {
            if case .exitStatus(let code, _) = $0 { return code == 0 }
            return false
        }
        #expect(recordedAZeroExit)
    }

    // MARK: - Sensitive

    @Test func aSensitiveStepIsNeverExecuted() async {
        let shell = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let runner = Self.runner(shell: shell)
        let result = await runner.executeStepCommand(
            step: Self.step(command: "echo $ANTHROPIC_API_KEY", sensitive: true),
            stepIndex: 0, totalSteps: 5
        )
        #expect(result == .handedBackAsSensitive)
        #expect(shell.commandsRun.isEmpty, "a sensitive command must never reach the shell")
    }

    // MARK: - The ladder

    @Test func aFailureIsRepairedByRungAAndTheOriginalRetried() async {
        // Original fails, fix runs clean, retry of the original succeeds.
        let shell = FakeShellSession(outcomes: [
            .failed(exitStatus: 1, workingDirectory: "/x"),   // original
            .succeeded(workingDirectory: "/x"),                // the fix
            .succeeded(workingDirectory: "/x"),                // retry
        ])
        let proposer = FakeFixProposer(rungA: [GuideAutopilotProposedFix(
            diagnosis: "esbuild was blocked.",
            confidence: "high",
            action: .runACommand(command: "pnpm approve-builds", whatItDoes: "Approves it."),
            retryTheOriginalCommandAfterwards: true,
            cameFromWebSearch: false
        )])
        let runner = Self.runner(shell: shell, proposer: proposer)
        let result = await runner.executeStepCommand(
            step: Self.step(command: "pnpm run build"), stepIndex: 1, totalSteps: 5
        )
        #expect(result == .succeeded)
        #expect(proposer.rungACalls == 1)
        #expect(proposer.rungBCalls == 0)
        #expect(shell.commandsRun == ["pnpm run build", "pnpm approve-builds", "pnpm run build"])
    }

    @Test func rungAFailingEscalatesToWebSearchThenSurfaces() async {
        // Everything fails; rung A offers a dud fix, rung B finds nothing.
        let shell = FakeShellSession(outcomes: [.failed(exitStatus: 1, workingDirectory: "/x")])
        let proposer = FakeFixProposer(
            rungA: [GuideAutopilotProposedFix(
                diagnosis: "Guessing.", confidence: "low",
                action: .runACommand(command: "npm install", whatItDoes: "Reinstalls."),
                retryTheOriginalCommandAfterwards: true, cameFromWebSearch: false
            )],
            rungB: [nil]
        )
        let runner = Self.runner(shell: shell, proposer: proposer)
        let result = await runner.executeStepCommand(
            step: Self.step(command: "pnpm run build"), stepIndex: 1, totalSteps: 5
        )
        #expect(result == .surfacedToReader)
        #expect(proposer.rungACalls == 1)
        #expect(proposer.rungBCalls == 1)
        if case .surfacedToReader = runner.state {} else {
            Issue.record("expected surfacedToReader state, got \(runner.state)")
        }
    }

    @Test func theGuideModelCallBudgetIsLatched() async {
        // Every command fails and every fix is a dud, across many steps.
        let proposer = FakeFixProposer(
            rungA: Array(repeating: nil, count: 20),
            rungB: Array(repeating: nil, count: 20)
        )
        let shell = FakeShellSession(outcomes: [.failed(exitStatus: 1, workingDirectory: "/x")])
        let runner = Self.runner(shell: shell, proposer: proposer)
        for index in 0..<6 {
            _ = await runner.executeStepCommand(
                step: Self.step(id: "s\(index)", command: "pnpm run build"),
                stepIndex: index, totalSteps: 6
            )
        }
        #expect(proposer.rungACalls + proposer.rungBCalls <= GuideAutopilotRunner.maximumModelCallsPerGuide,
                "model calls across the guide must not exceed the latched cap")
    }

    // MARK: - The confirm handshake

    @Test func aRiskyFixWaitsForATapAndNeverRunsItself() async {
        let shell = FakeShellSession(outcomes: [.failed(exitStatus: 1, workingDirectory: "/x")])
        let proposer = FakeFixProposer(rungA: [GuideAutopilotProposedFix(
            diagnosis: "Stale build dir.", confidence: "high",
            action: .runACommand(command: "rm -rf build", whatItDoes: "Clears the build folder."),
            retryTheOriginalCommandAfterwards: true, cameFromWebSearch: false
        )], rungB: [nil])
        let runner = Self.runner(shell: shell, proposer: proposer)

        let resultTask = Task {
            await runner.executeStepCommand(
                step: Self.step(command: "pnpm run build"), stepIndex: 0, totalSteps: 3
            )
        }
        // Let the ladder reach the confirm request, then decline.
        try? await Task.sleep(nanoseconds: 200_000_000)
        if case .awaitingConfirmation = runner.state {
            runner.skipPendingCommand()
        } else {
            Issue.record("expected a pending confirmation for rm -rf, got \(runner.state)")
        }
        _ = await resultTask.value
        #expect(!shell.commandsRun.contains("rm -rf build"),
                "a declined risky fix must never execute")
    }
}
