import Foundation

/// Every settings entry point chooses an action on the same existing panel.
/// Opening Settings repeatedly must bring it forward, never create a sibling.
nonisolated enum SettingsPanelRouting {
    /// The three compact settings surfaces keep the menu-bar panel scannable
    /// without changing what any existing row does.
    enum Page: String, CaseIterable, Equatable, Sendable {
        case general = "General"
        case connections = "Connections"
        case apps = "Apps"
    }

    enum Request { case show, toggle }
    enum Action: Equatable { case createAndShow, showExisting, hideExisting }

    static func action(
        for request: Request, panelExists: Bool, panelIsVisible: Bool
    ) -> Action {
        guard panelExists else { return .createAndShow }
        if case .toggle = request, panelIsVisible { return .hideExisting }
        return .showExisting
    }
}

/// Move notifications arrive throughout a drag, not just on release. Keep the
/// latest proposed frame in memory and persist only after motion settles.
nonisolated struct SettingsPanelPlacementUpdates {
    private(set) var origin: CGPoint?
    private(set) var size: CGSize?

    mutating func recordMove(to origin: CGPoint, isProgrammatic: Bool) {
        guard !isProgrammatic, origin.x.isFinite, origin.y.isFinite else { return }
        self.origin = origin
    }

    mutating func recordResize(to size: CGSize, origin: CGPoint, isProgrammatic: Bool) {
        guard !isProgrammatic, size.width.isFinite, size.height.isFinite else { return }
        recordMove(to: origin, isProgrammatic: false)
        self.size = size
    }

    mutating func takeSettledUpdate() -> (origin: CGPoint?, size: CGSize?) {
        defer { origin = nil; size = nil }
        return (origin, size)
    }
}
