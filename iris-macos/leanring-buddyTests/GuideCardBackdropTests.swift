//
//  GuideCardBackdropTests.swift
//  leanring-buddyTests
//
//  The guide card's backdrop has to stay dark enough to read white text on.
//
//  This is pinned because it has already failed twice in one day. First the card
//  shipped with no backdrop at all, drawn straight onto the reader's desktop —
//  which does not read as translucent, it reads as a rendering fault. Then it
//  was given the panel surface, which is the right answer for the menu bar
//  dropdown and the wrong one for a surface that floats over a white browser
//  window.
//
//  A colour is easy to nudge and the consequence is invisible on a dark
//  wallpaper, which is exactly the kind of regression a test should hold.
//

import AppKit
import Foundation
import SwiftUI
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct GuideCardBackdropTests {

    /// Contrast of white text over `backdrop` composited on pure white — the
    /// worst case the card actually meets in the wild, a maximised browser.
    private func contrastOfWhiteTextOverBackdropOnWhite(_ backdrop: Color) -> Double {
        let resolved = NSColor(backdrop).usingColorSpace(.sRGB)!
        let alpha = Double(resolved.alphaComponent)

        func channelOverWhite(_ component: Double) -> Double {
            // `component` over a white page, at this alpha.
            let composited = component * alpha + 1.0 * (1 - alpha)
            return composited <= 0.03928
                ? composited / 12.92
                : pow((composited + 0.055) / 1.055, 2.4)
        }

        let luminance =
            0.2126 * channelOverWhite(Double(resolved.redComponent))
            + 0.7152 * channelOverWhite(Double(resolved.greenComponent))
            + 0.0722 * channelOverWhite(Double(resolved.blueComponent))

        // White text is luminance 1.0.
        return (1.0 + 0.05) / (luminance + 0.05)
    }

    @Test func theCardStaysLegibleOverAWhiteWindow() {
        let contrast = contrastOfWhiteTextOverBackdropOnWhite(DS.Colors.readableOverAnything)
        // WCAG AA for body text. The backdrop blur underneath only helps from
        // here, so this is the floor rather than the expected reading.
        #expect(contrast >= 4.5)
    }

    /// It is still glass. A fully opaque card would pass the contrast check and
    /// lose the thing that makes the eye feel like it is sitting on the screen
    /// rather than blocking it.
    @Test func theCardIsStillTranslucent() {
        let alpha = Double(NSColor(DS.Colors.readableOverAnything).usingColorSpace(.sRGB)!.alphaComponent)
        #expect(alpha < 0.95)
        #expect(alpha > 0.5)
    }

    /// The menu bar panel keeps its own surface. It sits over Iris's own chrome,
    /// not over the reader's work, and darkening it would be a visual change
    /// nobody asked for.
    @Test func theMenuBarPanelKeepsItsOwnSurface() {
        let panel = NSColor(DS.Colors.surface).usingColorSpace(.sRGB)!
        let card = NSColor(DS.Colors.readableOverAnything).usingColorSpace(.sRGB)!
        #expect(panel.alphaComponent != card.alphaComponent)
    }
}
