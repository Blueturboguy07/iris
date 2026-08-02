//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
    /// Posted by CompanionManager when the global summon hotkey (ctrl + option)
    /// is pressed — toggles the companion panel open/closed.
    static let clickyTogglePanel = Notification.Name("clickyTogglePanel")
    /// Posted when the panel's SwiftUI content changes height on its own — the
    /// guide opening, closing, or moving to a longer step. The panel only
    /// measures its content when it is shown, so without this the new content
    /// renders clipped inside a panel still shaped for the old content.
    static let clickyResizePanelToContent = Notification.Name("clickyResizePanelToContent")
    /// Posted when an `iris://guide/…` link arrives and the panel has to come
    /// forward to show it, whether or not it was already open.
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var togglePanelObserver: NSObjectProtocol?
    private var resizePanelToContentObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        togglePanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyTogglePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.togglePanel()
        }

        resizePanelToContentObserver = NotificationCenter.default.addObserver(
            forName: .clickyResizePanelToContent,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // SwiftUI has not laid the new content out yet at the moment the
            // state changes, so the re-measure waits for the next runloop turn.
            DispatchQueue.main.async {
                guard let self, self.panel?.isVisible == true else { return }
                self.positionPanelBelowStatusItem()
            }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = togglePanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = resizePanelToContentObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeIrisMenuBarIcon()
        button.image?.isTemplate = true
        button.toolTip = "Iris — press ctrl + option to toggle"
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the Iris eye as a template menu bar icon: the almond lid with a
    /// filled iris — the same mark the panel header animates, tilted the same
    /// 7 degrees the stylesheet tilts it.
    private func makeIrisMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let rotation = NSAffineTransform()
        rotation.translateX(by: iconSize / 2, yBy: iconSize / 2)
        // AppKit's Y axis points up, so +7° here is the stylesheet's -7° tilt.
        rotation.rotate(byDegrees: 7)
        rotation.translateX(by: -iconSize / 2, yBy: -iconSize / 2)

        let lidPath = NSBezierPath(ovalIn: NSRect(x: 1.75, y: 4.75, width: 14.5, height: 8.5))
        lidPath.lineWidth = 1.5
        lidPath.transform(using: rotation as AffineTransform)
        NSColor.black.setStroke()
        lidPath.stroke()

        let irisPath = NSBezierPath(ovalIn: NSRect(
            x: iconSize / 2 - 2.4,
            y: iconSize / 2 - 2.4,
            width: 4.8,
            height: 4.8
        ))
        NSColor.black.setFill()
        irisPath.fill()

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    /// Toggles the panel open/closed. Used by both the status item click
    /// and the global summon hotkey.
    private func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        let targetPanelFrame = NSRect(
            x: panelOriginX,
            y: panelOriginY,
            width: panelWidth,
            height: actualPanelHeight
        )

        if panel.isVisible && panel.frame != targetPanelFrame {
            // The content changed shape while the panel is up — a guide opening,
            // a longer step. Glide to the new frame with the same ease-out cubic
            // the Tauri pill used for its `glide_iris` movement (24 frames at
            // 12ms, eased 1-(1-t)^3), instead of snapping.
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.28
                animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1.0, 0.68, 1.0)
                panel.animator().setFrame(targetPanelFrame, display: true)
            }
        } else {
            panel.setFrame(targetPanelFrame, display: true)
        }
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
