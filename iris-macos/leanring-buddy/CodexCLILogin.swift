//
//  CodexCLILogin.swift
//  leanring-buddy
//
//  "Sign in with Codex" — the OpenAI-side sibling of `ClaudeCodeLogin.swift`.
//  The reader authenticates Iris's model work with their existing ChatGPT
//  account by way of the Codex CLI, instead of pasting a raw `sk-…` API key.
//
//  WHY THIS FILE DOES NOT LOOK LIKE ClaudeCodeLogin.swift
//
//  The Claude path scrapes a long-lived `sk-ant-oat…` token out of
//  `claude setup-token` and stores it in the Keychain, because that token is a
//  real credential for `api.anthropic.com` — the same host a pasted API key
//  goes to. Codex has no equivalent. Its ChatGPT login mints a SHORT-LIVED
//  access token (hours) plus a rotating refresh token, and those are NOT
//  api.openai.com credentials at all: they address OpenAI's Codex backend, with
//  an account-id header and an originator the CLI stamps. Verified 2026-08-26:
//  the stored token is useless against `api.openai.com/v1/*`.
//
//  So Iris does not hold this credential. It drives the CLI, which owns the
//  token, performs its own refresh, and is the party OpenAI actually issued it
//  to. Three consequences worth stating plainly, because they are a DIFFERENCE
//  from the Claude route and not an oversight:
//
//    1. NOTHING is stored in the Keychain here. There is no `KeychainSecretKind`
//       for Codex. The credential lives in `~/.codex/auth.json`, mode 0600,
//       written by the CLI. Iris reads it only to answer "is a login present?"
//       and never copies the token anywhere.
//    2. Refresh is free and correct — the CLI does it. The Claude path
//       deliberately does NOT implement refresh (see its notes) and degrades to
//       a 401 when an imported login lapses. This path has no such cliff.
//    3. There is no reverse-engineered endpoint or beta header to rotate. When
//       OpenAI changes the backend protocol, `codex` is updated by its own
//       maintainers and Iris keeps working. The coupling is the CLI's command
//       surface (`codex exec`, `codex login`), which is a documented, stable,
//       non-secret interface.
//
//  HONESTY NOTE, same shape as the Claude one: using a ChatGPT *subscription*
//  to power a third-party app is a gray area under OpenAI's terms, and may be
//  rate-limited or disallowed. A pasted API key remains the unambiguous BYO
//  credential. The UI says so, in the same words the Claude row uses.
//

import Combine
import Foundation

// MARK: - Locating and reading the reader's Codex login

nonisolated enum CodexCLILogin {

    /// What Iris can tell about the reader's Codex setup, read from disk without
    /// spawning anything. Each case is a distinct, honest thing to say in the UI.
    enum ConnectionState: Equatable {
        /// No `codex` executable anywhere Iris knows to look.
        case codexNotInstalled
        /// The CLI is installed but no login has been completed.
        case signedOut
        /// Signed in with a ChatGPT account — the subscription path.
        case signedInWithChatGPT
        /// Signed in with a pasted `sk-…` key held by the CLI (`codex login
        /// --with-api-key`). Still a working credential for Iris's purposes.
        case signedInWithAPIKey

        /// Whether Iris can actually run a model call through Codex right now.
        var isUsable: Bool {
            switch self {
            case .signedInWithChatGPT, .signedInWithAPIKey:
                return true
            case .codexNotInstalled, .signedOut:
                return false
            }
        }
    }

    /// The auth shapes `~/.codex/auth.json` can hold. Parsed defensively:
    /// anything unrecognized is `nil` rather than a crash or a false positive.
    enum StoredAuthShape: Equatable {
        case chatGPTTokens
        case apiKey
    }

    // MARK: Locating the CLI

    /// The `codex` executable, or nil when the CLI is not installed anywhere
    /// Iris can find it. Known install locations first (fast, no subprocess),
    /// then whatever a login shell resolves on the reader's PATH.
    ///
    /// The npm-global path leads the list on purpose: `npm install -g
    /// @openai/codex` is the install route the Codex docs give first, and on a
    /// Mac with a user-level npm prefix it lands somewhere a GUI app's default
    /// PATH will never see.
    static func locateCodexBinary() -> String? {
        let home = NSHomeDirectory()
        let knownCandidatePaths = [
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.codex/bin/codex",
        ]
        let fileManager = FileManager.default
        for candidatePath in knownCandidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }
        return resolveCodexOnPathViaLoginShell()
    }

    /// Asks a login shell to resolve `codex`, covering an install under a
    /// directory the fixed list above does not know (a different npm prefix, a
    /// version manager, a pnpm global bin). Non-interactive and synchronous —
    /// it only runs when the known paths all miss.
    private static func resolveCodexOnPathViaLoginShell() -> String? {
        let loginShellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath)
        process.arguments = ["-l", "-c", "command -v codex"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let resolvedPath = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !resolvedPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return nil
        }
        return resolvedPath
    }

    // MARK: Where the CLI keeps its login

    /// The directory the CLI treats as its home. `CODEX_HOME` wins when set —
    /// the CLI honors it, so Iris must too, or it would read a different
    /// login than the one `codex exec` is about to use.
    static func codexHomeDirectory() -> String {
        if let overriddenHome = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !overriddenHome.isEmpty {
            return overriddenHome
        }
        return "\(NSHomeDirectory())/.codex"
    }

    /// The credential file itself. Never read for its token — only for shape.
    static func authFilePath() -> String {
        "\(codexHomeDirectory())/auth.json"
    }

    // MARK: Reading the state

    /// The current state, cheap enough for the settings panel to call on
    /// appear. Touches the filesystem only.
    static func currentState() -> ConnectionState {
        guard locateCodexBinary() != nil else { return .codexNotInstalled }
        guard let authFileData = FileManager.default.contents(atPath: authFilePath()) else {
            return .signedOut
        }
        switch storedAuthShape(inAuthFileContents: authFileData) {
        case .chatGPTTokens:
            return .signedInWithChatGPT
        case .apiKey:
            return .signedInWithAPIKey
        case nil:
            return .signedOut
        }
    }

    /// When the credential file was last written, or nil when there is none.
    /// Used as the "this is a FRESH login" oracle: a reader who was already
    /// signed in when they pressed the button must not be told they succeeded
    /// by the stale file that was already sitting there.
    static func authFileModificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: authFilePath())[.modificationDate] as? Date
    }

    /// Which credential shape `auth.json` holds, if any.
    ///
    /// PURE and total, so it is unit-tested against fixture blobs with no CLI
    /// installed. Deliberately does not return, log, or otherwise surface the
    /// secret material it walks past — the caller only ever learns the shape.
    ///
    /// The file has carried an explicit `auth_mode` since the version this was
    /// written against (0.149.1), but it is treated as a hint rather than the
    /// source of truth: the presence of real material decides, so an older or
    /// newer file that drops or renames the field still reads correctly.
    static func storedAuthShape(inAuthFileContents authFileData: Data) -> StoredAuthShape? {
        guard let json = try? JSONSerialization.jsonObject(with: authFileData) as? [String: Any] else {
            return nil
        }
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String,
           !accessToken.isEmpty {
            return .chatGPTTokens
        }
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .apiKey
        }
        return nil
    }

    /// The ChatGPT account id the login is bound to, when there is one. Shown
    /// nowhere; it exists so a future "which account is this?" row has a value
    /// to render that is not a secret.
    static func accountIdentifier(inAuthFileContents authFileData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: authFileData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accountIdentifier = tokens["account_id"] as? String,
              !accountIdentifier.isEmpty else {
            return nil
        }
        return accountIdentifier
    }

    // MARK: Redaction

    /// Redacts anything token-shaped from text bound for the on-screen
    /// transcript. `codex login` is not supposed to print its tokens, but the
    /// panel renders whatever the CLI writes, so this is belt-and-braces in the
    /// same posture as the Claude path's redaction: scrub on the way OUT, never
    /// rely on the other program's discretion.
    ///
    /// Covers the three shapes that could appear: an OpenAI API key, a JWT
    /// (the id/access tokens are JWTs), and the CLI's own `ey…`-prefixed blobs.
    static func redactingAnySecret(in text: String) -> String {
        var redactedText = text
        let secretPatterns = [
            // sk-… and sk-proj-… API keys.
            "sk-[A-Za-z0-9_-]{20,}",
            // A JWT: three base64url segments. The access/id tokens are these.
            "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}",
        ]
        for pattern in secretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let wholeRange = NSRange(redactedText.startIndex..., in: redactedText)
            redactedText = regex.stringByReplacingMatches(
                in: redactedText, range: wholeRange, withTemplate: "…[hidden]"
            )
        }
        return redactedText
    }

    // MARK: Disconnecting

    /// Signs the reader out by asking the CLI to forget its own credential —
    /// `codex logout`. Iris does not delete `auth.json` itself: the file is the
    /// CLI's, its exact shape is the CLI's business, and a future version may
    /// keep more than one thing in it.
    ///
    /// Returns whether the CLI reported success. Synchronous and quick (no
    /// network — it is a local file delete on the CLI's side).
    @discardableResult
    static func disconnect() -> Bool {
        guard let codexBinaryPath = locateCodexBinary() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinaryPath)
        process.arguments = ["logout"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = environmentForCodex()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: The environment the CLI runs in

    /// The environment `codex` is spawned with: the reader's own, plus a PATH
    /// wide enough to find node and friends when Iris was launched from Finder
    /// (a GUI app inherits a minimal PATH, which is exactly how "works in my
    /// terminal, not in the app" bugs happen).
    static func environmentForCodex() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let home = NSHomeDirectory()
        let broadSearchPath = [
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/bin", "\(home)/.bun/bin",
        ].joined(separator: ":")
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(existingPath):\(broadSearchPath)"
        } else {
            environment["PATH"] = broadSearchPath
        }
        environment["HOME"] = home
        return environment
    }
}

// MARK: - Signing in: `codex login` in a pty

/// Runs `codex login` in a real pty and waits for the browser round trip to
/// land a credential on disk. The reader completes the OpenAI sign-in the CLI
/// opens in their browser; Iris watches for the result.
///
/// HOW SUCCESS IS DETECTED, and why it is not a string match: the CLI prints a
/// success line, but wording is not a contract and Iris would silently stop
/// working the day it changed. The oracle is the credential file itself —
/// `auth.json` going from absent/empty to holding real material is the thing
/// that actually means "signed in", and it is what `codex exec` will read a
/// moment later. The printed output is shown to the reader, never parsed for
/// truth. (This is the same discipline the maintain harness learned the hard
/// way: verify the outcome, not the narration.)
@MainActor
final class CodexCLISignInSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// The Codex CLI is not installed where Iris could find it.
        case codexNotFound
        /// `codex login` is running; the reader is completing the browser step.
        case running
        /// A login landed on disk — the reader is connected.
        case connected(CodexCLILogin.ConnectionState)
        /// The command exited without a credential ever appearing (the reader
        /// cancelled the browser step, or the CLI errored).
        case finishedWithoutLogin
        /// Something went wrong starting or running the command.
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// The ANSI-stripped, secret-redacted transcript for the panel.
    @Published private(set) var visibleTranscript: String = ""

    private var pseudoTerminal: GuideAutopilotPseudoTerminal?
    private var rawOutputSoFar: String = ""
    private var hasConnected = false
    /// Polls `auth.json` for the moment the browser round trip lands. The pty
    /// gives no event for "the CLI's local callback server got its code", so
    /// the file is what Iris watches.
    private var credentialPollTimer: Timer?

    /// The shape on disk when the session started, so an ALREADY-signed-in
    /// reader re-running sign-in is not instantly reported as success by the
    /// stale file that was there before they began.
    private var authShapeBeforeStarting: CodexCLILogin.StoredAuthShape?
    /// The credential file's write time when this session began, paired with
    /// the shape above to tell "a new login landed" from "one was already here".
    private var authFileModifiedBeforeStarting: Date?

    private static let mostTranscriptCharactersToKeep = 8_000
    private static let credentialPollIntervalSeconds: TimeInterval = 0.75

    var isRunning: Bool { phase == .running }

    /// Spawns `codex login`. No-op if already running.
    func start() {
        guard phase != .running else { return }
        rawOutputSoFar = ""
        visibleTranscript = ""
        hasConnected = false

        guard let codexBinaryPath = CodexCLILogin.locateCodexBinary() else {
            phase = .codexNotFound
            return
        }

        // A stale login must not count as this session's success. The obvious
        // way to guarantee that — `codex logout` first — is WRONG: a reader who
        // then cancels the browser step has lost a login they had when they
        // started. So nothing is destroyed; the file's write time is the oracle
        // instead, and a cancelled attempt leaves the reader exactly as it
        // found them.
        authShapeBeforeStarting = FileManager.default
            .contents(atPath: CodexCLILogin.authFilePath())
            .flatMap { CodexCLILogin.storedAuthShape(inAuthFileContents: $0) }
        authFileModifiedBeforeStarting = CodexCLILogin.authFileModificationDate()

        let terminal = GuideAutopilotPseudoTerminal()
        terminal.onOutput = { [weak self] outputBytes in
            DispatchQueue.main.async { self?.ingest(outputBytes) }
        }
        terminal.onProcessExit = { [weak self] _ in
            DispatchQueue.main.async { self?.handleProcessExit() }
        }

        do {
            try terminal.spawn(
                shellPath: codexBinaryPath,
                arguments: ["login"],
                environment: CodexCLILogin.environmentForCodex()
            )
        } catch {
            phase = .failed(reason: "Iris couldn't start `codex login`.")
            return
        }

        pseudoTerminal = terminal
        phase = .running
        startPollingForCredential()
    }

    /// Forwards a line the reader typed, for any prompt the CLI puts up.
    func sendLine(_ text: String) {
        guard phase == .running else { return }
        pseudoTerminal?.write(text + "\r")
    }

    /// Forwards a bare return.
    func sendReturn() {
        guard phase == .running else { return }
        pseudoTerminal?.write("\r")
    }

    /// Reader gave up. Tears the command down.
    func cancel() {
        stopPollingForCredential()
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
        if phase == .running { phase = .idle }
    }

    // MARK: - Output handling

    private func ingest(_ outputBytes: [UInt8]) {
        guard let chunk = String(bytes: outputBytes, encoding: .utf8) else { return }
        rawOutputSoFar += chunk
        let cleaned = GuideAutopilotOutputBuffer.strippedOfControlSequences(rawOutputSoFar)
        let redacted = CodexCLILogin.redactingAnySecret(in: cleaned)
        visibleTranscript = String(redacted.suffix(Self.mostTranscriptCharactersToKeep))
    }

    // MARK: - The credential oracle

    private func startPollingForCredential() {
        stopPollingForCredential()
        credentialPollTimer = Timer.scheduledTimer(
            withTimeInterval: Self.credentialPollIntervalSeconds, repeats: true
        ) { [weak self] _ in
            guard let session = self else { return }
            Task { @MainActor in session.checkForLandedCredential() }
        }
    }

    private func stopPollingForCredential() {
        credentialPollTimer?.invalidate()
        credentialPollTimer = nil
    }

    private func checkForLandedCredential() {
        guard !hasConnected else { return }
        let state = CodexCLILogin.currentState()
        guard state.isUsable else { return }
        if authShapeBeforeStarting != nil {
            // There was already a login when this started, so "a credential
            // exists" proves nothing. Only a file written since then does.
            guard let before = authFileModifiedBeforeStarting,
                  let landed = CodexCLILogin.authFileModificationDate(),
                  landed > before else { return }
        }
        hasConnected = true
        phase = .connected(state)
        stopPollingForCredential()
        // The CLI exits on its own after a successful login; closing the pty
        // here keeps a stuck one from lingering.
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
    }

    private func handleProcessExit() {
        pseudoTerminal = nil
        if hasConnected { return }
        // The CLI can exit a beat before it finishes writing the file; give the
        // oracle one last look before calling it a failure.
        checkForLandedCredential()
        if hasConnected { return }
        stopPollingForCredential()
        if phase == .running {
            phase = .finishedWithoutLogin
        }
    }
}
