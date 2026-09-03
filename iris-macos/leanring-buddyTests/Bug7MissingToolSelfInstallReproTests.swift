//
//  Bug7MissingToolSelfInstallReproTests.swift
//  leanring-buddyTests
//
//  Bug 7 — "Fix ladder can only give advice for a missing tool".
//
//  THE FIELD SCENARIO, from Akrit's Test 9 logs (Iris 0.9.6 build 22), replayed
//  here step for step:
//
//    06:59:44  [51270] login-shell PATH captured with -l -i: 16 directories
//    06:59:45  drive: step[6] id=install-deps kind=terminal exec=true
//    06:59:45  drive: executing install-deps…
//              shell: runCommand len=12  → exit 0    (`cd ~/kneecap`)
//              shell: runCommand len=11  → exit 127  (`bun install` — no bun)
//    …then 18.5 SECONDS OF SILENCE. Not one `shell: runCommand` line. Two model
//       calls, and the ladder never asked the shell to do anything at all…
//    07:00:04  drive: install-deps result=skippedByReader
//
//  `skippedByReader` for a step the reader never touched is the whole bug: the
//  ladder's only two exits for a missing tool are a model-proposed
//  `runACommand` — which `GuideAutopilotFixProposer.validatedFix` rejects
//  outright when it reaches a host the guide's own commands never name, and
//  bun's installer reaches `bun.sh` while kneecap only ever reaches github.com
//  and nodejs.org — and `askTheReaderToDoSomething`, which
//  `GuideAutopilotRunner.climbTheFixLadder` turns straight into a hand-back.
//  There is no third exit. Nothing in the ladder can install a tool, even one
//  `ToolVersionService` already knows how to check and that the guide ITSELF
//  installs three steps earlier (kneecap step 3, `npm install -g bun`, which
//  Test 9 skipped because the session resumed at step 6).
//
//  So Iris stopped on a step it had everything it needed to finish, and the
//  reader was left to install bun by hand — which is exactly what they then
//  did, in their own Terminal, from a chat answer they had to ask for
//  ("how to do:" → "you need to install bun … curl -fsSL https://bun.sh/install
//  | bash … then hit Try again"), at 07:01:51.
//
//  WHAT IS REAL HERE, and what is not:
//    - the real `GuideSessionController`, its real drive loop, the real
//      `GuideAutopilotRunner`, the real fix ladder, the real risk gate, and the
//      real autonomy grant (over a UserDefaults suite of the test's own);
//    - the real published kneecap guide's own steps, ids, working directories,
//      commands and `toolVersion` watches, served over a stubbed URLProtocol
//      instead of publik, and resumed at step 6 exactly as Test 9 did;
//    - the SHIPPED guardrail: the model's proposals are decoded and validated by
//      `GuideAutopilotFixProposer.validatedFix` itself, from the raw proposal
//      objects the tool call would carry, so the rejection this bug turns on is
//      produced by the shipped code rather than scripted by the test;
//    - in `Bug7MissingToolOnARealLoginShellTests`: a real pty running a real
//      `zsh -l -i` through the app's own `GuideAutopilotPseudoTerminal`, in a
//      real temporary HOME with a real minimal `.zshrc`, over a real git
//      checkout of kneecap's workspace shape — a machine that genuinely has no
//      bun, where the real shell answers the real 127.
//
//  Faked, and only this:
//    - the model. `Bug7TheLadderTest9Got` replays the two answers Test 9's
//      ladder came back with, as raw proposal objects, so no model is called
//      and nothing is spent;
//    - `npm`, inside the temporary home only. The real one would reach the
//      network and write into this developer's own global prefix; the stand-in
//      does what npm does — puts a `bun` on the PATH — and nothing else. `bun`
//      itself is a stand-in for the same reason bun is absent in the first
//      place: the point is that Iris never runs anything that would create it.
//
//  `theTemporaryMacIsOneCommandAwayFromWorking` is the control: it drives the
//  same real shell by hand and proves the fixture is honest — bun really is
//  missing, the guide's own install command really does fix it, and one PATH
//  reload really is all that stands between the 127 and a clean run. It passes
//  with or without a fix, so a failure in the two repro tests can only mean
//  Iris never tried, and never means a broken scratch machine.
//

import Foundation
import Testing
@testable import Iris

/// The same opt-out `GuideAutopilotShellSessionTests` and the Bug 3 suites use:
/// the second suite in this file spawns real login shells.
private let bug7PtyTestsAreEnabled =
    ProcessInfo.processInfo.environment["IRIS_SKIP_PTY_TESTS"] != "1"

// MARK: - The kneecap guide, served the way publik serves it

/// Answers `GET /api/iris/guides/kneecap` with the published Mac + iPhone
/// branch, fetched live on 2026-09-03 and reproduced field for field: the same
/// setup steps (whose `nodejs.org` href and `github.com` clone are the ENTIRE
/// set of hosts the guide reaches, and therefore the entire set a proposed fix
/// is allowed to reach), the same step ids, the same working directories, the
/// same commands, and the same `toolVersion` watches — including step 3's
/// `bun`, which is the guide telling Iris, in its own words, how bun is
/// installed for this app.
///
/// Two `visual` expectations are dropped: `install-bun`'s and `build-editor`'s.
/// A visual expectation puts the watch loop on the screen-capture-and-ask-a-
/// model path, and the test host has neither a screen recording permission nor
/// a model. Nothing in this bug depends on them.
final class Bug7KneecapGuideURLProtocol: URLProtocol {

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasPrefix("/api/iris/guides/") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestURL = request.url,
              let response = HTTPURLResponse(
                  url: requestURL, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.kneecapGuideJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
          "setupSteps": [
            {"id": "install-git", "kind": "terminal", "tool": "git", "title": "Install Git",
             "body": "Apple opens a small installer.", "command": "xcode-select --install",
             "verifierLabel": "Git responds with a version number"},
            {"id": "install-node", "kind": "open", "tool": "node", "title": "Install Node LTS",
             "body": "Choose the macOS Installer (.pkg).",
             "href": "https://nodejs.org/en/download", "actionLabel": "Open download",
             "verifierLabel": "Node responds with a version number"}
          ],
          "steps": [
            {"id": "open-shell", "kind": "terminal", "title": "Open Terminal",
             "body": "Keep it open beside Iris.", "verifierLabel": "Terminal is open"},
            {"id": "check-tools", "kind": "check", "title": "Check Git and Node",
             "body": "Git and the current Node LTS are required.",
             "command": "git --version\\nnode --version",
             "verifierLabel": "Git and Node respond with version numbers",
             "watch": {"expect": [{"type": "toolVersion", "tool": "git"},
                                  {"type": "toolVersion", "tool": "node"}]}},
            {"id": "install-bun", "kind": "terminal", "title": "Install Bun",
             "body": "kneecap's workspace is built with Bun. This installs it through npm.",
             "command": "npm install -g bun",
             "verifierLabel": "Bun responds with a version number",
             "watch": {"expect": [{"type": "toolVersion", "tool": "bun"}]}},
            {"id": "clone", "workingDirectory": "~", "kind": "terminal",
             "title": "Copy kneecap to this Mac", "body": "",
             "command": "cd ~\\nif [ ! -d kneecap/.git ]; then\\ngit clone https://github.com/Blueturboguy07/kneecap.git\\nfi",
             "verifierLabel": "A kneecap folder appears",
             "watch": {"expect": [{"type": "toolVersion", "tool": "git"}]}},
            {"id": "enter-folder", "workingDirectory": "~", "kind": "terminal",
             "title": "Open the kneecap folder", "body": "", "command": "cd kneecap",
             "verifierLabel": "Your terminal prompt is inside the kneecap folder"},
            {"id": "pin-source", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Use the reviewed version", "body": "",
             "command": "git checkout fc48ba487a1e0d0cd10b30d6600acd2895ffdbed",
             "verifierLabel": "Git reports the reviewed commit"},
            {"id": "install-deps", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Install the workspace",
             "body": "A few minutes the first time — it is a Rust and TypeScript monorepo.",
             "command": "bun install",
             "verifierLabel": "The command finishes without an error"},
            {"id": "build-editor", "workingDirectory": "~/kneecap", "kind": "terminal",
             "title": "Build the editor",
             "body": "Bundles the editor into apps/mobile/www.",
             "command": "cd apps/mobile\\nbun run build",
             "verifierLabel": "Vite reports the build finished"}
          ],
          "unsupported": null
        }
      ]
    }
    """
}

// MARK: - The ladder Test 9 got, decoded by the shipped guardrails

/// The two answers the model gave the ladder on `install-deps`, replayed as the
/// RAW proposal objects a `propose_fix` tool call carries, and turned into fixes
/// by the shipped `GuideAutopilotFixProposer.validatedFix` — so the host guard
/// that rejects bun's own installer is the shipped one doing the rejecting, not
/// this test asserting that it would.
///
/// Rung (a) is the fix the model actually wants to make: run bun's official
/// installer. It reaches `bun.sh`, which appears nowhere in kneecap's own
/// commands, so `validatedFix` converts it into `cannotFixThis` before the
/// runner ever sees a command. Rung (b), with web search, is what the reader
/// then saw: advice, and "Your turn".
@MainActor
final class Bug7TheLadderTest9Got: GuideAutopilotFixProposing {

    private(set) var timesAsked = 0
    /// What each rung ended up offering the runner, AFTER the shipped
    /// validation. The evidence for the bug's mechanism, printed into the
    /// failure message rather than asserted, because a fix is free to make the
    /// ladder unnecessary and this file must not pin its shape.
    private(set) var whatTheLadderCouldOffer: [String] = []

    /// The command the model wants to run, and the host it reaches (`bun.sh`) —
    /// kept here so the guardrail test and the ladder use one string.
    static let bunsOwnInstaller = "curl -fsSL https://bun.sh/install | bash"

    static let theInstallerProposalTheModelMakesFirst: [String: Any] = [
        "diagnosis": "bun isn't installed on this Mac, so `bun install` can't run.",
        "confidence": "high",
        "retryTheOriginalCommandAfterwards": true,
        "action": [
            "kind": "runACommand",
            "command": bunsOwnInstaller,
            "whatItDoes": "Installs bun with its official installer.",
        ],
    ]

    /// The shape of what the reader was left with: a sentence to act on.
    static let theAdviceTheReaderWasGiven =
        "Install bun by running: curl -fsSL https://bun.sh/install | bash, "
        + "then restart your terminal and tap Try again."

    static let theAdviceProposal: [String: Any] = [
        "diagnosis": "bun isn't installed, so the workspace install can't run.",
        "confidence": "high",
        "retryTheOriginalCommandAfterwards": false,
        "action": [
            "kind": "askTheReaderToDoSomething",
            "instruction": theAdviceTheReaderWasGiven,
        ],
    ]

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        timesAsked += 1
        return validated(Self.theInstallerProposalTheModelMakesFirst,
                         cameFromWebSearch: false, context: context)
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        timesAsked += 1
        return validated(Self.theAdviceProposal, cameFromWebSearch: true, context: context)
    }

    private func validated(
        _ proposal: [String: Any],
        cameFromWebSearch: Bool,
        context: GuideAutopilotFailureContext
    ) -> GuideAutopilotProposedFix? {
        let fix = GuideAutopilotFixProposer.validatedFix(
            fromProposalObject: proposal,
            cameFromWebSearch: cameFromWebSearch,
            context: context
        )
        whatTheLadderCouldOffer.append(Self.describe(fix?.action))
        return fix
    }

    private static func describe(_ action: GuideAutopilotProposedFixAction?) -> String {
        switch action {
        case .runACommand(let command, _): return "runACommand(\(command))"
        case .askTheReaderToDoSomething(let instruction): return "advice(\(instruction))"
        case .cannotFixThis(let reason): return "cannotFixThis(\(reason))"
        case nil: return "no fix at all"
        }
    }
}

/// The runner's second session, for dev-server steps. Nothing in kneecap's
/// branch holds the shell open, so it is only ever asked to shut down.
@MainActor
final class Bug7UnusedLongRunningShell: GuideAutopilotShellSessionDriving {
    var onOutputLine: ((String) -> Void)?
    var currentWorkingDirectory = "/"
    var resolvedSearchPath: String?
    func start() async -> Bool { true }
    func run(
        _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        .succeeded(workingDirectory: currentWorkingDirectory)
    }
    func cancelTheRunningCommand() async {}
    func endSession() async {}
    func tailForTheModel() -> String { "" }
}

// MARK: - The reader's Mac at 06:59, modelled

/// Akrit's machine as the shell saw it: git and node are there, bun is not, and
/// nothing changes that except a command that actually installs bun — the
/// guide's own `npm install -g bun`, or bun's official installer.
///
/// It answers 127 for a bun command the way zsh does, and it deliberately does
/// NOT gain bun from a PATH reload: Bug 3's cure (re-source the reader's
/// dotfiles) cannot conjure a tool that is not on the disk, which is precisely
/// what separates this bug from that one.
@MainActor
final class Bug7MacWithoutBun: GuideAutopilotShellSessionDriving {

    var onOutputLine: ((String) -> Void)?
    var currentWorkingDirectory = "/Users/reader"
    var resolvedSearchPath: String? = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Every command this shell was asked to run, with the status it gave back.
    private(set) var attempts: [(command: String, exitStatus: Int32)] = []
    private(set) var bunIsInstalled = false
    private var tail = ""

    func start() async -> Bool { true }
    func cancelTheRunningCommand() async {}
    func endSession() async {}
    func tailForTheModel() -> String { tail }

    func run(
        _ command: GuideAutopilotApprovedCommand,
        deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        let text = command.text
        if Self.installsBun(text) {
            bunIsInstalled = true
            note("added 1 package in 3s")
        }
        if Self.needsBun(text), !bunIsInstalled {
            note("zsh: command not found: bun")
            attempts.append((command: text, exitStatus: 127))
            return .failed(exitStatus: 127, workingDirectory: currentWorkingDirectory)
        }
        attempts.append((command: text, exitStatus: 0))
        return .succeeded(workingDirectory: currentWorkingDirectory)
    }

    /// Exit statuses for one command's text, in the order they happened.
    func exitStatuses(of commandText: String) -> [Int32] {
        attempts.filter { $0.command == commandText }.map(\.exitStatus)
    }

    /// Anything Iris ran that would put a bun on this machine.
    var commandsThatWouldHaveInstalledBun: [String] {
        attempts.map(\.command).filter { Self.installsBun($0) }
    }

    /// Every command Iris ran, for a failure message that shows what it did
    /// instead of installing the tool.
    var everythingIrisRan: [String] { attempts.map(\.command) }

    private func note(_ line: String) {
        tail += line + "\n"
        onOutputLine?(line)
    }

    /// A command needs bun when one of its lines starts with `bun` — the shape
    /// every kneecap bun step has (`bun install`, `bun run build`).
    private static func needsBun(_ command: String) -> Bool {
        command.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("bun ")
        }
    }

    /// The two routes to a bun on this machine: the guide's own step 3, and
    /// bun's official installer.
    private static func installsBun(_ command: String) -> Bool {
        command.contains("install -g bun")
            || command.contains("bun.sh/install")
            || command.contains("bun.com/install")
    }
}

// MARK: - The fast reproduction

@MainActor
@Suite(.serialized)
struct Bug7MissingToolSelfInstallReproTests {

    private static func guideServiceServingTheKneecapGuide() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Bug7KneecapGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug7.repro.\(UUID().uuidString)")
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
                UserDefaults(suiteName: "iris.bug7.grant.\(UUID().uuidString)")
            )
        )
    }

    /// Polls a main-actor condition. The drive loop runs in a `Task` it does not
    /// hand back, so a test observes its effects.
    private func pump(
        within seconds: Double = 30,
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

    // MARK: The program a chained line runs

    /// Test 9's build-editor step is `cd apps/mobile && bun run build` on one
    /// line — the second command that died with exit 127 in the log. The
    /// self-install only helps if the tool it looks up is `bun`, not the `cd`
    /// in front of it; and a `sudo` or an env assignment in front of a program
    /// is not the program either.
    @Test func theToolAChainedLineNeedsIsTheOneAfterTheCd() {
        #expect(GuideAutopilotCommandShape.programsEachLineWouldRun(
            "cd apps/mobile && bun run build") == ["cd", "bun"])
        #expect(GuideAutopilotCommandShape.programsEachLineWouldRun(
            "(cd ui && pnpm build) && cargo build --release") == ["cd", "pnpm", "cargo"])
        #expect(GuideAutopilotCommandShape.programsEachLineWouldRun(
            "sudo bun install; FOO=bar node index.js") == ["bun", "node"])
        #expect(GuideAutopilotCommandShape.programsEachLineWouldRun(
            "cd apps/mobile\nbun run build") == ["cd", "bun"])
    }

    // MARK: The bug

    /// Test 9's install-deps, driven by the real controller and the real ladder
    /// against a machine that has no bun.
    ///
    /// On the unfixed code the ladder's rung (a) asks for bun's official
    /// installer and the host guard turns it into `cannotFixThis`; rung (b)
    /// hands the reader a sentence; the step comes back `skippedByReader` and
    /// the install stops on step 6 — with `npm install -g bun` sitting in the
    /// guide three steps above, unread.
    @Test func irisStopsOnAMissingToolItsOwnGuideKnowsHowToInstall() async throws {
        let machine = Bug7MacWithoutBun()
        let ladder = Bug7TheLadderTest9Got()
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheKneecapGuide(),
            // Git and Node were both on the reader's Mac, so the setup detour
            // never fires. Bun is the one thing missing, and the SHELL is what
            // discovers that — exactly as it did in the field, where the guide
            // had already walked past its own bun step.
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: machine,
                    longRunningSession: Bug7UnusedLongRunningShell(),
                    fixProposer: ladder,
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.autonomyGrant = try Self.autonomyGrantOfThisTestsOwn()
        controller.confirmAutonomousControl = { true }

        // Test 9 resumed the guide at step 6 — install-deps — which is why the
        // guide's own "Install Bun" step (index 2) was never run.
        await controller.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:ios", stepIndexFromDeepLink: 6
        )
        try #require(controller.selectedBranch != nil, "the kneecap guide must open")
        try #require(controller.currentStepIndex == 6, "the run resumes on install-deps")

        controller.startAutopilot()

        // 06:59:45 — `cd ~/kneecap` exit 0, `bun install` exit 127.
        let theLadderIsDone = await pump {
            controller.autopilotHandedTheCurrentStepToTheReader || controller.currentStepIndex > 6
        }
        try #require(theLadderIsDone, "the ladder must reach a verdict on install-deps")
        #expect(
            machine.exitStatuses(of: "bun install").first == 127,
            "the field's first attempt is exit 127 — got \(machine.exitStatuses(of: "bun install"))"
        )

        // THE BUG. Everything below is what Iris had and did not use: the tool
        // is one `ToolVersionService` already knows (`bun`), and the guide it is
        // running installs it in its own step 3.
        #expect(
            !machine.commandsThatWouldHaveInstalledBun.isEmpty,
            """
            THE BUG: `bun install` exited 127 because bun is missing, and Iris \
            never ran anything that would install it. The ladder's whole offer \
            was \(ladder.whatTheLadderCouldOffer) — a host-guard refusal, then a \
            sentence for the reader to act on — across \(ladder.timesAsked) model \
            call(s). The guide Iris is running installs bun itself, three steps \
            up: `npm install -g bun` (step id install-bun, watch toolVersion bun). \
            Commands Iris actually ran: \(machine.everythingIrisRan)
            """
        )
        #expect(
            machine.exitStatuses(of: "bun install").last == 0,
            """
            THE BUG, at the step: after the ladder had finished, `bun install` \
            still exits \(machine.exitStatuses(of: "bun install")) — nothing \
            about the machine changed between the first attempt and the last.
            """
        )
        #expect(
            !controller.autopilotHandedTheCurrentStepToTheReader,
            """
            THE SYMPTOM AS REPORTED: the step was handed back with "Your turn" \
            and the reader had to install bun themselves. The ladder's last word \
            on it was: \(ladder.whatTheLadderCouldOffer.last ?? "nothing")
            """
        )
        #expect(
            controller.currentStepIndex > 6,
            """
            THE CONSEQUENCE: a 17-step install stops dead on step 6 for a \
            prerequisite Iris knows the name of, knows how to check, and has a \
            published command for. It is still on step \(controller.currentStepIndex).
            """
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
    }

    // MARK: Why the model route cannot be the answer

    /// The other half of the root cause, in the shipped code that decides it:
    /// the ONE command that would fix this step is the one thing a model-
    /// proposed fix may never be, because bun's installer reaches a host
    /// kneecap's own commands never name.
    ///
    /// This passes before and after a fix, and it is here to stay that way: the
    /// host guard is the structural answer to an invented hostname, and a fix
    /// for Bug 7 that widens it — adding bun.sh to a model-visible allowlist,
    /// or relaxing `hosts.isSubset(of:)` — would trade a stopped install for a
    /// model that can reach anywhere it can justify. The fix belongs on a
    /// deterministic path that no model proposes into.
    @Test func theOneFixTheModelWantsIsTheOneTheHostGuardMustRefuse() {
        let hostsKneecapReaches: Set<String> = ["github.com", "nodejs.org"]
        let context = Self.failureContextForInstallDeps(hosts: hostsKneecapReaches)

        let rejected = GuideAutopilotFixProposer.validatedFix(
            fromProposalObject: Bug7TheLadderTest9Got.theInstallerProposalTheModelMakesFirst,
            cameFromWebSearch: false,
            context: context
        )
        guard case .cannotFixThis(let reason) = rejected?.action else {
            Issue.record("bun's own installer must be refused, got \(String(describing: rejected?.action))")
            return
        }
        #expect(reason.contains("bun.sh"), "and the refusal names the host: \(reason)")

        // And the reason it is refused is not that the command is unsafe — it is
        // that the guide never names `bun.sh`. The guide's OWN install command
        // names no host at all, which is the shape a deterministic recovery
        // could run without touching this guard.
        #expect(
            GuideAutopilotCommandShape.hostsTheCommandWouldReach("npm install -g bun").isEmpty,
            "the guide's own bun step reaches no host, so no allowlist stands in its way"
        )
        #expect(
            GuideAutopilotCommandShape.hostsTheCommandWouldReach(
                Bug7TheLadderTest9Got.bunsOwnInstaller
            ) == ["bun.sh"],
            "while the model's proposal reaches exactly the host the guide does not"
        )
        // `bun` is not an unknown name to Iris: the service that answers
        // "is it installed?" has known it all along.
        #expect(
            ToolVersionService.toolSpecification(for: "bun")?.executableName == "bun",
            "bun is a tool Iris already knows how to check for"
        )
    }

    /// The failure context Test 9's ladder was given, built by hand so the
    /// guardrail test does not need a shell.
    private static func failureContextForInstallDeps(
        hosts: Set<String>
    ) -> GuideAutopilotFailureContext {
        GuideAutopilotFailureContext(
            guideSlug: "kneecap", guideVersion: 2, appName: "kneecap",
            platformLabel: "Mac + iPhone",
            stepIdentifier: "install-deps", stepTitle: "Install the workspace",
            stepBody: "A few minutes the first time.",
            verifierLabel: "The command finishes without an error",
            commandAsRun: "bun install", exitStatus: 127,
            scrubbedOutputTail: "zsh: command not found: bun",
            shellPath: "/bin/zsh", workingDirectory: "/Users/reader/kneecap",
            operatingSystemVersion: "Version 15.6", architecture: "arm64",
            knownToolVersions: ["git 2.39.5", "node v22.14.0"],
            priorAttempts: [],
            hostsTheGuideAlreadyReaches: hosts
        )
    }
}

// MARK: - A real login shell, in a home directory the test owns

/// A stand-in for `GuideAutopilotShellSession` that takes the reader's home as a
/// parameter. Everything else is copied from it deliberately: the same
/// `zsh -l -i` through the same `GuideAutopilotPseudoTerminal`, the same
/// generated ZDOTDIR, the same PATH-less child environment, the same preamble
/// whose ready marker carries `$PATH` as its third field, and the same in-band
/// sentinel protocol.
///
/// The shipped class reads the reader's home from
/// `FileManager.default.homeDirectoryForCurrentUser` in two non-injectable
/// places (`privateZdotdir`'s cached rc and `childEnvironment`), so there is no
/// seam to point it at a scratch home — and a test must never install anything
/// into the developer's own home or PATH.
@MainActor
final class Bug7LoginShellInATemporaryReaderHome: GuideAutopilotShellSessionDriving {

    var onOutputLine: ((String) -> Void)?

    var currentWorkingDirectory: String { state.snapshotWorkingDirectory() }
    var resolvedSearchPath: String? { state.snapshotSearchPath() }

    /// Every command this shell was asked to run, with the exit status the real
    /// shell gave it.
    private(set) var attempts: [(command: String, exitStatus: Int32)] = []

    private let state: State

    init(readerHome: String, startingDirectory: String) {
        state = State(readerHome: readerHome, startingDirectory: startingDirectory)
        state.deliverOutputLine = { [weak self] line in
            Task { @MainActor [weak self] in self?.onOutputLine?(line) }
        }
    }

    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            state.enqueueStart { continuation.resume(returning: $0) }
        }
    }

    func run(
        _ command: GuideAutopilotApprovedCommand,
        deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        let outcome: GuideAutopilotCommandOutcome = await withCheckedContinuation { continuation in
            state.enqueueRun(command.text, deadline: deadline) { continuation.resume(returning: $0) }
        }
        switch outcome {
        case .succeeded:
            attempts.append((command: command.text, exitStatus: 0))
        case .failed(let exitStatus, _):
            attempts.append((command: command.text, exitStatus: exitStatus))
        default:
            // -1 stands for "the shell never gave a status" (timed out, died,
            // was cancelled) so a wedge is visibly different from a real 127.
            attempts.append((command: command.text, exitStatus: -1))
        }
        return outcome
    }

    func cancelTheRunningCommand() async {}

    func endSession() async {
        await withCheckedContinuation { continuation in
            state.enqueueEnd { continuation.resume() }
        }
    }

    func tailForTheModel() -> String { state.snapshotTail() }

    /// Exit statuses for one command's text, in the order they happened.
    func exitStatuses(of commandText: String) -> [Int32] {
        attempts.filter { $0.command == commandText }.map(\.exitStatus)
    }

    /// Every command Iris ran, for a failure message that shows what it did
    /// instead of installing the tool.
    var everythingIrisRan: [String] { attempts.map(\.command) }

    // MARK: The queue-confined core (mirrors `GuideAutopilotShellSession.SessionState`)

    private final class State: @unchecked Sendable {

        var deliverOutputLine: ((String) -> Void)?

        private let queue = DispatchQueue(label: "iris.bug7.repro.shell-session")
        private let readerHome: String
        private let startingDirectory: String

        private var terminal: GuideAutopilotPseudoTerminal?
        private var workingDirectory: String
        private var searchPath: String?
        private var shellHasExited = false
        private var markerToken: String?
        private var finishRunning: ((GuideAutopilotCommandOutcome) -> Void)?
        private var markerScanText = ""
        private var lineBuffer = ""
        private var tail = ""
        private var displayIsSuppressedUntilShellIsReady = true

        init(readerHome: String, startingDirectory: String) {
            self.readerHome = readerHome
            self.startingDirectory = startingDirectory
            self.workingDirectory = startingDirectory
        }

        func enqueueStart(_ completion: @escaping @Sendable (Bool) -> Void) {
            queue.async { self.startShell(completion) }
        }

        func enqueueRun(
            _ commandText: String,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            queue.async { self.runCommand(commandText, deadline: deadline, completion) }
        }

        func enqueueEnd(_ completion: @escaping @Sendable () -> Void) {
            queue.async { self.endShell(completion) }
        }

        func snapshotWorkingDirectory() -> String { queue.sync { workingDirectory } }
        func snapshotSearchPath() -> String? { queue.sync { searchPath } }
        func snapshotTail() -> String { queue.sync { String(tail.suffix(4_000)) } }

        private func startShell(_ completion: @escaping @Sendable (Bool) -> Void) {
            let terminal = GuideAutopilotPseudoTerminal()
            terminal.onOutput = { [weak self] bytes in
                self?.queue.async { self?.ingest(bytes) }
            }
            terminal.onProcessExit = { [weak self] _ in
                self?.queue.async { self?.noteShellExited() }
            }

            // The shipped `childEnvironment()`, with the home directory taken
            // from the caller instead of `FileManager.default`. PATH is
            // deliberately absent so the login shell rebuilds it through
            // path_helper and the (temporary) reader's own dotfiles.
            let user = NSUserName()
            var environment: [String: String] = [
                "HOME": readerHome,
                "USER": user,
                "LOGNAME": user,
                "SHELL": GuideAutopilotShellSession.loginShellPath(),
                "TMPDIR": NSTemporaryDirectory(),
                "TERM": "xterm-256color",
                "LANG": "en_US.UTF-8",
                "IRIS_AUTOPILOT": "1",
            ]
            if let zdotdir = GuideAutopilotShellSession.privateZdotdir() {
                environment["ZDOTDIR"] = zdotdir
                // The generated rc reads this with `${IRIS_USER_HOME:-<real home>}`,
                // so pointing it at the scratch home is what keeps this test off
                // the developer's own dotfiles.
                environment["IRIS_USER_HOME"] = readerHome
            }

            do {
                try terminal.spawn(
                    shellPath: GuideAutopilotShellSession.loginShellPath(),
                    arguments: ["-l", "-i"],
                    environment: environment
                )
            } catch {
                completion(false)
                return
            }
            self.terminal = terminal
            shellHasExited = false
            displayIsSuppressedUntilShellIsReady = true
            markerScanText = ""
            lineBuffer = ""

            let readyToken = Self.freshToken()
            markerToken = readyToken
            finishRunning = { outcome in
                if case .succeeded = outcome { completion(true) } else { completion(false) }
            }
            scheduleDeadline(seconds: 60, forToken: readyToken)
            // The shipped preamble, verbatim: the third `%s` is `$PATH`.
            terminal.write(
                "export PAGER=cat GIT_PAGER=cat LESS=-FRX GIT_TERMINAL_PROMPT=0\n"
                + "cd \(Self.shellQuoted(startingDirectory))\n"
                + "printf '\\n__IRIS_END_\(readyToken)__ %d\\t%s\\t%s\\n' \"$?\" \"$PWD\" \"$PATH\"\n"
            )
        }

        private func runCommand(
            _ commandText: String,
            deadline: TimeInterval,
            _ completion: @escaping @Sendable (GuideAutopilotCommandOutcome) -> Void
        ) {
            guard let terminal, !shellHasExited else {
                completion(.sessionFailed)
                return
            }
            guard finishRunning == nil else {
                completion(.sessionFailed)
                return
            }
            let token = Self.freshToken()
            markerToken = token
            markerScanText = ""
            lineBuffer = ""
            finishRunning = completion
            terminal.write(
                commandText
                + "\nprintf '\\n__IRIS_END_\(token)__ %d\\t%s\\n' \"$?\" \"$PWD\"\n"
            )
            // Capped well below the shipped 900s command deadline: a test that
            // wedges must FAIL, not sit there for a quarter of an hour.
            scheduleDeadline(seconds: min(deadline, 90), forToken: token)
        }

        private func ingest(_ bytes: [UInt8]) {
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\r", with: "")
            markerScanText += text
            if markerScanText.count > 65_536 {
                markerScanText = String(markerScanText.suffix(32_768))
            }
            lineBuffer += text
            while let newline = lineBuffer.firstIndex(of: "\n") {
                let line = String(lineBuffer[..<newline])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                guard !displayIsSuppressedUntilShellIsReady else { continue }
                let visible: String
                if let markerStart = line.range(of: "__IRIS_END_") {
                    visible = String(line[..<markerStart.lowerBound])
                } else {
                    visible = line
                }
                guard !visible.isEmpty else { continue }
                tail += visible + "\n"
                if tail.count > 16_384 { tail = String(tail.suffix(8_192)) }
                deliverOutputLine?(visible)
            }
            scanForMarker()
        }

        /// The shipped scan: the token appears in the echoed `printf` too, so
        /// only an occurrence followed by a real status digit on a line that has
        /// fully arrived counts.
        private func scanForMarker() {
            guard let token = markerToken else { return }
            let markerNeedle = "__IRIS_END_\(token)__ "
            var searchStart = markerScanText.startIndex
            while let range = markerScanText.range(
                of: markerNeedle, range: searchStart..<markerScanText.endIndex
            ) {
                let afterMarker = markerScanText[range.upperBound...]
                if afterMarker.first.map({ $0.isNumber || $0 == "-" }) == true,
                   let newline = afterMarker.firstIndex(of: "\n") {
                    finishRun(withMarkerLine: String(afterMarker[..<newline]))
                    return
                }
                searchStart = range.upperBound
            }
        }

        private func finishRun(withMarkerLine markerLine: String) {
            markerToken = nil
            let fields = markerLine.split(separator: "\t", maxSplits: 2)
            let exitStatus = fields.first.flatMap { Int32($0) } ?? -1
            if fields.count > 1 { workingDirectory = String(fields[1]) }
            if fields.count > 2 { searchPath = String(fields[2]) }
            if displayIsSuppressedUntilShellIsReady {
                displayIsSuppressedUntilShellIsReady = false
                lineBuffer = ""
            }
            let completion = finishRunning
            finishRunning = nil
            if exitStatus == 0 {
                completion?(.succeeded(workingDirectory: workingDirectory))
            } else {
                completion?(.failed(exitStatus: exitStatus, workingDirectory: workingDirectory))
            }
        }

        private func noteShellExited() {
            shellHasExited = true
            markerToken = nil
            let completion = finishRunning
            finishRunning = nil
            completion?(.sessionFailed)
        }

        private func scheduleDeadline(seconds: TimeInterval, forToken token: String) {
            queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, self.markerToken == token, let completion = self.finishRunning else {
                    return
                }
                self.finishRunning = nil
                self.markerToken = nil
                completion(.timedOut)
            }
        }

        private func endShell(_ completion: @escaping @Sendable () -> Void) {
            if let finish = finishRunning {
                finishRunning = nil
                markerToken = nil
                finish(.cancelled)
            }
            terminal?.onOutput = nil
            terminal?.onProcessExit = nil
            terminal?.write("exit\n")
            let terminalToClose = terminal
            terminal = nil
            shellHasExited = true
            queue.asyncAfter(deadline: .now() + 0.3) {
                terminalToClose?.killProcessGroup()
                completion()
            }
        }

        private static func freshToken() -> String {
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        private static func shellQuoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

// MARK: - The reader's Mac at 06:59, for real, in a temporary home

/// Builds the machine Test 9 ran on, in a scratch directory: a home whose
/// `.zshrc` puts `~/.local/bin` first on PATH, a real git checkout of kneecap's
/// workspace shape at `~/kneecap`, and an `npm` that installs bun the way npm
/// does — into a directory already on the PATH.
///
/// No bun anywhere. That is the fixture's whole point: unlike Bug 3, no amount
/// of re-reading the reader's dotfiles can find a tool that is not on the disk.
/// Something has to actually install it.
enum Bug7ReaderMacFixture {

    /// A temporary HOME with `.zshrc`, `~/.local/bin/npm`, and a real
    /// `~/kneecap` git repo.
    static func makeTemporaryReaderMacWithNoBun() throws -> String {
        let home = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("iris-bug7-reader-\(UUID().uuidString)")
        let localBin = (home as NSString).appendingPathComponent(".local/bin")
        let npmPayload = (home as NSString).appendingPathComponent(".npm-payload")
        let checkout = (home as NSString).appendingPathComponent("kneecap")
        let mobile = (checkout as NSString).appendingPathComponent("apps/mobile")
        for directory in [localBin, npmPayload, mobile] {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true
            )
        }

        // The reader's shell before anything is installed. `~/.local/bin` comes
        // FIRST so the stand-in npm below wins over whatever npm this developer
        // has on their own machine — nothing here may touch a real global
        // prefix or the network.
        try """
        # The reader's own zsh setup, before Iris ran anything.
        export PATH="$HOME/.local/bin:$PATH"
        export IRIS_BUG7_READER_SHELL=1
        """.write(
            toFile: (home as NSString).appendingPathComponent(".zshrc"),
            atomically: true, encoding: .utf8
        )

        // The bun the guide's own step would install. Stands in for bun 1.4.0 —
        // the version the field Mac ended up with — and does real work:
        // `install` writes the bun.lock Test 9 later found in the checkout, and
        // `run build` writes the page the build step exists to produce.
        try """
        #!/bin/sh
        case "$1" in
          --version|-v) echo "1.4.0" ;;
          install)
            echo "bun install v1.4.0"
            : > bun.lock
            echo "12 packages installed [8.00ms]"
            ;;
          run)
            mkdir -p www
            printf '<!doctype html><title>kneecap editor</title>' > www/index.html
            echo "vite v5.4.0 building for production..."
            echo "built in 1.20s"
            ;;
          *)
            echo "bun: unknown command: $1" >&2
            exit 1
            ;;
        esac
        exit 0
        """.write(
            toFile: (npmPayload as NSString).appendingPathComponent("bun"),
            atomically: true, encoding: .utf8
        )

        // npm, only as far as this guide uses it: `npm install -g bun` puts a
        // bun on the PATH. The real npm would download it — a guard test must
        // not need the network, and must not write into the developer's own
        // global prefix.
        try """
        #!/bin/sh
        if [ "$1" = "install" ] && [ "$2" = "-g" ] && [ "$3" = "bun" ]; then
          cp "$HOME/.npm-payload/bun" "$HOME/.local/bin/bun"
          chmod +x "$HOME/.local/bin/bun"
          echo "added 1 package in 3s"
          exit 0
        fi
        echo "npm: this stand-in only knows 'npm install -g bun'" >&2
        exit 1
        """.write(
            toFile: (localBin as NSString).appendingPathComponent("npm"),
            atomically: true, encoding: .utf8
        )
        for executable in [
            (npmPayload as NSString).appendingPathComponent("bun"),
            (localBin as NSString).appendingPathComponent("npm"),
        ] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable
            )
        }

        // kneecap's own workspace shape, in a REAL git repo, because the field
        // checkout was one and the guide's steps run inside it.
        try #"{"name":"kneecap","private":true,"workspaces":["apps/*"]}"#.write(
            toFile: (checkout as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        try #"{"name":"@kneecap/mobile","scripts":{"build":"vite build"}}"#.write(
            toFile: (mobile as NSString).appendingPathComponent("package.json"),
            atomically: true, encoding: .utf8
        )
        let gitEnvironment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        runProcess("/usr/bin/git", ["init", "-q"], inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["config", "user.email", "reader@example.invalid"],
                   inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["config", "user.name", "Reader"],
                   inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["add", "-A"], inDirectory: checkout, environment: gitEnvironment)
        runProcess("/usr/bin/git", ["commit", "-q", "-m", "kneecap"],
                   inDirectory: checkout, environment: gitEnvironment)
        return home
    }

    /// Where the guide's own install step would put bun on this machine.
    static func bunOnThePath(inHome home: String) -> String {
        (home as NSString).appendingPathComponent(".local/bin/bun")
    }

    /// The lockfile `bun install` writes when it really runs — the one file
    /// Test 9 found dirty in the checkout afterwards.
    static func workspaceLockfile(inHome home: String) -> String {
        (home as NSString).appendingPathComponent("kneecap/bun.lock")
    }

    /// The page `bun run build` writes when it really runs.
    static func builtEditorPage(inHome home: String) -> String {
        (home as NSString).appendingPathComponent("kneecap/apps/mobile/www/index.html")
    }

    private static func runProcess(
        _ launchPath: String,
        _ arguments: [String],
        inDirectory directory: String,
        environment: [String: String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

// MARK: - The same journey, on a real login shell

@MainActor
@Suite(.enabled(if: bug7PtyTestsAreEnabled), .serialized)
struct Bug7MissingToolOnARealLoginShellTests {

    private static func guideServiceServingTheKneecapGuide() throws -> GuideService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Bug7KneecapGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.bug7.pty.\(UUID().uuidString)")
        )
        return GuideService(
            apiBase: GuideService.defaultAPIBase,
            urlSession: URLSession(configuration: configuration),
            userDefaults: defaults
        )
    }

    private static func autonomyGrantOfThisTestsOwn() throws -> AutopilotAutonomyGrant {
        AutopilotAutonomyGrant(
            userDefaults: try #require(
                UserDefaults(suiteName: "iris.bug7.pty.grant.\(UUID().uuidString)")
            )
        )
    }

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

    private func approved(_ command: String) throws -> GuideAutopilotApprovedCommand {
        try #require(GuideAutopilotRiskAssessment.approve(command))
    }

    // MARK: The bug, on a real machine

    /// Test 9 again, with nothing between the drive loop and the disk faked: a
    /// real `zsh -l -i` in a real home with no bun, a real git checkout, the
    /// real risk gate, and the guide's own `npm install -g bun` sitting three
    /// steps above the one that fails.
    ///
    /// On the unfixed code the shell answers a real 127, the ladder spends two
    /// model calls producing a refusal and a sentence, and the install stops —
    /// with no bun on the machine, no lockfile in the checkout, and the reader
    /// holding the bag.
    @Test func theInstallStopsDeadOnAMissingToolWithTheCureInItsOwnGuide() async throws {
        let readerHome = try Bug7ReaderMacFixture.makeTemporaryReaderMacWithNoBun()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        // The ZDOTDIR trick — and therefore the reader's whole environment —
        // only applies when the login shell is zsh, as it is on every shipped Mac.
        try #require(
            GuideAutopilotShellSession.privateZdotdir() != nil,
            "this reproduction needs the zsh login shell the autopilot drives"
        )

        let shell = Bug7LoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        let ladder = Bug7TheLadderTest9Got()
        let controller = GuideSessionController(
            guideService: try Self.guideServiceServingTheKneecapGuide(),
            checkToolVersion: { toolName in
                ToolVersion(tool: toolName, available: true, version: "\(toolName) version 1.2.3")
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: Bug7UnusedLongRunningShell(),
                    fixProposer: ladder,
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        controller.autonomyGrant = try Self.autonomyGrantOfThisTestsOwn()
        controller.confirmAutonomousControl = { true }

        await controller.openGuide(
            slug: "kneecap", requestedVersion: 2,
            branchKeyFromDeepLink: "macos:ios", stepIndexFromDeepLink: 6
        )
        try #require(controller.selectedBranch != nil, "the kneecap guide must open")
        try #require(controller.currentStepIndex == 6, "the run resumes on install-deps")

        controller.startAutopilot()

        let theLadderIsDone = await pump {
            controller.autopilotHandedTheCurrentStepToTheReader || controller.currentStepIndex > 6
        }
        try #require(
            theLadderIsDone,
            "the ladder must reach a verdict on install-deps; terminal tail: \(shell.tailForTheModel())"
        )
        #expect(
            shell.exitStatuses(of: "bun install").first == 127,
            """
            the real shell must answer the field's 127 — got \
            \(shell.exitStatuses(of: "bun install")); it searches \
            \(shell.resolvedSearchPath ?? "nothing"); terminal tail: \
            \(shell.tailForTheModel())
            """
        )

        #expect(
            FileManager.default.isExecutableFile(
                atPath: Bug7ReaderMacFixture.bunOnThePath(inHome: readerHome)
            ),
            """
            THE BUG, on a real machine: bun is still not installed. Iris ran \
            \(shell.everythingIrisRan) and the ladder's entire offer was \
            \(ladder.whatTheLadderCouldOffer). The command that would have \
            installed it — `npm install -g bun` — is step 3 of the guide Iris is \
            running, and npm is right there on the PATH.
            """
        )
        #expect(
            shell.exitStatuses(of: "bun install").last == 0,
            """
            THE BUG, at the step: `bun install` still exits \
            \(shell.exitStatuses(of: "bun install")) in the real shell.
            """
        )
        #expect(
            FileManager.default.fileExists(
                atPath: Bug7ReaderMacFixture.workspaceLockfile(inHome: readerHome)
            ),
            "and so the workspace was never installed — there is no bun.lock in the checkout"
        )
        #expect(
            !controller.autopilotHandedTheCurrentStepToTheReader,
            """
            THE SYMPTOM AS REPORTED: "Your turn". The reader had to go and run \
            bun's installer in their own Terminal, which is what they did at \
            07:01:51 after asking Iris "how to do:".
            """
        )
        #expect(
            controller.currentStepIndex > 6,
            "THE CONSEQUENCE: the install is still on step \(controller.currentStepIndex)"
        )
        // The step after it is the one Test 9 also died on, for the same reason.
        // The pump above returns the moment install-deps ADVANCES, and build-editor
        // starts running in that same instant on a real pty, so its result has to
        // be waited for rather than read off the disk microseconds later.
        _ = await pump {
            FileManager.default.fileExists(
                atPath: Bug7ReaderMacFixture.builtEditorPage(inHome: readerHome)
            )
        }
        #expect(
            (try? String(
                contentsOfFile: Bug7ReaderMacFixture.builtEditorPage(inHome: readerHome),
                encoding: .utf8
            ))?.contains("kneecap editor") == true,
            "and the build step that follows it never ran either"
        )

        controller.stopAutopilot()
        _ = await pump(within: 5) { controller.autopilotRunner == nil }
        await shell.endSession()
    }

    // MARK: The control

    /// The fixture, driven by hand at the shell level, to prove it is honest:
    /// bun really is missing from this temporary Mac, the guide's own install
    /// command really does install it with no network, one PATH reload really
    /// is what makes the running shell see it, and `bun install` then really
    /// works — writing a real lockfile into a real git checkout.
    ///
    /// This passes with or without a fix. It exists so a failure above can only
    /// mean Iris never tried any of it.
    @Test func theTemporaryMacIsOneCommandAwayFromWorking() async throws {
        let readerHome = try Bug7ReaderMacFixture.makeTemporaryReaderMacWithNoBun()
        defer { try? FileManager.default.removeItem(atPath: readerHome) }
        try #require(GuideAutopilotShellSession.privateZdotdir() != nil)

        let shell = Bug7LoginShellInATemporaryReaderHome(
            readerHome: readerHome, startingDirectory: readerHome
        )
        try #require(await shell.start(), "the login shell must come up")
        _ = await shell.run(try approved("cd ~/kneecap"), deadline: 30)

        let withoutBun = await shell.run(try approved("bun install"), deadline: 60)
        #expect(
            withoutBun == .failed(
                exitStatus: 127, workingDirectory: shell.currentWorkingDirectory
            ),
            "bun is missing, so the real shell answers 127: got \(withoutBun)"
        )

        // The guide's own step 3, run in the same shell Iris drives.
        let installingBun = await shell.run(try approved("npm install -g bun"), deadline: 60)
        #expect(
            installingBun == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            "the guide's own install command works on this machine: got \(installingBun)"
        )
        #expect(
            FileManager.default.isExecutableFile(
                atPath: Bug7ReaderMacFixture.bunOnThePath(inHome: readerHome)
            ),
            "and it really put a bun on the PATH"
        )

        // The reload the retry path already has: `hash -r` is what makes a shell
        // that has already looked for bun and failed look again.
        _ = await shell.run(
            try approved(GuideAutopilotShellSession.reloadTheReadersEnvironmentCommand),
            deadline: 60
        )

        let withBun = await shell.run(try approved("bun install"), deadline: 60)
        #expect(
            withBun == .succeeded(workingDirectory: shell.currentWorkingDirectory),
            """
            everything the stopped install needed was three commands away in the \
            shell it was already holding: got \(withBun); terminal tail: \
            \(shell.tailForTheModel())
            """
        )
        #expect(
            FileManager.default.fileExists(
                atPath: Bug7ReaderMacFixture.workspaceLockfile(inHome: readerHome)
            ),
            "and the real bun wrote a real bun.lock into the real checkout"
        )

        await shell.endSession()
    }
}
