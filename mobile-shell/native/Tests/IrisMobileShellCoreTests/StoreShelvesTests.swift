import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Browse home at 3, 100 and 1,000 apps against the design's rules
/// (MOBILE_STORE_DESIGN.md sections 3.1, 3.2 and 14), recomputed here from
/// the raw fixture JSON the fake server serves, not from the store's rows.
final class StoreShelvesTests: XCTestCase {
    private struct Raw {
        let slug: String
        let categoryIds: [Int]
        let featured: Bool
        let sponsored: Bool
        let badged: Bool
        let updatedAt: String
    }

    private func raw(_ publish: CatalogPublish, hidden: Set<String>) throws -> [Raw] {
        try publish.appRows().compactMap { row in
            let slug = try XCTUnwrap(row["slug"] as? String)
            guard !hidden.contains(slug) else { return nil }
            let placement = row["placement"] as? [String: Any]
            return Raw(
                slug: slug,
                categoryIds: try XCTUnwrap(row["categoryIds"] as? [Int]),
                featured: placement?["featured"] as? Bool ?? false,
                sponsored: placement?["sponsored"] as? Bool ?? false,
                badged: !((row["badges"] as? [String]) ?? []).isEmpty,
                updatedAt: try XCTUnwrap(row["updatedAt"] as? String))
        }
    }

    private func categoryOrder(_ publish: CatalogPublish) throws -> [(id: Int, name: String)] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[CatalogPublish.categoriesPath])) as? [String: Any])
        return try XCTUnwrap(json["categories"] as? [[String: Any]])
            .sorted { ($0["order"] as! Int) < ($1["order"] as! Int) }
            .map { ($0["id"] as! Int, $0["name"] as! String) }
    }

    /// The design's shelf rules written out once, from the text.
    private func expectedHome(_ apps: [Raw], categories: [(id: Int, name: String)]) -> [String] {
        if apps.isEmpty { return [] }
        if apps.count < 13 { return ["all:" + apps.map(\.slug).joined(separator: ",")] }
        var lines: [String] = []
        let nonEmpty = categories.filter { c in apps.contains { $0.categoryIds.contains(c.id) } }
        if nonEmpty.count >= 2 { lines.append("chips:" + nonEmpty.prefix(24).map { String($0.id) }.joined(separator: ",")) }
        var homeSponsored = 0
        func take(_ list: [Raw], _ limit: Int) -> [String] {
            var shelfSponsored = 0
            var out: [String] = []
            for app in list where out.count < limit {
                if app.sponsored {
                    if shelfSponsored >= 1 || homeSponsored >= 3 { continue }
                    shelfSponsored += 1; homeSponsored += 1
                }
                out.append(app.slug + (app.sponsored ? "[S]" : ""))
            }
            return out
        }
        let featured = take(apps.filter(\.featured), 6)
        if !featured.isEmpty { lines.append("featured:" + featured.joined(separator: ",")) }
        let fresh = apps.enumerated().filter { $0.element.badged }
            .sorted { $0.element.updatedAt != $1.element.updatedAt ? $0.element.updatedAt > $1.element.updatedAt : $0.offset < $1.offset }
            .map(\.element)
        let freshCards = take(fresh, 10)
        if !freshCards.isEmpty { lines.append("new(\(fresh.count)):" + freshCards.joined(separator: ",")) }
        for category in nonEmpty.prefix(6) {
            let members = apps.filter { $0.categoryIds.contains(category.id) }
            lines.append("cat\(category.id)(\(members.count)):" + take(members, 8).joined(separator: ","))
        }
        if nonEmpty.count > 6 { lines.append("all-categories:\(nonEmpty.count)") }
        return lines
    }

    private func describe(_ sections: [StoreHomeSection]) -> [String] {
        sections.map { section in
            let cards = section.cards.map { $0.slug + ($0.isSponsored ? "[S]" : "") }.joined(separator: ",")
            switch section {
            case .allApps: return "all:" + section.cards.map(\.slug).joined(separator: ",")
            case .categoryRow(let ids, _): return "chips:" + ids.map(String.init).joined(separator: ",")
            case .featured: return "featured:" + cards
            case .newAndUpdated(_, let total): return "new(\(total)):" + cards
            case .category(let id, _, _, let total): return "cat\(id)(\(total)):" + cards
            case .browseAllCategories(let count): return "all-categories:\(count)"
            }
        }
    }

    func testHomeFollowsTheDesignRulesAtEverySizeAndAfterBlocking() async throws {
        var random = StoreSeededRandom(seed: 0x5EED)
        for size in StoreWorld.sizes {
            let publish = try CatalogPublish.fixture(size)
            let categories = try categoryOrder(publish)
            let all = try publish.slugs()
            // An edge user blocks some apps: none, a few, or nearly all.
            let blockCounts = size == 3 ? [0, 1, 3] : [0, 5, size - 12, size - 13]
            for blockCount in blockCounts {
                let hidden = Set(all.shuffled(using: &random).prefix(blockCount))
                let index = try await StoreWorld.index(appCount: size, hiddenSlugs: hidden)
                XCTAssertEqual(describe(StoreShelves.home(index)), expectedHome(try raw(publish, hidden: hidden), categories: categories),
                               "size \(size), \(blockCount) blocked")
                for section in StoreShelves.home(index) {
                    for card in section.cards { XCTAssertFalse(hidden.contains(card.slug), "a blocked app is on Home") }
                }
            }
        }
    }

    /// Paid slots stay honest on the busiest catalog: at most 1 per shelf,
    /// 3 per Home, always tagged, and no shelf moves an app ahead of where
    /// the catalog put it.
    func testSponsoredCapsAndCatalogOrderHoldOnTheThousandAppHome() async throws {
        let index = try await StoreWorld.index(appCount: 1000)
        let sections = StoreShelves.home(index)
        var total = 0
        for section in sections {
            let sponsored = section.cards.filter(\.isSponsored)
            XCTAssertLessThanOrEqual(sponsored.count, 1, "\(section.id) holds \(sponsored.count) sponsored cards")
            total += sponsored.count
            for card in section.cards {
                XCTAssertEqual(card.isSponsored, index.app(slug: card.slug)?.isSponsored, "\(card.slug) tag does not match the catalog")
            }
            if case .newAndUpdated = section { continue }
            let orders = section.cards.compactMap { index.app(slug: $0.slug)?.catalogOrder }
            XCTAssertEqual(orders, orders.sorted(), "\(section.id) is not in catalog order")
        }
        XCTAssertLessThanOrEqual(total, 3)
        XCTAssertGreaterThan(total, 0, "the fixture has sponsored apps; at least one should reach Home")
    }

    /// Category page: every app of the category, catalog order, sponsored in
    /// place. A fast scroll that fires many row appearances in any order only
    /// grows the list 50 at a time and ends with every row exactly once.
    func testCategoryPagesListEveryAppOnceUnderFastScrolling() async throws {
        let index = try await StoreWorld.index(appCount: 1000)
        var random = StoreSeededRandom(seed: 77)
        for category in index.nonEmptyCategories {
            let rows = StoreShelves.categoryPage(index, categoryId: category.id)
            let expected = index.visibleApps.filter { $0.categoryIds.contains(category.id) }.map(\.slug)
            XCTAssertEqual(rows.map(\.slug), expected)
            XCTAssertEqual(rows.count, index.displayCount(forCategory: category.id))
            var shown = min(50, rows.count)
            var steps = 0
            while shown < rows.count, steps < 10_000 {
                steps += 1
                // Rows appear out of order, several at a time, as in a fling.
                let appeared = Int(random.next() % UInt64(shown))
                let next = StoreShelves.visibleRowCount(current: shown, appearedRow: appeared, total: rows.count)
                XCTAssertGreaterThanOrEqual(next, shown)
                XCTAssertLessThanOrEqual(next - shown, 50)
                if appeared < shown - 11 { XCTAssertEqual(next, shown, "rows grew before the 40th row of the chunk appeared") }
                shown = next
            }
            XCTAssertEqual(shown, rows.count, "category \(category.name) never finished loading")
            XCTAssertEqual(Set(rows.prefix(shown).map(\.slug)).count, shown, "duplicate rows")
        }
    }

    /// While only page 1 of 4 has arrived, counts are Publik's published
    /// numbers; once every page is in, they are the rows the page will show.
    func testCountsArePublishedNumbersUntilEveryPageArrives() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        let cache = PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory("store-counts"))
        let firstPage = FirstPageBox()
        guard case .catalog(let full) = try await PublikMobileCatalogV2Loader(client: client, cache: cache)
            .refresh(onFirstPage: { await firstPage.set($0) }) else { return XCTFail("index v2 expected") }
        let categories = try await client.fetchCategories(cache: cache).value.categories
        let partialSnapshot = await firstPage.value
        let partial = StoreCatalogIndex(snapshot: try XCTUnwrap(partialSnapshot), categories: categories, hiddenSlugs: [])
        let complete = StoreCatalogIndex(snapshot: full, categories: categories, hiddenSlugs: [])
        XCTAssertFalse(partial.isComplete)
        XCTAssertTrue(complete.isComplete)
        for category in categories where category.appCount > 0 {
            XCTAssertEqual(partial.displayCount(forCategory: category.id), category.appCount)
            XCTAssertEqual(complete.displayCount(forCategory: category.id), complete.apps(inCategory: category.id).count)
        }
    }

    /// Today's catalog before index v2 exists: the v1 rows, curated exactly
    /// as Browse curated them (launch identities on iPhone only), shown as
    /// one list with no empty shelves.
    func testLegacyRowsFallBackToOneListWithTheLaunchApps() async throws {
        let publish = try CatalogPublish.fixture(3).legacyOnly()
        let index = try await StoreWorld.index(server: FakePublikServer(publish: publish))
        XCTAssertEqual(index.source, .legacy)
        XCTAssertTrue(index.visibleApps.isEmpty, "fixture apps are not launch identities, so the v1 Browse policy hides them")

        let rows = try await PublikMobileCatalogClient(transport: FakePublikServer(publish: publish)).fetchCatalog()
        func relabel(_ row: PublikMobileCatalogApp, appId: String, platform: String = "ios") -> PublikMobileCatalogApp {
            let d = row.mobileShell!
            return PublikMobileCatalogApp(slug: row.slug, name: row.name, guideSlug: nil, macBundleId: nil, latestReleaseTag: nil,
                mobileShell: PublikMobileShellDescriptor(version: d.version, platform: platform, packageFormat: d.packageFormat,
                    downloadURL: d.downloadURL, mediaType: d.mediaType, byteCount: d.byteCount, packageSHA256: d.packageSHA256,
                    appId: appId, projectId: d.projectId, baseRevisionId: d.baseRevisionId, revisionId: d.revisionId,
                    contentHash: d.contentHash, appStoreMetadata: d.appStoreMetadata))
        }
        let websiteOnly = PublikMobileCatalogApp(slug: "desktop-only", name: "Desktop Only", guideSlug: nil, macBundleId: "x", latestReleaseTag: nil, mobileShell: nil)
        let mixed = [relabel(rows[0], appId: "publik.kneecap"), websiteOnly, relabel(rows[1], appId: "publik.nut-ai", platform: "android"),
                     rows[2], relabel(rows[1], appId: "publik.freeharmony")]
        let legacy = StoreCatalogIndex(legacyRows: mixed, hiddenSlugs: [])
        XCTAssertEqual(legacy.visibleApps.map(\.slug), [rows[0].slug, rows[1].slug])
        XCTAssertEqual(StoreShelves.home(legacy).map(\.id), ["all-apps"])
        XCTAssertEqual(StoreShelves.home(legacy).first?.cards.map(\.slug), [rows[0].slug, rows[1].slug])
        XCTAssertNotNil(legacy.visibleApps.first?.descriptor, "v1 rows keep their installable descriptor")
    }
}

private actor FirstPageBox {
    var value: PublikMobileCatalogV2Snapshot?
    func set(_ snapshot: PublikMobileCatalogV2Snapshot) { if value == nil { value = snapshot } }
}
