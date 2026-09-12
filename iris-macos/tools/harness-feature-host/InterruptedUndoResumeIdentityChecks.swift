import Foundation

@testable import IrisHarnessNative

/// Runs the restart-Undo identity validator against disposable Test paths.
/// The validator itself is read-only; this probe only creates and removes its
/// own fixture and never touches an installed or registered app.
@main
struct InterruptedUndoResumeIdentityChecks {
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
        let scratch: URL
        let runner: MaintainShellRunner
        let project: IrisTestProjectRegistry.Project
        let sourceIdentity: AppDeliveryReceipt.SourceIdentity
        let receipt: AppDeliveryReceipt
        let recoveryStore: DeliveredEditUndoRecoveryStore
        let record: DeliveredEditUndoRecoveryRecord
        let baseCommit: String
        let editCommit: String
    }

    @MainActor
    static func main() async {
        do {
            guard IrisTestEnvironment.isEnabled else {
                print("SKIP interrupted Undo identity checks: requires the Iris Test bundle")
                return
            }
            guard MaintainSandbox.isAvailable else {
                print("SKIP interrupted Undo identity checks: sandbox-exec is unavailable")
                return
            }
            try await runChecks()
            print("INTERRUPTED UNDO RESUME IDENTITY CHECKS PASS: 6 groups; disposable Test paths only")
        } catch {
            print("INTERRUPTED UNDO RESUME IDENTITY CHECKS FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    @MainActor
    private static func runChecks() async throws {
        let files = FileManager.default

        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(message: message) }
        }

        func fixturePolicy(repository: String, scratch: String) -> MaintainSandbox.ProcessPolicy {
            MaintainSandbox.testProcessPolicy(
                scratchDirectoryPath: scratch,
                additionalReadOnlyPaths: [
                    "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc",
                    "/private/var/db", "/private/var/select", "/opt/homebrew", "/usr/local",
                    "/Library/Developer", "/Applications/Xcode.app", "/dev"
                ],
                repositoryIsRegistered: { $0 == repository }
            )
        }

        func run(_ fixture: Fixture, _ command: String) async throws -> MaintainCommandResult {
            let result = try await fixture.runner.run(command, deadline: 30)
            guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
                throw CheckFailure(message: "fixture command failed (\(result.exitCode)): \(result.outputTail)")
            }
            return result
        }

        func output(_ fixture: Fixture, _ command: String) async throws -> String {
            let result = try await run(fixture, command)
            return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func makeBundle(_ path: URL, payload: String) throws {
            let contents = path.appendingPathComponent("Contents", isDirectory: true)
            try files.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": "com.publikhq.iris.test.resume",
                "CFBundleName": "Resume Fixture",
                "CFBundleExecutable": "ResumeFixture",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1"
            ]
            let plist = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0
            )
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try Data(payload.utf8).write(to: contents.appendingPathComponent("Payload.bin"))
        }

        func makeFixture() async throws -> Fixture {
            let support = IrisTestEnvironment.applicationSupportDirectory
            let root = support.appendingPathComponent(
                "Projects/iris-resume-check-\(UUID().uuidString)", isDirectory: true
            )
            let clone = root.appendingPathComponent("clone", isDirectory: true)
            let installed = support.appendingPathComponent(
                "Projects/Apps/Resume Fixture-\(UUID().uuidString).app", isDirectory: true
            )
            let artifact = clone.appendingPathComponent("build/Resume Fixture.app", isDirectory: true)
            let backup = IrisTestAppDelivery.backupDirectory
                .appendingPathComponent("com.publikhq.iris.test.resume", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("Resume Fixture.app", isDirectory: true)
            let scratch = IrisTestEnvironment.commandScratchDirectory
                .appendingPathComponent("iris-resume-check-\(UUID().uuidString)", isDirectory: true)
            let source = clone.appendingPathComponent("source.txt")
            try files.createDirectory(at: clone, withIntermediateDirectories: true)
            try files.createDirectory(at: scratch, withIntermediateDirectories: true)
            try files.createDirectory(at: installed, withIntermediateDirectories: true)
            try files.createDirectory(at: artifact, withIntermediateDirectories: true)
            try files.createDirectory(at: backup, withIntermediateDirectories: true)
            try Data("base source\n".utf8).write(to: source)
            // The build artifact lives below the clone just as it does for a
            // real project. Keep it ignored so the validator's clean-source
            // check measures source state, including untracked files, rather
            // than treating disposable build output as a dirty checkout.
            try Data("build/\n".utf8).write(to: clone.appendingPathComponent(".gitignore"))
            try makeBundle(installed, payload: "edited payload\n")
            try makeBundle(artifact, payload: "edited payload\n")
            try makeBundle(backup, payload: "base payload\n")

            let canonicalClone = MaintainSandbox.canonicalPath(clone.path)
            let canonicalScratch = MaintainSandbox.canonicalPath(scratch.path)
            let runner = try MaintainShellRunner(
                repoRootPath: canonicalClone,
                processPolicy: fixturePolicy(repository: canonicalClone, scratch: canonicalScratch)
            )
            let initialized = try await runner.run(
                    "git init -q -b main && git add -- source.txt .gitignore && "
                    + "git -c user.name=Fixture -c user.email=fixture@example.invalid "
                    + "commit --no-gpg-sign -qm baseline && git checkout -q -b iris/edit-resume",
                deadline: 30
            )
            guard initialized.succeeded else {
                throw CheckFailure(message: "could not create the fixture baseline")
            }
            try Data("edited source\n".utf8).write(to: source)
            let edit = try await runner.run(
                "git add -- source.txt && git -c user.name=Fixture -c user.email=fixture@example.invalid "
                    + "commit --no-gpg-sign -qm edited",
                deadline: 30
            )
            guard edit.succeeded else {
                throw CheckFailure(message: "could not create the fixture delivered commit")
            }
            let baseCommit = try await outputForRunner(
                runner, "git rev-parse --verify HEAD^", deadline: 30
            )
            let editCommit = try await outputForRunner(
                runner, "git rev-parse --verify HEAD^{commit}", deadline: 30
            )
            let project = IrisTestProjectRegistry.Project(
                slug: "resume-check",
                name: "Resume Fixture",
                clonePath: canonicalClone,
                applicationPath: installed.path,
                buildArtifactPath: artifact.path,
                bundleIdentifier: "com.publikhq.iris.test.resume",
                pinnedCommit: baseCommit
            )
            let sourceIdentity = AppDeliveryReceipt.SourceIdentity(
                appSlug: project.slug,
                appName: project.name,
                clonePath: project.clonePath,
                branchName: "iris/edit-resume",
                commit: editCommit,
                baseCommit: baseCommit,
                baseRef: "main",
                changeId: "resume-change"
            )
            guard let installedIdentity = AppDeliveryReceipt.bundleIdentity(atPath: installed.path),
                  let replacementIdentity = AppDeliveryReceipt.bundleIdentity(atPath: artifact.path),
                  let backupIdentity = AppDeliveryReceipt.bundleIdentity(atPath: backup.path),
                  installedIdentity == replacementIdentity else {
                throw CheckFailure(message: "fixture bundle identity could not be captured")
            }
            let receipt = AppDeliveryReceipt(
                identifier: UUID(),
                bundleIdentifier: project.bundleIdentifier,
                installedPath: project.applicationPath,
                sourceArtifactPath: project.buildArtifactPath,
                backupPath: backup.path,
                phase: .installed,
                sourceIdentity: sourceIdentity,
                // Delivery receipts retain the pre-replacement app identity
                // in this field; it must equal the backup payload identity.
                installedBundleIdentity: backupIdentity,
                replacementBundleIdentity: replacementIdentity,
                backupBundleIdentity: backupIdentity
            )
            let record = DeliveredEditUndoRecoveryRecord(
                identifier: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                appSlug: project.slug,
                appName: project.name,
                installedPath: project.applicationPath,
                backupPath: receipt.backupPath,
                clonePath: project.clonePath,
                branchName: sourceIdentity.branchName,
                originalCommit: sourceIdentity.baseCommit,
                originalRef: sourceIdentity.baseRef,
                deliveryReceiptIdentifier: receipt.identifier
            )
            let recoveryStore = DeliveredEditUndoRecoveryStore(
                recordURL: root.appendingPathComponent("undo-recovery.json")
            )
            return Fixture(
                root: root, clone: clone, installed: installed, artifact: artifact,
                backup: backup, scratch: scratch, runner: runner, project: project,
                sourceIdentity: sourceIdentity, receipt: receipt,
                recoveryStore: recoveryStore, record: record,
                baseCommit: baseCommit, editCommit: editCommit
            )
        }

        // Kept separate because the fixture root is intentionally a child of
        // Test's Projects directory while the Git runner is already canonical.
        func outputForRunner(
            _ runner: MaintainShellRunner,
            _ command: String,
            deadline: TimeInterval
        ) async throws -> String {
            let result = try await runner.run(command, deadline: deadline)
            guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
                throw CheckFailure(message: "fixture query failed: \(result.outputTail)")
            }
            return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func sourceSnapshot(_ fixture: Fixture) async throws -> (String, String, String) {
            (
                try await output(fixture, "git rev-parse --verify HEAD^{commit}"),
                try await output(fixture, "git rev-parse --abbrev-ref HEAD"),
                try await output(fixture, "git status --porcelain=v1 --untracked-files=all")
            )
        }

        func requireFailure(
            _ operation: () async throws -> InterruptedUndoResumeIdentity,
            _ expected: InterruptedUndoResumeIdentity.Failure,
            _ message: String
        ) async throws {
            do {
                _ = try await operation()
                throw CheckFailure(message: message + " was accepted")
            } catch let failure as InterruptedUndoResumeIdentity.Failure {
                try require(failure == expected, message + " failed as \(failure), expected \(expected)")
            }
        }

        let fixture = try await makeFixture()
        defer {
            try? files.removeItem(at: fixture.root)
            try? files.removeItem(at: fixture.installed)
            try? files.removeItem(at: fixture.backup.deletingLastPathComponent().deletingLastPathComponent())
            try? files.removeItem(at: fixture.scratch)
        }

        let beforeInstalledSource = try await sourceSnapshot(fixture)
        let captured = try await InterruptedUndoResumeIdentity.capture(
            record: fixture.record,
            receipt: fixture.receipt,
            project: fixture.project,
            runner: fixture.runner
        )
        try require(captured.sourceState == .delivered, "installed receipt did not require the delivered branch")
        try require(await captured.stillMatches(
            record: fixture.record,
            receipt: fixture.receipt,
            project: fixture.project,
            runner: fixture.runner
        ), "unchanged installed identity did not match itself")
        try require(try await sourceSnapshot(fixture) == beforeInstalledSource,
                    "installed capture mutated the Git source")
        print("PASS installed phase binds receipt, payload hashes and clean delivered branch")

        // Model the crash window after the installed bundle has been swapped
        // to the saved app but before AppDeliveryReceiptStore can transition
        // the receipt from .installed to .restored. The recovery marker is
        // written first, and the actual swap is the real disposable bundle
        // primitive. A fresh capture must accept only the exact old payload
        // plus the durable marker; every changed boundary remains fail-closed.
        func captureFromMarker(_ candidate: Fixture) async throws -> InterruptedUndoResumeIdentity {
            guard case .pending(let marker) = candidate.recoveryStore.load(),
                  marker == candidate.record,
                  marker.deliveryReceiptIdentifier == candidate.receipt.identifier else {
                throw CheckFailure(message: "durable interrupted Undo marker was absent or mismatched")
            }
            return try await InterruptedUndoResumeIdentity.capture(
                record: marker,
                receipt: candidate.receipt,
                project: candidate.project,
                runner: candidate.runner
            )
        }

        func swapToSavedBundle(_ candidate: Fixture) throws {
            let swapGuard = DeliveredEditUndoRecoveryStore(
                recordURL: candidate.root.appendingPathComponent("swap-operation-marker.json")
            )
            let outcome = AppRelaunchService.atomicallyReplaceBundle(
                installedPath: candidate.installed.path,
                withBundleAt: candidate.backup.path,
                snapshotTo: nil,
                undoRecoveryStore: swapGuard
            )
            try require(outcome.isSuccess, "disposable atomic restore swap failed")
            try require(AppDeliveryReceipt.bundleIdentity(atPath: candidate.installed.path)
                == candidate.receipt.backupBundleIdentity,
                "swap did not leave the exact saved payload installed")
            try require(AppDeliveryReceipt.bundleIdentity(atPath: candidate.backup.path)
                == candidate.receipt.backupBundleIdentity,
                "swap consumed or changed the retained backup")
        }

        let interrupted = try await makeFixture()
        defer {
            try? files.removeItem(at: interrupted.root)
            try? files.removeItem(at: interrupted.installed)
            try? files.removeItem(at: interrupted.backup)
            try? files.removeItem(at: interrupted.scratch)
        }
        try interrupted.recoveryStore.saveBeforeStarting(interrupted.record)
        try require(interrupted.recoveryStore.load() == .pending(interrupted.record),
                    "interrupted Undo marker did not survive its initial write")
        try swapToSavedBundle(interrupted)
        let interruptedCapture = try await captureFromMarker(interrupted)
        try require(interruptedCapture.appState == .restored,
                    "receipt-still-installed swap window was not recognized as restored")
        try require(interruptedCapture.sourceState == .delivered,
                    "app-only interrupted restore changed the delivered source state")
        try require(await interruptedCapture.stillMatches(
            record: interrupted.record,
            receipt: interrupted.receipt,
            project: interrupted.project,
            runner: interrupted.runner
        ), "matching interrupted restore identity did not survive a fresh recapture")
        print("PASS atomic app restore is resumable with the exact durable marker")

        let thirdPayload = try await makeFixture()
        defer {
            try? files.removeItem(at: thirdPayload.root)
            try? files.removeItem(at: thirdPayload.installed)
            try? files.removeItem(at: thirdPayload.backup)
            try? files.removeItem(at: thirdPayload.scratch)
        }
        try thirdPayload.recoveryStore.saveBeforeStarting(thirdPayload.record)
        try swapToSavedBundle(thirdPayload)
        try Data("third payload\n".utf8)
            .write(to: thirdPayload.installed.appendingPathComponent("Contents/Payload.bin"))
        try await requireFailure({ try await captureFromMarker(thirdPayload) },
                                 .receiptPayloadMismatch,
                                 "third installed payload")
        print("PASS third same-ID payload is refused after an interrupted swap")

        let tamperedSource = try await makeFixture()
        defer {
            try? files.removeItem(at: tamperedSource.root)
            try? files.removeItem(at: tamperedSource.installed)
            try? files.removeItem(at: tamperedSource.backup)
            try? files.removeItem(at: tamperedSource.scratch)
        }
        try tamperedSource.recoveryStore.saveBeforeStarting(tamperedSource.record)
        try swapToSavedBundle(tamperedSource)
        try Data("unreviewed source change\n".utf8)
            .write(to: tamperedSource.clone.appendingPathComponent("source.txt"))
        try await requireFailure({ try await captureFromMarker(tamperedSource) },
                                 .sourceStateMismatch,
                                 "tampered source")
        print("PASS tampered source is refused without consuming the app or marker")

        let changedBackup = try await makeFixture()
        defer {
            try? files.removeItem(at: changedBackup.root)
            try? files.removeItem(at: changedBackup.installed)
            try? files.removeItem(at: changedBackup.backup)
            try? files.removeItem(at: changedBackup.scratch)
        }
        try changedBackup.recoveryStore.saveBeforeStarting(changedBackup.record)
        try swapToSavedBundle(changedBackup)
        try Data("changed saved payload\n".utf8)
            .write(to: changedBackup.backup.appendingPathComponent("Contents/Payload.bin"))
        try await requireFailure({ try await captureFromMarker(changedBackup) },
                                 .receiptPayloadMismatch,
                                 "changed backup")
        print("PASS changed backup is refused by the recorded digest")

        let absentMarker = try await makeFixture()
        defer {
            try? files.removeItem(at: absentMarker.root)
            try? files.removeItem(at: absentMarker.installed)
            try? files.removeItem(at: absentMarker.backup)
            try? files.removeItem(at: absentMarker.scratch)
        }
        try swapToSavedBundle(absentMarker)
        try require(absentMarker.recoveryStore.load() == .absent,
                    "fresh interrupted fixture unexpectedly had a recovery marker")
        do {
            _ = try await captureFromMarker(absentMarker)
            throw CheckFailure(message: "absent interrupted Undo marker was accepted")
        } catch let failure as CheckFailure {
            try require(failure.message.contains("marker was absent"),
                        "absent marker refusal was not explicit")
        }
        print("PASS absent durable marker refuses interrupted-capture admission")

        // The restored app remains backed by the same exact backup. Detach at
        // the base commit to exercise the source-restore path without asking
        // the validator to checkout, reset or clean anything.
        try Data("base payload\n".utf8).write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
        _ = try await run(fixture, "git checkout --detach -q \(fixture.baseCommit)")
        let restoredReceipt = AppDeliveryReceipt(
            identifier: fixture.receipt.identifier,
            bundleIdentifier: fixture.receipt.bundleIdentifier,
            installedPath: fixture.receipt.installedPath,
            sourceArtifactPath: fixture.receipt.sourceArtifactPath,
            backupPath: fixture.receipt.backupPath,
            phase: .restored,
            sourceIdentity: fixture.receipt.sourceIdentity,
            installedBundleIdentity: fixture.receipt.installedBundleIdentity,
            replacementBundleIdentity: fixture.receipt.replacementBundleIdentity,
            backupBundleIdentity: fixture.receipt.backupBundleIdentity
        )
        let restored = try await InterruptedUndoResumeIdentity.capture(
            record: fixture.record,
            receipt: restoredReceipt,
            project: fixture.project,
            runner: fixture.runner
        )
        try require(restored.sourceState == .restored,
                    "restored receipt did not accept the exact detached base commit")
        print("PASS restored phase accepts exact backup payload and already-restored base source")

        try await requireFailure({
            let inconsistent = AppDeliveryReceipt(
                identifier: fixture.receipt.identifier,
                bundleIdentifier: fixture.receipt.bundleIdentifier,
                installedPath: fixture.receipt.installedPath,
                sourceArtifactPath: fixture.receipt.sourceArtifactPath,
                backupPath: fixture.receipt.backupPath,
                phase: .restored,
                sourceIdentity: fixture.receipt.sourceIdentity,
                installedBundleIdentity: fixture.receipt.replacementBundleIdentity,
                replacementBundleIdentity: fixture.receipt.replacementBundleIdentity,
                backupBundleIdentity: fixture.receipt.backupBundleIdentity
            )
            return try await InterruptedUndoResumeIdentity.capture(
                record: fixture.record, receipt: inconsistent, project: fixture.project, runner: fixture.runner
            )
        }, .receiptPayloadMismatch, "inconsistent pre-replacement identity")
        print("PASS inconsistent receipt identities are refused")

        try await requireFailure({
            guard let replacement = fixture.receipt.replacementBundleIdentity else {
                throw CheckFailure(message: "fixture replacement identity unexpectedly missing")
            }
            let wrongBundle = AppDeliveryReceipt.BundleIdentity(
                bundleIdentifier: "com.publikhq.iris.test.other",
                bundleName: replacement.bundleName,
                shortVersion: replacement.shortVersion,
                version: replacement.version,
                executable: replacement.executable,
                contentDigest: replacement.contentDigest
            )
            let inconsistent = AppDeliveryReceipt(
                identifier: fixture.receipt.identifier,
                bundleIdentifier: fixture.receipt.bundleIdentifier,
                installedPath: fixture.receipt.installedPath,
                sourceArtifactPath: fixture.receipt.sourceArtifactPath,
                backupPath: fixture.receipt.backupPath,
                phase: .restored,
                sourceIdentity: fixture.receipt.sourceIdentity,
                installedBundleIdentity: fixture.receipt.installedBundleIdentity,
                replacementBundleIdentity: wrongBundle,
                backupBundleIdentity: fixture.receipt.backupBundleIdentity
            )
            return try await InterruptedUndoResumeIdentity.capture(
                record: fixture.record, receipt: inconsistent, project: fixture.project, runner: fixture.runner
            )
        }, .receiptPayloadMismatch, "wrong receipt bundle identifier")
        print("PASS receipt bundle-identifier mismatch is refused")

        try await requireFailure({
            var changed = restoredReceipt
            changed = AppDeliveryReceipt(
                identifier: changed.identifier,
                bundleIdentifier: changed.bundleIdentifier,
                installedPath: changed.installedPath,
                sourceArtifactPath: changed.sourceArtifactPath,
                backupPath: changed.backupPath,
                phase: .prepared,
                sourceIdentity: changed.sourceIdentity,
                installedBundleIdentity: changed.installedBundleIdentity,
                replacementBundleIdentity: changed.replacementBundleIdentity,
                backupBundleIdentity: changed.backupBundleIdentity
            )
            return try await InterruptedUndoResumeIdentity.capture(
                record: fixture.record, receipt: changed, project: fixture.project, runner: fixture.runner
            )
        }, .recordReceiptMismatch, "prepared receipt")
        print("PASS prepared receipt is refused")

        try await requireFailure({
            try Data("tampered payload\n".utf8)
                .write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
            return try await InterruptedUndoResumeIdentity.capture(
                record: fixture.record, receipt: fixture.receipt, project: fixture.project, runner: fixture.runner
            )
        }, .receiptPayloadMismatch, "tampered installed payload")
        try Data("base payload\n".utf8)
            .write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
        print("PASS changed installed payload is refused by exact digest")

        // Return only the fixture to a valid delivered state, then make source
        // dirty. No helper call is allowed to clean it or move its branch.
        try Data("edited payload\n".utf8)
            .write(to: fixture.installed.appendingPathComponent("Contents/Payload.bin"))
        _ = try await run(fixture, "git checkout -q iris/edit-resume")
        try Data("reader work\n".utf8).write(to: fixture.clone.appendingPathComponent("reader.txt"))
        try await requireFailure({
            try await InterruptedUndoResumeIdentity.capture(
                record: fixture.record, receipt: fixture.receipt, project: fixture.project, runner: fixture.runner
            )
        }, .sourceStateMismatch, "dirty source")
        try require((try await output(fixture, "git status --porcelain=v1 --untracked-files=all")).contains("reader.txt"),
                    "dirty-source refusal cleaned the reader file")
        print("PASS dirty source is refused without cleanup")
    }
}
