#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import IrisMobileShellHost

@MainActor
final class NativeFullscreenHomeSafeAreaTests: XCTestCase {
    func testHomeClampPreservesZeroInsetBehaviorAndProtectsTheEntire44PointTarget() {
        XCTAssertEqual(
            NativeHomeControlGeometry.clamp(
                CGPoint(x: -100, y: 2000),
                to: CGSize(width: 402, height: 874)
            ),
            CGPoint(x: 28, y: 846)
        )
        XCTAssertEqual(
            NativeHomeControlGeometry.clamp(
                CGPoint(x: 846, y: 800),
                to: CGSize(width: 874, height: 402)
            ),
            CGPoint(x: 846, y: 374)
        )
        XCTAssertEqual(
            NativeHomeControlGeometry.clamp(
                CGPoint(x: 374, y: 846),
                to: .zero
            ),
            .zero
        )

        let size = CGSize(width: 402, height: 874)
        let insets = UIEdgeInsets(top: 59, left: 12, bottom: 34, right: 12)
        assertExtremeHomePlacementsStayReachable(size: size, safeAreaInsets: insets)
    }

    func testSafeAreaOwnershipRejectsLateEventsFromAnOlderProbe() {
        let older = UUID()
        let newer = UUID()
        var state = NativeWindowSafeAreaState()

        state.apply(.init(
            probeID: older,
            kind: .attached,
            attachStamp: 10,
            insets: UIEdgeInsets(top: 40, left: 0, bottom: 20, right: 0)
        ))
        state.apply(.init(
            probeID: newer,
            kind: .attached,
            attachStamp: 20,
            insets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        ))

        state.apply(.init(
            probeID: older,
            kind: .detached,
            attachStamp: 10,
            insets: .zero
        ))
        state.apply(.init(
            probeID: older,
            kind: .changed,
            attachStamp: 10,
            insets: UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        ))
        state.apply(.init(
            probeID: older,
            kind: .attached,
            attachStamp: 10,
            insets: .zero
        ))

        XCTAssertEqual(state.activeProbeID, newer)
        XCTAssertEqual(state.insets, UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0))

        state.apply(.init(
            probeID: newer,
            kind: .detached,
            attachStamp: 20,
            insets: .zero
        ))
        XCTAssertNil(state.activeProbeID)
        XCTAssertEqual(state.insets, .zero)
    }

    func testSceneBackedReaderUsesActualWindowInsetsForEdgePlacementAndSwappedGeometry() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        let previousKey = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds

        let receivedActualInsets = expectation(description: "reader publishes the actual scene-backed window safe area")
        var didFulfill = false
        var state = NativeWindowSafeAreaState()
        let controller = UIHostingController(rootView:
            NativeWindowSafeAreaInsetsReader { event in
                state.apply(event)
                let expectedInsets = window.safeAreaInsets
                guard !didFulfill,
                      event.kind != .detached,
                      expectedInsets != .zero,
                      state.insets == expectedInsets else { return }
                didFulfill = true
                receivedActualInsets.fulfill()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKey?.makeKeyAndVisible()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let initialInsets = window.safeAreaInsets
        XCTAssertNotEqual(initialInsets, .zero,
                          "iPhone 17 Pro acceptance requires a real nonzero system safe area.")
        await fulfillment(of: [receivedActualInsets], timeout: 2)
        XCTAssertEqual(state.insets, initialInsets)
        XCTAssertGreaterThanOrEqual(
            window.bounds.width,
            initialInsets.left + initialInsets.right + 56,
            "scene width must fit the complete 44-point Home target plus its safe-edge margins"
        )
        XCTAssertGreaterThanOrEqual(
            window.bounds.height,
            initialInsets.top + initialInsets.bottom + 56,
            "scene height must fit the complete 44-point Home target plus its safe-edge margins"
        )
        assertExtremeHomePlacementsStayReachable(size: window.bounds.size, safeAreaInsets: initialInsets)

        // This is a scene-backed rotation-sized geometry check, not a claim that
        // the interface orientation changed. It deliberately reads the window's
        // actual post-resize safeAreaInsets rather than fabricating rotated insets.
        let originalFrame = window.frame
        window.frame = CGRect(
            origin: originalFrame.origin,
            size: CGSize(width: originalFrame.height, height: originalFrame.width)
        )
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        await Task.yield()

        let swappedInsets = window.safeAreaInsets
        XCTAssertEqual(state.insets, swappedInsets)
        XCTAssertGreaterThanOrEqual(
            window.bounds.width,
            swappedInsets.left + swappedInsets.right + 56,
            "swapped scene width must fit the complete 44-point Home target plus its safe-edge margins"
        )
        XCTAssertGreaterThanOrEqual(
            window.bounds.height,
            swappedInsets.top + swappedInsets.bottom + 56,
            "swapped scene height must fit the complete 44-point Home target plus its safe-edge margins"
        )
        assertExtremeHomePlacementsStayReachable(size: window.bounds.size, safeAreaInsets: swappedInsets)
    }

    private func assertExtremeHomePlacementsStayReachable(
        size: CGSize,
        safeAreaInsets: UIEdgeInsets,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard size.width >= safeAreaInsets.left + safeAreaInsets.right + 56,
              size.height >= safeAreaInsets.top + safeAreaInsets.bottom + 56 else {
            return
        }

        for requested in [
            CGPoint(x: -10_000, y: -10_000),
            CGPoint(x: 10_000, y: 10_000)
        ] {
            let center = NativeHomeControlGeometry.clamp(
                requested,
                to: size,
                safeAreaInsets: safeAreaInsets
            )
            let hitTarget = CGRect(
                x: center.x - 22,
                y: center.y - 22,
                width: 44,
                height: 44
            )
            XCTAssertGreaterThanOrEqual(
                hitTarget.minX,
                safeAreaInsets.left + 6 - 0.001,
                file: file,
                line: line
            )
            XCTAssertGreaterThanOrEqual(
                hitTarget.minY,
                safeAreaInsets.top + 6 - 0.001,
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                hitTarget.maxX,
                size.width - safeAreaInsets.right - 6 + 0.001,
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                hitTarget.maxY,
                size.height - safeAreaInsets.bottom - 6 + 0.001,
                file: file,
                line: line
            )
        }
    }
}
#endif
