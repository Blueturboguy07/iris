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

nonisolated struct CodexExecProcessIdentity: Hashable, Sendable {
    let processIdentifier: pid_t
    let userIdentifier: uid_t
    let processGroupIdentifier: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

/// Pure gate for group-wide signals. Current membership must be complete and
/// every member must still be one of the identities captured from this request.
nonisolated enum CodexExecProcessGroupSignalPolicy {
    static func maySignalOwnedGroup(
        leader: CodexExecProcessIdentity,
        callerProcessGroupIdentifier: pid_t,
        recordedMembers: Set<CodexExecProcessIdentity>,
        currentMembers: [CodexExecProcessIdentity],
        enumerationWasComplete: Bool
    ) -> Bool {
        guard enumerationWasComplete,
              leader.processIdentifier > 0,
              leader.processGroupIdentifier == leader.processIdentifier,
              leader.processGroupIdentifier != callerProcessGroupIdentifier,
              recordedMembers.contains(leader),
              !currentMembers.isEmpty else { return false }
        return currentMembers.allSatisfy {
            $0.processGroupIdentifier == leader.processGroupIdentifier
                && $0.userIdentifier == leader.userIdentifier
                && recordedMembers.contains($0)
        }
    }
}

/// One Codex invocation's process ownership. Darwin proc metadata is used only
/// to signal a verified private process group; uncertainty falls back to the
/// exact, birth-checked leader PID and never to a numeric group guess.
private nonisolated final class CodexExecProcessLifecycle: @unchecked Sendable {
    private struct Snapshot {
        let identity: CodexExecProcessIdentity
        let parentProcessIdentifier: pid_t
    }

    private static let maximumGroupMembers = 128
    private static let maximumAncestryDepth = 32
    private static let escalationDelayNanoseconds: UInt64 = 3_000_000_000

    private let lock = NSLock()
    private let leader: CodexExecProcessIdentity?
    private var recordedMembers = Set<CodexExecProcessIdentity>()
    private var terminationWasRequested = false

    init(processIdentifier: pid_t) {
        leader = Self.snapshot(processIdentifier)?.identity
        if let leader,
           let initialMembers = Self.captureOwnedGroup(leader: leader, callerGroup: getpgrp()) {
            recordedMembers = Set(initialMembers)
        } else if let leader {
            recordedMembers = [leader]
        }
    }

    func observeCurrentOwnedMembers() {
        guard let leader,
              let currentMembers = Self.captureOwnedGroup(leader: leader, callerGroup: getpgrp()) else { return }
        lock.lock()
        recordedMembers.formUnion(currentMembers)
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        guard !terminationWasRequested else {
            lock.unlock()
            return
        }
        terminationWasRequested = true
        lock.unlock()

        guard let leader else { return }
        let callerGroup = getpgrp()
        let captured = Self.captureOwnedGroup(leader: leader, callerGroup: callerGroup)
        if let captured,
           CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
               leader: leader,
               callerProcessGroupIdentifier: callerGroup,
               recordedMembers: Set(captured),
               currentMembers: captured,
               enumerationWasComplete: true
           ),
           killpg(leader.processGroupIdentifier, SIGTERM) == 0 {
            lock.lock()
            recordedMembers.formUnion(captured)
            lock.unlock()
        } else {
            lock.lock()
            if let captured { recordedMembers.formUnion(captured) }
            let membersToSignal = recordedMembers
            lock.unlock()
            for identity in membersToSignal {
                Self.signalIfStillSame(identity, signal: SIGTERM)
            }
        }

        Task.detached { [self] in
            try? await Task.sleep(nanoseconds: Self.escalationDelayNanoseconds)
            escalate()
        }
    }

    private func escalate() {
        lock.lock()
        let recorded = recordedMembers
        lock.unlock()
        guard let leader, !recorded.isEmpty else { return }

        if let current = Self.currentGroupMembers(
               processGroupIdentifier: leader.processGroupIdentifier,
               userIdentifier: leader.userIdentifier
           ),
           CodexExecProcessGroupSignalPolicy.maySignalOwnedGroup(
               leader: leader,
               callerProcessGroupIdentifier: getpgrp(),
               recordedMembers: recorded,
               currentMembers: current,
               enumerationWasComplete: true
           ) {
            _ = killpg(leader.processGroupIdentifier, SIGKILL)
            return
        }

        // A reused group, unknown member, or incomplete census forbids a group
        // signal. Revalidate and signal only exact same-birth PIDs we recorded.
        for identity in recorded {
            Self.signalIfStillSame(identity, signal: SIGKILL)
        }
    }

    private static func signalIfStillSame(_ identity: CodexExecProcessIdentity, signal: Int32) {
        guard let current = snapshot(identity.processIdentifier)?.identity,
              current == identity else { return }
        _ = kill(identity.processIdentifier, signal)
    }

    private static func captureOwnedGroup(
        leader: CodexExecProcessIdentity,
        callerGroup: pid_t
    ) -> [CodexExecProcessIdentity]? {
        guard leader.processGroupIdentifier == leader.processIdentifier,
              leader.processGroupIdentifier != callerGroup,
              snapshot(leader.processIdentifier)?.identity == leader,
              getpgid(leader.processIdentifier) == leader.processGroupIdentifier,
              let pids = processGroupMembers(leader.processGroupIdentifier),
              pids.contains(leader.processIdentifier) else { return nil }

        let members = pids.compactMap(snapshot)
        guard members.count == pids.count,
              members.allSatisfy({
                  $0.identity.processGroupIdentifier == leader.processGroupIdentifier
                      && $0.identity.userIdentifier == leader.userIdentifier
              }),
              members.allSatisfy({ isDescendant($0, of: leader) }) else { return nil }

        // Reject a changing or saturated group census instead of signaling a
        // partial view. The leader must still be the same process at this point.
        guard let confirmedPIDs = processGroupMembers(leader.processGroupIdentifier),
              confirmedPIDs.sorted() == pids.sorted() else { return nil }
        let confirmedMembers = confirmedPIDs.compactMap(snapshot)
        guard confirmedMembers.count == members.count,
              Set(confirmedMembers.map(\.identity)) == Set(members.map(\.identity)),
              snapshot(leader.processIdentifier)?.identity == leader else { return nil }
        return members.map(\.identity)
    }

    private static func isDescendant(_ member: Snapshot, of leader: CodexExecProcessIdentity) -> Bool {
        if member.identity == leader { return true }
        var parent = member.parentProcessIdentifier
        var visited = Set<pid_t>()
        for _ in 0..<maximumAncestryDepth {
            if parent == leader.processIdentifier { return true }
            guard parent > 0, visited.insert(parent).inserted,
                  let ancestor = snapshot(parent),
                  ancestor.identity.userIdentifier == leader.userIdentifier else { return false }
            parent = ancestor.parentProcessIdentifier
        }
        return false
    }

    private static func processGroupMembers(_ processGroupIdentifier: pid_t) -> [pid_t]? {
        var pids = [pid_t](repeating: 0, count: maximumGroupMembers)
        let count = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpgrppids(
                processGroupIdentifier,
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard count > 0, count < Int32(maximumGroupMembers) else { return nil }
        return Array(pids.prefix(Int(count)))
    }

    private static func currentGroupMembers(
        processGroupIdentifier: pid_t,
        userIdentifier: uid_t
    ) -> [CodexExecProcessIdentity]? {
        guard let pids = processGroupMembers(processGroupIdentifier) else { return nil }
        let members = pids.compactMap(snapshot).map(\.identity)
        guard members.count == pids.count,
              members.allSatisfy({
                  $0.processGroupIdentifier == processGroupIdentifier
                      && $0.userIdentifier == userIdentifier
              }) else { return nil }
        return members
    }

    private static func snapshot(_ processIdentifier: pid_t) -> Snapshot? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let byteCount = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            byteCount
        )
        guard result == byteCount,
              info.pbi_pid == UInt32(processIdentifier) else { return nil }
        return Snapshot(
            identity: CodexExecProcessIdentity(
                processIdentifier: processIdentifier,
                userIdentifier: info.pbi_uid,
                processGroupIdentifier: pid_t(info.pbi_pgid),
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            parentProcessIdentifier: pid_t(info.pbi_ppid)
        )
    }
}

/// Cancellation owned by one foreground Codex chat request. Edit calls omit
/// this token and retain their existing process lifecycle.
final class CodexExecCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var ownedProcess: Process?
    private var lifecycle: CodexExecProcessLifecycle?

    func throwIfCancelled() throws {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
    }

    func register(_ process: Process) -> Bool {
        let processLifecycle = CodexExecProcessLifecycle(processIdentifier: process.processIdentifier)
        lock.lock()
        ownedProcess = process
        lifecycle = processLifecycle
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { processLifecycle.terminate() }
        return !wasCancelled
    }

    func unregister(_ process: Process) {
        lock.lock()
        if ownedProcess === process {
            ownedProcess = nil
            lifecycle = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let processLifecycle = lifecycle
        lock.unlock()
        processLifecycle?.terminate()
    }

    func terminateForTimeout(_ process: Process) {
        lock.lock()
        let processLifecycle = ownedProcess === process ? lifecycle : nil
        lock.unlock()
        processLifecycle?.terminate()
    }

    func observeCurrentOwnedMembers(_ process: Process) {
        lock.lock()
        let processLifecycle = ownedProcess === process ? lifecycle : nil
        lock.unlock()
        processLifecycle?.observeCurrentOwnedMembers()
    }
}

/// Fails closed for screen-help so every image named in the prompt is actually
/// delivered. The edit route retains its existing best-effort default.
nonisolated enum CodexExecImageStager {
    static func stage(
        _ imageDataList: [Data],
        in directory: URL,
        requireAllImages: Bool,
        write: (Data, URL) throws -> Void = { data, url in try data.write(to: url) }
    ) throws -> [String] {
        var paths: [String] = []
        for (index, data) in imageDataList.enumerated() {
            let imageURL = directory.appendingPathComponent("attachment-\(index).png")
            do {
                try write(data, imageURL)
                paths.append(imageURL.path)
            } catch {
                guard requireAllImages else { continue }
                throw MaintainModelProviderError.requestFailed(
                    "Iris could not prepare every screenshot for Codex screen help, so no request was sent. Try again."
                )
            }
        }
        return paths
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
        cancellation: CodexExecCancellation? = nil,
        requireAllImages: Bool = false,
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
            try cancellation?.throwIfCancelled()
            if let assistantMessage = try await runCodexExecOnce(
                codexBinaryPath: codexBinaryPath,
                promptText: promptText,
                attachedImagePNGDataList: attachedImagePNGDataList,
                model: model,
                webSearchEnabled: webSearchEnabled,
                timeoutSeconds: timeoutSeconds,
                cancellation: cancellation,
                requireAllImages: requireAllImages
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
                if cancellation == nil {
                    try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                } else {
                    try await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))
                }
            }
            try cancellation?.throwIfCancelled()
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
        cancellation: CodexExecCancellation? = nil,
        requireAllImages: Bool = false
    ) async throws -> String? {
        try cancellation?.throwIfCancelled()
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

        let attachedImagePaths = try CodexExecImageStager.stage(
            attachedImagePNGDataList,
            in: scratchDirectoryURL,
            requireAllImages: requireAllImages
        )

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
            try cancellation?.throwIfCancelled()
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
        let cancellationAllowsRequest = cancellation?.register(process) ?? true
        defer { cancellation?.unregister(process) }

        let outputCollector = PipeCollector(
            fileHandle: standardOutputPipe.fileHandleForReading,
            timeoutSeconds: timeoutSeconds,
            onTimeout: { cancellation?.terminateForTimeout(process) },
            onActivity: { cancellation?.observeCurrentOwnedMembers(process) }
        )
        let errorCollector = PipeCollector(
            fileHandle: standardErrorPipe.fileHandleForReading,
            timeoutSeconds: timeoutSeconds,
            onTimeout: { cancellation?.terminateForTimeout(process) },
            onActivity: { cancellation?.observeCurrentOwnedMembers(process) }
        )

        async let stdoutRead = outputCollector.collectText()
        async let stderrRead = errorCollector.collectText()

        if !cancellationAllowsRequest {
            await waitUntilExitOffMainQueue(process)
            _ = try? await stdoutRead
            _ = try? await stderrRead
            throw CancellationError()
        }

        // Feed the prompt and close stdin so the CLI stops waiting for more.
        if let promptData = promptText.data(using: .utf8) {
            standardInputPipe.fileHandleForWriting.write(promptData)
        }
        try? standardInputPipe.fileHandleForWriting.close()
        cancellation?.observeCurrentOwnedMembers(process)

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
            if let cancellation {
                cancellation.terminateForTimeout(process)
            } else {
                guard process.isRunning else { return }
                let processIdentifier = process.processIdentifier
                process.terminate()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard process.isRunning else { return }
                // Edit calls retain their established timeout behavior. Chat
                // calls use the identity-checked invocation lifecycle above.
                if killpg(processIdentifier, SIGKILL) != 0 {
                    kill(processIdentifier, SIGKILL)
                }
            }
        }
        await waitUntilExitOffMainQueue(process)
        defer {
            watchdog.cancel()
        }
        try cancellation?.throwIfCancelled()

        let (standardOutputText, standardErrorText) = try await (stdoutRead, stderrRead)
        try cancellation?.throwIfCancelled()
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

    private nonisolated static func waitUntilExitOffMainQueue(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

// MARK: - Pipe draining

/// Drains one pipe asynchronously on a private queue. A descendant can inherit
/// its write descriptor after the owned child exits, so EOF has its own finite
/// bound. Concurrent stdout/stderr collectors prevent either pipe filling up.
private nonisolated final class PipeCollector: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "iris.codex.pipe-drain", qos: .utility)
    private var source: DispatchSourceRead?
    private var timeoutSource: DispatchSourceTimer?
    private var collectedData = Data()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var hasStartedCollecting = false
    private var hasObservedActivity = false

    private let onTimeout: (() -> Void)?
    private let onActivity: (() -> Void)?

    init(
        fileHandle: FileHandle,
        timeoutSeconds: TimeInterval,
        onTimeout: (() -> Void)? = nil,
        onActivity: (() -> Void)? = nil
    ) {
        self.fileHandle = fileHandle
        self.onTimeout = onTimeout
        self.onActivity = onActivity
        let readSource = DispatchSource.makeReadSource(
            fileDescriptor: fileHandle.fileDescriptor,
            queue: queue
        )
        source = readSource
        readSource.setEventHandler { [weak self] in self?.readAvailableBytes() }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timeoutSource = timer
        timer.setEventHandler { [weak self] in
            self?.onTimeout?()
            self?.finish(.failure(MaintainModelProviderError.requestFailed(
                "codex exec output pipes did not close within the per-attempt deadline; no partial response was used."
            )))
        }
        timer.schedule(deadline: .now() + max(0, timeoutSeconds))
        readSource.resume()
        timer.resume()
    }

    func collectText() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.hasStartedCollecting else {
                        continuation.resume(throwing: MaintainModelProviderError.requestFailed(
                            "codex exec output was collected more than once."
                        ))
                        return
                    }
                    self.hasStartedCollecting = true
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func readAvailableBytes() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(fileHandle.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            collectedData.append(contentsOf: buffer.prefix(count))
            if !hasObservedActivity {
                hasObservedActivity = true
                onActivity?()
            }
            return
        }
        if count == 0 {
            finish(.success(String(data: collectedData, encoding: .utf8) ?? ""))
            return
        }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return }
        finish(.failure(MaintainModelProviderError.requestFailed(
            "codex exec could not read its output pipe (errno \(errno)); no partial response was used."
        )))
    }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        if let source {
            // The cancel handler owns close so queued read events cannot observe
            // an fd that has already been reused for another resource.
            source.setEventHandler {}
            source.setCancelHandler { [fileHandle] in try? fileHandle.close() }
            source.cancel()
        } else {
            try? fileHandle.close()
        }
        source = nil
        timeoutSource?.setEventHandler {}
        timeoutSource?.cancel()
        timeoutSource = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
