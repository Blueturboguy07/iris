//
//  PrimaryActionStaleAdvanceReproTests.swift
//  leanring-buddyTests
//
//  Anthropic-key live run, Sep 2026 fix round, finding: "'Continue'
//  stall-recovery button silently skips an entire guide step."
//
//  Live repro: step 1/5 ("Open the Anthropic console") is a `web` step with an
//  `href` and a `urlHost` watch. The reader clicked the card's "Open the
//  console" button (setting `readerHasTakenThisStepsAction`, which turns the
//  SAME button into a plain "Continue" — the normal manual confirmation every
//  open-link step offers, not a special stall-recovery affordance). The
//  browser genuinely reached the watched host, so `WatchLoop.onVerdict` fired
//  and silently advanced the guide on its own — this can land at any moment,
//  including the instant between the reader's last rendered frame and their
//  physical click. When the reader's tap is then PROCESSED, the old code
//  re-resolved `primaryActionForTheCurrentStep` fresh against whatever step is
//  CURRENT NOW (not the step the on-screen button was drawn for) and ran
//  THAT action — so one tap the reader read as "leave the console step" also
//  silently confirmed and left "Click Create Key" (step 2/5), which the
//  reader never saw, acted on, or created a key on. The guide jumped from
//  "1 of 5" to "3 of 5" for one press.
//
//  This pins the fix at the level that does not need a screen or a real
//  WatchLoop tick: `GuideSessionController.advanceToTheNextStep()` (whatever
//  called it — the loop, or the reader) already ran BEFORE the tap is
//  processed is indistinguishable, at the moment `performPrimaryAction` runs,
//  from a step the reader is looking at right now. `expectedCurrentStepId` is
//  the id the button's closure captured when IT was rendered; a tap whose
//  captured id no longer matches `currentStep?.id` must be a no-op — the
//  reader's goal (leave the step they saw) is already satisfied by whatever
//  moved the guide on first, and running the NEW step's action on their
//  behalf is exactly the double-advance this test exists to keep fixed.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct PrimaryActionStaleAdvanceReproTests {

    /// Shaped like the real anthropic-api-key flow's first three steps:
    /// an `open`/`web` step with an href + urlHost watch, a `web` step with
    /// no href/command (so its own primary action always falls to the plain
    /// "advance" case, exactly like the live "Click Create Key" step), and a
    /// third step to land on if (and only if) a bug skips the second.
    final class StaleAdvanceGuideURLProtocol: URLProtocol {
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

        static let openConsoleStepId = "open-console"
        static let createKeyStepId = "create-key"
        static let copyKeyStepId = "copy-key"

        static var guideJSON: String {
            """
            {
              "appSlug": "stale-advance-repro",
              "appName": "Stale Advance Repro",
              "version": 1,
              "status": "pilot",
              "sourceOwner": "Blueturboguy07",
              "sourceRepo": "stale-advance-repro",
              "sourceCommit": null,
              "outputType": "credential",
              "estimatedMinutes": 4,
              "readmeSectionIds": [],
              "branches": [
                {
                  "platform": "macos",
                  "target": null,
                  "label": "macOS",
                  "shell": "terminal",
                  "setupSteps": [],
                  "steps": [
                    {"id": "\(openConsoleStepId)", "kind": "web", "title": "Open the console", "body": "",
                     "href": "https://platform.claude.com/settings/keys", "actionLabel": "Open the console",
                     "watch": {"expect": [{"type": "urlHost", "host": "platform.claude.com"}]}},
                    {"id": "\(createKeyStepId)", "kind": "web", "title": "Click Create Key", "body": "",
                     "watch": {"expect": [{"type": "axElement", "roleLabel": "Create Key"}]}},
                    {"id": "\(copyKeyStepId)", "kind": "paste", "title": "Copy the key", "body": "",
                     "watch": {"expect": [{"type": "foregroundApp", "bundleId": "com.publikhq.iris"}], "sensitive": true}}
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
        stubbedSessionConfiguration.protocolClasses = [StaleAdvanceGuideURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "iris.staleadvance.tests.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
    }

    @Test("a primary-action tap captured for a step the watch loop has already left is ignored, not re-run on the new current step")
    func staleContinueTapDoesNotDoubleAdvance() async throws {
        let controller = GuideSessionController(guideService: try Self.guideService())

        await controller.openGuide(
            slug: "stale-advance-repro", requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: 0
        )
        #expect(controller.currentStepIndex == 0)
        #expect(controller.currentStep?.id == StaleAdvanceGuideURLProtocol.openConsoleStepId)

        // First press: "Open the console". Captured at the render that showed
        // that label, for the step it was drawn for.
        let stepIdTheOpenButtonWasRenderedFor = controller.currentStep?.id
        controller.performPrimaryAction(expectedCurrentStepId: stepIdTheOpenButtonWasRenderedFor)
        #expect(controller.readerHasTakenThisStepsAction)
        #expect(controller.currentStepIndex == 0, "opening the link must not itself advance the step")

        // The button now reads "Continue" — the SAME step, captured again at
        // THIS render.
        let stepIdTheContinueButtonWasRenderedFor = controller.currentStep?.id
        #expect(stepIdTheContinueButtonWasRenderedFor == StaleAdvanceGuideURLProtocol.openConsoleStepId)

        // THE RACE: before the reader's physical click on "Continue" is
        // processed, the watch loop notices the browser genuinely reached
        // platform.claude.com and advances the guide on its own — exactly
        // what `WatchLoop.onVerdict`'s closure does in production.
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 1)
        #expect(controller.currentStep?.id == StaleAdvanceGuideURLProtocol.createKeyStepId)

        // THE STALE TAP LANDS. Before the fix, `performPrimaryAction` (no
        // step-id parameter existed) re-resolved the primary action fresh
        // against the NOW-current step (create-key, whose own action is a
        // plain "advance" — the live card rendered it as "Done") and ran it,
        // silently walking the guide to copy-key without the reader ever
        // having seen or acted on "Click Create Key".
        controller.performPrimaryAction(expectedCurrentStepId: stepIdTheContinueButtonWasRenderedFor)

        #expect(
            controller.currentStepIndex == 1,
            "a tap rendered for open-console must not also confirm create-key just because the watch loop got there first"
        )
        #expect(controller.currentStep?.id == StaleAdvanceGuideURLProtocol.createKeyStepId)
    }

    @Test("a primary-action tap whose captured step id still matches the current step advances normally")
    func freshTapStillAdvances() async throws {
        let controller = GuideSessionController(guideService: try Self.guideService())

        await controller.openGuide(
            slug: "stale-advance-repro", requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop", stepIndexFromDeepLink: 0
        )
        #expect(controller.currentStepIndex == 0)

        let stepIdTheButtonWasRenderedFor = controller.currentStep?.id
        controller.performPrimaryAction(expectedCurrentStepId: stepIdTheButtonWasRenderedFor)
        #expect(controller.currentStepIndex == 0)

        // Press "Continue" for real, with nothing else having moved the guide
        // in between — the ordinary, non-racy path must still work.
        let stepIdTheContinueButtonWasRenderedFor = controller.currentStep?.id
        controller.performPrimaryAction(expectedCurrentStepId: stepIdTheContinueButtonWasRenderedFor)

        #expect(controller.currentStepIndex == 1)
        #expect(controller.currentStep?.id == StaleAdvanceGuideURLProtocol.createKeyStepId)
    }
}
