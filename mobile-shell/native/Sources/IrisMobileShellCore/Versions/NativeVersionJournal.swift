import Darwin
import Foundation

/// The in-flight pointer swap (SPEC section 2.3, 2.4). Absent when nothing is
/// in flight. `state/<appId>/<projectId>/journal.json`.
public struct NativeVersionJournal: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case activate, rollback, undo }
    public enum Phase: String, Codable, Sendable { case building, swapped }

    public let op: Op
    public let from: String?
    public let to: String
    public let startedAt: String
    public var phase: Phase

    public init(op: Op, from: String?, to: String, startedAt: String, phase: Phase) {
        self.op = op
        self.from = from
        self.to = to
        self.startedAt = startedAt
        self.phase = phase
    }
}

/// `state/<appId>/<projectId>/active.json`, unchanged shape from today's
/// `NativeRevisionStore.ActivePointer` so this module is a drop-in the
/// existing store can delegate to.
public struct NativeVersionActivePointer: Codable, Equatable, Sendable {
    public let currentRevisionId: String
    public let fallbackRevisionId: String?

    public init(currentRevisionId: String, fallbackRevisionId: String?) {
        self.currentRevisionId = currentRevisionId
        self.fallbackRevisionId = fallbackRevisionId
    }
}

public struct NativeVersionUndoOffer: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let kind: String
    public let at: String
}

public enum NativeVersionJournalError: Error, Equatable, Sendable {
    case stuck(String)
}

/// Reads and atomically writes the small per-app-project JSON state files
/// under `state/<appId>/<projectId>/`: `active.json`, `journal.json`,
/// `undo-offer.json`. Every write is "write to a temporary name, fsync,
/// rename" (SPEC 2.4), never an in-place edit.
public struct NativeVersionStateFiles: Sendable {
    public let root: URL // .../v1/state
    private var fileManager: FileManager { .default }

    public init(root: URL) throws {
        self.root = root
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func directory(appId: String, projectId: String) -> URL {
        root.appendingPathComponent(appId, isDirectory: true).appendingPathComponent(projectId, isDirectory: true)
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL, fault: NativeVersionFaultInjector, at point: NativeVersionCrashPoint) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        let tmp = url.deletingLastPathComponent().appendingPathComponent("tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        guard rename(tmp.path, url.path) == 0 else {
            let err = errno
            try? fileManager.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        try fault.fire(point)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: active.json

    public func readActive(appId: String, projectId: String) -> NativeVersionActivePointer? {
        read(NativeVersionActivePointer.self, from: directory(appId: appId, projectId: projectId).appendingPathComponent("active.json"))
    }

    public func writeActive(
        _ pointer: NativeVersionActivePointer,
        appId: String,
        projectId: String,
        fault: NativeVersionFaultInjector = .init()
    ) throws {
        try atomicWrite(
            pointer,
            to: directory(appId: appId, projectId: projectId).appendingPathComponent("active.json"),
            fault: fault,
            at: .journalWrite_afterPointerWrite
        )
    }

    // MARK: journal.json

    public func readJournal(appId: String, projectId: String) -> NativeVersionJournal? {
        read(NativeVersionJournal.self, from: directory(appId: appId, projectId: projectId).appendingPathComponent("journal.json"))
    }

    public func writeJournal(
        _ journal: NativeVersionJournal,
        appId: String,
        projectId: String,
        fault: NativeVersionFaultInjector = .init()
    ) throws {
        try atomicWrite(
            journal,
            to: directory(appId: appId, projectId: projectId).appendingPathComponent("journal.json"),
            fault: fault,
            at: .journalWrite_afterJournalWritten
        )
    }

    public func deleteJournal(appId: String, projectId: String) {
        try? fileManager.removeItem(at: directory(appId: appId, projectId: projectId).appendingPathComponent("journal.json"))
    }

    // MARK: undo-offer.json

    public func readUndoOffer(appId: String, projectId: String) -> NativeVersionUndoOffer? {
        read(NativeVersionUndoOffer.self, from: directory(appId: appId, projectId: projectId).appendingPathComponent("undo-offer.json"))
    }

    public func writeUndoOffer(_ offer: NativeVersionUndoOffer, appId: String, projectId: String, fault: NativeVersionFaultInjector = .init()) throws {
        try atomicWrite(
            offer,
            to: directory(appId: appId, projectId: projectId).appendingPathComponent("undo-offer.json"),
            fault: fault,
            at: .none
        )
    }

    public func clearUndoOffer(appId: String, projectId: String) {
        try? fileManager.removeItem(at: directory(appId: appId, projectId: projectId).appendingPathComponent("undo-offer.json"))
    }
}
