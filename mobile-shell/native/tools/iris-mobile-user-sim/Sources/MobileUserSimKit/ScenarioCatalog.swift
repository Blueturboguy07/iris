import Foundation

/// The full set of persona scenarios this harness ships. Each scenario
/// generates its own real package fixtures once, in its initializer, then is
/// run many times by the `Runner` with varying personas, seeds and device
/// conditions.
public enum ScenarioCatalog {
    public static func makeAll(scratchRoot: URL) throws -> [any MobileScenario] {
        [
            try DoubleTapInstallScenario(scratchRoot: scratchRoot),
            try AirplaneModeOpenScenario(scratchRoot: scratchRoot),
            try EmptyCatalogScenario(scratchRoot: scratchRoot),
            try WrongBaseUpdateScenario(scratchRoot: scratchRoot),
            try StaleCatalogScenario(scratchRoot: scratchRoot),
            try LowStorageUpdateScenario(scratchRoot: scratchRoot),
            try ForceQuitRecoveryScenario(scratchRoot: scratchRoot),
            try IOS17UnsupportedScenario(scratchRoot: scratchRoot),
            try StoreFindAndInstallAtScaleScenario(appCount: 3, scratchRoot: scratchRoot),
            try StoreFindAndInstallAtScaleScenario(appCount: 100, scratchRoot: scratchRoot),
            try StoreFindAndInstallAtScaleScenario(appCount: 1000, scratchRoot: scratchRoot),
            try StoreDoubleTapGetAtScaleScenario(scratchRoot: scratchRoot),
            try SearchPerformanceScenario(scratchRoot: scratchRoot),
            try LockBackgroundDuringInstallScenario(scratchRoot: scratchRoot),
            try CameraPermissionScenario(scratchRoot: scratchRoot),
            try StorageReclaimScenario(scratchRoot: scratchRoot),
            // R2-mobile-integration: wired to the real store indexes (M2).
            try CatalogPage2FailsScenario(scratchRoot: scratchRoot),
            try SponsoredNeverOutranksScenario(scratchRoot: scratchRoot),
            // unit M-store-screens (round3-deferred): CLICK-PATH-006's
            // request-count test and R2-CP-3's index-v2-revision-field
            // persona (both listed as open items in R2-mobile-integration's
            // own HANDOFF.md).
            try OneCatalogRequestPerLaunchScenario(scratchRoot: scratchRoot),
            try UpdateAvailableWithoutPageOpenScenario(scratchRoot: scratchRoot),
            // M-store-screens seed catalog lane: publikhq.com 404 / airplane
            // mode / cache wiped, Browse still shows the apps that came with Iris.
            try StoreSeedCatalogScenario(scratchRoot: scratchRoot),
        ]
    }

    /// The original 8 scenarios only, without the M5 store-scale additions.
    /// Kept so a caller (or a future unit) can still run the base harness's
    /// exact original set for comparison, and so the store-scale additions
    /// stay obviously separable from unit m5-personasim's original,
    /// already-verified 960-run baseline.
    public static func baseEight(scratchRoot: URL) throws -> [any MobileScenario] {
        [
            try DoubleTapInstallScenario(scratchRoot: scratchRoot),
            try AirplaneModeOpenScenario(scratchRoot: scratchRoot),
            try EmptyCatalogScenario(scratchRoot: scratchRoot),
            try WrongBaseUpdateScenario(scratchRoot: scratchRoot),
            try StaleCatalogScenario(scratchRoot: scratchRoot),
            try LowStorageUpdateScenario(scratchRoot: scratchRoot),
            try ForceQuitRecoveryScenario(scratchRoot: scratchRoot),
            try IOS17UnsupportedScenario(scratchRoot: scratchRoot),
        ]
    }
}
