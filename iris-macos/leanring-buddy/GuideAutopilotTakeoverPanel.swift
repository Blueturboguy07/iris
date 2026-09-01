//
//  GuideAutopilotTakeoverPanel.swift
//  leanring-buddy
//
//  The centered "takeover" the autopilot runs its install in. When the reader
//  taps "Let Iris run it", the eye flies to the middle of the screen and the
//  install stops being a small pane tucked under the guide card in the corner:
//  a dim backdrop drops over the desktop and the eye MORPHS into a real macOS
//  Terminal window at the center — growing out of the eye's spot while the eye
//  fades and shrinks into it — runs the whole install there, then folds back
//  into the eye when it is done. It is the Swift port of the Windows renderer's
//  eye→terminal→eye morph (iris-windows/src/renderer/autopilot), which is the
//  agreed spec.
//
//  Why its own windows, not the overlay: the full-screen eye overlay is
//  click-through everywhere except the eye's own gate (see OverlayWindow), so it
//  cannot host the terminal's Run-it / Your-turn buttons. This mirrors the input
//  bar's pattern instead — a small non-activating panel that DOES take clicks —
//  with a second, click-through backdrop panel behind it for the dim. The
//  terminal content is GuideAutopilotTerminalView verbatim; only where it is
//  shown changes.
//

import AppKit
import Combine
import SwiftUI

/// The one bit of state the morph reads: which face the stage is showing. The
/// controller flips it and both the SwiftUI cross-fade and the AppKit window
/// grow animate to match, so the two read as a single morph.
@MainActor
final class GuideAutopilotTakeoverModel: ObservableObject {
    @Published var showsTerminalFace: Bool = false
    /// True while the takeover is parked on a manual step. Shows the
    /// "I did it — continue" control so the reader is never stranded on a step
    /// the watch loop cannot confirm (a permission grant, a sign-in), now that
    /// the corner guide card with its own Continue button is hidden mid-takeover.
    @Published var readerMustManuallyContinue: Bool = false
    /// What the reader has to do at the parked step, shown above the button so
    /// they are never guessing (e.g. "Allow screen and microphone access").
    @Published var manualStepTitle: String = ""
    @Published var manualStepInstruction: String = ""
}

/// The controller that owns the two panels and drives the morph in and out.
@MainActor
final class GuideAutopilotTakeoverController {
    private var backdropPanel: NSPanel?
    private var terminalPanel: NSPanel?
    private var model: GuideAutopilotTakeoverModel?

    /// The parked step's text, held so a park deferred during the entry morph
    /// (a manual first step) applies the same instruction once it settles.
    private var pendingManualTitle = ""
    private var pendingManualInstruction = ""

    /// The two frames the terminal window animates between: eye-sized (the
    /// morph's start/end) and terminal-sized (where the install runs). Held so
    /// the collapse can reverse the exact grow.
    private var eyeSizedFrame: CGRect = .zero
    private var terminalSizedFrame: CGRect = .zero

    /// A collapse is a chain of timed steps; a second dismiss must not start a
    /// second chain on top of it.
    private var isDismissing = false

    /// Parked = the terminal has slid to a corner and shrunk, and the dim is
    /// lifted, so the reader can see and reach a manual step's control on their
    /// own screen while the eye drifts to point at it. It returns to the center
    /// the moment Iris runs the next command.
    private var isParked = false

    /// A park asked for before the entry morph finished — a guide whose very
    /// first step is manual. Applied once the morph settles so the grow and the
    /// park do not fight over the same window frame.
    private var entryMorphHasSettled = false
    private var aParkWasRequestedDuringEntry = false

    /// Where the terminal sits while parked (bottom-right corner). Held so a park
    /// requested during the entry morph can be applied unchanged once it settles.
    private var parkedFrame: CGRect = .zero

    /// Where the READER dragged the terminal to, as a top-left point, or nil
    /// while they have never touched it. Reported: "the terminal Iris is using
    /// is not movable at all" — and moving it was only half the complaint,
    /// because every park and return-to-center calls `setFrame` with Iris's own
    /// geometry, so a window the reader had just dragged clear of the download
    /// button was yanked straight back the moment the next step began.
    ///
    /// THE CONTRACT: once the reader has placed it, Iris may still RESIZE the
    /// window (the parked card is 400x340, the running one 760x480 — freezing
    /// it at the small size for the rest of an install would just be the next
    /// complaint) but the top-left corner stays where they dropped it. Top-left
    /// rather than AppKit's bottom-left origin because that is the corner they
    /// aimed at: anchoring the bottom would slide the visible card 140pt up the
    /// screen on the very next resize, all by itself.
    private var readerPlacedTheTerminalTopLeft: CGPoint?

    /// The size the READER dragged the card to, or nil while they have never
    /// resized it. Reported, in one flat sentence: "You cannot resize the
    /// terminal tab."
    ///
    /// THE SAME CONTRACT THE DRAGGED POSITION GETS. Once they have chosen a
    /// size, Iris keeps it: parking no longer shrinks the card to 400x340 and
    /// returning to center no longer grows it to 760x480, because a window that
    /// snaps back to Iris's idea of the right size on the next step is not
    /// really resizable — that is exactly the complaint the moved-position
    /// latch was added for, one property along. Iris still MOVES it (a park
    /// slides it to the corner unless the reader has placed it), and the
    /// fold-back-into-the-eye collapse still shrinks it to eye size, because
    /// that one is an animation ending in the window going away rather than a
    /// size anybody has to live with.
    private var readerChoseTheTerminalSize: CGSize?

    /// Set while one of Iris's OWN frame animations is running. `didMove` fires
    /// for every intermediate frame of an animated `setFrame` exactly as it does
    /// for a drag, so without this the morph, the park, and the collapse would
    /// each record themselves as "the reader moved it". A count rather than a
    /// flag because the entry morph and a park deferred behind it can overlap.
    private var irisOwnFrameAnimationsInFlight = 0

    /// The `didMove` subscription on the terminal panel, kept so it dies with
    /// the panels rather than outliving them.
    private var terminalDidMoveObserver: NSObjectProtocol?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let morphDuration: TimeInterval = 0.5
    private static let morphTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    var isPresented: Bool { terminalPanel != nil }

    /// Bring up the takeover: dim the desktop, and morph the eye into the
    /// centered terminal that `runner` streams the work into.
    ///
    /// Generic over the presenter so the SAME morph hosts either a guide's
    /// `GuideAutopilotRunner` or an on-demand edit's `OnDemandEditRunner`. The
    /// guide-only callbacks (`onReaderFinishedManualStep`, the risky-command
    /// gate) are simply never triggered by the edit runner, which has no manual
    /// steps and no per-command confirm loop.
    func present<Runner: AutopilotTerminalPresenting>(
        runner: Runner,
        onApproveRiskyCommand: @escaping () -> Void,
        onSkipRiskyCommand: @escaping () -> Void,
        onRetrySurfacedStep: @escaping () -> Void,
        onContinuePastSurfacedStep: @escaping () -> Void,
        onReaderFinishedManualStep: @escaping () -> Void,
        onEscapeHatch: @escaping () -> Void
    ) {
        // Already up (e.g. a resumed run) — never stack a second takeover.
        guard terminalPanel == nil, !isDismissing else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        isDismissing = false

        let takeoverModel = GuideAutopilotTakeoverModel()
        self.model = takeoverModel

        eyeSizedFrame = Self.eyeSizedFrame(on: screen)
        terminalSizedFrame = Self.terminalSizedFrame(on: screen)
        parkedFrame = Self.parkedFrame(on: screen)
        isParked = false
        entryMorphHasSettled = false
        aParkWasRequestedDuringEntry = false
        readerPlacedTheTerminalTopLeft = nil
        readerChoseTheTerminalSize = nil
        irisOwnFrameAnimationsInFlight = 0

        // The dim backdrop. Click-through on purpose: a manual sub-step (a
        // download, a drag) still needs the reader to reach the app underneath.
        let backdrop = Self.makeChromelessPanel(frame: screen.frame)
        backdrop.ignoresMouseEvents = true
        backdrop.contentView = NSHostingView(rootView: GuideAutopilotTakeoverBackdrop())
        backdrop.alphaValue = 0
        backdrop.orderFrontRegardless()
        self.backdropPanel = backdrop

        // The terminal window. Starts eye-sized so it can grow out of the eye.
        // `GuideAutopilotTakeoverTerminalPanel` is the class that makes the CARD
        // draggable rather than just its 24pt title strip — see its own comment.
        let terminal = Self.makeChromelessPanel(
            frame: eyeSizedFrame, asA: GuideAutopilotTakeoverTerminalPanel.self
        )
        terminal.ignoresMouseEvents = false
        // "The terminal Iris is using is not movable at all." It was true: a
        // `.borderless` panel has no title bar to grab, and this is the only
        // drag path AppKit offers without one. The settings panel already made
        // exactly this fix for exactly this complaint (`MenuBarPanelManager`,
        // "I can't move shit around"), against the same NSHostingView content,
        // so the mechanism is known to work here. The backdrop deliberately
        // does NOT get it — it ignores mouse events and is the whole screen.
        //
        // It is kept ON TOP of the panel subclass, not replaced by it: it is
        // what carries a drag that starts on the parts of the card AppKit is
        // already happy to move (the title strip, the manual-step bar), and it
        // costs nothing where the subclass has taken the gesture over.
        terminal.isMovableByWindowBackground = true
        // "You cannot resize the terminal tab." Now they can, by its left,
        // right and bottom edges — and once they have, Iris keeps their size.
        terminal.onReaderResizedTheCard = { [weak self] sizeTheReaderChose in
            MainActor.assumeIsolated { self?.readerChoseTheTerminalSize = sizeTheReaderChose }
        }
        let takeoverView = GuideAutopilotTakeoverView(
            model: takeoverModel,
            runner: runner,
            onApproveRiskyCommand: onApproveRiskyCommand,
            onSkipRiskyCommand: onSkipRiskyCommand,
            onRetrySurfacedStep: onRetrySurfacedStep,
            onContinuePastSurfacedStep: onContinuePastSurfacedStep,
            onReaderFinishedManualStep: onReaderFinishedManualStep,
            onEscapeHatch: onEscapeHatch
        )
        let hostingView = NSHostingView(rootView: takeoverView)
        hostingView.autoresizingMask = [.width, .height]
        terminal.contentView = hostingView
        // Hover feedback for the resize, over the top of the SwiftUI content.
        // Without it the only way to discover the edges is to guess: the grip is
        // paint, the window is borderless, and nothing under the pointer ever
        // changed. It draws nothing and takes no clicks — it exists purely so
        // the pointer says "this edge moves" before the reader commits.
        let resizeCursorView = GuideAutopilotResizeCursorView(frame: hostingView.bounds)
        resizeCursorView.autoresizingMask = [.width, .height]
        hostingView.addSubview(resizeCursorView)
        terminal.orderFrontRegardless()
        self.terminalPanel = terminal

        // Remember wherever the reader leaves it. `didMove` cannot tell a drag
        // from an animated `setFrame`, so Iris's own motion is fenced off by
        // `irisOwnFrameAnimationsInFlight` rather than by inspecting the frame.
        terminalDidMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: terminal, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteWhereTheReaderPutTheTerminal() }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.35
            backdrop.animator().alphaValue = 1
        }

        if reduceMotion {
            setTerminalFrameOurselves(terminal, to: terminalSizedFrame)
            takeoverModel.showsTerminalFace = true
            entryMorphHasSettled = true
            if aParkWasRequestedDuringEntry {
                aParkWasRequestedDuringEntry = false
                parkForManualStep(title: pendingManualTitle, instruction: pendingManualInstruction)
            }
            return
        }

        // Let the eye read as "arrived" for a beat, then morph: grow the window
        // from the eye's spot to the terminal while the SwiftUI cross-fade swaps
        // the eye face for the terminal face — one motion, the eye becoming the
        // work.
        let centerFrame = terminalSizedFrame
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.terminalPanel === terminal else { return }
            self.irisOwnFrameAnimationsInFlight += 1
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.morphDuration
                context.timingFunction = Self.morphTiming
                terminal.animator().setFrame(centerFrame, display: true)
            }, completionHandler: { [weak self] in
                guard let self else { return }
                self.irisOwnFrameAnimationsInFlight = max(0, self.irisOwnFrameAnimationsInFlight - 1)
                guard self.terminalPanel === terminal else { return }
                // The morph has settled; a manual first step can now park the
                // window without fighting the grow it just finished.
                self.entryMorphHasSettled = true
                if self.aParkWasRequestedDuringEntry {
                    self.aParkWasRequestedDuringEntry = false
                    self.parkForManualStep(title: self.pendingManualTitle, instruction: self.pendingManualInstruction)
                }
            })
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: Self.morphDuration)) {
                takeoverModel.showsTerminalFace = true
            }
        }
    }

    /// Slide the terminal to the corner and shrink it, and lift the dim, so the
    /// reader can see and reach a manual step's control on their own screen while
    /// the eye drifts to point at it. Called when autopilot hands a manual step
    /// to the reader; `returnToCenter` reverses it when Iris runs the next
    /// command. Safe to call during the entry morph (it waits), and safe to call
    /// on an already-parked window: the SLIDE is idempotent, the TEXT is not —
    /// re-parking is how two manual steps in a row change what the card says.
    func parkForManualStep(title: String, instruction: String) {
        pendingManualTitle = title
        pendingManualInstruction = instruction
        guard let terminal = terminalPanel, !isDismissing else { return }
        // The very first step can be manual; if the entry morph is still growing
        // the window, defer until it settles so the two do not fight.
        guard entryMorphHasSettled else { aParkWasRequestedDuringEntry = true; return }

        // THE CONTENT IS NOT GUARDED. Reported: "when telling me to install
        // Cmake, the iris install terminal says Install rust, very confusing."
        // Two manual steps in a row never unpark in between — `drive()` only
        // calls `returnToCenter` on the branch that is about to RUN a command,
        // and a manual gate returns out of the loop before it — so the second
        // park hits `guard !isParked` below. That guard exists to keep the
        // WINDOW ANIMATION idempotent (re-running a 0.5s slide on an
        // already-parked window makes it twitch); it was never meant to decide
        // what the card SAYS, and the whimprflow guide's back-to-back
        // install-rust → install-cmake steps are exactly where it showed.
        model?.manualStepTitle = pendingManualTitle
        model?.manualStepInstruction = pendingManualInstruction
        model?.readerMustManuallyContinue = true
        irisTrace("takeover: PARKED + set readerMustManuallyContinue=true, showsTerminalFace=\(model?.showsTerminalFace == true), title=\(pendingManualTitle)")

        // From here down is the window animation, and only that.
        guard !isParked else { return }
        isParked = true
        let backdrop = backdropPanel
        let cornerFrame = frameHonoringWhereTheReaderPutTheTerminal(parkedFrame)
        if reduceMotion {
            setTerminalFrameOurselves(terminal, to: cornerFrame)
            backdrop?.alphaValue = 0
            return
        }
        irisOwnFrameAnimationsInFlight += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.morphDuration
            context.timingFunction = Self.morphTiming
            terminal.animator().setFrame(cornerFrame, display: true)
            backdrop?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.irisOwnFrameAnimationsInFlight = max(0, self.irisOwnFrameAnimationsInFlight - 1)
        })
    }

    /// Bring the terminal back to the center and restore the dim — the reader
    /// finished the manual step and Iris is about to run the next command. A
    /// no-op unless the terminal is actually parked.
    func returnToCenter() {
        aParkWasRequestedDuringEntry = false
        guard let terminal = terminalPanel, !isDismissing, isParked else { return }
        isParked = false
        model?.readerMustManuallyContinue = false
        let backdrop = backdropPanel
        let centerFrame = frameHonoringWhereTheReaderPutTheTerminal(terminalSizedFrame)
        if reduceMotion {
            setTerminalFrameOurselves(terminal, to: centerFrame)
            backdrop?.alphaValue = 1
            return
        }
        irisOwnFrameAnimationsInFlight += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.morphDuration
            context.timingFunction = Self.morphTiming
            terminal.animator().setFrame(centerFrame, display: true)
            backdrop?.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.irisOwnFrameAnimationsInFlight = max(0, self.irisOwnFrameAnimationsInFlight - 1)
        })
    }

    // MARK: - Leaving the terminal where the reader put it

    /// Called from `NSWindow.didMoveNotification`, but only counts while none of
    /// Iris's own frame animations are running — those post the same
    /// notification for every frame they interpolate.
    private func noteWhereTheReaderPutTheTerminal() {
        guard irisOwnFrameAnimationsInFlight == 0, !isDismissing, let terminal = terminalPanel else {
            return
        }
        readerPlacedTheTerminalTopLeft = CGPoint(x: terminal.frame.minX, y: terminal.frame.maxY)
    }

    /// Iris's own geometry, re-hung from the corner the reader chose and resized
    /// to the size they chose. Until they touch the window this returns the
    /// frame unchanged, so nothing about the default choreography changes.
    ///
    /// `honoringTheirSize: false` is the collapse: the fold back into the eye
    /// has to reach eye size or there is no morph.
    private func frameHonoringWhereTheReaderPutTheTerminal(
        _ irisChosenFrame: CGRect, honoringTheirSize: Bool = true
    ) -> CGRect {
        let size = (honoringTheirSize ? readerChoseTheTerminalSize : nil) ?? irisChosenFrame.size
        guard let readerTopLeft = readerPlacedTheTerminalTopLeft else {
            // They have resized it but never moved it: keep Iris's placement,
            // re-hung from the top-left so a taller card grows downward rather
            // than lifting off the corner it was parked in.
            guard size != irisChosenFrame.size else { return irisChosenFrame }
            return CGRect(
                x: irisChosenFrame.minX,
                y: irisChosenFrame.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }
        return CGRect(
            x: readerTopLeft.x,
            y: readerTopLeft.y - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// An unanimated frame change made BY IRIS — bracketed so the `didMove` it
    /// posts is not mistaken for the reader dragging the window.
    private func setTerminalFrameOurselves(_ terminal: NSPanel, to frame: CGRect) {
        irisOwnFrameAnimationsInFlight += 1
        terminal.setFrame(frame, display: true)
        irisOwnFrameAnimationsInFlight = max(0, irisOwnFrameAnimationsInFlight - 1)
    }

    /// Fold the terminal back into the eye and tear the panels down. `afterHold`
    /// leaves the finished terminal on screen a moment first (so "✓ All done"
    /// registers). `thenRun` fires once everything is gone — the caller uses it
    /// to open the freshly installed app, so the app appears as the eye returns
    /// rather than over the terminal.
    func dismiss(afterHold: Bool, thenRun: (() -> Void)? = nil) {
        // Nothing to fold away — still honor the follow-up so completion work
        // (open the app, refresh the list) runs for a manual, non-autopilot guide.
        guard terminalPanel != nil else { thenRun?(); return }
        // A collapse already in flight owns the teardown; don't start a second.
        guard !isDismissing else { return }
        isDismissing = true

        let hold: TimeInterval = afterHold && !reduceMotion ? 1.8 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            self?.collapseAndClose(thenRun: thenRun)
        }
    }

    private func collapseAndClose(thenRun: (() -> Void)?) {
        guard let terminal = terminalPanel else {
            isDismissing = false
            thenRun?()
            return
        }

        if reduceMotion {
            tearDownPanels()
            isDismissing = false
            thenRun?()
            return
        }

        // Reverse of the morph: terminal shrinks back into the eye face. It
        // shrinks in place if the reader moved the window — flying it back to
        // the screen centre to fold away would be one last yank.
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: Self.morphDuration)) {
            model?.showsTerminalFace = false
        }
        irisOwnFrameAnimationsInFlight += 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.morphDuration
            context.timingFunction = Self.morphTiming
            terminal.animator().setFrame(
                frameHonoringWhereTheReaderPutTheTerminal(
                    eyeSizedFrame, honoringTheirSize: false
                ),
                display: true
            )
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.irisOwnFrameAnimationsInFlight = max(0, self.irisOwnFrameAnimationsInFlight - 1)
            // Fade the eye + backdrop out, then remove the windows.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.terminalPanel?.animator().alphaValue = 0
                self.backdropPanel?.animator().alphaValue = 0
            }, completionHandler: {
                self.tearDownPanels()
                self.isDismissing = false
                thenRun?()
            })
        })
    }

    private func tearDownPanels() {
        if let terminalDidMoveObserver {
            NotificationCenter.default.removeObserver(terminalDidMoveObserver)
            self.terminalDidMoveObserver = nil
        }
        for panel in [terminalPanel, backdropPanel] {
            panel?.orderOut(nil)
            panel?.contentView = nil
        }
        terminalPanel = nil
        backdropPanel = nil
        model = nil
        isParked = false
        entryMorphHasSettled = false
        aParkWasRequestedDuringEntry = false
        // The reader's placement and size belong to the run they made them in;
        // the next takeover opens at Iris's own geometry again.
        readerPlacedTheTerminalTopLeft = nil
        readerChoseTheTerminalSize = nil
        irisOwnFrameAnimationsInFlight = 0
    }

    // MARK: - Geometry

    /// The eye's resting size at the center of the screen — the morph's endpoint.
    private static func eyeSizedFrame(on screen: NSScreen) -> CGRect {
        let side: CGFloat = 132
        return CGRect(
            x: screen.frame.midX - side / 2,
            y: screen.frame.midY - side / 2,
            width: side, height: side
        )
    }

    /// The terminal window's size at the center of the screen, clamped so it
    /// always leaves a margin of desktop showing around it.
    private static func terminalSizedFrame(on screen: NSScreen) -> CGRect {
        let width = min(760, screen.frame.width - 120)
        let height = min(480, screen.frame.height - 160)
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.midY - height / 2,
            width: width, height: height
        )
    }

    /// The parked position: a small window tucked into the BOTTOM-right, still
    /// big enough to keep the last commands and the running cursor readable,
    /// while the rest of the screen is clear for the reader to act on the
    /// control the eye is pointing at.
    ///
    /// It used to be the TOP-right, and that is the corner every browser keeps
    /// its download chip in. Reported: "it is not at all useable right now
    /// because it covers where the download symbol is" — measured on this Mac,
    /// the parked window (1088, 580, 400, 340) overlapped Safari's and
    /// Firefox's toolbar right cluster by 216x96pt. A manual step is very often
    /// "download this installer", so Iris was parking on the one control it had
    /// just told the reader to click.
    ///
    /// Bottom-right rather than either left corner: the top-right also holds
    /// notifications and Control Center, and the left edge is where a
    /// left-hand Dock lives (this Mac's `visibleFrame` starts at x=34 for
    /// exactly that reason), so bottom-right is the only corner clear of all
    /// three. The eye still flies to whatever the step points at, so nothing
    /// about the pointing depends on which corner this is.
    private static func parkedFrame(on screen: NSScreen) -> CGRect {
        let width: CGFloat = 400
        let height: CGFloat = 340
        let margin: CGFloat = 24
        return CGRect(
            x: screen.visibleFrame.maxX - width - margin,
            y: screen.visibleFrame.minY + margin,
            width: width, height: height
        )
    }

    /// The takeover's window level. `.floating` deliberately, NOT
    /// `.screenSaver`: the takeover must pop up above every ordinary window
    /// (it is the progress surface of a menu-bar app with no windows of its
    /// own) but must never sit above SYSTEM dialogs — at `.screenSaver`
    /// (level 1000) the full-screen dim scrim covered macOS permission
    /// prompts, so a TCC ask fired mid-run (a relaunched edited build
    /// requesting Accessibility, an installed app's first launch) rendered
    /// invisibly BEHIND the dim and read as a hang. `.floating` (level 3)
    /// keeps the pop-to-front behavior while alerts, modal panels, and TCC
    /// prompts (all higher) land on top where the reader can answer them.
    static let takeoverWindowLevel: NSWindow.Level = .floating

    /// A borderless, non-activating, all-Spaces floating panel — the same shape
    /// the input bar uses, so the takeover behaves like the rest of Iris's
    /// chrome (never steals focus, rides above full-screen apps).
    private static func makeChromelessPanel(frame: CGRect) -> NSPanel {
        makeChromelessPanel(frame: frame, asA: NSPanel.self)
    }

    /// The same panel, built as a specific `NSPanel` subclass — the terminal
    /// needs `GuideAutopilotTakeoverTerminalPanel`'s drag behaviour, the
    /// click-through backdrop deliberately does not.
    private static func makeChromelessPanel<Panel: NSPanel>(
        frame: CGRect, asA panelClass: Panel.Type
    ) -> Panel {
        let panel = Panel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = takeoverWindowLevel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

// MARK: - Making the whole card draggable, not just its title strip

/// The takeover terminal's own window class, and the only thing in Iris that
/// moves a window out from under AppKit's own rules.
///
/// WHY IT EXISTS. `isMovableByWindowBackground` is the documented way to drag a
/// borderless window, and it is not enough here. AppKit only starts that drag
/// when the view under the press answers `true` to `mouseDownCanMoveWindow`,
/// and SwiftUI backs every selectable `Text` with an `NSTextField`/`NSTextView`
/// that answers `false`. Measured on a structural replica of the parked card
/// (400x340: a 24pt title strip, the transcript, the manual-step bar), posting
/// real `CGEvent` drags of (-150, +60) and reading the window frame back:
///
///     grab                     hit view at mouse-down     result
///     title strip              NSHostingView              MOVED
///     transcript, top          DocumentView               DID NOT MOVE
///     transcript, middle       SelectionTextField         DID NOT MOVE
///     transcript, left gutter  SelectionTextField         DID NOT MOVE
///
/// The transcript is 65% of the parked card and 95% of the running one, so
/// "draggable" meant a 24pt strip with nothing on screen naming it as a handle.
/// The reader's words were "the terminal Iris is using is not movable at all"
/// and "please make the terminal movable" — a strip they will never find does
/// not answer that.
///
/// HOW IT WORKS. The press is HELD rather than dispatched, and what the reader
/// does next decides who gets it:
///
///   - the pointer travels past `theSlopAClickIsAllowed` → this window owns the
///     rest of the gesture and moves itself, one `setFrameOrigin` per dragged
///     event. It never asks `mouseDownCanMoveWindow`, which is the whole point.
///   - the button comes back up first → it was a CLICK, not a drag. The
///     mouse-up is pushed back to the front of the queue and the held mouse-down
///     is re-sent, so the view underneath sees an untouched click and behaves
///     exactly as it did before: buttons fire, and a double- or triple-click
///     still selects a word or a line in the transcript.
///
/// WHAT THIS COSTS, stated plainly: click-and-DRAG to select a range of
/// transcript text now moves the window instead of selecting. That is a real
/// trade and it is deliberate — the reported bug is a window the reader cannot
/// get off the download button they are being told to click, and every other
/// way of copying output survives (double-click a word, triple-click a line,
/// right-click → Copy, and the wheel still scrolls because only
/// `.leftMouseDown` is ever intercepted).
final class GuideAutopilotTakeoverTerminalPanel: NSPanel {

    /// How far the pointer must travel before this stops being a click and
    /// starts being a drag. Small enough that a deliberate drag is picked up
    /// immediately, large enough that the hand-shake in a real click is not.
    private static let theSlopAClickIsAllowed: CGFloat = 3

    /// A mouse held down for this long without moving is not a gesture anyone
    /// is waiting on; the loop lets go rather than owning the main thread
    /// forever. It then replays the press as an ordinary click.
    private static let longestAGestureIsWatched: TimeInterval = 30

    /// True only while a held-back click is being re-sent, so the re-send is
    /// not caught and held a second time.
    private var isReplayingAClickItHeldOnTo = false

    /// The card's title strip — the 24pt band the red escape hatch lives in.
    private static let heightOfTheTitleStrip: CGFloat = 24

    // MARK: - Resizing ("You cannot resize the terminal tab.")

    /// How close to an edge a press has to land to mean "resize" instead of
    /// "move". A real window's resize border is about this wide.
    static let theGripAlongTheEdges: CGFloat = 7

    /// How far into the bottom-right corner a press still takes hold of BOTH
    /// edges. Deliberately wider than the edge band, for two reasons.
    ///
    /// The first is that the only thing on screen that says "this window
    /// resizes" is the painted grip, and it did not fit inside a 7pt band: it is
    /// an 11pt glyph inset 4pt from each edge (`GuideAutopilotResizeGrip`, laid
    /// out at `.bottomTrailing` with `.padding(4)`), so its ink runs from 4pt to
    /// 15pt in and its CENTRE — where anybody aiming at a handle aims — sat 9.5pt
    /// in, outside the band. MEASURED before this change: a real gesture posted
    /// at (width - 9.5, 9.5) MOVED the card instead of resizing it. A reader who
    /// aims at the one affordance drawn for them got the wrong behaviour, which
    /// is indistinguishable from "you cannot resize the terminal tab".
    ///
    /// The second is that a corner is what a person actually grabs to resize a
    /// window, and every real Mac window gives it a bigger target than its
    /// edges. 16pt covers the whole glyph with a point to spare.
    static let theCornerGripSquare: CGFloat = 16

    /// The smallest the reader may make the card. Below this the transcript is
    /// too narrow to read a command on and the manual-step bar has nowhere to
    /// put its button — which would be a new way to strand somebody, not a
    /// smaller window.
    static let smallestTheCardMayBeMade = CGSize(width: 300, height: 200)

    /// The reader let go of a resize, at this size. The controller listens so it
    /// can keep their size for the rest of the run, the same courtesy the
    /// dragged-to POSITION already gets.
    var onReaderResizedTheCard: ((CGSize) -> Void)?

    /// Which edges a press takes hold of, or an empty set for a press that is
    /// somewhere in the body and therefore a move.
    struct EdgesUnderThePress: OptionSet {
        let rawValue: Int
        static let left = EdgesUnderThePress(rawValue: 1 << 0)
        static let right = EdgesUnderThePress(rawValue: 1 << 1)
        static let bottom = EdgesUnderThePress(rawValue: 1 << 2)
    }

    /// THE TOP EDGE IS NOT A RESIZE HANDLE, deliberately. The title strip is
    /// only 24pt tall and the red escape hatch sits inside it — a 7pt band
    /// across the top would turn the top of the close button into a resize
    /// grip, and "you can't close out of it" is a sentence this window has
    /// already earned once. Left, right and bottom are plenty: between them
    /// they reach every dimension, and the left edge stands down under the
    /// title strip for the same reason.
    static func edgesUnderThePress(
        at pointInWindow: CGPoint, forACardOfSize size: CGSize
    ) -> EdgesUnderThePress {
        // A card at or under the minimum can still be made BIGGER, so the grip
        // stays live at every size.
        guard size.width > theGripAlongTheEdges * 3,
              size.height > heightOfTheTitleStrip + theGripAlongTheEdges * 2 else {
            return []
        }
        var edges: EdgesUnderThePress = []
        let isBesideTheTitleStrip = pointInWindow.y > size.height - heightOfTheTitleStrip
        // The bottom-right corner first, because it is the one the grip is
        // painted in and it must take hold of both edges at once — see
        // `theCornerGripSquare`.
        if pointInWindow.y <= theCornerGripSquare,
           pointInWindow.x >= size.width - theCornerGripSquare,
           !isBesideTheTitleStrip {
            return [.bottom, .right]
        }
        if pointInWindow.y <= theGripAlongTheEdges { edges.insert(.bottom) }
        if pointInWindow.x >= size.width - theGripAlongTheEdges, !isBesideTheTitleStrip {
            edges.insert(.right)
        }
        if pointInWindow.x <= theGripAlongTheEdges, !isBesideTheTitleStrip {
            edges.insert(.left)
        }
        return edges
    }

    /// The frame a resize lands on: the grabbed edges follow the pointer, the
    /// opposite ones stay exactly where they are, and nothing goes below the
    /// minimum. Pure, so the whole geometry is testable without a gesture.
    ///
    /// The edge keeps the offset it had from the pointer when it was grabbed,
    /// which is the same self-correcting trick the MOVE uses (`whereTheReader
    /// TookHold`): snapping the edge onto the pointer instead would jump the
    /// card by however many points inside the 7pt grip the press landed, before
    /// the reader had moved at all.
    static func frameResized(
        from startingFrame: CGRect,
        by edges: EdgesUnderThePress,
        pointerAtThePress: CGPoint,
        pointerNow: CGPoint
    ) -> CGRect {
        var frame = startingFrame
        let travelled = CGPoint(
            x: pointerNow.x - pointerAtThePress.x, y: pointerNow.y - pointerAtThePress.y
        )
        if edges.contains(.right) {
            frame.size.width = max(
                smallestTheCardMayBeMade.width, startingFrame.width + travelled.x
            )
        }
        if edges.contains(.left) {
            // The RIGHT edge is the anchor, so the origin moves with the width.
            let rightEdge = startingFrame.maxX
            frame.size.width = max(
                smallestTheCardMayBeMade.width, startingFrame.width - travelled.x
            )
            frame.origin.x = rightEdge - frame.size.width
        }
        if edges.contains(.bottom) {
            // The TOP edge is the anchor: the reader is dragging the bottom of
            // a card whose title strip must not walk up the screen under them.
            let topEdge = startingFrame.maxY
            frame.size.height = max(
                smallestTheCardMayBeMade.height, startingFrame.height - travelled.y
            )
            frame.origin.y = topEdge - frame.size.height
        }
        return frame
    }

    /// How much of the card's width has to stay on a screen. Enough to hold the
    /// three traffic lights and be grabbed again.
    private static let narrowestSliverThatStaysReachable: CGFloat = 72

    /// Clamps a dragged origin so the card can be pushed almost anywhere but
    /// never off the edge of every display.
    ///
    /// Before this change the reader could only drag from a 24pt strip; now the
    /// whole card is a handle, so it is that much easier to shove the thing
    /// clean off the screen — and the reader's OTHER sentence about this window
    /// was "you can't close out of it". The red escape hatch is in the title
    /// strip, so the title strip is what is kept reachable: fully on a display
    /// vertically, and at least `narrowestSliverThatStaysReachable` of it
    /// horizontally. An ordinary drag never comes near these bounds.
    static func keepingTheTitleStripReachable(
        _ proposedOrigin: CGPoint, forACardOfSize size: CGSize
    ) -> CGPoint {
        let everywhereTheReaderCanSee = NSScreen.screens
            .map(\.visibleFrame)
            .reduce(CGRect.null) { $0.union($1) }
        guard !everywhereTheReaderCanSee.isNull, !everywhereTheReaderCanSee.isEmpty else {
            return proposedOrigin
        }

        let leftmost = everywhereTheReaderCanSee.minX - size.width + narrowestSliverThatStaysReachable
        let rightmost = everywhereTheReaderCanSee.maxX - narrowestSliverThatStaysReachable
        // The strip sits at the TOP of the card, so its band in AppKit's
        // bottom-left coordinates runs from `origin.y + height - 24` upwards.
        let lowest = everywhereTheReaderCanSee.minY + heightOfTheTitleStrip - size.height
        let highest = everywhereTheReaderCanSee.maxY - size.height
        return CGPoint(
            x: min(max(proposedOrigin.x, leftmost), max(leftmost, rightmost)),
            y: min(max(proposedOrigin.y, lowest), max(lowest, highest))
        )
    }

    /// Where inside the window the press landed. Window-relative by definition
    /// for a real event; an event carrying no window carries a SCREEN location
    /// instead (see `screenLocation(of:)`), so that one is converted.
    static func grabOffsetInWindow(of mouseDown: NSEvent, in window: NSWindow) -> CGPoint {
        guard mouseDown.window == nil else { return mouseDown.locationInWindow }
        return CGPoint(
            x: mouseDown.locationInWindow.x - window.frame.minX,
            y: mouseDown.locationInWindow.y - window.frame.minY
        )
    }

    /// Where a mouse event happened, in screen coordinates.
    ///
    /// An event that belongs to a window carries a window-relative location, and
    /// this window MOVES underneath the gesture, so converting that back would
    /// chase its own tail — the live pointer is the honest answer. An event with
    /// no window (`NSEvent.mouseEvent(with:location:… window: nil …)`) already
    /// carries a screen location by definition, and reading it is what lets a
    /// test drive this exact loop with a posted gesture instead of seizing the
    /// machine's physical mouse.
    static func screenLocation(of event: NSEvent) -> CGPoint {
        event.window == nil ? event.locationInWindow : NSEvent.mouseLocation
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .leftMouseDown,
              !isReplayingAClickItHeldOnTo,
              // A control-click is the context menu, not a drag. Leave it be.
              !event.modifierFlags.contains(.control),
              let contentView,
              // A scrollbar is the one control whose whole job IS the drag, so
              // it is the one place the window must not take the gesture.
              // Buttons need no exception: a click on one is replayed intact.
              !(contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
                  is NSScroller)
        else {
            super.sendEvent(event)
            return
        }

        // An edge grip is a RESIZE, and it is checked before the move because
        // the whole card is a drag handle — without this, the one gesture every
        // reader tries for a window that is the wrong size would just slide it
        // ("You cannot resize the terminal tab."). It is handled here rather
        // than by AppKit's own `.resizable` border for the same reason the move
        // is: this panel holds every left mouse-down for its own tracking loop,
        // so a border drag would never survive to reach AppKit.
        let edgesUnderThePress = Self.edgesUnderThePress(
            at: Self.grabOffsetInWindow(of: event, in: self), forACardOfSize: frame.size
        )
        if !edgesUnderThePress.isEmpty {
            theGestureResizedTheCard(startingFrom: event, by: edgesUnderThePress)
            return
        }

        if theGestureTurnedOutToBeADrag(startingFrom: event) { return }

        // It was a click, and the mouse-up has already been pushed back to the
        // head of the queue, so the view's own tracking loop finds it waiting
        // the moment this re-sent mouse-down reaches it.
        isReplayingAClickItHeldOnTo = true
        super.sendEvent(event)
        isReplayingAClickItHeldOnTo = false
    }

    /// Runs a resize the same way `theGestureTurnedOutToBeADrag` runs a move:
    /// this window pulls the rest of the gesture out of the queue itself,
    /// because a view that received the mouse-down would run its own loop and
    /// swallow every dragged event before `sendEvent` saw another one.
    ///
    /// No slop here, unlike the move. A press that lands on a 7pt edge is a
    /// resize the moment it lands — that is how every other window on the Mac
    /// behaves, and a resize of zero costs the reader nothing.
    private func theGestureResizedTheCard(
        startingFrom mouseDown: NSEvent, by edges: EdgesUnderThePress
    ) {
        let frameAtThePress = frame
        let whereTheReaderTookHold = Self.grabOffsetInWindow(of: mouseDown, in: self)
        let pointerAtThePress = CGPoint(
            x: frameAtThePress.minX + whereTheReaderTookHold.x,
            y: frameAtThePress.minY + whereTheReaderTookHold.y
        )
        let giveUpAt = Date().addingTimeInterval(Self.longestAGestureIsWatched)
        var theReaderActuallyResizedIt = false

        while true {
            guard let nextEventInTheGesture = NSApp.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: giveUpAt,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            if nextEventInTheGesture.type == .leftMouseUp { break }

            let resized = Self.frameResized(
                from: frameAtThePress,
                by: edges,
                pointerAtThePress: pointerAtThePress,
                pointerNow: Self.screenLocation(of: nextEventInTheGesture)
            )
            if resized != frame {
                theReaderActuallyResizedIt = true
                setFrame(resized, display: true)
            }
        }

        // Only a resize that changed something counts as the reader choosing a
        // size. A stray press on the edge must not freeze the card at whatever
        // size Iris happened to have it at.
        if theReaderActuallyResizedIt {
            onReaderResizedTheCard?(frame.size)
        }
    }

    /// Watches the gesture the held mouse-down opened. Returns true if it became
    /// a drag (and the window has already been moved and the gesture consumed),
    /// false if it was a click that still needs delivering.
    ///
    /// This is an AppKit tracking loop, the same shape `NSButton` and
    /// `NSTextView` run while the mouse is down: it pulls the rest of the
    /// gesture out of the queue itself. It must, because a `SelectionTextField`
    /// that received the mouse-down would run ITS loop and swallow every
    /// dragged event before `sendEvent` could see another one.
    private func theGestureTurnedOutToBeADrag(startingFrom mouseDown: NSEvent) -> Bool {
        // Where in the CARD the reader took hold of it. The window has not moved
        // yet, so this is exact — and holding the grab OFFSET rather than a
        // start position is what makes the drag self-correcting: every frame
        // simply puts that spot back under the pointer, so a coalesced or
        // late-delivered event can never leave the card lagging the hand.
        let whereTheReaderTookHold = Self.grabOffsetInWindow(of: mouseDown, in: self)
        let whereThePointerWasAtThePress = CGPoint(
            x: frame.minX + whereTheReaderTookHold.x, y: frame.minY + whereTheReaderTookHold.y
        )
        var theWindowIsFollowingThePointer = false
        let giveUpAt = Date().addingTimeInterval(Self.longestAGestureIsWatched)

        while true {
            guard let nextEventInTheGesture = NSApp.nextEvent(
                matching: [.leftMouseUp, .leftMouseDragged],
                until: giveUpAt,
                inMode: .eventTracking,
                dequeue: true
            ) else {
                // Timed out with the button still down. Treat it as a click so
                // the press is not simply lost.
                return theWindowIsFollowingThePointer
            }

            if nextEventInTheGesture.type == .leftMouseUp {
                if theWindowIsFollowingThePointer { return true }
                NSApp.postEvent(nextEventInTheGesture, atStart: true)
                return false
            }

            let pointerNow = Self.screenLocation(of: nextEventInTheGesture)
            let travelled = CGPoint(
                x: pointerNow.x - whereThePointerWasAtThePress.x,
                y: pointerNow.y - whereThePointerWasAtThePress.y
            )
            if !theWindowIsFollowingThePointer,
               hypot(travelled.x, travelled.y) >= Self.theSlopAClickIsAllowed {
                theWindowIsFollowingThePointer = true
            }
            if theWindowIsFollowingThePointer {
                setFrameOrigin(
                    Self.keepingTheTitleStripReachable(
                        CGPoint(
                            x: pointerNow.x - whereTheReaderTookHold.x,
                            y: pointerNow.y - whereTheReaderTookHold.y
                        ),
                        forACardOfSize: frame.size
                    )
                )
            }
        }
    }
}

// MARK: - The dim backdrop

/// The scrim behind the terminal. A flat dim with a soft center vignette so the
/// eye is drawn to the middle where the terminal grows.
private struct GuideAutopilotTakeoverBackdrop: View {
    var body: some View {
        RadialGradient(
            colors: [Color.black.opacity(0.34), Color.black.opacity(0.62)],
            center: .center,
            startRadius: 120,
            endRadius: 900
        )
        .ignoresSafeArea()
    }
}

// MARK: - The morphing stage (eye ⇄ terminal)

/// The stage that holds both faces and cross-fades between them, exactly like
/// the Windows renderer's `.stage`/`.stage.as-terminal`. The window itself grows
/// and shrinks around this (driven by the controller), so the scale here is only
/// the finishing touch on a morph the window size is doing most of.
private struct GuideAutopilotTakeoverView<Runner: AutopilotTerminalPresenting>: View {
    @ObservedObject var model: GuideAutopilotTakeoverModel
    @ObservedObject var runner: Runner
    let onApproveRiskyCommand: () -> Void
    let onSkipRiskyCommand: () -> Void
    let onRetrySurfacedStep: () -> Void
    let onContinuePastSurfacedStep: () -> Void
    /// The reader tapped "I did it — continue" on a manual step Iris parked on
    /// (a permission grant, a sign-in) that has no watch signal to auto-advance.
    let onReaderFinishedManualStep: () -> Void
    /// The red traffic light — closes the takeover, whatever Iris is doing.
    let onEscapeHatch: () -> Void

    var body: some View {
        ZStack {
            GuideAutopilotTakeoverEye()
                .frame(width: 96, height: 96)
                .opacity(model.showsTerminalFace ? 0 : 1)
                .scaleEffect(model.showsTerminalFace ? 0.5 : 1)

            GuideAutopilotTerminalView(
                runner: runner,
                onApproveRiskyCommand: onApproveRiskyCommand,
                onSkipRiskyCommand: onSkipRiskyCommand,
                onRetrySurfacedStep: onRetrySurfacedStep,
                onContinuePastSurfacedStep: onContinuePastSurfacedStep,
                onEscapeHatch: onEscapeHatch,
                // The takeover window is a fixed frame; the transcript fills it.
                fixedTranscriptHeight: nil
            )
            .shadow(color: Color.black.opacity(0.55), radius: 40, x: 0, y: 18)
            .opacity(model.showsTerminalFace ? 1 : 0)
            .scaleEffect(model.showsTerminalFace ? 1 : 0.94)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // Parked on a manual step: some steps (a TCC permission, a sign-in)
            // have no signal Iris can read, so the reader does the thing and
            // tells it. A solid bar drawn on top of the terminal's bottom (a
            // safeAreaInset collapses to nothing in this hosted panel), naming
            // the step so the reader is never lost.
            if model.readerMustManuallyContinue && model.showsTerminalFace {
                VStack(spacing: 7) {
                    if !model.manualStepTitle.isEmpty {
                        Text(model.manualStepTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.manualStepInstruction.isEmpty {
                        Text(model.manualStepInstruction)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("I did it — continue", action: onReaderFinishedManualStep)
                        .irisPrimaryPill(isFullWidth: true, isCompact: true)
                        .padding(.top, 2)
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.11, green: 0.11, blue: 0.13))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The affordance for the resize the panel implements. A borderless
            // window shows nothing at its edges, and a handle nobody can see is
            // the same to a reader as no handle at all — which is how "You
            // cannot resize the terminal tab" survived a window that was always
            // going to need to be a different size on somebody's screen.
            //
            // `allowsHitTesting(false)`: the grip is paint. The geometry lives
            // in `GuideAutopilotTakeoverTerminalPanel.edgesUnderThePress`, which
            // sees the press before any view does.
            if model.showsTerminalFace {
                GuideAutopilotResizeGrip()
                    .frame(width: 11, height: 11)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The pointer feedback for the resize: a transparent, click-through view that
/// does nothing but publish cursor rectangles over the same bands
/// `GuideAutopilotTakeoverTerminalPanel.edgesUnderThePress` reads.
///
/// It is a plain `NSView` rather than anything in SwiftUI because cursor
/// rectangles belong to AppKit's window machinery, and because the press itself
/// is intercepted in `sendEvent` before any view sees it — so the feedback and
/// the behaviour have to be described in the same coordinates twice, from the
/// one set of constants, and NOT by hit-testing.
///
/// `hitTest` returns nil so this never takes a click; cursor rectangles are
/// computed from the view's geometry by the window, not by hit-testing, so the
/// two do not conflict.
final class GuideAutopilotResizeCursorView: NSView {

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        typealias Panel = GuideAutopilotTakeoverTerminalPanel
        let band = Panel.theGripAlongTheEdges
        let corner = Panel.theCornerGripSquare
        // This view's own coordinates are the window's content coordinates, and
        // both are bottom-left origin — the same space `edgesUnderThePress`
        // measures in — so the rectangles below are that function drawn out.
        let size = bounds.size
        guard size.width > band * 3, size.height > corner * 2 else { return }

        addCursorRect(
            NSRect(x: 0, y: corner, width: band, height: size.height - corner - 24),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: size.width - band, y: corner,
                   width: band, height: size.height - corner - 24),
            cursor: .resizeLeftRight
        )
        addCursorRect(
            NSRect(x: band, y: 0, width: size.width - corner - band, height: band),
            cursor: .resizeUpDown
        )
        addCursorRect(
            NSRect(x: size.width - corner, y: 0, width: corner, height: corner),
            cursor: Self.theCornerCursor
        )
    }

    /// The diagonal corner cursor when the OS has one to give (macOS 15+), and
    /// the honest horizontal fallback when it does not. Never a crosshair: this
    /// resizes a window, it does not pick a point.
    private static var theCornerCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return NSCursor.frameResize(position: .bottomRight, directions: .all)
        }
        return .resizeLeftRight
    }
}

/// Three short diagonals in the bottom-right corner — the shape every Mac
/// window has used to say "this edge moves" for thirty years.
private struct GuideAutopilotResizeGrip: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let side = min(geometry.size.width, geometry.size.height)
                for inset in stride(from: side, through: side / 3, by: -side / 3) {
                    path.move(to: CGPoint(x: side - inset, y: side))
                    path.addLine(to: CGPoint(x: side, y: side - inset))
                }
            }
            .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}

/// The Iris eye, transcribed from the Windows renderer's inline SVG (the almond
/// stroke, the striated-less iris, the off-center glint) so the two platforms'
/// morphs open on the same face. Kept self-contained rather than reusing the
/// overlay's eye, which is wired to gaze and pointing state this stage does not
/// have.
private struct GuideAutopilotTakeoverEye: View {
    @State private var isBreathing = false

    private static let ink = Color(red: 0.902, green: 0.902, blue: 0.918)
    private static let glowBlue = Color(red: 0.490, green: 0.827, blue: 0.988)
    private static let glintDark = Color(red: 0.086, green: 0.086, blue: 0.102)

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Self.glowBlue.opacity(0.55), Self.glowBlue.opacity(0)],
                            center: .center, startRadius: 0, endRadius: side * 0.55
                        )
                    )
                    .frame(width: side * 1.15, height: side * 1.15)

                AlmondEyeShape()
                    .stroke(Self.ink, style: StrokeStyle(lineWidth: side * 0.055, lineJoin: .round))
                    .frame(width: side, height: side)

                Circle()
                    .fill(Self.ink)
                    .frame(width: side * 0.283, height: side * 0.283)

                Circle()
                    .fill(Self.glintDark)
                    .frame(width: side * 0.075, height: side * 0.075)
                    .offset(x: side * 0.05, y: -side * 0.05)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(isBreathing ? 1.06 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
        }
    }
}

/// The eye's almond outline, matching the renderer path
/// `M12 60 Q60 18 108 60 Q60 102 12 60 Z` on a 120-unit box, scaled to the view.
private struct AlmondEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 120 * width, y: rect.minY + y / 120 * height)
        }
        var path = Path()
        path.move(to: point(12, 60))
        path.addQuadCurve(to: point(108, 60), control: point(60, 18))
        path.addQuadCurve(to: point(12, 60), control: point(60, 102))
        path.closeSubpath()
        return path
    }
}
