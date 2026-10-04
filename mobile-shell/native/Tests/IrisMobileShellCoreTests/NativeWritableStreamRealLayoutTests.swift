import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Round 6, prep A: an independent check of the layout defect the round 5
/// verifier found. WebKit's networking process keeps its
/// `FileSystemWritableStream*` staging files one folder down, in
/// `tmp/com.apple.WebKit.Networking/`, not at the top of the app's temp
/// directory. The only real evidence on disk (a Simulator app container) is
/// the file `tmp/com.apple.WebKit.Networking/FileSystemWritableStreamazvI3G`,
/// 154,686 bytes; the Kneecap bug pass put its 1.5 GB pile in the same folder.
///
/// The people: Dana imports a run of long clips in Kneecap, the app is killed
/// twice mid-import, and WebKit leaves staging files behind each time. The
/// oracle is what Dana's phone has on disk afterwards: bytes under tmp, read
/// back, compared with what tmp held before the imports (the baseline).
final class NativeWritableStreamRealLayoutTests: XCTestCase {
    private var tmp: URL!
    private var networking: URL!
    private let fm = FileManager.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var launch: Date { now.addingTimeInterval(-600) }

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("wsreal-\(UUID().uuidString)", isDirectory: true)
        networking = tmp.appendingPathComponent("com.apple.WebKit.Networking", isDirectory: true)
        try fm.createDirectory(at: networking, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

    @discardableResult
    private func plant(_ name: String, in folder: URL, bytes: Int, age: TimeInterval) throws -> URL {
        let url = folder.appendingPathComponent(name)
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data(count: bytes)))
        let created = now.addingTimeInterval(-age)
        try fm.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: url.path)
        return url
    }

    private func bytesUnder(_ url: URL) -> Int {
        var total = 0
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let item as URL in walker {
            let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }

    private func listing(_ url: URL) -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: url.path)) ?? []) }

    func testPileInWebKitsNetworkingFolderIsReclaimedOnTheNextLaunch() throws {
        // What tmp legitimately holds: the person's own clip, WebKit's cookie
        // database, the web app's storage folder. This is the baseline.
        let keepers: [URL] = [
            try plant("holiday.mov", in: tmp, bytes: 3_000, age: 86_400 * 3),
            try plant("Cookies.db", in: networking, bytes: 2_000, age: 86_400 * 3),
        ]
        let storage = tmp.appendingPathComponent("web-app-storage", isDirectory: true)
        try fm.createDirectory(at: storage, withIntermediateDirectories: true)
        try plant("index.db", in: storage, bytes: 4_000, age: 86_400 * 3)
        let baseline = bytesUnder(tmp)
        XCTAssertEqual(baseline, 9_000)

        // The pile: the exact evidence file first, then four more of assorted sizes.
        try plant("FileSystemWritableStreamazvI3G", in: networking, bytes: 154_686, age: 86_400 * 2)
        for (index, size) in [1_500_000, 40_000, 800_000, 250_000].enumerated() {
            try plant("FileSystemWritableStream\(index)Xy", in: networking, bytes: size, age: 86_400)
        }
        // And one at the top level, where an earlier WebKit layout put them (still scanned).
        try plant("FileSystemWritableStreamTop0", in: tmp, bytes: 600_000, age: 86_400)
        XCTAssertGreaterThan(bytesUnder(tmp), baseline + 3_300_000, "the pile is really on disk")

        let removed = NativeWritableStreamStagingCleanup.sweep(
            directory: tmp, processLaunchedAt: launch, referenceStart: .distantPast, now: now
        )

        XCTAssertEqual(removed, 6)
        XCTAssertEqual(bytesUnder(tmp), baseline, "temp bytes are back to the baseline")
        XCTAssertEqual(listing(networking), ["Cookies.db"], "only WebKit's own other files are left in its folder")
        for keeper in keepers { XCTAssertTrue(fm.fileExists(atPath: keeper.path)) }
    }

    func testAFileTheRunningImportIsWritingInThatFolderIsNotCutOff() throws {
        let live = try plant("FileSystemWritableStreamLive9", in: networking, bytes: 500_000, age: 120)
        let orphan = try plant("FileSystemWritableStreamOrphan1", in: networking, bytes: 500_000, age: 86_400)
        // The launch sweep (only proof 1) and the end-of-import sweep both leave the live one alone.
        _ = NativeWritableStreamStagingCleanup.sweep(directory: tmp, processLaunchedAt: launch, referenceStart: .distantPast, now: now)
        _ = NativeWritableStreamStagingCleanup.sweep(directory: tmp, processLaunchedAt: launch, referenceStart: now.addingTimeInterval(-300), now: now)
        XCTAssertTrue(fm.fileExists(atPath: live.path))
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
    }

    func testNothingElseInWebKitsFolderOrAnySiblingFolderIsTouched() throws {
        let other = tmp.appendingPathComponent("com.apple.WebKit.WebContent", isDirectory: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let stray = try plant("FileSystemWritableStreamNotScanned", in: other, bytes: 1_000, age: 86_400 * 5)
        let deeper = networking.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: deeper, withIntermediateDirectories: true)
        let nested = try plant("FileSystemWritableStreamTooDeep", in: deeper, bytes: 1_000, age: 86_400 * 5)
        try plant("Cache-1.bin", in: networking, bytes: 1_000, age: 86_400 * 5)
        try plant("notFileSystemWritableStream", in: networking, bytes: 1_000, age: 86_400 * 5)
        XCTAssertEqual(NativeWritableStreamStagingCleanup.sweep(directory: tmp, processLaunchedAt: launch, referenceStart: .distantPast, now: now), 0)
        XCTAssertTrue(fm.fileExists(atPath: stray.path), "only WebKit's networking folder is scanned, by name")
        XCTAssertTrue(fm.fileExists(atPath: nested.path), "one level down only, never a recursive walk")
        XCTAssertEqual(listing(networking), ["Cache-1.bin", "notFileSystemWritableStream", "sub"])
    }

    func testAFolderThatOnlyPretendsToBeWebKitsIsNotFollowed() throws {
        try fm.removeItem(at: networking)
        let elsewhere = fm.temporaryDirectory.appendingPathComponent("wsreal-elsewhere-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: elsewhere) }
        let precious = try plant("FileSystemWritableStreamPrecious", in: elsewhere, bytes: 1_000, age: 86_400 * 5)
        try fm.createSymbolicLink(at: networking, withDestinationURL: elsewhere)
        XCTAssertEqual(NativeWritableStreamStagingCleanup.sweep(directory: tmp, processLaunchedAt: launch, referenceStart: .distantPast, now: now), 0)
        XCTAssertTrue(fm.fileExists(atPath: precious.path))
    }
}
