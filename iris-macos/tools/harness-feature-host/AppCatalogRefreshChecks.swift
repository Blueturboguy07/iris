import Foundation
@testable import IrisHarnessNative

private enum AppCatalogRefreshCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Standalone checks for the in-memory app catalog path. The directory source
/// is intentionally inert: it never creates a URLSession or reads a profile,
/// so this probe can exercise the service without a network or user data.
@main
struct AppCatalogRefreshChecks {
    @MainActor
    static func main() async {
        do {
            try await run()
            print("APP CATALOG REFRESH CHECKS PASS: 5 groups")
        } catch {
            let message = "APP CATALOG REFRESH CHECKS FAIL: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        try await checkForceRefreshInvalidatesCachedCatalog()
        try await checkForceRefreshBypassesURLSessionCache()
        try await checkDuplicateSlugsKeepFirstRow()
        try await checkFailurePreservesRowsAndPublishesError()
        try await checkRefreshDoesNotStartWatcherOrUseNetwork()
    }

    @MainActor
    private static func checkForceRefreshInvalidatesCachedCatalog() async throws {
        let source = RotatingCachedCatalogAppDirectory(catalogApps: [
            descriptor(slug: "old-app", name: "Old app")
        ])
        let service = makeService(catalogDirectory: source)

        await service.refreshInventory()
        try require(service.inventoryEntries.map(\.slug) == ["old-app"],
                    "initial catalog row was not published")

        await source.replaceUpstreamCatalog(with: [
            descriptor(slug: "new-app", name: "New app")
        ])
        await service.refreshInventory()
        try require(service.inventoryEntries.map(\.slug) == ["old-app"],
                    "ordinary refresh bypassed the source cache")

        await service.refreshInventory(forceCatalogFetch: true)
        try require(service.inventoryEntries.map(\.slug) == ["new-app"],
                    "forced refresh did not publish the replacement catalog")
        let clearCount = await source.clearCount
        try require(clearCount == 1,
                    "forced refresh did not invalidate the source cache exactly once")
        print("PASS force refresh invalidates the cached catalog")
    }

    @MainActor
    private static func checkForceRefreshBypassesURLSessionCache() async throws {
        CatalogCachePolicyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogCachePolicyURLProtocol.self]
        let urlSession = URLSession(configuration: configuration)
        let source = PublikCatalogAppDirectory(
            apiBase: "https://127.0.0.1",
            urlSession: urlSession
        )
        let service = makeService(catalogDirectory: source)

        await service.refreshInventory()
        await service.refreshInventory()
        try require(CatalogCachePolicyURLProtocol.recordedPolicies().count == 1,
                    "ordinary refresh bypassed the source's in-memory cache")

        await service.refreshInventory(forceCatalogFetch: true)
        let policies = CatalogCachePolicyURLProtocol.recordedPolicies()
        try require(policies == [
            .useProtocolCachePolicy,
            .reloadIgnoringLocalCacheData,
        ], "forced refresh did not bypass URLSession's response cache")
        urlSession.invalidateAndCancel()
        print("PASS forced catalog fetch bypasses URLSession cache policy")
    }

    @MainActor
    private static func checkDuplicateSlugsKeepFirstRow() async throws {
        let source = RotatingCachedCatalogAppDirectory(catalogApps: [
            descriptor(slug: "same-app", name: "First name", releaseTag: "v1.0.0"),
            descriptor(slug: "same-app", name: "Second name", releaseTag: "v2.0.0"),
            descriptor(slug: "other-app", name: "Other app")
        ])
        let service = makeService(catalogDirectory: source)

        await service.refreshInventory()
        try require(service.inventoryEntries.map(\.slug) == ["same-app", "other-app"],
                    "duplicate catalog slugs were not removed")
        try require(service.inventoryEntries.first?.name == "First name",
                    "a duplicate slug replaced the first published row")
        try require(service.inventoryEntries.first?.latestReleaseTag == "v1.0.0",
                    "a duplicate slug replaced the first release tag")
        print("PASS duplicate slugs keep the first published row")
    }

    @MainActor
    private static func checkFailurePreservesRowsAndPublishesError() async throws {
        let source = RotatingCachedCatalogAppDirectory(catalogApps: [
            descriptor(slug: "fixture-app", name: "Fixture app", bundleID: "com.fixture.app")
        ])
        let service = makeService(catalogDirectory: source)

        await service.refreshInventory()
        let rowsBeforeFailure = service.inventoryEntries
        let successfulRefreshBeforeFailure = service.lastSuccessfulRefreshCompletedAt
        await source.failEveryFurtherFetch(
            with: .transportFailure(reason: "fixture network is disabled")
        )

        await service.refreshInventory()
        try require(service.inventoryEntries == rowsBeforeFailure,
                    "catalog failure replaced the last known inventory rows")
        try require(service.lastSuccessfulRefreshCompletedAt == successfulRefreshBeforeFailure,
                    "catalog failure changed the last successful refresh timestamp")
        try require(
            service.lastRefreshFailureMessage
                == AppCatalogDirectoryError.transportFailure(
                    reason: "fixture network is disabled"
                ).userFacingMessage,
            "catalog failure did not publish its user-facing error"
        )
        try require(!service.isRefreshing,
                    "service remained marked refreshing after a failed fetch")
        print("PASS catalog failure preserves rows and reports an error")
    }

    @MainActor
    private static func checkRefreshDoesNotStartWatcherOrUseNetwork() async throws {
        let source = RotatingCachedCatalogAppDirectory(catalogApps: [
            descriptor(slug: "offline-app", name: "Offline app")
        ])
        let awarenessService = AppAwarenessService()
        let service = AppInventoryService(
            catalogDirectory: source,
            installedApplicationLocator: InertInstalledApplicationLocator(),
            appAwarenessService: awarenessService
        )

        await service.refreshInventory()
        try require(!awarenessService.isPollingForegroundApp,
                    "catalog refresh started the frontmost-app watcher")
        try require(awarenessService.currentForegroundApp == nil,
                    "catalog refresh populated a frontmost-app reading")
        let networkRequestCount = await source.networkRequestCount
        try require(networkRequestCount == 0,
                    "inert catalog refresh unexpectedly used a network transport")
        print("PASS refresh stays in memory without watcher or network activity")
    }

    @MainActor
    private static func makeService(
        catalogDirectory: any CatalogAppDirectorySource
    ) -> AppInventoryService {
        AppInventoryService(
            catalogDirectory: catalogDirectory,
            installedApplicationLocator: InertInstalledApplicationLocator(),
            appAwarenessService: AppAwarenessService()
        )
    }

    private static func descriptor(
        slug: String,
        name: String,
        bundleID: String? = nil,
        releaseTag: String? = nil
    ) -> CatalogAppDescriptor {
        CatalogAppDescriptor(
            slug: slug,
            name: name,
            macBundleId: bundleID,
            latestReleaseTag: releaseTag
        )
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw AppCatalogRefreshCheckError.failed(message)
        }
    }
}

private actor RotatingCachedCatalogAppDirectory: CatalogAppDirectorySource {
    private var cachedCatalogApps: [CatalogAppDescriptor]?
    private var upstreamCatalogApps: [CatalogAppDescriptor]
    private var failureToThrow: AppCatalogDirectoryError?
    private(set) var clearCount = 0
    private(set) var networkRequestCount = 0

    init(catalogApps: [CatalogAppDescriptor]) {
        self.upstreamCatalogApps = catalogApps
    }

    func replaceUpstreamCatalog(with catalogApps: [CatalogAppDescriptor]) {
        upstreamCatalogApps = catalogApps
    }

    func failEveryFurtherFetch(with failure: AppCatalogDirectoryError) {
        failureToThrow = failure
    }

    func catalogApps() async throws -> [CatalogAppDescriptor] {
        if let failureToThrow {
            throw failureToThrow
        }
        if let cachedCatalogApps {
            return cachedCatalogApps
        }
        cachedCatalogApps = upstreamCatalogApps
        return upstreamCatalogApps
    }

    func clearCachedCatalogApps() async {
        clearCount += 1
        cachedCatalogApps = nil
    }
}

private struct InertInstalledApplicationLocator: InstalledApplicationLocating {
    func applicationBundleURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        nil
    }
}

private final class CatalogCachePolicyURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var policies: [URLRequest.CachePolicy] = []

    static func reset() {
        lock.lock()
        policies.removeAll()
        lock.unlock()
    }

    static func recordedPolicies() -> [URLRequest.CachePolicy] {
        lock.lock()
        defer { lock.unlock() }
        return policies
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path == "/api/iris/apps"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.policies.append(request.cachePolicy)
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(
                self,
                didFailWithError: AppCatalogRefreshCheckError.failed(
                    "fixture URLProtocol could not create a response"
                )
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"apps":[]}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
