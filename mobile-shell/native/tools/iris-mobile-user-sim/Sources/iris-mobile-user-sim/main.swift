import Foundation
import MobileUserSimKit

struct CLIOptions {
    var runs = 40
    var seeds: [UInt64] = [20260926, 1, 2]
    var outputDirectory = URL(fileURLWithPath: "./iris-mobile-user-sim-reports")
    var list = false
    var scenarioID: String?
    var exactSeed: UInt64?
    var runIndex: Int?
}

func parseArguments(_ arguments: [String]) -> CLIOptions {
    var options = CLIOptions()
    var index = 0
    func nextValue() -> String? {
        guard index + 1 < arguments.count else { return nil }
        index += 1
        return arguments[index]
    }
    while index < arguments.count {
        switch arguments[index] {
        case "--runs":
            if let value = nextValue(), let intValue = Int(value) { options.runs = intValue }
        case "--seeds":
            if let value = nextValue() {
                options.seeds = value.split(separator: ",").compactMap { UInt64($0) }
            }
        case "--out":
            if let value = nextValue() { options.outputDirectory = URL(fileURLWithPath: value) }
        case "--list":
            options.list = true
        case "--scenario":
            options.scenarioID = nextValue()
        case "--exact-seed":
            if let value = nextValue() { options.exactSeed = UInt64(value) }
        case "--run-index":
            if let value = nextValue() { options.runIndex = Int(value) }
        default:
            break
        }
        index += 1
    }
    return options
}

let options = parseArguments(Array(CommandLine.arguments.dropFirst()))

let scratchRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("iris-mobile-user-sim-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratchRoot) }

let scenarios = try ScenarioCatalog.makeAll(scratchRoot: scratchRoot)

if options.list {
    for scenario in scenarios {
        print("\(scenario.id)\t\(scenario.title)\tpersonas=\(scenario.personas.map(\.id).joined(separator: ","))")
    }
    exit(0)
}

let runner = Runner(scratchRoot: scratchRoot)

func run() async -> Int32 {
    if let scenarioID = options.scenarioID, let exactSeed = options.exactSeed, let runIndex = options.runIndex {
        guard let scenario = scenarios.first(where: { $0.id == scenarioID }) else {
            FileHandle.standardError.write(Data("no such scenario: \(scenarioID)\n".utf8))
            return 1
        }
        guard let persona = scenario.personas.first else {
            FileHandle.standardError.write(Data("scenario \(scenarioID) declares no personas\n".utf8))
            return 1
        }
        let record = await runner.runOne(scenario: scenario, persona: persona, baseSeed: exactSeed, runIndex: runIndex)
        print("\(record.outcome.passed ? "PASS" : "FAIL")\t\(record.identity.scenarioID)\t\(record.identity.personaID)\tseed=\(record.identity.baseSeed)\trun=\(record.identity.runIndex)\t\(record.outcome.message)")
        return record.outcome.passed ? 0 : 1
    }

    let configuration = SweepConfiguration(runsPerScenarioPersona: options.runs, seeds: options.seeds)
    let records = await runner.run(scenarios: scenarios, configuration: configuration) { record in
        if !record.outcome.passed {
            print("FAIL\t\(record.identity.scenarioID)\t\(record.identity.personaID)\tseed=\(record.identity.baseSeed)\trun=\(record.identity.runIndex)\t\(record.outcome.message)")
        }
    }

    try? FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
    let jsonURL = options.outputDirectory.appendingPathComponent("report.json")
    let markdownURL = options.outputDirectory.appendingPathComponent("report.md")
    do {
        try Report.writeJSON(records, to: jsonURL)
        try Report.writeMarkdown(records, to: markdownURL)
    } catch {
        FileHandle.standardError.write(Data("failed to write report: \(error)\n".utf8))
    }

    let passed = records.filter { $0.outcome.passed }.count
    let failed = records.count - passed
    print("total=\(records.count) passed=\(passed) failed=\(failed)")
    print("report: \(jsonURL.path)")
    print("report: \(markdownURL.path)")
    return failed == 0 ? 0 : 1
}

let exitCode = await run()
exit(exitCode)
