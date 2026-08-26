//
//  AssistantMachineFacts.swift
//  leanring-buddy
//
//  What this Mac actually has on it, told to the assistant before it answers.
//
//  Iris knew all of this and never said any of it. The chat prompt carried the
//  screenshots, the last few exchanges, and nothing else — no OS, no shell, no
//  installed tools, no publik URL — while `ToolVersionService` could check
//  fourteen tools, `AppInventoryService` knew every installed catalog app, and
//  `PublikAPIBaseURL` sat in the bundle.
//
//  The cost of that gap was concrete. Asked how to install pnpm on a machine
//  that already had Node 24 and had never had Homebrew, the model answered from
//  its priors — `brew install pnpm`, and then the Homebrew installer one-liner
//  to get Homebrew first. Neither was in the guide. The reader spent the session
//  installing a package manager they did not need, to get a tool `npm` already
//  had. A model with no facts answers with the most common answer, and the most
//  common answer for a Mac is Homebrew.
//
//  So the facts go in front of it. Everything here is cheap and local: a PATH
//  walk per tool and a few `ProcessInfo` reads. Nothing is fetched, nothing is
//  sent anywhere except into the prompt on the reader's own model route.
//

import Foundation

enum AssistantMachineFacts {

    /// Tools worth telling the model about, in the order a reader would care.
    ///
    /// `brew` is first and is the reason this list is not simply
    /// `ToolVersionService`'s allowlist: brew is absent from that allowlist, so
    /// `checkToolVersion` refuses it outright — the one tool whose presence the
    /// model most needs to know about was the one thing the app could not be
    /// asked. Presence here is a PATH lookup, which needs no allowlist.
    static let toolsWorthReporting = [
        "brew", "node", "npm", "pnpm", "yarn", "bun",
        "git", "python3", "uv", "cargo", "rustc", "go", "docker", "xcodebuild",
    ]

    /// A short block naming what is on this machine, or nil if nothing could be
    /// established (in which case saying nothing beats asserting an empty list,
    /// which would read as "you have none of these").
    ///
    /// `installedCatalogApps` is passed in rather than looked up so this stays
    /// free of the app-inventory actor and testable on its own.
    static func summary(
        publikBaseURL: String?,
        installedCatalogApps: [String]
    ) -> String? {
        var lines: [String] = []

        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let architecture = "Apple silicon"
        #else
        let architecture = "Intel"
        #endif
        lines.append("Machine: macOS \(operatingSystem), \(architecture).")

        let shell = (ProcessInfo.processInfo.environment["SHELL"] as NSString?)?
            .lastPathComponent ?? "zsh"
        lines.append("Shell: \(shell).")

        let present = toolsWorthReporting.filter { isOnThePath($0) }
        let absent = toolsWorthReporting.filter { !isOnThePath($0) }
        if !present.isEmpty {
            lines.append("Installed: \(present.joined(separator: ", ")).")
        }
        if !absent.isEmpty {
            // Stated positively as "not installed" rather than left out, because
            // an omission reads as unknown and the model fills unknowns with its
            // priors — which is exactly how Homebrew got recommended.
            lines.append("NOT installed: \(absent.joined(separator: ", ")).")
        }

        if let publikBaseURL, !publikBaseURL.isEmpty {
            lines.append("Publik is at \(publikBaseURL) — use that, never guess a publik url.")
        }
        if !installedCatalogApps.isEmpty {
            lines.append("Publik apps installed here: \(installedCatalogApps.joined(separator: ", ")).")
        }

        guard lines.count > 1 else { return nil }
        return """
            [What Iris can see about this Mac — these are checked facts, not guesses. \
            Prefer them over anything you assume about a typical Mac.
            \(lines.joined(separator: "\n"))]
            """
    }

    /// Whether an executable of this name is on the current PATH.
    ///
    /// Homebrew's own directories are checked as well: a GUI app launched from
    /// Finder inherits launchd's minimal PATH, not the login shell's, so
    /// /opt/homebrew/bin is frequently absent from PATH even when brew is
    /// installed. Missing it would produce the mirror image of the original bug
    /// — telling the model brew is absent when it is right there.
    static func isOnThePath(_ executableName: String) -> Bool {
        if case .found = ToolVersionService.locateExecutableOnSearchPath(named: executableName) {
            return true
        }
        let fileManager = FileManager.default
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            if fileManager.isExecutableFile(atPath: directory + "/" + executableName) {
                return true
            }
        }
        return false
    }
}
