#if os(iOS)
import IrisMobileShellCore
import SwiftUI
import UIKit

/// The app owns the whole screen. The only Host chrome is a small movable Home
/// control; it never reserves a toolbar row or recreates the verified WebView.
struct NativeFullscreenAppView<Pending: View>: View {
    let launch: VerifiedLaunchDescriptor
    let adapter: IrisPackagedAPIAdapterConfiguration
    let presentationID: UUID
    let hasLoadFailure: Bool
    let onLoadResult: (NativeShellWebLoadResult) -> Void
    let onClose: () -> Void
    var permissionStore: NativePermissionStore? = nil
    /// The app's own display name, for the Home confirmation's title and
    /// message. Whatever supplies it (currently `NativeShellAppModel.launchDisplayName`)
    /// sometimes has nothing better than a placeholder; `resolvedAppDisplayName`
    /// below falls back to "this app" rather than showing a blank name.
    var displayName: String = ""
    @ViewBuilder let pendingRequest: (@escaping () -> Void) -> Pending
    @State private var homeAnchor: CGPoint?
    @GestureState private var homeDrag = CGSize.zero
    @State private var windowSafeArea = NativeWindowSafeAreaState()
    @State private var documentCloseHandle: NativeVerifiedDocumentCloseHandle?
    @State private var unavailableDocumentID = UUID()
    @State private var closeLifecycle: NativeAppCloseLifecycle?
    @State private var closeState: NativeAppCloseLifecycle.State = .idle
    @State private var homeConfirm = NativeHomeConfirmState()
    @State private var isHomeConfirmPresented = false
    /// Which phase this app session is in (M7, wired by R2-mobile-integration).
    /// Home never starts closing while an export is still writing a file.
    @State private var session = NativeFullscreenSessionLifecycle()
    @State private var isStillSavingNoticePresented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { viewport in
            let anchor = NativeHomeControlGeometry.clamp(
                homeAnchor ?? CGPoint(x: viewport.size.width - 28, y: viewport.size.height * 0.5),
                to: viewport.size,
                safeAreaInsets: windowSafeArea.insets)
            ZStack(alignment: .top) {
                VerifiedRevisionWebView(launch: launch, packagedAPIAdapter: adapter,
                    onLoadResult: receivedLoadResult, onCloseHandleChange: receivedCloseHandle,
                    permissionStore: permissionStore,
                    onExportActivityChange: receivedExportActivity)
                    .id(presentationID)
                    .frame(width: viewport.size.width, height: viewport.size.height)
                    .accessibilityIdentifier("iris.open.fullscreen-content")
                    .allowsHitTesting(closeState == .idle)
                    .overlay(alignment: .top) {
                        if hasLoadFailure {
                            Text("This app could not finish loading. Use Home to return to Iris and try again.")
                                .font(.callout).padding().frame(maxWidth: .infinity)
                                .background(.regularMaterial)
                                .accessibilityIdentifier("iris.open.load-failed")
                        }
                    }

                Button(action: requestHomeConfirm) {
                    Image(systemName: "house.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go back to Iris home")
                .accessibilityHint("Drag this button to move it away from app controls.")
                .accessibilityIdentifier("iris.open.done")
                .disabled(closeState != .idle)
                .position(NativeHomeControlGeometry.clamp(
                    CGPoint(x: anchor.x + homeDrag.width, y: anchor.y + homeDrag.height),
                    to: viewport.size,
                    safeAreaInsets: windowSafeArea.insets))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8)
                        .updating($homeDrag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            homeAnchor = NativeHomeControlGeometry.clamp(
                                CGPoint(x: anchor.x + value.translation.width, y: anchor.y + value.translation.height),
                                to: viewport.size,
                                safeAreaInsets: windowSafeArea.insets)
                        }
                )
            }
        }
        .background {
            NativeWindowSafeAreaInsetsReader { event in
                var next = windowSafeArea
                next.apply(event)
                if next != windowSafeArea {
                    windowSafeArea = next
                }
            }
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) { pendingRequest(requestClose) }
        .overlay { closeOverlay }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativeMarketplaceStyle.paper)
        .ignoresSafeArea(.container)
        .interactiveDismissDisabled()
        .nativeConfirmationAlert("Go back to Iris home?",
            message: "You will leave \(resolvedAppDisplayName) and return to your Iris Apps library. \(resolvedAppDisplayName) keeps your work.",
            isPresented: $isHomeConfirmPresented, actions: [
                NativeConfirmationAction(title: "Stay in \(resolvedAppDisplayName)", style: .cancel,
                    identifier: "iris.open.home-confirm.stay") { homeConfirm.cancel(for: homeConfirmToken) },
                NativeConfirmationAction(title: "Go to Iris home", identifier: "iris.open.home-confirm.go") {
                    if homeConfirm.confirm(for: homeConfirmToken) { requestClose() }
                }
            ])
        .alert("Your file is still saving", isPresented: $isStillSavingNoticePresented) {
            Button("OK", role: .cancel) {}
                .accessibilityIdentifier("iris.open.still-saving.ok")
        } message: {
            Text("\(resolvedAppDisplayName) is still saving your export. Wait until it finishes, then go back to Iris home.")
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: session.apply(.didEnterBackground)
            case .active: session.apply(.willEnterForeground)
            default: break
            }
        }
        .onChange(of: closeState) { state in
            // "Keep editing" returns the close decision to idle: the app is
            // running again, so an export started after this is protected.
            if state == .idle, session.state == .closing { session.apply(.closeCancelled) }
        }
        .onChange(of: isHomeConfirmPresented) { presented in
            // Covers any dismissal that did not go through one of the two
            // buttons above (for example the system tearing the alert down
            // on its own): the pure state must not be left thinking a
            // confirmation is still open once the alert is gone.
            if !presented { homeConfirm.cancel(for: homeConfirmToken) }
        }
        .onChange(of: presentationID) { _ in
            NativeAudioSessionPolicy.shared.appDidOpen(presentationID: presentationID, requestedCapabilities: launch.requestedCapabilities)
            if let token = closeLifecycle?.currentToken { closeLifecycle?.invalidate(for: token) }
            closeLifecycle = nil
            documentCloseHandle = nil
            unavailableDocumentID = UUID()
            closeState = .idle
            // A different app now occupies this same view identity (or this
            // one relaunched): any Home confirmation left open belonged to
            // the app that just left, so it must not linger or act.
            homeConfirm.presentationChanged(to: NativeHomeConfirmToken(presentationID: presentationID))
            isHomeConfirmPresented = false
            session = NativeFullscreenSessionLifecycle()
            isStillSavingNoticePresented = false
        }
        .onDisappear {
            NativeAudioSessionPolicy.shared.appDidClose(presentationID: presentationID)
            if let token = closeLifecycle?.currentToken { closeLifecycle?.invalidate(for: token) }
            closeLifecycle = nil
            documentCloseHandle = nil
            homeConfirm.presentationChanged(to: nil)
            isHomeConfirmPresented = false
        }
        .onAppear {
            NativeAudioSessionPolicy.shared.appDidOpen(presentationID: presentationID, requestedCapabilities: launch.requestedCapabilities)
        }
    }

    @MainActor
    private var closeToken: NativeAppCloseToken {
        NativeAppCloseToken(presentationID: presentationID,
                           documentHandle: documentCloseHandle?.id ?? unavailableDocumentID)
    }

    @MainActor
    private func receivedCloseHandle(_ handle: NativeVerifiedDocumentCloseHandle?) {
        documentCloseHandle = handle
        closeLifecycle?.updateToken(closeToken)
    }

    private func receivedLoadResult(_ result: NativeShellWebLoadResult) {
        // A failed load stays in `.opening`, where Home always closes: the
        // reader is told "Use Home to return" and must never be trapped.
        if result == .loaded { session.apply(.openFinished) }
        onLoadResult(result)
    }

    private func receivedExportActivity(inFlight: Bool, failed: Bool) {
        session.apply(inFlight ? .exportStarted : .exportEnded(failed ? .failed : .succeeded))
    }

    @MainActor
    private func requestClose() {
        // CLICK-PATH-002: the session decides first. Mid export (or mid save)
        // closing never starts; the reader is told to wait instead.
        guard session.beginClose() else {
            // Presented on the next turn so it never collides with the Home
            // confirmation that may still be dismissing.
            DispatchQueue.main.async { isStillSavingNoticePresented = true }
            return
        }
        let lifecycle: NativeAppCloseLifecycle
        if let existing = closeLifecycle {
            lifecycle = existing
        } else {
            lifecycle = NativeAppCloseLifecycle(timeoutNanoseconds: 5_000_000_000) { closeState = $0 }
            closeLifecycle = lifecycle
        }
        let token = closeToken
        let handle = documentCloseHandle
        lifecycle.updateToken(token)
        lifecycle.requestClose(for: token, evaluate: { completion in
            guard let handle, handle.isCurrent() else { completion(.failed); return }
            handle.prepare(completion)
        }, onClose: {
            guard closeToken == token else { return }
            session.apply(.closeFinished)
            onClose()
        })
    }

    /// `displayName` trimmed, or "this app" when there is nothing usable to
    /// show. Never shows a blank name in the confirmation's title or body.
    private var resolvedAppDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this app" : trimmed
    }

    private var homeConfirmToken: NativeHomeConfirmToken {
        NativeHomeConfirmToken(presentationID: presentationID)
    }

    /// The floating Home button's action. It never closes the app directly;
    /// it only ever opens (or, on a hurried double tap, leaves open) the
    /// "Go back to Iris home?" confirmation. Dragging the button is a
    /// separate, higher-priority gesture (see the `.highPriorityGesture`
    /// below) that this action is never reached through.
    @MainActor
    private func requestHomeConfirm() {
        // Mid export there is nothing to confirm yet: say why Home waits.
        if session.isWriting {
            isStillSavingNoticePresented = true
            return
        }
        guard homeConfirm.requestConfirm(for: homeConfirmToken) else { return }
        isHomeConfirmPresented = true
    }

    @MainActor
    @ViewBuilder
    private var closeOverlay: some View {
        switch closeState {
        case .preparing, .warning:
            ZStack {
                Color.black.opacity(0.24).ignoresSafeArea()
                    .contentShape(Rectangle())
                VStack(spacing: 16) {
                    if closeState == .preparing {
                        ProgressView().accessibilityLabel("Preparing to close")
                        Text("Preparing to close…").font(.headline)
                        Text("Waiting for the app to finish saving.")
                            .font(.subheadline).multilineTextAlignment(.center)
                    } else {
                        Text("Changes may not be saved").font(.headline)
                        Text("Iris could not confirm that this app saved its latest changes. Keep editing, or return home without that confirmation.")
                            .font(.subheadline).multilineTextAlignment(.center)
                            .accessibilityIdentifier("iris.open.close-warning")
                    }
                    Button("Keep editing") { closeLifecycle?.keepEditing(for: closeToken) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("iris.open.keep-editing")
                    if case .warning = closeState {
                        Button("Return home anyway", role: .destructive) {
                            closeLifecycle?.discardAndClose(for: closeToken)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("iris.open.close-without-save-confirmation")
                    }
                }
                .padding(24).frame(maxWidth: 340)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(20)
            }
        case .idle, .closing:
            EmptyView()
        }
    }
}

enum NativeHomeControlGeometry {
    /// Keep the full 44-point hit target reachable after dragging or rotation.
    /// The extra six points separate it from the nearest reachable safe-area edge.
    /// No persistence or observation of the app's document is needed to position
    /// the Home control.
    static func clamp(
        _ point: CGPoint,
        to size: CGSize,
        safeAreaInsets: UIEdgeInsets = .zero
    ) -> CGPoint {
        let width = max(0, size.width), height = max(0, size.height)
        let xBounds = axisBounds(length: width,
                                 startSafeInset: safeAreaInsets.left,
                                 endSafeInset: safeAreaInsets.right)
        let yBounds = axisBounds(length: height,
                                 startSafeInset: safeAreaInsets.top,
                                 endSafeInset: safeAreaInsets.bottom)
        return CGPoint(x: min(max(point.x, xBounds.lowerBound), xBounds.upperBound),
                       y: min(max(point.y, yBounds.lowerBound), yBounds.upperBound))
    }

    private static func axisBounds(
        length: CGFloat,
        startSafeInset: CGFloat,
        endSafeInset: CGFloat
    ) -> ClosedRange<CGFloat> {
        guard length > 0 else { return 0 ... 0 }
        let minimumCenter = max(0, startSafeInset) + 28
        let maximumCenter = length - max(0, endSafeInset) - 28
        guard minimumCenter <= maximumCenter else {
            let center = length / 2
            return center ... center
        }
        return minimumCenter ... maximumCenter
    }
}

enum NativeWindowSafeAreaEventKind: Equatable {
    case attached
    case changed
    case detached
}

struct NativeWindowSafeAreaEvent: Equatable {
    let probeID: UUID
    let kind: NativeWindowSafeAreaEventKind
    let attachStamp: UInt64
    let insets: UIEdgeInsets
}

struct NativeWindowSafeAreaState: Equatable {
    private(set) var activeProbeID: UUID?
    private(set) var newestAttachStamp: UInt64 = 0
    private(set) var insets: UIEdgeInsets = .zero

    mutating func apply(_ event: NativeWindowSafeAreaEvent) {
        switch event.kind {
        case .attached:
            guard event.attachStamp >= newestAttachStamp else { return }
            newestAttachStamp = event.attachStamp
            activeProbeID = event.probeID
            insets = event.insets
        case .changed:
            guard activeProbeID == event.probeID else { return }
            insets = event.insets
        case .detached:
            guard activeProbeID == event.probeID else { return }
            activeProbeID = nil
            insets = .zero
        }
    }
}

struct NativeWindowSafeAreaInsetsReader: UIViewRepresentable {
    let onEvent: (NativeWindowSafeAreaEvent) -> Void

    func makeUIView(context: Context) -> NativeWindowSafeAreaObservationView {
        let view = NativeWindowSafeAreaObservationView()
        view.onEvent = onEvent
        return view
    }

    func updateUIView(_ uiView: NativeWindowSafeAreaObservationView, context: Context) {
        uiView.onEvent = onEvent
    }
}

final class NativeWindowSafeAreaObservationView: UIView {
    let probeID = UUID()
    var onEvent: ((NativeWindowSafeAreaEvent) -> Void)?

    private weak var observedWindow: UIWindow?
    private var isAttachedToWindow = false
    private var lastInsets: UIEdgeInsets?
    private var currentAttachStamp: UInt64 = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            isAttachedToWindow = true
            observedWindow = window
            currentAttachStamp = DispatchTime.now().uptimeNanoseconds
            lastInsets = window.safeAreaInsets
            enqueue(.attached, expectedWindow: window, attachStamp: currentAttachStamp)
        } else if isAttachedToWindow {
            isAttachedToWindow = false
            observedWindow = nil
            lastInsets = nil
            enqueueDetach(attachStamp: currentAttachStamp)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        enqueueChangedIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        enqueueChangedIfNeeded()
    }

    private func enqueueChangedIfNeeded() {
        guard let window else { return }
        let insets = window.safeAreaInsets
        guard observedWindow === window else {
            isAttachedToWindow = true
            observedWindow = window
            currentAttachStamp = DispatchTime.now().uptimeNanoseconds
            lastInsets = insets
            enqueue(.attached, expectedWindow: window, attachStamp: currentAttachStamp)
            return
        }
        guard insets != lastInsets else { return }
        lastInsets = insets
        enqueue(.changed, expectedWindow: window, attachStamp: currentAttachStamp)
    }

    private func enqueue(
        _ kind: NativeWindowSafeAreaEventKind,
        expectedWindow: UIWindow,
        attachStamp: UInt64
    ) {
        Task { @MainActor [weak self, weak expectedWindow] in
            guard let self,
                  let expectedWindow,
                  self.window === expectedWindow,
                  self.observedWindow === expectedWindow,
                  self.currentAttachStamp == attachStamp else { return }
            self.onEvent?(NativeWindowSafeAreaEvent(
                probeID: self.probeID,
                kind: kind,
                attachStamp: attachStamp,
                insets: expectedWindow.safeAreaInsets
            ))
        }
    }

    private func enqueueDetach(attachStamp: UInt64) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.window == nil,
                  !self.isAttachedToWindow,
                  self.observedWindow == nil,
                  self.currentAttachStamp == attachStamp else { return }
            self.onEvent?(NativeWindowSafeAreaEvent(
                probeID: self.probeID,
                kind: .detached,
                attachStamp: attachStamp,
                insets: .zero
            ))
        }
    }
}
#endif
