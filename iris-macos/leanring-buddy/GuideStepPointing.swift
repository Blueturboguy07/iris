//
//  GuideStepPointing.swift
//  leanring-buddy
//
//  Turns the decision in `GuidePointing.swift` into an eye actually flying
//  somewhere.
//
//  Kept out of `GuideSessionController` because that file is already the
//  largest in the app and because this half has to touch AppKit and the
//  accessibility tree, which the controller otherwise never does.
//

import AppKit
import ApplicationServices
import Foundation

/// Finds the rectangle a descriptor names.
///
/// A protocol so the controller can be tested without a screen, and because the
/// model fallback is a different collaborator from the accessibility walk.
@MainActor
protocol GuideTargetLocating {
    /// The accessibility tree first: exact, free, and about three quarters of
    /// controls. Returns nil when the tree has nothing matching, which is the
    /// signal to fall back.
    func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect?

    /// The frame of an app's frontmost window, for a command step aiming at a
    /// Terminal rather than at a control.
    func locateWindow(ofApp bundleIdentifier: String) -> CGRect?

    /// The paid path, used only when the two above come back empty and the
    /// step's target was never authored.
    func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect?
}

/// What the eye was told to do about the current step.
@MainActor
struct GuideStepPointingOutcome: Equatable {
    let decision: GuidePointingDecision
    /// Global AppKit coordinates, when there is somewhere to go.
    let screenLocation: CGPoint?
    let displayFrame: CGRect?
    /// True when this resolution spent a model call, so the caller can count
    /// it against the step's small model budget. Pointing refreshes on every
    /// app activation now, and an uncounted model call per refresh is how one
    /// step burned through the funded tier's day.
    let theModelWasAsked: Bool
}

/// One display, reduced to the two rectangles pointing cares about.
///
/// A value rather than an `NSScreen` so the aiming maths below can be run — and
/// argued with — from a test with no screen attached, which is the only way the
/// "where did the eye actually go" questions ever get answered.
nonisolated struct GuidePointableDisplay: Equatable, Sendable {
    /// The whole display in AppKit's global coordinates. This is what the
    /// overlay animates on, so it is what an outcome carries.
    let frame: CGRect
    /// The part of it macOS says is usable: menu bar and Dock excluded. The eye
    /// never ends up outside this.
    let usableArea: CGRect
}

@MainActor
enum GuideStepPointingCoordinator {

    /// Where in a found rectangle the eye should aim.
    ///
    /// The centre for a control, because that is the thing to click. For a
    /// window it is the top edge rather than the middle: a window's centre is
    /// wherever the reader is working, and parking a 64pt eye on top of the
    /// text they are trying to read is worse than not pointing at all.
    static func aimPoint(in rectangle: CGRect, isWindow: Bool) -> CGPoint {
        if isWindow {
            return CGPoint(x: rectangle.midX, y: rectangle.maxY - min(28, rectangle.height * 0.12))
        }
        return CGPoint(x: rectangle.midX, y: rectangle.midY)
    }

    /// The display a point falls on, so the overlay animates on the right
    /// screen. Falls back to the main display rather than refusing to point.
    ///
    /// NOT on the pointing path any more, and must not be put back on it. That
    /// fallback is precisely how an outcome came to say "fly to (1792, 694) on
    /// the display (0, 0, 1512, 982)" — a display that does not contain the
    /// point it was handed alongside. `aimPointTheReaderCanSee` chooses the
    /// display from the target's own rectangle and then holds the point inside
    /// that display, so the two can never disagree.
    static func displayFrame(containing point: CGPoint) -> CGRect {
        for screen in NSScreen.screens where screen.frame.contains(point) {
            return screen.frame
        }
        return NSScreen.main?.frame ?? .zero
    }

    // MARK: - Somewhere the reader can actually see

    /// Every display attached right now, as pointing sees them.
    static func displaysTheEyeCouldFlyTo() -> [GuidePointableDisplay] {
        NSScreen.screens.map {
            GuidePointableDisplay(frame: $0.frame, usableArea: $0.visibleFrame)
        }
    }

    /// How wide the speech bubble `OverlayWindow` draws beside the eye will be
    /// for this sentence.
    ///
    /// Measured with the same font and padding the bubble is actually built
    /// from — `OverlayWindow`'s navigation bubble is a `Text` at
    /// `.system(size: 11, weight: .medium)` inside `.padding(.horizontal, 8)`,
    /// with `.fixedSize()`, so it never wraps and its width is exactly the
    /// rendered string plus both paddings. Derived rather than guessed, because
    /// a guessed width is how the previous attempt at this ended up reserving
    /// room for the first character and calling it room for the sentence.
    static func widthOfTheBubbleTheEyeWillSpeakIn(saying whatTheEyeWillSay: String) -> CGFloat {
        guard !whatTheEyeWillSay.isEmpty else { return 0 }
        let bubbleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let renderedWidth = (whatTheEyeWillSay as NSString)
            .size(withAttributes: [.font: bubbleFont])
            .width
        return ceil(renderedWidth) + horizontalPaddingInsideTheBubble * 2
    }

    /// `OverlayWindow`'s `.padding(.horizontal, 8)` on the navigation bubble.
    private static let horizontalPaddingInsideTheBubble: CGFloat = 8

    /// A title long enough to eat a third of the display is a guide bug, and
    /// reserving all of it would park the eye near the middle of the screen
    /// pointing at nothing in particular. Past this the sentence is allowed to
    /// clip; the eye still lands somewhere sane.
    private static let mostOfTheDisplayTheEyesSentenceMayReserve: CGFloat = 1.0 / 3.0

    /// The rectangle inside one display's usable area that the eye may come to
    /// rest in, given what it is about to say.
    ///
    /// Neither number is invented here. `smallestDistanceFromAnyEdge` is the
    /// rule the app already enforces on the *dragged* eye — "never draggable
    /// somewhere it cannot be dragged back from" — and the *flown* eye has
    /// simply never obeyed it, which is what "the pointer randomly went close
    /// to edge of the screen" is.
    ///
    /// The right-hand edge needs more than the others because the eye speaks
    /// rightwards, and it needs the WHOLE SENTENCE's worth, not the first
    /// character's. `OverlayWindow` positions the bubble's left edge at
    /// `eye.x + horizontalGapFromTheCentreToWhatTheEyeSays` and draws it
    /// `.fixedSize()`, so it neither wraps nor flips sides: everything past
    /// `maxX` is simply clipped away inside a per-screen overlay window.
    /// Reserving only the gap therefore guarantees the opposite of what it
    /// looks like it guarantees — the eye is placed at exactly the x where the
    /// bubble BEGINS at the display's edge. Measured on this Mac's real
    /// `visibleFrame` (34, 0, 1478, 944) with a target at (1450, 900, 24, 24):
    /// the gap-only rule allowed the eye at x = 1462, putting the first
    /// character at 1508 on a display ending at 1512 — four points of a
    /// ~136pt bubble on screen. "the pointer randomly went close to edge of the
    /// screen, and the text moved off the screen", both halves, from one clamp.
    ///
    /// The cost, stated plainly: a target inside the reserved band puts the eye
    /// to its left rather than on it. That band is the sentence's own width —
    /// measured, 110–260pt for real step titles on a 1478pt-wide area — and it
    /// only bites for targets already hard against the right edge, where the
    /// alternative is an eye announcing a step title nobody can read. Capped by
    /// `mostOfTheDisplayTheEyesSentenceMayReserve` so no title can push the eye
    /// to the middle of the screen.
    static func placeTheEyeMayComeToRest(
        inside usableArea: CGRect,
        whatTheEyeWillSay: String = ""
    ) -> CGRect {
        let edge = OverlayEyeRestingPlace.smallestDistanceFromAnyEdge
        let gapToTheFirstCharacter = OverlayEyeInteractionGeometry()
            .horizontalGapFromTheCentreToWhatTheEyeSays
        let roomForTheWholeSentence = min(
            gapToTheFirstCharacter + widthOfTheBubbleTheEyeWillSpeakIn(saying: whatTheEyeWillSay),
            usableArea.width * mostOfTheDisplayTheEyesSentenceMayReserve
        )

        // Widest first, then give ground one rule at a time rather than
        // collapsing straight to the centre. A display too narrow to hold the
        // whole sentence is still wide enough to hold the eye, and putting the
        // eye where it belongs with a clipped word beats abandoning the target.
        let rightHandInsetsWorthTrying = [
            max(edge, roomForTheWholeSentence),
            max(edge, gapToTheFirstCharacter),
            edge,
        ]
        for rightEdge in rightHandInsetsWorthTrying {
            let room = CGRect(
                x: usableArea.minX + edge,
                y: usableArea.minY + edge,
                width: usableArea.width - edge - rightEdge,
                height: usableArea.height - edge * 2
            )
            if room.width > 0, room.height > 0 {
                return room
            }
        }

        // A display too small to hold even the plain insets has no valid range.
        // Its centre is the only honest answer, and is exactly what
        // `OverlayEyeRestingPlace` already does for the dragged eye in the same
        // situation.
        return CGRect(x: usableArea.midX, y: usableArea.midY, width: 0, height: 0)
    }

    /// The display showing the most of this rectangle, or nil when no display
    /// shows any of it.
    ///
    /// Nil is the whole point. The accessibility tree answers with real
    /// geometry for a control in a window that is scrolled away, minimised, or
    /// on a display that has since been unplugged, and a rectangle at
    /// x = -2400 is not a target — it is the reader watching the eye fly off
    /// the side of the screen. "It seems to point incorrectly when the tab is
    /// not visible on the screen."
    static func displayShowingTheMostOf(
        _ rectangle: CGRect,
        among displays: [GuidePointableDisplay]
    ) -> GuidePointableDisplay? {
        var bestSoFar: GuidePointableDisplay?
        var largestAreaShowing: CGFloat = 0
        for display in displays {
            let showing = display.usableArea.intersection(rectangle)
            // A hairline of overlap is not "on screen"; it is a window pushed
            // one pixel past the edge. Ask for something the reader could see.
            guard !showing.isNull, showing.width >= 1, showing.height >= 1 else { continue }
            let areaShowing: CGFloat = showing.width * showing.height
            if bestSoFar == nil || areaShowing > largestAreaShowing {
                bestSoFar = display
                largestAreaShowing = areaShowing
            }
        }
        return bestSoFar
    }

    /// Where the eye can actually stand to point at this rectangle, and the
    /// display to fly it on — or nil when there is nowhere, which is a better
    /// answer than a wrong one.
    ///
    /// Two clamps, in this order and not the other one. First into the part of
    /// the target that is on screen, so the eye lands on the sliver the reader
    /// can see rather than on the offscreen centre of a window they have shoved
    /// half off the edge. Then into the eye's standing room, which is the hard
    /// constraint and therefore last.
    static func aimPointTheReaderCanSee(
        in rectangle: CGRect,
        isWindow: Bool,
        displays: [GuidePointableDisplay],
        whatTheEyeWillSay: String = ""
    ) -> (point: CGPoint, displayFrame: CGRect)? {
        guard let display = displayShowingTheMostOf(rectangle, among: displays) else { return nil }
        let partOfTheTargetOnThisDisplay = display.usableArea.intersection(rectangle)
        let onTheVisiblePart = clamp(
            aimPoint(in: rectangle, isWindow: isWindow),
            into: partOfTheTargetOnThisDisplay
        )
        // The display is picked from the rectangle and the point is then held
        // inside that same display, so the frame an outcome carries always
        // contains the point it carries. It used to be looked up FROM the
        // unclamped point and fall back to the main display when nothing held
        // it, which is how an outcome came to say "fly to (1792, 694) on the
        // display (0, 0, 1512, 982)" about a point that display does not have.
        let whereTheEyeMayStand = placeTheEyeMayComeToRest(
            inside: display.usableArea,
            whatTheEyeWillSay: whatTheEyeWillSay
        )
        return (clamp(onTheVisiblePart, into: whereTheEyeMayStand), display.frame)
    }

    private static func clamp(_ point: CGPoint, into rectangle: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rectangle.minX), rectangle.maxX),
            y: min(max(point.y, rectangle.minY), rectangle.maxY)
        )
    }

    /// Resolve a decision into a place, or explain why there is not one.
    ///
    /// `mayAskTheModel` is the caller's per-step budget: the free rungs (a
    /// window frame, the accessibility tree) always run, but the paid model
    /// rung is skipped once the step has spent its allowance.
    static func resolve(
        decision: GuidePointingDecision,
        stepTitle: String,
        stepBody: String,
        mayAskTheModel: Bool,
        using locator: any GuideTargetLocating
    ) async -> GuideStepPointingOutcome {
        guard case .pointAt(let target) = decision else {
            return GuideStepPointingOutcome(
                decision: decision, screenLocation: nil, displayFrame: nil,
                theModelWasAsked: false
            )
        }

        var found: CGRect?
        var theModelWasAsked = false
        if target.isWindow, let bundleIdentifier = target.inApp {
            found = locator.locateWindow(ofApp: bundleIdentifier)
        }
        if found == nil {
            found = locator.locateInAccessibilityTree(descriptor: target.descriptor, inApp: target.inApp)
        }
        // Only an inferred target is allowed to reach the model: an authored
        // descriptor the tree could not find is a stale guide, and guessing
        // over the top of it hides that rather than fixing it.
        if found == nil, target.provenance == .inferred, mayAskTheModel {
            theModelWasAsked = true
            found = await locator.locateByAskingTheModel(stepTitle: stepTitle, stepBody: stepBody)
        }

        guard let rectangle = found else {
            return GuideStepPointingOutcome(
                decision: .doNotPoint(.couldNotFindIt(descriptor: target.descriptor)),
                screenLocation: nil,
                displayFrame: nil,
                theModelWasAsked: theModelWasAsked
            )
        }

        // Having a rectangle is not the same as having somewhere to point. All
        // three rungs above can hand back geometry for something nobody is
        // looking at — a minimised window's last frame, a control scrolled out
        // of its own view, a menu title sitting in the band above
        // `visibleFrame` — and pointing at it is worse than not pointing:
        // "it keeps pointing to completely random places on the computer, like
        // the top of the screen". `couldNotFindIt` is the honest answer and the
        // app has had the right sentence for it all along ("I can't find it on
        // screen — it may be scrolled out of view"); it just never reached it.
        guard let aim = aimPointTheReaderCanSee(
            in: rectangle,
            isWindow: target.isWindow,
            displays: displaysTheEyeCouldFlyTo(),
            // The step title is what `GuideSessionController` hands to
            // `sendTheEyeTo`, and therefore what the bubble beside the eye will
            // actually read. Passing it here is what lets the clamp reserve the
            // sentence's own width instead of its first character's.
            whatTheEyeWillSay: stepTitle
        ) else {
            return GuideStepPointingOutcome(
                decision: .doNotPoint(.couldNotFindIt(descriptor: target.descriptor)),
                screenLocation: nil,
                displayFrame: nil,
                theModelWasAsked: theModelWasAsked
            )
        }

        return GuideStepPointingOutcome(
            decision: decision,
            screenLocation: aim.point,
            displayFrame: aim.displayFrame,
            theModelWasAsked: theModelWasAsked
        )
    }
}

// MARK: - The real macOS answers

/// The accessibility tree and the window list, for real.
///
/// No screenshot is taken here at all. That is why an authored descriptor still
/// resolves for somebody who has never granted Screen Recording — and it is why
/// `GuidePointingLadder.decide` only blocks the *inferred* path on that grant.
@MainActor
struct SystemGuideTargetLocator: GuideTargetLocating {
    /// Asks the model. Injected because it goes through `AssistantTransport`
    /// like every other model call in this app, and this file must not build a
    /// second route to one.
    var askTheModel: ((String, String) async -> CGRect?)?

    func locateInAccessibilityTree(descriptor: String, inApp bundleIdentifier: String?) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }

        let applications: [NSRunningApplication]
        if let bundleIdentifier {
            applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            applications = [frontmost]
        } else {
            applications = []
        }

        let wanted = GuidePointingLabelScore.nameAndContext(of: descriptor)
        guard !wanted.name.isEmpty else { return nil }
        let displays = GuideStepPointingCoordinator.displaysTheEyeCouldFlyTo()
        for application in applications {
            let element = AXUIElementCreateApplication(application.processIdentifier)
            var best: (rectangle: CGRect, score: GuidePointingLabelScore)?
            var nodesVisited = 0
            bestMatch(
                element: element, wanted: wanted, depth: 0,
                displays: displays,
                stopWalkingAt: Date().addingTimeInterval(Self.longestTheWalkMayTake),
                best: &best, nodesVisited: &nodesVisited
            )
            if let best {
                return best.rectangle
            }
        }
        return nil
    }

    func locateWindow(ofApp bundleIdentifier: String) -> CGRect? {
        guard
            AXIsProcessTrusted(),
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else {
            return nil
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement]
        else {
            return nil
        }
        // A minimised window keeps the position and size it had when it went
        // down, so `windows.first` cheerfully hands back a rectangle over an
        // empty patch of desktop — and an app can be frontmost with every one
        // of its windows in the Dock, so the frontmost gate does not catch it.
        // Take the first window that is actually up; if none is, say nothing
        // rather than aim at a ghost.
        guard let windowThatIsActuallyUp = windows.first(where: { !isMinimised($0) }) else {
            return nil
        }
        return frame(of: windowThatIsActuallyUp)
    }

    private func isMinimised(_ window: AXUIElement) -> Bool {
        var minimizedValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue) == .success,
            let minimized = minimizedValue as? Bool
        else {
            // An app that does not publish the attribute is not evidence of a
            // minimised window, and refusing on a missing attribute would take
            // pointing away from every app that omits it.
            return false
        }
        return minimized
    }

    func locateByAskingTheModel(stepTitle: String, stepBody: String) async -> CGRect? {
        guard let askTheModel else { return nil }
        return await askTheModel(stepTitle, stepBody)
    }

    // MARK: Walking the tree

    /// Bounded on purpose. An unbounded walk of a big app's tree takes long
    /// enough to be felt, and a control worth pointing at is never sixteen
    /// levels down inside a table cell.
    private static let maximumDepth = 16

    /// A big web page's accessibility tree is thousands of nodes, and the walk
    /// now visits ALL of them rather than stopping at the first hit — so it
    /// needs a ceiling the old first-match walk never had.
    ///
    /// It turns out the OLD walk needed one too, and nobody knew. Every AX read
    /// is an IPC round trip, and a walk that finds nothing visits the whole
    /// tree either way. Measured on this Mac against Finder (a big tree — every
    /// desktop icon is a node) with a descriptor nothing matches, which is
    /// exactly what happens on every activation while a guide's target app is
    /// not frontmost:
    ///
    ///     old first-match walk, unbounded:  78453ms
    ///     this walk, node cap only (6000):   8085ms
    ///
    /// Both numbers are on the main actor. So the cap is a DEADLINE as well as
    /// a node count: what matters is that pointing never makes the app hang,
    /// and a deadline says that directly whatever shape the tree is. The cmake
    /// download page's whole tree is ~1280 nodes in 82ms, so a real page still
    /// finishes its search rather than being cut off by either bound.
    private static let maximumNodesToVisit = 6000
    private static let longestTheWalkMayTake: TimeInterval = 0.4

    /// The best element in the whole tree, not the first one that matched.
    ///
    /// THIS IS THE FIX for "does not point correctly when asking you to install
    /// cmake". Measured live against a real Safari window on that page, with the
    /// authored descriptor "the macOS universal .dmg row in the download table":
    /// the old first-match walk returned `AXLink "Download"` at (240, 836, 72,
    /// 18) — the navigation link in the page header — because `matches` tested
    /// containment BOTH ways and the normalized descriptor "macos universal dmg
    /// row download table" contains "download". Pre-order made that link the
    /// first thing found, and it is fully on screen, so the visibility guard
    /// accepted it. The eye flew to the top-left nav bar.
    ///
    /// One common word in common is not a name. So every candidate is now
    /// SCORED against the descriptor (`GuidePointingLabelScore`) and the walk
    /// keeps the best: the real `.dmg` row shares three of the descriptor's
    /// words to the nav link's one, and wins by that margin instead of losing
    /// on document order.
    private func bestMatch(
        element: AXUIElement,
        wanted: (name: Set<String>, context: Set<String>),
        depth: Int,
        displays: [GuidePointableDisplay],
        stopWalkingAt: Date,
        best: inout (rectangle: CGRect, score: GuidePointingLabelScore)?,
        nodesVisited: inout Int
    ) {
        guard depth <= Self.maximumDepth, nodesVisited < Self.maximumNodesToVisit else { return }
        // Checked every 64 nodes rather than every node: `Date()` is cheap next
        // to an AX round trip but not free, and 64 nodes is far inside the
        // deadline's own resolution.
        if nodesVisited % 64 == 0, Date() >= stopWalkingAt { return }
        nodesVisited += 1

        if let label = label(of: element) {
            let score = GuidePointingLabelScore.of(
                label: normalizedTokens(label), againstName: wanted.name, context: wanted.context
            )
            if score.isAMatch, score > (best?.score ?? .noMatch) {
                // A match the reader cannot see is not a match, and the walk has
                // to keep going rather than stop on it. Measured live on this
                // Mac: the step title "Open Terminal" matched Terminal's own
                // AXMenuBarItem at (44, 945, 76, 37), and the walk returned the
                // FIRST thing it matched, so the eye flew to the menu bar and
                // stopped there. "It keeps pointing to completely random places
                // on the computer, like the top of the screen." Rejecting it
                // here rather than only at the clamp is what lets the real
                // control lower in the tree still win.
                if let rectangle = frame(of: element),
                   rectangle.width > 1,
                   rectangle.height > 1,
                   GuideStepPointingCoordinator.displayShowingTheMostOf(rectangle, among: displays) != nil {
                    best = (rectangle, score)
                    // Nothing can beat a label that IS the descriptor, so stop
                    // paying for the rest of the tree once one turns up.
                    if score.isTheDescriptorExactly { return }
                }
            }
        }

        var childrenValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else {
            return
        }
        for child in children {
            if let best, best.score.isTheDescriptorExactly { return }
            bestMatch(
                element: child, wanted: wanted, depth: depth + 1,
                displays: displays, stopWalkingAt: stopWalkingAt,
                best: &best, nodesVisited: &nodesVisited
            )
        }
    }

    /// Title, then description, then value — the three places a control's
    /// human-readable name actually lives, in the order they are most likely to
    /// be the name a guide author would have written down.
    private func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let text = value as? String,
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
        else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }

        // Accessibility reports a top-left origin on the primary display;
        // AppKit's global space is bottom-left. Flip through the main screen's
        // height, which is the same conversion `OverlayWindow` already does.
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? size.height
        return CGRect(x: origin.x, y: mainHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    /// Case, punctuation and the words a guide author adds for readability
    /// ("the ••• button in cue's toolbar") should not decide a match.
    private func normalizedTokens(_ text: String) -> Set<String> {
        GuidePointingLabelScore.normalizedTokens(text)
    }
}

/// How well one accessibility label answers a descriptor, as a pure function of
/// the two strings — no AX, no screen, so all of it is testable.
///
/// A guide's descriptor is prose, and it says two different things: what the
/// control is CALLED, and WHERE it is. "The macOS universal .dmg row **in the
/// download table**". "The Open button **on Android Studio's welcome screen**".
/// "The play button **at the top left of Xcode's toolbar**". Only the first
/// half is the control's name; the second half describes its surroundings, and
/// scoring a label against both halves at once is what made the eye fly to a
/// page's nav bar (which is literally named "Download") and to Xcode's own
/// application menu (named "Xcode").
///
/// So the descriptor is split at the first word that starts saying WHERE
/// (`wordsThatStartSayingWhereItIs`) and the halves are used for different
/// jobs. A label must account for some of the NAME to be a candidate at all;
/// the context half only breaks ties between labels that already qualify.
///
/// Among candidates, two numbers decide, in order:
///
///  1. `weightOfTheNameThisLabelAccountsFor` — how much of what the control is
///     called this label covers. This is the number that fixes the cmake
///     defect: against "the macOS universal .dmg row" the real row
///     `cmake-4.1.2-macos-universal.dmg` accounts for three words and the page
///     header link "Download" for none, so the row wins however early in the
///     document the header link appears.
///  2. `balance` — the harmonic mean of that coverage and how much of the LABEL
///     is name, which breaks ties toward a label that is the name and nothing
///     else ("Run" over "Run Destination" for "the Run button").
///
/// Words are weighted by length rather than counted, because a long word is a
/// name and a short one is usually grammar; the weight is capped so one very
/// long token cannot carry a match on its own.
nonisolated struct GuidePointingLabelScore: Comparable, Sendable {

    /// Words this short in common are a coincidence, not a name — "of", "s",
    /// "in". A match must share at least one word longer than this, or be the
    /// descriptor exactly.
    static let shortestWordThatCanCarryAMatch = 3

    /// One very long token must not outweigh three ordinary ones.
    static let mostOneWordMayWeigh = 8

    /// How much of what the control is CALLED a label has to account for before
    /// it is a candidate at all.
    ///
    /// Scoring alone only decides which of several matches is best. It cannot
    /// decide that the best of them is still not good enough, and that is the
    /// other half of the reader's complaint. Measured live against a real
    /// Safari window on a cmake.org-shaped download page, the inferred
    /// descriptor "Install CMake" — the step title, which is what the ladder
    /// falls back to when nobody authored a target — scored the page's header
    /// link "CMake" as its best candidate at (108, 816, 47, 18). Nothing on
    /// that page is called "Install CMake"; the header link answers one of the
    /// descriptor's two words and none of the one that says what to DO. The eye
    /// flew to the top-left nav bar and announced "Install CMake".
    ///
    /// So a label has to answer at least half of the name by weight. "No point"
    /// is a first-class answer here — it has a sentence of its own ("I can't
    /// find it on screen — it may be scrolled out of view") and it costs the
    /// reader nothing, where a confident arrow at the wrong control teaches
    /// them to stop trusting the arrow at all.
    ///
    /// Half rather than something stricter because real labels are routinely
    /// shorter than the prose describing them, and those still have to match:
    /// "Download the installer" against a button reading "Download" is 8 of 16
    /// and stays a match; "the macOS universal .dmg row" against the real row
    /// `cmake-4.1.2-macos-universal.dmg` is 16 of 19 and wins comfortably.
    static let smallestShareOfTheNameAMatchMustAccountFor = 0.5

    let weightOfTheNameThisLabelAccountsFor: Int
    let balance: Double
    /// How much of the descriptor's WHERE half this label also mentions. Only a
    /// tie-break: two rows that answer the name equally well are separated by
    /// which of them is also in the place the guide described.
    let weightOfTheContextThisLabelAlsoMentions: Int
    /// The label and the descriptor's name half are the same words. Nothing can
    /// beat it, so the walk stops when it finds one.
    let isTheNameExactly: Bool

    static let noMatch = GuidePointingLabelScore(
        weightOfTheNameThisLabelAccountsFor: 0,
        balance: 0,
        weightOfTheContextThisLabelAlsoMentions: 0,
        isTheNameExactly: false
    )

    var isAMatch: Bool { weightOfTheNameThisLabelAccountsFor > 0 }

    /// Kept as the walk's stop condition: an exact name match with nothing in
    /// the descriptor's context half left to distinguish it.
    var isTheDescriptorExactly: Bool { isTheNameExactly }

    static func < (lhs: GuidePointingLabelScore, rhs: GuidePointingLabelScore) -> Bool {
        if lhs.weightOfTheNameThisLabelAccountsFor != rhs.weightOfTheNameThisLabelAccountsFor {
            return lhs.weightOfTheNameThisLabelAccountsFor < rhs.weightOfTheNameThisLabelAccountsFor
        }
        if lhs.balance != rhs.balance {
            return lhs.balance < rhs.balance
        }
        return lhs.weightOfTheContextThisLabelAlsoMentions
            < rhs.weightOfTheContextThisLabelAlsoMentions
    }

    static let ignoredWords: Set<String> = [
        "the", "a", "an", "in", "on", "at", "of", "button", "toolbar", "menu", "window", "icon",
    ]

    /// The words that stop a descriptor naming the control and start describing
    /// where it sits. Deliberately only the plainly locative ones: "to" is NOT
    /// here, because "the Add to Chrome button" is a name with a "to" in it.
    static let wordsThatStartSayingWhereItIs: Set<String> = [
        "in", "on", "at", "under", "above", "below", "beside", "near",
        "within", "inside", "underneath", "beneath",
    ]

    /// Words in reading order, lowercased, punctuation gone — before anything
    /// is dropped, because the split has to see "in" and "on" to find them.
    static func wordsInOrder(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    static func normalizedTokens(_ text: String) -> Set<String> {
        Set(wordsInOrder(text).filter { !ignoredWords.contains($0) })
    }

    /// A descriptor split into what the control is called and where it is.
    /// Everything up to the first locative word is the name; the rest is
    /// context. A descriptor that opens with a locative word, or whose name
    /// half is nothing but grammar, keeps the whole thing as the name — a split
    /// that leaves nothing to match on is worse than no split.
    static func nameAndContext(of descriptor: String) -> (name: Set<String>, context: Set<String>) {
        let words = wordsInOrder(descriptor)
        let whole = Set(words.filter { !ignoredWords.contains($0) })
        guard let splitIndex = words.firstIndex(where: { wordsThatStartSayingWhereItIs.contains($0) }),
              splitIndex > 0
        else {
            return (whole, [])
        }
        let name = Set(words[..<splitIndex].filter { !ignoredWords.contains($0) })
        let context = Set(words[splitIndex...].filter { !ignoredWords.contains($0) })
        guard !name.isEmpty else { return (whole, []) }
        return (name, context.subtracting(name))
    }

    static func weight(of words: Set<String>) -> Int {
        words.reduce(0) { $0 + min($1.count, mostOneWordMayWeigh) }
    }

    static func of(
        label: Set<String>,
        againstName name: Set<String>,
        context: Set<String>
    ) -> GuidePointingLabelScore {
        guard !label.isEmpty, !name.isEmpty else { return .noMatch }
        let wordsInCommon = label.intersection(name)
        guard !wordsInCommon.isEmpty else { return .noMatch }
        let theyAreTheSameWords = label == name
        guard theyAreTheSameWords
                || wordsInCommon.contains(where: { $0.count >= shortestWordThatCanCarryAMatch })
        else {
            return .noMatch
        }
        let sharedWeight = weight(of: wordsInCommon)
        let coverage = Double(sharedWeight) / Double(weight(of: name))
        // A weak match loses to no match at all. See
        // `smallestShareOfTheNameAMatchMustAccountFor`.
        guard theyAreTheSameWords || coverage >= smallestShareOfTheNameAMatchMustAccountFor else {
            return .noMatch
        }
        let precision = Double(sharedWeight) / Double(weight(of: label))
        let balance = coverage + precision == 0
            ? 0
            : 2 * coverage * precision / (coverage + precision)
        return GuidePointingLabelScore(
            weightOfTheNameThisLabelAccountsFor: sharedWeight,
            balance: balance,
            weightOfTheContextThisLabelAlsoMentions: weight(of: label.intersection(context)),
            isTheNameExactly: theyAreTheSameWords && context.isEmpty
        )
    }

    /// The whole decision from two raw strings, for tests and for anything that
    /// wants to ask "would the eye pick this label for this descriptor".
    static func of(label: String, against descriptor: String) -> GuidePointingLabelScore {
        let split = nameAndContext(of: descriptor)
        return of(label: normalizedTokens(label), againstName: split.name, context: split.context)
    }
}
