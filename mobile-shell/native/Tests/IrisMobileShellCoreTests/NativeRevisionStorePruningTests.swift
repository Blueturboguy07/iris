import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// End-to-end tests for `NativeRevisionStore`/`NativeShellLibraryCoordinator`
/// bounded storage, driven through the real desktop CLI (the same
/// stage/approve/deliver pipeline `NativeRevisionStoreTests` uses), never
/// through a fake or a mock of the store itself. Every package staged here
/// is a real, validator-accepted `.irisapp` produced by a real subprocess;
/// every "does it open" assertion re-verifies real bytes on a real
/// filesystem, including real APFS `clonefile` sharing for the small apps'
/// unchanged files.
final class NativeRevisionStorePruningTests: XCTestCase {
    func testMonthsOfUpdatesAcross20AppsStayWithinTheBoundAndEveryKeptRevisionOpens() async throws {
        scenario: for keepChoice in [VersionsKeptPerApp.keepTwo, .keepAll] {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let suite = "iris-retention-scale-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = NativeRevisionPruningCatalogFixture()
        let offers: @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { identity in
            await catalog.offers(for: identity)
        }
        let coordinator = NativeShellLibraryCoordinator(
            rootURL: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: offers
        )
        if keepChoice == .keepAll {
            try await coordinator.setVersionKeepCount(.keepAll)
        }

        let appCount = 20
        let monthCount = 12
        // Two of the twenty are Kneecap-like: PLAN.md section 6, "Kneecap's
        // classic bundle is one 5.98 MB script that changes on every edit."
        let kneecapLikeAppIndexes: Set<Int> = [0, 11]

        struct AppTimeline {
            let appId: String
            let projectId: String
            let packages: [PruningFixture.GeneratedPackage]
        }
        var timelines: [AppTimeline] = []

        for appIndex in 0..<appCount {
            let appId = "iris.storage-scale-app-\(appIndex)"
            let projectId = "\(appId).mobile"
            let store = try fixture.makeStore(
                appId: appId, projectId: projectId, defaults: defaults, downloadableRevisionIds: offers
            )
            var baseRevisionId: String?
            var packages: [PruningFixture.GeneratedPackage] = []
            for month in 0..<monthCount {
                let nonce = fixture.nonce("scale-\(appIndex)-\(month)")
                let generated: PruningFixture.GeneratedPackage
                if kneecapLikeAppIndexes.contains(appIndex) {
                    generated = try fixture.stageLargeSingleFileRevision(
                        appId: appId, projectId: projectId,
                        seed: UInt64(appIndex * 1_000 + month), approxBytes: 6 * 1024 * 1024,
                        baseRevisionId: baseRevisionId, nonce: nonce
                    )
                } else {
                    generated = try fixture.stageSmallRevision(
                        appId: appId, projectId: projectId, month: month,
                        baseRevisionId: baseRevisionId, nonce: nonce, includeSharedAsset: true
                    )
                }
                await catalog.offer(generated.revisionId, appId: appId, projectId: projectId)
                _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
                try await coordinator.activate(
                    identity: .init(appId: appId, projectId: projectId),
                    revisionId: generated.revisionId
                )
                packages.append(generated)
                baseRevisionId = generated.revisionId
            }
            timelines.append(AppTimeline(appId: appId, projectId: projectId, packages: packages))
        }

        let roomyPlan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        XCTAssertEqual(roomyPlan.reclaimableBytes, 0, "the generated history fits the specified 2 GB cap")
        for timeline in timelines {
            let store = try fixture.makeStore(
                appId: timeline.appId, projectId: timeline.projectId, defaults: defaults,
                downloadableRevisionIds: offers
            )
            let summaries = try await store.revisionSummaries()
            let expectedCountRetained = keepChoice == .keepAll
                ? Set(timeline.packages.map(\.revisionId))
                : Set(timeline.packages.suffix(2).map(\.revisionId))
            // MUTATION: retaining the wrong K-selected revisions loses independently generated IDs.
            // PRE-2026-10-01-DECISION: revisit with the keep-count setting
            // RESOLVED 2026-10-01: expectation now K-based
            XCTAssertEqual(Set(summaries.map(\.revisionId)), Set(timeline.packages.map(\.revisionId)),
                           "the version ledger keeps every independently generated revision row")
            // PRE-2026-10-01-DECISION: revisit with the keep-count setting
            // RESOLVED 2026-10-01: expectation now K-based
            XCTAssertEqual(summaries.count, monthCount, "all version rows remain unique after count pruning")
            // PRE-2026-10-01-DECISION: revisit with the keep-count setting
            // RESOLVED 2026-10-01: expectation now K-based
            XCTAssertEqual(try fixture.availableRevisionIds(summaries.map(\.revisionId), packages: timeline.packages),
                           expectedCountRetained,
                           "each independently selected kept version opens")
            let entry = try await coordinator.libraryEntry(identity: .init(appId: timeline.appId, projectId: timeline.projectId))
            XCTAssertEqual(entry?.currentRevisionId, timeline.packages[11].revisionId)
            XCTAssertEqual(entry?.fallbackRevisionId, timeline.packages[10].revisionId)

            // Each probe starts at the newest version, so every target is an ancestor.
            // Return via the actual fallback after each probe, preserving the forward guard.
            for package in timeline.packages.filter({ expectedCountRetained.contains($0.revisionId) }).reversed() {
                try await store.rollback(to: package.revisionId)
                let launch = try await store.launchDescriptorForActiveRevision()
                XCTAssertEqual(launch.revisionId, package.revisionId)
                try fixture.assertExactLaunch(launch.readAccessRootURL, matches: package)
                try await store.rollback(to: timeline.packages[11].revisionId)
            }
            try await store.rollback(to: timeline.packages[10].revisionId)
            try await store.rollback(to: timeline.packages[11].revisionId)
        }

        // The disk walker measures the whole store once, so compare it with
        // the sum of independently generated per-app content and metadata bounds.
        let expectedStoreCeiling = timelines.reduce(Int64(0)) { total, timeline in
            total + fixture.distinctContentAllocatedBound(timeline.packages) + Int64(monthCount) * 16 * 1024
        }
        let totalAllocatedBytes = try fixture.codeAllocatedBytesOnDisk()
        XCTAssertLessThanOrEqual(totalAllocatedBytes, expectedStoreCeiling,
                                 "distinct fixture content plus 16 KiB metadata per revision across all apps")

        // The default-count pass checks all 20 apps and the bound. The Keep all pass below
        // exercises the same 20-app history against the independent cap and byte oracle.
        if keepChoice == .keepTwo { continue scenario }

        // Explicit fixture archives keep every package available for this synthetic
        // reclaim scenario. This is not permission to free an unavailable real package
        // or a phone-local build (SPEC 8.3 overrides the earlier cap policy).
        var protected: Set<String> = []
        var pendingPackages: [String: PruningFixture.GeneratedPackage] = [:]
        var candidates: [PruningFixture.GeneratedPackage] = []
        for timeline in timelines {
            let store = try fixture.makeStore(
                appId: timeline.appId, projectId: timeline.projectId, defaults: defaults,
                downloadableRevisionIds: offers
            )
            try await store.pin(revisionId: timeline.packages[1].revisionId)
            let pending = try fixture.stageSmallRevision(
                appId: timeline.appId, projectId: timeline.projectId, month: monthCount,
                baseRevisionId: timeline.packages[11].revisionId,
                nonce: fixture.nonce("pending-\(timeline.appId)"), includeSharedAsset: true
            )
            await catalog.offer(pending.revisionId, appId: timeline.appId, projectId: timeline.projectId)
            _ = try await store.stage(packageBytes: pending.bytes, approvalAuthority: pending.authority)
            pendingPackages[timeline.appId] = pending
            protected.formUnion([timeline.packages[1].revisionId, timeline.packages[10].revisionId,
                                 timeline.packages[11].revisionId, pending.revisionId])
            candidates += timeline.packages.enumerated().filter { ![1, 10, 11].contains($0.offset) }.map(\.element)
        }
        let expectedOrder = candidates.sorted {
            ($0.createdAt, $0.revisionId) < ($1.createdAt, $1.revisionId)
        }.map(\.revisionId)
        // First free exactly the oldest version, whose generated 6 MiB file
        // is unique. Raw st_blocks change is independent even in the legacy
        // clone-tree layout: no other version references that content.
        let measured = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults).totalCodeBytes
        let diskBefore = try fixture.codeAllocatedBytesOnDisk()
        await coordinator.setGlobalCodeCapBytes(measured - 1, defaults: defaults)
        let firstPlan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        XCTAssertEqual(firstPlan.items.map(\.revisionId), Array(expectedOrder.prefix(1)), "oldest kept version goes first")
        XCTAssertEqual(firstPlan.items.first?.revisionId, timelines[0].packages[0].revisionId)
        let firstEnforced = try await coordinator.enforceGlobalCap(defaults: defaults)
        let diskAfter = try fixture.codeAllocatedBytesOnDisk()
        // Mutation: logical-size accounting or a no-op removal disagrees with real st_blocks.
        XCTAssertEqual(Double(firstEnforced.reclaimableBytes), Double(diskBefore - diskAfter), accuracy: 4096,
                       "freed allocated bytes match the independent disk change within one block")
        XCTAssertGreaterThan(firstEnforced.reclaimableBytes, 0)
        XCTAssertEqual(firstEnforced.reclaimableBytes % 512, 0,
                       "allocated-byte promises use st_blocks units, never unrounded logical lengths")

        // Then exhaust the kept tier. Sharing in the small apps is still
        // charged by the independent distinct-content ceiling above.
        await coordinator.setGlobalCodeCapBytes(1, defaults: defaults)
        let plan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        // Mutation: newest-first reclamation disagrees with the fixture package timestamps.
        XCTAssertEqual(plan.items.map(\.revisionId), Array(expectedOrder.dropFirst()), "oldest kept versions across all apps go first")
        XCTAssertTrue(protected.isDisjoint(with: Set(plan.items.map(\.revisionId))), "no retained role is reclaimable")
        let enforced = try await coordinator.enforceGlobalCap(defaults: defaults)
        XCTAssertGreaterThan(enforced.reclaimableBytes, 0)
        for timeline in timelines {
            let store = try fixture.makeStore(
                appId: timeline.appId, projectId: timeline.projectId, defaults: defaults,
                downloadableRevisionIds: offers
            )
            let summaries = try await store.revisionSummaries()
            let pending = try XCTUnwrap(pendingPackages[timeline.appId])
            let kept = try fixture.availableRevisionIds(summaries.map(\.revisionId),
                                                       packages: timeline.packages + [pending])
            let removed = timeline.packages.filter { expectedOrder.contains($0.revisionId) }
            XCTAssertTrue(Set(removed.map(\.revisionId)).isDisjoint(with: kept), "freed versions are not listed as openable")
            // Mutation: cap enforcement freeing a pin, fallback, current or pending fails this set assertion.
            let expectedProtected = Set([timeline.packages[1].revisionId, timeline.packages[10].revisionId,
                                         timeline.packages[11].revisionId, pending.revisionId])
            XCTAssertEqual(kept, expectedProtected, "only retained roles survive the forced cap")
            XCTAssertTrue(kept.contains(timeline.packages[1].revisionId), "pin survives")
            XCTAssertTrue(kept.contains(timeline.packages[10].revisionId), "fallback survives")
            XCTAssertTrue(kept.contains(timeline.packages[11].revisionId), "current survives")
            XCTAssertEqual(kept.count, 4, "current, fallback, pin and pending survive")
            // Mutation: a freed version still available fails pin refusal and rollback.
            for package in removed {
                await XCTAssertThrowsStorageError(
                    try await store.pin(revisionId: package.revisionId),
                    equals: .revisionNotAvailableToPin(package.revisionId)
                )
                do {
                    try await store.rollback(to: package.revisionId)
                    XCTFail("freed version must refuse an open: \(package.revisionId)")
                } catch { /* A freed version cannot be opened offline. */ }
            }
            for index in [1, 10] {
                try await store.rollback(to: timeline.packages[index].revisionId)
                let launch = try await store.launchDescriptorForActiveRevision()
                XCTAssertEqual(launch.revisionId, timeline.packages[index].revisionId)
                try fixture.assertExactLaunch(launch.readAccessRootURL, matches: timeline.packages[index])
                try await store.rollback(to: timeline.packages[11].revisionId)
            }
            try await store.activate(revisionId: pending.revisionId)
            let pendingLaunch = try await store.launchDescriptorForActiveRevision()
            XCTAssertEqual(pendingLaunch.revisionId, pending.revisionId)
            try fixture.assertExactLaunch(pendingLaunch.readAccessRootURL, matches: pending)
        }
        }
    }

    func testForceQuitBetweenTheRenameAndTheDeleteLeavesEveryListedRevisionUsableAndTheNextPruneFinishesCleanly() async throws {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let appId = "iris.storage-crash-app"
        let projectId = "\(appId).mobile"
        let store = try fixture.makeStore(appId: appId, projectId: projectId)

        let first = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 0, baseRevisionId: nil, nonce: fixture.nonce("crash-0"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let stale = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 1, baseRevisionId: first.revisionId, nonce: fixture.nonce("crash-stale"))
        _ = try await store.stage(packageBytes: stale.bytes, approvalAuthority: stale.authority)
        let winner = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 2, baseRevisionId: first.revisionId, nonce: fixture.nonce("crash-winner"))
        _ = try await store.stage(packageBytes: winner.bytes, approvalAuthority: winner.authority)
        try await store.activate(revisionId: winner.revisionId)
        // On disk right now: first (previous), winner (current), stale
        // (prunable: its base is `first`, not the new current `winner`).

        // Plant the object-store crash point: the manifest is tombstoned while
        // its objects remain untouched, as SPEC 2.4/2.5 prescribe.
        let manifestsRoot = fixture.storeRoot.appendingPathComponent("manifests", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: manifestsRoot, includingPropertiesForKeys: [.isRegularFileKey])!
        var tombstonedManifest: URL?
        while let candidate = enumerator.nextObject() as? URL {
            guard candidate.pathExtension == "json",
                  let data = try? Data(contentsOf: candidate),
                  String(data: data, encoding: .utf8)?.contains(stale.revisionId) == true else { continue }
            tombstonedManifest = candidate
            break
        }
        let staleManifest = try XCTUnwrap(tombstonedManifest, "find the stale manifest by its revision content")
        let tombstone = staleManifest.appendingPathExtension("tomb")
        try FileManager.default.moveItem(at: staleManifest, to: tombstone)

        // A fresh store recovers the interrupted operation. Every listed row
        // must either open or be unavailable, never half-freed.
        let realStore = try fixture.makeStore(appId: appId, projectId: projectId)
        let summariesAfterCrash = try await realStore.revisionSummaries()
        let usableAfterCrash = try fixture.availableRevisionIds(summariesAfterCrash.map(\.revisionId), packages: [first, stale, winner])
        XCTAssertTrue(usableAfterCrash.isSubset(of: Set(summariesAfterCrash.map(\.revisionId))))
        for revisionId in Set(summariesAfterCrash.map(\.revisionId)).subtracting(usableAfterCrash) {
            do {
                try await realStore.rollback(to: revisionId)
                XCTFail("listed unavailable revision must not be revertable: \(revisionId)")
            } catch { }
        }
        XCTAssertTrue(usableAfterCrash.contains(first.revisionId) && usableAfterCrash.contains(winner.revisionId))
        try await realStore.rollback(to: first.revisionId)
        let fallbackLaunch = try await realStore.launchDescriptorForActiveRevision()
        XCTAssertEqual(fallbackLaunch.revisionId, first.revisionId)
        try fixture.assertExactLaunch(fallbackLaunch.readAccessRootURL, matches: first)
        try await realStore.rollback(to: winner.revisionId)
        let activeLaunch = try await realStore.launchDescriptorForActiveRevision()
        XCTAssertEqual(activeLaunch.revisionId, winner.revisionId)
        try fixture.assertExactLaunch(activeLaunch.readAccessRootURL, matches: winner)

        _ = try await realStore.pruneStorage()
        // Mutation: deleting a tombstone but retaining its objects leaves
        // unreferenced content and fails this independently derived inventory.
        let afterPrune = FileManager.default.enumerator(at: manifestsRoot, includingPropertiesForKeys: nil)!
        var leftoverTombstone = false
        while let url = afterPrune.nextObject() as? URL { if url.lastPathComponent.hasSuffix(".tomb") { leftoverTombstone = true } }
        XCTAssertFalse(leftoverTombstone, "no tombstone remains after recovery prune")
        let expectedHashes = Set((Array(first.files.values) + Array(winner.files.values)).map { bytes in
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        })
        let objectsRoot = fixture.storeRoot.appendingPathComponent("objects", isDirectory: true)
        let objectWalk = FileManager.default.enumerator(at: objectsRoot, includingPropertiesForKeys: nil)!
        var actualHashes: Set<String> = []
        while let url = objectWalk.nextObject() as? URL {
            guard !url.hasDirectoryPath, url.lastPathComponent.count == 64 else { continue }
            actualHashes.insert(url.lastPathComponent)
        }
        XCTAssertEqual(actualHashes, expectedHashes, "no unreferenced or missing content objects after recovery")
    }

    func testPinnedOldRevisionSurvivesManyLaterUpdatesAndRevertToPreviousKeepsWorkingAfterPruning() async throws {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let suite = "iris-retention-pin-history-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = NativeRevisionPruningCatalogFixture()
        let offers: @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { identity in
            await catalog.offers(for: identity)
        }
        let appId = "iris.storage-pin-app"
        let projectId = "\(appId).mobile"
        let coordinator = NativeShellLibraryCoordinator(
            rootURL: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: offers
        )
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(
            appId: appId, projectId: projectId, defaults: defaults, downloadableRevisionIds: offers
        )

        var revisionIds: [String] = []
        var packages: [PruningFixture.GeneratedPackage] = []
        var baseRevisionId: String?
        for month in 0..<8 {
            let generated = try fixture.stageSmallRevision(
                appId: appId, projectId: projectId, month: month,
                baseRevisionId: baseRevisionId, nonce: fixture.nonce("pin-\(month)")
            )
            await catalog.offer(generated.revisionId, appId: appId, projectId: projectId)
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            revisionIds.append(generated.revisionId)
            packages.append(generated)
            baseRevisionId = generated.revisionId
            if month == 1 {
                // Pin the second-ever revision before it would otherwise
                // age out, mid-way through many later updates.
                try await store.pin(revisionId: generated.revisionId)
            }
        }
        let pinnedRevisionId = revisionIds[1]

        let summaries = try await store.revisionSummaries()
        XCTAssertTrue(summaries.contains { $0.revisionId == pinnedRevisionId }, "the pinned revision must still be on disk after 6 later updates")
        // MUTATION: freeing a pin or fallback while pruning to K=2 loses the independently verified revision hash.
        // PRE-2026-10-01-DECISION: revisit with the keep-count setting
        // RESOLVED 2026-10-01: expectation now K-based
        XCTAssertEqual(Set(summaries.map(\.revisionId)), Set(revisionIds), "the history ledger keeps all eight distinct rows")
        // PRE-2026-10-01-DECISION: revisit with the keep-count setting
        // RESOLVED 2026-10-01: expectation now K-based
        XCTAssertEqual(summaries.count, 8, "freed downloadable history remains represented in the ledger")
        // PRE-2026-10-01-DECISION: revisit with the keep-count setting
        // RESOLVED 2026-10-01: expectation now K-based
        XCTAssertEqual(try fixture.availableRevisionIds(summaries.map(\.revisionId), packages: packages),
                       Set([pinnedRevisionId, revisionIds[6], revisionIds[7]]),
                       "current and fallback plus the pin remain openable at K=2")

        // Capture the real fallback ("previous") from the actual update
        // sequence before anything below moves the active pointer around
        // to check the pinned revision's own launch.
        let realCurrent = try await store.activeRevisionId()
        let realPrevious = try await coordinator.libraryEntry(identity: identity)?.fallbackRevisionId
        XCTAssertNotNil(realPrevious)

        XCTAssertEqual(realCurrent, revisionIds[7])
        XCTAssertEqual(realPrevious, revisionIds[6])
        let pending = try fixture.stageSmallRevision(
            appId: appId, projectId: projectId, month: 8,
            baseRevisionId: realCurrent, nonce: fixture.nonce("pin-pending")
        )
        await catalog.offer(pending.revisionId, appId: appId, projectId: projectId)
        _ = try await store.stage(packageBytes: pending.bytes, approvalAuthority: pending.authority)
        await coordinator.setGlobalCodeCapBytes(1, defaults: defaults)
        let capPlan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        let protected = Set([pinnedRevisionId, revisionIds[6], revisionIds[7], pending.revisionId])
        XCTAssertTrue(protected.isDisjoint(with: Set(capPlan.items.map(\.revisionId))))
        _ = try await coordinator.enforceGlobalCap(defaults: defaults)
        let afterCap = try await store.revisionSummaries()
        // Mutation: freeing the pin or the fallback above the cap loses a protected ID.
        let availableAfterCap = try fixture.availableRevisionIds(afterCap.map(\.revisionId),
                                                                packages: packages + [pending])
        XCTAssertEqual(availableAfterCap, protected)

        // Verify the fallback role before later rollback probes replace it.
        try await coordinator.revert(identity: identity, to: realPrevious!)
        let fallbackLaunch = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(fallbackLaunch.launchedRevisionId, realPrevious)
        try await coordinator.revert(identity: identity, to: realCurrent!)
        try await store.pin(revisionId: realPrevious!)

        // Summaries can include freed history. The independent object oracle
        // above verifies availability; rolling to
        // it and asking for its launch descriptor exercises the same path
        // an actual open would.
        try await store.rollback(to: pinnedRevisionId)
        let pinnedLaunch = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(pinnedLaunch.revisionId, pinnedRevisionId)
        try await store.rollback(to: realCurrent!)

        // The second pin keeps the original previous available while this
        // test changes the active/fallback roles to probe the older pin.
        try await coordinator.revert(identity: identity, to: realPrevious!)
        let revertedLaunch = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(revertedLaunch.launchedRevisionId, realPrevious)

        // Unpin makes this the oldest unprotected version. Establish cap
        // pressure explicitly instead of treating an automatic prune as a five-row limit.
        try await store.unpin(revisionId: pinnedRevisionId)
        let unpinnedPlan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        // Mutation: reclaiming a newer unprotected version first fails this independent history order.
        XCTAssertEqual(unpinnedPlan.items.first?.revisionId, pinnedRevisionId,
                       "the now-unprotected oldest version is freed first")
        _ = try await coordinator.enforceGlobalCap(defaults: defaults)
        try await store.pruneStorage()
        let summariesAfterUnpin = try await store.revisionSummaries()
        // Mutation: keeping unpinned objects fails availability and pin-refusal checks.
        let availableAfterUnpin = try fixture.availableRevisionIds(summariesAfterUnpin.map(\.revisionId),
                                                                  packages: packages + [pending])
        XCTAssertFalse(availableAfterUnpin.contains(pinnedRevisionId))
        await XCTAssertThrowsStorageError(
            try await store.pin(revisionId: pinnedRevisionId),
            equals: .revisionNotAvailableToPin(pinnedRevisionId)
        )
        let launchAfterUnpin = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launchAfterUnpin.launchedRevisionId, realPrevious)
    }

    func testPinLimitIsEnforcedAndPinningARevisionThatDoesNotExistFailsClosed() async throws {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let appId = "iris.storage-pin-limit-app"
        let projectId = "\(appId).mobile"
        let store = try fixture.makeStore(appId: appId, projectId: projectId)

        let first = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 0, baseRevisionId: nil, nonce: fixture.nonce("pinlimit-0"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let second = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 1, baseRevisionId: first.revisionId, nonce: fixture.nonce("pinlimit-1"))
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        let third = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 2, baseRevisionId: first.revisionId, nonce: fixture.nonce("pinlimit-2"))
        _ = try await store.stage(packageBytes: third.bytes, approvalAuthority: third.authority)

        try await store.pin(revisionId: first.revisionId)
        try await store.pin(revisionId: second.revisionId)
        await XCTAssertThrowsStorageError(
            try await store.pin(revisionId: third.revisionId),
            equals: .pinLimitReached(limit: NativeStorageRetentionPolicy.pinLimit)
        )

        let missingRevisionId = "rev-sha256:" + String(repeating: "0", count: 64)
        await XCTAssertThrowsStorageError(
            try await store.pin(revisionId: missingRevisionId),
            equals: .revisionNotAvailableToPin(missingRevisionId)
        )
        // Pinning again what is already pinned is a harmless no-op, not a
        // second slot consumed.
        try await store.pin(revisionId: first.revisionId)
        let pins = try await store.pinnedRevisionIds()
        XCTAssertEqual(Set(pins), [first.revisionId, second.revisionId])
    }

    func testLowStorageRefusesAnUpdateWithNoNewBytesWrittenAndTheCurrentVersionStillOpens() async throws {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let appId = "iris.storage-low-space-app"
        let projectId = "\(appId).mobile"

        // A fake, not a mock of the unit under test: this substitutes only
        // the OS-level "how much free space is there" fact, exactly the
        // kind of environment double the MiroFish pattern calls for, since
        // no CI machine can be reliably filled to under 500 MB free.
        let fakeLowSpace = FixedCapacityProvider(bytes: 200 * 1024 * 1024)
        let store = try fixture.makeStore(
            appId: appId, projectId: projectId,
            availableCapacityProvider: { url in try fakeLowSpace.provide(url) }
        )

        let first = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 0, baseRevisionId: nil, nonce: fixture.nonce("lowspace-0"))
        await XCTAssertThrowsStorageError(
            try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority),
            equals: .insufficientStorageForUpdate(availableBytes: 200 * 1024 * 1024, thresholdBytes: NativeStorageRetentionPolicy.defaultMinimumFreeBytesForStaging)
        )
        let revisionsDirectory = fixture.storeRoot.appendingPathComponent("content")
        XCTAssertFalse(FileManager.default.fileExists(atPath: revisionsDirectory.path), "a refused stage must not create any content directory")

        fakeLowSpace.bytes = 900 * 1024 * 1024
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let openBeforeLowSpace = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(openBeforeLowSpace.revisionId, first.revisionId)

        fakeLowSpace.bytes = 100 * 1024 * 1024
        let second = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 1, baseRevisionId: first.revisionId, nonce: fixture.nonce("lowspace-1"))
        await XCTAssertThrowsStorageError(
            try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority),
            equals: .insufficientStorageForUpdate(availableBytes: 100 * 1024 * 1024, thresholdBytes: NativeStorageRetentionPolicy.defaultMinimumFreeBytesForStaging)
        )
        // "The old version keeps opening": refusing the update must not
        // disturb the already-installed, already-open-able revision.
        let openAfterRefusal = try await store.launchDescriptorForActiveRevision()
        XCTAssertEqual(openAfterRefusal.revisionId, first.revisionId)
        let activeAfterRefusal = try await store.activeRevisionId()
        XCTAssertEqual(activeAfterRefusal, first.revisionId)
        let refusedRevisionDirectory = fixture.storeRoot
            .appendingPathComponent("content/\(appId)/\(projectId)/revisions/\(second.revisionId)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: refusedRevisionDirectory.path),
            "a refused update must not leave a partial revision directory behind"
        )
    }

    func testPruningNeverTouchesReaderOwnedUserDataAcrossManyPruneCycles() async throws {
        let fixture = try PruningFixture()
        defer { fixture.cleanup() }
        let appId = "iris.storage-userdata-app"
        let projectId = "\(appId).mobile"
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)

        let first = try fixture.stageSmallRevision(appId: appId, projectId: projectId, month: 0, baseRevisionId: nil, nonce: fixture.nonce("userdata-0"))
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await coordinator.activate(identity: identity, revisionId: first.revisionId)

        let userDataDirectory = try await store.readerDataDirectory(namespace: appId)
        let userDataFile = userDataDirectory.appendingPathComponent("diary.sqlite")
        let userDataBytes = Data((0..<4096).map { UInt8($0 % 256) })
        try userDataBytes.write(to: userDataFile)
        let hashBefore = sha256Hex(userDataBytes)

        var baseRevisionId = first.revisionId
        for month in 1...10 {
            let generated = try fixture.stageSmallRevision(
                appId: appId, projectId: projectId, month: month,
                baseRevisionId: baseRevisionId, nonce: fixture.nonce("userdata-\(month)")
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            baseRevisionId = generated.revisionId
            // Confirm on every single cycle, not only at the end, that
            // pruning (which just ran, deleting old revision directories)
            // left this file byte-for-byte untouched.
            let currentBytes = try Data(contentsOf: userDataFile)
            XCTAssertEqual(sha256Hex(currentBytes), hashBefore)
        }
        XCTAssertEqual(sha256Hex(try Data(contentsOf: userDataFile)), hashBefore)
        // And the directory itself, outside `content/.../revisions`, was
        // never renamed or removed by any of those prunes.
        XCTAssertTrue(FileManager.default.fileExists(atPath: userDataDirectory.path))
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private func XCTAssertThrowsStorageError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: NativeStorageError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error \(expected)", file: file, line: line)
    } catch let error as NativeStorageError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

/// A misbehaving fake at the OS boundary (a force-quit's worth of "the
/// process died between these two calls"), not a mock of the pruning logic
/// under test: it only ever intercepts the tombstone's final delete.
private final class InterruptedPruneFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        if url.lastPathComponent.hasPrefix(".trash-") {
            throw NSError(domain: "simulated-force-quit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "simulated-force-quit: process died before the tombstone delete",
            ])
        }
        try super.removeItem(at: url)
    }
}

/// A fake for a real OS fact (free disk space) that no test may safely
/// simulate by actually filling a shared machine's disk. Mutable so a
/// single store instance can be moved across the threshold mid-test; the
/// actor's own serialization is the only caller, sequentially, one `await`
/// at a time, so `@unchecked Sendable` reflects an actually-checked
/// invariant here, not an unexamined one.
private final class FixedCapacityProvider: @unchecked Sendable {
    var bytes: Int64
    init(bytes: Int64) { self.bytes = bytes }
    func provide(_ url: URL) throws -> Int64 { bytes }
}

/// Drives the real desktop CLI (`generate-desktop-package.mjs` for small,
/// inline content and the new sibling `generate-desktop-package-from-file.mjs`
/// for multi-megabyte content that would exceed macOS's 1 MiB ARG_MAX as an
/// argv string) to produce real, validator-accepted `.irisapp` packages.
private final class PruningFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-shell-pruning-tests-\(UUID().uuidString)", isDirectory: true)
        // Deliberately NOT created here: `store` must not exist yet, the
        // same as a brand-new install, so the low-storage guard's
        // ancestor-walk (see `NativeStorageBlockMeasurementTests`) is
        // exercised by every test in this file, not just its own test.
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func makeStore(
        appId: String,
        projectId: String,
        defaults: UserDefaults = .standard,
        downloadableRevisionIds: @escaping @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] },
        fileManager: FileManager = .default,
        availableCapacityProvider: (@Sendable (URL) throws -> Int64)? = nil
    ) throws -> NativeRevisionStore {
        if let availableCapacityProvider {
            return try NativeRevisionStore(
                rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0",
                fileManager: fileManager,
                availableCapacityProvider: availableCapacityProvider,
                defaults: defaults,
                downloadableRevisionIds: downloadableRevisionIds
            )
        }
        return try NativeRevisionStore(
            rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0",
            fileManager: fileManager, defaults: defaults, downloadableRevisionIds: downloadableRevisionIds
        )
    }

    func nonce(_ tag: String) -> String {
        SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct GeneratedPackage {
        let bytes: Data
        let authority: StaticApprovalAuthority
        let revisionId: String
        let createdAt: String
        let files: [String: Data]
    }

    struct StaticApprovalAuthority: DeliveryApprovalAuthority {
        let approval: TrustedDeliveryApproval
        func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
            approval.approvalId == approvalId ? approval : nil
        }
    }

    /// A small, genuinely-changing revision (a fresh index.html each
    /// "month"): representative of FreeHarmony/Nut-AI-scale updates in
    /// PLAN.md section 6, not a fixed string reused every call.
    func stageSmallRevision(
        appId: String, projectId: String, month: Int, baseRevisionId: String?, nonce: String,
        includeSharedAsset: Bool = false
    ) throws -> GeneratedPackage {
        let content = "<!doctype html><meta charset=utf-8><title>Storage scale</title>"
            + "<main data-app=\"\(appId)\" data-month=\"\(month)\">update \(month) for \(appId)</main>"
        return try runGenerator(
            scriptName: "generate-desktop-package.mjs",
            extraArguments: ["--content", content],
            appId: appId, projectId: projectId, baseRevisionId: baseRevisionId, nonce: nonce,
            includeSharedAsset: includeSharedAsset
        )
    }

    /// A Kneecap-like revision: one large (default 6 MB) file that changes
    /// completely on every call (PLAN.md section 6: "Kneecap's classic
    /// bundle is one 5.98 MB script that changes on every edit"), so this
    /// deliberately produces no clone-sharing opportunity with its base.
    func stageLargeSingleFileRevision(
        appId: String, projectId: String, seed: UInt64, approxBytes: Int, baseRevisionId: String?, nonce: String
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let contentFile = root.appendingPathComponent("large-content-\(packageIndex).html")
        var state = seed &+ 0x9E3779B97F4A7C15
        var bytes = [UInt8]()
        bytes.reserveCapacity(approxBytes)
        let prefix = Array("<!doctype html><meta charset=utf-8><title>Storage scale</title><main>".utf8)
        bytes.append(contentsOf: prefix)
        while bytes.count < approxBytes {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            // Printable 7-bit ASCII only ('0'...'~'): every byte is < 0x80,
            // so this is unambiguously valid UTF-8, unlike a wider byte
            // range that can land on a lone continuation/lead byte.
            bytes.append(UInt8(0x30 + (state >> 33) % 79))
        }
        bytes.append(contentsOf: Array("</main>".utf8))
        try Data(bytes).write(to: contentFile)
        return try runGenerator(
            scriptName: "generate-desktop-package-from-file.mjs",
            extraArguments: ["--content-file", contentFile.path],
            appId: appId, projectId: projectId, baseRevisionId: baseRevisionId, nonce: nonce
        )
    }

    private func runGenerator(
        scriptName: String,
        extraArguments: [String],
        appId: String,
        projectId: String,
        baseRevisionId: String?,
        nonce: String,
        includeSharedAsset: Bool = false
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var script = repositoryRoot().appendingPathComponent("mobile-shell/native/Tests/Fixtures/\(scriptName)")
        if includeSharedAsset {
            // The same real stage/approve/deliver generator, extended only in a
            // fixture-local copy to include one unchanged asset in the review.
            var generator = try String(contentsOf: script, encoding: .utf8)
            generator = generator.replacingOccurrences(
                of: "const cli = resolve(here, \"../../../desktop/cli.mjs\");",
                with: "const cli = \(String(data: try JSONSerialization.data(withJSONObject: repositoryRoot().appendingPathComponent("mobile-shell/desktop/cli.mjs").path, options: .fragmentsAllowed), encoding: .utf8)!);"
            )
            generator = generator.replacingOccurrences(
                of: "await writeFile(join(build, \"index.html\"), content, \"utf8\");",
                with: "await writeFile(join(build, \"index.html\"), content, \"utf8\");\nawait writeFile(join(build, \"shared.html\"), Buffer.alloc(256 * 1024, appId));"
            )
            generator = generator.replacingOccurrences(
                of: "files: [{ path: \"index.html\", mediaType: \"text/html\" }],",
                with: "files: [{ path: \"index.html\", mediaType: \"text/html\" }, { path: \"shared.html\", mediaType: \"text/html\" }],"
            )
            script = output.appendingPathComponent("scale-generator.mjs")
            try generator.write(to: script, atomically: true, encoding: .utf8)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--base", baseRevisionId ?? "null",
            "--nonce", nonce,
            "--namespace", appId,
            "--capabilities", "[]",
            "--app", appId,
            "--project", projectId,
        ] + extraArguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw FixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "unknown generator error")
        }
        let result = try jsonObject(outputData)
        let packagePath = try requiredString(result, "packagePath")
        let approvalPath = try requiredString(result, "trustedApprovalPath")
        let revisionId = try requiredString(result, "revisionId")
        let approval = try parseTrustedApproval(Data(contentsOf: URL(fileURLWithPath: approvalPath)))
        let bytes = try Data(contentsOf: URL(fileURLWithPath: packagePath))
        let package = try jsonObject(bytes)
        let envelope = try XCTUnwrap(package["envelope"] as? [String: Any])
        let revision = try XCTUnwrap(envelope["revision"] as? [String: Any])
        var files: [String: Data] = [:]
        let build = output.appendingPathComponent("build")
        for path in ["index.html", "shared.html"] where FileManager.default.fileExists(atPath: build.appendingPathComponent(path).path) {
            files[path] = try Data(contentsOf: build.appendingPathComponent(path))
        }
        return GeneratedPackage(bytes: bytes, authority: StaticApprovalAuthority(approval: approval),
                                revisionId: revisionId, createdAt: try requiredString(revision, "createdAt"), files: files)
    }

    // SPEC 2.1 gives these object paths; SPEC 2.7 says summaries read metadata.
    // Mutation: missing protected objects lose their IDs; pruning to five loses roomy IDs.
    func availableRevisionIds(_ ids: [String], packages: [GeneratedPackage],
                              file: StaticString = #filePath, line: UInt = #line) throws -> Set<String> {
        let generated = Dictionary(uniqueKeysWithValues: packages.map { ($0.revisionId, $0) })
        var available: Set<String> = []
        for id in ids {
            guard let package = generated[id] else {
                XCTFail("summary outside the generated timeline: \(id)", file: file, line: line)
                continue
            }
            XCTAssertFalse(package.files.isEmpty, "fixture must enumerate its content", file: file, line: line)
            var allPresent = !package.files.isEmpty
            for expected in package.files.values {
                let hash = nonceForBytes(expected)
                let object = storeRoot.appendingPathComponent("objects/\(hash.prefix(2))/\(hash)")
                guard FileManager.default.fileExists(atPath: object.path) else {
                    allPresent = false
                    break
                }
                XCTAssertEqual(nonceForBytes(try Data(contentsOf: object)), hash,
                               "independent generated object hash", file: file, line: line)
            }
            if allPresent { available.insert(id) }
        }
        return available
    }

    func distinctContentAllocatedBound(_ packages: [GeneratedPackage]) -> Int64 {
        var sizes: [String: Int64] = [:]
        for package in packages {
            for bytes in package.files.values {
                sizes[nonceForBytes(bytes)] = Int64((bytes.count + 4095) / 4096 * 4096)
            }
        }
        return sizes.values.reduce(0, +)
    }

    func assertExactLaunch(_ directory: URL, matches package: GeneratedPackage,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let paths = try XCTUnwrap(FileManager.default.enumerator(atPath: directory.path), file: file, line: line)
        var actual: [String: Data] = [:]
        for case let path as String in paths {
            let url = directory.appendingPathComponent(path)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                actual[path] = try Data(contentsOf: url)
            }
        }
        XCTAssertEqual(Set(actual.keys), Set(package.files.keys), "exact generated paths", file: file, line: line)
        for (path, expected) in package.files {
            XCTAssertEqual(actual[path].map(nonceForBytes), nonceForBytes(expected),
                           "independent generated hash at \(path)", file: file, line: line)
        }
    }

    // Read raw st_blocks independently, never the store's allocation result.
    // The measured cap step deletes a unique large file, so shared files that
    // remain on disk cancel from before/after even in legacy clone trees.
    func codeAllocatedBytesOnDisk() throws -> Int64 {
        var total: Int64 = 0
        var seenInodes: Set<String> = []
        for name in ["content", "objects", "manifests"] {
            let directory = storeRoot.appendingPathComponent(name)
            guard let paths = FileManager.default.enumerator(atPath: directory.path) else { continue }
            for case let path as String in paths {
                let url = directory.appendingPathComponent(path)
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                let inodeKey = "\(info.st_dev):\(info.st_ino)"
                guard seenInodes.insert(inodeKey).inserted else { continue }
                total += Int64(info.st_blocks) * 512
            }
        }
        return total
    }

    private func nonceForBytes(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum FixtureError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
}

private actor NativeRevisionPruningCatalogFixture {
    private var offeredRevisionIdsByIdentity: [String: Set<String>] = [:]

    func offer(_ revisionId: String, appId: String, projectId: String) {
        offeredRevisionIdsByIdentity[key(appId: appId, projectId: projectId), default: []].insert(revisionId)
    }

    func offers(for identity: NativeShellAppIdentity) -> Set<String> {
        offeredRevisionIdsByIdentity[key(appId: identity.appId, projectId: identity.projectId), default: []]
    }

    private func key(appId: String, projectId: String) -> String {
        "\(appId)::\(projectId)"
    }
}

private func parseTrustedApproval(_ data: Data) throws -> TrustedDeliveryApproval {
    let value = try jsonObject(data)
    func nullable(_ key: String) throws -> String? {
        if value[key] is NSNull { return nil }
        return try requiredString(value, key)
    }
    return TrustedDeliveryApproval(
        approvalId: try requiredString(value, "approvalId"),
        requestId: try nullable("requestId"),
        requestNonce: try nullable("requestNonce"),
        appId: try requiredString(value, "appId"),
        projectId: try requiredString(value, "projectId"),
        baseRevisionId: try nullable("baseRevisionId"),
        approvedRevisionId: try requiredString(value, "approvedRevisionId"),
        approvedContentHash: try requiredString(value, "approvedContentHash"),
        approvedAt: try requiredString(value, "approvedAt")
    )
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw FixtureError.malformedFixture("expected JSON object")
    }
    return object
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else { throw FixtureError.malformedFixture("missing \(key)") }
    return value
}
