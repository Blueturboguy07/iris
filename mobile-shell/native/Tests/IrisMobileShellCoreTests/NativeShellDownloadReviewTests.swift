import Foundation
import XCTest
@testable import IrisMobileShellCore

final class NativeShellDownloadReviewTests: XCTestCase {
    private func packageBytes() throws -> Data {
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: nativeRoot.appendingPathComponent("IrisMobileShellApp/Resources/SafeDemo.irisapp"))
    }

    func testCancelledDownloadCannotRecreatePendingReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-download-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let bytes = try packageBytes()

        await coordinator.supersedePendingReview(clientReviewSequence: 1)
        await coordinator.supersedePendingReview(clientReviewSequence: 2)
        do {
            _ = try await coordinator.reviewImport(packageBytes: bytes, clientReviewSequence: 1)
            XCTFail("A cancelled network result must not reopen a review.")
        } catch {
            XCTAssertEqual(error as? NativeShellLibraryError, .reviewSuperseded)
        }
        let pending = await coordinator.pendingPackageReview()
        XCTAssertNil(pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLateEqualInvalidationCannotEraseItsAlreadyDisplayedReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-download-equal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let review = try await coordinator.reviewImport(packageBytes: packageBytes(), clientReviewSequence: 8)

        // The host's separately enqueued initial invalidation can arrive late.
        await coordinator.supersedePendingReview(clientReviewSequence: 8)
        await coordinator.supersedePendingReview(clientReviewSequence: 7)
        let pending = await coordinator.pendingPackageReview()
        XCTAssertEqual(pending?.reviewToken, review.reviewToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testStaleDownloadAndTokenCleanupPreserveNewerReview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-download-newer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NativeShellLibraryCoordinator(rootURL: root)
        let bytes = try packageBytes()
        let old = try await coordinator.reviewImport(packageBytes: bytes, clientReviewSequence: 11)
        await coordinator.supersedePendingReview(clientReviewSequence: 12)
        let current = try await coordinator.reviewImport(packageBytes: bytes, clientReviewSequence: 12)
        await coordinator.cancelReview(reviewToken: old.reviewToken)
        do {
            _ = try await coordinator.reviewImport(packageBytes: bytes, clientReviewSequence: 11)
            XCTFail("Older completion must not replace the newer review.")
        } catch {
            XCTAssertEqual(error as? NativeShellLibraryError, .reviewSuperseded)
        }
        let pending = await coordinator.pendingPackageReview()
        XCTAssertEqual(pending?.reviewToken, current.reviewToken)
        let library = try await coordinator.refreshLibrary()
        XCTAssertTrue(library.isEmpty)
    }
}
