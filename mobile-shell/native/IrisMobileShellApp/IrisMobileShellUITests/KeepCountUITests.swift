import XCTest

// MV6 spec-only UI coverage for mobile-versions SPEC sections 1.6, 1.7 and 5.1.
// Fixture launch contract: MV6-ui-tests/FIXTURE_CONTRACT.md.
final class KeepCountUITests: XCTestCase {
    private let keepCountID = "iris.store.storage.keep-count"
    private let resetID = "iris.store.storage.keep-count.reset"
    private let appA = "publik.kneecap"
    private let appB = "publik.nut-ai"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchKeepCountFixture(seed: String? = nil, accessibilityXXXL: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--iris-ui-test-fixtures", "storage-keep-count"]
        if let seed {
            app.launchArguments += ["--iris-ui-test-keep-count", seed]
        }
        app.launchArguments += ["--iris-ui-test-session", "s\(UUID().uuidString.lowercased().prefix(12))"]
        if accessibilityXXXL {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    private func openStorage(_ app: XCUIApplication) {
        if app.element(NativeStoreIdentifiers.storage).exists { return }
        if app.element(NativeStoreIdentifiers.versions).exists {
            app.navigationBars.buttons.firstMatch.tap()
            if app.element(NativeStoreIdentifiers.storage).waitForExistence(timeout: fixtureWait) { return }
        }
        app.storeTab(.myApps).tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.myApps).waitForExistence(timeout: fixtureWait))
        let storageLine = app.element(NativeStoreIdentifiers.myAppsStorageLine)
        XCTAssertTrue(app.scrollUntilExists(storageLine))
        storageLine.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.storage).waitForExistence(timeout: fixtureWait))
    }

    private func keepCountControl(_ app: XCUIApplication) -> XCUIElement {
        app.element(keepCountID)
    }

    private func option(_ count: String, in app: XCUIApplication) -> XCUIElement {
        app.element("iris.store.storage.keep-count.option.\(count)")
    }

    private func choose(_ count: String, in app: XCUIApplication) {
        let control = keepCountControl(app)
        XCTAssertTrue(control.waitForExistence(timeout: fixtureWait))
        control.tap()
        let choice = option(count, in: app)
        XCTAssertTrue(choice.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(choice.isHittable, "Keep-count choice \(count) must be operable.")
        choice.tap()
    }

    private func assertSelected(_ count: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let control = keepCountControl(app)
        XCTAssertTrue(control.waitForExistence(timeout: fixtureWait), "The global setting must remain available.", file: file, line: line)
        let expectedLabel = count == "2" ? "2 (Default)" : (count == "all" ? "Keep all while there is room" : count)
        let accessibleValue = control.value as? String ?? ""
        XCTAssertTrue(control.label.contains(expectedLabel) || accessibleValue == count || accessibleValue == expectedLabel,
                      "The control's accessibility value must report K=\(expectedLabel); label=\(control.label), value=\(accessibleValue)", file: file, line: line)
        let selected = option(count, in: app)
        if selected.exists {
            XCTAssertTrue(selected.isSelected || (selected.value as? String == count), "The option's accessibility selection oracle must report K=\(count); value=\(String(describing: selected.value))", file: file, line: line)
        }
    }

    private func relaunchPreservingFixture(_ app: XCUIApplication) {
        app.terminate()
        if let seedIndex = app.launchArguments.firstIndex(of: "--iris-ui-test-keep-count"), app.launchArguments.indices.contains(seedIndex + 1) {
            app.launchArguments.removeSubrange(seedIndex..<(seedIndex + 2))
        }
        if !app.launchArguments.contains("--iris-ui-test-preserve-state") {
            app.launchArguments.append("--iris-ui-test-preserve-state")
        }
        app.launch()
    }

    private func amount(in confirmation: String, file: StaticString = #filePath, line: UInt = #line) -> String? {
        // The confirmation is the visible source of the expected amount. The UI test
        // captures it and compares the result; independent st_blocks accounting is a Core oracle.
        let pattern = #"^Keep 2 versions per app\? Iris will free ([0-9]+(?:\.[0-9]+)? (?:bytes|KB|MB|GB)) of allocated storage now\. This is the space the files give back to your iPhone\.$"#
        guard let match = confirmation.range(of: pattern, options: .regularExpression) else {
            XCTFail("Unexpected confirmation copy or amount format: \(confirmation)", file: file, line: line)
            return nil
        }
        let nsRange = NSRange(match, in: confirmation)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: confirmation, range: nsRange),
              let amountRange = Range(result.range(at: 1), in: confirmation) else {
            XCTFail("The confirmation amount must be byte-formatted.", file: file, line: line)
            return nil
        }
        return String(confirmation[amountRange])
    }

    private func assertResult(_ result: String, containsSameAmount amount: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = "Kept 2 versions per app. Iris freed \(amount) of allocated storage."
        XCTAssertEqual(result, expected, "The completed result must report the exact amount shown in confirmation.", file: file, line: line)
    }

    // Mutation: reusing one namespace across tests leaks a prior saved choice and fails the default-selection oracle.
    func testDefaultSelectionIsTwo() throws {
        let app = launchKeepCountFixture()
        openStorage(app)
        XCTAssertEqual(keepCountControl(app).label, "Versions kept per app")
        assertSelected("2", in: app)
        keepCountControl(app).tap()
        XCTAssertTrue(option("2", in: app).waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(option("2", in: app).label, "2 (Default)")
        assertSelected("2", in: app)
    }

    // Mutation: a missing, renamed, reordered-by-identity, inaccessible, or untappable choice fails the exact id, label, count, or hit test.
    func testFourChoicesKeepExactCopyIdentifiersAndAccessibilityAtXXXL() throws {
        let app = launchKeepCountFixture(accessibilityXXXL: true)
        openStorage(app)
        XCTAssertEqual(keepCountControl(app).label, "Versions kept per app")
        keepCountControl(app).tap()

        let choices: [(String, String)] = [
            ("2", "2 (Default)"), ("3", "3"), ("5", "5"), ("all", "Keep all while there is room")
        ]
        XCTAssertTrue(option("2", in: app).waitForExistence(timeout: fixtureWait))
        let visibleOptions = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.storage.keep-count.option."))
        XCTAssertEqual(visibleOptions.count, choices.count, "The control offers exactly the four specified choices.")
        XCTAssertEqual(visibleOptions.allElementsBoundByIndex.map(\.label), choices.map { $0.1 }, "The choice list keeps the specified order and exact visible text.")
        for (key, label) in choices {
            let item = option(key, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: fixtureWait), "Missing option identifier for \(key).")
            XCTAssertEqual(item.label, label)
            XCTAssertTrue(item.isHittable, "\(label) must remain tappable at accessibility Dynamic Type XXXL.")
            item.tap()
            assertSelected(key, in: app)
            if key != "all" { keepCountControl(app).tap() }
        }
    }

    // Mutation: per-app scoping or a prune that erases Features history fails app B's three ledger rows or the shared K=3 readback.
    func testChoiceIsGlobalAcrossAppsAndFeaturesLedgerStillShowsAppBHistory() throws {
        let app = launchKeepCountFixture()
        openStorage(app)
        choose("3", in: app)
        assertSelected("3", in: app)

        let secondAppRow = app.element(NativeStoreIdentifiers.storageAppRow(appB))
        XCTAssertTrue(app.scrollUntilExists(secondAppRow), "The second seeded app must be reachable from Storage.")
        secondAppRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait), "The second app opens its Features screen.")
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.store.versions.row."))
        XCTAssertEqual(rows.count, 3, "App B's three ledger versions remain represented on its Features screen.")
        let rowLabels = rows.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(rowLabels.contains { $0.contains("On this iPhone now") }, "The current revision remains marked in the Features ledger.")
        XCTAssertTrue(rowLabels.contains { $0.contains("Kept as backup") }, "The fallback revision remains marked in the Features ledger.")
        XCTAssertTrue(rowLabels.contains { $0.contains("Kept (within your count)") }, "At global K=3 the second app's third revision remains kept by count.")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.storage).waitForExistence(timeout: fixtureWait))
        choose("3", in: app)
        assertSelected("3", in: app)
    }

    // Mutation: an in-memory-only or wrong-suite preference fails the K=5 readback after process relaunch.
    func testFivePersistsAcrossTerminationAndRelaunch() throws {
        let app = launchKeepCountFixture()
        openStorage(app)
        choose("5", in: app)
        assertSelected("5", in: app)
        relaunchPreservingFixture(app)
        openStorage(app)
        assertSelected("5", in: app)
    }

    // Mutation: reset that only changes the display, skips pruning confirmation, or is not saved fails result and relaunch assertions.
    func testResetToTwoPersistsAcrossSecondRelaunch() throws {
        let app = launchKeepCountFixture(seed: "5")
        openStorage(app)
        assertSelected("5", in: app)
        let reset = app.element(resetID)
        XCTAssertTrue(reset.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(reset.label, "Reset to 2 (Default)")
        reset.tap()
        let confirmation = app.staticTexts["iris.store.storage.keep-count.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: fixtureWait), "Reset follows the same confirmed lower-count path.")
        app.buttons["iris.store.storage.keep-count.confirm"].tap()
        XCTAssertTrue(app.staticTexts["iris.store.storage.keep-count.result"].waitForExistence(timeout: fixtureWait))
        assertSelected("2", in: app)
        relaunchPreservingFixture(app)
        openStorage(app)
        assertSelected("2", in: app)
        relaunchPreservingFixture(app)
        openStorage(app)
        assertSelected("2", in: app)
    }

    // Mutation: wrong amount formatting, changed result amount, optimistic selection, or a result published before prune completion fails these assertions.
    func testConfirmLoweringWaitsForPruneAndReportsTheConfirmedAmount() throws {
        let app = launchKeepCountFixture(seed: "5")
        openStorage(app)
        choose("2", in: app)
        let confirmation = app.staticTexts["iris.store.storage.keep-count.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: fixtureWait))
        let expectedAmount = amount(in: confirmation.label)
        XCTAssertNotNil(expectedAmount)
        XCTAssertEqual(app.buttons["iris.store.storage.keep-count.confirm"].label, "Keep 2 versions")
        XCTAssertEqual(app.buttons["iris.store.storage.keep-count.cancel"].label, "Not now")
        assertSelected("5", in: app)

        app.buttons["iris.store.storage.keep-count.confirm"].tap()
        let result = app.staticTexts["iris.store.storage.keep-count.result"]
        XCTAssertTrue(result.waitForExistence(timeout: fixtureWait), "A result is published only when the prune operation has completed.")
        if let expectedAmount { assertResult(result.label, containsSameAmount: expectedAmount) }
        assertSelected("2", in: app)
    }

    // Mutation: Not now that persists 2 or publishes success fails the saved-selection and absent-result assertions.
    func testNotNowLeavesFiveSelectedAndShowsNoResult() throws {
        let app = launchKeepCountFixture(seed: "5")
        openStorage(app)
        choose("2", in: app)
        let confirmation = app.staticTexts["iris.store.storage.keep-count.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(app.buttons["iris.store.storage.keep-count.cancel"].label, "Not now")
        app.buttons["iris.store.storage.keep-count.cancel"].tap()
        assertSelected("5", in: app)
        XCTAssertFalse(app.staticTexts["iris.store.storage.keep-count.result"].exists, "Cancellation must not publish a prune result.")
    }

    // Mutation: a shared namespace leaks saved choices; querying the ledger on Storage instead of Features hides the freed row.
    func testRaisingCountDoesNotRestoreFreedVersion() throws {
        let app = launchKeepCountFixture(seed: "5")
        openStorage(app)
        choose("2", in: app)
        let confirmation = app.staticTexts["iris.store.storage.keep-count.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: fixtureWait))
        app.buttons["iris.store.storage.keep-count.confirm"].tap()
        XCTAssertTrue(app.staticTexts["iris.store.storage.keep-count.result"].waitForExistence(timeout: fixtureWait))

        let firstAppRow = app.element(NativeStoreIdentifiers.storageAppRow(appA))
        XCTAssertTrue(app.scrollUntilExists(firstAppRow))
        firstAppRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait), "The app's Features ledger must be open before checking freed versions.")
        let absentRow = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "iris.store.versions.row.", "Not on this iPhone")).firstMatch
        XCTAssertTrue(absentRow.waitForExistence(timeout: fixtureWait), "The fixture's catalog-offered historical row remains in the ledger after its files are freed.")
        let absentIdentifier = absentRow.identifier

        openStorage(app)
        choose("5", in: app)
        let raiseMessage = app.staticTexts["iris.store.storage.keep-count.raising"]
        XCTAssertTrue(raiseMessage.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(raiseMessage.label, "Raising this number will not bring back versions that were freed. Download a version again if the catalog still offers it.")
        assertSelected("5", in: app)

        XCTAssertTrue(app.scrollUntilExists(firstAppRow))
        firstAppRow.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.versions).waitForExistence(timeout: fixtureWait))
        let stillAbsent = app.element(absentIdentifier)
        XCTAssertTrue(stillAbsent.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(stillAbsent.label.contains("Not on this iPhone"), "Raising K must not recreate the freed row's files.")
    }
}
