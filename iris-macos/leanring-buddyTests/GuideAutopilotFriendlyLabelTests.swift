//
//  GuideAutopilotFriendlyLabelTests.swift
//  leanring-buddyTests
//
//  Pins the command → plain-English mapping shown in the autopilot terminal.
//  The catch-all is honest ("Running a setup step…"), never a wrong specific
//  claim, so the only thing worth asserting is that the common install shapes
//  map to their friendly line and an unknown command falls through.
//

import Foundation
import Testing
@testable import Iris

struct GuideAutopilotFriendlyLabelTests {

    @Test func commonInstallShapesGetAPlainEnglishLabel() {
        let expected: [(String, String)] = [
            ("git clone https://github.com/Blueturboguy07/cue.git", "Getting the app's code…"),
            ("git checkout v1.0.0", "Getting the right version…"),
            ("npm ci", "Installing the pieces it needs…"),
            ("pnpm install --frozen-lockfile", "Installing the pieces it needs…"),
            ("cargo build --release", "Building the app…"),
            ("ui/node_modules/.bin/tauri build --bundles app", "Building the app…"),
            ("brew install rust", "Installing a tool it needs…"),
            ("curl -fsSL https://sh.rustup.rs | sh", "Installing a tool it needs…"),
            ("xattr -dr com.apple.quarantine /Applications/Cue.app", "Clearing macOS's download warning…"),
            ("cd ~/cue", "Setting things up…"),
        ]
        for (command, label) in expected {
            #expect(GuideAutopilotFriendlyLabel.label(for: command) == label,
                    "\(command) should read as \"\(label)\"")
        }
    }

    @Test func anUnrecognizedCommandFallsThroughHonestly() {
        #expect(GuideAutopilotFriendlyLabel.label(for: "some-bespoke-tool --do-a-thing")
                == "Running a setup step…")
    }
}
