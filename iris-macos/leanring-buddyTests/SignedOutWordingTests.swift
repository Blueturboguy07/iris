//
//  SignedOutWordingTests.swift
//  leanring-buddyTests
//
//  Founder report, in two parts. First: "if i am signed out just say im signed
//  out dont say anthropic turned that key down." Then, on seeing the first
//  attempt at fixing it: "yo its not the sign in."
//
//  The original incident is gone with the credential that caused it — that Mac's
//  only stored credential was a Claude Code OAuth token, which Iris is no longer
//  allowed to hold at all. What survives is the RULE the report established, and
//  it now applies to a different set of failures:
//
//    1. The real cause leads. Never a state that happens to also be true.
//    2. The alternative is offered only when it genuinely exists.
//    3. Never advice the reader cannot act on.
//
//  Rule 3 is why the old "you can also sign in to publik and use iris on us"
//  had to go rather than being carried across: with the funded tier removed,
//  signing in buys nobody a model, so offering it would be exactly the class of
//  mistake this suite was written to prevent.
//

import Foundation
import Testing
@testable import Iris

@Suite struct SignedOutWordingTests {

    // MARK: - A 401 is read against the credential that carried it

    @Test("each credential gets the failure that describes what actually happened")
    func a401IsReadAgainstTheCredentialThatCarriedIt() {
        func failure(for shape: AssistantTransport.CredentialShape) -> AssistantTransportError {
            AssistantTransportError.failure(
                forStatusCode: 401, serverErrorCode: nil,
                retryAfterHeaderValue: nil, credentialShape: shape
            )
        }
        #expect(failure(for: .aPastedAnthropicKey) == .bringYourOwnKeyRejected)
        #expect(failure(for: .aPublikAPIKey) == .publikAPIKeyRejected)
    }

    @Test("a transport reports the credential it carries")
    func aTransportKnowsItsOwnCredentialShape() {
        #expect(AssistantTransport.bringYourOwnKey(anthropicAPIKey: "sk-ant-x")
            .credentialShape == .aPastedAnthropicKey)
        #expect(AssistantTransport.publikAPI(
            key: PublikAPIKey("pk_live_abc123456789_0123456789abcdef0123456789abcdef")!,
            gatewayBaseURL: URL(string: "https://publikhq.com/api/v1")!
        ).credentialShape == .aPublikAPIKey)
    }

    // MARK: - What the reader is told

    /// Rule 1. The cause leads; switching provider is an afterthought, never
    /// the diagnosis.
    @Test("the cause leads and switching is only ever an alternative")
    func theCauseLeadsAndSwitchingIsSecondary() {
        for failure in [
            AssistantTransportError.bringYourOwnKeyRejected,
            AssistantTransportError.publikAPIKeyRejected,
        ] {
            let text = CompanionManager.wording(for: failure, anotherProviderIsAlreadySetUp: true)
            #expect(text.hasPrefix(failure.userFacingMessage),
                    "the real cause must come first: \(text)")
            #expect(text.contains("another one set up"),
                    "the alternative should still be offered: \(text)")
        }
    }

    /// Rule 2, and the direct descendant of "yo its not the sign in": a reader
    /// with nothing else configured must not be told to go and switch to it.
    @Test("a reader with no other provider is not told to switch to one")
    func noSecondProviderMeansNoOffer() {
        for failure in [
            AssistantTransportError.bringYourOwnKeyRejected,
            AssistantTransportError.publikAPIKeyRejected,
        ] {
            let text = CompanionManager.wording(for: failure, anotherProviderIsAlreadySetUp: false)
            #expect(text == failure.userFacingMessage)
            #expect(!text.contains("another one set up"),
                    "offered a provider that does not exist: \(text)")
        }
    }

    /// Rule 3, stated as a property rather than a case list: nothing anywhere in
    /// this enum may offer the funded tier, because there is no longer one.
    @Test("nothing offers free assistant usage any more")
    func nothingPromisesTheFundedTier() {
        let everyFailure: [AssistantTransportError] = [
            .noCredentialsAvailable, .publikAPINotSetUp, .publikAPIStarterNotYetDisclosed,
            .codexIsNotAnHTTPTransport, .codexNotUsable, .anthropicKeyNotSaved,
            .rateLimited(retryAfterSeconds: 30), .assistantUnavailable,
            .requestFailed(statusCode: 500), .bringYourOwnKeyRejected, .publikAPIKeyRejected,
            .transportFailure(reason: "offline"),
        ]
        for failure in everyFailure {
            for anotherProvider in [true, false] {
                let text = CompanionManager.wording(
                    for: failure, anotherProviderIsAlreadySetUp: anotherProvider
                ).lowercased()
                #expect(!text.contains("on us"), "still offering the funded tier: \(text)")
                #expect(!text.contains("use iris free"), "still offering the funded tier: \(text)")
            }
        }
    }

    /// Failures that are not about a credential keep the wording they had.
    @Test("unrelated failures are untouched")
    func otherFailuresAreUnchanged() {
        for failure: AssistantTransportError in [
            .assistantUnavailable,
            .rateLimited(retryAfterSeconds: 30),
            .transportFailure(reason: "offline"),
        ] {
            for anotherProvider in [true, false] {
                #expect(CompanionManager.wording(
                    for: failure, anotherProviderIsAlreadySetUp: anotherProvider
                ) == failure.userFacingMessage)
            }
        }
    }

    /// A reader with no credential at all must be pointed at all three ways in,
    /// since any of them is a real answer.
    @Test("no credential at all names every way in")
    func noCredentialNamesEveryRoute() {
        let text = AssistantTransportError.noCredentialsAvailable.userFacingMessage.lowercased()
        #expect(text.contains("publik api"))
        #expect(text.contains("key"))
        #expect(text.contains("codex"))
    }
}
