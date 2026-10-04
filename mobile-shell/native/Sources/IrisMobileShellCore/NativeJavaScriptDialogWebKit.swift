#if canImport(WebKit)
import Foundation
import WebKit

/// The WebKit side of `NativeJavaScriptDialogBroker`: three `WKUIDelegate`
/// methods that turn WebKit's callbacks into broker requests. The Host's
/// `VerifiedRevisionWebView.Coordinator` forwards its own `WKUIDelegate`
/// methods here, and the Mac tests use this same object as the delegate of a
/// real `WKWebView`, so the page-visible return value of `confirm()`,
/// `alert()` and `prompt()` is tested through the code that ships.
///
/// `isAllowed` answers "may this frame open a dialog?" (see
/// `NativeJavaScriptDialogPolicy`); the Host builds it from the coordinator's
/// own state.
@MainActor
public final class NativeJavaScriptDialogUIDelegate: NSObject, WKUIDelegate {
    public let broker: NativeJavaScriptDialogBroker
    private let isAllowed: @MainActor (WKWebView, WKFrameInfo) -> Bool

    public init(
        broker: NativeJavaScriptDialogBroker,
        isAllowed: @escaping @MainActor (WKWebView, WKFrameInfo) -> Bool
    ) {
        self.broker = broker
        self.isAllowed = isAllowed
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        broker.present(kind: .alert, message: message, allowed: isAllowed(webView, frame)) { _ in
            completionHandler()
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        broker.present(kind: .confirm, message: message, allowed: isAllowed(webView, frame)) { answer in
            if case .accept = answer { completionHandler(true) } else { completionHandler(false) }
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        broker.present(
            kind: .prompt(defaultText: defaultText), message: prompt, allowed: isAllowed(webView, frame)
        ) { answer in
            if case let .accept(text) = answer { completionHandler(text ?? "") } else { completionHandler(nil) }
        }
    }
}
#endif
