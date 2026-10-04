#if os(iOS)
import SwiftUI
import UIKit

struct NativeConfirmationAction {
    let title: String
    var style: UIAlertAction.Style = .default
    let identifier: String
    let perform: @MainActor () -> Void
}

extension View {
    /// Keep system confirmation roles and action identifiers on UIAlertAction.
    /// The host does not inspect or modify the system alert's private views.
    func nativeConfirmationAlert(
        _ title: String,
        message: String,
        isPresented: Binding<Bool>,
        actions: [NativeConfirmationAction]
    ) -> some View {
        background(NativeConfirmationAnchor(title: title, message: message,
                                            isPresented: isPresented, actions: actions)
            .frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct NativeConfirmationAnchor: UIViewControllerRepresentable {
    let title: String
    let message: String
    @Binding var isPresented: Bool
    let actions: [NativeConfirmationAction]

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configuration = self
        controller.synchronize()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.dismissOwnAlert()
    }

    @MainActor
    final class Controller: UIViewController {
        var configuration: NativeConfirmationAnchor?
        private var alert: UIAlertController?

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            synchronize()
        }

        func synchronize() {
            guard let configuration else { return }
            guard configuration.isPresented else {
                dismissOwnAlert()
                return
            }
            guard alert == nil, var presenter = viewIfLoaded?.window?.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }
            guard !(presenter is UIAlertController), !presenter.isBeingDismissed,
                  !presenter.isBeingPresented else { return }
            let next = UIAlertController(title: configuration.title, message: configuration.message,
                                         preferredStyle: .alert)
            for action in configuration.actions {
                let item = UIAlertAction(title: action.title, style: action.style) { [weak self] _ in
                    self?.alert = nil
                    action.perform()
                    if configuration.isPresented { configuration.isPresented = false }
                }
                item.accessibilityIdentifier = action.identifier
                next.addAction(item)
                if action.style == .cancel { next.preferredAction = item }
            }
            alert = next
            presenter.present(next, animated: true)
        }

        func dismissOwnAlert() {
            let current = alert
            alert = nil
            current?.dismiss(animated: false)
        }
    }
}
#endif
