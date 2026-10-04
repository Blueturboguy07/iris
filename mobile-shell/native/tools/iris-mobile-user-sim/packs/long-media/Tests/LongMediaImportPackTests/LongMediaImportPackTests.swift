import XCTest
@testable import LongMediaImportPack

/// Runs the whole long-media MiroFish pack under `swift test`, so a
/// regression in the real `NativeMediaImportPolicy` this pack drives shows
/// up in the normal gate, not only when someone remembers to run the
/// `long-media-pack` executable by hand.
final class LongMediaImportPackTests: XCTestCase {
    private let scenarios: [any LongMediaScenario] = [
        LocalFileVariousDurationsScenario(),
        SlowICloudDownloadWithPausesScenario(),
        ProviderDeletesTempFileEarlyScenario(),
        DiskNearlyFullScenario(),
        DiskFillingFromAnotherAppDuringImportScenario(),
        CancelMidwayScenario(),
        SeveralClipsCombinedUpToAnHourScenario(),
    ]

    func testEverySeededRunPassesAcrossAllScenariosAndPersonas() {
        let records = LongMediaSweep.run(scenarios: scenarios, seeds: [20260928, 1, 2, 777], runsEach: 25)
        XCTAssertGreaterThan(records.count, 0, "the sweep must actually produce runs")
        let failing = records.filter { !$0.outcome.passed }
        if !failing.isEmpty {
            let firstFew = failing.prefix(5).map { record in
                "\(record.scenarioID)/\(record.personaID) seed=\(record.baseSeed) run=\(record.runIndex): \(record.outcome.message)"
            }.joined(separator: "\n")
            XCTFail("\(failing.count)/\(records.count) seeded runs failed:\n\(firstFew)")
        }
    }

    // MARK: Individual scenario checks, so a failure names which one broke
    // without needing to read the combined sweep's output.

    func testLocalFileVariousDurationsScenarioPassesEverySeededRun() {
        assertAllPass(LocalFileVariousDurationsScenario())
    }

    func testSlowICloudDownloadWithPausesScenarioPassesEverySeededRun() {
        assertAllPass(SlowICloudDownloadWithPausesScenario())
    }

    func testProviderDeletesTempFileEarlyScenarioPassesEverySeededRun() {
        assertAllPass(ProviderDeletesTempFileEarlyScenario())
    }

    func testDiskNearlyFullScenarioPassesEverySeededRun() {
        assertAllPass(DiskNearlyFullScenario())
    }

    func testDiskFillingFromAnotherAppDuringImportScenarioPassesEverySeededRun() {
        assertAllPass(DiskFillingFromAnotherAppDuringImportScenario())
    }

    func testCancelMidwayScenarioPassesEverySeededRun() {
        assertAllPass(CancelMidwayScenario())
    }

    func testSeveralClipsCombinedUpToAnHourScenarioPassesEverySeededRun() {
        assertAllPass(SeveralClipsCombinedUpToAnHourScenario())
    }

    private func assertAllPass(_ scenario: any LongMediaScenario, file: StaticString = #filePath, line: UInt = #line) {
        let records = LongMediaSweep.run(scenarios: [scenario], seeds: [20260928, 1, 2, 777, 99], runsEach: 30)
        let failing = records.filter { !$0.outcome.passed }
        XCTAssertTrue(
            failing.isEmpty,
            "\(scenario.id): \(failing.count)/\(records.count) failed. First: \(failing.first.map { "\($0.personaID) seed=\($0.baseSeed) run=\($0.runIndex): \($0.outcome.message)" } ?? "")",
            file: file, line: line
        )
    }
}
