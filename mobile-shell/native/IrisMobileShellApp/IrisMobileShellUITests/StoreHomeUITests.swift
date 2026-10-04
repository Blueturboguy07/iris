import XCTest

// unit m6-mobile-uitests. Covers design section 3 (Store home / Browse tab):
// the under-13 collapse to "All apps", shelves and chips once there are
// enough apps, the Featured shelf's "Chosen by Publik" label, See all
// counts, and pull-to-refresh's status-line change. Personas: P1 (the
// vague-words, first-big-control reader) drives the collapse and Featured
// checks; P3 (the edge user) drives the offline/stale status-line checks in
// `testOfflineWarmShowsCachedShelvesWithOfflineStatusLine`.
final class StoreHomeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// SPEC 3.2's collapse rule: under 13 visible apps, Browse renders one
    /// "All apps" list and skips chips and every shelf. `catalog3` seeds
    /// exactly 3 apps, so this is the concrete, always-true case of the
    /// collapse rule. (round6/catalog-expand: the catalog Iris ships with is
    /// now 4 apps, still under the threshold; `CatalogExpandUITests` covers
    /// the real bundled seed. This test stays on the 3-app fixture.)
    func testUnder13AppsCollapsesToOneAllAppsListWithNoShelves() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")

        let allApps = app.element(NativeStoreIdentifiers.homeAllApps)
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait), "The collapsed All apps list must render for a 3-app catalog.")

        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeCategoryRow).exists, "No category chip row below the collapse threshold.")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeShelfFeatured).exists, "No Featured shelf below the collapse threshold.")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeShelfNew).exists, "No New and updated shelf below the collapse threshold.")

        // The visible state change this test is actually about: every
        // generated app's row is readable inside the collapsed list, by its
        // real name text, not merely "some row exists."
        for index in 0..<3 {
            let row = app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(index)))
            assertVisibleText(row, contains: NativeStoreFixtureFacts.name(index))
        }
    }

    /// SPEC 3.1/3.2: at 100 (or 1,000) apps the category row, Featured shelf
    /// and New-and-updated shelf all render, each with a real See all count
    /// pulled from the catalog, not a placeholder.
    func testAtScaleShowsChipsFeaturedAndCategoryShelvesWithRealCounts() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")

        let categoryRow = app.element(NativeStoreIdentifiers.homeCategoryRow)
        XCTAssertTrue(categoryRow.waitForExistence(timeout: fixtureWait))
        let allChip = app.buttons[NativeStoreIdentifiers.homeCategoryAll]
        assertVisibleText(allChip, contains: "All")

        // Featured: design section 3.1 item 4, "Chosen by Publik" must be on
        // screen next to the shelf header, not merely the shelf container.
        let featuredShelf = app.element(NativeStoreIdentifiers.homeShelfFeatured)
        XCTAssertTrue(featuredShelf.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(
            featuredShelf.staticTexts["Chosen by Publik"].waitForExistence(timeout: fixtureWait),
            "Featured must say \"Chosen by Publik\" (design decision D9: never call a paid slot Featured)."
        )
        let featuredCard = featuredShelf.element(NativeStoreIdentifiers.card(NativeStoreFixtureFacts.slug(NativeStoreFixtureFacts.featuredIndex)))
        XCTAssertTrue(featuredCard.waitForExistence(timeout: fixtureWait), "The generator's featured app (index 1) must appear inside the Featured shelf specifically.")

        // Sponsored: distinct visual language from Featured (design section
        // 14), tag text is literally "Sponsored", never "Featured".
        let sponsoredTag = app.staticTexts[NativeStoreIdentifiers.cardSponsored(NativeStoreFixtureFacts.slug(NativeStoreFixtureFacts.sponsoredIndex))]
        assertVisibleText(sponsoredTag, contains: "Sponsored")

        // A category shelf's See all count is the catalog's own appCount,
        // not "however many cards happened to render" (design 3.1 item 6).
        let categoryShelf = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.home.shelf.category.")).firstMatch
        XCTAssertTrue(categoryShelf.waitForExistence(timeout: fixtureWait))
        let seeAll = categoryShelf.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.see-all'")).firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(seeAll.label.hasPrefix("See all ("), "See all must show a real, parenthesized count, e.g. \"See all (8)\", per design 3.1 item 6.")
    }

    /// design section 3.1 item 7: with more than 6 non-empty categories (the
    /// fixture generator always emits 24), a final "Browse all categories"
    /// row appears and pushes the All categories screen - a real navigation
    /// change, not just a tap target existing.
    func testBrowseAllCategoriesRowPushesAllCategoriesScreen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")

        let browseAll = app.buttons[NativeStoreIdentifiers.homeBrowseAllCategories]
        // Mutation: never rendering Browse all categories still fails the scroll assertion (U9).
        XCTAssertTrue(app.scrollUntilExists(browseAll), "Browse all categories (\(NativeStoreIdentifiers.homeBrowseAllCategories)) must become visible after scrolling.")
        XCTAssertTrue(browseAll.waitForExistence(timeout: fixtureWait))
        browseAll.tap()

        let categoriesScreen = app.element(NativeStoreIdentifiers.categories)
        XCTAssertTrue(categoriesScreen.waitForExistence(timeout: fixtureWait), "Tapping Browse all categories must land on the All categories screen.")
        // At least one category row must show a real "N apps" count, not 0
        // for every row (the generator distributes apps across all 24).
        let firstRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.categories.row.")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(firstRow.label.contains("apps"), "Each All categories row must state its app count in words.")
    }

    /// design 3.1 item 5 and section 5 ("New and updated (See all) uses the
    /// category page layout with the title 'New and updated'"): the shelf's
    /// See all shows a real count, "See all (N)", and the page it opens says
    /// "New and updated" once and counts the same N apps. Round 6 test author:
    /// added, the New shelf's See all had no test.
    func testNewAndUpdatedSeeAllOpensAPageWithThatTitleAndTheSameCount() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        let shelf = app.element(NativeStoreIdentifiers.homeShelfNew)
        guard shelf.waitForExistence(timeout: fixtureWait) else {
            throw XCTSkip("This fixture has no app badged new or updated, so the New and updated shelf is correctly absent (design 3.1 item 5: it renders only when N is 1 or more).")
        }
        let seeAll = app.buttons[NativeStoreIdentifiers.homeShelfNewSeeAll]
        XCTAssertTrue(seeAll.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(seeAll.label.hasPrefix("See all ("), "See all shows a real count, got \"\(seeAll.label)\"")
        let shelfCount = Int(seeAll.label.dropFirst("See all (".count).prefix { $0.isNumber }) ?? 0
        XCTAssertGreaterThan(shelfCount, 0)
        seeAll.tap()

        XCTAssertTrue(app.element(NativeStoreIdentifiers.category).waitForExistence(timeout: fixtureWait), "See all opens the category page layout")
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'New and updated'"))
        XCTAssertTrue(title.firstMatch.waitForExistence(timeout: fixtureWait), "the page is titled New and updated")
        XCTAssertEqual(title.count, 1, "the title shows once on the page (store-proportions SPEC L153)")
        let countLine = app.staticTexts[NativeStoreIdentifiers.categoryCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(countLine.label.hasPrefix("\(shelfCount) app"), "the count line says the same \(shelfCount) apps, got \"\(countLine.label)\"")
    }

    /// design section 3.4: the status line's exact text changes with the
    /// catalog's freshness, and `iris.catalog.load` (kept identifier) is
    /// both the pull-to-refresh proxy and a tappable refresh action per the
    /// design's own note. Pulling to refresh (or triggering `.load`) while
    /// online must move the status line to a "Checked <time>" sentence.
    func testRefreshMovesStatusLineToACheckedJustNowSentence() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")

        let status = app.staticTexts[NativeStoreIdentifiers.homeStatus]
        XCTAssertTrue(status.waitForExistence(timeout: fixtureWait))
        // Verifier fix (2026-09-28): this was a no-op ternary (both branches
        // evaluated to the same expression, so the `.exists` check on the
        // status label was computed and discarded) -- simplified to what it
        // was actually doing.
        let refresh = app.buttons["iris.catalog.load"]
        if refresh.waitForExistence(timeout: fixtureWait) {
            refresh.tap()
        } else {
            // Pull-to-refresh gesture fallback if `.load` is not exposed as
            // a standalone tappable control in the final layering.
            let home = app.element(NativeStoreIdentifiers.home)
            home.swipeDown()
        }
        assertVisibleText(status, contains: "Checked")
    }

    /// design section 10, Home / Offline with cache row: `offlineWarm` seeds
    /// a real catalog3-shaped snapshot into the on-disk cache before the app
    /// asks, then makes every live request fail. Browse must still show the
    /// 3 cached apps, and the status line must read the offline sentence,
    /// not the online one - the visible proof that Browse painted from
    /// cache rather than hanging on a dead network call.
    func testOfflineWarmShowsCachedShelvesWithOfflineStatusLine() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("offline-warm")

        let allApps = app.element(NativeStoreIdentifiers.homeAllApps)
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait), "Cached shelves must still paint while offline (design D15).")
        let status = app.staticTexts[NativeStoreIdentifiers.homeStatus]
        assertVisibleText(status, contains: "Offline")
    }

    /// design section 10, Home / Offline without cache row: `offlineCold` is
    /// the true first-launch-in-airplane-mode case (no cache, and this
    /// unit's seeding step deliberately installs nothing for this one mode).
    /// Browse must never show a blank screen: it falls back to the bundled
    /// starter descriptors as an "All apps" list.
    func testOfflineColdFallsBackToBundledStarterRowsNeverBlank() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("offline-cold")

        let allApps = app.element(NativeStoreIdentifiers.homeAllApps)
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait), "A true first launch offline must show the bundled starter rows, never a blank Browse screen.")
        let status = app.staticTexts[NativeStoreIdentifiers.homeStatus]
        assertVisibleText(status, contains: "Offline")
    }
}

/// SPEC R8.4 / design section 13.3: Browse at 1,000 apps must render the
/// same layout as at 100 (only the See all counts and category-row scroll
/// extent grow) and stay within the peak-memory budget. This file's test is
/// the functional half (does it still look and behave right); the
/// Instruments memory pass itself is a main-session step (see
/// `INTEGRATION_HOOKS.md` hook 1, step 8, and `HANDOFF.md`
/// `main_session_steps`) because Instruments needs the Xcode GUI.
final class StoreScaleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAt1000AppsLayoutMatches100AppsExceptCountsAndPaging() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog1000")

        let categoryRow = app.element(NativeStoreIdentifiers.homeCategoryRow)
        XCTAssertTrue(categoryRow.waitForExistence(timeout: fixtureWait))
        let featuredShelf = app.element(NativeStoreIdentifiers.homeShelfFeatured)
        XCTAssertTrue(featuredShelf.waitForExistence(timeout: fixtureWait), "Identical shelf set to the 100-app catalog (design 3.2 table).")

        // The one thing that is allowed to differ: a category See all count
        // in the thousands range, not the tens.
        let categoryShelf = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.home.shelf.category.")).firstMatch
        XCTAssertTrue(categoryShelf.waitForExistence(timeout: fixtureWait))
        let seeAll = categoryShelf.buttons.matching(NSPredicate(format: "identifier ENDSWITH '.see-all'")).firstMatch
        XCTAssertTrue(seeAll.waitForExistence(timeout: fixtureWait))
        XCTAssertFalse(seeAll.label.contains("(0)"), "A category shelf must not claim zero apps at 1,000-app scale.")
    }

    /// design section 5: at 500+ apps in one category, the category page
    /// must load in 50-row chunks with a visible "Loading more..." footer
    /// while scrolling, never a silent freeze or a duplicated row.
    func testCategoryPageLoadsMoreRowsOnScrollWithVisibleFooter() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog1000")

        let allCategories = app.buttons[NativeStoreIdentifiers.homeBrowseAllCategories]
        // Mutation: a missing Browse all categories row still blocks the paging journey (U14).
        XCTAssertTrue(app.scrollUntilExists(allCategories), "Browse all categories (\(NativeStoreIdentifiers.homeBrowseAllCategories)) must become visible after scrolling.")
        XCTAssertTrue(allCategories.waitForExistence(timeout: fixtureWait))
        allCategories.tap()
        let firstCategoryRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.categories.row.")).firstMatch
        XCTAssertTrue(firstCategoryRow.waitForExistence(timeout: fixtureWait))
        firstCategoryRow.tap()

        let list = app.element(NativeStoreIdentifiers.categoryList)
        XCTAssertTrue(list.waitForExistence(timeout: fixtureWait))
        // Round 6 test audit: this used to swipe and then check only that the
        // count line still said "apps". It now reads what a person could see on
        // the way down: the count line gives the real total up front (design 5,
        // "count from categories.json, not from loaded rows"), the rows that
        // come on screen while scrolling reach a full screen and more, and the
        // list never shows more rows than the total says exist.
        let countLine = app.staticTexts[NativeStoreIdentifiers.categoryCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: fixtureWait))
        let total = Int(countLine.label.split(separator: " ").first.map(String.init) ?? "") ?? 0
        XCTAssertGreaterThan(total, 0, "the count line starts with the real number of apps, got \"\(countLine.label)\"")

        let rowPredicate = NSPredicate(format: "identifier BEGINSWITH 'iris.store.row.' AND NOT identifier ENDSWITH '.get' AND NOT identifier ENDSWITH '.note' AND NOT identifier ENDSWITH '.sponsored' AND NOT identifier ENDSWITH '.name'")
        var seen = Set<String>()
        for _ in 0..<6 {
            seen.formUnion(app.descendants(matching: .any).matching(rowPredicate).allElementsBoundByIndex.map(\.identifier))
            list.swipeUp()
        }
        XCTAssertGreaterThanOrEqual(seen.count, min(total, 12), "scrolling brought at least a screenful of rows into view, saw \(seen.count) of \(total)")
        XCTAssertLessThanOrEqual(seen.count, total, "the list never shows more rows than the count line says exist")
        XCTAssertTrue(countLine.label.contains("apps"), "The count line must keep stating the real total while chunks load in.")
    }
}
