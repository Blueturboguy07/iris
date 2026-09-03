//
//  DragDropAttachmentReproTests.swift
//  leanring-buddyTests
//
//  "i cant drag and drop screenshots into it because when i click off it closes"
//  (founder, Sep 3 2026), and the two rulings that came with it: an attached
//  image goes WITH the screen, not instead of it, and the bar gets an attach
//  button.
//
//  The dismissal half was measured before it was written — see the header of
//  `OverlayEyeInputBarDropTarget.swift`: a global monitor in the bar's process
//  sees the foreign drag's mouse-up 4ms BEFORE the drop is delivered, so the
//  only way to keep the bar standing is to decide on signals that arrive
//  earlier (the bar's own `draggingEntered`, the drag pasteboard's change
//  count). These tests pin that rule, the reading of a drop, the drop target's
//  wiring, and the attachment list.
//
//  Revert-checked: with `readerReleasedTheLeftButton` ignoring both drag
//  signals (the old press-time behaviour moved to the release), the two
//  "keeps the bar" tests go red on the reader's exact symptom.
//

import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Iris

@MainActor
@Suite(.serialized)
struct DragDropAttachmentReproTests {

    // MARK: - Fixtures

    private func aPNG(width: Int, height: Int) -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }

    /// A pasteboard of this test's own, never the reader's real drag pasteboard.
    private func aPasteboardOfOurOwn(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("iris.dragdrop.\(name).\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func aTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-dragdrop-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func anImageFile(named name: String, width: Int, height: Int, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent(name)
        try aPNG(width: width, height: height).write(to: fileURL)
        return fileURL
    }

    private func anImage(width: Int, height: Int) -> OverlayEyePastedImage {
        OverlayEyePastedImage(imageData: aPNG(width: width, height: height), pixelWidth: width, pixelHeight: height)
    }

    // MARK: - 1. The rule: a press outside is only a click once it is released as one

    /// The behaviour nobody must notice changing: a plain click in another app
    /// still dismisses the bar — on its release now, ~100ms later than before.
    @Test func aPlainClickOutsideStillDismissesTheBarOnRelease() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 7)
        #expect(rule.aPressOutsideTheBarIsPending)
        #expect(rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 7) == .dismissTheBar)
        #expect(rule.aPressOutsideTheBarIsPending == false)
    }

    /// THE REPORT. The press on the Finder icon used to close the bar. Now the
    /// drag entering the bar tells the rule the release is a drop.
    @Test func aPressThatBecameADragIntoTheBarKeepsTheBar() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 7)
        rule.aDragEnteredTheBar()
        #expect(
            rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 8) == .keepTheBar,
            "the drop's release dismissed the bar — the reader's exact symptom: nothing left to drop onto"
        )
    }

    /// The second, independent signal: a drag session started somewhere since
    /// the press (the drag pasteboard moved). Even a drop that lands on the
    /// bar's edge before `draggingEntered` has run is covered by this one.
    @Test func aPressFollowedByAnyDragSessionKeepsTheBar() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 7)
        #expect(rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 8) == .keepTheBar)
    }

    /// A release that no press preceded (the press was inside the bar, or on
    /// the eye) decides nothing.
    @Test func aReleaseWithoutAPendingPressDecidesNothing() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        #expect(rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 7) == .keepTheBar)
    }

    /// Hiding the bar (Escape, the ×) mid-press must not leave a press pending
    /// for the NEXT bar to be dismissed by.
    @Test func hidingTheBarForgetsAPendingPress() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 7)
        rule.theBarWentAwayOrTheGestureEnded()
        #expect(rule.aPressOutsideTheBarIsPending == false)
        #expect(rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 7) == .keepTheBar)
    }

    /// Each press starts afresh: a drag that entered the bar during an EARLIER
    /// gesture says nothing about this one.
    @Test func aDragFromAnEarlierGestureDoesNotSpareALaterClick() {
        var rule = OverlayEyeInputBarClickOutsideDismissal()
        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 7)
        rule.aDragEnteredTheBar()
        _ = rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 8)

        rule.readerPressedTheLeftButtonOutsideTheBar(dragPasteboardChangeCount: 8)
        #expect(rule.readerReleasedTheLeftButton(dragPasteboardChangeCount: 8) == .dismissTheBar)
    }

    // MARK: - 2. Reading a drop

    @Test func anImageFileOnTheDragPasteboardIsReadAsAnImage() throws {
        let directory = aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try anImageFile(named: "shot.png", width: 240, height: 160, in: directory)

        let pasteboard = aPasteboardOfOurOwn("one-file")
        pasteboard.writeObjects([fileURL as NSURL])

        #expect(OverlayEyePastedImageReader.pasteboardCarriesSomethingAttachable(pasteboard))
        let images = OverlayEyePastedImageReader.imagesOnADragPasteboard(pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.pixelWidth == 240)
        #expect(images.first?.pixelHeight == 160)
    }

    /// "Screenshots", plural. Several files come in the order dropped, and the
    /// cap is the cap.
    @Test func severalImageFilesAreReadInOrderUpToTheCap() throws {
        let directory = aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fileURLs: [URL] = []
        for index in 1...(OverlayEyePastedImageReader.mostImagesOneMessageMayCarry + 1) {
            fileURLs.append(try anImageFile(named: "shot-\(index).png", width: 10 * index, height: 10, in: directory))
        }

        let images = OverlayEyePastedImageReader.imagesInFiles(fileURLs)
        #expect(images.count == OverlayEyePastedImageReader.mostImagesOneMessageMayCarry)
        #expect(images.map(\.pixelWidth) == [10, 20, 30, 40])
    }

    /// A text file dragged by mistake is skipped, never opened as an image, and
    /// the drop as a whole is not attachable.
    @Test func aTextFileIsNotAnImageAndNotAttachable() throws {
        let directory = aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textFile = directory.appendingPathComponent("notes.txt")
        try Data("just words".utf8).write(to: textFile)

        #expect(OverlayEyePastedImageReader.imagesInFiles([textFile]).isEmpty)

        let pasteboard = aPasteboardOfOurOwn("text-file")
        pasteboard.writeObjects([textFile as NSURL])
        #expect(OverlayEyePastedImageReader.pasteboardCarriesSomethingAttachable(pasteboard) == false)
        #expect(OverlayEyePastedImageReader.imagesOnADragPasteboard(pasteboard).isEmpty)
    }

    /// A browser or Preview drag carries the picture's bytes rather than a
    /// file. Read the same way the paste path reads them.
    @Test func rawImageDataOnTheDragPasteboardIsRead() {
        let pasteboard = aPasteboardOfOurOwn("raw-png")
        pasteboard.setData(aPNG(width: 50, height: 40), forType: .png)

        #expect(OverlayEyePastedImageReader.pasteboardCarriesSomethingAttachable(pasteboard))
        let images = OverlayEyePastedImageReader.imagesOnADragPasteboard(pasteboard)
        #expect(images.count == 1)
        #expect(images.first?.pixelWidth == 50)
    }

    /// Dragged text is none of the bar's business: not attachable, no image.
    @Test func aTextOnlyDragIsNotAttachable() {
        let pasteboard = aPasteboardOfOurOwn("text-only")
        pasteboard.setString("some dragged words", forType: .string)
        #expect(OverlayEyePastedImageReader.pasteboardCarriesSomethingAttachable(pasteboard) == false)
        #expect(OverlayEyePastedImageReader.imagesOnADragPasteboard(pasteboard).isEmpty)
    }

    // MARK: - 3. The drop delegate

    /// The content types the delegate offers to accept — image data first (a
    /// browser drag, a screenshot thumbnail's promise) then a file URL (Finder).
    @Test func theDropDelegateAcceptsImagesAndFileURLs() {
        #expect(OverlayEyeBarDropDelegate.droppedContentTypes.contains(.image))
        #expect(OverlayEyeBarDropDelegate.droppedContentTypes.contains(.fileURL))
    }

    /// The reader path a file drop ultimately runs through — the same one the
    /// picker uses — turns a dropped image file into a sendable attachment.
    @Test func aDroppedImageFileBecomesAnAttachmentThroughTheFileReader() throws {
        let directory = aTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = try anImageFile(named: "dropped.png", width: 300, height: 200, in: directory)
        let images = OverlayEyePastedImageReader.imagesInFiles([fileURL])
        #expect(images.count == 1)
        #expect(images.first?.pixelWidth == 300)
    }

    // MARK: - 4. The list

    @Test func attachmentsAccumulateAndTheOldestGoesPastTheCap() {
        let attachment = OverlayEyePastedImageAttachment()
        let cap = OverlayEyePastedImageReader.mostImagesOneMessageMayCarry
        for index in 1...(cap + 1) {
            attachment.attach(anImage(width: 10 * index, height: 10))
        }
        #expect(attachment.theImagesTheReaderAttached.count == cap)
        // The first one in is the one let go; the newest is always there.
        #expect(attachment.theImagesTheReaderAttached.first?.pixelWidth == 20)
        #expect(attachment.theImagesTheReaderAttached.last?.pixelWidth == 10 * (cap + 1))
    }

    @Test func removingOneLeavesTheOthers() {
        let attachment = OverlayEyePastedImageAttachment()
        let first = anImage(width: 10, height: 10)
        let second = anImage(width: 20, height: 10)
        attachment.attach(contentsOf: [first, second])
        attachment.remove(first)
        #expect(attachment.theImagesTheReaderAttached == [second])
    }

    @Test func takingSpendsEveryAttachmentAtOnce() {
        let attachment = OverlayEyePastedImageAttachment()
        let images = [anImage(width: 10, height: 10), anImage(width: 20, height: 10)]
        attachment.attach(contentsOf: images)
        #expect(attachment.takeTheImagesForThisMessage() == images)
        #expect(attachment.takeTheImagesForThisMessage() == [])
        #expect(attachment.thereIsSomethingAttached == false)
    }

    /// The bar's caption tells the reader both halves of the ruling: what is
    /// attached, and that the screen still goes with it.
    @Test func theCaptionSaysHowManyAndThatTheScreenGoesToo() {
        #expect(OverlayEyePastedImageThumbnailRow.caption(forAttachmentCount: 1) == "image attached")
        #expect(OverlayEyePastedImageThumbnailRow.caption(forAttachmentCount: 3) == "3 images attached")
        #expect(OverlayEyePastedImageThumbnailRow.whatIrisWillLookAt.contains("with your screen"))
    }

    /// Several attachments are all labelled, numbered, after the screens.
    @Test func severalAttachmentsAreNumberedAfterTheScreens() {
        let screen = CompanionScreenCapture(
            imageData: Data([0xFF, 0xD8, 0xFF]), label: "user's screen (cursor is here) — 1280x832 pixels",
            isCursorScreen: true, displayWidthInPoints: 1280, displayHeightInPoints: 832,
            displayFrame: CGRect(x: 0, y: 0, width: 1280, height: 832),
            screenshotWidthInPixels: 1280, screenshotHeightInPixels: 832
        )
        let attachments = [anImage(width: 10, height: 10), anImage(width: 20, height: 10)]
        let labeled = CompanionScreenCaptureUtility.labeledImages(
            forScreenCaptures: [screen], andImagesTheReaderAttached: attachments
        )
        #expect(labeled.count == 3)
        #expect(labeled[1].label.hasPrefix("image 1 of 2 the user ATTACHED"))
        #expect(labeled[2].label.hasPrefix("image 2 of 2 the user ATTACHED"))
        #expect(labeled[1].label.contains("The images before it are their screen"))
    }
}
