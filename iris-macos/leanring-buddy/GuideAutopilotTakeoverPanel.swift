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
import SwiftUI

/// The one bit of state the morph reads: which face the stage is showing. The
/// controller flips it and both the SwiftUI cross-fade and the AppKit window
/// grow animate to match, so the two read as a single morph.
@MainActor
final class GuideAutopilotTakeoverModel: ObservableObject {
    @Published var showsTerminalFace: Bool = false
}

/// The controller that owns the two panels and drives the morph in and out.
@MainActor
final class GuideAutopilotTakeoverController {
    private var backdropPanel: NSPanel?
    private var terminalPanel: NSPanel?
    private var model: GuideAutopilotTakeoverModel?

    /// The two frames the terminal window animates between: eye-sized (the
    /// morph's start/end) and terminal-sized (where the install runs). Held so
    /// the collapse can reverse the exact grow.
    private var eyeSizedFrame: CGRect = .zero
    private var terminalSizedFrame: CGRect = .zero

    /// A collapse is a chain of timed steps; a second dismiss must not start a
    /// second chain on top of it.
    private var isDismissing = false

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let morphDuration: TimeInterval = 0.5
    private static let morphTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    var isPresented: Bool { terminalPanel != nil }

    /// Bring up the takeover: dim the desktop, and morph the eye into the
    /// centered terminal that `runner` streams the install into.
    func present(
        runner: GuideAutopilotRunner,
        onApproveRiskyCommand: @escaping () -> Void,
        onSkipRiskyCommand: @escaping () -> Void,
        onRetrySurfacedStep: @escaping () -> Void,
        onContinuePastSurfacedStep: @escaping () -> Void
    ) {
        // Already up (e.g. a resumed run) — never stack a second takeover.
        guard terminalPanel == nil, !isDismissing else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        isDismissing = false

        let takeoverModel = GuideAutopilotTakeoverModel()
        self.model = takeoverModel

        eyeSizedFrame = Self.eyeSizedFrame(on: screen)
        terminalSizedFrame = Self.terminalSizedFrame(on: screen)

        // The dim backdrop. Click-through on purpose: a manual sub-step (a
        // download, a drag) still needs the reader to reach the app underneath.
        let backdrop = Self.makeChromelessPanel(frame: screen.frame)
        backdrop.ignoresMouseEvents = true
        backdrop.contentView = NSHostingView(rootView: GuideAutopilotTakeoverBackdrop())
        backdrop.alphaValue = 0
        backdrop.orderFrontRegardless()
        self.backdropPanel = backdrop

        // The terminal window. Starts eye-sized so it can grow out of the eye.
        let terminal = Self.makeChromelessPanel(frame: eyeSizedFrame)
        terminal.ignoresMouseEvents = false
        let takeoverView = GuideAutopilotTakeoverView(
            model: takeoverModel,
            runner: runner,
            onApproveRiskyCommand: onApproveRiskyCommand,
            onSkipRiskyCommand: onSkipRiskyCommand,
            onRetrySurfacedStep: onRetrySurfacedStep,
            onContinuePastSurfacedStep: onContinuePastSurfacedStep
        )
        let hostingView = NSHostingView(rootView: takeoverView)
        hostingView.autoresizingMask = [.width, .height]
        terminal.contentView = hostingView
        terminal.orderFrontRegardless()
        self.terminalPanel = terminal

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.35
            backdrop.animator().alphaValue = 1
        }

        if reduceMotion {
            terminal.setFrame(terminalSizedFrame, display: true)
            takeoverModel.showsTerminalFace = true
            return
        }

        // Let the eye read as "arrived" for a beat, then morph: grow the window
        // from the eye's spot to the terminal while the SwiftUI cross-fade swaps
        // the eye face for the terminal face — one motion, the eye becoming the
        // work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.terminalPanel === terminal else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.morphDuration
                context.timingFunction = Self.morphTiming
                terminal.animator().setFrame(self.terminalSizedFrame, display: true)
            }
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: Self.morphDuration)) {
                takeoverModel.showsTerminalFace = true
            }
        }
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

        // Reverse of the morph: terminal shrinks back into the eye face.
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: Self.morphDuration)) {
            model?.showsTerminalFace = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.morphDuration
            context.timingFunction = Self.morphTiming
            terminal.animator().setFrame(eyeSizedFrame, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
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
        for panel in [terminalPanel, backdropPanel] {
            panel?.orderOut(nil)
            panel?.contentView = nil
        }
        terminalPanel = nil
        backdropPanel = nil
        model = nil
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

    /// A borderless, non-activating, all-Spaces floating panel — the same shape
    /// the input bar uses, so the takeover behaves like the rest of Iris's
    /// chrome (never steals focus, rides above full-screen apps).
    private static func makeChromelessPanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
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
private struct GuideAutopilotTakeoverView: View {
    @ObservedObject var model: GuideAutopilotTakeoverModel
    @ObservedObject var runner: GuideAutopilotRunner
    let onApproveRiskyCommand: () -> Void
    let onSkipRiskyCommand: () -> Void
    let onRetrySurfacedStep: () -> Void
    let onContinuePastSurfacedStep: () -> Void

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
                onContinuePastSurfacedStep: onContinuePastSurfacedStep
            )
            .shadow(color: Color.black.opacity(0.55), radius: 40, x: 0, y: 18)
            .opacity(model.showsTerminalFace ? 1 : 0)
            .scaleEffect(model.showsTerminalFace ? 1 : 0.94)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
