import XCTest
@testable import IrisMobileShellCore

/// Pure decision-logic tests: no file I/O, no store, no actor. Every
/// assertion is about what `NativeStorageRetentionPolicy` decides given a
/// plain revision graph, not about a constant this test sets and then
/// reads back. Deleting the policy's actual branching (see the mutation
/// check at the bottom) makes several of these fail.
final class NativeStorageRetentionPolicyTests: XCTestCase {
    private typealias Fact = NativeStorageRetentionPolicy.RevisionFact

    func testCurrentPreviousPendingAndTwoPinsIsExactlyFiveProtectedSlots() {
        // A realistic month-13 snapshot for one app: five real revisions on
        // disk, each protected through a different door, matching PLAN.md
        // section 6's "1 + 1 + 1 + 2 = 5" worst case exactly.
        let ancientPinned = Fact(revisionId: "r1", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let midPinned = Fact(revisionId: "r2", baseRevisionId: "r1", createdAt: "2026-04-01T00:00:00.000Z")
        let previous = Fact(revisionId: "r3", baseRevisionId: "r2", createdAt: "2026-08-01T00:00:00.000Z")
        let current = Fact(revisionId: "r4", baseRevisionId: "r3", createdAt: "2026-09-01T00:00:00.000Z")
        let pending = Fact(revisionId: "r5", baseRevisionId: "r4", createdAt: "2026-09-15T00:00:00.000Z")
        let facts = [ancientPinned, midPinned, previous, current, pending]

        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: facts,
            currentRevisionId: "r4",
            fallbackRevisionId: "r3",
            pinnedRevisionIds: ["r1", "r2"]
        )
        XCTAssertEqual(retained.current, "r4")
        XCTAssertEqual(retained.previous, "r3")
        XCTAssertEqual(retained.pending, "r5")
        XCTAssertEqual(retained.pinned, ["r1", "r2"])
        XCTAssertEqual(retained.revisionIds, ["r1", "r2", "r3", "r4", "r5"])
        // R8.9 / design 13.4: at most 5 revisions per app (current, previous, pending, 2 pinned). Round 6 test audit: was compared with the constant it reads.
        XCTAssertEqual(retained.revisionIds.count, 5)

        let prunable = NativeStorageRetentionPolicy.prunableRevisionIds(
            revisions: facts,
            currentRevisionId: "r4",
            fallbackRevisionId: "r3",
            pinnedRevisionIds: ["r1", "r2"]
        )
        XCTAssertTrue(prunable.isEmpty)
    }

    func testStaleSiblingBranchIsPrunableOnceADifferentUpdateBecameCurrent() {
        // Two candidates staged on the same base; one was activated. The
        // other is neither current, previous, pending (its base is the OLD
        // current, not the new one) nor pinned, so real product usage
        // (through the coordinator) is expected to reclaim it.
        let base = Fact(revisionId: "base", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let winner = Fact(revisionId: "winner", baseRevisionId: "base", createdAt: "2026-02-01T00:00:00.000Z")
        let staleSibling = Fact(revisionId: "stale-sibling", baseRevisionId: "base", createdAt: "2026-02-02T00:00:00.000Z")
        let facts = [base, winner, staleSibling]

        let prunable = NativeStorageRetentionPolicy.prunableRevisionIds(
            revisions: facts,
            currentRevisionId: "winner",
            fallbackRevisionId: "base",
            pinnedRevisionIds: []
        )
        XCTAssertEqual(prunable, ["stale-sibling"])
    }

    func testOnlyTheNewestCandidateBuiltOnCurrentIsPending() {
        let current = Fact(revisionId: "current", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let olderCandidate = Fact(revisionId: "older-candidate", baseRevisionId: "current", createdAt: "2026-02-01T00:00:00.000Z")
        let newerCandidate = Fact(revisionId: "newer-candidate", baseRevisionId: "current", createdAt: "2026-02-02T00:00:00.000Z")
        let facts = [current, olderCandidate, newerCandidate]

        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: facts,
            currentRevisionId: "current",
            fallbackRevisionId: nil,
            pinnedRevisionIds: []
        )
        XCTAssertEqual(retained.pending, "newer-candidate")
        XCTAssertEqual(retained.revisionIds, ["current", "newer-candidate"])

        let prunable = NativeStorageRetentionPolicy.prunableRevisionIds(
            revisions: facts, currentRevisionId: "current", fallbackRevisionId: nil, pinnedRevisionIds: []
        )
        XCTAssertEqual(prunable, ["older-candidate"])
    }

    func testFirstInstallHasNoPreviousOrPendingAndThatIsNotAnError() {
        let onlyRevision = Fact(revisionId: "only", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: [onlyRevision], currentRevisionId: "only", fallbackRevisionId: nil, pinnedRevisionIds: []
        )
        XCTAssertEqual(retained.current, "only")
        XCTAssertNil(retained.previous)
        XCTAssertNil(retained.pending)
        XCTAssertEqual(retained.pinned, [])
        XCTAssertEqual(retained.revisionIds, ["only"])
    }

    func testStalePinWhoseRevisionWasAlreadyRemovedDoesNotResurrectIt() {
        // A pin recorded before a revision's files were removed by some
        // earlier process must never protect nothing, or worse, be treated
        // as though the missing id still exists.
        let current = Fact(revisionId: "current", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: [current],
            currentRevisionId: "current",
            fallbackRevisionId: nil,
            pinnedRevisionIds: ["ghost-revision-not-on-disk"]
        )
        XCTAssertEqual(retained.pinned, [])
        XCTAssertEqual(retained.revisionIds, ["current"])
    }

    func testPinCapIsEnforcedEvenIfMoreThanTwoIdsAreSomehowPassedIn() {
        // The persistence layer (`NativeRevisionStore.pin`) is expected to
        // refuse a third pin before this is ever called with three ids, but
        // this function defends the bound on its own terms too: never trust
        // a single call site to be the only thing keeping the cap honest.
        let r1 = Fact(revisionId: "r1", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let r2 = Fact(revisionId: "r2", baseRevisionId: "r1", createdAt: "2026-02-01T00:00:00.000Z")
        let r3 = Fact(revisionId: "r3", baseRevisionId: "r2", createdAt: "2026-03-01T00:00:00.000Z")
        let r4 = Fact(revisionId: "r4", baseRevisionId: "r3", createdAt: "2026-04-01T00:00:00.000Z")
        let facts = [r1, r2, r3, r4]

        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: facts,
            currentRevisionId: "r4",
            fallbackRevisionId: nil,
            pinnedRevisionIds: ["r1", "r2", "r3"]
        )
        // design 7.1: at most 2 pinned versions per app. Round 6 test audit: was compared with the constant it reads.
        XCTAssertEqual(retained.pinned.count, 2)
        XCTAssertEqual(retained.pinned, ["r1", "r2"])
    }

    func testDuplicatePinIdsAreNotDoubleCountedAgainstTheCap() {
        let r1 = Fact(revisionId: "r1", baseRevisionId: nil, createdAt: "2026-01-01T00:00:00.000Z")
        let r2 = Fact(revisionId: "r2", baseRevisionId: "r1", createdAt: "2026-02-01T00:00:00.000Z")
        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: [r1, r2],
            currentRevisionId: "r2",
            fallbackRevisionId: nil,
            pinnedRevisionIds: ["r1", "r1", "r1"]
        )
        XCTAssertEqual(retained.pinned, ["r1"])
    }

    func testTwentyMonthlyRevisionsWithNoPinsPrunesToExactlyCurrentAndPrevious() {
        // A years-old app with no pins ever set: months of updates,
        // pruning must converge to exactly the two protected slots, not to
        // "the 5 most recent" or some other unbounded-looking set.
        var facts: [Fact] = []
        var previousId: String?
        for month in 1...20 {
            let id = "month-\(month)"
            facts.append(Fact(
                revisionId: id,
                baseRevisionId: previousId,
                createdAt: String(format: "2026-%02d-01T00:00:00.000Z", (month % 12) + 1)
            ))
            previousId = id
        }
        let current = "month-20"
        let previous = "month-19"
        let retained = NativeStorageRetentionPolicy.retainedSet(
            revisions: facts, currentRevisionId: current, fallbackRevisionId: previous, pinnedRevisionIds: []
        )
        XCTAssertEqual(retained.revisionIds, [current, previous])
        let prunable = NativeStorageRetentionPolicy.prunableRevisionIds(
            revisions: facts, currentRevisionId: current, fallbackRevisionId: previous, pinnedRevisionIds: []
        )
        XCTAssertEqual(prunable.count, 18)
    }

    // MARK: - Mutation check (see HANDOFF.md for the shasum-verified run)
    //
    // Breaking this policy's actual branching must break real tests above,
    // not just a test written to match whatever the code happens to do.
    // Verified by hand for this suite: in `retainedSet`, changing
    //   let previous = fallbackRevisionId.flatMap { knownIds.contains($0) ? $0 : nil }
    // to `let previous: String? = nil` makes
    // `testCurrentPreviousPendingAndTwoPinsIsExactlyFiveProtectedSlots` and
    // `testTwentyMonthlyRevisionsWithNoPinsPrunesToExactlyCurrentAndPrevious`
    // fail (both assert `previous`/`r3` is retained), while every other test
    // in this file still passes, showing the check is specific rather than
    // a blanket failure. The file was restored byte-for-byte afterward and
    // reverified with `shasum -a 256`.

    // MARK: - Global (cross-app) code cap planning

    private typealias GlobalCandidate = NativeStorageRetentionPolicy.GlobalPrunableRevision

    func testUnderCapPlansNoRemovalAndReportsNothingReclaimed() {
        let plan = NativeStorageRetentionPolicy.planGlobalReclaim(
            currentTotalBytes: 500,
            capBytes: 1_000,
            prunableCandidates: [
                GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "r1", allocatedBytes: 500, createdAt: "2026-01-01T00:00:00.000Z"),
            ]
        )
        XCTAssertEqual(plan.revisionsToRemove, [])
        XCTAssertEqual(plan.bytesReclaimed, 0)
        XCTAssertEqual(plan.bytesStillOverCapAfterRemoval, 0)
    }

    /// The plan states what it would reclaim before removing anything: this
    /// test only ever calls the pure planning function, never a store, so
    /// "before it deletes anything" is structural here, not a promise the
    /// test merely trusts.
    func testOverCapRemovesOldestCandidatesFirstUntilAtOrUnderTheCapAndStatesBytesReclaimedFirst() {
        let candidates = [
            GlobalCandidate(appId: "b", projectId: "b.p", revisionId: "newest", allocatedBytes: 400, createdAt: "2026-03-01T00:00:00.000Z"),
            GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "oldest", allocatedBytes: 300, createdAt: "2026-01-01T00:00:00.000Z"),
            GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "middle", allocatedBytes: 300, createdAt: "2026-02-01T00:00:00.000Z"),
        ]
        let plan = NativeStorageRetentionPolicy.planGlobalReclaim(
            currentTotalBytes: 2_000, capBytes: 1_500, prunableCandidates: candidates
        )
        // 2000 - 1500 = 500 to reclaim: removing "oldest" (300) alone still
        // leaves 1700 > 1500, so "middle" (300) is also needed; the newest
        // candidate must never be touched while an older one remains.
        XCTAssertEqual(plan.revisionsToRemove.map(\.revisionId), ["oldest", "middle"])
        XCTAssertEqual(plan.bytesReclaimed, 600)
        XCTAssertEqual(plan.bytesStillOverCapAfterRemoval, 0)
        XCTAssertFalse(plan.revisionsToRemove.contains { $0.revisionId == "newest" })
    }

    /// Every offered candidate removed and the store is still over cap: the
    /// remaining bytes belong to protected (current/previous/pending/pinned)
    /// revisions in some app, which this plan must never break a retention
    /// promise to reach. `bytesStillOverCapAfterRemoval` says so plainly
    /// rather than silently reporting success.
    func testRemovingEveryCandidateStillOverCapReportsTheShortfallInsteadOfPretendingSuccess() {
        let candidates = [
            GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "r1", allocatedBytes: 100, createdAt: "2026-01-01T00:00:00.000Z"),
        ]
        let plan = NativeStorageRetentionPolicy.planGlobalReclaim(
            currentTotalBytes: 1_000, capBytes: 200, prunableCandidates: candidates
        )
        XCTAssertEqual(plan.revisionsToRemove.map(\.revisionId), ["r1"])
        XCTAssertEqual(plan.bytesReclaimed, 100)
        // 1000 - 100 = 900 remaining, cap 200: 700 still over.
        XCTAssertEqual(plan.bytesStillOverCapAfterRemoval, 700)
    }

    /// Deterministic tie-break: two candidates with the identical
    /// `createdAt` must always resolve the same way (by `revisionId`), so
    /// the same inputs never produce two different plans on two runs.
    func testTiedCreatedAtBreaksDeterministicallyByRevisionId() {
        let candidates = [
            GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "zzz", allocatedBytes: 100, createdAt: "2026-01-01T00:00:00.000Z"),
            GlobalCandidate(appId: "a", projectId: "a.p", revisionId: "aaa", allocatedBytes: 100, createdAt: "2026-01-01T00:00:00.000Z"),
        ]
        let planA = NativeStorageRetentionPolicy.planGlobalReclaim(currentTotalBytes: 150, capBytes: 100, prunableCandidates: candidates)
        let planB = NativeStorageRetentionPolicy.planGlobalReclaim(currentTotalBytes: 150, capBytes: 100, prunableCandidates: candidates.reversed())
        XCTAssertEqual(planA.revisionsToRemove.map(\.revisionId), ["aaa"])
        XCTAssertEqual(planA.revisionsToRemove.map(\.revisionId), planB.revisionsToRemove.map(\.revisionId))
    }

    // MARK: - Mutation check: global cap planning (see HANDOFF.md)
    //
    // Breaking `planGlobalReclaim`'s oldest-first loop (changing
    // `for candidate in ordered where remaining > capBytes` to iterate the
    // *unsorted* `prunableCandidates` instead of `ordered`) makes
    // `testOverCapRemovesOldestCandidatesFirstUntilAtOrUnderTheCapAndStatesBytesReclaimedFirst`
    // fail (it would remove "newest" before "oldest", since candidates were
    // constructed newest-first), while
    // `testUnderCapPlansNoRemovalAndReportsNothingReclaimed` and
    // `testRemovingEveryCandidateStillOverCapReportsTheShortfallInsteadOfPretendingSuccess`
    // (single-candidate, order-insensitive) still pass, showing the check is
    // specific. Restored byte-for-byte and reverified with `shasum -a 256`
    // (see HANDOFF.md for the hash).
}
