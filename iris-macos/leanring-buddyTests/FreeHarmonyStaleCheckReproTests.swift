//
//  FreeHarmonyStaleCheckReproTests.swift
//  leanring-buddyTests
//
//  FreeHarmony fix round (Sep 2026), the finding that survived the first pass:
//  "recorded step-check is not invalidated when its underlying condition later
//  becomes false." Live repro: on the 'Run FreeHarmony' step, the reader went
//  Back to a step they had already passed (which correctly holds — Back must
//  not be a no-op — via `readerDeliberatelyReturnedToThisStep`), killed the
//  dev server the step depends on, then tapped "Let Iris run it" to have Iris
//  fix it. The command re-ran and the world genuinely became correct again,
//  but the guide never advanced: `startAutopilot()` never cleared the
//  Back-navigation latch, so `WatchLoop.onVerdict` kept discarding every
//  verdict forever, and from the reader's chair "Let Iris run it" read as a
//  dead button.
//
//  This is deliberately NOT wired through a real pty shell or a real
//  `localhost:3000` fetch — the defect is entirely in the flag/gating logic
//  between `GuideSessionController` and `WatchLoop`, so the step's own watch
//  expectation is a plain `foregroundApp` the test flips by hand, and the
//  step's own command is a real dev-server SHAPE ("pnpm dev", so
//  `GuideAutopilotCommandShape.holdsTheShellOpen` is true and the drive loop
//  takes the exact branch FreeHarmony's step took) run through a scripted
//  shell rather than a real `pnpm`.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct FreeHarmonyStaleCheckReproTests {

    /// Serves one small guide: a `clone` step nothing here drives, a `run`
    /// step shaped exactly like FreeHarmony's ("pnpm dev", so the drive loop
    /// starts it as a long-running side session and yields to the watch
    /// loop), and an `open` step after it — so `returnToThePreviousStep()` has
    /// somewhere later to return FROM.
    final class StaleCheckGuideURLProtocol: URLProtocol {
        static let watchedBundleIdentifier = "com.example.freeharmony-marker"

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let responseBody = Data(Self.guideJSON.utf8)
            guard let httpResponse = HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            // Nothing to unwind: the answer above is delivered synchronously.
        }

        static var guideJSON: String {
            """
            {
              "appSlug": "stale-check-repro",
              "appName": "Stale Check Repro",
              "version": 1,
              "status": "pilot",
              "sourceOwner": "Blueturboguy07",
              "sourceRepo": "stale-check-repro",
              "sourceCommit": null,
              "outputType": "local_web",
              "estimatedMinutes": 5,
              "readmeSectionIds": [],
              "branches": [
                {
                  "platform": "macos",
                  "target": null,
                  "label": "macOS",
                  "shell": "terminal",
                  "setupSteps": [],
                  "steps": [
                    {"id": "clone", "kind": "terminal", "title": "Copy it here", "body": "",
                     "command": "git clone https://example.invalid/stale-check-repro.git"},
                    {"id": "run", "kind": "terminal", "title": "Run the app", "body": "",
                     "command": "pnpm dev",
                     "watch": {"expect": [{"type": "foregroundApp", "bundleId": "\(watchedBundleIdentifier)"}]},
                     "verifierLabel": "localhost:3000 responds"},
                    {"id": "open", "kind": "open", "title": "Open the app", "body": "",
                     "href": "https://localhost-repro.invalid/"}
                  ],
                  "unsupported": null
                }
              ]
            }
            """
        }
    }

    private static func guideService() throws -> GuideService {
        let stubbedSessionConfiguration = URLSessionConfiguration.ephemeral
        stubbedSessionConfiguration.protocolClasses = [StaleCheckGuideURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "iris.stalecheck.tests.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
    }

    /// Polls a main-actor condition until it holds or the deadline passes, the
    /// same shape `GuideAutopilotResumeTests` uses: the drive loop runs in a
    /// detached `Task`, so a test observes its effects rather than awaiting a
    /// handle it does not expose.
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

    @Test("a verdict reached after 'Let Iris run it' is honored even after the reader went Back")
    func letIrisRunItSupersedesAnEarlierDeliberateBack() async throws {
        let localSignalSource = ScriptedWatchLoopLocalSignalSource()
        // Not the watched app yet — the step must not read as already done the
        // moment it is (re-)watched.
        localSignalSource.frontmostBundleIdentifier = "com.apple.Terminal"

        let watchLoop = WatchLoop(
            clock: VirtualWatchLoopClock(),
            frameSource: ScriptedWatchLoopFrameSource(),
            localSignalSource: localSignalSource,
            visualEvaluator: ScriptedWatchLoopVisualEvaluator(),
            preferencesStore: try #require(
                UserDefaults(suiteName: "iris.stalecheck.watchloop.\(UUID().uuidString)")
            ),
            // The test ticks it by hand; see `WatchLoopTests.makeWatchLoop`.
            drivesItsOwnTickTimer: false
        )

        let longRunningShell = GuideAutopilotResumeTests.ScriptedShell(
            [.succeeded(workingDirectory: "/tmp/stale-check-repro")]
        )
        let controller = GuideSessionController(
            guideService: try Self.guideService(),
            watchLoop: watchLoop,
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: GuideAutopilotResumeTests.ScriptedShell(
                        [.succeeded(workingDirectory: "/tmp/stale-check-repro")]
                    ),
                    longRunningSession: longRunningShell,
                    fixProposer: GuideAutopilotResumeTests.GiveUpProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )

        // Land directly on the 'open' step (index 2) — the shape of a reader
        // resuming a guide already past the run step.
        await controller.openGuide(
            slug: "stale-check-repro", requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: 2
        )
        #expect(controller.currentStepIndex == 2)

        // The reader taps Back, landing on 'run' exactly the way the live
        // FreeHarmony repro did ("58-back-to-8.png"). This correctly latches
        // `readerDeliberatelyReturnedToThisStep` so a stray watch signal
        // cannot turn Back into a no-op.
        controller.returnToThePreviousStep()
        #expect(controller.currentStepIndex == 1)

        // Consent seam: the reader has already granted autonomous control (or
        // grants it now on the modal), same shape as
        // `LunaraGuideRunnerCrossContaminationReproTests`.
        controller.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.stalecheck.grant.\(UUID().uuidString)")
            )
        )
        controller.confirmAutonomousControl = { true }

        // "Let Iris run it": re-runs the dev-server command from the top.
        controller.startAutopilot()

        let commandWasRerun = await pump {
            longRunningShell.commandsRun.contains { $0.contains("pnpm dev") }
        }
        #expect(commandWasRerun, "startAutopilot must actually re-run the step's command")

        // The world becomes what the step is waiting for.
        localSignalSource.frontmostBundleIdentifier = StaleCheckGuideURLProtocol.watchedBundleIdentifier
        await watchLoop.performOneWatchTick()

        // THE FIX: a verdict reached after the reader explicitly asked Iris to
        // run the step must be honored, not silently discarded because of an
        // earlier, unrelated Back navigation. Before the fix this stayed at
        // index 1 forever — the "Let Iris run it does nothing" bug.
        let advanced = await pump { controller.currentStepIndex == 2 }
        #expect(advanced, "a real verdict reached after 'Let Iris run it' must advance the guide")
    }
}
