//
//  IrisEyeTests.swift
//  leanring-buddyTests
//
//  The maths behind the on-screen eye. None of this is visible when it goes
//  wrong — an eye that looks the wrong way still looks like an eye, and a
//  pupil painted at NaN just renders as nothing — so it is all pinned here.
//
//  THE COORDINATE SPACES, stated once, because the whole suite depends on
//  them being right:
//
//    * `IrisEyePupilGeometry` is handed points in **AppKit screen
//      coordinates** — origin bottom-left, y growing *upward*. That is the
//      space `NSEvent.mouseLocation` reports in, which is why the overlay can
//      read the pointer without an Accessibility grant.
//    * It hands back offsets in **SwiftUI view coordinates** — y growing
//      *downward*, which is what `.offset(_:)` consumes.
//
//  So a pointer ABOVE the eye has a LARGER AppKit y and must produce a
//  NEGATIVE SwiftUI height. That single sign is the thing most likely to be
//  wrong, and `theIrisLooksTowardAPointerAboveAndBelowTheEye` is the test
//  that would catch it.
//

import CoreGraphics
import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct IrisEyeTests {

    /// The same eye the overlay draws, so the numbers under test are the
    /// numbers that ship.
    private static let eye = IrisEyePupilGeometry(eyeDiameter: 32)

    /// Somewhere on a second display whose origin is not the main display's,
    /// so nothing in these tests can accidentally pass by assuming the eye
    /// sits at the origin.
    private static let eyeCenter = CGPoint(x: 1440, y: 900)

    // MARK: - Direction

    @Test func theIrisLooksTowardAPointerAboveAndBelowTheEye() {
        // AppKit y grows upward, so "above" is the LARGER y.
        let glanceAtAPointerAbove = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: CGPoint(x: Self.eyeCenter.x, y: Self.eyeCenter.y + 200)
        )
        // SwiftUI y grows downward, so looking up is a NEGATIVE height.
        #expect(glanceAtAPointerAbove.height < 0)
        #expect(abs(glanceAtAPointerAbove.width) < 0.0001)

        let glanceAtAPointerBelow = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: CGPoint(x: Self.eyeCenter.x, y: Self.eyeCenter.y - 200)
        )
        #expect(glanceAtAPointerBelow.height > 0)
        #expect(abs(glanceAtAPointerBelow.width) < 0.0001)

        // The two are mirror images of each other, which is the property that
        // fails loudly if a clamp starts biasing one direction.
        #expect(abs(glanceAtAPointerAbove.height + glanceAtAPointerBelow.height) < 0.0001)
    }

    @Test func theIrisLooksTowardAPointerLeftAndRightOfTheEye() {
        // Horizontal has the same sense in both spaces, so no flip here.
        let glanceAtAPointerToTheRight = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: CGPoint(x: Self.eyeCenter.x + 200, y: Self.eyeCenter.y)
        )
        #expect(glanceAtAPointerToTheRight.width > 0)
        #expect(abs(glanceAtAPointerToTheRight.height) < 0.0001)

        let glanceAtAPointerToTheLeft = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: CGPoint(x: Self.eyeCenter.x - 200, y: Self.eyeCenter.y)
        )
        #expect(glanceAtAPointerToTheLeft.width < 0)
        #expect(abs(glanceAtAPointerToTheLeft.height) < 0.0001)

        #expect(abs(glanceAtAPointerToTheRight.width + glanceAtAPointerToTheLeft.width) < 0.0001)
    }

    @Test func aPointerOnADiagonalPutsTheIrisInTheMatchingQuadrant() {
        // Up and to the right on screen: larger AppKit x AND larger AppKit y.
        let glance = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: CGPoint(
                x: Self.eyeCenter.x + 300,
                y: Self.eyeCenter.y + 300
            )
        )
        // Right and up in SwiftUI terms: positive width, negative height.
        #expect(glance.width > 0)
        #expect(glance.height < 0)
    }

    // MARK: - Magnitude and clamping

    @Test func aPointerAMileAwayStillLeavesThePupilInsideTheLid() {
        // Far enough that any un-clamped offset would be off the screen, let
        // alone off the eye, and probed all the way round the compass so no
        // single lucky direction can carry the test.
        let anAbsurdDistanceAway: CGFloat = 100_000
        for angleInDegrees in stride(from: 0.0, to: 360.0, by: 7.0) {
            let angleInRadians = angleInDegrees * .pi / 180.0
            let pointerLocation = CGPoint(
                x: Self.eyeCenter.x + cos(angleInRadians) * anAbsurdDistanceAway,
                y: Self.eyeCenter.y + sin(angleInRadians) * anAbsurdDistanceAway
            )

            let glance = Self.eye.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
                pointerLocationInAppKitScreenCoordinates: pointerLocation
            )

            #expect(
                Self.eye.glanceKeepsThePupilInsideTheLid(glance),
                "the pupil escaped the lid at \(angleInDegrees)°: \(glance)"
            )
            // And, belt and braces, neither axis alone exceeds its own budget.
            #expect(abs(glance.width) <= Self.eye.maximumHorizontalGlanceInPoints + 0.0001)
            #expect(abs(glance.height) <= Self.eye.maximumVerticalGlanceInPoints + 0.0001)
        }
    }

    @Test func theGlanceGrowsWithDistanceUntilItSaturates() {
        func horizontalGlance(atDistance distance: CGFloat) -> CGFloat {
            Self.eye.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
                pointerLocationInAppKitScreenCoordinates: CGPoint(
                    x: Self.eyeCenter.x + distance,
                    y: Self.eyeCenter.y
                )
            ).width
        }

        let glanceUpClose = horizontalGlance(atDistance: 10)
        let glanceFurtherOut = horizontalGlance(atDistance: 30)
        #expect(glanceUpClose < glanceFurtherOut)

        // Past the limit distance the eye is already rolled as far as it goes,
        // so more distance changes nothing.
        let glanceAtTheLimit = horizontalGlance(atDistance: Self.eye.distanceAtWhichTheGlanceReachesItsLimit)
        let glanceWellPastTheLimit = horizontalGlance(atDistance: 5_000)
        #expect(abs(glanceAtTheLimit - glanceWellPastTheLimit) < 0.0001)
        #expect(abs(glanceAtTheLimit - Self.eye.maximumHorizontalGlanceInPoints) < 0.0001)
    }

    @Test func theClampPullsAnEscapedOffsetBackOntoTheLidWithoutTurningIt() {
        let wildlyOutOfBounds = CGSize(width: 400, height: 400)
        let clamped = Self.eye.clampedToTheLid(wildlyOutOfBounds)

        #expect(Self.eye.glanceKeepsThePupilInsideTheLid(clamped))
        // Same direction: the ratio of the components survives the clamp.
        #expect(abs(clamped.width - clamped.height) < 0.0001)

        // Something already inside is returned untouched.
        let comfortablyInside = CGSize(width: 0.5, height: 0.5)
        let untouched = Self.eye.clampedToTheLid(comfortablyInside)
        #expect(untouched == comfortablyInside)
    }

    // MARK: - Degenerate input

    @Test func aPointerExactlyOnTheEyeGivesZeroOffsetAndNoNaN() {
        let glance = Self.eye.glanceOffsetInSwiftUICoordinates(
            eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
            pointerLocationInAppKitScreenCoordinates: Self.eyeCenter
        )

        #expect(glance == .zero)
        #expect(!glance.width.isNaN)
        #expect(!glance.height.isNaN)
        #expect(glance.width.isFinite)
        #expect(glance.height.isFinite)
    }

    @Test func noPointerAnywhereProducesANonFiniteOffset() {
        // A sweep across the plane, including the axes and the origin, to be
        // sure the divide-by-zero guard is the only one needed.
        for horizontalDistance in stride(from: -200.0, through: 200.0, by: 25.0) {
            for verticalDistance in stride(from: -200.0, through: 200.0, by: 25.0) {
                let glance = Self.eye.glanceOffsetInSwiftUICoordinates(
                    eyeCenterInAppKitScreenCoordinates: Self.eyeCenter,
                    pointerLocationInAppKitScreenCoordinates: CGPoint(
                        x: Self.eyeCenter.x + horizontalDistance,
                        y: Self.eyeCenter.y + verticalDistance
                    )
                )
                #expect(glance.width.isFinite && glance.height.isFinite)
                #expect(Self.eye.glanceKeepsThePupilInsideTheLid(glance))
            }
        }
    }

    // MARK: - Proportions

    @Test func theEyeKeepsTheWebsitesProportionsAtAnySize() {
        let smallEye = IrisEyePupilGeometry(eyeDiameter: 24)
        let largeEye = IrisEyePupilGeometry(eyeDiameter: 96)
        let sizeRatio: CGFloat = 96.0 / 24.0

        #expect(abs(largeEye.lidWidth - smallEye.lidWidth * sizeRatio) < 0.0001)
        #expect(abs(largeEye.lidHeight - smallEye.lidHeight * sizeRatio) < 0.0001)
        #expect(abs(largeEye.irisDiameter - smallEye.irisDiameter * sizeRatio) < 0.0001)
        #expect(abs(largeEye.pupilDiameter - smallEye.pupilDiameter * sizeRatio) < 0.0001)

        // The lid is wider than it is tall, as `78%` against `58%` demands,
        // and the pupil fits inside it in both directions with room to move.
        #expect(smallEye.lidWidth > smallEye.lidHeight)
        #expect(smallEye.maximumHorizontalGlanceInPoints > 0)
        #expect(smallEye.maximumVerticalGlanceInPoints > 0)
        #expect(smallEye.maximumHorizontalGlanceInPoints > smallEye.maximumVerticalGlanceInPoints)
    }

    // MARK: - Idle wander

    @Test func theIdleWanderFollowsTheWebsitesLookKeyframes() {
        // `iris-look` holds the iris centred from 0% to 18% of the cycle.
        let atTheStartOfTheCycle = Self.eye.idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds: 0)
        #expect(abs(atTheStartOfTheCycle.width) < 0.0001)
        #expect(abs(atTheStartOfTheCycle.height) < 0.0001)

        // 28%–44%: `translate(18%, -5%)` — right and up.
        let cycle = IrisEyePupilGeometry.idleWanderCycleSeconds
        let whileGlancingRight = Self.eye.idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds: cycle * 0.36)
        #expect(whileGlancingRight.width > 0)
        #expect(whileGlancingRight.height < 0)

        // 56%–72%: `translate(-16%, 8%)` — left and down.
        let whileGlancingLeft = Self.eye.idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds: cycle * 0.64)
        #expect(whileGlancingLeft.width < 0)
        #expect(whileGlancingLeft.height > 0)

        // It is a cycle, so a whole one later it is back where it started.
        let oneCycleLater = Self.eye.idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds: cycle * 1.36)
        #expect(abs(oneCycleLater.width - whileGlancingRight.width) < 0.0001)
        #expect(abs(oneCycleLater.height - whileGlancingRight.height) < 0.0001)
    }

    @Test func theIdleWanderNeverLetsThePupilLeaveTheLidEither() {
        for tenthsOfASecond in 0...200 {
            let elapsedSeconds = Double(tenthsOfASecond) / 10.0
            let wander = Self.eye.idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds: elapsedSeconds)
            #expect(
                Self.eye.glanceKeepsThePupilInsideTheLid(wander),
                "the idle wander escaped the lid at \(elapsedSeconds)s: \(wander)"
            )
        }
    }

    // MARK: - Tracking versus wandering

    @Test func trackingThePointerOverridesTheIdleWander() {
        var tracker = IrisEyeGazeTracker(pointerLocation: CGPoint(x: 100, y: 100), observedAt: 0)

        // A pointer that has just moved is watched, not wandered away from.
        #expect(tracker.gazeSource(at: 0) == .pointer)

        // And it stays watched right up to the stillness threshold.
        let justBeforeTheThreshold = IrisEyeGazeTracker.secondsOfStillnessBeforeTheIdleWanderResumes - 0.001
        #expect(tracker.gazeSource(at: justBeforeTheThreshold) == .pointer)

        // A move part-way through resets the clock, so the eye keeps watching
        // past the point where it would otherwise have given up.
        tracker.observePointer(at: CGPoint(x: 400, y: 260), timestamp: 2.0)
        let wellPastTheOriginalThreshold = 2.0
            + IrisEyeGazeTracker.secondsOfStillnessBeforeTheIdleWanderResumes
            - 0.001
        #expect(tracker.gazeSource(at: wellPastTheOriginalThreshold) == .pointer)
        #expect(tracker.lastObservedPointerLocation == CGPoint(x: 400, y: 260))
    }

    @Test func theIdleWanderResumesOnceThePointerGoesStill() {
        var tracker = IrisEyeGazeTracker(pointerLocation: CGPoint(x: 100, y: 100), observedAt: 0)
        let threshold = IrisEyeGazeTracker.secondsOfStillnessBeforeTheIdleWanderResumes

        #expect(tracker.gazeSource(at: threshold) == .idleWander)
        #expect(tracker.gazeSource(at: threshold + 60) == .idleWander)

        // Polling a motionless pointer must not keep resetting the clock —
        // the overlay polls at 60fps whether or not anything moved.
        for pollNumber in 1...300 {
            tracker.observePointer(at: CGPoint(x: 100, y: 100), timestamp: Double(pollNumber) / 60.0)
        }
        #expect(tracker.gazeSource(at: 5.0) == .idleWander)

        // One real move and it is watching again.
        tracker.observePointer(at: CGPoint(x: 180, y: 100), timestamp: 5.0)
        #expect(tracker.gazeSource(at: 5.0) == .pointer)
    }

    @Test func handJitterSmallerThanAPointDoesNotCountAsAMove() {
        var tracker = IrisEyeGazeTracker(pointerLocation: CGPoint(x: 100, y: 100), observedAt: 0)

        // A hand resting on a mouse twitches by fractions of a point. If that
        // counted, the eye would never wander on a desk with a hand on it.
        let jitter = IrisEyeGazeTracker.pointerMovementThatCountsAsAMoveInPoints / 4
        tracker.observePointer(at: CGPoint(x: 100 + jitter, y: 100), timestamp: 1.0)
        #expect(tracker.timestampWhenThePointerLastMoved == 0)

        // But the jitter still accumulates: enough of it in one direction is a
        // real move, and is recorded as one.
        tracker.observePointer(
            at: CGPoint(x: 100 + IrisEyeGazeTracker.pointerMovementThatCountsAsAMoveInPoints, y: 100),
            timestamp: 2.0
        )
        #expect(tracker.timestampWhenThePointerLastMoved == 2.0)
    }

    // MARK: - The eye at the size it actually ships at

    /// The eye grew from 32pt to 64pt so it could be seen and hit. Everything
    /// above is proved against a 32pt eye on purpose — the proportions have to
    /// hold at any size — but the size that ships gets its own pass, because a
    /// detail that vanishes at 64pt vanishes for every user.
    @Test func theEyeTheOverlayActuallyDrawsIsBigAndStillEntirelyDrawable() {
        let shippingEye = OverlayEyeInteractionGeometry.eyePupilGeometry

        #expect(shippingEye.eyeDiameter == 64)
        // It is meaningfully larger than the 32pt eye it replaced, which is the
        // whole point of the change.
        #expect(shippingEye.eyeDiameter >= 2 * 32)

        // Every layer still has real area at this size. A sub-point pupil glint
        // is a layer that has silently stopped existing.
        #expect(shippingEye.shellDiameter > 1)
        #expect(shippingEye.shellContentDiameter > 1)
        #expect(shippingEye.lidWidth > 1)
        #expect(shippingEye.lidHeight > 1)
        #expect(shippingEye.irisDiameter > 1)
        #expect(shippingEye.pupilDiameter > 1)
        #expect(shippingEye.pupilGlintDiameter > 1)

        // And the layers still nest: shell inside eye, lid inside shell, iris
        // inside lid, pupil inside iris.
        #expect(shippingEye.shellDiameter < shippingEye.eyeDiameter)
        #expect(shippingEye.lidWidth < shippingEye.shellContentDiameter)
        #expect(shippingEye.irisDiameter < shippingEye.lidWidth)
        #expect(shippingEye.pupilDiameter < shippingEye.irisDiameter)
    }

    @Test func theEnlargedEyeIsTheSmallOneScaledAndItsPupilStillCannotEscape() {
        let shippingEye = OverlayEyeInteractionGeometry.eyePupilGeometry
        let theOldThirtyTwoPointEye = IrisEyePupilGeometry(eyeDiameter: 32)
        let sizeRatio = shippingEye.eyeDiameter / theOldThirtyTwoPointEye.eyeDiameter

        #expect(abs(shippingEye.lidWidth - theOldThirtyTwoPointEye.lidWidth * sizeRatio) < 0.0001)
        #expect(abs(shippingEye.lidHeight - theOldThirtyTwoPointEye.lidHeight * sizeRatio) < 0.0001)
        #expect(abs(shippingEye.irisDiameter - theOldThirtyTwoPointEye.irisDiameter * sizeRatio) < 0.0001)
        #expect(abs(shippingEye.pupilDiameter - theOldThirtyTwoPointEye.pupilDiameter * sizeRatio) < 0.0001)

        // The whole compass, at the size that ships, on a display whose origin
        // is not the main one's.
        let eyeCenter = CGPoint(x: 1440, y: 900)
        for angleInDegrees in stride(from: 0.0, to: 360.0, by: 7.0) {
            let angleInRadians = angleInDegrees * .pi / 180.0
            let glance = shippingEye.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: eyeCenter,
                pointerLocationInAppKitScreenCoordinates: CGPoint(
                    x: eyeCenter.x + cos(angleInRadians) * 50_000,
                    y: eyeCenter.y + sin(angleInRadians) * 50_000
                )
            )
            #expect(
                shippingEye.glanceKeepsThePupilInsideTheLid(glance),
                "the pupil escaped the enlarged lid at \(angleInDegrees)°: \(glance)"
            )
        }

        // The idle wander scales with the eye too, so it also stays inside.
        for tenthsOfASecond in 0...200 {
            let wander = shippingEye.idleWanderOffsetInSwiftUICoordinates(
                atElapsedSeconds: Double(tenthsOfASecond) / 10.0
            )
            #expect(shippingEye.glanceKeepsThePupilInsideTheLid(wander))
        }
    }

    @Test func theGlanceSaturationDistanceGrewWithTheEye() {
        let shippingEye = OverlayEyeInteractionGeometry.eyePupilGeometry

        func horizontalGlance(atDistance distance: CGFloat) -> CGFloat {
            shippingEye.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: .zero,
                pointerLocationInAppKitScreenCoordinates: CGPoint(x: distance, y: 0)
            ).width
        }

        // 60pt used to be far enough to roll the 32pt eye all the way over. On
        // an eye twice the size that distance is barely off its own edge, so it
        // must NOT be fully extended yet — otherwise the enlarged eye would
        // stare at its maximum from the moment the pointer left it.
        #expect(horizontalGlance(atDistance: 60) < shippingEye.maximumHorizontalGlanceInPoints - 0.0001)

        // It still saturates, just proportionally further out.
        let atTheLimit = horizontalGlance(
            atDistance: shippingEye.distanceAtWhichTheGlanceReachesItsLimit
        )
        #expect(abs(atTheLimit - shippingEye.maximumHorizontalGlanceInPoints) < 0.0001)
        #expect(abs(atTheLimit - horizontalGlance(atDistance: 5_000)) < 0.0001)
    }
}

// MARK: - What the eye says has to be readable next to the eye

/// The bug these pin: speech bubbles are positioned from the eye's CENTRE with
/// a fixed offset, and that offset was 10 — a number chosen when the eye was
/// 32pt across. Nothing failed when the eye doubled to 64pt; the text simply
/// started appearing underneath it, and it took a tester's screenshot ("text
/// overlap is a lil' annoying", with the "o" of "over here!" behind the pupil)
/// to notice. A constant that has to track another constant is exactly the
/// thing to derive and then assert.
struct OverlayEyeSpeechClearanceTests {

    @Test func whatTheEyeSaysStartsBeyondTheEyeItself() {
        let geometry = OverlayEyeInteractionGeometry()
        let gap = geometry.horizontalGapFromTheCentreToWhatTheEyeSays

        // Clear of the click-target square, which is the widest the eye ever
        // occupies at rest — not merely clear of the drawn circle.
        #expect(gap > geometry.sideLengthOfTheClickTargetSquare / 2)
        // And clear of the old 10pt offset by enough that the regression is
        // unmistakable rather than marginal.
        #expect(gap > 10)
    }

    /// The offset must be DERIVED from the eye, not written down beside it.
    /// A bigger eye has to move its own speech out of the way.
    @Test func aBiggerEyePushesItsOwnSpeechFurtherOut() {
        let small = OverlayEyeInteractionGeometry(eyeDiameter: 32)
        let shipping = OverlayEyeInteractionGeometry(eyeDiameter: 64)

        #expect(
            shipping.horizontalGapFromTheCentreToWhatTheEyeSays
                > small.horizontalGapFromTheCentreToWhatTheEyeSays
        )
        #expect(
            small.horizontalGapFromTheCentreToWhatTheEyeSays
                > small.sideLengthOfTheClickTargetSquare / 2
        )
    }

    /// The flight pulse scales the eye to 1.3x at the arc's midpoint. A bubble
    /// that clears the resting eye but not the pulsing one overlaps for the
    /// most visible half-second there is.
    @Test func theGapSurvivesTheMidFlightScalePulse() {
        let geometry = OverlayEyeInteractionGeometry()
        let widestVisibleRadiusMidFlight = (geometry.eyeDiameter / 2) * 1.3

        #expect(
            geometry.horizontalGapFromTheCentreToWhatTheEyeSays
                > widestVisibleRadiusMidFlight
        )
    }
}

// MARK: - The click-through guarantee

/// THE MOST IMPORTANT TESTS IN THIS FILE.
///
/// The overlay is a full-screen window sitting above every app on the machine.
/// It is click-through everywhere, and the *only* thing that decides where it
/// stops being click-through is
/// `OverlayEyeInteractionGeometry.theOverlayShouldAcceptMouseEvents`. If that
/// function ever says yes somewhere it should not, the user loses the ability
/// to click their own applications, with nothing drawn on screen to explain
/// why. So it is tested directly, from both sides, on more than one display.
struct OverlayEyeClickThroughTests {

    private static let interactionGeometry = OverlayEyeInteractionGeometry()

    /// The main display.
    private static let primaryScreenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// A second display up and to the right of it, so nothing here can pass by
    /// assuming a screen origin of zero.
    private static let secondaryScreenFrame = CGRect(x: 1920, y: 240, width: 1512, height: 982)

    private static func theOverlayWouldSwallowAClick(
        at pointerLocation: CGPoint,
        onScreenWithFrame screenFrame: CGRect
    ) -> Bool {
        interactionGeometry.theOverlayShouldAcceptMouseEvents(
            forPointerAtAppKitScreenLocation: pointerLocation,
            onScreenWithFrame: screenFrame
        )
    }

    @Test func theInteractiveRectContainsTheWholeEyeOnEveryScreen() {
        for screenFrame in [Self.primaryScreenFrame, Self.secondaryScreenFrame] {
            let eyeCenter = Self.interactionGeometry
                .eyeCenterInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)
            let eyeRadius = Self.interactionGeometry.eyeDiameter / 2

            // The centre, and the four extremes of the eye's own disc.
            #expect(Self.theOverlayWouldSwallowAClick(at: eyeCenter, onScreenWithFrame: screenFrame))
            for edgePoint in [
                CGPoint(x: eyeCenter.x - eyeRadius, y: eyeCenter.y),
                CGPoint(x: eyeCenter.x + eyeRadius, y: eyeCenter.y),
                CGPoint(x: eyeCenter.x, y: eyeCenter.y - eyeRadius),
                CGPoint(x: eyeCenter.x, y: eyeCenter.y + eyeRadius)
            ] {
                #expect(
                    Self.theOverlayWouldSwallowAClick(at: edgePoint, onScreenWithFrame: screenFrame),
                    "the edge of the eye at \(edgePoint) was not clickable"
                )
            }

            // The whole eye sits on the screen rather than half under the menu
            // bar or off the left edge.
            let interactiveRect = Self.interactionGeometry
                .interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)
            #expect(screenFrame.contains(interactiveRect))
        }
    }

    @Test func aClickFarFromTheEyePassesStraightThrough() {
        for screenFrame in [Self.primaryScreenFrame, Self.secondaryScreenFrame] {
            // The place the user is overwhelmingly likely to actually click.
            #expect(!Self.theOverlayWouldSwallowAClick(
                at: CGPoint(x: screenFrame.midX, y: screenFrame.midY),
                onScreenWithFrame: screenFrame
            ))

            // And the four corners, including the one nearest the eye.
            for corner in [
                CGPoint(x: screenFrame.minX, y: screenFrame.minY),
                CGPoint(x: screenFrame.maxX - 1, y: screenFrame.minY),
                CGPoint(x: screenFrame.minX, y: screenFrame.maxY - 1),
                CGPoint(x: screenFrame.maxX - 1, y: screenFrame.maxY - 1)
            ] {
                #expect(
                    !Self.theOverlayWouldSwallowAClick(at: corner, onScreenWithFrame: screenFrame),
                    "the overlay would have eaten a click at the corner \(corner)"
                )
            }
        }
    }

    /// The statement the whole feature rests on, made over the entire display
    /// rather than at a handful of hand-picked points: everything outside one
    /// small square around the eye clicks through.
    @Test func everyPointOnTheScreenAwayFromTheEyeClicksThrough() {
        for screenFrame in [Self.primaryScreenFrame, Self.secondaryScreenFrame] {
            let interactiveRect = Self.interactionGeometry
                .interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)

            var pointsThatWouldBeSwallowed = 0
            var horizontalPosition = screenFrame.minX
            while horizontalPosition < screenFrame.maxX {
                var verticalPosition = screenFrame.minY
                while verticalPosition < screenFrame.maxY {
                    let pointerLocation = CGPoint(x: horizontalPosition, y: verticalPosition)
                    let wouldBeSwallowed = Self.theOverlayWouldSwallowAClick(
                        at: pointerLocation,
                        onScreenWithFrame: screenFrame
                    )
                    if wouldBeSwallowed {
                        pointsThatWouldBeSwallowed += 1
                    }
                    // The gate is open exactly where the eye is and nowhere
                    // else — no stray region, no inverted comparison.
                    #expect(
                        wouldBeSwallowed == interactiveRect.contains(pointerLocation),
                        "the click-through decision at \(pointerLocation) disagreed with the eye's own rect"
                    )
                    // A 16pt grid: fine enough that it lands inside the eye's
                    // 76pt square several times over on every screen tested,
                    // coarse enough that the sweep stays a fast unit test.
                    verticalPosition += 16
                }
                horizontalPosition += 16
            }

            // Sanity: the sweep really did pass over the eye, so a function
            // that always returned false could not pass this test.
            #expect(pointsThatWouldBeSwallowed > 0)
        }
    }

    @Test func theClickableSquareIsATinyFractionOfTheScreen() {
        let interactiveRect = Self.interactionGeometry
            .interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: Self.primaryScreenFrame)
        let fractionOfTheScreenThatIsNotClickThrough =
            (interactiveRect.width * interactiveRect.height)
            / (Self.primaryScreenFrame.width * Self.primaryScreenFrame.height)

        // Under a third of one percent of the display, and under 100pt on a
        // side. This is a guard against a future change quietly widening the
        // interactive region until the overlay starts eating real clicks.
        #expect(fractionOfTheScreenThatIsNotClickThrough < 0.003)
        #expect(interactiveRect.width <= 100)
        #expect(interactiveRect.height <= 100)
    }

    @Test func nonsensePointerLocationsAreTreatedAsClickThrough() {
        // A disconnected display or a mid-transition read can hand back
        // garbage. The safe answer for the overlay is always "let it through".
        for nonsenseLocation in [
            CGPoint(x: CGFloat.nan, y: 0),
            CGPoint(x: 0, y: CGFloat.nan),
            CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        ] {
            #expect(!Self.theOverlayWouldSwallowAClick(
                at: nonsenseLocation,
                onScreenWithFrame: Self.primaryScreenFrame
            ))
        }
    }
}

// MARK: - Clicking the eye

struct OverlayEyeActivationTests {

    @Test func theEyeStartsAsAnEyeWithNoBarOpen() {
        let activation = OverlayEyeActivation()
        #expect(activation.theInputBarIsOpen == false)
        #expect(activation.affordanceToDraw == .eye)
    }

    @Test func clickingTheEyeOpensTheBarAndTurnsTheEyeIntoAGear() {
        var activation = OverlayEyeActivation()

        let whatTheFirstClickDid = activation.registerAClickOnTheEye()
        #expect(whatTheFirstClickDid == .shouldOpenTheInputBar)
        #expect(activation.theInputBarIsOpen)
        #expect(activation.affordanceToDraw == .settingsGear)
    }

    @Test func clickingTheGearOpensSettingsAndLeavesTheBarAlone() {
        var activation = OverlayEyeActivation()
        _ = activation.registerAClickOnTheEye()

        let whatTheSecondClickDid = activation.registerAClickOnTheEye()
        #expect(whatTheSecondClickDid == .shouldOpenTheSettingsPanel)
        // The bar stays: someone who opened settings mid-sentence should find
        // their sentence still there.
        #expect(activation.theInputBarIsOpen)
        #expect(activation.affordanceToDraw == .settingsGear)

        // And it keeps meaning settings for as long as the bar is open.
        let whatTheThirdClickDid = activation.registerAClickOnTheEye()
        #expect(whatTheThirdClickDid == .shouldOpenTheSettingsPanel)
    }

    @Test func dismissingTheBarRestoresTheEye() {
        var activation = OverlayEyeActivation()
        _ = activation.registerAClickOnTheEye()

        activation.dismissTheInputBar()
        #expect(activation.theInputBarIsOpen == false)
        #expect(activation.affordanceToDraw == .eye)

        // And the next click opens the bar again rather than settings.
        let whatTheNextClickDid = activation.registerAClickOnTheEye()
        #expect(whatTheNextClickDid == .shouldOpenTheInputBar)
    }

    @Test func dismissingABarThatIsNotOpenChangesNothing() {
        var activation = OverlayEyeActivation()
        activation.dismissTheInputBar()
        #expect(activation.affordanceToDraw == .eye)

        let whatTheClickDid = activation.registerAClickOnTheEye()
        #expect(whatTheClickDid == .shouldOpenTheInputBar)
    }
}

// MARK: - Where the bar hangs

struct OverlayEyeInputBarPlacementTests {

    private static let interactionGeometry = OverlayEyeInteractionGeometry()
    private static let barSize = CGSize(
        width: OverlayEyeInteractionGeometry.inputBarWidth,
        height: 132
    )

    @Test func theBarHangsBelowTheEyeAndStaysOnTheScreen() {
        for screenFrame in [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 240, width: 1512, height: 982),
            CGRect(x: -1440, y: -300, width: 1440, height: 900)
        ] {
            let barOrigin = Self.interactionGeometry.inputBarOriginInAppKitScreenCoordinates(
                barSize: Self.barSize,
                onScreenWithFrame: screenFrame
            )
            let barFrame = CGRect(origin: barOrigin, size: Self.barSize)

            // Entirely on the screen it belongs to. The eye sits near the left
            // edge, so a bar merely centred under it would hang off the side.
            #expect(
                screenFrame.contains(barFrame),
                "the input bar at \(barFrame) escaped the screen \(screenFrame)"
            )

            // Below the eye, not over it.
            let eyeCenter = Self.interactionGeometry
                .eyeCenterInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)
            let bottomOfTheEye = eyeCenter.y - Self.interactionGeometry.eyeDiameter / 2
            #expect(barFrame.maxY <= bottomOfTheEye)

            // And close enough to read as attached to it.
            #expect(bottomOfTheEye - barFrame.maxY <= OverlayEyeInteractionGeometry.gapBetweenTheEyeAndTheInputBar + 0.0001)
        }
    }

    @Test func aBarTallerThanTheSpaceBelowTheEyeIsPushedOntoTheScreenRatherThanOffIt() {
        // A short screen with the eye near its top leaves less room below the
        // eye than the bar needs.
        let shortScreenFrame = CGRect(x: 0, y: 0, width: 1280, height: 400)
        let tallBarSize = CGSize(width: OverlayEyeInteractionGeometry.inputBarWidth, height: 380)

        let barOrigin = Self.interactionGeometry.inputBarOriginInAppKitScreenCoordinates(
            barSize: tallBarSize,
            onScreenWithFrame: shortScreenFrame
        )

        // It is clamped to the bottom margin rather than being placed off the
        // bottom of the display where none of it could be read.
        #expect(barOrigin.y >= shortScreenFrame.minY + OverlayEyeInteractionGeometry.inputBarMarginFromTheScreenEdge - 0.0001)
        #expect(barOrigin.x >= shortScreenFrame.minX)
    }
}

// MARK: - What the bar suggests

struct OverlayEyeSuggestionTests {

    @Test func withNoGuideOpenTheBarOffersItsGeneralStarters() {
        #expect(
            OverlayEyeSuggestions.suggestions(forOpenGuideStepTitled: nil)
                == OverlayEyeSuggestions.whenNothingElseIsOpen
        )
        #expect(!OverlayEyeSuggestions.whenNothingElseIsOpen.isEmpty)
    }

    @Test func anOpenGuideStepChangesWhatTheBarSuggests() {
        let suggestionsWhileFollowingAGuide = OverlayEyeSuggestions.suggestions(
            forOpenGuideStepTitled: "Install Homebrew"
        )

        #expect(suggestionsWhileFollowingAGuide != OverlayEyeSuggestions.whenNothingElseIsOpen)
        // They are about the step the reader is actually looking at.
        #expect(suggestionsWhileFollowingAGuide.contains { $0.contains("Install Homebrew") })
        #expect(!suggestionsWhileFollowingAGuide.isEmpty)
    }

    @Test func aGuideStepWithNoRealTitleFallsBackRatherThanQuotingNothing() {
        // `what does "" mean?` is worse than no suggestion at all.
        #expect(
            OverlayEyeSuggestions.suggestions(forOpenGuideStepTitled: "")
                == OverlayEyeSuggestions.whenNothingElseIsOpen
        )
        #expect(
            OverlayEyeSuggestions.suggestions(forOpenGuideStepTitled: "   \n ")
                == OverlayEyeSuggestions.whenNothingElseIsOpen
        )
    }

    @Test func aVeryLongStepTitleIsTrimmedSoTheChipStaysOneLine() {
        let aVeryLongStepTitle = "Clone the repository and install every one of its dependencies"
        let suggestions = OverlayEyeSuggestions.suggestions(forOpenGuideStepTitled: aVeryLongStepTitle)

        // No chip carries the whole title.
        #expect(!suggestions.contains { $0.contains(aVeryLongStepTitle) })
        // The trimmed title is marked as trimmed rather than silently cut.
        #expect(suggestions.contains { $0.contains("…") })
        // A title that fits is left exactly as it is.
        #expect(OverlayEyeSuggestions.shortenedForAChip("Install Node") == "Install Node")
    }
}

// MARK: - The answer arrives at the eye, not in the old panel

/// THE BUG THIS WHOLE CHANGE EXISTS TO FIX.
///
/// The bar under the eye used to take a question and then post
/// `.clickyShowPanel`, so the answer rendered in the menu bar panel. One
/// conversation, two windows: a minimal bar that threw the reader somewhere
/// else the moment they actually used it.
///
/// There is no object to interrogate for "did the view post a notification" —
/// the hand-off was three lines inside a SwiftUI view's send function — so this
/// reads the source of the bar and states the absence directly. It is the only
/// way to pin a *deletion*, and a deletion is exactly what was asked for.
struct OverlayEyeBarDoesNotDelegateToTheOldPanelTests {

    /// The bar's own source, found relative to this test file. `#filePath` is
    /// baked in at compile time from the repository the tests were built in, so
    /// this resolves wherever the checkout lives.
    private static var sourceOfTheInputBar: String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFileURL
            .deletingLastPathComponent()      // leanring-buddyTests
            .deletingLastPathComponent()      // iris-macos
        let inputBarSourceURL = repositoryRoot
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("OverlayEyeInputBar.swift")
        return (try? String(contentsOf: inputBarSourceURL, encoding: .utf8)) ?? ""
    }

    @Test func theBarNeverAsksTheOldPanelToOpen() {
        let source = Self.sourceOfTheInputBar
        // Sanity first: a missing or unreadable file must fail loudly rather
        // than pass by finding nothing in an empty string.
        #expect(source.contains("OverlayEyeInputBarView"), "the bar's source could not be read")

        // The notifications that open the menu bar panel. Neither may appear in
        // the bar, in a comment or otherwise — the comment that used to sit
        // above the post explained the hand-off, and it went with it.
        #expect(!source.contains("clickyShowPanel"))
        #expect(!source.contains("clickyTogglePanel"))
        // And nothing posts anything at all from here any more.
        #expect(!source.contains("NotificationCenter"))
    }

    @Test func theBarRendersTheAnswerItself() {
        let source = Self.sourceOfTheInputBar
        // The other half of the same statement: the answer is drawn here. If
        // somebody deletes the answer area and re-adds the hand-off, the test
        // above alone would not notice the first half of that.
        #expect(source.contains("latestAssistantResponseText"))
        #expect(source.contains("answerArea"))
    }
}

// MARK: - The exchange the bar shows

/// The bar is one small surface that changes state: chips, then the question
/// with a working line, then the question with the answer, then the field again
/// for a follow-up. These pin every transition, including the ones that must
/// *not* happen.
struct OverlayEyeExchangeTests {

    @Test func theBarOpensReadyForAQuestionWithNothingOnIt() {
        let exchange = OverlayEyeExchange()

        #expect(exchange.phase == .composingTheFirstQuestion)
        #expect(exchange.questionTheReaderAsked == nil)
        #expect(exchange.whatIrisSaidBack == nil)
        #expect(exchange.theSuggestionChipsShouldBeOffered)
        #expect(!exchange.thereIsAnExchangeOnScreen)
    }

    @Test func composingThenWorkingThenAnsweredThenComposingAFollowUp() {
        var exchange = OverlayEyeExchange()
        #expect(exchange.phase == .composingTheFirstQuestion)

        // Asked.
        exchange.registerTheReaderAsked("what's on my screen?")
        #expect(exchange.phase == .waitingForIrisToAnswer)
        #expect(exchange.questionTheReaderAsked == "what's on my screen?")
        // The question stays up while Iris works, so a slow answer never
        // arrives next to a blank space.
        #expect(exchange.thereIsAnExchangeOnScreen)
        // And the chips are gone: three suggestions competing with the thing
        // you are waiting for is noise.
        #expect(!exchange.theSuggestionChipsShouldBeOffered)

        // Answered.
        exchange.registerIrisAnswered("xcode, with a build running", theAnswerIsAFailureMessage: false)
        #expect(exchange.phase == .showingTheAnswer)
        #expect(exchange.whatIrisSaidBack == "xcode, with a build running")
        #expect(exchange.questionTheReaderAsked == "what's on my screen?")
        #expect(!exchange.whatIrisSaidBackIsAFailureMessage)

        // Composing again, without reopening anything.
        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.phase == .composingAFollowUp)
        // The answer they are following up on is still in front of them.
        #expect(exchange.whatIrisSaidBack == "xcode, with a build running")

        // And the follow-up runs the same loop again.
        exchange.registerTheReaderAsked("which target?")
        #expect(exchange.phase == .waitingForIrisToAnswer)
        #expect(exchange.questionTheReaderAsked == "which target?")
        // The previous answer goes when the new question is asked: the bar
        // shows one exchange, and this is now that exchange.
        #expect(exchange.whatIrisSaidBack == nil)
    }

    @Test func anEmptyQuestionCannotPutTheBarIntoAWorkingState() {
        var exchange = OverlayEyeExchange()

        exchange.registerTheReaderAsked("   \n  ")
        // Nothing was sent, so nothing is coming back, and a bar spinning
        // forever on a question nobody asked is worse than no bar at all.
        #expect(exchange.phase == .composingTheFirstQuestion)
        #expect(exchange.questionTheReaderAsked == nil)
    }

    @Test func theQuestionIsStoredTrimmedTheWayItIsSent() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("  explain this error \n")
        #expect(exchange.questionTheReaderAsked == "explain this error")
    }

    @Test func anAnswerThatArrivesWhenNothingWasAskedIsIgnored() {
        var exchange = OverlayEyeExchange()

        // A response landing after the reader dismissed the bar and opened it
        // again must not paste a stale answer under a question they have not
        // asked yet.
        exchange.registerIrisAnswered("something from last time", theAnswerIsAFailureMessage: false)
        #expect(exchange.phase == .composingTheFirstQuestion)
        #expect(exchange.whatIrisSaidBack == nil)

        // Nor may a second response overwrite the one being read.
        exchange.registerTheReaderAsked("what is this?")
        exchange.registerIrisAnswered("the first answer", theAnswerIsAFailureMessage: false)
        exchange.registerIrisAnswered("a late duplicate", theAnswerIsAFailureMessage: false)
        #expect(exchange.whatIrisSaidBack == "the first answer")
    }

    @Test func goingBackToTheFieldOnlyMeansSomethingOnceThereIsAnAnswer() {
        var exchange = OverlayEyeExchange()

        // Before anything is asked there is nothing to follow up on.
        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.phase == .composingTheFirstQuestion)

        // And while Iris is still working, the field is not the thing to
        // interrupt — every keystroke in that moment belongs to the app the
        // reader went back to.
        exchange.registerTheReaderAsked("what's this?")
        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.phase == .waitingForIrisToAnswer)
    }

    @Test func dismissingTheBarClearsTheWholeExchange() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")
        exchange.registerIrisAnswered("xcode", theAnswerIsAFailureMessage: false)

        exchange.clearTheWholeExchange()

        // Reopening the bar is a new conversation at the eye, not a resumed one.
        #expect(exchange == OverlayEyeExchange())
        #expect(exchange.phase == .composingTheFirstQuestion)
        #expect(exchange.questionTheReaderAsked == nil)
        #expect(exchange.whatIrisSaidBack == nil)
        #expect(!exchange.whatIrisSaidBackIsAFailureMessage)
    }
}

// MARK: - A failure is shown where an answer would be

struct OverlayEyeExchangeFailureTests {

    @Test func aFailureLandsInTheSamePlaceAnAnswerWouldAndLeavesTheBarOpen() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")

        let sentenceTheTransportProduces = AssistantTransportError.noCredentialsAvailable.userFacingMessage
        exchange.registerIrisAnswered(
            sentenceTheTransportProduces,
            theAnswerIsAFailureMessage: true
        )

        // Same phase, same field, same slot on screen: from the reader's side
        // "Iris could not answer" is what came back from what they asked, and a
        // separate alert would be the second surface all over again.
        #expect(exchange.phase == .showingTheAnswer)
        #expect(exchange.whatIrisSaidBack == sentenceTheTransportProduces)
        #expect(exchange.whatIrisSaidBackIsAFailureMessage)
        #expect(exchange.thereIsAnExchangeOnScreen)
        #expect(exchange.questionTheReaderAsked == "what's on my screen?")
    }

    @Test func aFollowUpCanBeAskedStraightAfterAFailure() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")
        exchange.registerIrisAnswered(
            AssistantTransportError.assistantUnavailable.userFacingMessage,
            theAnswerIsAFailureMessage: true
        )

        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.phase == .composingAFollowUp)
        #expect(exchange.theBarShouldHoldTheKeyboard)

        exchange.registerTheReaderAsked("try again")
        #expect(exchange.phase == .waitingForIrisToAnswer)
        // The failure tint does not survive into the next exchange.
        #expect(!exchange.whatIrisSaidBackIsAFailureMessage)
    }

    @Test func everyTransportFailureHasASentenceTheBarCanShow() {
        // The bar renders whatever `describeAndHandle` hands it, so an error
        // with an empty sentence would render as an empty card.
        for transportError: AssistantTransportError in [
            .noCredentialsAvailable,
            .signInRequired,
            .rateLimited(retryAfterSeconds: 30),
            .dailyBudgetExhausted(retryAfterSeconds: nil),
            .assistantUnavailable,
            .transportFailure(reason: "the network went away")
        ] {
            var exchange = OverlayEyeExchange()
            exchange.registerTheReaderAsked("anything")
            exchange.registerIrisAnswered(
                transportError.userFacingMessage,
                theAnswerIsAFailureMessage: true
            )
            #expect(exchange.whatIrisSaidBack?.isEmpty == false)
            #expect(exchange.phase == .showingTheAnswer)
        }
    }
}

// MARK: - Who holds the keyboard

/// The bar lives in a panel that can become key, because a text field in a
/// window that cannot be key never sees a keystroke. The danger is the panel
/// *staying* key after the question has gone: during an earlier verification
/// pass the literal characters the user typed into their own editor landed in
/// this bar. `theBarShouldHoldTheKeyboard` is the rule that decides it, and the
/// panel manager does exactly what it says.
struct OverlayEyeKeyboardFocusTests {

    @Test func theBarHoldsTheKeyboardWhileAQuestionIsBeingTyped() {
        let exchange = OverlayEyeExchange()
        #expect(exchange.theBarShouldHoldTheKeyboard)
    }

    @Test func theKeyboardIsReleasedTheMomentAQuestionIsSent() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")

        // The reader has gone back to whatever they were doing. Their
        // keystrokes go with them.
        #expect(!exchange.theBarShouldHoldTheKeyboard)
    }

    @Test func theKeyboardStaysReleasedWhileTheAnswerIsBeingRead() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")
        exchange.registerIrisAnswered("xcode", theAnswerIsAFailureMessage: false)

        #expect(!exchange.theBarShouldHoldTheKeyboard)
    }

    @Test func clickingBackIntoTheFieldTakesTheKeyboardBack() {
        var exchange = OverlayEyeExchange()
        exchange.registerTheReaderAsked("what's on my screen?")
        exchange.registerIrisAnswered("xcode", theAnswerIsAFailureMessage: false)
        #expect(!exchange.theBarShouldHoldTheKeyboard)

        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.theBarShouldHoldTheKeyboard)

        // And sending the follow-up hands it straight back again.
        exchange.registerTheReaderAsked("which target?")
        #expect(!exchange.theBarShouldHoldTheKeyboard)
    }

    @Test func theKeyboardIsHeldOnlyWhileSomethingIsBeingComposed() {
        // Stated as an exhaustive property rather than four separate cases, so
        // a phase added later cannot quietly default to holding the keyboard.
        var exchange = OverlayEyeExchange()
        let phasesWhereTheKeyboardIsHeld: Set<OverlayEyeExchangePhase> = [
            .composingTheFirstQuestion,
            .composingAFollowUp
        ]

        #expect(exchange.theBarShouldHoldTheKeyboard
                == phasesWhereTheKeyboardIsHeld.contains(exchange.phase))
        exchange.registerTheReaderAsked("a")
        #expect(exchange.theBarShouldHoldTheKeyboard
                == phasesWhereTheKeyboardIsHeld.contains(exchange.phase))
        exchange.registerIrisAnswered("b", theAnswerIsAFailureMessage: false)
        #expect(exchange.theBarShouldHoldTheKeyboard
                == phasesWhereTheKeyboardIsHeld.contains(exchange.phase))
        exchange.registerTheReaderWentBackToTheField()
        #expect(exchange.theBarShouldHoldTheKeyboard
                == phasesWhereTheKeyboardIsHeld.contains(exchange.phase))
    }
}

// MARK: - What Iris occupies while the bar is expanded

/// THE OTHER MOST IMPORTANT TESTS IN THIS FILE, alongside
/// `OverlayEyeClickThroughTests` above.
///
/// When an answer arrives the bar gets taller. The reader has to be able to
/// scroll and select inside it, which means the region that accepts a mouse
/// event has to grow with it — and shrink back, and never cover anything else.
///
/// The two halves of that are deliberately different mechanisms:
///
///   * The **overlay's** click-through gate never moves. It is the full-screen
///     window, and widening its gate is precisely how a user loses the ability
///     to click their own apps. It is the eye's 76pt square in every state of
///     the bar.
///   * The **bar's own window** is what grows. Its clicks and scrolls are
///     delivered to it directly and never travel through the overlay at all.
///
/// So these tests state both at once: the region Iris occupies grows with the
/// answer and shrinks back on dismissal, the gate does not budge, and a point
/// out in the middle of the reader's screen is outside everything in every
/// state.
struct OverlayEyeExpandedBarClickThroughTests {

    private static let interactionGeometry = OverlayEyeInteractionGeometry()

    private static let screenFrames = [
        CGRect(x: 0, y: 0, width: 1920, height: 1080),
        CGRect(x: 1920, y: 240, width: 1512, height: 982),
        CGRect(x: -1440, y: -300, width: 1440, height: 900)
    ]

    /// The three heights the bar actually takes: the opening state with its
    /// chips, the working state, and a long answer that has hit the ceiling.
    private static let heightWhileComposing: CGFloat = 132
    private static let heightWhileWorking: CGFloat = 150
    private static let heightShowingALongAnswer: CGFloat =
        OverlayEyeInteractionGeometry.tallestTheInputBarMayGrow

    @Test func theRegionIrisOccupiesGrowsWithTheAnswerAndShrinksBackOnDismissal() {
        for screenFrame in Self.screenFrames {
            let whileComposing = Self.interactionGeometry.rectOccupiedByIris(
                withInputBarOfHeight: Self.heightWhileComposing,
                onScreenWithFrame: screenFrame
            )
            let whileShowingALongAnswer = Self.interactionGeometry.rectOccupiedByIris(
                withInputBarOfHeight: Self.heightShowingALongAnswer,
                onScreenWithFrame: screenFrame
            )
            let afterDismissal = Self.interactionGeometry.rectOccupiedByIris(
                withInputBarOfHeight: nil,
                onScreenWithFrame: screenFrame
            )

            // Grows.
            #expect(whileShowingALongAnswer.height > whileComposing.height)
            // And the composing bar is entirely inside the expanded one, so the
            // field never moves out from under the reader as the answer lands.
            #expect(whileShowingALongAnswer.contains(whileComposing))

            // Shrinks back to the eye alone.
            #expect(afterDismissal == Self.interactionGeometry
                .interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame))
            #expect(afterDismissal.height < whileComposing.height)

            // Nothing Iris occupies ever leaves the screen it belongs to.
            for occupiedRect in [whileComposing, whileShowingALongAnswer, afterDismissal] {
                #expect(
                    screenFrame.contains(occupiedRect),
                    "Iris occupied \(occupiedRect), which is off the screen \(screenFrame)"
                )
            }
        }
    }

    @Test func theBarsOwnWindowIsWhatGrows() {
        for screenFrame in Self.screenFrames {
            let composingFrame = Self.interactionGeometry.inputBarFrameInAppKitScreenCoordinates(
                barHeight: Self.heightWhileComposing,
                onScreenWithFrame: screenFrame
            )
            let answeredFrame = Self.interactionGeometry.inputBarFrameInAppKitScreenCoordinates(
                barHeight: Self.heightShowingALongAnswer,
                onScreenWithFrame: screenFrame
            )

            // Taller, same width, and hanging from the same top edge — it grows
            // downward into empty desktop rather than sliding up over the eye.
            #expect(answeredFrame.height > composingFrame.height)
            #expect(answeredFrame.width == composingFrame.width)
            #expect(abs(answeredFrame.maxY - composingFrame.maxY) < 0.0001)
        }
    }

    @Test func theOverlaysGateDoesNotMoveNoMatterHowTallTheBarGets() {
        for screenFrame in Self.screenFrames {
            let gateRect = Self.interactionGeometry
                .interactiveRectInAppKitScreenCoordinates(onScreenWithFrame: screenFrame)

            // The gate is the eye's square, full stop. The bar's own window is
            // what receives the bar's clicks, so this never has to grow — and
            // it must not, because it belongs to the full-screen overlay.
            #expect(gateRect.width <= 100)
            #expect(gateRect.height <= 100)

            // A point in the middle of the expanded bar is *not* somewhere the
            // overlay accepts events. That is correct and load-bearing: the
            // overlay stays click-through there so the event reaches the bar's
            // own window underneath it.
            let expandedBarFrame = Self.interactionGeometry.inputBarFrameInAppKitScreenCoordinates(
                barHeight: Self.heightShowingALongAnswer,
                onScreenWithFrame: screenFrame
            )
            let middleOfTheAnswer = CGPoint(x: expandedBarFrame.midX, y: expandedBarFrame.minY + 20)
            #expect(!Self.interactionGeometry.theOverlayShouldAcceptMouseEvents(
                forPointerAtAppKitScreenLocation: middleOfTheAnswer,
                onScreenWithFrame: screenFrame
            ))
        }
    }

    @Test func aPointFarFromTheEyeIsOutsideEverythingInEveryState() {
        for screenFrame in Self.screenFrames {
            let placesTheReaderIsActuallyWorking = [
                CGPoint(x: screenFrame.midX, y: screenFrame.midY),
                CGPoint(x: screenFrame.maxX - 1, y: screenFrame.minY),
                CGPoint(x: screenFrame.maxX - 1, y: screenFrame.maxY - 1),
                CGPoint(x: screenFrame.minX, y: screenFrame.minY),
                // Directly below the eye but far past where even a
                // ceiling-height bar can reach.
                CGPoint(
                    x: screenFrame.minX + 58,
                    y: screenFrame.minY + 8
                )
            ]

            for barHeight: CGFloat? in [
                nil,
                Self.heightWhileComposing,
                Self.heightWhileWorking,
                Self.heightShowingALongAnswer
            ] {
                let occupiedRect = Self.interactionGeometry.rectOccupiedByIris(
                    withInputBarOfHeight: barHeight,
                    onScreenWithFrame: screenFrame
                )
                for pointerLocation in placesTheReaderIsActuallyWorking {
                    #expect(
                        !occupiedRect.contains(pointerLocation),
                        "Iris claimed \(pointerLocation) on \(screenFrame) with a bar of height \(String(describing: barHeight))"
                    )
                    // And the overlay's own gate agrees, in every state.
                    #expect(!Self.interactionGeometry.theOverlayShouldAcceptMouseEvents(
                        forPointerAtAppKitScreenLocation: pointerLocation,
                        onScreenWithFrame: screenFrame
                    ))
                }
            }
        }
    }

    @Test func aVeryLongAnswerScrollsRatherThanGrowingTheBarWithoutLimit() {
        // The bar floats over whatever the reader is really working in. A
        // thousand-word answer that grew the window to match would be a wall
        // across their screen that they did not ask for.
        let absurdContentHeight: CGFloat = 4_000
        let heightActuallyUsed = OverlayEyeInteractionGeometry
            .heightTheInputBarMayActuallyUse(forMeasuredContentHeight: absurdContentHeight)
        #expect(heightActuallyUsed == OverlayEyeInteractionGeometry.tallestTheInputBarMayGrow)

        // The answer's own scrolling area is capped below the bar's ceiling, so
        // the field above it can never be pushed off the bottom of the bar.
        #expect(OverlayEyeInteractionGeometry.tallestTheAnswerAreaMayGrow
                < OverlayEyeInteractionGeometry.tallestTheInputBarMayGrow)

        // A ceiling-height bar still fits on a normal display.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let barFrame = Self.interactionGeometry.inputBarFrameInAppKitScreenCoordinates(
            barHeight: heightActuallyUsed,
            onScreenWithFrame: screenFrame
        )
        #expect(screenFrame.contains(barFrame))
    }

    @Test func aMeasurementThatArrivesBeforeTheContentLaysOutCannotCollapseTheBar() {
        // SwiftUI reports a height of zero for one pass while it settles, and a
        // window of height zero is a bar that vanished.
        #expect(OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(forMeasuredContentHeight: 0)
                == OverlayEyeInteractionGeometry.shortestTheInputBarMayBe)
        #expect(OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(forMeasuredContentHeight: -20)
                == OverlayEyeInteractionGeometry.shortestTheInputBarMayBe)
        #expect(OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(forMeasuredContentHeight: .nan)
                == OverlayEyeInteractionGeometry.shortestTheInputBarMayBe)
        #expect(OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(forMeasuredContentHeight: .infinity)
                == OverlayEyeInteractionGeometry.tallestTheInputBarMayGrow)
    }
}

// MARK: - The bar and the eye agree about what is happening

struct OverlayEyeWorkingLineTests {

    @Test func everyAssistantStateHasSomethingForTheBarToSay() {
        // A spinning eye above a blank bar reads as broken. Every state the eye
        // has a mood for, the bar has a sentence for.
        for assistantState: CompanionAssistantState in [.idle, .capturing, .thinking, .pointing] {
            let line = OverlayEyeSuggestions.lineShownWhileIrisIsWorking(
                whileTheAssistantIs: assistantState
            )
            #expect(!line.isEmpty)
        }
    }

    @Test func theBarNamesTheScreenshotOutLoudAtTheMomentItHappens() {
        // The capture is the step that makes people uneasy, so it is said
        // rather than hidden behind a generic spinner.
        #expect(OverlayEyeSuggestions
            .lineShownWhileIrisIsWorking(whileTheAssistantIs: .capturing)
            .contains("screen"))
        #expect(OverlayEyeSuggestions
            .lineShownWhileIrisIsWorking(whileTheAssistantIs: .thinking)
            != OverlayEyeSuggestions.lineShownWhileIrisIsWorking(whileTheAssistantIs: .capturing))
    }
}

// MARK: - The bar's own window, driven for real

/// The tests above pin the *rules*. These drive a real `NSPanel` through the
/// same transitions, because the rules are only worth anything if the window
/// actually does what they say: it has to give up the keyboard on send, be
/// unable to take it back by accident, take it back on request, grow when an
/// answer arrives and shrink when the next question replaces it.
@MainActor
struct OverlayEyeInputBarPanelTests {

    private static let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func aBarShowingOnScreen() -> (OverlayEyeInputBarPanelManager, CompanionManager) {
        let panelManager = OverlayEyeInputBarPanelManager()
        let companionManager = CompanionManager()
        panelManager.showInputBar(
            forEyeAtInteractionGeometry: OverlayEyeInteractionGeometry(),
            onScreenWithFrame: Self.screenFrame,
            companionManager: companionManager,
            onTheBarClosing: {}
        )
        return (panelManager, companionManager)
    }

    @Test func theBarTakesTheKeyboardWhenItOpensAndGivesItBackOnSend() {
        let (panelManager, _) = aBarShowingOnScreen()
        defer { panelManager.hideInputBar() }

        // Open: the field has to be typeable, so the window has to be able to
        // be key.
        #expect(panelManager.isShowingTheInputBar)
        #expect(panelManager.theBarIsAskingForTheKeyboard)
        #expect(panelManager.theBarsWindowCouldBecomeKeyRightNow)

        // Sent: the reader has gone back to their own app, and the window can
        // no longer be handed the keyboard by AppKit, by a stray click, or by
        // anything else that has not asked for it.
        panelManager.releaseTheKeyboardSoTheReadersOwnAppGetsItBack()
        #expect(!panelManager.theBarIsAskingForTheKeyboard)
        #expect(!panelManager.theBarsWindowCouldBecomeKeyRightNow)

        // And the bar is still on screen — the answer has to land somewhere.
        #expect(panelManager.isShowingTheInputBar)
        #expect(panelManager.frameOfTheBarOnScreen != nil)
    }

    @Test func clickingBackIntoTheFieldMakesTheBarTypeableAgain() {
        let (panelManager, _) = aBarShowingOnScreen()
        defer { panelManager.hideInputBar() }

        panelManager.releaseTheKeyboardSoTheReadersOwnAppGetsItBack()
        #expect(!panelManager.theBarsWindowCouldBecomeKeyRightNow)

        panelManager.takeTheKeyboardBackForTheTextField()
        #expect(panelManager.theBarIsAskingForTheKeyboard)
        #expect(panelManager.theBarsWindowCouldBecomeKeyRightNow)

        // And a second question hands it straight back again.
        panelManager.releaseTheKeyboardSoTheReadersOwnAppGetsItBack()
        #expect(!panelManager.theBarsWindowCouldBecomeKeyRightNow)
    }

    @Test func aDismissedBarKeepsNoClaimOnTheKeyboard() {
        let (panelManager, _) = aBarShowingOnScreen()

        panelManager.hideInputBar()
        #expect(!panelManager.isShowingTheInputBar)
        #expect(!panelManager.theBarIsAskingForTheKeyboard)
        #expect(!panelManager.theBarsWindowCouldBecomeKeyRightNow)
        #expect(panelManager.frameOfTheBarOnScreen == nil)
    }

    @Test func theBarsWindowGrowsWithAnAnswerAndShrinksBackForTheNextQuestion() {
        let (panelManager, _) = aBarShowingOnScreen()
        defer { panelManager.hideInputBar() }

        guard let frameWhileComposing = panelManager.frameOfTheBarOnScreen else {
            Issue.record("the bar was not on screen")
            return
        }

        // An answer arrives and the content gets taller.
        panelManager.resizeTheBarToFit(measuredContentHeight: 320)
        guard let frameWhileShowingAnAnswer = panelManager.frameOfTheBarOnScreen else {
            Issue.record("the bar left the screen while growing")
            return
        }
        #expect(frameWhileShowingAnAnswer.height == 320)
        #expect(frameWhileShowingAnAnswer.height > frameWhileComposing.height)
        // The region that can take a click or a scroll really did grow, and it
        // grew downward: the field stays exactly where the reader left it.
        #expect(abs(frameWhileShowingAnAnswer.maxY - frameWhileComposing.maxY) < 0.5)
        #expect(frameWhileShowingAnAnswer.contains(frameWhileComposing))

        // The next question replaces the answer and the bar shrinks back.
        panelManager.resizeTheBarToFit(measuredContentHeight: frameWhileComposing.height)
        #expect(panelManager.frameOfTheBarOnScreen?.height == frameWhileComposing.height)

        // And an answer nobody could read in one window is capped rather than
        // drawn down the whole display.
        panelManager.resizeTheBarToFit(measuredContentHeight: 5_000)
        #expect(panelManager.frameOfTheBarOnScreen?.height
                == OverlayEyeInteractionGeometry.tallestTheInputBarMayGrow)
        #expect(Self.screenFrame.contains(panelManager.frameOfTheBarOnScreen ?? .infinite))
    }

    @Test func theBarStaysOnItsScreenAtEverySizeItCanBe() {
        let (panelManager, _) = aBarShowingOnScreen()
        defer { panelManager.hideInputBar() }

        for measuredContentHeight in stride(from: CGFloat(40), through: 500, by: 20) {
            panelManager.resizeTheBarToFit(measuredContentHeight: measuredContentHeight)
            guard let barFrame = panelManager.frameOfTheBarOnScreen else {
                Issue.record("the bar vanished at height \(measuredContentHeight)")
                return
            }
            #expect(
                Self.screenFrame.contains(barFrame),
                "the bar at content height \(measuredContentHeight) was at \(barFrame), off the screen"
            )
        }
    }
}
