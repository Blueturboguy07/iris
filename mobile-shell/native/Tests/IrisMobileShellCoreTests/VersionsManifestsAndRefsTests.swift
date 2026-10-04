import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsManifestsAndRefsTests: XCTestCase {
    private func manifest(_ id: String, base: String?, files: [NativeVersionFileEntry]) -> NativeVersionManifest {
        NativeVersionManifest(revisionId: id, baseRevisionId: base, contentHash: "sha256:\(id)", createdAt: VersionsFixture.isoNow(), files: files)
    }

    func testWriteReadListRoundTripsExactly() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeVersionManifestStore(root: root.v1.appendingPathComponent("manifests"))
        let m = manifest("rev-sha256:aaa", base: nil, files: [NativeVersionFileEntry(path: "a.js", sha256: "aa", bytes: 10, mediaType: "text/javascript")])
        try store.write(m, appId: "app", projectId: "proj")

        XCTAssertTrue(store.exists(appId: "app", projectId: "proj", revisionId: "rev-sha256:aaa"))
        let read = try store.read(appId: "app", projectId: "proj", revisionId: "rev-sha256:aaa")
        XCTAssertEqual(read, m)
        XCTAssertEqual(try store.list(appId: "app", projectId: "proj"), [m])
    }

    func testReadingAMissingManifestThrows() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeVersionManifestStore(root: root.v1.appendingPathComponent("manifests"))
        XCTAssertThrowsError(try store.read(appId: "app", projectId: "proj", revisionId: "rev-sha256:missing"))
    }

    func testTombstoneHidesTheLiveManifestButKeepsItReadableAsTombstoned() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeVersionManifestStore(root: root.v1.appendingPathComponent("manifests"))
        let m = manifest("rev-sha256:bbb", base: nil, files: [])
        try store.write(m, appId: "app", projectId: "proj")

        try store.tombstone(appId: "app", projectId: "proj", revisionId: "rev-sha256:bbb")
        XCTAssertFalse(store.exists(appId: "app", projectId: "proj", revisionId: "rev-sha256:bbb"))
        XCTAssertTrue(store.isTombstoned(appId: "app", projectId: "proj", revisionId: "rev-sha256:bbb"))
        XCTAssertEqual(try store.list(appId: "app", projectId: "proj"), [])

        try store.purgeTombstone(appId: "app", projectId: "proj", revisionId: "rev-sha256:bbb")
        XCTAssertFalse(store.isTombstoned(appId: "app", projectId: "proj", revisionId: "rev-sha256:bbb"))
    }

    func testAllProjectsEnumeratesEveryAppProjectPair() throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try NativeVersionManifestStore(root: root.v1.appendingPathComponent("manifests"))
        try store.write(manifest("rev-sha256:c1", base: nil, files: []), appId: "kneecap", projectId: "kneecap.mobile")
        try store.write(manifest("rev-sha256:c2", base: nil, files: []), appId: "nutai", projectId: "nutai.mobile")
        let pairs = Set(try store.allProjects().map { "\($0.appId)/\($0.projectId)" })
        XCTAssertEqual(pairs, ["kneecap/kneecap.mobile", "nutai/nutai.mobile"])
    }

    // MARK: Refs

    func testIncrementAllIsOneAtomicTransactionAndDecrementNeverGoesNegative() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let refs = try NativeVersionRefs(root: root.v1.appendingPathComponent("gc"))

        try await refs.incrementAll(sha256Hexes: ["a": 100, "b": 200])
        let __mv1v1 = try await refs.count(sha256: "a")
        XCTAssertEqual(__mv1v1, 1)
        try await refs.incrementAll(sha256Hexes: ["a": 100])
        let __mv1v2 = try await refs.count(sha256: "a")
        XCTAssertEqual(__mv1v2, 2)

        let zeroedFirst = try await refs.decrementAll(sha256Hexes: ["a"])
        XCTAssertEqual(zeroedFirst, [])
        let __mv1v3 = try await refs.count(sha256: "a")
        XCTAssertEqual(__mv1v3, 1)
        let zeroedSecond = try await refs.decrementAll(sha256Hexes: ["a"])
        XCTAssertEqual(zeroedSecond, ["a"])
        let __mv1v4 = try await refs.count(sha256: "a")
        XCTAssertEqual(__mv1v4, 0)

        // Never underflows below zero even if called again.
        let zeroedThird = try await refs.decrementAll(sha256Hexes: ["a"])
        XCTAssertEqual(zeroedThird, [])
        let __mv1v5 = try await refs.count(sha256: "a")
        XCTAssertEqual(__mv1v5, 0)
    }

    func testDirtyMarkerLifecycle() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let refs = try NativeVersionRefs(root: root.v1.appendingPathComponent("gc"))
        let __mv1v6 = await refs.isDirty()
        XCTAssertFalse(__mv1v6)
        try await refs.markDirty()
        let __mv1v7 = await refs.isDirty()
        XCTAssertTrue(__mv1v7)
        await refs.clearDirty()
        let __mv1v8 = await refs.isDirty()
        XCTAssertFalse(__mv1v8)
    }

    func testRebuildRecomputesExactCountsFromManifestsIndependentOfPriorState() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let objects = try NativeObjectStore(root: root.v1.appendingPathComponent("objects"))
        let refs = try NativeVersionRefs(root: root.v1.appendingPathComponent("gc"))

        let shaA = try objects.write(Data("A".utf8))
        let shaB = try objects.write(Data("B".utf8))
        // Simulate a badly drifted table: sha A overcounted (3 increments
        // for one real reference), a phantom entry that no manifest lists.
        try await refs.incrementAll(sha256Hexes: [shaA: 1, "phantom": 1])
        try await refs.incrementAll(sha256Hexes: [shaA: 1])
        try await refs.incrementAll(sha256Hexes: [shaA: 1])

        let manifests = [
            NativeVersionManifest(revisionId: "rev-sha256:x", baseRevisionId: nil, contentHash: "sha256:x", createdAt: VersionsFixture.isoNow(), files: [
                NativeVersionFileEntry(path: "a", sha256: shaA, bytes: 1, mediaType: "application/octet-stream"),
                NativeVersionFileEntry(path: "b", sha256: shaB, bytes: 1, mediaType: "application/octet-stream"),
            ]),
            NativeVersionManifest(revisionId: "rev-sha256:y", baseRevisionId: "rev-sha256:x", contentHash: "sha256:y", createdAt: VersionsFixture.isoNow(), files: [
                NativeVersionFileEntry(path: "a", sha256: shaA, bytes: 1, mediaType: "application/octet-stream"),
            ]),
        ]
        try await refs.rebuild(from: manifests, bytesForObject: { try objects.allocatedBytes(sha256: $0) })

        let counts = try await refs.allCounts()
        XCTAssertEqual(counts[shaA], 2) // referenced by both manifests
        XCTAssertEqual(counts[shaB], 1)
        XCTAssertNil(counts["phantom"], "rebuild must fully replace the table, not merge into stale rows")
        let __mv1v9 = await refs.isDirty()
        XCTAssertFalse(__mv1v9, "rebuild clears the dirty marker")
    }
}
