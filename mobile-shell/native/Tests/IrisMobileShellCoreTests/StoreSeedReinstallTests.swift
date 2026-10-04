import Foundation
import XCTest
@testable import IrisMobileShellCore

/// RC-11 (round 6): Get on a starter that someone removed sets it up again from
/// the files inside Iris. The person's view: Browse shows the apps that came
/// with Iris; one is not on this phone (fresh library); the button reads Get,
/// and after the tap the app is in the library at the revision the bundle ends
/// on. The oracle is the library read back, and how many times the real
/// (network) pipeline was asked, counted by a spy.
#if DEBUG
final class StoreSeedReinstallTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let identity0 = MyAppsUITestSeed.identity(forIndex: 0)

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("seed-reinstall-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    /// A stand-in for the network pipeline that only counts its calls.
    private actor SpyPipeline: StoreInstallPipeline {
        private(set) var installs: [String] = []
        private(set) var cancels = 0
        func install(slug: String, progress: @escaping @Sendable (StoreInstallProgressStep) -> Void) async throws -> StoreInstallPipelineOutcome {
            installs.append(slug)
            return .unsupported(reason: "spy")
        }
        func cancel() async { cancels += 1 }
    }

    /// One fixture starter whose slug spelling differs from its label, like "nut-ai" and "NutAI".
    private let entry = NativeStarterCatalog.Entry(label: "FixtureStarter", displayName: "Clock Studio", orderedFileNames: ["01.irisapp"])

    private func reinstaller(_ coordinator: NativeShellLibraryCoordinator, bundled: Bool = true) -> NativeStarterSeedReinstaller {
        let chain = NativeStarterInstaller.AppChain(displayName: "Clock Studio", orderedPackages: [MyAppsUITestSeed.packageBytes(forIndex: 0)])
        return NativeStarterSeedReinstaller(
            coordinator: coordinator, entries: [entry],
            hasBundledFiles: { _ in bundled },
            loadChain: { _ in chain }
        )
    }

    private func pipeline(_ spy: SpyPipeline, _ r: NativeStarterSeedReinstaller, identity: NativeShellAppIdentity?) -> StoreSeedAwarePipeline {
        StoreSeedAwarePipeline(base: spy, reinstaller: r, seedIdentity: { _ in identity })
    }

    // MARK: the button

    private func descriptor() async throws -> PublikMobileShellDescriptor {
        let bundled = await StoreCatalogSeed.bundled()
        let seed = try XCTUnwrap(bundled)
        return try XCTUnwrap(seed.pages.values.first?.mobileShell)
    }

    func testRemovedStarterWithBundledFilesOffersARealGet() async throws {
        let d = try await descriptor()
        let listing = StoreCatalogSeed.listing(for: d, installedRevisionId: nil, canReinstallFromBundle: true)
        let state = StoreInstallMachine.state(
            facts: StoreInstallFacts(appName: "Kneecap", listing: listing, installedRevisionId: nil, restriction: .none, isOnline: true),
            activity: .idle
        )
        XCTAssertEqual(state.kind, .get)
        XCTAssertEqual(state.label, "Get")
        XCTAssertTrue(state.isActionable)
    }

    /// No bundled files (a build without starters): the old plain note, no Get.
    func testRemovedStarterWithoutBundledFilesKeepsTheNote() async throws {
        let d = try await descriptor()
        let listing = StoreCatalogSeed.listing(for: d, installedRevisionId: nil, canReinstallFromBundle: false)
        let state = StoreInstallMachine.state(
            facts: StoreInstallFacts(appName: "Kneecap", listing: listing, installedRevisionId: nil, restriction: .none, isOnline: true),
            activity: .idle
        )
        XCTAssertEqual(state.kind, .unavailable)
        // round6/catalog-expand (SPEC L81, L113): the note says why, and never asks to restart Iris.
        XCTAssertFalse((state.note ?? "").isEmpty)
        XCTAssertFalse((state.note ?? "").contains("Close Iris"))
        XCTAssertFalse(state.isActionable)
    }

    /// An installed starter still reads Open, whether or not files are bundled.
    func testInstalledStarterStillReadsOpen() async throws {
        let d = try await descriptor()
        for canReinstall in [true, false] {
            let listing = StoreCatalogSeed.listing(for: d, installedRevisionId: d.revisionId, canReinstallFromBundle: canReinstall)
            let state = StoreInstallMachine.state(
                facts: StoreInstallFacts(appName: "Kneecap", listing: listing, installedRevisionId: d.revisionId, restriction: .none, isOnline: true),
                activity: .idle
            )
            XCTAssertEqual(state.kind, .open)
        }
    }

    /// An installed app at some OTHER revision is not offered a bundle reinstall
    /// (that would step on what the person has): the earlier behaviour stands.
    func testStarterInstalledAtAnotherRevisionIsNotReinstalled() async throws {
        let d = try await descriptor()
        let listing = StoreCatalogSeed.listing(for: d, installedRevisionId: "rev-sha256:" + String(repeating: "9", count: 64), canReinstallFromBundle: true)
        guard case let .unavailable(reason) = listing else { return XCTFail("expected unavailable, got \(listing)") }
        XCTAssertFalse(reason.contains("Close Iris"), "SPEC L113")
    }

    // MARK: the mapping

    /// Every app the shipped seed lists maps to a bundled starter chain: the
    /// slugs come from the real seed, the labels from the real starter list.
    func testEveryShippedSeedSlugMapsToAStarterChain() async throws {
        let bundled = await StoreCatalogSeed.bundled()
        let seed = try XCTUnwrap(bundled)
        XCTAssertEqual(Set(seed.apps.map(\.slug)).count, 4, "round6/catalog-expand: Kneecap, Nut AI, FreeHarmony, Lunara")
        for app in seed.apps {
            XCTAssertNotNil(
                NativeStarterSeedReinstaller.entry(forSlug: app.slug, in: NativeStarterCatalog.entries),
                "\(app.slug) has no bundled starter chain, so its Get could never set it up again"
            )
        }
        XCTAssertEqual(NativeStarterSeedReinstaller.entry(forSlug: "nut-ai", in: NativeStarterCatalog.entries)?.label, "NutAI")
        XCTAssertNil(NativeStarterSeedReinstaller.entry(forSlug: "not-a-starter", in: NativeStarterCatalog.entries))
        XCTAssertNil(NativeStarterSeedReinstaller.entry(forSlug: "", in: NativeStarterCatalog.entries))
    }

    // MARK: the tap

    /// The whole thing: a fresh library (the starter was removed), Get, and the
    /// app is back, active, with its name; the network pipeline was never asked.
    func testGetReinstallsFromTheBundleWithoutTouchingTheNetwork() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let before = try await coordinator.refreshLibrary()
        XCTAssertTrue(before.isEmpty, "the starter is really gone before the tap")
        let spy = SpyPipeline()
        let r = reinstaller(coordinator)
        XCTAssertTrue(r.canReinstall(slug: "fixture-starter"))
        let p = pipeline(spy, r, identity: identity0)
        let outcome = try await p.install(slug: "fixture-starter") { _ in }
        guard case let .installed(revisionId, identity) = outcome else { return XCTFail("expected installed, got \(outcome)") }
        XCTAssertEqual(identity, identity0)
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.map(\.displayName), ["Clock Studio"])
        XCTAssertEqual(library.first?.currentRevisionId, revisionId, "the app is active at the revision the outcome names")
        let spyInstalls = await spy.installs
        XCTAssertEqual(spyInstalls, [], "no download for an app that ships inside Iris")
    }

    /// Get on an app that is already there finishes as installed at what is there.
    func testGetOnAnAlreadyInstalledStarterChangesNothing() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let r = reinstaller(coordinator)
        let p = pipeline(SpyPipeline(), r, identity: identity0)
        let first = try await p.install(slug: "fixture-starter") { _ in }
        let second = try await p.install(slug: "fixture-starter") { _ in }
        XCTAssertEqual(first, second)
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.count, 1)
    }

    /// A slug the seed is not listing right now (the real catalog answered) goes
    /// to the real pipeline, exactly once, and nothing is reinstalled.
    func testNonSeedListingGoesToTheRealPipeline() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let spy = SpyPipeline()
        let p = pipeline(spy, reinstaller(coordinator), identity: nil)
        let outcome = try await p.install(slug: "fixture-starter") { _ in }
        XCTAssertEqual(outcome, .unsupported(reason: "spy"))
        let spyInstalls = await spy.installs
        XCTAssertEqual(spyInstalls, ["fixture-starter"])
        let after = try await coordinator.refreshLibrary()
        XCTAssertTrue(after.isEmpty)
    }

    /// A seed listing whose files are not inside this build also goes to the real pipeline.
    func testSeedListingWithoutBundledFilesGoesToTheRealPipeline() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let spy = SpyPipeline()
        let p = pipeline(spy, reinstaller(coordinator, bundled: false), identity: identity0)
        _ = try await p.install(slug: "fixture-starter") { _ in }
        let spyInstalls = await spy.installs
        XCTAssertEqual(spyInstalls, ["fixture-starter"])
    }

    /// A slug that names no starter goes to the real pipeline and installs nothing.
    func testUnknownSlugGoesToTheRealPipeline() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let spy = SpyPipeline()
        let p = pipeline(spy, reinstaller(coordinator), identity: identity0)
        _ = try await p.install(slug: "some-other-app") { _ in }
        let spyInstalls = await spy.installs
        XCTAssertEqual(spyInstalls, ["some-other-app"])
        let after = try await coordinator.refreshLibrary()
        XCTAssertTrue(after.isEmpty)
    }

    /// A broken bundled chain is a plain failure the button can show, not a crash
    /// and not a half install.
    func testCorruptBundledChainFailsCleanly() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let bad = NativeStarterInstaller.AppChain(displayName: "Clock Studio", orderedPackages: [Data("not a package".utf8)])
        let r = NativeStarterSeedReinstaller(coordinator: coordinator, entries: [entry], hasBundledFiles: { _ in true }, loadChain: { _ in bad })
        let p = pipeline(SpyPipeline(), r, identity: identity0)
        do {
            _ = try await p.install(slug: "fixture-starter") { _ in }
            XCTFail("expected a failure")
        } catch let error as StoreSeedReinstallError {
            guard case .failed = error else { return XCTFail("expected .failed, got \(error)") }
        }
        let after = try await coordinator.refreshLibrary()
        XCTAssertTrue(after.isEmpty)
    }

    /// Cancel is passed to both the reinstaller and the real pipeline.
    func testCancelReachesBothPipelines() async throws {
        let spy = SpyPipeline()
        let p = pipeline(spy, reinstaller(NativeShellLibraryCoordinator(rootURL: root)), identity: identity0)
        await p.cancel()
        let spyCancels = await spy.cancels
        XCTAssertEqual(spyCancels, 1)
    }
}
#endif
