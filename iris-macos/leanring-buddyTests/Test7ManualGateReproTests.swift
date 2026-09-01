//
//  Test7ManualGateReproTests.swift
//  leanring-buddyTests
//
//  Test 7, the reader's words: "The I did it - continue button is not working
//  when trying to install cmake."
//
//  Iris parked the takeover on the CMake gate with `readerMustManuallyContinue`
//  true, and then nothing the reader did moved it on — the install only picked
//  up again after they quit and relaunched Iris. The same gate stalled in
//  Test 6, and the reader hit it again on WhimprFlow's permission steps, so
//  whatever it is has to be about MANUAL GATES, not about CMake.
//
//  This file splits the button into the two halves that can each be the dead
//  one, and pins the half that can be measured without a screen:
//
//    1. THE HANDLER. Given a takeover genuinely parked at a manual gate,
//       does `readerFinishedTheGatedStep()` actually put the install back in
//       motion — advance the step AND resume the drive loop that returned out
//       of itself at the gate? That is what these tests answer, end to end,
//       through the real controller and the real runner with a scripted shell.
//
//    2. THE CLICK. Whether the press ever reaches the button at all is a
//       window-server question, and the answer is in
//       `Test7TakeoverClickReachabilityTests`.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct Test7ManualGateReproTests {

    // MARK: - Fakes

    /// A shell that records what it was asked to run and always succeeds. What
    /// matters here is not what the commands do — it is whether the command
    /// AFTER the gate is ever run at all.
    final class RecordingShell: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/x/whimprflow"
        var resolvedSearchPath: String? = "/usr/bin:/bin"
        private(set) var commandsRun: [String] = []

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async {}
        func tailForTheModel() -> String { "" }

        func run(
            _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
    }

    /// Never proposes a fix, so nothing here can be rescued by the repair loop
    /// and the only thing that moves the install on is the gate being cleared.
    final class NoFixProposer: GuideAutopilotFixProposing {
        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
    }

    // MARK: - The guide: WhimprFlow's shape, reduced to the gate

    /// Serves one guide whose steps are, in order: a command Iris can run, a
    /// manual gate it cannot (install CMake — a `.dmg` drag, with no signal on
    /// this Mac to confirm it), and then the command that only runs if the gate
    /// is cleared. That last command is the whole assertion: the reader's
    /// "progress" is a command running, not a step index moving.
    final class GatedGuideURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = Data(Self.gatedGuideJSON.utf8)
            guard let response = HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// The `permission` gate carries no `watch` on purpose: dragging
        /// CMake.app into /Applications leaves `cmake` off the PATH until the
        /// reader also installs its command line tools, which is exactly why
        /// this step has nothing for the watch loop to confirm and exactly why
        /// the reader has to be the one to say they did it.
        static let gatedGuideJSON = """
        {
          "appSlug": "gated",
          "appName": "Gated",
          "version": 1,
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "gated",
          "sourceCommit": null,
          "outputType": "desktop_app",
          "estimatedMinutes": 10,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": null,
              "label": "macOS",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "clone", "kind": "terminal", "title": "Copy it to this Mac",
                 "body": "", "command": "git clone https://github.com/Blueturboguy07/gated.git"},
                {"id": "install-cmake", "kind": "permission", "title": "Install CMake",
                 "body": "Download the CMake .dmg and drag CMake into Applications."},
                {"id": "build", "kind": "terminal", "title": "Build it",
                 "body": "", "command": "cargo tauri build"},
                {"id": "finish", "kind": "terminal", "title": "Put it in Applications",
                 "body": "", "command": "cp -R target/release/bundle/macos/Gated.app /Applications"}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }

    // MARK: - Harness

    /// Opens the gated guide, starts autopilot, and drives it until it parks on
    /// the CMake gate. Returns everything the assertions need to see: the
    /// controller, the shell that records commands, and what the takeover was
    /// told to put on the parked card.
    private static func driveToTheCMakeGate() async throws -> (
        controller: GuideSessionController,
        shell: RecordingShell,
        gateTitles: GateRecorder
    ) {
        let shell = RecordingShell()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatedGuideURLProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "iris.test7.gate.\(UUID().uuidString)"))
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
        let controller = GuideSessionController(
            guideService: guideService,
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: RecordingShell(),
                    fixProposer: NoFixProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // The one-time autonomy grant is machine state (it lives in
        // UserDefaults), and this test must not depend on whether some other
        // run happened to leave it on.
        controller.confirmAutonomousControl = { true }
        let gateTitles = GateRecorder()
        controller.onAutopilotWaitingForReaderAtGate = { title, instruction in
            gateTitles.record(title: title, instruction: instruction)
        }
        await controller.openLatestVersionOfGuide(slug: "gated")
        controller.startAutopilot()
        let parked = await pump(within: 12) { gateTitles.titles.isEmpty == false }
        #expect(parked, "autopilot must reach the manual CMake gate before this test means anything")
        return (controller, shell, gateTitles)
    }

    /// What `onAutopilotWaitingForReaderAtGate` was handed — the same values
    /// `CompanionManager` forwards to the takeover's parked card.
    @MainActor
    final class GateRecorder {
        private(set) var titles: [String] = []
        private(set) var instructions: [String] = []
        func record(title: String, instruction: String) {
            titles.append(title)
            instructions.append(instruction)
        }
    }

    /// Polls a main-actor condition until it holds or the deadline passes. The
    /// drive loop runs in a detached Task, so its effects are observed rather
    /// than awaited.
    private static func pump(
        within seconds: Double = 6, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - The reader's sentence, as a test

    /// THE REPRO. Park on the manual gate, tap "I did it — continue", and the
    /// install has to carry on by itself — the command after the gate has to
    /// actually run. A step index that moves while no command ever runs is the
    /// same stall the reader reported, dressed up as progress.
    @Test func theContinueButtonAtAManualGateRestartsTheInstall() async throws {
        let (controller, shell, gateTitles) = try await Self.driveToTheCMakeGate()

        #expect(gateTitles.titles.last == "Install CMake")
        #expect(shell.commandsRun.contains { $0.contains("git clone") },
                "the step before the gate must have run, or the gate was reached the wrong way")
        #expect(shell.commandsRun.contains { $0.contains("cargo tauri build") } == false,
                "the command after the gate must not have run yet")

        // The tap.
        controller.readerFinishedTheGatedStep()

        let carriedOn = await Self.pump(within: 8) {
            shell.commandsRun.contains { $0.contains("cargo tauri build") }
        }
        #expect(
            carriedOn,
            """
            "I did it — continue" moved the step to \(controller.currentStepIndex) but never ran \
            the command after the gate — commands run were \(shell.commandsRun). That is the \
            reader's "the I did it - continue button is not working": the gate clears on paper \
            and the install stands still.
            """
        )
    }

    /// The same gesture at the LAST kind of gate the reader hit — a permission
    /// step in WhimprFlow — must leave autopilot alive rather than tearing the
    /// run down, because the steps after it are Iris's to run.
    @Test func clearingAGateLeavesAutopilotRunningAndOwningTheNextStep() async throws {
        let (controller, _, _) = try await Self.driveToTheCMakeGate()
        let gateIndex = controller.currentStepIndex

        controller.readerFinishedTheGatedStep()

        #expect(controller.currentStepIndex == gateIndex + 1,
                "the gate step is behind the reader once they say they did it")
        #expect(controller.autopilotIsRunning,
                "clearing a gate is not an ending — Iris still has the rest of the install to run")
        #expect(controller.autopilotHandedTheCurrentStepToTheReader == false,
                "the step after the gate is Iris's again, not the reader's")
    }

    /// A second tap on a card the reader is looking at (they tapped, nothing
    /// visibly happened, they tapped again — which is exactly what a reader
    /// does with a button they believe is broken) must not skip a step of the
    /// install.
    @Test func aSecondTapDoesNotSkipTheStepAfterTheGate() async throws {
        let (controller, shell, _) = try await Self.driveToTheCMakeGate()
        let gateIndex = controller.currentStepIndex

        controller.readerFinishedTheGatedStep()
        controller.readerFinishedTheGatedStep()

        _ = await Self.pump(within: 8) {
            shell.commandsRun.contains { $0.contains("cargo tauri build") }
        }
        #expect(
            shell.commandsRun.contains { $0.contains("cargo tauri build") },
            "the step right after the gate must still run — commands were \(shell.commandsRun)"
        )
        #expect(controller.currentStepIndex >= gateIndex + 1)
    }
}
