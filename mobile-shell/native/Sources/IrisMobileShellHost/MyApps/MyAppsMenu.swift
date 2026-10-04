#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.2: one long-press menu, "the same list, in
// the same order" as VoiceOver's custom actions, both built from
// `MyAppsScreen.actions(for:)` (MA1) so they cannot drift apart (SPEC's own
// words). `MyAppsMenuCopy` is the single place that turns a `MenuAction`
// into the label SPEC 1.2's table gives it; the context menu (this file) and
// the row's `.accessibilityActions` (`MyAppsRow.swift`) both call it.
enum MyAppsMenuCopy {
    static func title(for action: MyAppsScreen.MenuAction, appName: String) -> String {
        switch action {
        case .update: return "Update"
        case .open: return "Open"
        case .download: return "Download"
        case .rename: return "Rename"
        case .move: return "Move to folder"
        case .takeOut: return "Take out of folder"
        case .features: return "Features"
        case .about: return "About this app"
        case .share: return "Share link"
        case .remove: return "Remove from this iPhone"
        }
    }

    /// SPEC 1.2's `take-out` row: "Take out of \"Editing\"" when the
    /// containing folder's name is known.
    static func title(for action: MyAppsScreen.MenuAction, appName: String, folderName: String?) -> String {
        if action == .takeOut, let folderName { return "Take out of \"\(folderName)\"" }
        return title(for: action, appName: appName)
    }

    static func systemImage(for action: MyAppsScreen.MenuAction) -> String {
        switch action {
        case .update: return "arrow.down.circle"
        case .open: return "arrow.up.forward.app"
        case .download: return "icloud.and.arrow.down"
        case .rename: return "pencil"
        case .move: return "folder"
        case .takeOut: return "folder.badge.minus"
        case .features: return "list.bullet.rectangle"
        case .about: return "info.circle"
        case .share: return "square.and.arrow.up"
        case .remove: return "trash"
        }
    }

    static func identifierSuffix(for action: MyAppsScreen.MenuAction) -> String {
        switch action {
        case .update: return "update"
        case .open: return "open"
        case .download: return "download"
        case .rename: return "rename"
        case .move: return "move"
        case .takeOut: return "take-out"
        case .features: return "features"
        case .about: return "about"
        case .share: return "share"
        case .remove: return "remove"
        }
    }
}

/// The system context menu (SPEC 1.2): "Touch and hold a row... The system
/// context menu opens with a header (icon, display name, the one-line
/// description) and these items, in this order, only the ones that apply."
/// Destructive items (Remove) are last and red -- `MyAppsScreen.actions(for:)`
/// already places `.remove` last, so this view only needs `role: .destructive`
/// on it.
struct MyAppsMenuModifier: ViewModifier {
    let header: String
    let subtitle: String
    let actions: [MyAppsScreen.MenuAction]
    let dispatch: (MyAppsScreen.MenuAction) -> Void
    var folderName: String? = nil
    var appId: String = ""

    func body(content: Content) -> some View {
        content.contextMenu {
            ForEach(actions, id: \.self) { action in
                Button(role: action == .remove ? .destructive : nil) {
                    dispatch(action)
                } label: {
                    Label(MyAppsMenuCopy.title(for: action, appName: header, folderName: folderName), systemImage: MyAppsMenuCopy.systemImage(for: action))
                }
                .accessibilityIdentifier("iris.store.my-apps.menu.\(appId).\(MyAppsMenuCopy.identifierSuffix(for: action))")
            }
        } preview: {
            VStack(alignment: .leading, spacing: 4) {
                Text(header).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
            }
            .padding()
        }
    }
}
#endif
