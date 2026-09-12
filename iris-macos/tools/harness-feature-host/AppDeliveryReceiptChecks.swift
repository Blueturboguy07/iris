import Foundation
@testable import IrisHarnessNative

private enum AppDeliveryReceiptCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Standalone checks for the durable delivery metadata seam. All writes are
/// below one disposable lab fixture; no installed app or default profile is
/// read, launched, or changed.
@main
struct AppDeliveryReceiptChecks {
    static func main() throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("iris-delivery-receipt-parent-" + UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("delivery-receipt-check-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parent) }

        var groups = 0
        try checkRestartAndTransitions(root: root); groups += 1
        try checkConcurrentTransitionSerialization(root: root); groups += 1
        try checkCollisionAndFailedWrite(root: root); groups += 1
        try checkMalformedAndBoundedLoads(root: root); groups += 1
        try checkIdentityAndPhaseRejection(root: root); groups += 1
        print("APP DELIVERY RECEIPT CHECKS PASS: \(groups) groups")
    }

    private static func receipt(root: URL, identifier: UUID = UUID()) -> AppDeliveryReceipt {
        AppDeliveryReceipt(
            identifier: identifier,
            bundleIdentifier: "com.fixture.receipt",
            installedPath: root.appendingPathComponent("installed/Receipt.app").path,
            sourceArtifactPath: root.appendingPathComponent("clone/release/Receipt.app").path,
            backupPath: root.appendingPathComponent("backups/\(identifier.uuidString)/Receipt.app").path,
            startedAt: Date(timeIntervalSince1970: 1_725_000_000)
        )
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppDeliveryReceiptCheckError.failed(message) }
    }

    private static func expectError(
        _ expected: AppDeliveryReceiptStore.StoreError,
        _ operation: () throws -> Void,
        _ message: String
    ) throws {
        do {
            try operation()
            throw AppDeliveryReceiptCheckError.failed(message + " did not throw")
        } catch let error as AppDeliveryReceiptStore.StoreError {
            try require(error == expected, message + " threw \(error), expected \(expected)")
        }
    }

    private static func checkRestartAndTransitions(root: URL) throws {
        let base = root.appendingPathComponent("restart/receipts", isDirectory: true)
        let firstStore = AppDeliveryReceiptStore(baseDirectory: base)
        let original = receipt(root: root)
        try firstStore.savePrepared(original)

        // A new store instance models an Iris restart. Prepared is explicit and
        // never inferred as installed merely because a receipt exists.
        let restarted = AppDeliveryReceiptStore(baseDirectory: base)
        guard case .valid(let prepared) = restarted.load(original.identifier) else {
            throw AppDeliveryReceiptCheckError.failed("prepared receipt did not survive restart")
        }
        try require(prepared.phase == .prepared, "restart changed prepared phase")
        let installed = try restarted.transition(prepared, to: .installed)
        let afterInstall = AppDeliveryReceiptStore(baseDirectory: base)
        guard case .valid(let persistedInstall) = afterInstall.load(original.identifier) else {
            throw AppDeliveryReceiptCheckError.failed("installed receipt did not persist")
        }
        try require(persistedInstall.phase == .installed && persistedInstall.identity == installed.identity,
                    "installed transition changed immutable identity")
        let restored = try afterInstall.transition(persistedInstall, to: .restored)
        guard case .valid(let persistedRestore) = AppDeliveryReceiptStore(baseDirectory: base).load(original.identifier) else {
            throw AppDeliveryReceiptCheckError.failed("restored receipt did not persist")
        }
        try require(persistedRestore.phase == .restored && restored.phase == .restored,
                    "restored phase was not durable")
        try require(AppDeliveryReceiptStore(baseDirectory: base).entries().count == 1,
                    "receipt inventory did not expose the durable record")
        print("PASS restart persistence and prepared-installed-restored transitions")
    }

    private static func checkConcurrentTransitionSerialization(root: URL) throws {
        let base = root.appendingPathComponent("concurrent/receipts", isDirectory: true)
        let store = AppDeliveryReceiptStore(baseDirectory: base)
        let original = receipt(root: root)
        try store.savePrepared(original)

        let resultLock = NSLock()
        var successfulTransitions = 0
        var failedTransitions = 0
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            do {
                _ = try AppDeliveryReceiptStore(baseDirectory: base)
                    .transition(original, to: .installed)
                resultLock.lock()
                successfulTransitions += 1
                resultLock.unlock()
            } catch {
                resultLock.lock()
                failedTransitions += 1
                resultLock.unlock()
            }
        }
        try require(successfulTransitions == 1 && failedTransitions == 11,
                    "concurrent transitions were not serialized: success=\(successfulTransitions) failures=\(failedTransitions)")
        guard case .valid(let installed) = store.load(original.identifier) else {
            throw AppDeliveryReceiptCheckError.failed("serialized transition did not leave a valid receipt")
        }
        try require(installed.phase == .installed, "serialized transition left the wrong phase")
        try expectError(.identityMismatch, { _ = try store.transition(original, to: .restored) },
                        "stale prepared transition")
        print("PASS serialized cross-instance transitions reject stale phase writers")
    }

    private static func checkCollisionAndFailedWrite(root: URL) throws {
        let base = root.appendingPathComponent("collision/receipts", isDirectory: true)
        let store = AppDeliveryReceiptStore(baseDirectory: base)
        let original = receipt(root: root)
        try store.savePrepared(original)
        try expectError(.alreadyExists, { try store.savePrepared(original) }, "same-ID save")
        guard case .valid(let unchanged) = store.load(original.identifier) else {
            throw AppDeliveryReceiptCheckError.failed("collision removed the original receipt")
        }
        try require(unchanged.phase == .prepared, "collision overwrote the original receipt")

        let baseFile = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: baseFile)
        let failedStore = AppDeliveryReceiptStore(baseDirectory: baseFile)
        try expectError(.writeFailed, { try failedStore.savePrepared(receipt(root: root)) }, "unwritable base")
        print("PASS exclusive collision and failed-write preservation")
    }

    private static func checkMalformedAndBoundedLoads(root: URL) throws {
        let base = root.appendingPathComponent("malformed/receipts", isDirectory: true)
        let store = AppDeliveryReceiptStore(baseDirectory: base)
        let malformedID = UUID()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("{\"version\":999,\"phase\":\"future\"}".utf8)
            .write(to: store.url(for: malformedID))
        guard case .corrupt = store.load(malformedID) else {
            throw AppDeliveryReceiptCheckError.failed("unknown schema/phase was accepted")
        }
        let oversizedID = UUID()
        try Data(repeating: 0x78, count: AppDeliveryReceiptStore.maximumRecordBytes + 1)
            .write(to: store.url(for: oversizedID))
        guard case .corrupt = store.load(oversizedID) else {
            throw AppDeliveryReceiptCheckError.failed("oversized receipt was accepted")
        }
        try Data("garbage".utf8).write(to: base.appendingPathComponent("not-a-uuid.json"))

        let danglingID = UUID()
        let danglingURL = store.url(for: danglingID)
        try FileManager.default.createSymbolicLink(
            at: danglingURL,
            withDestinationURL: base.appendingPathComponent("missing-target.json")
        )
        guard case .corrupt = store.load(danglingID) else {
            throw AppDeliveryReceiptCheckError.failed("dangling receipt symlink was reported absent")
        }

        let permissionID = UUID()
        try store.savePrepared(receipt(root: root, identifier: permissionID))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: store.url(for: permissionID).path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.url(for: permissionID).path
            )
        }
        guard case .corrupt = store.load(permissionID) else {
            throw AppDeliveryReceiptCheckError.failed("unreadable receipt was reported absent")
        }

        let entries = store.entries()
        try require(entries.contains { if case .corrupt = $0 { return true }; return false },
                    "corrupt inventory entry was hidden")
        guard case .absent = store.load(UUID()) else {
            throw AppDeliveryReceiptCheckError.failed("missing receipt was not absent")
        }
        let unreadableDirectory = root.appendingPathComponent("unreadable-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: unreadableDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: unreadableDirectory.path
            )
        }
        let unreadableEntries = AppDeliveryReceiptStore(baseDirectory: unreadableDirectory).entries()
        try require(unreadableEntries == [.unreadable(path: unreadableDirectory.path)],
                    "directory permission failure was collapsed to an empty inventory")
        print("PASS malformed, unknown-schema and bounded-load handling")
    }

    private static func checkIdentityAndPhaseRejection(root: URL) throws {
        let base = root.appendingPathComponent("identity/receipts", isDirectory: true)
        let store = AppDeliveryReceiptStore(baseDirectory: base)
        let original = receipt(root: root)
        try store.savePrepared(original)
        let differentBackup = AppDeliveryReceipt(
            identifier: original.identifier, bundleIdentifier: original.bundleIdentifier,
            installedPath: original.installedPath, sourceArtifactPath: original.sourceArtifactPath,
            backupPath: root.appendingPathComponent("other-backup/Receipt.app").path,
            startedAt: original.startedAt
        )
        try expectError(.identityMismatch, { _ = try store.transition(differentBackup, to: .installed) },
                        "immutable identity mismatch")
        try expectError(.invalidTransition, { _ = try store.transition(original, to: .restored) },
                        "skipped phase")
        let installed = try store.transition(original, to: .installed)
        try expectError(.identityMismatch, { _ = try store.transition(original, to: .restored) },
                        "stale phase transition")
        _ = try store.transition(installed, to: .installed) // idempotent retry is safe
        try expectError(.invalidTransition, { _ = try store.transition(installed, to: .prepared) },
                        "backward phase")
        let nonCanonical = AppDeliveryReceipt(
            bundleIdentifier: original.bundleIdentifier, installedPath: root.path + "/../bad.app",
            sourceArtifactPath: original.sourceArtifactPath, backupPath: root.appendingPathComponent("bad-backup.app").path
        )
        try expectError(.invalidReceipt, { try store.savePrepared(nonCanonical) }, "non-canonical path")
        print("PASS immutable identity, phase ordering and path validation")
    }
}
