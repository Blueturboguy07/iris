//
//  OnDemandEditInterruptedRunRecovery.swift
//  leanring-buddy
//
//  What happens to an on-demand edit's files when Iris quits before the edit
//  is committed or reverted.
//
//  THE REPORT (Sep 3 2026). The card read: "Your clone has changes Iris won't
//  touch: your clone of WhimprFlow has 2 changes that aren't committed —
//  src-tauri/src/lib.rs (modified Sep 3), src-tauri/src/paste.rs (modified
//  Sep 3)." The reader had not touched either file. Iris had. The run log
//  (20260903-160125354-whimprflow.log) shows the engine applying edits to both
//  at 16:04:26, then stopping at 16:04:33 on "manifest consent requested: Add
//  the Rust crate block2 0.6 to src-tauri/Cargo.toml" — the consent card.
//  iris.log for that process ends there, and the next Iris process starts
//  twelve minutes later. Iris quit, or was relaunched, with the run parked on
//  the card. The engine had already written its edits into the working tree
//  and was awaiting a `CheckedContinuation` that died with the process: the
//  approve path (apply, build, commit) and the decline path (`git checkout --
//  . && git clean -fd`) both live PAST that continuation, so neither ran. The
//  next attempt on the app, sixteen minutes later, found Iris's own orphaned
//  edits and refused — blaming the reader for them.
//
//  THE FIX IS A RECORD ON DISK. The moment the engine reports files edited,
//  the run writes down which clone, which base commit, and which paths it
//  touched; the record goes away when the run commits, reverts, or is reset.
//  Two readers of the record: the app at LAUNCH (a crash, a force quit, a
//  relaunch for an update) and the app at QUIT (a clean quit mid-run). Both
//  call `recoverNow()`, which reverts EXACTLY the recorded paths — and only if
//  the tree is dirty in nothing else, and only if HEAD is still the recorded
//  base. A tree that also carries the reader's own work is left alone, and the
//  record stays so the dirty-clone card can say which of the files were
//  Iris's.
//
//  SYNCHRONOUS BY DESIGN. `applicationWillTerminate` gets a few seconds and no
//  run loop; a `Process` running git in the clone finishes in well under one.
//  Nothing here goes through the login-shell runner, which spawns a `zsh -l`
//  to learn the reader's PATH and is the wrong cost at quit.
//

import Foundation

/// One in-flight edit's footprint on the reader's clone.
struct OnDemandEditInFlightRecord: Codable, Equatable {
    let appSlug: String
    /// Symlink-resolved, the same value the run's lock and runner key off.
    let clonePath: String
    /// HEAD before the run. If HEAD has moved since, the run committed and the
    /// record is stale.
    let baseCommit: String
    /// Repo-relative paths the engine reported editing, in the order reported.
    var pathsIrisEdited: [String]
    let startedAt: Date
    /// The run's own log, so the recovery can write into it what it did.
    let runLogPath: String?
    /// What the run was parked on when Iris went away, when known — the
    /// sentence the dirty-clone card and the run log use to explain the orphan.
    var whatIrisWasWaitingFor: String?
}

enum OnDemandEditInterruptedRunRecovery {

    nonisolated static let defaultRecordPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Iris/on-demand-edit-in-flight.json")

    enum Outcome: Equatable {
        /// No record, or a record naming a clone that is no longer there.
        case nothingToRecover
        /// HEAD moved past the recorded base: the run committed. The record was
        /// stale and is gone.
        case theRunHadAlreadyCommitted(clonePath: String)
        /// The tree was clean already (the engine's own revert ran). Record gone.
        case theTreeWasAlreadyClean(clonePath: String)
        /// Exactly Iris's paths were dirty, and they were put back.
        case revertedIrisOwnEdits(clonePath: String, paths: [String])
        /// The tree carries something that is not in the record — the reader's
        /// own work, most likely. Nothing was touched; the record stays so the
        /// dirty-clone card can name Iris's files.
        case leftAlone(clonePath: String, reason: String, pathsIrisEdited: [String])
    }

    // MARK: - The record

    static func remember(_ record: OnDemandEditInFlightRecord, recordPath: String = defaultRecordPath) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        let directory = (recordPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: recordPath), options: .atomic)
    }

    static func forget(recordPath: String = defaultRecordPath) {
        try? FileManager.default.removeItem(atPath: recordPath)
    }

    static func recordOnDisk(recordPath: String = defaultRecordPath) -> OnDemandEditInFlightRecord? {
        guard let data = FileManager.default.contents(atPath: recordPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OnDemandEditInFlightRecord.self, from: data)
    }

    // MARK: - The recovery

    /// Reverts what the record says Iris left uncommitted, if and only if that
    /// is all that is uncommitted. Safe to call when there is nothing to do.
    @discardableResult
    static func recoverNow(recordPath: String = defaultRecordPath, now: Date = Date()) -> Outcome {
        guard let record = recordOnDisk(recordPath: recordPath) else { return .nothingToRecover }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.clonePath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath: (record.clonePath as NSString).appendingPathComponent(".git"))
        else {
            forget(recordPath: recordPath)
            return .nothingToRecover
        }

        let head = runGit(["rev-parse", "HEAD"], in: record.clonePath)
        guard head.exitCode == 0 else {
            // Git itself could not be asked. Leave everything, including the
            // record, for a later attempt.
            return .leftAlone(clonePath: record.clonePath, reason: "git could not read HEAD", pathsIrisEdited: record.pathsIrisEdited)
        }
        if head.output.trimmingCharacters(in: .whitespacesAndNewlines) != record.baseCommit {
            forget(recordPath: recordPath)
            return .theRunHadAlreadyCommitted(clonePath: record.clonePath)
        }

        let status = runGit(["status", "--porcelain", "--untracked-files=all"], in: record.clonePath)
        guard status.exitCode == 0 else {
            return .leftAlone(clonePath: record.clonePath, reason: "git could not read the working tree", pathsIrisEdited: record.pathsIrisEdited)
        }
        let dirtyEntries = dirtyEntries(fromPorcelain: status.output)
        if dirtyEntries.isEmpty {
            forget(recordPath: recordPath)
            return .theTreeWasAlreadyClean(clonePath: record.clonePath)
        }

        let pathsIrisEdited = Set(record.pathsIrisEdited.map(normalized))
        let pathsThatAreNotIriss = dirtyEntries.map(\.path).filter { !pathsIrisEdited.contains(normalized($0)) }
        guard pathsThatAreNotIriss.isEmpty else {
            let reason = "the clone also has changes Iris did not make (\(pathsThatAreNotIriss.prefix(3).joined(separator: ", "))\(pathsThatAreNotIriss.count > 3 ? ", …" : ""))"
            appendToTheRunLog(record, line: "recovery: Iris went away before this run finished\(waitingClause(record)). Its unfinished edits were NOT reverted because \(reason).", now: now)
            return .leftAlone(clonePath: record.clonePath, reason: reason, pathsIrisEdited: record.pathsIrisEdited)
        }

        // Only Iris's paths are dirty. Tracked ones go back to HEAD; untracked
        // ones (files the engine created) are removed. Path by path, never
        // `-- .`, so a mistake in the record can only ever touch a named file.
        var revertedPaths: [String] = []
        for entry in dirtyEntries {
            let result = entry.isUntracked
                ? runGit(["clean", "-f", "--", entry.path], in: record.clonePath)
                : runGit(["checkout", "--", entry.path], in: record.clonePath)
            if result.exitCode == 0 { revertedPaths.append(entry.path) }
        }
        forget(recordPath: recordPath)
        appendToTheRunLog(record, line: "recovery: Iris went away before this run finished\(waitingClause(record)). Its unfinished edits to \(revertedPaths.joined(separator: ", ")) were reverted; the clone is clean again.", now: now)
        return .revertedIrisOwnEdits(clonePath: record.clonePath, paths: revertedPaths)
    }

    private static func waitingClause(_ record: OnDemandEditInFlightRecord) -> String {
        guard let waitingFor = record.whatIrisWasWaitingFor else { return "" }
        return " (it was waiting on \(waitingFor))"
    }

    // MARK: - Git, synchronously

    struct GitResult: Equatable {
        let exitCode: Int32
        let output: String
    }

    /// The system git, without the login-shell PATH walk. Falls back to the
    /// common Homebrew locations for a Mac without the command line tools.
    static func runGit(_ arguments: [String], in repoRootPath: String) -> GitResult {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let gitPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return GitResult(exitCode: 127, output: "git not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: repoRootPath)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return GitResult(exitCode: 126, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    struct DirtyEntry: Equatable {
        let path: String
        let isUntracked: Bool
    }

    /// `XY path` per line; `?? path` is untracked; a rename names its
    /// destination. The same shape `OnDemandEditDirtyTreeReport` parses, kept
    /// separate because this one must not consult the file system.
    static func dirtyEntries(fromPorcelain porcelain: String) -> [DirtyEntry] {
        var entries: [DirtyEntry] = []
        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).replacingOccurrences(of: "\r", with: "")
            guard line.count >= 4 else { continue }
            let statusCode = String(line.prefix(2))
            var path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let arrowRange = path.range(of: " -> ") {
                path = String(path[arrowRange.upperBound...])
            }
            if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            guard !path.isEmpty else { continue }
            entries.append(DirtyEntry(path: path, isUntracked: statusCode == "??"))
        }
        return entries
    }

    private static func normalized(_ path: String) -> String {
        var normalizedPath = path
        while normalizedPath.hasPrefix("./") { normalizedPath.removeFirst(2) }
        while normalizedPath.hasSuffix("/") { normalizedPath.removeLast() }
        return normalizedPath
    }

    private static func appendToTheRunLog(_ record: OnDemandEditInFlightRecord, line: String, now: Date) {
        guard let runLogPath = record.runLogPath,
              let handle = FileHandle(forWritingAtPath: runLogPath) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        handle.write(Data("\n\(formatter.string(from: now))  \(line)\n".utf8))
    }
}
