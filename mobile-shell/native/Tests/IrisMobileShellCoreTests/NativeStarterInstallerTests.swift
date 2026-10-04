import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Persona-shaped behavior tests for `NativeStarterInstaller`, run against a
/// real `NativeShellLibraryCoordinator` writing to a real temporary
/// filesystem. Every package fixture comes from the independent Node
/// generator at `Tests/Fixtures/generate-desktop-package.mjs` (the same
/// oracle `NativeRevisionStoreTests` and `NativeShellLibraryCoordinatorTests`
/// use), never from `NativeStarterInstaller` or `NativeShellLibraryCoordinator`
/// themselves. Oracles are observable outcomes: what ends up on disk, what
/// `libraryEntry`/`refreshLibrary` report, and reader-owned bytes written
/// outside the package - never a call count and never a value the test just
/// set.
///
/// Personas (see PLAN.md section 4 in this unit's impl folder):
/// P2 hurried power user (double-taps, backgrounds mid-install); P3 edge
/// user (force-quits mid-update).
final class NativeStarterInstallerTests: XCTestCase {
    func testP2DoubleTapConcurrentFirstLaunchInstallsEachStarterAppExactlyOnce() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let kneecapBase = try fixture.generatePackage(
            content: html("kneecap-base"), nonce: nonce("a"),
            appId: "starter.kneecap", projectId: "starter.kneecap.mobile", namespace: "starter.kneecap.v1"
        )
        let kneecapUpdate = try fixture.generatePackage(
            content: html("kneecap-fixed"), baseRevisionId: kneecapBase.revisionId, nonce: nonce("b"),
            appId: "starter.kneecap", projectId: "starter.kneecap.mobile", namespace: "starter.kneecap.v1"
        )
        let chains = ["kneecap": NativeStarterInstaller.AppChain(
            displayName: "Kneecap", orderedPackages: [kneecapBase.bytes, kneecapUpdate.bytes]
        )]
        let installer = NativeStarterInstaller()

        // P2 double-taps "Install & Open" on first launch: two install passes
        // race against the same coordinator, exactly as two overlapping
        // launch/foreground events could.
        async let first = installer.installMissing(chains, into: coordinator)
        async let second = installer.installMissing(chains, into: coordinator)
        _ = await (first, second)

        let identity = NativeShellAppIdentity(appId: "starter.kneecap", projectId: "starter.kneecap.mobile")
        let entry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(entry?.currentRevisionId, kneecapUpdate.revisionId)
        // Exactly one public summary for each expected package and one stored manifest per id.
        XCTAssertEqual(entry?.revisions.map(\.revisionId).sorted(), [kneecapBase.revisionId, kneecapUpdate.revisionId].sorted())
        let stored = try manifestOccurrences(containingAnyOf: [kneecapBase.revisionId, kneecapUpdate.revisionId], under: fixture.storeRoot)
        XCTAssertEqual(stored[kneecapBase.revisionId], 1, "SPEC 2.1: base revision has one manifest after concurrent first launch")
        XCTAssertEqual(stored[kneecapUpdate.revisionId], 1, "SPEC 2.1: update revision has one manifest after concurrent first launch")
    }

    func testP3ForceQuitMidStarterInstallThenNextLaunchCompletesToTheSameState() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let base = try fixture.generatePackage(
            content: html("nutai-base"), nonce: nonce("c"),
            appId: "starter.nutai", projectId: "starter.nutai.mobile", namespace: "starter.nutai.v1"
        )
        let update = try fixture.generatePackage(
            content: html("nutai-update"), baseRevisionId: base.revisionId, nonce: nonce("d"),
            appId: "starter.nutai", projectId: "starter.nutai.mobile", namespace: "starter.nutai.v1"
        )
        let identity = NativeShellAppIdentity(appId: "starter.nutai", projectId: "starter.nutai.mobile")

        // Simulate a force-quit that happened between "stage" and "activate"
        // on a previous launch attempt: the base package's bytes are staged
        // on disk (a real `stage()` call, the same effect a killed launch
        // would leave behind), but the active pointer was never written.
        let review = try await coordinator.reviewImport(packageBytes: base.bytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
        )
        let crashedEntry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertNil(crashedEntry?.currentRevisionId, "precondition: activate never ran before the simulated crash")

        // "Next launch": run the installer against the crashed store.
        let chains = ["nutai": NativeStarterInstaller.AppChain(
            displayName: "Nut AI", orderedPackages: [base.bytes, update.bytes]
        )]
        let allResults = await NativeStarterInstaller().installMissing(chains, into: coordinator)
        let results = try XCTUnwrap(allResults["nutai"])
        guard case .installed(let steps, let finalRevisionId) = results else {
            return XCTFail("expected .installed, got \(results)")
        }
        XCTAssertEqual(finalRevisionId, update.revisionId)
        // The already-staged base package must be recognized as such, not
        // silently re-downloaded/re-written as if it were new.
        XCTAssertEqual(steps.first, .alreadyStaged(revisionId: base.revisionId))
        XCTAssertEqual(steps.last, .installed(revisionId: update.revisionId))

        // Independent oracle: a second, never-crashed store that installs
        // the same chain in one clean pass must end up in the identical
        // state (same active revision, same set of stored revisions) as the
        // recovered one. Force-quit-then-retry must converge, not diverge.
        let cleanFixture = try StarterFixture()
        defer { cleanFixture.cleanup() }
        let cleanCoordinator = NativeShellLibraryCoordinator(rootURL: cleanFixture.storeRoot)
        _ = await NativeStarterInstaller().installMissing(chains, into: cleanCoordinator)
        let recoveredEntry = try await coordinator.libraryEntry(identity: identity)
        let cleanEntry = try await cleanCoordinator.libraryEntry(identity: identity)
        XCTAssertEqual(recoveredEntry?.currentRevisionId, cleanEntry?.currentRevisionId)
        XCTAssertEqual(
            recoveredEntry?.revisions.map(\.revisionId).sorted(),
            cleanEntry?.revisions.map(\.revisionId).sorted()
        )
    }

    func testTamperedStarterPackageIsRefusedAndOtherAppsStillInstall() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let goodBase = try fixture.generatePackage(
            content: html("freeharmony-base"), nonce: nonce("e"),
            appId: "starter.freeharmony", projectId: "starter.freeharmony.mobile", namespace: "starter.freeharmony.v1"
        )
        let tamperedTarget = try fixture.generatePackage(
            content: html("kneecap-tampered"), nonce: nonce("f"),
            appId: "starter.kneecap2", projectId: "starter.kneecap2.mobile", namespace: "starter.kneecap2.v1"
        )
        // Flip one content byte after the fact, exactly as a corrupted
        // download or a tampered bundle resource would arrive: the file's
        // declared sha256 in the manifest no longer matches its bytes.
        let tampered = try mutatePackage(tamperedTarget.bytes) { root in
            var files = root["files"] as! [[String: Any]]
            var bytes = Data(base64Encoded: files[0]["contentBase64"] as! String)!
            bytes[bytes.startIndex] ^= 0xff
            files[0]["contentBase64"] = bytes.base64EncodedString()
            root["files"] = files
        }

        let chains = [
            "freeharmony": NativeStarterInstaller.AppChain(displayName: "FreeHarmony", orderedPackages: [goodBase.bytes]),
            "kneecap2": NativeStarterInstaller.AppChain(displayName: "Kneecap", orderedPackages: [tampered]),
        ]
        let results = await NativeStarterInstaller().installMissing(chains, into: coordinator)

        guard case .failed = results["kneecap2"] else {
            return XCTFail("expected the tampered chain to fail, got \(String(describing: results["kneecap2"]))")
        }
        guard case .installed(_, let finalRevisionId) = results["freeharmony"] else {
            return XCTFail("expected the untampered chain to install, got \(String(describing: results["freeharmony"]))")
        }
        XCTAssertEqual(finalRevisionId, goodBase.revisionId)

        // Zero side effects from the refused chain: no revision, staged or
        // active, exists for it anywhere in the real store.
        let tamperedIdentity = NativeShellAppIdentity(appId: "starter.kneecap2", projectId: "starter.kneecap2.mobile")
        let tamperedEntry = try await coordinator.libraryEntry(identity: tamperedIdentity)
        XCTAssertNil(tamperedEntry)
        let contentRoot = fixture.storeRoot.appendingPathComponent("content/starter.kneecap2", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: contentRoot.path))
    }

    func testStarterInstallThenCatalogUpdateThenRevertPreservesReaderData() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let identity = NativeShellAppIdentity(appId: "starter.lifecycle", projectId: "starter.lifecycle.mobile")

        let base = try fixture.generatePackage(
            content: html("lifecycle-base"), nonce: nonce("g"),
            appId: identity.appId, projectId: identity.projectId, namespace: "starter.lifecycle.v1"
        )
        let starterFix = try fixture.generatePackage(
            content: html("lifecycle-fix"), baseRevisionId: base.revisionId, nonce: nonce("h"),
            appId: identity.appId, projectId: identity.projectId, namespace: "starter.lifecycle.v1"
        )
        let chains = ["lifecycle": NativeStarterInstaller.AppChain(
            displayName: "Lifecycle", orderedPackages: [base.bytes, starterFix.bytes]
        )]
        let results = await NativeStarterInstaller().installMissing(chains, into: coordinator)
        guard case .installed(_, let starterFinal) = results["lifecycle"] else {
            return XCTFail("expected starter install to succeed, got \(String(describing: results["lifecycle"]))")
        }
        XCTAssertEqual(starterFinal, starterFix.revisionId)

        // Real user content, written the same way the WKWebView host would
        // write it: outside any package, into the reader-owned data
        // directory for this app's data namespace.
        let dataDirectory = try await coordinator.readerDataDirectory(identity: identity, namespace: "starter.lifecycle.v1")
        let marker = dataDirectory.appendingPathComponent("user-note.txt")
        try Data("written-by-the-reader".utf8).write(to: marker)

        // A real catalog update arrives later (not starter content: staged
        // and activated directly through the coordinator, the exact path a
        // downloaded package uses).
        let catalogUpdate = try fixture.generatePackage(
            content: html("lifecycle-catalog-update"), baseRevisionId: starterFix.revisionId, nonce: nonce("i"),
            appId: identity.appId, projectId: identity.projectId, namespace: "starter.lifecycle.v1"
        )
        let updateReview = try await coordinator.reviewImport(packageBytes: catalogUpdate.bytes, expectedIdentity: identity)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: updateReview.reviewToken, packageSHA256: updateReview.packageSHA256
        )
        try await coordinator.activate(identity: identity, revisionId: catalogUpdate.revisionId)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "written-by-the-reader")

        try await coordinator.revert(identity: identity, to: starterFix.revisionId)
        let afterRevert = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(afterRevert?.currentRevisionId, starterFix.revisionId)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "written-by-the-reader")
    }

    func testAppAlreadyInstalledFromAnEarlierLaunchIsNeverTouchedByStarterInstall() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let identity = NativeShellAppIdentity(appId: "starter.existing", projectId: "starter.existing.mobile")

        // The user already has this app (from a previous starter install,
        // or a real catalog install) at a revision the bundled starter
        // chain below does not even know about.
        let existing = try fixture.generatePackage(
            content: html("already-here"), nonce: nonce("j"),
            appId: identity.appId, projectId: identity.projectId, namespace: "starter.existing.v1"
        )
        let review = try await coordinator.reviewImport(packageBytes: existing.bytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
        )
        try await coordinator.activate(identity: identity, revisionId: existing.revisionId)

        let unrelatedBase = try fixture.generatePackage(
            content: html("starter-attempt"), nonce: nonce("k"),
            appId: identity.appId, projectId: identity.projectId, namespace: "starter.existing.v1"
        )
        let chains = ["existing": NativeStarterInstaller.AppChain(
            displayName: "Existing", orderedPackages: [unrelatedBase.bytes]
        )]
        let results = await NativeStarterInstaller().installMissing(chains, into: coordinator)
        guard case .alreadyPresent(let currentRevisionId) = results["existing"] else {
            return XCTFail("expected .alreadyPresent, got \(String(describing: results["existing"]))")
        }
        XCTAssertEqual(currentRevisionId, existing.revisionId)

        let entry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(entry?.currentRevisionId, existing.revisionId)
        XCTAssertEqual(entry?.revisions.count, 1, "the unrelated starter package must never have been staged")
    }

    // MARK: - stillNeeded: the quick, non-staging pre-check the first-launch
    // "setting up your apps" banner is built on.

    func testStillNeededReportsEveryChainOnAFreshFirstLaunch() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let kneecap = try fixture.generatePackage(
            content: html("kneecap"), nonce: nonce("l"),
            appId: "starter.stillneeded.kneecap", projectId: "starter.stillneeded.kneecap.mobile",
            namespace: "starter.stillneeded.kneecap.v1"
        )
        let nutai = try fixture.generatePackage(
            content: html("nutai"), nonce: nonce("m"),
            appId: "starter.stillneeded.nutai", projectId: "starter.stillneeded.nutai.mobile",
            namespace: "starter.stillneeded.nutai.v1"
        )
        let chains = [
            "kneecap": NativeStarterInstaller.AppChain(displayName: "Kneecap", orderedPackages: [kneecap.bytes]),
            "nutai": NativeStarterInstaller.AppChain(displayName: "Nut AI", orderedPackages: [nutai.bytes]),
        ]

        let needing = await NativeStarterInstaller().stillNeeded(chains, into: coordinator)
        XCTAssertEqual(needing, ["kneecap", "nutai"], "nothing is installed yet, so both still need setup")

        // Read-only: a pre-check must never take the review slot or write
        // any revision to disk.
        let pending = await coordinator.pendingPackageReview()
        XCTAssertNil(pending)
        let kneecapEntry = try await coordinator.libraryEntry(
            identity: NativeShellAppIdentity(appId: "starter.stillneeded.kneecap", projectId: "starter.stillneeded.kneecap.mobile")
        )
        XCTAssertNil(kneecapEntry, "stillNeeded must not stage or install anything by itself")
    }

    func testStillNeededOmitsAChainThatFinishedOnAnEarlierLaunch() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        let doneBase = try fixture.generatePackage(
            content: html("done-base"), nonce: nonce("n"),
            appId: "starter.stillneeded.done", projectId: "starter.stillneeded.done.mobile",
            namespace: "starter.stillneeded.done.v1"
        )
        let stillPendingBase = try fixture.generatePackage(
            content: html("pending-base"), nonce: nonce("o"),
            appId: "starter.stillneeded.pending", projectId: "starter.stillneeded.pending.mobile",
            namespace: "starter.stillneeded.pending.v1"
        )
        let chains = [
            "done": NativeStarterInstaller.AppChain(displayName: "Done", orderedPackages: [doneBase.bytes]),
            "pending": NativeStarterInstaller.AppChain(displayName: "Pending", orderedPackages: [stillPendingBase.bytes]),
        ]
        // "An earlier launch" completed the "done" chain in full.
        let installer = NativeStarterInstaller()
        _ = await installer.installMissing(["done": chains["done"]!], into: coordinator)

        let needing = await installer.stillNeeded(chains, into: coordinator)
        XCTAssertEqual(needing, ["pending"], "the already-finished app must not be named as still running")
    }

    func testStillNeededTreatsAMalformedChainAsStillNeededSoInstallMissingCanSurfaceTheRealFailure() async throws {
        let fixture = try StarterFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)

        // A base package whose declared base revision is not nil is not a
        // valid first package in a chain (see `planChain`); `stillNeeded`
        // has no way to know it will fail, so it must still report it as
        // needing setup rather than quietly hiding it from the banner.
        let base = try fixture.generatePackage(
            content: html("malformed-base"), nonce: nonce("p"),
            appId: "starter.stillneeded.malformed", projectId: "starter.stillneeded.malformed.mobile",
            namespace: "starter.stillneeded.malformed.v1"
        )
        let update = try fixture.generatePackage(
            content: html("malformed-update"), baseRevisionId: base.revisionId, nonce: nonce("q"),
            appId: "starter.stillneeded.malformed", projectId: "starter.stillneeded.malformed.mobile",
            namespace: "starter.stillneeded.malformed.v1"
        )
        // Out of order: update before base breaks contiguity.
        let chains = ["malformed": NativeStarterInstaller.AppChain(displayName: "Malformed", orderedPackages: [update.bytes, base.bytes])]

        let needing = await NativeStarterInstaller().stillNeeded(chains, into: coordinator)
        XCTAssertEqual(needing, ["malformed"])
    }

    func testCatalogEntriesAreWellFormed() {
        let labels = NativeStarterCatalog.entries.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count, "every starter app label must be unique")
        for entry in NativeStarterCatalog.entries {
            XCTAssertFalse(entry.orderedFileNames.isEmpty, "\(entry.label) has no bundled files")
            XCTAssertEqual(entry.orderedFileNames.first, "01-base.irisapp", "\(entry.label) must start at its base revision")
            XCTAssertEqual(
                NativeStarterCatalog.subdirectory(for: entry), "Starter/\(entry.label)"
            )
        }
    }
}

// MARK: - Fixture (independent oracle: real desktop-CLI-produced package bytes)

private struct GeneratedStarterPackage {
    let bytes: Data
    let revisionId: String
}

private final class StarterFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-starter-installer-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func generatePackage(
        content: String,
        baseRevisionId: String? = nil,
        nonce: String,
        appId: String,
        projectId: String,
        namespace: String,
        capabilities: [String] = []
    ) throws -> GeneratedStarterPackage {
        packageIndex += 1
        let output = root.appendingPathComponent("package-\(packageIndex)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let script = repositoryRoot()
            .appendingPathComponent("mobile-shell/native/Tests/Fixtures/generate-desktop-package.mjs")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "node", script.path,
            "--output", output.path,
            "--base", baseRevisionId ?? "null",
            "--content", content,
            "--nonce", nonce,
            "--namespace", namespace,
            "--capabilities", try jsonString(capabilities),
            "--app", appId,
            "--project", projectId,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw StarterFixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "unknown generator error")
        }
        let result = try jsonObject(outputData)
        let packagePath = try requiredString(result, "packagePath")
        let revisionId = try requiredString(result, "revisionId")
        return GeneratedStarterPackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            revisionId: revisionId
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum StarterFixtureError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
}

private func mutatePackage(_ bytes: Data, mutation: (inout [String: Any]) throws -> Void) throws -> Data {
    var root = try jsonObject(bytes)
    try mutation(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw StarterFixtureError.malformedFixture("expected JSON object")
    }
    return object
}

private func jsonString(_ value: Any) throws -> String {
    String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else { throw StarterFixtureError.malformedFixture("missing \(key)") }
    return value
}

private func manifestOccurrences(containingAnyOf revisionIds: [String], under root: URL) throws -> [String: Int] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
    let wanted = Set(revisionIds)
    var counts: [String: Int] = [:]
    for case let url as URL in enumerator where url.pathExtension == "json" && url.pathComponents.contains("manifests") {
        guard let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)),
              let revisionId = manifestRevisionId(value) else { continue }
        if wanted.contains(revisionId) { counts[revisionId, default: 0] += 1 }
    }
    return counts
}

private func manifestRevisionId(_ value: Any) -> String? {
    if let object = value as? [String: Any] {
        if let revisionId = object["revisionId"] as? String { return revisionId }
        for nested in object.values {
            if let revisionId = manifestRevisionId(nested) { return revisionId }
        }
    } else if let array = value as? [Any] {
        for nested in array {
            if let revisionId = manifestRevisionId(nested) { return revisionId }
        }
    }
    return nil
}

private func jsonStrings(_ value: Any) -> Set<String> {
    if let string = value as? String { return [string] }
    if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(jsonStrings($1)) } }
    if let object = value as? [String: Any] { return object.values.reduce(into: Set<String>()) { $0.formUnion(jsonStrings($1)) } }
    return []
}

private func html(_ marker: String) -> String {
    "<!doctype html><meta charset=utf-8><title>Starter install</title><main>\(marker)</main>"
}

private func nonce(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
