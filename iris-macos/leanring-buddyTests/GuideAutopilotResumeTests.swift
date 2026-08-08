//
//  GuideAutopilotResumeTests.swift
//  leanring-buddyTests
//
//  The bug this pins: the first live run stopped the whole install dead the
//  moment Iris hit one step it could not clear on its own. A surfaced step must
//  hand control back — release Iris's ownership so the watch loop is free to
//  notice the reader finished it — and both the reader's ways out ("Continue
//  past it" and "Try again") must put the install back in motion rather than
//  leave it stalled.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct GuideAutopilotResumeTests {

    // MARK: - Fakes

    /// A shell whose outcomes are scripted in order; the last repeats. Records
    /// every command it was asked to run, so a retry is observable.
    final class ScriptedShell: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/x/app"
        var resolvedSearchPath: String? = "/usr/bin:/bin"
        private var outcomes: [GuideAutopilotCommandOutcome]
        private(set) var commandsRun: [String] = []

        init(_ outcomes: [GuideAutopilotCommandOutcome]) { self.outcomes = outcomes }

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async {}
        func tailForTheModel() -> String { "" }

        func run(
            _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            if outcomes.count > 1 { return outcomes.removeFirst() }
            return outcomes.first ?? .succeeded(workingDirectory: currentWorkingDirectory)
        }
    }

    /// Never offers a fix, so a failing command climbs the ladder and surfaces
    /// rather than being repaired — exactly the "Iris can't do it" case.
    final class GiveUpProposer: GuideAutopilotFixProposing {
        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
    }

    // MARK: - Harness

    private static func guideService() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedGuideURLProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "iris.resume.tests.\(UUID().uuidString)"))
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    /// Opens the stubbed cue guide on the `clone` step (index 2) — the first
    /// step autopilot actually executes — with a shell driven by `outcomes`,
    /// starts autopilot, and returns the controller and the shell to inspect.
    private static func startOnTheCloneStep(
        outcomes: [GuideAutopilotCommandOutcome]
    ) async throws -> (GuideSessionController, ScriptedShell) {
        let shell = ScriptedShell(outcomes)
        let controller = GuideSessionController(
            guideService: try guideService(),
            // Report every prerequisite present so the setup-recovery detour
            // never fires and blocks the start gesture — this test is about the
            // install steps, not the prerequisites.
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: ScriptedShell([.succeeded(workingDirectory: "/x")]),
                    fixProposer: GiveUpProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        await controller.openGuide(
            slug: "cue", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: 2
        )
        controller.startAutopilot()
        return (controller, shell)
    }

    /// Polls a main-actor condition until it holds or the deadline passes.
    /// The drive loop runs in a Task, so tests observe its effects rather than
    /// awaiting a handle it does not expose.
    private func pump(
        within seconds: Double = 5,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return condition()
    }

    // MARK: - Tests

    @Test func aSurfacedGateReleasesOwnershipSoTheInstallIsNotStuck() async throws {
        // The clone command fails and stays failed; with no fix on offer it
        // surfaces to the reader.
        let (controller, shell) = try await Self.startOnTheCloneStep(
            outcomes: [.failed(exitStatus: 1, workingDirectory: "/x")]
        )

        let surfaced = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        #expect(surfaced, "a failing command with no fix must surface and hand the step back")
        #expect(shell.commandsRun.contains { $0.contains("git clone") })

        // The fix: once surfaced, autopilot no longer owns the step, so the
        // watch loop is free to notice the reader finished it and advance —
        // which is what resumes the install. Before the fix this stayed true
        // and the whole install stopped dead here.
        #expect(controller.autopilotOwnsTheCurrentStep == false)
        #expect(controller.autopilotIsRunning == true,
                "autopilot stays on across the gate — it is handed back, not torn down")
    }

    @Test func continuePastASurfacedStepMovesTheInstallOn() async throws {
        let (controller, _) = try await Self.startOnTheCloneStep(
            outcomes: [.failed(exitStatus: 1, workingDirectory: "/x")]
        )
        _ = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        let surfacedIndex = controller.currentStepIndex

        controller.skipTheSurfacedStepAndContinue()

        #expect(controller.currentStepIndex == surfacedIndex + 1,
                "Continue must move past the surfaced step")
        #expect(controller.autopilotHandedTheCurrentStepToTheReader == false,
                "the new step is Iris's again, so the hand-back is cleared")
    }

    @Test func retryReRunsTheStepAndCarriesOnWhenItWorks() async throws {
        // The clone fails the first time and succeeds on the retry.
        let (controller, shell) = try await Self.startOnTheCloneStep(
            outcomes: [
                .failed(exitStatus: 1, workingDirectory: "/x"),
                .succeeded(workingDirectory: "/x"),
            ]
        )
        _ = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        let surfacedIndex = controller.currentStepIndex

        controller.retryTheSurfacedStep()

        let movedOn = await pump { controller.currentStepIndex > surfacedIndex }
        #expect(movedOn, "a successful retry must carry the install forward on its own")
        #expect(shell.commandsRun.filter { $0.contains("git clone") }.count == 2,
                "retry re-runs the same command, so the clone was attempted twice")
    }
}
