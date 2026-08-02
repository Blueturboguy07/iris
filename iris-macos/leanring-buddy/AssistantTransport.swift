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

    /// The only host the BYO key may ever reach.
    static let anthropicAPIHost = "api.anthropic.com"

    /// The Anthropic Messages API version every direct request must declare.
    static let anthropicAPIVersion = "2023-06-01"

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
        }
    }

    /// The funded route's server prepends its own system block, pins the model,
    /// and caps `max_tokens`; sending a model it will ignore only invites a
    /// reader of the code to believe the client picked it. On the BYO route the
    /// model is genuinely the client's choice and must be sent.
    var shouldSendModelInRequestBody: Bool {
        switch self {
        case .funded:
            return false
        case .bringYourOwnKey:
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

        if carriesBringYourOwnKey {
            guard destinationHost == anthropicAPIHost else {
                throw AssistantTransportError.bringYourOwnKeyWouldLeaveAnthropic(
                    attemptedHost: destinationHost ?? "an unknown host"
                )
            }
        }

        // Stated from the other direction as well, so the check reads as the
        // rule rather than as an implementation detail of the rule.
        if destinationHost != anthropicAPIHost && carriesBringYourOwnKey {
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
        currentAccessTokenProvider: @escaping @Sendable () async -> String?
    ) -> Result<AssistantTransport, AssistantTransportError> {
        if isSignedIn {
            return .success(.funded(
                publikBaseURL: publikBaseURL,
                currentAccessTokenProvider: currentAccessTokenProvider
            ))
        }

        if let storedAnthropicAPIKey, !storedAnthropicAPIKey.isEmpty {
            return .success(.bringYourOwnKey(anthropicAPIKey: storedAnthropicAPIKey))
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
    /// The user's own key was rejected by Anthropic (HTTP 401 on the BYO route).
    case bringYourOwnKeyRejected
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
            return "anthropic turned that key down. check it's still active and paste it again."
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
             .requestFailed, .bringYourOwnKeyRejected, .transportFailure,
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
             .bringYourOwnKeyRejected, .transportFailure, .bringYourOwnKeyWouldLeaveAnthropic:
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
        isFundedTier: Bool
    ) -> AssistantTransportError {
        let retryAfterSeconds = retryAfterHeaderValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        switch statusCode {
        case 401:
            // The same status means opposite things on the two routes: publik
            // is saying "sign in again", Anthropic is saying "this key is bad".
            return isFundedTier ? .signInRequired : .bringYourOwnKeyRejected
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
