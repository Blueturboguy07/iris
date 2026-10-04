#if os(iOS)
import IrisMobileShellCore
import SwiftUI
import WebKit

/// A host-observed WebKit navigation result, not evidence that an in-app task
/// succeeded or that the person interacted with the downloaded content.
public enum NativeShellWebLoadResult: Equatable, Sendable {
    case loaded
    case failed
}

/// A Host-owned reference to one live document, not an app-provided capability.
/// Its only operation invokes the fixed, no-argument save-before-close hook.
@MainActor
struct NativeVerifiedDocumentCloseHandle {
    let id: UUID
    let isCurrent: @MainActor () -> Bool
    let prepare: NativeAppCloseLifecycle.FixedHookEvaluator
}

/// Minimal reviewed-host surface for a revision that the core has already
/// re-verified on disk. This target intentionally exposes no script-message
/// handler or native capability bridge. The one exception is DEBUG builds
/// only: `NativeWebConsoleBridge` adds a log-only console handler (compiled
/// out of Release) so web app failures reach the unified log.
public struct VerifiedRevisionWebView: UIViewRepresentable {
    public let launch: VerifiedLaunchDescriptor
    private let packagedAPIAdapter: IrisPackagedAPIAdapterConfiguration
    private let onLoadResult: ((NativeShellWebLoadResult) -> Void)?
    private let onCloseHandleChange: ((NativeVerifiedDocumentCloseHandle?) -> Void)?
    // Optional and defaulted so every existing caller keeps compiling and
    // keeps today's exact behavior (always `.prompt` on first use) until a
    // caller actually wires a store in. Never resolves its own root URL.
    private let permissionStore: NativePermissionStore?
    /// Reports only that an export started (`true`) or ended (`false`, with
    /// whether it failed), so the full-screen session can refuse Home while a
    /// file is still being written (R2-mobile-integration). Never changes
    /// what the export does.
    private let onExportActivityChange: ((_ inFlight: Bool, _ failed: Bool) -> Void)?

    static var supportsFailClosedMediaBoundary: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    static let unsupportedRuntimeMessage = "Opening downloaded apps securely requires iOS 18.4 or later. Iris has not opened this app or reset its saved data."

    public init(
        launch: VerifiedLaunchDescriptor,
        packagedAPIAdapter: IrisPackagedAPIAdapterConfiguration = .notConfigured,
        onLoadResult: ((NativeShellWebLoadResult) -> Void)? = nil,
        permissionStore: NativePermissionStore? = nil
    ) {
        self.launch = launch
        self.packagedAPIAdapter = packagedAPIAdapter
        self.onLoadResult = onLoadResult
        self.onCloseHandleChange = nil
        self.permissionStore = permissionStore
        self.onExportActivityChange = nil
    }

    init(
        launch: VerifiedLaunchDescriptor,
        packagedAPIAdapter: IrisPackagedAPIAdapterConfiguration,
        onLoadResult: ((NativeShellWebLoadResult) -> Void)?,
        onCloseHandleChange: @escaping (NativeVerifiedDocumentCloseHandle?) -> Void,
        permissionStore: NativePermissionStore? = nil,
        onExportActivityChange: ((_ inFlight: Bool, _ failed: Bool) -> Void)? = nil
    ) {
        self.launch = launch
        self.packagedAPIAdapter = packagedAPIAdapter
        self.onLoadResult = onLoadResult
        self.onCloseHandleChange = onCloseHandleChange
        self.permissionStore = permissionStore
        self.onExportActivityChange = onExportActivityChange
    }

    public func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(launch: launch, onLoadResult: onLoadResult, onCloseHandleChange: onCloseHandleChange,
                                      permissionStore: permissionStore)
        coordinator.onExportActivityChange = onExportActivityChange
        return coordinator
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Older WebKit has no public delegate for cancelling HTML uploads.
        // Do not load untrusted content with an unenforceable capability policy.
        guard Self.supportsFailClosedMediaBoundary else {
            configuration.websiteDataStore = .nonPersistent()
            let emptyView = MediaRestrictedWebView(configuration: configuration, coordinator: context.coordinator)
            Task { @MainActor in context.coordinator.reportConfigurationFailure() }
            return emptyView
        }
        do {
            configuration.websiteDataStore = try NativeWebStorageConfiguration.dataStore(for: launch)
                ?? .nonPersistent()
        } catch {
            // A reviewed persistent-storage requirement must not silently run
            // in an ephemeral or shared-default profile on an unsupported OS.
            configuration.websiteDataStore = .nonPersistent()
            let emptyView = MediaRestrictedWebView(configuration: configuration, coordinator: context.coordinator)
            Task { @MainActor in context.coordinator.reportConfigurationFailure() }
            return emptyView
        }
        do {
            try context.coordinator.installResourceAccess(into: configuration)
            try IrisPackagedAPIHostScripts.install(
                into: configuration,
                launch: launch,
                adapter: packagedAPIAdapter
            )
        } catch {
            // Never construct a failure view from a partially configured object.
            // A fresh configuration has no registered resource handler or scripts;
            // it also avoids mutating WebKit's scheme registry after registration.
            context.coordinator.clearResourceAccess()
            let failureConfiguration = WKWebViewConfiguration()
            failureConfiguration.websiteDataStore = .nonPersistent()
            let emptyView = MediaRestrictedWebView(configuration: failureConfiguration, coordinator: context.coordinator)
            Task { @MainActor in context.coordinator.reportConfigurationFailure() }
            return emptyView
        }
#if DEBUG
        NativeWebConsoleBridge.install(into: configuration, appID: context.coordinator.debugLogAppID)
#endif
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Apps such as FreeHarmony and Kneecap already opt their video elements
        // into playsinline. The iPhone default is still a native full-screen
        // player unless the Host enables this half of WebKit's contract. Keep
        // camera previews and timeline controls together; this grants no media
        // permission and does not change WebKit's user-gesture/autoplay policy.
        configuration.allowsInlineMediaPlayback = true

        let webView = MediaRestrictedWebView(configuration: configuration, coordinator: context.coordinator)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--iris-local-app-acceptance"),
           #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
#endif
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        context.coordinator.prepareAndLoad(webView)
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        // Revision changes are represented by a new verified launch descriptor,
        // not arbitrary URL mutation through the view.
    }

    public static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        IrisPackagedAPIHostScripts.close(in: webView)
#if DEBUG
        NativeWebConsoleBridge.uninstall(from: webView)
#endif
        coordinator.invalidate()
        webView.navigationDelegate = nil
        webView.stopLoading()
        // Keep the denying UI delegate alive until the view itself is released.
        // Clearing a weak uiDelegate would restore WebKit's permission defaults
        // while a detached view or an already queued callback can still exist.
    }

    private final class MediaRestrictedWebView: WKWebView {
        private let mediaBoundaryCoordinator: Coordinator

        init(configuration: WKWebViewConfiguration, coordinator: Coordinator) {
            mediaBoundaryCoordinator = coordinator
            super.init(frame: .zero, configuration: configuration)
            uiDelegate = coordinator
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("Verified revision views are created with a reviewed configuration.")
        }
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let launch: VerifiedLaunchDescriptor
        private var didStartLoad = false
        private var initialNavigation: WKNavigation?
        private var onLoadResult: ((NativeShellWebLoadResult) -> Void)?
        private var onCloseHandleChange: ((NativeVerifiedDocumentCloseHandle?) -> Void)?
        private var initialLoadResultWasDelivered = false
        private var runtimeFailureWasDelivered = false
        private var isValid = true
        private var mediaLease: NativeSelectedMediaLease?
        private var mediaPicker: NativeMediaPickerSession?
        private var mediaPickerRequestID: UUID?
        private var resourceHandler: NativePackageResourceHandler?
        private weak var ownedWebView: WKWebView?
        private var documentEpoch = UUID()
        private var documentReady = false
        private var exportSession: NativeMediaExportSession?
        private var pendingExportAction: WKNavigationAction?
        private let permissionStore: NativePermissionStore?
        private var cameraGrantObservation: NSKeyValueObservation?
        fileprivate var onExportActivityChange: ((_ inFlight: Bool, _ failed: Bool) -> Void)?
        /// Native alert / confirm / prompt for the hosted page (DELETE_HOOKS.md).
        /// Set at the end of `init` because its closures capture `self`.
        private var javaScriptDialogs: NativeJavaScriptDialogUIDelegate!

#if DEBUG
        var hasMediaExportInFlightForTesting: Bool { exportSession != nil }
        var mediaExportDirectoryForTesting: URL? { exportSession?.temporaryDirectoryForTesting }
        /// App id prefix for the DEBUG-only web console log lines.
        var debugLogAppID: String { launch.identity?.appId ?? "unidentified-app" }
        fileprivate func debugLog(_ event: String) {
            NativeWebConsoleBridge.logHostEvent(appID: debugLogAppID, event)
        }
#endif

        fileprivate init(
            launch: VerifiedLaunchDescriptor,
            onLoadResult: ((NativeShellWebLoadResult) -> Void)?,
            onCloseHandleChange: ((NativeVerifiedDocumentCloseHandle?) -> Void)? = nil,
            permissionStore: NativePermissionStore? = nil
        ) {
            self.launch = launch
            self.onLoadResult = onLoadResult
            self.onCloseHandleChange = onCloseHandleChange
            self.permissionStore = permissionStore
            super.init()
            let presenter = NativeAlertDialogPresenter(anchorView: { [weak self] in self?.ownedWebView })
            self.javaScriptDialogs = NativeJavaScriptDialogUIDelegate(
                broker: NativeJavaScriptDialogBroker(presenter: presenter),
                isAllowed: { [weak self] webView, frame in
                    self?.allowsJavaScriptDialog(from: webView, frame: frame) ?? false
                }
            )
        }

        fileprivate func invalidate() {
            isValid = false
            javaScriptDialogs.broker.cancelAll()
            onCloseHandleChange = nil
            invalidateDocumentAuthority()
            ownedWebView = nil
            resourceHandler?.close()
            resourceHandler = nil
            mediaPicker?.cancel()
            mediaPicker = nil
            mediaLease?.close()
            mediaLease = nil
            onLoadResult = nil
            onExportActivityChange = nil
            initialNavigation = nil
            cameraGrantObservation?.invalidate()
            cameraGrantObservation = nil
        }

        fileprivate func reportConfigurationFailure() {
            finishInitialLoad(.failed)
        }

        fileprivate func installResourceAccess(into configuration: WKWebViewConfiguration) throws {
            let handler = NativePackageResourceHandler(launch: launch)
            try handler.install(into: configuration)
            resourceHandler = handler
        }

        fileprivate func clearResourceAccess() {
            resourceHandler?.close()
            resourceHandler = nil
        }

        private func finishInitialLoad(_ result: NativeShellWebLoadResult) {
            guard isValid, !initialLoadResultWasDelivered, let callback = onLoadResult else { return }
            initialLoadResultWasDelivered = true
            // Retain the callback only after a successful initial load so a
            // later WebContent-process termination can become a distinct runtime
            // failure. An initial failure has no healthy runtime to monitor.
            if result == .failed { onLoadResult = nil }
            callback(result)
        }

        private func reportRuntimeFailure() {
            guard isValid,
                  initialLoadResultWasDelivered,
                  !runtimeFailureWasDelivered,
                  let callback = onLoadResult else { return }
            runtimeFailureWasDelivered = true
            onLoadResult = nil
            callback(.failed)
        }

        fileprivate func prepareAndLoad(_ webView: WKWebView) {
            ownedWebView = webView
            installCameraGrantObservationIfNeeded(on: webView)
            let rules = """
            [
              {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}
            ]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "iris-native-shell-no-remote-network-v1",
                encodedContentRuleList: rules
            ) { [weak self, weak webView] ruleList, error in
                Task { @MainActor in
                    guard let self, let webView, self.isValid, !self.didStartLoad else { return }
                    guard error == nil, let ruleList else {
                        self.finishInitialLoad(.failed)
                        return
                    }
                    self.didStartLoad = true
                    webView.configuration.userContentController.add(ruleList)
                    self.initialNavigation = webView.loadFileURL(
                        self.launch.entrypointURL,
                        allowingReadAccessTo: self.launch.readAccessRootURL
                    )
                    if self.initialNavigation == nil { self.finishInitialLoad(.failed) }
                }
            }
        }

        public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard webView === ownedWebView, isValid else { return }
            invalidateDocumentAuthority()
        }

        public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard webView === ownedWebView, isValid else { return }
            invalidateDocumentAuthority()
            documentReady = webView.url.map {
                $0.isFileURL && Self.isDescendant($0.standardizedFileURL,
                                                 of: launch.readAccessRootURL.standardizedFileURL)
            } ?? false
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard isValid, webView === ownedWebView, let navigation else { return }
            if navigation === initialNavigation { finishInitialLoad(.loaded) }
            // A committed but still loading document must not be classified as
            // a fully loaded app without a save hook. Reloads also publish their
            // own fresh handle once that document finishes.
            publishCloseHandle(for: webView)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
#if DEBUG
            debugLog("navigation failed: \(error.localizedDescription)")
#endif
            guard let navigation, navigation === initialNavigation else { return }
            finishInitialLoad(.failed)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
#if DEBUG
            debugLog("provisional navigation failed: \(error.localizedDescription)")
#endif
            guard let navigation, navigation === initialNavigation else { return }
            finishInitialLoad(.failed)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
#if DEBUG
            debugLog("WebContent process terminated (memory limit or crash); the app's page is gone")
#endif
            guard webView === ownedWebView else { return }
            invalidateDocumentAuthority()
            if initialLoadResultWasDelivered {
                reportRuntimeFailure()
            } else {
                finishInitialLoad(.failed)
            }
        }

        public func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            // The installed revision is consented at setup; camera access is
            // still an explicit WebKit/OS decision on first actual use. Never
            // grant microphone or camera+microphone through a camera-only grant.
            let configured = (Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let permitted = type == .camera && configured && webView.window != nil
                && webView === ownedWebView && documentReady
                && frame.request.url?.absoluteString == webView.url?.absoluteString
                && origin.protocol == "file"
                && NativeMediaPermissionPolicy.allows(
                    capability: "web.media.camera", requestedCapabilities: launch.requestedCapabilities,
                    isValid: isValid, isMainFrame: frame.isMainFrame,
                    frameURL: frame.request.url, contentRoot: launch.readAccessRootURL)
            guard permitted else {
                decisionHandler(.deny)
                return
            }
            // No remembered-decision store wired in (or no stable per-app
            // identity to key it by, for example a launch built for a route
            // that never goes through NativeRevisionStore): fall back to
            // exactly today's behavior. This is never reached once the
            // shared store is wired in through the Host's normal launch path.
            guard let permissionStore, let identity = launch.identity else {
                decisionHandler(.prompt)
                return
            }
            switch permissionStore.decision(for: NativePermissionCapability.camera, identity: identity) {
            case .granted:
                decisionHandler(.grant)
            case .denied:
                decisionHandler(.deny)
            case .notDecided:
                // Iris has not remembered an answer for this app yet. Let
                // WebKit/iOS ask as it does today; a successful first use is
                // observed separately (`installCameraGrantObservationIfNeeded`)
                // and remembered from then on, so this branch is not reached
                // again for this app once the person allows it.
                decisionHandler(.prompt)
            }
        }

        /// Observes `WKWebView.cameraCaptureState`, a public, KVO-observable
        /// indicator of whether the camera is actually capturing right now
        /// (the same signal that powers a browser's "camera in use" light).
        /// The first time it becomes `.active` while this app's decision is
        /// still undecided, the person must just have answered WebKit/iOS's
        /// own first-use prompt with Allow, since a denied or never-asked
        /// request cannot start an active capture. That is recorded as this
        /// app's remembered decision, so every later request for this exact
        /// app skips the prompt entirely (see the switch above).
        ///
        /// This does not, by itself, let Iris learn a person's explicit
        /// "Don't Allow" answer on that same first-use prompt; a request that
        /// is silently denied simply never transitions to `.active`, so the
        /// per-app decision stays `.notDecided` and the person is asked again
        /// on the next attempt, which matches today's already-existing
        /// behavior for a denied request rather than regressing it. An
        /// explicit, one-tap "Don't allow" is always available from the
        /// per-app permissions screen (`NativePermissionsSection`).
        private func installCameraGrantObservationIfNeeded(on webView: WKWebView) {
            guard let permissionStore, let identity = launch.identity,
                  launch.requestedCapabilities.contains(NativePermissionCapability.camera) else { return }
            cameraGrantObservation?.invalidate()
            cameraGrantObservation = webView.observe(\.cameraCaptureState, options: [.new]) { [weak self, weak webView] _, _ in
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView, self.isValid, webView === self.ownedWebView,
                          webView.cameraCaptureState == .active,
                          permissionStore.decision(for: NativePermissionCapability.camera, identity: identity) == .notDecided
                    else { return }
                    _ = try? permissionStore.setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)
                }
            }
        }

        @available(iOS 18.4, *)
        public func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
#if DEBUG
            let requestedCompletion = completionHandler
            let completionHandler: ([URL]?) -> Void = { [weak self] urls in
                if let urls {
                    let bytes = urls.reduce(Int64(0)) { total, url in
                        total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                    self?.debugLog("open panel: handing \(urls.count) file(s), \(bytes) bytes, to WebKit")
                } else {
                    self?.debugLog("open panel: no files (cancelled, refused or failed); WebKit fires 'cancel' on the input")
                }
                requestedCompletion(urls)
            }
            debugLog("open panel requested (multiple: \(parameters.allowsMultipleSelection))")
#endif
            guard !parameters.allowsDirectories, webView === ownedWebView,
                  documentReady, webView.window != nil,
                  let sourceURL = webView.url?.absoluteString,
                  frame.request.url?.absoluteString == sourceURL,
                  NativeMediaPermissionPolicy.allows(
                capability: "web.media.photo-picker", requestedCapabilities: launch.requestedCapabilities,
                isValid: isValid, isMainFrame: frame.isMainFrame,
                frameURL: frame.request.url, contentRoot: launch.readAccessRootURL
            ) else { completionHandler(nil); return }
            // Reject a second simultaneous picker rather than displacing the
            // first user's selection or borrowing its completion handler.
            guard mediaPicker == nil else { completionHandler(nil); return }
            do {
                if mediaLease == nil { mediaLease = try NativeSelectedMediaLease() }
                guard let lease = mediaLease else { completionHandler(nil); return }
                let epoch = documentEpoch
                let requestID = UUID()
                mediaPickerRequestID = requestID
                let session = NativeMediaPickerSession(
                    lease: lease, multiple: parameters.allowsMultipleSelection,
                    isCurrent: { [weak self, weak webView] in
                        guard let self, let webView else { return false }
                        return self.mediaPickerRequestID == requestID
                            && self.isCurrentDocument(webView, epoch: epoch, sourceURL: sourceURL)
                    },
                    notice: { [weak self, weak webView] message in
                        guard let self, let webView,
                              self.mediaPickerRequestID == requestID,
                              self.isCurrentDocument(webView, epoch: epoch, sourceURL: sourceURL),
                              var presenter = webView.window?.rootViewController else { return }
                        while let presented = presenter.presentedViewController { presenter = presented }
                        let alert = UIAlertController(title: "Media not imported", message: message, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                        presenter.present(alert, animated: true)
                    }, completion: { [weak self] urls in
                        guard let self, self.mediaPickerRequestID == requestID else {
                            completionHandler(nil)
                            return
                        }
                        self.mediaPickerRequestID = nil
                        self.mediaPicker = nil
                        completionHandler(urls)
                    })
                mediaPicker = session
                session.present(from: webView)
            } catch { completionHandler(nil) }
        }

        // MARK: JavaScript dialogs (alert, confirm, prompt)
        //
        // Without these WebKit answers the page at once with no dialog:
        // confirm() returns false, so a hosted app's "Delete?" button can
        // never proceed (the Kneecap delete bug). The same frame rules as the
        // file picker apply (`NativeJavaScriptDialogPolicy`): only the launched
        // main-frame document of this shell's own web view may show one.

        private func allowsJavaScriptDialog(from webView: WKWebView, frame: WKFrameInfo) -> Bool {
            NativeJavaScriptDialogPolicy.allows(
                isValid: isValid, isOwnedWebView: webView === ownedWebView,
                documentReady: documentReady, hasWindow: webView.window != nil,
                isMainFrame: frame.isMainFrame, frameURL: frame.request.url,
                mainFrameURL: webView.url, contentRoot: launch.readAccessRootURL
            )
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable () -> Void
        ) {
            javaScriptDialogs.webView(webView, runJavaScriptAlertPanelWithMessage: message,
                                      initiatedByFrame: frame, completionHandler: completionHandler)
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
        ) {
            javaScriptDialogs.webView(webView, runJavaScriptConfirmPanelWithMessage: message,
                                      initiatedByFrame: frame, completionHandler: completionHandler)
        }

        public func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            javaScriptDialogs.webView(webView, runJavaScriptTextInputPanelWithPrompt: prompt,
                                      defaultText: defaultText, initiatedByFrame: frame,
                                      completionHandler: completionHandler)
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.request.url?.scheme?.lowercased() == "blob" {
                guard let identity = NativeMediaExportPolicy.authorizeBlobDownload(
                    requestedCapabilities: launch.requestedCapabilities,
                    isValid: isValid && documentReady && webView === ownedWebView,
                    hasWindow: webView.window != nil,
                    shouldPerformDownload: navigationAction.shouldPerformDownload,
                    isExportInFlight: exportSession != nil,
                    sourceIsMainFrame: navigationAction.sourceFrame.isMainFrame,
                    sourceURL: navigationAction.sourceFrame.request.url,
                    currentMainFrameURL: webView.url,
                    requestURL: navigationAction.request.url,
                    contentRoot: launch.readAccessRootURL,
                    // Earned by the actual iOS26.5 file-document category test.
                    // Explicit file-origin and other syntaxes remain disabled.
                    allowedBlobSyntaxes: [.opaqueFileOrigin]),
                      let blobURL = URL(string: identity.absoluteString),
                      let sourceURL = webView.url?.absoluteString else {
                    decisionHandler(.cancel)
                    return
                }
                let epoch = documentEpoch
                let session = NativeMediaExportSession(
                    webView: webView, blobURL: blobURL,
                    isCurrent: { [weak self, weak webView] in
                        guard let self, let webView else { return false }
                        return self.isCurrentDocument(webView, epoch: epoch, sourceURL: sourceURL)
                    }, completion: { [weak self, weak webView] id, message in
                        guard let self, self.exportSession?.id == id else { return }
                        self.exportSession = nil
                        self.pendingExportAction = nil
                        // Failure notices are the only non-nil messages.
                        self.onExportActivityChange?(false, message != nil)
                        guard let message, let webView,
                              self.isCurrentDocument(webView, epoch: epoch, sourceURL: sourceURL) else { return }
                        Self.presentExportNotice(message, in: webView)
                    })
                exportSession = session
                onExportActivityChange?(true, false)
                // Keep the exact approved action, not just an equal blob URL.
                // A late action from an earlier session cannot bind to a new one.
                pendingExportAction = navigationAction
                decisionHandler(.download)
                return
            }
            guard let url = navigationAction.request.url,
                  isValid, webView === ownedWebView,
                  url.isFileURL,
                  Self.isDescendant(url.standardizedFileURL, of: launch.readAccessRootURL.standardizedFileURL) else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame != false {
                // Includes reloads to the identical URL: URL equality alone is
                // insufficient to authorize a pending download in a new document.
                invalidateDocumentAuthority()
            }
            decisionHandler(.allow)
        }

        public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                            didBecome download: WKDownload) {
            guard isValid, documentReady, webView === ownedWebView,
                  navigationAction === pendingExportAction,
                  let session = exportSession,
                  navigationAction.request.url?.absoluteString == session.blobURL.absoluteString else {
                download.cancel(nil)
                return
            }
            pendingExportAction = nil
            session.accept(download, in: webView)
        }

        public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                            didBecome download: WKDownload) {
            // No MIME-triggered, remote, response-only, or implicit downloads.
            download.cancel(nil)
        }

        private func invalidateDocumentAuthority() {
            documentEpoch = UUID()
            documentReady = false
            // A dialog still up belongs to the document that is going away.
            // Answer it so WebKit's completion handler is never dropped.
            javaScriptDialogs?.broker.cancelAll()
            let oldPicker = mediaPicker
            mediaPicker = nil
            mediaPickerRequestID = nil
            oldPicker?.cancel()
            mediaLease?.close()
            mediaLease = nil
            pendingExportAction = nil
            // Do not drop the in-flight slot before the writer acknowledges
            // cancellation and the session has closed its temporary custody.
            exportSession?.cancel()
            onCloseHandleChange?(nil)
        }

        private func isCurrentDocument(_ webView: WKWebView, epoch: UUID, sourceURL: String) -> Bool {
            isValid && documentReady && documentEpoch == epoch && webView === ownedWebView
                && webView.window != nil && webView.url?.absoluteString == sourceURL
        }

        private func isCurrentCloseDocument(_ webView: WKWebView, epoch: UUID) -> Bool {
            // history.pushState/hash updates do not replace the actual document.
            // Preserve that document's fixed save hook without relaxing export
            // or picker URL binding. Any real navigation/reload rotates epoch.
            guard isValid, documentReady, documentEpoch == epoch,
                  webView === ownedWebView, webView.window != nil,
                  let url = webView.url, url.isFileURL else { return false }
            return Self.isDescendant(url.standardizedFileURL,
                                     of: launch.readAccessRootURL.standardizedFileURL)
        }

        private func publishCloseHandle(for webView: WKWebView) {
            let epoch = documentEpoch
            guard isCurrentCloseDocument(webView, epoch: epoch) else { return }
            let handle = NativeVerifiedDocumentCloseHandle(
                id: epoch,
                isCurrent: { [weak self, weak webView] in
                    guard let self, let webView else { return false }
                    return self.isCurrentCloseDocument(webView, epoch: epoch)
                },
                prepare: { [weak self, weak webView] completion in
                    guard let self, let webView,
                          self.isCurrentCloseDocument(webView, epoch: epoch) else {
                        completion(.failed)
                        return
                    }
                    // The return value is restricted by this fixed script itself.
                    // No app data, script text, argument, URL or error is returned
                    // to the shell. A malformed hook is not treated as absent.
                    let script = """
                    const hook = globalThis.__IRIS_PREPARE_CLOSE_V1__;
                    if (typeof hook === 'undefined') return null;
                    if (typeof hook !== 'function') return false;
                    try { return (await hook()) === true; } catch { return false; }
                    """
                    webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) {
                        [weak self, weak webView] result in
                        guard let self, let webView,
                              self.isCurrentCloseDocument(webView, epoch: epoch) else {
                            completion(.failed)
                            return
                        }
                        switch result {
                        case .success(let value) where value is NSNull:
                            completion(.noHook)
                        case .success(let value):
                            completion((value as? Bool) == true ? .ready : .failed)
                        case .failure:
                            completion(.failed)
                        }
                    }
                })
            onCloseHandleChange?(handle)
        }

        private static func presentExportNotice(_ message: String, in webView: WKWebView) {
            var responder: UIResponder? = webView
            while let next = responder?.next {
                if let controller = next as? UIViewController {
                    guard !controller.isBeingDismissed, controller.presentedViewController == nil else { return }
                    let alert = UIAlertController(title: "Media not saved", message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                    controller.present(alert, animated: true)
                    return
                }
                responder = next
            }
        }

        private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
            let candidateComponents = candidate.pathComponents
            let rootComponents = root.pathComponents
            guard candidateComponents.count > rootComponents.count else { return false }
            return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        }
    }
}
#endif
