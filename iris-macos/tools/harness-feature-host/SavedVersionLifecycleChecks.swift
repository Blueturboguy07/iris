import Foundation
@testable import IrisHarnessNative

/// Standalone, disposable checks for restart-safe Saved Versions Undo. This
/// executable never reads the normal Iris profile, Launch Services, or an
/// installed app. Every Git checkout, bundle, receipt, and recovery marker is
/// created below a temporary fixture root.
@main
struct SavedVersionLifecycleChecks {
    private struct CheckFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Fixture {
        let root: URL
        let clone: URL
        let installed: URL
        let artifact: URL
        let backup: URL
        let store: AppDeliveryReceiptStore
        let recoveryStore: DeliveredEditUndoRecoveryStore
        let receipt: AppDeliveryReceipt
        let sourceIdentity: AppDeliveryReceipt.SourceIdentity
        let baseCommit: String
        let editCommit: String
    }

    @MainActor
    static func main() async {
        do {
            try checkReceiptRoundTripAndPayloadIdentity()
            print("PASS receipt source/base and installed bundle identity survive restart")
            try await checkChangedSourceAndPayloadRefusal()
            print("PASS duplicate receipts, dirty source, and same-ID payload changes refuse safely")
            try await checkCoordinatorCallbackOrdering()
            print("PASS coordinator quit, restore, launch and truthful recovery callbacks")
            try await checkSourceRestoreCommandAndCheckpoint()
            print("PASS same-branch source restore preserves edit history and restart checkpoint resumes")
            print("SAVED VERSION LIFECYCLE CHECKS PASS: disposable Git and bundle fixtures only")
        } catch {
            print("SAVED VERSION LIFECYCLE CHECKS STOPPED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func checkReceiptRoundTripAndPayloadIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let restarted = AppDeliveryReceiptStore(baseDirectory: fixture.store.baseDirectory)
        guard case .valid(let loaded) = restarted.load(fixture.receipt.identifier) else {
            throw CheckFailure(message: "installed receipt did not survive restart")
        }
        try require(loaded.phase == .installed, "restart changed installed phase")
        try require(loaded.sourceIdentity == fixture.sourceIdentity,
                    "restart changed exact branch, commit, or base identity")
        try require(loaded.hasCompleteUndoMetadata,
                    "new receipt did not retain complete Undo metadata")
        try require(loaded.installedBundleIdentity?.contentDigest != nil
            && loaded.replacementBundleIdentity?.contentDigest != nil
            && loaded.backupBundleIdentity?.contentDigest != nil,
            "new receipt did not retain payload digests")
        try require(loaded.installedBundleIdentity == loaded.backupBundleIdentity,
                    "backup identity did not pin the replaced bundle")
        let copiedBundle = fixture.root.appendingPathComponent("copied/Notes.app", isDirectory: true)
        try FileManager.default.createDirectory(at: copiedBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.artifact, to: copiedBundle)
        try require(AppDeliveryReceipt.bundleIdentity(atPath: fixture.artifact.path)
            == AppDeliveryReceipt.bundleIdentity(atPath: copiedBundle.path),
            "real bundle copy changed an otherwise identical payload digest")

        let legacyBase = fixture.root.appendingPathComponent("legacy-receipts", isDirectory: true)
        let legacyStore = AppDeliveryReceiptStore(baseDirectory: legacyBase)
        let legacy = AppDeliveryReceipt(
            identifier: UUID(), bundleIdentifier: loaded.bundleIdentifier,
            installedPath: loaded.installedPath,
            sourceArtifactPath: loaded.sourceArtifactPath,
            backupPath: fixture.root.appendingPathComponent("legacy-backup.app").path
        )
        let legacyData = try JSONEncoder().encode(legacy)
        let object = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any]
        try require(object?["sourceIdentity"] == nil && object?["replacementBundleIdentity"] == nil,
                    "legacy encoder unexpectedly wrote new optional fields")
        try FileManager.default.createDirectory(at: legacyBase, withIntermediateDirectories: true)
        try legacyData.write(to: legacyStore.url(for: legacy.identifier))
        guard case .valid(let decodedLegacy) = legacyStore.load(legacy.identifier) else {
            throw CheckFailure(message: "legacy receipt no longer decodes")
        }
        try require(decodedLegacy.sourceIdentity == nil && !decodedLegacy.hasCompleteUndoMetadata,
                    "legacy receipt became restart-Undoable without source evidence")
        let metadataOnly = AppDeliveryReceipt.bundleMetadataIdentity(atPath: fixture.installed.path)
        let partial = AppDeliveryReceipt(bundleIdentifier: loaded.bundleIdentifier,
            installedPath: loaded.installedPath, sourceArtifactPath: loaded.sourceArtifactPath,
            backupPath: loaded.backupPath, phase: .installed,
            sourceIdentity: fixture.sourceIdentity, installedBundleIdentity: metadataOnly,
            replacementBundleIdentity: metadataOnly, backupBundleIdentity: metadataOnly)
        try require(partial.isValid && !partial.hasCompleteUndoMetadata,
                    "metadata-only legacy bundle identities incorrectly enabled Undo")
    }

    @MainActor
    private static func checkChangedSourceAndPayloadRefusal() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let duplicate = AppDeliveryReceipt(
            identifier: fixture.receipt.identifier,
            bundleIdentifier: fixture.receipt.bundleIdentifier,
            installedPath: fixture.receipt.installedPath,
            sourceArtifactPath: fixture.receipt.sourceArtifactPath,
            backupPath: fixture.receipt.backupPath,
            sourceIdentity: fixture.receipt.sourceIdentity,
            installedBundleIdentity: fixture.receipt.installedBundleIdentity,
            replacementBundleIdentity: fixture.receipt.replacementBundleIdentity,
            backupBundleIdentity: fixture.receipt.backupBundleIdentity
        )
        do {
            try fixture.store.savePrepared(duplicate)
            throw CheckFailure(message: "duplicate receipt ID was accepted")
        } catch let error as AppDeliveryReceiptStore.StoreError {
            try require(error == .alreadyExists, "duplicate receipt threw \(error), not alreadyExists")
        }

        try git(["checkout", "main"], at: fixture.clone)
        let sourceIdentity = SavedEditDeliveryIdentity(
            clonePath: fixture.clone.path, branchName: "iris-edit", commit: fixture.editCommit
        )
        try require(await sourceIdentity.stillMatchesSource() == false,
                    "changed source branch was accepted for a saved delivery")
        try git(["checkout", "iris-edit"], at: fixture.clone)
        try Data("dirty reader work\n".utf8).write(to: fixture.clone.appendingPathComponent("source.txt"))
        try require(await sourceIdentity.stillMatchesSource() == false,
                    "dirty saved source was accepted for a saved delivery")
        try git(["checkout", "--", "source.txt"], at: fixture.clone)

        // Keep the same identifier and version while changing only payload
        // bytes. Info.plist identity remains stable, but the digest must not.
        let before = fixture.receipt.replacementBundleIdentity
        try Data("tampered edited payload\n".utf8)
            .write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
        let after = AppDeliveryReceipt.bundleIdentity(atPath: fixture.installed.path)
        try require(before != after, "same-ID/version payload tamper kept the saved identity")

        var events: [String] = []
        let lock = MaintainClonePathLock()
        let coordinator = try makeCoordinator(fixture, clonePathLock: lock)
        coordinator.terminateEditedAppBeforeUndo = { _, _ in
            events.append("quit")
            return .readyForDelivery(priorApplicationPath: nil)
        }
        coordinator.restoreInstalledAppFromBackup = { _, _ in
            events.append("restore")
            return true
        }
        coordinator.launchRestoredAppAfterUndo = { _, _ in
            events.append("launch")
            return .relaunchedFreshBuild
        }
        try require(coordinator.undoSavedAppVersion(fixture.receipt),
                    "changed-payload receipt was not selected for asynchronous validation")
        try require(coordinator.savedVersionUndoIsPending,
                    "Saved Versions tap did not publish pending Undo state")
        try require(!coordinator.canPickAnotherApp,
                    "Saved Versions validation did not retain operation ownership")
        try await wait(until: { coordinator.undoFailureMessage != nil })
        try require(!coordinator.savedVersionUndoIsPending,
                    "failed Saved Versions preflight left the pending Undo projection visible")
        try require(events.isEmpty, "changed payload reached a recovery callback: \(events)")
        try require(coordinator.undoFailureMessage?.contains("payload") == true,
                    "changed payload refusal was not truthful")
        try require(coordinator.phase == .done, "payload refusal left the flow in a live phase")

        // The failed preflight never acquired the clone lock. Restore the
        // payload and hold the same lock to prove a second tap cannot bypass
        // contention merely because the coordinator retained Undo state.
        try Data("edited payload\n".utf8)
            .write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
        try require(lock.tryAcquire(clonePath: fixture.clone.path, owner: "fixture-holder"),
                    "fixture could not hold the clone lock")
        try require(coordinator.undoSavedAppVersion(fixture.receipt),
                    "valid retry after payload repair was not selected")
        try await wait(until: { coordinator.statusLine?.contains("Another task is using") == true })
        try require(events.isEmpty, "lock contention reached a recovery callback: \(events)")
        lock.release(clonePath: fixture.clone.path)
    }

    @MainActor
    private static func checkCoordinatorCallbackOrdering() async throws {
        let refusalFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: refusalFixture.root) }
        var refusalEvents: [String] = []
        let refusal = try makeCoordinator(refusalFixture)
        refusal.terminateEditedAppBeforeUndo = { _, _ in
            refusalEvents.append("quit")
            return .runningAppWouldNotQuit
        }
        refusal.restoreInstalledAppFromBackup = { _, _ in
            refusalEvents.append("restore")
            return true
        }
        refusal.launchRestoredAppAfterUndo = { _, _ in
            refusalEvents.append("launch")
            return .relaunchedFreshBuild
        }
        try require(refusal.undoSavedAppVersion(refusalFixture.receipt),
                    "quit-refusal receipt was not selected")
        try require(refusal.savedVersionUndoIsPending,
                    "quit-refusal selection did not publish pending Undo state")
        try require(!refusal.canPickAnotherApp,
                    "Undo selection became retargetable while validation was in flight")
        try await wait(until: { refusal.undoFailureMessage != nil })
        try require(!refusal.savedVersionUndoIsPending,
                    "quit refusal left the pending Undo projection visible")
        try require(refusalEvents == ["quit"], "quit refusal performed later callbacks: \(refusalEvents)")
        guard case .valid(let refusedReceipt) = refusalFixture.store.load(refusalFixture.receipt.identifier) else {
            throw CheckFailure(message: "quit refusal lost its receipt")
        }
        try require(refusedReceipt.phase == .installed, "quit refusal changed receipt phase")

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var events: [String] = []
        var launchShouldFail = true
        let coordinator = try makeCoordinator(fixture)
        coordinator.terminateEditedAppBeforeUndo = { _, _ in
            events.append("quit")
            return .readyForDelivery(priorApplicationPath: nil)
        }
        coordinator.restoreInstalledAppFromBackup = { installedPath, backupPath in
            events.append("restore")
            let files = FileManager.default
            do {
                try files.removeItem(atPath: installedPath)
                try files.copyItem(atPath: backupPath, toPath: installedPath)
                guard case .valid(let current) = fixture.store.load(fixture.receipt.identifier),
                      current.phase == .installed else { return false }
                _ = try fixture.store.transition(current, to: .restored)
                return true
            } catch { return false }
        }
        coordinator.launchRestoredAppAfterUndo = { _, _ in
            if launchShouldFail {
                events.append("launch-failed")
                return .launchFailedPriorAppRestored(reason: "fixture launch failure")
            }
            events.append("reopen")
            return .relaunchedFreshBuild
        }

        // This call models a fresh coordinator selecting the exact installed
        // receipt after restart. Restore must be checkpointed before launch.
        try require(coordinator.undoSavedAppVersion(fixture.receipt),
                    "restart receipt was not selected")
        try require(coordinator.savedVersionUndoIsPending,
                    "restart receipt selection did not publish pending Undo state")
        try await wait(until: { coordinator.undoFailureMessage != nil })
        try require(!coordinator.savedVersionUndoIsPending,
                    "launch failure left the pending Undo projection visible")
        try require(events == ["quit", "restore", "launch-failed"],
                    "launch failure did not preserve callback order: \(events)")
        guard case .valid(let restoredReceipt) = fixture.store.load(fixture.receipt.identifier) else {
            throw CheckFailure(message: "launch failure lost the delivery receipt")
        }
        try require(restoredReceipt.phase == .restored,
                    "launch failure did not leave a truthful restored receipt")
        guard case .pending = fixture.recoveryStore.load() else {
            throw CheckFailure(message: "launch failure did not retain recovery marker")
        }

        // A retry should resume at reopen, never attempt an uncertain second
        // restore. This currently documents the required public recovery path.
        launchShouldFail = false
        coordinator.undoDeliveredChange()
        try await wait(until: { !coordinator.undoIsInProgress && coordinator.deliveredChangeCanBeUndone == false })
        try require(events == ["quit", "restore", "launch-failed", "reopen"],
                    "reopen retry repeated or skipped a recovery callback: \(events)")
        try require(coordinator.previousVersionWasRestored,
                    "successful Saved Versions Undo did not publish restored-result state")
        try require(!coordinator.savedVersionUndoIsPending,
                    "successful Saved Versions Undo left pending-result state visible")
        try require(coordinator.statusLine == "Previous version restored. Saved Notes is running again.",
                    "successful Saved Versions Undo did not publish its truthful result status")
        guard case .absent = fixture.recoveryStore.load() else {
            throw CheckFailure(message: "completed reopen left a recovery marker")
        }
    }

    @MainActor
    private static func checkSourceRestoreCommandAndCheckpoint() async throws {
        let sameBranchFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: sameBranchFixture.root) }
        let sameBranchCommand = DeliveredEditUndoRecovery.sourceRestoreCommand(
            originalHeadRef: "iris-edit",
            originalCommit: sameBranchFixture.baseCommit,
            editedBranchName: "iris-edit"
        )
        let sameBranchResult = try shell(sameBranchCommand, at: sameBranchFixture.clone)
        try require(sameBranchResult.exitCode == 0,
                    "advanced saved branch did not restore the baseline: \(sameBranchResult.stderr)")
        let sameBranchHead = try git(["rev-parse", "HEAD"], at: sameBranchFixture.clone)
        try require(sameBranchHead == sameBranchFixture.baseCommit,
                    "same-branch source restore did not detach at the exact baseline")
        let savedBranchHead = try git(["rev-parse", "refs/heads/iris-edit"], at: sameBranchFixture.clone)
        try require(savedBranchHead == sameBranchFixture.editCommit,
                    "same-branch source restore changed the saved edit branch")
        let restoredSource = try String(contentsOf: sameBranchFixture.clone.appendingPathComponent("source.txt"), encoding: .utf8)
        try require(restoredSource == "base source\n",
                    "same-branch source restore did not restore baseline files")
        let detachedRetry = try shell(sameBranchCommand, at: sameBranchFixture.clone)
        try require(detachedRetry.exitCode == 0,
                    "a completed detached source restore was not safely retryable")

        let movedRefFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: movedRefFixture.root) }
        try git(["checkout", "main"], at: movedRefFixture.clone)
        try Data("new main source\n".utf8)
            .write(to: movedRefFixture.clone.appendingPathComponent("source.txt"))
        try git(["add", "source.txt"], at: movedRefFixture.clone)
        try git(["commit", "--no-gpg-sign", "-m", "unrelated main change"], at: movedRefFixture.clone)
        let movedMainCommit = try git(["rev-parse", "HEAD"], at: movedRefFixture.clone)
        let movedRefCommand = DeliveredEditUndoRecovery.sourceRestoreCommand(
            originalHeadRef: "main",
            originalCommit: movedRefFixture.baseCommit,
            editedBranchName: "iris-edit"
        )
        let movedRefResult = try shell(movedRefCommand, at: movedRefFixture.clone)
        try require(movedRefResult.exitCode != 0,
                    "a moved ordinary base ref was accepted for source restore")
        let movedRefHead = try git(["rev-parse", "HEAD"], at: movedRefFixture.clone)
        try require(movedRefHead == movedMainCommit,
                    "moved ordinary base ref refusal changed the current branch")
        let movedRefSource = try String(contentsOf: movedRefFixture.clone.appendingPathComponent("source.txt"), encoding: .utf8)
        try require(movedRefSource == "new main source\n",
                    "moved ordinary base ref refusal changed source")

        let dirtyFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dirtyFixture.root) }
        let dirtySource = dirtyFixture.clone.appendingPathComponent("source.txt")
        try Data("reader work\n".utf8).write(to: dirtySource)
        let dirtyResult = try shell(
            DeliveredEditUndoRecovery.sourceRestoreCommand(
                originalHeadRef: "iris-edit",
                originalCommit: dirtyFixture.baseCommit,
                editedBranchName: "iris-edit"
            ),
            at: dirtyFixture.clone
        )
        try require(dirtyResult.exitCode != 0,
                    "dirty same-branch source was accepted for restore")
        let dirtySourceContents = try String(contentsOf: dirtySource, encoding: .utf8)
        try require(dirtySourceContents == "reader work\n",
                    "dirty source refusal changed reader work")

        let detachedDirtyFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: detachedDirtyFixture.root) }
        let detachedRestore = DeliveredEditUndoRecovery.sourceRestoreCommand(
            originalHeadRef: "iris-edit",
            originalCommit: detachedDirtyFixture.baseCommit,
            editedBranchName: "iris-edit"
        )
        let detachedRestoreResult = try shell(detachedRestore, at: detachedDirtyFixture.clone)
        try require(detachedRestoreResult.exitCode == 0,
                    "detached dirty fixture could not reach baseline")
        let detachedDirtySource = detachedDirtyFixture.clone.appendingPathComponent("source.txt")
        try Data("reader work after restore\n".utf8).write(to: detachedDirtySource)
        let detachedDirtyResult = try shell(detachedRestore, at: detachedDirtyFixture.clone)
        try require(detachedDirtyResult.exitCode != 0,
                    "dirty detached baseline bypassed the source restore guard")
        let detachedDirtySourceContents = try String(contentsOf: detachedDirtySource, encoding: .utf8)
        try require(detachedDirtySourceContents == "reader work after restore\n",
            "dirty detached baseline refusal changed reader work")

        let checkpoint = DeliveredEditUndoRecovery()
        try require(checkpoint.restoreConfirmedAppCheckpoint(),
                    "restart restore checkpoint was not accepted while idle")
        try require(checkpoint.completed == [.restore] && checkpoint.needsRecovery,
                    "restart restore checkpoint changed more than the restore stage")
        try require(!checkpoint.restoreConfirmedAppCheckpoint(),
                    "restart restore checkpoint was not single-use")
        guard let operation = checkpoint.begin() else {
            throw CheckFailure(message: "checkpoint could not start its resumed operation")
        }
        var resumedStages: [String] = []
        let resumedFailure = await checkpoint.run(operation: operation) { stage in
            resumedStages.append(String(describing: stage))
            return nil
        }
        try require(resumedFailure == nil && resumedStages == ["relaunch", "source"],
                    "restart checkpoint replayed restore or skipped a later stage")
        try require(checkpoint.completed == [.restore, .relaunch, .source]
            && !checkpoint.needsRecovery,
            "resumed checkpoint did not complete all remaining stages")
    }

    @MainActor
    private static func makeCoordinator(
        _ fixture: Fixture,
        clonePathLock: MaintainClonePathLock? = nil
    ) throws -> OnDemandEditCoordinator {
        let queue = PatchQueue(baseDirectoryURL: fixture.root.appendingPathComponent("patch-queue"))
        try queue.recordChecked(QueuedPatch(
            recipeId: fixture.sourceIdentity.changeId,
            signatureId: fixture.sourceIdentity.changeId,
            appSlug: fixture.sourceIdentity.appSlug,
            branchName: fixture.sourceIdentity.branchName,
            patchText: "fixture patch",
            baseCommit: fixture.baseCommit,
            appliedAt: Date(timeIntervalSince1970: 1_725_000_000)
        ))
        guard let defaults = UserDefaults(suiteName: "SavedVersionLifecycle-\(UUID().uuidString)") else {
            throw CheckFailure(message: "could not create disposable defaults suite")
        }
        let coordinator = OnDemandEditCoordinator(
            installProvenanceStore: InstallProvenanceStore(userDefaults: defaults),
            patchQueue: queue,
            clonePathLock: clonePathLock ?? MaintainClonePathLock(),
            deliveredUndoRecoveryStore: fixture.recoveryStore,
            appDeliveryReceiptStore: fixture.store
        )
        coordinator.installedApplicationPathForApp = { slug in
            slug == fixture.sourceIdentity.appSlug ? fixture.installed.path : nil
        }
        return coordinator
    }

    private static func makeFixture() throws -> Fixture {
        let files = FileManager.default
        let root = files.temporaryDirectory
            .appendingPathComponent("iris-saved-version-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let clone = root.appendingPathComponent("clone", isDirectory: true)
        let installed = root.appendingPathComponent("installed/Notes.app", isDirectory: true)
        let artifact = clone.appendingPathComponent("release/Notes.app", isDirectory: true)
        let backup = root.appendingPathComponent("backups/Notes.app", isDirectory: true)
        try files.createDirectory(at: clone, withIntermediateDirectories: true)
        try git(["init"], at: clone)
        try git(["config", "user.email", "fixture@example.invalid"], at: clone)
        try git(["config", "user.name", "Saved Version Fixture"], at: clone)
        try git(["config", "commit.gpgSign", "false"], at: clone)
        let source = clone.appendingPathComponent("source.txt")
        try Data("release/\n".utf8).write(to: clone.appendingPathComponent(".gitignore"))
        try Data("base source\n".utf8).write(to: source)
        try git(["add", ".gitignore", "source.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "base"], at: clone)
        let baseCommit = try git(["rev-parse", "HEAD"], at: clone)
        try git(["branch", "-M", "main"], at: clone)
        try git(["checkout", "-b", "iris-edit"], at: clone)
        try Data("edited source\n".utf8).write(to: source)
        try git(["add", "source.txt"], at: clone)
        try git(["commit", "--no-gpg-sign", "-m", "fixture edit"], at: clone)
        let editCommit = try git(["rev-parse", "HEAD"], at: clone)

        try makeBundle(installed, identifier: "com.fixture.savednotes", payload: "edited payload\n")
        try makeBundle(artifact, identifier: "com.fixture.savednotes", payload: "edited payload\n")
        try makeBundle(backup, identifier: "com.fixture.savednotes", payload: "base payload\n")
        let sourceIdentity = AppDeliveryReceipt.SourceIdentity(
            appSlug: "saved-notes", appName: "Saved Notes", clonePath: clone.path,
            branchName: "iris-edit", commit: editCommit, baseCommit: baseCommit,
            baseRef: "main", changeId: "saved-version-change"
        )
        let installedIdentity = AppDeliveryReceipt.bundleIdentity(atPath: installed.path)
        let replacementIdentity = AppDeliveryReceipt.bundleIdentity(atPath: artifact.path)
        let backupIdentity = AppDeliveryReceipt.bundleIdentity(atPath: backup.path)
        guard let installedIdentity, let replacementIdentity, let backupIdentity else {
            throw CheckFailure(message: "fixture bundle identity could not be captured")
        }
        let store = AppDeliveryReceiptStore(baseDirectory: root.appendingPathComponent("receipts"))
        let prepared = AppDeliveryReceipt(
            bundleIdentifier: "com.fixture.savednotes", installedPath: installed.path,
            sourceArtifactPath: artifact.path, backupPath: backup.path,
            phase: .prepared, sourceIdentity: sourceIdentity,
            installedBundleIdentity: backupIdentity,
            replacementBundleIdentity: replacementIdentity,
            backupBundleIdentity: backupIdentity
        )
        try store.savePrepared(prepared)
        let receipt = try store.transition(prepared, to: .installed)
        try require(receipt.installedBundleIdentity == backupIdentity,
                    "fixture pre-swap identity did not match retained backup")
        try require(receipt.replacementBundleIdentity == installedIdentity,
                    "fixture replacement identity did not match installed payload")
        let recoveryStore = DeliveredEditUndoRecoveryStore(
            recordURL: root.appendingPathComponent("undo-recovery.json")
        )
        return Fixture(root: root, clone: clone, installed: installed, artifact: artifact,
                       backup: backup, store: store, recoveryStore: recoveryStore,
                       receipt: receipt, sourceIdentity: sourceIdentity,
                       baseCommit: baseCommit, editCommit: editCommit)
    }

    private static func makeBundle(_ path: URL, identifier: String, payload: String) throws {
        let files = FileManager.default
        let contents = path.appendingPathComponent("Contents", isDirectory: true)
        try files.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Saved Notes",
            "CFBundleExecutable": "SavedNotes",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(payload.utf8).write(to: contents.appendingPathComponent("Payload.bin"))
        let nested = contents.appendingPathComponent("Resources/Nested", isDirectory: true)
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested fixture resource\n".utf8).write(to: nested.appendingPathComponent("Detail.txt"))
        let current = contents.appendingPathComponent("Resources/Current")
        try files.createSymbolicLink(atPath: current.path, withDestinationPath: "Nested/Detail.txt")
    }

    private static func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CheckFailure(message: "git \(arguments.joined(separator: " ")) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shell(_ command: String, at directory: URL) throws
        -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    @MainActor
    private static func wait(until condition: @escaping () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CheckFailure(message: "timed out waiting for coordinator callback")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CheckFailure(message: message) }
    }
}
