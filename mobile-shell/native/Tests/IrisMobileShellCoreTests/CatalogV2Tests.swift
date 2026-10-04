import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Catalog v2 client, cache and loader against the checked-in fixture
/// publishes served by `FakePublikServer`. Oracles are the server's own
/// request log, the fixture files parsed independently of the client's
/// decoder, and disk usage measured with stat(2).
final class CatalogV2Tests: XCTestCase {
    override class func tearDown() {
        removeCatalogTestCaches()
        super.tearDown()
    }

    private func loader(
        _ server: FakePublikServer,
        cacheDirectory: URL,
        clock: CatalogTestClock = CatalogTestClock(),
        cacheBytes: Int = PublikMobileCatalogCache.maximumJSONCacheBytes
    ) -> (PublikMobileCatalogV2Loader, PublikMobileCatalogCache, PublikMobileCatalogClient) {
        let client = PublikMobileCatalogClient(transport: server)
        let cache = PublikMobileCatalogCache(directory: cacheDirectory, maximumBytes: cacheBytes)
        return (PublikMobileCatalogV2Loader(client: client, cache: cache, now: clock.closure), cache, client)
    }

    private func catalogSnapshot(_ result: PublikMobileCatalogV2RefreshResult, file: StaticString = #filePath, line: UInt = #line) throws -> PublikMobileCatalogV2Snapshot {
        guard case .catalog(let snapshot) = result else {
            XCTFail("expected index v2, got the v1 fallback", file: file, line: line)
            throw PublikMobileDownloadError.catalogIndexV2Unavailable
        }
        return snapshot
    }

    // MARK: R2-CP-3 (round3-deferred/M-store-screens): index v2's optional
    // `latestRevisionId`, backward compatible with a document published
    // before this field existed.

    /// Takes page 1 of an already-valid fixture publish and edits only
    /// `apps[0].latestRevisionId` (adding, removing or corrupting it),
    /// leaving every other field exactly as the checked-in fixture builder
    /// produced it -- the oracle for "this field alone" instead of a
    /// hand-rolled JSON blob that could accidentally test some other rule.
    private func page1WithFirstAppLatestRevisionId(_ publish: CatalogPublish, _ value: Any?) throws -> Data {
        let body = try XCTUnwrap(publish.files[CatalogPublish.indexPath(1)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var apps = try XCTUnwrap(object["apps"] as? [[String: Any]])
        if let value { apps[0]["latestRevisionId"] = value } else { apps[0].removeValue(forKey: "latestRevisionId") }
        object["apps"] = apps
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testLatestRevisionIdAbsentFromAnOlderPublishedIndexDecodesAsNilNotAFailure() async throws {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        let body = try page1WithFirstAppLatestRevisionId(publish, nil)
        let page = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        XCTAssertNil(page.apps.first?.latestRevisionId, "a document published before this field existed must decode cleanly, not fail or invent a value")
    }

    func testLatestRevisionIdExplicitNullDecodesAsNil() async throws {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        let body = try page1WithFirstAppLatestRevisionId(publish, NSNull())
        let page = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        XCTAssertNil(page.apps.first?.latestRevisionId)
    }

    func testLatestRevisionIdValidShapeIsExposedOnTheDecodedRow() async throws {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        let revisionId = "rev-sha256:" + String(repeating: "a", count: 64)
        let body = try page1WithFirstAppLatestRevisionId(publish, revisionId)
        let page = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        XCTAssertEqual(page.apps.first?.latestRevisionId, revisionId)
    }

    func testLatestRevisionIdWithAnArbitraryStringIsRefusedNotSilentlyAccepted() async throws {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        // A malformed or hostile catalog host must not be able to spoof
        // "Update available" for an app it never actually built by putting
        // any old string in this field.
        let body = try page1WithFirstAppLatestRevisionId(publish, "not-a-real-revision-id")
        await assertCatalogError(.invalidCatalogField("apps.latestRevisionId")) {
            _ = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        }
    }

    /// `StoreCatalogIndex.swift`'s `StoreApp.init(indexRow:)` -- the row
    /// the Host layer actually reads -- must carry the same value through.
    func testStoreAppCarriesLatestRevisionIdFromTheIndexRow() throws {
        let revisionId = "rev-sha256:" + String(repeating: "b", count: 64)
        let row = PublikMobileCatalogIndexAppV2(
            slug: "kneecap", name: "Kneecap", summary: "Track meals", categoryIds: [1],
            iconHash: String(repeating: "a", count: 16), iconURL: URL(string: "https://publikhq.com/icon.png")!,
            byteCount: 1000, ageRating: 4, updatedAt: "2026-09-28", badges: [], placement: nil,
            latestRevisionId: revisionId
        )
        let app = StoreApp(indexRow: row, catalogOrder: 0)
        XCTAssertEqual(app.latestRevisionId, revisionId)
    }

    func testStoreAppFromAnIndexRowWithNoLatestRevisionIdIsNilNotEmptyString() throws {
        let row = PublikMobileCatalogIndexAppV2(
            slug: "kneecap", name: "Kneecap", summary: "Track meals", categoryIds: [1],
            iconHash: String(repeating: "a", count: 16), iconURL: URL(string: "https://publikhq.com/icon.png")!,
            byteCount: 1000, ageRating: 4, updatedAt: "2026-09-28", badges: [], placement: nil
        )
        let app = StoreApp(indexRow: row, catalogOrder: 0)
        XCTAssertNil(app.latestRevisionId)
    }

    /// MOBILE_STORE_DESIGN.md sections 15 and 17 item 6: `ageRating` is a required
    /// field of index v2, because a listing with no rating cannot be checked
    /// against the age a person declared (Guideline 4.7.5). So a published row
    /// with no rating, or with one that is not an Apple tier (4, 9, 13, 16 or 18,
    /// mobile-shell/contracts/CONTRACT.md), is
    /// refused when the index is read; it is never quietly listed as if it were
    /// safe. (Round 6 test author, pass 0: nothing tested this rule.)
    func testAnIndexRowWithNoAgeRatingOrANonsenseOneIsRefusedNotListedAsSafe() throws {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        let body = try XCTUnwrap(publish.files[CatalogPublish.indexPath(1)])
        let cases: [(String, Any?)] = [("missing", nil), ("text", "adults"), ("negative", -1), ("not an Apple tier (17)", 17)]
        for (label, value) in cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            var apps = try XCTUnwrap(object["apps"] as? [[String: Any]])
            if let value { apps[0]["ageRating"] = value } else { apps[0].removeValue(forKey: "ageRating") }
            object["apps"] = apps
            let edited = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try client.decodeCatalogIndexPageV2(edited, expectedPage: 1), "an index row whose age rating is \(label) must be refused")
        }
    }

    // MARK: one request per launch

    func testSecondLaunchWithUnchangedCatalogMakesExactlyOneConditionalIndexRequest() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()

        // Launch 1, empty cache: every page is downloaded, none conditionally.
        let first = try catalogSnapshot(try await loader(server, cacheDirectory: directory).0.refresh())
        let launch1 = await server.indexRequests()
        XCTAssertEqual(launch1.map(\.path), (1...4).map(CatalogPublish.indexPath))
        XCTAssertTrue(launch1.allSatisfy { $0.ifNoneMatch == nil })
        XCTAssertEqual(first.apps.map(\.slug), try publish.slugs())
        XCTAssertTrue(first.isComplete)

        // Launch 2 (a new loader and cache object over the same directory,
        // as after an app relaunch): one request, carrying the ETag the
        // server issued, answered 304.
        let mark = await server.logCount
        let second = try catalogSnapshot(try await loader(server, cacheDirectory: directory).0.refresh())
        let launch2 = await server.indexRequests(since: mark)
        XCTAssertEqual(launch2.count, 1, "launch 2 made \(launch2.map(\.path))")
        XCTAssertEqual(launch2.first?.path, CatalogPublish.indexPath(1))
        XCTAssertEqual(launch2.first?.ifNoneMatch, FakePublikServer.etag(for: try XCTUnwrap(publish.files[CatalogPublish.indexPath(1)])))
        XCTAssertEqual(launch2.first?.status, 304)
        XCTAssertEqual(second.apps.map(\.slug), try publish.slugs())
        XCTAssertEqual(second.apps, first.apps)
    }

    func testANewPublishIsDownloadedOnTheNextLaunch() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()
        _ = try await loader(server, cacheDirectory: directory).0.refresh()

        let edited = try publish.slugs()[700] // lives on page 3
        let next = try publish.republished(editing: edited, summary: "Now with shared lists", generatedAt: "2026-09-29T08:00:00.000Z")
        await server.setPublish(next)
        let mark = await server.logCount
        let snapshot = try catalogSnapshot(try await loader(server, cacheDirectory: directory).0.refresh())
        let requests = await server.indexRequests(since: mark)
        XCTAssertEqual(requests.map(\.path), (1...4).map(CatalogPublish.indexPath))
        XCTAssertEqual(requests.map(\.status), [200, 200, 200, 200])
        XCTAssertEqual(snapshot.generatedAt, "2026-09-29T08:00:00.000Z")
        XCTAssertEqual(snapshot.apps.first { $0.slug == edited }?.summary, "Now with shared lists")

        // And the next launch is back to one request.
        let mark2 = await server.logCount
        _ = try await loader(server, cacheDirectory: directory).0.refresh()
        let requestCount = await server.indexRequests(since: mark2).count
        XCTAssertEqual(requestCount, 1)
    }

    // MARK: first paint

    func testPageOneIsShownFromCacheWhileTheNetworkIsStalled() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()
        _ = try await loader(server, cacheDirectory: directory).0.refresh()

        await server.setDefaultBehavior(.stalled)
        let (relaunched, _, _) = loader(server, cacheDirectory: directory)
        let mark = await server.logCount
        let refreshTask = Task { try await relaunched.refresh() }
        // Wait until the stalled request has actually reached the server.
        var waited = 0
        while await server.logCount == mark, waited < 400 {
            try await Task.sleep(nanoseconds: 5_000_000)
            waited += 1
        }
        let pending = await server.requests(since: mark)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.completed, false, "the refresh must still be waiting on the network")

        let firstPaint = await relaunched.cachedSnapshot()
        let snapshot = try XCTUnwrap(firstPaint, "Browse must paint from cache without the network")
        XCTAssertEqual(snapshot.pages.first?.apps.map(\.slug), Array(try publish.slugs().prefix(250)))
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertFalse(snapshot.isStale)

        refreshTask.cancel()
        do {
            _ = try await refreshTask.value
            XCTFail("a stalled refresh must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let stillPending = await server.requests(since: mark).filter { !$0.completed }.count
        XCTAssertEqual(stillPending, 1)
    }

    func testFirstLaunchWithNoCacheHasNothingToPaintInsteadOfInventingRows() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        await server.setDefaultBehavior(.stalled)
        let firstPaint = await loader(server, cacheDirectory: try makeCatalogCacheDirectory()).0.cachedSnapshot()
        XCTAssertNil(firstPaint)
        let requestCount = await server.logCount
        XCTAssertEqual(requestCount, 0, "reading the cache must never touch the network")
    }

    func testRefreshHandsOverPageOneBeforeRequestingThePageAfterIt() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let (freshLoader, _, _) = loader(server, cacheDirectory: try makeCatalogCacheDirectory())
        let seen = SeenAtFirstPage()
        _ = try await freshLoader.refresh { snapshot in
            await seen.record(pages: snapshot.pages.count, indexRequestsSoFar: await server.indexRequests().count)
        }
        let recorded = await seen.value
        XCTAssertEqual(recorded?.pages, 1)
        XCTAssertEqual(recorded?.indexRequestsSoFar, 1, "page 1 must be usable before page 2 is requested")
    }

    // MARK: stale while revalidate

    func testCatalogOlderThanADayIsStillShownAndMarkedStaleUntilPublikConfirmsIt() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        let directory = try makeCatalogCacheDirectory()
        let clock = CatalogTestClock()
        let (appLoader, _, _) = loader(server, cacheDirectory: directory, clock: clock)
        _ = try await appLoader.refresh()
        let checkedAt = clock.now

        clock.advance(hours: 23)
        let early = await appLoader.cachedSnapshot()
        XCTAssertEqual(early?.isStale, false)
        clock.advance(hours: 2)
        let late = await appLoader.cachedSnapshot()
        XCTAssertEqual(late?.isStale, true, "25 hours without a check must be flagged")
        XCTAssertEqual(late?.apps.count, 100, "a stale catalog is still shown")
        XCTAssertEqual(late?.lastCheckedAt, checkedAt)

        // Publik answers 304: nothing changed, and the check restarts the window.
        let mark = await server.logCount
        _ = try await appLoader.refresh()
        let statuses = await server.indexRequests(since: mark).map(\.status)
        XCTAssertEqual(statuses, [304])
        clock.advance(hours: 0.1)
        let after = await appLoader.cachedSnapshot()
        XCTAssertEqual(after?.isStale, false)
        XCTAssertEqual(after?.lastCheckedAt.timeIntervalSince(checkedAt), 25 * 3600)
    }

    // MARK: damaged or bad data

    func testDamagedCachedPageIsRefetchedInsteadOfConfirmedForever() async throws {
        let publish = try CatalogPublish.fixture(100)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()
        let (appLoader, cache, _) = loader(server, cacheDirectory: directory)
        _ = try await appLoader.refresh()
        // Same ETag as the server's current page, unreadable body: what a
        // torn write or bit rot leaves behind.
        let etag = FakePublikServer.etag(for: try XCTUnwrap(publish.files[CatalogPublish.indexPath(1)]))
        try await cache.write(key: "index-1", body: Data("{\"apps\":[".utf8), etag: etag)

        let mark = await server.logCount
        let snapshot = try catalogSnapshot(try await appLoader.refresh())
        let requests = await server.indexRequests(since: mark)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(requests.first?.ifNoneMatch, "a damaged copy must not be offered for revalidation")
        XCTAssertEqual(snapshot.apps.map(\.slug), try publish.slugs())
        let repaired = await appLoader.cachedSnapshot()
        XCTAssertEqual(repaired?.apps.count, 100)
    }

    func testAMalformedDownloadNeverReplacesTheLastGoodCatalog() async throws {
        let publish = try CatalogPublish.fixture(100)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()
        let (appLoader, _, _) = loader(server, cacheDirectory: directory)
        _ = try await appLoader.refresh()

        let broken = try publish.republished(editing: try publish.slugs()[0], summary: "x", generatedAt: "2026-09-30T00:00:00.000Z")
        var garbage = broken
        garbage.files[CatalogPublish.indexPath(1)] = Data("{\"version\":2,\"apps\":\"nope\"}".utf8)
        await server.setPublish(garbage)
        do {
            _ = try await appLoader.refresh()
            XCTFail("malformed page 1 must fail")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .malformedCatalog)
        }
        let kept = await appLoader.cachedSnapshot()
        XCTAssertEqual(kept?.generatedAt, try publish.generatedAt(), "the last good publish must stay on screen")
        XCTAssertEqual(kept?.apps.count, 100)
    }

    func testNetworkMisbehaviorIsRefusedAndKeepsTheLastGoodCatalog() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let changed = try publish.republished(editing: try publish.slugs()[3], summary: "Changed", generatedAt: "2026-09-30T00:00:00.000Z")
        let cases: [(FakeServerBehavior, String, PublikMobileDownloadError)] = [
            (.truncated(keep: 4000), CatalogPublish.indexPath(1), .responseLengthMismatch(expected: changed.files[CatalogPublish.indexPath(1)]!.count, actual: 4000)),
            (.contentType("text/html"), CatalogPublish.indexPath(1), .unexpectedMIME(expected: "application/json", actual: "text/html")),
            (.redirected(to: URL(string: "https://publikhq.com.evil.example/api/iris/mobile/index.json")!), CatalogPublish.indexPath(1), .redirectRejected),
            (.status(500), CatalogPublish.indexPath(1), .unexpectedStatus(500)),
            (.status(302), CatalogPublish.indexPath(1), .redirectRejected),
            (.body(changed.files[CatalogPublish.indexPath(1)]!), CatalogPublish.indexPath(2), .invalidCatalogField("page")),
            (.body(publish.files[CatalogPublish.indexPath(3)]!), CatalogPublish.indexPath(3), .invalidCatalogField("index page 3 is from a different publish")),
        ]
        for (behavior, path, expected) in cases {
            let server = FakePublikServer(publish: publish)
            let directory = try makeCatalogCacheDirectory()
            let (appLoader, _, _) = loader(server, cacheDirectory: directory)
            _ = try await appLoader.refresh()
            await server.setPublish(changed)
            await server.setBehavior(behavior, forPath: path)
            do {
                _ = try await appLoader.refresh()
                XCTFail("\(behavior) on \(path) must fail")
            } catch let error as PublikMobileDownloadError {
                XCTAssertEqual(error, expected, "\(behavior) on \(path)")
            }
            let shown = await appLoader.cachedSnapshot()
            let shownSnapshot = try XCTUnwrap(shown, "\(behavior): nothing left to show")
            XCTAssertTrue(shownSnapshot.pages.allSatisfy { $0.generatedAt == shownSnapshot.generatedAt }, "\(behavior): pages from two publishes shown together")
            XCTAssertTrue([try publish.generatedAt(), try changed.generatedAt()].contains(shownSnapshot.generatedAt))
        }
    }

    func testAnAppListedOnTwoPagesIsRefused() async throws {
        let publish = try CatalogPublish.fixture(1000)
        var page2 = try publish.indexPageJSON(2)
        var rows = try XCTUnwrap(page2["apps"] as? [[String: Any]])
        rows[0] = try XCTUnwrap(try publish.indexPageJSON(1)["apps"] as? [[String: Any]])[0]
        page2["apps"] = rows
        let server = FakePublikServer(publish: publish)
        await server.setBehavior(.body(try JSONSerialization.data(withJSONObject: page2)), forPath: CatalogPublish.indexPath(2))
        let (appLoader, _, _) = loader(server, cacheDirectory: try makeCatalogCacheDirectory())
        await assertCatalogError(.invalidCatalogField("apps.slug")) { _ = try await appLoader.refresh() }
        let shown = await appLoader.cachedSnapshot()
        XCTAssertEqual(shown?.pages.count, 1, "first paint must stop before the page that repeats an app")
    }

    func testSlowResponsesStillLoadWithOneRequestPerPage() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        await server.setDefaultBehavior(.slow(milliseconds: 40))
        let snapshot = try catalogSnapshot(try await loader(server, cacheDirectory: try makeCatalogCacheDirectory()).0.refresh())
        XCTAssertEqual(snapshot.apps.count, 1000)
        let requests = await server.indexRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func testOfflineRefreshFailsButFirstPaintStillWorks() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        let directory = try makeCatalogCacheDirectory()
        let (appLoader, _, _) = loader(server, cacheDirectory: directory)
        _ = try await appLoader.refresh()
        await server.setDefaultBehavior(.offline)
        do {
            _ = try await appLoader.refresh()
            XCTFail("offline refresh must fail")
        } catch let error as PublikMobileDownloadError {
            guard case .transportFailure = error else { return XCTFail("\(error)") }
        }
        let shown = await appLoader.cachedSnapshot()
        XCTAssertEqual(shown?.apps.count, 100)
    }

    // MARK: fallback

    func testMissingIndexV2FallsBackToTheV1Catalog() async throws {
        let legacy = try CatalogPublish.fixture(3).legacyOnly()
        let server = FakePublikServer(publish: legacy)
        let result = try await loader(server, cacheDirectory: try makeCatalogCacheDirectory()).0.refresh()
        guard case .legacy(let apps) = result else { return XCTFail("expected the v1 fallback, got \(result)") }
        XCTAssertEqual(apps.map(\.slug), try CatalogPublish.fixture(3).slugs())
        XCTAssertTrue(apps.allSatisfy { $0.mobileShell != nil })
        let paths = await server.log.map(\.path)
        XCTAssertEqual(paths, [CatalogPublish.indexPath(1), CatalogPublish.legacyCatalogPath])
    }

    func testAServerErrorOnIndexV2IsNotMistakenForAnUnpublishedIndex() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(3))
        await server.setBehavior(.status(503), forPath: CatalogPublish.indexPath(1))
        do {
            _ = try await loader(server, cacheDirectory: try makeCatalogCacheDirectory()).0.refresh()
            XCTFail("503 must not trigger the v1 fallback")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .unexpectedStatus(503))
        }
        let paths = await server.log.map(\.path)
        XCTAssertEqual(paths, [CatalogPublish.indexPath(1)])
    }

    // MARK: app pages on demand

    func testAppPagesAreFetchedOnlyWhenOpenedAndRevalidatedAfterward() async throws {
        let publish = try CatalogPublish.fixture(100)
        let server = FakePublikServer(publish: publish)
        let (appLoader, cache, client) = loader(server, cacheDirectory: try makeCatalogCacheDirectory())
        _ = try await appLoader.refresh()
        let appPageRequests = await server.log.filter { $0.path.contains("/apps/") }.count
        XCTAssertEqual(appPageRequests, 0, "loading Browse must not download app pages")

        let slug = try publish.slugs()[42]
        let opened = try await client.fetchAppPage(slug: slug, cache: cache)
        XCTAssertFalse(opened.notModified)
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[CatalogPublish.appPagePath(slug)])) as? [String: Any])
        XCTAssertEqual(opened.value.description, raw["description"] as? String)
        XCTAssertEqual(opened.value.mobileShell.revisionId, (raw["mobileShell"] as? [String: Any])?["revisionId"] as? String)

        let reopened = try await client.fetchAppPage(slug: slug, cache: cache)
        XCTAssertTrue(reopened.notModified)
        XCTAssertEqual(reopened.value, opened.value)
        let log = await server.log.filter { $0.path.contains("/apps/") }
        XCTAssertEqual(log.map(\.path), [CatalogPublish.appPagePath(slug), CatalogPublish.appPagePath(slug)])
        XCTAssertNil(log[0].ifNoneMatch)
        XCTAssertNotNil(log[1].ifNoneMatch)
    }

    // MARK: foreign hosts

    func testIconsFromAnyHostOtherThanPublikAreRefusedBeforeARequestIsMade() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(3))
        let client = PublikMobileCatalogClient(transport: server)
        let hostile = [
            "https://publikhq.com.evil.example/i/swift-mail.png",
            "https://evil.example/i/swift-mail.png",
            "http://publikhq.com/i/swift-mail.png",
            "https://publikhq.com:8443/i/swift-mail.png",
            "https://user:pass@publikhq.com/i/swift-mail.png",
            "https://cdn.publikhq.com/i/swift-mail.png",
        ]
        for text in hostile {
            do {
                _ = try await client.fetchIcon(URL(string: text)!, expectedIconHash: nil)
                XCTFail("\(text) must be refused")
            } catch let error as PublikMobileDownloadError {
                XCTAssertEqual(error, .disallowedURL, text)
            }
        }
        let requestCount = await server.logCount
        XCTAssertEqual(requestCount, 0, "no request may leave for a foreign icon host")
    }

    func testIndexRowsAndAppPagesPointingAtForeignHostsAreRejected() async throws {
        let publish = try CatalogPublish.fixture(3)
        let slug = try publish.slugs()[1]
        func served(_ mutate: (inout [String: Any]) -> Void, path: String) throws -> Data {
            var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[path])) as? [String: Any])
            mutate(&json)
            return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        let foreignIcon = try served({ json in
            var apps = json["apps"] as! [[String: Any]]
            apps[1]["iconURL"] = "https://publikhq.com.evil.example/i/x.png"
            json["apps"] = apps
        }, path: CatalogPublish.indexPath(1))
        let foreignShot = try served({ json in
            json["screenshots"] = [["url": "https://evil.example/1.png", "bytes": 1024]]
        }, path: CatalogPublish.appPagePath(slug))
        let foreignPackage = try served({ json in
            var shell = json["mobileShell"] as! [String: Any]
            shell["downloadUrl"] = "https://publikhq.com.evil.example/pkg.json"
            json["mobileShell"] = shell
        }, path: CatalogPublish.appPagePath(slug))

        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        await server.setBehavior(.body(foreignIcon), forPath: CatalogPublish.indexPath(1))
        await assertCatalogError(.invalidCatalogField("apps.iconURL")) { _ = try await client.fetchIndexPage(1, cache: nil) }
        await server.setBehavior(.body(foreignShot), forPath: CatalogPublish.appPagePath(slug))
        await assertCatalogError(.invalidCatalogField("screenshots.url")) { _ = try await client.fetchAppPage(slug: slug, cache: nil) }
        await server.setBehavior(.body(foreignPackage), forPath: CatalogPublish.appPagePath(slug))
        await assertCatalogError(.disallowedURL) { _ = try await client.fetchAppPage(slug: slug, cache: nil) }
        let hosts = Set(await server.log.compactMap { $0.url.host })
        XCTAssertEqual(hosts, ["publikhq.com"])
    }

    func testAPathTraversalSlugNeverBecomesARequest() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(3))
        let client = PublikMobileCatalogClient(transport: server)
        for slug in ["../../etc/passwd", "a/b", "..", "", "Swift-Mail"] {
            await assertCatalogError(.invalidCatalogField("slug")) { _ = try await client.fetchAppPage(slug: slug, cache: nil) }
        }
        let requestCount = await server.logCount
        XCTAssertEqual(requestCount, 0)
    }

    // MARK: icons

    func testIconsAreTheAppsOwnArtworkAndAreCapped() async throws {
        let publish = try CatalogPublish.fixture(3)
        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        let apps = try await client.fetchIndexPage(1, cache: nil).value.apps
        for app in apps {
            let bytes = try await client.fetchIcon(for: app)
            XCTAssertEqual(bytes, publish.files[CatalogPublish.iconPath(app.slug)])
        }
        // A CDN mix-up serves another app's icon at this path.
        await server.setFile(publish.files[CatalogPublish.iconPath(apps[1].slug)], atPath: CatalogPublish.iconPath(apps[0].slug))
        do {
            _ = try await client.fetchIcon(for: apps[0])
            XCTFail("another app's artwork must not be accepted")
        } catch let error as PublikMobileDownloadError {
            guard case .iconDigestMismatch = error else { return XCTFail("\(error)") }
        }
        await server.setFile(Data(repeating: 0x89, count: 64 * 1024 + 1), atPath: CatalogPublish.iconPath(apps[2].slug))
        await assertCatalogError(.responseTooLarge(limit: 64 * 1024)) { _ = try await client.fetchIcon(for: apps[2]) }
        let iconRequests = await server.log.filter { $0.path.hasPrefix("/i/") }
        XCTAssertTrue(iconRequests.allSatisfy { $0.maximumBytes == 64 * 1024 && $0.acceptEncoding == "identity" && $0.method == "GET" })
    }

    // MARK: cache budget

    func testCacheStaysUnderFourMegabytesOnDiskAndKeepsPageOneWhenFull() async throws {
        let publish = try CatalogPublish.fixture(1000)
        let server = FakePublikServer(publish: publish)
        let directory = try makeCatalogCacheDirectory()
        let (appLoader, cache, client) = loader(server, cacheDirectory: directory)
        _ = try await appLoader.refresh()
        // A heavy browser opens every app's page.
        for slug in try publish.slugs() {
            _ = try await client.fetchAppPage(slug: slug, cache: cache)
        }
        let used = allocatedBytesOnDisk(under: directory)
        XCTAssertLessThanOrEqual(used, 4 * 1024 * 1024, "cache uses \(used) bytes on disk")
        XCTAssertGreaterThan(used, 3 * 1024 * 1024, "the cache should be close to full after 1,000 app pages (\(used))")
        let firstPaint = await appLoader.cachedSnapshot()
        XCTAssertEqual(firstPaint?.isComplete, true, "eviction must drop app pages before any index page")
        XCTAssertEqual(firstPaint?.apps.count, 1000)
        let recent = await cache.read(key: "app-\(try publish.slugs().last!)")
        XCTAssertNotNil(recent, "the page just opened must survive its own write")
    }

    func testADocumentLargerThanHalfTheBudgetIsRefusedWithoutEmptyingTheCache() async throws {
        let directory = try makeCatalogCacheDirectory()
        let cache = PublikMobileCatalogCache(directory: directory, maximumBytes: 64 * 1024)
        try await cache.write(key: "index-1", body: Data(repeating: 0x20, count: 8 * 1024), etag: "\"a\"")
        do {
            try await cache.write(key: "app-huge", body: Data(repeating: 0x20, count: 40 * 1024), etag: nil)
            XCTFail("an oversized document must be refused")
        } catch let error as PublikMobileCatalogCacheError {
            XCTAssertEqual(error, .documentTooLarge(key: "app-huge", bytes: 40 * 1024, budget: 64 * 1024))
        }
        let kept = await cache.read(key: "index-1")
        XCTAssertNotNil(kept)
    }

    func testTheAppsCatalogCacheLivesInItsOwnCachesFolder() throws {
        let cache = try PublikMobileCatalogCache.inAppContainer()
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertEqual(cache.directoryURL.deletingLastPathComponent().standardizedFileURL, caches.standardizedFileURL)
        XCTAssertEqual(cache.directoryURL.lastPathComponent, "PublikCatalogV2")
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        XCTAssertFalse(cache.directoryURL.path.hasPrefix(documents.path), "catalog JSON must not land in backed-up Documents")
    }

    func testCacheKeysCannotEscapeTheCacheDirectory() async throws {
        let parent = try makeCatalogCacheDirectory()
        let cache = PublikMobileCatalogCache(directory: parent.appendingPathComponent("cache"))
        for key in ["../escape", "a/b", "..", "/tmp/x", ""] {
            do {
                try await cache.write(key: key, body: Data("{}".utf8), etag: nil)
                XCTFail("\(key) must be refused")
            } catch let error as PublikMobileCatalogCacheError {
                XCTAssertEqual(error, .invalidKey(key))
            }
        }
        let escaped = try FileManager.default.contentsOfDirectory(atPath: parent.path).filter { $0 != "cache" }
        XCTAssertEqual(escaped, [])
    }
}

private actor SeenAtFirstPage {
    private(set) var value: (pages: Int, indexRequestsSoFar: Int)?
    func record(pages: Int, indexRequestsSoFar: Int) {
        if value == nil { value = (pages, indexRequestsSoFar) }
    }
}

func assertCatalogError(
    _ expected: PublikMobileDownloadError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as PublikMobileDownloadError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}
