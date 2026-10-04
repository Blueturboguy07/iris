#if os(iOS)
import Foundation
import WebKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class NativeAppCloseRuntimeTests: XCTestCase {
    func testActualOwnedDocumentCloseHookReturnsOnlyTypedOutcomes() async throws {
        let page = try await hostedPage()
        defer { page.host.close(); page.fixture.close() }
        let web = try XCTUnwrap(page.host.webView)
        let handle = try XCTUnwrap(page.box.handle)
        XCTAssertTrue(handle.isCurrent())
        let absent = await prepare(handle)
        XCTAssertEqual(absent, .noHook)
        _ = try await web.evaluateJavaScript("globalThis.__IRIS_PREPARE_CLOSE_V1__ = async () => true; true")
        let ready = await prepare(handle)
        XCTAssertEqual(ready, .ready)
        _ = try await web.evaluateJavaScript("globalThis.__IRIS_PREPARE_CLOSE_V1__ = async () => 'true'; true")
        let wrongType = await prepare(handle)
        XCTAssertEqual(wrongType, .failed)
        _ = try await web.evaluateJavaScript("globalThis.__IRIS_PREPARE_CLOSE_V1__ = 1; true")
        let malformed = await prepare(handle)
        XCTAssertEqual(malformed, .failed)
        _ = try await web.evaluateJavaScript("globalThis.__IRIS_PREPARE_CLOSE_V1__ = async () => { throw new Error('synthetic'); }; true")
        let rejected = await prepare(handle)
        XCTAssertEqual(rejected, .failed)
    }

    func testPendingActualPageSaveKeepsWebViewUntilAcknowledgedAndClosesOnce() async throws {
        let page = try await hostedPage()
        defer { page.host.close(); page.fixture.close() }
        let web = try XCTUnwrap(page.host.webView)
        let handle = try XCTUnwrap(page.box.handle)
        try await installPendingHook(in: web)
        let lifecycle = NativeAppCloseLifecycle(timeoutNanoseconds: 3_000_000_000)
        let token = NativeAppCloseToken(presentationID: UUID(), documentHandle: handle.id)
        lifecycle.updateToken(token)
        var closes = 0
        let leave: @MainActor () -> Void = { closes += 1; page.host.close() }
        lifecycle.requestClose(for: token, evaluate: handle.prepare, onClose: leave)
        lifecycle.requestClose(for: token, evaluate: handle.prepare, onClose: leave)
        try await waitForHookStart(in: web)
        XCTAssertEqual(lifecycle.state, .preparing)
        XCTAssertEqual(closes, 0)
        XCTAssertNotNil(web.window, "pending app storage must not tear down the live WebView")
        let starts = try await web.evaluateJavaScript("globalThis.closeHookStarts") as? Int
        XCTAssertEqual(starts, 1)
        _ = try await web.evaluateJavaScript("globalThis.finishSyntheticClose(true); true")
        try await waitUntil { closes == 1 }
        XCTAssertEqual(lifecycle.state, .closing)
        XCTAssertNil(page.host.webView)
        lifecycle.requestClose(for: token, evaluate: handle.prepare, onClose: leave)
        XCTAssertEqual(closes, 1)
    }

    func testActualPageTimeoutPreservesDocumentAndLateResultCannotCloseIt() async throws {
        let page = try await hostedPage()
        defer { page.host.close(); page.fixture.close() }
        let web = try XCTUnwrap(page.host.webView)
        let handle = try XCTUnwrap(page.box.handle)
        let originalURL = web.url
        try await installPendingHook(in: web)
        let lifecycle = NativeAppCloseLifecycle(timeoutNanoseconds: 100_000_000)
        let token = NativeAppCloseToken(presentationID: UUID(), documentHandle: handle.id)
        lifecycle.updateToken(token)
        var closes = 0
        lifecycle.requestClose(for: token, evaluate: handle.prepare, onClose: { closes += 1 })
        try await waitForHookStart(in: web)
        try await waitUntil { lifecycle.state == .warning(.timedOut) }
        XCTAssertEqual(closes, 0)
        XCTAssertNotNil(web.window)
        XCTAssertEqual(web.url, originalURL)
        _ = try await web.evaluateJavaScript("globalThis.finishSyntheticClose(true); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(lifecycle.state, .warning(.timedOut))
        lifecycle.keepEditing(for: token)
        XCTAssertEqual(lifecycle.state, .idle)
        XCTAssertTrue(handle.isCurrent())
    }

    func testActualSameURLReloadInvalidatesOldCloseHandleAndPendingDecision() async throws {
        let page = try await hostedPage()
        defer { page.box.changed = nil; page.host.close(); page.fixture.close() }
        let web = try XCTUnwrap(page.host.webView)
        let handle = try XCTUnwrap(page.box.handle)
        let originalURL = try XCTUnwrap(web.url)
        let presentation = UUID()
        let token = NativeAppCloseToken(presentationID: presentation, documentHandle: handle.id)
        let lifecycle = NativeAppCloseLifecycle(timeoutNanoseconds: 500_000_000)
        lifecycle.updateToken(token)
        page.box.changed = { [weak lifecycle] next in
            guard let lifecycle else { return }
            if let next {
                lifecycle.updateToken(.init(presentationID: presentation, documentHandle: next.id))
            } else if let old = lifecycle.currentToken {
                lifecycle.invalidate(for: old)
            }
        }
        try await installPendingHook(in: web)
        var closes = 0
        lifecycle.requestClose(for: token, evaluate: handle.prepare, onClose: { closes += 1 })
        try await waitForHookStart(in: web)
        XCTAssertNotNil(web.reload())
        try await waitUntil { page.box.handle.map { $0.id != handle.id && $0.isCurrent() } == true }
        XCTAssertEqual(web.url, originalURL)
        XCTAssertFalse(handle.isCurrent(), "same URL must not revive an older document token")
        let staleResult = await prepare(handle)
        XCTAssertEqual(staleResult, .failed)
        XCTAssertEqual(closes, 0)
        XCTAssertEqual(lifecycle.state, .idle)
    }

    func testDismantledActualDocumentCannotPrepareOrAuthorizeClose() async throws {
        let page = try await hostedPage()
        defer { page.host.close(); page.fixture.close() }
        let handle = try XCTUnwrap(page.box.handle)
        var callbacksDuringTeardown = 0
        page.box.changed = { _ in callbacksDuringTeardown += 1 }
        page.host.close()
        XCTAssertFalse(handle.isCurrent())
        let result = await prepare(handle)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(callbacksDuringTeardown, 0,
                       "SwiftUI graph destruction must not synchronously mutate the dying view's State")
        XCTAssertEqual(page.box.handle?.id, handle.id,
                       "a retained handle is revoked by coordinator lifetime, not by mutating torn-down UI")
    }

    func testSameDocumentHistoryChangeKeepsTheActualSaveHookReachable() async throws {
        let page = try await hostedPage()
        defer { page.host.close(); page.fixture.close() }
        let web = try XCTUnwrap(page.host.webView)
        let originalHandle = try XCTUnwrap(page.box.handle)
        _ = try await web.evaluateJavaScript("globalThis.__IRIS_PREPARE_CLOSE_V1__ = async () => true; history.pushState(null, '', '#same-document-save'); true")
        try await Task.sleep(nanoseconds: 100_000_000)
        let currentHandle = try XCTUnwrap(page.box.handle)
        XCTAssertEqual(currentHandle.id, originalHandle.id,
                       "a history fragment changes the address, not the running document")
        XCTAssertTrue(currentHandle.isCurrent(),
                      "Home must not discard an available save hook after in-document navigation")
        let result = await prepare(currentHandle)
        XCTAssertEqual(result, .ready)
    }

    func testInitialCloseHandleIsPublishedOnlyAfterTheDocumentLoadFinishes() async throws {
        let fixture = try MultiAppRuntimeFixture()
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome = try await fixture.install(capabilities: [], coordinator: coordinator)
        let loaded = expectation(description: "actual document finished before no-hook authority")
        var events: [String] = []
        let host = MultiAppRuntimeHost(launch: outcome.launch, closeHandleChange: { handle in
            if handle != nil { events.append("handle") }
        }) { result in
            XCTAssertEqual(result, .loaded)
            events.append("loaded")
            loaded.fulfill()
        }
        defer { host.close(); fixture.close() }
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertTrue(events.contains("handle"))
        XCTAssertEqual(events.first, "loaded",
                       "commit alone must not authorize the absent-hook fast close during bootstrap")
    }

    private func prepare(_ handle: NativeVerifiedDocumentCloseHandle) async -> NativeAppClosePreparationResult? {
        let done = expectation(description: "bounded typed close-hook completion")
        var answer: NativeAppClosePreparationResult?
        handle.prepare { value in answer = value; done.fulfill() }
        await fulfillment(of: [done], timeout: 3)
        return answer
    }

    private func installPendingHook(in web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
        globalThis.closeHookStarts = 0;
        globalThis.__IRIS_PREPARE_CLOSE_V1__ = () => {
          globalThis.closeHookStarts += 1;
          return new Promise(resolve => { globalThis.finishSyntheticClose = resolve; });
        }; true;
        """)
    }

    private func waitForHookStart(in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if (try await web.evaluateJavaScript("globalThis.closeHookStarts === 1") as? Bool) == true { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the fixed hook did not begin in the actual page")
        throw NSError(domain: "NativeAppCloseRuntimeTest", code: 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard predicate() else {
            XCTFail("expected bounded production close transition did not occur")
            throw NSError(domain: "NativeAppCloseRuntimeTest", code: 2)
        }
    }

    private func hostedPage() async throws -> (fixture: MultiAppRuntimeFixture, host: MultiAppRuntimeHost, box: CloseHandleBox) {
        let fixture = try MultiAppRuntimeFixture()
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome: NativeShellLaunchOutcome
        do { outcome = try await fixture.install(capabilities: [], coordinator: coordinator) }
        catch { fixture.close(); throw error }
        let loaded = expectation(description: "real verified close-test page loaded")
        let box = CloseHandleBox()
        let host = MultiAppRuntimeHost(launch: outcome.launch, closeHandleChange: { box.handle = $0; box.changed?($0) }) {
            XCTAssertEqual($0, .loaded); loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        do { _ = try XCTUnwrap(host.webView); _ = try XCTUnwrap(box.handle) }
        catch { host.close(); fixture.close(); throw error }
        return (fixture, host, box)
    }
}

@MainActor
private final class CloseHandleBox {
    var handle: NativeVerifiedDocumentCloseHandle?
    var changed: ((NativeVerifiedDocumentCloseHandle?) -> Void)?
}
#endif
