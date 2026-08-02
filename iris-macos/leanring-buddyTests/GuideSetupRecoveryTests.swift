//
//  GuideSetupRecoveryTests.swift
//  leanring-buddyTests
//
//  Covers the setup recovery detour: what `GuideSessionController` does when the
//  branch a reader opened needs Git or Node and their computer does not have it.
//  The Tauri panel's `state.setupTool` flow (`iris-desktop/ui/app.js` —
//  `handlePrimaryAction`, `verifyCurrentTools`) remains the behavioral spec.
//
//  The guide API is answered by `StubbedGuideURLProtocol` — the same stub
//  `GuideSessionTests` uses — and the tool check is answered by
//  `RecordedToolVersionChecker`, so nothing here touches the network or spawns a
//  process. A test that shelled out for real would pass or fail depending on
//  whether the machine running it happens to have Node.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

/// Answers "is this tool installed?" from a table a test controls, and remembers
/// what it was asked. The record is what proves the branch with no setup steps
/// never runs a check at all, rather than running one and ignoring it.
actor RecordedToolVersionChecker {
    private var toolIsInstalledByName: [String: Bool]
    private(set) var toolNamesThatWereChecked: [String] = []

    init(toolIsInstalledByName: [String: Bool]) {
        self.toolIsInstalledByName = toolIsInstalledByName
    }

    /// The reader going away and installing the thing.
    func recordThatTheReaderInstalled(_ toolName: String) {
        toolIsInstalledByName[toolName] = true
    }

    func checkToolVersion(_ toolName: String) -> ToolVersion {
        toolNamesThatWereChecked.append(toolName)
        let toolIsInstalled = toolIsInstalledByName[toolName] ?? false
        return ToolVersion(
            tool: toolName,
            available: toolIsInstalled,
            version: toolIsInstalled ? "\(toolName) version 1.2.3" : ""
        )
    }
}

@MainActor
struct GuideSetupRecoveryTests {

    // MARK: - Entering the detour

    @Test func aMissingPrerequisiteWithSetupStepsDivertsTheReaderIntoSetup() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": true, "node": false]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)

        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )

        #expect(controller.loadState == .guideIsOpen)
        #expect(controller.readerIsInSetupRecovery)

        let setupRecoveryState = try #require(controller.setupRecoveryState)
        // Only the tool that is actually missing sends the reader anywhere. Git
        // is installed, so its setup step is not part of the detour.
        #expect(setupRecoveryState.toolNamesStillMissing == ["node"])
        #expect(setupRecoveryState.setupStepsToWalk.map(\.id) == ["install-node"])
        #expect(controller.stepTheReaderIsLookingAt?.id == "install-node")

        // Both rows stay visible, so the reader can see what was checked rather
        // than only what failed.
        #expect(setupRecoveryState.prerequisiteCheckRows.map(\.toolName) == ["git", "node"])
        #expect(setupRecoveryState.prerequisiteCheckRows[0].state == .installedWithVersion(version: "git version 1.2.3"))
        #expect(setupRecoveryState.prerequisiteCheckRows[1].state == .notInstalled)

        // The card has to name the tool and say why the guide needs it — "not
        // installed" alone leaves the reader to guess whether it matters.
        #expect(controller.headlineForTheSetupRecoveryCard.contains("Node"))
        #expect(controller.explanationForTheSetupRecoveryCard.contains("Node"))
        #expect(controller.stepCounterText == "Setup")

        // The guide itself is untouched underneath: same step, same count.
        #expect(controller.currentStepIndex == 0)
        #expect(controller.currentStep?.id == "open-shell")
        #expect(controller.numberOfStepsInTheSelectedBranch == 4)

        // The setup step keeps a guide step's affordances, including its link.
        guard case .openLinkInBrowser(let linkURLString, let buttonLabel) =
                try #require(controller.primaryActionForTheCurrentStep) else {
            Issue.record("the Node setup step should offer its download link")
            return
        }
        #expect(linkURLString == "https://nodejs.org/en/download")
        #expect(buttonLabel == "Open download")
    }

    @Test func theSameBranchWithEveryToolPresentGoesStraightIntoTheGuide() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": true, "node": true]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)

        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )

        #expect(controller.loadState == .guideIsOpen)
        #expect(controller.readerIsInSetupRecovery == false)
        #expect(controller.setupRecoveryState == nil)
        #expect(controller.currentStep?.id == "open-shell")
        #expect(controller.stepCounterText == "1 / 4")
        // The check did run — the detour was skipped because it found things,
        // not because nothing was looked at.
        #expect(await toolChecker.toolNamesThatWereChecked == ["git", "node"])
    }

    @Test func aMissingToolWithNoSetupStepsDoesNotDivertAndDoesNotDeadEnd() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": false, "node": false]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)

        await controller.openGuide(
            slug: "no-setup-steps",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )

        // A branch with no repair route has nothing to walk the reader through,
        // so holding them on a setup card would be a dead end with no exit.
        #expect(controller.loadState == .guideIsOpen)
        #expect(controller.readerIsInSetupRecovery == false)
        #expect(controller.currentStep?.id == "open-shell")
        #expect(controller.primaryActionForTheCurrentStep != nil)

        // And nothing was spawned to find that out: the branch declares no
        // prerequisites, so there is nothing to check.
        #expect(await toolChecker.toolNamesThatWereChecked.isEmpty)
    }

    // MARK: - Getting out of the detour

    @Test func aRecheckThatFindsTheToolReturnsTheReaderToTheirSavedStep() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()

        // The reader got three steps in on a day when everything was installed.
        let controllerFromTheEarlierSession = Self.controller(
            guideService: guideService,
            toolChecker: RecordedToolVersionChecker(
                toolIsInstalledByName: ["git": true, "node": true]
            )
        )
        await controllerFromTheEarlierSession.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        controllerFromTheEarlierSession.advanceToTheNextStep()
        controllerFromTheEarlierSession.advanceToTheNextStep()
        #expect(controllerFromTheEarlierSession.currentStepIndex == 2)
        await controllerFromTheEarlierSession.waitUntilProgressHasBeenPersisted()

        // Today Git is gone — a new Mac, or the command line tools were wiped.
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": false, "node": true]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)
        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.readerIsInSetupRecovery)
        #expect(controller.stepTheReaderIsLookingAt?.id == "install-git")
        // The saved place is restored before the detour, and waits there.
        #expect(controller.currentStepIndex == 2)

        // Copying the installer command is the step's action; the only setup
        // step then turns the button into the re-check, exactly as the Tauri
        // panel does once `actionReady` is set.
        let installerCommand = try #require(controller.commandBlockTextForTheCurrentStep)
        #expect(installerCommand == "xcode-select --install")
        controller.copyCommandToClipboard(installerCommand)
        guard case .runToolChecksForThisStep(let buttonLabel) =
                try #require(controller.primaryActionForTheCurrentStep) else {
            Issue.record("the last setup step should offer the re-check")
            return
        }
        #expect(buttonLabel == "Check again")

        await toolChecker.recordThatTheReaderInstalled("git")
        controller.performPrimaryAction()
        await controller.waitUntilTheSetupRecheckHasFinished()

        // The detour ends where it started, which is step three — not step one.
        #expect(controller.readerIsInSetupRecovery == false)
        #expect(controller.setupRecoveryState == nil)
        #expect(controller.currentStepIndex == 2)
        #expect(controller.currentStep?.id == "clone")
        #expect(controller.stepCounterText == "3 / 4")
    }

    @Test func aRecheckThatStillCannotFindTheToolSaysSoAndStaysInSetup() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": true, "node": false]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)

        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.readerIsInSetupRecovery)
        // Nothing has been re-checked yet, so there is nothing to report yet.
        #expect(controller.setupRecoveryState?.messageFromTheMostRecentRecheck == nil)

        controller.recheckThePrerequisitesForSetupRecovery()
        await controller.waitUntilTheSetupRecheckHasFinished()

        // Pressing a button and seeing nothing change is how a reader decides
        // the app is broken, so a failed re-check has to say what it found.
        #expect(controller.readerIsInSetupRecovery)
        let messageFromTheMostRecentRecheck = try #require(
            controller.setupRecoveryState?.messageFromTheMostRecentRecheck
        )
        #expect(messageFromTheMostRecentRecheck.contains("still cannot find Node"))
        #expect(controller.setupRecoveryState?.aRecheckIsRunning == false)
        #expect(controller.setupRecoveryState?.toolNamesStillMissing == ["node"])
        #expect(controller.stepTheReaderIsLookingAt?.id == "install-node")
        // Both checks ran: the arrival scan and the re-check.
        #expect(await toolChecker.toolNamesThatWereChecked == ["git", "node", "git", "node"])
    }

    @Test func skippingSetupReachesTheGuideAnyway() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": true, "node": false]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)

        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.readerIsInSetupRecovery)

        // Some people have the tool under a name the check cannot see. Iris
        // being wrong about that must not be the end of their install.
        controller.skipSetupRecoveryAndContinueToTheGuide()

        #expect(controller.readerIsInSetupRecovery == false)
        #expect(controller.currentStep?.id == "open-shell")
        #expect(controller.stepCounterText == "1 / 4")
        #expect(controller.primaryActionForTheCurrentStep != nil)
        // Skipping does not move the reader, so nothing about their place
        // changed either.
        #expect(controller.currentStepIndex == 0)
    }

    // MARK: - The detour writes nothing about the guide

    @Test func walkingTheSetupStepsLeavesSavedGuideProgressAlone() async throws {
        let guideService = try GuideSessionTests.guideServiceAnsweredByTheStub()

        let controllerFromTheEarlierSession = Self.controller(
            guideService: guideService,
            toolChecker: RecordedToolVersionChecker(
                toolIsInstalledByName: ["git": true, "node": true]
            )
        )
        await controllerFromTheEarlierSession.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        controllerFromTheEarlierSession.advanceToTheNextStep()
        controllerFromTheEarlierSession.advanceToTheNextStep()
        await controllerFromTheEarlierSession.waitUntilProgressHasBeenPersisted()

        // Both prerequisites are gone this time, so the detour has two steps to
        // walk and every navigation control is in play.
        let toolChecker = RecordedToolVersionChecker(
            toolIsInstalledByName: ["git": false, "node": false]
        )
        let controller = Self.controller(guideService: guideService, toolChecker: toolChecker)
        await controller.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.readerIsInSetupRecovery)
        #expect(controller.setupRecoveryState?.setupStepsToWalk.map(\.id) == ["install-git", "install-node"])
        #expect(controller.canReturnToThePreviousStep == false)

        controller.advanceToTheNextSetupStep()
        #expect(controller.stepTheReaderIsLookingAt?.id == "install-node")
        #expect(controller.canReturnToThePreviousStep)
        controller.returnToThePreviousSetupStep()
        #expect(controller.stepTheReaderIsLookingAt?.id == "install-git")

        // The guide's own navigation refuses to run during the detour, so a
        // stray press can never move the reader's place.
        controller.advanceToTheNextStep()
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 2)

        // Back inside the detour behaves as the detour's Back, not the guide's.
        controller.returnToThePreviousStep()
        #expect(controller.currentStepIndex == 2)

        // The stored progress is the thing that would strand somebody at step
        // one after they went away and installed Node, so it is checked at the
        // storage layer rather than in memory.
        let savedProgress = await guideService.loadProgress(
            slug: "setup-recovery",
            version: 1,
            branchKey: "macos:desktop"
        )
        #expect(savedProgress.stepIndex == 2)
        #expect(savedProgress.isCompleted == false)

        // And a fresh session with the tools back finds the same place.
        let controllerAfterInstallingEverything = Self.controller(
            guideService: guideService,
            toolChecker: RecordedToolVersionChecker(
                toolIsInstalledByName: ["git": true, "node": true]
            )
        )
        await controllerAfterInstallingEverything.openGuide(
            slug: "setup-recovery",
            requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            stepIndexFromDeepLink: nil
        )
        #expect(controllerAfterInstallingEverything.readerIsInSetupRecovery == false)
        #expect(controllerAfterInstallingEverything.currentStepIndex == 2)
    }

    // MARK: - Test fixtures

    private static func controller(
        guideService: GuideService,
        toolChecker: RecordedToolVersionChecker
    ) -> GuideSessionController {
        GuideSessionController(
            guideService: guideService,
            platformThisAppRunsOn: .macos,
            checkToolVersion: { toolName in
                await toolChecker.checkToolVersion(toolName)
            }
        )
    }
}
