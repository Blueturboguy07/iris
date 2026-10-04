import Foundation
import IrisMobileShellCore

/// PLAN.md Phase 1 acceptance: "P3 fills storage to under 500 MB free and
/// tries an app update: it is refused clearly and the old version still
/// opens." Installs v1 normally, then arms the simulated device's free
/// storage below what v2 needs and attempts the real stage call. See
/// `LowStorageFileManager` for exactly what is and is not faked here.
public final class LowStorageUpdateScenario: MobileScenario {
    public let id = "low-storage-update-refused"
    public let title = "Low storage update is refused; old version still opens"
    public let seedString = "low-storage-update-refused"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p3EdgeUser]

    private let appId = "publik.lowstorageapp"
    private let projectId = "publik.lowstorageapp.mobile"
    private let v1: GeneratedPackage
    private let v2: GeneratedPackage

    public init(scratchRoot: URL) throws {
        let root = scratchRoot.appendingPathComponent("low-storage-update", isDirectory: true)
        v1 = try PackageFixture.generate(
            content: TestContent.html("low-storage-v1"),
            nonce: String(repeating: "5", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Low Storage App",
            workDirectory: root.appendingPathComponent("gen-0", isDirectory: true)
        )
        v2 = try PackageFixture.generate(
            // Padded so this revision plainly needs more bytes than the
            // simulated free space below, without relying on exact byte math.
            content: TestContent.html("low-storage-v2") + "<!--\(String(repeating: "x", count: 4096))-->",
            baseRevisionId: v1.revisionId,
            nonce: String(repeating: "5", count: 63) + "1",
            appId: appId,
            projectId: projectId,
            displayName: "Low Storage App",
            workDirectory: root.appendingPathComponent("gen-1", isDirectory: true)
        )
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        // Plenty of room for v1's install.
        env.world.setFreeStorageBytes(500 * 1024 * 1024)
        let firstReview = try await env.coordinator.reviewImport(packageBytes: v1.bytes)
        _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: firstReview.reviewToken,
            packageSHA256: firstReview.packageSHA256
        )
        try await env.coordinator.activate(identity: identity, revisionId: v1.revisionId)

        // Fill the device until under 500 MB free, per the plan's own P3
        // acceptance number, and well under what v2 needs.
        let freeBytesBefore = 1024
        env.world.setFreeStorageBytes(freeBytesBefore)
        env.lowStorageFileManager.armNextStagingWrite(label: "v2-stage", requestedBytes: v2.bytes.count)

        let secondReview = try await env.coordinator.reviewImport(packageBytes: v2.bytes, expectedIdentity: identity)
        var thrown: Error?
        do {
            _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: secondReview.reviewToken,
                packageSHA256: secondReview.packageSHA256
            )
        } catch {
            thrown = error
        }

        guard let thrown else {
            throw OracleFailure(
                "low-storage-update-must-be-refused",
                "staging v2 succeeded even though the simulated device had \(freeBytesBefore) bytes free and v2 needs \(v2.bytes.count)",
                failureClass: .hostSide
            )
        }
        let nsError = thrown as NSError
        try Oracle.require(
            nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError,
            "low-storage-update-refusal-reason",
            "expected an out-of-space write failure, got \(thrown)",
            failureClass: .hostSide
        )

        let attempts = env.world.storageWriteAttemptLog()
        try Oracle.require(
            attempts.contains { $0.label == "v2-stage" && !$0.granted },
            "low-storage-write-attempt-recorded-denied",
            "expected a denied storage-write attempt for v2-stage, log was \(attempts)",
            failureClass: .setupPackaging
        )
        try Oracle.requireEqual(
            env.world.currentFreeStorageBytes(), freeBytesBefore,
            "low-storage-denied-write-did-not-consume-space", failureClass: .setupPackaging
        )

        // Ground truth: v1 is still the only stored revision, and it opens.
        let library = try await env.coordinator.refreshLibrary()
        try Oracle.requireEqual(library.count, 1, "low-storage-library-unchanged-count", failureClass: .hostSide)
        let entry = library[0]
        try Oracle.requireEqual(entry.currentRevisionId, v1.revisionId, "low-storage-v1-still-active", failureClass: .hostSide)
        try Oracle.requireEqual(entry.revisions.count, 1, "low-storage-no-partial-revision-left-behind", failureClass: .hostSide)

        let launch = try await env.coordinator.launchActive(identity: identity)
        let content = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(content, "low-storage-v1"),
            "low-storage-old-version-opens", "v1 did not open correctly after the refused low-storage update",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "The update was refused for low storage; no partial revision was left behind and v1 still opens.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Not enough storage to update Low Storage App right now.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "freeBytesAtDenial": String(freeBytesBefore),
                "v2NeededBytes": String(v2.bytes.count),
            ]
        )
    }
}
