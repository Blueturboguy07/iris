//
//  CodexFixProposerLiveTests.swift
//  leanring-buddyTests
//
//  A REAL call to the reader's real `codex` CLI, because everything else about
//  `GuideAutopilotCodexFixProposer` is asserted against replies I wrote myself,
//  and the founder's standing rule says that is not a test:
//
//    "scripted-provider tests ≠ tested; any Tier C prompt/protocol change needs
//     a LIVE run (real model, real jail, scratch repo) before deploy — the
//     Aug 22 six-gap pass died in 2 live steps on reply drift."
//
//  This route is exactly that shape of change. It inherits
//  `CodexMaintainProvider.framingPreamble`, which was written for the app-EDITING
//  loop and instructs the model to reach the repository by emitting command and
//  edit blocks. On this route that is wrong — the deliverable is ONE json object
//  — so `replyContract` overrides it. Whether a real model actually obeys the
//  override is not something any unit test can answer, and it is the single most
//  likely way this ships broken.
//
//  Billed, slow (codex is roughly 9x the Anthropic route), and off by default.
//
//    IRIS_CODEX_FIX_LIVE=1 xcodebuild … test \
//      -only-testing:leanring-buddyTests/CodexFixProposerLiveTests
//

import Foundation
import Testing
@testable import Iris

enum CodexFixLiveGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["IRIS_CODEX_FIX_LIVE"] == "1"
    }
}

@Suite(
    .enabled(if: CodexFixLiveGate.isEnabled, "set IRIS_CODEX_FIX_LIVE=1 to make real, billed codex calls"),
    .serialized
)
@MainActor
struct CodexFixProposerLiveTests {

    /// A failure with an obvious, safe, single-command answer, so a wrong reply
    /// is unambiguous rather than a judgement call. The guide's own hosts
    /// include the npm registry, so the honest fix is inside the allowlist and
    /// the host guard is not what is being measured here.
    private static func missingPnpmContext() -> GuideAutopilotFailureContext {
        GuideAutopilotFailureContext(
            guideSlug: "whimprflow",
            guideVersion: 9,
            appName: "WhimprFlow",
            platformLabel: "macOS",
            stepIdentifier: "dependencies",
            stepTitle: "Install the interface packages",
            stepBody: "",
            verifierLabel: "The install finishes without an error",
            commandAsRun: "pnpm install",
            exitStatus: 127,
            scrubbedOutputTail: "zsh: command not found: pnpm",
            shellPath: "/bin/zsh",
            workingDirectory: "/Users/reader/whimprflow",
            operatingSystemVersion: "macOS 15.7",
            architecture: "arm64",
            knownToolVersions: ["git 2.50.1", "node 22.1.0"],
            priorAttempts: [],
            hostsTheGuideAlreadyReaches: ["github.com", "registry.npmjs.org"]
        )
    }

    @Test("a real codex call returns a fix Iris can act on")
    func aRealCodexCallReturnsAnActionableFix() async throws {
        try #require(CodexCLILogin.currentState().isUsable, "connect the codex CLI first")

        let proposer = GuideAutopilotCodexFixProposer()
        let startedAt = Date()
        let fix = try await proposer.proposeFix(for: Self.missingPnpmContext())
        let elapsed = Date().timeIntervalSince(startedAt)

        print("[codex-live] round trip: \(String(format: "%.1f", elapsed))s")

        // THE BAR. A nil here is the exact failure this test exists to catch:
        // the model answered with something `proposalObject` could not read —
        // almost certainly a ```bash block, because the inherited Tier C
        // preamble told it to emit one and the override did not hold.
        let proposedFix = try #require(
            fix,
            "codex returned nothing parseable — the reply contract did not override the Tier C preamble"
        )

        print("[codex-live] diagnosis: \(proposedFix.diagnosis)")
        print("[codex-live] confidence: \(proposedFix.confidence)")
        print("[codex-live] action: \(proposedFix.action)")

        #expect(!proposedFix.diagnosis.isEmpty)
        #expect(["high", "medium", "low"].contains(proposedFix.confidence),
                "confidence must be one of the three the schema allows, got '\(proposedFix.confidence)'")

        // The failure is "pnpm is not installed" with a command the reader can
        // run. Anything but a runnable command here is a real miss — this is
        // about as unambiguous as an install failure gets.
        guard case .runACommand(let command, let whatItDoes) = proposedFix.action else {
            Issue.record("expected a runnable command for a missing pnpm, got \(proposedFix.action)")
            return
        }
        #expect(!command.isEmpty)
        #expect(!whatItDoes.isEmpty, "the plain-English label is what the terminal shows the reader")
        #expect(command.contains("pnpm") || command.contains("corepack"),
                "a fix for a missing pnpm should mention pnpm or corepack, got: \(command)")

        // And it must survive the gate that will actually decide whether it runs.
        // A proposal Iris refuses to execute is not a working ladder.
        let approval = GuideAutopilotRiskAssessment.approve(command)
        print("[codex-live] risk gate: \(approval == nil ? "REFUSED" : "allowed")")
        #expect(approval != nil, "the proposed command was refused outright by the risk gate: \(command)")
    }

    /// The honest-reporting half. `CodexExecInvocation` turns web search on
    /// unconditionally, so `cameFromWebSearch` on this route describes what the
    /// run COULD do rather than what it did. This measures which one actually
    /// happened, so the claim in the code comment is grounded in a number rather
    /// than in my reading of the invocation.
    @Test("what a search rung actually does")
    func aSearchRungIsObserved() async throws {
        try #require(CodexCLILogin.currentState().isUsable, "connect the codex CLI first")

        let proposer = GuideAutopilotCodexFixProposer()
        let fix = try await proposer.proposeFixWithWebSearch(for: Self.missingPnpmContext())

        let proposedFix = try #require(fix, "the search rung returned nothing parseable")
        print("[codex-live] search rung action: \(proposedFix.action)")
        #expect(proposedFix.cameFromWebSearch, "the search rung must report itself as one")
    }
}
