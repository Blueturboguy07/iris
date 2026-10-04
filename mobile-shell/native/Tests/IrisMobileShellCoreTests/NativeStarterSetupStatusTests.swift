import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Behavior tests for the pure starter-setup snapshot reducers
/// (`NativeStarterSetupPlanning.started` / `.finished`). No coordinator, no
/// filesystem, no `Task`: every case here is plain in-memory data, so these
/// assert exactly what a person would see in the "My apps" library (a
/// setting-up line naming real apps, or a plain failure message), never an
/// internal constant this test set up itself.
///
/// Personas (see the phone-fixes B-home-and-first-launch plan):
/// P1 non-technical reader watching first launch; P3 edge (one starter app
/// fails while the others still appear; nothing bundled needed installing).
final class NativeStarterSetupStatusTests: XCTestCase {
    private let catalogOrder = ["Kneecap", "NutAI", "FreeHarmony"]

    private func chain(_ displayName: String) -> NativeStarterInstaller.AppChain {
        // The reducers never look at package bytes, only `displayName`, so
        // an empty payload keeps these tests fast and focused.
        NativeStarterInstaller.AppChain(displayName: displayName, orderedPackages: [])
    }

    private var threeBundledChains: [String: NativeStarterInstaller.AppChain] {
        ["Kneecap": chain("Kneecap"), "NutAI": chain("Nut AI"), "FreeHarmony": chain("FreeHarmony")]
    }

    // MARK: - P1: first launch, everything still needs installing

    func testFirstLaunchNamesAllThreeAppsInTheCatalogsOwnOrderNotAlphabetical() {
        let snapshot = NativeStarterSetupPlanning.started(
            chains: threeBundledChains,
            needing: ["Kneecap", "NutAI", "FreeHarmony"],
            order: catalogOrder
        )
        // Alphabetically this would read "FreeHarmony, Kneecap, Nut AI"; the
        // reader should see the order the catalog declares instead, matching
        // the required copy "Setting up your apps: Kneecap, Nut AI, FreeHarmony.".
        XCTAssertEqual(snapshot.runningAppNames, ["Kneecap", "Nut AI", "FreeHarmony"])
        XCTAssertTrue(snapshot.failedAppNames.isEmpty)
        XCTAssertFalse(snapshot.hasNothingToShow)
    }

    func testNothingBundledNeedsInstallingShowsNoBannerAtAll() {
        // A launch after every starter app already installed: the quick
        // pre-check finds nothing to do, and the reader must never see a
        // "setting up" line for work that will not happen.
        let snapshot = NativeStarterSetupPlanning.started(
            chains: threeBundledChains, needing: [], order: catalogOrder
        )
        XCTAssertEqual(snapshot, .idle)
        XCTAssertTrue(snapshot.hasNothingToShow)
    }

    // MARK: - P3: resume after a partial install names only what is left

    func testResumedLaunchNamesOnlyTheChainsStillNeedingInstall() {
        // One app (Kneecap) finished on an earlier launch; only the other
        // two are still being set up on this one.
        let snapshot = NativeStarterSetupPlanning.started(
            chains: threeBundledChains, needing: ["NutAI", "FreeHarmony"], order: catalogOrder
        )
        XCTAssertEqual(snapshot.runningAppNames, ["Nut AI", "FreeHarmony"])
    }

    // MARK: - P3: one starter chain fails, the others still appear

    func testOneFailedChainIsNamedInPlainLanguageAndNothingIsShownRunningAnyMore() {
        let results: [String: NativeStarterInstaller.AppResult] = [
            "Kneecap": .installed([.installed(revisionId: "rev-a")], finalRevisionId: "rev-a"),
            "NutAI": .failed("chain for NutAI is not contiguous at index 1"),
            "FreeHarmony": .alreadyPresent(currentRevisionId: "rev-b"),
        ]
        let snapshot = NativeStarterSetupPlanning.finished(chains: threeBundledChains, results: results, order: catalogOrder)
        XCTAssertEqual(snapshot.failedAppNames, ["Nut AI"], "only the app that actually failed is named")
        XCTAssertTrue(snapshot.runningAppNames.isEmpty, "setup is over; nothing should still read as running")
    }

    func testTwoFailedChainsAreBothNamedInCatalogOrder() {
        let results: [String: NativeStarterInstaller.AppResult] = [
            "Kneecap": .failed("kneecap boom"),
            "NutAI": .installed([], finalRevisionId: "rev-a"),
            "FreeHarmony": .failed("freeharmony boom"),
        ]
        let snapshot = NativeStarterSetupPlanning.finished(chains: threeBundledChains, results: results, order: catalogOrder)
        XCTAssertEqual(snapshot.failedAppNames, ["Kneecap", "FreeHarmony"])
    }

    func testAllSucceedingLeavesNothingToShowAfterFinishing() {
        let results: [String: NativeStarterInstaller.AppResult] = [
            "Kneecap": .installed([], finalRevisionId: "rev-a"),
            "NutAI": .alreadyPresent(currentRevisionId: "rev-b"),
            "FreeHarmony": .installed([], finalRevisionId: "rev-c"),
        ]
        let snapshot = NativeStarterSetupPlanning.finished(chains: threeBundledChains, results: results, order: catalogOrder)
        XCTAssertEqual(snapshot, .idle)
    }

    // MARK: - Defensive fallbacks: nothing is silently dropped

    func testALabelNotInTheOrderedCatalogListIsStillNamedNotDropped() {
        let chains = ["SideloadedExtra": chain("Side Loaded Extra")]
        let snapshot = NativeStarterSetupPlanning.started(
            chains: chains, needing: ["SideloadedExtra"], order: catalogOrder
        )
        XCTAssertEqual(snapshot.runningAppNames, ["Side Loaded Extra"])
    }

    func testALabelWithNoMatchingChainFallsBackToTheLabelItself() {
        // Defensive only: `installMissing`/`stillNeeded` always pass a
        // `labels` set drawn from the same `chains` dictionary, so this
        // should not occur in practice, but a missing entry must still
        // produce a real (if plain) name rather than silently vanishing.
        let snapshot = NativeStarterSetupPlanning.started(
            chains: [:], needing: ["GhostApp"], order: catalogOrder
        )
        XCTAssertEqual(snapshot.runningAppNames, ["GhostApp"])
    }
}
