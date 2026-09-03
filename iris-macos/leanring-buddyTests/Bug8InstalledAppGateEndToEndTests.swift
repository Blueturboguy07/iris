//
//  Bug8InstalledAppGateEndToEndTests.swift
//  leanring-buddyTests
//
//  THE REGRESSION GUARD for Bug 8 (cofounder Test 9, Iris 0.9.6 build 22): an
//  unattended kneecap install stopped and asked a reader with Xcode 26.6 on
//  their Mac to go and install Xcode, and stayed stopped for twenty-six seconds
//  until they said so by hand. `Bug8InstalledAppGateReproTests` states the bug.
//  This file states the OUTCOME, as far down the real stack as this Mac allows,
//  so the bug cannot come back quietly.
//
//  == HOW FAR DOWN THIS GOES, AND THE THREE THINGS THAT ARE NOT REAL ==
//
//  Real: the drive loop (`GuideSessionController.driveAutopilotFromTheCurrentStep`),
//  the real `GuideAutopilotRunner`, TWO REAL PTY LOGIN SHELLS
//  (`GuideAutopilotShellSession`, the reader's own zsh through Iris's generated
//  ZDOTDIR, sourcing the reader's own dotfiles), the real `bun` and the real
//  `node` on this Mac, a real `git init` checkout in a temp folder shaped like
//  the reader's `~/kneecap` (a bun workspace with an `apps/mobile` package), the
//  real `GuideService` decoding real guide JSON off a real `URLSession`, and —
//  the part the repro faked — the REAL `AppInventoryService` backed by the REAL
//  `SystemInstalledApplicationLocator`, so "is Xcode installed?" is answered by
//  this Mac's own LaunchServices and Spotlight rather than by a fixture.
//
//  Not real, each for a reason that is about not damaging the machine running
//  the suite rather than about the code under test:
//
//    1. `bringTheInstalledAppAStepWaitsForToTheFront` is left NIL. In the app
//       CompanionManager wires it to `NSWorkspace.openApplication`, and calling
//       it here would throw Xcode up over the top of whoever is running the
//       tests. Left nil the drive loop still takes the same branch and still
//       advances (`await theClosure?(bundleId)` on a nil closure is a no-op), so
//       what is measured is exactly the reader-visible outcome: the install
//       carries on by itself. Leaving it nil has a second, deliberate benefit —
//       this file references no API that did not exist before the fix, so the
//       revert check fails on ASSERTIONS rather than on a compile error.
//    2. The watch loop is given no frames and a fixed local signal source. The
//       real ones capture the screen of whoever is running the suite and make AX
//       calls this unsigned test binary has no grant for. The signals it is
//       given are the reader's at 07:04:09 in the log: their browser in front,
//       on the App Store page, so the step's `foregroundApp` expectation cannot
//       settle by itself — which is what makes this a test of the DRIVE loop.
//    3. The `install-xcode` href is `https://apps-apple-com.invalid/...`. The
//       real one is on `ExternalLinkPolicy`'s allowlist, and the gate path opens
//       it, so a faithful copy would fling the Mac App Store open. `.invalid` is
//       the reserved never-resolving TLD and is not on the allowlist, so the
//       open is refused. It changes nothing about either branch: the fixed path
//       never reaches the open at all, and the failing path discards its result.
//
//  Nothing else is substituted. In particular the commands are real work with
//  real exit codes: `bun install` writes a real lockfile, `bun run build` writes
//  the editor bundle, and `bun run sync` copies that bundle into the iPhone
//  project the way `bunx cap sync ios` does. The last of those is the assertion
//  that matters — a file that only exists on disk if the install got PAST the
//  gate and did the next piece of work.
//
//  == WHAT "NOT INSTALLED" MEANS HERE ==
//
//  The control leg has to be a Mac without the watched app, and Xcode cannot be
//  removed from the founder's Mac to make one. So the control's step watches a
//  bundle identifier that is genuinely absent from every Mac — the real
//  LaunchServices lookup misses it and the real Spotlight fallback misses it
//  too, which is precisely the state of a reader who has not installed Xcode.
//  The rest of that step is the wire's, so what it proves is the thing that must
//  never break: the gate is skipped because the app is HERE, not because the
//  step is an `open` step. A third leg drives the same install with the check
//  left UNWIRED and Xcode really installed, pinning the other half of that same
//  rule: no answer is not a yes.
//
//  What is NOT asserted here, and why: that `CompanionManager` actually injects
//  `installedDesktopAppCheck`. It does so inside a private
//  `connectTheGuideToTheEye()`, reachable only through `CompanionManager.start()`
//  — which installs a global CGEvent tap, starts maintain mode and can put the
//  overlay on screen. Calling that from a test would take over the machine
//  running the suite, so it is left alone here, exactly as every other closure
//  wired in that method is.
//
//  == THE OTHER HALF: WHAT CHAT IS TOLD ABOUT THIS MAC ==
//
//  After the gate the reader asked chat how to get the build onto a phone, and
//  the assistant spent thirteen turns inventing a device dropdown before a
//  screenshot happened to show "Downloading iOS 26.5… 632.9 MB of 8.52 GB" —
//  the Mac had Xcode and no runtime at all, and `AssistantMachineFacts.summary`
//  reported `xcodebuild` and nothing else. The last test asserts the fact block
//  chat is actually handed, on the real path (the default argument, which
//  measures), against this Mac's real `xcrun simctl list runtimes -j`.
//

import AppKit
import Foundation
import Testing
@testable import Iris

/// The pty legs spawn real login shells, which is the whole point of them, and
/// the same switch the rest of the suite uses turns them off.
private let ptyBackedEndToEndLegsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

@Suite("Bug 8 end-to-end — an install does not stop for an app that is already here", .serialized)
@MainActor
struct Bug8InstalledAppGateEndToEndTests {

    // MARK: - The two seams, and nothing else

    /// Hands back no frames at all, so no test in this file ever captures the
    /// screen of whoever is running the suite.
    final class NoFramesEverCaptured: WatchLoopFrameSource {
        func captureFingerprintOfTheCurrentScreen() async -> ScreenFrameFingerprint? { nil }
        func captureOneFrameForAVisualModelCheck() async -> Data? { nil }
    }

    /// The reader as the log has them at 07:04:09: the App Store page is in
    /// front of them, so the `install-xcode` step's `foregroundApp` expectation
    /// cannot settle on its own and the decision under test belongs entirely to
    /// the drive loop.
    final class TheReaderIsLookingAtTheAppStorePage: WatchLoopLocalSignalSource {
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

    /// Never reached — no step driven here declares a `visual` expectation while
    /// the loop is live — but injected so no leg of this file can make a model
    /// call even by accident.
    final class NoVisualCheckIsEverMade: WatchLoopVisualEvaluator {
        func evaluateWhetherTheStepLooksDone(
            screenshotJPEGData: Data,
            visualPrompt: String,
            stepTitle: String,
            hintsTheStepAuthorWrote: [String],
            context: WatchScreenContext
        ) async -> WatchVerdict? { nil }
    }

    /// Never proposes a repair, so nothing here can be rescued by a model call
    /// and the only thing that can move the install on is the gate decision.
    final class NeverProposesAFix: GuideAutopilotFixProposing {
        func proposeFix(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(
            for context: GuideAutopilotFailureContext
        ) async throws -> GuideAutopilotProposedFix? { nil }
    }

    /// Every gate the reader was parked at, which is what `CompanionManager`
    /// forwards to the takeover's parked card — the log's
    /// `takeover: PARKED … title=Install Xcode`.
    final class ManualGateRecorder {
        private(set) var titlesOfEveryGateTheReaderWasParkedAt: [String] = []
        func record(title: String) {
            titlesOfEveryGateTheReaderWasParkedAt.append(title)
        }
    }

    // MARK: - The guide, served the way publik serves it

    /// `GET /api/iris/guides/kneecap`, narrowed to the gate's own neighbourhood
    /// and with each command rewritten to real work a real login shell can
    /// finish offline in a temp checkout. Step kinds, the watch blocks, the href
    /// and the order are the wire's; see the file header for the substitutions.
    final class KneecapGateNeighbourhoodGuideURLProtocol: URLProtocol {
        /// Set once before the session is built and read by the loading
        /// callback. The suite is `.serialized`, so there is exactly one writer.
        nonisolated(unsafe) static var checkoutFolderTheStepsRunIn = ""

        /// Which app the `install-xcode` step waits to see in front. The
        /// installed leg uses Xcode's real bundle identifier; the control leg
        /// uses one no Mac has. See "WHAT NOT INSTALLED MEANS HERE" above.
        nonisolated(unsafe) static var bundleIdentifierTheGateWatchesFor = ""

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let requestURL = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = Data(Self.guideJSON(
                checkout: Self.checkoutFolderTheStepsRunIn,
                watchedBundleIdentifier: Self.bundleIdentifierTheGateWatchesFor
            ).utf8)
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

        static func guideJSON(checkout: String, watchedBundleIdentifier: String) -> String {
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
                        "expect": [
                          {"type": "foregroundApp", "bundleId": "\(watchedBundleIdentifier)"}
                        ]
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

    // MARK: - A real checkout of the reader's kneecap folder

    /// Xcode's real bundle identifier, the one the published kneecap step names.
    static let bundleIdentifierOfXcode = "com.apple.dt.Xcode"

    /// A bundle identifier no Mac has, standing in for a reader who has not
    /// installed Xcode — the only honest way to test the absent case against the
    /// REAL locator on a Mac that does have Xcode.
    static let bundleIdentifierNoMacHasInstalled =
        "com.publikhq.iris.bug8.an-app-this-mac-does-not-have"

    /// Where `install-xcode` sits in the fixture, so a failure names a step
    /// rather than a number.
    static let indexOfTheInstallXcodeStep = 2

    /// Builds a real git checkout shaped like the reader's `~/kneecap`: a
    /// repository, a bun workspace at the root, and an `apps/mobile` package
    /// whose two scripts do with real `node` what Vite and Capacitor do in the
    /// real guide — write the editor bundle, then copy it into the iPhone
    /// project. `sync.mjs` copies rather than creates on purpose: it can only
    /// succeed if the build step really ran first, so the file it leaves behind
    /// is proof of the whole chain and not just of its own step.
    private static func buildARealKneecapCheckout() throws -> String {
        let checkoutFolder = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug8-e2e-kneecap-\(UUID().uuidString)")
        let mobilePackageFolder = (checkoutFolder as NSString)
            .appendingPathComponent("apps/mobile")
        try FileManager.default.createDirectory(
            atPath: mobilePackageFolder, withIntermediateDirectories: true
        )

        try #"{"name":"kneecap","private":true,"workspaces":["apps/*"]}"#
            .write(
                toFile: (checkoutFolder as NSString).appendingPathComponent("package.json"),
                atomically: true, encoding: .utf8
            )
        try #"{"name":"mobile","scripts":{"build":"node build.mjs","sync":"node sync.mjs"}}"#
            .write(
                toFile: (mobilePackageFolder as NSString).appendingPathComponent("package.json"),
                atomically: true, encoding: .utf8
            )
        try """
            import { mkdirSync, writeFileSync } from "node:fs";
            mkdirSync("www", { recursive: true });
            writeFileSync("www/index.html", "<!doctype html><title>kneecap</title>");
            """
            .write(
                toFile: (mobilePackageFolder as NSString).appendingPathComponent("build.mjs"),
                atomically: true, encoding: .utf8
            )
        try """
            import { copyFileSync, mkdirSync } from "node:fs";
            mkdirSync("ios/App/App/public", { recursive: true });
            copyFileSync("www/index.html", "ios/App/App/public/index.html");
            """
            .write(
                toFile: (mobilePackageFolder as NSString).appendingPathComponent("sync.mjs"),
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

    /// The lockfile a real `bun install` leaves in the real checkout.
    private static func realBunLockfileExists(inCheckout checkoutFolder: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (checkoutFolder as NSString).appendingPathComponent("bun.lock")
        )
    }

    /// The editor bundle the pre-gate build step writes.
    private static func theEditorBundleExists(inCheckout checkoutFolder: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (checkoutFolder as NSString)
                .appendingPathComponent("apps/mobile/www/index.html")
        )
    }

    /// THE OUTCOME THE READER CARES ABOUT: the editor sitting inside the iPhone
    /// project, which only exists if the install got past the `install-xcode`
    /// gate on its own and ran the step after it.
    private static func theEditorIsInsideTheIPhoneProject(
        inCheckout checkoutFolder: String
    ) -> Bool {
        FileManager.default.fileExists(
            atPath: (checkoutFolder as NSString)
                .appendingPathComponent("apps/mobile/ios/App/App/public/index.html")
        )
    }

    // MARK: - Driving one whole install through real shells

    /// Collects the bundle identifiers the drive loop asked about, so a failure
    /// can say not just "Iris got the answer wrong" but "Iris never asked". The
    /// ANSWER is still the real inventory's — this only listens in.
    final class QuestionsAskedOfTheRealInventory {
        private(set) var bundleIdentifiersAskedAbout: [String] = []
        func note(_ bundleIdentifier: String) {
            bundleIdentifiersAskedAbout.append(bundleIdentifier)
        }
    }

    /// Everything an assertion needs to see about one driven install.
    struct DrivenInstall {
        let controller: GuideSessionController
        let gates: ManualGateRecorder
        let checkoutFolder: String
        let questionsAskedOfTheRealInventory: QuestionsAskedOfTheRealInventory
        let loginShell: GuideAutopilotShellSession
        let longRunningShell: GuideAutopilotShellSession
    }

    /// Opens the fixture guide, starts autopilot, and lets the whole thing run
    /// through real login shells until it either parks the reader at a gate or
    /// finishes the step after the gate.
    private static func driveARealInstallThroughTheGate(
        watchingForBundleIdentifier bundleIdentifierTheGateWatchesFor: String,
        irisMayAskWhetherTheAppIsInstalled: Bool = true
    ) async throws -> DrivenInstall {
        let checkoutFolder = try buildARealKneecapCheckout()
        KneecapGateNeighbourhoodGuideURLProtocol
            .checkoutFolderTheStepsRunIn = checkoutFolder
        KneecapGateNeighbourhoodGuideURLProtocol
            .bundleIdentifierTheGateWatchesFor = bundleIdentifierTheGateWatchesFor

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [KneecapGateNeighbourhoodGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug8.e2e.\(UUID().uuidString)")
        )
        let guideService = GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: sessionConfiguration),
            userDefaults: defaults
        )

        let loginShell = GuideAutopilotShellSession(startingDirectory: checkoutFolder)
        let longRunningShell = GuideAutopilotShellSession(startingDirectory: checkoutFolder)
        let controller = GuideSessionController(
            guideService: guideService,
            watchLoop: WatchLoop(
                frameSource: NoFramesEverCaptured(),
                localSignalSource: TheReaderIsLookingAtTheAppStorePage(),
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
                    longRunningSession: longRunningShell,
                    fixProposer: NeverProposesAFix(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // The one-time autonomy grant lives in UserDefaults on the real machine;
        // this run must not depend on whether an earlier session left it on.
        controller.confirmAutonomousControl = { true }

        // The REAL inventory service, with the REAL locator behind it — this
        // Mac's own LaunchServices, and Spotlight when LaunchServices has not
        // caught up. Wired exactly the way `CompanionManager` wires it, with
        // nothing but a recorder in the way.
        let realAppInventoryService = AppInventoryService(
            installedApplicationLocator: SystemInstalledApplicationLocator()
        )
        let questionsAskedOfTheRealInventory = QuestionsAskedOfTheRealInventory()
        if irisMayAskWhetherTheAppIsInstalled {
            controller.installedDesktopAppCheck = { bundleIdentifier in
                questionsAskedOfTheRealInventory.note(bundleIdentifier)
                return realAppInventoryService
                    .installedApplicationURL(forBundleIdentifier: bundleIdentifier) != nil
            }
        }
        // `bringTheInstalledAppAStepWaitsForToTheFront` is deliberately left
        // unwired here — see reason 1 in the file header.

        let gates = ManualGateRecorder()
        controller.onAutopilotWaitingForReaderAtGate = { title, _ in
            gates.record(title: title)
        }

        await controller.openLatestVersionOfGuide(slug: "kneecap")
        controller.startAutopilot()

        // Whichever comes first: the gate the report is about, or the file that
        // only exists once the install has gone past it and done the next piece
        // of work.
        _ = await pump(within: 180) {
            gates.titlesOfEveryGateTheReaderWasParkedAt.isEmpty == false
                || theEditorIsInsideTheIPhoneProject(inCheckout: checkoutFolder)
                || controller.autopilotIsRunning == false
        }

        return DrivenInstall(
            controller: controller,
            gates: gates,
            checkoutFolder: checkoutFolder,
            questionsAskedOfTheRealInventory: questionsAskedOfTheRealInventory,
            loginShell: loginShell,
            longRunningShell: longRunningShell
        )
    }

    /// Shuts a driven install down: the guide, both real shells, and the temp
    /// checkout.
    private static func tearDownTheDrivenInstall(_ install: DrivenInstall) async {
        install.controller.closeTheGuide()
        await install.loginShell.endSession()
        await install.longRunningShell.endSession()
        try? FileManager.default.removeItem(atPath: install.checkoutFolder)
    }

    /// Polls a main-actor condition until it holds or the deadline passes. The
    /// drive loop runs in its own Task, so its effects are observed rather than
    /// awaited.
    private static func pump(
        within seconds: Double, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - The outcome

    /// THE GUARD. Xcode is genuinely on this Mac, and this Mac's own
    /// LaunchServices says so. The install must run the whole way through
    /// without ever stopping to ask the reader to install it, and the work after
    /// the gate must actually land on disk.
    @Test(
        "an unattended install walks straight past Install Xcode on a Mac that has Xcode",
        .enabled(if: ptyBackedEndToEndLegsAreEnabled)
    )
    func theInstallCarriesItselfPastTheGateWhenTheWatchedAppIsReallyInstalled() async throws {
        // The reader's situation, established against this Mac rather than
        // assumed: if Xcode is not here, nothing below is the reported bug.
        try #require(
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleIdentifierOfXcode
            ) != nil,
            "this test is about a Mac that already has Xcode on it, like the reader's"
        )

        let install = try await Self.driveARealInstallThroughTheGate(
            watchingForBundleIdentifier: Self.bundleIdentifierOfXcode
        )

        // The real work before the gate, so a failure below is about the gate
        // and not about a shell that never got going.
        #expect(
            Self.realBunLockfileExists(inCheckout: install.checkoutFolder),
            "a real `bun install` must have run in the real checkout"
        )
        #expect(
            Self.theEditorBundleExists(inCheckout: install.checkoutFolder),
            "a real `bun run build` must have written apps/mobile/www before the gate"
        )

        // The whole report, in one line of the log.
        #expect(
            install.gates.titlesOfEveryGateTheReaderWasParkedAt
                .contains("Install Xcode") == false,
            """
            Through real login shells, after real commands with real exit codes, \
            and with this Mac's own LaunchServices answering that \
            \(Self.bundleIdentifierOfXcode) is installed, Iris still parked the \
            reader at \(install.gates.titlesOfEveryGateTheReaderWasParkedAt). \
            That is Test 9 verbatim: "drive: step install-xcode -> MANUAL branch, \
            waiting at gate (return)", then "takeover: PARKED ... title=Install \
            Xcode", then twenty-six seconds of a reader with Xcode 26.6 being \
            told to go and install Xcode.
            """
        )

        // And it must have skipped it for the right reason: because it asked.
        #expect(
            install.questionsAskedOfTheRealInventory.bundleIdentifiersAskedAbout
                .contains(Self.bundleIdentifierOfXcode),
            """
            The drive loop never asked whether \(Self.bundleIdentifierOfXcode) \
            was installed — it asked about \
            \(install.questionsAskedOfTheRealInventory.bundleIdentifiersAskedAbout). \
            A gate that opens without asking is the same bug wearing the other \
            face: it would abandon the reader who really does need Xcode.
            """
        )

        // THE READER-VISIBLE OUTCOME. Not an index, not a flag: the editor
        // bundle sitting inside the iPhone project, put there by a real `node`
        // in a real login shell in the step AFTER the one that used to stop.
        #expect(
            Self.theEditorIsInsideTheIPhoneProject(inCheckout: install.checkoutFolder),
            """
            The install stopped at step \(install.controller.currentStepIndex) \
            and never copied the editor into the iPhone project. On the reader's \
            Mac that is an install that has done everything except the part that \
            makes the app exist, waiting on a reader who has no idea it is \
            waiting.
            """
        )
        #expect(
            install.controller.currentStepIndex > Self.indexOfTheInstallXcodeStep,
            "a step whose app is already installed is Iris's to finish, not the reader's"
        )

        await Self.tearDownTheDrivenInstall(install)
    }

    /// THE HALF THAT MUST NOT CHANGE. With the watched app genuinely absent —
    /// this Mac's real LaunchServices AND its real Spotlight fallback both
    /// missing it — the gate is exactly what it has always been, and nothing
    /// after it runs. A "fix" that skipped every `open` step would leave the
    /// reader who really does need Xcode with a broken install and no idea why.
    @Test(
        "the gate still stands, and still stops the install, when the app is genuinely missing",
        .enabled(if: ptyBackedEndToEndLegsAreEnabled)
    )
    func theGateStillStopsTheInstallWhenTheWatchedAppIsGenuinelyMissing() async throws {
        // The premise of the control, checked rather than assumed.
        try #require(
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleIdentifierNoMacHasInstalled
            ) == nil,
            "the control leg needs a bundle identifier this Mac genuinely does not have"
        )

        let install = try await Self.driveARealInstallThroughTheGate(
            watchingForBundleIdentifier: Self.bundleIdentifierNoMacHasInstalled
        )

        #expect(
            Self.realBunLockfileExists(inCheckout: install.checkoutFolder),
            "a real `bun install` must have run, or the gate was reached the wrong way"
        )
        #expect(
            install.gates.titlesOfEveryGateTheReaderWasParkedAt.last == "Install Xcode",
            """
            With the watched app genuinely absent the reader must still be asked \
            to install it. Gates recorded: \
            \(install.gates.titlesOfEveryGateTheReaderWasParkedAt).
            """
        )
        #expect(
            install.controller.currentStepIndex == Self.indexOfTheInstallXcodeStep,
            "the gate is recorded against the install-xcode step, the step the log names"
        )
        #expect(
            install.controller.autopilotHandedTheCurrentStepToTheReader,
            "the step is the reader's while the app is genuinely missing"
        )
        #expect(
            Self.theEditorIsInsideTheIPhoneProject(inCheckout: install.checkoutFolder) == false,
            """
            The install ran the step AFTER the gate even though the app the gate \
            watches for is not on this Mac. Skipping an `open` step because it is \
            an `open` step, rather than because the app is here, is the report's \
            bug inverted.
            """
        )

        await Self.tearDownTheDrivenInstall(install)
    }

    /// THE FAIL-SAFE. The gate decision is only as good as the answer it is
    /// given, and that answer is injected — a controller built without it (or a
    /// day when one deleted line in `CompanionManager` stops injecting it) must
    /// keep the gate rather than assume the app is there. Xcode really IS
    /// installed on this Mac for this leg, so the only thing standing between
    /// the loop and the skip is the missing answer.
    ///
    /// Without this, "no answer" could quietly become a yes and every reader who
    /// genuinely needs Xcode would be walked past the step that installs it,
    /// straight into a build that cannot work.
    @Test(
        "the gate stands when Iris has no way to ask whether the app is installed",
        .enabled(if: ptyBackedEndToEndLegsAreEnabled)
    )
    func theGateStandsWhenIrisHasNoWayToAskWhetherTheAppIsInstalled() async throws {
        try #require(
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: Self.bundleIdentifierOfXcode
            ) != nil,
            "the point of this leg is that the app IS here and Iris still cannot tell"
        )

        let install = try await Self.driveARealInstallThroughTheGate(
            watchingForBundleIdentifier: Self.bundleIdentifierOfXcode,
            irisMayAskWhetherTheAppIsInstalled: false
        )

        #expect(
            install.questionsAskedOfTheRealInventory.bundleIdentifiersAskedAbout.isEmpty,
            "this leg is about a controller with no check wired, so nothing may have been asked"
        )
        #expect(
            install.gates.titlesOfEveryGateTheReaderWasParkedAt.last == "Install Xcode",
            """
            With no way to ask whether \(Self.bundleIdentifierOfXcode) is \
            installed, Iris skipped the gate anyway. Gates recorded: \
            \(install.gates.titlesOfEveryGateTheReaderWasParkedAt). Treating an \
            absent answer as "it is already here" would walk a reader who really \
            does need Xcode straight past the step that installs it.
            """
        )
        #expect(
            Self.theEditorIsInsideTheIPhoneProject(inCheckout: install.checkoutFolder) == false,
            "nothing after the gate may run on an answer Iris never got"
        )

        await Self.tearDownTheDrivenInstall(install)
    }

    // MARK: - What chat is told about this Mac

    /// This Mac's real iOS Simulator runtimes, read independently of the app so
    /// the assertion below is measured against the tool and not against the code
    /// under test.
    private static func iosSimulatorRuntimesThisMacReallyHas() throws -> [String] {
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
            guard (runtime["isAvailable"] as? Bool) == true,
                  let name = runtime["name"] as? String,
                  name.hasPrefix("iOS") else { return nil }
            return name
        }
    }

    /// The app's own probe — the one `CompanionManager` measures off the main
    /// actor — against an independent reading of the same tool: it names every
    /// installed iOS runtime, and ONLY iOS ones, because a watchOS or tvOS
    /// runtime would let the assistant promise an iPhone build it cannot run.
    @Test("the app's own runtime probe agrees with simctl and names only iOS runtimes")
    func theAppsOwnRuntimeProbeAgreesWithSimctl() throws {
        try #require(AssistantMachineFacts.isOnThePath("xcodebuild"),
                     "this test is about a Mac with the Xcode toolchain on it")
        let runtimesThisMacReallyHas = try Self.iosSimulatorRuntimesThisMacReallyHas()
        let runtimesTheProbeReports = try #require(
            AssistantMachineFacts.installedIosSimulatorRuntimes(),
            "with Xcode installed the probe must answer, never say 'unknown'"
        )
        #expect(Set(runtimesTheProbeReports) == Set(runtimesThisMacReallyHas))
        #expect(runtimesTheProbeReports.allSatisfy { $0.hasPrefix("iOS") })
    }

    /// THE SECOND HALF, on the real path: the fact block chat is handed before
    /// it answers must say what this Mac can actually RUN an iOS build on, not
    /// only that a toolchain is installed. Called exactly the way
    /// `CompanionManager` calls it, so the runtime probe is the app's own.
    @Test("the facts chat is handed name this Mac's real iOS Simulator runtimes")
    func theFactsChatIsHandedNameTheRealSimulatorRuntimes() throws {
        // The precondition the probe is gated on, and the state the reader's Mac
        // was in: Xcode installed.
        try #require(AssistantMachineFacts.isOnThePath("xcodebuild"),
                     "this test is about a Mac with the Xcode toolchain on it")
        let runtimesThisMacReallyHas = try Self.iosSimulatorRuntimesThisMacReallyHas()
        try #require(
            runtimesThisMacReallyHas.isEmpty == false,
            "this Mac needs at least one installed iOS runtime for this leg to mean anything"
        )

        // Passed in exactly the way CompanionManager passes it — measured
        // first, off the main actor, then handed over — because summary has
        // no default that would measure on the caller's thread.
        let facts = try #require(AssistantMachineFacts.summary(
            publikBaseURL: "https://publikhq.com",
            installedCatalogApps: ["kneecap"],
            iosSimulatorRuntimes: runtimesThisMacReallyHas
        ))

        #expect(facts.contains("xcodebuild"),
                "the facts block already reported the Xcode toolchain, and must keep doing so")

        for runtimeName in runtimesThisMacReallyHas {
            #expect(
                facts.contains(runtimeName),
                """
                The facts chat is handed never name \(runtimeName), which \
                `xcrun simctl list runtimes -j` reports as installed and \
                available on this Mac. On the reader's Mac simctl listed nothing \
                at all while the same block said `xcodebuild` was installed, and \
                the assistant spent thirteen turns inventing a device dropdown \
                before a screenshot happened to show "Downloading iOS 26.5... \
                632.9 MB of 8.52 GB". Telling a model a toolchain is here and \
                telling it nothing about whether anything can be run on it is \
                the asymmetry that produced the guessing. Facts block was:
                \(facts)
                """
            )
        }
    }
}
