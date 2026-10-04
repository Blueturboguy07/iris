import XCTest

// unit m6-mobile-uitests. Covers design section 8 (Storage screen).
// `storage-full` seeds every bundled Starter app at every revision (base
// through final, several per app) and lowers the global code cap to 256 KB
// in the fixture contract. Versions SPEC 1.4 permits automatic cap enforcement
// before the person reaches Storage, leaving an honest empty plan. UI copy is
// observed here; independently allocated bytes remain a native storage gate.
final class StorageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func openStorage(_ app: XCUIApplication) {
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
        let storageLine = app.element(NativeStoreIdentifiers.myAppsStorageLine)
        XCTAssertTrue(app.scrollUntilExists(storageLine), "organization SPEC 1.1: Storage follows saved folders and recycled rows")
        storageLine.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.storage).waitForExistence(timeout: fixtureWait))
    }

    /// design section 8 item 2: the device line states both what Iris apps
    /// use and how much free space the iPhone has, in one sentence, before
    /// any cap banner - a real, readable number pair, not a bare bar.
    func testDeviceLineStatesIrisUsageAndFreeSpaceTogether() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        let deviceLine = app.staticTexts[NativeStoreIdentifiers.storageDeviceLine]
        XCTAssertTrue(deviceLine.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(deviceLine.label.contains("Iris apps use"), "The device line must lead with what Iris itself uses (design 8 item 2).")
        XCTAssertTrue(deviceLine.label.contains("free"), "The same sentence must also state the iPhone's free space.")
    }

    /// design section 8 item 3: the Free up space button's own label states
    /// the promised reclaimable bytes when optional content remains. After
    /// automatic enforcement an empty plan is disabled and honestly named.
    func testFreeUpSpaceButtonStatesAPromiseOnlyWhenOptionalBytesRemain() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        let freeUp = app.buttons[NativeStoreIdentifiers.storageFreeUp]
        XCTAssertTrue(freeUp.waitForExistence(timeout: fixtureWait))
        // Versions SPEC 1.4: automatic cap enforcement can have freed all optional history.
        if freeUp.isEnabled {
            XCTAssertTrue(freeUp.label.contains("Free up space"))
            XCTAssertNotNil(freeUp.label.range(of: #"[1-9][0-9]*(\.[0-9]+)? (bytes|KB|MB|GB)"#, options: .regularExpression),
                            "an enabled action states a nonzero promise")
        } else {
            XCTAssertTrue(freeUp.label.contains("Nothing to free"), "design 8: no optional bytes means a disabled honest empty state")
        }
    }

    /// design section 8 item 4: tapping Free up space produces a result
    /// line stating what was actually freed (measured, not promised) and
    /// what was kept - a visible sentence, appearing where none existed
    /// before the tap.
    func testTappingFreeUpSpaceProducesAResultSentence() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        let resultBefore = app.staticTexts[NativeStoreIdentifiers.storageResult]
        XCTAssertFalse(resultBefore.exists, "No result line should exist before Free up space is tapped.")

        let freeUp = app.buttons[NativeStoreIdentifiers.storageFreeUp]
        XCTAssertTrue(freeUp.waitForExistence(timeout: fixtureWait))
        guard freeUp.isEnabled else {
            XCTAssertTrue(freeUp.label.contains("Nothing to free"))
            XCTAssertFalse(resultBefore.exists, "no operation or result is invented when the plan is empty")
            XCTAssertTrue(app.scrollUntilExists(app.element(NativeStoreIdentifiers.storageAppRow("publik.kneecap"))),
                          "the protected current app stays available")
            return // An actual reclaim journey needs an explicitly reclaimable fixture.
        }
        freeUp.tap()

        let result = app.staticTexts[NativeStoreIdentifiers.storageResult]
        XCTAssertTrue(result.waitForExistence(timeout: fixtureWait), "A result sentence must appear after Free up space runs.")
        XCTAssertTrue(result.label.contains("Freed") || result.label.contains("couldn't free"), "The result must say either what was freed or, honestly, that it could not free space (design 8 item 4).")
    }

    /// The sentence a person reads when what is installed is over the cap they
    /// (or the default) set: mobile-versions SPEC 1.4, "When the kept versions
    /// alone exceed the cap": "Your apps' current versions use 2.5 GB, more than
    /// the 2 GB limit. Iris keeps them all. ..." Found by its words, not an id.
    private func overCapSentence(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'more than the' AND label CONTAINS 'limit'")).firstMatch
    }

    /// mobile-versions SPEC 1.4: when the kept versions alone are over the cap,
    /// nothing is freed by force and the Storage screen says so in that
    /// sentence. `storage-full` sets a 256 KB cap against several installed
    /// apps, so the sentence must be on screen. (Round 6 test audit: this test
    /// used to look for `iris.store.storage.low` and call it the "cap"
    /// banner. Design 8 item 7 defines that banner as the OS reporting under
    /// 500 MB free ("Your iPhone has less than 500 MB free. Updates are
    /// paused"), which a Simulator with room to spare never shows, and the
    /// over-cap case has its own sentence in SPEC 1.4. The under-500 MB banner
    /// needs a phone that is nearly full and is a device step.)
    func testOverTheCapTheScreenSaysInstalledAppsUseMoreThanTheLimit() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        let sentence = overCapSentence(app)
        XCTAssertTrue(sentence.waitForExistence(timeout: fixtureWait), "SPEC 1.4: Storage says the current versions use more than the limit when they do.")
        XCTAssertTrue(sentence.label.contains("Iris keeps them all"), "SPEC 1.4: and that Iris keeps them all, got \"\(sentence.label)\"")
    }

    /// design section 8 item 5: the per-app "By app, largest first" row for
    /// an installed app must open that app's own Versions screen, a real
    /// navigation, not merely informational text.
    func testByAppRowOpensThatAppsVersionsScreen() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        let appRow = app.element(NativeStoreIdentifiers.storageAppRow("publik.kneecap"))
        XCTAssertTrue(appRow.waitForExistence(timeout: fixtureWait))
        appRow.tap()

        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait), "Tapping a Storage app row must push that app's Versions screen (design 8 item 5).")
    }

    /// design 8 item 6: a setting row "Keep at most N GB of app code" opens a
    /// small sheet with three choices, 1 GB, 2 GB and 4 GB, the current one
    /// marked, and Done. Choosing a cap bigger than what is installed removes
    /// the over-the-limit sentence (storage-full starts with a cap far below what
    /// is installed, so it is showing). Round 6 test author: added, the
    /// cap setting had no test.
    func testKeepAtMostSettingOffersOneTwoAndFourGigabytesAndARoomyCapClearsTheOverLimitSentence() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        openStorage(app)

        XCTAssertTrue(overCapSentence(app).waitForExistence(timeout: fixtureWait), "the cap starts far below what is installed, so the over-the-limit sentence shows")
        let capRow = app.element(NativeStoreIdentifiers.storageCap)
        XCTAssertTrue(capRow.waitForExistence(timeout: fixtureWait), "design 8 item 6: the Storage screen has the cap setting row")
        XCTAssertTrue(capRow.label.contains("Keep at most"), "the row reads \"Keep at most N GB of app code\", got \"\(capRow.label)\"")
        capRow.tap()

        XCTAssertTrue(app.element(NativeStoreIdentifiers.storageCapSheet).waitForExistence(timeout: fixtureWait), "design 8 item 6: the choices open in a sheet")
        for choice in ["1 GB", "2 GB", "4 GB"] {
            XCTAssertTrue(app.buttons[choice].exists, "design 8 item 6: the sheet offers \(choice)")
        }
        app.buttons["4 GB"].tap()
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 2) { done.tap() }

        XCTAssertTrue(
            overCapSentence(app).waitForNonExistence(timeout: fixtureWait),
            "SPEC 1.4: with a 4 GB cap the installed apps are under it, so the over-the-limit sentence is gone."
        )
        XCTAssertTrue(app.element(NativeStoreIdentifiers.storageCap).label.contains("4 GB"), "the setting row now reads 4 GB, got \"\(app.element(NativeStoreIdentifiers.storageCap).label)\"")
    }
}
