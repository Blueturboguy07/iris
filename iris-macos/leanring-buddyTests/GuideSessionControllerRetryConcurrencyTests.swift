//
//  GuideSessionControllerRetryConcurrencyTests.swift
//  leanring-buddyTests
//
//  These are controller-level regressions for the surfaced-step retry button.
//  The fake shell suspends only the environment refresh, so the tests can put
//  a second tap, Skip, navigation, or a stop between the refresh and command.
//  No pty, network, model, app, or reader profile is used.
//

import Foundation
import Testing
#if IRIS_HARNESS_STANDALONE
@testable import IrisHarnessNative
#else
@testable import Iris
#endif

@MainActor
struct GuideSessionControllerRetryConcurrencyTests {

    // MARK: - Fakes

    /// The refresh command is a real runner call, but its result is held until
    /// the test releases it. Ordinary guide commands are recorded and the
    /// retry failure count is configurable so each race can choose its own
    /// deterministic outcome.
    @MainActor
    final class SuspendedRetryShell: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/test/retry-concurrency"
        var resolvedSearchPath: String? = "/usr/bin:/bin"

        private(set) var commandsRun: [String] = []
        private(set) var refreshRequestCount = 0
        private(set) var retryCommandAttempts = 0
        private(set) var pendingRefreshCount = 0
        private(set) var pendingRetryCommandCount = 0
        private(set) var pendingStartCount = 0
        var releaseRefreshesWhenEnded = true
        var suspendRetryCommands = false
        var suspendNextStart = false

        private var pendingStarts: [CheckedContinuation<Bool, Never>] = []
        private var pendingRefreshes: [CheckedContinuation<GuideAutopilotCommandOutcome, Never>] = []
        private var pendingRetryCommands: [
            (CheckedContinuation<GuideAutopilotCommandOutcome, Never>, GuideAutopilotCommandOutcome)
        ] = []
        private let failuresBeforeSuccess: Int

        init(failuresBeforeSuccess: Int = 1) {
            self.failuresBeforeSuccess = max(0, failuresBeforeSuccess)
        }

        func start() async -> Bool {
            guard suspendNextStart else { return true }
            suspendNextStart = false
            pendingStartCount += 1
            return await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                pendingStarts.append(continuation)
            }
        }

        func run(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            _ = deadline
            if command.text == GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand {
                refreshRequestCount += 1
                pendingRefreshCount += 1
                return await withCheckedContinuation {
                    (continuation: CheckedContinuation<GuideAutopilotCommandOutcome, Never>) in
                    pendingRefreshes.append(continuation)
                }
            }

            commandsRun.append(command.text)
            if command.text == "retry-command" {
                retryCommandAttempts += 1
                let outcome: GuideAutopilotCommandOutcome = retryCommandAttempts <= failuresBeforeSuccess
                    ? .failed(
                        exitStatus: 1,
                        workingDirectory: currentWorkingDirectory
                      )
                    : .succeeded(workingDirectory: currentWorkingDirectory)
                guard suspendRetryCommands else { return outcome }
                pendingRetryCommandCount += 1
                return await withCheckedContinuation {
                    (continuation: CheckedContinuation<GuideAutopilotCommandOutcome, Never>) in
                    pendingRetryCommands.append((continuation, outcome))
                }
            }
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }

        func cancelTheRunningCommand() async {
            releaseAllRefreshes()
        }

        func endSession() async {
            if releaseRefreshesWhenEnded {
                releaseAllRefreshes()
            }
        }

        func tailForTheModel() -> String { "" }

        func releaseNextRefresh(
            with outcome: GuideAutopilotCommandOutcome = .succeeded(
                workingDirectory: "/Users/test/retry-concurrency"
            )
        ) {
            guard !pendingRefreshes.isEmpty else { return }
            let continuation = pendingRefreshes.removeFirst()
            pendingRefreshCount -= 1
            continuation.resume(returning: outcome)
        }

        func releaseNextStart() {
            guard !pendingStarts.isEmpty else { return }
            let continuation = pendingStarts.removeFirst()
            pendingStartCount -= 1
            continuation.resume(returning: true)
        }

        func releaseNextRetryCommand() {
            guard !pendingRetryCommands.isEmpty else { return }
            let pending = pendingRetryCommands.removeFirst()
            pendingRetryCommandCount -= 1
            pending.0.resume(returning: pending.1)
        }

        func releaseAllRefreshes() {
            while !pendingStarts.isEmpty {
                releaseNextStart()
            }
            while !pendingRefreshes.isEmpty {
                releaseNextRefresh()
            }
            while !pendingRetryCommands.isEmpty {
                releaseNextRetryCommand()
            }
        }
    }

    @MainActor
    final class ImmediateShell: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/test/retry-concurrency"
        var resolvedSearchPath: String? = "/usr/bin:/bin"

        func start() async -> Bool { true }
        func run(
            _ command: GuideAutopilotApprovedCommand,
            deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            _ = command
            _ = deadline
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
        func cancelTheRunningCommand() async {}
        func endSession() async {}
        func tailForTheModel() -> String { "" }
    }

    final class NoFixProposer: GuideAutopilotFixProposing {
        func proposeFix(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? {
            _ = context
            return nil
        }

        func proposeFixWithWebSearch(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? {
            _ = context
            return nil
        }
    }

    private struct Fixture {
        let controller: GuideSessionController
        let shell: SuspendedRetryShell
        let defaults: UserDefaults
        let suiteName: String
    }

    // MARK: - Tests

    @Test("duplicate Try again taps refresh the shell once")
    func duplicateRetryTapsDoNotStartTwoRefreshes() async throws {
        let fixture = try Self.makeFixture()
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        fixture.controller.retryTheSurfacedStep()
        fixture.controller.retryTheSurfacedStep()

        let refreshStarted = await Self.pump {
            fixture.shell.refreshRequestCount == 1
        }
        #expect(refreshStarted, "the first tap must reach the suspended refresh")
        #expect(fixture.shell.refreshRequestCount == 1)
        #expect(fixture.shell.retryCommandAttempts == 1,
                "the retry command must wait for its one refresh")

        fixture.shell.releaseNextRefresh()
        let finished = await Self.pump {
            fixture.controller.readerHasFinishedTheGuide
        }
        #expect(finished, "the one accepted retry should finish the two-step fixture")
        #expect(fixture.shell.refreshRequestCount == 1)
        #expect(fixture.shell.retryCommandAttempts == 2,
                "one initial failure and one accepted retry are expected")
    }

    @Test("Skip cannot advance while Try again owns the surfaced step")
    func skipDuringRetryDoesNotAdvanceTheGuide() async throws {
        let fixture = try Self.makeFixture()
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)
        let surfacedIndex = fixture.controller.currentStepIndex

        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })

        fixture.controller.skipTheSurfacedStepAndContinue()

        #expect(fixture.controller.currentStepIndex == surfacedIndex,
                "Skip must not move the guide under an in-flight retry")
        #expect(fixture.controller.autopilotIsRunning)
        #expect(fixture.shell.retryCommandAttempts == 1,
                "Skip must not let the suspended retry reach the command")

        fixture.shell.releaseNextRefresh()
        let finished = await Self.pump {
            fixture.controller.readerHasFinishedTheGuide
        }
        #expect(finished, "the owned retry should still be able to finish")
    }

    @Test("stop and navigation cancel a suspended retry before its command")
    func stopOrNavigationWhileRefreshingCannotAdvance() async throws {
        let stopFixture = try Self.makeFixture()
        defer {
            stopFixture.shell.releaseAllRefreshes()
            stopFixture.controller.stopAutopilot()
            stopFixture.defaults.removePersistentDomain(forName: stopFixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: stopFixture.controller)
        let stoppedIndex = stopFixture.controller.currentStepIndex
        stopFixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { stopFixture.shell.pendingRefreshCount == 1 })

        stopFixture.controller.stopAutopilot()

        let stopSettled = await Self.pump {
            stopFixture.shell.pendingRefreshCount == 0
                && stopFixture.controller.autopilotRunner == nil
        }
        #expect(stopSettled, "stopping must settle the suspended refresh")
        #expect(stopFixture.shell.retryCommandAttempts == 1)
        #expect(stopFixture.controller.currentStepIndex == stoppedIndex)
        #expect(!stopFixture.controller.readerHasFinishedTheGuide)

        let navigationFixture = try Self.makeFixture()
        defer {
            navigationFixture.shell.releaseAllRefreshes()
            navigationFixture.controller.stopAutopilot()
            navigationFixture.defaults.removePersistentDomain(forName: navigationFixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: navigationFixture.controller)
        #expect(navigationFixture.controller.currentStepIndex == 1)
        navigationFixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { navigationFixture.shell.pendingRefreshCount == 1 })

        navigationFixture.controller.returnToThePreviousStep()

        let navigationSettled = await Self.pump {
            navigationFixture.shell.pendingRefreshCount == 0
                && navigationFixture.controller.autopilotRunner == nil
        }
        #expect(navigationSettled, "navigation must cancel and settle the retry")
        #expect(navigationFixture.controller.currentStepIndex == 0,
                "Back should leave the reader on the selected earlier step")
        #expect(navigationFixture.shell.retryCommandAttempts == 1,
                "a stale retry must not run after navigation")
        #expect(!navigationFixture.controller.readerHasFinishedTheGuide)
    }

    @Test("an old retry completion cannot clear a newer retry")
    func staleRetryCompletionCannotReleaseNewRetryOwnership() async throws {
        let fixture = try Self.makeFixture(
            failuresBeforeSuccess: 2,
            releaseRefreshesWhenEnded: false
        )
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        // The first retry is left suspended even when its runner is stopped.
        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })
        fixture.controller.restartTheGuide()
        #expect(fixture.controller.currentStepIndex == 0)
        #expect(!fixture.controller.autopilotIsRunning)

        // A new run surfaces the same step and owns a new retry token.
        fixture.controller.startAutopilot()
        let surfacedAgain = await Self.pump {
            fixture.controller.currentStepIndex == 1
                && fixture.controller.autopilotHandedTheCurrentStepToTheReader
        }
        #expect(surfacedAgain, "the replacement run must surface its own failure")
        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 2 })
        #expect(fixture.shell.refreshRequestCount == 2)

        // Complete the cancelled retry first. If it clears the replacement's
        // ownership, Skip below will incorrectly advance the guide.
        fixture.shell.releaseNextRefresh()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })
        fixture.controller.skipTheSurfacedStepAndContinue()
        #expect(fixture.controller.currentStepIndex == 1,
                "a stale completion must not release the newer retry")
        #expect(fixture.shell.retryCommandAttempts == 2,
                "the old retry must not run its command")

        fixture.shell.releaseNextRefresh()
        let finished = await Self.pump {
            fixture.controller.readerHasFinishedTheGuide
        }
        #expect(finished, "the newer retry should remain live after the stale one settles")
        #expect(fixture.shell.retryCommandAttempts == 3,
                "two surfaced failures plus only the newer retry command are expected")
    }

    @Test("a late command from a stopped runner cannot advance or unlock its replacement")
    func lateCommandFromStoppedRunnerCannotAdvanceReplacementRun() async throws {
        let fixture = try Self.makeFixture(
            failuresBeforeSuccess: 1,
            releaseRefreshesWhenEnded: false
        )
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        // Keep the first runner's successful retry command suspended even after
        // Stop. A later completion from that runner must not touch the run that
        // replaces it.
        fixture.shell.suspendRetryCommands = true
        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })
        fixture.shell.releaseNextRefresh()
        #expect(await Self.pump { fixture.shell.pendingRetryCommandCount == 1 })

        fixture.controller.stopAutopilot()
        #expect(await Self.pump { fixture.controller.autopilotRunner == nil })

        // Start a new runner on the same surfaced step. Its command is also
        // suspended, so the old completion has a live replacement lock to
        // preserve. Both attempts are successful; only the replacement may
        // advance the guide.
        fixture.controller.startAutopilot()
        #expect(await Self.pump {
            fixture.shell.pendingRetryCommandCount == 2
                && fixture.controller.autopilotRunner?.isExecutingACommand == true
        })
        #expect(fixture.controller.currentStepIndex == 1)
        #expect(fixture.shell.retryCommandAttempts == 3)

        fixture.shell.releaseNextRetryCommand()
        #expect(await Self.pump { fixture.shell.pendingRetryCommandCount == 1 })
        #expect(
            fixture.controller.currentStepIndex == 1,
            "the old runner's completion must not advance the replacement guide"
        )
        #expect(
            fixture.controller.autopilotRunner?.isExecutingACommand == true,
            "the old completion must not clear the replacement runner's command lock"
        )

        fixture.shell.releaseNextRetryCommand()
        #expect(await Self.pump { fixture.controller.readerHasFinishedTheGuide })
    }

    @Test("a late start from a stopped runner cannot clear its replacement drive")
    func lateStartFromStoppedRunnerCannotClearReplacementDrive() async throws {
        let fixture = try Self.makeFixture(
            failuresBeforeSuccess: 1,
            releaseRefreshesWhenEnded: false
        )
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        // Runner A is suspended in startSession and then stopped. Runner B
        // starts on the same surfaced step while A's start is still pending.
        fixture.controller.stopAutopilot()
        fixture.shell.suspendNextStart = true
        fixture.controller.startAutopilot()
        #expect(await Self.pump { fixture.shell.pendingStartCount == 1 })
        fixture.controller.stopAutopilot()

        fixture.shell.suspendRetryCommands = true
        fixture.controller.startAutopilot()
        #expect(await Self.pump {
            fixture.shell.pendingRetryCommandCount == 1
                && fixture.controller.autopilotRunner?.isExecutingACommand == true
        })

        fixture.shell.releaseNextStart()
        #expect(await Self.pump { fixture.shell.pendingStartCount == 0 })
        #expect(fixture.controller.currentStepIndex == 1)
        #expect(
            fixture.controller.autopilotRunner?.isExecutingACommand == true,
            "the stale start completion must not clear the replacement drive"
        )
        #expect(fixture.shell.retryCommandAttempts == 2)

        fixture.shell.releaseNextRetryCommand()
        #expect(await Self.pump { fixture.controller.readerHasFinishedTheGuide })
    }

    @Test("a failed environment refresh does not run the retry command")
    func failedRefreshDoesNotExecuteRetryCommand() async throws {
        let fixture = try Self.makeFixture()
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })
        fixture.shell.releaseNextRefresh(
            with: .failed(
                exitStatus: 1,
                workingDirectory: fixture.shell.currentWorkingDirectory
            )
        )

        let handedBack = await Self.pump {
            fixture.controller.autopilotHandedTheCurrentStepToTheReader
        }
        #expect(handedBack, "a failed refresh should return the step to the reader")
        #expect(fixture.shell.retryCommandAttempts == 1,
                "the original failure is the only retry-command attempt")
        #expect(fixture.controller.currentStepIndex == 1)
    }

    @Test("a retry publishes running command state while its command is in flight")
    func retryPublishesRunningCommandState() async throws {
        let fixture = try Self.makeFixture()
        defer {
            fixture.shell.releaseAllRefreshes()
            fixture.controller.stopAutopilot()
            fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        }
        try await Self.surfaceTheRetryStep(in: fixture.controller)

        fixture.shell.suspendRetryCommands = true
        fixture.controller.retryTheSurfacedStep()
        #expect(await Self.pump { fixture.shell.pendingRefreshCount == 1 })
        if let runner = fixture.controller.autopilotRunner {
            #expect(runner.state == .running(stepIndex: 1))
            #expect(runner.isExecutingACommand)
        } else {
            #expect(Bool(false), "the active runner must expose refresh work")
        }
        fixture.shell.releaseNextRefresh()

        let commandInFlight = await Self.pump {
            fixture.shell.pendingRetryCommandCount == 1
                && fixture.controller.autopilotRunner?.isExecutingACommand == true
        }
        #expect(commandInFlight, "the retry command should remain observable while suspended")
        if let runner = fixture.controller.autopilotRunner {
            #expect(runner.state == .running(stepIndex: 1))
            #expect(runner.isExecutingACommand)
        } else {
            #expect(Bool(false), "the active runner must remain available during retry")
        }

        fixture.shell.releaseNextRetryCommand()
        let finished = await Self.pump {
            fixture.controller.readerHasFinishedTheGuide
        }
        #expect(finished, "releasing the command should complete the fixture")
    }

    // MARK: - Fixture

    private static func makeFixture(
        failuresBeforeSuccess: Int = 1,
        releaseRefreshesWhenEnded: Bool = true
    ) throws -> Fixture {
        let shell = SuspendedRetryShell(failuresBeforeSuccess: failuresBeforeSuccess)
        shell.releaseRefreshesWhenEnded = releaseRefreshesWhenEnded
        let suiteName = "iris.guide.retry-concurrency.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryConcurrencyGuideURLProtocol.self]
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
        let controller = GuideSessionController(
            guideService: guideService,
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) 1.0")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: ImmediateShell(),
                    fixProposer: NoFixProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.lastFollowedGuideMemory = LastFollowedGuideMemory(userDefaults: defaults)
        controller.autonomyGrant = AutopilotAutonomyGrant(userDefaults: defaults)
        controller.confirmAutonomousControl = { true }
        return Fixture(controller: controller, shell: shell, defaults: defaults, suiteName: suiteName)
    }

    private static func surfaceTheRetryStep(
        in controller: GuideSessionController
    ) async throws {
        await controller.openLatestVersionOfGuide(slug: "retry-concurrency")
        controller.startAutopilot()
        let surfaced = await pump {
            controller.currentStepIndex == 1
                && controller.autopilotHandedTheCurrentStepToTheReader
        }
        try #require(surfaced, "the fixture must surface its failing retry step")
    }

    private static func pump(
        within seconds: Double = 3,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

#if GUIDE_RETRY_WINDOW_PROBE
/// Bridge used only by the manual window probe. It keeps the probe on the same
/// controller and suspended shell fixture as the executable regressions.
@MainActor
struct GuideRetryWindowProbeFixture {
    let controller: GuideSessionController
    let shell: GuideSessionControllerRetryConcurrencyTests.SuspendedRetryShell
    let defaults: UserDefaults
    let suiteName: String
}

extension GuideSessionControllerRetryConcurrencyTests {
    @MainActor
    static func makeWindowProbeFixture() throws -> GuideRetryWindowProbeFixture {
        let fixture = try makeFixture(releaseRefreshesWhenEnded: false)
        return GuideRetryWindowProbeFixture(
            controller: fixture.controller,
            shell: fixture.shell,
            defaults: fixture.defaults,
            suiteName: fixture.suiteName
        )
    }
}
#endif

/// Serves a two-step desktop guide from memory. URLSession still exercises the
/// GuideService/controller loading path, but no network request can escape this
/// test process.
final class RetryConcurrencyGuideURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let responseBody = Data(Self.guideJSON.utf8)
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let guideJSON = """
    {
      "appSlug": "retry-concurrency",
      "appName": "Retry concurrency fixture",
      "version": 1,
      "status": "pilot",
      "sourceOwner": "test",
      "sourceRepo": "retry-concurrency",
      "sourceCommit": null,
      "outputType": "desktop_app",
      "estimatedMinutes": 1,
      "readmeSectionIds": [],
      "reviewNote": null,
      "branches": [
        {
          "platform": "macos",
          "target": null,
          "label": "macOS",
          "shell": "terminal",
          "setupSteps": [],
          "steps": [
            {
              "id": "prime",
              "kind": "terminal",
              "title": "Prepare the fixture",
              "body": "",
              "command": "prime-command"
            },
            {
              "id": "retry-step",
              "kind": "terminal",
              "title": "Run the retry step",
              "body": "",
              "command": "retry-command"
            }
          ],
          "unsupported": null
        }
      ]
    }
    """
}
