import Foundation
import AppKit
import Darwin

// PRODUCTION_RESOLVER_SLICE

@main
struct InstalledAppResolverTests {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-installed-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let bundleID = "com.iris.portable.resolver"
        let active = root.appendingPathComponent("active/Demo.app")
        let stale = root.appendingPathComponent("stale/Demo.app")
        let applications = root.appendingPathComponent("Applications/Demo.app")
        let build = clone.appendingPathComponent("build/Demo.app")
        let wrongID = root.appendingPathComponent("wrong/Demo.app")
        try makeBundle(active, bundleID: bundleID)
        try makeBundle(stale, bundleID: bundleID)
        try makeBundle(applications, bundleID: bundleID)
        try makeBundle(build, bundleID: bundleID)
        try makeBundle(wrongID, bundleID: "com.iris.portable.other")

        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [active.path], clonePath: clone.path
            ) == .selected(path: canonical(active)),
            "running copy beats stale Launch Services registration"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [build.path], clonePath: clone.path
            ) == .selected(path: canonical(stale)),
            "clone-owned running build is excluded while the valid registered copy remains eligible"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [], clonePath: clone.path
            ) == .selected(path: canonical(stale)),
            "registered copy is selected when nothing is running"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: applications.path,
                runningPaths: [], clonePath: clone.path
            ) == .selected(path: canonical(applications)),
            "Applications copy wins when no different copy is running"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: applications.path,
                runningPaths: [active.path], clonePath: clone.path
            ), "conflicting running and Applications copies are rejected"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: nil,
                runningPaths: [active.path, stale.path], clonePath: clone.path
            ), "duplicate running copies are rejected"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: build.path, applicationsPath: build.path,
                runningPaths: [build.path], clonePath: clone.path
            ) == .absent,
            "clone-owned build output is never an installed target"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: nil,
                runningPaths: [wrongID.path], clonePath: clone.path
            ), "an invalid bundle-id-matched running candidate is rejected"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: nil,
                runningPaths: [nil], clonePath: clone.path
            ), "a bundle-id-matched running process with no bundle path is rejected"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: applications.path,
                runningPaths: [nil], clonePath: clone.path
            ), "unknown running identity blocks another installed target"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [active.path, nil], clonePath: clone.path
            ), "one invalid running identity blocks selection despite a valid running copy"
        )

        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: wrongID.path,
                runningPaths: [], clonePath: clone.path
            ), "a wrong-identity Applications candidate is rejected when no alternate exists"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: wrongID.path, applicationsPath: nil,
                runningPaths: [], clonePath: clone.path
            ), "a wrong-identity registered candidate is rejected when no alternate exists"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: wrongID.path,
                runningPaths: [], clonePath: clone.path
            ) == .selected(path: canonical(stale)),
            "a valid registered alternate wins over an unrelated invalid Applications candidate"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: wrongID.path, applicationsPath: applications.path,
                runningPaths: [], clonePath: clone.path
            ) == .selected(path: canonical(applications)),
            "a valid Applications target wins over an unrelated invalid registered candidate"
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: root.appendingPathComponent("stale-missing/Demo.app").path,
                applicationsPath: nil, runningPaths: [], clonePath: clone.path
            ) == .absent,
            "a genuinely missing stale Launch Services path remains absence"
        )

        let danglingAlias = root.appendingPathComponent("Dangling.app")
        try FileManager.default.createSymbolicLink(
            atPath: danglingAlias.path,
            withDestinationPath: root.appendingPathComponent("missing-target/Demo.app").path
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: danglingAlias.path, applicationsPath: nil,
                runningPaths: [], clonePath: clone.path
            ), "a dangling registered bundle symlink is rejected rather than treated as absence"
        )

        let alias = root.appendingPathComponent("active-alias")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: active.deletingLastPathComponent()
        )
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: nil,
                runningPaths: [active.path, alias.appendingPathComponent("Demo.app").path],
                clonePath: clone.path
            ) == .selected(path: canonical(active)),
            "canonical aliases of one running app do not look like duplicate processes"
        )

        let cloneAlias = root.appendingPathComponent("clone-alias")
        try FileManager.default.createSymbolicLink(at: cloneAlias, withDestinationURL: clone)
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: nil, applicationsPath: nil,
                runningPaths: [], clonePath: cloneAlias.path
            ), "a symlinked clone root is rejected"
        )

        let freshValidation = Resolver.validateFreshDeliveryArtifact(
            at: build.path, expectedBundleId: bundleID, insideClonePath: clone.path
        )
        expect(freshValidation == .valid(path: canonical(build)), "matching fresh bundle under clone validates")
        let mismatchedValidation = Resolver.validateFreshDeliveryArtifact(
            at: build.path, expectedBundleId: "com.iris.portable.wrong", insideClonePath: clone.path
        )
        expectInvalid(mismatchedValidation, "fresh bundle identifier mismatch is rejected")
        let outsideValidation = Resolver.validateFreshDeliveryArtifact(
            at: stale.path, expectedBundleId: bundleID, insideClonePath: clone.path
        )
        expectInvalid(outsideValidation, "fresh artifact outside the clone is rejected")

        let bundleAlias = root.appendingPathComponent("Symlink.app")
        try FileManager.default.createSymbolicLink(at: bundleAlias, withDestinationURL: active)
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [bundleAlias.path], clonePath: clone.path
            ), "an invalid running copy blocks selection of another installed copy"
        )
        expectRejected(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: stale.path, applicationsPath: nil,
                runningPaths: [active.path, bundleAlias.path], clonePath: clone.path
            ), "a valid and an invalid running copy are rejected as conflicting evidence"
        )
        expectInvalid(
            Resolver.validateInstalledDeliveryTarget(at: bundleAlias.path, expectedBundleId: bundleID),
            "symlinked installed bundle is rejected"
        )

        let cloneRootApp = root.appendingPathComponent("clone-root-app/Demo.app")
        try makeBundle(cloneRootApp, bundleID: bundleID)
        expect(
            Resolver.resolveInstalledDeliveryTarget(
                bundleId: bundleID, registeredPath: cloneRootApp.path,
                applicationsPath: cloneRootApp.path, runningPaths: [cloneRootApp.path],
                clonePath: cloneRootApp.path
            ) == .absent,
            "a candidate equal to the canonical clone root is excluded"
        )
        print("PASS: 27 installed-app resolver and filesystem assertions")
    }

    @MainActor
    private static func makeBundle(_ url: URL, bundleID: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }

    private static func expectRejected(
        _ resolution: Resolver.InstalledDeliveryTargetResolution,
        _ message: String
    ) {
        if case .rejected = resolution { expect(true, message) }
        else { expect(false, message) }
    }

    private static func expectInvalid(
        _ validation: Resolver.DeliveryBundleValidation,
        _ message: String
    ) {
        if case .invalid = validation { expect(true, message) }
        else { expect(false, message) }
    }
}
