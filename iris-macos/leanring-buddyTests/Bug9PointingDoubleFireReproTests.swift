//
//  Bug9PointingDoubleFireReproTests.swift
//  leanring-buddyTests
//
//  BUG 9 — "Pointing double-fire and stale coordinates after a window move."
//
//  THE FIELD EVIDENCE, verbatim from the cofounder's Mac (Iris 0.9.6 build 22,
//  `Iris_0.9.6_build_22_Test9_and_General_Logs_Credential_Redacted.log`,
//  process 51799, the kneecap install):
//
//      07:04:03.633  drive: step[7] id=build-editor kind=terminal exec=true
//      07:04:09.639  drive: build-editor result=succeeded
//      07:04:09.640  drive: step[8] id=install-xcode kind=open exec=false
//      07:04:09.861  drive: step install-xcode -> MANUAL branch, waiting at gate (return)
//      07:04:09.861  takeover: PARKED + set readerMustManuallyContinue=true, showsTerminalFace=true, title=Install Xcode
//      07:04:10.341  pointing/model: asked for step=Install Xcode
//      07:04:10.699  pointing/model: asked for step=Install Xcode
//      07:04:10.877  pointing/model: captured 1 screens, 1 cropped to the focused window
//      07:04:10.892  pointing/model: no point — i couldn't reach the assistant. check your connection and try again.
//      07:04:10.986  pointing/model: captured 1 screens, 1 cropped to the focused window
//      07:04:13.325  pointing/model: outcome=model-said-none coordinate=- screen=- modelLabel=none eyeWillAnnounce=Install Xcode
//      07:04:13.325  pointing/model: nothing to fly to (model-said-none)
//
//  and, from the same reports, the half the runtime never recorded a coordinate
//  for ("The runtime does not capture … exact pointer coordinates after the user
//  moves a window … The original Test 9 notes remain the evidence"): after the
//  reader MOVES a window, the eye flies to where the control WAS.
//
//  Both halves are reproduced against the SAME sequence of events the log
//  records, driven by the real machinery: the real `GuideSessionController`
//  (with its real `NSWorkspace` activation observer and its real 400ms
//  coalescer), the real `GuideAutopilotRunner` drive loop running the kneecap
//  guide's three terminal steps and then hitting `install-xcode`'s manual gate,
//  the real `GuidePointingLadder`, the real `GuideStepPointingCoordinator`, the
//  real `GuideService` answering from a stubbed URL protocol that serves the
//  guide the log was installing, and the real `GuideEyeFlightMemo` inside the
//  controller. Stood in for: the pty shell (a recorder — what a command does is
//  not what this bug is about), the pointing model (it costs money and needs a
//  granted Mac), and the reader's own window, which is a REAL `NSPanel` on the
//  REAL screen, really moved mid-ask.
//
//  WHAT THIS FILE ASSERTS, and why each assertion is the bug rather than a
//  restatement of the code:
//
//  (a) SEVERAL MODEL ASKS FOR ONE UNCHANGED STEP, INSIDE HALF A SECOND. One
//      manual step is parked exactly once, and THREE separate triggers reach
//      `GuideSessionController.refreshPointingForTheOpenStep()` in that window
//      — none of which knows the other two exist:
//
//        1. the step-change refresh. The command before the gate succeeds, and
//           `advanceFromWithinAutopilot` -> `advanceToTheNextStep()` carries a
//           `defer { refreshPointingForTheOpenStep() }` (GuideSessionController
//           line 2546). The reader has landed on `install-xcode`.
//
//        2. the park's own refresh. The same drive-loop iteration then takes the
//           MANUAL branch for that step and calls
//           `handTheCurrentStepBackToTheReader()`, whose last line is
//           `refreshPointingForTheOpenStep()` (line 1969) — "fly the eye to
//           whatever the step points at, so a non-technical reader is shown
//           where to act". Same step, same target, one main-actor turn later.
//
//        3. the app-activation refresh. The very next statement in that branch
//           is `onAutopilotWaitingForReaderAtGate?(...)`, which is what
//           `CompanionManager` uses to raise and park the takeover terminal —
//           a window coming forward. `NSWorkspace.didActivateApplicationNotification`
//           is posted for the OBSERVING app's own activation too, so Iris's own
//           panel feeds `refreshPointingOnceAppActivationsHaveSettled`, whose
//           400ms quiet period then expires on the same unchanged step.
//
//      This test therefore posts that activation from inside the gate callback:
//      the same statement of the same branch, in the same order the field ran
//      it. (Posting is the honest simulation — the swiftc test runner has no
//      `NSApplication` session for the window server to activate, so the
//      notification AppKit would post is posted directly, on the same
//      `NSWorkspace.shared.notificationCenter` the controller really observes.)
//
//      MEASURED HERE: asks at +0.000s, +0.000s and +0.427s from the park — the
//      first two from the same main-actor turn (1 and 2), the third when the
//      coalescer's quiet period expires (3). The cofounder's log records two
//      asks 0.358s apart rather than three; which of these triggers reached the
//      paid rung on his Mac depends on what `GuidePointingLadder.decide` said at
//      each instant, and the log does not carry that. Two or three, it is one
//      defect and one count: nothing coordinates callers that are asking about
//      the same unchanged step.
//
//      Neither trigger knows about the others. Every call does
//      `pointingTask?.cancel()` and then starts a brand-new task, and Swift task
//      cancellation is cooperative: the only `Task.isCancelled` check on this
//      path sits AFTER `await GuideStepPointingCoordinator.resolve(...)` has
//      already run to completion, so the first ask's real capture and real HTTPS
//      round trip are neither stopped nor merged. Both asks complete — that is
//      what the log's two independent outcomes 2.4s apart show — and both spend
//      the step's model budget, which is why `maximumModelPointingAsksPerStep`
//      does not catch this either: two legitimate reservations, two real asks.
//
//      The fake model here therefore refuses to abort on cancellation (see
//      `waitOutAnUncancellableRoundTrip`): a `try? await Task.sleep` would unwind
//      the instant `cancel()` set the flag and would flatter the unfixed code
//      into looking as though the cancel had worked. A JPEG that has been
//      captured and a request that is on the wire do not come back.
//
//  (b) A COORDINATE THAT DESCRIBES A WINDOW WHERE IT USED TO BE. For an inferred
//      target the answer comes from `CompanionManager.locateGuideTargetWithModel`,
//      which crops the capture to the focused window's frame *at capture time*
//      (`CompanionScreenCaptureUtility.focusedWindowWorthCroppingTo` ->
//      `CompanionScreenCaptureWindowCrop.regionInFullScreenshotPixels`), keeps
//      only that pixel crop region, and then — 2.6 seconds later, on the log's
//      own numbers — maps the model's in-image coordinate back to a global point
//      through that same stale crop origin
//      (`CompanionManager.globalScreenLocation(fromScreenshotPoint:screenNumber:in:)`).
//      Nothing between the capture and the flight asks whether the window is
//      still there. Drag it while the model is thinking and the eye is off by
//      exactly the drag delta.
//
//      The fake model performs that production geometry step for step, against a
//      REAL `NSPanel` really moved on the real screen mid-ask. The assertion is
//      at the boundary the reader can see — the point handed to
//      `GuideSessionController.sendTheEyeTo`.
//
//      NOTE FOR WHOEVER FIXES THIS. The correction has to be visible at that
//      boundary, and this test deliberately leaves a seam for it that exists in
//      the shipped protocol already: `GuideTargetLocating.locateWindow(ofApp:)`
//      answers where a window is NOW, and here it is wired to the live panel
//      frame, exactly as `SystemGuideTargetLocator` answers from the live
//      accessibility tree. Nothing calls it for an inferred target today (see
//      `GuideStepPointingCoordinator.resolve`: the window rung is gated on
//      `target.isWindow`), which is why wiring it changes nothing about the
//      failure below. A fix that corrects the point only INSIDE
//      `locateGuideTargetWithModel` — behind the `askTheModel` closure this test,
//      like every pointing test in the suite, necessarily stands in for — cannot
//      be seen from here and will leave this red.
//

import AppKit
import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized)
struct Bug9PointingDoubleFireReproTests {

    // MARK: - The guide the log was installing

    /// Serves `GET /api/iris/guides/{slug}` with the kneecap branch the Test 9
    /// log was driving, step ids and titles included, so the step this suite
    /// parks on is the one the evidence is about: `install-xcode`, `kind=open`,
    /// `exec=false`, titled "Install Xcode".
    ///
    /// No `href` on that step, because the log shows it took the MANUAL branch:
    /// `stepIsFinishedOnceIrisHasOpenedIt` requires an `href`, and a step with
    /// one would have been auto-advanced instead of parked at a gate.
    final class Test9InstallGuideURLProtocol: URLProtocol {
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

    /// The step the log parked on, and the only step in this guide whose target
    /// is `.inferred` and therefore allowed to reach the model at all (no
    /// authored point, no command, `kind: open`).
    private static let titleOfTheStepTheReaderWasParkedOn = "Install Xcode"
    private static let indexOfTheStepTheReaderWasParkedOn = 3

    // MARK: - The install, with everything but the shell for real

    /// The pty-backed login shell, recorded rather than spawned. What
    /// `bun install` does is not what this bug is about; that the drive loop
    /// walks the three terminal steps and then hits the manual gate is.
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

    // MARK: - The model the pointing ladder asks

    /// Stands in for `CompanionManager.locateGuideTargetWithModel`: the one rung
    /// of the ladder that captures the screen and spends a paid model call.
    ///
    /// It records every ask with the wall-clock times the log records — when the
    /// ask started and when it finished — because the whole of half (a) is two
    /// asks that overlap in time, and a counter alone cannot show an overlap.
    @MainActor
    final class ThePointingModelTheGuideAsks: GuideTargetLocating {

        struct AskTheModelWasGiven {
            let stepTitle: String
            let ordinal: Int
            let startedAt: Date
        }

        private(set) var asksThatStarted: [AskTheModelWasGiven] = []
        private(set) var asksThatFinished: [(ordinal: Int, at: Date)] = []
        private(set) var timesTheAccessibilityTreeWasWalked = 0
        private(set) var timesAWindowWasLookedUp = 0

        /// What the model does with one ask: how long its capture and round trip
        /// take, and what it answers. Takes the ask's ordinal so a test can give
        /// the first and second asks the two different fates the log shows.
        private let answerTheModelGives: @MainActor (String, Int) async -> CGRect?

        /// Where the window the reader is working in is RIGHT NOW, if this
        /// scenario has one. `SystemGuideTargetLocator.locateWindow(ofApp:)`
        /// answers this from the live accessibility tree; here it is the live
        /// frame of a real `NSPanel`. Nil when the scenario has no such window.
        var whereTheReadersWindowIsNow: (@MainActor () -> CGRect?)?

        init(answerTheModelGives: @escaping @MainActor (String, Int) async -> CGRect?) {
            self.answerTheModelGives = answerTheModelGives
        }

        /// Nil, which is what puts the ladder on the model rung. The real walk
        /// answers nil for exactly this kind of step: "Install Xcode" names
        /// nothing in the frontmost app's accessibility tree.
        func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
            timesTheAccessibilityTreeWasWalked += 1
            return nil
        }

        func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
            timesAWindowWasLookedUp += 1
            return whereTheReadersWindowIsNow?()
        }

        func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
            let ordinal = asksThatStarted.count + 1
            asksThatStarted.append(
                AskTheModelWasGiven(stepTitle: stepTitle, ordinal: ordinal, startedAt: Date())
            )
            let answer = await answerTheModelGives(stepTitle, ordinal)
            asksThatFinished.append((ordinal: ordinal, at: Date()))
            return answer
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
    /// completion regardless — which is exactly what the log shows, two
    /// independent outcomes 2.4s apart from two asks 0.358s apart.
    ///
    /// `try? await Task.sleep(for:)` would model the opposite: it unwinds the
    /// instant the flag is set, and the unfixed code would look coalesced when
    /// it is not.
    private static func waitOutAnUncancellableRoundTrip(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    // MARK: - A reader driven to the gate the way the log was

    /// What the takeover was told when the install parked, and when.
    @MainActor
    final class WhatTheTakeoverWasToldWhenItParked {
        private(set) var titles: [String] = []
        private(set) var parkedAt: [Date] = []
        /// Run inside the park, in the place `CompanionManager` raises the
        /// takeover window — the moment a window of Iris's own comes forward.
        var whatHappensWhenTheTakeoverComesForward: (@MainActor () -> Void)?

        func record(title: String) {
            titles.append(title)
            parkedAt.append(Date())
            whatHappensWhenTheTakeoverComesForward?()
        }
    }

    /// Opens the guide from the log, starts the real autopilot, and lets the
    /// real drive loop run the three terminal steps and park on `install-xcode`
    /// — the same eight-second stretch the log records at 07:04:03 → 07:04:09.
    ///
    /// Returns as soon as the park has happened, with the pointing that the park
    /// itself started deliberately still in flight.
    private static func aReaderDrivenToTheInstallXcodeGate(
        locator: ThePointingModelTheGuideAsks,
        eyeFlights: @escaping @MainActor (CGPoint, CGRect, String) -> Void,
        theGuideCardIsOnScreen: (@MainActor () -> Bool)? = nil,
        whenTheTakeoverComesForward: (@MainActor () -> Void)? = nil
    ) async throws -> (
        controller: GuideSessionController,
        shell: TheShellTheInstallRunsIn,
        park: WhatTheTakeoverWasToldWhenItParked
    ) {
        let stubbedSessionConfiguration = URLSessionConfiguration.ephemeral
        stubbedSessionConfiguration.protocolClasses = [Test9InstallGuideURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "com.publik.iris.tests.bug9.\(UUID().uuidString)")
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
            eyeFlights(location, displayFrame, label)
        }
        if let theGuideCardIsOnScreen {
            controller.isTheGuideCardOnScreen = theGuideCardIsOnScreen
        }

        let park = WhatTheTakeoverWasToldWhenItParked()
        park.whatHappensWhenTheTakeoverComesForward = whenTheTakeoverComesForward
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
        #expect(controller.currentStepIndex == 0)

        controller.startAutopilot()
        let parked = await pump(within: 12) { park.titles.isEmpty == false }
        #expect(parked, "autopilot must reach the Install Xcode gate before either half of this test means anything")
        #expect(park.titles.last == titleOfTheStepTheReaderWasParkedOn)
        #expect(controller.currentStepIndex == indexOfTheStepTheReaderWasParkedOn)
        #expect(
            shell.commandsRun.contains { $0.contains("bun run build") },
            "the three terminal steps before the gate must really have run, or the gate was reached the wrong way"
        )
        return (controller, shell, park)
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

    // MARK: - (a) two model asks for one unchanged step

    @Test("parking one manual step spends several pointing model asks on one unchanged target")
    func theParkedStepIsPointedAtOverAndOverBecauseNothingCoordinatesItsTriggers() async throws {
        // The two fates the log records, in order. The first ask fails fast —
        // "no point — i couldn't reach the assistant", 07:04:10.341 -> 10.892,
        // 551ms. Every ask after it runs the full round trip and comes back
        // `model-said-none`, 07:04:10.699 -> 13.325, 2626ms. All of them answer
        // nil, so the eye never flies and this test is purely about how many
        // times the paid rung was entered.
        let locator = ThePointingModelTheGuideAsks { _, ordinal in
            if ordinal == 1 {
                await Self.waitOutAnUncancellableRoundTrip(milliseconds: 551)
                return nil
            }
            await Self.waitOutAnUncancellableRoundTrip(milliseconds: 2626)
            return nil
        }

        let eyeFlights = FlightRecorder()
        let (controller, _, park) = try await Self.aReaderDrivenToTheInstallXcodeGate(
            locator: locator,
            eyeFlights: { point, displayFrame, label in
                eyeFlights.record(point: point, displayFrame: displayFrame, label: label)
            },
            // 07:04:09.861 — "takeover: PARKED". `CompanionManager` raises and
            // parks the takeover terminal from this very callback, one statement
            // after the park's own `refreshPointingForTheOpenStep()`. A window of
            // Iris's own coming forward posts
            // `NSWorkspace.didActivateApplicationNotification` — AppKit posts it
            // for the observing app's own activation as readily as for anybody
            // else's — and the controller's observer starts its 400ms quiet
            // period. Nothing tells it that the park it is reacting to has
            // already refreshed pointing for this same step.
            whenTheTakeoverComesForward: {
                NSWorkspace.shared.notificationCenter.post(
                    name: NSWorkspace.didActivateApplicationNotification,
                    object: NSWorkspace.shared
                )
            }
        )
        let whenTheStepWasParked = try #require(park.parkedAt.last)

        // One second: comfortably past the 400ms coalescer, and still inside the
        // second ask's round trip, so nothing that happens on this Mac after the
        // measured window can add to the count.
        try await Task.sleep(for: .milliseconds(1000))

        let asksForTheParkedStep = locator.asks(forStepTitled: Self.titleOfTheStepTheReaderWasParkedOn)
        let secondsBetweenTheFirstTwoAsks = asksForTheParkedStep.count >= 2
            ? asksForTheParkedStep[1].startedAt.timeIntervalSince(asksForTheParkedStep[0].startedAt)
            : nil

        print("""
        [bug9-a] step index throughout: \(controller.currentStepIndex) (\(Self.titleOfTheStepTheReaderWasParkedOn))
        [bug9-a] model asks for this one step: \(asksForTheParkedStep.count)
        [bug9-a] each ask started at: \(asksForTheParkedStep.map { String(format: "+%.3fs", $0.startedAt.timeIntervalSince(whenTheStepWasParked)) })
        [bug9-a] each ask finished at: \(locator.asksThatFinished.map { String(format: "#%d +%.3fs", $0.ordinal, $0.at.timeIntervalSince(whenTheStepWasParked)) })
        [bug9-a] gap between the first two asks: \(secondsBetweenTheFirstTwoAsks.map { String(format: "%.3fs", $0) } ?? "-") (the log's is 0.358s)
        [bug9-a] accessibility walks: \(locator.timesTheAccessibilityTreeWasWalked)
        [bug9-a] eye flights: \(eyeFlights.flights.count)
        """)

        // The signature of the defect, checked before the count so a failure says
        // WHICH shape it failed in: every ask lands inside one second of the one
        // park, on a step that did not change, from triggers that knew nothing
        // about each other. A burst spread wider than that would be some other
        // story — a reader really switching apps minutes apart, say — and this
        // test would no longer be about the reported bug.
        if let secondsBetweenTheFirstTwoAsks {
            #expect(
                secondsBetweenTheFirstTwoAsks < 1.0,
                """
                the second ask came \(String(format: "%.3f", secondsBetweenTheFirstTwoAsks))s after the first, which is \
                too far apart to be the log's double-fire — this test is no longer reproducing the reported bug
                """
            )
        }
        #expect(
            asksForTheParkedStep.allSatisfy { $0.startedAt.timeIntervalSince(whenTheStepWasParked) < 1.0 },
            "an ask landed more than a second after the park, so this run is not the field's one-park burst"
        )

        // The log's own numbers say the first ask was still in flight when the
        // second started (10.699 < 10.892), so `pointingTask?.cancel()` did not
        // stop it: the capture was taken and the request was sent.
        #expect(
            locator.asksThatFinished.contains(where: { $0.ordinal == 1 }),
            "the first ask never finished, so this run is not the field's overlapping pair"
        )

        #expect(
            asksForTheParkedStep.count == 1,
            """
            parking "\(Self.titleOfTheStepTheReaderWasParkedOn)" once spent \(asksForTheParkedStep.count) \
            screen-capture-plus-model pointing asks on it. One manual step, one park, one unchanged \
            target — and the reader's Mac captured the screen and called the assistant \
            \(asksForTheParkedStep.count) times, because the step-change refresh, the park's own refresh \
            and the app-activation refresh know nothing about each other, and cancelling an earlier \
            pointing task does not stop the capture or the request it has already made
            """
        )
    }

    // MARK: - (b) the eye flies to where the control was

    /// Every flight the controller asked for, in order. A class because the two
    /// tests hand this closure to a controller that outlives the statement that
    /// built it.
    @MainActor
    final class FlightRecorder {
        private(set) var flights: [(point: CGPoint, displayFrame: CGRect, label: String)] = []

        func record(point: CGPoint, displayFrame: CGRect, label: String) {
            flights.append((point: point, displayFrame: displayFrame, label: label))
        }

        func lastFlight(labelled label: String) -> (point: CGPoint, displayFrame: CGRect, label: String)? {
            flights.last(where: { $0.label == label })
        }
    }

    /// A real window on the real screen, standing in for the one the reader
    /// drags while Iris is thinking.
    ///
    /// `.nonactivatingPanel` so raising it never steals focus from whatever the
    /// founder is doing, and `isMovableByWindowBackground` so a real drag
    /// gesture on its body moves it exactly as dragging any window does.
    private static func theWindowTheReaderIsWorkingIn(
        titled title: String, at frame: CGRect
    ) -> NSPanel {
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

    /// The reader picks the window up and puts it down somewhere else.
    ///
    /// This moves the real window through AppKit, the way the window server
    /// does when somebody drags a title bar, rather than by synthesizing the
    /// gesture. A synthesized press-drag-release (the `NSApp.postEvent` +
    /// `panel.sendEvent` shape `Test6TakeoverPanelReproTests` uses) was tried
    /// first and measured here: it moves this panel by exactly 0pt, because
    /// AppKit's own background-drag tracking loop pulls the rest of the gesture
    /// out of an event queue the swiftc test runner has no `NSApplication` to
    /// pump. The reader moving their window is the premise of this test, not
    /// the thing under test, so it is done the way that actually moves it.
    private static func theReaderMovesTheWindow(_ panel: NSPanel, by delta: CGPoint) {
        panel.setFrameOrigin(
            CGPoint(x: panel.frame.minX + delta.x, y: panel.frame.minY + delta.y)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @Test("a window moved while the model is thinking sends the eye to where the control was")
    func theEyeIsFlownToTheControlsOldPositionAfterTheReaderMovesTheWindow() async throws {
        let mainScreen = try #require(NSScreen.main)
        let usable = mainScreen.visibleFrame

        // A window and a drag that both fit comfortably inside the usable area
        // with room to spare, so nothing here is about the eye's edge clamping
        // (`placeTheEyeMayComeToRest`) — every point in this test is deep inside
        // the screen and neither the stale point nor the true one is clamped.
        let windowSize = CGSize(
            width: min(420, usable.width * 0.3),
            height: min(300, usable.height * 0.3)
        )
        // Three quarters of the window's width, so the control's OLD position
        // ends up outside the window's new frame entirely: after this drag the
        // eye is not merely off-centre, it is pointing at bare desktop beside a
        // window that has moved on.
        let dragDelta = CGPoint(x: windowSize.width * 0.75, y: -min(80, usable.height * 0.08))
        let startingFrame = CGRect(
            x: usable.midX - windowSize.width / 2 - dragDelta.x / 2,
            y: usable.midY - windowSize.height / 2 - dragDelta.y / 2,
            width: windowSize.width, height: windowSize.height
        )
        let window = Self.theWindowTheReaderIsWorkingIn(titled: "Xcode", at: startingFrame)
        defer { window.orderOut(nil) }
        let frameBeforeTheDrag = window.frame
        print("[bug9-b] the reader's window is up at \(frameBeforeTheDrag) on \(usable)")

        // Where the control the step is about sits inside that window, in the
        // window's own bottom-left coordinates. The model answers in the crop's
        // pixel space, which is this same offset expressed differently; what
        // matters is that it is fixed to the WINDOW, so it travels with it.
        let whereTheControlSitsInTheWindow = CGPoint(
            x: frameBeforeTheDrag.width / 2, y: frameBeforeTheDrag.height / 2
        )

        let whereTheWindowWasWhenTheScreenWasCaptured = WindowFrameAtCaptureTime()

        // The production geometry, step for step:
        //   1. capture the screen and crop it to the focused window's frame NOW
        //      (`focusedWindowWorthCroppingTo` -> `regionInFullScreenshotPixels`);
        //   2. spend 2.6s inside `ClaudeAPI.analyzeImageStreaming` — the log's
        //      own 07:04:10.699 -> 07:04:13.325;
        //   3. map the model's in-image coordinate back to a global point using
        //      the crop region from step 1, which is the only geometry
        //      `globalScreenLocation` has, and wrap it in the same 44pt square
        //      `locateGuideTargetWithModel` builds around it.
        // The reader's drag is performed between 1 and 2 rather than on a timer
        // of its own, so the ordering is exact rather than raced.
        //
        // Every ask spans a drag, because half (a) has just established that one
        // park produces more than one ask and only the last one's answer
        // survives (the earlier pointing tasks are cancelled, and their
        // `guard !Task.isCancelled` sits after `resolve` — so they resolve, then
        // throw the answer away). Moving the window only once would let a later
        // ask capture the already-moved window, answer correctly, and hide the
        // defect behind the double-fire.
        let locator = ThePointingModelTheGuideAsks { _, _ in
            await Self.waitOutAnUncancellableRoundTrip(milliseconds: 300)
            whereTheWindowWasWhenTheScreenWasCaptured.frame = window.frame
            print("[bug9-b] captured the screen with the window at \(window.frame)")

            Self.theReaderMovesTheWindow(window, by: dragDelta)
            print("[bug9-b] the reader moved the window to \(window.frame)")

            await Self.waitOutAnUncancellableRoundTrip(milliseconds: 2326)

            let stalePoint = CGPoint(
                x: whereTheWindowWasWhenTheScreenWasCaptured.frame.minX + whereTheControlSitsInTheWindow.x,
                y: whereTheWindowWasWhenTheScreenWasCaptured.frame.minY + whereTheControlSitsInTheWindow.y
            )
            let side: CGFloat = 44
            return CGRect(
                x: stalePoint.x - side / 2, y: stalePoint.y - side / 2, width: side, height: side
            )
        }
        // The live answer to "where is that window now", the same question
        // `SystemGuideTargetLocator.locateWindow(ofApp:)` puts to the
        // accessibility tree. See the note in this file's header: nothing on the
        // inferred path asks it today, which is the seam a fix can use and the
        // reason wiring it changes nothing about the failure below.
        locator.whereTheReadersWindowIsNow = { window.frame }

        let eyeFlights = FlightRecorder()
        let (controller, _, _) = try await Self.aReaderDrivenToTheInstallXcodeGate(
            locator: locator,
            eyeFlights: { point, displayFrame, label in
                eyeFlights.record(point: point, displayFrame: displayFrame, label: label)
            },
            // Half (b) is about WHERE the eye lands, not how often it is sent.
            // Telling the controller the guide card is not on screen leaves the
            // park's own refresh — the one that produces the flight measured
            // here — exactly as it is, while keeping app activations on this Mac
            // from adding a second resolution in the middle of the measurement.
            theGuideCardIsOnScreen: { false }
        )
        print("[bug9-b] parked at step \(controller.currentStepIndex), waiting out the model")

        let theEyeFlewForTheParkedStep = await Self.pump(within: 8) {
            eyeFlights.lastFlight(labelled: Self.titleOfTheStepTheReaderWasParkedOn) != nil
        }

        let frameAfterTheDrag = window.frame
        let whereTheControlIsNow = CGPoint(
            x: frameAfterTheDrag.minX + whereTheControlSitsInTheWindow.x,
            y: frameAfterTheDrag.minY + whereTheControlSitsInTheWindow.y
        )
        let whereTheControlWasAtCaptureTime = CGPoint(
            x: whereTheWindowWasWhenTheScreenWasCaptured.frame.minX + whereTheControlSitsInTheWindow.x,
            y: whereTheWindowWasWhenTheScreenWasCaptured.frame.minY + whereTheControlSitsInTheWindow.y
        )

        #expect(
            frameAfterTheDrag.origin != whereTheWindowWasWhenTheScreenWasCaptured.frame.origin,
            """
            the window did not move between the capture the flown answer came from and the flight itself, \
            so there is no stale coordinate to catch — it was at \(whereTheWindowWasWhenTheScreenWasCaptured.frame) \
            for the capture and is at \(frameAfterTheDrag) now, having started at \(frameBeforeTheDrag)
            """
        )
        #expect(theEyeFlewForTheParkedStep, "the eye never flew for the parked step")

        let flight = try #require(
            eyeFlights.lastFlight(labelled: Self.titleOfTheStepTheReaderWasParkedOn),
            "the eye never flew for \"\(Self.titleOfTheStepTheReaderWasParkedOn)\", so this test is not looking at the thing it claims to"
        )
        let howFarFromTheControl = hypot(
            flight.point.x - whereTheControlIsNow.x, flight.point.y - whereTheControlIsNow.y
        )

        print("""
        [bug9-b] step: \(controller.currentStepIndex) (\(flight.label))
        [bug9-b] window frame when the screen was captured: \(whereTheWindowWasWhenTheScreenWasCaptured.frame)
        [bug9-b] window frame when the eye flew:            \(frameAfterTheDrag)
        [bug9-b] the control was at \(whereTheControlWasAtCaptureTime) and is now at \(whereTheControlIsNow)
        [bug9-b] the eye was flown to \(flight.point) on display \(flight.displayFrame)
        [bug9-b] which is \(String(format: "%.1f", howFarFromTheControl))pt from the control
        [bug9-b] eye flights in total: \(eyeFlights.flights.count); model asks: \(locator.asksThatStarted.count)
        """)

        // Not a tolerance invented here: `GuideEyeFlightMemo` already treats two
        // answers more than a point apart as genuinely different answers, so a
        // point is the app's own smallest meaningful distance.
        #expect(
            howFarFromTheControl <= GuideEyeFlightMemo.distanceAtWhichTwoAnswersAreTheSameAnswer,
            """
            the reader moved the "\(window.title)" window while Iris was working out where to point, \
            and the eye was flown to \(flight.point) — \(String(format: "%.0f", howFarFromTheControl))pt away from the \
            control, at \(whereTheControlWasAtCaptureTime), which is where it was when the screenshot was taken, \
            \(String(format: "%.1f", frameAfterTheDrag.minX - whereTheWindowWasWhenTheScreenWasCaptured.frame.minX))pt \
            and \(String(format: "%.1f", frameAfterTheDrag.minY - whereTheWindowWasWhenTheScreenWasCaptured.frame.minY))pt ago. \
            "after moving a window the eye flies to where the control WAS."
            """
        )

        // And it is not a near miss inside the window: the old point is outside
        // the window's new frame altogether, so the eye is pointing at desktop.
        #expect(
            frameAfterTheDrag.contains(flight.point),
            """
            the eye landed at \(flight.point), which is outside the \(window.title) window's current frame \
            \(frameAfterTheDrag) entirely — it is pointing at bare desktop beside the window it was asked about
            """
        )
    }

    /// The one thing `locateGuideTargetWithModel` keeps about the window it
    /// cropped to — where it was when the shutter went — held in a class so the
    /// model closure can write it and the assertions can read it.
    @MainActor
    final class WindowFrameAtCaptureTime {
        var frame: CGRect = .zero
    }
}
