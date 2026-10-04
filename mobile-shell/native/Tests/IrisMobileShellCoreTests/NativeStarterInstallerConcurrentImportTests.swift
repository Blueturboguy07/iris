import Foundation
import XCTest
@testable import IrisMobileShellCore

/// P2 "hurried power user" world for `NativeStarterInstaller`. New file; no
/// existing test file is edited.
///
/// `IrisMobileShellApp.init()` fires the starter install as a background
/// `Task` against the SAME `NativeShellLibraryCoordinator` the live UI
/// drives, and the UI is interactive immediately. That coordinator has one
/// single-slot pending review for its whole lifetime. The existing P2 test
/// only races `installMissing` against itself; this suite races it against
/// a reader importing a DIFFERENT app through the exact coordinator calls
/// the Host makes:
///
/// - File import / "Open in Iris" from Files (`NativeShellAppView`
///   `beginIncomingPackage` + `presentReview` + `approveLocallyAndStage`):
///   `supersedePendingReview(clientReviewSequence:)`, then
///   `reviewImport(packageBytes:clientReviewSequence:)`, the reader reads the
///   sheet, then `approvePendingReviewLocallyAndStage`, `activate`,
///   `launchActive`. A token mismatch there is what the Host shows as "the
///   visible package review is no longer the pending review" with Retry.
/// - Website install (`NativeWebsiteInstallFlow.installAndOpen` commit):
///   `reviewImportIfIdle` (nil is `anotherPackageReviewPending`), then the
///   same approve/activate/launch.
///
/// The only thing simulated is the reader's timing (when they act, how long
/// they read the sheet), drawn from a seeded generator and printed per round
/// so any failing round can be reproduced. Everything else is production
/// code on a real temporary filesystem, with real package bytes from the
/// independent Node generator (`Tests/Fixtures/generate-desktop-package-from-file.mjs`,
/// which drives the real desktop CLI publisher).
///
/// Oracles are the world, not the code's opinion of itself: the store's
/// on-disk active pointer and revision directories read directly, plus an
/// independent reference store built by staging and activating the same
/// chain one package at a time through the coordinator (never through
/// `NativeStarterInstaller`). No call counts.
final class NativeStarterInstallerConcurrentImportTests: XCTestCase {
    fileprivate static var sharedWorld: ConcurrentImportWorld?

    override class func tearDown() {
        sharedWorld?.cleanup()
        sharedWorld = nil
        super.tearDown()
    }

    /// The fact the reader cares about most: their own app, imported while the
    /// starter apps are still installing, ends up installed and opening, and
    /// the starter app ends up either fully installed or in a state its own
    /// installer could have left, and the next launch (a fresh coordinator
    /// over the same files, as after a real relaunch) converges to exactly
    /// the reference state. This must hold whether the starter chain
    /// finished in the first launch or stopped safely.
    func testP2ReaderImportsAnotherAppMidStarterChainBothEndConsistentAndNextLaunchConverges() async throws {
        let world = try await Self.world()
        var overlapped = 0
        for plan in Self.roundPlans() {
            let storeRoot = try world.freshStoreRoot()
            let outcome = try await Self.runRound(plan, world: world, storeRoot: storeRoot, installer: NativeStarterInstaller())
            print(outcome.summary)
            if outcome.overlapped { overlapped += 1 }
            let context = outcome.summary

            // The reader's own app, verified through the public library and store facades.
            XCTAssertNil(outcome.readerFailure, "reader never got their app: \(context)")
            let readerStore = try NativeRevisionStore(rootURL: storeRoot, appId: world.readerIdentity.appId, projectId: world.readerIdentity.projectId, shellVersion: "1.0.0")
            let readerCoordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
            let maybeReaderEntry = try await readerCoordinator.libraryEntry(identity: world.readerIdentity)
            let readerEntry = try XCTUnwrap(maybeReaderEntry)
            let readerActive = try await readerStore.activeRevisionId()
            XCTAssertEqual(readerActive, world.readerApp.revisionId, "SPEC 2.1: reader active pointer is public and consistent: \(context)")
            XCTAssertEqual(readerEntry.revisions.map(\.revisionId), [world.readerApp.revisionId], "SPEC 2.1: reader has one visible revision: \(context)")
            let readerDescriptor = try await readerStore.launchDescriptorForActiveRevision()
            XCTAssertEqual(readerDescriptor.revisionId, world.readerApp.revisionId, context)

            // The starter app after the first launch.
            let firstCoordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
            let starterStore = try NativeRevisionStore(rootURL: storeRoot, appId: world.starterIdentity.appId, projectId: world.starterIdentity.projectId, shellVersion: "1.0.0")
            let starterEntry = try await firstCoordinator.libraryEntry(identity: world.starterIdentity)
            let starterSummaries = try await starterStore.revisionSummaries()
            let starterIds = Set(starterSummaries.map(\.revisionId))
            XCTAssertTrue(starterIds.isSubset(of: world.chainRevisionIds), "SPEC 2.1: only staged chain revisions appear in the public store summaries: \(context)")
            switch outcome.starterFirstLaunch {
            case .installed(_, let finalRevisionId):
                XCTAssertEqual(finalRevisionId, world.chain.last!.revisionId, context)
                XCTAssertEqual(starterEntry?.currentRevisionId, finalRevisionId, "SPEC 2.1: library current revision agrees with installer result: \(context)")
            XCTAssertLessThanOrEqual(starterIds.count, world.chainRevisionIds.count, "SPEC 2.1: public summaries contain no revisions outside the chain: \(context)")
            case .failed:
                let current = try await starterStore.activeRevisionId()
                let fallback = try await starterStore.fallbackRevisionId()
                XCTAssertTrue(current == nil || world.chainRevisionIds.contains(current!), "SPEC 2.3: stopped chain current is a staged chain member: \(context)")
                if let current, let index = world.chain.firstIndex(where: { $0.revisionId == current }) {
                    XCTAssertEqual(fallback, index == 0 ? nil : world.chain[index - 1].revisionId, "SPEC 2.3: stopped chain pointer remains resumable: \(context)")
                }
            case .alreadyPresent, nil:
                XCTFail("a fresh store cannot already hold the starter app: \(context)")
            }

            // Next launch: new coordinator (fresh in-memory review slot and
            // store cache), no concurrent reader.
            let relaunched = NativeShellLibraryCoordinator(rootURL: storeRoot)
            _ = await NativeStarterInstaller().installMissing(world.chains, into: relaunched)
            let afterEntry = try await relaunched.libraryEntry(identity: world.starterIdentity)
            let afterStore = try NativeRevisionStore(rootURL: storeRoot, appId: world.starterIdentity.appId, projectId: world.starterIdentity.projectId, shellVersion: "1.0.0")
            let afterSummaries = try await afterStore.revisionSummaries()
            let afterIds = Set(afterSummaries.map(\.revisionId))
            XCTAssertEqual(afterEntry?.currentRevisionId, world.chain.last?.revisionId, "SPEC 2.1: next launch converges to chain head: \(context)")
            XCTAssertEqual(afterIds, starterIds, "SPEC 2.1: next launch preserves the same stored revision set: \(context)")
            let manifestCounts = try independentManifestCounts(storeRoot, revisionIds: Array(afterIds))
            for revisionId in afterIds {
                XCTAssertEqual(manifestCounts[revisionId], 1, "SPEC 2.1: exactly one content-discovered manifest exists for \(revisionId): \(context)")
            }
            let readerActiveAfter = try await readerStore.activeRevisionId()
            XCTAssertEqual(readerActiveAfter, world.readerApp.revisionId, "SPEC 2.1: starter relaunch leaves reader pointer unchanged: \(context)")
            XCTAssertFalse(try independentTemporaryEntries(storeRoot), "SPEC 2.2: completed operations leave no temporary store files: \(context)")
            let readerLaunch = try await relaunched.launchActive(identity: world.readerIdentity)
            XCTAssertEqual(readerLaunch.launchedRevisionId, world.readerApp.revisionId, context)
        }
        // Precondition, not a behavior claim: the world really produced the
        // overlap this suite is about in every round.
        XCTAssertEqual(overlapped, Self.roundPlans().count, "some rounds never overlapped the reader with a mid-chain starter install")
    }

    /// The reader-facing contract: background starter work the reader never
    /// asked for must not make the reader's own "Install" tap fail, and a
    /// reader import of another app must not cost the starter chain its
    /// first-launch install.
    func testP2ReaderImportMidStarterChainIsNeverBouncedAndStarterStillFinishesThisLaunch() async throws {
        let world = try await Self.world()
        var overlapped = 0
        var websiteBounces = 0
        for plan in Self.roundPlans() {
            let storeRoot = try world.freshStoreRoot()
            let outcome = try await Self.runRound(plan, world: world, storeRoot: storeRoot, installer: NativeStarterInstaller())
            print(outcome.summary)
            if outcome.overlapped { overlapped += 1 }
            XCTAssertNil(outcome.readerFailure, outcome.summary)

            switch plan.path {
            case .fileImport:
                // The Host's own review always takes the slot, so any bounce
                // here was caused by the background starter pass.
                XCTAssertEqual(outcome.readerBounces, 0, "reader's visible review was taken away by the starter pass: \(outcome.summary)")
            case .websiteInstall:
                // Recorded, not asserted: `reviewImportIfIdle` treats any
                // pending review as busy, including a starter step's own
                // one-hop review. See HANDOFF for the coordinator-side fix.
                websiteBounces += outcome.readerBounces
            }

            guard case .installed(_, let finalRevisionId) = outcome.starterFirstLaunch else {
                XCTFail("starter chain did not finish in the launch the reader interrupted: \(outcome.summary)")
                continue
            }
            XCTAssertEqual(finalRevisionId, world.chain.last!.revisionId, outcome.summary)
            XCTAssertEqual(
                world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).comparable,
                world.reference,
                outcome.summary
            )
        }
        print("website-path reader bounces across all rounds: \(websiteBounces)")
        XCTAssertEqual(overlapped, Self.roundPlans().count, "some rounds never overlapped the reader with a mid-chain starter install")
    }

    /// P2 opens their own import mid-chain and leaves the review sheet up
    /// longer than the starter pass is willing to wait. The starter pass must
    /// stop without touching the reader's review, leave only a resumable
    /// chain state, and the next launch must converge to the reference.
    func testP2ReaderHoldsReviewOpenPastStarterWaitStarterStopsSafelyAndNextLaunchConverges() async throws {
        let world = try await Self.world()
        let storeRoot = try world.freshStoreRoot()
        // About 15 ms of patience, so a 400 ms read of the sheet outlasts it.
        let impatient = NativeStarterInstaller(reviewSlotWait: .init(
            initialDelayNanoseconds: 1_000_000, maximumDelayNanoseconds: 4_000_000, maximumAttempts: 5
        ))
        let plan = RoundPlan(seed: 0, path: .fileImport, start: .afterStarterActivates(0), thinkMilliseconds: 400)
        let outcome = try await Self.runRound(plan, world: world, storeRoot: storeRoot, installer: impatient)
        print(outcome.summary)

        XCTAssertTrue(outcome.overlapped, "precondition: the reader acted mid-chain: \(outcome.summary)")
        guard case .failed(let reason) = outcome.starterFirstLaunch else {
            return XCTFail("precondition: the starter should have run out of patience: \(outcome.summary)")
        }
        XCTAssertEqual(reason, String(describing: NativeStarterInstaller.Failure.readerReviewStillOpen(label: "world")))
        XCTAssertNil(outcome.readerFailure, outcome.summary)
        XCTAssertEqual(outcome.readerBounces, 0, "the waiting starter pass took the reader's review away: \(outcome.summary)")

        let stopped = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity)
        XCTAssertTrue(world.isResumableChainState(stopped), "\(stopped)")
        XCTAssertNotEqual(stopped.comparable, world.reference, "precondition: the chain really stopped short")
        XCTAssertEqual(stopped.leftovers, [])

        let relaunched = NativeShellLibraryCoordinator(rootURL: storeRoot)
        _ = await NativeStarterInstaller().installMissing(world.chains, into: relaunched)
        XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).comparable, world.reference)
        XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.readerIdentity).pointer?.currentRevisionId, world.readerApp.revisionId)
    }

    /// Every later launch runs the starter pass again, against apps that are
    /// already installed. A reader who cold-launches Iris by opening a
    /// `.irisapp` from Files has their review sheet up while that check runs.
    /// A realistic 300 ms read of the sheet spans the whole check; the check
    /// must not take the reader's review away.
    func testP2ReaderOpensAFileAtALaterLaunchIsNotBouncedByTheStarterCheck() async throws {
        let world = try await Self.world()
        let storeRoot = try world.freshStoreRoot()
        _ = await NativeStarterInstaller().installMissing(world.chains, into: NativeShellLibraryCoordinator(rootURL: storeRoot))
        XCTAssertEqual(
            world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).comparable, world.reference,
            "precondition: the starter apps were installed on an earlier launch"
        )

        let plan = RoundPlan(seed: 0, path: .fileImport, start: .atLaunch, thinkMilliseconds: 300)
        let outcome = try await Self.runRound(plan, world: world, storeRoot: storeRoot, installer: NativeStarterInstaller())
        print(outcome.summary)
        XCTAssertTrue(outcome.starterRunningWhenReaderActs, "precondition: the reader acted while the starter check was still running")
        XCTAssertNil(outcome.readerFailure, outcome.summary)
        XCTAssertEqual(outcome.readerBounces, 0, "the starter check on a later launch took the reader's review away: \(outcome.summary)")
        XCTAssertEqual(outcome.starterFirstLaunch, .alreadyPresent(currentRevisionId: world.chain.last!.revisionId))
        XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).comparable, world.reference)
        XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.readerIdentity).pointer?.currentRevisionId, world.readerApp.revisionId)
    }

    /// P2 fumbles in the picker while the starter apps install: opens a file,
    /// glances, dismisses, opens again, many times, and only then installs
    /// for real. Each open is `supersedePendingReview` + `reviewImport` and
    /// each dismiss is `cancelReview(reviewToken:)`, as in the Host. Those
    /// opens land between a starter step's review and its approval, which
    /// takes the starter's review away; the starter must retry that step, not
    /// give up the chain for this launch.
    func testP2ReaderFumblesOpenAndDismissDuringStarterInstallStarterStillFinishesThisLaunch() async throws {
        let world = try await Self.world()
        for seed: UInt64 in [0xF00D_0001, 0xF00D_0002, 0xF00D_0003] {
            let storeRoot = try world.freshStoreRoot()
            let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
            let starterFinished = Flag()
            let chains = world.chains
            async let starterResults: [String: NativeStarterInstaller.AppResult] = {
                let results = await NativeStarterInstaller().installMissing(chains, into: coordinator)
                await starterFinished.set()
                return results
            }()

            var generator = SplitMix64(seed: seed)
            var generation: UInt64 = 0
            // Only the Host's own calls in this loop. An extra observer call
            // (for example `pendingPackageReview()`) would itself be the
            // message that lands between a starter step's review and its
            // approval, absorbing the very collision this test is about.
            // Whether the collision really happens is proven by mutation
            // check M3 (HANDOFF), not by an in-test witness.
            var fumblesWhileStarterRan = 0
            let fumbleUntil = Date().addingTimeInterval(3)
            while !(await starterFinished.isSet), Date() < fumbleUntil {
                fumblesWhileStarterRan += 1
                generation += 1
                await coordinator.supersedePendingReview(clientReviewSequence: generation)
                let glance = try await coordinator.reviewImport(
                    packageBytes: world.readerApp.bytes, clientReviewSequence: generation
                )
                try await Task.sleep(nanoseconds: (generator.next() % 4) * 1_000_000)
                await coordinator.cancelReview(reviewToken: glance.reviewToken)
                try await Task.sleep(nanoseconds: (1 + generator.next() % 8) * 1_000_000)
            }

            let finalPlan = RoundPlan(seed: seed, path: .fileImport, start: .atLaunch, thinkMilliseconds: 20)
            var readerFailure: String?
            var bounces = 0
            do {
                bounces = try await Self.readerInstalls(
                    finalPlan, world: world, coordinator: coordinator, lastReviewSequence: generation
                )
            } catch {
                readerFailure = String(describing: error)
            }
            let results = await starterResults
            let context = "[seed=\(String(seed, radix: 16)) fumble] fumblesWhileStarterRan=\(fumblesWhileStarterRan) starter=\(String(describing: results["world"])) readerBounces=\(bounces)"
            print(context)

            XCTAssertGreaterThan(fumblesWhileStarterRan, 10, "precondition: the reader fumbled while the starter chain was installing: \(context)")
            XCTAssertNil(readerFailure, context)
            XCTAssertEqual(bounces, 0, context)
            guard case .installed(_, let finalRevisionId) = results["world"] else {
                XCTFail("starter chain gave up this launch because the reader fumbled: \(context)")
                continue
            }
            XCTAssertEqual(finalRevisionId, world.chain.last!.revisionId, context)
            XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).comparable, world.reference, context)
            XCTAssertEqual(world.diskState(storeRoot: storeRoot, identity: world.readerIdentity).pointer?.currentRevisionId, world.readerApp.revisionId, context)
        }
    }

    /// P3 edge user: the reader deliberately goes back to the previous
    /// version of a starter app ("Use previous version"). The next launch's
    /// starter pass must leave that choice alone; starter content never
    /// reactivates existing reader state.
    func testReaderRevertOfAStarterAppIsNotUndoneByTheNextLaunch() async throws {
        let world = try await Self.world()
        let storeRoot = try world.freshStoreRoot()
        let threePackageChain = Array(world.chain.prefix(3))
        let chains = ["world": NativeStarterInstaller.AppChain(
            displayName: "Starter World", orderedPackages: threePackageChain.map(\.bytes)
        )]

        let firstLaunch = NativeShellLibraryCoordinator(rootURL: storeRoot)
        _ = await NativeStarterInstaller().installMissing(chains, into: firstLaunch)
        let installed = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity)
        XCTAssertEqual(installed.pointer?.currentRevisionId, threePackageChain[2].revisionId, "precondition: chain installed")

        // The reader's revert, through the same coordinator call the Host's
        // revert action makes.
        try await firstLaunch.revert(identity: world.starterIdentity, to: threePackageChain[1].revisionId)
        let reverted = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity)
        XCTAssertEqual(reverted.pointer?.currentRevisionId, threePackageChain[1].revisionId, "precondition: revert applied")

        let nextLaunch = NativeShellLibraryCoordinator(rootURL: storeRoot)
        _ = await NativeStarterInstaller().installMissing(chains, into: nextLaunch)
        let afterRelaunch = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity)
        XCTAssertEqual(afterRelaunch.pointer?.currentRevisionId, threePackageChain[1].revisionId, "the reader's revert was undone by the starter pass")
        XCTAssertEqual(afterRelaunch.comparable, reverted.comparable, "the starter pass changed a reverted app's stored state")
    }
}

// MARK: - Round plans (seeded, printed, reproducible)

private struct RoundPlan: CustomStringConvertible {
    enum Path: String { case fileImport, websiteInstall }
    enum Start: CustomStringConvertible {
        case atLaunch
        /// Wait until the starter's on-disk active pointer reaches this chain
        /// index (0-based) or later, then act.
        case afterStarterActivates(Int)
        var description: String {
            switch self {
            case .atLaunch: return "atLaunch"
            case .afterStarterActivates(let index): return "afterStarterActivates(\(index))"
            }
        }
    }

    let seed: UInt64
    let path: Path
    let start: Start
    let thinkMilliseconds: UInt64

    var description: String {
        "seed=\(String(seed, radix: 16)) path=\(path.rawValue) start=\(start) think=\(thinkMilliseconds)ms"
    }
}

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension NativeStarterInstallerConcurrentImportTests {
    /// Every combination of path x start point, with seeded reading times.
    fileprivate static func roundPlans(baseSeed: UInt64 = 0x1715_0927) -> [RoundPlan] {
        var generator = SplitMix64(seed: baseSeed)
        var plans: [RoundPlan] = []
        for path in [RoundPlan.Path.fileImport, .websiteInstall] {
            for start in [RoundPlan.Start.atLaunch, .afterStarterActivates(0), .afterStarterActivates(1), .afterStarterActivates(2)] {
                let seed = generator.next()
                var local = SplitMix64(seed: seed)
                plans.append(RoundPlan(seed: seed, path: path, start: start, thinkMilliseconds: 5 + local.next() % 56))
            }
        }
        return plans
    }
}

private func independentManifestCounts(_ root: URL, revisionIds: [String]) throws -> [String: Int] {
    let wanted = Set(revisionIds)
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
    var counts: [String: Int] = [:]
    for case let url as URL in enumerator where url.pathExtension == "json" && url.pathComponents.contains("manifests") {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let revisionId = independentManifestRevisionId(object) else { continue }
        if wanted.contains(revisionId) { counts[revisionId, default: 0] += 1 }
    }
    return counts
}

private func independentManifestRevisionId(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
        if let revisionId = object["revisionId"] as? String { return revisionId }
        for nested in object.values {
            if let revisionId = independentManifestRevisionId(nested) { return revisionId }
        }
    } else if let array = value as? [Any] {
        for nested in array {
            if let revisionId = independentManifestRevisionId(nested) { return revisionId }
        }
    }
    return nil
}

private func independentTemporaryEntries(_ root: URL) throws -> Bool {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return false }
    for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("tmp-") { return true }
    return false
}

// MARK: - One round of the world

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

private struct RoundOutcome {
    let plan: RoundPlan
    let starterFirstLaunch: NativeStarterInstaller.AppResult?
    let readerBounces: Int
    /// The starter pass had not finished when the reader first acted.
    let starterRunningWhenReaderActs: Bool
    /// ...and the starter app was not yet at its final revision (mid-chain).
    let overlapped: Bool
    let readerFailure: String?

    var summary: String {
        let starter: String
        switch starterFirstLaunch {
        case .installed(let steps, _): starter = "installed(\(steps.count) steps)"
        case .alreadyPresent: starter = "alreadyPresent"
        case .failed(let reason): starter = "failed(\(reason))"
        case nil: starter = "missing"
        }
        return "[\(plan)] overlapped=\(overlapped) readerBounces=\(readerBounces) starter=\(starter) readerFailure=\(readerFailure ?? "none")"
    }
}

extension NativeStarterInstallerConcurrentImportTests {
    fileprivate static func runRound(
        _ plan: RoundPlan,
        world: ConcurrentImportWorld,
        storeRoot: URL,
        installer: NativeStarterInstaller
    ) async throws -> RoundOutcome {
        // One coordinator shared by the starter pass and the reader, exactly
        // as `IrisMobileShellApp.init()` wires it.
        let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
        let starterFinished = Flag()
        let chains = world.chains
        async let starterResults: [String: NativeStarterInstaller.AppResult] = {
            let results = await installer.installMissing(chains, into: coordinator)
            await starterFinished.set()
            return results
        }()

        if case .afterStarterActivates(let index) = plan.start {
            let targets = Set(world.chain[index...].map(\.revisionId))
            while !(await starterFinished.isSet) {
                if let pointer = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).pointer,
                   targets.contains(pointer.currentRevisionId) {
                    break
                }
                try await Task.sleep(nanoseconds: 200_000)
            }
        }
        let pointerWhenReaderActs = world.diskState(storeRoot: storeRoot, identity: world.starterIdentity).pointer
        let starterRunning = !(await starterFinished.isSet)
        let overlapped = starterRunning && pointerWhenReaderActs?.currentRevisionId != world.chain.last!.revisionId

        var bounces = 0
        var readerFailure: String?
        do {
            bounces = try await readerInstalls(plan, world: world, coordinator: coordinator)
        } catch {
            readerFailure = String(describing: error)
        }
        let results = await starterResults
        return RoundOutcome(
            plan: plan,
            starterFirstLaunch: results["world"],
            readerBounces: bounces,
            starterRunningWhenReaderActs: starterRunning,
            overlapped: overlapped,
            readerFailure: readerFailure
        )
    }

    /// The reader's side, as the Host drives the coordinator. Returns how
    /// many times the reader was bounced (each one a visible error with a
    /// Retry the hurried reader taps immediately). `lastReviewSequence`
    /// continues the Host's presentation generation, which only ever grows
    /// within one app session.
    private static func readerInstalls(
        _ plan: RoundPlan,
        world: ConcurrentImportWorld,
        coordinator: NativeShellLibraryCoordinator,
        lastReviewSequence: UInt64 = 0
    ) async throws -> Int {
        let think = plan.thinkMilliseconds * 1_000_000
        let maximumBounces = 50
        var bounces = 0
        var generation = lastReviewSequence
        while true {
            let review: NativeShellPackageReview
            switch plan.path {
            case .fileImport:
                generation += 1
                await coordinator.supersedePendingReview(clientReviewSequence: generation)
                review = try await coordinator.reviewImport(
                    packageBytes: world.readerApp.bytes,
                    clientReviewSequence: generation
                )
                try await Task.sleep(nanoseconds: think) // reading the review sheet
            case .websiteInstall:
                try await Task.sleep(nanoseconds: think) // reading the website confirm step
                guard let idleReview = try await coordinator.reviewImportIfIdle(
                    packageBytes: world.readerApp.bytes,
                    expectedIdentity: world.readerIdentity
                ) else {
                    bounces += 1 // NativeWebsiteInstallFlowError.anotherPackageReviewPending
                    guard bounces < maximumBounces else { throw ReaderGaveUp(bounces: bounces) }
                    continue
                }
                review = idleReview
            }
            do {
                let staged = try await coordinator.approvePendingReviewLocallyAndStage(
                    reviewToken: review.reviewToken,
                    packageSHA256: review.packageSHA256
                )
                try await coordinator.activate(identity: staged.identity, revisionId: staged.revisionId)
                let launch = try await coordinator.launchActive(identity: staged.identity)
                guard launch.launchedRevisionId == world.readerApp.revisionId else {
                    throw ReaderOpenedWrongRevision(expected: world.readerApp.revisionId, actual: launch.launchedRevisionId)
                }
                return bounces
            } catch NativeShellLibraryError.reviewTokenMismatch, NativeShellLibraryError.noPendingReview {
                bounces += 1
                guard bounces < maximumBounces else { throw ReaderGaveUp(bounces: bounces) }
            }
        }
    }
}

private struct ReaderGaveUp: Error { let bounces: Int }
private struct ReaderOpenedWrongRevision: Error { let expected: String; let actual: String }

// MARK: - World: packages, reference store, disk observation

private struct GeneratedPackage {
    let bytes: Data
    let revisionId: String
}

private struct DiskPointer: Decodable, Equatable {
    let currentRevisionId: String
    let fallbackRevisionId: String?
}

private struct DiskState: Equatable, CustomStringConvertible {
    let pointer: DiskPointer?
    let visibleRevisions: Set<String>
    /// `.staging-*` / `.trash-*` entries: evidence of an interrupted write.
    let leftovers: [String]

    var comparable: ComparableState {
        ComparableState(current: pointer?.currentRevisionId, fallback: pointer?.fallbackRevisionId, revisions: visibleRevisions)
    }

    var description: String {
        let current = pointer.map { String($0.currentRevisionId.suffix(8)) } ?? "nil"
        let fallback = pointer?.fallbackRevisionId.map { String($0.suffix(8)) } ?? "nil"
        return "current=\(current) fallback=\(fallback) revisions=\(visibleRevisions.map { String($0.suffix(8)) }.sorted()) leftovers=\(leftovers)"
    }
}

private struct ComparableState: Equatable {
    let current: String?
    let fallback: String?
    let revisions: Set<String>
}

private final class ConcurrentImportWorld: @unchecked Sendable {
    let starterIdentity = NativeShellAppIdentity(appId: "starter.world", projectId: "starter.world.mobile")
    let readerIdentity = NativeShellAppIdentity(appId: "reader.notes", projectId: "reader.notes.mobile")
    let root: URL
    let chain: [GeneratedPackage]
    let readerApp: GeneratedPackage
    /// Independent reference: the state after staging and activating the
    /// same chain one package at a time through the coordinator, with no
    /// installer and no concurrency.
    private(set) var reference: ComparableState!
    private var storeIndex = 0
    private let lock = NSLock()

    var chains: [String: NativeStarterInstaller.AppChain] {
        ["world": NativeStarterInstaller.AppChain(displayName: "Starter World", orderedPackages: chain.map(\.bytes))]
    }

    var chainRevisionIds: Set<String> { Set(chain.map(\.revisionId)) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-starter-concurrent-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var packages: [GeneratedPackage] = []
        // Four packages, the real Nut AI / FreeHarmony chain length. About
        // 1.5 MB each so every chain step takes real time, as the real 12-36
        // MB bundled packages do.
        for (index, nonceCharacter) in ["t", "u", "v", "w"].enumerated() {
            packages.append(try Self.generate(
                in: root, index: index,
                marker: "starter-world-\(index)", padding: 1_500_000,
                baseRevisionId: packages.last?.revisionId,
                nonce: String(repeating: nonceCharacter, count: 64),
                identity: starterIdentity, namespace: "starter.world.v1", displayName: "Starter World"
            ))
        }
        chain = packages
        readerApp = try Self.generate(
            in: root, index: 99,
            marker: "reader-notes", padding: 200_000,
            baseRevisionId: nil,
            nonce: String(repeating: "x", count: 64),
            identity: readerIdentity, namespace: "reader.notes.v1", displayName: "Notes"
        )
    }

    func buildReference() async throws {
        let storeRoot = try freshStoreRoot()
        let coordinator = NativeShellLibraryCoordinator(rootURL: storeRoot)
        for package in chain {
            let review = try await coordinator.reviewImport(packageBytes: package.bytes)
            _ = try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
            )
            try await coordinator.activate(identity: starterIdentity, revisionId: package.revisionId)
        }
        reference = diskState(storeRoot: storeRoot, identity: starterIdentity).comparable
    }

    func freshStoreRoot() throws -> URL {
        lock.lock()
        storeIndex += 1
        let index = storeIndex
        lock.unlock()
        return root.appendingPathComponent("store-\(index)", isDirectory: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Reads the store's own files directly, not through the coordinator.
    func diskState(storeRoot: URL, identity: NativeShellAppIdentity) -> DiskState {
        let pointerURL = storeRoot
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(identity.appId, isDirectory: true)
            .appendingPathComponent(identity.projectId, isDirectory: true)
            .appendingPathComponent("active.json", isDirectory: false)
        let pointer = (try? Data(contentsOf: pointerURL)).flatMap { try? JSONDecoder().decode(DiskPointer.self, from: $0) }
        let revisionsURL = storeRoot
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(identity.appId, isDirectory: true)
            .appendingPathComponent(identity.projectId, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: revisionsURL.path)) ?? []
        return DiskState(
            pointer: pointer,
            visibleRevisions: Set(entries.filter { !$0.hasPrefix(".") }),
            leftovers: entries.filter { $0.hasPrefix(".staging-") || $0.hasPrefix(".trash-") }.sorted()
        )
    }

    /// A state the installer itself can leave behind when it stops early:
    /// nothing active yet, or package i active with package i-1 as its
    /// fallback (forward-only activation along the chain).
    func isResumableChainState(_ state: DiskState) -> Bool {
        guard let pointer = state.pointer else { return true }
        guard let index = chain.firstIndex(where: { $0.revisionId == pointer.currentRevisionId }) else { return false }
        let expectedFallback = index == 0 ? nil : chain[index - 1].revisionId
        return pointer.fallbackRevisionId == expectedFallback
    }

    private static func generate(
        in root: URL,
        index: Int,
        marker: String,
        padding: Int,
        baseRevisionId: String?,
        nonce: String,
        identity: NativeShellAppIdentity,
        namespace: String,
        displayName: String
    ) throws -> GeneratedPackage {
        let output = root.appendingPathComponent("package-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let contentFile = output.appendingPathComponent("content.html")
        let html = "<!doctype html><meta charset=utf-8><title>\(displayName)</title><main>\(marker)</main><!--\(String(repeating: "p", count: padding))-->"
        try Data(html.utf8).write(to: contentFile)
        let script = repositoryRoot()
            .appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package-from-file.mjs")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--content-file", contentFile.path,
            "--base", baseRevisionId ?? "null",
            "--nonce", nonce,
            "--namespace", namespace,
            "--display-name", displayName,
            "--capabilities", "[]",
            "--app", identity.appId,
            "--project", identity.projectId,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorldError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "unknown generator error")
        }
        guard let result = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let packagePath = result["packagePath"] as? String,
              let revisionId = result["revisionId"] as? String else {
            throw WorldError.malformedFixture("missing packagePath/revisionId")
        }
        return GeneratedPackage(bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)), revisionId: revisionId)
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum WorldError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
}

extension NativeStarterInstallerConcurrentImportTests {
    /// Generated once per test run (the Node publisher takes real time), with
    /// a fresh store root per round.
    fileprivate static func world() async throws -> ConcurrentImportWorld {
        if let sharedWorld { return sharedWorld }
        let world = try ConcurrentImportWorld()
        try await world.buildReference()
        sharedWorld = world
        return world
    }
}
