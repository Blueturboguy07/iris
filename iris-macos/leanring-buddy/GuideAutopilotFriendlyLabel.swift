//
//  GuideAutopilotFriendlyLabel.swift
//  leanring-buddy
//
//  Turns a raw shell command into one plain-English line for the reader who is
//  watching an install run. The audience is non-technical: "Getting the app's
//  code…" reads, `git clone https://github.com/…` does not. The real command
//  still shows underneath, de-emphasised, so the terminal still reads as
//  technical work rather than a toy — but the friendly line is what carries the
//  meaning.
//
//  A heuristic over the shapes install guides actually use, with an honest
//  catch-all. It never claims a different action than the command performs; the
//  worst case is the generic "Running a setup step…", never a wrong specific
//  one. Pure and `nonisolated` so `GuideAutopilotTerminalView` can call it while
//  building a row and a test can pin the mapping.
//

import Foundation

nonisolated enum GuideAutopilotFriendlyLabel {

    /// One plain sentence describing what `command` is doing, for the terminal.
    static func label(for command: String) -> String {
        let lowercased = command.lowercased()
        func mentions(_ needle: String) -> Bool { lowercased.contains(needle) }

        // Order matters: the most specific shapes first, the catch-all last.
        if mentions("git clone") {
            return "Getting the app's code…"
        }
        if mentions("git checkout") || mentions("git switch") {
            return "Getting the right version…"
        }
        if mentions("com.apple.quarantine") {
            return "Clearing macOS's download warning…"
        }
        if mentions("cargo tauri build") || mentions("tauri build") || mentions("cargo build")
            || mentions("xcodebuild") || (mentions("npm run") && mentions("build")) || mentions("npm run pack") {
            return "Building the app…"
        }
        if mentions("npm run dev") || mentions("tauri dev") || mentions("npm start") {
            return "Starting the app…"
        }
        if mentions("npm install") || mentions("npm ci") || mentions("pnpm install")
            || mentions("yarn install") || mentions("bun install") || (mentions("pip") && mentions("install")) {
            return "Installing the pieces it needs…"
        }
        if mentions("brew install") || mentions("apt install") || mentions("apt-get install")
            || mentions("winget install") || mentions("rustup") || mentions("nvm install")
            || mentions("install.sh") || (mentions("curl") && (mentions("| sh") || mentions("|sh") || mentions("| bash"))) {
            return "Installing a tool it needs…"
        }
        if lowercased.hasPrefix("cd ") || mentions("mkdir") || mentions("cp ") || mentions("mv ")
            || mentions("ln ") || mentions("chmod") || mentions("cp\t") {
            return "Setting things up…"
        }
        return "Running a setup step…"
    }
}
