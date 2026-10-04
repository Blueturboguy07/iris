import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeKeepCountRetentionTests: XCTestCase {
    func testEightDistinctRevisionsAtTwoKeepOnlyCurrentAndFallbackButKeepEveryLedgerRow() async throws {
        // SPEC check 6. Eight generated package hashes have an independently recorded oldest-to-newest order.
        // MUTATION: a no-op prune or off-by-one keep rule leaves an older object readable or drops a ledger row.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.history(count: 8, keep: .keepTwo)
        XCTAssertEqual(result.rows.count, 8)
        XCTAssertEqual(result.usableHashes, Set(result.expectedOrder.suffix(2)))
        XCTAssertEqual(result.rows.map(\.id), Array(result.expectedOrder.reversed()))
    }

    func testThreeAndFiveKeepNewestOrdinaryHistory() async throws {
        // SPEC check 7. Separate generated stores prevent one K from contaminating the other oracle.
        // MUTATION: selecting the wrong number of ordinary slots fails the independent expected-hash sets.
        for (keep, count) in [(VersionsKeptPerApp.keepThree, 3), (.keepFive, 5)] {
            let world = try KCBWorld(); defer { world.cleanup() }
            let result = try await world.history(count: 8, keep: keep)
            XCTAssertEqual(result.usableHashes, Set(result.expectedOrder.suffix(count)))
        }
    }

    func testFewerRevisionsThanKeepChoicePreservesEveryGeneratedHash() async throws {
        // SPEC check 8. The three package hashes are captured before storage calls.
        // MUTATION: a fixed-size truncation removes a real version when K exceeds history length.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.history(count: 3, keep: .keepFive)
        XCTAssertEqual(result.usableHashes, Set(result.expectedOrder))
    }

    func testPinningThirdHistoricalVersionAtDefaultKeepsItsObjectHashReadable() async throws {
        // SPEC check 10. The test reads the pinned object's content and hashes it independently.
        // MUTATION: pruning ignores a pin outside the ordinary K slots and deletes the selected object.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.history(count: 5, keep: .keepTwo, pinThirdHistorical: true)
        XCTAssertTrue(result.pinned.contains(result.expectedOrder[2]))
        XCTAssertTrue(result.usableHashes.contains(result.expectedOrder[2]))
        XCTAssertEqual(result.rows.count, 5)
    }

    func testCatalogUnavailableRevisionsRemainReadableAndAreProjectedAsProtected() async throws {
        // SPEC checks 11 and 20. Catalog offers only newest and one prior; bytes and row words are separate oracles.
        // MUTATION: treating missing catalog offers as permission to collect removes bytes that cannot be downloaded.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.history(count: 8, keep: .keepTwo, catalogLimit: 2)
        XCTAssertTrue(result.protectedUnavailableHashes.isSubset(of: result.usableHashes))
        let protectedRows = result.rows.filter { result.protectedUnavailableHashes.contains($0.revision.revisionId) }
        XCTAssertEqual(protectedRows.count, result.protectedUnavailableHashes.count)
        XCTAssertTrue(protectedRows.allSatisfy { $0.isOnThisPhone && !$0.canDownload && $0.storageStateLabel == "Kept on this iPhone (not available to download)" })
    }

    func testLocalOnlyRevisionReviewedLocallyAndUnavailableHistoryBothSurviveLowering() async throws {
        // SPEC checks 11 and 20. L enters via the local review path and the offer actor independently withdraws U.
        // MUTATION: count pruning that frees either non-downloadable hash fails the byte and row-state assertions, while a no-op prune fails the eligible-old assertion.
        let world = try KCBWorld(); defer { world.cleanup() }
        let built = try await world.build(count: 5, keep: .keepAll, catalogLimit: nil)
        let localPackage = try KCBPackage.make(root: world.root, appId: "kcb.app", projectId: "kcb.project", index: 30, base: built.order.last)
        let localReview = try await built.coordinator.reviewImport(packageBytes: localPackage.bytes, expectedIdentity: built.identity)
        try await built.coordinator.approvePendingReviewLocallyAndStage(reviewToken: localReview.reviewToken, packageSHA256: localReview.packageSHA256)
        try await built.coordinator.activate(identity: built.identity, revisionId: localPackage.revisionId)
        let localHash = KCBPackage.sha256(localPackage.contentBytes)
        var childBase = localPackage.revisionId
        for index in 31...32 {
            let child = try KCBPackage.make(root: world.root, appId: "kcb.app", projectId: "kcb.project", index: index, base: childBase)
            _ = try await built.store.stage(packageBytes: child.bytes, approvalAuthority: child.authority)
            await built.catalog.insert(child.revisionId)
            try await built.coordinator.activate(identity: built.identity, revisionId: child.revisionId)
            childBase = child.revisionId
        }
        let unavailableId = built.order[2]
        await built.catalog.remove(unavailableId)
        try await built.coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let rows = try await built.coordinator.featureHistory(identity: built.identity)
        let localRow = try XCTUnwrap(rows.first { $0.revision.revisionId == localPackage.revisionId })
        let unavailableRow = try XCTUnwrap(rows.first { $0.revision.revisionId == unavailableId })
        XCTAssertTrue(localRow.isOnThisPhone && !localRow.canDownload)
        XCTAssertEqual(localRow.storageStateLabel, "Kept on this iPhone (not available to download)")
        XCTAssertTrue(unavailableRow.isOnThisPhone && !unavailableRow.canDownload)
        XCTAssertEqual(unavailableRow.storageStateLabel, "Kept on this iPhone (not available to download)")
        let diskHashes = try KCBDisk.storedContentHashes(under: world.root)
        XCTAssertTrue(diskHashes.contains(localHash))
        XCTAssertTrue(diskHashes.contains(built.hashes[unavailableId]!))
        XCTAssertFalse(diskHashes.contains(built.hashes[built.order[0]]!), "an offered excess version must be freed by this same prune")
    }

    func testLoweringKeepCountImmediatelyReclaimsOnlyEligibleAllocatedObjects() async throws {
        // SPEC checks 14 and 6. Compare lstat block allocation with inode de-duplication and independently hashed objects.
        // MUTATION: deferring count prune until a later update leaves excess allocated objects on disk here.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.lowerAfterBuildingEight()
        XCTAssertEqual(result.actualAfter, Set(result.expectedOrder.suffix(2)))
        XCTAssertEqual(result.allocatedBefore - result.allocatedAfter, result.reportedBytes, "reported bytes must match independent st_blocks reduction")
        XCTAssertEqual(result.rows.count, 8)
    }

    func testFeaturesHistoryProjectsEveryStorageStateAndDownloadFlag() async throws {
        // Contract section 4. Arrange each state through stored roles, catalog eligibility, and a genuinely freed revision.
        // MUTATION: collapsing state projection to manifest presence gives the wrong state word or download action.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.stateTableFixture()
        XCTAssertEqual(result.states["current"]?.label, "On this iPhone now")
        XCTAssertEqual(result.states["current"]?.canDownload, false)
        XCTAssertEqual(result.states["fallback"]?.label, "Kept as backup")
        XCTAssertEqual(result.states["fallback"]?.canDownload, false)
        XCTAssertEqual(result.states["pending"]?.label, "Downloaded, not switched on yet")
        XCTAssertEqual(result.states["pending"]?.canDownload, false)
        XCTAssertEqual(result.states["pinned"]?.label, "Pinned: kept until you unpin it")
        XCTAssertEqual(result.states["pinned"]?.canDownload, false)
        XCTAssertEqual(result.states["unavailable"]?.label, "Kept on this iPhone (not available to download)")
        XCTAssertEqual(result.states["unavailable"]?.canDownload, false)
        XCTAssertEqual(result.states["kept"]?.label, "Kept (within your count)")
        XCTAssertEqual(result.states["kept"]?.canDownload, false)
        XCTAssertEqual(result.states["downloadable-absent"]?.label, "Not on this iPhone")
        XCTAssertEqual(result.states["downloadable-absent"]?.canDownload, true)
        XCTAssertEqual(result.states["unavailable-absent"]?.label, "No longer available")
        XCTAssertEqual(result.states["unavailable-absent"]?.canDownload, false)
    }

    func testCurrentRevisionFeatureRowUsesCurrentStateWords() async throws {
        // Contract section 4, current row. The independently staged active revision must not inherit the missing catalog state.
        // MUTATION: catalog-first labeling marks an active usable revision as unavailable or downloadable.
        try await KCBWorld().assertState("current", label: "On this iPhone now", downloadable: false, present: true)
    }

    func testFallbackRevisionFeatureRowUsesBackupStateWords() async throws {
        // Contract section 4, fallback row. The active pointer independently identifies the backup revision.
        // MUTATION: losing fallback precedence marks the rollback target as ordinary history.
        try await KCBWorld().assertState("fallback", label: "Kept as backup", downloadable: false, present: true)
    }

    func testPendingRevisionFeatureRowUsesPendingStateWords() async throws {
        // Contract section 4, pending row. An unstaged activation candidate remains readable in the generated store.
        // MUTATION: omitting pending role projection labels a staged candidate as ordinary kept history.
        try await KCBWorld().assertState("pending", label: "Downloaded, not switched on yet", downloadable: false, present: true)
    }

    func testPinnedRevisionFeatureRowUsesPinStateWords() async throws {
        // Contract section 4, pinned row. The pin API and independent object hash establish the role.
        // MUTATION: ignoring pins in the Features join drops the pin label or offers an invalid download.
        try await KCBWorld().assertState("pinned", label: "Pinned: kept until you unpin it", downloadable: false, present: true)
    }

    func testUnavailableStoredRevisionFeatureRowUsesProtectedStateWords() async throws {
        // Contract section 4, unavailable stored row. The injected catalog omits this known package while its bytes remain.
        // MUTATION: treating catalog withdrawal as absent storage offers Download and hides the protected bytes.
        try await KCBWorld().assertState("unavailable", label: "Kept on this iPhone (not available to download)", downloadable: false, present: true)
    }

    func testOrdinaryKeptRevisionFeatureRowUsesCountStateWords() async throws {
        // Contract section 4, count-kept row. The independent current/fallback/keep-three arrangement leaves one ordinary slot.
        // MUTATION: collapsing kept-tier into absent or unavailable produces the wrong row state.
        try await KCBWorld().assertState("kept", label: "Kept (within your count)", downloadable: false, present: true)
    }

    func testFreedOfferedRevisionFeatureRowOffersDownload() async throws {
        // Contract section 4, absent but offered row. The fixture prunes its independently known object hash.
        // MUTATION: equating a freed manifest with stored files suppresses Download and reports the wrong state.
        try await KCBWorld().assertState("downloadable-absent", label: "Not on this iPhone", downloadable: true, present: false)
    }

    func testFreedWithdrawnRevisionFeatureRowSaysNoLongerAvailable() async throws {
        // Contract section 4, absent and unavailable row. Catalog withdrawal follows the completed prune.
        // MUTATION: offering a download for a withdrawn package creates a dead-end action.
        try await KCBWorld().assertState("unavailable-absent", label: "No longer available", downloadable: false, present: false)
    }

    func testTiedCreationTimesUseRevisionIdAsStableOrder() async throws {
        // SPEC 2.5: revision ordering must not depend on the device clock or input dictionary iteration.
        // MUTATION: phone-clock or input-order sorting changes the independently recorded expected survivor.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.tiedRevisionOrder()
        XCTAssertEqual(result.survivors, result.expectedRevisionIdOrder)
    }

    func testLegacyMigrationPreservesEightHashesThroughFirstLaunchThenNextPruneAppliesTwo() async throws {
        // SPEC check 19 and section 4 item 15. The legacy source hash list is captured before migration.
        // MUTATION: migration-time pruning loses a preexisting version before the explicit next ordinary prune.
        let world = try KCBWorld(); defer { world.cleanup() }
        let result = try await world.migrationAndNextPrune()
        XCTAssertEqual(result.hashesAfterMigration, result.hashesBeforeMigration)
        XCTAssertEqual(result.migrationWarning, "Older versions will be cleared the next time Iris tidies storage.")
        XCTAssertEqual(result.hashesAfterNextPrune, Set(result.expectedOrder.suffix(2)))
        XCTAssertGreaterThan(result.allocatedBeforePrune - result.allocatedAfterPrune, 0, "the next ordinary prune must independently reclaim object blocks")
    }
}

private final class KCBWorld {
    struct KCBHistoryResult {
        let rows: [NativeRevisionHistoryRow]
        let expectedOrder: [String]
        let usableHashes: Set<String>
        let pinned: Set<String>
        let protectedUnavailableHashes: Set<String>
    }
    struct KCBLowerResult {
        let actualAfter: Set<String>; let expectedOrder: [String]; let allocatedBefore: Int64
        let allocatedAfter: Int64; let reportedBytes: Int64; let rows: [NativeRevisionHistoryRow]
    }
    struct KCBStateValue: Equatable { let label: String; let canDownload: Bool; let isOnThisPhone: Bool }
    struct KCBStateResult { let states: [String: KCBStateValue] }
    struct KCBTieResult { let survivors: [String]; let expectedRevisionIdOrder: [String] }
    struct KCBMigrationResult {
        let hashesBeforeMigration: Set<String>; let hashesAfterMigration: Set<String>
        let migrationWarning: String?; let hashesAfterNextPrune: Set<String>; let expectedOrder: [String]
        let allocatedBeforePrune: Int64; let allocatedAfterPrune: Int64
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kcb-\(UUID().uuidString)", isDirectory: true)
    private let defaultsSuiteName = "kcb-\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: defaultsSuiteName)!
    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuiteName) }

    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    // The test authoring unit intentionally expresses these scenarios through the public actor surface.
    // Package generation and legacy fixture wiring are centralized here so every call gets isolated state.
    func history(count: Int, keep: VersionsKeptPerApp, pinThirdHistorical: Bool = false, catalogLimit: Int? = nil) async throws -> KCBHistoryResult {
        let built = try await build(count: count, keep: keep, catalogLimit: catalogLimit)
        if pinThirdHistorical { try await built.store.pin(revisionId: built.order[count - 3]) }
        try await built.coordinator.setVersionKeepCount(keep, defaults: defaults)
        let report = try await built.store.pruneStorage()
        let rows = try await built.coordinator.featureHistory(identity: built.identity)
        let hashes = try KCBDisk.usableObjectRevisionIds(root: root, order: built.order, expectedHashes: built.hashes)
        XCTAssertEqual(report.retainedRevisionIds, hashes, "public prune projection must match readable generated object hashes")
        return KCBHistoryResult(rows: rows, expectedOrder: built.order, usableHashes: hashes,
                             pinned: Set(try await built.store.pinnedRevisionIds()),
                             protectedUnavailableHashes: Set(catalogLimit == nil ? [] : built.order.dropLast(catalogLimit!)))
    }

    func lowerAfterBuildingEight() async throws -> KCBLowerResult {
        let built = try await build(count: 8, keep: .keepAll)
        try await built.coordinator.setVersionKeepCount(.keepFive, defaults: defaults)
        let before = try KCBDisk.allocated(root: root)
        let outcome = try await built.coordinator.setVersionKeepCount(.keepTwo, defaults: defaults)
        let after = try KCBDisk.allocated(root: root)
        let rows = try await built.coordinator.featureHistory(identity: built.identity)
        return KCBLowerResult(actualAfter: try KCBDisk.usableObjectRevisionIds(root: root, order: built.order, expectedHashes: built.hashes),
                           expectedOrder: built.order, allocatedBefore: before, allocatedAfter: after,
                           reportedBytes: outcome.bytesReclaimed, rows: rows)
    }

    func stateTableFixture() async throws -> KCBStateResult {
        let built = try await build(count: 8, keep: .keepAll, catalogLimit: nil)
        try await built.store.pin(revisionId: built.order[4])
        await built.catalog.remove(built.order[3])
        let pending = try KCBPackage.make(root: root, appId: "kcb.app", projectId: "kcb.project", index: 8, base: built.order[7])
        _ = try await built.store.stage(packageBytes: pending.bytes, approvalAuthority: pending.authority)
        await built.catalog.insert(pending.revisionId)
        try await built.coordinator.setVersionKeepCount(.keepThree, defaults: defaults)
        _ = try await built.store.pruneStorage()
        await built.catalog.remove(built.order[0])
        await built.catalog.remove(built.order[6])
        await built.catalog.remove(built.order[7])
        let rows = try await built.coordinator.featureHistory(identity: built.identity)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.revision.revisionId, $0) })
        var states: [String: KCBStateValue] = [:]
        for (key, id) in [("current", built.order[7]), ("fallback", built.order[6]),
                          ("pending", pending.revisionId), ("pinned", built.order[4]),
                          ("unavailable", built.order[3]), ("kept", built.order[5]),
                          ("downloadable-absent", built.order[2]), ("unavailable-absent", built.order[0])] {
            let row = try XCTUnwrap(byId[id], "ledger row for \(key)")
            states[key] = KCBStateValue(label: row.storageStateLabel, canDownload: row.canDownload, isOnThisPhone: row.isOnThisPhone)
            XCTAssertEqual(row.isOnThisPhone, ["current", "fallback", "pending", "pinned", "unavailable", "kept"].contains(key), key)
        }
        XCTAssertEqual(states["current"]?.label, "On this iPhone now", "catalog absence cannot override current")
        XCTAssertEqual(states["fallback"]?.label, "Kept as backup", "catalog absence cannot override fallback")
        return KCBStateResult(states: states)
    }

    func assertState(_ key: String, label: String, downloadable: Bool, present: Bool) async throws {
        defer { cleanup() }
        let result = try await stateTableFixture()
        XCTAssertEqual(result.states[key]?.label, label)
        XCTAssertEqual(result.states[key]?.canDownload, downloadable)
        XCTAssertEqual(result.states[key]?.isOnThisPhone, present)
    }

    func tiedRevisionOrder() async throws -> KCBTieResult {
        let ids = ["rev-z", "rev-a", "rev-m"]
        let facts = ids.map { NativeStorageRetentionPolicy.RevisionFact(revisionId: $0, baseRevisionId: nil, createdAt: "same-time") }
        let actual = NativeStorageRetentionPolicy.retainedRevisionIds(revisions: facts, currentRevisionId: "rev-z", fallbackRevisionId: nil, pinnedRevisionIds: [], localOnlyRevisionIds: [], downloadableRevisionIds: Set(ids), keepCount: 2)
        return KCBTieResult(survivors: actual.sorted(), expectedRevisionIdOrder: ["rev-m", "rev-z"])
    }

    func migrationAndNextPrune() async throws -> KCBMigrationResult {
        let app = "kcb.app", project = "kcb.project", identity = NativeShellAppIdentity(appId: app, projectId: project)
        let legacy = root.appendingPathComponent("content/\(app)/\(project)/revisions", isDirectory: true)
        var expectedOrder: [String] = []; var expectedHashesByRevision: [String: Set<String>] = [:]; var base: String?
        for index in 0..<8 {
            let package = try KCBPackage.make(root: root, appId: app, projectId: project, index: index + 100, base: base)
            let receipt = try DeliveryPackageV1Validator().validate(packageBytes: package.bytes, approvalAuthority: package.authority)
            expectedOrder.append(receipt.revisionId); base = receipt.revisionId
            expectedHashesByRevision[receipt.revisionId] = Set(receipt.files.map { KCBPackage.sha256($0.data) })
            let manifest: [String: Any] = [
                "displayName": receipt.manifest.displayName,
                "runtimeType": receipt.manifest.runtimeType,
                "entrypoint": receipt.manifest.entrypoint,
                "minShellVersion": receipt.manifest.minShellVersion,
                "requestedCapabilities": receipt.manifest.requestedCapabilities,
                "dataNamespace": receipt.manifest.dataNamespace,
                "dataUpdatePolicy": receipt.manifest.dataUpdatePolicy,
            ]
            let receiptFiles: [[String: Any]] = receipt.files.map { file in
                ["path": file.path, "sha256": file.sha256, "bytes": file.bytes, "mediaType": file.mediaType]
            }
            let object: [String: Any] = [
                "contractVersion": receipt.contractVersion,
                "appId": receipt.appId,
                "projectId": receipt.projectId,
                "baseRevisionId": receipt.baseRevisionId.map { $0 as Any } ?? NSNull(),
                "revisionId": receipt.revisionId,
                "manifestHash": receipt.manifestHash,
                "contentHash": receipt.contentHash,
                "createdAt": receipt.createdAt,
                "manifest": manifest,
                "files": receiptFiles,
            ]
            let revisionRoot = legacy.appendingPathComponent(receipt.revisionId, isDirectory: true)
            var metadataFiles: [[String: Any]] = []
            for (file, record) in zip(receipt.files, receiptFiles) {
                let destination = revisionRoot.appendingPathComponent("content", isDirectory: true).appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: destination)
                var metadataFile = record; metadataFile.removeValue(forKey: "data"); metadataFiles.append(metadataFile)
            }
            var metadata = object; metadata["files"] = metadataFiles
            try FileManager.default.createDirectory(at: revisionRoot, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: revisionRoot.appendingPathComponent("metadata.json"))
        }
        let pointer = try NativeVersionStateFiles(root: root.appendingPathComponent("state"))
        try pointer.writeActive(NativeVersionActivePointer(currentRevisionId: expectedOrder[7], fallbackRevisionId: expectedOrder[6]), appId: app, projectId: project)
        let hashesBefore = expectedHashesByRevision.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        let sentinelURL = root.appendingPathComponent("reader-data/kcb.app/sentinel.txt")
        try FileManager.default.createDirectory(at: sentinelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("reader data belongs to the person".utf8); try sentinel.write(to: sentinelURL)
        let offered = KCBCatalog(Set(expectedOrder))
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, defaults: defaults, downloadableRevisionIds: { _ in await offered.values() })
        _ = try await coordinator.refreshLibrary()
        _ = try await coordinator.launchActive(identity: identity)
        let hashesAfterMigration = try KCBDisk.storedContentHashes(under: root)
        let store = try NativeRevisionStore(rootURL: root, appId: app, projectId: project, shellVersion: "1.0.0", defaults: defaults, downloadableRevisionIds: { _ in await offered.values() })
        _ = try await store.revisionSummaries()
        let warning = await store.storageMigrationWarning()
        let storeAgain = try NativeRevisionStore(rootURL: root, appId: app, projectId: project, shellVersion: "1.0.0", defaults: defaults, downloadableRevisionIds: { _ in await offered.values() })
        let warningAfterReconstruction = await storeAgain.storageMigrationWarning()
        XCTAssertEqual(warningAfterReconstruction, "Older versions will be cleared the next time Iris tidies storage.")
        let hashesAfterFirstLaunch = try KCBDisk.storedContentHashes(under: root)
        let allocatedBefore = try KCBDisk.allocated(root: root)
        _ = try await coordinator.pruneStorage(identity: identity)
        let allocatedAfter = try KCBDisk.allocated(root: root)
        let remainingHashes = try KCBDisk.storedContentHashes(under: root)
        let expectedRemaining = expectedOrder.suffix(2).reduce(into: Set<String>()) { $0.formUnion(expectedHashesByRevision[$1] ?? []) }
        XCTAssertEqual(hashesAfterMigration.intersection(hashesBefore), hashesBefore)
        XCTAssertEqual(hashesAfterFirstLaunch.intersection(hashesBefore), hashesBefore)
        let sentinelAfterPrune = try Data(contentsOf: sentinelURL)
        XCTAssertEqual(sentinelAfterPrune, sentinel)
        XCTAssertEqual(remainingHashes.intersection(hashesBefore), expectedRemaining)
        return KCBMigrationResult(hashesBeforeMigration: hashesBefore, hashesAfterMigration: hashesAfterMigration.intersection(hashesBefore),
            migrationWarning: warning, hashesAfterNextPrune: Set(expectedOrder.suffix(2)), expectedOrder: expectedOrder,
            allocatedBeforePrune: allocatedBefore, allocatedAfterPrune: allocatedAfter)
    }

    fileprivate struct KCBBuilt { let store: NativeRevisionStore; let coordinator: NativeShellLibraryCoordinator; let identity: NativeShellAppIdentity; let order: [String]; let hashes: [String: String]; let catalog: KCBCatalog }
    fileprivate func build(count: Int, keep: VersionsKeptPerApp, catalogLimit: Int? = nil) async throws -> KCBBuilt {
        let app = "kcb.app"; let project = "kcb.project"; let identity = NativeShellAppIdentity(appId: app, projectId: project)
        let offered = KCBCatalog([])
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, defaults: defaults, downloadableRevisionIds: { _ in await offered.values() })
        let store = try NativeRevisionStore(rootURL: root, appId: app, projectId: project, shellVersion: "1.0.0", defaults: defaults, downloadableRevisionIds: { _ in await offered.values() })
        try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)
        var order: [String] = []; var hashes: [String: String] = [:]; var base: String?
        for index in 0..<count {
            let pkg = try KCBPackage.make(root: root, appId: app, projectId: project, index: index, base: base)
            _ = try await store.stage(packageBytes: pkg.bytes, approvalAuthority: pkg.authority)
            try await coordinator.activate(identity: identity, revisionId: pkg.revisionId)
            order.append(pkg.revisionId); hashes[pkg.revisionId] = pkg.contentHash; base = pkg.revisionId
            await offered.insert(pkg.revisionId)
        }
        if let catalogLimit { await offered.replace(Set(order.suffix(catalogLimit))) }
        return KCBBuilt(store: store, coordinator: coordinator, identity: identity, order: order, hashes: hashes, catalog: offered)
    }
}

private enum KCBDisk {
    static func allocated(root: URL) throws -> Int64 {
        var inodes = Set<String>(); var bytes: Int64 = 0
        let objectRoot = root.appendingPathComponent("objects", isDirectory: true)
        guard let walk = FileManager.default.enumerator(atPath: objectRoot.path) else { return 0 }
        for case let relative as String in walk {
            let path = objectRoot.appendingPathComponent(relative).path; var statbuf = stat()
            guard lstat(path, &statbuf) == 0, (statbuf.st_mode & S_IFMT) == S_IFREG else { continue }
            let key = "\(statbuf.st_dev):\(statbuf.st_ino)"
            if inodes.insert(key).inserted { bytes += Int64(statbuf.st_blocks) * 512 }
        }
        return bytes
    }
    static func usableObjectRevisionIds(root: URL, order: [String], expectedHashes: [String: String]) throws -> Set<String> {
        Set(try order.filter { revision in
            guard let hash = expectedHashes[revision] else { return false }
            let object = root.appendingPathComponent("objects/\(hash.prefix(2))/\(hash)")
            guard let bytes = try? Data(contentsOf: object) else { return false }
            return KCBPackage.sha256(bytes) == hash
        })
    }
    static func contentHashes(under root: URL) throws -> Set<String> {
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result = Set<String>()
        for case let url as URL in walk where url.lastPathComponent != "metadata.json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            result.insert(KCBPackage.sha256(try Data(contentsOf: url)))
        }
        return result
    }
    static func storedContentHashes(under root: URL) throws -> Set<String> {
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result = Set<String>()
        for case let url as URL in walk {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let bytes = try Data(contentsOf: url)
            result.insert(KCBPackage.sha256(bytes))
        }
        return result
    }
}

private actor KCBCatalog {
    private var offered: Set<String>
    init(_ offered: Set<String>) { self.offered = offered }
    func values() -> Set<String> { offered }
    func insert(_ id: String) { offered.insert(id) }
    func remove(_ id: String) { offered.remove(id) }
    func replace(_ ids: Set<String>) { offered = ids }
}

private enum KCBLegacyFixture {
    struct KCBLegacyRevision {
        let id: String
        let base: String?
        let files: [(path: String, data: Data)]
        let createdAt: String
    }
    static func files(seed: UInt64) -> [(path: String, data: Data)] {
        (0..<3).map { index in
            var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
            let bytes = Data((0..<128).map { _ in value = value &* 6364136223846793005 &+ 1442695040888963407; return UInt8(truncatingIfNeeded: value >> 32) })
            return ("assets/file-\(index).bin", bytes)
        }
    }
    static func write(revisions: [KCBLegacyRevision], to root: URL) throws {
        for revision in revisions {
            let dir = root.appendingPathComponent(revision.id, isDirectory: true)
            var entries: [LegacyStoredManifestFile] = []
            for file in revision.files {
                let dest = dir.appendingPathComponent("content", isDirectory: true).appendingPathComponent(file.path)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: dest)
                entries.append(.init(path: file.path, sha256: KCBPackage.sha256(file.data), bytes: file.data.count, mediaType: "application/octet-stream"))
            }
            let metadata = LegacyStoredRevisionMetadata(contractVersion: 1, appId: "legacy", projectId: "legacy", baseRevisionId: revision.base, revisionId: revision.id,
                manifestHash: "sha256:" + String(repeating: "0", count: 64), contentHash: "sha256:" + String(repeating: "0", count: 64), createdAt: revision.createdAt,
                manifest: LegacyStoredAppManifest(displayName: "Legacy Keep Count", runtimeType: "web", entrypoint: "assets/file-0.bin", minShellVersion: "1.0.0", requestedCapabilities: [], dataNamespace: "kcb.app", dataUpdatePolicy: "preserve"),
                files: entries, changes: nil)
            try JSONEncoder().encode(metadata).write(to: dir.appendingPathComponent("metadata.json"))
        }
    }
}

private enum KCBPackage {
    struct KCBGenerated { let bytes: Data; let revisionId: String; let contentHash: String; let contentBytes: Data; let authority: KCBPackageApproval }
    struct KCBPackageApproval: DeliveryApprovalAuthority {
        let approval: TrustedDeliveryApproval
        func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? { approval.approvalId == approvalId ? approval : nil }
    }
    static func make(root: URL, appId: String, projectId: String, index: Int, base: String?) throws -> KCBGenerated {
        let content = Data("person revision \(index) \(UUID().uuidString)".utf8)
        let hash = sha256(content)
        // This helper delegates valid package construction to the repository fixture generator.
        let generator = repositoryRoot().appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", generator.path, "--output", root.appendingPathComponent("pkg-\(index)").path,
                            "--base", base ?? "null", "--nonce", UUID().uuidString, "--namespace", appId,
                            "--capabilities", "[]", "--app", appId, "--project", projectId,
                            "--content", String(decoding: content, as: UTF8.self)]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe(); try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "KCBPackage", code: Int(process.terminationStatus)) }
        let object = try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as! [String: Any]
        let path = URL(fileURLWithPath: object["packagePath"] as! String); let bytes = try Data(contentsOf: path)
        let approvalData = try Data(contentsOf: URL(fileURLWithPath: object["trustedApprovalPath"] as! String))
        let approvalObject = try JSONSerialization.jsonObject(with: approvalData) as! [String: Any]
        func approvalText(_ key: String) throws -> String { try XCTUnwrap(approvalObject[key] as? String) }
        func approvalOptional(_ key: String) throws -> String? {
            approvalObject[key] is NSNull ? nil : try approvalText(key)
        }
        let approval = TrustedDeliveryApproval(
            approvalId: try approvalText("approvalId"), requestId: try approvalOptional("requestId"),
            requestNonce: try approvalOptional("requestNonce"), appId: try approvalText("appId"),
            projectId: try approvalText("projectId"), baseRevisionId: try approvalOptional("baseRevisionId"),
            approvedRevisionId: try approvalText("approvedRevisionId"),
            approvedContentHash: try approvalText("approvedContentHash"), approvedAt: try approvalText("approvedAt")
        )
        let revisionId = object["revisionId"] as! String
        return KCBGenerated(bytes: bytes, revisionId: revisionId, contentHash: hash, contentBytes: content, authority: KCBPackageApproval(approval: approval))
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func repositoryRoot() -> URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
}
