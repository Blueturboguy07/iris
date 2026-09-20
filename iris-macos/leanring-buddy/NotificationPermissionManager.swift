//
//  NotificationPermissionManager.swift
//  leanring-buddy
//
//  The one place Iris asks macOS for permission to show a system
//  notification — used today only for "one of your publik apps has an
//  update", never for anything the assistant itself does.
//
//  Mirrors `WindowPositionManager`'s Accessibility/Screen Recording shape on
//  purpose, reusing its `permissionRequestPresentationDestination` decision
//  directly: the system's own one-time prompt on the first ask, System
//  Settings on every ask after that. macOS shows its permission dialog at
//  most once per app; asking again after the reader has already answered it
//  does nothing, so the second and every later ask has to go somewhere else.
//

import AppKit
import UserNotifications

@MainActor
class NotificationPermissionManager {
    private static var hasAttemptedSystemPromptDuringCurrentLaunch = false

    /// Whether Iris may show a system notification right now. `.provisional`
    /// counts as permission granted — it already delivers quietly to
    /// Notification Center with no alert, which is a decided state, not a
    /// pending one.
    static func hasNotificationPermission() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined, .denied, .ephemeral:
            return false
        @unknown default:
            return false
        }
    }

    /// Presents exactly one permission path per call: the system prompt on
    /// the first attempt this launch, then System Settings on later attempts
    /// — see the header comment for why a second system prompt is never the
    /// right answer.
    @discardableResult
    static func requestNotificationPermission() async -> PermissionRequestPresentationDestination {
        let alreadyGranted = await hasNotificationPermission()
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: alreadyGranted,
            hasAttemptedSystemPrompt: hasAttemptedSystemPromptDuringCurrentLaunch
        )

        switch presentationDestination {
        case .alreadyGranted:
            return .alreadyGranted
        case .systemPrompt:
            hasAttemptedSystemPromptDuringCurrentLaunch = true
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .systemSettings:
            openNotificationSettings()
        }

        return presentationDestination
    }

    /// Opens System Settings to the Notifications pane.
    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
