//
//  Test6ErrorSurfacingReproTests.swift
//  leanring-buddyTests
//
//  THE REPORT. A reader ran an app edit on their own Mac and the card told
//  them, in full:
//
//      "Iris couldn't complete that edit — nothing changed.
//       (model call failed: The operation couldn’t be completed.
//       (Iris.MaintainModelProviderError error 0.))"
//
//  …and when Iris was asked about it, the reader's own words were:
//
//      "I have the codex CLI?"
//
//  They were right, and the message was worthless. `MaintainModelProviderError`
//  had no `LocalizedError` conformance, so `error.localizedDescription` bridged
//  it to an NSError whose domain is the type name and whose code is the case's
//  runtime index — and `MaintainTierCFixer.modelCallFailureReason` reached for
//  exactly that `localizedDescription` for any error that was not an
//  `AssistantTransportError`. Every provider failure that was not Anthropic's
//  therefore reached the reader as a number.
//
//  WHICH number matters, and it is not the one the bug write-up assumed. Swift
//  numbers an enum's PAYLOAD cases first, in declaration order, then its
//  payload-free ones. In
//
//      enum MaintainModelProviderError: Error {
//          case noCredential           // ← runtime index 1
//          case requestFailed(String)  // ← runtime index 0
//      }
//
//  the reader's "error 0" is `.requestFailed` — the one case that CARRIES the
//  real diagnosis as a String. Iris had the explanation in its hand and threw
//  it away. (`.noCredential` is "error 1"; it is just as opaque and is covered
//  here too.) That claim was checked rather than assumed: a standalone binary
//  declaring this exact enum and printing `(error as NSError).code` prints 0
//  for `.requestFailed` and 1 for `.noCredential`. The write-up had it the
//  other way round, which would have aimed the fix at the payload-free case —
//  the one with no diagnosis to lose.
//
//  The stderr fixtures below are not invented. Both were captured by running
//  the reader's own CLI — codex-cli 0.149.1 — with the exact argument vector
//  `CodexExecInvocation.arguments` builds, against a scratch `CODEX_HOME` so
//  no real credential was touched.
//
//  This is the same defect that was already fixed once for its sibling enum:
//  `AssistantTransportError` grew `userFacingMessage` after a reader saw
//  "(Iris.AssistantTransportError error 8.)" when their Claude Code token
//  lapsed (see `ModelCallFailureWordingTests` in
//  FeatureEditRequestProbeTests.swift). The fix was never carried across.
//
//  The bar these tests hold to is the one that file set: the reader must be
//  told what to DO, never a code.
//

import Foundation
import Testing

@testable import Iris

@Suite struct MaintainModelProviderErrorSurfacingReproTests {

    // MARK: - Real captured CLI output

    /// VERBATIM stderr from a real `codex exec` run against an empty
    /// `CODEX_HOME` — i.e. a machine with the CLI installed and no login.
    /// The real run emitted seven of these lines and exited 1; two are enough
    /// to drive the mapping. Note what it does NOT say: there is no "not
    /// logged in" and no "please run `codex login`" anywhere in it. What it
    /// says is `401 Unauthorized`.
    static let stderrFromACodexWithNoLogin = """
        2026-08-30T03:07:45.964271Z ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket: HTTP error: 401 Unauthorized, url: wss://api.openai.com/v1/responses
        2026-08-30T03:07:46.506624Z ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket: HTTP error: 401 Unauthorized, url: wss://api.openai.com/v1/responses
        """

    /// VERBATIM stderr from a real `codex exec` run whose argument vector the
    /// CLI would not accept — the shape of a version skew, which is the
    /// likeliest way a reader who genuinely HAS the CLI still cannot use it.
    /// Exit code 2. This is the run that produces the reader's "error 0": the
    /// text matched none of `CodexExecOutput.failure`'s heuristics, so it
    /// became `.requestFailed` carrying these words — and these words are
    /// precisely what the reader needed and never saw.
    static let stderrFromACodexThatRefusedTheArguments = """
        error: unexpected argument '--not-a-real-flag' found

          tip: to pass '--not-a-real-flag' as a value, use '-- --not-a-real-flag'

        Usage: codex exec [OPTIONS] [PROMPT]
               codex exec [OPTIONS] <COMMAND> [ARGS]

        For more information, try '--help'.
        """

    /// The two fragments of the bridged NSError description. Neither may ever
    /// reach a reader. Matched on the ASCII stem of "couldn’t" so the check
    /// does not hinge on Foundation's curly apostrophe.
    static func readsLikeABridgedNSError(_ text: String) -> Bool {
        text.contains("MaintainModelProviderError")
            || text.contains("The operation couldn")
    }

    /// Something a reader can actually go and do. Deliberately broad — the
    /// wording is the fixer's to choose, the presence of an instruction is not.
    static func namesSomethingTheReaderCanDo(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return ["sign in", "signing in", "log in", "login", "connect",
                "install", "settings", "reconnect", "update"]
            .contains { lowercased.contains($0) }
    }

    // MARK: - The reader's exact alert

    /// The whole reported symptom, end to end, through the two real functions
    /// that produced it: the Tier C loop's reason string and the card's
    /// mapping. This is the string that was on the reader's screen.
    @Test func theReadersOwnAlertNeverCarriesTheBridgedNSErrorText() {
        let failureFromTheCLI = CodexExecOutput.failure(
            fromStandardError: Self.stderrFromACodexThatRefusedTheArguments,
            exitCode: 2
        )
        let reason = MaintainTierCFixer.modelCallFailureReason(for: failureFromTheCLI)
        let alert = OnDemandEditCoordinator.mappedFailure(reason: reason).userFacing

        #expect(
            !Self.readsLikeABridgedNSError(alert),
            "the reader's alert still hex-dumps the enum: \(alert)"
        )
        #expect(
            !alert.contains("error 0"),
            "the reader's alert still ends in a case index: \(alert)"
        )
    }

    // MARK: - The discarded explanation

    /// `.requestFailed`'s String payload is the whole point of the case. It is
    /// the CLI's own words, and it is what tells this reader that their codex
    /// is not the version Iris is calling — the one fact that would have
    /// answered "I have the codex CLI?".
    @Test func whatCodexActuallySaidReachesTheReaderInsteadOfACaseIndex() {
        let failureFromTheCLI = CodexExecOutput.failure(
            fromStandardError: Self.stderrFromACodexThatRefusedTheArguments,
            exitCode: 2
        )
        let reason = MaintainTierCFixer.modelCallFailureReason(for: failureFromTheCLI)

        #expect(
            reason.contains("unexpected argument"),
            "codex's own explanation was dropped; the reader got: \(reason)"
        )
        #expect(
            !Self.readsLikeABridgedNSError(reason),
            "the reason is still the bridged NSError: \(reason)"
        )
    }

    /// The same claim without the CLI in the way: any `.requestFailed` payload
    /// must survive the trip to the reader. This is the case index the reader
    /// literally saw.
    @Test func aRequestFailurePayloadIsNotThrownAway() {
        let reason = MaintainTierCFixer.modelCallFailureReason(
            for: MaintainModelProviderError.requestFailed("codex exec produced no assistant message")
        )

        #expect(
            reason.contains("codex exec produced no assistant message"),
            "the payload vanished; the reader got: \(reason)"
        )
        #expect(
            !Self.readsLikeABridgedNSError(reason),
            "the reason is still the bridged NSError: \(reason)"
        )
    }

    // MARK: - The missing credential

    /// `.noCredential` bridged to "error 1" and was exactly as unactionable.
    /// A reader who has no usable credential must be told what to go and do —
    /// and WHICH missing credential it is, because "codex isn't where Iris can
    /// look", "codex isn't signed in" and "there's no OpenAI key" have three
    /// different repairs and used to be one number. Every case is swept rather
    /// than one sampled: a case added later with no message of its own is how
    /// this regresses, and it should fail here rather than on a reader's screen.
    @Test func everyMissingCredentialSaysWhatToDoInsteadOfACaseIndex() {
        let everyWayACredentialCanBeMissing: [MaintainModelProviderError.MissingCredential] = [
            .codexCommandNotFound,
            .codexLoginNotUsable,
            .codexTurnedTheCallDown(codexSaid: "401 Unauthorized"),
            .openAIKeyNotSaved,
        ]
        var reasonsSeen: Set<String> = []

        for missingCredential in everyWayACredentialCanBeMissing {
            let reason = MaintainTierCFixer.modelCallFailureReason(
                for: MaintainModelProviderError.noCredential(missingCredential)
            )
            #expect(
                !Self.readsLikeABridgedNSError(reason),
                "\(missingCredential) still hex-dumps: \(reason)"
            )
            #expect(
                Self.namesSomethingTheReaderCanDo(reason),
                "\(missingCredential) says nothing the reader can act on: \(reason)"
            )
            reasonsSeen.insert(reason)
        }

        #expect(
            reasonsSeen.count == everyWayACredentialCanBeMissing.count,
            "two different missing credentials produced the same sentence — the defect this file exists for, with words instead of a digit"
        )
    }

    // MARK: - Three problems, one code

    /// A signed-out CLI and a CLI that refused its arguments are different
    /// problems with different fixes, and they used to be the same shrug with a
    /// different digit on the end. The signed-out one must talk about signing
    /// in; the argument one must repeat what the CLI said. Neither may be a
    /// number.
    @Test func aSignedOutCLIAndARefusedInvocationDoNotReadTheSame() {
        let signedOutAlert = OnDemandEditCoordinator.mappedFailure(
            reason: MaintainTierCFixer.modelCallFailureReason(
                for: CodexExecOutput.failure(
                    fromStandardError: Self.stderrFromACodexWithNoLogin, exitCode: 1
                )
            )
        ).userFacing
        let refusedInvocationAlert = OnDemandEditCoordinator.mappedFailure(
            reason: MaintainTierCFixer.modelCallFailureReason(
                for: CodexExecOutput.failure(
                    fromStandardError: Self.stderrFromACodexThatRefusedTheArguments, exitCode: 2
                )
            )
        ).userFacing

        #expect(
            !Self.readsLikeABridgedNSError(signedOutAlert),
            "signed-out reads as a code: \(signedOutAlert)"
        )
        #expect(
            Self.namesSomethingTheReaderCanDo(signedOutAlert),
            "signed-out tells the reader nothing to do: \(signedOutAlert)"
        )
        #expect(
            refusedInvocationAlert.contains("unexpected argument"),
            "the refused invocation dropped the CLI's own words: \(refusedInvocationAlert)"
        )
        #expect(
            signedOutAlert != refusedInvocationAlert,
            "two different problems produced one identical sentence"
        )
    }

    // MARK: - What the reader is quoted

    /// Quoting the tool is only worth doing if the quote is legible. The real
    /// signed-out stderr is the SAME 401 line seven times, differing only in
    /// its microsecond timestamp, and the flat `.suffix(300)` this used to be
    /// handed the reader one and a half of them starting mid-token
    /// ("::responses_websocket: failed to…"). A quote that reads like memory
    /// corruption is the same failure as a case index, one layer along.
    @Test func codexIsQuotedInWholeLinesWithItsRepeatsCollapsed() {
        let quoted = CodexExecOutput.quotableTail(
            ofStandardError: Self.stderrFromACodexWithNoLogin
        )

        #expect(
            quoted.hasPrefix("ERROR codex_api"),
            "the quote still starts mid-token: \(quoted)"
        )
        #expect(
            !quoted.contains("2026-08-30T"),
            "codex's log timestamps are still in the reader's sentence: \(quoted)"
        )
        // Two identical lines in, one out.
        #expect(
            quoted.components(separatedBy: "401 Unauthorized").count - 1 == 1,
            "the same line is quoted more than once: \(quoted)"
        )
        // And the line that actually names the problem leads, rather than being
        // pushed out by a `Usage:` block.
        #expect(
            CodexExecOutput.quotableTail(
                ofStandardError: Self.stderrFromACodexThatRefusedTheArguments
            ).hasPrefix("error: unexpected argument"),
            "the primary error was dropped in favour of boilerplate"
        )
    }
}
