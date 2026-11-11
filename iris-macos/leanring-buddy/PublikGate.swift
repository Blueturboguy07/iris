//
//  PublikGate.swift
//  leanring-buddy
//
//  The Sign in with publik window: the first window Iris shows, before the
//  menu bar panel, the eye and every window of its own. `Publik.swift` holds
//  the gate itself (the screens, the wallet poll, the stored choice); this file
//  draws one screen at a time and hands the pressed button back.
//
//  Closing the window quits Iris. There is no other way past the gate: the
//  menu bar panel does not exist yet, so a hidden window would leave a process
//  with nothing to show.
//

import AppKit
import SwiftUI

/// The SwiftUI adapter from publikhq.com/sdk/publik.swift.md: draws the screen
/// as a view and returns the button pressed. When the gate cancels the screen
/// (the wallet poll saw the sign-in), the screen is cleared and nil goes back.
@MainActor final class GateModel: ObservableObject, PublikGateUI {
    @Published var screen: Publik.Screen?
    private var pick: CheckedContinuation<String?, Never>?
    func show(_ s: Publik.Screen) async -> String? {
        await withTaskCancellationHandler { await withCheckedContinuation { c in pick?.resume(returning: nil); screen = s; pick = c } }
        onCancel: { Task { @MainActor in self.press(nil) } }
    }
    func press(_ action: String?) { pick?.resume(returning: action); pick = nil; if action == nil { screen = nil } }
    nonisolated func open(_ url: URL) { Task { @MainActor in NSWorkspace.shared.open(url) } }
}

/// One gate screen: the title, the body, the note and one button per action.
struct PublikGateView: View {
    @ObservedObject var model: GateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let screen = model.screen {
                Text(screen.title)
                    .font(.title2.weight(.semibold))
                Text(screen.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = screen.note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Spacer()
                    ForEach(Array(screen.buttons.enumerated()), id: \.offset) { index, button in
                        Button(button.label) { model.press(button.action) }
                            .keyboardShortcut(index == 0 ? .defaultAction : .cancelAction)
                    }
                }
                .padding(.top, 6)
            } else {
                Text("Sign in with publik")
                    .font(.title2.weight(.semibold))
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 440, alignment: .leading)
    }
}

/// Hosts `PublikGateView` in a plain AppKit window. Iris is an `LSUIElement`
/// app with no Dock icon, so a window it presents has to bring itself forward.
@MainActor final class PublikGateWindowController: NSObject, NSWindowDelegate {
    let model = GateModel()
    private var window: NSWindow?
    private let onClose: @MainActor () -> Void

    /// `onClose` runs when the person closes the window. The window stays open.
    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: PublikGateView(model: model))
            let gateWindow = NSWindow(contentViewController: hosting)
            gateWindow.title = "Sign in with publik"
            gateWindow.styleMask = [.titled, .closable]
            gateWindow.isReleasedWhenClosed = false
            gateWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            gateWindow.hidesOnDeactivate = false
            gateWindow.delegate = self
            gateWindow.center()
            window = gateWindow
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
}
