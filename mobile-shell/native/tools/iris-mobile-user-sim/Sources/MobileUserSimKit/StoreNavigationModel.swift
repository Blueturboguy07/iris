import Foundation

/// The tap sequence a person needs today to find a named app by partial
/// name and install it, read off the real Host view
/// (mobile-shell/native/Sources/IrisMobileShellHost/NativeShellAppView.swift):
/// a Browse/My apps tab bar and one `TextField("Search apps", text:
/// $searchText)` (line 962) above the results grid, then a per-row Get
/// button. This enum exists so a scenario's tap-budget oracle is computed
/// from a single named, auditable model instead of a magic number buried in
/// the scenario body, and so a future UI change (that adds or removes a
/// step) is caught by updating one place.
public enum StoreNavigationModel {
    public enum Step: String, Sendable {
        case openBrowseTab = "tap the Browse tab"
        case tapSearchField = "tap the search field"
        case tapResultRow = "tap the matching result row"
        case tapGet = "tap Get"
    }

    /// P1 starts on Browse already showing a grid (no tab tap needed if
    /// already there); this harness always starts a fresh run on Browse
    /// (`RunEnvironment` never selects My apps), so the model counts all
    /// four steps as the worst case a non-technical person is assumed to
    /// need, matching the plan's "tap budget 4 or fewer".
    public static let findAndInstallByPartialName: [Step] = [
        .openBrowseTab, .tapSearchField, .tapResultRow, .tapGet,
    ]

    public static var findAndInstallTapCount: Int { findAndInstallByPartialName.count }
}
