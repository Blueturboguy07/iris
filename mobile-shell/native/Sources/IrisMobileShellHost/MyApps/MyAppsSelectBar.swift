#if os(iOS)
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.4: Select mode's bottom bar: "Move to
// folder" and, once MV2's remove API exists, "Remove"; "Done" leaves the
// mode. `removeAvailable` is false until MV2 lands (SPEC decision 12),
// matching the same gate `MyAppsScreen.MenuContext.removeAPIAvailable` uses
// for the per-row menu.
struct MyAppsSelectBarView: View {
    let selectedCount: Int
    let removeAvailable: Bool
    let onMoveToFolder: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button("Move to folder", action: onMoveToFolder)
                .buttonStyle(NativeMarketplaceActionStyle(prominent: false))
                .disabled(selectedCount == 0)
                .accessibilityIdentifier("iris.store.my-apps.select.move")
            if removeAvailable {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .disabled(selectedCount == 0)
                    .accessibilityIdentifier("iris.store.my-apps.select.remove")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
#endif
