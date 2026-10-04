#if os(iOS)
import Foundation
import IrisMobileShellCore
import SwiftUI

/// One presentation owns one flow. Replacing a download cancels that captured
/// flow, never a later request which happens to share the library coordinator.
@MainActor
public final class NativeShellWebsiteInstallModel: ObservableObject {
    @Published public private(set) var isPresented = false
    @Published public private(set) var review: NativeWebsiteInstallReview?
    @Published public private(set) var progress: NativeWebsiteInstallProgress?
    @Published public private(set) var failureMessage: String? {
        didSet { if failureMessage == nil { ageCheckRating = nil } }
    }
    /// RC-02 (f): set when the refusal was "needs an age" (Guideline 4.7.5).
    /// The sheet then offers the same age check as the store's Get button
    /// instead of a bare refusal, and retries the link after an answer.
    @Published public private(set) var ageCheckRating: Int?
    @Published public private(set) var isCommitting = false
    @Published public private(set) var deferredSlug: String?

    private let coordinator: NativeShellLibraryCoordinator
    private let client: PublikMobileCatalogClient
    private let capabilityPolicy: CapabilityPolicy
    private let usageService: NativeUsageService?
    /// Unit m3-guideline47: nil by default, so every existing caller is
    /// unaffected until a Host wiring supplies these (see
    /// INTEGRATION_HOOKS.md). When present, a blocked or age-restricted app
    /// is refused before any download, cold or warm, from Browse or from a
    /// universal link.
    private let review47BlockList: Review47BlockList?
    private let review47AgeGate: Review47AgeGate?
    private let canPresent: @MainActor () -> Bool
    private let prepareHost: @MainActor () async -> Bool
    private let runtimeSupportsDownloadedContent: @MainActor () -> Bool
    private var flow: NativeWebsiteInstallFlow?
    private var hasStartedFlowPreparation = false
    private var operation: Task<Void, Never>?
    private var presentationID = UUID()
    private var requestedURL: URL?
    private var deferredURL: URL?
    private var completedResult: NativeWebsiteInstallResult?

    public convenience init(
        coordinator: NativeShellLibraryCoordinator,
        client: PublikMobileCatalogClient = .init(),
        capabilityPolicy: CapabilityPolicy,
        usageService: NativeUsageService? = nil,
        review47BlockList: Review47BlockList? = nil,
        review47AgeGate: Review47AgeGate? = nil,
        canPresent: @escaping @MainActor () -> Bool = { true },
        prepareHost: @escaping @MainActor () async -> Bool
    ) {
        self.init(
            coordinator: coordinator,
            client: client,
            capabilityPolicy: capabilityPolicy,
            usageService: usageService,
            review47BlockList: review47BlockList,
            review47AgeGate: review47AgeGate,
            canPresent: canPresent,
            runtimeSupportsDownloadedContent: { true },
            prepareHost: prepareHost
        )
    }

    init(
        coordinator: NativeShellLibraryCoordinator,
        client: PublikMobileCatalogClient = .init(),
        capabilityPolicy: CapabilityPolicy,
        usageService: NativeUsageService? = nil,
        review47BlockList: Review47BlockList? = nil,
        review47AgeGate: Review47AgeGate? = nil,
        canPresent: @escaping @MainActor () -> Bool = { true },
        runtimeSupportsDownloadedContent: @escaping @MainActor () -> Bool,
        prepareHost: @escaping @MainActor () async -> Bool
    ) {
        self.coordinator = coordinator
        self.client = client
        self.capabilityPolicy = capabilityPolicy
        self.usageService = usageService
        self.review47BlockList = review47BlockList
        self.review47AgeGate = review47AgeGate
        self.canPresent = canPresent
        self.runtimeSupportsDownloadedContent = {
            VerifiedRevisionWebView.supportsFailClosedMediaBoundary
                && runtimeSupportsDownloadedContent()
        }
        self.prepareHost = prepareHost
    }

    deinit { operation?.cancel() }

    var ageGateForSheet: Review47AgeGate? { review47AgeGate }

    public var canRetry: Bool {
        requestedURL != nil && failureMessage != nil && !isCommitting
    }

    /// Deferred links are visible to the reader, but cannot close a running app
    /// or discard an unrelated package review without the reader leaving it.
    public func receive(_ url: URL, deferUntilCurrentAppCloses: Bool = false) {
        do {
            let intent = try NativeWebsiteInstallIntent.parse(url)
            if let completedResult {
                // SwiftUI has begun dismissing the successful install sheet,
                // but its actual onDismiss still owns transfer of this result.
                // A second URL cannot erase that launch or open another sheet.
                if completedResult.slug == intent.slug { return }
                if deferredURL == nil {
                    deferredURL = url
                    deferredSlug = intent.slug
                }
                return
            }
            if (isPresented || isCommitting), failureMessage == nil,
               let requestedURL,
               let existingIntent = try? NativeWebsiteInstallIntent.parse(requestedURL),
               existingIntent.slug == intent.slug {
                // The public listing and dedicated handoff URL can identify
                // the same app. A spelling change must not replace its review
                // or queue it to reopen after an in-flight install finishes.
                return
            }
            if deferUntilCurrentAppCloses || isCommitting || !canPresent() {
                deferredURL = url
                deferredSlug = intent.slug
                return
            }
            begin(url)
        } catch {
            // Malformed links never enter the downloader or change an existing
            // app/review. An idle shell can explain the rejected handoff.
            guard completedResult == nil, deferredURL == nil,
                  !deferUntilCurrentAppCloses, !isCommitting, !isPresented else { return }
            requestedURL = nil
            review = nil
            progress = nil
            failureMessage = "This app link is not valid. Open the app's Download button on Publik and try again."
            isPresented = true
        }
    }

    public func continueDeferredRequest() {
        guard !isPresented, !isCommitting, canPresent(), let url = deferredURL else { return }
        deferredURL = nil
        deferredSlug = nil
        begin(url)
    }

    /// The store's landing for a link that waited while an app, a review or
    /// an install was open (design 9.5, CLICK-PATH-005): same guards as
    /// `continueDeferredRequest`, but instead of starting the install sheet
    /// the waiting slug is handed back so the shell shows that app's page.
    /// Nothing installs until the person taps Get there.
    public func takeDeferredRequestSlug() -> String? {
        guard !isPresented, !isCommitting, canPresent(), let url = deferredURL else { return nil }
        guard let intent = try? NativeWebsiteInstallIntent.parse(url) else { return nil }
        deferredURL = nil
        deferredSlug = nil
        return intent.slug
    }

    public func dismissDeferredRequest() {
        deferredURL = nil
        deferredSlug = nil
    }

    public func retry() {
        guard canRetry, canPresent(), let flow else { return }
        if !hasStartedFlowPreparation, let requestedURL {
            // The Host may have declined its reservation before Core received
            // an intent. Recheck that gate rather than retrying an empty flow.
            // Once preparation began, preserve the same flow and any exact
            // approved post-activation capability instead.
            begin(requestedURL)
            return
        }
        operation?.cancel()
        presentationID = UUID()
        let identifier = presentationID
        review = nil
        failureMessage = nil
        progress = nil
        isPresented = true
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                // Reuse this flow's exact approved installation after activation.
                // Starting a new flow would lose API setup authority and relabel
                // the same retry as an unrelated already-installed Open.
                let prepared = try await flow.retry(progress: progressHandler(for: identifier))
                guard presentationID == identifier, !Task.isCancelled else { return }
                switch prepared {
                case .consentRequired(let review): self.review = review
                case .openedExisting(let result): complete(result)
                }
            } catch {
                guard presentationID == identifier, !Task.isCancelled else { return }
                progress = nil
                fail(with: error)
            }
        }
    }

    public func installAndOpen() {
        guard !isCommitting, let review, review.unsupportedCapabilities.isEmpty,
              let flow else { return }
        // This short transaction is serialized. A new link waits; the UI does
        // not offer a cancel button after the installation decision is committed.
        isCommitting = true
        failureMessage = nil
        let identifier = presentationID
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await flow.installAndOpen(
                    consentToken: review.consentToken,
                    progress: progressHandler(for: identifier)
                )
                guard presentationID == identifier else { return }
                complete(result)
            } catch {
                guard presentationID == identifier else { return }
                isCommitting = false
                self.review = nil
                progress = nil
                fail(with: error)
            }
        }
    }

    public func cancel() {
        guard !isCommitting else { return }
        presentationID = UUID()
        operation?.cancel()
        operation = nil
        let cancelledFlow = flow
        flow = nil
        hasStartedFlowPreparation = false
        Task { _ = await cancelledFlow?.cancel() }
        completedResult = nil
        requestedURL = nil
        review = nil
        progress = nil
        failureMessage = nil
        isPresented = false
    }

    public func presentationWasDismissed() -> NativeWebsiteInstallResult? {
        let result = completedResult
        completedResult = nil
        if result == nil { cancel() }
        return result
    }

    public func setPresentation(_ presented: Bool) {
        // The successful completion already set isPresented to false. Do not
        // turn the ensuing SwiftUI dismissal notification into a cancellation.
        if !presented, isPresented { cancel() }
    }

    private func begin(_ url: URL) {
        operation?.cancel()
        let supersededFlow = flow
        Task { _ = await supersededFlow?.cancel() }
        guard runtimeSupportsDownloadedContent() else {
            operation = nil
            flow = nil
            presentationID = UUID()
            requestedURL = nil
            completedResult = nil
            review = nil
            progress = nil
            isCommitting = false
            failureMessage = VerifiedRevisionWebView.unsupportedRuntimeMessage
            isPresented = true
            return
        }
        let nextFlow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: client,
            capabilityPolicy: capabilityPolicy,
            usageService: usageService,
            review47BlockList: review47BlockList,
            review47AgeGate: review47AgeGate
        )
        flow = nextFlow
        hasStartedFlowPreparation = false
        presentationID = UUID()
        let identifier = presentationID
        requestedURL = url
        completedResult = nil
        review = nil
        failureMessage = nil
        progress = nil
        isCommitting = false
        isPresented = true
        operation = Task { [weak self] in
            guard let self else { return }
            guard presentationID == identifier, !Task.isCancelled else { return }
            guard await prepareHost() else {
                guard presentationID == identifier, !Task.isCancelled else { return }
                failureMessage = "Finish the current app or package review before opening this download."
                return
            }
            guard presentationID == identifier, !Task.isCancelled else { return }
            do {
                hasStartedFlowPreparation = true
                let prepared = try await nextFlow.prepare(
                    url: url,
                    progress: progressHandler(for: identifier)
                )
                guard presentationID == identifier, !Task.isCancelled else { return }
                switch prepared {
                case .consentRequired(let review):
                    self.review = review
                case .openedExisting(let result):
                    complete(result)
                }
            } catch {
                guard presentationID == identifier, !Task.isCancelled else { return }
                progress = nil
                fail(with: error)
            }
        }
    }

    private func fail(with error: Error) {
        failureMessage = Self.message(for: error)
        if let flowError = error as? NativeWebsiteInstallFlowError,
           case .ageRestricted(_, let rating, let declared) = flowError, declared == nil {
            ageCheckRating = rating
        }
    }

    private func progressHandler(for identifier: UUID) -> NativeWebsiteInstallProgressHandler {
        { [weak self] value in
            Task { @MainActor in
                guard let self, self.presentationID == identifier, self.isPresented else { return }
                self.progress = value
            }
        }
    }

    private func complete(_ result: NativeWebsiteInstallResult) {
        isCommitting = false
        review = nil
        completedResult = result
        isPresented = false
    }

    private static func message(for error: Error) -> String {
        if error as? NativeShellLibraryError == .activeSelectionSuperseded {
            return "The selected version changed, so the earlier installation permission expired. Retry to check the current app again. Your saved data was not reset."
        }
        if let failure = error as? NativeWebsiteInstallFlowError {
            switch failure {
            case .appNotFound:
                return "This app is not in Publik's current catalogue. Nothing was installed."
            case .anotherPackageReviewPending:
                return "Another package review is open. Finish or cancel it, then retry this app."
            case .cancelledAfterStaging:
                return "The download is ready, but installation was cancelled before it became the current version. Your previous app is unchanged."
            case .activationFailedAfterStaging:
                return "The verified download is ready, but Iris could not confirm which version is current. Retry to recheck the installation; Iris will not reset your saved data."
            case .openFailedAfterActivation:
                return "The app was installed, but it could not open. Retry to recheck and open the installed app; your saved data has not been reset."
            case .publishedRevisionMismatch:
                return "The available app version no longer matches this download. Iris did not open a different version as though it were the requested one. Retry to check the current catalogue."
            case .commitInProgress:
                return "Another installation is finishing. Retry when it is complete."
            case .unsupportedCapabilities:
                return "This Iris version does not support the app's requested capabilities. The app was not installed."
            case .invalidConsentToken, .requestSuperseded, .cancelled, .noRetryAvailable:
                return "This download request is no longer current. Retry to check the app again."
            case .blockedByLocalPolicy:
                return "This app is blocked on this device. Unblock it, then retry."
            case .ageRestricted(_, let appAgeRating, let declaredAge):
                return Review47AgeGateCopy.message(appAgeRating: appAgeRating, declaredAge: declaredAge) + " Nothing was installed or opened."
            }
        }
        if let download = error as? PublikMobileDownloadError,
           case .mobileShellUnavailable = download {
            return "This app is not available on mobile: Publik has not published an Iris mobile package for it. Nothing was installed or switched. Your apps remain in My apps."
        }
        if let shell = error as? NativeShellError {
            switch shell {
            case .baseMismatch, .userDataNamespaceMismatch:
                return "This download cannot safely replace your current app. Iris kept the current version and its data."
            default:
                return "Iris could not safely finish this installation. Retry to verify the download and the current app again."
            }
        }
        return "The download could not be verified. Check your connection and retry. Iris will not install unverified bytes."
    }
}

struct NativeShellWebsiteInstallView: View {
    @ObservedObject var model: NativeShellWebsiteInstallModel
    var sourceLabel = "From Publik · verified download"
    /// RC-05: who made the app. Every catalog app is Publik's own today, so the
    /// default is right; a caller that knows the index row's `publisher` passes it.
    var publisherName = StoreApp.defaultPublisher
    @State private var showingAgeCheck = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let failure = model.failureMessage {
                        Label("Could not finish", systemImage: "exclamationmark.triangle")
                            .font(.title2.bold())
                        Text(failure)
                            .accessibilityIdentifier("iris.website.install.error")
                        if model.ageCheckRating != nil, model.ageGateForSheet != nil {
                            Button("Check your age") { showingAgeCheck = true }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("iris.website.install.age-check")
                        }
                    } else if let review = model.review, !model.isCommitting {
                        Label(review.displayName, systemImage: "app.badge.checkmark")
                            .font(.title.bold())
                        Text(StoreApp.byLine(publisher: publisherName))
                            .font(.subheadline)
                            .accessibilityIdentifier("iris.website.install.publisher")
                        Text(sourceLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        NativeCapabilityDisclosure(capabilities: review.requestedCapabilities)
                        if !review.unsupportedCapabilities.isEmpty {
                            Label("This Iris version cannot run the app", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text("Unsupported capabilities: " + review.unsupportedCapabilities.joined(separator: ", "))
                                .font(.footnote)
                        }
                        DisclosureGroup("Technical details") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("App: \(review.identity.appId)")
                                Text("Project: \(review.identity.projectId)")
                                Text("Revision: \(review.revisionId)")
                                Text("Package: \(review.packageSHA256)")
                                Text("Storage: \(review.dataNamespace)")
                            }
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.top, 8)
                        }
                    } else {
                        Text(model.isCommitting ? "Opening your app" : "Getting your app ready")
                            .font(.title2.bold())
                        Text(sourceLabel)
                            .font(.subheadline).foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.large)
                        Text(progressMessage)
                            .accessibilityIdentifier("iris.website.install.progress")
                        if case .downloading(_, let transfer?) = model.progress {
                            ProgressView(
                                value: Double(transfer.receivedBytes),
                                total: Double(max(1, transfer.expectedBytes))
                            )
                        }
                        Text("Iris handles the download, verification, and setup. There is no file to find or separate activation step.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Get app")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 16) {
                    if !model.isCommitting {
                        Button(model.failureMessage == nil ? "Cancel" : "Close") { model.cancel() }
                            .accessibilityIdentifier("iris.website.install.cancel")
                    }
                    Spacer()
                    if model.canRetry {
                        Button("Retry") { model.retry() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("iris.website.install.retry")
                    } else if let review = model.review, !model.isCommitting {
                        Button(installLabel(review)) { model.installAndOpen() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!review.unsupportedCapabilities.isEmpty)
                            .accessibilityIdentifier("iris.website.install.confirm")
                    } else if model.isCommitting {
                        Text("Finishing installation…").font(.footnote)
                    }
                }
                .padding()
                .background(.bar)
            }
        }
        .interactiveDismissDisabled(model.isCommitting)
        .sheet(isPresented: $showingAgeCheck) {
            if let gate = model.ageGateForSheet, let rating = model.ageCheckRating {
                NativeAgeGateSheet(
                    thresholds: .init(ages: NativeAgeGateSheet.storeAges),
                    copy: .store(appAgeRating: rating),
                    ageGate: gate,
                    onDeclared: { _ in
                        showingAgeCheck = false
                        model.retry()
                    }
                )
                .presentationDetents([.medium])
            }
        }
        .accessibilityIdentifier("iris.website.install.sheet")
    }

    private func installLabel(_ review: NativeWebsiteInstallReview) -> String {
        switch review.disposition {
        case .install: return "Install & Open"
        case .update: return "Update & Open"
        }
    }

    private var progressMessage: String {
        switch model.progress {
        case .resolvingCatalog: return "Finding the app you chose…"
        case .checkingInstalled: return "Checking whether it is already installed…"
        case .downloading: return "Retrieving the app package…"
        case .verifying, .reviewing: return "Verifying the app…"
        case .awaitingConsent: return "Ready for your confirmation."
        case .staging: return "Preparing the verified app…"
        case .activating: return "Finishing setup…"
        case .opening: return "Opening the app…"
        case nil: return "Preparing your app request…"
        }
    }
}
#endif
