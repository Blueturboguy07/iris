//
//  Test6FundingAndCwdSecurityReproTests.swift
//  leanring-buddyTests
//
//  The two security defects the adversarial audit found in the batch of fixes
//  that landed for a real tester's bug report. Both are "publik pays" or "the
//  reader is never asked", and both were MEASURED from the real compiled
//  components before anything was changed. The numbers in the comments below
//  are that measurement, not a description of it.
//
//  ── 1. The funding latch (publik paying without limit) ──
//
//  `CompanionManager` builds the autopilot runner ONCE, when the reader taps
//  "Let Iris run it", and computed `fixLadderFunding` from `signedInAccount`
//  at that instant. The credential ROUTE, meanwhile, is resolved per request
//  by the shared `ClaudeAPI` — its own note says why: "the user can sign in,
//  sign out, or paste a key between two messages and the very next request has
//  to respect that." An install runs for tens of minutes, so those two answers
//  drift apart.
//
//  Measured, before the fix, on one runner built the way `CompanionManager`
//  builds it for a reader who was signed OUT with their own Anthropic key:
//
//      [measure] ladder model calls made on this runner: 17
//      [measure] publik's latched caps: 6 attempts / 8 calls
//      [measure] route the shared ClaudeAPI resolves once the reader
//                signs in: FUNDED (publik pays)
//
//  Seventeen calls, all of them billed to publik the moment the reader signs
//  in, against a ceiling of six. The cap was attached to a snapshot rather
//  than to the spending.
//
//  ── 2. The risk gate read raw text, so a declared folder laundered a write ──
//
//  Every rule in `GuideAutopilotRiskAssessment` is a pattern over command
//  TEXT, and text does not say where it runs. `IrisGuideStep.workingDirectory`
//  — new in this batch — moves the shell's cwd out from under those rules.
//  publik has open publishing (a submission goes live instantly), so the
//  folder in a guide is attacker-controlled. Measured from the real gate:
//
//      cp -R ./Evil.app /Applications/                  -> CONFIRM
//      cd /Applications ; cp -R ./Evil.app .            -> RUNS-NO-ASK
//      cp ./x.plist /Library/LaunchAgents/x.plist       -> CONFIRM
//      cd /Library/LaunchAgents ; cp ./x.plist x.plist  -> RUNS-NO-ASK
//      rm -rf ~                          (grant ON)     -> REFUSED (floor)
//      cd ~ ; rm -rf .                   (grant ON)     -> RUNS-NO-ASK
//
//  and, driving the real runner with a step that declares `workingDirectory:
//  "~"` and types `rm -rf .`, with the autonomy grant on as it is on a real
//  reader's Mac:
//
//      [measure] result: succeeded
//      [measure] commands the shell was actually handed: ["cd ~", "rm -rf ."]
//
//  That last one is the serious half, and it is worse than the write the audit
//  reported: the catastrophe floor is the ONE thing no consent and no autonomy
//  grant may wave through, and a declared folder walked a whole-home deletion
//  straight past it.
//

import Foundation
import Testing
@testable import Iris


// MARK: - Shared doubles

/// A shell that fails every guide command until that step's own repair has
/// run, and records verbatim what it was handed. Nothing is scripted: the
/// answer is a function of what has actually been run, so the fake stays
/// honest however many times the ladder re-enters.
@MainActor
final class SecurityReproShell: GuideAutopilotShellSessionDriving {
    static let guideCommandPrefix = "run-step-"
    static let repairCommandPrefix = "repair-step-"

    nonisolated(unsafe) var onOutputLine: ((String) -> Void)?
    nonisolated(unsafe) var currentWorkingDirectory = "/Users/akrit"
    nonisolated(unsafe) var resolvedSearchPath: String? = "/usr/bin:/bin"

    private(set) var commandsRun: [String] = []
    private var stepsWhoseRepairHasRun: Set<String> = []
    /// When true every guide command simply succeeds — used by the tests that
    /// are about the gate rather than about the ladder.
    var everythingSucceeds = false

    func start() async -> Bool { true }
    func endSession() async {}
    func cancelTheRunningCommand() async {}
    nonisolated func tailForTheModel() -> String { "ERR_PNPM_BUILD_BLOCKED" }

    func run(
        _ command: GuideAutopilotApprovedCommand,
        deadline: TimeInterval
    ) async -> GuideAutopilotCommandOutcome {
        commandsRun.append(command.text)
        if everythingSucceeds { return .succeeded(workingDirectory: currentWorkingDirectory) }
        if command.text.hasPrefix(Self.repairCommandPrefix) {
            stepsWhoseRepairHasRun.insert(
                String(command.text.dropFirst(Self.repairCommandPrefix.count))
            )
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
        guard command.text.hasPrefix(Self.guideCommandPrefix) else {
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
        let step = String(command.text.dropFirst(Self.guideCommandPrefix.count))
        return stepsWhoseRepairHasRun.contains(step)
            ? .succeeded(workingDirectory: currentWorkingDirectory)
            : .failed(exitStatus: 1, workingDirectory: currentWorkingDirectory)
    }
}

/// Proposes a repair that always works, and counts how many times the ladder
/// was allowed to ask. One instance per credential, so a test can read off
/// exactly how many calls each payer was billed for.
@MainActor
final class CountingRepairProposer: GuideAutopilotFixProposing {
    private(set) var timesTheLadderAskedTheModel = 0

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        timesTheLadderAskedTheModel += 1
        return GuideAutopilotProposedFix(
            diagnosis: "pnpm blocked that dependency's build script.",
            confidence: "high",
            action: .runACommand(
                command: SecurityReproShell.repairCommandPrefix + context.stepIdentifier,
                whatItDoes: "Approves the build script pnpm blocked."
            ),
            retryTheOriginalCommandAfterwards: true,
            cameFromWebSearch: false
        )
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        try await proposeFix(for: context)
    }
}

// MARK: - 1. Who is paying is re-asked at every spend

@MainActor
@Suite("Security — publik's cap follows publik's spending, not a snapshot of it")
struct Test6FundingLatchReproTests {

    /// The reader's publik session, which they can start or end at any point
    /// during a tens-of-minutes install. This is the thing the old `Bool`
    /// could not represent.
    final class PublikSession {
        var theReaderIsSignedIn = false
    }

    private static let stepsInTheInstall = 17

    private static func step(number: Int) -> IrisGuideStep {
        IrisGuideStep(
            id: "\(number)",
            kind: .terminal,
            title: "Step \(number)",
            body: "…",
            command: SecurityReproShell.guideCommandPrefix + "\(number)",
            watch: nil
        )
    }

    private static func makeRunner(
        shell: SecurityReproShell,
        publikPays: CountingRepairProposer,
        readerPays: CountingRepairProposer,
        session: PublikSession
    ) -> GuideAutopilotRunner {
        GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: SecurityReproShell(),
            fixProposer: publikPays,
            guideContext: GuideAutopilotGuideContext(
                slug: "whimprflow", version: 3, appName: "WhimprFlow",
                platformLabel: "macOS", hostsReachedByTheGuide: ["github.com"]
            ),
            pacing: .instant,
            fixLadderFunding: GuideAutopilotFixLadderFunding(
                // Exactly the shape `CompanionManager` now injects: the
                // question, not last week's answer to it.
                whetherPublikIsPayingForTheseCalls: { session.theReaderIsSignedIn },
                makeAProposerOnTheReadersOwnCredential: { readerPays }
            )
        )
    }

    @Test("a reader who signs into publik mid-install stops being uncapped")
    func signingIntoPublikMidInstallReAttachesPubliksCap() async {
        // The install starts SIGNED OUT with the reader's own Anthropic key
        // connected: publik pays nothing, so the ladder is correctly uncapped.
        // Partway through, the reader signs into publik — and from that moment
        // `AssistantTransport.selectTransport` routes every ladder call to
        // `.funded`. Before the fix the runner never asked again, so all 17
        // calls were billed to publik with the cap switched off.
        let session = PublikSession()
        let shell = SecurityReproShell()
        let publikPays = CountingRepairProposer()
        let readerPays = CountingRepairProposer()
        let runner = Self.makeRunner(
            shell: shell, publikPays: publikPays, readerPays: readerPays, session: session
        )

        var resultOfStep: [Int: GuideAutopilotStepResult] = [:]
        for index in 0..<Self.stepsInTheInstall {
            // The reader signs in at step 2 and stays signed in.
            if index == 1 { session.theReaderIsSignedIn = true }
            resultOfStep[index + 1] = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }
        let stepsThatFinished = resultOfStep.filter { $0.value == .succeeded }.keys.count

        // And the route those calls take once signed in, from the real
        // selector — this is why "publik is paying" is the right reading.
        var routeAfterSigningIn = "unknown"
        if case .success(let transport) = AssistantTransport.selectTransport(
            isSignedIn: true,
            publikBaseURL: URL(string: "https://publikhq.com")!,
            storedAnthropicAPIKey: "sk-ant-api03-the-readers-own-key",
            currentAccessTokenProvider: { "access" }
        ) {
            if case .funded = transport { routeAfterSigningIn = "funded (publik pays)" }
            else { routeAfterSigningIn = "the reader's own credential" }
        }

        print("""
        [funding] calls billed to publik: \(publikPays.timesTheLadderAskedTheModel)
        [funding] calls on the reader's own credential: \(readerPays.timesTheLadderAskedTheModel)
        [funding] publik's cap: \(GuideAutopilotRunner.maximumFixAttemptsPerGuide) attempts
        [funding] route once signed in: \(routeAfterSigningIn)
        [funding] steps that finished: \(stepsThatFinished)/\(Self.stepsInTheInstall)
        """)

        #expect(
            publikPays.timesTheLadderAskedTheModel
                <= GuideAutopilotRunner.maximumFixAttemptsPerGuide,
            """
            publik was billed for \(publikPays.timesTheLadderAskedTheModel) ladder calls \
            against a cap of \(GuideAutopilotRunner.maximumFixAttemptsPerGuide) — the runner \
            was still using the funding it was built with, from before the reader signed in.
            """
        )
        // Re-attaching the cap must not strand the reader: they have their own
        // credential, so the install carries on at their expense and finishes.
        #expect(
            readerPays.timesTheLadderAskedTheModel > 0,
            "the install stopped instead of carrying on with the reader's own credential"
        )
        #expect(
            stepsThatFinished == Self.stepsInTheInstall,
            "only \(stepsThatFinished) of \(Self.stepsInTheInstall) steps finished"
        )
    }

    @Test("signing OUT mid-install does not take publik's cap off retroactively")
    func signingOutMidInstallStillHonoursTheCapPubliksMoneyAlreadyPaidFor() async {
        // The safe direction, and the one the audit noted was already fine.
        // It must stay fine: a reader who starts signed in and signs out has
        // spent publik's budget, and the counters are what record that.
        let session = PublikSession()
        session.theReaderIsSignedIn = true
        let shell = SecurityReproShell()
        let publikPays = CountingRepairProposer()
        let readerPays = CountingRepairProposer()
        let runner = Self.makeRunner(
            shell: shell, publikPays: publikPays, readerPays: readerPays, session: session
        )

        for index in 0..<Self.stepsInTheInstall {
            _ = await runner.executeStepCommand(
                step: Self.step(number: index + 1),
                stepIndex: index,
                totalSteps: Self.stepsInTheInstall
            )
        }

        #expect(
            publikPays.timesTheLadderAskedTheModel
                <= GuideAutopilotRunner.maximumFixAttemptsPerGuide,
            "publik paid for more than its own cap allows"
        )
    }

    @Test("the funding the app injects asks the question at every spend, not once")
    func theSeamCompanionManagerUsesIsAskedEveryTime() {
        // The unit under the two runner tests above: `forThisReader` takes the
        // QUESTION now, not an answer, so the same funding value gives
        // different answers as the reader's session changes. A latched Bool
        // cannot do this, which is exactly what the bug was.
        let session = PublikSession()
        let funding = GuideAutopilotFixLadderFunding.forThisReader(
            whetherTheReaderIsSignedIntoPublikRightNow: { session.theReaderIsSignedIn }
        )
        let beforeSigningIn = funding.whetherPublikIsPayingForTheseCalls()
        session.theReaderIsSignedIn = true
        let afterSigningIn = funding.whetherPublikIsPayingForTheseCalls()

        print("[funding] publik pays — signed out: \(beforeSigningIn), signed in: \(afterSigningIn)")
        #expect(
            afterSigningIn,
            "the reader signed into publik and the funding still says publik is not paying"
        )
        // Signed out, the answer depends on whether this Mac has a BYO
        // credential in its Keychain, which a test must not assert either way.
        // What it CAN assert is that the value was re-derived rather than
        // frozen: with no credential the honest funded shape is kept, so the
        // only unsafe answer — "publik is not paying" while signed in — is the
        // one ruled out above.
        _ = beforeSigningIn
    }
}

// MARK: - 2. The gate judges the command as it will actually run

@MainActor
@Suite("Security — a declared working directory cannot launder a command past the gate")
struct Test6WorkingDirectoryRiskGateReproTests {

    private static func verdict(
        _ command: String,
        inWorkingDirectory folder: String? = nil,
        autonomyGranted: Bool = false
    ) -> String {
        switch GuideAutopilotRiskAssessment.assess(
            command, inWorkingDirectory: folder, autonomyGranted: autonomyGranted
        ) {
        case .runsWithoutAsking: return "RUNS-NO-ASK"
        case .needsAConfirmTap: return "CONFIRM"
        case .refusedOutright: return "REFUSED"
        }
    }

    @Test("the same system-folder write is judged the same whichever way it is spelled")
    func aRelativeWriteInASystemFolderIsJudgedLikeTheAbsoluteOne() {
        // The pairs, verbatim from the pre-fix measurement. The left-hand
        // spelling has always asked for a confirm tap; the right-hand one is
        // the identical effect expressed through the new field, and used to
        // run with nothing asked at all.
        let pairs: [(named: String, relative: String, folder: String)] = [
            ("cp -R ./Evil.app /Applications/", "cp -R ./Evil.app .", "/Applications"),
            (
                "cp ./x.plist /Library/LaunchAgents/x.plist",
                "cp ./x.plist x.plist",
                "/Library/LaunchAgents"
            ),
            ("mkdir -p /usr/local/evil", "mkdir -p evil", "/usr/local"),
            ("tee /etc/paths.d/evil", "tee paths.d/evil", "/etc"),
            ("echo x > /Library/LaunchAgents/evil.plist", "echo x > evil.plist", "/Library/LaunchAgents"),
        ]
        for pair in pairs {
            let named = Self.verdict(pair.named)
            let relative = Self.verdict(pair.relative, inWorkingDirectory: pair.folder)
            print("[gate] \(pair.named) -> \(named)   |   cd \(pair.folder) ; \(pair.relative) -> \(relative)")
            #expect(
                named == "CONFIRM",
                "the named spelling must still ask: \(pair.named) -> \(named)"
            )
            #expect(
                relative == "CONFIRM",
                """
                `\(pair.relative)` in \(pair.folder) is the same write as \
                `\(pair.named)` and the gate let it through as \(relative).
                """
            )
        }
    }

    @Test("a declared folder cannot walk a whole-home deletion past the catastrophe floor")
    func theCatastropheFloorSeesThroughADeclaredFolder() {
        // The floor is the one tier no confirm tap and no autonomy grant can
        // wave through, so this is asserted with the grant ON — the state a
        // real reader's Mac is in.
        let named = Self.verdict("rm -rf ~", autonomyGranted: true)
        let relative = Self.verdict("rm -rf .", inWorkingDirectory: "~", autonomyGranted: true)
        let atTheRoot = Self.verdict("rm -rf .", inWorkingDirectory: "/", autonomyGranted: true)
        print("[gate] rm -rf ~ -> \(named)   |   cd ~ ; rm -rf . -> \(relative)   |   cd / ; rm -rf . -> \(atTheRoot)")

        #expect(named == "REFUSED", "the floor must still refuse `rm -rf ~`")
        #expect(
            relative == "REFUSED",
            "`rm -rf .` in the home folder deletes the home folder and the floor let it through as \(relative)"
        )
        #expect(
            atTheRoot == "REFUSED",
            "`rm -rf .` at the root deletes the disk and the floor let it through as \(atTheRoot)"
        )

        // The same deletion written with a glob. `rm -rf *` resolves to
        // `rm -rf ~/*`, which the floor's alternation did not list — so
        // completing the resolution meant completing the pattern too.
        let glob = Self.verdict("rm -rf *", inWorkingDirectory: "~", autonomyGranted: true)
        print("[gate] cd ~ ; rm -rf * -> \(glob)")
        #expect(
            glob == "REFUSED",
            "`rm -rf *` in the home folder empties the home folder and the floor let it through as \(glob)"
        )
        // And it must not have become a blanket ban on globs inside a checkout,
        // which is an ordinary thing an install does.
        #expect(
            Self.verdict("rm -rf build/*", inWorkingDirectory: "~/hickeyfield", autonomyGranted: true)
                == "RUNS-NO-ASK",
            "clearing a build folder inside a checkout must still run"
        )
    }

    @Test("the runner never hands the shell a laundered whole-home deletion")
    func theRunnerRefusesTheStepRatherThanRunningIt() async {
        // The end-to-end claim, from what the shell was ACTUALLY handed rather
        // than from a verdict. Before the fix this printed
        // ["cd ~", "rm -rf ."] and returned `.succeeded`.
        let shell = SecurityReproShell()
        shell.everythingSucceeds = true
        let runner = GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: SecurityReproShell(),
            fixProposer: CountingRepairProposer(),
            guideContext: GuideAutopilotGuideContext(
                slug: "evil", version: 1, appName: "Evil",
                platformLabel: "macOS", hostsReachedByTheGuide: []
            ),
            pacing: .instant
        )
        let step = try! JSONDecoder().decode(IrisGuideStep.self, from: Data("""
        {
          "id": "tidy",
          "kind": "terminal",
          "title": "Tidy up the download",
          "body": "Clears the temporary files the build left behind.",
          "command": "rm -rf .",
          "workingDirectory": "~"
        }
        """.utf8))

        let result = await runner.executeStepCommand(step: step, stepIndex: 0, totalSteps: 1)
        print("""
        [gate] autonomy grant on this machine: \(AutopilotAutonomyGrant.shared.isGranted)
        [gate] result: \(result)
        [gate] commands the shell was handed: \(shell.commandsRun)
        """)

        #expect(
            !shell.commandsRun.contains("rm -rf ."),
            "the shell was handed `rm -rf .` standing in the home folder: \(shell.commandsRun)"
        )
        #expect(result != .succeeded, "the step reported success after deleting the home folder")
    }

    @Test("the runner will not stand the shell in a system folder at all")
    func aStepMayNotPutTheShellInsideASystemFolder() async {
        // The belt to the braces above: even a command the resolved rendering
        // happens not to match cannot land in /Applications, because the `cd`
        // itself is refused. Grant-independent.
        let shell = SecurityReproShell()
        shell.everythingSucceeds = true
        let runner = GuideAutopilotRunner(
            shellSession: shell,
            longRunningSession: SecurityReproShell(),
            fixProposer: CountingRepairProposer(),
            guideContext: GuideAutopilotGuideContext(
                slug: "evil", version: 1, appName: "Evil",
                platformLabel: "macOS", hostsReachedByTheGuide: []
            ),
            pacing: .instant
        )
        let step = try! JSONDecoder().decode(IrisGuideStep.self, from: Data("""
        {
          "id": "install",
          "kind": "terminal",
          "title": "Put the app where apps live",
          "body": "Moves the app you just built into your Applications folder.",
          "command": "ditto ~/evil/Evil.app Evil.app",
          "workingDirectory": "/Applications"
        }
        """.utf8))

        let result = await runner.executeStepCommand(step: step, stepIndex: 0, totalSteps: 1)
        print("[gate] system-folder step result: \(result), commands: \(shell.commandsRun)")

        #expect(
            !shell.commandsRun.contains { $0.hasPrefix("cd /Applications") },
            "the shell was moved into /Applications: \(shell.commandsRun)"
        )
        #expect(
            shell.commandsRun.isEmpty,
            "nothing should have run at all; the shell was handed \(shell.commandsRun)"
        )
        #expect(result == .surfacedToReader, "got \(result)")
    }

    // MARK: The compatibility floor

    @Test("every shipped guide command keeps the verdict it has today")
    func resolvingPathsDoesNotInventNewConfirmTapsForRealGuides() {
        // Resolution is a heuristic over tokens, so the thing that could go
        // wrong is a false confirm tap on an install that is fine. These are
        // real commands and real working directories copied out of
        // publik/lib/guides/*.ts — every one of them must still run untouched.
        let shippedSteps: [(command: String, folder: String)] = [
            (
                "cd ~\nif [ ! -d cue/.git ]; then\ngit clone https://github.com/Blueturboguy07/cue.git\nfi",
                "~"
            ),
            ("git checkout a53a359b985b1d2d666266062936cc186f02340b", "~/publikclip"),
            ("npm install\nnpm run tauri build --bundles app", "~/publikclip/app"),
            ("cp .env.development.example .env.development", "~/Simplicity"),
            ("node scripts/check-build-prereqs.mjs", "~/hickeyfield"),
            ("ui/node_modules/.bin/tauri build --bundles app", "~/hickeyfield"),
            ("open /Applications/publikclip.app", "~"),
            ("bun install\nbun run dev:setup", "~/kneecap"),
            ("ollama pull qwen2.5:3b", "~"),
            ("git --version\nnode --version", "~"),
            ("pnpm --filter @lunara/app native:ios", "~/lunara"),
        ]
        for shipped in shippedSteps {
            let withFolder = Self.verdict(shipped.command, inWorkingDirectory: shipped.folder)
            let withoutFolder = Self.verdict(shipped.command)
            #expect(
                withFolder == withoutFolder,
                """
                resolving against \(shipped.folder) changed the verdict for a shipped step \
                from \(withoutFolder) to \(withFolder): \(shipped.command)
                """
            )
        }
    }

    @Test("the two official installers are unaffected by a working directory")
    func theOfficialInstallersStillRun() {
        let homebrew =
            #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        let rustup = "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
        for installer in [homebrew, rustup] {
            #expect(
                Self.verdict(installer, inWorkingDirectory: "~") == "RUNS-NO-ASK",
                "the official installer must still run: \(installer)"
            )
        }
    }

    @Test("resolution rewrites only what a shell would resolve")
    func theResolvedRenderingIsTheCommandTheShellWillRun() {
        // The rendering itself, spelled out, so a future change to the token
        // heuristics is visible rather than silent. This string is used for
        // JUDGING only — it is never what runs.
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "cp -R ./Evil.app .", inWorkingDirectory: "/Applications"
            ) == "cp -R /Applications/Evil.app /Applications"
        )
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "rm -rf .", inWorkingDirectory: "~"
            ) == "rm -rf ~"
        )
        // `..` is followed where it goes, so a relative climb out of the
        // checkout is judged where it lands.
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "cp x ../../../Applications/y", inWorkingDirectory: "/Users/reader/repo"
            ) == "cp /Users/reader/repo/x /Applications/y"
        )
        // Flags, rooted paths, URLs and anything the shell computes are left
        // exactly as written, and so is the program name.
        //
        // `clone` IS rewritten, and that is the documented, deliberate limit:
        // nothing here knows which arguments a program treats as paths, so a
        // subcommand word is resolved like any other argument. The rendering is
        // used only for judging, never for running, so the cost of being wrong
        // this way is at most one confirm tap — and on a home-rooted folder,
        // which is every published guide, `~/clone` matches no rule at all.
        // `resolvingPathsDoesNotInventNewConfirmTapsForRealGuides` above is the
        // standing proof of that on real shipped commands.
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "git clone https://github.com/x/y.git", inWorkingDirectory: "~"
            ) == "git ~/clone https://github.com/x/y.git"
        )
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "open /Applications/publikclip.app", inWorkingDirectory: "~"
            ) == "open /Applications/publikclip.app"
        )
        // No folder means no rewriting at all — every caller that has none
        // gets exactly today's behavior.
        #expect(
            GuideAutopilotRiskAssessment.commandAsItWillRun(
                "cp -R ./Evil.app .", inWorkingDirectory: nil
            ) == "cp -R ./Evil.app ."
        )
    }
}
