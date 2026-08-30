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
//  ── The gate assesses the command AS IT WILL RUN ──
//
//  Every rule below is a pattern over command TEXT, and the text of a command
//  does not say where it runs. That was a real hole the moment a guide step
//  could declare its own working directory: `cp -R ./Evil.app /Applications/`
//  asks for a confirm tap, and the identical effect written as
//  `workingDirectory: "/Applications"` + `cp -R ./Evil.app .` used to run with
//  no tap at all. Measured, before the fix, from this file's own compiled gate:
//
//      cp -R ./Evil.app /Applications/                      -> CONFIRM
//      cd /Applications ; cp -R ./Evil.app .                -> RUNS-NO-ASK
//      cp ./x.plist /Library/LaunchAgents/x.plist           -> CONFIRM
//      cd /Library/LaunchAgents ; cp ./x.plist x.plist      -> RUNS-NO-ASK
//      rm -rf ~                              (grant ON)     -> REFUSED (floor)
//      cd ~ ; rm -rf .                       (grant ON)     -> RUNS-NO-ASK
//
//  The last pair is the worst of them: the catastrophe floor is the one thing
//  no consent and no autonomy grant can wave through, and a declared folder
//  walked a whole-home deletion straight past it.
//
//  So `assess` now takes the folder the command will run in and checks every
//  rule against TWO renderings — the raw text, exactly as before, and the same
//  command with its relative paths resolved against that folder. The strictest
//  verdict wins. Resolution is used only for judging; the text that actually
//  reaches the shell is never rewritten, so a rendering this gets wrong can
//  only ever cost an extra confirm tap, never change what runs.

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
    ///
    /// `inWorkingDirectory` is the folder the command will actually run in —
    /// the one a step declared, or the one the shell is already sitting in.
    /// Passing nil assesses raw text only, which is the pre-existing behavior
    /// and what every caller that genuinely has no folder should do.
    static func assess(
        _ command: String,
        inWorkingDirectory workingDirectory: String? = nil,
        autonomyGranted: Bool = AutopilotAutonomyGrant.shared.isGranted
    ) -> GuideAutopilotRisk {
        let renderings = Self.renderingsToAssess(command, inWorkingDirectory: workingDirectory)

        // The catastrophe floor is absolute — refused EVEN under the grant.
        // These are commands no install ever needs and no consent should wave
        // through; a hallucinated model-proposed fix that reaches for one is
        // stopped here, silently, without a tap.
        for rule in Self.catastropheRules {
            if let reason = Self.firstReason(from: rule, over: renderings, asWritten: command) {
                return .refusedOutright(reason: reason)
            }
        }

        if autonomyGranted {
            return .runsWithoutAsking
        }

        // Checked after the floor and before everything else: the two official
        // installers, by exact text. See `officialInstallerCommands`. Matched
        // on the command AS WRITTEN: resolution can only add path prefixes, so
        // a rendering never becomes an installer that the text was not.
        if Self.isAnOfficialInstaller(command) {
            return .runsWithoutAsking
        }

        for rule in Self.nonCatastropheRefusalRules {
            if let reason = Self.firstReason(from: rule, over: renderings, asWritten: command) {
                return .refusedOutright(reason: reason)
            }
        }
        for rule in Self.confirmRules {
            if let reason = Self.firstReason(from: rule, over: renderings, asWritten: command) {
                return .needsAConfirmTap(reason: reason)
            }
        }
        return .runsWithoutAsking
    }

    /// The raw command, plus — when a working directory says the two differ —
    /// the same command as the shell will really execute it. One entry when
    /// resolution changes nothing, so a caller with no folder pays nothing.
    private static func renderingsToAssess(
        _ command: String,
        inWorkingDirectory workingDirectory: String?
    ) -> [String] {
        let asItWillRun = commandAsItWillRun(command, inWorkingDirectory: workingDirectory)
        return asItWillRun == command ? [command] : [command, asItWillRun]
    }

    /// The first rendering this rule matches, turned into a reason.
    ///
    /// The confirm row highlights `trippingSubstring` inside the command well,
    /// which shows the command AS WRITTEN. A match found only in the resolved
    /// rendering has no such substring — half the reason is the folder, which
    /// is not in that text — so the highlight is dropped rather than pointing
    /// at characters that are not there. `GuideAutopilotRiskReason` already
    /// documents empty as "the whole command is the reason".
    private static func firstReason(
        from rule: GuideAutopilotRiskRule,
        over renderings: [String],
        asWritten command: String
    ) -> GuideAutopilotRiskReason? {
        for rendering in renderings {
            guard let match = rule.firstMatch(in: rendering) else { continue }
            return GuideAutopilotRiskReason(
                plainLanguageSummary: rule.plainLanguageSummary,
                trippingSubstring: command.contains(match) ? match : ""
            )
        }
        return nil
    }

    // MARK: - The only two mints

    /// Approves a command the gate waves through. Returns nil for anything
    /// that needs a tap or is refused — callers surface those, never force
    /// them through. Honors the same autonomy grant `assess` does, so a
    /// granted autopilot mints every non-catastrophe command directly.
    static func approve(
        _ command: String,
        inWorkingDirectory workingDirectory: String? = nil,
        autonomyGranted: Bool = AutopilotAutonomyGrant.shared.isGranted
    ) -> GuideAutopilotApprovedCommand? {
        guard case .runsWithoutAsking = assess(
            command, inWorkingDirectory: workingDirectory, autonomyGranted: autonomyGranted
        ) else { return nil }
        return GuideAutopilotApprovedCommand(text: command)
    }

    /// Approves a confirm-tier command after the reader's explicit tap.
    /// Refused-tier commands stay refused — no tap reaches them. The folder
    /// matters here too: the tap was asked for on the command as it will run,
    /// and this must not re-assess it in a laxer way than the ask did.
    static func approveAfterAReaderTap(
        _ command: String,
        inWorkingDirectory workingDirectory: String? = nil
    ) -> GuideAutopilotApprovedCommand? {
        switch assess(command, inWorkingDirectory: workingDirectory) {
        case .runsWithoutAsking, .needsAConfirmTap:
            return GuideAutopilotApprovedCommand(text: command)
        case .refusedOutright:
            return nil
        }
    }

    // MARK: - Resolving a command against the folder it runs in

    /// The command rewritten so every relative path in it is spelled from the
    /// root, the way the shell will resolve it in `workingDirectory`. Returns
    /// the command unchanged when there is no folder to resolve against, or
    /// when nothing in it is relative.
    ///
    /// FOR JUDGING ONLY. The string this returns is handed to the rule tables
    /// and to nothing else; `GuideAutopilotApprovedCommand` always carries the
    /// command as written. That is what makes the heuristics below safe to be
    /// approximate: an argument this resolves that was never a path (`install`
    /// in `npm install` becomes `~/repo/install`) cannot change what runs, and
    /// on a home-rooted folder — which is every published guide — it matches no
    /// rule either. The failure mode is one unnecessary confirm tap.
    ///
    /// Deliberately NOT `standardizingPath`: that expands `~` to this Mac's
    /// real home, and `rm -rf /Users/somebody` does not match the whole-home
    /// rule that `rm -rf ~` does. `~` is kept literal, exactly as `isAPlainFolder`
    /// keeps it for the real `cd`.
    static func commandAsItWillRun(
        _ command: String,
        inWorkingDirectory workingDirectory: String?
    ) -> String {
        guard var folder = workingDirectory,
              folder.hasPrefix("~") || folder.hasPrefix("/") else { return command }
        while folder.count > 1 && folder.hasSuffix("/") { folder.removeLast() }

        var resolved = ""
        var tokenIsTheProgramName = true
        for line in command.split(separator: "\n", omittingEmptySubsequences: false) {
            if !resolved.isEmpty { resolved += "\n" }
            tokenIsTheProgramName = true
            for piece in Self.piecesPreservingWhitespace(of: String(line)) {
                if piece.isWhitespaceRun {
                    resolved += piece.text
                    continue
                }
                if Self.separatesOneCommandFromTheNext(piece.text) {
                    resolved += piece.text
                    tokenIsTheProgramName = true
                    continue
                }
                if tokenIsTheProgramName {
                    // A program is found on PATH, not in the working folder.
                    resolved += piece.text
                    tokenIsTheProgramName = false
                    continue
                }
                resolved += Self.resolving(piece.text, against: folder) ?? piece.text
            }
        }
        return resolved
    }

    /// `&&`, `||`, `|`, `;` and `&` end one command and start another, so the
    /// token after one is a program name rather than an argument.
    private static func separatesOneCommandFromTheNext(_ token: String) -> Bool {
        ["&&", "||", "|", ";", "&", "(", ")", "{", "}"].contains(token)
    }

    private struct CommandPiece {
        let text: String
        let isWhitespaceRun: Bool
    }

    /// Splits a line into alternating runs of whitespace and non-whitespace, so
    /// the rebuilt rendering keeps the original spacing the `\s` in every rule
    /// depends on.
    private static func piecesPreservingWhitespace(of line: String) -> [CommandPiece] {
        var pieces: [CommandPiece] = []
        var current = ""
        var currentIsWhitespace: Bool?
        for character in line {
            let isWhitespace = character == " " || character == "\t"
            if currentIsWhitespace == nil || currentIsWhitespace == isWhitespace {
                current.append(character)
            } else {
                pieces.append(CommandPiece(text: current, isWhitespaceRun: currentIsWhitespace == true))
                current = String(character)
            }
            currentIsWhitespace = isWhitespace
        }
        if let currentIsWhitespace, !current.isEmpty {
            pieces.append(CommandPiece(text: current, isWhitespaceRun: currentIsWhitespace))
        }
        return pieces
    }

    /// The characters a path may be spelled with here. Anything else — a quote,
    /// a `$`, a backtick, a `:` in a URL, a `!`, a bracket — means the token is
    /// not a plain relative path, and it is left exactly as written. (Text a
    /// shell would expand or compute already trips the obfuscation rules.)
    private static let plainPathCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~@+-/*"
    )

    /// One argument, rewritten from the root — or nil when it is not a plain
    /// relative path and must be left alone.
    private static func resolving(_ token: String, against folder: String) -> String? {
        // `>out.log` and `>>out.log` write to a path; keep the operator and
        // resolve what it points at, so the redirect rules see the real target.
        var redirect = ""
        var body = token
        for operatorText in [">>", ">", "<"] where body.hasPrefix(operatorText) {
            redirect = operatorText
            body.removeFirst(operatorText.count)
            break
        }
        guard let first = body.unicodeScalars.first else { return nil }
        // A flag, an already-rooted path, a home-rooted path, or anything the
        // shell computes: not ours to resolve.
        guard first != "-", first != "/", first != "~", first != "$" else { return nil }
        guard body.unicodeScalars.allSatisfy({ plainPathCharacters.contains($0) }) else { return nil }
        return redirect + normalisedPath(folder + "/" + body)
    }

    /// Collapses `.` and `..` in a `~`- or `/`-rooted path, keeping a leading
    /// `~` literal. `..` that would climb past the root stays at the root,
    /// which is what a shell does.
    private static func normalisedPath(_ path: String) -> String {
        let isHomeRooted = path.hasPrefix("~")
        var components: [String] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if components.count > (isHomeRooted ? 1 : 0) {
                    components.removeLast()
                }
            default:
                components.append(String(component))
            }
        }
        if isHomeRooted {
            return components.joined(separator: "/")
        }
        return "/" + components.joined(separator: "/")
    }

    // MARK: - The catastrophe floor: refused EVEN under the autonomy grant
    //
    // The only rules `assess` checks before the grant can wave a command
    // through. These describe whole-disk / whole-home destruction that no
    // install ever needs; keeping them absolute is what lets "Let Iris take
    // control" be safe to grant once — a hallucinated fix that reaches for one
    // is stopped here with no tap, rather than running.

    private static let catastropheRules: [GuideAutopilotRiskRule] = [
        // `~/\*` and `\$HOME/\*` are here for the same reason the resolution
        // above exists: `rm -rf *` standing in the home folder is `rm -rf ~`
        // with a different spelling, and once a step can declare its own
        // working directory a guide can write it that way. The `/` and `/\*`
        // alternatives already covered the disk root; these cover the home
        // folder, which is the half a reader actually loses.
        .init(#"\brm\b[^\n]*\s-[a-z]*(rf|fr)[a-z]*\s+(/|/\*|~|~/|~/\*|\$HOME|\$HOME/\*)\s*(\n|$|;|&)"#,
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

    // MARK: - The two official installers, by exact text
    //
    // Reported from two machines: "Got stuck on the same problem with homebrew
    // installation, it won't install homebrew if it is not already installed"
    // and "It still doesn't know what to do if i don't have homebrew
    // installed." Without the grant, rustup's own one-liner is a `curl … | sh`
    // and this gate refused it outright, so a guide could only open a web page
    // and hope; Homebrew's fared little better, tripping the obfuscation rule
    // on its `$(` and stopping for a tap. The founder's call: "relax homebrew
    // shit allow them to just install homebrew and rustup in like through the
    // terminal commands."
    //
    // The allowance is the WHOLE COMMAND, matched literally. The alternative
    // shapes were both worse. Loosening `\b(curl|wget)\b … \|` would reopen
    // download-and-run generally, which is the one thing no confirm tap can
    // make informed — the reader cannot read what is on the other end. And an
    // allowlist of hosts would wave through
    // `https://raw.githubusercontent.com/Homebrew/install/HEAD/../../evil/x.sh`,
    // which is on the official host and is not the official script. Matching
    // the whole string also means a chained `… | sh && sudo …` never matches,
    // so nothing rides in behind the allowance.
    //
    // Widening this is a visible edit to a four-line list rather than a regex
    // tweak whose blast radius nobody can see. Spelled identically in
    // lib/guide-invariants.ts (`OFFICIAL_INSTALLER_COMMANDS`), which is the
    // gate the same command passes on the web side before it can be published.

    private static let officialInstallerCommands: Set<String> = [
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
        #"NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#,
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
    ]

    /// True only for one of the exact strings above, ignoring surrounding and
    /// repeated spaces — never for a command that merely contains one.
    static func isAnOfficialInstaller(_ command: String) -> Bool {
        let collapsed = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return officialInstallerCommands.contains(collapsed)
    }

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
