//
//  Test8TakeoverControlClickTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS (Test 8 field report, Iris 0.9.4 build 20), one window,
//  three ways of saying the same thing:
//
//    - "Hit try again, the button doesn't work though. Continue past it button
//      not working either, it is just moving the terminal around."
//    - "Hitting rebuild whimprflow for me … seems to not be working."
//    - "There needs to be a quit install button or close the Iris terminal
//      needs to work, or else if there is an error you need to restart Iris."
//
//  WHAT IS ACTUALLY WRONG — the same tracking loop `Test6`/`Test7` measured, one
//  step further. `GuideAutopilotTakeoverTerminalPanel.sendEvent` HOLDS every
//  left mouse-down and watches it: a press that travels past a 3pt slop becomes
//  a window MOVE, and a press that never travels is replayed as a click. A real
//  click on a small pill routinely drifts more than 3pt between the finger going
//  down and coming up, so "Try again", "Continue past it", and the red escape
//  hatch were being read as tiny drags — the window slid a few points and the
//  button never fired. To the reader that is "the button doesn't work … it is
//  just moving the terminal around", and because the red light IS the close, it
//  is also "close the Iris terminal needs to work, or else … restart Iris".
//
//  THE FIX under test: the terminal's interactive controls report their own
//  frames up to the panel (`TakeoverControlFramesKey` →
//  `interactiveControlFrames`), and a press that lands on one is delivered
//  STRAIGHT THROUGH to SwiftUI instead of being held for the drag loop — so the
//  button fires no matter how much the press drifts. A `Button` has no AppKit
//  view of its own, so `hitTest` cannot find it; the frame report is the only
//  handle the panel has.
//
//  These tests drive the REAL takeover — its own panel, its own `sendEvent`,
//  its own SwiftUI preference plumbing — with a gesture posted the way Test6 and
//  Test7 post theirs (an event with no window carries a SCREEN location, which
//  is what `screenLocation(of:)` reads), and read the window frame back. If the
//  control frames never reach the panel, or reach it in the wrong coordinate
//  space, the press lands on nothing and the window moves — which is exactly the
//  failure the reader hit, so the test would catch a fix that only looks right.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

/// A presenter parked on `.surfacedToReader`, so the terminal draws the "Your
/// turn" row with the real "Try again" and "Continue past it" buttons — the two
/// controls the reader named. Nothing animates (`isExecutingACommand == false`),
/// so the reported frames settle instead of chasing a blinking cursor.
@MainActor
private final class SurfacedRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .surfacedToReader(
        diagnosis: "Iris could not finish this step on its own.",
        failingCommand: "cargo build"
    )
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Build the app", stepNumber: 3, totalSteps: 6),
        .commandFromTheGuide(text: "cargo build --release"),
        .output(line: "error: could not compile `whimprflow`"),
        .exitStatus(code: 101, duration: 3.2)
    ]
    @Published var isExecutingACommand: Bool = false
}

/// A presenter parked mid-install (`.running`), the shape `Test6` uses: no
/// surfaced/confirm row, so the only controls are the title-strip pair plus the
/// "I did it — continue" manual-step button the takeover overlays at the bottom
/// once parked.
@MainActor
private final class RunningRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 0)
    @Published var transcript: [GuideAutopilotTranscriptEntry] =
        (0..<30).map { .output(line: "line \($0) some output from the shell") }
    @Published var isExecutingACommand: Bool = false
}

@MainActor
@Suite(.serialized) struct Test8TakeoverControlClickTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    private struct LiveTakeover {
        let controller: GuideAutopilotTakeoverController
        let terminal: Panel
    }

    /// Polls a main-actor condition. The takeover animates on its own clock, so
    /// a fixed sleep is a coin flip under a loaded machine — Test7's lesson.
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

    /// Raises a real takeover over a surfaced-to-reader runner and waits for the
    /// entry morph to grow the window to its terminal size, so the buttons are
    /// laid out where the reader would actually aim.
    private static func raiseSurfacedTakeover() async throws -> LiveTakeover {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = SurfacedRunner()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !before.contains(ObjectIdentifier($0)) },
            "the takeover must raise its own terminal panel subclass"
        )
        // Hold the runner alive for the length of the test: the panel keeps only
        // a weak view of it through the hosting view, and a deallocated runner
        // stops publishing the state the surface row is drawn from.
        objc_setAssociatedObject(
            terminal, &Self.runnerHolderKey, runner, .OBJC_ASSOCIATION_RETAIN
        )
        try #require(
            await pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        return LiveTakeover(controller: controller, terminal: terminal)
    }

    private static var runnerHolderKey: UInt8 = 0

    /// Builds one mouse event with no window, so it carries a SCREEN location —
    /// the seam `screenLocation(of:)` reads to let a posted gesture drive the
    /// panel's tracking loop without the machine's physical mouse (and without
    /// the Accessibility grant a real `CGEvent` would need — the test host has
    /// none: `AXIsProcessTrusted()` is false inside it).
    private static func mouseEvent(
        _ type: NSEvent.EventType, atScreenPoint point: CGPoint
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    /// Press, drag in 15 steps, release. The drag and release are queued FIRST,
    /// because `sendEvent` on the mouse-down does not return until the gesture is
    /// over — the panel pulls the rest of it out of the queue itself.
    private static func postAGesture(
        to panel: NSPanel, grabbingAtWindowPoint grabPoint: CGPoint, movingBy delta: CGPoint
    ) {
        let grabInScreen = CGPoint(
            x: panel.frame.minX + grabPoint.x, y: panel.frame.minY + grabPoint.y
        )
        for step in 1...15 {
            let along = CGFloat(step) / 15
            if let dragged = mouseEvent(
                .leftMouseDragged,
                atScreenPoint: CGPoint(
                    x: grabInScreen.x + delta.x * along, y: grabInScreen.y + delta.y * along
                )
            ) {
                NSApp.postEvent(dragged, atStart: false)
            }
        }
        if let released = mouseEvent(
            .leftMouseUp,
            atScreenPoint: CGPoint(x: grabInScreen.x + delta.x, y: grabInScreen.y + delta.y)
        ) {
            NSApp.postEvent(released, atStart: false)
        }
        if let pressed = mouseEvent(.leftMouseDown, atScreenPoint: grabInScreen) {
            panel.sendEvent(pressed)
        }
    }

    /// The centre of a reported control frame, expressed as the window point a
    /// gesture grabs. The frames are content-view coordinates (top-left origin,
    /// y down — SwiftUI `.global` inside the hosting view that IS the content
    /// view); a grab point is window coordinates (bottom-left origin), so the y
    /// flips through the window height, the exact inverse of the flip
    /// `pressLandsOnAControl` does.
    private static func windowGrabPoint(
        forControlFrame frame: CGRect, windowHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: frame.midX, y: windowHeight - frame.midY)
    }

    /// Records which reader-facing action the real takeover actually fired,
    /// wired straight to the closures `present(...)` invokes — so a test can
    /// assert the button DID something, not merely that the window held still.
    @MainActor private final class FiredActions {
        var retry = false
        var continuePast = false
    }

    /// Delivers a drifting click on a control the way a HARDWARE click arrives:
    /// as a windowed `NSEvent` whose `windowNumber` is the terminal panel's own,
    /// so `event.window` resolves to the panel and the panel's `sendEvent` reads
    /// the press through the `event.window != nil` branch of `grabOffsetInWindow`
    /// — the exact branch a real click takes, NOT the windowNumber:0 seam the
    /// drag tests use to drive travel without a physical mouse.
    ///
    /// The down lands on the control centre and the up drifts 4pt (past the 3pt
    /// slop, still inside the control), because that drift is the whole bug: the
    /// press that "doesn't work … just moves the terminal around" was a real
    /// finger drifting between down and up. A windowed `NSEvent` DOES drive
    /// SwiftUI's own button recogniser (the recogniser fires on the up that
    /// follows a down inside the button), so a delivered press runs the control's
    /// action — which is the half `clickingAnyControlDoesNotMoveTheTerminal`
    /// cannot see, because a press that is SWALLOWED also leaves the window still.
    private static func deliverAWindowedDriftingClick(
        to terminal: Panel, onControlFrame controlFrame: CGRect
    ) {
        let downInWindow = CGPoint(
            x: controlFrame.midX, y: terminal.frame.height - controlFrame.midY
        )
        let upInWindow = CGPoint(
            x: controlFrame.midX + 4, y: terminal.frame.height - (controlFrame.midY + 4)
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

    // MARK: - The control frames actually reach the panel

    /// The whole fix rests on the SwiftUI preference reaching the panel. If it
    /// does not — a stale `.global` space, an `onPreferenceChange` that never
    /// fires in a hosted panel — the panel has no idea where its buttons are and
    /// every press still becomes a drag. So prove the frames arrive first.
    @Test func theTerminalsButtonsReportTheirFramesToThePanel() async throws {
        let takeover = try await Self.raiseSurfacedTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }

        try #require(
            await Self.pump { !takeover.terminal.interactiveControlFrames.isEmpty },
            """
            the terminal's controls never reported a single frame to the panel, so a press \
            on a button cannot be told apart from a press on the background — the click fix \
            has no data to work with
            """
        )

        // The "Your turn" buttons (Try again / Continue past it) render in the
        // transcript BELOW the 24pt title strip, so they must show up among the
        // reported frames clear of it. The escape hatch and Help sit inside the
        // strip (y < 24); measured, the two named buttons report at y≈172-178.
        // (`heightOfTheTitleStrip` is private to the panel, so 24 is spelled out
        // here with this note rather than referenced.)
        let heightOfTheTitleStrip: CGFloat = 24
        let buttonsBelowTheTitleStrip = takeover.terminal.interactiveControlFrames.filter {
            $0.minY >= heightOfTheTitleStrip
        }
        #expect(
            buttonsBelowTheTitleStrip.count >= 2,
            """
            the "Your turn" row's Try again / Continue past it did not report their frames — \
            only \(takeover.terminal.interactiveControlFrames.count) control frame(s) arrived, \
            none clear of the title strip — so the two buttons the reader could not click are \
            still invisible to the drag exclusion
            """
        )
    }

    // MARK: - THE REPRO: a click on a button must not move the window

    /// Grab the CENTRE of each interactive control — Try again, Continue past
    /// it, the red escape hatch (which IS the close), Help — and drift well past
    /// the 3pt slop, the way a real finger does. At HEAD (before the frame-report
    /// fix) the panel's own tracking loop dequeued that drift and slid the
    /// window, and the button never fired — "it is just moving the terminal
    /// around", and for the red light, "close the Iris terminal needs to work,
    /// or else … restart Iris". After the fix a press on a reported control is
    /// handed straight to SwiftUI and never enters the tracking loop, so the
    /// window does not move.
    @Test func clickingAnyControlDoesNotMoveTheTerminal() async throws {
        let takeover = try await Self.raiseSurfacedTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }

        try #require(
            await Self.pump { takeover.terminal.interactiveControlFrames.count >= 3 },
            """
            fewer than three controls reported their frames — the surfaced row's two buttons \
            plus the escape hatch should all be present; see \
            theTerminalsButtonsReportTheirFramesToThePanel
            """
        )

        let controlsOnScreen = takeover.terminal.interactiveControlFrames
        let originBeforeAnyClick = takeover.terminal.frame.origin
        for controlFrame in controlsOnScreen {
            let grabPoint = Self.windowGrabPoint(
                forControlFrame: controlFrame, windowHeight: takeover.terminal.frame.height
            )
            // A real click's drift: 40pt across, 30pt up — an order of magnitude
            // past `theSlopAClickIsAllowed`, so nothing about this passing is the
            // drift happening to stay under the threshold.
            Self.postAGesture(
                to: takeover.terminal,
                grabbingAtWindowPoint: grabPoint,
                movingBy: CGPoint(x: 40, y: -30)
            )
            #expect(
                takeover.terminal.frame.origin == originBeforeAnyClick,
                """
                a drifting press on the control at \(controlFrame) moved the terminal to \
                \(takeover.terminal.frame.origin) instead of leaving it at \(originBeforeAnyClick) \
                — "Hit try again, the button doesn't work though … it is just moving the \
                terminal around"
                """
            )
        }
    }

    // MARK: - THE OTHER HALF: a drifting click FIRES the button's action

    /// The claim the reader disputed was not "the window moves" — it was "the
    /// button doesn't work." `clickingAnyControlDoesNotMoveTheTerminal` proves
    /// the window holds still, but a press that is SWALLOWED holds it still too,
    /// so on its own it cannot tell a working button from a dead one. This drives
    /// a real drifting click at "Try again" and at "Continue past it" — the two
    /// controls the Test-8 reader named — and asserts each one's ACTION actually
    /// runs, through the closure the takeover fires. The press is a windowed
    /// `NSEvent` (the panel's own `windowNumber`), so it travels the real
    /// `event.window != nil` path a hardware click takes, not the windowNumber:0
    /// seam, and the SwiftUI button recogniser fires on it.
    ///
    /// Out of band this same behaviour was measured with real `CGEvent`s posted
    /// through the window server against the real controller (an
    /// Accessibility-trusted run, `tools/takeover-click-harness/`): a drifting
    /// click fired "Continue past it" and "Try again" at every drift magnitude,
    /// and with the control frames blanked — the pre-fix state — the same press
    /// slid the window and fired nothing. This test is the in-suite half that
    /// runs everywhere, no Accessibility grant required.
    @Test func aDriftingClickFiresTheSurfacedRowButtonsActions() async throws {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = SurfacedRunner()
        let fired = FiredActions()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: { fired.retry = true },
            onContinuePastSurfacedStep: { fired.continuePast = true },
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        defer { controller.dismiss(afterHold: false) }
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !before.contains(ObjectIdentifier($0)) },
            "the takeover must raise its own terminal panel subclass"
        )
        objc_setAssociatedObject(
            terminal, &Self.runnerHolderKey, runner, .OBJC_ASSOCIATION_RETAIN
        )
        try #require(
            await Self.pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
        try #require(
            await Self.pump {
                terminal.interactiveControlFrames.filter { $0.minY >= 24 }.count >= 2
            },
            "the surfaced row's two buttons never reported their frames below the title strip"
        )

        // Below the 24pt title strip, sorted by x: "Continue past it" (the left,
        // a text button) then "Try again" (the right, the primary pill).
        let surfacedButtons = terminal.interactiveControlFrames
            .filter { $0.minY >= 24 }
            .sorted { $0.minX < $1.minX }
        let continuePastFrame = try #require(surfacedButtons.first)
        let tryAgainFrame = try #require(surfacedButtons.last)

        let originBefore = terminal.frame.origin

        Self.deliverAWindowedDriftingClick(to: terminal, onControlFrame: continuePastFrame)
        #expect(
            await Self.pump { fired.continuePast },
            """
            a drifting click on "Continue past it" never ran its action — \
            "Continue past it button not working either, it is just moving the terminal around"
            """
        )
        #expect(
            terminal.frame.origin == originBefore,
            "the press on 'Continue past it' fired its action but also moved the window"
        )

        Self.deliverAWindowedDriftingClick(to: terminal, onControlFrame: tryAgainFrame)
        #expect(
            await Self.pump { fired.retry },
            #"a drifting click on "Try again" never ran its action — "Hit try again, the button doesn't work though""#
        )
        #expect(
            terminal.frame.origin == originBefore,
            "the press on 'Try again' fired its action but also moved the window"
        )
    }

    /// The move must survive the click fix. A press in the transcript BODY —
    /// nowhere near a reported control — is still a drag, because the whole card
    /// is deliberately a handle ("please make the terminal movable" was the
    /// report that earned that). If this stops working the fix has swung too far
    /// and swallowed the drag it was told not to touch.
    @Test func aPressInTheBodyStillMovesTheTerminal() async throws {
        let takeover = try await Self.raiseSurfacedTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }
        try #require(
            await Self.pump { !takeover.terminal.interactiveControlFrames.isEmpty },
            "the controls never reported their frames"
        )

        // The middle of the card is transcript output, not a control. Prove that
        // before leaning on it: convert it to content space and check no
        // reported frame contains it.
        let frame = takeover.terminal.frame
        let bodyGrab = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let bodyInContent = CGPoint(x: bodyGrab.x, y: frame.height - bodyGrab.y)
        try #require(
            !takeover.terminal.interactiveControlFrames.contains { $0.contains(bodyInContent) },
            "the point chosen as 'body' is actually inside a control frame — pick another"
        )

        let originBefore = takeover.terminal.frame.origin
        Self.postAGesture(
            to: takeover.terminal, grabbingAtWindowPoint: bodyGrab, movingBy: CGPoint(x: -120, y: 40)
        )
        #expect(
            takeover.terminal.frame.origin
                == CGPoint(x: originBefore.x - 120, y: originBefore.y + 40),
            """
            a press in the transcript body left the card at \(takeover.terminal.frame.origin) \
            instead of moving it by the drag — the click fix must not have swallowed the drag \
            the whole card is meant to be a handle for
            """
        )
    }

    // MARK: - The parked card: body still drags, the manual button now clicks

    /// Why `Test6.theReaderCanDragTheParkedTerminalByItsBody` fails after this
    /// fix, and why it is a stale test rather than a regression. Test6 parks the
    /// terminal — which overlays the full-width "I did it — continue" button
    /// along the bottom — then walks UP the middle of the card from the very
    /// bottom looking for the first point to drag, and that first point is now
    /// INSIDE the manual-step button, which this fix DELIBERATELY makes a click,
    /// not a drag handle. Dragging by a real button was the bug ("it is just
    /// moving the terminal around"), so a test that leans on it has to move its
    /// grab point off the button.
    ///
    /// This proves both halves in the parked scenario: the bottom of the card is
    /// a control (so Test6's bottom-up search lands on one), and a transcript
    /// point clear of every control still drags the parked card exactly as
    /// before — nothing the reader relies on broke.
    @Test func theParkedCardStillDragsByABodyPointClearOfTheManualStepButton() async throws {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = RunningRunner()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        defer { controller.dismiss(afterHold: false) }
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !before.contains(ObjectIdentifier($0)) }
        )
        objc_setAssociatedObject(
            terminal, &Self.runnerHolderKey, runner, .OBJC_ASSOCIATION_RETAIN
        )
        try #require(await Self.pump { terminal.frame.width > 700 }, "never grew to terminal size")
        // Park: slides to the corner AND overlays the "I did it — continue" bar.
        controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        // Let the park slide + shrink settle before probing, the way Test6 does:
        // reading the frame mid-animation reads a transitional geometry.
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)

        let cardFrame = terminal.frame
        let controls = terminal.interactiveControlFrames
        func isInAControl(_ windowPoint: CGPoint) -> Bool {
            let inContent = CGPoint(x: windowPoint.x, y: cardFrame.height - windowPoint.y)
            return controls.contains { $0.contains(inContent) }
        }

        // Half one — the bottom of the parked card, where Test6 aims first, is a
        // control (the full-width manual-step button). This is the whole reason
        // Test6's "drag by the body" assertion flipped: it grabs the button.
        #expect(
            controls.contains { $0.midY > cardFrame.height / 2 },
            """
            no control reported a frame in the lower half of the parked card, so the manual-step \
            button is not what Test6's bottom-up grab search is now landing on — its failure \
            would need another explanation
            """
        )

        // Half two — a transcript point clear of every control still drags the
        // parked card. Walk down from just under the title strip and take the
        // first window point whose content position is inside no control frame.
        var bodyWindowPoint: CGPoint?
        var contentY: CGFloat = 30
        while contentY < cardFrame.height - 30 {
            let windowPoint = CGPoint(x: cardFrame.width / 2, y: cardFrame.height - contentY)
            if !isInAControl(windowPoint) { bodyWindowPoint = windowPoint; break }
            contentY += 10
        }
        let bodyPoint = try #require(
            bodyWindowPoint, "no transcript point clear of the controls to drag the parked card by"
        )
        let originBefore = terminal.frame.origin
        Self.postAGesture(
            to: terminal, grabbingAtWindowPoint: bodyPoint, movingBy: CGPoint(x: -150, y: 60)
        )
        #expect(
            terminal.frame.origin == CGPoint(x: originBefore.x - 150, y: originBefore.y + 60),
            """
            dragging the parked card by a transcript point clear of controls left it at \
            \(terminal.frame.origin) instead of \
            \(CGPoint(x: originBefore.x - 150, y: originBefore.y + 60)) — the body drag the \
            reader relies on must survive the click fix
            """
        )
    }
}
