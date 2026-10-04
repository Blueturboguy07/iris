#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// The one "Remove app" confirmation, shared by MA2's My Apps row menu and
/// MV4's own Features page (MA2 SPEC lines 82/150/349/353, MV4 owns this
/// type per that hook). Identifiers are the exact ones MA2's own SPEC.md
/// line 150 already fixed: `iris.store.my-apps.remove.confirm` /
/// `.remove.keep` / `.remove.delete-data`.
///
/// "Also delete my data" is a plain toggle, off by default (never delete
/// data silently): when the person confirms with it on, `onConfirm(true)`
/// fires and the caller is responsible for calling
/// `MyAppsOrganizationReducer.apply(.forgetApp(identity:), to:)` on its own
/// persisted arrangement store (this view has no access to that store --
/// see INTEGRATION_HOOKS.md "Remove app dialog wiring").
struct NativeRemoveAppDialog: View {
    let appName: String
    let onConfirm: (_ alsoDeleteData: Bool) -> Void
    let onCancel: () -> Void

    @State private var alsoDeleteData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove \(appName) from this iPhone?")
                .font(.headline)
            Text("This removes \(appName) and its stored versions from this iPhone.")
                .font(.body)
            Toggle("Also delete my data", isOn: $alsoDeleteData)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.removeAppDataToggle)
            Text(alsoDeleteData
                 ? "Your saved data for \(appName) will be deleted too. This cannot be undone."
                 : "Your saved data for \(appName) stays on this iPhone, in case you install it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Keep it", role: .cancel) { onCancel() }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.removeAppKeep)
                Spacer()
                Button("Remove", role: .destructive) { onConfirm(alsoDeleteData) }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.removeAppConfirm)
            }
        }
        .padding()
    }
}
#endif
