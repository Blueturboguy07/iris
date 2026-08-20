//
//  FeatureEditRequestProbe.swift
//  leanring-buddy
//
//  The two MODEL-DERIVED clarification triggers from plan §7, previously
//  passed as a hardcoded `false` from the describe step:
//
//    1. ambiguity — "the request could be built in ≥2 materially different
//       ways and nothing in the repo disambiguates", adjudicated by
//       SELF-CONSISTENCY: two quick, independent reasoning passes each state
//       the implementation they would choose; a third tiny call judges whether
//       the two statements are materially the same. Disagreement = ambiguous.
//    2. irreversibility — each pass also classifies whether the request
//       implies a hard-to-undo action (a data/save-file format change, a
//       public interface break, a destructive migration). Either pass flagging
//       it is enough: a false positive costs one question, a false negative
//       costs an unconsented destructive change.
//
//  Everything here FAILS OPEN to "no trigger": a missing provider, a thrown
//  model call, or an unparseable reply produces the same all-quiet verdict the
//  hardcoded `false` did — the probe can only ever ADD a question, never a
//  refusal, and never blocks the flow that existed before it. The prompts and
//  parsers are pure and unit-tested; only `probe(...)` touches a provider.
//

import Foundation

/// The adjudicated facts the describe step feeds into
/// `FeatureEditClarificationLogic.questions(...)` for the two model-derived
/// triggers. A verdict, not raw model text: parsing and the self-consistency
/// comparison have already happened by the time one of these exists.
nonisolated struct FeatureEditRequestProbeVerdict: Equatable, Sendable {
    /// True only when both reasoning passes parsed AND the agreement judge
    /// said their implementations are materially different (plan §7 trigger 1).
    let requestLooksAmbiguous: Bool
    /// True when either reasoning pass flagged a hard-to-undo action implied
    /// by the request (plan §7 trigger 2).
    let impliesIrreversibleAction: Bool

    /// The fail-open verdict: no trigger fires, exactly the behavior the
    /// hardcoded `false` signals produced before the probe existed.
    static let allQuiet = FeatureEditRequestProbeVerdict(
        requestLooksAmbiguous: false,
        impliesIrreversibleAction: false
    )
}

/// One reasoning pass's parsed answer. `implementationSummary` feeds the
/// self-consistency comparison; `impliesIrreversibleAction` feeds trigger 2.
nonisolated struct FeatureEditRequestProbePassAnswer: Equatable, Sendable {
    let implementationSummary: String
    let impliesIrreversibleAction: Bool
}

nonisolated enum FeatureEditRequestProbe {

    /// Output cap for each of the three calls. They each need one JSON line or
    /// one word, so this is generous — the point is that a probe call is a
    /// fraction of the cost of a single edit-loop step.
    static let maximumOutputTokensPerProbeCall = 220

    // MARK: - Prompts (pure)

    /// The prompt for one of the two reasoning passes. The second pass is
    /// explicitly told to look for a DIFFERENT reasonable reading first —
    /// self-consistency needs genuinely independent attempts, and two calls
    /// with an identical prompt at a provider's fixed temperature can collapse
    /// into one attempt made twice.
    static func reasoningPassPrompt(
        request: String,
        repoMapSummary: String,
        passIndex: Int
    ) -> String {
        let independenceInstruction = passIndex == 0
            ? "Decide the single most reasonable implementation."
            : "Before deciding, first consider whether a materially different reading of the request exists; then decide the implementation YOU find most reasonable."
        let repoContext = repoMapSummary.isEmpty
            ? "No code map is available."
            : "A map of the app's code, so the code itself can settle what the request means where it can:\n\(repoMapSummary)"
        return """
        A user asked for this change to an app: "\(request)"

        \(repoContext)

        \(independenceInstruction)

        Also classify: does doing this imply an action that is hard or impossible to undo — changing a saved-data/file format existing data must survive, breaking a public API/CLI interface, or a destructive data migration? Adding new code, new UI, or new optional behavior is NOT irreversible.

        Reply with ONLY one line of JSON, no code fences:
        {"implementation": "<one sentence: what you would build and where>", "irreversible": true|false}
        """
    }

    /// The agreement judge's prompt: one word out, so parsing cannot be
    /// confused by prose.
    static func agreementPrompt(
        firstImplementationSummary: String,
        secondImplementationSummary: String
    ) -> String {
        """
        Two engineers described how they would implement the same user request.

        A: \(firstImplementationSummary)
        B: \(secondImplementationSummary)

        Do A and B describe materially the same implementation (same user-visible behavior, same general place in the code)? Wording differences do not matter; a different feature, behavior, or location does.

        Reply with exactly one word: SAME or DIFFERENT.
        """
    }

    // MARK: - Parsing (pure, tolerant, fail-open)

    /// Extracts the one-line JSON answer from a reasoning pass's reply. The
    /// reply is model text, so this tolerates code fences and surrounding
    /// prose by scanning for the first balanced `{...}` object. Nil — never a
    /// guess — when no parseable answer is found.
    static func parsedReasoningPassAnswer(_ reply: String) -> FeatureEditRequestProbePassAnswer? {
        guard let jsonObjectText = firstBalancedJSONObject(in: reply),
              let jsonData = jsonObjectText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let implementationSummary = parsed["implementation"] as? String,
              !implementationSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let impliesIrreversibleAction = parsed["irreversible"] as? Bool else {
            return nil
        }
        return FeatureEditRequestProbePassAnswer(
            implementationSummary: implementationSummary,
            impliesIrreversibleAction: impliesIrreversibleAction
        )
    }

    /// The agreement judge's verdict: true = materially the same, false =
    /// materially different, nil = the reply named both words or neither, which
    /// is unusable and fails open upstream.
    static func parsedAgreementSaysSame(_ reply: String) -> Bool? {
        let uppercased = reply.uppercased()
        let saysSame = uppercased.contains("SAME")
        let saysDifferent = uppercased.contains("DIFFERENT")
        switch (saysSame, saysDifferent) {
        case (true, false): return true
        case (false, true): return false
        default: return nil
        }
    }

    /// The first balanced top-level `{...}` in a chunk of model text, or nil.
    /// Brace-counting rather than a regex so a nested object inside the answer
    /// does not truncate it; quotes are tracked so a brace inside a string
    /// value cannot unbalance the scan.
    static func firstBalancedJSONObject(in text: String) -> String? {
        var braceDepth = 0
        var isInsideStringLiteral = false
        var previousCharacterWasEscape = false
        var objectStartIndex: String.Index?

        for currentIndex in text.indices {
            let character = text[currentIndex]
            if isInsideStringLiteral {
                if previousCharacterWasEscape {
                    previousCharacterWasEscape = false
                } else if character == "\\" {
                    previousCharacterWasEscape = true
                } else if character == "\"" {
                    isInsideStringLiteral = false
                }
                continue
            }
            switch character {
            case "\"":
                isInsideStringLiteral = true
            case "{":
                if braceDepth == 0 { objectStartIndex = currentIndex }
                braceDepth += 1
            case "}":
                braceDepth -= 1
                if braceDepth == 0, let start = objectStartIndex {
                    return String(text[start...currentIndex])
                }
                if braceDepth < 0 { braceDepth = 0 }
            default:
                break
            }
        }
        return nil
    }

    // MARK: - The probe itself (the only part that touches a provider)

    /// Runs the two reasoning passes and, when both parsed and are not
    /// near-identical, the agreement judge — at most three small model calls on
    /// the reader's own key. Every failure path returns `.allQuiet`.
    @MainActor
    static func probe(
        scrubbedRequest: String,
        repoMapSummary: String,
        provider: MaintainModelProviding
    ) async -> FeatureEditRequestProbeVerdict {
        var parsedPassAnswers: [FeatureEditRequestProbePassAnswer] = []
        for passIndex in 0...1 {
            let passPrompt = reasoningPassPrompt(
                request: scrubbedRequest,
                repoMapSummary: repoMapSummary,
                passIndex: passIndex
            )
            guard let reply = try? await provider.respond(
                systemPrompt: "You are a careful software engineer sizing up a change request. Answer exactly in the format asked.",
                conversation: [MaintainChatTurn(role: "user", text: passPrompt)],
                maximumOutputTokens: maximumOutputTokensPerProbeCall
            ), let parsedAnswer = parsedReasoningPassAnswer(reply) else {
                continue
            }
            parsedPassAnswers.append(parsedAnswer)
        }

        // Trigger 2: either pass flagging irreversibility is enough (a false
        // positive costs one question; a false negative costs an unconsented
        // destructive change), and one parsed pass may still flag it.
        let impliesIrreversibleAction = parsedPassAnswers.contains { $0.impliesIrreversibleAction }

        // Trigger 1 needs BOTH passes: self-consistency over one attempt is
        // not a signal. Fail open when either pass was unusable.
        guard parsedPassAnswers.count == 2 else {
            return FeatureEditRequestProbeVerdict(
                requestLooksAmbiguous: false,
                impliesIrreversibleAction: impliesIrreversibleAction
            )
        }

        // Near-identical summaries need no judge — skip the third call. This is
        // a shortcut for the agreeing case only; anything else goes to the
        // judge rather than to a similarity heuristic.
        let normalizedFirst = normalizedForComparison(parsedPassAnswers[0].implementationSummary)
        let normalizedSecond = normalizedForComparison(parsedPassAnswers[1].implementationSummary)
        if normalizedFirst == normalizedSecond {
            return FeatureEditRequestProbeVerdict(
                requestLooksAmbiguous: false,
                impliesIrreversibleAction: impliesIrreversibleAction
            )
        }

        let judgePrompt = agreementPrompt(
            firstImplementationSummary: parsedPassAnswers[0].implementationSummary,
            secondImplementationSummary: parsedPassAnswers[1].implementationSummary
        )
        guard let judgeReply = try? await provider.respond(
            systemPrompt: "You compare two implementation descriptions. Answer with exactly one word.",
            conversation: [MaintainChatTurn(role: "user", text: judgePrompt)],
            maximumOutputTokens: 12
        ), let saysSame = parsedAgreementSaysSame(judgeReply) else {
            // The judge was unreachable or unusable: fail open, no question.
            return FeatureEditRequestProbeVerdict(
                requestLooksAmbiguous: false,
                impliesIrreversibleAction: impliesIrreversibleAction
            )
        }

        return FeatureEditRequestProbeVerdict(
            requestLooksAmbiguous: !saysSame,
            impliesIrreversibleAction: impliesIrreversibleAction
        )
    }

    /// Case/whitespace/punctuation-insensitive equality for the "the two
    /// passes said literally the same thing" shortcut.
    private static func normalizedForComparison(_ summary: String) -> String {
        summary.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
