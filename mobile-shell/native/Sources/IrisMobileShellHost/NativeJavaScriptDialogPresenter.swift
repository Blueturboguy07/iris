#if os(iOS)
import IrisMobileShellCore
import UIKit

/// Shows a hosted app's `alert()`, `confirm()` and `prompt()` as a native iOS
/// alert, the way Safari does (round 6, prep A; DELETE_HOOKS.md). One alert at
/// a time is enforced by `NativeJavaScriptDialogBroker`; this type only knows
/// how to put one on screen and take it off again.
@MainActor
final class NativeAlertDialogPresenter: NativeJavaScriptDialogPresenter {
    private let anchorView: @MainActor () -> UIView?
    private weak var current: UIAlertController?

    init(anchorView: @escaping @MainActor () -> UIView?) {
        self.anchorView = anchorView
    }

    func present(
        kind: NativeJavaScriptDialogKind,
        message: String,
        respond: @escaping @MainActor (NativeJavaScriptDialogAnswer) -> Void
    ) -> Bool {
        guard var top = anchorView()?.window?.rootViewController else { return false }
        while let next = top.presentedViewController { top = next }
        // Presenting over a controller that is mid-transition is dropped by
        // UIKit without a callback, which would freeze the page. Refuse
        // instead; the page then gets the plain "cancel" answer.
        guard !top.isBeingDismissed, !top.isBeingPresented else { return false }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        switch kind {
        case .alert:
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in respond(.accept(text: nil)) })
        case .confirm:
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in respond(.cancel) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in respond(.accept(text: nil)) })
        case .prompt(let defaultText):
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in respond(.cancel) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                respond(.accept(text: alert?.textFields?.first?.text ?? ""))
            })
        }
        current = alert
        top.present(alert, animated: true)
        return true
    }

    func dismissCurrent() {
        let alert = current
        current = nil
        alert?.presentingViewController?.dismiss(animated: false)
    }
}
#endif
