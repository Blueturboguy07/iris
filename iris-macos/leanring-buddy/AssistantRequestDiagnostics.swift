import Foundation

/// Only bounded categorical metadata reaches runtime logs. Provider messages,
/// request bodies, identifiers and credentials are never diagnostic fields.
nonisolated enum AssistantRequestDiagnostics {
    enum Route: String {
        case funded
        case anthropicKey = "anthropic-key"
        case claudeCodeLogin = "claude-code-login"
    }

    private static let safeErrorClasses: Set<String> = [
        "sign_in_required", "rate_limited", "daily_budget_exhausted",
        "assistant_unconfigured", "upstream_error", "invalid_request",
        "invalid_request_error", "authentication_error", "permission_error",
        "not_found_error", "request_too_large", "request_too_large_error",
        "rate_limit_error", "api_error", "overloaded_error", "model_not_found",
    ]

    static func errorClass(in responseData: Data) -> String {
        guard responseData.count <= 65_536,
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        else { return "unclassified" }
        let directCode = response["error"] as? String
        let nestedCode = (response["error"] as? [String: Any])?["type"] as? String
        guard let code = directCode ?? nestedCode, safeErrorClasses.contains(code) else {
            return "unclassified"
        }
        return code
    }

    static func traceLine(route: Route, statusCode: Int, responseData: Data) -> String {
        "assistant/request: failed route=\(route.rawValue) status=\(statusCode) class=\(errorClass(in: responseData))"
    }
}
