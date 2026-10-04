import IrisMobileShellCore
import IrisMobileShellHost
import SwiftUI

@main
struct IrisMobileShellApp: App {
    private let coordinator: NativeShellLibraryCoordinator
    private let usageService: NativeUsageService
    private let permissionStore: NativePermissionStore
    /// M-store-screens INTEGRATION_HOOKS.md Hook 3. See the doc comment at
    /// its construction site below.
    private let storeDefaults: UserDefaults
    private let bundledDemoPackage: Data?
    private let bundledDemoUpdatePackage: Data?
    private let bundledStorageCheckPackage: Data?
    private let catalogClient: PublikMobileCatalogClient
    /// Owned here (never a global) and handed to `NativeShellAppView` so the
    /// library can show first-launch starter-app setup progress and refresh
    /// itself the moment it finishes, with no relaunch. See
    /// `NativeStarterSetupStatus` for why this replaced a prior
    /// `NotificationCenter` post/observe pair.
    private let starterSetupStatus = NativeStarterSetupStatus()
    /// Where the store keeps its catalog cache. nil is the normal Caches
    /// location; a UI-test fixture launch points it at its own seeded folder.
    private let catalogCacheDirectory: URL?
#if DEBUG
    private let isStorageAcceptanceRun: Bool
    private let isLocalAppAcceptanceRun: Bool
#endif

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
#if DEBUG
        // The exact opt-in launch argument selects only a fixed, isolated test
        // namespace. Normal launches and Release cannot enter this test route.
        let storageAcceptance = ProcessInfo.processInfo.arguments.contains("--iris-storage-acceptance")
        let localAcceptance = ProcessInfo.processInfo.arguments.contains("--iris-local-app-acceptance")
        // M6 Hook 2: `--iris-ui-test-fixtures <mode>` (UI tests only).
        let uiTestFixtureMode = NativeUITestFixtures.requestedMode()
        // R6 hook H1: `--iris-ui-test-my-apps <n>` (My apps UI tests, DEBUG only).
        let myAppsFixtureCount = NativeMyAppsUITestFixtures.requestedCount()
        let fixtureNamespace = uiTestFixtureMode.map(NativeUITestFixtures.storageNamespace(for:))
            ?? myAppsFixtureCount.map(NativeMyAppsUITestFixtures.storageNamespace(forCount:))
        isStorageAcceptanceRun = storageAcceptance
        isLocalAppAcceptanceRun = localAcceptance
        catalogClient = uiTestFixtureMode.map(NativeUITestFixtures.makeCatalogClient(for:))
            ?? myAppsFixtureCount.map { _ in NativeMyAppsUITestFixtures.makeCatalogClient() }
            ?? (localAcceptance
                ? PublikMobileCatalogClient(transport: IrisLocalAppAcceptanceTransport())
                : (storageAcceptance ? PublikMobileCatalogClient(transport: IrisStorageAcceptanceTransport()) : .init()))
#else
        let storageAcceptance = false
        let localAcceptance = false
        // Release has no fixture types at all (NativeUITestFixtures is DEBUG-only).
        let fixtureNamespace: String? = nil
        catalogClient = .init()
#endif
        catalogCacheDirectory = fixtureNamespace.map {
            applicationSupport
                .appendingPathComponent("IrisMobileShell", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("PublikCatalogV2", isDirectory: true)
        }
        let root = applicationSupport
            .appendingPathComponent("IrisMobileShell", isDirectory: true)
            .appendingPathComponent(
                fixtureNamespace
                    ?? (localAcceptance ? "multiapp-acceptance-v1" : (storageAcceptance ? "acceptance-v1" : "v1")),
                isDirectory: true
            )
        usageService = NativeUsageService(
            rootURL: applicationSupport
                .appendingPathComponent("IrisMobileShell", isDirectory: true)
                .appendingPathComponent(fixtureNamespace.map { "usage-\($0)" }
                    ?? (localAcceptance ? "usage-multiapp-acceptance-v1" : (storageAcceptance ? "usage-acceptance-v1" : "usage-v1")), isDirectory: true)
        )
        permissionStore = NativePermissionStore(
            rootURL: applicationSupport
                .appendingPathComponent("IrisMobileShell", isDirectory: true)
                .appendingPathComponent(fixtureNamespace.map { "permissions-\($0)" }
                    ?? (localAcceptance ? "permissions-multiapp-acceptance-v1" : (storageAcceptance ? "permissions-acceptance-v1" : "permissions-v1")), isDirectory: true)
        )
        // M-store-screens INTEGRATION_HOOKS.md Hook 3: the Storage screen
        // reads its lowered-cap fixture from the same namespaced UserDefaults
        // suite the UI-test fixture writes into (`NativeUITestFixtures`'s own
        // `storageNamespace(for:)`, "ui-test-<mode>"), not `.standard`. A
        // normal (non-fixture) launch keeps `.standard`, unchanged.
        storeDefaults = fixtureNamespace.flatMap { UserDefaults(suiteName: "IrisMobileShell.\($0)") } ?? .standard
#if DEBUG
        let downloadableRevisionLookup: @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { identity in
            guard let uiTestFixtureMode else { return [] }
            return NativeUITestFixtures.downloadableRevisionIds(for: identity, mode: uiTestFixtureMode)
        }
#else
        let downloadableRevisionLookup: @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] }
#endif
        coordinator = NativeShellLibraryCoordinator(
            rootURL: root,
            shellVersion: "1.0.0",
            // Only the tested, isolated local-storage capability is available.
            // The platform helper still denies it on unsupported OS versions;
            // the Install & Open decision authorizes the distinct internal
            // review, staging, activation, and verified-open steps.
            capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy,
            automaticCodeCap: {
                let defaults = fixtureNamespace.flatMap { UserDefaults(suiteName: "IrisMobileShell.\($0)") } ?? .standard
                return (defaults.object(forKey: NativeShellLibraryCoordinator.globalCodeCapUserDefaultsKey) as? Int64)
                    ?? NativeStorageRetentionPolicy.defaultGlobalCodeCapBytes
            },
            defaults: storeDefaults,
            downloadableRevisionIds: downloadableRevisionLookup
        )
#if DEBUG
        if let uiTestFixtureMode, let catalogCacheDirectory {
            NativeUITestFixtures.seedSynchronously(
                mode: uiTestFixtureMode,
                coordinator: coordinator,
                cacheDirectory: catalogCacheDirectory
            )
        }
        if let myAppsFixtureCount {
            NativeMyAppsUITestFixtures.seedSynchronously(count: myAppsFixtureCount, coordinator: coordinator)
        }
#endif
        if storageAcceptance,
           let demoURL = Bundle.main.url(forResource: "SafeDemo", withExtension: "irisapp") {
            bundledDemoPackage = try? Data(contentsOf: demoURL)
        } else {
            bundledDemoPackage = nil
        }
        if storageAcceptance,
           let updateURL = Bundle.main.url(forResource: "SafeDemoUpdate", withExtension: "irisapp") {
            bundledDemoUpdatePackage = try? Data(contentsOf: updateURL)
        } else {
            bundledDemoUpdatePackage = nil
        }
#if DEBUG
        if storageAcceptance,
           let testURL = Bundle.main.url(forResource: "StorageCheck", withExtension: "irisapp") {
            bundledStorageCheckPackage = try? Data(contentsOf: testURL)
        } else {
            bundledStorageCheckPackage = nil
        }
#else
        bundledStorageCheckPackage = nil
#endif
        // M-longimport HANDOFF.md "What remains" / RC-01+RC-14 leftovers:
        // reap any picker-media lease directory left behind by a kill mid-
        // import, and sweep any WKFileUploadPanel-* orphan WebKit itself
        // left in tmp from a kill mid-handoff, on every launch, not only the
        // next time a picker happens to open. Both sweeps are synchronous,
        // best-effort and never-throwing (see their own doc comments), but
        // still do real (small) disk I/O, so this runs off the main thread
        // and never blocks the UI appearing.
        Task.detached(priority: .utility) {
            NativeMediaImportLaunchCleanup.sweepStaleLeases()
            NativeWKFileUploadPanelTempCleanup.sweepOrphans()
            NativeWritableStreamStagingCleanup.sweep(referenceStart: .distantPast)
        }
        // Starter content only runs the normal launch path. The isolated
        // storage/local-app acceptance runs exist precisely to test fixed,
        // curated fixtures without extra apps in the library; they keep
        // their own separate namespace and never see Starter content.
        if !storageAcceptance, !localAcceptance, fixtureNamespace == nil {
            let starterCoordinator = coordinator
            let chains = Self.loadBundledStarterChains()
            if !chains.isEmpty {
                let status = starterSetupStatus
                let order = NativeStarterCatalog.firstLaunchEntries.map(\.label)
                Task(priority: .utility) {
                    let installer = NativeStarterInstaller()
                    // A quick, non-staging read first: on a launch where
                    // every bundled app is already installed this comes back
                    // empty almost immediately, and the reader never sees a
                    // "setting up" line flash for work that was not done.
                    let needing = await installer.stillNeeded(chains, into: starterCoordinator)
                    await MainActor.run {
                        status.markStarted(chains: chains, needing: needing, order: order)
                    }
                    let results = await installer.installMissing(chains, into: starterCoordinator)
                    await MainActor.run {
                        status.markFinished(chains: chains, results: results, order: order)
                    }
                }
            }
        }
    }

    /// Reads every bundled starter package named in `NativeStarterCatalog`
    /// from this app's own bundle. Missing or unreadable files are dropped
    /// silently from that one app's chain (never crash launch over bundled
    /// content); `NativeStarterInstaller` also rejects a chain whose files
    /// are incomplete or out of order before writing anything.
    private static func loadBundledStarterChains() -> [String: NativeStarterInstaller.AppChain] {
        guard let resourcesURL = Bundle.main.resourceURL else { return [:] }
        var chains: [String: NativeStarterInstaller.AppChain] = [:]
        // round6/catalog-expand: only the apps a launch installs on its own (Lunara waits for a Get).
        for entry in NativeStarterCatalog.firstLaunchEntries {
            let directory = resourcesURL.appendingPathComponent(
                NativeStarterCatalog.subdirectory(for: entry), isDirectory: true
            )
            let packages: [Data] = entry.orderedFileNames.compactMap { fileName in
                try? Data(contentsOf: directory.appendingPathComponent(fileName, isDirectory: false))
            }
            guard packages.count == entry.orderedFileNames.count else { continue }
            chains[entry.label] = NativeStarterInstaller.AppChain(
                displayName: entry.displayName,
                orderedPackages: packages
            )
        }
        return chains
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NativeShellAppView(
                coordinator: coordinator,
                bundledDemoPackage: bundledDemoPackage,
                bundledDemoUpdatePackage: bundledDemoUpdatePackage,
                usageService: usageService,
                bundledStorageCheckPackage: bundledStorageCheckPackage,
                capabilityPolicy: NativeWebStorageConfiguration.capabilityPolicy,
                catalogClient: catalogClient,
                catalogSourceLabel: catalogSourceLabel,
                permissionStore: permissionStore,
                starterSetupStatus: starterSetupStatus,
                catalogCacheDirectory: catalogCacheDirectory,
                storeDefaults: storeDefaults
            )
            // Incoming app links belong to the existing shell, including
            // while a hosted app occupies its full-screen cover.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
#if DEBUG
            .safeAreaInset(edge: .bottom) {
                if isLocalAppAcceptanceRun {
                    Text("Local app acceptance · isolated data · not a public download")
                        .font(.caption).padding(8).frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                        .accessibilityIdentifier("iris.acceptance.local-apps")
                } else if isStorageAcceptanceRun {
                    Text("Storage acceptance test · isolated app data · not a Publik download")
                        .font(.caption)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                        .accessibilityIdentifier("iris.acceptance.isolated-storage")
                }
            }
#endif
        }
        .handlesExternalEvents(matching: ["*"])
        .onChange(of: scenePhase) { phase in
            // R6 hook H3: reclaim WebKit's leftover import copies whenever the app comes back to the front.
            guard phase == .active else { return }
            Task.detached(priority: .utility) {
                NativeWKFileUploadPanelTempCleanup.sweepOrphans()
                NativeWritableStreamStagingCleanup.sweep(referenceStart: Date())
            }
        }
    }

    private var catalogSourceLabel: String {
#if DEBUG
        if isLocalAppAcceptanceRun { return "Local developer package · verified bytes · not published" }
        if isStorageAcceptanceRun { return "Offline storage acceptance · no catalogue network" }
#endif
        return "From Publik · verified download"
    }
}

#if DEBUG
/// The new Browse-on-entry UI must not give the explicit offline native-test
/// launch a real HTTP transport. Normal Debug/Release never select this type.
private struct IrisStorageAcceptanceTransport: PublikMobileHTTPTransport {
    func get(_ request: URLRequest, maximumBytes: Int,
             progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        let body = Data("{\"apps\":[]}".utf8)
        guard request.httpMethod == "GET", request.url == PublikMobileCatalogClient.catalogURL,
              maximumBytes >= body.count else { throw URLError(.noPermissionsToReadFile) }
        try Task.checkCancellation()
        progress?(body.count)
        return PublikMobileHTTPResponse(statusCode: 200, mimeType: "application/json",
            declaredContentLength: body.count, finalURL: PublikMobileCatalogClient.catalogURL, body: body)
    }
}

/// Explicit developer-run retrieval fixture. Normal Debug/Release never use it.
/// The production catalogue client still verifies identity, digest, bounds and
/// every app byte; only HTTP retrieval is replaced with reviewed local packages.
private struct IrisLocalAppAcceptanceTransport: PublikMobileHTTPTransport {
    func get(_ request: URLRequest, maximumBytes: Int,
             progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        try Task.checkCancellation()
        guard request.httpMethod == "GET", maximumBytes > 0,
              let url = request.url, let resources = Bundle.main.resourceURL else {
            throw URLError(.unsupportedURL)
        }
        // Explicit local preview can receive new packages without rebuilding the
        // native Host. These are developer inputs, never installed revision state.
        // Normal Debug/Release never instantiate this transport.
        let bundled = resources.appendingPathComponent("LocalAppAcceptance", isDirectory: true)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let preview = documents?.appendingPathComponent("LocalAppAcceptance", isDirectory: true)
        let root: URL
        if let preview, FileManager.default.fileExists(atPath: preview.appendingPathComponent("preview-v1.marker").path) {
            let values = try preview.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw URLError(.noPermissionsToReadFile) }
            root = preview
        } else { root = bundled }
        let file: URL
        if url == PublikMobileCatalogClient.catalogURL {
            file = root.appendingPathComponent("catalog.json")
        } else {
            let indexURL = root.appendingPathComponent("transport.json")
            let indexValues = try indexURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard indexValues.isRegularFile == true, indexValues.isSymbolicLink != true,
                  (indexValues.fileSize ?? Int.max) < 8192 else { throw URLError(.cannotDecodeContentData) }
            let index = try Data(contentsOf: indexURL)
            guard let name = try JSONDecoder().decode([String: String].self, from: index)[url.absoluteString],
                  ["kneecap.irisapp", "freeharmony.irisapp", "nut-ai.irisapp"].contains(name) else {
                throw URLError(.unsupportedURL)
            }
            file = root.appendingPathComponent(name)
        }
        let body = try await Task.detached(priority: .userInitiated) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= maximumBytes else { throw URLError(.cannotDecodeContentData) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard bytes.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return bytes
        }.value
        try Task.checkCancellation()
        progress?(body.count)
        return PublikMobileHTTPResponse(statusCode: 200, mimeType: "application/json",
            declaredContentLength: body.count, finalURL: url, body: body)
    }
}
#endif
