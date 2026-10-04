import XCTest

// unit m6-mobile-uitests. Covers design section 6 (App page) and the Get
// button state machine (6.2). Persona P2 (hurried, double-taps) drives
// `testSecondTapDuringProgressIsIgnored`; P1 (reads nothing long) drives the
// report/block confirmation checks, since a destructive action under a
// look-alike row is exactly what design decision R2.4 exists to catch.
final class StoreAppPageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openAppPage(_ app: XCUIApplication, slug: String) {
        // All modes used here contain three apps: design 3.2 uses rows.
        let card = app.element(NativeStoreIdentifiers.row(slug))
        XCTAssertTrue(card.waitForExistence(timeout: fixtureWait))
        card.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.app).waitForExistence(timeout: fixtureWait))
    }

    /// RC-05: under the app name, one plain line says who made it. The
    /// generated catalog rows carry no publisher, so the line reads "By Publik".
    func testAppPageNamesThePublisherUnderTheName() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openAppPage(app, slug: NativeStoreFixtureFacts.slug(1))
        let line = app.staticTexts["iris.store.app.publisher"]
        assertVisibleText(line, contains: "By Publik")
        XCTAssertTrue(app.staticTexts[NativeStoreIdentifiers.appName].frame.maxY <= line.frame.minY + 1, "the maker line sits under the name")
    }

    /// design 6.2: tapping Get moves the one button through Downloading and
    /// Verifying, each a distinct visible label, in order. This unit's
    /// generated catalog apps have no real installable package behind them
    /// by design (see `Sources/IrisMobileShellHost/NativeUITestFixtures.swift`
    /// type doc comment and `INTEGRATION_HOOKS.md`'s "Not a hook" section),
    /// so the sequence this test can honestly assert ends at `failed`
    /// ("The download could not be verified. Nothing was installed."), not
    /// `Open`. That failure is itself the correct, designed outcome for an
    /// unverifiable package (SPEC's fail-closed posture) and is exactly what
    /// P3's "download could not be verified" scenario needs covered.
    func testUnverifiableGetLeavesGetAndEndsInAnExplainedFailure() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openAppPage(app, slug: NativeStoreFixtureFacts.slug(1))

        let getButton = app.buttons[NativeStoreIdentifiers.appGet]
        assertVisibleText(getButton, contains: "Get")
        getButton.tap()

        // Downloading and Verifying are each real, distinct states the
        // button's label must show in order; a fixture-speed transport can
        // pass through Downloading in under a frame, so this waits for
        // *either* Downloading or the state after it rather than requiring
        // a specific frame to catch Downloading, which would be a race
        // against this generator's own speed, not against the app.
        let reachedVerifyingOrLater = NSPredicate(format: "label CONTAINS 'Verifying' OR label CONTAINS 'Try again' OR label CONTAINS 'Downloading'")
        let sawProgressState = XCTNSPredicateExpectation(predicate: reachedVerifyingOrLater, object: getButton)
        XCTAssertEqual(XCTWaiter().wait(for: [sawProgressState], timeout: fixtureWait), .completed, "Get must visibly leave its notInstalled label once tapped.")

        let failed = NSPredicate(format: "label CONTAINS 'Try again'")
        let sawFailed = XCTNSPredicateExpectation(predicate: failed, object: getButton)
        XCTAssertEqual(XCTWaiter().wait(for: [sawFailed], timeout: fixtureWait), .completed, "An unverifiable fixture package must end at Try again (failed), never hang on Downloading or Verifying forever.")

        let note = app.staticTexts[NativeStoreIdentifiers.appNote]
        assertVisibleText(note, contains: "could not be verified")
    }

    /// design 6.2 table, `downloading(p)` row and SPEC R8.5: a second tap
    /// while a download is in progress must do nothing but keep showing
    /// progress. P2 double taps Get: the button never falls back to "Get" once
    /// it has left it, there is still exactly one Get button (no second screen,
    /// no dialog), and the run ends in the single designed outcome for an
    /// unverifiable fixture package, "Try again". (Round 6 test audit: the old
    /// body created a wait it never used and asserted a single label read that
    /// a restarted install would also have passed. The count of requests the
    /// server saw is covered where it can be read, in the Core install-button
    /// tests and the fake server's request log.)
    func testDoubleTapOnGetShowsNoSecondScreenAndSettlesOnTryAgain() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openAppPage(app, slug: NativeStoreFixtureFacts.slug(1))

        let getButton = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(getButton.waitForExistence(timeout: fixtureWait))
        getButton.doubleTap()

        XCTAssertNotEqual(getButton.label, "Get", "after a double tap the button has moved on; a second tap must never restart it at Get")
        XCTAssertEqual(app.alerts.count, 0, "a double tap on Get opens no dialog")
        XCTAssertEqual(app.sheets.count, 0, "a double tap on Get opens no second screen (design D7)")

        let failed = NSPredicate(format: "label CONTAINS 'Try again'")
        let settled = XCTNSPredicateExpectation(predicate: failed, object: getButton)
        XCTAssertEqual(XCTWaiter().wait(for: [settled], timeout: fixtureWait), .completed, "one install ran and ended at Try again")
        XCTAssertEqual(app.buttons.matching(identifier: NativeStoreIdentifiers.appGet).count, 1, "still exactly one Get button on the page")
    }

    /// RC-02 and design 6.2 `restricted(age)` row: an app rated above the
    /// shell's own 13+ rating (the fixture's first app is rated 18) shows the
    /// rating on its Get, and tapping it opens the age sheet. Nothing installs.
    /// After answering "18 or older" the plain Get appears. (On iOS 26 and
    /// later the sheet offers Apple's own age request instead of the three
    /// buttons; that path needs a real Apple ID, so this test skips there.)
    func testRestrictedAgeAppOpensTheAgeSheetAndGetAppearsAfterDeclaring() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("restricted")
        openAppPage(app, slug: NativeStoreFixtureFacts.slug(NativeStoreFixtureFacts.restrictedIndex))

        let getButton = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(getButton.waitForExistence(timeout: fixtureWait), "The restricted Get must be a tappable button now (RC-02).")
        XCTAssertEqual(getButton.label, "Rated 18+ · Check your age")
        let note = app.staticTexts[NativeStoreIdentifiers.appNote]
        assertVisibleText(note, contains: "Tell Iris your age range to continue")

        getButton.tap()
        let sheet = app.element("iris.app.age-gate.sheet")
        XCTAssertTrue(sheet.waitForExistence(timeout: fixtureWait), "Tapping Check your age must open the age sheet.")
        if app.buttons["iris.app.age-gate.system-request"].exists {
            throw XCTSkip("iOS 26+: the sheet uses Apple's Declared Age Range request, which needs a signed-in Apple ID.")
        }
        XCTAssertTrue(app.buttons["iris.app.age-gate.declare.13"].exists)
        XCTAssertTrue(app.buttons["iris.app.age-gate.declare.16"].exists)
        XCTAssertTrue(app.buttons["iris.app.age-gate.declare.18"].exists)
        XCTAssertTrue(app.buttons["iris.app.age-gate.decline"].exists, "Not now must always be there.")

        app.buttons["iris.app.age-gate.declare.18"].tap()
        let becameGet = NSPredicate(format: "label BEGINSWITH 'Get'")
        let expectation = XCTNSPredicateExpectation(predicate: becameGet, object: app.buttons[NativeStoreIdentifiers.appGet])
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: fixtureWait), .completed, "After declaring 18 the Get button must appear.")
    }

    /// RC-02: "Not now" leaves the app restricted and installs nothing.
    func testNotNowLeavesTheAppRestricted() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("restricted")
        openAppPage(app, slug: NativeStoreFixtureFacts.slug(NativeStoreFixtureFacts.restrictedIndex))
        let getButton = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(getButton.waitForExistence(timeout: fixtureWait))
        getButton.tap()
        XCTAssertTrue(app.element("iris.app.age-gate.sheet").waitForExistence(timeout: fixtureWait))
        let notNow = app.buttons["iris.app.age-gate.decline"]
        XCTAssertTrue(notNow.exists)
        notNow.tap()
        XCTAssertTrue(app.buttons[NativeStoreIdentifiers.appGet].waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(app.buttons[NativeStoreIdentifiers.appGet].label, "Rated 18+ · Check your age", "Not now must leave the app restricted.")
    }

    /// design 6.1 item 8 and R2.4: Block asks once, with a named alert
    /// (Block / Cancel / Report it instead); Cancel must change nothing
    /// (the app stays in the catalog, not silently hidden).
    func testBlockAsksOnceAndCancelChangesNothing() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let slug = NativeStoreFixtureFacts.slug(0)
        openAppPage(app, slug: slug)

        let blockToggle = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'block-toggle'")).firstMatch
        XCTAssertTrue(blockToggle.waitForExistence(timeout: fixtureWait))
        blockToggle.tap()

        // Mutation U3: no alert, a missing action or Cancel blocking the app still fails.
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: fixtureWait), "Block must show a system alert")
        XCTAssertEqual(app.alerts.count, 1, "Block asks once")
        let confirm = app.confirmationButton(NativeStoreIdentifiers.appBlockConfirm)
        let cancel = app.confirmationButton(NativeStoreIdentifiers.appBlockCancel)
        let report = app.confirmationButton(NativeStoreIdentifiers.appBlockReport)
        XCTAssertTrue(confirm.waitForExistence(timeout: fixtureWait), "Block must ask with a real alert, not act immediately (design R2.4).")
        XCTAssertTrue(cancel.exists)
        XCTAssertTrue(report.exists, "The alert must also offer \"Report it instead\" (design 6.1 item 8).")

        cancel.tap()
        XCTAssertFalse(confirm.exists, "The alert must close on Cancel.")
        // Still on the app page, and it is not marked Blocked: the visible
        // proof Cancel changed nothing.
        XCTAssertTrue(app.element(NativeStoreIdentifiers.app).exists)
        let blockedText = app.staticTexts["Blocked on this iPhone"]
        XCTAssertFalse(blockedText.exists, "Cancel must never leave the app looking blocked.")
    }

    /// design 6.1 item 8: after confirming Block, the row's text changes to
    /// "Blocked on this iPhone" with an Unblock control, and the Get slot
    /// shows the restriction note - a real, visible state flip, not just an
    /// internal flag.
    // Mutation U4: a confirmation that does not block, or an Unblock that asks, still fails.
    func testConfirmingBlockFlipsRowToBlockedWithUnblock() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let slug = NativeStoreFixtureFacts.slug(0)
        openAppPage(app, slug: slug)

        let blockToggle = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'block-toggle'")).firstMatch
        XCTAssertTrue(blockToggle.waitForExistence(timeout: fixtureWait))
        blockToggle.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: fixtureWait), "Block must show a system alert")
        let confirm = app.confirmationButton(NativeStoreIdentifiers.appBlockConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: fixtureWait))
        confirm.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "confirming Block must close the alert")

        assertVisibleText(blockToggle, contains: "Blocked")
        let note = app.staticTexts[NativeStoreIdentifiers.appNote]
        assertVisibleText(note, contains: "blocked")

        // Unblock never asks (design 6.1 item 8). Undo it so the block does not
        // outlive this test on the Simulator.
        blockToggle.tap()
        XCTAssertFalse(app.confirmationButton(NativeStoreIdentifiers.appBlockConfirm).exists, "design 6.1 item 8: Unblock never asks.")
        XCTAssertFalse(app.staticTexts["Blocked on this iPhone"].waitForExistence(timeout: 2), "after Unblock the page no longer says Blocked.")
    }

    /// design 15 and 6.1 item 8, one person's whole journey. She blocks an app
    /// from its page: it disappears from Browse, it is still findable under My
    /// apps, "Blocked apps (1)", and Unblock there brings it back to Browse. A
    /// blocked app is never lost (design decision 7 in section 17).
    // Mutation U5: leaving a blocked app in Browse or losing its Unblock path still fails.
    func testBlockedAppLeavesBrowseIsFoundUnderBlockedAppsAndComesBackOnUnblock() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let slug = NativeStoreFixtureFacts.slug(0)
        openAppPage(app, slug: slug)

        let blockToggle = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'block-toggle'")).firstMatch
        XCTAssertTrue(blockToggle.waitForExistence(timeout: fixtureWait))
        blockToggle.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: fixtureWait), "Block must show a system alert")
        let confirm = app.confirmationButton(NativeStoreIdentifiers.appBlockConfirm)
        XCTAssertTrue(confirm.waitForExistence(timeout: fixtureWait))
        confirm.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists, "confirming Block must close the alert")

        // Gone from Browse (design 15: "hidden from Home, Search and category pages").
        app.storeTab(.browse).tap()
        if !app.element(NativeStoreIdentifiers.homeAllApps).waitForExistence(timeout: 2) { app.storeTab(.browse).tap() }
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeAllApps).waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(
            app.element(NativeStoreIdentifiers.row(slug)).waitForNonExistence(timeout: fixtureWait),
            "design 15: a blocked app is absent from Browse."
        )
        XCTAssertTrue(app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(1))).exists, "only the blocked app leaves the list.")

        // Findable under My apps > Blocked apps (1).
        app.storeTab(.myApps).tap()
        let blockedLine = app.element(NativeStoreIdentifiers.myAppsBlockedLine)
        XCTAssertTrue(blockedLine.waitForExistence(timeout: fixtureWait), "design 7 item 4: a \"Blocked apps (N)\" line shows when N is 1 or more.")
        XCTAssertTrue(blockedLine.label.contains("Blocked apps (1)"), "the line counts the one blocked app, got \"\(blockedLine.label)\".")
        blockedLine.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.blocked).waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(app.element(NativeStoreIdentifiers.blockedRow(slug)).waitForExistence(timeout: fixtureWait), "the blocked app is listed by name.")

        // Unblock never asks, and the app returns to Browse.
        let unblock = app.buttons[NativeStoreIdentifiers.blockedRowUnblock(slug)]
        XCTAssertTrue(unblock.waitForExistence(timeout: fixtureWait))
        unblock.tap()
        XCTAssertFalse(app.confirmationButton(NativeStoreIdentifiers.appBlockConfirm).exists, "design 6.1 item 8: Unblock never asks.")
        app.storeTab(.browse).tap()
        XCTAssertTrue(
            app.element(NativeStoreIdentifiers.row(slug)).waitForExistence(timeout: fixtureWait),
            "after Unblock the app is back in Browse."
        )
    }

    /// design 6.1 item 8 as changed by apple-compliance OD-06 (decided in
    /// DECISIONS.md): the Report row promises only what Publik can keep. It says
    /// "Publik reads every report", and it does not promise a reply time such as
    /// "5 business days" unless someone owns the mailbox (still an open owner
    /// item). The design file's older wording is the one OD-06 replaces.
    func testReportRowSaysPublikReadsEveryReportAndPromisesNoReplyTime() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let slug = NativeStoreFixtureFacts.slug(0)
        openAppPage(app, slug: slug)

        let report = app.element("iris.catalog.review47.report.\(slug)")
        for _ in 0..<8 where !report.exists { app.swipeUp() }
        XCTAssertTrue(report.waitForExistence(timeout: fixtureWait), "design 6.1 item 8: the app page has a Report this app row.")
        var readable = [report.label]
        readable.append(contentsOf: report.staticTexts.allElementsBoundByIndex.map(\.label))
        let text = readable.joined(separator: " | ")
        XCTAssertTrue(text.contains("Publik reads every report"), "OD-06: the row says Publik reads every report, got \"\(text)\"")
        XCTAssertFalse(text.lowercased().contains("business days"), "OD-06: no reply time is promised, got \"\(text)\"")
    }
}
