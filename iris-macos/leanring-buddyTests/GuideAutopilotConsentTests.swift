//
//  GuideAutopilotConsentTests.swift
//  leanring-buddyTests
//
//  The security invariant the whole feature turns on: a crafted `iris://`
//  link can preselect a guide, a branch, and a step, but it can NEVER start
//  Iris executing commands. Opening a guide — by deep link or otherwise —
//  must leave autopilot stopped and nothing run. The only path to execution
//  is the reader tapping "Let Iris run it", i.e. `performPrimaryAction` on
//  the start case. These tests hold that line.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct GuideAutopilotConsentTests {

    /// A runner factory that records whether it was ever asked to build a
    /// runner. If a deep link ever constructs one, the invariant is broken.
    @MainActor
    final class SpyingRunnerFactory {
        private(set) var timesAskedToBuildARunner = 0

        func make(_ context: GuideAutopilotGuideContext) -> GuideAutopilotRunner {
            timesAskedToBuildARunner += 1
            return GuideAutopilotRunner(
                shellSession: NeverRunShellSession(),
                longRunningSession: NeverRunShellSession(),
                fixProposer: NeverProposeFixProposer(),
                guideContext: context
            )
        }
    }

    final class NeverRunShellSession: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/"
        var resolvedSearchPath: String?
        private(set) var numberOfCommandsRun = 0
        func start() async -> Bool { true }
        func run(_ command: GuideAutopilotApprovedCommand, deadline: TimeInterval) async -> GuideAutopilotCommandOutcome {
            numberOfCommandsRun += 1
            return .succeeded(workingDirectory: "/")
        }
        func cancelTheRunningCommand() async {}
        func endSession() async {}
        func tailForTheModel() -> String { "" }
    }

    final class NeverProposeFixProposer: GuideAutopilotFixProposing {
        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
    }

    private static func guideService() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedGuideURLProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "iris.consent.tests.\(UUID().uuidString)"))
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    @Test func noDeepLinkStartsAutopilotOrRunsACommand() async throws {
        // Every branch/step combination the stubbed guide offers.
        let stepIndices: [Int?] = [nil, 0, 1, 2, 5, 99]
        let branchKeys: [String?] = [nil, "macos:desktop", "windows:desktop", "not-a-branch"]

        for stepIndex in stepIndices {
            for branchKey in branchKeys {
                let spy = SpyingRunnerFactory()
                let controller = GuideSessionController(
                    guideService: try Self.guideService(),
                    makeAutopilotRunner: spy.make
                )
                await controller.openGuide(
                    slug: "cue",
                    requestedVersion: 2,
                    branchKeyFromDeepLink: branchKey,
                    stepIndexFromDeepLink: stepIndex
                )
                #expect(controller.autopilotIsRunning == false,
                        "deep link (branch \(branchKey ?? "nil"), step \(stepIndex.map(String.init) ?? "nil")) must not start autopilot")
                #expect(controller.numberOfCommandsAutopilotHasExecuted == 0,
                        "a deep link must execute nothing")
                #expect(spy.timesAskedToBuildARunner == 0,
                        "a deep link must not even construct a runner")
            }
        }
    }

    @Test func startAutopilotIsTheOnlyThingThatFlipsTheFlag() async throws {
        let spy = SpyingRunnerFactory()
        let controller = GuideSessionController(
            guideService: try Self.guideService(),
            makeAutopilotRunner: spy.make
        )
        await controller.openGuide(
            slug: "cue", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: nil
        )
        #expect(controller.autopilotIsRunning == false)

        // The one gesture that consents to execution.
        controller.startAutopilot()
        #expect(controller.autopilotIsRunning == true)
        #expect(spy.timesAskedToBuildARunner == 1)

        controller.stopAutopilot()
        #expect(controller.autopilotIsRunning == false)
    }

    @Test func withoutARunnerFactoryTheStartGestureDoesNothing() async throws {
        // A controller opened without autopilot support (no factory) must
        // treat the start gesture as a no-op, never a crash.
        let controller = GuideSessionController(guideService: try Self.guideService())
        await controller.openGuide(
            slug: "cue", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: nil
        )
        controller.startAutopilot()
        #expect(controller.autopilotIsRunning == false)
    }
}
