//
//  Bug3StaleShellPathEndToEndTests.swift
//  leanring-buddyTests
//
//  Bug 3's END-TO-END GUARD — "Stale PATH after a mid-run tool install
//  (relaunch required)".
//
//  `Bug3StaleShellPathReproTests` proves the defect: the retry path re-asks a
//  shell whose environment was built before the reader installed anything, so
//  "Try again" fails identically however many times it is tapped. This file
//  guards the outcome the reader actually cares about, one level up: an install
//  that stopped because a tool was missing FINISHES — in the same Iris, in the
//  same shell process, with real files on disk to show for it — once they
//  install the tool and tap "Try again".
//
//  What is real here:
//    - the real `GuideSessionController`, its real drive loop, the real
//      `GuideAutopilotRunner`, the real risk gate, the real autonomy grant, and
//      the real `retryTheSurfacedStep()` behind the "Try again" button;
//    - a real `zsh -l -i` on a real pty, spawned through the app's own
//      `GuideAutopilotPseudoTerminal` with the app's own generated ZDOTDIR;
//    - THIS MAC'S OWN bun and node, doing real work: `bun install` writes a
//      real `bun.lock` into a real git checkout and `bun run build` runs a real
//      node script that writes a real `www/index.html`. A shell-script stand-in
//      would only prove the fixture — the point of this file is that the tool
//      the reader installs is the tool that then runs;
//    - a real temporary HOME whose real `.zshrc` gains bun's own
//      `export PATH=…` line mid-run, exactly as the reader's did at 07:00.
//
//  Faked, and only this: the model. The fix ladder is the shape Test 9's had
//  (it could only tell the reader to install bun themselves) and the guide JSON
//  is served from a URLProtocol instead of publik. No model is called.
//
//  Two things this file deliberately does NOT use. `pnpm`: the pnpm on a
//  developer Mac is usually corepack's shim, which DOWNLOADS a pnpm build the
//  first time it runs in a fresh HOME, and a guard test must not need the
//  network. And the App Store step that follows `build-editor` in the published
//  kneecap guide, for the reason the repro gives — a test must not open the App
//  Store on the machine running it.
//
//  This file is compiled together with `Bug3StaleShellPathReproTests.swift`,
//  whose real-pty login shell (`PersistentLoginShellInATemporaryReaderHome`),
//  temporary reader Mac, and unused long-running session it reuses rather than
//  copying. That class exists there because the shipped
//  `GuideAutopilotShellSession` reads the reader's home from `FileManager` in
//  two non-injectable places and so cannot be pointed at a scratch home; see
//  that file's header.
//
//  `theShippedShellSurvivesTheRetryPathOnThisMacsOwnDotfiles` is the control,
//  and it passes with or without the fix. It is here because it is the one
//  place the SHIPPED shell object meets the retry path on this Mac's own
//  dotfiles: re-sourcing them inside a running interactive shell is the thing
//  the fix does to a real reader's machine, and a rc that came back wrong — no
//  pager exports, a rebuilt session that lost what earlier steps put in it —
//  would break every step after the retry rather than the retry itself.
//

import Foundation
import Testing
@testable import Iris

// MARK: - The real tools this Mac has

/// The tools these tests drive for real. Both are looked up as files rather
/// than asked of a shell: the answer decides whether the suite can run at all,
/// which is settled before any shell exists.
enum Bug3RealToolchainOnThisMac {

    /// Where bun's official installer puts it, then the two places a reader who
    /// used a package manager instead would have it. Nil on a Mac with no bun,
    /// which turns this suite off rather than substituting a stand-in.
    static let pathOfTheRealBun: String? = {
        let developersOwnHome = FileManager.default.homeDirectoryForCurrentUser.path
        let placesBunGetsInstalled = [
            (developersOwnHome as NSString).appendingPathComponent(".bun/bin/bun"),
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        return placesBunGetsInstalled.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    /// node is never installed into the temporary home. It is on the login PATH
    /// that `/etc/paths.d` gives every shell whoever's home it starts in —
    /// which is exactly why the reader's Test 9 Mac had node and not bun.
    static let realNodeIsInstalled: Bool =
        ["/opt/homebrew/bin/node", "/usr/local/bin/node"].contains {
            FileManager.default.isExecutableFile(atPath: $0)
        }
}

/// The same opt-out the repro and `GuideAutopilotShellSessionTests` use, plus
/// the tools: every test in this file spawns a real login shell, and the
/// headline one also runs this Mac's own bun and node.
private let bug3EndToEndTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"
        && Bug3RealToolchainOnThisMac.pathOfTheRealBun != nil
        && Bug3RealToolchainOnThisMac.realNodeIsInstalled

// MARK: - The reader's Mac, with this machine's real tools on it

enum Bug3EndToEndReaderMac {

    /// The repro's temporary Mac — a minimal `.zshrc`, a real git checkout at
    /// `~/kneecap`, kneecap's own workspace shape — with one thing changed: the
    /// mobile package's `build` script becomes a real node script instead of
    /// `vite build`, which nothing here could run offline. The file that script
    /// writes is the evidence that bun and node both really ran.
    static func makeTemporaryReaderMacWhoseBuildStepIsRealWork() throws -> String {
        let readerHome = try Bug3ReaderMacFixture.makeTemporaryReaderMac()
        let mobilePackageDirectory = (readerHome as NSString)
            .appendingPathComponent("kneecap/apps/mobile")
        try #"{"name":"@kneecap/mobile","version":"0.0.0","scripts":{"build":"node build.mjs"}}"#
            .write(
                toFile: (mobilePackageDirectory as NSString)
                    .appendingPathComponent("package.json"),
                atomically: true, encoding: .utf8
            )
        try """
        import { mkdirSync, writeFileSync } from "node:fs";
        mkdirSync("www", { recursive: true });
        writeFileSync("www/index.html", "<!doctype html><title>kneecap editor</title>");
        console.log("built in 1.20s");
        """.write(
            toFile: (mobilePackageDirectory as NSString)
                .appendingPathComponent("build.mjs"),
            atomically: true, encoding: .utf8
        )
        return readerHome
    }

    /// The lockfile `bun install` writes when it really runs — the one file
    /// Test 9 found dirty, "timestamped the same second install-deps succeeded".
    static func workspaceLockfile(inHome readerHome: String) -> String {
        (readerHome as NSString).appendingPathComponent("kneecap/bun.lock")
    }

    /// The page `bun run build` writes when it really runs.
    static func builtEditorPage(inHome readerHome: String) -> String {
        (readerHome as NSString)
            .appendingPathComponent("kneecap/apps/mobile/www/index.html")
    }

    /// What the reader did in their own Terminal at ~07:00, with this Mac's
    /// real bun rather than a stand-in: the binary lands in `~/.bun/bin` and
    /// the installer appends its export block to `~/.zshrc`. A symlink because
    /// it is the same executable either way and bun is a large binary; a shell
    /// finds it through PATH identically.
    static func installTheRealBunTheWayBunsInstallerDoes(
        _ pathOfTheRealBun: String, inHome readerHome: String
    ) throws {
        let binDirectory = (readerHome as NSString).appendingPathComponent(".bun/bin")
        try FileManager.default.createDirectory(
            atPath: binDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: (binDirectory as NSString).appendingPathComponent("bun"),
            withDestinationPath: pathOfTheRealBun
        )

        let zshrcPath = (readerHome as NSString).appendingPathComponent(".zshrc")
        let whatTheReaderHadBefore = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        try (whatTheReaderHadBefore + """


        # bun
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        """).write(toFile: zshrcPath, atomically: true, encoding: .utf8)
    }
}

// MARK: - The guides, served the way publik serves them

/// Answers `GET /api/iris/guides/<slug>` for the two guides these tests drive.
final class Bug3EndToEndGuideURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url,
              let guideJSON = Self.guideJSONBySlug[
                  (requestURL.path as NSString).lastPathComponent
              ],
              let response = HTTPURLResponse(
                  url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(guideJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static let guideJSONBySlug = [
        "kneecap": kneecapGuideJSON,
        "iris-shell-continuity": shellContinuityGuideJSON,
    ]

    /// The published kneecap Mac + iPhone branch, cut down to the three steps
    /// this Mac can run offline: the tool check the reader's machine passed,
    /// and the two steps Test 9 died on. Their ids, working directories and
    /// commands are the published guide's own.
    static let kneecapGuideJSON = """
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
      "branches": [
        {
          "platform": "macos",
          "target": "ios",
          "label": "Mac + iPhone",
          "shell": "terminal",
          "setupSteps": [],
          "steps": [
            {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
             "body": "Git and the current Node LTS are required.",
             "command": "git --version\\nnode --version",
             "verifierLabel": "Git and Node respond with version numbers"},
            {"id": "install-deps", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Install the workspace",
             "body": "A few minutes the first time.", "command": "bun install",
             "verifierLabel": "The command finishes without an error"},
            {"id": "build-editor", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Build the editor",
             "body": "Bundles the editor into apps/mobile/www.",
             "command": "cd apps/mobile\\nbun run build",
             "verifierLabel": "The build reports it finished"}
          ],
          "unsupported": null
        }
      ]
    }
    """

    /// A guide of this test's own — no such app is published — whose only job
    /// is to put something into the shell BEFORE the step that fails, and read
    /// it back AFTER the retry. Its middle step fails until the reader does
    /// their part, which is the shape every "Try again" has.
    static let shellContinuityGuideJSON = """
    {
      "appSlug": "iris-shell-continuity",
      "appName": "Shell continuity",
      "version": 1,
      "status": "pilot",
      "sourceOwner": "Blueturboguy07",
      "sourceRepo": "iris",
      "sourceCommit": "0000000000000000000000000000000000000000",
      "outputType": "desktop_app",
      "estimatedMinutes": 1,
      "readmeSectionIds": ["build"],
      "branches": [
        {
          "platform": "macos",
          "target": null,
          "label": "Mac",
          "shell": "terminal",
          "setupSteps": [],
          "steps": [
            {"id": "remember-something", "kind": "terminal",
             "title": "Set something the later steps need",
             "body": "A version manager, a cargo env, an export a guide asks for.",
             "command": "export IRIS_BUG3_SET_BY_AN_EARLIER_STEP=still-the-same-shell",
             "verifierLabel": "The shell holds it"},
            {"id": "wait-for-the-reader", "kind": "terminal",
             "title": "Fails until the reader does their part",
             "body": "Stands in for the missing tool: it cannot pass until they act.",
             "command": "test -f ready-for-the-next-step.txt",
             "verifierLabel": "The file is there"},
            {"id": "write-down-what-the-shell-still-has", "kind": "terminal",
             "title": "Write down what the shell still has",
             "body": "",
             "command": "echo $IRIS_BUG3_SET_BY_AN_EARLIER_STEP > the-marker-the-shell-still-has.txt\\necho $PAGER > the-pager-the-shell-still-uses.txt",
             "verifierLabel": "Both files are written"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

/// The ladder the second test needs: the failure there is a file the reader has
/// to create, not a tool, so the bun advice the repro's ladder gives would be
/// the wrong sentence in the transcript. Modelled, never called for real.
@MainActor
final class Bug3LadderThatOnlyAsksTheReaderToDoItThemselves: GuideAutopilotFixProposing {

    private static let advice = GuideAutopilotProposedFix(
        diagnosis: "This step needs something only you can do.",
        confidence: "high",
        action: .askTheReaderToDoSomething(
            instruction: "Do the thing this step needs, then tap Try again."
        ),
        retryTheOriginalCommandAfterwards: false,
        cameFromWebSearch: false
    )

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        Self.advice
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        Self.advice
    }
}

// MARK: - The tests

@MainActor
@Suite(.enabled(if: bug3EndToEndTestsAreEnabled), .serialized)
struct Bug3StaleShellPathEndToEndTests {

    private static func guideServiceServingTheseGuides() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Bug3EndToEndGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug3.e2e.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    /// The reader's "Let Iris take control of your Mac?" grant, over a suite of
    /// this test's own so the developer's real preference is untouched.
    private static func autonomyGrantOfThisTestsOwn() throws -> AutopilotAutonomyGrant {
        AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug3.e2e.grant.\(UUID().uuidString)")
            )
        )
    }

    /// Polls a main-actor condition. The drive loop runs in a `Task` it does not
    /// hand back, so a test observes its effects.
    private func pump(
        within seconds: Double = 90,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: The guard

    /// The whole journey, with nothing between the button and the shell faked:
    /// Iris drives the kneecap guide, `bun install` exits 127 because the reader
    /// has no bun, the step is surfaced with "Try again", the reader installs
    /// this Mac's real bun the way bun's installer does — and one tap of "Try
    /// again" has to carry the install all the way to the end.
    ///
    /// Before the fix the retry re-ran `bun install` in a shell whose PATH was
    /// captured at spawn, so it exited 127 again, the guide never left
    /// `install-deps`, and quitting and relaunching Iris was the only cure.
    @Test func theInstallFinishesAfterTheReaderInstallsTheToolAndTapsTryAgain() async throws {
        let readerHome = try Bug3EndToEndReaderMac.makeTemporaryReaderMacWhoseBuildStepIsRealWork()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        // The ZDOTDIR trick — and therefore the reader's whole environment —
        // only applies when the login shell is zsh, as it is on every shipped Mac.
        try #require(
            GuideAutopilotShellSession.privateZdotdir() != nil,
            "this guard needs the zsh login shell the autopilot drives"
        )
        let pathOfTheRealBun = try #require(Bug3RealToolchainOnThisMac.pathOfTheRealBun)

        let shell = PersistentLoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheseGuides(),
            // Git and node were both on the reader's Mac and are on this one;
            // bun is the one thing missing, and the SHELL is what discovers
            // that, which is the whole point of the bug.
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: Bug3UnusedLongRunningShell(),
                    fixProposer: Bug3LadderThatOnlyGivesBunAdvice(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.autonomyGrant = try Self.autonomyGrantOfThisTestsOwn()
        controller.confirmAutonomousControl = { true }

        await controller.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: nil, stepIndexFromDeepLink: nil
        )
        try #require(controller.selectedBranch != nil, "the kneecap guide must open")

        controller.startAutopilot()

        // Iris runs the tool check with this Mac's real git and node, then
        // `cd ~/kneecap` and `bun install` — which the real shell cannot find.
        let theStepWasSurfaced = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        #expect(
            theStepWasSurfaced,
            "install-deps must surface with Try again / Continue past it; terminal tail: \(shell.tailForTheModel())"
        )
        #expect(
            shell.exitStatuses(of: "git --version\nnode --version") == [0],
            "the real git and node on this Mac answer the check step"
        )
        #expect(
            shell.exitStatuses(of: "bun install") == [127],
            "the first attempt must be the field's exit 127 — got \(shell.exitStatuses(of: "bun install"))"
        )

        // The reader installs bun in their own Terminal while the step sits
        // surfaced, and taps "Try again" once.
        try Bug3EndToEndReaderMac.installTheRealBunTheWayBunsInstallerDoes(
            pathOfTheRealBun, inHome: readerHome
        )
        controller.retryTheSurfacedStep()

        let theInstallFinished = await pump { controller.readerHasFinishedTheGuide }
        #expect(
            theInstallFinished,
            """
            THE OUTCOME: bun is installed and on the reader's PATH, one tap of \
            "Try again" happened, and the install has to run itself to the end \
            from there. It stopped on step \(controller.currentStepIndex) with \
            `bun install` exiting \(shell.exitStatuses(of: "bun install")). \
            Terminal tail: \(shell.tailForTheModel())
            """
        )
        #expect(
            shell.exitStatuses(of: "bun install").last == 0,
            "the retry ran the step's own command and it passed this time"
        )
        #expect(
            FileManager.default.fileExists(
                atPath: Bug3EndToEndReaderMac.workspaceLockfile(inHome: readerHome)
            ),
            "the real bun really installed the workspace — bun.lock is on disk"
        )
        let builtEditorPage = Bug3EndToEndReaderMac.builtEditorPage(inHome: readerHome)
        #expect(
            (try? String(contentsOfFile: builtEditorPage, encoding: .utf8))?
                .contains("kneecap editor") == true,
            "the build step ran real bun and real node — the page they write is on disk"
        )
        #expect(
            shell.numberOfShellProcessesSpawned == 1,
            """
            and all of it happened in the one shell that failed: the field's \
            only cure was quitting and relaunching Iris, which is what a second \
            spawn here would mean.
            """
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
        await shell.endSession()
    }

    // MARK: The control

    /// The same retry path, driving the SHIPPED `GuideAutopilotShellSession` on
    /// this Mac's own dotfiles — the one object the guard above cannot use, and
    /// the one the fix re-sources a real rc into.
    ///
    /// It asserts what has to still be true AFTER a retry, not that the retry
    /// found a new tool: the export an earlier step put in the shell is still
    /// there (so the session was refreshed, not rebuilt — a rebuild loses
    /// everything the steps before it did), and `PAGER` is still `cat` (in a
    /// fresh shell the preamble sets that AFTER the rc, so a reader's own pager
    /// would otherwise win here and the next driven `git log` would wait
    /// forever on a pager nobody can see).
    ///
    /// This passes with or without the fix. It is a control: it says the reload
    /// does no harm on a real machine, where the guard above says it does the
    /// good.
    @Test func theShippedShellSurvivesTheRetryPathOnThisMacsOwnDotfiles() async throws {
        let scratchDirectory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug3-e2e-shipped-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: scratchDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: scratchDirectory) }

        let shippedShellSession = GuideAutopilotShellSession(startingDirectory: scratchDirectory)
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheseGuides(),
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shippedShellSession,
                    longRunningSession: Bug3UnusedLongRunningShell(),
                    fixProposer: Bug3LadderThatOnlyAsksTheReaderToDoItThemselves(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.autonomyGrant = try Self.autonomyGrantOfThisTestsOwn()
        controller.confirmAutonomousControl = { true }

        await controller.openGuide(
            slug: "iris-shell-continuity", requestedVersion: 1,
            branchKeyFromDeepLink: nil, stepIndexFromDeepLink: nil
        )
        try #require(controller.selectedBranch != nil, "the guide must open")

        controller.startAutopilot()
        let theStepWasSurfaced = await pump { controller.autopilotHandedTheCurrentStepToTheReader }
        #expect(theStepWasSurfaced, "the step that needs the reader must surface")

        // The reader does their part, in their own Finder or Terminal.
        try "ready".write(
            toFile: (scratchDirectory as NSString)
                .appendingPathComponent("ready-for-the-next-step.txt"),
            atomically: true, encoding: .utf8
        )
        controller.retryTheSurfacedStep()

        let theGuideFinished = await pump { controller.readerHasFinishedTheGuide }
        #expect(
            theGuideFinished,
            "the retry has to carry the guide to the end in the shipped shell, on this Mac's own dotfiles"
        )
        let markerTheShellStillHas = (try? String(
            contentsOfFile: (scratchDirectory as NSString)
                .appendingPathComponent("the-marker-the-shell-still-has.txt"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            markerTheShellStillHas == "still-the-same-shell",
            """
            what an earlier step exported has to survive the retry — got \
            \(markerTheShellStillHas ?? "nothing"). A session rebuilt instead of \
            refreshed would lose every `cd`, `nvm use` and `source …/cargo/env` \
            the steps before it did.
            """
        )
        let pagerTheShellStillUses = (try? String(
            contentsOfFile: (scratchDirectory as NSString)
                .appendingPathComponent("the-pager-the-shell-still-uses.txt"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            pagerTheShellStillUses == "cat",
            """
            the driver's pager settings have to survive too — got \
            \(pagerTheShellStillUses ?? "nothing"). Without them a driven \
            `git log` waits forever on a pager nobody can see.
            """
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
        await shippedShellSession.endSession()
    }
}
