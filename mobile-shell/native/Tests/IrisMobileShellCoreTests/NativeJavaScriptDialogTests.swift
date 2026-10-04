import XCTest
@testable import IrisMobileShellCore
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// A scripted stand-in for the iPhone alert: it records what the person would
/// have seen and answers the way a person would, when told to.
@MainActor
final class ScriptedDialogPresenter: NativeJavaScriptDialogPresenter {
    struct Shown: Equatable { let kind: NativeJavaScriptDialogKind; let message: String }
    var shown: [Shown] = []
    var dismissCount = 0
    /// Answers handed out in order. Empty means "leave the dialog open".
    var answers: [NativeJavaScriptDialogAnswer] = []
    var canShow = true
    private(set) var heldRespond: (@MainActor (NativeJavaScriptDialogAnswer) -> Void)?

    func present(
        kind: NativeJavaScriptDialogKind,
        message: String,
        respond: @escaping @MainActor (NativeJavaScriptDialogAnswer) -> Void
    ) -> Bool {
        guard canShow else { return false }
        shown.append(Shown(kind: kind, message: message))
        if answers.isEmpty {
            heldRespond = respond
        } else {
            // A person takes a moment; answer on the next turn of the run loop.
            let answer = answers.removeFirst()
            DispatchQueue.main.async { respond(answer) }
        }
        return true
    }

    func dismissCurrent() { dismissCount += 1 }

    /// The late tap of a person on a dialog the shell already took down.
    func tapNow(_ answer: NativeJavaScriptDialogAnswer) { heldRespond?(answer) }
}

// MARK: - Broker and policy (no WebKit)

@MainActor
final class NativeJavaScriptDialogBrokerTests: XCTestCase {
    func testAcceptedDialogCompletesOnceWithTheAnswer() {
        let presenter = ScriptedDialogPresenter()
        presenter.answers = [.accept(text: nil)]
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        let done = expectation(description: "completed")
        var answers: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .confirm, message: "Delete?", allowed: true) { answer in
            answers.append(answer)
            done.fulfill()
        }
        XCTAssertTrue(broker.isShowingDialog)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(answers, [.accept(text: nil)])
        XCTAssertFalse(broker.isShowingDialog)
        XCTAssertEqual(presenter.shown, [.init(kind: .confirm, message: "Delete?")])
    }

    func testRefusedRequestIsAnsweredCancelAndNeverShown() {
        let presenter = ScriptedDialogPresenter()
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        var answers: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .confirm, message: "x", allowed: false) { answers.append($0) }
        XCTAssertEqual(answers, [.cancel])
        XCTAssertTrue(presenter.shown.isEmpty)
        XCTAssertFalse(broker.isShowingDialog)
    }

    func testASecondDialogWhileOneIsUpIsAnsweredCancelAndTheFirstStaysUp() {
        let presenter = ScriptedDialogPresenter()   // holds the first one open
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        var first: [NativeJavaScriptDialogAnswer] = []
        var second: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .confirm, message: "one", allowed: true) { first.append($0) }
        broker.present(kind: .confirm, message: "two", allowed: true) { second.append($0) }
        XCTAssertEqual(second, [.cancel])
        XCTAssertEqual(first, [])
        XCTAssertEqual(presenter.shown.map(\.message), ["one"])
        presenter.tapNow(.accept(text: nil))
        XCTAssertEqual(first, [.accept(text: nil)])
    }

    func testPresenterThatCannotShowAnswersCancelInsteadOfFreezingThePage() {
        let presenter = ScriptedDialogPresenter()
        presenter.canShow = false
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        var answers: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .alert, message: "x", allowed: true) { answers.append($0) }
        XCTAssertEqual(answers, [.cancel])
        XCTAssertFalse(broker.isShowingDialog)
    }

    func testTeardownAnswersTheOpenDialogOnceAndALateTapDoesNothing() {
        let presenter = ScriptedDialogPresenter()
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        var answers: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .confirm, message: "x", allowed: true) { answers.append($0) }
        broker.cancelAll()
        XCTAssertEqual(answers, [.cancel])
        XCTAssertEqual(presenter.dismissCount, 1)
        presenter.tapNow(.accept(text: nil))      // the tap that raced the teardown
        XCTAssertEqual(answers, [.cancel], "answered exactly once")
        broker.cancelAll()                        // nothing showing: quiet no-op
        XCTAssertEqual(presenter.dismissCount, 1)
    }

    func testAfterAnAnswerTheNextDialogCanShow() {
        let presenter = ScriptedDialogPresenter()
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        var answers: [NativeJavaScriptDialogAnswer] = []
        broker.present(kind: .alert, message: "a", allowed: true) { answers.append($0) }
        presenter.tapNow(.accept(text: nil))
        broker.present(kind: .alert, message: "b", allowed: true) { answers.append($0) }
        XCTAssertEqual(presenter.shown.map(\.message), ["a", "b"])
        XCTAssertTrue(broker.isShowingDialog)
    }

    func testAHugeMessageIsCutBeforeItReachesTheScreen() {
        let presenter = ScriptedDialogPresenter()
        let broker = NativeJavaScriptDialogBroker(presenter: presenter)
        let huge = String(repeating: "a", count: 50_000)
        broker.present(kind: .alert, message: huge, allowed: true) { _ in }
        let shownCount = presenter.shown.first?.message.count ?? 0
        XCTAssertLessThan(shownCount, 2_100)
        XCTAssertGreaterThan(shownCount, 1_000)
        XCTAssertEqual(NativeJavaScriptDialogPolicy.displayText("short"), "short")
    }
}

final class NativeJavaScriptDialogPolicyTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/var/app/content/rev1/content", isDirectory: true)
    private var page: URL { root.appendingPathComponent("index.html") }

    private func allows(
        valid: Bool = true, owned: Bool = true, ready: Bool = true, window: Bool = true, main: Bool = true,
        frame: URL? = nil, top: URL? = nil
    ) -> Bool {
        NativeJavaScriptDialogPolicy.allows(
            isValid: valid, isOwnedWebView: owned, documentReady: ready, hasWindow: window,
            isMainFrame: main, frameURL: frame ?? page, mainFrameURL: top ?? page, contentRoot: root
        )
    }

    func testTheLaunchedMainFrameMayAsk() { XCTAssertTrue(allows()) }

    func testEveryOtherCallerIsRefused() {
        XCTAssertFalse(allows(valid: false), "torn down")
        XCTAssertFalse(allows(owned: false), "not the shell's own web view")
        XCTAssertFalse(allows(ready: false), "document not committed")
        XCTAssertFalse(allows(window: false), "not on screen")
        XCTAssertFalse(allows(main: false), "a subframe")
        XCTAssertFalse(allows(frame: root.appendingPathComponent("other.html")), "frame is not the launched document")
        XCTAssertFalse(allows(frame: URL(string: "https://example.com/a")!, top: URL(string: "https://example.com/a")!), "a web page, not a file")
        let outside = URL(fileURLWithPath: "/var/app/content/rev2/content/index.html")
        XCTAssertFalse(allows(frame: outside, top: outside), "a file outside the app's content folder")
        let folder = URL(fileURLWithPath: "/var/app/content/rev1/content")
        XCTAssertFalse(allows(frame: folder, top: folder), "the folder itself is not a document")
    }
}

// MARK: - A real WKWebView; the page-visible return value is the oracle

#if canImport(WebKit) && canImport(AppKit)
@MainActor
final class NativeJavaScriptDialogRealWebViewTests: XCTestCase {
    private var root: URL!
    private var window: NSWindow!
    private var web: WKWebView!
    private var presenter: ScriptedDialogPresenter!
    private var broker: NativeJavaScriptDialogBroker!
    private var delegate: NativeJavaScriptDialogUIDelegate!
    private var documentReady = true
    private var navigationWaiter: NavigationWaiter!

    final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(); onFinish = nil }
    }

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsdialog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // One page, two roles. Loaded as the top document it embeds ITSELF in an
        // iframe (same URL as the web view, so only "is this the main frame?"
        // can tell the two apart). Loaded inside that iframe it asks confirm()
        // and alert() and reports what came back to the top document.
        try Data("""
        <html><body><script>
        if (window.top === window) {
          window.frameReport = null;
          window.addEventListener('message', function (e) { window.frameReport = e.data; });
          var kid = document.createElement('iframe');
          kid.src = location.href;
          document.body.appendChild(kid);
        } else {
          var c = confirm('from a frame');
          alert('frame alert');
          parent.postMessage({frameConfirm: c, alertReturned: true}, '*');
        }
        </script></body></html>
        """.utf8).write(to: root.appendingPathComponent("index.html"))

        presenter = ScriptedDialogPresenter()
        broker = NativeJavaScriptDialogBroker(presenter: presenter)
        let page = root.appendingPathComponent("index.html")
        let contentRoot = root!
        delegate = NativeJavaScriptDialogUIDelegate(broker: broker) { [unowned self] webView, frame in
            NativeJavaScriptDialogPolicy.allows(
                isValid: true, isOwnedWebView: webView === self.web, documentReady: self.documentReady,
                hasWindow: webView.window != nil, isMainFrame: frame.isMainFrame,
                frameURL: frame.request.url, mainFrameURL: webView.url, contentRoot: contentRoot
            )
        }
        web = try await loadPage(page, into: nil)
    }

    override func tearDown() async throws {
        broker.cancelAll()
        window?.contentView = nil
        web = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func loadPage(_ page: URL, into existing: WKWebView?) async throws -> WKWebView {
        let view = existing ?? WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WKWebViewConfiguration())
        view.uiDelegate = delegate
        navigationWaiter = NavigationWaiter()
        view.navigationDelegate = navigationWaiter
        if existing == nil {
            // Before the load starts: the page's own scripts (the child frame's
            // dialogs) run during the load, and the delegate must already know
            // this is the shell's own web view.
            web = view
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = view
        }
        let loaded = expectation(description: "loaded")
        navigationWaiter.onFinish = { loaded.fulfill() }
        view.loadFileURL(page, allowingReadAccessTo: root)
        await fulfillment(of: [loaded], timeout: 10)
        return view
    }

    /// What the page itself sees: runs the snippet in the page and returns its
    /// value. A page frozen because a dialog was never answered fails the test
    /// after `timeout` seconds instead of hanging the suite.
    private func page(_ script: String, in view: WKWebView? = nil, timeout: TimeInterval = 8) async throws -> Any? {
        let target = view ?? web!
        let done = expectation(description: "page script returned")
        var outcome: Result<Any?, Error>?
        target.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            outcome = result.map { Optional($0) }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: timeout)
        guard let outcome else {
            XCTFail("the page never got an answer (frozen on a dialog): \(script)")
            return nil
        }
        return try outcome.get()
    }

    /// The child frame's dialog runs during page load; wait for its report. A
    /// page that froze on a dialog stops the wait at once instead of retrying.
    private func frameReport() async throws -> [String: Any]? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let value = try await page("return window.frameReport", timeout: 3)
            if let report = value as? [String: Any] { return report }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: confirm

    func testConfirmReturnsTrueWhenThePersonTapsOK() async throws {
        presenter.answers = [.accept(text: nil)]
        let value = try await page("return confirm('Delete \"Holiday\"? This cannot be undone.')")
        XCTAssertEqual(value as? Bool, true)
        XCTAssertEqual(presenter.shown, [.init(kind: .confirm, message: "Delete \"Holiday\"? This cannot be undone.")])
    }

    func testConfirmReturnsFalseWhenThePersonTapsCancel() async throws {
        presenter.answers = [.cancel]
        let value = try await page("return confirm('Delete?')")
        XCTAssertEqual(value as? Bool, false)
        XCTAssertEqual(presenter.shown.count, 1, "the person was asked")
    }

    /// The reported bug in one line: the same call with nothing to show is
    /// false and never asked. This is the WebKit default the shell used to
    /// give every app.
    func testRefusedCallerGetsFalseAndThePersonIsNeverAsked() async throws {
        documentReady = false
        presenter.answers = [.accept(text: nil)]
        let value = try await page("return confirm('Delete?')")
        XCTAssertEqual(value as? Bool, false)
        XCTAssertTrue(presenter.shown.isEmpty)
    }

    // MARK: alert

    func testAlertShowsTheMessageAndThePageContinuesAfterOK() async throws {
        presenter.answers = [.accept(text: nil)]
        let value = try await page("alert('Saved to Photos'); return 'after'")
        XCTAssertEqual(value as? String, "after")
        XCTAssertEqual(presenter.shown, [.init(kind: .alert, message: "Saved to Photos")])
    }

    // MARK: prompt

    func testPromptReturnsWhatThePersonTyped() async throws {
        presenter.answers = [.accept(text: "Beach day")]
        let value = try await page("return prompt('Name this project', 'Untitled')")
        XCTAssertEqual(value as? String, "Beach day")
        XCTAssertEqual(presenter.shown, [.init(kind: .prompt(defaultText: "Untitled"), message: "Name this project")])
    }

    func testPromptLeftBlankIsAnEmptyStringAndCancelIsNull() async throws {
        presenter.answers = [.accept(text: "")]
        let blank = try await page("return prompt('Name?')")
        XCTAssertEqual(blank as? String, "")
        presenter.answers = [.cancel]
        let cancelled = try await page("return prompt('Name?') === null")
        XCTAssertEqual(cancelled as? Bool, true)
    }

    // MARK: a frame the shell does not own

    func testDialogsFromAChildFrameAreRefusedAndNeverShown() async throws {
        presenter.answers = [.accept(text: nil), .accept(text: nil)]   // a person would say yes to anything
        let report = try await frameReport()
        XCTAssertNotNil(report, "the child frame's script finished (its alert did not freeze the page)")
        XCTAssertEqual(report?["frameConfirm"] as? Bool, false, "refused: plain false")
        XCTAssertTrue(presenter.shown.isEmpty, "no dialog reached the screen for the child frame")
    }

    // MARK: the hand-test page (round6/mobile-prep/A/dialog-check.irisapp)

    /// The same page a tester installs by hand ("Dialog check"): three buttons,
    /// a grey box showing what the page got back. Tapping the buttons here
    /// (`click()` runs the page's own onclick) is the Mac twin of that hand test.
    func testTheDialogCheckPageShowsWhatThePersonAnswered() async throws {
        let html = """
        <!doctype html><meta charset=utf-8><title>Dialog check</title>
        <button id=c onclick="out.textContent='confirm returned: '+confirm('Delete Holiday? This cannot be undone.')">Ask confirm</button>
        <button id=a onclick="alert('Saved to your library');out.textContent='alert closed, page continued'">Show alert</button>
        <button id=p onclick="out.textContent='prompt returned: '+JSON.stringify(prompt('Name this project','Untitled'))">Ask for a name</button>
        <div id=out>Nothing asked yet.</div><script>var out=document.getElementById('out')</script>
        """
        let demo = root.appendingPathComponent("demo.html")
        try Data(html.utf8).write(to: demo)
        web = try await loadPage(demo, into: web)
        func tap(_ id: String, answer: NativeJavaScriptDialogAnswer) async throws -> String? {
            presenter.answers = [answer]
            return try await page("document.getElementById('\(id)').click(); return document.getElementById('out').textContent") as? String
        }
        let sayYes = try await tap("c", answer: .accept(text: nil))
        XCTAssertEqual(sayYes, "confirm returned: true")
        let sayNo = try await tap("c", answer: .cancel)
        XCTAssertEqual(sayNo, "confirm returned: false")
        let okd = try await tap("a", answer: .accept(text: nil))
        XCTAssertEqual(okd, "alert closed, page continued")
        let named = try await tap("p", answer: .accept(text: "Beach day"))
        XCTAssertEqual(named, "prompt returned: \"Beach day\"")
        let skipped = try await tap("p", answer: .cancel)
        XCTAssertEqual(skipped, "prompt returned: null")
        XCTAssertEqual(presenter.shown.count, 5)
    }

    // MARK: teardown and one at a time

    func testTearDownWhileTheDialogIsUpAnswersThePageWithFalse() async throws {
        // Leave the confirm open (no scripted answer), then tear down.
        let done = expectation(description: "page answered after teardown")
        var pageSaw: Bool?
        web.callAsyncJavaScript("return confirm('Still there?')", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result { pageSaw = value as? Bool }
            done.fulfill()
        }
        for _ in 0..<100 where !broker.isShowingDialog { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(broker.isShowingDialog, "the dialog reached the screen")
        broker.cancelAll()
        await fulfillment(of: [done], timeout: 8)
        XCTAssertEqual(pageSaw, false, "the page was answered with the browser default")
        XCTAssertEqual(presenter.dismissCount, 1)
        presenter.tapNow(.accept(text: nil))   // a late tap must not answer twice
    }

    func testADialogFromAnotherWebViewIsRefused() async throws {
        // Only the shell's own web view is allowed, so another view is refused outright.
        let other = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        other.uiDelegate = delegate
        let loaded = expectation(description: "other loaded")
        let waiter = NavigationWaiter()
        waiter.onFinish = { loaded.fulfill() }
        other.navigationDelegate = waiter
        other.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        await fulfillment(of: [loaded], timeout: 10)
        presenter.answers = [.accept(text: nil)]
        let value = try await page("return confirm('from another view')", in: other)
        XCTAssertEqual(value as? Bool, false)
        XCTAssertTrue(presenter.shown.isEmpty)
    }
}
#endif
