import CoreGraphics
import Foundation

// Round 6, store-proportions. Test author file (spec only).
//
// Pure pixel measuring, no XCTest, no UIKit: the UI tests in
// `StoreProportionsUITests.swift` take an `XCUIScreenshot`, hand its CGImage
// to `StorePixelImage`, and measure what a person would see (the drawn size of
// a capsule, an icon, a blue slab). An element frame cannot show the drawn
// capsule when the tap area is taller than the capsule (SPEC.md line 95), so
// the drawn size has to come from pixels.
//
// This file has no dependency on the app or on XCTest, so the same source is
// compiled by a macOS harness for the mutation check of the measuring code
// itself (see TESTS.md). `StoreMeasureSelfCheck.run()` is the oracle for the
// measurer: it paints shapes of a known size into a synthetic image and checks
// the measurer reads the known size back.
//
// Coordinates are points with the origin at the top left, the same space as
// `XCUIElement.frame`.

struct StoreRGB: Equatable {
    var r: Int
    var g: Int
    var b: Int

    /// Largest per-channel difference (0 to 255).
    func distance(to other: StoreRGB) -> Int {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
    }

    var luminance: Double { (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255 }

    /// The `electric` brand blue (#315CF5) and anything close to a saturated blue fill.
    var isSolidBlue: Bool { b > 190 && r < 120 && g < 150 && b - r > 100 }
}

struct StorePixelImage {
    let width: Int
    let height: Int
    let pixelsPerPoint: CGFloat
    private var bytes: [UInt8]

    /// Draws `cgImage` into an RGBA buffer. Returns nil when the bitmap context cannot be made.
    init?(cgImage: CGImage, pixelsPerPoint: CGFloat) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0, pixelsPerPoint > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        var drawn = false
        data.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            drawn = true
        }
        guard drawn else { return nil }
        self.width = w
        self.height = h
        self.pixelsPerPoint = pixelsPerPoint
        self.bytes = data
    }

    /// A blank synthetic image (used by the self-check only).
    init(width: Int, height: Int, pixelsPerPoint: CGFloat, background: StoreRGB) {
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        var data = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            data[i * 4] = UInt8(background.r)
            data[i * 4 + 1] = UInt8(background.g)
            data[i * 4 + 2] = UInt8(background.b)
        }
        self.bytes = data
    }

    /// Fills whole pixels covering `rect` (points) with a flat colour. Self-check only.
    mutating func paint(_ rect: CGRect, _ color: StoreRGB) {
        let box = pixelBox(rect)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return }
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(color.r)
                bytes[i + 1] = UInt8(color.g)
                bytes[i + 2] = UInt8(color.b)
            }
        }
    }

    var sizeInPoints: CGSize {
        CGSize(width: CGFloat(width) / pixelsPerPoint, height: CGFloat(height) / pixelsPerPoint)
    }

    func rgb(px x: Int, _ y: Int) -> StoreRGB {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let i = (cy * width + cx) * 4
        return StoreRGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    func rgb(atPoint p: CGPoint) -> StoreRGB {
        rgb(px: Int((p.x * pixelsPerPoint).rounded(.down)), Int((p.y * pixelsPerPoint).rounded(.down)))
    }

    /// Whole-pixel box covering `rect`, clamped to the image. `x1` and `y1` are exclusive.
    func pixelBox(_ rect: CGRect) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let x0 = max(0, Int((rect.minX * pixelsPerPoint).rounded(.down)))
        let y0 = max(0, Int((rect.minY * pixelsPerPoint).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * pixelsPerPoint).rounded(.up)))
        let y1 = min(height, Int((rect.maxY * pixelsPerPoint).rounded(.up)))
        return (x0, y0, x1, y1)
    }

    /// The colour of the surface around a control: the median of the pixels on the
    /// outer edge of `rect`. Pass a rect that is a little bigger than the control so the
    /// edge is empty background.
    func backgroundColor(around rect: CGRect) -> StoreRGB {
        let box = pixelBox(rect)
        guard box.x1 - box.x0 >= 2, box.y1 - box.y0 >= 2 else { return rgb(px: box.x0, box.y0) }
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        func take(_ x: Int, _ y: Int) {
            let c = rgb(px: x, y)
            rs.append(c.r); gs.append(c.g); bs.append(c.b)
        }
        for x in box.x0..<box.x1 { take(x, box.y0); take(x, box.y1 - 1) }
        for y in box.y0..<box.y1 { take(box.x0, y); take(box.x1 - 1, y) }
        func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
        return StoreRGB(r: median(rs), g: median(gs), b: median(bs))
    }

    /// Bounding box, in points, of every pixel inside `rect` whose colour differs from
    /// `background` by more than `threshold` on any channel. Nil when nothing is drawn there.
    func inkBounds(in rect: CGRect, background: StoreRGB, threshold: Int = 6) -> CGRect? {
        let box = pixelBox(rect)
        guard box.x1 > box.x0, box.y1 > box.y0 else { return nil }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in box.y0..<box.y1 {
            for x in box.x0..<box.x1 where rgb(px: x, y).distance(to: background) > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        let s = pixelsPerPoint
        return CGRect(
            x: CGFloat(minX) / s,
            y: CGFloat(minY) / s,
            width: CGFloat(maxX - minX + 1) / s,
            height: CGFloat(maxY - minY + 1) / s
        )
    }

    func hasInk(in rect: CGRect, background: StoreRGB, threshold: Int = 6) -> Bool {
        inkBounds(in: rect, background: background, threshold: threshold) != nil
    }

    /// Connected areas of pixels for which `isSolid` is true, as point rects. Only areas whose
    /// box is at least `minWidth` by `minHeight` points, at least `minAspect` times wider than
    /// tall (a capsule or a bar, not a square icon) and at least `minFill` full are returned.
    func solidBlobs(
        minWidth: CGFloat,
        minHeight: CGFloat,
        minAspect: CGFloat,
        minFill: Double,
        isSolid: (StoreRGB) -> Bool
    ) -> [CGRect] {
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where isSolid(rgb(px: x, y)) { mask[y * width + x] = true }
        }
        var seen = [Bool](repeating: false, count: width * height)
        var found: [CGRect] = []
        var stack: [Int] = []
        let s = pixelsPerPoint
        for start in 0..<(width * height) where mask[start] && !seen[start] {
            var minX = width, minY = height, maxX = -1, maxY = -1, count = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                if x > 0, mask[index - 1], !seen[index - 1] { seen[index - 1] = true; stack.append(index - 1) }
                if x < width - 1, mask[index + 1], !seen[index + 1] { seen[index + 1] = true; stack.append(index + 1) }
                if y > 0, mask[index - width], !seen[index - width] { seen[index - width] = true; stack.append(index - width) }
                if y < height - 1, mask[index + width], !seen[index + width] { seen[index + width] = true; stack.append(index + width) }
            }
            let w = CGFloat(maxX - minX + 1) / s
            let h = CGFloat(maxY - minY + 1) / s
            let fill = Double(count) / Double((maxX - minX + 1) * (maxY - minY + 1))
            if w >= minWidth, h >= minHeight, w / h >= minAspect, fill >= minFill {
                found.append(CGRect(x: CGFloat(minX) / s, y: CGFloat(minY) / s, width: w, height: h))
            }
        }
        return found
    }
}

/// The oracle for the measurer. It paints shapes of a known size into synthetic images at two
/// screen scales and checks the measurer reads the known size back. Returns the list of failures
/// (empty means the measurer is trustworthy).
enum StoreMeasureSelfCheck {
    static func run() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ message: String) { if !ok { failures.append(message) } }
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat) -> Bool { abs(a - b) <= tolerance }

        let paper = StoreRGB(r: 248, g: 248, b: 250)
        let tonal = StoreRGB(r: 238, g: 240, b: 245)
        let blue = StoreRGB(r: 49, g: 92, b: 245)

        for scale in [2 as CGFloat, 3] {
            var image = StorePixelImage(width: Int(402 * scale), height: Int(874 * scale), pixelsPerPoint: scale, background: paper)
            let tonalCapsule = CGRect(x: 314, y: 200, width: 72, height: 30)
            let blueBar = CGRect(x: 16, y: 400, width: 96, height: 32)
            let blueIcon = CGRect(x: 200, y: 500, width: 56, height: 56)
            let blueBlock = CGRect(x: 250, y: 650, width: 70, height: 70)   // big enough, but square: not a capsule or bar
            let slateBar = CGRect(x: 16, y: 300, width: 96, height: 32)     // dark and bluish, but not the brand blue
            image.paint(tonalCapsule, tonal)
            image.paint(blueBar, blue)
            image.paint(blueIcon, blue)
            image.paint(blueBlock, blue)
            image.paint(slateBar, StoreRGB(r: 60, g: 70, b: 120))
            // a stray dark dot on the very first pixel of a crop edge must not change the surface colour (median, not first pixel)
            let dotCrop = CGRect(x: 30, y: 780, width: 60, height: 40)
            image.paint(CGRect(x: 30, y: 780, width: 1, height: 1), StoreRGB(r: 0, g: 0, b: 0))

            // 1. The drawn capsule inside a bigger tap frame reads back at its drawn size.
            let tapFrame = CGRect(x: 314, y: 193, width: 72, height: 44)
            let crop = tapFrame.insetBy(dx: -8, dy: -8)
            let bg = image.backgroundColor(around: crop)
            expect(bg.distance(to: paper) == 0, "scale \(scale): background read as \(bg), expected paper")
            let dotBg = image.backgroundColor(around: dotCrop)
            expect(dotBg.distance(to: paper) == 0, "scale \(scale): a stray pixel on the crop edge changed the surface colour to \(dotBg)")
            if let bounds = image.inkBounds(in: crop, background: bg) {
                expect(near(bounds.height, 30, 0.05), "scale \(scale): capsule height read as \(bounds.height), expected 30")
                expect(near(bounds.width, 72, 0.05), "scale \(scale): capsule width read as \(bounds.width), expected 72")
                expect(near(bounds.minX, 314, 0.05), "scale \(scale): capsule left edge read as \(bounds.minX), expected 314")
                expect(near(bounds.minY, 200, 0.05), "scale \(scale): capsule top edge read as \(bounds.minY), expected 200")
            } else {
                failures.append("scale \(scale): no ink found for a painted capsule")
            }

            // 2. Fill colour sampling reads the fill, not the paper.
            let fill = image.rgb(atPoint: CGPoint(x: 319, y: 215))
            expect(fill == tonal, "scale \(scale): fill sampled as \(fill), expected the tonal fill")

            // 3. An empty area has no ink.
            let empty = CGRect(x: 100, y: 700, width: 100, height: 40)
            expect(!image.hasInk(in: empty, background: paper), "scale \(scale): empty area reported ink")

            // 4. A colour only 3 levels off the paper is not ink (threshold), 20 levels off is.
            var faint = image
            faint.paint(CGRect(x: 10, y: 10, width: 20, height: 20), StoreRGB(r: 245, g: 245, b: 247))
            faint.paint(CGRect(x: 60, y: 10, width: 20, height: 20), StoreRGB(r: 228, g: 228, b: 230))
            expect(!faint.hasInk(in: CGRect(x: 5, y: 5, width: 30, height: 30), background: paper), "scale \(scale): a 3 level difference counted as ink")
            expect(faint.hasInk(in: CGRect(x: 55, y: 5, width: 30, height: 30), background: paper), "scale \(scale): a 20 level difference was not seen")

            // 5. Blob finder: the blue bar is one slab, the blue square icon and the tonal capsule are not.
            let blobs = image.solidBlobs(minWidth: 60, minHeight: 24, minAspect: 2, minFill: 0.6) { $0.isSolidBlue }
            expect(blobs.count == 1, "scale \(scale): expected 1 blue slab, found \(blobs.count)")
            if let slab = blobs.first {
                expect(near(slab.width, 96, 0.05) && near(slab.height, 32, 0.05), "scale \(scale): blue slab read as \(slab.width) x \(slab.height), expected 96 x 32")
            }
            expect(!tonal.isSolidBlue && !paper.isSolidBlue && blue.isSolidBlue, "scale \(scale): isSolidBlue misclassified a colour")

            // 6. Two separate slabs are two blobs, and text-like holes (white pixels) inside still count as one slab.
            var twoSlabs = image
            twoSlabs.paint(CGRect(x: 16, y: 600, width: 96, height: 32), blue)
            twoSlabs.paint(CGRect(x: 50, y: 610, width: 24, height: 10), StoreRGB(r: 255, g: 255, b: 255))
            let two = twoSlabs.solidBlobs(minWidth: 60, minHeight: 24, minAspect: 2, minFill: 0.6) { $0.isSolidBlue }
            expect(two.count == 2, "scale \(scale): expected 2 blue slabs, found \(two.count)")
        }
        return failures
    }
}
