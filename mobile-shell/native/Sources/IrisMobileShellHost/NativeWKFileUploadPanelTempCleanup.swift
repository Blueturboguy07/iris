import Foundation
import IrisMobileShellCore

/// Real `FileManager` I/O on top of `NativeWKFileUploadPanelCleanupPolicy`'s
/// pure decision. See that type's doc comment for the background and the
/// safety invariant (name-prefix match only; a user's own file is never a
/// candidate).
///
/// Best-effort throughout: a failure reading or deleting a temp entry (an
/// unreadable volume, a permissions oddity, a race with WebKit itself still
/// writing) never throws and never blocks whatever caller triggered the
/// cleanup. A missed entry is caught by a later call (the next pick's own
/// cleanup, or the next app launch's orphan sweep), never lost track of
/// forever.
public enum NativeWKFileUploadPanelTempCleanup {
    /// Called once a picker session reaches a terminal state (finished,
    /// failed or cancelled) -- see `NativeMediaPickerSession.finish(_:)`.
    /// Deletes every `WKFileUploadPanel-*` entry created at or after
    /// `sessionStartedAt` (this session's own copies, proven safe: see
    /// `NativeWKFileUploadPanelCleanupPolicy.entriesToDelete`) and, as a
    /// backstop, any older one that already sits past the stale threshold
    /// (an orphan from an earlier session that never reached a terminal
    /// state, e.g. the app was killed mid-pick and never got to call this).
    @discardableResult
    public static func cleanupAfterPick(
        sessionStartedAt: Date,
        now: Date = Date(),
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        followUpDelay: TimeInterval = followUpDelaySeconds
    ) -> Int {
        let removed = deleteMatching(sessionStartedAt: sessionStartedAt, now: now, directory: directory, fileManager: fileManager)
        // WebKit writes its copy AFTER the shell hands the picked file over
        // (round3 M-longimport HANDOFF, lines 106-110), so for this pick the
        // copy usually does not exist yet when this runs. Look again once it
        // is old enough to be safe to sweep (the stale threshold), so the copy
        // is reclaimed without waiting for the next pick or the next launch.
        scheduleStaleFollowUp(after: followUpDelay, directory: directory, fileManager: fileManager)
        return removed
    }

    /// Seconds to wait before the follow-up sweep: just past the stale
    /// threshold, so a copy made right after the pick is old enough.
    public static let followUpDelaySeconds: TimeInterval = NativeWKFileUploadPanelCleanupPolicy.staleAfterSeconds + 5

    /// One later look for orphans, with the launch sweep's rule (only entries
    /// past the stale threshold are ever eligible, so a copy a NEWER pick made
    /// a minute ago is never touched). `completion` reports how many were
    /// removed and exists for tests. A process that is suspended when the
    /// timer is due simply runs it on the next wake; the launch sweep and the
    /// next pick's sweep remain the backstops.
    public static func scheduleStaleFollowUp(
        after delay: TimeInterval = followUpDelaySeconds,
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        queue: DispatchQueue = .global(qos: .utility),
        completion: (@Sendable (Int) -> Void)? = nil
    ) {
        queue.asyncAfter(deadline: .now() + delay) {
            let removed = sweepOrphans(directory: directory, fileManager: fileManager)
            completion?(removed)
        }
    }

    /// Called once at app launch, before any picker session exists this
    /// process. Only orphans (idle past the stale threshold) are ever
    /// eligible: passing `.distantFuture` as `sessionStartedAt` makes the
    /// same-session branch of the policy impossible to satisfy (nothing can
    /// have a creation date at or after the far future), so this can never
    /// delete an entry that is mid-write by a session this call knows
    /// nothing about.
    @discardableResult
    public static func sweepOrphans(
        now: Date = Date(),
        directory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        deleteMatching(sessionStartedAt: .distantFuture, now: now, directory: directory, fileManager: fileManager)
    }

    /// `directory` defaults to the real temp directory for every production
    /// call site above; tests pass a scratch directory instead so a test run
    /// can never read or delete anything outside its own fixture, real
    /// system temp-directory contents included.
    private static func deleteMatching(
        sessionStartedAt: Date,
        now: Date,
        directory tmp: URL,
        fileManager: FileManager
    ) -> Int {
        var removed = 0
        // The top level of tmp is where the Simulator run put these copies;
        // WebKit's own networking folder is scanned too, the same one the
        // FileSystemWritableStream cleanup reads (a verifier finding: a
        // cleanup that lists only the top level can miss WebKit's own files).
        var folders = [tmp]
        for nested in NativeWritableStreamStagingCleanup.nestedFolderNames {
            let folder = tmp.appendingPathComponent(nested, isDirectory: true)
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            folders.append(folder)
        }
        for folder in folders {
            removed += deleteMatching(in: folder, sessionStartedAt: sessionStartedAt, now: now, fileManager: fileManager)
        }
        return removed
    }

    private static func deleteMatching(
        in tmp: URL,
        sessionStartedAt: Date,
        now: Date,
        fileManager: FileManager
    ) -> Int {
        guard let items = try? fileManager.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        let entries: [NativeWKFileUploadPanelCleanupPolicy.Entry] = items.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(NativeWKFileUploadPanelCleanupPolicy.namePrefix) else { return nil }
            // An unreadable creation date is skipped, never treated as ancient:
            // "cannot tell how old it is" must not read as "old enough to delete".
            guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return nil }
            return .init(name: name, createdAt: created)
        }
        let toDelete = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: entries, sessionStartedAt: sessionStartedAt, now: now
        )
        var removed = 0
        for name in toDelete {
            if (try? fileManager.removeItem(at: tmp.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }
}
