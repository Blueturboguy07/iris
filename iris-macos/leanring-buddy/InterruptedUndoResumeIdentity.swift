import Foundation

/// The read-only identity for resuming an Undo whose process ended after the
/// installed-app step. A captured value is evidence for one exact Test
/// delivery; it is never a command to move an app or a Git checkout.
nonisolated struct InterruptedUndoResumeIdentity: Equatable, Sendable {
    nonisolated enum SourceState: String, Equatable, Sendable {
        case delivered
        case restored
    }

    nonisolated enum AppState: String, Equatable, Sendable {
        case delivered
        case restored
    }

    enum Failure: Error, LocalizedError, Equatable, Sendable {
        case notEligible
        case recordReceiptMismatch
        case sourceIdentityMismatch
        case projectMismatch
        case receiptPayloadMismatch
        case sourceStateMismatch

        var errorDescription: String? {
            switch self {
            case .notEligible:
                return "Interrupted Undo resume requires the Iris Test process policy."
            case .recordReceiptMismatch:
                return "The interrupted Undo record does not name the selected delivery receipt."
            case .sourceIdentityMismatch:
                return "The interrupted Undo record does not match the delivered source identity."
            case .projectMismatch:
                return "The interrupted Undo record does not match the current Test project."
            case .receiptPayloadMismatch:
                return "The installed app or saved backup no longer matches the delivery receipt."
            case .sourceStateMismatch:
                return "The source checkout is not clean at the delivered or already-restored revision."
            }
        }
    }

    let record: DeliveredEditUndoRecoveryRecord
    let receipt: AppDeliveryReceipt
    let project: IrisTestProjectRegistry.Project
    let sourceState: SourceState
    let appState: AppState

    /// Capture the exact restart state without mutating the app, backup or
    /// checkout. The caller must provide a runner made with Test's explicit
    /// process policy; this method never constructs an ordinary fallback.
    static func capture(
        record: DeliveredEditUndoRecoveryRecord,
        receipt: AppDeliveryReceipt,
        project: IrisTestProjectRegistry.Project,
        runner: MaintainShellRunner
    ) async throws -> Self {
        guard IrisTestEnvironment.isEnabled,
              MaintainSandbox.isAvailable,
              runner.isTestProcessPolicy,
              runner.repoRootPath == project.clonePath else {
            throw Failure.notEligible
        }
        guard record.isValid, receipt.isValid,
              record.deliveryReceiptIdentifier == receipt.identifier,
              receipt.phase == .installed || receipt.phase == .restored else {
            throw Failure.recordReceiptMismatch
        }

        guard let sourceIdentity = receipt.sourceIdentity,
              let recordInstalledPath = record.installedPath,
              let recordBackupPath = record.backupPath,
              sourceIdentity.isValid,
              record.appSlug == sourceIdentity.appSlug,
              record.appName == sourceIdentity.appName,
              record.clonePath == sourceIdentity.clonePath,
              record.branchName == sourceIdentity.branchName,
              record.originalCommit == sourceIdentity.baseCommit,
              record.originalRef == sourceIdentity.baseRef,
              recordInstalledPath == receipt.installedPath,
              recordBackupPath == receipt.backupPath else {
            throw Failure.sourceIdentityMismatch
        }

        guard project.slug == sourceIdentity.appSlug,
              project.name == sourceIdentity.appName,
              project.clonePath == sourceIdentity.clonePath,
              project.applicationPath == receipt.installedPath,
              project.buildArtifactPath == receipt.sourceArtifactPath,
              project.bundleIdentifier == receipt.bundleIdentifier,
              project.applicationPath == recordInstalledPath,
              project.clonePath == runner.repoRootPath,
              IrisTestProjectRegistry.contains(
                  receipt.backupPath,
                  within: IrisTestAppDelivery.backupDirectory
              ),
              IrisTestProjectRegistry.contains(
                  receipt.sourceArtifactPath,
                  within: URL(fileURLWithPath: project.clonePath)
              ) else {
            throw Failure.projectMismatch
        }

        guard let installedExpected = receipt.replacementBundleIdentity,
              let backupExpected = receipt.backupBundleIdentity,
              let installedRecorded = receipt.installedBundleIdentity,
              installedExpected.isValid,
              backupExpected.isValid,
              installedRecorded.isValid,
              installedRecorded == backupExpected,
              installedRecorded.bundleIdentifier == receipt.bundleIdentifier,
              installedExpected.bundleIdentifier == receipt.bundleIdentifier,
              backupExpected.bundleIdentifier == receipt.bundleIdentifier,
              installedExpected.contentDigest != nil,
              backupExpected.contentDigest != nil,
              installedRecorded.contentDigest != nil else {
            throw Failure.receiptPayloadMismatch
        }

        let actualPayloads = await Task.detached(priority: .userInitiated) {
            (
                AppDeliveryReceipt.bundleIdentity(atPath: receipt.installedPath),
                AppDeliveryReceipt.bundleIdentity(atPath: receipt.backupPath)
            )
        }.value
        guard actualPayloads.1 == backupExpected else {
            throw Failure.receiptPayloadMismatch
        }
        let appState: AppState
        if actualPayloads.0 == backupExpected {
            // The atomic swap can finish before the receipt is updated. Only
            // this exact marker, source and full backup identity can establish
            // the completed app stage; an ordinary saved receipt cannot.
            appState = .restored
        } else if receipt.phase == .installed, actualPayloads.0 == installedExpected {
            appState = .delivered
        } else {
            throw Failure.receiptPayloadMismatch
        }

        let sourceState = try await sourceState(
            record: record,
            sourceIdentity: sourceIdentity,
            runner: runner
        )
        return Self(record: record, receipt: receipt, project: project,
                    sourceState: sourceState, appState: appState)
    }

    /// Re-run the complete read-only capture and compare its immutable result.
    /// A failed recheck is false, never a reason to repair or reset anything.
    func stillMatches(
        record: DeliveredEditUndoRecoveryRecord,
        receipt: AppDeliveryReceipt,
        project: IrisTestProjectRegistry.Project,
        runner: MaintainShellRunner
    ) async -> Bool {
        guard let current = try? await Self.capture(
            record: record, receipt: receipt, project: project, runner: runner
        ) else { return false }
        return current == self
    }

    private static func sourceState(
        record: DeliveredEditUndoRecoveryRecord,
        sourceIdentity: AppDeliveryReceipt.SourceIdentity,
        runner: MaintainShellRunner
    ) async throws -> SourceState {
        guard let status = try? await checkedOutput(
            "git status --porcelain=v1 --untracked-files=all", runner: runner
        ), status.isEmpty,
        let branch = try? await checkedOutput(
            "git rev-parse --abbrev-ref HEAD", runner: runner
        ),
        let commit = try? await checkedOutput(
            "git rev-parse --verify HEAD^{commit}", runner: runner
        ) else {
            throw Failure.sourceStateMismatch
        }

        if commit == sourceIdentity.commit, branch == sourceIdentity.branchName {
            return .delivered
        }

        guard commit == sourceIdentity.baseCommit else {
            throw Failure.sourceStateMismatch
        }
        if let baseRef = sourceIdentity.baseRef, baseRef != "HEAD" {
            // A source restore may intentionally detach at the exact base
            // commit when the old ref is the delivered edit branch. A named
            // base ref remains acceptable when it still points at that commit.
            guard branch == baseRef || branch == "HEAD" else {
                throw Failure.sourceStateMismatch
            }
        } else {
            guard branch == "HEAD" else { throw Failure.sourceStateMismatch }
        }
        // Keep the record in the validation contract so an accidental future
        // change cannot make this branch accept an unrelated source record.
        guard record.originalCommit == sourceIdentity.baseCommit else {
            throw Failure.sourceStateMismatch
        }
        return .restored
    }

    private static func checkedOutput(
        _ command: String,
        runner: MaintainShellRunner
    ) async throws -> String {
        let result = try await runner.run(command, deadline: 30)
        guard result.succeeded, result.bytesDroppedBeforeTail == 0 else {
            throw Failure.sourceStateMismatch
        }
        return result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
