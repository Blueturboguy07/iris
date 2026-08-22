//
//  OnDemandEditRunLog.swift
//  leanring-buddy
//
//  A plain-text, per-run log of ONE on-demand edit: the request, Iris's own
//  narration, every real command with its exit and output tail, the nudges and
//  waits, and the outcome — persisted so a failed run can be diagnosed after
//  the fact. It exists because a real dogfood failure (Aug 22 2026: "couldn't
//  converge... nothing was applied") left NOTHING to inspect: the whole
//  conversation lived only in memory, and `irisTrace`'s iris.log records
//  structure only by design.
//
//  This file is deliberately different from iris.log and does not weaken its
//  rule: it mirrors ONLY what the takeover terminal already displayed to the
//  reader (model-bound and displayed text is secret-scrubbed upstream on the
//  same egress paths), it never leaves the machine, it lives in its own
//  clearly-named directory (~/Library/Logs/Iris/edit-runs), and old runs are
//  pruned so the folder stays a handful of files.
//
//  Logging must never break a run: every filesystem miss is swallowed, and a
//  failed init simply means the run goes unlogged (the caller holds an
//  Optional and carries on).
//

import Foundation

@MainActor
final class OnDemandEditRunLog {

    // Nonisolated so the init's default argument (evaluated in a nonisolated
    // context under Swift 6) can read it — both are immutable constants.
    nonisolated static let runsDirectoryPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Logs/Iris/edit-runs")

    /// How many run files the directory keeps. Pruned oldest-first on every
    /// new run, so the folder never grows past a screenful.
    nonisolated static let maximumKeptRunLogFiles = 20

    /// Where this run's log lives, for the "what Iris tried is logged at…"
    /// line the terminal shows when a run ends.
    let filePath: String

    private var fileHandle: FileHandle?
    private let lineTimestampFormatter: DateFormatter

    /// Creates the directory, prunes old runs, and opens this run's file with
    /// a header naming the app, the kind, and the (already-scrubbed) request.
    /// Returns nil when the file cannot be created — never an error the run
    /// should see.
    init?(
        appSlug: String,
        kindLabel: String,
        scrubbedRequest: String,
        directoryPath: String = OnDemandEditRunLog.runsDirectoryPath,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        Self.pruneOldRunLogs(inDirectoryPath: directoryPath)

        let fileNameFormatter = DateFormatter()
        fileNameFormatter.locale = Locale(identifier: "en_US_POSIX")
        fileNameFormatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        // Timestamp-first names sort chronologically by plain string compare,
        // which is what the pruner relies on.
        let fileName = "\(fileNameFormatter.string(from: now))-\(appSlug).log"
        filePath = (directoryPath as NSString).appendingPathComponent(fileName)

        lineTimestampFormatter = DateFormatter()
        lineTimestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        lineTimestampFormatter.dateFormat = "HH:mm:ss"

        let header = """
        Iris on-demand edit — \(appSlug) (\(kindLabel))
        Started: \(now)
        Request: \(scrubbedRequest)

        """
        guard fileManager.createFile(atPath: filePath, contents: Data(header.utf8)),
              let handle = FileHandle(forWritingAtPath: filePath) else {
            return nil
        }
        handle.seekToEndOfFile()
        fileHandle = handle
    }

    /// One timestamped line of the run. Multi-line text is indented under its
    /// timestamp so commands with heredocs stay readable.
    func record(_ line: String, at date: Date = Date()) {
        let stamp = lineTimestampFormatter.string(from: date)
        let indented = line
            .components(separatedBy: "\n")
            .enumerated()
            .map { $0.offset == 0 ? $0.element : "         \($0.element)" }
            .joined(separator: "\n")
        fileHandle?.write(Data("[\(stamp)] \(indented)\n".utf8))
    }

    /// The run's final line; closes the file. Safe to call once per run —
    /// later `record` calls after this write nothing.
    func finish(outcome: String) {
        record("outcome: \(outcome)")
        try? fileHandle?.close()
        fileHandle = nil
    }

    /// Keep the newest `maximumKeptRunLogFiles - 1` files (the run being
    /// created makes it the maximum). Names are timestamp-first, so a plain
    /// descending sort is newest-first.
    static func pruneOldRunLogs(inDirectoryPath directoryPath: String) {
        let fileManager = FileManager.default
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryPath) else {
            return
        }
        let runLogFileNames = fileNames.filter { $0.hasSuffix(".log") }.sorted(by: >)
        for staleFileName in runLogFileNames.dropFirst(max(maximumKeptRunLogFiles - 1, 0)) {
            try? fileManager.removeItem(
                atPath: (directoryPath as NSString).appendingPathComponent(staleFileName)
            )
        }
    }
}
