//
//  CodexChatResponder.swift
//  leanring-buddy
//
//  Answering a question through the reader's own `codex` CLI, so "Sign in with
//  ChatGPT" is a real way to use Iris rather than an app-editing credential
//  that cannot hold a conversation.
//
//  WHAT THIS CAN AND CANNOT DO, PLAINLY.
//
//  It can do the thing chat is actually for: take the question, take the
//  screenshots, and come back with an answer — including the `[POINT:x,y:…]`
//  tags the eye flies along, which are ordinary text and survive any transport.
//
//  It cannot run chat's CLIENT TOOLS. Chat's Anthropic route offers the model
//  three of them (`ChatActionTools`: copy to the clipboard, run a command, open
//  an install guide) through Messages-API `tool_use` blocks. `codex exec` has no
//  tool-use wire format to carry those, so on this route the model answers in
//  words and the reader does the doing. That is a real capability difference,
//  it is stated in the provider picker rather than discovered, and it is why
//  `supportsChatActionTools` exists as a property instead of a comment.
//
//  Streaming costs nothing here, which surprised me: the eye bar never rendered
//  progressive text anyway — `requestTheChatAnswer` passes an `onTextChunk` that
//  does nothing and the bar shows the whole answer when it lands. So the one
//  thing `codex exec` genuinely cannot do is something this surface never used.
//
//  The process machinery is `CodexMaintainProvider`'s, reused rather than
//  copied: the same argument vector, the same read-only ephemeral sandbox, the
//  same re-validation before launch, the same failure vocabulary. The only new
//  thing here is the prompt, because the Tier C framing tells the model it is
//  editing a repository and that is the wrong instruction for a question about
//  somebody's screen.
//

import Foundation

@MainActor
enum CodexChatResponder {

    /// Whether this route can offer chat's client-side tools. It cannot — see
    /// the file header. Read by the composer so the difference is visible
    /// before somebody relies on it.
    static let supportsChatActionTools = false

    /// How long one answer may take. Chat is a foreground interaction with a
    /// reader watching a spinner, so this is far tighter than Tier C's 300s: a
    /// question that has not been answered in a minute and a half has failed as
    /// far as the person waiting is concerned.
    static let answerTimeoutSeconds: TimeInterval = 90

    /// Answers one chat message.
    ///
    /// Mirrors what `ClaudeAPI.analyzeImageStreaming` returns so the call site
    /// can swap between them without reshaping anything around it.
    static func answer(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        images: [(data: Data, label: String)]
    ) async throws -> (text: String, duration: TimeInterval) {
        guard let codexBinaryPath = CodexCLILogin.locateCodexBinary() else {
            throw MaintainModelProviderError.noCredential(.codexCommandNotFound)
        }
        guard CodexCLILogin.currentState().isUsable else {
            throw MaintainModelProviderError.noCredential(.codexLoginNotUsable)
        }

        let startedAt = Date()
        let promptText = chatPromptText(
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            imageLabels: images.map(\.label)
        )

        let answerText = try await withRequestCancellation { cancellation in
            try await CodexMaintainProvider.runCodexExec(
                codexBinaryPath: codexBinaryPath,
                promptText: promptText,
                attachedImagePNGDataList: images.map(\.data),
                model: nil,
                webSearchEnabled: true,
                timeoutSeconds: answerTimeoutSeconds,
                cancellation: cancellation,
                requireAllImages: true
            )
        }

        // Nothing is reported to the spend ledger on purpose. A ChatGPT plan is
        // flat-rate, so the marginal cost of one more question is zero and a
        // dollar figure against it would be a bill Iris invented.
        return (text: answerText, duration: Date().timeIntervalSince(startedAt))
    }

    /// Bridges cancellation of the Ask task to only the Codex child it owns.
    static func withRequestCancellation<Value>(
        operation: @escaping (CodexExecCancellation) async throws -> Value
    ) async throws -> Value {
        let cancellation = CodexExecCancellation()
        return try await withTaskCancellationHandler {
            let value = try await operation(cancellation)
            try cancellation.throwIfCancelled()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// A safe diagnostic category. Never returns localized text, subprocess
    /// output, paths, prompts, images, or an arbitrary error type name.
    static func failureDiagnosticClass(for error: Error) -> String {
        if error is MaintainModelProviderError { return "codex_provider" }
        if error is AssistantTransportError { return "assistant_transport" }
        if error is CodexExecInvocation.ValidationError { return "invocation_validation" }
        if error is CancellationError { return "cancelled" }

        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain: return "foundation_\(nsError.code)"
        case NSPOSIXErrorDomain: return "posix_\(nsError.code)"
        case NSURLErrorDomain: return "url_\(nsError.code)"
        default: return "other"
        }
    }

    // MARK: - The prompt

    /// Tells Codex it is answering a question rather than editing a repository.
    ///
    /// Codex is an AGENT: handed a question about a screenshot with no framing,
    /// its instinct is to go and investigate with its own shell — which is
    /// pointed at an empty scratch directory it cannot write to, so it would
    /// spend the turn failing and hand back nothing. Tier C's preamble solves
    /// the same problem, but by telling the model to reach the repository
    /// through command blocks, which is the opposite of what chat wants.
    static let chatFramingPreamble = """
        You are being used as the assistant inside another program, answering a \
        question about what is on the user's screen. You may describe what is \
        visible and point the eye at a visible control. Do not use YOUR OWN shell, \
        file or repository tools: the directory you are running in is an empty \
        scratch directory and has nothing to do with the question. Your entire \
        reply is the answer the user reads, so write it directly to them.

        You cannot take actions on their machine on this route: do not claim to \
        copy text, run commands, or open a guide. When Iris has a separate app \
        edit or install-guide path, explain that handoff in words without \
        claiming it has started. Tell the reader what to do in words, and never \
        claim you have done it. Follow the system prompt's screen-label and \
        pointing instructions.
        """

    /// The whole prompt for one question. Pure, so the exact bytes are testable.
    static func chatPromptText(
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        imageLabels: [String]
    ) -> String {
        var sections: [String] = [chatFramingPreamble, systemPrompt]

        if !imageLabels.isEmpty {
            // The Anthropic route labels each screenshot inline with its image
            // block. `codex exec --image` takes files with no labels, so the
            // labels are named here instead, in order, or a multi-monitor
            // answer cannot say which screen it is talking about.
            let labelList = imageLabels.enumerated()
                .map { "Image \($0.offset + 1): \($0.element)" }
                .joined(separator: "\n")
            sections.append("The attached images, in order:\n\(labelList)")
        }

        for previousExchange in conversationHistory {
            sections.append("User: \(previousExchange.userPlaceholder)")
            sections.append("Assistant: \(previousExchange.assistantResponse)")
        }

        sections.append("User: \(userPrompt)")
        sections.append("Assistant:")
        return sections.joined(separator: "\n\n")
    }
}
