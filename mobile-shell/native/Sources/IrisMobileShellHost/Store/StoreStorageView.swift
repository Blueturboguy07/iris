#if os(iOS)
import IrisMobileShellCore
import SwiftUI
import UIKit

/// unit M-store-screens (round3-deferred/M-store-screens, route G8). The
/// Storage screen (design section 8, WF-06): total used vs the global cap,
/// per-app code and data, pinned versions live on the Versions entry point
/// each row still reaches (this unit does not build a separate pinned-
/// versions list here). One `globalStorageUsage()` pass feeds every row
/// (SPEC R8.10: opens in under 500 ms at 100 apps x 5 revisions, one pass
/// not one call per revision); "By app, largest first" reads the same
/// already-fetched `usage.perApp`, no second measurement.
@MainActor
final class StoreStorageModel: ObservableObject {
    struct AppRow: Identifiable {
        let identity: NativeShellAppIdentity
        let displayName: String
        let usage: NativeStorageAppUsage
        var id: String { identity.id }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var usage: NativeStorageGlobalUsage?
    @Published private(set) var promisedReclaimableBytes: Int64?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isFreeing = false
    @Published private(set) var resultMessage: String?
    @Published var capSheetIsPresented = false
    @Published private(set) var selectedKeepCount: VersionsKeptPerApp = .keepTwo
    @Published var keepCountSheetIsPresented = false
    @Published private(set) var keepCountConfirmation: NativeStorageKeepCountPlan?
    @Published private(set) var keepCountResult: NativeStorageKeepCountResult?
    @Published private(set) var isApplyingKeepCount = false
    @Published private(set) var keepCountConfirmationMessage: String?
    @Published private(set) var keepCountConfirmButtonTitle: String?
    @Published private(set) var keepCountCancelButtonTitle: String?
    @Published private(set) var keepCountResultMessage: String?
    @Published private(set) var keepCountRaisingMessage: String?
    /// Read fresh into published state on every `refresh()` rather than a
    /// live computed property: `NativeShellLibraryCoordinator` is an actor
    /// (M3-catalog-contract-scale), so even its non-`async`-declared methods
    /// are actor-isolated and need `await` from this `@MainActor` model --
    /// a synchronous computed property could not call them at all (the
    /// exact compile error M6's own HANDOFF.md hit before this fix).
    @Published private(set) var capBytes: Int64 = NativeStorageRetentionPolicy.defaultGlobalCodeCapBytes

    private let coordinator: NativeShellLibraryCoordinator
    private let defaults: UserDefaults
    private let library: [NativeShellLibraryEntry]
    private let displayNames: MyAppsDisplayNames

    init(coordinator: NativeShellLibraryCoordinator, defaults: UserDefaults, library: [NativeShellLibraryEntry], displayNames: MyAppsDisplayNames = .empty) {
        self.coordinator = coordinator
        self.defaults = defaults
        self.library = library
        self.displayNames = displayNames
    }

    var perAppRows: [AppRow] {
        guard let usage else { return [] }
        let nameByAppId = Dictionary(uniqueKeysWithValues: library.map { ($0.identity.appId, displayNames.name(identity: $0.identity.id, fallback: $0.displayName)) })
        return usage.perApp.compactMap { appUsage in
            guard let name = nameByAppId[appUsage.identity.appId] else { return nil }
            return AppRow(identity: appUsage.identity, displayName: name, usage: appUsage)
        }
        .sorted { $0.usage.codeAllocatedBytes > $1.usage.codeAllocatedBytes }
    }

    func refresh() {
        guard !isApplyingKeepCount else { return }
        isLoading = true
        errorMessage = nil
        Task {
            defer { isLoading = false }
            capBytes = await coordinator.globalCodeCapBytes(defaults: defaults)
            selectedKeepCount = await coordinator.versionKeepCount(defaults: defaults)
            do {
                usage = try await coordinator.globalStorageUsage(defaults: defaults)
                // design 8 item 3: the promised number is "reclaimable if
                // Iris frees everything it safely can" (current, previous,
                // pending and pinned always kept), not "reclaimable down to
                // the owner's configured cap" -- a 0-byte target plan is
                // exactly that maximum-reclaim plan (`planGlobalReclaim`
                // keeps choosing candidates until the running total is at
                // or under the target).
                promisedReclaimableBytes = try await coordinator.planGlobalCapEnforcement(capBytes: 0, defaults: defaults).reclaimableBytes
            } catch {
                errorMessage = "Iris couldn't free space right now. Your apps and data were not changed. Try again."
            }
        }
    }

    func freeUpSpace() {
        guard !isFreeing, !isApplyingKeepCount else { return }
        isFreeing = true
        resultMessage = nil
        errorMessage = nil
        Task {
            defer { isFreeing = false }
            let before = usage?.totalCodeBytes ?? 0
            do {
                let plan = try await coordinator.enforceGlobalCap(capBytes: 0, defaults: defaults)
                usage = try await coordinator.globalStorageUsage(defaults: defaults)
                promisedReclaimableBytes = try await coordinator.planGlobalCapEnforcement(capBytes: 0, defaults: defaults).reclaimableBytes
                let after = usage?.totalCodeBytes ?? before
                let freed = max(0, before - after)
                let pinnedKept = plan.items.isEmpty && freed == 0 ? 0 : (usage?.perApp.reduce(0) { $0 + $1.pinnedRevisionIds.count } ?? 0)
                if freed > 0 {
                    let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                    resultMessage = pinnedKept > 0
                        ? "Freed \(freedText). Kept the current version, the previous one and \(pinnedKept) pinned version\(pinnedKept == 1 ? "" : "s")."
                        : "Freed \(freedText). Kept the current version and the previous one."
                } else {
                    resultMessage = "Nothing needed freeing. Iris already keeps only the current version, the previous one and anything you pinned."
                }
            } catch {
                errorMessage = "Iris couldn't free space right now. Your apps and data were not changed. Try again."
            }
        }
    }

    func setCapBytes(_ bytes: Int64) {
        guard !isApplyingKeepCount else { return }
        Task {
            await coordinator.setGlobalCodeCapBytes(bytes, defaults: defaults)
            refresh()
        }
    }

    func selectKeepCount(_ choice: VersionsKeptPerApp) async {
        guard !isApplyingKeepCount, !isLoading, !isFreeing else { return }
        isApplyingKeepCount = true
        defer { isApplyingKeepCount = false }
        cancelKeepCount()
        errorMessage = nil
        keepCountResult = nil
        keepCountResultMessage = nil
        keepCountRaisingMessage = nil
        selectedKeepCount = await coordinator.versionKeepCount(defaults: defaults)
        if let count = choice.count, count < (selectedKeepCount.count ?? Int.max) {
            do {
                let plan = try await coordinator.planVersionKeepCount(choice, defaults: defaults)
                keepCountConfirmation = plan
                let amount = ByteCountFormatter.string(fromByteCount: plan.bytesReclaimed, countStyle: .file)
                keepCountConfirmationMessage = "Keep \(count) versions per app? Iris will free \(amount) of allocated storage now. This is the space the files give back to your iPhone."
                keepCountConfirmButtonTitle = "Keep \(count) versions"
                keepCountCancelButtonTitle = "Not now"
            } catch {
                errorMessage = "Iris couldn't check storage right now. Try again."
            }
        } else {
            await applyKeepCount(choice)
        }
    }

    func confirmKeepCount() async {
        guard !isApplyingKeepCount, !isLoading, !isFreeing,
              let plan = keepCountConfirmation else { return }
        isApplyingKeepCount = true
        defer { isApplyingKeepCount = false }
        await applyKeepCount(plan.choice)
    }

    func cancelKeepCount() {
        keepCountConfirmation = nil
        keepCountConfirmationMessage = nil
        keepCountConfirmButtonTitle = nil
        keepCountCancelButtonTitle = nil
    }

    func resetKeepCount() async {
        await selectKeepCount(.keepTwo)
    }

    private func applyKeepCount(_ choice: VersionsKeptPerApp) async {
        let isRaising = (choice.count ?? Int.max) > (selectedKeepCount.count ?? Int.max)
        errorMessage = nil
        do {
            let result = try await coordinator.setVersionKeepCount(choice, defaults: defaults)
            keepCountResult = result
            selectedKeepCount = await coordinator.versionKeepCount(defaults: defaults)
            if let count = result.choice.count {
                let amount = ByteCountFormatter.string(fromByteCount: result.bytesReclaimed, countStyle: .file)
                keepCountResultMessage = result.nothingCouldBeFreed
                    ? "Kept \(count) versions per app. Nothing could be freed because the other versions are protected or unavailable to download."
                    : "Kept \(count) versions per app. Iris freed \(amount) of allocated storage."
            }
            if isRaising {
                keepCountRaisingMessage = "Raising this number will not bring back versions that were freed. Download a version again if the catalog still offers it."
            }
            cancelKeepCount()
            // Completion is the close barrier, not the earlier estimate.
            keepCountSheetIsPresented = false
            do {
                usage = try await coordinator.globalStorageUsage(defaults: defaults)
                promisedReclaimableBytes = try await coordinator.planGlobalCapEnforcement(capBytes: 0, defaults: defaults).reclaimableBytes
            } catch {
                errorMessage = "The setting was saved, but storage details couldn't be refreshed. Try again."
            }
        } catch {
            selectedKeepCount = await coordinator.versionKeepCount(defaults: defaults)
            errorMessage = "Iris couldn't finish freeing space. Your selected setting is shown. Try again."
            keepCountSheetIsPresented = true
        }
    }
}

private extension VersionsKeptPerApp {
    var storageChoiceLabel: String {
        switch self {
        case .keepTwo: return "2 (Default)"
        case .keepThree: return "3"
        case .keepFive: return "5"
        case .keepAll: return "Keep all while there is room"
        }
    }
}

struct StoreStorageView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var headingVisible = true
    @StateObject private var model: StoreStorageModel
    let openVersions: (NativeShellAppIdentity) -> Void

    init(coordinator: NativeShellLibraryCoordinator, defaults: UserDefaults, library: [NativeShellLibraryEntry], displayNames: MyAppsDisplayNames = .empty, openVersions: @escaping (NativeShellAppIdentity) -> Void) {
        _model = StateObject(wrappedValue: StoreStorageModel(coordinator: coordinator, defaults: defaults, library: library, displayNames: displayNames))
        self.openVersions = openVersions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Storage").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    .onGeometryChange(for: Bool.self) { geometry in
                        geometry.frame(in: .scrollView(axis: .vertical)).maxY > 0
                    } action: { headingVisible = $0 }

                if let usage = model.usage {
                    totalBar(usage)
                    deviceLine(usage)
                    if usage.totalCodeBytes - (model.promisedReclaimableBytes ?? 0) > usage.capBytes { overCapMessage(usage) }
                    if let free = availableDeviceBytes, free < NativeStorageRetentionPolicy.defaultMinimumFreeBytesForStaging { lowStorageBanner }
                    freeUpSection
                    capRow(usage)
                    keepCountSection
                    if model.perAppRows.isEmpty {
                        Text("Nothing to free yet.").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.empty)
                    } else {
                        byAppSection
                    }
                } else if model.isLoading {
                    ProgressView("Checking storage...")
                } else if let error = model.errorMessage {
                    Text(error).font(.footnote).accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.error)
                }
            }
            .padding(16)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(NativeMarketplaceStyle.paper)
        .foregroundStyle(NativeMarketplaceStyle.ink)
        .navigationTitle(headingVisible ? "" : "Storage").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.root)
        .task { if model.usage == nil { model.refresh() } }
        .sheet(isPresented: $model.capSheetIsPresented) { capSheet }
        .sheet(isPresented: $model.keepCountSheetIsPresented, onDismiss: model.cancelKeepCount) { keepCountSheet }
        .onChange(of: model.selectedKeepCount) { _, choice in
            UIAccessibility.post(notification: .announcement, argument: "Versions kept per app, \(choice.storageChoiceLabel)")
        }
        .onChange(of: model.keepCountConfirmationMessage) { _, message in
            if let message { UIAccessibility.post(notification: .announcement, argument: message) }
        }
    }

    private func totalBar(_ usage: NativeStorageGlobalUsage) -> some View {
        // "Your data" is per-app, WKWebsiteDataStore-measured Host state
        // (`NativeStorageAppUsageModel.userDataBytesProvider`); this cross-
        // app total has no such reading available, so the bar shows the two
        // segments it can state honestly: app code kept and app code that
        // could be freed. Never labelled as the full three-segment bar
        // design section 8 sketches until a cross-app data total exists.
        let reclaimable = model.promisedReclaimableBytes ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            let totalsLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout())
            totalsLayout {
                Text("Iris apps on this iPhone").font(.headline)
                if !typeSize.isAccessibilitySize { Spacer() }
                Text(ByteCountFormatter.string(fromByteCount: usage.totalCodeBytes, countStyle: .file))
                    .font(.headline)
            }
            GeometryReader { geo in
                let total = max(usage.totalCodeBytes, 1)
                let freeShare = min(1.0, Double(reclaimable) / Double(total))
                HStack(spacing: 0) {
                    Rectangle().fill(NativeMarketplaceStyle.electric)
                        .frame(width: geo.size.width * (1 - freeShare))
                    Rectangle().fill(NativeMarketplaceStyle.fog.opacity(0.5))
                        .frame(width: geo.size.width * freeShare)
                }
            }
            .frame(height: 12).clipShape(Capsule())
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.totalBar)
            let legendLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 14))
            legendLayout {
                Label("App code \(ByteCountFormatter.string(fromByteCount: max(0, usage.totalCodeBytes - reclaimable), countStyle: .file))", systemImage: "square.fill")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.electric)
                Label("Can be freed \(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file))", systemImage: "square.fill")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.total)
    }

    private func deviceLine(_ usage: NativeStorageGlobalUsage) -> some View {
        let freeBytes = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        let usedText = ByteCountFormatter.string(fromByteCount: usage.totalCodeBytes, countStyle: .file)
        let freeText = freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        let text = freeText.map { "Iris apps use \(usedText). Your iPhone has \($0) free." } ?? "Iris apps use \(usedText)."
        return Text(text).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.deviceLine)
    }

    private var availableDeviceBytes: Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    private func overCapMessage(_ usage: NativeStorageGlobalUsage) -> some View {
        let kept = max(0, usage.totalCodeBytes - (model.promisedReclaimableBytes ?? 0))
        let size = ByteCountFormatter.string(fromByteCount: kept, countStyle: .file)
        let limit = ByteCountFormatter.string(fromByteCount: usage.capBytes, countStyle: .file)
        return Text("Your apps' kept versions use \(size), more than the \(limit) limit. Iris keeps them all. Raise the limit or remove apps you don't use.")
            .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            .accessibilityIdentifier("iris.store.storage.over-cap")
    }

    private var lowStorageBanner: some View {
        Text("Your iPhone has less than 500 MB free. Updates are paused until there is room.")
            .font(.footnote).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(NativeMarketplaceStyle.fog, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.low)
    }

    private var freeUpSection: some View {
        let reclaimable = model.promisedReclaimableBytes
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.freeUpSpace()
            } label: {
                if let reclaimable, reclaimable > 0 {
                    Text("Free up space (\(ByteCountFormatter.string(fromByteCount: reclaimable, countStyle: .file)))")
                } else {
                    Text("Nothing to free right now")
                }
            }
            .buttonStyle(StoreMainActionStyle())
            .disabled(model.isFreeing || model.isApplyingKeepCount || (reclaimable ?? 0) <= 0)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.freeUp)

            Text("Removes old versions you are not using. Keeps the current version, the previous one and anything you pinned. Never touches your data.")
                .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.freeUpSub)

            if model.isFreeing { ProgressView() }
            if let result = model.resultMessage {
                Text(result).font(.footnote).accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.result)
            }
        }
    }

    private func capRow(_ usage: NativeStorageGlobalUsage) -> some View {
        Button { model.capSheetIsPresented = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep at most \(ByteCountFormatter.string(fromByteCount: usage.capBytes, countStyle: .memory)) of app code")
                        .font(.subheadline.weight(.semibold))
                    Text("Iris frees old versions on its own above this").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                }
                Spacer()
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.cap)
        .disabled(model.isApplyingKeepCount)
    }

    private var keepCountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { model.keepCountSheetIsPresented = true } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Versions kept per app").font(.subheadline.weight(.semibold))
                    Text(model.selectedKeepCount.storageChoiceLabel).font(.subheadline)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Versions kept per app")
            .accessibilityValue(model.selectedKeepCount.storageChoiceLabel)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCount)
            .disabled(model.isApplyingKeepCount || model.isFreeing || model.isLoading)
            keepCountHelp
            if let result = model.keepCountResultMessage {
                Text(result).font(.footnote)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountResult)
            }
            if let warning = model.keepCountRaisingMessage {
                Text(warning).font(.footnote)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountRaising)
            }
            if let error = model.errorMessage {
                Text(error).font(.footnote)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountError)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var keepCountHelp: some View {
        Text("Current and previous versions count. Pinned, pending, and versions only on this iPhone are kept separately.")
            .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountHelp)
    }

    private var keepCountSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    keepCountHelp
                    ForEach(VersionsKeptPerApp.allCases, id: \.rawValue) { choice in
                        Button { Task { await model.selectKeepCount(choice) } } label: {
                            HStack(alignment: .top) {
                                Text(choice.storageChoiceLabel).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if model.selectedKeepCount == choice {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.storageChoiceLabel)
                        .accessibilityAddTraits(model.selectedKeepCount == choice ? .isSelected : [])
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountOption(choice))
                        .disabled(model.isApplyingKeepCount || model.keepCountConfirmation != nil)
                    }
                    Button { Task { await model.resetKeepCount() } } label: {
                        Text("Reset to 2 (Default)").fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountReset)
                    .disabled(model.isApplyingKeepCount || model.keepCountConfirmation != nil)
                    if let message = model.keepCountConfirmationMessage {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(message).fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountConfirmation)
                            Button { Task { await model.confirmKeepCount() } } label: {
                                Text(model.keepCountConfirmButtonTitle ?? "")
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountConfirm)
                            Button { model.cancelKeepCount() } label: {
                                Text(model.keepCountCancelButtonTitle ?? "")
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountCancel)
                        }
                        .disabled(model.isApplyingKeepCount)
                    }
                    if model.isApplyingKeepCount { ProgressView("Checking storage...") }
                    if let error = model.errorMessage {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountError)
                    }
                    Button {
                        model.cancelKeepCount()
                        model.keepCountSheetIsPresented = false
                    } label: {
                        Text("Done").fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountDone)
                    .disabled(model.isApplyingKeepCount)
                }
                .padding(16)
            }
            .navigationTitle("Versions kept per app")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(model.isApplyingKeepCount)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.keepCountSheet)
    }

    private var capSheet: some View {
        let choices: [Int64] = [1 << 30, 2 << 30, 4 << 30]
        return NavigationStack {
            List(choices, id: \.self) { choice in
                Button {
                    model.setCapBytes(choice)
                    model.capSheetIsPresented = false
                } label: {
                    HStack {
                        Text("\(choice >> 30) GB")
                        Spacer()
                        if model.capBytes == choice { Image(systemName: "checkmark") }
                    }
                }
            }
            .navigationTitle("Keep at most")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { model.capSheetIsPresented = false } } }
        }
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.capSheet)
    }

    private var byAppSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("By app, largest first").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ForEach(model.perAppRows) { row in
                Button { openVersions(row.identity) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName).font(.subheadline.weight(.semibold))
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(row.usage.codeAllocatedBytes), countStyle: .file)) app code · \(row.usage.storedRevisionCount) version\(row.usage.storedRevisionCount == 1 ? "" : "s")")
                                .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Storage.appRow(row.identity.appId))
                Divider()
            }
        }
    }
}
#endif
