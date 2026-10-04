#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.1 item 5 (folder headers) and item 6
// (automatic group headers): "header: name, count, a chevron... Group
// headers and folder headers fold and unfold on tap (chevron turns), and the
// folded state is remembered." SPEC section 4: "the count is in the label
// (\"Editing, your folder, 3 apps, collapsed\"); the fold toggle is the
// header's own action (\"Double tap to collapse\")."
struct MyAppsFolderHeaderView: View {
    let folder: MyAppsFolder
    let onToggleCollapsed: () -> Void
    let onRename: () -> Void
    let onReorder: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggleCollapsed) {
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(NativeMarketplaceStyle.fog)
                    Text(folder.name).font(.subheadline.weight(.semibold))
                    Text("\(folder.apps.count)").font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                        .accessibilityIdentifier("iris.store.my-apps.folder.\(folder.id).count")
                    Image(systemName: folder.collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iris.store.my-apps.folder.\(folder.id).header")
            .accessibilityLabel("\(folder.name), your folder, \(folder.apps.count) app\(folder.apps.count == 1 ? "" : "s")\(folder.collapsed ? ", collapsed" : "")")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(folder.collapsed ? "Double tap to expand" : "Double tap to collapse")

            Spacer()

            Menu {
                Button("Rename folder", systemImage: "pencil", action: onRename)
                Button("Reorder", systemImage: "arrow.up.arrow.down", action: onReorder)
                Button("Delete folder", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("\(folder.name) folder actions")
            .accessibilityIdentifier("iris.store.my-apps.folder.\(folder.id).menu")
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

/// SPEC 1.1 item 5: an empty folder shows one line plus "Delete folder".
struct MyAppsEmptyFolderRow: View {
    let folderId: String
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing in this folder yet. Long press an app and choose Move to folder.")
                .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
            Button("Delete folder", action: onDelete)
                .font(.caption.weight(.semibold)).frame(minHeight: 44)
        }
        .padding(.vertical, 6)
        .accessibilityIdentifier("iris.store.my-apps.folder.\(folderId).empty")
    }
}

/// SPEC 1.1 item 6: automatic group headers, no "..." menu (folders only).
struct MyAppsGroupHeaderView: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let identifierSuffix: String
    let onToggleCollapsed: () -> Void

    var body: some View {
        Button(action: onToggleCollapsed) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(count)").font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier("iris.store.my-apps.group.\(identifierSuffix).count")
                Spacer()
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("iris.store.my-apps.group.\(identifierSuffix).header")
        .accessibilityLabel("\(title), \(count) app\(count == 1 ? "" : "s")\(collapsed ? ", collapsed" : "")")
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(collapsed ? "Double tap to expand" : "Double tap to collapse")
    }
}

/// SPEC 1.1 item 8: shown once, above the first automatic group, only while
/// the person has no folders and 6+ apps.
struct MyAppsGroupsHintView: View {
    var body: some View {
        Text("Grouped by what they do. Long press an app to make your own folders.")
            .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
            .accessibilityIdentifier("iris.store.my-apps.groups-hint")
    }
}
#endif
