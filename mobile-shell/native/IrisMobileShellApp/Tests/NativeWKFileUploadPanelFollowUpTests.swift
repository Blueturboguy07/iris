import Foundation
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

/// Round 6, prep A: two gaps an independent verifier found in the WebKit
/// picker-copy cleanup, tested on a scratch folder with real creation dates.
///
/// 1. Timing. `cleanupAfterPick` runs when the pick finishes, but WebKit makes
///    its `WKFileUploadPanel-*` copy after the shell hands the file over, so
///    for that pick the copy does not exist yet. A follow-up sweep now runs
///    once the copy is old enough to be safe.
/// 2. Layout. WebKit's own networking process keeps its temp files in
///    `tmp/com.apple.WebKit.Networking/`; the cleanup now looks there too.
///
/// The oracle is the folder listing read back afterwards. This file compiles
/// on the Mac and on iOS, so the same bodies were run in a scratch Mac package
/// (see the round 6 prep A HANDOFF) and are registered for the App test target
/// by a pbxproj hook (HOOKS.md).
final class NativeWKFileUploadPanelFollowUpTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("wkfollow-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    /// WebKit's copies are directories on the Simulator (a real 1 MB file inside).
    @discardableResult
    private func plantCopy(_ name: String, in parent: URL? = nil, ageSeconds: TimeInterval) throws -> URL {
        let dir = (parent ?? tmp).appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1_048_576).write(to: dir.appendingPathComponent("clip.mov"))
        try fm.setAttributes([.creationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: dir.path)
        return dir
    }

    private func left(_ folder: URL? = nil) -> Set<String> {
        Set((try? fm.contentsOfDirectory(atPath: (folder ?? tmp).path)) ?? [])
    }

    private func waitForFollowUp(_ delay: TimeInterval, directory: URL) -> Int {
        let done = expectation(description: "follow-up ran")
        var removed = -1
        NativeWKFileUploadPanelTempCleanup.scheduleStaleFollowUp(after: delay, directory: directory) {
            removed = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return removed
    }

    /// The 5 minute clip: the pick finished, then WebKit made its copy, and it
    /// has sat there for 16 minutes when the follow-up looks.
    func testCopyMadeAfterThePickFinishedIsReclaimedByTheFollowUp() throws {
        let pickFinishedAt = Date()
        let removedAtFinish = NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(
            sessionStartedAt: pickFinishedAt, directory: tmp, followUpDelay: 0.2
        )
        XCTAssertEqual(removedAtFinish, 0, "the copy does not exist yet at finish")
        try plantCopy("WKFileUploadPanel-late", ageSeconds: 16 * 60)   // created after finish, old by now
        try plantCopy("WKFileUploadPanel-newer-pick", ageSeconds: 30)  // a later pick, still in use
        try Data("mine".utf8).write(to: tmp.appendingPathComponent("holiday.mov"))
        let done = expectation(description: "the scheduled follow-up ran on its own")
        // Poll the folder instead of trusting the schedule's own bookkeeping.
        DispatchQueue.global().async {
            for _ in 0..<40 {
                if !FileManager.default.fileExists(atPath: self.tmp.appendingPathComponent("WKFileUploadPanel-late").path) { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 6)
        XCTAssertEqual(left(), ["WKFileUploadPanel-newer-pick", "holiday.mov"])
    }

    func testFollowUpNeverTouchesAFreshCopyOrAnyoneElsesFile() throws {
        try plantCopy("WKFileUploadPanel-fresh", ageSeconds: 60)
        try plantCopy("Photos-export", ageSeconds: 3 * 3600)
        try plantCopy("FileSystemWritableStream-not-mine", ageSeconds: 3 * 3600)
        XCTAssertEqual(waitForFollowUp(0.05, directory: tmp), 0)
        XCTAssertEqual(left(), ["WKFileUploadPanel-fresh", "Photos-export", "FileSystemWritableStream-not-mine"])
    }

    func testOrphanIsFoundInWebKitsNetworkingFolderToo() throws {
        let networking = tmp.appendingPathComponent("com.apple.WebKit.Networking", isDirectory: true)
        try fm.createDirectory(at: networking, withIntermediateDirectories: true)
        try plantCopy("WKFileUploadPanel-nested-old", in: networking, ageSeconds: 20 * 60)
        try plantCopy("WKFileUploadPanel-nested-fresh", in: networking, ageSeconds: 20)
        try plantCopy("WKFileUploadPanel-top-old", ageSeconds: 20 * 60)
        XCTAssertEqual(NativeWKFileUploadPanelTempCleanup.sweepOrphans(directory: tmp), 2)
        XCTAssertEqual(left(networking), ["WKFileUploadPanel-nested-fresh"])
        XCTAssertEqual(left(), ["com.apple.WebKit.Networking"])
    }

    /// A folder called com.apple.WebKit.Networking that is really a link to
    /// somewhere else must not be followed out of tmp.
    func testLinkedNetworkingFolderIsNotFollowed() throws {
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("wkfollow-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: elsewhere) }
        try plantCopy("WKFileUploadPanel-not-ours", in: elsewhere, ageSeconds: 3 * 3600)
        try fm.createSymbolicLink(at: tmp.appendingPathComponent("com.apple.WebKit.Networking"), withDestinationURL: elsewhere)
        XCTAssertEqual(NativeWKFileUploadPanelTempCleanup.sweepOrphans(directory: tmp), 0)
        XCTAssertEqual(left(elsewhere), ["WKFileUploadPanel-not-ours"])
    }
}
