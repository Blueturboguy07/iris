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
