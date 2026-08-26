//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//
//  The SSE parsing here is route-agnostic on purpose: publik's funded endpoint
//  is a passthrough of the Anthropic Messages API, so the same parser serves a
//  signed-in user and a bring-your-own-key user without a branch. What differs
//  is only the URL and the headers, and deciding those is `AssistantTransport`'s
//  job — this file never constructs a credential of its own.
//

import Foundation

/// What a tool Iris executed itself hands back to the model, in the shape a
/// `tool_result` block wants.
///
/// `isError` is about whether the TOOL ran, not about whether what it ran
/// succeeded. A command that exits 1 ran perfectly well and its exit code is
/// the answer; a command the risk gate refused never ran at all, and that is
/// the difference this flag carries.
struct ClaudeClientToolResult: Sendable {
    let contentText: String
    let isError: Bool
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hostsAlreadyWarmedUp: Set<String> = []

    /// Asked for a transport at the start of every request rather than once at
    /// init, because the answer changes underneath us: the user can sign in,
    /// sign out, or paste a key while the app is running, and an access token
    /// can need refreshing between two messages.
    private let resolveTransport: @Sendable () async -> Result<AssistantTransport, AssistantTransportError>

    /// The model the user picked. Honored on the bring-your-own-key route and
    /// deliberately omitted on the funded route, where the server pins its own.
    var model: String

    private let session: URLSession

    init(
        resolveTransport: @escaping @Sendable () async -> Result<AssistantTransport, AssistantTransportError>,
        model: String = "claude-sonnet-4-6"
    ) {
        self.resolveTransport = resolveTransport
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to whichever host the current transport uses,
    /// to establish and cache a TLS session before the first real (large,
    /// image-bearing) request pays for a cold handshake.
    ///
    /// This is called explicitly by `CompanionManager` at startup rather than
    /// from `init`, because the host is now a property of the chosen route and
    /// is not knowable until a transport has been resolved. Failures are
    /// silently ignored — this is purely an optimization.
    func warmUpTLSConnectionIfNeeded() async {
        guard case .success(let transport) = await resolveTransport(),
              let requestToWarmFor = try? await transport.makeChatRequest(),
              let hostToWarm = requestToWarmFor.url?.host else {
            return
        }

        Self.tlsWarmupLock.lock()
        let shouldWarmThisHost = !Self.hostsAlreadyWarmedUp.contains(hostToWarm)
        if shouldWarmThisHost {
            Self.hostsAlreadyWarmedUp.insert(hostToWarm)
        }
        Self.tlsWarmupLock.unlock()

        guard shouldWarmThisHost else { return }

        // The TLS session ticket is host-scoped, so warming the root path is
        // enough, and it deliberately carries none of the request's headers —
        // there is no reason for a credential to ride along on a warmup.
        guard let warmupURL = URL(string: "https://\(hostToWarm)/") else { return }
        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    // MARK: - Request assembly

    /// Builds the message list both routes share.
    private func buildMessages(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        return messages
    }

    /// Assembles the request body for a route.
    ///
    /// The `model` field is included only where it is actually honored. The
    /// funded route pins the model server-side and ignores whatever the client
    /// sends, and a field the server throws away is worse than absent: the next
    /// person to read this would reasonably conclude the picker controls it.
    private func buildRequestBody(
        for transport: AssistantTransport,
        systemPrompt: String,
        messages: [[String: Any]],
        maximumOutputTokens: Int,
        shouldStream: Bool,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        /// Set to 0 for anything whose answer should not change between two
        /// identical questions.
        ///
        /// Pointing needs this and never had it. The default is 1.0, so asking
        /// "where is the Install Node LTS control" about an unchanged screen was
        /// sampled fresh every time: one reader's six attempts at a single
        /// target produced five different coordinates. The maintain engine has
        /// always set 0; this path was simply missed.
        temperature: Double? = nil
    ) -> [String: Any] {
        var requestBody: [String: Any] = [
            "max_tokens": maximumOutputTokens,
            "system": Self.systemFieldValue(for: transport, systemPrompt: systemPrompt),
            "messages": messages,
        ]
        if let temperature {
            requestBody["temperature"] = temperature
        }
        if shouldStream {
            requestBody["stream"] = true
        }
        if transport.shouldSendModelInRequestBody {
            requestBody["model"] = model
        }
        // Tools ride in the body, not the transport: the funded proxy
        // allowlists them server-side and the BYO route sends them straight
        // to Anthropic. AssistantTransport needs no change for this, and
        // that is deliberate — do not "helpfully" move tools there.
        if let tools {
            requestBody["tools"] = tools
        }
        if let toolChoice {
            requestBody["tool_choice"] = toolChoice
        }
        return requestBody
    }

    /// The value of the request body's `system` field for this transport.
    ///
    /// On the OAuth-token route Anthropic accepts the request only when the
    /// system prompt LEADS with Claude Code's own identity sentence (see
    /// `AssistantTransport.claudeCodeIdentitySystemBlockText`), so there the
    /// field becomes an array of text blocks — the identity first, the
    /// caller's actual system prompt second. Everywhere else the field stays
    /// the plain string it has always been. An empty caller prompt on the
    /// OAuth route still sends the identity block alone, because a request
    /// with no system prompt at all is rejected the same way.
    static func systemFieldValue(
        for transport: AssistantTransport,
        systemPrompt: String
    ) -> Any {
        guard transport.shouldPrependClaudeCodeIdentitySystemBlock else {
            return systemPrompt
        }
        var systemBlocks: [[String: Any]] = [
            ["type": "text", "text": AssistantTransport.claudeCodeIdentitySystemBlockText]
        ]
        if !systemPrompt.isEmpty {
            systemBlocks.append(["type": "text", "text": systemPrompt])
        }
        return systemBlocks
    }

    /// Turns a non-2xx response into the user-visible state for that route.
    /// The body is read only far enough to find the funded tier's `error` code;
    /// it is never carried into the thrown error, because that error's message
    /// is shown to the user and a raw server body is not fit for that.
    private func failure(
        forStatusCode statusCode: Int,
        failureBodyData: Data,
        retryAfterHeaderValue: String?,
        transport: AssistantTransport
    ) -> AssistantTransportError {
        let isFundedTier: Bool
        if case .funded = transport {
            isFundedTier = true
        } else {
            isFundedTier = false
        }

        let serverErrorCode = AssistantTransportError.serverErrorCode(inFailureBody: failureBodyData)
        // The code and status are worth a console line for whoever is debugging
        // a build; the body itself is not logged, so a model's own words about a
        // user's screen never land in a log file.
        print("⚠️ Assistant request failed — status \(statusCode), code: \(serverErrorCode ?? "none")")

        return AssistantTransportError.failure(
            forStatusCode: statusCode,
            serverErrorCode: serverErrorCode,
            retryAfterHeaderValue: retryAfterHeaderValue,
            isFundedTier: isFundedTier
        )
    }

    // MARK: - Streaming

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ,
        /// 0 for a question whose answer should not move between identical asks.
        temperature: Double? = nil) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let transport = try await resolveTransport().get()
        var request = try await transport.makeChatRequest()

        let messages = buildMessages(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        let body = buildRequestBody(
            for: transport,
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: 1024,
            shouldStream: true,
            temperature: temperature
        )

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request via \(transport.tierDescription): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(for: request)
        } catch {
            throw AssistantTransportError.transportFailure(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantTransportError.requestFailed(statusCode: -1)
        }

        // If non-2xx status, drain the body only to find the machine-readable
        // error code, then discard it.
        guard (200...299).contains(httpResponse.statusCode) else {
            var failureBodyChunks: [String] = []
            for try await line in byteStream.lines {
                failureBodyChunks.append(line)
            }
            let failureBodyData = Data(failureBodyChunks.joined(separator: "\n").utf8)
            throw failure(
                forStatusCode: httpResponse.statusCode,
                failureBodyData: failureBodyData,
                retryAfterHeaderValue: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                transport: transport
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    // MARK: - Tool-carrying requests

    /// A chat turn that may DO things: the same screenshot-carrying request
    /// `analyzeImageStreaming` sends, plus a tool list, plus the loop that runs
    /// whatever the model asks for and hands the REAL result back so it can
    /// react to what actually happened rather than to what it hoped would.
    ///
    /// Two kinds of tool ride here and only one of them loops. Server tools
    /// (`web_search`) are executed on Anthropic's side inside the same turn and
    /// arrive already answered; a long one surfaces as a `pause_turn` stop
    /// reason, resumed by resending the assistant's own blocks exactly the way
    /// `respondWithTools` does. Client tools (the clipboard, a command) come
    /// back as `tool_use` blocks that Iris must answer with a `tool_result`
    /// before the model can finish its sentence — that round trip is the whole
    /// point, because it is what lets the model tell the reader that a command
    /// exited 1 instead of assuming it worked.
    ///
    /// Every path out of here is bounded. `maximumClientToolRounds` caps how
    /// many times tools may actually execute, and `maximumModelCalls` is an
    /// absolute ceiling so a model that will not stop asking still ends the
    /// turn. A round that is over budget executes NOTHING and says so — but it
    /// still answers every `tool_use`, because an unanswered one is a
    /// malformed conversation the API rejects.
    func analyzeImageStreamingRunningClientTools(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        tools: [[String: Any]],
        maximumClientToolRounds: Int,
        // @escaping because each round wraps this in a closure of its own to
        // prefix the text earlier rounds already produced, and the optional
        // parameter it is handed to is escaping by construction.
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void,
        executeClientTool: @MainActor (_ toolName: String, _ toolInputJSONText: String) async -> ClaudeClientToolResult
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var messages = buildMessages(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        // The model can speak on either side of a tool call ("let me check…"
        // then "…it's already installed"), and the reader is owed both halves,
        // so text accumulates across rounds rather than only the last round
        // surviving.
        var textAcrossAllRounds = ""
        var clientToolRoundsUsed = 0
        var pauseTurnResumesUsed = 0
        let maximumPauseTurnResumes = 3
        // Deliberately larger than the sum of the two budgets: after the last
        // round of tools the model still needs one call to put the outcome into
        // words. It cannot loop forever regardless — this counter only ever
        // rises.
        let maximumModelCalls = maximumClientToolRounds + maximumPauseTurnResumes + 2
        var modelCallsUsed = 0

        while modelCallsUsed < maximumModelCalls {
            modelCallsUsed += 1

            let textFromEarlierRounds = textAcrossAllRounds
            let message = try await streamOneMessage(
                systemPrompt: systemPrompt,
                messages: messages,
                maximumOutputTokens: 1024,
                tools: tools,
                toolChoice: nil,
                onTextChunk: { textSoFarThisRound in
                    // Progressive display must show the whole answer so far,
                    // not just this round's share of it.
                    onTextChunk(textFromEarlierRounds + textSoFarThisRound)
                }
            )

            if !message.text.isEmpty {
                textAcrossAllRounds += textAcrossAllRounds.isEmpty ? message.text : "\n\n" + message.text
            }

            if message.stopReason == "pause_turn", pauseTurnResumesUsed < maximumPauseTurnResumes {
                pauseTurnResumesUsed += 1
                messages.append(["role": "assistant", "content": message.assistantContentBlocks])
                continue
            }

            guard !message.toolUses.isEmpty else { break }

            messages.append(["role": "assistant", "content": message.assistantContentBlocks])

            // The budget is spent per ROUND, not per tool, so a round that is
            // over budget runs none of its tools rather than running the first
            // and refusing the second — half-done is the worst of both.
            let thisRoundMayExecute = clientToolRoundsUsed < maximumClientToolRounds
            var toolResultBlocks: [[String: Any]] = []
            for toolUse in message.toolUses {
                let result: ClaudeClientToolResult
                if thisRoundMayExecute {
                    result = await executeClientTool(toolUse.name, toolUse.inputJSONText)
                } else {
                    result = ClaudeClientToolResult(
                        contentText: """
                        Iris has done as much as it will do for one message, so this was NOT \
                        run and nothing changed. Answer the reader in words now.
                        """,
                        isError: true
                    )
                }
                toolResultBlocks.append([
                    "type": "tool_result",
                    "tool_use_id": toolUse.identifier,
                    "content": result.contentText,
                    "is_error": result.isError,
                ])
            }
            messages.append(["role": "user", "content": toolResultBlocks])
            clientToolRoundsUsed += 1
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: textAcrossAllRounds, duration: duration)
    }

    /// One Messages call whose answer arrives as structured tool_use blocks
    /// (and, with server tools like web_search, as server-executed rounds).
    /// The tool here is a schema carrier: nothing is executed client-side
    /// and no tool_result is ever sent back. A `pause_turn` stop reason is
    /// resumed by resending the conversation with the assistant's blocks
    /// appended, at most `maximumContinuations` times.
    func respondWithTools(
        systemPrompt: String,
        userMessageText: String,
        tools: [[String: Any]],
        toolChoice: [String: Any]?,
        maximumOutputTokens: Int
    ) async throws -> ClaudeStreamedMessage {
        var messages: [[String: Any]] = [
            ["role": "user", "content": userMessageText]
        ]
        let maximumContinuations = 3

        var latest = try await streamOneMessage(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens,
            tools: tools,
            toolChoice: toolChoice
        )
        var continuationsUsed = 0
        while latest.stopReason == "pause_turn", continuationsUsed < maximumContinuations {
            continuationsUsed += 1
            messages.append(["role": "assistant", "content": latest.assistantContentBlocks])
            latest = try await streamOneMessage(
                systemPrompt: systemPrompt,
                messages: messages,
                maximumOutputTokens: maximumOutputTokens,
                tools: tools,
                toolChoice: toolChoice
            )
        }
        return latest
    }

    /// A plain multi-turn text exchange: the caller owns the whole message
    /// history and gets back one assistant turn. This is what the maintain
    /// mode Tier C fixer's ReAct loop runs on — ask for one bash command,
    /// run it, append the result, ask again — without the tool-calling API,
    /// exactly the mini-swe-agent shape. No tools passed, so nothing here can
    /// reach a server-side tool.
    func continueTextConversation(
        systemPrompt: String,
        messages: [[String: Any]],
        maximumOutputTokens: Int
    ) async throws -> ClaudeStreamedMessage {
        try await streamOneMessage(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens
        )
    }

    /// Sends one streaming request and reassembles the full message. Shared
    /// by `respondWithTools` and `analyzeImage`.
    private func streamOneMessage(
        systemPrompt: String,
        messages: [[String: Any]],
        maximumOutputTokens: Int,
        tools: [[String: Any]]? = nil,
        toolChoice: [String: Any]? = nil,
        onTextChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> ClaudeStreamedMessage {
        let transport = try await resolveTransport().get()
        var request = try await transport.makeChatRequest()
        let body = buildRequestBody(
            for: transport,
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: maximumOutputTokens,
            shouldStream: true,
            tools: tools,
            toolChoice: toolChoice
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(for: request)
        } catch {
            throw AssistantTransportError.transportFailure(reason: error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AssistantTransportError.requestFailed(statusCode: -1)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var failureBodyChunks: [String] = []
            for try await line in byteStream.lines {
                failureBodyChunks.append(line)
            }
            throw failure(
                forStatusCode: httpResponse.statusCode,
                failureBodyData: Data(failureBodyChunks.joined(separator: "\n").utf8),
                retryAfterHeaderValue: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                transport: transport
            )
        }

        var accumulator = ClaudeSSEMessageAccumulator()
        var accumulatedText = ""
        for try await line in byteStream.lines {
            if let freshText = accumulator.consume(line: line), let onTextChunk {
                accumulatedText += freshText
                let textSoFar = accumulatedText
                await onTextChunk(textSoFar)
            }
        }
        return accumulator.finalize()
    }

    /// Non-streaming interface over the streaming wire format. The funded
    /// route hard-codes `stream: true` upstream and answers with SSE no
    /// matter what the client asked, so parsing the body as plain JSON —
    /// what this method did originally — failed on the funded tier and the
    /// watch loop's `try?` swallowed the error. Streaming both routes and
    /// assembling the message here makes the two tiers genuinely
    /// interchangeable again.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let messages = buildMessages(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        let message = try await streamOneMessage(
            systemPrompt: systemPrompt,
            messages: messages,
            maximumOutputTokens: 256
        )
        let duration = Date().timeIntervalSince(startTime)
        return (text: message.text, duration: duration)
    }
}
