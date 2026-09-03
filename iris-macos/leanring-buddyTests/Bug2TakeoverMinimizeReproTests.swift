//
//  Bug2TakeoverMinimizeReproTests.swift
//  leanring-buddyTests
//
//  BUG 2 — "No minimize on the takeover terminal (yellow light)."
//
//  THE FIELD REPORT (cofounder's Mac, Iris 0.9.6 build 22 = Test 9, and again
//  on 0.9.7 build 23 = Test 10). The takeover terminal — the "iris — install"
//  window with the three traffic lights — cannot be folded out of the way. The
//  red light ENDS the run (`onEscapeHatch` → `abortOrCloseAutopilotFromTheEscape
//  Hatch` → `stopAutopilot`), so a reader who only wants their screen back has
//  to kill the install they have been waiting on. The yellow light, which is
//  where every Mac user goes for exactly that, does nothing at all.
//
//  WHY: `GuideAutopilotTerminalView.titleBar` draws the red light as a real
//  `Button` (`escapeHatchTrafficLight`, with `.reportsFrameAsATakeoverControl()`
//  so the panel delivers a press to it) and then draws yellow and green as bare
//  `Circle().fill(…)` — paint. There is no `onMinimize` anywhere in the chain
//  (`GuideAutopilotTerminalView` → `GuideAutopilotTakeoverView` →
//  `GuideAutopilotTakeoverController.present(…)` → `CompanionManager`), and no
//  code path folds the takeover away while leaving the run alive: the only
//  things that take the window down are the escape hatch, `stopAutopilot()`,
//  and guide completion — all of which end the run.
//
//  WHAT THE EVIDENCE DOES AND DOES NOT SAY. Both runtime logs disclaim
//  click-level proof in the same words — 0.9.6: "The runtime does not capture
//  terminal minimize/close/resize hit-testing … Runtime can show a relaunch was
//  required and that no edit run started, but it cannot prove which visible
//  control accepted or rejected a click", and both add "Terminal
//  close/minimize/resize limitations are the same UI regression family
//  documented in Tests 6, 7, and 8." So the logs cannot be asserted against
//  directly. What they DO give, to the second, is the run the reader was
//  staring at when they wanted the window gone, and this file replays that run
//  into the real window rather than inventing a scenario:
//
//    Test 9, process 51799, the kneecap "Mac + iPhone" guide (the live guide
//    JSON: 15 steps, `install-deps` … `verify`). 07:04:03Z `install-deps`
//    succeeded, 07:04:09Z `build-editor` succeeded, then three manual gates in
//    a row with the takeover PARKED at each — 07:04:09.861Z "title=Install
//    Xcode", 07:04:40.567Z "title=Sign it with your Apple ID", and at
//    07:06:08.724Z "title=Plug in your iPhone and press play", where it stayed.
//    The reader then spent THIRTEEN MINUTES in the eye's ask bar (the retained
//    chat rows run to 07:18:10Z, and the next durable line is 07:19:45Z) with
//    that parked terminal sitting on their screen over the Xcode window they
//    were being asked to work in. Nothing in the run needed to stop; the window
//    just needed to get out of the way. That is the whole bug.
//
//  HOW THESE TESTS AIM. The yellow light is found by its PIXELS — the amber dot
//  the reader actually points at, measured off the real window's backing store —
//  not by a hard-coded offset, so the tests keep aiming at the right spot when
//  the fix changes the light's hit target (the red light's is 22pt around an
//  11pt dot). Clicks are windowed `NSEvent`s carrying the panel's own
//  `windowNumber`, the `event.window != nil` branch a hardware click takes, the
//  same delivery `Test8TakeoverControlClickTests` and `Bug1TakeoverCloseClick
//  ReproTests` use.
//
//  These tests must FAIL on the unfixed code, and they fail on the bug itself:
//  nothing reports a control frame where the yellow dot is drawn, and a click
//  there leaves the takeover exactly where it was.
//
//  A NOTE FOR THE FIX. These tests raise the takeover the way every existing
//  caller and test does — `present(runner:onApproveRiskyCommand:…:onEscapeHatch:)`
//  — and then assert what the READER sees: the yellow light folds the window
//  away and the run carries on. They deliberately do not name an `onMinimize`
//  parameter, because a repro cannot call an API that does not exist yet. If the
//  fix threads a minimize closure through `present(…)` with a no-op default, a
//  takeover raised WITHOUT that closure would draw a live-looking yellow light
//  that does nothing — the same "the button doesn't work" class this window has
//  now earned three times (Test 8's Try again, Bug 1's red light and Help). So
//  the fold-away itself belongs where the window does, in
//  `GuideAutopilotTakeoverController`, with the caller's closure carrying only
//  the side effects it alone knows about (`setAutopilotIsShownAsTakeover(false)`
//  for the guide, `onDemandEditTakeoverIsUp = false` for an edit).
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

/// The kneecap iOS install as Test 9 left it: parked on step 12 `run` — "Plug
/// in your iPhone and press play" — with steps 6 through 11 already in the
/// transcript. Titles, bodies and commands are the live guide's own
/// (`branches[macos/ios].steps`), and the exit timings are the log's
/// (`install-deps` 07:03:51→07:04:03, `build-editor` 07:04:03→07:04:09,
/// `sync-ios` 07:04:35→07:04:37, `open-project` 07:04:37→07:04:40).
///
/// A presenter rather than a real `GuideAutopilotRunner` for the reason
/// `Bug1TakeoverCloseClickReproTests` gives: the terminal binds to exactly the
/// three published properties of `AutopilotTerminalPresenting` and nothing
/// else, while driving a real runner this far would need a real pty login
/// shell, a real clone and a real Xcode — none of which this bug is about. The
/// takeover, the panel, the terminal view, the traffic lights and the events
/// are all real. Its `state`/`transcript` are also the proof that minimize left
/// the run ALONE: nothing in a fold-away may touch them.
@MainActor
private final class KneecapParkedOnPlugInYourIPhone: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 12)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Install the workspace", stepNumber: 6, totalSteps: 15),
        .commandFromTheGuide(text: "bun install"),
        .output(line: "bun install v1.4.0"),
        .output(line: "+ 1284 packages installed"),
        .exitStatus(code: 0, duration: 12.4),
        .stepHeading(stepTitle: "Build the editor", stepNumber: 7, totalSteps: 15),
        .commandFromTheGuide(text: "cd apps/mobile\nbun run build"),
        .output(line: "$ vite build"),
        .output(line: "✓ built in 4.81s"),
        .exitStatus(code: 0, duration: 5.9),
        .stepHeading(stepTitle: "Install Xcode", stepNumber: 8, totalSteps: 15),
        .explanation(text: "Free, and large — start it now. Open it once and accept the licence."),
        .stepHeading(
            stepTitle: "Copy the editor into the iPhone app", stepNumber: 9, totalSteps: 15
        ),
        .commandFromTheGuide(text: "bunx cap sync ios"),
        .output(line: "✔ Copying web assets from www to ios/App/App/public"),
        .exitStatus(code: 0, duration: 1.2),
        .stepHeading(stepTitle: "Open the iPhone project", stepNumber: 10, totalSteps: 15),
        .commandFromTheGuide(text: "bunx cap open ios"),
        .exitStatus(code: 0, duration: 3.5),
        .stepHeading(stepTitle: "Sign it with your Apple ID", stepNumber: 11, totalSteps: 15),
        .explanation(
            text: "Pick App, then Signing & Capabilities, then add your Apple ID as the Team."
        ),
        .stepHeading(
            stepTitle: "Plug in your iPhone and press play", stepNumber: 12, totalSteps: 15
        ),
        .explanation(
            text: "Pick your iPhone in the device menu, then the play button. "
                + "First build is slow."
        )
    ]
    @Published var isExecutingACommand: Bool = false
}

/// Whether the RED light's action ran. A reference box because the closure that
/// sets it escapes into `present(…)` and outlives the call that made it — the
/// pattern `Bug1TakeoverCloseClickReproTests.AskBarSummons` uses.
///
/// It is a control, not decoration: a "minimize" that is quietly wired to the
/// escape hatch would fold the window away AND kill the install, which is the
/// bug wearing a different hat.
private final class EscapeHatchFirings: @unchecked Sendable {
    var theRedLightFired = false
}

@MainActor
@Suite(.serialized) struct Bug2TakeoverMinimizeReproTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel

    /// How long the entry morph plus SwiftUI's preference plumbing need before
    /// the reported control frames describe where the lights actually are — the
    /// value Test8 and the Bug 1 repro both settle on.
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    /// A park or a return-to-centre is a 0.5s window animation; this is the
    /// beat that lets one finish before the next begins, the way the field's
    /// gates were seconds apart.
    private static let gateSettleNanoseconds: UInt64 = 700_000_000

    /// The 24pt title strip the traffic lights live in.
    /// `heightOfTheTitleStrip` is private to the panel, so it is spelled out
    /// here the way Test8 and the Bug 1 repro spell it out.
    private static let heightOfTheTitleStrip: CGFloat = 24

    private struct LiveTakeover {
        let controller: GuideAutopilotTakeoverController
        let terminal: Panel
        /// Held for the length of the test: the terminal stops publishing the
        /// state it draws from the moment the runner goes away.
        let runner: KneecapParkedOnPlugInYourIPhone
        let escapeHatch: EscapeHatchFirings
    }

    // MARK: - Driving the real window

    /// Polls a main-actor condition instead of sleeping a fixed amount: the
    /// takeover animates on its own clock, so a fixed sleep is a coin flip on a
    /// loaded machine (Test7's lesson, kept by Test8 and the Bug 1 repro).
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

    /// Lets the main run loop turn without asserting anything — the turn SwiftUI
    /// needs to run a button's action, and the stand-in for the reader's own
    /// pauses in the field.
    private static func letTheRunLoopTurn(forSeconds seconds: Double) async {
        _ = await pump(within: seconds) { false }
    }

    /// One click at a point in the terminal's own content coordinates,
    /// delivered the way a HARDWARE click arrives: windowed `NSEvent`s carrying
    /// the panel's `windowNumber`, so `event.window` resolves to the panel and
    /// its `sendEvent` takes the `event.window != nil` branch a real click
    /// takes rather than the `windowNumber: 0` seam the drag tests use.
    ///
    /// `driftInPoints` is how far the pointer travels between the finger going
    /// down and coming up; 4pt is a real finger's drift, past the panel's 3pt
    /// click slop.
    ///
    /// THIS CALL TAKES 30 SECONDS ON THE UNFIXED CODE, and that is the bug's own
    /// fingerprint rather than a flaw in the test. A press that lands on a
    /// REPORTED control is handed straight to SwiftUI and returns at once; a
    /// press that lands on anything else is held by
    /// `GuideAutopilotTakeoverTerminalPanel`'s tracking loop, which pulls the
    /// rest of the gesture out of the event queue and waits `longest
    /// AGestureIsWatched` (30s) for a release that a synthesized click never
    /// posts, then gives up and replays the press as a click. Today the yellow
    /// light is one of those "anything else" presses. Measured at HEAD: 30.03s.
    ///
    /// The release is NOT pre-posted to short-circuit that wait, even though
    /// `Test8TakeoverControlClickTests.postAGesture` does exactly that:
    /// `NSApp.postEvent` silently terminates this test process (measured — the
    /// runner exits 0 mid-test with no summary line, which is the "Test6/7/8
    /// takeover suites exit the runner early" flakiness the harness README
    /// records). `sendEvent` alone is both safe and closer to the hardware path.
    private static func deliverAClick(
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
        if let down = windowedEvent(.leftMouseDown, at: downInWindow) { terminal.sendEvent(down) }
        if let up = windowedEvent(.leftMouseUp, at: upInWindow) { terminal.sendEvent(up) }
    }

    /// Where the YELLOW traffic light is drawn, in the terminal's content
    /// coordinates: the centroid of the amber pixels in the title strip of the
    /// real window's backing store.
    ///
    /// Measured rather than computed because the fix is expected to change this
    /// light's geometry — the red light is an 11pt dot inside a 22pt hit target
    /// for the reason its own comment gives ("stopping a runaway install … is
    /// not a precision exercise"), and a minimize deserves the same. The DOT is
    /// what the reader aims at either way, so the dot is what these tests aim
    /// at. The bands are wide enough that a colour-space shift between the
    /// window's backing store and `deviceRGB` cannot move the answer, and they
    /// exclude the other two lights outright: the red light's green channel is
    /// 0.373 (below 0.55) and the green light's red channel is 0.157 (below
    /// 0.70).
    private static func centreOfTheYellowTrafficLight(in terminal: Panel) throws -> CGPoint {
        let contentView = try #require(
            terminal.contentView, "the takeover terminal has no content view to measure"
        )
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()

        // The left end of the 24pt title strip, which holds all three lights
        // (10pt inset, then a 22pt hit target and two 11pt dots at 7pt spacing)
        // and nothing else. Kept clear of the centred "iris — install" title.
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
        var everyColourInTheStrip: Set<String> = []
        for x in 0..<backingStore.pixelsWide {
            for y in 0..<backingStore.pixelsHigh {
                guard let sample = backingStore.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let red = sample.redComponent
                let green = sample.greenComponent
                let blue = sample.blueComponent
                everyColourInTheStrip.insert(
                    "\(Int(red * 255)),\(Int(green * 255)),\(Int(blue * 255))"
                )
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
            only \(Int(amberPixelCount)) amber pixel(s) in the title strip, so the yellow traffic \
            light was not found and there is nothing to aim at. Colours drawn there: \
            \(everyColourInTheStrip.sorted().prefix(8).joined(separator: " | ")). This is a \
            measurement failure, not the bug.
            """
        )
        return CGPoint(
            x: leftEndOfTheTitleStrip.minX + CGFloat(amberPixelsAcross / amberPixelCount)
                / pixelsPerPointAcross,
            y: leftEndOfTheTitleStrip.minY + CGFloat(amberPixelsDown / amberPixelCount)
                / pixelsPerPointDown
        )
    }

    /// Finds the terminal panel a controller just raised.
    private static func terminalPanelRaised(
        after windowsBefore: Set<ObjectIdentifier>
    ) throws -> Panel {
        try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !windowsBefore.contains(ObjectIdentifier($0)) },
            "the takeover must raise its own terminal panel subclass"
        )
    }

    /// Test 9's window, rebuilt: the takeover raised over the kneecap install,
    /// then the three manual gates the log records in the order and shape it
    /// records them — park "Install Xcode", the reader continues, park "Sign it
    /// with your Apple ID", the reader continues, park "Plug in your iPhone and
    /// press play" — and left parked there, which is where the reader spent the
    /// next thirteen minutes wanting the window gone.
    ///
    /// Parked matters: `parkForManualStep` shrinks the card to 400×340 in the
    /// corner and lifts the dim, so the lights are laid out where they really
    /// were, not where a centred 760pt window would put them.
    private static func raiseTheTest9TakeoverAndWalkItToTheLastGate() async throws -> LiveTakeover {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = KneecapParkedOnPlugInYourIPhone()
        let escapeHatch = EscapeHatchFirings()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {},
            onEscapeHatch: { escapeHatch.theRedLightFired = true }
        )
        let terminal = try terminalPanelRaised(after: windowsBefore)

        try #require(
            await pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)

        // 07:04:09.861Z — step[8] install-xcode → MANUAL branch.
        controller.parkForManualStep(
            title: "Install Xcode",
            instruction: "Free, and large — start it now. Open it once and accept the licence."
        )
        try await Task.sleep(nanoseconds: gateSettleNanoseconds)
        // 07:04:35Z — "gate: reader finished step 8 — advancing and resuming autopilot".
        controller.returnToCenter()
        try await Task.sleep(nanoseconds: gateSettleNanoseconds)
        // 07:04:40.567Z — step[11] signing → MANUAL branch.
        controller.parkForManualStep(
            title: "Sign it with your Apple ID",
            instruction: "Pick App, then Signing & Capabilities, then add your Apple ID as the Team."
        )
        try await Task.sleep(nanoseconds: gateSettleNanoseconds)
        // 07:06:08.691Z — "gate: reader finished step 11".
        controller.returnToCenter()
        try await Task.sleep(nanoseconds: gateSettleNanoseconds)
        // 07:06:08.724Z — step[12] run → MANUAL branch, and there it stayed.
        controller.parkForManualStep(
            title: "Plug in your iPhone and press play",
            instruction: "Pick your iPhone in the device menu, then the play button. "
                + "First build is slow."
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)

        try #require(
            await pump {
                terminal.interactiveControlFrames
                    .contains { $0.minY < heightOfTheTitleStrip }
            },
            """
            no control in the 24pt title strip reported a frame to the panel, so the frame \
            plumbing this test reads is not running at all — a measurement failure, not the bug
            """
        )
        return LiveTakeover(
            controller: controller, terminal: terminal, runner: runner, escapeHatch: escapeHatch
        )
    }

    /// True while the takeover is still covering the reader's screen. Written as
    /// a disjunction so it answers the READER'S question ("is that window still
    /// in my way?") rather than pinning one implementation of folding it away.
    private static func theTakeoverIsStillInTheReadersWay(_ takeover: LiveTakeover) -> Bool {
        takeover.controller.isPresented && takeover.terminal.isVisible
    }

    // MARK: - THE REPRO, half one: the yellow light is not a control at all

    /// The panel can only deliver a press to a control that reported its frame
    /// (`TakeoverControlFramesKey` → `interactiveControlFrames`) — a SwiftUI
    /// `Button` has no AppKit view for `hitTest` to find, which is the whole
    /// reason that plumbing exists. So a light that reports no frame cannot be
    /// clicked no matter how the press is delivered: it is paint, and a press on
    /// it is offered to the window's drag loop instead.
    ///
    /// This asserts the yellow dot the reader aims at lies inside SOME reported
    /// control frame. The red light beside it is the control: same strip, same
    /// window, same plumbing — so a failure here cannot be the plumbing.
    @Test func theYellowTrafficLightIsAControlTheTakeoverPanelKnowsAbout() async throws {
        let takeover = try await Self.raiseTheTest9TakeoverAndWalkItToTheLastGate()
        defer { takeover.controller.dismiss(afterHold: false) }

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: takeover.terminal)
        let reportedControls = takeover.terminal.interactiveControlFrames

        // The control beside it, so a failure below cannot be blamed on the
        // measurement or on the preference never arriving.
        try #require(
            reportedControls.contains { $0.minY < Self.heightOfTheTitleStrip && $0.minX < 40 },
            """
            the RED escape hatch — the control the yellow light sits next to — reported no frame \
            in the title strip either, so the frame plumbing is broken; that is a different bug \
            from this one. Frames: \(reportedControls)
            """
        )

        #expect(
            reportedControls.contains { $0.contains(yellowLight) },
            """
            the yellow traffic light is drawn at \(yellowLight) and NOTHING reported a control \
            frame there — the reported frames are \(reportedControls). It is a bare \
            `Circle().fill(…)`, not a `Button`, and carries no \
            `.reportsFrameAsATakeoverControl()`, so the panel cannot even tell a press on it \
            apart from a press on the title-bar background: "No minimize on the takeover \
            terminal (yellow light)". The reader parked at "Plug in your iPhone and press play" \
            had one working light — the red one, which ENDS the install they were waiting on.
            """
        )
    }

    // MARK: - THE REPRO, half two: clicking it does not fold the window away

    /// The reader's actual gesture, at the moment the field log leaves them:
    /// parked on step 12 with Xcode to work in behind a takeover they cannot
    /// move out of the way, they click the yellow light. The window must fold
    /// away — and the install must still be running when it does, which is the
    /// entire difference between this control and the red one beside it.
    @Test func clickingTheYellowLightFoldsTheTakeoverAwayAndLeavesTheInstallRunning() async throws {
        let takeover = try await Self.raiseTheTest9TakeoverAndWalkItToTheLastGate()
        defer { takeover.controller.dismiss(afterHold: false) }

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: takeover.terminal)
        let stateBeforeTheClick = takeover.runner.state
        let transcriptBeforeTheClick = takeover.runner.transcript
        let whereTheCardWasParked = takeover.terminal.frame.origin

        // One click, with a real finger's 4pt drift between down and up. The
        // card's position is read the instant the click returns, BEFORE the run
        // loop turns: a fold-away is scheduled on the next turn and moves the
        // window itself, so reading it later could not tell a drag from a fold.
        Self.deliverAClick(
            to: takeover.terminal, atContentPoint: yellowLight, driftInPoints: 4
        )
        let whereTheCardWasWhenTheClickReturned = takeover.terminal.frame.origin
        await Self.letTheRunLoopTurn(forSeconds: 0.5)

        // It did not become a window drag on the way (the Test-8 failure mode),
        // so a fold-away that does not happen cannot be explained by the press
        // having been eaten as a move.
        #expect(
            whereTheCardWasWhenTheClickReturned == whereTheCardWasParked,
            """
            the press on the yellow light at \(yellowLight) slid the parked card from \
            \(whereTheCardWasParked) to \(whereTheCardWasWhenTheClickReturned) instead of doing \
            anything — "it is just moving the terminal around" (Test 8), here because the light \
            is not a control the panel excludes from its drag loop
            """
        )

        #expect(
            await Self.pump(within: 6) { !Self.theTakeoverIsStillInTheReadersWay(takeover) },
            """
            the yellow traffic light at \(yellowLight) was clicked and the takeover is still on \
            screen (presented=\(takeover.controller.isPresented), \
            visible=\(takeover.terminal.isVisible), frame=\(takeover.terminal.frame)). There is \
            no minimize: yellow is a bare `Circle().fill(…)` with no action, no `onMinimize` \
            exists anywhere in the chain, and the only things that take this window down — the \
            red escape hatch, `stopAutopilot()`, guide completion — all END the run. The reader \
            parked at "Plug in your iPhone and press play" had to choose between their screen \
            and their install.
            """
        )

        #expect(
            !takeover.escapeHatch.theRedLightFired,
            """
            the yellow light ran the RED light's action — folding the window away by ENDING the \
            install (`onEscapeHatch` → `abortOrCloseAutopilotFromTheEscapeHatch` → \
            `stopAutopilot`). Minimize must be a pure UI fold-away: the run keeps going, and \
            that is the only reason a reader would reach for yellow instead of red.
            """
        )
        #expect(
            takeover.runner.state == stateBeforeTheClick,
            """
            minimize changed the run's state from \(stateBeforeTheClick) to \
            \(takeover.runner.state). Folding the window away must not touch the runner at all
            """
        )
        #expect(
            takeover.runner.transcript == transcriptBeforeTheClick,
            """
            minimize wrote \(takeover.runner.transcript.count - transcriptBeforeTheClick.count) \
            entrie(s) into the transcript. Folding the window away must not touch the runner
            """
        )
    }

    // MARK: - THE REPRO, half three: and the reader can get it back

    /// Minimize is only worth having if the window comes back. `present(…)`
    /// guards on `terminalPanel == nil`, so a fold-away that leaves the panel up
    /// — or a teardown that does not finish — silently refuses the next
    /// takeover, and the reader would be left with a run they can no longer see
    /// (the next park, the next surfaced step, the next risky-command gate).
    @Test func theTakeoverCanBeRaisedAgainAfterTheReaderMinimizesIt() async throws {
        let takeover = try await Self.raiseTheTest9TakeoverAndWalkItToTheLastGate()
        defer { takeover.controller.dismiss(afterHold: false) }

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: takeover.terminal)
        Self.deliverAClick(
            to: takeover.terminal, atContentPoint: yellowLight, driftInPoints: 4
        )
        #expect(
            await Self.pump(within: 6) { !Self.theTakeoverIsStillInTheReadersWay(takeover) },
            """
            the takeover never folded away when the yellow light was clicked, so whether it can \
            be raised again cannot be told apart from it never having gone — see \
            clickingTheYellowLightFoldsTheTakeoverAwayAndLeavesTheInstallRunning
            """
        )

        // Iris needs the window back: the next gate, the next surfaced step.
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        takeover.controller.present(
            runner: takeover.runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        let cameBack = await Self.pump(within: 6) {
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .contains { !windowsBefore.contains(ObjectIdentifier($0)) }
        }
        #expect(
            cameBack,
            """
            after the reader minimized it, Iris could not raise the takeover again — \
            `present(…)` refuses while `terminalPanel` is still set, so the run carries on with \
            no window the reader can watch it in
            """
        )
    }

    // MARK: - The other takeover the same window serves

    /// `present(…)` is generic over the presenter: the SAME terminal, the same
    /// three lights, host an on-demand edit run. Test 10's reader was in that
    /// one — the third WhimprFlow feature edit, 2026-09-02 11:52:51 → 11:55:48
    /// PT, which ended BLOCKED on pnpm's esbuild preflight with the terminal
    /// still up — and the 0.9.7 log files that report under the same heading:
    /// "The terminal close/minimize limitation remains in the terminal UI
    /// regression family documented in Tests 6 through 9."
    ///
    /// Replayed through the REAL `OnDemandEditRunner`, with the calls
    /// `OnDemandEditCoordinator` makes, so a fix that wires minimize only on the
    /// guide path leaves this one failing rather than passing silently.
    @Test func theOnDemandEditTakeoverHasTheSameYellowLightAndItIsAlsoPaint() async throws {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = OnDemandEditRunner()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        defer { controller.dismiss(afterHold: false) }

        runner.beginRun(appName: "whimprflow", kind: .feature)
        runner.note("memory: 3 prior run(s) injected")
        runner.note("runtime evidence: its recent log output")
        runner.note(
            "Added a visible transcription-model selector in Settings, persisted it compatibly, "
                + "and wired macOS and Windows to load the chosen installed Whisper model with "
                + "automatic fallback."
        )
        runner.note(
            "verifying: build=(cd 'ui' && pnpm build) && cargo build --release "
                + "--manifest-path src-tauri/Cargo.toml, tests=none"
        )
        runner.recordVerificationResult(passed: false, over: 1.7)
        runner.note(
            "BLOCKED: pnpm fails its dependency-status preflight before compiling any source "
                + "because esbuild is unapproved in the global pnpm store; run "
                + "`cd ui && pnpm approve-builds --all` and retry verification."
        )
        runner.finishStopped()

        let terminal = try Self.terminalPanelRaised(after: windowsBefore)
        try #require(
            await Self.pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size"
        )
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
        try #require(
            await Self.pump {
                terminal.interactiveControlFrames.contains { $0.minY < Self.heightOfTheTitleStrip }
            },
            "no title-strip control reported a frame — a measurement failure, not the bug"
        )

        let yellowLight = try Self.centreOfTheYellowTrafficLight(in: terminal)
        #expect(
            terminal.interactiveControlFrames.contains { $0.contains(yellowLight) },
            """
            on the on-demand edit takeover the yellow traffic light at \(yellowLight) reports no \
            control frame either (frames: \(terminal.interactiveControlFrames)) — the reader \
            left looking at a run that ended BLOCKED still cannot fold the window away without \
            the red light, and `present(…)` is generic, so wiring minimize on the guide path \
            alone would leave this surface with a light that looks clickable and is not.
            """
        )
    }
}
