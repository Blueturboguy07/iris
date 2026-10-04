import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Cleanup of WebKit's own `FileSystemWritableStream*` staging files in the
/// app's temporary directory (round 5, G12).
///
/// Background: when a web app writes through the File System Access API
/// (`createWritable()`), WebKit stages the bytes in a temp file named
/// `FileSystemWritableStream...` under `NSTemporaryDirectory()` and moves it
/// into place on close. A write that is aborted, or a process that is killed
/// mid-write, leaves the staging file behind, and WebKit never sweeps them.
/// About 1.5 GB built up in the Simulator across the import matrix, on a
/// phone whose free space is the scarce resource every import decision reads.
///
/// What this type will and will not delete. It is deliberately narrower than
/// "everything that looks like temp":
/// - A candidate is a REGULAR FILE directly inside the temp directory, or
///   directly inside `tmp/com.apple.WebKit.Networking/` (where WebKit really
///   puts them, see `nestedFolderNames`), whose
///   name starts with the exact prefix `FileSystemWritableStream`. A symlink,
///   a directory, or any other name (the web app's own storage, the user's
///   files, the picker leases, WebKit's `WKFileUploadPanel-*` copies that
///   `NativeWKFileUploadPanelCleanupPolicy` owns) is never a candidate.
/// - Two independent proofs make a candidate safe, either is enough:
///   1. It was created BEFORE this process launched. Only an earlier launch
///      could have created it, and that launch's web content processes died
///      with it, so nothing can still be writing it.
///   2. It has been idle (not modified) for `idleSeconds` (30 minutes) AND it
///      was created before `referenceStart`, the start of the import or
///      session that just finished. A file created during the current import
///      is never touched by proof 2, so a slow write that belongs to a
///      still-running page is not cut off. "Not open" cannot be read from
///      inside the sandbox, so an idle window is the proxy: a live stream
///      that has not written a byte in 30 minutes is treated as abandoned.
/// - Best effort: nothing here throws, and one undeletable file never stops
///   the rest of the sweep. A file missed now is caught by a later call.
public enum NativeWritableStreamStagingCleanup {
    public static let namePrefix = "FileSystemWritableStream"
    public static let idleSeconds: TimeInterval = 30 * 60

    public struct Entry: Sendable, Equatable {
        public let name: String
        public let createdAt: Date
        public let modifiedAt: Date

        public init(name: String, createdAt: Date, modifiedAt: Date) {
            self.name = name
            self.createdAt = createdAt
            self.modifiedAt = modifiedAt
        }
    }

    /// The pure decision: which of these entries are safe to delete.
    public static func entriesToDelete(
        in entries: [Entry],
        processLaunchedAt: Date,
        referenceStart: Date,
        now: Date,
        idleSeconds: TimeInterval = NativeWritableStreamStagingCleanup.idleSeconds
    ) -> [String] {
        entries.compactMap { entry -> String? in
            guard entry.name.hasPrefix(namePrefix) else { return nil }
            if entry.createdAt < processLaunchedAt { return entry.name }
            let idle = now.timeIntervalSince(entry.modifiedAt) >= idleSeconds
            if idle && entry.createdAt < referenceStart { return entry.name }
            return nil
        }
    }

    /// The subfolders of the temp directory where WebKit's network process
    /// really puts these files. Read from the only evidence on disk: the
    /// Simulator container held `tmp/com.apple.WebKit.Networking/
    /// FileSystemWritableStreamazvI3G` (a regular file, 154,686 bytes), and the
    /// Kneecap bug pass placed its 1.5 GB pile in the same folder. The top
    /// level of tmp is still scanned too (an earlier WebKit layout). Only these
    /// exact one-level names are scanned; nothing is walked recursively.
    public static let nestedFolderNames: [String] = ["com.apple.WebKit.Networking"]

    /// Lists `directory` and each folder in `nestedFolderNames` directly under
    /// it, decides, deletes. Returns how many files were removed.
    /// `referenceStart` is the start of the import or session that just ended;
    /// pass `.distantPast` (as the launch sweep does) so only proof 1 can fire.
    /// A nested folder that is a symlink, or is not a directory, is skipped.
    @discardableResult
    public static func sweep(
        directory: URL = FileManager.default.temporaryDirectory,
        processLaunchedAt: Date = currentProcessLaunchedAt(),
        referenceStart: Date,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        var removed = sweepOne(
            directory: directory, processLaunchedAt: processLaunchedAt,
            referenceStart: referenceStart, now: now, fileManager: fileManager
        )
        for nested in nestedFolderNames {
            let folder = directory.appendingPathComponent(nested, isDirectory: true)
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            removed += sweepOne(
                directory: folder, processLaunchedAt: processLaunchedAt,
                referenceStart: referenceStart, now: now, fileManager: fileManager
            )
        }
        return removed
    }

    private static func sweepOne(
        directory: URL,
        processLaunchedAt: Date,
        referenceStart: Date,
        now: Date,
        fileManager: FileManager
    ) -> Int {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var entries: [Entry] = []
        for url in items {
            let name = url.lastPathComponent
            guard name.hasPrefix(namePrefix) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // An unreadable date reads as "just now": the non-deleting direction.
            let created = values.creationDate ?? now
            let modified = values.contentModificationDate ?? now
            entries.append(Entry(name: name, createdAt: created, modifiedAt: modified))
        }
        var removed = 0
        for name in entriesToDelete(in: entries, processLaunchedAt: processLaunchedAt, referenceStart: referenceStart, now: now) {
            if (try? fileManager.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// When this process started, from the kernel, so a sweep that runs late
    /// in the launch still knows which files an earlier launch left behind.
    /// Falls back to "now" (the non-deleting direction for proof 1) if the
    /// kernel call fails.
    public static func currentProcessLaunchedAt() -> Date {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 {
            let start = info.kp_proc.p_un.__p_starttime
            return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        }
        #endif
        return Date()
    }
}
