import Foundation
import CryptoKit
import Darwin

extension DeliveredEditUndoRecoveryStore {
    enum ArchivedProtection: Equatable, Sendable {
        case clear
        case affected(archivePaths: [String])
        case unknownTargets(archivePaths: [String])

        var blocksChanges: Bool { self != .clear }
        var archivePaths: [String] {
            switch self {
            case .clear: return []
            case .affected(let paths), .unknownTargets(let paths): return paths
            }
        }
    }

    struct ArchivedRecoveryInventory: Sendable {
        let records: [DeliveredEditUndoRecoveryRecord]
        let archivePaths: [String]
        let hasUnknownTargets: Bool
    }

    struct ArchiveReceipt: Sendable {
        fileprivate let archiveURL: URL
        fileprivate let bytes: Data
        var path: String { archiveURL.path }
    }

    var archiveDirectoryURL: URL {
        recordURL.deletingLastPathComponent().appendingPathComponent("delivered-undo-archives")
    }

    /// Publish a byte-for-byte record before clearing anything. The content
    /// address makes a retry after a crash reuse the same evidence file.
    func archiveBeforeStopping() throws -> ArchiveReceipt {
        let bytes = try boundedRegularFile(recordURL)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let archiveURL = archiveDirectoryURL.appendingPathComponent(digest + ".json")
        try FileManager.default.createDirectory(at: archiveDirectoryURL, withIntermediateDirectories: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveDirectoryURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.invalidRecord }
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            guard try boundedRegularFile(archiveURL) == bytes else { throw StoreError.recordChanged }
        } else {
            let temporary = archiveDirectoryURL.appendingPathComponent(".staging-" + UUID().uuidString)
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
            guard descriptor >= 0 else { throw StoreError.synchronizationFailed }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); _ = unlink(temporary.path) }
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            // link publishes exclusively. A partial staging file never becomes an archive.
            if link(temporary.path, archiveURL.path) != 0 {
                guard try boundedRegularFile(archiveURL) == bytes else { throw StoreError.recordChanged }
            }
        }
        try synchronizeArchiveDirectory()
        guard try boundedRegularFile(archiveURL) == bytes else { throw StoreError.recordChanged }
        let parentDescriptor = open(recordURL.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        guard parentDescriptor >= 0 else { throw StoreError.synchronizationFailed }
        defer { close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else { throw StoreError.synchronizationFailed }
        return ArchiveReceipt(archiveURL: archiveURL, bytes: bytes)
    }

    /// Idempotent after archival. A changed or corrupt active marker is never
    /// discarded unless these exact bytes have already been archived.
    func clearActiveAfterArchival(_ receipt: ArchiveReceipt) throws {
        guard receipt.archiveURL.deletingLastPathComponent() == archiveDirectoryURL,
              try boundedRegularFile(receipt.archiveURL) == receipt.bytes else { throw StoreError.recordChanged }
        try synchronizeArchiveDirectory()
        if load() != .absent {
            guard try boundedRegularFile(recordURL) == receipt.bytes else { throw StoreError.recordChanged }
            guard unlink(recordURL.path) == 0 else { throw StoreError.recordChanged }
        }
        let descriptor = open(recordURL.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.synchronizationFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StoreError.synchronizationFailed }
    }

    func archivedRecoveryInventory() -> ArchivedRecoveryInventory {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: archiveDirectoryURL.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.invalidRecord }
            let files = try FileManager.default.contentsOfDirectory(at: archiveDirectoryURL, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".staging-") }
            guard files.count <= 1024 else { throw StoreError.invalidRecord }
            var records: [DeliveredEditUndoRecoveryRecord] = []
            var unknown = false
            for file in files {
                guard let bytes = try? boundedRegularFile(file),
                      let record = try? JSONDecoder().decode(DeliveredEditUndoRecoveryRecord.self, from: bytes),
                      record.isValid else { unknown = true; continue }
                records.append(record)
            }
            return ArchivedRecoveryInventory(records: records, archivePaths: files.map(\.path).sorted(), hasUnknownTargets: unknown)
        } catch {
            let failure = error as NSError
            let absent = failure.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code)
            return ArchivedRecoveryInventory(records: [], archivePaths: absent ? [] : [archiveDirectoryURL.path], hasUnknownTargets: !absent)
        }
    }

    func archivedProtection(appSlug: String? = nil, paths: [String] = []) -> ArchivedProtection {
        let inventory = archivedRecoveryInventory()
        if inventory.hasUnknownTargets { return .unknownTargets(archivePaths: inventory.archivePaths) }
        let candidates = paths.flatMap(Self.archivePathIdentities)
        let affected = inventory.records.contains { record in
            if let appSlug, record.appSlug == appSlug { return true }
            return record.paths.flatMap(Self.archivePathIdentities).contains { protected in
                candidates.contains { candidate in
                    candidate == "/" || protected == "/" || candidate == protected
                        || candidate.hasPrefix(protected + "/") || protected.hasPrefix(candidate + "/")
                }
            }
        }
        return affected ? .affected(archivePaths: inventory.archivePaths) : .clear
    }

    private static func archivePathIdentities(_ path: String) -> [String] {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL
        return [lexical.path, lexical.resolvingSymlinksInPath().path]
    }

    private func boundedRegularFile(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.invalidRecord }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size <= 32_768 else { throw StoreError.invalidRecord }
        let bytes = try handle.read(upToCount: 32_769) ?? Data()
        guard bytes.count <= 32_768, bytes.count == attributes.st_size else { throw StoreError.invalidRecord }
        return bytes
    }

    private func synchronizeArchiveDirectory() throws {
        let descriptor = open(archiveDirectoryURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.synchronizationFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw StoreError.synchronizationFailed }
    }
}
