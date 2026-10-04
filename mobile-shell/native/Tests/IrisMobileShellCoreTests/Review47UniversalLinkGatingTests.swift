import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47. End-to-end coverage through the
/// real NativeWebsiteInstallFlow (the same universal-link entry point
/// NativeShellAppView.onOpenURL/onContinueUserActivity use), with a fake
/// HTTP transport as the only test double at the boundary, never a mock of
/// NativeWebsiteInstallFlow, Review47AgeGate or Review47BlockList
/// themselves. Personas: P3 (a 12-year-old device, a blocked app reopened
/// from a link) and P2 (a hurried double-tap on a blocked app).
final class Review47UniversalLinkGatingTests: XCTestCase {
    // MARK: Persona P3: a 12-year-old device profile

    func testA12YearOldIsBlockedFromAn18PlusAppOpenedFromAUniversalLink() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        // 18 is Apple's current top App Store Connect age tier (4+, 9+,
        // 13+, 16+, 18+; confirmed 2026-09-27), used here in place of the
        // plan document's "17+" shorthand for the same "adult-only" idea.
        let catalog = try fixture.catalog(slug: "kneecap", name: "Kneecap", package: package, ageRating: 18)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let ageGate = Review47AgeGate(store: Review47InMemoryAgeStore(declaredMinimumAge: 12))
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47AgeGate: ageGate
        )

        do {
            _ = try await flow.prepare(url: fixture.intentURL(slug: "kneecap"))
            XCTFail("a 12-year-old must be blocked from an 18+ app")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .ageRestricted(slug: "kneecap", appAgeRating: 18, declaredAge: 12))
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1, "the gate must refuse before any package download")
        let library = try await coordinator.refreshLibrary()
        XCTAssertTrue(library.isEmpty, "an age-restricted app must never be staged")
    }

    func testA12YearOldIsAllowedA4PlusAppOpenedFromAUniversalLink() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "nut-ai", name: "Nut AI", package: package, ageRating: 4)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "nut-ai"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let ageGate = Review47AgeGate(store: Review47InMemoryAgeStore(declaredMinimumAge: 12))
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47AgeGate: ageGate
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "nut-ai"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("a 4+ app must reach the ordinary consent screen for a 12-year-old device")
        }
        XCTAssertEqual(review.slug, "nut-ai")
    }

    // RC-02: nobody has told Iris an age yet. A 16+ app opened from a link
    // is refused before any download (fails closed), the refusal says an
    // age is needed (declaredAge nil, so the sheet offers the age check),
    // and after the person answers 16 the same link proceeds.
    func testAnUnaskedDeviceIsRefusedA16PlusLinkThenAllowedAfterDeclaring16() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "kneecap", name: "Kneecap", package: package, ageRating: 16)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "kneecap"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let ageGate = Review47AgeGate(store: Review47InMemoryAgeStore(declaredMinimumAge: nil))
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47AgeGate: ageGate
        )

        do {
            _ = try await flow.prepare(url: fixture.intentURL(slug: "kneecap"))
            XCTFail("a device that never declared an age must not get a 16+ app")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .ageRestricted(slug: "kneecap", appAgeRating: 16, declaredAge: nil))
            XCTAssertTrue(error.description.contains("Tell Iris your age range"), "the refusal must say what to do, in plain words")
        }
        let downloadsAfterRefusal = await transport.requestCount()
        XCTAssertEqual(downloadsAfterRefusal, 1, "refused before any package download")

        await ageGate.declareMinimumAge(16)
        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "kneecap"))
        guard case .consentRequired(let review) = prepared else {
            return XCTFail("after declaring 16 the same link must reach the consent screen")
        }
        XCTAssertEqual(review.slug, "kneecap")
    }

    // RC-02: an app at the shell's own rating (13) never asks anything.
    func testAnUnaskedDeviceIsNotAskedForA13PlusApp() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "nut-ai", name: "Nut AI", package: package, ageRating: 13)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "nut-ai"), body: package),
        ])
        let flow = NativeWebsiteInstallFlow(
            coordinator: NativeShellLibraryCoordinator(rootURL: fixture.storeRoot),
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47AgeGate: Review47AgeGate(store: Review47InMemoryAgeStore(declaredMinimumAge: nil))
        )
        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "nut-ai"))
        guard case .consentRequired = prepared else { return XCTFail("13+ equals the shell rating: no question asked") }
    }

    // MARK: Guideline 4.7.1: a blocked app, including one already installed

    func testABlockedAppCannotBeOpenedFromAUniversalLinkEvenWhenAlreadyInstalled() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let inspection = try fixture.inspection(package)
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        try await fixture.install(package: package, coordinator: coordinator)
        let dataDirectory = try await coordinator.readerDataDirectory(
            identity: inspection.identity, namespace: inspection.dataNamespace)
        let sentinel = dataDirectory.appendingPathComponent("preserved-review47.txt")
        try Data("keep existing data".utf8).write(to: sentinel)

        let catalog = try fixture.catalog(slug: "freeharmony", name: "FreeHarmony", package: package, ageRating: nil)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let blockList = Review47BlockList(store: Review47InMemoryBlockListStore())
        await blockList.block(appId: inspection.appId)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47BlockList: blockList
        )

        do {
            _ = try await flow.prepare(url: fixture.intentURL(slug: "freeharmony"))
            XCTFail("a blocked app must not reopen from a universal link")
        } catch let error as NativeWebsiteInstallFlowError {
            XCTAssertEqual(error, .blockedByLocalPolicy(slug: "freeharmony", appId: inspection.appId))
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep existing data".utf8), "blocking must not touch existing reader data")
    }

    // Persona P2: a hurried power user double-taps the same link on a
    // blocked app. Both attempts must fail identically; the second is not
    // a crash, a different error, or a partial install.
    func testDoubleTappingAUniversalLinkOnABlockedAppFailsIdenticallyBothTimes() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let appId = try fixture.inspection(package).appId
        let catalog = try fixture.catalog(slug: "kneecap", name: "Kneecap", package: package, ageRating: nil)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let blockList = Review47BlockList(store: Review47InMemoryBlockListStore())
        await blockList.block(appId: appId)
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47BlockList: blockList
        )

        for attempt in 1...2 {
            do {
                _ = try await flow.prepare(url: fixture.intentURL(slug: "kneecap"))
                XCTFail("attempt \(attempt) must be refused")
            } catch let error as NativeWebsiteInstallFlowError {
                XCTAssertEqual(error, .blockedByLocalPolicy(slug: "kneecap", appId: appId), "attempt \(attempt)")
            }
        }
        let library = try await coordinator.refreshLibrary()
        XCTAssertTrue(library.isEmpty)
    }

    // "An old descriptor still installs but is flagged": no Guideline 4.7
    // metadata at all must not be blocked by a wired age gate or block list.
    func testAnOldDescriptorWithNoAppStoreMetadataStillInstallsEvenWithBothGatesWired() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "kneecap", name: "Kneecap", package: package, ageRating: nil)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
            .response(url: fixture.downloadURL(slug: "kneecap"), body: package),
        ])
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.storeRoot)
        let blockList = Review47BlockList(store: Review47InMemoryBlockListStore())
        let ageGate = Review47AgeGate(store: Review47InMemoryAgeStore(declaredMinimumAge: 12))
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport),
            review47BlockList: blockList,
            review47AgeGate: ageGate
        )

        let prepared = try await flow.prepare(url: fixture.intentURL(slug: "kneecap"))
        guard case .consentRequired = prepared else {
            return XCTFail("an old, unrated descriptor must still reach the ordinary consent screen")
        }
    }

    // Guideline 4.7.1's report mechanism, end to end from a real fetched
    // catalog descriptor through to the exact compose target, with no
    // network call in the composer itself.
    func testReportComposesTheRightContactFromARealFetchedDescriptorWithNoNetwork() async throws {
        let fixture = try Review47Fixture()
        defer { fixture.cleanup() }
        let package = try fixture.safeDemoPackage()
        let catalog = try fixture.catalog(slug: "nut-ai", name: "Nut AI", package: package, ageRating: 4)
        let transport = Review47SequentialTransport(steps: [
            .response(url: PublikMobileCatalogClient.catalogURL, body: catalog),
        ])
        let apps = try await PublikMobileCatalogClient(transport: transport).fetchCatalog()
        let app = try XCTUnwrap(apps.first { $0.slug == "nut-ai" })
        let descriptor = try XCTUnwrap(app.mobileShell)
        let metadata = try XCTUnwrap(descriptor.appStoreMetadata)
        let target = Review47ReportComposer.composeReport(
            for: metadata.reportContact,
            appDisplayName: app.name,
            appId: descriptor.appId
        )
        XCTAssertEqual(target.kind, .mail)
        XCTAssertEqual(
            target.url.absoluteString,
            "mailto:report@publikhq.com?subject=Report:%20Nut%20AI&body=App:%20Nut%20AI%20(\(descriptor.appId))%0A%0ADescribe%20the%20issue%20below.%0A"
        )
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1, "composing a report must not perform a second network request")
    }
}

// MARK: - Fixtures (private to this file; PublikMobileCatalogClientTests.swift and
// NativeWebsiteInstallFlowTests.swift each keep their own equivalent fixtures private too)

private actor Review47InMemoryAgeStore: Review47DeclaredAgeStore {
    private var age: Int?
    private var asked = false

    init(declaredMinimumAge: Int?) { age = declaredMinimumAge }

    func declaredMinimumAge() async -> Int? { age }
    func setDeclaredMinimumAge(_ age: Int?) async { self.age = age }
    func hasAskedOnce() async -> Bool { asked }
    func setHasAskedOnce(_ value: Bool) async { asked = value }
}

private actor Review47InMemoryBlockListStore: Review47BlockListStore {
    private var blocked: Set<String> = []

    func blockedAppIDs() async -> Set<String> { blocked }
    func setBlocked(_ appId: String, blocked isBlocked: Bool) async {
        if isBlocked { blocked.insert(appId) } else { blocked.remove(appId) }
    }
}

private actor Review47SequentialTransport: PublikMobileHTTPTransport {
    struct Step: Sendable {
        let url: URL
        let response: PublikMobileHTTPResponse

        static func response(url: URL, body: Data) -> Step {
            Step(url: url, response: PublikMobileHTTPResponse(
                statusCode: 200, mimeType: "application/json",
                declaredContentLength: body.count, finalURL: url, body: body
            ))
        }
    }

    private var steps: [Step]
    private var count = 0

    init(steps: [Step]) { self.steps = steps }

    func get(_ request: URLRequest, maximumBytes: Int, progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        guard !steps.isEmpty else { throw Review47FixtureError.unexpectedRequest(request.url) }
        let step = steps.removeFirst()
        guard request.url == step.url else { throw Review47FixtureError.wrongURL(expected: step.url, actual: request.url) }
        count += 1
        return step.response
    }

    func requestCount() -> Int {
        count
    }
}

private enum Review47FixtureError: Error {
    case unexpectedRequest(URL?)
    case wrongURL(expected: URL, actual: URL?)
}

private final class Review47Fixture {
    let root: URL
    let storeRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-review47-universal-link-tests-\(UUID().uuidString)", isDirectory: true)
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

    func catalog(slug: String, name: String, package: Data, ageRating: Int?) throws -> Data {
        let inspection = try self.inspection(package)
        var descriptor: [String: Any] = [
            "version": 1,
            "platform": "ios",
            "packageFormat": NativeSecurity.packageFormat,
            "downloadUrl": downloadURL(slug: slug).absoluteString,
            "mediaType": "application/json",
            "byteCount": package.count,
            "packageSha256": inspection.packageSHA256,
            "appId": inspection.appId,
            "projectId": inspection.projectId,
            "baseRevisionId": inspection.baseRevisionId ?? NSNull(),
            "revisionId": inspection.revisionId,
            "contentHash": inspection.contentHash,
        ]
        if let ageRating {
            descriptor["appStoreMetadata"] = [
                "kind": "iris.mobile-shell.app-store-metadata",
                "version": 1,
                "ageRating": ageRating,
                "privacySummary": "\(name) keeps data on this device only.",
                "privacyPolicyUrl": "https://publikhq.com/legal/privacy",
                "supportContact": ["kind": "email", "value": "support@publikhq.com"],
                "reportContact": ["kind": "email", "value": "report@publikhq.com"],
            ]
        }
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension DeliveryPackageInspection {
    var identity: NativeShellAppIdentity {
        NativeShellAppIdentity(appId: appId, projectId: projectId)
    }
}
