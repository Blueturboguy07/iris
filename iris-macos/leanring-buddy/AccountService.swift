//
//  AccountService.swift
//  leanring-buddy
//
//  Supabase auth without the Supabase SDK — three JSON endpoints and a system
//  browser are the whole of it, and adding a package dependency to reach them
//  would be a worse trade than the ~200 lines below.
//
//  `docs/iris-assistant-protocol.md` section 4 is the contract: native PKCE
//  OAuth in the **system browser** (never a webview) redirecting to
//  `iris://auth/callback`, or email+password against the same token endpoint;
//  refresh token in the Keychain, access token in memory only.
//
//  This type also owns the user's own Anthropic key, because "which credential
//  does Iris have" is one question with one answer and splitting it across two
//  objects is how a panel ends up showing a signed-out user a signed-in UI.
//

import AppKit
import AuthenticationServices
import Combine
import CryptoKit
import Foundation

// MARK: - Which publik project this build talks to

/// The Supabase project behind publik, read from the app bundle at runtime.
enum SupabaseProjectConfiguration {
    static let projectURLInfoPlistKey = "PublikSupabaseURL"
    static let anonymousKeyInfoPlistKey = "PublikSupabaseAnonKey"

    /// `https://<project>.supabase.co`, or nil when the bundle was built
    /// without it — in which case sign-in is simply unavailable rather than
    /// pointed at some default that would fail confusingly.
    static func projectURL() -> URL? {
        guard let projectURLString = AppBundleConfiguration.stringValue(forKey: projectURLInfoPlistKey),
              let projectURL = URL(string: projectURLString),
              projectURL.scheme == "https" else {
            return nil
        }
        return projectURL
    }

    /// The Supabase **anonymous** (publishable) key.
    ///
    /// THIS IS NOT A SECRET, and nobody should later "fix" it by moving it to
    /// the Keychain or a server. It is a public, row-level-security-protected
    /// value: publikhq.com already ships this exact string inside its
    /// JavaScript bundle, where any visitor can read it with View Source. It
    /// identifies the project and nothing else — every row it can reach is
    /// gated by RLS policies on the server, which is where the real
    /// authorization lives. The service-role key, which *is* a secret, never
    /// comes near this app.
    static func anonymousKey() -> String? {
        AppBundleConfiguration.stringValue(forKey: anonymousKeyInfoPlistKey)
    }
}

// MARK: - PKCE

/// Proof Key for Code Exchange (RFC 7636), the reason this app can do OAuth in
/// the system browser without holding a client secret it could not protect.
enum PKCECodeChallenge {
    /// 64 random bytes, which base64url-encode to 86 characters — comfortably
    /// inside RFC 7636's 43–128 character range and far past guessable.
    private static let codeVerifierByteCount = 64

    /// A fresh, high-entropy verifier. Kept in memory for exactly one sign-in
    /// attempt and then discarded; it is never persisted anywhere.
    static func generateCodeVerifier() -> String {
        var randomBytes = [UInt8](repeating: 0, count: codeVerifierByteCount)
        let randomGenerationStatus = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if randomGenerationStatus != errSecSuccess {
            // SecRandomCopyBytes does not fail in practice. If it somehow did,
            // falling back to a UUID pair is still 256 bits of system entropy
            // and is enormously better than proceeding with a fixed string.
            let fallbackEntropy = UUID().uuidString + UUID().uuidString
            return base64URLEncodedWithoutPadding(Data(fallbackEntropy.utf8))
        }
        return base64URLEncodedWithoutPadding(Data(randomBytes))
    }

    /// The S256 challenge for a verifier: base64url(SHA-256(verifier)), no
    /// padding. The authorization server stores this and can only match it
    /// against the verifier the app hands back at token-exchange time.
    static func codeChallenge(forCodeVerifier codeVerifier: String) -> String {
        let verifierDigest = SHA256.hash(data: Data(codeVerifier.utf8))
        return base64URLEncodedWithoutPadding(Data(verifierDigest))
    }

    /// base64url per RFC 4648 §5: `+` → `-`, `/` → `_`, and no `=` padding.
    /// Padding matters — an `=` in a query parameter is percent-encoded by some
    /// clients and not others, and the two spellings do not compare equal on
    /// the server.
    static func base64URLEncodedWithoutPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Who is signed in

/// The parts of a Supabase user Iris actually shows or uses. Deliberately not
/// the whole user object: the panel needs an email to display and an id for
/// nothing at all yet, and storing more invites storing more.
struct SignedInAccount: Equatable, Sendable {
    let userIdentifier: String
    let emailAddress: String?

    /// What the panel puts next to the sign-out button.
    var displayName: String {
        emailAddress ?? "signed in"
    }
}

/// The OAuth providers publik supports for desktop sign-in.
enum AccountSignInProvider: String, CaseIterable, Sendable {
    case google
    case github

    var displayName: String {
        switch self {
        case .google:
            return "Google"
        case .github:
            return "GitHub"
        }
    }
}

enum AccountServiceError: Error, Equatable, Sendable {
    case supabaseIsNotConfiguredInThisBuild
    case signInWasCancelled
    case theCallbackDidNotMatchThisSignInAttempt
    case theCallbackWasMalformed(reason: String)
    case authorizationServerRejectedTheRequest(reason: String)
    case couldNotReachTheAuthorizationServer(reason: String)
    case theSessionResponseCouldNotBeRead

    var userFacingMessage: String {
        switch self {
        case .supabaseIsNotConfiguredInThisBuild:
            return "This build of Iris was made without sign-in configured."
        case .signInWasCancelled:
            return "Sign-in was cancelled."
        case .theCallbackDidNotMatchThisSignInAttempt:
            return "That sign-in did not match the one Iris started. Try again."
        case .theCallbackWasMalformed(let reason):
            return "Iris could not read the sign-in response: \(reason)"
        case .authorizationServerRejectedTheRequest(let reason):
            return reason
        case .couldNotReachTheAuthorizationServer:
            return "Iris could not reach publik. Check your connection and try again."
        case .theSessionResponseCouldNotBeRead:
            return "Iris could not read the sign-in response. Try again."
        }
    }
}

// MARK: - The service

@MainActor
final class AccountService: ObservableObject {
    /// Who is signed in, or nil. This is the single source of truth the panel
    /// and the transport both read.
    @Published private(set) var signedInAccount: SignedInAccount?

    /// True while a browser sign-in or a password exchange is in flight, so the
    /// panel can disable its buttons instead of letting the user start two.
    @Published private(set) var isSignInInProgress = false

    /// The last thing that went wrong, in words meant for the user. Cleared the
    /// moment another attempt starts.
    @Published private(set) var signInFailureMessage: String?

    /// Whether a BYO Anthropic key is stored. Deliberately a Bool and not the
    /// key: once saved, the key is never read back into the UI layer.
    @Published private(set) var hasStoredAnthropicAPIKey: Bool = false

    /// Whether a Claude Code OAuth token is connected (the CLI-login path). Like
    /// the key flag, a Bool and never the token itself. The panel reads this to
    /// show the CLI-login as connected and offer disconnect.
    @Published private(set) var hasConnectedClaudeCodeLogin: Bool = false

    /// Whether the reader has a usable Codex CLI login. Unlike every other flag
    /// here, this is NOT backed by a Keychain item: Iris does not hold the Codex
    /// credential at all (see `CodexCLILogin.swift`). It is read from the CLI's
    /// own `auth.json`, so it can also go false without Iris doing anything —
    /// the reader running `codex logout` in a terminal, for instance — which is
    /// why the panel re-reads it on appear rather than trusting a cached value.
    @Published private(set) var codexLoginState: CodexCLILogin.ConnectionState = .codexNotInstalled

    /// Whether Codex is currently usable as a Tier C provider.
    var hasConnectedCodexLogin: Bool { codexLoginState.isUsable }

    /// True while the BYO key field is being checked against Anthropic.
    @Published private(set) var isValidatingAnthropicAPIKey = false

    /// Why a pasted key was refused, if it was.
    @Published private(set) var anthropicAPIKeyFailureMessage: String?

    /// The access token, in memory only — never written to the Keychain, never
    /// to UserDefaults. It is short-lived by design; the refresh token is the
    /// thing worth persisting and is the only thing that is.
    private var currentAccessToken: String?
    private var currentAccessTokenExpiryDate: Date?

    /// Held so the browser sheet is not deallocated mid-flow.
    private var activeWebAuthenticationSession: ASWebAuthenticationSession?
    private let webAuthenticationPresentationAnchorProvider = WebAuthenticationPresentationAnchorProvider()

    private let urlSession: URLSession

    /// A token this close to expiring is treated as already expired, so a
    /// request cannot set off with a token that dies in flight.
    private static let accessTokenRefreshLeadTimeInSeconds: TimeInterval = 60

    /// The redirect the protocol document names, and the only one this app
    /// accepts (`docs/iris-assistant-protocol.md` section 3).
    private static let authCallbackURLString = "iris://auth/callback"

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        self.hasStoredAnthropicAPIKey = KeychainStore.hasSecret(ofKind: .anthropicAPIKey)
        self.hasConnectedClaudeCodeLogin = KeychainStore.hasSecret(ofKind: .anthropicOAuthToken)
        self.codexLoginState = CodexCLILogin.currentState()
    }

    // MARK: - Restoring a previous session

    /// Trades the stored refresh token for a fresh access token at launch, so a
    /// user who signed in last week is still signed in today without seeing a
    /// browser window. Silent on failure by design: an expired or revoked
    /// refresh token means "signed out", which the panel already knows how to
    /// show, and an error toast at launch would be noise.
    func restorePreviousSessionIfPossible() async {
        guard KeychainStore.readSecret(ofKind: .supabaseRefreshToken) != nil else { return }
        _ = await refreshAccessTokenUsingStoredRefreshToken()
    }

    // MARK: - OAuth in the system browser

    /// Runs the full PKCE dance: verifier → challenge → system browser →
    /// callback → token exchange.
    func signIn(withProvider provider: AccountSignInProvider) async {
        guard !isSignInInProgress else { return }

        isSignInInProgress = true
        signInFailureMessage = nil
        defer { isSignInInProgress = false }

        do {
            guard let supabaseProjectURL = SupabaseProjectConfiguration.projectURL(),
                  let supabaseAnonymousKey = SupabaseProjectConfiguration.anonymousKey() else {
                throw AccountServiceError.supabaseIsNotConfiguredInThisBuild
            }

            let codeVerifier = PKCECodeChallenge.generateCodeVerifier()
            let codeChallenge = PKCECodeChallenge.codeChallenge(forCodeVerifier: codeVerifier)
            // Our own CSRF value. It rides in the redirect target rather than a
            // separate parameter because Supabase echoes the redirect back
            // verbatim and appends `code` to it — see the comment on
            // `authorizationURL` below.
            let opaqueStateToken = PKCECodeChallenge.generateCodeVerifier()

            let authorizationURL = try Self.authorizationURL(
                supabaseProjectURL: supabaseProjectURL,
                provider: provider,
                codeChallenge: codeChallenge,
                opaqueStateToken: opaqueStateToken
            )

            let callbackURL = try await presentSystemBrowserSignIn(startingAt: authorizationURL)

            let authorizationCode = try Self.authorizationCode(
                fromCallbackURL: callbackURL,
                expectedOpaqueStateToken: opaqueStateToken
            )

            let session = try await exchangeAuthorizationCodeForSession(
                authorizationCode: authorizationCode,
                codeVerifier: codeVerifier,
                supabaseProjectURL: supabaseProjectURL,
                supabaseAnonymousKey: supabaseAnonymousKey
            )
            adoptSession(session)
        } catch let accountServiceError as AccountServiceError {
            // A cancelled sign-in is the user changing their mind, not a
            // failure worth putting red text on the panel for.
            if accountServiceError != .signInWasCancelled {
                signInFailureMessage = accountServiceError.userFacingMessage
            }
        } catch {
            signInFailureMessage = AccountServiceError
                .couldNotReachTheAuthorizationServer(reason: error.localizedDescription)
                .userFacingMessage
        }
    }

    /// Builds `{supabase}/auth/v1/authorize?provider=…&redirect_to=…&code_challenge=…`.
    ///
    /// The state token is folded into `redirect_to` rather than sent as its own
    /// `state` parameter because Supabase manages `state` itself for the trip
    /// to the identity provider, but parses `redirect_to` as a URL and merges
    /// its own `code` into that URL's query. So a redirect of
    /// `iris://auth/callback?state=abc` comes back as
    /// `iris://auth/callback?state=abc&code=xyz` — exactly the shape
    /// `IrisDeepLinkParser` already validates.
    ///
    /// NOTE FOR DEPLOYMENT: publik's Supabase project must allow
    /// `iris://auth/callback` *with a query string* in its redirect allow list
    /// (an `iris://auth/callback*` entry). An exact-match-only entry rejects the
    /// state token and sign-in fails at the authorize step.
    static func authorizationURL(
        supabaseProjectURL: URL,
        provider: AccountSignInProvider,
        codeChallenge: String,
        opaqueStateToken: String
    ) throws -> URL {
        let redirectTarget = "\(authCallbackURLString)?state=\(opaqueStateToken)"

        var authorizationComponents = URLComponents(
            url: supabaseProjectURL.appendingPathComponent("auth/v1/authorize"),
            resolvingAgainstBaseURL: false
        )
        authorizationComponents?.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirectTarget),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]

        guard let authorizationURL = authorizationComponents?.url else {
            throw AccountServiceError.supabaseIsNotConfiguredInThisBuild
        }
        return authorizationURL
    }

    /// Opens the user's real browser, not a webview.
    ///
    /// `ASWebAuthenticationSession` is what makes that possible while still
    /// delivering the callback privately back to this app: the `iris://` URL is
    /// handed to this session directly rather than being broadcast to whatever
    /// happens to have registered the scheme. Section 4 of the protocol
    /// document requires the system browser specifically — an embedded webview
    /// would ask the user to type their Google password into a window Iris
    /// controls, which is exactly the shape of a credential-phishing screen.
    private func presentSystemBrowserSignIn(startingAt authorizationURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let webAuthenticationSession = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: IrisDeepLinkParser.irisURLScheme
            ) { callbackURL, sessionError in
                if let sessionError {
                    let wasCancelledByUser = (sessionError as? ASWebAuthenticationSessionError)?.code
                        == .canceledLogin
                    continuation.resume(throwing: wasCancelledByUser
                        ? AccountServiceError.signInWasCancelled
                        : AccountServiceError.couldNotReachTheAuthorizationServer(
                            reason: sessionError.localizedDescription
                        ))
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: AccountServiceError.signInWasCancelled)
                    return
                }
                continuation.resume(returning: callbackURL)
            }

            webAuthenticationSession.presentationContextProvider = webAuthenticationPresentationAnchorProvider
            // Not ephemeral: reusing the browser's existing Google or GitHub
            // session is the entire reason a user prefers this to typing a
            // password again.
            webAuthenticationSession.prefersEphemeralWebBrowserSession = false

            activeWebAuthenticationSession = webAuthenticationSession
            if !webAuthenticationSession.start() {
                continuation.resume(throwing: AccountServiceError.couldNotReachTheAuthorizationServer(
                    reason: "the sign-in window could not be opened"
                ))
            }
        }
    }

    /// Validates the callback with the parser this app already has.
    ///
    /// `IrisDeepLinkParser` is reused rather than reimplemented on purpose: it
    /// is the one place that knows which `iris://` shapes are acceptable, it
    /// already refuses a code without a state (the shape a CSRF attempt takes),
    /// and a second parser would be a second thing to keep in agreement with it.
    static func authorizationCode(
        fromCallbackURL callbackURL: URL,
        expectedOpaqueStateToken: String
    ) throws -> String {
        let parseResult = IrisDeepLinkParser.parse(callbackURL)

        guard case .success(let deepLink) = parseResult else {
            let rejectionMessage: String
            if case .failure(let rejection) = parseResult {
                rejectionMessage = rejection.rejectionMessage
            } else {
                rejectionMessage = "unsupported Iris link"
            }
            throw AccountServiceError.theCallbackWasMalformed(reason: rejectionMessage)
        }
        guard case .authCallback(let authCallback) = deepLink else {
            throw AccountServiceError.theCallbackWasMalformed(reason: "that was not a sign-in link")
        }
        guard authCallback.opaqueStateToken == expectedOpaqueStateToken else {
            throw AccountServiceError.theCallbackDidNotMatchThisSignInAttempt
        }
        return authCallback.authorizationCode
    }

    // MARK: - Email and password

    /// For the people who made a publik account with an email and a password
    /// before any of this existed. Same token endpoint, different grant.
    func signIn(withEmailAddress emailAddress: String, password: String) async {
        guard !isSignInInProgress else { return }

        isSignInInProgress = true
        signInFailureMessage = nil
        defer { isSignInInProgress = false }

        do {
            guard let supabaseProjectURL = SupabaseProjectConfiguration.projectURL(),
                  let supabaseAnonymousKey = SupabaseProjectConfiguration.anonymousKey() else {
                throw AccountServiceError.supabaseIsNotConfiguredInThisBuild
            }

            let session = try await requestSession(
                grantType: "password",
                requestBody: ["email": emailAddress, "password": password],
                supabaseProjectURL: supabaseProjectURL,
                supabaseAnonymousKey: supabaseAnonymousKey
            )
            adoptSession(session)
        } catch let accountServiceError as AccountServiceError {
            signInFailureMessage = accountServiceError.userFacingMessage
        } catch {
            signInFailureMessage = AccountServiceError
                .couldNotReachTheAuthorizationServer(reason: error.localizedDescription)
                .userFacingMessage
        }
    }

    // MARK: - Signing out

    /// Forgets the session on this machine. The refresh token is deleted from
    /// the Keychain and the access token stops existing with the process.
    func signOut() {
        currentAccessToken = nil
        currentAccessTokenExpiryDate = nil
        signedInAccount = nil
        signInFailureMessage = nil
        try? KeychainStore.deleteSecret(ofKind: .supabaseRefreshToken)
    }

    // MARK: - Handing a token to the transport

    /// The access token a request should use right now, refreshing first when
    /// the one in memory is missing or about to expire. Nil means "not signed
    /// in", which the transport reports as `signInRequired`.
    func currentAccessTokenRefreshingIfNeeded() async -> String? {
        if let currentAccessToken,
           let currentAccessTokenExpiryDate,
           currentAccessTokenExpiryDate.timeIntervalSinceNow > Self.accessTokenRefreshLeadTimeInSeconds {
            return currentAccessToken
        }
        return await refreshAccessTokenUsingStoredRefreshToken()
    }

    /// Called when the funded route answered 401 despite a token that looked
    /// live. One refresh is attempted; if that fails the user is signed out,
    /// because a refresh token the server will not honor is not worth keeping.
    func handleAccessTokenRejectedByServer() async {
        currentAccessToken = nil
        currentAccessTokenExpiryDate = nil
        if await refreshAccessTokenUsingStoredRefreshToken() == nil {
            signOut()
        }
    }

    @discardableResult
    private func refreshAccessTokenUsingStoredRefreshToken() async -> String? {
        guard let storedRefreshToken = KeychainStore.readSecret(ofKind: .supabaseRefreshToken),
              let supabaseProjectURL = SupabaseProjectConfiguration.projectURL(),
              let supabaseAnonymousKey = SupabaseProjectConfiguration.anonymousKey() else {
            return nil
        }

        do {
            let session = try await requestSession(
                grantType: "refresh_token",
                requestBody: ["refresh_token": storedRefreshToken],
                supabaseProjectURL: supabaseProjectURL,
                supabaseAnonymousKey: supabaseAnonymousKey
            )
            adoptSession(session)
            return session.accessToken
        } catch {
            // A refresh that the server refused means the session is over.
            // A refresh that never reached the server means we are offline, and
            // throwing the stored token away over a flaky network would sign
            // the user out for no reason — so only the former clears state.
            if case AccountServiceError.authorizationServerRejectedTheRequest = error {
                signOut()
            }
            return nil
        }
    }

    // MARK: - Talking to Supabase

    /// The one decoded shape all three grants return.
    private struct SupabaseSession: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresInSeconds: Int?
        let user: SupabaseUser?

        struct SupabaseUser: Decodable {
            let identifier: String
            let emailAddress: String?

            enum CodingKeys: String, CodingKey {
                case identifier = "id"
                case emailAddress = "email"
            }
        }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresInSeconds = "expires_in"
            case user
        }
    }

    private func exchangeAuthorizationCodeForSession(
        authorizationCode: String,
        codeVerifier: String,
        supabaseProjectURL: URL,
        supabaseAnonymousKey: String
    ) async throws -> SupabaseSession {
        try await requestSession(
            grantType: "pkce",
            requestBody: ["auth_code": authorizationCode, "code_verifier": codeVerifier],
            supabaseProjectURL: supabaseProjectURL,
            supabaseAnonymousKey: supabaseAnonymousKey
        )
    }

    /// `POST {supabase}/auth/v1/token?grant_type=<grant>`, which serves the
    /// PKCE exchange, the password grant, and the refresh grant identically
    /// apart from the body.
    private func requestSession(
        grantType: String,
        requestBody: [String: String],
        supabaseProjectURL: URL,
        supabaseAnonymousKey: String
    ) async throws -> SupabaseSession {
        var tokenURLComponents = URLComponents(
            url: supabaseProjectURL.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        )
        tokenURLComponents?.queryItems = [URLQueryItem(name: "grant_type", value: grantType)]
        guard let tokenURL = tokenURLComponents?.url else {
            throw AccountServiceError.supabaseIsNotConfiguredInThisBuild
        }

        var tokenRequest = URLRequest(url: tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.timeoutInterval = 30
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Supabase identifies the project by this header. It is the public
        // anon key — see the comment on `SupabaseProjectConfiguration.anonymousKey`.
        tokenRequest.setValue(supabaseAnonymousKey, forHTTPHeaderField: "apikey")
        tokenRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: tokenRequest)
        } catch {
            throw AccountServiceError.couldNotReachTheAuthorizationServer(
                reason: error.localizedDescription
            )
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AccountServiceError.theSessionResponseCouldNotBeRead
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AccountServiceError.authorizationServerRejectedTheRequest(
                reason: Self.userFacingReason(forAuthFailureBody: responseData, statusCode: httpResponse.statusCode)
            )
        }

        guard let session = try? JSONDecoder().decode(SupabaseSession.self, from: responseData) else {
            throw AccountServiceError.theSessionResponseCouldNotBeRead
        }
        return session
    }

    /// Reads only the named fields of a Supabase error body. Anything else in
    /// the body is discarded rather than shown, so an unexpected payload can
    /// never become text on the panel.
    private static func userFacingReason(forAuthFailureBody failureBodyData: Data, statusCode: Int) -> String {
        guard let failureBody = try? JSONSerialization.jsonObject(with: failureBodyData) as? [String: Any] else {
            return "Sign-in failed (\(statusCode))."
        }
        if let errorDescription = failureBody["error_description"] as? String, !errorDescription.isEmpty {
            return errorDescription
        }
        if let message = failureBody["msg"] as? String, !message.isEmpty {
            return message
        }
        if let message = failureBody["message"] as? String, !message.isEmpty {
            return message
        }
        return "Sign-in failed (\(statusCode))."
    }

    /// Takes a freshly minted session: refresh token to the Keychain, access
    /// token to memory, identity to the published state the panel reads.
    private func adoptSession(_ session: SupabaseSession) {
        currentAccessToken = session.accessToken
        let expiresInSeconds = TimeInterval(session.expiresInSeconds ?? 3600)
        currentAccessTokenExpiryDate = Date().addingTimeInterval(expiresInSeconds)

        try? KeychainStore.saveSecret(session.refreshToken, ofKind: .supabaseRefreshToken)

        if let user = session.user {
            signedInAccount = SignedInAccount(
                userIdentifier: user.identifier,
                emailAddress: user.emailAddress
            )
        } else if signedInAccount == nil {
            // A refresh response can omit the user object. Keeping whatever the
            // panel already displays is better than blanking the email out.
            signedInAccount = SignedInAccount(userIdentifier: "", emailAddress: nil)
        }
        signInFailureMessage = nil
    }

    // MARK: - Choosing a route

    /// The transport the assistant should use right now.
    ///
    /// This is the join between identity and networking: `AssistantTransport`
    /// knows the rules about which credential may reach which host, and this
    /// service is the only thing that knows which credentials exist. Neither
    /// half can pick a route on its own, and that is deliberate.
    func currentAssistantTransport(
        publikBaseURL: URL
    ) -> Result<AssistantTransport, AssistantTransportError> {
        AssistantTransport.selectTransport(
            isSignedIn: signedInAccount != nil,
            publikBaseURL: publikBaseURL,
            storedAnthropicAPIKey: storedAnthropicAPIKey(),
            storedAnthropicOAuthToken: KeychainStore.readSecret(ofKind: .anthropicOAuthToken),
            currentAccessTokenProvider: { [weak self] in
                guard let self else { return nil }
                return await self.currentAccessTokenRefreshingIfNeeded()
            }
        )
    }

    /// What will answer a QUESTION, in the reader's words.
    ///
    /// Split out from `activeTierDescription` — which described "the next
    /// request" as though there were one kind, was written for a status line,
    /// and was then never rendered anywhere. Chat and app-editing genuinely run
    /// on different providers at the same time: a signed-in reader with a Codex
    /// login asks publik and edits with Codex. One sentence could not say that,
    /// so a reader who connected Codex and then saw only "Sonnet | Opus" had
    /// nothing on screen to correct them. Editing's side is
    /// `MaintainModelProviderResolver.firstAvailable()`.
    /// Whether asking a question can go anywhere at all.
    ///
    /// A Codex login is deliberately not enough: chat needs the Anthropic
    /// Messages wire format with tool-use blocks, which `codex exec` cannot
    /// serve. A reader whose only credential is Codex can edit apps and cannot
    /// ask questions, and the composer says so rather than offering a field
    /// that fails on send.
    var canAnswerQuestions: Bool {
        signedInAccount != nil || hasStoredAnthropicAPIKey || hasConnectedClaudeCodeLogin
    }

    var chatProviderDescription: String {
        if signedInAccount != nil { return "Answers come from publik" }
        if hasStoredAnthropicAPIKey { return "Answers use your Anthropic key" }
        if hasConnectedClaudeCodeLogin { return "Answers use your Claude Code login" }
        // Deliberately not Codex: both chat routes speak the Anthropic Messages
        // wire format with tool-use blocks, which `codex exec` cannot serve
        // without a translation layer and the loss of streaming.
        return "Sign in or add a key to ask questions"
    }

    /// Which tier the next request will take, for the panel's status line.
    var activeTierDescription: String? {
        if signedInAccount != nil {
            return "publik account"
        }
        if hasStoredAnthropicAPIKey {
            return "your Anthropic key"
        }
        if hasConnectedClaudeCodeLogin {
            return "your Claude Code login"
        }
        // Codex is last for the same reason it is last in the Tier C resolver,
        // and it is named as an app-editing credential rather than a chat one:
        // chat speaks the Anthropic Messages wire format on both of its routes
        // (`docs/iris-assistant-protocol.md` section 1), which a Codex login
        // cannot serve. It powers app editing, which is where Tier C runs.
        if hasConnectedCodexLogin {
            return "your Codex login (app editing)"
        }
        return nil
    }

    // MARK: - Claude Code CLI login

    /// Re-reads whether a Claude Code OAuth token is connected. Called by the
    /// panel after a `setup-token` capture or an import so the connected state
    /// updates without reconstructing the service.
    func refreshClaudeCodeLoginState() {
        hasConnectedClaudeCodeLogin = ClaudeCodeLogin.isConnected
    }

    /// Imports the token from an existing `claude login`, then refreshes state.
    /// Returns the outcome so the panel can show the right message.
    @discardableResult
    func importClaudeCodeLogin() -> ClaudeCodeLogin.ImportOutcome {
        let outcome = ClaudeCodeLogin.importFromExistingClaudeLogin()
        refreshClaudeCodeLoginState()
        return outcome
    }

    /// Forgets the connected Claude Code token. The pasted API key, a separate
    /// credential, is untouched.
    func disconnectClaudeCodeLogin() {
        ClaudeCodeLogin.disconnect()
        refreshClaudeCodeLoginState()
    }

    // MARK: - Codex CLI login

    /// Re-reads the Codex CLI's login state from disk. Cheap (one file read),
    /// and called on panel appear because the state can change outside Iris.
    func refreshCodexLoginState() {
        codexLoginState = CodexCLILogin.currentState()
    }

    /// Asks the Codex CLI to forget its own login (`codex logout`), then
    /// re-reads. Iris never deletes the credential file itself — it is the
    /// CLI's, and the CLI is the only thing that should decide its shape.
    func disconnectCodexLogin() {
        CodexCLILogin.disconnect()
        refreshCodexLoginState()
    }

    // MARK: - The user's own Anthropic key

    /// The stored BYO key, for the transport only.
    ///
    /// The panel never calls this: once saved, a key is never echoed back into
    /// the UI, which is why the field shows a placeholder rather than the value
    /// after a save.
    func storedAnthropicAPIKey() -> String? {
        KeychainStore.readSecret(ofKind: .anthropicAPIKey)
    }

    /// Checks a pasted key against Anthropic before storing it, so a typo is
    /// caught here rather than at the bottom of the next screenshot request.
    ///
    /// The check is `/v1/messages/count_tokens`, which is free, returns in a few
    /// hundred milliseconds, and — critically — exercises the same credential on
    /// the same host the real requests will use.
    @discardableResult
    func validateAndSaveAnthropicAPIKey(_ candidateAPIKey: String) async -> Bool {
        let trimmedCandidateAPIKey = candidateAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCandidateAPIKey.isEmpty else {
            anthropicAPIKeyFailureMessage = "Paste your Anthropic API key first."
            return false
        }

        isValidatingAnthropicAPIKey = true
        anthropicAPIKeyFailureMessage = nil
        defer { isValidatingAnthropicAPIKey = false }

        do {
            try await verifyAnthropicAPIKeyIsUsable(trimmedCandidateAPIKey)
        } catch let transportError as AssistantTransportError {
            anthropicAPIKeyFailureMessage = transportError.userFacingMessage
            return false
        } catch {
            anthropicAPIKeyFailureMessage = "Iris could not reach Anthropic to check that key."
            return false
        }

        do {
            try KeychainStore.saveSecret(trimmedCandidateAPIKey, ofKind: .anthropicAPIKey)
        } catch {
            anthropicAPIKeyFailureMessage = "macOS would not let Iris store that key in your Keychain."
            return false
        }

        hasStoredAnthropicAPIKey = true
        return true
    }

    /// Deletes the stored key. The user is back to the funded tier, or to
    /// nothing at all if they are also signed out.
    func forgetAnthropicAPIKey() {
        try? KeychainStore.deleteSecret(ofKind: .anthropicAPIKey)
        hasStoredAnthropicAPIKey = false
        anthropicAPIKeyFailureMessage = nil
    }

    /// One cheap, real request with the candidate key.
    ///
    /// It is built through `AssistantTransport` rather than by hand so that the
    /// key-isolation guarantee covers validation too — this request cannot be
    /// pointed at a publik host any more than a chat request can.
    private func verifyAnthropicAPIKeyIsUsable(_ candidateAPIKey: String) async throws {
        let transport = AssistantTransport.bringYourOwnKey(anthropicAPIKey: candidateAPIKey)
        var countTokensRequest = try await transport.makeChatRequest()

        // The count-tokens endpoint lives one path component below the messages
        // endpoint the transport produced.
        guard let messagesURL = countTokensRequest.url,
              let countTokensURL = URL(string: messagesURL.absoluteString + "/count_tokens") else {
            throw AssistantTransportError.requestFailed(statusCode: -1)
        }
        countTokensRequest.url = countTokensURL
        countTokensRequest.timeoutInterval = 20
        countTokensRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "messages": [["role": "user", "content": "hi"]],
        ])

        // Re-validated after the URL was edited: the check is worth nothing if
        // it only runs on the request the transport handed back untouched.
        let validatedCountTokensRequest = try AssistantTransport.validatedRequest(countTokensRequest)

        let responseData: Data
        let urlResponse: URLResponse
        do {
            (responseData, urlResponse) = try await urlSession.data(for: validatedCountTokensRequest)
        } catch {
            throw AssistantTransportError.transportFailure(reason: error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw AssistantTransportError.requestFailed(statusCode: -1)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AssistantTransportError.failure(
                forStatusCode: httpResponse.statusCode,
                serverErrorCode: AssistantTransportError.serverErrorCode(inFailureBody: responseData),
                retryAfterHeaderValue: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                // This is the validation call made the moment a reader pastes a
                // key, so a 401 here means exactly that key was refused.
                credentialShape: .aPastedAnthropicKey
            )
        }
    }
}

// MARK: - Where the browser sheet attaches

/// `ASWebAuthenticationSession` insists on an anchor window even when, as here,
/// it goes on to hand the URL to the user's real browser. Iris is an
/// `LSUIElement` app whose only windows are borderless panels, so a hidden
/// zero-size window is kept for the purpose rather than attaching the sheet to
/// the companion panel — which dismisses itself on any outside click and would
/// take the sign-in flow with it.
private final class WebAuthenticationPresentationAnchorProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {

    private lazy var hiddenAnchorWindow: NSWindow = {
        let anchorWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchorWindow.isReleasedWhenClosed = false
        return anchorWindow
    }()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? hiddenAnchorWindow
    }
}
