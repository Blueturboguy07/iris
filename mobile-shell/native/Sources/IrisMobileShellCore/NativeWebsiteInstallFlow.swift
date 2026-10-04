import Foundation

public typealias NativeWebsiteInstallProgressHandler = @Sendable (NativeWebsiteInstallProgress) -> Void

public enum NativeWebsiteInstallProgress: Equatable, Sendable {
    case resolvingCatalog(slug: String)
    case checkingInstalled(slug: String)
    case downloading(slug: String, progress: PublikMobileDownloadProgress?)
    case verifying(slug: String)
    case awaitingConsent(slug: String, revisionId: String)
    case reviewing(slug: String, revisionId: String)
    case staging(slug: String, revisionId: String)
    case activating(slug: String, revisionId: String)
    case opening(slug: String, revisionId: String)
}

public enum NativeWebsiteInstallDisposition: Equatable, Sendable {
    case install
    case update(currentRevisionId: String)
}

public struct NativeWebsiteInstallReview: Equatable, Sendable {
    public let consentToken: String
    public let slug: String
    public let displayName: String
    public let identity: NativeShellAppIdentity
    public let baseRevisionId: String?
    public let revisionId: String
    public let packageSHA256: String
    public let requestedCapabilities: [String]
    public let unsupportedCapabilities: [String]
    public let dataNamespace: String
    public let disposition: NativeWebsiteInstallDisposition

    /// Host-facing spelling for the one prepared Install & Open decision. This
    /// is not `NativeShellPackageReview.reviewToken`; coordinator review authority
    /// is created only after this prepared review is explicitly confirmed.
    public var reviewToken: String { consentToken }
}

public enum NativeWebsiteInstallResultSource: Equatable, Sendable {
    case alreadyInstalled
    case installed(alreadyStaged: Bool)
}

public struct NativeWebsiteInstallResult: Equatable, Sendable {
    public let slug: String
    public let displayName: String
    public let identity: NativeShellAppIdentity
    public let revisionId: String
    public let requestedCapabilities: [String]
    public let dataNamespace: String
    public let source: NativeWebsiteInstallResultSource
    public let launch: NativeShellLaunchOutcome
}

public enum NativeWebsiteInstallPreparation: Equatable, Sendable {
    case consentRequired(NativeWebsiteInstallReview)
    case openedExisting(NativeWebsiteInstallResult)
}

public enum NativeWebsiteInstallCancelResult: Equatable, Sendable {
    case nothingToCancel
    case cancelled
    case cancellationRequested
    case commitPointReached
}

public enum NativeWebsiteInstallFlowError: Error, Equatable, Sendable, CustomStringConvertible {
    case appNotFound(String)
    case invalidConsentToken
    case requestSuperseded
    case cancelled
    case commitInProgress
    case noRetryAvailable
    case anotherPackageReviewPending
    case unsupportedCapabilities([String])
    case publishedRevisionMismatch(expected: String, actual: String)
    case cancelledAfterStaging(identity: NativeShellAppIdentity, revisionId: String, alreadyStaged: Bool)
    case activationFailedAfterStaging(identity: NativeShellAppIdentity, revisionId: String, reason: String)
    case openFailedAfterActivation(identity: NativeShellAppIdentity, revisionId: String, reason: String)
    /// Unit m3-guideline47, Guideline 4.7.1: this device blocked the app.
    /// Refused before any download, from Browse or from a universal link.
    case blockedByLocalPolicy(slug: String, appId: String)
    /// Unit m3-guideline47, Guideline 4.7.5: the app's age rating exceeds
    /// this device's declared age. Refused before any download.
    case ageRestricted(slug: String, appAgeRating: Int, declaredAge: Int?)

    public var description: String {
        switch self {
        case .appNotFound(let slug):
            return "Publik's verified catalog does not contain the requested app slug: \(slug)."
        case .invalidConsentToken:
            return "The Install & Open confirmation is no longer current."
        case .requestSuperseded:
            return "A newer website install request replaced this request."
        case .cancelled:
            return "The website install request was cancelled."
        case .commitInProgress:
            return "An Install & Open transaction is already committing."
        case .noRetryAvailable:
            return "There is no website install request to retry."
        case .anotherPackageReviewPending:
            return "Another package review is already pending in Iris."
        case .unsupportedCapabilities(let capabilities):
            return "This Iris build cannot install the app's requested capabilities: \(capabilities.joined(separator: ", "))."
        case .publishedRevisionMismatch(let expected, let actual):
            return "The verified launch revision \(actual) does not match Publik's published revision \(expected)."
        case .cancelledAfterStaging(_, let revisionId, _):
            return "Install & Open was cancelled after revision \(revisionId) was staged; it was not activated by this transaction."
        case .activationFailedAfterStaging(_, let revisionId, let reason):
            return "Revision \(revisionId) was staged, but activation failed: \(reason)"
        case .openFailedAfterActivation(_, let revisionId, let reason):
            return "Revision \(revisionId) was activated, but Iris could not prepare its verified launch: \(reason)"
        case .blockedByLocalPolicy(let slug, _):
            return "This device blocked \(slug). Unblock it, then retry, to install or open it again."
        case .ageRestricted(let slug, let appAgeRating, let declaredAge):
            return "\(slug): " + Review47AgeGateCopy.message(appAgeRating: appAgeRating, declaredAge: declaredAge)
        }
    }
}

/// Orchestrates the direct website-to-Iris path while keeping the existing local
/// import UI and its review lifecycle independent. The only authority created by
/// this flow is a reader's explicit one-app Install & Open confirmation after a
/// catalog-bound package has already been downloaded and inspected.
public actor NativeWebsiteInstallFlow {
    private struct PreparedInstall: Sendable {
        let generation: UInt64
        let app: PublikMobileCatalogApp
        let package: PublikMobileDownloadedPackage
        let review: NativeWebsiteInstallReview
    }

    private enum CommitPhase: Sendable {
        case reviewing
        case staging
        case activating
        case opening
    }

    private struct CommitState: Sendable {
        let generation: UInt64
        let consentToken: String
        var phase: CommitPhase
        var cancelRequested: Bool
    }

    private struct ActivatedInstall: Sendable {
        let review: NativeWebsiteInstallReview
        let alreadyStaged: Bool
        let selection: NativeShellActivationSelection
    }

    private let coordinator: NativeShellLibraryCoordinator
    private let catalogClient: PublikMobileCatalogClient
    /// Legacy callers keep their catalog contract; Browse v2 resolves the
    /// current published index and detail descriptor before any download.
    private let preferCatalogV2: Bool
    private let capabilityPolicy: CapabilityPolicy
    private let usageService: NativeUsageService?
    /// Unit m3-guideline47, Guideline 4.7.1: nil by default so every existing
    /// caller/test is unaffected; a Host that wires one in refuses to open a
    /// blocked app even from a universal link, cold or warm.
    private let review47BlockList: Review47BlockList?
    /// Unit m3-guideline47, Guideline 4.7.5: nil by default for the same
    /// reason. Absent Guideline 4.7 metadata on the resolved descriptor never
    /// restricts by itself (see Review47AgeGate.decide).
    private let review47AgeGate: Review47AgeGate?

    private var generation: UInt64 = 0
    private var activePreparationGeneration: UInt64?
    private var lastCancelledGeneration: UInt64?
    private var lastIntent: NativeWebsiteInstallIntent?
    private var prepared: PreparedInstall?
    private var commit: CommitState?
    private var activatedInstallAwaitingOpen: ActivatedInstall?
    private var reviewUsageBinding: NativeUsageBinding?

    public init(
        coordinator: NativeShellLibraryCoordinator,
        catalogClient: PublikMobileCatalogClient = .init(),
        capabilityPolicy: CapabilityPolicy = .denyAll,
        usageService: NativeUsageService? = nil,
        review47BlockList: Review47BlockList? = nil,
        review47AgeGate: Review47AgeGate? = nil,
        preferCatalogV2: Bool = false
    ) {
        self.coordinator = coordinator
        self.catalogClient = catalogClient
        self.preferCatalogV2 = preferCatalogV2
        self.capabilityPolicy = capabilityPolicy
        self.usageService = usageService
        self.review47BlockList = review47BlockList
        self.review47AgeGate = review47AgeGate
    }

    public func prepare(
        url: URL,
        progress: NativeWebsiteInstallProgressHandler? = nil
    ) async throws -> NativeWebsiteInstallPreparation {
        let intent = try NativeWebsiteInstallIntent.parse(url)
        return try await prepare(intent: intent, progress: progress)
    }

    public func retry(
        progress: NativeWebsiteInstallProgressHandler? = nil
    ) async throws -> NativeWebsiteInstallPreparation {
        try Task.checkCancellation()
        guard commit == nil else { throw NativeWebsiteInstallFlowError.commitInProgress }
        if let activated = activatedInstallAwaitingOpen {
            return try await retryActivatedInstall(activated, progress: progress)
        }
        guard let lastIntent else {
            throw NativeWebsiteInstallFlowError.noRetryAvailable
        }
        return try await prepare(intent: lastIntent, progress: progress)
    }

    public func cancel() -> NativeWebsiteInstallCancelResult {
        if var commit {
            switch commit.phase {
            case .reviewing, .staging:
                guard !commit.cancelRequested else { return .cancellationRequested }
                commit.cancelRequested = true
                self.commit = commit
                return .cancellationRequested
            case .activating, .opening:
                return .commitPointReached
            }
        }

        guard activePreparationGeneration != nil || prepared != nil || activatedInstallAwaitingOpen != nil else {
            return .nothingToCancel
        }
        let cancelled = generation
        finishUsageReview(.cancelled)
        lastCancelledGeneration = cancelled
        generation &+= 1
        activePreparationGeneration = nil
        prepared = nil
        activatedInstallAwaitingOpen = nil
        return .cancelled
    }

    public func installAndOpen(
        consentToken: String,
        progress: NativeWebsiteInstallProgressHandler? = nil
    ) async throws -> NativeWebsiteInstallResult {
        guard commit == nil else {
            throw NativeWebsiteInstallFlowError.commitInProgress
        }
        guard let prepared,
              prepared.generation == generation,
              prepared.review.consentToken == consentToken else {
            throw NativeWebsiteInstallFlowError.invalidConsentToken
        }

        let transactionGeneration = prepared.generation
        let review = prepared.review
        guard review.unsupportedCapabilities.isEmpty else {
            finishUsageReview(.rejected)
            throw NativeWebsiteInstallFlowError.unsupportedCapabilities(review.unsupportedCapabilities)
        }
        finishUsageReview(.success)
        // Confirmation begins a new operation. Its completion keeps this binding
        // even if the local consent setting changes while staging is suspended.
        let installationUsageBinding = newUsageBinding(identity: review.identity)
        commit = CommitState(
            generation: transactionGeneration,
            consentToken: consentToken,
            phase: .reviewing,
            cancelRequested: false
        )
        emit(.reviewing(slug: review.slug, revisionId: review.revisionId), using: progress)

        var coordinatorReviewToken: String?
        var stagedOutcome: NativeShellStageOutcome?
        var didBeginStaging = false
        do {
            try requireCommitCanContinue(transactionGeneration)
            guard let coordinatorReview = try await coordinator.reviewImportIfIdle(
                packageBytes: prepared.package.packageBytes,
                expectedIdentity: review.identity
            ) else {
                throw NativeWebsiteInstallFlowError.anotherPackageReviewPending
            }
            coordinatorReviewToken = coordinatorReview.reviewToken
            try requireCommitCanContinue(transactionGeneration)

            setCommitPhase(.staging, generation: transactionGeneration)
            emit(.staging(slug: review.slug, revisionId: review.revisionId), using: progress)
            didBeginStaging = true
            recordUsage(.stageAttempt, binding: installationUsageBinding)
            let staged = try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: coordinatorReview.reviewToken,
                packageSHA256: coordinatorReview.packageSHA256
            )
            stagedOutcome = staged
            recordUsage(.stageOutcome(.success), binding: installationUsageBinding)

            if Task.isCancelled || (commit?.generation == transactionGeneration && commit?.cancelRequested == true) {
                finishAbortedCommit(generation: transactionGeneration)
                throw NativeWebsiteInstallFlowError.cancelledAfterStaging(
                    identity: staged.identity,
                    revisionId: staged.revisionId,
                    alreadyStaged: staged.alreadyStaged
                )
            }
            try requireCommitCanContinue(transactionGeneration)

            // Crossing into activation is the commit point. Cancellation that
            // arrived before this exact boundary was handled above and cannot
            // activate. Once activation begins, cancel() reports commitPointReached.
            setCommitPhase(.activating, generation: transactionGeneration)
            emit(.activating(slug: review.slug, revisionId: review.revisionId), using: progress)
            recordUsage(.activateAttempt, binding: installationUsageBinding)
            let selection: NativeShellActivationSelection
            do {
                selection = try await coordinator.activateAndCaptureSelection(identity: staged.identity, revisionId: staged.revisionId)
                recordUsage(.activateOutcome(.success), binding: installationUsageBinding)
            } catch {
                recordUsage(.activateOutcome(.failure), binding: installationUsageBinding)
                finishAbortedCommit(generation: transactionGeneration)
                throw NativeWebsiteInstallFlowError.activationFailedAfterStaging(
                    identity: staged.identity,
                    revisionId: staged.revisionId,
                    reason: String(describing: error)
                )
            }

            activatedInstallAwaitingOpen = ActivatedInstall(review: review, alreadyStaged: staged.alreadyStaged, selection: selection)

            setCommitPhase(.opening, generation: transactionGeneration)
            emit(.opening(slug: review.slug, revisionId: review.revisionId), using: progress)
            let launch: NativeShellLaunchOutcome
            do {
                launch = try await coordinator.launchActive(identity: staged.identity, requiringSelection: selection)
            } catch {
                if error as? NativeShellLibraryError == .activeSelectionSuperseded {
                    activatedInstallAwaitingOpen = nil
                }
                finishAbortedCommit(generation: transactionGeneration)
                throw NativeWebsiteInstallFlowError.openFailedAfterActivation(
                    identity: staged.identity,
                    revisionId: staged.revisionId,
                    reason: String(describing: error)
                )
            }
            guard launch.identity == review.identity,
                  launch.launchedRevisionId == review.revisionId else {
                activatedInstallAwaitingOpen = nil
                finishAbortedCommit(generation: transactionGeneration)
                throw NativeWebsiteInstallFlowError.publishedRevisionMismatch(
                    expected: review.revisionId,
                    actual: launch.launchedRevisionId
                )
            }

            activatedInstallAwaitingOpen = nil
            finishSuccessfulCommit(generation: transactionGeneration)
            return NativeWebsiteInstallResult(
                slug: review.slug,
                displayName: review.displayName,
                identity: review.identity,
                revisionId: review.revisionId,
                requestedCapabilities: review.requestedCapabilities,
                dataNamespace: review.dataNamespace,
                source: .installed(alreadyStaged: staged.alreadyStaged),
                launch: launch
            )
        } catch {
            if didBeginStaging, stagedOutcome == nil {
                recordUsage(.stageOutcome(Self.usageOutcome(for: error)), binding: installationUsageBinding)
            }
            if let coordinatorReviewToken,
               stagedOutcome == nil,
               commit?.generation == transactionGeneration {
                await coordinator.cancelReview(reviewToken: coordinatorReviewToken)
            }
            if commit?.generation == transactionGeneration {
                finishAbortedCommit(generation: transactionGeneration)
            }
            throw error
        }
    }

    private func retryActivatedInstall(
        _ activated: ActivatedInstall,
        progress: NativeWebsiteInstallProgressHandler?
    ) async throws -> NativeWebsiteInstallPreparation {
        generation &+= 1
        let requestGeneration = generation
        activePreparationGeneration = requestGeneration
        let review = activated.review
        emit(.opening(slug: review.slug, revisionId: review.revisionId), using: progress)
        do {
            let launch = try await coordinator.launchActive(identity: review.identity, requiringSelection: activated.selection)
            try requirePreparationCurrent(requestGeneration)
            guard launch.identity == review.identity, launch.launchedRevisionId == review.revisionId, !launch.didFallback else {
                activatedInstallAwaitingOpen = nil
                throw NativeShellLibraryError.activeSelectionSuperseded
            }
            activatedInstallAwaitingOpen = nil
            finishPreparation(generation: requestGeneration)
            return .openedExisting(NativeWebsiteInstallResult(
                slug: review.slug, displayName: review.displayName, identity: review.identity,
                revisionId: review.revisionId, requestedCapabilities: review.requestedCapabilities,
                dataNamespace: review.dataNamespace,
                source: .installed(alreadyStaged: activated.alreadyStaged), launch: launch))
        } catch {
            guard generation == requestGeneration else { throw error }
            activePreparationGeneration = nil
            if error is CancellationError || error as? NativeShellLibraryError == .activeSelectionSuperseded {
                activatedInstallAwaitingOpen = nil
                throw error
            }
            // A transient read failure is not loss of an already approved,
            // completed activation. Keep only its exact in-memory selection.
            throw NativeWebsiteInstallFlowError.openFailedAfterActivation(
                identity: review.identity, revisionId: review.revisionId, reason: String(describing: error))
        }
    }

    private func resolveApp(slug: String) async throws -> PublikMobileCatalogApp {
        if preferCatalogV2 {
            let first: PublikMobileCatalogIndexPageV2
            do {
                first = try await catalogClient.fetchIndexPage(1, cache: nil).value
            } catch PublikMobileDownloadError.catalogIndexV2Unavailable {
                return try await resolveLegacyApp(slug: slug)
            }
            var rows = first.apps
            var slugs = Set(rows.map(\.slug))
            if first.pageCount > 1 {
                for number in 2...first.pageCount {
                    try Task.checkCancellation()
                    let page = try await catalogClient.fetchIndexPage(number, cache: nil).value
                    guard page.generatedAt == first.generatedAt, page.pageCount == first.pageCount else {
                        throw PublikMobileDownloadError.invalidCatalogField("index page is from a different publish")
                    }
                    for row in page.apps {
                        guard slugs.insert(row.slug).inserted else { throw PublikMobileDownloadError.invalidCatalogField("apps.slug") }
                    }
                    rows.append(contentsOf: page.apps)
                }
            }
            guard let row = rows.first(where: { $0.slug == slug }) else { throw NativeWebsiteInstallFlowError.appNotFound(slug) }
            let page = try await catalogClient.fetchAppPage(slug: slug, cache: nil).value
            return catalogClient.installableApp(slug: row.slug, name: row.name, appPage: page)
        }
        return try await resolveLegacyApp(slug: slug)
    }

    private func resolveLegacyApp(slug: String) async throws -> PublikMobileCatalogApp {
        guard let app = try await catalogClient.fetchCatalog().first(where: { $0.slug == slug }) else {
            throw NativeWebsiteInstallFlowError.appNotFound(slug)
        }
        return app
    }

    private func prepare(
        intent: NativeWebsiteInstallIntent,
        progress: NativeWebsiteInstallProgressHandler?
    ) async throws -> NativeWebsiteInstallPreparation {
        try Task.checkCancellation()
        guard commit == nil else {
            throw NativeWebsiteInstallFlowError.commitInProgress
        }

        activatedInstallAwaitingOpen = nil
        finishUsageReview(.cancelled)
        generation &+= 1
        let requestGeneration = generation
        activePreparationGeneration = requestGeneration
        prepared = nil
        lastIntent = intent
        emit(.resolvingCatalog(slug: intent.slug), using: progress)

        let preparationUsageBinding = newUsageBinding(identity: nil)
        recordUsage(.catalogLoadAttempt, binding: preparationUsageBinding)
        var catalogFinished = false
        var downloadStarted = false
        var downloadFinished = false
        var downloadUsageBinding: NativeUsageBinding?

        do {
            let app = try await resolveApp(slug: intent.slug)
            try requirePreparationCurrent(requestGeneration)
            catalogFinished = true
            recordUsage(.catalogLoadOutcome(.success), binding: preparationUsageBinding)
            guard let descriptor = app.mobileShell else {
                throw PublikMobileDownloadError.mobileShellUnavailable(slug: app.slug)
            }
            try await requireReview47Access(app: app, descriptor: descriptor)

            emit(.checkingInstalled(slug: intent.slug), using: progress)
            let installedEntry = try await coordinator.libraryEntry(identity: descriptor.identity)
            try requirePreparationCurrent(requestGeneration)
            if let entry = installedEntry,
               entry.currentRevisionId == descriptor.revisionId,
               let summary = entry.revisions.first(where: { $0.revisionId == descriptor.revisionId }) {
                emit(.opening(slug: intent.slug, revisionId: descriptor.revisionId), using: progress)
                let launch = try await coordinator.launchActive(identity: descriptor.identity)
                try requirePreparationCurrent(requestGeneration)
                guard launch.identity == descriptor.identity,
                      launch.launchedRevisionId == descriptor.revisionId else {
                    throw NativeWebsiteInstallFlowError.publishedRevisionMismatch(
                        expected: descriptor.revisionId,
                        actual: launch.launchedRevisionId
                    )
                }
                finishPreparation(generation: requestGeneration)
                return .openedExisting(
                    NativeWebsiteInstallResult(
                        slug: app.slug,
                        displayName: summary.displayName,
                        identity: descriptor.identity,
                        revisionId: descriptor.revisionId,
                        requestedCapabilities: summary.requestedCapabilities,
                        dataNamespace: summary.dataNamespace,
                        source: .alreadyInstalled,
                        launch: launch
                    )
                )
            }

            emit(.downloading(slug: intent.slug, progress: nil), using: progress)
            if let preparationUsageBinding,
               let identity = try? NativeUsageIdentity(appId: descriptor.appId, projectId: descriptor.projectId) {
                downloadUsageBinding = usageService?.binding(for: identity, continuing: preparationUsageBinding)
            }
            downloadStarted = true
            recordUsage(.downloadAttempt, binding: downloadUsageBinding)
            let flow = self
            let progressHandler = progress
            let package = try await catalogClient.download(app) { value in
                guard let progressHandler else { return }
                Task {
                    await flow.emitDownloadProgress(
                        value,
                        slug: intent.slug,
                        generation: requestGeneration,
                        using: progressHandler
                    )
                }
            }
            try requirePreparationCurrent(requestGeneration)
            downloadFinished = true
            recordUsage(.downloadOutcome(.success), binding: downloadUsageBinding)
            emit(.verifying(slug: intent.slug), using: progress)

            let currentRevision = installedEntry?.currentRevisionId
            let disposition: NativeWebsiteInstallDisposition = currentRevision.map {
                .update(currentRevisionId: $0)
            } ?? .install
            let consent = NativeWebsiteInstallReview(
                consentToken: UUID().uuidString,
                slug: app.slug,
                displayName: package.inspection.displayName,
                identity: package.identity,
                baseRevisionId: package.inspection.baseRevisionId,
                revisionId: package.inspection.revisionId,
                packageSHA256: package.inspection.packageSHA256,
                requestedCapabilities: package.inspection.requestedCapabilities,
                unsupportedCapabilities: unsupportedCapabilities(for: package.inspection.requestedCapabilities),
                dataNamespace: package.inspection.dataNamespace,
                disposition: disposition
            )
            self.prepared = PreparedInstall(
                generation: requestGeneration,
                app: app,
                package: package,
                review: consent
            )
            activePreparationGeneration = nil
            reviewUsageBinding = downloadUsageBinding
            recordUsage(.reviewAttempt, binding: reviewUsageBinding)
            emit(.awaitingConsent(slug: app.slug, revisionId: consent.revisionId), using: progress)
            return .consentRequired(consent)
        } catch {
            let outcome = Self.usageOutcome(for: error)
            if !catalogFinished { recordUsage(.catalogLoadOutcome(outcome), binding: preparationUsageBinding) }
            if downloadStarted, !downloadFinished { recordUsage(.downloadOutcome(outcome), binding: downloadUsageBinding) }
            if activePreparationGeneration == requestGeneration {
                activePreparationGeneration = nil
            }
            if prepared?.generation == requestGeneration {
                prepared = nil
            }
            throw error
        }
    }

    private func requirePreparationCurrent(_ requestGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard requestGeneration == generation else {
            if lastCancelledGeneration == requestGeneration {
                throw NativeWebsiteInstallFlowError.cancelled
            }
            throw NativeWebsiteInstallFlowError.requestSuperseded
        }
        guard commit == nil else {
            throw NativeWebsiteInstallFlowError.commitInProgress
        }
    }

    private func requireCommitCanContinue(_ transactionGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard let commit,
              commit.generation == transactionGeneration,
              prepared?.generation == transactionGeneration else {
            throw NativeWebsiteInstallFlowError.invalidConsentToken
        }
        if commit.cancelRequested {
            throw NativeWebsiteInstallFlowError.cancelled
        }
    }

    /// Unit m3-guideline47: refuses before any download starts, so a
    /// blocked or age-restricted app is refused whether it was opened from
    /// Browse or from a universal link (`https://publikhq.com/iris/apps/<slug>`),
    /// cold or warm, and whether it is already installed or not.
    private func requireReview47Access(
        app: PublikMobileCatalogApp,
        descriptor: PublikMobileShellDescriptor
    ) async throws {
        if let review47BlockList, await review47BlockList.isBlocked(appId: descriptor.appId) {
            throw NativeWebsiteInstallFlowError.blockedByLocalPolicy(slug: app.slug, appId: descriptor.appId)
        }
        if let review47AgeGate {
            let decision = await review47AgeGate.evaluate(appAgeRating: descriptor.appStoreMetadata?.ageRating)
            if case .restricted(let appAgeRating, let declaredAge) = decision {
                throw NativeWebsiteInstallFlowError.ageRestricted(
                    slug: app.slug,
                    appAgeRating: appAgeRating,
                    declaredAge: declaredAge
                )
            }
        }
    }

    private func unsupportedCapabilities(for requested: [String]) -> [String] {
        let requestedSet = Set(requested)
        let unsupported = requestedSet.subtracting(capabilityPolicy.supportedCapabilities)
        let nativeRequested = Set(requested.filter { $0.hasPrefix("native.") })
        let ungrantedNative = nativeRequested.subtracting(capabilityPolicy.grantedNativeCapabilities)
        return Array(unsupported.union(ungrantedNative)).sorted()
    }

    private func newUsageBinding(identity: NativeShellAppIdentity?) -> NativeUsageBinding? {
        guard let identity = try? NativeUsageIdentity(appId: identity?.appId ?? "iris.mobile-shell",
                                                     projectId: identity?.projectId ?? "iris.mobile-shell.host") else { return nil }
        return usageService?.binding(for: identity)
    }

    private func recordUsage(_ event: NativeUsageEvent, binding: NativeUsageBinding?) {
        guard let binding else { return }
        _ = usageService?.record(event, binding: binding)
    }

    private func finishUsageReview(_ outcome: NativeUsageOutcome) {
        let binding = reviewUsageBinding
        reviewUsageBinding = nil
        recordUsage(.reviewOutcome(outcome), binding: binding)
    }

    private static func usageOutcome(for error: Error) -> NativeUsageOutcome {
        if error is CancellationError { return .cancelled }
        if let flow = error as? NativeWebsiteInstallFlowError {
            switch flow {
            case .cancelled, .cancelledAfterStaging, .requestSuperseded: return .cancelled
            case .unsupportedCapabilities, .invalidConsentToken: return .rejected
            default: break
            }
        }
        return .failure
    }

    private func setCommitPhase(_ phase: CommitPhase, generation transactionGeneration: UInt64) {
        guard var commit, commit.generation == transactionGeneration else { return }
        commit.phase = phase
        self.commit = commit
    }

    private func finishPreparation(generation requestGeneration: UInt64) {
        if activePreparationGeneration == requestGeneration {
            activePreparationGeneration = nil
        }
        if generation == requestGeneration {
            prepared = nil
        }
    }

    private func finishSuccessfulCommit(generation transactionGeneration: UInt64) {
        guard commit?.generation == transactionGeneration else { return }
        commit = nil
        if prepared?.generation == transactionGeneration {
            prepared = nil
        }
        activePreparationGeneration = nil
    }

    private func finishAbortedCommit(generation transactionGeneration: UInt64) {
        guard commit?.generation == transactionGeneration else { return }
        commit = nil
        if prepared?.generation == transactionGeneration {
            prepared = nil
        }
        if generation == transactionGeneration {
            generation &+= 1
        }
        activePreparationGeneration = nil
    }

    private func emit(
        _ value: NativeWebsiteInstallProgress,
        using handler: NativeWebsiteInstallProgressHandler?
    ) {
        handler?(value)
    }

    private func emitDownloadProgress(
        _ value: PublikMobileDownloadProgress,
        slug: String,
        generation requestGeneration: UInt64,
        using handler: NativeWebsiteInstallProgressHandler
    ) {
        guard requestGeneration == generation,
              activePreparationGeneration == requestGeneration,
              commit == nil else { return }
        handler(.downloading(slug: slug, progress: value))
    }
}
