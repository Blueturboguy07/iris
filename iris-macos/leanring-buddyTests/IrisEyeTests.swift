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
}
