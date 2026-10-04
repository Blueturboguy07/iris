import Foundation
import IrisMobileShellCore

/// PLAN.md Phase 0 acceptance S0: "Airplane mode, then open an installed app:
/// it opens." Installs while healthy, then flips the device world fully
/// offline and opens the already-installed app directly through the
/// coordinator (the Library/Home Screen path, not a website link, which
/// legitimately does need the catalog). Zero network requests must happen
/// during the offline open.
public final class AirplaneModeOpenScenario: MobileScenario {
    public let id = "airplane-mode-open"
    public let title = "Airplane mode then open an installed app works"
    public let seedString = "airplane-mode-open"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p3EdgeUser]

    private let appId = "publik.airplaneapp"
    private let projectId = "publik.airplaneapp.mobile"
    private let package: GeneratedPackage

    public init(scratchRoot: URL) throws {
        package = try PackageFixture.generate(
            content: TestContent.html("airplane-v1"),
            nonce: String(repeating: "2", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Airplane App",
            workDirectory: scratchRoot.appendingPathComponent("airplane-mode-open/gen-0", isDirectory: true)
        )
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)

        // P3 starts offline in this scenario's own persona defaults; make the
        // install phase itself deterministic and network-independent of the
        // persona's starting condition by explicitly going healthy first.
        env.world.setNetwork(.healthy)
        let review = try await env.coordinator.reviewImport(packageBytes: package.bytes)
        _ = try await env.coordinator.approvePendingReviewLocallyAndStage(
            reviewToken: review.reviewToken,
            packageSHA256: review.packageSHA256
        )
        try await env.coordinator.activate(identity: identity, revisionId: package.revisionId)

        // Airplane mode.
        env.world.setNetwork(.offline)
        let requestsBeforeOpen = env.world.totalNetworkRequests()

        let launch = try await env.coordinator.launchActive(identity: identity)
        let requestsAfterOpen = env.world.totalNetworkRequests()

        try Oracle.requireEqual(
            launch.launchedRevisionId, package.revisionId, "airplane-open-correct-revision", failureClass: .hostSide
        )
        try Oracle.require(
            !launch.didFallback, "airplane-open-no-fallback", "opening offline unexpectedly fell back to another revision",
            failureClass: .hostSide
        )
        try Oracle.requireEqual(
            requestsAfterOpen, requestsBeforeOpen, "airplane-open-made-no-network-request",
            failureClass: .hostSide
        )

        let openedContent = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(openedContent, "airplane-v1"),
            "airplane-open-real-content", "entrypoint did not contain the expected marker",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Airplane App opened while offline with zero additional network requests.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Airplane App is open.",
                knewWhatToDoNext: true
            ),
            evidence: ["networkRequestsDuringOpen": String(requestsAfterOpen - requestsBeforeOpen)]
        )
    }
}
