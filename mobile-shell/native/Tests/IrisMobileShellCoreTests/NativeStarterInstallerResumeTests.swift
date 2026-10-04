import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Independent adversarial regression test for `NativeStarterInstaller`,
/// added during m4-release verification. New file: no existing test file is
/// edited.
///
/// The real bundled starter chains this unit ships are 3 packages
/// (Kneecap) and 4 packages (Nut AI, FreeHarmony) long, not 2. This test
/// reproduces the exact real-world interruption `PHASE0_DEVICE_GUIDE.md`
/// and the P3 persona describe - the app is force-quit mid-install - but
/// AFTER at least one intermediate package in a 3+ package chain has
/// already been activated, not only after the very first one. That is the
/// shape the existing `testP3ForceQuitMidStarterInstallThenNextLaunchCompletesToTheSameState`
/// test (2-package chain, crash before the first package's own activate)
/// does not cover, and where `installChainIfMissing`'s original
/// "already present -> leave alone" check (keyed only off whether ANY
/// revision is active, checked once at chain index 0) mistook a
/// partially-finished chain for a fully foreign install and silently
/// dropped the remainder of the chain forever, on every later launch.
///
/// Oracle: real `NativeShellLibraryCoordinator` against a real temporary
/// filesystem, real package bytes from the same independent Node generator
/// (`Tests/Fixtures/generate-desktop-package.mjs`) every other suite in
/// this target uses. The assertion is the observable end state
/// (`libraryEntry.currentRevisionId`), not a call count and not a value
/// this test set itself.
final class NativeStarterInstallerResumeTests: XCTestCase {
    func testThreePackageChainResumesPastAnAlreadyActivatedMiddlePackage() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let suite = "iris-starter-resume-keep-count-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = NativeShellAppIdentity(appId: "resume.threepkg", projectId: "resume.threepkg.mobile")
        let catalog = NativeStarterResumeKeepCountCatalogFixture()
        let offers: @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { identity in
            await catalog.offers(for: identity)
        }
        var coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: offers)

        let base = try fixture.generatePackage(
            content: html("resume-base"), nonce: nonce("m"),
            appId: identity.appId, projectId: identity.projectId, namespace: "resume.threepkg.v1"
        )
        let update = try fixture.generatePackage(
            content: html("resume-update"), baseRevisionId: base.revisionId, nonce: nonce("n"),
            appId: identity.appId, projectId: identity.projectId, namespace: "resume.threepkg.v1"
        )
        let final = try fixture.generatePackage(
            content: html("resume-final"), baseRevisionId: update.revisionId, nonce: nonce("o"),
            appId: identity.appId, projectId: identity.projectId, namespace: "resume.threepkg.v1"
        )
        for package in [base, update, final] {
            await catalog.offer(package.revisionId, appId: identity.appId, projectId: identity.projectId)
        }
        XCTAssertEqual(Set([base.revisionId, update.revisionId, final.revisionId]).count, 3,
                       "the independently generated A, B, and C packages have distinct revision hashes")

        // SPEC 5.1 check 6 and addendum 7.7: with K=2, install A then B.
        // The independent expected order is A < B < C, from the generated
        // package chain, not a product retention report.
        // MUTATION: a store that ignores K fails the post-completion A absence assertion.
        for package in [base, update] {
            let review = try await coordinator.reviewImport(packageBytes: package.bytes, expectedIdentity: package === base ? nil : identity)
            _ = try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken, packageSHA256: review.packageSHA256
            )
            try await coordinator.activate(identity: identity, revisionId: package.revisionId)
        }
        coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: offers)
        var entry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(entry?.currentRevisionId, update.revisionId)
        XCTAssertEqual(entry?.fallbackRevisionId, base.revisionId)

        // Stage C but do not activate it, as when a person closes Iris after
        // download. Pending C is retained while the K=2 current/fallback A/B
        // pair is also intact.
        let pendingReview = try await coordinator.reviewImport(packageBytes: final.bytes, expectedIdentity: identity)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: pendingReview.reviewToken, packageSHA256: pendingReview.packageSHA256
        )
        _ = try await coordinator.pruneStorage(identity: identity)
        let pendingStore = try NativeRevisionStore(
            rootURL: fixture.storeRoot, appId: identity.appId, projectId: identity.projectId,
            shellVersion: "1.0.0", defaults: defaults, downloadableRevisionIds: offers
        )
        for package in [base, update, final] {
            let isAvailable = try await pendingStore.revisionIsOnThisPhone(revisionId: package.revisionId)
            XCTAssertTrue(isAvailable,
                          "A, B, and pending C remain usable before resume")
            try fixture.assertStoredHTML(package.expectedHTML, present: true)
        }

        // A fresh coordinator represents the next process. The public
        // installOne recipe resumes the full chain from its already staged C.
        coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot, defaults: defaults, downloadableRevisionIds: offers)
        let chain = NativeStarterInstaller.AppChain(
            displayName: "Fixture", orderedPackages: [base.bytes, update.bytes, final.bytes]
        )
        let result = await NativeStarterInstaller().installOne(chain, label: "Fixture", into: coordinator)

        guard case .installed(_, let finalRevisionId) = result else {
            return XCTFail("expected the resumed chain to finish at C, got \(result)")
        }
        XCTAssertEqual(finalRevisionId, final.revisionId)

        entry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(entry?.currentRevisionId, final.revisionId)
        XCTAssertEqual(entry?.fallbackRevisionId, update.revisionId)
        // Independently verify the generated current and fallback launch trees.
        let launchC = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launchC.launchedRevisionId, final.revisionId)
        try fixture.assertLaunchContent(launchC.launch.readAccessRootURL, equals: html("resume-final"))
        try await coordinator.revert(identity: identity, to: update.revisionId)
        let launchB = try await coordinator.launchActive(identity: identity)
        XCTAssertEqual(launchB.launchedRevisionId, update.revisionId)
        try fixture.assertLaunchContent(launchB.launch.readAccessRootURL, equals: html("resume-update"))
        try await coordinator.revert(identity: identity, to: final.revisionId)

        // PRE-2026-10-01-DECISION: revisit with the keep-count setting
        // RESOLVED 2026-10-01: K=2 keeps current/fallback and pending C until resume; ordinary prune can then free offered A.
        _ = try await coordinator.pruneStorage(identity: identity)
        let completedStore = try NativeRevisionStore(
            rootURL: fixture.storeRoot, appId: identity.appId, projectId: identity.projectId,
            shellVersion: "1.0.0", defaults: defaults, downloadableRevisionIds: offers
        )
        let baseStillAvailable = try await completedStore.revisionIsOnThisPhone(revisionId: base.revisionId)
        let updateStillAvailable = try await completedStore.revisionIsOnThisPhone(revisionId: update.revisionId)
        let finalStillAvailable = try await completedStore.revisionIsOnThisPhone(revisionId: final.revisionId)
        XCTAssertFalse(baseStillAvailable,
                       "ordinary K=2 pruning frees eligible A after the chain completes")
        try fixture.assertStoredHTML(base.expectedHTML, present: false)
        try fixture.assertStoredHTML(update.expectedHTML, present: true)
        try fixture.assertStoredHTML(final.expectedHTML, present: true)
        XCTAssertTrue(updateStillAvailable && finalStillAvailable,
                      "ordinary K=2 pruning retains fallback B and current C")
        entry = try await coordinator.libraryEntry(identity: identity)
        XCTAssertEqual(entry?.currentRevisionId, final.revisionId)
        XCTAssertEqual(entry?.fallbackRevisionId, update.revisionId)
    }

    func testFourPackageChainResumesAfterCrashPastTheSecondPackage() async throws {
        let fixture = try ResumeFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let identity = NativeShellAppIdentity(appId: "resume.fourpkg", projectId: "resume.fourpkg.mobile")

        let p1 = try fixture.generatePackage(content: html("p1"), nonce: nonce("p"), appId: identity.appId, projectId: identity.projectId, namespace: "resume.fourpkg.v1")
        let p2 = try fixture.generatePackage(content: html("p2"), baseRevisionId: p1.revisionId, nonce: nonce("q"), appId: identity.appId, projectId: identity.projectId, namespace: "resume.fourpkg.v1")
        let p3 = try fixture.generatePackage(content: html("p3"), baseRevisionId: p2.revisionId, nonce: nonce("r"), appId: identity.appId, projectId: identity.projectId, namespace: "resume.fourpkg.v1")
        let p4 = try fixture.generatePackage(content: html("p4"), baseRevisionId: p3.revisionId, nonce: nonce("s"), appId: identity.appId, projectId: identity.projectId, namespace: "resume.fourpkg.v1")

        for package in [p1, p2] {
            let review = try await coordinator.reviewImport(packageBytes: package.bytes, expectedIdentity: package === p1 ? nil : identity)
            _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
            try await coordinator.activate(identity: identity, revisionId: package.revisionId)
        }

        let chain = NativeStarterInstaller.AppChain(displayName: "Resume4", orderedPackages: [p1.bytes, p2.bytes, p3.bytes, p4.bytes])
        let allResults = await NativeStarterInstaller().installMissing(["resume4": chain], into: coordinator)
        let result = try XCTUnwrap(allResults["resume4"])
        guard case .installed(let steps, let finalRevisionId) = result else {
            return XCTFail("expected the 4-package chain to resume at package 3 and finish at package 4, got \(result)")
        }
        XCTAssertEqual(finalRevisionId, p4.revisionId)
        XCTAssertEqual(steps.map { $0 }, [.installed(revisionId: p3.revisionId), .installed(revisionId: p4.revisionId)])
    }
}

// MARK: - Fixture (independent oracle: real desktop-CLI-produced package bytes)

private final class GeneratedResumePackage {
    let bytes: Data
    let revisionId: String
    let expectedHTML: String
    init(bytes: Data, revisionId: String, expectedHTML: String) {
        self.bytes = bytes
        self.revisionId = revisionId
        self.expectedHTML = expectedHTML
    }
}

private final class ResumeFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-starter-installer-resume-tests-\(UUID().uuidString)", isDirectory: true)
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
        namespace: String
    ) throws -> GeneratedResumePackage {
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
            "--capabilities", "[]",
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
            throw ResumeFixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "unknown generator error")
        }
        guard let result = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let packagePath = result["packagePath"] as? String,
              let revisionId = result["revisionId"] as? String else {
            throw ResumeFixtureError.malformedFixture("missing packagePath/revisionId")
        }
        return GeneratedResumePackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            revisionId: revisionId,
            expectedHTML: content
        )
    }

    func assertStoredHTML(_ expected: String, present: Bool,
                          file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = Data(expected.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let object = storeRoot.appendingPathComponent("objects/\(hash.prefix(2))/\(hash)")
        let exists = FileManager.default.fileExists(atPath: object.path)
        XCTAssertEqual(exists, present, "independent expected object presence", file: file, line: line)
        if present, exists {
            XCTAssertEqual(try Data(contentsOf: object), bytes,
                           "independent expected object bytes", file: file, line: line)
        }
    }

    func assertLaunchContent(_ root: URL, equals expected: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let entrypoint = root.appendingPathComponent("index.html")
        let actual = try String(contentsOf: entrypoint, encoding: .utf8)
        XCTAssertEqual(actual, expected, "independent generated launch content", file: file, line: line)
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

private enum ResumeFixtureError: Error {
    case generatorFailed(String)
    case malformedFixture(String)
}

private actor NativeStarterResumeKeepCountCatalogFixture {
    private var offeredRevisionIdsByIdentity: [String: Set<String>] = [:]

    func offer(_ revisionId: String, appId: String, projectId: String) {
        offeredRevisionIdsByIdentity[key(appId: appId, projectId: projectId), default: []].insert(revisionId)
    }

    func offers(for identity: NativeShellAppIdentity) -> Set<String> {
        offeredRevisionIdsByIdentity[key(appId: identity.appId, projectId: identity.projectId), default: []]
    }

    private func key(appId: String, projectId: String) -> String {
        "\(appId)::\(projectId)"
    }
}

private func html(_ marker: String) -> String {
    "<!doctype html><meta charset=utf-8><title>Starter install resume</title><main>\(marker)</main>"
}

private func nonce(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
