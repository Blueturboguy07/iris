import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47 (App Store Guideline 4.7
/// obligations). Covers Review47AppStoreMetadata/Review47ContactMethod
/// construction and JSON wire decoding. Mirrors
/// contracts/test/review47-app-store-metadata.test.js's cases in Swift.
final class Review47AppStoreMetadataTests: XCTestCase {
    private func goodMetadata(ageRating: Int = 4) throws -> Review47AppStoreMetadata {
        try Review47AppStoreMetadata(
            ageRating: ageRating,
            privacySummary: "This fixture app stores nothing off-device.",
            privacyPolicyURL: URL(string: "https://publikhq.com/legal/privacy")!,
            supportContact: try Review47ContactMethod(kind: "email", value: "support@publikhq.com"),
            reportContact: try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
        )
    }

    func testEveryKnownAgeRatingTierIsAccepted() throws {
        XCTAssertEqual(Review47AppStoreMetadata.knownAgeRatings, [4, 9, 13, 16, 18])
        for ageRating in Review47AppStoreMetadata.knownAgeRatings {
            XCTAssertNoThrow(try goodMetadata(ageRating: ageRating))
        }
    }

    func testARatingOutsideAppleCurrentTiersIsRejected() {
        for ageRating in [0, 3, 12, 17, 19] {
            XCTAssertThrowsError(try goodMetadata(ageRating: ageRating)) { error in
                XCTAssertEqual(error as? Review47MetadataError, .invalidAgeRating(ageRating))
            }
        }
    }

    // Exercised at the wire boundary (raw JSON string), not by first
    // constructing a Swift `URL`: `URL(string:)` itself may percent-encode
    // a raw "<", ">", "\"" or "'" during parsing, which would silently
    // launder a hostile string into an innocuous-looking URL before this
    // test ever got to check it. The wire path is also the actual
    // untrusted-network-input path a real hostile descriptor would use.
    func testPrivacyPolicyURLMustBeExactHTTPSWithNoInjectedMarkup() throws {
        func wire(policyURL: String) -> Review47AppStoreMetadataWire {
            Review47AppStoreMetadataWire(
                kind: Review47AppStoreMetadataWire.expectedKind,
                version: 1,
                ageRating: 4,
                privacySummary: "ok",
                privacyPolicyURL: policyURL,
                supportContact: Review47ContactMethodWire(kind: "email", value: "support@publikhq.com"),
                reportContact: Review47ContactMethodWire(kind: "email", value: "report@publikhq.com")
            )
        }
        XCTAssertNoThrow(try Review47AppStoreMetadata(wire: wire(policyURL: "https://publikhq.com/legal/privacy")))
        for hostile in [
            "http://publikhq.com/legal/privacy",
            "javascript:alert(1)",
            "https://publikhq.com/\"><script>alert(1)</script>",
        ] {
            XCTAssertThrowsError(try Review47AppStoreMetadata(wire: wire(policyURL: hostile)), "expected rejection for \(hostile)") { error in
                XCTAssertEqual(error as? Review47MetadataError, .invalidPrivacyPolicyURL, "expected rejection for \(hostile)")
            }
        }
    }

    func testAUrlContactAcceptsAnyHTTPSHostButNotAnUnsafeScheme() throws {
        XCTAssertNoThrow(try Review47ContactMethod(kind: "url", value: "https://publikhq.com/report"))
        XCTAssertThrowsError(try Review47ContactMethod(kind: "url", value: "javascript:alert(1)"))
        XCTAssertThrowsError(try Review47ContactMethod(kind: "url", value: "data:text/html,<script>alert(1)</script>"))
    }

    func testAHugePrivacySummaryIsRejectedNotTruncated() {
        let over = String(repeating: "a", count: Review47AppStoreMetadata.maximumPrivacySummaryCharacters + 1)
        let atLimit = String(repeating: "a", count: Review47AppStoreMetadata.maximumPrivacySummaryCharacters)
        XCTAssertThrowsError(try Review47AppStoreMetadata(
            ageRating: 4, privacySummary: over,
            privacyPolicyURL: URL(string: "https://publikhq.com/legal/privacy")!,
            supportContact: try Review47ContactMethod(kind: "email", value: "support@publikhq.com"),
            reportContact: try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
        ))
        XCTAssertNoThrow(try Review47AppStoreMetadata(
            ageRating: 4, privacySummary: atLimit,
            privacyPolicyURL: URL(string: "https://publikhq.com/legal/privacy")!,
            supportContact: try Review47ContactMethod(kind: "email", value: "support@publikhq.com"),
            reportContact: try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
        ))
    }

    func testControlCharactersInAPrivacySummaryAreRejected() {
        for bad in ["line one\nline two", "tab\there", "\u{0000}null", "\u{007f}del"] {
            XCTAssertThrowsError(try Review47AppStoreMetadata(
                ageRating: 4, privacySummary: bad,
                privacyPolicyURL: URL(string: "https://publikhq.com/legal/privacy")!,
                supportContact: try Review47ContactMethod(kind: "email", value: "support@publikhq.com"),
                reportContact: try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
            ), "expected rejection for \(bad.debugDescription)")
        }
    }

    func testMalformedEmailAddressesAreRejectedWithoutCrashing() {
        for value in ["not-an-email", "a@b", "a b@example.com", "a@@example.com", ""] {
            XCTAssertThrowsError(try Review47ContactMethod(kind: "email", value: value))
        }
    }

    func testAnUnknownContactKindIsRejected() {
        XCTAssertThrowsError(try Review47ContactMethod(kind: "phone", value: "+1-555-0100")) { error in
            XCTAssertEqual(error as? Review47MetadataError, .invalidContactKind("phone"))
        }
    }

    func testWireDecodeRoundTripsAValidJSONObjectAndRejectsAWrongKindOrVersion() throws {
        let json = """
        {
          "kind": "iris.mobile-shell.app-store-metadata",
          "version": 1,
          "ageRating": 9,
          "privacySummary": "Nut AI keeps meal logs on this device only.",
          "privacyPolicyUrl": "https://publikhq.com/legal/privacy",
          "supportContact": { "kind": "email", "value": "support@publikhq.com" },
          "reportContact": { "kind": "email", "value": "report@publikhq.com" }
        }
        """
        let wire = try JSONDecoder().decode(Review47AppStoreMetadataWire.self, from: Data(json.utf8))
        let metadata = try Review47AppStoreMetadata(wire: wire)
        XCTAssertEqual(metadata.ageRating, 9)
        XCTAssertEqual(metadata.supportContact, .email("support@publikhq.com"))

        let wrongKind = try JSONDecoder().decode(
            Review47AppStoreMetadataWire.self,
            from: Data(json.replacingOccurrences(of: "iris.mobile-shell.app-store-metadata", with: "something-else").utf8)
        )
        XCTAssertThrowsError(try Review47AppStoreMetadata(wire: wrongKind)) { error in
            XCTAssertEqual(error as? Review47MetadataError, .invalidKind("something-else"))
        }
    }
}
