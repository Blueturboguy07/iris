import Foundation
import XCTest
@testable import IrisMobileShellCore

final class VersionsStoreEndToEndTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    func testStageThenActivateBuildsALaunchableCheckoutAndAppendsALedgerRow() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()

        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 1, baseRevisionId: nil, createdAtOffset: -100, title: "First version")
        let activated = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertTrue(activated)

        let active = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(active?.currentRevisionId, v1)
        XCTAssertNil(active?.fallbackRevisionId)

        let launchRoot = try await store.launchContentRoot(appId: appId, projectId: projectId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchRoot.appendingPathComponent("assets/file-0.bin").path))

        let rows = await store.ledger.rows(appId: appId, projectId: projectId)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].title, "First version")
    }

    func testStagingTheSameRevisionTwiceIsIdempotent() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let files = VersionsFixture.files(seed: 2, count: 3)
        let createdAt = VersionsFixture.isoNow()
        let identity = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: nil, files: files, createdAt: createdAt)

        let first = try await store.stage(appId: appId, projectId: projectId, revisionId: identity.revisionId, baseRevisionId: nil, contentHash: identity.contentHash, createdAt: createdAt, files: files)
        XCTAssertFalse(first.alreadyStaged)
        let second = try await store.stage(appId: appId, projectId: projectId, revisionId: identity.revisionId, baseRevisionId: nil, contentHash: identity.contentHash, createdAt: createdAt, files: files)
        XCTAssertTrue(second.alreadyStaged)
        let __mv1v2A3 = await store.ledger.rows(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A3.count, 1, "idempotent restage must not append a second ledger row")
    }

    func testActivateRequiresContiguityBaseMustEqualCurrent() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 3, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)

        // v3 claims a base that was never staged as current (v1 is current,
        // but this manifest's base is some other id): must be refused.
        let bogusBase = "rev-sha256:" + String(repeating: "0", count: 64)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 4, baseRevisionId: bogusBase, createdAtOffset: -100)

        do {
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
            XCTFail("expected baseMismatch")
        } catch NativeVersionStoreError.baseMismatch(let expected, let actual) {
            XCTAssertEqual(expected, v1)
            XCTAssertEqual(actual, bogusBase)
        }
        let __mv1v2A4 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A4?.currentRevisionId, v1, "a refused activate must never move the pointer")
    }

    func testGoBackToFallbackAndToAnOlderAncestorBothWork() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 5, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 6, baseRevisionId: v1, createdAtOffset: -200)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
        let v3 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 7, baseRevisionId: v2, createdAtOffset: -100)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v3)
        // current=v3, fallback=v2

        // Go back to the fallback (v2): allowed directly.
        let toFallback = try await store.rollback(appId: appId, projectId: projectId, revisionId: v2)
        XCTAssertTrue(toFallback)
        let __mv1v2A5 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A5?.currentRevisionId, v2)
        XCTAssertEqual(__mv1v2A5?.fallbackRevisionId, v3)

        // Go back further, to v1, an ancestor of the (now current) v2, not
        // the fallback: still allowed (canRevert's ancestor walk).
        let toAncestor = try await store.rollback(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertTrue(toAncestor)
        let __mv1v2A6 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A6?.currentRevisionId, v1)
    }

    func testRollingBackToAnUnrelatedRevisionIsRefused() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let otherApp = "publik.other", otherProject = "publik.other.mobile"

        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 8, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let unrelated = try await versionsStageFixture(on: store, appId: otherApp, projectId: otherProject, seed: 9, baseRevisionId: nil, createdAtOffset: -300)

        do {
            _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: unrelated)
            XCTFail("expected notAnAncestorOrFallback (or revisionNotFound, since unrelated wasn't even staged under this app)")
        } catch {
            // Either NativeVersionStoreError.revisionNotFound or
            // .notAnAncestorOrFallback is correct here; the point under
            // test is that it throws and the pointer does not move.
        }
        let __mv1v2A7 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A7?.currentRevisionId, v1)
    }

    func testUndoReactivatesExactlyThePriorVersionNeverTheOther() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 10, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 11, baseRevisionId: v1, createdAtOffset: -200)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
        // current=v2, fallback=v1

        _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: v1) // "Go back": current=v1, fallback=v2
        let __mv1v2A8 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A8?.currentRevisionId, v1)

        let undone = try await store.undo(appId: appId, projectId: projectId)
        XCTAssertTrue(undone)
        // Undo must restore the version that was current *before* the Go
        // back (v2), never the version that was left behind by mistake, and
        // never a no-op.
        let __mv1v2A9 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2A9?.currentRevisionId, v2)
        XCTAssertNotEqual(__mv1v2A9?.currentRevisionId, v1)
    }

    func testUndoWithNoOfferThrows() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        do {
            _ = try await store.undo(appId: appId, projectId: projectId)
            XCTFail("expected noUndoOffer")
        } catch NativeVersionStoreError.noUndoOffer {
            // expected
        }
    }

    func testOracleAgreesAfterAFullStageActivateGoBackSequence() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 12, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 13, baseRevisionId: v1, createdAtOffset: -200)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
        _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: v1)

        let report = try versionsRunOracle(v1Root: root.v1)
        let findings = report["findings"] as? [[String: Any]] ?? [["kind": "oracle-produced-no-findings-key"]]
        XCTAssertEqual(findings.count, 0, "oracle findings after stage/activate/rollback: \(findings)")
    }

    func testTwoAppsSharingIdenticalFileContentShareOneObjectWithTwoReferences() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()

        let sharedBytes = Data("shared library bytes".utf8)
        let filesA = [NativeVersionStagedFile(path: "lib/shared.js", data: sharedBytes, mediaType: "text/javascript")]
        let filesB = [NativeVersionStagedFile(path: "vendor/shared.js", data: sharedBytes, mediaType: "text/javascript")]
        let createdAt = VersionsFixture.isoNow()
        let idA = VersionsFixture.identity(appId: "appA", projectId: "appA.mobile", baseRevisionId: nil, files: filesA, createdAt: createdAt)
        let idB = VersionsFixture.identity(appId: "appB", projectId: "appB.mobile", baseRevisionId: nil, files: filesB, createdAt: createdAt)

        _ = try await store.stage(appId: "appA", projectId: "appA.mobile", revisionId: idA.revisionId, baseRevisionId: nil, contentHash: idA.contentHash, createdAt: createdAt, files: filesA)
        _ = try await store.stage(appId: "appB", projectId: "appB.mobile", revisionId: idB.revisionId, baseRevisionId: nil, contentHash: idB.contentHash, createdAt: createdAt, files: filesB)

        let sha = NativeObjectStore.hex(sharedBytes)
        let __mv1v2A1 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2A1, 2, "one object, referenced by both apps")
        let __mv1v2A10 = try? await store.objects.allObjectHashes().contains(sha)
        XCTAssertEqual(__mv1v2A10, true)

        // Removing appA's version must not delete the object appB still needs.
        _ = try await store.gc.free(appId: "appA", projectId: "appA.mobile", revisionId: idA.revisionId)
        let __mv1v2A11 = await store.objects.exists(sha256: sha)
        XCTAssertTrue(__mv1v2A11, "appB's reference must keep the shared object alive")
        let __mv1v2A2 = try await store.refs.count(sha256: sha)
        XCTAssertEqual(__mv1v2A2, 1)
    }

    func testLaunchFallsBackToThePreviousVersionWhenAnObjectIsDamaged() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 14, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 15, baseRevisionId: v1, createdAtOffset: -200)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
        // current=v2, fallback=v1

        // Damage v2's checkout AND its backing object: verify-in-place on
        // the existing checkout must fail (so a rebuild is attempted), and
        // the rebuild-from-objects path must also fail (so launch falls
        // back), matching a real damaged object rather than a checkout that
        // could just self-heal from a still-good object.
        let v2Manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v2)
        let firstFile = v2Manifest.files[0]
        let checkoutFile = await store.checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: v2).appendingPathComponent(firstFile.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: checkoutFile.path)
        try Data("corrupted".utf8).write(to: checkoutFile)
        let __mv1v2A12 = await store.objects.path(forSHA256: firstFile.sha256)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: __mv1v2A12.path)
        try Data("corrupted".utf8).write(to: __mv1v2A12)

        let root2 = try await store.launchContentRoot(appId: appId, projectId: projectId)
        let active = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(active?.currentRevisionId, v1, "the person must never see a blank app when a backup version is available")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root2.path))
    }

    func testFreeVersionKeepsTheFeaturesRowButMarksObjectsGone() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 16, baseRevisionId: nil, createdAtOffset: -300, title: "First version")

        let rowsBefore = await store.ledger.rows(appId: appId, projectId: projectId)
        XCTAssertEqual(rowsBefore.count, 1)

        _ = try await store.gc.free(appId: appId, projectId: projectId, revisionId: v1)

        let rowsAfter = await store.ledger.rows(appId: appId, projectId: projectId)
        XCTAssertEqual(rowsAfter.count, 1, "the Features row survives its objects being freed (SPEC 2.5)")
        let __mv1v2A13 = await store.manifests.exists(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertFalse(__mv1v2A13, "the live manifest is gone")
        let __mv1v2A14 = await store.manifests.isTombstoned(appId: appId, projectId: projectId, revisionId: v1)
        XCTAssertFalse(__mv1v2A14, "the tombstone is purged once objects are freed")
    }
}
