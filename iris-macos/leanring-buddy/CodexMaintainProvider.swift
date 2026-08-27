//
//  CodexMaintainProvider.swift
//  leanring-buddy
//
//  The third Tier C provider: the reader's own ChatGPT account, reached by
//  driving the Codex CLI they already signed in to (see `CodexCLILogin.swift`
//  for why Iris drives the CLI instead of holding the credential).
//
//  The seam is `codex exec`, the CLI's documented non-interactive mode. It maps
//  onto `MaintainModelProviding` almost exactly:
//
//      MaintainModelProviding            codex exec
//      ─────────────────────             ──────────
//      systemPrompt + conversation  →    the prompt, on stdin
//      one assistant text turn out  ←    --output-last-message <file>
//      attachedImagePNGData         →    --image <file>
//      (accounting, for the harness) ←   --json event stream
//
//  FOUR FLAGS THAT ARE NOT OPTIONAL, and what each one is load-bearing for:
//
//    --sandbox read-only     Codex is an AGENT, not a raw model endpoint: it has
//                            a shell and will use it. Iris's fix loop does its
//                            own editing, verifying and committing, and a second
//                            agent writing to the same tree behind its back is
//                            precisely the class of bug the maintain harness was
//                            built to catch. Read-only is the wall.
//    --ephemeral             Every call must be stateless. The fix loop replays
//                            the whole windowed conversation each step and owns
//                            the history; a CLI-side session would silently make
//                            the model see a different past than the loop thinks
//                            it does.
//    --ignore-user-config    The reader's own ~/.codex/config.toml can pin a
//                            model, a provider, instructions, hooks, MCP servers.
//                            Iris's fix protocol is not something a stray local
//                            config gets to reshape.
//    --skip-git-repo-check   The scratch working directory is deliberately not a
//                            repo (see below); without this the CLI refuses.
//
//  These are enforced twice — built in one place, then re-checked by
//  `CodexExecInvocation.validated(_:)` before launch — for the same reason
//  `AssistantTransport.validatedRequest` exists: a later refactor that "helpfully"
//  makes the sandbox configurable trips an error instead of quietly handing a
//  second agent write access to the reader's disk.
//

import Foundation

// MARK: - Building one `codex exec` invocation (pure)

/// Everything about how Iris asks Codex a question, with no process in sight so
/// it can be asserted in unit tests.
nonisolated enum CodexExecInvocation {

    /// Ways an invocation can be refused before it is ever spawned.
    enum ValidationError: Error, Equatable {
        /// A sandbox mode other than read-only was requested.
        case sandboxWouldNotBeReadOnly(requested: String)
        /// One of the flags that bypasses approvals or sandboxing was present.
        case carriesADangerousBypass(flag: String)
        /// A required isolation flag was missing.
        case missingRequiredFlag(flag: String)
    }

    /// The flags that must be present on every invocation Iris makes.
    static let requiredFlags = ["--ephemeral", "--ignore-user-config", "--skip-git-repo-check"]

    /// Flag prefixes that must never appear. `codex` spells its escape hatches
    /// with a `--dangerously-` prefix; matching the prefix rather than a fixed
    /// list means a NEW escape hatch added by a future CLI version is refused by
    /// default instead of silently allowed.
    static let forbiddenFlagPrefix = "--dangerously-"

    /// The only sandbox mode Iris will run Codex in.
    static let requiredSandboxMode = "read-only"

    /// The argument vector for one question.
    ///
    /// `-` as the prompt makes the CLI read the prompt from stdin, which is the
    /// only workable channel: a Tier C step carries a windowed conversation and
    /// a repo map, far past what an argv entry should hold.
    static func arguments(
        finalMessageOutputPath: String,
        workingDirectory: String,
        attachedImagePaths: [String] = [],
        model: String? = nil
    ) -> [String] {
        var arguments = ["exec"]
        arguments += requiredFlags
        arguments += ["--sandbox", requiredSandboxMode]
        arguments += ["--cd", workingDirectory]
        arguments += ["--json"]
        arguments += ["--output-last-message", finalMessageOutputPath]
        if let model, !model.isEmpty {
            arguments += ["--model", model]
        }
        for attachedImagePath in attachedImagePaths {
            arguments += ["--image", attachedImagePath]
        }
        // Prompt comes from stdin.
        arguments += ["-"]
        return arguments
    }

    /// Re-checks a built argument vector against the isolation rules. Returns
    /// the vector unchanged when it holds, throws when it does not.
    @discardableResult
    static func validated(_ candidateArguments: [String]) throws -> [String] {
        for argument in candidateArguments where argument.hasPrefix(forbiddenFlagPrefix) {
            throw ValidationError.carriesADangerousBypass(flag: argument)
        }
        for requiredFlag in requiredFlags where !candidateArguments.contains(requiredFlag) {
            throw ValidationError.missingRequiredFlag(flag: requiredFlag)
        }
        // The sandbox flag must be present AND read-only. Both spellings the CLI
        // accepts are checked, so `-s danger-full-access` cannot slip past a
        // check that only knew about `--sandbox`.
        var sawSandboxMode = false
        for (index, argument) in candidateArguments.enumerated()
        where argument == "--sandbox" || argument == "-s" {
            sawSandboxMode = true
            let requestedMode = index + 1 < candidateArguments.count
                ? candidateArguments[index + 1]
                : ""
            guard requestedMode == requiredSandboxMode else {
                throw ValidationError.sandboxWouldNotBeReadOnly(requested: requestedMode)
            }
        }
        guard sawSandboxMode else {
            throw ValidationError.missingRequiredFlag(flag: "--sandbox")
        }
        return candidateArguments
    }

    // MARK: The prompt

    /// Codex has no system-prompt channel — `codex exec` takes one prompt. So
    /// the system prompt is folded in as a leading block, and the conversation
    /// is replayed under speaker labels beneath it.
    ///
    /// The framing preamble is not decoration. Codex is an agent whose default
    /// instinct on "here is a broken repo" is to go and fix it with its own
    /// shell — which would produce an empty-handed final message and no edits
    /// Iris can see (its sandbox is read-only and its cwd is a scratch dir).
    /// The preamble tells it plainly that it is being used as a text model and
    /// that its REPLY is the deliverable. How well that actually holds is not
    /// something a comment gets to assert: it is measured by the live parity
    /// harness, `tools/codex-parity/`.
    static let framingPreamble = """
        You are being used as a text model inside another program. Do not use \
        your shell, do not read or write files, and do not try to perform the \
        task yourself — you have no access to the files being discussed and any \
        attempt will fail. Your entire reply is the deliverable, and it must \
        follow the output format described below exactly.
        """

    /// The whole prompt for one step. Pure, so the exact bytes sent are testable.
    static func promptText(systemPrompt: String, conversation: [MaintainChatTurn]) -> String {
        var sections: [String] = [framingPreamble, systemPrompt]
        for turn in conversation {
            let speakerLabel = turn.role == "assistant" ? "Assistant" : "User"
            sections.append("\(speakerLabel): \(turn.text)")
        }
        // The trailing cue matters for the same reason the preamble does: it is
        // the last thing in the context, and it names the shape of the turn the
        // loop is waiting for.
        sections.append("Assistant:")
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Reading what came back (pure)

/// Parsing of the `--json` event stream and the final-message file.
nonisolated enum CodexExecOutput {

    /// The final assistant turn, recovered from the JSONL event stream.
    ///
    /// The `--output-last-message` file is the primary source (it is exactly the
    /// final turn, already unwrapped); this is the fallback for when the CLI
    /// exits before writing it. It takes the LAST `agent_message`, because a run
    /// that narrated intermediate steps emits several and only the last one is
    /// the answer.
    static func finalAssistantText(fromJSONL jsonLines: String) -> String? {
        var lastAgentMessage: String?
        for line in jsonLines.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any],
                  item["type"] as? String == "agent_message",
                  let text = item["text"] as? String else {
                continue
            }
            lastAgentMessage = text
        }
        return lastAgentMessage
    }

    /// Token accounting from the `turn.completed` event. Used by the parity
    /// harness, and by nothing in the app — Iris does not bill this tier.
    struct Usage: Equatable {
        let inputTokens: Int
        let cachedInputTokens: Int
        let outputTokens: Int
        let reasoningOutputTokens: Int
    }

    static func usage(fromJSONL jsonLines: String) -> Usage? {
        for line in jsonLines.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  event["type"] as? String == "turn.completed",
                  let usage = event["usage"] as? [String: Any] else {
                continue
            }
            return Usage(
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                cachedInputTokens: usage["cached_input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                reasoningOutputTokens: usage["reasoning_output_tokens"] as? Int ?? 0
            )
        }
        return nil
    }

    /// Maps a failed run onto the error vocabulary the fix loop already handles.
    ///
    /// HONESTY: this is a HEURISTIC over the CLI's human-readable stderr, not a
    /// parse of a documented error contract — `codex exec` does not expose
    /// machine-readable failure codes. It is written to fail safe: anything it
    /// does not recognize becomes a plain `requestFailed`, which the loop treats
    /// as a real failure rather than something to retry forever. The one case
    /// worth recognizing precisely is the rate limit, because the loop has a
    /// working backoff for it and would otherwise burn a step.
    static func failure(fromStandardError standardErrorText: String, exitCode: Int32) -> Error {
        let lowercased = standardErrorText.lowercased()
        if lowercased.contains("not logged in")
            || lowercased.contains("please run `codex login`")
            || lowercased.contains("no credentials")
            || lowercased.contains("unauthorized") {
            return MaintainModelProviderError.noCredential
        }
        if lowercased.contains("rate limit")
            || lowercased.contains("usage limit")
            || lowercased.contains("quota") {
            return AssistantTransportError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(inStandardError: standardErrorText)
            )
        }
        let trimmedDetail = standardErrorText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .suffix(300)
        return MaintainModelProviderError.requestFailed(
            trimmedDetail.isEmpty ? "codex exec exited \(exitCode)" : String(trimmedDetail)
        )
    }

    /// Pulls a "try again in N seconds/minutes" hint out of a rate-limit message
    /// when one is there. Nil when it is not — the loop has its own default.
    static func retryAfterSeconds(inStandardError standardErrorText: String) -> Int? {
        let patterns: [(String, Int)] = [
            ("([0-9]+) *seconds?", 1),
            ("([0-9]+) *minutes?", 60),
            ("([0-9]+) *hours?", 3600),
        ]
        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }
            let wholeRange = NSRange(standardErrorText.startIndex..., in: standardErrorText)
            guard let match = regex.firstMatch(in: standardErrorText, range: wholeRange),
                  let captureRange = Range(match.range(at: 1), in: standardErrorText),
                  let quantity = Int(standardErrorText[captureRange]) else {
                continue
            }
            return quantity * multiplier
        }
        return nil
    }
}

// MARK: - The provider

@MainActor
final class CodexMaintainProvider: MaintainModelProviding {
    let displayName = "Codex (your ChatGPT login)"

    /// Left nil so the CLI's own default applies — which is what the reader
    /// chose when they installed it, and what `codex` upgrades over time. Iris
    /// pinning a model here would go stale silently.
    private let model: String?

    /// How long one step may take before Iris gives up on it. Generous: a Tier C
    /// step can carry a large context, and a reasoning model can take a while.
    /// The fix loop's own step ceiling is what bounds a run overall.
    private static let stepTimeoutSeconds: TimeInterval = 300

    init(model: String? = nil) {
        self.model = model
    }

    var isAvailable: Bool { CodexCLILogin.currentState().isUsable }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        guard let codexBinaryPath = CodexCLILogin.locateCodexBinary() else {
            throw MaintainModelProviderError.noCredential
        }
        guard CodexCLILogin.currentState().isUsable else {
            throw MaintainModelProviderError.noCredential
        }

        // NOTE on `maximumOutputTokens`: `codex exec` exposes no output cap, so
        // this argument is genuinely not honored on this provider — a real
        // parity difference, stated here rather than papered over. What bounds a
        // run is the fix loop's step ceiling, which applies to every provider.

        let promptText = CodexExecInvocation.promptText(
            systemPrompt: systemPrompt, conversation: conversation
        )
        let attachedImages = conversation.compactMap { $0.attachedImagePNGData }

        return try await Self.runCodexExec(
            codexBinaryPath: codexBinaryPath,
            promptText: promptText,
            attachedImagePNGDataList: attachedImages,
            model: model,
            timeoutSeconds: Self.stepTimeoutSeconds
        )
    }

    // MARK: - Running the process

    /// Spawns one `codex exec`, feeds it the prompt on stdin, and returns its
    /// final assistant turn. `nonisolated` so the blocking wait happens off the
    /// main actor — the panel must stay live while a step is in flight.
    nonisolated static func runCodexExec(
        codexBinaryPath: String,
        promptText: String,
        attachedImagePNGDataList: [Data],
        model: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        // A scratch directory per call: it is the agent's working root, and it
        // is deliberately EMPTY and outside any repo, so even a read-only shell
        // has nothing of the reader's to look at.
        let scratchDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-codex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: scratchDirectoryURL, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: scratchDirectoryURL) }

        let finalMessageURL = scratchDirectoryURL.appendingPathComponent("final-message.txt")

        var attachedImagePaths: [String] = []
        for (index, imagePNGData) in attachedImagePNGDataList.enumerated() {
            let imageURL = scratchDirectoryURL.appendingPathComponent("attachment-\(index).png")
            guard (try? imagePNGData.write(to: imageURL)) != nil else { continue }
            attachedImagePaths.append(imageURL.path)
        }

        let arguments = try CodexExecInvocation.validated(
            CodexExecInvocation.arguments(
                finalMessageOutputPath: finalMessageURL.path,
                workingDirectory: scratchDirectoryURL.path,
                attachedImagePaths: attachedImagePaths,
                model: model
            )
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinaryPath)
        process.arguments = arguments
        process.environment = CodexCLILogin.environmentForCodex()
        process.currentDirectoryURL = scratchDirectoryURL

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        do {
            try process.run()
        } catch {
            throw MaintainModelProviderError.requestFailed("couldn't start codex: \(error.localizedDescription)")
        }

        // Feed the prompt and close stdin so the CLI stops waiting for more.
        if let promptData = promptText.data(using: .utf8) {
            standardInputPipe.fileHandleForWriting.write(promptData)
        }
        try? standardInputPipe.fileHandleForWriting.close()

        // Drain both pipes on their own threads. A `codex exec --json` run can
        // emit more than a pipe buffer holds, and a full pipe would deadlock the
        // child against a parent that is only waiting on exit.
        let outputCollector = PipeCollector(fileHandle: standardOutputPipe.fileHandleForReading)
        let errorCollector = PipeCollector(fileHandle: standardErrorPipe.fileHandleForReading)

        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning { process.terminate() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        watchdog.cancel()

        let standardOutputText = outputCollector.collectedText()
        let standardErrorText = errorCollector.collectedText()

        if process.terminationStatus != 0 {
            throw CodexExecOutput.failure(
                fromStandardError: standardErrorText.isEmpty ? standardOutputText : standardErrorText,
                exitCode: process.terminationStatus
            )
        }

        // The written file first; the event stream as the fallback.
        if let finalMessage = try? String(contentsOf: finalMessageURL, encoding: .utf8),
           !finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return finalMessage
        }
        if let recoveredMessage = CodexExecOutput.finalAssistantText(fromJSONL: standardOutputText),
           !recoveredMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return recoveredMessage
        }
        throw MaintainModelProviderError.requestFailed("codex exec produced no assistant message")
    }
}

// MARK: - Pipe draining

/// Reads a pipe to EOF on a background thread and hands back what it got.
///
/// This exists because the obvious `readDataToEndOfFile()` on the calling thread
/// serializes the two pipes: stderr cannot be drained until stdout has closed,
/// so a child that fills its stderr buffer first blocks forever. Both are read
/// concurrently here.
private nonisolated final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collectedData = Data()
    private let finishedReading = DispatchSemaphore(value: 0)

    init(fileHandle: FileHandle) {
        Thread.detachNewThread { [self] in
            let data = fileHandle.readDataToEndOfFile()
            lock.lock()
            collectedData = data
            lock.unlock()
            finishedReading.signal()
        }
    }

    func collectedText() -> String {
        finishedReading.wait()
        lock.lock()
        defer { lock.unlock() }
        return String(data: collectedData, encoding: .utf8) ?? ""
    }
}
