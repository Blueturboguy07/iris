//
//  ToolInvocationLiveTests.swift
//  leanring-buddyTests
//
//  DOES THE AGENT ACTUALLY REACH FOR THE TOOL?
//
//  Tier C was, until now, the one part of Iris with no way to look anything up.
//  The guide fix ladder has web search and so does chat; the edit loop was told
//  in its own system prompt "there is no network", so a reader asking it to
//  integrate an API it did not already know had no path that could succeed. It
//  now has search on both arms — Codex through `-c tools.web_search=true`,
//  Anthropic through the server-side `web_search` tool.
//
//  Giving it the tool is the easy half. The half that decides whether any of it
//  matters is whether the model REACHES for the tool when it should, and leaves
//  it alone when it shouldn't — and no amount of prompt wording settles that.
//  Only observation does. So this suite runs the same question at both
//  providers and records what the tool actually did.
//
//  It makes REAL, BILLED model calls, so it is off unless asked for:
//
//      IRIS_TOOL_INVOCATION=1 xcodebuild test -project leanring-buddy.xcodeproj \
//        -scheme leanring-buddy -destination platform=macOS,arch=arm64 \
//        -derivedDataPath .build-check -parallel-testing-enabled NO \
//        -only-testing:leanring-buddyTests/ToolInvocationLiveTests
//
//  Optional: IRIS_TOOL_INVOCATION_REPEATS=3 (default 2), because one sample of
//  a stochastic system is an anecdote; IRIS_TOOL_INVOCATION_OUT=/path.json to
//  keep the raw record. `print` from a test host never reaches xcodebuild's
//  log, so the report is written to a file, exactly as the parity harness does.
//
//  WHAT IT DOES NOT CLAIM. That a search happened says nothing about whether
//  the RESULT was used well. This measures reaching for the tool, which is the
//  failure that was actually observed in the field, and nothing more.
//

import Foundation
import Testing
@testable import Iris

nonisolated enum ToolInvocationGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IRIS_TOOL_INVOCATION"] == "1"
    }

    static var repeatsPerScenario: Int {
        guard let raw = ProcessInfo.processInfo.environment["IRIS_TOOL_INVOCATION_REPEATS"],
              let parsed = Int(raw), parsed > 0 else {
            return 2
        }
        return parsed
    }

    static var resultsPath: String {
        ProcessInfo.processInfo.environment["IRIS_TOOL_INVOCATION_OUT"]
            ?? NSTemporaryDirectory() + "iris-tool-invocation-results.json"
    }
}

// MARK: - What we expect of a scenario

/// Whether reaching for search is right, wrong, or a judgement call.
///
/// The middle case is the point of the suite. A scenario that is obviously one
/// or the other tests the plumbing; a scenario where a careful engineer would
/// look it up but a careless one would guess is where the behaviour actually
/// lives, and where the field failure happened.
nonisolated enum SearchExpectation: String, Sendable {
    /// Not searching is a defect: the answer cannot be known without looking.
    case mustSearch
    /// Searching is waste: everything needed is in the prompt.
    case mustNotSearch
    /// Either is defensible. Recorded, never failed — a judgement call scored
    /// as a defect would make the suite lie about what it measured.
    case judgementCall
}

nonisolated struct ToolScenario: Sendable {
    let name: String
    let expectation: SearchExpectation
    let systemPrompt: String
    let userMessage: String
    /// Why this scenario is classified the way it is, printed in the report so
    /// a surprising result can be argued with rather than just believed.
    let rationale: String
}

nonisolated enum ToolInvocationBattery {

    /// The shared framing: an engineer about to change a real codebase. Kept
    /// deliberately close to Tier C's own posture without being a copy of it —
    /// this measures the model's disposition to look things up, not the exact
    /// bytes of the edit protocol, which `CodexParityLiveTests` already covers.
    private static let engineerPrompt = """
    You are an engineer about to make a change to a real codebase. Answer the \
    question directly and briefly. You have a web search tool available; use it \
    whenever the answer depends on something you do not already know for \
    certain, and do not use it when you already have everything you need.
    """

    static func all() -> [ToolScenario] {
        [
            ToolScenario(
                name: "unambiguous-needs-search",
                expectation: .mustSearch,
                systemPrompt: engineerPrompt,
                userMessage: """
                I need to call the OpenRouter chat completions API from this app. \
                What is the exact request URL, the auth header, and the JSON body \
                shape it expects today? Be specific.
                """,
                rationale: "A live third-party API contract. Any answer from memory may be stale, and a wrong header is a silent failure at runtime."
            ),
            ToolScenario(
                name: "unambiguous-needs-no-search",
                expectation: .mustNotSearch,
                systemPrompt: engineerPrompt,
                userMessage: """
                Here is a function:

                func total(_ xs: [Int]) -> Int {
                    var sum = 0
                    for x in xs where x > 0 { sum += x }
                    return sum
                }

                What does total([-2, 5, 5]) return?
                """,
                rationale: "Pure local reasoning. Everything needed is on screen; a search here is wasted latency and spend."
            ),
            ToolScenario(
                name: "the-field-failure",
                expectation: .mustSearch,
                systemPrompt: engineerPrompt,
                userMessage: """
                Add OpenRouter to this app so users get free credits. Before you \
                write anything, tell me whether OpenRouter actually offers free \
                credits, and how you know.
                """,
                rationale: "The exact shape of the reported failure: a request resting on a premise that may be false. Verifying the premise is the whole job, and it cannot be done from memory."
            ),
            ToolScenario(
                name: "subtle-stale-knowledge",
                expectation: .judgementCall,
                systemPrompt: engineerPrompt,
                userMessage: """
                What is the current recommended way to persist a small amount of \
                key-value state in a SwiftUI macOS app, and has that advice \
                changed recently?
                """,
                rationale: "Plausibly answerable from training, but the question explicitly asks whether the advice has CHANGED — which memory cannot establish. Either behaviour is arguable; what it does is worth knowing."
            ),
            ToolScenario(
                name: "subtle-looks-webby-but-is-local",
                expectation: .judgementCall,
                systemPrompt: engineerPrompt,
                userMessage: """
                Our package.json has "electron": "^30.0.0" in devDependencies and \
                a "dist:mac" script running electron-builder. Which packager does \
                this project actually ship with?
                """,
                rationale: "Names third-party tools, so it reads as a web question, but the evidence is entirely in the snippet. A model that searches here is pattern-matching on vocabulary rather than reading."
            ),
        ]
    }
}

// MARK: - One measured run

nonisolated struct ToolOutcome: Sendable {
    let scenario: String
    let expectation: String
    let provider: String
    let attempt: Int
    let searched: Bool
    let queries: [String]
    let verdict: String
    let seconds: Double
    let replyExcerpt: String
}

@Suite(.enabled(if: ToolInvocationGate.isEnabled,
                "set IRIS_TOOL_INVOCATION=1 to make real model calls"))
struct ToolInvocationLiveTests {

    @MainActor
    @Test func bothProvidersReachForSearchWhenTheyShould() async throws {
        let scenarios = ToolInvocationBattery.all()
        let repeats = ToolInvocationGate.repeatsPerScenario

        var providers: [(name: String, provider: any MaintainModelProviding)] = []
        let anthropic = AnthropicMaintainProvider()
        let codex = CodexMaintainProvider()
        var report: [String] = []
        report.append("=== arms ===")
        // Lets one arm be re-checked without paying for the other: fixing a
        // credential on the slow arm should not cost minutes of the fast one's
        // billed calls.
        let onlyThisArm = ProcessInfo.processInfo.environment["IRIS_TOOL_INVOCATION_ARM"]
        for candidate in [("anthropic", anthropic as any MaintainModelProviding),
                          ("codex", codex as any MaintainModelProviding)]
        where onlyThisArm == nil || onlyThisArm == candidate.0 {
            let available = candidate.1.isAvailable
            report.append("  \(candidate.0): \(available ? "available" : "NOT AVAILABLE")")
            if available { providers.append((candidate.0, candidate.1)) }
        }
        report.append("  codex binary: \(CodexCLILogin.locateCodexBinary() ?? "not found")")

        try #require(!providers.isEmpty, "no provider is available — connect a credential first")

        var outcomes: [ToolOutcome] = []

        for scenario in scenarios {
            for provider in providers {
                for attempt in 1...repeats {
                    let startedAt = Date()
                    var searched = false
                    var queries: [String] = []
                    var reply = ""

                    do {
                        // Cleared before the call so a failed turn cannot be
                        // scored against the previous turn's event stream —
                        // which would report a search that this run never made.
                        CodexExecOutput.eventStreamOfTheMostRecentTurn = ""
                        reply = try await provider.provider.respond(
                            systemPrompt: scenario.systemPrompt,
                            conversation: [MaintainChatTurn(role: "user", text: scenario.userMessage)],
                            maximumOutputTokens: 1200
                        )
                        (searched, queries) = Self.whatTheToolDid(
                            provider: provider.name,
                            anthropicProvider: anthropic
                        )
                    } catch {
                        outcomes.append(ToolOutcome(
                            scenario: scenario.name,
                            expectation: scenario.expectation.rawValue,
                            provider: provider.name,
                            attempt: attempt,
                            searched: false,
                            queries: [],
                            // A credential or quota refusal says nothing about
                            // whether the model reaches for its tools, and
                            // scoring it as a tool failure would make this
                            // suite lie about what it measured — the arm never
                            // ran. The parity battery learned this from the
                            // same cause: a lapsed Claude Code token still
                            // reads "Connected" in the panel, so it cannot be
                            // told from a good one until a call is made.
                            verdict: Self.isAnInfrastructureRefusal(error)
                                ? "INCONCLUSIVE (arm unavailable)" : "ERROR",
                            seconds: Date().timeIntervalSince(startedAt),
                            replyExcerpt: "\(error)"
                        ))
                        continue
                    }

                    let verdict: String
                    switch scenario.expectation {
                    case .mustSearch:
                        verdict = searched ? "PASS" : "FAIL (did not look it up)"
                    case .mustNotSearch:
                        verdict = searched ? "FAIL (searched needlessly)" : "PASS"
                    case .judgementCall:
                        verdict = searched ? "observed: searched" : "observed: answered from memory"
                    }

                    outcomes.append(ToolOutcome(
                        scenario: scenario.name,
                        expectation: scenario.expectation.rawValue,
                        provider: provider.name,
                        attempt: attempt,
                        searched: searched,
                        queries: queries,
                        verdict: verdict,
                        seconds: Date().timeIntervalSince(startedAt),
                        replyExcerpt: String(reply.prefix(240))
                    ))
                }
            }
        }

        // MARK: The report

        report.append("\n=== per run ===")
        for outcome in outcomes {
            report.append("  " + Self.column(outcome.scenario, 32)
                          + Self.column(outcome.provider, 11)
                          + Self.column("#\(outcome.attempt)", 4)
                          + Self.column(outcome.searched ? "searched" : "no search", 11)
                          + Self.column(String(format: "%.1fs", outcome.seconds), 8)
                          + outcome.verdict)
            if !outcome.queries.isEmpty {
                report.append("      queries: " + outcome.queries.prefix(3).joined(separator: " | "))
            }
            // An ERROR with no reason is the same unactionable dead end this
            // whole pass exists to remove; the reason is already captured, it
            // just was not printed.
            if outcome.verdict == "ERROR" {
                report.append("      reason: " + outcome.replyExcerpt)
            }
        }

        let inconclusive = outcomes.filter { $0.verdict.hasPrefix("INCONCLUSIVE") }
        if !inconclusive.isEmpty {
            report.append("\n=== arms that never ran (not scored) ===")
            for provider in Set(inconclusive.map(\.provider)).sorted() {
                let reason = inconclusive.first { $0.provider == provider }?.replyExcerpt ?? ""
                report.append("  \(provider): every call refused — \(reason)")
                report.append("    UNVERIFIED by this run, which is not the same as failing.")
            }
        }

        report.append("\n=== scored scenarios (judgement calls excluded) ===")
        var failures: [String] = []
        for provider in providers.map(\.name) {
            let scored = outcomes.filter {
                $0.provider == provider
                    && $0.expectation != SearchExpectation.judgementCall.rawValue
                    && !$0.verdict.hasPrefix("INCONCLUSIVE")
            }
            guard !scored.isEmpty else {
                report.append("  \(provider): no scored runs (see above)")
                continue
            }
            let passed = scored.filter { $0.verdict == "PASS" }.count
            report.append("  \(provider): \(passed)/\(scored.count)")
            for bad in scored where bad.verdict != "PASS" {
                failures.append("\(provider)/\(bad.scenario)#\(bad.attempt): \(bad.verdict)")
            }
        }

        report.append("\n=== judgement calls (recorded, not scored) ===")
        for outcome in outcomes
        where outcome.expectation == SearchExpectation.judgementCall.rawValue {
            report.append("  " + Self.column(outcome.scenario, 32)
                          + Self.column(outcome.provider, 11)
                          + outcome.verdict)
        }

        if !failures.isEmpty {
            report.append("\n=== failures ===")
            for failure in failures { report.append("  \(failure)") }
        }

        let text = report.joined(separator: "\n")
        let path = ToolInvocationGate.resultsPath
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        print(text)

        // The suite reports rather than gatekeeps on the judgement calls, but a
        // clear-cut miss IS a defect and has to fail — otherwise the harness
        // becomes a thing that is run and nodded at.
        let failureSummary = "tool-invocation failures (report at \(path)): "
            + failures.joined(separator: "; ")
        #expect(failures.isEmpty, "\(failureSummary)")
    }

    /// Whether a thrown error means "this arm could not be reached" rather than
    /// "the model behaved badly". Credential and quota refusals are the whole
    /// set: they arrive in well under a second and never involve a model.
    private static func isAnInfrastructureRefusal(_ error: Error) -> Bool {
        guard let transportError = error as? AssistantTransportError else { return false }
        switch transportError {
        case .noCredentialsAvailable, .signInRequired, .bringYourOwnKeyRejected,
             .rateLimited, .dailyBudgetExhausted, .assistantUnavailable:
            return true
        default:
            return false
        }
    }

    /// What the tool did on the turn that just finished, per provider.
    ///
    /// The two arms report through different channels because they ARE
    /// different: Codex emits `item.completed` events with `item.type ==
    /// "web_search"`, and Anthropic returns `server_tool_use` content blocks.
    /// Both are read from the real transport rather than inferred from the
    /// reply text, because a model claiming it searched is not evidence that it
    /// did — and that specific confusion is what this suite exists to avoid.
    @MainActor
    private static func whatTheToolDid(
        provider: String,
        anthropicProvider: AnthropicMaintainProvider
    ) -> (Bool, [String]) {
        switch provider {
        case "codex":
            let stream = CodexExecOutput.eventStreamOfTheMostRecentTurn
            return (CodexExecOutput.didSearchTheWeb(inEventStream: stream),
                    CodexExecOutput.webSearchQueries(inEventStream: stream))
        case "anthropic":
            let queries = anthropicProvider.webSearchQueriesOfTheMostRecentTurn
            return (!queries.isEmpty, queries)
        default:
            return (false, [])
        }
    }

    private static func column(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
