import Foundation
@testable import IrisHarnessNative

private enum BackupRetentionCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Disposable checks for backup admission. They never use the installed Iris
/// profile and never remove anything outside their unique temporary root.
@main
struct BackupRetentionChecks {
    private struct Fixture {
        let root: URL
        let installed: URL
        let replacement: URL
        let backupRoot: URL
        let receiptRoot: URL
        let store: AppDeliveryReceiptStore
        let recoveryStore: DeliveredEditUndoRecoveryStore
        let policy: AppDeliveryReceiptStore.BackupRetentionPolicy
    }

    static func main() {
        do {
            try run()
        } catch {
            let message = "BACKUP RETENTION CHECKS FAILED: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    private static func run() throws {
        let fixtureParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-backup-retention-parent-" + UUID().uuidString, isDirectory: true)
        let root = fixtureParent
            .appendingPathComponent("iris-backup-retention-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureParent) }

        var groups = 0
        try checkExactCapAndNoCleanup(root: root); groups += 1
        try checkProtectedReferencesAndPreview(root: root); groups += 1
        try checkCorruptSymlinkAndRecordBounds(root: root); groups += 1
        try checkCheapAvailability(root: root); groups += 1
        print("BACKUP RETENTION CHECKS PASS: \(groups) groups")
    }

    private static func checkExactCapAndNoCleanup(root: URL) throws {
        let fixture = try fixture(root: root, name: "cap")
        try makeBundle(at: fixture.installed, identifier: "com.fixture.retention", payload: "candidate")
        let candidate = try requireSize(fixture.installed)
        let destination = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/next/Retention.app", isDirectory: true)
        let exact = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: candidate, backupRoot: fixture.backupRoot
        )
        guard let admission = try fixture.store.admitBackup(
            sourcePath: fixture.installed.path, destinationPath: destination.path,
            policy: exact, recoveryStore: fixture.recoveryStore
        ), admission.candidateLogicalBytes == candidate,
              admission.totalLogicalBytes == candidate else {
            throw BackupRetentionCheckError.failed("exact candidate cap was not admitted")
        }
        let oversizedSingleBundle = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: candidate - 1, backupRoot: fixture.backupRoot
        )
        try expectRetentionError(.budgetExceeded(current: 0, candidate: candidate,
                                                  limit: candidate - 1)) {
            _ = try fixture.store.admitBackup(
                sourcePath: fixture.installed.path, destinationPath: destination.path,
                policy: oversizedSingleBundle, recoveryStore: fixture.recoveryStore
            )
        }

        let existing = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/old/Retention.app", isDirectory: true)
        try makeBundle(at: existing, identifier: "com.fixture.retention", payload: "old")
        let existingBytes = try requireSize(existing)
        let exactWithExisting = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: existingBytes + candidate, backupRoot: fixture.backupRoot
        )
        guard try fixture.store.admitBackup(
            sourcePath: fixture.installed.path, destinationPath: destination.path,
            policy: exactWithExisting, recoveryStore: fixture.recoveryStore
        ) != nil else {
            throw BackupRetentionCheckError.failed("exact existing-plus-candidate cap was not admitted")
        }
        let before = try Data(contentsOf: existing.appendingPathComponent("Contents/marker"))
        let tooSmall = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: existingBytes + candidate - 1, backupRoot: fixture.backupRoot
        )
        try expectRetentionError(.budgetExceeded(current: existingBytes, candidate: candidate,
                                                  limit: existingBytes + candidate - 1)) {
            _ = try fixture.store.admitBackup(
                sourcePath: fixture.installed.path, destinationPath: destination.path,
                policy: tooSmall, recoveryStore: fixture.recoveryStore
            )
        }
        try require(Data(contentsOf: existing.appendingPathComponent("Contents/marker")) == before,
                    "overflow admission changed an existing backup")

        let boundary = try Self.fixture(root: root, name: "write-boundary")
        let boundaryIdentifier = "com.fixture.retention.boundary"
        try makeBundle(at: boundary.installed, identifier: boundaryIdentifier, payload: "old")
        try makeBundle(at: boundary.replacement, identifier: boundaryIdentifier, payload: "new")
        let blockedBackup = boundary.backupRoot
            .appendingPathComponent("com.fixture.retention.boundary/blocked/Retention.app", isDirectory: true)
        let blockedPolicy = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: 1, backupRoot: boundary.backupRoot
        )
        let blocked = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: boundaryIdentifier, installedPath: boundary.installed.path,
            artifactPath: boundary.replacement.path, backupPath: blockedBackup.path,
            grantsMayReset: true, store: boundary.store,
            undoRecoveryStore: boundary.recoveryStore, retentionPolicy: blockedPolicy
        )
        guard case .deliveryFailed = blocked,
              marker(at: boundary.installed) == "old",
              !FileManager.default.fileExists(atPath: blockedBackup.path),
              boundary.store.entries().isEmpty else {
            throw BackupRetentionCheckError.failed("write boundary replaced files after retention refusal")
        }

        let acceptedBackup = boundary.backupRoot
            .appendingPathComponent("com.fixture.retention.boundary/accepted/Retention.app", isDirectory: true)
        let boundaryInstalledBytes = try requireSize(boundary.installed)
        let boundaryReplacementBytes = try requireSize(boundary.replacement)
        let acceptedPolicy = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: boundaryInstalledBytes + boundaryReplacementBytes,
            backupRoot: boundary.backupRoot
        )
        let accepted = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: boundaryIdentifier, installedPath: boundary.installed.path,
            artifactPath: boundary.replacement.path, backupPath: acceptedBackup.path,
            grantsMayReset: true, store: boundary.store,
            undoRecoveryStore: boundary.recoveryStore, retentionPolicy: acceptedPolicy
        )
        guard case .replacedInstalledApp = accepted,
              marker(at: boundary.installed) == "new",
              marker(at: acceptedBackup) == "old" else {
            throw BackupRetentionCheckError.failed("admitted write boundary did not preserve the old app")
        }
        print("PASS exact cap, overflow, oversized-by-one and no-cleanup admission")
    }

    private static func checkProtectedReferencesAndPreview(root: URL) throws {
        let fixture = try fixture(root: root, name: "protected")
        let identifier = "com.fixture.retention"
        try makeBundle(at: fixture.installed, identifier: identifier, payload: "base")
        try makeBundle(at: fixture.replacement, identifier: identifier, payload: "replacement")
        let backup = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/restored/Retention.app", isDirectory: true)
        try makeBundle(at: backup, identifier: identifier, payload: "base")
        let sourceIdentity = AppDeliveryReceipt.SourceIdentity(
            appSlug: "retention", appName: "Retention", clonePath: fixture.root.appendingPathComponent("clone").path,
            branchName: "iris/edit-retention", commit: String(repeating: "a", count: 40),
            baseCommit: String(repeating: "b", count: 40), baseRef: "main", changeId: "retention-change"
        )
        let installedIdentity = try requireIdentity(fixture.installed)
        let replacementIdentity = try requireIdentity(fixture.replacement)
        let backupIdentity = try requireIdentity(backup)
        let prepared = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.installed.path,
            sourceArtifactPath: fixture.replacement.path, backupPath: backup.path,
            phase: .prepared, sourceIdentity: sourceIdentity,
            installedBundleIdentity: installedIdentity,
            replacementBundleIdentity: replacementIdentity,
            backupBundleIdentity: backupIdentity
        )
        try fixture.store.savePrepared(prepared)
        let installed = try fixture.store.transition(prepared, to: .installed)
        _ = try fixture.store.transition(installed, to: .restored)

        let destination = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/new/Retention.app", isDirectory: true)
        try makeBundle(at: fixture.installed, identifier: identifier, payload: "base")
        guard let admission = try fixture.store.admitBackup(
            sourcePath: fixture.installed.path, destinationPath: destination.path,
            policy: fixture.policy, recoveryStore: fixture.recoveryStore
        ), !admission.inventory.protectedBackupPaths.contains(backup.path),
              admission.inventory.previewEligibleBackupPaths == [backup.path] else {
            throw BackupRetentionCheckError.failed("restored receipt was not isolated as preview-eligible")
        }

        let alias = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.root.appendingPathComponent("alias-installed.app").path,
            sourceArtifactPath: fixture.replacement.path, backupPath: backup.path
        )
        try fixture.store.savePrepared(alias)
        let aliasDestination = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/alias-check/Retention.app", isDirectory: true)
        guard let aliasAdmission = try fixture.store.admitBackup(
            sourcePath: fixture.installed.path, destinationPath: aliasDestination.path,
            policy: fixture.policy, recoveryStore: fixture.recoveryStore
        ), aliasAdmission.inventory.protectedBackupPaths.contains(backup.path),
              !aliasAdmission.inventory.previewEligibleBackupPaths.contains(backup.path) else {
            throw BackupRetentionCheckError.failed("non-restored alias did not remove preview eligibility")
        }

        let preparedDestination = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/prepared/Retention.app", isDirectory: true)
        let preparedOnly = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.root.appendingPathComponent("other-installed.app").path,
            sourceArtifactPath: fixture.replacement.path, backupPath: preparedDestination.path
        )
        try fixture.store.savePrepared(preparedOnly)
        try expectRetentionError(.protectedReference) {
            _ = try fixture.store.admitBackup(
                sourcePath: fixture.installed.path, destinationPath: preparedDestination.path,
                policy: fixture.policy, recoveryStore: fixture.recoveryStore
            )
        }

        let pendingDestination = fixture.backupRoot
            .appendingPathComponent("com.fixture.retention/pending/Retention.app", isDirectory: true)
        let pending = DeliveredEditUndoRecoveryRecord(
            identifier: UUID(), startedAt: Date(timeIntervalSince1970: 1_725_000_000),
            appSlug: "retention", appName: "Retention", installedPath: fixture.installed.path,
            backupPath: pendingDestination.path, clonePath: fixture.root.appendingPathComponent("clone").path,
            branchName: "iris/edit-retention", originalCommit: String(repeating: "a", count: 40),
            originalRef: "main"
        )
        let pendingStore = DeliveredEditUndoRecoveryStore(
            recordURL: fixture.root.appendingPathComponent("pending/recovery.json")
        )
        try pendingStore.saveBeforeStarting(pending)
        try expectRetentionError(.protectedReference) {
            _ = try fixture.store.admitBackup(
                sourcePath: fixture.installed.path, destinationPath: pendingDestination.path,
                policy: fixture.policy, recoveryStore: pendingStore
            )
        }
        print("PASS installed/prepared/pending protection and restored-only preview eligibility")
    }

    private static func checkCorruptSymlinkAndRecordBounds(root: URL) throws {
        let corrupt = try fixture(root: root, name: "corrupt")
        try FileManager.default.createDirectory(at: corrupt.receiptRoot, withIntermediateDirectories: true)
        let badID = UUID()
        try Data("{not-json".utf8).write(to: corrupt.store.url(for: badID))
        try makeBundle(at: corrupt.installed, identifier: "com.fixture.retention", payload: "candidate")
        let destination = corrupt.backupRoot
            .appendingPathComponent("com.fixture.retention/new/Retention.app", isDirectory: true)
        try expectRetentionError(.corruptInventory) {
            _ = try corrupt.store.admitBackup(
                sourcePath: corrupt.installed.path, destinationPath: destination.path,
                policy: corrupt.policy, recoveryStore: corrupt.recoveryStore
            )
        }

        let symlink = try fixture(root: root, name: "symlink")
        let outside = symlink.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: symlink.backupRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlink.backupRoot.appendingPathComponent("com.fixture.retention"), withDestinationURL: outside
        )
        try makeBundle(at: symlink.installed, identifier: "com.fixture.retention", payload: "candidate")
        try expectAnyRetentionError {
            _ = try symlink.store.admitBackup(
                sourcePath: symlink.installed.path,
                destinationPath: symlink.backupRoot.appendingPathComponent("new/Retention.app").path,
                policy: symlink.policy, recoveryStore: symlink.recoveryStore
            )
        }

        let framework = try fixture(root: root, name: "framework-link")
        try makeBundle(at: framework.installed, identifier: "com.fixture.retention", payload: "candidate")
        let frameworkApp = framework.backupRoot
            .appendingPathComponent("com.fixture.retention/existing/Retention.app", isDirectory: true)
        try makeBundle(at: frameworkApp, identifier: "com.fixture.retention", payload: "old")
        let version = frameworkApp.appendingPathComponent(
            "Contents/Frameworks/Widget.framework/Versions/A", isDirectory: true
        )
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try Data("framework-binary".utf8).write(to: version.appendingPathComponent("Widget"))
        try FileManager.default.createSymbolicLink(
            atPath: version.deletingLastPathComponent().appendingPathComponent("Current").path,
            withDestinationPath: "A"
        )
        let frameworkDestination = framework.backupRoot
            .appendingPathComponent("com.fixture.retention/new/Retention.app", isDirectory: true)
        guard try framework.store.admitBackup(
            sourcePath: framework.installed.path, destinationPath: frameworkDestination.path,
            policy: framework.policy, recoveryStore: framework.recoveryStore
        ) != nil else {
            throw BackupRetentionCheckError.failed("framework-internal symlink was rejected")
        }
        print("PASS nested framework symlink counted without traversal")

        let bounded = try fixture(root: root, name: "bounded")
        try FileManager.default.createDirectory(at: bounded.receiptRoot, withIntermediateDirectories: true)
        for index in 0...AppDeliveryReceiptStore.maximumEntries {
            let receipt = AppDeliveryReceipt(
                identifier: UUID(), bundleIdentifier: "com.fixture.retention",
                installedPath: bounded.root.appendingPathComponent("installed-\(index).app").path,
                sourceArtifactPath: bounded.root.appendingPathComponent("source-\(index).app").path,
                backupPath: bounded.backupRoot.appendingPathComponent("com.fixture.retention/\(index)/Retention.app").path
            )
            try bounded.store.savePrepared(receipt)
        }
        try makeBundle(at: bounded.installed, identifier: "com.fixture.retention", payload: "candidate")
        try expectRetentionError(.corruptInventory) {
            _ = try bounded.store.admitBackup(
                sourcePath: bounded.installed.path,
                destinationPath: bounded.backupRoot.appendingPathComponent("new/Retention.app").path,
                policy: bounded.policy, recoveryStore: bounded.recoveryStore
            )
        }
        print("PASS corrupt receipt, symlink and >256-record inventory fail closed")
    }

    private static func checkCheapAvailability(root: URL) throws {
        let fixture = try fixture(root: root, name: "availability")
        let identifier = "com.fixture.retention"
        try makeBundle(at: fixture.installed, identifier: identifier, payload: "base")
        let backup = fixture.backupRoot.appendingPathComponent("com.fixture.retention/one/Retention.app")
        try makeBundle(at: backup, identifier: identifier, payload: "base")
        let receipt = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.installed.path,
            sourceArtifactPath: fixture.replacement.path, backupPath: backup.path
        )
        try require(fixture.store.backupIsAvailable(for: receipt), "safe existing backup was hidden")
        let missing = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.installed.path,
            sourceArtifactPath: fixture.replacement.path,
            backupPath: fixture.backupRoot.appendingPathComponent("missing/Retention.app").path
        )
        try require(!fixture.store.backupIsAvailable(for: missing), "missing backup was offered")
        let metadata = backup.appendingPathComponent("Contents/Info.plist")
        let externalMetadata = fixture.root.appendingPathComponent("external-Info.plist")
        try FileManager.default.moveItem(at: metadata, to: externalMetadata)
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: externalMetadata)
        try require(!fixture.store.backupIsAvailable(for: receipt), "symlinked bundle metadata was followed")
        print("PASS cheap Saved Versions availability gate")
    }

    private static func fixture(root: URL, name: String) throws -> Fixture {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let backupRoot = base.appendingPathComponent("backups", isDirectory: true)
        let receiptRoot = base.appendingPathComponent("receipts", isDirectory: true)
        let installed = base.appendingPathComponent("installed/Retention.app", isDirectory: true)
        let replacement = base.appendingPathComponent("replacement/Retention.app", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return Fixture(
            root: base, installed: installed, replacement: replacement,
            backupRoot: backupRoot, receiptRoot: receiptRoot,
            store: AppDeliveryReceiptStore(baseDirectory: receiptRoot),
            recoveryStore: DeliveredEditUndoRecoveryStore(
                recordURL: base.appendingPathComponent("recovery/recovery.json")
            ),
            policy: AppDeliveryReceiptStore.BackupRetentionPolicy(
                logicalByteLimit: 2 * 1024 * 1024, backupRoot: backupRoot
            )
        )
    }

    private static func makeBundle(at url: URL, identifier: String, payload: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Retention",
            "CFBundleVersion": "1",
            "CFBundleExecutable": "Retention"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(payload.utf8).write(to: contents.appendingPathComponent("marker"))
        try Data("executable".utf8).write(to: contents.appendingPathComponent("MacOS/Retention"))
    }

    private static func marker(at bundle: URL) -> String? {
        try? String(
            contentsOf: bundle.appendingPathComponent("Contents/marker"), encoding: .utf8
        )
    }

    private static func requireSize(_ url: URL) throws -> UInt64 {
        guard let size = AppDeliveryReceipt.logicalByteCount(atPath: url.path) else {
            throw BackupRetentionCheckError.failed("could not measure \(url.path)")
        }
        return size
    }

    private static func requireIdentity(_ url: URL) throws -> AppDeliveryReceipt.BundleIdentity {
        guard let identity = AppDeliveryReceipt.bundleIdentity(atPath: url.path) else {
            throw BackupRetentionCheckError.failed("could not identify \(url.path)")
        }
        return identity
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BackupRetentionCheckError.failed(message) }
    }

    private static func expectRetentionError(
        _ expected: AppDeliveryReceiptStore.RetentionError,
        _ operation: () throws -> Void
    ) throws {
        do {
            try operation()
            throw BackupRetentionCheckError.failed("expected retention error \(expected)")
        } catch let error as AppDeliveryReceiptStore.RetentionError {
            try require(error == expected, "got retention error \(error), expected \(expected)")
        }
    }

    private static func expectAnyRetentionError(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw BackupRetentionCheckError.failed("unsafe inventory was admitted")
        } catch is AppDeliveryReceiptStore.RetentionError {
            return
        }
    }
}
