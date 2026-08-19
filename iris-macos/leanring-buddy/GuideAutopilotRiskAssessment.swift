//
//  GuideAutopilotRiskAssessment.swift
//  leanring-buddy
//
//  The gate every command passes before the autopilot shell will run it.
//
//  Be clear-eyed about what this is: a guardrail against mistakes, not a
//  defence against an adversary. Regexes over command text are defeatable by
//  construction — `$(echo rm) -rf` says nothing that matches `rm -rf` — which
//  is exactly why obfuscation itself trips the gate rather than being chased
//  pattern by pattern. The real security boundary is provenance: guide
//  commands come only from HTTPS-fetched, version-pinned guide JSON that the
//  web repo's tests already vet, and fix commands come from a model call
//  whose schema and system prompt constrain it. This file exists so that a
//  vetting regression or a bad fix pauses for a human instead of running.
//
//  Three tiers, not two. A confirm tap is not informed consent for
//  `curl … | sh` — the reader cannot read what is on the other end — so the
//  handful of commands no tap can justify are refused outright and the
//  button never appears.
//
//  `GuideAutopilotApprovedCommand` is the only type the shell session will
//  accept, and its initialiser is private: the two mint functions below are
//  the only way to obtain one. "Run an unassessed command" is therefore not
//  something the code can express — the same structural enforcement
//  `AssistantTransport` uses for the BYO key.
//

import Foundation

/// Why a command tripped the gate, in words a reader can act on.
nonisolated struct GuideAutopilotRiskReason: Equatable, Sendable {
    /// One plain sentence for the confirm row ("This runs as administrator.").
    let plainLanguageSummary: String
    /// The exact substring that tripped the gate, for highlighting in the
    /// command well. Empty when the whole command is the reason.
    let trippingSubstring: String
}

nonisolated enum GuideAutopilotRisk: Equatable, Sendable {
    case runsWithoutAsking
    case needsAConfirmTap(reason: GuideAutopilotRiskReason)
    case refusedOutright(reason: GuideAutopilotRiskReason)
}

/// A command that has been through the gate. The shell session runs these and
/// nothing else. Minted only by `GuideAutopilotRiskAssessment.approve(_:)`
/// (clean commands) and `approveAfterAReaderTap(_:)` (confirm-tier commands,
/// after the tap) — never by a caller.
nonisolated struct GuideAutopilotApprovedCommand: Equatable, Sendable {
    let text: String
    fileprivate init(text: String) {
        self.text = text
    }
}

nonisolated enum GuideAutopilotRiskAssessment {

    // MARK: - The verdict

    /// `autonomyGranted` defaults to the persisted grant, so the whole
    /// autopilot honors "Let Iris take control" without threading a value
    /// through the runner. When it is `true`, every command that is not in the
    /// catastrophe floor runs without asking — the reader granted blanket
    /// control once, and a per-command tap on a vetted install is exactly the
    /// friction the grant removes. When it is `false` (no grant, or an explicit
    /// test), the original three-tier behavior is unchanged.
    static func assess(
        _ command: String,
        autonomyGranted: Bool = AutopilotAutonomyGrant.shared.isGranted
    ) -> GuideAutopilotRisk {
        // The catastrophe floor is absolute — refused EVEN under the grant.
        // These are commands no install ever needs and no consent should wave
        // through; a hallucinated model-proposed fix that reaches for one is
        // stopped here, silently, without a tap.
        for rule in Self.catastropheRules {
            if let match = rule.firstMatch(in: command) {
                return .refusedOutright(reason: GuideAutopilotRiskReason(
                    plainLanguageSummary: rule.plainLanguageSummary,
                    trippingSubstring: match
                ))
            }
        }

        if autonomyGranted {
            return .runsWithoutAsking
        }

        for rule in Self.nonCatastropheRefusalRules {
            if let match = rule.firstMatch(in: command) {
                return .refusedOutright(reason: GuideAutopilotRiskReason(
                    plainLanguageSummary: rule.plainLanguageSummary,
                    trippingSubstring: match
                ))
            }
        }
        for rule in Self.confirmRules {
            if let match = rule.firstMatch(in: command) {
                return .needsAConfirmTap(reason: GuideAutopilotRiskReason(
                    plainLanguageSummary: rule.plainLanguageSummary,
                    trippingSubstring: match
                ))
            }
        }
        return .runsWithoutAsking
    }

    // MARK: - The only two mints

    /// Approves a command the gate waves through. Returns nil for anything
    /// that needs a tap or is refused — callers surface those, never force
    /// them through. Honors the same autonomy grant `assess` does, so a
    /// granted autopilot mints every non-catastrophe command directly.
    static func approve(
        _ command: String,
        autonomyGranted: Bool = AutopilotAutonomyGrant.shared.isGranted
    ) -> GuideAutopilotApprovedCommand? {
        guard case .runsWithoutAsking = assess(command, autonomyGranted: autonomyGranted) else { return nil }
        return GuideAutopilotApprovedCommand(text: command)
    }

    /// Approves a confirm-tier command after the reader's explicit tap.
    /// Refused-tier commands stay refused — no tap reaches them.
    static func approveAfterAReaderTap(_ command: String) -> GuideAutopilotApprovedCommand? {
        switch assess(command) {
        case .runsWithoutAsking, .needsAConfirmTap:
            return GuideAutopilotApprovedCommand(text: command)
        case .refusedOutright:
            return nil
        }
    }

    // MARK: - The catastrophe floor: refused EVEN under the autonomy grant
    //
    // The only rules `assess` checks before the grant can wave a command
    // through. These describe whole-disk / whole-home destruction that no
    // install ever needs; keeping them absolute is what lets "Let Iris take
    // control" be safe to grant once — a hallucinated fix that reaches for one
    // is stopped here with no tap, rather than running.

    private static let catastropheRules: [GuideAutopilotRiskRule] = [
        .init(#"\brm\b[^\n]*\s-[a-z]*(rf|fr)[a-z]*\s+(/|/\*|~|~/|\$HOME)\s*(\n|$|;|&)"#,
              "This deletes the root of the disk or the whole home folder."),
        .init(#"\bdd\b[^\n]*\bof=/dev/"#,
              "This writes raw bytes over a disk device."),
        .init(#"\bmkfs\b"#,
              "This reformats a disk."),
        .init(#"\bdiskutil\s+(erase|reformat)"#,
              "This erases a disk."),
        .init(#"\(\)\s*\{[^\n}]*\|[^\n}]*&[^\n}]*\}\s*;"#,
              "This is a fork bomb."),
    ]

    // MARK: - Refused only WITHOUT the grant
    //
    // `curl … | sh` cannot be read before it runs, so without the grant it is
    // refused outright (no tap can make it informed). WITH the grant it runs —
    // that one-liner is how half of all prerequisites install, and refusing it
    // is the single biggest reason a package install used to bounce the reader
    // out to a web page. The literal stays here so the web guide tests that
    // grep this file for it keep matching.

    private static let nonCatastropheRefusalRules: [GuideAutopilotRiskRule] = [
        .init(#"\b(curl|wget)\b[^\n|]*\|[^\n]*\b(sh|bash|zsh)\b"#,
              "This downloads a script and runs it without anyone reading it first."),
    ]

    // MARK: - Needs a confirm tap
    //
    // The first seven patterns mirror tests/iris-guides.test.ts ("does not
    // publish obviously dangerous guide commands") verbatim — the web test
    // greps this file's source for each of its own pattern literals, so a
    // pattern added there must appear here spelled the same way.

    private static let confirmRules: [GuideAutopilotRiskRule] = [
        // Mirrored from the web guide tests, byte for byte.
        .init("\\bsudo\\b", "This runs as administrator."),
        .init("\\brm\\s+-rf\\b", "This force-deletes a folder and everything in it."),
        .init("\\bcurl\\b[^\\n]*\\|", "This pipes a download into another program."),
        .init("\\bwget\\b[^\\n]*\\|", "This pipes a download into another program."),
        .init("\\bxattr\\s+-cr\\b", "This strips macOS's safety attributes from files."),
        .init("\\bSet-ExecutionPolicy\\b", "This changes what scripts Windows will run."),
        .init("\\bInvoke-Expression\\b", "This runs text as a program."),

        // Administrator-adjacent.
        .init(#"(^|\s)su(\s|$)"#, "This switches to another user."),
        .init(#"\bosascript\b[^\n]*administrator privileges"#,
              "This asks for administrator rights through AppleScript."),
        .init(#"\bsecurity\s+add-trusted-cert\b"#, "This adds a trusted certificate."),
        .init(#"\bchmod\s+([0-7]*777|-R)\b"#, "This loosens file permissions broadly."),
        .init(#"\bchown\b"#, "This changes who owns files."),
        .init(#"\blaunchctl\s+(load|bootstrap)\b[^\n]*LaunchDaemons"#,
              "This installs a system-level background service."),
        .init(#"\bcsrutil\b"#, "This touches System Integrity Protection."),
        .init(#"\bspctl\b[^\n]*--master-disable"#, "This turns Gatekeeper off."),
        .init(#"\bsystemsetup\b"#, "This changes system-wide settings."),
        .init(#"\bxattr\b[^\n]*com\.apple\.quarantine"#,
              "This strips the quarantine flag macOS puts on downloads."),

        // Destructive.
        .init(#"\bgit\s+reset\s+--hard\b"#, "This throws away uncommitted changes."),
        .init(#"\bgit\s+clean\s+-[a-z]*f"#, "This deletes untracked files."),
        .init(#"\bgit\s+checkout\s+--\s+\."#, "This discards local edits."),
        .init(#"\bgit\s+push\b[^\n]*(--force\b|\s-f\b)"#, "This overwrites remote history."),
        .init(#"\btruncate\b"#, "This empties a file in place."),
        .init(#"\bshred\b"#, "This destroys a file's contents."),
        .init(#"\bfind\b[^\n]*-delete\b"#, "This deletes every file the search matches."),
        .init(#"\bdefaults\s+delete\b"#, "This erases an app's stored settings."),
        .init(#"\bkillall\b"#, "This force-quits running apps."),
        .init(#"\bpkill\b"#, "This force-quits running processes."),
        .init(#"\brmdir\b"#, "This removes a directory."),
        .init(#"\bbrew\s+uninstall\b"#, "This uninstalls software."),
        .init(#"\bdocker\s+(rm|rmi|volume\s+rm|system\s+prune)\b"#,
              "This deletes Docker containers, images, or volumes."),
        .init(#"\bDROP\s+(TABLE|DATABASE)\b"#, "This deletes a database."),
        .init(#"\bnpm\s+publish\b"#, "This publishes a package to the public registry."),

        // Writes outside the home folder.
        .init(#">>?\s*/(usr|etc|Library|System|Applications)/"#,
              "This writes into a system folder."),
        .init(#"\b(tee|cp|mv|ln|mkdir)\b[^\n]*\s/(usr|etc|Library|System|Applications)/"#,
              "This changes files in a system folder."),

        // Obfuscation: a command whose effect cannot be read from its text.
        // Chasing every disguise is unwinnable, so the disguise itself is
        // the trigger. `$(( ))` arithmetic is exempt — it computes a number,
        // not a command — so the pattern matches `$(` only when a second `(`
        // does not immediately follow.
        .init(#"\$\((?!\()"#, "Part of this command is computed when it runs, so its effect can't be read from its text."),
        .init(#"`"#, "Part of this command is computed when it runs, so its effect can't be read from its text."),
        .init(#"\beval\b"#, "This runs text as a program."),
        .init(#"\bbase64\b[^\n]*(-d|--decode)[^\n]*\|"#,
              "This decodes hidden text and pipes it into a program."),
        .init(#"\|\s*(sh|bash|zsh)\b"#, "This pipes text into a shell to run."),
    ]
}

/// One pattern plus its reason. Case-insensitive, like the web test's
/// patterns; the first match's text is what the confirm row highlights.
nonisolated private struct GuideAutopilotRiskRule {
    let pattern: NSRegularExpression
    let plainLanguageSummary: String

    init(_ pattern: String, _ plainLanguageSummary: String) {
        // The tables above are compile-time constants; a typo in one is a
        // programmer error worth crashing loudly over, not handling.
        // swiftlint:disable:next force_try
        self.pattern = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        self.plainLanguageSummary = plainLanguageSummary
    }

    func firstMatch(in command: String) -> String? {
        let wholeRange = NSRange(command.startIndex..., in: command)
        guard let match = pattern.firstMatch(in: command, range: wholeRange),
              let range = Range(match.range, in: command) else { return nil }
        return String(command[range])
    }
}
