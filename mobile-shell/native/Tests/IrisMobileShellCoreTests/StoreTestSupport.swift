import Foundation
import XCTest
@testable import IrisMobileShellCore

// Unit M2-store-layout-implementation: shared world for the Store suites.
// The store's catalog is loaded the way the phone loads it: M3's real
// `PublikMobileCatalogV2Loader` and client, talking to the fake Publik server
// (the only thing faked, at the network boundary) that serves the checked-in
// fixture publishes at 3, 100 and 1,000 apps.

enum StoreWorld {
    static let sizes = [3, 100, 1000]

    /// Loads index v2 and categories through the real client and cache.
    static func index(appCount: Int, hiddenSlugs: Set<String> = []) async throws -> StoreCatalogIndex {
        let server = FakePublikServer(publish: try CatalogPublish.fixture(appCount))
        return try await index(server: server, hiddenSlugs: hiddenSlugs)
    }

    static func index(server: FakePublikServer, hiddenSlugs: Set<String> = []) async throws -> StoreCatalogIndex {
        let client = PublikMobileCatalogClient(transport: server)
        let cache = PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory("store-world"))
        let loader = PublikMobileCatalogV2Loader(client: client, cache: cache)
        switch try await loader.refresh() {
        case .catalog(let snapshot):
            let categories = try await client.fetchCategories(cache: cache).value.categories
            return StoreCatalogIndex(snapshot: snapshot, categories: categories, hiddenSlugs: hiddenSlugs)
        case .legacy(let rows):
            return StoreCatalogIndex(legacyRows: rows, hiddenSlugs: hiddenSlugs)
        }
    }

    /// The 3-app publish with installable packages, plus the v1 route the
    /// install flow resolves slugs through (as publikhq.com serves both).
    static func installablePublish() throws -> CatalogPublish {
        var publish = try CatalogPublish.fixture(3)
        let legacy = try publish.legacyOnly()
        publish.files[CatalogPublish.legacyCatalogPath] = legacy.files[CatalogPublish.legacyCatalogPath]
        return publish
    }
}

/// Deterministic seeded generator (SplitMix64) so every run can be replayed.
struct StoreSeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A fresh, empty library folder for one simulated phone.
func makeStoreLibraryRoot(_ label: String = #function) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("store-tests", isDirectory: true)
        .appendingPathComponent("\(label.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Elapsed wall time of `body` in milliseconds.
func storeMilliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
