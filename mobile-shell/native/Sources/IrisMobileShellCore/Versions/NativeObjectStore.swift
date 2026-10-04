import CryptoKit
import Darwin
import Foundation

/// Content-addressed object store (SPEC section 2.1, 2.2). One file per unique
/// content, shared by every app and every version. Objects are written once,
/// verified once at write time (hash of the bytes just written), chmod 0444,
/// and never modified again. Layout: `objects/<2-char fan-out>/<sha256 hex>`,
/// in-flight writes at `objects/tmp-<uuid>` swept on launch.
public enum NativeObjectStoreError: Error, Equatable, Sendable {
    case objectNotFound(String)
    case corruptObject(sha256: String)
}

public struct NativeObjectStore: Sendable {
    public let root: URL // .../v1/objects
    private var fileManager: FileManager { .default }

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func path(forSHA256 hex: String) -> URL {
        let fan = String(hex.prefix(2))
        return root.appendingPathComponent(fan, isDirectory: true).appendingPathComponent(hex)
    }

    public func exists(sha256 hex: String) -> Bool {
        fileManager.fileExists(atPath: path(forSHA256: hex).path)
    }

    /// Writes `data`, returning its bare sha256 hex (no `sha256:` prefix, to
    /// match a manifest file entry's `sha256` field and the object filename
    /// directly). Idempotent: writing the same bytes twice is a fast no-op.
    @discardableResult
    public func write(_ data: Data, fault: NativeVersionFaultInjector = .init()) throws -> String {
        let hex = Self.hex(data)
        var replacingDamagedCopy = false
        if exists(sha256: hex) {
            var st = stat()
            if stat(path(forSHA256: hex).path, &st) == 0, Int(st.st_size) == data.count {
                // A repeat write of content that is already stored. Refresh
                // its modification time: garbage collection only sweeps
                // objects nothing references AND that are older than its
                // grace window, and this write is the first half of a stage
                // whose manifest lands a moment later. Without the refresh an
                // old, currently unreferenced object (left by an interrupted
                // stage) could be swept in that gap and the new manifest
                // would point at nothing.
                _ = utimes(path(forSHA256: hex).path, nil)
                return hex
            }
            // Same name, wrong size: a damaged copy. Replace it with the
            // bytes we hold (every version that lists this content heals).
            replacingDamagedCopy = true
        }

        let tmp = root.appendingPathComponent("tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: tmp.path, contents: nil) else {
            throw NativeObjectStoreError.corruptObject(sha256: hex)
        }
        try fault.fire(.objectWrite_afterTempWrite)
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.write(contentsOf: data)
            try handle.synchronize() // fsync
            try handle.close()
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw error
        }
        try fault.fire(.objectWrite_afterFsync)

        let fanDir = root.appendingPathComponent(String(hex.prefix(2)), isDirectory: true)
        try fileManager.createDirectory(at: fanDir, withIntermediateDirectories: true)
        let dest = path(forSHA256: hex)
        if replacingDamagedCopy {
            guard rename(tmp.path, dest.path) == 0 else {
                let err = errno
                try? fileManager.removeItem(at: tmp)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
            try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        } else if fileManager.fileExists(atPath: dest.path) {
            // Another writer won the race for this identical content.
            try? fileManager.removeItem(at: tmp)
        } else {
            do {
                try fileManager.moveItem(at: tmp, to: dest)
            } catch {
                if fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.removeItem(at: tmp)
                } else {
                    throw error
                }
            }
            try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
        }
        try fault.fire(.objectWrite_afterRename)
        return hex
    }

    public func read(sha256 hex: String) throws -> Data {
        let url = path(forSHA256: hex)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NativeObjectStoreError.objectNotFound(hex)
        }
        return try Data(contentsOf: url)
    }

    /// Re-hashes the object on disk and compares to its own filename. Used at
    /// checkout-build and by the mark-and-sweep verifier, never by ordinary
    /// reads (those trust the write-time verification and the read-only mode).
    public func verify(sha256 hex: String) throws -> Bool {
        let data = try read(sha256: hex)
        return Self.hex(data) == hex
    }

    /// Allocated bytes on disk (`st_blocks * 512`), the number "Free up space"
    /// and the Storage screen must use, never the logical file size (SPEC
    /// 2.5: "the number shown is the number the disk gets back").
    public func allocatedBytes(sha256 hex: String) throws -> Int {
        var st = stat()
        let path = path(forSHA256: hex).path
        guard stat(path, &st) == 0 else {
            throw NativeObjectStoreError.objectNotFound(hex)
        }
        return Int(st.st_blocks) * 512
    }

    public func delete(sha256 hex: String) throws {
        let url = path(forSHA256: hex)
        guard fileManager.fileExists(atPath: url.path) else { return }
        // Objects are read-only (0444); reclaim write permission on the
        // containing reference before unlinking.
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try fileManager.removeItem(at: url)
    }

    /// Every unique sha256 hex currently stored, from the fan-out directories.
    public func allObjectHashes() throws -> Set<String> {
        var result = Set<String>()
        guard let fanDirs = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return result
        }
        for fanDir in fanDirs {
            guard fanDir.lastPathComponent.count == 2,
                  (try? fanDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let children = (try? fileManager.contentsOfDirectory(at: fanDir, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                result.insert(child.lastPathComponent)
            }
        }
        return result
    }

    /// Deletes `objects/tmp-*` files older than `olderThan` seconds. Run on
    /// every launch before anything else touches the store (SPEC 2.4). The
    /// age guard protects a write that is still in flight in another process.
    @discardableResult
    public func sweepOrphanTemps(olderThan seconds: TimeInterval = 600) -> Int {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        var swept = 0
        let cutoff = Date().addingTimeInterval(-seconds)
        for child in children where child.lastPathComponent.hasPrefix("tmp-") {
            let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < cutoff {
                try? fileManager.removeItem(at: child)
                swept += 1
            }
        }
        return swept
    }

    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// `clonefile(2)` on APFS shares blocks with the source at zero physical cost;
/// falls back to an ordinary copy on a volume that refuses it (a copy volume,
/// SPEC edge case 5). Returns `true` when the clone succeeded.
@discardableResult
public func nativeCloneOrCopyFile(from source: URL, to destination: URL) throws -> Bool {
    let rc = source.path.withCString { src in
        destination.path.withCString { dst in
            clonefile(src, dst, 0)
        }
    }
    if rc == 0 { return true }
    try FileManager.default.copyItem(at: source, to: destination)
    return false
}
