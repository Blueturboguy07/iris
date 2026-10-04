import Foundation

/// Pure decision logic for cleaning up WebKit's own per-pick temp copies.
///
/// Background (`docs/plans/20260928-all-routes/NATIVE_RUNS.md`, "Side
/// finding", and `kneecap-bugpass/INTEGRATION_HOOKS.md` H3): every time the
/// shell hands a picked file to the web view's native file-input response,
/// WebKit itself (not this app's own code) writes a full temp copy into the
/// app's own `NSTemporaryDirectory()` under a name starting with
/// `WKFileUploadPanel-`. WebKit never deletes these on its own; 21 copies
/// (3.5 GB) were observed accumulating during one Simulator import matrix
/// session. This is a real, unbounded disk leak on a device with sharply
/// limited free space (`NativeMediaImportPolicy`'s whole free-space model
/// depends on the device actually having the space it thinks it has).
///
/// This type only decides which directory-entry names are safe to delete;
/// it does no file I/O itself (see `NativeWKFileUploadPanelTempCleanup` in
/// the Host module for the actual `FileManager` calls), so it can be unit
/// tested without a real filesystem, a real `WKWebView`, or a real picker.
///
/// Safety invariant, load-bearing: **an entry is only ever a deletion
/// candidate when its name matches WebKit's own `WKFileUploadPanel-` prefix
/// exactly.** A user's own file (in Photos, in Documents, in iCloud, or
/// anywhere else) never carries this prefix and is never touched by this
/// policy, regardless of its age. This mirrors the same "clear only what we
/// can prove belongs to a finished pick" rule
/// `NativeSelectedMediaLease`'s own crash-reaper already applies to lease
/// directories.
public enum NativeWKFileUploadPanelCleanupPolicy {
    /// WebKit's own fixed naming for this per-pick temp copy. Never
    /// constructed by this app's code; only ever observed and matched.
    public static let namePrefix = "WKFileUploadPanel-"

    /// How long an entry with no live session to attribute it to (an app
    /// killed mid-pick, a crash, a session this process never started) must
    /// sit idle before it is swept as an orphan. Well past any real pick
    /// (even the slowest healthy iCloud download-and-handoff observed in
    /// this round's harness runs was under a few minutes), short enough that
    /// a genuinely stuck device does not accumulate space for long.
    public static let staleAfterSeconds: TimeInterval = 15 * 60

    /// One directory entry as this policy needs to see it: WebKit's own
    /// creation timestamp for it (`NSTemporaryDirectory()`'s entries carry a
    /// real `.creationDate`; a missing/unreadable date is treated as
    /// "as old as possible", the conservative direction for a stale-orphan
    /// sweep and the non-deleting direction for a same-session sweep).
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let createdAt: Date

        public init(name: String, createdAt: Date) {
            self.name = name
            self.createdAt = createdAt
        }
    }

    /// Which entries (by name) are safe to delete right now.
    ///
    /// Two independent reasons an entry qualifies, either is sufficient:
    /// 1. **Same-session proof.** `createdAt >= sessionStartedAt`: WebKit can
    ///    only have created this entry after this picker session began, so
    ///    it can only belong to the pick that just reached a terminal state
    ///    (finished, failed or cancelled) when this function is called from
    ///    `NativeMediaPickerSession.finish(_:)`. This is a real proof, not a
    ///    guess: nothing else in this app creates `WKFileUploadPanel-*`
    ///    entries, and a new session could not have started before this one
    ///    called `finish`.
    /// 2. **Orphan sweep.** `now - createdAt >= staleAfterSeconds`: old
    ///    enough that it cannot belong to any session that is still
    ///    legitimately in progress; it is left over from a session that
    ///    never reached a terminal state at all (the app was killed or
    ///    crashed mid-pick). Used both at app launch (see
    ///    `NativeWKFileUploadPanelTempCleanup.sweepOrphans`, called with no
    ///    live session, so only this branch can ever fire there) and as a
    ///    backstop during an ordinary same-session cleanup.
    ///
    /// Every candidate must also match `namePrefix`; nothing else is ever
    /// considered, so a caller cannot widen this by passing the wrong
    /// entries in (the Host wrapper only ever lists entries that already
    /// passed this same prefix check before constructing `Entry`, but the
    /// check is repeated here too so this function is safe standalone).
    public static func entriesToDelete(
        in entries: [Entry],
        sessionStartedAt: Date,
        now: Date,
        staleAfterSeconds: TimeInterval = NativeWKFileUploadPanelCleanupPolicy.staleAfterSeconds
    ) -> [String] {
        entries.compactMap { entry -> String? in
            guard entry.name.hasPrefix(namePrefix) else { return nil }
            if entry.createdAt >= sessionStartedAt { return entry.name }
            if now.timeIntervalSince(entry.createdAt) >= staleAfterSeconds { return entry.name }
            return nil
        }
    }
}
