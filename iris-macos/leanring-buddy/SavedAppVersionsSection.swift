import SwiftUI
import AppKit

/// Recovery locations survive Iris restarts. This is not a claim that source,
/// app data, or an older app has been restored.
struct SavedAppVersionsSection: View {
    private let receiptStore: AppDeliveryReceiptStore
    private let onUndoReceipt: ((AppDeliveryReceipt) -> Void)?
    private let testProjects: [IrisTestProjectRegistry.Project]
    private let previewTestBackups: ((IrisTestProjectRegistry.Project) -> String)?
    private let onCleanupTestBackups: ((IrisTestProjectRegistry.Project) async -> String)?
    @State private var records: [AppDeliveryReceiptStore.Entry] = []
    @State private var missingFiles = false
    @State private var isShowingCleanupConfirmation = false
    @State private var cleanupMessage: String?
    @State private var selectedTestProjectSlug: String?

    init(
        receiptStore: AppDeliveryReceiptStore = AppDeliveryReceiptStore(),
        onUndoReceipt: ((AppDeliveryReceipt) -> Void)? = nil,
        testProjects: [IrisTestProjectRegistry.Project] = [],
        previewTestBackups: ((IrisTestProjectRegistry.Project) -> String)? = nil,
        onCleanupTestBackups: ((IrisTestProjectRegistry.Project) async -> String)? = nil
    ) {
        self.receiptStore = receiptStore
        self.onUndoReceipt = onUndoReceipt
        self.testProjects = testProjects
        self.previewTestBackups = previewTestBackups
        self.onCleanupTestBackups = onCleanupTestBackups
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
                if let onCleanupTestBackups, isIrisTestRuntime {
                    Divider()
                        .padding(.vertical, 4)
                    Text("Iris Test cleanup")
                        .foregroundColor(DS.Colors.textPrimary)
                    if testProjects.isEmpty {
                        Text("No eligible registered Test app is available. Iris will not guess a project or remove anything.")
                            .foregroundColor(DS.Colors.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("Test app", selection: $selectedTestProjectSlug) {
                            ForEach(testProjects, id: \.slug) { project in
                                Text(project.name).tag(Optional(project.slug))
                            }
                        }
                        .pickerStyle(.menu)
                        let selectedProject = testProjects.first(where: { $0.slug == selectedTestProjectSlug }) ?? testProjects[0]
                        Text(previewTestBackups?(selectedProject) ?? "Iris will re-check this Test app before removing anything.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Review cleanup…") {
                            isShowingCleanupConfirmation = true
                        }
                        .irisTinyButton()
                        .alert("Remove obsolete Test backups?", isPresented: $isShowingCleanupConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Remove obsolete backups", role: .destructive) {
                                Task {
                                    let result = await onCleanupTestBackups(selectedProject)
                                    await MainActor.run {
                                        cleanupMessage = result
                                        refresh()
                                    }
                                }
                            }
                        } message: {
                            Text(previewTestBackups?(selectedProject) ?? "Iris will re-check project identity, recovery references, bundle identity, and paths immediately before removing anything. Your source clone and installed app are not deleted.")
                        }
                        if let cleanupMessage {
                            Text(cleanupMessage)
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button("Refresh") { refresh() }.irisTinyButton()
            }
            .padding(.top, DS.Spacing.sm)
        }
        .font(DS.Typography.caption)
        .foregroundColor(DS.Colors.textSecondary)
        .onAppear {
            refresh()
            if selectedTestProjectSlug == nil {
                selectedTestProjectSlug = testProjects.first?.slug
            }
        }
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

    /// Xcode's Test scheme injects the Test bundle identity into the app
    /// process, but a debug launch can briefly report the host identity while
    /// the debug dylib is being loaded. The product-path fallback keeps the
    /// Test-only cleanup affordance visible in that narrow window without ever
    /// exposing it from the normal /Applications/Iris.app build.
    private var isIrisTestRuntime: Bool {
        IrisTestEnvironment.isEnabled
            || Bundle.main.bundleURL.path.contains("/Build/Products/Test/")
    }
}
