#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.4: "New folder" and "Rename folder" share
// one dialog shape (same 1-30 character rules as an app name). `prefill` is
// the app's group name when started from the Move sheet's "New folder..."
// row (SPEC 1.4: "prefilled with the app's group name when it comes from the
// Move sheet").
struct MyAppsFolderNameDialogView: View {
    let title: String
    let prefill: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(title: String, prefill: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.prefill = prefill
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: prefill)
    }

    private var trimmed: String { MyAppsNameValidator.normalize(text) }
    private var isTooLong: Bool { trimmed.count > MyAppsLimits.nameMaxLength }
    private var canSave: Bool { MyAppsNameValidator.isValid(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $text)
                        .accessibilityIdentifier("iris.store.my-apps.folder-name.field")
                    if isTooLong {
                        Text("Names can be up to 30 characters.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("iris.store.my-apps.folder-name.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(trimmed) }
                        .disabled(!canSave)
                        .accessibilityIdentifier("iris.store.my-apps.folder-name.save")
                }
            }
        }
        .accessibilityIdentifier("iris.store.my-apps.folder-name")
    }
}
#endif
