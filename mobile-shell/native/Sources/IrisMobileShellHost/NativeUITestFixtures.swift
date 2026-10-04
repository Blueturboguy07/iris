import Foundation
import CryptoKit
import IrisMobileShellCore

// unit m6-mobile-uitests. DEBUG-only fixture plumbing for the mobile
// XCUITest target: a launch argument that points the real catalog client at
// local, generated (or bundled) catalog v2 data instead of the network, and
// a synchronous seed step for the installed-app library. Nothing here runs
// in a Release build (the whole file compiles only under `#if DEBUG`,
// matching the existing `--iris-storage-acceptance` / `--iris-local-app-
// acceptance` pattern in `IrisMobileShellApp.swift`), and nothing here ever
// opens a real socket or reads a real network response: every request the
// app makes while a fixture mode is active is answered in-process from
// bytes this file owns, so a UI test run never depends on, or talks to,
// publikhq.com. See `docs/plans/20260928-all-routes/M6-mobile-uitests/
// INTEGRATION_HOOKS.md` for the two-line change `IrisMobileShellApp.swift`
// needs to read the launch argument and use this file; that file is owned
// by the phone-fixes pass in flight, so this unit cannot edit it directly.
#if DEBUG

/// The scale or condition a UI test run asks for with
/// `--iris-ui-test-fixtures <mode>`. Values are the exact strings the
/// launch argument takes and the exact strings `NativeUITestFixtures.md`
/// (and every UI test file) name in their doc comments, so a test failure
/// and this file's routing logic always describe the same thing.
public enum NativeUITestFixtureMode: String, CaseIterable, Sendable {
    /// 3 apps: under SPEC 3.2's collapse threshold, so Browse renders as a
    /// single "All apps" list with no chips or shelves.
    case catalog3
    /// 100 apps across categories, featured and sponsored shelves, one page.
    case catalog100
    /// 1,000 apps across 4 index pages (250 apps per page, SPEC R8.1),
    /// enough non-empty categories to exercise "Browse all categories" and
    /// paging in a category page (section 5 of the design).
    case catalog1000
    /// Every request fails (no network), but the on-disk catalog cache is
    /// pre-seeded with a successful catalog3-shaped snapshot before the app
    /// ever asks, so Browse must render from that cache with the "Offline.
    /// Showing apps from <date>." status line (design section 3.4).
    case offlineWarm = "offline-warm"
    /// Every request fails and no cache exists: the true first-launch,
    /// airplane-mode case. Browse must fall back to the bundled starter
    /// descriptors, never a blank screen (design section 10).
    case offlineCold = "offline-cold"
    /// A catalog3-shaped index, plus every bundled Starter chain installed
    /// at its final revision (so several revisions exist to prune) and the
    /// global code cap lowered to a few hundred KB, so the device already
    /// reads as full without needing gigabytes of real fixture bytes.
    case storageFull = "storage-full"
    /// Three real revision histories for the keep-count Storage scenarios.
    case storageKeepCount = "storage-keep-count"
    /// A catalog3-shaped index whose first app carries `ageRating: 18`, so
    /// the Get slot for that one app starts in `restricted(age)` (design
    /// section 6.2 and 15) from the first launch.
    case restricted

    /// Apps in the generated index for this mode's "browse" shape. Offline
    /// modes still generate this shape (it drives `offline-warm`'s cache
    /// seed); the transport simply refuses to serve it live for those two.
    var generatedAppCount: Int {
        switch self {
        case .catalog3, .offlineWarm, .offlineCold, .storageFull, .storageKeepCount, .restricted: return 3
        case .catalog100: return 100
        case .catalog1000: return 1000
        }
    }

    /// True when every live catalog request must fail (no network), which
    /// is the one axis that is not "how many apps."
    var isOffline: Bool {
        self == .offlineWarm || self == .offlineCold
    }
}

/// Entry points the app target (`IrisMobileShellApp.swift`, via
/// `INTEGRATION_HOOKS.md`) and the UI tests both use.
public enum NativeUITestFixtures {
    /// `--iris-ui-test-fixtures <mode>`, e.g. `--iris-ui-test-fixtures
    /// catalog100`. Two tokens, exactly like the existing
    /// `--iris-storage-acceptance` and `--iris-local-app-acceptance` flags,
    /// so a UI test's `XCUIApplication().launchArguments` reads the same
    /// way as every other acceptance entry point in this app.
    public static let launchArgumentFlag = "--iris-ui-test-fixtures"

    /// Parses `arguments` for `launchArgumentFlag` followed by a known mode
    /// name. Returns nil when the flag is absent or the value does not
    /// match a case exactly (never a partial or case-insensitive match: an
    /// unrecognized value is a test-setup bug and should fail loudly by
    /// falling through to the normal launch path, not by silently picking a
    /// mode).
    public static func requestedMode(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> NativeUITestFixtureMode? {
        guard let flagIndex = arguments.firstIndex(of: launchArgumentFlag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.count else { return nil }
        return NativeUITestFixtureMode(rawValue: arguments[valueIndex])
    }

    /// The isolated Application Support subdirectory name for this mode,
    /// parallel to the existing `"v1"` / `"acceptance-v1"` /
    /// `"multiapp-acceptance-v1"` namespaces in `IrisMobileShellApp.swift`.
    /// Every mode gets its own namespace (never shared with a developer's
    /// own simulator data, and never shared between two fixture modes) so a
    /// UI test run's synthetic library cannot leak into, or be polluted by,
    /// any other run.
    public static func storageNamespace(for mode: NativeUITestFixtureMode) -> String {
        storageNamespace(for: mode, launchArguments: ProcessInfo.processInfo.arguments)
    }

    public static func storageNamespace(for mode: NativeUITestFixtureMode, launchArguments: [String]) -> String {
        guard let token = MyAppsUITestSeed.fixtureSessionToken(arguments: launchArguments) else { return "ui-test-\(mode.rawValue)" }
        return "ui-test-session-\(token)-\(mode.rawValue)"
    }

    /// A catalog client wired to the in-process fixture transport for
    /// `mode`. Never touches the network: every `get` either returns
    /// generated or bundled bytes immediately, or throws
    /// `PublikMobileDownloadError.transportFailure` for an offline mode.
    public static func makeCatalogClient(for mode: NativeUITestFixtureMode) -> PublikMobileCatalogClient {
        PublikMobileCatalogClient(transport: NativeUITestFixtureTransport(mode: mode))
    }

    /// Exact downloadable revision ids used by the retention store for this
    /// fixture. FreeHarmony is intentionally absent because it is local-only.
    public static func downloadableRevisionIds(
        for identity: NativeShellAppIdentity,
        mode: NativeUITestFixtureMode
    ) -> Set<String> {
        guard mode == .storageKeepCount else { return [] }
        guard identity != KeepCountFixture.apps[2].identity,
              let app = KeepCountFixture.apps.first(where: { $0.identity == identity }) else { return [] }
        return Set(app.revisions.map(\.revisionId))
    }

    /// Prepares the library and (for `offlineWarm`) the on-disk catalog
    /// cache for `mode`, then returns. This blocks the calling thread for a
    /// bounded time (60 s for a session, 20 s for legacy, 180 s for
    /// storageFull): `IrisMobileShellApp.init()` is
    /// synchronous, and every UI-test-fixture launch must have a
    /// deterministic library and cache in place *before* `NativeShellAppView`
    /// mounts and starts reading them, not racing a background `Task`
    /// against first paint the way the normal Starter install intentionally
    /// does. Bounded, DEBUG-only, and only reachable behind
    /// `requestedMode(arguments:)` returning non-nil, so it can never affect
    /// a normal or Release launch's startup time.
    public static func seedSynchronously(
        mode: NativeUITestFixtureMode,
        coordinator: NativeShellLibraryCoordinator,
        cacheDirectory: URL
    ) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await seed(mode: mode, coordinator: coordinator, cacheDirectory: cacheDirectory)
            semaphore.signal()
        }
        // Storage-full uses a longer bound for its fresh Starter install and
        // must finish before the Storage screen mounts. A timeout fails loudly.
        let timeoutSeconds: Int
        if mode == .storageFull {
            timeoutSeconds = 180
        } else {
            timeoutSeconds = MyAppsUITestSeed.fixtureSessionToken() == nil ? 20 : 60
        }
        let completed = semaphore.wait(timeout: .now() + .seconds(timeoutSeconds))
        if mode == .storageFull {
            precondition(completed == .success, "Storage-full UI fixture did not finish seeding within 180 seconds.")
        }
    }

    // MARK: - Seeding

    private static func seed(
        mode: NativeUITestFixtureMode,
        coordinator: NativeShellLibraryCoordinator,
        cacheDirectory: URL
    ) async {
        if mode == .storageKeepCount {
            await seedKeepCountFixture(coordinator: coordinator)
            return
        }
        try? MyAppsUITestSeed.sweepStaleSessions(namespaceRoot: cacheDirectory.deletingLastPathComponent())
        // Legacy launches retain their age reset. New sessions start with an
        // empty suite and preserve the person's answer across same-token relaunches.
        if MyAppsUITestSeed.fixtureSessionToken() == nil {
            let defaults = fixtureDefaults(namespace: storageNamespace(for: mode))
            defaults.removeObject(forKey: "iris.review47.age-gate.declared-minimum-age")
            defaults.removeObject(forKey: "iris.review47.age-gate.has-asked-once")
        }

        if mode == .offlineCold {
            // The true first-launch-offline case: no cache, no library.
            return
        }

        if mode == .offlineWarm {
            await seedWarmCache(mode: mode, cacheDirectory: cacheDirectory)
        }

        // Every mode except offlineCold gets a small installed library
        // (My apps / Versions / Storage need something to show); storageFull
        // lowers the cap before installing every chain so the first Storage
        // read shows the over-limit state without needing gigabytes of bytes.
        let chains = bundledStarterChains()
        guard !chains.isEmpty else { return }
        let installer = NativeStarterInstaller()
        let storageFullDefaults = fixtureDefaults(namespace: storageNamespace(for: mode))
        let keepCountKey = NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey
        let priorKeepCount = storageFullDefaults.string(forKey: keepCountKey)
        if mode == .storageFull {
            // Save the cap before activation so the first Storage read sees it.
            // Keep all revisions during installation: activation enforces the
            // keep-count policy, and the low cap alone must not prune history.
            await coordinator.setGlobalCodeCapBytes(256 * 1024, defaults: storageFullDefaults)
            storageFullDefaults.set(VersionsKeptPerApp.keepAll.rawValue, forKey: keepCountKey)
        }
        _ = await installer.installMissing(chains, into: coordinator)

        if mode == .storageFull {
            if let priorKeepCount {
                storageFullDefaults.set(priorKeepCount, forKey: keepCountKey)
            } else {
                storageFullDefaults.removeObject(forKey: keepCountKey)
            }
        }
    }

    private static func seedWarmCache(mode: NativeUITestFixtureMode, cacheDirectory: URL) async {
        let cache = PublikMobileCatalogCache(directory: cacheDirectory)
        let generator = NativeUITestCatalogGenerator(mode: .catalog3)
        let now = Date()
        let indexPage = generator.indexPageJSON(page: 1)
        _ = try? await cache.write(
            key: "index-1",
            body: indexPage,
            etag: "\"ui-test-warm-index\"",
            now: now
        )
        let categories = generator.categoriesJSON()
        _ = try? await cache.write(
            key: "categories",
            body: categories,
            etag: "\"ui-test-warm-categories\"",
            now: now
        )
    }

    /// A `UserDefaults` suite private to this mode, so
    /// `setGlobalCodeCapBytes` never touches `.standard` (which a developer
    /// running the app normally, in the same simulator, also uses).
    private static func fixtureDefaults(namespace: String) -> UserDefaults {
        UserDefaults(suiteName: "IrisMobileShell.\(namespace)") ?? .standard
    }

    private static func seedKeepCountFixture(coordinator: NativeShellLibraryCoordinator) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains("--iris-ui-test-preserve-state") else { return }

        let defaults = fixtureDefaults(namespace: storageNamespace(for: .storageKeepCount, launchArguments: arguments))
        let preferenceKey = NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey
        let priorChoice = defaults.string(forKey: preferenceKey)
        let requestedChoice = keepCountSeed(arguments: arguments)
        defaults.set(VersionsKeptPerApp.keepAll.rawValue, forKey: preferenceKey)

        do {
            for app in KeepCountFixture.apps {
                for revision in app.revisions {
                    let existing = try await coordinator.libraryEntry(identity: app.identity)
                    if existing?.revisions.contains(where: { $0.revisionId == revision.revisionId }) == true {
                        continue
                    }
                    let review = try await coordinator.reviewImport(
                        packageBytes: revision.package,
                        expectedIdentity: app.identity
                    )
                    let staged = try await coordinator.approvePendingReviewLocallyAndStage(
                        reviewToken: review.reviewToken,
                        packageSHA256: review.packageSHA256
                    )
                    try await coordinator.activate(identity: app.identity, revisionId: staged.revisionId)
                }
            }

            let kneecap = KeepCountFixture.apps[0]
            let dataDirectory = await coordinator.namespaceRootURL
                .appendingPathComponent("reader-data", isDirectory: true)
                .appendingPathComponent(kneecap.identity.appId, isDirectory: true)
                .appendingPathComponent("storage-keep-count-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let sentinel = dataDirectory.appendingPathComponent("keep-count-sentinel.txt", isDirectory: false)
            if !FileManager.default.fileExists(atPath: sentinel.path) {
                _ = FileManager.default.createFile(
                    atPath: sentinel.path,
                    contents: Data("keep-count-user-data-survives".utf8)
                )
            }

            if let priorChoice {
                defaults.set(priorChoice, forKey: preferenceKey)
            } else if let requestedChoice {
                defaults.set(requestedChoice.rawValue, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        } catch {
            if let priorChoice {
                defaults.set(priorChoice, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
            preconditionFailure("Storage keep-count UI fixture seeding failed: \(error)")
        }
    }

    private static func keepCountSeed(arguments: [String]) -> VersionsKeptPerApp? {
        guard let index = arguments.firstIndex(of: "--iris-ui-test-keep-count"),
              arguments.indices.contains(index + 1),
              let choice = VersionsKeptPerApp(rawValue: arguments[index + 1]),
              choice == .keepTwo || choice == .keepThree || choice == .keepFive else { return nil }
        return choice
    }

    /// Reads every bundled Starter chain (`NativeStarterCatalog.entries`,
    /// the same files a normal launch installs) straight from the app
    /// bundle, exactly as `IrisMobileShellApp.loadBundledStarterChains()`
    /// does for the normal path. Reusing the already-shipped, already-valid
    /// packages means installed-app fixtures need no hand-built package
    /// bytes and no new bundled resource: they are the same three apps a
    /// real first launch installs, through the isolated fixture namespace
    /// including every base revision.
    private static func bundledStarterChains() -> [String: NativeStarterInstaller.AppChain] {
        guard let resourcesURL = Bundle.main.resourceURL else { return [:] }
        var chains: [String: NativeStarterInstaller.AppChain] = [:]
        // round6/catalog-expand: same set a normal launch installs (Lunara waits for a Get).
        for entry in NativeStarterCatalog.firstLaunchEntries {
            let directory = resourcesURL.appendingPathComponent(
                NativeStarterCatalog.subdirectory(for: entry), isDirectory: true
            )
            // Updates require their exact base. Keep the whole validated chain.
            let fileNames = entry.orderedFileNames
            let packages: [Data] = fileNames.compactMap { fileName in
                try? Data(contentsOf: directory.appendingPathComponent(fileName, isDirectory: false))
            }
            guard packages.count == fileNames.count, !packages.isEmpty else { continue }
            chains[entry.label] = NativeStarterInstaller.AppChain(
                displayName: entry.displayName,
                orderedPackages: packages
            )
        }
        return chains
    }
}

private struct KeepCountFixtureRevision: Sendable {
    let revisionId: String
    let package: Data
}

private struct KeepCountFixtureApp: Sendable {
    let identity: NativeShellAppIdentity
    let revisions: [KeepCountFixtureRevision]
}

private enum KeepCountFixture {
    static let apps: [KeepCountFixtureApp] = [
        makeApp(appId: "publik.kneecap", displayName: "Kneecap", count: 8),
        makeApp(appId: "publik.nut-ai", displayName: "Nut AI", count: 3),
        makeApp(appId: "publik.freeharmony", displayName: "FreeHarmony", count: 1),
    ]

    private static let projectId = "storage-keep-count-fixture"

    private static func makeApp(appId: String, displayName: String, count: Int) -> KeepCountFixtureApp {
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        var baseRevisionId: String?
        var revisions: [KeepCountFixtureRevision] = []

        for index in 0..<count {
            let html = packageHTML(appId: appId, displayName: displayName, index: index)
            let fileSHA = sha256(html)
            let encodedBaseRevision: Any = baseRevisionId.map { $0 as Any } ?? NSNull()
            let manifest: [String: Any] = [
                "appId": appId,
                "capabilities": [String](),
                "data": ["namespace": appId, "updatePolicy": "preserve"],
                "displayName": displayName,
                "kind": "iris.mobile-shell.manifest",
                "projectId": projectId,
                "runtime": ["entrypoint": "index.html", "minShellVersion": "1.0.0", "type": "web"],
                "version": 1,
            ]
            let revisionFiles: [[String: Any]] = [[
                "bytes": html.count,
                "mediaType": "text/html",
                "path": "index.html",
                "sha256": fileSHA,
            ]]
            let identityPayload: [String: Any] = [
                "appId": appId,
                "baseRevisionId": encodedBaseRevision,
                "files": revisionFiles,
                "manifest": manifest,
                "projectId": projectId,
            ]
            let contentHash = sha256((try? json(identityPayload)) ?? Data())
            let manifestHash = sha256((try? json(manifest)) ?? Data())
            let revisionId = "rev-sha256:\(contentHash.dropFirst("sha256:".count))"
            let instant = String(format: "2026-09-28T00:00:%02d.000Z", index)
            let seed = "\(appId)-revision-\(index)"
            let approvalId = "approval_fixture_\(String(hex(seed: "approval-\(seed)").prefix(24)))"
            let envelopeId = "delivery_fixture_\(String(hex(seed: "envelope-\(seed)").prefix(24)))"
            let nonce = hex(seed: "nonce-\(seed)")

            let revision: [String: Any] = [
                "kind": "iris.mobile-shell.revision",
                "version": 1,
                "appId": appId,
                "projectId": projectId,
                "revisionId": revisionId,
                "baseRevisionId": encodedBaseRevision,
                "manifestHash": manifestHash,
                "contentHash": contentHash,
                "createdAt": instant,
                "manifest": manifest,
                "files": revisionFiles,
            ]
            let package: [String: Any] = [
                "format": "iris.mobile-shell.package+json",
                "approval": [
                    "kind": "iris.mobile-shell.delivery-approval",
                    "version": 1,
                    "approvalId": approvalId,
                    "requestId": NSNull(),
                    "requestNonce": NSNull(),
                    "appId": appId,
                    "projectId": projectId,
                    "baseRevisionId": encodedBaseRevision,
                    "approvedRevisionId": revisionId,
                    "approvedContentHash": contentHash,
                    "approvedAt": instant,
                ] as [String: Any],
                "envelope": [
                    "kind": "iris.mobile-shell.delivery-envelope",
                    "version": 1,
                    "envelopeId": envelopeId,
                    "deliveryNonce": nonce,
                    "approvalId": approvalId,
                    "appId": appId,
                    "projectId": projectId,
                    "baseRevisionId": encodedBaseRevision,
                    "revisionId": revisionId,
                    "contentHash": contentHash,
                    "issuedAt": instant,
                    "revision": revision,
                ] as [String: Any],
                "files": [[
                    "path": "index.html",
                    "mediaType": "text/html",
                    "contentBase64": html.base64EncodedString(),
                ] as [String: Any]],
            ]
            let packageBytes = (try? json(package)) ?? Data()
            revisions.append(KeepCountFixtureRevision(revisionId: revisionId, package: packageBytes))
            baseRevisionId = revisionId
        }
        return KeepCountFixtureApp(identity: identity, revisions: revisions)
    }

    private static func packageHTML(appId: String, displayName: String, index: Int) -> Data {
        let prefix = "<!doctype html><meta charset=utf-8><title>\(displayName) \(index)</title><main data-app=\"\(appId)\">"
        let suffix = "</main>"
        let seed = "\(appId)-\(index)"
        var body = prefix
        while body.utf8.count < 1_200 - suffix.utf8.count {
            for byte in seed.utf8 {
                guard body.utf8.count < 1_200 - suffix.utf8.count else { break }
                let letter = UInt32(97 + (Int(byte) + body.utf8.count) % 26)
                body.append(Character(UnicodeScalar(letter)!))
            }
        }
        body += suffix
        return Data(body.utf8)
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    private static func hex(seed: String) -> String {
        SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Transport

/// Answers every catalog v2 (and legacy v1) request in-process. Routes on
/// the request's path only (the host and scheme are already constrained to
/// `https://publikhq.com` by `PublikMobileCatalogClient` itself before a
/// transport is ever consulted, so this never has to re-check them), and
/// never performs real I/O and never reads from disk: everything it returns
/// comes from `NativeUITestCatalogGenerator`, computed in memory.
struct NativeUITestFixtureTransport: PublikMobileHTTPTransport {
    let mode: NativeUITestFixtureMode

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        guard let url = request.url else {
            throw PublikMobileDownloadError.transportFailure("UI test fixture transport received a request with no URL.")
        }
        if mode.isOffline {
            throw PublikMobileDownloadError.transportFailure("UI test fixtures: \(mode.rawValue) is offline by design.")
        }

        let generator = NativeUITestCatalogGenerator(mode: mode)
        let path = url.path

        let body: Data
        let mimeType: String

        if path == "/api/iris/apps" {
            body = generator.legacyEnvelopeJSON()
            mimeType = "application/json"
        } else if path == "/api/iris/mobile/index.json" {
            body = generator.indexPageJSON(page: 1)
            mimeType = "application/json"
        } else if path.hasPrefix("/api/iris/mobile/index-"), path.hasSuffix(".json"),
                  let page = Int(path.dropFirst("/api/iris/mobile/index-".count).dropLast(".json".count)) {
            body = generator.indexPageJSON(page: page)
            mimeType = "application/json"
        } else if path == "/api/iris/mobile/categories.json" {
            body = generator.categoriesJSON()
            mimeType = "application/json"
        } else if path.hasPrefix("/api/iris/mobile/apps/"), path.hasSuffix(".json") {
            let slug = String(path.dropFirst("/api/iris/mobile/apps/".count).dropLast(".json".count))
            guard let pageBody = generator.appPageJSON(slug: slug) else {
                throw PublikMobileDownloadError.unexpectedStatus(404)
            }
            body = pageBody
            mimeType = "application/json"
        } else if path.hasPrefix("/fixture-icons/") {
            body = NativeUITestCatalogGenerator.iconPNGBytes
            mimeType = "image/png"
        } else if path.hasPrefix("/api/iris/mobile-shell/"), path.hasSuffix("/pkg.json") {
            let slug = String(path.dropFirst("/api/iris/mobile-shell/".count).dropLast("/pkg.json".count))
            guard let packageBody = generator.installablePackageBytes(slug: slug) else {
                throw PublikMobileDownloadError.unexpectedStatus(404)
            }
            body = packageBody
            mimeType = "application/json"
        } else {
            throw PublikMobileDownloadError.unexpectedStatus(404)
        }

        guard body.count <= maximumBytes else {
            throw PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)
        }
        progress?(body.count)
        return PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: mimeType,
            declaredContentLength: body.count,
            finalURL: url,
            body: body,
            etag: "\"ui-test-\(mode.rawValue)\""
        )
    }
}

// MARK: - Generator

/// Builds catalog v2 JSON by hand (field-for-field matches of the private
/// wire types in `PublikMobileCatalogClient.swift`, which this module
/// cannot import) for a deterministic, seeded set of apps at the mode's
/// scale. Every constraint `PublikMobileCatalogClient.decodeCatalogIndexPageV2`
/// enforces is satisfied on purpose (see the inline comments below); a
/// mismatch here would make the real client reject its own fixture and
/// every UI test would see a permanent error state instead of a catalog,
/// which is the fastest possible signal that this generator drifted from
/// the client it feeds.
///
/// Deliberate scope limit: every generated catalog app is synthetic and has
/// no real, valid `DeliveryPackageV1` bytes behind it, so tapping Get on one
/// always ends at `failed` ("The download could not be verified. Nothing
/// was installed.") after a real download-and-verify round trip, never a
/// crash or a silent no-op. That is itself an honest, assertable outcome
/// (`StoreAppPageUITests.testGetOnAGeneratedAppFailsVerificationCleanly`),
/// and it is the only outcome this generator can produce without either
/// fabricating a `DeliveryPackageV1` envelope by hand or depending on a new
/// bundled resource. Installed-app testing (My apps, Versions, Storage,
/// Update badge, fullscreen open, background/return) does not need a
/// catalog-backed install at all: it seeds the three real, already-bundled
/// Starter apps straight into the library through `NativeStarterInstaller`
/// (`NativeUITestFixtures.seed`), which are genuinely valid packages the app
/// already ships and installs on every normal first launch. `HANDOFF.md`
/// lists the one true first-install assertion this cannot cover and the
/// optional follow-up (wiring M3's `Tests/Fixtures/catalog-v2/3/packages/
/// *.irisapp` in as a bundled resource) that would close it.
struct NativeUITestCatalogGenerator {
    let mode: NativeUITestFixtureMode

    private static let categoryNames = [
        "Productivity", "Health & Fitness", "Finance", "Education", "Photo & Video",
        "Games", "Utilities", "Social", "Music", "Reading", "Food & Drink", "Travel",
        "Shopping", "News", "Weather", "Kids", "Developer Tools", "Design", "Writing",
        "Reference", "Lifestyle", "Business", "Sports", "Medical",
    ]

    private static let calendarDates = [
        "2026-09-01", "2026-08-15", "2026-07-04", "2026-06-20", "2026-05-11", "2026-03-28",
    ]

    /// Opaque 128x128 RGB PNG: saturated blue rounded square with a lighter
    /// inner square and pale-blue corners. Generated once with python3 struct
    /// (PNG chunks and CRC32) and zlib (filter-0 RGB scanlines, level 9).
    /// Visible ink lets UI measurements find the icon's actual edges.
    static let iconPNGBytes: Data = Data([
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x80,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x4c, 0x5c, 0xf6, 0x9c, 0x00, 0x00, 0x01,
        0x9e, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0xed, 0xdd, 0x31, 0x52, 0x42,
        0x41, 0x10, 0x45, 0xd1, 0xde, 0x92, 0xfb, 0x71, 0x57, 0x6e, 0xc6, 0x35,
        0x99, 0x19, 0x18, 0x43, 0x40, 0xaa, 0x22, 0xf2, 0xa7, 0x5f, 0xc3, 0x9c,
        0xaa, 0xae, 0x22, 0xe6, 0x9e, 0xf8, 0xbf, 0xa9, 0x8f, 0xcf, 0xd3, 0xe1,
        0xf7, 0xf2, 0xfa, 0xf5, 0x94, 0xb7, 0xa2, 0x55, 0x69, 0x9d, 0x55, 0x29,
        0xdd, 0xb3, 0x12, 0x25, 0x7d, 0x96, 0xa1, 0xa4, 0xcf, 0x32, 0x94, 0xfa,
        0x59, 0x83, 0x92, 0x3e, 0xcb, 0x50, 0xea, 0x67, 0x0d, 0x4a, 0xfd, 0xac,
        0x41, 0xa9, 0x9f, 0x35, 0x28, 0xf5, 0xb3, 0x06, 0xa5, 0x7e, 0xd6, 0x00,
        0xc0, 0x30, 0x00, 0x8d, 0x9a, 0x0d, 0x4a, 0xfd, 0xac, 0x01, 0x80, 0x31,
        0x00, 0xba, 0x44, 0x0c, 0x00, 0xcc, 0x00, 0x50, 0x24, 0x65, 0x00, 0x00,
        0x00, 0x00, 0x2d, 0x82, 0x06, 0x00, 0x00, 0x00, 0x10, 0x02, 0x00, 0x00,
        0x07, 0x60, 0x53, 0x00, 0x15, 0xb2, 0x07, 0x00, 0x00, 0x00, 0xb7, 0x3b,
        0xc0, 0xdb, 0xfb, 0x29, 0x72, 0x5b, 0x03, 0xa4, 0xa2, 0x4f, 0xc3, 0x28,
        0xe9, 0xb3, 0x0c, 0xa5, 0x7e, 0xd6, 0xa0, 0xd4, 0xcf, 0x1a, 0x94, 0xfa,
        0x59, 0x83, 0x52, 0x3f, 0x6b, 0x00, 0x60, 0x03, 0x80, 0x47, 0xac, 0xdf,
        0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0xcf, 0x0c, 0xf0, 0xb8, 0xf5, 0x7b,
        0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xf0, 0xa1, 0xb6, 0x0f, 0xb5, 0x01,
        0x00, 0x00, 0x00, 0xc0, 0x60, 0x93, 0xc1, 0x26, 0x00, 0x46, 0xfb, 0x8c,
        0xf6, 0x99, 0xad, 0x34, 0xdc, 0x6a, 0xb8, 0xd5, 0x74, 0xb1, 0xf1, 0x6e,
        0xe3, 0xdd, 0x63, 0x31, 0x26, 0xfc, 0x77, 0x0f, 0x38, 0x00, 0x00, 0xe0,
        0x00, 0x6c, 0x0c, 0xe0, 0x21, 0xb7, 0xe0, 0x79, 0x49, 0x0f, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x68, 0x01, 0x60, 0x6b, 0x00, 0x06, 0xa9, 0xfa, 0x00,
        0x00, 0x00, 0xb8, 0xfc, 0x30, 0x88, 0xd4, 0x07, 0x30, 0x09, 0x80, 0x41,
        0x7f, 0x7d, 0x00, 0xc3, 0x00, 0x18, 0x34, 0xd7, 0xff, 0x06, 0x80, 0x41,
        0x67, 0x7d, 0x00, 0x23, 0x01, 0x18, 0xb4, 0xd5, 0xff, 0x11, 0x80, 0x41,
        0x4f, 0xfd, 0xdf, 0x00, 0x18, 0x34, 0xd4, 0xbf, 0x02, 0xc0, 0x60, 0x75,
        0xfd, 0xeb, 0x00, 0x0c, 0x96, 0xd6, 0xff, 0x13, 0x00, 0x86, 0x45, 0xe9,
        0x6f, 0x03, 0x60, 0xb0, 0xa2, 0xfe, 0x6d, 0x00, 0x18, 0x8e, 0x4d, 0xff,
        0x4f, 0x00, 0x0c, 0x47, 0xa5, 0xbf, 0x0b, 0x80, 0xc4, 0x9d, 0xdd, 0x0f,
        0x03, 0xd8, 0x4a, 0x65, 0x45, 0xab, 0x33, 0xda, 0x87, 0xa4, 0x71, 0x36,
        0x1b, 0x42, 0xf7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
        0x42, 0x60, 0x82,
    ])

    private static let iconHash: String = {
        let digest = SHA256.hash(data: iconPNGBytes)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }()

    private static let generatedAtISO8601: String = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: 1_790_000_000))
    }()

    private var appCount: Int { mode.generatedAppCount }
    private static let appsPerPage = 250
    private var pageCount: Int { max(1, (appCount + Self.appsPerPage - 1) / Self.appsPerPage) }

    // MARK: Slugs and rows

    private func slug(forIndex index: Int) -> String {
        String(format: "fixture-app-%04d", index)
    }

    private func name(forIndex index: Int) -> String {
        "Fixture App \(index)"
    }

    private func summary(forIndex index: Int) -> String {
        "Sample summary for fixture app number \(index)."
    }

    private func ageRating(forIndex index: Int) -> Int {
        // `restricted` mode's first app (the only app most of its UI tests
        // look at) is always the 17+ bucket, so the Get slot for it starts
        // in `restricted(age)` deterministically, regardless of the cycle
        // below (design sections 6.2 and 15).
        if mode == .restricted, index == 0 { return 18 }
        let ratings = [4, 9, 13, 16, 18]
        return ratings[index % ratings.count]
    }

    private func categoryIds(forIndex index: Int) -> [Int] {
        let first = (index % Self.categoryNames.count) + 1
        let second = ((index + 7) % Self.categoryNames.count) + 1
        return first == second ? [first] : [first, second]
    }

    private func badges(forIndex index: Int) -> [String] {
        // Roughly 1 in 10 apps is new-or-updated, so the "New and updated"
        // shelf (design section 3.1 item 5) has a non-empty, bounded set to
        // render at every scale.
        guard index % 10 == 0 else { return [] }
        return index % 20 == 0 ? ["new"] : ["updated"]
    }

    private func placement(forIndex index: Int) -> [String: Any]? {
        // At most 1 sponsored per shelf and at most 3 per Home is a layout
        // rule for the real app (design section 14); the fixture only needs
        // to guarantee at least one featured and one sponsored app exist
        // when there are enough apps for shelves to render at all (SPEC
        // 3.2's 13-app collapse threshold).
        guard appCount >= 13 else { return nil }
        if index == 1 { return ["featured": true, "sponsored": false, "label": "Featured"] }
        if index == 2 { return ["featured": false, "sponsored": true, "label": "Sponsored"] }
        return nil
    }

    private func rowJSON(forIndex index: Int) -> [String: Any] {
        var row: [String: Any] = [
            "slug": slug(forIndex: index),
            "name": name(forIndex: index),
            "summary": summary(forIndex: index),
            "categoryIds": categoryIds(forIndex: index),
            "iconHash": Self.iconHash,
            "iconURL": "https://publikhq.com/fixture-icons/\(slug(forIndex: index)).png",
            "byteCount": 190_000 + index,
            "ageRating": ageRating(forIndex: index),
            "updatedAt": Self.calendarDates[index % Self.calendarDates.count],
            "badges": badges(forIndex: index),
        ]
        if let placement = placement(forIndex: index) {
            row["placement"] = placement
        } else {
            row["placement"] = NSNull()
        }
        return row
    }

    // MARK: Documents

    func indexPageJSON(page: Int) -> Data {
        let start = (page - 1) * Self.appsPerPage
        let end = min(start + Self.appsPerPage, appCount)
        let rows: [[String: Any]] = start < end ? (start..<end).map(rowJSON(forIndex:)) : []
        let document: [String: Any] = [
            "version": 2,
            "generatedAt": Self.generatedAtISO8601,
            "page": page,
            "pageCount": pageCount,
            "apps": rows,
        ]
        return encode(document)
    }

    func categoriesJSON() -> Data {
        var counts = [Int](repeating: 0, count: Self.categoryNames.count + 1)
        for index in 0..<appCount {
            for categoryId in categoryIds(forIndex: index) where categoryId < counts.count {
                counts[categoryId] += 1
            }
        }
        let rows: [[String: Any]] = Self.categoryNames.enumerated().map { offset, name in
            let id = offset + 1
            return ["id": id, "name": name, "order": offset, "appCount": counts[id]]
        }
        return encode(["categories": rows])
    }

    func legacyEnvelopeJSON() -> Data {
        encode(["apps": [[String: Any]]()])
    }

    /// `apps/<slug>.json`. Returns nil for a slug this generator never
    /// listed in the index (matches the real server's 404 behavior).
    func appPageJSON(slug requestedSlug: String) -> Data? {
        guard let index = appIndex(forSlug: requestedSlug) else { return nil }
        let contentHash = deterministicHex(seed: "content-\(requestedSlug)")
        // Real, self-consistent integrity fields: packageSha256 is the
        // actual sha256 of the bytes `installablePackageBytes(slug:)` will
        // serve for this slug, so a generated app fails at real package
        // *inspection* (not a real `DeliveryPackageV1` envelope), not at an
        // earlier, less meaningful digest mismatch. See the type doc
        // comment for why a generated app never completes an install.
        let packageBytes = installablePackageBytes(slug: requestedSlug) ?? Data()
        let packageDigest = SHA256.hash(data: packageBytes).map { String(format: "%02x", $0) }.joined()
        let mobileShell: [String: Any] = [
            "version": 1,
            "platform": "ios",
            "packageFormat": "iris.mobile-shell.package+json",
            "downloadUrl": "https://publikhq.com/api/iris/mobile-shell/\(requestedSlug)/pkg.json",
            "mediaType": "application/json",
            "byteCount": packageBytes.count,
            "packageSha256": "sha256:\(packageDigest)",
            "appId": "fixture.\(requestedSlug)",
            "projectId": "fixture.\(requestedSlug).mobile",
            "revisionId": "rev-sha256:\(contentHash)",
            "contentHash": "sha256:\(contentHash)",
        ]
        let document: [String: Any] = [
            "mobileShell": mobileShell,
            "description": "Fixture description for \(name(forIndex: index)). Generated for UI test mode \(mode.rawValue).",
            "screenshots": [[String: Any]](),
            "permissions": [
                ["capability": "web.storage", "label": "Remember your data on this device"],
            ],
            "privacySummary": "This fixture app keeps its data on this device.",
            "supportURL": "https://fixtures.example/support",
            "whatsNew": NSNull(),
        ]
        return encode(document)
    }

    /// A small, deterministic, non-`DeliveryPackageV1`-valid JSON blob for a
    /// generated app's "package" download. It exists so the transport can
    /// answer `download()`'s GET without a 404 (which would look like a
    /// transport bug rather than a verification failure); the real client
    /// still rejects it during verification, so a UI test that taps Get on
    /// a *generated* app (index > 0) deterministically reaches the
    /// `failed` state, never a crash or a hang. See the type doc comment
    /// above for the one path that needs a real installable package.
    func installablePackageBytes(slug requestedSlug: String) -> Data? {
        guard appIndex(forSlug: requestedSlug) != nil else { return nil }
        return encode(["fixture": "not-a-real-package", "slug": requestedSlug])
    }

    private func appIndex(forSlug requestedSlug: String) -> Int? {
        for index in 0..<appCount where slug(forIndex: index) == requestedSlug {
            return index
        }
        return nil
    }

    /// A stable 64-character lowercase hex string derived from `seed`, used
    /// where the wire format needs "a sha256-shaped string" but not a hash
    /// of anything in particular (revisionId and contentHash must agree
    /// with each other, per `NativeSecurity.revisionId(forContentHash:)`,
    /// but nothing in the index-v2 decode path re-derives them from actual
    /// bytes, so a deterministic placeholder is both valid and stable
    /// across runs, which keeps failures reproducible).
    private func deterministicHex(seed: String) -> String {
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

#endif
