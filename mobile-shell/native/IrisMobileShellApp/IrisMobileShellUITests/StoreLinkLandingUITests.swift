import XCTest

// R2-mobile-integration. Design 9.5 and R8.8: a Publik app link lands on that
// app's page in Browse, cold or warm, and never installs by itself. Covers
// CLICK-PATH-005: a link that arrives while another app is open full screen
// waits ("An app link from Publik is waiting."), and Continue closes the app
// and lands on the linked app's page, not in My apps and not in the old
// install sheet. Uses M6's fixture seam (catalog3: fixture apps plus the
// three bundled starter apps installed), never the live network.
final class StoreLinkLandingUITests: XCTestCase {
    private let linkedSlug = NativeStoreFixtureFacts.slug(0)
    private let linkedName = NativeStoreFixtureFacts.name(0)

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openLink(_ app: XCUIApplication) throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("XCUIApplication.open(_:) needs iOS 16.4") }
        app.open(try XCTUnwrap(URL(string: "iris-apps://install/\(linkedSlug)")))
    }

    private func assertLandedOnLinkedAppPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.descendants(matching: .any)["iris.store.app"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: fixtureWait), "The link must land on the app page.", file: file, line: line)
        let name = app.descendants(matching: .any)["iris.store.app.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: fixtureWait), file: file, line: line)
        XCTAssertTrue(name.label.contains(linkedName), "The page must be the linked app's page, got \(name.label).", file: file, line: line)
        XCTAssertTrue(app.storeTab(.browse).isSelected, "The app page lives in Browse.", file: file, line: line)
        let get = app.buttons["iris.store.app.get"]
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait), file: file, line: line)
        XCTAssertFalse(get.label.contains("Downloading") || get.label.contains("Verifying"),
                       "A link must never start an install by itself; the button read \(get.label).", file: file, line: line)
    }

    private func openKneecap(_ app: XCUIApplication) {
        app.storeTab(.myApps).tap()
        let open = app.buttons["iris.open.publik.kneecap"]
        XCTAssertTrue(app.scrollUntilExists(open), "organization SPEC 1.1: saved folders can place Open below the viewport")
        open.tap()
        XCTAssertTrue(app.element("iris.open.fullscreen-content").waitForExistence(timeout: fixtureWait))
    }

    /// Non-technical person taps a Publik link while nothing is open (warm).
    func testLinkWithNothingOpenLandsOnTheAppPageWithoutInstalling() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        XCTAssertTrue(app.storeTab(.browse).waitForExistence(timeout: fixtureWait))
        app.storeTab(.myApps).tap()
        try openLink(app)
        assertLandedOnLinkedAppPage(app)
    }

    /// Cold: Iris is not running and the person taps the link. The page
    /// shows "Finding this app..." while the list loads, then the linked
    /// app's page, never "not on iPhone yet" for a listed app (R8.8 cold).
    /// `open(_:)` launches the app when it is not running; the fixture
    /// arguments set here are the ones that launch uses.
    func testColdLinkLandsOnTheAppPageOnceTheListArrives() throws {
        let app = XCUIApplication()
        app.launchArguments += ["--iris-ui-test-fixtures", "catalog3"]
        app.addFixtureSession()
        app.terminate()
        try openLink(app)
        XCTAssertFalse(app.staticTexts["This app is not on iPhone yet. Installed apps still work in My apps."].waitForExistence(timeout: 2),
                       "A listed app must never be called unavailable while the list is still loading.")
        assertLandedOnLinkedAppPage(app)
    }

    /// Hurried power user: working in Kneecap, taps a link from Messages,
    /// then Continue on the waiting banner. The app closes (its save hook
    /// runs) and the linked app's page shows (CLICK-PATH-005).
    func testLinkWhileAnAppIsOpenWaitsThenContinueLandsOnTheAppPage() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecap(app)
        try openLink(app)

        let waiting = app.descendants(matching: .any)["iris.website.pending"].firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: fixtureWait), "The open app is never closed by a link; a waiting banner appears instead.")
        XCTAssertTrue(app.element("iris.open.fullscreen-content").exists, "Kneecap stays on screen while the link waits.")
        app.buttons["iris.website.pending.continue"].tap()

        // The close may ask the app to save first; if the app cannot confirm,
        // the reader decides (this test chooses to leave).
        let anyway = app.buttons["iris.open.close-without-save-confirmation"]
        if anyway.waitForExistence(timeout: 6) { anyway.tap() }
        assertLandedOnLinkedAppPage(app)
        XCTAssertFalse(app.descendants(matching: .any)["iris.website.pending"].firstMatch.exists, "The waiting banner is gone once the link was used.")
    }

    /// Edge user: taps the link by mistake and chooses Stay here. The app
    /// keeps running and no page opens behind it.
    func testStayHereKeepsTheAppOpenAndForgetsTheLink() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecap(app)
        try openLink(app)
        let stay = app.buttons["iris.website.pending.dismiss"]
        XCTAssertTrue(stay.waitForExistence(timeout: fixtureWait))
        stay.tap()
        XCTAssertFalse(app.descendants(matching: .any)["iris.website.pending"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.element("iris.open.fullscreen-content").exists, "Stay here keeps the app on screen.")
    }
}
