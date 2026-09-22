import Foundation

/// Copy and action labels for the common case where macOS has a stale or
/// duplicate Accessibility entry. Permission truth still comes from the
/// system check in CompanionPanelView; this only keeps the repair guidance
/// deterministic and testable.
nonisolated enum AccessibilityPermissionRecovery {
    enum Action: String, CaseIterable, Hashable {
        case openSettings = "Open Settings"
        case showIris = "Show Iris"
    }

    static let disclosureTitle = "Already enabled?"
    static let repairInstructions = "If Iris is already listed but still says it is not granted, select the old Iris entry, click the minus button, click the plus button, choose this copy of Iris, then turn it on."

    static func shouldShowRepairInstructions(isGranted: Bool) -> Bool {
        !isGranted
    }
}
