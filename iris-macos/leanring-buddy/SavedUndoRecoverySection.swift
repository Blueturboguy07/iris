import SwiftUI
import AppKit

struct SavedUndoRecoverySection: View {
    @ObservedObject var coordinator: OnDemandEditCoordinator
    @State private var filesAreMissing = false

    var body: some View {
        if !coordinator.savedUndoArchivePaths.isEmpty {
            DisclosureGroup("Saved recovery details") {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text("These records are from stopped Undo attempts. Keeping them does not confirm an app was restored.")
                        .font(DS.Typography.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show saved details") {
                        let locations = coordinator.savedUndoArchivePaths
                            .filter { FileManager.default.fileExists(atPath: $0) }
                            .map { URL(fileURLWithPath: $0) }
                        filesAreMissing = locations.isEmpty
                        if !locations.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(locations) }
                    }
                    .irisTinyButton()
                    if filesAreMissing {
                        Text("The saved files could not be found at their recorded locations.")
                            .font(DS.Typography.caption)
                            .foregroundColor(DS.Colors.amber)
                    }
                }
                .padding(.top, DS.Spacing.sm)
            }
            .font(DS.Typography.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
        }
    }
}
