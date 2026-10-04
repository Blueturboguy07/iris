import Foundation
import XCTest
@testable import IrisMobileShellCore

/// The crash-point world (SPEC section 5): interrupts a write sequence at
/// every named point a real process death could land (`NativeVersionCrashPoint`),
/// then runs the same recovery path a relaunch would run
/// (`NativeVersionStore.recoverIfNeeded`) and checks invariants with an
/// independent oracle. A single-process `swift test` cannot literally kill
/// the process mid-write, so the fault injector throws exactly where a kill
/// would have landed, leaving disk state identical to what a real crash at
/// that instant would leave (every write below it is already "write to a
/// temp name, fsync, rename", so the on-disk state after N steps committed
/// is well-defined regardless of whether step N+1 ran because of a crash or
/// because a test threw there deliberately).
final class VersionsCrashPointTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    // MARK: Stage

    func testEveryStageCrashPointRecoversToAConsistentStoreOnRetry() async throws {
        let points: [NativeVersionCrashPoint] = [
            .objectWrite_afterTempWrite, .objectWrite_afterFsync, .objectWrite_afterRename,
            .manifestWrite_afterTempWrite, .manifestWrite_afterRename, .manifestWrite_afterRefsCommit,
        ]
        for point in points {
            let root = try VersionsTestRoot("stageCrash-\(point.rawValue)")
            defer { root.cleanup() }
            let store = try root.makeStore()

            let files = VersionsFixture.files(seed: 100, count: 4)
            let createdAt = VersionsFixture.isoNow()
            let identity = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: nil, files: files, createdAt: createdAt)

            do {
                _ = try await store.stage(
                    appId: appId, projectId: projectId, revisionId: identity.revisionId, baseRevisionId: nil,
                    contentHash: identity.contentHash, createdAt: createdAt, files: files,
                    fault: NativeVersionFaultInjector(point: point)
                )
                XCTFail("[\(point)] expected the simulated crash to interrupt stage()")
            } catch is NativeVersionSimulatedCrash {
                // expected: the write sequence stopped exactly here
            }

            // A relaunch: recovery, then a retry with no fault.
            _ = try await store.recoverIfNeeded(appId: appId, projectId: projectId)
            let retry = try await store.stage(
                appId: appId, projectId: projectId, revisionId: identity.revisionId, baseRevisionId: nil,
                contentHash: identity.contentHash, createdAt: createdAt, files: files
            )
            XCTAssertNotNil(retry, "[\(point)] retry after recovery must succeed")

            let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: identity.revisionId)
            XCTAssertEqual(manifest.files.count, files.count, "[\(point)]")
            for file in manifest.files {
                let __mv1v2a1 = await store.objects.exists(sha256: file.sha256)
                XCTAssertTrue(__mv1v2a1, "[\(point)] missing object \(file.path)")
                let __mv1v1 = try await store.refs.count(sha256: file.sha256)
                XCTAssertEqual(__mv1v1, 1, "[\(point)] refcount for \(file.path)")
            }
            let __mv1v2 = await store.refs.isDirty()
            XCTAssertFalse(__mv1v2, "[\(point)] dirty marker must be cleared after a clean stage")

            let report = try versionsRunOracle(v1Root: root.v1)
            let findings = report["findings"] as? [[String: Any]] ?? [["kind": "no-json"]]
            XCTAssertEqual(findings.count, 0, "[\(point)] oracle findings: \(findings)")
        }
    }

    // MARK: Activate / rollback swap

    func testEverySwapCrashPointRecoversToAConsistentStore() async throws {
        let points: [NativeVersionCrashPoint] = [
            .journalWrite_afterJournalWritten, .journalWrite_afterCheckoutBuilt,
            .journalWrite_afterPointerWrite, .journalWrite_beforeJournalDelete,
        ]
        for point in points {
            let root = try VersionsTestRoot("swapCrash-\(point.rawValue)")
            defer { root.cleanup() }
            let store = try root.makeStore()

            let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 200, baseRevisionId: nil, createdAtOffset: -300)
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
            let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 201, baseRevisionId: v1, createdAtOffset: -200)

            do {
                _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2, fault: NativeVersionFaultInjector(point: point))
                XCTFail("[\(point)] expected the simulated crash to interrupt activate()")
            } catch is NativeVersionSimulatedCrash {
                // expected
            }

            if point == .journalWrite_afterJournalWritten || point == .journalWrite_afterCheckoutBuilt {
                let activeBeforeRecovery = await store.state.readActive(appId: appId, projectId: projectId)
                XCTAssertEqual(activeBeforeRecovery?.currentRevisionId, v1,
                               "[\(point)] pointer must not move before the checkout is verified")
            }

            let outcome = try await store.recoverIfNeeded(appId: appId, projectId: projectId)
            let activeAfterRecovery = await store.state.readActive(appId: appId, projectId: projectId)
            let __mv1v2a2 = await store.state.readJournal(appId: appId, projectId: projectId)
            XCTAssertNil(__mv1v2a2, "[\(point)] journal must be settled (deleted) by recovery")

            switch point {
            case .journalWrite_afterJournalWritten, .journalWrite_afterCheckoutBuilt:
                // The pointer never moved: SPEC 2.4 "nothing changed".
                XCTAssertEqual(activeAfterRecovery?.currentRevisionId, v1, "[\(point)] pointer must stay at v1")
                XCTAssertEqual(outcome, .rolledBackIncompleteSwap(revisionId: v2), "[\(point)]")
                let stoppedRow = await store.ledger.rows(appId: appId, projectId: projectId).last { $0.revisionId == v2 }
                XCTAssertEqual(stoppedRow?.stoppedBeforeFinishing, true, "[\(point)] the row must read 'stopped before it finished'")
            case .journalWrite_afterPointerWrite, .journalWrite_beforeJournalDelete:
                // The pointer already moved before the crash: the swap
                // finished, only cleanup remained.
                XCTAssertEqual(activeAfterRecovery?.currentRevisionId, v2, "[\(point)] pointer must have completed the swap to v2")
                XCTAssertEqual(outcome, .completedSwapAfterCrash(revisionId: v2), "[\(point)]")
            default:
                XCTFail("unexpected point \(point)")
            }

            // Whichever version ended up current must be launchable.
            let launchRoot = try await store.launchContentRoot(appId: appId, projectId: projectId)
            XCTAssertTrue(FileManager.default.fileExists(atPath: launchRoot.path), "[\(point)]")

            let report = try versionsRunOracle(v1Root: root.v1)
            let findings = report["findings"] as? [[String: Any]] ?? [["kind": "no-json"]]
            XCTAssertEqual(findings.count, 0, "[\(point)] oracle findings: \(findings)")
        }
    }

    func testJournalWriteCrashLeavesNothingChanged() async throws {
        // Named target for mutation check 3 (skip the journal): with the
        // journal enabled (production default), a crash right after it is
        // written must roll back to "nothing changed" cleanly. If the
        // journal is skipped (the mutation), recovery has no record of
        // what was in flight and this invariant breaks.
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 202, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 203, baseRevisionId: v1, createdAtOffset: -200)

        do {
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2, fault: NativeVersionFaultInjector(point: .journalWrite_afterJournalWritten))
            XCTFail("expected simulated crash")
        } catch is NativeVersionSimulatedCrash {}

        let outcome = try await store.recoverIfNeeded(appId: appId, projectId: projectId)
        XCTAssertEqual(outcome, .rolledBackIncompleteSwap(revisionId: v2))
        let __mv1v2a3 = await store.state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(__mv1v2a3?.currentRevisionId, v1)
    }

    // MARK: GC sweep

    func testMarkAndSweepInterruptedMidSweepNeverTouchesAReferencedObject() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 204, baseRevisionId: nil, createdAtOffset: -300)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        let manifest = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v1)

        // A handful of true orphans (never referenced by any manifest), aged
        // past the grace period so the sweep is allowed to touch them.
        var orphanHashes: [String] = []
        for i in 0..<5 {
            let hash = try await store.objects.write(Data("orphan-\(i)".utf8))
            orphanHashes.append(hash)
            let old = Date().addingTimeInterval(-3600)
            let __mv1v2a4 = await store.objects.path(forSHA256: hash).path
            try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: __mv1v2a4)
        }

        do {
            _ = try await store.gc.markAndSweep(fault: NativeVersionFaultInjector(point: .gcSweep_midSweep))
            XCTFail("expected simulated crash")
        } catch is NativeVersionSimulatedCrash {}

        for file in manifest.files {
            let __mv1v2a5 = await store.objects.exists(sha256: file.sha256)
            XCTAssertTrue(__mv1v2a5, "an interrupted sweep must never remove a referenced object")
        }

        // A second, uninterrupted sweep converges to a clean state.
        _ = try await store.gc.markAndSweep()
        for file in manifest.files {
            let __mv1v2a6 = await store.objects.exists(sha256: file.sha256)
            XCTAssertTrue(__mv1v2a6)
        }
        var stillOrphaned: [String] = []
        for hash in orphanHashes {
            if await store.objects.exists(sha256: hash) { stillOrphaned.append(hash) }
        }
        XCTAssertEqual(stillOrphaned, [], "a clean sweep run must finish removing the aged orphans")
    }

    // MARK: Migration

    func testMigrationInterruptedMidwayResumesWithoutLosingLegacyBytes() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let legacyRoot = root.base.appendingPathComponent("revisions")
        let v1 = "rev-sha256:" + String(repeating: "1", count: 64)
        let v2 = "rev-sha256:" + String(repeating: "2", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v1, base: nil, seed: 300, createdAt: VersionsFixture.isoNow(offsetSeconds: -300)),
            VersionsLegacyFixture.revision(id: v2, base: v1, seed: 301, createdAt: VersionsFixture.isoNow(offsetSeconds: -200)),
        ], to: legacyRoot)

        let store = try root.makeStore()
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacyRoot, v1Root: root.v1)

        do {
            try await migration.migrate(
                appId: appId, projectId: projectId, currentRevisionId: v2, fallbackRevisionId: v1,
                objects: store.objects, manifests: store.manifests, refs: store.refs,
                ledger: store.ledger, checkouts: store.checkouts,
                fault: NativeVersionFaultInjector(point: .migration_midRename)
            )
            XCTFail("expected simulated crash")
        } catch is NativeVersionSimulatedCrash {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path), "an interrupted migration must not remove the legacy tree early")

        // Resume: no fault this time.
        try await migration.migrate(
            appId: appId, projectId: projectId, currentRevisionId: v2, fallbackRevisionId: v1,
            objects: store.objects, manifests: store.manifests, refs: store.refs,
            ledger: store.ledger, checkouts: store.checkouts
        )

        let journal = migration.readJournal(appId: appId, projectId: projectId)
        XCTAssertEqual(journal?.done, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path),
                      "C4: migration retry retains legacy bytes until the object-store checkout is launched and verified")
        let current = try await store.manifests.read(appId: appId, projectId: projectId, revisionId: v2)
        for file in current.files {
            let source = legacyRoot.appendingPathComponent(v2).appendingPathComponent("content").appendingPathComponent(file.path)
            let bytes = try Data(contentsOf: source)
            XCTAssertEqual(NativeObjectStore.hex(bytes), file.sha256, "C4: crash and retry preserve exact legacy bytes")
            let objectURL = await store.objects.path(forSHA256: file.sha256)
            XCTAssertEqual(NativeObjectStore.hex(try Data(contentsOf: objectURL)), file.sha256,
                           "C4: retried object bytes verify independently")
        }

        let report = try versionsRunOracle(v1Root: root.v1)
        let findings = report["findings"] as? [[String: Any]] ?? [["kind": "no-json"]]
        XCTAssertEqual(findings.count, 0, "oracle findings after resumed migration: \(findings)")
    }
}
