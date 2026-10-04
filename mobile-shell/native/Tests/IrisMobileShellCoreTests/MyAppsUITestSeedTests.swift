import XCTest
@testable import IrisMobileShellCore

// Round 6, unit R6-mobile-prep-B (MA2 hook 5). The `--iris-ui-test-my-apps <n>`
// fixture must hand the UI tests n REAL installed apps to organise. These tests
// are the person's view of it: they install through the real coordinator, then
// read the library and the My apps screen back, and compare with numbers
// written here by hand (the names a person would see, the 12-app threshold
// from SPEC 1.1, the four "cl" apps), never with the seeder's own output.
#if DEBUG
final class MyAppsUITestSeedTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("my-apps-seed-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// Every generated package is a real DeliveryPackageV1: the strict validator
    /// (the one the app uses before it stages anything) accepts it and reads
    /// back the name a person will see.
    func testEveryGeneratedPackagePassesTheRealValidator() throws {
        for index in [0, 1, 11, 12, 99] {
            let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: MyAppsUITestSeed.packageBytes(forIndex: index))
            XCTAssertEqual(inspection.appId, "fixture.myapps-\(index + 1)")
            XCTAssertEqual(inspection.projectId, "fixture.myapps-\(index + 1).mobile")
            XCTAssertEqual(inspection.displayName, index < 12
                ? ["Clock Studio", "Clipboard", "Cloud Notes", "Clover Garden", "Budget Buddy", "Recipe Box",
                   "Daily Journal", "Kitchen Timer", "Habit Tracker", "Trail Maps", "Photo Frames", "Study Music"][index]
                : "Fixture App \(index + 1)")
            XCTAssertTrue(inspection.requestedCapabilities.isEmpty, "a fixture app asks for nothing")
        }
    }

    /// Two apps never share an identity, a nonce or a revision (a repeat would be
    /// refused as a replay, or two apps would collapse into one).
    func testPackagesAreDistinctAndDeterministic() throws {
        let a = try DeliveryPackageV1Validator().inspect(packageBytes: MyAppsUITestSeed.packageBytes(forIndex: 3))
        let b = try DeliveryPackageV1Validator().inspect(packageBytes: MyAppsUITestSeed.packageBytes(forIndex: 4))
        XCTAssertNotEqual(a.deliveryNonce, b.deliveryNonce)
        XCTAssertNotEqual(a.revisionId, b.revisionId)
        XCTAssertNotEqual(a.appId, b.appId)
        XCTAssertEqual(MyAppsUITestSeed.packageBytes(forIndex: 3), MyAppsUITestSeed.packageBytes(forIndex: 3))
    }

    /// A person launches with `--iris-ui-test-my-apps 12` and sees twelve apps
    /// in My apps: twelve library entries with their real names.
    func testSeedingTwelveGivesTwelveRealInstalledApps() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let report = await MyAppsUITestSeed.seedLibrary(count: 12, into: coordinator)
        XCTAssertEqual(report, .init(requested: 12, installed: 12, alreadyPresent: 0, failed: 0))
        let library = try await coordinator.refreshLibrary()
        XCTAssertEqual(library.count, 12)
        XCTAssertEqual(Set(library.map(\.displayName)), [
            "Clock Studio", "Clipboard", "Cloud Notes", "Clover Garden", "Budget Buddy", "Recipe Box",
            "Daily Journal", "Kitchen Timer", "Habit Tracker", "Trail Maps", "Photo Frames", "Study Music",
        ])
        XCTAssertTrue(library.allSatisfy { $0.currentRevisionId != nil }, "every seeded app is active, so Open works")
    }

    /// The tenth launch of the same fixture must not reinstall (or fail) anything.
    func testSeedingAgainIsANoOp() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        await MyAppsUITestSeed.seedLibrary(count: 14, into: coordinator)
        let again = await MyAppsUITestSeed.seedLibrary(count: 14, into: NativeShellLibraryCoordinator(rootURL: root))
        XCTAssertEqual(again, .init(requested: 14, installed: 0, alreadyPresent: 14, failed: 0))
    }

    /// A bigger fixture is a superset: 12 first, then 30, adds only the new 18.
    func testGrowingTheFixtureAddsOnlyTheNewApps() async throws {
        await MyAppsUITestSeed.seedLibrary(count: 12, into: NativeShellLibraryCoordinator(rootURL: root))
        let report = await MyAppsUITestSeed.seedLibrary(count: 30, into: NativeShellLibraryCoordinator(rootURL: root))
        XCTAssertEqual(report.installed, 18)
        XCTAssertEqual(report.alreadyPresent, 12)
        XCTAssertEqual(report.failed, 0)
    }

    /// The launch argument: the count is read from the token after the flag; a
    /// missing flag, a missing or non-number value, zero, negative or too large
    /// all mean "no fixture", never a guess.
    func testLaunchArgumentParsing() {
        let flag = "--iris-ui-test-my-apps"
        XCTAssertEqual(MyAppsUITestSeed.requestedCount(arguments: ["app", flag, "12"]), 12)
        XCTAssertEqual(MyAppsUITestSeed.requestedCount(arguments: ["app", "-x", flag, "1000", "-y"]), 1000)
        XCTAssertEqual(MyAppsUITestSeed.requestedCount(arguments: [flag, "2000"]), 2000)
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: ["app", "12"]), "no flag")
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: ["app", flag]), "flag with no value")
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: [flag, "twelve"]))
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: [flag, "0"]))
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: [flag, "-3"]))
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: [flag, "2001"]))
        XCTAssertNil(MyAppsUITestSeed.requestedCount(arguments: [flag, "12.5"]))
        XCTAssertEqual(MyAppsUITestSeed.storageNamespace(forCount: 12), "ui-test-my-apps-12")
    }

    /// The count is clamped, never trusted: a huge or negative argument cannot
    /// make a launch install thousands of apps.
    func testCountIsClamped() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let negative = await MyAppsUITestSeed.seedLibrary(count: -5, into: coordinator)
        XCTAssertEqual(negative.requested, 0)
        XCTAssertEqual(MyAppsUITestSeed.maximumCount, 2_000)
    }

    /// The SPEC 5.6 search case, end to end on what was really installed: at 12
    /// apps the search field is offered, and "cl" finds exactly Clock Studio,
    /// Clipboard, Cloud Notes and Clover Garden (counted by hand from the names).
    func testTwelveSeededAppsOfferSearchAndClFindsFour() async throws {
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        await MyAppsUITestSeed.seedLibrary(count: 12, into: coordinator)
        MyAppsUITestSeed.writeArrangementIfAbsent(count: 12, root: root)
        let library = try await coordinator.refreshLibrary()
        let inputs = library.map { entry in
            MyAppsAppInput(identity: entry.identity.id, originalName: entry.displayName, descriptionLine: "",
                           categoryIds: [], sizeBytes: 1_000, hasUpdate: false, isBlocked: false, hasCatalogSlug: false)
        }
        let arrangement = MyAppsOrganizationFile(rootForTest: root).load().arrangement
        let now = Date()
        let idle = MyAppsScreen.sections(input: .init(apps: inputs, categories: [], arrangement: arrangement, sort: .groups, query: "", now: now))
        XCTAssertTrue(idle.showSearchField, "12 apps is the threshold that turns the search field on")
        let found = MyAppsScreen.sections(input: .init(apps: inputs, categories: [], arrangement: arrangement, sort: .groups, query: "cl", now: now))
        XCTAssertEqual(found.searchMatchCount, 4)
        XCTAssertEqual(Set(found.sections.flatMap(\.rows).map(\.displayName)), ["Clock Studio", "Clipboard", "Cloud Notes", "Clover Garden"])
        let eleven = MyAppsScreen.sections(input: .init(apps: Array(inputs.prefix(11)), categories: [], arrangement: arrangement, sort: .groups, query: "", now: now))
        XCTAssertFalse(eleven.showSearchField, "11 apps must not show it")
    }

    /// The people-made side: three folders (one empty) and two renamed apps,
    /// written next to the library, read back as the screen would.
    func testArrangementHasThreeFoldersOneEmptyAndTwoRenames() throws {
        MyAppsUITestSeed.writeArrangementIfAbsent(count: 12, root: root)
        let arrangement = MyAppsOrganizationFile(rootForTest: root).load().arrangement
        XCTAssertEqual(arrangement.folders.map(\.name), ["Favourites", "Later", "Empty shelf"])
        XCTAssertEqual(arrangement.folders.map(\.apps.count), [3, 1, 0])
        XCTAssertEqual(arrangement.apps.values.compactMap(\.name).sorted(), ["Habits", "Hikes"])
    }

    /// A repeat launch keeps what the person changed: an existing file is left alone.
    func testExistingArrangementFileIsNeverOverwritten() throws {
        MyAppsUITestSeed.writeArrangementIfAbsent(count: 12, root: root)
        let file = try MyAppsOrganizationFile(root: root)
        var edited = file.load().arrangement
        edited.folders[0].name = "Renamed by the person"
        try file.save(edited)
        MyAppsUITestSeed.writeArrangementIfAbsent(count: 12, root: root)
        XCTAssertEqual(file.load().arrangement.folders[0].name, "Renamed by the person")
    }

    /// A small fixture only names folders it can fill: at 4 apps there is no
    /// "Favourites", no rename, only the empty shelf; at 5 apps Favourites
    /// holds the one app that exists.
    func testSmallCountOnlyUsesAppsThatExist() {
        let arrangement = MyAppsUITestSeed.arrangement(count: 4)
        XCTAssertEqual(arrangement.folders.map(\.name), ["Empty shelf"])
        XCTAssertTrue(arrangement.apps.isEmpty)
        let five = MyAppsUITestSeed.arrangement(count: 5)
        XCTAssertEqual(five.folders.map(\.name), ["Favourites", "Empty shelf"])
        XCTAssertEqual(five.folders[0].apps, [MyAppsUITestSeed.identity(forIndex: 4).id])
    }
}

private extension MyAppsOrganizationFile {
    init(rootForTest root: URL) { self = try! MyAppsOrganizationFile(root: root) }
}
#endif
