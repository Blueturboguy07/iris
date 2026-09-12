import AppKit
import Foundation

/// Test delivery uses explicit registry paths, never Launch Services discovery.
@MainActor
enum IrisTestAppDelivery {
    static func install(
        project: IrisTestProjectRegistry.Project,
        artifactPath: String,
        sourceIdentity: AppDeliveryReceipt.SourceIdentity,
        service: AppRelaunchService
    ) async -> AppRelaunchService.InstalledDeliveryResult {
        guard IrisTestEnvironment.isEnabled,
              IrisTestProjectRegistry.project(slug: project.slug) == project,
              sourceIdentity.appSlug == project.slug, sourceIdentity.clonePath == project.clonePath,
              sourceIdentity.isValid,
              await SavedEditDeliveryIdentity(clonePath: sourceIdentity.clonePath,
                branchName: sourceIdentity.branchName, commit: sourceIdentity.commit).stillMatchesSource(),
              permitsInstall(project: project, artifactPath: artifactPath,
                             projectsDirectory: IrisTestProjectRegistry.projectsDirectory),
              NSRunningApplication.runningApplications(withBundleIdentifier: project.bundleIdentifier).isEmpty else {
            return .deliveryFailed(reason: "Iris Test could not confirm its stopped, registered test copy. No installed app was replaced.")
        }
        let backupPath = AppRelaunchService.deliveryBackupPath(
            forBundleId: project.bundleIdentifier,
            appBundleName: URL(fileURLWithPath: project.applicationPath).lastPathComponent)
        guard IrisTestProjectRegistry.contains(backupPath, within: backupDirectory) else {
            return .deliveryFailed(reason: "Iris Test refused a recovery location outside its own data folder.")
        }
        let store = service.deliveryReceiptStore
        return await Task.detached(priority: .userInitiated) {
            // Recheck after the executor hop, before any recovery write or swap.
            guard IrisTestProjectRegistry.project(slug: project.slug) == project,
                  permitsInstall(project: project, artifactPath: artifactPath,
                                 projectsDirectory: IrisTestProjectRegistry.projectsDirectory),
                  NSRunningApplication.runningApplications(withBundleIdentifier: project.bundleIdentifier).isEmpty else {
                return AppRelaunchService.InstalledDeliveryResult.deliveryFailed(
                    reason: "The test app changed or started again before delivery. No files were replaced.")
            }
            return AppRelaunchService.replaceBundleWithRecoveryReceipt(
                bundleIdentifier: project.bundleIdentifier, installedPath: project.applicationPath,
                artifactPath: artifactPath, backupPath: backupPath, grantsMayReset: true, store: store,
                sourceIdentity: sourceIdentity)
        }.value
    }

    static func restore(installedPath: String, backupPath: String,
                        service: AppRelaunchService) async -> Bool {
        guard IrisTestEnvironment.isEnabled,
              let project = IrisTestProjectRegistry.projects().first(where: { $0.applicationPath == installedPath }),
              permitsRestore(project: project, installedPath: installedPath, backupPath: backupPath,
                             projectsDirectory: IrisTestProjectRegistry.projectsDirectory,
                             backupDirectory: backupDirectory, receipts: service.deliveryReceiptStore.entries()),
              NSRunningApplication.runningApplications(withBundleIdentifier: project.bundleIdentifier).isEmpty else { return false }
        return await service.restoreInstalledAppFromBackup(installedPath: installedPath, backupPath: backupPath) {
            IrisTestProjectRegistry.project(slug: project.slug) == project
                && IrisTestProjectRegistry.contains(installedPath, within: IrisTestProjectRegistry.projectsDirectory)
                && IrisTestProjectRegistry.contains(backupPath, within: backupDirectory)
        }
    }

    nonisolated static var backupDirectory: URL {
        IrisTestEnvironment.applicationSupportDirectory.appendingPathComponent("edit-delivery-backups", isDirectory: true)
    }

    nonisolated static func permitsInstall(
        project: IrisTestProjectRegistry.Project, artifactPath: String, projectsDirectory: URL
    ) -> Bool {
        IrisTestProjectRegistry.isValidProject(project, within: projectsDirectory,
            applicationBundleIdentifier: AppRelaunchService.artifactBundleIdentifier(atPath: project.applicationPath))
            && artifactPath == project.buildArtifactPath
            && IrisTestProjectRegistry.contains(artifactPath, within: URL(fileURLWithPath: project.clonePath))
            && AppRelaunchService.artifactBundleIdentifier(atPath: artifactPath) == project.bundleIdentifier
    }

    nonisolated static func permitsRestore(
        project: IrisTestProjectRegistry.Project, installedPath: String, backupPath: String,
        projectsDirectory: URL, backupDirectory: URL, receipts: [AppDeliveryReceiptStore.Entry]
    ) -> Bool {
        guard installedPath == project.applicationPath,
              IrisTestProjectRegistry.isValidProject(project, within: projectsDirectory,
                applicationBundleIdentifier: AppRelaunchService.artifactBundleIdentifier(atPath: installedPath)),
              IrisTestProjectRegistry.contains(backupPath, within: backupDirectory),
              AppRelaunchService.artifactBundleIdentifier(atPath: backupPath) == project.bundleIdentifier else { return false }
        return receipts.contains { entry in
            guard case .valid(let receipt) = entry else { return false }
            return receipt.phase == .installed && receipt.bundleIdentifier == project.bundleIdentifier
                && receipt.installedPath == installedPath && receipt.backupPath == backupPath
                && receipt.sourceArtifactPath == project.buildArtifactPath
        }
    }
}
