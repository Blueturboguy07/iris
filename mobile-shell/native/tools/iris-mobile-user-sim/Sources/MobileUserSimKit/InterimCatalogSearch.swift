import Foundation
import IrisMobileShellCore

/// SIM-ONLY interim search, explicitly not production code.
///
/// M5's brief (`docs/plans/20260928-all-routes/M5-mobile-persona-sim-store/PLAN.md`)
/// says to "drive the real catalog client, StoreCatalogIndex and
/// StoreSearchIndex (from M2, when landed; until then drive the client and
/// an interim search over rows and mark the scenario pending)". As of
/// 2026-09-28, M2 (`store-layout-implementation`) has not landed: there is
/// no `StoreCatalogIndex`/`StoreSearchIndex` anywhere in the tree, and
/// `NativeShellCatalogView`/`NativeShellAppView` today only ever show the
/// fixed 3-app `NativeMobileMarketplacePolicy.launchAppIDs` allowlist in
/// Browse (mobile-shell/native/Sources/IrisMobileShellCore/NativeMobileMarketplacePolicy.swift:7-16)
/// with no full-catalog search of any kind, real or otherwise.
///
/// This type is that explicitly-sanctioned stand-in: a plain, linear,
/// case-insensitive scan over the REAL decoded `[PublikMobileCatalogApp]`
/// `PublikMobileCatalogClient.fetchCatalog()` returns, used only so this
/// harness can measure decode/search-at-scale behavior and prove a tap
/// budget today. Every store-scale scenario that uses it records in its
/// `ScenarioOutcome.evidence` that the search step is this seam, not the
/// real one, so a report reader (or the M2 integrator) cannot mistake a
/// pass here for evidence that `StoreSearchIndex` exists or works. Swap
/// the call site in `Scenarios/StoreFindAndInstallAtScaleScenario.swift`
/// for the real index the moment M2 lands (see that unit's
/// `INTEGRATION_HOOKS.md` for the M2 side of this seam).
public enum InterimCatalogSearch {
    public struct Match: Sendable, Equatable {
        public let app: PublikMobileCatalogApp
        /// 0 = the query is a prefix of the name (ranked first); 1 = the
        /// query appears elsewhere in the name.
        public let rank: Int
    }

    /// Ranked: prefix matches first, then other substring matches.
    /// Case-insensitive. An empty query matches nothing (mirrors a real
    /// search field showing no results before the person types anything).
    ///
    /// Independent-verifier fix (2026-09-28): among equally-ranked prefix
    /// matches this used to keep plain catalog order, so a longer decoy
    /// name sharing the same prefix (for example "Kneepad Tracker" against
    /// a "Knee" query) could rank above the tighter match ("Kneecap")
    /// whenever it happened to sit earlier in the fixture's randomly
    /// seeded row order. That was a real, reproducible bug: a store-scale
    /// scenario's own "search ranks the target first" oracle failed at
    /// seed 11 (`store-find-install-100`/`store-find-install-1000`, run 2),
    /// caught by an independent verifier's seeded sweep, not by this
    /// scenario's own single-seed `swift test` run. Sorting prefix matches
    /// by name length first (a shorter name is a tighter match to what was
    /// typed) makes the tighter match win regardless of catalog order;
    /// `sort` is stable, so catalog order remains the tie-break among
    /// same-length names.
    public static func search(_ query: String, in apps: [PublikMobileCatalogApp]) -> [Match] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var prefixMatches: [Match] = []
        var otherMatches: [Match] = []
        for app in apps {
            let haystack = app.name.lowercased()
            if haystack.hasPrefix(needle) {
                prefixMatches.append(Match(app: app, rank: 0))
            } else if haystack.contains(needle) {
                otherMatches.append(Match(app: app, rank: 1))
            }
        }
        prefixMatches.sort { $0.app.name.count < $1.app.name.count }
        return prefixMatches + otherMatches
    }

    /// An independent oracle: a second, deliberately dumber implementation
    /// (no ranking, no code shared with `search`, `Foundation.range(of:)`
    /// instead of `hasPrefix`/`contains`) used only to check that
    /// `search`'s result *set* is exactly right. A mutation that breaks
    /// `search`'s matching (not just its ranking) is expected to disagree
    /// with this set, which is what the mutation check below exercises.
    public static func bruteForceContainingSlugs(_ query: String, in apps: [PublikMobileCatalogApp]) -> Set<String> {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return [] }
        var slugs = Set<String>()
        for app in apps {
            if app.name.lowercased().range(of: needle) != nil {
                slugs.insert(app.slug)
            }
        }
        return slugs
    }
}
