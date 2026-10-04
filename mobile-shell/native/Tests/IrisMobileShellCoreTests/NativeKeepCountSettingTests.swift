import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeKeepCountSettingTests: XCTestCase {
    private var worlds: [KCAWorld] = []

    override func tearDown() {
        worlds.forEach { $0.cleanup() }
        worlds.removeAll()
        super.tearDown()
    }

    func testOneSavedCountAppliesToBothAppsAndKeepsTheirExpectedHashes() async throws {
        // SPEC 5.1 checks 3 and the one-global-setting acceptance mapping.
        // MUTATION: a per-app preference or a setter that saves without pruning leaves old hashes in one app.
        let world = try KCAWorld(); worlds.append(world)
        _ = try await world.coordinator().setVersionKeepCount(.keepAll, defaults: world.defaults)
        let a = try await world.stageTimeline(app: "keep-a", count: 4)
        let b = try await world.stageTimeline(app: "keep-b", count: 4)
        let coordinator = world.coordinator()
        let result = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let saved = await coordinator.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(saved, .keepTwo)
        for (identity, timeline) in [(a.identity, a), (b.identity, b)] {
            let store = try world.store(identity)
            let summaries = try await store.revisionSummaries()
            XCTAssertEqual(Set(summaries.map(\.revisionId)), Set(timeline.ids), "freed revisions remain in history")
            var present = Set<String>()
            for revisionId in timeline.ids {
                if try await store.revisionIsOnThisPhone(revisionId: revisionId) { present.insert(revisionId) }
            }
            XCTAssertEqual(present, Set(timeline.ids.suffix(2)))
            XCTAssertEqual(result.retainedRevisionIds[identity], Set(timeline.ids.suffix(2)))
            for item in timeline.packages.suffix(2) { try await world.assertUsableFixtureRevision(item, identity: identity) }
        }
    }

    func testSavedCountSurvivesReconstructingActorsOverTheSameSuiteAndRoot() async throws {
        // SPEC 5.1 check 4. Actor reconstruction is the Core half of relaunch.
        // MUTATION: a process-only value or standard-defaults lookup loses the selected value.
        let world = try KCAWorld(); worlds.append(world)
        let first = world.coordinator()
        _ = try await first.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let relaunched = world.coordinator()
        let implicitRead = await relaunched.versionKeepCount()
        let suiteRead = await relaunched.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(implicitRead, .keepFive)
        XCTAssertEqual(suiteRead, .keepFive)
    }

    func testResetPlansAndImmediatelyAppliesTwoBeforeAnyLaterUpdate() async throws {
        // SPEC 5.1 check 5. Core reset uses setVersionKeepCount(.keepTwo), with its confirmation plan.
        // MUTATION: reset only changes selection, defers pruning, or fails to persist through reconstruction.
        let world = try KCAWorld(); worlds.append(world)
        _ = try await world.coordinator().setVersionKeepCount(.keepAll, defaults: world.defaults)
        let timeline = try await world.stageTimeline(app: "reset-immediate", count: 8)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let beforeHashes = try world.hashes(at: world.storeRoot)
        let beforeBlocks = try world.allocatedBlocks(at: world.storeRoot)
        let plan = try await coordinator.planVersionKeepCount(.keepTwo, defaults: world.defaults)
        XCTAssertEqual(plan.choice, .keepTwo)
        XCTAssertFalse(plan.items.isEmpty)
        let plannedChoice = await coordinator.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(plannedChoice, .keepFive)
        XCTAssertEqual(try world.hashes(at: world.storeRoot), beforeHashes)
        XCTAssertEqual(try world.allocatedBlocks(at: world.storeRoot), beforeBlocks)

        let result = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let expected = Set(timeline.ids.suffix(2))
        XCTAssertEqual(result.choice, .keepTwo)
        XCTAssertEqual(result.retainedRevisionIds[timeline.identity], expected)
        XCTAssertEqual(result.freedRevisionIds[timeline.identity], Set(timeline.ids.suffix(5).dropLast(2)))
        let resetStore = try world.store(timeline.identity)
        let resetSummaries = try await resetStore.revisionSummaries()
        XCTAssertEqual(Set(resetSummaries.map(\.revisionId)), Set(timeline.ids), "freed revisions remain in history")
        var resetUsable = Set<String>()
        for revisionId in timeline.ids {
            if try await resetStore.revisionIsOnThisPhone(revisionId: revisionId) { resetUsable.insert(revisionId) }
        }
        XCTAssertEqual(resetUsable, expected)
        XCTAssertLessThan(try world.allocatedBlocks(at: world.storeRoot), beforeBlocks)
        let afterReset = world.coordinator()
        let implicitResetChoice = await afterReset.versionKeepCount()
        let explicitResetChoice = await afterReset.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(implicitResetChoice, .keepTwo)
        XCTAssertEqual(explicitResetChoice.count, 2)
        XCTAssertEqual(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey), "2")
    }

    func testInvalidSavedRawValueReadsAsTwoWithoutRewritingPreferences() async throws {
        // SPEC 1.6 and public API choice persistence rule.
        // MUTATION: invalid data leaks through, or a read silently normalizes and rewrites the user's suite.
        let world = try KCAWorld(); worlds.append(world)
        world.defaults.set("1", forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
        let value = await world.coordinator().versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(value, .keepTwo)
        XCTAssertEqual(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey), "1")
    }

    func testLoweringPlanIsPureAndItsBytesMatchTheIndependentLastReferenceDrop() async throws {
        // SPEC 5.1 check 12. Several packages share a file, so only removing its last reference frees its blocks.
        // MUTATION: logical-size or per-revision summation accounting overstates bytes, or planning mutates storage.
        let world = try KCAWorld(); worlds.append(world)
        _ = try await world.coordinator().setVersionKeepCount(.keepAll, defaults: world.defaults)
        let timeline = try await world.stageTimeline(app: "plan-shared", count: 5, sharedPrefix: 2)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let beforeHashes = try world.hashes(at: world.storeRoot)
        let beforeBlocks = try world.allocatedBlocks(at: world.storeRoot)
        let plan = try await coordinator.planVersionKeepCount(.keepTwo, defaults: world.defaults)
        let savedChoice = await coordinator.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(savedChoice, .keepFive)
        XCTAssertEqual(try world.hashes(at: world.storeRoot), beforeHashes)
        XCTAssertEqual(try world.allocatedBlocks(at: world.storeRoot), beforeBlocks)
        let result = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let afterBlocks = try world.allocatedBlocks(at: world.storeRoot)
        XCTAssertEqual(plan.bytesReclaimed, beforeBlocks - afterBlocks)
        XCTAssertEqual(result.bytesReclaimed, beforeBlocks - afterBlocks)
        let summaries = try await world.store(timeline.identity).revisionSummaries()
        XCTAssertEqual(Set(summaries.map(\.revisionId)), Set(timeline.ids), "freed revisions remain in history")
        let store = try world.store(timeline.identity)
        var usable = Set<String>()
        for revisionId in timeline.ids {
            if try await store.revisionIsOnThisPhone(revisionId: revisionId) { usable.insert(revisionId) }
        }
        XCTAssertEqual(usable, Set(timeline.ids.suffix(2)))
    }

    func testNeverAppliedPlanLeavesSavedChoiceHashesAndAllocatedBlocksUnchanged() async throws {
        // SPEC 5.1 check 13. The simulated person previews the confirmation then chooses Not now.
        // MUTATION: planning saves the candidate or deletes a candidate revision before confirmation.
        let world = try KCAWorld(); worlds.append(world)
        let timeline = try await world.stageTimeline(app: "plan-cancel", count: 5)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let hashes = try world.hashes(at: world.storeRoot)
        let blocks = try world.allocatedBlocks(at: world.storeRoot)
        let plan = try await coordinator.planVersionKeepCount(.keepTwo, defaults: world.defaults)
        XCTAssertGreaterThan(plan.bytesReclaimed, 0)
        let savedChoice = await coordinator.versionKeepCount(defaults: world.defaults)
        XCTAssertEqual(savedChoice, .keepFive)
        XCTAssertEqual(try world.hashes(at: world.storeRoot), hashes)
        XCTAssertEqual(try world.allocatedBlocks(at: world.storeRoot), blocks)
        let summaries = try await world.store(timeline.identity).revisionSummaries()
        XCTAssertEqual(summaries.count, 5)
    }

    func testLoweringCountPrunesImmediatelyWithoutWaitingForAnotherUpdate() async throws {
        // SPEC 5.1 check 14. Eight distinct revisions are staged while Keep all is selected.
        // MUTATION: pruning is deferred until a later stage or activation.
        let world = try KCAWorld(); worlds.append(world)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: world.defaults)
        let timeline = try await world.stageTimeline(app: "lower-now", count: 8)
        let result = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        XCTAssertEqual(result.retainedRevisionIds[timeline.identity], Set(timeline.ids.suffix(2)))
        let summaries = try await world.store(timeline.identity).revisionSummaries()
        XCTAssertEqual(Set(summaries.map(\.revisionId)), Set(timeline.ids), "freed revisions remain in history")
        for package in timeline.packages.suffix(2) { try await world.assertUsableFixtureRevision(package, identity: timeline.identity) }
        for package in timeline.packages.dropLast(2) {
            let present = try await world.store(timeline.identity).revisionIsOnThisPhone(revisionId: package.revisionId)
            XCTAssertFalse(present)
        }
    }

    func testRaisingCountDoesNotRestoreFreedFilesAndHistoryOffersDownloadOnlyWhenCatalogDoes() async throws {
        // SPEC 5.1 check 15. The catalog closure is the independently controlled current offer set.
        // MUTATION: raising resurrects bytes or every absent ledger row gets a fabricated Download action.
        let world = try KCAWorld(); worlds.append(world)
        let timeline = try await world.stageTimeline(app: "raise-no-restore", count: 5)
        await world.catalog.set(Set(timeline.ids), for: timeline.identity)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let freed = timeline.ids[0]
        _ = try await coordinator.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let stillPresentAfterRaise = try await world.store(timeline.identity).revisionIsOnThisPhone(revisionId: freed)
        XCTAssertFalse(stillPresentAfterRaise)
        let offeredRows = try await coordinator.featureHistory(identity: timeline.identity)
        let offered = try XCTUnwrap(offeredRows.first { $0.id == freed })
        XCTAssertFalse(offered.isOnThisPhone)
        XCTAssertEqual(offered.storageStateLabel, "Not on this iPhone")
        XCTAssertTrue(offered.canDownload)
        await world.catalog.set(Set(timeline.ids.dropFirst()), for: timeline.identity)
        let withdrawnRows = try await coordinator.featureHistory(identity: timeline.identity)
        let withdrawn = try XCTUnwrap(withdrawnRows.first { $0.id == freed })
        XCTAssertEqual(withdrawn.storageStateLabel, "No longer available")
        XCTAssertFalse(withdrawn.canDownload)
        let stillPresentAfterWithdrawal = try await world.store(timeline.identity).revisionIsOnThisPhone(revisionId: freed)
        XCTAssertFalse(stillPresentAfterWithdrawal)
    }

    func testKeepFiveStillHonorsSmallGlobalCodeCapAndPreservesCurrentAndFallback() async throws {
        // SPEC 5.1 check 16. A deliberately small cap must take precedence over the five-version count.
        // MUTATION: count policy bypasses the cap, or cap enforcement frees a role revision.
        let world = try KCAWorld(); worlds.append(world)
        let timeline = try await world.stageTimeline(app: "cap-count", count: 5)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepFive, defaults: world.defaults)
        let store = try world.store(timeline.identity)
        let allBytes = try world.allocatedBlocks(at: world.storeRoot)
        await coordinator.setGlobalCodeCapBytes(allBytes / 2, defaults: world.defaults)
        _ = try await coordinator.enforceGlobalCap(defaults: world.defaults)
        let actual = try world.allocatedBlocks(at: world.storeRoot)
        XCTAssertLessThanOrEqual(actual, allBytes / 2 + 4096)
        let currentId = try await store.activeRevisionId()
        let fallbackId = try await store.fallbackRevisionId()
        XCTAssertEqual(currentId, timeline.ids.last)
        XCTAssertEqual(fallbackId, timeline.ids[timeline.ids.count - 2])
        for package in timeline.packages.suffix(2) { try await world.assertUsableFixtureRevision(package, identity: timeline.identity) }
    }

    func testGoBackThenPublicFacadeUndoRestoreExpectedVersionsAfterCountPrune() async throws {
        // SPEC 5.1 check 17. Independent package hashes and reader-data sentinel identify both expected states.
        // MUTATION: fallback is pruned, facade Undo is replaced by a second Go back, or user data is changed.
        let world = try KCAWorld(); worlds.append(world)
        let timeline = try await world.stageTimeline(app: "undo-fallback", count: 5)
        let coordinator = world.coordinator()
        _ = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults)
        let store = try world.store(timeline.identity)
        let current = try XCTUnwrap(timeline.packages.last)
        let fallback = timeline.packages[timeline.packages.count - 2]
        try await world.assertUsableFixtureRevision(fallback, identity: timeline.identity)
        let expectedCurrentEntry = current.content
        let expectedFallbackEntry = fallback.content
        let dataDir = try await store.readerDataDirectory(namespace: timeline.identity.appId)
        let sentinel = dataDir.appendingPathComponent("person-data.txt")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("leave my data alone".utf8).write(to: sentinel)
        try await coordinator.revert(identity: timeline.identity, to: fallback.revisionId)
        let backEntry = try await coordinator.libraryEntry(identity: timeline.identity)
        let afterBack = try XCTUnwrap(backEntry)
        XCTAssertEqual(afterBack.currentRevisionId, fallback.revisionId)
        XCTAssertEqual(afterBack.fallbackRevisionId, current.revisionId)
        let backLaunch = try await coordinator.launchActive(identity: timeline.identity)
        XCTAssertEqual(backLaunch.launchedRevisionId, fallback.revisionId)
        XCTAssertTrue(try String(contentsOf: backLaunch.launch.entrypointURL, encoding: .utf8).contains(expectedFallbackEntry))
        try await world.assertUsableFixtureRevision(fallback, identity: timeline.identity)

        let facade = try NativeVersionStore(root: world.storeRoot)
        let didUndo = try await facade.undo(appId: timeline.identity.appId, projectId: timeline.identity.projectId, fault: NativeVersionFaultInjector())
        XCTAssertTrue(didUndo)
        _ = try await coordinator.pruneStorage(identity: timeline.identity)
        let undoEntry = try await coordinator.libraryEntry(identity: timeline.identity)
        let afterUndo = try XCTUnwrap(undoEntry)
        XCTAssertEqual(afterUndo.currentRevisionId, current.revisionId)
        XCTAssertEqual(afterUndo.fallbackRevisionId, fallback.revisionId)
        let undoLaunch = try await coordinator.launchActive(identity: timeline.identity)
        XCTAssertEqual(undoLaunch.launchedRevisionId, current.revisionId)
        XCTAssertTrue(try String(contentsOf: undoLaunch.launch.entrypointURL, encoding: .utf8).contains(expectedCurrentEntry))
        try await world.assertUsableFixtureRevision(current, identity: timeline.identity)
        try await world.assertUsableFixtureRevision(fallback, identity: timeline.identity)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("leave my data alone".utf8))
    }

    func testFailedCatalogReadCannotAuthorizeFreeingAnyVersion() async throws {
        // SPEC 8.3 and public API catalog-failure rule.
        // MUTATION: a thrown catalog lookup is treated as an empty offer set and eligible history is deleted.
        let world = try KCAWorld(); worlds.append(world)
        let timeline = try await world.stageTimeline(app: "catalog-failure", count: 4)
        _ = try await world.coordinator().setVersionKeepCount(.keepAll, defaults: world.defaults)
        let coordinator = world.coordinator(catalogFails: true)
        let before = try world.hashes(at: world.storeRoot)
        do { _ = try await coordinator.setVersionKeepCount(.keepTwo, defaults: world.defaults); XCTFail("catalog failure must propagate") }
        catch { XCTAssertEqual(try world.hashes(at: world.storeRoot), before) }
        let savedChoice = await coordinator.versionKeepCount(defaults: world.defaults)
        let summaries = try await world.store(timeline.identity).revisionSummaries()
        XCTAssertEqual(savedChoice, .keepAll)
        XCTAssertEqual(summaries.count, 4)
    }

    func testEveryPublicCrashPointPreservesHashesUntilSettlementThenAllowsOneKeepTwoPrune() async throws {
        // SPEC 5.1 check 18. Each interruption uses a fresh store; KCAWorld hashes and lstat block walks observe disk before recovery.
        // MUTATION: collection runs through an unsettled journal, or recovery loses protected/current bytes before ordinary pruning.
        let stagePoints: [NativeVersionCrashPoint] = [
            .objectWrite_afterTempWrite, .objectWrite_afterFsync, .objectWrite_afterRename,
            .manifestWrite_afterTempWrite, .manifestWrite_afterRename, .manifestWrite_afterRefsCommit,
        ]
        for point in stagePoints {
            let world = try KCAWorld(); worlds.append(world)
            let safePoint = point.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
            let identity = NativeShellAppIdentity(appId: "crash-\(safePoint)", projectId: "crash-\(safePoint).mobile")
            let facade = try NativeVersionStore(root: world.storeRoot)
            let coordinator = world.coordinator()
            var priorIds: [String] = []
            var baseRevisionId: String?
            for index in 0..<4 {
                let prior = try await world.stageCrashWebRevision(on: coordinator, identity: identity,
                                                            seed: UInt64(880 + index), baseRevisionId: baseRevisionId,
                                                            createdAtOffset: TimeInterval(index - 10))
                try await coordinator.activate(identity: identity, revisionId: prior)
                priorIds.append(prior)
                baseRevisionId = prior
            }
            await world.catalog.set(Set(priorIds), for: identity)
            let before = try world.hashes(at: world.storeRoot)
            let beforeBlocks = try world.allocatedBlocks(at: world.storeRoot)
            do {
                let faultedCoordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: point))
                _ = try await world.stageCrashWebRevision(on: faultedCoordinator, identity: identity,
                                                           seed: UInt64(stagePoints.firstIndex(of: point) ?? 0),
                                                           baseRevisionId: baseRevisionId, createdAtOffset: 0)
                XCTFail("[\(point)] expected the stage write to throw")
            } catch let crash as NativeVersionSimulatedCrash {
                XCTAssertEqual(crash.point, point, "[\(point)] thrown point must match the requested interruption")
            }
            XCTAssertTrue(try world.hashes(at: world.storeRoot).filter { before[$0.key] != nil }.allSatisfy { before[$0.key] == $0.value }, "[\(point)] prior files remain intact")
            XCTAssertGreaterThanOrEqual(try world.allocatedBlocks(at: world.storeRoot), beforeBlocks, "[\(point)] stage failure cannot count-prune earlier usable data")
            let cleanRecovery = try await facade.recoverIfNeeded(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector())
            XCTAssertEqual(cleanRecovery, .clean, "[\(point)] stage interruption leaves no unsettled swap")
            _ = try await facade.recoverIfNeeded(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector())
            _ = try await coordinator.refreshLibrary()
            let beforePrune = try world.allocatedBlocks(at: world.storeRoot)
            let result = try await coordinator.setVersionKeepCount(.keepTwo)
            let afterPrune = try world.allocatedBlocks(at: world.storeRoot)
            XCTAssertEqual(result.bytesReclaimed, beforePrune - afterPrune, "[\(point)] post-recovery prune equals independent allocation drop")
            XCTAssertEqual(result.retainedRevisionIds[identity]?.intersection(Set(priorIds.suffix(2))), Set(priorIds.suffix(2)), "[\(point)] current and fallback prior revisions remain usable")
        }

        let swapPoints: [NativeVersionCrashPoint] = [
            .journalWrite_afterJournalWritten, .journalWrite_afterCheckoutBuilt,
            .journalWrite_afterPointerWrite, .journalWrite_beforeJournalDelete,
        ]
        enum KCASwap: Equatable { case activate, rollback, undo }
        for point in swapPoints {
            for operation in [KCASwap.activate, .rollback, .undo] {
                let world = try KCAWorld(); worlds.append(world)
                let safePoint = point.rawValue.lowercased().replacingOccurrences(of: "_", with: "-")
                let operationName: String
                switch operation {
                case .activate: operationName = "activate"
                case .rollback: operationName = "rollback"
                case .undo: operationName = "undo"
                }
                let identity = NativeShellAppIdentity(appId: "swap-\(safePoint)-\(operationName)", projectId: "swap-\(safePoint)-\(operationName).mobile")
                let facade = try NativeVersionStore(root: world.storeRoot)
                let coordinator = world.coordinator()
                let first = try await world.stageCrashWebRevision(on: coordinator, identity: identity, seed: 1201, baseRevisionId: nil, createdAtOffset: -30)
                try await coordinator.activate(identity: identity, revisionId: first)
                let second = try await world.stageCrashWebRevision(on: coordinator, identity: identity, seed: 1202, baseRevisionId: first, createdAtOffset: -20)
                try await coordinator.activate(identity: identity, revisionId: second)
                let third = try await world.stageCrashWebRevision(on: coordinator, identity: identity, seed: 1203, baseRevisionId: second, createdAtOffset: -10)
                try await coordinator.activate(identity: identity, revisionId: third)
                let fourth = try await world.stageCrashWebRevision(on: coordinator, identity: identity, seed: 1204, baseRevisionId: third, createdAtOffset: 0)
                await world.catalog.set([first, second, third, fourth], for: identity)
                if operation == .undo {
                    _ = try await facade.rollback(appId: identity.appId, projectId: identity.projectId, revisionId: second)
                }
                if operation == .undo && point == .journalWrite_afterCheckoutBuilt {
                    // Inapplicable: the undo target checkout is always retained (SPEC 2.3 step 2); this point is reached only by a build.
                    let undoSucceeded = try await facade.undo(appId: identity.appId, projectId: identity.projectId)
                    XCTAssertTrue(undoSucceeded, "[\(point), undo] un-faulted undo succeeds")
                    continue
                }
                let beforeSnapshot = try world.immutableSnapshot()
                let beforeBlocks = try world.allocatedBlocks(at: world.storeRoot)
                do {
                    switch operation {
                    case .activate:
                        _ = try await facade.activate(appId: identity.appId, projectId: identity.projectId, revisionId: fourth, fault: NativeVersionFaultInjector(point: point))
                    case .rollback:
                        let rollbackTarget = point == .journalWrite_afterCheckoutBuilt ? first : second
                        _ = try await facade.rollback(appId: identity.appId, projectId: identity.projectId, revisionId: rollbackTarget, fault: NativeVersionFaultInjector(point: point))
                    case .undo:
                        _ = try await facade.undo(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector(point: point))
                    }
                    XCTFail("[\(point), \(operation)] expected injected swap failure")
                } catch let crash as NativeVersionSimulatedCrash {
                    XCTAssertEqual(crash.point, point, "[\(point), \(operation)] crash point")
                }
                let interruptedHashes = try world.hashes(at: world.storeRoot)
                let interruptedBlocks = try world.allocatedBlocks(at: world.storeRoot)
                let interruptedSnapshot = try world.immutableSnapshot()
                world.assertNoPruneOrRewrite(beforeSnapshot, interruptedSnapshot, "[\(point), \(operation)] interruption cannot rewrite or remove existing object or manifest content")
                XCTAssertGreaterThanOrEqual(interruptedBlocks, beforeBlocks, "[\(point), \(operation)] no count prune before settlement")
                if point == .journalWrite_beforeJournalDelete {
                    for barrierPoint in NativeVersionCrashPoint.allCases where barrierPoint != .none {
                        let barrierCoordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: barrierPoint))
                        do {
                            _ = try await barrierCoordinator.planVersionKeepCount(.keepTwo)
                            XCTFail("[\(point), \(operation), barrier \(barrierPoint)] planning must refuse an unsettled journal")
                        } catch let error as NativeStorageError {
                            if case .recoveryRequired = error {} else { XCTFail("[\(point), \(operation), barrier \(barrierPoint)] got \(error)") }
                        }
                        let afterPlan = try world.hashes(at: world.storeRoot)
                        let comparedPaths = afterPlan.filter { entry in
                            let components = URL(fileURLWithPath: entry.key).pathComponents
                            return components.contains("state") || components.contains("manifests") || components.contains("objects") || components.contains("checkouts")
                        }
                        let interruptedPaths = interruptedHashes.filter { entry in
                            let components = URL(fileURLWithPath: entry.key).pathComponents
                            return components.contains("state") || components.contains("manifests") || components.contains("objects") || components.contains("checkouts")
                        }
                        XCTAssertEqual(comparedPaths, interruptedPaths, "[\(point), \(operation), barrier \(barrierPoint)] read-only refusal did not repair, recover or prune")
                    }
                    let coordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: point))
                    do {
                        _ = try await coordinator.pruneStorage(identity: identity)
                        XCTFail("[\(point), \(operation)] explicit prune must fail while recovery remains unsettled")
                    } catch {
                        XCTAssertTrue(error is NativeStorageError || error is NativeVersionSimulatedCrash, "[\(point), \(operation)] prune reports its recovery failure")
                    }
                    XCTAssertNil(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey), "[\(point), \(operation)] refusal does not save a choice")
                    let afterPruneAttempt = try world.immutableSnapshot()
                    world.assertNoPruneOrRewrite(interruptedSnapshot, afterPruneAttempt, "[\(point), \(operation)] refused prune preserves objects and manifests")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: world.storeRoot.appendingPathComponent("state/\(identity.appId)/\(identity.projectId)/journal.json").path), "[\(point), \(operation)] refused prune leaves journal present")
                    let applyCoordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: point))
                    do {
                        _ = try await applyCoordinator.setVersionKeepCount(.keepTwo)
                        XCTFail("[\(point), \(operation)] setting cannot report success before recovery settles")
                    } catch {
                        XCTAssertTrue(error is NativeStorageError || error is NativeVersionSimulatedCrash, "[\(point), \(operation)] setting propagates recovery failure")
                    }
                    XCTAssertNil(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey), "[\(point), \(operation)] failed setting does not persist K")
                }
                _ = try await facade.recoverIfNeeded(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector())
                let settledAgain = try await facade.recoverIfNeeded(appId: identity.appId, projectId: identity.projectId, fault: NativeVersionFaultInjector())
                XCTAssertEqual(settledAgain, .clean, "[\(point), \(operation)] repeated recovery is clean")
                let activePointer = await facade.state.readActive(appId: identity.appId, projectId: identity.projectId)
                let active = activePointer?.currentRevisionId
                XCTAssertTrue([first, second, third, fourth].contains(active ?? ""), "[\(point), \(operation)] recovery leaves a known fixture revision active")
                _ = try await coordinator.refreshLibrary()
                let beforePruneBlocks = try world.allocatedBlocks(at: world.storeRoot)
                let pruneResult = try await coordinator.setVersionKeepCount(.keepTwo)
                let afterPruneBlocks = try world.allocatedBlocks(at: world.storeRoot)
                XCTAssertEqual(pruneResult.bytesReclaimed, beforePruneBlocks - afterPruneBlocks, "[\(point), \(operation)] ordinary post-recovery prune reports independent allocated reduction")
                XCTAssertTrue(pruneResult.freedRevisionIds[identity]?.isEmpty == false, "[\(point), \(operation)] one eligible excess revision is freed after settlement")
            }
        }
    }

    func testUnsettledMigrationRefusesExplicitPruneAndKeepCountApply() async throws {
        // SPEC 2.5 and 5.1 check 18: neither public collection action may pass an unsettled migration journal.
        // MUTATION: deleting the settled-storage guard permits prune or saved preference mutation during migration.
        let world = try KCAWorld(); worlds.append(world)
        let identity = NativeShellAppIdentity(appId: "migration-guard-fixture", projectId: "migration-guard-fixture.mobile")
        let legacy = world.root.appendingPathComponent("legacy", isDirectory: true)
        let v7 = "rev-sha256:" + String(repeating: "7", count: 64)
        let v8 = "rev-sha256:" + String(repeating: "8", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v7, base: nil, seed: 1707, createdAt: "2026-09-29T00:00:00Z"),
            VersionsLegacyFixture.revision(id: v8, base: v7, seed: 1708, createdAt: "2026-09-30T00:00:00Z"),
        ], to: legacy)
        let facade = try NativeVersionStore(root: world.storeRoot)
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacy, v1Root: world.storeRoot)
        do {
            try await facade.migrateLegacy(appId: identity.appId, projectId: identity.projectId, legacyRevisionsRoot: legacy,
                                           currentRevisionId: v8, fallbackRevisionId: v7,
                                           fault: NativeVersionFaultInjector(point: .migration_midRename))
            XCTFail("[migration_midRename] expected injected migration interruption")
        } catch let crash as NativeVersionSimulatedCrash {
            XCTAssertEqual(crash.point, .migration_midRename, "[migration_midRename] reported point")
        }
        XCTAssertEqual(migration.readJournal(appId: identity.appId, projectId: identity.projectId)?.done, false,
                       "[migration_midRename] fixture leaves a not-done migration journal")
        let interrupted = try world.immutableSnapshot()
        let coordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: .migration_midRename))
        do {
            _ = try await coordinator.pruneStorage(identity: identity)
            XCTFail("[migration_midRename] explicit prune must refuse unsettled migration")
        } catch let error as NativeStorageError {
            if case .recoveryRequired = error {} else { XCTFail("[migration_midRename] explicit prune got \(error), expected recoveryRequired") }
        } catch {
            XCTFail("[migration_midRename] explicit prune got \(error), expected recoveryRequired")
        }
        world.assertNoPruneOrRewrite(interrupted, try world.immutableSnapshot(), "[migration_midRename] explicit prune refusal preserves objects and manifests")
        XCTAssertNil(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey),
                     "[migration_midRename] explicit prune refusal does not save a choice")
        let afterPrune = try world.immutableSnapshot()
        let applyCoordinator = world.coordinator(versionFault: NativeVersionFaultInjector(point: .migration_midRename))
        do {
            _ = try await applyCoordinator.setVersionKeepCount(.keepTwo)
            XCTFail("[migration_midRename] keep-count apply must refuse unsettled migration")
        } catch let error as NativeStorageError {
            if case .recoveryRequired = error {} else { XCTFail("[migration_midRename] keep-count apply got \(error), expected recoveryRequired") }
        } catch {
            XCTFail("[migration_midRename] keep-count apply got \(error), expected recoveryRequired")
        }
        world.assertNoPruneOrRewrite(afterPrune, try world.immutableSnapshot(), "[migration_midRename] apply refusal preserves objects and manifests")
        XCTAssertNil(world.defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey),
                     "[migration_midRename] failed apply does not save K")
        XCTAssertEqual(migration.readJournal(appId: identity.appId, projectId: identity.projectId)?.done, false,
                       "[migration_midRename] both refusals leave migration unsettled")
    }

    func testInterruptedSweepAndLegacyMigrationKeepReferencedBytesRecoverable() async throws {
        // SPEC 5.1 checks 18 and 19. The fixture file bytes and lstat block walk are independent of store reports.
        // MUTATION: sweep removes a referenced object, or migration interruption loses legacy revision contents.
        let gcWorld = try KCAWorld(); worlds.append(gcWorld)
        let app = "gc-crash-fixture", project = "gc-crash-fixture.mobile"
        let store = try NativeVersionStore(root: gcWorld.storeRoot)
        let active = try await versionsStageFixture(on: store, appId: app, projectId: project, seed: 1501, baseRevisionId: nil, createdAtOffset: -30)
        _ = try await store.activate(appId: app, projectId: project, revisionId: active)
        let manifest = try await store.manifests.read(appId: app, projectId: project, revisionId: active)
        var referencedBytes: [Data] = []
        for file in manifest.files {
            let objectURL = await store.objects.path(forSHA256: file.sha256)
            referencedBytes.append(try Data(contentsOf: objectURL))
        }
        let beforeGC = try gcWorld.hashes(at: gcWorld.storeRoot)
        let beforeGCBlocks = try gcWorld.allocatedBlocks(at: gcWorld.storeRoot)
        let orphan = try await store.objects.write(Data("independent orphan for interrupted sweep".utf8))
        let orphanPath = await store.objects.path(forSHA256: orphan)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: orphanPath.path)
        do {
            _ = try await store.gc.markAndSweep(graceSeconds: 0, fault: NativeVersionFaultInjector(point: .gcSweep_midSweep))
            XCTFail("[gcSweep_midSweep] expected injected sweep failure")
        } catch let crash as NativeVersionSimulatedCrash {
            XCTAssertEqual(crash.point, .gcSweep_midSweep, "[gcSweep_midSweep] reported point")
        }
        let postGC = try gcWorld.hashes(at: gcWorld.storeRoot)
        let postGCBlocks = try gcWorld.allocatedBlocks(at: gcWorld.storeRoot)
        XCTAssertGreaterThan(postGCBlocks, 0, "[gcSweep_midSweep] referenced revision still allocates blocks; baseline was \(beforeGCBlocks)")
        for (path, digest) in beforeGC { XCTAssertEqual(postGC[path], digest, "[gcSweep_midSweep] prior file hash at \(path)") }
        for (index, file) in manifest.files.enumerated() {
            let objectURL = await store.objects.path(forSHA256: file.sha256)
            XCTAssertEqual(try Data(contentsOf: objectURL), referencedBytes[index], "[gcSweep_midSweep] referenced object bytes remain")
        }
        _ = try await store.gc.markAndSweep(graceSeconds: 0, fault: NativeVersionFaultInjector())

        let migrationWorld = try KCAWorld(); worlds.append(migrationWorld)
        let migrationApp = "migration-crash-fixture", migrationProject = "migration-crash-fixture.mobile"
        let legacy = migrationWorld.root.appendingPathComponent("legacy", isDirectory: true)
        let v7 = "rev-sha256:" + String(repeating: "7", count: 64)
        let v8 = "rev-sha256:" + String(repeating: "8", count: 64)
        try VersionsLegacyFixture.write(revisions: [
            VersionsLegacyFixture.revision(id: v7, base: nil, seed: 1507, createdAt: "2026-09-29T00:00:00Z"),
            VersionsLegacyFixture.revision(id: v8, base: v7, seed: 1508, createdAt: "2026-09-30T00:00:00Z"),
        ], to: legacy)
        let migrationStore = try NativeVersionStore(root: migrationWorld.storeRoot)
        let migration = NativeStoreMigration(legacyRevisionsRoot: legacy, v1Root: migrationWorld.storeRoot)
        let legacyDigests = try migrationWorld.hashes(at: legacy)
        let beforeMigrationBlocks = try migrationWorld.allocatedBlocks(at: migrationWorld.root)
        do {
            try await migration.migrate(appId: migrationApp, projectId: migrationProject, currentRevisionId: v8, fallbackRevisionId: v7,
                                        objects: migrationStore.objects, manifests: migrationStore.manifests, refs: migrationStore.refs,
                                        ledger: migrationStore.ledger, checkouts: migrationStore.checkouts,
                                        fault: NativeVersionFaultInjector(point: .migration_midRename))
            XCTFail("[migration_midRename] expected injected migration failure")
        } catch let crash as NativeVersionSimulatedCrash {
            XCTAssertEqual(crash.point, .migration_midRename, "[migration_midRename] reported point")
        }
        let interruptedMigrationBlocks = try migrationWorld.allocatedBlocks(at: migrationWorld.root)
        XCTAssertGreaterThan(interruptedMigrationBlocks, 0, "[migration_midRename] legacy or migrated allocated blocks remain; baseline was \(beforeMigrationBlocks)")
        for digest in legacyDigests.values {
            XCTAssertTrue(try migrationWorld.hashes(at: legacy).values.contains(digest) || migrationWorld.hashes(at: migrationWorld.storeRoot).values.contains(digest),
                          "[migration_midRename] every legacy content or metadata hash remains in legacy or migrated storage")
        }
        try await migration.migrate(appId: migrationApp, projectId: migrationProject, currentRevisionId: v8, fallbackRevisionId: v7,
                                    objects: migrationStore.objects, manifests: migrationStore.manifests, refs: migrationStore.refs,
                                    ledger: migrationStore.ledger, checkouts: migrationStore.checkouts, fault: NativeVersionFaultInjector())
        XCTAssertEqual(migration.readJournal(appId: migrationApp, projectId: migrationProject)?.done, true, "[migration_midRename] retry settles migration")
    }
}

private final class KCAWorld {
    let root: URL
    let storeRoot: URL
    let defaults: UserDefaults
    let suite: String
    let catalog = KCACatalog()
    private var packageSerial = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("kca-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        suite = "kca-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
    func stageCrashWebRevision(on coordinator: NativeShellLibraryCoordinator, identity: NativeShellAppIdentity, seed: UInt64,
                               baseRevisionId: String?, createdAtOffset: TimeInterval) async throws -> String {
        let package = try generate(appId: identity.appId, projectId: identity.projectId,
                                   content: "crash-fixture-\(seed)-\(createdAtOffset)", base: baseRevisionId, sharedPrefix: nil)
        let review = try await coordinator.reviewImport(packageBytes: package.bytes, expectedIdentity: identity)
        let staged = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
        )
        return staged.revisionId
    }
    func coordinator(catalogFails: Bool = false, versionFault: NativeVersionFaultInjector? = nil) -> NativeShellLibraryCoordinator {
        let catalog = self.catalog
        return NativeShellLibraryCoordinator(rootURL: storeRoot, defaults: defaults, downloadableRevisionIds: { identity in
            if catalogFails { throw KCACatalogError.unavailable }
            return await catalog.offers(for: identity)
        }, versionFault: versionFault)
    }
    func store(_ identity: NativeShellAppIdentity) throws -> NativeRevisionStore {
        try NativeRevisionStore(rootURL: storeRoot, appId: identity.appId, projectId: identity.projectId, shellVersion: "1.0.0", defaults: defaults)
    }

    struct KCATimeline {
        let identity: NativeShellAppIdentity
        let ids: [String]
        let packages: [KCAPackage]
    }
    struct KCAPackage { let revisionId: String; let bytes: Data; let authority: KCAApproval; let content: String }
    struct KCAApproval: DeliveryApprovalAuthority {
        let approval: TrustedDeliveryApproval
        func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? { self.approval.approvalId == approvalId ? self.approval : nil }
    }

    func stageTimeline(app: String, count: Int, sharedPrefix: Int = 0) async throws -> KCATimeline {
        let identity = NativeShellAppIdentity(appId: app, projectId: "\(app).mobile")
        let store = try self.store(identity)
        var ids: [String] = [], packages: [KCAPackage] = [], base: String?
        for index in 0..<count {
            let content = "\(app)-revision-\(index)-\(UUID().uuidString)"
            let package = try generate(appId: app, projectId: identity.projectId, content: content, base: base, sharedPrefix: index < sharedPrefix ? "\(app)-shared" : nil)
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            ids.append(package.revisionId); packages.append(package); base = package.revisionId
        }
        XCTAssertEqual(Set(ids).count, count, "the test's package generator must produce distinct revision identities")
        let packageDigests = packages.map { SHA256.hash(data: $0.bytes).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(Set(packageDigests).count, count, "every staged package archive has distinct generated contents")
        let existingOffers = await catalog.offers(for: identity)
        await catalog.set(existingOffers.union(ids), for: identity)
        return KCATimeline(identity: identity, ids: ids, packages: packages)
    }

    private func generate(appId: String, projectId: String, content: String, base: String?, sharedPrefix: String?) throws -> KCAPackage {
        packageSerial += 1
        let output = root.appendingPathComponent("pkg-\(packageSerial)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let nonce = SHA256.hash(data: Data("\(appId)-\(packageSerial)".utf8)).map { String(format: "%02x", $0) }.joined()
        let payload = sharedPrefix.map { "\($0)-stable-shared-library" } ?? content
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--output", output.path, "--base", base ?? "null", "--content", sharedPrefix.map { "<!doctype html><title>shared</title><main>\($0)-stable-shared-library</main>" } ?? "<!doctype html><title>\(content)</title><main>\(payload)</main>", "--nonce", nonce, "--namespace", appId, "--capabilities", "[]", "--app", appId, "--project", projectId]
        let out = Pipe(), err = Pipe(); process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
              let packagePath = object["packagePath"] as? String, let approvalPath = object["trustedApprovalPath"] as? String,
              let revisionId = object["revisionId"] as? String else { throw KCABuildError.generatorFailed(String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown") }
        let approvalObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: approvalPath))) as? [String: Any])
        func text(_ key: String) throws -> String { try XCTUnwrap(approvalObject[key] as? String, "missing \(key)") }
        func optional(_ key: String) throws -> String? { approvalObject[key] is NSNull ? nil : try text(key) }
        let approval = TrustedDeliveryApproval(approvalId: try text("approvalId"), requestId: try optional("requestId"), requestNonce: try optional("requestNonce"), appId: try text("appId"), projectId: try text("projectId"), baseRevisionId: try optional("baseRevisionId"), approvedRevisionId: try text("approvedRevisionId"), approvedContentHash: try text("approvedContentHash"), approvedAt: try text("approvedAt"))
        return KCAPackage(revisionId: revisionId, bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)), authority: KCAApproval(approval: approval), content: content)
    }

    func hashes(at url: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in e where (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true) {
                let data = try Data(contentsOf: file); result[file.path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }
    struct KCAImmutableSnapshot {
        let files: [String: String]
        let manifestNames: Set<String>
        let blocks: Int64
    }

    func immutableSnapshot() throws -> KCAImmutableSnapshot {
        let allFiles = try hashes(at: storeRoot)
        let immutableFiles = allFiles.filter { path, _ in
            let components = URL(fileURLWithPath: path).pathComponents
            if components.contains("objects") { return true }
            return components.contains("manifests") && (components.last ?? "").hasPrefix("rev-sha256:") && (components.last ?? "").hasSuffix(".json")
        }
        let manifests = Set(immutableFiles.keys.filter { path in
            let components = URL(fileURLWithPath: path).pathComponents
            return components.contains("manifests")
        })
        return KCAImmutableSnapshot(files: immutableFiles, manifestNames: manifests, blocks: try allocatedBlocks(at: storeRoot))
    }

    func assertNoPruneOrRewrite(_ before: KCAImmutableSnapshot, _ after: KCAImmutableSnapshot, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(before.files.allSatisfy { after.files[$0.key] == $0.value }, "[\(label)] no object or revision manifest was removed or changed", file: file, line: line)
        XCTAssertTrue(before.manifestNames.isSubset(of: after.manifestNames), "[\(label)] no revision that was present is gone", file: file, line: line)
        XCTAssertGreaterThanOrEqual(after.blocks, before.blocks, "[\(label)] allocated object blocks did not decrease", file: file, line: line)
        if let e = FileManager.default.enumerator(at: storeRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in e {
                XCTAssertFalse(url.lastPathComponent.hasSuffix(".json.tomb") || url.lastPathComponent.hasSuffix(".json.freed"),
                               "[\(label)] no tombstone or freed manifest marker exists at \(url.path)", file: file, line: line)
            }
        }
    }
    func allocatedBlocks(at url: URL) throws -> Int64 {
        var seen: Set<String> = [], total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let file as URL in e {
                guard file.pathComponents.contains("objects") else { continue }
                var s = stat(); guard lstat(file.path, &s) == 0, (s.st_mode & S_IFMT) == S_IFREG else { continue }
                let key = "\(s.st_dev):\(s.st_ino)"; guard seen.insert(key).inserted else { continue }
                total += Int64(s.st_blocks) * 512
            }
        }
        return total
    }
    func assertUsableFixtureRevision(_ package: KCAPackage, identity: NativeShellAppIdentity, file: StaticString = #filePath, line: UInt = #line) async throws {
        let store = try self.store(identity)
        let present = try await store.revisionIsOnThisPhone(revisionId: package.revisionId)
        XCTAssertTrue(present, "the independently recorded fixture revision \(package.revisionId) remains usable", file: file, line: line)
    }
}

private actor KCACatalog {
    private var values: [NativeShellAppIdentity: Set<String>] = [:]
    func set(_ ids: Set<String>, for identity: NativeShellAppIdentity) { values[identity] = ids }
    func offers(for identity: NativeShellAppIdentity) -> Set<String> { values[identity, default: []] }
}
private enum KCACatalogError: Error { case unavailable }
private enum KCABuildError: Error { case generatorFailed(String) }
