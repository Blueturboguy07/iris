import Foundation
import MobileUserSimKit

public struct LongMediaRunRecord: Sendable {
    public let scenarioID: String
    public let scenarioTitle: String
    public let personaID: String
    public let personaDisplayName: String
    public let baseSeed: UInt64
    public let runIndex: Int
    public let outcome: ScenarioOutcome
}

/// Runs every scenario across its declared personas, `seeds` and `runsEach`
/// seeded repetitions each. Every run is reproducible from
/// `(scenarioID, personaID, baseSeed, runIndex)` alone.
public enum LongMediaSweep {
    public static func run(
        scenarios: [any LongMediaScenario], seeds: [UInt64], runsEach: Int
    ) -> [LongMediaRunRecord] {
        var records: [LongMediaRunRecord] = []
        for scenario in scenarios {
            for persona in scenario.personas {
                for seed in seeds {
                    for runIndex in 0..<runsEach {
                        let derivedSeed = SeededGenerator.derivedSeed(baseSeed: seed, runIndex: runIndex)
                        var rng = SeededGenerator(seed: derivedSeed)
                        let outcome = scenario.run(persona: persona, rng: &rng)
                        records.append(LongMediaRunRecord(
                            scenarioID: scenario.id, scenarioTitle: scenario.title,
                            personaID: persona.id, personaDisplayName: persona.displayName,
                            baseSeed: seed, runIndex: runIndex, outcome: outcome
                        ))
                    }
                }
            }
        }
        return records
    }
}

public enum LongMediaReport {
    public static func writeMarkdown(_ records: [LongMediaRunRecord], to url: URL) throws {
        var lines: [String] = []
        lines.append("# Long-clip import MiroFish report")
        lines.append("")
        let total = records.count
        let passed = records.filter { $0.outcome.passed }.count
        lines.append("Total runs: \(total). Passed: \(passed). Failed: \(total - passed).")
        lines.append("")

        let byScenario = Dictionary(grouping: records, by: { $0.scenarioID })
        for scenarioID in byScenario.keys.sorted() {
            let scenarioRecords = byScenario[scenarioID] ?? []
            let title = scenarioRecords.first?.scenarioTitle ?? scenarioID
            let scenarioPassed = scenarioRecords.filter { $0.outcome.passed }.count
            lines.append("## \(title) (`\(scenarioID)`)")
            lines.append("")
            lines.append("\(scenarioPassed)/\(scenarioRecords.count) runs passed.")
            let failing = scenarioRecords.filter { !$0.outcome.passed }
            if !failing.isEmpty {
                lines.append("")
                lines.append("Failing runs (reproduce with persona + `--seed <baseSeed> --run-index <runIndex>`):")
                lines.append("")
                lines.append("| persona | baseSeed | runIndex | failure class | message |")
                lines.append("|---|---|---|---|---|")
                for record in failing.prefix(20) {
                    let failureClass = record.outcome.failureClass?.rawValue ?? "unknown"
                    let message = record.outcome.message.replacingOccurrences(of: "|", with: "\\|")
                    lines.append("| \(record.personaDisplayName) | \(record.baseSeed) | \(record.runIndex) | \(failureClass) | \(message) |")
                }
            }
            lines.append("")
        }

        lines.append("## Failure taxonomy")
        lines.append("")
        let failingRecords = records.filter { !$0.outcome.passed }
        let byClass = Dictionary(grouping: failingRecords, by: { $0.outcome.failureClass ?? .hostSide })
        if byClass.isEmpty {
            lines.append("No failures.")
        } else {
            lines.append("| failure class | count |")
            lines.append("|---|---|")
            for failureClass in FailureClass.allCases {
                let count = byClass[failureClass]?.count ?? 0
                if count > 0 { lines.append("| \(failureClass.rawValue) | \(count) |") }
            }
        }
        lines.append("")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
