import Foundation
@testable import IrisHarnessNative

@main
struct IrisTestAppDeliveryChecks {
    static func main() throws {
        let files = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("iris-delivery-boundary-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let projects = root.appendingPathComponent("Projects")
        let clone = projects.appendingPathComponent("notes")
        let installed = projects.appendingPathComponent("Apps/Notes.app")
        let artifact = clone.appendingPathComponent("release/Notes.app")
        let backups = root.appendingPathComponent("backups")
        let backup = backups.appendingPathComponent("one/Notes.app")
        let identifier = "com.publikhq.iris.test.notes"
        func bundle(_ path: URL, _ bundleIdentifier: String) throws {
            try files.createDirectory(at: path.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
                format: .xml, options: 0).write(to: path.appendingPathComponent("Contents/Info.plist"))
        }
        try bundle(installed, identifier); try bundle(artifact, identifier); try bundle(backup, identifier)
        let project = IrisTestProjectRegistry.Project(slug: "notes", name: "Notes", clonePath: clone.path,
            applicationPath: installed.path, buildArtifactPath: artifact.path,
            bundleIdentifier: identifier, pinnedCommit: String(repeating: "a", count: 40))
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: message, code: 1) }
        }
        func permitsInstall(_ path: String) -> Bool {
            IrisTestAppDelivery.permitsInstall(project: project, artifactPath: path, projectsDirectory: projects)
        }
        try require(permitsInstall(artifact.path), "exact fixture rejected")
        try require(!permitsInstall(installed.path), "installed app accepted as fresh artifact")
        let sibling = clone.appendingPathComponent("release/Other.app")
        try bundle(sibling, identifier)
        try require(!permitsInstall(sibling.path), "same identity sibling admitted")
        try bundle(artifact, "com.example.normal")
        try require(!permitsInstall(artifact.path), "wrong identity admitted")
        try bundle(artifact, identifier)
        print("PASS exact fixture, sibling artifact and wrong-identity boundaries")

        let launchable = clone.appendingPathComponent("release/mac-arm64/Notes.app")
        let launchableExecutable = launchable.appendingPathComponent("Contents/MacOS/Notes")
        try bundle(launchable, identifier)
        try files.createDirectory(at: launchableExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture executable".utf8).write(to: launchableExecutable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchableExecutable.path)
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: clone.path,
                producedAtOrAfter: .distantPast,
                expectedBundleIdentifier: identifier
            ) == launchable.path,
            "valid launchable artifact was not discovered"
        )
        try files.removeItem(at: launchable.appendingPathComponent("Contents/Info.plist"))
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: clone.path,
                producedAtOrAfter: .distantPast,
                expectedBundleIdentifier: identifier
            ) == nil,
            "malformed launch artifact was admitted"
        )
        print("PASS launchability discovery refuses a bundle without Info.plist")

        let savedArtifact = clone.appendingPathComponent("release/Preserved.app")
        try files.moveItem(at: artifact, to: savedArtifact)
        try files.createSymbolicLink(at: artifact, withDestinationURL: savedArtifact)
        try require(!permitsInstall(artifact.path), "symlink artifact admitted")
        try files.removeItem(at: artifact)
        try files.moveItem(at: savedArtifact, to: artifact)
        print("PASS symlink artifact refused even with matching bundle identity")

        func receipt(_ phase: AppDeliveryReceipt.Phase, _ backupPath: String = backup.path) -> AppDeliveryReceiptStore.Entry {
            .valid(AppDeliveryReceipt(bundleIdentifier: identifier, installedPath: installed.path,
                sourceArtifactPath: artifact.path, backupPath: backupPath, phase: phase))
        }
        func permitsRestore(_ path: String, _ entries: [AppDeliveryReceiptStore.Entry]) -> Bool {
            IrisTestAppDelivery.permitsRestore(project: project, installedPath: installed.path,
                backupPath: path, projectsDirectory: projects, backupDirectory: backups, receipts: entries)
        }
        try require(permitsRestore(backup.path, [receipt(.installed)]), "installed receipt rejected")
        try require(!permitsRestore(backup.path, []), "no receipt admitted")
        try require(!permitsRestore(backup.path, [receipt(.prepared)]), "uncertain prepared receipt replayed")
        try require(!permitsRestore(backup.path, [receipt(.restored)]), "already restored receipt replayed")
        let outside = root.appendingPathComponent("outside/Notes.app")
        try bundle(outside, identifier)
        try require(!permitsRestore(outside.path, [receipt(.installed, outside.path)]), "external backup admitted")
        try bundle(backup, "com.example.normal")
        try require(!permitsRestore(backup.path, [receipt(.installed)]), "wrong backup identity admitted")
        print("PASS receipt phase, absent receipt, external backup and wrong backup identity refusal")
        print("IRIS TEST DELIVERY BOUNDARIES PASS: 3 groups; no applications launched or real registry changed")
    }
}
