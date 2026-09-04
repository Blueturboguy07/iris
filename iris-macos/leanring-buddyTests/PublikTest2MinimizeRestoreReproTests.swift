//
//  PublikTest2MinimizeRestoreReproTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "Minimize button works, but I can't get the terminal back up
//  after I minimize it."
//
//  THE FIELD REPORT (cofounder's Mac, Iris 0.9.8, 2026-09-03, mid WhimprFlow
//  edit): the Test 9/10 round made the takeover terminal's yellow light a real
//  minimize that folds the window away while the run keeps going. For a GUIDE
//  install that is fine — the guide keeps a terminal inline under its step card.
//  For an ON-DEMAND EDIT there is no inline terminal: after a minimize the only
//  surface left is a compact status card (spinner + a Stop button), and NOTHING
//  anywhere re-presents the centered terminal. The minimize was a one-way trip.
//
//  THE FIX has two halves:
//   1. `CompanionManager.reopenOnDemandEditTakeoverTerminal()` re-presents the
//      takeover — safe because the minimize fully dismissed the controller, so
//      its "no second present" guard now passes, and the run never stopped.
//   2. It is gated: only while an edit is actually RUNNING is there a live run
//      for a terminal to show. The gate is the pure
//      `aMinimizedOnDemandEditTerminalMayBeReopened(whileEditPhaseIs:)`, which
//      the running card's new "Show terminal" button rides on.
//
//  The re-present MECHANISM (the controller raising the same generic takeover
//  again after a minimize) is already proven for both the guide and the
//  on-demand runner by `Bug2TakeoverMinimizeReproTests`. This file covers the
//  part that was missing: the CALLER that invokes it for an on-demand edit, and
//  the rule that gates it.
//

import Foundation
import Testing
@testable import Iris

@Suite(.serialized)
@MainActor
struct PublikTest2MinimizeRestoreReproTests {

    // MARK: - The gate: a terminal is only worth reopening while a run is live

    /// While an edit is running there is a live run to show, so the minimized
    /// terminal may be reopened.
    @Test func aRunningEditMayReopenItsMinimizedTerminal() {
        #expect(
            CompanionManager.aMinimizedOnDemandEditTerminalMayBeReopened(whileEditPhaseIs: .running),
            "a running edit is exactly when the reader wants the terminal back, and it was refused"
        )
    }

    /// Every phase that is not a live run draws its OWN surface in the bar — a
    /// consent, the committed-diff preview, the finished result — and has no
    /// terminal to reopen. Reopening in those phases would raise an empty
    /// takeover over a run that is not happening.
    @Test func aNonRunningEditNeverReopensATerminal() {
        let phasesWithNoLiveRun: [OnDemandEditPhase] = [
            .pickApp,
            .describe,
            .clarifying,
            .presentingPlan,
            .awaitingStartConsent,
            .previewDiff,
            .committing,
            .awaitingManifestConsent,
            .awaitingMachineCommandConsent,
            .delivering,
            .awaitingSymptomConfirmation,
            .awaitingRelaunchConsent,
            .relaunching,
            .awaitingForceQuitConsent,
            .done,
            .failed(reason: "anything"),
            .notEligible(reason: "anything"),
            .blockedByModel(explanation: "anything"),
        ]
        for phase in phasesWithNoLiveRun {
            #expect(
                !CompanionManager.aMinimizedOnDemandEditTerminalMayBeReopened(whileEditPhaseIs: phase),
                "phase \(phase) has no live run, but was told it could reopen a terminal"
            )
        }
    }

    // MARK: - The mechanism, for the on-demand runner specifically

    /// The report's own case: an on-demand edit takeover, minimized, must be able
    /// to come back. Driven through the REAL `GuideAutopilotTakeoverController`
    /// over the REAL `OnDemandEditRunner` — the same objects
    /// `reopenOnDemandEditTakeoverTerminal` uses — proving the re-present the
    /// fix's caller performs actually raises the window again after a minimize.
    ///
    /// Asserts on `isPresented` only (not window geometry), so it stays cheap and
    /// robust; the geometry/click plumbing is `Bug2TakeoverMinimizeReproTests`'s
    /// job.
    @Test func theOnDemandEditTakeoverComesBackAfterAMinimize() async throws {
        let controller = GuideAutopilotTakeoverController()
        let runner = OnDemandEditRunner()
        runner.beginRun(appName: "whimprflow", kind: .feature)

        func presentIt() {
            controller.present(
                runner: runner,
                onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
                onRetrySurfacedStep: {}, onContinuePastSurfacedStep: {},
                onReaderFinishedManualStep: {}, onEscapeHatch: {}
            )
        }

        presentIt()
        #expect(controller.isPresented, "the on-demand takeover never came up to begin with")

        // Minimize: fold it away. `dismiss` tears the panels down asynchronously.
        controller.dismiss(afterHold: false)
        let folded = await pump(within: 6) { !controller.isPresented }
        #expect(folded, "the takeover never folded away when minimized, so 'came back' can't be told from 'never left'")

        // Reopen — what `reopenOnDemandEditTakeoverTerminal()` does once the run
        // is still `.running`. Before the fix nothing called this for an
        // on-demand edit, so the terminal was gone for good.
        presentIt()
        let cameBack = await pump(within: 6) { controller.isPresented }
        #expect(
            cameBack,
            "after the reader minimized it, the on-demand edit takeover could not be raised again"
        )

        controller.dismiss(afterHold: false)
    }

    /// Polls `condition` up to `seconds`, yielding between checks, so an
    /// asynchronous present/dismiss has time to settle without a fixed sleep.
    private func pump(within seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return condition()
    }
}
