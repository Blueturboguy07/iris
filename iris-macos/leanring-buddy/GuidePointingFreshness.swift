import Foundation
import CoreGraphics

/// A point from an old screenshot must not become a confident arrow on a
/// different app or layout. This checks geometry, not whether a page scrolled.
nonisolated enum GuidePointingFreshness {
    static func explicitScreenNumberIsValid(_ screenNumber: Int?, captureCount: Int) -> Bool {
        guard captureCount > 0 else { return false }
        guard let screenNumber else { return true }
        return screenNumber >= 1 && screenNumber <= captureCount
    }

    static func pointIsInsideScreenshot(_ point: CGPoint, width: Int, height: Int) -> Bool {
        width > 0 && height > 0
            && point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.y >= 0
            && point.x < CGFloat(width) && point.y < CGFloat(height)
    }

    static func rectangleIfStillUsable(
        _ rectangle: CGRect,
        capturedApplication: String?,
        currentApplication: String?,
        capturedWindow: CGRect?,
        currentWindow: CGRect?,
        capturedDisplays: [CGRect],
        currentDisplays: [CGRect]
    ) -> CGRect? {
        guard capturedApplication == currentApplication,
              capturedDisplays == currentDisplays,
              rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              rectangle.width > 0, rectangle.height > 0 else { return nil }

        switch (capturedWindow, currentWindow) {
        case (nil, nil):
            return rectangle
        case (let capturedWindow?, let currentWindow?):
            let tolerance: CGFloat = 1
            guard abs(currentWindow.width - capturedWindow.width) <= tolerance,
                  abs(currentWindow.height - capturedWindow.height) <= tolerance else { return nil }
            let horizontalMovement = currentWindow.minX - capturedWindow.minX
            let verticalMovement = currentWindow.minY - capturedWindow.minY
            guard abs(horizontalMovement) > tolerance || abs(verticalMovement) > tolerance else {
                return rectangle
            }
            // The full-screen fallback can point outside the focused window.
            // Such a point does not move with that window.
            guard capturedWindow.contains(CGPoint(x: rectangle.midX, y: rectangle.midY)) else {
                return rectangle
            }
            return rectangle.offsetBy(dx: horizontalMovement, dy: verticalMovement)
        default:
            // Losing the focused window or gaining a different one invalidates
            // the old crop. Refuse instead of reusing the old coordinates.
            return nil
        }
    }
}
