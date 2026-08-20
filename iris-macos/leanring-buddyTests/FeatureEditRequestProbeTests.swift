//
//  FeatureEditRequestProbeTests.swift
//  leanring-buddyTests
//
//  The two model-derived §7 triggers: the probe's pure prompt/parse layer, the
//  three-call orchestration against a scripted provider, and — just as
//  load-bearing — every fail-open path, because the probe may only ever ADD a
//  question and must never block the describe flow the way a refusal would.
//  Also the reader-actionable failure wording this change exists for: a
//  rejected credential must surface as "reconnect it in settings", never as
//  the bridged NSError's "error 8".
//

import Foundation
import Testing
@testable import Iris

// MARK: - Pure parsing

@Suite struct FeatureEditRequestProbeParsingTests {

    @Test func aCleanOneLineAnswerParses() {
        let parsed = FeatureEditRequestProbe.parsedReasoningPassAnswer(
            #"{"implementation": "Add a Copy as Markdown item to the note context menu", "irreversible": false}"#
        )
        #expect(parsed?.implementationSummary.contains("context menu") == true)
        #expect(parsed?.impliesIrreversibleAction == false)
    }

    @Test func fencesAndSurroundingProseAreTolerated() {
        let parsed = FeatureEditRequestProbe.parsedReasoningPassAnswer("""
        Sure — here's my answer:
        ```json
        {"implementation": "Migrate the save file to a new schema", "irreversible": true}
        ```
        """)
        #expect(parsed?.impliesIrreversibleAction == true)
    }

    @Test func aBraceInsideAStringValueDoesNotUnbalanceTheScan() {
        let parsed = FeatureEditRequestProbe.parsedReasoningPassAnswer(
            #"{"implementation": "Render {placeholder} tokens in titles", "irreversible": false}"#
        )
        #expect(parsed?.implementationSummary.contains("{placeholder}") == true)
    }

    @Test func garbageAndMissingKeysParseToNilNeverAGuess() {
        #expect(FeatureEditRequestProbe.parsedReasoningPassAnswer("no json here at all") == nil)
        #expect(FeatureEditRequestProbe.parsedReasoningPassAnswer(#"{"irreversible": true}"#) == nil)
        #expect(FeatureEditRequestProbe.parsedReasoningPassAnswer(#"{"implementation": "", "irreversible": true}"#) == nil)
        #expect(FeatureEditRequestProbe.parsedReasoningPassAnswer(#"{"implementation": "x", "irreversible": "yes"}"#) == nil)
    }

    @Test func theAgreementVerdictReadsExactlyOneWord() {
        #expect(FeatureEditRequestProbe.parsedAgreementSaysSame("SAME") == true)
        #expect(FeatureEditRequestProbe.parsedAgreementSaysSame("different") == false)
        // Naming both words, or neither, is unusable and must fail open
        // upstream rather than be guessed at here.
        #expect(FeatureEditRequestProbe.parsedAgreementSaysSame("same but different") == nil)
        #expect(FeatureEditRequestProbe.parsedAgreementSaysSame("unclear") == nil)
    }
}

// MARK: - Orchestration (scripted provider, no network)

/// Replays canned turns, records every call, and can be told to throw —
/// the same stand-in shape the engine tests use, plus the failure lever the
/// probe's fail-open paths need.
@MainActor
private final class ScriptedProbeProvider: MaintainModelProviding {
    let displayName = "scripted-probe-mock"
    let isAvailable = true
    private let turns: [String]
    private let errorToThrow: Error?
    private(set) var callCount = 0

    init(_ turns: [String], throwing errorToThrow: Error? = nil) {
        self.turns = turns
        self.errorToThrow = errorToThrow
    }

    func respond(
        systemPrompt: String, conversation: [MaintainChatTurn], maximumOutputTokens: Int
    ) async throws -> String {
        if let errorToThrow { throw errorToThrow }
        defer { callCount += 1 }
        return callCount < turns.count ? turns[callCount] : ""
    }
}

@MainActor
@Suite struct FeatureEditRequestProbeOrchestrationTests {

    private func passAnswer(_ implementation: String, irreversible: Bool = false) -> String {
        #"{"implementation": "\#(implementation)", "irreversible": \#(irreversible)}"#
    }

    @Test func agreeingPassesAreQuietAndSkipTheJudge() async {
        let provider = ScriptedProbeProvider([
            passAnswer("Add a dark mode toggle in settings"),
            passAnswer("Add a dark mode toggle in settings"),
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "add dark mode", repoMapSummary: "", provider: provider
        )
        #expect(verdict == .allQuiet)
        // Literally-identical summaries need no judge — two calls, not three.
        #expect(provider.callCount == 2)
    }

    @Test func disagreeingPassesTheJudgeConfirmsAreAmbiguous() async {
        let provider = ScriptedProbeProvider([
            passAnswer("Add an export button that writes a CSV file"),
            passAnswer("Add automatic nightly export to iCloud"),
            "DIFFERENT",
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "add export", repoMapSummary: "", provider: provider
        )
        #expect(verdict.requestLooksAmbiguous)
        #expect(provider.callCount == 3)
    }

    @Test func differentlyWordedButJudgedSameStaysQuiet() async {
        let provider = ScriptedProbeProvider([
            passAnswer("Add a CSV export button to the toolbar"),
            passAnswer("Put an Export as CSV control in the toolbar"),
            "SAME",
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "add export", repoMapSummary: "", provider: provider
        )
        #expect(!verdict.requestLooksAmbiguous)
    }

    @Test func eitherPassFlaggingIrreversibilityIsEnough() async {
        let provider = ScriptedProbeProvider([
            passAnswer("Change the save-file schema", irreversible: true),
            passAnswer("Change the save-file schema", irreversible: false),
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "change the save format", repoMapSummary: "", provider: provider
        )
        #expect(verdict.impliesIrreversibleAction)
    }

    @Test func aThrowingProviderFailsOpenToAllQuiet() async {
        let provider = ScriptedProbeProvider([], throwing: AssistantTransportError.bringYourOwnKeyRejected)
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "anything", repoMapSummary: "", provider: provider
        )
        #expect(verdict == .allQuiet)
    }

    @Test func oneUnusablePassStillCarriesTheOthersIrreversibleFlagButNeverAmbiguity() async {
        let provider = ScriptedProbeProvider([
            "not json at all",
            passAnswer("Destructive migration of the database", irreversible: true),
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "migrate the db", repoMapSummary: "", provider: provider
        )
        // Self-consistency over one attempt is not a signal — ambiguity needs
        // both passes — but a parsed irreversibility flag is still real.
        #expect(!verdict.requestLooksAmbiguous)
        #expect(verdict.impliesIrreversibleAction)
    }

    @Test func anUnusableJudgeFailsOpenToNotAmbiguous() async {
        let provider = ScriptedProbeProvider([
            passAnswer("Add an export button"),
            passAnswer("Add scheduled exports"),
            "I couldn't really say, same but different",
        ])
        let verdict = await FeatureEditRequestProbe.probe(
            scrubbedRequest: "add export", repoMapSummary: "", provider: provider
        )
        #expect(!verdict.requestLooksAmbiguous)
    }
}

// MARK: - Reader-actionable failure wording

@Suite struct ModelCallFailureWordingTests {

    @Test func aRejectedCredentialSurfacesTheTransportsOwnAdviceNotErrorEight() {
        let reason = MaintainTierCFixer.modelCallFailureReason(
            for: AssistantTransportError.bringYourOwnKeyRejected
        )
        // The whole point: the reader must see what to DO, never the bridged
        // NSError's "(Iris.AssistantTransportError error 8.)".
        #expect(reason.hasPrefix("model credential rejected"))
        #expect(reason.contains("turned that key down"))
        #expect(!reason.contains("error 8"))
    }

    @Test func otherTransportErrorsAlsoSpeakTheTransportsVocabulary() {
        let reason = MaintainTierCFixer.modelCallFailureReason(
            for: AssistantTransportError.transportFailure(reason: "offline")
        )
        #expect(reason.hasPrefix("model call failed"))
        #expect(reason.contains("check your connection"))
    }

    @Test func aNonTransportErrorStillFallsBackToItsOwnDescription() {
        let reason = MaintainTierCFixer.modelCallFailureReason(
            for: NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        )
        #expect(reason == "model call failed: boom")
    }

    @Test func aRateLimitGetsTierCWordingNotTheFundedTiersAdvice() {
        let reason = MaintainTierCFixer.modelCallFailureReason(
            for: AssistantTransportError.rateLimited(retryAfterSeconds: 60)
        )
        #expect(reason.contains("rate-limiting"))
        // The transport's own message ends "add your own anthropic key" —
        // nonsense advice for a loop that already runs on the reader's key.
        #expect(!reason.contains("add your own anthropic key"))
    }

    @Test func theRateLimitWaitHonorsRetryAfterWithinItsClamp() {
        // The server's own Retry-After wins when it sent one…
        #expect(MaintainTierCFixer.rateLimitWaitSeconds(retryAfterSeconds: 5) == 5)
        // …the default fills in when it did not…
        #expect(MaintainTierCFixer.rateLimitWaitSeconds(retryAfterSeconds: nil)
            == MaintainTierCFixer.defaultRateLimitWaitSeconds)
        // …and the clamp keeps a zero or an hour-long answer inside what a
        // watched run should ever stall for.
        #expect(MaintainTierCFixer.rateLimitWaitSeconds(retryAfterSeconds: 0) == 1)
        #expect(MaintainTierCFixer.rateLimitWaitSeconds(retryAfterSeconds: 3600)
            == MaintainTierCFixer.maximumRateLimitWaitSeconds)
    }

    @Test func theCoordinatorMapsACredentialRejectionToTheSettingsOffer() {
        let mapped = OnDemandEditCoordinator.mappedFailure(
            reason: "model credential rejected: anthropic turned that key down. check it's still active and paste it again."
        )
        #expect(mapped.offersModelKeySetup)
        #expect(!mapped.wasBuildScriptBlock)
        #expect(mapped.userFacing.contains("settings"))
        #expect(mapped.userFacing.lowercased().contains("nothing changed"))
    }

    @Test func theOtherFailureMappingsNeverOfferTheSettingsTap() {
        let buildScript = OnDemandEditCoordinator.mappedFailure(reason: "blocked: build-script file edited")
        #expect(buildScript.wasBuildScriptBlock)
        #expect(!buildScript.offersModelKeySetup)

        let generic = OnDemandEditCoordinator.mappedFailure(reason: "model call failed: boom")
        #expect(!generic.offersModelKeySetup)
        #expect(generic.userFacing.contains("boom"))
    }
}
