//
//  SignedOutWordingTests.swift
//  leanring-buddyTests
//
//  Founder report, in two parts. First: "if i am signed out just say im signed
//  out dont say anthropic turned that key down." Then, on seeing the first
//  attempt at fixing it: "yo its not the sign in."
//
//  The screenshot behind it: he asked Iris to "point at what i should click"
//  and got "anthropic turned that key down. check it's still active and paste
//  it again." This Mac's only stored credential is `anthropic-oauth-token` — a
//  Claude Code login, no pasted key anywhere — and those rotate every few
//  hours. So the sentence was wrong twice: there is no key, and there is
//  nothing to paste.
//
//  Cause: a 401 on the BYO route always became `bringYourOwnKeyRejected`,
//  whichever credential actually rode on the request. One status, three
//  meanings, one sentence.
//
//  The second half of the report is the part worth remembering. Leading with
//  "you're signed out" reads as a correct fix and is not one — it replaces a
//  wrong cause with an irrelevant one, and buries what actually broke. The
//  cause and its remedy lead; signing in is offered afterwards, and only when
//  it is genuinely available.
//

import Foundation
import Testing
@testable import Iris

@Suite struct SignedOutWordingTests {

    // MARK: - A 401 means three different things

    @Test("each credential gets the failure that describes what actually happened")
    func a401IsReadAgainstTheCredentialThatCarriedIt() {
        func failure(for shape: AssistantTransport.CredentialShape) -> AssistantTransportError {
            AssistantTransportError.failure(
                forStatusCode: 401, serverErrorCode: nil,
                retryAfterHeaderValue: nil, credentialShape: shape
            )
        }
        #expect(failure(for: .publiksFundedTier) == .signInRequired)
        #expect(failure(for: .aPastedAnthropicKey) == .bringYourOwnKeyRejected)
        // The whole point: this used to be `bringYourOwnKeyRejected` too.
        #expect(failure(for: .aClaudeCodeLogin) == .claudeCodeLoginExpired)
    }

    @Test("a transport reports the credential it carries")
    func aTransportKnowsItsOwnCredentialShape() {
        #expect(AssistantTransport.bringYourOwnKey(anthropicAPIKey: "sk-ant-x")
            .credentialShape == .aPastedAnthropicKey)
        #expect(AssistantTransport.bringYourOwnOAuthToken(anthropicOAuthToken: "sk-ant-oat-x")
            .credentialShape == .aClaudeCodeLogin)
    }

    // MARK: - What the reader is told

    /// THE ACTUAL REPORT. This Mac's only stored credential is
    /// `anthropic-oauth-token` — a Claude Code login, no pasted key — and those
    /// tokens rotate every few hours. The reader asked Iris to point at
    /// something, the token had lapsed, and they were told to check a key and
    /// paste it again: wrong twice, because there is no key and nothing to
    /// paste. The message has to name the thing that actually expired.
    @Test("an expired Claude Code login is named, not blamed on a key")
    func anExpiredLoginIsNotCalledABadKey() {
        for signedIn in [true, false] {
            let text = CompanionManager.wording(
                for: .claudeCodeLoginExpired, theReaderIsSignedIntoPublik: signedIn
            )
            #expect(text.contains("claude code login"), "did not name it: \(text)")
            #expect(text.contains("reconnect"), "did not say what to do: \(text)")
            #expect(!text.contains("turned that key down"), "still blaming a key: \(text)")
            #expect(!text.lowercased().contains("paste"), "there is nothing to paste: \(text)")
        }
    }

    /// "yo its not the sign in." The cause and its fix lead; signing in is an
    /// alternative offered afterwards, never the diagnosis.
    @Test("the cause leads and sign-in is only ever an alternative")
    func theCauseLeadsAndSignInIsSecondary() {
        for failure in [
            AssistantTransportError.bringYourOwnKeyRejected,
            AssistantTransportError.claudeCodeLoginExpired,
        ] {
            let text = CompanionManager.wording(for: failure, theReaderIsSignedIntoPublik: false)
            #expect(text.hasPrefix(failure.userFacingMessage),
                    "the real cause must come first: \(text)")
            #expect(!text.hasPrefix("you're signed out"),
                    "signing in is not the diagnosis: \(text)")
            #expect(text.contains("sign in"), "the alternative should still be offered: \(text)")
        }
    }

    /// THE REASON SIGN-IN STATE IS READ RATHER THAN INFERRED FROM THE ROUTE.
    /// Tier C and the fix ladder run on the BYO transport even for a signed-IN
    /// reader, so offering "sign in" there is advice they have already taken.
    @Test("a signed-in reader is never told to sign in")
    func aSignedInReaderIsNeverToldToSignIn() {
        for failure in [
            AssistantTransportError.bringYourOwnKeyRejected,
            AssistantTransportError.claudeCodeLoginExpired,
        ] {
            let text = CompanionManager.wording(for: failure, theReaderIsSignedIntoPublik: true)
            #expect(text == failure.userFacingMessage)
            #expect(!text.contains("sign in"), "told a signed-in reader to sign in: \(text)")
        }
    }

    /// Everything else keeps the wording it already had, signed in or out — the
    /// change is scoped to the two failures that were describing a state as a
    /// credential fault.
    @Test("unrelated failures are untouched")
    func otherFailuresAreUnchanged() {
        for failure: AssistantTransportError in [
            .noCredentialsAvailable, .signInRequired, .assistantUnavailable,
            .rateLimited(retryAfterSeconds: 30), .transportFailure(reason: "offline"),
        ] {
            #expect(CompanionManager.wording(for: failure, theReaderIsSignedIntoPublik: false)
                == failure.userFacingMessage)
        }
    }

    /// A reader with no credential at all was already told the right thing, and
    /// must keep being told it — this is the state the report was NOT about.
    @Test("no credential at all still points at both ways in")
    func noCredentialStillNamesBothRoutes() {
        let text = AssistantTransportError.noCredentialsAvailable.userFacingMessage
        #expect(text.contains("sign in"))
        #expect(text.contains("key"))
    }
}
