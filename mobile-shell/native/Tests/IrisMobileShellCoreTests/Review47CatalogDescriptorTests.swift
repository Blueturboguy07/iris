import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47. Covers
/// PublikMobileCatalogClient's parsing of the optional
/// mobileShell.appStoreMetadata field: an old descriptor with none still
/// installs (flagged not-ready), a valid one parses, and hostile fields
/// (huge strings, a script-bearing or non-https URL, an unsupported age
/// rating) are rejected before the descriptor is ever returned to a caller.
final class Review47CatalogDescriptorTests: XCTestCase {
    private func descriptorJSON(appStoreMetadata: [String: Any]?) -> [String: Any] {
        var descriptor: [String: Any] = [
            "version": 1,
            "platform": "ios",
            "packageFormat": "iris.mobile-shell.package+json",
            "downloadUrl": "https://publikhq.com/mobile/nut-ai.irisapp",
            "mediaType": "application/json",
            "byteCount": 1,
            "packageSha256": "sha256:" + String(repeating: "b", count: 64),
            "appId": "publik.nut-ai",
            "projectId": "publik.nut-ai.mobile",
            "baseRevisionId": NSNull(),
            "revisionId": "rev-sha256:" + String(repeating: "a", count: 64),
            "contentHash": "sha256:" + String(repeating: "a", count: 64),
        ]
        if let appStoreMetadata { descriptor["appStoreMetadata"] = appStoreMetadata }
        return descriptor
    }

    private func goodMetadataJSON(ageRating: Any = 9) -> [String: Any] {
        [
            "kind": "iris.mobile-shell.app-store-metadata",
            "version": 1,
            "ageRating": ageRating,
            "privacySummary": "Nut AI keeps meal logs on this device only.",
            "privacyPolicyUrl": "https://publikhq.com/legal/privacy",
            "supportContact": ["kind": "email", "value": "support@publikhq.com"],
            "reportContact": ["kind": "email", "value": "report@publikhq.com"],
        ]
    }

    private func catalogData(mobileShell: [String: Any]) throws -> Data {
        let row: [String: Any] = [
            "slug": "nut-ai",
            "name": "Nut AI",
            "guideSlug": "nut-ai",
            "macBundleId": NSNull(),
            "latestReleaseTag": NSNull(),
            "mobileShell": mobileShell,
        ]
        return try JSONSerialization.data(withJSONObject: ["apps": [row]], options: [.sortedKeys])
    }

    private func fetchApp(mobileShell: [String: Any]) async throws -> PublikMobileCatalogApp {
        let body = try catalogData(mobileShell: mobileShell)
        let transport = SingleResponseTransport(response: PublikMobileHTTPResponse(
            statusCode: 200, mimeType: "application/json",
            declaredContentLength: body.count, finalURL: PublikMobileCatalogClient.catalogURL, body: body
        ))
        let apps = try await PublikMobileCatalogClient(transport: transport).fetchCatalog()
        guard let app = apps.first else { throw XCTFailure.noAppReturned }
        return app
    }

    func testAValidAppStoreMetadataIsParsedAndMarksTheDescriptorListingReady() async throws {
        let app = try await fetchApp(mobileShell: descriptorJSON(appStoreMetadata: goodMetadataJSON()))
        let descriptor = try XCTUnwrap(app.mobileShell)
        XCTAssertEqual(descriptor.appStoreMetadata?.ageRating, 9)
        XCTAssertTrue(descriptor.isReadyForAppStoreListing)
    }

    // "An old descriptor still installs but is flagged": no appStoreMetadata
    // field at all must not reject the descriptor or the app.
    func testAnOldDescriptorWithNoAppStoreMetadataStillInstallsButIsFlaggedNotReady() async throws {
        let app = try await fetchApp(mobileShell: descriptorJSON(appStoreMetadata: nil))
        let descriptor = try XCTUnwrap(app.mobileShell)
        XCTAssertNil(descriptor.appStoreMetadata)
        XCTAssertFalse(descriptor.isReadyForAppStoreListing)
        // Every other install-relevant field is still present and correct.
        XCTAssertEqual(descriptor.appId, "publik.nut-ai")
        XCTAssertEqual(descriptor.revisionId, "rev-sha256:" + String(repeating: "a", count: 64))
    }

    func testHostileAppStoreMetadataFieldsAreRejectedBeforeAnyDescriptorIsReturned() async {
        let hostileCases: [(String, [String: Any])] = [
            ("huge privacy summary", ["privacySummary": String(repeating: "a", count: 10_000)]),
            ("non-https policy URL", ["privacyPolicyUrl": "http://publikhq.com/legal/privacy"]),
            ("script-bearing policy URL", ["privacyPolicyUrl": "https://publikhq.com/\"><script>alert(1)</script>"]),
            ("javascript scheme policy URL", ["privacyPolicyUrl": "javascript:alert(1)"]),
            ("unsupported age rating", ["ageRating": 17]),
            ("malformed support contact email", ["supportContact": ["kind": "email", "value": "not-an-email"]]),
            ("unknown contact kind", ["reportContact": ["kind": "phone", "value": "+1-555-0100"]]),
        ]
        for (label, overrides) in hostileCases {
            var metadata = goodMetadataJSON()
            for (key, value) in overrides { metadata[key] = value }
            do {
                _ = try await fetchApp(mobileShell: descriptorJSON(appStoreMetadata: metadata))
                XCTFail("\(label) must be rejected")
            } catch let error as PublikMobileDownloadError {
                XCTAssertEqual(error, .invalidDescriptorField("mobileShell.appStoreMetadata"), label)
            } catch {
                XCTFail("\(label): unexpected error \(error)")
            }
        }
    }

    func testAgeRatingMustBeAnIntegerNotAStringOrFloat() async {
        for hostileAgeRating: Any in ["9", 9.5] {
            do {
                _ = try await fetchApp(mobileShell: descriptorJSON(appStoreMetadata: goodMetadataJSON(ageRating: hostileAgeRating)))
                XCTFail("age rating \(hostileAgeRating) must be rejected")
            } catch {
                // Either a JSON decode failure (malformedCatalog) or an
                // explicit invalidDescriptorField is an acceptable fail-closed
                // outcome; a successfully parsed descriptor is not.
                XCTAssertTrue(error is PublikMobileDownloadError)
            }
        }
    }
}

private enum XCTFailure: Error {
    case noAppReturned
}

private struct SingleResponseTransport: PublikMobileHTTPTransport, Sendable {
    let response: PublikMobileHTTPResponse

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        response
    }
}
