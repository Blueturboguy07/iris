import XCTest
@testable import IrisMobileShellCore

/// Persona tests for `NativeWritableStreamStagingCleanup` on a REAL scratch
/// directory (round5/mobile-integrator-B). The oracle is what a person would
/// still have on disk afterwards, not the policy's own arithmetic: files are
/// planted with real creation and modification dates and the directory listing
/// is read back.
final class NativeWritableStreamStagingCleanupTests: XCTestCase {
    private var dir: URL!
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var launch: Date { now.addingTimeInterval(-600) }          // this process started 10 min ago
    private var importStart: Date { now.addingTimeInterval(-300) }     // the import began 5 min ago

    override func setUpWithError() throws {
        dir = fm.temporaryDirectory.appendingPathComponent("wsc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: dir)
    }

    @discardableResult
    private func plant(_ name: String, in folder: String? = nil, created: Date, modified: Date? = nil, bytes: Int = 64) throws -> URL {
        var base = dir!
        if let folder {
            base = dir.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        let url = base.appendingPathComponent(name)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data(count: bytes)))
        try fm.setAttributes([.creationDate: created, .modificationDate: modified ?? created], ofItemAtPath: url.path)
        return url
    }

    private func left() throws -> Set<String> {
        Set(try fm.contentsOfDirectory(atPath: dir.path))
    }

    private func left(in folder: String) throws -> Set<String> {
        Set(try fm.contentsOfDirectory(atPath: dir.appendingPathComponent(folder).path))
    }

    private func sweep(referenceStart: Date? = nil) -> Int {
        NativeWritableStreamStagingCleanup.sweep(
            directory: dir, processLaunchedAt: launch,
            referenceStart: referenceStart ?? importStart, now: now, fileManager: fm
        )
    }

    /// A person who force-quit the app mid-save yesterday: the orphan from the
    /// earlier launch goes, everything that is not WebKit's staging stays.
    func testOrphanFromEarlierLaunchIsRemovedAndNothingElseIs() throws {
        let yesterday = now.addingTimeInterval(-86_400)
        try plant("FileSystemWritableStream-old-1", created: yesterday)
        try plant("FileSystemWritableStreamAbc", created: yesterday)
        try plant("WKFileUploadPanel-owned-by-another-policy", created: yesterday)
        try plant("holiday.mov", created: yesterday)
        try plant("filesystemwritablestream-lowercase", created: yesterday)
        try plant("Not-FileSystemWritableStream-suffix", created: yesterday)
        XCTAssertEqual(sweep(), 2)
        XCTAssertEqual(try left(), [
            "WKFileUploadPanel-owned-by-another-policy", "holiday.mov",
            "filesystemwritablestream-lowercase", "Not-FileSystemWritableStream-suffix",
        ])
    }

    /// A slow save that belongs to the running import must not be cut off,
    /// even when it has been quiet a few minutes.
    func testStreamCreatedDuringTheCurrentImportSurvives() throws {
        try plant("FileSystemWritableStream-live", created: now.addingTimeInterval(-120), modified: now.addingTimeInterval(-100))
        XCTAssertEqual(sweep(), 0)
        XCTAssertEqual(try left(), ["FileSystemWritableStream-live"])
    }

    /// A very long import (over 2 hours): a stream created inside it and idle
    /// for more than 30 minutes is still not this sweep's to judge, because it
    /// was created after the import began. This separates the two proofs.
    /// (APFS clamps a creation date to the earliest modification date, so an
    /// "idle" file is made idle by moving `now` forward, as it happens in life.)
    func testCreatedAfterImportStartSurvivesEvenWhenIdleForHours() throws {
        let created = now.addingTimeInterval(-200)
        try plant("FileSystemWritableStream-long-import", created: created)
        let later = now.addingTimeInterval(7_200)
        let removed = NativeWritableStreamStagingCleanup.sweep(
            directory: dir, processLaunchedAt: launch, referenceStart: importStart, now: later, fileManager: fm
        )
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try left(), ["FileSystemWritableStream-long-import"])
    }

    /// Made this launch, before the import, idle 40 minutes: abandoned, goes.
    func testThisLaunchStreamIdleLongAndOlderThanImportIsRemoved() throws {
        let importStartLate = now.addingTimeInterval(-60)
        let created = now.addingTimeInterval(-3_000)
        let launchEarly = now.addingTimeInterval(-4_000)
        try plant("FileSystemWritableStream-abandoned", created: created, modified: now.addingTimeInterval(-2_400))
        let removed = NativeWritableStreamStagingCleanup.sweep(
            directory: dir, processLaunchedAt: launchEarly, referenceStart: importStartLate, now: now, fileManager: fm
        )
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try left(), [])
    }

    /// Made this launch, before the import, but written to 5 minutes ago: keep.
    func testThisLaunchStreamRecentlyWrittenSurvives() throws {
        let launchEarly = now.addingTimeInterval(-4_000)
        try plant("FileSystemWritableStream-recent", created: now.addingTimeInterval(-3_000), modified: now.addingTimeInterval(-300))
        let removed = NativeWritableStreamStagingCleanup.sweep(
            directory: dir, processLaunchedAt: launchEarly, referenceStart: now.addingTimeInterval(-60), now: now, fileManager: fm
        )
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try left(), ["FileSystemWritableStream-recent"])
    }

    /// The launch sweep passes .distantPast: only an earlier launch's orphans go.
    func testLaunchSweepNeverTouchesThisLaunchsFiles() throws {
        try plant("FileSystemWritableStream-prev", created: launch.addingTimeInterval(-10), modified: launch.addingTimeInterval(-10))
        try plant("FileSystemWritableStream-now", created: launch.addingTimeInterval(30))
        XCTAssertEqual(sweep(referenceStart: .distantPast), 1)
        XCTAssertEqual(try left(), ["FileSystemWritableStream-now"])
    }

    /// The user's own data can be reached by name from a link. It must not be
    /// followed: a symlink named like a staging file is skipped, and its target
    /// survives, and a directory of that name (with content) survives too.
    func testSymlinkAndDirectoryWithStagingNameAreNeverDeleted() throws {
        let precious = dir.appendingPathComponent("precious-user-file.txt")
        XCTAssertTrue(fm.createFile(atPath: precious.path, contents: Data("keep".utf8)))
        try fm.setAttributes([.creationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: precious.path)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("FileSystemWritableStream-link"), withDestinationURL: precious)
        let folder = dir.appendingPathComponent("FileSystemWritableStream-dir", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("child.txt"))
        try fm.setAttributes([.creationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: folder.path)
        XCTAssertEqual(sweep(), 0)
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("child.txt").path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: dir.appendingPathComponent("FileSystemWritableStream-link").path))
    }

    /// A missing or unreadable directory is a quiet no-op, never a crash.
    func testMissingDirectoryIsANoOp() {
        let gone = dir.appendingPathComponent("does-not-exist")
        XCTAssertEqual(NativeWritableStreamStagingCleanup.sweep(directory: gone, referenceStart: .distantPast), 0)
    }

    /// A second sweep right after the first finds nothing more to do.
    func testSweepIsIdempotent() throws {
        try plant("FileSystemWritableStream-a", created: now.addingTimeInterval(-86_400))
        XCTAssertEqual(sweep(), 1)
        XCTAssertEqual(sweep(), 0)
    }

    /// The kernel launch time is real: in the past, and not absurdly old.
    func testProcessLaunchTimeIsPlausible() {
        let t = NativeWritableStreamStagingCleanup.currentProcessLaunchedAt()
        XCTAssertLessThanOrEqual(t, Date())
        XCTAssertGreaterThan(t, Date().addingTimeInterval(-86_400))
    }

    // MARK: real container layout (round 6, verifier finding on integrator B)

    private let networking = "com.apple.WebKit.Networking"

    /// The one real piece of evidence: the Simulator container held a 154,686
    /// byte regular file `FileSystemWritableStreamazvI3G` inside
    /// `tmp/com.apple.WebKit.Networking/`, days old. The launch sweep
    /// (reference .distantPast) must reclaim it, and the folder stays.
    func testRealLayoutOrphanInWebKitNetworkingFolderIsRemovedAtLaunch() throws {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let f = try plant("FileSystemWritableStreamazvI3G", in: networking, created: threeDaysAgo, bytes: 154_686)
        XCTAssertEqual(try fm.attributesOfItem(atPath: f.path)[.size] as? Int, 154_686)
        XCTAssertEqual(sweep(referenceStart: .distantPast), 1)
        XCTAssertEqual(try left(in: networking), [])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(networking).path), "the WebKit folder itself must stay")
    }

    /// The picker-finish sweep (reference = the finished import's start) also
    /// reaches the nested folder, and still spares what belongs to a live write.
    func testNestedFolderFollowsTheSameProofsAsTopLevel() throws {
        let yesterday = now.addingTimeInterval(-86_400)
        try plant("FileSystemWritableStream-old", in: networking, created: yesterday)
        try plant("FileSystemWritableStream-live", in: networking, created: now.addingTimeInterval(-120), modified: now.addingTimeInterval(-100))
        try plant("SomethingElseWebKitOwns", in: networking, created: yesterday)
        try plant("WKFileUploadPanel-not-ours-here", in: networking, created: yesterday)
        try plant("FileSystemWritableStream-top", created: yesterday)
        XCTAssertEqual(sweep(), 2)
        XCTAssertEqual(try left(in: networking), ["FileSystemWritableStream-live", "SomethingElseWebKitOwns", "WKFileUploadPanel-not-ours-here"])
        XCTAssertEqual(try left().subtracting([networking]), [])
    }

    /// Only the exact one-level WebKit folder is scanned. Same-named files in
    /// any other folder, or one level deeper, are somebody else's data.
    func testOtherAndDeeperFoldersAreNeverScanned() throws {
        let old = now.addingTimeInterval(-3 * 86_400)
        try plant("FileSystemWritableStream-x", in: "someone-elses-folder", created: old)
        try plant("FileSystemWritableStream-y", in: "\(networking)/deeper", created: old)
        XCTAssertEqual(sweep(referenceStart: .distantPast), 0)
        XCTAssertEqual(try left(in: "someone-elses-folder"), ["FileSystemWritableStream-x"])
        XCTAssertEqual(try left(in: "\(networking)/deeper"), ["FileSystemWritableStream-y"])
    }

    /// A link named like WebKit's folder must not be followed to reach data
    /// outside the temp directory.
    func testNestedFolderThatIsASymlinkIsNotFollowed() throws {
        let outside = fm.temporaryDirectory.appendingPathComponent("wsc-outside-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let precious = outside.appendingPathComponent("FileSystemWritableStream-precious")
        XCTAssertTrue(fm.createFile(atPath: precious.path, contents: Data("keep".utf8)))
        try fm.setAttributes([.creationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: precious.path)
        try fm.createSymbolicLink(at: dir.appendingPathComponent(networking), withDestinationURL: outside)
        XCTAssertEqual(sweep(referenceStart: .distantPast), 0)
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
    }

    /// A stream file name that is a directory or a symlink inside the WebKit
    /// folder stays, like at the top level.
    func testDirectoryAndSymlinkWithStagingNameInsideNestedFolderSurvive() throws {
        let old = now.addingTimeInterval(-86_400)
        let folder = dir.appendingPathComponent(networking, isDirectory: true)
        try fm.createDirectory(at: folder.appendingPathComponent("FileSystemWritableStream-dir"), withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("FileSystemWritableStream-dir/child.txt"))
        try fm.setAttributes([.creationDate: old], ofItemAtPath: folder.appendingPathComponent("FileSystemWritableStream-dir").path)
        let target = try plant("keep-me.txt", created: old)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("FileSystemWritableStream-link"), withDestinationURL: target)
        XCTAssertEqual(sweep(referenceStart: .distantPast), 0)
        XCTAssertTrue(fm.fileExists(atPath: target.path))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("FileSystemWritableStream-dir/child.txt").path))
    }

    /// A media import matrix leaves many big files there; a person's tmp size
    /// afterwards must return to the baseline (the bytes, not just the names).
    func testTempBytesReturnToBaselineAfterAMatrixOfNestedOrphans() throws {
        let old = now.addingTimeInterval(-2 * 86_400)
        try plant("keep.bin", created: old, bytes: 1_000)
        let baseline = try treeBytes()
        for i in 0..<6 { try plant("FileSystemWritableStream\(i)", in: networking, created: old, bytes: 200_000) }
        XCTAssertGreaterThan(try treeBytes(), baseline + 1_000_000)
        XCTAssertEqual(sweep(referenceStart: .distantPast), 6)
        XCTAssertEqual(try treeBytes(), baseline)
    }

    private func treeBytes() throws -> Int {
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in en {
            let v = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v.isRegularFile == true { total += v.fileSize ?? 0 }
        }
        return total
    }
}
