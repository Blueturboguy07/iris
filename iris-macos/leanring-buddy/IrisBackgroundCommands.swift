//
//  IrisBackgroundCommands.swift
//  leanring-buddy
//
//  The lane for a command that is SUPPOSED to keep running: a dev server, a
//  watcher, a local API somebody is installing.
//
//  Why this exists. Chat's `run_a_command_in_the_terminal` runs a command to
//  completion with a 120-second deadline, which is right for every command
//  that ends and wrong for every command that doesn't. A reader installing an
//  app got `npm run dev` started for them; vite printed "ready … Local:
//  http://localhost:5174/"; the deadline hit; the process was killed; and the
//  model — reading the ready line and knowing it had stopped the command —
//  told them "i stopped the command after 2 minutes since dev servers run
//  forever, but it's still serving." It was not serving. It had been dead
//  since the sentence describing it as alive.
//
//  Two things follow, and this file is built around both:
//
//  1. A long-lived process needs somewhere to live. Before this there was no
//     detach, no nohup, no background spawn anywhere in the app — a dev
//     server was not a thing Iris could leave running, at all.
//
//  2. "Is it running?" must be answered by asking the KERNEL, not by
//     remembering a line of stdout. `isAlive` sends signal 0 to the pid every
//     single time it is called. A "ready on :5174" line read two minutes ago
//     is not evidence of anything, and it is exactly what produced the lie.
//
//  What this is NOT: a way around the risk gate. Nothing here assesses a
//  command. Callers hand in a `GuideAutopilotApprovedCommand`, which only the
//  gate can mint, so "start an unassessed command in the background" is not
//  expressible here any more than it is in chat's foreground lane.
//

import Foundation

/// One command Iris started and deliberately left running.
struct IrisBackgroundCommand: Identifiable, Sendable {
    let id: String
    let commandText: String
    let pid: pid_t
    let startedAt: Date
    /// Where stdout and stderr are going, so the model can read back what a
    /// server actually printed instead of guessing at it.
    let logPath: String
}

/// A live status line for one background command, computed at the moment it is
/// asked for.
struct IrisBackgroundCommandStatus: Sendable {
    let command: IrisBackgroundCommand
    let isRunning: Bool
    /// The tail of what it has printed since it started, scrubbed by the
    /// caller before it ever reaches a model.
    let recentOutput: String
}

@MainActor
final class IrisBackgroundCommands {

    static let shared = IrisBackgroundCommands()

    /// How long to let a process settle before reporting whether it survived.
    /// A command that dies instantly — a typo, a missing script, a port
    /// conflict it refuses to work around — must be reported as dead, not as
    /// "started". Two seconds is enough for an immediate exit to have
    /// happened and short enough that nobody is waiting on it.
    static let settleSeconds: TimeInterval = 2

    /// The ceiling on how many of these one Mac can accumulate. A reader
    /// asking for the same server three times should not get three of them.
    static let maximumConcurrent = 8

    /// Bytes of a log file read back for the model. The whole point is the
    /// last thing it said, not its entire history.
    private static let logTailByteLimit = 4_000

    /// Persisted so a crash cannot orphan a server forever — see `reapLeftovers`.
    private static let leftoversDefaultsKey = "iris.backgroundCommands.leftovers"

    private var running: [String: (command: IrisBackgroundCommand, process: Process)] = [:]

    private init() {}

    // MARK: - Starting

    enum StartOutcome {
        /// The process is alive after the settle window. This is the only
        /// outcome that may be described to a reader as running.
        case running(IrisBackgroundCommand)
        /// It started and was gone within the settle window — a real failure
        /// with real output, not a "probably fine".
        case exitedImmediately(exitCode: Int32, output: String)
        case couldNotStart(reason: String)
        case tooMany
    }

    /// Starts an approved command and leaves it running.
    ///
    /// The command is handed to a login shell the same way chat's foreground
    /// lane hands one over, so a reader's PATH, nvm and aliases apply — a dev
    /// server that only exists under their node version has to find it.
    func start(
        _ approvedCommand: GuideAutopilotApprovedCommand,
        workingDirectory: String
    ) async -> StartOutcome {
        guard running.count < Self.maximumConcurrent else { return .tooMany }

        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-bg-\(id).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else {
            return .couldNotStart(reason: "Iris could not open a log file for it.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // `-l` for a login shell so the reader's own environment applies;
        // `-c` because this is one command, not an interactive session.
        process.arguments = ["-lc", approvedCommand.text]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            return .couldNotStart(reason: error.localizedDescription)
        }

        let record = IrisBackgroundCommand(
            id: id,
            commandText: approvedCommand.text,
            pid: process.processIdentifier,
            startedAt: Date(),
            logPath: logURL.path
        )

        // Settle, then ask the kernel. Reporting "started" off the fact that
        // `run()` did not throw is the same mistake as reporting "serving"
        // off a ready line: spawning succeeded, which says nothing about
        // whether the thing is still there.
        try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))

        if process.isRunning {
            running[id] = (record, process)
            rememberLeftover(record)
            irisTrace("bg: started \(id) pid=\(record.pid) — \(approvedCommand.text.prefix(60))")
            return .running(record)
        }

        let output = readLogTail(atPath: record.logPath)
        irisTrace("bg: \(id) exited immediately, status=\(process.terminationStatus)")
        return .exitedImmediately(exitCode: process.terminationStatus, output: output)
    }

    // MARK: - Asking the machine

    /// Whether this pid is alive RIGHT NOW. Signal 0 performs the permission
    /// and existence checks and delivers nothing, which is exactly the
    /// question being asked.
    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Every command Iris is still holding, each with a freshly computed
    /// liveness. Anything found dead is dropped from the registry on the way
    /// out, so the list never reports a ghost twice.
    func statuses() -> [IrisBackgroundCommandStatus] {
        var result: [IrisBackgroundCommandStatus] = []
        for (id, entry) in running {
            let alive = Self.isAlive(pid: entry.command.pid)
            if !alive { running.removeValue(forKey: id); forgetLeftover(entry.command) }
            result.append(
                IrisBackgroundCommandStatus(
                    command: entry.command,
                    isRunning: alive,
                    recentOutput: readLogTail(atPath: entry.command.logPath)
                )
            )
        }
        return result.sorted { $0.command.startedAt < $1.command.startedAt }
    }

    func status(id: String) -> IrisBackgroundCommandStatus? {
        statuses().first { $0.command.id == id }
    }

    // MARK: - Stopping

    @discardableResult
    func stop(id: String) -> Bool {
        guard let entry = running[id] else { return false }
        terminate(entry.process, pid: entry.command.pid)
        running.removeValue(forKey: id)
        forgetLeftover(entry.command)
        irisTrace("bg: stopped \(id)")
        return true
    }

    /// Called when the app is going away. A process Iris started is Iris's to
    /// clean up — leaving a dev server bound to a port after the app that
    /// started it has quit is its own bug report.
    func stopEverything() {
        for (id, entry) in running {
            terminate(entry.process, pid: entry.command.pid)
            forgetLeftover(entry.command)
            irisTrace("bg: stopped \(id) on shutdown")
        }
        running.removeAll()
    }

    private func terminate(_ process: Process, pid: pid_t) {
        guard Self.isAlive(pid: pid) else { return }
        process.terminate()
        // A server that ignores SIGTERM still has to go.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if IrisBackgroundCommands.isAlive(pid: pid) { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Surviving a crash

    /// A clean quit goes through `stopEverything`. A crash does not, which
    /// would leave a server running with nothing holding its handle. Each
    /// start records its pid and command; the next launch kills anything
    /// still answering to both.
    ///
    /// The command text is the identity check, not the pid alone: pids are
    /// recycled, and killing a stranger's process because it inherited a
    /// number is far worse than leaking one of ours.
    func reapLeftovers() {
        let stored = UserDefaults.standard.array(forKey: Self.leftoversDefaultsKey) as? [[String: Any]] ?? []
        guard !stored.isEmpty else { return }
        for entry in stored {
            guard let pidValue = entry["pid"] as? Int32,
                  let commandText = entry["command"] as? String else { continue }
            let pid = pid_t(pidValue)
            guard Self.isAlive(pid: pid) else { continue }
            guard Self.processLooksLikeOurs(pid: pid, commandText: commandText) else {
                irisTrace("bg: leftover pid \(pid) is somebody else's now — left alone")
                continue
            }
            kill(pid, SIGTERM)
            irisTrace("bg: reaped leftover pid \(pid) from a previous run")
        }
        UserDefaults.standard.removeObject(forKey: Self.leftoversDefaultsKey)
    }

    /// Asks `ps` what that pid is actually running and insists it still looks
    /// like the shell invocation we started.
    static func processLooksLikeOurs(pid: pid_t, commandText: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(data: data, encoding: .utf8) ?? ""
        guard line.contains("zsh") else { return false }
        // A distinctive slice of the command, not the whole thing: ps
        // truncates long command lines.
        let fingerprint = String(commandText.prefix(30))
        return !fingerprint.isEmpty && line.contains(fingerprint)
    }

    private func rememberLeftover(_ record: IrisBackgroundCommand) {
        var stored = UserDefaults.standard.array(forKey: Self.leftoversDefaultsKey) as? [[String: Any]] ?? []
        stored.append(["pid": Int32(record.pid), "command": record.commandText])
        UserDefaults.standard.set(stored, forKey: Self.leftoversDefaultsKey)
    }

    private func forgetLeftover(_ record: IrisBackgroundCommand) {
        let stored = UserDefaults.standard.array(forKey: Self.leftoversDefaultsKey) as? [[String: Any]] ?? []
        let kept = stored.filter { ($0["pid"] as? Int32) != Int32(record.pid) }
        UserDefaults.standard.set(kept, forKey: Self.leftoversDefaultsKey)
    }

    // MARK: - Reading back

    func readLogTail(atPath path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.logTailByteLimit) ? size - UInt64(Self.logTailByteLimit) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
