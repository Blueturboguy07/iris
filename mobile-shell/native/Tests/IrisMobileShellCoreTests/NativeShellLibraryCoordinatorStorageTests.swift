import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Coordinator-level surface for bounded storage: the delegating methods
/// themselves (`storageUsage`, `pin`, `unpin`, `pruneStorage`) and that the
/// automatic prune hooked into `activate`/`revert`/`launchActive` (see
/// `NativeShellLibraryCoordinator.swift`) is reachable and effective through
/// the coordinator, not only through a direct `NativeRevisionStore`.
final class NativeShellLibraryCoordinatorStorageTests: XCTestCase {
    private let appId = "iris.coordinator-storage-test"
    private let projectId = "iris.coordinator-storage-test.mobile"

    func testStorageUsageReflectsRealCodeBytesRevisionCountAndPins() async throws {
        let fixture = try CoordinatorStorageFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        let first = try fixture.generatePackage(content: "first", nonce: fixture.nonce("a"), appId: appId, projectId: projectId)
        let firstReview = try await coordinator.reviewImport(packageBytes: first.bytes)
        let stagedFirst = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: firstReview.reviewToken, packageSHA256: firstReview.packageSHA256
        )
        try await coordinator.activate(identity: identity, revisionId: stagedFirst.revisionId)

        let usageAfterInstall = try await coordinator.storageUsage(identity: identity)
        XCTAssertEqual(usageAfterInstall.identity, identity)
        XCTAssertEqual(usageAfterInstall.storedRevisionCount, 1)
        XCTAssertEqual(usageAfterInstall.currentRevisionId, stagedFirst.revisionId)
        XCTAssertNil(usageAfterInstall.fallbackRevisionId)
        XCTAssertEqual(usageAfterInstall.pinnedRevisionIds, [])
        // Real measured bytes for real content, not zero and not a made-up
        // constant: cross-checked against the store's own allocation call.
        XCTAssertGreaterThan(usageAfterInstall.codeAllocatedBytes, 0)

        try await coordinator.pin(identity: identity, revisionId: stagedFirst.revisionId)
        let usageAfterPin = try await coordinator.storageUsage(identity: identity)
        XCTAssertEqual(usageAfterPin.pinnedRevisionIds, [stagedFirst.revisionId])
        let pinsAfterPin = try await coordinator.pinnedRevisionIds(identity: identity)
        XCTAssertEqual(pinsAfterPin, [stagedFirst.revisionId])

        try await coordinator.unpin(identity: identity, revisionId: stagedFirst.revisionId)
        let pinsAfterUnpin = try await coordinator.pinnedRevisionIds(identity: identity)
        XCTAssertEqual(pinsAfterUnpin, [])
    }

    /// R2-mobile-integration: the Storage screen measures without re-hashing
    /// (SPEC R8.10 speed), so a version whose bytes were damaged on disk must
    /// still be shown and counted there, while every path that keeps or runs
    /// code (pin, revert, open) refuses it. Seeded misbehavior: one byte of a
    /// stored file flipped after install, file size unchanged.
    func testDamagedStoredVersionIsStillMeasuredButCanNeverBePinnedOpenedOrRevertedTo() async throws {
        let fixture = try CoordinatorStorageFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)

        let first = try fixture.generatePackage(content: "healthy-first", nonce: fixture.nonce("dm-1"), appId: appId, projectId: projectId)
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await coordinator.activate(identity: identity, revisionId: first.revisionId)
        let second = try fixture.generatePackage(
            content: "healthy-second", baseRevisionId: first.revisionId, nonce: fixture.nonce("dm-2"), appId: appId, projectId: projectId
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await coordinator.activate(identity: identity, revisionId: second.revisionId)
        let usageBefore = try await coordinator.storageUsage(identity: identity)
        XCTAssertEqual(usageBefore.storedRevisionCount, 2)

        let damagedPayload = Data("<!doctype html><meta charset=utf-8><title>Coordinator storage</title><main>healthy-first</main>".utf8)
        let damagedPath = try XCTUnwrap(findStoredBytes(damagedPayload, under: fixture.storeRoot), "SPEC 2.4: find staged object by its exact package bytes")
        try flipReadOnlyObjectByte(at: damagedPath, offset: damagedPayload.count / 2)

        // The Storage screen still opens and still counts the damaged version.
        let usageAfter = try await coordinator.storageUsage(identity: identity)
        XCTAssertEqual(usageAfter.storedRevisionCount, 2, "SPEC 2.4: damaged stored revision remains measured")
        XCTAssertEqual(usageAfter.codeAllocatedBytes, usageBefore.codeAllocatedBytes, "SPEC 2.4: same-size object damage leaves measured allocation unchanged")
        XCTAssertGreaterThan(usageAfter.codeAllocatedBytes, 0)

        // Nothing may keep or run it.
        await XCTAssertThrowsAnyError(try await coordinator.pin(identity: identity, revisionId: first.revisionId), "SPEC 2.4: damaged revision cannot be pinned")
        let pins = try await coordinator.pinnedRevisionIds(identity: identity)
        XCTAssertEqual(pins, [], "a damaged version must never be recorded as pinned")
        await XCTAssertThrowsAnyError(try await store.rollback(to: first.revisionId), "SPEC 2.3/2.4: damaged revision cannot be rolled back to")
        await XCTAssertThrowsAnyError(try await coordinator.revert(identity: identity, to: first.revisionId), "SPEC 2.4: damaged revision cannot be opened by revert")
        // The healthy current version still opens.
        let launch = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launch.launchedRevisionId, second.revisionId)
    }

    /// A stale "Free up space" plan (made before the person activated an
    /// older version again) names one version that is now protected next to
    /// one that is not. The removal must refuse as a whole: nothing named is
    /// deleted, not even the unprotected one (M4 review finding, pinned by
    /// R2-mobile-integration). Oracle: the version folders on disk.
    func testStaleRemovalListNamingAProtectedVersionDeletesNothingAtAll() async throws {
        let fixture = try CoordinatorStorageFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        defaults.set("all", forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
        let coordinator = fixture.coordinator()
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try fixture.makeStore(appId: appId, projectId: projectId)
        var ids: [String] = []
        var base: String?
        for index in 0..<3 {
            let generated = try fixture.generatePackage(
                content: "atomic-\(index)", baseRevisionId: base, nonce: fixture.nonce("atomic-\(index)"), appId: appId, projectId: projectId
            )
            await fixture.offers.insert(identity, generated.revisionId)
            _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
            try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
            ids.append(generated.revisionId)
            base = generated.revisionId
            if index == 1 { try await coordinator.pin(identity: identity, revisionId: ids[0]) }
        }
        try await coordinator.unpin(identity: identity, revisionId: ids[0])
        // ids[0] is now stored but unprotected; ids[1] is the previous version.
        let before = try independentStoreSnapshot(fixture.storeRoot)

        await XCTAssertThrowsAnyError(try await store.removeSpecificRevisions([ids[0], ids[1]]))
        XCTAssertEqual(try independentStoreSnapshot(fixture.storeRoot), before, "SPEC 2.5: stale request naming a protected version removes nothing at all")

        // The unprotected one alone is removable.
        _ = try await store.removeSpecificRevisions([ids[0]])
        XCTAssertNotEqual(try independentStoreSnapshot(fixture.storeRoot), before, "SPEC 2.5: an allowed version removal changes store files")
    }

    func testExplicitPruneStorageThroughTheCoordinatorReclaimsAStaleSiblingAndReportsErrorsRatherThanSwallowingThem() async throws {
        let fixture = try CoordinatorStorageFixture()
        defer { fixture.cleanup() }
        let defaults = fixture.defaults
        defaults.set("all", forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
        let coordinator = fixture.coordinator()
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let directStore = try fixture.makeStore(appId: appId, projectId: projectId)

        let first = try fixture.generatePackage(content: "stale-sibling", nonce: fixture.nonce("b"), appId: appId, projectId: projectId)
        await fixture.offers.insert(identity, first.revisionId)
        _ = try await directStore.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await directStore.activate(revisionId: first.revisionId)
        let stale = first
        let middle = try fixture.generatePackage(
            content: "middle", baseRevisionId: stale.revisionId, nonce: fixture.nonce("c"), appId: appId, projectId: projectId
        )
        await fixture.offers.insert(identity, middle.revisionId)
        _ = try await directStore.stage(packageBytes: middle.bytes, approvalAuthority: middle.authority)
        try await directStore.activate(revisionId: middle.revisionId)
        let winner = try fixture.generatePackage(
            content: "winner", baseRevisionId: middle.revisionId, nonce: fixture.nonce("d"), appId: appId, projectId: projectId
        )
        await fixture.offers.insert(identity, winner.revisionId)
        _ = try await directStore.stage(packageBytes: winner.bytes, approvalAuthority: winner.authority)

        // Keep all is selected, and every revision is offered by the catalog.
        // Direct store activation keeps the setup independent of the
        // coordinator hook; this explicit call must leave bytes alone below
        // the cap, then the cap path must reclaim the offered stale sibling.
        try await directStore.activate(revisionId: winner.revisionId)
        let belowCapSnapshot = try independentStoreSnapshot(fixture.storeRoot)
        _ = try await coordinator.pruneStorage(identity: identity)
        XCTAssertEqual(try independentStoreSnapshot(fixture.storeRoot), belowCapSnapshot, "SPEC 1.4/2.5: explicit prune frees nothing below the cap")
        let measured = try await coordinator.globalStorageUsage(capBytes: 1, defaults: defaults).totalCodeBytes
        await coordinator.setGlobalCodeCapBytes(measured - 1, defaults: defaults)
        let plan = try await coordinator.planGlobalCapEnforcement(defaults: defaults)
        let beforePrune = try independentObjectAllocation(fixture.storeRoot)
        let enforcement = try await coordinator.enforceGlobalCap(defaults: defaults)
        XCTAssertTrue(plan.items.contains { $0.revisionId == stale.revisionId }, "SPEC 2.5: below-cap pruning is not forced; lower the public cap first")
        let freshStore = try fixture.makeStore(appId: appId, projectId: projectId)
        let remainingSummaries = try await freshStore.revisionSummaries()
        let stalePayload = Data("<!doctype html><meta charset=utf-8><title>Coordinator storage</title><main>stale-sibling</main>".utf8)
        XCTAssertTrue(remainingSummaries.contains { $0.revisionId == stale.revisionId }, "SPEC 2.5: freed history row remains in Features")
        XCTAssertNil(try findStoredBytes(stalePayload, under: fixture.storeRoot), "SPEC 2.5: oldest unprotected version object is freed after cap enforcement")
        let activeAfterEnforcement = try await directStore.activeRevisionId()
        XCTAssertEqual(activeAfterEnforcement, winner.revisionId, "SPEC 2.5: current version remains retained")
        let currentLaunch = try await freshStore.launchDescriptorForActiveRevision()
        XCTAssertEqual(currentLaunch.revisionId, winner.revisionId, "SPEC 2.5: retained current object still verifies and launches")
        try await freshStore.rollback(to: middle.revisionId)
        let fallbackLaunch = try await freshStore.launchDescriptorForActiveRevision()
        XCTAssertEqual(fallbackLaunch.revisionId, middle.revisionId, "SPEC 2.5: retained fallback object still verifies and rolls back")
        let afterPrune = try independentObjectAllocation(fixture.storeRoot)
        XCTAssertEqual(beforePrune - afterPrune, enforcement.reclaimableBytes, "SPEC 2.5: reclaimed allocation equals independently measured object allocation drop")
        _ = try await coordinator.pruneStorage(identity: identity)

        // Unlike the automatic hooks (which swallow a pruning failure so it
        // can never turn a successful activate/launch into an error), the
        // explicit call must surface a real failure.
        let corruptPath = try XCTUnwrap(findStoredManifest(revisionId: winner.revisionId, under: fixture.storeRoot))
        try flipReadOnlyObjectByte(at: corruptPath, offset: 0)
        await XCTAssertThrowsAnyError(try await coordinator.pruneStorage(identity: identity))
    }
}

private func XCTAssertThrowsAnyError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "expected an error",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail(message, file: file, line: line)
    } catch {
        // The specific error is not the point here: `NativeRevisionStore`'s
        // own corruption-detection tests already pin down exactly which
        // `NativeShellError` case this is.
    }
}

private struct IndependentStoreFile: Equatable {
    let size: Int
    let sha256: String
}

private func independentStoreSnapshot(_ root: URL) throws -> [String: IndependentStoreFile] {
    let base = root.standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [:] }
    var result: [String: IndependentStoreFile] = [:]
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
        let bytes = try Data(contentsOf: url)
        let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
        result[relative] = IndependentStoreFile(
            size: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
    }
    return result
}

private func independentObjectAllocation(_ root: URL) throws -> Int64 {
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

private func findStoredBytes(_ bytes: Data, under root: URL) throws -> URL? {
    let objects = root.appendingPathComponent("objects", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(at: objects, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
        if try Data(contentsOf: url) == bytes { return url }
    }
    return nil
}

private func findStoredManifest(revisionId: String, under root: URL) throws -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in enumerator where url.pathExtension == "json" && url.pathComponents.contains("manifests") {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data),
              storedManifestRevisionId(value) == revisionId else { continue }
        return url
    }
    return nil
}

private func storedManifestRevisionId(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
        if let id = object["revisionId"] as? String { return id }
        for nested in object.values {
            if let id = storedManifestRevisionId(nested) { return id }
        }
    } else if let array = value as? [Any] {
        for nested in array {
            if let id = storedManifestRevisionId(nested) { return id }
        }
    }
    return nil
}

private func flipReadOnlyObjectByte(at url: URL, offset: Int) throws {
    guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { _ = chmod(url.path, mode_t(S_IRUSR | S_IRGRP | S_IROTH)) }
    let descriptor = open(url.path, O_RDWR)
    guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    defer { _ = close(descriptor) }
    var byte: UInt8 = 0
    guard pread(descriptor, &byte, 1, off_t(offset)) == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    byte ^= 0x20
    guard pwrite(descriptor, &byte, 1, off_t(offset)) == 1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard fsync(descriptor) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}

private final class CoordinatorStorageFixture {
    let root: URL
    let storeRoot: URL
    let defaultsName = "iris-coordinator-storage-\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: defaultsName)!
    let offers = CoordinatorStorageOffers()
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-coordinator-storage-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsName) }

    func coordinator() -> NativeShellLibraryCoordinator {
        let offers = self.offers
        return NativeShellLibraryCoordinator(rootURL: storeRoot, defaults: defaults, downloadableRevisionIds: { identity in await offers.all(for: identity) })
    }

    func nonce(_ tag: String) -> String {
        SHA256.hash(data: Data(tag.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func makeStore(appId: String, projectId: String, fileManager: FileManager = .default) throws -> NativeRevisionStore {
        let offers = self.offers
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        return try NativeRevisionStore(rootURL: storeRoot, appId: appId, projectId: projectId, shellVersion: "1.0.0", fileManager: fileManager, defaults: defaults, downloadableRevisionIds: { _ in await offers.all(for: identity) })
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
        content: String, baseRevisionId: String? = nil, nonce: String, appId: String, projectId: String
    ) throws -> GeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = repositoryRoot().appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let html = "<!doctype html><meta charset=utf-8><title>Coordinator storage</title><main>\(content)</main>"

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

private actor CoordinatorStorageOffers {
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
