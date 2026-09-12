//
//  EditTerminalStartMinimizedPreference.swift
//  leanring-buddy
//
//  "There should be a setting where the terminal is auto minimized, in settings
//  tab" (Publik Test 2, 2026-09-03). When it is on, a guide install or an
//  on-demand edit does not raise the centered terminal takeover over the
//  reader's screen. The run starts minimized and the compact workflow summary
//  carries its explicit "Show terminal" action. The run itself is unchanged.
//
//  The historical type name remains `EditTerminalStartMinimizedPreference` so
//  existing settings and test call sites keep their persisted key. The setting
//  now applies to both terminal workflows. A guide's manual or risky gate must
//  stay visible in its compact summary, and the explicit Show terminal action
//  can reopen the terminal when the reader needs its controls.
//
//  Backed by `UserDefaults` and `nonisolated`, mirroring `AutopilotAutonomyGrant`:
//  one small bool read where the run is presented and written from the settings
//  panel, with `UserDefaults`'s own synchronization.
//

import Foundation

/// The terminal workflows that share the one start-minimized setting.
nonisolated enum IrisTerminalWorkflow: Equatable {
    case guideInstall
    case onDemandEdit
}

/// Pure presentation policy kept separate from AppKit so the preference's
/// automatic-show and explicit-reopen contract can be tested without windows.
nonisolated enum TerminalStartMinimizedPolicy {
    static func shouldAutomaticallyPresent(
        workflow: IrisTerminalWorkflow,
        startsMinimized: Bool
    ) -> Bool {
        switch workflow {
        case .guideInstall, .onDemandEdit:
            return !startsMinimized
        }
    }
}

/// Pure ownership checks shared by the one visible terminal controller and its
/// offline tests. A workflow may present only into an empty slot and may dismiss
/// only its own terminal. Explicit switching still performs the actual animated
/// dismissal in the controller before presenting the queued workflow.
nonisolated enum TerminalTakeoverOwnershipPolicy {
    static func mayPresent(
        requestedWorkflow: IrisTerminalWorkflow,
        presentedWorkflow: IrisTerminalWorkflow?
    ) -> Bool {
        _ = requestedWorkflow
        return presentedWorkflow == nil
    }

    static func mayDismiss(
        requestedWorkflow: IrisTerminalWorkflow,
        presentedWorkflow: IrisTerminalWorkflow?
    ) -> Bool {
        presentedWorkflow == requestedWorkflow
    }

    static func shouldQueueDismissalFollowUp(
        requestedWorkflow: IrisTerminalWorkflow,
        presentedWorkflow: IrisTerminalWorkflow?,
        isDismissing: Bool
    ) -> Bool {
        isDismissing && mayDismiss(
            requestedWorkflow: requestedWorkflow,
            presentedWorkflow: presentedWorkflow
        )
    }
}

// `@unchecked Sendable` for the same reason as `AutopilotAutonomyGrant`: the one
// stored property is a `UserDefaults`, thread-safe but not marked `Sendable`.
nonisolated struct EditTerminalStartMinimizedPreference: @unchecked Sendable {

    /// The app-wide preference, over `UserDefaults.standard`.
    static let shared = EditTerminalStartMinimizedPreference()

    private static let defaultsKey = "iris:onDemandEdit:startTerminalMinimized"

    private let userDefaults: UserDefaults

    /// A real preference uses `.standard`; a test constructs one over an
    /// isolated suite so it never touches the reader's real setting.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Whether a guide install or on-demand edit should start minimized.
    /// Defaults to `false` for a key that was never written — the centered
    /// takeover is the established behaviour, and this is an opt-in.
    var startsMinimized: Bool {
        userDefaults.bool(forKey: Self.defaultsKey)
    }

    func setStartsMinimized(_ startsMinimized: Bool) {
        userDefaults.set(startsMinimized, forKey: Self.defaultsKey)
    }
}
