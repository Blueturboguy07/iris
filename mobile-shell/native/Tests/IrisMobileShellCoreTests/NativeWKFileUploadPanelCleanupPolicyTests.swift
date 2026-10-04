import XCTest
@testable import IrisMobileShellCore

/// Pure-decision coverage for `NativeWKFileUploadPanelCleanupPolicy`
/// (round5/mobile-integrator-B1, WKFileUploadPanel temp-copy cleanup). No
/// filesystem I/O here -- that is `NativeWKFileUploadPanelTempCleanup`
/// (Host module, exercised by the App-level
/// `NativeWKFileUploadPanelCleanupTests.swift` and its standalone
/// scratch-mirror mutation run; see that file's doc comment). This file
/// only proves the `Entry`-array decision function itself, in-process,
/// under `swift test`.
final class NativeWKFileUploadPanelCleanupPolicyTests: XCTestCase {
    private typealias Entry = NativeWKFileUploadPanelCleanupPolicy.Entry

    func testMatchesOnlyTheExactWebKitPrefix() {
        let now = Date()
        let entries = [
            Entry(name: "WKFileUploadPanel-abc", createdAt: now),
            Entry(name: "wkfileuploadpanel-lowercase", createdAt: now),
            Entry(name: "SomeOtherApp-WKFileUploadPanel-suffix", createdAt: now),
            Entry(name: "Users-Own-Photo.jpg", createdAt: now),
        ]
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: entries, sessionStartedAt: now.addingTimeInterval(-1), now: now
        )
        XCTAssertEqual(deleted, ["WKFileUploadPanel-abc"])
    }

    func testSameSessionEntryIsDeletedRegardlessOfAge() {
        let sessionStart = Date()
        let entry = Entry(name: "WKFileUploadPanel-created-after-session-start", createdAt: sessionStart.addingTimeInterval(5))
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: [entry], sessionStartedAt: sessionStart, now: sessionStart.addingTimeInterval(5)
        )
        XCTAssertEqual(deleted, [entry.name])
    }

    func testOlderThanSessionAndNotYetStaleSurvives() {
        let sessionStart = Date()
        let now = sessionStart.addingTimeInterval(60)
        // Created 2 minutes before the session started, and well under the
        // stale threshold: not this session's own copy, not yet an orphan.
        let entry = Entry(name: "WKFileUploadPanel-older-not-stale", createdAt: sessionStart.addingTimeInterval(-120))
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: [entry], sessionStartedAt: sessionStart, now: now, staleAfterSeconds: 900
        )
        XCTAssertTrue(deleted.isEmpty)
    }

    func testStaleOrphanIsDeletedEvenWithNoLiveSession() {
        let now = Date()
        let entry = Entry(name: "WKFileUploadPanel-orphan", createdAt: now.addingTimeInterval(-1000))
        // .distantFuture as sessionStartedAt is exactly what
        // `NativeWKFileUploadPanelTempCleanup.sweepOrphans` passes: no
        // live session exists, so only the stale-backstop branch can fire.
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: [entry], sessionStartedAt: .distantFuture, now: now, staleAfterSeconds: 900
        )
        XCTAssertEqual(deleted, [entry.name])
    }

    func testFreshEntryNeverDeletedWithNoLiveSession() {
        let now = Date()
        let entry = Entry(name: "WKFileUploadPanel-fresh", createdAt: now.addingTimeInterval(-10))
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: [entry], sessionStartedAt: .distantFuture, now: now, staleAfterSeconds: 900
        )
        XCTAssertTrue(deleted.isEmpty, "a fresh entry may still belong to a session genuinely in progress")
    }

    func testStaleBoundaryIsInclusive() {
        let now = Date()
        let entry = Entry(name: "WKFileUploadPanel-exact-boundary", createdAt: now.addingTimeInterval(-900))
        let deleted = NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: [entry], sessionStartedAt: .distantFuture, now: now, staleAfterSeconds: 900
        )
        XCTAssertEqual(deleted, [entry.name])
    }

    func testManyEntriesMixedOutcomesInOneCall() {
        let sessionStart = Date()
        let now = sessionStart.addingTimeInterval(3)
        let entries = [
            Entry(name: "WKFileUploadPanel-this-session-1", createdAt: sessionStart.addingTimeInterval(1)),
            Entry(name: "WKFileUploadPanel-this-session-2", createdAt: sessionStart.addingTimeInterval(2)),
            Entry(name: "WKFileUploadPanel-too-old-not-stale", createdAt: sessionStart.addingTimeInterval(-30)),
            Entry(name: "not-a-panel-file", createdAt: sessionStart.addingTimeInterval(1)),
        ]
        let deleted = Set(NativeWKFileUploadPanelCleanupPolicy.entriesToDelete(
            in: entries, sessionStartedAt: sessionStart, now: now, staleAfterSeconds: 900
        ))
        XCTAssertEqual(deleted, ["WKFileUploadPanel-this-session-1", "WKFileUploadPanel-this-session-2"])
    }
}
