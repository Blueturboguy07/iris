import XCTest
@testable import MobileUserSimKit

final class PlainLanguageTests: XCTestCase {
    func testEmptyCatalogExplanationIsNonEmptyPlainText() {
        let text = PlainLanguage.emptyCatalogExplanation()
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.lowercased().contains("error"))
    }

    func testUnsupportedCapabilitiesExplanationNamesEachFeatureInWordsNotIds() {
        let text = PlainLanguage.unsupportedCapabilitiesExplanation(
            appName: "Kneecap",
            capabilities: ["web.media.camera", "web.media.export"],
            osName: "iOS 17"
        )
        XCTAssertTrue(text.contains("Kneecap"))
        XCTAssertTrue(text.contains("the camera"))
        XCTAssertTrue(text.contains("saving exported files"))
        XCTAssertTrue(text.contains("iOS 17"))
        XCTAssertFalse(text.contains("web.media"), "raw capability ids must never leak into the plain-language text")
    }

    func testUnsupportedCapabilitiesExplanationHandlesASingleCapability() {
        let text = PlainLanguage.unsupportedCapabilitiesExplanation(
            appName: "FreeHarmony",
            capabilities: ["web.media.camera"],
            osName: "iOS 17"
        )
        XCTAssertTrue(text.contains("the camera"))
        XCTAssertFalse(text.contains(" and and "))
    }

    func testUnsupportedCapabilitiesExplanationFallsBackHonestlyForAnUnknownId() {
        let text = PlainLanguage.unsupportedCapabilitiesExplanation(
            appName: "SomeApp",
            capabilities: ["some.future.capability"],
            osName: "iOS 17"
        )
        XCTAssertTrue(text.contains("some.future.capability"), "an unmapped capability id should still be shown, not silently dropped")
    }
}
