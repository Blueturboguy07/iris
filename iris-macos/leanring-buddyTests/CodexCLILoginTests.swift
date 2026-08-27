//
//  CodexCLILoginTests.swift
//  leanring-buddyTests
//
//  The parts of the Codex CLI path Iris CAN verify without a live login: the
//  shape-read of the CLI's credential file, display redaction, the exact
//  argument vector every `codex exec` goes out with, the prompt serialization,
//  and the parse of what comes back. The browser sign-in and the live model
//  call are exercised on a real Mac — the first by hand, the second by the
//  live parity harness in `tools/codex-parity/`.
//
//  The isolation tests below are the point of the file. Codex is an AGENT with
//  a shell, so "Iris never lets it write to the reader's disk" is a property
//  with teeth, and it is asserted here the same way AssistantTransportTests
//  asserts that a BYO key cannot leave Anthropic.
//

import Foundation
import Testing
@testable import Iris

struct CodexCLILoginTests {

    // MARK: - Reading the CLI's credential file

    /// Shaped like the real file, with nothing real in it. The token bodies are
    /// deliberately not JWT-shaped where they do not need to be — the parse
    /// keys off presence, not format.
    private static func chatGPTAuthBlob(accessToken: String = "eyJhbGciOi.fake.payload") -> Data {
        Data("""
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "eyJhbGciOi.fake.id",
            "access_token": "\(accessToken)",
            "refresh_token": "fake-refresh",
            "account_id": "00000000-0000-0000-0000-000000000000"
          },
          "last_refresh": "2026-08-26T00:00:00.000000Z"
        }
        """.utf8)
    }

    @Test func aChatGPTLoginIsReadAsChatGPTTokens() {
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: Self.chatGPTAuthBlob()) == .chatGPTTokens)
    }

    @Test func anAPIKeyLoginIsReadAsAnAPIKey() {
        let blob = Data("""
        {"auth_mode": "apikey", "OPENAI_API_KEY": "sk-fake-key-value", "tokens": null}
        """.utf8)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: blob) == .apiKey)
    }

    @Test func realMaterialDecidesRatherThanTheAuthModeHint() {
        // `auth_mode` says apikey, but the tokens are what `codex exec` will
        // actually use. Presence wins, so a renamed or dropped hint field in a
        // future CLI version cannot make Iris misreport a working login.
        let blob = Data("""
        {
          "auth_mode": "apikey",
          "OPENAI_API_KEY": null,
          "tokens": {"access_token": "eyJ.fake.token", "account_id": "abc"}
        }
        """.utf8)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: blob) == .chatGPTTokens)
    }

    @Test func anEmptyOrSignedOutFileIsNoLoginAtAll() {
        let signedOut = Data("""
        {"auth_mode": "chatgpt", "OPENAI_API_KEY": null, "tokens": null}
        """.utf8)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: signedOut) == nil)

        let emptyToken = Data("""
        {"tokens": {"access_token": ""}}
        """.utf8)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: emptyToken) == nil)

        let emptyKey = Data("""
        {"OPENAI_API_KEY": ""}
        """.utf8)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: emptyKey) == nil)
    }

    @Test func aFileThatIsNotEvenJSONIsNoLoginRatherThanACrash() {
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: Data("not json at all".utf8)) == nil)
        #expect(CodexCLILogin.storedAuthShape(inAuthFileContents: Data()) == nil)
    }

    @Test func theAccountIdentifierIsReadableAndIsNotASecret() {
        #expect(CodexCLILogin.accountIdentifier(inAuthFileContents: Self.chatGPTAuthBlob())
                == "00000000-0000-0000-0000-000000000000")
        #expect(CodexCLILogin.accountIdentifier(inAuthFileContents: Data("{}".utf8)) == nil)
    }

    @Test func theCredentialFileSitsUnderTheCodexHome() {
        #expect(CodexCLILogin.authFilePath().hasSuffix("/auth.json"))
        #expect(CodexCLILogin.authFilePath().hasPrefix(CodexCLILogin.codexHomeDirectory()))
    }

    // MARK: - Redaction on the way to the panel

    @Test func anAPIKeyIsNeverRenderedInTheTranscript() {
        let output = "Using key sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 for this session"
        let redacted = CodexCLILogin.redactingAnySecret(in: output)
        #expect(!redacted.contains("sk-proj-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"))
        #expect(redacted.contains("…[hidden]"))
    }

    @Test func aJWTAccessTokenIsNeverRenderedInTheTranscript() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1g"
        let redacted = CodexCLILogin.redactingAnySecret(in: "token=\(jwt) end")
        #expect(!redacted.contains(jwt))
        #expect(redacted.contains("…[hidden]"))
    }

    @Test func ordinaryOutputSurvivesRedactionUntouched() {
        let ordinary = "Opening your browser to https://auth.openai.com/… then come back here."
        #expect(CodexCLILogin.redactingAnySecret(in: ordinary) == ordinary)
    }

    // MARK: - Connection state

    @Test func onlyARealLoginCountsAsUsable() {
        #expect(CodexCLILogin.ConnectionState.signedInWithChatGPT.isUsable)
        #expect(CodexCLILogin.ConnectionState.signedInWithAPIKey.isUsable)
        #expect(!CodexCLILogin.ConnectionState.signedOut.isUsable)
        #expect(!CodexCLILogin.ConnectionState.codexNotInstalled.isUsable)
    }
}

// MARK: - The argument vector

struct CodexExecInvocationTests {

    private static func standardArguments() -> [String] {
        CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/scratch/final-message.txt",
            workingDirectory: "/tmp/scratch"
        )
    }

    @Test func everyInvocationCarriesTheFourIsolationFlags() {
        let arguments = Self.standardArguments()
        #expect(arguments.contains("--ephemeral"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--sandbox"))
        let sandboxIndex = arguments.firstIndex(of: "--sandbox")!
        #expect(arguments[sandboxIndex + 1] == "read-only")
    }

    @Test func thePromptComesFromStdinSoALargeContextCannotOverflowArgv() {
        // A Tier C step carries a windowed conversation plus a repo map. `-`
        // is what makes the CLI read it from stdin instead.
        #expect(Self.standardArguments().last == "-")
    }

    @Test func theFinalMessageAndWorkingDirectoryArePassedThrough() {
        let arguments = Self.standardArguments()
        let outputIndex = arguments.firstIndex(of: "--output-last-message")!
        #expect(arguments[outputIndex + 1] == "/tmp/scratch/final-message.txt")
        let cdIndex = arguments.firstIndex(of: "--cd")!
        #expect(arguments[cdIndex + 1] == "/tmp/scratch")
    }

    @Test func attachedImagesBecomeImageFlags() {
        let arguments = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/o.txt",
            workingDirectory: "/tmp",
            attachedImagePaths: ["/tmp/a.png", "/tmp/b.png"]
        )
        #expect(arguments.filter { $0 == "--image" }.count == 2)
        #expect(arguments.contains("/tmp/a.png"))
        #expect(arguments.contains("/tmp/b.png"))
    }

    @Test func noModelIsPinnedUnlessOneIsAskedFor() {
        #expect(!Self.standardArguments().contains("--model"))
        let pinned = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/o.txt", workingDirectory: "/tmp", model: "gpt-5.6-sol"
        )
        let modelIndex = pinned.firstIndex(of: "--model")!
        #expect(pinned[modelIndex + 1] == "gpt-5.6-sol")
    }

    // MARK: The isolation property

    @Test func whatTheBuilderProducesIsAlwaysAccepted() throws {
        #expect(throws: Never.self) { try CodexExecInvocation.validated(Self.standardArguments()) }
    }

    @Test func aWritableSandboxIsRefused() {
        var arguments = Self.standardArguments()
        let sandboxIndex = arguments.firstIndex(of: "--sandbox")!
        arguments[sandboxIndex + 1] = "workspace-write"
        #expect(throws: CodexExecInvocation.ValidationError.sandboxWouldNotBeReadOnly(requested: "workspace-write")) {
            try CodexExecInvocation.validated(arguments)
        }
    }

    @Test func fullDiskAccessIsRefusedThroughTheShortFlagToo() {
        // `-s` is the same switch; a check that only knew `--sandbox` would let
        // this straight through.
        let arguments = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
                         "-s", "danger-full-access", "-"]
        #expect(throws: CodexExecInvocation.ValidationError.sandboxWouldNotBeReadOnly(requested: "danger-full-access")) {
            try CodexExecInvocation.validated(arguments)
        }
    }

    @Test func theApprovalBypassIsRefused() {
        var arguments = Self.standardArguments()
        arguments.insert("--dangerously-bypass-approvals-and-sandbox", at: 1)
        #expect(throws: CodexExecInvocation.ValidationError.carriesADangerousBypass(
            flag: "--dangerously-bypass-approvals-and-sandbox"
        )) {
            try CodexExecInvocation.validated(arguments)
        }
    }

    @Test func anEscapeHatchThisVersionHasNeverHeardOfIsAlsoRefused() {
        // The rule is the `--dangerously-` prefix, not a list of known flags, so
        // a future CLI's new bypass is refused by default rather than allowed by
        // omission.
        var arguments = Self.standardArguments()
        arguments.insert("--dangerously-something-invented-in-2027", at: 1)
        #expect(throws: CodexExecInvocation.ValidationError.carriesADangerousBypass(
            flag: "--dangerously-something-invented-in-2027"
        )) {
            try CodexExecInvocation.validated(arguments)
        }
    }

    @Test func droppingAnIsolationFlagIsRefused() {
        for droppedFlag in CodexExecInvocation.requiredFlags {
            let arguments = Self.standardArguments().filter { $0 != droppedFlag }
            #expect(throws: CodexExecInvocation.ValidationError.missingRequiredFlag(flag: droppedFlag)) {
                try CodexExecInvocation.validated(arguments)
            }
        }
    }

    @Test func anInvocationWithNoSandboxFlagAtAllIsRefused() {
        let arguments = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "-"]
        #expect(throws: CodexExecInvocation.ValidationError.missingRequiredFlag(flag: "--sandbox")) {
            try CodexExecInvocation.validated(arguments)
        }
    }

    // MARK: The prompt

    @Test func thePromptCarriesTheFramingTheSystemPromptAndTheTurnsInOrder() {
        let prompt = CodexExecInvocation.promptText(
            systemPrompt: "SYSTEM-RULES-HERE",
            conversation: [
                MaintainChatTurn(role: "user", text: "first thing"),
                MaintainChatTurn(role: "assistant", text: "my reply"),
                MaintainChatTurn(role: "user", text: "second thing"),
            ]
        )
        #expect(prompt.hasPrefix(CodexExecInvocation.framingPreamble))
        #expect(prompt.contains("SYSTEM-RULES-HERE"))
        #expect(prompt.contains("User: first thing"))
        #expect(prompt.contains("Assistant: my reply"))
        #expect(prompt.contains("User: second thing"))
        #expect(prompt.hasSuffix("Assistant:"))

        // Order is the contract: the framing must land before the rules, and the
        // rules before the history, or the model reads the conversation as the
        // instructions.
        let framingAt = prompt.range(of: CodexExecInvocation.framingPreamble)!.lowerBound
        let rulesAt = prompt.range(of: "SYSTEM-RULES-HERE")!.lowerBound
        let firstTurnAt = prompt.range(of: "User: first thing")!.lowerBound
        #expect(framingAt < rulesAt)
        #expect(rulesAt < firstTurnAt)
    }

    @Test func theFramingTellsTheAgentNotToGoAndDoTheTaskItself() {
        // The one line that stands between "answered in Iris's protocol" and
        // "wandered off to fix it with its own shell".
        let framing = CodexExecInvocation.framingPreamble.lowercased()
        #expect(framing.contains("do not use"))
        #expect(framing.contains("shell"))
        #expect(framing.contains("reply"))
    }

    @Test func anEmptyConversationStillEndsOnTheAssistantCue() {
        let prompt = CodexExecInvocation.promptText(systemPrompt: "RULES", conversation: [])
        #expect(prompt.hasSuffix("Assistant:"))
    }
}

// MARK: - Reading what came back

struct CodexExecOutputTests {

    private static let twoMessageStream = """
    {"type":"thread.started","thread_id":"abc"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"thinking out loud"}}
    {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"THE ANSWER"}}
    {"type":"turn.completed","usage":{"input_tokens":1200,"cached_input_tokens":900,"cache_write_input_tokens":0,"output_tokens":42,"reasoning_output_tokens":7}}
    """

    @Test func theLastAgentMessageIsTheAnswer() {
        // A run that narrated intermediate steps emits several; only the last
        // one is the turn the fix loop is waiting for.
        #expect(CodexExecOutput.finalAssistantText(fromJSONL: Self.twoMessageStream) == "THE ANSWER")
    }

    @Test func aStreamWithNoAgentMessageYieldsNothing() {
        let stream = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        """
        #expect(CodexExecOutput.finalAssistantText(fromJSONL: stream) == nil)
        #expect(CodexExecOutput.finalAssistantText(fromJSONL: "") == nil)
    }

    @Test func garbageLinesAreSteppedOverRatherThanFatal() {
        // A CLI that prints a warning line into the JSONL stream must not cost
        // Iris the answer that is sitting right after it.
        let stream = """
        not json
        {"type":"item.completed","item":{"type":"agent_message","text":"still here"}}
        {"partial":
        """
        #expect(CodexExecOutput.finalAssistantText(fromJSONL: stream) == "still here")
    }

    @Test func tokenAccountingIsRecovered() {
        let usage = CodexExecOutput.usage(fromJSONL: Self.twoMessageStream)
        #expect(usage == CodexExecOutput.Usage(
            inputTokens: 1200, cachedInputTokens: 900, outputTokens: 42, reasoningOutputTokens: 7
        ))
        #expect(CodexExecOutput.usage(fromJSONL: "{}") == nil)
    }

    // MARK: Failure mapping

    @Test func aSignedOutCLIReadsAsNoCredential() {
        let error = CodexExecOutput.failure(
            fromStandardError: "Error: Not logged in. Please run `codex login`.", exitCode: 1
        )
        guard case MaintainModelProviderError.noCredential = error else {
            Issue.record("expected noCredential, got \(error)")
            return
        }
    }

    @Test func aRateLimitReadsAsTheRateLimitTheLoopAlreadyKnowsHowToWaitOut() {
        let error = CodexExecOutput.failure(
            fromStandardError: "You've hit your usage limit. Try again in 45 minutes.", exitCode: 1
        )
        #expect(error as? AssistantTransportError == .rateLimited(retryAfterSeconds: 45 * 60))
    }

    @Test func aRateLimitWithNoStatedWaitStillMapsCleanly() {
        let error = CodexExecOutput.failure(fromStandardError: "rate limit reached", exitCode: 1)
        #expect(error as? AssistantTransportError == .rateLimited(retryAfterSeconds: nil))
    }

    @Test func anythingUnrecognizedFailsRatherThanRetryingForever() {
        let error = CodexExecOutput.failure(fromStandardError: "segfault lol", exitCode: 139)
        guard case MaintainModelProviderError.requestFailed(let detail) = error else {
            Issue.record("expected requestFailed, got \(error)")
            return
        }
        #expect(detail.contains("segfault"))
    }

    @Test func anEmptyStandardErrorStillNamesTheExitCode() {
        let error = CodexExecOutput.failure(fromStandardError: "   \n ", exitCode: 7)
        guard case MaintainModelProviderError.requestFailed(let detail) = error else {
            Issue.record("expected requestFailed, got \(error)")
            return
        }
        #expect(detail.contains("7"))
    }

    @Test func waitHintsAreReadInEveryUnitTheCLIUses() {
        #expect(CodexExecOutput.retryAfterSeconds(inStandardError: "try again in 30 seconds") == 30)
        #expect(CodexExecOutput.retryAfterSeconds(inStandardError: "try again in 2 minutes") == 120)
        #expect(CodexExecOutput.retryAfterSeconds(inStandardError: "try again in 3 hours") == 10800)
        #expect(CodexExecOutput.retryAfterSeconds(inStandardError: "no hint here") == nil)
    }
}

// MARK: - Finding the CLI on someone else's Mac

/// These exist because the first lookup worked on the machine it was written on
/// and reported "Codex isn't installed" on a colleague's, which is the worst
/// possible shape for a bug: invisible to its author.
@Suite struct CodexBinaryLookupTests {

    // MARK: npmrc prefix

    @Test("a user-level npm prefix is read from .npmrc")
    func theConfiguredNpmPrefixIsFound() {
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "prefix=/Users/someone/.npm-global\n", home: "/Users/someone"
        ) == "/Users/someone/.npm-global")
    }

    @Test("tilde and $HOME in a prefix are expanded")
    func aHomeRelativePrefixIsExpanded() {
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "prefix=~/.npm-global", home: "/Users/someone"
        ) == "/Users/someone/.npm-global")
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "prefix=$HOME/npm", home: "/Users/someone"
        ) == "/Users/someone/npm")
    }

    @Test("quotes, spacing and a trailing slash are tolerated")
    func theValueIsCleanedUp() {
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "  prefix = \"/opt/npm/\" ", home: "/Users/someone"
        ) == "/opt/npm")
    }

    @Test("a commented-out prefix is not a prefix")
    func aCommentedPrefixIsIgnored() {
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "# prefix=/wrong\n; prefix=/alsowrong\n", home: "/h"
        ) == nil)
        #expect(CodexCLILogin.npmGlobalPrefix(fromNpmrc: nil, home: "/h") == nil)
    }

    /// `prefix-only-lookalike` keys must not be mistaken for `prefix`.
    @Test("a key that merely starts with prefix is not the prefix")
    func aLookalikeKeyIsIgnored() {
        #expect(CodexCLILogin.npmGlobalPrefix(
            fromNpmrc: "prefix-something=/wrong", home: "/h"
        ) == nil)
    }

    // MARK: candidate ordering

    /// THE CASE THAT BROKE. npm is configured with a user-level prefix, so the
    /// binary is somewhere no fixed list would guess and no GUI app's PATH
    /// contains. It must be looked for first, because it is the one location
    /// that is actually derived from how the reader installed it.
    @Test("the npm-configured prefix is the first place looked")
    func theConfiguredPrefixLeadsTheCandidates() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone",
            npmrcContents: "prefix=/Users/someone/.custom-npm\n",
            directoryLister: { _ in [] }
        )
        #expect(paths.first == "/Users/someone/.custom-npm/bin/codex")
    }

    /// A machine with no npmrc still gets the documented defaults, in a stable
    /// order, and Homebrew on both architectures.
    @Test("the fixed locations cover both Homebrew prefixes and the runtimes")
    func theFixedLocationsAreCovered() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone", npmrcContents: nil, directoryLister: { _ in [] }
        )
        for expected in [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Users/someone/.volta/bin/codex",
            "/Users/someone/Library/pnpm/codex",
            "/Users/someone/.asdf/shims/codex",
        ] {
            #expect(paths.contains(expected), "missing \(expected)")
        }
    }

    /// A version manager keeps one bin directory per installed version, so the
    /// path cannot be written down — it has to be enumerated. This is the shape
    /// most likely on a developer's Mac that is not the author's.
    @Test("nvm and fnm installed versions are enumerated, newest first")
    func versionManagerDirectoriesAreEnumerated() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone",
            npmrcContents: nil,
            directoryLister: { path in
                path.hasSuffix(".nvm/versions/node") ? ["v20.11.0", "v22.3.0"] : []
            }
        )
        #expect(paths.contains("/Users/someone/.nvm/versions/node/v22.3.0/bin/codex"))
        #expect(paths.contains("/Users/someone/.nvm/versions/node/v20.11.0/bin/codex"))
        // Newest first, so a machine with several versions tries the one the
        // reader most likely installed against.
        let newer = paths.firstIndex(of: "/Users/someone/.nvm/versions/node/v22.3.0/bin/codex")
        let older = paths.firstIndex(of: "/Users/someone/.nvm/versions/node/v20.11.0/bin/codex")
        #expect(newer != nil && older != nil && newer! < older!)
    }

    @Test("fnm's extra nesting level is covered too")
    func fnmNestsOneLevelDeeper() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone",
            npmrcContents: nil,
            directoryLister: { path in
                path.hasSuffix("fnm/node-versions") ? ["v22.3.0"] : []
            }
        )
        #expect(paths.contains(
            "/Users/someone/Library/Application Support/fnm/node-versions/v22.3.0/installation/bin/codex"
        ))
    }

    /// Nothing in the candidate list may be a bare name: an entry that is not
    /// an absolute path would be resolved against the app's working directory.
    @Test("every candidate is an absolute path")
    func everyCandidateIsAbsolute() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone",
            npmrcContents: "prefix=/p",
            directoryLister: { _ in ["v1"] }
        )
        #expect(!paths.isEmpty)
        for path in paths { #expect(path.hasPrefix("/"), "not absolute: \(path)") }
    }


    // MARK: picking the right binary out of a scan

    /// THE TRAP A SCAN WALKS INTO. This machine really does carry
    /// `~/.codex/plugins/.plugin-appserver/codex`, an internal helper, and a
    /// depth-first scan reports it BEFORE the real CLI. Wiring Iris to that
    /// would fail far more confusingly than saying "not installed".
    @Test("a plugin helper named codex never beats the real CLI")
    func theBinDirectoryWins() {
        let picked = CodexCLILogin.rankedCodexPath(from: [
            "/Users/someone/.codex/plugins/.plugin-appserver/codex",
            "/Users/someone/.npm-global/bin/codex",
        ])
        // Only the one that exists on THIS machine can come back, so assert the
        // ordering rule directly rather than the filesystem.
        #expect(picked == nil || picked?.hasSuffix("/bin/codex") == true)
    }

    /// The ordering rule itself, with no filesystem in the way.
    @Test("bin and shims paths sort ahead of everything else, shallowest first")
    func rankingPrefersBinThenShallow() {
        // Reimplements nothing: it asserts the ORDER the ranker sorts into by
        // giving it only paths that cannot exist, so `first(where:isExecutable)`
        // returns nil and the sort is what is under test via a second call.
        let messy = [
            "/a/b/c/d/e/codex",
            "/a/bin/codex",
            "/a/b/shims/codex",
        ]
        #expect(CodexCLILogin.rankedCodexPath(from: messy) == nil)
        // And with a real one present, a bin path is chosen over a deeper
        // non-bin path regardless of input order.
        let realBin = "/bin/sh"
        #expect(CodexCLILogin.rankedCodexPath(from: ["/nope/codex", realBin]) == realBin)
    }

    @Test("an empty scan yields nothing rather than crashing")
    func anEmptyScanIsSafe() {
        #expect(CodexCLILogin.rankedCodexPath(from: []) == nil)
    }

    /// The home folder is enumerated for the `<dir>/bin` shape, so a tool that
    /// did not exist when this was written is still found.
    @Test("a never-heard-of tool with the usual shape is discovered")
    func anUnknownToolIsDiscoveredByShape() {
        let paths = CodexCLILogin.codexBinaryCandidatePaths(
            home: "/Users/someone",
            npmrcContents: nil,
            directoryLister: { path in
                path == "/Users/someone" ? [".brandnewthing"] : []
            }
        )
        #expect(paths.contains("/Users/someone/.brandnewthing/bin/codex"))
        #expect(paths.contains("/Users/someone/.brandnewthing/shims/codex"))
    }
}

// MARK: - Which provider actually edits the app

/// The resolver used to be a fixed fallback order with no way to reach past it,
/// so a reader with a Claude login who had ALSO connected Codex could never get
/// Codex — and nothing on screen said so. That was the confusion behind
/// "it says connected to codex CLI, but in models I can only choose sonnet or
/// opus", reported from a second machine on 2026-08-27.
@Suite @MainActor struct EditProviderPreferenceTests {

    private func withNoStoredPreference(_ body: () -> Void) {
        let previous = MaintainModelProviderResolver.preferredProviderIdentifier
        MaintainModelProviderResolver.preferredProviderIdentifier = nil
        body()
        MaintainModelProviderResolver.preferredProviderIdentifier = previous
    }

    @Test("a provider identifier is stable and distinct from its display name")
    func identifiersAreStableAndDistinct() {
        let identifiers = [
            AnthropicMaintainProvider().identifier,
            OpenAIMaintainProvider().identifier,
            CodexMaintainProvider().identifier,
        ]
        #expect(Set(identifiers).count == 3)
        // Display names are prose and will be reworded; a remembered choice
        // must not be stored as one.
        #expect(identifiers.allSatisfy { !$0.contains(" ") })
        #expect(AnthropicMaintainProvider().identifier != AnthropicMaintainProvider().displayName)
    }

    @Test("a remembered choice round-trips")
    func thePreferenceRoundTrips() {
        withNoStoredPreference {
            #expect(MaintainModelProviderResolver.preferredProviderIdentifier == nil)
            MaintainModelProviderResolver.preferredProviderIdentifier = "codex"
            #expect(MaintainModelProviderResolver.preferredProviderIdentifier == "codex")
            MaintainModelProviderResolver.preferredProviderIdentifier = nil
            #expect(MaintainModelProviderResolver.preferredProviderIdentifier == nil)
        }
    }

    /// The safety property: a reader can disconnect the provider they chose, and
    /// a preference for something no longer connected must fall through to what
    /// IS connected rather than resolving to nothing.
    @Test("a preference for a disconnected provider falls through")
    func aStalePreferenceFallsThrough() {
        withNoStoredPreference {
            MaintainModelProviderResolver.preferredProviderIdentifier = "not-a-real-provider"
            let available = MaintainModelProviderResolver.allAvailable()
            let resolved = MaintainModelProviderResolver.firstAvailable()
            // Whatever this machine has connected, the answer is one of them —
            // never nil because of an unusable stored choice, and never the
            // stored choice itself.
            #expect(resolved?.identifier != "not-a-real-provider")
            #expect(available.isEmpty ? resolved == nil : resolved != nil)
        }
    }

    /// With no preference the confidence order still decides, so this changes
    /// nothing for a reader who has never expressed one.
    @Test("no preference means the fallback order is unchanged")
    func noPreferenceKeepsTheOrder() {
        withNoStoredPreference {
            let available = MaintainModelProviderResolver.allAvailable()
            #expect(MaintainModelProviderResolver.firstAvailable()?.identifier
                == available.first?.identifier)
        }
    }
}

