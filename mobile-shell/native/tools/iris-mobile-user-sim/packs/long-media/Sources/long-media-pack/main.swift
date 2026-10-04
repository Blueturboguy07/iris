import Foundation
import LongMediaImportPack

var seeds: [UInt64] = [20260928, 1, 2]
var runsEach = 40
var outputPath = "./long-media-pack-report.md"

let arguments = CommandLine.arguments
var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--seeds":
        if index + 1 < arguments.count {
            seeds = arguments[index + 1].split(separator: ",").compactMap { UInt64($0) }
            index += 1
        }
    case "--runs":
        if index + 1 < arguments.count, let value = Int(arguments[index + 1]) {
            runsEach = value
            index += 1
        }
    case "--out":
        if index + 1 < arguments.count {
            outputPath = arguments[index + 1]
            index += 1
        }
    default:
        break
    }
    index += 1
}

let scenarios: [any LongMediaScenario] = [
    LocalFileVariousDurationsScenario(),
    SlowICloudDownloadWithPausesScenario(),
    ProviderDeletesTempFileEarlyScenario(),
    DiskNearlyFullScenario(),
    DiskFillingFromAnotherAppDuringImportScenario(),
    CancelMidwayScenario(),
    SeveralClipsCombinedUpToAnHourScenario(),
]

print("long-media-pack: \(scenarios.count) scenarios, seeds \(seeds), \(runsEach) runs each")
let records = LongMediaSweep.run(scenarios: scenarios, seeds: seeds, runsEach: runsEach)
let passed = records.filter { $0.outcome.passed }.count
print("\(passed)/\(records.count) runs passed")

let outURL = URL(fileURLWithPath: outputPath)
try LongMediaReport.writeMarkdown(records, to: outURL)
print("report written to \(outURL.path)")

if passed != records.count {
    exit(1)
}
