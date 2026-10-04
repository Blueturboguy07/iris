import Foundation
import XCTest
@testable import IrisMobileShellCore

/// New test file for unit m3-guideline47, Guideline 4.7.5's age
/// restriction mechanism. Personas: P3 (a 12-year-old device profile) and
/// P1 (asked at most once, in plain words, never nagged again).
final class Review47AgeGateTests: XCTestCase {
    /// Boundary fake, not a mock of the unit under test: it only stores
    /// exactly what a real UserDefaults-backed store would, and every
    /// assertion below is on `Review47AgeGate`'s own decision logic.
    private actor InMemoryAgeStore: Review47DeclaredAgeStore {
        private var age: Int?
        private var asked = false

        func declaredMinimumAge() async -> Int? { age }
        func setDeclaredMinimumAge(_ age: Int?) async { self.age = age }
        func hasAskedOnce() async -> Bool { asked }
        func setHasAskedOnce(_ value: Bool) async { asked = value }
    }

    // RC-02 (apple-compliance/DECISIONS.md OD-01): the shell is rated 13+.
    // The table below is written out by hand from that rule, not computed
    // from the code under test: an app at or below 13 never asks anything;
    // an app above 13 fails CLOSED when no age is declared, and otherwise
    // needs a declared age at least equal to its rating.
    func testShellRatingIsThirteenAsDecided() {
        XCTAssertEqual(Review47AppStoreMetadata.shellAgeRating, 13)
    }

    func testDecisionTableFromTheWrittenRule() {
        typealias D = Review47AgeGateDecision
        let rows: [(rating: Int?, declared: Int?, expected: D)] = [
            (nil, nil, .allowed),                           // 1 unrated, unasked
            (nil, 12, .allowed),                            // 2 unrated, young
            (4, nil, .allowed),                             // 3 low rating, unasked
            (13, nil, .allowed),                            // 4 at the shell rating, unasked
            (13, 12, .allowed),                             // 5 at the shell rating, young
            (14, nil, .restricted(appAgeRating: 14, declaredAge: nil)),   // 6 just above, unasked
            (16, nil, .restricted(appAgeRating: 16, declaredAge: nil)),   // 7 fail closed
            (16, 12, .restricted(appAgeRating: 16, declaredAge: 12)),     // 8 young
            (16, 15, .restricted(appAgeRating: 16, declaredAge: 15)),     // 9 one bucket short
            (16, 16, .allowed),                             // 10 exact boundary
            (18, 17, .restricted(appAgeRating: 18, declaredAge: 17)),     // 11 one short
            (18, 18, .allowed),                             // 12 exact boundary
            (18, 21, .allowed),                             // 13 older than needed
        ]
        for row in rows {
            XCTAssertEqual(
                Review47AgeGate.decide(appAgeRating: row.rating, declaredAge: row.declared),
                row.expected,
                "rating \(String(describing: row.rating)) declared \(String(describing: row.declared))"
            )
        }
    }

    // Persona P3: a 12-year-old profile is blocked from a 17+ app and
    // allowed a 4+ app. This exact scenario is also exercised end to end
    // through NativeWebsiteInstallFlow in Review47UniversalLinkGatingTests.
    func testA12YearOldIsBlockedFrom17PlusAndAllowed4Plus() {
        XCTAssertEqual(
            Review47AgeGate.decide(appAgeRating: 17, declaredAge: 12),
            .restricted(appAgeRating: 17, declaredAge: 12)
        )
        XCTAssertEqual(Review47AgeGate.decide(appAgeRating: 4, declaredAge: 12), .allowed)
    }

    func testOnlyAnUnratedAppIsNeverGated() {
        XCTAssertEqual(Review47AgeGate.decide(appAgeRating: nil, declaredAge: nil), .allowed)
    }

    func testTheOD02SentenceIsExactlyWhatAPersonReads() {
        XCTAssertEqual(
            Review47AgeGateCopy.message(appAgeRating: 16, declaredAge: nil),
            "This app is rated 16+. Tell Iris your age range to continue. Iris keeps this on your iPhone."
        )
        XCTAssertTrue(Review47AgeGateCopy.message(appAgeRating: 16, declaredAge: 13).contains("13+"))
    }

    func testGateEvaluateReadsTheDeclaredAgeFromItsStore() async {
        let store = InMemoryAgeStore()
        let gate = Review47AgeGate(store: store)
        let beforeDeclaring = await gate.evaluate(appAgeRating: 17)
        XCTAssertEqual(beforeDeclaring, .restricted(appAgeRating: 17, declaredAge: nil), "no declared age yet fails closed (RC-02)")
        await gate.declareMinimumAge(12)
        let afterDeclaring17Plus = await gate.evaluate(appAgeRating: 17)
        XCTAssertEqual(afterDeclaring17Plus, .restricted(appAgeRating: 17, declaredAge: 12))
        let afterDeclaring4Plus = await gate.evaluate(appAgeRating: 4)
        XCTAssertEqual(afterDeclaring4Plus, .allowed)
    }

    // Persona P1: non-technical, "gives up after two confusing screens".
    // The gate must be asked at most once, and a later declaration must
    // never silently reset `hasAskedOnce` back to false.
    func testHasAskedOnceIsStickyAfterOneDeclaration() async {
        let store = InMemoryAgeStore()
        let gate = Review47AgeGate(store: store)
        let initiallyAsked = await gate.hasAskedOnce()
        XCTAssertFalse(initiallyAsked)
        await gate.declareMinimumAge(18)
        let askedAfterFirstDeclaration = await gate.hasAskedOnce()
        XCTAssertTrue(askedAfterFirstDeclaration)
        await gate.declareMinimumAge(9)
        let askedAfterSecondDeclaration = await gate.hasAskedOnce()
        XCTAssertTrue(askedAfterSecondDeclaration, "asking again must not un-ask")
        let declaredAge = await gate.declaredMinimumAge()
        XCTAssertEqual(declaredAge, 9)
    }

    func testUserDefaultsBackedStoreRoundTripsThroughARealNamespacedSuite() async throws {
        let suiteName = "iris.review47.age-gate.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("could not create an isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsReview47AgeStore(defaults: defaults)
        let beforeAnySet = await store.declaredMinimumAge()
        XCTAssertNil(beforeAnySet)
        await store.setDeclaredMinimumAge(16)
        let afterSet = await store.declaredMinimumAge()
        XCTAssertEqual(afterSet, 16)
        await store.setDeclaredMinimumAge(nil)
        let afterClear = await store.declaredMinimumAge()
        XCTAssertNil(afterClear)
    }
}
