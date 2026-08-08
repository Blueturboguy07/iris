//
//  GuideAutopilotFixProposer.swift
//  leanring-buddy
//
//  When a guide command fails, this assembles what actually happened — the
//  step, the exact command, the exit status, the scrubbed output tail — and
//  asks the model for ONE structured fix through a forced `propose_fix`
//  tool call. Rung (a) asks from the material alone; rung (b) adds
//  Anthropic's server-side web_search and lets the model look the error up.
//
//  No screenshot rides along, ever. The failure happened in a terminal Iris
//  owns; Iris has the text. Pixels cost money and privacy for nothing here —
//  and sending the command text instead of pixels is precisely what fixes
//  the `ping api.publik.local` class of confabulation, where the model
//  reasoned from a screenshot because nobody had told it the command.
//
//  The tool is a schema carrier, not a callable: Iris reads the proposal
//  out of the tool_use block and the exchange ends. No tool_result, no
//  agent loop.
//

import Foundation

/// Everything the model is told about a failure. Assembled once, used by
/// both rungs, and carried forward so attempt two knows what attempt one
/// already tried.
struct GuideAutopilotFailureContext {
    let guideSlug: String
    let guideVersion: Int
    let appName: String
    let platformLabel: String
    let stepIdentifier: String
    let stepTitle: String
    let stepBody: String
    let verifierLabel: String?
    let commandAsRun: String
    let exitStatus: Int32
    let scrubbedOutputTail: String
    let shellPath: String
    let workingDirectory: String
    let operatingSystemVersion: String
    let architecture: String
    let knownToolVersions: [String]
    let priorAttempts: [String]
    /// Hosts named by the guide's own commands — the only network
    /// destinations a proposed fix is allowed to reach.
    let hostsTheGuideAlreadyReaches: Set<String>
}

/// What the model proposed, decoded from the tool_use block.
enum GuideAutopilotProposedFixAction: Equatable {
    case runACommand(command: String, whatItDoes: String)
    case askTheReaderToDoSomething(instruction: String)
    case cannotFixThis(reason: String)
}

struct GuideAutopilotProposedFix: Equatable {
    let diagnosis: String
    let confidence: String
    let action: GuideAutopilotProposedFixAction
    let retryTheOriginalCommandAfterwards: Bool
    let cameFromWebSearch: Bool
}

@MainActor
protocol GuideAutopilotFixProposing: AnyObject {
    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix?
    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix?
}

@MainActor
final class GuideAutopilotFixProposer: GuideAutopilotFixProposing {

    static let maximumOutputTokensPerFixCall = 700
    static let maximumWebSearchesPerCall = 5

    private let claudeAPI: ClaudeAPI

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    // MARK: - The two rungs

    func proposeFix(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        let message = try await claudeAPI.respondWithTools(
            systemPrompt: Self.systemPrompt(for: context),
            userMessageText: Self.failureReport(for: context),
            tools: [Self.proposeFixTool],
            toolChoice: ["type": "tool", "name": "propose_fix"],
            maximumOutputTokens: Self.maximumOutputTokensPerFixCall
        )
        return Self.decodedFix(from: message, cameFromWebSearch: false, context: context)
    }

    func proposeFixWithWebSearch(
        for context: GuideAutopilotFailureContext
    ) async throws -> GuideAutopilotProposedFix? {
        // tool_choice auto: a forced propose_fix would forbid searching.
        // The system prompt tells the model to search first, then propose.
        let message = try await claudeAPI.respondWithTools(
            systemPrompt: Self.systemPrompt(for: context)
                + "\n\nYou may use web_search to look this error up before proposing. "
                + "Search for the exact error text, then call propose_fix with what you learned.",
            userMessageText: Self.failureReport(for: context),
            tools: [Self.webSearchTool, Self.proposeFixTool],
            toolChoice: ["type": "auto"],
            maximumOutputTokens: Self.maximumOutputTokensPerFixCall
        )
        return Self.decodedFix(from: message, cameFromWebSearch: true, context: context)
    }

    // MARK: - Decoding, and the guardrails that survive a bad model answer

    static func decodedFix(
        from message: ClaudeStreamedMessage,
        cameFromWebSearch: Bool,
        context: GuideAutopilotFailureContext
    ) -> GuideAutopilotProposedFix? {
        guard let toolUse = message.toolUses.first(where: { $0.name == "propose_fix" }),
              let input = toolUse.inputObject,
              let diagnosis = input["diagnosis"] as? String,
              let confidence = input["confidence"] as? String,
              let retry = input["retryTheOriginalCommandAfterwards"] as? Bool,
              let actionObject = input["action"] as? [String: Any],
              let kind = actionObject["kind"] as? String else {
            // No proposal is a legitimate answer at rung (b) — the model
            // searched and found nothing. The runner escalates.
            return nil
        }

        let action: GuideAutopilotProposedFixAction
        switch kind {
        case "runACommand":
            guard let command = actionObject["command"] as? String,
                  let whatItDoes = actionObject["whatItDoes"] as? String else { return nil }
            // A fix may not quietly introduce a new network destination:
            // every host it reaches must already appear in the guide's own
            // commands. This is the structural answer to an invented
            // hostname — it does not matter how plausible it sounds.
            let hosts = GuideAutopilotCommandShape.hostsTheCommandWouldReach(command)
            guard hosts.isSubset(of: context.hostsTheGuideAlreadyReaches) else {
                return GuideAutopilotProposedFix(
                    diagnosis: diagnosis,
                    confidence: confidence,
                    action: .cannotFixThis(
                        reason: "The proposed fix reached for a host the guide never uses"
                            + " (\(hosts.subtracting(context.hostsTheGuideAlreadyReaches).sorted().joined(separator: ", ")))."
                    ),
                    retryTheOriginalCommandAfterwards: false,
                    cameFromWebSearch: cameFromWebSearch
                )
            }
            action = .runACommand(command: command, whatItDoes: whatItDoes)
        case "askTheReaderToDoSomething":
            guard let instruction = actionObject["instruction"] as? String else { return nil }
            action = .askTheReaderToDoSomething(instruction: instruction)
        case "cannotFixThis":
            guard let reason = actionObject["reason"] as? String else { return nil }
            action = .cannotFixThis(reason: reason)
        default:
            return nil
        }

        return GuideAutopilotProposedFix(
            diagnosis: diagnosis,
            confidence: confidence,
            action: action,
            retryTheOriginalCommandAfterwards: retry,
            cameFromWebSearch: cameFromWebSearch
        )
    }

    // MARK: - The prompt

    static func systemPrompt(for context: GuideAutopilotFailureContext) -> String {
        """
        You are Iris's install-repair assistant. A command from the published \
        install guide for \(context.appName) just failed in Iris's own terminal, \
        and you propose exactly one fix via the propose_fix tool.

        Hard rules, in order:
        - Never invent hostnames, URLs, file paths, or commands that do not \
        appear in the material you were given or belong to the toolchain the \
        guide itself uses (git, node, pnpm, cargo, and the like).
        - Never propose reaching a network host that does not already appear \
        in the guide's own commands.
        - Never propose sudo unless the output plainly says permission denied.
        - Never ask for or handle secrets, passwords, or API keys.
        - "cannotFixThis" is a good answer. A wrong fix costs the reader more \
        than an honest dead end.
        - Keep the diagnosis to one or two plain sentences a non-developer \
        can follow.
        """
    }

    static func failureReport(for context: GuideAutopilotFailureContext) -> String {
        var report = """
        Guide: \(context.guideSlug) v\(context.guideVersion) (\(context.appName), \(context.platformLabel))
        Step \(context.stepIdentifier): \(context.stepTitle)
        \(context.stepBody)
        """
        if let verifier = context.verifierLabel {
            report += "\nStep is done when: \(verifier)"
        }
        report += """


        Command run (verbatim):
        \(context.commandAsRun)

        Exit status: \(context.exitStatus)
        Working directory: \(context.workingDirectory)
        Shell: \(context.shellPath)
        System: \(context.operatingSystemVersion) (\(context.architecture))
        """
        if !context.knownToolVersions.isEmpty {
            report += "\nTool versions: " + context.knownToolVersions.joined(separator: ", ")
        }
        if !context.priorAttempts.isEmpty {
            report += "\n\nAlready tried on this step (do not repeat):\n"
                + context.priorAttempts.map { "- \($0)" }.joined(separator: "\n")
        }
        report += """


        Output tail (secrets redacted):
        \(context.scrubbedOutputTail)
        """
        return report
    }

    // MARK: - Tool definitions

    static let proposeFixTool: [String: Any] = [
        "name": "propose_fix",
        "description": "Propose one fix for the command that just failed, or report that you cannot.",
        "strict": true,
        "input_schema": [
            "type": "object",
            "additionalProperties": false,
            "required": ["diagnosis", "confidence", "action", "retryTheOriginalCommandAfterwards"],
            "properties": [
                "diagnosis": ["type": "string"],
                "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                "retryTheOriginalCommandAfterwards": ["type": "boolean"],
                "action": [
                    "anyOf": [
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["kind", "command", "whatItDoes"],
                            "properties": [
                                "kind": ["const": "runACommand"],
                                "command": ["type": "string"],
                                "whatItDoes": ["type": "string"],
                            ],
                        ],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["kind", "instruction"],
                            "properties": [
                                "kind": ["const": "askTheReaderToDoSomething"],
                                "instruction": ["type": "string"],
                            ],
                        ],
                        [
                            "type": "object",
                            "additionalProperties": false,
                            "required": ["kind", "reason"],
                            "properties": [
                                "kind": ["const": "cannotFixThis"],
                                "reason": ["type": "string"],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ]

    static let webSearchTool: [String: Any] = [
        "type": "web_search_20250305",
        "name": "web_search",
        "max_uses": maximumWebSearchesPerCall,
    ]
}
