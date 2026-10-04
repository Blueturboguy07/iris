import XCTest

// unit m6-mobile-uitests. Covers design section 4 (Search tab): incremental
// results while typing, zero results, and Clear. Persona P1 ("the food
// app", vague words) is why zero-results must offer a way forward, not a
// dead end (design 4.1 item 4); P2 (hurried, types fast) is why the 120 ms
// debounce and sequence guard (design 4.1 item 3) must never show a stale
// result set - this file checks the *outcome* of that guard (the count line
// matches the box on screen), not its internal sequence numbers.
final class StoreSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// design 4.1 items 1 and 3: typing a query that matches exactly one
    /// generated app narrows the list to exactly that row, with the count
    /// line stating "1" - a real, checkable narrowing, not merely "some
    /// results appeared."
    func testTypingNarrowsResultsIncrementallyToOneExactMatch() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")

        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        // Verifier fix (2026-09-28): the query must match exactly one
        // *display name* under substring "contains" search (design 4.1 item
        // 3 / SPEC R8's "name contains" ranking rule), not merely one slug.
        // Names are "Fixture App <index>" with no zero-padding, so any
        // single-digit index other than 0 collides with its own decade
        // (e.g. "Fixture App 7" is also a substring of "Fixture App 70"
        // through "Fixture App 79" -- 11 matches at 100 apps, confirmed by
        // direct enumeration, not just this comment's claim). Index 0 has no
        // such collision: no two-digit index in 10..99 starts with "0"
        // (there is no "Fixture App 0X"), and the summary text ("Sample
        // summary for fixture app number 0.") never contains the contiguous
        // phrase "Fixture App 0" either, so "Fixture App 0" is genuinely
        // substring-unique at every catalog scale this fixture generates.
        field.typeText("Fixture App 0")

        let countLine = app.staticTexts[NativeStoreIdentifiers.searchCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(countLine.label.contains("1 app"), "A substring-unique query must narrow the count line to exactly 1 app, not just \"some\".")

        let row = app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(0)))
        assertVisibleText(row, contains: NativeStoreFixtureFacts.name(0))
    }

    /// design 4.1 item 4: a query that matches nothing must show the exact
    /// heading with the typed text quoted back, plus a way forward (a
    /// category chip list or Browse all apps), never a bare "no results."
    func testZeroResultsOffersAWayForwardNeverADeadEnd() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")

        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        field.typeText("zzz-no-such-app-zzz")

        let zero = app.staticTexts[NativeStoreIdentifiers.searchZero]
        assertVisibleText(zero, contains: "zzz-no-such-app-zzz")

        let browseAll = app.buttons[NativeStoreIdentifiers.searchBrowseAll]
        XCTAssertTrue(browseAll.waitForExistence(timeout: fixtureWait), "Zero results must always offer \"Browse all apps\" as a way forward (design 4.1 item 4, NN/g's three rules).")
        browseAll.tap()
        let categoriesScreen = app.element(NativeStoreIdentifiers.categories)
        XCTAssertTrue(categoriesScreen.waitForExistence(timeout: fixtureWait), "Browse all apps from zero results must actually navigate, not just be present.")
    }

    /// design 4.1 item 1: Clear removes the typed text and returns Search to
    /// its idle state (Recent plus category chips), a real content swap, not
    /// merely the field going empty.
    func testClearReturnsSearchToIdleRecentAndCategoriesState() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")

        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        field.typeText("Fixture App 3")
        let countLine = app.staticTexts[NativeStoreIdentifiers.searchCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait))

        let clear = app.buttons[NativeStoreIdentifiers.searchClear]
        XCTAssertTrue(clear.waitForExistence(timeout: fixtureWait))
        clear.tap()

        XCTAssertFalse(countLine.exists, "The count line must disappear once the query is cleared (idle state has no count).")
        let categories = app.element(NativeStoreIdentifiers.searchCategories)
        XCTAssertTrue(categories.waitForExistence(timeout: fixtureWait), "Clearing must return to the idle Recent-plus-categories layout (design 4.1 item 2).")
    }

    /// design 4.1 item 5: Search keeps working over the cached index while
    /// offline, and shows the dashed offline banner above the count line -
    /// search results must not silently vanish just because the network is
    /// down.
    func testSearchStillWorksOfflineWithBannerAboveResults() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("offline-warm")

        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        field.typeText("Fixture App 1")

        let banner = app.staticTexts[NativeStoreIdentifiers.searchOffline]
        assertVisibleText(banner, contains: "offline")
        let countLine = app.staticTexts[NativeStoreIdentifiers.searchCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait), "Search must still produce results from the cached index while offline.")
    }

    /// RC-06 (apple-compliance/REQUIRED_CHANGES.md, decided in DECISIONS.md):
    /// "Sponsored" marks a paid shelf placement only; search results are
    /// organic and never carry the tag. The same app that shows "Sponsored" on
    /// its Home card shows no tag, and no "Sponsored" in its spoken label, when
    /// a person finds it by searching. (Design 14 said the tag also appears on
    /// search rows; RC-06 replaced that so the "How we pick these" promise,
    /// "Search results are never paid for", is literally true. This test
    /// replaces a Core test that only asserted a constant was false.)
    func testSearchResultsNeverCarryTheSponsoredTagEvenForASponsoredApp() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        let slug = NativeStoreFixtureFacts.slug(NativeStoreFixtureFacts.sponsoredIndex)

        // The app really is sponsored on Home.
        let homeTag = app.staticTexts[NativeStoreIdentifiers.cardSponsored(slug)]
        assertVisibleText(homeTag, contains: "Sponsored")

        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.tap()
        field.typeText(NativeStoreFixtureFacts.name(NativeStoreFixtureFacts.sponsoredIndex))

        let row = app.element(NativeStoreIdentifiers.row(slug))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait), "the sponsored app is found by its own name like any other app")
        XCTAssertFalse(app.descendants(matching: .any)["iris.store.row.\(slug).sponsored"].exists, "RC-06: no Sponsored tag on a search result")
        XCTAssertFalse(row.label.contains("Sponsored"), "RC-06: the spoken label of a search result never says Sponsored, got \"\(row.label)\"")
    }

    /// design 4.1 item 2: an idle Search tab shows "Recent", up to five earlier
    /// searches as chips, and a Clear button. A person searches, clears the box,
    /// and finds the search waiting as a chip; tapping the chip runs it again;
    /// Clear empties the list. Round 6 test author: added, this part of the
    /// Search tab had no test. Recents live on this phone only, so the test
    /// clears them at the start and the end.
    func testSearchedTextComesBackAsARecentChipAndClearForgetsIt() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))

        let clearRecents = app.buttons[NativeStoreIdentifiers.searchRecentClear]
        if clearRecents.waitForExistence(timeout: 1) { clearRecents.tap() }

        field.tap()
        field.typeText("Fixture App 3")
        field.typeText("\n") // the keyboard's Search key: the person means this search
        XCTAssertTrue(app.staticTexts[NativeStoreIdentifiers.searchCount].waitForExistence(timeout: fixtureWait))

        let clear = app.buttons[NativeStoreIdentifiers.searchClear]
        XCTAssertTrue(clear.waitForExistence(timeout: fixtureWait))
        clear.tap()

        let recent = app.element(NativeStoreIdentifiers.searchRecent)
        XCTAssertTrue(recent.waitForExistence(timeout: fixtureWait), "design 4.1 item 2: the idle screen shows Recent once there is a recent search.")
        let chip = app.buttons["iris.store.search.recent.0"]
        XCTAssertTrue(chip.waitForExistence(timeout: fixtureWait), "the newest recent search is the first chip")
        XCTAssertTrue(chip.label.contains("Fixture App 3"), "the chip reads what was typed, got \"\(chip.label)\"")

        chip.tap()
        XCTAssertEqual(field.value as? String, "Fixture App 3", "tapping the chip runs that search again")
        XCTAssertTrue(app.staticTexts[NativeStoreIdentifiers.searchCount].waitForExistence(timeout: fixtureWait))

        app.buttons[NativeStoreIdentifiers.searchClear].tap()
        let forget = app.buttons[NativeStoreIdentifiers.searchRecentClear]
        XCTAssertTrue(forget.waitForExistence(timeout: fixtureWait), "design 4.1 item 2: Recent has a Clear button")
        forget.tap()
        XCTAssertFalse(app.buttons["iris.store.search.recent.0"].waitForExistence(timeout: 2), "Clear forgets the recent searches")
    }
}
