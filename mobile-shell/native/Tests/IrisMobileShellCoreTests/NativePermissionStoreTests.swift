import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Simulated people and devices exercising the real `NativePermissionStore`
/// across many "sessions" (a fresh store instance built from the same disk
/// root, exactly like a relaunch of the Iris app). No mock replaces the
/// store; every assertion reads back the store's own observable decision,
/// never a constant this test just set, and every scenario would fail if the
/// remembered-decision feature itself were removed and every request always
/// fell back to `.notDecided`.
final class NativePermissionStoreTests: XCTestCase {
    // MARK: P1: non-technical person, allows once, keeps using the camera

    func testP1AllowsOnceThenIsNeverAskedAgainAcrossTwentyRelaunches() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")

        // Before the person has ever answered, every fresh session must ask.
        XCTAssertEqual(fixture.makeStore().decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)

        // P1 taps Allow exactly once, on the very first camera use.
        let firstSession = fixture.makeStore()
        try firstSession.setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        // Twenty more camera uses, each simulated as a brand-new store loaded
        // fresh from the same disk root (a relaunch of the Iris app): none of
        // them may ask again.
        for use in 1...20 {
            let session = fixture.makeStore()
            XCTAssertEqual(
                session.decision(for: NativePermissionCapability.camera, identity: identity), .granted,
                "camera use #\(use) after relaunch must not be asked again"
            )
        }
    }

    // MARK: P3: edge-case person, denies, then later allows from the app's own permissions screen

    func testP3DeniesThenLaterAllowsAndTheOverrideHoldsAcrossRestart() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.freeharmony", projectId: "iris.freeharmony.mobile")

        try fixture.makeStore().setDecision(.denied, for: NativePermissionCapability.camera, identity: identity)
        XCTAssertEqual(
            fixture.makeStore().decision(for: NativePermissionCapability.camera, identity: identity), .denied,
            "a denial must hold for a session that did not set it"
        )

        // Later, from the permissions screen ("Settings"), the same person
        // flips this app to Allow.
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        let afterRestart = fixture.makeStore()
        XCTAssertEqual(afterRestart.decision(for: NativePermissionCapability.camera, identity: identity), .granted)
    }

    // MARK: An update that requests a brand-new capability asks once, for that capability only

    func testNewCapabilityOnAnUpdateIsIndependentOfAnAlreadyDecidedCapability() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.nut-ai", projectId: "iris.nut-ai.mobile")
        let existingCapability = NativePermissionCapability.camera
        let newlyRequestedCapability = "web.media.camera-plus-face-model"

        try fixture.makeStore().setDecision(.granted, for: existingCapability, identity: identity)

        // An update ships that declares a second capability nobody has ever
        // been asked about for this app. It must start at `.notDecided`
        // while the already-decided capability is completely untouched.
        let afterUpdate = fixture.makeStore()
        XCTAssertEqual(afterUpdate.decision(for: existingCapability, identity: identity), .granted)
        XCTAssertEqual(afterUpdate.decision(for: newlyRequestedCapability, identity: identity), .notDecided)

        try afterUpdate.setDecision(.granted, for: newlyRequestedCapability, identity: identity)
        let afterSecondDecision = fixture.makeStore()
        XCTAssertEqual(afterSecondDecision.decision(for: existingCapability, identity: identity), .granted)
        XCTAssertEqual(afterSecondDecision.decision(for: newlyRequestedCapability, identity: identity), .granted)
    }

    // MARK: A different app never inherits another app's grant

    func testADifferentAppNeverInheritsAnotherAppsGrant() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let grantedApp = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        let otherApp = try NativeShellAppIdentity(appId: "iris.freeharmony", projectId: "iris.freeharmony.mobile")

        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: grantedApp)

        let session = fixture.makeStore()
        XCTAssertEqual(session.decision(for: NativePermissionCapability.camera, identity: grantedApp), .granted)
        XCTAssertEqual(
            session.decision(for: NativePermissionCapability.camera, identity: otherApp), .notDecided,
            "granting one app's camera use must never leak to a different app"
        )

        // Same appId, different projectId (a distinct project under the same
        // developer) must also be treated as a different app.
        let sameAppDifferentProject = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.other-project")
        XCTAssertEqual(session.decision(for: NativePermissionCapability.camera, identity: sameAppDifferentProject), .notDecided)
    }

    // MARK: Fails closed on a corrupted or partially written store

    func testCorruptedStoreFailsClosedToNotDecidedRatherThanGranting() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)
        XCTAssertEqual(fixture.makeStore().decision(for: NativePermissionCapability.camera, identity: identity), .granted)

        // Overwrite the real, previously-valid store with garbage bytes, as
        // if a crash or a disk fault landed mid-write.
        try Data("not json at all {{{".utf8).write(to: fixture.storeFileURL, options: [.atomic])

        let afterCorruption = fixture.makeStore()
        XCTAssertEqual(
            afterCorruption.decision(for: NativePermissionCapability.camera, identity: identity), .notDecided,
            "a corrupted store must ask again, never silently grant the app's last known state"
        )
    }

    func testPartiallyWrittenStoreFailsClosedToNotDecided() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        let fullBytes = try Data(contentsOf: fixture.storeFileURL)
        XCTAssertGreaterThan(fullBytes.count, 4, "the fixture's own write should not be trivially empty")
        // A crash mid-write on a small file characteristically leaves a
        // truncated prefix, not a shuffled or bit-flipped file.
        let truncated = fullBytes.prefix(fullBytes.count / 2)
        try Data(truncated).write(to: fixture.storeFileURL, options: [.atomic])

        let afterTruncation = fixture.makeStore()
        XCTAssertEqual(afterTruncation.decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)
    }

    func testHandEditedStoreWithAnExtraFieldFailsClosed() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        // A real store file, exactly as ordinary use would create it, so this
        // test overwrites an existing store rather than relying on some other
        // test having already created the parent directory.
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        let handEdited: [String: Any] = [
            "schemaVersion": 1,
            "records": [[
                "appId": identity.appId,
                "projectId": identity.projectId,
                "capability": NativePermissionCapability.camera,
                "decision": "granted",
                "note": "a field this store never wrote",
            ]],
        ]
        try JSONSerialization.data(withJSONObject: handEdited, options: [.sortedKeys]).write(to: fixture.storeFileURL, options: [.atomic])

        XCTAssertEqual(fixture.makeStore().decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)
    }

    func testOversizedStoreIsRejectedBeforeDecode() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        let tooLarge = Data(repeating: 0x61, count: 256 * 1024 + 1)
        try tooLarge.write(to: fixture.storeFileURL, options: [.atomic])

        XCTAssertEqual(fixture.makeStore().decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)
    }

    // MARK: Revocation

    func testRevokingResetsToNotDecidedAndHoldsAcrossRestart() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")

        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)
        try fixture.makeStore().forgetDecision(for: NativePermissionCapability.camera, identity: identity)

        let afterRevoke = fixture.makeStore()
        XCTAssertEqual(afterRevoke.decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)

        // The revoked app must genuinely be asked again on its next request,
        // not silently re-granted by some leftover in-memory state.
        XCTAssertEqual(afterRevoke.decision(for: NativePermissionCapability.camera, identity: identity), .notDecided)
    }

    func testDecidedCapabilitiesListsOnlyThisAppsActualDecisions() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        let otherApp = try NativeShellAppIdentity(appId: "iris.nut-ai", projectId: "iris.nut-ai.mobile")

        let store = fixture.makeStore()
        try store.setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)
        try store.setDecision(.denied, for: "web.media.camera-plus-face-model", identity: identity)
        try store.setDecision(.granted, for: NativePermissionCapability.camera, identity: otherApp)

        let listed = fixture.makeStore().decidedCapabilities(for: identity)
        XCTAssertEqual(listed.count, 2, "the list must show exactly this app's two decided capabilities, not the other app's")
        XCTAssertEqual(listed.first(where: { $0.capability == NativePermissionCapability.camera })?.decision, .granted)
        XCTAssertEqual(listed.first(where: { $0.capability == "web.media.camera-plus-face-model" })?.decision, .denied)
    }

    // MARK: Identity validation

    func testUnstableIdentityIsRejectedRatherThanSilentlyStored() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let unstable = NativeShellAppIdentity(appId: "Not Allowed", projectId: "ok.project")
        XCTAssertThrowsError(
            try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: unstable)
        ) { error in
            XCTAssertEqual(error as? NativePermissionStoreError, .invalidIdentity)
        }
    }

    func testStoredFileNeverContainsFieldsBeyondItsOwnStrictSchema() throws {
        let fixture = try PermissionFixture()
        defer { fixture.cleanup() }
        let identity = try NativeShellAppIdentity(appId: "iris.kneecap", projectId: "iris.kneecap.mobile")
        try fixture.makeStore().setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)

        let raw = try String(contentsOf: fixture.storeFileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"granted\""))
        XCTAssertFalse(raw.contains("notDecided"), "a `.notDecided` row is never written; absence of a row means notDecided")
    }
}

private final class PermissionFixture {
    let root: URL
    let permissionsRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-native-permission-tests-\(UUID().uuidString)", isDirectory: true)
        permissionsRoot = root.appendingPathComponent("permissions-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storeFileURL: URL {
        permissionsRoot.appendingPathComponent("permissions-v1.json", isDirectory: false)
    }

    /// A fresh `NativePermissionStore` built from the same disk root, the
    /// same thing a relaunch of the Iris app would do.
    func makeStore() -> NativePermissionStore {
        NativePermissionStore(rootURL: permissionsRoot)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
