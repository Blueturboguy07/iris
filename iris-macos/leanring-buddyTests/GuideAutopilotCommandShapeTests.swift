//
//  GuideAutopilotCommandShapeTests.swift
//  leanring-buddyTests
//
//  Locks the run-from-source detection that the NitroAI `npm run app` incident
//  exposed: a command that runs the app from source and never returns MUST be
//  recognized as holding the shell open, or the autopilot runs it on the main
//  session and every later build/install step blocks behind it forever until it
//  times out. Regular builds (`tauri build`, `npm ci`) must NOT be flagged, or
//  the autopilot would background a command it should wait on.
//

import Foundation
import Testing
@testable import Iris

struct GuideAutopilotCommandShapeTests {

    @Test func runFromSourceCommandsHoldTheShellOpen() {
        // Includes the project-specific script names guides actually use to run
        // the app from source — not just the conventional dev/start (the ones
        // that were missing and broke the NitroAI install).
        let holdsOpen = [
            "npm run app",     // nitroai — the incident
            "yarn app",        // simplicity
            "pnpm app",
            "npm run dev",
            "npm start",
            "pnpm dev",
            "npm run serve",
            "npm run preview",
            "npm run electron",
            "tauri dev",
            "cargo run",
            "vite",
        ]
        for command in holdsOpen {
            #expect(GuideAutopilotCommandShape.holdsTheShellOpen(command),
                    "must be treated as long-running or it blocks the main shell: \(command)")
        }
    }

    @Test func buildsAndOneShotsDoNotHoldTheShellOpen() {
        // Critically `npm run tauri build --bundles app` contains "app" but is a
        // build that returns — widening the run-script list must not swallow it.
        let returns = [
            "npm run tauri build --bundles app",
            "npm ci",
            "npm install",
            "cargo build --release",
            "git clone https://example.com/x.git",
            "ditto src-tauri/target/release/bundle/macos/App.app /Applications/App.app",
            "open /Applications/App.app",
        ]
        for command in returns {
            #expect(!GuideAutopilotCommandShape.holdsTheShellOpen(command),
                    "a command that returns must not be backgrounded: \(command)")
        }
    }

    // MARK: - Moved here from GuideAutopilotShellSessionTests
    //
    // These three lived in a SECOND struct of this same name at the bottom
    // of that file. Two suites cannot share a name: the whole test target
    // failed to build with "invalid redeclaration", and every macro-
    // generated @Test entry point in both files failed to resolve — so no
    // test in the project could run at all.


    @Test func devServersAreRecognisedAndBuildCommandsAreNot() {
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("npm run dev"))
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("corepack pnpm dev"))
        #expect(GuideAutopilotCommandShape.holdsTheShellOpen("docker compose up"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen("docker compose up -d"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen("npm ci"))
        #expect(!GuideAutopilotCommandShape.holdsTheShellOpen(
            "ui/node_modules/.bin/tauri build --bundles app"))
    }

    @Test func unterminatedConstructsAreRefusedBeforeTheyWedgeTheShell() {
        #expect(GuideAutopilotCommandShape.looksSyntacticallyIncomplete("echo 'unterminated"))
        #expect(GuideAutopilotCommandShape.looksSyntacticallyIncomplete("cat <<EOF\nhello"))
        #expect(!GuideAutopilotCommandShape.looksSyntacticallyIncomplete(
            "git commit -m 'a complete message'"))
    }

    @Test func hostsAreExtractedForFixValidation() {
        let hosts = GuideAutopilotCommandShape.hostsTheCommandWouldReach(
            "git clone https://github.com/Blueturboguy07/cue.git && curl https://registry.npmjs.org/x"
        )
        #expect(hosts == ["github.com", "registry.npmjs.org"])
    }
}
