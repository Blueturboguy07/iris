import SwiftUI
import AppKit

/// Recovery locations survive Iris restarts. This is not a claim that source,
/// app data, or an older app has been restored.
struct SavedAppVersionsSection: View {
    private let receiptStore: AppDeliveryReceiptStore
    private let onUndoReceipt: ((AppDeliveryReceipt) -> Void)?
    @State private var records: [AppDeliveryReceiptStore.Entry] = []
    @State private var missingFiles = false

    init(
        receiptStore: AppDeliveryReceiptStore = AppDeliveryReceiptStore(),
        onUndoReceipt: ((AppDeliveryReceipt) -> Void)? = nil
    ) {
        self.receiptStore = receiptStore
        self.onUndoReceipt = onUndoReceipt
    }

    var body: some View {
        DisclosureGroup("Saved app versions") {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text("Previous app files are kept when Iris replaces an installed copy. Your documents are separate. These records do not confirm that the app opened or worked.")
                    .fixedSize(horizontal: false, vertical: true)
                if records.isEmpty {
                    Text("No saved app versions recorded yet.")
                }
                ForEach(Array(records.enumerated()), id: \.offset) { _, entry in
                    if case .valid(let receipt) = entry {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(fileURLWithPath: receipt.installedPath).deletingPathExtension().lastPathComponent)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(receipt.startedAt, style: .date)
                            Text(phaseLabel(receipt.phase))
                            let backupAvailable = receiptStore.backupIsAvailable(for: receipt)
                            Text(backupAvailable
                                 ? "Previous app files were found. Iris checks their contents before Undo."
                                 : "Previous app files are unavailable at the recorded location.")
                            switch receipt.phase {
                            case .prepared:
                                Text("Iris will not guess whether this update reached the installed app.")
                                    .foregroundColor(DS.Colors.amber)
                            case .installed:
                                if receipt.hasCompleteUndoMetadata && backupAvailable {
                                    if let onUndoReceipt {
                                        Button("Undo") { onUndoReceipt(receipt) }
                                            .irisTinyButton()
                                            .help("Restore the exact previous app files and source recorded for this update.")
                                    } else {
                                        Text("Undo is available from the edit recovery card.")
                                            .foregroundColor(DS.Colors.textSecondary)
                                    }
                                } else if !backupAvailable {
                                    Text("Undo is unavailable because the previous app files are unavailable at the recorded location.")
                                        .foregroundColor(DS.Colors.amber)
                                } else {
                                    Text("Undo is unavailable because the exact source identity was not saved.")
                                        .foregroundColor(DS.Colors.amber)
                                }
                            case .restored:
                                Text("This saved version is already recorded as restored.")
                                    .foregroundColor(DS.Colors.textSecondary)
                            }
                            if backupAvailable {
                                Button("Show previous app files") {
                                    let url = URL(fileURLWithPath: receipt.backupPath)
                                    missingFiles = !receiptStore.backupIsAvailable(for: receipt)
                                    if !missingFiles { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                }
                                .irisTinyButton()
                            }
                        }
                    } else {
                        Text("Some saved version details cannot be read. No restoration is confirmed.")
                            .foregroundColor(DS.Colors.amber)
                    }
                }
                if missingFiles {
                    Text("The previous app files became unavailable at the recorded location.")
                        .foregroundColor(DS.Colors.amber)
                }
                if records.count >= AppDeliveryReceiptStore.maximumEntries {
                    Text("Showing up to \(AppDeliveryReceiptStore.maximumEntries) saved records. Additional records may not appear here; nothing was deleted.")
                        .foregroundColor(DS.Colors.amber)
                }
                Button("Refresh") { refresh() }.irisTinyButton()
            }
            .padding(.top, DS.Spacing.sm)
        }
        .font(DS.Typography.caption)
        .foregroundColor(DS.Colors.textSecondary)
        .onAppear { refresh() }
    }

    private func refresh() {
        records = receiptStore.entries().sorted { left, right in
            if case .valid(let a) = left, case .valid(let b) = right { return a.startedAt > b.startedAt }
            if case .valid = left { return false }
            if case .valid = right { return true }
            return false
        }
    }

    private func phaseLabel(_ phase: AppDeliveryReceipt.Phase) -> String {
        switch phase {
        case .prepared: return "Update prepared. Whether it finished is not confirmed."
        case .installed: return "Last recorded event: app files replaced."
        case .restored: return "Last recorded event: previous app files restored."
        }
    }
}
