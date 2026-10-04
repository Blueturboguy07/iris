import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A live, identity-scoped input to count and cap planning. Freed ledger
/// rows are intentionally absent from the stored manifest set.
struct NativeStorageKeepSnapshot: Sendable {
    let identity: NativeShellAppIdentity
    let versions: [NativeVersionManifest]
    let current: String?
    let fallback: String?
    let pins: [String]
    let offers: Set<String>
    let legacyRoot: URL?
    let awaitingFirstLaunch: Bool

    var facts: [NativeStorageRetentionPolicy.RevisionFact] {
        versions.map { .init(revisionId: $0.revisionId, baseRevisionId: $0.baseRevisionId, createdAt: $0.createdAt) }
    }
    var storedIds: Set<String> { Set(versions.map(\.revisionId)) }
    var protectedIds: Set<String> {
        if awaitingFirstLaunch { return storedIds }
        return NativeStorageRetentionPolicy.retainedSet(revisions: facts, currentRevisionId: current,
            fallbackRevisionId: fallback, pinnedRevisionIds: pins).revisionIds.union(storedIds.subtracting(offers))
    }
    func retained(_ choice: VersionsKeptPerApp) -> Set<String> {
        if awaitingFirstLaunch { return storedIds }
        return NativeStorageRetentionPolicy.retainedRevisionIds(revisions: facts, currentRevisionId: current,
            fallbackRevisionId: fallback, pinnedRevisionIds: pins, localOnlyRevisionIds: [],
            downloadableRevisionIds: offers, keepCount: choice.count)
    }
}

struct NativeStorageRevisionKey: Hashable, Sendable {
    let identity: NativeShellAppIdentity
    let revisionId: String
}

/// One allocation graph per operation. Selection is linear in the selected
/// file tables, rather than rescanning a 1,000-app root for each revision.
struct NativeStorageReclaimLedger {
    private var references: [String: Set<NativeStorageRevisionKey>] = [:]
    private var allocations: [NativeStorageRevisionKey: Set<String>] = [:]
    private var bytes: [String: Int64] = [:]
    private var selected = Set<NativeStorageRevisionKey>()
    private(set) var totalBytes: Int64 = 0
    private(set) var bytesReclaimed: Int64 = 0

    init(root: URL, snapshots: [NativeStorageKeepSnapshot]) throws {
        var measured: [String: (String, Int64)] = [:]
        for snapshot in snapshots {
            let versions = Dictionary(uniqueKeysWithValues: snapshot.versions.map { ($0.revisionId, $0) })
            for version in snapshot.versions {
                let key = NativeStorageRevisionKey(identity: snapshot.identity, revisionId: version.revisionId)
                allocations[key] = []
                for file in version.files {
                    let url: URL
                    let allocation: String
                    if let legacy = snapshot.legacyRoot {
                        // Legacy clone reuse follows the same exact fingerprint
                        // and direct-base rule as the existing adapter measurement.
                        var owner = version.revisionId
                        var visited = Set<String>()
                        while visited.insert(owner).inserted, let base = versions[owner]?.baseRevisionId,
                              let parent = versions[base], parent.files.contains(file) { owner = base }
                        url = legacy.appendingPathComponent(owner + "/content/" + file.path)
                        allocation = "legacy/" + snapshot.identity.id + "/" + owner + "/" + file.path
                    } else {
                        url = root.appendingPathComponent("objects/" + String(file.sha256.prefix(2)) + "/" + file.sha256)
                        allocation = "object/" + file.sha256
                    }
                    let observed: (String, Int64)
                    if let cached = measured[allocation] { observed = cached }
                    else {
                        try NativeSecurity.assertNoSymlinkComponents(from: root, to: url, fileManager: .default)
                        var info = stat()
                        guard lstat(url.path, &info) == 0 else {
                            throw NativeStorageBlockMeasurement.MeasurementError.statFailed(url.path, errno: errno)
                        }
                        guard info.st_mode & S_IFMT == S_IFREG else {
                            throw NativeStorageBlockMeasurement.MeasurementError.notARegularFile(url.path)
                        }
                        observed = ("\(info.st_dev):\(info.st_ino)", Int64(info.st_blocks) * 512)
                        measured[allocation] = observed
                    }
                    add(allocation: observed.0, bytes: observed.1, reference: key)
                }
                guard snapshot.legacyRoot == nil else { continue }
                let checkout = root.appendingPathComponent("checkouts/" + snapshot.identity.appId + "/" + snapshot.identity.projectId + "/" + version.revisionId)
                let content = checkout.appendingPathComponent("content")
                guard FileManager.default.fileExists(atPath: content.path) else { continue }
                try NativeSecurity.assertNoSymlinkComponents(from: root, to: content, fileManager: .default)
                let receiptURL = checkout.appendingPathComponent("checkout.json")
                var cloned = false
                if FileManager.default.fileExists(atPath: receiptURL.path) {
                    try NativeSecurity.assertNoSymlinkComponents(from: root, to: receiptURL, fileManager: .default)
                    let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any]
                    cloned = receipt?["cloned"] as? Bool == true
                }
                if !cloned {
                    add(allocation: "copy/" + key.identity.id + "/" + key.revisionId,
                        bytes: try NativeStorageBlockMeasurement.allocatedTreeBytes(at: content), reference: key)
                }
            }
        }
    }

    private mutating func add(allocation: String, bytes amount: Int64, reference: NativeStorageRevisionKey) {
        if bytes[allocation] == nil { bytes[allocation] = amount; totalBytes += amount }
        references[allocation, default: []].insert(reference)
        allocations[reference, default: []].insert(allocation)
    }

    @discardableResult
    mutating func select(identity: NativeShellAppIdentity, revisionId: String) -> Int64 {
        let key = NativeStorageRevisionKey(identity: identity, revisionId: revisionId)
        guard selected.insert(key).inserted else { return 0 }
        var reclaimed: Int64 = 0
        for allocation in allocations[key, default: []] {
            references[allocation]?.remove(key)
            if references[allocation]?.isEmpty == true { reclaimed += bytes[allocation, default: 0] }
        }
        bytesReclaimed += reclaimed
        return reclaimed
    }
}

/// Measures on-disk allocation the way APFS actually charges it (512-byte
/// blocks, `st_blocks`), not the logical byte count `Data(contentsOf:).count`
/// or a package manifest's declared size would report.
///
/// A same-volume `clonefile` copy of an unchanged file (`NativeRevisionStore`
/// makes exactly this call when staging an update whose file is byte-identical
/// to its base revision's file at the same path) still reports its own full
/// `st_blocks` from `stat`, because APFS's copy-on-write sharing is invisible
/// at that layer: summing every file's blocks across every stored revision
/// therefore overstates real usage whenever this store's own clone reuse
/// shared content with an older, still-retained revision.
/// `dedupingAllocatedBytes` corrects for exactly that known sharing pattern
/// (same path, same declared fingerprint, base revision still present) using
/// the same equality test `NativeRevisionStore.stageIntoTemporaryDirectory`
/// uses to decide whether to clone in the first place. It does not attempt
/// general content-addressed dedupe of files this store did not itself clone.
public enum NativeStorageBlockMeasurement {
    public enum MeasurementError: Error, Equatable {
        case notARegularFile(String)
        case statFailed(String, errno: Int32)
        case capacityUnavailable(String)
    }

    /// One file's identity for dedupe purposes: exactly the fields
    /// `NativeRevisionStore` compares (path, content hash, byte count and
    /// declared media type) before it attempts a clone from a base revision.
    public struct FileFingerprint: Equatable, Sendable {
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

    /// `st_blocks * 512` for one regular file, via `lstat` so a symbolic
    /// link is rejected rather than silently followed.
    public static func allocatedBytes(atPath path: String) throws -> Int {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw MeasurementError.statFailed(path, errno: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw MeasurementError.notARegularFile(path)
        }
        return Int(info.st_blocks) * 512
    }

    /// Allocated bytes per revision id, deduplicating clone-shared blocks.
    ///
    /// For each revision, a file is only charged in full when its direct
    /// base revision is either absent from `filesByRevision` (pruned away,
    /// so this revision is now the sole owner of those physical blocks) or
    /// present but without a byte-identical fingerprint at that path (a real
    /// content change). When the direct base is present in the same call
    /// and has the identical fingerprint at that path, the file is counted
    /// as zero here: it shares physical blocks with that base, which is
    /// counted once, at the base.
    ///
    /// This intentionally keys off each revision's *own* base id, not
    /// "whatever was processed previously": a revision whose base was
    /// pruned must be re-charged in full even though its blocks were once
    /// shared, and revisions are not required to be passed in any order.
    public static func dedupingAllocatedBytes(
        contentRootByRevision: [String: URL],
        filesByRevision: [String: [FileFingerprint]],
        baseRevisionByRevision: [String: String?]
    ) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (revisionId, files) in filesByRevision {
            guard let contentURL = contentRootByRevision[revisionId] else { continue }
            let baseId = baseRevisionByRevision[revisionId] ?? nil
            let baseFilesByPath: [String: FileFingerprint] = baseId
                .flatMap { filesByRevision[$0] }
                .map { baseFiles in Dictionary(uniqueKeysWithValues: baseFiles.map { ($0.path, $0) }) }
                ?? [:]
            var total = 0
            for file in files {
                if baseFilesByPath[file.path] == file { continue }
                let fileURL = contentURL.appendingPathComponent(file.path)
                total += try allocatedBytes(atPath: fileURL.path)
            }
            result[revisionId] = total
        }
        return result
    }

    /// Measures the union of allocations released by the selected revisions.
    /// A shared object earns credit only when every live reference is selected.
    static func reclaimableBytes(root: URL, snapshots: [NativeStorageKeepSnapshot],
                                 removing: [NativeShellAppIdentity: Set<String>]) throws -> Int64 {
        var ledger = try NativeStorageReclaimLedger(root: root, snapshots: snapshots)
        for (identity, ids) in removing {
            for id in ids { ledger.select(identity: identity, revisionId: id) }
        }
        return ledger.bytesReclaimed
    }

    static func allocatedTreeBytes(at root: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        var total: Int64 = 0
        var seen = Set<String>()
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            errorHandler: { _, error in enumerationError = error; return false }) else { throw MeasurementError.capacityUnavailable(root.path) }
        for case let entry as URL in entries {
            var info = stat()
            guard lstat(entry.path, &info) == 0 else { throw MeasurementError.statFailed(entry.path, errno: errno) }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw MeasurementError.notARegularFile(entry.path) }
            if info.st_mode & S_IFMT == S_IFREG, seen.insert("\(info.st_dev):\(info.st_ino)").inserted {
                total += Int64(info.st_blocks) * 512
            }
        }
        if let enumerationError { throw enumerationError }
        return total
    }

    /// The volume's free space "important for the user to know about" (the
    /// same metric Files/Settings storage bars use), for the low-storage
    /// staging guard. Real filesystem I/O; tests inject a fake instead of
    /// filling a real disk (see `NativeRevisionStore.availableCapacityProvider`).
    ///
    /// `url` need not exist yet: a brand-new store's root directory is not
    /// created until the first successful stage. Volume free space is the
    /// same answer for every path on that volume, so this walks up to the
    /// nearest ancestor that already exists (worst case "/") and asks there.
    public static func systemAvailableCapacityBytes(at url: URL) throws -> Int64 {
        var candidate = url.standardizedFileURL
        var hops = 0
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path, hops < 64 else { break }
            candidate = parent
            hops += 1
        }
        let importantCapacity = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let capacity = importantCapacity, capacity > 0 { return capacity }
        // The important-usage estimate can be unavailable or zero even when
        // this volume has physical free blocks. Use the filesystem's actual
        // free bytes as a conservative fallback, without counting purgeable data.
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: candidate.path),
           let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value >= 0 {
            return free.int64Value
        }
        if let capacity = importantCapacity, capacity == 0 { return 0 }
        throw MeasurementError.capacityUnavailable(url.path)
    }
}
