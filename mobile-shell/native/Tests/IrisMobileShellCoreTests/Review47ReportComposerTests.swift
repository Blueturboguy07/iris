import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47, Guideline 4.7.1's "mechanism to
/// report content". Every assertion here is on the compose target's exact
/// bytes with no I/O of any kind (no URLSession, no mail framework): the
/// oracle is "what URL would open", independent of Review47ReportComposer's
/// own implementation choices.
final class Review47ReportComposerTests: XCTestCase {
    func testComposeReportForAnEmailContactBuildsAnExactMailtoURLWithNoNetwork() throws {
        let contact = try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
        let target = Review47ReportComposer.composeReport(
            for: contact,
            appDisplayName: "Nut AI",
            appId: "publik.nut-ai"
        )
        XCTAssertEqual(target.kind, .mail)
        XCTAssertEqual(target.url.scheme, "mailto")
        let string = target.url.absoluteString
        XCTAssertTrue(string.hasPrefix("mailto:report@publikhq.com?"), string)
        // ":" and "(" "/" ")" are RFC 3986 query sub-delims/pchars and stay
        // literal under CharacterSet.urlQueryAllowed; only the delimiters
        // this composer reserves ("&", "=") and whitespace are encoded.
        XCTAssertTrue(string.contains("subject=Report:%20Nut%20AI"), string)
        XCTAssertTrue(string.contains("body=App:%20Nut%20AI%20(publik.nut-ai)"), string)
    }

    func testComposeSupportRequestUsesADifferentSubjectPrefixThanReport() throws {
        let contact = try Review47ContactMethod(kind: "email", value: "support@publikhq.com")
        let target = Review47ReportComposer.composeSupportRequest(
            for: contact,
            appDisplayName: "Kneecap",
            appId: "publik.kneecap"
        )
        XCTAssertTrue(target.url.absoluteString.contains("subject=Support%20request:%20Kneecap"), target.url.absoluteString)
    }

    func testComposeReportForAUrlContactReturnsThatExactURLUnchanged() throws {
        let contact = try Review47ContactMethod(kind: "url", value: "https://publikhq.com/report/nut-ai")
        let target = Review47ReportComposer.composeReport(for: contact, appDisplayName: "Nut AI", appId: "publik.nut-ai")
        XCTAssertEqual(target.kind, .webURL)
        XCTAssertEqual(target.url, URL(string: "https://publikhq.com/report/nut-ai")!)
    }

    // A display name with characters that need percent-encoding (space,
    // ampersand, parentheses) must not corrupt the query string structure:
    // the composed URL must still parse back to exactly two query items.
    func testAHostileOrPunctuatedDisplayNameCannotBreakTheQueryStringStructure() throws {
        let contact = try Review47ContactMethod(kind: "email", value: "report@publikhq.com")
        let target = Review47ReportComposer.composeReport(
            for: contact,
            appDisplayName: "Nut & AI (beta)?subject=hijacked",
            appId: "publik.nut-ai"
        )
        let components = URLComponents(url: target.url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        XCTAssertEqual(queryItems.count, 2, "a crafted display name must not inject extra query items")
        XCTAssertEqual(queryItems.first { $0.name == "subject" }?.value, "Report: Nut & AI (beta)?subject=hijacked")
    }

    func testMailtoURLBuilderNeverProducesANilURLForValidatedInput() throws {
        for address in ["a@b.co", "very.long.local.part@sub.domain.example.co.uk"] {
            let url = Review47ReportComposer.mailtoURL(address: address, subject: "s", body: "b")
            XCTAssertEqual(url.scheme, "mailto")
        }
    }
}
