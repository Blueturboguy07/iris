import Foundation
import IrisMobileShellCore

/// M5 brief, store world, scenario 2: "P2 double-taps Get (exactly one
/// install)", at the 1,000-app scale point, so the double-tap guard is
/// proven with real 1,000-row catalog decode overhead in the path, not just
/// at the 1-2 row catalogs the base harness's `DoubleTapInstallScenario`
/// (which this scenario deliberately does not duplicate the assertions of,
/// only the concurrency technique) already covers.
public final class StoreDoubleTapGetAtScaleScenario: MobileScenario {
    public let id = "store-double-tap-get-at-scale"
    public let title = "Double-tapped Get in a 1,000-app catalog installs exactly once"
    public let seedString = "store-double-tap-get-at-scale"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    public static let appCount = 1000

    private let slug = "store-scale-doubletap-sim"
    private let appId = "publik.storescaledoubletap"
    private let projectId = "publik.storescaledoubletap.mobile"
    private let package: GeneratedPackage
    private let downloadURL: URL
    private let decoyRows: [StoreScaleCatalogFixture.Row]

    public init(scratchRoot: URL) throws {
        package = try PackageFixture.generate(
            content: TestContent.html("store-double-tap-at-scale-v1"),
            nonce: String(repeating: "3", count: 60) + "dtap",
            appId: appId,
            projectId: projectId,
            displayName: "Store Scale Double Tap App",
            workDirectory: scratchRoot.appendingPathComponent("store-double-tap-at-scale/gen-0", isDirectory: true)
        )
        downloadURL = CatalogFixture.downloadURL(slug: slug, revisionId: package.revisionId)
        decoyRows = StoreScaleCatalogFixture.syntheticRows(count: Self.appCount - 1, seed: 0x5_57_a1_e)
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let targetRow = StoreScaleCatalogFixture.realRow(slug: slug, name: "Store Scale Double Tap App", package: package, downloadURL: downloadURL)
        var allRows = decoyRows
        allRows.append(targetRow)
        env.transport.setLiveCatalog(StoreScaleCatalogFixture.envelope(rows: allRows))
        env.transport.registerPackage(at: downloadURL, bytes: package.bytes)

        let apps = try await env.catalogClient.fetchCatalog()
        try Oracle.requireEqual(apps.count, Self.appCount, "store-scale-double-tap-catalog-decodes-full-count", failureClass: .setupPackaging)

        let intentURL = URL(string: "iris-apps://install/\(slug)")!
        let preparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let review) = preparation else {
            throw OracleFailure(
                "unexpected-preparation",
                "expected consentRequired for a first install, got \(preparation)",
                failureClass: .hostSide
            )
        }

        let jitterNanoseconds = UInt64(rng.nextUnitDouble() * 4_000_000)
        let flow = env.installFlow
        let token = review.consentToken

        async let firstTap = Self.tap(flow: flow, token: token, afterNanoseconds: 0)
        async let secondTap = Self.tap(flow: flow, token: token, afterNanoseconds: jitterNanoseconds)
        let results = await [firstTap, secondTap]

        let successes = results.compactMap { try? $0.get() }
        try Oracle.requireEqual(successes.count, 1, "store-scale-double-tap-installs-exactly-once", failureClass: .hostSide)

        // Ground truth: the coordinator's own durable library state, read
        // fresh, not either tap's in-memory return value.
        let library = try await env.coordinator.refreshLibrary()
        let matchingEntries = library.filter { $0.currentRevisionId == package.revisionId }
        try Oracle.requireEqual(matchingEntries.count, 1, "store-scale-double-tap-one-library-entry", failureClass: .hostSide)

        return ScenarioOutcome(
            passed: true,
            message: "Two concurrent Get taps against a 1,000-app catalog installed the app exactly once.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Store Scale Double Tap App is open.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "appCount": String(Self.appCount),
                "successfulTaps": String(successes.count),
            ]
        )
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
