import Foundation
import XCTest
@testable import IrisMobileShellCore

/// RC-05 (round 6): "By Publik" on the app page and the consent sheet. A person
/// reads "By <name>" under the app name; these tests take the index row the way
/// the phone gets it (JSON off the wire, edited in this one field only) and
/// check the exact line that would be drawn. Expected strings are written here
/// by hand, not read back from the code under test.
final class StoreAppPublisherTests: XCTestCase {
    private func page1(withFirstAppPublisher value: Any?, removing: Bool = false) throws -> (PublikMobileCatalogClient, Data) {
        let publish = try CatalogPublish.fixture(3)
        let client = PublikMobileCatalogClient(transport: FakePublikServer(publish: publish))
        let body = try XCTUnwrap(publish.files[CatalogPublish.indexPath(1)])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var apps = try XCTUnwrap(object["apps"] as? [[String: Any]])
        if removing { apps[0].removeValue(forKey: "publisher") } else if let value { apps[0]["publisher"] = value }
        object["apps"] = apps
        return (client, try JSONSerialization.data(withJSONObject: object))
    }

    private func indexRow(publisher: String?) -> PublikMobileCatalogIndexAppV2 {
        PublikMobileCatalogIndexAppV2(
            slug: "kneecap", name: "Kneecap", summary: "Cut clips", categoryIds: [1],
            iconHash: String(repeating: "a", count: 16), iconURL: URL(string: "https://publikhq.com/icon.png")!,
            byteCount: 1000, ageRating: 4, updatedAt: "2026-09-28", badges: [], placement: nil, publisher: publisher
        )
    }

    /// An index published before the field existed: the page still says By Publik.
    func testOlderIndexWithNoPublisherReadsByPublik() throws {
        let (client, body) = try page1(withFirstAppPublisher: nil, removing: true)
        let page = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        XCTAssertNil(page.apps[0].publisher)
        let app = StoreApp(indexRow: page.apps[0], catalogOrder: 0)
        XCTAssertEqual(app.byLine, "By Publik")
    }

    /// A row that names its maker: the header says so, word for word.
    func testIndexRowPublisherIsShownAsByLine() throws {
        let (client, body) = try page1(withFirstAppPublisher: "Acme Studio")
        let page = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
        let app = StoreApp(indexRow: page.apps[0], catalogOrder: 0)
        XCTAssertEqual(app.publisher, "Acme Studio")
        XCTAssertEqual(app.byLine, "By Acme Studio")
    }

    /// The consent sheet builds its line from the same helper.
    func testConsentSheetLineUsesTheSameWording() {
        XCTAssertEqual(StoreApp.byLine(publisher: StoreApp.defaultPublisher), "By Publik")
        XCTAssertEqual(StoreApp.byLine(publisher: "Acme Studio"), "By Acme Studio")
    }

    /// A catalog host cannot put markup, blanks or hidden characters into the header.
    func testHostilePublisherNamesAreRefusedAtDecode() async throws {
        for bad in ["", " ", " Publik", "Publik ", "<b>Publik</b>", "Pub\nlik", "Pub\u{0}lik", String(repeating: "A", count: 81)] {
            let (client, body) = try page1(withFirstAppPublisher: bad)
            await assertCatalogError(.invalidCatalogField("apps.publisher")) {
                _ = try client.decodeCatalogIndexPageV2(body, expectedPage: 1)
            }
        }
    }

    /// Exactly 80 characters is allowed; the sheet and header never truncate a good name.
    func testEightyCharacterNameIsAccepted() throws {
        let name = String(repeating: "A", count: 80)
        let (client, body) = try page1(withFirstAppPublisher: name)
        XCTAssertEqual(try client.decodeCatalogIndexPageV2(body, expectedPage: 1).apps[0].publisher, name)
    }

    /// A blank or unsafe value that reached the model some other way still never
    /// shows: the app falls back to Publik rather than draw it.
    func testUnsafeValueInsideTheModelFallsBackToPublik() {
        XCTAssertEqual(StoreApp(indexRow: indexRow(publisher: "<i>x</i>"), catalogOrder: 0).byLine, "By Publik")
        XCTAssertEqual(StoreApp(indexRow: indexRow(publisher: nil), catalogOrder: 0).byLine, "By Publik")
    }

    /// Rows from the v1 list carry no publisher at all: still By Publik.
    func testEveryBundledSeedAppReadsByPublik() async throws {
        let bundled = await StoreCatalogSeed.bundled()
        let seed = try XCTUnwrap(bundled)
        let apps = seed.load.snapshot?.apps ?? []
        XCTAssertFalse(apps.isEmpty)
        for row in apps { XCTAssertEqual(StoreApp(indexRow: row, catalogOrder: 0).byLine, "By Publik") }
    }
}
