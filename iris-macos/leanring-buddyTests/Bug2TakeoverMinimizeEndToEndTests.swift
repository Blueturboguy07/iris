//
//  Bug2TakeoverMinimizeEndToEndTests.swift
//  leanring-buddyTests
//
//  BUG 2, END TO END — "No minimize on the takeover terminal (yellow light)."
//
//  `Bug2TakeoverMinimizeReproTests` reproduces the defect and names its
//  mechanism: the yellow light was a bare `Circle().fill(…)` that reported no
//  frame through `TakeoverControlFramesKey`, so the panel could not tell a
//  press on it from a press on the title-bar background and offered it to the
//  drag loop instead. Those tests prove it by watching closures the TEST itself
//  handed to `present(…)`.
//
//  THIS FILE IS THE REGRESSION GUARD, and it asks the reader's question rather
//  than the mechanism's: after the click, IS THE WINDOW GONE — and is the
//  install they were waiting on still running? Nothing between the finger and
//  that answer is stubbed —
//
//    - a real `GuideSessionController`, opened on a real guide (served from a
//      URLProtocol so the test never touches the network) and started with the
//      real `startAutopilot()`, which runs the REAL drive loop;
//    - the real `GuideAutopilotRunner`, driving the real risk gate, the real
//      transcript and the real `.running` state the terminal renders;
//    - the real manual gate: the drive loop's own MANUAL branch fires
//      `onAutopilotWaitingForReaderAtGate`, so the takeover is PARKED in the
//      bottom-right corner — the 400×340 card the Test 9 reader spent thirteen
//      minutes looking at, not a centred window standing in for it;
//    - the real `GuideAutopilotTakeoverController`, its real `NSPanel`s, the
//      real park animation and the real `NSHostingView` the lights live in;
//    - the yellow light found the way the reader finds it — the centroid of the
//      amber pixels in the real window's backing store, not a frame the fix
//      reports, so this file aims at the same dot before and after the fix;
//    - a real windowed `NSEvent` mouse-down + mouse-up delivered through
//      `NSApplication.shared.sendEvent(_:)` — the application's own dispatch,
//      which is what a hardware click goes through before any window sees it;
//    - and the assertions are the reader's own: the terminal panel is off the
//      screen, `autopilotIsRunning` is still true, the pane under the guide card
//      is showing the run again, the step they were parked on is still the step
//      they are on, and the install carries on to its next command with the
//      window folded away.
//
//  WHAT IS FAKED, AND WHY EXACTLY THESE TWO THINGS. The model transport (the
//  fix proposer) and the pty shell — the same two `Bug1TakeoverCloseClickEndTo
//  EndTests` fakes, for the same reasons. A test that spawned the reader's real
//  login shell and let a guide's real commands run would `git clone`,
//  `bun install` and build on the machine running the suite; and the fix ladder
//  would spend real money on a real model. The shell here RUNS NOTHING and
//  holds each command open until the test releases it, which is not a shortcut
//  but the field state itself: an install in flight is what makes the window
//  worth minimizing rather than closing.
//
//  WHAT IS TRANSCRIBED RATHER THAN CALLED. `CompanionManager` owns the real
//  wiring, but its `autopilotTakeoverController` and `presentAutopilotTakeover`
//  are `private`, and the only public way in — `CompanionManager.start()` —
//  boots permission polling, network calls, maintain mode and the overlay
//  windows, which a test on the founder's own Mac must not do. So
//  `TheYellowLightWiringCompanionManagerInstalls` below repeats those closures
//  verbatim from `CompanionManager.swift:1035-1098`, with the file:line on each
//  one, and nothing else. `onGuideCompleted` is deliberately NOT transcribed:
//  the real one opens the freshly installed app and refreshes the inventory,
//  and a test may not launch applications on this Mac.
//
//  THE GUIDE'S SECOND STEP IS A `verify`, NOT THE FIELD'S `permission`. The
//  drive loop's manual branch calls `autoOpenIfTheStepPointsSomewhere` first,
//  and for a `permission` step that opens System Settings on whatever machine
//  is running the suite (`GuideSessionController.swift:2032-2034`). A `verify`
//  step with no `href` and no `point` opens nothing and parks exactly the same
//  way, which is the only difference between this gate and the field's.
//

import AppKit
import Foundation
import Testing
@testable import Iris

// MARK: - The guide, served without a network

/// Answers `GET /api/iris/guides/kneecap` with the guide Test 9 was running —
/// the kneecap (OpenCut mobile port) Mac + iPhone branch, cut down to the three
/// steps this bug happens across: the command the takeover opens on, the manual
/// gate the reader was parked at when they wanted their screen back, and the
/// command that only runs if the install survived the minimize.
///
/// Its own protocol class rather than one borrowed from a neighbouring test
/// file: the harness compiles test files one command at a time, and a guard
/// that only works when another file happens to be in the same invocation is a
/// guard that will go missing the first time somebody runs this one alone.
private final class Bug2EndToEndKneecapGuideURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.kneecapGuideJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Nothing to unwind: the answer is delivered synchronously.
    }

    /// The exact shape `app/api/iris/guides/[slug]/route.ts` returns.
    /// `bun install` is deliberate: it is the field command, and it trips no
    /// confirm rule, so the step runs on the reader's autonomy grant OR without
    /// it — `GuideAutopilotRiskAssessment.assess` reads the process-wide
    /// `AutopilotAutonomyGrant.shared`, which a test may read but must never
    /// write, so the command has to be one that is waved through either way.
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
      "estimatedMinutes": 30,
      "readmeSectionIds": [],
      "branches": [
        {
          "platform": "macos",
          "target": "ios",
          "label": "Mac + iPhone",
          "shell": "terminal",
          "setupSteps": [],
          "steps": [
            {"id": "install-deps", "kind": "terminal", "title": "Install the workspace",
             "body": "", "command": "bun install"},
            {"id": "run", "kind": "verify", "title": "Plug in your iPhone and press play",
             "body": "Pick your iPhone in the device menu, then the play button. First build is slow."},
            {"id": "confirm", "kind": "check", "title": "Check it landed on your phone",
             "body": "", "command": "xcrun devicectl list devices"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

// MARK: - The two things that are not real, and nothing else

/// A shell driver that executes NOTHING and holds each command open until the
/// test says that step finished.
///
/// Holding is the point twice over. It is the field state — the reader reaches
/// for a traffic light with work in flight — and it is what stops the drive
/// loop racing to the end of the guide and folding the takeover away by itself
/// before this file has aimed at anything. Every command holds, not just the
/// first: the command AFTER the gate has to still be running when the test
/// looks, or "the install carried on" could not be told from "the install
/// finished and stopped".
///
/// The wait is polled rather than parked on a continuation so that `endSession`
/// and `cancelTheRunningCommand` — both of which the real teardown reaches —
/// release it from anywhere, and so that a test that forgets to tear down still
/// ends: `longestItWillEverHold` is a backstop, never the normal path.
@MainActor
private final class ShellThatHoldsEachCommandUntilTheTestReleasesIt:
    GuideAutopilotShellSessionDriving {
    var onOutputLine: ((String) -> Void)?
    var currentWorkingDirectory = NSHomeDirectory()
    var resolvedSearchPath: String? = "/usr/bin:/bin"

    private(set) var commandsItWasAskedToRun: [String] = []
    /// How many times something asked the shell to abandon the command in
    /// flight. A minimize must never be one of them.
    private(set) var timesItWasToldToCancelTheRunningCommand = 0
    private var theCommandInFlightWasReleased = false

    /// Long enough that no takeover animation can outlast it, short enough that
    /// a mistake costs the suite seconds rather than minutes.
    private static let longestItWillEverHold: TimeInterval = 20

    func start() async -> Bool { true }

    func run(
        _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        commandsItWasAskedToRun.append(command.text)
        theCommandInFlightWasReleased = false
        onOutputLine?("$ \(command.text)")
        let startedAt = Date()
        while !theCommandInFlightWasReleased,
              Date().timeIntervalSince(startedAt) < Self.longestItWillEverHold {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .succeeded(workingDirectory: currentWorkingDirectory)
    }

    /// The command in flight finishes cleanly, the way `bun install` finished
    /// for the Test 9 reader before the guide put them in front of Xcode. The
    /// next command holds again.
    func theCommandInFlightFinishes() {
        onOutputLine?("done")
        theCommandInFlightWasReleased = true
    }

    func cancelTheRunningCommand() async {
        timesItWasToldToCancelTheRunningCommand += 1
        theCommandInFlightWasReleased = true
    }

    func endSession() async { theCommandInFlightWasReleased = true }
    func tailForTheModel() -> String { "" }
}

/// The model transport, faked at the only place a guide install reaches one.
/// Returning nil is what a fix ladder with nothing to propose does, so the
/// drive loop takes its real "surface it to the reader" path rather than a path
/// invented for the test. Nothing in this file fails a command, so it is only
/// ever the guarantee that no test here can reach a model.
private final class Bug2EndToEndFixProposerThatNeverReachesAModel: GuideAutopilotFixProposing {
    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? { nil }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? { nil }
}

// MARK: - CompanionManager's wiring, transcribed

/// The guide session and the takeover controller, connected exactly the way
/// `CompanionManager` connects them — including the line the fix added, which
/// is the caller's half of the yellow light.
///
/// Every closure below is copied from `CompanionManager.swift` with its line
/// number, because that file's real objects are unreachable from a test (see
/// this file's header). Nothing else about a `CompanionManager` is recreated:
/// the two controllers ARE the app's, and this holder is only the cable between
/// them.
@MainActor
private final class TheYellowLightWiringCompanionManagerInstalls {
    let guideSessionController: GuideSessionController
    let takeoverController = GuideAutopilotTakeoverController()
    let shell = ShellThatHoldsEachCommandUntilTheTestReleasesIt()

    /// The terminal panel THIS wiring raised — captured across the single
    /// synchronous statement that raises it, rather than found by scanning
    /// `NSApplication.shared.windows` some `await` later.
    ///
    /// It has to be captured that way because Swift Testing runs SUITES in
    /// parallel (`.serialized` orders the tests inside one suite, not the suites
    /// against each other), and every takeover in the app is the same panel
    /// class at the same frames. A scan that runs after a suspension point can
    /// hand back the window a test in ANOTHER suite raised in between — and
    /// then this file clicks that window and reports that minimize did nothing.
    private(set) var theTerminalItRaised: GuideAutopilotTakeoverTerminalPanel?

    /// What the parked card was told to say. The drive loop reaching its manual
    /// branch is how this file knows the takeover is parked over the reader's
    /// work rather than centred and busy.
    private(set) var titlesTheTakeoverWasParkedFor: [String] = []

    init() throws {
        let stubbedConfiguration = URLSessionConfiguration.ephemeral
        stubbedConfiguration.protocolClasses = [Bug2EndToEndKneecapGuideURLProtocol.self]
        let shellThatRunsNothing = shell
        guideSessionController = GuideSessionController(
            guideService: GuideService(
                apiBase: GuideService.defaultAPIBase,
                urlSession: URLSession(configuration: stubbedConfiguration),
                // An isolated suite so a test never reads or writes the
                // founder's own saved place in a guide.
                userDefaults: try #require(
                    UserDefaults(suiteName: "iris.bug2.e2e.\(UUID().uuidString)")
                )
            ),
            // Answered from here rather than from this Mac: the drive loop and
            // the watch loop both probe for tools, and what is installed on the
            // machine running the suite must not decide whether the guide
            // reaches its gate.
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            // The factory `CompanionManager.swift:164-203` installs, with the
            // pty shell and the model-backed fix proposer swapped for the two
            // fakes above and everything else — the runner, its state machine,
            // its transcript — left real. `.instant` pacing only removes the
            // typewriter and the 0.7s minimum result hold, which are display
            // dressing; the reader's thirteen minutes are not what this file
            // is reproducing.
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shellThatRunsNothing,
                    longRunningSession: shellThatRunsNothing,
                    fixProposer: Bug2EndToEndFixProposerThatNeverReachesAModel(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )

        // The reader's one-time "Let Iris take control of your Mac?" grant, over
        // an isolated suite for the same reason the guide service gets one.
        guideSessionController.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug2.e2e.grant.\(UUID().uuidString)")
            )
        )
        guideSessionController.confirmAutonomousControl = { true }

        // CompanionManager.swift:1035-1037
        guideSessionController.onAutopilotDidStart = { [weak self] in
            self?.presentAutopilotTakeover()
        }
        // CompanionManager.swift:1039-1043
        guideSessionController.onAutopilotDidStop = { [weak self] in
            self?.takeoverController.dismiss(afterHold: false)
        }
        // CompanionManager.swift:1045-1051
        guideSessionController.onAutopilotWaitingForReaderAtGate = {
            [weak self] title, instruction in
            self?.titlesTheTakeoverWasParkedFor.append(title)
            self?.takeoverController.parkForManualStep(title: title, instruction: instruction)
        }
        // CompanionManager.swift:1053-1057
        guideSessionController.onAutopilotResumedFromGate = { [weak self] in
            self?.takeoverController.returnToCenter()
        }
        // `onGuideCompleted` is NOT wired: the real one opens the freshly
        // installed app and refreshes the app inventory, and a test must not
        // launch applications on the founder's Mac. Nothing here finishes a
        // guide, because every command holds.
    }

    /// CompanionManager.swift:1078-1098, verbatim except for the two lines that
    /// capture the window (see `theTerminalItRaised`) — including the
    /// `afterTheReaderMinimizesIt` closure, which is the caller's half of the
    /// line this whole file exists to exercise.
    ///
    /// Not private: raising the takeover again after the reader has minimized it
    /// is one of the outcomes under test, and this is the method the app itself
    /// would call to do it.
    func presentAutopilotTakeover() {
        guard let runner = guideSessionController.autopilotRunner else { return }
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        guideSessionController.setAutopilotIsShownAsTakeover(true)
        takeoverController.present(
            runner: runner,
            onApproveRiskyCommand: { [weak self] in
                self?.guideSessionController.approveThePendingRiskyCommand()
            },
            onSkipRiskyCommand: { [weak self] in
                self?.guideSessionController.skipThePendingRiskyCommand()
            },
            onRetrySurfacedStep: { [weak self] in
                self?.guideSessionController.retryTheSurfacedStep()
            },
            onContinuePastSurfacedStep: { [weak self] in
                self?.guideSessionController.skipTheSurfacedStepAndContinue()
            },
            onReaderFinishedManualStep: { [weak self] in
                self?.guideSessionController.readerFinishedTheGatedStep()
            },
            onEscapeHatch: { [weak self] in
                self?.guideSessionController.abortOrCloseAutopilotFromTheEscapeHatch()
            },
            // The takeover has folded away with the install still running, so
            // the pane under the guide card — suppressed only while the
            // takeover is up — shows the rest of it.
            afterTheReaderMinimizesIt: { [weak self] in
                self?.guideSessionController.setAutopilotIsShownAsTakeover(false)
            }
        )
        theTerminalItRaised = NSApplication.shared.windows
            .compactMap { $0 as? GuideAutopilotTakeoverTerminalPanel }
            .first { !windowsBefore.contains(ObjectIdentifier($0)) }
    }

    /// Opens the guide and presses "Let Iris run it", which is the only entry
    /// point that begins execution.
    func theReaderOpensTheGuideAndLetsIrisRunIt() async {
        await guideSessionController.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:ios", stepIndexFromDeepLink: nil
        )
        // `startAutopilot()` calls `onAutopilotDidStart` synchronously
        // (`GuideSessionController.swift:1454`), which presents the takeover
        // synchronously and captures the panel inside that one statement.
        guideSessionController.startAutopilot()
    }

    /// Leaves nothing running behind a finished test: the held command is
    /// released through the same `endSession` the real teardown uses, and any
    /// window still up is folded away.
    func tearDown() {
        guideSessionController.stopAutopilot()
        takeoverController.dismiss(afterHold: false)
    }
}

// MARK: - The tests

@MainActor
@Suite(.serialized) struct Bug2TakeoverMinimizeEndToEndTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel

    /// The 24pt title strip the three traffic lights live in.
    /// `heightOfTheTitleStrip` is private to the panel, so it is spelled out
    /// here the way `Test8TakeoverControlClickTests` and the repro spell it out.
    private static let heightOfTheTitleStrip: CGFloat = 24

    /// How long the entry morph plus SwiftUI's preference plumbing need before
    /// the window's pixels and its reported control frames describe where the
    /// lights actually are — the value Test8 and both Bug repro files settle on.
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    /// A park is a 0.5s slide to the bottom-right corner; this is the beat that
    /// lets it land before anything measures where the lights ended up.
    private static let parkSettleNanoseconds: UInt64 = 900_000_000

    // MARK: Driving the real window

    /// Polls a main-actor condition instead of sleeping a fixed amount: the
    /// takeover animates on its own clock, so a fixed sleep is a coin flip on a
    /// loaded machine (Test7's lesson, kept by Test8 and both repro files).
    private static func pump(
        within seconds: Double = 10, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    /// One click at a point in the terminal's own content coordinates,
    /// delivered the way a HARDWARE click arrives: a windowed `NSEvent`
    /// carrying the panel's own `windowNumber`, handed to
    /// `NSApplication.shared.sendEvent(_:)` rather than to the panel directly.
    ///
    /// Through NSApp on purpose. The repro next door calls `panel.sendEvent`,
    /// which is one hop short of what really happens: AppKit pulls the event off
    /// the queue, hands it to the application, and the application routes it to
    /// `event.window`. Going through that routing is the difference between "the
    /// panel's dispatch works" and "a click on this Mac works".
    ///
    /// `driftInPoints` is how far the pointer travels between the finger going
    /// down and coming up; 4pt is a real finger's drift, past the panel's 3pt
    /// click slop.
    ///
    /// ON THE UNFIXED CODE THIS CALL TAKES 30 SECONDS, and that is the bug's own
    /// fingerprint rather than a flaw in the test: a press that lands on a
    /// REPORTED control is handed straight to SwiftUI and returns at once, while
    /// a press that lands on anything else is held by the panel's tracking loop,
    /// which waits `longestAGestureIsWatched` (30s) for a release that a
    /// synthesized click never posts. Today's yellow light is a control; before
    /// the fix it was one of those "anything else" presses.
    private static func deliverAClickThroughTheApplication(
        to terminal: Panel, atContentPoint point: CGPoint, driftInPoints: CGFloat
    ) {
        // Content-view coordinates are top-left origin (SwiftUI `.global` inside
        // the flipped hosting view that IS the content view); an event's
        // `locationInWindow` is bottom-left origin, so the y flips through the
        // window height — the inverse of the flip `pressLandsOnAControl` does.
        let downInWindow = CGPoint(x: point.x, y: terminal.frame.height - point.y)
        let upInWindow = CGPoint(
            x: point.x + driftInPoints, y: terminal.frame.height - (point.y + driftInPoints)
        )
        func windowedEvent(_ type: NSEvent.EventType, at location: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: terminal.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        if let down = windowedEvent(.leftMouseDown, at: downInWindow) {
            NSApplication.shared.sendEvent(down)
        }
        if let up = windowedEvent(.leftMouseUp, at: upInWindow) {
            NSApplication.shared.sendEvent(up)
        }
    }

    // MARK: Finding the light the reader aims at

    /// Where the YELLOW traffic light is DRAWN, in the terminal's content
    /// coordinates: the centroid of the amber pixels in the title strip of the
    /// real window's backing store.
    ///
    /// Measured from the pixels rather than read from `interactiveControlFrames`
    /// on purpose — a guard that asked the fix where its own button is would aim
    /// nowhere at all on the code that has no such button, and would report a
    /// missing measurement instead of a window that will not go away. The dot is
    /// what the reader aims at either way, so the dot is what this aims at.
    ///
    /// The bands are wide enough that a colour-space shift between the window's
    /// backing store and `deviceRGB` cannot move the answer, and they exclude
    /// the other two lights outright: the red light's green channel is 0.373
    /// (below 0.55) and the green light's red channel is 0.157 (below 0.70).
    /// Repeated from `Bug2TakeoverMinimizeReproTests` rather than shared with
    /// it because the harness compiles test files one command at a time.
    private static func centreOfTheYellowTrafficLight(in terminal: Panel) throws -> CGPoint {
        let contentView = try #require(
            terminal.contentView, "the takeover terminal has no content view to measure"
        )
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        // The left end of the 24pt title strip, which holds all three lights
        // (10pt inset, then hit targets and dots at 7pt spacing) and nothing
        // else. Kept clear of the centred "iris — install" title.
        let leftEndOfTheTitleStrip = NSRect(x: 0, y: 0, width: 160, height: heightOfTheTitleStrip)
        let backingStore = try #require(
            contentView.bitmapImageRepForCachingDisplay(in: leftEndOfTheTitleStrip),
            "could not read the takeover terminal's backing store"
        )
        contentView.cacheDisplay(in: leftEndOfTheTitleStrip, to: backingStore)

        let pixelsPerPointAcross = CGFloat(backingStore.pixelsWide) / leftEndOfTheTitleStrip.width
        let pixelsPerPointDown = CGFloat(backingStore.pixelsHigh) / leftEndOfTheTitleStrip.height
        var amberPixelsAcross = 0.0
        var amberPixelsDown = 0.0
        var amberPixelCount = 0.0
        for x in 0..<backingStore.pixelsWide {
            for y in 0..<backingStore.pixelsHigh {
                guard let sample = backingStore.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let red = sample.redComponent
                let green = sample.greenComponent
                let blue = sample.blueComponent
                guard red > 0.70, green > 0.55, green < 0.85, blue < 0.40,
                      red > green, green > blue else { continue }
                amberPixelsAcross += Double(x)
                amberPixelsDown += Double(y)
                amberPixelCount += 1
            }
        }

        // An 11pt dot is ~95 solid pixels at 1x and ~380 at 2x; 40 is well under
        // either and well over any stray antialiased edge.
        try #require(
            amberPixelCount >= 40,
            """
            only \(Int(amberPixelCount)) amber pixel(s) in the title strip, so the yellow \
            traffic light was not found and there is nothing to aim at. This is a measurement \
            failure, not the bug.
            """
        )
        return CGPoint(
            x: leftEndOfTheTitleStrip.minX + CGFloat(amberPixelsAcross / amberPixelCount)
                / pixelsPerPointAcross,
            y: leftEndOfTheTitleStrip.minY + CGFloat(amberPixelsDown / amberPixelCount)
                / pixelsPerPointDown
        )
    }

    /// The RED escape hatch: the leftmost control frame reported in the title
    /// strip. It is a real `Button` before and after this fix, which is what
    /// makes it this file's control — see
    /// `theRedLightBesideItStillMeansStopTheInstall`.
    private static func frameOfTheRedTrafficLight(in terminal: Panel) throws -> CGRect {
        try #require(
            terminal.interactiveControlFrames
                .filter { $0.minY < heightOfTheTitleStrip }
                .min { $0.minX < $1.minX },
            """
            no control in the 24pt title strip reported a frame to the panel, so the frame \
            plumbing this test reads is not running at all — a measurement failure, not the bug
            """
        )
    }

    // MARK: The window the field reports leave the reader under

    /// Test 9's window, rebuilt through the real drive loop: the takeover raised
    /// over the kneecap install, the first command run and finished, and the
    /// guide parked at "Plug in your iPhone and press play" — the manual gate
    /// the reader was sitting at, with the card slid into the bottom-right
    /// corner and the desktop undimmed, when they spent thirteen minutes wanting
    /// this window out of the way of the Xcode it had just told them to use.
    private static func aTakeoverParkedOverTheReadersOwnWork() async throws
        -> (TheYellowLightWiringCompanionManagerInstalls, Panel) {
        let iris = try TheYellowLightWiringCompanionManagerInstalls()
        await iris.theReaderOpensTheGuideAndLetsIrisRunIt()

        let terminal = try #require(
            iris.theTerminalItRaised,
            """
            "Let Iris run it" did not raise a takeover terminal at all, so there is no window \
            for the reader to be stuck under and nothing for this test to click
            """
        )
        try #require(
            await pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        try #require(
            await pump(within: 5) { iris.shell.commandsItWasAskedToRun.isEmpty == false },
            "the drive loop never reached the guide's first command"
        )

        // `bun install` finishes, and the guide's next step is the one only the
        // reader can do — so the drive loop parks the takeover and waits.
        iris.shell.theCommandInFlightFinishes()
        try #require(
            await pump(within: 15) {
                iris.titlesTheTakeoverWasParkedFor.contains("Plug in your iPhone and press play")
            },
            """
            autopilot never reached the manual gate, so the takeover is not parked over the \
            reader's work and this test is not in the state the field report describes
            """
        )
        try await Task.sleep(nanoseconds: parkSettleNanoseconds)
        try #require(
            terminal.isVisible,
            "the takeover terminal is not on screen, so 'is it gone afterwards' means nothing"
        )
        try #require(
            await pump {
                terminal.interactiveControlFrames.contains { $0.minY < heightOfTheTitleStrip }
            },
            """
            no title-strip control reported a frame after the park — the frame plumbing this \
            file reads is not running, which is a measurement failure, not the bug
            """
        )
        return (iris, terminal)
    }

    // MARK: THE GUARD — the yellow light

    /// "No minimize on the takeover terminal (yellow light)", asked as the
    /// reader asks it: one click on the yellow dot, delivered through the
    /// application, and then the two things that have to be true together — the
    /// window is off my screen, AND the install I have been waiting on is still
    /// running. Either alone is a light they already had: the red one takes the
    /// window away by ending the run, and doing nothing leaves the run alone.
    @Test func theYellowLightGivesTheReaderTheirScreenBackWithoutEndingTheInstall() async throws {
        let (iris, terminal) = try await Self.aTakeoverParkedOverTheReadersOwnWork()
        defer { iris.tearDown() }

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: terminal)
        let whereTheParkedCardWas = terminal.frame.origin
        let stepTheReaderWasParkedOn = iris.guideSessionController.currentStepIndex
        let commandsBeforeTheClick = iris.shell.commandsItWasAskedToRun

        // The card's position is read the instant the click returns, BEFORE the
        // run loop turns: a fold-away is scheduled on the next turn and moves the
        // window itself, so reading it later could not tell a drag from a fold.
        Self.deliverAClickThroughTheApplication(
            to: terminal, atContentPoint: yellowLight, driftInPoints: 4
        )
        let whereTheCardWasWhenTheClickReturned = terminal.frame.origin

        #expect(
            whereTheCardWasWhenTheClickReturned == whereTheParkedCardWas,
            """
            the press on the yellow light at \(yellowLight) slid the parked card from \
            \(whereTheParkedCardWas) to \(whereTheCardWasWhenTheClickReturned) instead of doing \
            anything — "it is just moving the terminal around" (Test 8), here because the light \
            is not a control the panel excludes from its drag loop
            """
        )
        #expect(
            await Self.pump(within: 8) {
                iris.takeoverController.isPresented == false && terminal.isVisible == false
            },
            """
            the reader clicked the yellow traffic light at \(yellowLight) and the takeover \
            terminal is STILL ON SCREEN (presented=\(iris.takeoverController.isPresented), \
            visible=\(terminal.isVisible), frame=\(terminal.frame)). That is the report: "No \
            minimize on the takeover terminal (yellow light)". Parked at "Plug in your iPhone \
            and press play", the reader's only working light was the red one — which ENDS the \
            install they were waiting on
            """
        )
        #expect(
            iris.guideSessionController.autopilotIsRunning,
            """
            the window went away and took the install with it. Minimize is not a second close \
            button: the whole reason a reader reaches for yellow instead of red is that the run \
            keeps going
            """
        )
        #expect(
            iris.shell.timesItWasToldToCancelTheRunningCommand == 0,
            """
            minimizing the window asked the shell to abandon what it was running \
            (\(iris.shell.timesItWasToldToCancelTheRunningCommand) cancel(s)) — that is the red \
            light's job, not this one's
            """
        )
        #expect(
            await Self.pump(within: 5) {
                iris.guideSessionController.autopilotIsShownAsTakeover == false
            },
            """
            the takeover folded away but `autopilotIsShownAsTakeover` is still true, so the pane \
            under the guide card stays suppressed (`OverlayEyeInputBar.swift:721-722`) and the \
            reader is left with no surface at all for a run that is still going — the window \
            gone AND the terminal gone
            """
        )
        // Minimizing costs the reader their screen back, never their place.
        #expect(
            iris.guideSessionController.loadState == .guideIsOpen,
            "minimizing the takeover must leave the guide open where the reader left it"
        )
        #expect(
            iris.guideSessionController.currentStepIndex == stepTheReaderWasParkedOn,
            """
            minimizing moved the guide from step \(stepTheReaderWasParkedOn) to step \
            \(iris.guideSessionController.currentStepIndex) — folding a window away must not \
            answer the gate it was parked at
            """
        )
        #expect(
            iris.shell.commandsItWasAskedToRun == commandsBeforeTheClick,
            """
            minimizing ran something: \(iris.shell.commandsItWasAskedToRun) against \
            \(commandsBeforeTheClick) before the click
            """
        )
    }

    // MARK: THE GUARD — and the install goes on without the window

    /// A minimize is only worth having if the install keeps moving while the
    /// window is down and the window comes back when it is needed again.
    ///
    /// So: fold it away, finish the manual step from the pane under the guide
    /// card the way the reader now can (`readerFinishedTheGatedStep()` is what
    /// that continue button calls), and watch the guide's NEXT command actually
    /// run with no takeover on screen. Then let Iris raise the takeover again —
    /// `present(…)` guards on `terminalPanel == nil`, so a fold-away that leaves
    /// the panel up, or a teardown that does not finish, silently refuses the
    /// next one and the reader never sees their install again.
    @Test func theInstallCarriesOnWithTheWindowFoldedAwayAndTheTakeoverComesBack() async throws {
        let (iris, terminal) = try await Self.aTakeoverParkedOverTheReadersOwnWork()
        defer { iris.tearDown() }

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: terminal)
        Self.deliverAClickThroughTheApplication(
            to: terminal, atContentPoint: yellowLight, driftInPoints: 4
        )
        try #require(
            await Self.pump(within: 8) { iris.takeoverController.isPresented == false },
            """
            the takeover never folded away when the yellow light at \(yellowLight) was clicked, \
            so what happens afterwards cannot be told apart from it never having gone — see \
            theYellowLightGivesTheReaderTheirScreenBackWithoutEndingTheInstall
            """
        )

        let commandsBeforeTheGateWasCleared = iris.shell.commandsItWasAskedToRun.count
        let transcriptBeforeTheGateWasCleared =
            iris.guideSessionController.autopilotRunner?.transcript.count ?? 0
        iris.guideSessionController.readerFinishedTheGatedStep()

        #expect(
            await Self.pump(within: 15) {
                iris.shell.commandsItWasAskedToRun.count > commandsBeforeTheGateWasCleared
            },
            """
            with the takeover minimized the reader finished the manual step and the install did \
            NOT carry on: the guide's next command was never run \
            (\(iris.shell.commandsItWasAskedToRun)). Folding the window away must leave the run \
            exactly as it was — that is the entire difference between this light and the red one
            """
        )

        // Iris needs the window back: the next gate, the next surfaced step.
        iris.presentAutopilotTakeover()
        let theTakeoverTheSecondTime = try #require(
            iris.theTerminalItRaised,
            """
            after the reader minimized it, Iris could not raise the takeover again — \
            `present(…)` refuses while `terminalPanel` is still set, so the install carries on \
            with no window the reader can watch it in
            """
        )
        #expect(
            theTakeoverTheSecondTime !== terminal,
            "the second takeover must be a new panel, not the one the reader folded away"
        )
        #expect(
            await Self.pump(within: 8) { theTakeoverTheSecondTime.frame.width > 700 },
            "the takeover came back but never grew out of the eye"
        )
        #expect(
            iris.guideSessionController.autopilotIsShownAsTakeover,
            """
            the takeover is back on screen but the under-the-card pane was not suppressed again, \
            so the reader is shown the same terminal twice
            """
        )
        #expect(
            (iris.guideSessionController.autopilotRunner?.transcript.count ?? 0)
                >= transcriptBeforeTheGateWasCleared,
            """
            the transcript the reader was watching was thrown away across the minimize: \
            \(iris.guideSessionController.autopilotRunner?.transcript.count ?? 0) entries now \
            against \(transcriptBeforeTheGateWasCleared) before
            """
        )
    }

    // MARK: THE CONTROL — the light beside it, which always worked

    /// The control, in the same file rather than in another one: if a change to
    /// the click path ever breaks EVERY button in this window, the two guards
    /// above go red and say "minimize does nothing", which is the wrong story
    /// and the wrong fix. So the same delivery is aimed at the red escape hatch
    /// — a real `Button` before and after this fix — and the assertion is the
    /// one thing that must stay DIFFERENT about it: red takes the window away by
    /// ending the install.
    @Test func theRedLightBesideItStillMeansStopTheInstall() async throws {
        let (iris, terminal) = try await Self.aTakeoverParkedOverTheReadersOwnWork()
        defer { iris.tearDown() }

        let redLight = try Self.frameOfTheRedTrafficLight(in: terminal)
        Self.deliverAClickThroughTheApplication(
            to: terminal, atContentPoint: CGPoint(x: redLight.midX, y: redLight.midY),
            driftInPoints: 4
        )

        #expect(
            await Self.pump(within: 8) {
                iris.takeoverController.isPresented == false && terminal.isVisible == false
            },
            """
            the red escape hatch at \(redLight) did not close the takeover through the same \
            click delivery the yellow light is tested with. This test failing ALONE means the \
            click path itself is broken and the two guards above prove nothing; this test \
            failing ALONGSIDE them is a different bug from the one they guard
            """
        )
        #expect(
            await Self.pump(within: 5) { iris.guideSessionController.autopilotIsRunning == false },
            """
            the red light folded the window away and left the install running — red and yellow \
            have collapsed into the same control, and the reader has no way to stop a runaway \
            install
            """
        )
    }
}
