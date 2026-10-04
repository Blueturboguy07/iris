import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Independent-verifier regression test for unit m3-guideline47. New file
/// (does not edit any existing test file), added during adversarial
/// verification of m3-guideline47's own claim that Core "mirrors
/// mobile-shell/contracts/index.js's AppStoreMetadataV1 exactly."
///
/// Oracle: the real, independent EMAIL_PATTERN regex from
/// mobile-shell/contracts/index.js (quoted verbatim below, not re-derived
/// from Core's own implementation), not any constant this test sets itself.
/// contracts/index.js's own publisher/CLI already accepts these addresses
/// (see mobile-shell/publisher/test/review47-cli.test.mjs's "with all seven
/// Guideline 4.7 flags" case and mobile-shell/contracts/index.js's own
/// EMAIL_PATTERN), so an operator can create a real, guideline-compliant
/// descriptor carrying one. Before this fix, Core's `Review47ContactMethod`
/// rejected such a descriptor's `supportContact`/`reportContact` outright,
/// which (per Review47CatalogDescriptorTests's own
/// "testHostileAppStoreMetadataFieldsAreRejectedBeforeAnyDescriptorIsReturned")
/// makes the ENTIRE mobileShell descriptor fail to parse, not merely
/// "not listing ready": a real app becomes uninstallable on a real address a
/// publisher validated and approved.
final class Review47ContactEmailConsistencyTests: XCTestCase {
    // contracts/index.js:
    //   const EMAIL_PATTERN = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]
    //     (?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9]
    //     (?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/
    // Re-implemented here only as an independent oracle for this test, never
    // imported from Core, so this test cannot become tautological with
    // whatever Core's own regex happens to be.
    private static let contractsEmailPattern = try! NSRegularExpression(
        pattern: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
    )

    private static func contractsAccepts(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return Self.contractsEmailPattern.firstMatch(in: value, options: [], range: range) != nil
    }

    /// A real, RFC-valid, guideline-compliant support email that
    /// contracts/index.js's own EMAIL_PATTERN accepts (confirmed live
    /// against contracts/index.js's validateAppStoreMetadataV1 during
    /// verification: {"ok":true,...}), so Core's client-side re-validation
    /// must accept it too. This is not asserting a constant this test just
    /// set: it is cross-checking Core against a second, independently
    /// re-implemented copy of the publisher's own accepted charset.
    func testCoreAcceptsAnEmailLocalPartWithAnApostropheJustLikeThePublisherContractDoes() throws {
        let address = "o'brien@publikhq.com"
        XCTAssertTrue(Self.contractsAccepts(address), "sanity: the contracts-mirroring oracle itself must accept this address")
        let contact = try Review47ContactMethod(kind: "email", value: address)
        guard case .email(let stored) = contact else {
            return XCTFail("expected an email contact")
        }
        XCTAssertEqual(stored, address)
    }

    /// A second real local-part character the publisher's own EMAIL_PATTERN
    /// accepts (RFC 5322 "atext"), to show this is not a single hardcoded
    /// exception.
    func testCoreAcceptsAPlusAddressedEmailJustLikeThePublisherContractDoes() throws {
        let address = "reports+ios@publikhq.com"
        XCTAssertTrue(Self.contractsAccepts(address))
        XCTAssertNoThrow(try Review47ContactMethod(kind: "email", value: address))
    }

    /// Markup-relevant characters must still be rejected on both sides: this
    /// is not a request to loosen Core generally, only to match the
    /// publisher's own accepted charset exactly.
    func testCoreStillRejectsMarkupCharactersInAnEmailLocalPart() {
        for hostile in ["<script>@publikhq.com", "a\"b@publikhq.com", "a>b@publikhq.com"] {
            XCTAssertFalse(Self.contractsAccepts(hostile), "sanity: the oracle itself must also reject \(hostile)")
            XCTAssertThrowsError(try Review47ContactMethod(kind: "email", value: hostile))
        }
    }

    /// A domain label starting with a hyphen is rejected by the publisher's
    /// own EMAIL_PATTERN (its domain-label alternation requires an
    /// alphanumeric first character); Core must fail closed the same way,
    /// not merely "look plausible" per its own separate ad hoc rule.
    func testCoreRejectsADomainLabelStartingWithAHyphenJustLikeThePublisherContractDoes() {
        let address = "person@-example.com"
        XCTAssertFalse(Self.contractsAccepts(address), "sanity: the oracle itself must reject this domain")
        XCTAssertThrowsError(try Review47ContactMethod(kind: "email", value: address))
    }
}
