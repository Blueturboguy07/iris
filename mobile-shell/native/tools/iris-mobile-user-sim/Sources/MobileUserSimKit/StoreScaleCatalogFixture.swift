import CryptoKit
import Foundation
import IrisMobileShellCore

/// Builds a schema-valid catalog envelope at store scale (3, 100 or 1,000
/// rows) so the store scenarios can drive the REAL `PublikMobileCatalogClient`
/// decode and per-field validation path
/// (`PublikMobileCatalogClient.fetchCatalog()` /
/// `validateDescriptor`, mobile-shell/native/Sources/IrisMobileShellCore/PublikMobileCatalogClient.swift:373-624)
/// at scale, not just at the 1-2 rows the base harness's scenarios use.
///
/// Every row must satisfy the client's real field validation
/// (`NativeSecurity.isStableId`, `.isSHA256`, `.isRevisionId`, and the
/// `revisionId(forContentHash:)` derivation), but `NativeSecurity` is
/// `internal` to `IrisMobileShellCore`, so this file reimplements the same
/// two-prefix scheme (`sha256Prefix`/`revisionPrefix`,
/// mobile-shell/native/Sources/IrisMobileShellCore/SecurityPrimitives.swift:5-6,29,32-45)
/// against real SHA-256 digests, exactly as `SeededGenerator` reimplements
/// (rather than imports) the desktop harness's own PRNG. None of these
/// synthetic rows' package bytes are ever fetched by a scenario, so their
/// `packageSHA256` only needs to be well-formed, not correspond to real
/// bytes; the one row a scenario actually installs is built from a real
/// `PackageFixture.generate` output instead (see
/// `Scenarios/StoreFindAndInstallAtScaleScenario.swift`).
public enum StoreScaleCatalogFixture {
    public static let sha256Prefix = "sha256:"
    public static let revisionPrefix = "rev-sha256:"

    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func contentHash(for seedString: String) -> String {
        sha256Prefix + sha256Hex(seedString)
    }

    public static func revisionId(forContentHash contentHash: String) -> String {
        revisionPrefix + contentHash.dropFirst(sha256Prefix.count)
    }

    public struct Row: Sendable {
        public let slug: String
        public let name: String
        public let appId: String
        public let projectId: String
        public let downloadURL: URL
        public let byteCount: Int
        public let packageSHA256: String
        public let contentHash: String
        public let revisionId: String

        public init(
            slug: String, name: String, appId: String, projectId: String,
            downloadURL: URL, byteCount: Int, packageSHA256: String,
            contentHash: String, revisionId: String
        ) {
            self.slug = slug
            self.name = name
            self.appId = appId
            self.projectId = projectId
            self.downloadURL = downloadURL
            self.byteCount = byteCount
            self.packageSHA256 = packageSHA256
            self.contentHash = contentHash
            self.revisionId = revisionId
        }
    }

    /// Word pool kept deliberately mundane (no name overlaps the fixed
    /// "Kneecap" target used by the store scenarios) so a partial-name
    /// search has real, plausible neighbors to rank against instead of an
    /// empty field.
    private static let wordPool = [
        "Focus", "Ledger", "Bright", "Nimbus", "Garden", "Signal", "Anchor",
        "Circuit", "Meadow", "Harbor", "Ridge", "Lantern", "Compass", "Orbit",
        "Thicket", "Cobble", "Ember", "Willow", "Granite", "Tide",
    ]

    /// `count` deterministic, schema-valid, never-downloaded rows. Slugs are
    /// `sim-app-00000`.. so they satisfy `NativeSecurity.isStableId`
    /// (lowercase alphanumeric plus `.`, `_`, `-`) and never collide with a
    /// scenario's own real target slug.
    public static func syntheticRows(count: Int, seed: UInt64) -> [Row] {
        guard count > 0 else { return [] }
        var rng = SeededGenerator(seed: seed)
        var rows: [Row] = []
        rows.reserveCapacity(count)
        for i in 0..<count {
            let w1 = wordPool[Int(rng.nextUnitDouble() * Double(wordPool.count)) % wordPool.count]
            let w2 = wordPool[Int(rng.nextUnitDouble() * Double(wordPool.count)) % wordPool.count]
            let slug = "sim-app-" + String(format: "%05d", i)
            let name = "\(w1) \(w2) \(i)"
            let seedString = "store-scale-fixture:\(slug)"
            let hash = contentHash(for: seedString)
            let revId = revisionId(forContentHash: hash)
            let digestSuffix = String(revId.dropFirst(revisionPrefix.count))
            rows.append(
                Row(
                    slug: slug,
                    name: name,
                    appId: "sim." + slug,
                    projectId: "sim." + slug + ".mobile",
                    downloadURL: URL(string: "https://publikhq.com/api/iris/mobile-shell/\(slug)/\(digestSuffix).json")!,
                    byteCount: 512 + Int(rng.nextUnitDouble() * 4096),
                    packageSHA256: sha256Prefix + sha256Hex("package-bytes:\(seedString)"),
                    contentHash: hash,
                    revisionId: revId
                )
            )
        }
        return rows
    }

    /// A near-miss decoy: shares a prefix with a target name (e.g. "Knee")
    /// without being it, so a search scenario proves disambiguation rather
    /// than just proving the only candidate wins.
    public static func nearMissRow(slug: String, name: String) -> Row {
        let seedString = "store-scale-near-miss:\(slug)"
        let hash = contentHash(for: seedString)
        let revId = revisionId(forContentHash: hash)
        let digestSuffix = String(revId.dropFirst(revisionPrefix.count))
        return Row(
            slug: slug,
            name: name,
            appId: "sim." + slug,
            projectId: "sim." + slug + ".mobile",
            downloadURL: URL(string: "https://publikhq.com/api/iris/mobile-shell/\(slug)/\(digestSuffix).json")!,
            byteCount: 1024,
            packageSHA256: sha256Prefix + sha256Hex("package-bytes:\(seedString)"),
            contentHash: hash,
            revisionId: revId
        )
    }

    /// One real, installable row built from an actual `GeneratedPackage`
    /// (produced by `PackageFixture.generate`, the same real fixture pipeline
    /// `DoubleTapInstallScenario` and the rest of the base harness use), so
    /// exactly one app in an otherwise-synthetic catalog can actually be
    /// downloaded and installed for real.
    public static func realRow(
        slug: String, name: String, package: GeneratedPackage, downloadURL: URL
    ) -> Row {
        Row(
            slug: slug,
            name: name,
            appId: package.appId,
            projectId: package.projectId,
            downloadURL: downloadURL,
            byteCount: package.bytes.count,
            packageSHA256: package.packageSHA256,
            contentHash: package.contentHash,
            revisionId: package.revisionId
        )
    }

    /// The wire-shape catalog envelope `PublikMobileCatalogClient.fetchCatalog()`
    /// decodes, field names mirrored from `CatalogFixture.envelope` exactly.
    public static func envelope(rows: [Row]) -> Data {
        let appsJSON: [[String: Any]] = rows.map { row in
            [
                "slug": row.slug,
                "name": row.name,
                "guideSlug": NSNull(),
                "macBundleId": NSNull(),
                "latestReleaseTag": NSNull(),
                "mobileShell": [
                    "version": 1,
                    "platform": "ios",
                    "packageFormat": "iris.mobile-shell.package+json",
                    "downloadUrl": row.downloadURL.absoluteString,
                    "mediaType": "application/json",
                    "byteCount": row.byteCount,
                    "packageSha256": row.packageSHA256,
                    "appId": row.appId,
                    "projectId": row.projectId,
                    "baseRevisionId": NSNull(),
                    "revisionId": row.revisionId,
                    "contentHash": row.contentHash,
                ],
            ]
        }
        let root: [String: Any] = ["apps": appsJSON]
        return try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
