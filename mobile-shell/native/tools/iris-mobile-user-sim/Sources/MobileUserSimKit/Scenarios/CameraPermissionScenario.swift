import Foundation
import IrisMobileShellCore

/// SPEC.md R7.4 lifecycle item: "camera denied then allowed in Settings."
///
/// Real production code exercised: `NativePermissionStore` (Core), exactly
/// as a real Host would use it: one instance per process, backed by a JSON
/// file under the app's own container. A denial and a later grant must both
/// survive a relaunch (a fresh in-memory `NativePermissionStore` instance
/// over the same durable root, the same "relaunch" technique
/// `ForceQuitRecoveryScenario` uses for the library coordinator), and the
/// persisted file must fail closed to `.notDecided` if it is ever corrupted
/// rather than silently reading back as `.granted`
/// (`NativePermissionStore.swift`'s own documented guarantee).
///
/// This does not exercise the Host-level "ask before first use" enforcement
/// around the camera capability (`NativeMediaPermissionPolicy`, in
/// `IrisMobileShellHost`, a phone-fix-in-flight file this unit must not
/// touch and which this sim-harness's Core-only dependency cannot reach
/// anyway): only the durable decision store itself.
public final class CameraPermissionScenario: MobileScenario {
    public let id = "camera-denied-then-allowed"
    public let title = "Camera denied then allowed in Settings persists correctly"
    public let seedString = "camera-denied-then-allowed"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical]

    private let appId = "publik.cameraapp"
    private let projectId = "publik.cameraapp.mobile"

    public init(scratchRoot: URL) throws {}

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let permissionsRoot = env.rootURL.appendingPathComponent("camera-permission-store", isDirectory: true)
        try FileManager.default.createDirectory(at: permissionsRoot, withIntermediateDirectories: true)

        // The person is asked and says no.
        let firstStore = NativePermissionStore(rootURL: permissionsRoot)
        let deniedResult = try firstStore.setDecision(.denied, for: NativePermissionCapability.camera, identity: identity)
        try Oracle.requireEqual(deniedResult, .denied, "camera-deny-recorded", failureClass: .hostSide)
        env.world.record("camera-permission-denied")

        // Relaunch: a fresh in-memory store over the same durable root.
        let storeAfterDenyRelaunch = NativePermissionStore(rootURL: permissionsRoot)
        try Oracle.requireEqual(
            storeAfterDenyRelaunch.decision(for: NativePermissionCapability.camera, identity: identity),
            .denied, "camera-deny-survives-relaunch", failureClass: .hostSide
        )

        // The person goes to Settings and allows it.
        let grantedResult = try storeAfterDenyRelaunch.setDecision(.granted, for: NativePermissionCapability.camera, identity: identity)
        try Oracle.requireEqual(grantedResult, .granted, "camera-grant-recorded", failureClass: .hostSide)
        env.world.record("camera-permission-granted-in-settings")

        // Relaunch again.
        let storeAfterGrantRelaunch = NativePermissionStore(rootURL: permissionsRoot)
        try Oracle.requireEqual(
            storeAfterGrantRelaunch.decision(for: NativePermissionCapability.camera, identity: identity),
            .granted, "camera-grant-survives-relaunch", failureClass: .hostSide
        )

        // Independent oracle: decode the on-disk JSON file directly, with
        // this scenario's own small Codable shape (not the store's private
        // `StoredFile`/`StoredRecord` types), so the check reads real bytes
        // on disk rather than trusting the store's own `decision(for:)`
        // report of itself.
        let fileURL = permissionsRoot.appendingPathComponent("permissions-v1.json", isDirectory: false)
        let onDiskData = try Data(contentsOf: fileURL)
        let onDiskFile = try JSONDecoder().decode(IndependentPermissionsFile.self, from: onDiskData)
        try Oracle.requireEqual(onDiskFile.schemaVersion, 1, "camera-file-schema-version", failureClass: .hostSide)
        guard let onDiskRecord = onDiskFile.records.first(where: {
            $0.appId == appId && $0.projectId == projectId && $0.capability == NativePermissionCapability.camera
        }) else {
            throw OracleFailure(
                "camera-file-has-record", "no record for \(appId)/\(projectId)/camera among \(onDiskFile.records.count) records",
                failureClass: .hostSide
            )
        }
        try Oracle.requireEqual(onDiskRecord.decision, "granted", "camera-file-on-disk-says-granted", failureClass: .hostSide)

        // Documented crash-safety guarantee: a corrupted file must fail
        // closed to `.notDecided`, never silently read back as `.granted`.
        try Data("{ this is not valid json".utf8).write(to: fileURL, options: [.atomic])
        let storeAfterCorruption = NativePermissionStore(rootURL: permissionsRoot)
        try Oracle.requireEqual(
            storeAfterCorruption.decision(for: NativePermissionCapability.camera, identity: identity),
            .notDecided, "camera-corrupted-file-fails-closed", failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Camera permission denied, then allowed in Settings, persisted correctly across relaunch; a corrupted store fails closed.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Camera App can now use the camera.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "finalDecisionOnDisk": onDiskRecord.decision,
            ]
        )
    }
}

private struct IndependentPermissionsFile: Decodable {
    let schemaVersion: Int
    let records: [IndependentPermissionRecord]
}

private struct IndependentPermissionRecord: Decodable {
    let appId: String
    let projectId: String
    let capability: String
    let decision: String
}
