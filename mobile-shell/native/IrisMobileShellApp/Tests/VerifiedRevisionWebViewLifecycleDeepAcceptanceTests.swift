#if os(iOS)
import CryptoKit
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class VerifiedRevisionWebViewLifecycleDeepAcceptanceTests: XCTestCase {
    func testLoadedHostReportsExactlyOneLaterWebContentTerminationFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appendingPathComponent("index.html")
        try Data("<!doctype html><main>host lifecycle fixture</main>".utf8)
            .write(to: entrypoint)

        let launch = VerifiedLaunchDescriptor(
            revisionId: "rev-sha256:" + String(repeating: "a", count: 64),
            entrypointURL: entrypoint,
            readAccessRootURL: root,
            webStorageIdentity: nil
        )

        var results: [NativeShellWebLoadResult] = []
        let initiallyLoaded = expectation(description: "real WKWebView initial file navigation loaded")
        let runtimeTerminationReported = expectation(
            description: "real Host coordinator reports post-load WebContent termination"
        )

        let represented = VerifiedRevisionWebView(launch: launch) { result in
            results.append(result)
            if results.count == 1 {
                if result == .loaded {
                    initiallyLoaded.fulfill()
                } else {
                    XCTFail("initial navigation unexpectedly failed")
                }
            } else if result == .failed {
                runtimeTerminationReported.fulfill()
            }
        }

        let hostingController = UIHostingController(rootView: represented)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let webView = try await waitForWebView(in: hostingController.view)
        await fulfillment(of: [initiallyLoaded], timeout: 5.0)
        let actualCoordinator = try XCTUnwrap(
            webView.navigationDelegate as? VerifiedRevisionWebView.Coordinator
        )

        // Public WKNavigationDelegate entry point on the ACTUAL Host coordinator.
        // Before the fix this is swallowed because the initial .loaded callback
        // was consumed/nilled by finishInitialLoad().
        actualCoordinator.webViewWebContentProcessDidTerminate(webView)
        await fulfillment(of: [runtimeTerminationReported], timeout: 1.0)
        XCTAssertEqual(results, [.loaded, .failed])

        // A duplicate termination must not produce a second runtime failure or
        // replay the initial-load success callback.
        actualCoordinator.webViewWebContentProcessDidTerminate(webView)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(results, [.loaded, .failed])

        window.isHidden = true
        window.rootViewController = nil
    }

    private func waitForWebView(in root: UIView) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let webView = firstWebView(in: root) { return webView }
            root.setNeedsLayout()
            root.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("WKWebView did not appear in the actual SwiftUI Host hierarchy")
    }

    private func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = firstWebView(in: child) { return found }
        }
        return nil
    }
}

@MainActor
final class VerifiedRevisionWebViewMediaBoundaryTests: XCTestCase {
    func testDownloadedContentHasAnExplicitUIDelegateInsteadOfAmbientMediaDefaults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-media-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appendingPathComponent("index.html")
        try Data("<!doctype html><main>No media request is made by this test.</main>".utf8)
            .write(to: entrypoint)
        let launch = VerifiedLaunchDescriptor(
            revisionId: "rev-sha256:" + String(repeating: "b", count: 64),
            entrypointURL: entrypoint,
            readAccessRootURL: root,
            webStorageIdentity: nil
        )
        let loaded = expectation(description: "harmless local revision loads through actual Host")
        let hostingController = UIHostingController(rootView: VerifiedRevisionWebView(launch: launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("harmless local revision unexpectedly failed to load") }
        })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostingController.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        var actualWebView: WKWebView?
        while Date() < deadline, actualWebView == nil {
            actualWebView = firstWebView(in: hostingController.view)
            if actualWebView == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        let webView = try XCTUnwrap(actualWebView, "actual Host must create its WKWebView")
        let navigationDelegate = try XCTUnwrap(
            webView.navigationDelegate as? VerifiedRevisionWebView.Coordinator
        )
        XCTAssertNotNil(
            webView.uiDelegate,
            "nil WKUIDelegate inherits Safari-style file upload and prompted media capture; no-native-grants requires explicit denial"
        )
        XCTAssertTrue(
            (webView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === navigationDelegate,
            "the actual Host must own both navigation and media permission callbacks"
        )
        await fulfillment(of: [loaded], timeout: 5)
    }

    private func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = firstWebView(in: child) { return found }
        }
        return nil
    }
}

@MainActor
final class VerifiedRevisionWebViewMediaCallbackAcceptanceTests: XCTestCase {
    func testActualCoordinatorDeniesMediaCaptureUsingRealWebKitFrameObjectsAndStillResolvesAfterTeardown() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("modern hosted callback lane requires iOS 18.4+")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-media-callback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appendingPathComponent("index.html")
        try Data("<!doctype html><main>media callback fixture; no media request</main>".utf8)
            .write(to: entrypoint)
        let launch = VerifiedLaunchDescriptor(
            revisionId: "rev-sha256:" + String(repeating: "c", count: 64),
            entrypointURL: entrypoint,
            readAccessRootURL: root,
            webStorageIdentity: nil
        )
        let loaded = expectation(description: "actual Host loads harmless callback fixture")
        let hostingController = UIHostingController(rootView: VerifiedRevisionWebView(launch: launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("harmless callback fixture unexpectedly failed") }
        })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostingController.view.layoutIfNeeded()

        let actualWebView = try await waitForWebView(in: hostingController.view)
        await fulfillment(of: [loaded], timeout: 5)
        let actualCoordinator = try XCTUnwrap(
            actualWebView.navigationDelegate as? VerifiedRevisionWebView.Coordinator
        )
        XCTAssertTrue((actualWebView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === actualCoordinator)

        let frameCaptured = expectation(description: "fixture WebKit produced a real frame object")
        let frameCapture = WebKitFrameCaptureDelegate(expectation: frameCaptured)
        let probeConfiguration = WKWebViewConfiguration()
        probeConfiguration.websiteDataStore = .nonPersistent()
        let probeWebView = WKWebView(frame: .zero, configuration: probeConfiguration)
        probeWebView.navigationDelegate = frameCapture
        probeWebView.loadHTMLString("<!doctype html><main>frame probe</main>", baseURL: nil)
        await fulfillment(of: [frameCaptured], timeout: 5)
        let frame = try XCTUnwrap(frameCapture.sourceFrame)
        let origin = frame.securityOrigin

        for captureType: WKMediaCaptureType in [.camera, .microphone, .cameraAndMicrophone] {
            var decisions: [WKPermissionDecision] = []
            actualCoordinator.webView(
                actualWebView,
                requestMediaCapturePermissionFor: origin,
                initiatedByFrame: frame,
                type: captureType
            ) { decisions.append($0) }
            XCTAssertEqual(decisions, [.deny])
        }

        VerifiedRevisionWebView.dismantleUIView(actualWebView, coordinator: actualCoordinator)
        XCTAssertTrue(
            (actualWebView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === actualCoordinator,
            "a retained WebView must keep the denying UI delegate alive after SwiftUI dismantle"
        )
        XCTAssertNil(actualWebView.navigationDelegate)

        var staleDecision: WKPermissionDecision?
        actualCoordinator.webView(
            actualWebView,
            requestMediaCapturePermissionFor: origin,
            initiatedByFrame: frame,
            type: .camera
        ) { staleDecision = $0 }
        XCTAssertEqual(staleDecision, .deny, "teardown must not strand a WebKit permission callback")
    }

    func testActualCoordinatorCancelsWebKitOpenPanelUsingRealParametersAndStillCancelsAfterTeardown() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("public WKUIDelegate file-panel callback requires iOS 18.4+")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-open-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appendingPathComponent("index.html")
        try Data("<!doctype html><input id='iris-upload-probe' type='file' aria-label='Iris upload denial probe'>".utf8)
            .write(to: entrypoint)
        let launch = VerifiedLaunchDescriptor(
            revisionId: "rev-sha256:" + String(repeating: "e", count: 64),
            entrypointURL: entrypoint,
            readAccessRootURL: root,
            webStorageIdentity: nil
        )
        let loaded = expectation(description: "actual Host loads synthetic upload-control fixture")
        let hostingController = UIHostingController(rootView: VerifiedRevisionWebView(launch: launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("upload-control fixture unexpectedly failed") }
        })
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostingController.view.layoutIfNeeded()

        let actualWebView = try await waitForWebView(in: hostingController.view)
        await fulfillment(of: [loaded], timeout: 5)
        let actualCoordinator = try XCTUnwrap(
            actualWebView.navigationDelegate as? VerifiedRevisionWebView.Coordinator
        )
        XCTAssertTrue(
            (actualWebView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === actualCoordinator,
            "actual Host must install the denying coordinator before a probe is attached"
        )

        let productionCallback = expectation(description: "production coordinator handled real WebKit open-panel parameters")
        let probe = WebKitOpenPanelForwardingProbe(
            productionCoordinator: actualCoordinator,
            expectation: productionCallback
        )
        actualWebView.uiDelegate = probe
        defer { actualWebView.uiDelegate = actualCoordinator }

        _ = try await actualWebView.evaluateJavaScript(
            "document.getElementById('iris-upload-probe').click()"
        )
        await fulfillment(of: [productionCallback], timeout: 5)

        XCTAssertEqual(probe.productionCompletionCount, 1)
        XCTAssertTrue(probe.productionReturnedNil)
        let parameters = try XCTUnwrap(probe.parameters)
        let frame = try XCTUnwrap(probe.frame)

        actualWebView.uiDelegate = actualCoordinator
        XCTAssertTrue((actualWebView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === actualCoordinator)

        VerifiedRevisionWebView.dismantleUIView(actualWebView, coordinator: actualCoordinator)
        XCTAssertTrue(
            (actualWebView.uiDelegate as? VerifiedRevisionWebView.Coordinator) === actualCoordinator,
            "retained WebView must keep explicit denial after SwiftUI dismantle"
        )
        XCTAssertNil(actualWebView.navigationDelegate)

        var staleCompletionCount = 0
        var staleReturnedNil = false
        actualCoordinator.webView(
            actualWebView,
            runOpenPanelWith: parameters,
            initiatedByFrame: frame
        ) { urls in
            staleCompletionCount += 1
            staleReturnedNil = urls == nil
        }
        XCTAssertEqual(staleCompletionCount, 1)
        XCTAssertTrue(staleReturnedNil)
    }

    func testRetainedWebViewOwnsDenyCoordinatorUntilTheWebViewIsReleased() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("modern retained-boundary lane requires iOS 18.4+")
        }

        var retained: WKWebView?
        let weakWebView: WeakMediaBoundaryWebViewBox
        let weakBox: WeakMediaBoundaryCoordinatorBox
        (retained, weakWebView, weakBox) = try await makeDismantledRetainedHostWebView()

        XCTAssertTrue(weakWebView.value === retained)
        XCTAssertNotNil(weakBox.value, "dismantled retained WebView must keep the denying coordinator alive")
        XCTAssertTrue(
            retained?.uiDelegate === weakBox.value,
            "the retained WebView must still expose that same denying coordinator as its UI delegate"
        )

        retained = nil
        // Yielding the Swift executor alone does not establish that UIKit's
        // hierarchy or WebKit's queued teardown released the view. Observe
        // both owners and allow bounded real main-queue cleanup turns.
        let releaseDeadline = Date().addingTimeInterval(1)
        while Date() < releaseDeadline,
              weakWebView.value != nil || weakBox.value != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    continuation.resume()
                }
            }
        }
        XCTAssertNil(weakWebView.value, "the actual hosted WebView must release after hierarchy teardown and its final retained reference")
        XCTAssertNil(weakBox.value, "releasing the WebView must release its retained coordinator; no cycle is allowed")
    }

    private func makeDismantledRetainedHostWebView() async throws -> (WKWebView, WeakMediaBoundaryWebViewBox, WeakMediaBoundaryCoordinatorBox) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-host-media-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entrypoint = root.appendingPathComponent("index.html")
        try Data("<!doctype html><main>retention fixture</main>".utf8).write(to: entrypoint)
        let launch = VerifiedLaunchDescriptor(
            revisionId: "rev-sha256:" + String(repeating: "f", count: 64),
            entrypointURL: entrypoint,
            readAccessRootURL: root,
            webStorageIdentity: nil
        )
        let loaded = expectation(description: "retention fixture loaded")
        let hostingController = UIHostingController(rootView: AnyView(VerifiedRevisionWebView(launch: launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("retention fixture unexpectedly failed") }
        }))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostingController.view.layoutIfNeeded()

        let webView = try await waitForWebView(in: hostingController.view)
        await fulfillment(of: [loaded], timeout: 5)
        let coordinator = try XCTUnwrap(
            webView.navigationDelegate as? VerifiedRevisionWebView.Coordinator
        )
        let weakBox = WeakMediaBoundaryCoordinatorBox(coordinator)
        let weakWebView = WeakMediaBoundaryWebViewBox(webView)

        VerifiedRevisionWebView.dismantleUIView(webView, coordinator: coordinator)
        hostingController.rootView = AnyView(EmptyView())
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
        webView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        return (webView, weakWebView, weakBox)
    }

    private func waitForWebView(in root: UIView) async throws -> WKWebView {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let webView = firstWebView(in: root) { return webView }
            root.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("WKWebView did not appear in the actual SwiftUI Host hierarchy")
    }

    private func firstWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = firstWebView(in: child) { return found }
        }
        return nil
    }
}

@MainActor
private final class WebKitFrameCaptureDelegate: NSObject, WKNavigationDelegate {
    let expectation: XCTestExpectation
    private(set) var sourceFrame: WKFrameInfo?

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if sourceFrame == nil {
            sourceFrame = navigationAction.sourceFrame
            expectation.fulfill()
        }
        decisionHandler(.allow)
    }
}

private final class WeakMediaBoundaryWebViewBox {
    weak var value: WKWebView?

    init(_ value: WKWebView) {
        self.value = value
    }
}

private final class WeakMediaBoundaryCoordinatorBox {
    weak var value: VerifiedRevisionWebView.Coordinator?

    init(_ value: VerifiedRevisionWebView.Coordinator) {
        self.value = value
    }
}

@available(iOS 18.4, *)
@MainActor
private final class WebKitOpenPanelForwardingProbe: NSObject, WKUIDelegate {
    let productionCoordinator: VerifiedRevisionWebView.Coordinator
    let expectation: XCTestExpectation
    private(set) var parameters: WKOpenPanelParameters?
    private(set) var frame: WKFrameInfo?
    private(set) var productionCompletionCount = 0
    private(set) var productionReturnedNil = false

    init(
        productionCoordinator: VerifiedRevisionWebView.Coordinator,
        expectation: XCTestExpectation
    ) {
        self.productionCoordinator = productionCoordinator
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

        productionCoordinator.webView(
            webView,
            runOpenPanelWith: parameters,
            initiatedByFrame: frame
        ) { [weak self] urls in
            guard let self else { return }
            productionCompletionCount += 1
            productionReturnedNil = urls == nil
            expectation.fulfill()
        }

        // The probe owns the real WebKit callback while it is installed.
        // Always cancel it directly, even if the production result is wrong,
        // so this test can never present Photos/Files picker UI.
        completionHandler(nil)
    }
}

@MainActor
final class NativeShellWebsiteInstallHostAdversarialTests: XCTestCase {
    func testOneConfirmStagesActivatesAndOpensButPreparationCreatesNoApprovalOrRevision() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(fixture.primaryIntentURL)
        try await waitUntil("website review did not become ready") { website.review != nil }
        let review = try XCTUnwrap(website.review)

        let pendingBeforeConfirm = await coordinator.pendingPackageReview()
        let entryBeforeConfirm = try await coordinator.libraryEntry(identity: review.identity)
        XCTAssertNil(pendingBeforeConfirm)
        XCTAssertNil(entryBeforeConfirm)
        XCTAssertNil(appModel.launch)

        website.installAndOpen()
        try await waitUntil("Install & Open did not complete") {
            !website.isPresented && !website.isCommitting
        }
        let result = try XCTUnwrap(website.presentationWasDismissed())
        XCTAssertEqual(result.revisionId, review.revisionId)

        let installedEntry = try await coordinator.libraryEntry(identity: review.identity)
        let installed = try XCTUnwrap(installedEntry)
        XCTAssertEqual(installed.currentRevisionId, review.revisionId)
        XCTAssertEqual(installed.stagedRevisions.map(\.revisionId), [])

        appModel.adoptVerifiedWebsiteLaunch(result)
        XCTAssertEqual(appModel.launch?.launchedRevisionId, review.revisionId)
        XCTAssertEqual(appModel.launchSourceSlug, fixture.primarySlug)
    }

    func testActiveAppAndExistingReviewBothDeferWebsiteIntentWithoutReplacement() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(
            coordinator: coordinator,
            bundledDemoPackage: fixture.packageBytes
        )
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        appModel.reviewBundledDemo()
        try await waitUntil("legacy review did not appear") { appModel.review != nil }
        let originalReviewToken = try XCTUnwrap(appModel.review?.reviewToken)
        XCTAssertTrue(appModel.hasBlockingPresentation)

        website.receive(
            fixture.secondaryIntentURL,
            deferUntilCurrentAppCloses: appModel.hasBlockingPresentation
        )
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
        XCTAssertFalse(website.isPresented)
        XCTAssertEqual(appModel.review?.reviewToken, originalReviewToken)
        let deferredReviewRequestCount = await transport.totalRequestCount()
        XCTAssertEqual(deferredReviewRequestCount, 0)

        website.dismissDeferredRequest()
        appModel.cancelReview()
        appModel.reviewSheetDidClose()
        try await waitUntilAsync("legacy coordinator review did not clear") {
            await coordinator.pendingPackageReview() == nil
        }

        let firstResult = try await installWebsiteApp(
            website,
            url: fixture.primaryIntentURL
        )
        appModel.adoptVerifiedWebsiteLaunch(firstResult)
        let activeLaunchID = try XCTUnwrap(appModel.launch?.id)

        website.receive(
            fixture.secondaryIntentURL,
            deferUntilCurrentAppCloses: appModel.hasBlockingPresentation
        )
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
        XCTAssertFalse(website.isPresented)
        XCTAssertEqual(appModel.launch?.id, activeLaunchID)
        XCTAssertEqual(appModel.launchSourceSlug, fixture.primarySlug)
    }

    func testStayHereDismissesOnlyDeferredWebsiteRequestAndPreservesActiveApp() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        let firstResult = try await installWebsiteApp(
            website,
            url: fixture.primaryIntentURL
        )
        appModel.adoptVerifiedWebsiteLaunch(firstResult)
        let launchBeforeStay = try XCTUnwrap(appModel.launch)

        website.receive(
            fixture.secondaryIntentURL,
            deferUntilCurrentAppCloses: appModel.hasBlockingPresentation
        )
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
        website.dismissDeferredRequest()

        XCTAssertNil(website.deferredSlug)
        XCTAssertFalse(website.isPresented)
        XCTAssertEqual(appModel.launch?.id, launchBeforeStay.id)
        XCTAssertEqual(appModel.launch?.launchedRevisionId, launchBeforeStay.launchedRevisionId)
        XCTAssertEqual(appModel.launchSourceSlug, fixture.primarySlug)
    }

    func testMalformedWebsiteURLNeverFetchesCatalogOrPackage() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(URL(string: "https://evil.example/iris/apps/\(fixture.primarySlug)")!)

        XCTAssertTrue(website.isPresented)
        XCTAssertNotNil(website.failureMessage)
        XCTAssertNil(website.review)
        let malformedRequestCount = await transport.totalRequestCount()
        let malformedPendingReview = await coordinator.pendingPackageReview()
        XCTAssertEqual(malformedRequestCount, 0)
        XCTAssertNil(malformedPendingReview)
    }

    func testCancelledLateDownloadCompletionCannotPresentReviewOrInstall() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture, holdPackageResponses: true)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(fixture.primaryIntentURL)
        try await waitUntilAsync("package request did not begin") {
            await transport.packageRequestCount() == 1
        }
        website.cancel()
        XCTAssertFalse(website.isPresented)
        await transport.releaseHeldPackages()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(website.isPresented)
        XCTAssertNil(website.review)
        XCTAssertNil(website.failureMessage)
        let pendingAfterLateCompletion = await coordinator.pendingPackageReview()
        let entryAfterLateCompletion = try await coordinator.libraryEntry(identity: fixture.identity)
        XCTAssertNil(pendingAfterLateCompletion)
        XCTAssertNil(entryAfterLateCompletion)
    }

    func testDuplicateSameLinkWhileReviewPresentedDoesNotRedownload() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(fixture.primaryIntentURL)
        try await waitUntil("first website review did not become ready") { website.review != nil }
        let firstReviewToken = try XCTUnwrap(website.review?.reviewToken)
        let requestsBeforeDuplicate = await transport.totalRequestCount()
        XCTAssertEqual(requestsBeforeDuplicate, 2)

        website.receive(fixture.primaryIntentURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(website.review?.reviewToken, firstReviewToken)
        let requestsAfterDuplicate = await transport.totalRequestCount()
        let packageRequestsAfterDuplicate = await transport.packageRequestCount()
        XCTAssertEqual(requestsAfterDuplicate, 2)
        XCTAssertEqual(packageRequestsAfterDuplicate, 1)
    }

    func testQueuedURLDuringCommitSurvivesAndDoesNotReplaceJustOpenedApp() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockingFileManager = WebsiteHostBlockingStageFileManager()
        let coordinator = NativeShellLibraryCoordinator(
            rootURL: root,
            fileManager: blockingFileManager
        )
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(fixture.primaryIntentURL)
        try await waitUntil("website review did not become ready") { website.review != nil }
        website.installAndOpen()
        try await waitUntil("real revision store did not reach staging promotion") {
            blockingFileManager.didReachStagePromotion
        }
        XCTAssertTrue(website.isCommitting)

        website.receive(fixture.secondaryIntentURL)
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
        XCTAssertTrue(website.isCommitting)
        let requestsWhileQueued = await transport.totalRequestCount()
        XCTAssertEqual(requestsWhileQueued, 2)

        blockingFileManager.releaseStagePromotion()
        try await waitUntil("first committed install did not finish") {
            !website.isPresented && !website.isCommitting
        }
        let firstResult = try XCTUnwrap(website.presentationWasDismissed())
        XCTAssertEqual(firstResult.slug, fixture.primarySlug)
        appModel.adoptVerifiedWebsiteLaunch(firstResult)

        XCTAssertEqual(appModel.launchSourceSlug, fixture.primarySlug)
        XCTAssertEqual(appModel.launch?.launchedRevisionId, fixture.revisionId)
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
        XCTAssertFalse(website.isPresented)
        let requestsAfterFirstOpen = await transport.totalRequestCount()
        XCTAssertEqual(requestsAfterFirstOpen, 2)
    }

    func testStaleSameRevisionLoadCallbackCannotMarkReopenedPresentationLoaded() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        let installed = try await installWebsiteApp(
            website,
            url: fixture.primaryIntentURL
        )
        appModel.adoptVerifiedWebsiteLaunch(installed)
        let firstLaunch = try XCTUnwrap(appModel.launch)
        let firstPresentationID = appModel.launchPresentationID
        appModel.receivedWebLoadResult(
            .loaded,
            launchID: firstLaunch.id,
            presentationID: firstPresentationID
        )
        XCTAssertEqual(appModel.launchLoadResult, .loaded)

        appModel.closeApp()
        appModel.appSheetDidClose()
        XCTAssertNil(appModel.launch)
        appModel.open(identity: fixture.identity)
        try await waitUntil("same revision did not reopen") { appModel.launch != nil }
        let reopenedLaunch = try XCTUnwrap(appModel.launch)
        let secondPresentationID = appModel.launchPresentationID
        XCTAssertEqual(reopenedLaunch.id, firstLaunch.id, "same revision intentionally reuses launch identity")
        XCTAssertNotEqual(secondPresentationID, firstPresentationID)
        XCTAssertNil(appModel.launchLoadResult)

        appModel.receivedWebLoadResult(
            .loaded,
            launchID: firstLaunch.id,
            presentationID: firstPresentationID
        )
        XCTAssertNil(appModel.launchLoadResult, "stale callback must not mark the reopened page loaded")

        appModel.receivedWebLoadResult(
            .loaded,
            launchID: reopenedLaunch.id,
            presentationID: secondPresentationID
        )
        XCTAssertEqual(appModel.launchLoadResult, .loaded)
    }

    func testSecondURLBeforeWebsiteSheetOnDismissCannotEraseCompletedResultOrOpenSecondModal() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let appModel = NativeShellAppModel(coordinator: coordinator)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = makeWebsiteModel(
            coordinator: coordinator,
            transport: transport,
            appModel: appModel
        )

        website.receive(fixture.primaryIntentURL)
        try await waitUntil("first website review did not become ready") { website.review != nil }
        website.installAndOpen()
        try await waitUntil("first install result was not ready for sheet dismissal") {
            !website.isPresented && !website.isCommitting
        }

        // Deliberately do NOT call presentationWasDismissed() yet. SwiftUI has
        // observed isPresented=false, but the actual website sheet's onDismiss
        // has not handed the completed result to NativeShellAppModel.
        XCTAssertNil(appModel.launch)
        website.receive(fixture.secondaryIntentURL)

        XCTAssertFalse(
            website.isPresented,
            "a second URL must not open a new website modal before the first sheet's onDismiss adopts its result"
        )
        XCTAssertEqual(
            website.deferredSlug,
            fixture.secondarySlug,
            "the second valid intent must queue behind the first completed-but-not-dismissed result"
        )
        let firstResult = try XCTUnwrap(
            website.presentationWasDismissed(),
            "the first completed result must survive until the real sheet onDismiss consumes it"
        )
        XCTAssertEqual(firstResult.slug, fixture.primarySlug)
        appModel.adoptVerifiedWebsiteLaunch(firstResult)
        XCTAssertEqual(appModel.launchSourceSlug, fixture.primarySlug)
        XCTAssertEqual(website.deferredSlug, fixture.secondarySlug)
    }

    func testLocalReimportOfCurrentFirstRevisionReverifiesAndOpensWithoutRestageOrDataLoss() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)

        let initialReview = try await coordinator.reviewImport(packageBytes: fixture.packageBytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: initialReview.reviewToken,
            packageSHA256: initialReview.packageSHA256
        )
        try await coordinator.activate(
            identity: initialReview.identity,
            revisionId: initialReview.revisionId
        )
        let entryBeforeReimportValue = try await coordinator.libraryEntry(identity: initialReview.identity)
        let entryBeforeReimport = try XCTUnwrap(entryBeforeReimportValue)
        XCTAssertEqual(entryBeforeReimport.currentRevisionId, initialReview.revisionId)

        let readerData = try await coordinator.readerDataDirectory(
            identity: initialReview.identity,
            namespace: initialReview.dataNamespace
        )
        let sentinel = readerData.appendingPathComponent("local-reimport-sentinel.txt")
        try Data("preserve-local-reader-data".utf8).write(to: sentinel)

        let appModel = NativeShellAppModel(
            coordinator: coordinator,
            bundledDemoPackage: fixture.packageBytes
        )
        appModel.reviewBundledDemo()
        try await waitUntil("same raw package did not reach local review") { appModel.review != nil }
        let reimportReview = try XCTUnwrap(appModel.review)
        XCTAssertEqual(reimportReview.identity, initialReview.identity)
        XCTAssertEqual(reimportReview.revisionId, initialReview.revisionId)
        XCTAssertNil(reimportReview.baseRevisionId, "fixture intentionally remains a first revision")

        appModel.approveLocallyAndOpen(review: reimportReview)
        appModel.reviewSheetDidClose()
        try await waitUntil("local re-import did not finish") { !appModel.isInstalling }

        XCTAssertNil(
            appModel.errorMessage,
            "re-importing the exact active verified revision should reverify/open instead of surfacing baseMismatch"
        )
        let launch = try XCTUnwrap(appModel.launch)
        XCTAssertEqual(launch.identity, initialReview.identity)
        XCTAssertEqual(launch.launchedRevisionId, initialReview.revisionId)
        XCTAssertFalse(launch.didFallback)

        let entryAfterReimportValue = try await coordinator.libraryEntry(identity: initialReview.identity)
        let entryAfterReimport = try XCTUnwrap(entryAfterReimportValue)
        XCTAssertEqual(entryAfterReimport.currentRevisionId, entryBeforeReimport.currentRevisionId)
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "preserve-local-reader-data"
        )
    }

    private func makeWebsiteModel(
        coordinator: NativeShellLibraryCoordinator,
        transport: WebsiteHostTransport,
        appModel: NativeShellAppModel
    ) -> NativeShellWebsiteInstallModel {
        NativeShellWebsiteInstallModel(
            coordinator: coordinator,
            client: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll,
            canPresent: { [weak appModel] in
                guard let appModel else { return false }
                return !appModel.hasBlockingPresentation && appModel.review == nil
            },
            prepareHost: { [weak appModel] in
                guard let appModel else { return false }
                return await appModel.prepareForDirectWebsiteIntent()
            }
        )
    }

    private func installWebsiteApp(
        _ website: NativeShellWebsiteInstallModel,
        url: URL
    ) async throws -> NativeWebsiteInstallResult {
        website.receive(url)
        try await waitUntil("website review did not become ready") { website.review != nil }
        website.installAndOpen()
        try await waitUntil("website install did not produce a dismissal result") {
            !website.isPresented && !website.isCommitting
        }
        return try XCTUnwrap(website.presentationWasDismissed())
    }

    private func waitUntil(
        _ failure: String,
        timeout: TimeInterval = 5,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(failure)
        throw WebsiteHostTestError.timedOut(failure)
    }

    private func waitUntilAsync(
        _ failure: String,
        timeout: TimeInterval = 5,
        predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(failure)
        throw WebsiteHostTestError.timedOut(failure)
    }
}

@MainActor
final class NativeShellWebsiteRuntimeBoundaryTests: XCTestCase {
    func testUnsupportedRuntimeRestrictionStopsBeforeCatalogOrPackageRequest() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = NativeShellWebsiteInstallModel(
            coordinator: coordinator,
            client: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll,
            runtimeSupportsDownloadedContent: { false },
            prepareHost: { true }
        )

        website.receive(fixture.primaryIntentURL)

        XCTAssertTrue(website.isPresented)
        XCTAssertNil(website.review)
        XCTAssertFalse(website.isCommitting)
        XCTAssertFalse(website.canRetry)
        XCTAssertTrue(website.failureMessage?.contains("iOS 18.4") == true)
        let requests = await transport.totalRequestCount()
        let entry = try await coordinator.libraryEntry(identity: fixture.identity)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(entry)
    }
}

@MainActor
final class NativeShellLocalRuntimeBoundaryTests: XCTestCase {
    func testRestrictedRuntimeDoesNotOpenOrChangeAnInstalledRevisionOrItsData() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let review = try await coordinator.reviewImport(packageBytes: fixture.packageBytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken,
            packageSHA256: review.packageSHA256
        )
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        let readerData = try await coordinator.readerDataDirectory(
            identity: review.identity,
            namespace: review.dataNamespace
        )
        let sentinel = readerData.appendingPathComponent("restricted-runtime-sentinel.txt")
        try Data("keep-existing-data".utf8).write(to: sentinel)
        let model = NativeShellAppModel(
            coordinator: coordinator,
            runtimeSupportsDownloadedContent: { false }
        )

        model.open(identity: review.identity)

        XCTAssertEqual(model.errorMessage, VerifiedRevisionWebView.unsupportedRuntimeMessage)
        XCTAssertNil(model.launch)
        XCTAssertNil(model.retryAction)
        XCTAssertFalse(model.hasBlockingPresentation)
        let entry = try await coordinator.libraryEntry(identity: review.identity)
        XCTAssertEqual(entry?.currentRevisionId, review.revisionId)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep-existing-data")
    }

    func testRestrictedLocalInstallAndOpenKeepsReviewUnconsumedAndDoesNotStage() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let model = NativeShellAppModel(
            coordinator: coordinator,
            bundledDemoPackage: fixture.packageBytes,
            runtimeSupportsDownloadedContent: { false }
        )
        model.reviewBundledDemo()
        let deadline = Date().addingTimeInterval(5)
        while model.review == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let review = try XCTUnwrap(model.review, "actual local review must be ready before the denied action")

        model.approveLocallyAndOpen(review: review)

        XCTAssertEqual(model.errorMessage, VerifiedRevisionWebView.unsupportedRuntimeMessage)
        XCTAssertEqual(model.review?.reviewToken, review.reviewToken)
        XCTAssertFalse(model.isInstalling)
        XCTAssertNil(model.launch)
        let pending = await coordinator.pendingPackageReview()
        let entry = try await coordinator.libraryEntry(identity: review.identity)
        XCTAssertEqual(pending?.reviewToken, review.reviewToken)
        XCTAssertNil(entry, "an unavailable runtime must not turn Install & Open into a hidden staging operation")
    }
}

@MainActor
final class NativeShellPublicListingIntentAcceptanceTests: XCTestCase {
    func testActualPublicListingURLsPreserveOnlyTheirAppSlug() throws {
        for slug in ["kneecap", "freeharmony", "lunara"] {
            let url = try XCTUnwrap(URL(string: "https://publikhq.com/\(slug)"))
            XCTAssertEqual(try NativeWebsiteInstallIntent.parse(url).slug, slug)
        }
    }

    func testPublicListingIntentsRejectAuthorityAndPathSmuggling() {
        let rejected = [
            "http://publikhq.com/kneecap",
            "https://www.publikhq.com/kneecap",
            "https://publikhq.com.evil.example/kneecap",
            "https://publikhq.com:443/kneecap",
            "https://@publikhq.com/kneecap",
            "https://user@publikhq.com/kneecap",
            "https://publikhq.com/kneecap/",
            "https://publikhq.com/kneecap/install/mac-iphone",
            "https://publikhq.com/kneecap?package=https://evil.example/a.irisapp",
            "https://publikhq.com/kneecap?approve=1",
            "https://publikhq.com/kneecap?",
            "https://publikhq.com/kneecap#approve",
            "https://publikhq.com/kneecap#",
            "https://publikhq.com/%6Bneecap",
            "https://publikhq.com/kneecap%2Fextra",
            "https://publikhq.com/other/../kneecap",
            "https://publikhq.com/./kneecap",
            "https://publikhq.com//kneecap",
            "https://publikhq.com/",
            "https://github.com/Blueturboguy07/kneecap",
            "iris://guide/kneecap?version=5&branch=macos:ios&step=0",
        ]
        for raw in rejected {
            guard let url = URL(string: raw) else { continue }
            XCTAssertThrowsError(try NativeWebsiteInstallIntent.parse(url), raw)
        }
    }

    func testPublicRepositoryMetadataDoesNotBecomeAnInstallablePackage() async throws {
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let transport = PublicListingMetadataOnlyTransport()
        let flow = NativeWebsiteInstallFlow(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: transport)
        )
        do {
            _ = try await flow.prepare(url: URL(string: "https://publikhq.com/kneecap")!)
            XCTFail("a source repository link is not an approved runnable package")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .mobileShellUnavailable(slug: "kneecap"))
        } catch {
            XCTFail("listing should reach catalog availability checks, not fail URL routing: \(error)")
        }
        let requests = await transport.requestCount
        let pending = await coordinator.pendingPackageReview()
        let entries = try await coordinator.refreshLibrary()
        XCTAssertEqual(requests, 1, "only the catalog may be requested")
        XCTAssertNil(pending)
        XCTAssertTrue(entries.isEmpty)
    }

    func testListingAndCanonicalAliasesDoNotReplaceOrRedownloadTheSameReview() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = NativeShellWebsiteInstallModel(
            coordinator: coordinator,
            client: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll,
            prepareHost: { true }
        )
        website.receive(fixture.primaryIntentURL)
        let deadline = Date().addingTimeInterval(5)
        while website.review == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let token = try XCTUnwrap(website.review?.reviewToken)
        website.receive(URL(string: "https://publikhq.com/\(fixture.primarySlug)")!)
        try await Task.sleep(nanoseconds: 100_000_000)
        let requests = await transport.totalRequestCount()
        XCTAssertEqual(website.review?.reviewToken, token)
        XCTAssertEqual(requests, 2, "URL spelling must not cause a second catalog/package fetch")
        XCTAssertNil(website.failureMessage)
    }

    func testSameAppListingAliasDuringCommitDoesNotQueueAnUnrequestedReopen() async throws {
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = WebsiteHostBlockingStageFileManager()
        defer { blocker.releaseStagePromotion() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, fileManager: blocker)
        let transport = WebsiteHostTransport(fixture: fixture)
        let website = NativeShellWebsiteInstallModel(
            coordinator: coordinator,
            client: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll,
            prepareHost: { true }
        )
        website.receive(URL(string: "https://publikhq.com/\(fixture.primarySlug)")!)
        let reviewDeadline = Date().addingTimeInterval(5)
        while website.review == nil, Date() < reviewDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(website.review, "a listing URL with a valid bound package must reach review")
        website.installAndOpen()
        let stageDeadline = Date().addingTimeInterval(5)
        while !blocker.didReachStagePromotion, Date() < stageDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(blocker.didReachStagePromotion)
        XCTAssertTrue(website.isCommitting)

        website.receive(fixture.primaryIntentURL)

        XCTAssertNil(website.deferredSlug, "the same app must not be queued to reopen after the reader later closes it")
        let requestsDuringCommit = await transport.totalRequestCount()
        XCTAssertEqual(requestsDuringCommit, 2)
        blocker.releaseStagePromotion()
        let finishDeadline = Date().addingTimeInterval(5)
        while website.isCommitting, Date() < finishDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result = try XCTUnwrap(website.presentationWasDismissed())
        XCTAssertEqual(result.slug, fixture.primarySlug)
        XCTAssertEqual(result.identity, fixture.identity)
        XCTAssertEqual(result.revisionId, fixture.revisionId)
        XCTAssertNil(website.deferredSlug)
    }
}

private actor PublicListingMetadataOnlyTransport: PublikMobileHTTPTransport {
    private(set) var requestCount = 0

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        requestCount += 1
        guard request.url == PublikMobileCatalogClient.catalogURL else {
            throw WebsiteHostTestError.unexpectedRequest(request.url)
        }
        let body = Data("""
        {"apps":[{"slug":"kneecap","name":"kneecap","guideSlug":"kneecap","repositoryUrl":"https://github.com/Blueturboguy07/kneecap"}]}
        """.utf8)
        guard body.count <= maximumBytes else { throw WebsiteHostTestError.responseTooLarge }
        return PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: "application/json",
            declaredContentLength: body.count,
            finalURL: request.url,
            body: body
        )
    }
}

@MainActor
final class NativeMobileUpdateHistoryAcceptanceTests: XCTestCase {
    func testCancellingLocalUpdateReviewLeavesTheCurrentVersionAndDataUntouched() async throws {
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let r1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let dataRoot = try await coordinator.readerDataDirectory(identity: fixture.identity, namespace: fixture.namespace)
        let note = dataRoot.appendingPathComponent("cancel-sentinel.txt")
        try Data("not reset by cancel".utf8).write(to: note)
        let model = NativeShellAppModel(coordinator: coordinator,
            bundledDemoPackage: try fixture.package(number: 2, base: r1))
        model.reviewBundledDemo()
        let deadline = Date().addingTimeInterval(5)
        while model.review == nil, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = try XCTUnwrap(model.review)
        model.cancelReview()
        model.reviewSheetDidClose()
        while await coordinator.pendingPackageReview() != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pending = await coordinator.pendingPackageReview()
        let entry = try await coordinator.libraryEntry(identity: fixture.identity)
        XCTAssertNil(model.review)
        XCTAssertNil(model.launch)
        XCTAssertNil(pending)
        XCTAssertEqual(entry?.currentRevisionId, r1)
        XCTAssertEqual(entry?.revisions.count, 1)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "not reset by cancel")
    }

    func testThreeRealRevisionsKeepHistoryAndDataAcrossRevertAndCoordinatorRestart() async throws {
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let v1 = try fixture.package(number: 1, base: nil)
        let r1 = try await fixture.install(v1, through: coordinator)
        let dataRoot = try await coordinator.readerDataDirectory(identity: fixture.identity, namespace: fixture.namespace)
        let note = dataRoot.appendingPathComponent("synthetic-note.txt")
        try Data("keep-my-test-note".utf8).write(to: note)
        let v2 = try fixture.package(number: 2, base: r1)
        let r2 = try await fixture.install(v2, through: coordinator)
        let v3 = try fixture.package(number: 3, base: r2)
        let r3 = try await fixture.install(v3, through: coordinator)

        let entryValue = try await coordinator.libraryEntry(identity: fixture.identity)
        let entry = try XCTUnwrap(entryValue)
        XCTAssertEqual(entry.currentRevisionId, r3)
        XCTAssertEqual(entry.revisions.count, 3)
        let rows = NativeRevisionHistoryRow.rows(for: entry)
        XCTAssertEqual(rows.first?.id, r3)
        XCTAssertEqual(rows.first?.state, .current)
        XCTAssertEqual(rows.first(where: { $0.id == r2 })?.state, .previousSelection)
        XCTAssertTrue(rows.first(where: { $0.id == r1 })?.canRevert == true,
                      "the oldest verified ancestor must not be offered an impossible normal activation")
        XCTAssertFalse(rows.first(where: { $0.id == r1 })?.canActivate == true)
        XCTAssertEqual(rows.first(where: { $0.id == r1 })?.selectionActionLabel, "Revert")

        try await coordinator.revert(identity: fixture.identity, to: r1)
        let restarted = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let reopened = try await restarted.launchActive(identity: fixture.identity)
        let afterValue = try await restarted.libraryEntry(identity: fixture.identity)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(reopened.launchedRevisionId, r1)
        XCTAssertFalse(reopened.didFallback)
        XCTAssertEqual(after.currentRevisionId, r1)
        XCTAssertEqual(after.fallbackRevisionId, r3)
        XCTAssertEqual(Set(after.revisions.map(\.revisionId)), Set([r1, r2, r3]))
        XCTAssertEqual(NativeRevisionHistoryRow.rows(for: after).first(where: { $0.id == r3 })?.state,
                       .previousSelection, "after a revert the previous selection may be newer, not an older install")
        XCTAssertEqual(NativeRevisionHistoryRow.rows(for: after).first(where: { $0.id == r3 })?.selectionActionLabel,
                       "Restore", "restoring a newer previous selection must not be presented as going backward")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "keep-my-test-note")
    }

    func testStaleBaseAndCorruptUpdatesCannotChangeCurrentVersionOrReaderData() async throws {
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let r1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let r2 = try await fixture.install(fixture.package(number: 2, base: r1), through: coordinator)
        let dataRoot = try await coordinator.readerDataDirectory(identity: fixture.identity, namespace: fixture.namespace)
        let note = dataRoot.appendingPathComponent("synthetic-note.txt")
        try Data("survives-rejected-update".utf8).write(to: note)

        let stale = try fixture.package(number: 3, base: r1)
        let staleReview = try await coordinator.reviewImport(packageBytes: stale, expectedIdentity: fixture.identity)
        do {
            _ = try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: staleReview.reviewToken, packageSHA256: staleReview.packageSHA256)
            XCTFail("a stale update must not be staged as though it targets the current version")
        } catch let error as NativeShellError {
            XCTAssertEqual(error, .baseMismatch(expected: r2, actual: r1))
        }
        var corrupt = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.package(number: 4, base: r2)) as? [String: Any])
        var files = try XCTUnwrap(corrupt["files"] as? [[String: Any]])
        files[0]["contentBase64"] = Data("changed without an updated digest".utf8).base64EncodedString()
        corrupt["files"] = files
        do {
            _ = try await coordinator.reviewImport(packageBytes: JSONSerialization.data(withJSONObject: corrupt))
            XCTFail("corrupt bytes must not reach an approval surface")
        } catch { XCTAssertTrue(error is NativeShellError) }

        let entry = try await coordinator.libraryEntry(identity: fixture.identity)
        let pending = await coordinator.pendingPackageReview()
        XCTAssertEqual(entry?.currentRevisionId, r2)
        XCTAssertEqual(entry?.revisions.count, 2)
        XCTAssertNil(pending)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "survives-rejected-update")
    }

    func testActualWebStorageSurvivesContentUpdateAndRevertInTheVerifiedHost() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("requires the supported downloaded-content runtime") }
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let r1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let first = try await coordinator.launchActive(identity: fixture.identity)
        let host1 = try await loadedHost(first.launch)
        let view1 = try XCTUnwrap(host1.webView)
        _ = try await view1.evaluateJavaScript("localStorage.setItem('iris.synthetic.update-note','kept across versions')")
        host1.close()

        let r2 = try await fixture.install(fixture.package(number: 2, base: r1), through: coordinator)
        let second = try await coordinator.launchActive(identity: fixture.identity)
        XCTAssertNotEqual(first.launch.entrypointURL, second.launch.entrypointURL)
        XCTAssertEqual(first.launch.webStorageIdentity, second.launch.webStorageIdentity)
        let host2 = try await loadedHost(second.launch)
        let view2 = try XCTUnwrap(host2.webView)
        let title2 = try await view2.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        let note2 = try await view2.evaluateJavaScript("localStorage.getItem('iris.synthetic.update-note')") as? String
        XCTAssertEqual(title2, "Local test version 2")
        XCTAssertEqual(note2, "kept across versions")
        host2.close()

        try await coordinator.revert(identity: fixture.identity, to: r1)
        let restarted = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let reverted = try await restarted.launchActive(identity: fixture.identity)
        let host3 = try await loadedHost(reverted.launch)
        let view3 = try XCTUnwrap(host3.webView)
        let title3 = try await view3.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        let note3 = try await view3.evaluateJavaScript("localStorage.getItem('iris.synthetic.update-note')") as? String
        XCTAssertEqual(reverted.launchedRevisionId, r1)
        XCTAssertNotEqual(reverted.launchedRevisionId, r2)
        XCTAssertEqual(title3, "Local test version 1")
        XCTAssertEqual(note3, "kept across versions")
        host3.close()
        // Only the unique synthetic app's named profile is cleaned. No default
        // profile, normal Lunara data, or unrelated WebKit profile is accessed.
        if let store = try NativeWebStorageConfiguration.dataStore(for: first.launch) {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    private func loadedHost(_ launch: VerifiedLaunchDescriptor) async throws -> MobileUpdateHostedView {
        let loaded = expectation(description: "actual verified content loaded")
        let host = MobileUpdateHostedView(launch: launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("actual verified test content failed to load") }
        }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        _ = try XCTUnwrap(host.webView)
        return host
    }
}

@MainActor
private final class MobileUpdateHostedView {
    private var controller: UIHostingController<AnyView>?
    private var window: UIWindow?
    private(set) var webView: WKWebView?

    init(launch: VerifiedLaunchDescriptor, result: @escaping (NativeShellWebLoadResult) -> Void) {
        let controller = UIHostingController(rootView: AnyView(VerifiedRevisionWebView(launch: launch, onLoadResult: result)))
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.controller = controller
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    func findWebView() {
        func visit(_ view: UIView) -> WKWebView? {
            if let result = view as? WKWebView { return result }
            for child in view.subviews { if let result = visit(child) { return result } }
            return nil
        }
        if let root = controller?.view { webView = visit(root) }
    }

    func close() {
        if let webView, let coordinator = webView.navigationDelegate as? VerifiedRevisionWebView.Coordinator {
            VerifiedRevisionWebView.dismantleUIView(webView, coordinator: coordinator)
        }
        controller?.rootView = AnyView(EmptyView())
        controller?.view.layoutIfNeeded()
        webView?.removeFromSuperview()
        window?.isHidden = true
        window?.rootViewController = nil
        webView = nil
        controller = nil
        window = nil
    }
}

private struct MobileUpdateFixture {
    let suffix = UUID().uuidString.lowercased()
    var identity: NativeShellAppIdentity { .init(appId: "iris.update.\(suffix)", projectId: "iris.update.project") }
    var namespace: String { "iris.update.\(suffix)" }
    var policy: CapabilityPolicy { .init(supportedCapabilities: ["web.storage"]) }

    func install(_ bytes: Data, through coordinator: NativeShellLibraryCoordinator) async throws -> String {
        let review = try await coordinator.reviewImport(packageBytes: bytes, expectedIdentity: identity)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: identity, revisionId: review.revisionId)
        return review.revisionId
    }

    func package(number: Int, base: String?) throws -> Data {
        let content = Data("<!doctype html><html><body><h1>Local test version \(number)</h1><p>Synthetic compatible-schema update fixture.</p></body></html>".utf8)
        let manifest = DeliveryManifestReceipt(displayName: "Update test", runtimeType: "web", entrypoint: "index.html",
            minShellVersion: "1.0.0", requestedCapabilities: ["web.storage"], dataNamespace: namespace, dataUpdatePolicy: "preserve")
        let file = DeliveryFileReceipt(path: "index.html", sha256: NativeSecurity.sha256(content), bytes: content.count,
            mediaType: "text/html", data: content)
        let digest = NativeSecurity.revisionIdentity(appId: identity.appId, projectId: identity.projectId,
            baseRevisionId: base, manifest: manifest, files: [file])
        let timestamp = String(format: "2026-09-19T00:%02d:00.000Z", number)
        let approvalID = "approval-\(UUID().uuidString)"
        let null = NSNull()
        let manifestJSON: [String: Any] = ["kind": "iris.mobile-shell.manifest", "version": 1,
            "appId": identity.appId, "projectId": identity.projectId, "displayName": manifest.displayName,
            "runtime": ["type": "web", "entrypoint": "index.html", "minShellVersion": "1.0.0"],
            "capabilities": ["web.storage"], "data": ["namespace": namespace, "updatePolicy": "preserve"]]
        let revision: [String: Any] = ["kind": "iris.mobile-shell.revision", "version": 1,
            "appId": identity.appId, "projectId": identity.projectId, "baseRevisionId": base as Any? ?? null,
            "revisionId": digest.revisionId, "manifestHash": digest.manifestHash, "contentHash": digest.contentHash,
            "createdAt": timestamp, "manifest": manifestJSON,
            "files": [["path": file.path, "sha256": file.sha256, "bytes": file.bytes, "mediaType": file.mediaType]]]
        let approval: [String: Any] = ["kind": "iris.mobile-shell.delivery-approval", "version": 1,
            "approvalId": approvalID, "requestId": null, "requestNonce": null, "appId": identity.appId,
            "projectId": identity.projectId, "baseRevisionId": base as Any? ?? null,
            "approvedRevisionId": digest.revisionId, "approvedContentHash": digest.contentHash, "approvedAt": timestamp]
        let envelope: [String: Any] = ["kind": "iris.mobile-shell.delivery-envelope", "version": 1,
            "envelopeId": "delivery-\(UUID().uuidString)", "deliveryNonce": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "approvalId": approvalID, "appId": identity.appId, "projectId": identity.projectId,
            "baseRevisionId": base as Any? ?? null, "revisionId": digest.revisionId,
            "contentHash": digest.contentHash, "issuedAt": timestamp, "revision": revision]
        return try JSONSerialization.data(withJSONObject: ["format": NativeSecurity.packageFormat,
            "approval": approval, "envelope": envelope,
            "files": [["path": file.path, "mediaType": file.mediaType, "contentBase64": content.base64EncodedString()]]], options: [.sortedKeys])
    }
}

private struct WebsiteHostFixture {
    private static let primarySlugValue = "safe-demo"
    private static let secondarySlugValue = "safe-demo-alt"
    private static let primaryPackageURLValue = URL(string: "https://publikhq.com/mobile/safe-demo.irisapp")!
    private static let secondaryPackageURLValue = URL(string: "https://publikhq.com/mobile/safe-demo-alt.irisapp")!

    let packageBytes: Data
    let inspection: DeliveryPackageInspection
    let catalogData: Data

    var primarySlug: String { Self.primarySlugValue }
    var secondarySlug: String { Self.secondarySlugValue }
    var primaryPackageURL: URL { Self.primaryPackageURLValue }
    var secondaryPackageURL: URL { Self.secondaryPackageURLValue }
    var primaryIntentURL: URL { URL(string: "https://publikhq.com/iris/apps/\(primarySlug)")! }
    var secondaryIntentURL: URL { URL(string: "https://publikhq.com/iris/apps/\(secondarySlug)")! }
    var identity: NativeShellAppIdentity {
        NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId)
    }
    var revisionId: String { inspection.revisionId }

    init() throws {
        let packageURL = try XCTUnwrap(
            Bundle.main.url(forResource: "SafeDemo", withExtension: "irisapp"),
            "SafeDemo.irisapp must be supplied by the hosted app bundle"
        )
        packageBytes = try Data(contentsOf: packageURL)
        inspection = try DeliveryPackageV1Validator().inspect(packageBytes: packageBytes)
        catalogData = try Self.makeCatalog(
            packageBytes: packageBytes,
            inspection: inspection,
            rows: [
                (
                    slug: Self.primarySlugValue,
                    name: "Safe Demo",
                    downloadURL: Self.primaryPackageURLValue
                ),
                (
                    slug: Self.secondarySlugValue,
                    name: "Safe Demo Alternate",
                    downloadURL: Self.secondaryPackageURLValue
                ),
            ]
        )
    }

    private static func makeCatalog(
        packageBytes: Data,
        inspection: DeliveryPackageInspection,
        rows: [(slug: String, name: String, downloadURL: URL)]
    ) throws -> Data {
        let apps: [[String: Any]] = rows.map { row in
            let descriptor: [String: Any] = [
                "version": 1,
                "platform": "ios",
                "packageFormat": NativeSecurity.packageFormat,
                "downloadUrl": row.downloadURL.absoluteString,
                "mediaType": "application/json",
                "byteCount": packageBytes.count,
                "packageSha256": inspection.packageSHA256,
                "appId": inspection.appId,
                "projectId": inspection.projectId,
                "baseRevisionId": inspection.baseRevisionId ?? NSNull(),
                "revisionId": inspection.revisionId,
                "contentHash": inspection.contentHash,
            ]
            return [
                "slug": row.slug,
                "name": row.name,
                "guideSlug": row.slug,
                "macBundleId": NSNull(),
                "latestReleaseTag": NSNull(),
                "mobileShell": descriptor,
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["apps": apps], options: [.sortedKeys])
    }
}

private actor WebsiteHostTransport: PublikMobileHTTPTransport {
    private let fixture: WebsiteHostFixture
    private let holdPackageResponses: Bool
    private var requests: [URL] = []
    private var packagesReleased = false
    private var packageWaiters: [CheckedContinuation<Void, Never>] = []

    init(fixture: WebsiteHostFixture, holdPackageResponses: Bool = false) {
        self.fixture = fixture
        self.holdPackageResponses = holdPackageResponses
    }

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        guard let url = request.url else { throw WebsiteHostTestError.unexpectedRequest(nil) }
        requests.append(url)

        let body: Data
        if url == PublikMobileCatalogClient.catalogURL {
            body = fixture.catalogData
        } else if url == fixture.primaryPackageURL || url == fixture.secondaryPackageURL {
            if holdPackageResponses && !packagesReleased {
                await withCheckedContinuation { continuation in
                    packageWaiters.append(continuation)
                }
            }
            body = fixture.packageBytes
        } else {
            throw WebsiteHostTestError.unexpectedRequest(url)
        }

        guard body.count <= maximumBytes else {
            throw WebsiteHostTestError.responseTooLarge
        }
        progress?(body.count)
        return PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: "application/json",
            declaredContentLength: body.count,
            finalURL: url,
            body: body
        )
    }

    func totalRequestCount() -> Int { requests.count }

    func packageRequestCount() -> Int {
        requests.filter { $0 == fixture.primaryPackageURL || $0 == fixture.secondaryPackageURL }.count
    }

    func releaseHeldPackages() {
        packagesReleased = true
        let waiters = packageWaiters
        packageWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final class WebsiteHostBlockingStageFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var reachedStagePromotion = false

    var didReachStagePromotion: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedStagePromotion
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        var shouldBlock = false
        lock.lock()
        if !reachedStagePromotion && srcURL.lastPathComponent.hasPrefix(".staging-") {
            reachedStagePromotion = true
            shouldBlock = true
        }
        lock.unlock()
        if shouldBlock {
            _ = release.wait(timeout: .now() + 5)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }

    func releaseStagePromotion() {
        release.signal()
    }
}

private enum WebsiteHostTestError: Error {
    case timedOut(String)
    case unexpectedRequest(URL?)
    case responseTooLarge
}

private func makeWebsiteHostRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("iris-ios-host-website-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

// Append inside the existing `#if os(iOS)` scope of
// VerifiedRevisionWebViewLifecycleDeepAcceptanceTests.swift.
// It intentionally reuses the same-file private MobileUpdateFixture and
// MobileUpdateHostedView helpers that prime added for update/history acceptance.

@MainActor
final class IrisPackagedAPIHostedAcceptanceTests: XCTestCase {
    func testVerifiedHostInjectsDefaultClientWithExactVerifiedIdentityAndNoAdapter() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("requires the supported downloaded-content runtime")
        }

        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        _ = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let outcome = try await coordinator.launchActive(identity: fixture.identity)
        XCTAssertEqual(outcome.launch.identity, fixture.identity)
        XCTAssertEqual(outcome.launch.revisionId, outcome.launchedRevisionId)

        let loaded = expectation(description: "verified host loaded with packaged API")
        let host = MobileUpdateHostedView(launch: outcome.launch) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("verified packaged-API fixture failed to load") }
        }
        defer { host.close() }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        let webView = try XCTUnwrap(host.webView)

        let status = try await packagedAPIStatus(in: webView)
        XCTAssertEqual(status["version"] as? Int, 1)
        XCTAssertEqual(status["status"] as? String, "not_configured")
        XCTAssertEqual(status["activeRequests"] as? Int, 0)
        XCTAssertEqual(status["retainedRequests"] as? Int, 0)
        let context = try XCTUnwrap(status["context"] as? [String: Any])
        XCTAssertEqual(context["appId"] as? String, fixture.identity.appId)
        XCTAssertEqual(context["projectId"] as? String, fixture.identity.projectId)
        XCTAssertEqual(context["revisionId"] as? String, outcome.launchedRevisionId)

        let defaultError = try await webView.callAsyncJavaScript(
            """
            try {
              await globalThis.IrisPackagedAPI.v1.perform({
                requestId: "host-default-1",
                operationCode: "offline.echo",
                input: { text: "synthetic" }
              });
              return "unexpected_success";
            } catch (error) {
              return error && error.code ? error.code : "missing_error_code";
            }
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(defaultError, "not_configured")

        try await closePackagedAPI(in: webView)
        let closedStatus = try await packagedAPIStatus(in: webView)
        XCTAssertEqual(closedStatus["status"] as? String, "closed")
    }

    func testInternalOfflineAdapterUsesSameClientSurfaceAndVerifiedContext() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("requires the supported downloaded-content runtime")
        }

        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        _ = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let outcome = try await coordinator.launchActive(identity: fixture.identity)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let source = try IrisPackagedAPIHostScripts.source(
            launch: outcome.launch,
            testingBootstrapExtension: """
            Object.assign(globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__, {
              operations: {
                "offline.echo": {
                  input: {
                    type: "object",
                    properties: { text: { type: "string", minLength: 1, maxLength: 32 } },
                    required: ["text"],
                    additionalProperties: false
                  },
                  output: {
                    type: "object",
                    properties: {
                      text: { type: "string", minLength: 1, maxLength: 96 },
                      appId: { type: "string", minLength: 1, maxLength: 128 },
                      revisionId: { type: "string", minLength: 1, maxLength: 80 }
                    },
                    required: ["text", "appId", "revisionId"],
                    additionalProperties: false
                  }
                }
              },
              adapter: async (request) => ({
                text: request.input.text.toUpperCase(),
                appId: request.context.appId,
                revisionId: request.context.revisionId
              })
            });
            """
        )
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        let loaded = expectation(description: "offline adapter probe loaded verified file URL")
        let probe = IrisPackagedAPINavigationProbe(loaded: loaded)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = probe
        webView.loadFileURL(outcome.launch.entrypointURL, allowingReadAccessTo: outcome.launch.readAccessRootURL)
        await fulfillment(of: [loaded], timeout: 5)

        let status = try await packagedAPIStatus(in: webView)
        XCTAssertEqual(status["status"] as? String, "ready")
        XCTAssertEqual(status["activeRequests"] as? Int, 0)
        let operations = status["operations"] as? [String]
        XCTAssertEqual(operations, ["offline.echo"])

        let resultJSON = try await webView.callAsyncJavaScript(
            """
            const result = await globalThis.IrisPackagedAPI.v1.perform({
              requestId: "offline-hosted-1",
              operationCode: "offline.echo",
              input: { text: "synthetic" },
              deadlineMs: 1000
            });
            return JSON.stringify(result);
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        let result = try jsonObject(try XCTUnwrap(resultJSON))
        XCTAssertEqual(result["text"] as? String, "SYNTHETIC")
        XCTAssertEqual(result["appId"] as? String, fixture.identity.appId)
        XCTAssertEqual(result["revisionId"] as? String, outcome.launchedRevisionId)

        try await closePackagedAPI(in: webView)
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    private func packagedAPIStatus(in webView: WKWebView) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.IrisPackagedAPI.v1.status());",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        return try jsonObject(try XCTUnwrap(json))
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func closePackagedAPI(in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            IrisPackagedAPIHostScripts.close(in: webView) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

@MainActor
private final class IrisPackagedAPINavigationProbe: NSObject, WKNavigationDelegate {
    private let loaded: XCTestExpectation

    init(loaded: XCTestExpectation) {
        self.loaded = loaded
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        XCTFail("offline packaged-API probe navigation failed: \(error)")
        loaded.fulfill()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        XCTFail("offline packaged-API probe provisional navigation failed: \(error)")
        loaded.fulfill()
    }
}


// Append inside the existing `#if os(iOS)` scope of
// VerifiedRevisionWebViewLifecycleDeepAcceptanceTests.swift.
// Reuses same-file MobileUpdateFixture and makeWebsiteHostRoot helpers.

@MainActor
final class IrisPackagedAdapterResourceAcceptanceTests: XCTestCase {
    func testActualVerifiedHostRunsOnlyExactScopedBundledOfflineAdapter() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("requires the supported downloaded-content runtime")
        }

        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        _ = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let outcome = try await coordinator.launchActive(identity: fixture.identity)
        let adapter = IrisPackagedAPIAdapterConfiguration.offlineExample(
            identity: fixture.identity,
            revisionId: outcome.launchedRevisionId
        )

        let loaded = expectation(description: "actual verified Host loaded exact-scoped bundled adapter")
        let host = PackagedAdapterHostedView(
            launch: outcome.launch,
            adapter: adapter
        ) { result in
            if result == .loaded { loaded.fulfill() }
            else { XCTFail("exact-scoped bundled adapter unexpectedly failed Host load") }
        }
        defer { host.close() }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        let webView = try XCTUnwrap(host.webView)

        let statusJSON = try await webView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.IrisPackagedAPI.v1.status());",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let status = try jsonObject(try XCTUnwrap(statusJSON))
        XCTAssertEqual(status["status"] as? String, "ready")
        XCTAssertEqual(status["operations"] as? [String], ["offline.echo"])
        let context = try XCTUnwrap(status["context"] as? [String: Any])
        XCTAssertEqual(context["appId"] as? String, fixture.identity.appId)
        XCTAssertEqual(context["projectId"] as? String, fixture.identity.projectId)
        XCTAssertEqual(context["revisionId"] as? String, outcome.launchedRevisionId)

        let bootstrapConsumed = try await webView.evaluateJavaScript(
            "typeof globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__ === 'undefined'"
        ) as? Bool
        XCTAssertEqual(bootstrapConsumed, true)

        let resultJSON = try await webView.callAsyncJavaScript(
            """
            const result = await globalThis.IrisPackagedAPI.v1.perform({
              requestId: "bundled-offline-example-1",
              operationCode: "offline.echo",
              input: { text: "local only" },
              deadlineMs: 1000
            });
            return JSON.stringify(result);
            """,
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let result = try jsonObject(try XCTUnwrap(resultJSON))
        XCTAssertEqual(result["text"] as? String, "local only")
        XCTAssertEqual(result["appId"] as? String, fixture.identity.appId)
        XCTAssertEqual(result["projectId"] as? String, fixture.identity.projectId)
        XCTAssertEqual(result["revisionId"] as? String, outcome.launchedRevisionId)

        let contextAfterMutationAttempt = try await webView.callAsyncJavaScript(
            """
            try { globalThis.IrisPackagedAPI.v1.context.appId = "replacement"; } catch (_) {}
            return globalThis.IrisPackagedAPI.v1.context.appId;
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(contextAfterMutationAttempt, fixture.identity.appId)
    }

    func testActualVerifiedHostRejectsWrongAdapterScopeBeforeBundledResourceExecution() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("requires the supported downloaded-content runtime")
        }

        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        _ = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let outcome = try await coordinator.launchActive(identity: fixture.identity)
        let wrongIdentity = NativeShellAppIdentity(
            appId: fixture.identity.appId + ".other",
            projectId: fixture.identity.projectId
        )
        let wrongRevision = "rev-sha256:" + String(repeating: "0", count: 64)
        let wrongConfigurations: [IrisPackagedAPIAdapterConfiguration] = [
            .offlineExample(identity: wrongIdentity, revisionId: outcome.launchedRevisionId),
            .offlineExample(identity: fixture.identity, revisionId: wrongRevision),
        ]

        for (index, adapter) in wrongConfigurations.enumerated() {
            let failed = expectation(description: "wrong packaged adapter scope \(index) rejected")
            let host = PackagedAdapterHostedView(
                launch: outcome.launch,
                adapter: adapter
            ) { result in
                if result == .failed { failed.fulfill() }
                else { XCTFail("wrong adapter scope must not load verified content") }
            }
            await fulfillment(of: [failed], timeout: 5)
            host.findWebView()
            let webView = try XCTUnwrap(host.webView)

            XCTAssertNil(webView.url, "scope mismatch must fail before verified file navigation")
            let bootstrapType = try await webView.evaluateJavaScript(
                "typeof globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__"
            ) as? String
            XCTAssertEqual(bootstrapType, "undefined", "wrong scope must fail before any packaged-API source is installed")
            let apiType = try await webView.evaluateJavaScript(
                "typeof globalThis.IrisPackagedAPI"
            ) as? String
            XCTAssertEqual(apiType, "undefined")
            host.close()
        }
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }
}

@MainActor
final class IrisPackagedAPIRevisionLifecycleTests: XCTestCase {
    func testUpdateDoesNotInheritOldAdapterAndRevertRestoresExactContextWithSavedData() async throws {
        guard #available(iOS 18.4, *) else {
            throw XCTSkip("requires the supported downloaded-content runtime")
        }
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let revision1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let launch1 = try await coordinator.launchActive(identity: fixture.identity)
        let adapter1 = IrisPackagedAPIAdapterConfiguration.offlineExample(
            identity: fixture.identity, revisionId: revision1
        )
        let first = try await loadedHost(launch1.launch, adapter: adapter1)
        defer { first.close() }
        let firstWebView = try XCTUnwrap(first.webView)
        _ = try await firstWebView.evaluateJavaScript(
            "localStorage.setItem('iris.synthetic.api-update-note', 'keep through API version changes')"
        )
        let firstReply = try await echo(in: firstWebView, requestID: "same-request-id")
        XCTAssertEqual(firstReply["revisionId"] as? String, revision1)
        first.close()

        // A detached old document must close its API, not remain a route into
        // the adapter while a later immutable revision is being selected.
        let closedStatus = try await status(in: firstWebView)
        XCTAssertEqual(closedStatus["status"] as? String, "closed")

        let revision2 = try await fixture.install(
            fixture.package(number: 2, base: revision1), through: coordinator
        )
        let launch2 = try await coordinator.launchActive(identity: fixture.identity)
        XCTAssertNotEqual(launch1.launch.entrypointURL, launch2.launch.entrypointURL)
        XCTAssertEqual(launch1.launch.webStorageIdentity, launch2.launch.webStorageIdentity)

        let unconfigured = try await loadedHost(launch2.launch, adapter: .notConfigured)
        defer { unconfigured.close() }
        let unconfiguredWebView = try XCTUnwrap(unconfigured.webView)
        let unconfiguredStatus = try await status(in: unconfiguredWebView)
        XCTAssertEqual(unconfiguredStatus["status"] as? String, "not_configured")
        let unconfiguredContext = try XCTUnwrap(unconfiguredStatus["context"] as? [String: Any])
        XCTAssertEqual(unconfiguredContext["revisionId"] as? String, revision2)
        let noteAfterUpdate = try await unconfiguredWebView.evaluateJavaScript(
            "localStorage.getItem('iris.synthetic.api-update-note')"
        ) as? String
        XCTAssertEqual(noteAfterUpdate, "keep through API version changes")
        unconfigured.close()

        // Deliberately reuse the old exact-scoped adapter on the newly installed
        // revision. Content integrity alone must not grant a stale API binding.
        let refused = expectation(description: "updated content refuses its predecessor's adapter")
        let staleHost = PackagedAdapterHostedView(launch: launch2.launch, adapter: adapter1) { result in
            XCTAssertEqual(result, .failed)
            refused.fulfill()
        }
        defer { staleHost.close() }
        await fulfillment(of: [refused], timeout: 5)
        staleHost.findWebView()
        let staleWebView = try XCTUnwrap(staleHost.webView)
        XCTAssertNil(staleWebView.url)
        XCTAssertTrue(staleWebView.configuration.userContentController.userScripts.isEmpty)
        staleHost.close()
        let afterRefusal = try await coordinator.libraryEntry(identity: fixture.identity)
        XCTAssertEqual(afterRefusal?.currentRevisionId, revision2)
        XCTAssertEqual(afterRefusal?.revisions.count, 2)

        let adapter2 = IrisPackagedAPIAdapterConfiguration.offlineExample(
            identity: fixture.identity, revisionId: revision2
        )
        let second = try await loadedHost(launch2.launch, adapter: adapter2)
        defer { second.close() }
        let secondWebView = try XCTUnwrap(second.webView)
        // Request IDs are local to this document's API. Reusing a prior ID must
        // not replay the previous revision's response or idempotency record.
        let secondReply = try await echo(in: secondWebView, requestID: "same-request-id")
        XCTAssertEqual(secondReply["appId"] as? String, fixture.identity.appId)
        XCTAssertEqual(secondReply["revisionId"] as? String, revision2)
        XCTAssertNotEqual(secondReply["revisionId"] as? String, firstReply["revisionId"] as? String)
        second.close()

        try await coordinator.revert(identity: fixture.identity, to: revision1)
        let restartedCoordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let restored = try await restartedCoordinator.launchActive(identity: fixture.identity)
        XCTAssertEqual(restored.launchedRevisionId, revision1)
        XCTAssertFalse(restored.didFallback)
        let restoredHost = try await loadedHost(restored.launch, adapter: adapter1)
        defer { restoredHost.close() }
        let restoredWebView = try XCTUnwrap(restoredHost.webView)
        let restoredReply = try await echo(in: restoredWebView, requestID: "same-request-id")
        let restoredNote = try await restoredWebView.evaluateJavaScript(
            "localStorage.getItem('iris.synthetic.api-update-note')"
        ) as? String
        XCTAssertEqual(restoredReply["revisionId"] as? String, revision1)
        XCTAssertEqual(restoredNote, "keep through API version changes")
        let finalEntryValue = try await restartedCoordinator.libraryEntry(identity: fixture.identity)
        let finalEntry = try XCTUnwrap(finalEntryValue)
        let rows = NativeRevisionHistoryRow.rows(for: finalEntry)
        XCTAssertEqual(Set(rows.map(\.id)), Set([revision1, revision2]))
        XCTAssertEqual(rows.first?.id, revision1)
        XCTAssertEqual(rows.first?.state, .current)
        XCTAssertEqual(rows.first(where: { $0.id == revision2 })?.selectionActionLabel, "Restore")
        restoredHost.close()
        if let store = try NativeWebStorageConfiguration.dataStore(for: launch1.launch) {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    private func loadedHost(
        _ launch: VerifiedLaunchDescriptor,
        adapter: IrisPackagedAPIAdapterConfiguration
    ) async throws -> PackagedAdapterHostedView {
        let loaded = expectation(description: "actual verified revision and its API configuration loaded")
        let host = PackagedAdapterHostedView(launch: launch, adapter: adapter) { result in
            XCTAssertEqual(result, .loaded)
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        _ = try XCTUnwrap(host.webView)
        return host
    }

    private func status(in webView: WKWebView) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript(
            "return JSON.stringify(globalThis.IrisPackagedAPI.v1.status());",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        return try object(json)
    }

    private func echo(in webView: WKWebView, requestID: String) async throws -> [String: Any] {
        let json = try await webView.callAsyncJavaScript(
            """
            return JSON.stringify(await globalThis.IrisPackagedAPI.v1.perform({
              requestId, operationCode: "offline.echo", input: {text: "revision-scoped"}, deadlineMs: 1000
            }));
            """,
            arguments: ["requestId": requestID], in: nil, contentWorld: .page
        ) as? String
        return try object(json)
    }

    private func object(_ json: String?) throws -> [String: Any] {
        let text = try XCTUnwrap(json)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

@MainActor
final class IrisSignedPackagedAPIInstallationTests: XCTestCase {
    func testAPIBindingSurvivesMissingDirectoryBecomingADirectory() async throws {
        let api = SignedAPITestFixture()
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let review = try await coordinator.reviewImport(packageBytes: fixture.packageBytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        let launch = try await coordinator.launchActive(identity: review.identity)
        let apiPath = root.appendingPathComponent("new-api-store").path
        let withoutDirectoryHint = URL(fileURLWithPath: apiPath, isDirectory: false)
        let withDirectoryHint = URL(fileURLWithPath: apiPath, isDirectory: true)
        XCTAssertEqual(withoutDirectoryHint.path, withDirectoryHint.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: apiPath))
        let first = try NativePackagedAPIInstallationStore(rootURL: withoutDirectoryHint, verifier: api.verifier())
        XCTAssertNil(try first.installed(for: launch.launch))
        let bytes = try api.package(identity: review.identity, revision: review.revisionId)
        let installed = try first.install(bytes, for: launch.launch)
        XCTAssertEqual(try first.installed(for: launch.launch), installed)
        let reopened = try NativePackagedAPIInstallationStore(rootURL: withDirectoryHint, verifier: api.verifier())
        XCTAssertEqual(try reopened.installed(for: launch.launch), installed)
        let alias = root.appendingPathComponent("untrusted-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: withDirectoryHint)
        XCTAssertThrowsError(try NativePackagedAPIInstallationStore(rootURL: alias, verifier: api.verifier())) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .unsafeStorage)
        }
    }

    func testCorruptActiveHistoryDoesNotBlockVerifiedFallbackOrMisreportRejectedAPIAsOpened() async throws {
        for revoked in [false, true] {
            let fixture = MobileUpdateFixture()
            let root = try makeWebsiteHostRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"), capabilityPolicy: fixture.policy)
            let revision1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
            let first = try await coordinator.launchActive(identity: fixture.identity)
            let signer = SignedAPITestFixture()
            let apiRoot = root.appendingPathComponent("api")
            let installer = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: signer.verifier())
            let installed = try installer.install(signer.package(identity: fixture.identity, revision: revision1), for: first.launch)
            _ = try await fixture.install(fixture.package(number: 2, base: revision1), through: coordinator)
            let second = try await coordinator.launchActive(identity: fixture.identity)
            let firstBytes = try Data(contentsOf: first.launch.entrypointURL)
            let badBytes = Data("owned synthetic corrupted version 2".utf8)
            try badBytes.write(to: second.launch.entrypointURL)
            let resolver = try NativePackagedAPIInstallationStore(rootURL: apiRoot,
                verifier: revoked ? NativePackagedAPIVerifier() : signer.verifier())
            var preparationCalls = 0
            var resolverCalls = 0
            let model = NativeShellAppModel(coordinator: coordinator,
                preparePackagedAPIForLaunch: { _ in preparationCalls += 1 },
                packagedAPIAdapterForLaunch: { launch in
                    resolverCalls += 1
                    return resolver.adapterConfiguration(for: launch)
                })
            model.open(identity: fixture.identity)
            try await waitForModel { model.launch != nil || model.errorMessage != nil }
            XCTAssertEqual(resolverCalls, 1)
            XCTAssertEqual(preparationCalls, 0)
            if revoked {
                XCTAssertNil(model.launch)
                XCTAssertTrue(model.errorMessage?.contains("packaged API") == true)
                XCTAssertNil(model.notice)
                XCTAssertEqual(model.retryAction, .open(fixture.identity))
            } else {
                XCTAssertEqual(model.launch?.launchedRevisionId, revision1)
                XCTAssertEqual(model.launch?.didFallback, true)
                XCTAssertEqual(model.launchPackagedAPIAdapter, .verifiedBundle(installed))
                XCTAssertTrue(model.notice?.contains("history") == true)
                XCTAssertNil(model.errorMessage)
                model.closeApp()
                model.appSheetDidClose()
            }
            XCTAssertEqual(try Data(contentsOf: first.launch.entrypointURL), firstBytes)
            XCTAssertEqual(try Data(contentsOf: second.launch.entrypointURL), badBytes)
        }
    }

    func testRevisionSwitchInvalidatesFailedAPISetupSoLaterOrdinaryOpenCannotBind() async throws {
        let api = SignedAPITestFixture()
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"), capabilityPolicy: fixture.policy)
        let r1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let update = try fixture.package(number: 2, base: r1)
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: api.verifier())
        var calls = 0
        var failPreparation = true
        let model = NativeShellAppModel(
            coordinator: coordinator, bundledDemoPackage: update,
            preparePackagedAPIForLaunch: { launch in
                calls += 1
                if failPreparation { throw NativePackagedAPIError.invalidSignature }
                _ = try store.install(api.package(identity: fixture.identity, revision: launch.revisionId), for: launch)
            },
            packagedAPIAdapterForLaunch: store.adapterConfiguration
        )
        model.reviewBundledDemo()
        try await waitForModel { model.review != nil }
        let review = try XCTUnwrap(model.review)
        model.approveLocallyAndOpen(review: review)
        model.reviewSheetDidClose()
        try await waitForModel { !model.isInstalling }
        XCTAssertNil(model.launch)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.retryAction, .open(fixture.identity))
        model.revert(identity: fixture.identity, revisionId: r1)
        try await waitForModel { model.library.first?.currentRevisionId == r1 }
        model.activate(identity: fixture.identity, revisionId: review.revisionId)
        try await waitForModel { model.library.first?.currentRevisionId == review.revisionId }
        failPreparation = false
        model.open(identity: fixture.identity)
        try await waitForModel { model.launch != nil }
        let outcome = try XCTUnwrap(model.launch)
        XCTAssertEqual(calls, 1, "an old approved setup cannot revive after intervening revision selection")
        XCTAssertEqual(model.launchPackagedAPIAdapter, .notConfigured)
        XCTAssertNil(try store.installed(for: outcome.launch))
        model.closeApp()
        model.appSheetDidClose()
    }

    func testOrdinaryOpenCannotSilentlyAddAFirstAPIToAnExistingRevision() async throws {
        let api = SignedAPITestFixture()
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let review = try await coordinator.reviewImport(packageBytes: fixture.packageBytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: api.verifier())
        let signed = try api.package(identity: fixture.identity, revision: fixture.revisionId)
        var prepareCalls = 0
        let model = NativeShellAppModel(
            coordinator: coordinator,
            preparePackagedAPIForLaunch: { launch in
                prepareCalls += 1
                _ = try store.install(signed, for: launch)
            },
            packagedAPIAdapterForLaunch: store.adapterConfiguration
        )
        model.open(identity: fixture.identity)
        try await waitForModel { model.launch != nil }
        let launch = try XCTUnwrap(model.launch)
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertEqual(model.launchPackagedAPIAdapter, .notConfigured)
        XCTAssertNil(try store.installed(for: launch.launch))
        model.closeApp()
        model.appSheetDidClose()
    }

    func testOneInstallAndOpenBindsPreparedAPIOnceBeforePublishingLaunch() async throws {
        let api = SignedAPITestFixture()
        let fixture = try WebsiteHostFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"))
        let store = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: api.verifier())
        let signed = try api.package(identity: fixture.identity, revision: fixture.revisionId)
        var prepareCalls = 0
        var resolveCalls = 0
        let model = NativeShellAppModel(
            coordinator: coordinator, bundledDemoPackage: fixture.packageBytes,
            preparePackagedAPIForLaunch: { launch in
                prepareCalls += 1
                _ = try store.install(signed, for: launch)
            },
            packagedAPIAdapterForLaunch: { launch in
                resolveCalls += 1
                return store.adapterConfiguration(for: launch)
            }
        )
        XCTAssertEqual(prepareCalls, 0)
        model.reviewBundledDemo()
        try await waitForModel { model.review != nil }
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(prepareCalls, 0, "review is not permission to install an API")
        model.approveLocallyAndOpen(review: review)
        model.reviewSheetDidClose()
        try await waitForModel { !model.isInstalling }
        let outcome = try XCTUnwrap(model.launch)
        guard case .verifiedBundle(let installed) = model.launchPackagedAPIAdapter else {
            return XCTFail("the actual launch must contain its verified installed API")
        }
        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(resolveCalls, 1)
        XCTAssertEqual(installed.revisionId, outcome.launchedRevisionId)
        XCTAssertEqual(try store.installed(for: outcome.launch), installed)
        let echoed = try await runAPI(outcome.launch, installed: installed)
        XCTAssertEqual(echoed["revisionId"] as? String, outcome.launchedRevisionId)
        model.refresh()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(resolveCalls, 1, "refresh/render must not rescan or replace a live document's adapter")
        model.closeApp()
        model.appSheetDidClose()
        XCTAssertEqual(model.launchPackagedAPIAdapter, .notConfigured)
        let restoredStore = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: api.verifier())
        let restarted = NativeShellAppModel(coordinator: coordinator, packagedAPIAdapterForLaunch: restoredStore.adapterConfiguration)
        restarted.open(identity: fixture.identity)
        try await waitForModel { restarted.launch != nil }
        XCTAssertEqual(restarted.launchPackagedAPIAdapter, .verifiedBundle(installed))
        XCTAssertEqual(prepareCalls, 1, "reopen uses the durable binding, not a repeated installation callback")
        restarted.closeApp()
        restarted.appSheetDidClose()
    }

    func testAPISetupFailureAfterUpdateIsInstalledButNotOpenedAndPreservesData() async throws {
        let fixture = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: fixture.policy)
        let r1 = try await fixture.install(fixture.package(number: 1, base: nil), through: coordinator)
        let first = try await coordinator.launchActive(identity: fixture.identity)
        let storage = try await coordinator.readerDataDirectory(identity: fixture.identity, namespace: fixture.namespace)
        let note = storage.appendingPathComponent("api-setup-preserve.txt")
        try Data("synthetic saved data".utf8).write(to: note)
        let update = try fixture.package(number: 2, base: r1)
        let api = SignedAPITestFixture()
        let apiStore = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: api.verifier())
        var prepareCalls = 0
        var failPreparation = true
        let model = NativeShellAppModel(
            coordinator: coordinator, bundledDemoPackage: update,
            preparePackagedAPIForLaunch: { launch in
                prepareCalls += 1
                if failPreparation { throw NativePackagedAPIError.invalidSignature }
                let bytes = try api.package(identity: fixture.identity, revision: launch.revisionId)
                _ = try apiStore.install(bytes, for: launch)
            },
            packagedAPIAdapterForLaunch: apiStore.adapterConfiguration
        )
        model.reviewBundledDemo()
        try await waitForModel { model.review != nil }
        let review = try XCTUnwrap(model.review)
        model.approveLocallyAndOpen(review: review)
        model.reviewSheetDidClose()
        try await waitForModel { !model.isInstalling }
        XCTAssertNil(model.launch)
        XCTAssertTrue(model.errorMessage?.contains("app is installed") == true)
        XCTAssertTrue(model.errorMessage?.contains("has not opened") == true)
        XCTAssertEqual(model.launchPackagedAPIAdapter, .notConfigured)
        let entry = try await coordinator.libraryEntry(identity: fixture.identity)
        XCTAssertEqual(entry?.currentRevisionId, review.revisionId)
        XCTAssertEqual(entry?.revisions.count, 2)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "synthetic saved data")
        XCTAssertEqual(prepareCalls, 1)
        XCTAssertEqual(model.retryAction, .open(fixture.identity))
        failPreparation = false
        model.retry()
        try await waitForModel { model.launch != nil }
        XCTAssertEqual(prepareCalls, 2, "visible Retry must actually retry API preparation, not only refresh the library")
        XCTAssertEqual(model.launch?.launchedRevisionId, review.revisionId)
        guard case .verifiedBundle(let installed) = model.launchPackagedAPIAdapter else {
            return XCTFail("retried launch must resolve the actual newly installed API")
        }
        XCTAssertEqual(installed.revisionId, review.revisionId)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "synthetic saved data")
        model.closeApp()
        model.appSheetDidClose()
        if let store = try NativeWebStorageConfiguration.dataStore(for: first.launch) {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    func testPublisherTrustSignatureScopeSDKAndCapabilitiesFailClosed() throws {
        let fixture = SignedAPITestFixture()
        let identity = NativeShellAppIdentity(appId: "iris.api-signature-test", projectId: "iris.api-signature-project")
        let revision = "rev-sha256:" + String(repeating: "a", count: 64)
        let verifier = try fixture.verifier()
        let good = try fixture.package(identity: identity, revision: revision)
        let verified = try verifier.verify(good, identity: identity, revisionId: revision)
        XCTAssertEqual(verified.identity, identity)
        XCTAssertEqual(verified.revisionId, revision)
        XCTAssertEqual(verified.adapterVersion, "1.0.0")
        XCTAssertEqual(verified.sourceSHA256, NativeSecurity.sha256(Data(fixture.source.utf8)))
        let untrusted = try NativePackagedAPIVerifier()
        XCTAssertThrowsError(try untrusted.verify(good, identity: identity, revisionId: revision)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .unknownPublisher)
        }
        let impostorKey = Curve25519.Signing.PrivateKey()
        let wrongRegistry = try NativePackagedAPIVerifier(trustedPublisherKeys: [fixture.keyID: impostorKey.publicKey.rawRepresentation])
        XCTAssertThrowsError(try wrongRegistry.verify(good, identity: identity, revisionId: revision)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .invalidSignature)
        }
        let next = "rev-sha256:" + String(repeating: "b", count: 64)
        XCTAssertThrowsError(try verifier.verify(good, identity: identity, revisionId: next)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .invalidScope)
        }
        let wrongApp = NativeShellAppIdentity(appId: "iris.other", projectId: identity.projectId)
        XCTAssertThrowsError(try verifier.verify(good, identity: wrongApp, revisionId: revision)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .invalidScope)
        }
        for (change, expected) in [
            (["sdkMajor": 2], NativePackagedAPIError.unsupportedSDK),
            (["capabilities": ["network"]], .unsupportedCapabilities),
            (["sourceSha256": "sha256:" + String(repeating: "0", count: 64)], .invalidSource),
            (["adapterVersion": "01.0.0"], .invalidSource),
            (["providerKey": "not-a-real-secret"], .invalidEnvelope),
        ] as [([String: Any], NativePackagedAPIError)] {
            let bytes = try fixture.package(identity: identity, revision: revision, overriding: change)
            XCTAssertThrowsError(try verifier.verify(bytes, identity: identity, revisionId: revision)) {
                XCTAssertEqual($0 as? NativePackagedAPIError, expected)
            }
        }
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        var payload = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(envelope["payloadBase64"] as? String)))
        payload.append(32) // Still valid JSON, but the signed bytes changed.
        envelope["payloadBase64"] = payload.base64EncodedString()
        let changed = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try verifier.verify(changed, identity: identity, revisionId: revision)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .invalidSignature)
        }
    }

    func testActualSignedAdapterPersistsPerRevisionAcrossUpdateAndRevert() async throws {
        let api = SignedAPITestFixture()
        let app = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"), capabilityPolicy: app.policy)
        let verifier = try api.verifier()
        let apiRoot = root.appendingPathComponent("api-bindings")
        let store = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        let r1 = try await app.install(app.package(number: 1, base: nil), through: coordinator)
        let v1 = try await coordinator.launchActive(identity: app.identity)
        let bytes1 = try api.package(identity: app.identity, revision: r1)
        let installed1 = try store.install(bytes1, for: v1.launch)
        XCTAssertEqual(try store.install(bytes1, for: v1.launch), installed1, "exact retry is idempotent")
        let result1 = try await runAPI(v1.launch, installed: installed1)
        XCTAssertEqual(result1["revisionId"] as? String, r1)

        let r2 = try await app.install(app.package(number: 2, base: r1), through: coordinator)
        let v2 = try await coordinator.launchActive(identity: app.identity)
        let reopenedStore = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        XCTAssertNil(try reopenedStore.installed(for: v2.launch), "new content cannot inherit an older API binding")
        XCTAssertThrowsError(try reopenedStore.install(bytes1, for: v2.launch)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .invalidScope)
        }
        let bytes2 = try api.package(identity: app.identity, revision: r2, overriding: ["adapterVersion": "2.0.0"])
        let installed2 = try reopenedStore.install(bytes2, for: v2.launch)
        let result2 = try await runAPI(v2.launch, installed: installed2)
        XCTAssertEqual(result2["revisionId"] as? String, r2)
        XCTAssertEqual(installed2.adapterVersion, "2.0.0")

        let replacement = try api.package(identity: app.identity, revision: r2, overriding: ["adapterVersion": "2.0.1"])
        XCTAssertThrowsError(try reopenedStore.install(replacement, for: v2.launch)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .immutableBindingConflict)
        }
        XCTAssertEqual(try reopenedStore.installed(for: v2.launch), installed2)
        try await coordinator.revert(identity: app.identity, to: r1)
        let restored = try await coordinator.launchActive(identity: app.identity)
        let freshStore = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        let restoredBinding = try XCTUnwrap(freshStore.installed(for: restored.launch))
        XCTAssertEqual(restoredBinding, installed1)
        let restoredResult = try await runAPI(restored.launch, installed: restoredBinding)
        XCTAssertEqual(restoredResult["revisionId"] as? String, r1)
        let entry = try await coordinator.libraryEntry(identity: app.identity)
        XCTAssertEqual(entry?.revisions.count, 2)
        XCTAssertEqual(entry?.currentRevisionId, r1)
        if let dataStore = try NativeWebStorageConfiguration.dataStore(for: v1.launch) {
            await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }

    func testStoredCorruptionAndSymlinkAreErrorsNotUnconfiguredOrAuthority() async throws {
        let api = SignedAPITestFixture()
        let app = MobileUpdateFixture()
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"), capabilityPolicy: app.policy)
        let revision = try await app.install(app.package(number: 1, base: nil), through: coordinator)
        let launch = try await coordinator.launchActive(identity: app.identity)
        let apiRoot = root.appendingPathComponent("api")
        let verifier = try api.verifier()
        let store = try NativePackagedAPIInstallationStore(rootURL: apiRoot, verifier: verifier)
        XCTAssertNil(try store.installed(for: launch.launch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: apiRoot.path), "absent lookup must not create storage")
        let bytes = try api.package(identity: app.identity, revision: revision)
        _ = try store.install(bytes, for: launch.launch)
        let files = try FileManager.default.contentsOfDirectory(at: apiRoot, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first(where: { $0.pathExtension == "irisapi" }))
        try Data("not a signed API".utf8).write(to: file)
        XCTAssertThrowsError(try store.installed(for: launch.launch))
        let entry = try await coordinator.libraryEntry(identity: app.identity)
        XCTAssertEqual(entry?.currentRevisionId, revision)
        try FileManager.default.removeItem(at: file)
        let other = root.appendingPathComponent("owned-synthetic-other.irisapi")
        try bytes.write(to: other)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try store.installed(for: launch.launch)) {
            XCTAssertEqual($0 as? NativePackagedAPIError, .unsafeStorage)
        }
        XCTAssertEqual(try Data(contentsOf: other), bytes)
        let rootAlias = root.appendingPathComponent("api-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: apiRoot)
        XCTAssertThrowsError(try NativePackagedAPIInstallationStore(rootURL: rootAlias, verifier: verifier))
    }

    private func waitForModel(_ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(predicate(), "actual Host model did not reach its expected state")
        guard predicate() else { throw WebsiteHostTestError.timedOut("API installation model") }
    }

    private func runAPI(_ launch: VerifiedLaunchDescriptor, installed: NativeVerifiedPackagedAPI) async throws -> [String: Any] {
        let loaded = expectation(description: "signed supplied adapter loads in actual verified Host")
        let host = PackagedAdapterHostedView(launch: launch, adapter: .verifiedBundle(installed)) { result in
            XCTAssertEqual(result, .loaded)
            loaded.fulfill()
        }
        defer { host.close() }
        await fulfillment(of: [loaded], timeout: 5)
        host.findWebView()
        let webView = try XCTUnwrap(host.webView)
        let raw = try await webView.callAsyncJavaScript(
            "return JSON.stringify(await IrisPackagedAPI.v1.perform({requestId:'installation-test',operationCode:'fixture.version',input:{},deadlineMs:1000}));",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        let json = try XCTUnwrap(raw)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}

private struct SignedAPITestFixture {
    let key = Curve25519.Signing.PrivateKey()
    let keyID = "iris-ephemeral-test-publisher"
    let source = """
    (() => {
      const b = globalThis.__IRIS_PACKAGED_API_BOOTSTRAP__;
      b.operations = {"fixture.version": {
        input: {type:"object",properties:{},required:[],additionalProperties:false},
        output: {type:"object",properties:{revisionId:{type:"string",maxLength:80}},required:["revisionId"],additionalProperties:false}
      }};
      b.adapter = async request => ({revisionId:request.context.revisionId});
    })();
    """
    func verifier() throws -> NativePackagedAPIVerifier {
        try NativePackagedAPIVerifier(trustedPublisherKeys: [keyID: key.publicKey.rawRepresentation])
    }
    func package(identity: NativeShellAppIdentity, revision: String, overriding: [String: Any] = [:]) throws -> Data {
        let sourceBytes = Data(source.utf8)
        var body: [String: Any] = [
            "version": 1, "sdkMajor": 1, "adapterId": "iris.signed-test", "adapterVersion": "1.0.0",
            "appId": identity.appId, "projectId": identity.projectId, "revisionId": revision,
            "sourceSha256": NativeSecurity.sha256(sourceBytes), "sourceBase64": sourceBytes.base64EncodedString(),
            "capabilities": [] as [String]
        ]
        for (key, value) in overriding { body[key] = value }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let signature = try key.signature(for: NativePackagedAPIVerifier.signingDomain + payload)
        return try JSONSerialization.data(withJSONObject: [
            "format": NativePackagedAPIVerifier.format, "keyId": keyID,
            "payloadBase64": payload.base64EncodedString(), "signatureBase64": signature.base64EncodedString()
        ], options: [.sortedKeys])
    }
}

@MainActor
private final class PackagedAdapterHostedView {
    private var controller: UIHostingController<AnyView>?
    private var window: UIWindow?
    private(set) var webView: WKWebView?

    init(
        launch: VerifiedLaunchDescriptor,
        adapter: IrisPackagedAPIAdapterConfiguration,
        result: @escaping (NativeShellWebLoadResult) -> Void
    ) {
        let controller = UIHostingController(
            rootView: AnyView(
                VerifiedRevisionWebView(
                    launch: launch,
                    packagedAPIAdapter: adapter,
                    onLoadResult: result
                )
            )
        )
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.controller = controller
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    func findWebView() {
        func visit(_ view: UIView) -> WKWebView? {
            if let result = view as? WKWebView { return result }
            for child in view.subviews {
                if let result = visit(child) { return result }
            }
            return nil
        }
        if let root = controller?.view { webView = visit(root) }
    }

    func close() {
        if let webView,
           let coordinator = (webView.navigationDelegate as? VerifiedRevisionWebView.Coordinator)
            ?? (webView.uiDelegate as? VerifiedRevisionWebView.Coordinator) {
            VerifiedRevisionWebView.dismantleUIView(webView, coordinator: coordinator)
        }
        controller?.rootView = AnyView(EmptyView())
        controller?.view.layoutIfNeeded()
        webView?.removeFromSuperview()
        window?.isHidden = true
        window?.rootViewController = nil
        webView = nil
        controller = nil
        window = nil
    }
}

// BEGIN_MOBILE_WEBSITE_RECOVERY_SCENARIOS
@MainActor
private enum MobileWebsiteRecoveryScenarios {
    typealias Scenario = @MainActor (MobileWebsiteRecoveryFixture) async throws -> Void
    static var cases: [(String, Scenario)] { [
        ("website-approved-retry", websiteApprovedRetry),
        ("website-cancel-revokes", websiteCancellationRevokesSetup),
        ("website-selection-invalidates", interveningSelectionInvalidatesSetup),
        ("ordinary-open-repeated-failure", ordinaryOpenRetainsRetry),
        ("api-retry-core-failure", apiSetupRetryRetainsRetry),
        ("website-host-busy-retry", websiteRetriesHostPreparation),
        ("website-adoption-refresh-generation", websiteAdoptionRefreshCannotOverwriteNewerSelection),
        ("website-usage-enabled", websiteUsageRecordsActualTransitions),
        ("website-usage-off", websiteUsageStaysOff),
        ("website-usage-late-consent", websiteUsageDoesNotBackfillLateConsent),
        ("website-usage-revoked-review", websiteUsageDoesNotRenewAnOldReviewBinding)
    ] }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw MobileWebsiteRecoveryFailure(message: message) }
    }

    static func wait(_ message: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try require(predicate(), "Timed out: " + message)
    }

    static func websiteFailure(_ fixture: MobileWebsiteRecoveryFixture,
                               _ website: NativeShellWebsiteInstallModel) async throws {
        fixture.files.arm(1)
        website.receive(fixture.intent)
        try await wait("website review") { website.review != nil || website.failureMessage != nil }
        try require(website.review != nil, "Verified website review was not prepared")
        website.installAndOpen()
        try await wait("post-activation failure") { website.failureMessage != nil && !website.isCommitting }
        try require(website.failureMessage?.contains("app was installed") == true, "Activation must not be described as rollback")
        try require(fixture.apiPreparationCalls == 0, "Core failure must happen before any API setup")
        let entry = try await fixture.coordinator.libraryEntry(identity: fixture.identity)
        try require(entry?.currentRevisionId == fixture.revision, "Content really activated before the fault")
    }

    static func websiteApprovedRetry(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let app = fixture.model()
        let website = fixture.website(app)
        try await websiteFailure(fixture, website)
        let originalPointer = try Data(contentsOf: fixture.files.activePointer)
        website.retry()
        try await wait("website Retry") { !website.isPresented || website.failureMessage != nil }
        guard let result = website.presentationWasDismissed() else {
            throw MobileWebsiteRecoveryFailure(message: "Retry did not return a verified app")
        }
        try require(result.source == .installed(alreadyStaged: false),
                    "Retry lost the original approved installation and misclassified it as ordinary Open")
        app.adoptVerifiedWebsiteLaunch(result)
        try require(app.launch != nil && fixture.apiPreparationCalls == 1,
                    "Exact approved Retry must prepare its API once before publishing the app")
        guard let launch = app.launch else { throw MobileWebsiteRecoveryFailure(message: "App not opened") }
        try require(try fixture.apiStore.installed(for: launch.launch) != nil, "Signed API binding must really persist")
        try require(try Data(contentsOf: fixture.files.activePointer) == originalPointer, "Retry must not rewrite activation")
        let requests = await fixture.transport.requestCount()
        try require(requests == 2, "Retry must not refetch catalogue or package after successful activation")
        app.closeApp(); app.appSheetDidClose()
    }

    static func websiteCancellationRevokesSetup(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let app = fixture.model()
        let website = fixture.website(app)
        try await websiteFailure(fixture, website)
        website.cancel()
        website.receive(fixture.intent)
        try await wait("fresh existing-open after cancellation") { !website.isPresented || website.failureMessage != nil }
        guard let result = website.presentationWasDismissed() else {
            throw MobileWebsiteRecoveryFailure(message: "Existing verified content could not reopen")
        }
        try require(result.source == .alreadyInstalled, "Cancel must revoke the prior installation capability")
        app.adoptVerifiedWebsiteLaunch(result)
        try require(app.launch != nil && fixture.apiPreparationCalls == 0, "Ordinary Open cannot install a first API")
        try require(app.launchPackagedAPIAdapter == .notConfigured, "No hidden adapter fallback")
        app.closeApp(); app.appSheetDidClose()
    }

    static func interveningSelectionInvalidatesSetup(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let app = fixture.model()
        let website = fixture.website(app)
        try await websiteFailure(fixture, website)
        _ = try await fixture.seed(fixture.update)
        try await fixture.coordinator.revert(identity: fixture.identity, to: fixture.revision)
        website.retry()
        try await wait("Retry after intervening selection") {
            !website.isPresented || website.failureMessage != nil || website.review != nil
        }
        if !website.isPresented, let result = website.presentationWasDismissed() {
            try require(result.source == .alreadyInstalled, "Returning to a revision cannot resurrect an old setup grant")
            app.adoptVerifiedWebsiteLaunch(result)
        }
        try require(fixture.apiPreparationCalls == 0, "Intervening selection must revoke first-API authority")
        let entry = try await fixture.coordinator.libraryEntry(identity: fixture.identity)
        try require(entry?.currentRevisionId == fixture.revision && entry?.revisions.count == 2, "Both real revisions must remain")
        if app.launch != nil { app.closeApp(); app.appSheetDidClose() }
        website.cancel()
    }

    static func ordinaryOpenRetainsRetry(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        _ = try await fixture.seed(fixture.initial)
        let app = fixture.model()
        fixture.files.arm(2)
        app.open(identity: fixture.identity)
        try await wait("first Core open failure") { app.errorMessage != nil }
        try require(app.retryAction == .open(fixture.identity), "A failed ordinary Open must expose actual Retry")
        app.retry()
        try await wait("second Core open failure") { app.errorMessage != nil }
        try require(app.retryAction == .open(fixture.identity), "Another transient failure must not remove Retry")
        app.retry()
        try await wait("successful ordinary Retry") { app.launch != nil || app.errorMessage != nil }
        try require(app.launch?.launchedRevisionId == fixture.revision, "Retry must open the actual installed revision")
        try require(fixture.apiPreparationCalls == 0, "Ordinary retries remain resolver-only")
        app.closeApp(); app.appSheetDidClose()
    }

    static func apiSetupRetryRetainsRetry(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        fixture.failAPIPreparation = true
        let app = fixture.model()
        app.reviewBundledDemo()
        try await wait("local review") { app.review != nil }
        guard let review = app.review else { throw MobileWebsiteRecoveryFailure(message: "No review") }
        app.approveLocallyAndOpen(review: review)
        app.reviewSheetDidClose()
        try await wait("API setup failure") { app.errorMessage != nil && !app.isInstalling }
        try require(fixture.apiPreparationCalls == 1 && app.launch == nil, "Actual approved API setup failed once")
        fixture.failAPIPreparation = false
        fixture.files.arm(1)
        app.retry()
        try await wait("Core failure while retrying API setup") { app.errorMessage != nil }
        try require(app.retryAction == .open(fixture.identity), "Core failure must not strand approved API setup")
        try require(fixture.apiPreparationCalls == 1, "Failed Core check must not run API setup")
        app.retry()
        try await wait("second API setup Retry") { app.launch != nil || app.errorMessage != nil }
        try require(app.launch != nil && fixture.apiPreparationCalls == 2, "Safe next Retry must finish the exact approved setup")
        app.closeApp(); app.appSheetDidClose()
    }

    static func websiteRetriesHostPreparation(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let app = fixture.model()
        var preparationCalls = 0
        let website = NativeShellWebsiteInstallModel(
            coordinator: fixture.coordinator,
            client: PublikMobileCatalogClient(transport: fixture.transport),
            capabilityPolicy: .denyAll,
            canPresent: { !app.hasBlockingPresentation },
            prepareHost: {
                preparationCalls += 1
                // The Host can become busy before its async reservation settles.
                // No flow has prepared a catalogue request at this boundary yet.
                guard preparationCalls > 1 else { return false }
                return await app.prepareForDirectWebsiteIntent()
            }
        )
        website.receive(fixture.intent)
        try await wait("Host preparation refusal") { website.failureMessage != nil }
        let initialRequests = await fixture.transport.requestCount()
        try require(initialRequests == 0 && website.canRetry, "A busy Host must leave a retryable request without downloading")
        website.retry()
        try await wait("Host preparation Retry") { website.review != nil || website.failureMessage != nil }
        try require(website.review != nil && preparationCalls == 2,
                    "Retry after a busy Host must re-run preparation instead of calling an uninitialized flow")
        let requests = await fixture.transport.requestCount()
        let library = try await fixture.coordinator.refreshLibrary()
        try require(requests == 2 && library.isEmpty && fixture.apiPreparationCalls == 0,
                    "Retry may prepare the exact review, never approve, install or configure its API")
        website.cancel()
    }

    static func websiteAdoptionRefreshCannotOverwriteNewerSelection(
        _ fixture: MobileWebsiteRecoveryFixture
    ) async throws {
        try await fixture.installRefreshRaceBlockers()
        _ = try await fixture.seed(fixture.initial)
        let updateReview = try await fixture.coordinator.reviewImport(packageBytes: fixture.update)
        let staged = try await fixture.coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: updateReview.reviewToken,
            packageSHA256: updateReview.packageSHA256
        )
        try require(staged.revisionId != fixture.revision, "Harness update must be a distinct staged revision")

        let app = fixture.model()
        let website = fixture.website(app)
        website.receive(fixture.intent)
        try await wait("existing website app open") {
            !website.isPresented || website.failureMessage != nil
        }
        guard let existing = website.presentationWasDismissed() else {
            throw MobileWebsiteRecoveryFailure(message: "Harness could not obtain the existing verified website launch")
        }
        try require(existing.source == .alreadyInstalled, "Harness must exercise the no-redownload existing-app path")

        fixture.files.armRefreshRace(
            blockerA: fixture.refreshBlockerAIdentity,
            blockerB: fixture.refreshBlockerBIdentity
        )
        defer {
            fixture.files.releaseStaleRefreshBlock()
            fixture.files.releaseNewerRefreshBlock()
        }
        app.adoptVerifiedWebsiteLaunch(existing)
        try await wait("stale adoption refresh reached the later blocker app") {
            fixture.files.isStaleRefreshBlocked || fixture.files.refreshRaceTimedOut
        }
        try require(!fixture.files.refreshRaceTimedOut,
                    "Harness stale-refresh blocker timed out before the newer selection")
        try require(app.launch?.launchedRevisionId == fixture.revision,
                    "Harness must first adopt the website's existing current revision")

        app.closeApp()
        app.appSheetDidClose()
        app.activate(identity: fixture.identity, revisionId: staged.revisionId)
        try await wait("newer selection refresh reached its earlier blocker app") {
            fixture.files.isNewerRefreshBlocked || fixture.files.refreshRaceTimedOut
        }
        try require(!fixture.files.refreshRaceTimedOut,
                    "Harness newer-refresh blocker timed out before stale refresh was released")
        let selected = try await fixture.coordinator.libraryEntry(identity: fixture.identity)
        try require(selected?.currentRevisionId == staged.revisionId,
                    "Production activation did not select the staged update while the stale refresh was isolated")

        fixture.files.releaseStaleRefreshBlock()
        try await wait("stale adoption refresh finished its blocker app snapshot") {
            fixture.files.staleBlockerActivePointerReads >= 2 || fixture.files.refreshRaceTimedOut
        }
        try require(!fixture.files.refreshRaceTimedOut, "Harness stale-refresh release timed out")
        try await Task.sleep(nanoseconds: 50_000_000)
        let visibleBeforeNewRefresh = app.library.first { $0.identity == fixture.identity }?.currentRevisionId
        try require(
            visibleBeforeNewRefresh != fixture.revision,
            "Late website-adoption refresh published stale revision \(visibleBeforeNewRefresh ?? "nil") after newer selection \(staged.revisionId)"
        )

        fixture.files.releaseNewerRefreshBlock()
        try await wait("newer version selection published") {
            app.library.first { $0.identity == fixture.identity }?.currentRevisionId == staged.revisionId
                || app.errorMessage != nil
        }
        try require(!fixture.files.refreshRaceTimedOut, "Harness newer-refresh release timed out")
        try require(app.errorMessage == nil, "Newer version selection failed during stale-refresh setup")
        try require(app.library.first { $0.identity == fixture.identity }?.currentRevisionId == staged.revisionId,
                    "Newer version selection did not become the visible library state")
    }

    static func prepareWebsite(_ fixture: MobileWebsiteRecoveryFixture, usage: NativeUsageService) async throws -> NativeShellWebsiteInstallModel {
        let website = fixture.website(fixture.model(), usageService: usage)
        website.receive(fixture.intent)
        try await wait("usage fixture review") { website.review != nil || website.failureMessage != nil }
        try require(website.review != nil, "The actual website flow must reach its consent boundary")
        return website
    }

    static func finishWebsite(_ website: NativeShellWebsiteInstallModel) async throws {
        website.installAndOpen()
        try await wait("usage fixture install") { !website.isPresented || website.failureMessage != nil }
        try require(website.presentationWasDismissed() != nil, "The actual website flow must complete")
    }

    static func counts(_ usage: NativeUsageService) -> [NativeUsageSummaryCount] {
        usage.flushForTesting()
        return usage.snapshot().dailySummaries.flatMap(\.eventCounts)
    }

    static func websiteUsageRecordsActualTransitions(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let usage = NativeUsageService(rootURL: fixture.root.appendingPathComponent("synthetic-usage"))
        try usage.grantConsent()
        let website = try await prepareWebsite(fixture, usage: usage)
        let before = counts(usage)
        try require(before.reduce(0) { $0 + $1.count } == 5, "Direct website preparation must record catalogue/download/review, not omit the new normal route")
        try require(!before.contains { [.stageAttempt, .activateAttempt, .openLoaded].contains($0.eventKind) }, "Preparation is not staging, activation or a successful app load")
        try await finishWebsite(website)
        let after = counts(usage)
        let expected: Set<NativeUsageEventKind> = [.catalogLoadAttempt, .catalogLoadOutcome, .downloadAttempt, .downloadOutcome,
            .reviewAttempt, .reviewOutcome, .stageAttempt, .stageOutcome, .activateAttempt, .activateOutcome]
        try require(Set(after.map(\.eventKind)) == expected && after.allSatisfy { $0.count == 1 }, "Each real setup transition must be recorded once")
        try require(after.filter { $0.outcome != nil }.allSatisfy { $0.outcome == .success }, "Only actual completed transitions may be successes")
        try require(!after.contains { $0.eventKind == .openLoaded }, "Core launch preparation cannot claim WebKit loaded")
    }

    static func websiteUsageStaysOff(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let usage = NativeUsageService(rootURL: fixture.root.appendingPathComponent("synthetic-usage"))
        let website = try await prepareWebsite(fixture, usage: usage)
        try await finishWebsite(website)
        try require(counts(usage).isEmpty, "Normal Off means no website operation records")
        let snapshot = usage.snapshot()
        try require(snapshot.consentState == .disabled && snapshot.pendingEventCount == 0 && snapshot.retainedRawEventCount == 0,
                    "Installing must not enable usage or retain events without consent")
    }

    static func websiteUsageDoesNotBackfillLateConsent(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let usage = NativeUsageService(rootURL: fixture.root.appendingPathComponent("synthetic-usage"))
        let website = try await prepareWebsite(fixture, usage: usage)
        try usage.grantConsent()
        try await finishWebsite(website)
        let after = counts(usage)
        try require(Set(after.map(\.eventKind)) == Set([.stageAttempt, .stageOutcome, .activateAttempt, .activateOutcome]),
                    "New consent may observe the new explicit install, not backfill the older download or review")
        try require(after.allSatisfy { $0.count == 1 }, "No duplicated setup events")
    }

    static func websiteUsageDoesNotRenewAnOldReviewBinding(_ fixture: MobileWebsiteRecoveryFixture) async throws {
        let usage = NativeUsageService(rootURL: fixture.root.appendingPathComponent("synthetic-usage"))
        try usage.grantConsent()
        let website = try await prepareWebsite(fixture, usage: usage)
        let before = counts(usage)
        try require(before.reduce(0) { $0 + $1.count } == 5, "Review must be observed under the original consent")
        try usage.pause(); try usage.resume()
        try await finishWebsite(website)
        let after = counts(usage)
        try require(!after.contains { $0.eventKind == .reviewOutcome }, "An old review completion cannot reacquire renewed consent")
        try require(after.reduce(0) { $0 + $1.count } == 9, "Only the new explicit installation's four transitions use renewed consent")
    }
}

private struct MobileWebsiteRecoveryFailure: Error { let message: String }

@MainActor
private final class MobileWebsiteRecoveryFixture {
    let root: URL
    let initial: Data
    let update: Data
    let identity: NativeShellAppIdentity
    let revision: String
    let coordinator: NativeShellLibraryCoordinator
    let files: MobileWebsiteRecoveryFileManager
    let transport: MobileWebsiteRecoveryTransport
    let apiStore: NativePackagedAPIInstallationStore
    let signer = SignedAPITestFixture()
    let intent = URL(string: "https://publikhq.com/iris/apps/recovery-fixture")!
    let refreshBlockerAIdentity = NativeShellAppIdentity(
        appId: "zzza.iris.refresh.race",
        projectId: "zzza.iris.refresh.race"
    )
    let refreshBlockerBIdentity = NativeShellAppIdentity(
        appId: "zzzb.iris.refresh.race",
        projectId: "zzzb.iris.refresh.race"
    )
    var apiPreparationCalls = 0
    var failAPIPreparation = false

    init(root: URL, initial: Data, update: Data) throws {
        self.root = root; self.initial = initial; self.update = update
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: initial)
        identity = NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId)
        revision = inspection.revisionId
        files = MobileWebsiteRecoveryFileManager(root: root.appendingPathComponent("apps"), identity: identity)
        coordinator = NativeShellLibraryCoordinator(rootURL: root.appendingPathComponent("apps"), fileManager: files)
        apiStore = try NativePackagedAPIInstallationStore(rootURL: root.appendingPathComponent("api"), verifier: signer.verifier())
        transport = try MobileWebsiteRecoveryTransport(package: initial, inspection: inspection)
    }

    func model() -> NativeShellAppModel {
        NativeShellAppModel(coordinator: coordinator, bundledDemoPackage: initial,
            preparePackagedAPIForLaunch: { [self] launch in
                apiPreparationCalls += 1
                if failAPIPreparation { throw MobileWebsiteRecoveryFailure(message: "Synthetic API setup failure") }
                _ = try apiStore.install(signer.package(identity: identity, revision: launch.revisionId), for: launch)
            }, packagedAPIAdapterForLaunch: apiStore.adapterConfiguration)
    }

    func website(_ app: NativeShellAppModel, usageService: NativeUsageService? = nil) -> NativeShellWebsiteInstallModel {
        NativeShellWebsiteInstallModel(coordinator: coordinator, client: PublikMobileCatalogClient(transport: transport),
            capabilityPolicy: .denyAll, usageService: usageService, canPresent: { !app.hasBlockingPresentation },
            prepareHost: { await app.prepareForDirectWebsiteIntent() })
    }

    func seed(_ bytes: Data) async throws -> String {
        let review = try await coordinator.reviewImport(packageBytes: bytes)
        _ = try await coordinator.approvePendingReviewLocallyAndStage(reviewToken: review.reviewToken, packageSHA256: review.packageSHA256)
        try await coordinator.activate(identity: review.identity, revisionId: review.revisionId)
        return review.revisionId
    }

    func installRefreshRaceBlockers() async throws {
        for (identity, minute) in [(refreshBlockerAIdentity, 41), (refreshBlockerBIdentity, 42)] {
            let package = try refreshRaceBlockerPackage(identity: identity, minute: minute)
            let review = try await coordinator.reviewImport(packageBytes: package, expectedIdentity: identity)
            _ = try await coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: review.reviewToken,
                packageSHA256: review.packageSHA256
            )
            try await coordinator.activate(identity: identity, revisionId: review.revisionId)
        }
    }

    private func refreshRaceBlockerPackage(identity: NativeShellAppIdentity, minute: Int) throws -> Data {
        let content = Data("<!doctype html><title>Refresh race blocker</title>".utf8)
        let namespace = identity.appId
        let manifest = DeliveryManifestReceipt(
            displayName: "Refresh race blocker",
            runtimeType: "web",
            entrypoint: "index.html",
            minShellVersion: "1.0.0",
            requestedCapabilities: [],
            dataNamespace: namespace,
            dataUpdatePolicy: "preserve"
        )
        let file = DeliveryFileReceipt(
            path: "index.html",
            sha256: NativeSecurity.sha256(content),
            bytes: content.count,
            mediaType: "text/html",
            data: content
        )
        let digest = NativeSecurity.revisionIdentity(
            appId: identity.appId,
            projectId: identity.projectId,
            baseRevisionId: nil,
            manifest: manifest,
            files: [file]
        )
        let timestamp = String(format: "2026-09-21T00:%02d:00.000Z", minute)
        let approvalID = "approval-\(UUID().uuidString)"
        let null = NSNull()
        let manifestJSON: [String: Any] = [
            "kind": "iris.mobile-shell.manifest", "version": 1,
            "appId": identity.appId, "projectId": identity.projectId,
            "displayName": manifest.displayName,
            "runtime": ["type": "web", "entrypoint": "index.html", "minShellVersion": "1.0.0"],
            "capabilities": [],
            "data": ["namespace": namespace, "updatePolicy": "preserve"]
        ]
        let revision: [String: Any] = [
            "kind": "iris.mobile-shell.revision", "version": 1,
            "appId": identity.appId, "projectId": identity.projectId,
            "baseRevisionId": null, "revisionId": digest.revisionId,
            "manifestHash": digest.manifestHash, "contentHash": digest.contentHash,
            "createdAt": timestamp, "manifest": manifestJSON,
            "files": [[
                "path": file.path, "sha256": file.sha256,
                "bytes": file.bytes, "mediaType": file.mediaType
            ]]
        ]
        let approval: [String: Any] = [
            "kind": "iris.mobile-shell.delivery-approval", "version": 1,
            "approvalId": approvalID, "requestId": null, "requestNonce": null,
            "appId": identity.appId, "projectId": identity.projectId,
            "baseRevisionId": null, "approvedRevisionId": digest.revisionId,
            "approvedContentHash": digest.contentHash, "approvedAt": timestamp
        ]
        let envelope: [String: Any] = [
            "kind": "iris.mobile-shell.delivery-envelope", "version": 1,
            "envelopeId": "delivery-\(UUID().uuidString)",
            "deliveryNonce": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "approvalId": approvalID, "appId": identity.appId, "projectId": identity.projectId,
            "baseRevisionId": null, "revisionId": digest.revisionId,
            "contentHash": digest.contentHash, "issuedAt": timestamp, "revision": revision
        ]
        return try JSONSerialization.data(withJSONObject: [
            "format": NativeSecurity.packageFormat,
            "approval": approval,
            "envelope": envelope,
            "files": [[
                "path": file.path,
                "mediaType": file.mediaType,
                "contentBase64": content.base64EncodedString()
            ]]
        ], options: [.sortedKeys])
    }
}

private final class MobileWebsiteRecoveryFileManager: FileManager, @unchecked Sendable {
    let activePointer: URL
    private let root: URL
    private let contentPrefix: String
    private let lock = NSLock()
    private var remaining = 0
    private let refreshRaceCondition = NSCondition()
    private var blockerARevisionsPath: String?
    private var blockerBRevisionsPath: String?
    private var blockerBActivePointerPath: String?
    private var blockerARevisionReads = 0
    private var blockerBRevisionReads = 0
    private var blockerBPointerReads = 0
    private var staleRefreshBlocked = false
    private var newerRefreshBlocked = false
    private var releaseStaleRefresh = false
    private var releaseNewerRefresh = false
    private var didTimeOutRefreshRace = false

    init(root: URL, identity: NativeShellAppIdentity) {
        self.root = root
        activePointer = root.appendingPathComponent("state/\(identity.appId)/\(identity.projectId)/active.json")
        contentPrefix = root.appendingPathComponent("content/\(identity.appId)/\(identity.projectId)/revisions").path + "/"
        super.init()
    }
    func arm(_ count: Int) { lock.withLock { remaining = count } }
    func armRefreshRace(blockerA: NativeShellAppIdentity, blockerB: NativeShellAppIdentity) {
        refreshRaceCondition.lock()
        blockerARevisionsPath = revisionsPath(for: blockerA)
        blockerBRevisionsPath = revisionsPath(for: blockerB)
        blockerBActivePointerPath = pointerPath(for: blockerB)
        blockerARevisionReads = 0
        blockerBRevisionReads = 0
        blockerBPointerReads = 0
        staleRefreshBlocked = false
        newerRefreshBlocked = false
        releaseStaleRefresh = false
        releaseNewerRefresh = false
        didTimeOutRefreshRace = false
        refreshRaceCondition.unlock()
    }
    var isStaleRefreshBlocked: Bool { refreshRaceValue { staleRefreshBlocked } }
    var isNewerRefreshBlocked: Bool { refreshRaceValue { newerRefreshBlocked } }
    var refreshRaceTimedOut: Bool { refreshRaceValue { didTimeOutRefreshRace } }
    var staleBlockerActivePointerReads: Int { refreshRaceValue { blockerBPointerReads } }
    func releaseStaleRefreshBlock() {
        refreshRaceCondition.lock()
        releaseStaleRefresh = true
        refreshRaceCondition.broadcast()
        refreshRaceCondition.unlock()
    }
    func releaseNewerRefreshBlock() {
        refreshRaceCondition.lock()
        releaseNewerRefresh = true
        refreshRaceCondition.broadcast()
        refreshRaceCondition.unlock()
    }
    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let path = url.standardizedFileURL.path
        refreshRaceCondition.lock()
        if path == blockerARevisionsPath {
            blockerARevisionReads += 1
            if blockerARevisionReads == 2 {
                newerRefreshBlocked = true
                waitForRefreshRaceRelease({ releaseNewerRefresh })
                newerRefreshBlocked = false
            }
        } else if path == blockerBRevisionsPath {
            blockerBRevisionReads += 1
            if blockerBRevisionReads == 1 {
                staleRefreshBlocked = true
                waitForRefreshRaceRelease({ releaseStaleRefresh })
                staleRefreshBlocked = false
            }
        }
        refreshRaceCondition.unlock()
        return try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
    }
    override func fileExists(atPath path: String) -> Bool {
        if path == blockerBActivePointerPath {
            refreshRaceCondition.lock()
            blockerBPointerReads += 1
            refreshRaceCondition.broadcast()
            refreshRaceCondition.unlock()
        }
        return super.fileExists(atPath: path)
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let eligible = path.hasPrefix(contentPrefix) && path.hasSuffix("/content/index.html")
            && FileManager.default.fileExists(atPath: activePointer.path)
        let fail = lock.withLock { () -> Bool in
            guard eligible, remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if fail { throw MobileWebsiteRecoveryFailure(message: "Synthetic post-activation content read failed") }
        return try super.attributesOfItem(atPath: path)
    }
    private func revisionsPath(for identity: NativeShellAppIdentity) -> String {
        root.appendingPathComponent(
            "content/\(identity.appId)/\(identity.projectId)/revisions",
            isDirectory: true
        ).standardizedFileURL.path
    }
    private func pointerPath(for identity: NativeShellAppIdentity) -> String {
        root.appendingPathComponent(
            "state/\(identity.appId)/\(identity.projectId)/active.json"
        ).standardizedFileURL.path
    }
    private func refreshRaceValue<T>(_ body: () -> T) -> T {
        refreshRaceCondition.lock()
        defer { refreshRaceCondition.unlock() }
        return body()
    }
    private func waitForRefreshRaceRelease(_ released: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !released() {
            guard refreshRaceCondition.wait(until: deadline) else {
                didTimeOutRefreshRace = true
                break
            }
        }
    }
}

private actor MobileWebsiteRecoveryTransport: PublikMobileHTTPTransport {
    private let package: Data
    private let catalog: Data
    private let packageURL = URL(string: "https://publikhq.com/mobile/recovery-fixture.irisapp")!
    private var count = 0
    init(package: Data, inspection: DeliveryPackageInspection) throws {
        self.package = package
        catalog = try JSONSerialization.data(withJSONObject: ["apps": [[
            "slug": "recovery-fixture", "name": "Recovery fixture", "mobileShell": [
                "version": 1, "platform": "ios", "packageFormat": NativeSecurity.packageFormat,
                "downloadUrl": packageURL.absoluteString, "mediaType": "application/json", "byteCount": package.count,
                "packageSha256": inspection.packageSHA256, "appId": inspection.appId, "projectId": inspection.projectId,
                "baseRevisionId": inspection.baseRevisionId as Any? ?? NSNull(), "revisionId": inspection.revisionId,
                "contentHash": inspection.contentHash
            ]
        ]]], options: [.sortedKeys])
    }
    func get(_ request: URLRequest, maximumBytes: Int, progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        guard let url = request.url, url == PublikMobileCatalogClient.catalogURL || url == packageURL else {
            throw MobileWebsiteRecoveryFailure(message: "Unexpected transport URL")
        }
        count += 1
        let body = url == packageURL ? package : catalog
        guard body.count <= maximumBytes else { throw MobileWebsiteRecoveryFailure(message: "Response bound exceeded") }
        return PublikMobileHTTPResponse(statusCode: 200, mimeType: "application/json", declaredContentLength: body.count, finalURL: url, body: body)
    }
    func requestCount() -> Int { count }
}
// END_MOBILE_WEBSITE_RECOVERY_SCENARIOS

@MainActor
final class NativeMobileWebsiteRecoveryAcceptanceTests: XCTestCase {
    func testWebsiteRetryAfterBusyHostRechecksPreparationWithoutImplicitApproval() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteRetriesHostPreparation)
    }
    func testDirectWebsiteAdoptionLateRefreshCannotOverwriteNewerVersionSelection() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteAdoptionRefreshCannotOverwriteNewerSelection)
    }
    func testDirectWebsiteUsageRecordsOnlyActualSetupTransitions() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteUsageRecordsActualTransitions)
    }
    func testDirectWebsiteInstallNeverEnablesUsageOrCollectsWhileOff() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteUsageStaysOff)
    }
    func testDirectWebsiteUsageDoesNotBackfillConsentGrantedAfterReview() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteUsageDoesNotBackfillLateConsent)
    }
    func testDirectWebsiteReviewCannotReacquireConsentAfterPauseAndResume() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteUsageDoesNotRenewAnOldReviewBinding)
    }
    func testWebsitePostActivationRetryRetainsApprovedAPIAndDoesNotRedownload() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteApprovedRetry)
    }
    func testCancellingFailedWebsiteInstallRevokesFirstAPISetupPermission() async throws {
        try await run(MobileWebsiteRecoveryScenarios.websiteCancellationRevokesSetup)
    }
    func testInterveningVersionSelectionCannotReviveWebsiteAPISetupPermission() async throws {
        try await run(MobileWebsiteRecoveryScenarios.interveningSelectionInvalidatesSetup)
    }
    func testOrdinaryOpenRetainsRealRetryAcrossRepeatedCoreFailures() async throws {
        try await run(MobileWebsiteRecoveryScenarios.ordinaryOpenRetainsRetry)
    }
    func testApprovedAPISetupRetrySurvivesAnotherCoreReadFailure() async throws {
        try await run(MobileWebsiteRecoveryScenarios.apiSetupRetryRetainsRetry)
    }
    private func run(_ scenario: MobileWebsiteRecoveryScenarios.Scenario) async throws {
        let root = try makeWebsiteHostRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try XCTUnwrap(Bundle.main.url(forResource: "SafeDemo", withExtension: "irisapp"))
        let update = try XCTUnwrap(Bundle.main.url(forResource: "SafeDemoUpdate", withExtension: "irisapp"))
        let fixture = try MobileWebsiteRecoveryFixture(root: root, initial: Data(contentsOf: initial), update: Data(contentsOf: update))
        try await scenario(fixture)
    }
}

#endif
