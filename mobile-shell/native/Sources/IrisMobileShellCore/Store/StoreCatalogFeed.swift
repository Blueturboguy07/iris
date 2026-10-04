import Foundation

// Unit M2-store-layout-implementation. How Browse gets its rows (SPEC R8.1,
// design 3.4 and 10): paint from disk first, then one conditional check;
// never a blank screen, and always one plain status line saying how fresh
// the list is. Uses M3's loader, client and cache unchanged.

public struct StoreCatalogLoad: Sendable {
    public let snapshot: PublikMobileCatalogV2Snapshot?
    public let legacyRows: [PublikMobileCatalogApp]?
    public let categories: [PublikMobileCatalogCategoryV2]
    /// Seed catalog only (`StoreCatalogSeed`): each seed row's install
    /// descriptor. Empty for every network or disk load.
    public let seedDescriptors: [String: PublikMobileShellDescriptor]

    /// True when these rows are the seed that ships inside Iris.
    public var isBundledSeed: Bool { !seedDescriptors.isEmpty }

    public init(snapshot: PublikMobileCatalogV2Snapshot?, legacyRows: [PublikMobileCatalogApp]?, categories: [PublikMobileCatalogCategoryV2], seedDescriptors: [String: PublikMobileShellDescriptor] = [:]) {
        self.snapshot = snapshot
        self.legacyRows = legacyRows
        self.categories = categories
        self.seedDescriptors = seedDescriptors
    }

    public func index(hiddenSlugs: Set<String>) -> StoreCatalogIndex {
        if let snapshot {
            let index = StoreCatalogIndex(snapshot: snapshot, categories: categories, hiddenSlugs: hiddenSlugs)
            guard isBundledSeed else { return index }
            return StoreCatalogIndex(source: index.source, apps: index.allApps.map { $0.withDescriptor(seedDescriptors[$0.slug]) }, categories: index.categories, hiddenSlugs: hiddenSlugs)
        }
        return StoreCatalogIndex(legacyRows: legacyRows ?? [], hiddenSlugs: hiddenSlugs)
    }
}

/// How fresh the list on screen is.
public enum StoreCatalogFreshness: Equatable, Sendable {
    /// Nothing shown yet and a check is running.
    case checking(lastChecked: Date?)
    case fresh(checkedAt: Date)
    /// The last check is over 24 hours old and no newer check succeeded yet.
    case stale(lastChecked: Date)
    case offline(lastChecked: Date?)
    case failed(lastChecked: Date?)

    public var lastChecked: Date? {
        switch self {
        case .checking(let date), .offline(let date), .failed(let date): return date
        case .fresh(let date), .stale(let date): return date
        }
    }

    public var canRetry: Bool {
        switch self {
        case .stale, .offline, .failed: return true
        case .checking, .fresh: return false
        }
    }

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }
}

public enum StoreStatusLine {
    /// The one quiet line under "Browse" (design 3.4 and 10).
    public static func text(_ freshness: StoreCatalogFreshness, hasRows: Bool, showingBundledSeed: Bool = false, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if showingBundledSeed, hasRows {
            if case .checking = freshness { return StoreCatalogSeed.checkingLine }
            if freshness.isOffline { return "Offline. " + StoreCatalogSeed.statusLine }
            return StoreCatalogSeed.statusLine
        }
        switch freshness {
        case .checking(let last):
            if let last, hasRows { return "Checking for new apps. Showing \(when(last, now: now, calendar: calendar, locale: locale, style: .showing))." }
            return "Checking for apps..."
        case .fresh(let date):
            return "Checked \(when(date, now: now, calendar: calendar, locale: locale, style: .checked))"
        case .stale(let date):
            return "Couldn't check for new apps. Showing \(when(date, now: now, calendar: calendar, locale: locale, style: .showing))."
        case .offline(let last):
            guard let last, hasRows else { return "Offline. Installed apps still work in My apps." }
            return "Offline. Showing apps from \(when(last, now: now, calendar: calendar, locale: locale, style: .showing))."
        case .failed(let last):
            guard let last, hasRows else { return "Couldn't check for apps." }
            return "Couldn't check for new apps. Showing \(when(last, now: now, calendar: calendar, locale: locale, style: .showing))."
        }
    }

    public enum Style: Sendable { case checked, showing }

    /// "today at 9:12" / "Sep 27 at 18:40".
    public static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale, style: Style) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.setLocalizedDateFormatFromTemplate("jmm")
        if calendar.isDate(date, inSameDayAs: now) {
            return "today at " + time.string(from: date)
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return day.string(from: date) + " at " + time.string(from: date)
    }
}

public actor StoreCatalogFeed {
    private let client: PublikMobileCatalogClient
    private let cache: PublikMobileCatalogCache?
    private let now: @Sendable () -> Date
    var pages: [String: PublikMobileCatalogAppPageV2] = [:]
    /// The catalog of last resort (`StoreCatalogSeed`, seed hooks live in
    /// StoreCatalogSeed.swift). Nil: no seed, the behavior before it existed.
    let seedSource: (@Sendable () async -> StoreCatalogSeed?)?
    /// App pages that came from the seed, not from Publik.
    var seededPageSlugs: Set<String> = []

    public init(client: PublikMobileCatalogClient, cache: PublikMobileCatalogCache?, now: @escaping @Sendable () -> Date = { Date() }, seed: (@Sendable () async -> StoreCatalogSeed?)? = nil) {
        self.client = client
        self.cache = cache
        self.now = now
        self.seedSource = seed
    }

    /// Disk only, no network: what can paint before any request finishes.
    /// With no usable disk copy, the seed that ships inside Iris.
    public func cached() async -> (load: StoreCatalogLoad, freshness: StoreCatalogFreshness)? {
        guard let cache else { return await seedLoad().map { (load: $0, freshness: StoreCatalogFreshness.checking(lastChecked: nil)) } }
        let loader = PublikMobileCatalogV2Loader(client: client, cache: cache, now: now)
        guard let snapshot = await loader.cachedSnapshot() else { return await seedLoad().map { (load: $0, freshness: StoreCatalogFreshness.checking(lastChecked: nil)) } }
        let load = StoreCatalogLoad(snapshot: snapshot, legacyRows: nil, categories: await cachedCategories())
        return (load, snapshot.isStale ? .stale(lastChecked: snapshot.lastCheckedAt) : .fresh(checkedAt: snapshot.lastCheckedAt))
    }

    /// One conditional check. `onFirstPage` paints page 1 before the rest
    /// arrive. On failure the caller keeps what it already shows; the
    /// returned freshness says why.
    public func refresh(
        lastChecked: Date?,
        onFirstPage: (@Sendable (StoreCatalogLoad) async -> Void)? = nil
    ) async -> (load: StoreCatalogLoad?, freshness: StoreCatalogFreshness) {
        do {
            if let cache {
                let loader = PublikMobileCatalogV2Loader(client: client, cache: cache, now: now)
                let categoriesTask = Task { try? await self.client.fetchCategories(cache: cache, now: self.now()).value.categories }
                let result = try await loader.refresh(onFirstPage: { first in
                    await onFirstPage?(StoreCatalogLoad(snapshot: first, legacyRows: nil, categories: await self.cachedCategories()))
                })
                switch result {
                case .catalog(let snapshot):
                    forgetSeedPages()
                    let fetched = await categoriesTask.value
                    let categories: [PublikMobileCatalogCategoryV2]
                    if let fetched { categories = fetched } else { categories = await cachedCategories() }
                    return (StoreCatalogLoad(snapshot: snapshot, legacyRows: nil, categories: categories), .fresh(checkedAt: now()))
                case .legacy(let rows):
                    categoriesTask.cancel()
                    return (await legacyOrSeed(rows), .fresh(checkedAt: now()))
                }
            }
            return (await legacyOrSeed(try await client.fetchCatalog()), .fresh(checkedAt: now()))
        } catch {
            return (nil, Self.isOffline(error) ? .offline(lastChecked: lastChecked) : .failed(lastChecked: lastChecked))
        }
    }

    /// The app page (description, screenshots, permissions, descriptor).
    /// Pages read in this session are kept in memory, so a page opened
    /// earlier still shows its details when the phone goes offline.
    public func appPage(slug: String) async throws -> PublikMobileCatalogAppPageV2 {
        if let page = seedPage(slug) { return page }
        do {
            let page = try await client.fetchAppPage(slug: slug, cache: cache, now: now()).value
            pages[slug] = page
            return page
        } catch {
            if let page = pages[slug] { return page }
            throw error
        }
    }

    public func iconFetch() -> StoreIconCache.Fetch {
        let client = self.client
        return { app in
            guard let url = app.iconURL, let hash = app.iconHash else { throw PublikMobileDownloadError.disallowedURL }
            return try await client.fetchIcon(url, expectedIconHash: hash)
        }
    }

    /// No answer at all from Publik. The catalog client reports every
    /// transport failure as `.transportFailure` (the URL error code is not
    /// kept), so that counts as offline; an HTTP error or a bad body does not.
    public static func isOffline(_ error: Error) -> Bool {
        if case PublikMobileDownloadError.transportFailure = error { return true }
        if let url = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .timedOut].contains(url.code)
        }
        return false
    }

    /// `categories.json` from disk, checked the same way the contract does
    /// (at most 24 rows, a name, whole numbers). A damaged copy is ignored.
    private func cachedCategories() async -> [PublikMobileCatalogCategoryV2] {
        guard let document = await cache?.read(key: PublikMobileCatalogClient.categoriesCacheKey) else { return [] }
        struct Wire: Decodable {
            struct Row: Decodable { let id: Int; let name: String; let order: Int; let appCount: Int }
            let categories: [Row]
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: document.body),
              wire.categories.count <= PublikMobileCatalogClient.catalogV2MaximumCategories else { return [] }
        return wire.categories.compactMap { row in
            guard !row.name.isEmpty, row.name.count <= 64, row.appCount >= 0 else { return nil }
            return PublikMobileCatalogCategoryV2(id: row.id, name: row.name, order: row.order, appCount: row.appCount)
        }
    }
}
