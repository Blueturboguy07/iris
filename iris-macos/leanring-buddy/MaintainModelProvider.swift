//
//  MaintainModelProvider.swift
//  leanring-buddy
//
//  Tier C runs on the user's OWN model access — never the funded proxy
//  (ratified D4/D5). Providers speak one interface so the fix loop doesn't
//  care which the user brought:
//
//    anthropic   the user's sk-ant key OR their Claude Code login, through
//                the BYO-only ClaudeAPI.
//    openai      the user's sk key, straight to api.openai.com — net-new
//                for Iris, its first non-Anthropic model call, kept behind
//                this seam so nothing else in the app learns a second SDK.
//    codex       the user's ChatGPT account, driven through the Codex CLI
//                they signed in to (2026-08-26). It lives in its own file,
//                `CodexMaintainProvider.swift`, because it is a subprocess
//                rather than an HTTP call — the "agent CLI" shape this
//                interface was always meant to be able to take, and the
//                proof that it can without a caller change.
//    (local models are v1.1.)
//
//  The whole interface is one turn: history in, one assistant text turn out.
//  The ReAct loop that drives it lives in MaintainTierCFixer.
//

import Foundation

/// One conversational turn, provider-agnostic. `role` is "user" or
/// "assistant"; `text` is plain text (the loop has no tool API).
/// `attachedImagePNGData` carries the ONE image the on-demand opening turn may
/// attach — a screenshot of the app's window, so the model sees what the user
/// is looking at. `var`, because the loop strips it after the first reply
/// (replaying a screenshot on all subsequent steps would cost image tokens on
/// EVERY step for context the model has already absorbed).
struct MaintainChatTurn: Sendable {
    let role: String
    let text: String
    var attachedImagePNGData: Data? = nil
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
        // The reader's own credential in either shape — a pasted API key or a
        // connected Claude Code OAuth token — never the funded proxy (D4/D5).
        guard let transport = AnthropicBringYourOwnCredential.currentTransport() else {
            return .failure(.noCredentialsAvailable)
        }
        return .success(transport)
    })

    var isAvailable: Bool { AnthropicBringYourOwnCredential.isAvailable }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        let messages = conversation.map { turn in Self.messagePayload(forTurn: turn) }
        let message = try await byoOnlyAPI.continueTextConversation(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens
        )
        return message.text
    }

    /// One turn as Messages-API JSON. A turn with an attached image becomes a
    /// content-block array (image first, then the text — the order the API
    /// docs recommend); a plain turn stays a plain string. Static + pure so
    /// the mapping is unit-testable without a network.
    nonisolated static func messagePayload(forTurn turn: MaintainChatTurn) -> [String: Any] {
        guard let attachedImagePNGData = turn.attachedImagePNGData else {
            return ["role": turn.role, "content": turn.text]
        }
        return ["role": turn.role, "content": [
            [
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": attachedImagePNGData.base64EncodedString(),
                ],
            ] as [String: Any],
            ["type": "text", "text": turn.text] as [String: Any],
        ]]
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
        messages.append(contentsOf: conversation.map { Self.messagePayload(forTurn: $0) })

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

    /// One turn as Chat-Completions JSON. A turn with an attached image
    /// becomes the multimodal content-part array (base64 data URL); a plain
    /// turn stays a plain string. Static + pure for unit tests.
    nonisolated static func messagePayload(forTurn turn: MaintainChatTurn) -> [String: Any] {
        guard let attachedImagePNGData = turn.attachedImagePNGData else {
            return ["role": turn.role, "content": turn.text]
        }
        return ["role": turn.role, "content": [
            [
                "type": "image_url",
                "image_url": [
                    "url": "data:image/png;base64,\(attachedImagePNGData.base64EncodedString())",
                ],
            ] as [String: Any],
            ["type": "text", "text": turn.text] as [String: Any],
        ]]
    }
}

// MARK: - Resolution

enum MaintainModelProviderResolver {
    /// The provider to use for Tier C, in descending order of how much Iris can
    /// promise about it. Nil when the user brought no model access at all — the
    /// honest funded-tier ceiling.
    ///
    /// The order is not a quality ranking, it is a confidence ranking:
    ///
    ///   1. Anthropic — a pasted key or a Claude Code login, through the BYO
    ///      transport whose isolation property is proven and tested.
    ///   2. OpenAI key — a pasted key, one plain HTTPS call Iris fully controls.
    ///   3. Codex login — the reader's ChatGPT account, driven through their
    ///      Codex CLI. Last because it is the only provider whose behaviour Iris
    ///      does not own end to end: a separate program, its own model default,
    ///      its own agent instincts (see `CodexMaintainProvider`). It is here so
    ///      that a reader with a ChatGPT subscription and no API key at all can
    ///      still run Tier C, which was previously impossible for them.
    @MainActor
    static func firstAvailable() -> MaintainModelProviding? {
        let anthropic = AnthropicMaintainProvider()
        if anthropic.isAvailable { return anthropic }
        let openai = OpenAIMaintainProvider()
        if openai.isAvailable { return openai }
        let codex = CodexMaintainProvider()
        if codex.isAvailable { return codex }
        return nil
    }

    /// Every provider the reader could currently use, most-preferred first.
    /// The panel uses this to say what Tier C would run on without committing
    /// to a run, and the parity harness uses it to enumerate what to compare.
    @MainActor
    static func allAvailable() -> [MaintainModelProviding] {
        let candidates: [MaintainModelProviding] = [
            AnthropicMaintainProvider(),
            OpenAIMaintainProvider(),
            CodexMaintainProvider(),
        ]
        return candidates.filter { $0.isAvailable }
    }
}
