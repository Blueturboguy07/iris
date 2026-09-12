import Foundation

struct MaintainChatTurn: Sendable {
    let role: String
    let text: String
    var attachedImagePNGData: Data? = nil
}

@MainActor
protocol MaintainModelProviding: Sendable {
    var displayName: String { get }
    var identifier: String { get }
    var requestedModelDescription: String { get }
    var isAvailable: Bool { get }
    func respond(
        systemPrompt: String,
        conversation: [MaintainChatTurn],
        maximumOutputTokens: Int
    ) async throws -> String
}

enum MaintainModelProviderError: Error {
    enum MissingCredential: Equatable {
        case codexCommandNotFound
        case codexLoginNotUsable
        case codexTurnedTheCallDown(codexSaid: String)
    }

    case noCredential(MissingCredential)
    case requestFailed(String)
}

enum AssistantTransportError: Error {
    case rateLimited(retryAfterSeconds: Int?)
}

enum CodexCLILogin {
    enum ConnectionState {
        case usable

        var isUsable: Bool { true }
    }

    static func locateCodexBinary() -> String? { "/usr/bin/true" }
    static func currentState() -> ConnectionState { .usable }
    static func environmentForCodex() -> [String: String] { [:] }
}

enum CodexEditModelSelection {
    static func isValidIdentifier(_ identifier: String) -> Bool { true }
    static func requestedModelLabel(_ model: String?) -> String { model ?? "default" }
}

func irisTrace(_ message: String) {}
