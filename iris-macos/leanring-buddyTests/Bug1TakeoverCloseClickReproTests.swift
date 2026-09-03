//
//  Bug1TakeoverCloseClickReproTests.swift
//  leanring-buddyTests
//
//  BUG 1 — "Terminal Close (red light) and Help do nothing."
//
//  THE FIELD REPORT (cofounder's Mac, Iris 0.9.6 build 22 = Test 9, and again
//  on 0.9.7 build 23 = Test 10): in the takeover terminal — the "iris — install"
//  window with the three traffic lights and the Help pill — the red light and
//  the Help pill never fire, in BOTH takeovers: the guide install
//  (`GuideAutopilotRunner`) and the on-demand edit (`OnDemandEditRunner`).
//  It is reported AFTER commit 9c12317 ("Test 8: make the takeover buttons
//  clickable"), which fixed Try again / Continue past it / Run it — so whatever
//  is wrong is NOT the drag-vs-click frame reporting that fix installed.
//
//  WHAT THE EVIDENCE DOES AND DOES NOT SAY. Neither runtime log carries
//  click-level proof, and both say so themselves — the 0.9.7 log: "The runtime
//  does not prove whether the embedded terminal's close or minimize controls
//  accepted clicks … The original Test 10 notes and screenshots remain the
//  evidence for that UI behavior." What the logs DO give is the exact run the
//  reader was staring at when they went for the red light, and this file
//  replays both of them into the real objects rather than inventing a scenario:
//
//    - Test 10 (0.9.7): the third WhimprFlow on-demand edit, 2026-09-02
//      11:52:51 → 11:55:48 PT — memory + answered-block injection, the real
//      jailed `find`/`sed`/`grep` commands at exit 0, five source files edited,
//      then `verifying: build=(cd 'ui' && pnpm build) && cargo build …`,
//      verification failed, and the BLOCKED sentence about esbuild being
//      unapproved in the pnpm store. Replayed through the REAL
//      `OnDemandEditRunner` — the same object the field build renders that run
//      with — using the same calls the coordinator makes.
//
//    - Test 9 (0.9.6): the kneecap guide parked on step 6 `install-deps`
//      (`bun install`) after the stale-PATH exit 127 at 06:59:45Z, which is
//      what put the terminal into `.surfacedToReader` with the "Your turn" row
//      the reader then tapped Try again on twice (07:00:07Z, 07:00:21Z).
//
//  And ALREADY IN THE REPO, out of band: `tools/takeover-click-harness/README.md`
//  records, from a real-`CGEvent` run through the window server, that "The red
//  escape-hatch traffic light … did NOT fire its action in this harness on
//  either the real-`CGEvent` path or the in-process `sendEvent` path, even
//  though `pressLandsOnAControl` is true for it and the window does not move."
//  That is this bug, logged there as an unexplained open item.
//
//  WHY THESE TESTS ARE SHAPED THE WAY THEY ARE. The panel-level dispatch is
//  already correct and `Test8TakeoverControlClickTests` already proves the
//  in-process click path fires a takeover button — so a test that only clicked
//  the red light and reported "it did not fire" could not tell this bug apart
//  from a broken harness. Every test here therefore carries its own control:
//  `theRedLightIsDeadWhileTheTryAgainBesideItWorks` clicks BOTH controls in the
//  SAME window with the SAME delivery, and the mechanism test compares the red
//  light against bare title-strip background in the same hit test. The clicks
//  are delivered as windowed `NSEvent`s carrying the panel's own
//  `windowNumber`, which is the `event.window != nil` branch a hardware click
//  takes (see `Test8TakeoverControlClickTests.deliverAWindowedDriftingClick`),
//  and each control is clicked TWICE — once with a real finger's 4pt drift and
//  once dead centre with none — so "the press drifted" (the Test-8 bug, already
//  fixed) cannot be the explanation for a control that stays dead.
//

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Iris

/// The guide side of the report, parked exactly where Test 9 left it: kneecap
/// step 6 `install-deps` surfaced to the reader after `bun install` returned
/// exit 127 against process 51270's stale 16-directory PATH. That state is what
/// draws the "Your turn" row, whose "Try again" is this file's control: it has
/// no `.nativeTooltip`, it is the button commit 9c12317 made work, and it is
/// the button the reader really did tap in the field.
///
/// A presenter rather than a real `GuideAutopilotRunner` because the terminal
/// binds to exactly these three published properties (`AutopilotTerminalPresenting`)
/// and nothing else, while driving a real runner into `.surfacedToReader` would
/// need a real pty login shell and a real model round trip — neither of which
/// this bug is about, and both of which would make a click test flaky. The
/// takeover, the panel, the terminal view, the buttons and the events are all
/// real.
@MainActor
private final class KneecapSurfacedAtInstallDeps: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .surfacedToReader(
        diagnosis: "bun is not on this shell's PATH, so `bun install` could not run.",
        failingCommand: "bun install"
    )
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Install dependencies", stepNumber: 6, totalSteps: 9),
        .commandFromTheGuide(text: "cd ~/kneecap"),
        .exitStatus(code: 0, duration: 0.1),
        .commandFromTheGuide(text: "bun install"),
        .output(line: "zsh: command not found: bun"),
        .exitStatus(code: 127, duration: 0.1),
        .explanation(text: "Iris could not finish this step on its own.")
    ]
    @Published var isExecutingACommand: Bool = false
}

/// Whether the ask bar's doorbell rang. A reference box because the observer
/// closure that sets it escapes into `NotificationCenter`.
private final class AskBarSummons: @unchecked Sendable {
    var wasRung = false
}

@MainActor
@Suite(.serialized) struct Bug1TakeoverCloseClickReproTests {

    private typealias Panel = GuideAutopilotTakeoverTerminalPanel

    /// How long the takeover's entry morph plus SwiftUI's preference plumbing
    /// need before the reported control frames describe where the buttons
    /// actually are. The value `Test8TakeoverControlClickTests` settles on.
    private static let settleNanoseconds: UInt64 = 1_500_000_000

    /// The 24pt title strip the red light and the Help pill live in.
    /// `heightOfTheTitleStrip` is private to the panel, so it is spelled out
    /// here the way Test8 spells it out.
    private static let heightOfTheTitleStrip: CGFloat = 24

    // MARK: - Driving the real window

    /// Polls a main-actor condition instead of sleeping a fixed amount: the
    /// takeover animates on its own clock, so a fixed sleep is a coin flip on a
    /// loaded machine (Test7's lesson, kept by Test8).
    private static func pump(
        within seconds: Double = 10, until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    /// Lets the main run loop turn for a moment without asserting anything —
    /// the gap a second click needs so it is not read as a double-click, and
    /// the turn SwiftUI needs to run a button's action.
    private static func letTheRunLoopTurn(forSeconds seconds: Double) async {
        _ = await pump(within: seconds) { false }
    }

    /// One click on a reported control frame, delivered the way a HARDWARE
    /// click arrives: a windowed `NSEvent` carrying the terminal panel's own
    /// `windowNumber`, so `event.window` resolves to the panel and its
    /// `sendEvent` reads the press through the `event.window != nil` branch —
    /// the branch a real click takes, not the `windowNumber: 0` seam the drag
    /// tests use to drive travel without a physical mouse.
    ///
    /// `driftInPoints` is how far the pointer travels between the finger going
    /// down and coming up. 4pt is past the panel's 3pt slop (what the Test-8
    /// bug turned into a window move); 0pt is the pedantically perfect click
    /// that drift cannot explain away. A control that answers neither is dead.
    private static func deliverAClick(
        to terminal: Panel, onControlFrame controlFrame: CGRect, driftInPoints: CGFloat
    ) {
        // The frames are content-view coordinates (top-left origin, y down —
        // SwiftUI `.global` inside the hosting view that IS the content view);
        // an event's `locationInWindow` is window coordinates (bottom-left
        // origin), so the y flips through the window height.
        let downInWindow = CGPoint(
            x: controlFrame.midX, y: terminal.frame.height - controlFrame.midY
        )
        let upInWindow = CGPoint(
            x: controlFrame.midX + driftInPoints,
            y: terminal.frame.height - (controlFrame.midY + driftInPoints)
        )
        func windowedEvent(_ type: NSEvent.EventType, at location: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: terminal.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            )
        }
        if let down = windowedEvent(.leftMouseDown, at: downInWindow) { terminal.sendEvent(down) }
        if let up = windowedEvent(.leftMouseUp, at: upInWindow) { terminal.sendEvent(up) }
    }

    /// A real finger's drifting click, then a dead-centre one, with a run-loop
    /// turn between them. Both, because the whole point of clicking twice is to
    /// rule the Test-8 drift bug out as the explanation for what is still
    /// broken.
    private static func clickTheControlBothWays(
        to terminal: Panel, onControlFrame controlFrame: CGRect
    ) async {
        deliverAClick(to: terminal, onControlFrame: controlFrame, driftInPoints: 4)
        await letTheRunLoopTurn(forSeconds: 1)
        deliverAClick(to: terminal, onControlFrame: controlFrame, driftInPoints: 0)
        await letTheRunLoopTurn(forSeconds: 0.5)
    }

    /// The frame the terminal reported for the red escape-hatch traffic light:
    /// inside the 24pt title strip, on the LEFT (it is the first thing in the
    /// strip's `HStack`, at a 22pt hit target). The Help pill is the other
    /// title-strip control and sits hard against the RIGHT edge, so left/right
    /// tells them apart without reaching into the view's private geometry.
    private static func escapeHatchFrame(reportedBy terminal: Panel) throws -> CGRect {
        let inTheTitleStrip = terminal.interactiveControlFrames
            .filter { $0.minY < heightOfTheTitleStrip }
            .sorted { $0.minX < $1.minX }
        let leftmost = try #require(
            inTheTitleStrip.first,
            """
            no control reported a frame inside the 24pt title strip — the red light and Help \
            should both be there; without their frames this test cannot aim at them
            """
        )
        #expect(
            leftmost.minX < terminal.frame.width / 2,
            """
            the leftmost title-strip control reported at \(leftmost) is not on the left half of a \
            \(terminal.frame.width)pt-wide card, so it is probably not the red light
            """
        )
        return leftmost
    }

    /// The frame the terminal reported for the Help pill — the right-hand
    /// control in the title strip.
    private static func helpButtonFrame(reportedBy terminal: Panel) throws -> CGRect {
        let inTheTitleStrip = terminal.interactiveControlFrames
            .filter { $0.minY < heightOfTheTitleStrip }
            .sorted { $0.minX < $1.minX }
        try #require(
            inTheTitleStrip.count >= 2,
            """
            only \(inTheTitleStrip.count) control(s) reported a frame in the title strip — the \
            red light AND the Help pill should both be there
            """
        )
        let rightmost = try #require(inTheTitleStrip.last)
        #expect(
            rightmost.minX > terminal.frame.width / 2,
            """
            the rightmost title-strip control reported at \(rightmost) is not on the right half \
            of a \(terminal.frame.width)pt-wide card, so it is probably not the Help pill
            """
        )
        return rightmost
    }

    /// Waits out the entry morph and the preference plumbing, so the reported
    /// frames describe a laid-out window rather than one still growing out of
    /// the eye.
    private static func waitForTheTakeoverToFinishOpening(_ terminal: Panel) async throws {
        try #require(
            await pump { terminal.frame.width > 700 },
            "the takeover never grew to its terminal size — nothing laid out to click yet"
        )
        try await Task.sleep(nanoseconds: settleNanoseconds)
        try #require(
            await pump {
                terminal.interactiveControlFrames
                    .filter { $0.minY < heightOfTheTitleStrip }.count >= 2
            },
            """
            the title strip's two controls (the red escape hatch and the Help pill) never \
            reported their frames to the panel
            """
        )
    }

    /// Finds the terminal panel the controller just raised.
    private static func terminalPanelRaised(
        after windowsBefore: Set<ObjectIdentifier>
    ) throws -> Panel {
        try #require(
            NSApplication.shared.windows
                .compactMap { $0 as? Panel }
                .first { !windowsBefore.contains(ObjectIdentifier($0)) },
            "the takeover must raise its own terminal panel subclass"
        )
    }

    // MARK: - The field run, replayed into the real runner

    /// Test 10's third WhimprFlow edit run, 2026-09-02 11:52:51 → 11:55:48 PT,
    /// as the edit-run log records it and through the same `OnDemandEditRunner`
    /// calls `OnDemandEditCoordinator` makes: the memory and answered-block
    /// injections, the real jailed commands the model ran (all exit 0), the
    /// five edited source files, the derived verification command, its failure,
    /// and the BLOCKED sentence the run ended on.
    ///
    /// It ends with `finishStopped()` — the runner call a blocked-and-reverted
    /// run really makes — because that is the state the takeover was left
    /// sitting in: the run over, the transcript still up, and the reader
    /// reaching for the red light to get rid of it.
    private static func replayTheTest10WhimprFlowEditRun(into runner: OnDemandEditRunner) {
        runner.beginRun(appName: "whimprflow", kind: .feature)
        runner.note("memory: 3 prior run(s) injected")
        runner.note("retry: 1 answered block(s) injected")
        runner.note("runtime evidence: its recent log output")

        runner.note(
            "Inspecting the settings and local-model paths to find the smallest existing "
                + "extension point for improving transcription quality."
        )
        runner.recordExecutedCommand("find . -maxdepth 4 -type f | sort")
        runner.recordCommandOutputTail([
            "./ui/src/overlay/main.tsx",
            "./ui/src/tokens/values.ts",
            "./ui/tsconfig.json",
            "./ui/vite.config.ts"
        ])
        runner.recordCommandExit(exitCode: 0, duration: 0.1)

        runner.note(
            "Reading the settings, transcription engine, and local worker code to identify the "
                + "existing model-selection and CLI integration patterns."
        )
        runner.recordExecutedCommand(
            "sed -n '1,260p' crates/whimpr-core/src/settings.rs; "
                + "sed -n '1,280p' crates/whimpr-asr/src/lib.rs; "
                + "sed -n '1,260p' src-tauri/src/local_llm.rs; "
                + "sed -n '1,320p' ui/src/hub/SettingsPane.tsx; sed -n '1,240p' ui/src/hub/api.ts"
        )
        runner.recordCommandOutputTail([
            "} catch {", "/* browser preview — no-op */", "}", "}"
        ])
        runner.recordCommandExit(exitCode: 0, duration: 0.1)

        runner.note(
            "Tracing where the Whisper model path is chosen so the quality control changes "
                + "transcription rather than the separate cleanup model."
        )
        runner.recordExecutedCommand(
            "grep -R \"WhisperEngine::load|whisper_model_path|model_path()\" -n src-tauri/src "
                + "crates --exclude-dir=target; sed -n '1,180p' crates/whimpr-asr/src/lib.rs"
        )
        runner.recordCommandOutputTail([
            "{LEVELS.map((l) => {",
            "const selected = settings.cleanup_level === l.value;",
            "return ("
        ])
        runner.recordCommandExit(exitCode: 0, duration: 0.1)

        runner.note(
            "file edits applied: edited crates/whimpr-core/src/settings.rs; "
                + "edited src-tauri/src/hotkey.rs; edited src-tauri/src/win.rs; "
                + "edited ui/src/hub/api.ts; edited ui/src/hub/SettingsPane.tsx"
        )
        runner.note(
            "changed: crates/whimpr-core/src/settings.rs, src-tauri/src/hotkey.rs, "
                + "src-tauri/src/win.rs, ui/src/hub/SettingsPane.tsx, ui/src/hub/api.ts"
        )
        runner.note(
            "Added a visible transcription-model selector in Settings, persisted it compatibly, "
                + "and wired macOS and Windows to load the chosen installed Whisper model with "
                + "automatic fallback."
        )
        runner.note(
            "verifying: build=(cd 'ui' && pnpm build) && cargo build --release "
                + "--manifest-path src-tauri/Cargo.toml, tests=none"
        )
        runner.recordVerificationResult(passed: false, over: 1.7)
        runner.note("verification failed (build) — repair round begins (1 left)")
        runner.recordExecutedCommand(
            "cat ui/package.json; sed -n '1,120p' ui/pnpm-workspace.yaml; "
                + "grep -n \"ERR_PNPM|ignored-build|pnpm build|pnpm install\" README.md"
        )
        runner.recordCommandOutputTail([
            "50:cd ui && pnpm install && cd ..",
            "51:# If pnpm reports [ERR_PNPM_IGNORED_BUILDS] (esbuild's postinstall was"
        ])
        runner.recordCommandExit(exitCode: 0, duration: 0.1)
        runner.note(
            "BLOCKED: pnpm fails its dependency-status preflight before compiling any source "
                + "because esbuild is unapproved in the global pnpm store; run "
                + "`cd ui && pnpm approve-builds --all` and retry verification."
        )
        runner.finishStopped()
    }

    // MARK: - THE REPRO: the on-demand edit takeover (Test 10)

    /// "Terminal Close (red light) … does nothing", on the on-demand edit
    /// takeover the Test-10 reader was looking at: the WhimprFlow feature run
    /// that ended BLOCKED on the esbuild preflight at 11:55:48 PT, with the
    /// terminal still on screen and no way out of it.
    ///
    /// The red light is `GuideAutopilotTerminalView.escapeHatchTrafficLight`,
    /// whose action is the `onEscapeHatch` closure `present(...)` is handed —
    /// which on this path is `CompanionManager`'s `stopRunningEdit()` plus
    /// `dismiss(afterHold: false)`. This asserts that closure runs. It does not
    /// run today: the click never reaches SwiftUI's button.
    @Test func theRedLightClosesTheOnDemandEditTakeover() async throws {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = OnDemandEditRunner()
        var theEscapeHatchFired = false
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {},
            onEscapeHatch: { theEscapeHatchFired = true }
        )
        defer { controller.dismiss(afterHold: false) }
        Self.replayTheTest10WhimprFlowEditRun(into: runner)

        let terminal = try Self.terminalPanelRaised(after: windowsBefore)
        try await Self.waitForTheTakeoverToFinishOpening(terminal)
        let redLight = try Self.escapeHatchFrame(reportedBy: terminal)

        let originBeforeTheClick = terminal.frame.origin
        await Self.clickTheControlBothWays(to: terminal, onControlFrame: redLight)

        #expect(
            await Self.pump(within: 3) { theEscapeHatchFired },
            """
            the red traffic light at \(redLight) never ran its action, after a 4pt-drifting click \
            AND a dead-centre one — "Terminal Close (red light) … do nothing". The window did not \
            move either (it is at \(terminal.frame.origin), started at \(originBeforeTheClick)), \
            so this is not the Test-8 drag-vs-click bug commit 9c12317 fixed: the press reaches \
            the panel, is correctly recognised as landing on a control, and is then swallowed \
            before SwiftUI's Button ever sees it
            """
        )
        // Named separately so a regression that reintroduces the Test-8 drag
        // cannot hide inside the assertion above.
        #expect(
            terminal.frame.origin == originBeforeTheClick,
            """
            clicking the red light moved the terminal to \(terminal.frame.origin) instead of \
            leaving it at \(originBeforeTheClick)
            """
        )
    }

    /// "…and Help do nothing", same window, same run. Help is the reader's only
    /// door onto an answer while a takeover covers the screen: it posts
    /// `.clickySummonAskBar` through `GuideAutopilotHelpRequest`, which opens
    /// the ask bar under the eye with the step and the real terminal output
    /// already attached. Nothing is posted today.
    @Test func theHelpPillOpensTheAskBarFromTheOnDemandEditTakeover() async throws {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = OnDemandEditRunner()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        defer { controller.dismiss(afterHold: false) }
        Self.replayTheTest10WhimprFlowEditRun(into: runner)

        // Help does not run a closure the takeover hands it — it posts the same
        // notification the summon hotkey does — so the ask bar's own doorbell
        // is what this listens for.
        let askBarSummons = AskBarSummons()
        let observer = NotificationCenter.default.addObserver(
            forName: .clickySummonAskBar, object: nil, queue: .main
        ) { _ in askBarSummons.wasRung = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        let terminal = try Self.terminalPanelRaised(after: windowsBefore)
        try await Self.waitForTheTakeoverToFinishOpening(terminal)
        let helpPill = try Self.helpButtonFrame(reportedBy: terminal)

        let originBeforeTheClick = terminal.frame.origin
        await Self.clickTheControlBothWays(to: terminal, onControlFrame: helpPill)

        #expect(
            await Self.pump(within: 3) { askBarSummons.wasRung },
            """
            the Help pill at \(helpPill) never posted clickySummonAskBar, after a 4pt-drifting \
            click AND a dead-centre one — "Help do nothing". The window did not move either (it \
            is at \(terminal.frame.origin), started at \(originBeforeTheClick)), so the press is \
            being swallowed rather than taken as a drag. A reader stuck under a takeover has no \
            other way to ask
            """
        )
        #expect(
            terminal.frame.origin == originBeforeTheClick,
            """
            clicking Help moved the terminal to \(terminal.frame.origin) instead of leaving it \
            at \(originBeforeTheClick)
            """
        )
    }

    // MARK: - THE DISCRIMINATOR: the guide takeover (Test 9)

    /// The report is "Close and Help do nothing" — not "the terminal's buttons
    /// do nothing". The same window's Try again works, which is what makes this
    /// a real, narrow defect rather than a broken click path, and what makes a
    /// test that only clicks the red light untrustworthy on its own.
    ///
    /// So: one window, the kneecap guide parked exactly where Test 9 left it
    /// (step 6 `install-deps`, `bun install` exit 127 under the stale PATH,
    /// surfaced to the reader), and the SAME delivery aimed at both controls.
    /// "Try again" — the button the reader really did tap twice at 07:00:07Z
    /// and 07:00:21Z — must fire; the red light a few points above it must fire
    /// too. Today only the first one does.
    @Test func theRedLightIsDeadWhileTheTryAgainBesideItWorks() async throws {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = KneecapSurfacedAtInstallDeps()
        var theEscapeHatchFired = false
        var theReaderRetriedTheStep = false
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: { theReaderRetriedTheStep = true },
            onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {},
            onEscapeHatch: { theEscapeHatchFired = true }
        )
        defer { controller.dismiss(afterHold: false) }

        let terminal = try Self.terminalPanelRaised(after: windowsBefore)
        try await Self.waitForTheTakeoverToFinishOpening(terminal)

        // "Try again" is the rightmost control BELOW the title strip (the
        // surfaced row is "Continue past it" on the left, the primary pill on
        // the right) — the same identification Test8 makes.
        let surfacedRowButtons = terminal.interactiveControlFrames
            .filter { $0.minY >= Self.heightOfTheTitleStrip }
            .sorted { $0.minX < $1.minX }
        try #require(
            surfacedRowButtons.count >= 2,
            "the 'Your turn' row's two buttons never reported their frames below the title strip"
        )
        let tryAgain = try #require(surfacedRowButtons.last)
        let redLight = try Self.escapeHatchFrame(reportedBy: terminal)

        // The control first: if this fails, the harness is broken and nothing
        // below it means anything.
        await Self.clickTheControlBothWays(to: terminal, onControlFrame: tryAgain)
        try #require(
            await Self.pump(within: 3) { theReaderRetriedTheStep },
            """
            "Try again" at \(tryAgain) did not fire either, so this run proves nothing about the \
            red light — the click delivery itself is broken and must be fixed before this test \
            can speak. (Commit 9c12317 made this button work; \
            Test8TakeoverControlClickTests.aDriftingClickFiresTheSurfacedRowButtonsActions \
            asserts the same thing.)
            """
        )

        await Self.clickTheControlBothWays(to: terminal, onControlFrame: redLight)
        #expect(
            await Self.pump(within: 3) { theEscapeHatchFired },
            """
            the red traffic light at \(redLight) never ran its action, in the very same window \
            where the identical click on "Try again" at \(tryAgain) just did. Both are plain \
            SwiftUI Buttons carrying .reportsFrameAsATakeoverControl(), both had their frames \
            reported, both presses were recognised by pressLandsOnAControl and handed to \
            super.sendEvent — the only thing separating them is what is stacked on top of them \
            in the view hierarchy
            """
        )
    }

    // MARK: - THE MECHANISM: what the click actually lands on

    /// Why the red light is dead, in one hit test, so the fix is aimed at the
    /// cause rather than at the symptom.
    ///
    /// A SwiftUI `Button` has NO AppKit view of its own — the takeover panel
    /// says so in its own comment on `interactiveControlFrames`: "`hitTest` on
    /// the 'Try again' pill returns this window's `NSHostingView` exactly as it
    /// does for bare background (measured)". That is the whole reason the
    /// controls have to report their frames. So AppKit resolving a point over a
    /// button to something OTHER than what it resolves bare background to means
    /// a real, non-SwiftUI view is sitting on top of that button — and a view
    /// AppKit hands a `mouseDown` to is a view that has taken the click away
    /// from the button underneath.
    ///
    /// The reference is bare background in the SAME title strip: a point with
    /// no control on it at all, whose press AppKit resolves to the hosted view
    /// SwiftUI draws the whole card into — which is exactly what the panel's own
    /// comment measured. Anything the red light or Help resolves to that is NOT
    /// that view is the thing eating their clicks.
    ///
    /// It has to be bare background in that strip rather than "Try again" below
    /// it: the transcript is a SwiftUI `ScrollView`, which AppKit really does
    /// back with a scroll view and a document view, so a press down there lands
    /// on a different AppKit view than a press in the strip does — for reasons
    /// that have nothing to do with this bug.
    @Test func aPressOverTheRedLightLandsOnAViewThatBareBackgroundDoesNotHave() async throws {
        let windowsBefore = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = GuideAutopilotTakeoverController()
        let runner = KneecapSurfacedAtInstallDeps()
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
            onReaderFinishedManualStep: {}, onEscapeHatch: {}
        )
        defer { controller.dismiss(afterHold: false) }

        let terminal = try Self.terminalPanelRaised(after: windowsBefore)
        try await Self.waitForTheTakeoverToFinishOpening(terminal)
        let contentView = try #require(terminal.contentView)
        let redLight = try Self.escapeHatchFrame(reportedBy: terminal)
        let helpPill = try Self.helpButtonFrame(reportedBy: terminal)
        // Bare background in the title strip: the centre of the strip, between
        // the traffic lights on the left and the Help pill on the right, where
        // only the title text is drawn and no control reports a frame.
        let bareTitleStripBackground = CGPoint(
            x: terminal.frame.width / 2, y: Self.heightOfTheTitleStrip / 2
        )
        try #require(
            !terminal.interactiveControlFrames.contains { $0.contains(bareTitleStripBackground) },
            """
            \(bareTitleStripBackground) is inside a reported control frame, so it is not the \
            bare title-strip background this test needs as its reference
            """
        )

        /// `NSView.hitTest(_:)` takes a point in the view's SUPERVIEW space,
        /// which for a borderless window's content view is window coordinates
        /// (bottom-left origin) — so a point in the card (top-left origin)
        /// flips through the window height and goes in as-is.
        func whatAPressResolvesTo(at pointInTheCard: CGPoint) -> NSView? {
            contentView.hitTest(
                CGPoint(x: pointInTheCard.x, y: terminal.frame.height - pointInTheCard.y)
            )
        }
        /// What a view is, and the tooltip it carries if it carries one — the
        /// tooltip is the fingerprint that names WHICH overlay this is.
        func describe(_ view: NSView?) -> String {
            guard let view else { return "nothing" }
            let tooltip = view.toolTip.map { " carrying the tooltip \"\($0)\"" } ?? ""
            return "\(type(of: view))\(tooltip)"
        }

        let whatBareBackgroundResolvesTo = whatAPressResolvesTo(at: bareTitleStripBackground)
        let whatTheRedLightResolvesTo = whatAPressResolvesTo(
            at: CGPoint(x: redLight.midX, y: redLight.midY)
        )
        let whatHelpResolvesTo = whatAPressResolvesTo(
            at: CGPoint(x: helpPill.midX, y: helpPill.midY)
        )

        // The fingerprint first, because it names the culprit outright: the
        // view AppKit chose to hand the press to carries the escape hatch's own
        // tooltip text, so it is the inert `NSView` the `.nativeTooltip(…)`
        // overlay put on top of the button — not the button, and not anything
        // that will pass the press down to it.
        #expect(
            whatTheRedLightResolvesTo?.toolTip == nil,
            """
            the view AppKit resolved the red light's press to is carrying the red light's own \
            tooltip text, which makes it the inert NSView that .nativeTooltip(…) overlays the \
            button with — \(describe(whatTheRedLightResolvesTo)). A plain NSView does nothing \
            with a mouseDown, so the click stops there and the button underneath never sees it
            """
        )
        #expect(
            whatHelpResolvesTo?.toolTip == nil,
            """
            the same for Help: the press resolves to \(describe(whatHelpResolvesTo)), the inert \
            tooltip overlay rather than the button
            """
        )

        #expect(
            whatTheRedLightResolvesTo === whatBareBackgroundResolvesTo,
            """
            a press over the red traffic light resolves to \
            \(describe(whatTheRedLightResolvesTo)), while a press on the bare title-strip \
            background beside it resolves to \(describe(whatBareBackgroundResolvesTo)). \
            A SwiftUI Button contributes no AppKit view of its own, so both should land on the \
            same hosted view; a different one over the red light is an inert AppKit view stacked \
            on top of it, and AppKit hands that view the mouseDown instead of letting it reach \
            SwiftUI. That is the whole of "the red light does nothing"
            """
        )
        #expect(
            whatHelpResolvesTo === whatBareBackgroundResolvesTo,
            """
            a press over the Help pill resolves to \(describe(whatHelpResolvesTo)) rather than \
            the \(describe(whatBareBackgroundResolvesTo)) the bare title-strip background beside \
            it resolves to — the same kind of inert overlay that swallows the red light's click
            """
        )
    }
}
