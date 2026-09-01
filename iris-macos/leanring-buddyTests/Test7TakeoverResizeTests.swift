//
//  Test7TakeoverResizeTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS (Test 7 field report, Iris 0.9.1 build 17):
//
//      "You cannot resize the terminal tab."
//
//  True at HEAD by construction, and measured: the takeover terminal is a
//  `[.borderless, .nonactivatingPanel]` window whose every frame comes from
//  `GuideAutopilotTakeoverController` (`terminalSizedFrame` 760x480,
//  `parkedFrame` 400x340). `styleMask.contains(.resizable)` is false, there is
//  no title bar to grab, and — the part that would have defeated `.resizable`
//  even if it were set — `GuideAutopilotTakeoverTerminalPanel.sendEvent` HOLDS
//  every left mouse-down for its own drag-tracking loop, so a press on the
//  window's edge never survives to reach AppKit's own resize handling. Dragging
//  an edge slid the whole window instead.
//
//  So the resize is implemented in that same tracking loop, next to the move,
//  and these tests drive it the way `Test6TakeoverPanelReproTests` drives the
//  drag: a real gesture posted at the real panel, with the window frame read
//  back afterwards.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

@MainActor
private final class StillRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 0)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = []
    @Published var isExecutingACommand: Bool = false
}

@MainActor
@Suite(.serialized) struct Test7TakeoverResizeTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    // MARK: - Which presses take hold of an edge

    /// The body of the card is a move, its edges are a resize, and the title
    /// strip is neither — because the red escape hatch lives there and this
    /// window has already earned "you can't close out of it" once.
    @Test func onlyTheEdgesResizeAndTheTitleStripIsLeftAlone() {
        let card = CGSize(width: 400, height: 340)

        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: 200, y: 3), forACardOfSize: card)
                == .bottom,
            "the bottom edge must resize"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: 397, y: 170), forACardOfSize: card)
                == .right,
            "the right edge must resize"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: 3, y: 170), forACardOfSize: card)
                == .left,
            "the left edge must resize"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: 397, y: 3), forACardOfSize: card)
                == [.right, .bottom],
            "the bottom-right corner must resize both ways at once"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: 200, y: 170), forACardOfSize: card)
                .isEmpty,
            "the body of the card stays a drag handle"
        )

        // The escape hatch is drawn at roughly (10…25, height-19.5…height-4.5).
        // Not one point of it may be read as a resize grip.
        for xAcrossTheRedLight in stride(from: CGFloat(8), through: 27, by: 1) {
            for yDownTheStrip in stride(from: card.height - 24, through: card.height, by: 1) {
                #expect(
                    Panel.edgesUnderThePress(
                        at: CGPoint(x: xAcrossTheRedLight, y: yDownTheStrip),
                        forACardOfSize: card
                    ).isEmpty,
                    """
                    a press at (\(xAcrossTheRedLight), \(yDownTheStrip)) — inside the title \
                    strip, on the red escape hatch — was read as a resize grip
                    """
                )
            }
        }
    }

    /// THE ONE THING ON SCREEN THAT SAYS "THIS RESIZES" MUST BE A PLACE THAT
    /// RESIZES.
    ///
    /// `GuideAutopilotResizeGrip` is drawn `.frame(width: 11, height: 11)` with
    /// `.padding(4)` at `.bottomTrailing`, so its ink runs from 4pt to 15pt in
    /// from the bottom and right edges and its centre is 9.5pt in. The grab band
    /// was 7pt. Every point of the glyph past that band MOVED the window —
    /// measured with a real gesture at its centre — which to a reader aiming at
    /// the handle is exactly "You cannot resize the terminal tab", the sentence
    /// this whole file exists for. A handle you must not aim at is not a handle.
    @Test func everyPointOfThePaintedGripActuallyGrabsTheCorner() {
        let card = CGSize(width: 400, height: 340)
        // The glyph's own box in window coordinates (bottom-left origin): 11pt
        // wide, inset 4pt from the bottom and right edges.
        let gripBox = CGRect(
            x: card.width - 4 - 11, y: 4, width: 11, height: 11
        )

        for xAcrossTheGrip in stride(from: gripBox.minX, through: gripBox.maxX, by: 0.5) {
            for yUpTheGrip in stride(from: gripBox.minY, through: gripBox.maxY, by: 0.5) {
                #expect(
                    Panel.edgesUnderThePress(
                        at: CGPoint(x: xAcrossTheGrip, y: yUpTheGrip), forACardOfSize: card
                    ) == [.right, .bottom],
                    """
                    a press at (\(xAcrossTheGrip), \(yUpTheGrip)) — inside the painted resize \
                    grip, \(card.width - xAcrossTheGrip)pt in from the right and \(yUpTheGrip)pt \
                    up from the bottom — did not take hold of the corner, so aiming at the \
                    handle moves the window instead of resizing it
                    """
                )
            }
        }
    }

    /// The corner is bigger than the edges, and that must not eat the body.
    @Test func theWiderCornerDoesNotSwallowTheBodyOfTheCard() {
        let card = CGSize(width: 400, height: 340)
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: card.width - 40, y: 40), forACardOfSize: card)
                .isEmpty,
            "a press well inside the bottom-right of the body is still a drag"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: card.width - 30, y: 3), forACardOfSize: card)
                == .bottom,
            "the bottom edge away from the corner still takes only the bottom"
        )
        #expect(
            Panel.edgesUnderThePress(at: CGPoint(x: card.width - 3, y: 40), forACardOfSize: card)
                == .right,
            "the right edge above the corner still takes only the right"
        )
    }

    // MARK: - Where a resize lands

    @Test func aResizeMovesTheGrabbedEdgeAndAnchorsTheOthers() {
        let start = CGRect(x: 1000, y: 100, width: 400, height: 340)

        // Dragging the right edge out by 120 widens it and leaves the left edge.
        let widened = Panel.frameResized(
            from: start, by: .right,
            pointerAtThePress: CGPoint(x: 1400, y: 250), pointerNow: CGPoint(x: 1520, y: 250)
        )
        #expect(widened == CGRect(x: 1000, y: 100, width: 520, height: 340))

        // Dragging the bottom edge DOWN by 60 makes it taller and leaves the top
        // where it is — the title strip must not walk up the screen under the
        // hand that is dragging the opposite edge.
        let taller = Panel.frameResized(
            from: start, by: .bottom,
            pointerAtThePress: CGPoint(x: 1200, y: 100), pointerNow: CGPoint(x: 1200, y: 40)
        )
        #expect(taller == CGRect(x: 1000, y: 40, width: 400, height: 400))
        #expect(taller.maxY == start.maxY, "the top edge is the anchor for a bottom drag")

        // Dragging the left edge right narrows it and leaves the right edge.
        let narrowed = Panel.frameResized(
            from: start, by: .left,
            pointerAtThePress: CGPoint(x: 1000, y: 250), pointerNow: CGPoint(x: 1060, y: 250)
        )
        #expect(narrowed == CGRect(x: 1060, y: 100, width: 340, height: 340))
        #expect(narrowed.maxX == start.maxX, "the right edge is the anchor for a left drag")
    }

    /// A card small enough to be useless is its own way of stranding somebody:
    /// the transcript stops being readable and the manual-step bar has nowhere
    /// to put "I did it — continue".
    @Test func aResizeCannotShrinkTheCardBelowWhatItNeeds() {
        let start = CGRect(x: 1000, y: 100, width: 400, height: 340)
        let squashed = Panel.frameResized(
            from: start, by: [.right, .bottom],
            pointerAtThePress: CGPoint(x: 1400, y: 100), pointerNow: CGPoint(x: 1005, y: 435)
        )
        #expect(squashed.width == Panel.smallestTheCardMayBeMade.width)
        #expect(squashed.height == Panel.smallestTheCardMayBeMade.height)
        #expect(squashed.maxY == start.maxY, "clamping must not detach the anchored edge")
    }

    // MARK: - A real gesture at the real panel

    private struct LiveTakeover {
        let controller: GuideAutopilotTakeoverController
        let terminal: NSPanel
    }

    /// Polls a main-actor condition. Window animations run on their own clock,
    /// and under a loaded machine they finish later than any fixed sleep.
    private static func pump(
        within seconds: Double = 8, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    private static func raiseTakeover() async throws -> LiveTakeover {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = StillRunner()
        runner.transcript = (0..<12).map { .output(line: "line \($0) output from the shell") }
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? NSPanel }
                .filter { !before.contains(ObjectIdentifier($0)) }
                .first { !$0.ignoresMouseEvents && $0.frame.width == 132 }
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        return LiveTakeover(controller: controller, terminal: terminal)
    }

    /// Builds one mouse event with no window, so it carries a SCREEN location —
    /// which is what `GuideAutopilotTakeoverTerminalPanel.screenLocation(of:)`
    /// reads. This is how the panel's own tracking loop can be driven without
    /// seizing the machine's physical mouse, and without the Accessibility grant
    /// posting real `CGEvent`s would need (the test runner has none:
    /// `AXIsProcessTrusted()` is false inside it — re-measured, Test 7).
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
    /// because `sendEvent` on the mouse-down does not return until the gesture
    /// is over — the panel pulls the rest of it out of the queue itself.
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

    /// THE REPRO, driven end to end: grab the bottom-right corner of the real
    /// takeover and drag. At HEAD this MOVED the window (the whole body is a
    /// drag handle and nothing told it an edge meant anything else), which is
    /// "You cannot resize the terminal tab."
    @Test func draggingTheCornerResizesTheTerminalInsteadOfMovingIt() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }
        let frameBefore = takeover.terminal.frame

        // The bottom-right corner, 2pt in from each edge.
        let corner = CGPoint(x: frameBefore.width - 2, y: 2)
        Self.postAGesture(
            to: takeover.terminal, grabbingAtWindowPoint: corner, movingBy: CGPoint(x: 90, y: -70)
        )

        let frameAfter = takeover.terminal.frame
        #expect(
            frameAfter.size == CGSize(
                width: frameBefore.width + 90, height: frameBefore.height + 70
            ),
            """
            dragging the bottom-right corner left the card at \(frameAfter.size) instead of \
            \(CGSize(width: frameBefore.width + 90, height: frameBefore.height + 70)) — \
            "You cannot resize the terminal tab."
            """
        )
        #expect(
            frameAfter.maxY == frameBefore.maxY && frameAfter.minX == frameBefore.minX,
            "a corner drag must grow the card from its top-left, not walk it across the screen"
        )
    }

    /// The same gesture the audit ran, at the point a reader actually aims at:
    /// the CENTRE of the painted grip. Before the corner square this moved the
    /// window — "dragging the bottom-right corner left the card at (760, 480)
    /// instead of (850, 550)".
    @Test func draggingThePaintedGripItselfResizesTheTerminal() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }
        // WAIT FOR THE ENTRY MORPH, don't assume it. The takeover GROWS from
        // eye size (132pt) to the terminal's 760x480, and under the full suite
        // that animation runs past the fixed settle: measured, this test read a
        // 132pt card, resized it, and got 300pt back because the minimum size
        // clamped it — a failure that says nothing about the grip.
        try #require(
            await Self.pump { takeover.terminal.frame.width > 700 },
            "the takeover never finished growing to its terminal size — nothing to grab yet"
        )
        let frameBefore = takeover.terminal.frame

        // The grip is an 11pt glyph inset 4pt from each edge, so its centre is
        // 9.5pt in from the bottom and the right.
        let centreOfThePaintedGrip = CGPoint(x: frameBefore.width - 9.5, y: 9.5)
        Self.postAGesture(
            to: takeover.terminal,
            grabbingAtWindowPoint: centreOfThePaintedGrip,
            movingBy: CGPoint(x: 90, y: -70)
        )

        let frameAfter = takeover.terminal.frame
        #expect(
            frameAfter.size == CGSize(
                width: frameBefore.width + 90, height: frameBefore.height + 70
            ),
            """
            grabbing the middle of the painted grip left the card at \(frameAfter.size) instead \
            of \(CGSize(width: frameBefore.width + 90, height: frameBefore.height + 70)) — the \
            only affordance drawn for the reader is outside the zone that answers it
            """
        )
        #expect(
            frameAfter.maxY == frameBefore.maxY && frameAfter.minX == frameBefore.minX,
            "grabbing the grip must grow the card from its top-left, not walk it across the screen"
        )
    }

    /// The move must survive the resize being added. A press in the BODY is
    /// still a drag — "please make the terminal movable" was the last report
    /// about this window and it must not be undone by this one.
    @Test func thePressInTheBodyStillMovesTheWindow() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }
        let frameBefore = takeover.terminal.frame

        let middleOfTheCard = CGPoint(x: frameBefore.width / 2, y: frameBefore.height / 2)
        Self.postAGesture(
            to: takeover.terminal,
            grabbingAtWindowPoint: middleOfTheCard,
            movingBy: CGPoint(x: -120, y: 40)
        )

        #expect(takeover.terminal.frame.size == frameBefore.size, "a body drag must not resize")
        #expect(
            takeover.terminal.frame.origin
                == CGPoint(x: frameBefore.minX - 120, y: frameBefore.minY + 40),
            "a body drag must still move the card"
        )
    }

    /// The other half of the complaint. A window that snaps back to Iris's own
    /// size on the very next step is not resizable in any way the reader would
    /// recognise — the same thing the dragged-to POSITION latch was added for.
    @Test func irisKeepsTheSizeTheReaderChose() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.controller.dismiss(afterHold: false) }

        let corner = CGPoint(x: takeover.terminal.frame.width - 2, y: 2)
        Self.postAGesture(
            to: takeover.terminal, grabbingAtWindowPoint: corner, movingBy: CGPoint(x: -140, y: 60)
        )
        let sizeTheReaderChose = takeover.terminal.frame.size
        try #require(
            sizeTheReaderChose != CGSize(width: 400, height: 340),
            "the chosen size must differ from the parked size, or this test proves nothing"
        )

        // Parking would otherwise force 400x340 on them.
        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
        #expect(
            takeover.terminal.frame.size == sizeTheReaderChose,
            "parking must not throw away the size the reader chose"
        )

        // And returning to center would otherwise force 760x480.
        takeover.controller.returnToCenter()
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
        #expect(
            takeover.terminal.frame.size == sizeTheReaderChose,
            "returning to center must not throw away the size the reader chose"
        )
    }
}
