//
//  LunaraGuideRunnerCrossContaminationReproTests.swift
//  leanring-buddyTests
//
//  The live-run report, verbatim: running the real Lunara guide, the panel
//  correctly showed steps 1-3 with Lunara-appropriate output, then step "5 of
//  15" was captioned "COPY HICKEYFIELD TO THIS MAC" — a different app's clone
//  step — and the run froze solid. A stray macOS Keychain dialog for
//  Hickeyfield was already open on screen before this session began, which
//  points at the real cause: Iris is one shared menu-bar process, and a
//  PREVIOUS guide's autopilot (Hickeyfield, still stuck on that dialog) was
//  still running when THIS session opened a completely different guide
//  (Lunara). `GuideSessionController.openGuide` reset the step card's own
//  state (`guideBeingFollowed`, `selectedBranch`, `currentStepIndex`) for the
//  new guide, but never stopped the OLD guide's still-running
//  `autopilotRunner` — so the old autopilot kept driving its shell, and its
//  terminal, in the background while the card in front of the reader named a
//  different app.
//
//  This pins the fix: opening ANY new guide must tear down a previous guide's
//  still-running autopilot session first, exactly like closing the guide
//  already did.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct LunaraGuideRunnerCrossContaminationReproTests {

    @Test("opening a new guide stops a previous guide's still-running autopilot")
    func openingANewGuideTearsDownAPreviousGuidesRunningAutopilot() async throws {
        let spy = GuideAutopilotConsentTests.SpyingRunnerFactory()
        let controller = GuideSessionController(
            guideService: try GuideSessionTests.guideServiceAnsweredByTheStub(),
            makeAutopilotRunner: spy.make
        )

        // Open the first guide and let the reader hand Iris the wheel — the
        // real path: "Let Iris install it" -> the OS "Open Iris?" handoff ->
        // autopilot starts running the guide's own commands.
        await controller.openGuide(
            slug: "cue", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android", stepIndexFromDeepLink: nil
        )
        controller.autonomyGrant = AutopilotAutonomyGrant(
            userDefaults: try #require(UserDefaults(suiteName: "iris.crosscontamination.tests.\(UUID().uuidString)"))
        )
        controller.confirmAutonomousControl = { true }
        controller.startAutopilot()

        #expect(controller.autopilotIsRunning == true)
        #expect(controller.guideBeingFollowed?.appSlug == "cue")
        let theFirstGuidesRunner = try #require(controller.autopilotRunner)

        var timesTheOldTakeoverWasFoldedAway = 0
        controller.onAutopilotDidStop = { timesTheOldTakeoverWasFoldedAway += 1 }

        // A second, completely different guide opens on the SAME controller —
        // the shape of a second `iris://guide/…` link (or a second browser
        // tab) arriving while the first guide's autopilot is still mid-install.
        await controller.openGuide(
            slug: "hickeyfield", requestedVersion: 2,
            branchKeyFromDeepLink: nil, stepIndexFromDeepLink: nil
        )

        // The step card now genuinely belongs to the new guide...
        #expect(controller.guideBeingFollowed?.appSlug == "hickeyfield")
        #expect(controller.currentStepIndex == 0)

        // ...and the OLD guide's autopilot must not still be alive underneath
        // it. Before the fix, none of these held: `autopilotIsRunning` stayed
        // true and `autopilotRunner` still pointed at the Cue runner, which is
        // exactly how a reader could be looking at one guide's step card while
        // a completely different guide's install kept running, unseen, behind
        // it.
        #expect(controller.autopilotIsRunning == false)
        #expect(controller.autopilotRunner !== theFirstGuidesRunner)
        #expect(timesTheOldTakeoverWasFoldedAway == 1, "the old guide's takeover must fold away, not linger behind the new card")
    }
}
