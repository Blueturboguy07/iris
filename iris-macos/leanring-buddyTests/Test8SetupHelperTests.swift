//
//  Test8SetupHelperTests.swift
//  leanring-buddyTests
//
//  The pure logic behind the first-run setup helper: the walkthrough's
//  navigation, the "show it exactly once, and only when ready" gate, the seen
//  flag's persistence, and — the part that is the whole point of the feature —
//  that the three steps actually spell out the things a new reader cannot guess.
//
//  None of this needs a screen. The card that draws it is not exercised here;
//  what is exercised is everything that decides WHAT it draws and WHEN.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

struct Test8SetupHelperTests {

    // MARK: - Navigation

    @Test func theWalkthroughStartsAtTheFirstOfThreeSteps() {
        let walkthrough = IrisSetupHelperWalkthrough()
        #expect(IrisSetupHelperWalkthrough.steps.count == 3)
        #expect(walkthrough.currentStepIndex == 0)
        #expect(walkthrough.isOnFirstStep)
        #expect(!walkthrough.isOnLastStep)
        #expect(walkthrough.primaryActionLabel == "Next")
        #expect(walkthrough.progressLabel == "1 of 3")
    }

    @Test func advancingWalksToTheLastStepAndThenStops() {
        var walkthrough = IrisSetupHelperWalkthrough()
        walkthrough.advanceToTheNextStep()
        #expect(walkthrough.currentStepIndex == 1)
        walkthrough.advanceToTheNextStep()
        #expect(walkthrough.currentStepIndex == 2)
        #expect(walkthrough.isOnLastStep)
        #expect(walkthrough.primaryActionLabel == "Got it")
        #expect(walkthrough.progressLabel == "3 of 3")

        // Past the last step goes nowhere — the button becomes the dismissal,
        // and the index must never run off the end and crash the panel.
        walkthrough.advanceToTheNextStep()
        #expect(walkthrough.currentStepIndex == 2)
    }

    @Test func goingBackStopsAtTheFirstStep() {
        var walkthrough = IrisSetupHelperWalkthrough()
        walkthrough.advanceToTheNextStep()
        walkthrough.advanceToTheNextStep()
        walkthrough.goBackToThePreviousStep()
        #expect(walkthrough.currentStepIndex == 1)
        walkthrough.goBackToThePreviousStep()
        #expect(walkthrough.currentStepIndex == 0)
        // And no further.
        walkthrough.goBackToThePreviousStep()
        #expect(walkthrough.currentStepIndex == 0)
    }

    @Test func restartReturnsToTheFirstStep() {
        var walkthrough = IrisSetupHelperWalkthrough()
        walkthrough.advanceToTheNextStep()
        walkthrough.advanceToTheNextStep()
        walkthrough.restartFromTheFirstStep()
        #expect(walkthrough.currentStepIndex == 0)
        #expect(walkthrough.currentStep == IrisSetupHelperWalkthrough.steps[0])
    }

    // MARK: - Content

    @Test func theThreeStepsSpellOutTheThingsANewReaderCannotGuess() {
        let steps = IrisSetupHelperWalkthrough.steps

        // 1. The summon shortcut, named exactly.
        #expect(steps[0].glyph == .summonShortcut)
        #expect(steps[0].body.contains("Control + Option"))

        // 2. The eye is where you ask and edit.
        #expect(steps[1].glyph == .theEye)
        #expect(steps[1].body.lowercased().contains("eye"))

        // 3. This panel is where the settings live, reached by the gear.
        #expect(steps[2].glyph == .theSettingsGear)
        let lastBody = steps[2].body.lowercased()
        #expect(lastBody.contains("settings"))
        #expect(lastBody.contains("gear"))

        // Every step earns its place — no empty titles or bodies.
        for step in steps {
            #expect(!step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!step.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test func theThreeGlyphsAreDistinct() {
        let glyphs = IrisSetupHelperWalkthrough.steps.map(\.glyph)
        #expect(Set(glyphs).count == glyphs.count)
    }

    // MARK: - The show-once gate

    @Test func theHelperAutoPresentsOnlyWhenUnseenAndReady() {
        // Unseen and ready: yes. Every other combination: no.
        #expect(FirstRunSetupHelper.shouldAutomaticallyPresent(
            theReaderHasSeenItBefore: false,
            thePanelIsReadyForEverydayUse: true
        ))
        #expect(!FirstRunSetupHelper.shouldAutomaticallyPresent(
            theReaderHasSeenItBefore: true,
            thePanelIsReadyForEverydayUse: true
        ))
        // Mid-setup, the permissions UI owns the panel — never drop a
        // walkthrough on top of it, even for a reader who has never seen it.
        #expect(!FirstRunSetupHelper.shouldAutomaticallyPresent(
            theReaderHasSeenItBefore: false,
            thePanelIsReadyForEverydayUse: false
        ))
        #expect(!FirstRunSetupHelper.shouldAutomaticallyPresent(
            theReaderHasSeenItBefore: true,
            thePanelIsReadyForEverydayUse: false
        ))
    }

    // MARK: - Seen persistence

    @Test func theSeenStoreStartsUnseenAndRemembersOnceMarked() {
        // A throwaway defaults suite so the real one is never touched.
        let suiteName = "Test8SetupHelper-\(UUID().uuidString)"
        let scratchDefaults = UserDefaults(suiteName: suiteName)!
        defer { scratchDefaults.removePersistentDomain(forName: suiteName) }

        let seenStore = UserDefaultsSetupHelperSeenStore(userDefaults: scratchDefaults)
        #expect(seenStore.theReaderHasSeenTheSetupHelper == false)

        seenStore.rememberThatTheReaderHasSeenTheSetupHelper()
        #expect(seenStore.theReaderHasSeenTheSetupHelper == true)

        // A fresh store over the same defaults still sees it — the flag lives on
        // disk, not in the struct, so it survives the panel being rebuilt.
        let secondStore = UserDefaultsSetupHelperSeenStore(userDefaults: scratchDefaults)
        #expect(secondStore.theReaderHasSeenTheSetupHelper == true)
    }

    @Test func theSeenKeyIsDistinctFromTheOnboardingFlag() {
        // Conflating the two would make granting permissions silently suppress
        // the how-to, or vice versa — they gate different experiences.
        #expect(UserDefaultsSetupHelperSeenStore.seenDefaultsKey != "hasCompletedOnboarding")
    }
}
