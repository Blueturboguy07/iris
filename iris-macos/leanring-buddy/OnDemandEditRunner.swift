//
//  OnDemandEditRunner.swift
//  leanring-buddy
//
//  The "watch it work" surface for a user-initiated on-demand edit, built so
//  the existing eye→terminal takeover can visualize the run WITHOUT faking a
//  guide.
//
//  The takeover (GuideAutopilotTakeoverController) and the terminal it grows
//  out of (GuideAutopilotTerminalView) are the exact experience an on-demand
//  edit wants — the eye morphs into a Terminal window, streams the work, and
//  folds back on completion. But both are wired 1:1 to GuideAutopilotRunner's
//  guide-shaped step model. There were two ways to reuse them (design §2):
//  (a) fake a synthetic one-step "guide", or (b) build a lightweight runner
//  that exposes the SAME published surface the terminal view binds to and
//  present it through the same controller. (a) couples the tool to guide
//  semantics and pollutes guide analytics/step-completion; (b) is a clean
//  adapter over an already-generic renderer. This is (b).
//
//  It is deliberately NOT the full autopilot state machine: an on-demand edit
//  has no risk-gated per-command confirm loop, no fix ladder, no dev servers.
//  The jailed ReAct loop lives inside MaintainTierCFixer and is a black box to
//  the UI — so this runner NARRATES the coordinator's phases (locating source,
//  building + testing, the finished diff) into the transcript as Iris's own
//  prose and a single verification result line. It never fabricates shell
//  commands that did not run — that would be dishonest theater — so it uses
//  `.explanation` rows (Iris talking) and one real `.exitStatus`, not fake
//  `.commandFromTheGuide` rows.
//

import Combine
import Foundation

/// The exact binding surface `GuideAutopilotTerminalView` reads off its runner:
/// the transcript, the coarse state, and whether a command is live (drives the
/// blinking cursor). Both `GuideAutopilotRunner` and `OnDemandEditRunner`
/// satisfy it, so the UI stage can generalize the terminal view + takeover
/// controller over `some AutopilotTerminalPresenting` instead of the concrete
/// `GuideAutopilotRunner`, and the on-demand run reuses the renderer untouched.
///
/// (The UI/wiring stage adds `: AutopilotTerminalPresenting` to
/// `GuideAutopilotRunner` — a one-line, no-behavior-change conformance, since
/// it already publishes all three — and changes `GuideAutopilotTerminalView`
/// and `GuideAutopilotTakeoverController.present` to bind the protocol.)
@MainActor
protocol AutopilotTerminalPresenting: ObservableObject {
    var state: GuideAutopilotState { get }
    var transcript: [GuideAutopilotTranscriptEntry] { get }
    var isExecutingACommand: Bool { get }
}

@MainActor
final class OnDemandEditRunner: ObservableObject, AutopilotTerminalPresenting {

    // MARK: - The published surface the terminal view binds to

    @Published private(set) var state: GuideAutopilotState = .notStarted
    @Published private(set) var transcript: [GuideAutopilotTranscriptEntry] = []
    /// True while the jailed loop / verification build is in flight, so the
    /// terminal shows a live blinking cursor rather than a dead prompt.
    @Published private(set) var isExecutingACommand: Bool = false

    // MARK: - Narration the coordinator drives

    /// Open the run: a heading naming the app and the kind of change, then a
    /// first line of Iris's prose. Puts the runner into the running state so the
    /// terminal reads as active work (not a finished/idle surface).
    func beginRun(appName: String, kind: OnDemandEditKind) {
        transcript.removeAll()
        let heading = kind == .feature
            ? "Adding a feature to \(appName)"
            : "Fixing a bug in \(appName)"
        transcript.append(.stepHeading(stepTitle: heading, stepNumber: 1, totalSteps: 1))
        state = .running(stepIndex: 0)
        isExecutingACommand = true
    }

    /// One line of Iris talking to the reader, in prose (never mono) — the
    /// same voice the autopilot uses for its own sentences, so the reader can
    /// always tell Iris from the machine.
    func note(_ prose: String) {
        transcript.append(.explanation(text: prose))
    }

    /// The single honest verification result line for the whole edit: the
    /// engine ran the build and (when the stack has one) the suite behind the
    /// black box; this is the one exit-status row that reports whether that
    /// gate went green.
    func recordVerificationResult(passed: Bool, over duration: TimeInterval) {
        // 0 is "green"; 1 is the conventional "the gate blocked" code. The
        // terminal renders it exactly like a real command's exit line.
        transcript.append(.exitStatus(code: passed ? 0 : 1, duration: duration))
    }

    /// Flip the live-cursor state. The coordinator holds it true across the
    /// engine call and drops it the moment the black box returns.
    func setWorking(_ working: Bool) {
        isExecutingACommand = working
    }

    /// The edit landed on a branch and is ready for the reader to review. The
    /// terminal keeps showing the transcript; the diff preview and the
    /// apply/discard choice live in the coordinator's own card, not here — the
    /// guide-shaped "Your turn" surface row does not fit an on-demand edit, so
    /// this uses `.finishedAllSteps`, which the terminal renders as plain
    /// finished output.
    func finishApplied() {
        isExecutingACommand = false
        state = .finishedAllSteps
    }

    /// The run ended without a kept change — out of budget, a blocked
    /// build-script edit, failed verification, or the reader discarding the
    /// diff. `.stopped` renders as plain finished output with no guide-shaped
    /// retry buttons; the reason is already an `.explanation` row above it.
    func finishStopped() {
        isExecutingACommand = false
        state = .stopped
    }
}
