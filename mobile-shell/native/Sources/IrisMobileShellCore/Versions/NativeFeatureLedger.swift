import Darwin
import Foundation

/// One row per version ever seen (SPEC 2.1, 2.6): `state/<appId>/<projectId>/
/// features.json`, ~300 bytes per row, appended by stage and by activate/
/// rollback/undo, never pruned (a freed version keeps its row).
public struct NativeFeatureLedgerRow: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case added, removed, restored, updated }

    public let title: String
    public let kind: Kind
    public let createdAt: String
    public let revisionId: String
    public var undoneAt: String?
    public var stoppedBeforeFinishing: Bool

    public init(
        title: String,
        kind: Kind,
        createdAt: String,
        revisionId: String,
        undoneAt: String? = nil,
        stoppedBeforeFinishing: Bool = false
    ) {
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.revisionId = revisionId
        self.undoneAt = undoneAt
        self.stoppedBeforeFinishing = stoppedBeforeFinishing
    }
}

/// Appends are read-modify-write-whole-file (the file is a few hundred rows
/// at 50 versions, well under the budget in section 3.2), written with the
/// same temp-fsync-rename pattern as every other state file so a crash mid
/// append never corrupts earlier rows.
public struct NativeFeatureLedger: Sendable {
    public let root: URL // .../v1/state
    private var fileManager: FileManager { .default }

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(appId: String, projectId: String) -> URL {
        root.appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("features.json")
    }

    public func rows(appId: String, projectId: String) -> [NativeFeatureLedgerRow] {
        let url = fileURL(appId: appId, projectId: projectId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NativeFeatureLedgerRow].self, from: data)) ?? []
    }

    private func write(_ rows: [NativeFeatureLedgerRow], appId: String, projectId: String) throws {
        let url = fileURL(appId: appId, projectId: projectId)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rows)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? fileManager.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
    }

    @discardableResult
    public func append(_ row: NativeFeatureLedgerRow, appId: String, projectId: String) throws -> [NativeFeatureLedgerRow] {
        var current = rows(appId: appId, projectId: projectId)
        current.append(row)
        try write(current, appId: appId, projectId: projectId)
        return current
    }

    /// Marks the most recent not-yet-undone row for `revisionId` as undone
    /// (Undo, section 1.2).
    public func markUndone(revisionId: String, at timestamp: String, appId: String, projectId: String) throws {
        var current = rows(appId: appId, projectId: projectId)
        guard let index = current.lastIndex(where: { $0.revisionId == revisionId && $0.undoneAt == nil }) else { return }
        current[index].undoneAt = timestamp
        try write(current, appId: appId, projectId: projectId)
    }

    public func markStoppedBeforeFinishing(revisionId: String, appId: String, projectId: String) throws {
        var current = rows(appId: appId, projectId: projectId)
        guard let index = current.lastIndex(where: { $0.revisionId == revisionId }) else { return }
        current[index].stoppedBeforeFinishing = true
        try write(current, appId: appId, projectId: projectId)
    }
}
