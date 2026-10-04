import Foundation

// Unit M2-store-layout-implementation. One-tap Get (SPEC R8.5, design 6.2
// and 6.3). The controller keeps each button's activity, feeds taps and
// install progress through `StoreInstallMachine.reduce`, and runs at most one
// install at a time through a pipeline. The production pipeline is the
// existing `NativeWebsiteInstallFlow` (same catalog lookup, download, digest
// and package verification, capability policy, staging and activation as the
// website sheet); the tap on Get is the local approval, so there is no second
// screen. Nothing is opened: the button turns into Open.

public enum StoreInstallProgressStep: Equatable, Sendable {
    case downloading(percent: Int?)
    case verifying
}

public enum StoreInstallPipelineOutcome: Equatable, Sendable {
    case installed(revisionId: String, identity: NativeShellAppIdentity)
    case unsupported(reason: String)
}

public enum StoreInstallPipelineError: Error, Equatable, Sendable {
    /// Another review or app presentation owns the shell right now.
    case hostBusy
    case cancelled
}

public protocol StoreInstallPipeline: Sendable {
    func install(slug: String, progress: @escaping @Sendable (StoreInstallProgressStep) -> Void) async throws -> StoreInstallPipelineOutcome
    func cancel() async
}

public actor StoreInstallController {
    public typealias ChangeHandler = @Sendable (_ slug: String, _ activity: StoreInstallActivity) -> Void

    private let pipeline: any StoreInstallPipeline
    private var activities: [String: StoreInstallActivity] = [:]
    private var running: (slug: String, token: UUID)?
    private var onChange: ChangeHandler?
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var installedIdentities: [String: NativeShellAppIdentity] = [:]

    public init(pipeline: any StoreInstallPipeline, onChange: ChangeHandler? = nil) {
        self.pipeline = pipeline
        self.onChange = onChange
    }

    public func setChangeHandler(_ handler: ChangeHandler?) { onChange = handler }

    public func activity(for slug: String) -> StoreInstallActivity { activities[slug] ?? .idle }

    public var runningSlug: String? { running?.slug }

    /// The app identity a Get installed (index v2 rows do not carry one).
    public func installedIdentity(for slug: String) -> NativeShellAppIdentity? { installedIdentities[slug] }

    /// Feeds one person-made event (a tap, Cancel, the phone coming back
    /// online) for one app. Returns the effect the Host must perform itself
    /// (open, unblock, age check); installs and cancels run here.
    @discardableResult
    public func handle(_ event: StoreInstallEvent, slug: String, facts: StoreInstallFacts) -> StoreInstallEffect {
        let current = activities[slug] ?? .idle
        let others = running.map { $0.slug != slug } ?? false
        let (next, effect) = StoreInstallMachine.reduce(activity: current, event: event, facts: facts, anotherInstallRunning: others)
        set(slug, next)
        switch effect {
        case .startInstall:
            start(slug: slug)
        case .cancelInstall:
            let pipeline = self.pipeline
            Task { await pipeline.cancel() }
        case .none, .open, .unblock, .checkAge:
            break
        }
        return effect
    }

    /// Clears a note or a finished state once the library list reflects it,
    /// so the button falls back to what the facts say.
    public func settle(slug: String) {
        switch activities[slug] ?? .idle {
        case .downloading, .verifying: return
        default: set(slug, .idle)
        }
    }

    /// Suspends until no install is running (tests and the persona sim).
    public func waitUntilIdle() async {
        guard running != nil else { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }

    private func start(slug: String) {
        let token = UUID()
        running = (slug, token)
        let pipeline = self.pipeline
        Task {
            do {
                let outcome = try await pipeline.install(slug: slug) { step in
                    Task { await self.progress(step, slug: slug, token: token) }
                }
                switch outcome {
                case .installed(let revisionId, let identity):
                    installedIdentities[slug] = identity
                    finish(slug: slug, token: token, event: .finished(revisionId: revisionId))
                case .unsupported(let reason): finish(slug: slug, token: token, event: .unsupported(reason: reason))
                }
            } catch {
                finish(slug: slug, token: token, event: Self.event(for: error))
            }
        }
    }

    private func progress(_ step: StoreInstallProgressStep, slug: String, token: UUID) {
        guard running?.token == token else { return }
        let event: StoreInstallEvent
        switch step {
        case .downloading(let percent): event = .downloadProgress(percent: percent)
        case .verifying: event = .verifying
        }
        apply(event, slug: slug)
    }

    private func finish(slug: String, token: UUID, event: StoreInstallEvent) {
        guard running?.token == token else { return }
        apply(event, slug: slug)
        running = nil
        let waiters = finishedWaiters
        finishedWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Install events do not depend on facts (only taps do).
    private func apply(_ event: StoreInstallEvent, slug: String) {
        let current = activities[slug] ?? .idle
        let facts = StoreInstallFacts(appName: slug, listing: .notYetChecked)
        let (next, _) = StoreInstallMachine.reduce(activity: current, event: event, facts: facts, anotherInstallRunning: false)
        set(slug, next)
    }

    private func set(_ slug: String, _ activity: StoreInstallActivity) {
        guard activities[slug] ?? .idle != activity else { return }
        activities[slug] = activity
        onChange?(slug, activity)
    }

    static func event(for error: Error) -> StoreInstallEvent {
        if error is CancellationError { return .cancelled }
        if let error = error as? StoreInstallPipelineError, error == .cancelled { return .cancelled }
        if let error = error as? NativeWebsiteInstallFlowError, error == .cancelled || error == .requestSuperseded { return .cancelled }
        return .failed(message: StoreInstallMessages.message(for: error))
    }
}

/// Plain sentences for a failed Get. One idea each, no internal words.
public enum StoreInstallMessages {
    public static func message(for error: Error) -> String {
        if let error = error as? StoreInstallPipelineError, error == .hostBusy {
            return "Finish the app or review that is open, then try again. Nothing was installed."
        }
        if let failure = error as? NativeWebsiteInstallFlowError {
            switch failure {
            case .appNotFound: return "This app is no longer in Publik's list. Nothing was installed."
            case .blockedByLocalPolicy: return "You blocked this app on this iPhone. Unblock it to get it."
            case .ageRestricted(_, let rating, _): return "This app is rated \(rating)+. It was not installed."
            case .unsupportedCapabilities: return "This app needs something this iPhone can't do yet. Nothing was installed."
            case .activationFailedAfterStaging, .cancelledAfterStaging:
                return "The download is ready but was not switched on. Your current app is unchanged. Try again."
            case .openFailedAfterActivation: return "The app was installed. Tap Open to start it."
            case .anotherPackageReviewPending, .commitInProgress:
                return "Another install is finishing. Try again in a moment."
            case .publishedRevisionMismatch, .invalidConsentToken, .requestSuperseded, .cancelled, .noRetryAvailable:
                return "The app changed while it was downloading. Try again to get the newest version."
            }
        }
        if let download = error as? PublikMobileDownloadError, case .mobileShellUnavailable = download {
            return "This app is not published for iPhone yet. Nothing was installed."
        }
        if StoreCatalogFeed.isOffline(error) {
            return "The download stopped. Check your connection and try again. Nothing was installed."
        }
        if let shell = error as? NativeShellError {
            switch shell {
            case .baseMismatch, .userDataNamespaceMismatch:
                return "This version can't safely replace the one you have. Your app and its data were kept."
            default:
                break
            }
        }
        return "The download could not be verified. Nothing was installed."
    }

    /// "This app needs the camera and saving media, which Iris on this
    /// iPhone can't offer yet."
    public static func unsupportedReason(_ capabilities: [String]) -> String {
        var names: [String] = []
        for capability in capabilities.sorted() {
            let name: String
            switch capability {
            case "web.media.camera": name = "the camera"
            case "web.media.photo-picker": name = "picking photos"
            case "web.media.export": name = "saving media"
            case "web.storage": name = "saving its own data"
            default: name = "a phone feature"
            }
            if !names.contains(name) { names.append(name) }
        }
        if names.isEmpty { names = ["a phone feature"] }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "This app needs \(list), which Iris on this iPhone can't offer yet."
    }
}

/// The production pipeline: a fresh `NativeWebsiteInstallFlow` per Get, the
/// same one a publikhq.com link uses, with the tap as the consent.
public actor StoreFlowInstallPipeline: StoreInstallPipeline {
    public typealias FlowFactory = @Sendable () -> NativeWebsiteInstallFlow

    private let makeFlow: FlowFactory
    private let prepareHost: @Sendable () async -> Bool
    private var current: NativeWebsiteInstallFlow?
    private var cancelRequested = false

    public init(makeFlow: @escaping FlowFactory, prepareHost: @escaping @Sendable () async -> Bool = { true }) {
        self.makeFlow = makeFlow
        self.prepareHost = prepareHost
    }

    public static func appLink(slug: String) -> URL? {
        guard NativeSecurity.isStableId(slug) else { return nil }
        return URL(string: "https://publikhq.com/iris/apps/" + slug)
    }

    public func install(slug: String, progress: @escaping @Sendable (StoreInstallProgressStep) -> Void) async throws -> StoreInstallPipelineOutcome {
        guard let url = Self.appLink(slug: slug) else {
            throw NativeWebsiteInstallFlowError.appNotFound(slug)
        }
        cancelRequested = false
        guard await prepareHost() else { throw StoreInstallPipelineError.hostBusy }
        if cancelRequested { throw StoreInstallPipelineError.cancelled }
        let flow = makeFlow()
        current = flow
        defer { current = nil }
        let handler: NativeWebsiteInstallProgressHandler = { value in
            switch value {
            case .downloading(_, let transfer):
                let percent = transfer.map { $0.expectedBytes > 0 ? Int((Double($0.receivedBytes) / Double($0.expectedBytes) * 100).rounded(.down)) : 0 }
                progress(.downloading(percent: percent))
            case .verifying, .reviewing, .awaitingConsent, .staging, .activating, .opening:
                progress(.verifying)
            case .resolvingCatalog, .checkingInstalled:
                break
            }
        }
        switch try await flow.prepare(url: url, progress: handler) {
        case .openedExisting(let result):
            return .installed(revisionId: result.revisionId, identity: result.identity)
        case .consentRequired(let review):
            guard review.unsupportedCapabilities.isEmpty else {
                _ = await flow.cancel()
                return .unsupported(reason: StoreInstallMessages.unsupportedReason(review.unsupportedCapabilities))
            }
            if cancelRequested {
                _ = await flow.cancel()
                throw StoreInstallPipelineError.cancelled
            }
            let result = try await flow.installAndOpen(consentToken: review.consentToken, progress: handler)
            return .installed(revisionId: result.revisionId, identity: result.identity)
        }
    }

    public func cancel() async {
        cancelRequested = true
        _ = await current?.cancel()
    }
}
