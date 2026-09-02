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
        model: String? = nil,
        // Defaults ON, so Tier C — the caller this was written for — is
        // untouched. The guide fix ladder turns it OFF for its first rung, so
        // that rung matches the Anthropic route's material-only rung and its
        // `cameFromWebSearch: false` is a fact rather than an assumption.
        webSearchEnabled: Bool = true
    ) -> [String] {
        var arguments = ["exec"]
        arguments += requiredFlags
        arguments += ["--sandbox", requiredSandboxMode]
        arguments += ["--cd", workingDirectory]
        // Live web search, the provider's own server-side tool. The local jail
        // is untouched by this: the search runs on OpenAI's side and only its
        // RESULTS come back as text, so the model gains current knowledge
        // without the sandbox gaining network. Tier C is the one place in Iris
        // that had no way to look anything up — the guide fix ladder and chat
        // both do — and a reader asking to integrate an API Iris has never
        // heard of had no path that could possibly succeed.
        //
        // A CONFIG OVERRIDE, NOT `--search`. That flag exists, but only on the
        // top-level `codex` command; `codex exec --search` exits 2 with
        // "unexpected argument". Verified against the CLI rather than its
        // documentation, and `--strict-config` accepts this key while a made-up
        // one (`web_search=true`) is rejected — so the override is real and not
        // being silently ignored.
        if webSearchEnabled {
            arguments += ["-c", "tools.web_search=true"]
        }
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
        YOUR OWN shell or file tools to do the task — the directory you are \
        running in is an empty scratch directory, not the repository being \
        discussed, so any attempt will silently fail. Your entire reply is the \
        deliverable, and it must follow the output format described below \
        exactly.

        You DO have access to the repository, and to the internet. The \
        repository is reached by emitting the command and edit blocks the \
        format below describes: the program runs them for you against the real \
        checkout and gives you the output back. Web search is a normal tool and \
        you may call it whenever current or unfamiliar information would help. \
        Never conclude that you cannot read files, cannot edit files, or have \
        no shell — you can do all three THROUGH THE BLOCKS, and stopping on \
        that basis is a false refusal.
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

    /// The raw `--json` event stream of the most recent turn, for measurement.
    /// Not part of the provider protocol, and never read by the edit loop.
    nonisolated(unsafe) static var eventStreamOfTheMostRecentTurn: String = ""

    /// Every web search the model ran this turn, as the queries it issued.
    ///
    /// Exists to be measured. Giving Tier C a search tool is only half the
    /// change — the half that matters is whether the model REACHES for it when
    /// it should, which no prompt can assert and only observation can settle.
    /// The CLI emits one `item.completed` with `item.type == "web_search"` per
    /// search; the first such item of a turn can carry an empty `query` with
    /// `action.type == "other"`, so the queries are read from `action.queries`
    /// where it is present.
    static func webSearchQueries(inEventStream eventStreamText: String) -> [String] {
        var queries: [String] = []
        for line in eventStreamText.components(separatedBy: .newlines) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  event["type"] as? String == "item.completed",
                  let item = event["item"] as? [String: Any],
                  item["type"] as? String == "web_search" else { continue }
            if let action = item["action"] as? [String: Any],
               let issued = action["queries"] as? [String] {
                queries += issued
            } else if let single = item["query"] as? String, !single.isEmpty {
                queries.append(single)
            }
        }
        return queries
    }

    /// Whether the model searched the web at all this turn.
    static func didSearchTheWeb(inEventStream eventStreamText: String) -> Bool {
        !webSearchQueries(inEventStream: eventStreamText).isEmpty
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
        // Codex's own words, kept for every branch below. A heuristic over
        // human-readable stderr is a guess, and quoting the tool is the only
        // way a reader can tell whether the guess was right — which is exactly
        // what the reader who asked "I have the codex CLI?" never got.
        let trimmedDetail = quotableTail(ofStandardError: standardErrorText)
        if lowercased.contains("not logged in")
            || lowercased.contains("please run `codex login`")
            || lowercased.contains("no credentials")
            || lowercased.contains("unauthorized") {
            return MaintainModelProviderError.noCredential(
                .codexTurnedTheCallDown(codexSaid: trimmedDetail)
            )
        }
        if lowercased.contains("rate limit")
            || lowercased.contains("usage limit")
            || lowercased.contains("quota") {
            return AssistantTransportError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(inStandardError: standardErrorText)
            )
        }
        // THE CLI REFUSED THE ARGUMENT VECTOR IRIS BUILT. Measured against
        // codex-cli 0.149.1: this exits 2 and prints clap's "error: unexpected
        // argument '…' found" over a `Usage: codex exec` block. It is not a
        // credential problem and not a model problem — it is Iris and codex
        // being out of step, which is the likeliest way a reader who genuinely
        // HAS the CLI still cannot use it, and it has exactly one repair. Left
        // in the unrecognised bucket it became "error 0" and told the reader
        // nothing; recognising it is what turns their own screen into an
        // instruction.
        if lowercased.contains("unexpected argument")
            || lowercased.contains("unrecognized subcommand")
            || lowercased.contains("unexpected subcommand") {
            return MaintainModelProviderError.requestFailed(
                "your codex cli wouldn't accept how iris called it, so the two are out of step. "
                    + "update codex (`npm install -g @openai/codex@latest`), or update iris, and try again. "
                    + "codex said: \(trimmedDetail)"
            )
        }
        // Unrecognised. The heuristics above are the only ones worth claiming,
        // so this branch says so plainly and QUOTES codex rather than
        // paraphrasing it — the instruction comes first so it survives a long
        // dump, and the dump comes last because it is evidence, not advice.
        guard !trimmedDetail.isEmpty else {
            return MaintainModelProviderError.requestFailed(
                "codex exec exited \(exitCode) without saying why. try again, and if it keeps "
                    + "happening connect a different model in settings."
            )
        }
        return MaintainModelProviderError.requestFailed(
            "codex couldn't finish that call and iris doesn't recognise why. try again, and if "
                + "it keeps happening connect a different model in settings. codex said: \(trimmedDetail)"
        )
    }

    /// Codex's stderr, trimmed to something a person will actually read.
    ///
    /// This used to be a flat `.suffix(300)`, which was fine while nothing ever
    /// showed it to anyone. Now that it does, both shapes measured against
    /// codex-cli 0.149.1 come out wrong that way: a signed-out run prints the
    /// SAME `401 Unauthorized` line seven times, so the reader got one and a
    /// half of them starting mid-token ("::responses_websocket: failed to…"),
    /// and a refused-argument run's one useful line is its FIRST, which a tail
    /// drops in favour of the `Usage:` block.
    ///
    /// So: whole lines, its own log timestamps dropped so that repeats actually
    /// collapse, and the FIRST few — in both shapes the primary error leads and
    /// everything after it is either a cascade or boilerplate. That is a
    /// heuristic like the rest of this function, and it is stated as one rather
    /// than dressed up as a parse.
    static func quotableTail(ofStandardError standardErrorText: String) -> String {
        var alreadySeen: Set<String> = []
        var distinctLines: [String] = []
        for line in standardErrorText.components(separatedBy: .newlines) {
            let trimmedLine = withoutLeadingLogTimestamp(line.trimmingCharacters(in: .whitespaces))
            guard !trimmedLine.isEmpty, alreadySeen.insert(trimmedLine).inserted else { continue }
            distinctLines.append(String(trimmedLine.prefix(200)))
        }
        return distinctLines.prefix(3).joined(separator: " ")
    }

    /// Drops codex's `2026-08-30T04:53:26.352513Z ` log prefix. Without this the
    /// seven identical 401 lines a signed-out run prints are seven DIFFERENT
    /// strings — they differ only in microseconds — so the de-duplication above
    /// collapses nothing and the reader is quoted the same sentence three times.
    /// A timestamp tells the reader nothing they can use; the sentence does.
    private static func withoutLeadingLogTimestamp(_ line: String) -> String {
        guard let firstSpace = line.firstIndex(of: " ") else { return line }
        let possibleTimestamp = String(line[line.startIndex..<firstSpace])
        let looksLikeATimestamp = possibleTimestamp.count >= 20
            && possibleTimestamp.hasSuffix("Z")
            && possibleTimestamp.contains("T")
            && possibleTimestamp.prefix(4).allSatisfy(\.isNumber)
        guard looksLikeATimestamp else { return line }
        return String(line[line.index(after: firstSpace)...])
            .trimmingCharacters(in: .whitespaces)
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
    let identifier = "codex"

    /// Left nil so the CLI's own default applies — which is what the reader
    /// chose when they installed it, and what `codex` upgrades over time. Iris
    /// pinning a model here would go stale silently.
    private let model: String?

    /// How long one step may take before Iris gives up on it. Generous: a Tier C
    /// step can carry a large context, and a reasoning model can take a while.
    /// The fix loop's own step ceiling is what bounds a run overall.
    private static let stepTimeoutSeconds: TimeInterval = 300

    /// How many times ONE step will re-run a `codex exec` that exited cleanly
    /// but handed back NO assistant message — an empty `--output-last-message`
    /// and no `agent_message` in the event stream — before it gives up and
    /// surfaces the honest failure. A clean exit with no answer is not the model
    /// declining; it is the same shape as a dropped call, and the failure text
    /// the reader would otherwise see literally tells them to "try again". So
    /// Iris tries again ITSELF first, a bounded number of times. Mirrors
    /// `MaintainTierCFixer.maximumTransportDropRetriesPerRun`, which retries the
    /// sibling transient (a dropped model call) for exactly this reason.
    /// `nonisolated` because `runCodexExec` (off the main actor) reads it and a
    /// test asserts on it — the same reason `MaintainTierCFixer`'s own retry
    /// constants are reachable off-actor.
    nonisolated static let maximumEmptyReplyRetriesPerStep = 3

    /// The pause before re-running after an empty reply. Mirrors
    /// `MaintainTierCFixer.transportDropRetryWaitSeconds` — long enough to ride
    /// out a momentary provider blip, short enough that even the full ladder of
    /// retries (three, at five seconds each) stays inside the fix ladder's own
    /// 60s per-rung deadline once the real ~9s round trips are added in.
    nonisolated static let emptyReplyRetryWaitSeconds = 5

    /// Whether this provider's calls may search the web. Always true for Tier C;
    /// the guide fix ladder's first rung sets it false.
    private let webSearchEnabled: Bool

    init(model: String? = nil, webSearchEnabled: Bool = true) {
        self.model = model
        self.webSearchEnabled = webSearchEnabled
    }

    var isAvailable: Bool { CodexCLILogin.currentState().isUsable }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        // Two different problems that used to throw the same opaque case: the
        // command isn't findable, and the command is findable but signed out.
        // The first is often a PATH problem rather than a missing install — a
        // GUI app gets Finder's minimal PATH — so telling a reader "not
        // installed" would have been a lie as well as a dead end.
        guard let codexBinaryPath = CodexCLILogin.locateCodexBinary() else {
            throw MaintainModelProviderError.noCredential(.codexCommandNotFound)
        }
        guard CodexCLILogin.currentState().isUsable else {
            throw MaintainModelProviderError.noCredential(.codexLoginNotUsable)
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
            webSearchEnabled: webSearchEnabled,
            timeoutSeconds: Self.stepTimeoutSeconds
        )
    }

    // MARK: - Running the process

    /// Runs `codex exec` for one step and returns its final assistant turn.
    ///
    /// A thin retry wrapper over `runCodexExecOnce`. A single run that exits
    /// cleanly but hands back NO assistant message is a TRANSIENT empty, not a
    /// permanent failure — the same dropped-call shape the fix loop already
    /// retries — and the failure text the reader would otherwise see literally
    /// tells them to try again. So Iris tries again ITSELF first, a bounded
    /// number of times with a short backoff, and only surfaces that honest
    /// message once the empties KEEP coming. A non-zero exit is a real failure
    /// and is not retried here: it throws straight out of `runCodexExecOnce`,
    /// already mapped by `CodexExecOutput.failure`.
    nonisolated static func runCodexExec(
        codexBinaryPath: String,
        promptText: String,
        attachedImagePNGDataList: [Data],
        model: String?,
        webSearchEnabled: Bool,
        timeoutSeconds: TimeInterval,
        // The pause between empty-reply retries (see
        // `maximumEmptyReplyRetriesPerStep`). Defaults to the real backoff; a
        // test drives it to 0 to exercise the whole retry ladder in
        // milliseconds. It changes only the wait BETWEEN retries, never how many
        // happen, so production behavior is untouched.
        emptyReplyRetryWaitSecondsOverride: Double? = nil
    ) async throws -> String {
        let backoffSeconds = emptyReplyRetryWaitSecondsOverride
            ?? Double(emptyReplyRetryWaitSeconds)
        var emptyReplyRetriesRemaining = maximumEmptyReplyRetriesPerStep
        while true {
            if let assistantMessage = try await runCodexExecOnce(
                codexBinaryPath: codexBinaryPath,
                promptText: promptText,
                attachedImagePNGDataList: attachedImagePNGDataList,
                model: model,
                webSearchEnabled: webSearchEnabled,
                timeoutSeconds: timeoutSeconds
            ) {
                return assistantMessage
            }
            // A clean exit (status 0) with no assistant message: the process ran
            // and simply wrote nothing. Retry it a bounded number of times with
            // a short backoff before surfacing the honest failure.
            guard emptyReplyRetriesRemaining > 0 else {
                throw MaintainModelProviderError.requestFailed(
                    "codex exec produced no assistant message — it ran and exited cleanly without "
                        + "answering. try again, and if it keeps happening connect a different model in settings."
                )
            }
            emptyReplyRetriesRemaining -= 1
            irisTrace(
                "maintain: codex exec exited cleanly with no assistant message, retrying "
                    + "(\(emptyReplyRetriesRemaining) retries left)"
            )
            if backoffSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
            }
        }
    }

    /// Spawns one `codex exec`, feeds it the prompt on stdin, and returns its
    /// final assistant turn — or `nil` when the process exits cleanly (status 0)
    /// but produces no assistant message, which the caller treats as a transient
    /// empty to retry. `nonisolated` so the blocking wait happens off the main
    /// actor — the panel must stay live while a step is in flight.
    nonisolated static func runCodexExecOnce(
        codexBinaryPath: String,
        promptText: String,
        attachedImagePNGDataList: [Data],
        model: String?,
        webSearchEnabled: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> String? {
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
                model: model,
                webSearchEnabled: webSearchEnabled
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
            throw MaintainModelProviderError.requestFailed(
                "iris found the codex command but couldn't start it. reinstall it "
                    + "(`npm install -g @openai/codex`) or reconnect under \"Sign in with Codex\" in "
                    + "settings, then try again. the system said: \(error.localizedDescription)"
            )
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

        // The watchdog ESCALATES, and that escalation is load-bearing. A single
        // `terminate()` (SIGTERM) is not enough: a `codex exec` blocked on a
        // network read, or one that has spawned children, can ignore it — and
        // then `waitUntilExit()` never returns and the whole call hangs forever,
        // which a full-suite run actually hit (a 20-minute hang on a stuck
        // codex). Worse under the empty-reply retry above, which must never sit
        // on top of an unkillable process. So: SIGTERM, a short grace period,
        // then SIGKILL the whole PROCESS GROUP (negative pid) so any children
        // die with it. A killed process comes back with a non-zero
        // terminationStatus, which throws below and is NOT retried — a hang is
        // not a transient empty.
        let watchdog = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard process.isRunning else { return }
            let processIdentifier = process.processIdentifier
            process.terminate()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard process.isRunning else { return }
            // SIGKILL the group; fall back to the single pid if the group send
            // is rejected (e.g. the child changed its own process group).
            if killpg(processIdentifier, SIGKILL) != 0 {
                kill(processIdentifier, SIGKILL)
            }
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
        // Kept so a harness can ask what tools this turn actually used. The
        // provider protocol returns only the assistant's text, and whether the
        // model REACHED for web search is not in the text — it is in the event
        // stream, and it is the thing worth measuring.
        CodexExecOutput.eventStreamOfTheMostRecentTurn = standardOutputText

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
        // Clean exit, nothing written. Report the empty as `nil` and let the
        // caller (`runCodexExec`) decide whether to retry it or surface it — an
        // empty here is a transient, not proof the model refused.
        return nil
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
