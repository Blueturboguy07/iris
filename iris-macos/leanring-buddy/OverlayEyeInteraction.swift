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

    static func shortenedForAChip(_ stepTitle: String) -> String {
        guard stepTitle.count > longestStepTitleAChipWillCarry else { return stepTitle }
        let keptPortion = stepTitle.prefix(longestStepTitleAChipWillCarry)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keptPortion + "…"
    }
}
