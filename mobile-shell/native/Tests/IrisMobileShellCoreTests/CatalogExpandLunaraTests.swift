import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Round 6, catalog-expand. Test author: spec only (docs/plans/20260928-all-routes/
/// round6/catalog-expand/SPEC.md; each assertion cites its SPEC line as "SPEC L<n>").
///
/// The owner asked why the iPhone store shows 3 apps. The decided answer: 4
/// apps, Lunara added, bundled but installed only by Get, behind the age
/// check. These tests are the person's view of that, on the seed that ships
/// inside Iris (`StoreCatalogSeed.bundled()`), with oracles from outside the
/// seed code: the package bytes on disk hashed with CryptoKit here, the ages
/// and names written in SPEC.md, and the age sheet sentences a person reads.
///
/// Expected to FAIL until the builder lands Lunara (there is no fourth app,
/// no Lunara package and no `Health and body` category yet).
final class CatalogExpandLunaraTests: XCTestCase {
    // SPEC L4, L107: the four apps a person sees, with the ages from SPEC L87-L92.
    // If the owner picks 18 for Lunara (SPEC L95, L97), change the one number below.
    private static let expected: [(slug: String, name: String, appId: String, age: Int)] = [
        ("kneecap", "Kneecap", "publik.kneecap", 4),
        ("nut-ai", "Nut AI", "publik.nut-ai", 13),
        ("freeharmony", "FreeHarmony", "publik.freeharmony", 13),
        ("lunara", "Lunara", "publik.lunara", 16),
    ]
    // SPEC L114: apps that cannot run in the shell and must never be listed.
    private static let excluded = ["NoScroll", "HAT", "Chirp", "Beaver", "Turbolarp", "MyMacroHero", "Microstudy"]

    private static let starterRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("IrisMobileShellApp/Resources/Starter", isDirectory: true)

    private func seed() async throws -> StoreCatalogSeed {
        try await XCTUnwrapAsync(await StoreCatalogSeed.bundled())
    }

    private func app(_ slug: String, in seed: StoreCatalogSeed) throws -> StoreApp {
        let index = seed.load.index(hiddenSlugs: [])
        return try XCTUnwrap(index.visibleApps.first { $0.slug == slug }, "\(slug) must be listed in Browse")
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The newest package file of an app, found by the starter list a phone installs from.
    private func shippedPackage(label: String) throws -> (bytes: Data, files: [String]) {
        let entry = try XCTUnwrap(NativeStarterCatalog.entries.first { $0.label == label }, "\(label) is in NativeStarterCatalog")
        let file = Self.starterRoot.appendingPathComponent(label).appendingPathComponent(try XCTUnwrap(entry.orderedFileNames.last))
        return (try Data(contentsOf: file), entry.orderedFileNames)
    }

    // MARK: what Browse lists (acceptance 1 and 2)

    func testBrowseListsTheFourAppsByNameOnOnePlainList() async throws {
        let seed = try await seed()
        let index = seed.load.index(hiddenSlugs: [])
        XCTAssertEqual(Set(index.visibleApps.map(\.name)), Set(Self.expected.map(\.name)), "SPEC L107: Kneecap, Nut AI, FreeHarmony, Lunara")
        XCTAssertEqual(index.visibleApps.count, 4, "SPEC L9, L12: 4 apps, no more and no fewer")
        XCTAssertEqual(seed.snapshot.pageCount, 1)
        XCTAssertFalse(StoreShelves.home(index).isEmpty)
        XCTAssertLessThan(index.visibleApps.count, 13, "SPEC L107: below 13 apps the store collapses to one All apps list, so 4 apps must stay under that line")
    }

    func testEveryRowHasASummaryOfAtMost80CharactersAndReadsByPublik() async throws {
        let seed = try await seed()
        for expected in Self.expected {
            let app = try app(expected.slug, in: seed)
            XCTAssertEqual(app.name, expected.name)
            XCTAssertFalse(app.summary.trimmingCharacters(in: .whitespaces).isEmpty, "\(app.name) has a summary")
            XCTAssertLessThanOrEqual(app.summary.count, 80, "SPEC L80, L108: \(app.name)'s summary is \(app.summary.count) characters")
            XCTAssertFalse(app.summary.contains("\u{2014}"), "no em dash")
            XCTAssertEqual(app.byLine, "By Publik", "SPEC L108: every row says By Publik")
            XCTAssertNotNil(app.iconHash.flatMap { seed.icons[$0] }, "\(app.name) has an icon")
            XCTAssertGreaterThan(app.byteCount ?? 0, 0)
        }
    }

    func testLunaraSitsInHealthAndBodyAndTheOtherCategoriesStay() async throws {
        let seed = try await seed()
        let index = seed.load.index(hiddenSlugs: [])
        XCTAssertTrue(Set(index.categories.map(\.name)).isSuperset(of: ["Video editing", "Food and nutrition", "Face and looks", "Health and body"]), "SPEC L80")
        XCTAssertEqual(try index.categoryNames(for: app("lunara", in: seed)), ["Health and body"])
        XCTAssertEqual(index.category(id: 4)?.name, "Health and body", "SPEC L80: id 4")
        for app in index.visibleApps {
            XCTAssertEqual(index.categoryNames(for: app).count, 1, "\(app.name) sits in one task-shaped category")
        }
    }

    // MARK: age ratings and the age check (acceptance 2 and 4)

    func testAgeRatingsAre4And13And13And16AndOnlyLunaraGetsABadge() async throws {
        let seed = try await seed()
        var badged: [String] = []
        for expected in Self.expected {
            let app = try app(expected.slug, in: seed)
            XCTAssertEqual(app.ageRating, expected.age, "SPEC L87-L92: \(expected.name)")
            if let rating = app.ageRating, rating > Review47AppStoreMetadata.shellAgeRating { badged.append(app.name) }
        }
        XCTAssertEqual(badged, ["Lunara"], "SPEC L108: a badge shows above the shell rating, so only Lunara has one")
    }

    private func facts(for app: StoreApp, restriction: StoreInstallFacts.Restriction) throws -> StoreInstallFacts {
        let descriptor = try XCTUnwrap(app.descriptor, "a seed row carries its install descriptor")
        // Not on this phone, files inside Iris: the Get a person can tap (SPEC L75).
        return StoreInstallFacts(
            appName: app.name,
            listing: StoreCatalogSeed.listing(for: descriptor, installedRevisionId: nil, canReinstallFromBundle: true),
            installedRevisionId: nil, restriction: restriction, isOnline: true)
    }

    func testLunaraAsksForAnAgeBeforeGetAndNothingInstallsUntilAgeIs16() async throws {
        let seed = try await seed()
        let lunara = try app("lunara", in: seed)

        // SPEC L110 step 1: no age declared, tap Get: the age sheet opens, nothing installs.
        let never = StoreRestrictionPolicy.restriction(app: lunara, isBlocked: false, declaredAge: nil)
        let neverFacts = try facts(for: lunara, restriction: never)
        let neverState = StoreInstallMachine.state(facts: neverFacts, activity: .idle)
        XCTAssertEqual(neverState.kind, .restricted)
        XCTAssertEqual(neverState.note, "This app is rated 16+. Tell Iris your age range to continue. Iris keeps this on your iPhone.")
        let (_, effect) = StoreInstallMachine.reduce(activity: .idle, event: .tap, facts: neverFacts, anotherInstallRunning: false)
        XCTAssertEqual(effect, .checkAge, "tapping Get opens the age sheet and starts no install")

        // Step 2: "13 or older": Get stays unavailable and a plain line says 16+.
        let thirteen = StoreRestrictionPolicy.restriction(app: lunara, isBlocked: false, declaredAge: 13)
        let thirteenState = StoreInstallMachine.state(facts: try facts(for: lunara, restriction: thirteen), activity: .idle)
        XCTAssertEqual(thirteenState.kind, .restricted)
        XCTAssertNotEqual(thirteenState.kind, .get)
        XCTAssertEqual(thirteenState.note, "This app is rated 16+. The age set on this iPhone (13+) is below that.")
        let (_, blockedEffect) = StoreInstallMachine.reduce(activity: .idle, event: .tap, facts: try facts(for: lunara, restriction: thirteen), anotherInstallRunning: false)
        XCTAssertNotEqual(blockedEffect, .startInstall, "a 13 year old's tap must never start the install")

        // Step 3: "16 or older": Get installs.
        let sixteen = StoreRestrictionPolicy.restriction(app: lunara, isBlocked: false, declaredAge: 16)
        XCTAssertEqual(sixteen, .none)
        let sixteenState = StoreInstallMachine.state(facts: try facts(for: lunara, restriction: sixteen), activity: .idle)
        XCTAssertEqual(sixteenState.kind, .get)
        XCTAssertEqual(sixteenState.label, "Get")
        XCTAssertTrue(sixteenState.isActionable)
    }

    func testTheOtherThreeAppsNeverAskForAnAge() async throws {
        let seed = try await seed()
        for slug in ["kneecap", "nut-ai", "freeharmony"] {
            let app = try app(slug, in: seed)
            XCTAssertEqual(StoreRestrictionPolicy.restriction(app: app, isBlocked: false, declaredAge: nil), .none, "SPEC L108, L109: \(app.name) has no gate")
        }
        // The gate itself, the way Review47 decides it: never declared fails closed for 16+, opens for 16.
        XCTAssertEqual(Review47AgeGate.decide(appAgeRating: 16, declaredAge: nil), .restricted(appAgeRating: 16, declaredAge: nil))
        XCTAssertEqual(Review47AgeGate.decide(appAgeRating: 16, declaredAge: 13), .restricted(appAgeRating: 16, declaredAge: 13))
        XCTAssertEqual(Review47AgeGate.decide(appAgeRating: 16, declaredAge: 16), .allowed)
    }

    // MARK: Lunara's page and package (acceptance 6, 9)

    func testLunarasPageAndRowMatchTheBytesOfThePackageThatShipsInsideIris() async throws {
        let seed = try await seed()
        let row = try app("lunara", in: seed)
        let page = try XCTUnwrap(seed.pages["lunara"], "Lunara has an app page in the seed")
        let (bytes, files) = try shippedPackage(label: "Lunara")
        XCTAssertEqual(files, ["01-base.irisapp"], "SPEC L79: one revision")
        let package = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let envelope = try XCTUnwrap(package["envelope"] as? [String: Any])

        XCTAssertEqual(page.mobileShell.appId, "publik.lunara")
        XCTAssertEqual(envelope["appId"] as? String, "publik.lunara")
        XCTAssertEqual(page.mobileShell.revisionId, envelope["revisionId"] as? String, "the seed lists the revision Iris installs")
        XCTAssertEqual(page.mobileShell.packageSHA256.replacingOccurrences(of: "sha256:", with: ""), sha256Hex(bytes), "SPEC L79: the page's package hash is the hash of the file")
        XCTAssertEqual(page.mobileShell.byteCount, bytes.count)
        XCTAssertEqual(row.byteCount, bytes.count, "the size Browse shows is the real package size")
        XCTAssertEqual(seed.apps.first { $0.slug == "lunara" }?.latestRevisionId, envelope["revisionId"] as? String)
        XCTAssertLessThanOrEqual(bytes.count, 2 * 1024 * 1024, "SPEC L116: the app grows by no more than 2 MB")
        XCTAssertTrue(NativeMobileMarketplacePolicy.launchAppIDs.contains("publik.lunara"), "Lunara is in the launch scope, like every other listed app")
    }

    func testLunarasPageShowsPlainPermissionAndPrivacyLines() async throws {
        let seed = try await seed()
        let page = try XCTUnwrap(seed.pages["lunara"])
        XCTAssertFalse(page.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(page.permissions.map(\.label), ["Keeps your log on this phone"], "SPEC L80, L110")
        XCTAssertEqual(page.permissions.map(\.capability), ["web.storage"], "SPEC L50: storage only")
        XCTAssertFalse(page.privacySummary.isEmpty, "SPEC L110: a privacy line")
        XCTAssertTrue((page.description + page.privacySummary).lowercased().contains("medical"), "SPEC L110: the not-a-medical-device wording reaches the page")
    }

    func testEveryListedAppsPagePromisesExactlyThePackagesCapabilities() async throws {
        let seed = try await seed()
        for (label, slug) in [("Kneecap", "kneecap"), ("NutAI", "nut-ai"), ("FreeHarmony", "freeharmony"), ("Lunara", "lunara")] {
            let (bytes, _) = try shippedPackage(label: label)
            let package = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let envelope = try XCTUnwrap(package["envelope"] as? [String: Any])
            let revision = try XCTUnwrap(envelope["revision"] as? [String: Any])
            let manifest = try XCTUnwrap(revision["manifest"] as? [String: Any])
            let asked = Set(try XCTUnwrap(manifest["capabilities"] as? [String]))
            let promised = Set(try XCTUnwrap(seed.pages[slug]).permissions.map(\.capability))
            XCTAssertEqual(promised, asked, "\(label): the page must not hide a capability or list one the package does not use")
        }
    }

    // MARK: not pushed onto the phone, Get sets it up from the bundle (acceptance 3)

    func testLunaraIsBundledWithFilesInsideIrisSoGetNeedsNoDownload() async throws {
        let entry = try XCTUnwrap(NativeStarterSeedReinstaller.entry(forSlug: "lunara", in: NativeStarterCatalog.entries), "SPEC L79: Lunara is in the bundled list, so Get can set it up offline")
        XCTAssertEqual(entry.displayName, "Lunara")
        XCTAssertEqual(entry.orderedFileNames, ["01-base.irisapp"])
        let file = Self.starterRoot.appendingPathComponent(entry.label).appendingPathComponent("01-base.irisapp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        // The three that install at first launch are untouched.
        for label in ["Kneecap", "NutAI", "FreeHarmony"] { XCTAssertNotNil(NativeStarterCatalog.entries.first { $0.label == label }) }
    }

    func testGetOnLunaraSetsItUpFromTheBundleAndOnlyThenItIsOnThePhone() async throws {
        let seed = try await seed()
        let page = try XCTUnwrap(seed.pages["lunara"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-expand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A phone supports web.storage (the one capability Lunara asks for, SPEC L50).
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.storage"]))

        // Before Get: a fresh library has nothing (Lunara is not pushed on first launch).
        let before = try await coordinator.refreshLibrary()
        XCTAssertTrue(before.isEmpty)

        // The button offers a real Get from the bundle (SPEC L75).
        let descriptor = page.mobileShell
        let listing = StoreCatalogSeed.listing(for: descriptor, installedRevisionId: nil, canReinstallFromBundle: true)
        let state = StoreInstallMachine.state(
            facts: StoreInstallFacts(appName: "Lunara", listing: listing, installedRevisionId: nil, restriction: .none, isOnline: true),
            activity: .idle)
        XCTAssertEqual(state.kind, .get)

        // Tap: the real package installs through the real coordinator, no network.
        let (bytes, _) = try shippedPackage(label: "Lunara")
        let entries = NativeStarterCatalog.entries
        let reinstaller = NativeStarterSeedReinstaller(
            coordinator: coordinator, entries: entries,
            hasBundledFiles: { _ in true },
            loadChain: { _ in NativeStarterInstaller.AppChain(displayName: "Lunara", orderedPackages: [bytes]) })
        XCTAssertTrue(reinstaller.canReinstall(slug: "lunara"))
        let identity = try NativeShellAppIdentity(appId: descriptor.appId, projectId: descriptor.projectId)
        let outcome = try await reinstaller.reinstall(slug: "lunara", identity: identity)
        guard case let .installed(revisionId, installedIdentity) = outcome else { return XCTFail("expected installed, got \(outcome)") }
        XCTAssertEqual(installedIdentity, identity)
        XCTAssertEqual(revisionId, descriptor.revisionId)

        let after = try await coordinator.refreshLibrary()
        XCTAssertEqual(after.map(\.displayName), ["Lunara"], "only the tapped app is on the phone")
        XCTAssertEqual(after.first?.currentRevisionId, descriptor.revisionId)

        // And now the row reads Open.
        let open = StoreInstallMachine.state(
            facts: StoreInstallFacts(
                appName: "Lunara",
                listing: StoreCatalogSeed.listing(for: descriptor, installedRevisionId: descriptor.revisionId, canReinstallFromBundle: true),
                installedRevisionId: descriptor.revisionId, restriction: .none, isOnline: true),
            activity: .idle)
        XCTAssertEqual(open.kind, .open)
    }

    // MARK: honest reason for an entry that cannot install (acceptance 7)

    func testARowWithNoBundledPackageSaysWhyInsteadOfAskingToRestartIris() async throws {
        let seed = try await seed()
        let descriptor = try XCTUnwrap(seed.pages["lunara"]).mobileShell
        let listing = StoreCatalogSeed.listing(for: descriptor, installedRevisionId: nil, canReinstallFromBundle: false)
        let state = StoreInstallMachine.state(
            facts: StoreInstallFacts(appName: "Lunara", listing: listing, installedRevisionId: nil, restriction: .none, isOnline: true),
            activity: .idle)
        XCTAssertEqual(state.kind, .unavailable)
        XCTAssertEqual(state.label, "Unavailable on this iPhone", "SPEC L113")
        XCTAssertFalse(state.isActionable, "SPEC L113: a disabled button")
        let note = state.note ?? ""
        XCTAssertFalse(note.isEmpty, "the reason is written on screen")
        XCTAssertTrue(note.lowercased().contains("publish"), "SPEC L113: a reason like 'Publik has not published this app yet', got \"\(note)\"")
        for banned in ["Close Iris", "open it again", "could not be verified", "download"] {
            XCTAssertFalse(note.lowercased().contains(banned.lowercased()), "SPEC L113: the note must never say \"\(banned)\", got \"\(note)\"")
        }
    }

    // MARK: no fake apps (acceptance 8)

    func testSearchFindsLunaraOnceAndNoneOfTheAppsThatCannotRunInTheShell() async throws {
        let seed = try await seed()
        let search = StoreSearchIndex(index: seed.load.index(hiddenSlugs: []))
        XCTAssertEqual(search.search("Lunara").slugs, ["lunara"], "SPEC L114: one result for Lunara")
        for name in Self.excluded {
            XCTAssertEqual(search.search(name).slugs, [], "SPEC L114: searching \(name) finds nothing")
            XCTAssertFalse(seed.pages.keys.contains(name.lowercased()), "no page for \(name)")
        }
        XCTAssertEqual(Set(seed.icons.keys).count, 4, "one icon each")
    }
}
