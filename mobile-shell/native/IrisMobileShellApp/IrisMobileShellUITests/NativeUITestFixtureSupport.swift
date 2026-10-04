import XCTest
import ObjectiveC

// Only the address is used as an association key; its value never changes.
private nonisolated(unsafe) var nativeUITestFixtureSessionKey: UInt8 = 0

// unit m6-mobile-uitests. Shared launch helpers and the accessibility
// identifier contract every file in this target asserts against.
//
// Identifiers below are copied verbatim from
// `docs/plans/20260928-all-routes/design/MOBILE_STORE_DESIGN.md` section 12
// ("Accessibility identifiers (the contract for M6)"), which that document
// states is the fixed contract for this unit. As of 2026-09-28 M2
// (store-layout-implementation, the unit that builds the views these
// identifiers live on and publishes `NativeAccessibilityIdentifiers.swift`)
// has not landed: `docs/plans/20260928-all-routes/M2-*/` does not exist yet
// and no `NativeAccessibilityIdentifiers.swift` is on disk anywhere in
// `mobile-shell/`. Every test in this target therefore fails today with
// "no such element" until M2 lands, which is the expected, honest state for
// UI tests written ahead of their views (this is stated as a fact, not
// hidden, in `HANDOFF.md`). If M2 publishes different literal values, this
// one file is the only place that needs to change: every other file in this
// target goes through `NativeStoreIdentifiers`, never a raw string.
enum NativeStoreIdentifiers {
    // MARK: Tab bar and shell (design 12.1)
    static let tabs = "iris.store.tabs"
    static let tabBrowse = "iris.store.tab.browse"
    static let tabSearch = "iris.store.tab.search"
    static let tabMyApps = "iris.store.tab.my-apps"
    static let tabMyAppsBadge = "iris.store.tab.my-apps.badge"

    // MARK: Home (design 12.2)
    static let home = "iris.store.home"
    static let homeStatus = "iris.store.home.status"
    static let homeRetry = "iris.store.home.retry"
    static let homeSearchEntry = "iris.store.home.search-entry"
    static let homeCategoryRow = "iris.store.home.category-row"
    static let homeCategoryAll = "iris.store.home.category-all"
    static let homeAllApps = "iris.store.home.all-apps"
    static let homeShelfFeatured = "iris.store.home.shelf.featured"
    static let homeShelfFeaturedHow = "iris.store.home.shelf.featured.how"
    static let homeShelfNew = "iris.store.home.shelf.new"
    static let homeShelfNewSeeAll = "iris.store.home.shelf.new.see-all"
    static let homeBrowseAllCategories = "iris.store.home.browse-all-categories"
    static let howWePick = "iris.store.how-we-pick"
    static let howWePickClose = "iris.store.how-we-pick.close"
    static func homeCategoryChip(_ categoryId: Int) -> String { "iris.store.home.category-chip.\(categoryId)" }
    static func homeShelfCategory(_ categoryId: Int) -> String { "iris.store.home.shelf.category.\(categoryId)" }
    static func card(_ slug: String) -> String { "iris.store.card.\(slug)" }
    static func cardGet(_ slug: String) -> String { "iris.store.card.\(slug).get" }
    static func cardSponsored(_ slug: String) -> String { "iris.store.card.\(slug).sponsored" }
    static func cardName(_ slug: String) -> String { "iris.store.card.\(slug).name" }

    // MARK: Search (design 12.3)
    static let searchField = "iris.marketplace.search"
    static let searchClear = "iris.store.search.clear"
    static let searchRecent = "iris.store.search.recent"
    static let searchRecentClear = "iris.store.search.recent-clear"
    static let searchCategories = "iris.store.search.categories"
    static let searchCount = "iris.store.search.count"
    static let searchResults = "iris.store.search.results"
    static let searchZero = "iris.store.search.zero"
    static let searchBrowseAll = "iris.store.search.browse-all"
    static let searchOffline = "iris.store.search.offline"
    static func row(_ slug: String) -> String { "iris.store.row.\(slug)" }
    static func rowGet(_ slug: String) -> String { "iris.store.row.\(slug).get" }
    static func rowNote(_ slug: String) -> String { "iris.store.row.\(slug).note" }

    // MARK: Category and All categories (design 12.4)
    static let category = "iris.store.category"
    static let categoryTitle = "iris.store.category.title"
    static let categoryCount = "iris.store.category.count"
    static let categoryList = "iris.store.category.list"
    static let categoryEmpty = "iris.store.category.empty"
    static let categories = "iris.store.categories"

    // MARK: App page (design 12.5)
    static let app = "iris.store.app"
    static let appIcon = "iris.store.app.icon"
    static let appName = "iris.store.app.name"
    static let appSummary = "iris.store.app.summary"
    static let appFacts = "iris.store.app.facts"
    static let appGet = "iris.store.app.get"
    static let appNote = "iris.store.app.note"
    static let catalogCancel = "iris.catalog.cancel"
    static let catalogRetry = "iris.catalog.retry"
    static let appPermissions = "iris.store.app.permissions"
    static let appScreenshots = "iris.store.app.screenshots"
    static let appDescription = "iris.store.app.description"
    static let appWhatsNew = "iris.store.app.whats-new"
    static let appAgeCheck = "iris.store.app.age-check"
    static let appBlockConfirm = "iris.store.app.block-confirm"
    static let appBlockCancel = "iris.store.app.block-cancel"
    static let appBlockReport = "iris.store.app.block-report"
    static let appDetails = "iris.store.app.details"
    static let appVersionsRow = "iris.store.app.versions-row"
    static let appPermissionsRow = "iris.store.app.permissions-row"
    static let appStorageRow = "iris.store.app.storage-row"
    static let appUnavailable = "iris.store.app.unavailable"

    // MARK: My apps, Versions, Storage, Blocked (design 12.6)
    static let myApps = "iris.store.my-apps"
    static let myAppsMenu = "iris.store.my-apps.menu"
    static let importLocalPackage = "iris.import"
    static let demoReviewV1 = "iris.demo.review-v1"
    static let demoReviewV2 = "iris.demo.review-v2"
    static let storageCheckReview = "iris.storage-check.review"
    static let myAppsUpdateAll = "iris.store.my-apps.update-all"
    static let myAppsUpdateAllNote = "iris.store.my-apps.update-all.note"
    static let myAppsList = "iris.store.my-apps.list"
    static let myAppsStorageLine = "iris.store.my-apps.storage-line"
    static let myAppsBlockedLine = "iris.store.my-apps.blocked-line"
    static let myAppsEmpty = "iris.store.my-apps.empty"
    static let myAppsEmptyBrowse = "iris.store.my-apps.empty.browse"
    static func myAppsRow(_ appId: String) -> String { "iris.store.my-apps.row.\(appId)" }
    static func myAppsRowUpdateBadge(_ appId: String) -> String { "iris.store.my-apps.row.\(appId).update-badge" }
    static func myAppsRowBlockedBadge(_ appId: String) -> String { "iris.store.my-apps.row.\(appId).blocked-badge" }
    static func open(_ appId: String) -> String { "iris.open.\(appId)" }
    static let versions = "iris.store.versions"
    static let versionsExplanation = "iris.store.versions.explanation"
    static func versionsRow(_ revisionId: String) -> String { "iris.store.versions.row.\(revisionId)" }
    static func revert(_ revisionId: String) -> String { "iris.revert.\(revisionId)" }
    static func activate(_ revisionId: String) -> String { "iris.activate.\(revisionId)" }
    static func pin(_ revisionId: String) -> String { "iris.storage.pin.\(revisionId)" }
    static func unpin(_ revisionId: String) -> String { "iris.storage.unpin.\(revisionId)" }
    static let storage = "iris.store.storage"
    static let storageTotalBar = "iris.store.storage.total-bar"
    static let storageTotal = "iris.store.storage.total"
    static let storageDeviceLine = "iris.store.storage.device-line"
    static let storageFreeUp = "iris.store.storage.free-up"
    static let storageFreeUpSub = "iris.store.storage.free-up.sub"
    static let storageResult = "iris.store.storage.result"
    static let storageCap = "iris.store.storage.cap"
    static let storageCapSheet = "iris.store.storage.cap-sheet"
    static let storageEmpty = "iris.store.storage.empty"
    static let storageError = "iris.store.storage.error"
    static let storageLow = "iris.store.storage.low"
    static func storageAppRow(_ appId: String) -> String { "iris.store.storage.app-row.\(appId)" }
    static let blocked = "iris.store.blocked"
    static func blockedRow(_ slug: String) -> String { "iris.store.blocked.row.\(slug)" }
    static func blockedRowUnblock(_ slug: String) -> String { "iris.store.blocked.row.\(slug).unblock" }

    // MARK: Running app and lifecycle (existing, kept)
    static let websitePending = "iris.website.pending"
    static let websiteDismiss = "iris.website.pending.dismiss"
    static let websiteContinue = "iris.website.pending.continue"
}

/// Generated catalog fixture facts every test file needs, kept in one place
/// so a change to `NativeUITestCatalogGenerator`'s naming scheme
/// (`Sources/IrisMobileShellHost/NativeUITestFixtures.swift`) only needs a
/// matching change here.
enum NativeStoreFixtureFacts {
    /// `NativeUITestCatalogGenerator.slug(forIndex:)`. Index 0 exists at
    /// every catalog scale and is never featured or sponsored.
    static func slug(_ index: Int) -> String { String(format: "fixture-app-%04d", index) }
    static func name(_ index: Int) -> String { "Fixture App \(index)" }
    /// Present only when `generatedAppCount >= 13` (`catalog100`,
    /// `catalog1000`): index 1 is featured, index 2 is sponsored.
    static let featuredIndex = 1
    static let sponsoredIndex = 2
    /// `restricted` mode's index-0 row carries `ageRating: 18`.
    static let restrictedIndex = 0
}

extension XCUIApplication {
    /// Keeps one fresh namespace per application instance across relaunches.
    /// Mutation: shared tokens expose prior-test data; new relaunch tokens lose saved names (U17-U33).
    func addFixtureSession() {
        let token: String
        if let stored = objc_getAssociatedObject(self, &nativeUITestFixtureSessionKey) as? String {
            token = stored
        } else {
            token = "s" + UUID().uuidString.lowercased().prefix(12)
            objc_setAssociatedObject(self, &nativeUITestFixtureSessionKey, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let flag = "--iris-ui-test-session"
        if let index = launchArguments.firstIndex(of: flag) {
            if launchArguments.indices.contains(index + 1) {
                launchArguments[index + 1] = token
            } else {
                launchArguments.append(token)
            }
        } else {
            launchArguments.append(contentsOf: [flag, token])
        }
    }

    /// Launches with a UI test fixture mode active (see
    /// `NativeUITestFixtureMode` and `NativeUITestFixtures.launchArgumentFlag`
    /// in `Sources/IrisMobileShellHost/NativeUITestFixtures.swift`). Every
    /// test in this target calls this instead of the bare `launch()`, so no
    /// test ever depends on network state, a developer's own simulator data,
    /// or another test's leftover library.
    /// Mutation: omitting the session pair exposes reused fixture state (U17-U33).
    func launchWithFixtures(_ mode: String) {
        launchArguments = ["--iris-ui-test-fixtures", mode]
        addFixtureSession()
        launch()
    }

    /// Selects one action in the frontmost presentation without adding a wait.
    /// Mutation: a missing alert action cannot be satisfied by a background button (U1, U3-U8).
    func confirmationButton(_ identifierOrLabel: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifierOrLabel, identifierOrLabel)
        let alert = alerts.firstMatch
        if alert.exists {
            return alert.buttons.matching(predicate).firstMatch
        }
        let sheet = sheets.firstMatch
        if sheet.exists {
            return sheet.buttons.matching(predicate).firstMatch
        }
        return buttons.matching(predicate).firstMatch
    }

    /// Reveals a lazy row using bounded scrolling, requiring a tappable result.
    /// Mutation: missing rows and existing but untappable rows still return false (U9-U14).
    @discardableResult
    func scrollUntilExists(_ element: XCUIElement, maxSwipes: Int = 12) -> Bool {
        var wasFound = element.exists
        if wasFound && element.isHittable { return true }
        let container = [scrollViews.firstMatch, collectionViews.firstMatch, tables.firstMatch]
            .first(where: { $0.exists }) ?? windows.firstMatch
        let swipeLimit = max(0, maxSwipes)
        for _ in 0..<swipeLimit {
            container.swipeUp()
            let exists = element.exists
            wasFound = wasFound || exists
            if exists && element.isHittable { return true }
        }
        // A short reverse pass handles a starting position below an unseen row.
        if !wasFound {
            for _ in 0..<min(3, swipeLimit) {
                container.swipeDown()
                let exists = element.exists
                if exists && element.isHittable { return true }
                if exists { break }
            }
        }
        return element.exists && element.isHittable
    }
}

extension XCTestCase {
    /// The wait budget for a fixture-backed catalog request: generation is
    /// in-memory (microseconds), but SwiftUI's own task scheduling and the
    /// simulator's own load under parallel UI test runs both add real,
    /// variable latency, so this is generous on purpose. A test that needs
    /// longer than this for a *local* fixture to render is itself a signal
    /// worth seeing fail, not a flake to paper over with a longer timeout.
    var fixtureWait: TimeInterval { 8 }

    /// Asserts an element exists and is showing the given visible text
    /// (label or value, whichever is non-empty), which is what every test in
    /// this target uses instead of an existence-only assertion: SPEC section
    /// 1 and this unit's brief both forbid "identifier existence alone."
    func assertVisibleText(
        _ element: XCUIElement,
        contains expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: fixtureWait),
            "Expected \(element) to exist before checking its text.",
            file: file, line: line
        )
        let visible = element.label.isEmpty ? (element.value as? String ?? "") : element.label
        XCTAssertTrue(
            visible.contains(expectedSubstring),
            "Expected \"\(visible)\" to contain \"\(expectedSubstring)\".",
            file: file, line: line
        )
    }

    /// Uses the current package's name without imposing the catalog's casing.
    /// Mutation: absent elements and wrong names still fail; casing alone is ignored (U19, U20, U29).
    func assertVisibleText(
        _ element: XCUIElement,
        containsIgnoringCase expectedSubstring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: fixtureWait),
            "Expected \(element) to exist before checking its text.",
            file: file, line: line
        )
        let visible = element.label.isEmpty ? (element.value as? String ?? "") : element.label
        XCTAssertTrue(
            visible.range(of: expectedSubstring, options: .caseInsensitive) != nil,
            "Expected \"\(visible)\" to contain \"\(expectedSubstring)\" ignoring case.",
            file: file, line: line
        )
    }
}

// MARK: Tab bar helper (round 5, RC tab identifiers)

/// The three store tabs. A tab bar button is found by its identifier
/// (`iris.store.tab.*`, set on the tab label leaf) OR its visible label, so a
/// test still finds the tab if an OS release drops the identifier from the
/// system tab bar. The label is what a person reads, so it is a fair query.
enum NativeStoreTab: CaseIterable {
    case browse, search, myApps

    var identifier: String {
        switch self {
        case .browse: return NativeStoreIdentifiers.tabBrowse
        case .search: return NativeStoreIdentifiers.tabSearch
        case .myApps: return NativeStoreIdentifiers.tabMyApps
        }
    }

    var label: String {
        switch self {
        case .browse: return "Browse"
        case .search: return "Search"
        case .myApps: return "My apps"
        }
    }
}

extension XCUIApplication {
    /// Every tab-bar button that is NOT one of the three tabs the store design
    /// allows (MOBILE_STORE_DESIGN.md D1: Browse, Search, My apps, never a
    /// fourth). A button counts as one of the three when its identifier is the
    /// tab's identifier, or its label is the tab's name (a badge makes the
    /// system read "My apps, 2 updates", so a label prefix "<name>," counts).
    /// Empty means exactly the spec'd tabs are on screen.
    func strayTabBarButtons() -> [XCUIElement] {
        tabBars.buttons.allElementsBoundByIndex.filter { button in
            !NativeStoreTab.allCases.contains { tab in
                button.identifier == tab.identifier
                    || button.label == tab.label
                    || button.label.hasPrefix(tab.label + ",")
            }
        }
    }

    func storeTab(_ tab: NativeStoreTab) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", tab.identifier, tab.label)
        return tabBars.buttons.matching(predicate).firstMatch
    }
}

extension XCUIElement {
    /// A container or leaf by identifier, of ANY element type. Containers the
    /// app marks `.accessibilityElement(children: .contain)` read as Group (not
    /// Other) to XCUITest, so a type-specific query such as `otherElements[id]`
    /// missed them: this was a main cause of the first Simulator run passing
    /// only 10 of 54 tests. The first match is used so a container that shares
    /// its identifier with a child never fails the query as ambiguous.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
