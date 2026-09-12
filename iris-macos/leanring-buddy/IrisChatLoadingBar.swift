import SwiftUI
import AppKit
import QuartzCore

/// Mount only while work is pending, with wording from the real request state.
@MainActor
struct IrisChatLoadingBar: View {
    @Environment(\.accessibilityReduceMotion) private var readerAskedToReduceMotion

    let label: String

    init(label: String) {
        self.label = label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            IrisChatLoadingTrack(reduceMotion: readerAskedToReduceMotion)
                .frame(height: 3)
                .accessibilityHidden(true)

            Text(label)
                .font(DS.Typography.caption)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

private struct IrisChatLoadingTrack: NSViewRepresentable {
    let reduceMotion: Bool

    func makeNSView(context: Context) -> IrisChatLoadingTrackView {
        let view = IrisChatLoadingTrackView(frame: .zero)
        view.setReduceMotion(reduceMotion)
        return view
    }

    func updateNSView(_ nsView: IrisChatLoadingTrackView, context: Context) {
        // Label updates should not recreate or restart the compositor animation.
        nsView.setReduceMotion(reduceMotion)
    }
}

private final class IrisChatLoadingTrackView: NSView {
    private static let sweepAnimationKey = "irisChatLoadingSweep"
    private static let sweepDuration: CFTimeInterval = 1.6

    private let sweepLayer = CAGradientLayer()
    private var reduceMotion = false
    private var laidOutSize = CGSize.zero
    private var sweepWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()

        let size = bounds.size
        guard size != laidOutSize else { return }
        laidOutSize = size

        guard let trackLayer = layer, size.width > 0, size.height > 0 else {
            sweepWidth = 0
            return
        }

        trackLayer.cornerRadius = size.height / 2
        sweepWidth = max(24, size.width * 0.34)
        removeSweepAnimation()
        placeSweep(at: reduceMotion ? staticSweepOrigin(in: size.width) : -sweepWidth)

        if window != nil && !reduceMotion {
            startSweepAnimation()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            removeSweepAnimation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1

        guard window != nil else {
            removeSweepAnimation()
            return
        }

        if reduceMotion {
            showStaticSweep()
        } else {
            startSweepAnimation()
        }
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion

        guard window != nil else { return }
        if reduceMotion {
            showStaticSweep()
        } else {
            startSweepAnimation()
        }
    }

    private func configureLayers() {
        wantsLayer = true
        guard let trackLayer = layer else { return }

        trackLayer.backgroundColor = Self.accentColor(alpha: 0.18)
        trackLayer.masksToBounds = true
        trackLayer.drawsAsynchronously = true

        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.colors = [
            Self.accentColor(alpha: 0),
            Self.accentColor(alpha: 0.70),
            Self.accentColor(alpha: 0)
        ]
        sweepLayer.locations = [0, 0.5, 1]
        sweepLayer.masksToBounds = true
        trackLayer.addSublayer(sweepLayer)
    }

    private func startSweepAnimation() {
        guard window != nil, bounds.width > 0, bounds.height > 0, sweepWidth > 0 else { return }
        guard sweepLayer.animation(forKey: Self.sweepAnimationKey) == nil else { return }

        placeSweep(at: -sweepWidth)

        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = 0
        sweep.toValue = bounds.width + sweepWidth
        sweep.duration = Self.sweepDuration
        sweep.repeatCount = .greatestFiniteMagnitude
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.isRemovedOnCompletion = true
        sweepLayer.add(sweep, forKey: Self.sweepAnimationKey)
    }

    private func showStaticSweep() {
        removeSweepAnimation()
        guard bounds.width > 0, sweepWidth > 0 else { return }
        placeSweep(at: staticSweepOrigin(in: bounds.width))
    }

    private func removeSweepAnimation() {
        sweepLayer.removeAnimation(forKey: Self.sweepAnimationKey)
    }

    private func placeSweep(at originX: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweepLayer.frame = CGRect(
            x: originX,
            y: 0,
            width: sweepWidth,
            height: bounds.height
        )
        CATransaction.commit()
    }

    private func staticSweepOrigin(in trackWidth: CGFloat) -> CGFloat {
        max(0, (trackWidth - sweepWidth) / 2)
    }

    private static func accentColor(alpha: CGFloat) -> CGColor {
        let accent = NSColor(DS.Colors.accent).usingColorSpace(.sRGB) ?? .systemBlue
        return accent.withAlphaComponent(alpha).cgColor
    }
}

#Preview("Chat loading on bright and dark backdrops") {
    VStack(spacing: 0) {
        IrisChatLoadingBar(label: "Waiting for Iris to respond...")
            .padding(DS.Spacing.lg)
            .background(DS.Colors.readableOverAnything, in: RoundedRectangle(cornerRadius: 8))
            .padding(DS.Spacing.xl)
            .background(Color.white)

        IrisChatLoadingBar(label: "Assessing your request...")
            .padding(DS.Spacing.lg)
            .background(DS.Colors.readableOverAnything, in: RoundedRectangle(cornerRadius: 8))
            .padding(DS.Spacing.xl)
            .background(Color.black)
    }
    .frame(width: 380)
    .preferredColorScheme(.dark)
}
