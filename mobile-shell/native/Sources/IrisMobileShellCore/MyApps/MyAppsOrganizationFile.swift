import Darwin
import Foundation

// Unit MA1-organization-core. Atomic load and save of `my-apps.json`
// (SPEC 3.1), independent of `NativeVersionStateFiles` (owned by MV1's
// `Core/Versions/**`, frozen for this pass) so MyApps has no build-order or
// ownership coupling to it, even though the on-disk discipline is the same:
// write to a temporary name next to the target, `fsync`, `rename(2)`. A
// crash between those two steps leaves the previous file intact, because
// `rename` on the same volume is atomic; nothing here ever edits
// `my-apps.json` in place.

/// Injectable crash points for the mutation checks and MA5's fault world
/// (SPEC 5.2, 5.5 #4: "Non-atomic write, in place"). Production code always
/// runs with `.none`.
public enum MyAppsFileCrashPoint: String, Sendable, CaseIterable {
    case none
    /// After the temporary file is written and fsynced, before `rename`.
    case afterTempWriteBeforeRename
}

public struct MyAppsFileFaultInjector: Sendable {
    public struct Triggered: Error, Sendable {}

    public let point: MyAppsFileCrashPoint
    public init(point: MyAppsFileCrashPoint = .none) {
        self.point = point
    }

    func fire(_ candidate: MyAppsFileCrashPoint) throws {
        if point == candidate { throw Triggered() }
    }
}

public enum MyAppsOrganizationFileError: Error, Equatable, Sendable {
    case renameFailed(errno: Int32)
}

/// What `load()` found, so the caller can show SPEC 1.6's notice line
/// without re-deriving it from file-system state itself.
public struct MyAppsLoadResult: Equatable, Sendable {
    public let arrangement: MyAppsArrangement
    /// True when the file existed but did not parse as valid JSON of a
    /// version this reader understands as version 1 (SPEC 3.1: "A file that
    /// does not parse is renamed to `my-apps.json.bad`... the screen shows
    /// the notice"). False for "no file yet" (first launch), which is not
    /// an error.
    public let wasQuarantined: Bool
    /// True when the file parsed but declared a `version` newer than this
    /// reader understands (SPEC 3.1's forward-compatibility rule). The
    /// arrangement returned is `.empty` in this case; the caller keeps
    /// showing apps from the library/catalog only, never invents data.
    public let versionTooNew: Bool
}

/// Owns exactly one file, `<root>/my-apps.json`, plus its temp and
/// quarantine siblings. `root` is the coordinator's namespace root (SPEC
/// 3.1), passed in by the caller (MA2/the integrator); this type never
/// discovers it on its own, so fixture and acceptance namespaces get their
/// own copy automatically the same way `library.json` does.
public struct MyAppsOrganizationFile: Sendable {
    public let root: URL
    private var fileManager: FileManager { .default }

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public var fileURL: URL { root.appendingPathComponent("my-apps.json") }
    private var quarantineURL: URL { root.appendingPathComponent("my-apps.json.bad") }
    private var newerVersionURL: URL { root.appendingPathComponent("my-apps.json.v\(MyAppsArrangement.currentVersion)") }

    /// Deletes stray `my-apps.json.tmp-*` left by a crash before `rename`
    /// (SPEC 3.1: "the sweep on launch deletes `my-apps.json.tmp-*`"). Safe
    /// to call every launch; a missing directory or no matches is a no-op.
    public func sweepTemporaryFiles() {
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("my-apps.json.tmp-") {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// SPEC 3.1: "Reads: once at launch... then in memory." Call this once;
    /// the caller (MA2's store) keeps the result in memory afterward and
    /// only calls `save` on a change.
    public func load() -> MyAppsLoadResult {
        sweepTemporaryFiles()
        // A version-parked file from a newer shell takes priority: SPEC
        // 3.1's rule is "the shell writes to my-apps.json only when it read
        // a version it fully understands; otherwise it writes
        // my-apps.json.v1 and reads that one next time" -- meaning once
        // this reader has parked a too-new file, it keeps reading the
        // parked copy rather than silently falling back to the (stale)
        // main file on every subsequent launch.
        if let data = try? Data(contentsOf: newerVersionURL),
           let arrangement = try? JSONDecoder().decode(MyAppsArrangement.self, from: data),
           arrangement.version == MyAppsArrangement.currentVersion {
            return MyAppsLoadResult(arrangement: arrangement, wasQuarantined: false, versionTooNew: false)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            // No file yet: first launch, not an error.
            return MyAppsLoadResult(arrangement: .empty, wasQuarantined: false, versionTooNew: false)
        }

        guard let decoded = try? JSONDecoder().decode(MyAppsArrangement.self, from: data) else {
            quarantine()
            return MyAppsLoadResult(arrangement: .empty, wasQuarantined: true, versionTooNew: false)
        }

        if decoded.version > MyAppsArrangement.currentVersion {
            // KF-1 fix, part 2 (found by MA5's persona sweep after part 1
            // above): SPEC 3.1 says a version this reader does not fully
            // understand "is read for the fields it understands" -- not
            // discarded. `decoded` only reaches this branch after a
            // successful `JSONDecoder` decode, so every field this reader's
            // model knows about (folders, apps, collapsedGroups,
            // hintDismissed) already parsed correctly; only the `version`
            // number itself is newer than this reader recognizes. Returning
            // `.empty` here (the pre-fix behavior) silently dropped the
            // person's real folders and renames on every relaunch after a
            // version bump, which is exactly what the sweep's
            // "arrangement-lost"/"wrong-group"/"recents-wrong-order"
            // findings in the versionAhead phase were catching. The
            // in-memory `version` is stamped back down to
            // `currentVersion` because this reader only ever knows how to
            // produce version-1 documents: any save from here on writes to
            // the version-1 sidecar (`newerVersionURL`, part 1's fix above),
            // never claims to understand version 2 itself, and never writes
            // that claim back over the real newer file.
            var readable = decoded
            readable.version = MyAppsArrangement.currentVersion
            return MyAppsLoadResult(arrangement: readable, wasQuarantined: false, versionTooNew: true)
        }
        if decoded.version < 1 {
            quarantine()
            return MyAppsLoadResult(arrangement: .empty, wasQuarantined: true, versionTooNew: false)
        }
        return MyAppsLoadResult(arrangement: decoded, wasQuarantined: false, versionTooNew: false)
    }

    /// SPEC 3.1: "the bad file is kept aside as `my-apps.json.bad`... and
    /// never overwritten silently". "Kept aside" is a move, not a copy: the
    /// corrupt bytes leave `my-apps.json` entirely, so the next successful
    /// `save()` starts clean rather than racing the old corrupt content, and
    /// the main path never again round-trips through the bad bytes. Only the
    /// most recent bad file is kept, on purpose: the notice already tells
    /// the person once, and keeping every historical corruption is not the
    /// point. Mutation #11 ("a corrupt file overwritten with an empty
    /// arrangement") is guarded against precisely because this function
    /// never calls `save`: the corrupt bytes move sideways, they are never
    /// replaced by a freshly-encoded `.empty`.
    private func quarantine() {
        try? fileManager.removeItem(at: quarantineURL)
        _ = try? fileManager.moveItem(at: fileURL, to: quarantineURL)
    }

    /// SPEC 3.1: "Writes: coalesced, at most one write per 500 ms, always
    /// the whole document, always atomic." The 500 ms coalescing is the
    /// caller's job (a debounce timer in MA2's store, documented in
    /// HANDOFF.md); this function itself is the atomic primitive it debounces
    /// down to, called with the version this reader understands. A newer
    /// version than this reader's own is never written here (guarded by the
    /// type: `MyAppsArrangement.currentVersion` is baked into `.empty` and
    /// every mutation the reducer produces).
    @discardableResult
    public func save(_ arrangement: MyAppsArrangement, fault: MyAppsFileFaultInjector = .init()) throws -> Data {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(arrangement)

        // KF-1 fix (found by MA5's persona sweep, 36/36 reproductions): SPEC
        // 3.1 says a version this reader does not fully understand "is read
        // for the fields it understands and never written back over ...
        // otherwise it writes my-apps.json.v1 and reads that one next time".
        // `load()` already refuses to parse a too-new `fileURL` as version 1
        // and returns `.empty`, but until this fix `save()` still wrote its
        // (empty-derived) version-1 document straight to `fileURL` on the
        // very next ordinary save, permanently destroying the newer
        // document's folders. Guard against that here, independent of
        // whatever `load()` returned earlier in this process's lifetime, by
        // re-checking what is on disk right now: if `fileURL` currently
        // holds a version newer than this reader understands, redirect this
        // write to the version-1 sidecar (`newerVersionURL`, "my-apps.json.v1")
        // instead, leaving the newer main file untouched. `load()` already
        // prefers `newerVersionURL` over `fileURL` when its version matches
        // `currentVersion`, so a later launch reads this reader's own writes
        // back correctly without ever touching the parked newer document.
        var destination = fileURL
        if let existingData = try? Data(contentsOf: fileURL),
           let existingArrangement = try? JSONDecoder().decode(MyAppsArrangement.self, from: existingData),
           existingArrangement.version > MyAppsArrangement.currentVersion {
            destination = newerVersionURL
        }

        let tmp = root.appendingPathComponent("my-apps.json.tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        // `.atomic` above already does a temp-write-then-rename internally
        // for the tmp file itself; the fsync we care about is on that tmp
        // file before *our* rename onto the destination, so re-open and sync
        // it explicitly rather than relying on `.atomic`'s internal one.
        if let handle = FileHandle(forWritingAtPath: tmp.path) {
            handle.synchronizeFile()
            try? handle.close()
        }
        do {
            try fault.fire(.afterTempWriteBeforeRename)
        } catch {
            // Simulated crash: leave the tmp file for the next launch's
            // sweep to clean up, exactly as a real crash would, and do NOT
            // touch the destination file. The previous file stays intact.
            throw error
        }
        guard rename(tmp.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: tmp)
            throw MyAppsOrganizationFileError.renameFailed(errno: code)
        }
        return data
    }
}
