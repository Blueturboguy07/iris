import Testing
#if canImport(IrisUsability)
@testable import IrisUsability
#else
@testable import Iris
#endif

struct IrisGlassSurfacePolicyTests {
    @Test func normalAppearanceKeepsGlassAndMotion() {
        let policy = IrisGlassSurfacePolicy.resolve(
            reduceTransparency: false, increaseContrast: false, reduceMotion: false
        )

        #expect(policy.usesBackdropMaterial)
        #expect(policy.usesDecorativeHighlights)
        #expect(policy.animationsAreEnabled)
        #expect(policy.pressedScale < 1)
        #expect(!policy.usesSolidSurfaceFallback)
    }

    @Test func reducedTransparencyUsesSolidAccessibleSurface() {
        let policy = IrisGlassSurfacePolicy.resolve(
            reduceTransparency: true, increaseContrast: false, reduceMotion: false
        )

        #expect(!policy.usesBackdropMaterial)
        #expect(!policy.usesDecorativeHighlights)
        #expect(policy.usesSolidSurfaceFallback)
        #expect(policy.shellHighlightOpacity == 0)
        #expect(policy.controlHighlightOpacity == 0)
    }

    @Test func contrastAndMotionPreferencesRemainIndependent() {
        let policy = IrisGlassSurfacePolicy.resolve(
            reduceTransparency: false, increaseContrast: true, reduceMotion: true
        )

        #expect(policy.usesSolidSurfaceFallback)
        #expect(policy.shellBorderOpacity == 0.28)
        #expect(policy.controlBorderOpacity == 0.30)
        #expect(policy.animationsAreEnabled == false)
        #expect(policy.pressedScale == 1.0)
    }
}
