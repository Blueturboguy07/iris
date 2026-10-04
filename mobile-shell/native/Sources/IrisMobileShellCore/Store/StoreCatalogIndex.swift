import Foundation

// Unit M2-store-layout-implementation (route R8). The store's in-memory view
// of the catalog: index v2 rows from M3's loader, or today's v1 rows when
// Publik has not published index v2 yet. Pure values, no network, no disk.

/// One app as the store shows it on cards, rows and the page header.
public struct StoreApp: Equatable, Sendable, Identifiable {
    public let slug: String
    public let name: String
    /// At most 80 characters (index v2). Empty for v1 rows, which carry none.
    public let summary: String
    public let categoryIds: [Int]
    public let iconHash: String?
    public let iconURL: URL?
    public let byteCount: Int?
    /// Index v2 `ageRating`, or the v1 descriptor's `appStoreMetadata.ageRating`.
    public let ageRating: Int?
    /// `YYYY-MM-DD` (index v2) or empty. ISO dates sort as strings.
    public let updatedAt: String
    public let badges: [String]
    public let isFeatured: Bool
    public let isSponsored: Bool
    public let placementLabel: String?
    /// Position in the catalog (page order, then row order). Shelves and
    /// category pages keep this order; sponsored rows never move.
    public let catalogOrder: Int
    /// Present for v1 rows (the installable descriptor), nil for index v2
    /// rows until the app page is fetched.
    public let descriptor: PublikMobileShellDescriptor?
    /// R2-CP-3: index v2's own optional `latestRevisionId` (nil for v1 rows
    /// and for an index published before this field existed). Lets My apps
    /// show "Update available" for an installed app without a page fetch;
    /// see `StoreModel.hasListedUpdate(for:)`.
    public let latestRevisionId: String?
    /// RC-05: who made the app, from the index row (`publisher`), or
    /// `defaultPublisher` when the row carries none (older index, v1 rows).
    public let publisher: String

    /// Every app in the catalog today is Publik's own (apple-compliance
    /// DECISIONS.md OD-16), so a row with no `publisher` reads "By Publik".
    public static let defaultPublisher = "Publik"

    /// The plain line shown under the app name and on the consent sheet.
    public static func byLine(publisher: String) -> String { "By \(publisher)" }
    public var byLine: String { Self.byLine(publisher: publisher) }

    /// A publisher name is 1 to 80 characters after trimming, on one line, with
    /// no control characters and no angle brackets.
    public static func isValidPublisherName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed == value, !trimmed.isEmpty, trimmed.count <= 80 else { return false }
        return !trimmed.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "<" || $0 == ">" }
    }

    public var id: String { slug }
    public var isNewOrUpdated: Bool { badges.contains("new") || badges.contains("updated") }

    public init(
        slug: String,
        name: String,
        summary: String,
        categoryIds: [Int],
        iconHash: String?,
        iconURL: URL?,
        byteCount: Int?,
        ageRating: Int?,
        updatedAt: String,
        badges: [String],
        isFeatured: Bool,
        isSponsored: Bool,
        placementLabel: String?,
        catalogOrder: Int,
        descriptor: PublikMobileShellDescriptor?,
        latestRevisionId: String? = nil,
        publisher: String? = nil
    ) {
        self.slug = slug
        self.name = name
        self.summary = summary
        self.categoryIds = categoryIds
        self.iconHash = iconHash
        self.iconURL = iconURL
        self.byteCount = byteCount
        self.ageRating = ageRating
        self.updatedAt = updatedAt
        self.badges = badges
        self.isFeatured = isFeatured
        self.isSponsored = isSponsored
        self.placementLabel = placementLabel
        self.catalogOrder = catalogOrder
        self.descriptor = descriptor
        self.latestRevisionId = latestRevisionId
        self.publisher = publisher.flatMap { Self.isValidPublisherName($0) ? $0 : nil } ?? Self.defaultPublisher
    }

    public init(indexRow row: PublikMobileCatalogIndexAppV2, catalogOrder: Int) {
        self.init(
            slug: row.slug,
            name: row.name,
            summary: row.summary,
            categoryIds: row.categoryIds,
            iconHash: row.iconHash,
            iconURL: row.iconURL,
            byteCount: row.byteCount,
            ageRating: row.ageRating,
            updatedAt: row.updatedAt,
            badges: row.badges,
            isFeatured: row.placement?.featured ?? false,
            isSponsored: row.placement?.sponsored ?? false,
            placementLabel: row.placement.flatMap { $0.label.isEmpty ? nil : $0.label },
            catalogOrder: catalogOrder,
            descriptor: nil,
            latestRevisionId: row.latestRevisionId,
            publisher: row.publisher
        )
    }

    public init(legacyRow row: PublikMobileCatalogApp, catalogOrder: Int) {
        self.init(
            slug: row.slug,
            name: row.name,
            summary: "",
            categoryIds: [],
            iconHash: nil,
            iconURL: nil,
            byteCount: row.mobileShell?.byteCount,
            ageRating: row.mobileShell?.appStoreMetadata?.ageRating,
            updatedAt: "",
            badges: [],
            isFeatured: false,
            isSponsored: false,
            placementLabel: nil,
            catalogOrder: catalogOrder,
            descriptor: row.mobileShell,
            latestRevisionId: row.mobileShell?.revisionId
        )
    }
}

public struct StoreCategory: Equatable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public let order: Int
    /// `categories.json` count: correct before every index page has landed.
    public let publishedAppCount: Int

    public init(id: Int, name: String, order: Int, publishedAppCount: Int) {
        self.id = id
        self.name = name
        self.order = order
        self.publishedAppCount = publishedAppCount
    }
}

/// Where the rows came from; drives the status line and the partial-list footer.
public enum StoreCatalogSource: Equatable, Sendable {
    case none
    case indexV2(generatedAt: String, loadedPages: Int, pageCount: Int)
    case legacy
}

public struct StoreCatalogIndex: Sendable {
    public let source: StoreCatalogSource
    /// Every row in catalog order, hidden ones included (a link to a blocked
    /// app still lands on its page).
    public let allApps: [StoreApp]
    /// Rows Browse, Search and category pages may show, in catalog order.
    public let visibleApps: [StoreApp]
    /// Categories in catalog `order`.
    public let categories: [StoreCategory]
    private let slugPosition: [String: Int]
    private let visibleSlugs: Set<String>
    private let visibleByCategory: [Int: [Int]]

    public static let empty = StoreCatalogIndex(source: .none, apps: [], categories: [], hiddenSlugs: [])

    public init(source: StoreCatalogSource, apps: [StoreApp], categories: [StoreCategory], hiddenSlugs: Set<String>) {
        self.source = source
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.slug).inserted }
        allApps = unique
        var position: [String: Int] = [:]
        for (offset, app) in unique.enumerated() { position[app.slug] = offset }
        slugPosition = position
        let visible = unique.filter { !hiddenSlugs.contains($0.slug) }
        visibleApps = visible
        visibleSlugs = Set(visible.map(\.slug))
        var byCategory: [Int: [Int]] = [:]
        for (offset, app) in visible.enumerated() {
            for id in Set(app.categoryIds) { byCategory[id, default: []].append(offset) }
        }
        visibleByCategory = byCategory
        self.categories = categories.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// Index v2: every loaded page, in order, plus `categories.json`.
    public init(snapshot: PublikMobileCatalogV2Snapshot, categories: [PublikMobileCatalogCategoryV2], hiddenSlugs: Set<String>) {
        let apps = snapshot.apps.enumerated().map { StoreApp(indexRow: $0.element, catalogOrder: $0.offset) }
        self.init(
            source: .indexV2(generatedAt: snapshot.generatedAt, loadedPages: snapshot.pages.count, pageCount: snapshot.pageCount),
            apps: apps,
            categories: categories.map { StoreCategory(id: $0.id, name: $0.name, order: $0.order, publishedAppCount: $0.appCount) },
            hiddenSlugs: hiddenSlugs
        )
    }

    /// Fallback while index v2 is not published: today's v1 rows, curated by
    /// the same Browse policy as before (launch identities, iPhone only).
    public init(legacyRows: [PublikMobileCatalogApp], hiddenSlugs: Set<String>) {
        let rows = legacyRows.filter(NativeMobileMarketplacePolicy.isVisibleInBrowse)
        self.init(
            source: .legacy,
            apps: rows.enumerated().map { StoreApp(legacyRow: $0.element, catalogOrder: $0.offset) },
            categories: [],
            hiddenSlugs: hiddenSlugs
        )
    }

    /// True once every index page of the publish is in memory (always true
    /// for v1 rows).
    public var isComplete: Bool {
        if case .indexV2(_, let loaded, let count) = source { return loaded >= count }
        return true
    }

    public func app(slug: String) -> StoreApp? {
        slugPosition[slug].map { allApps[$0] }
    }

    public func isVisible(slug: String) -> Bool {
        visibleSlugs.contains(slug)
    }

    /// Visible apps in one category, catalog order.
    public func apps(inCategory id: Int) -> [StoreApp] {
        (visibleByCategory[id] ?? []).map { visibleApps[$0] }
    }

    /// The count a person sees next to a category. Before every page has
    /// landed it is Publik's published count; once the whole list is in
    /// memory it is the number of rows the category page will really show
    /// (blocked apps are not counted, so the number never overpromises).
    public func displayCount(forCategory id: Int) -> Int {
        let loaded = visibleByCategory[id]?.count ?? 0
        guard !isComplete, let category = categories.first(where: { $0.id == id }) else { return loaded }
        return max(loaded, category.publishedAppCount)
    }

    /// Categories that have at least one app to show, catalog order.
    public var nonEmptyCategories: [StoreCategory] {
        categories.filter { displayCount(forCategory: $0.id) > 0 }
    }

    public func category(id: Int) -> StoreCategory? {
        categories.first { $0.id == id }
    }

    public func categoryNames(for app: StoreApp) -> [String] {
        app.categoryIds.compactMap { id in categories.first { $0.id == id }?.name }
    }
}
