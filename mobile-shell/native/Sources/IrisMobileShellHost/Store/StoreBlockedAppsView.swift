#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// unit M-store-screens. design section 7 item 4: "Blocked apps (N)...
/// pushes a list of blocked apps with an Unblock button per row." Reads
/// `store.blockedAppIDs` (Review47BlockList-backed, already the source of
/// truth Browse and the app page use); unblocking here is the same
/// `store.setBlocked(false, appId:)` call the app page's own Unblock
/// button already makes.
struct StoreBlockedAppsView: View {
    @ObservedObject var store: StoreModel
    let library: [NativeShellLibraryEntry]
    var displayNames: MyAppsDisplayNames = .empty

    private var rows: [(appId: String, name: String)] {
        store.blockedAppIDs.sorted().map { appId in
            let entry = library.first { $0.identity.appId == appId }
            return (appId, entry.map { displayNames.name(identity: $0.identity.id, fallback: $0.displayName) } ?? appId)
        }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Text("No blocked apps.").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            } else {
                ForEach(rows, id: \.appId) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Button("Unblock") { store.setBlocked(false, appId: row.appId) }
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Blocked.rowUnblock(row.appId))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Blocked.row(row.appId))
                }
            }
        }
        .navigationTitle("Blocked apps").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Blocked.root)
    }
}
#endif
