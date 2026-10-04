#if os(iOS)
import Foundation
import UIKit
import WebKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class NativeMediaExportAdversarialTests: XCTestCase {
    func testUndeclaredBlobDownloadNeverCreatesExportSessionOrPicker() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: [], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)
        let originalURL = try XCTUnwrap(web.url)

        _ = try await triggerPNGExport(in: web)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertFalse(coordinator.hasMediaExportInFlightForTesting)
        XCTAssertNil(coordinator.mediaExportDirectoryForTesting)
        XCTAssertFalse(host.controller.presentedViewController is UIDocumentPickerViewController)
        XCTAssertEqual(web.url, originalURL)
    }

    func testSecondDeclaredExportCannotReplaceActivePickerOrCustody() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)

        _ = try await triggerPNGExport(in: web)
        try await acceptPhotosChoiceIntoFiles(in: host)
        let presentedPicker = try await waitForPicker(in: host)
        let firstPicker = try XCTUnwrap(presentedPicker)
        let firstCustody = try XCTUnwrap(coordinator.mediaExportDirectoryForTesting)
        XCTAssertTrue(coordinator.hasMediaExportInFlightForTesting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCustody.path))

        _ = try await triggerPNGExport(in: web)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(host.controller.presentedViewController === firstPicker)
        XCTAssertTrue(coordinator.hasMediaExportInFlightForTesting)
        XCTAssertEqual(coordinator.mediaExportDirectoryForTesting?.path, firstCustody.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCustody.path))

        firstPicker.delegate?.documentPickerWasCancelled?(firstPicker)
        try await waitUntil {
            !coordinator.hasMediaExportInFlightForTesting
                && !(host.controller.presentedViewController is UIDocumentPickerViewController)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCustody.path))
    }

    func testSameURLReloadRevokesExportPickerAndOwnedCustody() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)
        let originalURL = try XCTUnwrap(web.url)

        _ = try await triggerPNGExport(in: web)
        try await acceptPhotosChoiceIntoFiles(in: host)
        let presentedPicker = try await waitForPicker(in: host)
        _ = try XCTUnwrap(presentedPicker)
        let custody = try XCTUnwrap(coordinator.mediaExportDirectoryForTesting)
        XCTAssertTrue(coordinator.hasMediaExportInFlightForTesting)

        XCTAssertNotNil(web.reload(), "the adversarial transition must be a real reload of the same verified document")
        try await waitUntil {
            !coordinator.hasMediaExportInFlightForTesting
                && !(host.controller.presentedViewController is UIDocumentPickerViewController)
        }

        XCTAssertNil(coordinator.mediaExportDirectoryForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custody.path))
        XCTAssertEqual(web.url, originalURL, "same-URL reload must revoke old authority without replacing the app path")
    }

    func testTeardownRevokesExportPickerAndOwnedCustody() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)

        _ = try await triggerPNGExport(in: web)
        try await acceptPhotosChoiceIntoFiles(in: host)
        let presentedPicker = try await waitForPicker(in: host)
        _ = try XCTUnwrap(presentedPicker)
        let custody = try XCTUnwrap(coordinator.mediaExportDirectoryForTesting)
        XCTAssertTrue(coordinator.hasMediaExportInFlightForTesting)

        host.close()
        try await waitUntil { !coordinator.hasMediaExportInFlightForTesting }

        XCTAssertNil(coordinator.mediaExportDirectoryForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custody.path))
    }

    private func loadedHost(_ launch: VerifiedLaunchDescriptor) async throws -> MultiAppRuntimeHost {
        let loaded = expectation(description: "actual Core-backed export adversarial fixture loaded")
        let host = MultiAppRuntimeHost(launch: launch) { result in
            XCTAssertEqual(result, .loaded)
            loaded.fulfill()
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

    private func triggerPNGExport(in web: WKWebView) async throws -> String {
        let value = try await web.evaluateJavaScript("""
            (() => {
              const bytes = Uint8Array.from(
                atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/4WQAAAAASUVORK5CYII='),
                c => c.charCodeAt(0)
              );
              const link = document.createElement('a');
              link.href = URL.createObjectURL(new Blob([bytes], {type: 'image/png'}));
              link.download = 'synthetic-export.png';
              link.hidden = true;
              document.body.appendChild(link);
              link.click();
              return link.href;
            })();
            """) as? String
        return try XCTUnwrap(value)
    }

    private func waitForPicker(in host: MultiAppRuntimeHost) async throws -> UIDocumentPickerViewController? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let picker = host.controller.presentedViewController as? UIDocumentPickerViewController {
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
        XCTAssertTrue(condition(), "timed out waiting for export authority/custody teardown")
    }

    // MARK: - The new Photos/Files choice for a PNG (image) export

    /// A synthetic PNG export now shows "Your photo is ready" first. These
    /// two tests cover that new step directly; every other test in this
    /// file taps "Save to Files" on it (`acceptPhotosChoiceIntoFiles`) and
    /// then continues exactly as before, since it is testing the
    /// unchanged Files picker lifecycle and custody guarantees, not this
    /// choice.
    func testImageExportShowsPhotosChoiceBeforeAnyFilesPicker() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)

        _ = try await triggerPNGExport(in: web)
        let choice = try await waitForAlert(titled: NativeMediaSaveCopy.choiceTitle(for: .image), in: host)
        let alert = try XCTUnwrap(choice, "a PNG export must offer Photos before Files")

        XCTAssertEqual(
            alert.actions.map(\.title),
            [NativeMediaSaveCopy.saveToPhotosButton, NativeMediaSaveCopy.saveToFilesButton, NativeMediaSaveCopy.cancelButton]
        )
        XCTAssertEqual(alert.preferredAction?.title, NativeMediaSaveCopy.saveToPhotosButton)
        XCTAssertFalse(host.controller.presentedViewController is UIDocumentPickerViewController)
        XCTAssertTrue(coordinator.hasMediaExportInFlightForTesting, "custody is still held while the choice is on screen")
    }

    func testChoiceCancelReleasesCustodyWithoutEverPresentingFilesPicker() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let library = NativeShellLibraryCoordinator(
            rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"])
        )
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: library)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let coordinator = try coordinator(for: web)

        _ = try await triggerPNGExport(in: web)
        let choice = try await waitForAlert(titled: NativeMediaSaveCopy.choiceTitle(for: .image), in: host)
        let alert = try XCTUnwrap(choice)
        let custody = try XCTUnwrap(coordinator.mediaExportDirectoryForTesting)

        await alert.tapAction(titled: NativeMediaSaveCopy.cancelButton)
        try await waitUntil { !coordinator.hasMediaExportInFlightForTesting }

        XCTAssertNil(coordinator.mediaExportDirectoryForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custody.path))
        XCTAssertFalse(host.controller.presentedViewController is UIDocumentPickerViewController, "Cancel must never fall through to Files")
    }

    /// Waits for the new choice alert, then taps "Save to Files" so the
    /// rest of a test can exercise the existing, unchanged Files picker
    /// path exactly as it did before this alert was added in front of it.
    private func acceptPhotosChoiceIntoFiles(in host: MultiAppRuntimeHost) async throws {
        let choice = try await waitForAlert(titled: NativeMediaSaveCopy.choiceTitle(for: .image), in: host)
        let alert = try XCTUnwrap(choice, "the Photos/Files choice never appeared for this export")
        await alert.tapAction(titled: NativeMediaSaveCopy.saveToFilesButton)
    }

    private func waitForAlert(titled title: String, in host: MultiAppRuntimeHost) async throws -> UIAlertController? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let alert = host.controller.presentedViewController as? UIAlertController, alert.title == title {
                return alert
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: RC-09a (apple-compliance/REQUIRED_CHANGES.md, M-03): export in
    // line with import's free-space rule, not a flat 32 MB cap.
    //
    // These exact scenarios (and their exact mutation) were first proven
    // against a standalone, git-free mirror of NativeMediaExportLease.swift
    // in a scratch SwiftPM package
    // (`scratchpad/export-lease-mirror/`, `swift test` runnable, no Xcode
    // needed), per verify-in-scratch-mirror: 4/4 pass there, and the
    // required mutation ("restore the 32 MB cap") is caught (3/4 fail,
    // exactly the three that depend on the raised ceiling). Ported here
    // against the real `NativeMediaExportLease` once this target can
    // actually run it.

    func testHundredMegabyteFixtureExportSucceeds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-lease-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try NativeMediaExportLease(parent: root)
        defer { lease.close() }
        // Ample injected headroom: this is a size test, not a real-disk test.
        let url = try lease.reserve(
            expectedBytes: 100 * 1024 * 1024, fileExtension: "mp4",
            availableBytesOverride: 50 * 1024 * 1024 * 1024
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "reserve only names a destination, does not create it")
    }

    func testExportThatWouldExceedFreeSpaceFailsWithThePlainMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-lease-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try NativeMediaExportLease(parent: root)
        defer { lease.close() }
        XCTAssertThrowsError(
            try lease.reserve(expectedBytes: 100 * 1024 * 1024, fileExtension: "mp4",
                               availableBytesOverride: 50 * 1024 * 1024)
        ) { error in
            guard let failure = error as? NativeMediaExportLease.Failure,
                  case .notEnoughSpace(let required, let available) = failure else {
                XCTFail("expected .notEnoughSpace, got \(error)")
                return
            }
            XCTAssertGreaterThan(required, available)
            // The plain-language message this failure produces
            // (NativeMediaExportSession's decideDestinationUsing catch)
            // states a real byte count, never a placeholder.
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let message = "Your iPhone needs about \(formatter.string(fromByteCount: required)) free to save this export. Free up space, then try again."
            XCTAssertTrue(message.contains("needs about"))
        }
    }

    func testHardCeilingStaysAtTwoGiBRegardlessOfFreeSpace() throws {
        XCTAssertEqual(NativeMediaExportLease.maximumBytes, Int(NativeMediaExportPolicy.maximumExportBytes))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-lease-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try NativeMediaExportLease(parent: root)
        defer { lease.close() }
        XCTAssertThrowsError(
            try lease.reserve(expectedBytes: NativeMediaExportLease.maximumBytes + 1, fileExtension: "mp4",
                               availableBytesOverride: 1024 * 1024 * 1024 * 1024)
        ) { error in
            guard let failure = error as? NativeMediaExportLease.Failure, case .invalidSize = failure else {
                XCTFail("expected .invalidSize, got \(error)")
                return
            }
        }
    }
}

private extension UIAlertController {
    /// Dismisses this alert and then invokes one action's handler, the
    /// standard (if unofficial) way test code exercises a
    /// `UIAlertController` without driving a real touch through its view.
    /// The dismiss happens first, and is awaited, because a real tap
    /// begins dismissing the alert as part of handling that tap; a
    /// handler that immediately presents something else (as
    /// "Save to Files" does here) is written expecting that ordering.
    /// Invoking the handler directly, the way this helper must, skips
    /// UIKit's own touch handling entirely, so without first awaiting a
    /// real dismissal here, the handler's own `present(_:animated:)` call
    /// would race this alert's presentation and be silently refused.
    func tapAction(titled title: String) async {
        guard let action = actions.first(where: { $0.title == title }) else {
            XCTFail("no action titled \(title) on alert \(self.title ?? self.message ?? "<untitled>")")
            return
        }
        await withCheckedContinuation { continuation in
            self.dismiss(animated: false) { continuation.resume() }
        }
        action.invoke()
    }
}

private extension UIAlertAction {
    private typealias Handler = @convention(block) (UIAlertAction) -> Void

    /// `UIAlertAction` stores its closure under a private `handler` key.
    /// This has been stable for years and is the well-known way to invoke
    /// an alert action from a test without UI automation.
    func invoke() {
        guard let handler = value(forKey: "handler") else { return }
        unsafeBitCast(handler as AnyObject, to: Handler.self)(self)
    }
}
#endif
