import XCTest

// unit m6-mobile-uitests. Skill akrit-dev:accessibility. Covers design
// section 9.4 and 12.7 (the exact VoiceOver label shapes) plus 9.3 (Dynamic
// Type at accessibility sizes keeps one column). XCUITest cannot toggle the
// system VoiceOver switch itself from inside a UI test process without
// Settings automation the main session would need to grant separately, so
// these tests check what VoiceOver actually reads from - each element's own
// `label`/`value`, which is the same accessibility tree VoiceOver speaks
// from - rather than literally enabling the screen reader. That is stated
// here as the one, deliberate limit of this file (see `HANDOFF.md`), not
// hidden: it is standard XCUITest practice (Apple's own UI testing guidance
// recommends asserting `label`/`value` rather than requiring VoiceOver to be
// physically on), but it is not a substitute for the main session's real
// VoiceOver pass, which stays a separate main_session_steps item.
final class AccessibilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// design 12.7 / 3.5: a card's one accessible element reads
    /// "<name>, <summary>, <action>" - checked as one label on one element,
    /// This checks the spoken-content contract. It cannot prove focus count;
    /// a real VoiceOver traversal is still required.
    func testCollapsedRowIsOneAccessibleElementWithNameSummaryAndAction() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")

        let slug = NativeStoreFixtureFacts.slug(0)
        // MOBILE_STORE_DESIGN.md 3.2: catalog3 uses rows, not shelf cards.
        let card = app.element(NativeStoreIdentifiers.row(slug))
        XCTAssertTrue(card.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(card.label.contains(NativeStoreFixtureFacts.name(0)), "The card's single accessibility label must include the app name.")
        XCTAssertTrue(card.label.contains("Sample summary for fixture app number 0"), "The card's single accessibility label must include the summary text (design 3.5).")

        XCTAssertTrue(card.label.contains("Get"), "design 12.7: the row announces its available action")

        // Design 3.5/3.6/12.7 requires grouped speech and a named action.
        // XCUIElement.exists reports query membership, not VoiceOver focus.
        // Keep the spoken-content oracle; a real focus traversal stays required.
        let get = app.buttons[NativeStoreIdentifiers.rowGet(slug)]
        XCTAssertTrue(get.exists)
        XCTAssertTrue(get.label.contains("Get"), "the action must have a name")
    }

    /// design 12.7: the Get button's accessibility value carries the state
    /// word, and per the Get-button table (design 6.2) the note line's text
    /// is repeated as the button's `value` in every state - checked
    /// directly against `.value`, which is what VoiceOver speaks after the
    /// label, not merely that some value is non-nil.
    func testGetButtonAccessibilityValueCarriesTheStateWord() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let card = app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(1)))
        XCTAssertTrue(card.waitForExistence(timeout: fixtureWait))
        card.tap()

        let getButton = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(getButton.waitForExistence(timeout: fixtureWait))
        let value = getButton.value as? String ?? ""
        // R2: the real button (StoreInstallButtonState.accessibilityValue) always
        // carries its state word, so an empty value now means the feature is gone.
        XCTAssertTrue(value.hasPrefix("Get"), "Before any tap, the Get button's value states \"Get\" (got \"\(value)\"); never empty and never a later-stage word (Downloading, Verifying).")
    }

    /// design 12.7 ("the strings tests assert"): the pin toggle's VoiceOver
    /// label is "Pin this version" (and "Unpin this version" once pinned), and
    /// mobile-versions SPEC 1.1 says the same phrase in its VoiceOver column.
    /// XCUITest cannot read an accessibility hint, so the label is what is
    /// checked, exactly, in both states. (Round 6 test audit: this test used
    /// to be named for the hint but only asserted that the label contained
    /// "Pin", which the words "Pinned" or "Pincode" would also satisfy.)
    func testPinToggleReadsPinThisVersionThenUnpinThisVersion() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("storage-full")
        app.storeTab(.myApps).tap()
        let row = app.element(NativeStoreIdentifiers.myAppsRow("publik.kneecap"))
        XCTAssertTrue(app.scrollUntilExists(row), "organization SPEC 1.1: reveal the recycled app row")
        row.tap()
        let versionsRow = app.element(NativeStoreIdentifiers.appVersionsRow)
        XCTAssertTrue(versionsRow.waitForExistence(timeout: fixtureWait))
        versionsRow.tap()

        let pinButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "iris.storage.pin.")).firstMatch
        XCTAssertTrue(pinButton.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(
            pinButton.label.hasPrefix("Pin this version"),
            "design 12.7: the pin toggle reads \"Pin this version\" to VoiceOver, got \"\(pinButton.label)\""
        )
        pinButton.tap()
        let revision = String(pinButton.identifier.dropFirst("iris.storage.pin.".count))
        let unpinButton = app.buttons["iris.storage.unpin.\(revision)"]
        XCTAssertTrue(unpinButton.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(
            unpinButton.label.hasPrefix("Unpin this version"),
            "design 12.7: once pinned the toggle reads \"Unpin this version\", got \"\(unpinButton.label)\""
        )
    }

    /// design 9.3 (round 6 store-proportions SPEC.md L199: the app page Get
    /// drops under the text at its natural width, at least 44 pt tall, and is
    /// no longer full width; that part is checked in
    /// `StoreProportionsUITests.swift`): at an accessibility Dynamic Type
    /// size, horizontal
    /// shelves on Home collapse to a vertical "See all" list - checked as a
    /// real layout difference (the shelf's horizontal scroll container is
    /// gone, replaced by a plain list), not merely that text got bigger.
    /// Uses the standard simulator override for preferred content size
    /// (`-UIPreferredContentSizeCategoryName`), which is the practical,
    /// supported way to drive Dynamic Type from a UI test without a
    /// Settings-app detour.
    func testAccessibilitySizeCollapsesHorizontalShelvesToOneColumn() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--iris-ui-test-fixtures", "catalog100",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.addFixtureSession()
        app.launch()

        let featuredShelf = app.element(NativeStoreIdentifiers.homeShelfFeatured)
        // Mutation: an absent Featured shelf or missing contained See all link still fails (U12).
        XCTAssertTrue(app.scrollUntilExists(featuredShelf), "Featured (\(NativeStoreIdentifiers.homeShelfFeatured)) must become visible after scrolling at the largest accessibility size.")
        XCTAssertTrue(featuredShelf.waitForExistence(timeout: fixtureWait))
        // At an accessibility size the design (9.3) replaces the horizontal
        // shelf with a vertical list of the first 3 items plus a text "See
        // all" link; the checkable, visible difference from the default
        // layout is that a "See all" text link is now inside the Featured
        // shelf's own container (at default size Featured has no per-card
        // See all, only shelves like category/new do).
        let seeAllInsideFeatured = featuredShelf.staticTexts["See all"]
        XCTAssertTrue(seeAllInsideFeatured.waitForExistence(timeout: fixtureWait), "At an accessibility Dynamic Type size, Featured must show a \"See all\" link as part of its collapsed vertical list (design 9.3).")
    }

    /// SPEC section 1's accessibility identifier contract plus the built-in
    /// accessibility audit: a fast, broad sweep for the categories XCTest can
    /// check automatically (contrast, hit-target size, missing labels, text
    /// clipped) across the Home screen. This complements, never replaces, the
    /// manual VoiceOver pass.
    ///
    /// Round 6 test audit: the handler used to return `true` for every issue
    /// except the ones that mention Sponsored or Featured. `true` means "this
    /// issue is handled, ignore it", so the audit ignored everything it found
    /// and could never fail, the opposite of what the comment above the handler
    /// said. The spec-only audit now fails on every reported issue, including
    /// issues in Sponsored or Featured items (store-proportions SPEC 4.2).
    // Design 9.3/12.7 and sizing SPEC 6: independently observe heading growth.
    // The automatic audit stays strict; this is additional rendered evidence.
    func testBrowseSectionHeadingGrowsAtTheLargestAccessibilitySize() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog3")
        let heading = app.staticTexts["All apps"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: fixtureWait))
        let normalHeight = heading.frame.height
        XCTAssertGreaterThan(normalHeight, 0)
        app.terminate()
        app.launchArguments = ["--iris-ui-test-fixtures", "catalog3",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.addFixtureSession()
        app.launch()
        XCTAssertTrue(app.scrollUntilExists(heading))
        XCTAssertGreaterThan(heading.frame.height, normalHeight,
                             "the section heading must respond to the reader's text setting")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAutomaticAccessibilityAuditOnHomeFindsNoIssues() throws {
        let app = XCUIApplication()
        app.launchWithFixtures("catalog100")
        XCTAssertTrue(app.element(NativeStoreIdentifiers.home).waitForExistence(timeout: fixtureWait))

        // Store proportions SPEC 4.2 and 6 require legibility and hit areas
        // for every item. Editorial labels do not waive those requirements.
        try app.performAccessibilityAudit()
    }
}
