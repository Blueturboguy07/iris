import Darwin
import Foundation

/// A version's file table (SPEC section 2.1, 2.6): the StoredRevision fields
/// as today, plus the optional contract v1.1 `changes` field MV3 will emit.
public struct NativeVersionFileEntry: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let bytes: Int
    public let mediaType: String

    public init(path: String, sha256: String, bytes: Int, mediaType: String) {
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.mediaType = mediaType
    }
}

public struct NativeVersionChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, removed }
    public let title: String
    public let kind: Kind
    public let target: String?

    public init(title: String, kind: Kind, target: String?) {
        self.title = title
        self.kind = kind
        self.target = target
    }
}

/// The app-manifest fields today's `NativeRevisionStore.StoredManifest`
/// carries (displayName, runtime, capabilities, data namespace/policy),
/// mirrored here so a manifest written by MV2's adapter (or by migration,
/// which reads it straight from a legacy `metadata.json`) can answer
/// `revisionSummaries()`-shaped questions (display name, data namespace,
/// requested capabilities) without ever hashing file content -- SPEC.md
/// section 2.7's "revisionSummaries() reads manifests only". Optional on
/// `NativeVersionManifest` so every one of MV1's 47 tests, whose fixtures
/// build a manifest with no app-level fields at all, keeps compiling and
/// passing unchanged; a manifest written through MV2 always sets it.
public struct NativeVersionAppManifest: Codable, Equatable, Sendable {
    public let displayName: String
    public let runtimeType: String
    public let entrypoint: String
    public let minShellVersion: String
    public let requestedCapabilities: [String]
    public let dataNamespace: String
    public let dataUpdatePolicy: String

    public init(
        displayName: String,
        runtimeType: String,
        entrypoint: String,
        minShellVersion: String,
        requestedCapabilities: [String],
        dataNamespace: String,
        dataUpdatePolicy: String
    ) {
        self.displayName = displayName
        self.runtimeType = runtimeType
        self.entrypoint = entrypoint
        self.minShellVersion = minShellVersion
        self.requestedCapabilities = requestedCapabilities
        self.dataNamespace = dataNamespace
        self.dataUpdatePolicy = dataUpdatePolicy
    }
}

public struct NativeVersionManifest: Codable, Equatable, Sendable {
    public let revisionId: String
    public let baseRevisionId: String?
    public let contentHash: String
    public let createdAt: String
    public let files: [NativeVersionFileEntry]
    public let changes: [NativeVersionChange]?
    public let manifest: NativeVersionAppManifest?

    public init(
        revisionId: String,
        baseRevisionId: String?,
        contentHash: String,
        createdAt: String,
        files: [NativeVersionFileEntry],
        changes: [NativeVersionChange]? = nil,
        manifest: NativeVersionAppManifest? = nil
    ) {
        self.revisionId = revisionId
        self.baseRevisionId = baseRevisionId
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.files = files
        self.changes = changes
        self.manifest = manifest
    }
}

public enum NativeVersionManifestError: Error, Equatable, Sendable {
    case manifestNotFound(String)
    case manifestCorrupt(String)
}

/// `manifests/<appId>/<projectId>/rev-sha256:<id>.json` (SPEC 2.1). A manifest
/// proves itself against its own filename (`revisionId`); it never needs to
/// touch `objects/` to be trusted as a row in the Features list.
public struct NativeVersionManifestStore: Sendable {
    public let root: URL // .../v1/manifests
    private var fileManager: FileManager { .default }
    private let readCache = ReadCache()
    private let rootPath: String

    private struct FileSignature: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let uid: uid_t
        let gid: gid_t
        let links: nlink_t
        let size: off_t
        let blocks: blkcnt_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    // Cache decoded manifests only while the actual file identity matches.
    // Every ancestry read still checks disk; edits, replacement and removal
    // cannot authorize a rollback using a stale parent. No I/O holds this lock.
    private final class ReadCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (signature: FileSignature, manifest: NativeVersionManifest, bytes: Int)] = [:]
        private var encodedBytes = 0

        func get(_ path: String, signature: FileSignature) -> NativeVersionManifest? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.signature == signature else { return nil }
            return entry.manifest
        }

        func insert(_ manifest: NativeVersionManifest, path: String, signature: FileSignature, bytes: Int) {
            let limit = 8 * 1_024 * 1_024
            guard bytes <= limit else { return }
            lock.lock(); defer { lock.unlock() }
            if let previous = entries.removeValue(forKey: path) { encodedBytes -= previous.bytes }
            if entries.count >= 2_048 || encodedBytes > limit - bytes {
                entries.removeAll(keepingCapacity: true)
                encodedBytes = 0
            }
            entries[path] = (signature, manifest, bytes)
            encodedBytes += bytes
        }
    }

    private func readSignature(_ path: String) -> FileSignature? {
        var info = stat()
        // Follow the same target as Data(contentsOf:), including URL aliases.
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileSignature(device: info.st_dev, inode: info.st_ino, mode: info.st_mode,
            uid: info.st_uid, gid: info.st_gid, links: info.st_nlink, size: info.st_size,
            blocks: info.st_blocks, modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec, changedSeconds: info.st_ctimespec.tv_sec,
            changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    public init(root: URL) throws {
        self.root = root
        self.rootPath = root.path
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directory(appId: String, projectId: String) -> URL {
        root.appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
    }

    private func filePath(appId: String, projectId: String, revisionId: String) -> String {
        rootPath + "/" + appId + "/" + projectId + "/" + revisionId + ".json"
    }

    private func fileURL(appId: String, projectId: String, revisionId: String) -> URL {
        URL(fileURLWithPath: filePath(appId: appId, projectId: projectId, revisionId: revisionId), isDirectory: false)
    }

    private func tombURL(appId: String, projectId: String, revisionId: String) -> URL {
        directory(appId: appId, projectId: projectId).appendingPathComponent("\(revisionId).json.tomb")
    }

    public func exists(appId: String, projectId: String, revisionId: String) -> Bool {
        fileManager.fileExists(atPath: filePath(appId: appId, projectId: projectId, revisionId: revisionId))
    }

    /// True when the manifest row still exists but has been tombstoned (SPEC
    /// 2.5 "Free up space"): its objects may already be gone, but the row
    /// stays so the Features page can still say "Not on this iPhone".
    public func isTombstoned(appId: String, projectId: String, revisionId: String) -> Bool {
        fileManager.fileExists(atPath: tombURL(appId: appId, projectId: projectId, revisionId: revisionId).path)
    }

    @discardableResult
    public func write(
        _ manifest: NativeVersionManifest,
        appId: String,
        projectId: String,
        fault: NativeVersionFaultInjector = .init()
    ) throws -> URL {
        let dir = directory(appId: appId, projectId: projectId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        let tmp = dir.appendingPathComponent("tmp-\(UUID().uuidString).json")
        try data.write(to: tmp, options: .atomic)
        try fault.fire(.manifestWrite_afterTempWrite)
        let dest = fileURL(appId: appId, projectId: projectId, revisionId: manifest.revisionId)
        guard rename(tmp.path, dest.path) == 0 else {
            let err = errno
            try? fileManager.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        try fault.fire(.manifestWrite_afterRename)
        return dest
    }

    public func read(appId: String, projectId: String, revisionId: String) throws -> NativeVersionManifest {
        let path = filePath(appId: appId, projectId: projectId, revisionId: revisionId)
        let observed = readSignature(path)
        if let observed, let cached = readCache.get(path, signature: observed),
           readSignature(path) == observed { return cached }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)) else {
            throw NativeVersionManifestError.manifestNotFound(revisionId)
        }
        do {
            let manifest = try JSONDecoder().decode(NativeVersionManifest.self, from: data)
            if let observed, readSignature(path) == observed {
                readCache.insert(manifest, path: path, signature: observed, bytes: data.count)
            }
            return manifest
        } catch {
            throw NativeVersionManifestError.manifestCorrupt(revisionId)
        }
    }

    func readHistory(appId: String, projectId: String, revisionId: String) throws -> NativeVersionManifest {
        if exists(appId: appId, projectId: projectId, revisionId: revisionId) {
            return try read(appId: appId, projectId: projectId, revisionId: revisionId)
        }
        let url = directory(appId: appId, projectId: projectId).appendingPathComponent("\(revisionId).json.freed")
        guard let data = try? Data(contentsOf: url) else { throw NativeVersionManifestError.manifestNotFound(revisionId) }
        let manifest = try JSONDecoder().decode(NativeVersionManifest.self, from: data)
        guard manifest.revisionId == revisionId else { throw NativeVersionManifestError.manifestCorrupt(revisionId) }
        return manifest
    }

    /// Every manifest row for one app+project, in no particular order
    /// (callers sort by `createdAt` for display, per section 1.1).
    public func list(appId: String, projectId: String) throws -> [NativeVersionManifest] {
        let dir = directory(appId: appId, projectId: projectId)
        guard let children = try? fileManager.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var result: [NativeVersionManifest] = []
        for name in children {
            guard name.hasSuffix(".json"), !name.hasPrefix("tmp-") else { continue }
            let revisionId = String(name.dropLast(5))
            guard let manifest = try? read(appId: appId, projectId: projectId, revisionId: revisionId),
                  name == "\(manifest.revisionId).json" else {
                throw NativeVersionManifestError.manifestCorrupt(name)
            }
            result.append(manifest)
        }
        return result
    }

    /// Every (appId, projectId) pair with at least one manifest, for
    /// migration and whole-store scans (GC, scale checks).
    public func allProjects() throws -> [(appId: String, projectId: String)] {
        guard let appDirs = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        var result: [(String, String)] = []
        for appId in appDirs {
            guard let projectDirs = try? fileManager.contentsOfDirectory(atPath: root.path + "/" + appId) else {
                continue
            }
            for projectId in projectDirs {
                result.append((appId, projectId))
            }
        }
        return result
    }

    /// Interrupted removals retain their file table until every unreferenced
    /// object is gone. These manifests are never part of the live listing.
    func tombstones(appId: String, projectId: String) throws -> [NativeVersionManifest] {
        let dir = directory(appId: appId, projectId: projectId)
        let children = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var result: [NativeVersionManifest] = []
        for child in children where child.lastPathComponent.hasSuffix(".json.tomb") {
            let id = String(child.lastPathComponent.dropLast(".json.tomb".count))
            guard NativeSecurity.isRevisionId(id) else { throw NativeVersionManifestError.manifestCorrupt(id) }
            try NativeSecurity.assertNoSymlinkComponents(from: root, to: child, fileManager: fileManager)
            let manifest = try JSONDecoder().decode(NativeVersionManifest.self, from: Data(contentsOf: child))
            guard manifest.revisionId == id,
                  manifest.files.allSatisfy({ $0.sha256.count == 64 && $0.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) })
            else { throw NativeVersionManifestError.manifestCorrupt(id) }
            result.append(manifest)
        }
        return result
    }

    /// Step 1 of removing a version's objects (SPEC 2.5): tombstone the
    /// manifest so a crash between here and the objects-freed step leaves an
    /// unambiguous "being removed" marker, not a half-valid row.
    public func tombstone(appId: String, projectId: String, revisionId: String) throws {
        let src = fileURL(appId: appId, projectId: projectId, revisionId: revisionId)
        let dst = tombURL(appId: appId, projectId: projectId, revisionId: revisionId)
        guard fileManager.fileExists(atPath: src.path) else { return }
        if fileManager.fileExists(atPath: dst.path) {
            try? fileManager.removeItem(at: src)
            return
        }
        try fileManager.moveItem(at: src, to: dst)
    }

    /// Final step: once unreferenced objects are gone, remove the tombstone
    /// marker by retaining history metadata as .freed. That row contributes
    /// no object references and exists() still reports it unavailable.
    public func purgeTombstone(appId: String, projectId: String, revisionId: String) throws {
        let url = tombURL(appId: appId, projectId: projectId, revisionId: revisionId)
        guard fileManager.fileExists(atPath: url.path) else { return }
        let row = directory(appId: appId, projectId: projectId).appendingPathComponent("\(revisionId).json.freed")
        guard rename(url.path, row.path) == 0 else { throw NativeVersionManifestError.manifestCorrupt(revisionId) }
    }

    /// Small history metadata survives freeing objects. Availability is still
    /// determined by exists(), never by this history listing.
    public func history(appId: String, projectId: String) throws -> [NativeVersionManifest] {
        var rows = try list(appId: appId, projectId: projectId)
        var known = Set(rows.map(\.revisionId))
        let dir = directory(appId: appId, projectId: projectId)
        for child in (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            guard child.lastPathComponent.hasSuffix(".json.freed") else { continue }
            let id = String(child.lastPathComponent.dropLast(".json.freed".count))
            guard NativeSecurity.isRevisionId(id) else { throw NativeVersionManifestError.manifestCorrupt(id) }
            try NativeSecurity.assertNoSymlinkComponents(from: root, to: child, fileManager: fileManager)
            let row = try JSONDecoder().decode(NativeVersionManifest.self, from: Data(contentsOf: child))
            guard row.revisionId == id else { throw NativeVersionManifestError.manifestCorrupt(id) }
            if known.insert(id).inserted { rows.append(row) }
        }
        return rows
    }
}
