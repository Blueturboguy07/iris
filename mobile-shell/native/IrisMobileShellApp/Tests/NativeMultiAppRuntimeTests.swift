#if os(iOS)
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class NativeMultiAppRuntimeTests: XCTestCase {
    func testMarketplaceModelShowsOnlyCuratedMobileDescriptorsAndPreservesLibrary() async throws {
        struct CatalogTransport: PublikMobileHTTPTransport {
            let body: Data
            func get(_ request: URLRequest, maximumBytes: Int,
                     progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
                guard request.url == PublikMobileCatalogClient.catalogURL, body.count <= maximumBytes else {
                    throw URLError(.badURL)
                }
                return PublikMobileHTTPResponse(statusCode: 200, mimeType: "application/json",
                    declaredContentLength: body.count, finalURL: request.url, body: body)
            }
        }
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        _ = try await fixture.install(capabilities: [], coordinator: coordinator)
        let before = try await coordinator.refreshLibrary()
        let hash = "sha256:" + String(repeating: "2", count: 64)
        let revision = "rev-sha256:" + String(repeating: "2", count: 64)
        let base = "rev-sha256:" + String(repeating: "1", count: 64)
        var rows: [[String: Any]] = [["slug": "desktop-only", "name": "Kneecap for iPhone",
                                    "macBundleId": "publik.kneecap"]]
        for appID in ["publik.kneecap", "publik.nut-ai", "publik.freeharmony", "publik.lunara", "future.mobile"] {
            rows.append(["slug": appID, "name": "Display " + appID, "mobileShell": [
                "version": 1, "platform": "ios", "packageFormat": "iris.mobile-shell.package+json",
                "downloadUrl": "https://publikhq.com/_synthetic_not_published/package.json",
                "mediaType": "application/json", "byteCount": 1, "packageSha256": hash,
                "appId": appID, "projectId": "fixture.mobile", "baseRevisionId": base,
                "revisionId": revision, "contentHash": hash,
            ]])
        }
        let body = try JSONSerialization.data(withJSONObject: ["apps": rows])
        let importer = NativeShellAppModel(coordinator: coordinator)
        let model = NativeShellCatalogModel(importer: importer,
            client: PublikMobileCatalogClient(transport: CatalogTransport(body: body)))
        model.loadCatalog()
        for _ in 0..<100 {
            if !model.isLoading { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.apps.count, 6, "full metadata remains available to explicit links and updates")
        // Mutation N1: an unlisted fifth app still fails this independent identity set.
        XCTAssertEqual(Set(model.downloadableApps.compactMap { $0.mobileShell?.appId }),
                       Set(["publik.kneecap", "publik.nut-ai", "publik.freeharmony", "publik.lunara"]),
                       "catalog-expand SPEC 8.1: four curated Browse identities")
        XCTAssertEqual(model.downloadableApps.count, 4)
        let listed = try XCTUnwrap(model.downloadableApps.first)
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: nil), "Get app")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: revision), "Open")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: base), "Review update")
        XCTAssertEqual(NativeMobileMarketplacePolicy.actionLabel(for: listed, installedRevisionID: "different"), "Check version")
        let after = try await coordinator.refreshLibrary()
        XCTAssertEqual(after.map { $0.identity }, before.map { $0.identity })
        XCTAssertEqual(after.map { $0.currentRevisionId }, before.map { $0.currentRevisionId })
        XCTAssertNil(importer.launch)
        let pending = await coordinator.pendingPackageReview()
        XCTAssertNil(pending)
    }

    func testFloatingHomeControlRemainsReachableAfterDraggingAndRotation() {
        XCTAssertEqual(NativeHomeControlGeometry.clamp(CGPoint(x: -100, y: 2000), to: CGSize(width: 402, height: 874)),
                       CGPoint(x: 28, y: 846))
        XCTAssertEqual(NativeHomeControlGeometry.clamp(CGPoint(x: 846, y: 800), to: CGSize(width: 874, height: 402)),
                       CGPoint(x: 846, y: 374))
        XCTAssertEqual(NativeHomeControlGeometry.clamp(CGPoint(x: 374, y: 846), to: .zero), .zero)
    }

    func testMarketplaceSearchIsBoundedAndUnknownIdentitiesDoNotBorrowKnownArtwork() {
        XCTAssertTrue(NativeMarketplaceSelection.matches(query: " NUT ", name: "Nut AI", slug: "nut-ai"))
        XCTAssertTrue(NativeMarketplaceSelection.matches(query: "freeharmony", name: "FreeHarmony", slug: "freeharmony"))
        XCTAssertFalse(NativeMarketplaceSelection.matches(query: "unrelated", name: "Nut AI", slug: "nut-ai"))
        XCTAssertFalse(NativeMarketplaceSelection.matches(query: String(repeating: "x", count: 1000), name: "Nut AI", slug: "nut-ai"))
        XCTAssertEqual(NativeMarketplaceSelection.appearanceKey(appId: "publik.freeharmony"), "freeharmony")
        XCTAssertEqual(NativeMarketplaceSelection.appearanceKey(appId: "untrusted.publik.freeharmony"), "untrusted.publik.freeharmony")
    }

    func testMarketplaceInstalledMatchRequiresExactAppAndProjectDescriptorIdentity() {
        let identity = NativeShellAppIdentity(appId: "iris.marketplace.fixture", projectId: "iris.marketplace.project")
        let entry = NativeShellLibraryEntry(identity: identity, displayName: "Same name", currentRevisionId: nil,
                                           fallbackRevisionId: nil, revisions: [])
        let nameOnly = PublikMobileCatalogApp(slug: "same-name", name: "Same name", guideSlug: nil,
                                             macBundleId: nil, latestReleaseTag: nil, mobileShell: nil)
        XCTAssertNil(NativeMarketplaceSelection.catalogApp(for: entry, in: [nameOnly]))
        func app(project: String) -> PublikMobileCatalogApp {
            let descriptor = PublikMobileShellDescriptor(version: 1, platform: "ios", packageFormat: "iris.mobile-shell.package+json",
                downloadURL: URL(string: "https://publikhq.com/_synthetic_not_published/marketplace.irisapp")!,
                mediaType: "application/json", byteCount: 1, packageSHA256: "sha256:" + String(repeating: "1", count: 64),
                appId: identity.appId, projectId: project, baseRevisionId: nil,
                revisionId: "rev-sha256:" + String(repeating: "2", count: 64), contentHash: "sha256:" + String(repeating: "2", count: 64))
            return PublikMobileCatalogApp(slug: "different-display-name", name: "Other name", guideSlug: nil,
                                         macBundleId: nil, latestReleaseTag: nil, mobileShell: descriptor)
        }
        XCTAssertNil(NativeMarketplaceSelection.catalogApp(for: entry, in: [app(project: "different.project")]))
        XCTAssertEqual(NativeMarketplaceSelection.catalogApp(for: entry, in: [app(project: identity.projectId)])?.slug,
                       "different-display-name")
    }

    func testActualFullscreenContentUsesTheScreenWidthWithoutAnAppNavigationBar() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome = try await fixture.install(capabilities: [], coordinator: coordinator)
        let loaded = expectation(description: "full-screen production WebView loaded")
        // Layout acceptance needs a real scene-backed window. A detached legacy
        // UIWindow can load WebKit while never receiving the scene's layout size.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        let screen = UIWindow(windowScene: scene)
        screen.frame = scene.coordinateSpace.bounds
        let controller = UIHostingController(rootView: NativeFullscreenAppView(
            launch: outcome.launch, adapter: .notConfigured, presentationID: UUID(), hasLoadFailure: false,
            onLoadResult: { result in XCTAssertEqual(result, .loaded); loaded.fulfill() },
            onClose: {}, pendingRequest: { _ in EmptyView() }))
        screen.rootViewController = controller
        screen.makeKeyAndVisible()
        screen.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWeb).first
        }
        defer {
            if let web = findWeb(controller.view), let delegate = web.uiDelegate as? VerifiedRevisionWebView.Coordinator {
                VerifiedRevisionWebView.dismantleUIView(web, coordinator: delegate)
            }
            screen.isHidden = true
            screen.rootViewController = nil
        }
        await fulfillment(of: [loaded], timeout: 8)
        // didFinish is a WebKit navigation event, not SwiftUI's display/layout
        // completion. Let two display cycles run before asserting visible bounds.
        // This is a fixed bounded settle, not a loop waiting for assertions to pass.
        try await Task.sleep(nanoseconds: 100_000_000)
        screen.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let web = try XCTUnwrap(findWeb(controller.view))
        let rect = web.convert(web.bounds, to: screen)
        XCTAssertTrue(screen.windowScene === scene)
        print("IRIS_FULLSCREEN_GEOMETRY scene=\(scene.coordinateSpace.bounds) window=\(screen.bounds) root=\(controller.view.bounds) web=\(rect)")
        XCTAssertEqual(rect.minX, 0, accuracy: 1, "the app must not have inset modal-sheet margins")
        XCTAssertEqual(rect.width, screen.bounds.width, accuracy: 1)
        XCTAssertEqual(rect.minY, 0, accuracy: 1, "Home must float over app content, not reserve a toolbar row")
        XCTAssertEqual(rect.height, screen.bounds.height, accuracy: 1, "the app owns the entire screen")
        XCTAssertGreaterThan(rect.height, screen.bounds.height * 0.75)
        XCTAssertLessThan(rect.minY, screen.bounds.height * 0.20)
        XCTAssertGreaterThanOrEqual(rect.maxY, screen.bounds.maxY - 2)
        func containsNavigationBar(_ view: UIView) -> Bool {
            view is UINavigationBar || view.subviews.contains(where: containsNavigationBar)
        }
        XCTAssertFalse(containsNavigationBar(controller.view), "the actual app hierarchy must not contain a nested navigation title bar")
    }

    func testPendingWebsiteBannerDoesNotShrinkTheActualFullscreenApp() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome = try await fixture.install(capabilities: [], coordinator: coordinator)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let screen = UIWindow(windowScene: scene)
        screen.frame = scene.coordinateSpace.bounds
        let loaded = expectation(description: "production full-screen app with pending website request")
        let controller = UIHostingController(rootView: NativeFullscreenAppView(
            launch: outcome.launch, adapter: .notConfigured, presentationID: UUID(), hasLoadFailure: false,
            onLoadResult: { result in XCTAssertEqual(result, .loaded); loaded.fulfill() }, onClose: {},
            pendingRequest: { _ in Text("Another app is waiting. Stay here or return home.")
                .frame(maxWidth: .infinity).frame(height: 96).background(.bar) }))
        screen.rootViewController = controller
        screen.makeKeyAndVisible()
        screen.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        func findWeb(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(findWeb).first
        }
        defer {
            if let web = findWeb(controller.view), let delegate = web.uiDelegate as? VerifiedRevisionWebView.Coordinator {
                VerifiedRevisionWebView.dismantleUIView(web, coordinator: delegate)
            }
            screen.isHidden = true
            screen.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }
        await fulfillment(of: [loaded], timeout: 8)
        try await Task.sleep(nanoseconds: 100_000_000)
        screen.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let web = try XCTUnwrap(findWeb(controller.view))
        let rect = web.convert(web.bounds, to: screen)
        print("IRIS_PENDING_BANNER_GEOMETRY window=\(screen.bounds) web=\(rect)")
        XCTAssertEqual(rect.minX, 0, accuracy: 1)
        XCTAssertEqual(rect.minY, 0, accuracy: 1)
        XCTAssertEqual(rect.width, screen.bounds.width, accuracy: 1)
        XCTAssertEqual(rect.height, screen.bounds.height, accuracy: 1,
                       "a pending link may overlay an explicit choice, not resize the running app")
        XCTAssertEqual(web.url, outcome.launch.entrypointURL, "pending request cannot replace app content")
    }

    func testVerifiedRevisionCarriesOnlyItsOwnApprovedMediaCapabilities() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy)
        let first = try await fixture.install(capabilities: ["web.storage", "web.media.photo-picker"], coordinator: coordinator)
        XCTAssertEqual(Set(first.launch.requestedCapabilities), Set(["web.storage", "web.media.photo-picker"]))
        let second = try await fixture.install(capabilities: ["web.storage"], base: first.launchedRevisionId, coordinator: coordinator)
        XCTAssertEqual(second.launch.requestedCapabilities, ["web.storage"])
        try await coordinator.revert(identity: fixture.identity, to: first.launchedRevisionId)
        let reverted = try await coordinator.launchActive(identity: fixture.identity)
        XCTAssertEqual(reverted.launch.requestedCapabilities, first.launch.requestedCapabilities)
        XCTAssertFalse(reverted.launch.requestedCapabilities.contains("native.photo-library"))
    }

    func testPermissionPolicyRejectsUndeclaredForeignSubframeAndStaleRequests() throws {
        let root = URL(fileURLWithPath: "/owned/app/content", isDirectory: true)
        let source = root.appendingPathComponent("index.html")
        func permits(_ caps: [String] = ["web.media.photo-picker"], valid: Bool = true,
                     main: Bool = true, url: URL? = nil) -> Bool {
            NativeMediaPermissionPolicy.allows(capability: "web.media.photo-picker",
                requestedCapabilities: caps, isValid: valid, isMainFrame: main,
                frameURL: url ?? source, contentRoot: root)
        }
        XCTAssertTrue(permits())
        XCTAssertFalse(permits([]))
        XCTAssertFalse(permits(["web.media.camera"]))
        XCTAssertFalse(permits(valid: false))
        XCTAssertFalse(permits(main: false))
        XCTAssertFalse(permits(url: URL(string: "https://publikhq.com/index.html")!))
        XCTAssertFalse(permits(url: URL(fileURLWithPath: "/owned/app/content-other/index.html")))
        XCTAssertFalse(permits(url: URL(fileURLWithPath: "/owned/app/content/../private.jpg")))
        XCTAssertTrue(permits(url: URL(string: source.absoluteString + "#/scan")!))
    }

    func testSelectedMediaCustodyIsBoundedAndRevokedOnClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-media-lease-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("synthetic.jpg")
        let bytes = Data([0xff,0xd8,0xff,0xd9])
        try bytes.write(to: image)
        let lease = try NativeSelectedMediaLease(parent: root)
        let selected = try lease.copySelectedFile(image, fileExtension: "jpg")
        XCTAssertEqual(try Data(contentsOf: selected), bytes)
        XCTAssertNotEqual(image, selected)
        let link = root.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
        XCTAssertThrowsError(try lease.copySelectedFile(link, fileExtension: "jpg"))
        XCTAssertThrowsError(try lease.copySelectedFile(image, fileExtension: "../jpg"))
        // M-longimport (round5/mobile-integrator-B1, 2026-09-28): videos of
        // any length are accepted now; only real free space limits an
        // import, there is no fixed video byte cap any more
        // (`NativeMediaImportPolicy.evaluateSize` always accepts video, and
        // `maximumFileBytes(for: .video)` is `nil`). This test used to build
        // a `.mov` at exactly `NativeMediaPermissionPolicy.maximumFileBytes + 1`
        // (a constant that is documented, as of this same round, to be for
        // *export* only -- see that constant's own doc comment -- and was
        // never reachable via this *import* path once the cap was removed).
        // The flagged cross-lane conflict this rewrite closes (named in
        // `docs/plans/20260928-all-routes/round3-mobile/M-longimport/HANDOFF.md`,
        // "Cross-lane conflict found, flagged, not fixed here", and
        // `NEEDS_OWNER.md` 2026-09-28 09:41): a bare `XCTAssertThrowsError`
        // on that old size made this test's pass/fail depend entirely on
        // how much free space this machine happened to have at test time,
        // not on any property of the code under test.
        //
        // Rewritten to assert the actual current behavior: an import this
        // large **relative to this volume's own real free space right now**
        // must still be rejected, but for the real reason
        // (`Failure.notEnoughSpace`), never a size-cap `Failure.tooLarge`.
        // Sized off a fresh read of the real available bytes (not a fixed
        // constant), so the assertion is deterministic on any machine's
        // free space: `evaluateSpace`'s formula requires roughly 3x the
        // added bytes plus a margin, so requesting slightly more than 100%
        // of what is actually free guarantees `.insufficient` regardless of
        // whether this machine has 5 GB or 500 GB free today. The file
        // itself is sparse (`truncate` to a byte offset, never written),
        // so this never risks actually filling the test machine's disk.
        let availableBytes: Int64 = (try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage) ?? (4 * 1024 * 1024 * 1024)
        let big = root.appendingPathComponent("oversized.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(availableBytes) + 1)
        try handle.close()
        XCTAssertThrowsError(try lease.copySelectedFile(big, fileExtension: "mov")) { error in
            guard let failure = error as? NativeSelectedMediaLease.Failure,
                  case .notEnoughSpace = failure else {
                XCTFail("expected a free-space rejection (.notEnoughSpace), got \(error)")
                return
            }
        }
        lease.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try Data(contentsOf: image), bytes)
        XCTAssertThrowsError(try lease.copySelectedFile(image, fileExtension: "jpg"))
        lease.close()
    }

    func testActualApprovedFileInputPresentsSystemPhotoPickerAndTeardownCancels() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy)
        let launch = try await fixture.install(capabilities: ["web.media.photo-picker"], coordinator: coordinator)
        let host = try await loadedHost(launch.launch)
        defer { host.close() }
        let view = try XCTUnwrap(host.webView)
        _ = try await view.evaluateJavaScript("document.querySelector('#photo').click()")
        let deadline = Date().addingTimeInterval(5)
        while !(host.controller.presentedViewController is PHPickerViewController), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(host.controller.presentedViewController is PHPickerViewController,
                      "approved HTML upload must reach the actual system picker, not silently cancel")
        let delegate = try XCTUnwrap(view.uiDelegate as? VerifiedRevisionWebView.Coordinator)
        VerifiedRevisionWebView.dismantleUIView(view, coordinator: delegate)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(host.controller.presentedViewController)
        XCTAssertTrue(view.uiDelegate === delegate, "denying delegate remains alive for late calls")
    }

    func testActualVerifiedHostCanFetchPackagedJSONAndCompilePackagedWASM() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let launch = try await fixture.install(capabilities: [], coordinator: coordinator)
        let host = try await loadedHost(launch.launch)
        defer { host.close() }
        let view = try XCTUnwrap(host.webView)
        let result = try await view.callAsyncJavaScript("""
            try {
              const json = await (await fetch('./assets/config.json')).json();
              const module = await WebAssembly.compile(await (await fetch('./assets/empty.wasm')).arrayBuffer());
              return json.value === 'actual packaged resource' && module instanceof WebAssembly.Module ? 'ok' : 'wrong';
            } catch(e) { return 'failed:' + String(e); }
            """, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(result, "ok", "real apps require local fetch/WASM, not only inline HTML execution")
    }

    func testActualVerifiedHostKeepsAppOptedInVideoInlineWithoutGrantingMedia() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome = try await fixture.install(capabilities: [], coordinator: coordinator,
            html: "<!doctype html><meta name='viewport' content='width=device-width'><video id='preview' playsinline muted></video><button>Capture</button>")
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        XCTAssertTrue(web.configuration.allowsInlineMediaPlayback,
                      "an app's playsinline preview must not hide its Capture/Stop controls in a native player")
        let playsInline = try await web.evaluateJavaScript("document.querySelector('#preview').playsInline") as? Bool
        XCTAssertEqual(playsInline, true)
        XCTAssertTrue(outcome.launch.requestedCapabilities.isEmpty)
        XCTAssertNotNil(web.uiDelegate, "inline rendering does not bypass the denying media delegate")
        XCTAssertNil(host.controller.presentedViewController)
    }

    func testActualVerifiedFileDocumentReportsOpaqueBlobOriginCategory() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome = try await fixture.install(capabilities: [], coordinator: coordinator)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        // This fresh native diagnostic returns only a fixed category, never the
        // generated blob identifier, document URL, file contents or app data.
        let category = try await web.evaluateJavaScript("""
            (() => {
              const value = URL.createObjectURL(new Blob(['synthetic'], {type: 'image/png'}));
              try {
                const uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
                if (new RegExp('^blob:null/' + uuid + '$', 'i').test(value)) return 'opaque-null-uuid';
                if (new RegExp('^blob:file:///' + uuid + '$', 'i').test(value)) return 'explicit-file-uuid';
                return 'unsupported';
              } finally { URL.revokeObjectURL(value); }
            })();
            """) as? String
        XCTContext.runActivity(named: "Observed local blob category: " + (category ?? "missing")) { _ in
            XCTAssertEqual(category, "opaque-null-uuid")
        }
    }

    func testDeclaredOwnedBlobExportPresentsSystemSavePickerWithoutReplacingTheApp() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        // G7: authorize only export for this independent local package.
        // Follow the destination choice through Files and Cancel without losing app data.
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root,
            capabilityPolicy: CapabilityPolicy(supportedCapabilities: ["web.media.export"]))
        let outcome = try await fixture.install(capabilities: ["web.media.export"], coordinator: coordinator)
        let host = try await loadedHost(outcome.launch)
        defer { host.close() }
        let web = try XCTUnwrap(host.webView)
        let originalURL = try XCTUnwrap(web.url)
        let exportCoordinator = try XCTUnwrap(web.uiDelegate as? VerifiedRevisionWebView.Coordinator)
        let unrelatedFile = fixture.root.appendingPathComponent("unrelated-export-sentinel.txt")
        let unrelatedBytes = Data("caller data must survive export cancellation".utf8)
        try unrelatedBytes.write(to: unrelatedFile)
        let exportDispatched = try await web.evaluateJavaScript("""
            (() => {
              const bytes = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/4WQAAAAASUVORK5CYII='), c => c.charCodeAt(0));
              const link = document.createElement('a');
              link.href = URL.createObjectURL(new Blob([bytes], {type: 'image/png'}));
              link.download = 'synthetic-export.png';
              document.body.appendChild(link);
              link.click();
              return link.protocol === 'blob:';
            })();
            """) as? Bool
        // Origin qualification is covered by the separate categorical native
        // test. This behavioral test need not print any generated identifier.
        XCTAssertEqual(exportDispatched, true)
        try await acceptPhotosChoiceIntoFiles(in: host)
        // Mutation N2: omitting the Files picker still fails after choosing Files.
        let pickerPresented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.controller.presentedViewController is UIDocumentPickerViewController
        }, object: nil)
        let pickerResult = await XCTWaiter.fulfillment(of: [pickerPresented], timeout: 5)
        XCTAssertEqual(pickerResult, .completed,
                       "an app-produced export must reach a user-controlled Save picker, not silently cancel")
        let picker = try XCTUnwrap(host.controller.presentedViewController as? UIDocumentPickerViewController)
        XCTAssertEqual(web.url, originalURL, "export must not replace the running app document")
        let custody = try XCTUnwrap(exportCoordinator.mediaExportDirectoryForTesting)
        XCTAssertTrue(exportCoordinator.hasMediaExportInFlightForTesting)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custody.path), "the picker holds owned export custody")

        picker.delegate?.documentPickerWasCancelled?(picker)
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !exportCoordinator.hasMediaExportInFlightForTesting
                && !(host.controller.presentedViewController is UIDocumentPickerViewController)
        }, object: nil)
        let cancelledResult = await XCTWaiter.fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(cancelledResult, .completed, "Cancel must release the picker and export custody")
        XCTAssertFalse(exportCoordinator.hasMediaExportInFlightForTesting)
        XCTAssertNil(exportCoordinator.mediaExportDirectoryForTesting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custody.path), "Cancel removes the owned temporary export directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertEqual(try Data(contentsOf: unrelatedFile), unrelatedBytes, "Cancel preserves unrelated caller files")
        XCTAssertEqual(web.url, originalURL, "Cancel keeps the original app open")
    }

    func testPackageFetchRejectsUndeclaredFilesAndChangedBytes() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let launch = try await fixture.install(capabilities: [], coordinator: coordinator)
        let host = try await loadedHost(launch.launch)
        defer { host.close() }
        let view = try XCTUnwrap(host.webView)
        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("not package content".utf8).write(to: outside)
        let denied = try await view.callAsyncJavaScript("try { await fetch(path); return 'allowed'; } catch { return 'denied'; }",
            arguments: ["path":outside.absoluteString], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(denied, "denied")
        let changed = launch.launch.readAccessRootURL.appendingPathComponent("assets/config.json")
        try Data("{\"value\":\"changed after verified launch\"}".utf8).write(to: changed)
        let tampered = try await view.callAsyncJavaScript("try { await (await fetch('./assets/config.json')).text(); return 'allowed'; } catch { return 'denied'; }",
            arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(tampered, "denied", "resource snapshot hashes remain enforced after initial launch")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "not package content")
    }

    func testActualAppCSPMustExplicitlyAllowItsVerifiedLocalResourceTransport() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        // Exact policy from Kneecap's reviewed mobile HTML, before adaptation.
        let original = "default-src 'self' data: blob: https://appassets.androidplatform.net capacitor://appassets.androidplatform.net capacitor://localhost https://localhost; img-src 'self' data: blob: https://appassets.androidplatform.net capacitor://appassets.androidplatform.net; style-src 'self' 'unsafe-inline'; script-src 'self' 'wasm-unsafe-eval'"
        func html(_ policy: String) -> String {
            "<!doctype html><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><h1>Actual package CSP boundary</h1>"
        }
        let initial = try await fixture.install(capabilities: [], coordinator: coordinator, html: html(original))
        let firstHost = try await loadedHost(initial.launch)
        let source = "try { await WebAssembly.compile(await (await fetch('./assets/empty.wasm')).arrayBuffer()); return 'compiled'; } catch { return 'denied'; }"
        let refused = try await XCTUnwrap(firstHost.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(refused, "denied", "original app CSP must not silently bypass its missing custom-resource authority")
        firstHost.close()

        let updated = try await fixture.install(capabilities: [], base: initial.launchedRevisionId,
            coordinator: coordinator, html: html(original + "; connect-src 'self' blob: iris-resource:"))
        let secondHost = try await loadedHost(updated.launch)
        defer { secondHost.close() }
        let compiled = try await XCTUnwrap(secondHost.webView).callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(compiled, "compiled", "only the declared, hash-verified local transport is added; no remote origin or native bridge")
    }

    func testDeclaredCameraUsesPromptOnlyForTheActualOwnedFrameAndNeverMicrophone() async throws {
        let fixture = try MultiAppRuntimeFixture()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root,
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy)
        let launch = try await fixture.install(capabilities: ["web.media.camera"], coordinator: coordinator)
        let host = try await loadedHost(launch.launch)
        defer { host.close() }
        let view = try XCTUnwrap(host.webView)
        let captured = expectation(description: "actual owned WebKit frame")
        let probe = MultiAppFrameCapture { captured.fulfill() }
        view.configuration.userContentController.add(probe, name: "irisTestOwnedFrame")
        defer { view.configuration.userContentController.removeScriptMessageHandler(forName: "irisTestOwnedFrame") }
        _ = try await view.evaluateJavaScript("window.webkit.messageHandlers.irisTestOwnedFrame.postMessage(true); null")
        await fulfillment(of: [captured], timeout: 3)
        let frame = try XCTUnwrap(probe.frame)
        let delegate = try XCTUnwrap(view.uiDelegate as? VerifiedRevisionWebView.Coordinator)
        var decisions: [WKPermissionDecision] = []
        delegate.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .camera) { decisions.append($0) }
        XCTAssertEqual(decisions, [.prompt], "installation never grants camera automatically")
        delegate.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .microphone) { decisions.append($0) }
        delegate.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .cameraAndMicrophone) { decisions.append($0) }
        XCTAssertEqual(decisions, [.prompt, .deny, .deny])
        VerifiedRevisionWebView.dismantleUIView(view, coordinator: delegate)
        delegate.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: .camera) { decisions.append($0) }
        XCTAssertEqual(decisions.last, .deny)
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription"))
    }

    private func acceptPhotosChoiceIntoFiles(in host: MultiAppRuntimeHost) async throws {
        // Mutation N2: opening Files directly fails the required titled choice and its actions.
        let title = NativeMediaSaveCopy.choiceTitle(for: .image)
        let offered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "presentedViewController.title == %@", title), object: host.controller)
        let offeredResult = await XCTWaiter.fulfillment(of: [offered], timeout: 5)
        XCTAssertEqual(offeredResult, .completed, "a PNG export must first offer Photos and Files")
        let choice = try XCTUnwrap(host.controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(choice.title, title)
        XCTAssertEqual(choice.actions.count, 3)
        XCTAssertEqual(Set(choice.actions.compactMap(\.title)), Set([
            NativeMediaSaveCopy.saveToPhotosButton, NativeMediaSaveCopy.saveToFilesButton, NativeMediaSaveCopy.cancelButton
        ]))
        XCTAssertEqual(choice.preferredAction?.title, NativeMediaSaveCopy.saveToPhotosButton)
        XCTAssertFalse(host.controller.presentedViewController is UIDocumentPickerViewController,
                       "Files must not open before the person selects it")
        let action = try XCTUnwrap(choice.actions.first { $0.title == NativeMediaSaveCopy.saveToFilesButton })
        let handler = try XCTUnwrap(action.value(forKey: "handler"), "the Files action must have an invokable handler")
        // Mirror the adversarial suite's test-only action invocation. Dismiss first,
        // as UIKit does for a tap, so the handler can present the Files picker.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            choice.dismiss(animated: false) { continuation.resume() }
        }
        typealias ActionHandler = @convention(block) (UIAlertAction) -> Void
        unsafeBitCast(handler as AnyObject, to: ActionHandler.self)(action)
    }

    private func loadedHost(_ launch: VerifiedLaunchDescriptor) async throws -> MultiAppRuntimeHost {
        let loaded = expectation(description: "verified runtime loaded")
        let host = MultiAppRuntimeHost(launch: launch) { value in
            XCTAssertEqual(value, .loaded)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        _ = try XCTUnwrap(host.webView)
        return host
    }
}

@MainActor
private final class MultiAppFrameCapture: NSObject, WKScriptMessageHandler {
    private let received: () -> Void
    private(set) var frame: WKFrameInfo?
    init(received: @escaping () -> Void) { self.received = received }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard frame == nil else { return }
        frame = message.frameInfo
        received()
    }
}

@MainActor
final class MultiAppRuntimeHost {
    let controller: UIHostingController<AnyView>
    private let window = UIWindow(frame: UIScreen.main.bounds)
    private(set) var webView: WKWebView?
    init(launch: VerifiedLaunchDescriptor,
         closeHandleChange: ((NativeVerifiedDocumentCloseHandle?) -> Void)? = nil,
         result: @escaping (NativeShellWebLoadResult) -> Void) {
        let content: VerifiedRevisionWebView
        if let closeHandleChange {
            content = VerifiedRevisionWebView(launch: launch, packagedAPIAdapter: .notConfigured,
                onLoadResult: result, onCloseHandleChange: closeHandleChange)
        } else {
            content = VerifiedRevisionWebView(launch: launch, onLoadResult: result)
        }
        controller = UIHostingController(rootView: AnyView(content))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }
    func findWebView() {
        func visit(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap(visit).first
        }
        webView = visit(controller.view)
    }
    func close() {
        if let view = webView, let delegate = view.uiDelegate as? VerifiedRevisionWebView.Coordinator {
            VerifiedRevisionWebView.dismantleUIView(view, coordinator: delegate)
        }
        controller.rootView = AnyView(EmptyView())
        webView?.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        webView = nil
    }
}

struct MultiAppRuntimeFixture {
    let root: URL
    let identity: NativeShellAppIdentity
    init() throws {
        let suffix = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-multi-runtime-" + suffix)
        identity = .init(appId: "iris.multi." + suffix, projectId: "iris.multi.project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func install(capabilities: [String], base: String? = nil,
                 coordinator: NativeShellLibraryCoordinator, html: String? = nil) async throws -> NativeShellLaunchOutcome {
        let rawFiles: [(String, String, Data)] = [
            ("index.html", "text/html", Data((html ?? "<!doctype html><meta name='viewport' content='width=device-width'><h1>Runtime fixture</h1><input id='photo' type='file' accept='image/*'>").utf8)),
            ("assets/config.json", "application/json", Data("{\"value\":\"actual packaged resource\"}".utf8)),
            ("assets/empty.wasm", "application/wasm", Data([0,97,115,109,1,0,0,0]))]
        let files = rawFiles.map { DeliveryFileReceipt(path: $0.0, sha256: NativeSecurity.sha256($0.2), bytes: $0.2.count, mediaType: $0.1, data: $0.2) }
        let manifest = DeliveryManifestReceipt(displayName: "Runtime fixture", runtimeType: "web", entrypoint: "index.html",
            minShellVersion: "1.0.0", requestedCapabilities: capabilities, dataNamespace: identity.appId, dataUpdatePolicy: "preserve")
        let hash = NativeSecurity.revisionIdentity(appId: identity.appId, projectId: identity.projectId, baseRevisionId: base, manifest: manifest, files: files)
        let nilValue = NSNull(); let stamp = "2026-09-20T00:00:00.000Z"; let approvalID = "approval-" + UUID().uuidString
        let manifestJSON: [String: Any] = ["kind":"iris.mobile-shell.manifest", "version":1, "appId":identity.appId, "projectId":identity.projectId,
            "displayName":manifest.displayName, "runtime":["type":"web","entrypoint":"index.html","minShellVersion":"1.0.0"],
            "capabilities":capabilities,"data":["namespace":identity.appId,"updatePolicy":"preserve"]]
        let revision: [String: Any] = ["kind":"iris.mobile-shell.revision","version":1,"appId":identity.appId,"projectId":identity.projectId,
            "baseRevisionId":base as Any? ?? nilValue,"revisionId":hash.revisionId,"manifestHash":hash.manifestHash,"contentHash":hash.contentHash,
            "createdAt":stamp,"manifest":manifestJSON,"files":files.map { ["path":$0.path,"sha256":$0.sha256,"bytes":$0.bytes,"mediaType":$0.mediaType] as [String:Any] }]
        let approval: [String: Any] = ["kind":"iris.mobile-shell.delivery-approval","version":1,"approvalId":approvalID,"requestId":nilValue,"requestNonce":nilValue,
            "appId":identity.appId,"projectId":identity.projectId,"baseRevisionId":base as Any? ?? nilValue,"approvedRevisionId":hash.revisionId,"approvedContentHash":hash.contentHash,"approvedAt":stamp]
        let envelope: [String: Any] = ["kind":"iris.mobile-shell.delivery-envelope","version":1,"envelopeId":"delivery-"+UUID().uuidString,
            "deliveryNonce":UUID().uuidString.replacingOccurrences(of:"-",with:""),"approvalId":approvalID,"appId":identity.appId,"projectId":identity.projectId,
            "baseRevisionId":base as Any? ?? nilValue,"revisionId":hash.revisionId,"contentHash":hash.contentHash,"issuedAt":stamp,"revision":revision]
        let data = try JSONSerialization.data(withJSONObject: ["format":NativeSecurity.packageFormat,"approval":approval,"envelope":envelope,
            "files":files.map { ["path":$0.path,"mediaType":$0.mediaType,"contentBase64":$0.data.base64EncodedString()] }], options: [.sortedKeys])
        let review = try await coordinator.reviewImport(packageBytes: data)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: identity, revisionId: review.revisionId)
        return try await coordinator.launchActive(identity: identity)
    }
}
#endif
