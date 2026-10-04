import XCTest

// Unit MA2 my-apps-screen (MA6 folded in per this unit's brief). Covers
// `docs/plans/20260928-all-routes/round3/my-apps-organization/SPEC.md`
// section 5.6's list: every button, click-away and keyboard path the My
// apps organization screen (folders, rename, search, select mode) adds on
// top of M-store-screens' own `MyAppsUITests.swift`, which this file does
// not duplicate.
//
// Fixture note (written honestly, following `NativeUITestFixtureSupport.swift`'s
// own precedent for tests written ahead of their support infra): the tests
// below that only need 3 installed apps use the existing `catalog3` fixture
// mode (`NativeUITestFixtures.seed`, already seeds the real Kneecap, Nut AI
// and FreeHarmony Starter packages), which is enough to exercise every
// folder/rename/move/select-mode button because SPEC 1.4's folder actions
// are not gated by installed-app count. The tests marked "SCALE FIXTURE"
// need SPEC 5.6's `--iris-ui-test-my-apps <n>` launch argument. Round 6
// (R6-mobile-prep-B) built it: `NativeMyAppsUITestFixtures` (Host, DEBUG only) and
// `MyAppsUITestSeed` (Core, DEBUG only) install n real apps into an isolated
// library, plus three folders (one empty) and two renamed apps, and turn the
// network off. It needs the two-line-plus hook in `IrisMobileShellApp.swift`
// (round6/mobile-prep/HOOKS.md, hook H1); until that hook is applied these
// tests fail with "no such element" or a timeout, and only these.
final class MyAppsOrganizationUITests: XCTestCase {
    static let kneecapAppId = "publik.kneecap"
    static let nutAiAppId = "publik.nut-ai"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openMyApps(_ app: XCUIApplication) {
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
    }

    private func longPress(_ element: XCUIElement) {
        XCTAssertTrue(XCUIApplication().scrollUntilExists(element), "organization SPEC 1.1: reveal the recycled row before opening its menu")
        element.press(forDuration: 0.6)
    }

    // MARK: - Search field (SPEC 1.1 item 2)

    /// SPEC 5.6: "Search field: absent at 3 apps."
    func testSearchFieldAbsentAtThreeApps() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        XCTAssertFalse(app.textFields["iris.store.my-apps.search"].exists, "The search field must not render below SPEC 1.1's 12-app threshold.")
    }

    // MARK: - Long-press menu (SPEC 1.2)

    /// SPEC 5.6: "Long press on a row: every item in 1.2 exists exactly when
    /// 1.2 says it should" -- Rename, Move to folder, Features and About
    /// this app always apply; Take out of only applies once the app is in a
    /// folder (checked by the separate move test below); Share link applies
    /// because Kneecap has a known catalog slug.
    func testLongPressMenuShowsAlwaysAvailableItems() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)

        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        longPress(row)

        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(app.buttons["Move to folder"].exists)
        XCTAssertTrue(app.buttons["Features"].exists)
        XCTAssertTrue(app.buttons["About this app"].exists)
        XCTAssertFalse(app.buttons["Take out of folder"].exists, "Not in a folder yet, so Take out of must not show.")
        // SPEC 1.2 (row "Remove from this iPhone"): shown once MV2's remove API
        // exists, hidden before that (decision 12). The API exists since round 6
        // (RC-04 "Also delete my data really deletes"), so the item is there.
        // Round 6 test audit: this line used to assert the item was absent.
        XCTAssertTrue(app.buttons["Remove from this iPhone"].exists, "SPEC 1.2 and decision 12: Remove is in the menu now that the remove API exists.")
    }

    // MARK: - Remove app (SPEC 1.2 "Remove from this iPhone", mobile-versions SPEC 1.2 "Remove app")

    /// A person removes one of their 14 apps. The question names the app, says
    /// their data stays unless they also delete it, and has the data toggle OFF
    /// by default (mobile-versions SPEC 1.2, owner decision 2026-09-28). Keep
    /// it changes nothing; Remove takes the row out of My apps.
    /// Uses `--iris-ui-test-my-apps 14` so the removed app belongs to a library
    /// no other test reads (each count has its own isolated library).
    func testRemoveAsksNamesTheAppKeepsDataByDefaultAndKeepItChangesNothing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--iris-ui-test-my-apps", "14"]
        app.addFixtureSession()
        app.launch()
        openMyApps(app)
        let victimId = "fixture.myapps-14"
        let row = findRowThroughSearch(app, appId: victimId, query: "Fixture App 14")

        longPress(row)
        let remove = app.buttons["Remove from this iPhone"]
        XCTAssertTrue(remove.waitForExistence(timeout: fixtureWait), "SPEC 1.2: Remove is in the long-press menu.")
        remove.tap()

        let question = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Remove Fixture App 14 from this iPhone'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: fixtureWait), "mobile-versions SPEC 1.2: the question is \"Remove <name> from this iPhone?\"")
        let toggle = app.descendants(matching: .any)["iris.store.my-apps.remove.delete-data"]
        XCTAssertTrue(toggle.waitForExistence(timeout: fixtureWait), "SPEC 1.2: an \"Also delete my data\" toggle is on the question.")
        XCTAssertEqual(toggle.value as? String, "0", "SPEC 1.2: the data toggle is off by default, so removing an app never deletes data by accident.")

        app.buttons["iris.store.my-apps.remove.keep"].tap()
        XCTAssertFalse(app.buttons["iris.store.my-apps.remove.confirm"].exists, "the question closes on Keep it")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myAppsRow(victimId)).exists, "Keep it removes nothing.")

        longPress(app.element(NativeStoreIdentifiers.myAppsRow(victimId)))
        app.buttons["Remove from this iPhone"].tap()
        let confirm = app.buttons["iris.store.my-apps.remove.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: fixtureWait))
        confirm.tap()
        XCTAssertTrue(
            app.element(NativeStoreIdentifiers.myAppsRow(victimId)).waitForNonExistence(timeout: fixtureWait * 2),
            "Removing takes the app out of My apps."
        )
    }

    // MARK: - Rename (SPEC 1.3)

    /// SPEC 5.6: "Rename: Save disabled when empty; 31 characters rejected
    /// with the limit line; Save changes the row label; ... the new name
    /// survives relaunch."
    func testRenameSaveDisabledWhenEmptyAndLimitLineAt31Characters() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)))
        app.buttons["Rename"].tap()

        let field = app.textFields["iris.store.my-apps.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        let save = app.buttons["iris.store.my-apps.rename.save"]

        field.tap()
        field.clearAndTypeText("")
        XCTAssertFalse(save.isEnabled, "Save must be disabled while the field is empty.")

        field.typeText(String(repeating: "a", count: 31))
        assertVisibleText(app.staticTexts["iris.store.my-apps.rename.limit"], contains: "up to 30 characters")
    }

    func testRenameChangesRowLabelAndSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)))
        app.buttons["Rename"].tap()

        let field = app.textFields["iris.store.my-apps.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.clearAndTypeText("Clips")
        app.buttons["iris.store.my-apps.rename.save"].tap()

        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        assertVisibleText(row, contains: "Clips")

        app.terminate()
        // The same instance keeps its session token; a lost saved rename must still fail below.
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        assertVisibleText(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)), contains: "Clips")
    }

    /// SPEC 1.3: "Use original name" restores the original name.
    func testUseOriginalNameRestoresIt() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        let row = app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId))
        assertVisibleText(row, containsIgnoringCase: "Kneecap")
        let originalName = row.label
        longPress(row)
        app.buttons["Rename"].tap()
        let field = app.textFields["iris.store.my-apps.rename.field"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        field.clearAndTypeText("Clips")
        app.buttons["iris.store.my-apps.rename.save"].tap()
        assertVisibleText(row, contains: "Clips")

        longPress(row)
        app.buttons["Rename"].tap()
        let originalButton = app.buttons["iris.store.my-apps.rename.original"]
        XCTAssertTrue(originalButton.waitForExistence(timeout: fixtureWait), "Once renamed, 'Use original name' must appear.")
        originalButton.tap()

        assertVisibleText(row, containsIgnoringCase: "Kneecap")
        // Mutation: keeping Clips or restoring a different spelling fails this exact comparison.
        XCTAssertEqual(row.label, originalName, "Use original name must restore the current version's exact name.")
    }

    // MARK: - Move to folder / new folder (SPEC 1.4)

    /// SPEC 5.6: "New folder from the Move sheet: the name field is
    /// prefilled with the group name; Save creates the folder with the app
    /// in it." "Move to folder: the row appears under the folder header and
    /// disappears from its group ... Take out of returns it."
    func testNewFolderFromMoveSheetPlacesTheAppInIt() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)))
        app.buttons["Move to folder"].tap()

        let moveSheet = app.element("iris.store.my-apps.move")
        XCTAssertTrue(moveSheet.waitForExistence(timeout: fixtureWait))
        app.buttons["iris.store.my-apps.move.new"].tap()

        let nameField = app.textFields["iris.store.my-apps.folder-name.field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: fixtureWait))
        let createdName = "Editing " + UUID().uuidString.prefix(8)
        nameField.clearAndTypeText(createdName)
        app.buttons["iris.store.my-apps.folder-name.save"].tap()

        let folderHeader = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.my-apps.folder.' AND identifier ENDSWITH '.header' AND label BEGINSWITH %@", createdName)).firstMatch
        XCTAssertTrue(app.scrollUntilExists(folderHeader), "the new folder must be revealed")
        assertVisibleText(folderHeader, contains: createdName)

        // The row is now reached through the folder, and the menu offers
        // "Take out of" once it is in one.
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.my-apps.menu.' AND identifier ENDSWITH '.take-out'")).firstMatch.waitForExistence(timeout: fixtureWait))
    }

    // MARK: - Folder menu: rename, delete (SPEC 1.4)

    func testFolderMenuRenameChangesHeaderAndDeleteShowsConfirmation() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        let createdHeader = makeFolder(app, named: "Editing", forRow: Self.kneecapAppId)
        let folderPrefix = String(createdHeader.identifier.dropLast(".header".count))
        // Mutation: a stale header after rename or a retained header after delete must still fail.
        let header = app.buttons[folderPrefix + ".header"]
        let folderMenuButton = app.buttons[folderPrefix + ".menu"]
        XCTAssertTrue(folderMenuButton.waitForExistence(timeout: fixtureWait))
        folderMenuButton.tap()
        let menuRename = app.buttons.matching(NSPredicate(format: "label == %@ AND isHittable == true", "Rename folder")).firstMatch
        XCTAssertTrue(menuRename.waitForExistence(timeout: fixtureWait))
        menuRename.tap()
        let nameField = app.textFields["iris.store.my-apps.folder-name.field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: fixtureWait))
        nameField.clearAndTypeText("Clipping")
        app.buttons["iris.store.my-apps.folder-name.save"].tap()

        assertVisibleText(header, contains: "Clipping")

        folderMenuButton.tap()
        // The open menu is hittable; the underlying empty-folder delete controls are not.
        let menuDelete = app.buttons.matching(NSPredicate(format: "label == %@ AND isHittable == true", "Delete folder")).firstMatch
        XCTAssertTrue(menuDelete.waitForExistence(timeout: fixtureWait))
        menuDelete.tap()
        // Mutation: deleting without asking still fails the alert assertion.
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: fixtureWait), "Deleting a folder asks for confirmation (SPEC 1.4).")
        app.confirmationButton("iris.store.my-apps.folder-delete.cancel").tap()
        assertVisibleText(header, contains: "Clipping")

        folderMenuButton.tap()
        menuDelete.tap()
        app.confirmationButton("iris.store.my-apps.folder-delete.confirm").tap()
        XCTAssertFalse(
            header.exists,
            "Deleting this folder removes its header; other saved folders stay."
        )
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)).waitForExistence(timeout: fixtureWait), "Deleting a folder never removes an app.")
    }

    // MARK: - Select mode (SPEC 1.4)

    /// SPEC 5.6: "Select shows checkboxes and '0 selected'; two taps show
    /// '2 selected'; Move to folder moves both; Done leaves the mode;
    /// tapping a row in Select mode never opens the app or its page."
    func testSelectModeCountsSelectionsAndNeverOpensARow() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)

        app.buttons["iris.store.my-apps.select"].tap()
        assertVisibleText(app.staticTexts["iris.store.my-apps.select.count"], contains: "0 selected")

        for identity in [Self.kneecapAppId, Self.nutAiAppId] {
            let checkbox = app.buttons["iris.store.my-apps.select.row.\(identity)"]
            XCTAssertTrue(app.scrollUntilExists(checkbox))
            checkbox.tap()
        }
        assertVisibleText(app.staticTexts["iris.store.my-apps.select.count"], contains: "2 selected")

        // The row itself must not open the app or its page while selecting:
        // the tab bar must still be hittable (a full-screen app launch hides it).
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "Tapping a checkbox must not open the full-screen app.")

        app.buttons["iris.store.my-apps.select.done"].tap()
        XCTAssertFalse(app.staticTexts["iris.store.my-apps.select.count"].exists, "Done must leave Select mode.")
    }

    // MARK: - Collapse (SPEC 1.1 item 6)

    func testTappingFolderHeaderCollapsesAndExpandsIt() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        let header = makeFolder(app, named: "Editing", forRow: Self.kneecapAppId)
        XCTAssertTrue(header.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)).exists)
        header.tap()
        XCTAssertFalse(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)).exists, "Collapsing a folder must hide its rows.")
        header.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)).waitForExistence(timeout: fixtureWait), "Expanding must bring the row back.")
    }

    // MARK: - Empty folder (SPEC 1.1 item 5)

    func testEmptyFolderShowsTheEmptyLineAndDeleteFolder() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openMyApps(app)
        makeFolder(app, named: "Editing", forRow: Self.kneecapAppId)

        // Take the one app back out, leaving the folder empty.
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)))
        let takeOut = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.my-apps.menu.' AND identifier ENDSWITH '.take-out'")).firstMatch
        XCTAssertTrue(takeOut.waitForExistence(timeout: fixtureWait))
        takeOut.tap()

        let emptyLine = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.my-apps.folder.' AND identifier ENDSWITH '.empty'")).firstMatch
        XCTAssertTrue(emptyLine.waitForExistence(timeout: fixtureWait), "An emptied folder must show SPEC 1.1's empty-folder line and a Delete folder button, never disappear on its own.")
    }

    // MARK: - Rotation (SPEC 5.6, design 9.2)

    func testSameIdentifiersInLandscape() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        XCUIDevice.shared.orientation = .landscapeLeft
        openMyApps(app)
        // Mutation: a missing or wrong app name still fails; installed-name casing is not fixed by SPEC 1.3.
        assertVisibleText(app.element(NativeStoreIdentifiers.myAppsRow(Self.kneecapAppId)), containsIgnoringCase: "Kneecap")
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Scale fixtures (SPEC 5.6; `--iris-ui-test-my-apps <n>`, built in
    // round 6 -- see the file header comment and round6/mobile-prep/HOOKS.md H1)

    /// SPEC 5.6: "Search field: ... present at 12" and the count line shows
    /// a real number for a real match.
    func testSearchFieldPresentAndCountsMatchesAtTwelveApps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--iris-ui-test-my-apps", "12"]
        app.addFixtureSession()
        app.launch()
        openMyApps(app)
        let field = app.textFields["iris.store.my-apps.search"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait), "Needs the --iris-ui-test-my-apps launch hook (round6/mobile-prep/HOOKS.md H1).")
        field.tap()
        field.typeText("cl")
        assertVisibleText(app.staticTexts["iris.store.my-apps.search.count"], contains: "of your apps match")
    }

    /// SPEC 5.6: "Scale: at 1,000 apps My apps appears within the wait
    /// budget (`XCTClockMetric` measured and recorded, the number reported);
    /// scrolling to the last group produces no hang."
    /// Round 6 test audit: the measured block used to discard the result of
    /// `waitForExistence`, so the test passed even when My apps never showed.
    /// It now fails when My apps does not appear inside the wait budget, and it
    /// scrolls to the bottom and checks the screen still answers.
    func testOpensWithinBudgetAtOneThousandApps() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--iris-ui-test-my-apps", "1000"]
        // No session here: repeated measured launches reuse the 1,000-app seed instead of reseeding it.
        let metric = XCTClockMetric()
        measure(metrics: [metric]) {
            app.launch()
            app.storeTab(.myApps).tap()
            XCTAssertTrue(
                app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait),
                "SPEC 5.6: My apps must appear within the wait budget at 1,000 apps."
            )
            app.terminate()
        }

        app.launch()
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
        let list = app.element(NativeStoreIdentifiers.myAppsList)
        XCTAssertTrue(list.waitForExistence(timeout: fixtureWait))
        for _ in 0..<12 { list.swipeUp(velocity: .fast) }
        XCTAssertTrue(app.tabBars.firstMatch.isHittable, "SPEC 5.6: scrolling a 1,000 app library does not hang the screen.")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).exists)
    }

    // MARK: - Helpers

    /// At 12 or more apps My apps has a search field (SPEC 1.1 item 2), which
    /// is how a person finds one app among many without scrolling.
    private func findRowThroughSearch(_ app: XCUIApplication, appId: String, query: String) -> XCUIElement {
        let field = app.textFields["iris.store.my-apps.search"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait), "SPEC 1.1: the search field shows at 12 or more apps.")
        field.tap()
        field.typeText(query)
        let row = app.element(NativeStoreIdentifiers.myAppsRow(appId))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait), "\(query) must be found by search.")
        return row
    }

    @discardableResult
    private func makeFolder(_ app: XCUIApplication, named name: String, forRow appId: String) -> XCUIElement {
        longPress(app.element(NativeStoreIdentifiers.myAppsRow(appId)))
        app.buttons["Move to folder"].tap()
        XCTAssertTrue(app.element("iris.store.my-apps.move").waitForExistence(timeout: fixtureWait))
        app.buttons["iris.store.my-apps.move.new"].tap()
        let field = app.textFields["iris.store.my-apps.folder-name.field"]
        XCTAssertTrue(field.waitForExistence(timeout: fixtureWait))
        let createdName = name + " " + UUID().uuidString.prefix(8)
        field.clearAndTypeText(createdName)
        app.buttons["iris.store.my-apps.folder-name.save"].tap()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.my-apps.folder.' AND identifier ENDSWITH '.header' AND label BEGINSWITH %@", createdName)).firstMatch
        XCTAssertTrue(app.scrollUntilExists(header), "SPEC 1.4: find the folder just created")
        return header
    }
}

private extension XCUIElement {
    /// SwiftUI `TextField` selection cannot be driven by "select all" from
    /// XCUITest portably across simulator OS versions; clearing by deleting
    /// the existing value's character count is the standard, reliable
    /// substitute this codebase's other UI test files also rely on.
    func clearAndTypeText(_ text: String) {
        tap()
        if let value = self.value as? String, !value.isEmpty {
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)
            typeText(deletes)
        }
        if !text.isEmpty { typeText(text) }
    }
}
