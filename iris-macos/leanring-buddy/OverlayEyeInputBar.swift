//
//  OverlayEyeInputBar.swift
//  leanring-buddy
//
//  The minimal text bar that appears under the eye when the eye is clicked:
//  one input, a few suggestion chips, nothing else.
//
//  WHY THIS IS ITS OWN WINDOW RATHER THAN PART OF THE OVERLAY. The overlay is
//  a full-screen, click-through, never-key window — deliberately so, because
//  everything the user clicks has to pass straight through it, and because it
//  must never take keyboard focus away from the app they are working in. A
//  text field needs the exact opposite of both. Putting the bar in its own
//  small `.nonactivatingPanel` gets both properties without compromising the
//  overlay: the panel is only as large as itself, so there is no click-through
//  question to answer, and a non-activating panel can become key *without
//  activating Iris*, so the user's app stays frontmost.
//
//  The tradeoff that remains: while the bar is open the user's own window
//  resigns key, so its caret stops blinking and its title bar dims — the same
//  thing Spotlight does, and the same thing the menu bar panel already does.
//  Ordering the panel out hands key status straight back, which is why
//  dismissal is an `orderOut` rather than a hide-behind-alpha.
//

import AppKit
import SwiftUI

// MARK: - The panel

/// An `NSPanel` that may become key. `.nonactivatingPanel` on its own gets
/// mouse events without activating the app but leaves `canBecomeKey` false for
/// a borderless panel, and a text field in a window that cannot be key never
/// sees a keystroke.
private final class OverlayEyeInputBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the input bar's window: shows it under the eye, dismisses it on a
/// click anywhere else, and tells the overlay when it has gone so the gear can
/// turn back into an eye.
///
/// One of these exists per screen overlay, created by `OverlayWindowManager`
/// alongside the window it belongs to.
@MainActor
final class OverlayEyeInputBarPanelManager {

    private var inputBarPanel: NSPanel?
    private var clickOutsideMonitor: Any?

    /// Told to the overlay whenever the bar goes away for any reason, so the
    /// eye's activation state and the bar's actual visibility cannot drift
    /// apart.
    private var notifyTheOverlayThatTheBarClosed: (() -> Void)?

    init() {}

    var isShowingTheInputBar: Bool {
        inputBarPanel?.isVisible == true
    }

    /// Puts the bar on screen directly under the eye.
    func showInputBar(
        forEyeAtInteractionGeometry interactionGeometry: OverlayEyeInteractionGeometry,
        onScreenWithFrame screenFrame: CGRect,
        companionManager: CompanionManager,
        onTheBarClosing: @escaping () -> Void
    ) {
        notifyTheOverlayThatTheBarClosed = onTheBarClosing

        let inputBarView = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: { [weak self] in
                self?.hideInputBar()
            }
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: inputBarView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: hostingView.fittingSize.height
        )

        let panel = OverlayEyeInputBarPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // The same level as the overlay it hangs from, so the bar and the eye
        // stay together above everything else on the desktop.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        let barSize = CGSize(
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: hostingView.fittingSize.height
        )
        panel.setContentSize(barSize)
        panel.setFrameOrigin(interactionGeometry.inputBarOriginInAppKitScreenCoordinates(
            barSize: barSize,
            onScreenWithFrame: screenFrame
        ))

        inputBarPanel = panel
        panel.makeKeyAndOrderFront(nil)
        installClickOutsideMonitor()
    }

    /// Takes the bar down and hands keyboard focus back to whatever had it.
    func hideInputBar() {
        removeClickOutsideMonitor()

        if let inputBarPanel {
            // `orderOut` is what returns key status to the previously key
            // window. Hiding the panel any other way would leave Iris holding
            // the keyboard with nothing focused to receive it.
            inputBarPanel.orderOut(nil)
            inputBarPanel.contentView = nil
            self.inputBarPanel = nil
        }

        let closeCallback = notifyTheOverlayThatTheBarClosed
        notifyTheOverlayThatTheBarClosed = nil
        closeCallback?()
    }

    // MARK: Click outside

    /// A click in any other application dismisses the bar. Clicks on the eye
    /// itself are not seen here — a global monitor only reports events headed
    /// for *other* apps — which is exactly right, because clicking the gear
    /// must open settings without closing the bar behind it.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hideInputBar()
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}

// MARK: - The bar itself

/// One input and a few suggestion chips. There is no header, no close button
/// and no border around the whole thing on purpose: anything more turns an
/// attachment to the eye into a second panel, and Iris already has a panel.
struct OverlayEyeInputBarView: View {

    @ObservedObject var companionManager: CompanionManager

    /// Observed separately from the companion manager because the guide is its
    /// own object, and the suggestions have to follow the step the reader is
    /// actually on rather than the step they were on when the bar opened.
    @ObservedObject var guideSessionController: GuideSessionController

    let onDismissRequested: () -> Void

    @State private var typedMessage: String = ""
    @FocusState private var theTextFieldHasKeyboardFocus: Bool

    private var suggestionsToOffer: [String] {
        OverlayEyeSuggestions.suggestions(
            forOpenGuideStepTitled: guideSessionController.stepTheReaderIsLookingAt?.title
        )
    }

    private var thereIsSomethingToSend: Bool {
        !typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            textField
            suggestionChips
        }
        // The bar is dismissed the way every transient input on macOS is.
        .onKeyPress(.escape) {
            onDismissRequested()
            return .handled
        }
        .onAppear {
            // The panel has to be key before the field can take focus, and it
            // becomes key one runloop turn after it is ordered front.
            DispatchQueue.main.async {
                theTextFieldHasKeyboardFocus = true
            }
        }
    }

    private var textField: some View {
        HStack(spacing: 8) {
            TextField("Ask Iris…", text: $typedMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.ink)
                .focused($theTextFieldHasKeyboardFocus)
                .onSubmit {
                    sendWhatIsTyped()
                }
                .overlay(IBeamCursorView())

            Button {
                sendWhatIsTyped()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(thereIsSomethingToSend ? DS.Colors.accent : DS.Colors.quiet)
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: thereIsSomethingToSend)
            .disabled(!thereIsSomethingToSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(IrisShellBackground(cornerRadius: DS.CornerRadius.extraLarge))
    }

    /// Stacked rather than laid out in a row: a row of chips either overflows a
    /// 320pt bar or has to be truncated to fit it, and a suggestion the reader
    /// cannot finish reading is not a suggestion.
    ///
    /// Each chip carries its own glass shell rather than sharing one card. A
    /// card would be the panel chrome this bar is meant not to have — but pale
    /// text with nothing behind it is illegible the moment the desktop under it
    /// is bright, so the backdrop goes on the chips themselves.
    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestionsToOffer, id: \.self) { suggestion in
                Button {
                    send(suggestion)
                } label: {
                    Text(suggestion)
                        .lineLimit(1)
                }
                .irisTinyButton()
                .background(IrisShellBackground(cornerRadius: DS.CornerRadius.small))
            }
        }
        .padding(.leading, 4)
    }

    // MARK: Sending

    private func sendWhatIsTyped() {
        guard thereIsSomethingToSend else { return }
        send(typedMessage)
    }

    /// Everything the bar sends goes through `sendUserMessage` — the one
    /// pipeline the panel's own input already uses — so there is no second
    /// route to Claude to keep in step with the first.
    private func send(_ messageText: String) {
        companionManager.sendUserMessage(messageText)
        typedMessage = ""
        // The answer is rendered in the menu bar panel, so bring that forward;
        // without it a question typed at the eye would appear to go nowhere.
        NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
        onDismissRequested()
    }
}
