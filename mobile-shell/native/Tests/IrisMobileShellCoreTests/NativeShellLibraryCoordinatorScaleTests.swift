import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Scale cases for the Library/Storage screens (SPEC.md R8.10: "At 100
/// installed apps x 5 revisions the Library and Storage screens open in
/// under 500 ms (measured in SwiftPM with a synthetic store)"). Builds a
/// real, on-disk synthetic store (real staged/activated revisions through
/// the actual `NativeRevisionStore`/`NativeShellLibraryCoordinator` code
/// path, small fabricated content, not a mock) and times the exact call
/// the Host's Library/Storage screens make:
/// `NativeShellLibraryCoordinator.globalStorageUsage()`.
///
/// Each package is generated, consumed, and released inside one app iteration.
final class NativeShellLibraryCoordinatorScaleTests: XCTestCase {
    func testLibraryAndStorageScreensOpenUnderFiveHundredMillisecondsAtOneHundredAppsTimesFiveRevisions() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let appCount = 100
        let revisionsPerApp = 5
        // Stream one app and one small signed package at a time. Only this
        // app's five revision IDs and the current base ID remain live. Expected
        // resident memory is under 1.5 GB and setup is expected under 60 seconds.
        // MUTATION: omitting a revision stage makes the independent per-app count oracle fail.
        for appIndex in 0..<appCount {
            let appId = "iris.scale-app-\(appIndex)"
            let projectId = "\(appId).mobile"
            let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
            let store = try fixture.makeStore(appId: appId, projectId: projectId)
            var baseRevisionId: String?
            var revisionIds: [String] = []
            for revisionIndex in 0..<revisionsPerApp {
                let generated = try fixture.generatePackage(
                    appId: appId, projectId: projectId, content: "r\(revisionIndex)",
                    baseRevisionId: baseRevisionId, nonce: fixture.nonce("\(appId)-\(revisionIndex)")
                )
                _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
                revisionIds.append(generated.revisionId)
                baseRevisionId = generated.revisionId
                if revisionIndex == revisionsPerApp - 1 { break } // pending update
                try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
                if revisionIndex == 1 || revisionIndex == 2 {
                    try await coordinator.pin(identity: identity, revisionId: revisionIds[revisionIndex - 1])
                }
            }
        }

        // The timed operation: exactly what the Host's Library/Storage
        // screens call to render per-app bars and the cross-app total.
        let clock = ContinuousClock()
        let start = clock.now
        let usage = try await coordinator.globalStorageUsage()
        let elapsed = start.duration(to: clock.now)

        XCTAssertEqual(usage.perApp.count, appCount)
        for appUsage in usage.perApp {
            XCTAssertEqual(appUsage.storedRevisionCount, min(revisionsPerApp, 5 /* R8.9: at most 5 revisions per app */))
        }

        let elapsedMillis = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        // Printed (not just asserted) so HANDOFF.md can quote the real
        // measured number, per this unit's acceptance criteria.
        print("NativeShellLibraryCoordinatorScaleTests: globalStorageUsage() at \(appCount) apps x \(revisionsPerApp) revisions took \(elapsedMillis) ms")
        XCTAssertLessThan(elapsedMillis, 500, "Library/Storage read at 100 apps x 5 revisions must open in under 500 ms")
    }

    /// "1,000 apps as a stress case for the index only" (this unit's brief):
    /// exercises app-count scale specifically (identity discovery and one
    /// store per app), not full revision-history depth per app, so this
    /// stays a distinct, cheaper case from the 100x5 timing case above
    /// rather than a 5x-more-expensive repeat of it. No strict millisecond
    /// bound is asserted here (SPEC.md's quoted number is for the 100x5
    /// case only); this proves the read path completes and returns correct
    /// counts at 10x the app count, and reports its own timing for the
    /// record.
    func testLibraryIndexStaysCorrectAndCompletesAtOneThousandInstalledAppsStressCase() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let appCount = 1_000
        for appIndex in 0..<appCount {
            try await fixture.installStressApp(index: appIndex, coordinator: coordinator)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let usage = try await coordinator.globalStorageUsage()
        let elapsed = start.duration(to: clock.now)
        let elapsedMillis = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        print("NativeShellLibraryCoordinatorScaleTests: globalStorageUsage() at \(appCount) apps (index stress) took \(elapsedMillis) ms")

        XCTAssertEqual(usage.perApp.count, appCount)
        XCTAssertEqual(Set(usage.perApp.map(\.identity)).count, appCount, "every installed app must be counted exactly once")
    }
}

// MARK: - Fixture

private final class ScaleFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-scale-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    // The 1,000-app world is streamed one tiny package at a time, without
    // accumulated package bytes, strings, decoded objects, or revision arrays.
    // Expected resident memory is under 1.5 GB and setup plus index read under 60 seconds.
    // MUTATION: skipping an app install makes the independent unique identity count fail.
    func installStressApp(index: Int, coordinator: NativeShellLibraryCoordinator) async throws {
        let appId = "iris.stress-app-\(index)"
        let projectId = "\(appId).mobile"
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let store = try makeStore(appId: appId, projectId: projectId)
        let generated = try generatePackage(appId: appId, projectId: projectId, content: "tiny",
                                            baseRevisionId: nil, nonce: nonce(appId))
        _ = try await store.stage(packageBytes: generated.bytes, approvalAuthority: generated.authority)
        try await coordinator.activate(identity: identity, revisionId: generated.revisionId)
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
        let html = "<!doctype html><meta charset=utf-8><title>Scale</title><main>\(content)</main>"

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
