//
//  WatchFrameAnnotation.swift
//  leanring-buddy
//
//  Cuts the frame down to the window the watch loop is asking about.
//
//  Like `WatchVisualCheck.swift`, this is compiled by
//  `iris-macos/tools/guide-rehearsal` as well as by the app, so it imports
//  nothing above CoreGraphics/ImageIO and holds no app state.
//
//  WHY THIS EXISTS, and what was measured to get here. The loop used to send the
//  whole screen and describe the window in words — the frontmost application and
//  the focused window's title. Replayed against a real frame of a *successful*
//  `npm ci`, five samples at a time:
//
//      whole screen, words only ............ 0/5 correct
//      whole screen, window outlined ....... 1–2/5
//      whole screen + crop as 2nd image .... 0–1/5
//      crop alone .......................... 5/5
//
//  Two things fall out of that. The model was not failing to *try*; on the whole
//  screen the terminal it had to read was about seven pixels a character after
//  the API's downscale, and it was guessing. And every extra thing added to the
//  request — a second image, a second block of instructions — made it worse, not
//  better. Sent the window on its own it is right every time.
//
//  WHAT THIS COSTS. The full screen is no longer sent, so a `STUCK` verdict can
//  no longer be read from something elsewhere on the desktop. That is a real
//  loss and it is taken deliberately: the crop follows the *focused* window, and
//  a dialog that interrupts somebody almost always takes focus, so it lands
//  inside the crop rather than outside it. A 5/5 answer about the right window
//  beats a 0/5 answer with better peripheral vision.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum WatchFrameAnnotation {

    /// Just the window, at the frame's own resolution.
    ///
    /// Returns nil if the bounds do not land on this frame — the window is on
    /// another display, or was closed between the capture and the read. The
    /// caller then sends the whole frame, which is what it always used to do:
    /// worse, but not broken.
    static func croppingToTheFocusedWindow(
        inJPEG jpegData: Data,
        windowBoundsInPoints: CGRect,
        displaySizeInPoints: CGSize,
        compressionQuality: CGFloat = 0.8
    ) -> Data? {
        guard
            displaySizeInPoints.width > 0,
            windowBoundsInPoints.width > 0,
            windowBoundsInPoints.height > 0,
            let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let frame = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        // The frame is a Retina capture of a display measured in points, so one
        // point is usually two pixels. Deriving the ratio rather than assuming
        // 2 keeps this right on a non-Retina display and on a scaled resolution.
        let pointsToPixels = CGFloat(frame.width) / displaySizeInPoints.width

        // Window bounds arrive top-left origin, which is how both the
        // accessibility API and System Events report them, and also how
        // `CGImage.cropping` reads — so there is deliberately no y flip here.
        let cropRect = CGRect(
            x: windowBoundsInPoints.minX * pointsToPixels,
            y: windowBoundsInPoints.minY * pointsToPixels,
            width: windowBoundsInPoints.width * pointsToPixels,
            height: windowBoundsInPoints.height * pointsToPixels
        ).intersection(
            CGRect(x: 0, y: 0, width: CGFloat(frame.width), height: CGFloat(frame.height))
        )

        // A sliver is not a window. Cropping to one would produce a confident
        // answer about almost no pixels, which is the failure mode this whole
        // file exists to remove.
        guard
            !cropRect.isNull,
            cropRect.width >= 120,
            cropRect.height >= 80,
            let cropped = frame.cropping(to: cropRect),
            let output = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            )
        else { return nil }

        CGImageDestinationAddImage(
            destination,
            cropped,
            [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
