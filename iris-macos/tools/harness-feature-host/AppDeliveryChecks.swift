import Foundation
@testable import IrisHarnessNative

private enum AppDeliveryCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Standalone checks for the cross-app packaging, relaunch and delivery seams.
/// Every filesystem mutation is below one disposable fixture directory. This
/// host never launches an app, consults a provider, or looks up a real target.
@main
struct AppDeliveryChecks {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-recipe" {
            let recipe = RepoRecipeService.deriveRecipe(repoRootPath: CommandLine.arguments[2])
            print("RECIPE stack=\(recipe.ecosystemIdentifier) build=\(recipe.build?.commandLine ?? "none") tests=\(recipe.test?.commandLine ?? "none")")
            return
        }
        if CommandLine.arguments.count == 5,
           CommandLine.arguments[1] == "--inspect-read-only" {
            try inspectReadOnly(arguments: Array(CommandLine.arguments.dropFirst(2)))
            return
        }

        let fileManager = FileManager.default
        let fixtureRoot = fileManager.temporaryDirectory
            .appendingPathComponent("iris-app-delivery-check-\(UUID().uuidString) with spaces")
        try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: fixtureRoot) }

        var passedGroups = 0
        func pass(_ label: String) {
            passedGroups += 1
            print("PASS \(label)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw AppDeliveryCheckError.failed(message) }
        }

        try checkStackAndPackagingCommands(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try checkShippingRecipe(fixtureRoot: fixtureRoot, require: require, pass: pass)
        try checkElectronArtifactLayouts(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try checkTauriArtifactLayouts(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try checkMissingStaleAndMalformedArtifacts(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try checkArchitecturePreference(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try await checkPureRelaunchGuards(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )
        try await checkBundleDeliveryAndUndo(
            fixtureRoot: fixtureRoot, require: require, pass: pass
        )

        print("APP DELIVERY CHECKS PASS: \(passedGroups) groups")
    }

    @MainActor
    private static func checkShippingRecipe(
        fixtureRoot: URL, require: (Bool, String) throws -> Void, pass: (String) -> Void
    ) throws {
        let root = fixtureRoot.appendingPathComponent("mixed-shell")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src-tauri"), withIntermediateDirectories: true)
        try Data("console.log('entry');".utf8).write(to: root.appendingPathComponent("main.cjs"))
        try Data("[package]\nname = \"fixture\"\nversion = \"0.1.0\"\n[dependencies]\ntauri = \"2\"\n".utf8)
            .write(to: root.appendingPathComponent("src-tauri/Cargo.toml"))
        try Data("{\"build\":{\"beforeBuildCommand\":\"npm run build\"}}".utf8)
            .write(to: root.appendingPathComponent("src-tauri/tauri.conf.json"))
        var package: [String: Any] = ["main": "main.cjs", "dependencies": ["electron": "1"],
            "scripts": ["build": "vite build", "dist:mac": "electron-builder --mac"]]
        func save() throws {
            try JSONSerialization.data(withJSONObject: package).write(to: root.appendingPathComponent("package.json"))
        }
        try save()
        let recipe = RepoRecipeService.deriveRecipe(repoRootPath: root.path)
        try require(recipe.ecosystemIdentifier == "node/electron", "strong Electron shipping evidence lost to Tauri scaffold")
        try require(recipe.build?.commandLine == "npm run build", "mixed shell still received a Cargo verification build")
        package["scripts"] = ["build": "vite build", "dist:mac": "electron-builder --mac", "native": "npx tauri build"]
        try save()
        try require(!RepoRecipeElectronShippingEvidence.inspect(packageJSON: package, repoRootPath: root.path).isStrong,
                    "two explicit shipping shells silently selected Electron")
        for fake in ["echo electron-builder", "printf electron-builder", "echo 'fake; electron-builder'"] {
            package["scripts"] = ["build": "vite build", "dist:mac": fake]
            try require(!RepoRecipeElectronShippingEvidence.inspect(packageJSON: package, repoRootPath: root.path).isStrong,
                        "printed tool name was treated as a packaging command")
        }
        package["scripts"] = ["build": "vite build", "dist:mac": "electron-builder --mac"]
        package.removeValue(forKey: "main")
        try save()
        try require(RepoRecipeService.deriveRecipe(repoRootPath: root.path).ecosystemIdentifier == "rust/tauri",
                    "Electron dependency without a shipping entry displaced Tauri")
        pass("Recipe picks the declared Electron shell, preserves Tauri and rejects weak or ambiguous shipping evidence")
    }

    @MainActor
    private static func inspectReadOnly(arguments: [String]) throws {
        guard arguments.count == 3,
              let stack = BreakAppStack(rawValue: arguments[0]),
              let epoch = Double(arguments[2]), epoch.isFinite else {
            throw AppDeliveryCheckError.failed(
                "usage: --inspect-read-only <stack> <clonePath> <build-start-epoch>"
            )
        }
        let artifact = AppRelaunchService.newestLaunchableAppBundle(
            forStack: stack,
            clonePath: arguments[1],
            producedAtOrAfter: Date(timeIntervalSince1970: epoch)
        )
        let bundleIdentifier = artifact.flatMap(AppRelaunchService.artifactBundleIdentifier(atPath:))
        print(
            "INSPECT stack=\(stack.rawValue) artifact=\(artifact ?? "<none>") "
                + "bundleID=\(bundleIdentifier ?? "<none>")"
        )
    }

    @MainActor
    private static func checkStackAndPackagingCommands(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) throws {
        let releaseRoot = fixtureRoot.appendingPathComponent("electron-release")
        try writePackageJSON(
            at: releaseRoot,
            scripts: ["dist:mac": "electron-builder --mac"],
            dependencies: ["electron": "1"]
        )
        try Data("module.exports = {};\n".utf8)
            .write(to: releaseRoot.appendingPathComponent("electron-builder.cjs"))
        try require(
            AppRelaunchService.stackOfClone(atPath: releaseRoot.path) == .electron,
            "Electron builder evidence did not select Electron"
        )
        try require(
            AppRelaunchService.packageCommandForTesting(
                forStack: .electron, clonePath: releaseRoot.path
            ) == "npm run dist:mac",
            "Electron release command was not selected"
        )

        let distRoot = fixtureRoot.appendingPathComponent("electron-dist")
        try writePackageJSON(
            at: distRoot,
            scripts: ["dist": "electron-builder --dir"],
            dependencies: ["electron-builder": "1"]
        )
        try require(
            AppRelaunchService.stackDerived(
                from: .init(
                    packageJSONContents: try String(
                        contentsOf: distRoot.appendingPathComponent("package.json"), encoding: .utf8
                    )
                )
            ) == .electron,
            "Electron dependency evidence did not select Electron"
        )
        try require(
            AppRelaunchService.packageCommandForTesting(
                forStack: .electron, clonePath: distRoot.path
            ) == "npm run dist",
            "Electron dist command was not selected"
        )

        let forgeRoot = fixtureRoot.appendingPathComponent("electron-forge")
        try writePackageJSON(
            at: forgeRoot,
            scripts: ["make": "electron-forge make"],
            dependencies: ["electron": "1", "@electron-forge/cli": "1"]
        )
        try require(
            AppRelaunchService.packageCommandForTesting(
                forStack: .electron, clonePath: forgeRoot.path
            ) == "npm run make",
            "Electron Forge command was not selected"
        )

        try require(
            AppRelaunchService.stackCanProduceARelaunchableMacArtifact(.electron),
            "Electron was marked non-relaunchable"
        )
        try require(
            AppRelaunchService.stackCanProduceARelaunchableMacArtifact(.tauri),
            "Tauri was marked non-relaunchable"
        )
        try require(
            !AppRelaunchService.stackCanProduceARelaunchableMacArtifact(.nextjs),
            "Next.js was incorrectly marked as a launchable Mac artifact"
        )
        pass("Electron release, dist, Forge command selection and stack eligibility")

        let tauriRoot = fixtureRoot.appendingPathComponent("tauri-local-cli")
        try writePackageJSON(
            at: tauriRoot,
            scripts: [:],
            dependencies: ["@tauri-apps/cli": "1"]
        )
        try FileManager.default.createDirectory(at: tauriRoot.appendingPathComponent("node_modules/.bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8)
            .write(to: tauriRoot.appendingPathComponent("node_modules/.bin/tauri"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tauriRoot.appendingPathComponent("node_modules/.bin/tauri").path
        )
        try require(
            AppRelaunchService.packageCommandForTesting(
                forStack: .tauri, clonePath: tauriRoot.path
            ) == "'node_modules/.bin/tauri' build",
            "local Tauri CLI command was not selected"
        )

        let tauriNpxRoot = fixtureRoot.appendingPathComponent("tauri-npx")
        try writePackageJSON(
            at: tauriNpxRoot,
            scripts: [:],
            dependencies: ["@tauri-apps/cli": "1"]
        )
        try require(
            AppRelaunchService.tauriPackagingCommand(clonePath: tauriNpxRoot.path)
                == "npx --no-install tauri build",
            "Tauri npx fallback was not selected"
        )

        let tauriCargoRoot = fixtureRoot.appendingPathComponent("tauri-cargo")
        try writePackageJSON(at: tauriCargoRoot, scripts: [:], dependencies: [:])
        try require(
            AppRelaunchService.tauriPackagingCommand(clonePath: tauriCargoRoot.path)
                == "cargo tauri build",
            "Tauri cargo fallback was not selected"
        )
        pass("Tauri local CLI, npx fallback and cargo fallback")
    }

    @MainActor
    private static func checkElectronArtifactLayouts(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) throws {
        let cases = [
            "release/mac",
            "dist/mac",
            "out/NitroAI-darwin-arm64",
        ]
        for relativeParent in cases {
            let cloneRoot = fixtureRoot.appendingPathComponent(
                "electron-layout-" + relativeParent.replacingOccurrences(of: "/", with: "-")
            )
            let bundle = cloneRoot.appendingPathComponent(relativeParent)
                .appendingPathComponent("NitroAI.app")
            try makeBundle(
                at: bundle,
                bundleIdentifier: "com.fixture.nitroai",
                marker: relativeParent
            )
            let found = AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: cloneRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -60)
            )
            try require(found == bundle.path, "Electron layout was not discovered: \(relativeParent)")
        }
        pass("Electron release, dist and Forge out artifact discovery")
    }

    @MainActor
    private static func checkTauriArtifactLayouts(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) throws {
        let layouts = [
            "target/release/bundle/macos",
            "src-tauri/target/release/bundle/macos",
            "target/universal-apple-darwin/release/bundle/macos",
        ]
        for relativeParent in layouts {
            let cloneRoot = fixtureRoot.appendingPathComponent(
                "tauri-layout-" + relativeParent.replacingOccurrences(of: "/", with: "-")
            )
            let bundle = cloneRoot.appendingPathComponent(relativeParent)
                .appendingPathComponent("Iris Notes.app")
            try makeBundle(
                at: bundle,
                bundleIdentifier: "com.fixture.tauri.notes",
                marker: relativeParent
            )
            let found = AppRelaunchService.newestLaunchableAppBundle(
                forStack: .tauri,
                clonePath: cloneRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -60)
            )
            try require(found == bundle.path, "Tauri layout was not discovered: \(relativeParent)")
        }
        pass("Tauri target, src-tauri target and universal artifact discovery")
    }

    @MainActor
    private static func checkMissingStaleAndMalformedArtifacts(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) throws {
        let missingRoot = fixtureRoot.appendingPathComponent("missing-artifact")
        try FileManager.default.createDirectory(at: missingRoot, withIntermediateDirectories: true)
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: missingRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -1)
            ) == nil,
            "missing artifact was accepted"
        )

        let emptyRoot = fixtureRoot.appendingPathComponent("empty-macos")
        let emptyBundle = emptyRoot.appendingPathComponent("dist/mac/Empty.app")
        try FileManager.default.createDirectory(
            at: emptyBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writeBundleInfo(
            at: emptyBundle,
            bundleIdentifier: "com.fixture.empty",
            executableName: "Empty"
        )
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: emptyRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -60)
            ) == nil,
            "empty Contents/MacOS was accepted"
        )

        let escapeRoot = fixtureRoot.appendingPathComponent("executable-escape")
        let escapeBundle = escapeRoot.appendingPathComponent("dist/mac/Escape.app")
        try FileManager.default.createDirectory(
            at: escapeBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try writeBundleInfo(
            at: escapeBundle,
            bundleIdentifier: "com.fixture.escape",
            executableName: "../outside"
        )
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: escapeRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -60)
            ) == nil,
            "executable path escaped the bundle"
        )

        let symlinkRoot = fixtureRoot.appendingPathComponent("executable-symlink")
        let symlinkBundle = symlinkRoot.appendingPathComponent("dist/mac/Symlink.app")
        try FileManager.default.createDirectory(
            at: symlinkBundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        let outsideExecutable = symlinkRoot.appendingPathComponent("outside-tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: outsideExecutable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: outsideExecutable.path
        )
        let symlinkExecutable = symlinkBundle.appendingPathComponent("Contents/MacOS/Symlink")
        try FileManager.default.createSymbolicLink(
            at: symlinkExecutable, withDestinationURL: outsideExecutable
        )
        try writeBundleInfo(
            at: symlinkBundle,
            bundleIdentifier: "com.fixture.symlink",
            executableName: "Symlink"
        )
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: symlinkRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -60)
            ) == nil,
            "executable symlink escaped the bundle"
        )

        let staleRoot = fixtureRoot.appendingPathComponent("stale-with-dmg")
        let staleBundle = staleRoot.appendingPathComponent("release/mac/Stale.app")
        try makeBundle(
            at: staleBundle,
            bundleIdentifier: "com.fixture.stale",
            marker: "old"
        )
        let oldDate = Date(timeIntervalSinceNow: -120)
        try setBundleFreshness(staleBundle, to: oldDate)
        try Data("not-an-app\n".utf8)
            .write(to: staleRoot.appendingPathComponent("release/Stale.dmg"))
        try require(
            AppRelaunchService.newestLaunchableAppBundle(
                forStack: .electron,
                clonePath: staleRoot.path,
                producedAtOrAfter: Date(timeIntervalSinceNow: -1)
            ) == nil,
            "stale app plus fresh sibling DMG was accepted"
        )

        let refreshedRoot = fixtureRoot.appendingPathComponent("fresh-app-asar")
        let refreshedBundle = refreshedRoot.appendingPathComponent("dist/mac/Refreshed.app")
        try makeBundle(
            at: refreshedBundle,
            bundleIdentifier: "com.fixture.refreshed",
            marker: "old-outer"
        )
        try setBundleFreshness(refreshedBundle, to: oldDate)
        let producedAt = Date(timeIntervalSinceNow: -1)
        let appAsar = refreshedBundle.appendingPathComponent("Contents/Resources/app.asar")
        try Data("fresh-payload\n".utf8).write(to: appAsar)
        let refreshed = AppRelaunchService.newestLaunchableAppBundle(
            forStack: .electron,
            clonePath: refreshedRoot.path,
            producedAtOrAfter: producedAt
        )
        try require(refreshed == refreshedBundle.path, "fresh app.asar did not refresh an old app bundle")
        pass("Missing, empty, stale, sibling-DMG and executable-escape rejection")
        pass("Fresh Electron app.asar payload refresh")
    }

    @MainActor
    private static func checkArchitecturePreference(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) throws {
        let root = fixtureRoot.appendingPathComponent("architecture-preference")
        let nativeBundle = root.appendingPathComponent("release/mac-arm64/Arch.app")
        let x64Bundle = root.appendingPathComponent("release/mac/Arch.app")
        try makeBundle(
            at: nativeBundle,
            bundleIdentifier: "com.fixture.arch",
            marker: "native"
        )
        try makeBundle(
            at: x64Bundle,
            bundleIdentifier: "com.fixture.arch",
            marker: "x64"
        )
        try setBundleFreshness(nativeBundle, to: Date(timeIntervalSinceNow: -10))
        try setBundleFreshness(x64Bundle, to: Date(timeIntervalSinceNow: -1))
        let producedAt = Date(timeIntervalSinceNow: -30)
        let found = AppRelaunchService.newestLaunchableAppBundle(
            forStack: .electron,
            clonePath: root.path,
            producedAtOrAfter: producedAt
        )
#if arch(arm64)
        let expected = nativeBundle.path
#else
        let expected = x64Bundle.path
#endif
        try require(found == expected, "native architecture preference selected the wrong fresh artifact")
        pass("Native architecture preferred over newer foreign architecture")

        let unrelated = root.appendingPathComponent("release/mac-arm64/Unrelated.app")
        try makeBundle(at: unrelated, bundleIdentifier: "com.fixture.unrelated", marker: "newest")
        let matching = AppRelaunchService.newestLaunchableAppBundle(
            forStack: .electron, clonePath: root.path, producedAtOrAfter: producedAt,
            expectedBundleIdentifier: "com.fixture.arch"
        )
        try require(matching == expected, "a newer unrelated app displaced the requested project")
        pass("Expected project identity filters unrelated fresh apps before selection")
    }

    @MainActor
    private static func checkPureRelaunchGuards(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) async throws {
        let clonePath = fixtureRoot.appendingPathComponent("registered-clone").path
        let siblingPath = fixtureRoot.appendingPathComponent("registered-clone-sibling").path
        let installedPath = "/Applications/Fixture.app"
        try require(
            AppRelaunchService.chooseInstalledBundlePath(
                registeredPath: clonePath + "/dist/mac/Fixture.app",
                applicationsPath: installedPath,
                clonePath: clonePath
            ) == installedPath,
            "installed path did not win over clone build output"
        )
        try require(
            AppRelaunchService.chooseInstalledBundlePath(
                registeredPath: clonePath + "/dist/mac/Fixture.app",
                applicationsPath: nil,
                clonePath: clonePath
            ) == nil,
            "clone build output was treated as installed"
        )
        try require(
            AppRelaunchService.chooseInstalledBundlePath(
                registeredPath: siblingPath + "/Fixture.app",
                applicationsPath: nil,
                clonePath: clonePath
            ) == siblingPath + "/Fixture.app",
            "sibling path was incorrectly treated as inside clone"
        )
        try require(
            AppRelaunchService.applicationURLsAreAllowed(
                [URL(fileURLWithPath: siblingPath)], by: { $0.path == siblingPath }
            ),
            "allowed application URL was rejected"
        )
        try require(
            !AppRelaunchService.applicationURLsAreAllowed(
                [nil, URL(fileURLWithPath: siblingPath)], by: { _ in true }
            ),
            "nil application URL was allowed"
        )

        let artifact = fixtureRoot.appendingPathComponent("identity-mismatch/Actual.app")
        try makeBundle(
            at: artifact,
            bundleIdentifier: "com.fixture.actual",
            marker: "actual"
        )
        try require(
            AppRelaunchService.artifactBundleIdentifier(atPath: artifact.path)
                == "com.fixture.actual",
            "artifact bundle identifier was not read from Info.plist"
        )
        try require(
            AppRelaunchService.artifactBundleIdentifier(
                atPath: fixtureRoot.appendingPathComponent("missing.app").path
            ) == nil,
            "missing artifact had a bundle identifier"
        )

        let service = AppRelaunchService()
        let malformedArtifact = fixtureRoot.appendingPathComponent("malformed/Malformed.app")
        try FileManager.default.createDirectory(
            at: malformedArtifact.appendingPathComponent("Contents"), withIntermediateDirectories: true
        )
        let malformedInfo = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.fixture.expected",
                "CFBundleExecutable": "Malformed",
            ], format: .xml, options: 0
        )
        try malformedInfo.write(to: malformedArtifact.appendingPathComponent("Contents/Info.plist"))
        let malformedQuit = await service.terminateRunningInstanceBeforeDelivery(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: malformedArtifact.path,
            allowForceQuit: false
        )
        if case .ineligible(let reason) = malformedQuit {
            try require(reason.contains("launchable"), "malformed artifact refusal was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed("same-ID malformed artifact reached quit")
        }
        let malformedInstall = await service.installFreshBuildOverInstalledApp(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: malformedArtifact.path,
            clonePath: fixtureRoot.appendingPathComponent("clone").path
        )
        if case .deliveryFailed(let reason) = malformedInstall {
            try require(reason.contains("launchable"), "malformed install refusal was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed("same-ID malformed artifact reached install")
        }
        pass("Same-ID malformed bundles are refused before quit or replacement")
        let sameNameWrongApp = fixtureRoot.appendingPathComponent("wrong-installed/Actual.app")
        try makeBundle(at: sameNameWrongApp, bundleIdentifier: "com.fixture.wrong", marker: "must-survive")
        try require(AppRelaunchService.chooseInstalledBundlePath(
            registeredPath: artifact.path, applicationsPath: sameNameWrongApp.path,
            clonePath: fixtureRoot.appendingPathComponent("clone").path,
            expectedBundleIdentifier: "com.fixture.actual"
        ) == artifact.path, "same-name wrong-ID installed app was selected")
        try require(marker(of: sameNameWrongApp) == "must-survive", "candidate inspection mutated the wrong app")
        pass("Same-name installed app with a different identity is excluded")
        let quitOnlyResult = await service.terminateRunningInstanceBeforeDelivery(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: artifact.path,
            allowForceQuit: false
        )
        if case .ineligible(let reason) = quitOnlyResult {
            try require(reason.contains("identity"), "quit-only identity mismatch reason was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed(
                "quit-only delivery guard accepted an artifact with the wrong identity"
            )
        }
        let launchOnlyResult = await service.launchFreshBuildAfterTermination(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: artifact.path
        )
        if case .ineligible(let reason) = launchOnlyResult {
            try require(reason.contains("identity"), "launch-only identity mismatch reason was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed(
                "launch-only delivery guard accepted an artifact with the wrong identity"
            )
        }
        try require(marker(of: sameNameWrongApp) == "must-survive", "split delivery guard mutated the wrong app")
        pass("Quit-only and launch-only delivery guards reject mismatched artifacts without a process lookup")
        let launchResult = await service.terminateRunningInstanceThenLaunchFreshBuild(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: artifact.path,
            allowForceQuit: false
        )
        if case .ineligible(let reason) = launchResult {
            try require(reason.contains("identity"), "identity mismatch reason was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed(
                "mismatched launch artifact was not rejected before app lookup"
            )
        }

        let installResult = await service.installFreshBuildOverInstalledApp(
            macBundleId: "com.fixture.expected",
            freshBuildArtifactPath: artifact.path,
            clonePath: fixtureRoot.appendingPathComponent("clone").path
        )
        if case .deliveryFailed(let reason) = installResult {
            try require(reason.contains("identity"), "identity mismatch delivery reason was not disclosed")
        } else {
            throw AppDeliveryCheckError.failed(
                "mismatched install artifact reached installed-app lookup"
            )
        }

        try require(
            AppRelaunchService.packagingVerdict(
                freshLaunchableAppBundlePath: artifact.path,
                buildSucceeded: false,
                buildOutputTail: "bundle_dmg failed"
            ) == .deliverTheFreshApp(artifactPath: artifact.path),
            "fresh app was not preferred over a later packaging failure"
        )
        try require(
            AppRelaunchService.packagingVerdict(
                freshLaunchableAppBundlePath: nil,
                buildSucceeded: true,
                buildOutputTail: "warning only"
            ) == .noLaunchableApp(
                reason: "the build finished but Iris couldn't find a launchable app it produced"
            ),
            "successful build without an app was accepted"
        )
        pass("Installed-path selection and artifact identity fail-closed guards")
    }

    @MainActor
    private static func checkBundleDeliveryAndUndo(
        fixtureRoot: URL,
        require: (Bool, String) throws -> Void,
        pass: (String) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let root = fixtureRoot.appendingPathComponent("swap-round-trip")
        let installed = root.appendingPathComponent("installed/Demo.app")
        let fresh = root.appendingPathComponent("clone/build/Demo.app")
        let backup = root.appendingPathComponent("undo/Demo.app")
        try makeBundle(
            at: installed,
            bundleIdentifier: "com.fixture.demo",
            marker: "installed-v1"
        )
        try makeBundle(
            at: fresh,
            bundleIdentifier: "com.fixture.demo",
            marker: "fresh-v2"
        )
        let privateStore = DeliveredEditUndoRecoveryStore(
            recordURL: root.appendingPathComponent("state/recovery.json")
        )
        let delivered = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installed.path,
            withBundleAt: fresh.path,
            snapshotTo: backup.path,
            undoRecoveryStore: privateStore
        )
        try require(delivered.isSuccess, "disposable installed bundle swap failed")
        try require(
            marker(of: installed) == "fresh-v2"
                && marker(of: backup) == "installed-v1"
                && marker(of: fresh) == "fresh-v2",
            "delivery did not preserve fresh source and old undo snapshot"
        )

        let undone = AppRelaunchService.atomicallyReplaceBundle(
            installedPath: installed.path,
            withBundleAt: backup.path,
            snapshotTo: nil,
            undoRecoveryStore: privateStore
        )
        try require(undone.isSuccess, "disposable installed bundle undo failed")
        try require(marker(of: installed) == "installed-v1", "undo did not restore the old bundle")
        pass("Disposable installed replacement, backup and undo round trip")

        let backupOne = AppRelaunchService.deliveryBackupPath(
            forBundleId: "com.fixture.demo", appBundleName: "Demo.app"
        )
        let backupTwo = AppRelaunchService.deliveryBackupPath(
            forBundleId: "com.fixture.demo", appBundleName: "Demo.app"
        )
        try require(backupOne != backupTwo, "successive deliveries reused the same backup path")
        try require(
            backupOne.contains("edit-delivery-backups/com.fixture.demo/")
                && backupOne.hasSuffix("/Demo.app"),
            "backup path lost its keyed delivery structure"
        )
        try require(
            !fileManager.fileExists(atPath: backupOne)
                && !fileManager.fileExists(atPath: backupTwo),
            "backup path helper mutated the real filesystem"
        )
        pass("Per-delivery backup identity and no-write path helper")

        let receipts = AppDeliveryReceiptStore(baseDirectory: root.appendingPathComponent("receipts"))
        let recordedBackup = root.appendingPathComponent("recorded-undo/Demo.app")
        let recorded = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: "com.fixture.demo", installedPath: installed.path,
            artifactPath: fresh.path, backupPath: recordedBackup.path,
            grantsMayReset: false, store: receipts, undoRecoveryStore: privateStore)
        guard case .replacedInstalledApp(_, _, _, let warning) = recorded else {
            throw AppDeliveryCheckError.failed("receipt-backed delivery failed")
        }
        try require(warning == nil, "receipt-backed delivery had an unexpected history warning")
        let restartedStore = AppDeliveryReceiptStore(baseDirectory: receipts.baseDirectory)
        guard case .valid(let persisted)? = restartedStore.entries().first else {
            throw AppDeliveryCheckError.failed("delivery did not leave a readable receipt")
        }
        try require(persisted.phase == .installed && persisted.backupPath == recordedBackup.path,
                    "delivery history did not record the actual backup and installed phase")
        try require(marker(of: installed) == "fresh-v2" && marker(of: recordedBackup) == "installed-v1",
                    "receipt-backed swap lost the old or new app")
        pass("Receipt-backed delivery records the real swap and survives a store restart")

        let blockedPath = root.appendingPathComponent("receipt-storage-is-a-file")
        try Data("preserve".utf8).write(to: blockedPath)
        let blockedBackup = root.appendingPathComponent("must-not-exist/Demo.app")
        let refused = AppRelaunchService.replaceBundleWithRecoveryReceipt(
            bundleIdentifier: "com.fixture.demo", installedPath: installed.path,
            artifactPath: recordedBackup.path, backupPath: blockedBackup.path,
            grantsMayReset: false, store: AppDeliveryReceiptStore(baseDirectory: blockedPath),
            undoRecoveryStore: privateStore)
        guard case .deliveryFailed = refused else {
            throw AppDeliveryCheckError.failed("delivery proceeded without durable recovery metadata")
        }
        try require(marker(of: installed) == "fresh-v2" && !fileManager.fileExists(atPath: blockedBackup.path),
                    "receipt write failure changed installed app or created a backup")
        pass("Failed recovery metadata persistence prevents the app swap")
    }

    @MainActor
    private static func writePackageJSON(
        at root: URL,
        scripts: [String: String],
        dependencies: [String: String]
    ) throws {
        let package: [String: Any] = [
            "name": "fixture",
            "private": true,
            "scripts": scripts,
            "dependencies": dependencies,
        ]
        let data = try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("package.json"))
    }

    @MainActor
    private static func makeBundle(
        at bundle: URL,
        bundleIdentifier: String,
        marker: String,
        executableName: String = "Demo"
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true
        )
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path
        )
        try writeBundleInfo(
            at: bundle,
            bundleIdentifier: bundleIdentifier,
            executableName: executableName
        )
        try Data(marker.utf8)
            .write(to: bundle.appendingPathComponent("Contents/Resources/marker.txt"))
    }

    @MainActor
    private static func writeBundleInfo(
        at bundle: URL,
        bundleIdentifier: String,
        executableName: String
    ) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleExecutable": executableName,
                "CFBundleIdentifier": bundleIdentifier,
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    @MainActor
    private static func setBundleFreshness(_ bundle: URL, to date: Date) throws {
        let fileManager = FileManager.default
        let info = bundle.appendingPathComponent("Contents/Info.plist")
        let executableName = (try PropertyListSerialization.propertyList(
            from: Data(contentsOf: info), format: nil
        ) as? [String: Any])?["CFBundleExecutable"] as? String ?? "Demo"
        let executable = bundle.appendingPathComponent("Contents/MacOS/\(executableName)")
        for path in [bundle.path, info.path, executable.path] {
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    @MainActor
    private static func marker(of bundle: URL) -> String? {
        try? String(
            contentsOf: bundle.appendingPathComponent("Contents/Resources/marker.txt"),
            encoding: .utf8
        )
    }
}
