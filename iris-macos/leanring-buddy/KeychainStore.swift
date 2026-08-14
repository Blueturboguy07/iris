//
//  KeychainStore.swift
//  leanring-buddy
//
//  The only place in this app that touches the macOS Keychain. Exactly four
//  secrets are ever stored: the user's own Anthropic API key (the BYO tier),
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
    static let keychainServiceName = "com.publikhq.iris"

    // MARK: - Writing

    /// Stores (or replaces) a secret. Replacing is done as delete-then-add
    /// rather than `SecItemUpdate` so the item's accessibility attribute is
    /// re-applied every time instead of inheriting whatever an older build set.
    static func saveSecret(_ secretValue: String, ofKind secretKind: KeychainSecretKind) throws {
        guard let secretData = secretValue.data(using: .utf8) else {
            throw KeychainStoreError.secretIsNotValidUTF8
        }

        // A failure to delete is fine — the usual case is that nothing was
        // stored yet. Only the add below is allowed to fail loudly.
        deleteSecretIgnoringFailure(ofKind: secretKind)

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

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.keychainOperationFailed(status: addStatus)
        }
    }

    // MARK: - Reading

    /// Reads a secret, or nil when there is none.
    ///
    /// Every failure — item missing, keychain locked, unsigned build with no
    /// keychain access — collapses to nil on purpose. A read happens on the
    /// launch path, and an app that refuses to start because the Keychain was
    /// unhappy is worse than an app that asks the user to sign in again.
    static func readSecret(ofKind secretKind: KeychainSecretKind) -> String? {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: secretKind.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var readResult: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &readResult)
        guard readStatus == errSecSuccess,
              let secretData = readResult as? Data,
              let secretValue = String(data: secretData, encoding: .utf8) else {
            return nil
        }

        let trimmedSecretValue = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedSecretValue.isEmpty ? nil : trimmedSecretValue
    }

    /// Whether a secret is present, without pulling its bytes into memory.
    /// The panel uses this to decide what to show without ever handling the key.
    static func hasSecret(ofKind secretKind: KeychainSecretKind) -> Bool {
        let existenceQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: secretKind.rawValue,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(existenceQuery as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - Deleting

    /// Removes a secret. Signing out and "forget my key" both land here.
    static func deleteSecret(ofKind secretKind: KeychainSecretKind) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: secretKind.rawValue,
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        // Deleting something that was never there is the caller's intent
        // already satisfied, not a failure.
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainStoreError.keychainOperationFailed(status: deleteStatus)
        }
    }

    private static func deleteSecretIgnoringFailure(ofKind secretKind: KeychainSecretKind) {
        try? deleteSecret(ofKind: secretKind)
    }
}
