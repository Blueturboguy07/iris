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
#if IRIS_HARNESS_STANDALONE
@testable import IrisHarnessNative
#else
@testable import Iris
#endif

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
        /// Holds scripted runs open so a test can model a real dev server and
        /// release an old completion after a replacement owner exists.
        var holdRuns = false
        private(set) var heldRunCount = 0
        private var heldRunContinuations: [CheckedContinuation<GuideAutopilotCommandOutcome, Never>] = []

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
            if holdRuns {
                heldRunCount += 1
                return await withCheckedContinuation { continuation in
                    heldRunContinuations.append(continuation)
                }
            }
            if outcomes.count > 1 { return outcomes.removeFirst() }
            return outcomes.first ?? .succeeded(workingDirectory: currentWorkingDirectory)
        }

        func resolveNextHeldRun(with outcome: GuideAutopilotCommandOutcome) {
            guard !heldRunContinuations.isEmpty else { return }
            heldRunContinuations.removeFirst().resume(returning: outcome)
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
        proposer: FakeFixProposer? = nil,
        guideInstallers: [String: String] = [:],
        sourceOwner: String? = nil,
        sourceRepo: String? = nil,
        sourceCommit: String? = nil,
        sourceMetadataReader: @escaping @Sendable (String) async -> GuideAutopilotSourceCheckoutMetadata = { _ in .unknown }
    ) -> GuideAutopilotRunner {
        let proposer = proposer ?? FakeFixProposer()
        return GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: longRunning ?? FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")]),
            fixProposer: proposer,
            guideContext: GuideAutopilotGuideContext(
                slug: "whimprflow", version: 3, appName: "WhimprFlow",
                platformLabel: "macOS",
                hostsReachedByTheGuide: ["github.com"],
                commandTheGuidePublishesToInstallEachTool: guideInstallers,
                sourceOwner: sourceOwner,
                sourceRepo: sourceRepo,
                sourceCommit: sourceCommit
            ),
            // No artificial hold in tests: a fake shell returns instantly and
            // the suite must stay fast and deterministic. The pacing floor is
            // exercised on its own in `pacingHoldsAFastCommandButNotASlowOne`.
            pacing: .instant,
            sourceMetadataReader: sourceMetadataReader
        )
    }

    private static func step(
        id: String = "package",
        command: String?,
        sensitive: Bool = false,
        workingDirectory: String? = nil
    ) -> IrisGuideStep {
        IrisGuideStep(
            id: id, kind: .terminal, title: "Build the app", body: "…",
            command: command,
            watch: sensitive ? IrisStepWatch(expect: [], sensitive: true) : nil,
            workingDirectory: workingDirectory
        )
    }

    private static let sourcePinGuardCommand = """
    (
    if ! git config --get remote.origin.url 2>/dev/null | grep -qxF "https://example.test/source"; then
      echo "~/fixture already exists and is not a clean copy of this app's source. Move or rename that folder, then press Try again."
      exit 1
    fi
    if git status --porcelain 2>/dev/null | grep -q .; then
      echo "~/fixture already exists and is not a clean copy of this app's source. Move or rename that folder, then press Try again."
      exit 1
    fi
    git checkout 0123456789abcdef0123456789abcdef01234567
    )
    """

    private static func sourcePinStep() -> IrisGuideStep {
        IrisGuideStep(
            id: "pin-source", kind: .terminal, title: "Pin source", body: "",
            command: sourcePinGuardCommand,
            workingDirectory: "/Users/test/fixture"
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

    // MARK: - Terminal recovery and output ownership

    @Test func aRecoveredDeadTerminalIsSurfacedForExplicitRetryWithoutReplayingTheStep() async {
        let shell = FakeShellSession(outcomes: [.terminalSessionRestarted])
        let proposer = FakeFixProposer(
            rungA: [GuideAutopilotProposedFix(
                diagnosis: "should never be asked",
                confidence: "high",
                action: .runACommand(command: "echo repair", whatItDoes: "repairs"),
                retryTheOriginalCommandAfterwards: true,
                cameFromWebSearch: false
            )]
        )
        let runner = Self.runner(shell: shell, proposer: proposer)

        let result = await runner.executeStepCommand(
            step: Self.step(command: "install-tool --apply"), stepIndex: 2, totalSteps: 5
        )

        #expect(result == .surfacedToReader)
        #expect(shell.commandsRun == ["install-tool --apply"],
                "a dead terminal must not replay a potentially non-idempotent command")
        #expect(proposer.rungACalls == 0 && proposer.rungBCalls == 0,
                "terminal recovery is not a model-repair opportunity")
        guard case .surfacedToReader(let diagnosis, _) = runner.state else {
            Issue.record("expected an actionable surfaced state, got \(runner.state)")
            return
        }
        #expect(diagnosis.contains("did not replay"))
        #expect(diagnosis.contains("Try again"))
    }

    @Test func aBusyTerminalRejectionIsNotMisreportedAsARecoveredShellOrSentToTheModel() async {
        let shell = FakeShellSession(outcomes: [.sessionBusy])
        let proposer = FakeFixProposer(
            rungA: [GuideAutopilotProposedFix(
                diagnosis: "should never be asked",
                confidence: "high",
                action: .runACommand(command: "echo repair", whatItDoes: "repairs"),
                retryTheOriginalCommandAfterwards: true,
                cameFromWebSearch: false
            )]
        )
        let runner = Self.runner(shell: shell, proposer: proposer)

        let result = await runner.executeStepCommand(
            step: Self.step(command: "npm install"), stepIndex: 2, totalSteps: 5
        )

        #expect(result == .surfacedToReader)
        #expect(shell.commandsRun == ["npm install"])
        #expect(proposer.rungACalls == 0 && proposer.rungBCalls == 0,
                "a serial-session busy rejection must not duplicate work or spend a model call")
        guard case .surfacedToReader(let diagnosis, _) = runner.state else {
            Issue.record("expected a surfaced busy state, got \(runner.state)")
            return
        }
        #expect(diagnosis.contains("still finishing"))
        #expect(!diagnosis.contains("fresh terminal is ready"))
    }

    @Test func longRunningOwnershipCoversNoCwdStepsCancellationRetryAndStaleCompletion() async {
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        long.holdRuns = true
        let runner = Self.runner(shell: main, longRunning: long)
        let firstStep = Self.step(id: "run-first", command: "npm run dev")

        #expect(await runner.executeStepCommand(
            step: firstStep, stepIndex: 0, totalSteps: 3
        ) == .longRunningStarted)
        // The fake observes entry into run itself; this does not pretend that
        // the production API can acknowledge process startup before returning.
        for _ in 0..<100 where long.heldRunCount == 0 {
            await Task.yield()
        }
        #expect(long.heldRunCount == 1)

        let secondAttempt = await runner.executeStepCommand(
            step: Self.step(id: "run-second", command: "npm run dev"),
            stepIndex: 1,
            totalSteps: 3
        )
        #expect(secondAttempt == .surfacedToReader)
        #expect(long.commandsRun.count == 1,
                "a second no-cwd long-running step must not enter the side session")

        let sensitiveAttempt = await runner.executeStepCommand(
            step: Self.step(command: "echo SECRET && npm run dev", sensitive: true),
            stepIndex: 1,
            totalSteps: 3
        )
        #expect(sensitiveAttempt == .handedBackAsSensitive)
        #expect(!runner.transcript.contains { entry in
            if case .commandFromTheGuide(let text) = entry { return text.contains("SECRET") }
            return false
        }, "a sensitive long-running command must not be surfaced as busy with raw text")

        await runner.abortTheCurrentStepBecauseTheReaderAskedToStop()
        #expect(long.cancelCount == 1)

        // The first run is intentionally left unresolved: this models a stale
        // completion arriving after an explicit abort released its owner.
        #expect(await runner.executeStepCommand(
            step: Self.step(id: "run-retry", command: "npm run dev"),
            stepIndex: 2,
            totalSteps: 3
        ) == .longRunningStarted)
        for _ in 0..<100 where long.heldRunCount < 2 {
            await Task.yield()
        }
        #expect(long.heldRunCount == 2)

        long.resolveNextHeldRun(with: .timedOut)
        // The old run's completion must not clear the retry's ownership.
        for _ in 0..<100 {
            if case .running(let stepIndex) = runner.state, stepIndex == 2 { break }
            await Task.yield()
        }
        #expect(runner.state == .running(stepIndex: 2),
                "a stale timeout must not surface against the replacement step")
        let staleCompletionAttempt = await runner.executeStepCommand(
            step: Self.step(id: "run-after-stale", command: "npm run dev"),
            stepIndex: 3,
            totalSteps: 4
        )
        #expect(staleCompletionAttempt == .surfacedToReader)
        #expect(long.commandsRun.count == 2,
                "a stale completion must not make the replacement lane appear free")

        long.resolveNextHeldRun(with: .succeeded(workingDirectory: "/x"))
    }

    @Test func aLongRunningTimeoutSurfacesAnActionableRetryWithoutReplay() async {
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        long.holdRuns = true
        let runner = Self.runner(shell: main, longRunning: long)

        #expect(await runner.executeStepCommand(
            step: Self.step(command: "npm run dev"), stepIndex: 0, totalSteps: 1
        ) == .longRunningStarted)
        for _ in 0..<100 where long.heldRunCount == 0 {
            await Task.yield()
        }
        long.resolveNextHeldRun(with: .timedOut)
        for _ in 0..<100 {
            if case .surfacedToReader = runner.state { break }
            await Task.yield()
        }

        guard case .surfacedToReader(let diagnosis, _) = runner.state else {
            Issue.record("expected a surfaced long-running timeout, got \(runner.state)")
            return
        }
        #expect(diagnosis.contains("too long"))
        #expect(diagnosis.contains("not replayed"))
        #expect(diagnosis.contains("Try again"))
        #expect(long.commandsRun.count == 1)
    }

    @Test func anUnexpectedLongRunningCancellationSurfacesAnActionableRetry() async {
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        long.holdRuns = true
        let runner = Self.runner(shell: main, longRunning: long)

        #expect(await runner.executeStepCommand(
            step: Self.step(command: "npm run dev"), stepIndex: 0, totalSteps: 1
        ) == .longRunningStarted)
        for _ in 0..<100 where long.heldRunCount == 0 {
            await Task.yield()
        }
        long.resolveNextHeldRun(with: .cancelled)
        for _ in 0..<100 {
            if case .surfacedToReader = runner.state { break }
            await Task.yield()
        }

        guard case .surfacedToReader(let diagnosis, _) = runner.state else {
            Issue.record("expected a surfaced long-running interruption, got \(runner.state)")
            return
        }
        #expect(diagnosis.contains("interrupted"))
        #expect(diagnosis.contains("did not replay"))
        #expect(diagnosis.contains("Try again"))
        #expect(long.commandsRun.count == 1)
    }

    @Test func aRefusedLongRunningCommandDoesNotHoldTheSideSessionLane() async {
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let runner = Self.runner(shell: main, longRunning: long)

        #expect(await runner.executeStepCommand(
            step: Self.step(command: "sudo npm run dev"), stepIndex: 0, totalSteps: 2
        ) == .skippedByReader)
        #expect(long.commandsRun.isEmpty)

        #expect(await runner.executeStepCommand(
            step: Self.step(command: "npm run dev"), stepIndex: 1, totalSteps: 2
        ) == .longRunningStarted,
        "a refused confirmation must not strand the side-session ownership latch")
    }

    @Test func longRunningSessionOutputReachesTheSameTranscript() async {
        let main = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let long = FakeShellSession(outcomes: [.succeeded(workingDirectory: "/x")])
        let runner = Self.runner(shell: main, longRunning: long)

        long.onOutputLine?("dev server ready")
        long.onOutputLine?("http://localhost:3000")

        let outputLines = runner.transcript.compactMap { entry -> String? in
            if case .output(let line) = entry { return line }
            return nil
        }
        #expect(outputLines.contains("http://localhost:3000"))
    }

    @Test func aRecoveredShellDoesNotReplayTheOriginalCommandButAnExplicitSecondRunCan() async {
        let shell = FakeShellSession(outcomes: [
            .terminalSessionRestarted,
            .succeeded(workingDirectory: "/x"),
        ])
        let runner = Self.runner(shell: shell)
        let step = Self.step(command: "ditto release/App.app /Applications/App.app")

        #expect(await runner.executeStepCommand(step: step, stepIndex: 0, totalSteps: 1) == .surfacedToReader)
        #expect(shell.commandsRun == ["ditto release/App.app /Applications/App.app"])

        #expect(await runner.executeStepCommand(step: step, stepIndex: 0, totalSteps: 1) == .succeeded)
        #expect(shell.commandsRun == [
            "ditto release/App.app /Applications/App.app",
            "ditto release/App.app /Applications/App.app",
        ])
    }

    @Test func aWorkingDirectoryMoveRetriesOnceAfterARecoveredTerminalBeforeTheRealCommand() async {
        let shell = FakeShellSession(outcomes: [
            .terminalSessionRestarted,
            .succeeded(workingDirectory: "/Users/x/app"),
            .succeeded(workingDirectory: "/Users/x/app"),
        ])
        let runner = Self.runner(shell: shell)

        #expect(await runner.executeStepCommand(
            step: Self.step(command: "printf ready", workingDirectory: "/Users/x/app"),
            stepIndex: 0,
            totalSteps: 1
        ) == .succeeded)
        #expect(shell.commandsRun == [
            "cd /Users/x/app",
            "cd /Users/x/app",
            "printf ready",
        ])
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

    @Test func aSuccessfulGlobalInstallRefreshesTheShellBeforeTheNextStep() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/x"), // npm install -g yarn
            .succeeded(workingDirectory: "/x"), // environment refresh
            .succeeded(workingDirectory: "/x"), // yarn install
        ])
        let runner = Self.runner(shell: shell)

        #expect(
            await runner.executeStepCommand(
                step: Self.step(command: "npm install -g yarn"),
                stepIndex: 0,
                totalSteps: 2
            ) == .succeeded
        )
        #expect(shell.commandsRun == [
            "npm install -g yarn",
            GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand,
        ])

        #expect(
            await runner.executeStepCommand(
                step: Self.step(command: "yarn install"),
                stepIndex: 1,
                totalSteps: 2
            ) == .succeeded
        )
        #expect(shell.commandsRun.last == "yarn install")
    }

    @Test func aMissingYarnReplaysTheGuideInstallBeforeAskingTheModel() async {
        let shell = FakeShellSession(outcomes: [
            .failed(exitStatus: 127, workingDirectory: "/x"), // yarn install
            .succeeded(workingDirectory: "/x"),                // npm install -g yarn
            .succeeded(workingDirectory: "/x"),                // environment refresh
            .succeeded(workingDirectory: "/x"),                // yarn install retry
        ])
        let proposer = FakeFixProposer(
            rungA: [nil], rungB: [nil]
        )
        let runner = Self.runner(
            shell: shell,
            proposer: proposer,
            guideInstallers: ["yarn": "npm install -g yarn"]
        )

        let result = await runner.executeStepCommand(
            step: Self.step(command: "yarn install"), stepIndex: 6, totalSteps: 13
        )

        #expect(result == .succeeded)
        #expect(shell.commandsRun == [
            "yarn install",
            "npm install -g yarn",
            GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand,
            "yarn install",
        ])
        #expect(proposer.rungACalls == 0)
        #expect(proposer.rungBCalls == 0)
        #expect(runner.transcript.contains {
            if case .explanation(let text) = $0 {
                return text.contains("yarn") && text.contains("own step")
            }
            return false
        })
    }

    @Test func aMissingToolDoesNotRetryItsCommandAfterEnvironmentRefreshFails() async {
        let shell = FakeShellSession(outcomes: [
            .failed(exitStatus: 127, workingDirectory: "/x"),
            .succeeded(workingDirectory: "/x"),
            .sessionFailed,
        ])
        let proposer = FakeFixProposer()
        let runner = Self.runner(
            shell: shell, proposer: proposer,
            guideInstallers: ["node": "echo fixture-installer"]
        )
        let result = await runner.executeStepCommand(
            step: Self.step(command: "node app.js"), stepIndex: 1, totalSteps: 2
        )
        #expect(result == .surfacedToReader)
        #expect(shell.commandsRun == [
            "node app.js", "echo fixture-installer",
            GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand,
        ])
        #expect(proposer.rungACalls == 0 && proposer.rungBCalls == 0)
    }

    @Test func aGuideGlobalPackageInstallMapsItsPackageManagerWithoutAWatch() {
        let installStep = IrisGuideStep(
            id: "install-yarn", kind: .terminal, title: "Install Yarn", body: "",
            command: "npm install -g yarn"
        )
        let branch = IrisGuideBranch(
            platform: .macos, target: nil, label: "macOS", shell: .terminal,
            setupSteps: [],
            steps: [
                installStep,
                IrisGuideStep(
                    id: "dependencies", kind: .terminal, title: "Install dependencies", body: "",
                    command: "yarn install"
                ),
            ],
            unsupported: nil
        )

        #expect(
            GuideSessionController.commandsThisGuidePublishesToInstallEachToolForAutopilot(
                branch: branch
            ) == ["yarn": "npm install -g yarn"]
        )
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

    @Test func aDirtySourcePinSurfacesTheFoundFolderWithoutEnteringTheRepairLadder() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/fixture"), // declared folder
            .failed(exitStatus: 1, workingDirectory: "/Users/test/fixture") // source guard
        ])
        shell.modelTail = """
        ~/fixture already exists and is not a clean copy of this app's source.
         M Sources/Editor.swift
        ?? notes/local.md
        """
        let proposer = FakeFixProposer(rungA: [nil], rungB: [nil])
        let runner = Self.runner(shell: shell, proposer: proposer)

        let result = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        #expect(result == .surfacedToReader)
        #expect(proposer.rungACalls == 0)
        #expect(proposer.rungBCalls == 0)
        #expect(shell.commandsRun == [
            "cd /Users/test/fixture",
            Self.sourcePinGuardCommand,
        ])
        guard case .surfacedToReader(let diagnosis, _) = runner.state else {
            Issue.record("expected the source pin to hand the step back, got \(runner.state)")
            return
        }
        #expect(diagnosis.contains("source check stopped in /Users/test/fixture"))
        #expect(diagnosis.contains("Sources/Editor.swift"))
        #expect(diagnosis.contains("notes/local.md"))
        #expect(!diagnosis.contains("couldn't move into"))
    }

    @Test func sourcePinRetryRemainsAnExplicitSingleStepAndDoesNotLoopOrReclone() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/fixture"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/fixture"),
            .succeeded(workingDirectory: "/Users/test/fixture"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/fixture"),
        ])
        shell.modelTail = "~/fixture already exists and is not a clean copy of this app's source."
        let proposer = FakeFixProposer(rungA: [nil], rungB: [nil])
        let runner = Self.runner(shell: shell, proposer: proposer)

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )
        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        #expect(proposer.rungACalls == 0)
        #expect(proposer.rungBCalls == 0)
        #expect(shell.commandsRun == [
            "cd /Users/test/fixture",
            Self.sourcePinGuardCommand,
            "cd /Users/test/fixture",
            Self.sourcePinGuardCommand,
        ])
        #expect(!shell.commandsRun.contains("git clone https://example.test/source"))
    }

    @Test func sourcePinNamesOnlySafeRelativePorcelainPathsAndStatesWhenNamesWereNotPrinted() {
        let tail = """
        ~/fixture already exists and is not a clean copy of this app's source.
         M Sources/Editor.swift
        ?? notes/local.md
        ?? ../outside.md
        ?? /private/tmp/outside.md
        ?? \"quoted name.md\"
        R  old.md -> new.md
        """
        let refusal = GuideAutopilotSourceCheckoutRefusal.detect(
            command: Self.sourcePinGuardCommand,
            exitStatus: 1,
            scrubbedOutputTail: tail,
            workingDirectory: "/Users/test/fixture"
        )
        #expect(refusal?.verifiedWorkingDirectory == "/Users/test/fixture")
        #expect(refusal?.safeRelativeChangedPaths == ["Sources/Editor.swift", "notes/local.md"])

        let noNames = GuideAutopilotSourceCheckoutRefusal.detect(
            command: Self.sourcePinGuardCommand,
            exitStatus: 1,
            scrubbedOutputTail: "~/fixture already exists and is not a clean copy of this app's source.",
            workingDirectory: "/Users/test/fixture"
        )
        #expect(noNames?.safeRelativeChangedPaths.isEmpty == true)
        #expect(noNames?.readerFacingDiagnosis.contains("did not expose the individual changed filenames") == true)
    }

    @Test func unrelatedGitFailureIsNotLabeledAsASourcePinRefusal() {
        let refusal = GuideAutopilotSourceCheckoutRefusal.detect(
            command: "git status --porcelain",
            exitStatus: 1,
            scrubbedOutputTail: "not a clean copy",
            workingDirectory: "/Users/test/fixture"
        )
        #expect(refusal == nil)
    }

    @Test func correctCleanPinRemainsRefusedAndExplainsTheMatchingSource() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceOwner: "Blueturboguy07",
            sourceRepo: "kneecap",
            sourceCommit: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
            sourceMetadataReader: { _ in
                GuideAutopilotSourceCheckoutMetadata(
                    head: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                    origin: "https://github.com/Blueturboguy07/kneecap.git",
                    porcelainOutput: "",
                    statusOutputWasTruncated: false
                )
            }
        )

        let result = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        #expect(result == .surfacedToReader)
        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("folder is named kneecap"))
        #expect(diagnosis.contains("source origin matches Blueturboguy07/kneecap"))
        #expect(diagnosis.contains("revision matches the guide pin"))
        #expect(diagnosis.contains("no changed paths"))
        #expect(diagnosis.contains("does not waive this refusal"))
    }

    @Test func correctDirtyPinNamesTrackedChangesAndFinderMetadataSeparately() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceOwner: "Blueturboguy07",
            sourceRepo: "kneecap",
            sourceCommit: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
            sourceMetadataReader: { _ in
                GuideAutopilotSourceCheckoutMetadata(
                    head: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                    origin: "git@github.com:Blueturboguy07/kneecap.git",
                    porcelainOutput: " M Sources/Editor.swift\n?? .DS_Store\n",
                    statusOutputWasTruncated: false
                )
            }
        )

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("tracked changes: Sources/Editor.swift"))
        #expect(diagnosis.contains("Finder metadata: .DS_Store"))
        #expect(!diagnosis.contains("untracked source paths: .DS_Store"))
    }

    @Test func dirtyWrongPinNamesOriginAndRevisionMismatchesButStillRefuses() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceOwner: "Blueturboguy07",
            sourceRepo: "kneecap",
            sourceCommit: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
            sourceMetadataReader: { _ in
                GuideAutopilotSourceCheckoutMetadata(
                    head: "0000000000000000000000000000000000000000",
                    origin: "https://github.com/other-owner/other-repo.git",
                    porcelainOutput: " M package.json\n",
                    statusOutputWasTruncated: false
                )
            }
        )

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("source origin does not match"))
        #expect(diagnosis.contains("revision does not match"))
        #expect(diagnosis.contains("tracked changes: package.json"))
    }

    @Test func absentCheckoutKeepsFolderNamedAndAllFreshFactsUnconfirmed() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/missing-copy"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/missing-copy")
        ])
        shell.modelTail = "missing-copy already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceOwner: "Blueturboguy07",
            sourceRepo: "kneecap",
            sourceCommit: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed"
        )

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("folder is named missing-copy"))
        #expect(diagnosis.contains("source origin is unconfirmed"))
        #expect(diagnosis.contains("revision is unconfirmed"))
        #expect(diagnosis.contains("changed paths are unconfirmed"))
    }

    @Test func unreadableOrTruncatedStatusStaysExplicitlyUnconfirmed() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceMetadataReader: { _ in
                GuideAutopilotSourceCheckoutMetadata(
                    head: nil,
                    origin: nil,
                    porcelainOutput: nil,
                    statusOutputWasTruncated: true
                )
            }
        )

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("Fresh Git status could not be confirmed"))
        #expect(diagnosis.contains("changed paths are unconfirmed"))
        #expect(!diagnosis.contains("status output was truncated"))
    }

    @Test func truncatedStatusNamesOnlyTheSafeBoundedPrefixAndSaysItWasCut() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceMetadataReader: { _ in
                GuideAutopilotSourceCheckoutMetadata(
                    head: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                    origin: "https://github.com/Blueturboguy07/kneecap.git",
                    porcelainOutput: " M Sources/Editor.swift\n?? notes/local.md\n",
                    statusOutputWasTruncated: true
                )
            }
        )

        _ = await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        )

        guard case .surfacedToReader(let diagnosis, _) = runner.state else { return }
        #expect(diagnosis.contains("tracked changes: Sources/Editor.swift"))
        #expect(diagnosis.contains("untracked source paths: notes/local.md"))
        #expect(diagnosis.contains("status output was truncated"))
    }

    @Test func staleSourceMetadataDoesNotDisplayAfterTheSessionEnds() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceMetadataReader: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return GuideAutopilotSourceCheckoutMetadata(
                    head: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                    origin: "https://github.com/Blueturboguy07/kneecap.git",
                    porcelainOutput: "",
                    statusOutputWasTruncated: false
                )
            }
        )
        let resultTask = Task { await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        ) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        await runner.endSession()
        #expect(await resultTask.value == .stopped)
        #expect(!runner.transcript.contains { entry in
            if case .explanation(let text) = entry {
                return text.contains("source origin matches")
            }
            return false
        })
    }

    @Test func cancelledSourceMetadataDoesNotDisplayAStaleDiagnosis() async {
        let shell = FakeShellSession(outcomes: [
            .succeeded(workingDirectory: "/Users/test/kneecap"),
            .failed(exitStatus: 1, workingDirectory: "/Users/test/kneecap")
        ])
        shell.modelTail = "kneecap already exists and is not a clean copy of this app's source."
        let runner = Self.runner(
            shell: shell,
            sourceMetadataReader: { _ in
                try? await Task.sleep(nanoseconds: 100_000_000)
                return GuideAutopilotSourceCheckoutMetadata(
                    head: "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                    origin: "https://github.com/Blueturboguy07/kneecap.git",
                    porcelainOutput: "",
                    statusOutputWasTruncated: false
                )
            }
        )
        let resultTask = Task { await runner.executeStepCommand(
            step: Self.sourcePinStep(), stepIndex: 5, totalSteps: 15
        ) }
        try? await Task.sleep(nanoseconds: 10_000_000)
        resultTask.cancel()
        #expect(await resultTask.value == .stopped)
        #expect(!runner.transcript.contains { entry in
            if case .explanation(let text) = entry {
                return text.contains("source origin matches")
            }
            return false
        })
    }

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
