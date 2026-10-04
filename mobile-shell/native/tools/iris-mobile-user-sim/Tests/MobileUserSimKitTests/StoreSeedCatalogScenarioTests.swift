import XCTest
@testable import MobileUserSimKit

/// M-store-screens seed catalog lane: the owner's "no mobile apps to browse"
/// world (publikhq.com 404, airplane mode, flaky, cache wiped) swept over all
/// three personas and 40 seeded runs each, with a failure taxonomy check.
/// Every seeded run draws one of the three network conditions, so all three
/// are covered many times.
final class StoreSeedCatalogScenarioTests: XCTestCase {
    func testEveryPersonaSeesTheAppsThatCameWithIrisWhatevertheNetworkDoes() async throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-mobile-user-sim-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

        let scenario = try StoreSeedCatalogScenario(scratchRoot: scratchRoot)
        let runner = Runner(scratchRoot: scratchRoot)
        let configuration = SweepConfiguration(runsPerScenarioPersona: 40, seeds: [20260928])
        let records = await runner.run(scenarios: [scenario], configuration: configuration)

        XCTAssertEqual(records.count, 3 * 40)
        let failing = records.filter { !$0.outcome.passed }
        let taxonomy = Dictionary(grouping: failing, by: { $0.outcome.failureClass?.rawValue ?? "none" }).mapValues(\.count)
        XCTAssertTrue(failing.isEmpty, "failures by class \(taxonomy): " + failing.prefix(5).map {
            "\($0.identity.personaID) run=\($0.identity.runIndex): \($0.outcome.message)"
        }.joined(separator: "; "))
        let conditions = Set(records.compactMap { $0.outcome.evidence["condition"] })
        XCTAssertEqual(conditions.count, 3, "the sweep covered 404, airplane mode and a flaky connection: \(conditions)")
    }
}
