import Foundation

/// Pure accessibility-aware appearance decisions for Iris's shared glass chrome.
/// SwiftUI/AppKit rendering stays in `DesignSystem.swift`; keeping the policy here
/// lets the reduced-transparency/contrast/motion rules be verified without a UI.
struct IrisGlassSurfacePolicy: Equatable, Sendable {
    let usesBackdropMaterial: Bool
    let usesDecorativeHighlights: Bool
    let shellBorderOpacity: Double
    let shellHighlightOpacity: Double
    let controlRestingFillOpacity: Double
    let controlHoverFillOpacity: Double
    let controlPressedFillOpacity: Double
    let controlBorderOpacity: Double
    let controlHighlightOpacity: Double
    let controlShadowOpacity: Double
    let primaryShadowOpacity: Double
    let pressedScale: Double
    let animationsAreEnabled: Bool

    var usesSolidSurfaceFallback: Bool {
        !usesBackdropMaterial
    }

    static func resolve(
        reduceTransparency: Bool,
        increaseContrast: Bool,
        reduceMotion: Bool
    ) -> IrisGlassSurfacePolicy {
        let usesSolidFallback = reduceTransparency || increaseContrast

        return IrisGlassSurfacePolicy(
            usesBackdropMaterial: !usesSolidFallback,
            usesDecorativeHighlights: !usesSolidFallback,
            shellBorderOpacity: increaseContrast ? 0.28 : (reduceTransparency ? 0.22 : 0.14),
            shellHighlightOpacity: usesSolidFallback ? 0 : 0.11,
            controlRestingFillOpacity: increaseContrast ? 0.14 : (reduceTransparency ? 0.11 : 0.065),
            controlHoverFillOpacity: increaseContrast ? 0.22 : (reduceTransparency ? 0.18 : 0.105),
            controlPressedFillOpacity: increaseContrast ? 0.28 : (reduceTransparency ? 0.23 : 0.15),
            controlBorderOpacity: increaseContrast ? 0.30 : (reduceTransparency ? 0.24 : 0.13),
            controlHighlightOpacity: usesSolidFallback ? 0 : 0.08,
            controlShadowOpacity: usesSolidFallback ? 0.10 : 0.18,
            primaryShadowOpacity: increaseContrast ? 0.08 : 0.16,
            pressedScale: reduceMotion ? 1.0 : 0.985,
            animationsAreEnabled: !reduceMotion
        )
    }
}
