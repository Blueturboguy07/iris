import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Independent-verifier regression tests for MV1-object-store-core.
///
/// `VersionsFixture.files` (VersionsTestSupport.swift) deliberately makes
/// every file's content unique per (seed, path), so none of the builder's 47
/// tests ever stage a version where two files in the SAME manifest share
/// byte-identical content. That is a realistic, easy-to-hit case (two empty
/// placeholder files, two identical default icons, a hurried duplicate of a
/// template file) and it is not an edge case invented for this test: it is
/// exactly the situation the content-addressed design exists to handle
/// ("objects are stored once by sha256 and shared ... by every version").
///
/// `testStagingTwoIdenticalFilesInOneVersionDoesNotCrash` reproduces a crash
/// in `NativeVersionStore.stage`: it built `allocatedBytes` with
/// `Dictionary(uniqueKeysWithValues:)` from `entries.map { ($0.sha256, ...) }`
/// without deduplicating by sha256 first. Two files with identical content in
/// the same `files:` array produce two entries with the same key, and
/// `Dictionary(uniqueKeysWithValues:)` traps (`Fatal error: Duplicate values
/// for key`) -- an unrecoverable process crash, not a catchable Swift error.
/// Before the fix, this test aborts the whole test process instead of
/// failing cleanly; after the fix it must pass.
final class VersionsVerifierRegressionTests: XCTestCase {
    func testStagingTwoIdenticalFilesInOneVersionDoesNotCrash() async throws {
        let root = try VersionsTestRoot(#function)
        defer { root.cleanup() }
        let store = try root.makeStore()

        let sharedBytes = Data("verifier-duplicate-content-fixture".utf8)
        let files = [
            NativeVersionStagedFile(path: "assets/a.txt", data: sharedBytes, mediaType: "text/plain"),
            NativeVersionStagedFile(path: "assets/b.txt", data: sharedBytes, mediaType: "text/plain"),
        ]
        let createdAt = VersionsFixture.isoNow()
        let identity = VersionsFixture.identity(appId: "app1", projectId: "proj1", baseRevisionId: nil, files: files, createdAt: createdAt)

        // Must not crash the process. Before the fix this line traps.
        let receipt = try await store.stage(
            appId: "app1", projectId: "proj1",
            revisionId: identity.revisionId, baseRevisionId: nil,
            contentHash: identity.contentHash, createdAt: createdAt,
            files: files
        )
        XCTAssertFalse(receipt.alreadyStaged)

        let sha = NativeObjectStore.hex(sharedBytes)
        // One manifest referencing the object twice (by path) must still
        // contribute exactly one reference, matching mark-and-sweep's
        // per-manifest `Set` semantics and the oracle's definition of a
        // reference (see `oracle_store.py`'s ref counting).
        let count = try await store.refs.count(sha256: sha)
        XCTAssertEqual(count, 1, "a single manifest referencing an object twice by path must count as one reference, not two")
    }

    /// If the fix above naively dedupes only `incrementAll`'s input while
    /// leaving `free()`'s decrement and `rebuild()`'s reconstruction
    /// un-deduped, the three would disagree about how many references a
    /// manifest with duplicate-content files contributes. That mismatch is
    /// exactly the shape of SPEC mutation 2 ("delete a referenced object"):
    /// an object still needed by a live version gets its refcount driven to
    /// zero and deleted by freeing a DIFFERENT, unrelated version. This test
    /// proves increment/decrement/rebuild agree: object content shared by
    /// (a) two files within one version and (b) a second, independent
    /// version survives freeing the first version, and is only actually
    /// deleted once every referencing version is gone.
    func testFreeingAVersionWithDuplicateFilesNeverDeletesAnObjectAnotherVersionStillNeeds() async throws {
        let root = try VersionsTestRoot(#function)
        defer { root.cleanup() }
        let store = try root.makeStore()

        let sharedBytes = Data("verifier-cross-version-shared-content".utf8)
        let sha = NativeObjectStore.hex(sharedBytes)

        // Version 1 (app1/proj1): two files, same content -> should count as
        // ONE reference from this manifest once fixed.
        let v1Files = [
            NativeVersionStagedFile(path: "assets/a.txt", data: sharedBytes, mediaType: "text/plain"),
            NativeVersionStagedFile(path: "assets/b.txt", data: sharedBytes, mediaType: "text/plain"),
        ]
        let createdAt1 = VersionsFixture.isoNow()
        let identity1 = VersionsFixture.identity(appId: "app1", projectId: "proj1", baseRevisionId: nil, files: v1Files, createdAt: createdAt1)
        try await store.stage(
            appId: "app1", projectId: "proj1", revisionId: identity1.revisionId, baseRevisionId: nil,
            contentHash: identity1.contentHash, createdAt: createdAt1, files: v1Files
        )

        // Version 2 (app2/proj2): one file, same content -> a second,
        // independent reference.
        let v2Files = [
            NativeVersionStagedFile(path: "assets/c.txt", data: sharedBytes, mediaType: "text/plain"),
        ]
        let createdAt2 = VersionsFixture.isoNow(offsetSeconds: 1)
        let identity2 = VersionsFixture.identity(appId: "app2", projectId: "proj2", baseRevisionId: nil, files: v2Files, createdAt: createdAt2)
        try await store.stage(
            appId: "app2", projectId: "proj2", revisionId: identity2.revisionId, baseRevisionId: nil,
            contentHash: identity2.contentHash, createdAt: createdAt2, files: v2Files
        )

        let countAfterBothStaged = try await store.refs.count(sha256: sha)
        XCTAssertEqual(countAfterBothStaged, 2, "two independent manifests referencing the object must count as two references")

        // Free version 1 (the one with the internal duplicate). The object
        // must still exist: app2/proj2's version still needs it.
        _ = try await store.gc.free(appId: "app1", projectId: "proj1", revisionId: identity1.revisionId)
        let __mv1v2V4 = await store.objects.exists(sha256: sha)
        XCTAssertTrue(__mv1v2V4, "freeing version 1 must not delete an object version 2 still references")
        let __mv1v2V1 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2V1, 1)

        // Now free version 2 too. Only now should the object actually go.
        _ = try await store.gc.free(appId: "app2", projectId: "proj2", revisionId: identity2.revisionId)
        let __mv1v2V5 = await store.objects.exists(sha256: sha)
        XCTAssertFalse(__mv1v2V5, "freeing the last referencing version must delete the object")
        let __mv1v2V2 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2V2, 0)

        // A full rebuild (the dirty-marker/mark-and-sweep path) from
        // whatever manifests remain must agree with the live counts above,
        // not double-count a manifest's internal duplicate.
        try await store.rebuildAllRefs()
        let __mv1v2V3 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2V3, 0)
    }
}
