//
//  Bug9PointingDoubleFireEndToEndTests.swift
//  leanring-buddyTests
//
//  BUG 9, END TO END — "Pointing double-fire and stale coordinates after a
//  window move", measured once, at the boundary the reader can see.
//
//  `Bug9PointingDoubleFireReproTests` reproduces the two halves of this report
//  separately, and one of them (`theCorrectionFollowsTheWindowTheCaptureWas...`)
//  reaches `GuideStepPointingCoordinator.resolve` directly with a hand-built
//  locator. This file takes the reader's own path through the app once and
//  asserts what the reader would actually experience at the end of it:
//
//      * the assistant is called ONCE for the manual step they were parked on,
//        not two or three times inside half a second; and
//      * the eye lands on the control where the control IS, after they picked
//        the window up and put it down somewhere else while Iris was thinking.
//
//  Both in the same run, because in the field they happen in the same run: the
//  log's two asks 0.358s apart and its 2.6s round trip are one park of one step.
//  A guard that checks them apart cannot see the way they interact — every ask
//  spans a drag, only the LAST uncancelled ask's answer is ever flown, and a fix
//  to either half alone still leaves the eye on bare desktop.
//
//  HOW MUCH OF THIS IS REAL, stated plainly so nobody has to guess:
//
//    REAL. `GuideSessionController`, including its real
//    `NSWorkspace.didActivateApplicationNotification` observer and its real
//    400ms activation coalescer. The real `GuideAutopilotRunner` drive loop,
//    which walks the guide's three terminal steps and then takes the MANUAL
//    branch on `install-xcode` exactly as the field log does. The real
//    `GuideService` parsing a real HTTP response. The real `GuidePointingLadder`,
//    the real `GuideStepPointingCoordinator`, the real per-step model budget and
//    the real `GuideEyeFlightMemo`. Two REAL `NSPanel`s on the REAL screen, whose
//    live frames are what every locator answer is read from, one of which is
//    really moved between the capture and the answer.
//
//    STOOD IN FOR. (1) The model transport — `locateByAskingTheModel` stands in
//    for `CompanionManager.locateGuideTargetWithModel`, because that rung
//    captures the screen, costs money and needs grants this runner does not
//    have. It performs that method's geometry step for step: crop to the focused
//    window's frame at shutter time, wait out the round trip, then express the
//    answer through the crop origin it kept — which is the only geometry
//    `CompanionManager.globalScreenLocation` has. (2) The guide server, as a
//    `URLProtocol` serving the kneecap guide the log was installing, so the step
//    parked on is the field's step. (3) The pty shell, recorded rather than
//    spawned: what `bun install` does is not what this bug is about, and a real
//    login shell inside a timing-sensitive pointing measurement buys nothing.
//
//    HOW THE WINDOW IS MOVED. Through AppKit (`setFrameOrigin`), not through a
//    synthesized press-drag-release. That is not a shortcut taken here for
//    convenience: the sibling repro measured the synthesized gesture against
//    this same kind of panel and it moves it by exactly 0pt, because AppKit's
//    background-drag tracking loop pulls the rest of the gesture out of an event
//    queue the swiftc test runner has no `NSApplication` to pump (see
//    `Bug9PointingDoubleFireReproTests.theReaderMovesTheWindow`). The reader
//    moving their own window is this test's PREMISE, not the thing under test,
//    so it is done the way that actually moves a real window on the real window
//    server. The one event this runner does deliver for real — the app
//    activation Iris's own takeover window causes when it comes forward — is
//    posted on the real `NSWorkspace.shared.notificationCenter` and received by
//    the controller's real observer.
//
//  WHAT MAKES IT A GUARD RATHER THAN A RESTATEMENT. The app the reader is
//  working in has TWO windows open, which is what a real install target looks
//  like — a second Xcode window, a browser with two windows, any multi-document
//  editor. Only one of them is focused, and only that one is the window the
//  pointing capture crops to. The other sits perfectly still and is what this
//  app's window LIST (`locateWindow(ofApp:)`, `kAXWindowsAttribute`, whose order
//  Apple documents nothing about) hands back. So this test fails three separate
//  ways: if nothing coalesces the triggers, if nothing corrects for the move,
//  and if the correction measures the move of the wrong window.
//

import AppKit
import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized)
struct Bug9PointingDoubleFireEndToEndTests {

    // MARK: - The guide the field log was installing

    /// Serves `GET /api/iris/guides/{slug}` with the kneecap branch from the
    /// Test 9 log, step ids and titles included, so the step this test parks on
    /// is the field's: `install-xcode`, `kind=open`, `exec=false`, "Install
    /// Xcode". No `href`, because the log shows it took the MANUAL branch.
    ///
    /// Nested and self-contained rather than borrowed from the sibling repro
    /// file, so this suite can be compiled and run on its own — which is how it
    /// was run against the unfixed commit.
    final class TheGuideServerTheInstallReads: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard
                let requestURL = request.url,
                let httpResponse = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.kneecapGuideJSON.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {
            // Every answer is delivered synchronously; there is nothing to unwind.
        }

        static let kneecapGuideJSON = """
        {
          "appSlug": "kneecap",
          "appName": "kneecap",
          "version": 2,
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "kneecap",
          "sourceCommit": null,
          "outputType": "mobile_app",
          "estimatedMinutes": 40,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": "ios",
              "label": "Mac + iPhone",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "pin-source", "kind": "terminal", "title": "Pin the source",
                 "body": "", "command": "git checkout dc8eff27"},
                {"id": "install-deps", "kind": "terminal", "title": "Install what it needs",
                 "body": "", "command": "bun install"},
                {"id": "build-editor", "kind": "terminal", "title": "Build the editor",
                 "body": "", "command": "bun run build"},
                {"id": "install-xcode", "kind": "open", "title": "Install Xcode",
                 "body": "Apple's build tools. It is a large download from the App Store."},
                {"id": "sync-ios", "kind": "terminal", "title": "Sync the iOS project",
                 "body": "", "command": "bunx cap sync ios"},
                {"id": "open-project", "kind": "terminal", "title": "Open the project",
                 "body": "", "command": "bunx cap open ios"},
                {"id": "signing", "kind": "permission", "title": "Sign it with your Apple ID",
                 "body": "Pick your own team under Signing & Capabilities."},
                {"id": "run", "kind": "open", "title": "Plug in your iPhone and press play",
                 "body": "Xcode builds it onto the phone."}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }

    /// The step the log parked on: the only step in this guide whose target is
    /// `.inferred` and therefore allowed to reach the model at all.
    private static let titleOfTheStepTheReaderWasParkedOn = "Install Xcode"
    private static let indexOfTheStepTheReaderWasParkedOn = 3

    // MARK: - The install, with everything but the shell for real

    /// The pty-backed login shell, recorded rather than spawned. See the file
    /// header: what `bun install` does is not what this bug is about, and the
    /// drive loop reaching the manual gate is asserted below either way.
    final class TheShellTheInstallRunsIn: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/akrit/kneecap"
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

    /// Nothing failed in the log's run, so nothing needs proposing. Wired in so
    /// the fix ladder can never reach a model and add asks of its own.
    final class NothingProposesAFix: GuideAutopilotFixProposing {
        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
    }

    // MARK: - The app the reader is installing from, with two windows open

    /// Stands in for `SystemGuideTargetLocator` against an app showing two
    /// windows — which is what a real install target looks like.
    ///
    /// Every answer is read from a LIVE `NSPanel` frame, so nothing here is a
    /// remembered rectangle: when the reader moves the window, the next answer
    /// is different because the window is somewhere else.
    ///
    ///   * `locateFocusedWindow(ofApp:)` answers from the panel the reader is
    ///     working in. This is the window `CompanionScreenCaptureUtility`
    ///     crops the pointing capture to (`kAXFocusedWindowAttribute`, through
    ///     `SystemWatchLoopLocalSignalSource`), so it is the only window whose
    ///     movement says anything about where the model's answer went.
    ///   * `locateWindow(ofApp:)` answers from the app's OTHER window, which
    ///     never moves. That is the honest stand-in for `kAXWindowsAttribute`:
    ///     the array's order is undocumented, so which window comes back first
    ///     cannot be predicted, and for this app it is not the focused one.
    @MainActor
    final class TheAppTheReaderIsInstallingFrom: GuideTargetLocating {

        struct AskTheModelWasGiven {
            let stepTitle: String
            let ordinal: Int
            let startedAt: Date
        }

        private(set) var asksThatStarted: [AskTheModelWasGiven] = []
        private(set) var asksThatFinished: [(ordinal: Int, at: Date)] = []
        private(set) var timesTheFocusedWindowWasLookedUp = 0
        private(set) var timesTheWindowListWasLookedUp = 0

        /// Where the control was, in global screen points, at the instant each
        /// capture was taken — one entry per ask, in order.
        private(set) var whereTheControlWasWhenEachScreenWasCaptured: [CGPoint] = []

        /// The window the capture is cropped to. The reader drags this one.
        let theWindowTheReaderIsWorkingIn: NSPanel
        /// Another window of the same app, sitting perfectly still.
        let theOtherWindowOfTheSameApp: NSPanel
        /// How far the reader shoves the focused window, once per ask.
        let howFarTheReaderDragsIt: CGPoint
        /// How long the capture takes before the shutter goes, and how long the
        /// round trip takes after it. The field log's own shape: the reader has
        /// time to move the window between the two.
        let howLongTheCaptureTakes: Int
        let howLongTheRoundTripTakes: Int

        init(
            theWindowTheReaderIsWorkingIn: NSPanel,
            theOtherWindowOfTheSameApp: NSPanel,
            howFarTheReaderDragsIt: CGPoint,
            howLongTheCaptureTakes: Int,
            howLongTheRoundTripTakes: Int
        ) {
            self.theWindowTheReaderIsWorkingIn = theWindowTheReaderIsWorkingIn
            self.theOtherWindowOfTheSameApp = theOtherWindowOfTheSameApp
            self.howFarTheReaderDragsIt = howFarTheReaderDragsIt
            self.howLongTheCaptureTakes = howLongTheCaptureTakes
            self.howLongTheRoundTripTakes = howLongTheRoundTripTakes
        }

        /// Nil, which is what puts the ladder on the model rung. The real walk
        /// answers nil for exactly this kind of step: "Install Xcode" names
        /// nothing in the frontmost app's accessibility tree.
        func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? { nil }

        func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
            timesTheWindowListWasLookedUp += 1
            return theOtherWindowOfTheSameApp.frame
        }

        func locateFocusedWindow(ofApp bundleIdentifier: String) -> CGRect? {
            timesTheFocusedWindowWasLookedUp += 1
            return theWindowTheReaderIsWorkingIn.frame
        }

        /// `CompanionManager.locateGuideTargetWithModel`, step for step:
        ///
        ///   1. capture the screen and crop it to the focused window's frame NOW
        ///      (`captureAllScreensAsJPEG(croppingToTheFocusedWindow: true)` ->
        ///      `focusedWindowWorthCroppingTo` ->
        ///      `CompanionScreenCaptureWindowCrop.regionInFullScreenshotPixels`);
        ///   2. spend the round trip inside `ClaudeAPI.analyzeImageStreaming` —
        ///      the log's own 07:04:10.699 -> 07:04:13.325, 2.6 seconds;
        ///   3. map the model's in-image coordinate back to a global point
        ///      through the crop region from step 1, which is the only geometry
        ///      `CompanionManager.globalScreenLocation` has, and wrap it in the
        ///      same 44pt square that method builds around it.
        ///
        /// The reader's drag happens between 1 and 2, so the ordering is exact
        /// rather than raced. EVERY ask spans a drag, deliberately: with the
        /// triggers uncoalesced only the last ask's answer is ever flown (the
        /// earlier tasks resolve and then throw their answers away at
        /// `guard !Task.isCancelled`), so moving the window only once would let a
        /// later ask photograph the already-moved window and hide the defect
        /// behind the double-fire.
        func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
            let ordinal = asksThatStarted.count + 1
            asksThatStarted.append(
                AskTheModelWasGiven(stepTitle: stepTitle, ordinal: ordinal, startedAt: Date())
            )

            await Bug9PointingDoubleFireEndToEndTests
                .waitOutAnUncancellableRoundTrip(milliseconds: howLongTheCaptureTakes)

            // The shutter. The crop origin is this frame, and it is all the
            // answer will ever be expressed through.
            let whereTheWindowWasWhenTheShutterWent = theWindowTheReaderIsWorkingIn.frame
            let whereTheControlWas = CGPoint(
                x: whereTheWindowWasWhenTheShutterWent.midX,
                y: whereTheWindowWasWhenTheShutterWent.midY
            )
            whereTheControlWasWhenEachScreenWasCaptured.append(whereTheControlWas)

            Bug9PointingDoubleFireEndToEndTests.theReaderMovesTheWindow(
                theWindowTheReaderIsWorkingIn, by: howFarTheReaderDragsIt
            )

            await Bug9PointingDoubleFireEndToEndTests
                .waitOutAnUncancellableRoundTrip(milliseconds: howLongTheRoundTripTakes)

            asksThatFinished.append((ordinal: ordinal, at: Date()))
            let side: CGFloat = 44
            return CGRect(
                x: whereTheControlWas.x - side / 2,
                y: whereTheControlWas.y - side / 2,
                width: side, height: side
            )
        }

        func asks(forStepTitled stepTitle: String) -> [AskTheModelWasGiven] {
            asksThatStarted.filter { $0.stepTitle == stepTitle }
        }
    }

    /// A wait that a `Task.cancel()` cannot shorten.
    ///
    /// This is the whole reason the double-fire is a double-fire rather than a
    /// cancelled first attempt. `refreshPointingForTheOpenStep` cancels the
    /// in-flight pointing task before starting the next one, but cancellation in
    /// Swift is cooperative: `CompanionScreenCaptureUtility.captureAllScreensAsJPEG`
    /// and `ClaudeAPI.analyzeImageStreaming` contain no `Task.isCancelled` check,
    /// so a capture that has been taken and a request that is on the wire run to
    /// completion regardless. `try? await Task.sleep(for:)` would model the
    /// opposite and flatter the unfixed code into looking coalesced.
    private static func waitOutAnUncancellableRoundTrip(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    // MARK: - The reader's own windows, and the reader's own hand

    /// A real window on the real screen.
    ///
    /// `.nonactivatingPanel` so raising it never steals focus from whatever the
    /// founder is doing while this runs.
    private static func aWindowOnTheRealScreen(titled title: String, at frame: CGRect) -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        return panel
    }

    /// The reader picks the window up and puts it down somewhere else. See the
    /// file header for why this goes through AppKit rather than a synthesized
    /// gesture.
    private static func theReaderMovesTheWindow(_ panel: NSPanel, by delta: CGPoint) {
        panel.setFrameOrigin(
            CGPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    // MARK: - Everything the eye was told to do

    /// Every flight the controller asked for, in order. A class because the
    /// closure outlives the statement that builds it.
    @MainActor
    final class FlightRecorder {
        private(set) var flights: [(point: CGPoint, displayFrame: CGRect, label: String)] = []

        func record(point: CGPoint, displayFrame: CGRect, label: String) {
            flights.append((point: point, displayFrame: displayFrame, label: label))
        }

        func firstFlight(labelled label: String) -> (point: CGPoint, displayFrame: CGRect, label: String)? {
            flights.first(where: { $0.label == label })
        }
    }

    /// What the takeover was told when the install parked, and when.
    @MainActor
    final class WhatTheTakeoverWasToldWhenItParked {
        private(set) var titles: [String] = []
        private(set) var parkedAt: [Date] = []
        /// Run inside the park, where `CompanionManager` raises the takeover
        /// window — the moment a window of Iris's own comes forward.
        var whatHappensWhenTheTakeoverComesForward: (@MainActor () -> Void)?

        func record(title: String) {
            titles.append(title)
            parkedAt.append(Date())
            whatHappensWhenTheTakeoverComesForward?()
        }
    }

    /// Polls a main-actor condition until it holds or the deadline passes. The
    /// drive loop runs in its own Task, so its effects are observed rather than
    /// awaited.
    private static func pump(
        within seconds: Double, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - The run

    @Test("a reader who moves a window mid-install is asked about once and pointed at where the control is")
    func theEyeLandsOnTheMovedControlAfterASinglePointingAsk() async throws {
        // Everything is kept well inside the usable area with room for four
        // drags, so no clamp in `placeTheEyeMayComeToRest` has any say in where
        // the eye ends up: the only geometry this test measures is the
        // correction's. Four, because with nothing coalescing the triggers the
        // one park produces up to three asks and each of them drags.
        let usable = try #require(NSScreen.main).visibleFrame
        let howManyDragsThisRunMustSurvive: CGFloat = 4
        // The right-hand margin is wider than the others because the eye speaks
        // rightwards and `placeTheEyeMayComeToRest` reserves the sentence's own
        // width there. Staying out of that band keeps the flown point equal to
        // the aim point.
        let roomTheWindowsMayUse = CGRect(
            x: usable.minX + 40,
            y: usable.minY + 40,
            width: usable.width - 40 - 280,
            height: usable.height - 80
        )
        try #require(
            roomTheWindowsMayUse.width > 600 && roomTheWindowsMayUse.height > 300,
            "this display is too small to move a window four times inside it without hitting the eye's own clamps"
        )

        let windowSize = CGSize(
            width: min(280, roomTheWindowsMayUse.width * 0.22),
            height: min(200, roomTheWindowsMayUse.height * 0.22)
        )
        let whereTheReadersWindowStarts = CGPoint(
            x: roomTheWindowsMayUse.minX,
            y: roomTheWindowsMayUse.minY + roomTheWindowsMayUse.height * 0.75
        )
        // Big enough that the control's OLD position ends up outside the
        // window's new frame entirely — after this drag the eye is not merely
        // off-centre, it is over bare desktop beside a window that has moved on
        // — and small enough that four of them stay inside the room above.
        let howFarTheReaderDragsIt = CGPoint(
            x: min(
                (roomTheWindowsMayUse.maxX - windowSize.width - whereTheReadersWindowStarts.x)
                    / howManyDragsThisRunMustSurvive,
                windowSize.width * 0.9
            ),
            y: -min(
                (whereTheReadersWindowStarts.y - roomTheWindowsMayUse.minY) / howManyDragsThisRunMustSurvive,
                60
            )
        )
        try #require(
            howFarTheReaderDragsIt.x > windowSize.width / 2,
            "the drag has to clear half the window or the stale point stays inside it and proves less"
        )

        let theWindowTheReaderIsWorkingIn = Self.aWindowOnTheRealScreen(
            titled: "Xcode",
            at: CGRect(origin: whereTheReadersWindowStarts, size: windowSize)
        )
        // The same app's other window, somewhere else entirely and never
        // touched. A correction that reads the app's window LIST finds this one,
        // measures a move of zero, and leaves the stale answer where it was.
        let theOtherWindowOfTheSameApp = Self.aWindowOnTheRealScreen(
            titled: "Xcode — Organizer",
            at: CGRect(
                x: roomTheWindowsMayUse.maxX - windowSize.width,
                y: roomTheWindowsMayUse.minY,
                width: windowSize.width, height: windowSize.height
            )
        )
        defer {
            theWindowTheReaderIsWorkingIn.orderOut(nil)
            theOtherWindowOfTheSameApp.orderOut(nil)
        }
        let whereTheStillWindowStarted = theOtherWindowOfTheSameApp.frame

        // The correction reads the focused window of the FRONTMOST app, and
        // skips itself when there is no frontmost app to name — so a runner with
        // nothing frontmost would pass this test for the wrong reason.
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        try #require(
            frontmostBundleIdentifier != nil && frontmostBundleIdentifier != Bundle.main.bundleIdentifier,
            """
            no app other than this test runner is frontmost on this Mac, so the pointing capture has no \
            window to crop to and nothing here is being measured
            """
        )

        let locator = TheAppTheReaderIsInstallingFrom(
            theWindowTheReaderIsWorkingIn: theWindowTheReaderIsWorkingIn,
            theOtherWindowOfTheSameApp: theOtherWindowOfTheSameApp,
            howFarTheReaderDragsIt: howFarTheReaderDragsIt,
            // The shutter goes a quarter of a second in, leaving the rest of the
            // round trip for the reader's hand — and leaving the ask still in
            // flight when the activation coalescer's 400ms quiet period expires,
            // which is the moment the third trigger arrives.
            howLongTheCaptureTakes: 250,
            howLongTheRoundTripTakes: 1300
        )

        let eyeFlights = FlightRecorder()

        // MARK: the install, driven for real to the manual gate

        let stubbedSessionConfiguration = URLSessionConfiguration.ephemeral
        stubbedSessionConfiguration.protocolClasses = [TheGuideServerTheInstallReads.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "com.publik.iris.tests.bug9e2e.\(UUID().uuidString)")
        )
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
        let shell = TheShellTheInstallRunsIn()
        let controller = GuideSessionController(
            guideService: guideService,
            // The watch loop plays no part in pointing and its default frame
            // source is ScreenCaptureKit: left to drive its own timer it would
            // photograph the founder's screen for the length of this test.
            watchLoop: WatchLoop(preferencesStore: isolatedUserDefaults, drivesItsOwnTickTimer: false),
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: TheShellTheInstallRunsIn(),
                    fixProposer: NothingProposesAFix(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // Over an isolated suite, so starting autopilot here never writes the
        // founder's real "Let Iris take control of your Mac?" preference.
        controller.autonomyGrant = AutopilotAutonomyGrant(userDefaults: isolatedUserDefaults)
        controller.confirmAutonomousControl = { true }
        controller.targetLocator = locator
        controller.irisMayLookAtTheScreenForPointing = true
        controller.sendTheEyeTo = { location, displayFrame, label in
            eyeFlights.record(point: location, displayFrame: displayFrame, label: label)
        }
        // `isTheGuideCardOnScreen` is deliberately left unset — the card IS in
        // front of the reader at a manual gate, and leaving it unset is what
        // keeps the third trigger, the app-activation refresh, live.

        let park = WhatTheTakeoverWasToldWhenItParked()
        // 07:04:09.861 — "takeover: PARKED". `CompanionManager` raises and parks
        // the takeover terminal from this very callback, one statement after the
        // park's own `refreshPointingForTheOpenStep()`. A window of Iris's own
        // coming forward posts `NSWorkspace.didActivateApplicationNotification`
        // — AppKit posts it for the observing app's own activation as readily as
        // for anybody else's — and the controller's real observer starts its
        // 400ms quiet period. Nothing tells it that the park it is reacting to
        // has already refreshed pointing for this same step.
        park.whatHappensWhenTheTakeoverComesForward = {
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: NSWorkspace.shared
            )
        }
        controller.onAutopilotWaitingForReaderAtGate = { title, _ in
            park.record(title: title)
        }

        await controller.openGuide(
            slug: "kneecap",
            requestedVersion: 2,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )
        #expect(controller.loadState == .guideIsOpen)
        controller.startAutopilot()

        let parked = await Self.pump(within: 12) { park.titles.isEmpty == false }
        #expect(parked, "autopilot never reached the Install Xcode gate, so nothing below is being measured")
        #expect(park.titles.last == Self.titleOfTheStepTheReaderWasParkedOn)
        #expect(controller.currentStepIndex == Self.indexOfTheStepTheReaderWasParkedOn)
        #expect(
            shell.commandsRun.contains { $0.contains("bun run build") },
            "the three terminal steps before the gate must really have run, or the gate was reached the wrong way"
        )
        let whenTheStepWasParked = try #require(park.parkedAt.last)

        // MARK: what the reader ends up seeing

        let theEyeFlew = await Self.pump(within: 12) {
            eyeFlights.firstFlight(labelled: Self.titleOfTheStepTheReaderWasParkedOn) != nil
        }
        // Counted at the instant of the flight, not afterwards: this Mac belongs
        // to somebody, and an app they switch to a second later is a real
        // activation that would rightly refresh pointing for a step still on
        // screen. Everything this bug is about has already happened by now.
        let asksBehindTheFlight = locator.asks(forStepTitled: Self.titleOfTheStepTheReaderWasParkedOn)

        let whereTheReadersWindowIsNow = theWindowTheReaderIsWorkingIn.frame
        let whereTheControlIsNow = CGPoint(
            x: whereTheReadersWindowIsNow.midX, y: whereTheReadersWindowIsNow.midY
        )
        let whereTheControlWasWhenTheFlownAnswerWasPhotographed = try #require(
            locator.whereTheControlWasWhenEachScreenWasCaptured.last,
            "the model was never asked, so there is no answer to have corrected"
        )

        #expect(theEyeFlew, "the eye never flew for the parked step")
        let flight = try #require(
            eyeFlights.firstFlight(labelled: Self.titleOfTheStepTheReaderWasParkedOn),
            """
            the eye never flew for "\(Self.titleOfTheStepTheReaderWasParkedOn)", so this test is not looking at \
            the thing it claims to
            """
        )
        let howFarFromTheControl = hypot(
            flight.point.x - whereTheControlIsNow.x, flight.point.y - whereTheControlIsNow.y
        )

        print("""
        [bug9-e2e] parked on step \(controller.currentStepIndex) (\(Self.titleOfTheStepTheReaderWasParkedOn)) \
        after really running \(shell.commandsRun.count) commands
        [bug9-e2e] model asks for this one step, at the moment the eye flew: \(asksBehindTheFlight.count)
        [bug9-e2e] each ask started at: \
        \(asksBehindTheFlight.map { String(format: "+%.3fs", $0.startedAt.timeIntervalSince(whenTheStepWasParked)) })
        [bug9-e2e] the reader's window: started at \(whereTheReadersWindowStarts), is now at \(whereTheReadersWindowIsNow.origin)
        [bug9-e2e] the app's other window, which nobody touched: \(theOtherWindowOfTheSameApp.frame)
        [bug9-e2e] focused-window reads: \(locator.timesTheFocusedWindowWasLookedUp); \
        window-list reads: \(locator.timesTheWindowListWasLookedUp)
        [bug9-e2e] the control was photographed at \(whereTheControlWasWhenTheFlownAnswerWasPhotographed) \
        and is now at \(whereTheControlIsNow)
        [bug9-e2e] the eye was flown to \(flight.point) on display \(flight.displayFrame)
        [bug9-e2e] which is \(String(format: "%.1f", howFarFromTheControl))pt from the control
        """)

        // The premise, checked before the outcomes so a failure says which part
        // of the scenario did not happen: the window really did move between the
        // photograph the flown answer came from and the flight itself, and the
        // app's other window really did sit still.
        #expect(
            hypot(
                whereTheControlIsNow.x - whereTheControlWasWhenTheFlownAnswerWasPhotographed.x,
                whereTheControlIsNow.y - whereTheControlWasWhenTheFlownAnswerWasPhotographed.y
            ) > GuideEyeFlightMemo.distanceAtWhichTwoAnswersAreTheSameAnswer,
            """
            the window did not move between the capture the flown answer came from and the flight, so there is \
            no stale coordinate here to catch
            """
        )
        #expect(
            theOtherWindowOfTheSameApp.frame == whereTheStillWindowStarted,
            "the app's other window moved, so it is no longer the still decoy this test needs it to be"
        )

        // OUTCOME 1, the bill. One manual step, parked once, one unchanged
        // target — and the reader's Mac photographed the screen and called the
        // assistant this many times.
        #expect(
            asksBehindTheFlight.count == 1,
            """
            parking "\(Self.titleOfTheStepTheReaderWasParkedOn)" once cost \(asksBehindTheFlight.count) \
            screen-capture-plus-assistant pointing asks before the eye had flown even once. The step-change \
            refresh, the park's own refresh and the app-activation refresh know nothing about each other, and \
            cancelling a pointing task stops neither a capture already taken nor a request already on the wire \
            — the field log's two asks 0.358s apart
            """
        )

        // OUTCOME 2, what the reader sees. Not a tolerance invented here:
        // `GuideEyeFlightMemo` already treats two answers more than a point
        // apart as genuinely different answers, so a point is the app's own
        // smallest meaningful distance.
        #expect(
            howFarFromTheControl <= GuideEyeFlightMemo.distanceAtWhichTwoAnswersAreTheSameAnswer,
            """
            the reader moved the "\(theWindowTheReaderIsWorkingIn.title)" window while Iris was working out \
            where to point, and the eye was flown to \(flight.point) — \
            \(String(format: "%.0f", howFarFromTheControl))pt away from the control, at \
            \(whereTheControlWasWhenTheFlownAnswerWasPhotographed), which is where it was when the screenshot \
            was taken. "after moving a window the eye flies to where the control WAS."
            """
        )

        // And it is not a near miss inside the window: a stale point is outside
        // the window's new frame altogether, so the eye would be pointing at
        // bare desktop.
        #expect(
            whereTheReadersWindowIsNow.contains(flight.point),
            """
            the eye landed at \(flight.point), which is outside the \(theWindowTheReaderIsWorkingIn.title) \
            window's current frame \(whereTheReadersWindowIsNow) entirely — it is pointing at bare desktop \
            beside the window it was asked about
            """
        )
    }
}
