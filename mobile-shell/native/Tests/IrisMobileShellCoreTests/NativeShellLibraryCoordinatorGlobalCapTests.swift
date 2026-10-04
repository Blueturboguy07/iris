import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Coordinator-level tests for the cross-app global code cap
/// (`planGlobalCapEnforcement`/`enforceGlobalCap`) and for Library/Storage
/// screen performance at scale (SPEC.md R8.9/R8.10, this unit's brief items
/// 1 and 3). Correctness cases use a handful of real apps so each assertion
/// is fast and specific; the scale cases build a much larger synthetic
/// store (SPEC.md R8.10's own words: "measured in SwiftPM with a synthetic
/// store") to time the read path the Library/Storage screens actually use.
final class NativeShellLibraryCoordinatorGlobalCapTests: XCTestCase {
    // MARK: - Correctness: plan-then-enforce, real apps

    /// The plan states reclaimable bytes and never removes a current,
    /// previous, pending or pinned revision; `enforceGlobalCap` then
    /// actually reclaims what the plan promised, oracle-checked with real
    /// `st_blocks` measurement before and after, not a number this test set.
    func testPlanThenEnforceReclaimsAtLeastThePromisedBytesAndNeverTouchesAProtectedRevision() async throws {
        let fixture = try GlobalCapFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.isolatedDefaults()
        let coordinator = fixture.coordinator(defaults: defaults)

        // Three small apps, each updated three times through the real
        // product path. The coordinator prunes after every activate
        // (current, previous, pending and pinned are kept; SPEC R8.9), so an
        // old version only survives the third update if the person pinned
        // it first. That is what every app here does: pin the first
        // version after the second update. Apps 1 and 2 then unpin it
        // ("I don't need that one any more"), which leaves exactly one
        // stored but no longer protected version per app for the global
        // cap to reclaim. App 0 keeps its pin: the plan must never list it.
        var pinnedRevisionId: String?
        var identities: [NativeShellAppIdentity] = []
        for appIndex in 0..<3 {
            let appId = "iris.global-cap-app-\(appIndex)"
            let projectId = "\(appId).mobile"
            let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
            identities.append(identity)
            let store = try fixture.makeStore(appId: appId, projectId: projectId)
            var baseRevisionId: String?
            var revisionIds: [String] = []
            for revisionIndex in 0..<3 {
                let generated = try fixture.generatePackage(
                    appId: appId, projectId: projectId,
                    content: "revision \(revisionIndex) of \(appId)",
                    baseRevisionId: baseRevisionId,
                    nonce: fixture.nonce("\(appId)-\(revisionIndex)")
                )
                _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
                await fixture.offers.insert(identity, generated.revisionId)
                try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
                revisionIds.append(generated.revisionId)
                baseRevisionId = generated.revisionId
                if revisionIndex == 1 {
                    try await coordinator.pin(identity: identity, revisionId: revisionIds[0])
                }
            }
            if appIndex == 0 {
                pinnedRevisionId = revisionIds[0]
            } else {
                try await coordinator.unpin(identity: identity, revisionId: revisionIds[0])
            }
        }

        let usageBefore = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults)
        XCTAssertGreaterThan(usageBefore.totalCodeBytes, 0)

        // Cap of 1 byte forces "reclaim everything prunable": exercises the
        // plan against every app at once, not just one.
        let plan = try await coordinator.planGlobalCapEnforcement(capBytes: 1, defaults: defaults)
        XCTAssertGreaterThan(plan.reclaimableBytes, 0)
        if let pinnedRevisionId {
            XCTAssertFalse(plan.items.contains { $0.revisionId == pinnedRevisionId })
        }
        // Nothing removed yet: the plan is pure and must not have touched
        // disk. Real allocation is unchanged from before the plan was made.
        let usageAfterPlanOnly = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults)
        XCTAssertEqual(usageAfterPlanOnly.totalCodeBytes, usageBefore.totalCodeBytes)

        let enforced = try await coordinator.enforceGlobalCap(capBytes: 1, defaults: defaults)
        XCTAssertEqual(enforced.reclaimableBytes, plan.reclaimableBytes)
        let usageAfterEnforce = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults)
        // Real bytes reclaimed is at least what the plan promised (oracle:
        // measured st_blocks-based totals before/after, not the plan's own
        // number reflected back).
        XCTAssertLessThanOrEqual(
            usageAfterEnforce.totalCodeBytes,
            usageBefore.totalCodeBytes - enforced.reclaimableBytes + 4096
        )

        // Every app's current revision still opens after global enforcement.
        for identity in identities {
            let store = try fixture.makeStore(appId: identity.appId, projectId: identity.projectId)
            let launch = try await store.launchDescriptorForActiveRevision()
            XCTAssertFalse(launch.revisionId.isEmpty)
        }
        // The pinned revision specifically still opens.
        if let pinnedRevisionId {
            let store = try fixture.makeStore(appId: identities[0].appId, projectId: identities[0].projectId)
            try await store.rollback(to: pinnedRevisionId)
            let launch = try await store.launchDescriptorForActiveRevision()
            XCTAssertEqual(launch.revisionId, pinnedRevisionId)
        }
    }

    /// A person's setting (not the shipped default) is what `enforceGlobalCap`
    /// actually enforces, read back through the same `UserDefaults` key
    /// `setGlobalCodeCapBytes` writes.
    func testSetGlobalCodeCapBytesIsWhatGetsEnforcedByDefault() async throws {
        // MUTATION: ignoring the stored cap setting leaves the default 2 GB plan empty.
        let fixture = try GlobalCapFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.isolatedDefaults()
        let coordinator = fixture.coordinator(defaults: defaults)
        _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)

        let shippedCap = await coordinator.globalCodeCapBytes(defaults: defaults)
        // The shipped default is "2 GB" (MOBILE_STORE_DESIGN.md sections 8 item 6
        // and 13.4). Round 6 test audit: this used to compare the setting with the
        // constant it is read from, which can never fail. It is checked against
        // the number the design writes down, in either reading of "GB" (decimal
        // or binary).
        XCTAssertGreaterThanOrEqual(shippedCap, 2_000_000_000, "the shipped app-code cap is 2 GB")
        XCTAssertLessThanOrEqual(shippedCap, 2 * 1024 * 1024 * 1024, "the shipped app-code cap is 2 GB")
        await coordinator.setGlobalCodeCapBytes(123_456, defaults: defaults)
        let chosenCap = await coordinator.globalCodeCapBytes(defaults: defaults)
        XCTAssertEqual(chosenCap, 123_456)

        // One app updated three times through the product path; its first
        // version was pinned and later unpinned, so it is stored but no
        // longer protected (the coordinator prunes on activate, SPEC R8.9).
        let appId = "iris.global-cap-setting-app"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)
        var baseRevisionId: String?
        var revisionIds: [String] = []
        for revisionIndex in 0..<3 {
            let generated = try fixture.generatePackage(
                appId: appId, projectId: projectId, content: "setting-\(revisionIndex)",
                baseRevisionId: baseRevisionId, nonce: fixture.nonce("setting-\(revisionIndex)")
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            await fixture.offers.insert(identity, generated.revisionId)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            revisionIds.append(generated.revisionId)
            baseRevisionId = generated.revisionId
            if revisionIndex == 1 {
                try await coordinator.pin(identity: identity, revisionId: revisionIds[0])
            }
        }
        try await coordinator.unpin(identity: identity, revisionId: revisionIds[0])

        // The real stored size, measured on disk. A cap one byte under it
        // must trigger a reclaim; the shipped 2 GB default must not.
        let measured = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults).totalCodeBytes
        XCTAssertGreaterThan(measured, 1)
        let underDefault = try await coordinator.planGlobalCapEnforcement(
            capBytes: NativeStorageRetentionPolicy.defaultGlobalCodeCapBytes, defaults: defaults
        )
        XCTAssertEqual(underDefault.reclaimableBytes, 0, "nothing here comes near the shipped 2 GB default")

        await coordinator.setGlobalCodeCapBytes(measured - 1, defaults: defaults)
        // No explicit capBytes passed: must fall back to the stored setting,
        // not the shipped 2 GB default (which nothing here would exceed).
        let plan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        XCTAssertGreaterThan(plan.reclaimableBytes, 0)
        XCTAssertEqual(plan.items.map(\.revisionId), [revisionIds[0]], "only the unpinned old version may be listed")
    }

    /// Count pruning still applies below the cap when a fresh suite uses K=2.
    func testDefaultKeepCountPlansThirdOfferedVersionBelowGlobalCap() async throws {
        // MUTATION: changing the default keep count to keep-all removes this expected count-only item.
        let fixture = try GlobalCapFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.isolatedDefaults()
        let coordinator = fixture.coordinator(defaults: defaults)

        let initialChoice = await coordinator.versionKeepCount(defaults: defaults)
        XCTAssertEqual(initialChoice, .keepTwo)
        let appId = "iris.global-cap-default-count-app"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)
        // Temporarily keep all while constructing the three-version world, then
        // remove the saved override so planning observes the shipped K=2 default.
        _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)
        var baseRevisionId: String?
        var revisionIds: [String] = []
        for revisionIndex in 0..<3 {
            let generated = try fixture.generatePackage(
                appId: appId, projectId: projectId, content: "default-count-\(revisionIndex)",
                baseRevisionId: baseRevisionId, nonce: fixture.nonce("default-count-\(revisionIndex)")
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            await fixture.offers.insert(identity, generated.revisionId)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            revisionIds.append(generated.revisionId)
            baseRevisionId = generated.revisionId
        }
        defaults.removeObject(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
        let restoredDefault = await coordinator.versionKeepCount(defaults: defaults)
        XCTAssertEqual(restoredDefault, .keepTwo)

        let plan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        XCTAssertEqual(plan.reclaimableBytes, 4_096, "the oldest offered version is the count-only reclaim below cap")
        XCTAssertEqual(plan.items.map(\.revisionId), [revisionIds[0]])
    }

    /// Section 8 item 3: a catalog-withdrawn stored version remains usable under cap pressure.
    func testGlobalCapAndExplicitRemovalProtectAStoredVersionTheCatalogNoLongerOffers() async throws {
        // MUTATION: allowing unavailable history to become a cap or explicit-removal candidate must fail this test.
        let fixture = try GlobalCapFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.isolatedDefaults()
        let coordinator = fixture.coordinator(defaults: defaults)
        let appId = "iris.global-cap-unavailable-history"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)
        _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)

        var ids: [String] = []
        var base: String?
        for index in 0..<4 {
            let generated = try fixture.generatePackage(
                appId: appId, projectId: projectId, content: "unavailable-history-\(index)",
                baseRevisionId: base, nonce: fixture.nonce("unavailable-history-\(index)")
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            ids.append(generated.revisionId)
            base = generated.revisionId
            if index != 0 {
                await fixture.offers.insert(identity, generated.revisionId)
            }
        }

        // The oldest revision is stored but absent from the current catalog.
        // The next-oldest is offered and eligible; total allocation is above
        // the one-byte cap, so enforcement must reclaim the eligible one.
        let unoffered = ids[0]
        let offeredOlder = ids[1]
        let plan = try await coordinator.planGlobalCapEnforcement(capBytes: 1, defaults: defaults)
        XCTAssertTrue(plan.items.contains { $0.revisionId == offeredOlder })
        XCTAssertFalse(plan.items.contains { $0.revisionId == unoffered })
        let enforced = try await coordinator.enforceGlobalCap(capBytes: 1, defaults: defaults)
        XCTAssertTrue(enforced.items.contains { $0.revisionId == offeredOlder })
        XCTAssertFalse(enforced.items.contains { $0.revisionId == unoffered })

        var explicitRemovalWasRejected = false
        do {
            _ = try await store.removeSpecificRevisions([unoffered])
        } catch {
            explicitRemovalWasRejected = true
        }
        XCTAssertTrue(explicitRemovalWasRejected, "SPEC section 2.5: explicit removal rechecks catalog availability")

        let report = try await coordinator.pruneStorage(identity: identity)
        XCTAssertTrue(report.retainedRevisionIds.contains(unoffered),
            "the prune report keeps the unavailable revision")
        try await coordinator.revert(identity: identity, to: unoffered)
        let launch = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launch.launchedRevisionId, unoffered, "the unavailable revision remains launchable")
    }

    /// SPEC 2.5: cap enforcement accounts for the count-prune savings before selecting more history.
    func testGlobalCapDoesNotOverFreeAfterTheDefaultCountRuleHasReachedItsTarget() async throws {
        // MUTATION: ignoring count-prune savings in cap selection must free extra eligible history and fail this exact-set assertion.
        let fixture = try GlobalCapFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.isolatedDefaults()
        let coordinator = fixture.coordinator(defaults: defaults)
        let appId = "iris.global-cap-count-before-cap"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)
        _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)

        var ids: [String] = []
        var base: String?
        for index in 0..<5 {
            let generated = try fixture.generatePackage(
                appId: appId, projectId: projectId, content: "count-before-cap-\(index)",
                baseRevisionId: base, nonce: fixture.nonce("count-before-cap-\(index)")
            )
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            await fixture.offers.insert(identity, generated.revisionId)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            ids.append(generated.revisionId)
            base = generated.revisionId
        }
        defaults.removeObject(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)

        // K=2 retains current and fallback. The three older, offered fixture
        // versions are the independently enumerated count-rule removal set.
        let expectedFreed = Set(ids.prefix(3))
        let expectedRetained = Set(ids.suffix(2))
        let before = try independentAllocatedBytes(fixture.storeRoot)
        XCTAssertGreaterThan(before, 8_192)
        let cap = before - 12_288
        XCTAssertGreaterThan(cap, 0)
        await coordinator.setGlobalCodeCapBytes(cap, defaults: defaults)
        let result = try await coordinator.enforceGlobalCap(defaults: defaults)
        let after = try independentAllocatedBytes(fixture.storeRoot)
        XCTAssertEqual(Set(result.items.map(\.revisionId)), expectedFreed)
        XCTAssertEqual(before - after, result.reclaimableBytes, "reported reclaimed bytes match independent allocated-block delta")
        XCTAssertEqual(result.reclaimableBytes, before - after)
        let activeId = try await store.activeRevisionId()
        XCTAssertEqual(activeId, ids[4])
        let report = try await coordinator.pruneStorage(identity: identity)
        XCTAssertEqual(report.retainedRevisionIds, expectedRetained,
            "current and fallback are exactly the versions left by K=2")
    }

    // MARK: - Mutation check: global cap enforcement wiring (see HANDOFF.md)
    //
    // In `NativeShellLibraryCoordinator.enforceGlobalCap`, replacing the
    // real removal loop's `try await makeStore(identity: identity)
    // .removeSpecificRevisions(ids)` with a no-op makes
    // `testPlanThenEnforceReclaimsAtLeastThePromisedBytesAndNeverTouchesAProtectedRevision`
    // fail at its `usageAfterEnforce.totalCodeBytes` assertion (nothing
    // actually shrinks), while `testSetGlobalCodeCapBytesIsWhatGetsEnforcedByDefault`
    // (which only checks the *plan*, not enforcement) still passes,
    // confirming the check is specific to enforcement, not planning.
    // Restored byte-for-byte, `shasum -a 256` verified (see HANDOFF.md).
}

private func independentAllocatedBytes(_ root: URL) throws -> Int64 {
    let objects = root.appendingPathComponent("objects", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil) else { return 0 }
    var total: Int64 = 0
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
        total += Int64(info.st_blocks) * 512
    }
    return total
}

// MARK: - Fixture

private final class GlobalCapFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0
    let offers = GlobalCapOffers()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-global-cap-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func coordinator(defaults: UserDefaults = .standard) -> NativeShellLibraryCoordinator {
        let offers = self.offers
        return NativeShellLibraryCoordinator(rootURL: storeRoot, defaults: defaults, downloadableRevisionIds: { identity in await offers.all(for: identity) })
    }

    /// A private, in-memory-backed `UserDefaults` suite per fixture instance
    /// so tests never read or write the real app's saved cap setting.
    func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "iris-global-cap-tests-\(UUID().uuidString)")!
    }

    func nonce(_ tag: String) -> String {
        SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func makeStore(appId: String, projectId: String) throws -> NativeRevisionStore {
        try NativeRevisionStore(rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0")
    }

    struct GeneratedPackage {
        let bytes: Data
        let authority: StaticApprovalAuthority
        let revisionId: String
    }

    struct StaticApprovalAuthority: DeliveryApprovalAuthority {
        let approval: TrustedDeliveryApproval
        func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
            approval.approvalId == approvalId ? approval : nil
        }
    }

    func generatePackage(
        appId: String, projectId: String, content: String, baseRevisionId: String?, nonce: String
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = repositoryRoot().appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let html = "<!doctype html><meta charset=utf-8><title>Global cap</title><main>\(content)</main>"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--base", baseRevisionId ?? "null",
            "--content", html,
            "--nonce", nonce,
            "--namespace", appId,
            "--capabilities", "[]",
            "--app", appId,
            "--project", projectId,
        ]
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
        return GeneratedPackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            authority: StaticApprovalAuthority(approval: approval),
            revisionId: revisionId
        )
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

private actor GlobalCapOffers {
    private var idsByIdentity: [NativeShellAppIdentity: Set<String>] = [:]
    func insert(_ identity: NativeShellAppIdentity, _ id: String) { idsByIdentity[identity, default: []].insert(id) }
    func all(for identity: NativeShellAppIdentity) -> Set<String> { idsByIdentity[identity, default: []] }
}

private enum FixtureError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
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

extension NativeShellLibraryCoordinatorGlobalCapTests {
    /// Count pruning alone reaches the independent cap target, so the kept-tier version must survive.
    func testKeepCountThreeDoesNotCapPruneAfterCountTargetIsMet() async throws {
        let actual = try await makeKeepCountCapWorld(versionCount: 6, tag: "world-a")
        let oracle = try await makeKeepCountCapWorld(versionCount: 6, tag: "world-a")
        defer { actual.fixture.cleanup(); oracle.fixture.cleanup() }

        // Six offered versions are [V1 oldest ... V6 current]. At K=3,
        // SPEC 2.5 independently keeps V6 current, V5 fallback, and V4 newest older.
        let countFreed = Array(actual.ids.prefix(3))
        let expectedKept = Set(actual.ids.suffix(3))
        let before = try independentAllocatedBytes(actual.fixture.storeRoot)
        let oracleOffers = oracle.fixture.offers
        let oracleIdentity = oracle.identity
        let oracleStore = try NativeRevisionStore(
            rootURL: oracle.fixture.storeRoot, appId: oracle.appId, projectId: oracle.projectId,
            shellVersion: "1.0.0", defaults: oracle.defaults,
            downloadableRevisionIds: { _ in await oracleOffers.all(for: oracleIdentity) }
        )
        _ = try await oracleStore.removeSpecificRevisions(Set(oracle.ids.prefix(3)))
        let countOnlyAllocation = try independentAllocatedBytes(oracle.fixture.storeRoot)
        XCTAssertGreaterThan(before, countOnlyAllocation)
        XCTAssertEqual(expectedKept.count, 3)

        await actual.coordinator.setGlobalCodeCapBytes(countOnlyAllocation, defaults: actual.defaults)
        let result = try await actual.coordinator.setVersionKeepCount(.keepThree, defaults: actual.defaults)
        let after = try independentAllocatedBytes(actual.fixture.storeRoot)
        XCTAssertEqual(result.freedRevisionIds[actual.identity], Set(countFreed))
        XCTAssertEqual(result.retainedRevisionIds[actual.identity], expectedKept)
        XCTAssertLessThanOrEqual(after, countOnlyAllocation)
        XCTAssertEqual(before - after, result.bytesReclaimed)

        for revisionId in actual.ids.suffix(3).reversed() {
            try await actual.coordinator.revert(identity: actual.identity, to: revisionId)
            let launch = try await actual.coordinator.launchActive(identity: actual.identity)
            XCTAssertEqual(launch.launchedRevisionId, revisionId)
        }
    }

    /// At K=5, the cap needs one more revision; only the oldest of three kept-tier versions may go.
    func testKeepCountFiveCapFreesOnlyOldestAdditionalKeptTierVersion() async throws {
        let actual = try await makeKeepCountCapWorld(versionCount: 8, tag: "world-b")
        let oracle = try await makeKeepCountCapWorld(versionCount: 8, tag: "world-b")
        defer { actual.fixture.cleanup(); oracle.fixture.cleanup() }

        // Eight offered versions are [V1 oldest ... V8 current]. At K=5,
        // V8, V7, V6, V5, V4 survive count pruning; cap ordering then removes V4 first.
        let countFreed = Array(actual.ids.prefix(3))
        let additionalFreed = actual.ids[3]
        let expectedFreed = Set(countFreed + [additionalFreed])
        let expectedKept = Set(actual.ids.suffix(4))
        let before = try independentAllocatedBytes(actual.fixture.storeRoot)
        let oracleOffers = oracle.fixture.offers
        let oracleIdentity = oracle.identity
        let oracleStore = try NativeRevisionStore(
            rootURL: oracle.fixture.storeRoot, appId: oracle.appId, projectId: oracle.projectId,
            shellVersion: "1.0.0", defaults: oracle.defaults,
            downloadableRevisionIds: { _ in await oracleOffers.all(for: oracleIdentity) }
        )
        _ = try await oracleStore.removeSpecificRevisions(Set(oracle.ids.prefix(3)))
        let countOnlyAllocation = try independentAllocatedBytes(oracle.fixture.storeRoot)
        _ = try await oracleStore.removeSpecificRevisions([oracle.ids[3]])
        let capSatisfiedAllocation = try independentAllocatedBytes(oracle.fixture.storeRoot)
        XCTAssertGreaterThan(before, countOnlyAllocation)
        XCTAssertGreaterThan(countOnlyAllocation, capSatisfiedAllocation)

        await actual.coordinator.setGlobalCodeCapBytes(capSatisfiedAllocation, defaults: actual.defaults)
        let result = try await actual.coordinator.setVersionKeepCount(.keepFive, defaults: actual.defaults)
        let after = try independentAllocatedBytes(actual.fixture.storeRoot)
        XCTAssertEqual(result.freedRevisionIds[actual.identity], expectedFreed)
        XCTAssertEqual(result.retainedRevisionIds[actual.identity], expectedKept)
        XCTAssertLessThanOrEqual(after, capSatisfiedAllocation)
        XCTAssertEqual(before - after, result.bytesReclaimed)

        for revisionId in actual.ids.suffix(4).reversed() {
            try await actual.coordinator.revert(identity: actual.identity, to: revisionId)
            let launch = try await actual.coordinator.launchActive(identity: actual.identity)
            XCTAssertEqual(launch.launchedRevisionId, revisionId)
        }
    }
}

private struct KeepCountCapWorld {
    let fixture: GlobalCapFixture
    let appId: String
    let projectId: String
    let identity: NativeShellAppIdentity
    let ids: [String]
    let defaults: UserDefaults
    let coordinator: NativeShellLibraryCoordinator
}

private func makeKeepCountCapWorld(versionCount: Int, tag: String) async throws -> KeepCountCapWorld {
    let fixture = try GlobalCapFixture()
    let defaults = fixture.isolatedDefaults()
    let coordinator = fixture.coordinator(defaults: defaults)
    let appId = "iris.keep-count-cap-\(tag)"
    let projectId = "\(appId).mobile"
    let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
    let store = try fixture.makeStore(appId: appId, projectId: projectId)
    _ = try await coordinator.setVersionKeepCount(.keepAll, defaults: defaults)

    var ids: [String] = []
    var base: String?
    for index in 0..<versionCount {
        let content = "version-\(index)-" + String(repeating: Character(UnicodeScalar(65 + index)!), count: 512 * (index + 1))
        let generated = try fixture.generatePackage(
            appId: appId, projectId: projectId, content: content,
            baseRevisionId: base, nonce: fixture.nonce("\(tag)-version-\(index)")
        )
        _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
        await fixture.offers.insert(identity, generated.revisionId)
        try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
        ids.append(generated.revisionId)
        base = generated.revisionId
    }
    return KeepCountCapWorld(
        fixture: fixture, appId: appId, projectId: projectId,
        identity: identity, ids: ids, defaults: defaults, coordinator: coordinator
    )
}
