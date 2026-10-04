import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Unit M-store-screens, seed catalog lane. The owner opened Browse on a real
/// iPhone on 2026-09-28 and saw "There are no mobile apps to browse":
/// publikhq.com answered 404 for /api/iris/mobile/index.json and its v1
/// /api/iris/apps list only held Mac apps. These tests rebuild that world at
/// the network boundary (the fake Publik server, the only thing faked) and
/// check what a person would see, using oracles that do not come from the
/// seed code: the real starter packages that ship inside Iris, the names in
/// `NativeStarterCatalog`, and the plain status line.
final class StoreCatalogSeedTests: XCTestCase {
    /// The Mac list publikhq.com serves today (the apps with Mac marketplace
    /// artwork in this repo): real slugs, no iPhone descriptor on any row.
    static func macOnlyList() throws -> Data {
        let rows: [[String: Any]] = [
            ["slug": "cue", "name": "Cue", "guideSlug": "cue", "macBundleId": "com.publik.cue", "latestReleaseTag": "v1.4.0"],
            ["slug": "simplicity", "name": "Simplicity", "macBundleId": "com.publik.simplicity"],
            ["slug": "plantgpt", "name": "PlantGPT", "macBundleId": "com.publik.plantgpt"],
            ["slug": "freeharmony", "name": "FreeHarmony", "macBundleId": "com.publik.freeharmony"],
            ["slug": "nut-ai", "name": "Nut AI", "macBundleId": "com.publik.nut-ai"],
        ]
        return try JSONSerialization.data(withJSONObject: ["apps": rows], options: [.sortedKeys])
    }

    /// publikhq.com as the owner's phone found it: no index v2 files at all.
    static func publikToday() throws -> FakePublikServer {
        FakePublikServer(publish: CatalogPublish(files: [CatalogPublish.legacyCatalogPath: try macOnlyList()], appCount: 0))
    }

    static let starterRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IrisMobileShellApp/Resources/Starter", isDirectory: true)

    static let websiteCopyRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/plans/20260928-all-routes/round3-deferred/M-store-screens/website-catalog-v2", isDirectory: true)

    struct StarterFacts {
        let displayName: String
        let appId: String
        let revisionId: String
        let packageSHA256: String
        let byteCount: Int
    }

    /// The newest revision of each starter, read from the package bytes that
    /// ship inside Iris (the last file of each chain in NativeStarterCatalog).
    static func shippedStarters() throws -> [StarterFacts] {
        try NativeStarterCatalog.entries.map { entry in
            let file = starterRoot
                .appendingPathComponent(entry.label, isDirectory: true)
                .appendingPathComponent(try XCTUnwrap(entry.orderedFileNames.last))
            let bytes = try Data(contentsOf: file)
            let package = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let envelope = try XCTUnwrap(package["envelope"] as? [String: Any])
            return StarterFacts(
                displayName: entry.displayName,
                appId: try XCTUnwrap(envelope["appId"] as? String),
                revisionId: try XCTUnwrap(envelope["revisionId"] as? String),
                packageSHA256: NativeSecurity.sha256(bytes),
                byteCount: bytes.count
            )
        }
    }

    private func freshFeed(_ server: FakePublikServer, _ label: String) throws -> StoreCatalogFeed {
        .withBundledSeed(client: PublikMobileCatalogClient(transport: server),
                         cache: PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory(label)))
    }

    /// A seed row's button, the way the store builds it while the seed is shown.
    private func button(for app: StoreApp, installedRevisionId: String?) throws -> StoreInstallButtonState {
        let descriptor = try XCTUnwrap(app.descriptor, "\(app.name): a seed row carries its install descriptor")
        let listing = StoreCatalogSeed.listing(for: descriptor, installedRevisionId: installedRevisionId)
        return StoreInstallMachine.state(
            facts: StoreInstallFacts(appName: app.name, listing: listing, installedRevisionId: installedRevisionId, restriction: .none, isOnline: true),
            activity: .idle)
    }

    // MARK: the seed itself

    func testTheShippedSeedDescribesTheStarterPackagesThatComeWithIris() async throws {
        let seed = try await XCTUnwrapAsync(await StoreCatalogSeed.bundled())
        let starters = try Self.shippedStarters()
        XCTAssertEqual(seed.apps.count, starters.count)
        for starter in starters {
            let page = try XCTUnwrap(seed.pages.values.first { $0.mobileShell.appId == starter.appId }, "\(starter.displayName) is missing from the seed")
            let row = try XCTUnwrap(seed.apps.first { seed.pages[$0.slug]?.mobileShell.appId == starter.appId })
            XCTAssertEqual(row.name, starter.displayName)
            XCTAssertEqual(page.mobileShell.revisionId, starter.revisionId, "the seed must list the revision Iris installs")
            XCTAssertEqual(page.mobileShell.packageSHA256, starter.packageSHA256)
            XCTAssertEqual(page.mobileShell.byteCount, starter.byteCount)
            XCTAssertEqual(row.byteCount, starter.byteCount, "the size Browse shows is the real package size")
            XCTAssertEqual(row.latestRevisionId, starter.revisionId)
            XCTAssertTrue(NativeMobileMarketplacePolicy.launchAppIDs.contains(starter.appId))
            let icon = try XCTUnwrap(seed.icons[row.iconHash])
            XCTAssertTrue(icon.starts(with: [0x89, 0x50, 0x4E, 0x47]), "icons are PNG files")
            XCTAssertLessThanOrEqual(icon.count, PublikMobileCatalogClient.catalogIconMaximumBytes)
        }
        let index = seed.load.index(hiddenSlugs: [])
        for app in index.visibleApps {
            XCTAssertEqual(index.categoryNames(for: app).count, 1, "\(app.name) sits in one task-shaped category")
        }
        // round6/catalog-expand (SPEC L80): a fourth category, Health and body, holds Lunara.
        XCTAssertEqual(Set(index.categories.map(\.name)), ["Video editing", "Food and nutrition", "Face and looks", "Health and body"])
    }

    func testADamagedSeedIsRefusedByTheSameChecksAsANetworkAnswer() async throws {
        let good = try StoreCatalogSeed.bundledFiles()
        _ = try await StoreCatalogSeed.decode(files: good)

        var swappedIcon = good
        let iconPath = try XCTUnwrap(good.keys.first { $0.hasPrefix("icons/") })
        let otherIcon = try XCTUnwrap(good.keys.first { $0.hasPrefix("icons/") && $0 != iconPath })
        swappedIcon[iconPath] = good[otherIcon]
        await XCTAssertThrowsAsync(try await StoreCatalogSeed.decode(files: swappedIcon), "another app's artwork under this app's name")

        var tooLong = good
        let index = String(decoding: try XCTUnwrap(good["index.json"]), as: UTF8.self)
        tooLong["index.json"] = Data(index.replacingOccurrences(of: "\"summary\":\"Trim and join clips into one video\"", with: "\"summary\":\"\(String(repeating: "x", count: 81))\"").utf8)
        XCTAssertNotEqual(tooLong["index.json"], good["index.json"])
        await XCTAssertThrowsAsync(try await StoreCatalogSeed.decode(files: tooLong), "an 81-character summary breaks the v2 cap")

        var missingPage = good
        missingPage["apps/nut-ai.json"] = nil
        await XCTAssertThrowsAsync(try await StoreCatalogSeed.decode(files: missingPage), "a row without its page")
    }

    // MARK: the owner's phone, 2026-09-28

    func testFreshInstallWhilePublikHasNoMobileCatalogShowsTheAppsThatCameWithIris() async throws {
        let server = try Self.publikToday()
        let feed = try freshFeed(server, "seed-404")
        let starters = try Self.shippedStarters()

        // Before any request finishes: the seed paints at once.
        let painted = try await XCTUnwrapAsync(await feed.cached())
        let first = painted.load.index(hiddenSlugs: [])
        XCTAssertEqual(Set(first.visibleApps.map(\.name)), Set(starters.map(\.displayName)))
        XCTAssertEqual(StoreStatusLine.text(painted.freshness, hasRows: true, showingBundledSeed: painted.load.isBundledSeed),
                       "Checking for new apps. Showing the apps that came with Iris.")

        // The check: index.json is 404 and the v1 list is Mac only.
        let result = await feed.refresh(lastChecked: nil)
        let load = try XCTUnwrap(result.load)
        XCTAssertTrue(load.isBundledSeed)
        let index = load.index(hiddenSlugs: [])
        XCTAssertEqual(Set(index.visibleApps.map(\.name)), Set(starters.map(\.displayName)), "Browse is never empty")
        XCTAssertFalse(StoreShelves.home(index).isEmpty)
        let line = StoreStatusLine.text(result.freshness, hasRows: true, showingBundledSeed: load.isBundledSeed)
        XCTAssertEqual(line, "Showing the apps that came with Iris. More apps appear when publikhq.com lists them.")
        XCTAssertFalse(result.freshness.canRetry, "Publik answered; there is nothing to retry")

        // Every starter is installed on this phone (Iris sets them up on
        // first launch): each row reads Open, not Get.
        for starter in starters {
            let app = try XCTUnwrap(index.visibleApps.first { $0.name == starter.displayName })
            XCTAssertEqual(try button(for: app, installedRevisionId: starter.revisionId).label, "Open", "\(starter.displayName) is installed")
            // Removed by the person: no Get that would try a download that is
            // not there yet; a plain note instead.
            let removed = try button(for: app, installedRevisionId: nil)
            XCTAssertNotEqual(removed.kind, .get)
            // round6/catalog-expand (SPEC L81, L113): no more "Close Iris and open it again";
            // an entry that cannot install says why, on a disabled button.
            XCTAssertEqual(removed.kind, .unavailable)
            XCTAssertFalse(removed.isActionable)
            XCTAssertFalse((removed.note ?? "").isEmpty)
            XCTAssertFalse((removed.note ?? "").contains("Close Iris"), "SPEC L113")
            // An older starter revision (Iris updates starters at launch):
            // Open, never an Update that would download from a 404.
            let older = try button(for: app, installedRevisionId: "rev-sha256:" + String(repeating: "0", count: 64))
            XCTAssertEqual(older.label, "Open")
        }

        // Opening a seed app's page needs no request that is known to fail.
        let before = await server.log.count
        let page = try await feed.appPage(slug: "kneecap")
        XCTAssertEqual(page.mobileShell.appId, "publik.kneecap")
        XCTAssertFalse(page.description.isEmpty)
        let after = await server.log.count
        XCTAssertEqual(after, before, "the page came from the seed, not from a 404")
    }

    func testAirplaneModeWithTheCacheWipedStillShowsTheStarters() async throws {
        let server = try Self.publikToday()
        await server.setDefaultBehavior(.offline)
        let feed = try freshFeed(server, "seed-offline")
        let painted = try await XCTUnwrapAsync(await feed.cached())
        XCTAssertEqual(Set(painted.load.index(hiddenSlugs: []).visibleApps.map(\.slug)),
                       ["kneecap", "nut-ai", "freeharmony", "lunara"], "SPEC L107: all four apps remain visible offline")
        let result = await feed.refresh(lastChecked: nil)
        XCTAssertNil(result.load, "a failed check keeps what is on screen")
        XCTAssertEqual(result.freshness, .offline(lastChecked: nil))
        XCTAssertTrue(result.freshness.canRetry)
        // SPEC L111 requires offline Lunara access, without prescribing status-line copy.
        let lunara = try await feed.appPage(slug: "lunara")
        XCTAssertEqual(lunara.mobileShell.appId, "publik.lunara", "SPEC L111: Lunara's bundled page opens offline")
        let page = try await feed.appPage(slug: "freeharmony")
        XCTAssertEqual(page.mobileShell.appId, "publik.freeharmony", "a seed app's page opens offline")
    }

    // MARK: the seed never hides a real catalog

    func testARealCatalogOnTheNetworkWinsAndTheSeedStepsAside() async throws {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(100))
        let feed = try freshFeed(server, "seed-real")
        let painted = try await XCTUnwrapAsync(await feed.cached())
        XCTAssertTrue(painted.load.isBundledSeed, "first paint on a fresh phone")
        let result = await feed.refresh(lastChecked: nil)
        let load = try XCTUnwrap(result.load)
        XCTAssertFalse(load.isBundledSeed)
        XCTAssertEqual(load.index(hiddenSlugs: []).visibleApps.count, 100)
        do {
            _ = try await feed.appPage(slug: "kneecap")
            XCTFail("once the real catalog is shown, the seed no longer answers app pages")
        } catch {
            XCTAssertFalse(StoreCatalogFeed.isOffline(error), "Publik's own 404 for a page it does not list")
        }
    }

    func testTheDiskCacheWinsOverTheSeedWhenOffline() async throws {
        let directory = try makeCatalogCacheDirectory("seed-disk")
        let server = FakePublikServer(publish: try CatalogPublish.fixture(3))
        _ = await StoreCatalogFeed.withBundledSeed(client: PublikMobileCatalogClient(transport: server),
                                                    cache: PublikMobileCatalogCache(directory: directory)).refresh(lastChecked: nil)
        await server.setDefaultBehavior(.offline)
        let relaunch = StoreCatalogFeed.withBundledSeed(client: PublikMobileCatalogClient(transport: server),
                                                        cache: PublikMobileCatalogCache(directory: directory))
        let painted = try await XCTUnwrapAsync(await relaunch.cached())
        XCTAssertFalse(painted.load.isBundledSeed)
        let names = Set(painted.load.index(hiddenSlugs: []).visibleApps.map(\.name))
        XCTAssertTrue(names.isDisjoint(with: NativeStarterCatalog.entries.map(\.displayName)), "yesterday's real list, not the seed")
    }

    func testAV1ListWithIPhoneAppsWinsOverTheSeed() async throws {
        let seed = try await XCTUnwrapAsync(await StoreCatalogSeed.bundled())
        let kneecap = try XCTUnwrap(seed.pages["kneecap"]).mobileShell
        let row: [String: Any] = ["slug": "kneecap", "name": "Kneecap", "mobileShell": [
            "version": kneecap.version, "platform": kneecap.platform, "packageFormat": kneecap.packageFormat,
            "downloadUrl": kneecap.downloadURL.absoluteString, "mediaType": kneecap.mediaType, "byteCount": kneecap.byteCount,
            "packageSha256": kneecap.packageSHA256, "appId": kneecap.appId, "projectId": kneecap.projectId,
            "baseRevisionId": kneecap.baseRevisionId as Any, "revisionId": kneecap.revisionId, "contentHash": kneecap.contentHash,
        ]]
        let list = try JSONSerialization.data(withJSONObject: ["apps": [row]], options: [.sortedKeys])
        let server = FakePublikServer(publish: CatalogPublish(files: [CatalogPublish.legacyCatalogPath: list], appCount: 1))
        let result = await (try freshFeed(server, "seed-v1")).refresh(lastChecked: nil)
        let load = try XCTUnwrap(result.load)
        XCTAssertFalse(load.isBundledSeed, "a v1 list with an iPhone app is Publik's answer, so it wins")
        XCTAssertEqual(load.index(hiddenSlugs: []).visibleApps.map(\.slug), ["kneecap"])
    }

    // MARK: the website copy (what DEPLOY.md uploads)

    func testTheWebsiteCopyLoadsAsARealCatalogOnceUploaded() async throws {
        let root = Self.websiteCopyRoot.appendingPathComponent("api/iris/mobile", isDirectory: true)
        var files: [String: Data] = [:]
        for (path, bytes) in try StoreCatalogSeed.bundledFiles() {
            let uploaded = try Data(contentsOf: root.appendingPathComponent(path))
            XCTAssertEqual(uploaded, bytes, "\(path): the website copy and the copy inside Iris must be the same bytes")
            files[CatalogPublish.indexPrefix + path] = uploaded
        }
        files[CatalogPublish.legacyCatalogPath] = try Self.macOnlyList()
        let server = FakePublikServer(publish: CatalogPublish(files: files, appCount: 3))
        let result = await (try freshFeed(server, "seed-uploaded")).refresh(lastChecked: nil)
        let load = try XCTUnwrap(result.load)
        XCTAssertFalse(load.isBundledSeed, "after the upload, publikhq.com is the source")
        XCTAssertEqual(Set(load.index(hiddenSlugs: []).visibleApps.map(\.name)), Set(NativeStarterCatalog.entries.map(\.displayName)))
        guard case .fresh = result.freshness else { return XCTFail("expected a fresh check, got \(result.freshness)") }
        XCTAssertEqual(load.categories.count, 4, "round6/catalog-expand (SPEC L80): the three original categories plus Health and body")
    }
}

func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error: \(message)", file: file, line: line)
    } catch {}
}
