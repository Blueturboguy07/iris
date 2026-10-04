import XCTest

// Round 6, catalog-expand. Test author: spec only
// (docs/plans/20260928-all-routes/round6/catalog-expand/SPEC.md; each
// assertion cites its SPEC line as "SPEC L<n>").
//
// The owner opened the iPhone store, saw three apps, and asked why. These
// tests are what a person sees afterwards on the phone's own catalog of last
// resort: Browse lists four apps by name (Kneecap, Nut AI, FreeHarmony,
// Lunara), Lunara carries a "16+" badge and asks for an age before Get, and
// none of the Browse apps that cannot run inside Iris show up.
//
// Environment (SPEC L105): run only on the assigned Simulator (iPhone 18 Pro)
// or the owner's phone, on a FRESH install (delete the app first) with no
// declared age, and with the catalog at publikhq.com still answering 404 so
// the app paints its bundled seed. These tests deliberately do NOT pass
// `--iris-ui-test-fixtures`: the fixtures build fake catalogs, and the point
// here is the real bundled seed. Nothing here taps an install that finishes;
// the age sheet test stops at the sheet.
//
// Expected to FAIL until the builder lands Lunara (only three apps list today).
final class CatalogExpandUITests: XCTestCase {
    private static let expected: [(slug: String, name: String)] = [
        ("kneecap", "Kneecap"),
        ("nut-ai", "Nut AI"),
        ("freeharmony", "FreeHarmony"),
        ("lunara", "Lunara"),
    ]
    // SPEC L114.
    private static let excluded = ["NoScroll", "HAT", "Chirp", "Beaver", "Turbolarp", "MyMacroHero", "Microstudy"]

    private let wait: TimeInterval = 20

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchWithBundledSeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    /// Everything a person can read on a row: its label plus any text inside it.
    private func readableText(of row: XCUIElement) -> String {
        var parts = [row.label]
        parts.append(contentsOf: row.staticTexts.allElementsBoundByIndex.map(\.label))
        return parts.joined(separator: " | ")
    }

    private func listedRowSlugs(_ app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(
            format: "identifier BEGINSWITH 'iris.store.row.' AND NOT identifier ENDSWITH '.get' AND NOT identifier ENDSWITH '.note' AND NOT identifier ENDSWITH '.sponsored' AND NOT identifier ENDSWITH '.name'")
        let prefix = "iris.store.row."
        let identifiers = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.map(\.identifier)
        return Array(Set(identifiers.map { String($0.dropFirst(prefix.count)) })).sorted()
    }

    // MARK: acceptance 1 and 2: what Browse lists

    /// SPEC L107, L108: fresh install, Browse home: one plain All apps list of
    /// exactly four apps, each with its name, and a "By Publik" line.
    func testBrowseListsKneecapNutAIFreeHarmonyAndLunaraByName() throws {
        let app = launchWithBundledSeed()
        let allApps = app.element(NativeStoreIdentifiers.homeAllApps)
        XCTAssertTrue(allApps.waitForExistence(timeout: fixtureWait * 2), "SPEC L107: below 13 apps the store shows one plain All apps list")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeCategoryRow).exists, "SPEC L107: no chips at four apps")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.homeShelfFeatured).exists, "SPEC L107: no shelves at four apps")

        for entry in Self.expected {
            let row = app.element(NativeStoreIdentifiers.row(entry.slug))
            XCTAssertTrue(row.waitForExistence(timeout: wait), "SPEC L107: \(entry.name) must be listed")
            let text = readableText(of: row)
            XCTAssertTrue(text.contains(entry.name), "\(entry.slug) row reads \"\(text)\"")
            XCTAssertTrue(text.contains("By Publik"), "SPEC L108: \(entry.name)'s row says By Publik, got \"\(text)\"")
        }
        XCTAssertEqual(listedRowSlugs(app), Self.expected.map(\.slug).sorted(), "SPEC L9, L12: exactly these four apps and no other row")

        let countLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '4 apps'")).firstMatch
        XCTAssertTrue(countLine.waitForExistence(timeout: wait), "SPEC L107: the All apps section says \"4 apps\"")
    }

    /// SPEC L108: Lunara's row shows a "16+" badge; the other three show no age badge.
    func testOnlyLunarasRowShowsAnAgeBadge() throws {
        let app = launchWithBundledSeed()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeAllApps).waitForExistence(timeout: fixtureWait * 2))
        let badge = try NSRegularExpression(pattern: "\\b\\d{1,2}\\+")
        for entry in Self.expected {
            let row = app.element(NativeStoreIdentifiers.row(entry.slug))
            XCTAssertTrue(row.waitForExistence(timeout: wait), "\(entry.name) must be listed")
            let text = readableText(of: row)
            let hasBadge = badge.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            if entry.slug == "lunara" {
                XCTAssertTrue(text.contains("16+"), "SPEC L108: Lunara shows 16+, got \"\(text)\"")
            } else {
                XCTAssertFalse(hasBadge, "SPEC L108: \(entry.name) shows no age badge, got \"\(text)\"")
            }
        }
    }

    // MARK: acceptance 8: no fake apps

    /// SPEC L114: searching the seven apps that cannot run in the shell finds
    /// nothing, and searching Lunara finds exactly one app.
    func testSearchFindsLunaraOnceAndNoneOfTheAppsThatCannotRunInIris() throws {
        let app = launchWithBundledSeed()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.homeAllApps).waitForExistence(timeout: fixtureWait * 2))
        app.storeTab(.search).tap()
        let field = app.textFields[NativeStoreIdentifiers.searchField]
        XCTAssertTrue(field.waitForExistence(timeout: wait))
        field.tap()

        field.typeText("Lunara")
        let countLine = app.staticTexts[NativeStoreIdentifiers.searchCount]
        XCTAssertTrue(countLine.waitForExistence(timeout: wait))
        XCTAssertTrue(countLine.label.contains("1 app"), "SPEC L114: one result for Lunara, got \"\(countLine.label)\"")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.row("lunara")).waitForExistence(timeout: wait))

        for name in Self.excluded {
            app.buttons[NativeStoreIdentifiers.searchClear].tap()
            field.tap()
            field.typeText(name)
            XCTAssertTrue(
                app.element(NativeStoreIdentifiers.searchZero).waitForExistence(timeout: wait),
                "SPEC L114: searching \(name) must find nothing")
            XCTAssertTrue(listedRowSlugs(app).isEmpty, "SPEC L114: no row for \(name)")
        }
    }

    // MARK: acceptance 3: not pushed onto the phone

    /// SPEC L109: on first launch My apps holds Kneecap, Nut AI and FreeHarmony
    /// only. Lunara appears there only after someone taps Get.
    func testMyAppsHoldsTheOriginalThreeAndNotLunaraBeforeGet() throws {
        let app = launchWithBundledSeed()
        app.storeTab(.myApps).tap()
        // First launch sets the three starters up (tens of MB each), so give it time.
        for appId in ["publik.kneecap", "publik.nut-ai", "publik.freeharmony"] {
            let row = app.element(NativeStoreIdentifiers.myAppsRow(appId))
            XCTAssertTrue(row.waitForExistence(timeout: 120), "SPEC L109: \(appId) is set up on first launch")
        }
        XCTAssertFalse(
            app.element(NativeStoreIdentifiers.myAppsRow("publik.lunara")).exists,
            "SPEC L109: Lunara must not be installed until someone taps Get")
    }

    // MARK: acceptance 4: the age check

    /// SPEC L110: with no age declared, tapping Get on Lunara opens the age
    /// sheet, and nothing installs. Stops at the sheet on purpose.
    func testGetOnLunaraWithNoAgeDeclaredOpensTheAgeSheet() throws {
        let app = launchWithBundledSeed()
        let row = app.element(NativeStoreIdentifiers.row("lunara"))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait * 2), "Lunara must be listed")
        row.tap()

        let name = app.element(NativeStoreIdentifiers.appName)
        XCTAssertTrue(name.waitForExistence(timeout: wait))
        XCTAssertTrue(readableText(of: name).contains("Lunara"))
        let get = app.element(NativeStoreIdentifiers.appGet)
        XCTAssertTrue(get.waitForExistence(timeout: wait))
        let visible = get.label.isEmpty ? (get.value as? String ?? "") : get.label
        XCTAssertTrue(visible.contains("16+"), "SPEC L108, L110: the button reads as rated 16+ before an age is set, got \"\(visible)\"")
        XCTAssertFalse(visible.hasPrefix("Open"), "nothing is installed yet")

        get.tap()
        XCTAssertTrue(
            app.element(NativeStoreIdentifiers.appAgeCheck).waitForExistence(timeout: wait),
            "SPEC L110: the age sheet opens")
    }

    // MARK: acceptance 6: the app page

    /// SPEC L110: Lunara's page shows its description, the permission line,
    /// "By Publik" and a visible not-a-medical-device line. (The privacy line
    /// and the report link have no fixed wording in SPEC.md, so they are
    /// covered by the node and Core tests, not asserted here.)
    func testLunarasAppPageShowsPermissionPrivacyPublisherAndReport() throws {
        let app = launchWithBundledSeed()
        let row = app.element(NativeStoreIdentifiers.row("lunara"))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait * 2), "Lunara must be listed")
        row.tap()

        let description = app.element(NativeStoreIdentifiers.appDescription)
        XCTAssertTrue(description.waitForExistence(timeout: wait))
        XCTAssertFalse(readableText(of: description).trimmingCharacters(in: .whitespaces).isEmpty)
        let permissions = app.element(NativeStoreIdentifiers.appPermissions)
        XCTAssertTrue(permissions.waitForExistence(timeout: wait))
        XCTAssertTrue(readableText(of: permissions).contains("Keeps your log on this phone"), "SPEC L110, got \"\(readableText(of: permissions))\"")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'By Publik'")).firstMatch.waitForExistence(timeout: wait),
            "SPEC L110: By Publik")
        let medical = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'medical'")).firstMatch
        XCTAssertTrue(medical.waitForExistence(timeout: wait), "SPEC L110: a visible not-a-medical-device line")
    }

    // MARK: acceptance 4, the rest of it (round 6 test audit, pass 0)

    // The two tests below change the age this phone remembers, and that
    // survives between tests. XCTest runs a class's tests in alphabetical order,
    // so both are named to sort after every test above that needs "no age
    // declared yet" (their names start with "testWith", after testBrowse,
    // testGet, testLunaras, testMyApps, testOnly and testSearch), and the 13
    // test sorts before the 16 test.

    /// Opens Lunara's page, taps its restricted Get and returns the age sheet,
    /// or skips on iOS 26 and later where the sheet is Apple's own request.
    private func openTheAgeSheetOnLunara(_ app: XCUIApplication) throws {
        let row = app.element(NativeStoreIdentifiers.row("lunara"))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait * 2), "Lunara must be listed")
        row.tap()
        let get = app.element(NativeStoreIdentifiers.appGet)
        XCTAssertTrue(get.waitForExistence(timeout: wait))
        get.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.appAgeCheck).waitForExistence(timeout: wait), "SPEC L110: the age sheet opens")
        if app.buttons["iris.app.age-gate.system-request"].exists {
            throw XCTSkip("iOS 26 and later: the age sheet is Apple's Declared Age Range request, which needs a signed-in Apple ID; run SPEC L110 by hand on the phone.")
        }
    }

    /// SPEC L110, acceptance 4: choose "13 or older": Get stays unavailable and a
    /// plain line says the app is rated 16+.
    func testWithAnAgeDeclared13LunaraStaysRestrictedAndSaysItIsRated16Plus() throws {
        let app = launchWithBundledSeed()
        try openTheAgeSheetOnLunara(app)
        app.buttons["iris.app.age-gate.declare.13"].tap()

        let get = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(get.waitForExistence(timeout: wait))
        XCTAssertFalse(get.label.hasPrefix("Get"), "SPEC L110: Get stays unavailable after answering 13, the button reads \"\(get.label)\"")
        XCTAssertFalse(get.label.hasPrefix("Open"), "nothing was installed")
        let note = app.staticTexts[NativeStoreIdentifiers.appNote]
        XCTAssertTrue(note.waitForExistence(timeout: wait))
        XCTAssertTrue(note.label.contains("16+"), "SPEC L110: a plain line says the app is rated 16+, got \"\(note.label)\"")
    }

    /// SPEC L110, acceptance 4 and 5 (the part that does not need airplane mode):
    /// choose "16 or older" and Get installs Lunara from the copy inside Iris.
    /// Get must reach Open, and must not sit on Verifying (the owner watched the
    /// button stay on Verifying for two minutes, store-proportions SPEC section
    /// 10). Then My apps holds Lunara.
    func testWithAnAgeDeclared16GetInstallsLunaraFromTheBundleAndReachesOpen() throws {
        let app = launchWithBundledSeed()
        try openTheAgeSheetOnLunara(app)
        app.buttons["iris.app.age-gate.declare.16"].tap()

        let get = app.buttons[NativeStoreIdentifiers.appGet]
        let becameGet = NSPredicate(format: "label BEGINSWITH 'Get'")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: becameGet, object: get)], timeout: wait),
            .completed, "SPEC L110: after answering 16 the plain Get appears, the button reads \"\(get.label)\"")
        get.tap()

        let opened = NSPredicate(format: "label BEGINSWITH 'Open'")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: opened, object: get)], timeout: 120)
        XCTAssertEqual(result, .completed, "SPEC L110: Get installs Lunara and the button becomes Open within two minutes; it last read \"\(get.label)\" (\"Verifying\" here is the stuck state from the owner's video)")

        app.storeTab(.myApps).tap()
        XCTAssertTrue(
            app.element(NativeStoreIdentifiers.myAppsRow("publik.lunara")).waitForExistence(timeout: wait),
            "SPEC L109: after Get, Lunara is in My apps")
    }
}
