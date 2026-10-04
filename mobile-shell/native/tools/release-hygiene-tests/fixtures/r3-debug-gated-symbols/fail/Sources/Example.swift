import WebKit

#if os(iOS)
struct ReleaseSafeThing {
    func run() {
        #if DEBUG
        final class LogHandler: NSObject, WKScriptMessageHandler {
            func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
        }
        let controller = WKUserContentController()
        controller.add(LogHandler(), name: "irisDebugLog")
        #else
        print("release build: no debug bridge installed")
        #endif
    }

    func configureWebView(_ webView: WKWebView) {
        webView.isInspectable = true
        #if DEBUG
        #endif
    }
}
#endif

#if DEBUG
struct DebugMenu {
    var body: some View {
        Button("Import local package") { }
        Button("Review demo") { }
    }
}
#endif
