//
//  MaintainModelProvider.swift
//  leanring-buddy
//
//  Tier C runs on the user's OWN model access — never the funded proxy
//  (ratified D4/D5). Three providers speak one interface so the fix loop
//  doesn't care which the user brought:
//
//    anthropic   the user's sk-ant key, through the BYO-only ClaudeAPI.
//    openai      the user's sk key, straight to api.openai.com — net-new
//                for Iris, its first non-Anthropic model call, kept behind
//                this seam so nothing else in the app learns a second SDK.
//    (agent CLIs and local models are M6.1 / v1.1; the interface is shaped
//     to take them without a caller change.)
//
//  The whole interface is one turn: history in, one assistant text turn out.
//  The ReAct loop that drives it lives in MaintainTierCFixer.
//

import Foundation

/// One conversational turn, provider-agnostic. `role` is "user" or
/// "assistant"; `text` is plain text (the loop is text-only, no tool API).
struct MaintainChatTurn: Sendable {
    let role: String
    let text: String
}

enum MaintainModelProviderError: Error {
    case noCredential
    case requestFailed(String)
}

@MainActor
protocol MaintainModelProviding: Sendable {
    var displayName: String { get }
    var isAvailable: Bool { get }
    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String
}

// MARK: - Anthropic (the user's own key, via the BYO-only ClaudeAPI)

@MainActor
final class AnthropicMaintainProvider: MaintainModelProviding {
    let displayName = "Anthropic (your key)"

    private lazy var byoOnlyAPI = ClaudeAPI(resolveTransport: {
        guard let key = KeychainStore.readSecret(ofKind: .anthropicAPIKey), !key.isEmpty else {
            return .failure(.noCredentialsAvailable)
        }
        return .success(.bringYourOwnKey(anthropicAPIKey: key))
    })

    var isAvailable: Bool { KeychainStore.hasSecret(ofKind: .anthropicAPIKey) }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        let messages = conversation.map { turn in
            ["role": turn.role, "content": turn.text] as [String: Any]
        }
        let message = try await byoOnlyAPI.continueTextConversation(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens
        )
        return message.text
    }
}

// MARK: - OpenAI (the user's own key, straight to the source)

@MainActor
final class OpenAIMaintainProvider: MaintainModelProviding {
    let displayName = "OpenAI (your key)"

    /// The model the fix loop asks for. A capable coding model; the user's
    /// key, the user's spend.
    static let model = "gpt-4o"
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    var isAvailable: Bool { KeychainStore.hasSecret(ofKind: .openAIAPIKey) }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        guard let key = KeychainStore.readSecret(ofKind: .openAIAPIKey), !key.isEmpty else {
            throw MaintainModelProviderError.noCredential
        }
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages.append(contentsOf: conversation.map { ["role": $0.role, "content": $0.text] })

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "messages": messages,
            "max_tokens": maximumOutputTokens,
            "temperature": 0,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MaintainModelProviderError.requestFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MaintainModelProviderError.requestFailed("unparseable response")
        }
        return content
    }
}

// MARK: - Resolution

enum MaintainModelProviderResolver {
    /// The provider to use for Tier C, preferring Anthropic when both keys
    /// are present (its BYO isolation is already proven and tested). Nil when
    /// the user brought no key at all — the honest funded-tier ceiling.
    @MainActor
    static func firstAvailable() -> MaintainModelProviding? {
        let anthropic = AnthropicMaintainProvider()
        if anthropic.isAvailable { return anthropic }
        let openai = OpenAIMaintainProvider()
        if openai.isAvailable { return openai }
        return nil
    }
}
