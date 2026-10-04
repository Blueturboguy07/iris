#if os(iOS)
import CryptoKit
import Foundation
import XCTest
@testable import IrisMobileShellCore
@testable import IrisMobileShellHost

/// round5/mobile-integrator-B1: MiroFish-style behavior simulation for the
/// WKFileUploadPanel temp-copy cleanup (`NATIVE_RUNS.md`'s "Side finding":
/// WebKit keeps a full temp copy of every picked file in the app's own tmp
/// directory and never deletes it; 21 copies, 3.5 GB, observed piling up
/// during one Simulator import matrix run). `NativeMediaPickerSession.finish(_:)`
/// now calls `NativeWKFileUploadPanelTempCleanup.cleanupAfterPick` on every
/// terminal path (success, failure, cancel); `IrisMobileShellApp.swift`'s
/// launch path calls `NativeWKFileUploadPanelTempCleanup.sweepOrphans` once
/// for anything left behind by a kill mid-pick.
///
/// This exact test file (same assertions, same scenarios) was first
/// developed and mutation-verified against a standalone, git-free mirror of
/// `NativeWKFileUploadPanelCleanupPolicy.swift` and
/// `NativeWKFileUploadPanelTempCleanup.swift` in a scratch SwiftPM package
/// (`scratchpad/wk-cleanup-mirror/`, `swift test` runnable, no Xcode/device
/// needed), per `verify-in-scratch-mirror`: 7/7 pass there, and a paired
/// mutation (dropping the WKFileUploadPanel- prefix guard in *both* the
/// policy's own `entriesToDelete` and the wrapper's directory-listing
/// filter -- they are intentionally redundant, so a single-sided mutation
/// is absorbed and proves nothing) is caught (2/7 fail exactly on the two
/// tests built to catch it). Ported here unchanged, against the real
/// production types, to become part of the real
/// `IrisMobileShellAcceptanceTests` target once
/// `INTEGRATION_HOOKS.md`'s pbxproj hook for this file is applied (same
/// pattern as `NativeMediaImportMoveAndCleanupTests.swift`).
///
/// Independent oracle throughout: a real `SHA256` digest of a planted
/// "user file" (never carrying WebKit's own prefix) checked byte-for-byte
/// after every call, plus a real on-disk byte-count return-to-baseline
/// check -- never the code's own self-reported success.
final class NativeWKFileUploadPanelCleanupTests: XCTestCase {
    private var scratchRoot: URL!
    private var userFile: URL!
    private var userFileHashBefore: String!

    override func setUpWithError() throws {
        scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wk-cleanup-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        userFile = scratchRoot.appendingPathComponent("Users-Own-Photo-Export.jpg")
        try Data(repeating: 0xAB, count: 4096).write(to: userFile)
        userFileHashBefore = try sha256(of: userFile)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchRoot)
    }

    private func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func directoryByteCount(_ dir: URL) throws -> Int {
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        return try items.reduce(0) { total, url in
            total + ((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func plantPanelFile(named name: String, bytes: Int, createdAt: Date) throws -> URL {
        let url = scratchRoot.appendingPathComponent(name)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)
        return url
    }

    private func assertUserFileUntouched(line: UInt = #line) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path), "user file must never be deleted", line: line)
        XCTAssertEqual(try sha256(of: userFile), userFileHashBefore, "user file bytes must never change", line: line)
    }

    func testPersonaCalmSingleClipCleansUpAfterSuccess() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let sessionStart = Date()
        _ = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 900_000, createdAt: Date())
        NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: sessionStart, directory: scratchRoot)
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline, "temp bytes must return to baseline after a finished pick")
        try assertUserFileUntouched()
    }

    func testPersonaHurriedMultiClipBatchCleansUpAfterCancel() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let sessionStart = Date()
        for index in 0..<6 {
            _ = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 250_000 + index * 1000, createdAt: Date())
        }
        NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: sessionStart, directory: scratchRoot)
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline, "a cancelled batch's temp copies must all be swept")
        try assertUserFileUntouched()
    }

    /// "picks, cancels and re-picks many files": bytes must return to
    /// baseline after every single cycle, not just at the end.
    func testPersonaRePicksManyTimesBaselineHoldsEveryCycle() throws {
        let baseline = try directoryByteCount(scratchRoot)
        for cycle in 0..<20 {
            let sessionStart = Date()
            let fileCount = 1 + (cycle % 4)
            for _ in 0..<fileCount {
                _ = try plantPanelFile(
                    named: "WKFileUploadPanel-\(UUID().uuidString)",
                    bytes: 10_000 + cycle * 500,
                    createdAt: Date()
                )
            }
            NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: sessionStart, directory: scratchRoot)
            XCTAssertEqual(try directoryByteCount(scratchRoot), baseline, "cycle \(cycle): must return to baseline")
            try assertUserFileUntouched()
        }
    }

    func testPersonaCrashedMidPickIsSweptOnlyAsAnOrphanAtNextLaunch() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let staleTime = Date().addingTimeInterval(-(NativeWKFileUploadPanelCleanupPolicy.staleAfterSeconds + 30))
        _ = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 500_000, createdAt: staleTime)
        NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: Date(), directory: scratchRoot)
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline, "a stale orphan must be swept by the backstop too")
        try assertUserFileUntouched()
    }

    func testLaunchOrphanSweepRemovesOnlyStaleEntriesNeverFreshOnes() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let staleTime = Date().addingTimeInterval(-(NativeWKFileUploadPanelCleanupPolicy.staleAfterSeconds + 60))
        let staleFile = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 300_000, createdAt: staleTime)
        let freshFile = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 300_000, createdAt: Date())

        NativeWKFileUploadPanelTempCleanup.sweepOrphans(directory: scratchRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path), "a stale orphan must be swept at launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshFile.path), "a fresh entry must survive a launch sweep (may still be mid-pick)")
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline + 300_000, "only the stale entry's bytes should be gone")
        try assertUserFileUntouched()
        try FileManager.default.removeItem(at: freshFile)
    }

    /// The sharpest version of the safety invariant: a non-WebKit file that
    /// lands in tmp *during* the pick session (so its creation time alone
    /// would put it inside the same-session deletion window) must still
    /// survive, because it never carries WebKit's own prefix.
    func testFreshNonPanelFileCreatedDuringTheSessionStillSurvives() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let sessionStart = Date()
        let concurrentUserFile = scratchRoot.appendingPathComponent("Some-Other-App-Cache-File.dat")
        try Data(repeating: 0xEF, count: 1234).write(to: concurrentUserFile)
        let concurrentHashBefore = try sha256(of: concurrentUserFile)
        _ = try plantPanelFile(named: "WKFileUploadPanel-\(UUID().uuidString)", bytes: 500_000, createdAt: Date())

        NativeWKFileUploadPanelTempCleanup.cleanupAfterPick(sessionStartedAt: sessionStart, directory: scratchRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: concurrentUserFile.path),
                       "a same-session non-WebKit file must never be deleted just for being fresh")
        XCTAssertEqual(try sha256(of: concurrentUserFile), concurrentHashBefore)
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline + 1234,
                       "only the WKFileUploadPanel- entry should be gone; the concurrent file's bytes remain")
        try assertUserFileUntouched()
        try FileManager.default.removeItem(at: concurrentUserFile)
    }

    func testNeverDeletesAnEntryWithoutTheExactWebKitPrefix() throws {
        let baseline = try directoryByteCount(scratchRoot)
        let lookalike = try plantPanelFile(
            named: "wkfileuploadpanel-lowercase-\(UUID().uuidString)",
            bytes: 200_000,
            createdAt: Date().addingTimeInterval(-(NativeWKFileUploadPanelCleanupPolicy.staleAfterSeconds + 300))
        )
        NativeWKFileUploadPanelTempCleanup.sweepOrphans(directory: scratchRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lookalike.path), "a name that only resembles the prefix must never be deleted")
        try assertUserFileUntouched()
        try FileManager.default.removeItem(at: lookalike)
        XCTAssertEqual(try directoryByteCount(scratchRoot), baseline)
    }
}
#endif
