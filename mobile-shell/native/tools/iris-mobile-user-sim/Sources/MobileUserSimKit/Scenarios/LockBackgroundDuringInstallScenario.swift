import Foundation
import IrisMobileShellCore

/// SPEC.md R7.4 lifecycle item: "lock or background during export or
/// install." This scenario covers the install half (export is a Kneecap
/// capture concern, out of this unit's owned path).
///
/// Real production code exercised: `NativeWebsiteInstallFlow.prepare(url:)`
/// (which performs the actual catalog fetch and package download before
/// ever asking for consent) and `NativeWebsiteInstallFlow.retry()`, exactly
/// the API a real Host would call when a person reopens Iris after a
/// download was interrupted. Sim-only: the moment iOS would suspend network
/// activity for a backgrounded app is modeled by flipping `DeviceWorld` to
/// `.offline` from inside the flow's own `progress` callback, right as it
/// reports `.downloading` (the same hook point a real Host's progress
/// handler would see, not a delay guessed from outside).
public final class LockBackgroundDuringInstallScenario: MobileScenario {
    public let id = "lock-background-during-install"
    public let title = "Locking or backgrounding during install recovers on reopen"
    public let seedString = "lock-background-during-install"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    private let slug = "lockbg-app"
    private let appId = "publik.lockbgapp"
    private let projectId = "publik.lockbgapp.mobile"
    private let package: GeneratedPackage
    private let downloadURL: URL

    public init(scratchRoot: URL) throws {
        package = try PackageFixture.generate(
            content: TestContent.html("lockbg-v1"),
            nonce: String(repeating: "7", count: 63) + "0",
            appId: appId,
            projectId: projectId,
            displayName: "Lock Background App",
            workDirectory: scratchRoot.appendingPathComponent("lock-background-during-install/gen-0", isDirectory: true)
        )
        downloadURL = CatalogFixture.downloadURL(slug: slug, revisionId: package.revisionId)
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let catalogApp = CatalogFixtureApp(slug: slug, name: "Lock Background App", package: package, downloadURL: downloadURL)
        env.transport.setLiveCatalog(CatalogFixture.envelope(apps: [catalogApp]))
        env.transport.registerPackage(at: downloadURL, bytes: package.bytes)
        env.world.setNetwork(.healthy)

        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let intentURL = URL(string: "iris-apps://install/\(slug)")!

        // First attempt: the person locks the phone (or backgrounds Iris)
        // right as the download starts. Real iOS suspends network activity
        // for a backgrounded app almost immediately, so the in-flight GET
        // fails with the same error `FakeMobileTransport` produces for
        // `.offline`.
        var firstAttemptFailed = false
        let world = env.world
        do {
            _ = try await env.installFlow.prepare(url: intentURL) { progress in
                if case .downloading = progress {
                    world.setNetwork(.offline)
                    world.record("simulated-lock-or-background", "network suspended mid-download")
                }
            }
        } catch {
            firstAttemptFailed = true
            world.record("first-prepare-failed", "\(error)")
        }
        try Oracle.require(
            firstAttemptFailed, "lockbg-first-attempt-fails-while-suspended",
            "expected prepare(url:) to fail once the world went offline mid-download, but it returned normally",
            failureClass: .hostSide
        )
        try Oracle.require(
            env.world.hasEvent("network-request-failed"),
            "lockbg-transport-saw-the-drop",
            "device world's own event log has no network-request-failed entry after the simulated lock/background",
            failureClass: .hostSide
        )

        // The person unlocks the phone / brings Iris back to the foreground:
        // network returns.
        env.world.setNetwork(.healthy)
        env.world.record("simulated-unlock-or-foreground", "network restored")

        let preparation = try await env.installFlow.retry()
        guard case .consentRequired(let review) = preparation else {
            throw OracleFailure(
                "lockbg-retry-unexpected-preparation",
                "expected consentRequired on retry after reconnecting, got \(preparation)",
                failureClass: .hostSide
            )
        }
        _ = try await env.installFlow.installAndOpen(consentToken: review.consentToken)

        // Ground truth: the coordinator's own durable library state, read
        // fresh, not either flow call's in-memory return value. Exactly one
        // entry, exactly one stored revision: the interrupted first attempt
        // must not have left a corrupted or duplicate partial install.
        let library = try await env.coordinator.refreshLibrary()
        try Oracle.requireEqual(library.count, 1, "lockbg-one-library-entry-after-recovery", failureClass: .hostSide)
        let entry = library[0]
        try Oracle.requireEqual(entry.currentRevisionId, package.revisionId, "lockbg-current-revision-correct", failureClass: .hostSide)
        try Oracle.requireEqual(entry.revisions.count, 1, "lockbg-exactly-one-revision-on-disk", failureClass: .hostSide)

        let launch = try await env.coordinator.launchActive(identity: identity)
        let openedContent = try String(contentsOf: launch.launch.entrypointURL, encoding: .utf8)
        try Oracle.require(
            TestContent.containsMarker(openedContent, "lockbg-v1"),
            "lockbg-opens-real-content-after-recovery", "entrypoint did not contain the expected marker after recovery",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Locking mid-download failed the install honestly; reopening and retrying finished it once, cleanly.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Lock Background App is open.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "revisionId": entry.currentRevisionId ?? "nil",
                "revisionsOnDisk": String(entry.revisions.count),
            ]
        )
    }
}
