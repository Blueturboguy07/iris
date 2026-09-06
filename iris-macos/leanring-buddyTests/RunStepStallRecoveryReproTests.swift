//
//  RunStepStallRecoveryReproTests.swift
//  leanring-buddyTests
//
//  Nutcracker live fix round (Sep 2026), finding: "Hands-off autopilot
//  silently hangs on the dev-server step; its Next button is hidden behind
//  the terminal window with zero recovery affordance."
//
//  Live repro: once `npm run dev` was marked `.longRunningStarted`, the drive
//  loop's own comment says "the watch loop owns completion" and just
//  `return`s — unlike every OTHER step the drive loop cannot finish itself
//  (the `stepIsAutopilotExecutable == false` / MANUAL branch just above it in
//  `driveAutopilotFromTheCurrentStep`), which calls
//  `handTheCurrentStepBackToTheReader()` + `onAutopilotWaitingForReaderAtGate`
//  so the takeover terminal parks aside instead of sitting centered and
//  full-size. A long-running step got none of that: the terminal stayed a
//  full, centered takeover for as long as the watch loop took (or forever, if
//  it never fired), fully occluding the guide's own step card — checkbox and
//  Next button included — with no gate bar, no pointer, and no working
//  "I did it — continue" escape hatch underneath it. iris.log showed 5m21s of
//  silence; the run only continued because of an accidental mis-click that
//  happened to land on the hidden Next button.
//
//  This pins the fix at the level that does not need a screen: the moment a
//  step with a real `watch` goes `.longRunningStarted`, the SAME hand-back
//  hooks the manual branch already uses must fire, and the SAME "I did it —
//  continue" button the manual branch already wires up must actually move the
//  guide on — not read as live and do nothing, which is the exact class of
//  dead-button bug `Test7ManualGateReproTests` already exists to keep fixed
//  for manual steps.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct RunStepStallRecoveryReproTests {

    /// Serves one guide shaped like Nutcracker's own `clone → run → open`:
    /// the `run` step carries a real `watch` (so the drive loop takes the
    /// "yields to the watch loop" branch of `.longRunningStarted`, never the
    /// no-watch auto-advance branch), and its command is a dev-server shape
    /// so `GuideAutopilotCommandShape.holdsTheShellOpen` routes it through
    /// `startLongRunning` exactly the way the live run's `npm run dev` did.
    final class RunStepGuideURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = Data(Self.guideJSON.utf8)
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

        static let runStepTitle = "Start Run Step Repro"
        static let runStepBody = "Run Step Repro is starting from source. The red button stops it and hands the step to you."

        static var guideJSON: String {
            """
            {
              "appSlug": "run-step-repro",
              "appName": "Run Step Repro",
              "version": 1,
              "status": "pilot",
              "sourceOwner": "Blueturboguy07",
              "sourceRepo": "run-step-repro",
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
                     "command": "git clone https://example.invalid/run-step-repro.git"},
                    {"id": "run", "kind": "terminal", "title": "\(runStepTitle)", "body": "\(runStepBody)",
                     "command": "npm run dev",
                     "watch": {"expect": [{"type": "axElement", "roleLabel": "localhost:5173"}]},
                     "verifierLabel": "localhost:5173 responds"},
                    {"id": "open", "kind": "open", "title": "Open it", "body": "",
                     "href": "http://localhost:5173",
                     "watch": {"expect": [{"type": "urlHost", "host": "localhost"}]}}
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
        stubbedSessionConfiguration.protocolClasses = [RunStepGuideURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "iris.runstepstall.tests.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
    }

    /// Same polling shape `FreeHarmonyStaleCheckReproTests` and
    /// `GuideAutopilotResumeTests` use: the drive loop runs in a detached
    /// `Task`, so a test observes its effects rather than awaiting a handle
    /// it does not expose.
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

    @Test("a long-running step with a real watch parks the terminal aside and opens a real escape hatch")
    func longRunningStepWithWatchHandsBackAndIsRecoverable() async throws {
        let longRunningShell = GuideAutopilotResumeTests.ScriptedShell(
            [.succeeded(workingDirectory: "/tmp/run-step-repro")]
        )
        let controller = GuideSessionController(
            guideService: try Self.guideService(),
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: GuideAutopilotResumeTests.ScriptedShell(
                        [.succeeded(workingDirectory: "/tmp/run-step-repro")]
                    ),
                    longRunningSession: longRunningShell,
                    fixProposer: GuideAutopilotResumeTests.GiveUpProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )

        var gateFiredWithTitle: String?
        controller.onAutopilotWaitingForReaderAtGate = { title, _ in
            gateFiredWithTitle = title
        }

        // Land directly on 'clone' (index 0) so autopilot drives through the
        // real 'run' step rather than starting on it.
        await controller.openGuide(
            slug: "run-step-repro", requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: 0
        )
        #expect(controller.currentStepIndex == 0)

        controller.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.runstepstall.grant.\(UUID().uuidString)")
            )
        )
        controller.confirmAutonomousControl = { true }
        controller.startAutopilot()

        // 'clone' runs and the drive loop lands on 'run', starts "npm run
        // dev" as a long-running side session, and (before the fix) simply
        // returns here forever — autopilot still "running", nothing ever
        // parked, nothing ever gated.
        let landedOnRunStep = await pump {
            controller.currentStepIndex == 1 && longRunningShell.commandsRun.contains { $0.contains("npm run dev") }
        }
        #expect(landedOnRunStep, "the drive loop must reach the run step and start its dev server")

        // THE FIX: exactly like a step Iris cannot finish itself, a
        // long-running step with a real watch must hand back and surface a
        // gate — so the takeover terminal parks aside instead of sitting as a
        // full, centered window with nothing behind it to say a stall is
        // recoverable.
        let handedBack = await pump {
            controller.autopilotHandedTheCurrentStepToTheReader && gateFiredWithTitle != nil
        }
        #expect(handedBack, "a long-running step with a watch must hand back to the reader, the same as a manual step")
        #expect(gateFiredWithTitle == RunStepGuideURLProtocol.runStepTitle)
        // Autopilot itself must still be considered running — this is a
        // park, not a stop; the watch loop (or the reader) can still move it
        // on, and the takeover terminal must not have been torn down.
        #expect(controller.autopilotIsRunning)

        // THE OTHER HALF: the parked card's "I did it — continue" button must
        // not be the same kind of dead button `Test7ManualGateReproTests`
        // exists to keep fixed for manual gates. Tapping it here must
        // actually move the guide off the run step.
        controller.readerFinishedTheGatedStep()
        let advancedPastRunStep = await pump { controller.currentStepIndex == 2 }
        #expect(advancedPastRunStep, "\"I did it — continue\" on a parked long-running step must actually advance the guide")
    }
}
