import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Independent-verifier regression test for a real, reproduced defect: two
/// concurrent callers of `setDecision` (for example the Host's explicit
/// permissions screen racing the WebView's own first-use grant observer)
/// could each take a consistent in-memory snapshot but land their disk
/// writes out of order, so the earlier call's stale snapshot silently
/// overwrote the later call's newer one on disk. The in-memory state inside
/// one running process stayed correct either way, so this only ever showed
/// up after a fresh load from disk (a relaunch) - exactly what every other
/// test in this suite simulates by calling `fixture.makeStore()` again.
///
/// This is a real stress test against the real, unmocked store: many
/// concurrent writers, a real reload from disk, and an assertion that reads
/// the store's own observable `decision(...)` result, never a constant this
/// test set itself. Deleting the fix (see `PLAN.md`) makes this fail on
/// close to every run, not flakily; 60 rounds of 8 concurrent writers each
/// is chosen to make that failure essentially certain while keeping the
/// suite fast.
final class NativePermissionStoreConcurrencyTests: XCTestCase {
    func testConcurrentDecisionsForDifferentCapabilitiesAllSurviveAReloadFromDisk() {
        for round in 0..<60 {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("iris-permission-concurrency-\(round)-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let identity = NativeShellAppIdentity(appId: "iris.concurrencyapp", projectId: "iris.concurrencyapp.mobile")
            let store = NativePermissionStore(rootURL: root)
            let capabilities = (0..<8).map { "concurrency-cap-\($0)" }

            let group = DispatchGroup()
            for capability in capabilities {
                group.enter()
                DispatchQueue.global().async {
                    _ = try? store.setDecision(.granted, for: capability, identity: identity)
                    group.leave()
                }
            }
            group.wait()

            // A fresh store loaded from the same disk root, exactly like a
            // relaunch of the Iris app, must show every one of the eight
            // concurrent decisions as granted, not only the ones that
            // happened to be the last write to actually land on disk.
            let reloaded = NativePermissionStore(rootURL: root)
            for capability in capabilities {
                XCTAssertEqual(
                    reloaded.decision(for: capability, identity: identity), .granted,
                    "round \(round): \(capability) did not survive a reload from disk after a concurrent grant"
                )
            }
        }
    }
}
