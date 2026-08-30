//
//  GuideAutopilotCodexFixProposer.swift
//  leanring-buddy
//
//  THE FIX LADDER, FOR A READER WHOSE ONLY CREDENTIAL IS THE CODEX CLI.
//
//  Reported by a tester who watched an install stop with "I've used up what I
//  can spend on this install for now", and answered: "I have the codex CLI? The
//  usage shouldn't be a problem."
//
//  He was right, and the cap was made provider-aware — but that only got him
//  half a fix, because the thing the cap was gating could not run on his
//  credential at all. `GuideAutopilotFixProposer` gets its fix by FORCING a tool
//  call (`toolChoice: ["type": "tool", "name": "propose_fix"]`) over the
//  Anthropic Messages API, so the model must answer with a `tool_use` block
//  matching a strict schema. `codex exec` is a CLI: it returns text and an
//  `--output-last-message` file, and has no tool-use wire format to force. So a
//  codex-only reader had no ladder, and nothing for the funded tier to fall back
//  to when publik's budget ran out.
//
//  The way out is the one this codebase already uses everywhere else it needs
//  structure out of Codex: Tier C gets executable actions from the same text-only
//  CLI by asking for FENCED BLOCKS and parsing them (```bash, ```write, ```edit).
//  Same trick. Ask for one fenced JSON object with the same fields the tool
//  schema demands, parse it, and hand it to the SAME validator the Anthropic
//  route uses.
//
//  That last point is the load-bearing one. `validatedFix(fromProposalObject:)`
//  is not a decoder — it carries the guardrail that refuses a fix reaching any
//  host the guide's own commands do not already name, which is the structural
//  answer to a model inventing a plausible hostname. Writing a second parser
//  here is exactly how one route quietly loses a guardrail the other keeps, so
//  this file does not parse a fix at all: it finds a JSON object and delegates.
//
//  HONEST DIFFERENCES from the Anthropic route, neither of them papered over:
//
//    - BOTH RUNGS SEARCH. `CodexExecInvocation` sets `-c tools.web_search=true`
//      unconditionally, so there is no material-only rung here the way there is
//      on the Anthropic side. `cameFromWebSearch` therefore reports what the run
//      could have done, not proof it did.
//    - IT IS SLOWER. Measured at roughly 9x the Anthropic route per step. On a
//      ladder that is at most two rungs per step this is a pause, not a stall,
//      and it beats the alternative of the install simply stopping.
//

import Foundation

@MainActor
final class GuideAutopilotCodexFixProposer: GuideAutopilotFixProposing {

    /// The provider is injected so this is testable without the CLI installed.
    private let provider: MaintainModelProviding

    /// The default is built here rather than as a default ARGUMENT because
    /// `CodexMaintainProvider.init` is main-actor isolated and a default
    /// argument expression is evaluated in a nonisolated context.
    init(provider: MaintainModelProviding? = nil) {
        self.provider = provider ?? CodexMaintainProvider()
    }

    /// Whether this can be used at all right now — a connected Codex login.
    /// Checked at the moment of use rather than remembered, because the reader
    /// can run `codex logout` between two steps.
    var isAvailable: Bool { provider.isAvailable }

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        try await propose(for: context, cameFromWebSearch: false)
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        try await propose(for: context, cameFromWebSearch: true)
    }

    private func propose(
        for context: GuideAutopilotFailureContext,
        cameFromWebSearch: Bool
    ) async throws -> GuideAutopilotProposedFix? {
        let reply = try await provider.respond(
            // The Anthropic system prompt verbatim, plus the reply contract.
            // Verbatim matters: the prompt carries the "keep the install
            // MOVING" and "never invent a hostname" instructions, and a
            // paraphrase here would be a second, drifting set of rules.
            systemPrompt: GuideAutopilotFixProposer.systemPrompt(for: context)
                + "\n\n" + Self.replyContract,
            conversation: [
                MaintainChatTurn(
                    role: "user",
                    text: GuideAutopilotFixProposer.failureReport(for: context)
                )
            ],
            // Not honored by `codex exec`, which exposes no output cap. Passed
            // anyway so the two proposers read the same and a future provider
            // that DOES honor it needs no change here.
            maximumOutputTokens: GuideAutopilotFixProposer.maximumOutputTokensPerFixCall
        )

        guard let proposalObject = Self.proposalObject(inReply: reply) else { return nil }
        return GuideAutopilotFixProposer.validatedFix(
            fromProposalObject: proposalObject,
            cameFromWebSearch: cameFromWebSearch,
            context: context
        )
    }

    // MARK: - Asking for something parseable

    /// What the tool schema says, restated as a reply format. Kept beside the
    /// schema it mirrors — if `proposeFixTool` gains a field, this must gain it
    /// too, and `GuideAutopilotCodexFixProposerTests` fails when they drift.
    static let replyContract = """
    THIS TURN OVERRIDES THE BLOCK FORMAT DESCRIBED ABOVE. `CodexMaintainProvider` \
    prepends a preamble written for Iris's app-editing loop, which tells you to \
    reach the repository by emitting command and edit blocks. That does not apply \
    here: you are proposing ONE fix for Iris to run, not performing the work. \
    Emit no command block, no edit block, and no write block.

    Reply with EXACTLY ONE fenced json block and nothing else — no prose before \
    it, no explanation after it. There is no propose_fix tool on this route; the \
    json block IS the proposal.

    ```json
    {
      "diagnosis": "one sentence on why the command failed",
      "confidence": "high" | "medium" | "low",
      "retryTheOriginalCommandAfterwards": true | false,
      "action": { ... one of the three below ... }
    }
    ```

    The action is exactly one of:

      {"kind": "runACommand", "command": "…", "whatItDoes": "plain English, one line"}
      {"kind": "askTheReaderToDoSomething", "instruction": "…"}
      {"kind": "cannotFixThis", "reason": "…"}

    Do not run anything yourself, do not edit any file, and do not use your own \
    shell to investigate. You are being asked for ONE proposal as json; Iris runs \
    it, under its own safety gate.
    """

    /// Pulls the proposal object out of a reply.
    ///
    /// Tolerant on purpose about WRAPPING and strict about CONTENT. A real model
    /// puts the object in a ```json fence, sometimes in a bare ``` fence, and
    /// sometimes — despite the instruction — with a sentence in front of it.
    /// Rejecting those would throw away a good fix over punctuation. What is NOT
    /// tolerated is a malformed or missing object: this returns nil rather than
    /// a salvaged fragment, because the runner treats nil as "no fix offered"
    /// and escalates, which is the safe direction.
    static func proposalObject(inReply reply: String) -> [String: Any]? {
        for candidate in jsonCandidates(inReply: reply) {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  // A json block that is not a proposal (a model explaining
                  // itself in json, say) must not be mistaken for one.
                  object["action"] != nil || object["diagnosis"] != nil else {
                continue
            }
            return object
        }
        return nil
    }

    /// Every substring of the reply that might be the object, best guess first:
    /// each fenced block in order, then a bare outermost `{…}` span.
    private static func jsonCandidates(inReply reply: String) -> [String] {
        var candidates: [String] = []

        // Fenced blocks, ```json or bare ```.
        var remainder = Substring(reply)
        while let fenceStart = remainder.range(of: "```") {
            let afterFence = remainder[fenceStart.upperBound...]
            // Drop an optional language tag on the same line as the fence.
            guard let firstNewline = afterFence.firstIndex(of: "\n") else { break }
            let languageTag = afterFence[..<firstNewline].trimmingCharacters(in: .whitespaces)
            let body = afterFence[afterFence.index(after: firstNewline)...]
            guard let closingFence = body.range(of: "```") else { break }
            if languageTag.isEmpty || languageTag.lowercased() == "json" {
                candidates.append(String(body[..<closingFence.lowerBound]))
            }
            remainder = body[closingFence.upperBound...]
        }

        // An unfenced object, for a model that ignored the fence instruction.
        if let firstBrace = reply.firstIndex(of: "{"), let lastBrace = reply.lastIndex(of: "}"),
           firstBrace < lastBrace {
            candidates.append(String(reply[firstBrace...lastBrace]))
        }
        return candidates
    }
}
