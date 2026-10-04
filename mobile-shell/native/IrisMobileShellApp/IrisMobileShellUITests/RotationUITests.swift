import XCTest

// unit m6-mobile-uitests. Covers design section 9.2 (rotation): iPhone
// landscape keeps a single column centered at max 800 pt; nothing becomes
// two columns, so the same identifiers and reading order hold in both
// orientations. Persona P3 ("rotation... mid-action") is why this file also
// checks that a value entered before rotating (the search query) survives
// it, not just that the screen still renders.
final class RotationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    /// design 9.2: rotating to landscape must not turn the shelf/list layout
    /// into two columns - checked by confirming the same identifiers that
    /// exist in portrait still exist, unchanged, in landscape (a real
    /// structural check, not a screenshot diff).
    func testLandscapeKeepsSingleColumnLayoutWithSameIdentifiers() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeShelfFeatured).waitForExistence(timeout: fixtureWait))

        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeShelfFeatured).waitForExistence(timeout: fixtureWait), "Featured must still exist after rotating to landscape (design 9.2: identifiers and reading order are identical to portrait).")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeCategoryRow).exists, "The category row must still exist in landscape.")
        // The single-column claim, checked concretely: My apps' list keeps
        // rendering as a `List` (one row per line) rather than a grid, by
        // confirming two known rows both still exist as distinct,
        // independently-tappable elements after rotation (a 2-column grid
        // would still pass this, so this is a floor check, not a full
        // layout-geometry assertion; the geometry claim itself belongs to a
        // main-session screenshot comparison, listed in HANDOFF.md).
        app.storeTab(.myApps).tap()
        let row = app.element(NativeStoreIdentifiers.myAppsRow("publik.kneecap"))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
    }

    /// P3, rotation mid-action: a typed search query must survive a
    /// rotation, not reset to empty - the visible proof state was preserved
    /// across the SwiftUI environment change a rotation triggers.
    func testSearchQuerySurvivesRotation() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        field.typeText("Fixture App 4")
        let countLine = app.staticTexts[NativeStoreIdentifiers.searchCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait))

        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait), "The search count line (and so the query itself) must survive rotation, not reset.")
        XCTAssertEqual(field.value as? String, "Fixture App 4", "The typed query text must still be in the field after rotating.")
    }

    /// design 9.2: rotating back to portrait must restore the original
    /// layout exactly - a round trip, not a one-way transform that leaves
    /// stale landscape state behind.
    func testRotatingBackToPortraitRestoresOriginalLayout() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let allApps = app.element(NativeStoreIdentifiers.homeAllApps)
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait))
        XCUIDevice.shared.orientation = .portrait

        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait), "Rotating back to portrait must restore the collapsed All apps list, not leave it in a landscape-only state.")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeCategoryRow).exists, "Portrait at 3 apps must still collapse (no chips), matching the pre-rotation state exactly.")
    }

    /// design 9.2, checked as geometry (round 6 test audit: the first test in
    /// this file admits in its own comment that a two column grid would pass
    /// it). In landscape the rows of the All apps list stay one column, one
    /// under the other, each row no wider than 800 pt and the column centred
    /// on the screen. A person would see exactly this: a single centred list.
    func testLandscapeListIsOneCentredColumnNoWiderThan800Points() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeAllApps).waitForExistence(timeout: fixtureWait))
        XCUIDevice.shared.orientation = .landscapeLeft

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: fixtureWait))
        XCTAssertGreaterThan(window.frame.width, window.frame.height, "the device must actually be in landscape")

        var frames: [CGRect] = []
        for index in 0..<3 {
            let row = app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(index)))
            XCTAssertTrue(row.waitForExistence(timeout: fixtureWait), "row \(index) must still be listed in landscape")
            frames.append(row.frame)
        }
        for (index, frame) in frames.enumerated() {
            XCTAssertLessThanOrEqual(frame.width, 800.5, "design 9.2: row \(index) is at most 800 pt wide, got \(frame.width)")
            XCTAssertEqual(frame.midX, window.frame.midX, accuracy: 2.5, "design 9.2: the column is centred, row \(index) is centred at \(frame.midX) on a \(window.frame.width) pt screen")
            XCTAssertEqual(frame.minX, frames[0].minX, accuracy: 1.0, "design 9.2: one column, so every row starts at the same x")
        }
        XCTAssertLessThanOrEqual(frames[0].maxY, frames[1].minY + 1, "design 9.2: the second row sits under the first, not beside it")
        XCTAssertLessThanOrEqual(frames[1].maxY, frames[2].minY + 1, "design 9.2: the third row sits under the second, not beside it")
    }
}
