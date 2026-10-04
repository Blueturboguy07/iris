#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.1 item 4: "Recently used": up to 8 icons,
// most recently opened first, tap opens the app, long press gives the same
// menu as a row. Shown only when `MyAppsScreen.sections(...)` says to
// (`showRecentlyUsed`), so this view never re-derives that rule itself.
struct MyAppsRecentRowView: View {
    let rows: [MyAppsRow]
    let onOpen: (String) -> Void
    let actionsFor: (MyAppsRow) -> [MyAppsScreen.MenuAction]
    let dispatch: (MyAppsScreen.MenuAction, String) -> Void
    var folderNameFor: (MyAppsRow) -> String? = { _ in nil }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconMetric: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently used").font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.identity) { row in tile(row) }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(rows, id: \.identity) { row in tile(row) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iris.store.my-apps.recent")
    }

    private func tile(_ row: MyAppsRow) -> some View {
        let appId = MyAppsIdentifiers.appIdComponent(row.identity)
        return Button { onOpen(row.identity) } label: {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 12))
                : AnyLayout(VStackLayout(spacing: 4))
            layout {
                MyAppsRowIcon(identity: row.identity, name: row.displayName, size: min(iconMetric, 72))
                Text(row.displayName).font(typeSize.isAccessibilitySize ? .headline : .caption2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .frame(width: typeSize.isAccessibilitySize ? nil : max(64, iconMetric))
                    .foregroundStyle(NativeMarketplaceStyle.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.displayName), opened recently")
        .accessibilityHint("Opens \(row.displayName).")
        .accessibilityIdentifier("iris.store.my-apps.recent.\(appId)")
        .modifier(MyAppsMenuModifier(header: row.displayName, subtitle: row.secondLine, actions: actionsFor(row), dispatch: { dispatch($0, row.identity) }, folderName: folderNameFor(row), appId: appId))
        .accessibilityActions {
            ForEach(actionsFor(row), id: \.self) { action in
                Button(MyAppsMenuCopy.title(for: action, appName: row.displayName, folderName: folderNameFor(row))) { dispatch(action, row.identity) }
            }
        }
    }
}
#endif
