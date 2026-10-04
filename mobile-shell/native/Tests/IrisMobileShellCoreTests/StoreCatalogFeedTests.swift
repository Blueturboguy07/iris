import Foundation
import XCTest
@testable import IrisMobileShellCore

/// What Browse can show in each network situation (design section 10), for a
/// person on a train (P3): first launch offline, a later launch offline with
/// yesterday's list on disk, a list older than a day, and a server error.
/// The world is the fake Publik server plus a controllable clock; the
/// production feed, loader, client and disk cache run unchanged. Oracles: the
/// rows a person would see and the plain status line.
final class StoreCatalogFeedTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testFirstLaunchOfflineSaysSoAndPointsToMyApps() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        await server.setDefaultBehavior(.offline)
        let feed = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                    cache: PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory("feed-offline")))
        let cached = await feed.cached()
        XCTAssertNil(cached, "nothing is on disk before the first check")
        let result = await feed.refresh(lastChecked: nil)
        XCTAssertNil(result.load)
        XCTAssertEqual(result.freshness, .offline(lastChecked: nil))
        XCTAssertEqual(StoreStatusLine.text(result.freshness, hasRows: false), "Offline. Installed apps still work in My apps.")
    }

    func testALaterLaunchOfflineShowsYesterdaysShelvesAndSaysHowOldTheyAre() async throws {
        let clock = CatalogTestClock()
        let directory = try makeCatalogCacheDirectory("feed-relaunch")
        let server = FakePublikServer(publish: try CatalogPublish.fixture(1000))
        let firstLaunch = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                           cache: PublikMobileCatalogCache(directory: directory), now: clock.closure)
        let online = await firstLaunch.refresh(lastChecked: nil)
        let loaded = try XCTUnwrap(online.load)
        XCTAssertEqual(loaded.index(hiddenSlugs: []).visibleApps.count, 1000)

        // Next morning, airplane mode, app relaunched (a new feed on the same disk).
        clock.advance(hours: 10)
        await server.setDefaultBehavior(.offline)
        let relaunch = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                        cache: PublikMobileCatalogCache(directory: directory), now: clock.closure)
        let cached = try await XCTUnwrapAsync(await relaunch.cached())
        let index = cached.load.index(hiddenSlugs: [])
        XCTAssertEqual(index.visibleApps.count, 1000, "every cached page paints before any request")
        XCTAssertEqual(index.categories.count, 24, "categories come from disk too, so chips and shelves still draw")
        XCTAssertFalse(StoreShelves.home(index).isEmpty)
        let offline = await relaunch.refresh(lastChecked: cached.freshness.lastChecked)
        XCTAssertNil(offline.load, "a failed check never replaces what is on screen")
        guard case .offline(let last?) = offline.freshness else { return XCTFail("expected offline with a date, got \(offline.freshness)") }
        let line = StoreStatusLine.text(offline.freshness, hasRows: true, now: clock.now, calendar: utc, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(line.hasPrefix("Offline. Showing apps from "), line)
        XCTAssertEqual(last, cached.freshness.lastChecked)
    }

    func testAListOlderThanADayIsShownAndMarkedUntilACheckSucceeds() async throws {
        let clock = CatalogTestClock()
        let directory = try makeCatalogCacheDirectory("feed-stale")
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        _ = await StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                   cache: PublikMobileCatalogCache(directory: directory), now: clock.closure).refresh(lastChecked: nil)
        clock.advance(hours: 30)
        await server.setDefaultBehavior(.status(503))
        let feed = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                    cache: PublikMobileCatalogCache(directory: directory), now: clock.closure)
        let cached = try await XCTUnwrapAsync(await feed.cached())
        guard case .stale = cached.freshness else { return XCTFail("30 hours old must read as stale, got \(cached.freshness)") }
        XCTAssertTrue(StoreStatusLine.text(cached.freshness, hasRows: true).hasPrefix("Couldn't check for new apps. Showing "))
        XCTAssertTrue(cached.freshness.canRetry, "a stale list offers Try again")
        let failed = await feed.refresh(lastChecked: cached.freshness.lastChecked)
        guard case .failed = failed.freshness else { return XCTFail("a 503 is an error, not offline: \(failed.freshness)") }
        await server.clearBehaviors()
        let recovered = await feed.refresh(lastChecked: cached.freshness.lastChecked)
        XCTAssertEqual(recovered.freshness, .fresh(checkedAt: clock.now))
        XCTAssertEqual(recovered.load?.index(hiddenSlugs: []).visibleApps.count, 100)
    }

    /// Before index v2 is published, the v1 list is the store.
    func testWithoutIndexV2TheV1ListIsUsed() async throws {
        let publish = try CatalogPublish.fixture(3).legacyOnly()
        let feed = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: FakePublikServer(publish: publish)),
                                    cache: PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory("feed-legacy")))
        let result = await feed.refresh(lastChecked: nil)
        XCTAssertEqual(result.load?.legacyRows?.count, 3)
        XCTAssertEqual(result.load?.index(hiddenSlugs: []).source, .legacy)
    }

    /// An app page read earlier this session still shows offline.
    func testAnAppPageReadEarlierStillShowsOffline() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        let feed = StoreCatalogFeed(client: PublikMobileCatalogClient(transport: server),
                                    cache: PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory("feed-page")))
        let slug = try CatalogPublish.fixture(100).slugs()[5]
        let page = try await feed.appPage(slug: slug)
        await server.setDefaultBehavior(.offline)
        let again = try await feed.appPage(slug: slug)
        XCTAssertEqual(again, page)
        do {
            _ = try await feed.appPage(slug: try CatalogPublish.fixture(100).slugs()[6])
            XCTFail("a page never read cannot appear offline")
        } catch {
            XCTAssertTrue(StoreCatalogFeed.isOffline(error))
        }
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
