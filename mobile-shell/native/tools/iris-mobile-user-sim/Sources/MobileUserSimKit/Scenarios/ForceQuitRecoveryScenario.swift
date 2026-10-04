import Foundation
import IrisMobileShellCore

/// PLAN.md section 7 edge case: "Force-quit between stage and activate."
/// `NativeRevisionStore.stage()` durably commits a revision's bytes to disk
/// (atomic move) before `activate()` ever runs; the active pointer is a
/// separate, later write. A force-quit in between means the process dies
/// with a fully staged-but-not-yet-active revision on disk. This scenario
/// stages v2 and deliberately never calls `activate`, simulating the kill,
/// then builds a brand-new `NativeShellLibraryCoordinator` over the SAME
/// on-disk root (an in-memory actor cannot survive a real kill, but a fresh
/// instance over durable disk state is the exact recovery a real relaunch
/// performs) and checks the app is still usable and the interrupted update
/// can be finished.
public final class ForceQuitRecoveryScenario: MobileScenario {
    public let id = "force-quit-stage-activate-recovers"
    public let title = "Force-quit between stage and activate recovers"
    public let seedString = "force-quit-stage-activate-recovers"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    private let appId = "publik.forcequitapp"
    private let projectId = "publik.forcequitapp.mobile"
    private let v1: GeneratedPackage
    private let v2: GeneratedPackage

    public init(scratchRoot: URL) throws {
        let root = scratchRoot.appendingPathComponent("force-quit-recovery", isDirectory: true)
        v1 = try PackageFixture.generate(
            content: TestContent.html("force-quit-v1"),
            nonce: String(repeating: "6", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Force Quit App",
            workDirectory: root.appendingPathComponent("gen-0", isDirectory: true)
        )
        v2 = try PackageFixture.generate(
            content: TestContent.html("force-quit-v2"),
            baseRevisionId: v1.revisionId,
            nonce: String(repeating: "6", count: 63) + "1",
            appId: appId,
            projectId: projectId,
            displayName: "Force Quit App",
            workDirectory: root.appendingPathComponent("gen-1", isDirectory: true)
        )
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        let firstReview = try await env.coordinator.reviewImport(packageBytes: v1.bytes)
        _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: firstReview.reviewToken,
            packageSHA256: firstReview.packageSHA256
        )
        try await env.coordinator.activate(identity: identity, revisionId: v1.revisionId)

        let secondReview = try await env.coordinator.reviewImport(packageBytes: v2.bytes, expectedIdentity: identity)
        let stageOutcome = try await env.coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: secondReview.reviewToken,
            packageSHA256: secondReview.packageSHA256
        )
        try Oracle.requireEqual(stageOutcome.revisionId, v2.revisionId, "force-quit-v2-staged-before-kill", failureClass: .setupPackaging)
        env.world.record("simulated-force-quit", "after stage, before activate")
        // Deliberately no activate(): this is the moment the app is killed.

        // "Relaunch": a fresh in-memory coordinator over the same durable
        // disk root, exactly as a fresh process start would construct one.
        let relaunchedCoordinator = NativeShellLibraryCoordinator(
            rootURL: env.libraryRootURL,
            capabilityPolicy: env.capabilityPolicy,
            fileManager: env.lowStorageFileManager
        )
        env.world.record("simulated-relaunch")

        let libraryAfterRelaunch = try await relaunchedCoordinator.refreshLibrary()
        try Oracle.requireEqual(libraryAfterRelaunch.count, 1, "force-quit-relaunch-one-library-entry", failureClass: .hostSide)
        let entryAfterRelaunch = libraryAfterRelaunch[0]
        try Oracle.requireEqual(
            entryAfterRelaunch.currentRevisionId, v1.revisionId,
            "force-quit-relaunch-still-on-old-version", failureClass: .hostSide
        )
        try Oracle.require(
            entryAfterRelaunch.stagedRevisions.map(\.revisionId) == [v2.revisionId],
            "force-quit-relaunch-sees-staged-v2",
            "expected v2 present as a staged (not active) revision, got \(entryAfterRelaunch.stagedRevisions.map(\.revisionId))",
            failureClass: .hostSide
        )

        // The app must still be usable right after the interrupted update:
        // opening it gives the old version, not a crash or an empty state.
        let launchOldVersion = try await relaunchedCoordinator.launchActive(identity: identity)
        let oldContent = try String(contentsOf: launchOldVersion.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(oldContent, "force-quit-v1"),
            "force-quit-old-version-opens-after-relaunch", "v1 did not open correctly right after the interrupted update",
            failureClass: .hostSide
        )

        // The interrupted update can be finished without re-downloading or
        // re-staging: activating the already-staged revision succeeds.
        try await relaunchedCoordinator.activate(identity: identity, revisionId: v2.revisionId)
        let launchNewVersion = try await relaunchedCoordinator.launchActive(identity: identity)
        let newContent = try String(contentsOf: launchNewVersion.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(newContent, "force-quit-v2"),
            "force-quit-interrupted-update-can-be-finished", "v2 did not open correctly after finishing the interrupted activation",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "A force-quit between stage and activate left v1 usable; relaunch recovered and the update could be finished.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Force Quit App is up to date.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "stagedRevisionAfterKill": stageOutcome.revisionId,
                "activeRevisionAfterRelaunch": entryAfterRelaunch.currentRevisionId ?? "nil",
            ]
        )
    }
}
