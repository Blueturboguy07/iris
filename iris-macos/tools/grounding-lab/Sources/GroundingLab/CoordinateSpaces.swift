//
//  CoordinateSpaces.swift
//  grounding-lab
//
//  THE most important file in this tool. Every arm looks equally bad when a
//  coordinate space conversion is wrong, so all of them are written down here
//  and performed in exactly one place.
//
//  There are four spaces in play on macOS, and three different origins:
//
//  1. GLOBAL ACCESSIBILITY POINTS — what `AXPosition` / `AXSize` return.
//     Units: points. Origin: TOP-LEFT of the primary display. Y grows DOWNWARD.
//     This is the same space as `CGDisplayBounds`, which is why the walker and
//     the display geometry can be compared without any flip.
//
//  2. GLOBAL APPKIT POINTS — what `NSScreen.frame` and `NSEvent.mouseLocation`
//     use. Units: points. Origin: BOTTOM-LEFT of the primary display. Y grows
//     UPWARD. This tool touches AppKit geometry for exactly one thing —
//     `backingScaleFactor` — and deliberately never mixes AppKit rects with AX
//     rects. The shipping app (`OverlayWindow.swift`) does need this space; the
//     lab does not, so it is not converted to anywhere in here.
//
//  3. DISPLAY-LOCAL POINTS — global accessibility points with the captured
//     display's origin subtracted. Units: points. Origin: TOP-LEFT of the
//     captured display. Y grows DOWNWARD.
//     *** This is the canonical space of `dataset.json` and of all scoring. ***
//     Everything a model predicts is converted into this space before it is
//     compared with anything.
//
//  4. SCREENSHOT PIXELS — what ScreenCaptureKit actually writes into the PNG.
//     Units: PIXELS, not points. On a Retina display these are 2x the point
//     dimensions. The dataset records `backingScaleFactor` so a reader can get
//     back to points; nothing in the scoring path ever works in pixels.
//
//  The one conversion that produced a real bug during development is
//  `modelResolutionPointToDisplayLocalPoint` below — see its comment.
//

import CoreGraphics
import Foundation

/// A rectangle that survives a round trip through JSON. Deliberately not
/// `CGRect`, so that a rect read out of `dataset.json` cannot be silently
/// mixed with an AppKit rect somewhere else.
struct RectInPoints: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var centerX: Double { x + width / 2.0 }
    var centerY: Double { y + height / 2.0 }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(cgRect: CGRect) {
        self.init(
            x: Double(cgRect.origin.x),
            y: Double(cgRect.origin.y),
            width: Double(cgRect.size.width),
            height: Double(cgRect.size.height)
        )
    }

    var asCGRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func containsPoint(x pointX: Double, y pointY: Double, paddedBy padding: Double) -> Bool {
        pointX >= (x - padding)
            && pointX <= (x + width + padding)
            && pointY >= (y - padding)
            && pointY <= (y + height + padding)
    }

    /// Fraction of this rectangle's area that overlaps `other`, relative to the
    /// smaller of the two. Used only for deduplication.
    func overlapFraction(with other: RectInPoints) -> Double {
        let intersection = asCGRect.intersection(other.asCGRect)
        if intersection.isNull || intersection.isEmpty { return 0 }
        let intersectionArea = Double(intersection.width * intersection.height)
        let smallerArea = min(width * height, other.width * other.height)
        guard smallerArea > 0 else { return 0 }
        return intersectionArea / smallerArea
    }
}

/// A single point in display-local points (space 3 above).
struct PointInPoints: Codable, Equatable {
    var x: Double
    var y: Double

    func distance(to other: PointInPoints) -> Double {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}

enum CoordinateSpaces {

    /// Space 1 -> space 3. The ONLY place a global accessibility rect becomes a
    /// dataset rect. Both spaces are top-left-origin points, so this is a pure
    /// translation with no Y flip — a flip here would mirror every target
    /// vertically and make every arm look equally broken.
    static func displayLocalRect(
        fromGlobalAccessibilityRect globalRect: CGRect,
        displayBoundsInGlobalPoints displayBounds: CGRect
    ) -> RectInPoints {
        RectInPoints(
            x: Double(globalRect.origin.x - displayBounds.origin.x),
            y: Double(globalRect.origin.y - displayBounds.origin.y),
            width: Double(globalRect.size.width),
            height: Double(globalRect.size.height)
        )
    }

    /// The conversion most likely to be silently wrong, and the one this tool
    /// mirrors deliberately from `iris-macos/leanring-buddy/ElementLocationDetector.swift`.
    ///
    /// Claude's Computer Use tool answers in the pixel space of the image it was
    /// shown, whose dimensions we declared in the tool definition. That space is
    /// TOP-LEFT origin, exactly like display-local points, so the conversion is a
    /// pure uniform rescale with NO Y flip.
    ///
    /// The upstream detector does one extra step that this tool must NOT copy:
    /// after rescaling it computes `displayHeight - y` to hand AppKit a
    /// bottom-left-origin point for the cursor overlay (space 2). The lab scores
    /// against accessibility rects, which are top-left-origin, so applying that
    /// flip here would mirror every prediction about the display's horizontal
    /// midline.
    ///
    /// This is not theoretical. `results.json` records every raw model
    /// coordinate, so both interpretations can be scored offline from one real
    /// Finder run of 8 answered targets:
    ///
    ///     top-left (what this function does)     6/8 hits, median error   4.5pt
    ///     bottom-left flip (upstream cursor)     0/8 hits, median error 531.3pt
    ///
    /// A wrong flip here does not look like a bug — it looks like a model that
    /// cannot point, which is exactly the wrong conclusion to draw.
    static func modelResolutionPointToDisplayLocalPoint(
        modelPoint: CGPoint,
        modelResolutionWidth: Int,
        modelResolutionHeight: Int,
        displayWidthInPoints: Double,
        displayHeightInPoints: Double
    ) -> PointInPoints {
        // Claude occasionally answers a pixel or two outside the declared
        // resolution; clamp exactly as the shipping detector does.
        let clampedX = max(0, min(Double(modelPoint.x), Double(modelResolutionWidth)))
        let clampedY = max(0, min(Double(modelPoint.y), Double(modelResolutionHeight)))

        let scaledX = (clampedX / Double(modelResolutionWidth)) * displayWidthInPoints
        let scaledY = (clampedY / Double(modelResolutionHeight)) * displayHeightInPoints

        // No `displayHeight - scaledY` here. See the comment above.
        return PointInPoints(x: scaledX, y: scaledY)
    }

    /// Space 3 -> space 4, for drawing overlays onto the captured PNG.
    static func screenshotPixel(
        fromDisplayLocalPoint point: PointInPoints,
        backingScaleFactor: Double
    ) -> CGPoint {
        CGPoint(x: point.x * backingScaleFactor, y: point.y * backingScaleFactor)
    }
}
