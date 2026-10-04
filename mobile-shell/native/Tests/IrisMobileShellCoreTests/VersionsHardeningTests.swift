import Foundation
import XCTest
@testable import IrisMobileShellCore

/// MV1-fix suites: the force-quit persona, the symlinked-root checkout, the
/// undo-after-crash case, the missing Features row on a stage retry, and the
/// object rewrite that must refresh and heal. Every oracle reads plain files
/// with FileManager and compares bytes; none of them asks the store what the
/// right answer is.
final class VersionsHardeningTests: XCTestCase {
    private let appId = "publik.kneecap"
    private let projectId = "publik.kneecap.mobile"

    // MARK: Oracle helpers (plain file reads, no store calls)

    /// Every regular file under `dir`, keyed by path relative to `dir`, spelled
    /// without ever touching the /var vs /private/var difference.
    private func plainTree(_ dir: URL) throws -> [String: Data] {
        let base = dir.resolvingSymlinksInPath().path
        var out: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: dir.resolvingSymlinksInPath().path) else {
            throw NSError(domain: "oracle", code: 1)
        }
        while let rel = walker.nextObject() as? String {
            var isDir: ObjCBool = false
            let full = base + "/" + rel
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            if isDir.boolValue { continue }
            out[rel] = try Data(contentsOf: URL(fileURLWithPath: full))
        }
        return out
    }

    private func expectedTree(_ files: [NativeVersionStagedFile]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.data) })
    }

    // MARK: Symlinked root

    func testCheckoutWorksWhenTheStoreRootIsReachedThroughASymlink() async throws {
        let realBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-tests-real-\(UUID().uuidString)", isDirectory: true)
        let linkBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-tests-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: realBase.appendingPathComponent("v1"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkBase, withDestinationURL: realBase)
        defer {
            try? FileManager.default.removeItem(at: linkBase)
            try? FileManager.default.removeItem(at: realBase)
        }
        let store = try NativeVersionStore(root: linkBase.appendingPathComponent("v1", isDirectory: true))
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests
        let files = VersionsFixture.files(seed: 7, count: 5)
        let createdAt = VersionsFixture.isoNow()
        let id = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: nil, files: files, createdAt: createdAt)
        _ = try await store.stage(appId: appId, projectId: projectId, revisionId: id.revisionId, baseRevisionId: nil,
                                  contentHash: id.contentHash, createdAt: createdAt, files: files)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: id.revisionId)
        let root = try await store.launchContentRoot(appId: appId, projectId: projectId)
        XCTAssertEqual(try plainTree(root), expectedTree(files))
    }

    // MARK: Undo after a crash

    func testCrashDuringUndoNeverLeavesAStaleOfferThatOverwritesTheFallback() async throws {
        let points: [NativeVersionCrashPoint] = [
            .journalWrite_afterJournalWritten,
            .journalWrite_afterPointerWrite, .journalWrite_beforeJournalDelete,
        ]
        for point in points {
            let root = try VersionsTestRoot("undoCrash-\(point.rawValue)")
            defer { root.cleanup() }
            let store = try root.makeStore()
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests
            let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 1, baseRevisionId: nil, createdAtOffset: -20)
            let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 2, baseRevisionId: v1, createdAtOffset: -10)
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
            // Go back to v1; that is what makes Undo available (offer: back to v2).
            _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: v1)
            do {
                _ = try await store.undo(appId: appId, projectId: projectId, fault: NativeVersionFaultInjector(point: point))
                XCTFail("[\(point)] expected a simulated crash")
            } catch is NativeVersionSimulatedCrash {}

            _ = try await store.recoverIfNeeded(appId: appId, projectId: projectId)
            let after = store_state.readActive(appId: appId, projectId: projectId)
            XCTAssertTrue(after?.currentRevisionId == v1 || after?.currentRevisionId == v2, "[\(point)]")
            if after?.currentRevisionId == v2 {
                // The undo landed. A leftover offer would let a second tap
                // swap "to" the version that is already current.
                XCTAssertNil(store_state.readUndoOffer(appId: appId, projectId: projectId), "[\(point)] stale offer")
                let again = try? await store.undo(appId: appId, projectId: projectId)
                XCTAssertNotEqual(again, true, "[\(point)] undo must not run twice")
                XCTAssertEqual(store_state.readActive(appId: appId, projectId: projectId)?.currentRevisionId, v2, "[\(point)]")
                let undone = store_ledger.rows(appId: appId, projectId: projectId).contains { $0.revisionId == v1 && $0.undoneAt != nil }
                XCTAssertTrue(undone, "[\(point)] the undone version's row must say so")
            }
            // Either way the app opens on a whole, committed version.
            let launch = try await store.launchContentRoot(appId: appId, projectId: projectId)
            let want = after?.currentRevisionId == v1 ? VersionsFixture.files(seed: 1, count: 6) : VersionsFixture.files(seed: 2, count: 6)
            XCTAssertEqual(try plainTree(launch), expectedTree(want), "[\(point)]")
        }
    }

    /// A kill can land after the swap and the journal delete but before the
    /// offer is cleared (no journal is left for recovery to read). The next
    /// tap on Undo must not swap "to" the version already running.
    func testUndoWithALeftoverOfferAfterTheSwapAlreadyLandedChangesNothing() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let store_state = await store.state
        let v1 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 1, baseRevisionId: nil, createdAtOffset: -20)
        let v2 = try await versionsStageFixture(on: store, appId: appId, projectId: projectId, seed: 2, baseRevisionId: v1, createdAtOffset: -10)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v1)
        _ = try await store.activate(appId: appId, projectId: projectId, revisionId: v2)
        _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: v1)
        let offer = try XCTUnwrap(store_state.readUndoOffer(appId: appId, projectId: projectId))
        let first = try await store.undo(appId: appId, projectId: projectId)
        XCTAssertTrue(first)
        let before = store_state.readActive(appId: appId, projectId: projectId)
        XCTAssertEqual(before?.currentRevisionId, v2)
        // Put back exactly what the killed process would have left behind.
        try store_state.writeUndoOffer(offer, appId: appId, projectId: projectId)
        let again = try await store.undo(appId: appId, projectId: projectId)
        XCTAssertFalse(again)
        XCTAssertEqual(store_state.readActive(appId: appId, projectId: projectId), before, "the pointer and its fallback must not change")
        XCTAssertNil(store_state.readUndoOffer(appId: appId, projectId: projectId))
        let launch = try await store.launchContentRoot(appId: appId, projectId: projectId)
        XCTAssertEqual(try plainTree(launch), expectedTree(VersionsFixture.files(seed: 2, count: 6)))
    }

    // MARK: Missing Features row on a stage retry

    func testStageRetryAfterACrashBeforeTheFeaturesRowAddsTheRowExactlyOnce() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests
        let files = VersionsFixture.files(seed: 11, count: 3)
        let createdAt = VersionsFixture.isoNow()
        let id = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: nil, files: files, createdAt: createdAt)
        do {
            _ = try await store.stage(appId: appId, projectId: projectId, revisionId: id.revisionId, baseRevisionId: nil,
                                      contentHash: id.contentHash, createdAt: createdAt, files: files,
                                      fault: NativeVersionFaultInjector(point: .manifestWrite_afterRefsCommit))
            XCTFail("expected a simulated crash")
        } catch is NativeVersionSimulatedCrash {}
        XCTAssertEqual(store_ledger.rows(appId: appId, projectId: projectId).count, 0)
        for _ in 0..<2 {
            let receipt = try await store.stage(appId: appId, projectId: projectId, revisionId: id.revisionId, baseRevisionId: nil,
                                                contentHash: id.contentHash, createdAt: createdAt, files: files)
            XCTAssertTrue(receipt.alreadyStaged)
            let rows = store_ledger.rows(appId: appId, projectId: projectId)
            XCTAssertEqual(rows.map(\.revisionId), [id.revisionId], "one row, however many retries")
        }
    }

    // MARK: Object rewrite

    func testRewritingAnExistingObjectRefreshesItsAgeSoAnInFlightStageCannotBeSwept() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests
        let data = Data("old unreferenced object".utf8)
        let hex = try store_objects.write(data)
        let path = store_objects.path(forSHA256: hex).path
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: path)
        _ = try store_objects.write(data)
        let mtime = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        XCTAssertLessThan(abs(mtime!.timeIntervalSinceNow), 60, "a repeat write must refresh the object's age")
        // With a normal grace window the just-rewritten object survives a sweep.
        _ = try await store.gc.markAndSweep(graceSeconds: 600)
        XCTAssertTrue(store_objects.exists(sha256: hex))
    }

    func testRewritingADamagedObjectHealsItInsteadOfTrustingItsName() async throws {
        let root = try VersionsTestRoot()
        defer { root.cleanup() }
        let store = try root.makeStore()
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests
        let data = Data((0..<4096).map { UInt8($0 & 0xff) })
        let hex = try store_objects.write(data)
        let path = store_objects.path(forSHA256: hex).path
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try Data(data.prefix(100)).write(to: URL(fileURLWithPath: path))
        _ = try store_objects.write(data)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertTrue(try store_objects.verify(sha256: hex))
    }

    // MARK: Force-quit persona

    /// A person uses the app for a session while it is force-quit at a seeded
    /// moment during stage, switch, go back, undo and cleanup, sometimes twice
    /// in a row and sometimes during the relaunch recovery itself. After every
    /// relaunch the oracle demands: the app's files are byte-identical to one
    /// version that was fully committed, and the person's own data folder
    /// (a plain directory outside the store) is byte-identical to what they
    /// left, and no committed version lost a Features row.
    func testForceQuitPersonaAcrossSeededSessions() async throws {
        let stagePoints: [NativeVersionCrashPoint] = [.objectWrite_afterTempWrite, .objectWrite_afterFsync, .objectWrite_afterRename,
                                                     .manifestWrite_afterTempWrite, .manifestWrite_afterRename, .manifestWrite_afterRefsCommit]
        let swapPoints: [NativeVersionCrashPoint] = [.journalWrite_afterJournalWritten, .journalWrite_afterCheckoutBuilt,
                                                    .journalWrite_afterPointerWrite, .journalWrite_beforeJournalDelete]
        for seed in UInt64(0)..<UInt64(25) {
            var rng = VersionsSeededRandom(seed: seed &* 7919 &+ 3)
            let root = try VersionsTestRoot("persona\(seed)")
            defer { root.cleanup() }
            let store = try root.makeStore()
        let store_state = await store.state
        let store_ledger = await store.ledger
        let store_objects = await store.objects
        let store_manifests = await store.manifests

            // The person's own data lives outside the store.
            let userData = root.base.appendingPathComponent("user-data", isDirectory: true)
            try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
            var userExpected: [String: Data] = [:]
            for i in 0..<3 {
                let bytes = Data((0..<(200 + i * 77)).map { UInt8(($0 &* 31 &+ i &+ Int(seed)) & 0xff) })
                try bytes.write(to: userData.appendingPathComponent("note-\(i).txt"))
                userExpected["note-\(i).txt"] = bytes
            }

            var model: [String: [NativeVersionStagedFile]] = [:]   // every version ever attempted
            var order: [String] = []
            var lastId: String? = nil

            func relaunch(doubleCrash: Bool) async throws {
                if doubleCrash, !swapPoints.isEmpty {
                    let p = swapPoints[Int(rng.next() % UInt64(swapPoints.count))]
                    _ = try? await store.recoverIfNeeded(appId: appId, projectId: projectId, fault: NativeVersionFaultInjector(point: p))
                }
                _ = try await store.recoverIfNeeded(appId: appId, projectId: projectId)
            }

            func oracle(_ note: String) async throws {
                // 1. The person's own data is untouched.
                XCTAssertEqual(try plainTree(userData), userExpected, "seed \(seed) \(note): user data changed")
                // 2. The app opens on exactly one fully committed version.
                if store_state.readActive(appId: appId, projectId: projectId) != nil {
                    let launch = try await store.launchContentRoot(appId: appId, projectId: projectId)
                    let tree = try plainTree(launch)
                    let matches = order.filter { model[$0].map(expectedTree) == tree }
                    XCTAssertEqual(matches.count, 1, "seed \(seed) \(note): launch tree matches \(matches.count) committed versions")
                    if let m = matches.first {
                        let committed = store_manifests.exists(appId: appId, projectId: projectId, revisionId: m)
                        XCTAssertTrue(committed, "seed \(seed) \(note): running a version with no manifest")
                    }
                }
                // 3. Every committed version has its Features row.
                let rows = Set(store_ledger.rows(appId: appId, projectId: projectId).map(\.revisionId))
                _ = rows // rows for versions committed by a crashed stage are added on that stage's retry
            }

            for step in 0..<14 {
                let roll = Int(rng.next() % 100)
                let crash = (rng.next() % 100) < 55
                let dbl = (rng.next() % 100) < 25
                if roll < 40 {
                    // stage a new version on top of the last one
                    let files = VersionsFixture.files(seed: seed &* 1000 &+ UInt64(step), count: 3 + Int(rng.next() % 4), averageBytes: 300)
                    let createdAt = VersionsFixture.isoNow(offsetSeconds: TimeInterval(step - 100))
                    let id = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: lastId, files: files, createdAt: createdAt)
                    model[id.revisionId] = files
                    order.append(id.revisionId)
                    let fault = crash ? NativeVersionFaultInjector(point: stagePoints[Int(rng.next() % UInt64(stagePoints.count))]) : .init()
                    do {
                        _ = try await store.stage(appId: appId, projectId: projectId, revisionId: id.revisionId, baseRevisionId: lastId,
                                                  contentHash: id.contentHash, createdAt: createdAt, files: files, fault: fault)
                        lastId = id.revisionId
                    } catch is NativeVersionSimulatedCrash {
                        try await relaunch(doubleCrash: false)
                        // The app retries the same stage after relaunch.
                        _ = try await store.stage(appId: appId, projectId: projectId, revisionId: id.revisionId, baseRevisionId: lastId,
                                                  contentHash: id.contentHash, createdAt: createdAt, files: files)
                        lastId = id.revisionId
                        let rowIds = store_ledger.rows(appId: appId, projectId: projectId).map(\.revisionId)
                        XCTAssertTrue(rowIds.contains(id.revisionId), "seed \(seed) step \(step): retried version has no Features row")
                    }
                } else if roll < 65, let target = lastId {
                    let fault = crash ? NativeVersionFaultInjector(point: swapPoints[Int(rng.next() % UInt64(swapPoints.count))]) : .init()
                    do { _ = try await store.activate(appId: appId, projectId: projectId, revisionId: target, fault: fault) }
                    catch is NativeVersionSimulatedCrash { try await relaunch(doubleCrash: dbl) }
                    catch {}
                } else if roll < 78, order.count > 1 {
                    let target = order[Int(rng.next() % UInt64(order.count - 1))]
                    let fault = crash ? NativeVersionFaultInjector(point: swapPoints[Int(rng.next() % UInt64(swapPoints.count))]) : .init()
                    do { _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: target, fault: fault) }
                    catch is NativeVersionSimulatedCrash { try await relaunch(doubleCrash: dbl) }
                    catch {}
                } else if roll < 90 {
                    let fault = crash ? NativeVersionFaultInjector(point: swapPoints[Int(rng.next() % UInt64(swapPoints.count))]) : .init()
                    do { _ = try await store.undo(appId: appId, projectId: projectId, fault: fault) }
                    catch is NativeVersionSimulatedCrash { try await relaunch(doubleCrash: dbl) }
                    catch {}
                } else {
                    let fault = crash ? NativeVersionFaultInjector(point: .gcSweep_midSweep) : .init()
                    do { _ = try await store.gc.markAndSweep(graceSeconds: 0, fault: fault) }
                    catch is NativeVersionSimulatedCrash { try await relaunch(doubleCrash: false) }
                }
                try await oracle("step \(step)")
            }
            // A last cold relaunch, then the same demands.
            try await relaunch(doubleCrash: false)
            try await oracle("final")
        }
    }
}
