import Foundation
import IrisMobileShellCore

/// PLAN.md section 7 edge case: "A catalog that is missing or stale ... does
/// not downgrade." Installs v1, updates to v2 through the real website
/// install flow, then serves a STALE catalog snapshot (still advertising v1
/// as the app's package) and taps the website link again. The real
/// `NativeWebsiteInstallFlow` will download and try to stage the stale v1
/// package (since its currentRevisionId no longer matches the descriptor),
/// which the real `NativeRevisionStore` base-mismatch guard must refuse,
/// leaving v2 active.
public final class StaleCatalogScenario: MobileScenario {
    public let id = "stale-catalog-no-downgrade"
    public let title = "Stale catalog does not downgrade an installed app"
    public let seedString = "stale-catalog-no-downgrade"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p3EdgeUser]

    private let slug = "stale-catalog-app"
    private let appId = "publik.stalecatalogapp"
    private let projectId = "publik.stalecatalogapp.mobile"
    private let v1: GeneratedPackage
    private let v2: GeneratedPackage
    private let v1DownloadURL: URL
    private let v2DownloadURL: URL

    public init(scratchRoot: URL) throws {
        let root = scratchRoot.appendingPathComponent("stale-catalog", isDirectory: true)
        v1 = try PackageFixture.generate(
            content: TestContent.html("stale-catalog-v1"),
            nonce: String(repeating: "4", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Stale Catalog App",
            workDirectory: root.appendingPathComponent("gen-0", isDirectory: true)
        )
        v2 = try PackageFixture.generate(
            content: TestContent.html("stale-catalog-v2"),
            baseRevisionId: v1.revisionId,
            nonce: String(repeating: "4", count: 63) + "1",
            appId: appId,
            projectId: projectId,
            displayName: "Stale Catalog App",
            workDirectory: root.appendingPathComponent("gen-1", isDirectory: true)
        )
        v1DownloadURL = CatalogFixture.downloadURL(slug: slug, revisionId: v1.revisionId)
        v2DownloadURL = CatalogFixture.downloadURL(slug: slug, revisionId: v2.revisionId)
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        env.world.setNetwork(.healthy)

        let v1App = CatalogFixtureApp(slug: slug, name: "Stale Catalog App", package: v1, downloadURL: v1DownloadURL)
        let v2App = CatalogFixtureApp(slug: slug, name: "Stale Catalog App", package: v2, downloadURL: v2DownloadURL)
        env.transport.registerPackage(at: v1DownloadURL, bytes: v1.bytes)
        env.transport.registerPackage(at: v2DownloadURL, bytes: v2.bytes)

        // Fresh install of v1 through the website flow.
        let staleSnapshot = CatalogFixture.envelope(apps: [(app: v1App, baseRevisionId: nil)])
        env.transport.setLiveCatalog(staleSnapshot)
        env.transport.setStaleCatalog(staleSnapshot)

        let intentURL = URL(string: "iris-apps://install/\(slug)")!
        let firstPreparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let firstReview) = firstPreparation else {
            throw OracleFailure("stale-catalog-first-install-not-consent-required", "\(firstPreparation)", failureClass: .hostSide)
        }
        _ = try await env.installFlow.installAndOpen(consentToken: firstReview.consentToken)

        // Publish v2 as the live catalog and update to it. This is the
        // "current" catalog the moment the update succeeds.
        env.transport.setLiveCatalog(CatalogFixture.envelope(apps: [(app: v2App, baseRevisionId: v1.revisionId)]))
        let secondPreparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let secondReview) = secondPreparation else {
            throw OracleFailure("stale-catalog-update-not-consent-required", "\(secondPreparation)", failureClass: .hostSide)
        }
        _ = try await env.installFlow.installAndOpen(consentToken: secondReview.consentToken)

        let afterUpdate = try await env.coordinator.libraryEntry(identity: identity)
        try Oracle.requireEqual(afterUpdate?.currentRevisionId, v2.revisionId, "stale-catalog-v2-active-after-update", failureClass: .appSide)

        // Now the served catalog goes stale: it still points at v1, unaware
        // v2 was already installed. The user taps the same website link
        // again (a real, observed behavior: a cached app-store-style page,
        // or a stale CDN edge).
        env.world.setNetwork(.catalogStale)
        let stalePreparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let staleReview) = stalePreparation else {
            throw OracleFailure(
                "stale-catalog-third-tap-not-consent-required",
                "expected the stale descriptor (v1) to differ from the installed v2 and require review, got \(stalePreparation)",
                failureClass: .distribution
            )
        }
        try Oracle.requireEqual(staleReview.revisionId, v1.revisionId, "stale-catalog-offers-stale-revision", failureClass: .distribution)

        var thrown: Error?
        do {
            _ = try await env.installFlow.installAndOpen(consentToken: staleReview.consentToken)
        } catch {
            thrown = error
        }
        guard let thrown else {
            throw OracleFailure(
                "stale-catalog-downgrade-must-be-refused",
                "installAndOpen on a stale (older) catalog descriptor unexpectedly succeeded",
                failureClass: .appSide
            )
        }
        guard let shellError = thrown as? NativeShellError,
              shellError == .baseMismatch(expected: v2.revisionId, actual: nil) else {
            throw OracleFailure(
                "stale-catalog-downgrade-refusal-reason",
                "expected NativeShellError.baseMismatch(expected: v2, actual: v1's base), got \(thrown)",
                failureClass: .appSide
            )
        }

        // Ground truth: v2 is still active; nothing downgraded.
        let finalEntry = try await env.coordinator.libraryEntry(identity: identity)
        try Oracle.requireEqual(finalEntry?.currentRevisionId, v2.revisionId, "stale-catalog-still-v2-after-refusal", failureClass: .hostSide)

        let launch = try await env.coordinator.launchActive(identity: identity)
        let content = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(content, "stale-catalog-v2"),
            "stale-catalog-v2-still-opens", "v2 no longer opens correctly after the stale catalog's refused downgrade",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "A stale catalog snapshot could not downgrade the already-installed newer revision.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Stale Catalog App is already up to date.",
                knewWhatToDoNext: true
            ),
            evidence: ["activeRevision": finalEntry?.currentRevisionId ?? "nil"]
        )
    }
}
