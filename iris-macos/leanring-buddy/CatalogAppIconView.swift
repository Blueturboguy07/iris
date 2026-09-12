import AppKit
import ImageIO
import SwiftUI

struct CatalogAppIconView: View {
    let entry: CatalogAppInventoryEntry
    @State private var icon: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.surfaceRaised)
            if let icon {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Text(CatalogAppIconPolicy.fallbackInitial(for: entry.name))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(entry.slug)|\(entry.installedBundlePath ?? "")|\(entry.macCompatibility.rawValue)") {
            icon = nil
            if entry.isInstalled, let installedBundlePath = entry.installedBundlePath {
                icon = NSWorkspace.shared.icon(forFile: installedBundlePath)
                return
            }
            guard entry.macCompatibility.isConfirmedForThisMac,
                  let url = CatalogAppIconPolicy.verifiedIconURL(forSlug: entry.slug),
                  let data = await CatalogAppIconLoader.shared.imageData(for: url),
                  !Task.isCancelled else { return }
            icon = Self.thumbnail(from: data)
        }
    }

    private static func thumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 2048, height <= 2048,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
    }
}
