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
import Darwin

/// The reasoning levels understood by the current Codex CLI model catalog.
/// These values are passed through the CLI config override rather than stored
/// in the user's config file.
nonisolated enum CodexReasoningEffort: String, CaseIterable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max
    case ultra

    static let configKey = "model_reasoning_effort"

    var configOverride: String {
        "\(Self.configKey)=\"\(rawValue)\""
    }
}

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
        case invalidModelIdentifier
        case invalidReasoningEffort
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
        reasoningEffort: CodexReasoningEffort? = nil,
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
        if let reasoningEffort {
            arguments += ["-c", reasoningEffort.configOverride]
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
        if let modelIndex = candidateArguments.firstIndex(of: "--model") {
            guard candidateArguments.indices.contains(modelIndex + 1),
                  CodexEditModelSelection.isValidIdentifier(candidateArguments[modelIndex + 1]) else {
                throw ValidationError.invalidModelIdentifier
            }
        }
        for argument in candidateArguments where argument.hasPrefix(forbiddenFlagPrefix) {
            throw ValidationError.carriesADangerousBypass(flag: argument)
        }
        for (index, argument) in candidateArguments.enumerated()
        where argument == "-c" || argument == "--config" {
            guard candidateArguments.indices.contains(index + 1) else { continue }
            let configOverride = candidateArguments[index + 1]
            let prefix = "\(CodexReasoningEffort.configKey)="
            guard configOverride.hasPrefix(prefix) else { continue }
            let rawEffort = String(configOverride.dropFirst(prefix.count))
            let unquotedEffort: String
            if rawEffort.count >= 2,
               ((rawEffort.first == "\"" && rawEffort.last == "\"")
                || (rawEffort.first == "'" && rawEffort.last == "'")) {
                unquotedEffort = String(rawEffort.dropFirst().dropLast())
            } else {
                unquotedEffort = rawEffort
            }
            guard CodexReasoningEffort(rawValue: unquotedEffort) != nil else {
                throw ValidationError.invalidReasoningEffort
            }
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
    static func promptText(systemPrompt: String, conversation: [MaintainChatTurn],
                           webSearchEnabled: Bool = true) -> String {
        let offlineFraming = """
        You are a text model inside another program. Your reply is the deliverable;
        follow the output format below exactly. Do not use your own shell or file
        tools: your working directory is an empty scratch directory, not the project.
        Read and edit the project through the command and edit blocks described below;
        the program executes those blocks and returns their results. Web search is
        disabled for this call. Do not claim to have searched or accessed the internet.
        """
        var sections: [String] = [webSearchEnabled ? framingPreamble : offlineFraming, systemPrompt]
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
    struct Usage: Equatable, Sendable {
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?
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
                inputTokens: usage["input_tokens"] as? Int,
                cachedInputTokens: usage["cached_input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                reasoningOutputTokens: usage["reasoning_output_tokens"] as? Int
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

/// The identity and requested route for one admitted Codex process attempt.
nonisolated struct CodexProcessAttemptContext: Equatable, Sendable {
    let attemptID: UUID
    let model: String?
    let reasoningEffort: CodexReasoningEffort?
}

/// The bounded lifecycle result reported after one Codex process attempt.
nonisolated struct CodexProcessAttemptResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case succeeded
        case emptyReply
        case failed
        case cancelled
    }

    let context: CodexProcessAttemptContext
    let outcome: Outcome
    let usage: CodexExecOutput.Usage?
}

/// Optional hooks for an external run ledger. The admission hook runs before a
/// process is spawned and may reject the attempt. The completion hook receives
/// every admitted attempt, including an empty reply or cancellation.
nonisolated struct CodexProcessAttemptObserver: Sendable {
    let beforeAttempt: (@Sendable (CodexProcessAttemptContext) async throws -> Void)?
    let afterAttempt: (@Sendable (CodexProcessAttemptResult) async -> Void)?

    init(
        beforeAttempt: (@Sendable (CodexProcessAttemptContext) async throws -> Void)? = nil,
        afterAttempt: (@Sendable (CodexProcessAttemptResult) async -> Void)? = nil
    ) {
        self.beforeAttempt = beforeAttempt
        self.afterAttempt = afterAttempt
    }
}

private nonisolated struct CodexExecAttemptOutput: Sendable {
    let assistantMessage: String?
    let usage: CodexExecOutput.Usage?
}

private nonisolated final class CodexProcessCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationWasRequested = false

    func attach(_ process: Process) {
        lock.lock()
        if cancellationWasRequested {
            lock.unlock()
            Self.terminate(process)
            return
        }
        self.process = process
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationWasRequested = true
        let process = self.process
        lock.unlock()
        if let process {
            Self.terminate(process)
        }
    }

    /// Ends the process and its group without waiting for Foundation to reap it.
    /// The group kill also closes inherited pipe descriptors held by descendants.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let processIdentifier = process.processIdentifier
        guard processIdentifier > 0 else { return }
        if killpg(processIdentifier, SIGKILL) != 0 {
            kill(processIdentifier, SIGKILL)
        }
    }
}

private enum CodexProcessTerminationWaitError: Error {
    case deadlineExceeded
}

/// Waits for Foundation's termination callback instead of blocking on
/// `Process.waitUntilExit()`. The latter can remain blocked after the child has
/// exited, which leaves the provider stuck even when its output file is complete.
/// A deadline is kept outside the process so cancellation and a missing callback
/// both have a bounded completion path.
private nonisolated final class CodexProcessTerminationWaiter: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var hasFinished = false
    private var cancellationWasRequested = false
    private var isArmed = false

    init(process: Process) {
        self.process = process
    }

    /// Installs the termination callback and deadline before any synchronous
    /// stdin write. A large write can itself wait for the child to read, so the
    /// process must already have a cancellation and timeout path at that point.
    func arm(timeoutSeconds: TimeInterval) {
        lock.lock()
        guard !isArmed, !hasFinished else {
            lock.unlock()
            return
        }
        isArmed = true
        lock.unlock()

        process.terminationHandler = { [weak self] _ in
            self?.processDidTerminate()
        }

        // The handler may be installed after a very short-lived process exits.
        // Check the state as well so completion does not depend on callback
        // delivery timing.
        if !process.isRunning {
            finish(.success(()))
            return
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.deadlineDidExpire()
        }
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        self.timeoutWorkItem = timeoutWorkItem
        lock.unlock()

        let boundedMilliseconds = max(
            0,
            min(timeoutSeconds * 1_000, Double(Int.max))
        )
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(Int(boundedMilliseconds)),
            execute: timeoutWorkItem
        )
    }

    func wait() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                resume(pendingResult, with: continuation)
                return
            }
            if cancellationWasRequested || hasFinished {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancellationWasRequested = true
        guard !hasFinished else {
            lock.unlock()
            return
        }
        let continuation = self.continuation
        self.continuation = nil
        hasFinished = true
        if continuation == nil {
            pendingResult = .failure(CancellationError())
        }
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        CodexProcessCancellationHandle.terminate(process)
        continuation?.resume(throwing: CancellationError())
    }

    private func processDidTerminate() {
        finish(.success(()))
    }

    private func deadlineDidExpire() {
        lock.lock()
        let shouldFinish = !hasFinished
        lock.unlock()
        guard shouldFinish else { return }

        // Force-close the process group before resuming. Detached pipe readers
        // otherwise can remain blocked on descriptors inherited by a child.
        CodexProcessCancellationHandle.terminate(process)
        finish(.failure(CodexProcessTerminationWaitError.deadlineExceeded))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil {
            pendingResult = result
        }
        let timeoutWorkItem = self.timeoutWorkItem
        self.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        guard let continuation else { return }
        resume(result, with: continuation)
    }

    private func resume(
        _ result: Result<Void, Error>,
        with continuation: CheckedContinuation<Void, Error>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - The provider

@MainActor
final class CodexMaintainProvider: MaintainModelProviding {
    let displayName = "Codex (your ChatGPT login)"
    let identifier = "codex"
    var requestedModelDescription: String { CodexEditModelSelection.requestedModelLabel(model) }

    /// Captured at provider creation for this run. Nil uses the CLI's built-in
    /// default, not config.toml, because the isolation policy ignores user config.
    private let model: String?
    private let reasoningEffort: CodexReasoningEffort?
    private let attemptObserver: CodexProcessAttemptObserver?
    private let maximumEmptyReplyRetriesOverride: Int?

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

    init(
        model: String? = nil,
        reasoningEffort: CodexReasoningEffort? = nil,
        webSearchEnabled: Bool = true,
        attemptObserver: CodexProcessAttemptObserver? = nil,
        maximumEmptyReplyRetriesOverride: Int? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.webSearchEnabled = webSearchEnabled
        self.attemptObserver = attemptObserver
        self.maximumEmptyReplyRetriesOverride = maximumEmptyReplyRetriesOverride
    }

    var isAvailable: Bool { CodexCLILogin.currentState().isUsable }

    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String {
        if let model, !CodexEditModelSelection.isValidIdentifier(model) {
            throw MaintainModelProviderError.requestFailed(
                "The saved Codex model ID is invalid. Choose a model or Codex default in the project composer."
            )
        }
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
            systemPrompt: systemPrompt, conversation: conversation, webSearchEnabled: webSearchEnabled
        )
        let attachedImages = conversation.compactMap { $0.attachedImagePNGData }

        return try await Self.runCodexExec(
            codexBinaryPath: codexBinaryPath,
            promptText: promptText,
            attachedImagePNGDataList: attachedImages,
            model: model,
            webSearchEnabled: webSearchEnabled,
            timeoutSeconds: Self.stepTimeoutSeconds,
            reasoningEffort: reasoningEffort,
            maximumEmptyReplyRetriesOverride: maximumEmptyReplyRetriesOverride,
            attemptObserver: attemptObserver
        )
    }

    // MARK: - Running the process

    nonisolated private static func reportAttemptCompletion(
        context: CodexProcessAttemptContext,
        outcome: CodexProcessAttemptResult.Outcome,
        usage: CodexExecOutput.Usage?,
        observer: CodexProcessAttemptObserver?
    ) async {
        guard let afterAttempt = observer?.afterAttempt else { return }
        await afterAttempt(CodexProcessAttemptResult(
            context: context, outcome: outcome, usage: usage
        ))
    }

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
        reasoningEffort: CodexReasoningEffort? = nil,
        // The pause between empty-reply retries (see
        // `maximumEmptyReplyRetriesPerStep`). Defaults to the real backoff; a
        // test drives it to 0 to exercise the whole retry ladder in
        // milliseconds. It changes only the wait BETWEEN retries, never how many
        // happen, so production behavior is untouched.
        emptyReplyRetryWaitSecondsOverride: Double? = nil,
        // Harness callers can set this to 0 when their outer ledger owns the
        // retry budget. Nil preserves the production retry ladder.
        maximumEmptyReplyRetriesOverride: Int? = nil,
        attemptObserver: CodexProcessAttemptObserver? = nil
    ) async throws -> String {
        let maximumEmptyReplyRetries = maximumEmptyReplyRetriesOverride
            ?? Self.maximumEmptyReplyRetriesPerStep
        guard maximumEmptyReplyRetries >= 0 else {
            throw MaintainModelProviderError.requestFailed(
                "codex exec retry budget must not be negative."
            )
        }
        let backoffSeconds = emptyReplyRetryWaitSecondsOverride
            ?? Double(emptyReplyRetryWaitSeconds)
        var emptyReplyRetriesRemaining = maximumEmptyReplyRetries
        while true {
            try Task.checkCancellation()
            let attemptContext = CodexProcessAttemptContext(
                attemptID: UUID(), model: model, reasoningEffort: reasoningEffort
            )
            if let beforeAttempt = attemptObserver?.beforeAttempt {
                try await beforeAttempt(attemptContext)
            }

            let attemptOutput: CodexExecAttemptOutput
            do {
                try Task.checkCancellation()
                attemptOutput = try await runCodexExecOnceWithUsage(
                    codexBinaryPath: codexBinaryPath,
                    promptText: promptText,
                    attachedImagePNGDataList: attachedImagePNGDataList,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    webSearchEnabled: webSearchEnabled,
                    timeoutSeconds: timeoutSeconds
                )
            } catch is CancellationError {
                await reportAttemptCompletion(
                    context: attemptContext,
                    outcome: .cancelled,
                    usage: nil,
                    observer: attemptObserver
                )
                throw CancellationError()
            } catch {
                await reportAttemptCompletion(
                    context: attemptContext,
                    outcome: .failed,
                    usage: nil,
                    observer: attemptObserver
                )
                throw error
            }

            if let assistantMessage = attemptOutput.assistantMessage {
                await reportAttemptCompletion(
                    context: attemptContext,
                    outcome: .succeeded,
                    usage: attemptOutput.usage,
                    observer: attemptObserver
                )
                return assistantMessage
            }
            await reportAttemptCompletion(
                context: attemptContext,
                outcome: .emptyReply,
                usage: attemptOutput.usage,
                observer: attemptObserver
            )
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
            try Task.checkCancellation()
            if backoffSeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
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
        timeoutSeconds: TimeInterval,
        reasoningEffort: CodexReasoningEffort? = nil
    ) async throws -> String? {
        let attemptOutput = try await runCodexExecOnceWithUsage(
            codexBinaryPath: codexBinaryPath,
            promptText: promptText,
            attachedImagePNGDataList: attachedImagePNGDataList,
            model: model,
            reasoningEffort: reasoningEffort,
            webSearchEnabled: webSearchEnabled,
            timeoutSeconds: timeoutSeconds
        )
        return attemptOutput.assistantMessage
    }

    private nonisolated static func runCodexExecOnceWithUsage(
        codexBinaryPath: String,
        promptText: String,
        attachedImagePNGDataList: [Data],
        model: String?,
        reasoningEffort: CodexReasoningEffort?,
        webSearchEnabled: Bool,
        timeoutSeconds: TimeInterval
    ) async throws -> CodexExecAttemptOutput {
        try Task.checkCancellation()
        // A scratch directory per call: it is the agent's working root, and it
        // is deliberately EMPTY and outside any repo, so even a read-only shell
        // has nothing of the reader's to look at.
#if IRIS_HARNESS_HEADLESS
        let temporaryRoot = HarnessFixtureEnvironment.scratchDirectory
#else
        let temporaryRoot = FileManager.default.temporaryDirectory
#endif
        let scratchDirectoryURL = temporaryRoot
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
                reasoningEffort: reasoningEffort,
                webSearchEnabled: webSearchEnabled
            )
        )

        let process = Process()
        // Own one process group in both the normal app and fixture host. The
        // CLI can exit before a helper closes inherited output pipes.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0,0) or die 'process group failed'; exec @ARGV; die 'exec failed';",
            "--", codexBinaryPath] + arguments
#if IRIS_HARNESS_HEADLESS
        // Model transport needs its backend connection, but its own read-only
        // shell must not inspect the lab's held-out fixture answers.
        let boundaryProfile = scratchDirectoryURL.appendingPathComponent("fixture-read-boundary.sb")
        try ("(version 1)\n(allow default)\n" + HarnessFixtureEnvironment.sourceReadDenial)
            .write(to: boundaryProfile, atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0,0) or die 'process group failed'; exec @ARGV; die 'exec failed';",
            "--", "/usr/bin/sandbox-exec", "-f", boundaryProfile.path, codexBinaryPath] + arguments
#endif
        process.environment = CodexCLILogin.environmentForCodex()
        process.currentDirectoryURL = scratchDirectoryURL

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        let cancellationHandle = CodexProcessCancellationHandle()
        let terminationWaiter = CodexProcessTerminationWaiter(process: process)
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                guard FileManager.default.isExecutableFile(atPath: codexBinaryPath) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                try process.run()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MaintainModelProviderError.requestFailed(
                    "iris found the codex command but couldn't start it. reinstall it "
                        + "(`npm install -g @openai/codex`) or reconnect under \"Sign in with Codex\" in "
                        + "settings, then try again. the system said: \(error.localizedDescription)"
                )
            }
            cancellationHandle.attach(process)
            // Also close helpers on cancellation, timeout or another thrown
            // error, before the call's scratch directory is removed.
            defer { killpg(process.processIdentifier, SIGKILL) }
            try Task.checkCancellation()

            // Drain both pipes on their own threads. A `codex exec --json` run can
            // emit more than a pipe buffer holds, and a full pipe would deadlock the
            // child against a parent that is only waiting on exit.
            let outputCollector = PipeCollector(fileHandle: standardOutputPipe.fileHandleForReading)
            let errorCollector = PipeCollector(fileHandle: standardErrorPipe.fileHandleForReading)
            defer {
                outputCollector.stopReading()
                errorCollector.stopReading()
                try? standardInputPipe.fileHandleForWriting.close()
            }

            // Start draining output and arm cancellation before sending a large
            // prompt. A child may write startup output before it reads stdin;
            // feeding first can leave both ends waiting on full pipes.
            terminationWaiter.arm(timeoutSeconds: timeoutSeconds)
            let inputComplete = try await sendPrompt(Data(promptText.utf8),
                to: standardInputPipe.fileHandleForWriting, process: process)
            try? standardInputPipe.fileHandleForWriting.close()

            do {
                try await terminationWaiter.wait()
            } catch CodexProcessTerminationWaitError.deadlineExceeded {
                throw MaintainModelProviderError.requestFailed(
                    "codex exec exceeded its time limit. try again, and if it keeps happening "
                        + "connect a different model in settings."
                )
            }
            // The wrapper owns this group. Close descendants before draining
            // their inherited pipes or deleting their scratch directory.
            killpg(process.processIdentifier, SIGKILL)
            try Task.checkCancellation()

            let standardOutputText = try outputCollector.collectedText()
            let standardErrorText = try errorCollector.collectedText()
            // Kept so a harness can ask what tools this turn actually used. The
            // provider protocol returns only the assistant's text. Whether the
            // model REACHED for web search is not in the text. It is in the
            // event stream, and it is the thing worth measuring.
            CodexExecOutput.eventStreamOfTheMostRecentTurn = standardOutputText
            let usage = CodexExecOutput.usage(fromJSONL: standardOutputText)

            if process.terminationStatus != 0 {
                throw CodexExecOutput.failure(
                    fromStandardError: standardErrorText.isEmpty ? standardOutputText : standardErrorText,
                    exitCode: process.terminationStatus
                )
            }
            guard inputComplete else {
                throw MaintainModelProviderError.requestFailed("codex closed its input before receiving the full request. try again.")
            }

            // The written file first; the event stream as the fallback.
            if let finalMessage = try? String(contentsOf: finalMessageURL, encoding: .utf8),
               !finalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CodexExecAttemptOutput(assistantMessage: finalMessage, usage: usage)
            }
            if let recoveredMessage = CodexExecOutput.finalAssistantText(fromJSONL: standardOutputText),
               !recoveredMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return CodexExecAttemptOutput(assistantMessage: recoveredMessage, usage: usage)
            }
            // Clean exit, nothing written. The caller decides whether to retry.
            return CodexExecAttemptOutput(assistantMessage: nil, usage: usage)
        }, onCancel: {
            cancellationHandle.cancel()
            terminationWaiter.cancel()
        })
    }

    /// A stalled reader must not block cancellation or crash Iris with SIGPIPE.
    /// These flags affect only this call's pipe, never process-wide signals.
    private nonisolated static func sendPrompt(
        _ data: Data, to handle: FileHandle, process: Process
    ) async throws -> Bool {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            throw MaintainModelProviderError.requestFailed("iris couldn't prepare the codex input pipe. try again.")
        }
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            guard process.isRunning else { return false }
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
            }
            if count > 0 { offset += count; continue }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EPIPE { return false }
            guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                throw MaintainModelProviderError.requestFailed("iris couldn't send the request to codex. try again.")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
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
    private var stopped = false
    private let finishedReading = DispatchSemaphore(value: 0)

    init(fileHandle: FileHandle) {
        Thread.detachNewThread { [self] in
            defer {
                try? fileHandle.close()
                finishedReading.signal()
            }
            let fd = fileHandle.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                lock.lock()
                let shouldStop = stopped
                lock.unlock()
                if shouldStop { return }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    lock.lock()
                    collectedData.append(contentsOf: buffer.prefix(count))
                    lock.unlock()
                } else if count == 0 { return }
                else if errno == EINTR { continue }
                else if errno == EAGAIN || errno == EWOULDBLOCK { usleep(10_000) }
                else { return }
            }
        }
    }

    func stopReading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func collectedText() throws -> String {
        guard finishedReading.wait(timeout: .now() + 1) == .success else {
            stopReading()
            throw MaintainModelProviderError.requestFailed("codex exited but a helper kept its output open. try again.")
        }
        lock.lock()
        defer { lock.unlock() }
        return String(data: collectedData, encoding: .utf8) ?? ""
    }
}
