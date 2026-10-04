// M2-store-layout-implementation: XCUITest source for the Iris Apps store.
// Not compiled by SwiftPM. Part of the IrisMobileShellUITests target (added
// by R2-mobile-integration); runs on the Simulator against M6's in-process
// fixture catalogs (3, 100 and 1,000 apps), never the live network.
//
// Every identifier comes from NativeAccessibilityIdentifiers.swift (values
// copied, since UI tests cannot import the app module). Each test names the
// person it simulates and asserts what that person would see.

import XCTest

final class IrisStoreUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // R2-mobile-integration: M6's fixture seam (never the live network).
        // IRIS_STORE_FIXTURE picks catalog3, catalog100, catalog1000,
        // offline-warm and so on; catalog100 by default.
        app.launchArguments += ["--iris-ui-test-fixtures", ProcessInfo.processInfo.environment["IRIS_STORE_FIXTURE"] ?? "catalog100"]
        app.addFixtureSession()
        app.launch()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func firstRowSlug(prefix: String) -> String? {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '.get' AND NOT identifier ENDSWITH '.note' AND NOT identifier ENDSWITH '.sponsored' AND NOT identifier ENDSWITH '.name'", prefix)).firstMatch
        guard row.waitForExistence(timeout: 10) else { return nil }
        return String(row.identifier.dropFirst(prefix.count))
    }

    // MARK: tabs and shell

    /// P1 opens the app: Browse is first, three tabs, nothing else to learn.
    func testLaunchLandsOnBrowseWithThreeTabs() {
        XCTAssertTrue(element("iris.store.home").waitForExistence(timeout: 10))
        XCTAssertTrue(app.storeTab(.browse).isSelected)
        // D1 (MOBILE_STORE_DESIGN.md): exactly Browse, Search and My apps, by
        // identifier. This replaces `tabBars.buttons.count == 3`: the tab
        // identifiers now sit on each tab's Label leaf (integrator B), so a
        // raw button count no longer says which tabs are there. Each spec'd tab
        // must exist, and nothing else may sit in the tab bar.
        for tab in NativeStoreTab.allCases {
            XCTAssertTrue(app.storeTab(tab).exists, "the \(tab.label) tab must be in the tab bar")
        }
        XCTAssertEqual(NativeStoreTab.allCases.count, 3, "the design allows three tabs and never a fourth")
        XCTAssertTrue(
            app.strayTabBarButtons().isEmpty,
            "unexpected tab bar buttons: \(app.strayTabBarButtons().map { "\($0.identifier)/\($0.label)" })"
        )
        XCTAssertTrue(element("iris.store.home.status").exists, "the status line is always present")
        XCTAssertTrue(element("iris.store.home.search-entry").exists)
    }

    /// P2 switches tabs mid-task and expects to come back to the same page.
    func testSwitchingTabsKeepsThePushedPage() throws {
        let slug = try XCTUnwrap(firstRowSlug(prefix: "iris.store.row.") ?? firstRowSlug(prefix: "iris.store.card."))
        (element("iris.store.row.\(slug)").exists ? element("iris.store.row.\(slug)") : element("iris.store.card.\(slug)")).tap()
        XCTAssertTrue(element("iris.store.app.get").waitForExistence(timeout: 5))
        app.storeTab(.myApps).tap()
        app.storeTab(.browse).tap()
        XCTAssertTrue(element("iris.store.app.get").waitForExistence(timeout: 5), "the app page must still be there")
        app.storeTab(.browse).tap()
        XCTAssertTrue(element("iris.store.home.search-entry").waitForExistence(timeout: 5), "tapping the selected tab returns to its top")
    }

    // MARK: search

    /// P1 taps the big field and types: the keyboard is already up.
    func testSearchEntryOpensSearchWithTheKeyboardUp() {
        element("iris.store.home.search-entry").tap()
        let field = element("iris.marketplace.search")
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "no extra tap on the field")
        XCTAssertTrue(app.storeTab(.search).isSelected)
        field.typeText("a")
        XCTAssertTrue(element("iris.store.search.count").waitForExistence(timeout: 3))
        element("iris.store.search.clear").tap()
        XCTAssertFalse(element("iris.store.search.count").exists, "clearing returns to the idle screen")
    }

    /// Edge user: nonsense gets a plain message and a way forward.
    func testZeroResultsOfferAWayForward() {
        app.storeTab(.search).tap()
        element("iris.marketplace.search").typeText("zzqqxx")
        XCTAssertTrue(element("iris.store.search.zero").waitForExistence(timeout: 3))
        element("iris.store.search.browse-all").tap()
        XCTAssertTrue(element("iris.store.categories").waitForExistence(timeout: 3) || element("iris.store.home").waitForExistence(timeout: 3))
    }

    // MARK: Get

    /// P2 double taps a Browse Get: progress in place, no second screen.
    /// Design 6.2: an unverifiable catalog fixture ends in explained failure.
    // Mutation U2: a second sheet, stuck Get, false Open or duplicate control still fails.
    func testDoubleTapGetShowsProgressThenOpenWithNoSecondScreen() throws {
        let slug = try XCTUnwrap(firstRowSlug(prefix: "iris.store.row.") ?? firstRowSlug(prefix: "iris.store.card."))
        // Keep the tracked method name; generated packages must fail verification, not reach Open.
        // Design 12.2: use the Browse row, whose Get and note share one container.
        // Mutation U2: a missing or untappable row still fails before Get is tapped.
        let item = element(NativeStoreIdentifiers.row(slug))
        XCTAssertTrue(app.scrollUntilExists(item), "the first Browse app's row must be visible and tappable")
        let controls = item.buttons.matching(identifier: NativeStoreIdentifiers.rowGet(slug))
        let get = controls.firstMatch
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(get.value as? String, "Get", "a fresh catalog100 session must start with Get")
        get.doubleTap()
        XCTAssertFalse(element("iris.review.sheet").exists, "one-tap Get must not open the review sheet")
        XCTAssertFalse(element("iris.website.install.sheet").exists, "one-tap Get must not open the install sheet")
        XCTAssertNotEqual(get.value as? String, "Get", "double tapping must move the one control out of Get")
        let failed = NSPredicate(format: "label BEGINSWITH 'Try again' OR value BEGINSWITH 'Failed'")
        let settled = XCTNSPredicateExpectation(predicate: failed, object: get)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: fixtureWait), .completed, "an unverifiable package must settle at Try again or Failed")
        // Mutation U2: a missing or misleading row verification note still fails.
        let note = item.staticTexts.matching(identifier: NativeStoreIdentifiers.rowNote(slug)).firstMatch
        assertVisibleText(note, contains: "The download could not be verified. Nothing was installed.")
        XCTAssertTrue((get.value as? String)?.contains("could not be verified") == true, "design 6.2: the failure note is also the Get accessibility value")
        XCTAssertFalse(element("iris.review.sheet").exists, "failure must stay in place without a review sheet")
        XCTAssertFalse(element("iris.website.install.sheet").exists, "failure must stay in place without an install sheet")
        XCTAssertEqual(controls.count, 1, "still exactly one Get control for this slug in the selected Browse item")
        // Design 6.2: independently inspect the library, not just the failure copy.
        let fixtureIndex = try XCTUnwrap(Int(slug.replacingOccurrences(of: "fixture-app-", with: "")))
        app.storeTab(.myApps).tap()
        // Mutation U2: an unrendered library cannot satisfy the no-install oracle.
        XCTAssertTrue(element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait), "My apps must render before its installed rows are counted")
        XCTAssertTrue(app.storeTab(.myApps).isSelected, "the rendered library must be the selected tab")
        let installedNames = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'iris.store.my-apps.row.' AND label CONTAINS %@",
            NativeStoreFixtureFacts.name(fixtureIndex)))
        XCTAssertEqual(installedNames.count, 0, "failed verification must not create an installed app row")
    }

    /// P3 in airplane mode (set by the main session in the Simulator):
    /// Get writes one line, nothing else happens.
    func testOfflineGetWritesOneLine() throws {
        guard ProcessInfo.processInfo.environment["IRIS_STORE_OFFLINE"] == "1" else { throw XCTSkip("run with the Simulator offline") }
        let slug = try XCTUnwrap(firstRowSlug(prefix: "iris.store.row."))
        element("iris.store.row.\(slug).get").tap()
        XCTAssertTrue(element("iris.store.row.\(slug).note").waitForExistence(timeout: 3))
        XCTAssertTrue((element("iris.store.row.\(slug).get").value as? String)?.contains("Connect to the internet") == true)
    }

    // MARK: app page, block, explainer

    func testAppPageOrderAndBlockAlertButtons() throws {
        let slug = try XCTUnwrap(firstRowSlug(prefix: "iris.store.row.") ?? firstRowSlug(prefix: "iris.store.card."))
        (element("iris.store.row.\(slug)").exists ? element("iris.store.row.\(slug)") : element("iris.store.card.\(slug)")).tap()
        for id in ["iris.store.app.icon", "iris.store.app.name", "iris.store.app.facts", "iris.store.app.get", "iris.store.app.permissions", "iris.store.app.details"] {
            XCTAssertTrue(element(id).waitForExistence(timeout: 5), "\(id) missing")
        }
        XCTAssertLessThan(element("iris.store.app.get").frame.minY, element("iris.store.app.permissions").frame.minY, "Get sits above What it can do")
        // design 6.1 item 2: the facts line reads "<Category> · <size> · <age>+".
        let facts = element("iris.store.app.facts").label
        let parts = facts.components(separatedBy: " · ")
        XCTAssertEqual(parts.count, 3, "design 6.1 item 2: three facts separated by a middle dot, got \"\(facts)\"")
        if parts.count == 3 {
            XCTAssertFalse(parts[0].isEmpty, "the first fact is the category")
            XCTAssertNotNil(parts[1].range(of: #"^\d+(\.\d+)? (bytes|KB|MB|GB)$"#, options: .regularExpression), "the second fact is a size such as 36.8 MB, got \"\(parts[1])\"")
            XCTAssertNotNil(parts[2].range(of: #"^\d+\+$"#, options: .regularExpression), "the third fact is an age such as 13+, got \"\(parts[2])\"")
        }
        let block = element("iris.catalog.review47.block-toggle.\(slug)")
        // Mutation U1: a missing Block alert or a Cancel that blocks the app still fails.
        XCTAssertTrue(block.waitForExistence(timeout: 5), "the app page must offer Block")
        XCTAssertTrue(block.label.hasPrefix("Block"), "a fresh session must not start blocked")
        let blockLabelBefore = block.label
        block.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.alerts.count, 1, "Block asks once")
        app.confirmationButton("Cancel").tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "Cancel must close the Block alert")
        XCTAssertEqual(block.label, blockLabelBefore, "Cancel changes nothing")
    }

    func testHowWePickTheseOpensAndCloses() throws {
        let how = element("iris.store.home.shelf.featured.how")
        guard how.waitForExistence(timeout: 10) else { throw XCTSkip("no Featured shelf in this catalog") }
        how.tap()
        XCTAssertTrue(element("iris.store.how-we-pick.close").waitForExistence(timeout: 3))
        // RC-06 (apple-compliance/REQUIRED_CHANGES.md, decided in DECISIONS.md):
        // the sheet says what is true. Featured is Publik's own pick, a paid
        // shelf slot is marked Sponsored there, and search results are never
        // paid for. The older sentence ("never mixed into search results") is
        // the promise RC-06 replaced.
        let sheetText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Search results are never paid for'")).firstMatch
        XCTAssertTrue(sheetText.waitForExistence(timeout: 3), "RC-06: the sheet says \"Search results are never paid for.\"")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'marked Sponsored'")).firstMatch.exists,
            "RC-06: the sheet says paid shelf slots are marked Sponsored."
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'never mixed into search results'")).firstMatch.exists,
            "RC-06: the old promise that sponsored apps are kept out of search results is gone from the copy."
        )
        element("iris.store.how-we-pick.close").tap()
        XCTAssertFalse(element("iris.store.how-we-pick.close").exists)
    }

    // MARK: VoiceOver contract

    /// Every card and row reads "<name>, <summary>, <action>"; the Get button's
    /// value is its state word plus any note line.
    func testCardsAndButtonsSpeakTheirStateAndAction() throws {
        let slug = try XCTUnwrap(firstRowSlug(prefix: "iris.store.row.") ?? firstRowSlug(prefix: "iris.store.card."))
        let row = element("iris.store.row.\(slug)").exists ? element("iris.store.row.\(slug)") : element("iris.store.card.\(slug)")
        let get = element("iris.store.row.\(slug).get").exists ? element("iris.store.row.\(slug).get") : element("iris.store.card.\(slug).get")
        let words = ["Get", "Open", "Update", "Try again", "Unblock", "Rated ", "Unavailable on this iPhone", "Downloading", "Verifying"]
        XCTAssertTrue(words.contains { row.label.contains($0) }, "row label \(row.label) lacks its action")
        let value = get.value as? String ?? ""
        XCTAssertTrue(["Get", "Open", "Update", "Failed", "Blocked", "Restricted", "Unavailable", "Downloading", "Verifying"].contains { value.hasPrefix($0) }, value)
    }
}
