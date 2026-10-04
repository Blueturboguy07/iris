import Foundation
import SQLite3

/// Reference counts for the object store (SPEC section 2.2, 2.5): `refs.sqlite`
/// maps an object's sha256 to the number of manifests that list it, plus its
/// allocated byte count for fast measurement without re-stat'ing every object.
/// An `actor` because SQLite's C handle is not itself safe for concurrent use;
/// every call below is already serialized by actor isolation.
public enum NativeVersionRefsError: Error, Equatable, Sendable {
    case openFailed(String)
    case statementFailed(String)
}

public actor NativeVersionRefs {
    public let databaseURL: URL // .../v1/gc/refs.sqlite
    public let dirtyMarkerURL: URL // .../v1/gc/dirty
    private var db: OpaquePointer?
    nonisolated(unsafe) private let fileManager = FileManager.default

    public init(root: URL) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        self.databaseURL = root.appendingPathComponent("refs.sqlite")
        self.dirtyMarkerURL = root.appendingPathComponent("dirty")
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw NativeVersionRefsError.openFailed(String(cString: sqlite3_errmsg(handle)))
        }
        self.db = handle
        var errmsg: UnsafeMutablePointer<Int8>?
        let createSQL = """
        CREATE TABLE IF NOT EXISTS objects (
            sha256 TEXT PRIMARY KEY,
            refcount INTEGER NOT NULL,
            bytes INTEGER NOT NULL,
            firstSeen TEXT NOT NULL
        );
        """
        let status = sqlite3_exec(handle, createSQL, nil, nil, &errmsg)
        if status != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errmsg)
            guard status == SQLITE_CORRUPT || status == SQLITE_NOTADB else {
                sqlite3_close(handle)
                self.db = nil
                throw NativeVersionRefsError.statementFailed(message)
            }
            // Only the rebuildable index is quarantined, never a manifest,
            // checkout or reader data. The dirty marker lands first so a
            // process death at any later step rebuilds from the kept manifests.
            try Data().write(to: dirtyMarkerURL, options: .atomic)
            sqlite3_close(handle)
            self.db = nil
            let quarantine = root.appendingPathComponent("refs-unreadable-\(UUID().uuidString).sqlite")
            try fileManager.moveItem(at: databaseURL, to: quarantine)
            var replacement: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &replacement) == SQLITE_OK, let replacement else {
                if let replacement { sqlite3_close(replacement) }
                throw NativeVersionRefsError.openFailed(databaseURL.path)
            }
            self.db = replacement
            var replacementError: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(replacement, createSQL, nil, nil, &replacementError) == SQLITE_OK else {
                let reason = replacementError.map { String(cString: $0) } ?? "index rebuild failed"
                sqlite3_free(replacementError)
                throw NativeVersionRefsError.statementFailed(reason)
            }
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: Dirty marker

    /// Written before object step 2 of stage (SPEC 2.2 step 3): if the
    /// process dies after a manifest rename but before the refs commit, the
    /// marker survives and the next launch rebuilds refs from every manifest
    /// instead of trusting a possibly-short count.
    public func markDirty() throws {
        try Data().write(to: dirtyMarkerURL, options: .atomic)
    }

    public func clearDirty() {
        try? fileManager.removeItem(at: dirtyMarkerURL)
    }

    public func isDirty() -> Bool {
        fileManager.fileExists(atPath: dirtyMarkerURL.path)
    }

    // MARK: Reads

    public func count(sha256 hex: String) throws -> Int {
        let stmt = try prepare("SELECT refcount FROM objects WHERE sha256 = ?;")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, hex)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func allCounts() throws -> [String: Int] {
        let stmt = try prepare("SELECT sha256, refcount FROM objects;")
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sha = String(cString: sqlite3_column_text(stmt, 0))
            result[sha] = Int(sqlite3_column_int64(stmt, 1))
        }
        return result
    }

    public func totalReferencedObjects() throws -> Int {
        try allCounts().count
    }

    // MARK: Writes

    /// Increments every object a manifest lists, in one transaction (SPEC
    /// 2.2 step 3: "Increment refs for its objects (one SQLite transaction)").
    /// A fault fired mid-way leaves a partial commit that never lands
    /// (SQLite rolls the transaction back), which is exactly why the caller
    /// also writes `gc/dirty` before this runs: an aborted transaction here
    /// under-counts, and the dirty marker's rebuild recovers the true count.
    public func incrementAll(
        sha256Hexes: [String: Int], // sha256 -> bytes
        now: () -> String = { NativeVersionRefs.iso(Date()) },
        fault: NativeVersionFaultInjector = .init()
    ) throws {
        guard !sha256Hexes.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            let insert = try prepare("""
            INSERT INTO objects (sha256, refcount, bytes, firstSeen) VALUES (?, 1, ?, ?)
            ON CONFLICT(sha256) DO UPDATE SET refcount = refcount + 1;
            """)
            let timestamp = now()
            for (sha, bytes) in sha256Hexes {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bind(insert, 1, sha)
                sqlite3_bind_int64(insert, 2, Int64(bytes))
                bind(insert, 3, timestamp)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    sqlite3_finalize(insert)
                    throw NativeVersionRefsError.statementFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            sqlite3_finalize(insert)
            try fault.fire(.manifestWrite_afterRefsCommit)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Decrements every object a manifest lists; returns the objects whose
    /// count reached zero (collectable). Never called by "delete a referenced
    /// object" logic directly, callers are expected to actually delete the
    /// returned objects from the object store as part of the same operation
    /// (mutation check 1 in HANDOFF.md is exactly "call this, then skip the
    /// object deletion", i.e. drop the decrement's effect on disk).
    @discardableResult
    public func decrementAll(sha256Hexes: [String]) throws -> [String] {
        guard !sha256Hexes.isEmpty else { return [] }
        try exec("BEGIN IMMEDIATE;")
        var zeroed: [String] = []
        do {
            let update = try prepare("UPDATE objects SET refcount = refcount - 1 WHERE sha256 = ? AND refcount > 0;")
            let select = try prepare("SELECT refcount FROM objects WHERE sha256 = ?;")
            for sha in sha256Hexes {
                sqlite3_reset(update)
                sqlite3_clear_bindings(update)
                bind(update, 1, sha)
                guard sqlite3_step(update) == SQLITE_DONE else {
                    sqlite3_finalize(update)
                    sqlite3_finalize(select)
                    throw NativeVersionRefsError.statementFailed(String(cString: sqlite3_errmsg(db)))
                }
                // Only a decrement that actually landed can have "reached
                // zero". A row already at zero (a repeat decrement) changes
                // nothing and must not be reported collectable a second time.
                guard sqlite3_changes(db) > 0 else { continue }
                sqlite3_reset(select)
                sqlite3_clear_bindings(select)
                bind(select, 1, sha)
                if sqlite3_step(select) == SQLITE_ROW, sqlite3_column_int64(select, 0) == 0 {
                    zeroed.append(sha)
                }
            }
            sqlite3_finalize(update)
            sqlite3_finalize(select)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return zeroed
    }

    /// Removes rows whose refcount is zero (after their objects are actually
    /// deleted from disk).
    public func pruneZeroed(sha256Hexes: [String]) throws {
        guard !sha256Hexes.isEmpty else { return }
        let stmt = try prepare("DELETE FROM objects WHERE sha256 = ? AND refcount <= 0;")
        defer { sqlite3_finalize(stmt) }
        for sha in sha256Hexes {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bind(stmt, 1, sha)
            _ = sqlite3_step(stmt)
        }
    }

    /// Rebuilds the whole table from every manifest across every app,
    /// destructively (SPEC 2.4: "if gc/dirty exists, rebuild refs.sqlite from
    /// the manifests and remove the marker"; also run after migration and by
    /// the mark-and-sweep verifier). `bytesForObject` supplies the allocated
    /// byte count (normally `NativeObjectStore.allocatedBytes`).
    public func rebuild(
        from manifests: [NativeVersionManifest],
        bytesForObject: (String) throws -> Int,
        now: () -> String = { NativeVersionRefs.iso(Date()) }
    ) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("DELETE FROM objects;")
            let insert = try prepare("""
            INSERT INTO objects (sha256, refcount, bytes, firstSeen) VALUES (?, 1, ?, ?)
            ON CONFLICT(sha256) DO UPDATE SET refcount = refcount + 1;
            """)
            let timestamp = now()
            // One stat per distinct object, not one per manifest entry: the
            // same object is listed by many versions.
            var bytesCache: [String: Int] = [:]
            for manifest in manifests {
                // Independent-verifier fix: one increment per DISTINCT
                // object this manifest references, not one per file entry.
                // A manifest with two files sharing identical content used
                // to double-count here, inflating the rebuilt refcount above
                // what `incrementAll` (one increment per manifest per unique
                // object) would ever produce for the same manifest -- a
                // storage leak (the object never reaches zero refs, so
                // "Free up space" can never reclaim it) that also disagreed
                // with `NativeVersionGC.free`'s now-deduped decrement.
                var seenInThisManifest = Set<String>()
                for file in manifest.files {
                    guard seenInThisManifest.insert(file.sha256).inserted else { continue }
                    let bytes: Int
                    if let cached = bytesCache[file.sha256] {
                        bytes = cached
                    } else {
                        bytes = (try? bytesForObject(file.sha256)) ?? file.bytes
                        bytesCache[file.sha256] = bytes
                    }
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    bind(insert, 1, file.sha256)
                    sqlite3_bind_int64(insert, 2, Int64(bytes))
                    bind(insert, 3, timestamp)
                    guard sqlite3_step(insert) == SQLITE_DONE else {
                        sqlite3_finalize(insert)
                        throw NativeVersionRefsError.statementFailed(String(cString: sqlite3_errmsg(db)))
                    }
                }
            }
            sqlite3_finalize(insert)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        clearDirty()
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(errmsg)
            throw NativeVersionRefsError.statementFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NativeVersionRefsError.statementFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    public static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
