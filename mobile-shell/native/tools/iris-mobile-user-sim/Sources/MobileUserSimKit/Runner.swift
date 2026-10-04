import Foundation

public struct SweepConfiguration: Sendable {
    public let runsPerScenarioPersona: Int
    public let seeds: [UInt64]

    public init(runsPerScenarioPersona: Int = 40, seeds: [UInt64] = [20260926, 1, 2]) {
        self.runsPerScenarioPersona = runsPerScenarioPersona
        self.seeds = seeds
    }
}

public struct ScenarioRunRecord: Sendable {
    public let identity: ScenarioRunIdentity
    public let scenarioTitle: String
    public let personaDisplayName: String
    public let outcome: ScenarioOutcome
    public let durationSeconds: Double
}

/// Runs every scenario across its declared personas, the sweep's seeds and
/// `runsPerScenarioPersona` seeded repetitions each. A failing run is
/// reproducible from `identity.derivedSeed` alone (see
/// `--exact-seed`/`--run-index` in the CLI).
public final class Runner {
    private let scratchRoot: URL

    public init(scratchRoot: URL) {
        self.scratchRoot = scratchRoot
    }

    public func run(
        scenarios: [any MobileScenario],
        configuration: SweepConfiguration,
        onRecord: (@Sendable (ScenarioRunRecord) -> Void)? = nil
    ) async -> [ScenarioRunRecord] {
        var records: [ScenarioRunRecord] = []
        for scenario in scenarios {
            for persona in scenario.personas {
                for seed in configuration.seeds {
                    for runIndex in 0..<configuration.runsPerScenarioPersona {
                        let record = await runOne(
                            scenario: scenario,
                            persona: persona,
                            baseSeed: seed,
                            runIndex: runIndex
                        )
                        records.append(record)
                        onRecord?(record)
                    }
                }
            }
        }
        return records
    }

    /// Runs exactly one identified (scenario, persona, seed, run index)
    /// combination. Used both by the sweep above and by `--exact-seed
    /// --run-index` reproduction of a single failing run.
    public func runOne(
        scenario: any MobileScenario,
        persona: MobilePersona,
        baseSeed: UInt64,
        runIndex: Int
    ) async -> ScenarioRunRecord {
        let derivedSeed = SeededGenerator.derivedSeed(baseSeed: baseSeed, runIndex: runIndex)
        var rng = SeededGenerator(seed: derivedSeed)
        let identity = ScenarioRunIdentity(
            scenarioID: scenario.id,
            personaID: persona.id,
            baseSeed: baseSeed,
            runIndex: runIndex,
            derivedSeed: derivedSeed
        )

        let start = Date()
        let env: RunEnvironment
        do {
            env = try RunEnvironment(persona: persona, seed: derivedSeed, scratchRoot: scratchRoot)
        } catch {
            let outcome = ScenarioOutcome(
                passed: false,
                failureClass: .setupPackaging,
                message: "could not construct the run environment: \(error)",
                personaInterview: PersonaInterview(
                    didFinish: false,
                    lastHonestMessage: "The simulated device could not even start.",
                    knewWhatToDoNext: false
                )
            )
            return ScenarioRunRecord(
                identity: identity,
                scenarioTitle: scenario.title,
                personaDisplayName: persona.displayName,
                outcome: outcome,
                durationSeconds: Date().timeIntervalSince(start)
            )
        }
        defer { env.cleanUp() }

        let outcome: ScenarioOutcome
        do {
            outcome = try await scenario.run(env: env, persona: persona, rng: &rng)
        } catch let failure as OracleFailure {
            outcome = ScenarioOutcome(
                passed: false,
                failureClass: failure.failureClass,
                message: failure.description,
                personaInterview: PersonaInterview(
                    didFinish: false,
                    lastHonestMessage: failure.description,
                    knewWhatToDoNext: false
                )
            )
        } catch {
            outcome = ScenarioOutcome(
                passed: false,
                failureClass: .setupPackaging,
                message: "unexpected error: \(error)",
                personaInterview: PersonaInterview(
                    didFinish: false,
                    lastHonestMessage: "Something went wrong Iris did not explain.",
                    knewWhatToDoNext: false
                )
            )
        }
        return ScenarioRunRecord(
            identity: identity,
            scenarioTitle: scenario.title,
            personaDisplayName: persona.displayName,
            outcome: outcome,
            durationSeconds: Date().timeIntervalSince(start)
        )
    }
}
