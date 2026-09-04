//
//  PublikTest2EditTerminalMinimizePreferenceTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "There should be a setting where the terminal is auto
//  minimized, in settings tab."
//
//  `EditTerminalStartMinimizedPreference` is the persisted opt-in behind that
//  setting. When it is on, `CompanionManager.reactToOnDemandEditPhase(.running)`
//  skips presenting the centered terminal takeover, so an edit starts minimized
//  (the eye bar's running card, with its "Show terminal" button, is the
//  surface). These tests pin the preference's contract: off by default, and
//  remembered across reads — over an ISOLATED `UserDefaults` suite so the
//  reader's real setting is never touched.
//

import Foundation
import Testing
@testable import Iris

@Suite
struct PublikTest2EditTerminalMinimizePreferenceTests {

    @Test func theTerminalStartsUnminimizedByDefaultAndPersists() throws {
        let suiteName = "iris.editTerminalMinimize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preference = EditTerminalStartMinimizedPreference(userDefaults: defaults)
        #expect(
            preference.startsMinimized == false,
            "the centered takeover is the established behaviour; auto-minimize is an opt-in, off until the reader turns it on"
        )

        preference.setStartsMinimized(true)
        #expect(preference.startsMinimized == true)

        // A different instance over the SAME store sees it — the setting is
        // remembered across launches, not held in memory.
        #expect(EditTerminalStartMinimizedPreference(userDefaults: defaults).startsMinimized == true)

        preference.setStartsMinimized(false)
        #expect(preference.startsMinimized == false)
        #expect(EditTerminalStartMinimizedPreference(userDefaults: defaults).startsMinimized == false)
    }
}
