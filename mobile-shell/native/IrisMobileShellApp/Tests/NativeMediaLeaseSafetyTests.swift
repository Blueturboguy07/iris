#if os(iOS)
import Foundation
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import IrisMobileShellHost

@MainActor
final class NativeMediaLeaseSafetyTests: XCTestCase {
    func testRollbackRemovesBatchCopiesRestoresAccountingAndPreservesSources() throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let source = fixture.file(named: "original.jpg", bytes: Data([0xff, 0xd8, 0xff, 0xd9]))
        let original = try Data(contentsOf: source)
        let lease = try NativeSelectedMediaLease(parent: fixture.root)
        defer { lease.close() }

        let batch = try lease.beginBatch()
        let copied = try lease.copySelectedFile(source, fileExtension: "jpg", batch: batch)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(lease.retainedBytesForTesting, original.count)
        XCTAssertEqual(lease.retainedFilesForTesting, 1)

        lease.rollback(batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
        XCTAssertEqual(lease.retainedBytesForTesting, 0)
        XCTAssertEqual(lease.retainedFilesForTesting, 0)
        XCTAssertEqual(try Data(contentsOf: source), original)

        let retry = try lease.beginBatch()
        _ = try lease.copySelectedFile(source, fileExtension: "jpg", batch: retry)
        try lease.commit(retry)
        XCTAssertEqual(lease.retainedBytesForTesting, original.count)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCancelledBatchRejectsLateCopyAndLeavesOriginalUntouched() throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let bytes = Data("late provider bytes".utf8)
        let source = fixture.file(named: "late.jpg", bytes: bytes)
        let lease = try NativeSelectedMediaLease(parent: fixture.root)
        defer { lease.close() }
        let batch = try lease.beginBatch()

        lease.rollback(batch)
        XCTAssertThrowsError(try lease.copySelectedFile(source, fileExtension: "jpg", batch: batch))
        XCTAssertEqual(lease.retainedBytesForTesting, 0)
        XCTAssertEqual(lease.retainedFilesForTesting, 0)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testCrashReaperDeletesOnlyMarkedUnlockedExactChildrenAndProtectsLiveLease() throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let live = try NativeSelectedMediaLease(parent: fixture.root)
        defer { live.close() }
        let liveDirectory = live.directoryForTesting
        let root = fixture.root.appendingPathComponent(NativeSelectedMediaLease.mediaRootName, isDirectory: true)

        let stale = root.appendingPathComponent(
            NativeSelectedMediaLease.leaseDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stale,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try NativeSelectedMediaLease.leaseMarkerData.write(
            to: stale.appendingPathComponent(NativeSelectedMediaLease.leaseMarkerName),
            options: .withoutOverwriting
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: stale.appendingPathComponent(NativeSelectedMediaLease.leaseLockName).path,
            contents: Data()
        ))
        try Data(repeating: 0x41, count: 4096).write(to: stale.appendingPathComponent("payload.jpg"))

        let unknown = root.appendingPathComponent(
            NativeSelectedMediaLease.leaseDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        try Data("not owned".utf8).write(to: unknown.appendingPathComponent("payload"))

        let external = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let linked = root.appendingPathComponent(
            NativeSelectedMediaLease.leaseDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)

        let next = try NativeSelectedMediaLease(parent: fixture.root)
        next.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDirectory.path), "live lease must not be reaped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "exact marked unlocked stale lease must be reaped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path), "unknown directory must not be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path), "symlink child must not be followed or deleted")
    }

    func testProviderTimeoutCancelsProgressAndLateCallbackCannotCopy() async throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let sourceBytes = Data("timeout source".utf8)
        let source = fixture.file(named: "timeout.jpg", bytes: sourceBytes)
        let lease = try NativeSelectedMediaLease(parent: fixture.root)
        defer { lease.close() }
        let batch = try lease.beginBatch()
        let progress = Progress(totalUnitCount: 1)
        var callback: ((URL?, Error?) -> Void)?

        do {
            // Stand-in for the real 60 s stall so this test does not
            // actually wait a minute: the threshold is shrunk to a few tens
            // of milliseconds, with a poll interval short enough to observe
            // that. There is no overall-ceiling parameter any more (round 3:
            // only a stall ends an import now).
            _ = try await NativeMediaPickerSession.loadSelectedFile(
                using: { completion in
                    callback = completion
                    return progress
                },
                lease: lease,
                batch: batch,
                fileExtension: "jpg",
                kind: .image,
                stallThresholdSeconds: 0.02,
                pollIntervalNanoseconds: 5_000_000
            )
            XCTFail("provider wait must time out")
        } catch {
            XCTAssertEqual(error as? NativeMediaPickerSession.ProviderLoadFailure, .timedOut)
        }

        XCTAssertTrue(progress.isCancelled)
        lease.rollback(batch)
        callback?(source, nil)
        await Task.yield()
        XCTAssertEqual(lease.retainedBytesForTesting, 0)
        XCTAssertEqual(lease.retainedFilesForTesting, 0)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    }

    func testTaskCancellationCancelsProgressAndLateProviderCallbackCannotCopy() async throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let source = fixture.file(named: "cancel.jpg", bytes: Data("cancel source".utf8))
        let lease = try NativeSelectedMediaLease(parent: fixture.root)
        defer { lease.close() }
        let batch = try lease.beginBatch()
        let progress = Progress(totalUnitCount: 1)
        var callback: ((URL?, Error?) -> Void)?

        let task = Task {
            // A threshold wide enough that the manual `task.cancel()` below
            // always wins the race, the same role the old 5 s flat timeout
            // played here.
            try await NativeMediaPickerSession.loadSelectedFile(
                using: { completion in
                    callback = completion
                    return progress
                },
                lease: lease,
                batch: batch,
                fileExtension: "jpg",
                kind: .image,
                stallThresholdSeconds: 5
            )
        }
        while callback == nil { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled provider wait must fail")
        } catch {
            XCTAssertEqual(error as? NativeMediaPickerSession.ProviderLoadFailure, .cancelled)
        }

        XCTAssertTrue(progress.isCancelled)
        lease.rollback(batch)
        callback?(source, nil)
        await Task.yield()
        XCTAssertEqual(lease.retainedBytesForTesting, 0)
        XCTAssertEqual(lease.retainedFilesForTesting, 0)
    }

    func testPresentationDismissalCompletesAtMostOnce() throws {
        let fixture = try MediaLeaseFixture()
        defer { fixture.close() }
        let lease = try NativeSelectedMediaLease(parent: fixture.root)
        defer { lease.close() }
        var completions = 0
        let session = NativeMediaPickerSession(
            lease: lease,
            multiple: false,
            isCurrent: { true },
            notice: { _ in },
            completion: { _ in completions += 1 }
        )
        let controller = UIPresentationController(
            presentedViewController: UIViewController(),
            presenting: nil
        )

        session.presentationControllerDidDismiss(controller)
        session.presentationControllerDidDismiss(controller)
        session.cancel()
        XCTAssertEqual(completions, 1)
    }

    func testRepresentationSelectionSkipsAbstractTypeWithoutFilenameExtension() {
        let selection = NativeMediaPickerSession.preferredRepresentation(
            in: [UTType.image.identifier, UTType.jpeg.identifier]
        )
        XCTAssertEqual(selection?.typeIdentifier, UTType.jpeg.identifier)
        // UTType may prefer "jpeg" on iOS and "jpg" on macOS. Assert the
        // concrete system type's extension, not a platform-specific spelling.
        XCTAssertEqual(selection?.fileExtension, UTType.jpeg.preferredFilenameExtension)
    }
}

private final class MediaLeaseFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iris-media-safety-" + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func file(named name: String, bytes: Data) -> URL {
        let url = root.appendingPathComponent(name)
        try! bytes.write(to: url)
        return url
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
