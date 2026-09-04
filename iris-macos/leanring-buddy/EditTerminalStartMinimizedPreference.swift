//
//  EditTerminalStartMinimizedPreference.swift
//  leanring-buddy
//
//  "There should be a setting where the terminal is auto minimized, in settings
//  tab" (Publik Test 2, 2026-09-03). When it is on, an on-demand EDIT run does
//  not raise the centered terminal takeover over the reader's screen — the run
//  starts minimized, showing only the compact running card in the eye bar (with
//  its "Show terminal" button, `reopenOnDemandEditTakeoverTerminal`, for when the
//  reader does want to watch). The edit still runs; it just does not take over
//  the screen to do it.
//
//  SCOPED TO ON-DEMAND EDITS, not guide installs. A guide can PARK on a manual
//  step and needs its terminal in view for the reader to act on it, and a guide
//  keeps a terminal inline after a minimize anyway; an on-demand edit has no
//  manual gates and no inline terminal, so "start minimized" is unambiguous for
//  it and is exactly the surface the reader asked to be able to get out of the
//  way. Reopening a minimized edit terminal is the affordance that makes this
//  safe to default-off-but-offer.
//
//  Backed by `UserDefaults` and `nonisolated`, mirroring `AutopilotAutonomyGrant`:
//  one small bool read where the run is presented and written from the settings
//  panel, with `UserDefaults`'s own synchronization.
//

import Foundation

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

    /// Whether an on-demand edit should start with its terminal minimized.
    /// Defaults to `false` for a key that was never written — the centered
    /// takeover is the established behaviour, and this is an opt-in.
    var startsMinimized: Bool {
        userDefaults.bool(forKey: Self.defaultsKey)
    }

    func setStartsMinimized(_ startsMinimized: Bool) {
        userDefaults.set(startsMinimized, forKey: Self.defaultsKey)
    }
}
