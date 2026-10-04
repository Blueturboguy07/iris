import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47, Guideline 4.7.1's "ability to
/// block abusive users" (implemented here as a local, on-device per-app
/// block list; the shell has no user-to-user interaction surface).
final class Review47BlockListTests: XCTestCase {
    private actor InMemoryBlockListStore: Review47BlockListStore {
        private var blocked: Set<String> = []

        func blockedAppIDs() async -> Set<String> { blocked }
        func setBlocked(_ appId: String, blocked isBlocked: Bool) async {
            if isBlocked { blocked.insert(appId) } else { blocked.remove(appId) }
        }
    }

    func testBlockThenUnblockRoundTrips() async {
        let list = Review47BlockList(store: InMemoryBlockListStore())
        let beforeBlocking = await list.isBlocked(appId: "publik.freeharmony")
        XCTAssertFalse(beforeBlocking)
        await list.block(appId: "publik.freeharmony")
        let afterBlocking = await list.isBlocked(appId: "publik.freeharmony")
        XCTAssertTrue(afterBlocking)
        let blockedIDs = await list.blockedAppIDs()
        XCTAssertEqual(blockedIDs, ["publik.freeharmony"])
        await list.unblock(appId: "publik.freeharmony")
        let afterUnblocking = await list.isBlocked(appId: "publik.freeharmony")
        XCTAssertFalse(afterUnblocking)
        let idsAfterUnblock = await list.blockedAppIDs()
        XCTAssertEqual(idsAfterUnblock, [])
    }

    func testBlockingOneAppNeverAffectsAnother() async {
        let list = Review47BlockList(store: InMemoryBlockListStore())
        await list.block(appId: "publik.kneecap")
        let kneecapBlocked = await list.isBlocked(appId: "publik.kneecap")
        XCTAssertTrue(kneecapBlocked)
        let nutAiBlocked = await list.isBlocked(appId: "publik.nut-ai")
        XCTAssertFalse(nutAiBlocked)
    }

    // Persona P2: a hurried power user double-taps Block. The second call
    // must be a no-op, not a crash or a toggled-back state.
    func testDoubleTappingBlockIsIdempotent() async {
        let list = Review47BlockList(store: InMemoryBlockListStore())
        await list.block(appId: "publik.kneecap")
        await list.block(appId: "publik.kneecap")
        let isBlocked = await list.isBlocked(appId: "publik.kneecap")
        XCTAssertTrue(isBlocked)
        let blockedIDs = await list.blockedAppIDs()
        XCTAssertEqual(blockedIDs, ["publik.kneecap"])
    }

    func testUserDefaultsBackedStoreRoundTripsThroughARealNamespacedSuite() async throws {
        let suiteName = "iris.review47.block-list.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("could not create an isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsReview47BlockListStore(defaults: defaults)
        let initialIDs = await store.blockedAppIDs()
        XCTAssertEqual(initialIDs, [])
        await store.setBlocked("publik.freeharmony", blocked: true)
        let idsAfterBlock = await store.blockedAppIDs()
        XCTAssertEqual(idsAfterBlock, ["publik.freeharmony"])
        await store.setBlocked("publik.freeharmony", blocked: false)
        let idsAfterUnblock = await store.blockedAppIDs()
        XCTAssertEqual(idsAfterUnblock, [])
    }
}
