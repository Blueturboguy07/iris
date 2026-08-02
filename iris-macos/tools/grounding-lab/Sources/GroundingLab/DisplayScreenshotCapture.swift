//
//  DisplayScreenshotCapture.swift
//  grounding-lab
//
//  Screenshots one display with ScreenCaptureKit and reports the geometry the
//  rest of the tool needs. Note carefully which numbers are points and which
//  are pixels — ScreenCaptureKit's configuration is in PIXELS.
//

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct CapturedDisplay {
    var displayIdentifier: CGDirectDisplayID
    /// GLOBAL ACCESSIBILITY POINTS (top-left origin) — the same space
    /// `AXPosition` answers in, which is what makes the subtraction in
    /// `CoordinateSpaces.displayLocalRect` legal.
    var boundsInGlobalPoints: CGRect
    var backingScaleFactor: Double
    var pngData: Data
    var widthInPixels: Int
    var heightInPixels: Int
}

enum DisplayScreenshotCapture {

    enum CaptureError: LocalizedError {
        case noDisplaysAvailable
        case displayNotSharable(CGDirectDisplayID)
        case pngEncodingFailed

        var errorDescription: String? {
            switch self {
            case .noDisplaysAvailable:
                // Seen for real: ScreenCaptureKit reports zero displays while
                // the screen is asleep, even though permission is granted.
                return """
                    ScreenCaptureKit reports no available displays. The usual \
                    cause is that the screen has gone to sleep — wake it \
                    (`caffeinate -u -t 2`) and try again.
                    """
            case .displayNotSharable(let identifier):
                return "ScreenCaptureKit does not expose display \(identifier)."
            case .pngEncodingFailed:
                return "Failed to encode the captured image as PNG."
            }
        }
    }

    /// Picks the display containing `globalPointOfInterest` (top-left-origin
    /// global points), falling back to the main display.
    static func displayIdentifierContaining(globalPoint: CGPoint?) -> CGDirectDisplayID {
        guard let globalPoint else { return CGMainDisplayID() }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return CGMainDisplayID()
        }
        var identifiers = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &identifiers, &displayCount) == .success else {
            return CGMainDisplayID()
        }

        for identifier in identifiers.prefix(Int(displayCount)) {
            // CGDisplayBounds is in the SAME space as AXPosition: global points,
            // top-left origin. This is the whole reason the walker's rects can
            // be tested for containment directly.
            if CGDisplayBounds(identifier).contains(globalPoint) {
                return identifier
            }
        }
        return CGMainDisplayID()
    }

    static func backingScaleFactor(forDisplay displayIdentifier: CGDirectDisplayID) -> Double {
        for screen in NSScreen.screens {
            let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
            if let screenNumber = screen.deviceDescription[screenNumberKey] as? CGDirectDisplayID,
               screenNumber == displayIdentifier {
                return Double(screen.backingScaleFactor)
            }
        }
        return Double(NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    static func capture(displayIdentifier: CGDirectDisplayID) async throws -> CapturedDisplay {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard !shareableContent.displays.isEmpty else {
            throw CaptureError.noDisplaysAvailable
        }
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayIdentifier })
                ?? shareableContent.displays.first else {
            throw CaptureError.displayNotSharable(displayIdentifier)
        }

        let boundsInGlobalPoints = CGDisplayBounds(display.displayID)
        let scaleFactor = backingScaleFactor(forDisplay: display.displayID)

        let configuration = SCStreamConfiguration()
        // These two are PIXELS. Asking for points here would hand back a
        // half-resolution image on Retina while the dataset claimed a 2x scale
        // factor, which would quietly halve every measured distance.
        configuration.width = Int((boundsInGlobalPoints.width * scaleFactor).rounded())
        configuration.height = Int((boundsInGlobalPoints.height * scaleFactor).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let capturedImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        let bitmap = NSBitmapImageRep(cgImage: capturedImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CaptureError.pngEncodingFailed
        }

        return CapturedDisplay(
            displayIdentifier: display.displayID,
            boundsInGlobalPoints: boundsInGlobalPoints,
            backingScaleFactor: scaleFactor,
            pngData: pngData,
            widthInPixels: capturedImage.width,
            heightInPixels: capturedImage.height
        )
    }
}
