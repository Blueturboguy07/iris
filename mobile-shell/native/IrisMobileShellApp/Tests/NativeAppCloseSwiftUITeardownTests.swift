#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

@MainActor
final class NativeAppCloseSwiftUITeardownTests: XCTestCase {
    func testActualFullscreenSwiftUITeardownDoesNotPublishCloseHandleIntoDestroyedGraph() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let fixture = try MultiAppRuntimeFixture()
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome: NativeShellLaunchOutcome
        do {
            outcome = try await fixture.install(capabilities: [], coordinator: coordinator)
        } catch {
            fixture.close()
            throw error
        }

        let loaded = expectation(description: "real fullscreen verified document loaded")
        var didLoad = false
        var closeCalls = 0
        let fullscreen = NativeFullscreenAppView(
            launch: outcome.launch,
            adapter: .notConfigured,
            presentationID: UUID(),
            hasLoadFailure: false,
            onLoadResult: { result in
                guard !didLoad else { return }
                XCTAssertEqual(result, .loaded)
                didLoad = true
                loaded.fulfill()
            },
            onClose: { closeCalls += 1 },
            pendingRequest: { _ in EmptyView() }
        )
        let controller = UIHostingController(rootView: AnyView(fullscreen))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
            fixture.close()
        }

        await fulfillment(of: [loaded], timeout: 5)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        // This is the actual SwiftUI graph-destruction path from the captured
        // failing-before stack. Do not manually call dismantleUIView or the
        // close-handle callback: replacing the root owns descendant teardown.
        controller.rootView = AnyView(EmptyView())
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(closeCalls, 0, "view teardown must not masquerade as a reader Home action")
    }
}
#endif
