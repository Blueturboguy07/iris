//
//  GuideAutopilotCommandShape.swift
//  leanring-buddy
//
//  Text analysis of a command that is not about risk: does it ever return,
//  is it even finished, and what does it reach for. Pure functions over the
//  command string — nothing here runs a shell or executes any part of the
//  command, in the same spirit as `WatchLoop.repositoryPathAGitCloneWouldCreate`.
//

import Foundation

// nonisolated: pure text analysis, called from the shell session's queue.
nonisolated enum GuideAutopilotCommandShape {

    // MARK: - Commands that hold the shell open

    /// Dev servers and watchers never exit; running one on the main session
    /// would queue every later step behind it forever. The rehearsal harness
    /// checks npm start / npm run dev; autopilot meets the wider world.
    static func holdsTheShellOpen(_ command: String) -> Bool {
        let patterns = [
            #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?(start|dev|watch)\b"#,
            #"\bnext\s+dev\b"#,
            #"(^|\s|/)vite(\s|$)"#,
            #"\bdocker\s+compose\s+up\b(?![^\n]*\s-d\b)"#,
            #"\bpython3?\s+-m\s+http\.server\b"#,
            #"\bcargo\s+run\b"#,
            #"\bexpo\s+start\b"#,
            #"\bflutter\s+run\b"#,
            #"\brails\s+s(erver)?\b"#,
            #"\btauri\s+dev\b"#,
        ]
        return patterns.contains { command.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    // MARK: - Commands the shell would wait on forever

    /// A command that leaves the shell mid-construct never produces the end
    /// marker, and every later command would be typed into the wreck. Refuse
    /// to send one rather than detect the wedge afterwards.
    static func looksSyntacticallyIncomplete(_ command: String) -> Bool {
        if command.range(of: #"<<-?\s*['"]?\w+"#, options: .regularExpression) != nil {
            // Heredocs are legitimate shell, but a guide command should not
            // need one and a truncated heredoc wedges the session.
            return true
        }
        var insideSingleQuotes = false
        var insideDoubleQuotes = false
        var previousWasBackslash = false
        for character in command {
            if previousWasBackslash {
                previousWasBackslash = false
                continue
            }
            switch character {
            case "\\" where !insideSingleQuotes:
                previousWasBackslash = true
            case "'" where !insideDoubleQuotes:
                insideSingleQuotes.toggle()
            case "\"" where !insideSingleQuotes:
                insideDoubleQuotes.toggle()
            default:
                break
            }
        }
        if insideSingleQuotes || insideDoubleQuotes { return true }
        // A trailing backslash asks the shell for a continuation line that
        // will never come.
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if previousWasBackslash && trimmed.hasSuffix("\\") { return true }
        return false
    }

    // MARK: - What the command reaches for

    /// Hostnames named anywhere in the command — used to check a proposed
    /// fix against the hosts the guide itself already reaches, so a fix
    /// cannot quietly introduce a new network destination.
    static func hostsTheCommandWouldReach(_ command: String) -> Set<String> {
        var hosts: Set<String> = []
        let urlPattern = #"https?://([A-Za-z0-9.-]+)"#
        let sshPattern = #"git@([A-Za-z0-9.-]+):"#
        for pattern in [urlPattern, sshPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(command.startIndex..., in: command)
            regex.enumerateMatches(in: command, range: range) { match, _, _ in
                guard let match, let hostRange = Range(match.range(at: 1), in: command) else { return }
                hosts.insert(String(command[hostRange]).lowercased())
            }
        }
        return hosts
    }
}
