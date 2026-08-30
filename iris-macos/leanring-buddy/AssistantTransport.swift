//
//  AssistantTransport.swift
//  leanring-buddy
//
//  Decides where a chat request goes, and is the single place in the app that
//  is allowed to attach credentials to one.
//
//  `docs/iris-assistant-protocol.md` section 1 defines exactly two routes, and
//  they speak the identical wire format (the Anthropic Messages API, streaming
//  SSE) so one parser serves both:
//
//    funded  →  POST {publik}/api/assistant/chat   Authorization: Bearer <supabase access token>
//    BYO     →  POST https://api.anthropic.com/v1/messages   x-api-key: <the user's own key>
//
//  THE PROPERTY THIS FILE EXISTS TO PROTECT: the user's own Anthropic key is
//  never sent to any publik host. Losing that is a ship-blocker, so it is
//  enforced three ways rather than by convention:
//
//    1. Structurally. `anthropicDirectChatRequest(anthropicAPIKey:)` is the ONLY
//       function that writes an `x-api-key` header, and it takes no URL — it
//       builds `https://api.anthropic.com/v1/messages` from a constant. There
//       is no code path anywhere that accepts both a key and a destination, so
//       "send the key somewhere else" is not a mistake this file can express.
//    2. By assertion. Every request leaves through `validatedRequest(_:)`, which
//       refuses a request carrying `x-api-key` to any host but api.anthropic.com,
//       and refuses to let a publik host see that header at all.
//    3. By test. `AssistantTransportTests` asserts the property directly.
//

import Foundation

// MARK: - Where a request can go

/// The two model routes, and the credential each one carries.
///
/// The funded case holds a *provider* rather than a token because the Supabase
/// access token is short-lived: it may need refreshing between the moment the
/// transport was chosen and the moment a request is actually built.
enum AssistantTransport: Sendable {
    /// The publik-funded tier. The server pins the model and caps `max_tokens`,
    /// so the client's choice of either is ignored — see `shouldSendModelInRequestBody`.
    case funded(
        publikBaseURL: URL,
        currentAccessTokenProvider: @Sendable () async -> String?
    )

    /// The user's own Anthropic key, going straight to Anthropic. The URL is
    /// deliberately absent: it is a constant inside this file.
    case bringYourOwnKey(anthropicAPIKey: String)

    /// The user's own Claude Code OAuth token (`sk-ant-oat…`), going straight to
    /// Anthropic. Same isolation property as the API key — the URL is a constant
    /// inside this file — but it authenticates with `Authorization: Bearer` plus
    /// the OAuth beta header rather than `x-api-key`, which is how Anthropic
    /// accepts a Claude Code token on the Messages API.
    case bringYourOwnOAuthToken(anthropicOAuthToken: String)

    /// The only host the BYO key may ever reach.
    static let anthropicAPIHost = "api.anthropic.com"

    /// The Anthropic Messages API version every direct request must declare.
    static let anthropicAPIVersion = "2023-06-01"

    /// The `anthropic-beta` value that makes Anthropic accept a Claude Code
    /// OAuth token on the Messages API. This is the public value Claude Code
    /// itself sends; it is NOT something Iris can verify from inside this
    /// process, so if Anthropic rotates it, an OAuth-token request starts
    /// failing with 401 and this constant is the one line to update.
    /// UNVERIFIED against a live token — see the CLI-login notes.
    static let anthropicOAuthBetaHeaderValue = "oauth-2025-04-20"

    /// The system-prompt sentence Anthropic requires at the head of every
    /// request made with a Claude Code OAuth token. Anthropic enforces that an
    /// `sk-ant-oat…` credential is only used by Claude Code, and it recognizes
    /// Claude Code by this exact first system block — a request without it is
    /// rejected with a synthetic `rate_limit_error` 429 (no `Retry-After`, no
    /// quota headers), which reads like a quota problem but is not one.
    /// Verified live on 2026-08-20: the identical request flips 429 → 200 on
    /// this block alone. Like `anthropicOAuthBetaHeaderValue`, this is the
    /// public value Claude Code itself sends and cannot be verified from
    /// inside this process — if Anthropic changes it, OAuth-token requests
    /// start failing again and this constant is the one line to update.
    static let claudeCodeIdentitySystemBlockText =
        "You are Claude Code, Anthropic's official CLI for Claude."

    /// Whether the request body's `system` field must lead with
    /// `claudeCodeIdentitySystemBlockText`. Only the OAuth-token route: the
    /// funded server prepends its own system block, and a pasted API key
    /// carries no Claude-Code-only restriction.
    var shouldPrependClaudeCodeIdentitySystemBlock: Bool {
        switch self {
        case .funded, .bringYourOwnKey:
            return false
        case .bringYourOwnOAuthToken:
            return true
        }
    }

    /// Where publik lives when nothing overrides it.
    static let defaultPublikBaseURLString = "https://publikhq.com"

    /// The Info.plist key a local-development build sets to point Iris at a
    /// site running on localhost instead of production.
    static let publikBaseURLInfoPlistKey = "PublikAPIBaseURL"

    /// Which tier this is, for UI that wants to say "funded" or "your own key"
    /// without pattern-matching on a case that carries a secret.
    var tierDescription: String {
        switch self {
        case .funded:
            return "publik account"
        case .bringYourOwnKey:
            return "your Anthropic key"
        case .bringYourOwnOAuthToken:
            return "your Claude Code login"
        }
    }

    /// The funded route's server prepends its own system block, pins the model,
    /// and caps `max_tokens`; sending a model it will ignore only invites a
    /// reader of the code to believe the client picked it. On the BYO route the
    /// model is genuinely the client's choice and must be sent.
    /// Whether a call on this transport costs the reader money PER QUERY, and
    /// so whether a dollar figure is honest to show against it.
    ///
    /// The OAuth-token case is the one worth stating out loud: it is the
    /// reader's own credential, so it looks like the API-key case and is not.
    /// A Claude Code login is a flat-rate plan — the marginal cost of one more
    /// query is zero — so pricing its tokens would invent a bill.
    var spendRoute: AssistantSpendRoute {
        switch self {
        case .funded:
            return .publiksFundedTier
        case .bringYourOwnKey:
            return .theReadersOwnAPIKey
        case .bringYourOwnOAuthToken:
            return .aFlatRateSubscription
        }
    }

    /// Which credential a request rode on. Replaces the `isFundedTier` Bool the
    /// 401 mapping used to take: a 401 means three different things here, and
    /// two of them were being told to the reader as the same sentence.
    enum CredentialShape: Sendable {
        case publiksFundedTier
        case aPastedAnthropicKey
        /// A Claude Code login. NOT a key — you cannot "paste it again", and
        /// telling somebody to is advice they cannot follow.
        case aClaudeCodeLogin
    }

    var credentialShape: CredentialShape {
        switch self {
        case .funded: return .publiksFundedTier
        case .bringYourOwnKey: return .aPastedAnthropicKey
        case .bringYourOwnOAuthToken: return .aClaudeCodeLogin
        }
    }

    var shouldSendModelInRequestBody: Bool {
        switch self {
        case .funded:
            return false
        case .bringYourOwnKey, .bringYourOwnOAuthToken:
            return true
        }
    }

    // MARK: - Building a request

    /// Produces the URL and headers for one chat request. The caller supplies
    /// the body, which is identical for both routes apart from the `model`
    /// field described above.
    func makeChatRequest() async throws -> URLRequest {
        switch self {
        case .funded(let publikBaseURL, let currentAccessTokenProvider):
            guard let accessToken = await currentAccessTokenProvider(),
                  !accessToken.isEmpty else {
                // No usable access token means the refresh already failed. This
                // is exactly the state the funded tier's 401 describes, so it
                // is reported the same way rather than as a transport failure.
                throw AssistantTransportError.signInRequired
            }
            return try Self.validatedRequest(
                Self.fundedChatRequest(publikBaseURL: publikBaseURL, supabaseAccessToken: accessToken)
            )

        case .bringYourOwnKey(let anthropicAPIKey):
            return try Self.validatedRequest(
                Self.anthropicDirectChatRequest(anthropicAPIKey: anthropicAPIKey)
            )

        case .bringYourOwnOAuthToken(let anthropicOAuthToken):
            return try Self.validatedRequest(
                Self.anthropicDirectOAuthChatRequest(anthropicOAuthToken: anthropicOAuthToken)
            )
        }
    }

    /// The funded route. Note what this function does NOT take: an API key. The
    /// only credential it can attach is a Supabase access token, which is a
    /// publik-issued value that publik is supposed to see.
    private static func fundedChatRequest(
        publikBaseURL: URL,
        supabaseAccessToken: String
    ) -> URLRequest {
        let chatURL = publikBaseURL.appendingPathComponent("api/assistant/chat")
        var fundedRequest = URLRequest(url: chatURL)
        fundedRequest.httpMethod = "POST"
        fundedRequest.timeoutInterval = 120
        fundedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        fundedRequest.setValue("Bearer \(supabaseAccessToken)", forHTTPHeaderField: "Authorization")
        return fundedRequest
    }

    /// The BYO route, and the only place `x-api-key` is ever written.
    ///
    /// There is no URL parameter on purpose. A caller cannot ask this function
    /// to send the key anywhere, because the destination is not something the
    /// caller supplies — it is the constant below.
    private static func anthropicDirectChatRequest(anthropicAPIKey: String) -> URLRequest {
        let anthropicMessagesURL = URL(string: "https://\(anthropicAPIHost)/v1/messages")!
        var directRequest = URLRequest(url: anthropicMessagesURL)
        directRequest.httpMethod = "POST"
        directRequest.timeoutInterval = 120
        directRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        directRequest.setValue(anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        directRequest.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        return directRequest
    }

    /// The BYO OAuth-token route, and the only place an `Authorization: Bearer`
    /// header is paired with the OAuth `anthropic-beta` header.
    ///
    /// Like the API-key builder, it takes no URL: the destination is the same
    /// constant Anthropic host, so a caller cannot ask this function to send the
    /// token anywhere else. The `anthropic-beta: oauth-…` header it stamps is
    /// also what `validatedRequest` keys off to guarantee an OAuth token can
    /// only ever reach Anthropic — the funded route's Bearer header never
    /// carries it, so the two Bearers can never be confused.
    private static func anthropicDirectOAuthChatRequest(anthropicOAuthToken: String) -> URLRequest {
        let anthropicMessagesURL = URL(string: "https://\(anthropicAPIHost)/v1/messages")!
        var directRequest = URLRequest(url: anthropicMessagesURL)
        directRequest.httpMethod = "POST"
        directRequest.timeoutInterval = 120
        directRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        directRequest.setValue("Bearer \(anthropicOAuthToken)", forHTTPHeaderField: "Authorization")
        directRequest.setValue(anthropicOAuthBetaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        directRequest.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        return directRequest
    }

    // MARK: - The last gate before a request leaves

    /// Refuses any request whose credentials and destination do not match.
    ///
    /// This duplicates what the two builders above already guarantee, and that
    /// is the point: a later refactor that merges them, adds a third route, or
    /// "helpfully" copies headers between requests trips this instead of
    /// silently shipping the user's key to a server that should never see it.
    static func validatedRequest(_ candidateRequest: URLRequest) throws -> URLRequest {
        let destinationHost = candidateRequest.url?.host?.lowercased()
        let carriesBringYourOwnKey = candidateRequest.value(forHTTPHeaderField: "x-api-key") != nil

        // A BYO OAuth token is identified by the OAuth `anthropic-beta` header
        // its builder stamps. This is deliberately NOT "any Authorization:
        // Bearer": the funded route also sends a Bearer (the Supabase token) and
        // is SUPPOSED to reach a publik host, so keying off the OAuth beta header
        // is what separates the user's own token from the publik-issued one.
        let anthropicBetaHeader = candidateRequest.value(forHTTPHeaderField: "anthropic-beta")
        let carriesBringYourOwnOAuthToken =
            anthropicBetaHeader?.contains("oauth") == true

        // Either shape of the user's own Anthropic credential — the API key or
        // the OAuth token — may only ever reach Anthropic. Stated both as
        // "carries a credential ⇒ host must be Anthropic" and its contrapositive
        // so the check reads as the rule, not an implementation detail of it.
        let carriesEitherBringYourOwnCredential =
            carriesBringYourOwnKey || carriesBringYourOwnOAuthToken

        if carriesEitherBringYourOwnCredential {
            guard destinationHost == anthropicAPIHost else {
                throw AssistantTransportError.bringYourOwnKeyWouldLeaveAnthropic(
                    attemptedHost: destinationHost ?? "an unknown host"
                )
            }
        }

        if destinationHost != anthropicAPIHost && carriesEitherBringYourOwnCredential {
            throw AssistantTransportError.bringYourOwnKeyWouldLeaveAnthropic(
                attemptedHost: destinationHost ?? "an unknown host"
            )
        }

        return candidateRequest
    }

    // MARK: - Choosing between the two

    /// Picks the route for the current state of the app.
    ///
    /// Funded wins when the user is signed in, because it costs them nothing.
    /// A stored key is the fallback. Neither is a real state the panel has to
    /// explain, not a silent failure at request time — which is why it is a
    /// `.failure` carrying a message rather than a nil transport.
    static func selectTransport(
        isSignedIn: Bool,
        publikBaseURL: URL,
        storedAnthropicAPIKey: String?,
        storedAnthropicOAuthToken: String? = nil,
        currentAccessTokenProvider: @escaping @Sendable () async -> String?
    ) -> Result<AssistantTransport, AssistantTransportError> {
        if isSignedIn {
            return .success(.funded(
                publikBaseURL: publikBaseURL,
                currentAccessTokenProvider: currentAccessTokenProvider
            ))
        }

        // A pasted API key wins over a Claude Code token when both are present:
        // the API key is the plainer, more reliable credential (an OAuth token
        // depends on the beta header staying valid), so it is the safer default.
        if let storedAnthropicAPIKey, !storedAnthropicAPIKey.isEmpty {
            return .success(.bringYourOwnKey(anthropicAPIKey: storedAnthropicAPIKey))
        }

        if let storedAnthropicOAuthToken, !storedAnthropicOAuthToken.isEmpty {
            return .success(.bringYourOwnOAuthToken(anthropicOAuthToken: storedAnthropicOAuthToken))
        }

        return .failure(.noCredentialsAvailable)
    }

    /// The publik origin this build talks to. Production unless the bundle
    /// names another, and even then only an origin `GuideService` already
    /// trusts — publik itself or localhost — so a tampered Info.plist cannot
    /// redirect signed-in traffic to somebody else's server.
    static func configuredPublikBaseURL() -> URL {
        let configuredBaseURLString = AppBundleConfiguration
            .stringValue(forKey: publikBaseURLInfoPlistKey) ?? defaultPublikBaseURLString

        let allowedBaseURLString = GuideService.normalizedAPIBase(configuredBaseURLString)
            ?? defaultPublikBaseURLString

        // The default is a compile-time constant known to parse, so the final
        // fallback here is unreachable rather than a real recovery path.
        return URL(string: allowedBaseURLString)
            ?? URL(string: defaultPublikBaseURLString)!
    }
}

// MARK: - Failures

/// Every way a chat request can fail before, during, or after transport, in the
/// vocabulary the panel uses to talk to the user.
///
/// The funded tier's error codes (`docs/iris-assistant-protocol.md` section 1)
/// each map to exactly one case here, so the panel never has to interpret a
/// status code and a raw server body is never shown to anybody.
enum AssistantTransportError: Error, Equatable, Sendable {
    /// Not signed in and no key stored. The one state that is the user's move.
    case noCredentialsAvailable
    /// `sign_in_required` (HTTP 401). The session is gone or was rejected.
    case signInRequired
    /// `rate_limited` (HTTP 429 + `Retry-After`).
    case rateLimited(retryAfterSeconds: Int?)
    /// `daily_budget_exhausted` (HTTP 429 + `Retry-After`).
    case dailyBudgetExhausted(retryAfterSeconds: Int?)
    /// `assistant_unconfigured` (HTTP 503). Publik's own outage, not the user's.
    case assistantUnavailable
    /// `upstream_error` and every other status. Deliberately vague: the server's
    /// body may quote the model's own words back and is never surfaced.
    case requestFailed(statusCode: Int)
    /// The user's own PASTED key was rejected by Anthropic (401 on the BYO route).
    case bringYourOwnKeyRejected
    /// The user's connected Claude Code login was rejected (401 on the BYO
    /// route). Split from the case above because the remedy is different and
    /// the old shared wording — "check it's still active and paste it again" —
    /// is impossible advice for a login there is nothing to paste. These tokens
    /// also rotate every few hours, so this is the commonest of the three.
    case claudeCodeLoginExpired
    /// The network never got there.
    case transportFailure(reason: String)
    /// The key-isolation property was about to be violated. This should be
    /// impossible; it exists so that if it ever happens the request dies here
    /// rather than on the wire.
    case bringYourOwnKeyWouldLeaveAnthropic(attemptedHost: String)

    /// What the panel shows. Lowercase to match the assistant's own voice in
    /// `CompanionManager`'s prompt, which is what the same text area displays.
    var userFacingMessage: String {
        switch self {
        case .noCredentialsAvailable:
            return "sign in with your publik account, or add your own anthropic key, and i'll be right here."
        case .signInRequired:
            return "your sign-in expired. sign in again and ask me one more time."
        case .rateLimited(let retryAfterSeconds):
            return "you've hit the request limit for now. \(Self.retryPhrase(forRetryAfterSeconds: retryAfterSeconds)) or add your own anthropic key to keep going."
        case .dailyBudgetExhausted(let retryAfterSeconds):
            return "that's today's free assistant budget used up. \(Self.retryPhrase(forRetryAfterSeconds: retryAfterSeconds)) or add your own anthropic key to keep going."
        case .assistantUnavailable:
            return "the assistant is unavailable right now. this one's on publik, not you — try again in a bit."
        case .requestFailed:
            return "hm, something went wrong reaching the assistant. check your connection and try again."
        case .bringYourOwnKeyRejected:
            return "anthropic refused the key iris has saved. check it's still active and paste it again."
        case .claudeCodeLoginExpired:
            return "your claude code login has expired — they only last a few hours. reconnect it in settings."
        case .transportFailure:
            return "i couldn't reach the assistant. check your connection and try again."
        case .bringYourOwnKeyWouldLeaveAnthropic:
            return "iris stopped that request: your api key was about to go somewhere it shouldn't."
        }
    }

    /// True when the right response is to put the sign-in buttons back in front
    /// of the user rather than just showing them a message.
    var requiresReSignIn: Bool {
        switch self {
        case .signInRequired:
            return true
        case .noCredentialsAvailable, .rateLimited, .dailyBudgetExhausted, .assistantUnavailable,
             .requestFailed, .bringYourOwnKeyRejected, .claudeCodeLoginExpired, .transportFailure,
             .bringYourOwnKeyWouldLeaveAnthropic:
            return false
        }
    }

    /// True when the user's quota, not the software, is what stopped them —
    /// the case where offering the BYO key is genuinely useful advice.
    var shouldOfferBringYourOwnKey: Bool {
        switch self {
        case .rateLimited, .dailyBudgetExhausted:
            return true
        case .noCredentialsAvailable, .signInRequired, .assistantUnavailable, .requestFailed,
             .bringYourOwnKeyRejected, .claudeCodeLoginExpired, .transportFailure,
             .bringYourOwnKeyWouldLeaveAnthropic:
            return false
        }
    }

    private static func retryPhrase(forRetryAfterSeconds retryAfterSeconds: Int?) -> String {
        guard let retryAfterSeconds, retryAfterSeconds > 0 else {
            return "try again shortly,"
        }
        if retryAfterSeconds < 90 {
            return "try again in \(retryAfterSeconds) seconds,"
        }
        let retryAfterMinutes = Int((Double(retryAfterSeconds) / 60.0).rounded(.up))
        if retryAfterMinutes < 90 {
            return "try again in about \(retryAfterMinutes) minutes,"
        }
        let retryAfterHours = Int((Double(retryAfterMinutes) / 60.0).rounded(.up))
        return "try again in about \(retryAfterHours) hours,"
    }

    // MARK: - Mapping the server's answer

    /// Turns one HTTP failure into the state the user sees.
    ///
    /// `serverErrorCode` is the `{"error": "..."}` string the funded route
    /// returns. It is read only to choose between two 429s that mean different
    /// things to the user — "wait a few minutes" versus "that's it for today" —
    /// and is never itself displayed, because an unknown code must not become
    /// user-visible text.
    static func failure(
        forStatusCode statusCode: Int,
        serverErrorCode: String?,
        retryAfterHeaderValue: String?,
        credentialShape: AssistantTransport.CredentialShape
    ) -> AssistantTransportError {
        let retryAfterSeconds = retryAfterHeaderValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        switch statusCode {
        case 401:
            // One status, three meanings. publik is saying "sign in again";
            // Anthropic is saying either "this key is bad" or "this login has
            // expired", and those two need different advice from the reader.
            switch credentialShape {
            case .publiksFundedTier: return .signInRequired
            case .aPastedAnthropicKey: return .bringYourOwnKeyRejected
            case .aClaudeCodeLogin: return .claudeCodeLoginExpired
            }
        case 429:
            if serverErrorCode == "daily_budget_exhausted" {
                return .dailyBudgetExhausted(retryAfterSeconds: retryAfterSeconds)
            }
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case 503:
            return .assistantUnavailable
        default:
            return .requestFailed(statusCode: statusCode)
        }
    }

    /// Pulls the `{"error": "code"}` string out of a funded-tier failure body.
    /// Only the code is ever read — the rest of the body is dropped on the
    /// floor so it can never reach the panel.
    static func serverErrorCode(inFailureBody failureBodyData: Data) -> String? {
        guard let failureBody = try? JSONSerialization.jsonObject(with: failureBodyData) as? [String: Any],
              let serverErrorCode = failureBody["error"] as? String,
              !serverErrorCode.isEmpty else {
            return nil
        }
        return serverErrorCode
    }
}
