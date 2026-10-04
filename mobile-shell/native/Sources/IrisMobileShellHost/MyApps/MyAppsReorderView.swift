#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.4: "Reorder" pushes a Reorder screen: "a
// plain `List` in edit mode with the standard drag handles (`.onMove`),
// nothing else on the screen." Used for both a folder's own apps
// (`iris.store.my-apps.reorder`) and the folders themselves
// (`iris.store.my-apps.folder.<folderId>.reorder`, launched from "Reorder
// folders" in the "..." menu -- SPEC's `.reorder` identifier is reused for
// both, since only one Reorder screen is ever on screen at once). SPEC
// section 4: each row also carries "Move up" / "Move down" / "Move to top"
// as VoiceOver custom actions, since a drag handle alone is not usable by
// VoiceOver rotor navigation on every iOS version.
struct MyAppsReorderRow: Identifiable, Equatable {
    let id: String
    let title: String
}

struct MyAppsReorderView: View {
    let title: String
    @State var rows: [MyAppsReorderRow]
    let onDone: ([String]) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    Text(row.title)
                        .accessibilityIdentifier("iris.store.my-apps.reorder.row.\(row.id)")
                        .accessibilityActions {
                            Button("Move up") { move(row.id, delta: -1) }
                            Button("Move down") { move(row.id, delta: 1) }
                            Button("Move to top") { moveToTop(row.id) }
                        }
                }
                .onMove { indices, newOffset in
                    rows.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { onDone(rows.map(\.id)) }
                        .accessibilityIdentifier("iris.store.my-apps.reorder.done")
                }
            }
        }
        .accessibilityIdentifier("iris.store.my-apps.reorder")
    }

    private func move(_ id: String, delta: Int) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
    }

    private func moveToTop(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }), index > 0 else { return }
        let row = rows.remove(at: index)
        rows.insert(row, at: 0)
    }
}
#endif
