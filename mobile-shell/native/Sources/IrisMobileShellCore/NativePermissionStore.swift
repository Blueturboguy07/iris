import Foundation

/// Per-app, per-capability remembered decisions for the Iris native shell.
///
/// Keyed by the app's stable namespace (`appId` + `projectId`, the same
/// identity `NativeRevisionStore` already uses), never by revision, so
/// installing an update keeps a person's earlier choice for a capability the
/// app already had. An update that declares a capability nobody has decided
/// for this app yet simply has no record, so the Host asks about that one
/// capability the next time it is actually used; every other, already
/// decided capability for that same app is untouched.
///
/// Persisted as one small JSON file inside the root the caller passes (the
/// app's own container; this type never resolves its own path). Writes are
/// atomic. Any file this type cannot read, or cannot make sense of, including
/// one a crash left partially written, is treated exactly like an empty
/// store: every decision reads back as `.notDecided`. A corrupted file must
/// never be read as `.granted` for anything; failing closed means asking
/// again, not granting silently.
public final class NativePermissionStore: @unchecked Sendable {
    private struct RecordKey: Hashable {
        let appId: String
        let projectId: String
        let capability: String
    }

    private struct StoredRecord: Codable, Equatable {
        let appId: String
        let projectId: String
        let capability: String
        let decision: NativePermissionDecision
    }

    private struct StoredFile: Codable, Equatable {
        let schemaVersion: Int
        let records: [StoredRecord]
    }

    private enum LoadFailure: Error {
        case unreadable
        case invalidShape
        case invalidRoot
    }

    private static let schemaVersion = 1
    // Generous relative to any realistic library size; this store holds one
    // small record per (app, capability) pair, never per revision or event.
    private static let maximumRecords = 4_096
    private static let maximumFileBytes = 256 * 1024
    private static let maximumCapabilityLength = 128
    private static let fileName = "permissions-v1.json"

    private let lock = NSLock()
    private let rootURL: URL
    private let fileManager: FileManager
    private var decisions: [RecordKey: NativePermissionDecision]

    /// Loads whatever is on disk immediately. Never throws: a missing,
    /// unreadable, or corrupted file is the same as an empty store, so every
    /// capability starts as `.notDecided` rather than blocking construction.
    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.decisions = Self.loadDecisions(rootURL: self.rootURL, fileManager: fileManager)
    }

    /// The remembered decision for one app and one capability. `.notDecided`
    /// covers "never asked", "the store file is missing", and "the store
    /// file could not be trusted" identically: the Host must still ask.
    public func decision(
        for capability: String,
        identity: NativeShellAppIdentity
    ) -> NativePermissionDecision {
        lock.lock()
        defer { lock.unlock() }
        return decisions[key(capability: capability, identity: identity)] ?? .notDecided
    }

    /// Records the person's choice for one app and one capability and writes
    /// it to disk before returning, so a crash immediately afterward cannot
    /// lose it. Setting `.notDecided` forgets any earlier choice (the same
    /// effect as "ask again next time").
    ///
    /// The mutation and its disk write happen under the same lock hold, not
    /// as two separate critical sections. Two concurrent callers (for
    /// example the Host's explicit "Allow"/"Don't allow" buttons racing the
    /// WebView's own first-use grant observer) must have their writes reach
    /// disk in the same order their mutations were applied; splitting the
    /// lock around only the in-memory update let an earlier call's stale
    /// snapshot land on disk after a later call's newer one, silently
    /// dropping the later decision until the next write happened to touch
    /// that same key again. A write that fails (for example the store is at
    /// `maximumRecords`) rolls the in-memory mutation back, so a decision
    /// this method could not persist is never read back as if it had been.
    @discardableResult
    public func setDecision(
        _ decision: NativePermissionDecision,
        for capability: String,
        identity: NativeShellAppIdentity
    ) throws -> NativePermissionDecision {
        guard NativeSecurity.isStableId(identity.appId), NativeSecurity.isStableId(identity.projectId) else {
            throw NativePermissionStoreError.invalidIdentity
        }
        guard (1...Self.maximumCapabilityLength).contains(capability.utf8.count) else {
            throw NativePermissionStoreError.invalidCapability
        }
        let recordKey = key(capability: capability, identity: identity)
        lock.lock()
        defer { lock.unlock() }
        let previous = decisions[recordKey]
        if decision == .notDecided {
            decisions.removeValue(forKey: recordKey)
        } else {
            decisions[recordKey] = decision
        }
        do {
            try Self.write(decisions, rootURL: rootURL, fileManager: fileManager)
        } catch {
            if let previous {
                decisions[recordKey] = previous
            } else {
                decisions.removeValue(forKey: recordKey)
            }
            throw error
        }
        return decision
    }

    /// Forgets one app's decision for one capability. Equivalent to
    /// `setDecision(.notDecided, ...)`, kept as its own name for the
    /// permissions screen's "ask again next time" action.
    public func forgetDecision(
        for capability: String,
        identity: NativeShellAppIdentity
    ) throws {
        try setDecision(.notDecided, for: capability, identity: identity)
    }

    /// Forgets every remembered decision for one app (RC-04, "Also delete my
    /// data" on Remove): a reinstalled app starts as if it had never asked.
    /// Written to disk before returning; a write that fails rolls the in-memory
    /// change back and throws, so a decision this could not remove is still
    /// read back as it was. Returns how many decisions were removed.
    @discardableResult
    public func forgetAllDecisions(for identity: NativeShellAppIdentity) throws -> Int {
        guard NativeSecurity.isStableId(identity.appId), NativeSecurity.isStableId(identity.projectId) else {
            throw NativePermissionStoreError.invalidIdentity
        }
        lock.lock()
        defer { lock.unlock() }
        let previous = decisions
        decisions = decisions.filter { $0.key.appId != identity.appId || $0.key.projectId != identity.projectId }
        let removed = previous.count - decisions.count
        guard removed > 0 else { return 0 }
        do {
            try Self.write(decisions, rootURL: rootURL, fileManager: fileManager)
        } catch {
            decisions = previous
            throw error
        }
        return removed
    }

    /// Every capability this app actually has a decision for (never
    /// `.notDecided`, since there is nothing to show or revoke there),
    /// ordered by capability for a stable list on the permissions screen.
    public func decidedCapabilities(
        for identity: NativeShellAppIdentity
    ) -> [(capability: String, decision: NativePermissionDecision)] {
        lock.lock()
        defer { lock.unlock() }
        return decisions.compactMap { recordKey, value in
            guard recordKey.appId == identity.appId, recordKey.projectId == identity.projectId else { return nil }
            return (recordKey.capability, value)
        }.sorted { $0.capability < $1.capability }
    }

    private func key(capability: String, identity: NativeShellAppIdentity) -> RecordKey {
        RecordKey(appId: identity.appId, projectId: identity.projectId, capability: capability)
    }

    // MARK: - Persistence

    private static func loadDecisions(
        rootURL: URL,
        fileManager: FileManager
    ) -> [RecordKey: NativePermissionDecision] {
        let url = rootURL.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try boundedRead(url, fileManager: fileManager)
            guard hasStrictShape(data) else { throw LoadFailure.invalidShape }
            let decoded = try JSONDecoder().decode(StoredFile.self, from: data)
            guard decoded.schemaVersion == schemaVersion, decoded.records.count <= maximumRecords else {
                throw LoadFailure.invalidShape
            }
            var result: [RecordKey: NativePermissionDecision] = [:]
            for record in decoded.records {
                guard NativeSecurity.isStableId(record.appId), NativeSecurity.isStableId(record.projectId),
                      record.decision != .notDecided else {
                    // A stored "notDecided" or an unstable identity could
                    // only come from a hand-edited or corrupted file; treat
                    // the whole file as untrustworthy rather than one row.
                    throw LoadFailure.invalidShape
                }
                result[RecordKey(appId: record.appId, projectId: record.projectId, capability: record.capability)]
                    = record.decision
            }
            return result
        } catch {
            // Any failure here, including a partially written file, is the
            // same as no file: every capability falls back to `.notDecided`.
            return [:]
        }
    }

    private static func write(
        _ decisions: [RecordKey: NativePermissionDecision],
        rootURL: URL,
        fileManager: FileManager
    ) throws {
        guard decisions.count <= maximumRecords else { throw NativePermissionStoreError.invalidStoreFile }
        try ensurePlainDirectory(rootURL, fileManager: fileManager)
        let url = rootURL.appendingPathComponent(fileName, isDirectory: false)
        try requirePlainRegularFileIfPresent(url, fileManager: fileManager)
        let records = decisions.keys.sorted { lhs, rhs in
            if lhs.appId != rhs.appId { return lhs.appId < rhs.appId }
            if lhs.projectId != rhs.projectId { return lhs.projectId < rhs.projectId }
            return lhs.capability < rhs.capability
        }.map { recordKey in
            StoredRecord(
                appId: recordKey.appId, projectId: recordKey.projectId,
                capability: recordKey.capability, decision: decisions[recordKey] ?? .notDecided
            )
        }
        let file = StoredFile(schemaVersion: schemaVersion, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(file)
        guard data.count <= maximumFileBytes else { throw NativePermissionStoreError.invalidStoreFile }
        try data.write(to: url, options: [.atomic])
    }

    private static func ensurePlainDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw NativePermissionStoreError.invalidRoot
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NativePermissionStoreError.invalidRoot
            }
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func requirePlainRegularFileIfPresent(_ url: URL, fileManager: FileManager) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw NativePermissionStoreError.invalidStoreFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw NativePermissionStoreError.invalidStoreFile
        }
    }

    private static func boundedRead(_ url: URL, fileManager: FileManager) throws -> Data {
        try requirePlainRegularFileIfPresent(url, fileManager: fileManager)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value <= UInt64(maximumFileBytes) else {
            throw LoadFailure.unreadable
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw LoadFailure.unreadable }
        return data
    }

    /// Rejects any JSON that decodes structurally but was never written by
    /// this type, for example a hand-edited file with an extra key. Checked
    /// before `JSONDecoder` so an unexpected shape is a load failure here,
    /// not a lenient decode that silently drops fields.
    private static func hasStrictShape(_ data: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: []),
              let root = value as? [String: Any],
              Set(root.keys) == ["schemaVersion", "records"],
              let records = root["records"] as? [Any]
        else { return false }
        return records.allSatisfy(hasStrictRecordShape)
    }

    private static func hasStrictRecordShape(_ value: Any) -> Bool {
        guard let record = value as? [String: Any] else { return false }
        return Set(record.keys) == ["appId", "projectId", "capability", "decision"]
            && record["appId"] is String && record["projectId"] is String
            && record["capability"] is String && record["decision"] is String
    }
}
