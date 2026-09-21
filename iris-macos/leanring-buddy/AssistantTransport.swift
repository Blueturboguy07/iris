//
//  AssistantTransport.swift
//  leanring-buddy
//
//  Decides where a chat request goes, and is the single place in the app that
//  is allowed to attach credentials to one.
//
//  `docs/assistant-credentials.md` is the cross-platform contract. There are
//  exactly two HTTP routes here, and they speak the identical wire format (the
//  Anthropic Messages API, streaming SSE) so one parser serves both:
//
//    publik API  →  POST {gateway}/messages            x-api-key: pk_live_…
//    BYO         →  POST https://api.anthropic.com/v1/messages   x-api-key: sk-ant-…
//
//  (The third credential a reader can pick — a Codex CLI login — is not an
//  HTTP route at all and is not in this enum. It is a subprocess; see
//  `CodexChatResponder.swift`.)
//
//  WHAT WENT AWAY, AND WHY IT IS NOT COMING BACK:
//
//    - The FUNDED tier (`POST {publik}/api/assistant/chat` on publik's own
//      Anthropic key) is gone. It was free to anyone signed in and capped only
//      per-user, so exposure scaled with the number of accounts — which is
//      what kept Iris from being publicly installable at all. publik API
//      replaces it: the same "it just works" first run, paid by the person
//      using it. The server route stays up for older installed builds; this
//      build never calls it.
//    - The Claude Code OAuth token route (`sk-ant-oat…`, `claude setup-token`,
//      importing an existing `claude login`) is gone for good. Anthropic's own
//      terms forbid a third-party app collecting, storing or intermediating
//      Claude.ai credentials or session tokens, or routing requests through a
//      Free/Pro/Max plan on a user's behalf. Anthropic access here is API keys
//      only. Do not re-add it.
//
//  THE PROPERTY THIS FILE EXISTS TO PROTECT: the reader's own Anthropic key is
//  never sent to any publik host. Adding a second legitimate `x-api-key` route
//  (the publik gateway) does not weaken that — it sharpens it, because the rule
//  is now stated in terms of WHICH credential may reach WHICH host rather than
//  "this header may only ever go one place":
//
//    1. Structurally. `anthropicDirectChatRequest(anthropicAPIKey:)` is the only
//       function that can attach an Anthropic key, and it takes no URL — it
//       builds `https://api.anthropic.com/v1/messages` from a constant. The
//       publik builder takes a base URL because the gateway names its own, but
//       it cannot be handed an Anthropic key: it takes a `PublikAPIKey`, a type
//       whose initializer refuses anything that is not a `pk_` credential.
//    2. By assertion. Every request leaves through `validatedRequest(_:)`, which
//       reads the credential's own prefix and refuses any pairing but the two
//       legal ones.
//    3. By test. `AssistantTransportTests` asserts the property directly.
//

import Foundation

// MARK: - A publik API key, as a type

/// A `pk_…` gateway credential.
///
/// A named type rather than a `String` so the publik request builder — the one
/// builder that accepts a destination — cannot be handed the reader's Anthropic
/// key by a caller that mixed two variables up. The initializer is the whole
/// point: it refuses anything that is not a publik key.
struct PublikAPIKey: Sendable, Equatable {
    let value: String

    /// Nil unless this really is a publik gateway key.
    init?(_ candidateValue: String) {
        let trimmedValue = candidateValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.hasPrefix(PublikAPIKey.keyPrefix) else { return nil }
        value = trimmedValue
    }

    /// Every publik gateway key starts with this, live and test alike. It is
    /// also what `validatedRequest` keys off to tell the two credentials apart
    /// on the way out.
    static let keyPrefix = "pk_"
}

// MARK: - Where a request can go

/// The two HTTP model routes, and the credential each one carries.
enum AssistantTransport: Sendable {
    /// The publik API gateway. Metered to the reader, billed by publik at half
    /// the provider's list price. The URL is supplied because the gateway names
    /// its own base at provisioning time — but the credential is a
    /// `PublikAPIKey`, so an Anthropic key cannot be routed here.
    case publikAPI(key: PublikAPIKey, gatewayBaseURL: URL)

    /// The reader's own Anthropic key, going straight to Anthropic. The URL is
    /// deliberately absent: it is a constant inside this file.
    case bringYourOwnKey(anthropicAPIKey: String)

    /// The only host an Anthropic credential may ever reach.
    static let anthropicAPIHost = "api.anthropic.com"

    /// The Anthropic Messages API version every direct request must declare.
    static let anthropicAPIVersion = "2023-06-01"

    /// Where publik lives when nothing overrides it.
    static let defaultPublikBaseURLString = "https://publikhq.com"

    /// The Info.plist key a local-development build sets to point Iris at a
    /// site running on localhost instead of production.
    static let publikBaseURLInfoPlistKey = "PublikAPIBaseURL"

    /// Which route this is, for UI that wants to name it without pattern
    /// matching on a case that carries a secret.
    var tierDescription: String {
        switch self {
        case .publikAPI:
            return "publik API"
        case .bringYourOwnKey:
            return "your Anthropic key"
        }
    }

    /// Whether a call on this transport costs the reader money PER QUERY, and
    /// so whether a dollar figure is honest to show against it.
    ///
    /// Both routes are metered now. The funded tier was the one route where the
    /// reader's own money was not at stake, and it is gone.
    var spendRoute: AssistantSpendRoute {
        switch self {
        case .publikAPI:
            // publik bills this one and shows the running total on its own
            // dashboard, which is the authority. Iris's local ledger prices
            // Anthropic list rates and would therefore be wrong here — see
            // `AssistantSpendLedger`.
            return .aMeteredGatewayThatBillsSeparately
        case .bringYourOwnKey:
            return .theReadersOwnAPIKey
        }
    }

    /// Which credential a request rode on, so a 401 can be explained in terms
    /// of the thing the reader would have to go and fix.
    enum CredentialShape: Sendable {
        case aPublikAPIKey
        case aPastedAnthropicKey
    }

    var credentialShape: CredentialShape {
        switch self {
        case .publikAPI: return .aPublikAPIKey
        case .bringYourOwnKey: return .aPastedAnthropicKey
        }
    }

    /// Both routes take the client's model choice. The funded tier was the one
    /// that pinned the model server-side and ignored what the client sent.
    var shouldSendModelInRequestBody: Bool { true }

    /// The publik gateway takes alias model names only — never a raw upstream
    /// slug — so the model the client asks for has to be translated on that
    /// route. See `PublikAPIModelAlias`.
    var requiresPublikModelAliases: Bool {
        switch self {
        case .publikAPI: return true
        case .bringYourOwnKey: return false
        }
    }

    // MARK: - Building a request

    /// Produces the URL and headers for one chat request. The caller supplies
    /// the body, which is identical for both routes apart from the model name.
    func makeChatRequest() async throws -> URLRequest {
        switch self {
        case .publikAPI(let key, let gatewayBaseURL):
            return try Self.validatedRequest(
                Self.publikGatewayChatRequest(key: key, gatewayBaseURL: gatewayBaseURL)
            )

        case .bringYourOwnKey(let anthropicAPIKey):
            return try Self.validatedRequest(
                Self.anthropicDirectChatRequest(anthropicAPIKey: anthropicAPIKey)
            )
        }
    }

    /// The publik API route.
    ///
    /// This is the one builder that takes a destination, because the gateway
    /// names its own base URL at provisioning time. What makes that safe is the
    /// credential parameter's TYPE: a `PublikAPIKey` cannot be constructed from
    /// an `sk-ant-…` string, so no caller can route the reader's Anthropic key
    /// through here however they hold it wrong.
    private static func publikGatewayChatRequest(
        key: PublikAPIKey,
        gatewayBaseURL: URL
    ) -> URLRequest {
        let messagesURL = gatewayBaseURL.appendingPathComponent("messages")
        var gatewayRequest = URLRequest(url: messagesURL)
        gatewayRequest.httpMethod = "POST"
        gatewayRequest.timeoutInterval = 120
        gatewayRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        gatewayRequest.setValue(key.value, forHTTPHeaderField: "x-api-key")
        // The gateway speaks the Anthropic dialect on this route, so it expects
        // the same version header a direct call would carry.
        gatewayRequest.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        return gatewayRequest
    }

    /// The BYO route, and the only place an Anthropic key is ever attached.
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

    /// Refuses any request whose credential and destination do not match.
    ///
    /// Two credentials now legitimately travel as `x-api-key`, so the rule is
    /// stated per credential rather than per header:
    ///
    ///   - an Anthropic key (anything NOT `pk_`) may only reach api.anthropic.com
    ///   - a publik key (`pk_`) may only reach a host publik itself is served on
    ///
    /// This duplicates what the two builders above already guarantee, and that
    /// is the point: a later refactor that merges them, adds a third route, or
    /// "helpfully" copies headers between requests trips this instead of
    /// silently shipping the reader's key to a server that should never see it.
    static func validatedRequest(_ candidateRequest: URLRequest) throws -> URLRequest {
        guard let credential = candidateRequest.value(forHTTPHeaderField: "x-api-key") else {
            // No credential attached: nothing for this gate to protect.
            return candidateRequest
        }
        let destinationHost = candidateRequest.url?.host?.lowercased()

        if credential.hasPrefix(PublikAPIKey.keyPrefix) {
            guard let destinationHost, Self.isAPublikHost(destinationHost) else {
                throw AssistantTransportError.publikKeyWouldLeavePublik(
                    attemptedHost: destinationHost ?? "an unknown host"
                )
            }
            return candidateRequest
        }

        guard destinationHost == anthropicAPIHost else {
            throw AssistantTransportError.bringYourOwnKeyWouldLeaveAnthropic(
                attemptedHost: destinationHost ?? "an unknown host"
            )
        }
        return candidateRequest
    }

    /// Whether a host is one publik is served on. Derived from the same
    /// allowlist `GuideService` uses for everything else Iris fetches, so there
    /// is exactly one definition of "ours" in the app.
    static func isAPublikHost(_ candidateHost: String) -> Bool {
        let normalizedHost = candidateHost.lowercased()
        if normalizedHost == "publikhq.com" || normalizedHost == "www.publikhq.com" {
            return true
        }
        // A local-development build points at a site on localhost; the same
        // origins `GuideService.normalizedAPIBase` already accepts.
        if normalizedHost == "localhost" || normalizedHost == "127.0.0.1" {
            return true
        }
        return false
    }

    // MARK: - Choosing between them

    /// Picks the route for the current state of the app.
    ///
    /// A stored preference WINS, and a broken preference does not silently fall
    /// through to another provider: spending somebody's money on an account they
    /// did not choose is worse than an error message. Only when nothing is
    /// stored does this fall back to the contract's order.
    ///
    /// Codex is resolved above this function, not in it — it is a subprocess
    /// rather than a URL request, so it never becomes an `AssistantTransport`.
    static func selectTransport(
        preference: AssistantProviderPreference?,
        publikAPIKey: String?,
        publikGatewayBaseURL: URL,
        publikKeyMaySpend: Bool,
        storedAnthropicAPIKey: String?,
        codexIsUsable: Bool
    ) -> Result<AssistantTransport, AssistantTransportError> {
        let usablePublikKey = publikAPIKey.flatMap { PublikAPIKey($0) }
        let usableAnthropicKey = (storedAnthropicAPIKey?.isEmpty == false) ? storedAnthropicAPIKey : nil

        switch preference {
        case .publikAPI:
            guard let usablePublikKey else {
                return .failure(.publikAPINotSetUp)
            }
            guard publikKeyMaySpend else {
                return .failure(.publikAPIStarterNotYetDisclosed)
            }
            return .success(.publikAPI(key: usablePublikKey, gatewayBaseURL: publikGatewayBaseURL))

        case .anthropicKey:
            guard let usableAnthropicKey else {
                return .failure(.anthropicKeyNotSaved)
            }
            return .success(.bringYourOwnKey(anthropicAPIKey: usableAnthropicKey))

        case .codex:
            // Chosen, but this function only builds HTTP requests. The caller
            // is expected to have routed a Codex preference to the subprocess
            // responder before asking for a transport, so arriving here means
            // the CLI is no longer usable.
            return .failure(codexIsUsable ? .codexIsNotAnHTTPTransport : .codexNotUsable)

        case nil:
            if let usablePublikKey, publikKeyMaySpend {
                return .success(.publikAPI(key: usablePublikKey, gatewayBaseURL: publikGatewayBaseURL))
            }
            if let usableAnthropicKey {
                return .success(.bringYourOwnKey(anthropicAPIKey: usableAnthropicKey))
            }
            if codexIsUsable {
                return .failure(.codexIsNotAnHTTPTransport)
            }
            return .failure(.noCredentialsAvailable)
        }
    }

    /// The publik origin this build talks to. Production unless the bundle
    /// names another, and even then only an origin `GuideService` already
    /// trusts — publik itself or localhost — so a tampered Info.plist cannot
    /// redirect traffic to somebody else's server.
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

// MARK: - The reader's own Anthropic credential

/// Resolves the reader's OWN Anthropic key into a BYO transport. One place so
/// the chat path, the Tier C provider and the crash-path fix adapter never each
/// re-derive it.
///
/// This used to resolve two shapes — a pasted key or a Claude Code OAuth token —
/// and pick between them. The OAuth shape is gone (see the file header), so the
/// "which one?" precedence went with it; the type stays because three call
/// sites depend on it and because it is the right place to put the next shape
/// if there ever is one.
enum AnthropicBringYourOwnCredential {

    /// True when the reader has saved their own Anthropic key. Used for
    /// eligibility gates and panel state without pulling a secret into memory.
    static var isAvailable: Bool {
        KeychainStore.hasSecret(ofKind: .anthropicAPIKey)
    }

    /// The BYO transport for the reader's own key, or nil when none is stored.
    static func currentTransport() -> AssistantTransport? {
        guard let apiKey = KeychainStore.readSecret(ofKind: .anthropicAPIKey), !apiKey.isEmpty else {
            return nil
        }
        return .bringYourOwnKey(anthropicAPIKey: apiKey)
    }
}

// MARK: - Model aliases

/// The publik gateway takes alias names, never a raw upstream slug, and maps
/// each to a tier of its own choosing. Iris's model picker speaks in Anthropic
/// model names, so this is the translation.
enum PublikAPIModelAlias {
    static let fast = "publik-fast"
    static let balanced = "publik-balanced"
    static let smart = "publik-smart"

    /// The alias to ask for, given the model the reader picked in Iris.
    ///
    /// Deliberately coarse: the picker offers a fast model and a capable one,
    /// and the gateway's three tiers are the same idea. An unrecognized name
    /// maps to `balanced` rather than failing — a new model in the picker should
    /// degrade to a sensible tier, not break the route.
    static func alias(forIrisModelName irisModelName: String) -> String {
        let lowercasedName = irisModelName.lowercased()
        if lowercasedName.contains("haiku") { return fast }
        if lowercasedName.contains("opus") { return smart }
        return balanced
    }
}

// MARK: - Failures

/// Every way a chat request can fail before, during, or after transport, in the
/// vocabulary the panel uses to talk to the user.
enum AssistantTransportError: Error, Equatable, Sendable {
    /// No credential of any kind. The one state that is the reader's move.
    case noCredentialsAvailable
    /// publik API is the chosen provider but no key is stored yet.
    case publikAPINotSetUp
    /// A key exists but the first-run card has not been shown, so spending the
    /// starter would be the "silent starter" CONTRACT section 12 forbids.
    case publikAPIStarterNotYetDisclosed
    /// The chosen provider is Codex, which is a subprocess and not a URL route.
    case codexIsNotAnHTTPTransport
    /// Codex was chosen and its CLI is no longer signed in or findable.
    case codexNotUsable
    /// The reader chose their own Anthropic key and none is saved.
    case anthropicKeyNotSaved
    /// `rate_limited` (HTTP 429 + `Retry-After`).
    case rateLimited(retryAfterSeconds: Int?)
    /// HTTP 402 from the gateway: the wallet is empty. Carries the server's own
    /// message and the one link it sent, which are rendered verbatim.
    case publikAPIOutOfCredit(PublikAPIInsufficientCredit)
    /// publik's own outage, not the reader's.
    case assistantUnavailable
    /// Deliberately vague: the server's body may quote the model's own words
    /// back and is never surfaced.
    case requestFailed(statusCode: Int)
    /// The reader's own pasted key was rejected by Anthropic (401 on BYO).
    case bringYourOwnKeyRejected
    /// The gateway rejected the publik key (401).
    case publikAPIKeyRejected
    /// The network never got there.
    case transportFailure(reason: String)
    /// The key-isolation property was about to be violated. These should be
    /// impossible; they exist so that if it ever happens the request dies here
    /// rather than on the wire.
    case bringYourOwnKeyWouldLeaveAnthropic(attemptedHost: String)
    case publikKeyWouldLeavePublik(attemptedHost: String)

    /// What the panel shows. Lowercase to match the assistant's own voice in
    /// `CompanionManager`'s prompt, which is what the same text area displays.
    var userFacingMessage: String {
        switch self {
        case .noCredentialsAvailable:
            return "i need a model to answer with. set up publik API, add your own anthropic key, or sign in with codex — it's all in settings."
        case .publikAPINotSetUp:
            return "publik API isn't set up on this mac yet. open settings to finish it, or pick a different provider."
        case .publikAPIStarterNotYetDisclosed:
            return "open settings once to see what publik API costs, and i can start answering."
        case .codexIsNotAnHTTPTransport:
            return "codex answers through its own cli rather than a web request. if you're seeing this, something routed the question the wrong way — try again."
        case .codexNotUsable:
            return "your codex login isn't usable right now. run `codex login` in a terminal, or pick a different provider in settings."
        case .anthropicKeyNotSaved:
            return "you picked your own anthropic key, but there isn't one saved. paste one in settings, or pick a different provider."
        case .rateLimited(let retryAfterSeconds):
            return "you've hit the request limit for now. \(Self.retryPhrase(forRetryAfterSeconds: retryAfterSeconds))"
        case .publikAPIOutOfCredit(let insufficientCredit):
            // The server's own words, verbatim. CONTRACT section 12 item 3.
            return insufficientCredit.message
        case .assistantUnavailable:
            return "the assistant is unavailable right now. this one's on publik, not you — try again in a bit."
        case .requestFailed:
            return "hm, something went wrong reaching the assistant. check your connection and try again."
        case .bringYourOwnKeyRejected:
            return "anthropic refused the key iris has saved. check it's still active and paste it again."
        case .publikAPIKeyRejected:
            return "publik refused the key saved on this mac. set publik API up again in settings."
        case .transportFailure:
            return "i couldn't reach the assistant. check your connection and try again."
        case .bringYourOwnKeyWouldLeaveAnthropic:
            return "iris stopped that request: your api key was about to go somewhere it shouldn't."
        case .publikKeyWouldLeavePublik:
            return "iris stopped that request: your publik key was about to go somewhere it shouldn't."
        }
    }

    /// The one link to show under the message, when the failure carries one.
    /// Only the 402 does — everything else is fixed in settings, not on the web.
    var oneLinkToOffer: String? {
        switch self {
        case .publikAPIOutOfCredit(let insufficientCredit):
            return insufficientCredit.linkURLString
        default:
            return nil
        }
    }

    /// True when the right response is to put the provider choices back in
    /// front of the reader rather than just showing them a message.
    var shouldOfferProviderSetup: Bool {
        switch self {
        case .noCredentialsAvailable, .publikAPINotSetUp, .publikAPIStarterNotYetDisclosed,
             .anthropicKeyNotSaved, .codexNotUsable, .bringYourOwnKeyRejected,
             .publikAPIKeyRejected:
            return true
        case .codexIsNotAnHTTPTransport, .rateLimited, .publikAPIOutOfCredit, .assistantUnavailable,
             .requestFailed, .transportFailure, .bringYourOwnKeyWouldLeaveAnthropic,
             .publikKeyWouldLeavePublik:
            return false
        }
    }

    private static func retryPhrase(forRetryAfterSeconds retryAfterSeconds: Int?) -> String {
        guard let retryAfterSeconds, retryAfterSeconds > 0 else {
            return "try again shortly."
        }
        if retryAfterSeconds < 90 {
            return "try again in \(retryAfterSeconds) seconds."
        }
        let retryAfterMinutes = Int((Double(retryAfterSeconds) / 60.0).rounded(.up))
        if retryAfterMinutes < 90 {
            return "try again in about \(retryAfterMinutes) minutes."
        }
        let retryAfterHours = Int((Double(retryAfterMinutes) / 60.0).rounded(.up))
        return "try again in about \(retryAfterHours) hours."
    }

    // MARK: - Mapping the server's answer

    /// Turns one HTTP failure into the state the user sees.
    static func failure(
        forStatusCode statusCode: Int,
        serverErrorCode: String?,
        retryAfterHeaderValue: String?,
        credentialShape: AssistantTransport.CredentialShape,
        responseBody: Data? = nil
    ) -> AssistantTransportError {
        let retryAfterSeconds = retryAfterHeaderValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        switch statusCode {
        case 401:
            switch credentialShape {
            case .aPublikAPIKey: return .publikAPIKeyRejected
            case .aPastedAnthropicKey: return .bringYourOwnKeyRejected
            }
        case 402:
            // The gateway's "your wallet is empty". Its own message and link
            // are what the reader sees; a body we cannot parse degrades to the
            // generic failure rather than to copy Iris made up.
            if let responseBody, let insufficientCredit = PublikAPIInsufficientCredit.parse(responseBody: responseBody) {
                return .publikAPIOutOfCredit(insufficientCredit)
            }
            return .requestFailed(statusCode: statusCode)
        case 429:
            return .rateLimited(retryAfterSeconds: retryAfterSeconds)
        case 503:
            return .assistantUnavailable
        default:
            return .requestFailed(statusCode: statusCode)
        }
    }

    /// Pulls the `{"error": "code"}` string out of a failure body. Only the
    /// code is ever read — the rest of the body is dropped on the floor so it
    /// can never reach the panel.
    static func serverErrorCode(inFailureBody failureBodyData: Data) -> String? {
        guard let failureBody = try? JSONSerialization.jsonObject(with: failureBodyData) as? [String: Any],
              let serverErrorCode = failureBody["error"] as? String,
              !serverErrorCode.isEmpty else {
            return nil
        }
        return serverErrorCode
    }
}
