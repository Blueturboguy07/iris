#if os(iOS)
import Foundation
import PhotosUI
import WebKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class NativeMediaDocumentLifetimeTests: XCTestCase {
    func testSameURLReloadCancelsOldPickerAndLateOldPickerCannotAffectNewDocument() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy
        )
        let outcome = try await fixture.install(
            capabilities: ["web.media.photo-picker"],
            coordinator: library
        )
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let originalURL = try XCTUnwrap(web.url)

        try await clickFileInput(in: web)
        let oldPickerValue = try await waitForPicker(in: host)
        let oldPicker = try XCTUnwrap(oldPickerValue)
        let oldDelegate = oldPicker.delegate
        XCTAssertNotNil(oldDelegate, "the real system picker must still be owned by its production session")

        XCTAssertNotNil(web.reload(), "the adversarial transition must be a real reload of the same verified file URL")
        try await waitUntil {
            !(host.controller.presentedViewController is PHPickerViewController)
        }
        try await waitForFileInputReady(in: web)
        XCTAssertEqual(web.url, originalURL)

        try await clickFileInput(in: web)
        let newPickerValue = try await waitForPicker(in: host)
        let newPicker = try XCTUnwrap(newPickerValue)
        XCTAssertFalse(newPicker === oldPicker, "a new document must receive a new picker session")

        // Simulate a late callback that was already queued for the old real picker.
        // Keeping the old delegate strongly here proves its stale callback cannot
        // clear/dismiss the new document's session after reload cancellation.
        oldDelegate?.picker(oldPicker, didFinishPicking: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(host.controller.presentedViewController === newPicker)

        newPicker.delegate?.picker(newPicker, didFinishPicking: [])
        try await waitUntil {
            !(host.controller.presentedViewController is PHPickerViewController)
        }
    }

    func testWebContentTerminationCancelsOwnedPicker() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy
        )
        let outcome = try await fixture.install(
            capabilities: ["web.media.photo-picker"],
            coordinator: library
        )
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)

        try await clickFileInput(in: web)
        let pickerValue = try await waitForPicker(in: host)
        let picker = try XCTUnwrap(pickerValue)
        let retainedOldDelegate = picker.delegate
        XCTAssertNotNil(retainedOldDelegate)

        coordinator.webViewWebContentProcessDidTerminate(web)
        try await waitUntil {
            !(host.controller.presentedViewController is PHPickerViewController)
        }

        // A callback delivered after process termination must already be inert.
        retainedOldDelegate?.picker(picker, didFinishPicking: [])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(host.controller.presentedViewController is PHPickerViewController)
    }

    func testForeignSameLaunchWebViewOpenPanelRequestIsDenied() async throws {
        guard #available(iOS 18.4, *) else {
            XCTFail("This native acceptance requires the supported iOS 18.4+ WebKit runtime")
            throw NSError(domain: "NativeMediaDocumentLifetimeTests", code: 1)
        }

        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy
        )
        let outcome = try await fixture.install(
            capabilities: ["web.media.photo-picker"],
            coordinator: library
        )
        let ownerHost = try await loadedHost(outcome.launch)
        let foreignHost = try await loadedHost(outcome.launch)
        defer {
            ownerHost.close()
            foreignHost.close()
        }
        let ownerWeb = try XCTUnwrap(ownerHost.webView)
        let foreignWeb = try XCTUnwrap(foreignHost.webView)
        let ownerCoordinator = try coordinator(for: ownerWeb)
        let foreignCoordinator = try coordinator(for: foreignWeb)

        let captured = expectation(description: "foreign real WebKit open-panel request captured")
        let probe = DocumentLifetimeOpenPanelCapture(expectation: captured)
        foreignWeb.uiDelegate = probe
        try await clickFileInput(in: foreignWeb)
        await fulfillment(of: [captured], timeout: 5)
        foreignWeb.uiDelegate = foreignCoordinator

        let parameters = try XCTUnwrap(probe.parameters)
        let frame = try XCTUnwrap(probe.frame)
        var completionCount = 0
        var returnedNil = false
        ownerCoordinator.webView(
            foreignWeb,
            runOpenPanelWith: parameters,
            initiatedByFrame: frame
        ) { urls in
            completionCount += 1
            returnedNil = urls == nil
        }

        try await waitUntil(timeout: 1) {
            completionCount > 0
                || ownerHost.controller.presentedViewController is PHPickerViewController
                || foreignHost.controller.presentedViewController is PHPickerViewController
        }

        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(returnedNil)
        XCTAssertFalse(ownerHost.controller.presentedViewController is PHPickerViewController)
        XCTAssertFalse(foreignHost.controller.presentedViewController is PHPickerViewController)
    }

    private func loadedHost(_ launch: VerifiedLaunchDescriptor) async throws -> MultiAppRuntimeHost {
        let loaded = expectation(description: "actual Core-backed media lifetime fixture loaded")
        var initialResultSeen = false
        let host = MultiAppRuntimeHost(launch: launch) { result in
            if !initialResultSeen {
                initialResultSeen = true
                XCTAssertEqual(result, .loaded)
                loaded.fulfill()
            }
        }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        _ = try XCTUnwrap(host.webView)
        return host
    }

    private func coordinator(for web: WKWebView) throws -> VerifiedRevisionWebView.Coordinator {
        try XCTUnwrap(
            (web.navigationDelegate as? VerifiedRevisionWebView.Coordinator)
                ?? (web.uiDelegate as? VerifiedRevisionWebView.Coordinator)
        )
    }

    private func clickFileInput(in web: WKWebView) async throws {
        let clicked = try await web.evaluateJavaScript("""
            (() => {
              const input = document.querySelector('#photo');
              if (!(input instanceof HTMLInputElement)) return false;
              input.click();
              return true;
            })();
            """) as? Bool
        XCTAssertEqual(clicked, true)
    }

    private func waitForFileInputReady(in web: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let ready = (try? await web.evaluateJavaScript(
                "document.readyState === 'complete' && document.querySelector('#photo') instanceof HTMLInputElement"
            )) as? Bool
            if !web.isLoading, ready == true {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("same-URL reload did not produce a ready verified file input")
    }

    private func waitForPicker(in host: MultiAppRuntimeHost) async throws -> PHPickerViewController? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let picker = host.controller.presentedViewController as? PHPickerViewController {
                return picker
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for media document-lifetime transition")
    }
}

@available(iOS 18.4, *)
@MainActor
private final class DocumentLifetimeOpenPanelCapture: NSObject, WKUIDelegate {
    let expectation: XCTestExpectation
    private(set) var parameters: WKOpenPanelParameters?
    private(set) var frame: WKFrameInfo?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        self.parameters = parameters
        self.frame = frame
        completionHandler(nil)
        expectation.fulfill()
    }
}
#endif
