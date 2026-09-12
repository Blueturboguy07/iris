import AppKit
import Foundation
@testable import IrisHarnessNative

@main struct ImageInputBoundaryChecks {
    @MainActor static func main() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "ImageInputBoundaryChecks", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let reader = OverlayEyePastedImageReader.self
        try require(!reader.inputPixelDimensionsAreWithinBounds(width: Int.max, height: Int.max), "overflow dimensions admitted")
        try require(!reader.inputPixelDimensionsAreWithinBounds(width: 16384, height: 16384), "oversized raster admitted")
        try require(!reader.inputPixelDimensionsAreWithinBounds(width: 0, height: 1), "empty raster admitted")
        try require(reader.imagePixelDimensions(in: Data("not an image".utf8)) == nil, "malformed image admitted")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        guard let image = reader.sendableImage(from: png) else { throw NSError(domain: "valid PNG rejected", code: 1) }
        try require(image.pixelWidth == 2 && image.pixelHeight == 2, "valid image dimensions changed")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-image-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("oversized.png")
        try png.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(reader.maximumInputDataBytes + 1))
        try handle.close()
        try require(reader.imagesInFiles([file]).isEmpty, "oversized sparse file read as image")
        print("PASS image metadata, pixel bounds, valid PNG and oversized-file refusal")

        let attachments = OverlayEyePastedImageAttachment()
        let askDrop = attachments.captureDestination()
        attachments.switchComposerMode(isAsking: false)
        attachments.attach(image, to: askDrop)
        try require(!attachments.thereIsSomethingAttached && attachments.generalHelpHasAttachments,
                    "late Ask image crossed into Edit")
        attachments.switchComposerMode(isAsking: true)
        try require(attachments.theImagesTheReaderAttached == [image], "Ask drop was lost")
        let staleDrop = attachments.captureDestination()
        attachments.clearGeneralHelpAttachments()
        attachments.attach(image, to: staleDrop)
        try require(!attachments.thereIsSomethingAttached, "old drop populated new chat")
        let pendingAtSend = attachments.captureDestination()
        _ = attachments.takeTheImagesForThisMessage()
        attachments.attach(image, to: pendingAtSend)
        try require(!attachments.thereIsSomethingAttached, "old drop populated next message")
        attachments.switchComposerMode(isAsking: false)
        let editDrop = attachments.captureDestination()
        attachments.switchComposerMode(isAsking: true)
        attachments.attach(image, to: editDrop)
        try require(!attachments.thereIsSomethingAttached && attachments.editModeHasAttachments,
                    "late Edit image crossed into Ask")
        print("PASS delayed image ownership, New chat and send invalidation")
    }
}
