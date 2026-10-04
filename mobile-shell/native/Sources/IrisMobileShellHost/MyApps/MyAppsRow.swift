#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.1 "Row anatomy" and section 4's
// accessibility rules. Every identifier here is either kept byte for byte
// from M-store-screens (`iris.store.my-apps.row.<appId>`, `iris.open.<appId>`,
// `iris.versions.<appId>`) or new from SPEC section 6's list
// (`.row.<appId>.update-badge`, `.blocked-badge`, `.menu.<appId>...`), written
// as string literals per this unit's own scope note (`NativeAccessibilityIdentifiers.swift`
// is not an owned path; INTEGRATION_HOOKS.md gives its owner the fold-in).
struct MyAppsRowView: View {
    let row: MyAppsRow
    /// False when the library has no current revision for this identity
    /// (a transitional state); mirrors M-store-screens' own
    /// `.disabled(entry.currentRevisionId == nil)` on the Open button.
    let canOpen: Bool
    let onOpenPage: () -> Void
    let onOpen: () -> Void
    let onUnblock: () -> Void
    let menuActions: [MyAppsScreen.MenuAction]
    let dispatch: (MyAppsScreen.MenuAction) -> Void
    /// Select mode (SPEC 1.4): tapping the row toggles a checkbox and does
    /// nothing else -- "never opens the app or its page."
    let selection: MyAppsSelectionContext?
    /// The name of the folder this app sits in, for the menu's "Take out of
    /// \"<folder>\"" wording (SPEC 1.2). Nil when the app is in no folder.
    var folderName: String? = nil

    private var appId: String { MyAppsIdentifiers.appIdComponent(row.identity) }

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconMetric: CGFloat = 56

    /// SPEC 4.3: 56 pt icon (72 at most), the same small capsule as the store.
    private var iconSize: CGFloat { min(iconMetric, 72) }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        selectButton
                        infoButton(trailingGap: 0)
                    }
                    if selection == nil { actionButton.padding(.leading, iconSize + 12) }
                }
            } else {
                HStack(spacing: 0) {
                    selectButton
                    infoButton(trailingGap: 12)
                    if selection == nil { actionButton.fixedSize(horizontal: true, vertical: false) }
                }
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 76, alignment: .center)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NativeMarketplaceStyle.line).frame(height: 0.5)
                .padding(.leading, iconSize + 12).accessibilityHidden(true)
        }
        // `.contain`, not `.combine`: the trailing Open/Unblock/select
        // control must stay independently hittable from the row's own
        // container element (SPEC section 4, and the same M-store-screens
        // rule this design keeps).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("iris.store.my-apps.row.\(appId)")
        .modifier(MyAppsMenuModifier(header: row.displayName, subtitle: row.secondLine, actions: menuActions, dispatch: dispatch, folderName: folderName, appId: appId))
        .accessibilityActions {
            ForEach(menuActions, id: \.self) { action in
                Button(MyAppsMenuCopy.title(for: action, appName: row.displayName, folderName: folderName)) { dispatch(action) }
            }
        }
    }

    @ViewBuilder private var selectButton: some View {
        if let selection {
            Button {
                selection.toggle(row.identity)
            } label: {
                Image(systemName: selection.isSelected(row.identity) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.isSelected(row.identity) ? NativeMarketplaceStyle.electric : NativeMarketplaceStyle.fog)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 12)
            .accessibilityIdentifier("iris.store.my-apps.select.row.\(appId)")
            .accessibilityLabel(selection.isSelected(row.identity) ? "\(row.displayName), selected" : "\(row.displayName), not selected")
        }
    }

    private func infoButton(trailingGap: CGFloat) -> some View {
        Button {
            if let selection { selection.toggle(row.identity) } else { onOpenPage() }
        } label: {
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                MyAppsRowIcon(identity: row.identity, name: row.displayName, size: iconSize)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(row.displayName).font(.headline).foregroundStyle(NativeMarketplaceStyle.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : (typeSize > .large ? 3 : 1))
                        if row.hasUpdate {
                            MyAppsBadge(text: "Update", color: NativeMarketplaceStyle.electric)
                                .accessibilityIdentifier("iris.store.my-apps.row.\(appId).update-badge")
                        }
                        if row.isBlocked {
                            MyAppsBadge(text: "Blocked", color: NativeMarketplaceStyle.fog)
                                .accessibilityIdentifier("iris.store.my-apps.row.\(appId).blocked-badge")
                        }
                    }
                    Text(row.secondLine).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                        .lineLimit(typeSize > .large ? 4 : 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.trailing, trailingGap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Kept from M-store-screens: MyAppsUITests reads this identifier
        // directly from the My apps tab (see StoreMyAppsView.swift's own
        // long comment on this exact line for the regression it guards).
        .accessibilityIdentifier("iris.versions.\(appId)")
    }

    /// The trailing control is the store's small capsule (SPEC 4.2): 30 pt
    /// drawn, 44 pt to tap, Open in ink on the tonal fill.
    @ViewBuilder private var actionButton: some View {
        if row.isBlocked {
            Button(action: onUnblock) { Text("Unblock") }
                .buttonStyle(StoreGetStyle(size: .row))
        } else if row.needsDownload {
            Button(action: onOpen) { Text("Download") }
                .buttonStyle(StoreGetStyle(size: .row))
                .accessibilityIdentifier("iris.open.\(appId)")
        } else {
            Button(action: onOpen) { Text("Open") }
                .buttonStyle(StoreGetStyle(size: .row, ink: true))
                .disabled(!canOpen)
                .accessibilityIdentifier("iris.open.\(appId)")
        }
    }

    /// SPEC section 4: "Clips, cut and trim short videos, in Editing, Update
    /// available, Blocked" (only the parts that apply).
    private var accessibilityLabel: String {
        var parts = [row.displayName, row.secondLine]
        if row.hasUpdate { parts.append("Update available") }
        if row.isBlocked { parts.append("Blocked") }
        return parts.joined(separator: ", ")
    }

    private var accessibilityHint: String {
        row.isRenamed ? "Opens the app's page. Originally called \(row.originalName)." : "Opens the app's page."
    }
}

/// Shared 44 pt icon used by rows, the recent shelf and the move sheet.
/// `NativeMarketplaceArtwork` (M-store-screens) already resolves the catalog
/// icon when known and falls back to an initial otherwise; this is a thin
/// wrapper so every MyApps view asks for it the same way.
struct MyAppsRowIcon: View {
    let identity: String
    let name: String
    var size: CGFloat = 44

    var body: some View {
        NativeMarketplaceArtwork(key: NativeMarketplaceSelection.appearanceKey(appId: MyAppsIdentifiers.appIdComponent(identity)), name: name)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237))
            .accessibilityHidden(true)
    }
}

struct MyAppsBadge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color, in: Capsule()).foregroundStyle(.white)
    }
}

/// Threaded down to every row so Select mode (SPEC 1.4) can toggle a
/// checkbox without each row needing its own binding into the parent's set.
struct MyAppsSelectionContext {
    let selected: Set<String>
    let toggle: (String) -> Void
    func isSelected(_ identity: String) -> Bool { selected.contains(identity) }
}
#endif
