//
//  AstroGuideFinishButtonReproTests.swift
//  leanring-buddyTests
//
//  ASTRO FIX ROUND (2026-09-05 live campaign): "Astro guide's final step
//  ('Choose where answers come from') cannot be completed — Finish/Done
//  button is a dead end." Reproduced live on Astro's real 5-step macOS
//  branch (five GUI/permission steps, no terminal or check step anywhere in
//  it): landing on "5 of 5" and pressing Finish relabelled the button to
//  "Done", but the panel stayed on "5 of 5" for 5+ minutes and a second press
//  did nothing — confirmed with a direct AXPress on the real button, so this
//  was never a hit-testing problem, and it survived Astro being quit
//  underneath it.
//
//  THE ACTUAL MECHANISM — not what the field report guessed. The report
//  theorized the completion path depends on autopilot having run (Astro's
//  branch has zero terminal/check steps, so `canOfferAutopilot` is
//  permanently false for it). That theory is wrong: `GuideSessionController`
//  already reaches a real completed state — `readerHasFinishedTheGuide` and
//  `onGuideCompleted` — unconditionally, on ONE press, with no dependency on
//  autopilot whatsoever (see `theControllerCompletesTheGuideInOnePress`
//  below, and `GuideCompletionTests`/`GuideSessionTests` for the rest of that
//  path's coverage).
//
//  The real break is one layer up, in the view that actually renders a guide
//  in the field — `OverlayEyeInputBar.guidePresentation` — NOT
//  `GuidePanelView`, which draws a proper completion card on
//  `readerHasFinishedTheGuide` but is dead code: nothing in the app
//  constructs a `GuidePanelView` any more (grep the target — zero hits). The
//  live surface is the card under the eye, and its visibility guard only
//  checked "is a guide open", never "has the reader finished it":
//  `stepTheReaderIsLookingAt` stays pinned to the branch's LAST step forever
//  once the reader finishes it (`advanceToTheNextStep` clamps
//  `currentStepIndex` at `lastStepIndex` rather than walking off the end), so
//  the card kept drawing that step after completion. For a step with neither
//  a command nor a link — Astro's actual last step, a plain `permission`
//  step — `GuideStepPrimaryAction`'s default fallback applies, and the label
//  shown came from `OverlayEyeGuideStepPresentation`'s OWN fallback guess
//  (`isTheLastStep ? "Done" : "Continue"`) rather than the controller's real
//  (now-`nil`) answer once finished — exactly the "Finish" → "Done" relabel
//  the report describes. Pressing that "Done" again called
//  `performPrimaryAction()` into a `nil` primary action: a guaranteed no-op,
//  forever, which is the reported dead end.
//
//  THE FIX. `guidePresentation` now also requires
//  `!guideSessionController.readerHasFinishedTheGuide`, so the card leaves
//  the screen the moment the guide actually finishes — one press, exactly
//  like every earlier step.
//

import AppKit
import Foundation
import SwiftUI
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

@MainActor
struct AstroGuideFinishButtonReproTests {

    /// Test 1 rules out the field report's own theory: the controller's
    /// completion path has no dependency on autopilot. It fires unconditionally
    /// on one press of the last step, whether or not the branch has anything
    /// autopilot could ever run.
    @Test("the controller completes the guide in one press, with no autopilot involved")
    func theControllerCompletesTheGuideInOnePress() async throws {
        let guideSessionController = GuideSessionController(
            guideService: try Self.stubbedAstroGuideService()
        )
        await guideSessionController.openLatestVersionOfGuide(slug: "astro-repro")
        #expect(guideSessionController.numberOfStepsInTheSelectedBranch == 5)
        // Astro's real shape: no terminal/check step anywhere, so autopilot
        // was never offered and never ran — this is by design, not a bug.
        #expect(!guideSessionController.canOfferAutopilot)

        // Steps 1-4, driven the same way `WatchLoop`/`Back` do — moving the
        // reader's place without touching a step's own action (opening a
        // link, copying a command), which is not what this test is about.
        for _ in 0..<4 { guideSessionController.advanceToTheNextStep() }
        #expect(guideSessionController.currentStepIndex == 4)
        #expect(!guideSessionController.readerHasFinishedTheGuide)

        var onGuideCompletedFireCount = 0
        guideSessionController.onGuideCompleted = { _, _ in onGuideCompletedFireCount += 1 }

        // THE ONE PRESS. Exactly `primaryActionButton`'s action in the real
        // card: `performPrimaryAction()`, the real dispatch a click runs.
        guideSessionController.performPrimaryAction()

        #expect(
            guideSessionController.readerHasFinishedTheGuide,
            "the controller never reached a completed state on one press of the last step"
        )
        #expect(
            onGuideCompletedFireCount == 1,
            "onGuideCompleted did not fire exactly once on the press that finished the guide"
        )

        // THE HAZARD the view guard exists for. The branch's last step is
        // still what `stepTheReaderIsLookingAt` reports, even though the
        // guide is finished — a view guard that only checks "is a guide
        // open" cannot tell this state apart from the one right before the
        // press. If this assertion ever starts failing on its own (i.e.
        // `stepTheReaderIsLookingAt` starts returning nil once finished),
        // the extra guard added to `OverlayEyeInputBar.guidePresentation`
        // stops being necessary — update it and this test together.
        #expect(guideSessionController.stepTheReaderIsLookingAt != nil)
    }

    /// Test 2 is the actual reported bug, reproduced on the real view: the
    /// card the reader is actually looking at (under the eye, not the unused
    /// `GuidePanelView`) has to leave the screen once the guide finishes, or
    /// the dead "Done" button the report describes is exactly what renders.
    @Test("the real card the reader sees leaves the screen the moment the guide finishes")
    func theRealGuideCardDisappearsWhenTheGuideFinishes() async throws {
        let companionManager = CompanionManager()
        defer { companionManager.stop() }
        let guideSessionController = GuideSessionController(
            guideService: try Self.stubbedAstroGuideService()
        )

        await guideSessionController.openLatestVersionOfGuide(slug: "astro-repro")
        for _ in 0..<4 { guideSessionController.advanceToTheNextStep() }
        try #require(
            guideSessionController.currentStepIndex == 4
                && !guideSessionController.readerHasFinishedTheGuide,
            "the harness did not land on step 5 of 5 before finishing — fix the harness"
        )

        let barOnTheLastStep = Self.renderBar(
            companionManager: companionManager, guideSessionController: guideSessionController
        )
        // A sanity check on the harness itself, not the fix: the card the
        // reader is looking at right before the press that finishes it.
        try #require(
            barOnTheLastStep.height > 0,
            "the guide card never rendered at all on step 5 — fix the harness before trusting the rest"
        )

        // THE ONE PRESS.
        guideSessionController.performPrimaryAction()
        try #require(
            guideSessionController.readerHasFinishedTheGuide,
            "the controller did not finish on one press — fix the harness, not the view"
        )

        let barAfterFinishing = Self.renderBar(
            companionManager: companionManager, guideSessionController: guideSessionController
        )

        #expect(
            barAfterFinishing.height < barOnTheLastStep.height,
            """
            The guide finished (readerHasFinishedTheGuide == true) but the bar is still \
            \(barAfterFinishing.height)pt tall — the same "5 of 5" card, with a dead button, is \
            still on screen. This is the field report's "the panel stayed on '5 of 5' for 5+ \
            minutes" and "a second click on the same visual location did nothing", photographed.
            """
        )
    }

    // MARK: - A stubbed `GuideService` serving Astro's real branch shape

    /// Astro's real macOS branch, reproduced field-for-field from the live
    /// campaign run: five GUI/permission steps (download, install, the
    /// BrowserOS/Astro shared-bundle-id explanation, letting the search engine
    /// download, and choosing where answers come from), zero terminal or
    /// check steps anywhere in it — so autopilot can never engage, which is
    /// the shape the field report reasoned from and drew the wrong
    /// conclusion about — and a LAST step with no `href` and no `command`,
    /// Astro's actual "Choose where answers come from", so the primary button
    /// resolves through `GuideStepPrimaryAction`'s bare fallback case exactly
    /// as it did live.
    private static func stubbedAstroGuideService() throws -> GuideService {
        let stubbedSessionConfiguration = URLSessionConfiguration.ephemeral
        stubbedSessionConfiguration.protocolClasses = [AstroReproStubURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "com.publik.iris.tests.astro-finish-repro.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
    }

    // MARK: - Rendering the real bar off-screen

    /// The same off-screen-window measurement `Bug4BarRendering.bar` uses:
    /// the REAL `OverlayEyeInputBarView`, laid out in a real window parked far
    /// off any display, so what is measured is what the reader would
    /// literally see rather than what the source suggests they would.
    private static func renderBar(
        companionManager: CompanionManager,
        guideSessionController: GuideSessionController
    ) -> (height: CGFloat, pixels: Data?) {
        let view = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: guideSessionController,
            onDismissRequested: {},
            onTheBarShouldReleaseTheKeyboard: {},
            onTheBarShouldTakeTheKeyboardBack: {},
            onTheBarsMeasuredHeightChanged: { _ in }
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: max(hostingView.fittingSize.height, 1)
        )
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        hostingView.layoutSubtreeIfNeeded()

        let measuredHeight = hostingView.fittingSize.height
        var pixels: Data?
        if let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            pixels = representation.representation(using: .png, properties: [:])
        }
        window.orderOut(nil)
        return (measuredHeight, pixels)
    }
}

/// Answers `GET /api/iris/guides/astro-repro` with Astro's real branch shape,
/// field for field, instead of the network.
private final class AstroReproStubURLProtocol: URLProtocol {
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
        let requestedVersion = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "version" }?
            .value
            .flatMap(Int.init) ?? 3

        let responseBody = Data(Self.astroGuideJSON(version: requestedVersion).utf8)
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

    private static func astroGuideJSON(version: Int) -> String {
        """
        {
          "appSlug": "astro-repro",
          "appName": "Astro",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "astro-repro",
          "sourceCommit": null,
          "outputType": "desktop_app",
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
                {"id": "download", "kind": "open", "title": "Download Astro",
                 "body": "Astro.dmg", "href": "https://astro-repro.example/Astro.dmg",
                 "actionLabel": "Download Astro.dmg"},
                {"id": "install", "kind": "permission", "title": "Drag Astro to Applications",
                 "body": "Drag it in."},
                {"id": "browseros-conflict", "kind": "permission",
                 "title": "Keep BrowserOS or Astro, not both",
                 "body": "They share a bundle ID."},
                {"id": "search-engine", "kind": "permission", "title": "Let the search engine download",
                 "body": "A search returns results."},
                {"id": "ai-route", "kind": "permission", "title": "Choose where answers come from",
                 "body": "A model is selected in Settings."}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }
}
