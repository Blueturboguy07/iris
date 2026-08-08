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
        toolChoice: [String: Any]? = nil
    ) -> [String: Any] {
        var requestBody: [String: Any] = [
            "max_tokens": maximumOutputTokens,
            "system": systemPrompt,
            "messages": messages,
        ]
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
    ) async throws -> (text: String, duration: TimeInterval) {
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
            shouldStream: true
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
