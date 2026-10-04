import Foundation
import IrisMobileShellCore

/// PLAN.md section 7 edge case: "A wrong-base update." Installs v1, then
/// attempts to stage a package whose declared `baseRevisionId` points at a
/// different, unrelated real revision rather than v1 (the currently active
/// one). Real `NativeRevisionStore.validateDelivery` must refuse this with
/// `.baseMismatch` before writing anything, and the active revision must
/// stay v1.
public final class WrongBaseUpdateScenario: MobileScenario {
    public let id = "wrong-base-update"
    public let title = "Wrong-base update is refused"
    public let seedString = "wrong-base-update"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    private let appId = "publik.wrongbaseapp"
    private let projectId = "publik.wrongbaseapp.mobile"
    private let v1: GeneratedPackage
    private let decoy: GeneratedPackage
    private let wrongBaseUpdate: GeneratedPackage

    public init(scratchRoot: URL) throws {
        let root = scratchRoot.appendingPathComponent("wrong-base-update", isDirectory: true)
        v1 = try PackageFixture.generate(
            content: TestContent.html("wrong-base-v1"),
            nonce: String(repeating: "3", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Wrong Base App",
            workDirectory: root.appendingPathComponent("gen-0", isDirectory: true)
        )
        // An unrelated real revision, generated only to harvest a real,
        // validator-shaped revision id that is not v1's.
        decoy = try PackageFixture.generate(
            content: TestContent.html("wrong-base-decoy"),
            nonce: String(repeating: "3", count: 63) + "1",
            appId: appId,
            projectId: projectId,
            displayName: "Wrong Base App",
            workDirectory: root.appendingPathComponent("gen-1", isDirectory: true)
        )
        wrongBaseUpdate = try PackageFixture.generate(
            content: TestContent.html("wrong-base-v2-attempt"),
            baseRevisionId: decoy.revisionId,
            nonce: String(repeating: "3", count: 63) + "2",
            appId: appId,
            projectId: projectId,
            displayName: "Wrong Base App",
            workDirectory: root.appendingPathComponent("gen-2", isDirectory: true)
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

        let wrongReview = try await env.coordinator.reviewImport(
            packageBytes: wrongBaseUpdate.bytes,
            expectedIdentity: identity
        )

        var thrown: Error?
        do {
            _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
                reviewToken: wrongReview.reviewToken,
                packageSHA256: wrongReview.packageSHA256
            )
        } catch {
            thrown = error
        }

        guard let thrown else {
            throw OracleFailure(
                "wrong-base-update-must-be-refused",
                "staging a package whose base does not match the active revision unexpectedly succeeded",
                failureClass: .appSide
            )
        }
        guard let shellError = thrown as? NativeShellError,
              shellError == .baseMismatch(expected: v1.revisionId, actual: decoy.revisionId) else {
            throw OracleFailure(
                "wrong-base-update-refusal-reason",
                "expected NativeShellError.baseMismatch(expected: v1, actual: decoy), got \(thrown)",
                failureClass: .appSide
            )
        }

        let library = try await env.coordinator.refreshLibrary()
        try Oracle.requireEqual(library.count, 1, "wrong-base-update-library-unchanged-count", failureClass: .hostSide)
        let entry = library[0]
        try Oracle.requireEqual(entry.currentRevisionId, v1.revisionId, "wrong-base-update-still-v1-active", failureClass: .hostSide)
        try Oracle.requireEqual(entry.revisions.count, 1, "wrong-base-update-no-partial-revision-written", failureClass: .hostSide)

        let launch = try await env.coordinator.launchActive(identity: identity)
        let content = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(content, "wrong-base-v1"),
            "wrong-base-update-v1-still-opens", "v1 no longer opens correctly after the refused update attempt",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "A wrong-base update package was refused before any bytes were written; v1 remains active and opens.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Wrong Base App is unchanged and still open.",
                knewWhatToDoNext: true
            ),
            evidence: ["thrownError": String(describing: thrown)]
        )
    }
}
