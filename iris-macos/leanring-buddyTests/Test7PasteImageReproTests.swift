//
//  Test7PasteImageReproTests.swift
//  leanring-buddyTests
//
//  "I CANNOT PASTE IMAGES INTO THE CHAT BOX."
//
//  Reported in Test 7 and again in Test 4, with runtime evidence beside it:
//  Iris asked the pasteboard for TEXT three times and never once asked it for
//  an image.
//
//  RECREATED AT HEAD BY OBSERVATION, not by reading the source. A harness hosted
//  the bar's own field construction (`OverlayEyeInputBar.swift:1077-1081`,
//  verbatim) in a borderless non-activating panel that can become key — the same
//  window shape the bar uses — put an image on the general pasteboard as a
//  PROMISED item so every type request could be counted as it happened, and
//  pasted. Measured:
//
//      types the app actually requested: ["public.utf8-plain-text", "public.rtf"]
//      did it ever read an image type?   NO
//      field text after the paste:       "" (0 characters)
//      cmd-V swallowed by a view:        false
//
//  and the control leg — the same keystroke, the same field, TEXT on the
//  pasteboard — pasted "hello from the harness" perfectly. So the paste path
//  was never broken. A SwiftUI `TextField` is bound to a `String`, its field
//  editor reads text types, and handed a picture it does the only thing it can,
//  which is nothing. Silently.
//
//  These tests are the fix, at the two places it has to be true: the keystroke
//  has to TAKE the image, and the message has to CARRY it. (It carried it
//  INSTEAD of the screen until Sep 3 2026; it now carries it WITH the screen —
//  founder ruling, see `CompanionScreenCaptureUtility.imageryForOneChatMessage`.)
//
//  Revert-checked. With `SelectionTextFieldImagePasteCatchingView.performKeyEquivalent`
//  returning false unconditionally, and with `imageryForOneChatMessage` ignoring
//  its pasted image, the tests below go red on exactly the assertions that name
//  the reader's symptom; restoring both turns them green again.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Iris

@MainActor
@Suite(.serialized)
struct Test7PasteImageReproTests {

    // MARK: - Fixtures

    /// A pasteboard of this test's own, so nothing here writes over whatever the
    /// person running the suite has on their real clipboard.
    private func aPasteboardOfOurOwn(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("iris.test7.paste.\(name)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func aPNG(width: Int, height: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.black.setFill()
        NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func aCommandVKeystroke() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        )!
    }

    private func aFabricatedScreenCapture(label: String, width: Int, height: Int) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data([0xFF, 0xD8, 0xFF]),
            label: label,
            isCursorScreen: true,
            displayWidthInPoints: width,
            displayHeightInPoints: height,
            displayFrame: CGRect(x: 0, y: 0, width: width, height: height),
            screenshotWidthInPixels: width,
            screenshotHeightInPixels: height
        )
    }

    // MARK: - 1. The image comes off the pasteboard at all

    /// The single fact the whole report reduces to: an image on the pasteboard
    /// has to be readable as an image. At HEAD nothing ever asked.
    @Test func anImageOnThePasteboardIsReadAsAnImage() throws {
        let pasteboard = aPasteboardOfOurOwn("image")
        pasteboard.setData(aPNG(width: 240, height: 160), forType: .png)

        let pastedImage = try #require(
            OverlayEyePastedImageReader.imageOnThePasteboard(pasteboard),
            "an image on the pasteboard must be readable — this is the reader's whole report"
        )
        #expect(pastedImage.pixelWidth == 240)
        #expect(pastedImage.pixelHeight == 160)
        #expect(OverlayEyePastedImageReader.dataIsPNG(pastedImage.imageData))
        // The wire declaration ClaudeAPI will sniff off these bytes.
        #expect(pastedImage.mediaType == "image/png")
    }

    /// Preview and most native apps write TIFF rather than PNG, so "an image" has
    /// to mean more than one type.
    @Test func aTIFFOnThePasteboardIsReadTooAndArrivesAsPNG() throws {
        let pasteboard = aPasteboardOfOurOwn("tiff")
        let tiff = try #require(NSBitmapImageRep(data: aPNG(width: 120, height: 90))?
            .representation(using: .tiff, properties: [:]))
        pasteboard.setData(tiff, forType: .tiff)

        let pastedImage = try #require(OverlayEyePastedImageReader.imageOnThePasteboard(pasteboard))
        #expect(pastedImage.pixelWidth == 120)
        #expect(pastedImage.pixelHeight == 90)
        #expect(OverlayEyePastedImageReader.dataIsPNG(pastedImage.imageData))
    }

    /// The load-bearing negative. A text pasteboard must read as NO image, or an
    /// ordinary text paste would be swallowed and the fix would have replaced
    /// one broken paste with another.
    @Test func aTextOnlyPasteboardCarriesNoImage() {
        let pasteboard = aPasteboardOfOurOwn("text")
        pasteboard.setString("just some words", forType: .string)

        #expect(OverlayEyePastedImageReader.imageOnThePasteboard(pasteboard) == nil)
    }

    // MARK: - 2. The keystroke

    /// Plain cmd-V is claimed only when there is an image to claim it for.
    @Test func theCatchingViewTakesCommandVOnlyWhenThereIsAnImage() throws {
        let attachment = OverlayEyePastedImageAttachment()
        let pasteboard = aPasteboardOfOurOwn("keystroke")

        let catcher = SelectionTextFieldImagePasteCatchingView(frame: .zero)
        catcher.pasteboardToRead = { pasteboard }
        catcher.attachTheImage = { attachment.attach($0) }

        // Text on the pasteboard: not ours. Returning false is what lets the
        // field editor go on pasting text exactly as it always did.
        pasteboard.clearContents()
        pasteboard.setString("just some words", forType: .string)
        #expect(catcher.performKeyEquivalent(with: aCommandVKeystroke()) == false)
        #expect(attachment.thereIsSomethingAttached == false)

        // An image: claimed, and attached.
        pasteboard.clearContents()
        pasteboard.setData(aPNG(width: 64, height: 48), forType: .png)
        #expect(catcher.performKeyEquivalent(with: aCommandVKeystroke()) == true)
        let attached = try #require(attachment.theImagesTheReaderAttached.last)
        #expect(attached.pixelWidth == 64)
    }

    /// The window really does offer the keystroke to this view before anything
    /// else gets it. The whole design rests on that traversal, so it is asserted
    /// against a real `NSWindow` rather than reasoned about.
    @Test func arealWindowOffersCommandVToTheCatcherFirst() throws {
        let attachment = OverlayEyePastedImageAttachment()
        let pasteboard = aPasteboardOfOurOwn("window")
        pasteboard.setData(aPNG(width: 32, height: 32), forType: .png)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let catcher = SelectionTextFieldImagePasteCatchingView(frame: .zero)
        catcher.pasteboardToRead = { pasteboard }
        catcher.attachTheImage = { attachment.attach($0) }
        window.contentView?.addSubview(catcher)

        #expect(window.performKeyEquivalent(with: aCommandVKeystroke()) == true)
        #expect(attachment.thereIsSomethingAttached)
    }

    /// shift-cmd-V is "paste and match style" — a text operation the reader is
    /// asking a text field for. Claiming it would take a keystroke away and give
    /// nothing back.
    @Test func onlyPlainCommandVIsClaimed() {
        let plain = aCommandVKeystroke()
        #expect(OverlayEyePasteKeystroke.isTheCommandVThatPastes(plain))

        let withShift = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "V", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        )!
        #expect(OverlayEyePasteKeystroke.isTheCommandVThatPastes(withShift) == false)

        let commandC = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
        )!
        #expect(OverlayEyePasteKeystroke.isTheCommandVThatPastes(commandC) == false)

        let keyUp = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9
        )!
        #expect(OverlayEyePasteKeystroke.isTheCommandVThatPastes(keyUp) == false)
    }

    /// Dismissing the bar destroys the exchange. An attachment that outlived it
    /// would ride a question the reader asked later and never see it coming.
    @Test func leavingItsWindowForgetsWhatWasAttached() throws {
        let attachment = OverlayEyePastedImageAttachment()
        let pasteboard = aPasteboardOfOurOwn("teardown")
        pasteboard.setData(aPNG(width: 40, height: 40), forType: .png)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        let catcher = SelectionTextFieldImagePasteCatchingView(frame: .zero)
        catcher.pasteboardToRead = { pasteboard }
        catcher.attachTheImage = { attachment.attach($0) }
        catcher.forgetWhatWasAttached = { attachment.removeAllAttachments() }
        window.contentView?.addSubview(catcher)

        #expect(window.performKeyEquivalent(with: aCommandVKeystroke()) == true)
        #expect(attachment.thereIsSomethingAttached)

        // What `hideInputBar` does to the whole content view.
        catcher.removeFromSuperview()
        #expect(attachment.thereIsSomethingAttached == false)
    }

    // MARK: - 3. The message carries the image WITH the screen

    /// The reader's symptom, stated as the thing that has to be true of the
    /// message they send: the picture they pasted is a picture Iris looks at —
    /// after the screen, which stays in the message (founder ruling, Sep 3
    /// 2026: "it should read both my screen and the image").
    @Test func aPastedImageRidesAfterTheScreenInTheMessage() throws {
        let pngData = aPNG(width: 300, height: 200)
        let pastedImage = try #require(
            OverlayEyePastedImageReader.sendableImage(from: NSBitmapImageRep(data: pngData)!)
        )
        let screen = aFabricatedScreenCapture(
            label: "user's screen (cursor is here) — 1280x832 pixels", width: 1280, height: 832
        )

        let labeled = CompanionScreenCaptureUtility.labeledImages(
            forScreenCaptures: [screen], andImagesTheReaderAttached: [pastedImage]
        )

        #expect(labeled.count == 2)
        // Screen first, exactly as chat has always labeled it…
        #expect(labeled[0].data == screen.imageData)
        #expect(labeled[0].label.hasPrefix("user's screen (cursor is here)"))
        // …then the picture the reader handed over, introduced as such.
        #expect(labeled[1].data == pastedImage.imageData)
        #expect(labeled[1].label.contains("ATTACHED"))
    }

    /// Losing the screen (no permission, no display) must not lose the question:
    /// the reader attached a picture, and that picture still goes.
    @Test func whenTheScreenCannotBeCapturedTheAttachmentStillGoes() async throws {
        let pastedImage = OverlayEyePastedImage(
            imageData: aPNG(width: 120, height: 80), pixelWidth: 120, pixelHeight: 80
        )
        let imagery = try await CompanionScreenCaptureUtility
            .imageryForOneChatMessage(theReaderAttached: [pastedImage])

        // The runner may or may not be allowed to capture a screen; either way
        // the attachment is the last image, and the labels agree with the
        // captures about whether a screen is in the message.
        #expect(imagery.labeledImages.last?.data == pastedImage.imageData)
        #expect(imagery.labeledImages.count == imagery.screenCaptures.count + 1)
    }

    /// The label has to say what the picture is, because every other label in
    /// that file describes a screen and the system prompt is written for a model
    /// looking at one — and it has to say that the picture is not a coordinate
    /// space, or the eye flies to a spot on the desktop that is inside a photo.
    @Test func theLabelSaysItIsNotAScreenshotAndNotToPointInsideIt() throws {
        let pastedImage = OverlayEyePastedImage(
            imageData: aPNG(width: 800, height: 600), pixelWidth: 800, pixelHeight: 600
        )
        let labelWithAScreen = CompanionScreenCaptureUtility.labelForTheImageTheReaderAttached(
            pastedImage, position: 2, count: 3, theScreenIsAlsoInThisMessage: true
        )
        #expect(labelWithAScreen.contains("image 2 of 3"))
        #expect(labelWithAScreen.contains("ATTACHED"))
        #expect(labelWithAScreen.contains("NOT a screenshot"))
        #expect(labelWithAScreen.contains("800x600 pixels"))
        #expect(labelWithAScreen.contains("Never point inside it"))
        // A screen IS in the message, so pointing is still allowed — at it.
        #expect(labelWithAScreen.contains("[POINT:none]") == false)

        let labelWithoutAScreen = CompanionScreenCaptureUtility.labelForTheImageTheReaderAttached(
            pastedImage, position: 1, count: 1, theScreenIsAlsoInThisMessage: false
        )
        #expect(labelWithoutAScreen.contains("the image the user ATTACHED"))
        #expect(labelWithoutAScreen.contains("no screen in this message"))
        // With no screen in the message there is nothing to point at, and the
        // eye must not fly at a coordinate invented for a screen never seen.
        #expect(labelWithoutAScreen.contains("[POINT:none]"))
    }

    /// With nothing pasted, the labels are the ones chat has always sent — byte
    /// for byte the string `CompanionManager` used to build inline.
    @Test func withNothingPastedTheScreenLabelsAreUnchanged() {
        let captures = [
            aFabricatedScreenCapture(label: "user's screen (cursor is here) — 1280x832 pixels", width: 1280, height: 832)
        ]
        let labeled = CompanionScreenCaptureUtility.labeledImages(forScreenCaptures: captures)

        #expect(labeled.count == 1)
        #expect(labeled[0].label ==
            "user's screen (cursor is here) — 1280x832 pixels (image dimensions: 1280x832 pixels)")
        #expect(labeled[0].data == captures[0].imageData)
    }

    // MARK: - 4. It rides one message, and only one

    @Test func theAttachmentIsSpentByTheMessageItRidesOn() {
        let attachment = OverlayEyePastedImageAttachment()
        let pastedImage = OverlayEyePastedImage(
            imageData: aPNG(width: 10, height: 10), pixelWidth: 10, pixelHeight: 10
        )

        attachment.attach(pastedImage)
        #expect(attachment.takeTheImagesForThisMessage() == [pastedImage])
        // Taken, not read: a second message must not silently carry it again.
        #expect(attachment.takeTheImagesForThisMessage() == [])
        #expect(attachment.thereIsSomethingAttached == false)
    }

    @Test func theRemoveControlTakesItBackOff() {
        let attachment = OverlayEyePastedImageAttachment()
        let pastedImage = OverlayEyePastedImage(
            imageData: aPNG(width: 10, height: 10), pixelWidth: 10, pixelHeight: 10
        )
        attachment.attach(pastedImage)
        attachment.remove(pastedImage)
        #expect(attachment.thereIsSomethingAttached == false)
    }

    // MARK: - 5. What is sent stays sendable, and stays the reader's

    /// A phone photograph pasted at full size is megabytes of base64 that buys
    /// nothing and can be refused outright by the API.
    @Test func aHugePastedImageIsBoundedBeforeItIsSent() throws {
        let huge = try #require(NSBitmapImageRep(data: aPNG(width: 3000, height: 2000)))
        let pastedImage = try #require(OverlayEyePastedImageReader.sendableImage(from: huge))

        #expect(max(pastedImage.pixelWidth, pastedImage.pixelHeight)
            == OverlayEyePastedImageReader.longestSideAPastedImageIsSentAt)
        // Aspect ratio kept: 3000x2000 → 1280x853.
        #expect(pastedImage.pixelWidth == 1280)
        #expect(pastedImage.pixelHeight == 853)
        #expect(pastedImage.imageData.count < OverlayEyePastedImageReader.heaviestPNGWorthSending)
    }

    /// A small image is passed through untouched rather than needlessly re-scaled.
    @Test func aSmallPastedImageKeepsItsOwnSize() throws {
        let small = try #require(NSBitmapImageRep(data: aPNG(width: 200, height: 100)))
        let pastedImage = try #require(OverlayEyePastedImageReader.sendableImage(from: small))
        #expect(pastedImage.pixelWidth == 200)
        #expect(pastedImage.pixelHeight == 100)
    }

    /// The scrubbing rule, made structural. A pasted image belongs to the reader
    /// and goes to the model route this message uses and nowhere else — so the
    /// one thing this type must never make easy is printing itself into a log.
    @Test func aPastedImageDescribesItselfWithoutItsContents() {
        let pngData = aPNG(width: 64, height: 64)
        let pastedImage = OverlayEyePastedImage(imageData: pngData, pixelWidth: 64, pixelHeight: 64)

        let described = "\(pastedImage)"
        #expect(described == "a pasted image, 64x64, \(pngData.count) bytes")
        #expect(described.contains(pngData.base64EncodedString().prefix(24)) == false)
        // Not even the raw PNG signature leaks through an interpolation.
        #expect(described.contains("PNG") == false)
    }
}
