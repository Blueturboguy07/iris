import XCTest
@testable import MobileUserSimKit
import IrisMobileShellCore

/// Pure-logic tests for the sim-only `InterimCatalogSearch` seam (not the
/// production Core code, which has no full-catalog search yet).
///
/// Independent verifier fix (2026-09-28): `PublikMobileCatalogApp`'s
/// memberwise initializer is `internal` (Swift only synthesizes a `public`
/// memberwise init when every stored property's type is itself public AND
/// the struct declares no other initializer with narrower semantics is
/// still involved here; in this codebase the type is `public` but the
/// compiler-synthesized initializer stayed `internal`), so this test target
/// cannot construct one directly the way this file previously did
/// (`PublikMobileCatalogApp(slug:...)`), and `swift test` failed to even
/// compile with "initializer is inaccessible due to 'internal' protection
/// level". Real apps are now built the same way every scenario in this
/// harness gets them: encode a schema-valid envelope with
/// `StoreScaleCatalogFixture` and decode it through the real, public
/// `PublikMobileCatalogClient.fetchCatalog()` over a `FakeMobileTransport`,
/// so this is still real Core decode/validation, not a hand-built struct.
final class InterimCatalogSearchTests: XCTestCase {
    private func apps(_ pairs: [(slug: String, name: String)]) async throws -> [PublikMobileCatalogApp] {
        let rows = pairs.map { StoreScaleCatalogFixture.nearMissRow(slug: $0.slug, name: $0.name) }
        let world = DeviceWorld(persona: MobileBuiltInPersonas.p1NonTechnical, seed: 1)
        let transport = FakeMobileTransport(world: world)
        transport.setLiveCatalog(StoreScaleCatalogFixture.envelope(rows: rows))
        let client = PublikMobileCatalogClient(transport: transport)
        return try await client.fetchCatalog()
    }

    func testPrefixMatchRanksAboveSubstringMatch() async throws {
        let apps = try await apps([
            ("a", "Signal Ledger"),      // substring match only ("nal" not relevant; contains "signal" not query)
            ("b", "Knee Support App"),   // prefix match
            ("c", "My Knee Brace"),      // substring match, not prefix
        ])
        let matches = InterimCatalogSearch.search("Knee", in: apps)
        XCTAssertEqual(matches.map(\.app.slug), ["b", "c"])
        XCTAssertEqual(matches[0].rank, 0)
        XCTAssertEqual(matches[1].rank, 1)
    }

    func testCaseInsensitive() async throws {
        let apps = try await apps([("a", "KNEECAP")])
        let matches = InterimCatalogSearch.search("knee", in: apps)
        XCTAssertEqual(matches.map(\.app.slug), ["a"])
    }

    func testEmptyQueryMatchesNothing() async throws {
        let apps = try await apps([("a", "Kneecap")])
        XCTAssertTrue(InterimCatalogSearch.search("", in: apps).isEmpty)
    }

    func testNoMatchReturnsEmpty() async throws {
        let apps = try await apps([("a", "Ledger"), ("b", "Signal")])
        XCTAssertTrue(InterimCatalogSearch.search("Knee", in: apps).isEmpty)
    }

    /// The independent brute-force oracle must agree with `search`'s result
    /// set (not necessarily its order) across a range of sizes, since this
    /// is exactly what a store-scale scenario's oracle assertion relies on.
    func testBruteForceOracleAgreesWithSearchResultSet() async throws {
        var pairs: [(slug: String, name: String)] = []
        for i in 0..<200 {
            pairs.append((slug: "app-\(i)", name: i % 17 == 0 ? "Knee Gadget \(i)" : "Other Thing \(i)"))
        }
        let apps = try await apps(pairs)
        let searched = Set(InterimCatalogSearch.search("Knee", in: apps).map(\.app.slug))
        let bruteForced = InterimCatalogSearch.bruteForceContainingSlugs("Knee", in: apps)
        XCTAssertEqual(searched, bruteForced)
        XCTAssertFalse(searched.isEmpty)
    }
}
