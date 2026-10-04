import Foundation
import XCTest
@testable import IrisMobileShellCore

// Shared world for the Versions* suites (MV1-object-store-core). Deliberately
// self-contained (no dependency on other units' test support files, which
// are being written in parallel) and namespaced with a `Versions` prefix so
// nothing here collides with another suite's identically-purposed helper.

/// A fresh `v1/` store root for one simulated phone, deleted on `cleanup()`.
final class VersionsTestRoot {
    let base: URL
    let v1: URL

    init(_ label: String = #function) throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("versions-tests", isDirectory: true)
            .appendingPathComponent("\(label.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
        v1 = base.appendingPathComponent("v1", isDirectory: true)
        try FileManager.default.createDirectory(at: v1, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }

    func makeStore() throws -> NativeVersionStore {
        try NativeVersionStore(root: v1)
    }
}

/// Deterministic seeded generator (SplitMix64) so every scale/persona run is
/// replayable, namespaced to avoid colliding with another suite's generator
/// of the same algorithm under a different name.
struct VersionsSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum VersionsFixture {
    /// A small deterministic file set: content is unique per (seed, path) so
    /// dedup only happens when a test asks for it explicitly by reusing
    /// bytes across two file sets.
    static func files(seed: UInt64, count: Int, averageBytes: Int = 512, prefix: String = "assets") -> [NativeVersionStagedFile] {
        var rng = VersionsSeededRandom(seed: seed)
        return (0..<count).map { index in
            let size = max(16, Int(averageBytes) + Int(rng.next() % UInt64(averageBytes)) - averageBytes / 2)
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { buffer in
                for i in 0..<size {
                    buffer[i] = UInt8((rng.next() ^ UInt64(i)) & 0xff)
                }
            }
            return NativeVersionStagedFile(path: "\(prefix)/file-\(index).bin", data: bytes, mediaType: "application/octet-stream")
        }
    }

    /// Identity fields for a manifest built from `files`, using the same
    /// sha256 + `rev-sha256:` scheme the rest of the app uses
    /// (`NativeSecurity`), so fixtures look like real revisions.
    static func identity(appId: String, projectId: String, baseRevisionId: String?, files: [NativeVersionStagedFile], createdAt: String) -> (contentHash: String, revisionId: String) {
        let sortedDescriptions = files.sorted { $0.path < $1.path }.map { file -> String in
            let sha = NativeObjectStore.hex(file.data)
            return "\(file.path)|\(sha)|\(file.data.count)|\(file.mediaType)"
        }.joined(separator: "\n")
        let payload = "\(appId)|\(projectId)|\(baseRevisionId ?? "")|\(createdAt)|\(sortedDescriptions)"
        let contentHash = NativeSecurity.sha256(Data(payload.utf8))
        let revisionId = NativeSecurity.revisionId(forContentHash: contentHash)!
        return (contentHash, revisionId)
    }

    static func isoNow(offsetSeconds: TimeInterval = 0) -> String {
        NativeVersionRefs.iso(Date().addingTimeInterval(offsetSeconds))
    }
}

/// Stages one version end to end (files -> identity -> `stage`) and returns
/// its revisionId, so end-to-end tests read as a sequence of versions rather
/// than a wall of manifest plumbing.
@discardableResult
func versionsStageFixture(
    on store: NativeVersionStore,
    appId: String,
    projectId: String,
    seed: UInt64,
    fileCount: Int = 6,
    averageBytesOverride: Int = 512,
    baseRevisionId: String?,
    createdAtOffset: TimeInterval,
    changes: [NativeVersionChange]? = nil,
    title: String? = nil,
    fault: NativeVersionFaultInjector = .init()
) async throws -> String {
    let files = VersionsFixture.files(seed: seed, count: fileCount, averageBytes: averageBytesOverride)
    let createdAt = VersionsFixture.isoNow(offsetSeconds: createdAtOffset)
    let identity = VersionsFixture.identity(appId: appId, projectId: projectId, baseRevisionId: baseRevisionId, files: files, createdAt: createdAt)
    let receipt = try await store.stage(
        appId: appId, projectId: projectId,
        revisionId: identity.revisionId, baseRevisionId: baseRevisionId,
        contentHash: identity.contentHash, createdAt: createdAt,
        files: files, changes: changes, title: title, fault: fault
    )
    return receipt.revisionId
}

/// Builds a fixture in today's pre-migration `revisions/<rev>/{metadata.json,
/// content/}` layout (SPEC 2.7), so migration tests exercise the real
/// decode path `NativeStoreMigration` reads, not a shortcut.
enum VersionsLegacyFixture {
    struct Revision {
        let id: String
        let base: String?
        let files: [(path: String, data: Data)]
        let createdAt: String
        let changes: [NativeVersionChange]?
    }

    static func revision(
        id: String, base: String?, seed: UInt64, createdAt: String, fileCount: Int = 4,
        changes: [NativeVersionChange]? = nil
    ) -> Revision {
        var rng = VersionsSeededRandom(seed: seed)
        let files: [(String, Data)] = (0..<fileCount).map { index in
            let size = 64 + Int(rng.next() % 256)
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { buffer in
                for i in 0..<size { buffer[i] = UInt8((rng.next() ^ UInt64(i)) & 0xff) }
            }
            return ("assets/file-\(index).bin", bytes)
        }
        return Revision(id: id, base: base, files: files, createdAt: createdAt, changes: changes)
    }

    static func write(revisions: [Revision], to legacyRoot: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        for revision in revisions {
            let revisionDir = legacyRoot.appendingPathComponent(revision.id, isDirectory: true)
            let contentDir = revisionDir.appendingPathComponent("content", isDirectory: true)
            try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)

            var legacyFiles: [LegacyStoredManifestFile] = []
            for file in revision.files {
                let dest = contentDir.appendingPathComponent(file.path)
                try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: dest)
                legacyFiles.append(LegacyStoredManifestFile(path: file.path, sha256: NativeObjectStore.hex(file.data), bytes: file.data.count, mediaType: "application/octet-stream"))
            }
            let metadata = LegacyStoredRevisionMetadata(
                contractVersion: 1, appId: "ignored-by-migration-decode", projectId: "ignored-by-migration-decode",
                baseRevisionId: revision.base, revisionId: revision.id,
                manifestHash: "sha256:" + String(repeating: "0", count: 64),
                contentHash: "sha256:" + String(repeating: "0", count: 64),
                createdAt: revision.createdAt,
                // A real `metadata.json` always carries this object
                // (`NativeRevisionStore.StoredManifest`); this fixture's own
                // values are unused by migration's identity checks (it never
                // re-hashes), but the app-manifest fields it carries forward
                // ARE now asserted by `testMigrationCarriesTheAppManifestForward`.
                manifest: LegacyStoredAppManifest(
                    displayName: "Legacy Fixture App",
                    runtimeType: "web",
                    entrypoint: "assets/file-0.bin",
                    minShellVersion: "1.0.0",
                    requestedCapabilities: [],
                    dataNamespace: "publik.kneecap",
                    dataUpdatePolicy: "preserve"
                ),
                files: legacyFiles,
                changes: revision.changes
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: revisionDir.appendingPathComponent("metadata.json"))
        }
    }
}

/// Runs the Python oracle against a store root and fails the test if it
/// reports any finding. Requires `python3` on PATH (true in this repo's dev
/// environment; the script has no third-party dependency).
func versionsRunOracle(v1Root: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
    let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // .../Tests/IrisMobileShellCoreTests/VersionsTestSupport.swift -> IrisMobileShellCoreTests/
        .deletingLastPathComponent() // -> Tests/
        .deletingLastPathComponent() // -> native/
        .deletingLastPathComponent() // -> mobile-shell/
        .deletingLastPathComponent() // -> iris/ (repo root)
        .appendingPathComponent("docs/plans/20260928-all-routes/round3/mobile-versions/MV1-object-store-core/oracle_store.py")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", scriptURL.path, v1Root.path, "--json"]
    let stdout = Pipe()
    process.standardOutput = stdout
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTFail("oracle_store.py produced no JSON. stderr: \(String(data: errData, encoding: .utf8) ?? "")", file: file, line: line)
        return [:]
    }
    return json
}
