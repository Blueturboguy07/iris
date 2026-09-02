//
//  Test6TakeoverPanelReproTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS, three complaints about one window — the takeover
//  terminal `GuideAutopilotTakeoverController` parks in the corner while a
//  manual step waits on them:
//
//    - "When telling me to install Cmake, the iris install terminal says
//      Install rust, very confusing."
//    - "The terminal Iris is using is not movable at all, you can't close out
//      of it."
//    - "please make the terminal movable, it is not at all useable right now
//      because it covers where the download symbol is."
//
//  WHAT IS ACTUALLY WRONG — measured, not read off the source.
//
//  (H) `parkForManualStep` updates `pendingManualTitle`, then bails at
//  `guard !isParked` BEFORE it hands the new text to the view model. The guard
//  is there to keep the WINDOW ANIMATION idempotent, but it also gates the
//  CONTENT. Two manual steps in a row never park-and-unpark in between —
//  `GuideSessionController.drive()` calls `onAutopilotResumedFromGate`
//  (`returnToCenter`) only on the branch that is about to RUN a command, and a
//  manual step returns out of the loop before reaching it — so the second gate
//  re-parks an already-parked window and the reader keeps reading step one.
//  Driving the real controller through park("Install Rust") → park("Install
//  CMake") and rendering the panel to a bitmap produced a file byte-identical
//  to the "Install Rust" render (31839 bytes, FNV 281430639780185676) and
//  different from a takeover parked straight onto "Install CMake" (34855 bytes,
//  FNV 1048608809967751155). The PNG says, in the reader's own words,
//  "Install Rust / Download rustup and run it." while the step is CMake.
//
//  The two titles here are not invented. `publik/lib/guides/whimprflow.ts`
//  authors the macOS toolchain as `install-rust` (kind `open`) immediately
//  followed by `install-cmake` (kind `open`) — two manual steps back to back,
//  each one asking the reader to DOWNLOAD something from a web page. That is
//  the pair the reader hit. (`hickeyfield.ts` has the same shape on macOS at
//  `get-key` → `paste-key`.)
//
//  (G) The terminal panel is `[.borderless, .nonactivatingPanel]` — no title
//  bar to grab — and `isMovableByWindowBackground` is never set, so it is
//  false. Measured on the live panel: movableByWindowBackground=false,
//  titled=false, resizable=false. AppKit therefore offers no drag path at all.
//  And when the window IS moved, Iris throws the new position away: after
//  moving the panel to (120, 120), `returnToCenter()` put it back at
//  (376, 251) and the next `parkForManualStep` put it back at (1088, 580).
//
//  Where it parks is the other half. `parkedFrame` is the TOP-RIGHT corner
//  (visibleFrame.maxX - 400 - 24, visibleFrame.maxY - 340 - 24) — exactly
//  where every browser keeps its download chip. On this Mac (screen
//  1512x982, visibleFrame (34, 0, 1478, 944)) the parked window is
//  (1088, 580, 400, 340), and the browser windows actually open at the time
//  were measured with CGWindowList:
//
//      Safari  appKit frame (159, 0, 1160, 934)   toolbar right cluster
//              (1099, 844, 220, 90)   → overlaps the parked window
//      Firefox appKit frame (278, 140, 1191, 793) toolbar right cluster
//              (1249, 843, 220, 90)   → overlaps the parked window
//
//  Iris parks its terminal on top of the one control the step is telling the
//  reader to click.
//
//  These tests drive the REAL `GuideAutopilotTakeoverController` — its own
//  panels, its own animations, its own view model — and read back what the
//  reader would see.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

// MARK: - The quietest presenter the takeover will accept

/// A stand-in for `GuideAutopilotRunner` with nothing moving in it. The
/// running-cursor line blinks while `isExecutingACommand` is true, and an
/// animating pixel would make every bitmap comparison a coin flip; with it
/// false, two captures of an unchanged panel hash identically (asserted in
/// `theRenderedPanelIsAStableWitness`).
@MainActor
private final class QuietTakeoverRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .running(stepIndex: 0)
    @Published var transcript: [GuideAutopilotTranscriptEntry] = []
    @Published var isExecutingACommand: Bool = false
}

/// One live takeover: the controller, the runner keeping it alive, and the
/// panel the reader actually looks at.
@MainActor
private struct LiveTakeover {
    let controller: GuideAutopilotTakeoverController
    let runner: QuietTakeoverRunner
    let terminal: NSPanel

    /// The takeover's view model — the object `Text(model.manualStepTitle)` is
    /// bound to, pulled out of the controller that owns it.
    var model: GuideAutopilotTakeoverModel? {
        for child in Mirror(reflecting: controller).children {
            if let model = child.value as? GuideAutopilotTakeoverModel { return model }
        }
        return nil
    }

    /// What the reader sees, as bytes: the whole parked window rendered to a
    /// PNG and hashed. Two renders of the same content hash the same; a
    /// different manual-step title changes the hash.
    ///
    /// `named` is only used when `IRIS_PANEL_RENDER_DUMP_DIR` is set, in which
    /// case the PNG is also written there under that name. A hash says "the
    /// pixels changed"; it cannot say "and they now read Install CMake", and
    /// that sentence is the whole complaint — so the way to check the fix is to
    /// run this suite with the variable set and LOOK at the two files. Off by
    /// default, like the other harnesses in this target, so an ordinary test
    /// run writes nothing.
    func renderedPixels(named: String = "render") -> String {
        guard let contentView = terminal.contentView else { return "no-content-view" }
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        let bounds = contentView.bounds
        guard let representation = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return "no-bitmap-rep"
        }
        contentView.cacheDisplay(in: bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            return "no-png"
        }
        if let dumpDirectory = ProcessInfo.processInfo.environment["IRIS_PANEL_RENDER_DUMP_DIR"] {
            try? data.write(
                to: URL(fileURLWithPath: dumpDirectory).appendingPathComponent("\(named).png")
            )
        }
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return "\(data.count)b/\(hash)"
    }

    func dismiss() { controller.dismiss(afterHold: false) }
}

@MainActor
@Suite(.serialized) struct Test6TakeoverPanelReproTests {

    // MARK: - Harness

    /// The morph in is a 0.4s hold plus a 0.5s grow; a park is another 0.5s.
    /// Every wait here is generous on top of that, because the assertions are
    /// about settled state, never about a frame mid-flight.
    private static let settleNanoseconds: UInt64 = 1_400_000_000

    /// Raises a real takeover and waits for the entry morph to finish, so a
    /// park is not deferred by `entryMorphHasSettled`.
    private static func raiseTakeover() async throws -> LiveTakeover {
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = QuietTakeoverRunner()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        // The takeover raises two panels: a click-through backdrop the size of
        // the screen, and the eye-sized terminal that takes clicks.
        let terminal = try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? NSPanel }
                .filter { !before.contains(ObjectIdentifier($0)) }
                .first { !$0.ignoresMouseEvents && $0.frame.width == 132 },
            "the takeover must raise an eye-sized terminal panel that takes clicks"
        )
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
        return LiveTakeover(controller: controller, runner: runner, terminal: terminal)
    }

    private static func settle() async throws {
        try await Task.sleep(nanoseconds: Self.settleNanoseconds)
    }

    // MARK: - H: "the iris install terminal says Install rust"

    @Test func theTakeoverNamesTheStepTheReaderIsActuallyOn() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.dismiss() }
        let model = try #require(takeover.model)

        // Gate one: a manual step. The terminal parks in the corner naming it.
        takeover.controller.parkForManualStep(
            title: "Install Rust", instruction: "Download rustup and run it."
        )
        try await Self.settle()
        #expect(model.manualStepTitle == "Install Rust")
        let whatTheReaderSawOnRust = takeover.renderedPixels(named: "1-parked-on-rust")

        // Gate two, with no command in between — which is the whole point.
        // `returnToCenter` is only ever called on the branch of
        // `GuideSessionController.drive()` that is about to execute a command,
        // so two manual steps in a row re-park an already-parked window.
        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Self.settle()

        #expect(
            model.manualStepTitle == "Install CMake",
            "the parked terminal must name the step the reader is on, not the one before it"
        )
        #expect(
            model.manualStepInstruction == "Download the CMake .dmg and drag it in.",
            "the instruction under the title must move with it"
        )
        #expect(
            takeover.renderedPixels(named: "2-parked-on-cmake-after-rust") != whatTheReaderSawOnRust,
            """
            the reader is looking at pixels, not at a view model: the parked card must \
            visibly change when the step changes
            """
        )
    }

    /// The control for the test above: the same two titles, with a
    /// `returnToCenter` in between so the `!isParked` guard does not fire.
    /// This one passes today, and is here to prove the bitmap witness can see a
    /// title change at all — without it, "the pixels did not change" would be
    /// worthless as evidence.
    @Test func theRenderedPanelIsAStableWitness() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.dismiss() }

        takeover.controller.parkForManualStep(
            title: "Install Rust", instruction: "Download rustup and run it."
        )
        try await Self.settle()
        let rust = takeover.renderedPixels()

        // Nothing changed, so nothing may change in the render.
        try await Self.settle()
        #expect(takeover.renderedPixels() == rust, "an unchanged panel must render identically")

        takeover.controller.returnToCenter()
        try await Self.settle()
        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Self.settle()
        #expect(
            takeover.renderedPixels() != rust,
            "an unblocked re-park DOES change the render, so the witness can see a title change"
        )
    }

    // MARK: - G: "not movable at all" / "it covers where the download symbol is"

    /// THIS TEST USED TO ASSERT `isMovableByWindowBackground == true` AND
    /// NOTHING ELSE, and it passed while the reader's complaint was still true.
    /// That flag is a request, not an outcome: AppKit only honours it when the
    /// view under the press answers `true` to `mouseDownCanMoveWindow`, and
    /// SwiftUI backs every selectable transcript line with a `SelectionTextField`
    /// that answers `false`. Measured on the REAL parked card (1088, 24, 400,
    /// 340) by walking up the middle of it, 20pt at a time:
    ///
    ///     dy=4    NSHostingView         mDCMW=true
    ///     dy=84   SelectionTextField    mDCMW=false
    ///     dy=104  SelectionTextField    mDCMW=false
    ///     ...
    ///     dy=224  SelectionTextField    mDCMW=false
    ///     dy=324  NSHostingView         mDCMW=true
    ///
    /// So the card was draggable by its 24pt title strip and the manual-step
    /// bar, and dead across the transcript in between — which is 65% of the
    /// parked card and 95% of the running one, with nothing on screen saying
    /// which 24pt to aim at. The same gesture posted at those same points into
    /// a PLAIN `NSPanel` hosting the identical `GuideAutopilotTerminalView`
    /// moves it by (0, 0); through `GuideAutopilotTakeoverTerminalPanel` it
    /// moves by exactly the drag.
    ///
    /// So this test now drives a real gesture through the real panel's real
    /// `sendEvent` and reads the window frame back, rather than asking the
    /// window what it intends.
    @Test func theReaderCanDragTheParkedTerminalByItsBody() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.dismiss() }
        // A card with output in it, because the defect lives in the views
        // SwiftUI creates for transcript TEXT.
        takeover.runner.transcript = (0..<30).map {
            .output(line: "line \($0) some output from the shell")
        }
        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Self.settle()

        #expect(
            takeover.terminal.styleMask.contains(.titled) == false,
            "unchanged: the takeover is deliberately chromeless"
        )

        let contentView = try #require(takeover.terminal.contentView)
        contentView.layoutSubtreeIfNeeded()
        let cardFrame = takeover.terminal.frame

        // Find a grab point in the transcript that AppKit's own background drag
        // REFUSES. If there is no such point the defect cannot recur, and the
        // rest of this test would be measuring nothing — so say so out loud.
        let controlFrames = (takeover.terminal as? GuideAutopilotTakeoverTerminalPanel)?.interactiveControlFrames ?? []
        var whereAppKitRefusesToDrag: CGPoint?
        var heightOfTheCardAppKitRefuses: CGFloat = 0
        var dy: CGFloat = 4
        while dy < cardFrame.height {
            let pointInWindow = CGPoint(x: cardFrame.width / 2, y: dy)
            let viewUnderThePoint = contentView.hitTest(contentView.convert(pointInWindow, from: nil))
            if viewUnderThePoint?.mouseDownCanMoveWindow == false
                && !controlFrames.contains(where: { $0.contains(CGPoint(x: pointInWindow.x, y: cardFrame.height - pointInWindow.y)) }) {
                heightOfTheCardAppKitRefuses += 20
                if whereAppKitRefusesToDrag == nil { whereAppKitRefusesToDrag = pointInWindow }
            }
            dy += 20
        }
        let grabPoint = try #require(
            whereAppKitRefusesToDrag,
            """
            no point on the parked card reports mouseDownCanMoveWindow == false, so this \
            test can no longer see the defect it exists for — re-derive it before deleting it
            """
        )

        // The reader drags the card off the browser's download button.
        let dragDelta = CGPoint(x: -150, y: 60)
        let frameBeforeTheDrag = takeover.terminal.frame
        Self.postADragGesture(
            to: takeover.terminal, grabbingAtWindowPoint: grabPoint, movingBy: dragDelta
        )

        #expect(
            takeover.terminal.frame.origin
                == CGPoint(
                    x: frameBeforeTheDrag.minX + dragDelta.x,
                    y: frameBeforeTheDrag.minY + dragDelta.y
                ),
            """
            dragging the card by its body left it at \(takeover.terminal.frame.origin) instead \
            of \(CGPoint(x: frameBeforeTheDrag.minX + dragDelta.x, y: frameBeforeTheDrag.minY + dragDelta.y)) — \
            \(Int(heightOfTheCardAppKitRefuses))pt of this \(Int(cardFrame.height))pt card is \
            transcript that AppKit will not drag on its own, which is the reader's \
            "the terminal Iris is using is not movable at all"
            """
        )

        // And a press that never travels is still a CLICK: the panel now HOLDS
        // every left mouse-down to see whether it becomes a drag, so the card's
        // buttons (Run it, Try again, the red escape hatch) depend on it handing
        // an unmoved press straight back.
        //
        // What can be asserted HERE is that such a press does not move the
        // window. Whether the held press still reaches the BUTTON cannot be:
        // SwiftUI routes clicks through its own recognizers, which a
        // synthesized NSEvent does not drive — measured, a synthesized click on
        // the escape hatch fires nothing through a PLAIN NSPanel either, so it
        // would be a witness that fails for the unfixed build too. And the test
        // runner cannot post real ones: `AXIsProcessTrusted()` is false inside
        // it, so `CGEvent.post` is dropped on the floor.
        //
        // So that half was measured out of band, with real `CGEvent`s, against a
        // structural replica of this card in a borderless non-activating panel
        // (an Accessibility-trusted standalone binary). With this same panel
        // logic in place: a click on a `.buttonStyle(.plain)` traffic light ran
        // its action; a click on the manual-step bar's "I did it — continue"
        // ran its action; a double-click on a transcript line selected the word
        // under it ("shell"); and drags at every transcript point moved the
        // window by exactly the drag.
        let frameBeforeTheClick = takeover.terminal.frame
        Self.postAClickWithoutMoving(to: takeover.terminal, atWindowPoint: grabPoint)
        #expect(
            takeover.terminal.frame.origin == frameBeforeTheClick.origin,
            "a press that does not travel must stay a click, not nudge the window"
        )
    }

    /// The other half of "you can't close out of it". Making the whole card a
    /// handle makes it that much easier to shove off the screen, and the red
    /// escape hatch goes with it. The drag clamps so the title strip is always
    /// still there to grab (and to click).
    @Test func aDragCannotPushTheEscapeHatchOffEveryScreen() throws {
        let card = CGSize(width: 400, height: 340)
        let everywhereTheReaderCanSee = NSScreen.screens
            .map(\.visibleFrame)
            .reduce(CGRect.null) { $0.union($1) }
        try #require(!everywhereTheReaderCanSee.isNull, "this Mac must report at least one screen")

        for absurdOrigin in [
            CGPoint(x: -5000, y: -5000), CGPoint(x: 5000, y: 5000),
            CGPoint(x: -5000, y: 5000), CGPoint(x: 5000, y: -5000)
        ] {
            let landedAt = GuideAutopilotTakeoverTerminalPanel.keepingTheTitleStripReachable(
                absurdOrigin, forACardOfSize: card
            )
            let titleStrip = CGRect(
                x: landedAt.x, y: landedAt.y + card.height - 24, width: card.width, height: 24
            )
            let stillOnScreen = titleStrip.intersection(everywhereTheReaderCanSee)
            #expect(
                stillOnScreen.height == 24 && stillOnScreen.width >= 72,
                """
                dragging to \(absurdOrigin) left only \(stillOnScreen) of the title strip on \
                screen — the reader would have no red light left to stop the install with
                """
            )
        }

        // And a perfectly ordinary position is returned untouched.
        let ordinary = CGPoint(
            x: everywhereTheReaderCanSee.midX, y: everywhereTheReaderCanSee.midY
        )
        #expect(
            GuideAutopilotTakeoverTerminalPanel.keepingTheTitleStripReachable(
                ordinary, forACardOfSize: card
            ) == ordinary,
            "the clamp must never nudge a drag that was already on screen"
        )
    }

    // MARK: - Posting a real gesture at the panel

    /// Builds one mouse event. `windowNumber: 0` deliberately: an event with no
    /// window carries a SCREEN location, which is what
    /// `GuideAutopilotTakeoverTerminalPanel.screenLocation(of:)` reads, so the
    /// panel's own tracking loop can be driven without seizing the machine's
    /// physical mouse (and without the Accessibility grant that posting real
    /// `CGEvent`s would need — the test runner does not have one:
    /// `AXIsProcessTrusted()` is false inside it).
    private static func mouseEvent(_ type: NSEvent.EventType, atScreenPoint point: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    /// Press, drag in 15 steps, release. The drag and release are queued FIRST,
    /// because `sendEvent` on the mouse-down does not return until the gesture
    /// is over — the panel pulls the rest of it out of the queue itself, which
    /// is exactly what a real tracking loop does.
    private static func postADragGesture(
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

    private static func postAClickWithoutMoving(to panel: NSPanel, atWindowPoint point: CGPoint) {
        let inScreen = CGPoint(x: panel.frame.minX + point.x, y: panel.frame.minY + point.y)
        if let released = mouseEvent(.leftMouseUp, atScreenPoint: inScreen) {
            NSApp.postEvent(released, atStart: false)
        }
        if let pressed = mouseEvent(.leftMouseDown, atScreenPoint: inScreen) {
            panel.sendEvent(pressed)
        }
    }


    @Test func irisLeavesTheTerminalWhereTheReaderPutIt() async throws {
        let takeover = try await Self.raiseTakeover()
        defer { takeover.dismiss() }
        takeover.controller.parkForManualStep(
            title: "Install Rust", instruction: "Download rustup and run it."
        )
        try await Self.settle()

        // The reader drags the terminal out of the way of the download button.
        // A real background drag ends exactly here: a new frame origin.
        let whereTheReaderPutIt = CGPoint(x: 120, y: 120)
        takeover.terminal.setFrameOrigin(whereTheReaderPutIt)
        let readerTopLeft = CGPoint(
            x: takeover.terminal.frame.minX, y: takeover.terminal.frame.maxY
        )

        // THE CONTRACT: once the reader has moved the window, Iris's own frame
        // animations may still resize it, but they must leave its top-left
        // corner where the reader dropped it. Top-left rather than AppKit's
        // bottom-left origin because that is the corner the reader aimed at:
        // parking shrinks the window from 480pt tall to 340pt, and anchoring
        // the bottom would slide the visible card 140pt up the screen on its
        // own. ("Must not reposition at all" also satisfies this test.)
        takeover.controller.returnToCenter()
        try await Self.settle()
        #expect(
            CGPoint(x: takeover.terminal.frame.minX, y: takeover.terminal.frame.maxY)
                == readerTopLeft,
            "returning to center must not yank the terminal out of the place the reader chose"
        )

        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Self.settle()
        #expect(
            CGPoint(x: takeover.terminal.frame.minX, y: takeover.terminal.frame.maxY)
                == readerTopLeft,
            "parking for the next manual step must not yank it back either"
        )
    }

    @Test func theParkedTerminalDoesNotCoverTheBrowserDownloadButton() async throws {
        let screen = try #require(NSScreen.main ?? NSScreen.screens.first)
        let takeover = try await Self.raiseTakeover()
        defer { takeover.dismiss() }
        takeover.controller.parkForManualStep(
            title: "Install CMake", instruction: "Download the CMake .dmg and drag it in."
        )
        try await Self.settle()

        // Where Chrome, Safari, Firefox and Arc all keep the download chip:
        // the right end of the toolbar, at the top of the window — and a
        // browser the reader is downloading an installer in is normally the
        // full working area. Sized from the measurements in the file comment
        // (a 220x90 toolbar cluster, plus a little slack).
        let visible = screen.visibleFrame
        let whereEveryBrowserKeepsItsDownloadButton = CGRect(
            x: visible.maxX - 240, y: visible.maxY - 120, width: 240, height: 120
        )

        #expect(
            takeover.terminal.frame.intersects(whereEveryBrowserKeepsItsDownloadButton) == false,
            """
            the parked terminal \(takeover.terminal.frame) sits on the browser's download \
            button \(whereEveryBrowserKeepsItsDownloadButton) — the one control the step is \
            telling the reader to click, on a window they cannot move
            """
        )
    }
}
