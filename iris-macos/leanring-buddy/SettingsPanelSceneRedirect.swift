import AppKit
import SwiftUI

/// SwiftUI still owns a Settings scene for system callers. Its host stays
/// invisible and immediately hands off to the one menu/eye settings panel.
/// This also handles callers that bypass the replaced Settings menu command.
struct SettingsPanelSceneRedirect: NSViewRepresentable {
    let onOpenSettings: () -> Void

    func makeNSView(context: Context) -> SettingsRedirectView {
        let view = SettingsRedirectView()
        view.onOpenSettings = onOpenSettings
        return view
    }

    func updateNSView(_ nsView: SettingsRedirectView, context: Context) {
        nsView.onOpenSettings = onOpenSettings
    }

    final class SettingsRedirectView: NSView {
        var onOpenSettings: () -> Void = {}
        private var windowBecameKeyObserver: NSObjectProtocol?
        private var redirectIsPending = false

        deinit {
            if let windowBecameKeyObserver {
                NotificationCenter.default.removeObserver(windowBecameKeyObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let windowBecameKeyObserver {
                NotificationCenter.default.removeObserver(windowBecameKeyObserver)
                self.windowBecameKeyObserver = nil
            }
            guard let window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.tabbingMode = .disallowed
            windowBecameKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRedirect() }
            }
            scheduleRedirect()
        }

        private func scheduleRedirect() {
            guard !redirectIsPending, let sceneWindow = window else { return }
            redirectIsPending = true
            let openSettings = onOpenSettings
            // Wait until the Settings scene finishes attaching its view before
            // closing that host. Alpha is already zero, so it cannot flash.
            DispatchQueue.main.async { [weak self, weak sceneWindow] in
                sceneWindow?.orderOut(nil)
                sceneWindow?.close()
                self?.redirectIsPending = false
                openSettings()
            }
        }
    }
}
