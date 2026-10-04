import Foundation
import Darwin
import XCTest
@testable import IrisMobileShellCore

final class NativeWebsiteInstallFlowTests: XCTestCase {
    func testDesktopOnlyDeepLinkDoesNotSwitchInstalledSelectionOrReaderData() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let inspection = try fixture.inspection(package)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        try await fixture.install(package: package, coordinator: coordinator)
        let dataDirectory = try await coordinator.readerDataDirectory(
            identity: inspection.identity, namespace: inspection.dataNamespace)
        let sentinel = dataDirectory.appendingPathComponent("preserved-mobile-data.txt")
        try Data("keep existing data".utf8).write(to: sentinel)
        let before = try await coordinator.refreshLibrary()
        let catalog = try JSONSerialization.data(withJSONObject: ["apps": [[
            "slug": "desktop-only", "name": "Desktop app", "macBundleId": "desktop.app",
        ]]])
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let flow = NativeWebsiteInstallFlow(coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport))
        do {
            _ = try await flow.prepare(url: fixture.intentURL(slug: "desktop-only"))
            XCTFail("a desktop listing must not open another installed app")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .mobileShellUnavailable(slug: "desktop-only"))
        }
        let after = try await coordinator.refreshLibrary()
        XCTAssertEqual(after.map { $0.identity }, before.map { $0.identity })
        XCTAssertEqual(after.map { $0.currentRevisionId }, before.map { $0.currentRevisionId })
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep existing data".utf8))
        XCTAssertEqual(transport.requestCount(), 1)
    }

    func testIntentParserAcceptsOnlyCanonicalPublikAndFallbackRoutes() throws {
        XCTAssertEqual(
            try NativeWebsiteInstallIntent.parse(URL(string: "https://publikhq.com/iris/apps/safe-demo")!).slug,
            "safe-demo"
        )
        XCTAssertEqual(
            try NativeWebsiteInstallIntent.parse(URL(string: "iris-apps://install/safe-demo")!).slug,
            "safe-demo"
        )

        let rejected = [
            "http://publikhq.com/iris/apps/safe-demo",
            "https://www.publikhq.com/iris/apps/safe-demo",
            "https://evil.example/iris/apps/safe-demo",
            "https://publikhq.com:443/iris/apps/safe-demo",
            "https://user@publikhq.com/iris/apps/safe-demo",
            "https://publikhq.com/iris/apps/safe-demo/",
            "https://publikhq.com/iris/apps/safe-demo/extra",
            "https://publikhq.com/iris/apps/safe-demo?download=https://evil.example/a",
            "https://publikhq.com/iris/apps/safe-demo#approve",
            "https://publikhq.com/iris/apps/safe%2Ddemo",
            "iris-apps://install/safe-demo?token=secret",
            "iris-apps://install/safe-demo/extra",
            "iris-apps://evil/safe-demo",
        ]

        for raw in rejected {
            XCTAssertThrowsError(try NativeWebsiteInstallIntent.parse(URL(string: raw)!)) { error in
                XCTAssertTrue(
                    error is NativeWebsiteInstallIntentError,
                    "unexpected error for \(raw): \(error)"
                )
            }
        }
    }

    // MARK: M7 -- cold and warm link landing, cross-checked by an independent oracle parser

    /// A second, from-scratch reader of the same two link shapes, written
    /// without looking at `NativeWebsiteInstallIntent.parse`'s
    /// implementation: plain string splitting instead of `URLComponents`,
    /// and its own idea of what counts as a valid slug. Deliberately looser
    /// than the production parser (it does not reject query strings,
    /// fragments, or an unstable-id slug), so it exists only to answer one
    /// question independently -- "what slug does a human reading this exact
    /// URL text land on" -- never to police every rejection the production
    /// parser is responsible for. A change that quietly made the production
    /// parser resolve `https://publikhq.com/iris/apps/<slug>` or
    /// `iris-apps://install/<slug>` to the WRONG slug would make this oracle
    /// disagree even though both parsers are otherwise unrelated code.
    private func independentReferenceSlug(_ raw: String) -> String? {
        if raw.hasPrefix("https://publikhq.com/iris/apps/") {
            let rest = String(raw.dropFirst("https://publikhq.com/iris/apps/".count))
            let slug = rest.split(separator: "?", maxSplits: 1)[0].split(separator: "#", maxSplits: 1)[0]
            return slug.isEmpty || slug.contains("/") ? nil : String(slug)
        }
        if raw.hasPrefix("iris-apps://install/") {
            let rest = String(raw.dropFirst("iris-apps://install/".count))
            let slug = rest.split(separator: "?", maxSplits: 1)[0].split(separator: "#", maxSplits: 1)[0]
            return slug.isEmpty || slug.contains("/") ? nil : String(slug)
        }
        return nil
    }

    func testColdAndWarmLandingSlugsAgreeWithAnIndependentlyWrittenReferenceParser() throws {
        // "Cold": the app has never been opened before on this device, so
        // this is the very first time this exact URL is seen.
        // "Warm": the same two link shapes, arriving again after the app is
        // already installed and open (the reader tapped the link a second
        // time, or the OS relaunched Iris into it). Both must resolve to the
        // identical slug as a from-scratch reference reader of the URL text,
        // whether this is the first or a later time it is seen -- link
        // resolution has no notion of "cold" or "warm" of its own.
        let coldAndWarmLinks: [(label: String, url: String)] = [
            ("cold universal link, reviewed app", "https://publikhq.com/iris/apps/nut-ai"),
            ("warm universal link, reviewed app, same slug seen again", "https://publikhq.com/iris/apps/nut-ai"),
            ("cold custom-scheme install link", "iris-apps://install/kneecap"),
            ("warm custom-scheme install link, same slug seen again", "iris-apps://install/kneecap"),
            ("cold universal link, desktop-only app", "https://publikhq.com/iris/apps/desktop-only-tool"),
            ("warm universal link, desktop-only app, same slug seen again", "https://publikhq.com/iris/apps/desktop-only-tool"),
        ]
        for (label, raw) in coldAndWarmLinks {
            let url = try XCTUnwrap(URL(string: raw), label)
            let produced = try NativeWebsiteInstallIntent.parse(url).slug
            let reference = try XCTUnwrap(independentReferenceSlug(raw), "reference parser found no slug for \(label)")
            XCTAssertEqual(produced, reference, "production and independent reference parser disagree for \(label)")
        }
    }

    func testIndependentReferenceParserAlsoAgreesOnRejectedNonCanonicalLinks() throws {
        // The inverse check: every link the production parser rejects as
        // non-canonical must not quietly resolve to a plausible-looking slug
        // under the independent reader either -- otherwise a person could be
        // shown one app's page while the reference reading of the same text
        // says another slug, an ambiguity this test refuses to accept as
        // "fine because the production code happens to throw".
        let ambiguousOrRejected = [
            "https://evil.example/iris/apps/nut-ai",
            "https://publikhq.com/iris/apps/nut-ai/extra",
            "iris-apps://evil/nut-ai",
        ]
        for raw in ambiguousOrRejected {
            XCTAssertThrowsError(try NativeWebsiteInstallIntent.parse(URL(string: raw)!), raw)
            if let reference = independentReferenceSlug(raw) {
                XCTAssertNotEqual(reference, "nut-ai", "independent reader must not silently agree on a slug for a rejected link: \(raw)")
            }
        }
    }

    func testSuccessUsesOneConsentThenStagesActivatesAndReturnsVerifiedLaunch() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("new app should require exactly one Install & Open confirmation")
        }
        XCTAssertEqual(review.slug, "safe-demo")
        XCTAssertEqual(review.reviewToken, review.consentToken)
        XCTAssertEqual(review.identity, try fixture.inspection(package).identity)

        let result = try await flow.installAndOpen(consentToken: review.consentToken)
        XCTAssertEqual(result.revisionId, review.revisionId)
        XCTAssertEqual(result.launch.launchedRevisionId, review.revisionId)
        XCTAssertEqual(result.source, .installed(alreadyStaged: false))
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.first?.currentRevisionId, review.revisionId)
        let requestCount = transport.requestCount()
        XCTAssertEqual(requestCount, 2)
    }

    func testAlreadyCurrentRevisionReverifiesAndOpensWithoutDownloadOrRepeatedConsentAndPreservesReaderData() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let inspection = try fixture.inspection(package)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        try await fixture.install(package: package, coordinator: coordinator)
        let dataDirectory = try await coordinator.readerDataDirectory(
            identity: inspection.identity,
            namespace: inspection.dataNamespace
        )
        let note = dataDirectory.appendingPathComponent("preserved.txt")
        try Data("reader-owned".utf8).write(to: note)

        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
        guard case .openedExisting(let result) = prepared else {
            return XCTFail("same published/current revision should reverify and open directly")
        }
        XCTAssertEqual(result.source, .alreadyInstalled)
        XCTAssertEqual(result.revisionId, inspection.revisionId)
        XCTAssertEqual(result.launch.launchedRevisionId, inspection.revisionId)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "reader-owned")
        let requestCount = transport.requestCount()
        XCTAssertEqual(requestCount, 1, "existing fast path must not redownload")
    }

    func testUnrelatedCorruptLibraryIdentityDoesNotBlockExactInstalledFastPath() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let inspection = try fixture.inspection(package)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        try await fixture.install(package: package, coordinator: coordinator)

        let unrelatedProject = fixture.storeRoot
            .appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent("unrelated-app", isDirectory: true)
            .appendingPathComponent("unrelated-project", isDirectory: true)
        let unrelatedRevisions = unrelatedProject.appendingPathComponent("revisions", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelatedRevisions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: unrelatedRevisions.appendingPathComponent("not-a-revision", isDirectory: true),
            withIntermediateDirectories: true
        )

        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
        guard case .openedExisting(let result) = prepared else {
            return XCTFail("unrelated corrupt identity must not block exact app lookup")
        }
        XCTAssertEqual(result.revisionId, inspection.revisionId)
        XCTAssertEqual(result.launch.launchedRevisionId, inspection.revisionId)
        XCTAssertEqual(transport.requestCount(), 1)
    }

    func testExactLibraryLookupRejectsTraversalIdentityWithoutCreatingStorage() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let traversal = NativeShellAppIdentity(appId: "../escape", projectId: "safe-project")

        do {
            _ = try await coordinator.libraryEntry(identity: traversal)
            XCTFail("path traversal identity must be rejected")
        } catch let error as NativeShellError {
            XCTAssertEqual(error, .invalidStableIdentifier("../escape"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storeRoot.path))
    }

    func testWrongCatalogDigestFailsBeforeConsentOrInstall() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let wrongDigest = "sha256:" + String(repeating: "0", count: 64)
        let catalog = try fixture.catalog(
            slug: "safe-demo",
            name: "Safe Demo",
            package: package,
            packageSHA256: wrongDigest
        )
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )

        do {
            _ = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
            XCTFail("digest mismatch must fail before consent")
        } catch let error as PublikMobileDownloadError {
            guard case .packageDigestMismatch(let expected, _) = error else {
                return XCTFail("unexpected download error: \(error)")
            }
            XCTAssertEqual(expected, wrongDigest)
        }
        let library = try await coordinator.refreshLibrary()
        let pending = await coordinator.pendingPackageReview()
        XCTAssertTrue(library.isEmpty)
        XCTAssertNil(pending)
    }

    func testUnsupportedCapabilitiesAreVisibleAndBlockedBeforeCoordinatorReviewOrStage() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.generatedUnsupportedPackage()
        let catalog = try fixture.catalog(
            slug: "capability-app",
            name: "Catalog Label",
            package: package.bytes
        )
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "capability-app"), body: package.bytes),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "capability-app"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("unsupported capability still needs a visible prepared review")
        }
        XCTAssertEqual(review.displayName, "Website Flow Test", "display must come from validated package bytes")
        XCTAssertEqual(review.requestedCapabilities, ["native.camera"])
        XCTAssertEqual(review.unsupportedCapabilities, ["native.camera"])

        do {
            _ = try await flow.installAndOpen(consentToken: review.consentToken)
            XCTFail("unsupported capability must be blocked before review/stage")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .unsupportedCapabilities(["native.camera"]))
        }
        let pending = await coordinator.pendingPackageReview()
        let library = try await coordinator.refreshLibrary()
        XCTAssertNil(pending)
        XCTAssertTrue(library.isEmpty)
    }

    func testStaleBaseBetweenConsentAndCommitIsRejectedWithoutActivatingCandidate() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let generated = try fixture.generatedPackageSet()
        let baseInspection = try fixture.inspection(generated.base.bytes)
        let candidateInspection = try fixture.inspection(generated.candidate.bytes)
        let winnerInspection = try fixture.inspection(generated.winner.bytes)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        try await fixture.install(package: generated.base.bytes, coordinator: coordinator)

        let catalog = try fixture.catalog(
            slug: "generated-app",
            name: "Generated App",
            package: generated.candidate.bytes
        )
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "generated-app"), body: generated.candidate.bytes),
        ])
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "generated-app"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("candidate should be prepared for consent")
        }

        let directStore = try NativeRevisionStore(
            rootURL: fixture.storeRoot,
            appId: winnerInspection.appId,
            projectId: winnerInspection.projectId,
            shellVersion: "1.0.0"
        )
        _ = try await directStore.stage(
            packageBytes: generated.winner.bytes,
            approvalAuthority: generated.winner.authority
        )
        try await directStore.activate(revisionId: winnerInspection.revisionId)

        do {
            _ = try await flow.installAndOpen(consentToken: review.consentToken)
            XCTFail("candidate with stale base must not activate")
        } catch let error as NativeShellError {
            XCTAssertEqual(
                error,
                .baseMismatch(expected: winnerInspection.revisionId, actual: baseInspection.revisionId)
            )
        }
        let launch = try await coordinator.launchActive(identity: review.identity)
        XCTAssertEqual(launch.launchedRevisionId, winnerInspection.revisionId)
        XCTAssertNotEqual(launch.launchedRevisionId, candidateInspection.revisionId)
    }

    func testFailedDownloadCanRetryFromFreshCatalogAndThenInstall() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: Data(), statusCode: 503),
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )

        await XCTAssertThrowsWebsiteDownloadError(
            try await flow.prepare(url: fixture.intentURL(slug: "safe-demo")),
            equals: .unexpectedStatus(503)
        )
        let retry = try await flow.retry()
        guard case .consentRequired(let review) = retry else {
            return XCTFail("retry should return a fresh prepared review")
        }
        let result = try await flow.installAndOpen(consentToken: review.consentToken)
        XCTAssertEqual(result.revisionId, review.revisionId)
        let requestCount = transport.requestCount()
        XCTAssertEqual(requestCount, 4)
    }

    func testDuplicateLateDownloadIsSupersededAndCannotReplaceNewerConsentOrActivation() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = RacingWebsiteTransport(
            catalog: catalog,
            packageURL: fixture.downloadURL(slug: "safe-demo"),
            package: package
        )
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        let url = fixture.intentURL(slug: "safe-demo")

        let older = Task { try await flow.prepare(url: url) }
        XCTAssertEqual(transport.firstDownloadStarted.wait(timeout: .now() + 5), .success)
        let newer = try await flow.prepare(url: url)
        guard case .consentRequired(let newerReview) = newer else {
            transport.releaseFirstDownload.signal()
            return XCTFail("newer request should own the prepared consent")
        }
        transport.releaseFirstDownload.signal()
        do {
            _ = try await older.value
            XCTFail("late older download must be rejected")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .requestSuperseded)
        }
        let pending = await coordinator.pendingPackageReview()
        XCTAssertNil(pending)

        let result = try await flow.installAndOpen(consentToken: newerReview.consentToken)
        XCTAssertEqual(result.revisionId, newerReview.revisionId)
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.first?.currentRevisionId, newerReview.revisionId)
    }

    func testCancelWhileDownloadIsLateLeavesNoReviewStageOrActivation() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = RacingWebsiteTransport(
            catalog: catalog,
            packageURL: fixture.downloadURL(slug: "safe-demo"),
            package: package,
            blockEveryDownload: true
        )
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        let task = Task { try await flow.prepare(url: fixture.intentURL(slug: "safe-demo")) }
        XCTAssertEqual(transport.firstDownloadStarted.wait(timeout: .now() + 5), .success)
        let cancelResult = await flow.cancel()
        XCTAssertEqual(cancelResult, .cancelled)
        transport.releaseFirstDownload.signal()

        do {
            _ = try await task.value
            XCTFail("cancelled late download must not recreate install state")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .cancelled)
        }
        let pending = await coordinator.pendingPackageReview()
        let library = try await coordinator.refreshLibrary()
        XCTAssertNil(pending)
        XCTAssertTrue(library.isEmpty)
    }

    func testExternalTaskCancellationDuringStageReportsStagedSideEffectAndNeverActivates() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let inspection = try fixture.inspection(package)
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("package should be prepared before commit cancellation test")
        }

        let filesBeforeStage = try independentWebsiteFiles(fixture.storeRoot)
        let installTask = Task {
            try await flow.installAndOpen(consentToken: review.consentToken)
        }
        let observedStageBoundary = await Task.detached(priority: .high) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if (try? independentWebsiteStageBoundaryAppeared(since: filesBeforeStage, under: fixture.storeRoot)) == true { return true }
                usleep(100)
            }
            return false
        }.value
        guard observedStageBoundary else { return XCTFail("SPEC 2.2: bounded wait did not observe staged object content") }
        let stageSideEffectAtBoundary = try independentWebsiteStageBoundaryAppeared(since: filesBeforeStage, under: fixture.storeRoot)
        XCTAssertTrue(stageSideEffectAtBoundary, "SPEC 2.2: object or manifest side effect exists at stage boundary")
        installTask.cancel()

        do {
            _ = try await installTask.value
            XCTFail("task cancellation during staging must stop before activation")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(
                error,
                .cancelledAfterStaging(
                    identity: inspection.identity,
                    revisionId: inspection.revisionId,
                    alreadyStaged: false
                )
            )
        }
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.count, 1)
        XCTAssertNil(library[0].currentRevisionId, "SPEC 2.2: cancellation never activates the staged version")
        XCTAssertEqual(library[0].stagedRevisions.map(\.revisionId), [inspection.revisionId], "SPEC 2.2: cancellation reports the completed staged side effect")
        let store = try NativeRevisionStore(rootURL: fixture.storeRoot, appId: inspection.identity.appId, projectId: inspection.identity.projectId, shellVersion: "1.0.0")
        let activeAfterCancellation = try await store.activeRevisionId()
        XCTAssertNil(activeAfterCancellation, "SPEC 2.2: active pointer is unchanged by staging cancellation")
        let stagedBytesRemain = try independentWebsiteStageBoundaryAppeared(since: filesBeforeStage, under: fixture.storeRoot)
        XCTAssertTrue(stagedBytesRemain, "SPEC 2.2: staged bytes remain observable after cancellation")
    }

    func testExistingLegacyPendingReviewIsNotOverwrittenByWebsiteCommit() async throws {
        let fixture = try WebsiteInstallFixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "safe-demo", name: "Safe Demo", package: package)
        let transport = SequentialWebsiteTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "safe-demo"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "safe-demo"))
        guard case .consentRequired(let websiteReview) = prepared else {
            return XCTFail("website package should be prepared")
        }
        let legacyReview = try await coordinator.reviewImport(packageBytes: package)

        do {
            _ = try await flow.installAndOpen(consentToken: websiteReview.consentToken)
            XCTFail("website commit must not overwrite an existing legacy review")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .anotherPackageReviewPending)
        }
        let pending = await coordinator.pendingPackageReview()
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(pending?.reviewToken, legacyReview.reviewToken)
        XCTAssertTrue(library.isEmpty)
    }
}

private final class SequentialWebsiteTransport: PublikMobileHTTPTransport, @unchecked Sendable {
    struct Step {
        let url: URL
        let response: PublikMobileHTTPResponse

        static func response(
            url: URL,
            body: Data,
            statusCode: Int = 200,
            mimeType: String = "application/json"
        ) -> Step {
            Step(
                url: url,
                response: PublikMobileHTTPResponse(
                    statusCode: statusCode,
                    mimeType: mimeType,
                    declaredContentLength: body.count,
                    finalURL: url,
                    body: body
                )
            )
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var count = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        try Task.checkCancellation()
        let step = try takeStep(for: request.url)
        guard step.response.body.count <= maximumBytes || step.response.statusCode != 200 else {
            throw WebsiteTransportError.responseTooLarge
        }
        progress?(step.response.body.count)
        return step.response
    }

    private func takeStep(for requestURL: URL?) throws -> Step {
        lock.lock()
        defer { lock.unlock() }
        guard !steps.isEmpty else { throw WebsiteTransportError.unexpectedRequest(requestURL) }
        let step = steps.removeFirst()
        guard requestURL == step.url else {
            throw WebsiteTransportError.wrongURL(expected: step.url, actual: requestURL)
        }
        count += 1
        return step
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class RacingWebsiteTransport: PublikMobileHTTPTransport, @unchecked Sendable {
    let firstDownloadStarted = DispatchSemaphore(value: 0)
    let releaseFirstDownload = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let catalog: Data
    private let packageURL: URL
    private let package: Data
    private let blockEveryDownload: Bool
    private var downloadCount = 0

    init(catalog: Data, packageURL: URL, package: Data, blockEveryDownload: Bool = false) {
        self.catalog = catalog
        self.packageURL = packageURL
        self.package = package
        self.blockEveryDownload = blockEveryDownload
    }

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url else { throw WebsiteTransportError.unexpectedRequest(nil) }
        if url == PublikMobileCatalogClient.catalogURL {
            return response(url: url, body: catalog)
        }
        guard url == packageURL else { throw WebsiteTransportError.unexpectedRequest(url) }

        let index = nextDownloadIndex()
        if index == 1 || blockEveryDownload {
            firstDownloadStarted.signal()
            while releaseFirstDownload.wait(timeout: .now() + 0.01) != .success {
                try Task.checkCancellation()
            }
        }
        guard package.count <= maximumBytes else { throw WebsiteTransportError.responseTooLarge }
        progress?(package.count)
        return response(url: url, body: package)
    }

    private func nextDownloadIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        downloadCount += 1
        return downloadCount
    }

    private func response(url: URL, body: Data) -> PublikMobileHTTPResponse {
        PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: "application/json",
            declaredContentLength: body.count,
            finalURL: url,
            body: body
        )
    }
}

private func independentWebsiteFiles(_ root: URL) throws -> [String: Int] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
    var files: [String: Int] = [:]
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
        files[String(url.path.dropFirst(root.path.count + 1))] = Int(info.st_size)
    }
    return files
}

private func independentWebsiteStageBoundaryAppeared(since old: [String: Int], under root: URL) throws -> Bool {
    let now = try independentWebsiteFiles(root)
    return now.contains { path, bytes in
        guard old[path] != bytes else { return false }
        return path.split(separator: "/").contains("objects") || path.split(separator: "/").contains("manifests")
    }
}


private enum WebsiteTransportError: Error {
    case unexpectedRequest(URL?)
    case wrongURL(expected: URL, actual: URL?)
    case responseTooLarge
}

private struct GeneratedWebsitePackage {
    let bytes: Data
    let authority: WebsiteApprovalAuthority
}

private struct GeneratedWebsitePackageSet {
    let base: GeneratedWebsitePackage
    let candidate: GeneratedWebsitePackage
    let winner: GeneratedWebsitePackage
}

private struct WebsiteApprovalAuthority: DeliveryApprovalAuthority {
    let approval: TrustedDeliveryApproval

    func trustedApproval(approvalId: String) throws -> TrustedDeliveryApproval? {
        approval.approvalId == approvalId ? approval : nil
    }
}

private final class WebsiteInstallFixture {
    let root: URL
    let storeRoot: URL
    private var packageIndex = 0

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-website-install-tests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func intentURL(slug: String) -> URL {
        URL(string: "https://publikhq.com/iris/apps/\(slug)")!
    }

    func downloadURL(slug: String) -> URL {
        URL(string: "https://publikhq.com/mobile/\(slug).irisapp")!
    }

    func safeDemoPackage() throws -> Data {
        try Data(contentsOf: repositoryRoot()
            .appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources/SafeDemo.irisapp"))
    }

    func inspection(_ package: Data) throws -> DeliveryPackageInspection {
        try DeliveryPackageV1Validator().inspect(packageBytes: package)
    }

    func catalog(
        slug: String,
        name: String,
        package: Data,
        packageSHA256: String? = nil
    ) throws -> Data {
        let inspection = try self.inspection(package)
        let descriptor: [String: Any] = [
            "version": 1,
            "platform": "ios",
            "packageFormat": NativeSecurity.packageFormat,
            "downloadUrl": downloadURL(slug: slug).absoluteString,
            "mediaType": "application/json",
            "byteCount": package.count,
            "packageSha256": packageSHA256 ?? inspection.packageSHA256,
            "appId": inspection.appId,
            "projectId": inspection.projectId,
            "baseRevisionId": inspection.baseRevisionId ?? NSNull(),
            "revisionId": inspection.revisionId,
            "contentHash": inspection.contentHash,
        ]
        let row: [String: Any] = [
            "slug": slug,
            "name": name,
            "guideSlug": slug,
            "macBundleId": NSNull(),
            "latestReleaseTag": NSNull(),
            "mobileShell": descriptor,
        ]
        return try JSONSerialization.data(withJSONObject: ["apps": [row]], options: [.sortedKeys])
    }

    func install(package: Data, coordinator: NativeShellLibraryCoordinator) async throws {
        let review = try await coordinator.reviewImport(packageBytes: package)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken,
            packageSHA256: review.packageSHA256
        )
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
    }

    func generatedPackageSet() throws -> GeneratedWebsitePackageSet {
        let appId = "iris.website-flow-test"
        let projectId = "iris.website-flow-test.mobile"
        let base = try generatePackage(
            content: "<main>base</main>",
            baseRevisionId: nil,
            nonce: String(repeating: "a", count: 64),
            appId: appId,
            projectId: projectId
        )
        let baseRevision = try inspection(base.bytes).revisionId
        let candidate = try generatePackage(
            content: "<main>candidate</main>",
            baseRevisionId: baseRevision,
            nonce: String(repeating: "b", count: 64),
            appId: appId,
            projectId: projectId
        )
        let winner = try generatePackage(
            content: "<main>winner</main>",
            baseRevisionId: baseRevision,
            nonce: String(repeating: "c", count: 64),
            appId: appId,
            projectId: projectId
        )
        return GeneratedWebsitePackageSet(base: base, candidate: candidate, winner: winner)
    }

    func generatedUnsupportedPackage() throws -> GeneratedWebsitePackage {
        try generatePackage(
            content: "<main>camera</main>",
            baseRevisionId: nil,
            nonce: String(repeating: "d", count: 64),
            appId: "iris.website-capability-test",
            projectId: "iris.website-capability-test.mobile",
            capabilities: ["native.camera"]
        )
    }

    private func generatePackage(
        content: String,
        baseRevisionId: String?,
        nonce: String,
        appId: String,
        projectId: String,
        capabilities: [String] = []
    ) throws -> GeneratedWebsitePackage {
        packageIndex += 1
        let output = root.appendingPathComponent("generated-\(packageIndex)", isDirectory: true)
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
            "--namespace", "iris.website-flow-test.data",
            "--capabilities", String(
                data: try JSONSerialization.data(withJSONObject: capabilities),
                encoding: .utf8
            )!,
            "--app", appId,
            "--project", projectId,
            "--display-name", "Website Flow Test",
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
            throw WebsiteFixtureError.generatorFailed(String(data: errorData, encoding: .utf8) ?? "generator failed")
        }
        let generated = try requiredObject(outputData)
        let packagePath = try requiredString(generated, "packagePath")
        let approvalPath = try requiredString(generated, "trustedApprovalPath")
        let approvalObject = try requiredObject(Data(contentsOf: URL(fileURLWithPath: approvalPath)))
        let approval = TrustedDeliveryApproval(
            approvalId: try requiredString(approvalObject, "approvalId"),
            requestId: nullableString(approvalObject, "requestId"),
            requestNonce: nullableString(approvalObject, "requestNonce"),
            appId: try requiredString(approvalObject, "appId"),
            projectId: try requiredString(approvalObject, "projectId"),
            baseRevisionId: nullableString(approvalObject, "baseRevisionId"),
            approvedRevisionId: try requiredString(approvalObject, "approvedRevisionId"),
            approvedContentHash: try requiredString(approvalObject, "approvedContentHash"),
            approvedAt: try requiredString(approvalObject, "approvedAt")
        )
        return GeneratedWebsitePackage(
            bytes: try Data(contentsOf: URL(fileURLWithPath: packagePath)),
            authority: WebsiteApprovalAuthority(approval: approval)
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

private enum WebsiteFixtureError: Error {
    case generatorFailed(String)
    case malformed(String)
}

private func requiredObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw WebsiteFixtureError.malformed("expected object")
    }
    return object
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String else {
        throw WebsiteFixtureError.malformed("missing \(key)")
    }
    return value
}

private func nullableString(_ object: [String: Any], _ key: String) -> String? {
    object[key] is NSNull ? nil : object[key] as? String
}

private extension DeliveryPackageInspection {
    var identity: NativeShellAppIdentity {
        NativeShellAppIdentity(appId: appId, projectId: projectId)
    }
}

private func XCTAssertThrowsWebsiteDownloadError<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expected: PublikMobileDownloadError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as PublikMobileDownloadError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
