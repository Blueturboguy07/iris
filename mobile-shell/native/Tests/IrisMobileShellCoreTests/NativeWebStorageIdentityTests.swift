import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeWebStorageIdentityTests: XCTestCase {
    func testIdentityIsDeterministicLengthPrefixedAndScoped() throws {
        let identity = try NativeWebStorageIdentity(
            appId: "publik.alpha",
            projectId: "publik.alpha.mobile",
            dataNamespace: "shared"
        )
        let repeated = try NativeWebStorageIdentity(
            appId: "publik.alpha",
            projectId: "publik.alpha.mobile",
            dataNamespace: "shared"
        )
        XCTAssertEqual(identity, repeated)
        XCTAssertEqual(
            identity.identifier.uuidString.lowercased(),
            "5a3bb06e-a204-8d65-bffd-d440c7986a87"
        )
        XCTAssertNotEqual(
            identity,
            try NativeWebStorageIdentity(
                appId: "publik.beta",
                projectId: "publik.alpha.mobile",
                dataNamespace: "shared"
            )
        )
        XCTAssertNotEqual(
            identity,
            try NativeWebStorageIdentity(
                appId: "publik.alpha",
                projectId: "publik.beta.mobile",
                dataNamespace: "shared"
            )
        )
        XCTAssertNotEqual(
            identity,
            try NativeWebStorageIdentity(
                appId: "publik.alpha",
                projectId: "publik.alpha.mobile",
                dataNamespace: "other"
            )
        )

        // Concatenating these tuples without lengths would produce the same
        // bytes. Length-prefixing keeps them distinct.
        let ambiguousA = try NativeWebStorageIdentity(
            appId: "ab",
            projectId: "c",
            dataNamespace: "d"
        )
        let ambiguousB = try NativeWebStorageIdentity(
            appId: "a",
            projectId: "bc",
            dataNamespace: "d"
        )
        XCTAssertNotEqual(ambiguousA, ambiguousB)
        XCTAssertNotEqual(
            identity.identifier,
            UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        )
    }

    func testVerifiedStorageLaunchKeepsIdentityAcrossApprovedRevisions() async throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let policy = CapabilityPolicy(supportedCapabilities: ["web.storage"])
        let store = try fixture.makeStore(policy: policy)

        let first = try fixture.generatePackage(
            content: storageHTML("first"),
            baseRevisionId: nil,
            nonce: storageNonce("a"),
            namespace: "publik.storage",
            capabilities: ["web.storage"]
        )
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let firstLaunch = try await store.launchDescriptorForActiveRevision()
        let firstIdentity = try XCTUnwrap(firstLaunch.webStorageIdentity)

        let second = try fixture.generatePackage(
            content: storageHTML("second"),
            baseRevisionId: first.revisionId,
            nonce: storageNonce("b"),
            namespace: "publik.storage",
            capabilities: ["web.storage"]
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)
        let secondLaunch = try await store.launchDescriptorForActiveRevision()
        let secondIdentity = try XCTUnwrap(secondLaunch.webStorageIdentity)

        XCTAssertNotEqual(firstLaunch.revisionId, secondLaunch.revisionId)
        XCTAssertEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(
            firstIdentity,
            try NativeWebStorageIdentity(
                appId: fixture.appId,
                projectId: fixture.projectId,
                dataNamespace: "publik.storage"
            )
        )
    }

    func testNoStorageLaunchHasNoIdentityAndDefaultDenyAllRejectsStorage() async throws {
        do {
            let fixture = try StorageFixture()
            defer { fixture.cleanup() }
            let store = try fixture.makeStore(policy: .denyAll)
            let package = try fixture.generatePackage(
                content: storageHTML("plain"),
                baseRevisionId: nil,
                nonce: storageNonce("c"),
                namespace: "publik.plain",
                capabilities: []
            )
            _ = try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority)
            try await store.activate(revisionId: package.revisionId)
            let launch = try await store.launchDescriptorForActiveRevision()
            XCTAssertNil(launch.webStorageIdentity)
        }

        do {
            let fixture = try StorageFixture()
            defer { fixture.cleanup() }
            let store = try fixture.makeStore(policy: .denyAll)
            let package = try fixture.generatePackage(
                content: storageHTML("storage-denied"),
                baseRevisionId: nil,
                nonce: storageNonce("d"),
                namespace: "publik.storage",
                capabilities: ["web.storage"]
            )
            await XCTAssertThrowsStorageNativeError(
                try await store.stage(packageBytes: package.bytes, approvalAuthority: package.authority),
                equals: .unsupportedCapabilities(["web.storage"])
            )
        }
    }

    func testTamperedStoredManifestCannotSelectAnotherStorageIdentity() async throws {
        let fixture = try StorageFixture()
        defer { fixture.cleanup() }
        let store = try fixture.makeStore(
            policy: CapabilityPolicy(supportedCapabilities: ["web.storage"])
        )

        let first = try fixture.generatePackage(
            content: storageHTML("known-good"),
            baseRevisionId: nil,
            nonce: storageNonce("e"),
            namespace: "publik.storage",
            capabilities: ["web.storage"]
        )
        _ = try await store.stage(packageBytes: first.bytes, approvalAuthority: first.authority)
        try await store.activate(revisionId: first.revisionId)
        let knownGoodLaunch = try await store.launchDescriptorForActiveRevision()
        let knownGoodIdentity = try XCTUnwrap(knownGoodLaunch.webStorageIdentity)

        let second = try fixture.generatePackage(
            content: storageHTML("candidate"),
            baseRevisionId: first.revisionId,
            nonce: storageNonce("f"),
            namespace: "publik.storage",
            capabilities: ["web.storage"]
        )
        _ = try await store.stage(packageBytes: second.bytes, approvalAuthority: second.authority)
        try await store.activate(revisionId: second.revisionId)

        let manifestURL = try XCTUnwrap(findManifestJSON(for: second.revisionId, under: fixture.storeRoot), "SPEC 2.4: locate stored manifest by its revision content")
        var manifestJSON = try storageJSONObject(Data(contentsOf: manifestURL))
        XCTAssertTrue(replaceStorageNamespace(in: &manifestJSON), "SPEC 2.4: tamper the namespace field discovered in the stored manifest")
        try JSONSerialization.data(withJSONObject: manifestJSON, options: [.sortedKeys]).write(to: manifestURL)

        if let launchAfterTamper = try? await store.launchDescriptorForActiveRevision() {
            XCTAssertTrue([first.revisionId, second.revisionId].contains(launchAfterTamper.revisionId), "SPEC 2.4: launch stays within the known revision chain")
            XCTAssertEqual(launchAfterTamper.webStorageIdentity, knownGoodIdentity, "SPEC 2.1: launch can only retain the original app storage identity")
            let activeAfterTamper = try await store.activeRevisionId()
            XCTAssertEqual(activeAfterTamper, launchAfterTamper.revisionId)
        }
    }
}

private struct StorageGeneratedPackage {
    let bytes: Data
    let authority: StorageApprovalAuthority
    let revisionId: String
}

private struct StorageApprovalAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private final class StorageFixture {
    let appId = "publik.storage-test"
    let projectId = "publik.storage-test.mobile"
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-web-storage-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeStore(policy: CapabilityPolicy) throws -> NativeRevisionStore {
        try NativeRevisionStore(
            rootURL: storeRoot,
            appId: appId,
            projectId: projectId,
            shellVersion: "1.0.0",
            capabilityPolicy: policy
        )
    }

    func generatePackage(
        content: String,
        baseRevisionId: String?,
        nonce: String,
        namespace: String,
        capabilities: [String]
    ) throws -> StorageGeneratedPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = storageRepositoryRoot()
            .appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--base", baseRevisionId ?? "null",
            "--content", content,
            "--nonce", nonce,
            "--namespace", namespace,
            "--capabilities", try storageJSONString(capabilities),
            "--app", appId,
            "--project", projectId,
            "--display-name", "Storage Test",
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
            throw StorageFixtureError.generatorFailed(
                String(data: errorData, encoding: .utf8) ?? "generator failed"
            )
        }

        let result = try storageJSONObject(outputData)
        let packagePath = try storageRequiredString(result, "packagePath")
        let approvalPath = try storageRequiredString(result, "trustedApprovalPath")
        let revisionId = try storageRequiredString(result, "revisionId")
        let approval = try storageTrustedApproval(
            Data(contentsOf: URL(fileURLWithPath: approvalPath))
        )
        return StorageGeneratedPackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            authority: StorageApprovalAuthority(approval: approval),
            revisionId: revisionId
        )
    }

    func revisionURL(_ revisionId: String) -> URL {
        storeRoot
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
            .appendingPathComponent(revisionId, isDirectory: true)
    }
}

private enum StorageFixtureError: Error {
    case generatorFailed(String)
    case malformed(String)
}

private func storageTrustedApproval(_ data: Data) throws -> TrustedDeliveryApproval {
    let value = try storageJSONObject(data)
    func nullable(_ key: String) throws -> String? {
        if value[key] is NSNull { return nil }
        return try storageRequiredString(value, key)
    }
    return TrustedDeliveryApproval(
        approvalId: try storageRequiredString(value, "approvalId"),
        requestId: try nullable("requestId"),
        requestNonce: try nullable("requestNonce"),
        appId: try storageRequiredString(value, "appId"),
        projectId: try storageRequiredString(value, "projectId"),
        baseRevisionId: try nullable("baseRevisionId"),
        approvedRevisionId: try storageRequiredString(value, "approvedRevisionId"),
        approvedContentHash: try storageRequiredString(value, "approvedContentHash"),
        approvedAt: try storageRequiredString(value, "approvedAt")
    )
}

private func storageJSONObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StorageFixtureError.malformed("expected object")
    }
    return value
}

private func storageRequiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else {
        throw StorageFixtureError.malformed("missing \(key)")
    }
    return value
}

private func storageJSONString(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

private func storageRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func storageHTML(_ marker: String) -> String {
    "<!doctype html><meta charset=utf-8><title>Storage</title><main>\(marker)</main>"
}

private func storageNonce(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func findManifestJSON(for revisionId: String, under root: URL) throws -> URL? {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in enumerator where url.pathExtension == "json" && url.pathComponents.contains("manifests") {
        let bytes = try Data(contentsOf: url)
        guard let text = String(data: bytes, encoding: .utf8), text.contains(revisionId) else { continue }
        return url
    }
    return nil
}

private func replaceStorageNamespace(in value: inout [String: Any]) -> Bool {
    for key in value.keys {
        if ["dataNamespace", "storageId", "storageIdentity"].contains(key), value[key] is String {
            value[key] = "publik.tampered"
            return true
        }
        if var nested = value[key] as? [String: Any], replaceStorageNamespace(in: &nested) {
            value[key] = nested
            return true
        }
    }
    return false
}

private func XCTAssertThrowsStorageNativeError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: NativeShellError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error \(expected)", file: file, line: line)
    } catch let error as NativeShellError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
