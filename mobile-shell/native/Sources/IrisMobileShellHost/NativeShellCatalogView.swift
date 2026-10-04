#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Catalogue reads start when the reader enters Browse or requests a refresh.
/// No polling, authenticated account traffic, or synthesized package URLs.
@MainActor
final class NativeShellCatalogModel: ObservableObject {
    @Published private(set) var apps: [PublikMobileCatalogApp] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var downloadingName: String?
    @Published private(set) var progress: PublikMobileDownloadProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoadedAt: Date?
    /// Unit m3-guideline47: mirrors the injected block list/age gate so the
    /// view can render synchronously. Empty/nil until `review47Refresh()`
    /// runs, which never blocks first paint.
    @Published private(set) var review47BlockedAppIDs: Set<String> = []
    @Published private(set) var review47DeclaredAge: Int?

    private let client: PublikMobileCatalogClient
    private let importer: NativeShellAppModel
    /// nil by default: existing callers/tests are unaffected until a Host
    /// wiring (see INTEGRATION_HOOKS.md) supplies these.
    private let review47BlockList: Review47BlockList?
    private let review47AgeGate: Review47AgeGate?
    private var catalogTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var catalogToken = UUID()
    private var downloadToken = UUID()
    private var importGeneration: UInt64?
    private var retryApp: PublikMobileCatalogApp?
    private var downloadBinding: NativeUsageBinding?
    private var catalogBinding: NativeUsageBinding?

    init(
        importer: NativeShellAppModel,
        client: PublikMobileCatalogClient = .init(),
        review47BlockList: Review47BlockList? = nil,
        review47AgeGate: Review47AgeGate? = nil
    ) {
        self.importer = importer
        self.client = client
        self.review47BlockList = review47BlockList
        self.review47AgeGate = review47AgeGate
    }

    deinit {
        catalogTask?.cancel()
        downloadTask?.cancel()
    }

    var downloadableApps: [PublikMobileCatalogApp] {
        apps.filter(NativeMobileMarketplacePolicy.isVisibleInBrowse)
    }
    var isDownloading: Bool { downloadingName != nil }
    var canRetryDownload: Bool { retryApp != nil && !isDownloading }

    /// Safe to call every time Browse appears; both reads are local
    /// (UserDefaults-backed by default) and this never blocks first paint.
    func review47Refresh() async {
        if let review47BlockList { review47BlockedAppIDs = await review47BlockList.blockedAppIDs() }
        if let review47AgeGate { review47DeclaredAge = await review47AgeGate.declaredMinimumAge() }
    }

    func review47Restriction(for app: PublikMobileCatalogApp) -> NativeMobileMarketplacePolicy.Review47Restriction? {
        guard let appId = app.mobileShell?.appId else { return nil }
        return NativeMobileMarketplacePolicy.review47Restriction(
            for: app,
            isBlocked: review47BlockedAppIDs.contains(appId),
            declaredAge: review47DeclaredAge
        )
    }

    func review47ToggleBlock(_ app: PublikMobileCatalogApp) {
        guard let review47BlockList, let appId = app.mobileShell?.appId else { return }
        let willBlock = !review47BlockedAppIDs.contains(appId)
        Task {
            if willBlock { await review47BlockList.block(appId: appId) }
            else { await review47BlockList.unblock(appId: appId) }
            await review47Refresh()
        }
    }

    /// Pure and synchronous: no network, and nothing is sent until the
    /// reader taps through the returned URL in their own mail/browser app.
    func review47ReportTarget(for app: PublikMobileCatalogApp) -> Review47ReportComposer.ComposeTarget? {
        guard let descriptor = app.mobileShell, let metadata = descriptor.appStoreMetadata else { return nil }
        return Review47ReportComposer.composeReport(
            for: metadata.reportContact,
            appDisplayName: app.name,
            appId: descriptor.appId
        )
    }

    func loadCatalog() {
        guard !isDownloading else { return }
        if isLoading { importer.recordUsage(.catalogLoadOutcome(.cancelled), binding: catalogBinding) }
        catalogTask?.cancel()
        let token = UUID()
        catalogToken = token
        isLoading = true
        errorMessage = nil
        retryApp = nil
        let binding = importer.beginUsage(.catalogLoadAttempt)
        catalogBinding = binding
        catalogTask = Task {
            do {
                let loaded = try await client.fetchCatalog()
                guard catalogToken == token, !Task.isCancelled else { return }
                apps = loaded
                hasLoaded = true
                lastLoadedAt = Date()
                isLoading = false
                importer.recordUsage(.catalogLoadOutcome(.success), binding: binding)
                catalogBinding = nil
            } catch {
                guard catalogToken == token, !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "The Publik catalogue could not be verified. Retry when a connection is available."
                importer.recordUsage(.catalogLoadOutcome(.failure), binding: binding)
                catalogBinding = nil
            }
        }
    }

    func download(_ app: PublikMobileCatalogApp) {
        guard !isDownloading, let descriptor = app.mobileShell else { return }
        if isLoading {
            importer.recordUsage(.catalogLoadOutcome(.cancelled), binding: catalogBinding)
            catalogBinding = nil
        }
        catalogTask?.cancel()
        catalogToken = UUID()
        isLoading = false
        downloadTask?.cancel()
        let token = UUID()
        downloadToken = token
        let generation = importer.beginWebsiteDownload()
        importGeneration = generation
        downloadingName = app.name
        progress = nil
        errorMessage = nil
        retryApp = nil
        let binding = importer.beginUsage(.downloadAttempt, identity: descriptor.identity)
        downloadBinding = binding
        downloadTask = Task {
            do {
                let package = try await client.download(app) { [weak self] value in
                    Task { @MainActor in
                        guard let self, self.downloadToken == token, self.isDownloading else { return }
                        self.progress = value
                    }
                }
                guard downloadToken == token, !Task.isCancelled else { return }
                let accepted = importer.reviewWebsiteDownload(package, generation: generation)
                clearTransfer()
                importer.recordUsage(.downloadOutcome(accepted ? .success : .cancelled), binding: binding)
            } catch {
                guard downloadToken == token, !Task.isCancelled else { return }
                importer.cancelWebsiteDownload(generation: generation)
                clearTransfer()
                retryApp = app
                errorMessage = "The download could not be verified. Nothing was installed. Retry to download the same catalogue entry again."
                importer.recordUsage(.downloadOutcome(.failure), binding: binding)
            }
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        let binding = downloadBinding
        downloadToken = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        if let importGeneration { importer.cancelWebsiteDownload(generation: importGeneration) }
        clearTransfer()
        retryApp = nil
        errorMessage = nil
        importer.recordUsage(.downloadOutcome(.cancelled), binding: binding)
    }

    func retryDownload() {
        guard let retryApp else { return }
        download(retryApp)
    }

    private func clearTransfer() {
        downloadingName = nil
        progress = nil
        importGeneration = nil
        downloadBinding = nil
    }
}

struct NativeShellCatalogSection: View {
    @ObservedObject var model: NativeShellCatalogModel
    var onInstall: ((PublikMobileCatalogApp) -> Void)? = nil

    var body: some View {
        Section("Mobile apps") {
            Text("Browse published mobile packages. Installed apps stay in My apps.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .task { await model.review47Refresh() }

            Button(model.hasLoaded ? "Refresh Publik catalogue" : "Check Publik downloads") { model.loadCatalog() }
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.load)
                .disabled(model.isLoading || model.isDownloading)

            if model.isLoading { ProgressView("Checking published downloads…") }

            if model.hasLoaded {
                Text("\(model.downloadableApps.count) mobile package listings")
                    .font(.caption)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.counts)
                if model.downloadableApps.isEmpty {
                    Text("No mobile shell downloads are published in this catalogue response. Your library and local imports still work.")
                        .font(.footnote)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.unavailable)
                }
                ForEach(model.downloadableApps) { app in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.headline)
                        Text("iPhone package · publikhq.com").font(.caption).foregroundStyle(.secondary)
                        Review47AppStoreInfoView(model: model, app: app)
                        if let restriction = model.review47Restriction(for: app) {
                            Text(Review47AppStoreInfoView.restrictionMessage(restriction))
                                .font(.footnote)
                                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.review47Restricted(app.slug))
                        } else {
                            Button("Get app") {
                                if let onInstall { onInstall(app) }
                                else { model.download(app) }
                            }
                                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.download(app.slug))
                                .disabled(model.isDownloading)
                        }
                    }
                }
            }

            if let name = model.downloadingName {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Downloading \(name)")
                    if let progress = model.progress {
                        ProgressView(value: Double(progress.receivedBytes), total: Double(max(1, progress.expectedBytes)))
                        Text("\(progress.receivedBytes) / \(progress.expectedBytes) bytes").font(.caption.monospacedDigit())
                    } else {
                        ProgressView()
                    }
                    Button("Cancel download", role: .cancel) { model.cancelDownload() }
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.cancel)
                }
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage).font(.footnote)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.error)
                if model.canRetryDownload {
                    Button("Retry download") { model.retryDownload() }
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.retry)
                }
            }
        }
    }
}
#endif
