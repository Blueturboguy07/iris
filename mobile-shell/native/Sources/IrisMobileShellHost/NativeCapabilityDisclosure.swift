#if os(iOS)
import SwiftUI

/// One shared explanation for website and local setup. It describes declared
/// access; it never turns installation into a grant for camera or all Photos.
struct NativeCapabilityDisclosure: View {
    let capabilities: [String]
    /// The store app page (SPEC 4.5): titles are 15 semibold sub-items, the
    /// explanation is indented under the icon. Other screens keep the
    /// original look.
    var compact = false
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if capabilities.contains("web.storage") {
                block("Saves its own app data", systemImage: "internaldrive",
                      text: "Kept separate from other apps. Updating or switching versions does not erase it; older versions still need to understand that data.")
            }
            if capabilities.contains("web.media.photo-picker") {
                block("Photos and videos you select", systemImage: "photo.on.rectangle",
                      text: "The system picker shares only your selected items, not your whole library. You can cancel. Temporary imports are cleared when this app view closes.")
            }
            if capabilities.contains("web.media.export") {
                block("Save media you create", systemImage: "square.and.arrow.up",
                      text: "The app can offer a system Save dialog for media up to 32 MB. You choose where to save or cancel; the app cannot choose a destination or access other files.",
                      identifier: "iris.review.media-export")
            }
            if capabilities.contains("web.media.camera") {
                block("Camera, when you choose to use it", systemImage: "camera",
                      text: "Your phone asks when the app first uses the camera. Installation does not turn it on or grant microphone access.")
            }
            if capabilities.isEmpty {
                Text("No persistent app storage or phone permissions requested.")
                    .font(.footnote)
            }
            Text("No account or usage tracking is required for setup.")
                .font(.footnote).foregroundStyle(compact ? NativeMarketplaceStyle.fog : Color.secondary)
        }
        .accessibilityIdentifier("iris.review.capabilities")
    }

    @ViewBuilder private func block(_ title: String, systemImage: String, text: String, identifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 12) {
            Label { Text(title) } icon: {
                Image(systemName: systemImage)
                    .font(compact ? .title3 : .headline)
                    .frame(width: compact ? iconWidth : nil)
            }
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            if let identifier {
                explanation(text).accessibilityIdentifier(identifier)
            } else {
                explanation(text)
            }
        }
    }

    private func explanation(_ text: String) -> some View {
        Text(text).font(.footnote)
            .foregroundStyle(compact ? NativeMarketplaceStyle.fog : Color.secondary)
            .padding(.leading, compact ? iconWidth + 8 : 0)
            .fixedSize(horizontal: false, vertical: compact)
    }
}
#endif
