//
//  PublikTest2EditTerminalMinimizePreferenceTests.swift
//  leanring-buddyTests
//
//  PUBLIK TEST 2 — "There should be a setting where the terminal is auto
//  minimized, in settings tab."
//
//  `EditTerminalStartMinimizedPreference` is the persisted opt-in behind that
//  setting. When it is on, guide installs and on-demand edits start minimized
//  and their compact workflow cards carry an explicit "Show terminal" action.
//  These tests pin the preference's contract: off by default, and remembered
//  across reads over an ISOLATED `UserDefaults` suite so the reader's real
//  setting is never touched.
//

import Foundation
import Testing
@testable import Iris

@Suite
struct PublikTest2TerminalStartMinimizedPreferenceTests {

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

    @Test func thePurePolicyUsesTheSamePreferenceForInstallsAndEdits() {
        #expect(
            TerminalStartMinimizedPolicy.shouldAutomaticallyPresent(
                workflow: .guideInstall, startsMinimized: false
            )
        )
        #expect(
            !TerminalStartMinimizedPolicy.shouldAutomaticallyPresent(
                workflow: .guideInstall, startsMinimized: true
            )
        )
        #expect(
            TerminalStartMinimizedPolicy.shouldAutomaticallyPresent(
                workflow: .onDemandEdit, startsMinimized: false
            )
        )
        #expect(
            !TerminalStartMinimizedPolicy.shouldAutomaticallyPresent(
                workflow: .onDemandEdit, startsMinimized: true
            )
        )
    }

    @Test func terminalOwnershipRejectsWrongWorkflowAndQueuesOnlyItsOwner() {
        #expect(
            TerminalTakeoverOwnershipPolicy.mayPresent(
                requestedWorkflow: .guideInstall, presentedWorkflow: nil
            )
        )
        #expect(
            !TerminalTakeoverOwnershipPolicy.mayPresent(
                requestedWorkflow: .onDemandEdit, presentedWorkflow: .guideInstall
            )
        )
        #expect(
            !TerminalTakeoverOwnershipPolicy.mayDismiss(
                requestedWorkflow: .guideInstall, presentedWorkflow: .onDemandEdit
            )
        )
        #expect(
            TerminalTakeoverOwnershipPolicy.mayDismiss(
                requestedWorkflow: .onDemandEdit, presentedWorkflow: .onDemandEdit
            )
        )
        #expect(
            TerminalTakeoverOwnershipPolicy.shouldQueueDismissalFollowUp(
                requestedWorkflow: .onDemandEdit,
                presentedWorkflow: .onDemandEdit,
                isDismissing: true
            )
        )
        #expect(
            !TerminalTakeoverOwnershipPolicy.shouldQueueDismissalFollowUp(
                requestedWorkflow: .guideInstall,
                presentedWorkflow: .onDemandEdit,
                isDismissing: true
            )
        )
    }
}
