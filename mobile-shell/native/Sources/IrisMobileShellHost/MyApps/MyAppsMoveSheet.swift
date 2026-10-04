#if os(iOS)
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen. SPEC 1.4 "Move to folder": a list of the
// person's folders with a check on the current one, a first row "No folder
// (stays in <group>)", and a last row "New folder..." (replaced by the
// limit line at 40 folders). One tap moves and closes the sheet.
struct MyAppsMoveSheetView: View {
    let folders: [MyAppsFolder]
    let currentFolderId: String?
    let currentGroupName: String
    let onSelect: (String?) -> Void
    let onNewFolder: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Text("No folder (stays in \(currentGroupName))")
                        Spacer()
                        if currentFolderId == nil { Image(systemName: "checkmark") }
                    }
                }
                .accessibilityIdentifier("iris.store.my-apps.move.none")

                ForEach(folders.sorted(by: { $0.order < $1.order })) { folder in
                    let isFull = folder.apps.count >= MyAppsLimits.maxAppsPerFolder
                    Button {
                        guard !isFull else { return }
                        onSelect(folder.id)
                    } label: {
                        HStack {
                            Text(isFull ? "\(folder.name) (full)" : folder.name)
                                .foregroundStyle(isFull ? NativeMarketplaceStyle.fog : NativeMarketplaceStyle.ink)
                            Spacer()
                            if currentFolderId == folder.id { Image(systemName: "checkmark") }
                        }
                    }
                    .disabled(isFull)
                    .accessibilityIdentifier("iris.store.my-apps.move.folder.\(folder.id)")
                    .accessibilityLabel(currentFolderId == folder.id ? "\(folder.name), selected" : folder.name)
                }

                if folders.count < MyAppsLimits.maxFolders {
                    Button("New folder...", action: onNewFolder)
                        .accessibilityIdentifier("iris.store.my-apps.move.new")
                } else {
                    Text("You can have up to 40 folders. Delete one to make another.")
                        .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
                }
            }
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("iris.store.my-apps.move")
    }
}
#endif
