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
        // Foundation's temporaryDirectory is /var on macOS here, and /var is
        // a symlink. Keep the disposable retention fixture under the explicit
        // harness scratch boundary or a unique folder in /Users/Shared so
        // the production no-symlink guard can exercise the fixture itself.
        let configuredScratch = ProcessInfo.processInfo.environment["IRIS_HARNESS_SCRATCH"]
            ?? "/Users/Shared"
        let configuredURL = URL(fileURLWithPath: configuredScratch, isDirectory: true)
        // BackupRetentionPolicy canonicalizes its root. Avoid /private/tmp
        // and other aliases whose canonical spelling introduces /tmp or /var,
        // both of which contain symlink components on macOS.
        let canonicalScratch = configuredURL.standardizedFileURL
        guard canonicalScratch.path == configuredURL.path else {
            throw BackupRetentionCheckError.failed("IRIS_HARNESS_SCRATCH must use a canonical, non-aliased path")
        }
        let scratchURL = configuredURL
        let fixtureParent = scratchURL
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
        try checkTestCleanupPreflightAndProtection(root: root); groups += 1
        try checkSuccessiveInstalledDeliveriesRemain(root: root); groups += 1
        try checkCleanupAliasAndPolicyGuards(root: root); groups += 1
        print("BACKUP RETENTION CHECKS PASS: \(groups) groups")
    }

    private static func checkTestCleanupPreflightAndProtection(root: URL) throws {
        let cleanupFixture = try fixture(root: root, name: "cleanup-success")
        let identifier = "com.fixture.retention.cleanup"
        try makeBundle(at: cleanupFixture.installed, identifier: identifier, payload: "current")
        try makeBundle(at: cleanupFixture.replacement, identifier: identifier, payload: "replacement")
        let project = cleanupProject(fixture: cleanupFixture, identifier: identifier)
        let now = Date(timeIntervalSince1970: 1_725_000_000)

        let oldest = cleanupFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.cleanup/old/Retention.app", isDirectory: true
        )
        let recent = cleanupFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.cleanup/recent/Retention.app", isDirectory: true
        )
        let newest = cleanupFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.cleanup/newest/Retention.app", isDirectory: true
        )
        // Every restored receipt records the pre-delivery installed identity;
        // the fixture therefore keeps the payload identical across backups.
        try makeBundle(at: oldest, identifier: identifier, payload: "current")
        try makeBundle(at: recent, identifier: identifier, payload: "current")
        try makeBundle(at: newest, identifier: identifier, payload: "current")
        try saveRestoredReceipt(store: cleanupFixture.store, installed: cleanupFixture.installed,
            replacement: cleanupFixture.replacement, backup: oldest, identifier: identifier,
            startedAt: now.addingTimeInterval(-30 * 24 * 60 * 60))
        try saveRestoredReceipt(store: cleanupFixture.store, installed: cleanupFixture.installed,
            replacement: cleanupFixture.replacement, backup: recent, identifier: identifier,
            startedAt: now.addingTimeInterval(-24 * 60 * 60))
        try saveRestoredReceipt(store: cleanupFixture.store, installed: cleanupFixture.installed,
            replacement: cleanupFixture.replacement, backup: newest, identifier: identifier,
            startedAt: now.addingTimeInterval(-14 * 24 * 60 * 60))

        let result = try IrisTestAppDelivery.cleanupObsoleteBackups(
            project: project, backupDirectory: cleanupFixture.backupRoot,
            receiptStore: cleanupFixture.store, recoveryStore: cleanupFixture.recoveryStore,
            policy: .init(now: now)
        )
        try require(result.deletedPaths == [newest.path, oldest.path].sorted(),
                    "cleanup did not delete only obsolete restored backups: \(result.deletedPaths)")
        try require(result.retainedPaths == [recent.path],
                    "recent rollback backup was not retained")
        try require(result.logicalBytesRemoved > 0 && result.allocatedBytesMeasured > 0,
                    "cleanup did not report logical and allocated measurements")
        try require(!FileManager.default.fileExists(atPath: oldest.path)
            && !FileManager.default.fileExists(atPath: newest.path), "obsolete backup still exists")
        try require(FileManager.default.fileExists(atPath: cleanupFixture.store.url(for: receiptID(
            store: cleanupFixture.store, backup: oldest, identifier: identifier
        )).path), "cleanup removed the receipt JSON")
        try require(FileManager.default.fileExists(atPath: recent.path),
                    "cleanup removed a retained rollback backup")
        print("PASS Test-only cleanup removes obsolete restored backup and retains newest/recent rollback")

        let protectedFixture = try Self.fixture(root: root, name: "cleanup-recovery")
        let protectedIdentifier = "com.fixture.retention.recovery"
        try makeBundle(at: protectedFixture.installed, identifier: protectedIdentifier, payload: "current")
        try makeBundle(at: protectedFixture.replacement, identifier: protectedIdentifier, payload: "replacement")
        let protectedProject = cleanupProject(fixture: protectedFixture, identifier: protectedIdentifier)
        let pendingBackup = protectedFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.recovery/pending/Retention.app", isDirectory: true
        )
        let archivedBackup = protectedFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.recovery/archived/Retention.app", isDirectory: true
        )
        let deletableBackup = protectedFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.recovery/deletable/Retention.app", isDirectory: true
        )
        for backup in [pendingBackup, archivedBackup, deletableBackup] {
            try makeBundle(at: backup, identifier: protectedIdentifier, payload: "current")
        }
        try saveRestoredReceipt(store: protectedFixture.store, installed: protectedFixture.installed,
            replacement: protectedFixture.replacement, backup: pendingBackup, identifier: protectedIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try saveRestoredReceipt(store: protectedFixture.store, installed: protectedFixture.installed,
            replacement: protectedFixture.replacement, backup: archivedBackup, identifier: protectedIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try saveRestoredReceipt(store: protectedFixture.store, installed: protectedFixture.installed,
            replacement: protectedFixture.replacement, backup: deletableBackup, identifier: protectedIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_500_000_000))
        let pendingRecord = DeliveredEditUndoRecoveryRecord(
            identifier: UUID(), startedAt: now, appSlug: "recovery", appName: "Retention",
            installedPath: protectedFixture.installed.path, backupPath: archivedBackup.path,
            clonePath: protectedFixture.root.appendingPathComponent("clone").path,
            branchName: "iris/edit-recovery", originalCommit: String(repeating: "a", count: 40),
            originalRef: "main"
        )
        try protectedFixture.recoveryStore.saveBeforeStarting(pendingRecord)
        let archive = try protectedFixture.recoveryStore.archiveBeforeStopping()
        try protectedFixture.recoveryStore.clearActiveAfterArchival(archive)
        let liveRecord = DeliveredEditUndoRecoveryRecord(
            identifier: UUID(), startedAt: now, appSlug: "recovery", appName: "Retention",
            installedPath: protectedFixture.installed.path, backupPath: pendingBackup.path,
            clonePath: protectedFixture.root.appendingPathComponent("clone").path,
            branchName: "iris/edit-recovery", originalCommit: String(repeating: "a", count: 40),
            originalRef: "main"
        )
        try protectedFixture.recoveryStore.saveBeforeStarting(liveRecord)
        let protectedResult = try IrisTestAppDelivery.cleanupObsoleteBackups(
            project: protectedProject, backupDirectory: protectedFixture.backupRoot,
            receiptStore: protectedFixture.store, recoveryStore: protectedFixture.recoveryStore,
            policy: .init(now: now)
        )
        try require(protectedResult.deletedPaths == [deletableBackup.path],
                    "pending/archived recovery references were not protected: \(protectedResult.deletedPaths)")
        try require(FileManager.default.fileExists(atPath: pendingBackup.path)
            && FileManager.default.fileExists(atPath: archivedBackup.path),
                    "recovery-protected backup was deleted")
        print("PASS pending and archived recovery references block cleanup")

        let corruptFixture = try Self.fixture(root: root, name: "cleanup-corrupt")
        let corruptIdentifier = "com.fixture.retention.corrupt"
        try makeBundle(at: corruptFixture.installed, identifier: corruptIdentifier, payload: "current")
        try makeBundle(at: corruptFixture.replacement, identifier: corruptIdentifier, payload: "replacement")
        let corruptBackup = corruptFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.corrupt/old/Retention.app", isDirectory: true
        )
        try makeBundle(at: corruptBackup, identifier: corruptIdentifier, payload: "old")
        _ = try saveRestoredReceipt(store: corruptFixture.store, installed: corruptFixture.installed,
            replacement: corruptFixture.replacement, backup: corruptBackup, identifier: corruptIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try Data("{not-json".utf8).write(to: corruptFixture.receiptRoot.appendingPathComponent("bad.json"))
        do {
            _ = try IrisTestAppDelivery.cleanupObsoleteBackups(
                project: cleanupProject(fixture: corruptFixture, identifier: corruptIdentifier),
                backupDirectory: corruptFixture.backupRoot, receiptStore: corruptFixture.store,
                recoveryStore: corruptFixture.recoveryStore, policy: .init(now: now)
            )
            throw BackupRetentionCheckError.failed("corrupt cleanup inventory was accepted")
        } catch AppDeliveryReceiptStore.CleanupError.corruptInventory {
            try require(FileManager.default.fileExists(atPath: corruptBackup.path),
                        "fail-closed corrupt cleanup deleted a backup")
        }
        print("PASS corrupt cleanup inventory fails closed before deletion")

        let changedFixture = try Self.fixture(root: root, name: "cleanup-changed")
        let changedIdentifier = "com.fixture.retention.changed"
        try makeBundle(at: changedFixture.installed, identifier: changedIdentifier, payload: "current")
        try makeBundle(at: changedFixture.replacement, identifier: changedIdentifier, payload: "replacement")
        let changedBackup = changedFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.changed/old/Retention.app", isDirectory: true
        )
        let changedNewest = changedFixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.changed/newest/Retention.app", isDirectory: true
        )
        try makeBundle(at: changedBackup, identifier: changedIdentifier, payload: "current")
        try makeBundle(at: changedNewest, identifier: changedIdentifier, payload: "current")
        _ = try saveRestoredReceipt(store: changedFixture.store, installed: changedFixture.installed,
            replacement: changedFixture.replacement, backup: changedBackup, identifier: changedIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        _ = try saveRestoredReceipt(store: changedFixture.store, installed: changedFixture.installed,
            replacement: changedFixture.replacement, backup: changedNewest, identifier: changedIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try Data("mutated".utf8).write(to: changedBackup.appendingPathComponent("Contents/marker"))
        do {
            _ = try IrisTestAppDelivery.cleanupObsoleteBackups(
                project: cleanupProject(fixture: changedFixture, identifier: changedIdentifier),
                backupDirectory: changedFixture.backupRoot, receiptStore: changedFixture.store,
                recoveryStore: changedFixture.recoveryStore, policy: .init(now: now)
            )
            throw BackupRetentionCheckError.failed("changed cleanup identity was accepted")
        } catch AppDeliveryReceiptStore.CleanupError.changedIdentity {
            try require(FileManager.default.fileExists(atPath: changedBackup.path),
                        "changed identity cleanup deleted a backup")
        }
        print("PASS changed bundle identity fails closed before deletion")

        let repeated = try IrisTestAppDelivery.cleanupObsoleteBackups(
            project: project, backupDirectory: cleanupFixture.backupRoot,
            receiptStore: cleanupFixture.store, recoveryStore: cleanupFixture.recoveryStore,
            policy: .init(now: now)
        )
        try require(repeated.deletedPaths.isEmpty && repeated.retainedPaths == [recent.path],
                    "repeat cleanup was not idempotent")
        print("PASS repeat cleanup treats removed restored payloads as idempotently absent")
    }

    private static func checkSuccessiveInstalledDeliveriesRemain(root: URL) throws {
        let fixture = try Self.fixture(root: root, name: "cleanup-installed-growth")
        let identifier = "com.fixture.retention.installed"
        try makeBundle(at: fixture.installed, identifier: identifier, payload: "v0")
        try makeBundle(at: fixture.replacement, identifier: identifier, payload: "v1")
        let replacementTwo = fixture.root.appendingPathComponent("replacement-two/Retention.app")
        try makeBundle(at: replacementTwo, identifier: identifier, payload: "v2")
        let backupOne = fixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.installed/one/Retention.app", isDirectory: true
        )
        let backupTwo = fixture.backupRoot.appendingPathComponent(
            "com.fixture.retention.installed/two/Retention.app", isDirectory: true
        )
        let policy = AppDeliveryReceiptStore.BackupRetentionPolicy(
            logicalByteLimit: 2 * 1024 * 1024, backupRoot: fixture.backupRoot
        )
        let first = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.installed.path,
            artifactPath: fixture.replacement.path, backupPath: backupOne.path,
            grantsMayReset: true, store: fixture.store,
            undoRecoveryStore: fixture.recoveryStore, retentionPolicy: policy
        )
        guard case .replacedInstalledApp = first else {
            throw BackupRetentionCheckError.failed("first installed delivery did not succeed")
        }
        let bytesAfterFirst = try requireSize(fixture.backupRoot)
        let second = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: identifier, installedPath: fixture.installed.path,
            artifactPath: replacementTwo.path, backupPath: backupTwo.path,
            grantsMayReset: true, store: fixture.store,
            undoRecoveryStore: fixture.recoveryStore, retentionPolicy: policy
        )
        guard case .replacedInstalledApp = second else {
            throw BackupRetentionCheckError.failed("second installed delivery did not succeed")
        }
        let bytesAfterSecond = try requireSize(fixture.backupRoot)
        try require(bytesAfterSecond > bytesAfterFirst,
                    "successive installed deliveries did not leave measurable backup growth")
        let project = IrisTestProjectRegistry.Project(
            slug: "installed", name: "Installed", clonePath: fixture.root.appendingPathComponent("clone").path,
            applicationPath: fixture.installed.path, buildArtifactPath: replacementTwo.path,
            bundleIdentifier: identifier, pinnedCommit: String(repeating: "a", count: 40)
        )
        let result = try IrisTestAppDelivery.cleanupObsoleteBackups(
            project: project, backupDirectory: fixture.backupRoot,
            receiptStore: fixture.store, recoveryStore: fixture.recoveryStore,
            policy: .init(now: Date(timeIntervalSince1970: 1_725_000_000))
        )
        try require(result.deletedPaths.isEmpty, "cleanup removed an installed Undo backup")
        try require(try requireSize(fixture.backupRoot) == bytesAfterSecond,
                    "installed backup inventory changed during no-op cleanup")
        try require(fixture.store.entries().compactMap({
            if case .valid(let receipt) = $0 { return receipt.phase }
            return nil
        }).filter({ $0 == AppDeliveryReceipt.Phase.installed }).count == 2,
                    "successful deliveries did not retain both installed receipts")
        print("PASS successive installed deliveries retain receipts/backups; growth remains outside cleanup")
    }

    private static func checkCleanupAliasAndPolicyGuards(root: URL) throws {
        let newestAlias = try Self.fixture(root: root, name: "cleanup-alias-newest")
        let identifier = "com.fixture.retention.alias.newest"
        try makeBundle(at: newestAlias.installed, identifier: identifier, payload: "current")
        try makeBundle(at: newestAlias.replacement, identifier: identifier, payload: "replacement")
        let shared = newestAlias.backupRoot.appendingPathComponent(
            "com.fixture.retention.alias.newest/shared/Retention.app", isDirectory: true
        )
        try makeBundle(at: shared, identifier: identifier, payload: "current")
        try saveRestoredReceipt(store: newestAlias.store, installed: newestAlias.installed,
            replacement: newestAlias.replacement, backup: shared, identifier: identifier,
            startedAt: Date(timeIntervalSince1970: 1_725_000_000 - 24 * 60 * 60))
        try saveRestoredReceipt(store: newestAlias.store, installed: newestAlias.installed,
            replacement: newestAlias.replacement, backup: shared, identifier: identifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try expectCleanupError(.corruptInventory, project: cleanupProject(
            fixture: newestAlias, identifier: identifier), fixture: newestAlias)
        try require(FileManager.default.fileExists(atPath: shared.path),
                    "newest/old alias cleanup removed the shared backup")

        let obsoleteAlias = try Self.fixture(root: root, name: "cleanup-alias-obsolete")
        let obsoleteIdentifier = "com.fixture.retention.alias.obsolete"
        try makeBundle(at: obsoleteAlias.installed, identifier: obsoleteIdentifier, payload: "current")
        try makeBundle(at: obsoleteAlias.replacement, identifier: obsoleteIdentifier, payload: "replacement")
        let obsoleteShared = obsoleteAlias.backupRoot.appendingPathComponent(
            "com.fixture.retention.alias.obsolete/shared/Retention.app", isDirectory: true
        )
        try makeBundle(at: obsoleteShared, identifier: obsoleteIdentifier, payload: "current")
        try saveRestoredReceipt(store: obsoleteAlias.store, installed: obsoleteAlias.installed,
            replacement: obsoleteAlias.replacement, backup: obsoleteShared, identifier: obsoleteIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try saveRestoredReceipt(store: obsoleteAlias.store, installed: obsoleteAlias.installed,
            replacement: obsoleteAlias.replacement, backup: obsoleteShared, identifier: obsoleteIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_590_000_000))
        try expectCleanupError(.corruptInventory, project: cleanupProject(
            fixture: obsoleteAlias, identifier: obsoleteIdentifier), fixture: obsoleteAlias)
        try require(FileManager.default.fileExists(atPath: obsoleteShared.path),
                    "obsolete alias cleanup removed the shared backup")

        let overlap = try Self.fixture(root: root, name: "cleanup-alias-overlap")
        let overlapIdentifier = "com.fixture.retention.alias.overlap"
        try makeBundle(at: overlap.installed, identifier: overlapIdentifier, payload: "current")
        try makeBundle(at: overlap.replacement, identifier: overlapIdentifier, payload: "replacement")
        let ancestor = overlap.backupRoot.appendingPathComponent(
            "com.fixture.retention.alias.overlap/ancestor/Retention.app", isDirectory: true
        )
        let child = ancestor.appendingPathComponent("Nested.app", isDirectory: true)
        try makeBundle(at: ancestor, identifier: overlapIdentifier, payload: "current")
        try makeBundle(at: child, identifier: overlapIdentifier, payload: "nested")
        try saveRestoredReceipt(store: overlap.store, installed: overlap.installed,
            replacement: overlap.replacement, backup: ancestor, identifier: overlapIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        try saveRestoredReceipt(store: overlap.store, installed: overlap.installed,
            replacement: overlap.replacement, backup: child, identifier: overlapIdentifier,
            startedAt: Date(timeIntervalSince1970: 1_590_000_000))
        try expectCleanupError(.corruptInventory, project: cleanupProject(
            fixture: overlap, identifier: overlapIdentifier), fixture: overlap)
        try require(FileManager.default.fileExists(atPath: ancestor.path)
            && FileManager.default.fileExists(atPath: child.path),
                    "overlapping alias cleanup removed a payload")

        let policyFixture = try Self.fixture(root: root, name: "cleanup-nonfinite-policy")
        let policyProject = cleanupProject(fixture: policyFixture, identifier: "com.fixture.retention.policy")
        try expectCleanupError(.invalidPolicy, project: policyProject, fixture: policyFixture,
            policy: .init(now: Date(timeIntervalSinceReferenceDate: .nan)))
        try expectCleanupError(.invalidPolicy, project: policyProject, fixture: policyFixture,
            policy: .init(now: Date(timeIntervalSinceReferenceDate: 0), recentRollbackWindow: .nan))
        print("PASS duplicate/overlapping receipt aliases and nonfinite policy fail closed")
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
        try FileManager.default.createDirectory(at: base.appendingPathComponent("clone"), withIntermediateDirectories: true)
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

    private static func cleanupProject(
        fixture: Fixture, identifier: String
    ) -> IrisTestProjectRegistry.Project {
        IrisTestProjectRegistry.Project(
            slug: "cleanup", name: "Cleanup", clonePath: fixture.root.appendingPathComponent("clone").path,
            applicationPath: fixture.installed.path,
            buildArtifactPath: fixture.replacement.path,
            bundleIdentifier: identifier, pinnedCommit: String(repeating: "a", count: 40)
        )
    }

    @discardableResult
    private static func saveRestoredReceipt(
        store: AppDeliveryReceiptStore, installed: URL, replacement: URL, backup: URL,
        identifier: String, startedAt: Date
    ) throws -> AppDeliveryReceipt {
        let installedIdentity = try requireIdentity(installed)
        let replacementIdentity = try requireIdentity(replacement)
        let backupIdentity = try requireIdentity(backup)
        let source = AppDeliveryReceipt.SourceIdentity(
            appSlug: "cleanup", appName: "Cleanup", clonePath: replacement.deletingLastPathComponent().path,
            branchName: "iris/edit-cleanup", commit: String(repeating: "a", count: 40),
            baseCommit: String(repeating: "b", count: 40), baseRef: "main", changeId: "cleanup"
        )
        let prepared = AppDeliveryReceipt(
            bundleIdentifier: identifier, installedPath: installed.path,
            sourceArtifactPath: replacement.path, backupPath: backup.path,
            startedAt: startedAt, phase: .prepared, sourceIdentity: source,
            installedBundleIdentity: installedIdentity,
            replacementBundleIdentity: replacementIdentity,
            backupBundleIdentity: backupIdentity
        )
        try store.savePrepared(prepared)
        let installedReceipt = try store.transition(prepared, to: .installed)
        return try store.transition(installedReceipt, to: .restored)
    }

    private static func receiptID(
        store: AppDeliveryReceiptStore, backup: URL, identifier: String
    ) -> UUID {
        for entry in store.entries() {
            guard case .valid(let receipt) = entry,
                  receipt.backupPath == backup.path,
                  receipt.bundleIdentifier == identifier else { continue }
            return receipt.identifier
        }
        return UUID()
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

    private static func expectCleanupError(
        _ expected: AppDeliveryReceiptStore.CleanupError,
        project: IrisTestProjectRegistry.Project,
        fixture: Fixture,
        policy: AppDeliveryReceiptStore.BackupCleanupPolicy = .init()
    ) throws {
        do {
            _ = try IrisTestAppDelivery.cleanupObsoleteBackups(
                project: project, backupDirectory: fixture.backupRoot,
                receiptStore: fixture.store, recoveryStore: fixture.recoveryStore,
                policy: policy
            )
            throw BackupRetentionCheckError.failed("expected cleanup error (expected)")
        } catch let error as AppDeliveryReceiptStore.CleanupError {
            try require(error == expected, "got cleanup error \(error), expected \(expected)")
        }
    }
}
