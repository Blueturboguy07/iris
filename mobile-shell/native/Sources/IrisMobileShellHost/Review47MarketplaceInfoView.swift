#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit m3-guideline47: the Browse-time privacy summary, age-rating badge,
/// report link and block toggle for one catalog app. Guideline 4.7.1's
/// privacy summary and report mechanism, and 4.7.5's "way for users to
/// identify software that exceeds the app's age rating" (verbatim text
/// checked 2026-09-27 against
/// https://developer.apple.com/app-store/review/guidelines/).
struct Review47AppStoreInfoView: View {
    @ObservedObject var model: NativeShellCatalogModel
    let app: PublikMobileCatalogApp

    private var metadata: Review47AppStoreMetadata? {
        app.mobileShell?.appStoreMetadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let metadata {
                Text("Age rating: \(metadata.ageRating)+")
                    .font(.caption)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47AgeRating(app.slug))
                Text(metadata.privacySummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47PrivacySummary(app.slug))
                HStack(spacing: 12) {
                    if let target = model.review47ReportTarget(for: app) {
                        Link("Report this app", destination: target.url)
                            .font(.caption)
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47Report(app.slug))
                    }
                    Button(model.review47Restriction(for: app) == .blocked ? "Unblock" : "Block") {
                        model.review47ToggleBlock(app)
                    }
                        .font(.caption)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47BlockToggle(app.slug))
                }
            } else {
                Text("Age rating and privacy information have not been published for this app yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47NotRated(app.slug))
            }
        }
    }

    static func restrictionMessage(_ restriction: NativeMobileMarketplacePolicy.Review47Restriction) -> String {
        switch restriction {
        case .blocked:
            return "You blocked this app on this device. Unblock it above to install or open it again."
        case .ageRestricted(let appAgeRating, let declaredAge):
            return Review47AgeGateCopy.message(appAgeRating: appAgeRating, declaredAge: declaredAge)
        }
    }
}
#endif
