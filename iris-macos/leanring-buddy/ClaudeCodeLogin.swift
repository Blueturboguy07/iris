//
//  ClaudeCodeLogin.swift
//  leanring-buddy
//
//  "CLI login" — letting the reader authenticate Iris's BYO Anthropic tier with
//  their Claude Code login instead of pasting a raw `sk-ant-…` API key. Two ways
//  in, both landing the same `sk-ant-oat…` OAuth token in the Keychain
//  (`.anthropicOAuthToken`), where `AssistantTransport` sends it to Anthropic
//  with an `Authorization: Bearer` + `anthropic-beta: oauth-…` pair:
//
//    1. Automated capture — run `claude setup-token` in a pty and scrape the
//       long-lived token it prints. `ClaudeCodeSetupTokenSession`.
//    2. Import — read the token an existing `claude login` already stored in the
//       macOS Keychain (service "Claude Code-credentials"), and snapshot it.
//
//  HONESTY / VERIFICATION NOTES (this whole file interoperates with an external
//  tool and a login flow Iris cannot exercise from inside its own process):
//    - The `anthropic-beta` value that makes Anthropic accept these tokens lives
//      in `AssistantTransport.anthropicOAuthBetaHeaderValue`; it is the public
//      value Claude Code sends and is UNVERIFIED here. If Anthropic rotates it,
//      OAuth-token requests 401 and that constant is the fix.
//    - A `setup-token` token is long-lived, so it needs no refresh. An IMPORTED
//      `claude login` token ROTATES; this file snapshots the current one and does
//      NOT implement the Claude Code OAuth refresh (its endpoint/client-id are
//      not things Iris can verify). When an imported token lapses, Anthropic
//      returns 401 (surfaced as "that credential was turned down") and the reader
//      re-imports or uses setup-token. The durable path is setup-token.
//    - Using a Claude *subscription* token to power a third-party app against the
//      raw API is a gray area and may be rate-limited by Anthropic; a pasted API
//      key remains the most reliable BYO credential. The UI says so.
//

import Combine
import Foundation
import Security

// MARK: - The user's own Anthropic credential, in either shape

/// Resolves the reader's OWN Anthropic credential — a pasted API key first, then
/// a Claude Code OAuth token — into a BYO transport. One place so the chat path,
/// the Tier C provider, and the crash-path fix adapter never each re-derive the
/// "key or token?" precedence (and never disagree about it).
enum AnthropicBringYourOwnCredential {

    /// True when the reader has connected either shape of their own Anthropic
    /// credential. Used for eligibility gates and panel state without pulling a
    /// secret into memory.
    static var isAvailable: Bool {
        KeychainStore.hasSecret(ofKind: .anthropicAPIKey)
            || KeychainStore.hasSecret(ofKind: .anthropicOAuthToken)
    }

    /// The BYO transport for the reader's own credential, or nil when neither is
    /// stored. Prefers the API key: it is the plainer credential that does not
    /// depend on the OAuth beta header staying valid.
    static func currentTransport() -> AssistantTransport? {
        if let apiKey = KeychainStore.readSecret(ofKind: .anthropicAPIKey), !apiKey.isEmpty {
            return .bringYourOwnKey(anthropicAPIKey: apiKey)
        }
        if let oauthToken = KeychainStore.readSecret(ofKind: .anthropicOAuthToken), !oauthToken.isEmpty {
            return .bringYourOwnOAuthToken(anthropicOAuthToken: oauthToken)
        }
        return nil
    }
}

// MARK: - Shared CLI-login helpers (pure where they can be)

enum ClaudeCodeLogin {

    /// Whether a Claude Code OAuth token is currently connected.
    static var isConnected: Bool {
        KeychainStore.hasSecret(ofKind: .anthropicOAuthToken)
    }

    /// Forget the connected token. The reader's pasted API key (a different
    /// Keychain item) is untouched.
    static func disconnect() {
        try? KeychainStore.deleteSecret(ofKind: .anthropicOAuthToken)
    }

    // MARK: Token scraping (pure)

    /// Finds a long-lived Claude Code OAuth token in a chunk of terminal output.
    /// `setup-token` prints exactly one `sk-ant-oat…` token when it finishes;
    /// this returns the longest such match (a token can be split by a wrapped
    /// line in theory, but the pty is opened 4000 columns wide precisely so it
    /// never is). Pure and total, so it is unit-tested without a process.
    static func scanForOAuthToken(in terminalOutput: String) -> String? {
        // sk-ant-oat<two digits>-<base64url-ish body>. The body is long; require
        // a generous minimum so a truncated echo is not mistaken for the token.
        let pattern = "sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{20,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let wholeRange = NSRange(terminalOutput.startIndex..., in: terminalOutput)
        let matches = regex.matches(in: terminalOutput, range: wholeRange)
        let tokens = matches.compactMap { match -> String? in
            guard let range = Range(match.range, in: terminalOutput) else { return nil }
            return String(terminalOutput[range])
        }
        // The longest match is the complete token; a shorter one is a prefix that
        // arrived in an earlier read before the rest of the bytes.
        return tokens.max(by: { $0.count < $1.count })
    }

    /// Redacts any OAuth token from text bound for the on-screen transcript, so
    /// the captured secret is not left sitting in the panel after `setup-token`
    /// prints it. Matches the app's egress-only scrubbing posture.
    static func redactingAnyOAuthToken(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{6,}") else {
            return text
        }
        let wholeRange = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: wholeRange, withTemplate: "sk-ant-oat…[hidden]"
        )
    }

    // MARK: Locating the CLI

    /// The `claude` executable, or nil when Claude Code is not installed where
    /// Iris can find it. Known install locations first (fast, no subprocess),
    /// then whatever a login shell resolves on the reader's PATH.
    static func locateClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let knownCandidatePaths = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
        ]
        let fileManager = FileManager.default
        for candidatePath in knownCandidatePaths where fileManager.isExecutableFile(atPath: candidatePath) {
            return candidatePath
        }
        return resolveClaudeOnPathViaLoginShell()
    }

    /// Asks a login shell to resolve `claude`, covering an install under a name
    /// or directory the fixed list above does not know. Non-interactive and
    /// synchronous — it only runs when the known paths all miss.
    private static func resolveClaudeOnPathViaLoginShell() -> String? {
        let loginShellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath)
        process.arguments = ["-l", "-c", "command -v claude"]
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

    // MARK: Importing an existing `claude login`

    /// The macOS Keychain service Claude Code files its own OAuth login under.
    private static let claudeCodeKeychainService = "Claude Code-credentials"

    /// What an import attempt did — each a distinct, honest message for the panel.
    enum ImportOutcome: Equatable {
        /// A token was read from the Claude Code login and stored.
        case imported
        /// No `claude login` is present in the Keychain to import.
        case noClaudeCodeLoginFound
        /// The Keychain item exists but Iris could not read it — almost always
        /// because the reader denied the authorization prompt macOS shows when
        /// one app reads another app's Keychain item.
        case couldNotReadKeychain
        /// The login was found and read, but held no usable OAuth token (an
        /// unexpected shape, or an API-key-only login with no token).
        case loginHadNoUsableToken
    }

    /// Reads the token an existing `claude login` stored and snapshots it as the
    /// connected credential. Reading another app's Keychain item triggers a
    /// one-time macOS authorization prompt; denying it lands in
    /// `.couldNotReadKeychain`.
    static func importFromExistingClaudeLogin() -> ImportOutcome {
        let (credentialBlob, status) = readClaudeCodeCredentialBlob()
        if status == errSecItemNotFound {
            return .noClaudeCodeLoginFound
        }
        guard status == errSecSuccess, let credentialBlob else {
            return .couldNotReadKeychain
        }
        guard let oauthToken = extractOAuthToken(fromClaudeCodeCredentialBlob: credentialBlob) else {
            return .loginHadNoUsableToken
        }
        do {
            try KeychainStore.saveSecret(oauthToken, ofKind: .anthropicOAuthToken)
        } catch {
            return .couldNotReadKeychain
        }
        return .imported
    }

    /// Reads the raw credential blob and the raw status, so the caller can tell
    /// "no login" apart from "denied".
    private static func readClaudeCodeCredentialBlob() -> (Data?, OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        // Claude Code files the item under the current user's short name; include
        // it for a precise hit, but a login stored without an account still
        // matches because the service alone is unique to Claude Code.
        query[kSecAttrAccount as String] = NSUserName()

        var readResult: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &readResult)
        if status == errSecItemNotFound {
            // Retry without pinning the account, in case it was stored under a
            // different one than the current short name.
            query.removeValue(forKey: kSecAttrAccount as String)
            status = SecItemCopyMatching(query as CFDictionary, &readResult)
        }
        return (readResult as? Data, status)
    }

    /// Pulls the OAuth token out of Claude Code's stored JSON blob. Claude Code
    /// nests it under `claudeAiOauth.accessToken`; older/other shapes may put it
    /// at the top level. Parsed defensively — anything else is "no usable token"
    /// rather than a crash. Pure, so it is unit-tested with a fixture blob.
    static func extractOAuthToken(fromClaudeCodeCredentialBlob credentialBlob: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: credentialBlob) as? [String: Any] else {
            return nil
        }
        if let oauthSection = json["claudeAiOauth"] as? [String: Any],
           let accessToken = oauthSection["accessToken"] as? String,
           !accessToken.isEmpty {
            return accessToken
        }
        if let accessToken = json["accessToken"] as? String, !accessToken.isEmpty {
            return accessToken
        }
        return nil
    }
}

// MARK: - Automated capture: `claude setup-token` in a pty

/// Runs `claude setup-token` in a real pty and captures the long-lived token it
/// prints. It is a small interactive terminal: the reader completes the browser
/// authorization the CLI opens (and types any prompt the CLI asks for), and the
/// moment a token appears in the output it is stored and the session ends.
///
/// UNVERIFIED end-to-end from here: the browser authorization step cannot be
/// exercised inside Iris's own process, so this is exercised on a real Mac. The
/// pure pieces it leans on (`scanForOAuthToken`, storage) ARE tested.
@MainActor
final class ClaudeCodeSetupTokenSession: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// Claude Code is not installed where Iris could find it.
        case claudeNotFound
        /// `setup-token` is running; the reader is completing the browser step.
        case running
        /// A token was captured and stored — the reader is connected.
        case captured
        /// The command exited without a token ever appearing (the reader
        /// cancelled the browser step, or `setup-token` errored).
        case finishedWithoutToken
        /// Something went wrong starting or running the command.
        case failed(reason: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// The ANSI-stripped, token-redacted transcript for the sheet. The token is
    /// captured programmatically; it is never left rendered in the panel.
    @Published private(set) var visibleTranscript: String = ""

    private var pseudoTerminal: GuideAutopilotPseudoTerminal?
    /// The full, un-redacted output, scanned for the token. Never published.
    private var rawOutputSoFar: String = ""
    private var hasCapturedToken = false

    /// The most output the transcript keeps, so a chatty CLI cannot grow the
    /// sheet without bound.
    private static let mostTranscriptCharactersToKeep = 8_000

    var isRunning: Bool { phase == .running }

    /// Spawns `claude setup-token`. No-op if already running.
    func start() {
        guard phase != .running else { return }
        rawOutputSoFar = ""
        visibleTranscript = ""
        hasCapturedToken = false

        guard let claudeBinaryPath = ClaudeCodeLogin.locateClaudeBinary() else {
            phase = .claudeNotFound
            return
        }

        let terminal = GuideAutopilotPseudoTerminal()
        terminal.onOutput = { [weak self] outputBytes in
            DispatchQueue.main.async { self?.ingest(outputBytes) }
        }
        terminal.onProcessExit = { [weak self] _ in
            DispatchQueue.main.async { self?.handleProcessExit() }
        }

        do {
            try terminal.spawn(
                shellPath: claudeBinaryPath,
                arguments: ["setup-token"],
                environment: Self.environmentForClaude()
            )
        } catch {
            phase = .failed(reason: "Iris couldn't start `claude setup-token`.")
            return
        }

        pseudoTerminal = terminal
        phase = .running
    }

    /// Forwards a line the reader typed (e.g. a code the CLI asked them to paste)
    /// to the running command, with a return so the CLI reads it.
    func sendLine(_ text: String) {
        guard phase == .running else { return }
        pseudoTerminal?.write(text + "\r")
    }

    /// Forwards a bare return (some prompts just want Enter).
    func sendReturn() {
        guard phase == .running else { return }
        pseudoTerminal?.write("\r")
    }

    /// Reader gave up. Tears the command down; nothing is stored.
    func cancel() {
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
        if phase == .running { phase = .idle }
    }

    // MARK: - Output handling

    private func ingest(_ outputBytes: [UInt8]) {
        guard let chunk = String(bytes: outputBytes, encoding: .utf8) else { return }
        rawOutputSoFar += chunk

        // Try to capture the token the instant it is complete.
        if !hasCapturedToken, let token = ClaudeCodeLogin.scanForOAuthToken(in: rawOutputSoFar) {
            captureAndStore(token)
        }

        // Keep a bounded, cleaned, redacted tail for display.
        let cleaned = GuideAutopilotOutputBuffer.strippedOfControlSequences(rawOutputSoFar)
        let redacted = ClaudeCodeLogin.redactingAnyOAuthToken(in: cleaned)
        visibleTranscript = String(redacted.suffix(Self.mostTranscriptCharactersToKeep))
    }

    private func captureAndStore(_ token: String) {
        hasCapturedToken = true
        do {
            try KeychainStore.saveSecret(token, ofKind: .anthropicOAuthToken)
            phase = .captured
        } catch {
            phase = .failed(reason: "Iris captured the token but couldn't save it to the Keychain.")
        }
        // The token is in hand; the command has nothing left to do.
        pseudoTerminal?.closeSession()
        pseudoTerminal = nil
    }

    private func handleProcessExit() {
        pseudoTerminal = nil
        // A capture already moved us to `.captured` and closed the session; its
        // exit arriving afterward must not overwrite success.
        if hasCapturedToken { return }
        if phase == .running {
            phase = .finishedWithoutToken
        }
    }

    /// The environment `claude` runs in: the reader's own, with a TERM and a PATH
    /// wide enough that a self-contained CLI finds what it needs.
    private static func environmentForClaude() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        let home = NSHomeDirectory()
        let broadSearchPath =
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            environment["PATH"] = "\(existingPath):\(broadSearchPath)"
        } else {
            environment["PATH"] = broadSearchPath
        }
        environment["HOME"] = home
        return environment
    }
}
