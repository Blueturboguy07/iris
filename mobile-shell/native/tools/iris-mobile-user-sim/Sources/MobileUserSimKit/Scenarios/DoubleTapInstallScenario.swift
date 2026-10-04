import Foundation
import IrisMobileShellCore

/// PLAN.md Phase 0 acceptance S0: "P2 double-taps Install & Open, and exactly
/// one install happens." Fires two concurrent `installAndOpen` calls with the
/// SAME consent token, exactly as a real double tap would deliver two taps
/// before the button disables itself, then checks the coordinator's own
/// durable state (not either call's return value alone) for exactly one
/// installed revision.
public final class DoubleTapInstallScenario: MobileScenario {
    public let id = "double-tap-install"
    public let title = "Double-tapped Install & Open installs once"
    public let seedString = "double-tap-install"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    private let slug = "double-tap-app"
    private let appId = "publik.doubletapapp"
    private let projectId = "publik.doubletapapp.mobile"
    private let package: GeneratedPackage
    private let downloadURL: URL

    public init(scratchRoot: URL) throws {
        package = try PackageFixture.generate(
            content: TestContent.html("double-tap-v1"),
            nonce: Self.staticNonce(0),
            appId: appId,
            projectId: projectId,
            displayName: "Double Tap App",
            workDirectory: scratchRoot.appendingPathComponent("double-tap-install/gen-0", isDirectory: true)
        )
        downloadURL = CatalogFixture.downloadURL(slug: slug, revisionId: package.revisionId)
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let catalogApp = CatalogFixtureApp(slug: slug, name: "Double Tap App", package: package, downloadURL: downloadURL)
        env.transport.setLiveCatalog(CatalogFixture.envelope(apps: [catalogApp]))
        env.transport.registerPackage(at: downloadURL, bytes: package.bytes)

        let intentURL = URL(string: "iris-apps://install/\(slug)")!
        let preparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let review) = preparation else {
            throw OracleFailure(
                "unexpected-preparation",
                "expected consentRequired for a first install, got \(preparation)",
                failureClass: .hostSide
            )
        }

        // Vary the interleaving of the two taps across seeded runs without
        // making the outcome nondeterministic: a small, seed-derived jitter
        // before the second tap, both still fired before either completes.
        let jitterNanoseconds = UInt64(rng.nextUnitDouble() * 4_000_000)
        let flow = env.installFlow
        let token = review.consentToken

        async let firstTap = Self.tap(flow: flow, token: token, afterNanoseconds: 0)
        async let secondTap = Self.tap(flow: flow, token: token, afterNanoseconds: jitterNanoseconds)
        let results = await [firstTap, secondTap]
        try Oracle.require(
            results.count == 2, "tap-count", "expected exactly two recorded taps, got \(results.count)",
            failureClass: .setupPackaging
        )
        let successes = results.compactMap { try? $0.get() }
        try Oracle.requireEqual(successes.count, 1, "double-tap-installs-exactly-once", failureClass: .hostSide)

        let failures = results.filter { if case .failure = $0 { return true }; return false }
        try Oracle.requireEqual(failures.count, 1, "double-tap-second-tap-refused", failureClass: .hostSide)
        if case .failure(let error) = failures[0] {
            let isExpectedRefusal: Bool
            if let flowError = error as? NativeWebsiteInstallFlowError {
                isExpectedRefusal = flowError == .commitInProgress || flowError == .invalidConsentToken
            } else {
                isExpectedRefusal = false
            }
            try Oracle.require(
                isExpectedRefusal,
                "double-tap-second-tap-reason",
                "expected the losing tap to be refused as commitInProgress or invalidConsentToken, got \(error)",
                failureClass: .hostSide
            )
        }

        // Ground truth: the coordinator's own durable library state, read
        // fresh, not either call's in-memory return value.
        let library = try await env.coordinator.refreshLibrary()
        try Oracle.requireEqual(library.count, 1, "double-tap-one-library-entry", failureClass: .hostSide)
        let entry = library[0]
        try Oracle.requireEqual(entry.currentRevisionId, package.revisionId, "double-tap-current-revision", failureClass: .hostSide)
        try Oracle.requireEqual(entry.revisions.count, 1, "double-tap-one-revision-on-disk", failureClass: .hostSide)

        let launch = try await env.coordinator.launchActive(identity: catalogApp.package.identity)
        let openedContent = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(openedContent, "double-tap-v1"),
            "double-tap-opens-real-content", "entrypoint did not contain the expected marker",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Exactly one of two concurrent Install & Open taps installed the app; the library holds one revision.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Double Tap App is open.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "revisionId": entry.currentRevisionId ?? "nil",
                "revisionsOnDisk": String(entry.revisions.count),
            ]
        )
    }

    private static func staticNonce(_ index: Int) -> String {
        String(repeating: "1", count: 63) + String(index)
    }

    private static func tap(
        flow: NativeWebsiteInstallFlow,
        token: String,
        afterNanoseconds: UInt64
    ) async -> Result<NativeWebsiteInstallResult, Error> {
        if afterNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: afterNanoseconds)
        }
        do {
            let result = try await flow.installAndOpen(consentToken: token)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }
}

private extension GeneratedPackage {
    var identity: NativeShellAppIdentity {
        NativeShellAppIdentity(appId: appId, projectId: projectId)
    }
}
