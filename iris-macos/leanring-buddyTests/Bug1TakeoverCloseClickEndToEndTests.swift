//
//  Bug1TakeoverCloseClickEndToEndTests.swift
//  leanring-buddyTests
//
//  BUG 1, END TO END — "Terminal Close (red light) and Help do nothing."
//
//  `Bug1TakeoverCloseClickReproTests` reproduces the defect and names its
//  mechanism: the `.nativeTooltip(…)` overlay had no `hitTest(_:)` override, so
//  AppKit handed the press to an inert `NSView` and the SwiftUI `Button`
//  underneath never saw it. Those tests prove it by watching a closure the TEST
//  itself handed to `present(…)`.
//
//  THIS FILE IS THE REGRESSION GUARD, and it asks the reader's question instead
//  of the mechanism's: after the click, IS THE WINDOW GONE? Nothing between the
//  finger and that outcome is stubbed —
//
//    - a real `GuideSessionController`, opened on a real guide (served from a
//      URLProtocol so the test never touches the network) and started with the
//      real `startAutopilot()`, which runs the REAL drive loop;
//    - the real `GuideAutopilotRunner`, driving the real risk gate, the real
//      transcript and the real `.running` state the terminal renders;
//    - the real `GuideAutopilotTakeoverController`, its real `NSPanel`s, the
//      real entry morph and the real `NSHostingView` the buttons live in;
//    - a real windowed `NSEvent` mouse-down + mouse-up delivered through
//      `NSApplication.shared.sendEvent(_:)` — the application's own dispatch,
//      which is what a hardware click goes through before any window sees it;
//    - the real escape hatch: `abortOrCloseAutopilotFromTheEscapeHatch()` →
//      `stopAutopilot()` → `onAutopilotDidStop` → `dismiss(afterHold: false)`;
//    - and the assertion is the reader's own: the terminal panel is no longer
//      on screen, the install has stopped, and the guide is still open at the
//      step they were on.
//
//  WHAT IS FAKED, AND WHY EXACTLY THESE TWO THINGS. The model transport (the
//  fix proposer) and the pty shell. A test that spawned the reader's real login
//  shell and let a guide's real commands run would `git clone`, `bun install`
//  and build on the machine running the suite; and the fix ladder would spend
//  real money on a real model. So the shell driver here RUNS NOTHING and simply
//  holds the step open — which is not a shortcut but the field state itself: in
//  Test 9 and Test 10 the reader reached for the red light while a step was in
//  flight, and holding the step is what makes the terminal look exactly the way
//  it looked when they did.
//
//  WHAT IS TRANSCRIBED RATHER THAN CALLED. `CompanionManager` owns the real
//  wiring, but its `autopilotTakeoverController` and `presentAutopilotTakeover`
//  are `private`, and the only public way in — `CompanionManager.start()` —
//  boots permission polling, network calls, maintain mode and the overlay
//  windows, which a test on the founder's own Mac must not do. So
//  `TheTakeoverWiringCompanionManagerInstalls` below repeats those closures
//  verbatim from `CompanionManager.swift:1035-1092`, with the file:line on each
//  one, and nothing else. If that wiring is ever changed there and not here,
//  these tests keep passing while the app breaks — which is why the repro file
//  next door pins the mechanism separately, and why `Test6EscapeHatchTests`
//  pins the controller half.
//

import AppKit
import Foundation
import Testing
@testable import Iris

// MARK: - The guide, served without a network

/// Answers `GET /api/iris/guides/kneecap` with the guide Test 9 was running:
/// the kneecap (OpenCut mobile port) Mac + Android branch, cut down to the one
/// step the reader was parked on when they went for the red light —
/// `install-deps`, `bun install`.
///
/// Its own protocol class rather than `StubbedGuideURLProtocol` from
/// `GuideSessionTests` so this file compiles and runs on its own: the harness
/// builds test files one command at a time, and a guard that only works when
/// another file happens to be in the same invocation is a guard that will go
/// missing the first time somebody runs this one alone.
final class Bug1EndToEndKneecapGuideURLProtocol: URLProtocol {
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
    /// confirm rule, so the step runs on the reader's grant OR without it —
    /// `GuideAutopilotRiskAssessment.assess` reads the process-wide
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
          "target": "android",
          "label": "Mac + Android",
          "shell": "terminal",
          "setupSteps": [],
          "steps": [
            {"id": "install-deps", "kind": "terminal", "title": "Install dependencies",
             "body": "", "command": "bun install"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

// MARK: - The two things that are not real, and nothing else

/// A shell driver that executes NOTHING and holds the step open until the run
/// is released or torn down.
///
/// Holding rather than returning is the point: the reader in both field reports
/// pressed the red light with a step IN FLIGHT, so this is the state the window
/// has to be in for the click to be the click they made. It also means the
/// terminal cannot race ahead, finish the guide and fold itself away before the
/// test has aimed at anything.
///
/// It ends as exit 127 — `bun install` against process 51270's stale PATH, the
/// Test 9 failure — so a test that wants the surfaced "Your turn" row gets
/// there through the runner's real failure path rather than through a state
/// invented for it.
///
/// The wait is polled rather than parked on a continuation so that `endSession`
/// and `cancelTheRunningCommand` — both of which the real escape hatch reaches
/// — release it from anywhere, and so that a test that forgets to tear down
/// still ends: `longestItWillEverHold` is a backstop, never the normal path.
@MainActor
final class ShellThatHoldsTheStepOpenWithoutRunningAnything: GuideAutopilotShellSessionDriving {
    var onOutputLine: ((String) -> Void)?
    var currentWorkingDirectory = NSHomeDirectory()
    var resolvedSearchPath: String? = "/usr/bin:/bin"

    private(set) var commandsItWasAskedToRun: [String] = []
    private var theRunWasReleased = false

    /// Long enough that no takeover animation can outlast it, short enough that
    /// a mistake costs the suite seconds rather than minutes.
    private static let longestItWillEverHold: TimeInterval = 20

    func start() async -> Bool { true }

    func run(
        _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        commandsItWasAskedToRun.append(command.text)
        theRunWasReleased = false
        onOutputLine?("zsh: command not found: bun")
        let startedAt = Date()
        while !theRunWasReleased,
              Date().timeIntervalSince(startedAt) < Self.longestItWillEverHold {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .failed(exitStatus: 127, workingDirectory: currentWorkingDirectory)
    }

    func cancelTheRunningCommand() async { theRunWasReleased = true }
    func endSession() async { theRunWasReleased = true }
    func tailForTheModel() -> String { "zsh: command not found: bun" }
}

/// The model transport, faked at the only place a guide install reaches one.
/// Returning nil is what a fix ladder with nothing to propose does, so the
/// drive loop takes its real "surface it to the reader" path rather than a
/// path invented for the test.
final class FixProposerThatNeverReachesAModel: GuideAutopilotFixProposing {
    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? { nil }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? { nil }
}

// MARK: - CompanionManager's wiring, transcribed

/// The guide session and the takeover controller, connected exactly the way
/// `CompanionManager` connects them.
///
/// Every closure below is copied from `CompanionManager.swift` with its line
/// number, because that file's real objects are unreachable from a test (see
/// this file's header). Nothing else about a `CompanionManager` is recreated:
/// the two controllers ARE the app's, and this holder is only the cable
/// between them.
@MainActor
final class TheTakeoverWiringCompanionManagerInstalls {
    let guideSessionController: GuideSessionController
    let takeoverController = GuideAutopilotTakeoverController()
    let shell = ShellThatHoldsTheStepOpenWithoutRunningAnything()

    init() throws {
        let stubbedConfiguration = URLSessionConfiguration.ephemeral
        stubbedConfiguration.protocolClasses = [Bug1EndToEndKneecapGuideURLProtocol.self]
        let shellThatRunsNothing = shell
        guideSessionController = GuideSessionController(
            guideService: GuideService(
                apiBase: GuideService.defaultAPIBase,
                urlSession: URLSession(configuration: stubbedConfiguration),
                // An isolated suite so a test never reads or writes the
                // founder's own saved place in a guide.
                userDefaults: try #require(
                    UserDefaults(suiteName: "iris.bug1.e2e.\(UUID().uuidString)")
                )
            ),
            // The factory `CompanionManager.swift:164-203` installs, with the
            // pty shell and the model-backed fix proposer swapped for the two
            // fakes above and everything else — the runner, its pacing, its
            // state machine — left real.
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shellThatRunsNothing,
                    longRunningSession: shellThatRunsNothing,
                    fixProposer: FixProposerThatNeverReachesAModel(),
                    guideContext: context
                )
            }
        )

        // The reader's one-time "Let Iris take control of your Mac?" grant,
        // over an isolated suite for the same reason the guide service gets
        // one. This is the grant `startAutopilot` consults; the risk gate
        // consults `AutopilotAutonomyGrant.shared` separately and is left
        // alone — see the guide JSON's note on `bun install`.
        guideSessionController.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug1.e2e.grant.\(UUID().uuidString)")
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
        // CompanionManager.swift:1053-1057
        guideSessionController.onAutopilotResumedFromGate = { [weak self] in
            self?.takeoverController.returnToCenter()
        }
    }

    /// CompanionManager.swift:1080-1092, verbatim — including the escape-hatch
    /// closure, which is the line this whole file exists to exercise.
    private func presentAutopilotTakeover() {
        guard let runner = guideSessionController.autopilotRunner else { return }
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
            }
        )
    }

    /// Opens the guide and presses "Let Iris run it", which is the only entry
    /// point that begins execution.
    func theReaderOpensTheGuideAndLetsIrisRunIt() async {
        await guideSessionController.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android", stepIndexFromDeepLink: nil
        )
        guideSessionController.startAutopilot()
    }

    /// Leaves nothing running behind a finished test: the held step is
    /// released through the same `endSession` the real teardown uses, and any
    /// window still up is folded away.
    func tearDown() {
        guideSessionController.stopAutopilot()
        takeoverController.dismiss(afterHold: false)
    }
}

// MARK: - The tests

@MainActor
@Suite(.serialized) struct Bug1TakeoverCloseClickEndToEndTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel

    /// The 24pt title strip the red light and the Help pill live in.
    /// `heightOfTheTitleStrip` is private to the panel, so it is spelled out
    /// here the way `Test8TakeoverControlClickTests` and the repro spell it out.
    private static let heightOfTheTitleStrip: CGFloat = 24

    /// How long the entry morph plus SwiftUI's preference plumbing need before
    /// the reported control frames describe where the buttons actually are.
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    // MARK: Driving the real window

    /// Polls a main-actor condition instead of sleeping a fixed amount: the
    /// takeover animates on its own clock, so a fixed sleep is a coin flip on a
    /// loaded machine.
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

    private static func letTheRunLoopTurn(forSeconds seconds: Double) async {
        _ = await pump(within: seconds) { false }
    }

    /// One click, delivered the way a hardware click is: a windowed `NSEvent`
    /// carrying the terminal panel's own `windowNumber`, handed to
    /// `NSApplication.shared.sendEvent(_:)` rather than to the panel directly.
    ///
    /// Through NSApp on purpose. The repro next door calls `panel.sendEvent`,
    /// which is one hop short of what really happens: AppKit pulls the event
    /// off the queue, hands it to the application, and the application routes
    /// it to `event.window`. Going through that routing is the difference
    /// between "the panel's dispatch works" and "a click on this Mac works".
    private static func deliverAClickThroughTheApplication(
        to terminal: Panel, onControlFrame controlFrame: CGRect, driftInPoints: CGFloat
    ) {
        // The reported frames are content-view coordinates (top-left origin);
        // an event's `locationInWindow` is window coordinates (bottom-left
        // origin), so the y flips through the window height.
        let downInWindow = CGPoint(
            x: controlFrame.midX, y: terminal.frame.height - controlFrame.midY
        )
        let upInWindow = CGPoint(
            x: controlFrame.midX + driftInPoints,
            y: terminal.frame.height - (controlFrame.midY + driftInPoints)
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

    /// A real finger's drifting click, then a dead-centre one. Both, so that
    /// "the press drifted" — the Test-8 bug commit 9c12317 already fixed —
    /// cannot be mistaken for this one.
    private static func theReaderClicks(
        _ controlFrame: CGRect, on terminal: Panel
    ) async {
        deliverAClickThroughTheApplication(
            to: terminal, onControlFrame: controlFrame, driftInPoints: 4
        )
        await letTheRunLoopTurn(forSeconds: 1)
        deliverAClickThroughTheApplication(
            to: terminal, onControlFrame: controlFrame, driftInPoints: 0
        )
        await letTheRunLoopTurn(forSeconds: 0.5)
    }

    // MARK: Finding the window and its two controls

    private static func terminalPanelRaised(
        after windowsBefore: Set<ObjectIdentifier>
    ) async throws -> Panel {
        _ = await pump(within: 5) {
            NSApplication.shared.windows
                .contains { $0 is Panel && !windowsBefore.contains(ObjectIdentifier($0)) }
        }
        return try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !windowsBefore.contains(ObjectIdentifier($0)) },
            """
            "Let Iris run it" did not raise a takeover terminal at all, so there is no window \
            for the reader to be stuck under and nothing for this test to click
            """
        )
    }

    /// Waits out the entry morph and the preference plumbing, so the reported
    /// frames describe a laid-out window rather than one still growing out of
    /// the eye.
    private static func waitForTheTakeoverToFinishOpening(_ terminal: Panel) async throws {
        try #require(
            await pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        try #require(
            await pump {
                terminal.interactiveControlFrames
                    .filter { $0.minY < heightOfTheTitleStrip }.count >= 2
            },
            """
            the title strip's two controls (the red escape hatch and the Help pill) never \
            reported their frames to the panel
            """
        )
    }

    /// The title strip's two controls: the red escape hatch is the leftmost
    /// (first in the strip's `HStack`, 22pt hit target), the Help pill the
    /// rightmost (hard against the right edge). Left/right tells them apart
    /// without reaching into the view's private geometry.
    private static func titleStripControls(
        reportedBy terminal: Panel
    ) throws -> (redLight: CGRect, helpPill: CGRect) {
        let inTheTitleStrip = terminal.interactiveControlFrames
            .filter { $0.minY < heightOfTheTitleStrip }
            .sorted { $0.minX < $1.minX }
        try #require(
            inTheTitleStrip.count >= 2,
            """
            only \(inTheTitleStrip.count) control(s) reported a frame in the 24pt title strip — \
            the red light AND the Help pill should both be there
            """
        )
        let redLight = try #require(inTheTitleStrip.first)
        let helpPill = try #require(inTheTitleStrip.last)
        #expect(
            redLight.minX < terminal.frame.width / 2 && helpPill.minX > terminal.frame.width / 2,
            """
            the title strip's controls came back at \(redLight) and \(helpPill) on a \
            \(terminal.frame.width)pt-wide card, which is not the left/right pair the red light \
            and the Help pill are
            """
        )
        return (redLight, helpPill)
    }

    /// The takeover as the reader sees it: on screen, grown, with the install
    /// running inside it. Every test starts here because that is where the
    /// field reports start.
    private static func aTakeoverTheReaderIsStuckUnder() async throws
        -> (TheTakeoverWiringCompanionManagerInstalls, Panel) {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let iris = try TheTakeoverWiringCompanionManagerInstalls()
        await iris.theReaderOpensTheGuideAndLetsIrisRunIt()

        let terminal = try await terminalPanelRaised(after: windowsBefore)
        try await waitForTheTakeoverToFinishOpening(terminal)
        try #require(
            terminal.isVisible,
            "the takeover terminal is not on screen, so 'is it gone afterwards' means nothing"
        )
        try #require(
            await pump(within: 5) { iris.shell.commandsItWasAskedToRun.isEmpty == false },
            """
            the drive loop never reached the step's command, so the terminal is not in the state \
            the reader pressed the red light in
            """
        )
        return (iris, terminal)
    }

    // MARK: THE GUARD — the red light

    /// "Terminal Close (red light) … do nothing", asked as the reader asks it.
    ///
    /// One click on the red dot, delivered through the application, and then
    /// the only question that matters: is the window still there? Everything
    /// behind the answer is the shipping path — the tooltip overlay the press
    /// has to get past, SwiftUI's Button, `abortOrCloseAutopilotFromTheEscapeHatch`,
    /// `stopAutopilot`, `onAutopilotDidStop`, and the takeover's own collapse.
    @Test func theRedLightActuallyClosesTheTakeoverTheReaderIsStuckUnder() async throws {
        let (iris, terminal) = try await Self.aTakeoverTheReaderIsStuckUnder()
        defer { iris.tearDown() }
        let (redLight, _) = try Self.titleStripControls(reportedBy: terminal)

        let originBeforeTheClick = terminal.frame.origin
        await Self.theReaderClicks(redLight, on: terminal)

        #expect(
            await Self.pump(within: 8) {
                iris.takeoverController.isPresented == false && terminal.isVisible == false
            },
            """
            the reader clicked the red traffic light at \(redLight) — twice, once with a real \
            finger's 4pt drift and once dead centre — and the takeover terminal is STILL ON \
            SCREEN (presented=\(iris.takeoverController.isPresented), \
            visible=\(terminal.isVisible)). That is the whole report: "Terminal Close (red \
            light) … do nothing". The window did not move either (it is at \
            \(terminal.frame.origin), started at \(originBeforeTheClick)), so the press reached \
            the panel and was correctly read as landing on a control — it was swallowed \
            somewhere between the panel and SwiftUI's Button, which is where the \
            `.nativeTooltip(…)` overlay sits
            """
        )
        #expect(
            iris.guideSessionController.autopilotIsRunning == false,
            """
            the window went away but the install did not stop — the red light means "stop what \
            Iris is doing", and a run left going behind a closed window is worse than a dead \
            button
            """
        )
        // Closing costs the reader their automation, never their place.
        #expect(
            iris.guideSessionController.loadState == .guideIsOpen,
            "closing the takeover must leave the guide open where the reader left it"
        )
    }

    // MARK: THE GUARD — Help

    /// "…and Help do nothing", same window, same run.
    ///
    /// Help is the reader's only door onto an answer while a takeover covers
    /// the screen: it posts `.clickySummonAskBar`, which is what the eye's
    /// overlay subscribes to (`OverlayWindow.swift:578-581`) to open the ask
    /// bar with the step and the real terminal output already attached. That
    /// last hop needs an eye visible on a screen, which a headless test has no
    /// way to give it, so the doorbell IS the assertion — and the second
    /// expectation is the other half of the reader's experience: asking for
    /// help must not take the install away.
    @Test func theHelpPillActuallyRingsTheAskBarAndLeavesTheInstallAlone() async throws {
        let (iris, terminal) = try await Self.aTakeoverTheReaderIsStuckUnder()
        defer { iris.tearDown() }
        let (_, helpPill) = try Self.titleStripControls(reportedBy: terminal)

        let askBarSummons = TheAskBarDoorbell()
        let observer = NotificationCenter.default.addObserver(
            forName: .clickySummonAskBar, object: nil, queue: .main
        ) { _ in askBarSummons.wasRung = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        await Self.theReaderClicks(helpPill, on: terminal)

        #expect(
            await Self.pump(within: 5) { askBarSummons.wasRung },
            """
            the reader clicked Help at \(helpPill) — twice — and nothing was posted, so the ask \
            bar never opens: "Help do nothing". A reader stuck under a takeover has no other \
            way to ask, because the eye that would open the bar is behind the window they are \
            stuck under
            """
        )
        #expect(
            iris.takeoverController.isPresented && terminal.isVisible,
            "asking for help must leave the terminal up — Help is not a second close button"
        )
        #expect(
            iris.guideSessionController.autopilotIsRunning,
            "asking for help must not stop the install"
        )
    }

    // MARK: THE GUARD — the same window, the button that always worked

    /// The control, in the same file rather than in another one: if a change to
    /// the click path ever breaks EVERY button in this window, the two tests
    /// above go red and say "the red light does nothing", which is the wrong
    /// story and the wrong fix. So the same delivery is aimed at "Try again" —
    /// the button commit 9c12317 made work, which carries no tooltip and is the
    /// button the Test-9 reader really did tap twice.
    ///
    /// It is driven to the surfaced row the way the field got there: the held
    /// step is released as exit 127, the fix ladder has nothing to propose, and
    /// the runner surfaces it to the reader exactly as `bun install` did at
    /// 06:59:45Z under the stale PATH.
    @Test func theSameClickStillFiresTheButtonThatNeverBroke() async throws {
        let (iris, terminal) = try await Self.aTakeoverTheReaderIsStuckUnder()
        defer { iris.tearDown() }

        // Release the held step so the runner takes its real failure path and
        // draws the "Your turn" row the reader taps Try again on.
        await iris.shell.cancelTheRunningCommand()
        try #require(
            await Self.pump(within: 20) {
                terminal.interactiveControlFrames
                    .filter { $0.minY >= Self.heightOfTheTitleStrip }.count >= 2
            },
            """
            the surfaced "Your turn" row never appeared, so there is no "Try again" to use as \
            this file's control
            """
        )

        // "Try again" is the rightmost control BELOW the title strip (the row
        // is "Continue past it" on the left, the primary pill on the right) —
        // the same identification Test8 and the repro make.
        let tryAgain = try #require(
            terminal.interactiveControlFrames
                .filter { $0.minY >= Self.heightOfTheTitleStrip }
                .sorted { $0.minX < $1.minX }
                .last
        )
        let commandsBeforeTheClick = iris.shell.commandsItWasAskedToRun.count

        await Self.theReaderClicks(tryAgain, on: terminal)

        #expect(
            await Self.pump(within: 8) {
                iris.shell.commandsItWasAskedToRun.count > commandsBeforeTheClick
            },
            """
            "Try again" at \(tryAgain) did not re-run the step through the same click delivery \
            that the red light and Help are tested with. This test failing ALONE means the \
            click path itself is broken and the two tests above prove nothing about the \
            tooltip; this test failing ALONGSIDE them is a different bug from the one they \
            guard
            """
        )
    }
}

/// Whether the ask bar's doorbell rang. A reference box because the observer
/// closure that sets it escapes into `NotificationCenter`.
final class TheAskBarDoorbell: @unchecked Sendable {
    var wasRung = false
}
