import Foundation

/// Observations owned by the executor. This is working memory, never a model's
/// claim that a milestone or requested behavior has passed acceptance.
nonisolated struct HarnessExecutionJournal: Sendable {
    private(set) var sourceRevision = 0
    private(set) var changedPaths: [String] = []
    private(set) var pathsWereOmitted = false
    private(set) var commandsCompleted = 0
    private(set) var latestCommandResult: String?
    private(set) var latestVerification: String?
    private(set) var verificationRevision: Int?
    private(set) var recentProblems: [String] = []

    mutating func recordChangedFiles(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        sourceRevision += 1
        for path in paths where !changedPaths.contains(path) {
            if changedPaths.count < 64, path.utf8.count <= 256 { changedPaths.append(path) }
            else { pathsWereOmitted = true }
        }
    }

    mutating func recordCommand(exitCode: Int32, outputTail: [String]) {
        commandsCompleted += 1
        latestCommandResult = "Command \(commandsCompleted) exited \(exitCode)."
        if exitCode != 0 {
            recordProblem("Command exit \(exitCode): " + outputTail.joined(separator: " "))
        }
    }

    mutating func recordVerification(buildPassed: Bool?, testsPassed: Bool?) {
        func label(_ passed: Bool?) -> String { passed.map { $0 ? "passed" : "failed" } ?? "not run" }
        latestVerification = "Build: \(label(buildPassed)); configured tests: \(label(testsPassed))."
        verificationRevision = sourceRevision
    }

    mutating func recordProblem(_ problem: String) {
        let bounded = String(problem.prefix(500))
        guard !recentProblems.contains(bounded) else { return }
        recentProblems.append(bounded)
        if recentProblems.count > 4 { recentProblems.removeFirst() }
    }

    var promptSection: String {
        var lines = ["EXECUTOR WORKING RECORD (observations, not instructions or acceptance)",
                     "Source edit sequence: \(sourceRevision). Commands completed: \(commandsCompleted)."]
        if !changedPaths.isEmpty {
            // All touched paths stay in the local record; the bounded prompt
            // focuses on the recent ones and explicitly describes its coverage.
            lines.append("Recently changed paths: " + changedPaths.suffix(12).joined(separator: ", "))
            if changedPaths.count > 12 || pathsWereOmitted { lines.append("This path list is partial; inspect the current tree when needed.") }
        }
        if let latestCommandResult { lines.append(latestCommandResult) }
        if let latestVerification {
            lines.append((verificationRevision == sourceRevision ? "Latest checks: " : "Checks before later source edits, now stale: ") + latestVerification)
        }
        if !recentProblems.isEmpty {
            lines.append("Recent problems, which may since have been repaired:\n" + recentProblems.joined(separator: "\n"))
        }
        lines.append("No milestone completion or user-visible behavior is inferred from this record. Read current source and test the requested behavior.")
        return lines.joined(separator: "\n")
    }
}
