//
//  SelectionTextField.swift
//  leanring-buddy
//
//  Taking an image off the pasteboard when the reader presses cmd-V in the bar.
//
//  THE REPORT. Two testers, two rounds apart, wrote the same sentence:
//
//      "I CANNOT PASTE IMAGES INTO THE CHAT BOX."
//
//  and the runtime evidence beside it said why: Iris asked the pasteboard for
//  text, three times, and never once asked it for an image. Recreated against
//  HEAD by hosting the bar's own field construction in a panel with an image on
//  the pasteboard and pasting into it — the app asked for `public.utf8-plain-text`
//  and `public.rtf`, asked for neither `public.png` nor `public.tiff`, and the
//  field ended the paste with the same nought characters it started with. The
//  same keystroke on the same field with TEXT on the pasteboard pasted fine.
//
//  So nothing is broken in the paste path. The bar's field is a SwiftUI
//  `TextField` bound to a `String`, its field editor is a plain-text one, and a
//  plain-text field editor's readable pasteboard types are text types. Handed a
//  picture it does the only thing it can do, which is nothing — and doing
//  nothing, silently, is what the reader experienced.
//
//  WHY THIS FILE IS CALLED WHAT IT IS. `SelectionTextField` is the class name
//  AppKit's accessibility hierarchy reports for the SwiftUI field the bar
//  builds — it is the name in the dumps in `Test6TakeoverPanelReproTests` and
//  in `GuideAutopilotTakeoverPanel`'s header. This file is the paste behaviour
//  that field never had.
//
//  WHY THE FIELD ITSELF IS NOT REPLACED. It would have to be: the bar drives
//  focus through `@FocusState` and `.focused(...)`, submits through `.onSubmit`,
//  and an `NSViewRepresentable` in its place would have to reimplement all of
//  it — a great deal of risk to buy a paste. Instead a zero-size view sits in
//  the same window and claims cmd-V *before* the field editor is offered it.
//  `NSWindow` walks its view tree with `performKeyEquivalent(with:)` before the
//  main menu's Paste item is ever consulted, so an image paste is intercepted
//  and a text paste is waved straight through by returning false. Measured in
//  the same harness: with nothing claiming cmd-V, the window reported the
//  keystroke swallowed by no view at all — that slot was empty and is now used.
//
//  WHAT AN INTERCEPTED IMAGE DOES. It is attached to the NEXT message rather
//  than typed into the field, because there is no way to put a picture inside a
//  `String`. `OverlayEyePastedImageAttachment` holds up to a few of them, the
//  bar draws each as a thumbnail with a remove control, and the message that
//  follows carries them ALONGSIDE the automatic screen capture — see
//  `CompanionScreenCaptureUtility.imageryForOneChatMessage`. (It used to carry
//  the picture INSTEAD of the screen. Founder ruling, Sep 3 2026: "i dont want
//  iris to read just the image attachment, it should read both my screen and
//  the image.")
//
//  SINCE SEP 3 2026 THE SAME ATTACHMENT ARRIVES THREE WAYS: pasted here,
//  dropped onto the bar (`OverlayEyeBarDropDelegate`), or picked with
//  the bar's attach button. The type names still say "pasted" because that is
//  where they were born; the reader helpers below serve all three.
//
//  WHERE THE BYTES ARE ALLOWED TO GO. Onto the model route this message uses,
//  and nowhere else. They are never written to disk: the transcript store
//  records the reader's typed text only, the conversation history the API is
//  handed carries text placeholders only, and `OverlayEyePastedImage`'s own
//  description names the size and the byte count and never the content, so an
//  image cannot be laundered into a log by an interpolation somebody adds later.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The image itself

/// One image the reader put on the pasteboard, normalised into something that
/// can ride the wire: bounded in dimensions, bounded in bytes, and in a format
/// `ClaudeAPI.detectImageMediaType` already recognises.
struct OverlayEyePastedImage: Sendable, Equatable, CustomStringConvertible {

    /// PNG bytes, or JPEG bytes when the PNG was too heavy to send (see
    /// `OverlayEyePastedImageReader.heaviestPNGWorthSending`). Either way the
    /// first bytes say which, which is exactly what `ClaudeAPI` sniffs to fill
    /// in `media_type` — so nothing about the wire format needed changing to
    /// carry a pasted image. Chat has shipped base64 image blocks since it
    /// shipped screenshots.
    let imageData: Data

    let pixelWidth: Int
    let pixelHeight: Int

    /// What the request will declare for these bytes. Derived rather than
    /// stored alongside them so the two can never disagree.
    var mediaType: String {
        OverlayEyePastedImageReader.dataIsPNG(imageData) ? "image/png" : "image/jpeg"
    }

    /// Size and weight, never content. A pasted image is the reader's, and the
    /// only place it is allowed to go is the model route the message it is
    /// attached to uses — so the one thing this type must never make easy is
    /// printing itself into a log.
    var description: String {
        "a pasted image, \(pixelWidth)x\(pixelHeight), \(imageData.count) bytes"
    }
}

// MARK: - Reading one off the pasteboard

/// Turns whatever is on a pasteboard into a sendable image, or answers that
/// there is no image on it — which is the answer that lets a text paste carry
/// on exactly as it always has.
enum OverlayEyePastedImageReader {

    /// The longest side a pasted image is sent at. The same 1280 the screen
    /// capture downscales displays to, for the same reason: it is the size the
    /// model reads well at, and a phone-camera photo pasted at full size is
    /// megabytes of base64 that buys nothing.
    static let longestSideAPastedImageIsSentAt = 1280

    /// Above this the PNG is re-encoded as JPEG. Anthropic rejects an image
    /// whose base64 runs past about 5MB, and base64 is a third larger again
    /// than the bytes — so a lossless screenshot of a photograph, which
    /// compresses badly as PNG, has to be allowed to become a JPEG rather than
    /// become a 400.
    static let heaviestPNGWorthSending = 1_500_000

    /// The image types worth looking for, in the order they are preferred.
    /// `.png` first because it is what a macOS screenshot and a browser's "copy
    /// image" both put on the pasteboard, and taking it directly avoids a
    /// re-encode. `.tiff` is what Preview and most native apps write.
    static let imageTypesWorthReading: [NSPasteboard.PasteboardType] = [.png, .tiff]

    static func dataIsPNG(_ data: Data) -> Bool {
        data.count >= 8 && [UInt8](data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }

    /// The image on this pasteboard, or nil when there is not one.
    ///
    /// Nil is a load-bearing answer, not a failure: it is what makes an
    /// ordinary text paste fall through to the field editor untouched.
    static func imageOnThePasteboard(_ pasteboard: NSPasteboard) -> OverlayEyePastedImage? {
        guard let bitmap = bitmapOnThePasteboard(pasteboard) else { return nil }
        return sendableImage(from: bitmap)
    }

    // MARK: Dropped and picked images

    /// The image file types a drop or the picker accepts: anything
    /// `NSBitmapImageRep` decodes that the model route can carry as PNG/JPEG.
    /// Read through the file's UTType so a `.txt` dragged by mistake is never
    /// opened, and a `.heic` from Photos is (it decodes, and re-encodes to PNG).
    static let imageFileTypesWorthReading: [UTType] = [.png, .jpeg, .tiff, .gif, .bmp, .heic, .heif, .webP]

    /// The most images one drop, one pick, or one message carries. Four is
    /// enough for "here are the before and after" twice over and small enough
    /// that a 320pt bar still reads as a bar.
    static let mostImagesOneMessageMayCarry = 4

    /// Whether a drag pasteboard holds anything the bar could turn into an
    /// attachment — asked at `draggingEntered`, before any bytes are read, so
    /// the pointer can say "copy" or "no" honestly. A promise is counted:
    /// its file exists only once accepted.
    static func pasteboardCarriesSomethingAttachable(_ pasteboard: NSPasteboard) -> Bool {
        if !imageFileURLs(onPasteboard: pasteboard).isEmpty { return true }
        if pasteboard.availableType(from: imageTypesWorthReading) != nil { return true }
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return pasteboard.availableType(from: promiseTypes) != nil
    }

    /// Everything attachable that is ALREADY on a drag pasteboard: image files
    /// first (a Finder drag), then raw image data (a browser or Preview drag).
    /// Promised files are not here — they arrive later, through
    /// `OverlayEyeBarDropDelegate`.
    static func imagesOnADragPasteboard(_ pasteboard: NSPasteboard) -> [OverlayEyePastedImage] {
        let imagesInDroppedFiles = imagesInFiles(imageFileURLs(onPasteboard: pasteboard))
        if !imagesInDroppedFiles.isEmpty { return imagesInDroppedFiles }
        if let imageData = imageOnThePasteboard(pasteboard) { return [imageData] }
        return []
    }

    /// Reads each file that decodes as an image, in the order given, stopping
    /// at `mostImagesOneMessageMayCarry`. A file that is not an image, or that
    /// cannot be read, is skipped rather than failing the whole drop.
    static func imagesInFiles(_ fileURLs: [URL]) -> [OverlayEyePastedImage] {
        var images: [OverlayEyePastedImage] = []
        for fileURL in fileURLs {
            guard images.count < mostImagesOneMessageMayCarry else { break }
            guard fileURLIsAnImage(fileURL),
                  let fileData = try? Data(contentsOf: fileURL),
                  let bitmap = NSBitmapImageRep(data: fileData),
                  let image = sendableImage(from: bitmap) else { continue }
            images.append(image)
        }
        return images
    }

    /// The file URLs on a pasteboard whose type says they are images. `NSURL`
    /// reading with `urlReadingContentsConformToTypes` does the type check the
    /// same way Finder does, from the file's declared type rather than its
    /// extension alone.
    private static func imageFileURLs(onPasteboard pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: imageFileTypesWorthReading.map(\.identifier),
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private static func fileURLIsAnImage(_ fileURL: URL) -> Bool {
        guard let contentType = (try? fileURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                ?? UTType(filenameExtension: fileURL.pathExtension) else { return false }
        return imageFileTypesWorthReading.contains { contentType.conforms(to: $0) }
    }

    private static func bitmapOnThePasteboard(_ pasteboard: NSPasteboard) -> NSBitmapImageRep? {
        // `availableType(from:)` rather than reading each type blind, so a
        // pasteboard carrying only text is never asked for image data it does
        // not have — and so a promised item is not woken for nothing.
        guard let availableImageType = pasteboard.availableType(from: imageTypesWorthReading),
              let imageData = pasteboard.data(forType: availableImageType),
              let bitmap = NSBitmapImageRep(data: imageData)
        else { return nil }
        return bitmap
    }

    /// Bounded in size, bounded in weight, PNG when PNG is cheap enough.
    static func sendableImage(from bitmap: NSBitmapImageRep) -> OverlayEyePastedImage? {
        let widthInPixels = bitmap.pixelsWide
        let heightInPixels = bitmap.pixelsHigh
        guard widthInPixels > 0, heightInPixels > 0 else { return nil }

        // A bitmap decoded from data carries a `size` in POINTS, derived from
        // whatever DPI the file declared, and `draw(in:)` scales against that.
        // Pinning it to the pixel count is what makes the downscale below mean
        // what it says on a 144-DPI screenshot.
        bitmap.size = NSSize(width: widthInPixels, height: heightInPixels)

        let longestSide = max(widthInPixels, heightInPixels)
        let bitmapToEncode: NSBitmapImageRep
        let outputWidth: Int
        let outputHeight: Int

        if longestSide > longestSideAPastedImageIsSentAt {
            let scale = CGFloat(longestSideAPastedImageIsSentAt) / CGFloat(longestSide)
            outputWidth = max(1, Int((CGFloat(widthInPixels) * scale).rounded()))
            outputHeight = max(1, Int((CGFloat(heightInPixels) * scale).rounded()))
            guard let scaled = redraw(bitmap, atWidth: outputWidth, height: outputHeight) else { return nil }
            bitmapToEncode = scaled
        } else {
            outputWidth = widthInPixels
            outputHeight = heightInPixels
            bitmapToEncode = bitmap
        }

        guard let pngData = bitmapToEncode.representation(using: .png, properties: [:]) else { return nil }
        if pngData.count <= heaviestPNGWorthSending {
            return OverlayEyePastedImage(imageData: pngData, pixelWidth: outputWidth, pixelHeight: outputHeight)
        }

        guard let jpegData = bitmapToEncode.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else {
            // No JPEG encoder for this bitmap: the heavy PNG is still better
            // than refusing the reader's paste.
            return OverlayEyePastedImage(imageData: pngData, pixelWidth: outputWidth, pixelHeight: outputHeight)
        }
        return OverlayEyePastedImage(imageData: jpegData, pixelWidth: outputWidth, pixelHeight: outputHeight)
    }

    private static func redraw(_ bitmap: NSBitmapImageRep, atWidth width: Int, height: Int) -> NSBitmapImageRep? {
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        scaled.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        context.flushGraphics()
        return scaled
    }
}

// MARK: - What the reader has attached

/// The images waiting to ride the next message.
///
/// A short list, not one image: since drag-and-drop, "here are the two
/// screenshots" is an ordinary thing to hand Iris. It is bounded at
/// `OverlayEyePastedImageReader.mostImagesOneMessageMayCarry`; past that the
/// OLDEST is let go, so the reader's latest action always shows up on the bar
/// instead of silently doing nothing.
///
/// They are TAKEN by the send path rather than read, so an image can only ever
/// be sent once. An attachment that survived its own message would silently
/// ride the next question too, which is the same class of surprise as the bar
/// keeping the keyboard after a question was sent.
@MainActor
final class OverlayEyePastedImageAttachment: ObservableObject {

    /// One bar is open at a time, and the things that put an image on it (a
    /// keystroke in that bar's window, a drop on it, the picker) and the thing
    /// that spends them (the next message) are files apart with no object in
    /// common. A shared instance is the seam; it is an ordinary class, so a
    /// test makes its own.
    static let shared = OverlayEyePastedImageAttachment()

    @Published private(set) var theImagesTheReaderAttached: [OverlayEyePastedImage] = []

    /// True while a drag is over the bar, so the bar can say "drop to attach"
    /// before the reader lets go. Set and cleared by the drop target.
    @Published var aDragIsHoveringOverTheBar = false

    init() {}

    var thereIsSomethingAttached: Bool { !theImagesTheReaderAttached.isEmpty }

    func attach(_ image: OverlayEyePastedImage) {
        attach(contentsOf: [image])
    }

    /// Appends, keeping only the newest `mostImagesOneMessageMayCarry`.
    func attach(contentsOf images: [OverlayEyePastedImage]) {
        guard !images.isEmpty else { return }
        var combined = theImagesTheReaderAttached + images
        let overflow = combined.count - OverlayEyePastedImageReader.mostImagesOneMessageMayCarry
        if overflow > 0 {
            combined.removeFirst(overflow)
        }
        theImagesTheReaderAttached = combined
    }

    /// The × on one thumbnail.
    func remove(_ image: OverlayEyePastedImage) {
        theImagesTheReaderAttached.removeAll { $0 == image }
    }

    /// The bar going away.
    func removeAllAttachments() {
        theImagesTheReaderAttached = []
        aDragIsHoveringOverTheBar = false
    }

    /// Hands the images to the message being sent and forgets them in the
    /// same move.
    func takeTheImagesForThisMessage() -> [OverlayEyePastedImage] {
        defer { theImagesTheReaderAttached = [] }
        return theImagesTheReaderAttached
    }
}

// MARK: - The keystroke

enum OverlayEyePasteKeystroke {

    /// Plain cmd-V, and only plain cmd-V.
    ///
    /// shift-cmd-V ("paste and match style") and option-cmd-V are text
    /// operations the reader is asking a text field for; claiming those would
    /// take a keystroke away from the field editor and give nothing back.
    static func isTheCommandVThatPastes(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == .command else { return false }
        return event.charactersIgnoringModifiers?.lowercased() == "v"
    }
}

// MARK: - The interception

/// A zero-size view whose only job is to be in the bar's window when cmd-V
/// arrives.
///
/// `NSWindow` offers a key equivalent to its whole view tree before the main
/// menu's Paste item gets it, so this runs first and decides. It claims the
/// keystroke only when there is actually an image to take — a text paste
/// returns false and reaches the field editor exactly as it always did.
final class SelectionTextFieldImagePasteCatchingView: NSView {

    /// Injectable so a test can exercise the real AppKit traversal without
    /// writing over the reader's own clipboard.
    var pasteboardToRead: () -> NSPasteboard = { .general }

    var attachTheImage: (OverlayEyePastedImage) -> Void = { _ in }

    /// Called when this view leaves its window, which is what `hideInputBar`
    /// does to the whole content view. Dismissing the bar destroys the
    /// exchange; an attachment that outlived it would ride a question the
    /// reader asked later and never see it coming.
    var forgetWhatWasAttached: () -> Void = {}

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard OverlayEyePasteKeystroke.isTheCommandVThatPastes(event) else { return false }
        guard let pastedImage = OverlayEyePastedImageReader.imageOnThePasteboard(pasteboardToRead()) else {
            // No image on the pasteboard: this is an ordinary text paste and
            // is none of our business. Returning false is what keeps it working.
            return false
        }
        attachTheImage(pastedImage)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            forgetWhatWasAttached()
        }
    }
}

struct SelectionTextFieldImagePasteCatcher: NSViewRepresentable {

    let attachment: OverlayEyePastedImageAttachment

    func makeNSView(context: Context) -> SelectionTextFieldImagePasteCatchingView {
        let catcher = SelectionTextFieldImagePasteCatchingView(frame: .zero)
        catcher.attachTheImage = { [attachment] pastedImage in
            attachment.attach(pastedImage)
        }
        catcher.forgetWhatWasAttached = { [attachment] in
            attachment.removeAllAttachments()
        }
        return catcher
    }

    func updateNSView(_ nsView: SelectionTextFieldImagePasteCatchingView, context: Context) {}
}

extension View {

    /// Lets an image pasted while this field's window is key be attached to the
    /// next message instead of being dropped on the floor.
    ///
    /// It rides in `.background`, which takes no layout space and does not
    /// touch the field's focus, submit or styling — the whole point of doing it
    /// this way round rather than replacing the field.
    @MainActor
    func acceptsAnImagePastedIntoTheField(
        attachedTo attachment: OverlayEyePastedImageAttachment = .shared
    ) -> some View {
        background(SelectionTextFieldImagePasteCatcher(attachment: attachment))
    }
}
