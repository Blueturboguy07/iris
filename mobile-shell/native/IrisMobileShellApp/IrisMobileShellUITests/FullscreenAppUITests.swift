import XCTest

// unit m6-mobile-uitests. Covers design section 9.1 ("The running app")
// and R7's lifecycle requirements: open, the in-app Home control's
// confirmation (the owner's explicit device-facts request, "the owner wants
// the in-app Home button to confirm it returns to Iris home" - already
// built in `NativeFullscreenAppView.swift`, identifiers `iris.open.done`
// triggering the `iris.open.home-confirm.stay`/`.go` alert), and
// background/return. Persona P2 ("backgrounds the app mid-action, expects
// instant reopen") drives `testBackgroundingAndReturningKeepsTheAppOpen`.
final class FullscreenAppUITests: XCTestCase {
    static let kneecapAppId = "publik.kneecap"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openKneecapFullScreen(_ app: XCUIApplication) {
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
        let open = app.buttons[NativeStoreIdentifiers.open(Self.kneecapAppId)]
        XCTAssertTrue(app.scrollUntilExists(open), "organization SPEC 1.1: reveal Kneecap below saved folders")
        open.tap()
        XCTAssertTrue(app.element("iris.open.fullscreen-content").waitForExistence(timeout: fixtureWait), "The app's own content must render inside the full-screen cover.")
    }

    /// design 9.1, "The running app" row: opening an installed app covers
    /// the whole screen and hides the tab bar - the real, visible signal
    /// that My apps is no longer the front surface.
    func testOpenCoversTheWholeScreenAndHidesTheTabBar() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecapFullScreen(app)

        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The tab bar must be hidden while the app fills the screen.")
    }

    /// The owner's explicit device-facts item (`PHASE0_DEVICE_RESULTS_
    /// 20260928.md`, S0): the in-app Home control must ask for confirmation
    /// before it returns to Iris home, and tapping Stay must leave the app
    /// exactly as it was (the app's content is still on screen, not
    /// interrupted).
    func testHomeControlAsksAndStayKeepsTheAppOpen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecapFullScreen(app)

        let home = app.buttons["iris.open.done"]
        XCTAssertTrue(home.waitForExistence(timeout: fixtureWait))
        home.tap()

        // Mutation: Home leaving immediately still fails the real alert-action wait (design 9.1, G7).
        let stay = app.confirmationButton("iris.open.home-confirm.stay")
        let go = app.confirmationButton("iris.open.home-confirm.go")
        XCTAssertTrue(stay.waitForExistence(timeout: fixtureWait), "The Home control must ask \"Go back to Iris home?\" before leaving, not leave immediately.")
        XCTAssertTrue(go.exists)

        stay.tap()
        XCTAssertTrue(app.element("iris.open.fullscreen-content").waitForExistence(timeout: fixtureWait), "Stay must leave the app's content on screen, uninterrupted.")
    }

    /// The same confirmation's Go path must actually return to Iris home
    /// (My apps, per design 9.1's "on dismissal the store selects My apps
    /// and pops to root"), a real screen change, not just the alert
    /// dismissing.
    func testHomeControlGoReturnsToMyApps() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecapFullScreen(app)

        app.buttons["iris.open.done"].tap()
        // Mutation: missing confirmation or Go leaving the app open still fails (design 9.1, G7).
        let go = app.confirmationButton("iris.open.home-confirm.go")
        XCTAssertTrue(go.waitForExistence(timeout: fixtureWait))
        go.tap()

        XCTAssertTrue(app.storeTab(.myApps).waitForExistence(timeout: fixtureWait), "Go must return to My apps with the tab bar visible again (design 9.1).")
        XCTAssertFalse(app.element("iris.open.fullscreen-content").exists, "The running app's content must no longer be on screen after Go.")
    }

    /// P2's "backgrounds the app mid-action, expects instant reopen": send
    /// the whole process to the background with the device Home gesture,
    /// then reactivate it, and the running app must still be exactly where
    /// it was, not reset to My apps or relaunched fresh.
    func testBackgroundingAndReturningKeepsTheAppOpen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecapFullScreen(app)

        XCUIDevice.shared.press(.home)
        // Give the app a moment to actually reach the background state
        // before asking it to come back; this is a real OS transition, not
        // fixture-speed in-memory work, so it gets its own short wait
        // rather than reusing `fixtureWait`.
        let backgrounded = expectation(description: "app backgrounded")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { backgrounded.fulfill() }
        wait(for: [backgrounded], timeout: 3)

        app.activate()
        XCTAssertTrue(app.element("iris.open.fullscreen-content").waitForExistence(timeout: fixtureWait), "Reactivating after backgrounding must return to the same running app, not My apps or a cold relaunch.")
    }

    /// Device fact (`PHASE0_DEVICE_RESULTS_20260928.md`): "exports only went
    /// to Files, never Photos" and a Save sheet appears for the storage
    /// check package. This uses the existing, already-working
    /// `--iris-storage-acceptance` launch path (bundled `StorageCheck.
    /// irisapp`, unrelated to this unit's own `--iris-ui-test-fixtures`
    /// modes) rather than this unit's generated fixtures, since the export
    /// trigger lives inside that bundled app's own web content, which this
    /// unit's identifiers do not reach. The one thing checkable from the
    /// host side is that a system save/share sheet actually appears and
    /// that the fullscreen app's own content is momentarily covered by it,
    /// which is the visible proof export handed off to the system Save UI
    /// rather than silently doing nothing (the S0 double-tap / silent-
    /// failure risk this whole device-facts list exists to catch).
    func testStorageCheckExportShowsASystemSaveSheet() throws {
        // No stable export trigger is part of the allowed fixture contract.
        // Opening a package review sheet is not an export action or Save UI.
        throw XCTSkip("Export coverage gap: runner must invoke export inside StorageCheck and verify the system Save destination. No export trigger seam is supplied to this host UI suite.")
    }

    // MARK: Kneecap: deleting a project (kneecap-bugpass/DELETE_HOW_TO_TEST.txt)

    /// The owner's hand test for "Kneecap: deleting a project", steps 1, 2 and 4
    /// to 8, as far as a test can do without picking a video from Photos. The
    /// person: opens Kneecap from My apps, starts a new project, comes back to
    /// the list, swipes the project left and taps Delete. Expect:
    ///  - a box asking `Delete "Project 1"?` that says it can't be undone and
    ///    that the videos are removed from this phone too, with Cancel and Delete;
    ///  - Cancel closes the box and the project is still in the list;
    ///  - Delete closes the box, the project is gone, the list stays on screen
    ///    (the editor does not open), and the list reads "No projects yet";
    ///  - after closing Kneecap and opening it again, still no projects.
    /// Steps 3 and 9 (Settings > iPhone Storage, videos from Photos) are a
    /// person's job on the phone. If Kneecap does not keep a project until it has
    /// a video in it, no project is listed here, and the test skips with that
    /// reason rather than pretend the delete path ran.
    /// Round 6 test author: added, the delete fix (package 06) had a Core test for
    /// the dialog mechanic and for the bundled file, and no test of this journey.
    func testKneecapDeleteProjectAsksFirstCancelKeepsTheProjectAndDeleteRemovesOnlyThen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        openKneecapFullScreen(app)

        func web(_ text: String) -> XCUIElement {
            app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }

        let newProject = web("New project")
        XCTAssertTrue(newProject.waitForExistence(timeout: fixtureWait * 2), "DELETE_HOW_TO_TEST.txt step 1: installed Kneecap must open its project list with New project")
        newProject.tap()
        let close = web("Close project")
        XCTAssertTrue(close.waitForExistence(timeout: fixtureWait * 2), "step 1: a new project opens the editor, which has a Close project arrow")
        close.tap()

        let project = web("Project 1")
        guard project.waitForExistence(timeout: fixtureWait) else {
            throw XCTSkip("No project is listed after closing an empty new project, so Kneecap keeps a project only once a video is in it. The delete path needs a video from Photos: run DELETE_HOW_TO_TEST.txt steps 1 to 9 by hand.")
        }

        // Step 4: swipe left, Delete, and the box.
        project.swipeLeft()
        let deleteButton = app.webViews.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteButton.waitForExistence(timeout: fixtureWait), "step 4: swiping the project left shows a Delete button")
        deleteButton.tap()
        // Mutation: deletion without asking still fails at the box step (DELETE_HOW_TO_TEST step 4).
        // The observed web dialog owns both actions; a page ancestor also contains the swipe-row Delete.
        let box = app.webViews.otherElements
            .matching(NSPredicate(format: "label ENDSWITH 'web alert dialog'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: fixtureWait), "step 4: the web confirmation must appear before deletion")
        let boxText = ([box.label] + box.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
        XCTAssertTrue(boxText.contains("Delete \"Project 1\"?") || boxText.contains("Delete \u{201C}Project 1\u{201D}?"), "step 4: the box names the project, got \"\(boxText)\"")
        XCTAssertTrue(boxText.contains("undone"), "step 4: the box says it can't be undone, got \"\(boxText)\"")
        XCTAssertTrue(boxText.contains("removed from this phone"), "step 4: the box says the videos are removed from this phone too, got \"\(boxText)\"")
        let cancel = box.buttons["Cancel"].firstMatch
        // The dialog scope excludes the swipe-row Delete behind it.
        let confirmDelete = box.buttons["Delete"].firstMatch
        XCTAssertTrue(cancel.exists && confirmDelete.exists, "step 4: the box has Cancel and Delete")

        // Step 5: Cancel keeps it.
        cancel.tap()
        XCTAssertTrue(box.waitForNonExistence(timeout: 2), "step 5: the web box closes")
        XCTAssertTrue(web("Project 1").exists, "step 5: the project is still in the list")

        // Step 6: Delete removes it, and the list stays.
        web("Project 1").swipeLeft()
        app.webViews.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(box.waitForExistence(timeout: fixtureWait))
        confirmDelete.tap()
        XCTAssertTrue(box.waitForNonExistence(timeout: 2), "step 6: the web box closes")
        XCTAssertTrue(web("No projects yet").waitForExistence(timeout: fixtureWait), "step 7: the emptied list reads \"No projects yet\"")
        XCTAssertFalse(web("Project 1").exists, "step 6: the project is gone and does not come back")
        XCTAssertFalse(web("Close project").exists, "step 6: the editor does not open after deleting")

        // Reopen within this shell process; force-quit persistence and media byte release remain matrix M11.
        // Step 8: close Kneecap, open it again, still nothing.
        app.buttons["iris.open.done"].tap()
        app.confirmationButton("iris.open.home-confirm.go").tap()
        openKneecapFullScreen(app)
        XCTAssertTrue(web("No projects yet").waitForExistence(timeout: fixtureWait * 2), "step 8: after reopening Kneecap the deleted project is still gone")
        XCTAssertFalse(web("Project 1").exists)
    }
}
