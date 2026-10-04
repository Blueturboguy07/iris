import Foundation
import IrisMobileShellCore

/// M5 brief, store world, scenario 1: "P1 finds and installs a named app by
/// partial name (tap budget 4 or fewer, computed by the sim from the
/// navigation model)", run at 3, 100 and 1,000 apps (SPEC R8's three scale
/// points) so the catalog decode and interim-search path is proven at scale,
/// not just correctness at one size.
///
/// Real: `PublikMobileCatalogClient.fetchCatalog()` decode and per-field
/// validation over the full generated envelope; `NativeWebsiteInstallFlow`
/// prepare/consent/install; `NativeShellLibraryCoordinator.refreshLibrary()`
/// as the install oracle. Sim-only: `InterimCatalogSearch` (see that file's
/// doc comment) standing in for M2's `StoreSearchIndex`, which does not
/// exist yet.
public final class StoreFindAndInstallAtScaleScenario: MobileScenario {
    public let id: String
    public let title: String
    public let seedString: String
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p1NonTechnical]

    public let appCount: Int

    private let targetSlug = "publik-kneecap-sim"
    private let targetAppId = "publik.kneecap"
    private let targetProjectId = "publik.kneecap.mobile"
    private let targetDisplayName = "Kneecap"
    private let partialQuery = "Knee"

    private let package: GeneratedPackage
    private let downloadURL: URL
    private let decoyRows: [StoreScaleCatalogFixture.Row]

    public init(appCount: Int, scratchRoot: URL) throws {
        precondition(appCount >= 1, "appCount must be at least 1 (the real target row)")
        self.appCount = appCount
        self.id = "store-find-install-\(appCount)"
        self.title = "P1 finds and installs \"Kneecap\" by partial name at \(appCount) apps"
        self.seedString = "store-find-install-\(appCount)"

        package = try PackageFixture.generate(
            content: TestContent.html("store-find-install-\(appCount)-v1"),
            nonce: Self.staticNonce(appCount),
            appId: targetAppId,
            projectId: targetProjectId,
            displayName: targetDisplayName,
            workDirectory: scratchRoot.appendingPathComponent("store-find-install-\(appCount)/gen-0", isDirectory: true)
        )
        downloadURL = CatalogFixture.downloadURL(slug: targetSlug, revisionId: package.revisionId)

        let decoyCount = max(0, appCount - 1)
        var rows = StoreScaleCatalogFixture.syntheticRows(count: decoyCount, seed: 0x4b_ee_e5 &+ UInt64(appCount))
        // A deliberate near-miss so the search proves disambiguation: shares
        // the "Knee" prefix with the real target without being it.
        if decoyCount > 0 {
            rows[decoyCount / 2] = StoreScaleCatalogFixture.nearMissRow(slug: "kneepad-tracker-sim", name: "Kneepad Tracker")
        }
        decoyRows = rows
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        let targetRow = StoreScaleCatalogFixture.realRow(
            slug: targetSlug, name: targetDisplayName, package: package, downloadURL: downloadURL
        )
        // Insert the real row at a seed-derived position (not always index 0
        // or last) so search must actually scan a realistic spread, not
        // benefit from a fixed favorable position.
        let insertAt = decoyRows.isEmpty ? 0 : Int(rng.nextUnitDouble() * Double(decoyRows.count))
        var allRows = decoyRows
        allRows.insert(targetRow, at: min(insertAt, allRows.count))

        env.transport.setLiveCatalog(StoreScaleCatalogFixture.envelope(rows: allRows))
        env.transport.registerPackage(at: downloadURL, bytes: package.bytes)

        let decodeStart = Date()
        let apps = try await env.catalogClient.fetchCatalog()
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        try Oracle.requireEqual(apps.count, appCount, "store-scale-catalog-decodes-full-count", failureClass: .setupPackaging)

        let searchStart = Date()
        let matches = InterimCatalogSearch.search(partialQuery, in: apps)
        let searchSeconds = Date().timeIntervalSince(searchStart)

        // Independent oracle: a second, separately-implemented brute-force
        // scan must agree the target is findable, not just `search`'s own
        // ranked output.
        let bruteForceSlugs = InterimCatalogSearch.bruteForceContainingSlugs(partialQuery, in: apps)
        try Oracle.require(
            bruteForceSlugs.contains(targetSlug),
            "search-oracle-finds-target-independently",
            "independent brute-force scan over \(apps.count) rows did not contain \(targetSlug)",
            failureClass: .hostSide
        )
        guard let best = matches.first, best.app.slug == targetSlug else {
            throw OracleFailure(
                "search-ranks-target-first",
                "expected \(targetSlug) ranked first for query \"\(partialQuery)\" among \(matches.count) matches, got \(matches.first?.app.slug ?? "none")",
                failureClass: .hostSide
            )
        }

        let taps = StoreNavigationModel.findAndInstallTapCount
        try Oracle.require(
            taps <= 4, "tap-budget-4-or-fewer",
            "navigation model computed \(taps) taps for \(StoreNavigationModel.findAndInstallByPartialName.map(\.rawValue))",
            failureClass: .hostSide
        )

        let intentURL = URL(string: "iris-apps://install/\(targetSlug)")!
        let preparation = try await env.installFlow.prepare(url: intentURL)
        guard case .consentRequired(let review) = preparation else {
            throw OracleFailure(
                "unexpected-preparation",
                "expected consentRequired for a first install, got \(preparation)",
                failureClass: .hostSide
            )
        }
        _ = try await env.installFlow.installAndOpen(consentToken: review.consentToken)

        let library = try await env.coordinator.refreshLibrary()
        guard let entry = library.first(where: { $0.currentRevisionId == package.revisionId }) else {
            throw OracleFailure(
                "store-install-lands-in-library",
                "no library entry with revision \(package.revisionId) among \(library.count) entries",
                failureClass: .hostSide
            )
        }
        try Oracle.requireEqual(entry.currentRevisionId, package.revisionId, "store-installed-revision-matches", failureClass: .hostSide)

        return ScenarioOutcome(
            passed: true,
            message: "Found \"\(targetDisplayName)\" among \(appCount) apps by typing \"\(partialQuery)\" and installed it in \(taps) taps.",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Kneecap is open.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "appCount": String(appCount),
                "decodeMilliseconds": String(format: "%.3f", decodeSeconds * 1000),
                "interimSearchMilliseconds": String(format: "%.3f", searchSeconds * 1000),
                "taps": String(taps),
                "searchSeam": "InterimCatalogSearch (sim-only; pending M2 StoreSearchIndex)",
            ]
        )
    }

    private static func staticNonce(_ appCount: Int) -> String {
        String(repeating: "2", count: 58) + "find" + String(format: "%02d", appCount % 100)
    }
}
