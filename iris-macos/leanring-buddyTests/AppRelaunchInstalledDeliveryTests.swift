//
//  AppRelaunchInstalledDeliveryTests.swift
//  leanring-buddyTests
//
//  The pure decision logic behind the founder's Sep 2 2026 override: after a
//  green build, the fresh copy is installed OVER the reader's installed app
//  rather than launched from the clone's build dir. The two things worth
//  pinning here are which copy counts as "the installed app to replace"
//  (never the clone's own build output; /Applications wins) and where the
//  pre-delivery snapshot for undo is kept. The ditto/replace filesystem work
//  itself has no unit coverage for the same reason the rest of this service
//  does not — the harness cannot copy real app bundles — so it stays a
//  supervised dogfood, like the relaunch mechanics above it.
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite struct AppRelaunchInstalledDeliveryTests {

    private static let clonePath = "/Users/someone/whimprflow"
    private static let buildDirCopy =
        "/Users/someone/whimprflow/target/release/bundle/macos/WhimprFlow.app"

    /// A copy under /Applications is what gets replaced, even when Launch
    /// Services' registered copy is the clone's own build output — which is
    /// exactly the case that misfired: the running copy was the build-dir one,
    /// so trusting the registered copy alone would have replaced nothing.
    @Test func prefersTheApplicationsCopyOverTheCloneBuildOutput() {
        let chosen = AppRelaunchService.chooseInstalledBundlePath(
            registeredPath: Self.buildDirCopy,
            applicationsPath: "/Applications/WhimprFlow.app",
            clonePath: Self.clonePath
        )
        #expect(chosen == "/Applications/WhimprFlow.app")
    }

    /// The clone's build output is NEVER "the installed app" — replacing it with
    /// itself would be a no-op that reads as success. With no copy outside the
    /// clone, there is nothing to replace and the caller falls back to the
    /// build-dir artifact.
    @Test func neverReturnsACopyInsideTheClone() {
        let chosen = AppRelaunchService.chooseInstalledBundlePath(
            registeredPath: Self.buildDirCopy,
            applicationsPath: nil,
            clonePath: Self.clonePath
        )
        #expect(chosen == nil)
    }

    /// A registered copy OUTSIDE the clone and outside /Applications (an app the
    /// reader keeps in ~/Applications, say) is still a real installed copy to
    /// replace when /Applications has none.
    @Test func fallsBackToARegisteredCopyOutsideTheClone() {
        let userApplications = "/Users/someone/Applications/WhimprFlow.app"
        let chosen = AppRelaunchService.chooseInstalledBundlePath(
            registeredPath: userApplications,
            applicationsPath: nil,
            clonePath: Self.clonePath
        )
        #expect(chosen == userApplications)
    }

    /// When BOTH candidates are the clone's build output (nothing installed
    /// separately at all), there is nothing to replace.
    @Test func returnsNilWhenEveryCandidateIsInsideTheClone() {
        let chosen = AppRelaunchService.chooseInstalledBundlePath(
            registeredPath: Self.buildDirCopy,
            applicationsPath: Self.buildDirCopy,
            clonePath: Self.clonePath
        )
        #expect(chosen == nil)
    }

    /// The undo snapshot lives under Application Support, keyed by a
    /// filesystem-safe form of the bundle id, and keeps the app's own bundle
    /// name so the restored copy is recognizably itself.
    @Test func deliveryBackupPathIsKeyedByBundleIdUnderApplicationSupport() {
        let backupPath = AppRelaunchService.deliveryBackupPath(
            forBundleId: "com.whimpr.whimprflow", appBundleName: "WhimprFlow.app"
        )
        #expect(backupPath.contains("Application Support/Iris/edit-delivery-backups"))
        #expect(backupPath.contains("com.whimpr.whimprflow"))
        #expect(backupPath.hasSuffix("WhimprFlow.app"))
    }

    // MARK: - Live filesystem round-trip (the real ditto + replaceItemAt swap)

    /// Build a minimal `.app`-shaped directory whose Info.plist marker records a
    /// version, so a swap can be proven by reading which version is at a path.
    private static func makeFakeBundle(at path: String, marker: String) {
        let contents = (path as NSString).appendingPathComponent("Contents")
        try? FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: (contents as NSString).appendingPathComponent("marker.txt"),
            contents: Data(marker.utf8)
        )
    }

    private static func markerOfBundle(at path: String) -> String? {
        let markerPath = (path as NSString)
            .appendingPathComponent("Contents/marker.txt")
        return (try? String(contentsOfFile: markerPath, encoding: .utf8))
    }

    /// The core the whole delivery rests on, exercised for real: snapshot the
    /// installed bundle, swap the fresh one into its exact path, and prove the
    /// installed path now holds the FRESH build while the snapshot holds the OLD
    /// one — then run the same primitive in reverse (the undo) and prove the
    /// original is back. Real `ditto`, real `replaceItemAt`, real temp bundles;
    /// no model, no network. This is the one corruption-risking primitive, so it
    /// earns a real round trip rather than a mocked one.
    @Test func swappingABundleReplacesItInPlaceAndTheSnapshotRestoresIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delivery-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let installedPath = root.appendingPathComponent("Applications/Demo.app").path
        let freshBuildPath = root.appendingPathComponent("clone/build/Demo.app").path
        let snapshotPath = root.appendingPathComponent("backups/Demo.app").path
        Self.makeFakeBundle(at: installedPath, marker: "installed-v1")
        Self.makeFakeBundle(at: freshBuildPath, marker: "fresh-v2")

        // Deliver: the installed copy becomes the fresh build; the old one is
        // preserved at the snapshot path for undo.
        let delivered = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installedPath, withBundleAt: freshBuildPath, snapshotTo: snapshotPath
        )
        #expect(delivered.isSuccess)
        #expect(Self.markerOfBundle(at: installedPath) == "fresh-v2")
        #expect(Self.markerOfBundle(at: snapshotPath) == "installed-v1")
        // The fresh build the swap consumed is still where it was built — it was
        // ditto-copied, not moved, so verification/other steps can still read it.
        #expect(Self.markerOfBundle(at: freshBuildPath) == "fresh-v2")

        // Undo: the snapshot goes back into the installed path.
        let undone = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installedPath, withBundleAt: snapshotPath, snapshotTo: nil
        )
        #expect(undone.isSuccess)
        #expect(Self.markerOfBundle(at: installedPath) == "installed-v1")
    }

    /// The delivery entry point, run for real against a bundle id that no app on
    /// this machine claims: there is nothing installed to replace, so it reports
    /// that honestly (the caller then launches the build-dir artifact) rather
    /// than inventing a target or failing. Uses a real fresh build on disk so
    /// the early "is the build there" guard is not what returns.
    @Test func installOverInstalledAppReportsNoInstalledCopyForAnUnknownBundleId() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-delivery-none-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let clonePath = root.appendingPathComponent("clone").path
        let freshBuildPath = root.appendingPathComponent("clone/build/Nope.app").path
        Self.makeFakeBundle(at: freshBuildPath, marker: "fresh")

        let result = await AppRelaunchService().installFreshBuildOverInstalledApp(
            macBundleId: "com.iris.test.definitely-not-installed-\(UUID().uuidString)",
            freshBuildArtifactPath: freshBuildPath,
            clonePath: clonePath
        )
        #expect(result == .noInstalledCopyToReplace)
    }
}
