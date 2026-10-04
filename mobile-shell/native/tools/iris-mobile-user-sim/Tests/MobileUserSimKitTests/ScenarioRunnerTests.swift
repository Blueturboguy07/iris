import XCTest
@testable import MobileUserSimKit

/// Runs every scenario at least once against the real Core code. A failure
/// here means a real regression in the production behavior a scenario
/// checks, not a broken test double: none of `NativeShellLibraryCoordinator`,
/// `NativeRevisionStore`, `PublikMobileCatalogClient`,
/// `NativeWebsiteInstallFlow` or `NativeMobileMarketplacePolicy` is mocked.
final class ScenarioRunnerTests: XCTestCase {
    private var scratchRoot: URL!

    override func setUpWithError() throws {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-mobile-user-sim-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchRoot { try? FileManager.default.removeItem(at: scratchRoot) }
    }

    func testEveryScenarioPassesOnceForEveryDeclaredPersona() async throws {
        let scenarios = try ScenarioCatalog.makeAll(scratchRoot: scratchRoot)
        XCTAssertEqual(scenarios.count, 21, "update this count if a scenario is added or removed")
        let runner = Runner(scratchRoot: scratchRoot)

        for scenario in scenarios {
            XCTAssertFalse(scenario.personas.isEmpty, "\(scenario.id) declares no personas")
            for persona in scenario.personas {
                let record = await runner.runOne(scenario: scenario, persona: persona, baseSeed: 20260926, runIndex: 0)
                XCTAssertTrue(
                    record.outcome.passed,
                    "\(scenario.id) failed for \(persona.id): \(record.outcome.message)"
                )
            }
        }
    }

    func testSameSeedAndRunIndexReproduceTheSameOutcome() async throws {
        let scenarios = try ScenarioCatalog.makeAll(scratchRoot: scratchRoot)
        let runner = Runner(scratchRoot: scratchRoot)
        guard let scenario = scenarios.first(where: { $0.id == "double-tap-install" }),
              let persona = scenario.personas.first else {
            XCTFail("double-tap-install scenario not found")
            return
        }

        let first = await runner.runOne(scenario: scenario, persona: persona, baseSeed: 555, runIndex: 7)
        let second = await runner.runOne(scenario: scenario, persona: persona, baseSeed: 555, runIndex: 7)

        XCTAssertEqual(first.identity.derivedSeed, second.identity.derivedSeed)
        XCTAssertEqual(first.outcome.passed, second.outcome.passed)
        XCTAssertEqual(first.outcome.message, second.outcome.message)
    }

    /// Independent of any single scenario's internal assertions: after the
    /// double-tap scenario runs, the coordinator's own durable state (not
    /// its return value) must show one library entry per identity. This
    /// oracle is evaluated fresh here, not borrowed from the scenario.
    func testDoubleTapScenarioLeavesExactlyOneOnDiskRevisionAsGroundTruth() async throws {
        let scenario = try DoubleTapInstallScenario(scratchRoot: scratchRoot)
        guard let persona = scenario.personas.first else {
            XCTFail("no persona")
            return
        }
        var rng = SeededGenerator(seed: 4242)
        let env = try RunEnvironment(persona: persona, seed: 4242, scratchRoot: scratchRoot)
        defer { env.cleanUp() }

        let outcome = try await scenario.run(env: env, persona: persona, rng: &rng)
        XCTAssertTrue(outcome.passed, outcome.message)

        // Independent re-check against the filesystem, not the scenario's
        // own oracle: exactly one app directory, exactly one revision
        // directory inside it.
        let contentRoot = env.libraryRootURL.appendingPathComponent("content", isDirectory: true)
        let appDirectories = try FileManager.default.contentsOfDirectory(at: contentRoot, includingPropertiesForKeys: nil)
        XCTAssertEqual(appDirectories.count, 1)
        let projectDirectories = try FileManager.default.contentsOfDirectory(at: appDirectories[0], includingPropertiesForKeys: nil)
        XCTAssertEqual(projectDirectories.count, 1)
        let revisionsRoot = projectDirectories[0].appendingPathComponent("revisions", isDirectory: true)
        let revisionDirectories = try FileManager.default.contentsOfDirectory(at: revisionsRoot, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".staging-") }
        XCTAssertEqual(revisionDirectories.count, 1, "double-tapped install must leave exactly one revision directory on disk")
    }
}
