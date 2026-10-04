import Foundation
import IrisMobileShellCore

// Round 6, unit R6-mobile-prep-B (MA2 hook 5, SPEC 5.6). DEBUG-only launch
// fixture for the My apps UI tests: `--iris-ui-test-my-apps <n>` gives the app
// an isolated library of n real installed apps (and three folders, two renamed
// apps) so MyAppsOrganizationUITests' 12-app and scale cases have something to
// organise. The whole file compiles only under `#if DEBUG`; a Release build has
// no fixture type at all (tools/release-hygiene.sh and the Release compile check
// this). The generator and seeder live in Core (`MyAppsUITestSeed`, also
// DEBUG-only) where `swift test` exercises them; this file only bridges them to
// the app's synchronous launch.
#if DEBUG

public enum NativeMyAppsUITestFixtures {
    public static func requestedCount(arguments: [String] = ProcessInfo.processInfo.arguments) -> Int? {
        MyAppsUITestSeed.requestedCount(arguments: arguments)
    }

    public static func storageNamespace(forCount count: Int) -> String {
        MyAppsUITestSeed.storageNamespace(forCount: count)
    }

    /// No network at all: every catalog request fails and Browse shows the apps
    /// that ship with Iris, exactly like the offline-cold fixture mode. The
    /// installed apps come from the seed below, not from any catalog.
    public static func makeCatalogClient() -> PublikMobileCatalogClient {
        NativeUITestFixtures.makeCatalogClient(for: .offlineCold)
    }

    /// Installs the apps and writes the folders next to the library, then
    /// returns. Blocks the launch (like `NativeUITestFixtures.seedSynchronously`)
    /// so My apps never renders half a library. A new session token starts with
    /// an empty library and may need to install every requested app.
    public static func seedSynchronously(count: Int, coordinator: NativeShellLibraryCoordinator) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            if MyAppsUITestSeed.fixtureSessionToken() != nil {
                try? MyAppsUITestSeed.sweepStaleSessions(namespaceRoot: await coordinator.namespaceRootURL)
            }
            await MyAppsUITestSeed.seedLibrary(count: count, into: coordinator)
            MyAppsUITestSeed.writeArrangementIfAbsent(count: count, root: await coordinator.namespaceRootURL)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + .seconds(min(20 + count / 4, 600)))
    }
}

#endif
