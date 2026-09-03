//
//  Test6PointingReproTests.swift
//  leanring-buddyTests
//
//  ROOT CAUSE C — pointing re-fires on every app activation, and nothing ever
//  asks whether the thing it found can be seen.
//
//  WHAT THE READER SAW, in his own words:
//
//    "Does not point correctly when asking you to install cmake."
//    "It keeps pointing to completely random places on the computer, like the
//     top of the screen"
//    "it seems to point incorrectly when the tab is not visible on the screen,
//     or when the thing you need to install is not on the screen"
//    "It also keeps pointing multiple times for whatever reason, whenever I
//     open the browser, even after installing it."
//    "Seems to point every time I interact with the browser that is default."
//    "the pointer randomly went close to edge of the screen, and the text moved
//     off the screen"
//
//  Three separate holes, all in the same two files, and every one of them is
//  reachable without a screen because the deciding code is already pure.
//
//  1. NOTHING IS DEBOUNCED PER STEP. `GuideSessionController` observes
//     `NSWorkspace.didActivateApplicationNotification` and re-runs the whole
//     ladder. There IS a 400ms coalescer on it, but a coalescer only merges one
//     BURST: two deliberate visits to the browser a minute apart are two
//     settled activations, so they are two full re-resolutions and two calls to
//     `sendTheEyeTo` — on a step that has not changed, at a target that has not
//     moved. And the eye really does fly again each time, because
//     `OverlayWindow.finishNavigationAndResumeFollowing()` calls
//     `CompanionManager.clearDetectedElementLocation()` when the eye goes home,
//     which nils `detectedElementScreenLocation` — so the next identical
//     location is a *change* as far as `.onChange` is concerned, and the whole
//     fly-out / say-the-step-title / hold-three-seconds / fly-home performance
//     runs from the top. That is "it keeps pointing multiple times whenever I
//     open the browser, even after installing it", exactly.
//
//  2. NOTHING CHECKS VISIBILITY. `grep -n 'offscreen|notVisible|isVisible|
//     onScreen|clamp'` over `GuidePointing.swift` and `GuideStepPointing.swift`
//     returns nothing. A rectangle the accessibility tree hands back is aimed
//     at whether or not any part of it is on a display.
//
//  3. NOTHING IS CLAMPED. `GuideStepPointingCoordinator.aimPoint` returns the
//     rectangle's centre and `displayFrame(containing:)` falls back to the main
//     display when no screen contains that centre — so the outcome can say
//     "fly to this point, on that display" about a point that is not on that
//     display at all.
//
//  MEASURED ON THIS MAC while writing these (a 14" MacBook Pro, one display):
//
//      screen.frame        = (0, 0, 1512, 982)
//      screen.visibleFrame = (34, 0, 1478, 944)
//
//  so there is a 38pt menu-bar band across the top that is inside `frame` and
//  outside `visibleFrame`. Every regular application publishes its menu bar in
//  the accessibility tree, and every menu title's rect centres on y = 963.5 —
//  inside that band, above everything `visibleFrame` says is usable.
//
//  Running the exact `normalize`/`matches`/depth-16 walk that
//  `SystemGuideTargetLocator` performs, against the live tree, the step title
//  "Open Terminal" — which is the FIRST STEP of the stubbed desktop guide in
//  `GuideSessionTests`, and of most real ones — resolves like this:
//
//      "Open Terminal" -> AX label "Terminal" rect (44.0, 945.0, 76.0, 37.0)
//                         aim (82.0, 963.5)   OUTSIDE every visibleFrame
//                         path …/AXMenuBar/AXMenuBarItem
//
//  `matches` accepts it because it tests containment both ways, so the short
//  menu title "terminal" is contained in the wanted "open terminal", and the
//  walk returns the first thing it matches. The eye is then flown to the top
//  left of the screen, under the menu bar. "It keeps pointing to completely
//  random places on the computer, like the top of the screen."
//
//  The app already knows the rule this pointing path is missing, and already
//  applies it on the one path a reader can see: `OverlayEyeRestingPlace`
//  refuses to let the eye be DRAGGED closer than
//  `smallestDistanceFromAnyEdge` (44pt) to any edge, "so a 64pt disc plus its
//  drop shadow clears the menu bar … rather than tucking under it". Nothing
//  applies that rule when the guide FLIES the eye. These tests hold the flown
//  eye to the dragged eye's own standard.
//

import AppKit
import Foundation
import Testing
@testable import Iris

@MainActor
@Suite("Root cause C — the eye re-fires on every activation and never checks it can be seen")
struct Test6PointingReproTests {

    // MARK: - A locator that answers with whatever the tree would have said

    /// Stands in for the accessibility walk and the model.
    ///
    /// It does not pretend to find anything clever: it hands back one rectangle,
    /// which is exactly what `SystemGuideTargetLocator` does once its walk has
    /// matched something. What is under test is what the coordinator DOES with
    /// that rectangle, so the rectangle is the input.
    final class AccessibilityTreeAnswering: GuideTargetLocating {
        var rectangleTheTreeReports: CGRect?

        private(set) var timesTheTreeWasWalked = 0
        private(set) var timesTheModelWasAsked = 0

        init(rectangleTheTreeReports: CGRect?) {
            self.rectangleTheTreeReports = rectangleTheTreeReports
        }

        func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
            timesTheTreeWasWalked += 1
            return rectangleTheTreeReports
        }

        func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
            timesTheTreeWasWalked += 1
            return rectangleTheTreeReports
        }

        func locateFocusedWindow(ofApp bundleIdentifier: String) -> CGRect? {
            timesTheTreeWasWalked += 1
            return rectangleTheTreeReports
        }

        func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
            timesTheModelWasAsked += 1
            return rectangleTheTreeReports
        }
    }

    /// An authored target, because authored is the path that does not spend a
    /// model call and so keeps these tests about geometry rather than budget.
    private static func authoredTarget(
        _ descriptor: String,
        isWindow: Bool = false,
        inApp: String? = nil
    ) -> GuidePointTarget {
        GuidePointTarget(
            descriptor: descriptor,
            inApp: inApp,
            isWindow: isWindow,
            provenance: .authoredAndFound
        )
    }

    /// The step title is not decoration here: it is the sentence the eye says
    /// on arrival (`GuideSessionController` hands `step.title` straight to
    /// `sendTheEyeTo`), so it is also what has to fit on the screen beside the
    /// eye. Any test about the right-hand edge has to name it.
    private static func resolve(
        aimingAt target: GuidePointTarget,
        whereTheTreeSaysItIs rectangle: CGRect,
        andTheEyeWillSay stepTitle: String = "Install CMake"
    ) async -> GuideStepPointingOutcome {
        await GuideStepPointingCoordinator.resolve(
            decision: .pointAt(target),
            stepTitle: stepTitle,
            stepBody: "Homebrew puts it on your PATH.",
            mayAskTheModel: false,
            using: AccessibilityTreeAnswering(rectangleTheTreeReports: rectangle)
        )
    }

    // MARK: - What "on screen" has to mean

    /// The eye's own rule for how close to an edge it may be, taken from the
    /// path that already enforces it rather than invented here.
    private static var roomTheEyeNeedsFromAnyEdge: CGFloat {
        OverlayEyeRestingPlace.smallestDistanceFromAnyEdge
    }

    /// How far right of the eye's centre the WHOLE of what it says has to fit.
    ///
    /// `OverlayWindow` positions the speech bubble's left edge at
    /// `cursorPosition.x + horizontalGapFromTheEyeToWhatItSays` and draws it
    /// `.fixedSize()`, so it never wraps and never flips to the eye's other
    /// side: anything past the display's right edge is clipped away.
    ///
    /// This used to assert only the gap — where the FIRST CHARACTER begins —
    /// and so passed while the reader's actual complaint ("the text moved off
    /// the screen") was still true in full. Worse, the gap is the exact x at
    /// which the sentence STARTS at the edge: an eye placed on that boundary
    /// shows four points of a hundred-and-thirty-point bubble. The measurement
    /// has to be the sentence's own width, which is what this now is.
    private static func roomTheLabelNeedsToTheRightOfTheEye(saying whatTheEyeSays: String) -> CGFloat {
        OverlayEyeInteractionGeometry().horizontalGapFromTheCentreToWhatTheEyeSays
            + GuideStepPointingCoordinator.widthOfTheBubbleTheEyeWillSpeakIn(saying: whatTheEyeSays)
    }

    /// Whether a point is somewhere the eye can actually sit: on a display, in
    /// the part of it macOS says is usable, far enough in that the eye is not
    /// half under the menu bar or off an edge.
    private static func theEyeCanSitAt(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame
                .insetBy(dx: roomTheEyeNeedsFromAnyEdge, dy: roomTheEyeNeedsFromAnyEdge)
                .contains(point)
        }
    }

    private static func describeTheScreens() -> String {
        NSScreen.screens
            .map { "frame \($0.frame) visible \($0.visibleFrame)" }
            .joined(separator: " | ")
    }

    // MARK: - "the pointer randomly went close to edge of the screen"

    @Test("the eye is never sent to a point the display it was handed does not contain")
    func aWindowHangingOffTheEdgeSendsTheEyeOffTheDisplayEntirely() async throws {
        let screen = try #require(NSScreen.main)

        // A Terminal the reader has shoved mostly off the right of the display,
        // which is an ordinary thing to do with a window you are only glancing
        // at. Its left edge is on screen, so the accessibility tree reports it
        // and the reader can genuinely see it — but its CENTRE is not on any
        // display, and the centre is what `aimPoint` returns.
        let windowMostlyOffTheRightEdge = CGRect(
            x: screen.frame.maxX - 120,
            y: screen.visibleFrame.midY - 250,
            width: 800,
            height: 500
        )

        let outcome = await Self.resolve(
            aimingAt: Self.authoredTarget("the Terminal window", isWindow: true, inApp: "com.apple.Terminal"),
            whereTheTreeSaysItIs: windowMostlyOffTheRightEdge
        )

        print("""
        [repro] screens: \(Self.describeTheScreens())
        [repro] window the tree reported: \(windowMostlyOffTheRightEdge)
        [repro] decision: \(outcome.decision)
        [repro] eye was sent to: \(String(describing: outcome.screenLocation))
        [repro] on the display: \(String(describing: outcome.displayFrame))
        """)

        // Refusing this one outright is a perfectly good answer and the fix is
        // free to take it. What is not allowed is the third thing, which is what
        // happens today: a point handed over as if it were fine.
        guard let point = outcome.screenLocation else {
            #expect(outcome.displayFrame == nil, "a refusal must not still carry a display to fly to")
            return
        }
        let displayFrame = try #require(outcome.displayFrame)

        // The outcome hands the overlay a point and the display to animate it
        // on, and `OverlayWindow` picks the screen from the display frame. A
        // point outside the frame it came with is an instruction to fly off the
        // side of that screen.
        #expect(
            displayFrame.contains(point),
            "Iris told the eye to fly to \(point) on the display \(displayFrame), which does not contain it"
        )
        #expect(
            Self.theEyeCanSitAt(point),
            "the eye was aimed at \(point); no display has that point \(Self.roomTheEyeNeedsFromAnyEdge)pt inside its visible area (\(Self.describeTheScreens()))"
        )
    }

    @Test("and the text it says still fits on the screen when the target is at the edge")
    func aControlAgainstTheRightEdgeLeavesNoRoomForWhatTheEyeSays() async throws {
        let screen = try #require(NSScreen.main)

        // A small control hard against the right edge — an installer's "Next"
        // in a window the reader has pushed over there. Entirely on screen, so
        // nothing about it deserves a refusal; it is simply somewhere the eye
        // cannot stand and still be read.
        let controlAgainstTheRightEdge = CGRect(
            x: screen.visibleFrame.maxX - 26,
            y: screen.visibleFrame.midY,
            width: 22,
            height: 20
        )

        // A real step title, not a word: what the reader saw run off the screen
        // was a sentence, and a one-word label would let a clamp that reserves
        // almost nothing pass this test.
        let whatTheEyeWillSay = "Download the installer"

        let outcome = await Self.resolve(
            aimingAt: Self.authoredTarget("Continue"),
            whereTheTreeSaysItIs: controlAgainstTheRightEdge,
            andTheEyeWillSay: whatTheEyeWillSay
        )
        // This rectangle is wholly inside the display's visible area, so there
        // is nothing about it to refuse — refusing a control the reader can see
        // would take the feature away. The only correct answer is a point, and
        // it has to be a point the eye can stand on.
        let point = try #require(
            outcome.screenLocation,
            "this control is entirely on screen; Iris has to point at it, not give up on it"
        )
        let roomToTheRight = screen.visibleFrame.maxX - point.x
        let roomTheSentenceNeeds = Self.roomTheLabelNeedsToTheRightOfTheEye(saying: whatTheEyeWillSay)
        let whereTheBubbleWouldEnd = point.x
            + OverlayEyeInteractionGeometry().horizontalGapFromTheCentreToWhatTheEyeSays
            + GuideStepPointingCoordinator.widthOfTheBubbleTheEyeWillSpeakIn(saying: whatTheEyeWillSay)

        print("""
        [repro] control the tree reported: \(controlAgainstTheRightEdge)
        [repro] eye was sent to: \(point)
        [repro] screen to the right of the eye: \(roomToTheRight)pt
        [repro] "\(whatTheEyeWillSay)" needs \(roomTheSentenceNeeds)pt of it
        [repro] the bubble would end at x = \(whereTheBubbleWouldEnd), display ends at \(screen.visibleFrame.maxX)
        """)

        #expect(
            Self.theEyeCanSitAt(point),
            "the eye was aimed at \(point), which is not \(Self.roomTheEyeNeedsFromAnyEdge)pt inside any display's visible area"
        )
        // "the pointer randomly went close to edge of the screen, and the text
        // moved off the screen". The whole sentence, not its first character:
        // `OverlayWindow` draws the bubble `.fixedSize()` to the eye's right
        // with no wrap and no side-flip, so every point past `maxX` is clipped.
        #expect(
            roomToTheRight >= roomTheSentenceNeeds,
            """
            the eye was left \(roomToTheRight)pt from the right edge, and "\(whatTheEyeWillSay)" \
            needs \(roomTheSentenceNeeds)pt — the bubble would run to x = \(whereTheBubbleWouldEnd) \
            on a display that ends at \(screen.visibleFrame.maxX)
            """
        )
    }

    @Test("a step title too long for any screen still puts the eye somewhere sane")
    func anAbsurdlyLongStepTitleDoesNotShoveTheEyeIntoTheMiddleOfTheScreen() async throws {
        let screen = try #require(NSScreen.main)
        let aTitleNoDisplayCouldHold = String(repeating: "an unreasonably wordy step title ", count: 8)

        let outcome = await Self.resolve(
            aimingAt: Self.authoredTarget("Continue"),
            whereTheTreeSaysItIs: CGRect(
                x: screen.visibleFrame.maxX - 26,
                y: screen.visibleFrame.midY,
                width: 22,
                height: 20
            ),
            andTheEyeWillSay: aTitleNoDisplayCouldHold
        )
        let point = try #require(outcome.screenLocation)

        print("""
        [repro] bubble width for that title: \
        \(GuideStepPointingCoordinator.widthOfTheBubbleTheEyeWillSpeakIn(saying: aTitleNoDisplayCouldHold))pt
        [repro] display visible width: \(screen.visibleFrame.width)pt
        [repro] eye was sent to: \(point)
        """)

        // The reservation is capped, so an impossible sentence clips rather than
        // dragging the eye to the middle of the display pointing at nothing.
        #expect(Self.theEyeCanSitAt(point))
        #expect(
            point.x > screen.visibleFrame.midX,
            "the eye was pushed to \(point.x), left of the middle of the screen, by a step title alone"
        )
    }

    // MARK: - "like the top of the screen"

    @Test("the menu-bar band is not a place to park the eye")
    func aMatchInTheMenuBarPutsTheEyeUnderTheMenuBar() async throws {
        let screen = try #require(NSScreen.main)
        try #require(
            screen.frame.maxY > screen.visibleFrame.maxY,
            "this machine has no menu-bar band, so there is nothing here to reproduce"
        )

        // The shape a real menu title has, measured off the live accessibility
        // tree on this Mac: Terminal's own menu-bar item came back as
        // (44, 945, 76, 37) — the full height of the menu-bar band, centred
        // above visibleFrame.maxY. It is what the shipped walk returns for the
        // step title "Open Terminal", because `matches` tests containment both
        // ways and "terminal" is inside "open terminal".
        let bandHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let aMenuTitle = CGRect(
            x: 44,
            y: screen.visibleFrame.maxY + 1,
            width: 76,
            height: bandHeight - 1
        )

        let outcome = await Self.resolve(
            aimingAt: Self.authoredTarget("Open Terminal"),
            whereTheTreeSaysItIs: aMenuTitle
        )

        print("""
        [repro] menu-bar band on this Mac: \(bandHeight)pt, y \(screen.visibleFrame.maxY)…\(screen.frame.maxY)
        [repro] menu title rect: \(aMenuTitle)
        [repro] decision: \(outcome.decision)
        [repro] eye was sent to: \(String(describing: outcome.screenLocation))
        [repro] visibleFrame.maxY = \(screen.visibleFrame.maxY)
        """)

        // Saying "I can't find it" about a menu title the guide never meant is
        // a fine answer, and the fix may take it. Parking a 64pt eye and a
        // sentence of text in the menu-bar band is not.
        guard let point = outcome.screenLocation else { return }

        #expect(
            point.y <= screen.visibleFrame.maxY,
            "the eye was sent to y = \(point.y), above visibleFrame.maxY = \(screen.visibleFrame.maxY) — that is underneath the menu bar"
        )
        #expect(
            Self.theEyeCanSitAt(point),
            "the eye was aimed at \(point), which is not \(Self.roomTheEyeNeedsFromAnyEdge)pt inside any display's visible area"
        )
    }

    // MARK: - "when the thing you need to install is not on the screen"

    @Test("a rectangle on no display at all is not a target — no point beats a wrong point")
    func aControlThatIsNotOnAnyScreenIsRefusedRatherThanAimedAt() async {
        // What the accessibility tree hands back for a control in a window that
        // has been scrolled away, minimised, or left on a display that has since
        // been unplugged: real geometry, describing somewhere nobody is looking.
        // "it seems to point incorrectly when the tab is not visible on the
        // screen, or when the thing you need to install is not on the screen".
        let somewhereNobodyCanSee = CGRect(x: -2400, y: 620, width: 220, height: 44)

        let outcome = await Self.resolve(
            aimingAt: Self.authoredTarget("Install CMake"),
            whereTheTreeSaysItIs: somewhereNobodyCanSee
        )

        print("""
        [repro] rect the tree reported: \(somewhereNobodyCanSee)
        [repro] screens: \(Self.describeTheScreens())
        [repro] decision: \(outcome.decision)
        [repro] eye was sent to: \(String(describing: outcome.screenLocation))
        """)

        #expect(
            outcome.screenLocation == nil,
            "Iris aimed the eye at \(String(describing: outcome.screenLocation)), which is on no display — the reader watches the eye fly off the side of the screen and point at nothing"
        )
        #expect(
            outcome.decision == .doNotPoint(.couldNotFindIt(descriptor: "Install CMake")),
            "the honest answer is the one Iris already has a sentence for, and instead it said \(outcome.decision)"
        )
        // The app has had the right words for this all along; it just never
        // reaches the case that needs them.
        #expect(
            GuidePointRefusal.couldNotFindIt(descriptor: "Install CMake").userFacingMessage
                == "I can't find it on screen — it may be scrolled out of view."
        )
    }

    // MARK: - "Does not point correctly when asking you to install cmake"

    /// Every label the cmake download page publishes to the accessibility tree,
    /// in document order.
    ///
    /// NOT invented. Read off a live Safari window on a cmake.org-shaped
    /// download page with a standalone AX walk, the same
    /// title→description→value read `SystemGuideTargetLocator.label(of:)`
    /// performs. The order is the pre-order the walk visits them in, which is
    /// the whole point: the nav bar is at the top of the document and the
    /// download table is a long way below it.
    ///
    /// The two that matter, with the rectangles the same walk reported:
    ///
    ///     AXLink "Download"                        (159, 498, 67, 18)
    ///     AXLink "cmake-4.1.2-macos-universal.dmg" (260, 353, 222, 19)
    ///
    private static let labelsTheCMakeDownloadPagePublishes = [
        "CMake",
        "Download",
        "Documentation",
        "Community",
        "Latest Release (4.1.2)",
        "Platform",
        "Files",
        "Windows x64 Installer",
        "cmake-4.1.2-windows-x86_64.msi",
        "macOS 10.13 or later",
        "cmake-4.1.2-macos-universal.dmg",
        "macOS 10.10 or later",
        "cmake-4.1.2-macos10.10-universal.dmg",
        "Linux x86_64",
        "cmake-4.1.2-linux-x86_64.tar.gz",
    ]

    /// The descriptor the whimprflow guide actually authors for its install-cmake
    /// step (`publik/lib/guides/whimprflow.ts`), verbatim.
    private static let theAuthoredCMakeDescriptor = "the macOS universal .dmg row in the download table"

    /// What the walk would settle on, given a page's labels in document order —
    /// `SystemGuideTargetLocator.bestMatch`'s decision rule with the tree and
    /// the screen taken out, so it can be argued with here.
    private static func theLabelTheWalkWouldSettleOn(
        among labels: [String],
        forDescriptor descriptor: String
    ) -> String? {
        var bestLabel: String?
        var bestScore = GuidePointingLabelScore.noMatch
        for label in labels {
            let score = GuidePointingLabelScore.of(label: label, against: descriptor)
            guard score.isAMatch, score > bestScore else { continue }
            bestLabel = label
            bestScore = score
        }
        return bestLabel
    }

    @Test("the authored cmake descriptor finds the .dmg row, not the page's nav bar")
    func theEyeFindsTheDownloadRowRatherThanTheFirstThingSharingAWordWithIt() {
        let whatTheWalkFinds = Self.theLabelTheWalkWouldSettleOn(
            among: Self.labelsTheCMakeDownloadPagePublishes,
            forDescriptor: Self.theAuthoredCMakeDescriptor
        )

        print("""
        [repro] descriptor: "\(Self.theAuthoredCMakeDescriptor)"
        [repro] split into name/context: \(GuidePointingLabelScore.nameAndContext(of: Self.theAuthoredCMakeDescriptor))
        [repro] the walk settles on: \(String(describing: whatTheWalkFinds))
        [repro] scores: \(Self.labelsTheCMakeDownloadPagePublishes.map {
            "\($0)=\(GuidePointingLabelScore.of(label: $0, against: Self.theAuthoredCMakeDescriptor).weightOfTheNameThisLabelAccountsFor)"
        })
        """)

        #expect(
            whatTheWalkFinds == "cmake-4.1.2-macos-universal.dmg",
            "the eye was sent to \(String(describing: whatTheWalkFinds)) instead of the row the guide named"
        )

        // The exact wrong answer the reader got. The shipped rule tested
        // containment BOTH ways, so the normalized descriptor "macos universal
        // dmg row download table" CONTAINED the nav link's "download" — and
        // that link is near the top of the document, so first-match returned
        // it. One common word is not a name.
        #expect(
            GuidePointingLabelScore.of(label: "Download", against: Self.theAuthoredCMakeDescriptor).isAMatch == false,
            "the page header link \"Download\" is still a candidate for a descriptor about a .dmg row"
        )
    }

    @Test("a descriptor nothing on the page answers gets no point at all, not the nearest word")
    func aWeakMatchLosesToNotPointing() {
        // The ladder's third rung: no authored target, so the step TITLE
        // becomes the descriptor. Nothing on this page is called "Install
        // CMake"; the nav link "CMake" answers one of its two words and none of
        // the word that says what to do. Measured live before this fix, the
        // walk returned that link at (108, 816, 47, 18) and the eye flew to the
        // top-left of the page saying "Install CMake".
        let whatTheWalkFinds = Self.theLabelTheWalkWouldSettleOn(
            among: Self.labelsTheCMakeDownloadPagePublishes,
            forDescriptor: "Install CMake"
        )

        print("""
        [repro] descriptor: "Install CMake"
        [repro] the walk settles on: \(String(describing: whatTheWalkFinds))
        [repro] "CMake" scores \(GuidePointingLabelScore.of(label: "CMake", against: "Install CMake"))
        """)

        #expect(
            whatTheWalkFinds == nil,
            "Iris pointed confidently at \(String(describing: whatTheWalkFinds)) for a step nothing on the page answers"
        )
        // …and the honest refusal is the one the app already has a sentence for.
        #expect(
            GuidePointRefusal.couldNotFindIt(descriptor: "Install CMake").userFacingMessage
                == "I can't find it on screen — it may be scrolled out of view."
        )
    }

    @Test("the floor does not take away the matches that were always right")
    func aShortLabelAnsweringMostOfALongerDescriptorIsStillAMatch() {
        // The cost of a floor is false refusals, so the cases it must NOT eat
        // are written down next to it. Real labels are routinely shorter than
        // the prose describing them.
        let stillFound: [(descriptor: String, label: String)] = [
            ("Download the installer", "Download"),
            ("the macOS universal .dmg row in the download table", "cmake-4.1.2-macos-universal.dmg"),
            ("the Run button in Xcode's toolbar", "Run"),
            ("the Open button on Android Studio's welcome screen", "Open"),
            ("Install Homebrew", "Homebrew"),
        ]
        for pair in stillFound {
            let score = GuidePointingLabelScore.of(label: pair.label, against: pair.descriptor)
            #expect(
                score.isAMatch,
                "\"\(pair.label)\" stopped answering \"\(pair.descriptor)\" — the floor is eating real matches"
            )
        }
    }

    // MARK: - "it keeps pointing multiple times … whenever I open the browser"

    /// A rectangle nothing can object to: comfortably inside the usable area of
    /// the main display, so the only thing these two tests can be about is HOW
    /// MANY TIMES the eye is sent to it.
    private static func aPlainlyVisibleControl() throws -> CGRect {
        let visible = try #require(NSScreen.main).visibleFrame
        return CGRect(x: visible.midX - 40, y: visible.midY - 12, width: 80, height: 24)
    }

    /// One settled app activation, delivered through the notification the
    /// controller actually observes rather than by calling its handler.
    ///
    /// The wait is longer than
    /// `quietPeriodBeforeRefreshingPointingAfterAnActivation` (400ms) on
    /// purpose: these are not one cmd-tab's burst, they are the reader coming
    /// back to the browser for the third time in a minute, which the existing
    /// coalescer is not meant to merge and does not.
    private static func theReaderSwitchesIntoAnApp() async {
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared
        )
        try? await Task.sleep(for: .milliseconds(750))
    }

    private static func aControllerFollowingAGuideWhoseStepHasSomethingToPointAt(
        eyeFlights: @escaping (CGPoint, String) -> Void,
        locator: AccessibilityTreeAnswering
    ) async throws -> GuideSessionController {
        let controller = GuideSessionController(
            guideService: try GuideSessionTests.guideServiceAnsweredByTheStub()
        )
        controller.targetLocator = locator
        controller.sendTheEyeTo = { location, _, label in eyeFlights(location, label) }
        // "blocked-link" is the stub's two-`open`-step guide. Neither step
        // carries a command or an authored point and neither names an app, so
        // both resolve to a target the frontmost-app gate cannot refuse —
        // whatever happens to be in front while the suite runs.
        await controller.openGuide(
            slug: "blocked-link",
            requestedVersion: 1,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )
        #expect(controller.loadState == .guideIsOpen)
        return controller
    }

    @Test("going back into the same app on the same step does not point all over again")
    func repeatedActivationsOfTheSameAppOnAnUnchangedStepPointOnlyOnce() async throws {
        var eyeFlights: [(point: CGPoint, label: String)] = []
        let locator = AccessibilityTreeAnswering(rectangleTheTreeReports: try Self.aPlainlyVisibleControl())
        let controller = try await Self.aControllerFollowingAGuideWhoseStepHasSomethingToPointAt(
            eyeFlights: { eyeFlights.append((point: $0, label: $1)) },
            locator: locator
        )

        // The step opens and the eye flies to it. This one is the point of the
        // whole feature and must survive the fix.
        controller.refreshPointingForTheOpenStep()
        try? await Task.sleep(for: .milliseconds(900))
        let flightsWhenTheStepOpened = eyeFlights.count
        #expect(
            flightsWhenTheStepOpened >= 1,
            "the eye never flew at all, so this test is not looking at the thing it claims to"
        )

        // "Seems to point every time I interact with the browser that is
        // default." Three deliberate visits, each one long after the previous
        // burst has settled. Same step. Same target. Same rectangle.
        for _ in 0..<3 {
            await Self.theReaderSwitchesIntoAnApp()
        }

        let flightsCausedByTheActivations = eyeFlights.count - flightsWhenTheStepOpened

        print("""
        [repro] step index throughout: \(controller.currentStepIndex)
        [repro] eye flights when the step opened: \(flightsWhenTheStepOpened)
        [repro] eye flights caused by 3 later activations: \(flightsCausedByTheActivations)
        [repro] every flight went to: \(Set(eyeFlights.map { "\($0.point)" }))
        [repro] and said: \(Set(eyeFlights.map(\.label)))
        [repro] times the tree was walked: \(locator.timesTheTreeWasWalked)
        """)

        // Each of these is a full fly-out, three-second hold and fly-home, with
        // the step title read out over the eye again — on a step the reader has
        // already done. "even after installing it."
        #expect(
            flightsCausedByTheActivations == 0,
            "switching apps 3 times on an unchanged step sent the eye out \(flightsCausedByTheActivations) more times"
        )
    }

    @Test("leaving the app and coming back does not fly the eye out all over again")
    func theMemoSurvivesTheTargetAppLosingFocusAndGettingItBack() async throws {
        // The scenario the reader actually described, which the test above does
        // NOT cover: it activates apps while the answer stays available
        // throughout, so it only ever exercises two resolutions that both find
        // the target. "whenever I OPEN the browser" is the other shape — the
        // reader was somewhere else in between, and while they were, pointing
        // for this step resolves to nothing at all.
        //
        // That happens on both routes into the ladder, and this one is
        // deterministic rather than timing-dependent, so it is asserted here
        // rather than described:
        let aCommandStepsTarget = GuidePointTarget(
            descriptor: "the Terminal window",
            inApp: "com.apple.Terminal",
            isWindow: true,
            provenance: .shellWindow
        )
        #expect(
            GuidePointingLadder.decide(
                target: aCommandStepsTarget,
                stepIsSensitive: false,
                irisMayLookAtTheScreen: true,
                frontmostBundleIdentifier: "com.apple.finder",
                frontmostAppName: "Finder"
            ) == .doNotPoint(.targetAppIsNotInFront(bundleId: "com.apple.Terminal", appName: "Finder")),
            "a step aimed at an app that is not in front has to resolve to no location — that is the branch under test"
        )
        // The accessibility route behaves the same way for the same reason: the
        // walk is rooted at the app the descriptor names, and a descriptor about
        // a web page's download table answers nothing in Finder's tree.
        var eyeFlights: [(point: CGPoint, label: String)] = []
        let whereTheControlIs = try Self.aPlainlyVisibleControl()
        let locator = AccessibilityTreeAnswering(rectangleTheTreeReports: whereTheControlIs)
        let controller = try await Self.aControllerFollowingAGuideWhoseStepHasSomethingToPointAt(
            eyeFlights: { eyeFlights.append((point: $0, label: $1)) },
            locator: locator
        )

        controller.refreshPointingForTheOpenStep()
        try? await Task.sleep(for: .milliseconds(900))
        let flightsWhenTheStepOpened = eyeFlights.count
        #expect(
            flightsWhenTheStepOpened >= 1,
            "the eye never flew at all, so this test is not looking at the thing it claims to"
        )

        // Three out-and-backs: away (nothing to point at), then back (the same
        // answer as before). On a step the reader has already finished.
        for _ in 0..<3 {
            locator.rectangleTheTreeReports = nil
            controller.refreshPointingForTheOpenStep()
            try? await Task.sleep(for: .milliseconds(400))

            locator.rectangleTheTreeReports = whereTheControlIs
            controller.refreshPointingForTheOpenStep()
            try? await Task.sleep(for: .milliseconds(400))
        }

        let flightsCausedByComingBack = eyeFlights.count - flightsWhenTheStepOpened

        print("""
        [repro] step index throughout: \(controller.currentStepIndex)
        [repro] eye flights when the step opened: \(flightsWhenTheStepOpened)
        [repro] eye flights caused by 3 out-and-backs: \(flightsCausedByComingBack)
        [repro] every flight went to: \(Set(eyeFlights.map { "\($0.point)" }))
        [repro] and said: \(Set(eyeFlights.map(\.label)))
        """)

        #expect(
            flightsCausedByComingBack == 0,
            """
            leaving the app and coming back 3 times sent the eye out \(flightsCausedByComingBack) more \
            times — the memo is being erased by the very app switch that causes the repeat
            """
        )
    }

    // MARK: - The line the fix must not cross

    @Test("a step change still re-points — a debounce must not turn the eye off")
    func movingToTheNextStepStillFliesTheEye() async throws {
        var eyeFlights: [(point: CGPoint, label: String)] = []
        let locator = AccessibilityTreeAnswering(rectangleTheTreeReports: try Self.aPlainlyVisibleControl())
        let controller = try await Self.aControllerFollowingAGuideWhoseStepHasSomethingToPointAt(
            eyeFlights: { eyeFlights.append((point: $0, label: $1)) },
            locator: locator
        )

        controller.refreshPointingForTheOpenStep()
        try? await Task.sleep(for: .milliseconds(900))
        let labelsOnTheFirstStep = eyeFlights.map(\.label)

        controller.advanceToTheNextStep()
        try? await Task.sleep(for: .milliseconds(900))
        let labelsAfterMovingOn = eyeFlights.map(\.label)

        print("""
        [repro] step index after advancing: \(controller.currentStepIndex)
        [repro] labels said on step one: \(Set(labelsOnTheFirstStep))
        [repro] labels said in total:    \(Set(labelsAfterMovingOn))
        """)

        #expect(
            labelsAfterMovingOn.count > labelsOnTheFirstStep.count,
            "the reader moved to a new step and the eye did not go anywhere"
        )
        #expect(
            Set(labelsAfterMovingOn).count > 1,
            "the eye said the same step title on the new step, so it never re-resolved"
        )
    }

    // MARK: - The rule underneath the two tests above, on its own

    /// The two controller tests are the ones that speak for the reader, and
    /// they stay. This one holds the pure rule they lean on, so the rule keeps
    /// its meaning even in a build where the controller's wiring has been
    /// re-arranged around it — and so the three answers it has to give are
    /// written down in one place rather than inferred from timing.
    @Test("what counts as the same flight, and what does not")
    func theMemoLetsThroughEverythingThatIsGenuinelyNew() {
        var memo = GuideEyeFlightMemo()
        let firstTimeTheStepIsShown = GuideEyeFlight(
            stepIdentity: "0:download-the-installer",
            screenLocation: CGPoint(x: 773, y: 472),
            label: "Download the installer"
        )

        let theStepOpening = memo.theEyeShouldFly(to: firstTimeTheStepIsShown)
        let theReaderComingBackToTheSameApp = memo.theEyeShouldFly(to: firstTimeTheStepIsShown)
        #expect(theStepOpening, "the first flight of a step is the feature")
        #expect(
            theReaderComingBackToTheSameApp == false,
            "the reader came back to the same app on the same step and the eye was sent out again"
        )

        // The same button, reported a fraction of a point off by the
        // accessibility tree between two walks. Not a new answer.
        let theSameButtonMeasuredAgain = memo.theEyeShouldFly(
            to: GuideEyeFlight(
                stepIdentity: firstTimeTheStepIsShown.stepIdentity,
                screenLocation: CGPoint(x: 773.4, y: 471.8),
                label: firstTimeTheStepIsShown.label
            )
        )
        #expect(theSameButtonMeasuredAgain == false)

        // Everything that is genuinely new still flies: a new step…
        let theReaderMovingToTheNextStep = memo.theEyeShouldFly(
            to: GuideEyeFlight(
                stepIdentity: "1:install-node-lts",
                screenLocation: firstTimeTheStepIsShown.screenLocation,
                label: "Install Node LTS"
            )
        )
        #expect(theReaderMovingToTheNextStep)

        // …and the window having moved under a step that has not.
        let theWindowMovingUnderAnUnchangedStep = memo.theEyeShouldFly(
            to: GuideEyeFlight(
                stepIdentity: "1:install-node-lts",
                screenLocation: CGPoint(x: 400, y: 300),
                label: "Install Node LTS"
            )
        )
        #expect(theWindowMovingUnderAnUnchangedStep)

        // And once there is no step at all, the same answer is news again —
        // otherwise closing a guide and reopening it on the same step would
        // swallow the flight that matters most.
        //
        // "No step" is the ONLY thing that resets this now, and the narrowness
        // is the fix: the reset used to also fire whenever a refresh found
        // nothing, which is precisely what an app switch does, so browser →
        // Finder → browser cleared the memo on the way out and re-flew on the
        // way back. See `theMemoSurvivesTheTargetAppLosingFocusAndGettingItBack`.
        memo.theEyeStoppedPointing()
        let theSameAnswerAfterTheEyeWentHome = memo.theEyeShouldFly(
            to: GuideEyeFlight(
                stepIdentity: "1:install-node-lts",
                screenLocation: CGPoint(x: 400, y: 300),
                label: "Install Node LTS"
            )
        )
        #expect(theSameAnswerAfterTheEyeWentHome)
    }
}
