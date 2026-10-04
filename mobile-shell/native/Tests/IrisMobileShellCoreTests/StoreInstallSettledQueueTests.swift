import Foundation
import XCTest
@testable import IrisMobileShellCore

/// MA2 hook 1c (round 6): a fresh install leads Recently used. The person: six
/// apps, three opened over the week; they install a seventh from Browse while
/// My apps is not on screen, then open My apps. The seventh must be the first
/// tile. The expected order is written here by hand.
final class StoreInstallSettledQueueTests: XCTestCase {
    private let base = ISO8601DateFormatter().date(from: "2026-09-28T12:00:00Z")!

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date)
    }

    private func input(_ i: Int) -> MyAppsAppInput {
        MyAppsAppInput(identity: "app\(i)::p\(i)", originalName: "App \(i)", descriptionLine: "", categoryIds: [],
                       sizeBytes: 1000, hasUpdate: false, isBlocked: false, hasCatalogSlug: true)
    }

    /// The week: apps 0, 1, 2 opened (2 most recently); 3, 4, 5 never opened.
    private func arrangementAfterAWeek() throws -> MyAppsArrangement {
        var a = MyAppsArrangement.empty
        for (i, hours) in [(0, 1), (1, 2), (2, 3)] {
            a = try require(MyAppsOrganizationReducer.apply(.recordOpened(identity: "app\(i)::p\(i)", at: iso(base.addingTimeInterval(TimeInterval(hours * 3600)))), to: a)).arrangement
        }
        return a
    }

    private func recents(_ arrangement: MyAppsArrangement, apps: Int) -> [String] {
        let out = MyAppsScreen.sections(input: .init(apps: (0..<apps).map(input), categories: [], arrangement: arrangement, sort: .groups, query: "", now: base.addingTimeInterval(86_400)))
        return out.recentlyUsed.map(\.identity)
    }

    func testFreshInstallLeadsRecentlyUsedAfterTheQueueIsDrained() throws {
        var arrangement = try arrangementAfterAWeek()
        XCTAssertEqual(recents(arrangement, apps: 7), ["app2::p2", "app1::p1", "app0::p0"], "before the install, only opened apps are there")

        var queue = StoreInstallSettledQueue()
        queue.settled(identity: "app6::p6", at: base.addingTimeInterval(5 * 3600))
        for record in queue.drain() {
            arrangement = try require(MyAppsOrganizationReducer.apply(.recordInstalled(identity: record.identity, at: iso(record.settledAt)), to: arrangement)).arrangement
        }
        XCTAssertEqual(recents(arrangement, apps: 7), ["app6::p6", "app2::p2", "app1::p1", "app0::p0"])
    }

    /// The install happened long ago while another tab was showing; the moment
    /// it settled, not the moment My apps appeared, decides its place.
    func testEarlierInstallKeepsItsOwnMomentNotTheMomentOfDraining() throws {
        var arrangement = try arrangementAfterAWeek()
        var queue = StoreInstallSettledQueue()
        queue.settled(identity: "app6::p6", at: base.addingTimeInterval(2.5 * 3600)) // between app1 (2h) and app2 (3h)
        for record in queue.drain() {
            arrangement = try require(MyAppsOrganizationReducer.apply(.recordInstalled(identity: record.identity, at: iso(record.settledAt)), to: arrangement)).arrangement
        }
        XCTAssertEqual(recents(arrangement, apps: 7), ["app2::p2", "app6::p6", "app1::p1", "app0::p0"])
    }

    func testDrainEmptiesTheQueueAndReturnsOldestFirst() {
        var queue = StoreInstallSettledQueue()
        queue.settled(identity: "b", at: base.addingTimeInterval(20))
        queue.settled(identity: "a", at: base.addingTimeInterval(10))
        queue.settled(identity: "c", at: base.addingTimeInterval(30))
        XCTAssertEqual(queue.drain().map(\.identity), ["a", "b", "c"])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.drain(), [])
    }

    /// Installing the same app twice keeps one note, the later moment.
    func testSameAppTwiceKeepsTheLaterMoment() {
        var queue = StoreInstallSettledQueue()
        queue.settled(identity: "a", at: base)
        queue.settled(identity: "a", at: base.addingTimeInterval(60))
        XCTAssertEqual(queue.drain(), [.init(identity: "a", settledAt: base.addingTimeInterval(60))])
    }

    /// Nothing is dropped while My apps is not showing: notes pile up until drained.
    func testNothingIsLostWhileNobodyDrains() {
        var queue = StoreInstallSettledQueue()
        for i in 0..<25 { queue.settled(identity: "app\(i)", at: base.addingTimeInterval(TimeInterval(i))) }
        XCTAssertEqual(queue.drain().count, 25)
    }
}
