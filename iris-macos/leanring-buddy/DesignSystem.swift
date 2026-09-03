//
//  DesignSystem.swift
//  leanring-buddy
//
//  Iris's design system. Every token here is transcribed from the Tauri pill's
//  stylesheet (`iris-desktop/ui/styles.css`), which is the visual spec for
//  Iris on every platform: a near-black glass surface, one periwinkle accent,
//  ink-on-white primary buttons, and small, tight typography. If a value here
//  disagrees with styles.css, styles.css wins.
//

import SwiftUI
import AppKit

// MARK: - Design System Namespace

/// The top-level namespace for all design system tokens.
/// Usage: `DS.Colors.ink`, `DS.Colors.accent`, etc.
enum DS {

    // MARK: - Color Tokens (from iris-desktop/ui/styles.css :root)

    enum Colors {

        // ── Surfaces ─────────────────────────────────────────────────
        // Iris is one dark glass sheet, not stacked cards. Elevation is
        // done with translucent white overlays, exactly like the CSS
        // (--surface-raised / --surface-hover), so layers pick up the
        // surface underneath instead of drifting toward a different hue.

        /// The shell fill: `--surface: rgba(14, 14, 16, 0.94)`.
        /// Slightly translucent so the backdrop blur reads through.
        static let surface = Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255).opacity(0.94)

        /// For a surface that floats over whatever the reader happens to have
        /// open, rather than over Iris's own chrome.
        ///
        /// Deliberately still translucent — this is glass, and seeing the shape
        /// of what is behind it is the point. But translucency here is a
        /// contrast problem, not just a look: the guide card sits over the
        /// reader's real screen, which is often a white browser window, and
        /// `textPrimary` is near-white.
        ///
        /// 0.86 of black is the floor that keeps white text legible against a
        /// pure white background — around 5:1, comfortably past WCAG AA for body
        /// text — and the backdrop blur underneath only ever helps from there.
        /// Lower numbers look better on a dark wallpaper and become unreadable
        /// on a light one, which is how the card shipped invisible.
        static let readableOverAnything = Color.black.opacity(0.86)

        /// The same shell color fully opaque, for contexts that cannot
        /// composite over a blur (the overlay bubble, fallbacks).
        static let background = Color(hex: "#0E0E10")

        /// `--surface-raised: rgba(255,255,255,0.065)` — inputs, tiny buttons.
        static let surfaceRaised = Color.white.opacity(0.065)

        /// `--surface-hover: rgba(255,255,255,0.1)` — hover fill on raised elements.
        static let surfaceHover = Color.white.opacity(0.1)

        /// Pressed fill, one step past hover.
        static let surfacePressed = Color.white.opacity(0.14)

        // ── Lines ────────────────────────────────────────────────────

        /// `--line: rgba(255,255,255,0.09)` — hairlines, input borders.
        static let line = Color.white.opacity(0.09)

        /// `--line-strong: rgba(255,255,255,0.16)` — focused/hovered borders.
        static let lineStrong = Color.white.opacity(0.16)

        /// The shell's outer border: `rgba(255,255,255,0.12)`.
        static let shellBorder = Color.white.opacity(0.12)

        // ── Text ─────────────────────────────────────────────────────

        /// `--ink: #f7f7f8` — primary text.
        static let ink = Color(hex: "#F7F7F8")

        /// `--muted: rgba(247,247,248,0.56)` — body copy, descriptions.
        static let muted = ink.opacity(0.56)

        /// `--quiet: rgba(247,247,248,0.34)` — step counters, timestamps, hints.
        static let quiet = ink.opacity(0.34)

        /// Text on an ink-filled primary button: `.primary-action { color: #101013 }`.
        static let textOnInk = Color(hex: "#101013")

        /// Command block text: `rgba(255,255,255,0.88)`.
        static let commandText = Color.white.opacity(0.88)

        // ── Accent and semantic colors ───────────────────────────────

        /// `--accent: #6f8cff` — the one Iris accent. Indicators, progress,
        /// links, the eye's iris. Never a button fill (primary buttons are ink).
        static let accent = Color(hex: "#6F8CFF")

        /// `--accent-hover: #819aff`.
        static let accentHover = Color(hex: "#819AFF")

        /// `--green: #58d5a5` — success, watching, done.
        static let green = Color(hex: "#58D5A5")

        /// `--amber: #e9c96f` — caution, setup recovery, pending states.
        static let amber = Color(hex: "#E9C96F")

        /// `--red: #ff737d` — errors, destructive actions.
        static let red = Color(hex: "#FF737D")

        // ── The eye ──────────────────────────────────────────────────

        /// The eye's shell (`.iris-eye__shell`).
        static let eyeShell = Color(hex: "#111217")

        /// The eyeball/lid fill (`.iris-eye__lid`).
        static let eyeLid = Color(hex: "#F6F7FB")

        /// The pupil (`.iris-eye__pupil`).
        static let eyePupil = Color(hex: "#090A0D")

        /// The satellite dot's ring (`.iris-eye__satellite` border).
        static let eyeSatelliteRing = Color(hex: "#151519")

        // ── Compatibility aliases ────────────────────────────────────
        // Older call sites use clicky's names. They resolve to Iris values
        // so no view can render the old palette by accident.

        static let textPrimary = ink
        static let textSecondary = muted
        static let textTertiary = quiet
        static let textOnAccent = textOnInk
        static let borderSubtle = line
        static let borderStrong = lineStrong
        static let surface1 = Color.white.opacity(0.045)
        static let surface2 = surfaceRaised
        static let surface3 = surfaceHover
        static let surface4 = surfacePressed
        static let success = green
        static let warning = amber
        static let warningText = amber
        static let destructive = red
        static let destructiveText = red
        static let accentText = accent
        static let accentSubtle = accent.opacity(0.14)
        static let codeText = commandText
        static let info = accent

        /// The pointing cursor on the screen overlay is the Iris accent —
        /// the same periwinkle as the eye's iris, so the thing flying around
        /// the screen is recognizably a piece of Iris.
        static let overlayCursorBlue = accent

        // ── Disabled State ───────────────────────────────────────────

        /// Disabled button/container background.
        static var disabledBackground: Color {
            ink.opacity(0.12)
        }

        /// Disabled text/icon color.
        static var disabledText: Color {
            ink.opacity(0.38)
        }
    }

    // MARK: - Spacing (for reference, not enforced)

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii (from styles.css)

    enum CornerRadius {
        /// Tiny buttons, tool marks (`.tiny-button` 8px).
        static let small: CGFloat = 8
        /// Primary action pills (`.primary-action` 11px).
        static let medium: CGFloat = 11
        /// Inputs, command blocks, cards (`.command-block` 12px).
        static let large: CGFloat = 12
        /// Sheets (`.settings-panel__sheet` 14px).
        static let extraLarge: CGFloat = 14
        /// The panel shell itself (`.app-shell` 16px).
        static let shell: CGFloat = 16
        /// Pill-shaped elements.
        static let pill: CGFloat = .infinity
    }

    // MARK: - Motion (from styles.css keyframes and transitions)

    enum Animation {
        /// Hover/state feedback (`transition: … 140ms ease`).
        static let fast: Double = 0.14
        /// Content entering (`content-in 180ms`).
        static let normal: Double = 0.18
        /// A step sliding in (`step-in 220ms`).
        static let slow: Double = 0.22
    }

    enum Motion {
        /// The Iris ease: `cubic-bezier(0.16, 1, 0.3, 1)` — fast out, long settle.
        static let contentIn = SwiftUI.Animation.timingCurve(0.16, 1, 0.3, 1, duration: Animation.normal)
        static let stepIn = SwiftUI.Animation.timingCurve(0.16, 1, 0.3, 1, duration: Animation.slow)
        static let quick = SwiftUI.Animation.easeOut(duration: Animation.fast)

        /// How new content arrives: fade up 5pt (`@keyframes content-in`).
        static let contentTransition = AnyTransition.opacity.combined(with: .offset(y: 5))

        /// How a step arrives: fade in from 5pt right (`@keyframes step-in`).
        static let stepTransition = AnyTransition.opacity.combined(with: .offset(x: 5))
    }
}

// MARK: - Iris Button Styles

/// The primary action: an ink-white pill with near-black text, exactly
/// `.primary-action` — hover brightens to pure white and lifts 1pt.
/// One per view maximum.
struct IrisPrimaryPillStyle: ButtonStyle {
    var isFullWidth: Bool = true
    /// Compact fits inline rows (Grant, Save); regular is the 36pt-tall CTA.
    var isCompact: Bool = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: isCompact ? 10 : 11, weight: .bold))
            .foregroundColor(DS.Colors.textOnInk)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .frame(minHeight: isCompact ? 24 : 36)
            .padding(.horizontal, isCompact ? 10 : 15)
            .background(
                RoundedRectangle(cornerRadius: isCompact ? DS.CornerRadius.small : DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovered ? Color.white : DS.Colors.ink)
            )
            .offset(y: isHovered && !configuration.isPressed ? -1 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }
}

/// `.tiny-button`: a small raised chip with a hairline border. Supporting
/// actions that sit inside rows — Copy, Pause, Sign out, Find App.
struct IrisTinyButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(DS.Colors.ink)
            .frame(minHeight: 24)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isHovered || configuration.isPressed ? DS.Colors.surfaceHover : DS.Colors.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .strokeBorder(DS.Colors.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }
}

/// `.text-button`: no background on any state; muted text that turns to ink.
struct IrisTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 9
    var isDanger: Bool = false

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                isDanger
                    ? (isHovered || configuration.isPressed ? DS.Colors.red : DS.Colors.red.opacity(0.72))
                    : (isHovered || configuration.isPressed ? DS.Colors.ink : DS.Colors.muted)
            )
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }
}

/// `.icon-button`: a 28pt quiet square that shows a soft fill on hover.
struct IrisIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundColor(isHovered || configuration.isPressed ? DS.Colors.ink : DS.Colors.muted)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered || configuration.isPressed ? DS.Colors.surfaceHover : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(DS.Motion.quick, value: configuration.isPressed)
            .animation(DS.Motion.quick, value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hovering in
                isHovered = hovering
            }
            .pointerCursor()
    }
}

// MARK: - Convenience View Extensions

extension View {
    /// The ink-filled primary pill (`.primary-action`).
    func irisPrimaryPill(isFullWidth: Bool = true, isCompact: Bool = false) -> some View {
        self.buttonStyle(IrisPrimaryPillStyle(isFullWidth: isFullWidth, isCompact: isCompact))
    }

    /// The small raised chip (`.tiny-button`).
    func irisTinyButton() -> some View {
        self.buttonStyle(IrisTinyButtonStyle())
    }

    /// The bare text button (`.text-button`).
    func irisTextButton(fontSize: CGFloat = 9, isDanger: Bool = false) -> some View {
        self.buttonStyle(IrisTextButtonStyle(fontSize: fontSize, isDanger: isDanger))
    }

    /// The quiet icon button (`.icon-button`).
    func irisIconButton(size: CGFloat = 28) -> some View {
        self.buttonStyle(IrisIconButtonStyle(size: size))
    }

    /// Attaches the shared pointing-hand cursor treatment used across interactive controls.
    /// Disabled controls can opt out so they keep the default arrow cursor.
    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

// MARK: - The Panel Shell

/// The Iris glass shell (`.app-shell`): a translucent near-black fill over a
/// backdrop blur, a periwinkle radial glow bleeding in from the top-left, a
/// hairline border, and a deep soft shadow. Every floating Iris surface wears
/// this — the menu bar panel today, the collapsed pill later.
struct IrisShellBackground: View {
    var cornerRadius: CGFloat = DS.CornerRadius.shell

    /// What sits between the blur and the content.
    ///
    /// The default is the near-opaque panel surface, which is right for the menu
    /// bar dropdown: it has the menu bar behind it and nothing else. A surface
    /// that floats over the reader's actual desktop needs a different answer —
    /// see `DS.Colors.readableOverAnything` — because the thing behind it might
    /// be a white browser window, and white text on 6% of white is not text.
    var surface: Color = DS.Colors.surface

    var body: some View {
        ZStack {
            PanelBackdropBlurView()

            Rectangle()
                .fill(surface)

            // radial-gradient(circle at 16% -20%, rgba(111,140,255,0.12), transparent 44%)
            RadialGradient(
                colors: [DS.Colors.accent.opacity(0.12), .clear],
                center: UnitPoint(x: 0.16, y: -0.2),
                startRadius: 0,
                endRadius: 260
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.Colors.shellBorder, lineWidth: 1)
        )
        // box-shadow: 0 22px 70px rgba(0,0,0,0.45)
        .shadow(color: Color.black.opacity(0.45), radius: 35, x: 0, y: 22)
        .shadow(color: Color.black.opacity(0.28), radius: 5, x: 0, y: 3)
    }
}

/// The `backdrop-filter: blur(30px)` behind the shell, via AppKit's
/// behind-window material since SwiftUI cannot blur what is behind a window.
private struct PanelBackdropBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Pointer Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show a pointing hand cursor.
/// More reliable than NSCursor.push()/pop() inside SwiftUI's .onHover because
/// cursor rects are managed at the window level and don't conflict with
/// SwiftUI's internal cursor handling.
private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - I-Beam Cursor (AppKit Bridge)

/// Uses AppKit's cursor rect system to reliably show an I-beam (text selection) cursor.
/// Same approach as PointerCursorView — cursor rects are managed at the window level
/// and don't conflict with SwiftUI's internal cursor handling.
/// Unlike NSCursor.push()/pop() in .onHover, this avoids cursor stack imbalance
/// when the mouse moves quickly between views.
private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    /// Pass through all mouse events so the TextField underneath still receives
    /// focus, clicks, and text selection. Cursor rects are registered with the
    /// window (via resetCursorRects) and work independently of hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Invalidate cursor rects when the view updates (e.g., resizes)
        // so AppKit recalculates the cursor area.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

// MARK: - Native Tooltip

/// Carries the tooltip string and nothing else. `.nativeTooltip(…)` stacks it
/// as an `.overlay` directly on top of whatever it decorates, and AppKit's
/// default `hitTest(_:)` returns a view for any point inside its own bounds —
/// so without this override the overlay claims the press, a plain `NSView`
/// does nothing with a `mouseDown`, and the SwiftUI `Button` underneath never
/// sees the click. That is why the takeover terminal's red escape hatch and
/// Help pill did nothing (cofounder Test 9 / Test 10): they are the only two
/// controls in that window carrying a tooltip, while the buttons beside them —
/// same panel, same dispatch — worked. Passing the press through is what
/// `PointerCursorNSView` and `IBeamCursorNSView` above do, for the same reason:
/// tooltip rects, like cursor rects, are registered with the window and work
/// independently of hit testing.
private class NativeTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NativeTooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

// MARK: - Color Utilities

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        // Convert to NSColor to access RGB components for blending
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
