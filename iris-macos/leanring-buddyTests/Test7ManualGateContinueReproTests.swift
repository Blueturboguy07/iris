//
//  Test7ManualGateContinueReproTests.swift
//  leanring-buddyTests
//
//  THE READER'S WORDS (Test 7 field report, Iris 0.9.1 build 17):
//
//      "The I did it - continue button is not working when trying to install
//       cmake."
//
//  and the same gate, reported once already in Test 6, on a permission grant
//  for WhimprFlow. Runtime telemetry from his run: at the CMake gate Iris was
//  parked with `readerMustManuallyContinue = true` and nothing ever advanced —
//  the install only moved again after he quit and relaunched the app.
//
//  These tests drive the REAL `GuideSessionController` — its real drive loop,
//  its real advance, its real resume — against a scripted shell, to the exact
//  shape the reader hit: whimprflow's macOS toolchain authors `install-rust`
//  (kind `open`) immediately followed by `install-cmake` (kind `open`), two
//  manual gates back to back, and then the install's own commands.
//
//  WHAT THEY CAUGHT AT HEAD, stated exactly:
//
//   - ONE press at a gate already resumed the install (the first two tests
//     passed before any change). Say that plainly rather than claiming a fix
//     for something that was working.
//   - TWO presses did NOT. `advanceToTheNextStep` increments unconditionally,
//     while `resumeAutopilotAfterAdvance` refuses to re-enter a drive loop that
//     is already in flight — so the second press walked the reader past the
//     step immediately after the gate and that step was NEVER RUN. The only
//     outward sign is a step counter creeping upward with nothing happening,
//     which is what a reader sees as a button that does nothing, and it is the
//     shape his own forensics recorded: parked at the CMake gate, nothing
//     running, and a relaunch that picked up three steps further on.
//   - The resume-position check moved him BACKWARDS into that gate in the
//     first place, mid-install. That is his runtime finding #1 verbatim, and
//     the last test here pins it.
//   - The press wrote NOTHING to `iris.log` in either direction, which is why
//     his forensics could only say "No same-process continuation was logged".
//

import Foundation
import Testing
@testable import Iris

@MainActor
@Suite(.serialized) struct Test7ManualGateContinueReproTests {

    // MARK: - Fakes

    /// A shell that records every command and always succeeds. The assertion
    /// this suite turns on is "did the NEXT command run at all", so an outcome
    /// script would only add noise.
    final class RecordingShell: GuideAutopilotShellSessionDriving {
        var onOutputLine: ((String) -> Void)?
        var currentWorkingDirectory = "/Users/x"
        var resolvedSearchPath: String? = "/usr/bin:/bin"
        private(set) var commandsRun: [String] = []
        /// How long each command takes. A real install's commands are not
        /// instant, and a test that needs something to happen WHILE the drive
        /// loop is inside itself has to leave a window for it.
        var eachCommandTakes: Duration = .zero

        func start() async -> Bool { true }
        func endSession() async {}
        func cancelTheRunningCommand() async {}
        func tailForTheModel() -> String { "" }

        func run(
            _ command: GuideAutopilotApprovedCommand, deadline: TimeInterval
        ) async -> GuideAutopilotCommandOutcome {
            commandsRun.append(command.text)
            if eachCommandTakes > .zero { try? await Task.sleep(for: eachCommandTakes) }
            return .succeeded(workingDirectory: currentWorkingDirectory)
        }
    }

    /// Never offers a fix — nothing here is meant to fail, and a proposer that
    /// reached for the network would make the suite a live test.
    final class NoFixProposer: GuideAutopilotFixProposing {
        func proposeFix(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
        func proposeFixWithWebSearch(for context: GuideAutopilotFailureContext) async throws -> GuideAutopilotProposedFix? { nil }
    }

    // MARK: - The guide the reader was on

    /// Answers `GET /api/iris/guides/manual-gate` with whimprflow's real shape:
    /// a command step, then TWO manual `open` steps back to back (rust, then
    /// cmake — each carrying a `toolVersion` watch for a tool that is absent,
    /// so neither can pass early), then the install's own commands.
    ///
    /// The hrefs point at a host `ExternalLinkPolicy` has never allowlisted, on
    /// purpose: the drive loop really does call `openLinkInBrowser` at a manual
    /// gate, and a test that opened cmake.org in the reader's browser every run
    /// would be its own bug.
    final class ManualGateGuideURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.path.hasPrefix("/api/iris/guides/") == true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func stopLoading() {}

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
            client?.urlProtocol(self, didLoad: Data(Self.guideJSON.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        static let guideJSON = """
        {
          "appSlug": "manual-gate",
          "appName": "WhimprFlow",
          "version": 1,
          "status": "pilot",
          "sourceOwner": "Blueturboguy07",
          "sourceRepo": "WhimprFlow",
          "sourceCommit": null,
          "outputType": "desktop_app",
          "estimatedMinutes": 20,
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
                 "body": "", "command": "echo tools-ok"},
                {"id": "install-rust", "kind": "open", "title": "Install Rust",
                 "body": "Run the single command the page shows, then reopen Terminal.",
                 "href": "https://rustup.not-reviewed.example/",
                 "actionLabel": "Open rustup",
                 "watch": {"expect": [{"type": "toolVersion", "tool": "cargo"}]}},
                {"id": "install-cmake", "kind": "open", "title": "Install CMake",
                 "body": "The speech engine needs it to build.",
                 "href": "https://cmake.not-reviewed.example/download/",
                 "actionLabel": "Open download",
                 "watch": {"expect": [{"type": "toolVersion", "tool": "cmake"}]}},
                {"id": "clone", "kind": "terminal", "title": "Copy it to this Mac",
                 "body": "", "command": "echo cloned"},
                {"id": "build", "kind": "terminal", "title": "Build it",
                 "body": "", "command": "echo built"}
              ],
              "unsupported": null
            }
          ]
        }
        """
    }

    // MARK: - Harness

    /// The two tools the manual gates watch for. Reporting them ABSENT is what
    /// makes those steps real gates: `everyToolThisStepWatchesForIsAlreadyPresent`
    /// would otherwise auto-advance them and the reader would never see a
    /// button to press.
    private static let toolsTheGatesWaitFor: Set<String> = ["cargo", "cmake"]

    /// One live session: the controller, the shell it drives, and every gate the
    /// takeover was asked to park on (which is what `CompanionManager` wires to
    /// `GuideAutopilotTakeoverController.parkForManualStep`).
    @MainActor
    final class LiveInstall {
        let controller: GuideSessionController
        let shell: RecordingShell
        var gatesParkedOn: [String] = []
        var returnsToCenter = 0
        /// Whether the advisory resume check reached its model call at all.
        let resumeCheck: ResumeCheckWitness

        init(
            controller: GuideSessionController,
            shell: RecordingShell,
            resumeCheck: ResumeCheckWitness
        ) {
            self.controller = controller
            self.shell = shell
            self.resumeCheck = resumeCheck
        }
    }

    /// Records whether the advisory "where is this install actually up to"
    /// check reached its model call — the seam the fix guards.
    @MainActor
    final class ResumeCheckWitness {
        var askedTheModel = false
    }

    private static func startTheInstall(
        theResumeCheckSays positionModelReply: String? = nil,
        resumingAtSavedStep savedStep: (index: Int, id: String)? = nil,
        eachCommandTakes: Duration = .zero,
        toolCheckDelay: Duration? = nil
    ) async throws -> LiveInstall {
        let shell = RecordingShell()
        shell.eachCommandTakes = eachCommandTakes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualGateGuideURLProtocol.self]
        let defaults = try #require(
            UserDefaults(suiteName: "iris.test7.manualgate.\(UUID().uuidString)")
        )
        if let savedStep {
            // Where the reader left off last time, which is what the resume
            // check is an opinion about.
            defaults.set(
                ["step": savedStep.index, "stepId": savedStep.id, "version": 1,
                 "completed": false, "updatedAt": Date().timeIntervalSince1970] as [String: Any],
                forKey: "iris:progress:manual-gate:macos:desktop"
            )
        }
        let resumeCheckWitness = ResumeCheckWitness()
        let controller = GuideSessionController(
            guideService: GuideService(
                apiBase: GuideService.defaultAPIBase,
                urlSession: URLSession(configuration: configuration),
                userDefaults: defaults
            ),
            // A WATCH LOOP THAT NEVER TICKS ON ITS OWN, so a gate is a gate on
            // every machine. The default `WatchLoop()` reaches the REAL
            // `ToolVersionService`, not the `checkToolVersion` injected below —
            // so on a Mac that has cargo and cmake (this one does) it cleared
            // both of this guide's gates by itself, at whatever moment the
            // machine happened to be fast enough, and the suite's result then
            // depended on how loaded the box was. That is how these tests came
            // to pass alone and fail under the full suite. The race it was
            // hiding is real and is now covered deliberately, by
            // `theWatchLoopAdvancingWhileTheDriveLoopIsInFlightRunsEveryStep`
            // below, which fires the watch loop's own advance by hand.
            watchLoop: WatchLoop(drivesItsOwnTickTimer: false),
            checkToolVersion: { toolName in
                if let toolCheckDelay { try? await Task.sleep(for: toolCheckDelay) }
                return ToolVersion(
                    tool: toolName,
                    available: !toolsTheGatesWaitFor.contains(toolName),
                    version: "\(toolName) version 1.2.3"
                )
            },
            makeAutopilotRunner: { context in
                GuideAutopilotRunner(
                    shellSession: shell,
                    longRunningSession: RecordingShell(),
                    fixProposer: NoFixProposer(),
                    guideContext: context,
                    pacing: .instant
                )
            }
        )
        // The autonomy grant lives in UserDefaults and its state on this Mac
        // decides whether `startAutopilot` even runs. Inject a granted one over
        // an isolated suite so the suite reads the same on any machine and
        // never touches the reader's real preference.
        let grantDefaults = try #require(
            UserDefaults(suiteName: "iris.test7.manualgate.grant.\(UUID().uuidString)")
        )
        var grant = AutopilotAutonomyGrant(userDefaults: grantDefaults)
        grant.grant()
        controller.autonomyGrant = grant
        controller.confirmAutonomousControl = { true }
        if let positionModelReply {
            // The advisory "where is this install actually up to" check, whose
            // reply lands seconds after the guide opened — which on a real Mac
            // is well after the reader has tapped "Let Iris run it".
            controller.askTheModelWhereTheReaderIs = { _, _ in
                await MainActor.run { resumeCheckWitness.askedTheModel = true }
                return positionModelReply
            }
        }

        let install = LiveInstall(
            controller: controller, shell: shell, resumeCheck: resumeCheckWitness
        )
        controller.onAutopilotWaitingForReaderAtGate = { title, _ in
            install.gatesParkedOn.append(title)
        }
        controller.onAutopilotResumedFromGate = { install.returnsToCenter += 1 }

        await controller.openGuide(
            slug: "manual-gate", requestedVersion: 1,
            branchKeyFromDeepLink: "macos:desktop",
            // A saved-progress resume is the path the resume check hangs off;
            // a deep-linked step index bypasses it entirely.
            stepIndexFromDeepLink: savedStep == nil ? 0 : nil
        )
        controller.startAutopilot()
        return install
    }

    /// Polls a main-actor condition. The drive loop runs in a detached `Task`,
    /// so its effects are what a test can observe — there is no handle to await.
    private func pump(
        within seconds: Double = 8,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Walks the install to the CMake gate — the one the reader named — by
    /// clearing the Rust gate in front of it the way he did, with the button.
    ///
    /// It is spelled out rather than assumed because the guide's gates are only
    /// cleared by something doing it: this suite's watch loop never ticks (see
    /// `startTheInstall`), so nothing arrives at the second gate on its own. A
    /// test that waited for it anyway passed only on a machine that happened to
    /// have cargo installed, which is exactly the flake being removed.
    private func parkAtTheCMakeGate(_ install: LiveInstall) async throws {
        try #require(
            await pump { install.gatesParkedOn.count >= 1 },
            "autopilot never reached the first manual gate — the repro is not set up"
        )
        install.controller.readerFinishedTheGatedStep()
        try #require(
            await pump { install.gatesParkedOn.count >= 2 },
            "clearing the Rust gate never brought Iris to the CMake gate — parked on \(install.gatesParkedOn)"
        )
        try #require(install.gatesParkedOn.last == "Install CMake")
    }

    // MARK: - The reported defect

    /// THE REPRO. Two manual gates back to back, exactly as whimprflow authors
    /// them, and the reader taps "I did it — continue" on the second one — the
    /// CMake gate he named. The install must carry on by itself from there.
    @Test func tappingContinueAtTheCMakeGateResumesTheInstall() async throws {
        let install = try await Self.startTheInstall()
        defer { install.controller.stopAutopilot() }

        // Gate one: Install Rust.
        #expect(
            await pump { install.gatesParkedOn.count >= 1 },
            "autopilot never reached the first manual gate — the repro is not set up"
        )
        #expect(install.gatesParkedOn.first == "Install Rust")
        install.controller.readerFinishedTheGatedStep()

        // Gate two: Install CMake. This is the one the reader named.
        #expect(
            await pump { install.gatesParkedOn.count >= 2 },
            """
            tapping "I did it — continue" at the Rust gate never brought Iris to the CMake \
            gate — parked on \(install.gatesParkedOn)
            """
        )
        #expect(install.gatesParkedOn.last == "Install CMake")

        // The tap the reader says does nothing.
        install.controller.readerFinishedTheGatedStep()

        #expect(
            await pump { install.shell.commandsRun.contains("echo cloned") },
            """
            "I did it — continue" at the CMake gate ran nothing: after the tap the shell had \
            only \(install.shell.commandsRun) and the guide was still on step \
            \(install.controller.currentStepIndex). This is the reader's "the I did it - \
            continue button is not working when trying to install cmake".
            """
        )
        // And it keeps going, rather than advancing exactly one step and stalling.
        #expect(
            await pump { install.shell.commandsRun.contains("echo built") },
            "the install stopped one command after the gate instead of finishing"
        )
    }

    /// The same tap on the FIRST gate a guide reaches, because the reader hit
    /// this on WhimprFlow's permission steps too and the fix has to cover every
    /// manual gate rather than CMake specially.
    @Test func tappingContinueAtTheFirstGateResumesTheInstall() async throws {
        let install = try await Self.startTheInstall()
        defer { install.controller.stopAutopilot() }

        #expect(await pump { install.gatesParkedOn.count >= 1 })
        let stepBeforeTheTap = install.controller.currentStepIndex
        install.controller.readerFinishedTheGatedStep()

        #expect(
            await pump { install.controller.currentStepIndex > stepBeforeTheTap },
            "the tap did not even move the guide off the gated step"
        )
        #expect(
            await pump { install.gatesParkedOn.count >= 2 },
            "the drive loop never re-entered after the tap, so nothing after the gate ran"
        )
    }

    /// A double tap — the reader's instinct when a button "does nothing" is to
    /// press it again, and his run shows exactly that shape. Pressing twice
    /// must not skip a step the guide still needs, and must not wedge the loop.
    @Test func tappingContinueTwiceDoesNotSkipTheStepAfterTheGate() async throws {
        let install = try await Self.startTheInstall()
        defer { install.controller.stopAutopilot() }

        try await parkAtTheCMakeGate(install)
        install.controller.readerFinishedTheGatedStep()
        install.controller.readerFinishedTheGatedStep()

        #expect(
            await pump { install.shell.commandsRun.contains("echo cloned") },
            """
            two taps at the CMake gate left the shell at \(install.shell.commandsRun) — the \
            step after the gate was skipped, which is worse than the button doing nothing
            """
        )
    }

    /// THE RACE THAT MADE THE CMAKE GATE POINT AT THE WRONG STEP, and the one
    /// mechanism that explains the tester's forensics without hand-waving.
    ///
    /// At a manual gate there are TWO things that can advance the guide: the
    /// reader's button and the watch loop. The watch loop's advance is a plain
    /// `advanceToTheNextStep()` (see `WatchLoop.onVerdict`'s handler), and it can
    /// land while the drive loop is suspended at one of its own `await`s —
    /// `resumeAutopilotAfterAdvance` will not start a second loop, so the
    /// running one simply carries on. At HEAD it then carried on with the OLD
    /// step's decision and the NEW step's index: the CMake gate parked, but
    /// recorded itself against the step AFTER it. Measured in the full suite,
    /// from `iris.log`:
    ///
    ///     drive: step[2] id=install-cmake … MANUAL branch, waiting at gate
    ///     gate: reader finished step 3 — advancing and resuming autopilot
    ///     drive: step[4] id=build
    ///
    /// — `clone` skipped, never run. That is "parked at the CMake gate, nothing
    /// running, and a relaunch that picked up three steps further on".
    ///
    /// Here the watch loop's advance is fired BY HAND, in the window the tool
    /// probe holds open, so the race is a fact of the test rather than a matter
    /// of how loaded the machine is.
    @Test func theWatchLoopAdvancingWhileTheDriveLoopIsInFlightRunsEveryStep() async throws {
        // Each tool probe shells out on a real Mac, so the drive loop really is
        // suspended here for a moment on its way into a gate.
        let install = try await Self.startTheInstall(toolCheckDelay: .milliseconds(400))
        defer { install.controller.stopAutopilot() }

        #expect(
            await pump { install.gatesParkedOn.count >= 1 },
            "autopilot never reached the first manual gate — the repro is not set up"
        )
        // The reader clears the Rust gate. The drive loop moves to the CMake
        // gate and suspends inside its tool probe.
        install.controller.readerFinishedTheGatedStep()
        try? await Task.sleep(for: .milliseconds(150))

        // THE WATCH LOOP FIRES, mid-probe — verbatim the call its verdict
        // handler makes when it decides a step is finished.
        install.controller.advanceToTheNextStep()

        #expect(
            await pump { install.shell.commandsRun.contains("echo cloned") },
            """
            the watch loop advanced the guide while the drive loop was in flight and the step \
            after the gate was never run: the shell had only \(install.shell.commandsRun) and \
            the guide ended on step \(install.controller.currentStepIndex)
            """
        )
        #expect(
            await pump { install.shell.commandsRun.contains("echo built") },
            "the install stopped one command after the race instead of finishing"
        )
    }

    /// The reader presses Back in the guide panel while the takeover's bar is
    /// still up, then presses "I did it — continue".
    ///
    /// `GuidePanelView`'s Back button is live during a takeover and writes
    /// `currentStepIndex` directly, so the bar and the guide can disagree.
    /// Answering that disagreement with a silent `return` — which is what the
    /// first attempt at this fix did — makes the button PERMANENTLY dead:
    /// neither press ran a command, advanced a step, or took the bar down
    /// (`readerMustManuallyContinue` is only cleared by `returnToCenter`, which
    /// a stopped drive loop never reaches). That is strictly worse than the bug
    /// being fixed, so the bar is honoured instead.
    @Test func continueStillWorksAfterTheReaderPressedBackInThePanel() async throws {
        let install = try await Self.startTheInstall()
        defer { install.controller.stopAutopilot() }

        try await parkAtTheCMakeGate(install)
        let theStepTheBarIsAbout = install.controller.currentStepIndex
        install.controller.returnToThePreviousStep()
        try #require(
            install.controller.currentStepIndex == theStepTheBarIsAbout - 1,
            "Back did not move the guide, so this test proves nothing"
        )

        // The bar still says "Install CMake". The reader presses it.
        install.controller.readerFinishedTheGatedStep()

        #expect(
            await pump { install.shell.commandsRun.contains("echo cloned") },
            """
            after pressing Back, "I did it — continue" did nothing at all: the shell had only \
            \(install.shell.commandsRun) and the guide sat on step \
            \(install.controller.currentStepIndex) with the bar still on screen
            """
        )
        #expect(
            await pump { install.shell.commandsRun.contains("echo built") },
            "the install stopped one command after the gate instead of finishing"
        )
    }

    /// The stopped-autopilot branch of the gate button, which nothing covered.
    ///
    /// A press with autopilot already stopped underneath a takeover that is
    /// still on screen used to return in silence — the same silent-dead-button
    /// shape that made the red traffic light read as broken. Delete the branch
    /// and this goes red.
    @Test func continueAdvancesTheGuideEvenWithAutopilotAlreadyStopped() async throws {
        let install = try await Self.startTheInstall()

        #expect(await pump { install.gatesParkedOn.count >= 1 })
        let stepTheGateParkedOn = install.controller.currentStepIndex
        install.controller.stopAutopilot()

        install.controller.readerFinishedTheGatedStep()

        #expect(
            install.controller.currentStepIndex == stepTheGateParkedOn + 1,
            """
            the reader said they did the step and nothing moved: still on step \
            \(install.controller.currentStepIndex). A button that does nothing is the whole \
            complaint, and autopilot having stopped is not the reader's problem.
            """
        )
    }

    // MARK: - How he got to that gate in the first place

    /// Runtime finding #1, verbatim: "At 4:57 PM PT, Iris moved WhimprFlow from
    /// step 11 back to the CMake step, entered the manual CMake gate, and parked
    /// with readerMustManuallyContinue=true."
    ///
    /// The resume-position check is a `Task` fired when a guide opens, and its
    /// verdict is ADVISORY — it exists so somebody resuming at "copy the app you
    /// never built" is put back where the machine says they are. A reader can
    /// tap "Let Iris run it" long before a model call returns, and at HEAD the
    /// verdict then reached in and moved the step index under a running drive
    /// loop. An opinion about where somebody probably is has no business
    /// overruling an install that is actually in flight.
    @Test func theResumeCheckDoesNotMoveAnInstallThatIsAlreadyRunning() async throws {
        // Resuming at the last step, the way a reader picking up a nearly
        // finished install does, with commands slow enough that the check's
        // reply lands while the drive loop is inside itself.
        let install = try await Self.startTheInstall(
            theResumeCheckSays: "STEP: 1\nWHY: cargo does not respond",
            resumingAtSavedStep: (index: 4, id: "build"),
            eachCommandTakes: .milliseconds(600),
            // Probing the machine for a tool really does take a moment (each
            // one shells out), so the reader's tap lands mid-gather — exactly
            // as it did on his Mac.
            toolCheckDelay: .milliseconds(250)
        )
        defer { install.controller.stopAutopilot() }
        try #require(
            install.controller.currentStepIndex == 4,
            "the guide must resume where the reader left it, or this test proves nothing"
        )

        // The reader taps "Let Iris run it" while the check is still gathering
        // its evidence — which is the ordinary case, because gathering it means
        // probing the machine for tools and files.
        install.controller.startAutopilot()
        _ = await pump { install.shell.commandsRun.contains("echo built") }
        try? await Task.sleep(for: .milliseconds(1200))

        #expect(
            install.resumeCheck.askedTheModel == false,
            """
            the resume check went on to ask where the reader "really" is while the install \
            was running, and its verdict then moved the step index under the drive loop — \
            "Iris moved WhimprFlow from step 11 back to the CMake step, entered the manual \
            CMake gate, and parked with readerMustManuallyContinue=true"
            """
        )
        #expect(
            install.controller.positionWasCorrectedExplanation == nil,
            "and it must not tell the reader it moved them, because it must not have"
        )
    }
}
