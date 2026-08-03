//
//  OverlayEyeInteraction.swift
//  leanring-buddy
//
//  Everything about the on-screen eye being a *control* rather than a
//  decoration: how big its clickable region is, where that region sits in each
//  of the two coordinate spaces the overlay lives in, what a click on it does,
//  and what the input bar it opens offers to say.
//
//  All of it is deliberately free of AppKit and SwiftUI so it can be tested
//  without a screen. The one thing in this feature that is genuinely dangerous
//  — deciding which pixels of a full-screen, otherwise click-through overlay
//  are allowed to swallow a mouse click — is a pure function here, and
//  `IrisEyeTests` pins it down directly.
//
//  COORDINATE SPACES, since this file converts between them:
//
//    * **SwiftUI overlay coordinates** — origin at the top-left of *this
//      screen's* overlay window, y growing downward. This is the space the
//      eye's position is tracked in.
//    * **AppKit screen coordinates** — origin at the bottom-left of the main
//      display, y growing upward. This is the space `NSEvent.mouseLocation`
//      reports in and the space `NSWindow.setFrameOrigin` consumes.
//
//  Every conversion between the two lives in this file's
//  `convert…` helpers, so there is one place to get the y flip wrong.
//

import CoreGraphics
import Foundation

// MARK: - What the eye is showing

/// What is drawn where the eye sits.
///
/// The eye becomes a gear while the input bar is open, because at that point
/// the eye has already done its job — the thing a second click should reach is
/// the settings panel, not another copy of the bar that is already open.
enum OverlayEyeAffordance: Equatable {
    /// The ordinary state: Iris's eye, watching the pointer.
    case eye
    /// The input bar is open, so the same spot is now the way into settings.
    case settingsGear
}

/// What a click on the eye did. Returned rather than performed so the state
/// machine stays free of AppKit and the view is the only thing that talks to
/// notifications and windows.
enum OverlayEyeClickOutcome: Equatable {
    /// The eye was resting; the input bar should now be shown.
    case shouldOpenTheInputBar
    /// The bar was already open and the eye was a gear; the settings panel
    /// should be toggled.
    case shouldOpenTheSettingsPanel
}

/// Whether the eye has been activated, and therefore which of the two things
/// the same click target currently means.
struct OverlayEyeActivation: Equatable {

    /// True from the moment the eye is clicked until the bar is dismissed —
    /// by Escape, by a click elsewhere, or by sending a message.
    private(set) var theInputBarIsOpen: Bool = false

    init() {}

    var affordanceToDraw: OverlayEyeAffordance {
        theInputBarIsOpen ? .settingsGear : .eye
    }

    /// Records a click on the eye and says what should happen because of it.
    mutating func registerAClickOnTheEye() -> OverlayEyeClickOutcome {
        guard !theInputBarIsOpen else {
            // The bar stays open behind the settings panel on purpose: the
            // reader may well have opened settings to change a model or sign
            // in and then want to finish the sentence they were typing.
            return .shouldOpenTheSettingsPanel
        }
        theInputBarIsOpen = true
        return .shouldOpenTheInputBar
    }

    mutating func dismissTheInputBar() {
        theInputBarIsOpen = false
    }
}

// MARK: - The exchange the bar is showing

/// Which of the four things the bar is showing at this instant.
///
/// The whole conversation happens here, at the eye. The bar does not hand the
/// reader off to another window when they ask something — it changes state in
/// place, so what they see is one small surface doing four things rather than
/// panels appearing and disappearing around them.
enum OverlayEyeExchangePhase: Hashable {
    /// The bar has just opened: an empty field and the suggestion chips.
    case composingTheFirstQuestion
    /// A question has been sent and Iris has not answered yet.
    case waitingForIrisToAnswer
    /// The answer — or the sentence explaining why there is no answer — is on
    /// screen, and the field is empty and waiting for a follow-up.
    case showingTheAnswer
    /// The answer is still on screen and the reader has gone back to the field
    /// to ask something else. The answer deliberately stays visible: taking it
    /// away the moment they touch the field would delete the very thing they
    /// are asking a follow-up about.
    case composingAFollowUp
}

/// The one exchange the bar is currently showing, as a pure value so the whole
/// state machine can be tested without a screen, a window or a network.
///
/// There is exactly one exchange at a time on purpose. The bar hangs off a 64pt
/// eye and floats over whatever the reader is really doing; a scrollback of
/// previous questions would turn it into the second panel this whole change
/// exists to get rid of.
struct OverlayEyeExchange: Equatable {

    /// What the reader asked, kept on screen while Iris works and while the
    /// answer is read, so a slow answer never arrives next to a blank space
    /// where the question used to be.
    private(set) var questionTheReaderAsked: String?

    /// What Iris said back. This is also where a failure sentence goes — an
    /// error is shown in the same place an answer would be, because from the
    /// reader's side "Iris could not answer" *is* the answer to what they
    /// asked, and a separate alert would be a second surface again.
    private(set) var whatIrisSaidBack: String?

    /// Whether `whatIrisSaidBack` is a failure sentence rather than a real
    /// answer. Only the tint depends on it; the position does not.
    private(set) var whatIrisSaidBackIsAFailureMessage: Bool = false

    private(set) var phase: OverlayEyeExchangePhase = .composingTheFirstQuestion

    init() {}

    /// Whether the bar should be holding the keyboard right now.
    ///
    /// THIS IS THE RULE THAT KEEPS THE READER'S OWN TYPING OUT OF THE BAR. The
    /// bar lives in a panel that can become key, which it has to be while
    /// somebody is typing a question into it. But a panel that stays key after
    /// the question is sent goes on swallowing keystrokes meant for the app the
    /// reader went back to — which is exactly the bug this models away. Focus
    /// belongs to the bar only while a question is being composed.
    var theBarShouldHoldTheKeyboard: Bool {
        switch phase {
        case .composingTheFirstQuestion, .composingAFollowUp:
            return true
        case .waitingForIrisToAnswer, .showingTheAnswer:
            return false
        }
    }

    /// Whether there is an exchange on screen at all, as opposed to the empty
    /// opening state with its suggestion chips.
    var thereIsAnExchangeOnScreen: Bool {
        phase != .composingTheFirstQuestion
    }

    /// Whether the suggestion chips should be offered. Only before the first
    /// question: once there is a real exchange to read, three chips underneath
    /// it are noise competing with the answer.
    var theSuggestionChipsShouldBeOffered: Bool {
        phase == .composingTheFirstQuestion
    }

    /// The reader sent a question. Whatever was on screen from last time goes,
    /// because the bar shows one exchange and this is now that exchange.
    mutating func registerTheReaderAsked(_ question: String) {
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty send is not an exchange. Guarding here rather than at every
        // call site means no caller can put the bar into a working state with
        // nothing on its way back.
        guard !trimmedQuestion.isEmpty else { return }

        questionTheReaderAsked = trimmedQuestion
        whatIrisSaidBack = nil
        whatIrisSaidBackIsAFailureMessage = false
        phase = .waitingForIrisToAnswer
    }

    /// Iris answered, or failed in a way that has a sentence for the reader.
    ///
    /// Ignored unless a question is actually outstanding, so a response that
    /// lands after the reader dismissed the bar and opened it again cannot
    /// paste a stale answer under a question they have not asked yet.
    mutating func registerIrisAnswered(
        _ answer: String,
        theAnswerIsAFailureMessage: Bool
    ) {
        guard phase == .waitingForIrisToAnswer else { return }
        whatIrisSaidBack = answer
        whatIrisSaidBackIsAFailureMessage = theAnswerIsAFailureMessage
        phase = .showingTheAnswer
    }

    /// The reader clicked back into the field after an answer. Only meaningful
    /// once there is an answer to follow up on — while Iris is still working
    /// the field is not the thing to interrupt.
    mutating func registerTheReaderWentBackToTheField() {
        guard phase == .showingTheAnswer else { return }
        phase = .composingAFollowUp
    }

    /// The bar is going away. Everything on it goes with it: reopening the bar
    /// is a new conversation at the eye, not a resumed one.
    mutating func clearTheWholeExchange() {
        questionTheReaderAsked = nil
        whatIrisSaidBack = nil
        whatIrisSaidBackIsAFailureMessage = false
        phase = .composingTheFirstQuestion
    }
}

// MARK: - Where the eye is and what may be clicked

/// The eye's size and resting place, and — the important part — exactly which
/// rectangle of the full-screen overlay is allowed to accept a mouse click.
///
/// THE CLICK-THROUGH GUARANTEE. The overlay window covers an entire display
/// and sits above everything. It is `ignoresMouseEvents = true` by default, so
/// every click passes straight through to whatever the user is really working
/// in. The *only* time that is relaxed is while the pointer is inside
/// `interactiveRect…`, which is the eye and a few points of forgiveness around
/// it. Widen this rect carelessly and the user loses the ability to click their
/// own apps, with no visible cause.
struct OverlayEyeInteractionGeometry {

    /// The eye is drawn at 64pt. It was 32pt, which was legible but easy to
    /// miss and far too small a target to ask anybody to hit — a click target
    /// wants to be at least this big, and the eye is now a click target.
    static let eyeDiameterOnTheOverlay: CGFloat = 64

    /// How far the glance is fully extended by. Scaled with the eye from the
    /// 60pt the 32pt eye used, so the "eases off only when the pointer is
    /// almost on top of the eye" behaviour survives the size change instead of
    /// saturating the instant the pointer leaves the eye's own edge.
    static let distanceAtWhichTheGlanceReachesItsLimit: CGFloat =
        eyeDiameterOnTheOverlay * (60.0 / 32.0)

    /// The eye the overlay actually draws, so the proportions under test are
    /// the proportions that ship.
    static let eyePupilGeometry = IrisEyePupilGeometry(
        eyeDiameter: eyeDiameterOnTheOverlay,
        distanceAtWhichTheGlanceReachesItsLimit: distanceAtWhichTheGlanceReachesItsLimit
    )

    /// Where the eye lives when it is not flying somewhere: pinned near the
    /// top-left of the screen. Far enough down and in that a 64pt disc plus its
    /// drop shadow clears the menu bar — including the taller menu bar on a
    /// notched display — rather than tucking under it.
    static let restingEyeCenterInSwiftUICoordinates = CGPoint(x: 58, y: 78)

    /// A ring of forgiveness around the eye's own circle. A click that lands a
    /// couple of points off the edge of a round target was meant for the
    /// target, and the cost of accepting it is a slightly larger rectangle in
    /// a corner of the screen.
    static let clickTargetPaddingAroundTheEye: CGFloat = 6

    /// How far below the eye the input bar hangs.
    static let gapBetweenTheEyeAndTheInputBar: CGFloat = 14

    /// The input bar's width. Wide enough for a real question, narrow enough
    /// that it reads as an attachment to the eye rather than as a window.
    static let inputBarWidth: CGFloat = 320

    /// The bar never touches a screen edge, which matters because the eye sits
    /// close to the left one and a bar centred under it would otherwise hang
    /// off the side of the display.
    static let inputBarMarginFromTheScreenEdge: CGFloat = 16

    /// The tallest the bar's window is ever allowed to become, however long the
    /// answer is.
    ///
    /// The bar floats over whatever the reader is actually working in. A
    /// thousand-word answer that grew the window to match would be a wall
    /// across their screen that they did not ask for, so past this height the
    /// answer scrolls inside the bar instead of the bar growing to fit it.
    static let tallestTheInputBarMayGrow: CGFloat = 420

    /// The shortest the bar's window may be. A floor rather than a fixed size,
    /// so a measurement that arrives before the content has laid out cannot
    /// collapse the window to nothing.
    static let shortestTheInputBarMayBe: CGFloat = 44

    /// The tallest the answer's own scrolling area may be. Under the bar's
    /// ceiling by enough that the field above it and the question echo always
    /// have room, so the field can never be pushed off the bottom of the bar
    /// by a long answer.
    static let tallestTheAnswerAreaMayGrow: CGFloat = 236

    /// Where the eye's centre currently is, in this screen's SwiftUI overlay
    /// coordinates. Held rather than assumed so a caller can ask about the eye
    /// mid-flight if it ever needs to.
    let eyeCenterInSwiftUICoordinates: CGPoint

    let eyeDiameter: CGFloat

    init(
        eyeCenterInSwiftUICoordinates: CGPoint = OverlayEyeInteractionGeometry.restingEyeCenterInSwiftUICoordinates,
        eyeDiameter: CGFloat = OverlayEyeInteractionGeometry.eyeDiameterOnTheOverlay
    ) {
        self.eyeCenterInSwiftUICoordinates = eyeCenterInSwiftUICoordinates
        self.eyeDiameter = eyeDiameter
    }

    /// The one rectangle of the overlay that may accept a mouse click, in this
    /// screen's SwiftUI overlay coordinates.
    var interactiveRectInSwiftUICoordinates: CGRect {
        let sideLength = eyeDiameter + 2 * Self.clickTargetPaddingAroundTheEye
        return CGRect(
            x: eyeCenterInSwiftUICoordinates.x - sideLength / 2,
            y: eyeCenterInSwiftUICoordinates.y - sideLength / 2,
            width: sideLength,
            height: sideLength
        )
    }

    /// The same rectangle in AppKit screen coordinates, which is the space the
    /// pointer is polled in.
    func interactiveRectInAppKitScreenCoordinates(onScreenWithFrame screenFrame: CGRect) -> CGRect {
        let rectInSwiftUICoordinates = interactiveRectInSwiftUICoordinates
        // The SwiftUI rect's *minY* is its top edge; in AppKit that is the
        // rect's maxY, so the AppKit origin is one height further down.
        let topEdgeInAppKitScreenCoordinates =
            screenFrame.origin.y + screenFrame.height - rectInSwiftUICoordinates.minY
        return CGRect(
            x: screenFrame.origin.x + rectInSwiftUICoordinates.minX,
            y: topEdgeInAppKitScreenCoordinates - rectInSwiftUICoordinates.height,
            width: rectInSwiftUICoordinates.width,
            height: rectInSwiftUICoordinates.height
        )
    }

    /// The eye's centre in AppKit screen coordinates — where the input bar
    /// hangs from.
    func eyeCenterInAppKitScreenCoordinates(onScreenWithFrame screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: screenFrame.origin.x + eyeCenterInSwiftUICoordinates.x,
            y: screenFrame.origin.y + screenFrame.height - eyeCenterInSwiftUICoordinates.y
        )
    }

    /// THE CLICK-THROUGH DECISION. True only while the pointer is over the
    /// eye, which is the only moment the overlay window is allowed to stop
    /// being click-through. Everywhere else this is false and the user's own
    /// apps receive their own clicks.
    func theOverlayShouldAcceptMouseEvents(
        forPointerAtAppKitScreenLocation pointerLocation: CGPoint,
        onScreenWithFrame screenFrame: CGRect
    ) -> Bool {
        guard pointerLocation.x.isFinite, pointerLocation.y.isFinite else { return false }
        return interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)
            .contains(pointerLocation)
    }

    /// Where the input bar's window goes: centred under the eye, pushed back
    /// on screen if that would hang it off an edge. AppKit screen coordinates,
    /// bottom-left origin, which is what `NSWindow.setFrameOrigin` wants.
    func inputBarOriginInAppKitScreenCoordinates(
        barSize: CGSize,
        onScreenWithFrame screenFrame: CGRect
    ) -> CGPoint {
        let eyeCenter = eyeCenterInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)

        let idealLeftEdge = eyeCenter.x - barSize.width / 2
        let leftmostAllowedEdge = screenFrame.minX + Self.inputBarMarginFromTheScreenEdge
        let rightmostAllowedEdge =
            screenFrame.maxX - Self.inputBarMarginFromTheScreenEdge - barSize.width
        // `max` last so that a bar wider than the screen still starts on it
        // rather than being pushed off the left edge by the right-edge clamp.
        let clampedLeftEdge = max(leftmostAllowedEdge, min(idealLeftEdge, rightmostAllowedEdge))

        let barTopEdge = eyeCenter.y - eyeDiameter / 2 - Self.gapBetweenTheEyeAndTheInputBar
        let idealBottomEdge = barTopEdge - barSize.height
        let lowestAllowedEdge = screenFrame.minY + Self.inputBarMarginFromTheScreenEdge
        let clampedBottomEdge = max(lowestAllowedEdge, idealBottomEdge)

        return CGPoint(x: clampedLeftEdge, y: clampedBottomEdge)
    }

    /// The bar's whole window frame, in AppKit screen coordinates, for a bar of
    /// the given height. This is the region the reader can actually click,
    /// scroll and select inside, because the bar is its own window and it is
    /// that window — not the overlay — that receives those events.
    func inputBarFrameInAppKitScreenCoordinates(
        barHeight: CGFloat,
        onScreenWithFrame screenFrame: CGRect
    ) -> CGRect {
        let barSize = CGSize(
            width: Self.inputBarWidth,
            height: Self.heightTheInputBarMayActuallyUse(forMeasuredContentHeight: barHeight)
        )
        return CGRect(
            origin: inputBarOriginInAppKitScreenCoordinates(
                barSize: barSize,
                onScreenWithFrame: screenFrame
            ),
            size: barSize
        )
    }

    /// Everything on this screen that belongs to Iris right now: the eye's
    /// click target, plus the bar's window when the bar is open.
    ///
    /// WHY THIS EXISTS SEPARATELY FROM THE CLICK-THROUGH GATE. The gate
    /// (`theOverlayShouldAcceptMouseEvents`) is deliberately *only* the eye and
    /// never grows, because the overlay is the full-screen window and widening
    /// its gate is how a user loses the ability to click their own apps. The
    /// bar's clicks arrive by a completely different route — its own small
    /// window — so the interactive surface grows with the answer without the
    /// overlay's gate moving a pixel. This function is what lets a test state
    /// both halves of that at once: the region Iris occupies grows and shrinks
    /// back, and every point outside it is still the reader's own desktop.
    func rectOccupiedByIris(
        withInputBarOfHeight inputBarHeight: CGFloat?,
        onScreenWithFrame screenFrame: CGRect
    ) -> CGRect {
        let eyeRect = interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)
        guard let inputBarHeight else { return eyeRect }
        let barFrame = inputBarFrameInAppKitScreenCoordinates(
            barHeight: inputBarHeight,
            onScreenWithFrame: screenFrame
        )
        return eyeRect.union(barFrame)
    }

    /// The height the bar's window should actually be given for a measured
    /// content height: never below the floor, never above the ceiling.
    ///
    /// The ceiling is the important half. Everything past it has to scroll
    /// inside the bar, because the alternative is a floating window that grows
    /// down the reader's screen in proportion to how talkative Iris was.
    static func heightTheInputBarMayActuallyUse(
        forMeasuredContentHeight measuredContentHeight: CGFloat
    ) -> CGFloat {
        // NaN means the content has not been measured yet — SwiftUI reports it
        // while a layout settles — and every comparison against it is false, so
        // it would slip through the clamp below and collapse the window to
        // nothing. An infinite height is a different thing: it means "as much
        // as you will give me", and the clamp answers that correctly.
        guard !measuredContentHeight.isNaN else { return shortestTheInputBarMayBe }
        return min(max(measuredContentHeight, shortestTheInputBarMayBe), tallestTheInputBarMayGrow)
    }
}

// MARK: - What the bar suggests

/// The suggestion chips under the input bar, in one place so they are easy to
/// change.
///
/// The rule they are written to: every one of them names something Iris can
/// actually do. It can see the screen, and it can fly its eye over and point at
/// a thing on it. It cannot click anything, type anything, install anything, or
/// remember what you did yesterday, so nothing here offers to.
enum OverlayEyeSuggestions {

    /// A chip is one line, so a step title longer than this is trimmed rather
    /// than allowed to stretch the bar or vanish into an ellipsis mid-word.
    static let longestStepTitleAChipWillCarry = 26

    /// The starters shown when there is nothing more specific going on.
    static let whenNothingElseIsOpen: [String] = [
        "what's on my screen?",
        "point at what i should click",
        "explain this error"
    ]

    /// The starters shown while the reader is part-way through an install
    /// guide. They are about the step in front of them, because that is
    /// overwhelmingly what they are about to ask.
    static func whileFollowingAGuideStep(titled stepTitle: String) -> [String] {
        let shortenedTitle = shortenedForAChip(stepTitle)
        return [
            "what does \"\(shortenedTitle)\" mean?",
            "point at where i do this",
            "i'm stuck on this step"
        ]
    }

    /// The suggestions to show right now. Pass the title of the step the
    /// reader is looking at, or nil when no guide is open.
    static func suggestions(forOpenGuideStepTitled stepTitle: String?) -> [String] {
        guard let stepTitle else { return whenNothingElseIsOpen }
        let trimmedStepTitle = stepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // A guide whose step has an empty title tells the reader nothing, so
        // it falls back rather than offering `what does "" mean?`.
        guard !trimmedStepTitle.isEmpty else { return whenNothingElseIsOpen }
        return whileFollowingAGuideStep(titled: trimmedStepTitle)
    }

    /// What the bar says while Iris is working, which is a different sentence
    /// depending on which part of the work is happening.
    ///
    /// It is spelled out rather than left as a generic spinner because the
    /// screenshot step is the one that makes people uneasy, and saying "looking
    /// at your screen" out loud at the moment it happens is the honest version.
    static func lineShownWhileIrisIsWorking(
        whileTheAssistantIs assistantState: CompanionAssistantState
    ) -> String {
        switch assistantState {
        case .capturing:
            return "looking at your screen…"
        case .thinking:
            return "thinking…"
        case .pointing:
            return "pointing at it…"
        case .idle:
            // Reached for the moment between the send and the pipeline actually
            // starting. "Working" rather than nothing at all, so the bar is
            // never blank under a question that has just been asked.
            return "working…"
        }
    }

    static func shortenedForAChip(_ stepTitle: String) -> String {
        guard stepTitle.count > longestStepTitleAChipWillCarry else { return stepTitle }
        let keptPortion = stepTitle.prefix(longestStepTitleAChipWillCarry)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keptPortion + "…"
    }
}
