import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Catalog v2 changes what Browse shows, never what gets installed: the
/// descriptor on an app page goes through the same checks as a v1 catalog
/// row, and `download(_:)` verifies the package bytes exactly as before.
/// The 3-app fixture publish carries real packages (built by the fixture
/// generator and verified there with the contract), so these tests install
/// them end to end through the fake server.
final class CatalogV2InstallVerificationTests: XCTestCase {
    func testEveryFixtureAppInstallsThroughItsCatalogV2PageAndMatchesTheStoreRow() async throws {
        let publish = try CatalogPublish.fixture(3)
        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        let rows = try await client.fetchIndexPage(1, cache: nil).value.apps
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            let page = try await client.fetchAppPage(slug: row.slug, cache: nil).value
            let packageBytes = try XCTUnwrap(publish.files[CatalogPublish.packagePath(row.slug)])
            // What the store shows is what arrives.
            XCTAssertEqual(row.byteCount, packageBytes.count, "\(row.slug): store size differs from the download")
            let installed = try await client.download(client.installableApp(slug: row.slug, name: row.name, appPage: page))
            XCTAssertEqual(installed.packageBytes, packageBytes)
            XCTAssertEqual(installed.catalogSlug, row.slug)
            XCTAssertEqual(installed.identity, page.mobileShell.identity)
            XCTAssertEqual(installed.inspection.revisionId, page.mobileShell.revisionId)
            XCTAssertEqual(installed.inspection.packageSHA256, NativeSecurity.sha256(packageBytes))
            // The store's permission list is what the package asks for.
            XCTAssertEqual(
                Set(page.permissions.map(\.capability)),
                Set(try requestedCapabilities(in: packageBytes)),
                "\(row.slug): permissions shown in the store differ from the package"
            )
        }
    }

    func testTamperedOrSwappedPackagesAreRefusedAtInstall() async throws {
        let publish = try CatalogPublish.fixture(3)
        let slugs = try publish.slugs()
        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        let target = slugs[0]
        let page = try await client.fetchAppPage(slug: target, cache: nil).value
        let app = client.installableApp(slug: target, name: "Target", appPage: page)

        // One flipped byte in the package.
        var flipped = try XCTUnwrap(publish.files[CatalogPublish.packagePath(target)])
        flipped[flipped.count / 2] ^= 0x01
        await server.setFile(flipped, atPath: CatalogPublish.packagePath(target))
        await assertInstallRefused(client, app) { error in
            if case .packageDigestMismatch = error { return true }
            return false
        }

        // Another app's genuine package served at this app's address.
        let other = try XCTUnwrap(publish.files[CatalogPublish.packagePath(slugs[1])])
        await server.setFile(other, atPath: CatalogPublish.packagePath(target))
        await assertInstallRefused(client, app) { error in
            // Refused by size before any byte is trusted, or by digest.
            if case .responseLengthMismatch = error { return true }
            if case .responseTooLarge = error { return true }
            if case .packageDigestMismatch = error { return true }
            return false
        }

        // The package is gone.
        await server.setFile(nil, atPath: CatalogPublish.packagePath(target))
        await assertInstallRefused(client, app) { $0 == .unexpectedStatus(404) }
    }

    func testEveryAppPageInTheHundredAppPublishIsCheckedLikeAV1CatalogRow() async throws {
        let publish = try CatalogPublish.fixture(100)
        let server = FakePublikServer(publish: publish)
        let client = PublikMobileCatalogClient(transport: server)
        for slug in try publish.slugs() {
            let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[CatalogPublish.appPagePath(slug)])) as? [String: Any])
            let shell = try XCTUnwrap(raw["mobileShell"] as? [String: Any])
            let page = try await client.fetchAppPage(slug: slug, cache: nil).value
            XCTAssertEqual(page.mobileShell.downloadURL.absoluteString, shell["downloadUrl"] as? String)
            XCTAssertEqual(page.mobileShell.packageSHA256, shell["packageSha256"] as? String)
            XCTAssertEqual(page.mobileShell.byteCount, shell["byteCount"] as? Int)
        }

        // The same descriptor faults the v1 catalog refuses are refused here.
        let slug = try publish.slugs()[10]
        let faults: [(String, Any, PublikMobileDownloadError)] = [
            ("revisionId", "rev-sha256:" + String(repeating: "c", count: 64), .invalidDescriptorField("mobileShell.contentHash")),
            ("platform", "android", .unsupportedPlatform("android")),
            ("byteCount", 49 * 1024 * 1024, .invalidDescriptorField("mobileShell.byteCount")),
            ("packageSha256", "sha256:not-hex", .invalidDescriptorField("mobileShell.packageSha256")),
            ("mediaType", "text/html", .invalidDescriptorField("mobileShell.mediaType")),
            ("downloadUrl", "https://evil.example/pkg.json", .disallowedURL),
        ]
        for (field, value, expected) in faults {
            var raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[CatalogPublish.appPagePath(slug)])) as? [String: Any])
            var shell = try XCTUnwrap(raw["mobileShell"] as? [String: Any])
            shell[field] = value
            raw["mobileShell"] = shell
            await server.setBehavior(.body(try JSONSerialization.data(withJSONObject: raw)), forPath: CatalogPublish.appPagePath(slug))
            await assertCatalogError(expected) { _ = try await client.fetchAppPage(slug: slug, cache: nil) }
        }
    }

    private func requestedCapabilities(in packageBytes: Data) throws -> [String] {
        let package = try XCTUnwrap(try JSONSerialization.jsonObject(with: packageBytes) as? [String: Any])
        let envelope = try XCTUnwrap(package["envelope"] as? [String: Any])
        let revision = try XCTUnwrap(envelope["revision"] as? [String: Any])
        let manifest = try XCTUnwrap(revision["manifest"] as? [String: Any])
        return try XCTUnwrap(manifest["capabilities"] as? [String])
    }

    private func assertInstallRefused(
        _ client: PublikMobileCatalogClient,
        _ app: PublikMobileCatalogApp,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ matches: (PublikMobileDownloadError) -> Bool
    ) async {
        do {
            _ = try await client.download(app)
            XCTFail("install must be refused", file: file, line: line)
        } catch let error as PublikMobileDownloadError {
            XCTAssertTrue(matches(error), "unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }
}
