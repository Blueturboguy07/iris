#if os(iOS)
import Foundation
import IrisMobileShellCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import WebKit

private final class NativeMediaProviderLoadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var terminalResult: Result<URL, Error>?
    private var progress: Progress?
    private var providerCallbackClaimed = false

    func installContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if let terminalResult {
            lock.unlock()
            continuation.resume(with: terminalResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func installProgress(_ progress: Progress) {
        lock.lock()
        if let terminalResult {
            let shouldCancel: Bool
            switch terminalResult {
            case .success:
                shouldCancel = false
            case .failure:
                shouldCancel = true
            }
            lock.unlock()
            if shouldCancel { progress.cancel() }
            return
        }
        self.progress = progress
        lock.unlock()
    }

    func claimProviderCallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard terminalResult == nil, !providerCallbackClaimed else { return false }
        providerCallbackClaimed = true
        return true
    }

    func finishProvider(_ result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>?
        lock.lock()
        guard terminalResult == nil, providerCallbackClaimed else {
            lock.unlock()
            return
        }
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        progress = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func fail(_ error: Error) {
        let continuation: CheckedContinuation<URL, Error>?
        let progress: Progress?
        lock.lock()
        guard terminalResult == nil else {
            lock.unlock()
            return
        }
        let result: Result<URL, Error> = .failure(error)
        terminalResult = result
        continuation = self.continuation
        self.continuation = nil
        progress = self.progress
        self.progress = nil
        lock.unlock()
        progress?.cancel()
        continuation?.resume(with: result)
    }
}

/// Thread-safe "when did the provider's Progress last move" clock. KVO fires
/// on whatever thread the provider chooses; the watchdog task reads it from
/// its own loop. Only ever moves forward.
private final class NativeMediaProgressAdvanceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(startedAt: Date) { value = startedAt }

    var lastProgressAt: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func recordAdvance(at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if date > value { value = date }
    }
}

/// Holds the KVO observation so the provider's completion closure can
/// invalidate it without capturing a plain `var` across concurrently
/// executing code (that capture is a Swift 6 language mode error).
private final class NativeMediaObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?

    func set(_ observation: NSKeyValueObservation) {
        lock.lock()
        self.observation = observation
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let observation = self.observation
        self.observation = nil
        lock.unlock()
        observation?.invalidate()
    }
}

/// Apple's picker grants access only to selected media; it never requests broad
/// Photo Library access. The WebKit completion resolves once across cancel,
/// timeout, teardown and interactive picker dismissal.
@MainActor
final class NativeMediaPickerSession: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    enum ProviderLoadFailure: Error, Equatable {
        case cancelled
        case timedOut
        case provider
    }

    typealias FileRepresentationCompletion = @Sendable (URL?, Error?) -> Void
    typealias FileRepresentationLoader = (@escaping FileRepresentationCompletion) -> Progress

    private var completion: (([URL]?) -> Void)?
    private let lease: NativeSelectedMediaLease
    private let isCurrent: () -> Bool
    private let notice: (String) -> Void
    private weak var picker: PHPickerViewController?
    private weak var presentingWindow: UIWindow?
    private let maximumItems: Int
    private var activeBatch: NativeSelectedMediaLease.Batch?
    private var loadTask: Task<Void, Never>?
    private var selectionDismissalInProgress = false
    private var waitingIndicatorTask: Task<Void, Never>?
    private weak var waitingAlert: UIAlertController?
    /// Governs one progress sheet across a whole multi-clip pick (requirement:
    /// several clips import one after another with one sheet, not one per
    /// clip): set once at the start of `importResults`, read by
    /// `NativeMediaImportPolicy.waitingIndicatorMessage` to name which clip
    /// is in progress.
    private var totalItemsInBatch = 0
    private var completedItemsInBatch = 0
    /// This session's own start time, used only to bound
    /// `NativeWKFileUploadPanelTempCleanup.cleanupAfterPick`'s same-session
    /// deletion to entries WebKit could only have created after this pick
    /// began (see that type's doc comment). Never a network or UI concern:
    /// pure bookkeeping for a safe cleanup boundary.
    private let sessionStartedAt = Date()

    init(lease: NativeSelectedMediaLease, multiple: Bool,
         isCurrent: @escaping () -> Bool, notice: @escaping (String) -> Void,
         completion: @escaping ([URL]?) -> Void) {
        self.lease = lease
        self.maximumItems = multiple ? NativeMediaPermissionPolicy.maximumItems : 1
        self.isCurrent = isCurrent
        self.notice = notice
        self.completion = completion
    }

    func present(from webView: WKWebView) {
        guard isCurrent(), let window = webView.window,
              var presenter = window.rootViewController else { finish(nil); return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { finish(nil); return }
        presentingWindow = window
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = maximumItems
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        self.picker = picker
        picker.delegate = self
        picker.presentationController?.delegate = self
        presenter.present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func cancel() {
        let task = loadTask
        loadTask = nil
        task?.cancel()
        dismissWaitingIndicator()
        rollbackActiveBatch()
        picker?.dismiss(animated: false)
        finish(nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // A programmatic dismissal after the user committed picker results must
        // not cancel the provider import that is already in progress.
        guard !selectionDismissalInProgress else { return }
        cancel()
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        selectionDismissalInProgress = true
        picker.dismiss(animated: true)
        guard isCurrent(), !results.isEmpty, results.count <= maximumItems else { finish(nil); return }
        do {
            let batch = try lease.beginBatch()
            activeBatch = batch
            let task = Task { [weak self] in
                guard let self else { return }
                await self.importResults(results, batch: batch)
            }
            loadTask = task
        } catch {
            finish(nil)
        }
    }

    static func preferredRepresentation(in typeIdentifiers: [String]) -> (typeIdentifier: String, fileExtension: String)? {
        for identifier in typeIdentifiers {
            guard let type = UTType(identifier),
                  type.conforms(to: .image) || type.conforms(to: .movie),
                  let preferred = type.preferredFilenameExtension?.lowercased(),
                  NativeSelectedMediaLease.isSafeFileExtension(preferred) else { continue }
            return (identifier, preferred)
        }
        return nil
    }

    /// Replaces a single flat timeout: fails only when the provider's own
    /// `Progress` has gone quiet for `stallThresholdSeconds`. There is no
    /// overall ceiling any more (round 3, long-clip import): a slow but
    /// still-moving iCloud download, however long it takes, is never killed
    /// just for taking a while. `stallThresholdSeconds` is a parameter (not
    /// read from `NativeMediaImportPolicy` directly) so a caller, such as a
    /// test, can shrink it; production call sites use the policy's own value.
    static func loadSelectedFile(
        using loader: @escaping FileRepresentationLoader,
        lease: NativeSelectedMediaLease,
        batch: NativeSelectedMediaLease.Batch,
        fileExtension: String,
        kind: NativeMediaImportPolicy.Kind,
        stallThresholdSeconds: TimeInterval = NativeMediaImportPolicy.stallThresholdSeconds,
        pollIntervalNanoseconds: UInt64 = 1_000_000_000
    ) async throws -> URL {
        let gate = NativeMediaProviderLoadGate()
        let startedAt = Date()
        let progressTracker = NativeMediaProgressAdvanceTracker(startedAt: startedAt)

        let watchdogTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                let now = Date()
                let decision = NativeMediaImportPolicy.evaluateProgress(
                    now: now.timeIntervalSinceReferenceDate,
                    lastProgressAt: progressTracker.lastProgressAt.timeIntervalSinceReferenceDate
                )
                switch decision {
                case .keepWaiting:
                    continue
                case .stalled:
                    gate.fail(ProviderLoadFailure.timedOut)
                    return
                }
            }
        }
        defer { watchdogTask.cancel() }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.installContinuation(continuation)
                let observationBox = NativeMediaObservationBox()
                let progress = loader { url, error in
                    observationBox.invalidate()
                    guard gate.claimProviderCallback() else { return }
                    guard error == nil, let url else {
                        gate.finishProvider(.failure(ProviderLoadFailure.provider))
                        return
                    }
                    do {
                        let copied = try lease.copySelectedFile(
                            url,
                            fileExtension: fileExtension,
                            kind: kind,
                            batch: batch,
                            takingProviderTemporaryFile: true
                        )
                        gate.finishProvider(.success(copied))
                    } catch {
                        gate.finishProvider(.failure(error))
                    }
                }
                gate.installProgress(progress)
                observationBox.set(progress.observe(\.completedUnitCount, options: [.new]) { [progressTracker] _, _ in
                    progressTracker.recordAdvance(at: Date())
                })
            }
        }, onCancel: {
            gate.fail(ProviderLoadFailure.cancelled)
        })
    }

    /// One plain sentence a person can act on, per kind of failure, with the
    /// real size in it where that helps.
    static func plainImportFailure(_ error: Error) -> String {
        if let leaseFailure = error as? NativeSelectedMediaLease.Failure {
            switch leaseFailure {
            case .tooLarge(let kind, let actualBytes, _):
                switch kind {
                case .video:
                    return NativeMediaImportPolicy.message(for: .tooLargeVideo(actualBytes: actualBytes))
                case .image:
                    return NativeMediaImportPolicy.message(for: .tooLargeImage(actualBytes: actualBytes))
                }
            case .notEnoughSpace(let requiredBytes, _):
                return NativeMediaImportPolicy.message(for: .notEnoughSpace(requiredBytes: requiredBytes))
            case .closed, .unsafeFile, .full, .io:
                return NativeMediaImportPolicy.message(for: .other)
            }
        }
        if let providerFailure = error as? ProviderLoadFailure, providerFailure == .timedOut {
            return NativeMediaImportPolicy.message(for: .stalled)
        }
        return NativeMediaImportPolicy.message(for: .other)
    }

    private func importResults(_ results: [PHPickerResult], batch: NativeSelectedMediaLease.Batch) async {
        do {
            var files: [URL] = []
            // One progress sheet governs the whole batch (requirement: several
            // clips import one after another with one sheet, not one per
            // clip), scheduled once up front if any item in the pick is a
            // video -- never per item -- and only dismissed once the whole
            // batch is done (success, failure or cancel).
            totalItemsInBatch = results.count
            completedItemsInBatch = 0
            let anyVideo = results.contains { result in
                guard let representation = Self.preferredRepresentation(
                    in: result.itemProvider.registeredTypeIdentifiers
                ) else { return false }
                return NativeMediaImportPolicy.kind(forTypeIdentifier: representation.typeIdentifier) == .video
            }
            if anyVideo { scheduleWaitingIndicatorIfNeeded() }

            for result in results {
                guard completion != nil, isCurrent(), !Task.isCancelled else {
                    throw ProviderLoadFailure.cancelled
                }
                let provider = result.itemProvider
                guard let representation = Self.preferredRepresentation(in: provider.registeredTypeIdentifiers) else {
                    throw NativeSelectedMediaLease.Failure.unsafeFile
                }
                let kind = NativeMediaImportPolicy.kind(forTypeIdentifier: representation.typeIdentifier) ?? .image
                refreshWaitingIndicatorProgress()
                let file: URL
                do {
                    file = try await Self.loadSelectedFile(
                        using: { completion in
                            provider.loadFileRepresentation(
                                forTypeIdentifier: representation.typeIdentifier,
                                completionHandler: completion
                            )
                        },
                        lease: lease,
                        batch: batch,
                        fileExtension: representation.fileExtension,
                        kind: kind
                    )
                } catch {
                    dismissWaitingIndicator()
                    throw error
                }
                files.append(file)
                completedItemsInBatch += 1
                refreshWaitingIndicatorProgress()
            }
            dismissWaitingIndicator()
            guard completion != nil, isCurrent(), !Task.isCancelled else {
                throw ProviderLoadFailure.cancelled
            }
            try lease.commit(batch)
            activeBatch = nil
            loadTask = nil
            finish(files)
        } catch {
            loadTask = nil
            dismissWaitingIndicator()
            let shouldNotice: Bool
            if let providerFailure = error as? ProviderLoadFailure, providerFailure == .cancelled {
                shouldNotice = false
            } else {
                shouldNotice = completion != nil && isCurrent()
            }
            if shouldNotice {
                notice(Self.plainImportFailure(error))
            }
            finish(nil)
        }
    }

    /// Shows "Bringing in your video" after a short delay, so a clip that
    /// loads in about a second never flashes it. Only ever one shown at a
    /// time for the whole batch; `dismissWaitingIndicator` both cancels the
    /// pending timer and dismisses an already-visible one.
    private func scheduleWaitingIndicatorIfNeeded() {
        guard waitingIndicatorTask == nil, waitingAlert == nil else { return }
        let delayNanoseconds = UInt64(NativeMediaImportPolicy.waitingIndicatorDelaySeconds * 1_000_000_000)
        waitingIndicatorTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.presentWaitingIndicator()
        }
    }

    private func presentWaitingIndicator() {
        guard waitingAlert == nil, isCurrent(),
              let window = presentingWindow, var presenter = window.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let alert = UIAlertController(
            title: "Bringing in your video",
            message: NativeMediaImportPolicy.waitingIndicatorMessage(
                completedItems: completedItemsInBatch, totalItems: totalItemsInBatch
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.cancel()
        })
        waitingAlert = alert
        presenter.present(alert, animated: true)
    }

    /// Updates an already-visible sheet's message as items in the batch
    /// complete ("Bringing in clip 2 of 5..."). A no-op before the sheet has
    /// appeared (its own delayed presentation reads the current counters
    /// fresh) or once it has been dismissed.
    private func refreshWaitingIndicatorProgress() {
        guard let alert = waitingAlert else { return }
        alert.message = NativeMediaImportPolicy.waitingIndicatorMessage(
            completedItems: completedItemsInBatch, totalItems: totalItemsInBatch
        )
    }

    private func dismissWaitingIndicator() {
        waitingIndicatorTask?.cancel()
        waitingIndicatorTask = nil
        guard let alert = waitingAlert else { return }
        waitingAlert = nil
        alert.presentingViewController?.dismiss(animated: true)
    }

    private func rollbackActiveBatch() {
        guard let activeBatch else { return }
        self.activeBatch = nil
        lease.rollback(activeBatch)
    }

    private func finish(_ files: [URL]?) {
        dismissWaitingIndicator()
        if files == nil { rollbackActiveBatch() }
        // Runs on every terminal path this function is called from (a full
        // success, a rejected/oversized/space-short pick, a cancel, or
        // teardown): the moment this pick is done, WebKit's own
        // `WKFileUploadPanel-*` temp copies for it are no longer needed.
        // See `NativeWKFileUploadPanelCleanupPolicy` for why this is safe
        // (name-prefix match only; never a user's own file) and
        // `NATIVE_RUNS.md`'s "Side finding" for the 3.5 GB leak this closes.
        NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: sessionStartedAt)
        // Same moment, same rule for WebKit's `FileSystemWritableStream*`
        // staging files (idle 30 minutes, older than this pick, or left by an
        // earlier launch). See `NativeWritableStreamStagingCleanup`.
        NativeWritableStreamStagingCleanup.sweep(referenceStart: sessionStartedAt)
        guard let completion else { return }
        self.completion = nil
        picker = nil
        selectionDismissalInProgress = false
        completion(files)
    }
}
#endif
