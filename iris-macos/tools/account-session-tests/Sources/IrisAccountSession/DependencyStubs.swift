import Foundation

// These collaborators are intentionally inert. The account tests exercise the
// production session state machine, not the app's UI, CLI discovery, or model
// transport implementation.

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? { nil }
}

struct AuthCallbackDeepLink: Equatable, Sendable {
    let authorizationCode: String
    let opaqueStateToken: String
}

enum IrisDeepLink: Equatable, Sendable {
    case authCallback(AuthCallbackDeepLink)
    case other
}

enum IrisDeepLinkRejection: Error, Equatable, Sendable {
    case malformed

    var rejectionMessage: String { "stub rejection" }
}

enum IrisDeepLinkParser {
    static let irisURLScheme = "iris"

    static func parse(_ callbackURL: URL) -> Result<IrisDeepLink, IrisDeepLinkRejection> {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              components.scheme == irisURLScheme,
              components.host == "auth",
              components.path == "/callback",
              let queryItems = components.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value,
              let state = queryItems.first(where: { $0.name == "state" })?.value else {
            return .failure(.malformed)
        }
        return .success(.authCallback(AuthCallbackDeepLink(
            authorizationCode: code,
            opaqueStateToken: state
        )))
    }
}

enum ClaudeCodeLogin {
    struct ImportOutcome: Sendable {
        let didImport: Bool
    }

    static let isConnected = false

    static func importFromExistingClaudeLogin() -> ImportOutcome {
        ImportOutcome(didImport: false)
    }

    static func disconnect() {}
}

enum CodexCLILogin {
    enum ConnectionState: Sendable, Equatable {
        case codexNotInstalled

        var isUsable: Bool { false }
    }

    static func currentState() -> ConnectionState { .codexNotInstalled }
    static func disconnect() {}
}

enum AssistantTransport: Sendable {
    case funded(
        publikBaseURL: URL,
        currentAccessTokenProvider: @Sendable () async -> String?
    )
    case bringYourOwnKey(anthropicAPIKey: String)
    case bringYourOwnOAuthToken(anthropicOAuthToken: String)

    enum CredentialShape: Sendable {
        case aPastedAnthropicKey
    }

    func makeChatRequest() async throws -> URLRequest {
        URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    }

    static func validatedRequest(_ candidateRequest: URLRequest) throws -> URLRequest {
        candidateRequest
    }

    static func selectTransport(
        isSignedIn: Bool,
        publikBaseURL: URL,
        storedAnthropicAPIKey: String?,
        storedAnthropicOAuthToken: String? = nil,
        currentAccessTokenProvider: @escaping @Sendable () async -> String?
    ) -> Result<Self, AssistantTransportError> {
        if isSignedIn {
            return .success(.funded(
                publikBaseURL: publikBaseURL,
                currentAccessTokenProvider: currentAccessTokenProvider
            ))
        }
        if let storedAnthropicAPIKey, !storedAnthropicAPIKey.isEmpty {
            return .success(.bringYourOwnKey(anthropicAPIKey: storedAnthropicAPIKey))
        }
        if let storedAnthropicOAuthToken, !storedAnthropicOAuthToken.isEmpty {
            return .success(.bringYourOwnOAuthToken(anthropicOAuthToken: storedAnthropicOAuthToken))
        }
        return .failure(.noCredentialsAvailable)
    }
}

enum AssistantTransportError: Error, Equatable, Sendable {
    case noCredentialsAvailable
    case signInRequired
    case requestFailed(statusCode: Int)
    case transportFailure(reason: String)
    case failure(
        forStatusCode: Int,
        serverErrorCode: String?,
        retryAfterHeaderValue: String?,
        credentialShape: AssistantTransport.CredentialShape
    )

    var userFacingMessage: String {
        switch self {
        case .noCredentialsAvailable: return "No credentials available."
        case .signInRequired: return "Sign in required."
        case .requestFailed(let statusCode): return "Request failed (\(statusCode))."
        case .transportFailure: return "Transport failed."
        case .failure(let statusCode, _, _, _): return "Request failed (\(statusCode))."
        }
    }

    static func serverErrorCode(inFailureBody failureBodyData: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: failureBodyData) as? [String: Any] else {
            return nil
        }
        return body["error"] as? String
    }
}
