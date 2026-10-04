import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeKeepCountPolicyTests: XCTestCase {
    func testChoicesHaveStableRawValuesDefaultAndCodableRoundTrip() throws {
        // MUTATION: swapping stable raw values or making keep-all look finite breaks the public persisted choice contract.
        XCTAssertEqual(VersionsKeptPerApp.allCases.map(\.rawValue), ["2", "3", "5", "all"])
        XCTAssertEqual(VersionsKeptPerApp.keepTwo.count, 2)
        XCTAssertEqual(VersionsKeptPerApp.keepThree.count, 3)
        XCTAssertEqual(VersionsKeptPerApp.keepFive.count, 5)
        XCTAssertNil(VersionsKeptPerApp.keepAll.count)
        XCTAssertEqual(VersionsKeptPerApp(rawValue: "2"), .keepTwo)
        for choice in VersionsKeptPerApp.allCases {
            XCTAssertEqual(try JSONDecoder().decode(VersionsKeptPerApp.self, from: JSONEncoder().encode(choice)), choice)
        }
    }

    func testFreshPreferencesReadAsTwoWithoutWritingAnotherChoice() async throws {
        // SPEC check 1. A fresh preference suite is the independent default-setting world.
        // MUTATION: defaulting to an unbounded or non-two value changes the public readback.
        let suite = "kcp-default-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, defaults: preferences)
        let selected = await coordinator.versionKeepCount()
        XCTAssertEqual(selected, .keepTwo)
        XCTAssertNil(preferences.object(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey), "reading the default must not persist an invented value")
    }

    func testReferenceModelMatchesGeneratedHistoriesAndReportsSeedOnFailure() {
        // SPEC 2.5 and checks 6 to 9. Each seed represents a distinct ledger snapshot.
        // MUTATION: ignoring K or consuming slots for protected roles diverges from the independent table model.
        for seed in [11, 29, 47, 83, 101, 211, 509, 997, 2029, 4093, 8209, 12289, 16381, 20483, 24571, 28657, 32749, 36857, 40961, 45007] {
            var random = KCPGenerator(seed: UInt64(seed))
            for sample in 0..<20 {
                let count = 1 + random.next(12)
                let revisions = (0..<count).map { i in
                    NativeStorageRetentionPolicy.RevisionFact(
                        revisionId: String(format: "rev-%02d-%04d", random.next(4), i),
                        baseRevisionId: i == 0 ? nil : String(format: "rev-%02d-%04d", 0, i - 1),
                        createdAt: String(format: "2026-%02d-%02d", 1 + random.next(12), 1 + random.next(28))
                    )
                }
                let ids = revisions.map(\.revisionId)
                let current = ids.last
                let fallback = ids.dropLast().last
                let pinned = ids.filter { _ in random.next(5) == 0 }.prefix(2).map { $0 }
                let local = Set(ids.filter { _ in random.next(6) == 0 })
                let offered = Set(ids.filter { _ in random.next(4) != 0 })
                let keep = [1, 2, 3, 5, nil][random.next(5)]
                let expected = KCPReference.retained(
                    facts: revisions, ids: ids, current: current, fallback: fallback, pinned: pinned,
                    local: local, offered: offered, keepCount: keep
                )
                let actual = NativeStorageRetentionPolicy.retainedRevisionIds(
                    revisions: revisions, currentRevisionId: current, fallbackRevisionId: fallback,
                    pinnedRevisionIds: pinned, localOnlyRevisionIds: local,
                    downloadableRevisionIds: offered, keepCount: keep
                )
                XCTAssertEqual(actual, expected, "seed=\(seed), sample=\(sample), K=\(String(describing: keep)), ids=\(ids)")
            }
        }
    }

    func testProtectedRolesSurviveKOneAndTiedHistoryUsesRevisionIdOrder() {
        // SPEC check 9. K=1 is a policy adversary, never a saved choice.
        // MUTATION: charging pins, pending, or unavailable revisions to K drops a required protected id.
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let revisions = ids.enumerated().map {
            NativeStorageRetentionPolicy.RevisionFact(revisionId: $0.element, baseRevisionId: $0.offset == 0 ? nil : ids[$0.offset - 1], createdAt: "same")
        }
        let retained = NativeStorageRetentionPolicy.retainedRevisionIds(
            revisions: revisions, currentRevisionId: "g", fallbackRevisionId: "f",
            pinnedRevisionIds: ["a", "b"], localOnlyRevisionIds: ["c"],
            downloadableRevisionIds: Set(ids), keepCount: 1
        )
        XCTAssertEqual(retained, Set(["a", "b", "c", "f", "g", "h"]))

        let tied = ["z", "a", "m"].map { NativeStorageRetentionPolicy.RevisionFact(revisionId: $0, baseRevisionId: nil, createdAt: "same") }
        let first = NativeStorageRetentionPolicy.retainedRevisionIds(revisions: tied, currentRevisionId: "z", fallbackRevisionId: nil, pinnedRevisionIds: [], localOnlyRevisionIds: [], downloadableRevisionIds: Set(["a", "m", "z"]), keepCount: 2)
        let reversed = NativeStorageRetentionPolicy.retainedRevisionIds(revisions: tied.reversed(), currentRevisionId: "z", fallbackRevisionId: nil, pinnedRevisionIds: [], localOnlyRevisionIds: [], downloadableRevisionIds: Set(["a", "m", "z"]), keepCount: 2)
        XCTAssertEqual(first, Set(["z", "m"]))
        XCTAssertEqual(reversed, first)
    }

    func testPendingUsesNewestChildOfCurrentAndRevisionIdBreaksEqualTimeTie() {
        // SPEC check 9. A staged package is a real pending child of current C; input order is reversed on the second call.
        // MUTATION: choosing first input, ignoring pending, or choosing the wrong equal-time id drops P2 despite K=1.
        let facts = [
            NativeStorageRetentionPolicy.RevisionFact(revisionId: "C", baseRevisionId: "F", createdAt: "2026-09-28T00:00:00Z"),
            NativeStorageRetentionPolicy.RevisionFact(revisionId: "F", baseRevisionId: nil, createdAt: "2026-09-27T00:00:00Z"),
            NativeStorageRetentionPolicy.RevisionFact(revisionId: "P1", baseRevisionId: "C", createdAt: "2026-09-30T00:00:00Z"),
            NativeStorageRetentionPolicy.RevisionFact(revisionId: "P2", baseRevisionId: "C", createdAt: "2026-09-30T00:00:00Z")
        ]
        func retained(_ input: [NativeStorageRetentionPolicy.RevisionFact]) -> Set<String> {
            NativeStorageRetentionPolicy.retainedRevisionIds(revisions: input, currentRevisionId: "C", fallbackRevisionId: "F", pinnedRevisionIds: [], localOnlyRevisionIds: [], downloadableRevisionIds: Set(["C", "F", "P1", "P2"]), keepCount: 1)
        }
        XCTAssertEqual(retained(facts), Set(["C", "F", "P2"]))
        XCTAssertEqual(retained(Array(facts.reversed())), Set(["C", "F", "P2"]))
        let changedBase = facts.map { fact in
            NativeStorageRetentionPolicy.RevisionFact(revisionId: fact.revisionId, baseRevisionId: fact.revisionId == "P2" ? "F" : fact.baseRevisionId, createdAt: fact.createdAt)
        }
        XCTAssertEqual(retained(changedBase), Set(["C", "F", "P1"]))
    }
}

private struct KCPGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 32) % UInt64(upperBound))
    }
}

private enum KCPReference {
    // Independent SPEC 2.5 model. Pending is derived from generated facts, never accepted from the product result.
    static func retained(facts: [NativeStorageRetentionPolicy.RevisionFact], ids: [String], current: String?, fallback: String?, pinned: [String], local: Set<String>, offered: Set<String>, keepCount: Int?) -> Set<String> {
        let known = Set(ids)
        var result = Set([current, fallback].compactMap { $0 }.filter(known.contains))
        result.formUnion(pinned.filter(known.contains))
        result.formUnion(local)
        result.formUnion(known.subtracting(offered))
        let pending = facts.filter { $0.baseRevisionId == current && $0.revisionId != current }
            .sorted { $0.createdAt == $1.createdAt ? $0.revisionId > $1.revisionId : $0.createdAt > $1.createdAt }.first?.revisionId
        if let pending { result.insert(pending) }
        guard let keepCount else { return known }
        let slots = max(0, keepCount - result.intersection(Set([current, fallback].compactMap { $0 })).count)
        let order = facts.sorted { $0.createdAt == $1.createdAt ? $0.revisionId < $1.revisionId : $0.createdAt < $1.createdAt }.map(\.revisionId)
        let eligibleNewestFirst = order.reversed().filter { offered.contains($0) && !result.contains($0) }
        result.formUnion(eligibleNewestFirst.prefix(slots))
        return result
    }
}
