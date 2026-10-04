#if os(iOS)
import Combine
import SwiftUI
import UIKit
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

/// View-wiring coverage for the two phone fixes (B-home-and-first-launch):
/// the "setting up your apps" library state and the Home confirmation.
///
/// The full behavior of both decisions (`NativeStarterSetupPlanning`,
/// `NativeHomeConfirmState`) is already covered by `swift test` on Core,
/// with plain in-memory values and no UI involved; this file exists only to
/// prove those pieces actually wire up to the real `Host` module and to the
/// real SwiftUI views, the way `NativeAppCloseSwiftUITeardownTests` and
/// `NativeMultiAppRuntimeTests` already do for the neighboring close flow
/// (hosting the real view in a real window, never simulating a tap on a
/// system alert or a SwiftUI `Button` directly, which this codebase does
/// not do anywhere).
@MainActor
final class NativeHomeAndFirstLaunchWiringTests: XCTestCase {
    // MARK: - NativeStarterSetupStatus publishes on the main actor

    func testStarterSetupStatusPublishesWhenSetupStartsAndWhenItFinishes() {
        let status = NativeStarterSetupStatus()
        XCTAssertEqual(status.snapshot, .idle)

        var seen: [NativeStarterSetupSnapshot] = []
        let cancellable = status.$snapshot.dropFirst().sink { seen.append($0) }
        defer { cancellable.cancel() }

        let chains = ["kneecap": NativeStarterInstaller.AppChain(displayName: "Kneecap", orderedPackages: [])]
        status.markStarted(chains: chains, needing: ["kneecap"], order: ["kneecap"])
        XCTAssertEqual(status.snapshot.runningAppNames, ["Kneecap"])

        status.markFinished(
            chains: chains,
            results: ["kneecap": .installed([], finalRevisionId: "rev-a")],
            order: ["kneecap"]
        )
        XCTAssertEqual(status.snapshot, .idle)

        XCTAssertEqual(seen.map(\.runningAppNames), [["Kneecap"], []],
                       "the view's onChange relies on exactly these two publishes to know when to refresh")
    }

    func testStarterSetupStatusInitialValueCanBeSeededForTests() {
        let running = NativeStarterSetupSnapshot(runningAppNames: ["Kneecap"], failedAppNames: [])
        let status = NativeStarterSetupStatus(snapshot: running)
        XCTAssertEqual(status.snapshot, running)
    }

    // MARK: - NativeShellAppView accepts an App-owned starter status without crashing

    func testShellAppViewHostsWithARunningStarterStatusAndLayoutSucceeds() async throws {
        let fixture = try MultiAppRuntimeFixtureForShell()
        defer { fixture.close() }
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let status = NativeStarterSetupStatus(
            snapshot: NativeStarterSetupSnapshot(runningAppNames: ["Kneecap", "Nut AI", "FreeHarmony"], failedAppNames: [])
        )
        let view = NativeShellAppView(
            coordinator: coordinator,
            catalogClient: PublikMobileCatalogClient(transport: NoNetworkTransport()),
            starterSetupStatus: status
        )
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        // Give the view's `.task { await onAppear() }` an actual chance to
        // run (it starts on the next run-loop turn, not synchronously with
        // layout) before treating "nothing crashed" as meaningful.
        await Task.yield()
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Reaching here without a crash or a hang is the assertion: the
        // App's starter status plugs into the real view and its onAppear /
        // onChange wiring does not deadlock or trap while running.
        XCTAssertEqual(status.snapshot.runningAppNames, ["Kneecap", "Nut AI", "FreeHarmony"],
                       "hosting the view must not itself mutate App-owned state")
    }

    // MARK: - NativeFullscreenAppView accepts a display name and never closes on its own

    func testFullscreenAppViewHostsWithADisplayNameAndNeverAutoCloses() async throws {
        let fixture = try MultiAppRuntimeFixture()
        let coordinator = NativeShellLibraryCoordinator(rootURL: fixture.root)
        let outcome: NativeShellLaunchOutcome
        do { outcome = try await fixture.install(capabilities: [], coordinator: coordinator) }
        catch { fixture.close(); throw error }

        let loaded = expectation(description: "real fullscreen document loaded with a display name set")
        var closeCalls = 0
        let fullscreen = NativeFullscreenAppView(
            launch: outcome.launch,
            adapter: .notConfigured,
            presentationID: UUID(),
            hasLoadFailure: false,
            onLoadResult: { result in
                guard result == .loaded else { return }
                loaded.fulfill()
            },
            onClose: { closeCalls += 1 },
            displayName: "Kneecap",
            pendingRequest: { _ in EmptyView() }
        )
        let controller = UIHostingController(rootView: AnyView(fullscreen))
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            fixture.close()
        }

        await fulfillment(of: [loaded], timeout: 5)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        XCTAssertEqual(closeCalls, 0,
                       "showing the app (and its Home button) must never call onClose by itself; only a confirmed Home tap may")
        XCTAssertNil(controller.presentedViewController,
                     "no confirmation should be showing before the reader ever taps Home")
    }
}

/// Fails every request immediately instead of reaching the real network, the
/// same way a real device with no connectivity would: `NativeShellCatalogModel`
/// is built to show `catalog.errorMessage` in that case, not crash or hang,
/// which keeps this a fast, offline-safe unit test.
private struct NoNetworkTransport: PublikMobileHTTPTransport {
    func get(_ request: URLRequest, maximumBytes: Int,
             progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

/// A minimal fixture for hosting `NativeShellAppView` on its own (no real
/// starter/catalog content needed: these tests are about the App-owned
/// status object reaching the view, not about library contents).
private struct MultiAppRuntimeFixtureForShell {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-shell-wiring-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}
#endif
