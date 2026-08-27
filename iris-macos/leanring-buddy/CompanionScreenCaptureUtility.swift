//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//
//  WHY THE POINTING PATH MAY ASK FOR A CROP. A whole display downscaled to
//  1280px wide is roughly seven pixels per terminal character, and every window
//  on the desktop is composited flat into it with no seam, no z-order and no
//  hint about which one has focus. A reader with a browser overlapping a
//  terminal reported that Iris "thought the iris setup on website was an
//  extension of my terminal", and six asks at one target produced five
//  different coordinates.
//
//  The watch loop already measured the way out of this. `WatchFrameAnnotation`'s
//  header records it: whole screen with the window described in words 0/5,
//  whole screen with the window outlined 1-2/5, whole screen plus the crop as a
//  second image 0-1/5, the crop on its own 5/5. So the pointing path reuses
//  that file's crop rather than inventing a second one, and this file's job is
//  to record enough about the crop that the coordinate maths can be undone.
//
//  It is opt-in. General chat still gets the whole screen, because "what is on
//  my screen" is a question about the screen and not about one window.
//

import AppKit
import ImageIO
import ScreenCaptureKit

/// Where a cropped capture's image sits inside the full-display screenshot it
/// was cut out of.
///
/// Cropping moves the origin, so a coordinate the model gives in the cropped
/// image is not a coordinate in the display. Keeping the full-display pixel
/// dimensions here means the existing screenshot-pixels → display-points
/// conversion is left exactly as it was, and the only new step in front of it
/// is adding the crop's own origin back on.
struct CompanionScreenCaptureWindowCrop {
    /// The window's rectangle inside the full-display screenshot, in that
    /// screenshot's own pixels, top-left origin — the same space and the same
    /// origin `WatchFrameAnnotation` crops in.
    let regionInFullScreenshotPixels: CGRect
    let fullScreenshotWidthInPixels: Int
    let fullScreenshotHeightInPixels: Int
}

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    /// The pixel dimensions of `imageData` — the image that is actually sent.
    /// When the capture was cropped to one window these are the crop's
    /// dimensions, not the display's, because the model is told these numbers
    /// and answers in the coordinate space of the picture in front of it.
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    /// Non-nil when `imageData` is one window rather than the whole display.
    /// The pointing maths needs it to map a coordinate back out of the crop.
    var focusedWindowCrop: CompanionScreenCaptureWindowCrop?
    /// The app that owned the focused window at capture time, and that window's
    /// title, so the model can be told what it is looking at. Nil when the
    /// caller did not ask for a crop, or when nothing could be read.
    var focusedApplicationName: String?
    var focusedWindowTitle: String?
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    ///
    /// - Parameter shouldCropToTheFocusedWindow: when true, the display holding
    ///   the reader's focused window is cut down to just that window (see the
    ///   file header for the measurement behind this). The other displays are
    ///   still sent whole so a `:screenN` answer keeps working, and the screen
    ///   numbering is untouched. When there is no focused window to crop to,
    ///   every display is sent whole and the label says so — a model that is
    ///   about to see several overlapping windows needs to know that is what it
    ///   is seeing rather than assume it is looking at one.
    static func captureAllScreensAsJPEG(
        croppingToTheFocusedWindow shouldCropToTheFocusedWindow: Bool = false
    ) async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = ScreenContainment.screenFrame(frameA, containsPointer: mouseLocation)
            let bContainsCursor = ScreenContainment.screenFrame(frameB, containsPointer: mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        // Which window the reader is actually working in. Read once for the
        // whole batch rather than once per display: the answer is the same for
        // every display, and each read walks an accessibility tree.
        let focusedWindow = shouldCropToTheFocusedWindow ? focusedWindowWorthCroppingTo() : nil

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = ScreenContainment.screenFrame(displayFrame, containsPointer: mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            // Cut the frame down to the focused window, but only on the display
            // that window is actually on. Everything the crop changes about the
            // coordinate maths is recorded in `windowCrop` so it can be undone;
            // if the crop cannot be made or cannot be trusted, this display is
            // sent whole, which is exactly what it always used to be.
            var imageDataToSend = jpegData
            var imageWidthInPixels = configuration.width
            var imageHeightInPixels = configuration.height
            var windowCrop: CompanionScreenCaptureWindowCrop?

            if let focusedWindow,
               displayFrame.contains(CGPoint(
                   x: focusedWindow.rectangleInGlobalAppKitPoints.midX,
                   y: focusedWindow.rectangleInGlobalAppKitPoints.midY
               )),
               let croppedToTheWindow = croppedToTheFocusedWindow(
                   fullDisplayJPEG: jpegData,
                   fullScreenshotWidthInPixels: cgImage.width,
                   fullScreenshotHeightInPixels: cgImage.height,
                   focusedWindowRectangleInGlobalAppKitPoints: focusedWindow.rectangleInGlobalAppKitPoints,
                   displayFrame: displayFrame
               )
            {
                imageDataToSend = croppedToTheWindow.imageData
                imageWidthInPixels = croppedToTheWindow.widthInPixels
                imageHeightInPixels = croppedToTheWindow.heightInPixels
                windowCrop = croppedToTheWindow.crop
            }

            let screenLabel = labelDescribingThisImage(
                imageWidthInPixels: imageWidthInPixels,
                imageHeightInPixels: imageHeightInPixels,
                displayIndex: displayIndex,
                numberOfDisplays: sortedDisplays.count,
                isCursorScreen: isCursorScreen,
                focusedWindow: focusedWindow,
                theImageWasCroppedToTheFocusedWindow: windowCrop != nil,
                theCallerAskedForACrop: shouldCropToTheFocusedWindow
            )

            capturedScreens.append(CompanionScreenCapture(
                imageData: imageDataToSend,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: imageWidthInPixels,
                screenshotHeightInPixels: imageHeightInPixels,
                focusedWindowCrop: windowCrop,
                focusedApplicationName: focusedWindow?.applicationName,
                focusedWindowTitle: focusedWindow?.windowTitle
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    // MARK: - The focused window

    /// What the pointing path needs to know about the window the reader is
    /// actually working in: which app owns it, what it is called, and where it
    /// is in AppKit global points.
    private struct FocusedWindowOnScreen {
        let applicationName: String?
        let windowTitle: String?
        /// AppKit global coordinates — bottom-left origin, the same space
        /// `NSScreen.frame` and `NSEvent.mouseLocation` use, so it can be
        /// matched against the display frames the captures are described in.
        let rectangleInGlobalAppKitPoints: CGRect
    }

    /// Reads the focused window through the accessibility sources the watch
    /// loop already uses (`SystemWatchLoopLocalSignalSource`), and converts its
    /// rectangle out of the accessibility API's coordinate space into AppKit's.
    ///
    /// Returns nil when nothing is focused, when the screen layout cannot be
    /// read, or when the reader is looking at Iris itself — Iris's own windows
    /// are excluded from the capture, so cropping to one would frame whatever
    /// happens to be sitting behind it.
    private static func focusedWindowWorthCroppingTo() -> FocusedWindowOnScreen? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier =
            (try? AppAwarenessService.currentForegroundApplicationIdentity())?.bundleIdentifier
        if let ownBundleIdentifier, frontmostBundleIdentifier == ownBundleIdentifier {
            return nil
        }

        let localSignalSource = SystemWatchLoopLocalSignalSource()
        guard
            let (windowRectangleInAccessibilityPoints, _) =
                localSignalSource.focusedWindowRectangleAndDisplaySizeInPoints(),
            let primaryScreenFrame = NSScreen.screens.first?.frame
        else { return nil }

        // The accessibility API reports a window's position from the top-left
        // of the PRIMARY display with y growing downward; AppKit measures from
        // that same display's bottom-left with y growing upward. One flip about
        // the primary screen's top edge converts between them. On a
        // single-display Mac this and the display-local conversion below cancel
        // out to exactly the "no y flip here" that `WatchFrameAnnotation`
        // documents, so the known-good case is unchanged.
        let rectangleInGlobalAppKitPoints = CGRect(
            x: windowRectangleInAccessibilityPoints.minX,
            y: primaryScreenFrame.maxY - windowRectangleInAccessibilityPoints.maxY,
            width: windowRectangleInAccessibilityPoints.width,
            height: windowRectangleInAccessibilityPoints.height
        )

        return FocusedWindowOnScreen(
            applicationName: localSignalSource.frontmostApplicationName(),
            windowTitle: localSignalSource.frontmostWindowTitle(),
            rectangleInGlobalAppKitPoints: rectangleInGlobalAppKitPoints
        )
    }

    // MARK: - Cropping

    private struct CroppedFocusedWindowImage {
        let imageData: Data
        let widthInPixels: Int
        let heightInPixels: Int
        let crop: CompanionScreenCaptureWindowCrop
    }

    /// Cuts one display's screenshot down to the focused window, and works out
    /// where that cut was made so the pointing maths can be undone.
    ///
    /// The pixels are cut by `WatchFrameAnnotation.croppingToTheFocusedWindow`
    /// — the file the watch loop measured this against, and the only crop in
    /// this app. The rectangle is recomputed here only because that function
    /// hands back an image and not the rectangle it used, and the two are then
    /// checked against each other: if the recomputed rectangle disagrees with
    /// the size of the image that actually came back, the crop is thrown away
    /// and the caller sends the whole display. A crop rectangle that has
    /// drifted would fly the eye somewhere the reader never asked about,
    /// whereas no crop at all is only as bad as it was before this existed.
    private static func croppedToTheFocusedWindow(
        fullDisplayJPEG: Data,
        fullScreenshotWidthInPixels: Int,
        fullScreenshotHeightInPixels: Int,
        focusedWindowRectangleInGlobalAppKitPoints: CGRect,
        displayFrame: CGRect
    ) -> CroppedFocusedWindowImage? {
        guard
            displayFrame.width > 0, displayFrame.height > 0,
            fullScreenshotWidthInPixels > 0, fullScreenshotHeightInPixels > 0
        else { return nil }

        // Display-local and top-left origin, which is the shape
        // `WatchFrameAnnotation` documents `windowBoundsInPoints` as being in.
        let windowBoundsInDisplayLocalPoints = CGRect(
            x: focusedWindowRectangleInGlobalAppKitPoints.minX - displayFrame.minX,
            y: displayFrame.maxY - focusedWindowRectangleInGlobalAppKitPoints.maxY,
            width: focusedWindowRectangleInGlobalAppKitPoints.width,
            height: focusedWindowRectangleInGlobalAppKitPoints.height
        )

        guard let croppedJPEG = WatchFrameAnnotation.croppingToTheFocusedWindow(
            inJPEG: fullDisplayJPEG,
            windowBoundsInPoints: windowBoundsInDisplayLocalPoints,
            displaySizeInPoints: displayFrame.size
        ) else { return nil }

        // The same arithmetic that file does, repeated here only to learn the
        // rectangle it used — see the note above about why the two answers are
        // then checked against each other.
        let pointsToPixels = CGFloat(fullScreenshotWidthInPixels) / displayFrame.width
        let cropRegionInFullScreenshotPixels = CGRect(
            x: windowBoundsInDisplayLocalPoints.minX * pointsToPixels,
            y: windowBoundsInDisplayLocalPoints.minY * pointsToPixels,
            width: windowBoundsInDisplayLocalPoints.width * pointsToPixels,
            height: windowBoundsInDisplayLocalPoints.height * pointsToPixels
        ).intersection(
            CGRect(x: 0, y: 0,
                   width: CGFloat(fullScreenshotWidthInPixels),
                   height: CGFloat(fullScreenshotHeightInPixels))
        ).integral

        guard
            !cropRegionInFullScreenshotPixels.isNull,
            let croppedPixelSize = pixelDimensionsOfJPEG(croppedJPEG)
        else { return nil }

        // `CGImage.cropping(to:)` rounds its rectangle to whole pixels, so an
        // exact match is not expected. A disagreement bigger than that rounding
        // means the two calculations have drifted apart, and the crop is
        // discarded rather than trusted.
        let widthDisagreementInPixels =
            abs(croppedPixelSize.width - Int(cropRegionInFullScreenshotPixels.width))
        let heightDisagreementInPixels =
            abs(croppedPixelSize.height - Int(cropRegionInFullScreenshotPixels.height))
        guard widthDisagreementInPixels <= 2, heightDisagreementInPixels <= 2 else { return nil }

        return CroppedFocusedWindowImage(
            imageData: croppedJPEG,
            widthInPixels: croppedPixelSize.width,
            heightInPixels: croppedPixelSize.height,
            crop: CompanionScreenCaptureWindowCrop(
                regionInFullScreenshotPixels: cropRegionInFullScreenshotPixels,
                fullScreenshotWidthInPixels: fullScreenshotWidthInPixels,
                fullScreenshotHeightInPixels: fullScreenshotHeightInPixels
            )
        )
    }

    /// How big the cropped image actually came out, read the same way
    /// `WatchFrameAnnotation` reads the frame it crops — so the size this
    /// checks against is measured by the same route that produced it.
    private static func pixelDimensionsOfJPEG(_ jpegData: Data) -> (width: Int, height: Int)? {
        guard
            let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
            image.width > 0, image.height > 0
        else { return nil }
        return (image.width, image.height)
    }

    // MARK: - What the model is told about the image

    /// The text block that rides alongside one image.
    ///
    /// When the image IS one window, saying which app and window it belongs to
    /// is the whole point: that is what stops a browser sitting behind a
    /// terminal from reading as part of the terminal. When a crop was wanted
    /// and could not be made, the model is told THAT instead, because it is
    /// about to see several overlapping windows and must not assume otherwise.
    /// When no crop was ever asked for — general chat — the label is byte for
    /// byte the one this file has always produced.
    private static func labelDescribingThisImage(
        imageWidthInPixels: Int,
        imageHeightInPixels: Int,
        displayIndex: Int,
        numberOfDisplays: Int,
        isCursorScreen: Bool,
        focusedWindow: FocusedWindowOnScreen?,
        theImageWasCroppedToTheFocusedWindow: Bool,
        theCallerAskedForACrop: Bool
    ) -> String {
        let windowDescription = describeInWords(focusedWindow: focusedWindow)

        // THE PIXEL SIZE, ON EVERY LABEL. The system prompt tells the model
        // "images are labeled with their pixel dimensions — use those as the
        // coordinate space", and until 2026-08-27 no label carried them. The
        // model had to GUESS the size of the image it was answering in, and a
        // guessed coordinate space is how a point lands nowhere near the thing
        // it named — the "pointing at random stuff" report. It is worst on a
        // cropped window, where the dimensions are not a familiar screen size
        // and there is nothing to guess from at all.
        let pixelSpace = "\(imageWidthInPixels)x\(imageHeightInPixels) pixels"

        if theImageWasCroppedToTheFocusedWindow {
            let whichWindow = windowDescription ?? "the window the user is working in"
            return "the focused window: \(whichWindow). This image is ONLY that window, cut out of the screen — nothing else on the desktop is in it. It is \(pixelSpace); give coordinates in THAT space, measured from this image's own top-left corner, not from the whole screen."
        }

        let screenDescription: String
        if numberOfDisplays == 1 {
            screenDescription = "user's screen (cursor is here)"
        } else if isCursorScreen {
            screenDescription = "screen \(displayIndex + 1) of \(numberOfDisplays) — cursor is on this screen (primary focus)"
        } else {
            screenDescription = "screen \(displayIndex + 1) of \(numberOfDisplays) — secondary screen"
        }

        let screenDescriptionWithSize = screenDescription + " — \(pixelSpace)"

        guard theCallerAskedForACrop else { return screenDescriptionWithSize }

        // A crop was wanted here and could not be made. Say so: a model that
        // believes it is looking at one window when it is looking at a stack of
        // them is exactly how a website behind a terminal became part of it.
        var whyThisIsTheWholeScreen = "This is the WHOLE screen, not a single window — several windows may be visible and they may overlap, so do not read two windows as one."
        if let windowDescription {
            whyThisIsTheWholeScreen += " The app in front is \(windowDescription)."
        } else {
            whyThisIsTheWholeScreen += " Iris could not tell which window has focus."
        }
        return screenDescriptionWithSize + " — " + whyThisIsTheWholeScreen
    }

    /// "Terminal — “cue — -zsh — 80×24”", or as much of that as is known.
    private static func describeInWords(focusedWindow: FocusedWindowOnScreen?) -> String? {
        guard let focusedWindow else { return nil }
        let applicationName = focusedWindow.applicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil
        let windowTitle = focusedWindow.windowTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmptyOrNil

        switch (applicationName, windowTitle) {
        case let (applicationName?, windowTitle?):
            return "\(applicationName) — “\(windowTitle)”"
        case let (applicationName?, nil):
            return applicationName
        case let (nil, windowTitle?):
            return "“\(windowTitle)”"
        case (nil, nil):
            return nil
        }
    }
}

private extension String {
    /// Nil rather than "", so an empty app name or window title falls through
    /// to the next-best description instead of leaving a dangling dash.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
