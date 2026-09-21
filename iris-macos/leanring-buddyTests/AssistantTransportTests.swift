//
//  AssistantTransportTests.swift
//  leanring-buddyTests
//
//  The property this suite exists for: the reader's own Anthropic key never
//  reaches a publik host, and the publik gateway key never reaches anything
//  else.
//
//  Two credentials now legitimately travel as `x-api-key`, which is exactly
//  when a rule like this stops being obvious and starts needing a test. The
//  old suite could assert "this header only ever goes to Anthropic"; that
//  sentence is no longer true, and a weaker version of it ("well, it goes to
//  one of two places") would not catch the mistake that matters — sending the
//  reader's `sk-ant-…` to publik. So the assertions below are stated per
//  credential, both directions, including the crossed pairs that must fail.
//

import Foundation
import Testing
@testable import Iris

@Suite("Assistant transport")
struct AssistantTransportTests {

    static let fakeAnthropicKey = "sk-ant-api03-not-a-real-key"
    static let fakePublikKey = "pk_live_abc123456789_0123456789abcdef0123456789abcdef"
    static let publikGatewayURL = URL(string: "https://publikhq.com/api/v1")!

    // MARK: The publik key type

    @Test func aPublikKeyTypeRefusesAnAnthropicKey() {
        // The whole point of the type: the one request builder that takes a
        // destination cannot be handed the reader's Anthropic credential,
        // however badly a caller holds it wrong.
        #expect(PublikAPIKey(Self.fakeAnthropicKey) == nil)
        #expect(PublikAPIKey("") == nil)
        #expect(PublikAPIKey("definitely not a key") == nil)
        #expect(PublikAPIKey(Self.fakePublikKey) != nil)
    }

    @Test func aPublikKeyTypeAcceptsATestKeyToo() {
        #expect(PublikAPIKey("pk_test_abc123456789_0123456789abcdef0123456789abcdef") != nil)
    }

    // MARK: Where each credential is allowed to go

    @Test func theReadersAnthropicKeyGoesOnlyToAnthropic() async throws {
        let transport = AssistantTransport.bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicKey)
        let request = try await transport.makeChatRequest()

        #expect(request.url?.host == AssistantTransport.anthropicAPIHost)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.fakeAnthropicKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version")
            == AssistantTransport.anthropicAPIVersion)
    }

    @Test func thePublikKeyGoesToTheGateway() async throws {
        let key = try #require(PublikAPIKey(Self.fakePublikKey))
        let transport = AssistantTransport.publikAPI(key: key, gatewayBaseURL: Self.publikGatewayURL)
        let request = try await transport.makeChatRequest()

        #expect(request.url?.absoluteString == "https://publikhq.com/api/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == Self.fakePublikKey)
    }

    @Test func theGateIsAnAnthropicKeyHeadedAnywhereButAnthropic() {
        var smugglingRequest = URLRequest(url: URL(string: "https://publikhq.com/api/v1/messages")!)
        smugglingRequest.setValue(Self.fakeAnthropicKey, forHTTPHeaderField: "x-api-key")

        #expect(throws: AssistantTransportError.self) {
            _ = try AssistantTransport.validatedRequest(smugglingRequest)
        }
    }

    @Test func theGateIsAlsoAPublikKeyHeadedAnywhereButPublik() {
        // The mirror image, and it matters for the same reason: a publik key is
        // the reader's money, and handing it to a third party is the same class
        // of mistake as leaking the Anthropic one.
        var strayRequest = URLRequest(url: URL(string: "https://example.com/v1/messages")!)
        strayRequest.setValue(Self.fakePublikKey, forHTTPHeaderField: "x-api-key")

        #expect(throws: AssistantTransportError.self) {
            _ = try AssistantTransport.validatedRequest(strayRequest)
        }
    }

    @Test func anAnthropicKeyMayNotRideToAnAttackersHost() {
        for attemptedHost in ["evil.example", "publikhq.com.evil.example", "api.anthropic.com.evil.example"] {
            var request = URLRequest(url: URL(string: "https://\(attemptedHost)/v1/messages")!)
            request.setValue(Self.fakeAnthropicKey, forHTTPHeaderField: "x-api-key")
            #expect(throws: AssistantTransportError.self, "host \(attemptedHost)") {
                _ = try AssistantTransport.validatedRequest(request)
            }
        }
    }

    @Test func aRequestCarryingNoCredentialIsNotThisGatesBusiness() throws {
        let plainRequest = URLRequest(url: URL(string: "https://publikhq.com/api/iris/apps")!)
        let validated = try AssistantTransport.validatedRequest(plainRequest)
        #expect(validated.url == plainRequest.url)
    }

    @Test func localhostCountsAsPublikForADevelopmentBuild() throws {
        var request = URLRequest(url: URL(string: "http://localhost:3000/api/v1/messages")!)
        request.setValue(Self.fakePublikKey, forHTTPHeaderField: "x-api-key")
        let validated = try AssistantTransport.validatedRequest(request)
        #expect(validated.value(forHTTPHeaderField: "x-api-key") == Self.fakePublikKey)
    }

    // MARK: Choosing a provider

    @Test func anExplicitChoiceWinsOverWhatElseIsLyingAround() {
        // The bug this replaces: being signed in silently beat a key the reader
        // had pasted themselves, so somebody who deliberately connected their
        // own account could never reach it.
        let selection = AssistantTransport.selectTransport(
            preference: .anthropicKey,
            publikAPIKey: Self.fakePublikKey,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: true,
            storedAnthropicAPIKey: Self.fakeAnthropicKey,
            codexIsUsable: true
        )
        guard case .success(.bringYourOwnKey(let chosenKey)) = selection else {
            Issue.record("expected the reader's own key to win")
            return
        }
        #expect(chosenKey == Self.fakeAnthropicKey)
    }

    @Test func aBrokenChoiceDoesNotSilentlySpendSomebodyElsesMoney() {
        // The rule from docs/assistant-credentials.md: a chosen provider that
        // has stopped working says what broke rather than quietly switching to
        // another account.
        let selection = AssistantTransport.selectTransport(
            preference: .anthropicKey,
            publikAPIKey: Self.fakePublikKey,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: true,
            storedAnthropicAPIKey: nil,
            codexIsUsable: false
        )
        guard case .failure(let failure) = selection else {
            Issue.record("expected a failure, not a fallback onto the publik key")
            return
        }
        #expect(failure == .anthropicKeyNotSaved)
    }

    @Test func withNoPreferenceThePublikGatewayLeads() {
        let selection = AssistantTransport.selectTransport(
            preference: nil,
            publikAPIKey: Self.fakePublikKey,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: true,
            storedAnthropicAPIKey: Self.fakeAnthropicKey,
            codexIsUsable: true
        )
        guard case .success(.publikAPI) = selection else {
            Issue.record("expected publik API to lead when nothing was chosen")
            return
        }
    }

    @Test func withNoPreferenceAndNoPublikKeyTheReadersOwnKeyIsNext() {
        let selection = AssistantTransport.selectTransport(
            preference: nil,
            publikAPIKey: nil,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: false,
            storedAnthropicAPIKey: Self.fakeAnthropicKey,
            codexIsUsable: true
        )
        guard case .success(.bringYourOwnKey) = selection else {
            Issue.record("expected the reader's own key")
            return
        }
    }

    @Test func aStarterThatHasNotBeenDisclosedIsNotSpent() {
        // CONTRACT section 12 item 4, enforced where it cannot be forgotten:
        // a provisioned key whose card has not been shown cannot build a
        // request at all.
        let selection = AssistantTransport.selectTransport(
            preference: .publikAPI,
            publikAPIKey: Self.fakePublikKey,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: false,
            storedAnthropicAPIKey: nil,
            codexIsUsable: false
        )
        guard case .failure(let failure) = selection else {
            Issue.record("expected the undisclosed starter to be refused")
            return
        }
        #expect(failure == .publikAPIStarterNotYetDisclosed)
    }

    @Test func nothingSetUpAtAllIsItsOwnState() {
        let selection = AssistantTransport.selectTransport(
            preference: nil,
            publikAPIKey: nil,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: false,
            storedAnthropicAPIKey: nil,
            codexIsUsable: false
        )
        guard case .failure(let failure) = selection else {
            Issue.record("expected a no-credentials failure")
            return
        }
        #expect(failure == .noCredentialsAvailable)
    }

    @Test func codexIsNotAnHTTPTransportAndSaysSo() {
        // Codex answers through its own CLI. It is a real provider the reader
        // can pick, but it never becomes an AssistantTransport — the caller is
        // meant to have routed it to the subprocess responder before asking.
        let selection = AssistantTransport.selectTransport(
            preference: .codex,
            publikAPIKey: nil,
            publikGatewayBaseURL: Self.publikGatewayURL,
            publikKeyMaySpend: false,
            storedAnthropicAPIKey: nil,
            codexIsUsable: true
        )
        guard case .failure(let failure) = selection else {
            Issue.record("expected codex to refuse to be an HTTP transport")
            return
        }
        #expect(failure == .codexIsNotAnHTTPTransport)
    }

    // MARK: Model aliases

    @Test func thePublikRouteAsksForAliasesAndTheDirectRouteDoesNot() {
        let key = PublikAPIKey(Self.fakePublikKey)!
        #expect(AssistantTransport.publikAPI(key: key, gatewayBaseURL: Self.publikGatewayURL)
            .requiresPublikModelAliases)
        #expect(AssistantTransport.bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicKey)
            .requiresPublikModelAliases == false)
    }

    @Test func modelNamesMapOntoTheGatewaysThreeTiers() {
        #expect(PublikAPIModelAlias.alias(forIrisModelName: "claude-haiku-4-5") == PublikAPIModelAlias.fast)
        #expect(PublikAPIModelAlias.alias(forIrisModelName: "claude-opus-4-1") == PublikAPIModelAlias.smart)
        #expect(PublikAPIModelAlias.alias(forIrisModelName: "claude-sonnet-4-6") == PublikAPIModelAlias.balanced)
        // A model the picker gains later degrades to a sensible tier rather
        // than breaking the route.
        #expect(PublikAPIModelAlias.alias(forIrisModelName: "something-new") == PublikAPIModelAlias.balanced)
    }

    // MARK: Failure mapping

    @Test func a401IsExplainedInTermsOfTheCredentialThatWasUsed() {
        let publikRejection = AssistantTransportError.failure(
            forStatusCode: 401,
            serverErrorCode: nil,
            retryAfterHeaderValue: nil,
            credentialShape: .aPublikAPIKey
        )
        #expect(publikRejection == .publikAPIKeyRejected)

        let anthropicRejection = AssistantTransportError.failure(
            forStatusCode: 401,
            serverErrorCode: nil,
            retryAfterHeaderValue: nil,
            credentialShape: .aPastedAnthropicKey
        )
        #expect(anthropicRejection == .bringYourOwnKeyRejected)
    }

    @Test func a402CarriesTheServersOwnSentenceAndExactlyOneLink() {
        let body = Data("""
        {"type":"error","error":{"type":"insufficient_credit",
        "message":"You're out of credit. Link this computer and pick a plan at the link below.",
        "top_up_url":"https://publikhq.com/claim/abc123"}}
        """.utf8)

        let failure = AssistantTransportError.failure(
            forStatusCode: 402,
            serverErrorCode: nil,
            retryAfterHeaderValue: nil,
            credentialShape: .aPublikAPIKey,
            responseBody: body
        )
        guard case .publikAPIOutOfCredit(let insufficientCredit) = failure else {
            Issue.record("expected the 402 to be recognised")
            return
        }
        #expect(insufficientCredit.message.contains("out of credit"))
        #expect(insufficientCredit.linkURLString == "https://publikhq.com/claim/abc123")
        // Rendered verbatim — Iris writes no copy of its own for this state.
        #expect(failure.userFacingMessage == insufficientCredit.message)
        #expect(failure.oneLinkToOffer == "https://publikhq.com/claim/abc123")
    }

    @Test func a402WeCannotReadDoesNotInventCopy() {
        let failure = AssistantTransportError.failure(
            forStatusCode: 402,
            serverErrorCode: nil,
            retryAfterHeaderValue: nil,
            credentialShape: .aPublikAPIKey,
            responseBody: Data("not json at all".utf8)
        )
        #expect(failure == .requestFailed(statusCode: 402))
    }

    @Test func a429CarriesTheRetryDelay() {
        let failure = AssistantTransportError.failure(
            forStatusCode: 429,
            serverErrorCode: nil,
            retryAfterHeaderValue: "45",
            credentialShape: .aPublikAPIKey
        )
        #expect(failure == .rateLimited(retryAfterSeconds: 45))
        #expect(failure.userFacingMessage.contains("45 seconds"))
    }

    @Test func everyFailureSaysSomethingAReaderCanActOn() {
        // No case may fall through to an empty string or a status code: a
        // reader was once shown "(… error 8.)" and had nothing to do about it.
        let everyFailure: [AssistantTransportError] = [
            .noCredentialsAvailable,
            .publikAPINotSetUp,
            .publikAPIStarterNotYetDisclosed,
            .codexIsNotAnHTTPTransport,
            .codexNotUsable,
            .anthropicKeyNotSaved,
            .rateLimited(retryAfterSeconds: nil),
            .publikAPIOutOfCredit(PublikAPIInsufficientCredit(message: "out of credit", linkURLString: nil)),
            .assistantUnavailable,
            .requestFailed(statusCode: 500),
            .bringYourOwnKeyRejected,
            .publikAPIKeyRejected,
            .transportFailure(reason: "offline"),
            .bringYourOwnKeyWouldLeaveAnthropic(attemptedHost: "evil.example"),
            .publikKeyWouldLeavePublik(attemptedHost: "evil.example"),
        ]
        for failure in everyFailure {
            #expect(!failure.userFacingMessage.isEmpty, "\(failure)")
            #expect(!failure.userFacingMessage.contains("error 8"), "\(failure)")
        }
    }

    // MARK: The system field

    @Test func theSystemPromptIsAPlainStringOnEveryRoute() {
        // It used to become an array on the Claude Code OAuth route, which
        // needed Claude Code's own identity sentence first. That route is gone.
        for transport in [
            AssistantTransport.bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicKey),
            AssistantTransport.publikAPI(
                key: PublikAPIKey(Self.fakePublikKey)!,
                gatewayBaseURL: Self.publikGatewayURL
            ),
        ] {
            let systemField = ClaudeAPI.systemFieldValue(for: transport, systemPrompt: "be helpful")
            #expect(systemField as? String == "be helpful")
        }
    }
}
