import Darwin
import Foundation

/// Migrates today's `revisions/<rev>/{metadata.json,content/}` layout (one
/// full file tree per version) into the v1 content-addressed layout (SPEC
/// section 2.7), once per app, journaled and resumable. Legacy content stays
/// readable until the adapter confirms a verified object-store launch. Clones
/// preserve sharing where supported; checkout records report real copy fallback.
struct LegacyStoredManifestFile: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
    let bytes: Int
    let mediaType: String
}

/// Mirrors `NativeRevisionStore.StoredManifest` exactly (field-for-field,
/// same JSON keys) so a legacy `metadata.json` -- which always has this
/// object today, per `NativeRevisionStore.stageIntoTemporaryDirectory` --
/// decodes it rather than silently discarding it. Migrating a revision
/// without carrying this forward would leave the v1 manifest unable to
/// answer `displayName`/`dataNamespace`/`requestedCapabilities` (SPEC.md
/// section 2.7: "revisionSummaries() reads manifests only"), which is real
/// data loss for anything reading the migrated store, not merely cosmetic.
struct LegacyStoredAppManifest: Codable, Equatable, Sendable {
    let displayName: String
    let runtimeType: String
    let entrypoint: String
    let minShellVersion: String
    let requestedCapabilities: [String]
    let dataNamespace: String
    let dataUpdatePolicy: String
}

struct LegacyStoredRevisionMetadata: Codable, Equatable, Sendable {
    let contractVersion: Int
    let appId: String
    let projectId: String
    let baseRevisionId: String?
    let revisionId: String
    let manifestHash: String
    let contentHash: String
    let createdAt: String
    let manifest: LegacyStoredAppManifest
    let files: [LegacyStoredManifestFile]
    /// Contract v1.1 (SPEC.md section 2.6). Absent on any revision staged
    /// before that field existed; `Codable` decodes that as `nil` rather
    /// than failing, so every pre-v1.1 legacy revision still migrates.
    let changes: [NativeVersionChange]?
}

public struct NativeStoreMigrationJournal: Codable, Equatable, Sendable {
    public var appId: String
    public var projectId: String
    public var migratedRevisionIds: [String]
    public var currentRevisionId: String?
    public var fallbackRevisionId: String?
    public var done: Bool
}

public enum NativeStoreMigrationError: Error, Equatable, Sendable {
    case legacyRevisionInvalid(String)
    case fileVerificationFailed(String, String) // revisionId, path
}

/// One legacy `revisions/` root migrated at a time. The caller supplies the
/// legacy root (`.../revisions`) and the new v1 root; everything else is
/// derived from the layout in SPEC 2.1.
public struct NativeStoreMigration: Sendable {
    public let legacyRevisionsRoot: URL
    public let v1Root: URL
    private var fileManager: FileManager { .default }

    private var objectsRoot: URL { v1Root.appendingPathComponent("objects", isDirectory: true) }
    private var checkoutsRoot: URL { v1Root.appendingPathComponent("checkouts", isDirectory: true) }
    private var stateRoot: URL { v1Root.appendingPathComponent("state", isDirectory: true) }

    public init(legacyRevisionsRoot: URL, v1Root: URL) {
        self.legacyRevisionsRoot = legacyRevisionsRoot
        self.v1Root = v1Root
    }

    private func journalURL(appId: String, projectId: String) -> URL {
        stateRoot.appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("migration.json")
    }

    public func readJournal(appId: String, projectId: String) -> NativeStoreMigrationJournal? {
        guard let data = try? Data(contentsOf: journalURL(appId: appId, projectId: projectId)) else { return nil }
        return try? JSONDecoder().decode(NativeStoreMigrationJournal.self, from: data)
    }

    private func writeJournal(_ journal: NativeStoreMigrationJournal) throws {
        let url = journalURL(appId: journal.appId, projectId: journal.projectId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(journal)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? fileManager.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    /// Migrates one app+project's revisions. `currentRevisionId` and
    /// `fallbackRevisionId` come from the legacy `active.json` (read by the
    /// caller, since that format is unchanged and MV2 already owns reading
    /// it); pass nil for a revision that has no fallback.
    public func migrate(
        appId: String,
        projectId: String,
        currentRevisionId: String?,
        fallbackRevisionId: String?,
        objects: NativeObjectStore,
        manifests: NativeVersionManifestStore,
        refs: NativeVersionRefs,
        ledger: NativeFeatureLedger,
        checkouts: NativeVersionCheckoutBuilder,
        fault: NativeVersionFaultInjector = .init()
    ) async throws {
        var journal = readJournal(appId: appId, projectId: projectId) ?? NativeStoreMigrationJournal(
            appId: appId, projectId: projectId, migratedRevisionIds: [],
            currentRevisionId: currentRevisionId, fallbackRevisionId: fallbackRevisionId, done: false
        )
        journal.done = false
        try await refs.markDirty()
        try writeJournal(journal)
        try fault.fire(.journalWrite_afterJournalWritten)

        let children = try fileManager.contentsOfDirectory(at: legacyRevisionsRoot, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        var revisions: [(URL, LegacyStoredRevisionMetadata)] = []
        for child in children {
            guard NativeSecurity.isRevisionId(child.lastPathComponent),
                  let data = try? Data(contentsOf: child.appendingPathComponent("metadata.json")),
                  let legacy = try? JSONDecoder().decode(LegacyStoredRevisionMetadata.self, from: data),
                  legacy.revisionId == child.lastPathComponent else {
                throw NativeStoreMigrationError.legacyRevisionInvalid(child.lastPathComponent)
            }
            revisions.append((child, legacy))
        }
        revisions.sort { $0.1.createdAt != $1.1.createdAt
            ? $0.1.createdAt < $1.1.createdAt : $0.1.revisionId < $1.1.revisionId }
        for (child, legacy) in revisions {
            let revisionId = legacy.revisionId
            let content = child.appendingPathComponent("content", isDirectory: true)
            var files: [NativeVersionFileEntry] = []
            // Always reverify on resume, including already imported revisions.
            // A journal entry is progress, never an assertion about current bytes.
            for file in legacy.files {
                let hash = file.sha256.hasPrefix("sha256:") ? String(file.sha256.dropFirst(7)) : file.sha256
                guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }),
                      NativeSecurity.isSafePackagePath(file.path), file.bytes >= 0 else {
                    throw NativeStoreMigrationError.fileVerificationFailed(revisionId, file.path)
                }
                let source = content.appendingPathComponent(file.path).standardizedFileURL
                try NativeSecurity.assertNoSymlinkComponents(from: legacyRevisionsRoot, to: source, fileManager: fileManager)
                let attrs = try fileManager.attributesOfItem(atPath: source.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      let data = try? Data(contentsOf: source), data.count == file.bytes,
                      NativeObjectStore.hex(data) == hash else {
                    throw NativeStoreMigrationError.fileVerificationFailed(revisionId, file.path)
                }
                let destination = objects.path(forSHA256: hash)
                let directory = destination.deletingLastPathComponent()
                try NativeSecurity.assertNoSymlinkComponents(from: v1Root, to: objectsRoot, fileManager: fileManager)
                if !fileManager.fileExists(atPath: directory.path) {
                    try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
                }
                try NativeSecurity.assertNoSymlinkComponents(from: v1Root, to: directory, fileManager: fileManager)
                if objects.exists(sha256: hash) {
                    try NativeSecurity.assertNoSymlinkComponents(from: v1Root, to: destination, fileManager: fileManager)
                    guard try objects.verify(sha256: hash) else {
                        throw NativeStoreMigrationError.fileVerificationFailed(revisionId, file.path)
                    }
                } else {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let temporary = objectsRoot.appendingPathComponent("tmp-\(UUID().uuidString)")
                    _ = try nativeCloneOrCopyFile(from: source, to: temporary)
                    try fault.fire(.objectWrite_afterTempWrite)
                    let handle = try FileHandle(forReadingFrom: temporary)
                    try handle.synchronize()
                    try handle.close()
                    try fault.fire(.objectWrite_afterFsync)
                    guard NativeObjectStore.hex(try Data(contentsOf: temporary)) == hash else {
                        throw NativeStoreMigrationError.fileVerificationFailed(revisionId, file.path)
                    }
                    guard rename(temporary.path, destination.path) == 0 else {
                        throw NativeStoreMigrationError.fileVerificationFailed(revisionId, file.path)
                    }
                    try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
                    try fault.fire(.objectWrite_afterRename)
                }
                files.append(.init(path: file.path, sha256: hash, bytes: file.bytes, mediaType: file.mediaType))
                try fault.fire(.migration_midRename)
            }
            let manifest = NativeVersionManifest(
                revisionId: revisionId, baseRevisionId: legacy.baseRevisionId,
                contentHash: legacy.contentHash, createdAt: legacy.createdAt,
                files: files, changes: legacy.changes,
                manifest: NativeVersionAppManifest(
                    displayName: legacy.manifest.displayName, runtimeType: legacy.manifest.runtimeType,
                    entrypoint: legacy.manifest.entrypoint, minShellVersion: legacy.manifest.minShellVersion,
                    requestedCapabilities: legacy.manifest.requestedCapabilities,
                    dataNamespace: legacy.manifest.dataNamespace, dataUpdatePolicy: legacy.manifest.dataUpdatePolicy
                )
            )
            try manifests.write(manifest, appId: appId, projectId: projectId, fault: fault)
            if revisionId == currentRevisionId || revisionId == fallbackRevisionId {
                _ = try checkouts.build(manifest: manifest, appId: appId, projectId: projectId, fault: fault)
                _ = try checkouts.verify(manifest: manifest, appId: appId, projectId: projectId)
            }
            if !ledger.rows(appId: appId, projectId: projectId).contains(where: { $0.revisionId == revisionId }) {
                let first = legacy.baseRevisionId == nil
                let title = first ? "First version" : (legacy.changes?.first?.title ?? "Update from \(Self.displayDate(legacy.createdAt))")
                let kind: NativeFeatureLedgerRow.Kind = legacy.changes?.first?.kind == .removed ? .removed
                    : (legacy.changes?.first?.kind == .added ? .added : .updated)
                try ledger.append(.init(title: title, kind: kind, createdAt: legacy.createdAt, revisionId: revisionId),
                                  appId: appId, projectId: projectId)
            }
            if !journal.migratedRevisionIds.contains(revisionId) { journal.migratedRevisionIds.append(revisionId) }
            try writeJournal(journal)
        }
        // Other apps can share these objects. Rebuilding only this app's refs
        // would make their live objects collectable.
        var all: [NativeVersionManifest] = []
        for project in try manifests.allProjects() {
            all += try manifests.list(appId: project.appId, projectId: project.projectId)
        }
        try await refs.rebuild(from: all, bytesForObject: { try objects.allocatedBytes(sha256: $0) })
        try fault.fire(.manifestWrite_afterRefsCommit)
        journal.currentRevisionId = currentRevisionId
        journal.fallbackRevisionId = fallbackRevisionId
        journal.done = true
        try writeJournal(journal)
    }

    /// Called only after the shipping adapter has returned a hash-verified
    /// active checkout. An interrupted cleanup is harmless and retried on open.
    func confirmVerifiedLaunch(appId: String, projectId: String) throws {
        guard readJournal(appId: appId, projectId: projectId)?.done == true,
              fileManager.fileExists(atPath: legacyRevisionsRoot.path) else { return }
        let objects = try NativeObjectStore(root: objectsRoot)
        let manifests = try NativeVersionManifestStore(root: v1Root.appendingPathComponent("manifests"))
        var verified = Set<String>()
        for manifest in try manifests.list(appId: appId, projectId: projectId) {
            for file in manifest.files where verified.insert(file.sha256).inserted {
                let url = objects.path(forSHA256: file.sha256)
                try NativeSecurity.assertNoSymlinkComponents(from: v1Root, to: url, fileManager: fileManager)
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      try objects.verify(sha256: file.sha256) else {
                    throw NativeStoreMigrationError.fileVerificationFailed(manifest.revisionId, file.path)
                }
            }
        }
        try fileManager.removeItem(at: legacyRevisionsRoot)
    }

    private static func displayDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) ?? {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: iso)
        }() else { return iso }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
