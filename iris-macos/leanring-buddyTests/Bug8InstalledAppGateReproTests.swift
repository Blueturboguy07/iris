//
//  Bug8InstalledAppGateReproTests.swift
//  leanring-buddyTests
//
//  Bug 8 from the cofounder's Test 9 report (Iris 0.9.6 build 22, kneecap on
//  his Mac): "Install Xcode" was put in front of a reader who already had
//  Xcode 26.6 installed, and the chat assistant that was then asked about it
//  spent thirteen turns guessing because nothing had ever told it whether an
//  iOS Simulator runtime existed on the machine.
//
//  == HALF ONE: the gate ==
//
//  The install was already running unattended when it hit the step. From
//  `iris.log`, verbatim, with the first two timestamps 221ms apart:
//
//      07:04:09.639Z  drive: build-editor result=succeeded
//      07:04:09.640Z  drive: step[8] id=install-xcode kind=open exec=false
//      07:04:09.861Z  drive: step install-xcode -> MANUAL branch, waiting at gate (return)
//      07:04:09.861Z  takeover: PARKED + set readerMustManuallyContinue=true,
//                     showsTerminalFace=true, title=Install Xcode
//      07:04:10.341Z  pointing/model: asked for step=Install Xcode
//      ...
//      07:04:35.791Z  gate: reader finished step 8 - advancing and resuming autopilot
//
//  Twenty-six seconds of a reader being asked to install software they already
//  had, ending in them telling Iris so by hand. Step 8 of the published kneecap
//  iOS branch is `kind: open`, `href` to the App Store, and its watch block
//  declares exactly one expectation: `foregroundApp com.apple.dt.Xcode`.
//
//  Why it parks: `driveAutopilotFromTheCurrentStep`'s manual-step branch has
//  ONE way to skip a gate, `everyToolThisStepWatchesForIsAlreadyPresent`, and
//  that function returns false for any expectation that is not `.toolVersion`
//  (`guard case .toolVersion(let toolName) = expectation else { return false }`)
//  - deliberately, per its own doc comment. A `.foregroundApp` expectation
//  therefore can never satisfy it, `stepIsFinishedOnceIrisHasOpenedIt` is false
//  because the watch block is non-empty, and the loop falls through to
//  `handTheCurrentStepBackToTheReader()`. Nothing anywhere in that path asks
//  whether the app the step is gating on is already on the disk - even though
//  `GuideSessionController.installedDesktopAppCheck`, the inventory-backed
//  "is this bundle installed?" closure CompanionManager already injects, is
//  sitting right there and is used by the resume reality-check.
//
//  The first two tests are the pair the dossier asks for: installed -> the
//  install must carry on by itself; not installed -> the gate must stay exactly
//  as it is today. Both drive the REAL `GuideSessionController` and the REAL
//  `GuideAutopilotRunner` against the published kneecap iOS branch, served over
//  `URLProtocol` the way `GET /api/iris/guides/kneecap` serves it, resumed at
//  step 6 so the loop reaches step[8] by running the same two commands the log
//  shows it running (install-deps, build-editor). The third test does the whole
//  thing again through a REAL pty login shell, a REAL git checkout and a REAL
//  bun workspace in a temp folder, so the gate is reached off the back of real
//  work with real exit codes rather than a scripted shell.
//
//  Two deliberate deviations from the wire, both about not touching the machine
//  the suite runs on:
//
//    * the `install-xcode` href is `https://apps-apple-com.invalid/...` instead
//      of `https://apps.apple.com/app/xcode/id497799835`. Reaching the gate runs
//      `autoOpenIfTheStepPointsSomewhere`, and the real href is on
//      `ExternalLinkPolicy`'s allowlist, so a faithful copy would fling the Mac
//      App Store open on top of whoever is running the tests. `.invalid` is the
//      reserved never-resolving TLD; the host is not on the allowlist, so
//      `openLinkInBrowser` refuses it and returns false. The branch under test
//      is untouched by that - the open is best-effort and its result is
//      discarded either way - which the first test pins by asserting the real
//      App Store href IS allowed.
//    * the pty test's guide names the temp checkout as each step's
//      `workingDirectory` and runs `bun run sync` where the wire says
//      `bunx cap sync ios`, because the published step names `~/kneecap` and
//      Capacitor's CLI is a network fetch. Everything the gate depends on -
//      step kind, href, watch block, the order - is the wire's.
//
//  == HALF TWO: the simulator runtime ==
//
//  After the gate the reader asked chat about deploying, and the transcript
//  records thirteen turns of Iris pointing at a Git-branch dropdown and a
//  simulator choice that did not exist, reversing itself repeatedly, until at
//  07:18:10Z it finally noticed - from a screenshot, not from a fact - that
//  "Downloading iOS 26.5... 632.9 MB of 8.52 GB" was still in flight. `simctl`
//  on that Mac listed no runtime at all.
//
//  `AssistantMachineFacts.summary` is what chat is told about the machine, and
//  it reports `xcodebuild` - so the model is told Xcode is installed and is
//  told nothing whatsoever about whether anything can be run on it. There is no
//  `simctl` reference anywhere in the app. The last test states that asymmetry
//  against this Mac's REAL `xcrun simctl list runtimes -j` output.
//

import AppKit
import Foundation
import Testing
@testable import Iris

private let ptyTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

@MainActor
@Suite(.serialized)
struct Bug8InstalledAppGateReproTests {

    // MARK: - Fakes standing in for the parts of the Mac a test may not touch

    /// A shell that records what it was asked to run and always succeeds. The
    /// commands themselves do not matter here - what matters is whether the
    /// command AFTER the gate is ever reached.
    final class RecordingShellSession: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/reader/kneecap"
        var resolvedSearchPath: String? = "/usr/bin:/bin"
        private(set) var commandsRun: [String] = []

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async {}
        func tailForTheModel() -> String { "" }

        func run(
            _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
    }

    /// Never proposes a repair, so nothing can be rescued by a model call and
    /// the only thing that can move this install on is the gate decision.
    final class NeverProposesAFix: GuideAutopilotFixProposing {
        func proposeFix(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? { nil }
    }

    /// What `onAutopilotWaitingForReaderAtGate` was handed - the same two values
    /// `CompanionManager` forwards to the takeover's parked card, and the ones
    /// the log line `takeover: PARKED ... title=Install Xcode` came from.
    final class ManualGateRecorder {
        private(set) var titlesOfEveryGateTheReaderWasParkedAt: [String] = []
        private(set) var instructionsShownAtThoseGates: [String] = []
        func record(title: String, instruction: String) {
            titlesOfEveryGateTheReaderWasParkedAt.append(title)
            instructionsShownAtThoseGates.append(instruction)
        }
    }

    /// The fake workspace lookup the dossier's test calls for: stands in for
    /// `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` behind the
    /// seam the app already has for it (`installedDesktopAppCheck`, which
    /// CompanionManager wires to `AppInventoryService`). It records every
    /// question asked of it, so a test can say not just "Iris got the answer
    /// wrong" but "Iris never asked".
    final class FakeInstalledApplicationLookup {
        private let bundleIdentifiersThatAreInstalled: Set<String>
        private(set) var bundleIdentifiersItWasAskedAbout: [String] = []

        init(installed bundleIdentifiersThatAreInstalled: Set<String>) {
            self.bundleIdentifiersThatAreInstalled = bundleIdentifiersThatAreInstalled
        }

        func isInstalled(_ bundleIdentifier: String) -> Bool {
            bundleIdentifiersItWasAskedAbout.append(bundleIdentifier)
            return bundleIdentifiersThatAreInstalled.contains(bundleIdentifier)
        }
    }

    // MARK: - Watch-loop seams, so no test ever captures this Mac's screen

    /// Hands back no frames at all. The step under test declares a watch block,
    /// so the real loop would otherwise start capturing the screen of whoever is
    /// running the suite.
    final class NoFramesEverCaptured: WatchLoopFrameSource {
        func captureFingerprintOfTheCurrentScreen() async -> ScreenFrameFingerprint? { nil }
        func captureOneFrameForAVisualModelCheck() async -> Data? { nil }
    }

    /// The reader as the log has them at 07:04:09: the guide has just opened the
    /// App Store link, so their browser is frontmost - Xcode is installed but
    /// has not been brought to the front, which is exactly why the step's
    /// `foregroundApp` expectation cannot settle it and why the drive loop, not
    /// the watch loop, is the thing being measured here.
    final class TheReaderIsLookingAtTheirBrowser: WatchLoopLocalSignalSource {
        func frontmostApplicationBundleIdentifier() -> String? { "com.apple.Safari" }
        func frontmostApplicationName() -> String? { "Safari" }
        func frontmostWindowTitle() -> String? { "Xcode on the Mac App Store" }
        func focusedWindowRectangleAndDisplaySizeInPoints() -> (window: CGRect, display: CGSize)? {
            nil
        }
        func hostOfTheURLInTheFrontmostWindow() -> String? { "apps.apple.com" }
        func isToolInstalled(named toolName: String) async -> Bool { true }
        func gitWorkingTreeHasACommit(atRepositoryPath repositoryPath: String) async -> Bool { true }
        func isAccessibilityElementPresent(matchingRoleLabel roleLabel: String) -> Bool { false }
        func isSecureEventInputActive() -> Bool { false }
    }

    /// Never reached - no step driven here declares a `visual` expectation while
    /// the loop is live - but injected so no test can ever make a model call.
    final class NoVisualCheckIsEverMade: WatchLoopVisualEvaluator {
        func evaluateWhetherTheStepLooksDone(
            screenshotJPEGData: Data,
            visualPrompt: String,
            stepTitle: String,
            hintsTheStepAuthorWrote: [String],
            context: WatchScreenContext
        ) async -> WatchVerdict? { nil }
    }

    // MARK: - The guide, as publik serves it

    /// `GET /api/iris/guides/kneecap` for the branch the reader was on
    /// (`macos:ios`, "Mac + iPhone"), with the single href change explained in
    /// the file header. Step 8 is the one the report is about.
    final class KneecapIosGuideURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = Data(Self.kneecapGuideJSON.utf8)
            guard let response = HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// A raw string on purpose: the guide's own commands carry `\n`
        /// sequences that JSON needs to survive as two characters.
        static let kneecapGuideJSON = #"""
        {
          "appSlug": "kneecap",
          "appName": "kneecap",
          "version": 2,
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "kneecap",
          "sourceCommit": "fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
          "outputType": "mobile_app",
          "estimatedMinutes": 40,
          "readmeSectionIds": ["build"],
          "reviewNote": "kneecap installs unsigned onto the reader's own phone.",
          "branches": [
            {
              "platform": "macos",
              "target": "ios",
              "unsupported": null,
              "label": "Mac + iPhone",
              "shell": "terminal",
              "setupSteps": [
                {
                  "id": "install-git",
                  "kind": "terminal",
                  "tool": "git",
                  "title": "Install Git",
                  "body": "Apple opens a small installer.",
                  "command": "xcode-select --install",
                  "verifierLabel": "Git responds with a version number"
                },
                {
                  "id": "install-node",
                  "kind": "open",
                  "tool": "node",
                  "title": "Install Node LTS",
                  "body": "Choose the macOS Installer (.pkg).",
                  "href": "https://nodejs.org/en/download",
                  "actionLabel": "Open download",
                  "verifierLabel": "Node responds with a version number"
                }
              ],
              "steps": [
                {
                  "id": "open-shell",
                  "kind": "terminal",
                  "title": "Open Terminal",
                  "body": "Keep it open beside Iris.",
                  "verifierLabel": "Terminal is open"
                },
                {
                  "id": "check-tools",
                  "kind": "check",
                  "title": "Check Git and Node",
                  "body": "Git and the current Node LTS are required.",
                  "command": "git --version\nnode --version",
                  "verifierLabel": "Git and Node respond with version numbers",
                  "watch": {
                    "expect": [
                      {"type": "toolVersion", "tool": "git"},
                      {"type": "toolVersion", "tool": "node"}
                    ]
                  }
                },
                {
                  "id": "install-bun",
                  "kind": "terminal",
                  "title": "Install Bun",
                  "body": "kneecap's workspace is built with Bun.",
                  "command": "npm install -g bun",
                  "verifierLabel": "Bun responds with a version number",
                  "watch": {
                    "expect": [
                      {"type": "toolVersion", "tool": "bun"},
                      {"type": "visual", "prompt": "Has `npm install -g bun` finished?"}
                    ],
                    "hints": [
                      "If npm refused for lack of permission, reinstall Node from nodejs.org."
                    ]
                  }
                },
                {
                  "id": "clone",
                  "workingDirectory": "~",
                  "kind": "terminal",
                  "title": "Copy kneecap to this Mac",
                  "body": "",
                  "command": "cd ~\nif [ ! -d kneecap/.git ]; then\ngit clone https://github.com/Blueturboguy07/kneecap.git\nfi",
                  "verifierLabel": "A kneecap folder appears",
                  "watch": {"expect": [{"type": "toolVersion", "tool": "git"}]}
                },
                {
                  "id": "enter-folder",
                  "workingDirectory": "~",
                  "kind": "terminal",
                  "title": "Open the kneecap folder",
                  "body": "",
                  "command": "cd kneecap",
                  "verifierLabel": "Your terminal prompt is inside the kneecap folder"
                },
                {
                  "id": "pin-source",
                  "workingDirectory": "~/kneecap",
                  "kind": "terminal",
                  "title": "Use the reviewed version",
                  "body": "",
                  "command": "git checkout fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
                  "verifierLabel": "Git reports the reviewed commit"
                },
                {
                  "id": "install-deps",
                  "workingDirectory": "~/kneecap",
                  "kind": "terminal",
                  "title": "Install the workspace",
                  "body": "A few minutes the first time.",
                  "command": "bun install",
                  "verifierLabel": "The command finishes without an error"
                },
                {
                  "id": "build-editor",
                  "workingDirectory": "~/kneecap",
                  "kind": "terminal",
                  "title": "Build the editor",
                  "body": "Bundles the editor into apps/mobile/www.",
                  "command": "cd apps/mobile\nbun run build",
                  "verifierLabel": "Vite reports the build finished",
                  "watch": {
                    "expect": [
                      {"type": "visual", "prompt": "Does the terminal show a finished Vite build?"}
                    ],
                    "hints": ["If it cannot find vite, the workspace install did not finish."]
                  }
                },
                {
                  "id": "install-xcode",
                  "kind": "open",
                  "title": "Install Xcode",
                  "body": "Free, and large. Open it once and accept the licence.",
                  "href": "https://apps-apple-com.invalid/app/xcode/id497799835",
                  "actionLabel": "Open App Store",
                  "verifierLabel": "Xcode opens to its welcome screen",
                  "watch": {
                    "expect": [{"type": "foregroundApp", "bundleId": "com.apple.dt.Xcode"}]
                  }
                },
                {
                  "id": "sync-ios",
                  "workingDirectory": "~/kneecap/apps/mobile",
                  "kind": "terminal",
                  "title": "Copy the editor into the iPhone app",
                  "body": "",
                  "command": "bunx cap sync ios",
                  "verifierLabel": "Capacitor reports the sync finished"
                },
                {
                  "id": "open-project",
                  "workingDirectory": "~/kneecap/apps/mobile",
                  "kind": "terminal",
                  "title": "Open the iPhone project",
                  "body": "Capacitor 8 uses Swift Package Manager.",
                  "command": "bunx cap open ios",
                  "verifierLabel": "Xcode opens the App project",
                  "watch": {
                    "expect": [{"type": "foregroundApp", "bundleId": "com.apple.dt.Xcode"}]
                  }
                },
                {
                  "id": "signing",
                  "kind": "permission",
                  "title": "Sign it with your Apple ID",
                  "body": "Pick App, then Signing & Capabilities, then add your Apple ID.",
                  "verifierLabel": "The signing panel shows your name and no red error"
                },
                {
                  "id": "run",
                  "kind": "open",
                  "title": "Plug in your iPhone and press play",
                  "body": "Pick your iPhone in the device menu, then the play button.",
                  "actionLabel": "Build started",
                  "verifierLabel": "kneecap appears on your home screen"
                },
                {
                  "id": "trust",
                  "kind": "permission",
                  "title": "Trust the app on your iPhone",
                  "body": "Settings, General, VPN & Device Management, your Apple ID, Trust.",
                  "verifierLabel": "kneecap opens instead of showing Untrusted Developer"
                },
                {
                  "id": "verify",
                  "kind": "verify",
                  "title": "Check that it works",
                  "body": "Open kneecap, start a project, add a clip, then Export.",
                  "verifierLabel": "The exported video saves back to your camera roll"
                }
              ]
            }
          ]
        }
        """#
    }

    /// The same branch reduced to the gate's immediate neighbourhood, with every
    /// command rewritten to something a real login shell can finish offline in a
    /// temp checkout. Used only by the pty test; see the file header for exactly
    /// what was substituted and why.
    final class OfflineNeighbourhoodGuideURLProtocol: URLProtocol {
        /// Set once by the pty test before the session is built, read by the
        /// loading callback. The suite is `.serialized`, so there is one writer.
        nonisolated(unsafe) static var checkoutFolderTheStepsRunIn = ""

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = Data(Self.guideJSON(checkout: Self.checkoutFolderTheStepsRunIn).utf8)
            guard let response = HTTPURLResponse(
                url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func guideJSON(checkout: String) -> String {
            """
            {
              "appSlug": "kneecap",
              "appName": "kneecap",
              "version": 2,
              "status": "pilot",
              "sourceOwner": "Blueturboguy07",
              "sourceRepo": "kneecap",
              "sourceCommit": null,
              "outputType": "mobile_app",
              "estimatedMinutes": 40,
              "readmeSectionIds": [],
              "branches": [
                {
                  "platform": "macos",
                  "target": "ios",
                  "unsupported": null,
                  "label": "Mac + iPhone",
                  "shell": "terminal",
                  "setupSteps": [],
                  "steps": [
                    {
                      "id": "install-deps",
                      "workingDirectory": "\(checkout)",
                      "kind": "terminal",
                      "title": "Install the workspace",
                      "body": "A few minutes the first time.",
                      "command": "bun install",
                      "verifierLabel": "The command finishes without an error"
                    },
                    {
                      "id": "build-editor",
                      "workingDirectory": "\(checkout)",
                      "kind": "terminal",
                      "title": "Build the editor",
                      "body": "Bundles the editor into apps/mobile/www.",
                      "command": "cd apps/mobile\\nbun run build",
                      "verifierLabel": "The build finished",
                      "watch": {
                        "expect": [
                          {"type": "visual", "prompt": "Does the terminal show a finished build?"}
                        ]
                      }
                    },
                    {
                      "id": "install-xcode",
                      "kind": "open",
                      "title": "Install Xcode",
                      "body": "Free, and large. Open it once and accept the licence.",
                      "href": "https://apps-apple-com.invalid/app/xcode/id497799835",
                      "actionLabel": "Open App Store",
                      "verifierLabel": "Xcode opens to its welcome screen",
                      "watch": {
                        "expect": [{"type": "foregroundApp", "bundleId": "com.apple.dt.Xcode"}]
                      }
                    },
                    {
                      "id": "sync-ios",
                      "workingDirectory": "\(checkout)/apps/mobile",
                      "kind": "terminal",
                      "title": "Copy the editor into the iPhone app",
                      "body": "",
                      "command": "bun run sync",
                      "verifierLabel": "The sync finished"
                    }
                  ]
                }
              ]
            }
            """
        }
    }

    // MARK: - Harness

    /// Everything an assertion needs to see about one driven install.
    struct DrivenInstall {
        let controller: GuideSessionController
        let shell: RecordingShellSession
        let gates: ManualGateRecorder
        let workspaceLookup: FakeInstalledApplicationLookup
    }

    /// The index the log's `step[8]` is, and the step the whole report is about.
    static let indexOfTheInstallXcodeStep = 8

    /// Where the relaunched process in the log picked the install back up.
    static let indexTheReadersLinkResumedAt = 6

    /// Opens the published kneecap iOS branch at step 6, starts autopilot, and
    /// lets it run until it either parks the reader at a gate or gets past
    /// `install-xcode` on its own.
    private static func driveTheKneecapInstallPastTheBuildStep(
        xcodeIsAlreadyInstalledOnThisMac: Bool
    ) async throws -> DrivenInstall {
        let shell = RecordingShellSession()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KneecapIosGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug8.gate.\(UUID().uuidString)")
        )
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
        let controller = GuideSessionController(
            guideService: guideService,
            watchLoop: WatchLoop(
                frameSource: NoFramesEverCaptured(),
                localSignalSource: TheReaderIsLookingAtTheirBrowser(),
                visualEvaluator: NoVisualCheckIsEverMade(),
                preferencesStore: defaults,
                drivesItsOwnTickTimer: false
            ),
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: RecordingShellSession(),
                    fixProposer: NeverProposesAFix(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // The one-time autonomy grant lives in UserDefaults on the real machine;
        // this run must not depend on whether some earlier session left it on.
        controller.confirmAutonomousControl = { true }

        let workspaceLookup = FakeInstalledApplicationLookup(
            installed: xcodeIsAlreadyInstalledOnThisMac ? ["com.apple.dt.Xcode"] : []
        )
        controller.installedDesktopAppCheck = { bundleIdentifier in
            workspaceLookup.isInstalled(bundleIdentifier)
        }

        let gates = ManualGateRecorder()
        controller.onAutopilotWaitingForReaderAtGate = { title, instruction in
            gates.record(title: title, instruction: instruction)
        }

        // The reader's own resume point: publik's link names the branch and the
        // step, which is how the relaunched process in the log came back at
        // install-deps rather than at step one.
        await controller.openGuide(
            slug: "kneecap",
            requestedVersion: nil,
            branchKeyFromDeepLink: "macos:ios",
            stepIndexFromDeepLink: indexTheReadersLinkResumedAt
        )
        #expect(controller.currentStepIndex == indexTheReadersLinkResumedAt,
                "the guide must resume where the log resumed, or nothing below is about step 8")

        controller.startAutopilot()

        // Wait for whichever comes first: the gate the report is about, or the
        // command that only runs if the install got past it by itself.
        _ = await pump(within: 15) {
            gates.titlesOfEveryGateTheReaderWasParkedAt.isEmpty == false
                || shell.commandsRun.contains { $0.contains("cap sync ios") }
        }
        return DrivenInstall(
            controller: controller, shell: shell, gates: gates, workspaceLookup: workspaceLookup
        )
    }

    /// Polls a main-actor condition until it holds or the deadline passes. The
    /// drive loop runs in its own Task, so its effects are observed rather than
    /// awaited.
    private static func pump(
        within seconds: Double = 6, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - The report, as a test

    /// THE REPRO. Xcode is on the disk. The install must not stop and ask the
    /// reader to go and install it.
    @Test func theInstallXcodeGateIsShownEvenThoughXcodeIsAlreadyInstalled() async throws {
        let install = try await Self.driveTheKneecapInstallPastTheBuildStep(
            xcodeIsAlreadyInstalledOnThisMac: true
        )

        // The two commands the log shows running immediately before step[8], so
        // a failure below is about the gate and not about a run that never got
        // there.
        #expect(install.shell.commandsRun.contains { $0.contains("bun install") },
                "install-deps must have run, or the gate was reached the wrong way")
        #expect(install.shell.commandsRun.contains { $0.contains("bun run build") },
                "build-editor must have run, or the gate was reached the wrong way")

        // The whole bug, in one line of the log. Only THIS gate: once the
        // install carries on it reaches `signing` and `run`, which are a reader
        // adding an Apple ID and plugging in a phone - gates by nature, and
        // nothing to do with the report.
        #expect(
            install.gates.titlesOfEveryGateTheReaderWasParkedAt
                .contains("Install Xcode") == false,
            """
            Iris parked the reader at \
            \(install.gates.titlesOfEveryGateTheReaderWasParkedAt) with \
            com.apple.dt.Xcode already installed on this Mac. That is Test 9's \
            "drive: step install-xcode -> MANUAL branch, waiting at gate (return)" \
            followed by "takeover: PARKED ... title=Install Xcode" - twenty-six \
            seconds of a reader being told to install software they already had.
            """
        )

        // And the reason it parked: nothing in the manual-step branch ever asks.
        #expect(
            install.workspaceLookup.bundleIdentifiersItWasAskedAbout
                .contains("com.apple.dt.Xcode"),
            """
            The drive loop never asked whether com.apple.dt.Xcode was installed - \
            it asked about \(install.workspaceLookup.bundleIdentifiersItWasAskedAbout). \
            `everyToolThisStepWatchesForIsAlreadyPresent` returns false for any \
            expectation that is not `.toolVersion`, and no other check exists, so \
            an `open` step watching for `foregroundApp` gates unconditionally.
            """
        )

        // Progress is a command running, not an index moving.
        #expect(
            install.shell.commandsRun.contains { $0.contains("cap sync ios") },
            """
            The install stopped at step \(install.controller.currentStepIndex) \
            instead of carrying on to sync-ios. Commands run were \
            \(install.shell.commandsRun).
            """
        )
        #expect(install.controller.currentStepIndex > Self.indexOfTheInstallXcodeStep,
                "a step whose app is already installed is Iris's, not the reader's")

        // The published step's real href IS on the allowlist - the fixture's
        // `.invalid` host is only there to keep the Mac App Store from opening
        // on top of whoever is running this suite, and changes nothing about the
        // branch above.
        #expect(ExternalLinkPolicy.isAllowedExternalURL(
            "https://apps.apple.com/app/xcode/id497799835"
        ))
    }

    /// THE CONTROL, and the half that must not change: with the app genuinely
    /// missing, the gate is exactly what it is today. A fix that skips this step
    /// unconditionally would abandon the reader who really does need Xcode.
    @Test func theInstallXcodeGateIsStillShownWhenXcodeIsNotInstalled() async throws {
        let install = try await Self.driveTheKneecapInstallPastTheBuildStep(
            xcodeIsAlreadyInstalledOnThisMac: false
        )

        #expect(install.gates.titlesOfEveryGateTheReaderWasParkedAt.last == "Install Xcode",
                "with no Xcode on the Mac the reader must still be asked to install it")
        #expect(install.controller.currentStepIndex == Self.indexOfTheInstallXcodeStep,
                "the gate is recorded against step 8, the step the log names")
        #expect(install.controller.autopilotHandedTheCurrentStepToTheReader,
                "the step is the reader's while the app is genuinely missing")
        #expect(install.shell.commandsRun.contains { $0.contains("cap sync ios") } == false,
                "nothing after the gate may run until the reader has actually installed Xcode")
    }

    // MARK: - The same gate, reached through a real login shell

    /// A real git checkout with a real bun workspace in it, built the way the
    /// reader's kneecap folder is: a repository, a root manifest with an
    /// `apps/*` workspace, and an `apps/mobile` package whose scripts stand in
    /// for the Vite build and the Capacitor sync.
    private static func buildARealCheckoutOfTheEditor() throws -> String {
        let checkoutFolder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug8-kneecap-\(UUID().uuidString)")
        let mobileFolder = (checkoutFolder as NSString)
            .appendingPathComponent("apps/mobile")
        try FileManager.default.createDirectory(
            atPath: mobileFolder, withIntermediateDirectories: true
        )
        try #"{"name":"kneecap","private":true,"workspaces":["apps/*"]}"#
            .write(
                toFile: (checkoutFolder as NSString).appendingPathComponent("package.json"),
                atomically: true, encoding: .utf8
            )
        try #"{"name":"mobile","scripts":{"build":"echo built","sync":"echo synced"}}"#
            .write(
                toFile: (mobileFolder as NSString).appendingPathComponent("package.json"),
                atomically: true, encoding: .utf8
            )
        let gitInit = Process()
        gitInit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        gitInit.arguments = ["init", "--quiet", checkoutFolder]
        gitInit.standardOutput = FileHandle.nullDevice
        gitInit.standardError = FileHandle.nullDevice
        try gitInit.run()
        gitInit.waitUntilExit()
        return checkoutFolder
    }

    /// The end-to-end shape: the real drive loop, the real runner, and a REAL
    /// pty login shell running real `bun` in a real checkout, hitting the same
    /// `open` + `foregroundApp` step. Nothing here is scripted except the
    /// workspace lookup the dossier asks to be faked.
    @Test(.enabled(if: ptyTestsAreEnabled))
    func aRealShellReachesTheSameGateWithXcodeAlreadyInstalled() async throws {
        let checkoutFolder = try Self.buildARealCheckoutOfTheEditor()
        defer { try? FileManager.default.removeItem(atPath: checkoutFolder) }
        OfflineNeighbourhoodGuideURLProtocol.checkoutFolderTheStepsRunIn = checkoutFolder

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineNeighbourhoodGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug8.pty.\(UUID().uuidString)")
        )
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
        let loginShell = GuideAutopilotShellSession(startingDirectory: checkoutFolder)
        let sideShell = GuideAutopilotShellSession(startingDirectory: checkoutFolder)
        let controller = GuideSessionController(
            guideService: guideService,
            watchLoop: WatchLoop(
                frameSource: NoFramesEverCaptured(),
                localSignalSource: TheReaderIsLookingAtTheirBrowser(),
                visualEvaluator: NoVisualCheckIsEverMade(),
                preferencesStore: defaults,
                drivesItsOwnTickTimer: false
            ),
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: loginShell,
                    longRunningSession: sideShell,
                    fixProposer: NeverProposesAFix(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.confirmAutonomousControl = { true }
        let workspaceLookup = FakeInstalledApplicationLookup(installed: ["com.apple.dt.Xcode"])
        controller.installedDesktopAppCheck = { bundleIdentifier in
            workspaceLookup.isInstalled(bundleIdentifier)
        }
        let gates = ManualGateRecorder()
        controller.onAutopilotWaitingForReaderAtGate = { title, instruction in
            gates.record(title: title, instruction: instruction)
        }

        await controller.openLatestVersionOfGuide(slug: "kneecap")
        controller.startAutopilot()

        let indexOfTheStepAfterTheGate = 3
        let settled = await Self.pump(within: 120) {
            gates.titlesOfEveryGateTheReaderWasParkedAt.isEmpty == false
                || controller.currentStepIndex >= indexOfTheStepAfterTheGate
                || controller.autopilotIsRunning == false
        }
        #expect(settled, "the real shell run should reach a decision inside 120s")

        // Prove the real work actually happened, so a failure below is about the
        // gate rather than about a shell that never got going.
        let bunLockfileExists = FileManager.default.fileExists(
            atPath: (checkoutFolder as NSString).appendingPathComponent("bun.lock")
        )
        #expect(bunLockfileExists,
                "the real `bun install` must have run in the real checkout")

        #expect(
            gates.titlesOfEveryGateTheReaderWasParkedAt.isEmpty,
            """
            Through a real login shell, after real commands with real exit codes, \
            Iris still parked the reader at \
            \(gates.titlesOfEveryGateTheReaderWasParkedAt) with \
            com.apple.dt.Xcode already installed. The gate is not an artifact of \
            a scripted shell.
            """
        )
        #expect(
            controller.currentStepIndex >= indexOfTheStepAfterTheGate,
            """
            The install stopped at step \(controller.currentStepIndex) instead of \
            carrying on to sync-ios once the watched app was already installed.
            """
        )

        controller.closeTheGuide()
        await loginShell.endSession()
        await sideShell.endSession()
    }

    // MARK: - What chat was told about this Mac

    /// This Mac's real simulator runtimes, straight out of the tool the app has
    /// never once called.
    private static func iosSimulatorRuntimesOnThisMac() throws -> [String] {
        let listRuntimes = Process()
        listRuntimes.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        listRuntimes.arguments = ["simctl", "list", "runtimes", "-j"]
        let outputPipe = Pipe()
        listRuntimes.standardOutput = outputPipe
        listRuntimes.standardError = FileHandle.nullDevice
        try listRuntimes.run()
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        listRuntimes.waitUntilExit()
        guard let root = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else {
            return []
        }
        return runtimes.compactMap { runtime in
            guard (runtime["isAvailable"] as? Bool) == true else { return nil }
            return runtime["name"] as? String
        }
    }

    /// The second half of the report: thirteen turns of the assistant guessing
    /// about a simulator, because the facts it is handed name `xcodebuild` and
    /// stop there.
    @Test func theFactsChatIsGivenSayNothingAboutTheIosSimulatorRuntime() async throws {
        // The precondition the probe would be gated on, and the state the
        // reader's Mac was in: Xcode installed.
        try #require(AssistantMachineFacts.isOnThePath("xcodebuild"),
                     "this test is about a Mac with Xcode on it")
        let runtimesThisMacActuallyHas = try Self.iosSimulatorRuntimesOnThisMac()

        let facts = try #require(AssistantMachineFacts.summary(
            publikBaseURL: "https://publikhq.com",
            installedCatalogApps: ["kneecap"]
        ))

        // Iris does tell the model Xcode is here...
        #expect(facts.contains("xcodebuild"),
                "the facts block already reports the Xcode toolchain")

        // ...and nothing at all about whether anything can be run on it.
        let runtimesAsTheyWouldBeNamed = runtimesThisMacActuallyHas.isEmpty
            ? "no available runtime"
            : runtimesThisMacActuallyHas.joined(separator: ", ")
        #expect(
            facts.lowercased().contains("simulator"),
            """
            The facts chat is given never mention the iOS Simulator runtime. \
            `xcrun simctl list runtimes -j` on this Mac reports \
            \(runtimesAsTheyWouldBeNamed), and none of it reaches the model. On \
            the reader's Mac simctl listed nothing at all, and the assistant \
            spent thirteen turns inventing a device dropdown before a screenshot \
            happened to show "Downloading iOS 26.5... 632.9 MB of 8.52 GB". The \
            facts block said Xcode was installed and said nothing about the \
            runtime, which is the exact asymmetry that produced the guessing. \
            Facts block was:
            \(facts)
            """
        )
    }
}
