import Foundation

/// Native window.alert / window.confirm / window.prompt for hosted apps
/// (round 6, prep A; kneecap-bugpass DELETE_HOOKS.md).
///
/// Why this exists: the shell's web view delegate used to answer only the
/// file-picker request. With no delegate method for JavaScript dialogs, WebKit
/// answers the page at once without showing anything: `confirm()` returns
/// false, `alert()` returns, `prompt()` returns null. Kneecap's red Delete
/// button asked `confirm(...)` first, so every tap ended silently in a
/// `return` and projects (and their videos) could never be deleted.
///
/// This file is the part that has no UIKit and no WebKit in it, so it runs in
/// `swift test` on the Mac:
/// - `NativeJavaScriptDialogPolicy`: who may open a dialog (the same guards the
///   file-picker request uses).
/// - `NativeJavaScriptDialogBroker`: the one-at-a-time rule and the "WebKit
///   crashes the page if a completion handler is dropped or called twice" rule.
/// The WebKit delegate glue is in `NativeJavaScriptDialogWebKit.swift`; the
/// iPhone alert that actually shows the dialog is in the Host module.

/// What the page asked for.
public enum NativeJavaScriptDialogKind: Equatable, Sendable {
    case alert
    case confirm
    case prompt(defaultText: String?)
}

/// What the person did.
public enum NativeJavaScriptDialogAnswer: Equatable, Sendable {
    /// OK. For a prompt, the text in the field (empty string when left blank).
    case accept(text: String?)
    /// Cancel, dismissed, refused or torn down.
    case cancel
}

/// Who may open a dialog. Mirrors the guards of the file-picker request
/// (`runOpenPanelWith`): the shell's own web view, a fully committed document,
/// on screen, the main frame only, and that frame is the document the shell
/// launched (same URL as the web view, a file inside the app's content
/// folder). A subframe, another origin or a stale document is refused, and a
/// refused dialog is answered with the plain browser default (false / null),
/// never shown.
public enum NativeJavaScriptDialogPolicy {
    public static func allows(
        isValid: Bool,
        isOwnedWebView: Bool,
        documentReady: Bool,
        hasWindow: Bool,
        isMainFrame: Bool,
        frameURL: URL?,
        mainFrameURL: URL?,
        contentRoot: URL
    ) -> Bool {
        guard isValid, isOwnedWebView, documentReady, hasWindow, isMainFrame,
              let frameURL, let mainFrameURL,
              frameURL.isFileURL,
              frameURL.absoluteString == mainFrameURL.absoluteString else { return false }
        let root = contentRoot.standardizedFileURL.pathComponents
        let file = frameURL.standardizedFileURL.pathComponents
        return file.count > root.count && Array(file.prefix(root.count)) == root
    }

    /// The longest message the alert shows. A page can send megabytes.
    public static let maximumMessageCharacters = 2_000

    public static func displayText(_ message: String) -> String {
        message.count <= maximumMessageCharacters
            ? message
            : String(message.prefix(maximumMessageCharacters)) + "..."
    }
}

/// Shows one dialog. The iPhone implementation is a `UIAlertController`; tests
/// use a scripted one. `present` returns false when nothing could be shown
/// (no view on screen to present from), and then `respond` is never called.
@MainActor
public protocol NativeJavaScriptDialogPresenter: AnyObject {
    func present(
        kind: NativeJavaScriptDialogKind,
        message: String,
        respond: @escaping @MainActor (NativeJavaScriptDialogAnswer) -> Void
    ) -> Bool
    /// Remove the dialog from the screen without answering it.
    func dismissCurrent()
}

/// Enforces the rules WebKit needs. Every request is completed exactly once:
/// WebKit raises an exception when a completion handler is dropped and
/// misbehaves when it is called twice, and a page that is waiting on a dialog
/// is frozen until the handler runs.
@MainActor
public final class NativeJavaScriptDialogBroker {
    private struct Pending {
        let token: UUID
        let finish: (NativeJavaScriptDialogAnswer) -> Void
    }

    private let presenter: NativeJavaScriptDialogPresenter
    private var pending: Pending?

    public init(presenter: NativeJavaScriptDialogPresenter) {
        self.presenter = presenter
    }

    public var isShowingDialog: Bool { pending != nil }

    /// Shows the dialog when `allowed`, nothing else is showing and the
    /// presenter can show it; otherwise completes at once with `.cancel`.
    /// `completion` is called exactly once, on the main actor.
    public func present(
        kind: NativeJavaScriptDialogKind,
        message: String,
        allowed: Bool,
        completion: @escaping @MainActor (NativeJavaScriptDialogAnswer) -> Void
    ) {
        guard allowed, pending == nil else {
            completion(.cancel)
            return
        }
        let token = UUID()
        pending = Pending(token: token, finish: { answer in completion(answer) })
        let shown = presenter.present(
            kind: kind,
            message: NativeJavaScriptDialogPolicy.displayText(message)
        ) { [weak self] answer in
            // A late tap on a dialog that was already torn down does nothing.
            guard let self, let pending = self.pending, pending.token == token else { return }
            self.pending = nil
            pending.finish(answer)
        }
        if !shown, let stillPending = pending, stillPending.token == token {
            pending = nil
            stillPending.finish(.cancel)
        }
    }

    /// The document went away, the view is being torn down or the web content
    /// process ended: take the dialog off the screen and answer it with the
    /// default. Safe to call when nothing is showing.
    public func cancelAll() {
        guard let current = pending else { return }
        pending = nil
        presenter.dismissCurrent()
        current.finish(.cancel)
    }
}
