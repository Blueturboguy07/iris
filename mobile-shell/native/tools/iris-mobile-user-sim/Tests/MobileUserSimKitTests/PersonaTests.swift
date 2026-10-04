import XCTest
import IrisMobileShellCore
@testable import MobileUserSimKit

final class PersonaTests: XCTestCase {
    func testBuiltInPersonasCoverThePlansThreePersonas() {
        let ids = Set(MobileBuiltInPersonas.all.map(\.id))
        XCTAssertEqual(ids, ["p1-nontechnical", "p2-hurried", "p3-edge"])
    }

    func testP3IsTheOnlyIOS17StartingOffline() {
        XCTAssertEqual(MobileBuiltInPersonas.p3EdgeUser.osVersion, .ios17)
        XCTAssertEqual(MobileBuiltInPersonas.p3EdgeUser.startingNetwork, .offline)
        XCTAssertEqual(MobileBuiltInPersonas.p1NonTechnical.osVersion, .ios18_4Plus)
        XCTAssertEqual(MobileBuiltInPersonas.p2HurriedPowerUser.osVersion, .ios18_4Plus)
    }

    /// This mirrors `NativeWebStorageConfiguration.capabilityPolicy`
    /// (mobile-shell/native/Sources/IrisMobileShellHost/NativeWebStorageConfiguration.swift:20-31)
    /// exactly. If that Host policy changes, this test's expectation and the
    /// mirror in `Persona.swift` both need a matching update, which
    /// INTEGRATION_HOOKS.md flags for the integrator.
    func testMirroredCapabilityPolicyMatchesRealHostPolicyByOSVersion() {
        XCTAssertEqual(SimulatedOSVersion.ios17.mirroredHostCapabilityPolicy.supportedCapabilities, ["web.storage"])
        XCTAssertEqual(
            SimulatedOSVersion.ios18_4Plus.mirroredHostCapabilityPolicy.supportedCapabilities,
            ["web.storage", "web.media.photo-picker", "web.media.export"]
        )
    }
}
