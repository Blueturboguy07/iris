//
//  Test6EscapeHatchTests.swift
//  leanring-buddyTests
//
//  The reader's complaint, verbatim: "The terminal Iris is using is not movable
//  at all, you can't close out of it" — and then, directly: "the traffic light
//  doesn't actually work, it's not functional."
//
//  The red dot is drawn to look exactly like a Mac close button, × on hover and
//  all, and it had two ways of closing nothing:
//
//    1. `guard autopilotIsRunning, let runner = autopilotRunner else { return }`
//       returned silently whenever autopilot had already stopped under a
//       takeover that was still on screen. A completely dead button.
//    2. Mid-drive it aborted the STEP and left the window standing. That is not
//       the narrow "a command is running" window it sounds like:
//       `autopilotIsDriving` is true for the WHOLE drive loop, and a manual gate
//       (Install Rust, Install CMake — the exact steps in the report) parks
//       inside that loop. So at the moment a reader most wants out, the close
//       button closed nothing, twice in a row if they tried twice.
//
//  Closing is now unconditional, so these two tests pin the states that used to
//  swallow the click.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct Test6EscapeHatchTests {

    /// Failure 1, the dead button. This is the state the old guard returned
    /// from: a takeover still on screen with autopilot already stopped beneath
    /// it. The click has to fold the window away regardless — `stopAutopilot`
    /// is what calls `onAutopilotDidStop`, so returning early left the reader
    /// with a window and no way out of it.
    @Test("the red light closes even when autopilot is not running")
    func theRedLightClosesWhenAutopilotIsNotRunning() async throws {
        let controller = GuideSessionController(
            guideService: try GuideSessionTests.guideServiceAnsweredByTheStub()
        )
        await controller.openGuide(
            slug: "lunara", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android", stepIndexFromDeepLink: nil
        )
        #expect(controller.autopilotIsRunning == false)

        var theTakeoverWasFoldedAway = false
        controller.onAutopilotDidStop = { theTakeoverWasFoldedAway = true }

        controller.abortOrCloseAutopilotFromTheEscapeHatch()

        // The whole bug: this was false, because the guard returned first.
        #expect(theTakeoverWasFoldedAway, "the red light has to close the takeover even with autopilot stopped")
    }

    /// Failure 2's other half — a running autopilot must end, not merely hand
    /// the step over. The mid-DRIVE case cannot be observed from here
    /// (`autopilotIsDriving` is private and only ever true inside the drive
    /// loop's own `defer` scope), so this test covers the running-but-idle
    /// state and the mid-drive case is covered by construction instead: the
    /// method no longer branches on `autopilotIsDriving` at all. Stated rather
    /// than implied, because a test that quietly covers less than its name
    /// suggests is how this button passed review while being dead.
    ///
    /// Measured honestly: this one PASSES at the pre-fix commit too, because
    /// running-but-idle already took the old `else` branch into `stopAutopilot`.
    /// It is a regression guard, not a reproduction. The test above is the one
    /// that fails without the fix.
    @Test("the red light ends a running autopilot and folds the window away")
    func theRedLightEndsARunningAutopilot() async throws {
        let spy = GuideAutopilotConsentTests.SpyingRunnerFactory()
        let controller = GuideSessionController(
            guideService: try GuideSessionTests.guideServiceAnsweredByTheStub(),
            makeAutopilotRunner: spy.make
        )
        await controller.openGuide(
            slug: "lunara", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android", stepIndexFromDeepLink: nil
        )

        // Autopilot needs the one-time grant; inject it over an isolated suite
        // so the reader's real preference is never read or written.
        controller.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(UserDefaults(suiteName: "iris.escapehatch.tests.\(UUID().uuidString)"))
        )
        controller.confirmAutonomousControl = { true }
        controller.startAutopilot()
        #expect(controller.autopilotIsRunning == true)

        var theTakeoverWasFoldedAway = false
        controller.onAutopilotDidStop = { theTakeoverWasFoldedAway = true }

        controller.abortOrCloseAutopilotFromTheEscapeHatch()

        #expect(controller.autopilotIsRunning == false)
        #expect(theTakeoverWasFoldedAway)
        // Closing costs the reader their automation, never their place.
        #expect(controller.loadState == .guideIsOpen)
    }
}
