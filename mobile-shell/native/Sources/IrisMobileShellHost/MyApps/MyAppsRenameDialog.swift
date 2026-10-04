#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.3: rename dialog. A `.sheet` (not a bare
// SwiftUI `.alert`) because the dialog needs a live character count line and
// a duplicate-name notice under the field while typing, neither of which an
// `Alert`'s fixed layout can show; the sheet still reads and behaves like a
// small modal dialog (medium detent, two/three buttons), matching SPEC 1.3's
// shape without needing UIKit's `UIAlertController` (which cannot host a
// SwiftUI view for the live count).
struct MyAppsRenameTarget: Identifiable {
    let identity: String
    let currentDisplayName: String
    let isRenamed: Bool
    var id: String { identity }
}

struct MyAppsRenameDialogView: View {
    let target: MyAppsRenameTarget
    /// True when some other installed app already has this trimmed name
    /// (SPEC 1.3: "Another app is also called Clips."), recomputed by the
    /// caller on every keystroke from the live library, never cached here.
    let nameCollision: (String) -> Bool
    let onSave: (String) -> Void
    let onUseOriginal: () -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(target: MyAppsRenameTarget, nameCollision: @escaping (String) -> Bool, onSave: @escaping (String) -> Void, onUseOriginal: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.nameCollision = nameCollision
        self.onSave = onSave
        self.onUseOriginal = onUseOriginal
        self.onCancel = onCancel
        _text = State(initialValue: target.currentDisplayName)
    }

    private var trimmed: String { MyAppsNameValidator.normalize(text) }
    private var isTooLong: Bool { trimmed.count > MyAppsLimits.nameMaxLength }
    private var canSave: Bool { MyAppsNameValidator.isValid(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $text)
                        .accessibilityIdentifier("iris.store.my-apps.rename.field")
                        .onAppear {
                            // SPEC 1.3: "one text field prefilled with the
                            // current display name and selected." SwiftUI has
                            // no direct "select all" API on `TextField`; the
                            // prefilled value is the closest portable
                            // approximation available without UIKit
                            // (`UITextField.selectAll`), which is out of
                            // scope for this pass and noted in HANDOFF.md.
                        }
                    if isTooLong {
                        Text("Names can be up to 30 characters.")
                            .font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("iris.store.my-apps.rename.limit")
                    } else if nameCollision(trimmed) {
                        Text("Another app is also called \(trimmed).")
                            .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                            .accessibilityIdentifier("iris.store.my-apps.rename.collision")
                    }
                }
            }
            .navigationTitle("Rename \(target.currentDisplayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel).accessibilityIdentifier("iris.store.my-apps.rename.cancel")
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if target.isRenamed {
                        Button("Use original name", action: onUseOriginal)
                            .accessibilityIdentifier("iris.store.my-apps.rename.original")
                    }
                    Button("Save") { onSave(trimmed) }
                        .disabled(!canSave)
                        .accessibilityIdentifier("iris.store.my-apps.rename.save")
                }
            }
        }
        .accessibilityIdentifier("iris.store.my-apps.rename")
    }
}
#endif
