import Foundation

/// Browse curation, not package validation or an installed-library restriction.
/// Add future launch identities here after mobile review. Direct website links
/// remain eligible for the normal descriptor/package verification flow.
public enum NativeMobileMarketplacePolicy {
    public static let launchAppIDs: Set<String> = [
        "publik.kneecap", "publik.nut-ai", "publik.freeharmony", "publik.lunara",
    ]

    /// Input comes from the validated catalog client. A name, website listing,
    /// or marketing OS label alone cannot make an app available in Browse.
    public static func isVisibleInBrowse(_ app: PublikMobileCatalogApp) -> Bool {
        guard let descriptor = app.mobileShell else { return false }
        return descriptor.platform == "ios" && launchAppIDs.contains(descriptor.appId)
    }

    public static func actionLabel(for app: PublikMobileCatalogApp,
                                   installedRevisionID: String?) -> String {
        guard let descriptor = app.mobileShell else { return "Not available on mobile" }
        guard let installedRevisionID else { return "Get app" }
        if installedRevisionID == descriptor.revisionId { return "Open" }
        return descriptor.baseRevisionId == installedRevisionID ? "Review update" : "Check version"
    }

    // --- Unit m3-guideline47: Guideline 4.7.1 / 4.7.5 Browse-time gating ---

    /// One reason Browse/My apps or a universal link must refuse to open an
    /// app. `blocked` (4.7.1's "ability to block abusive users") always wins
    /// over `ageRestricted` (4.7.5) when both apply, since a person who
    /// blocked an app gets that exact outcome regardless of who is holding
    /// the phone.
    public enum Review47Restriction: Equatable, Sendable {
        case blocked
        case ageRestricted(appAgeRating: Int, declaredAge: Int?)
    }

    /// Pure combination of the block list and age gate decisions. Absent
    /// Guideline 4.7 metadata (`app.mobileShell?.appStoreMetadata == nil`)
    /// never age-restricts by itself: see `Review47AgeGate.decide`.
    public static func review47Restriction(
        for app: PublikMobileCatalogApp,
        isBlocked: Bool,
        declaredAge: Int?
    ) -> Review47Restriction? {
        if isBlocked { return .blocked }
        let appAgeRating = app.mobileShell?.appStoreMetadata?.ageRating
        switch Review47AgeGate.decide(appAgeRating: appAgeRating, declaredAge: declaredAge) {
        case .allowed:
            return nil
        case .restricted(let appAgeRating, let declaredAge):
            return .ageRestricted(appAgeRating: appAgeRating, declaredAge: declaredAge)
        }
    }
}
