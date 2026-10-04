#if os(iOS)
import Combine
import Foundation
import IrisMobileShellCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class NativeShellAppModel: ObservableObject {
    public enum RetryAction: Equatable {
        case refresh
        case reopenReview(Data)
        case reopenWebsiteReview(PublikMobileDownloadedPackage)
        case open(NativeShellAppIdentity)
        case activate(NativeShellAppIdentity, String)
        case revert(NativeShellAppIdentity, String)
    }

    @Published public private(set) var library: [NativeShellLibraryEntry] = []
    @Published public private(set) var review: NativeShellPackageReview?
    @Published public private(set) var notice: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var retryAction: RetryAction?
    @Published public var launch: NativeShellLaunchOutcome?
    @Published public var importPickerIsPresented = false
    @Published public private(set) var reviewSourceSlug: String?
    @Published public private(set) var launchLoadResult: NativeShellWebLoadResult?
    @Published public private(set) var isInstalling = false
    @Published public private(set) var launchDisplayName = "App"
    @Published public private(set) var launchSourceSlug: String?
    @Published public private(set) var launchPresentationID = UUID()
    @Published public private(set) var launchPackagedAPIAdapter: IrisPackagedAPIAdapterConfiguration = .notConfigured

    private let coordinator: NativeShellLibraryCoordinator
    private let usageService: NativeUsageService?
    private let bundledDemoPackage: Data?
    private let bundledDemoUpdatePackage: Data?
    private let bundledStorageCheckPackage: Data?
    private let bundledDemoUpdateBaseRevisionId: String?
    private let runtimeSupportsDownloadedContent: @MainActor () -> Bool
    private let preparePackagedAPIForLaunch: @MainActor (VerifiedLaunchDescriptor) throws -> Void
    private let packagedAPIAdapterForLaunch: @MainActor (VerifiedLaunchDescriptor) -> IrisPackagedAPIAdapterConfiguration
    private var visibleReviewPackageBytes: Data?
    private var visibleWebsitePackage: PublikMobileDownloadedPackage?
    private var launchUsageBinding: NativeUsageBinding?
    private var reviewUsageBinding: NativeUsageBinding?
    private var launchPresentationActive = false
    private var reviewPresentationActive = false
    private var pendingApprovedAPISetup: (identity: NativeShellAppIdentity, revisionId: String, retryID: UUID)?
    private var launchWaitingForReviewDismissal: (
        outcome: NativeShellLaunchOutcome,
        displayName: String,
        sourceSlug: String?,
        binding: NativeUsageBinding?,
        approvedAPIRevisionId: String?
    )?
    private var presentationGeneration = NativeShellPresentationGeneration()

    public convenience init(
        coordinator: NativeShellLibraryCoordinator,
        bundledDemoPackage: Data? = nil,
        bundledDemoUpdatePackage: Data? = nil,
        usageService: NativeUsageService? = nil,
        bundledStorageCheckPackage: Data? = nil,
        preparePackagedAPIForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) throws -> Void = { _ in },
        packagedAPIAdapterForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) -> IrisPackagedAPIAdapterConfiguration = { _ in .notConfigured }
    ) {
        self.init(
            coordinator: coordinator,
            bundledDemoPackage: bundledDemoPackage,
            bundledDemoUpdatePackage: bundledDemoUpdatePackage,
            usageService: usageService,
            bundledStorageCheckPackage: bundledStorageCheckPackage,
            preparePackagedAPIForLaunch: preparePackagedAPIForLaunch,
            packagedAPIAdapterForLaunch: packagedAPIAdapterForLaunch,
            runtimeSupportsDownloadedContent: { true }
        )
    }

    init(
        coordinator: NativeShellLibraryCoordinator,
        bundledDemoPackage: Data? = nil,
        bundledDemoUpdatePackage: Data? = nil,
        usageService: NativeUsageService? = nil,
        bundledStorageCheckPackage: Data? = nil,
        preparePackagedAPIForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) throws -> Void = { _ in },
        packagedAPIAdapterForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) -> IrisPackagedAPIAdapterConfiguration = { _ in .notConfigured },
        runtimeSupportsDownloadedContent: @escaping @MainActor () -> Bool
    ) {
        self.coordinator = coordinator
        self.usageService = usageService
        self.bundledDemoPackage = bundledDemoPackage
        self.bundledDemoUpdatePackage = bundledDemoUpdatePackage
        self.bundledStorageCheckPackage = bundledStorageCheckPackage
        self.preparePackagedAPIForLaunch = preparePackagedAPIForLaunch
        self.packagedAPIAdapterForLaunch = packagedAPIAdapterForLaunch
        self.runtimeSupportsDownloadedContent = {
            VerifiedRevisionWebView.supportsFailClosedMediaBoundary
                && runtimeSupportsDownloadedContent()
        }
        self.bundledDemoUpdateBaseRevisionId = bundledDemoUpdatePackage.flatMap {
            try? DeliveryPackageV1Validator().inspect(packageBytes: $0).baseRevisionId
        }
    }

    public var hasBundledDemo: Bool { bundledDemoPackage != nil }
    public var hasBundledStorageCheck: Bool { bundledStorageCheckPackage != nil }
    public var downloadedContentRuntimeUnavailableMessage: String? {
        runtimeSupportsDownloadedContent() ? nil : VerifiedRevisionWebView.unsupportedRuntimeMessage
    }

    @discardableResult
    private func requireDownloadedContentRuntime() -> Bool {
        guard let message = downloadedContentRuntimeUnavailableMessage else { return true }
        errorMessage = message
        retryAction = nil
        notice = nil
        return false
    }
    public var hasBlockingPresentation: Bool {
        launchPresentationActive || reviewPresentationActive || importPickerIsPresented || isInstalling
    }
    public var canReviewBundledDemoUpdate: Bool {
        guard bundledDemoUpdatePackage != nil,
              let bundledDemoUpdateBaseRevisionId else { return false }
        return library.contains { entry in
            entry.identity.appId == "iris.native-demo"
                && entry.identity.projectId == "iris.native-demo.shell"
                && entry.currentRevisionId == bundledDemoUpdateBaseRevisionId
        }
    }

    public func refresh() {
        guard !isInstalling else { return }
        run(
            retry: .refresh,
            operation: { try await self.coordinator.refreshLibrary() },
            publish: { self.library = $0 }
        )
    }

    public func removeApp(identity: NativeShellAppIdentity, alsoDeleteData: Bool,
                          permissionStore: NativePermissionStore?) async throws {
        guard !hasBlockingPresentation, !isInstalling else {
            throw NativeShellLibraryError.activeSelectionSuperseded
        }
        isInstalling = true
        defer { isInstalling = false }
        _ = try await coordinator.removeApp(identity: identity, alsoDeleteData: alsoDeleteData,
                                             permissionStore: permissionStore)
        library = try await coordinator.refreshLibrary()
    }

    public func reviewImportedFile(_ url: URL) {
        guard !isInstalling else { return }
        let generation = beginIncomingPackage()
        Task {
            do {
                let packageBytes = try await Self.readBoundedPackageBytes(from: url)
                guard presentationGeneration.isCurrent(generation) else { return }
                presentReview(packageBytes: packageBytes, usingGeneration: generation)
            } catch {
                guard presentationGeneration.isCurrent(generation) else { return }
                present(error: error, retry: nil)
            }
        }
    }

    public func reviewBundledDemo() {
        guard let bundledDemoPackage else { return }
        presentReview(packageBytes: bundledDemoPackage)
    }

    public func reviewBundledDemoUpdate() {
        guard canReviewBundledDemoUpdate, let bundledDemoUpdatePackage else { return }
        presentReview(packageBytes: bundledDemoUpdatePackage)
    }

    public func reviewBundledStorageCheck() {
        guard let bundledStorageCheckPackage else { return }
        // Synthetic developer fixture; the same raw validator, explicit local
        // review, separate stage/activate path and capability gates still apply.
        presentReview(packageBytes: bundledStorageCheckPackage)
    }

    public func cancelReview() {
        // A sheet's late dismissal notification must not invalidate the stage
        // operation which already consumed and cleared its visible review.
        guard let token = review?.reviewToken else { return }
        _ = beginIncomingPackage()
        Task {
            await coordinator.cancelReview(reviewToken: token)
        }
    }

    /// Called before network work starts, never after downloading as an implicit
    /// approval. Cancellation and other package intents invalidate this token.
    public func beginWebsiteDownload() -> UInt64 { beginIncomingPackage() }

    public func cancelWebsiteDownload(generation: UInt64) {
        guard presentationGeneration.isCurrent(generation) else { return }
        _ = beginIncomingPackage()
    }

    @discardableResult
    public func reviewWebsiteDownload(_ package: PublikMobileDownloadedPackage, generation: UInt64) -> Bool {
        guard presentationGeneration.isCurrent(generation) else { return false }
        presentReview(packageBytes: package.packageBytes, websitePackage: package, usingGeneration: generation)
        return true
    }

    private func beginIncomingPackage() -> UInt64 {
        pendingApprovedAPISetup = nil
        let generation = presentationGeneration.advance()
        recordUsage(.reviewOutcome(.cancelled), binding: reviewUsageBinding)
        reviewUsageBinding = nil
        review = nil
        visibleReviewPackageBytes = nil
        visibleWebsitePackage = nil
        reviewSourceSlug = nil
        errorMessage = nil
        retryAction = nil
        notice = nil
        Task { await coordinator.supersedePendingReview(clientReviewSequence: generation) }
        return generation
    }

    public func approveLocallyAndStage(
        review approvedReview: NativeShellPackageReview,
        openWhenReady: Bool = false
    ) {
        guard !isInstalling, review?.reviewToken == approvedReview.reviewToken,
              review?.packageSHA256 == approvedReview.packageSHA256,
              let retryBytes = visibleReviewPackageBytes else { return }
        guard !openWhenReady || requireDownloadedContentRuntime() else { return }
        isInstalling = true
        let sourceSlug = reviewSourceSlug
        recordUsage(.reviewOutcome(.success), binding: reviewUsageBinding)
        reviewUsageBinding = nil
        let retry: RetryAction = visibleWebsitePackage.map(RetryAction.reopenWebsiteReview) ?? .reopenReview(retryBytes)
        let generation = presentationGeneration.advance()
        review = nil
        visibleReviewPackageBytes = nil
        visibleWebsitePackage = nil
        reviewSourceSlug = nil
        errorMessage = nil
        retryAction = nil
        Task {
            defer { isInstalling = false }
            var binding: NativeUsageBinding?
            var didAttemptStaging = false
            var didStage = false
            var didActivate = false
            do {
                if openWhenReady,
                   let current = try await coordinator.libraryEntry(identity: approvedReview.identity),
                   current.currentRevisionId == approvedReview.revisionId {
                    guard presentationGeneration.isCurrent(generation) else { return }
                    // Re-importing an already installed first revision is an
                    // open request, not a new update with a missing base. Keep
                    // all base checks in the actual staging path unchanged.
                    await coordinator.cancelReview(reviewToken: approvedReview.reviewToken)
                    guard presentationGeneration.isCurrent(generation) else { return }
                    let openBinding = beginUsage(.openRequest, identity: approvedReview.identity)
                    let outcome: NativeShellLaunchOutcome
                    do {
                        outcome = try await coordinator.launchActive(identity: approvedReview.identity)
                        guard outcome.identity == approvedReview.identity,
                              outcome.launchedRevisionId == approvedReview.revisionId else {
                            throw NativeWebsiteInstallFlowError.publishedRevisionMismatch(
                                expected: approvedReview.revisionId,
                                actual: outcome.launchedRevisionId
                            )
                        }
                    } catch {
                        recordUsage(.openLoadEnded(.failure), binding: openBinding)
                        throw error
                    }
                    guard presentationGeneration.isCurrent(generation) else { return }
                    presentLaunchAfterReviewCloses(
                        outcome,
                        displayName: current.displayName,
                        sourceSlug: sourceSlug,
                        binding: openBinding
                    )
                    if let refreshed = try? await coordinator.refreshLibrary(),
                       presentationGeneration.isCurrent(generation) {
                        library = refreshed
                    }
                    return
                }
                guard presentationGeneration.isCurrent(generation) else { return }
                binding = beginUsage(.stageAttempt, identity: approvedReview.identity)
                didAttemptStaging = true
                let staged = try await coordinator.approvePendingReviewLocallyAndStage(
                    reviewToken: approvedReview.reviewToken,
                    packageSHA256: approvedReview.packageSHA256
                )
                didStage = true
                recordUsage(.stageOutcome(.success), binding: binding)
                if openWhenReady {
                    guard presentationGeneration.isCurrent(generation) else { return }
                    recordUsage(.activateAttempt, binding: binding)
                    try await coordinator.activate(identity: staged.identity, revisionId: staged.revisionId)
                    didActivate = true
                    recordUsage(.activateOutcome(.success), binding: binding)
                    guard presentationGeneration.isCurrent(generation) else { return }
                    // Retain the approved API-setup capability before Core's
                    // post-activation launch recheck. A transient read failure
                    // there must not turn Retry into an ordinary unconfigured
                    // open or require restaging an already-installed revision.
                    pendingApprovedAPISetup = (staged.identity, staged.revisionId, UUID())
                    let openBinding = beginUsage(.openRequest, identity: staged.identity)
                    let outcome: NativeShellLaunchOutcome
                    do {
                        outcome = try await coordinator.launchActive(identity: staged.identity)
                    } catch {
                        recordUsage(.openLoadEnded(.failure), binding: openBinding)
                        throw error
                    }
                    guard presentationGeneration.isCurrent(generation) else { return }
                    presentLaunchAfterReviewCloses(
                        outcome,
                        displayName: approvedReview.displayName,
                        sourceSlug: sourceSlug,
                        binding: openBinding,
                        approvedAPIRevisionId: staged.revisionId
                    )
                    // The verified launch is already ready. A failure while
                    // refreshing another library entry must not turn that fact
                    // into a false opening failure or discard the waiting app.
                    if let refreshed = try? await coordinator.refreshLibrary(),
                       presentationGeneration.isCurrent(generation) {
                        library = refreshed
                    }
                    return
                }
                let refreshed = try await coordinator.refreshLibrary()
                guard presentationGeneration.isCurrent(generation) else { return }
                if !openWhenReady {
                    notice = staged.alreadyStaged
                        ? "This exact verified revision was already staged."
                        : "Revision staged. Activation is a separate action."
                }
                library = refreshed
            } catch {
                if didAttemptStaging, !didStage { recordUsage(.stageOutcome(.failure), binding: binding) }
                if didStage, openWhenReady, !didActivate {
                    recordUsage(.activateOutcome(.failure), binding: binding)
                }
                guard presentationGeneration.isCurrent(generation) else { return }
                if didActivate {
                    errorMessage = "The app was installed, but it could not finish opening. Its saved data was not reset."
                    retryAction = .open(approvedReview.identity)
                } else if didStage, openWhenReady {
                    errorMessage = "The verified download is ready, but Iris could not confirm which version is current. Retry to recheck the installation without resetting saved data."
                    retryAction = retry
                } else {
                    present(error: error, retry: retry)
                }
            }
        }
    }

    public func approveLocallyAndOpen(review: NativeShellPackageReview) {
        approveLocallyAndStage(review: review, openWhenReady: true)
    }

    private func presentLaunchAfterReviewCloses(
        _ outcome: NativeShellLaunchOutcome,
        displayName: String,
        sourceSlug: String?,
        binding: NativeUsageBinding?,
        approvedAPIRevisionId: String? = nil
    ) {
        // A small verified package can finish before the approval sheet has
        // really dismissed. Both new installs and existing opens share this gate.
        if reviewPresentationActive {
            launchWaitingForReviewDismissal = (outcome, displayName, sourceSlug, binding, approvedAPIRevisionId)
        } else {
            presentLaunch(outcome, displayName: displayName, sourceSlug: sourceSlug, binding: binding, approvedAPIRevisionId: approvedAPIRevisionId)
        }
    }

    public func reviewSheetDidClose() {
        reviewPresentationActive = false
        guard let waiting = launchWaitingForReviewDismissal else { return }
        launchWaitingForReviewDismissal = nil
        presentLaunch(
            waiting.outcome,
            displayName: waiting.displayName,
            sourceSlug: waiting.sourceSlug,
            binding: waiting.binding,
            approvedAPIRevisionId: waiting.approvedAPIRevisionId
        )
    }

    /// Invalidates only legacy in-flight work before a direct website flow takes
    /// over. Awaiting the actor reservation prevents a late invalidation from
    /// clearing that flow's eventual, explicitly approved package review.
    public func prepareForDirectWebsiteIntent() async -> Bool {
        guard !hasBlockingPresentation, review == nil else { return false }
        guard requireDownloadedContentRuntime() else { return false }
        let generation = beginIncomingPackage()
        await coordinator.supersedePendingReview(clientReviewSequence: generation)
        return presentationGeneration.isCurrent(generation) && !hasBlockingPresentation
    }

    public func adoptVerifiedWebsiteLaunch(_ result: NativeWebsiteInstallResult) {
        guard !hasBlockingPresentation, review == nil else { return }
        guard requireDownloadedContentRuntime() else { return }
        let generation = presentationGeneration.advance()
        notice = nil
        errorMessage = nil
        retryAction = nil
        let binding = beginUsage(.openRequest, identity: result.identity)
        let approvedAPIRevisionId: String?
        switch result.source {
        case .installed: approvedAPIRevisionId = result.revisionId
        case .alreadyInstalled: approvedAPIRevisionId = nil
        }
        presentLaunch(
            result.launch,
            displayName: result.displayName,
            sourceSlug: result.slug,
            binding: binding,
            approvedAPIRevisionId: approvedAPIRevisionId
        )
        Task {
            if let refreshed = try? await coordinator.refreshLibrary(),
               presentationGeneration.isCurrent(generation) {
                library = refreshed
            }
        }
    }

    private func presentLaunch(
        _ outcome: NativeShellLaunchOutcome,
        displayName: String,
        sourceSlug: String?,
        binding: NativeUsageBinding?,
        approvedAPIRevisionId: String? = nil,
        retryAPISetupID: UUID? = nil
    ) {
        guard !launchPresentationActive else { return }
        guard requireDownloadedContentRuntime() else {
            recordUsage(.openLoadEnded(.rejected), binding: binding)
            return
        }
        let approvedInstall = approvedAPIRevisionId == outcome.launchedRevisionId && !outcome.didFallback
        if approvedInstall {
            pendingApprovedAPISetup = (outcome.identity, outcome.launchedRevisionId, UUID())
        }
        let exactPending = pendingApprovedAPISetup?.identity == outcome.identity
            && pendingApprovedAPISetup?.revisionId == outcome.launchedRevisionId
        let explicitRetry = retryAPISetupID != nil && pendingApprovedAPISetup?.retryID == retryAPISetupID
        let mayPrepareAPI = exactPending && (approvedInstall || explicitRetry)
        if retryAPISetupID != nil, !mayPrepareAPI { pendingApprovedAPISetup = nil }
        do {
            // This is the model's verified-open boundary, not SwiftUI rendering.
            // A Host can persist an already-fetched/signed API package here at
            // the same approved Install & Open, and reopen from its exact binding.
            // Ordinary Open/restart/fallback is resolver-only. It cannot silently
            // add an API to a revision that was previously installed without one.
            // Retry may finish only the exact failed, explicitly approved setup.
            if mayPrepareAPI { try preparePackagedAPIForLaunch(outcome.launch) }
            let adapter = packagedAPIAdapterForLaunch(outcome.launch)
            try IrisPackagedAPIHostScripts.validateScope(adapter, for: outcome.launch)
            launchPackagedAPIAdapter = adapter
            if mayPrepareAPI { pendingApprovedAPISetup = nil }
        } catch {
            launchPackagedAPIAdapter = .notConfigured
            recordUsage(.openLoadEnded(.failure), binding: binding)
            errorMessage = "The app is installed, but its packaged API could not be prepared. Iris has not opened it or reset its saved data."
            retryAction = .open(outcome.identity)
            notice = nil
            return
        }
        launchLoadResult = nil
        launchUsageBinding = binding
        launchPresentationActive = true
        launchDisplayName = displayName
        launchSourceSlug = sourceSlug
        launchPresentationID = UUID()
        launch = outcome
        if outcome.didFallback {
            notice = "The current revision failed its launch recheck. Iris selected the last verified fallback for opening."
        }
    }

    public func activate(identity: NativeShellAppIdentity, revisionId: String) {
        pendingApprovedAPISetup = nil
        let generation = presentationGeneration.advance()
        let binding = beginUsage(.activateAttempt, identity: identity)
        errorMessage = nil
        retryAction = nil
        Task {
            var didActivate = false
            do {
                try await coordinator.activate(identity: identity, revisionId: revisionId)
                didActivate = true
                recordUsage(.activateOutcome(.success), binding: binding)
                let refreshed = try await coordinator.refreshLibrary()
                guard presentationGeneration.isCurrent(generation) else { return }
                notice = "Revision activated. Its explicitly approved capabilities apply when opened."
                library = refreshed
            } catch {
                if !didActivate { recordUsage(.activateOutcome(.failure), binding: binding) }
                guard presentationGeneration.isCurrent(generation) else { return }
                present(error: error, retry: .activate(identity, revisionId))
            }
        }
    }

    public func revert(identity: NativeShellAppIdentity, revisionId: String) {
        pendingApprovedAPISetup = nil
        run(
            retry: .revert(identity, revisionId),
            operation: {
                try await self.coordinator.revert(identity: identity, to: revisionId)
                return try await self.coordinator.refreshLibrary()
            },
            publish: {
                self.notice = "Switched to the selected verified version. Saved data was not reset; compatibility with that version is not guaranteed."
                self.library = $0
            }
        )
    }

    public func open(identity: NativeShellAppIdentity) {
        pendingApprovedAPISetup = nil
        open(identity: identity, retryAPISetupID: nil)
    }

    private func open(identity: NativeShellAppIdentity, retryAPISetupID: UUID?) {
        guard !launchPresentationActive, !isInstalling else { return }
        guard requireDownloadedContentRuntime() else { return }
        let binding = beginUsage(.openRequest, identity: identity)
        run(
            retry: .open(identity),
            operation: {
                let outcome = try await self.coordinator.launchActive(identity: identity)
                var refreshed: [NativeShellLibraryEntry]?
                var historyRefreshFailed = false
                if outcome.didFallback {
                    // Core has independently verified the fallback and changed
                    // only its active pointer. The bad former revision can still
                    // make a full history refresh fail; that must not prevent
                    // the verified fallback's own API/open checks from running.
                    do { refreshed = try await self.coordinator.refreshLibrary() }
                    catch { historyRefreshFailed = true }
                }
                return (outcome, refreshed, historyRefreshFailed)
            },
            publish: { result in
                let (outcome, refreshed, historyRefreshFailed) = result
                self.presentLaunch(
                    outcome,
                    displayName: self.library.first { $0.identity == identity }?.displayName ?? "App",
                    sourceSlug: nil,
                    binding: binding,
                    retryAPISetupID: retryAPISetupID
                )
                if outcome.didFallback {
                    if let refreshed { self.library = refreshed }
                    // API rejection above deliberately publishes no app. Do not
                    // overwrite that failure with an unconditional open-success
                    // message merely because Core selected a fallback pointer.
                    if self.launch?.id == outcome.id, historyRefreshFailed {
                        self.notice = "Iris selected the last verified fallback for opening, but stored version history could not be fully verified. The history list may be out of date. No version was deleted."
                    }
                }
            },
            onFailure: { self.recordUsage(.openLoadEnded(.rejected), binding: binding) }
        )
    }

    public func receivedWebLoadResult(
        _ result: NativeShellWebLoadResult,
        launchID: String,
        presentationID: UUID? = nil
    ) {
        guard launch?.id == launchID,
              presentationID == nil || presentationID == launchPresentationID else { return }
        switch (launchLoadResult, result) {
        case (nil, .loaded):
            launchLoadResult = .loaded
            recordUsage(.openLoaded, binding: launchUsageBinding)
        case (nil, .failed):
            launchLoadResult = .failed
            recordUsage(.openLoadEnded(.failure), binding: launchUsageBinding)
        case (.loaded?, .failed):
            // The initial open already completed and was counted once. A later
            // WebContent-process death is a runtime UI failure transition, not a
            // second outcome for the original open attempt.
            launchLoadResult = .failed
        default:
            // Duplicate initial callbacks, duplicate runtime failures and any
            // impossible failed->loaded replay are ignored.
            return
        }
    }

    public func closeApp() {
        guard launchPresentationActive, launch != nil else { return }
        recordUsage(.closeAttempt, binding: launchUsageBinding)
        if launchLoadResult == nil {
            recordUsage(.openLoadEnded(.cancelled), binding: launchUsageBinding)
            launchLoadResult = .failed
        }
        launch = nil
    }

    public func appSheetDidClose() {
        guard launchPresentationActive else { return }
        if launchLoadResult == nil {
            recordUsage(.openLoadEnded(.cancelled), binding: launchUsageBinding)
        }
        recordUsage(.closeOutcome(.success), binding: launchUsageBinding)
        launchUsageBinding = nil
        launchLoadResult = nil
        launchPresentationActive = false
        launchSourceSlug = nil
        launchPackagedAPIAdapter = .notConfigured
    }

    // Bind consent when the operation starts. Never reacquire a newer consent
    // epoch merely because an old asynchronous operation finishes later.
    func beginUsage(_ event: NativeUsageEvent, identity: NativeShellAppIdentity? = nil) -> NativeUsageBinding? {
        guard let usageService,
              let localIdentity = try? NativeUsageIdentity(
                appId: identity?.appId ?? "iris.mobile-shell",
                projectId: identity?.projectId ?? "iris.mobile-shell.host"
              ),
              let binding = usageService.binding(for: localIdentity) else { return nil }
        recordUsage(event, binding: binding)
        return binding
    }

    func recordUsage(_ event: NativeUsageEvent, binding: NativeUsageBinding?) {
        guard let usageService, let binding else { return }
        _ = usageService.record(event, binding: binding)
    }

    public func retry() {
        guard let retryAction else { return }
        switch retryAction {
        case .refresh: refresh()
        case .open(let identity):
            let retryID = pendingApprovedAPISetup?.identity == identity ? pendingApprovedAPISetup?.retryID : nil
            open(identity: identity, retryAPISetupID: retryID)
        case .reopenReview(let packageBytes): presentReview(packageBytes: packageBytes)
        case .reopenWebsiteReview(let package):
            presentReview(packageBytes: package.packageBytes, websitePackage: package)
        case .activate(let identity, let revisionId): activate(identity: identity, revisionId: revisionId)
        case .revert(let identity, let revisionId): revert(identity: identity, revisionId: revisionId)
        }
    }

    private func presentReview(
        packageBytes: Data,
        websitePackage: PublikMobileDownloadedPackage? = nil,
        usingGeneration: UInt64? = nil
    ) {
        guard !isInstalling else { return }
        let generation = usingGeneration ?? beginIncomingPackage()
        guard presentationGeneration.isCurrent(generation) else { return }
        let binding = beginUsage(.reviewAttempt, identity: websitePackage?.identity)
        reviewUsageBinding = binding
        Task {
            do {
                guard presentationGeneration.isCurrent(generation), !Task.isCancelled else { return }
                let reviewed = try await coordinator.reviewImport(
                    packageBytes: packageBytes,
                    expectedIdentity: websitePackage?.identity,
                    clientReviewSequence: generation
                )
                guard presentationGeneration.isCurrent(generation), !Task.isCancelled else {
                    await coordinator.cancelReview(reviewToken: reviewed.reviewToken)
                    return
                }
                visibleReviewPackageBytes = packageBytes
                visibleWebsitePackage = websitePackage
                reviewSourceSlug = websitePackage?.catalogSlug
                reviewPresentationActive = true
                review = reviewed
            } catch {
                guard presentationGeneration.isCurrent(generation) else { return }
                recordUsage(.reviewOutcome(.failure), binding: binding)
                reviewUsageBinding = nil
                present(error: error, retry: nil)
            }
        }
    }

    private func run<Value>(
        retry: RetryAction?,
        operation: @escaping @MainActor () async throws -> Value,
        publish: @escaping @MainActor (Value) -> Void,
        onFailure: (@MainActor () -> Void)? = nil
    ) {
        let generation = presentationGeneration.advance()
        errorMessage = nil
        retryAction = nil
        Task {
            do {
                let value = try await operation()
                guard presentationGeneration.isCurrent(generation) else { return }
                publish(value)
            } catch {
                guard presentationGeneration.isCurrent(generation) else { return }
                onFailure?()
                present(error: error, retry: retry)
            }
        }
    }

    nonisolated private static func readBoundedPackageBytes(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true else {
                throw NativeShellError.invalidPackageJSON
            }
            if let fileSize = resourceValues.fileSize,
               fileSize > DeliveryPackageV1Validator.maximumRawPackageBytes {
                throw NativeShellError.packageTooLarge
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = DeliveryPackageV1Validator.maximumRawPackageBytes
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw NativeShellError.packageTooLarge }
            return data
        }.value
    }

    private func present(error: Error, retry: RetryAction?) {
        errorMessage = String(describing: error)
        retryAction = retry
    }
}

public struct NativeShellAppView: View {
    private let catalogSourceLabel: String
    private let coordinator: NativeShellLibraryCoordinator
    private let permissionStore: NativePermissionStore?
    /// M-store-screens INTEGRATION_HOOKS.md Hook 3: the fixture-namespaced
    /// suite the Storage screen must read its cap from during a UI-test
    /// fixture launch; `.standard` on every ordinary launch.
    private let storeDefaults: UserDefaults
    @StateObject private var model: NativeShellAppModel
    @StateObject private var catalog: NativeShellCatalogModel
    @StateObject private var usage: NativeShellUsageModel
    @StateObject private var website: NativeShellWebsiteInstallModel
    @StateObject private var store: StoreModel
    /// MA2 hook 1: the person's folders, own names and recents, kept in the
    /// same namespace root as the library (a fixture launch gets its own).
    @StateObject private var myAppsOrganization: MyAppsOrganizationStore
    /// Owned by the App (see `IrisMobileShellApp`), not by this view: it is
    /// observed here, never created here, so its lifetime spans the whole
    /// first-launch install rather than resetting if this view is rebuilt.
    @ObservedObject private var starterSetupStatus: NativeStarterSetupStatus
    private var selectedTab: StoreTab {
        get { store.navigation.tab }
        nonmutating set { store.perform(.selectTab(newValue)) }
    }
    @State private var searchText = ""
    @State private var navigationPath: [NativeMarketplaceDestination] = []
    @State private var starterSetupWasRunning = false

    public init(
        coordinator: NativeShellLibraryCoordinator,
        bundledDemoPackage: Data? = nil,
        bundledDemoUpdatePackage: Data? = nil,
        usageService: NativeUsageService? = nil,
        bundledStorageCheckPackage: Data? = nil,
        capabilityPolicy: CapabilityPolicy = NativeWebStorageConfiguration.capabilityPolicy,
        catalogClient: PublikMobileCatalogClient = .init(),
        catalogSourceLabel: String = "From Publik · verified download",
        review47BlockList: Review47BlockList? = Review47BlockList(store: UserDefaultsReview47BlockListStore()),
        review47AgeGate: Review47AgeGate? = nil,
        packagedAPIAdapterForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) -> IrisPackagedAPIAdapterConfiguration = { _ in .notConfigured },
        preparePackagedAPIForLaunch: @escaping @MainActor (VerifiedLaunchDescriptor) throws -> Void = { _ in },
        permissionStore: NativePermissionStore? = nil,
        starterSetupStatus: NativeStarterSetupStatus,
        catalogCacheDirectory: URL? = nil,
        storeDefaults: UserDefaults = .standard
    ) {
        self.catalogSourceLabel = catalogSourceLabel
        self.coordinator = coordinator
        self.permissionStore = permissionStore
        self.starterSetupStatus = starterSetupStatus
        self.storeDefaults = storeDefaults
        // RC-02: the age declaration lives in the same defaults suite as the
        // rest of the store's local state, so a UI-test fixture launch never
        // inherits (or leaks) a declared age from another run.
        let review47AgeGate = review47AgeGate ?? Review47AgeGate(store: UserDefaultsReview47AgeStore(defaults: storeDefaults))
        let appModel = NativeShellAppModel(
            coordinator: coordinator,
            bundledDemoPackage: bundledDemoPackage,
            bundledDemoUpdatePackage: bundledDemoUpdatePackage,
            usageService: usageService,
            bundledStorageCheckPackage: bundledStorageCheckPackage,
            preparePackagedAPIForLaunch: preparePackagedAPIForLaunch,
            packagedAPIAdapterForLaunch: packagedAPIAdapterForLaunch
        )
        _model = StateObject(wrappedValue: appModel)
        _catalog = StateObject(wrappedValue: NativeShellCatalogModel(
            importer: appModel,
            client: catalogClient,
            review47BlockList: review47BlockList,
            review47AgeGate: review47AgeGate
        ))
        _usage = StateObject(wrappedValue: NativeShellUsageModel(service: usageService))
        _myAppsOrganization = StateObject(wrappedValue: (try? MyAppsOrganizationStore(root: coordinator.namespaceRootURL, defaults: storeDefaults)) ?? .fallback())
        _website = StateObject(wrappedValue: NativeShellWebsiteInstallModel(
            coordinator: coordinator,
            client: catalogClient,
            capabilityPolicy: capabilityPolicy,
            usageService: usageService,
            review47BlockList: review47BlockList,
            review47AgeGate: review47AgeGate,
            canPresent: { [weak appModel] in
                guard let appModel else { return false }
                return !appModel.hasBlockingPresentation && appModel.review == nil
            },
            prepareHost: { [weak appModel] in
                guard let appModel else { return false }
                return await appModel.prepareForDirectWebsiteIntent()
            }
        ))
        _store = StateObject(wrappedValue: Self.makeStore(
            appModel: appModel,
            coordinator: coordinator,
            catalogClient: catalogClient,
            capabilityPolicy: capabilityPolicy,
            usageService: usageService,
            review47BlockList: review47BlockList,
            review47AgeGate: review47AgeGate,
            catalogCache: catalogCacheDirectory.map { PublikMobileCatalogCache(directory: $0) }
                ?? (try? PublikMobileCatalogCache.inAppContainer())
        ))
    }

    /// One-tap Get runs the same verified flow a publikhq.com link runs; the
    /// tap on Get is the local approval (design 6.3). Nothing opens by itself.
    private static func makeStore(
        appModel: NativeShellAppModel,
        coordinator: NativeShellLibraryCoordinator,
        catalogClient: PublikMobileCatalogClient,
        capabilityPolicy: CapabilityPolicy,
        usageService: NativeUsageService?,
        review47BlockList: Review47BlockList?,
        review47AgeGate: Review47AgeGate?,
        catalogCache: PublikMobileCatalogCache?
    ) -> StoreModel {
        let pipeline = StoreFlowInstallPipeline(
            makeFlow: {
                NativeWebsiteInstallFlow(
                    coordinator: coordinator,
                    catalogClient: catalogClient,
                    capabilityPolicy: capabilityPolicy,
                    usageService: usageService,
                    review47BlockList: review47BlockList,
                    review47AgeGate: review47AgeGate,
                    preferCatalogV2: true
                )
            },
            prepareHost: { [weak appModel] in
                guard let appModel else { return false }
                return await appModel.prepareForDirectWebsiteIntent()
            }
        )
        return StoreModel(
            client: catalogClient,
            cache: catalogCache,
            pipeline: pipeline,
            blockList: review47BlockList,
            ageGate: review47AgeGate,
            openApp: { [weak appModel] identity in appModel?.open(identity: identity) },
            refreshLibrary: { [weak appModel] in appModel?.refresh() },
            catalogCheckStarted: { [weak appModel] in
                // Same local usage record the v1 Browse list kept (Privacy page).
                let binding = appModel?.beginUsage(.catalogLoadAttempt)
                return { [weak appModel] succeeded in
                    appModel?.recordUsage(.catalogLoadOutcome(succeeded ? .success : .failure), binding: binding)
                }
            },
            // R6 hook H2 (RC-11): a real Get for a removed starter app.
            seedReinstaller: NativeStarterBundleReader.reinstaller(coordinator: coordinator)
        )
    }

    public var body: some View {
        storeRoot
            .disabled(website.isPresented || website.isCommitting || model.isInstalling)
            .fileImporter(
                isPresented: $model.importPickerIsPresented,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.reviewImportedFile(url)
                }
            }
            .fullScreenCover(item: $model.launch, onDismiss: {
                model.appSheetDidClose()
                usage.refresh()
                store.perform(.appClosed)
                navigationPath.removeAll()
                // A link received while the reader was working waits until the
                // full-screen app has actually closed, not merely until launch is nil.
                // It then lands on that app's page (after `.appClosed`, so the
                // page wins over My apps; CLICK-PATH-005).
                continueDeferredLink()
            }) { outcome in
                fullscreenAppView(outcome: outcome)
            }
            .sheet(
                isPresented: Binding(
                    get: { model.review != nil },
                    set: { if !$0 { model.cancelReview() } }
                ),
                onDismiss: {
                    model.reviewSheetDidClose()
                    if !model.hasBlockingPresentation { continueDeferredLink() }
                }
            ) {
                if let review = model.review {
                    reviewSheet(review)
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { website.isPresented },
                    set: { website.setPresentation($0) }
                ),
                onDismiss: {
                    if let result = website.presentationWasDismissed() {
                        model.adoptVerifiedWebsiteLaunch(result)
                    }
                    // A queued link is NOT opened here: a successful install
                    // is now opening its app. That app owns its next dismissal.
                }
            ) {
                NativeShellWebsiteInstallView(model: website, sourceLabel: catalogSourceLabel)
            }
        .tint(NativeMarketplaceStyle.electric)
        .task { await onAppear() }
        .onChange(of: starterSetupStatus.snapshot) { snapshot in
            // Refresh exactly on the transition from "something is still
            // being set up" to "nothing is": that is the moment newly
            // installed starter apps exist to show, with no relaunch. A
            // launch with nothing to install never runs `.running`, so it
            // never triggers this extra refresh either.
            if starterSetupWasRunning, snapshot.runningAppNames.isEmpty {
                model.refresh()
            }
            starterSetupWasRunning = !snapshot.runningAppNames.isEmpty
        }
        .onOpenURL(perform: receiveWebsiteURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { receiveWebsiteURL(url) }
        }
        .onChange(of: store.freshness) { _ in usage.refresh() }
        .onChange(of: model.notice) { _ in usage.refresh() }
    }

    private var installedDisplayNames: MyAppsDisplayNames {
        MyAppsAdapter.displayNames(
            library: model.library,
            store: store,
            arrangement: myAppsOrganization.arrangement,
            starterNames: store.starterDisplayNames
        )
    }

    private var storeRoot: some View {
        StoreTabView(
            store: store,
            myAppsPath: $navigationPath,
            library: model.library,
            status: { marketplaceStatus },
            myApps: { myAppsScreen },
            myAppsDestination: { destination in myAppsDestination(destination) },
            displayNames: { installedDisplayNames }
        )
    }

    /// unit M-store-screens (round3-deferred/M-store-screens): the
    /// standalone My apps screen (`StoreMyAppsView`, owned Store/** file)
    /// replaces the old inline `myAppsContent` grid. This is a routing
    /// change only, per this unit's brief -- `appDetails(identity:)` below
    /// (today's combined Versions/Permissions/Storage list) is unchanged
    /// and stays the navigation target every entry point here reaches, per
    /// INTEGRATION_HOOKS.md.
    private var myAppsScreen: some View {
        StoreMyAppsView(
            store: store,
            library: model.library,
            myAppsStore: myAppsOrganization,
            blockedCount: store.blockedAppIDs.count,
            hasBundledDemo: model.hasBundledDemo,
            hasBundledDemoUpdate: model.canReviewBundledDemoUpdate,
            hasBundledStorageCheck: model.hasBundledStorageCheck,
            importPickerRequested: { model.importPickerIsPresented = true },
            refreshLibrary: { model.refresh() },
            reviewBundledDemo: { model.reviewBundledDemo() },
            reviewBundledDemoUpdate: { model.reviewBundledDemoUpdate() },
            reviewBundledStorageCheck: { model.reviewBundledStorageCheck() },
            open: { identity in model.open(identity: identity) },
            openDetails: { identity in navigationPath.append(.app(identity)) },
            openFeatures: { identity in navigationPath.append(.features(identity)) },
            removeApp: { identity, deleteData in
                try await model.removeApp(identity: identity, alsoDeleteData: deleteData, permissionStore: permissionStore)
                if deleteData { _ = myAppsOrganization.apply(.forgetApp(identity: identity.id)) }
            },
            browse: { store.perform(.selectTab(.browse)) },
            searchStore: { query in
                store.perform(.selectTab(.search))
                store.searchText = query
            },
            storageDestination: {
                StoreStorageView(
                    coordinator: coordinator,
                    defaults: storeDefaults,
                    library: model.library,
                    displayNames: installedDisplayNames,
                    openVersions: { identity in navigationPath.append(.features(identity)) }
                )
            },
            blockedDestination: { StoreBlockedAppsView(store: store, library: model.library, displayNames: installedDisplayNames) },
            privacyLink: AnyView(privacyLink)
        )
    }

    @ViewBuilder private func myAppsDestination(_ destination: NativeMarketplaceDestination) -> some View {
        switch destination {
        case .app(let identity): appDetails(identity: identity)
        case .features(let identity):
            StoreVersionsView(
                coordinator: coordinator,
                identity: identity,
                appName: featuresName(for: identity)
            )
        case .catalog(let slug):
            if let app = catalog.apps.first(where: { $0.slug == slug }) { catalogDetails(app) }
            else { Text("This catalogue entry is no longer available.") }
        case .privacy:
            List { NativeShellUsageSection(model: usage) }
                .navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar).task { usage.refresh() }
        }
    }

    @ViewBuilder private func fullscreenAppView(outcome: NativeShellLaunchOutcome) -> some View {
        let presentationID = model.launchPresentationID
        let packagedAPIAdapter = model.launchPackagedAPIAdapter
        NativeFullscreenAppView(
            launch: outcome.launch,
            adapter: packagedAPIAdapter,
            presentationID: presentationID,
            hasLoadFailure: model.launchLoadResult == .failed,
            onLoadResult: { result in
                model.receivedWebLoadResult(
                    result,
                    launchID: outcome.id,
                    presentationID: presentationID
                )
                // MA2 SPEC integration point 1: an app counts as opened only
                // once it actually finished loading, from any entry point.
                if result == .loaded { myAppsOrganization.recordOpened(identity: outcome.identity.id) }
            },
            onClose: {
                guard model.launch?.id == outcome.id,
                      model.launchPresentationID == presentationID else { return }
                model.closeApp()
            },
            permissionStore: permissionStore,
            displayName: installedDisplayNames.name(identity: outcome.identity.id, fallback: model.launchDisplayName),
            pendingRequest: { prepareClose in
                NativeDeferredWebsiteRequest(model: website) {
                    deferredWebsiteRequest(continueAction: prepareClose)
                        .padding().background(.bar)
                }
            }
        )
        .onOpenURL(perform: receiveWebsiteURL)
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { receiveWebsiteURL(url) }
        }
    }

    /// The same custom, catalog or starter name used by My apps, with the
    /// library's manifest name as the fallback.
    private func featuresName(for identity: NativeShellAppIdentity) -> String {
        let fallback = model.library.first { $0.identity == identity }?.displayName ?? "This app"
        return installedDisplayNames.name(identity: identity.id, fallback: fallback)
    }

    private func onAppear() async {
        model.refresh()
        // Browse's catalog is the store's own single check (StoreModel.start);
        // the v1 list is no longer loaded separately (CLICK-PATH-006).
        await catalog.review47Refresh()
    }

    /// A link that waited for an app, a review or an install to finish lands
    /// on that app's page in Browse (design 9.5). Nothing installs until Get.
    private func continueDeferredLink() {
        if let slug = website.takeDeferredRequestSlug() { store.openLink(slug: slug) }
    }

    @ViewBuilder private var marketplaceStatus: some View {
        if let message = model.downloadedContentRuntimeUnavailableMessage {
            Label(message, systemImage: "exclamationmark.shield").font(.footnote)
                .accessibilityIdentifier("iris.runtime.unavailable")
        }
        if website.deferredSlug != nil {
            deferredWebsiteRequest {
                if !model.hasBlockingPresentation { continueDeferredLink() }
            }
        }
        if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Action could not be completed", systemImage: "exclamationmark.triangle").font(.headline)
                Text(errorMessage).font(.footnote)
                if model.retryAction != nil { Button("Retry") { model.retry() } }
            }.padding(14).background(.white, in: RoundedRectangle(cornerRadius: 12))
        }
        if let notice = model.notice {
            Text(notice).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
        }
    }

    private var filteredLibrary: [NativeShellLibraryEntry] {
        let names = installedDisplayNames
        return model.library.filter {
            NativeMarketplaceSelection.matches(query: searchText, name: names.name(identity: $0.identity.id, fallback: $0.displayName), slug: $0.identity.appId)
        }
    }

    // RC-07 (apple-compliance/REQUIRED_CHANGES.md): this computed property is
    // dead in the running app (superseded by `myAppsScreen`/`StoreMyAppsView`
    // above; nothing else in this file or elsewhere references
    // `myAppsContent`, confirmed by grep), but its debug-only menu strings
    // (the local import, demo review and storage test entries) still
    // compiled straight into Release with no gate. The release hygiene
    // script flags those strings by name, so they are not repeated here.
    // Guideline 2.3/4.7: a reviewer must never see debug-only affordances.
    // Wrapped whole in `#if DEBUG` per this repo's "never delete code" rule
    // and RC-07's own instruction; nothing references it in Release, so no
    // replacement call site is needed.
#if DEBUG
    private var myAppsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("My apps").font(.system(size: 24, weight: .bold))
                Spacer()
                Menu {
                    Button("Import local package", systemImage: "square.and.arrow.down") {
                        model.importPickerIsPresented = true
                    }.accessibilityIdentifier("iris.import")
                    Button("Refresh library", systemImage: "arrow.clockwise") { model.refresh() }
                    if model.hasBundledDemo {
                        Button("Review demo") { model.reviewBundledDemo() }.accessibilityIdentifier("iris.demo.review-v1")
                    }
                    if model.canReviewBundledDemoUpdate {
                        Button("Review demo update") { model.reviewBundledDemoUpdate() }.accessibilityIdentifier("iris.demo.review-v2")
                    }
                    if model.hasBundledStorageCheck {
                        Button("Review storage test") { model.reviewBundledStorageCheck() }.accessibilityIdentifier("iris.storage-check.review")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("My apps actions")
            }
            Text("Your installed apps. Your data stays separate.")
                .font(.system(size: 14)).foregroundStyle(NativeMarketplaceStyle.fog)
            starterSetupBanner
            starterSetupFailureNotice

            if filteredLibrary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle)
                    Text(model.library.isEmpty ? "Make this space yours" : "No matching apps").font(.headline)
                    Text(model.library.isEmpty ? "Choose an app in Browse. Review its permissions once, then open it here." : "Try another name or clear the search.")
                        .font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog)
                    if model.library.isEmpty { Button("Browse apps") { selectedTab = .browse }.buttonStyle(NativeMarketplaceActionStyle()) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 16) {
                    ForEach(filteredLibrary) { entry in
                        NativeMarketplaceCard(key: NativeMarketplaceSelection.appearanceKey(appId: entry.identity.appId),
                                              name: featuresName(for: entry.identity),
                                              subtitle: "\(entry.revisions.count) stored version\(entry.revisions.count == 1 ? "" : "s")") {
                            HStack(spacing: 4) {
                                Button("Open") { model.open(identity: entry.identity) }
                                    .buttonStyle(NativeMarketplaceActionStyle())
                                    .disabled(entry.currentRevisionId == nil || model.downloadedContentRuntimeUnavailableMessage != nil)
                                    .accessibilityIdentifier("iris.open.\(entry.identity.appId)")
                                NavigationLink(value: NativeMarketplaceDestination.app(entry.identity)) {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Versions and details for \(featuresName(for: entry.identity))")
                                .accessibilityIdentifier("iris.versions.\(entry.identity.appId)")
                            }
                        }
                    }
                }
            }
            privacyLink
        }
    }
#endif

    /// Shown only while first-launch starter apps are still being set up,
    /// and only for the apps actually being installed right now (an already
    /// fully-installed launch never shows this at all). Disappears on its
    /// own the moment setup finishes, because `starterSetupStatus.snapshot`
    /// changing drives this view's re-render directly.
    @ViewBuilder private var starterSetupBanner: some View {
        let names = starterSetupStatus.snapshot.runningAppNames
        if !names.isEmpty {
            let message = "Setting up your apps: \(names.joined(separator: ", ")). This takes about a minute the first time."
            HStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text(message).font(.system(size: 14))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .accessibilityIdentifier("iris.starter.setting-up")
        }
    }

    /// One plain-language line naming any starter app that could not be set
    /// up. The other apps still show normally in the grid below; this is
    /// purely informational and never blocks anything.
    @ViewBuilder private var starterSetupFailureNotice: some View {
        let names = starterSetupStatus.snapshot.failedAppNames
        if !names.isEmpty {
            let message = "\(names.joined(separator: ", ")) could not be set up. Your other apps are ready."
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(NativeMarketplaceStyle.fog)
                .accessibilityIdentifier("iris.starter.setup-failed")
        }
    }

    private var privacyLink: some View {
        NavigationLink(value: NativeMarketplaceDestination.privacy) {
            Label("Privacy & local usage", systemImage: "hand.raised")
                .font(.system(size: 14)).frame(minHeight: 44)
        }.accessibilityIdentifier("iris.privacy.open")
    }

    @ViewBuilder private func permissionsSection(
        identity: NativeShellAppIdentity,
        entry: NativeShellLibraryEntry
    ) -> some View {
        Section("Permissions") {
            if let revision = entry.revisions.first(where: { $0.revisionId == entry.currentRevisionId }) {
                NativeCapabilityDisclosure(capabilities: revision.requestedCapabilities)
                if let permissionStore {
                    NativePermissionsSection(
                        identity: identity,
                        requestedCapabilities: revision.requestedCapabilities,
                        store: permissionStore
                    )
                }
            }
        }
    }

    @ViewBuilder private func appDetails(identity: NativeShellAppIdentity) -> some View {
        List {
            if let entry = model.library.first(where: { $0.identity == identity }) {
                Section(featuresName(for: entry.identity)) {
                    Button("Open") { model.open(identity: identity) }
                        .accessibilityIdentifier("iris.open.\(identity.appId)")
                        .disabled(entry.currentRevisionId == nil || model.downloadedContentRuntimeUnavailableMessage != nil)
                    Button("Versions") { navigationPath.append(.features(identity)) }
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.AppPage.versionsRow)
                }
                permissionsSection(identity: identity, entry: entry)
                NativeStorageAppUsageContainer(coordinator: coordinator, identity: identity)
                if let listed = store.listedUpdate(for: entry) {
                    Section {
                        Button(listed.descriptor.baseRevisionId == entry.currentRevisionId ? "Review listed update" : "Check listed version") { openListing(slug: listed.slug) }
                        Text("Your existing app stays selected until you approve the verified update.").font(.footnote)
                    }
                }
            } else { Text("This app is no longer in the library.") }
        }
        .navigationTitle(featuresName(for: identity)).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func catalogDetails(_ app: PublikMobileCatalogApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                NativeMarketplaceArtwork(key: app.slug, name: app.name).frame(height: 210)
                Text(app.name).font(.largeTitle.bold())
                Text("Listed on Publik").font(.headline)
                Text("The public catalogue does not yet include an installable mobile-shell package for this app. A source repository or website listing is not an Iris installation.")
                    .foregroundStyle(NativeMarketplaceStyle.fog)
                Text("There is nothing to approve or download here yet. Your installed apps remain available in My apps.").font(.callout)
            }.padding(20)
        }
        .background(NativeMarketplaceStyle.paper)
        .navigationTitle(app.name).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    /// Same path as a publikhq.com link: the app page in Browse when nothing
    /// is open, otherwise the existing waiting banner.
    private func openListing(slug: String) {
        guard let url = URL(string: "https://publikhq.com/iris/apps/" + slug) else { return }
        receiveWebsiteURL(url)
    }

    private func receiveWebsiteURL(_ url: URL) {
        guard let intent = try? NativeWebsiteInstallIntent.parse(url) else {
            website.receive(url, deferUntilCurrentAppCloses: model.hasBlockingPresentation)
            return
        }
        if model.launch != nil, model.launchSourceSlug == intent.slug {
            // The chosen app is already on screen. Do not reload its document
            // or lose unsaved state simply because the same link arrived twice.
            website.dismissDeferredRequest()
            return
        }
        if model.hasBlockingPresentation || model.review != nil || website.isPresented || website.isCommitting {
            catalog.cancelDownload()
            website.receive(url, deferUntilCurrentAppCloses: model.hasBlockingPresentation)
            return
        }
        store.openLink(slug: intent.slug)
    }

    private func deferredWebsiteRequest(continueAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An app link from Publik is waiting.").font(.headline)
            Text("Finish your current work, then continue to the requested app.")
                .font(.footnote)
            HStack {
                Button("Stay here") { website.dismissDeferredRequest() }
                    .accessibilityIdentifier("iris.website.pending.dismiss")
                Spacer()
                Button("Continue") { continueAction() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("iris.website.pending.continue")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iris.website.pending")
    }

    @ViewBuilder
    private func appSection(_ entry: NativeShellLibraryEntry) -> some View {
        Section(featuresName(for: entry.identity)) {
            if entry.currentRevisionId != nil {
                Button("Open") { model.open(identity: entry.identity) }
                    .accessibilityIdentifier("iris.open.\(entry.identity.appId)")
                    .disabled(model.downloadedContentRuntimeUnavailableMessage != nil)
            } else {
                Text("No active version").foregroundStyle(.secondary)
            }
            DisclosureGroup("Versions and details") {
                LabeledContent("App", value: entry.identity.appId)
                LabeledContent("Project", value: entry.identity.projectId)
                if let current = entry.currentRevisionId {
                    LabeledContent("Current", value: shortRevision(current))
                }
                Text("These are verified stored app versions. Reverting changes the app code, not a backup of your data; older versions still need to understand your saved data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let contentBytes = entry.totalVersionContentBytes {
                    LabeledContent("Version content", value: ByteCountFormatter.string(fromByteCount: Int64(contentBytes), countStyle: .file))
                    Text("Logical app-file size across \(entry.revisions.count) versions. Iris reuses unchanged files with copy-on-write where supported, so this is not actual disk usage. App data and imported installer files are separate.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("iris.versions.storage-explanation")
                }
                ForEach(NativeRevisionHistoryRow.rows(for: entry)) { row in
                    let revision = row.revision
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.state.label).font(.subheadline.weight(.semibold))
                            Text(shortRevision(revision.revisionId)).font(.system(.body, design: .monospaced))
                            if let contentBytes = revision.contentBytes {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(contentBytes), countStyle: .file) + " app files")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Package created: " + String(revision.createdAt.prefix(10)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NativeStorageRevisionPinButton(
                            revisionId: revision.revisionId,
                            model: NativeStorageAppUsageModelCache.model(coordinator: coordinator, identity: entry.identity)
                        )
                        if row.canRevert {
                            Button(row.selectionActionLabel) {
                                model.revert(identity: entry.identity, revisionId: revision.revisionId)
                            }
                            .accessibilityIdentifier("iris.revert.\(revision.revisionId)")
                        } else if row.canActivate {
                            Button("Activate") {
                                model.activate(identity: entry.identity, revisionId: revision.revisionId)
                            }
                            .accessibilityIdentifier("iris.activate.\(revision.revisionId)")
                        }
                    }
                    // Two buttons in one List row: without borderless, a tap
                    // anywhere in the row fires both, so Pin would also revert
                    // (R2 click-path audit, R2-CP-4).
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func reviewSheet(_ review: NativeShellPackageReview) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(review.displayName).font(.title2.bold())
                    if let sourceSlug = model.reviewSourceSlug {
                        LabeledContent("Downloaded from", value: "publikhq.com · \(sourceSlug)")
                    } else {
                        Text("Verified local package").font(.subheadline).foregroundStyle(.secondary)
                    }
                    NativeCapabilityDisclosure(capabilities: review.requestedCapabilities)
                    if !review.unsupportedCapabilities.isEmpty {
                        Label("This app needs capabilities this Iris version does not support.", systemImage: "exclamationmark.shield")
                        Text(review.unsupportedCapabilities.joined(separator: ", ")).font(.footnote)
                    }
                }
                DisclosureGroup("Technical details") {
                    LabeledContent("App", value: review.identity.appId)
                    LabeledContent("Project", value: review.identity.projectId)
                    LabeledContent("Revision", value: shortRevision(review.revisionId))
                    LabeledContent("Base", value: review.baseRevisionId.map(shortRevision) ?? "First revision")
                    LabeledContent("Package hash", value: shortHash(review.packageSHA256))
                    LabeledContent("Content hash", value: shortHash(review.contentHash))
                    Text("Requested capabilities").font(.headline)
                    if review.requestedCapabilities.contains("web.storage") {
                        Text("Requested local app storage: this would allow data in an isolated browser-data profile, separate from other apps and optional usage records. It grants no network or native filesystem access and is not a backup or migration guarantee. An unsupported request remains blocked.")
                            .font(.footnote)
                            .accessibilityIdentifier("iris.review.web-storage")
                    }
                    if review.requestedCapabilities.isEmpty {
                        Text("None")
                    } else {
                        ForEach(review.requestedCapabilities, id: \.self) { Text($0) }
                    }
                    if !review.unsupportedCapabilities.isEmpty {
                        Text("Unsupported here: \(review.unsupportedCapabilities.joined(separator: ", "))")
                            .foregroundStyle(.red)
                    }
                    Text(review.localApprovalExplanation)
                    Text("Embedded approval id: \(review.embeddedApprovalId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = model.downloadedContentRuntimeUnavailableMessage {
                    Section("Runtime unavailable") {
                        Text(message)
                            .accessibilityIdentifier("iris.review.runtime-unavailable")
                    }
                }
            }
            .accessibilityIdentifier("iris.review.sheet")
            .navigationTitle(review.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Cancel", role: .cancel) { model.cancelReview() }
                        .accessibilityIdentifier("iris.review.cancel")
                    Spacer()
                    Button(review.baseRevisionId == nil ? "Install & Open" : "Update & Open") {
                        model.approveLocallyAndOpen(review: review)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!review.unsupportedCapabilities.isEmpty || model.downloadedContentRuntimeUnavailableMessage != nil)
                        .accessibilityIdentifier("iris.review.approve")
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private func shortRevision(_ value: String) -> String {
        String(value.suffix(12))
    }

    private func shortHash(_ value: String) -> String {
        String(value.suffix(16))
    }
}

/// A modal's captured content must observe the waiting request itself.
/// The presenting shell can refresh without recreating its fullscreen cover.
private struct NativeDeferredWebsiteRequest<Content: View>: View {
    @ObservedObject var model: NativeShellWebsiteInstallModel
    @ViewBuilder let content: () -> Content

    var body: some View {
        if model.deferredSlug != nil { content() }
    }
}
#endif
