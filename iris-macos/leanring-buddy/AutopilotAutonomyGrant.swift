//
//  AutopilotAutonomyGrant.swift
//  leanring-buddy
//
//  The one persisted consent that turns the guided-install autopilot fully
//  autonomous. A publik guide's commands are already reviewed and version-
//  pinned on the server, so making a non-technical reader approve each one is
//  friction that defeats the whole "Let Iris run it" promise. Instead the
//  reader grants blanket control ONCE — "Let Iris take control of your Mac?" —
//  and it is remembered across every future install until they revoke it in
//  settings.
//
//  What the grant does NOT do: it never waves through the catastrophe floor in
//  `GuideAutopilotRiskAssessment` (whole-disk / whole-home destruction, `mkfs`,
//  `dd` to a raw disk, a fork bomb). That floor stays refused even under the
//  grant — the one thing that can stop a command once control is granted,
//  invisible unless a hallucinated model-proposed fix tries something ruinous.
//  The reader can also always stop a running install with the terminal's red
//  escape hatch, and revoke the grant entirely from the panel.
//
//  Deliberately `nonisolated` and backed by `UserDefaults`: it is read from
//  `GuideAutopilotRiskAssessment.assess(_:autonomyGranted:)`'s default argument
//  (itself `nonisolated`), written from the @MainActor consent flow, and shown
//  as a toggle in the settings panel — one small value that every one of those
//  contexts can reach without an actor hop. `UserDefaults` is its own
//  synchronization.
//

import Foundation

// `@unchecked Sendable`, not plain `Sendable`: the one stored property is a
// `UserDefaults`, which Apple documents as thread-safe but does not mark
// `Sendable`. Reading/writing one small bool key from several isolation
// domains is exactly what `UserDefaults` guarantees is safe, so the unchecked
// conformance is honest rather than a papered-over race.
nonisolated struct AutopilotAutonomyGrant: @unchecked Sendable {

    /// The app-wide grant, over `UserDefaults.standard`. `assess`'s default
    /// argument reads `AutopilotAutonomyGrant.shared.isGranted`, so the whole
    /// autopilot honors the grant with no value to thread through the runner.
    static let shared = AutopilotAutonomyGrant()

    private static let defaultsKey = "iris:autopilot:autonomousControlGranted"

    private let userDefaults: UserDefaults

    /// A real grant uses `.standard`; a test constructs one over an isolated
    /// suite so it never touches the reader's real preference.
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Whether the reader has granted autonomous control. Defaults to `false`
    /// for a key that was never written, so a fresh install always asks first.
    var isGranted: Bool {
        userDefaults.bool(forKey: Self.defaultsKey)
    }

    func grant() {
        userDefaults.set(true, forKey: Self.defaultsKey)
    }

    func revoke() {
        userDefaults.set(false, forKey: Self.defaultsKey)
    }
}
