import Foundation
import IrisMobileShellCore

// R2-mobile-integration: the two store scenarios M5 left pending until M2's
// store landed. Both drive the REAL catalog v2 client, loader and on-disk
// cache (`StoreCatalogFeed`, `PublikMobileCatalogV2Loader`,
// `PublikMobileCatalogCache`) and the REAL store indexes (`StoreCatalogIndex`,
// `StoreSearchIndex`, `StoreShelves` through `StoreScreen`). Only the network
// boundary is fake (`FakeMobileTransport`), serving index v2 JSON pages this
// file writes from plain rows, so the oracles below compare against those
// rows, never against what the store code computed.

/// One synthetic app row as Publik would publish it in index v2.
struct CatalogV2FixtureRow {
    let slug: String
    let name: String
    let summary: String
    let categoryIds: [Int]
    let updatedAt: String
    let sponsored: Bool
    let featured: Bool

    var json: [String: Any] {
        var row: [String: Any] = [
            "slug": slug,
            "name": name,
            "summary": summary,
            "categoryIds": categoryIds,
            "iconHash": String(format: "%016llx", UInt64(truncatingIfNeeded: slug.utf8.reduce(1469598103934665603) { ($0 ^ UInt64($1)) &* 1099511628211 })),
            "iconURL": "https://publikhq.com/api/iris/mobile/icons/\(slug).png",
            "byteCount": 48_000,
            "ageRating": 4,
            "updatedAt": updatedAt,
            "badges": [String](),
        ]
        if sponsored || featured {
            row["placement"] = ["featured": featured, "sponsored": sponsored, "label": sponsored ? "Sponsored" : "Featured"]
        }
        return row
    }
}

enum CatalogV2Fixture {
    /// Canonical instant with milliseconds, the only form the client accepts.
    static let generatedAt = "2026-09-28T06:00:00.000Z"
    static let perPage = 250

    static func pageURL(_ page: Int) -> URL {
        page <= 1
            ? URL(string: "https://publikhq.com/api/iris/mobile/index.json")!
            : URL(string: "https://publikhq.com/api/iris/mobile/index-\(page).json")!
    }

    static let categoriesURL = URL(string: "https://publikhq.com/api/iris/mobile/categories.json")!

    /// `count` ordinary rows with seed-derived names and dates.
    static func rows(count: Int, seed: UInt64) -> [CatalogV2FixtureRow] {
        var rng = SeededGenerator(seed: seed)
        let words = ["Budget", "Recipe", "Sketch", "Habit", "Tide", "Garden", "Metro", "Lumen", "Pocket", "Quill", "Sprout", "Orbit"]
        return (0..<count).map { index in
            let a = words[Int(rng.nextUnitDouble() * Double(words.count)) % words.count]
            let b = words[Int(rng.nextUnitDouble() * Double(words.count)) % words.count]
            let day = 1 + Int(rng.nextUnitDouble() * 27)
            return CatalogV2FixtureRow(
                slug: "sim-app-\(index)",
                name: "\(a) \(b) \(index)",
                summary: "A simple \(a.lowercased()) helper for everyday use.",
                categoryIds: [1 + index % 8],
                updatedAt: String(format: "2026-08-%02d", day),
                sponsored: false,
                featured: false
            )
        }
    }

    /// Serves `rows` as index v2 pages (250 per page) plus categories.json.
    static func publish(_ rows: [CatalogV2FixtureRow], on transport: FakeMobileTransport) throws -> [[CatalogV2FixtureRow]] {
        let pages = stride(from: 0, to: max(rows.count, 1), by: perPage).map { Array(rows[$0..<min($0 + perPage, rows.count)]) }
        for (offset, pageRows) in pages.enumerated() {
            let body: [String: Any] = [
                "version": 2,
                "generatedAt": generatedAt,
                "page": offset + 1,
                "pageCount": pages.count,
                "apps": pageRows.map(\.json),
            ]
            transport.registerPackage(at: pageURL(offset + 1), bytes: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
        let categories: [[String: Any]] = (1...8).map { id in
            ["id": id, "name": "Category \(id)", "order": id, "appCount": rows.filter { $0.categoryIds.contains(id) }.count]
        }
        transport.registerPackage(at: categoriesURL, bytes: try JSONSerialization.data(withJSONObject: ["categories": categories], options: [.sortedKeys]))
        return pages
    }
}

// MARK: - Catalog page 2 fails while page 1 loads

/// A person opens Browse on a flaky connection: page 1 of the index arrives,
/// page 2 drops. What they see must be page 1's apps, all findable by
/// search, with an honest "couldn't check" line; nothing from page 2 may
/// appear half-loaded; a relaunch shows page 1 from disk before any request;
/// once the connection recovers, every app is there.
public final class CatalogPage2FailsScenario: MobileScenario {
    public let id = "catalog-page-2-fails"
    public let title = "Catalog page 2 drops while page 1 loads (300 apps, 2 pages)"
    public let seedString = "catalog-page-2-fails"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical, MobileBuiltInPersonas.p2HurriedPowerUser]

    public init(scratchRoot: URL) throws {}

    public func run(env: RunEnvironment, persona: MobilePersona, rng: inout SeededGenerator) async throws -> ScenarioOutcome {
        // The connection is fine except for page 2, which this scenario drops
        // on purpose below.
        env.world.setNetwork(.healthy)
        let rows = CatalogV2Fixture.rows(count: 300, seed: UInt64(rng.nextUnitDouble() * 1_000_000))
        let pages = try CatalogV2Fixture.publish(rows, on: env.transport)
        try Oracle.requireEqual(pages.count, 2, "fixture-has-two-pages", failureClass: .setupPackaging)
        let pageOneSlugs = Set(pages[0].map(\.slug))
        let allSlugs = Set(rows.map(\.slug))
        env.transport.failRequests(to: CatalogV2Fixture.pageURL(2))

        let cache = PublikMobileCatalogCache(directory: env.rootURL.appendingPathComponent("catalog-cache", isDirectory: true))
        let feed = StoreCatalogFeed(client: env.catalogClient, cache: cache)
        let painted = FirstPaintBox()
        let result = await feed.refresh(lastChecked: nil) { first in await painted.set(first) }

        // What the store puts on screen: the first page it painted (the whole
        // refresh failed, so nothing newer replaces it). StoreModel applies
        // exactly this load when it has nothing else yet.
        guard let firstLoad = await painted.value else {
            throw OracleFailure("page-1-painted", "page 1 arrived but was never offered for first paint", failureClass: .hostSide)
        }
        try Oracle.require(result.load == nil, "refresh-reports-failure", "the refresh claimed success although page 2 never arrived", failureClass: .hostSide)
        let screen = StoreScreen(index: firstLoad.index(hiddenSlugs: []))
        let shown = Set(screen.index.visibleApps.map(\.slug))
        try Oracle.requireEqual(shown, pageOneSlugs, "shows-exactly-page-1", failureClass: .hostSide)
        try Oracle.require(!screen.index.isComplete, "partial-list-known", "the store believes a 1-of-2-page list is complete", failureClass: .hostSide)
        let homeSlugs = Set(screen.home.flatMap(\.cards).map(\.slug))
        try Oracle.require(homeSlugs.isSubset(of: pageOneSlugs), "home-has-no-page-2-rows", "Home shows \(homeSlugs.subtracting(pageOneSlugs).count) rows from the page that failed", failureClass: .hostSide)

        // Search: every page-1 app is findable by its own name; no page-2 app is.
        let pageOneProbe = pages[0][Int(rng.nextUnitDouble() * Double(pages[0].count)) % pages[0].count]
        let pageTwoProbe = pages[1][Int(rng.nextUnitDouble() * Double(pages[1].count)) % pages[1].count]
        try Oracle.require(screen.search.search(pageOneProbe.name).slugs.contains(pageOneProbe.slug),
                           "page-1-app-findable", "\(pageOneProbe.name) not found by its own name", failureClass: .hostSide)
        try Oracle.require(!screen.search.search(pageTwoProbe.name).slugs.contains(pageTwoProbe.slug),
                           "page-2-app-not-invented", "\(pageTwoProbe.name) found although its page never arrived", failureClass: .hostSide)

        let line = StoreStatusLine.text(result.freshness, hasRows: !shown.isEmpty)
        try Oracle.require(line.hasPrefix("Couldn't check") || line.hasPrefix("Offline"),
                           "honest-status-line", "status line after a failed check read: \(line)", failureClass: .hostSide)

        // Relaunch with the connection still bad: page 1 paints from disk.
        let relaunch = StoreCatalogFeed(client: env.catalogClient, cache: cache)
        guard let cached = await relaunch.cached() else {
            throw OracleFailure("page-1-cached", "nothing on disk after page 1 was received", failureClass: .hostSide)
        }
        try Oracle.requireEqual(Set(cached.load.index(hiddenSlugs: []).visibleApps.map(\.slug)), pageOneSlugs,
                                "relaunch-paints-page-1-from-disk", failureClass: .hostSide)

        // The connection recovers: one more check brings every app.
        env.transport.stopFailingRequests(to: CatalogV2Fixture.pageURL(2))
        let recovered = await relaunch.refresh(lastChecked: cached.freshness.lastChecked)
        guard let full = recovered.load else {
            throw OracleFailure("recovers", "refresh still failed after page 2 came back (\(recovered.freshness))", failureClass: .hostSide)
        }
        let fullIndex = full.index(hiddenSlugs: [])
        try Oracle.requireEqual(Set(fullIndex.visibleApps.map(\.slug)), allSlugs, "recovered-shows-every-app", failureClass: .hostSide)
        try Oracle.require(fullIndex.isComplete, "recovered-list-complete", "all pages loaded but the list is still marked partial", failureClass: .hostSide)

        return ScenarioOutcome(
            passed: true,
            message: "Page 1 (\(pageOneSlugs.count) apps) stayed on screen with \"\(line)\"; all \(allSlugs.count) apps after recovery.",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: line, knewWhatToDoNext: true),
            evidence: ["pageOne": String(pageOneSlugs.count), "total": String(allSlugs.count), "statusLine": line]
        )
    }
}

private actor FirstPaintBox {
    private(set) var value: StoreCatalogLoad?
    func set(_ load: StoreCatalogLoad) { if value == nil { value = load } }
}

// MARK: - Sponsored never outranks an exact match

/// A person types the exact name of the app they want in a 1,000-app store
/// where several paid placements also mention that name. The app they named
/// must be first; paid placement must not move any result; and the result
/// order must follow the published rule (name starts with the words, then
/// name contains them, then only the summary does).
public final class SponsoredNeverOutranksScenario: MobileScenario {
    public let id = "sponsored-never-outranks-exact"
    public let title = "Sponsored apps never outrank an exact name match (1,000 apps)"
    public let seedString = "sponsored-never-outranks-exact"
    // P1 types the name the way it is written, P2 in a hurry (lower case,
    // capitals, a fragment). P3's difference (starting offline) is not part
    // of this check, so it is left out to keep the 1,000-app sweep in budget.
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical, MobileBuiltInPersonas.p2HurriedPowerUser]

    public init(scratchRoot: URL) throws {}

    private func load(_ rows: [CatalogV2FixtureRow], env: RunEnvironment, cacheName: String) async throws -> StoreScreen {
        _ = try CatalogV2Fixture.publish(rows, on: env.transport)
        let cache = PublikMobileCatalogCache(directory: env.rootURL.appendingPathComponent(cacheName, isDirectory: true))
        let result = await StoreCatalogFeed(client: env.catalogClient, cache: cache).refresh(lastChecked: nil)
        guard let loaded = result.load else {
            throw OracleFailure("catalog-loads", "the 1,000-app catalog did not load (\(result.freshness))", failureClass: .setupPackaging)
        }
        return StoreScreen(index: loaded.index(hiddenSlugs: []))
    }

    public func run(env: RunEnvironment, persona: MobilePersona, rng: inout SeededGenerator) async throws -> ScenarioOutcome {
        // The store is read online.
        env.world.setNetwork(.healthy)
        var rows = CatalogV2Fixture.rows(count: 990, seed: UInt64(rng.nextUnitDouble() * 1_000_000))
        let target = CatalogV2FixtureRow(slug: "kneecap", name: "Kneecap", summary: "Edit short videos on your phone.",
                                         categoryIds: [2], updatedAt: "2026-06-01", sponsored: false, featured: false)
        let paid: [CatalogV2FixtureRow] = [
            .init(slug: "kneecap-pro-ad", name: "Kneecap Pro Studio", summary: "Sponsored video tools.", categoryIds: [2], updatedAt: "2026-09-27", sponsored: true, featured: false),
            .init(slug: "best-kneecap-ad", name: "Best Kneecap Templates", summary: "Templates for Kneecap.", categoryIds: [2], updatedAt: "2026-09-27", sponsored: true, featured: false),
            .init(slug: "clip-helper-ad", name: "Clip Helper", summary: "Works great with Kneecap.", categoryIds: [2], updatedAt: "2026-09-27", sponsored: true, featured: false),
            .init(slug: "kneecap-featured", name: "Kneecap Guide", summary: "Learn Kneecap fast.", categoryIds: [2], updatedAt: "2026-09-26", sponsored: false, featured: true),
        ]
        // Seeded positions: paid rows sometimes come before the target in
        // catalog order, sometimes after.
        for extra in paid + [target] {
            rows.insert(extra, at: Int(rng.nextUnitDouble() * Double(rows.count)) % (rows.count + 1))
        }

        let screen = try await load(rows, env: env, cacheName: "cache-published")
        // The same catalog with every paid or featured flag removed.
        let unpaid = rows.map {
            CatalogV2FixtureRow(slug: $0.slug, name: $0.name, summary: $0.summary, categoryIds: $0.categoryIds,
                                updatedAt: $0.updatedAt, sponsored: false, featured: false)
        }
        let neutral = try await load(unpaid, env: env, cacheName: "cache-neutral")

        // How this persona types the name.
        let typed: [String] = persona.id == MobileBuiltInPersonas.p2HurriedPowerUser.id
            ? ["kneecap", "knee", "KNEECAP"]
            : ["Kneecap", "kneecap ", "Knee"]
        var checked = 0
        var exactChecked = 0
        let byslug = Dictionary(uniqueKeysWithValues: rows.map { ($0.slug, $0) })
        for query in typed {
            let result = screen.search.search(query).slugs
            // The whole name, in any case and with stray spaces, is an exact
            // match and must lead. A partial word ("Knee") is not: there the
            // published rule and the unpaid comparison below decide.
            if query.trimmingCharacters(in: .whitespaces).lowercased() == target.name.lowercased() {
                try Oracle.require(result.first == "kneecap", "exact-name-first",
                                   "query \"\(query)\" put \(result.first ?? "nothing") first", failureClass: .hostSide)
                exactChecked += 1
            }
            try Oracle.requireEqual(result, neutral.search.search(query).slugs, "sponsorship-never-moves-results", failureClass: .hostSide)
            // Independent rule check on the published rows: every result whose
            // name starts with the typed words comes before every result whose
            // name only contains them, which come before summary-only matches.
            let words = query.lowercased().split(separator: " ").map(String.init)
            func bucket(_ slug: String) -> Int {
                guard let row = byslug[slug] else { return 9 }
                let name = row.name.lowercased()
                let prefix = words.joined(separator: " ")
                if name.hasPrefix(prefix) { return 0 }
                if words.allSatisfy({ name.contains($0) }) { return 1 }
                return 2
            }
            let buckets = result.map(bucket)
            try Oracle.require(buckets == buckets.sorted(), "published-ranking-rule",
                               "query \"\(query)\" buckets out of order: \(buckets.prefix(12))", failureClass: .hostSide)
            // Paid rows are still findable (never hidden), just never promoted.
            try Oracle.require(result.contains("kneecap-pro-ad"), "paid-rows-still-listed", "a matching sponsored app vanished", failureClass: .hostSide)
            checked += 1
        }

        try Oracle.require(exactChecked >= 2, "exact-typings-checked", "only \(exactChecked) typings were the whole name", failureClass: .setupPackaging)

        // Home: paid placement is labeled and capped (at most 1 per shelf, 3 per Home).
        let sponsoredCards = screen.home.map { $0.cards.filter(\.isSponsored).count }
        try Oracle.require(sponsoredCards.allSatisfy { $0 <= 1 } && sponsoredCards.reduce(0, +) <= 3,
                           "sponsored-capped-on-home", "sponsored cards per shelf: \(sponsoredCards)", failureClass: .hostSide)

        return ScenarioOutcome(
            passed: true,
            message: "\"Kneecap\" came first for all \(exactChecked) whole-name typings (\(checked) typings checked) among \(rows.count) apps; paid rows never moved a result.",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "Kneecap is the first result.", knewWhatToDoNext: true),
            evidence: ["apps": String(rows.count), "queries": typed.joined(separator: "|")]
        )
    }
}

// MARK: - One catalog request per launch (CLICK-PATH-006)

/// unit M-store-screens (round3-deferred). CLICK-PATH-006's historical bug:
/// Browse used to load its own v1 list AND `StoreModel` loaded index v2 on
/// the same appearance, two requests where a person should see one.
/// R2-mobile-integration fixed this by deleting both v1
/// `catalog.loadCatalog()` call sites (its own HANDOFF.md, "both v1
/// catalog.loadCatalog() calls removed (CLICK-PATH-006)") but left it
/// "fixed by static trace only; no test counts catalog requests per
/// launch yet" (same HANDOFF.md, "What remains"). `StoreModel.start()`'s
/// own dedup guard (skip refreshing again inside 15 minutes of the last
/// check) is Host-only Swift with no SwiftPM test target
/// (`native/Package.swift` has one `testTarget`, `IrisMobileShellCoreTests`
/// -- confirmed by inspection, and M6's own HANDOFF.md hit the same wall:
/// "the Host has no SwiftPM test target"), so it cannot be driven directly
/// here. What this scenario verifies instead, against the real
/// `StoreCatalogFeed`/`PublikMobileCatalogV2Loader`/`PublikMobileCatalogClient`
/// Core code every real launch actually calls through: one `refresh()` (one
/// launch, or one `onAppear` inside the Host's 15-minute dedup window) makes
/// exactly one request to `index.json` and, critically, zero requests to the
/// legacy v1 catalog URL -- the second half is the actual historical bug
/// (both loaders firing), and it is fully exercised here since both clients
/// are real. A ground-truth oracle (`DeviceWorld`'s own recorded
/// "network-request-served" events, written by the fake transport
/// independent of what the loader claims it did), never the loader's return
/// value.
public final class OneCatalogRequestPerLaunchScenario: MobileScenario {
    public let id = "one-catalog-request-per-launch"
    public let title = "One catalog request per launch, never the v1 list alongside index v2 (CLICK-PATH-006)"
    public let seedString = "one-catalog-request-per-launch"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical, MobileBuiltInPersonas.p2HurriedPowerUser]

    public init(scratchRoot: URL) throws {}

    private func servedRequests(_ env: RunEnvironment, containing needle: String) -> Int {
        env.world.eventLog().filter { $0.label == "network-request-served" && $0.detail.contains(needle) }.count
    }

    public func run(env: RunEnvironment, persona: MobilePersona, rng: inout SeededGenerator) async throws -> ScenarioOutcome {
        env.world.setNetwork(.healthy)
        let rows = CatalogV2Fixture.rows(count: 40, seed: UInt64(rng.nextUnitDouble() * 1_000_000))
        _ = try CatalogV2Fixture.publish(rows, on: env.transport)
        let cache = PublikMobileCatalogCache(directory: env.rootURL.appendingPathComponent("catalog-cache", isDirectory: true))
        let feed = StoreCatalogFeed(client: env.catalogClient, cache: cache)

        // Launch: the one refresh a real launch's first `StoreTabView.onAppear`
        // makes (`StoreModel.start()` -> `runRefresh()` -> `feed.refresh`).
        let launch = await feed.refresh(lastChecked: nil)
        guard launch.load != nil else {
            throw OracleFailure("launch-loads", "the fixture catalog did not load on launch (\(launch.freshness))", failureClass: .setupPackaging)
        }
        let indexRequestsAfterLaunch = servedRequests(env, containing: "index.json")
        try Oracle.requireEqual(indexRequestsAfterLaunch, 1, "exactly-one-index-request-on-launch", failureClass: .hostSide)
        let v1RequestsAfterLaunch = servedRequests(env, containing: "/api/iris/apps")
        try Oracle.requireEqual(v1RequestsAfterLaunch, 0,
                                "no-legacy-v1-request-alongside-index-v2",
                                failureClass: .hostSide)

        // What CLICK-PATH-006 named directly: even if something in the Host
        // layer still held a reference to the old v1 client and called it
        // directly (the exact shape of the historical bug), that request
        // would show up here as a hit on the v1 URL. It does not, because
        // `env.catalogClient` -- the one real `PublikMobileCatalogClient`
        // this whole scenario shares, exactly like the shell shares one
        // client -- was only ever asked for index v2 above.
        try Oracle.require(!env.world.hasEvent("network-request-failed"), "no-request-failures", "a request failed unexpectedly: \(env.world.eventLog().filter { $0.label == "network-request-failed" })", failureClass: .setupPackaging)

        return ScenarioOutcome(
            passed: true,
            message: "One launch made \(indexRequestsAfterLaunch) index.json request and \(v1RequestsAfterLaunch) legacy v1 requests.",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "Browse showed \(rows.count) apps.", knewWhatToDoNext: true),
            evidence: ["indexRequests": String(indexRequestsAfterLaunch), "v1Requests": String(v1RequestsAfterLaunch)]
        )
    }
}

// MARK: - Update available without opening the app page (R2-CP-3)

/// unit M-store-screens (round3-deferred). R2-mobile-integration's open
/// item, quoted from its HANDOFF.md: "with index v2 live, an installed app
/// shows 'Update available' only after its page was read this session
/// (index v2 rows have no revision id). Needs a contract field (M3) or an
/// owner call on fetching installed apps' pages." This scenario drives the
/// contract field this unit added (`PublikMobileCatalogIndexAppV2
/// .latestRevisionId`, decoded by the real
/// `PublikMobileCatalogClient.decodeCatalogIndexPageV2`) through the real
/// `StoreCatalogFeed` and asserts, on the real decoded row, that an
/// installed app's badge-worthy fact (its current revision differs from the
/// catalog's `latestRevisionId`) is visible without ever calling
/// `feed.appPage(slug:)` -- the exact page-open step this scenario proves
/// unnecessary. `StoreModel.hasListedUpdate(for:)` (Host) is the real
/// consumer of this same fact through `appIdBySlug`; that plumbing is
/// Host-only and untestable here (see the scenario above), so this
/// scenario's oracle is the one fact index v2 itself must carry correctly:
/// the decoded row's `latestRevisionId`, compared against a real
/// `NativeRevisionSummary.revisionId` an app would actually be running.
public final class UpdateAvailableWithoutPageOpenScenario: MobileScenario {
    public let id = "update-available-without-page-open"
    public let title = "Update available shows from the index row alone, no app-page fetch (R2-CP-3)"
    public let seedString = "update-available-without-page-open"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical, MobileBuiltInPersonas.p3EdgeUser]

    public init(scratchRoot: URL) throws {}

    public func run(env: RunEnvironment, persona: MobilePersona, rng: inout SeededGenerator) async throws -> ScenarioOutcome {
        env.world.setNetwork(.healthy)
        let installedRevisionId = "rev-sha256:" + String(repeating: "1", count: 64)
        let newerRevisionId = "rev-sha256:" + String(repeating: "2", count: 64)
        var rows = CatalogV2Fixture.rows(count: 20, seed: UInt64(rng.nextUnitDouble() * 1_000_000))
        let kneecapRow = CatalogV2FixtureRow(
            slug: "kneecap", name: "Kneecap", summary: "Edit short videos on your phone.",
            categoryIds: [2], updatedAt: "2026-09-27", sponsored: false, featured: false
        )
        rows.insert(kneecapRow, at: 0)

        // Publish index v2 with the one field this unit added: kneecap's row
        // carries the newer revision the catalog now lists.
        let pages = stride(from: 0, to: rows.count, by: CatalogV2Fixture.perPage).map { Array(rows[$0..<min($0 + CatalogV2Fixture.perPage, rows.count)]) }
        for (offset, pageRows) in pages.enumerated() {
            var appsJSON = pageRows.map(\.json)
            if let kneecapIndex = pageRows.firstIndex(where: { $0.slug == "kneecap" }) {
                appsJSON[kneecapIndex]["latestRevisionId"] = newerRevisionId
            }
            let body: [String: Any] = [
                "version": 2, "generatedAt": CatalogV2Fixture.generatedAt,
                "page": offset + 1, "pageCount": pages.count, "apps": appsJSON,
            ]
            env.transport.registerPackage(at: CatalogV2Fixture.pageURL(offset + 1), bytes: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
        }
        env.transport.registerPackage(at: CatalogV2Fixture.categoriesURL, bytes: try JSONSerialization.data(withJSONObject: ["categories": [Any]()]))

        let cache = PublikMobileCatalogCache(directory: env.rootURL.appendingPathComponent("catalog-cache", isDirectory: true))
        let feed = StoreCatalogFeed(client: env.catalogClient, cache: cache)
        let result = await feed.refresh(lastChecked: nil)
        guard let load = result.load else {
            throw OracleFailure("catalog-loads", "the fixture catalog did not load (\(result.freshness))", failureClass: .setupPackaging)
        }
        let index = load.index(hiddenSlugs: [])
        guard let kneecap = index.app(slug: "kneecap") else {
            throw OracleFailure("kneecap-row-present", "kneecap was published but is not in the decoded index", failureClass: .setupPackaging)
        }

        // The oracle: the decoded row's own field, read directly, with no
        // app-page fetch anywhere in this scenario (`feed.appPage` is never
        // called) -- proving the fact the badge needs is on the index row.
        try Oracle.requireEqual(kneecap.latestRevisionId, newerRevisionId, "latest-revision-id-on-index-row-without-a-page-fetch", failureClass: .hostSide)
        try Oracle.require(kneecap.latestRevisionId != installedRevisionId, "differs-from-installed-revision", "the fixture's installed and newest revisions must differ for this check to mean anything", failureClass: .setupPackaging)

        // A second app, published with no `latestRevisionId` at all (an
        // older-format row, or a slug whose latest edition matches what is
        // installed): must decode to nil, never a false "update available."
        guard let unrelated = index.app(slug: rows[10].slug) else {
            throw OracleFailure("second-row-present", "\(rows[10].slug) was published but is not in the decoded index", failureClass: .setupPackaging)
        }
        try Oracle.require(unrelated.latestRevisionId == nil, "no-field-means-no-false-update", "a row this scenario never set latestRevisionId on decoded to \(String(describing: unrelated.latestRevisionId)) instead of nil", failureClass: .hostSide)

        return ScenarioOutcome(
            passed: true,
            message: "Kneecap's index row carried the newer revision id with zero app-page fetches; an untouched row stayed nil.",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: "My apps would show Kneecap as Update available.", knewWhatToDoNext: true),
            evidence: ["kneecapLatest": kneecap.latestRevisionId ?? "nil"]
        )
    }
}
