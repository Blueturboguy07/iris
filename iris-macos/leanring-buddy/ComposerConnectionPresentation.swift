import Foundation

/// Wording from already-known connection state. This never checks credentials,
/// picks a provider, redirects a request, or starts a connection flow.
nonisolated struct ComposerConnectionPresentation: Equatable, Sendable {
    enum Context: Sendable {
        case screenHelp
        case projectEdit
    }

    enum HelpConnection: Sendable {
        case unavailable
        case publik
        case anthropicKey
        case claudeCodeLogin
    }

    enum EditConnection: Sendable {
        case unavailable
        case codex
        case anthropic
        case openAI
    }

    let connectionLabel: String
    let showsModelControl: Bool
    let inlineMessage: String?
    /// A small settings link, not a second model control or primary action.
    let settingsLinkLabel: String?

    static func canSendTypedRequest(
        hasText: Bool,
        requestIsBeingSizedUp: Bool,
        context: Context,
        helpIsAvailable: Bool
    ) -> Bool {
        hasText && !requestIsBeingSizedUp && (context == .projectEdit || helpIsAvailable)
    }

    static func resolve(
        context: Context,
        help: HelpConnection,
        editing: EditConnection,
        codexIsConnected: Bool
    ) -> Self {
        switch context {
        case .screenHelp:
            switch help {
            case .publik:
                return connected("Screen help through publik")
            case .anthropicKey:
                return connected("Screen help through your Anthropic key")
            case .claudeCodeLogin:
                return connected("Screen help through Claude Code")
            case .unavailable:
                return Self(
                    connectionLabel: "Screen help not connected",
                    showsModelControl: false,
                    inlineMessage: codexIsConnected
                        ? "Codex is connected for app edits. Screen help needs a separate connection."
                        : "Connect screen help to ask questions about what is on your screen.",
                    settingsLinkLabel: "Connect screen help"
                )
            }
        case .projectEdit:
            switch editing {
            case .codex:
                return connected("Codex connected for app edits")
            case .anthropic:
                return connected("Anthropic connected for app edits")
            case .openAI:
                return connected("OpenAI connected for app edits")
            case .unavailable:
                return Self(
                    connectionLabel: "App editing not connected",
                    showsModelControl: false,
                    inlineMessage: help == .unavailable
                        ? "Connect an editing provider to change this app."
                        : "Screen help is connected. App edits need an editing provider.",
                    settingsLinkLabel: "Connect app editing"
                )
            }
        }
    }

    private static func connected(_ label: String) -> Self {
        Self(connectionLabel: label, showsModelControl: true,
             inlineMessage: nil, settingsLinkLabel: nil)
    }
}
