import Foundation
import XCTest
@testable import IrisMobileShellCore

/// RC-02 (apple-compliance/REQUIRED_CHANGES.md): the store side of the age
/// check. Persona: a 15-year-old who has never told Iris an age taps Get on
/// a 16+ app, is asked once in plain words, answers, and then sees what the
/// answer allows. Oracles are the sentences and button labels a person reads,
/// written out here, not derived from the code under test.
final class StoreAgeCheckTests: XCTestCase {
    private func app(rating: Int?) -> StoreApp {
        StoreApp(
            slug: "kneecap", name: "Kneecap", summary: "Edit clips", categoryIds: [1],
            iconHash: "abc", iconURL: nil, byteCount: 1000, ageRating: rating,
            updatedAt: "2026-09-01", badges: [], isFeatured: false, isSponsored: false,
            placementLabel: nil, catalogOrder: 0, descriptor: nil)
    }

    private func facts(_ restriction: StoreInstallFacts.Restriction) -> StoreInstallFacts {
        StoreInstallFacts(
            appName: "Kneecap", listing: .listed(revisionId: "r1", baseRevisionId: nil),
            installedRevisionId: nil, restriction: restriction, isOnline: true)
    }

    func testANeverAskedPersonSeesTheCheckYourAgeButtonForA16PlusApp() {
        let restriction = StoreRestrictionPolicy.restriction(app: app(rating: 16), isBlocked: false, declaredAge: nil)
        let state = StoreInstallMachine.state(facts: facts(restriction), activity: .idle)
        XCTAssertEqual(state.kind, .restricted)
        XCTAssertEqual(state.label, "Rated 16+ · Check your age")
        XCTAssertEqual(state.note, "This app is rated 16+. Tell Iris your age range to continue. Iris keeps this on your iPhone.")
        XCTAssertTrue(state.isActionable, "the sheet is wired: the button must be tappable")
        XCTAssertFalse(state.accessibilityValue.contains("aren't available"), "the old 'not available yet' line is gone")
        let (_, effect) = StoreInstallMachine.reduce(activity: .idle, event: .tap, facts: facts(restriction), anotherInstallRunning: false)
        XCTAssertEqual(effect, .checkAge, "tapping opens the age sheet and installs nothing")
    }

    func testAfterDeclaring16TheGetButtonAppears() {
        let restriction = StoreRestrictionPolicy.restriction(app: app(rating: 16), isBlocked: false, declaredAge: 16)
        XCTAssertEqual(restriction, .none)
        let state = StoreInstallMachine.state(facts: facts(restriction), activity: .idle)
        XCTAssertEqual(state.kind, .get)
        XCTAssertEqual(state.label, "Get")
    }

    func testDeclaring13ForA16PlusAppStillRestrictsAndSaysWhy() {
        let restriction = StoreRestrictionPolicy.restriction(app: app(rating: 16), isBlocked: false, declaredAge: 13)
        let state = StoreInstallMachine.state(facts: facts(restriction), activity: .idle)
        XCTAssertEqual(state.kind, .restricted)
        XCTAssertEqual(state.note, "This app is rated 16+. The age set on this iPhone (13+) is below that.")
        XCTAssertTrue(state.isActionable, "a person can change their answer")
    }

    func testAppsAtOrBelowTheShellRatingNeverAsk() {
        for rating in [4, 9, 12, 13] {
            XCTAssertEqual(
                StoreRestrictionPolicy.restriction(app: app(rating: rating), isBlocked: false, declaredAge: nil), .none,
                "rated \(rating)+ is inside the shell's own 13+ rating")
        }
    }

    func testABlockedAppStaysBlockedWhateverTheAge() {
        XCTAssertEqual(StoreRestrictionPolicy.restriction(app: app(rating: 18), isBlocked: true, declaredAge: 18), .blocked)
    }
}
