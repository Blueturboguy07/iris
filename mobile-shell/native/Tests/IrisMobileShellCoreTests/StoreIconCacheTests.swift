import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Icons on disk (SPEC R8.3): a person scrolls through far more apps than fit
/// under the cap. Oracles: the folder's allocated blocks measured by this
/// test (st_blocks), which icons survive (the ones looked at last), and that
/// an app never shows bytes that are not its own artwork. Icon bytes travel
/// through M3's real `fetchIcon` over the fake Publik server.
final class StoreIconCacheTests: XCTestCase {
    /// A valid-looking PNG of `size` bytes whose content depends on `seed`.
    private func png(_ seed: Int, size: Int) -> Data {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var random = StoreSeededRandom(seed: UInt64(seed) &+ 1)
        while bytes.count < size { bytes.append(UInt8(truncatingIfNeeded: random.next())) }
        return Data(bytes)
    }

    private func iconHash(_ data: Data) -> String {
        String(NativeSecurity.sha256(data).dropFirst("sha256:".count).prefix(16))
    }

    private func app(_ slug: String, bytes: Data, order: Int) -> StoreApp {
        StoreApp(slug: slug, name: slug, summary: "", categoryIds: [], iconHash: iconHash(bytes),
                 iconURL: URL(string: "https://publikhq.com/i/\(slug).png"), byteCount: nil, ageRating: 4,
                 updatedAt: "2026-09-01", badges: [], isFeatured: false, isSponsored: false, placementLabel: nil,
                 catalogOrder: order, descriptor: nil)
    }

    private func world(apps count: Int, iconBytes: Int) async -> (FakePublikServer, [StoreApp], [String: Data]) {
        let server = FakePublikServer(publish: CatalogPublish(files: [:], appCount: 0))
        var apps: [StoreApp] = []
        var icons: [String: Data] = [:]
        for index in 0..<count {
            let slug = "icon-app-\(index)"
            let data = png(index, size: iconBytes)
            await server.setFile(data, atPath: CatalogPublish.iconPath(slug))
            apps.append(app(slug, bytes: data, order: index))
            icons[slug] = data
        }
        return (server, apps, icons)
    }

    private func cache(_ server: FakePublikServer, cap: Int) throws -> StoreIconCache {
        let client = PublikMobileCatalogClient(transport: server)
        return StoreIconCache(directory: try makeCatalogCacheDirectory("icons"), capBytes: cap) { app in
            try await client.fetchIcon(app.iconURL!, expectedIconHash: app.iconHash)
        }
    }

    func testScrollingPastTheCapKeepsTheFolderUnderItAndKeepsRecentIcons() async throws {
        let (server, apps, icons) = await world(apps: 400, iconBytes: 40_000)
        let cap = 4 * 1024 * 1024 // 100 icons' worth; a scroll through 400 must evict
        let icons1 = try cache(server, cap: cap)
        var random = StoreSeededRandom(seed: 314)
        var recent: [String] = []
        for step in 0..<900 {
            // Mostly forward scrolling, sometimes back to a recent app.
            let app: StoreApp
            if step % 5 == 4, !recent.isEmpty {
                let slug = recent[Int(random.next() % UInt64(min(10, recent.count)))]
                app = apps.first { $0.slug == slug }!
            } else {
                app = apps[Int(random.next() % UInt64(apps.count))]
            }
            let data = await icons1.iconData(for: app)
            XCTAssertEqual(data, icons[app.slug], "\(app.slug) showed bytes that are not its own icon")
            recent.removeAll { $0 == app.slug }
            recent.insert(app.slug, at: 0)
            let onDisk = allocatedBytesOnDisk(under: icons1.directoryURL)
            XCTAssertLessThanOrEqual(onDisk, cap, "step \(step): \(onDisk) bytes on disk over the \(cap) cap")
        }
        // The 20 most recently shown icons are still on disk: showing them
        // again costs no request.
        let before = await server.log.count
        for slug in recent.prefix(20) {
            _ = await icons1.iconData(for: apps.first { $0.slug == slug }!)
        }
        let after = await server.log.count
        XCTAssertEqual(after, before, "recently used icons were evicted before older ones")
    }

    /// Edge user: the phone's storage hands back a different file than was
    /// written (restore from an old backup, a damaged block, another app's
    /// icon under this name). Seeded misbehavior at the file-system boundary
    /// only. The app must show its own artwork (fetched again) online, its
    /// initial offline, and never the wrong picture. Then a relaunch (a new
    /// cache on the same folder) shows the good icons offline.
    func testADamagedOrSwappedIconFileOnDiskIsNeverShown() async throws {
        let (server, apps, icons) = await world(apps: 4, iconBytes: 12_000)
        let first = try cache(server, cap: StoreIconCache.defaultCapBytes)
        for app in apps { _ = await first.iconData(for: app) }
        let folder = first.directoryURL
        func file(_ app: StoreApp) -> URL { folder.appendingPathComponent(app.iconHash! + ".img") }

        // App 1's file now holds app 3's picture; app 2's file is truncated.
        try icons[apps[3].slug]!.write(to: file(apps[1]))
        try icons[apps[2].slug]!.prefix(5_000).write(to: file(apps[2]))

        let online1 = await first.iconData(for: apps[1])
        XCTAssertEqual(online1, icons[apps[1].slug], "online, app 1 shows its own artwork again, fetched fresh")
        await server.setDefaultBehavior(.offline)
        let offline2 = await first.iconData(for: apps[2])
        XCTAssertNil(offline2, "offline, a damaged icon falls back to the initial, never partial bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(apps[2]).path), "the damaged file is removed")

        let relaunched = StoreIconCache(directory: folder, capBytes: StoreIconCache.defaultCapBytes) { _ in
            throw PublikMobileDownloadError.transportFailure("offline")
        }
        for index in [0, 1, 3] {
            let shown = await relaunched.iconData(for: apps[index])
            XCTAssertEqual(shown, icons[apps[index].slug], "after relaunch, offline, \(apps[index].slug) shows its own icon from disk")
        }
    }

    func testAnotherAppsArtworkIsNeverShownAndOversizedIconsAreRefused() async throws {
        let (server, apps, icons) = await world(apps: 3, iconBytes: 20_000)
        let cache = try cache(server, cap: StoreIconCache.defaultCapBytes)
        // The server swaps app 1's icon for app 2's (a publishing mistake).
        await server.setFile(icons[apps[2].slug], atPath: CatalogPublish.iconPath(apps[1].slug))
        let swapped = await cache.iconData(for: apps[1])
        XCTAssertNil(swapped, "app 1 must keep its initial, never app 2's artwork")
        // A 70 KB icon is over the 64 KB limit.
        let huge = png(99, size: 70_000)
        await server.setFile(huge, atPath: CatalogPublish.iconPath(apps[0].slug + "-big"))
        let oversized = await cache.iconData(for: app(apps[0].slug + "-big", bytes: huge, order: 9))
        XCTAssertNil(oversized)
        XCTAssertEqual(allocatedBytesOnDisk(under: cache.directoryURL), 0, "refused icons must not be written")
        // Offline after a first view: the icon still shows from disk.
        let good = await cache.iconData(for: apps[2])
        XCTAssertEqual(good, icons[apps[2].slug])
        await server.setDefaultBehavior(.offline)
        let offline = await cache.iconData(for: apps[2])
        XCTAssertEqual(offline, icons[apps[2].slug])
    }
}
