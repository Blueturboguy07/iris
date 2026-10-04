import XCTest
@testable import MobileUserSimKit

/// A small sweep as part of `swift test` (kept short so the test target
/// stays fast); the full `--runs 40` / 3-seed sweep the plan asks for is run
/// through the CLI (`iris-mobile-user-sim --runs 40 --seeds <a>,<b>,<c>`) and
/// reported separately in HANDOFF.md, since a multi-minute sweep does not
/// belong inside the default `swift test` gate.
final class SweepSmokeTests: XCTestCase {
    func testSmallSweepAcrossAllScenariosHasZeroFailures() async throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-mobile-user-sim-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let scenarios = try ScenarioCatalog.makeAll(scratchRoot: scratchRoot)
        let runner = Runner(scratchRoot: scratchRoot)
        let configuration = SweepConfiguration(runsPerScenarioPersona: 3, seeds: [11, 22])

        let records = await runner.run(scenarios: scenarios, configuration: configuration)
        let failing = records.filter { !$0.outcome.passed }
        XCTAssertTrue(
            failing.isEmpty,
            "failing runs: " + failing.map {
                "\($0.identity.scenarioID)/\($0.identity.personaID) seed=\($0.identity.baseSeed) run=\($0.identity.runIndex): \($0.outcome.message)"
            }.joined(separator: "; ")
        )
        // Each scenario ran for each of its declared personas, for both seeds, 3 times.
        let expectedCount = scenarios.reduce(0) { $0 + $1.personas.count * configuration.seeds.count * configuration.runsPerScenarioPersona }
        XCTAssertEqual(records.count, expectedCount)
    }
}
