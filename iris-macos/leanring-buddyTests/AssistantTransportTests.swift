//
//  AssistantTransportTests.swift
//  leanring-buddyTests
//
//  The security property `AssistantTransport` exists to protect —
//  "the user's own Anthropic key is never sent to any publik host"
//  (docs/iris-assistant-protocol.md section 1, where losing it is called a
//  ship-blocker) — is not something a reader can confirm by looking at a
//  request in a debugger once. It is asserted here, from both directions, so a
//  later refactor that merges the two request builders fails loudly.
//

import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// The helpers under test are main-actor isolated, so the suite has to be too.
@MainActor
struct AssistantTransportTests {

    // MARK: - Fixtures

    /// A publik origin of the shape `configuredPublikBaseURL` produces.
    private static let publikBaseURL = URL(string: "https://publikhq.com")!

    /// Stands in for a real Supabase access token. Its only requirement is
    /// being non-empty, which is what the transport actually checks.
    private static let fakeSupabaseAccessToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.fake.token"

    /// Shaped like a real key so a failure message reads plausibly, but this
    /// value is never sent anywhere — no test here touches the network.
    private static let fakeAnthropicAPIKey = "sk-ant-api03-not-a-real-key-0000000000"

    private static func fundedTransport(
        publikBaseURL: URL = AssistantTransportTests.publikBaseURL,
        accessToken: String? = AssistantTransportTests.fakeSupabaseAccessToken
    ) -> AssistantTransport {
        .funded(publikBaseURL: publikBaseURL, currentAccessTokenProvider: { accessToken })
    }

    /// Every host this app has any reason to talk to that is NOT Anthropic.
    /// The BYO key must be absent from a request aimed at any of them.
    private static let everyPublikHostTheKeyMustNeverReach = [
        "https://publikhq.com",
        "https://www.publikhq.com",
        "http://localhost:3000",
        "http://127.0.0.1:3000",
        "https://gcbxnxwwuuqsypwevfgi.supabase.co",
    ]

    // MARK: - The funded route

    @Test func theFundedTransportTargetsPublikAndCarriesOnlyABearerToken() async throws {
        let fundedRequest = try await Self.fundedTransport().makeChatRequest()

        #expect(fundedRequest.url?.host == "publikhq.com")
        #expect(fundedRequest.url?.path == "/api/assistant/chat")
        #expect(fundedRequest.httpMethod == "POST")
        #expect(fundedRequest.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(Self.fakeSupabaseAccessToken)")

        // The header that carries the user's own key must not exist on this
        // route at all — not empty, absent.
        #expect(fundedRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(fundedRequest.value(forHTTPHeaderField: "anthropic-version") == nil)
    }

    @Test func theFundedRouteHonorsALocalDevelopmentOrigin() async throws {
        let localDevelopmentTransport = Self.fundedTransport(
            publikBaseURL: URL(string: "http://localhost:3000")!
        )
        let fundedRequest = try await localDevelopmentTransport.makeChatRequest()

        #expect(fundedRequest.url?.absoluteString == "http://localhost:3000/api/assistant/chat")
        #expect(fundedRequest.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test func aFundedRequestWithNoLiveAccessTokenAsksForSignInRatherThanSendingNothing() async throws {
        let transportWithNoToken = Self.fundedTransport(accessToken: nil)

        await #expect(throws: AssistantTransportError.signInRequired) {
            _ = try await transportWithNoToken.makeChatRequest()
        }
    }

    @Test func theFundedRouteDoesNotSendAModelTheServerWillIgnore() async throws {
        #expect(Self.fundedTransport().shouldSendModelInRequestBody == false)
        #expect(AssistantTransport
            .bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicAPIKey)
            .shouldSendModelInRequestBody)
    }

    // MARK: - The bring-your-own-key route

    @Test func theBringYourOwnKeyTransportTargetsAnthropicDirectly() async throws {
        let directRequest = try await AssistantTransport
            .bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicAPIKey)
            .makeChatRequest()

        #expect(directRequest.url?.host == "api.anthropic.com")
        #expect(directRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(directRequest.url?.scheme == "https")
        #expect(directRequest.value(forHTTPHeaderField: "x-api-key") == Self.fakeAnthropicAPIKey)
        #expect(directRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        // Publik's own credential has no business on this route either.
        #expect(directRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// THE PROPERTY. Stated as directly as it can be stated.
    @Test func theBringYourOwnKeyRequestNeverPointsAtAPublikHost() async throws {
        let directRequest = try await AssistantTransport
            .bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicAPIKey)
            .makeChatRequest()

        let destinationHost = try #require(directRequest.url?.host?.lowercased())
        #expect(destinationHost == AssistantTransport.anthropicAPIHost)

        for publikHostTheKeyMustNeverReach in Self.everyPublikHostTheKeyMustNeverReach {
            let forbiddenHost = try #require(URL(string: publikHostTheKeyMustNeverReach)?.host?.lowercased())
            #expect(destinationHost != forbiddenHost)
        }

        // And the whole URL, not just the host — a path or a query cannot smuggle
        // the destination somewhere else either.
        let requestedURLString = try #require(directRequest.url?.absoluteString)
        #expect(!requestedURLString.contains("publikhq"))
        #expect(!requestedURLString.contains("supabase"))
        #expect(!requestedURLString.contains("localhost"))
    }

    /// The same property from the other side: a key can never appear on a
    /// request whose host is not Anthropic, no matter who built that request.
    @Test func aRequestToAnyNonAnthropicHostIsRefusedIfItCarriesTheUsersKey() async throws {
        for publikHostTheKeyMustNeverReach in Self.everyPublikHostTheKeyMustNeverReach {
            var smuggledRequest = URLRequest(
                url: URL(string: "\(publikHostTheKeyMustNeverReach)/api/assistant/chat")!
            )
            smuggledRequest.httpMethod = "POST"
            smuggledRequest.setValue(Self.fakeAnthropicAPIKey, forHTTPHeaderField: "x-api-key")

            #expect(throws: AssistantTransportError.self) {
                _ = try AssistantTransport.validatedRequest(smuggledRequest)
            }
        }
    }

    @Test func theGateLetsThroughTheTwoRequestsThatAreActuallyLegitimate() async throws {
        // A key going to Anthropic is fine.
        var anthropicRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        anthropicRequest.setValue(Self.fakeAnthropicAPIKey, forHTTPHeaderField: "x-api-key")
        #expect(throws: Never.self) {
            _ = try AssistantTransport.validatedRequest(anthropicRequest)
        }

        // A bearer token going to publik is fine.
        var publikRequest = URLRequest(url: URL(string: "https://publikhq.com/api/assistant/chat")!)
        publikRequest.setValue("Bearer \(Self.fakeSupabaseAccessToken)", forHTTPHeaderField: "Authorization")
        #expect(throws: Never.self) {
            _ = try AssistantTransport.validatedRequest(publikRequest)
        }
    }

    // MARK: - The bring-your-own OAuth-token route (Claude Code login)

    /// Shaped like a real long-lived Claude Code token; never sent anywhere here.
    private static let fakeAnthropicOAuthToken = "sk-ant-oat01-not-a-real-token-000000000000000000"

    @Test func theOAuthTokenTransportTargetsAnthropicWithBearerAndTheOAuthBeta() async throws {
        let directRequest = try await AssistantTransport
            .bringYourOwnOAuthToken(anthropicOAuthToken: Self.fakeAnthropicOAuthToken)
            .makeChatRequest()

        #expect(directRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        // The OAuth token authenticates as a Bearer, NOT x-api-key.
        #expect(directRequest.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(Self.fakeAnthropicOAuthToken)")
        #expect(directRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        // The beta header is what makes Anthropic accept the token, and what the
        // gate keys off to keep it away from any publik host.
        #expect(directRequest.value(forHTTPHeaderField: "anthropic-beta")
            == AssistantTransport.anthropicOAuthBetaHeaderValue)
        #expect(directRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(AssistantTransport
            .bringYourOwnOAuthToken(anthropicOAuthToken: Self.fakeAnthropicOAuthToken)
            .shouldSendModelInRequestBody)
    }

    /// THE PROPERTY, for the OAuth token: it is the user's own credential too, so
    /// a request carrying the OAuth beta header may only ever reach Anthropic.
    @Test func anOAuthTokenRequestIsRefusedIfItWouldLeaveAnthropic() async throws {
        for publikHostTheTokenMustNeverReach in Self.everyPublikHostTheKeyMustNeverReach {
            var smuggledRequest = URLRequest(
                url: URL(string: "\(publikHostTheTokenMustNeverReach)/api/assistant/chat")!
            )
            smuggledRequest.httpMethod = "POST"
            smuggledRequest.setValue("Bearer \(Self.fakeAnthropicOAuthToken)", forHTTPHeaderField: "Authorization")
            smuggledRequest.setValue(
                AssistantTransport.anthropicOAuthBetaHeaderValue, forHTTPHeaderField: "anthropic-beta"
            )

            #expect(throws: AssistantTransportError.self) {
                _ = try AssistantTransport.validatedRequest(smuggledRequest)
            }
        }

        // And the legitimate one still passes.
        var anthropicRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        anthropicRequest.setValue("Bearer \(Self.fakeAnthropicOAuthToken)", forHTTPHeaderField: "Authorization")
        anthropicRequest.setValue(
            AssistantTransport.anthropicOAuthBetaHeaderValue, forHTTPHeaderField: "anthropic-beta"
        )
        #expect(throws: Never.self) {
            _ = try AssistantTransport.validatedRequest(anthropicRequest)
        }
    }

    // MARK: - Choosing a route

    @Test func fundedWinsWhenSignedInAndTheStoredKeyIsTheFallback() async throws {
        let signedInSelection = AssistantTransport.selectTransport(
            isSignedIn: true,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: Self.fakeAnthropicAPIKey,
            currentAccessTokenProvider: { Self.fakeSupabaseAccessToken }
        )
        guard case .success(.funded) = signedInSelection else {
            Issue.record("a signed-in user should be served by the funded tier")
            return
        }

        let signedOutWithKeySelection = AssistantTransport.selectTransport(
            isSignedIn: false,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: Self.fakeAnthropicAPIKey,
            currentAccessTokenProvider: { nil }
        )
        guard case .success(.bringYourOwnKey(let selectedKey)) = signedOutWithKeySelection else {
            Issue.record("a stored key should be used when nobody is signed in")
            return
        }
        #expect(selectedKey == Self.fakeAnthropicAPIKey)
    }

    @Test func aClaudeCodeOAuthTokenIsTheBYOFallbackBelowAPastedKey() async throws {
        // Signed out, only an OAuth token connected → the OAuth route.
        let oauthOnlySelection = AssistantTransport.selectTransport(
            isSignedIn: false,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: nil,
            storedAnthropicOAuthToken: Self.fakeAnthropicOAuthToken,
            currentAccessTokenProvider: { nil }
        )
        guard case .success(.bringYourOwnOAuthToken(let selectedToken)) = oauthOnlySelection else {
            Issue.record("a connected Claude Code token should be used when it is the only credential")
            return
        }
        #expect(selectedToken == Self.fakeAnthropicOAuthToken)

        // Both present → the pasted key wins (it is the plainer credential).
        let bothSelection = AssistantTransport.selectTransport(
            isSignedIn: false,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: Self.fakeAnthropicAPIKey,
            storedAnthropicOAuthToken: Self.fakeAnthropicOAuthToken,
            currentAccessTokenProvider: { nil }
        )
        guard case .success(.bringYourOwnKey) = bothSelection else {
            Issue.record("a pasted API key should win over an OAuth token when both are present")
            return
        }

        // Signed in → still funded, regardless of a connected token.
        let signedInSelection = AssistantTransport.selectTransport(
            isSignedIn: true,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: nil,
            storedAnthropicOAuthToken: Self.fakeAnthropicOAuthToken,
            currentAccessTokenProvider: { Self.fakeSupabaseAccessToken }
        )
        guard case .success(.funded) = signedInSelection else {
            Issue.record("funded should still win for a signed-in user even with a connected token")
            return
        }
    }

    @Test func neitherCredentialIsAStateTheUserIsToldAboutRatherThanASilentFailure() async throws {
        let emptySelection = AssistantTransport.selectTransport(
            isSignedIn: false,
            publikBaseURL: Self.publikBaseURL,
            storedAnthropicAPIKey: nil,
            currentAccessTokenProvider: { nil }
        )

        guard case .failure(let selectionFailure) = emptySelection else {
            Issue.record("with no credentials at all there is no transport to return")
            return
        }
        #expect(selectionFailure == .noCredentialsAvailable)
        // The message has to name both ways out, because both are available.
        #expect(selectionFailure.userFacingMessage.contains("sign in"))
        #expect(selectionFailure.userFacingMessage.contains("anthropic key"))
    }

    // MARK: - PKCE

    @Test func theCodeChallengeIsSHA256OfTheVerifierInBase64URLWithoutPadding() async throws {
        // The worked example from RFC 7636 appendix B. Matching it proves the
        // hash, the alphabet, and the padding rule all at once.
        let rfc7636CodeVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let rfc7636CodeChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

        #expect(PKCECodeChallenge.codeChallenge(forCodeVerifier: rfc7636CodeVerifier)
            == rfc7636CodeChallenge)
    }

    @Test func base64URLEncodingUsesTheURLSafeAlphabetAndNoPadding() async throws {
        // Bytes chosen because standard base64 encodes them as "++++/////w==",
        // which contains every character the URL-safe alphabet has to replace
        // plus the padding that has to disappear.
        let bytesThatExerciseEveryReplacement = Data([
            0xFB, 0xEF, 0xBE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ])
        let encoded = PKCECodeChallenge.base64URLEncodedWithoutPadding(bytesThatExerciseEveryReplacement)

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(encoded.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        })
    }

    @Test func everyVerifierIsFreshAndLongEnoughToBeWorthSomething() async throws {
        let firstCodeVerifier = PKCECodeChallenge.generateCodeVerifier()
        let secondCodeVerifier = PKCECodeChallenge.generateCodeVerifier()

        #expect(firstCodeVerifier != secondCodeVerifier)
        // RFC 7636 requires 43-128 characters. 64 random bytes base64url to 86.
        #expect(firstCodeVerifier.count >= 43)
        #expect(firstCodeVerifier.count <= 128)
        #expect(!firstCodeVerifier.contains("="))
    }

    @Test func theAuthorizationURLCarriesTheChallengeTheCallbackWillBeCheckedAgainst() async throws {
        let codeVerifier = PKCECodeChallenge.generateCodeVerifier()
        let codeChallenge = PKCECodeChallenge.codeChallenge(forCodeVerifier: codeVerifier)
        let opaqueStateToken = "state-token-for-this-attempt"

        let authorizationURL = try AccountService.authorizationURL(
            supabaseProjectURL: URL(string: "https://project.supabase.co")!,
            provider: .google,
            codeChallenge: codeChallenge,
            opaqueStateToken: opaqueStateToken
        )

        let authorizationComponents = try #require(
            URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
        )
        let queryItemsByName = Dictionary(
            uniqueKeysWithValues: (authorizationComponents.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )

        #expect(authorizationComponents.path == "/auth/v1/authorize")
        #expect(queryItemsByName["provider"] == "google")
        #expect(queryItemsByName["code_challenge"] == codeChallenge)
        #expect(queryItemsByName["code_challenge_method"] == "s256")
        // The state rides inside redirect_to so Supabase hands it back next to
        // the code — see the comment on `AccountService.authorizationURL`.
        #expect(queryItemsByName["redirect_to"] == "iris://auth/callback?state=\(opaqueStateToken)")
        // The verifier itself never leaves this machine.
        #expect(!authorizationURL.absoluteString.contains(codeVerifier))
    }

    @Test func aCallbackFromADifferentSignInAttemptIsRefused() async throws {
        let callbackURL = URL(string: "iris://auth/callback?state=theirs&code=abc123")!

        #expect(throws: AccountServiceError.theCallbackDidNotMatchThisSignInAttempt) {
            _ = try AccountService.authorizationCode(
                fromCallbackURL: callbackURL,
                expectedOpaqueStateToken: "ours"
            )
        }

        let matchingAuthorizationCode = try AccountService.authorizationCode(
            fromCallbackURL: callbackURL,
            expectedOpaqueStateToken: "theirs"
        )
        #expect(matchingAuthorizationCode == "abc123")
    }

    // MARK: - Error-code mapping

    @Test func theFundedTiersErrorCodesBecomeTheRightUserVisibleState() async throws {
        // 401 sign_in_required — the session is gone, so put sign-in back in
        // front of the user rather than only showing a message.
        let signInRequired = AssistantTransportError.failure(
            forStatusCode: 401,
            serverErrorCode: "sign_in_required",
            retryAfterHeaderValue: nil,
            isFundedTier: true
        )
        #expect(signInRequired == .signInRequired)
        #expect(signInRequired.requiresReSignIn)
        #expect(signInRequired.shouldOfferBringYourOwnKey == false)

        // 429 rate_limited, with Retry-After, becomes a quota message that
        // names the wait and offers the way around it.
        let rateLimited = AssistantTransportError.failure(
            forStatusCode: 429,
            serverErrorCode: "rate_limited",
            retryAfterHeaderValue: "45",
            isFundedTier: true
        )
        #expect(rateLimited == .rateLimited(retryAfterSeconds: 45))
        #expect(rateLimited.requiresReSignIn == false)
        #expect(rateLimited.shouldOfferBringYourOwnKey)
        #expect(rateLimited.userFacingMessage.contains("45 seconds"))

        // 429 daily_budget_exhausted is a different sentence from rate_limited:
        // "wait a minute" and "that's today's budget" are not the same news.
        let dailyBudgetExhausted = AssistantTransportError.failure(
            forStatusCode: 429,
            serverErrorCode: "daily_budget_exhausted",
            retryAfterHeaderValue: "7200",
            isFundedTier: true
        )
        #expect(dailyBudgetExhausted == .dailyBudgetExhausted(retryAfterSeconds: 7200))
        #expect(dailyBudgetExhausted.userFacingMessage != rateLimited.userFacingMessage)
        #expect(dailyBudgetExhausted.shouldOfferBringYourOwnKey)

        // 503 assistant_unconfigured is publik's outage, and the message says so.
        let assistantUnavailable = AssistantTransportError.failure(
            forStatusCode: 503,
            serverErrorCode: "assistant_unconfigured",
            retryAfterHeaderValue: nil,
            isFundedTier: true
        )
        #expect(assistantUnavailable == .assistantUnavailable)
        #expect(assistantUnavailable.requiresReSignIn == false)
        #expect(assistantUnavailable.userFacingMessage.contains("unavailable"))

        // Anything else is one generic failure. upstream_error included.
        #expect(AssistantTransportError.failure(
            forStatusCode: 502,
            serverErrorCode: "upstream_error",
            retryAfterHeaderValue: nil,
            isFundedTier: true
        ) == .requestFailed(statusCode: 502))
    }

    @Test func a401MeansOppositeThingsOnTheTwoRoutes() async throws {
        // Publik saying 401 means "sign in again"; Anthropic saying it means
        // "that key is bad", and telling a BYO user to sign in would be wrong.
        #expect(AssistantTransportError.failure(
            forStatusCode: 401,
            serverErrorCode: nil,
            retryAfterHeaderValue: nil,
            isFundedTier: false
        ) == .bringYourOwnKeyRejected)
        #expect(AssistantTransportError.bringYourOwnKeyRejected.requiresReSignIn == false)
    }

    @Test func aMissingOrUnreadableRetryAfterStillProducesAUsableSentence() async throws {
        let withoutRetryAfter = AssistantTransportError.failure(
            forStatusCode: 429,
            serverErrorCode: "rate_limited",
            retryAfterHeaderValue: nil,
            isFundedTier: true
        )
        #expect(withoutRetryAfter == .rateLimited(retryAfterSeconds: nil))
        #expect(!withoutRetryAfter.userFacingMessage.isEmpty)

        let withGarbageRetryAfter = AssistantTransportError.failure(
            forStatusCode: 429,
            serverErrorCode: "rate_limited",
            retryAfterHeaderValue: "Wed, 21 Oct 2026 07:28:00 GMT",
            isFundedTier: true
        )
        #expect(withGarbageRetryAfter == .rateLimited(retryAfterSeconds: nil))
    }

    @Test func onlyTheServersErrorCodeIsEverReadOutOfAFailureBody() async throws {
        let failureBody = Data(#"{"error":"daily_budget_exhausted"}"#.utf8)
        #expect(AssistantTransportError.serverErrorCode(inFailureBody: failureBody)
            == "daily_budget_exhausted")

        // A body that is not the shape publik produces yields nothing, rather
        // than something that could end up quoted at the user.
        #expect(AssistantTransportError.serverErrorCode(inFailureBody: Data("not json".utf8)) == nil)
        #expect(AssistantTransportError.serverErrorCode(inFailureBody: Data(#"{"error":""}"#.utf8)) == nil)
        #expect(AssistantTransportError.serverErrorCode(
            inFailureBody: Data(#"{"message":"whatever the model just said"}"#.utf8)
        ) == nil)
    }

    @Test func noUserFacingMessageEverQuotesAServerBody() async throws {
        let everyFailureState: [AssistantTransportError] = [
            .noCredentialsAvailable,
            .signInRequired,
            .rateLimited(retryAfterSeconds: 30),
            .dailyBudgetExhausted(retryAfterSeconds: nil),
            .assistantUnavailable,
            .requestFailed(statusCode: 502),
            .bringYourOwnKeyRejected,
            .transportFailure(reason: "a socket said something unrepeatable"),
            .bringYourOwnKeyWouldLeaveAnthropic(attemptedHost: "publikhq.com"),
        ]

        for failureState in everyFailureState {
            #expect(!failureState.userFacingMessage.isEmpty)
            // The two cases that carry raw text in their payload must not put
            // it in front of the user.
            #expect(!failureState.userFacingMessage.contains("unrepeatable"))
            #expect(!failureState.userFacingMessage.contains("502"))
        }
    }

    // MARK: - The configured origin

    @Test func onlyPublikOrLocalhostCanEverBeTheFundedOrigin() async throws {
        // `configuredPublikBaseURL` reads the app bundle, which under the test
        // runner is the xctest bundle rather than Iris — so it lands on the
        // default. That is the assertion worth making anyway: an absent or
        // unreadable configuration must produce publik, never nothing.
        let configuredBaseURL = AssistantTransport.configuredPublikBaseURL()
        #expect(configuredBaseURL.absoluteString == "https://publikhq.com")

        // And the allowlist it filters through is the one GuideService already
        // enforces, so a tampered Info.plist cannot redirect signed-in traffic.
        #expect(GuideService.normalizedAPIBase("https://evil.example") == nil)
        #expect(GuideService.normalizedAPIBase("https://publikhq.com.attacker.example") == nil)
        #expect(GuideService.normalizedAPIBase("http://localhost:3000") == "http://localhost:3000")
    }

    // MARK: - The system field, per route

    // Anthropic accepts a Claude Code OAuth token only when the request's
    // system prompt LEADS with Claude Code's own identity sentence; anything
    // else is rejected with a synthetic `rate_limit_error` 429 that carries no
    // quota headers. Verified live 2026-08-20 — the identical request flips
    // 429 → 200 on this block alone.

    @Test func theOAuthTokenRouteLeadsWithClaudeCodesOwnIdentityBlock() {
        let systemFieldValue = ClaudeAPI.systemFieldValue(
            for: .bringYourOwnOAuthToken(anthropicOAuthToken: "sk-ant-oat01-fake"),
            systemPrompt: "You are a careful software-maintenance agent."
        )

        let systemBlocks = systemFieldValue as? [[String: Any]]
        #expect(systemBlocks?.count == 2)
        #expect(systemBlocks?.first?["type"] as? String == "text")
        #expect(
            systemBlocks?.first?["text"] as? String
                == AssistantTransport.claudeCodeIdentitySystemBlockText
        )
        #expect(
            systemBlocks?.last?["text"] as? String
                == "You are a careful software-maintenance agent."
        )
    }

    @Test func anEmptySystemPromptOnTheOAuthRouteStillSendsTheIdentityBlockAlone() {
        // A bare request (no system prompt at all) is rejected the same way,
        // so the identity block must go out even when the caller has nothing
        // to say.
        let systemFieldValue = ClaudeAPI.systemFieldValue(
            for: .bringYourOwnOAuthToken(anthropicOAuthToken: "sk-ant-oat01-fake"),
            systemPrompt: ""
        )

        let systemBlocks = systemFieldValue as? [[String: Any]]
        #expect(systemBlocks?.count == 1)
        #expect(
            systemBlocks?.first?["text"] as? String
                == AssistantTransport.claudeCodeIdentitySystemBlockText
        )
    }

    @Test func theKeyAndFundedRoutesKeepThePlainStringSystemField() async throws {
        // A pasted API key carries no Claude-Code-only restriction, and the
        // funded server prepends its own system block — neither route should
        // impersonate Claude Code.
        let keyRouteSystemField = ClaudeAPI.systemFieldValue(
            for: .bringYourOwnKey(anthropicAPIKey: Self.fakeAnthropicAPIKey),
            systemPrompt: "You are Iris."
        )
        #expect(keyRouteSystemField as? String == "You are Iris.")

        let fundedRouteSystemField = ClaudeAPI.systemFieldValue(
            for: .funded(
                publikBaseURL: URL(string: "https://publikhq.com")!,
                currentAccessTokenProvider: { "fake-supabase-token" }
            ),
            systemPrompt: "You are Iris."
        )
        #expect(fundedRouteSystemField as? String == "You are Iris.")
    }
}
