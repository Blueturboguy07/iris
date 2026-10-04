import Foundation

public enum Report {
    public static func writeJSON(_ records: [ScenarioRunRecord], to url: URL) throws {
        let rows: [[String: Any]] = records.map { record in
            [
                "scenarioId": record.identity.scenarioID,
                "scenarioTitle": record.scenarioTitle,
                "personaId": record.identity.personaID,
                "personaDisplayName": record.personaDisplayName,
                "baseSeed": record.identity.baseSeed,
                "runIndex": record.identity.runIndex,
                "derivedSeed": record.identity.derivedSeed,
                "passed": record.outcome.passed,
                "failureClass": record.outcome.failureClass?.rawValue ?? NSNull(),
                "message": record.outcome.message,
                "durationSeconds": record.durationSeconds,
                "personaInterview": [
                    "didFinish": record.outcome.personaInterview.didFinish,
                    "lastHonestMessage": record.outcome.personaInterview.lastHonestMessage,
                    "knewWhatToDoNext": record.outcome.personaInterview.knewWhatToDoNext,
                ],
                "evidence": record.outcome.evidence,
            ]
        }
        let root: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "totalRuns": records.count,
            "passedRuns": records.filter { $0.outcome.passed }.count,
            "failedRuns": records.filter { !$0.outcome.passed }.count,
            "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
    }

    public static func writeMarkdown(_ records: [ScenarioRunRecord], to url: URL) throws {
        var lines: [String] = []
        lines.append("# Mobile persona simulation report")
        lines.append("")
        let total = records.count
        let passed = records.filter { $0.outcome.passed }.count
        let failed = total - passed
        lines.append("Total runs: \(total). Passed: \(passed). Failed: \(failed).")
        lines.append("")

        let byScenario = Dictionary(grouping: records, by: { $0.identity.scenarioID })
        for scenarioID in byScenario.keys.sorted() {
            let scenarioRecords = byScenario[scenarioID] ?? []
            let title = scenarioRecords.first?.scenarioTitle ?? scenarioID
            let scenarioPassed = scenarioRecords.filter { $0.outcome.passed }.count
            lines.append("## \(title) (`\(scenarioID)`)")
            lines.append("")
            lines.append("\(scenarioPassed)/\(scenarioRecords.count) runs passed.")
            lines.append("")
            let failing = scenarioRecords.filter { !$0.outcome.passed }
            if failing.isEmpty {
                lines.append("No failing runs.")
            } else {
                lines.append("Failing runs (reproduce with `--scenario \(scenarioID) --exact-seed <baseSeed> --run-index <runIndex>`):")
                lines.append("")
                lines.append("| persona | baseSeed | runIndex | failure class | message |")
                lines.append("|---|---|---|---|---|")
                for record in failing.prefix(20) {
                    let failureClass = record.outcome.failureClass?.rawValue ?? "unknown"
                    let message = record.outcome.message.replacingOccurrences(of: "|", with: "\\|")
                    lines.append(
                        "| \(record.personaDisplayName) | \(record.identity.baseSeed) | \(record.identity.runIndex) | \(failureClass) | \(message) |"
                    )
                }
                if failing.count > 20 {
                    lines.append("")
                    lines.append("(\(failing.count - 20) more failing rows omitted; see the JSON report.)")
                }
            }
            lines.append("")
        }

        lines.append("## Failure taxonomy")
        lines.append("")
        let failingRecords = records.filter { !$0.outcome.passed }
        let byClass = Dictionary(grouping: failingRecords, by: { $0.outcome.failureClass ?? .setupPackaging })
        if byClass.isEmpty {
            lines.append("No failures.")
        } else {
            lines.append("| failure class | count |")
            lines.append("|---|---|")
            for failureClass in FailureClass.allCases {
                let count = byClass[failureClass]?.count ?? 0
                if count > 0 {
                    lines.append("| \(failureClass.rawValue) | \(count) |")
                }
            }
        }
        lines.append("")

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
