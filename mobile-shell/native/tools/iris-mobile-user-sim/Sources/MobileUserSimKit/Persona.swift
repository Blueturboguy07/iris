import Foundation
import IrisMobileShellCore

/// Simulated phone people. Mirrors the desktop harness's `Persona` shape
/// (tools/iris-user-sim/Sources/UserSimKit/Persona.swift) but keeps its own
/// definition: this package must not modify or import that tool.
///
/// Every field here is drawn from the owner-approved mobile plan, section 4
/// ("Personas used in every phase") and section 7 ("Edge cases to keep in the
/// tests"): docs/plans/20260926-feature-streams/s6-mobile/PLAN.md.
public struct MobilePersona: Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String

    /// How many confusing moments this person tolerates before giving up.
    /// P1 in the plan: "gives up after two confusing screens."
    public let patience: Int

    /// Taps the very first big, obvious control rather than reading choices.
    public let tapsFirstBigButton: Bool

    /// Double-taps controls instead of a single deliberate tap.
    public let doubleTaps: Bool

    /// Backgrounds or force-quits the app mid-operation instead of waiting.
    public let interruptsMidOperation: Bool

    /// Simulated OS version this persona's device runs.
    public let osVersion: SimulatedOSVersion

    /// Starting network condition this persona's device is in.
    public let startingNetwork: SimulatedNetworkCondition

    /// Starting free storage, in bytes, on this persona's device.
    public let startingFreeStorageBytes: Int

    public init(
        id: String,
        displayName: String,
        patience: Int,
        tapsFirstBigButton: Bool,
        doubleTaps: Bool,
        interruptsMidOperation: Bool,
        osVersion: SimulatedOSVersion,
        startingNetwork: SimulatedNetworkCondition,
        startingFreeStorageBytes: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.patience = patience
        self.tapsFirstBigButton = tapsFirstBigButton
        self.doubleTaps = doubleTaps
        self.interruptsMidOperation = interruptsMidOperation
        self.osVersion = osVersion
        self.startingNetwork = startingNetwork
        self.startingFreeStorageBytes = startingFreeStorageBytes
    }
}

/// The OS-version axis the plan cares about: iOS 17.x only ever grants
/// `web.storage` (`NativeWebStorageConfiguration.capabilityPolicy`, read at
/// mobile-shell/native/Sources/IrisMobileShellHost/NativeWebStorageConfiguration.swift:27-29),
/// so media capabilities are always unsupported there. iOS 18.4+ also grants
/// photo-picker, export and (with the camera usage string) camera.
public enum SimulatedOSVersion: String, Sendable, Equatable, Hashable, CaseIterable {
    case ios17
    case ios18_4Plus

    /// Mirrors `NativeWebStorageConfiguration.capabilityPolicy` for this OS
    /// version exactly (same supported-capability sets), without depending on
    /// the Host target (which needs WebKit and #available gates this harness
    /// cannot exercise from a plain SwiftPM/macOS test process). Any drift
    /// between this table and the real Host policy is exactly what
    /// INTEGRATION_HOOKS.md flags for the integrator to re-check.
    public var mirroredHostCapabilityPolicy: CapabilityPolicy {
        switch self {
        case .ios17:
            return CapabilityPolicy(supportedCapabilities: ["web.storage"])
        case .ios18_4Plus:
            return CapabilityPolicy(supportedCapabilities: [
                "web.storage", "web.media.photo-picker", "web.media.export",
            ])
        }
    }

    public var plainLanguageName: String {
        switch self {
        case .ios17: return "iOS 17"
        case .ios18_4Plus: return "iOS 18.4 or later"
        }
    }
}

/// The network axis: healthy, fully offline (airplane mode), slow, flaky, and
/// the two catalog-shape problems named in the plan ("a catalog that is
/// missing or stale," section 7).
public enum SimulatedNetworkCondition: Sendable, Equatable, Hashable {
    case healthy
    case offline
    case slow(extraLatencySeconds: Double)
    case flaky(failureRate: Double)
    case catalogEmpty
    case catalogStale
}

/// Built-in personas from the plan (section 4). Ids are stable strings used
/// as report keys and seed-derivation inputs, so do not rename them.
public enum MobileBuiltInPersonas {
    /// P1: non-technical. Vague words, taps the first big button, gives up
    /// after two confusing screens.
    public static let p1NonTechnical = MobilePersona(
        id: "p1-nontechnical",
        displayName: "P1 non-technical",
        patience: 2,
        tapsFirstBigButton: true,
        doubleTaps: false,
        interruptsMidOperation: false,
        osVersion: .ios18_4Plus,
        startingNetwork: .healthy,
        startingFreeStorageBytes: 8 * 1024 * 1024 * 1024
    )

    /// P2: hurried power user. Double-taps, backgrounds the app mid-install,
    /// expects instant reopen.
    public static let p2HurriedPowerUser = MobilePersona(
        id: "p2-hurried",
        displayName: "P2 hurried power user",
        patience: 5,
        tapsFirstBigButton: false,
        doubleTaps: true,
        interruptsMidOperation: true,
        osVersion: .ios18_4Plus,
        startingNetwork: .healthy,
        startingFreeStorageBytes: 4 * 1024 * 1024 * 1024
    )

    /// P3: edge user. Airplane mode, low storage, force-quit mid-update, an
    /// older iOS (17.x, storage only).
    public static let p3EdgeUser = MobilePersona(
        id: "p3-edge",
        displayName: "P3 edge user",
        patience: 1,
        tapsFirstBigButton: false,
        doubleTaps: true,
        interruptsMidOperation: true,
        osVersion: .ios17,
        startingNetwork: .offline,
        startingFreeStorageBytes: 200 * 1024 * 1024
    )

    public static let all: [MobilePersona] = [p1NonTechnical, p2HurriedPowerUser, p3EdgeUser]
}
