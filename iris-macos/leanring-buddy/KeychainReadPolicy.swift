import Foundation
import LocalAuthentication
import Security

/// Routine credential checks must never open authentication UI. A user can
/// explicitly reconnect one saved item from settings when a signature changes.
nonisolated enum KeychainReadPolicy {
    // The login keychain uses macOS's legacy, file-based backend. That backend
    // does not honor LAContext's no-UI flag. Serialize our synchronous calls
    // while changing the process-local legacy flag, then restore its value.
    // No password, item ACL, or system-wide security setting is changed.
    private static let interactionLock = NSRecursiveLock()

    static func perform(
        allowsUserInteraction: Bool = false, _ operation: () -> OSStatus
    ) -> OSStatus {
        interactionLock.lock()
        defer { interactionLock.unlock() }

        var previousInteraction: DarwinBoolean = false
        let readStatus = SecKeychainGetUserInteractionAllowed(&previousInteraction)
        guard readStatus == errSecSuccess else { return readStatus }
        let setStatus = SecKeychainSetUserInteractionAllowed(allowsUserInteraction)
        guard setStatus == errSecSuccess else { return setStatus }
        let operationStatus = operation()
        let restoreStatus = SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue)
        return restoreStatus == errSecSuccess ? operationStatus : restoreStatus
    }

    static func updateOrAdd(
        update: () -> OSStatus, add: () -> OSStatus
    ) -> OSStatus {
        perform {
            let updateStatus = update()
            guard updateStatus == errSecItemNotFound else { return updateStatus }
            return add()
        }
    }

    static func query(
        service: String, account: String, returnsData: Bool,
        allowsUserInteraction: Bool = false
    ) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowsUserInteraction
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: returnsData,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }
}
