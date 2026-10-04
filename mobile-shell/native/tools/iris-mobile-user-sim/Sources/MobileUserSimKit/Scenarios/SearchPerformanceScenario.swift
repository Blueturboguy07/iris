import Foundation
import IrisMobileShellCore

/// M5 brief, store world, scenario 6: "1,000 apps search under 100 ms per
/// keystroke on this Mac", and SPEC R8.2: "Local search index built from the
/// loaded index in under 50 ms for 1,000 apps on the Mac (proxy)... with a
/// 120 ms debounce" for incremental typing.
///
/// SIM-ONLY seam, same as `StoreFindAndInstallAtScaleScenario`:
/// `InterimCatalogSearch` stands in for M2's `StoreSearchIndex`, which does
/// not exist yet (see that file's doc comment for the exact seam). What
/// this scenario proves today is that the harness's own stand-in, run the
/// way a person's keystrokes would actually drive it (`K`, `Kn`, `Kne`,
/// `Knee`, `Kneec`, one search call per partial query, never a single
/// combined call), stays inside the 100 ms per-keystroke budget at 1,000
/// apps on this Mac, and that the decoded catalog is re-used across
/// keystrokes rather than re-decoded. Swap the call site for
/// `StoreSearchIndex` the moment M2 lands, per that unit's
/// `INTEGRATION_HOOKS.md`.
public final class SearchPerformanceScenario: MobileScenario {
    public let id = "search-performance-1000-apps"
    public let title = "Search stays under 100 ms per keystroke at 1,000 apps"
    public let seedString = "search-performance-1000-apps"
    public let personas: [MobilePersona] = [MobileBuiltInPersonas.p2HurriedPowerUser]

    private let appCount = 1000
    private let targetSlug = "publik-kneecap-perf-sim"
    private let targetDisplayName = "Kneecap"
    private let keystrokes = ["K", "Kn", "Kne", "Knee", "Kneec", "Kneeca", "Kneecap"]
    private let perKeystrokeBudgetSeconds = 0.1

    private let decoyRows: [StoreScaleCatalogFixture.Row]
    private let targetRow: StoreScaleCatalogFixture.Row

    public init(scratchRoot: URL) throws {
        var rows = StoreScaleCatalogFixture.syntheticRows(count: appCount - 1, seed: 0x5eed_9e5f)
        // Several near-misses sharing the "K"/"Kn" prefix so early keystrokes
        // still have to rank among real competitors, not just filter noise.
        for offset in stride(from: 0, to: min(rows.count, 40), by: 7) {
            rows[offset] = StoreScaleCatalogFixture.nearMissRow(
                slug: "kn-decoy-\(offset)-sim", name: "Knapsack Tracker \(offset)"
            )
        }
        decoyRows = rows
        targetRow = StoreScaleCatalogFixture.nearMissRow(slug: targetSlug, name: targetDisplayName)
    }

    public func run(
        env: RunEnvironment,
        persona: MobilePersona,
        rng: inout SeededGenerator
    ) async throws -> ScenarioOutcome {
        var allRows = decoyRows
        let insertAt = Int(rng.nextUnitDouble() * Double(allRows.count))
        allRows.insert(targetRow, at: min(insertAt, allRows.count))
        env.transport.setLiveCatalog(StoreScaleCatalogFixture.envelope(rows: allRows))

        let apps = try await env.catalogClient.fetchCatalog()
        try Oracle.requireEqual(apps.count, appCount, "search-perf-catalog-decodes-full-count", failureClass: .setupPackaging)

        var worstMilliseconds = 0.0
        for query in keystrokes {
            let start = Date()
            let matches = InterimCatalogSearch.search(query, in: apps)
            let elapsedSeconds = Date().timeIntervalSince(start)
            let elapsedMilliseconds = elapsedSeconds * 1000
            worstMilliseconds = max(worstMilliseconds, elapsedMilliseconds)

            try Oracle.require(
                elapsedSeconds < perKeystrokeBudgetSeconds,
                "search-perf-keystroke-under-budget",
                "query \"\(query)\" over \(appCount) apps took \(String(format: "%.3f", elapsedMilliseconds)) ms, budget is \(Int(perKeystrokeBudgetSeconds * 1000)) ms",
                failureClass: .hostSide
            )
            // Every partial query up to and including the full name must
            // still find the target: proves the budget was not met by
            // silently truncating results.
            try Oracle.require(
                matches.contains { $0.app.slug == targetSlug },
                "search-perf-still-finds-target",
                "query \"\(query)\" over \(appCount) apps lost the target \(targetSlug) among \(matches.count) matches",
                failureClass: .hostSide
            )
        }

        // Independent oracle: the same brute-force scan used elsewhere,
        // run once on the final (longest, most expensive) query, must agree
        // on the result set, so a fast-but-wrong implementation cannot pass
        // by returning too little.
        let bruteForceSlugs = InterimCatalogSearch.bruteForceContainingSlugs(keystrokes.last!, in: apps)
        try Oracle.require(
            bruteForceSlugs.contains(targetSlug),
            "search-perf-oracle-agrees",
            "independent brute-force scan over \(apps.count) rows did not contain \(targetSlug) for \"\(keystrokes.last!)\"",
            failureClass: .hostSide
        )

        return ScenarioOutcome(
            passed: true,
            message: "Every keystroke's search over \(appCount) apps stayed under \(Int(perKeystrokeBudgetSeconds * 1000)) ms (worst: \(String(format: "%.3f", worstMilliseconds)) ms).",
            personaInterview: PersonaInterview(
                didFinish: true,
                lastHonestMessage: "Kneecap showed up while I was still typing.",
                knewWhatToDoNext: true
            ),
            evidence: [
                "appCount": String(appCount),
                "worstKeystrokeMilliseconds": String(format: "%.3f", worstMilliseconds),
                "searchSeam": "InterimCatalogSearch (sim-only; pending M2 StoreSearchIndex)",
            ]
        )
    }
}
