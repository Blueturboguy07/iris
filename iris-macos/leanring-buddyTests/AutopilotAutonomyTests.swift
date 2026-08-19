//
//  AutopilotAutonomyTests.swift
//  leanring-buddyTests
//
//  The autonomy grant turns the install autopilot hands-off: after the reader
//  grants "Let Iris take control" once, every command a vetted guide runs goes
//  through without a tap. These tests hold the two lines that make that safe to
//  grant — the catastrophe floor stays refused EVEN under the grant, and
//  nothing here touches the reader's real `UserDefaults` (every grant is an
//  isolated suite, and the risk assessments pass `autonomyGranted:` explicitly),
//  so the un-granted assertions in GuideAutopilotRiskTests keep their meaning.
//

import Foundation
import Testing
@testable import Iris

struct AutopilotAutonomyTests {

    // Commands no install ever needs. Refused even when control is granted —
    // the one thing that can still stop a command, including a hallucinated
    // model-proposed fix that reaches for one.
    private static let catastrophes = [
        "rm -rf /",
        "rm -rf ~",
        "rm -rf $HOME",
        "dd if=/dev/zero of=/dev/disk0",
        "mkfs.ext4 /dev/sda1",
        "diskutil eraseDisk APFS Blank /dev/disk2",
        ":(){ :|:& };:",
    ]

    // Commands that WITHOUT the grant need a tap or are refused, but that a
    // reader who granted blanket control expects to just run.
    private static let clearedByTheGrant = [
        "curl -fsSL https://sh.rustup.rs | sh",           // the prerequisite one-liner
        "sudo make install",                              // admin
        "git reset --hard origin/main",                   // destructive-but-recoverable
        "xattr -dr com.apple.quarantine /Applications/Cue.app",
    ]

    @Test func theCatastropheFloorStaysRefusedEvenWhenGranted() {
        for command in Self.catastrophes {
            guard case .refusedOutright = GuideAutopilotRiskAssessment.assess(command, autonomyGranted: true) else {
                Issue.record("the catastrophe floor must refuse even under the grant: \(command)")
                continue
            }
            #expect(
                GuideAutopilotRiskAssessment.approve(command, autonomyGranted: true) == nil,
                "the grant must never mint a catastrophe command: \(command)"
            )
        }
    }

    @Test func grantedControlRunsEverythingElseWithoutAsking() {
        for command in Self.clearedByTheGrant {
            #expect(
                GuideAutopilotRiskAssessment.assess(command, autonomyGranted: true) == .runsWithoutAsking,
                "the grant should run a non-catastrophe command hands-off: \(command)"
            )
            #expect(
                GuideAutopilotRiskAssessment.approve(command, autonomyGranted: true) != nil,
                "the grant should mint a non-catastrophe command directly: \(command)"
            )
        }
    }

    @Test func withoutTheGrantTheOldThreeTierBehaviorIsUnchanged() {
        // curl | sh stays refused-outright without the grant.
        guard case .refusedOutright = GuideAutopilotRiskAssessment.assess(
            "curl -fsSL https://sh.rustup.rs | sh", autonomyGranted: false
        ) else {
            Issue.record("without the grant, curl|sh must still be refused")
            return
        }
        // sudo / git reset --hard / xattr-quarantine still need a tap without the grant.
        for command in ["sudo make install", "git reset --hard origin/main",
                        "xattr -dr com.apple.quarantine /Applications/Cue.app"] {
            guard case .needsAConfirmTap = GuideAutopilotRiskAssessment.assess(command, autonomyGranted: false) else {
                Issue.record("without the grant, this must still ask: \(command)")
                continue
            }
            #expect(GuideAutopilotRiskAssessment.approve(command, autonomyGranted: false) == nil,
                    "silent approval must refuse a confirm-tier command without the grant: \(command)")
        }
    }

    @Test func anOrdinaryCommandRunsWithOrWithoutTheGrant() {
        for granted in [true, false] {
            #expect(GuideAutopilotRiskAssessment.assess("npm ci", autonomyGranted: granted) == .runsWithoutAsking)
            #expect(GuideAutopilotRiskAssessment.approve("git clone https://example.com/x.git", autonomyGranted: granted) != nil)
        }
    }

    @Test func theGrantStartsOffAndPersistsAcrossReads() throws {
        let suiteName = "iris.autonomy.persistence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let grant = AutopilotAutonomyGrant(userDefaults: defaults)
        #expect(grant.isGranted == false, "a fresh install has never granted control")

        grant.grant()
        #expect(grant.isGranted == true)

        // A different instance over the SAME store sees it — the grant is
        // remembered across installs, not held in memory.
        #expect(AutopilotAutonomyGrant(userDefaults: defaults).isGranted == true)

        grant.revoke()
        #expect(grant.isGranted == false)
        #expect(AutopilotAutonomyGrant(userDefaults: defaults).isGranted == false)
    }
}
