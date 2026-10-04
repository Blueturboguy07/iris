import XCTest

// unit m6-mobile-uitests. Covers design section 7 (My apps) and 7.1
// (Versions). Every fixture mode except `offline-cold` seeds the three real
// bundled Starter apps (Kneecap `publik.kneecap`, Nut AI `publik.nut-ai`,
// FreeHarmony `publik.freeharmony`) into the library via
// `NativeUITestFixtures.seed` -> `NativeStarterInstaller`, the same,
// genuinely valid packages a normal first launch installs - so these tests
// exercise the real install/activate/pin pipeline, not a mock.
final class MyAppsUITests: XCTestCase {
    static let kneecapAppId = "publik.kneecap"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openMyApps(_ app: XCUIApplication, revealKneecap: Bool = true) {
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
        if revealKneecap {
            XCTAssertTrue(app.scrollUntilExists(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))),
                          "organization SPEC 1.1: reveal the app below saved folders")
        }
    }

    /// design section 7 item 3: an installed app's row shows its real name
    /// and an Open control, and tapping Open actually opens it full screen
    /// (design section 9.1: "The running app" full-screen cover, tab bar
    /// hidden) - a real screen change, not just the row existing.
    func testOpenLaunchesTheAppFullScreen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)

        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        // Mutation: a row naming another app still fails; installed-name casing is not prescribed (organization SPEC 1.3).
        assertVisibleText(row, containsIgnoringCase: "Kneecap")

        let open = app.buttons[NativeStoreIdentifiers.open(Self.kneecapAppId)]
        XCTAssertTrue(open.waitForExistence(timeout: fixtureWait))
        open.tap()

        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar must be hidden while the running app covers the screen (design 9.1).")
    }

    /// mobile-versions SPEC 1.1 (round3/mobile-versions/SPEC.md, which turns
    /// design 7.1's Versions screen into the Features page): the page for an
    /// installed app is titled "<name> features", always carries the one
    /// sentence that says what Iris keeps and that data is separate, and marks
    /// the version that is running with the words "On this iPhone now".
    /// Round 6 test audit: this test used to look for the word "Current" and
    /// the sentence "Switching versions", both from design 7.1, which SPEC 1.1
    /// replaces ("its kept identifiers stay valid", its words do not).
    func testFeaturesPageNamesTheAppExplainsWhatIsKeptAndMarksTheRunningVersion() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)

        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
        // Mutation: another app name still fails even if its row and Features title agree.
        assertVisibleText(row, containsIgnoringCase: "Kneecap")
        // Organization SPEC 1.3: capture the row before navigation; names may contain commas.
        let installedRowLabel = row.label
        row.tap() // installed-app page

        let versionsRow = app.element(NativeStoreIdentifiers.appVersionsRow)
        XCTAssertTrue(versionsRow.waitForExistence(timeout: fixtureWait))
        versionsRow.tap()

        let versionsScreen = app.element(NativeStoreIdentifiers.versions)
        XCTAssertTrue(versionsScreen.waitForExistence(timeout: fixtureWait))
        // Mutation: a wrong app title or changed installed-name casing still fails the exact row prefix (SPEC 1.1).
        let title = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ENDSWITH %@", " features")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: fixtureWait), "SPEC 1.1: the page is titled \"<name> features\".")
        let displayName = String(title.label.dropLast(" features".count))
        XCTAssertFalse(displayName.isEmpty, "SPEC 1.1: the Features title names the installed app")
        XCTAssertTrue(installedRowLabel == displayName || installedRowLabel.hasPrefix(displayName + ", "),
                      "Organization SPEC 1.3: the complete Features name must exactly prefix the installed row, including any commas; row=\(installedRowLabel), title=\(title.label)")
        let explanation = app.staticTexts[NativeStoreIdentifiers.versionsExplanation]
        assertVisibleText(explanation, contains: "Iris keeps the version on your iPhone and the one before it")
        assertVisibleText(explanation, contains: "Your data is separate and is never changed by any of this")

        let runningRow = app.staticTexts["On this iPhone now"]
        XCTAssertTrue(runningRow.waitForExistence(timeout: fixtureWait), "SPEC 1.1: the version that is running says \"On this iPhone now\" in words.")
    }

    /// design section 7.1 and 12.6 (`iris.storage.pin.<rev>` /
    /// `.unpin.<rev>`): pinning a revision must flip that one row's own
    /// label from Pin to Unpin and add the "Pinned: kept until you unpin
    /// it" words (never color only) - checked on the specific row, not
    /// merely "a pin control exists somewhere."
    func testPinTogglesToUnpinWithPinnedWordsOnThatRow() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full") // every revision installed, so a non-current row exists to pin
        openMyApps(app)

        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
        row.tap()
        let versionsRow = app.element(NativeStoreIdentifiers.appVersionsRow)
        XCTAssertTrue(versionsRow.waitForExistence(timeout: fixtureWait))
        versionsRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait))

        let pinButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.storage.pin.")).firstMatch
        XCTAssertTrue(pinButton.waitForExistence(timeout: fixtureWait), "A non-current revision must exist to pin once every Starter revision is installed.")
        pinButton.tap()

        let pinnedId = String(pinButton.identifier.dropFirst("iris.storage.pin.".count))
        let unpinButton = app.buttons[NativeStoreIdentifiers.unpin(pinnedId)]
        XCTAssertTrue(unpinButton.waitForExistence(timeout: fixtureWait), "Pin must flip the same row to Unpin, not add a second control.")
        let pinnedWords = app.staticTexts["Pinned: kept until you unpin it"]
        XCTAssertTrue(pinnedWords.waitForExistence(timeout: fixtureWait), "Pinned state must be stated in words, never color only (design section 9.4 Increase Contrast rule generalized).")
    }

    /// design section 7 item 6: My apps' tab badge is the count of apps
    /// with an update available. `storage-full` mode installs every Starter
    /// app at its final revision (no update pending, badge absent);
    /// `catalog3` seeds only the final revision too by default in this
    /// unit's fixture, so this test's actual, checkable claim is the
    /// negative: with nothing outdated, the badge must not exist (never a
    /// stale "0" badge sitting on screen).
    func testNoUpdatesMeansNoBadgeOnTheMyAppsTab() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)

        let badge = app.element(NativeStoreIdentifiers.tabMyAppsBadge)
        XCTAssertFalse(badge.exists, "With nothing outdated, the My apps badge must not render at all, not render as 0.")
    }

    /// design section 7 item 5: with the library empty (`offline-cold`,
    /// which this unit's seeding deliberately leaves with no installed
    /// apps), My apps shows the "Make this space yours" empty state with a
    /// Browse apps action that actually switches tabs.
    func testEmptyLibraryShowsMakeThisSpaceYoursWithBrowseAction() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("offline-cold")
        openMyApps(app, revealKneecap: false)

        let empty = app.element(NativeStoreIdentifiers.myAppsEmpty)
        XCTAssertTrue(empty.waitForExistence(timeout: fixtureWait))
        let browse = app.buttons[NativeStoreIdentifiers.myAppsEmptyBrowse]
        XCTAssertTrue(browse.waitForExistence(timeout: fixtureWait))
        browse.tap()

        XCTAssertTrue(app.element(NativeStoreIdentifiers.home).waitForExistence(timeout: fixtureWait), "Browse apps from the empty state must actually land on Browse.")
    }

    /// R2-mobile-integration, click-path R2-CP-4, kept on the page the spec now
    /// puts it on (mobile-versions SPEC 1.1: trailing controls are 44 pt
    /// borderless buttons so one tap fires one button). Edge user: pins an
    /// older version to keep it. That must pin it and nothing else: the app
    /// must not switch to that version. storage-full installs Kneecap's whole
    /// chain, so an older version with a Go back button exists. (Round 6 test
    /// audit: the old body went through the retired "Versions and details"
    /// list; the path below is store design 6.1 item 10 and SPEC 1.1.)
    func testPinningAnOlderVersionPinsItAndNeverRevertsTheApp() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openMyApps(app)
        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
        row.tap()
        let versionsRow = app.element(NativeStoreIdentifiers.appVersionsRow)
        XCTAssertTrue(versionsRow.waitForExistence(timeout: fixtureWait))
        versionsRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait))

        let revert = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.revert.'")).firstMatch
        XCTAssertTrue(revert.waitForExistence(timeout: fixtureWait), "storage-full must leave an older Kneecap version to go back to")
        let olderId = String(revert.identifier.dropFirst("iris.revert.".count))
        let pin = app.buttons["iris.storage.pin.\(olderId)"]
        XCTAssertTrue(pin.waitForExistence(timeout: fixtureWait))
        pin.tap()

        XCTAssertTrue(app.buttons["iris.storage.unpin.\(olderId)"].waitForExistence(timeout: fixtureWait), "the older version shows as pinned")
        XCTAssertTrue(app.buttons["iris.revert.\(olderId)"].exists, "the older version is still the one you could go back to, so the app did not switch to it")
        XCTAssertEqual(app.alerts.count, 0, "pinning asks nothing and starts nothing else (SPEC 1.2: only Go back asks \"Go back to...?\")")
    }

    /// mobile-versions SPEC 1.2, "Go back" row: tapping Go back on an earlier
    /// version asks first ("Go back to "<title>"?" with an explanation that
    /// nothing is deleted and data stays), Keep it changes nothing, Go back
    /// switches, the status block says "Went back to..." with Undo, and Undo
    /// puts it back. Round 6 test author: added because the Features page had
    /// only pin coverage. The journey ends where it started so it cannot leave
    /// the fixture library on an older version.
    func testGoBackAsksFirstKeepItChangesNothingGoBackThenUndoRestores() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openMyApps(app)
        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
        row.tap()
        let versionsRow = app.element(NativeStoreIdentifiers.appVersionsRow)
        XCTAssertTrue(versionsRow.waitForExistence(timeout: fixtureWait))
        versionsRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait))

        let goBack = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.revert.'")).firstMatch
        XCTAssertTrue(goBack.waitForExistence(timeout: fixtureWait), "storage-full leaves an earlier Kneecap version on the phone")

        // Ask, then say no.
        goBack.tap()
        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Go back to'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: fixtureWait), "SPEC 1.2: Go back asks \"Go back to ...?\" before doing anything")
        let explanation = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'switched off, not deleted'")).firstMatch
        XCTAssertTrue(explanation.exists, "SPEC 1.2: the question says nothing is deleted")
        // Mutation: switching without the question still fails before either answer (versions SPEC 1.2).
        let keepIt = app.confirmationButton("iris.store.versions.go-back.cancel")
        XCTAssertTrue(keepIt.exists, "SPEC 1.2: the safe answer is \"Keep it\"")
        keepIt.tap()
        XCTAssertFalse(app.confirmationButton("iris.store.versions.go-back.confirm").exists, "the question closes on Keep it")
        XCTAssertTrue(app.staticTexts["On this iPhone now"].exists, "Keep it changes nothing")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Went back to'")).firstMatch.exists)

        // Ask, then say yes.
        goBack.tap()
        let confirm = app.confirmationButton("iris.store.versions.go-back.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: fixtureWait))
        confirm.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Went back to'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: fixtureWait), "SPEC 1.2: the done sentence is \"Went back to ...\"")
        let undo = app.buttons["iris.store.versions.undo"]
        XCTAssertTrue(undo.exists, "SPEC 1.2: Undo is offered after going back")

        // Undo puts it back.
        undo.tap()
        let undone = app.staticTexts["Undone."]
        XCTAssertTrue(undone.waitForExistence(timeout: fixtureWait), "SPEC 1.2: Undo ends with \"Undone.\"")
    }
}
