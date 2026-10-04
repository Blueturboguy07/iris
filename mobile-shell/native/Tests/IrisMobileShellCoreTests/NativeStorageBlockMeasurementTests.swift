import Darwin
import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Exercises `NativeStorageBlockMeasurement` against real files and a real
/// `clonefile` (the same syscall `NativeRevisionStore` itself uses), never a
/// fake filesystem. The oracle for "did dedupe actually happen" is the
/// difference between the naive per-file sum and this function's result on
/// a large (well above one block) file, not a hardcoded byte count.
final class NativeStorageBlockMeasurementTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-storage-block-measurement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAllocatedBytesMatchesTheFilesystemsOwnAllocatedSizeKey() throws {
        let url = tempRoot.appendingPathComponent("plain.bin")
        let bytes = Data(repeating: 0x5A, count: 3 * 64 * 1024)
        try bytes.write(to: url)

        let measured = try NativeStorageBlockMeasurement.allocatedBytes(atPath: url.path)
        // Independent oracle: ask the filesystem directly through a
        // completely different API (`URLResourceValues`, not `stat`/`lstat`)
        // for the same real file, rather than comparing our own function to
        // a number this test invented.
        let resourceValues = try url.resourceValues(forKeys: [.fileAllocatedSizeKey])
        let oracle = resourceValues.fileAllocatedSize ?? -1
        XCTAssertGreaterThan(measured, 0)
        XCTAssertEqual(measured, oracle)
        XCTAssertGreaterThanOrEqual(measured, bytes.count, "allocation can round up to a block but never reports less than the real content")
    }

    func testAllocatedBytesRejectsASymlinkRatherThanFollowingIt() throws {
        let real = tempRoot.appendingPathComponent("real.bin")
        try Data(repeating: 0x11, count: 4096).write(to: real)
        let link = tempRoot.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try NativeStorageBlockMeasurement.allocatedBytes(atPath: link.path)) { error in
            guard case NativeStorageBlockMeasurement.MeasurementError.notARegularFile(let path) = error else {
                return XCTFail("expected notARegularFile, got \(error)")
            }
            XCTAssertEqual(path, link.path)
        }
    }

    func testAllocatedBytesReportsStatFailedForAMissingFile() {
        let missing = tempRoot.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try NativeStorageBlockMeasurement.allocatedBytes(atPath: missing.path)) { error in
            guard case NativeStorageBlockMeasurement.MeasurementError.statFailed(let path, _) = error else {
                return XCTFail("expected statFailed, got \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    /// Directly exercises the same clonefile the revision store uses for an
    /// unchanged file, at a size (6 MB, Kneecap-scale) where APFS sharing
    /// is not a rounding artifact. The oracle is: real, independent
    /// `fileAllocatedSizeKey` block counts on the two real clone files sum
    /// to roughly double the content size (each clone individually reports
    /// full allocation, exactly the double-counting problem this type
    /// exists to correct), while `dedupingAllocatedBytes` must not.
    func testDedupingAllocatedBytesChargesASharedCloneOnlyOnceWhenItsBaseIsPresent() throws {
        let revisionA = tempRoot.appendingPathComponent("rev-a", isDirectory: true)
        let revisionB = tempRoot.appendingPathComponent("rev-b", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisionB, withIntermediateDirectories: true)

        let bigContent = pseudoRandomData(seed: 7, count: 6 * 1024 * 1024)
        let fileA = revisionA.appendingPathComponent("index.html")
        try bigContent.write(to: fileA)
        let fileB = revisionB.appendingPathComponent("index.html")
        let cloneResult = fileA.withUnsafeFileSystemRepresentation { sourcePath in
            fileB.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return -1 }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        try XCTSkipUnless(cloneResult == 0, "clonefile is unavailable on this volume; dedupe has nothing to correct here")

        let fingerprint = NativeStorageBlockMeasurement.FileFingerprint(
            path: "index.html", sha256: "sha256:shared", bytes: bigContent.count, mediaType: "text/html"
        )
        let naiveSumOfBothClones = try NativeStorageBlockMeasurement.allocatedBytes(atPath: fileA.path)
            + NativeStorageBlockMeasurement.allocatedBytes(atPath: fileB.path)

        let deduped = try NativeStorageBlockMeasurement.dedupingAllocatedBytes(
            contentRootByRevision: ["a": revisionA, "b": revisionB],
            filesByRevision: ["a": [fingerprint], "b": [fingerprint]],
            baseRevisionByRevision: ["a": nil, "b": "a"]
        )
        let dedupedTotal = (deduped["a"] ?? -1) + (deduped["b"] ?? -1)
        XCTAssertEqual(deduped["a"], try NativeStorageBlockMeasurement.allocatedBytes(atPath: fileA.path))
        XCTAssertEqual(deduped["b"], 0, "b's file is byte-identical to a's, and a is its declared base, so b shares a's blocks")
        XCTAssertLessThan(
            dedupedTotal, naiveSumOfBothClones,
            "deduped total must be strictly less than summing every clone's own reported allocation"
        )
    }

    /// The same shared content, but the base revision is absent from the
    /// call (as it is once a real prune has removed it): the surviving
    /// revision must be charged in full, not silently treated as free.
    func testDedupingAllocatedBytesChargesInFullWhenTheBaseIsAbsent() throws {
        let revisionA = tempRoot.appendingPathComponent("rev-a2", isDirectory: true)
        let revisionB = tempRoot.appendingPathComponent("rev-b2", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisionB, withIntermediateDirectories: true)
        let content = pseudoRandomData(seed: 9, count: 2 * 1024 * 1024)
        let fileA = revisionA.appendingPathComponent("index.html")
        try content.write(to: fileA)
        let fileB = revisionB.appendingPathComponent("index.html")
        let cloneResult = fileA.withUnsafeFileSystemRepresentation { sourcePath in
            fileB.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return -1 }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        try XCTSkipUnless(cloneResult == 0, "clonefile is unavailable on this volume")

        let fingerprint = NativeStorageBlockMeasurement.FileFingerprint(
            path: "index.html", sha256: "sha256:shared", bytes: content.count, mediaType: "text/html"
        )
        // Only "b" is passed, as pruning would call this once "a" is gone.
        let deduped = try NativeStorageBlockMeasurement.dedupingAllocatedBytes(
            contentRootByRevision: ["b": revisionB],
            filesByRevision: ["b": [fingerprint]],
            baseRevisionByRevision: ["b": "a"]
        )
        XCTAssertEqual(deduped["b"], try NativeStorageBlockMeasurement.allocatedBytes(atPath: fileB.path))
        XCTAssertGreaterThan(deduped["b"] ?? 0, 0)
    }

    func testDedupingAllocatedBytesTreatsAChangedFileAtTheSamePathAsNewContent() throws {
        let revisionA = tempRoot.appendingPathComponent("rev-a3", isDirectory: true)
        let revisionB = tempRoot.appendingPathComponent("rev-b3", isDirectory: true)
        try FileManager.default.createDirectory(at: revisionA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: revisionB, withIntermediateDirectories: true)
        try pseudoRandomData(seed: 1, count: 8192).write(to: revisionA.appendingPathComponent("index.html"))
        try pseudoRandomData(seed: 2, count: 8192).write(to: revisionB.appendingPathComponent("index.html"))

        let fingerprintA = NativeStorageBlockMeasurement.FileFingerprint(
            path: "index.html", sha256: "sha256:aaa", bytes: 8192, mediaType: "text/html"
        )
        let fingerprintB = NativeStorageBlockMeasurement.FileFingerprint(
            path: "index.html", sha256: "sha256:bbb", bytes: 8192, mediaType: "text/html"
        )
        let deduped = try NativeStorageBlockMeasurement.dedupingAllocatedBytes(
            contentRootByRevision: ["a": revisionA, "b": revisionB],
            filesByRevision: ["a": [fingerprintA], "b": [fingerprintB]],
            baseRevisionByRevision: ["a": nil, "b": "a"]
        )
        XCTAssertGreaterThan(deduped["b"] ?? 0, 0, "a genuinely different file at the same path must be charged, not skipped")
    }

    func testSystemAvailableCapacityBytesWorksForAPathThatDoesNotExistYetAndMatchesAnExistingAncestor() throws {
        let existingAncestor: URL = tempRoot
        let notYetCreated = tempRoot.appendingPathComponent("brand-new-store-root", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notYetCreated.path))

        // Volume-level free space, so both must report the same value. Other
        // processes write to this volume (R2 saw a 4096-byte difference while
        // a benchmark was writing), so compare inside a quiet window: the
        // ancestor read before and after the missing-path read must agree.
        var compared = false
        for _ in 0..<20 where !compared {
            let ancestorBefore = try NativeStorageBlockMeasurement.systemAvailableCapacityBytes(at: existingAncestor)
            let capacityForMissingPath = try NativeStorageBlockMeasurement.systemAvailableCapacityBytes(at: notYetCreated)
            let ancestorAfter = try NativeStorageBlockMeasurement.systemAvailableCapacityBytes(at: existingAncestor)
            guard ancestorBefore == ancestorAfter else { continue }
            XCTAssertGreaterThan(capacityForMissingPath, 0)
            XCTAssertEqual(capacityForMissingPath, ancestorBefore)
            compared = true
        }
        XCTAssertTrue(compared, "the volume never held still for three reads in a row")
    }

    private func pseudoRandomData(seed: UInt64, count: Int) -> Data {
        var state = seed &+ 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8((state >> 33) & 0xff)
        }
        return Data(bytes)
    }
}
