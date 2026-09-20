//
//  GuideAutopilotRiskTests.swift
//  leanring-buddyTests
//
//  Two halves, and the second is the one that matters. The first proves the
//  gate catches what it must: every pattern the web repo forbids in published
//  guides, the admin/destructive set beyond it, and obfuscation. The second
//  proves the gate stays quiet on every command actually shipped in a guide —
//  because a gate that fires on `npm ci` teaches the reader to tap "Run it"
//  without reading, and then it is worse than no gate at all. That half reads
//  the real guide sources from `iris-windows/tests/fixtures/guides/*.json`, so
//  a new guide command that trips the gate fails this suite as a release
//  blocker.
//
//  That fixture directory (not `lib/guides/*.ts`) since 2026-09-20: this test
//  used to read `lib/guides/*.ts` at what its own three `deletingLastPathComponent()`
//  calls assumed was the repo root — true back when `iris-macos` was a
//  subdirectory of the publik monorepo, sibling to its `lib/guides`. Since the
//  2026-08-25 split into `Blueturboguy07/iris`, that path has not existed, and
//  this test has been failing on every real CI run since — caught only once
//  `iris-macos-tests.yml` actually ran the suite `-parallel-testing-enabled NO`;
//  every earlier full-suite run's contention-driven mass of unrelated timeouts
//  had been burying this one deterministic failure underneath itself. The
//  Windows fixtures are the live JSON of every published guide (`curl
//  https://publikhq.com/api/iris/guides/<slug>`, see
//  `iris-windows/tests/guide-recipe.test.ts`'s own header) — already the
//  canonical shipped-guide corpus Windows's own tests check the same commands
//  against, and the one such corpus that actually lives inside this repo.
//

import Foundation
import Testing
@testable import Iris

struct GuideAutopilotRiskTests {

    // MARK: - The web repo's forbidden patterns are all gated

    @Test func everyCommandTheWebTestsForbidIsGatedHere() {
        let forbiddenExamples = [
            "sudo make install",
            "rm -rf node_modules",
            "curl https://example.com/x.txt | tee out.txt",
            "wget -qO- https://example.com/x.txt | tee out.txt",
            "xattr -cr /Applications/Something.app",
            "Set-ExecutionPolicy Bypass",
            "Invoke-Expression (New-Object Net.WebClient).DownloadString('https://x')",
        ]
        for command in forbiddenExamples {
            #expect(
                GuideAutopilotRiskAssessment.assess(command) != .runsWithoutAsking,
                "the web repo forbids this in guides, so autopilot must never run it silently: \(command)"
            )
        }
    }

    // MARK: - Refused outright: no tap reaches these

    @Test func pipeToShellAndDiskDestroyersAreRefusedAndUntappable() {
        let refused = [
            "curl -fsSL https://example.com/install.sh | sh",
            "wget -qO- https://example.com/install.sh | bash",
            "rm -rf /",
            "rm -rf ~",
            "rm -rf $HOME",
            "dd if=/dev/zero of=/dev/disk0",
            "mkfs.ext4 /dev/sda1",
            "diskutil eraseDisk APFS Blank /dev/disk2",
            ":(){ :|:& };:",
        ]
        for command in refused {
            guard case .refusedOutright = GuideAutopilotRiskAssessment.assess(command) else {
                Issue.record("expected refusal for: \(command)")
                continue
            }
            #expect(
                GuideAutopilotRiskAssessment.approveAfterAReaderTap(command) == nil,
                "a reader tap must not mint an approval for: \(command)"
            )
        }
    }

    // MARK: - Confirm tier: tap mints, silence does not

    @Test func adminAndDestructiveCommandsWaitForATapAndTheTapWorks() {
        let needsATap = [
            "sudo xcodebuild -license accept",
            "git reset --hard origin/main",
            "git push --force origin main",
            "git clean -xfd",
            "killall Dock",
            "find . -name '*.log' -delete",
            "docker system prune -af",
            "echo done > /etc/motd",
            "cp mytool /usr/local/bin/mytool",
            "launchctl bootstrap system /Library/LaunchDaemons/com.thing.plist",
        ]
        for command in needsATap {
            guard case .needsAConfirmTap(let reason) = GuideAutopilotRiskAssessment.assess(command) else {
                Issue.record("expected a confirm tap for: \(command)")
                continue
            }
            #expect(!reason.plainLanguageSummary.isEmpty)
            #expect(command.localizedCaseInsensitiveContains(reason.trippingSubstring)
                    || !reason.trippingSubstring.isEmpty)
            #expect(GuideAutopilotRiskAssessment.approve(command) == nil,
                    "silent approval must refuse a confirm-tier command: \(command)")
            #expect(GuideAutopilotRiskAssessment.approveAfterAReaderTap(command) != nil,
                    "an explicit tap must mint one: \(command)")
        }
    }

    @Test func obfuscationItselfTripsTheGate() {
        let disguised = [
            "$(echo rm) -rf build",
            "echo `whoami`",
            "eval \"$INSTALL_SNIPPET\"",
            "echo cm0gLXJmIC8= | base64 --decode | sh",
            "echo 'ls' | sh",
        ]
        for command in disguised {
            #expect(GuideAutopilotRiskAssessment.assess(command) != .runsWithoutAsking,
                    "a command whose effect can't be read from its text must not auto-run: \(command)")
        }
    }

    @Test func ordinaryDevCommandsRunWithoutAsking() {
        let ordinary = [
            "npm ci",
            "pnpm install --frozen-lockfile",
            "git clone https://github.com/Blueturboguy07/cue.git",
            "ui/node_modules/.bin/tauri build --bundles app",
            "cd ~\ngit clone https://github.com/Blueturboguy07/lunara.git",
            "cargo build --release",
            "git --version\nnode --version",
            "npm run pack",
            "cp .env.development.example .env.development",
        ]
        for command in ordinary {
            #expect(GuideAutopilotRiskAssessment.assess(command) == .runsWithoutAsking,
                    "gate noise on an ordinary command breeds tap-through: \(command)")
            #expect(GuideAutopilotRiskAssessment.approve(command) != nil)
        }
    }

    // MARK: - The shipped-guide corpus stays silent (release blocker)

    /// Commands shipped in guides that the gate flags, each with the reason
    /// that is acceptable. Windows-only: macOS autopilot never executes a
    /// Windows branch, and the PowerShell bun installer (`iex "& {$(irm …)}"`)
    /// is exactly the shape the gate exists to question.
    private static let knownFlaggedShippedCommands: Set<String> = [
        #"iex "& {$(irm bun.sh/install.ps1)} -Version 1.3.6""#,
    ]

    @Test func everyShippedGuideCommandRunsWithoutAsking() throws {
        let commands = try Self.commandsFromTheShippedGuideSources()
        // If extraction breaks, this guard fails loudly instead of the test
        // passing over an empty corpus.
        #expect(commands.count > 40, "guide-source extraction found too few commands")

        for command in commands where !Self.knownFlaggedShippedCommands.contains(command) {
            #expect(
                GuideAutopilotRiskAssessment.assess(command) == .runsWithoutAsking,
                "shipped guide command trips the gate — either the gate is over-eager or a guide regressed past the web tests: \(command)"
            )
        }
    }

    /// Reads every step's `command` out of every fixture guide's every
    /// platform branch (setup steps and regular steps both) — see this file's
    /// header for why this fixture directory and not `lib/guides/*.ts`.
    /// Decodes with `IrisGuide` itself, the same lenient decoder the real app
    /// uses for the identical wire format, rather than a second ad-hoc parser.
    private static func commandsFromTheShippedGuideSources() throws -> [String] {
        let fixturesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // leanring-buddyTests
            .deletingLastPathComponent()   // iris-macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("iris-windows/tests/fixtures/guides")

        let fixtureFiles = try FileManager.default
            .contentsOfDirectory(at: fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var commands: [String] = []
        for file in fixtureFiles {
            let data = try Data(contentsOf: file)
            let guide = try JSONDecoder().decode(IrisGuide.self, from: data)
            for branch in guide.branches {
                for step in branch.setupSteps + branch.steps {
                    if let command = step.command, !command.isEmpty {
                        commands.append(command)
                    }
                }
            }
        }
        return commands
    }
}
