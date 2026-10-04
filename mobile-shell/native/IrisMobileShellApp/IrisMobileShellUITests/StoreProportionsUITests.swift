import CoreGraphics
import Vision
import XCTest

// Round 6, store-proportions. Written by the test author from the spec only:
// docs/plans/20260928-all-routes/round6/store-proportions/SPEC.md
// ("Iris Apps store on iPhone: sizing spec"). The author had not seen the
// implementation. Every assertion cites a SPEC.md line as "SPEC L<n>".
//
// What these tests check is what a person sees and can reach, in points:
//  - the DRAWN size of a control, measured from an XCUIScreenshot (an element
//    frame cannot show it, because SPEC L95 makes the tap area taller than
//    the drawn capsule),
//  - the tap area, by really tapping just outside the drawn shape,
//  - text that is cut off with "...", read back from the screenshot with
//    Vision text recognition (a Text's label is the full string even when it
//    is drawn cut off, so the label cannot show truncation),
//  - one accessibility text size launch (AX5, the largest).
//
// Screen assumption: portrait iPhone at least 375 pt wide. The spec numbers
// are for 402 x 874 (iPhone 18 Pro), and widths that depend on the screen
// are computed from the real window width, not hard coded.
//
// Not automated here (needs a person or another tool, see TESTS.md):
// SPEC L180 check 10 (Reduce Motion press scale), the 4.5:1 contrast of the
// tonal fill (SPEC L96, computed from token values), and VoiceOver.

private enum SpecPoints {
    static let gutter: CGFloat = 16                 // SPEC L60, L52
    static let rowIcon: CGFloat = 56                // SPEC L105
    static let rowPitch: CGFloat = 76               // SPEC L107
    static let rowCapsuleHeight: CGFloat = 30       // SPEC L88
    static let rowCapsuleMinWidth: CGFloat = 72     // SPEC L88
    static let rowCapsuleMaxWidth: CGFloat = 96     // SPEC L88
    static let pageCapsuleHeight: CGFloat = 32      // SPEC L90
    static let pageCapsuleMinWidth: CGFloat = 96    // SPEC L90, L128
    static let pageIcon: CGFloat = 96               // SPEC L126
    static let tapMinimum: CGFloat = 44             // SPEC L58
    static let drawnTolerance: CGFloat = 1.5        // edge anti-aliasing at 2x and 3x
}

class StoreProportionsTestCase: XCTestCase {
    static let defaultSize = "UICTContentSizeCategoryL"
    static let accessibilityLargest = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: launch and navigation

    func launch(_ mode: String, textSize: String = StoreProportionsTestCase.defaultSize) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--iris-ui-test-fixtures", mode,
            "-UIPreferredContentSizeCategoryName", textSize,
        ]
        app.addFixtureSession()
        app.launch()
        return app
    }

    func windowFrame(_ app: XCUIApplication) -> CGRect { app.windows.firstMatch.frame }

    func rowGet(_ app: XCUIApplication, _ index: Int) -> XCUIElement {
        app.element(NativeStoreIdentifiers.rowGet(NativeStoreFixtureFacts.slug(index)))
    }

    /// The first row Get on the current screen (Category and Search screens do not know slugs up front).
    func firstRowGet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.row.' AND identifier ENDSWITH '.get'"))
            .firstMatch
    }

    /// Opens the app page by tapping the text of the row (not the Get capsule).
    func openAppPageFromRow(_ app: XCUIApplication, index: Int) {
        let get = rowGet(app, index)
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait), "Row \(index) must be on Browse.")
        tap(app, x: 114, y: get.frame.midY)
        XCTAssertTrue(app.element(NativeStoreIdentifiers.app).waitForExistence(timeout: fixtureWait), "Tapping the row text must open the app page (SPEC L115).")
    }

    func tap(_ app: XCUIApplication, x: CGFloat, y: CGFloat) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
    }

    // MARK: screenshots and measuring

    func snapshot(_ app: XCUIApplication) throws -> (image: StorePixelImage, cgImage: CGImage) {
        let shot = app.screenshot()
        let cg = try XCTUnwrap(shot.image.cgImage, "The screenshot has no bitmap.")
        let window = windowFrame(app)
        let image = try XCTUnwrap(StorePixelImage(cgImage: cg, pixelsPerPoint: CGFloat(cg.width) / window.width), "The screenshot could not be read.")
        return (image, cg)
    }

    /// The drawn shape of a control: everything drawn inside its frame grown by 8 pt,
    /// against the surface colour around it.
    func drawnBounds(of element: XCUIElement, in image: StorePixelImage, grow: CGFloat = 8) -> CGRect? {
        let crop = element.frame.insetBy(dx: -grow, dy: -grow)
        let background = image.backgroundColor(around: crop)
        return image.inkBounds(in: crop, background: background)
    }

    func fillColor(of drawn: CGRect, in image: StorePixelImage) -> StoreRGB {
        image.rgb(atPoint: CGPoint(x: drawn.minX + 5, y: drawn.midY))
    }

    func surfaceColor(around element: XCUIElement, in image: StorePixelImage) -> StoreRGB {
        image.backgroundColor(around: element.frame.insetBy(dx: -8, dy: -8))
    }

    /// The row icon, found in the column left of the text at the height of the row's Get capsule.
    func rowIconBounds(centeredOn midY: CGFloat, in image: StorePixelImage) -> CGRect? {
        let band = CGRect(x: 0, y: midY - 40, width: 80, height: 80)
        return image.inkBounds(in: band, background: image.backgroundColor(around: band))
    }

    func stateText(_ element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    func waitForStateToLeaveGet(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let advanced = NSPredicate(format: "NOT (value BEGINSWITH 'Get')")
        let expectation = XCTNSPredicateExpectation(predicate: advanced, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: text recognition

    struct RecognizedLine {
        let text: String
        let rect: CGRect   // points, top left origin
    }

    /// Reads the text drawn inside `rect` (points). Skips the test when the recognizer is not available.
    func recognizedLines(in cgImage: CGImage, pixelsPerPoint: CGFloat, rect: CGRect) throws -> [RecognizedLine] {
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let pixelRect = CGRect(
            x: rect.minX * pixelsPerPoint, y: rect.minY * pixelsPerPoint,
            width: rect.width * pixelsPerPoint, height: rect.height * pixelsPerPoint
        ).integral.intersection(bounds)
        guard !pixelRect.isNull, pixelRect.width > 4, pixelRect.height > 4, let crop = cgImage.cropping(to: pixelRect) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        } catch {
            throw XCTSkip("Text recognition is not available in this environment: \(error)")
        }
        let results = request.results ?? []
        return results.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                text: best.string,
                rect: CGRect(
                    x: rect.minX + box.minX * rect.width,
                    y: rect.minY + (1 - box.maxY) * rect.height,
                    width: box.width * rect.width,
                    height: box.height * rect.height
                )
            )
        }
    }

    func assertNoCutOffText(_ lines: [RecognizedLine], contains fragments: [String], _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let joined = lines.map(\.text).joined(separator: " ")
        XCTAssertFalse(joined.contains("\u{2026}") || joined.contains("..."), "\(context): text is cut off with an ellipsis. Read: \"\(joined)\"", file: file, line: line)
        for fragment in fragments {
            XCTAssertTrue(joined.localizedCaseInsensitiveContains(fragment), "\(context): expected to read \"\(fragment)\" on screen. Read: \"\(joined)\"", file: file, line: line)
        }
    }

    // MARK: shared checks

    func assertGetIsTonalNotSolid(_ drawn: CGRect, surface: StoreRGB, image: StorePixelImage, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let fill = fillColor(of: drawn, in: image)
        XCTAssertFalse(fill.isSolidBlue, "\(context): the capsule is filled solid blue (\(fill)); rows use a light tonal fill (SPEC L88, L173).", file: file, line: line)
        XCTAssertLessThanOrEqual(fill.distance(to: surface), 48, "\(context): the capsule fill \(fill) is far from the surface \(surface); rows use a light tonal fill (SPEC L88).", file: file, line: line)
    }
}

// MARK: - The measuring code itself (no app launched)

/// The oracle check for the pixel measurer, run inside the UI test bundle. It paints known shapes
/// into synthetic images and checks the measurer reads the known sizes back. If this fails, the
/// size tests below cannot be trusted.
final class StoreProportionsMeasurerSelfTests: XCTestCase {
    func testMeasurerReadsKnownShapesBackAtTwoScreenScales() {
        let failures = StoreMeasureSelfCheck.run()
        XCTAssertTrue(failures.isEmpty, "The screenshot measurer is wrong: \(failures.joined(separator: "; "))")
    }
}

// MARK: - Browse rows (SPEC section 4.2 and 4.3)

final class StoreRowProportionsUITests: StoreProportionsTestCase {
    /// SPEC L88, L93, L47, L173 (check 1 and 3). The owner's complaint: "the get button looks way too big".
    /// On Browse with 3 apps each Get capsule is 30 pt tall (drawn), 72 to 96 wide, light tonal fill.
    func testGetCapsuleIsA30PointTonalPillOnEveryRow() throws {
        let app = launch("catalog3")
        let shot = try snapshot(app)
        for index in 0..<3 {
            let get = rowGet(app, index)
            XCTAssertTrue(get.waitForExistence(timeout: fixtureWait), "Row \(index) Get must exist.")
            let drawn = try XCTUnwrap(drawnBounds(of: get, in: shot.image), "Row \(index): nothing is drawn for Get.")
            XCTAssertEqual(drawn.height, SpecPoints.rowCapsuleHeight, accuracy: SpecPoints.drawnTolerance, "Row \(index): the drawn Get capsule must be 30 pt tall, not the 43 to 44 pt it is today (SPEC L88, L47).")
            XCTAssertGreaterThanOrEqual(drawn.width, SpecPoints.rowCapsuleMinWidth - 1, "Row \(index): the capsule is narrower than 72 pt (SPEC L88).")
            XCTAssertLessThanOrEqual(drawn.width, SpecPoints.rowCapsuleMaxWidth + 1, "Row \(index): the capsule is wider than 96 pt (SPEC L88).")
            assertGetIsTonalNotSolid(drawn, surface: surfaceColor(around: get, in: shot.image), image: shot.image, "Row \(index)")
        }
    }

    /// SPEC L88 and L173 (check 3): no solid blue slab anywhere on Browse. The blue Get capsule is the
    /// one thing the owner called too loud.
    func testBrowseHasNoSolidBlueSlab() throws {
        let app = launch("catalog3")
        XCTAssertTrue(rowGet(app, 0).waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let slabs = shot.image.solidBlobs(minWidth: 60, minHeight: 24, minAspect: 2, minFill: 0.6) { $0.isSolidBlue }
        XCTAssertTrue(slabs.isEmpty, "Browse shows solid blue slabs at \(slabs). Row Get capsules use a tonal fill, so nothing on Browse is a solid blue block (SPEC L88, L173).")
    }

    /// SPEC L93 and L173 (check 1): the icon is about twice the height of the Get capsule, 56 pt, and starts at
    /// the 16 pt gutter (SPEC L105, L106, L175 check 5).
    func testRowIconIs56PointsAtTheSixteenPointGutterAndTwiceTheCapsule() throws {
        // Design 13.3: measure verified bundled artwork, not a transparent fixture.
        let app = launch("offline-cold")
        let get = app.element(NativeStoreIdentifiers.rowGet("kneecap"))
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: get, in: shot.image), "Nothing is drawn for Get.")
        let icon = try XCTUnwrap(rowIconBounds(centeredOn: capsule.midY, in: shot.image), "No icon is drawn in the left column of the row.")
        XCTAssertEqual(icon.height, SpecPoints.rowIcon, accuracy: 2, "The row icon must be 56 pt tall, it is 44 pt today (SPEC L105).")
        XCTAssertEqual(icon.width, SpecPoints.rowIcon, accuracy: 2, "The row icon must be 56 pt wide (SPEC L105).")
        XCTAssertEqual(icon.minX, SpecPoints.gutter, accuracy: 1.5, "The row icon must start 16 pt from the screen edge (SPEC L106, L175).")
        XCTAssertLessThanOrEqual(capsule.height, icon.height * 0.6, "The Get capsule (\(capsule.height) pt) must be clearly shorter than the icon (\(icon.height) pt); the spec ratio is 0.54 (SPEC L93).")
    }

    /// SPEC L107 and L24 row: the row pitch stays 76 pt, so density does not drop.
    func testRowPitchIs76Points() throws {
        let app = launch("catalog3")
        for index in 0..<3 { XCTAssertTrue(rowGet(app, index).waitForExistence(timeout: fixtureWait)) }
        let first = rowGet(app, 0).frame.midY
        let second = rowGet(app, 1).frame.midY
        let third = rowGet(app, 2).frame.midY
        XCTAssertEqual(second - first, SpecPoints.rowPitch, accuracy: 1.5, "Rows 0 and 1 must be 76 pt apart (SPEC L107).")
        XCTAssertEqual(third - second, SpecPoints.rowPitch, accuracy: 1.5, "Rows 1 and 2 must be 76 pt apart (SPEC L107).")
    }

    /// SPEC L95 and L171 (check 1): the tap area is 44 pt tall although the capsule is drawn 30 pt. A tap just above
    /// (row 0) and just below (row 1) the drawn capsule still starts the install and does not open the app page.
    /// The spec text says "8 pt above or below"; 30 pt drawn inside a 44 pt area leaves 7 pt, so this test taps 6 pt out.
    func testTapJustAboveAndBelowTheDrawnCapsuleStartsTheInstall() throws {
        let app = launch("catalog3")
        XCTAssertTrue(rowGet(app, 0).waitForExistence(timeout: fixtureWait))

        var shot = try snapshot(app)
        let capsule0 = try XCTUnwrap(drawnBounds(of: rowGet(app, 0), in: shot.image))
        tap(app, x: capsule0.midX, y: capsule0.minY - 6)
        XCTAssertTrue(waitForStateToLeaveGet(rowGet(app, 0)), "A tap 6 pt above the drawn capsule must start the install; the tap area is 44 pt tall (SPEC L95). State: \(stateText(rowGet(app, 0)))")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.app).exists, "A tap on the Get tap area must not open the app page (SPEC L58, L115).")

        shot = try snapshot(app)
        let capsule1 = try XCTUnwrap(drawnBounds(of: rowGet(app, 1), in: shot.image))
        tap(app, x: capsule1.midX, y: capsule1.maxY + 6)
        XCTAssertTrue(waitForStateToLeaveGet(rowGet(app, 1)), "A tap 6 pt below the drawn capsule must start the install (SPEC L95). State: \(stateText(rowGet(app, 1)))")
        XCTAssertFalse(app.element(NativeStoreIdentifiers.app).exists, "A tap on the Get tap area must not open the app page (SPEC L58, L115).")
    }

    /// SPEC L109 and L115: 12 pt separates the text from Get so the tap areas do not touch. A tap 6 pt left of the
    /// capsule is a row tap: it opens the app page and installs nothing.
    func testTapInTheGapLeftOfTheCapsuleOpensThePageAndInstallsNothing() throws {
        let app = launch("catalog3")
        XCTAssertTrue(rowGet(app, 0).waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: rowGet(app, 0), in: shot.image))
        tap(app, x: capsule.minX - 6, y: capsule.midY)
        XCTAssertTrue(app.element(NativeStoreIdentifiers.app).waitForExistence(timeout: fixtureWait), "A tap 6 pt left of the capsule is outside the Get tap area and must open the app page (SPEC L109, L115).")
        let pageGet = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(pageGet.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(pageGet.label.hasPrefix("Get"), "Nothing may have been installed by a tap beside the capsule. Page Get reads \"\(pageGet.label)\" (SPEC L115).")
    }

    /// SPEC L171 (check 1) and L115: a tap on the summary text opens the app page.
    func testTapOnTheSummaryTextOpensTheAppPage() throws {
        let app = launch("catalog3")
        openAppPageFromRow(app, index: 0)
    }

    /// SPEC L98 and L178 (check 8): one control, one frame. The capsule keeps its width from Get to the state after
    /// the tap (fixtures end at a failed install with a retry label), so the text column does not re-wrap.
    func testCapsuleKeepsItsWidthWhileTheInstallRuns() throws {
        let app = launch("catalog3")
        let get = rowGet(app, 0)
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait))
        var shot = try snapshot(app)
        let before = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        tap(app, x: before.midX, y: before.midY)

        shot = try snapshot(app)
        let during = try XCTUnwrap(drawnBounds(of: rowGet(app, 0), in: shot.image), "Nothing is drawn for the capsule right after the tap.")
        // SPEC 4.2: a press may scale to 0.96; the settled frame still stays fixed.
        XCTAssertGreaterThanOrEqual(during.width, before.width * 0.96 - SpecPoints.drawnTolerance)
        XCTAssertLessThanOrEqual(during.width, before.width + SpecPoints.drawnTolerance)
        XCTAssertGreaterThanOrEqual(during.height, before.height * 0.96 - SpecPoints.drawnTolerance)
        XCTAssertLessThanOrEqual(during.height, before.height + SpecPoints.drawnTolerance)

        let settled = NSPredicate(format: "value BEGINSWITH 'Failed' OR value CONTAINS 'Try again' OR value BEGINSWITH 'Retry'")
        let expectation = XCTNSPredicateExpectation(predicate: settled, object: rowGet(app, 0))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed, "The install must settle. State: \(stateText(rowGet(app, 0)))")
        shot = try snapshot(app)
        let after = try XCTUnwrap(drawnBounds(of: rowGet(app, 0), in: shot.image), "Nothing is drawn for the capsule after the install settled.")
        XCTAssertEqual(after.width, before.width, accuracy: SpecPoints.drawnTolerance, "After the install settled the capsule is \(after.width) pt wide, it was \(before.width) pt as Get (SPEC L98, L178).")
        XCTAssertEqual(after.height, before.height, accuracy: SpecPoints.drawnTolerance, "After the install settled the capsule changed height (SPEC L98).")
    }

    /// SPEC L111, L174 (check 4): at the default size nothing is cut off with "...". The full name and the whole
    /// summary are on screen (the summary may take two lines).
    func testNameAndSummaryAreNotCutOffAtTheDefaultSize() throws {
        let app = launch("catalog3")
        let get = rowGet(app, 0)
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        let textColumn = CGRect(x: 84, y: capsule.midY - 34, width: max(60, capsule.minX - 84 - 4), height: 68)
        let lines = try recognizedLines(in: shot.cgImage, pixelsPerPoint: shot.image.pixelsPerPoint, rect: textColumn)
        assertNoCutOffText(lines, contains: ["Fixture App", "number"], "Row 0 text")
    }
}

// MARK: - Browse page, chips, search entry (SPEC section 4.6)

final class StoreBrowseProportionsUITests: StoreProportionsTestCase {
    /// SPEC L143, L27, L60: the Home search entry is 44 pt tall (it was 46) and sits inside the 16 pt gutters.
    func testHomeSearchEntryIs44TallInsideTheSixteenPointGutters() throws {
        let app = launch("catalog3")
        let entry = app.element(NativeStoreIdentifiers.homeSearchEntry)
        XCTAssertTrue(entry.waitForExistence(timeout: fixtureWait))
        let width = windowFrame(app).width
        XCTAssertEqual(entry.frame.height, 44, accuracy: 1, "The Home search entry must be 44 pt tall (SPEC L143).")
        XCTAssertEqual(entry.frame.minX, SpecPoints.gutter, accuracy: 1, "The search entry must start at the 16 pt gutter (SPEC L52, L60).")
        XCTAssertEqual(entry.frame.maxX, width - SpecPoints.gutter, accuracy: 1, "The search entry must end at the 16 pt gutter (SPEC L52, L60).")
    }

    /// SPEC L144, L58: a category chip is drawn 36 pt tall and its tap area is 44 pt tall, with 8 pt between chips.
    /// The chip's tap area is read from the button's frame (the identifier sits on the tap area).
    func testCategoryChipIsDrawn36TallWithA44TapAreaAndEightPointGaps() throws {
        let app = launch("catalog100")
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.home.category-chip.'"))
        let first = chips.element(boundBy: 0)
        let second = chips.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: fixtureWait), "Category chips must be on Browse at 100 apps.")
        XCTAssertTrue(second.exists)
        XCTAssertGreaterThanOrEqual(first.frame.height, SpecPoints.tapMinimum - 0.5, "A chip's tap area must be 44 pt tall (SPEC L144, L58). Frame height: \(first.frame.height)")
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: first, in: shot.image), "Nothing is drawn for the first chip.")
        XCTAssertEqual(drawn.height, 36, accuracy: SpecPoints.drawnTolerance, "A chip must be drawn 36 pt tall, it is 44 pt today (SPEC L144, L47 table).")
        XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 7.5, "Chips must be 8 pt apart so tap areas do not overlap (SPEC L144).")
    }
}

// MARK: - Category page (SPEC section 5)

final class StoreCategoryProportionsUITests: StoreProportionsTestCase {
    private func openFirstCategory(_ app: XCUIApplication) {
        let all = app.buttons[NativeStoreIdentifiers.homeBrowseAllCategories]
        // Mutation: a missing Browse all categories row still fails before either category oracle (U10, U11).
        XCTAssertTrue(app.scrollUntilExists(all), "Browse all categories (\(NativeStoreIdentifiers.homeBrowseAllCategories)) must become visible after scrolling.")
        XCTAssertTrue(all.waitForExistence(timeout: fixtureWait))
        all.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.categories.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait))
        row.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.category).waitForExistence(timeout: fixtureWait))
    }

    /// SPEC L153, L177 (check 7): the category name is on the screen once, at the top and after scrolling.
    func testCategoryNameShowsOnce() throws {
        let app = launch("catalog100")
        openFirstCategory(app)
        let title = app.staticTexts[NativeStoreIdentifiers.categoryTitle]
        XCTAssertTrue(title.waitForExistence(timeout: fixtureWait))
        let name = title.label
        XCTAssertFalse(name.isEmpty, "The category heading has no text.")
        let window = windowFrame(app)
        func visibleCopies() -> Int {
            app.staticTexts.matching(NSPredicate(format: "label == %@", name)).allElementsBoundByIndex.filter {
                $0.exists && $0.isHittable && window.intersects($0.frame)
            }.count
        }
        XCTAssertEqual(visibleCopies(), 1, "\"\(name)\" must show once at the top of the Category page, not in the top bar and again as a heading (SPEC L153, L177).")
        app.element(NativeStoreIdentifiers.category).swipeUp()
        XCTAssertLessThanOrEqual(visibleCopies(), 1, "\"\(name)\" must never show twice after scrolling either (SPEC L153).")
    }

    /// SPEC L153, L106, L175 (check 5): Category rows start at the 16 pt gutter (the icon was at 22 pt) and use the
    /// same 30 pt tonal Get capsule as Browse.
    func testCategoryRowsUseTheSixteenPointGutterAndTheSmallCapsule() throws {
        let app = launch("catalog100")
        openFirstCategory(app)
        let get = firstRowGet(app)
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait), "The Category page must list rows.")
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        XCTAssertEqual(capsule.height, SpecPoints.rowCapsuleHeight, accuracy: SpecPoints.drawnTolerance, "Category rows use the same 30 pt capsule as Browse (SPEC L88).")
        let icon = try XCTUnwrap(rowIconBounds(centeredOn: capsule.midY, in: shot.image))
        XCTAssertEqual(icon.minX, SpecPoints.gutter, accuracy: 1.5, "Category row icons must start at the 16 pt gutter, not 22 pt (SPEC L153).")
        XCTAssertEqual(icon.width, SpecPoints.rowIcon, accuracy: 2, "Category row icons are 56 pt (SPEC L105).")
    }
}

// MARK: - App page (SPEC section 4.5)

final class StoreAppPageProportionsUITests: StoreProportionsTestCase {
    private func openPage(_ app: XCUIApplication) {
        openAppPageFromRow(app, index: 1)
        XCTAssertTrue(app.buttons[NativeStoreIdentifiers.appGet].waitForExistence(timeout: fixtureWait))
    }

    /// SPEC L128, L90, L172 (check 2 and 3), L10 owner complaint: the page Get is a small solid blue capsule
    /// (32 pt tall, at least 96 wide), not a 362 x 44 bar, and it is the only solid blue capsule on screen.
    func testPageGetIsASmallSolidCapsuleNotAFullWidthBar() throws {
        let app = launch("catalog3")
        openPage(app)
        let get = app.buttons[NativeStoreIdentifiers.appGet]
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: get, in: shot.image), "Nothing is drawn for the page Get.")
        XCTAssertEqual(drawn.height, SpecPoints.pageCapsuleHeight, accuracy: SpecPoints.drawnTolerance, "The page Get capsule must be 32 pt tall, it is 44 pt today (SPEC L90, L128).")
        XCTAssertGreaterThanOrEqual(drawn.width, SpecPoints.pageCapsuleMinWidth - 1, "The page Get capsule must be at least 96 pt wide (SPEC L90).")
        XCTAssertLessThanOrEqual(drawn.width, windowFrame(app).width - 2 * SpecPoints.gutter - SpecPoints.pageIcon - 16 + SpecPoints.drawnTolerance, "The page Get capsule must fit beside the 96 pt icon and 16 pt header gap, inside the gutters; its width may grow with its label (SPEC section 4.2, section 4.5).")
        let fill = fillColor(of: drawn, in: shot.image)
        XCTAssertTrue(fill.isSolidBlue, "The page Get is the one solid blue capsule (SPEC L90). Fill read as \(fill).")
        let slabs = shot.image.solidBlobs(minWidth: 60, minHeight: 24, minAspect: 2, minFill: 0.6) { $0.isSolidBlue }
        XCTAssertEqual(slabs.count, 1, "Exactly one solid blue capsule may be on the app page screen (SPEC L172 check 3). Found \(slabs).")
    }

    /// SPEC L128, L127: the Get capsule sits in the header, left aligned with the text column beside the icon,
    /// and its bottom lines up with the bottom of the icon.
    func testPageGetSitsInTheHeaderBesideTheIconBottomAligned() throws {
        let app = launch("catalog3")
        openPage(app)
        let get = app.buttons[NativeStoreIdentifiers.appGet]
        let icon = app.element(NativeStoreIdentifiers.appIcon)
        XCTAssertTrue(icon.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        XCTAssertGreaterThanOrEqual(drawn.minX, icon.frame.maxX + 8, "The Get capsule must sit to the right of the icon, in the text column (SPEC L127, L128). Capsule x \(drawn.minX), icon right edge \(icon.frame.maxX)")
        XCTAssertGreaterThanOrEqual(drawn.minY, icon.frame.minY - 1, "The Get capsule must not start above the icon (SPEC L127).")
        XCTAssertLessThanOrEqual(drawn.maxY, icon.frame.maxY + 1, "The Get capsule must end inside the header, level with the bottom of the icon (SPEC L127).")
        XCTAssertLessThanOrEqual(icon.frame.maxY - drawn.maxY, 7, "The Get capsule must be bottom aligned with the icon, within the 6 pt of tap padding (SPEC L127). Gap: \(icon.frame.maxY - drawn.maxY)")
    }

    /// SPEC L90, L95, L128: the page Get tap area is 44 pt tall although 32 pt is drawn; 5 pt above and below still tap it.
    func testPageGetTapAreaIs44Tall() throws {
        let app = launch("catalog3")
        openPage(app)
        let get = app.buttons[NativeStoreIdentifiers.appGet]
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        tap(app, x: drawn.midX, y: drawn.maxY + 5)
        let advanced = NSPredicate(format: "NOT (label BEGINSWITH 'Get')")
        let expectation = XCTNSPredicateExpectation(predicate: advanced, object: get)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: fixtureWait), .completed, "A tap 5 pt below the 32 pt capsule is inside the 44 pt tap area and must start the install (SPEC L95, L128). Label: \(get.label)")
    }

    /// SPEC L126, L125, L50: the icon is 96 pt (it was 88) at the 16 pt gutter (it was 20).
    func testIconIs96PointsAtTheSixteenPointGutter() throws {
        let app = launch("catalog3")
        openPage(app)
        let icon = app.element(NativeStoreIdentifiers.appIcon)
        XCTAssertTrue(icon.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(icon.frame.width, SpecPoints.pageIcon, accuracy: 1, "The app page icon must be 96 pt (SPEC L126, L50).")
        XCTAssertEqual(icon.frame.height, SpecPoints.pageIcon, accuracy: 1, "The app page icon must be 96 pt (SPEC L126, L50).")
        XCTAssertEqual(icon.frame.minX, SpecPoints.gutter, accuracy: 1, "The app page gutter is 16 pt, it was 20 (SPEC L125, L52).")
    }

    /// SPEC L129, L125, L175 (check 5): summary and facts are moved under the header, at the 16 pt gutter, one line each.
    func testSummaryAndFactsSitUnderTheHeaderOnOneLineEach() throws {
        let app = launch("catalog3")
        openPage(app)
        let icon = app.element(NativeStoreIdentifiers.appIcon)
        let summary = app.staticTexts[NativeStoreIdentifiers.appSummary]
        let facts = app.staticTexts[NativeStoreIdentifiers.appFacts]
        XCTAssertTrue(summary.waitForExistence(timeout: fixtureWait))
        XCTAssertTrue(facts.waitForExistence(timeout: fixtureWait))
        XCTAssertGreaterThanOrEqual(summary.frame.minY, icon.frame.maxY - 1, "The summary must sit below the header, not inside the narrow text column (SPEC L129).")
        XCTAssertEqual(summary.frame.minX, SpecPoints.gutter, accuracy: 1, "The summary starts at the 16 pt gutter (SPEC L129, L125).")
        XCTAssertEqual(facts.frame.minX, SpecPoints.gutter, accuracy: 1, "The facts line starts at the 16 pt gutter (SPEC L129, L125).")
        XCTAssertLessThanOrEqual(summary.frame.height, 24, "The summary is one line of 15 pt text (SPEC L129). Height: \(summary.frame.height)")
        XCTAssertLessThanOrEqual(facts.frame.height, 20, "The facts line is one line of 13 pt text (SPEC L129). Height: \(facts.frame.height)")
        XCTAssertGreaterThanOrEqual(facts.frame.minY, summary.frame.maxY, "The facts line is under the summary (SPEC L129).")
    }

    /// SPEC L172 (check 2): "What it can do" is on the first screen of the app page (iPhone 18 Pro is 874 pt tall;
    /// on a shorter screen this test is skipped because the spec number is for the tall screen).
    func testWhatItCanDoIsOnTheFirstScreen() throws {
        let app = launch("catalog3")
        openPage(app)
        let window = windowFrame(app)
        guard window.height >= 850 else { throw XCTSkip("SPEC L172 check 2 is stated for the iPhone 18 Pro screen (874 pt).") }
        let title = app.staticTexts["What it can do"]
        XCTAssertTrue(title.waitForExistence(timeout: fixtureWait), "The page needs a \"What it can do\" section title (SPEC L68).")
        XCTAssertLessThan(title.frame.maxY, window.maxY - 90, "\"What it can do\" must be visible on the first screen, above the tab bar, without scrolling (SPEC L172 check 2). Title bottom: \(title.frame.maxY)")
    }

    /// SPEC L68, L77, L176 (check 6), L29: the section title is 20 bold (title3, a 24 to 25 pt line) and the items
    /// under it are 15 pt (a 20 pt line), so the title is visibly the bigger one. Before, both were 17 pt.
    func testSectionTitleIsVisiblyBiggerThanTheItemsUnderIt() throws {
        let app = launch("catalog3")
        openPage(app)
        let title = app.staticTexts["What it can do"]
        XCTAssertTrue(title.waitForExistence(timeout: fixtureWait))
        XCTAssertGreaterThanOrEqual(title.frame.height, 23.5, "The section title must be 20 pt bold (a line of about 24 pt), it is 17 pt today (SPEC L68). Height: \(title.frame.height)")
        let permissions = app.element(NativeStoreIdentifiers.appPermissions)
        XCTAssertTrue(permissions.waitForExistence(timeout: fixtureWait), "What it can do must have its capability container.")
        // Mutation: an oversized capability title or a section title no bigger than its item still fails (S1).
        let item = permissions.staticTexts.matching(NSPredicate(format: "label != %@", "What it can do")).firstMatch
        guard item.waitForExistence(timeout: 2) else { throw XCTSkip("This fixture app has no checklist item under \"What it can do\" to compare the title with.") }
        XCTAssertLessThanOrEqual(item.frame.height, 21.5, "A checklist item is 15 pt text, a line of about 20 pt (SPEC L77). Height: \(item.frame.height)")
        XCTAssertGreaterThan(title.frame.height, item.frame.height + 2, "The section title must be visibly larger than the checklist items (SPEC L176).")
    }

    /// SPEC L163, L174 (check 4): the header text (name and by line) and the summary are not cut off.
    func testHeaderTextIsNotCutOff() throws {
        let app = launch("catalog3")
        openPage(app)
        let icon = app.element(NativeStoreIdentifiers.appIcon)
        let facts = app.staticTexts[NativeStoreIdentifiers.appFacts]
        XCTAssertTrue(facts.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let region = CGRect(x: SpecPoints.gutter, y: icon.frame.minY, width: windowFrame(app).width - 2 * SpecPoints.gutter, height: facts.frame.maxY - icon.frame.minY + 6)
        let lines = try recognizedLines(in: shot.cgImage, pixelsPerPoint: shot.image.pixelsPerPoint, rect: region)
        assertNoCutOffText(lines, contains: ["Fixture App 1", "By Publik", "number 1"], "App page header")
    }
}

// MARK: - Storage and My apps (SPEC section 4.6, 4.2)

final class StoreStorageProportionsUITests: StoreProportionsTestCase {
    private func openStorage(_ app: XCUIApplication) {
        app.storeTab(.myApps).tap()
        let line = app.element(NativeStoreIdentifiers.myAppsStorageLine)
        XCTAssertTrue(line.waitForExistence(timeout: fixtureWait))
        line.tap()
        XCTAssertTrue(app.element(NativeStoreIdentifiers.storage).waitForExistence(timeout: fixtureWait))
    }

    /// SPEC L146: Free up space is the one main action on the screen: full width inside the 16 pt gutters, 48 pt tall.
    func testFreeUpSpaceIs48TallAndFullWidthInsideTheGutters() throws {
        let app = launch("storage-full")
        openStorage(app)
        let button = app.buttons[NativeStoreIdentifiers.storageFreeUp]
        XCTAssertTrue(button.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: button, in: shot.image), "Nothing is drawn for Free up space.")
        XCTAssertEqual(drawn.height, 48, accuracy: SpecPoints.drawnTolerance, "Free up space must be drawn 48 pt tall (SPEC L146).")
        XCTAssertEqual(drawn.minX, SpecPoints.gutter, accuracy: 1.5, "Free up space starts at the 16 pt gutter (SPEC L146, L52).")
        XCTAssertEqual(drawn.maxX, windowFrame(app).width - SpecPoints.gutter, accuracy: 1.5, "Free up space ends at the 16 pt gutter, full width (SPEC L146).")
    }

    /// SPEC L147 and L52: the storage bar is 12 pt tall (was 10) and the Storage screen uses the 16 pt gutter (was 20).
    func testStorageBarIs12TallAndTheScreenUsesTheSixteenPointGutter() throws {
        let app = launch("storage-full")
        openStorage(app)
        let bar = app.element(NativeStoreIdentifiers.storageTotalBar)
        let device = app.staticTexts[NativeStoreIdentifiers.storageDeviceLine]
        XCTAssertTrue(bar.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(bar.frame.height, 12, accuracy: 1, "The storage bar must be 12 pt tall (SPEC L147).")
        XCTAssertTrue(device.waitForExistence(timeout: fixtureWait))
        XCTAssertEqual(device.frame.minX, SpecPoints.gutter, accuracy: 1, "Storage text starts at the 16 pt gutter, it was 20 pt (SPEC L52, L175 check 5).")
    }
}

final class StoreMyAppsProportionsUITests: StoreProportionsTestCase {
    private let kneecap = "publik.kneecap"

    /// SPEC L88, L178 (check 8), L101: in My apps the installed app's Open capsule is the same small capsule as Get:
    /// 30 pt tall, 72 to 96 wide, tonal, and its row icon is 56 pt at the 16 pt gutter.
    func testOpenCapsuleIsTheSameSmallCapsuleAsGet() throws {
        let app = launch("catalog3")
        app.storeTab(.myApps).tap()
        let open = app.buttons[NativeStoreIdentifiers.open(kneecap)]
        XCTAssertTrue(open.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let drawn = try XCTUnwrap(drawnBounds(of: open, in: shot.image), "Nothing is drawn for Open.")
        XCTAssertEqual(drawn.height, SpecPoints.rowCapsuleHeight, accuracy: SpecPoints.drawnTolerance, "The Open capsule must be 30 pt tall like Get (SPEC L88, L178).")
        XCTAssertGreaterThanOrEqual(drawn.width, SpecPoints.rowCapsuleMinWidth - 1, "Open is narrower than 72 pt (SPEC L88).")
        XCTAssertLessThanOrEqual(drawn.width, SpecPoints.rowCapsuleMaxWidth + 1, "Open is wider than 96 pt (SPEC L88).")
        assertGetIsTonalNotSolid(drawn, surface: surfaceColor(around: open, in: shot.image), image: shot.image, "Open")
        let icon = try XCTUnwrap(rowIconBounds(centeredOn: drawn.midY, in: shot.image), "No icon is drawn in the My apps row.")
        XCTAssertEqual(icon.width, SpecPoints.rowIcon, accuracy: 2, "The My apps row icon is 56 pt (SPEC L101, L105).")
        XCTAssertEqual(icon.minX, SpecPoints.gutter, accuracy: 1.5, "The My apps row icon starts at the 16 pt gutter (SPEC L106).")
    }
}

// MARK: - One accessibility text size (SPEC section 6, L154 to L165, check 9 at L179)

final class StoreAccessibilitySizeProportionsUITests: StoreProportionsTestCase {
    /// SPEC L158, L160, L179 (check 9): at the largest accessibility size a row is stacked. The Get capsule is at
    /// least 44 pt tall, is not full width, sits on its own line below the text, left aligned with the text (not at
    /// the icon), and nothing runs off the right edge.
    func testRowStacksTheCapsuleUnderTheTextAtTheLargestAccessibilitySize() throws {
        let app = launch("catalog3", textSize: StoreProportionsTestCase.accessibilityLargest)
        let get = rowGet(app, 0)
        // Mutation: a missing Get fails here; a full-width capsule still fails the unchanged pixel oracle (U13).
        XCTAssertTrue(app.scrollUntilExists(get), "Row Get (\(NativeStoreIdentifiers.rowGet(NativeStoreFixtureFacts.slug(0)))) must become visible after scrolling.")
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait * 2))
        // Hittability alone permits a partly clipped capsule. Expose its whole tap frame before measuring.
        let viewport = [app.scrollViews.firstMatch, app.collectionViews.firstMatch, app.tables.firstMatch]
            .first(where: { $0.exists }) ?? app.windows.firstMatch
        if !viewport.frame.contains(get.frame) {
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.75))
            let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTAssertTrue(viewport.frame.contains(get.frame), "Row Get must be fully inside the scrolling viewport before the screenshot.")
        let window = windowFrame(app)
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: get, in: shot.image), "Nothing is drawn for Get.")
        XCTAssertGreaterThanOrEqual(capsule.height, SpecPoints.tapMinimum - 1, "At an accessibility size the Get capsule is at least 44 pt tall (SPEC L158). Height: \(capsule.height)")
        XCTAssertLessThan(capsule.width, window.width * 0.6, "The capsule must keep its natural width, not run full width (SPEC L160). Width: \(capsule.width)")
        XCTAssertLessThanOrEqual(capsule.maxX, window.width - SpecPoints.gutter + 1, "Nothing may run past the right gutter (SPEC L164, L179).")
        XCTAssertGreaterThanOrEqual(capsule.minX, SpecPoints.gutter + SpecPoints.rowIcon + 12 - 2, "The capsule must be left aligned with the text, which starts after the icon, not at the icon (SPEC L160). Capsule x: \(capsule.minX)")

        // On its own line: nothing else is drawn level with the capsule.
        let surface = shot.image.backgroundColor(around: CGRect(x: 0, y: capsule.minY - 12, width: window.width, height: capsule.height + 24))
        let left = CGRect(x: 0, y: capsule.minY, width: max(0, capsule.minX - 4), height: capsule.height)
        let right = CGRect(x: capsule.maxX + 4, y: capsule.minY, width: max(0, window.width - capsule.maxX - 8), height: capsule.height)
        XCTAssertFalse(shot.image.hasInk(in: left, background: surface), "Something is drawn to the left of the capsule on its line; the capsule must drop under the text (SPEC L160).")
        XCTAssertFalse(shot.image.hasInk(in: right, background: surface), "Something is drawn to the right of the capsule on its line; the capsule must drop under the text (SPEC L160).")
    }

    /// SPEC L159, L179 (check 9): the row icon grows with the text size, capped at 72 pt, so rows do not stay
    /// tiny beside large text.
    func testRowIconGrowsButStopsAt72AtTheLargestAccessibilitySize() throws {
        // The bundled seed has visible verified artwork (design 13.3, sizing 6).
        let app = launch("offline-cold", textSize: StoreProportionsTestCase.accessibilityLargest)
        let get = app.element(NativeStoreIdentifiers.rowGet("kneecap"))
        let rowElement = app.element(NativeStoreIdentifiers.row("kneecap"))
        // Mutation: a missing icon or an icon outside the unchanged 64...72.5 pt bound still fails (U35).
        XCTAssertTrue(app.scrollUntilExists(rowElement), "Fixture row (\(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(0)))) must be on screen before the icon scan.")
        XCTAssertTrue(rowElement.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        // The icon is the only thing in the far-left column; scan from just above the row to below the icon.
        let column = CGRect(x: 8, y: rowElement.frame.minY - 8, width: 52, height: 118)
        let icon = try XCTUnwrap(shot.image.inkBounds(in: column, background: shot.image.backgroundColor(around: column)), "No icon is drawn at the left of the row.")
        XCTAssertGreaterThanOrEqual(icon.height, 64, "At the largest accessibility size the row icon must have grown from 56 pt (SPEC L159). Height: \(icon.height)")
        XCTAssertLessThanOrEqual(icon.height, 72.5, "The row icon is capped at 72 pt (SPEC L159). Height: \(icon.height)")
    }

    /// SPEC L179 (check 9), L80, L143: "everything in the store grows together (no giant footer next to tiny rows)":
    /// the search entry (body text) is taller than its 44 pt default.
    func testHomeSearchEntryGrowsWithTheTextSize() throws {
        let app = launch("catalog3", textSize: StoreProportionsTestCase.accessibilityLargest)
        let entry = app.element(NativeStoreIdentifiers.homeSearchEntry)
        XCTAssertTrue(entry.waitForExistence(timeout: fixtureWait * 2))
        XCTAssertGreaterThanOrEqual(entry.frame.height, 60, "The search entry uses the body text style and must grow at the largest accessibility size (SPEC L80, L157, L179). Height: \(entry.frame.height)")
        XCTAssertLessThanOrEqual(entry.frame.maxX, windowFrame(app).width - SpecPoints.gutter + 1, "The search entry must stay inside the gutters, no sideways scrolling (SPEC L164).")
    }

    /// SPEC L161, L158: the app page header stacks at an accessibility size: icon, then name, then the Get capsule
    /// (left aligned with the name, at least 44 pt tall), then the summary.
    func testAppPageHeaderStacksAtTheLargestAccessibilitySize() throws {
        let app = launch("catalog3", textSize: StoreProportionsTestCase.accessibilityLargest)
        let row = app.element(NativeStoreIdentifiers.row(NativeStoreFixtureFacts.slug(1)))
        XCTAssertTrue(row.waitForExistence(timeout: fixtureWait * 2))
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.12)).tap()
        let get = app.buttons[NativeStoreIdentifiers.appGet]
        XCTAssertTrue(get.waitForExistence(timeout: fixtureWait * 2), "Tapping the row text must open the app page.")
        let icon = app.element(NativeStoreIdentifiers.appIcon)
        let name = app.staticTexts[NativeStoreIdentifiers.appName]
        XCTAssertTrue(name.waitForExistence(timeout: fixtureWait))
        let shot = try snapshot(app)
        let capsule = try XCTUnwrap(drawnBounds(of: get, in: shot.image))
        XCTAssertGreaterThanOrEqual(name.frame.minY, icon.frame.maxY - 1, "The name goes under the icon at an accessibility size (SPEC L161).")
        XCTAssertGreaterThanOrEqual(capsule.minY, name.frame.maxY - 1, "The Get capsule goes under the name (SPEC L161).")
        XCTAssertGreaterThanOrEqual(capsule.height, SpecPoints.tapMinimum - 1, "The Get capsule is at least 44 pt tall at an accessibility size (SPEC L158). Height: \(capsule.height)")
        XCTAssertEqual(capsule.minX, name.frame.minX, accuracy: 2, "The Get capsule is left aligned with the name (SPEC L161).")
        XCTAssertLessThan(capsule.width, windowFrame(app).width * 0.75, "The Get capsule keeps its natural width (SPEC L161).")
        let summary = app.staticTexts[NativeStoreIdentifiers.appSummary]
        if summary.exists {
            XCTAssertGreaterThanOrEqual(summary.frame.minY, capsule.maxY - 1, "The summary goes under the Get capsule (SPEC L161).")
        }
    }

    /// SPEC L162, L158: at an accessibility size category chips are one per line, each with a 44 pt tap area.
    func testCategoryChipsGoOnePerLineAtTheLargestAccessibilitySize() throws {
        let app = launch("catalog100", textSize: StoreProportionsTestCase.accessibilityLargest)
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'iris.store.home.category-chip.'"))
        let first = chips.element(boundBy: 0)
        let second = chips.element(boundBy: 1)
        XCTAssertTrue(first.waitForExistence(timeout: fixtureWait * 2), "Chips must be on Browse at 100 apps.")
        XCTAssertTrue(second.exists)
        XCTAssertGreaterThanOrEqual(first.frame.height, SpecPoints.tapMinimum - 0.5, "Chip tap area is at least 44 pt tall (SPEC L162).")
        XCTAssertGreaterThanOrEqual(second.frame.minY, first.frame.maxY - 1, "Chips are one per line at an accessibility size, the second is below the first (SPEC L162). First \(first.frame), second \(second.frame)")
        XCTAssertLessThanOrEqual(second.frame.maxX, windowFrame(app).width + 0.5, "No sideways scrolling: a chip runs past the screen edge (SPEC L164).")
    }
}
