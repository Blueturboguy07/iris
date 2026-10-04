#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// The Features page (mobile-versions SPEC.md section 1.1): "<name>
/// features", plain-words rows newest first (8 then Show all), Free up
/// space, Remove app. Reads `FeaturesModel.state`/`rows` and dispatches
/// `FeaturesAction`s; every branch of `FeaturesState` a `FeaturesModel` can
/// reach has a rendering here (SPEC 1.3: "Every state ... has a way out").
struct FeaturesView: View {
    @ObservedObject var model: FeaturesModel
    let appName: String
    /// SPEC's own hook back into MA2: when "Remove" is confirmed with
    /// "Also delete my data" on, the page has no access to MA2's
    /// persisted arrangement store, so it asks the caller to forget the
    /// app (see INTEGRATION_HOOKS.md "Remove app dialog wiring").
    var onAppRemoved: (_ alsoDeleteData: Bool) -> Void = { _ in }
    /// False until the phone has an app-removal API (MV2). A Remove app
    /// button that removed nothing would be a lie, so the section is hidden,
    /// the same call MA2 made for the My apps row menu (SPEC decision 12).
    var removeAppAvailable: Bool = false

    @State private var showAll = false

    var body: some View {
        List {
            Section {
                Text("\(appName) features")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.myAppsRow(model.identity.appId))
                Text("Iris keeps the version on your iPhone and the one before it. Older ones stay while there is room. Your data is separate and is never changed by any of this.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.explanation)
            }

            statusSection

            if model.isLoading && model.entry == nil {
                ProgressView()
            } else if let loadErrorMessage = model.loadErrorMessage, model.entry == nil {
                Section {
                    Text(loadErrorMessage)
                    Button("Try again") { model.load() }
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.retry)
                }
            } else {
                rowsSection
                spaceSection
                if removeAppAvailable { removeAppSection }
            }
        }
        .accessibilityIdentifier("iris.store.versions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear { model.load() }
        .nativeConfirmationAlert(confirmationTitle, message: confirmationMessage,
            isPresented: confirmingBinding, actions: [
                NativeConfirmationAction(title: confirmationActionLabel, identifier: confirmationConfirmIdentifier) { model.dispatch(.confirm) },
                NativeConfirmationAction(title: "Keep it", style: .cancel, identifier: confirmationCancelIdentifier) { model.dispatch(.cancelConfirmation) }
            ])
        .sheet(isPresented: macRemovalBinding) {
            macRemovalSheet
        }
        .sheet(isPresented: removeAppSheetBinding) {
            NativeRemoveAppDialog(
                appName: appName,
                onConfirm: { alsoDeleteData in
                    model.dispatch(.confirm)
                    onAppRemoved(alsoDeleteData)
                },
                onCancel: { model.dispatch(.cancelConfirmation) }
            )
        }
    }

    // MARK: - Rows (SPEC 1.1)

    private var rowsSection: some View {
        Section {
            let allRows = model.rows
            let visibleRows = showAll ? allRows : Array(allRows.prefix(FeaturesRows.collapsedRowCount))
            ForEach(visibleRows) { row in
                FeaturesRowView(row: row, model: model)
            }
            if !showAll && allRows.count > FeaturesRows.collapsedRowCount {
                Button("Show all \(allRows.count)") { showAll = true }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.showAll)
            }
        }
    }

    private var statusSection: some View {
        Group {
            switch model.state {
            case .removing(_, _, let phase):
                Section {
                    HStack {
                        ProgressView()
                        Text(phase.sentence(appName: appName))
                    }
                }
            case .downloading(_, let percent):
                Section {
                    ProgressView(value: Double(percent), total: 100)
                    Button("Cancel") { model.dispatch(.cancelDownload) }
                }
            case .done(let message, let undo):
                Section {
                    HStack {
                        Text(message)
                        Spacer()
                        if let undo {
                            Button(undo.label) { model.dispatch(.tappedUndo) }
                                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.undo)
                        }
                    }
                }
                .onTapGesture { model.dispatch(.dismissBanner) }
            case .failed(let reason, let nextStep):
                Section {
                    Text(reason).foregroundStyle(.red)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.error)
                    if let nextStep {
                        Button(nextStep) { model.dispatch(.dismissBanner) }
                    }
                }
            case .paused:
                Section {
                    Text("Still working on it.")
                    Button("Check again") { model.dispatch(.checkAgain) }
                }
            case .pausedStuck:
                Section {
                    Text("This is taking longer than expected. It is safe to keep using \(appName); nothing was lost.")
                    Button("Check again") { model.dispatch(.checkAgain) }
                }
            default:
                EmptyView()
            }
        }
    }

    private var spaceSection: some View {
        Section {
            if let bytes = model.entry?.totalVersionContentBytes {
                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " used by stored versions")
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.spaceUsed)
            }
            Button("Free up space") { model.dispatch(.tappedFreeUpSpace) }
                .disabled(model.state.isBusy)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.freeUp)
        }
    }

    private var removeAppSection: some View {
        Section {
            Button("Remove app", role: .destructive) { model.dispatch(.tappedRemoveApp) }
                .disabled(model.state.isBusy)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.removeApp)
        }
    }

    // MARK: - Sheets

    private var macRemovalSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .explainingMacRemoval(let title) = model.state {
                Text("Removing \"\(title)\" and keeping the newer versions needs Iris on the Mac.")
                    .font(.body)
            }
            Button("OK") { model.dispatch(.dismissMacRemovalSheet) }
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.macRemovalSheetOK)
        }
        .padding()
    }

    // MARK: - Confirmation dialog plumbing

    private var confirmingBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming(let confirmation) = model.state, confirmation != .removeApp { return true }
                return false
            },
            set: { if !$0 { model.dispatch(.cancelConfirmation) } }
        )
    }

    private var macRemovalBinding: Binding<Bool> {
        Binding(
            get: { if case .explainingMacRemoval = model.state { return true }; return false },
            set: { if !$0 { model.dispatch(.dismissMacRemovalSheet) } }
        )
    }

    private var removeAppSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming(.removeApp) = model.state { return true }
                if case .removingApp = model.state { return true }
                return false
            },
            set: { if !$0 { model.dispatch(.cancelConfirmation) } }
        )
    }

    private var confirmationTitle: String {
        guard case .confirming(let confirmation) = model.state else { return "" }
        switch confirmation {
        case .goBack(_, let title): return "Go back to \(title)?"
        case .removeNewest(_, let title): return "Remove \(title)?"
        case .removeApp: return ""
        }
    }

    private var confirmationMessage: String {
        guard case .confirming(let confirmation) = model.state else { return "" }
        switch confirmation {
        case .goBack(let revisionId, _):
            let date = model.rows.first { $0.revisionId == revisionId }.map { String($0.createdAt.prefix(10)) } ?? "that version"
            return "\(appName) will be the way it was on \(date). Everything added after that is switched off, not deleted; you can come back. Your data stays as it is."
        case .removeNewest:
            return "This version is removed from your iPhone. Your data stays as it is."
        case .removeApp: return ""
        }
    }

    private var confirmationActionLabel: String {
        guard case .confirming(let confirmation) = model.state else { return "" }
        switch confirmation {
        case .goBack: return "Go back"
        case .removeNewest: return "Remove"
        case .removeApp: return ""
        }
    }

    private var confirmationConfirmIdentifier: String {
        guard case .confirming(let confirmation) = model.state else { return "" }
        switch confirmation {
        case .goBack: return NativeAccessibilityIdentifiers.Versions.goBackConfirm
        case .removeNewest: return NativeAccessibilityIdentifiers.Versions.removeConfirm
        case .removeApp: return ""
        }
    }

    private var confirmationCancelIdentifier: String {
        guard case .confirming(let confirmation) = model.state else { return "" }
        switch confirmation {
        case .goBack: return NativeAccessibilityIdentifiers.Versions.goBackCancel
        case .removeNewest: return NativeAccessibilityIdentifiers.Versions.removeCancel
        case .removeApp: return ""
        }
    }
}

private struct FeaturesRowView: View {
    let row: FeaturesRow
    @ObservedObject var model: FeaturesModel
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.subheadline.weight(.semibold))
                Text(row.state.detailLine()).font(.caption).foregroundStyle(.secondary)
                Text(String(row.createdAt.prefix(10))).font(.caption2).foregroundStyle(.tertiary)
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            if row.isPinned {
                Button("Unpin") { model.unpin(row.revisionId) }
                    .accessibilityLabel("Unpin this version")
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.unpin(row.revisionId))
            } else {
                Button("Pin") { model.pin(row.revisionId) }
                    .accessibilityLabel("Pin this version")
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.pin(row.revisionId))
            }
            if row.canActivate {
                Button("Switch on") { model.dispatch(.tappedSwitchOn(revisionId: row.revisionId)) }
                    .disabled(model.state.isBusy)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.activate(row.revisionId))
            }
            if row.canGoBack {
                Button("Go back") { model.dispatch(.tappedGoBack(revisionId: row.revisionId, title: row.title)) }
                    .disabled(model.state.isBusy)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.revert(row.revisionId))
            }
            if row.canRemove {
                Button("Remove", role: .destructive) {
                    if row.removalNeedsMac {
                        model.dispatch(.tappedRemoveOlderOnPhone(title: row.title))
                    } else {
                        model.dispatch(.tappedRemove(revisionId: row.revisionId, title: row.title, isNewest: true))
                    }
                }
                .disabled(model.state.isBusy)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.remove(row.revisionId))
            }
        }
        .buttonStyle(FeaturesActionButtonStyle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Versions.row(row.revisionId))
    }
}

private struct FeaturesActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
#endif
