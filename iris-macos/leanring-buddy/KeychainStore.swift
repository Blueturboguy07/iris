//
//  KeychainStore.swift
//  leanring-buddy
//
//  The only place in this app that touches the macOS Keychain. A small, fixed
//  set of secrets is ever stored: the user's own Anthropic API key and the
//  Claude Code OAuth token (two shapes of the BYO tier), the user's OpenAI key,
//  the Supabase refresh token (the funded tier), and the GitHub App token
//  pair (maintain mode's fork backup). None is ever printed, logged, written
//  to UserDefaults, or included in a crash report — the whole reason this
//  file exists rather than a `UserDefaults.set` call somewhere.
//
//  `docs/iris-assistant-protocol.md` section 1 makes the BYO key's isolation a
//  ship-blocker, and section 4 requires the refresh token to live here while
//  the access token stays in memory.
//
//  The GitHub pair was a deliberate, reviewed expansion (maintain mode M4,
//  2026-08-13): the access token expires in 8 hours and the refresh token in
//  6 months, so persisting both is what makes "connect GitHub once" true
//  without ever holding a long-lived credential.
//

import Foundation
import Security
#if canImport(IrisEnvironment)
import IrisEnvironment
#endif

/// The secrets Iris keeps. This is an enum rather than a free-form string
/// so a future caller cannot invent another Keychain item without editing
/// this file and being confronted with the rules above.
enum KeychainSecretKind: String, CaseIterable, Sendable {
    /// The user's own `sk-ant-…` key, used only against `api.anthropic.com`.
    case anthropicAPIKey = "anthropic-api-key"
    /// The Supabase refresh token. The access token it mints is deliberately
    /// NOT stored — it lives in `AccountService`'s memory for the session only.
    case supabaseRefreshToken = "supabase-refresh-token"
    /// GitHub App user access token (8-hour life), used only against
    /// `api.github.com` and `github.com` push URLs, only for fork backup.
    case gitHubAccessToken = "github-access-token"
    /// The 6-month refresh token that silently renews the one above.
    case gitHubRefreshToken = "github-refresh-token"
    /// The user's own OpenAI key, used only against `api.openai.com`, only
    /// for maintain mode's Tier C novel fixes when they choose OpenAI. Like
    /// the Anthropic key, it never reaches a publik host.
    case openAIAPIKey = "openai-api-key"
    /// A Claude Code OAuth token (`sk-ant-oat…`), obtained either from
    /// `claude setup-token` (long-lived) or imported from an existing
    /// `claude login`. It is a second shape of the user's OWN Anthropic
    /// credential — sent only to `api.anthropic.com`, and with an
    /// `Authorization: Bearer` + `anthropic-beta` pair rather than `x-api-key`
    /// (see `AssistantTransport`). Like the API key, it never reaches a publik
    /// host.
    case anthropicOAuthToken = "anthropic-oauth-token"

    var reconnectLabel: String {
        switch self {
        case .anthropicAPIKey: return "Anthropic API key"
        case .supabaseRefreshToken: return "publik account"
        case .gitHubAccessToken: return "GitHub access token"
        case .gitHubRefreshToken: return "GitHub refresh token"
        case .openAIAPIKey: return "OpenAI API key"
        case .anthropicOAuthToken: return "Claude Code login"
        }
    }
}

enum KeychainStoreError: Error, Equatable, Sendable {
    /// A `SecItem…` call failed. The OSStatus is carried because a caller may
    /// want to distinguish "the user cancelled the unlock prompt" from a real
    /// failure, but the secret itself is never part of the error.
    case keychainOperationFailed(status: OSStatus)
    case secretIsNotValidUTF8
}

/// A thin wrapper over `kSecClassGenericPassword`.
///
/// PRIVACY: nothing in this type ever interpolates a secret into a string. If
/// you add a `print` here, you have broken the property the whole assistant
/// design rests on. Log the *kind* of secret, never its value.
enum KeychainStore {
    /// The service name every item is filed under. It matches the app's bundle
    /// identifier so a user inspecting Keychain Access sees a name they can
    /// connect to Iris rather than an opaque string.
    static var keychainServiceName: String { IrisTestEnvironment.keychainServiceName }

    // MARK: - Writing

    /// Updates an existing secret, or adds it when absent. A denied update
    /// must not erase the previous credential, especially during token refresh.
    static func saveSecret(_ secretValue: String, ofKind secretKind: KeychainSecretKind) throws {
        guard let secretData = secretValue.data(using: .utf8) else {
            throw KeychainStoreError.secretIsNotValidUTF8
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: secretKind.rawValue,
            kSecValueData as String: secretData,
            // `AfterFirstUnlock` rather than `WhenUnlocked` because Iris is a
            // login item: it starts before the user has necessarily typed their
            // password into the login window a second time, and a token it
            // cannot read is a token that forces a pointless re-sign-in.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let addStatus = KeychainReadPolicy.updateOrAdd(update: {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainServiceName,
                kSecAttrAccount as String: secretKind.rawValue,
            ]
            let replacement: [String: Any] = [
                kSecValueData as String: secretData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(match as CFDictionary, replacement as CFDictionary)
        }, add: {
            SecItemAdd(addQuery as CFDictionary, nil)
        })
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.keychainOperationFailed(status: addStatus)
        }
    }

    // MARK: - Reading

    /// Reads a secret, or nil when there is none.
    ///
    /// Convenience for callers that only need a usable credential. Account
    /// restoration uses the detailed result so denied access is not sign-out.
    static func readSecret(ofKind secretKind: KeychainSecretKind) -> String? {
        readSecret(ofKind: secretKind, allowsUserInteraction: false)
    }

    /// Only an explicit settings action calls this, for one item per click.
    /// The credential stays inside the store; the UI receives no secret value.
    static func reconnectSavedSecret(ofKind secretKind: KeychainSecretKind) -> Bool {
        readSecret(ofKind: secretKind, allowsUserInteraction: true) != nil
    }

    private static func readSecret(
        ofKind secretKind: KeychainSecretKind, allowsUserInteraction: Bool
    ) -> String? {
        try? readSecretResult(ofKind: secretKind, allowsUserInteraction: allowsUserInteraction).get()
    }

    static func readSecretResult(
        ofKind secretKind: KeychainSecretKind, allowsUserInteraction: Bool = false
    ) -> Result<String?, KeychainStoreError> {
        let readQuery = KeychainReadPolicy.query(
            service: keychainServiceName, account: secretKind.rawValue,
            returnsData: true, allowsUserInteraction: allowsUserInteraction
        )

        var readResult: CFTypeRef?
        let readStatus = KeychainReadPolicy.perform(allowsUserInteraction: allowsUserInteraction) {
            SecItemCopyMatching(readQuery as CFDictionary, &readResult)
        }
        if readStatus == errSecItemNotFound { return .success(nil) }
        guard readStatus == errSecSuccess else {
            return .failure(.keychainOperationFailed(status: readStatus))
        }
        guard let secretData = readResult as? Data,
              let secretValue = String(data: secretData, encoding: .utf8) else {
            return .failure(.secretIsNotValidUTF8)
        }

        let trimmedSecretValue = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecretValue.isEmpty else { return .failure(.secretIsNotValidUTF8) }
        return .success(trimmedSecretValue)
    }

    /// Whether a secret is present, without pulling its bytes into memory.
    /// The panel uses this to decide what to show without ever handling the key.
    static func hasSecret(ofKind secretKind: KeychainSecretKind) -> Bool {
        let existenceQuery = KeychainReadPolicy.query(
            service: keychainServiceName, account: secretKind.rawValue, returnsData: false
        )
        return KeychainReadPolicy.perform {
            SecItemCopyMatching(existenceQuery as CFDictionary, nil)
        } == errSecSuccess
    }

    // MARK: - Deleting

    /// Removes a secret. Signing out and "forget my key" both land here.
    static func deleteSecret(ofKind secretKind: KeychainSecretKind) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: secretKind.rawValue,
        ]

        let deleteStatus = KeychainReadPolicy.perform {
            SecItemDelete(deleteQuery as CFDictionary)
        }
        // Deleting something that was never there is the caller's intent
        // already satisfied, not a failure.
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainStoreError.keychainOperationFailed(status: deleteStatus)
        }
    }

}
