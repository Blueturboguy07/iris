//
//  MachineCommandRunner.swift
//  leanring-buddy
//
//  Runs ONE reader-approved command on the Mac itself, outside the Tier C jail.
//
//  This is the executing end of the machine-state channel (`OnDemandEdit` ->
//  `.awaitingMachineCommandConsent` -> `approvePendingMachineCommand`). It runs
//  only after two gates the reader can see: the risk assessment's refusal floor
//  (`approveAfterAReaderTap`, which no tap can lower), and the reader's own
//  "Run it" on a card that shows the command verbatim.
//
//  It exists because Iris's editor could only ever change a repository's source,
//  and some bugs are not in the source. A permission grant keyed to a dead
//  build's identity is a real one: two edit runs rewrote WhimprFlow's Rust over
//  a ghost TCC record, because source was the only verb the loop had. This gives
//  the loop a second verb, kept deliberately narrow.
//
//  NO SHELL. The command is split into an argv and run directly, so nothing in
//  it — a stray `;`, a `$(…)`, a pipe — is re-interpreted by a shell. The risk
//  gate's own patterns already refuse pipe-to-shell and the destroyers; running
//  argv-directly means a command that slipped a metacharacter past the text
//  gate still cannot spawn a second process through one.
//

import Foundation

nonisolated enum MachineCommandRunner {

    /// The ONLY executables a machine command may run. An allowlist, not a
    /// denylist, and that direction is the point: the guide risk gate refuses
    /// the destroyers it KNOWS (`rm -rf`, pipe-to-shell), but it was written
    /// for install commands and a machine command that named a tool the gate
    /// had no rule for would sail through. The measured hole was
    /// `curl … | sh` — the pipe-to-shell ban lives in publik's guide
    /// preflight, not in the Swift `assess()`, so a machine command bypassed
    /// it entirely.
    ///
    /// So a machine command may only run tools whose whole job is reading or
    /// resetting local state, and which take no URL and spawn nothing:
    ///   tccutil   — reset a permission record (the case this channel was built for)
    ///   defaults  — read/delete a preferences key
    ///   launchctl — unload/remove a launch agent
    ///   pluginkit, sqlite3, plutil, killall — inspect/reset local state
    /// Adding to this list is a deliberate act; a model naming anything else
    /// gets an honest "not an allowed machine command", never a silent run.
    static let allowedExecutables: Set<String> = [
        "tccutil", "defaults", "launchctl", "pluginkit", "plutil", "sqlite3", "killall",
    ]

    /// The catastrophe-shaped subcommands that stay refused even for an
    /// allowed tool — `defaults delete` of a whole domain the reader did not
    /// name is fine, but there is no reason a machine fix ever needs
    /// `launchctl … remove` of an Apple daemon or `defaults delete -g` of the
    /// global domain. Kept tiny and specific; the allowlist above is the real
    /// safety, this is a second belt.
    static func namesAThingItMayNotTouch(_ argv: [String]) -> Bool {
        let joined = argv.joined(separator: " ")
        // The global preferences domain is the whole system's settings.
        if argv.contains("-g") || argv.contains("-globalDomain") || argv.contains("NSGlobalDomain") {
            return true
        }
        // An Apple system service is never the target of a user-app fix.
        if joined.contains("com.apple.") { return true }
        return false
    }

    /// Whether this command is one a machine channel may run at all — the
    /// allowlist plus the small refusal set, checked on the ALREADY-SPLIT argv
    /// so no shell string is ever consulted.
    static func isAnAllowedMachineCommand(_ command: String) -> Bool {
        let parts = argv(from: command)
        guard let tool = parts.first else { return false }
        let toolName = (tool as NSString).lastPathComponent
        guard allowedExecutables.contains(toolName) else { return false }
        return !namesAThingItMayNotTouch(parts)
    }

    /// How long a machine command may run. These are meant to be quick,
    /// idempotent state pokes (`tccutil reset …`, `defaults delete …`); a
    /// command that hangs is killed rather than left holding the flow.
    private static let deadline: TimeInterval = 30

    /// Split a command line into argv the way a POSIX shell would for the
    /// simple, quoted forms these commands take — honoring single and double
    /// quotes and backslash escapes — WITHOUT invoking a shell. Anything a real
    /// shell would treat as an operator (`|`, `;`, `&`, `$`, backticks, `>`)
    /// is NOT special here: it becomes a literal argument character, which is
    /// the safe direction, because the only commands that reach this point have
    /// already passed the risk gate that refuses those shapes outright.
    static func argv(from command: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var sawAnyCharacterForThisArgument = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inSingleQuote {
                if character == "'" { inSingleQuote = false } else { current.append(character) }
            } else if inDoubleQuote {
                if character == "\"" {
                    inDoubleQuote = false
                } else if character == "\\", index + 1 < characters.count,
                          characters[index + 1] == "\"" || characters[index + 1] == "\\" {
                    index += 1
                    current.append(characters[index])
                } else {
                    current.append(character)
                }
            } else {
                switch character {
                case "'": inSingleQuote = true; sawAnyCharacterForThisArgument = true
                case "\"": inDoubleQuote = true; sawAnyCharacterForThisArgument = true
                case "\\":
                    if index + 1 < characters.count {
                        index += 1
                        current.append(characters[index])
                        sawAnyCharacterForThisArgument = true
                    }
                case " ", "\t", "\n":
                    if sawAnyCharacterForThisArgument {
                        arguments.append(current)
                        current = ""
                        sawAnyCharacterForThisArgument = false
                    }
                default:
                    current.append(character)
                    sawAnyCharacterForThisArgument = true
                }
            }
            index += 1
        }
        if sawAnyCharacterForThisArgument { arguments.append(current) }
        return arguments
    }

    /// Resolve the executable's absolute path. The command names a tool
    /// (`tccutil`, `defaults`), not a path; a machine command must never carry
    /// its own executable path from a working directory, so this looks only in
    /// the fixed system locations these tools actually live in.
    static func resolveExecutable(named name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run it. Returns the exit status and a short, scrubbed output tail — the
    /// same two facts the jailed loop reports for any command, so the model can
    /// read the outcome of its own request on the next turn.
    static func run(_ command: String) async -> (exitStatus: Int32, outputTail: String) {
        // The allowlist is enforced HERE too, not only at the consent card, so
        // this function is safe to call from anywhere — a second, independent
        // gate on the one line that actually spawns a process.
        guard isAnAllowedMachineCommand(command) else {
            return (exitStatus: 126, outputTail: "not an allowed machine command")
        }
        let parts = argv(from: command)
        guard let toolName = parts.first,
              let executablePath = resolveExecutable(named: toolName) else {
            return (exitStatus: 127, outputTail: "no such command on this Mac")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = Array(parts.dropFirst())
                // An empty, non-inherited environment plus a fixed PATH: the
                // command cannot pick up anything from the app's own launch
                // environment, and there is nothing here for a subprocess to
                // read even if one were somehow spawned.
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = outputPipe

                let collected = NSMutableData()
                let handle = outputPipe.fileHandleForReading
                handle.readabilityHandler = { fileHandle in
                    collected.append(fileHandle.availableData)
                }

                do {
                    try process.run()
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(returning: (
                        exitStatus: 126,
                        outputTail: "couldn't start: \(error.localizedDescription)"
                    ))
                    return
                }

                let deadlineWorkItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: deadlineWorkItem)
                process.waitUntilExit()
                deadlineWorkItem.cancel()
                handle.readabilityHandler = nil

                let rawText = String(data: collected as Data, encoding: .utf8) ?? ""
                // Same egress scrubbing every model-bound command output goes
                // through, then a short tail — the reader saw the command, and
                // the model needs only the outcome.
                let scrubbedTail = GuideAutopilotOutputBuffer.scrubbed(rawText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .suffix(400)
                continuation.resume(returning: (
                    exitStatus: process.terminationStatus,
                    outputTail: String(scrubbedTail)
                ))
            }
        }
    }
}
