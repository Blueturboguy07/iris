import Foundation
import LocalAuthentication
import Security
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisUsability
#endif

@Suite(.serialized)
struct KeychainReadPolicyTests {
    @Test(arguments: [errSecSuccess, errSecAuthFailed, errSecInteractionNotAllowed])
    func existingCredentialIsNeverDeletedOrReaddedAfterAnUpdate(_ updateStatus: OSStatus) {
        var attemptedAdd = false
        let status = KeychainReadPolicy.updateOrAdd(update: { updateStatus }, add: {
            attemptedAdd = true
            return errSecSuccess
        })
        #expect(!attemptedAdd)
        #expect(status == updateStatus)
    }

    @Test func onlyAMissingCredentialMayBeAdded() {
        var attemptedAdd = false
        let status = KeychainReadPolicy.updateOrAdd(update: { errSecItemNotFound }, add: {
            attemptedAdd = true
            return errSecDuplicateItem
        })
        #expect(attemptedAdd)
        #expect(status == errSecDuplicateItem)
    }

    @Test func legacyBackgroundScopeDisallowsUIAndRestoresPreviousSetting() throws {
        var before: DarwinBoolean = false
        try #require(SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess)
        let status = KeychainReadPolicy.perform {
            var during: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&during) == errSecSuccess)
            #expect(!during.boolValue)
            return errSecItemNotFound
        }
        #expect(status == errSecItemNotFound)
        var after: DarwinBoolean = false
        #expect(SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess)
        #expect(after.boolValue == before.boolValue)
    }

    @Test func explicitScopeRestoresOuterQuietScopeEvenAfterFailure() {
        let status = KeychainReadPolicy.perform {
            let explicitStatus = KeychainReadPolicy.perform(allowsUserInteraction: true) {
                var interactive: DarwinBoolean = false
                #expect(SecKeychainGetUserInteractionAllowed(&interactive) == errSecSuccess)
                #expect(interactive.boolValue)
                return errSecAuthFailed
            }
            #expect(explicitStatus == errSecAuthFailed)
            var quiet: DarwinBoolean = true
            #expect(SecKeychainGetUserInteractionAllowed(&quiet) == errSecSuccess)
            #expect(!quiet.boolValue)
            return errSecSuccess
        }
        #expect(status == errSecSuccess)
    }

    @Test(arguments: [true, false])
    func routineReadsAndAvailabilityChecksCannotPrompt(_ returnsData: Bool) throws {
        let query = KeychainReadPolicy.query(service: "test-service", account: "test-account", returnsData: returnsData)
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(context.interactionNotAllowed)
        #expect(query[kSecAttrService as String] as? String == "test-service")
        #expect(query[kSecAttrAccount as String] as? String == "test-account")
        #expect(query[kSecReturnData as String] as? Bool == returnsData)
    }

    @Test func onlyAnExplicitReconnectCanAuthenticate() throws {
        let query = KeychainReadPolicy.query(
            service: "test-service", account: "test-account", returnsData: true,
            allowsUserInteraction: true
        )
        let context = try #require(query[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(!context.interactionNotAllowed)
    }

    @Test func reconnectDoesNotEnableInteractionForLaterBackgroundReads() throws {
        let explicit = KeychainReadPolicy.query(service: "a", account: "b", returnsData: true, allowsUserInteraction: true)
        let background = KeychainReadPolicy.query(service: "a", account: "b", returnsData: true)
        let interactiveContext = try #require(explicit[kSecUseAuthenticationContext as String] as? LAContext)
        let backgroundContext = try #require(background[kSecUseAuthenticationContext as String] as? LAContext)
        #expect(interactiveContext !== backgroundContext)
        #expect(backgroundContext.interactionNotAllowed)
    }

    @Test func quietReadsStillRetrieveAnAccessibleThrowawayItem() throws {
        let service = "iris-quiet-keychain-test-\(UUID().uuidString)"
        let account = "fixture"
        let value = Data("not-a-real-credential".utf8)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        try #require(added == errSecSuccess)
        defer {
            let exactItem: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(exactItem as CFDictionary)
        }
        var result: CFTypeRef?
        let status = KeychainReadPolicy.perform {
            SecItemCopyMatching(KeychainReadPolicy.query(
                service: service, account: account, returnsData: true
            ) as CFDictionary, &result)
        }
        #expect(status == errSecSuccess)
        #expect(result as? Data == value)
    }

    @Test func lockedLegacyKeychainFailsWithoutRequestingAPassword() throws {
        // Isolated fixture only. Never lock or modify the user's login keychain.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-keychain-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixturePassword = Array("fixture-only-\(UUID().uuidString)".utf8)
        var fixtureKeychain: SecKeychain?
        let created = fixturePassword.withUnsafeBytes { bytes in
            SecKeychainCreate(directory.appendingPathComponent("fixture.keychain").path,
                              UInt32(bytes.count), bytes.baseAddress, false, nil, &fixtureKeychain)
        }
        try #require(created == errSecSuccess)
        let keychain = try #require(fixtureKeychain)
        defer { SecKeychainDelete(keychain) }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "iris-fixture-service",
            kSecAttrAccount as String: "fixture-account",
            kSecValueData as String: Data("fake-fixture-value".utf8),
            kSecUseKeychain as String: keychain,
        ]
        try #require(KeychainReadPolicy.perform { SecItemAdd(item as CFDictionary, nil) } == errSecSuccess)
        try #require(SecKeychainLock(keychain) == errSecSuccess)
        var query = KeychainReadPolicy.query(
            service: "iris-fixture-service", account: "fixture-account", returnsData: true
        )
        query[kSecMatchSearchList as String] = [keychain]
        var result: CFTypeRef?
        let status = KeychainReadPolicy.perform {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        // The legacy backend reports authFailed on this macOS version;
        // the data-protection backend uses interactionNotAllowed.
        #expect(status == errSecInteractionNotAllowed || status == errSecAuthFailed)
        #expect(result == nil)
    }
}
