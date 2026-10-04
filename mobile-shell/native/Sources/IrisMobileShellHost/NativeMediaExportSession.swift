import Foundation

enum NativeMediaExportSessionDecision {
    enum CandidateAction: Equatable {
        case bind
        case ignore
        case cancelOnly
        case cancelAndFinish
    }

    enum CallbackAction: Equatable {
        case ignore
        case terminate
        case proceed
    }

    static func candidateAction(
        finished: Bool,
        hasBoundDownload: Bool,
        candidateIsBoundDownload: Bool,
        viewMatches: Bool,
        isCurrent: Bool,
        blobMatches: Bool
    ) -> CandidateAction {
        if finished { return .cancelOnly }
        if hasBoundDownload { return candidateIsBoundDownload ? .ignore : .cancelOnly }
        return viewMatches && isCurrent && blobMatches ? .bind : .cancelAndFinish
    }

    static func callbackAction(ownsDownload: Bool, sessionReady: Bool) -> CallbackAction {
        guard ownsDownload else { return .ignore }
        return sessionReady ? .proceed : .terminate
    }

    static func noticeMessage(_ message: String?, isCurrent: Bool, hasWindow: Bool) -> String? {
        isCurrent && hasWindow ? message : nil
    }
}

#if os(iOS)
import UIKit
import WebKit
import Photos
import UniformTypeIdentifiers
import IrisMobileShellCore

/// One current-document blob download followed by a user-controlled Save picker.
/// The coordinator retains this object until its writer/custody are both closed.
/// No bridge, remote request, resume-data store or caller-selected path is added.
@MainActor
final class NativeMediaExportSession: NSObject, WKDownloadDelegate, UIDocumentPickerDelegate,
                                      UIAdaptivePresentationControllerDelegate {
    let id = UUID()
    let blobURL: URL
    private weak var webView: WKWebView?
    private let isCurrent: () -> Bool
    private var completion: ((UUID, String?) -> Void)?
    private var download: WKDownload?
    private var lease: NativeMediaExportLease?
    private var picker: UIDocumentPickerViewController?
    private var observation: NSKeyValueObservation?
    private var timeout: Task<Void, Never>?
    private var destinationChosen = false
    private var downloadFinished = false
    private var finished = false
    private var fileExtension: String?
    private var saveFlow: NativeMediaSaveFlow?
    private var exportedFile: URL?

#if DEBUG
    var temporaryDirectoryForTesting: URL? { lease?.directoryForTesting }
#endif

    init(webView: WKWebView, blobURL: URL, isCurrent: @escaping () -> Bool,
         completion: @escaping (UUID, String?) -> Void) {
        self.webView = webView
        self.blobURL = blobURL
        self.isCurrent = isCurrent
        self.completion = completion
        super.init()
        armTimeout(seconds: 30)
    }

    func accept(_ candidate: WKDownload, in view: WKWebView) {
        let action = NativeMediaExportSessionDecision.candidateAction(
            finished: finished,
            hasBoundDownload: download != nil,
            candidateIsBoundDownload: download.map { $0 === candidate } ?? false,
            viewMatches: view === webView,
            isCurrent: current,
            blobMatches: candidate.originalRequest?.url?.absoluteString == blobURL.absoluteString
        )
        switch action {
        case .bind:
            break
        case .ignore:
            return
        case .cancelOnly:
            candidate.cancel(nil)
            return
        case .cancelAndFinish:
            candidate.cancel(nil)
            finish(message: nil)
            return
        }
        download = candidate
        candidate.delegate = self
        observation = candidate.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let count = progress.completedUnitCount
            Task { @MainActor in
                guard let self, !self.finished else { return }
                if count > Int64(NativeMediaExportLease.maximumBytes) {
                    // RC-09a: the hard ceiling itself is no longer 32 MB
                    // (see NativeMediaExportLease.maximumBytes); state the
                    // real current ceiling instead of a stale number.
                    let formatter = ByteCountFormatter()
                    formatter.countStyle = .file
                    let limit = formatter.string(fromByteCount: Int64(NativeMediaExportLease.maximumBytes))
                    self.finish(message: "The exported media exceeds the \(limit) save limit.")
                }
            }
        }
    }

    func cancel() { finish(message: nil) }

    private var current: Bool {
        !finished && isCurrent() && webView?.window != nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        switch NativeMediaExportSessionDecision.callbackAction(
            ownsDownload: download === self.download,
            sessionReady: current && !destinationChosen
        ) {
        case .ignore:
            completionHandler(nil)
            return
        case .terminate:
            completionHandler(nil)
            finish(message: Self.responseRejectedMessage())
            return
        case .proceed:
            break
        }
        guard let metadata = NativeMediaExportPolicy.responseMetadata(response: response, expectedBlobURL: blobURL) else {
            completionHandler(nil)
            finish(message: Self.responseRejectedMessage())
            return
        }
        do {
            let lease = try NativeMediaExportLease()
            let destination = try lease.reserve(expectedBytes: metadata.byteCount, fileExtension: metadata.fileExtension)
            self.lease = lease
            destinationChosen = true
            fileExtension = metadata.fileExtension
            // suggestedFilename is untrusted and is never used as a path or name.
            completionHandler(destination)
        } catch let failure as NativeMediaExportLease.Failure {
            completionHandler(nil)
            // RC-09a: a real free-space rejection gets its own plain,
            // real-number message (same shape as the import side's
            // `NativeMediaImportPolicy.message(for: .notEnoughSpace)`),
            // distinct from every other lease failure's generic message.
            if case .notEnoughSpace(let requiredBytes, _) = failure {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                let size = formatter.string(fromByteCount: requiredBytes)
                finish(message: "Your iPhone needs about \(size) free to save this export. Free up space, then try again.")
            } else {
                finish(message: "Iris could not prepare temporary space for this export. Your app data was not changed.")
            }
        } catch {
            completionHandler(nil)
            finish(message: "Iris could not prepare temporary space for this export. Your app data was not changed.")
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let action = NativeMediaExportSessionDecision.callbackAction(
            ownsDownload: download === self.download,
            sessionReady: current && destinationChosen && lease != nil && webView != nil
        )
        guard action != .ignore else { return }
        // This callback is terminal for the owned writer even if document
        // authority became stale before presentation could begin.
        downloadFinished = true
        switch action {
        case .ignore:
            return
        case .terminate:
            finish(message: nil)
            return
        case .proceed:
            break
        }
        guard let lease, let webView else { finish(message: nil); return }
        observation?.invalidate()
        observation = nil
        do {
            let file = try lease.validatedFile()
            guard current, let presenter = Self.presenter(for: webView),
                  !presenter.isBeingDismissed, presenter.presentedViewController == nil else {
                finish(message: nil)
                return
            }
            let rawKind = Self.saveKind(forFileExtension: fileExtension)
            let kind = NativeMediaSaveKind.effectiveKind(
                rawKind: rawKind,
                isPhotosCompatible: Self.isPhotosCompatible(kind: rawKind, fileURL: file)
            )
            guard kind != .other else {
                presentFilesPicker(file: file, from: presenter)
                return
            }
            beginSaveChoice(kind: kind, file: file, presenter: presenter)
        } catch {
            finish(message: "The exported file failed its size or ownership check and was not saved.")
        }
    }

    /// The existing, unchanged Files "Save" sheet. Used directly for a
    /// non-media export, and as the "Save to Files" fallback from the
    /// choice, the access-unavailable, and the save-failed steps below.
    private func presentFilesPicker(file: URL, from presenter: UIViewController) {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        self.picker = picker
        presenter.present(picker, animated: true) { [weak self, weak picker] in
            guard let self, self.current else {
                picker?.dismiss(animated: false)
                self?.finish(message: nil)
                return
            }
            picker?.presentationController?.delegate = self
        }
        // Do not leave app-produced temporary media retained indefinitely if
        // a Save picker is abandoned. This timeout never reports "saved".
        armTimeout(seconds: 180)
    }

    /// Starts the "Your video/photo is ready" choice for a video or image
    /// export. `NativeMediaSaveFlow` (Core) decides what is shown and what
    /// to do next; this method and `apply(_:)`/`render()` below only wire
    /// its effects to the real `PHPhotoLibrary`, `UIApplication` and the
    /// existing Files picker.
    private func beginSaveChoice(kind: NativeMediaSaveKind, file: URL, presenter: UIViewController) {
        exportedFile = file
        var flow = NativeMediaSaveFlow(kind: kind)
        let effects = flow.handle(.start)
        saveFlow = flow
        apply(effects, presenter: presenter)
        render(presenter: presenter)
        // Same abandonment safety net as the Files-only path: a person who
        // leaves the choice, the permission prompt, or the result on
        // screen without ever choosing must not keep the temporary export
        // file around forever.
        armTimeout(seconds: 180)
    }

    private func send(_ event: NativeMediaSaveEvent, presenter: UIViewController) {
        guard current, var flow = saveFlow else { return }
        let effects = flow.handle(event)
        saveFlow = flow
        apply(effects, presenter: presenter)
        render(presenter: presenter)
    }

    private func apply(_ effects: [NativeMediaSaveEffect], presenter: UIViewController) {
        for effect in effects {
            switch effect {
            case .requestAddOnlyAuthorization:
                Task { @MainActor [weak self] in
                    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard let self else { return }
                    self.send(.authorizationResolved(Self.mapAuthorization(status)), presenter: presenter)
                }
            case .performSave(let kind):
                guard let file = exportedFile else {
                    send(.saveFailed, presenter: presenter)
                    continue
                }
                Task { @MainActor [weak self] in
                    do {
                        try await PHPhotoLibrary.shared().performChanges {
                            switch kind {
                            case .video:
                                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                            case .image:
                                _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: file)
                            case .other:
                                break
                            }
                        }
                        self?.send(.saveSucceeded, presenter: presenter)
                    } catch {
                        self?.send(.saveFailed, presenter: presenter)
                    }
                }
            case .presentFilesPicker:
                guard let file = exportedFile, current,
                      let webView, let presenter = Self.presenter(for: webView) else {
                    finish(message: nil)
                    continue
                }
                // A choice/access-unavailable/save-failed alert this file
                // presented may still be up; it must be gone before the
                // Files picker is presented; presenting on top of it would
                // be silently refused.
                if let presented = presenter.presentedViewController {
                    presented.dismiss(animated: false) { [weak self, weak presenter] in
                        guard let self, let presenter, self.current else { return }
                        self.presentFilesPicker(file: file, from: presenter)
                    }
                } else {
                    presentFilesPicker(file: file, from: presenter)
                }
            case .cancelAbandonmentTimeout:
                timeout?.cancel()
                timeout = nil
            case .openPhotosApp:
                if let url = URL(string: "photos-redirect://") {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            case .openSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            case .finish:
                finish(message: nil)
            }
        }
    }

    /// Presents whatever `saveFlow`'s current step calls for. Alerts are
    /// dismissed with no animation before the next one is presented so two
    /// steps in a row (for example a resolved authorization that goes
    /// straight to a failed save) never race two presentations.
    private func render(presenter: UIViewController) {
        guard let saveFlow, current else { return }
        guard let alert = alert(for: saveFlow.step) else { return }
        if let presented = presenter.presentedViewController, presented is UIAlertController {
            presented.dismiss(animated: false) { [weak presenter] in
                presenter?.present(alert, animated: true)
            }
        } else {
            presenter.present(alert, animated: true)
        }
    }

    private func alert(for step: NativeMediaSaveStep) -> UIAlertController? {
        switch step {
        case .choice(let kind):
            let alert = UIAlertController(
                title: NativeMediaSaveCopy.choiceTitle(for: kind), message: nil, preferredStyle: .alert
            )
            let saveToPhotos = UIAlertAction(title: NativeMediaSaveCopy.saveToPhotosButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapSaveToPhotos)
            }
            alert.addAction(saveToPhotos)
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.saveToFilesButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapSaveToFiles)
            })
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.cancelButton, style: .cancel) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapCancel)
            })
            alert.preferredAction = saveToPhotos
            return alert
        case .saving, .none:
            return nil
        case .saved:
            let alert = UIAlertController(title: NativeMediaSaveCopy.savedTitle, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.openPhotosButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapOpenPhotos)
            })
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.doneButton, style: .cancel) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapDone)
            })
            return alert
        case .accessUnavailable:
            let alert = UIAlertController(
                title: nil, message: NativeMediaSaveCopy.accessUnavailableMessage, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.saveToFilesButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapSaveToFiles)
            })
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.openSettingsButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapOpenSettings)
            })
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.cancelButton, style: .cancel) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapCancel)
            })
            return alert
        case .saveFailed:
            let alert = UIAlertController(
                title: nil, message: NativeMediaSaveCopy.saveFailedMessage, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.saveToFilesButton, style: .default) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapSaveToFiles)
            })
            alert.addAction(UIAlertAction(title: NativeMediaSaveCopy.cancelButton, style: .cancel) { [weak self] _ in
                self?.sendFromCurrentPresenter(.tapCancel)
            })
            return alert
        }
    }

    private func sendFromCurrentPresenter(_ event: NativeMediaSaveEvent) {
        guard let webView, let presenter = Self.presenter(for: webView) else { return }
        send(event, presenter: presenter)
    }

    /// RC-09a: the response-rejection message used to hardcode "32 MB",
    /// stale even before this round (the actual check here has always been
    /// `NativeMediaExportPolicy.maximumExportBytes`, 2 GiB, not the
    /// lease's now-removed 32 MB constant). States the real current ceiling
    /// instead of a number that was never the true limit at this step.
    private static func responseRejectedMessage() -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let limit = formatter.string(fromByteCount: NativeMediaExportPolicy.maximumExportBytes)
        return "This export could not be saved. Only known-size media up to \(limit) is supported."
    }

    private static func saveKind(forFileExtension fileExtension: String?) -> NativeMediaSaveKind {
        guard let fileExtension, let type = UTType(filenameExtension: fileExtension) else { return .other }
        return NativeMediaSaveKind.classify(type)
    }

    /// A real, file-level check, not just the extension/UTType this file
    /// was classified from: a browser/web export can be `.mp4`/`.webm`
    /// with a codec (VP9/Opus WebM in particular) Photos cannot import,
    /// so classifying it as `.video` is not proof Photos will actually
    /// take it. `NativeMediaSaveKind.effectiveKind` uses this to decide
    /// whether to offer Save to Photos at all.
    private static func isPhotosCompatible(kind: NativeMediaSaveKind, fileURL: URL) -> Bool {
        switch kind {
        case .video:
            return UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(fileURL.path)
        case .image:
            // Every image extension this shell trusts (png/jpg/gif/webp/heic,
            // see NativeMediaExportPolicy.trustedMediaExtensions) is a format
            // PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL:)
            // accepts.
            return true
        case .other:
            return false
        }
    }

    private static func mapAuthorization(_ status: PHAuthorizationStatus) -> NativeMediaSaveAuthorization {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === self.download else { return }
        // Terminal failure means no writer remains. Never retain resumeData.
        downloadFinished = true
        finish(message: "The export could not finish. Return to the app and try again.")
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(.cancel)
        if download === self.download { finish(message: "Redirected exports are not supported.") }
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
        if download === self.download { finish(message: "An export cannot request account credentials.") }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }
        finish(message: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker else { return }
        // The system owns the copy. Do not inspect/log the user's chosen URLs.
        finish(message: nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === picker else { return }
        finish(message: nil)
    }

    private func armTimeout(seconds: UInt64) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            self?.finish(message: "The export timed out without a confirmed save. Your app data was not changed.")
        }
    }

    private func finish(message: String?) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        observation?.invalidate()
        observation = nil
        picker?.delegate = nil
        picker?.presentationController?.delegate = nil
        picker?.dismiss(animated: false)
        picker = nil
        saveFlow = nil
        exportedFile = nil
        let lease = self.lease
        self.lease = nil
        let completion = self.completion
        self.completion = nil
        let id = self.id
        if let download, !downloadFinished {
            self.download = nil
            // Hold the lease until WebKit confirms cancellation. A late writer
            // must not outlive cleanup or race a newly started export.
            download.cancel { [self] _ in
                lease?.close()
                completion?(
                    id,
                    NativeMediaExportSessionDecision.noticeMessage(
                        message,
                        isCurrent: isCurrent(),
                        hasWindow: webView?.window != nil
                    )
                )
            }
        } else {
            download = nil
            lease?.close()
            completion?(
                id,
                NativeMediaExportSessionDecision.noticeMessage(
                    message,
                    isCurrent: isCurrent(),
                    hasWindow: webView?.window != nil
                )
            )
        }
    }

    private static func presenter(for webView: WKWebView) -> UIViewController? {
        var responder: UIResponder? = webView
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
#endif
