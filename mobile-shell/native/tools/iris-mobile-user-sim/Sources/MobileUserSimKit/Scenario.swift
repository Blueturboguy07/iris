import Foundation

/// One run's result. `personaInterview` answers the same three questions the
/// desktop harness's Interview step asks (README.md step 5): did the person
/// finish, what did the shell last honestly tell them, did they know what to
/// do next. It is derived from ground truth the scenario collected, not
/// invented after the fact.
public struct ScenarioOutcome: Sendable {
    public let passed: Bool
    public let failureClass: FailureClass?
    public let message: String
    public let personaInterview: PersonaInterview
    public let evidence: [String: String]

    public init(
        passed: Bool,
        failureClass: FailureClass? = nil,
        message: String,
        personaInterview: PersonaInterview,
        evidence: [String: String] = [:]
    ) {
        self.passed = passed
        self.failureClass = failureClass
        self.message = message
        self.personaInterview = personaInterview
        self.evidence = evidence
    }
}

public struct PersonaInterview: Sendable {
    public let didFinish: Bool
    public let lastHonestMessage: String
    public let knewWhatToDoNext: Bool

    public init(didFinish: Bool, lastHonestMessage: String, knewWhatToDoNext: Bool) {
        self.didFinish = didFinish
        self.lastHonestMessage = lastHonestMessage
        self.knewWhatToDoNext = knewWhatToDoNext
    }
}

/// A single seeded scenario run: which scenario, persona, run index and
/// derived seed produced it, so any failure is reproducible by name alone.
public struct ScenarioRunIdentity: Sendable {
    public let scenarioID: String
    public let personaID: String
    public let baseSeed: UInt64
    public let runIndex: Int
    public let derivedSeed: UInt64
}

/// A scenario against the real Core code. Each concrete type generates its
/// own real package fixtures once (in `init`), then `run` is called many
/// times with varying personas, seeds and device-world conditions.
public protocol MobileScenario: AnyObject, Sendable {
    var id: String { get }
    var title: String { get }
    var seedString: String { get }
    var personas: [MobilePersona] { get }

    func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome
}

extension MobileScenario {
    /// A per-generated-package nonce, unique per scenario and per call index
    /// so a scenario invoked many times across a sweep never re-uses a
    /// delivery nonce (which the real validator would reject as a replay).
    /// Built deterministically (no `Hasher`, which is randomly seeded per
    /// process) so the exact bytes are reproducible across runs.
    public func nonce(_ index: Int) -> String {
        let idHex = seedString.unicodeScalars.map { String(format: "%02x", $0.value & 0xff) }.joined()
        let indexHex = String(format: "%08x", index)
        let raw = idHex + indexHex
        guard !raw.isEmpty else { return String(repeating: "0", count: 64) }
        let repeatCount = (64 / raw.count) + 1
        return String(String(repeating: raw, count: repeatCount).prefix(64))
    }
}
