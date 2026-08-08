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
//  the real guide sources from lib/guides/*.ts, so a new guide command that
//  trips the gate fails this suite as a release blocker.
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

    /// Reads every `command:` string literal out of lib/guides/*.ts. The web
    /// repo's tests read Swift and Rust sources for the same cross-language
    /// checks; this is that trick pointed the other way.
    private static func commandsFromTheShippedGuideSources() throws -> [String] {
        let guidesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // leanring-buddyTests
            .deletingLastPathComponent()   // iris-macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("lib/guides")

        let sources = try FileManager.default
            .contentsOfDirectory(at: guidesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ts" }

        let literal = try NSRegularExpression(
            pattern: #"command:\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')"#,
            options: [.dotMatchesLineSeparators]
        )

        var commands: [String] = []
        for file in sources {
            let source = try String(contentsOf: file, encoding: .utf8)
            let wholeRange = NSRange(source.startIndex..., in: source)
            literal.enumerateMatches(in: source, range: wholeRange) { match, _, _ in
                guard let match else { return }
                for group in 1...2 {
                    guard let range = Range(match.range(at: group), in: source) else { continue }
                    commands.append(Self.unescapedTypeScriptLiteral(String(source[range])))
                }
            }
        }
        return commands
    }

    private static func unescapedTypeScriptLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
