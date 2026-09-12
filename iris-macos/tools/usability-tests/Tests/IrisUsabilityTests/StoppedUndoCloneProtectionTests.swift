import Foundation
import Testing
@testable import IrisUsability

@MainActor
struct StoppedUndoCloneProtectionTests {
    @Test func stoppedUndoBlocksOnlyAffectedCloneAcrossLockRecreation() throws {
        try withFixture { directory, store in
            let protectedClone = directory.appendingPathComponent("protected-clone").path
            let unrelatedClone = directory.appendingPathComponent("other-clone").path
            let record = DeliveredEditUndoRecoveryRecord(
                identifier: UUID(), startedAt: Date(), appSlug: "fixture", appName: "Fixture",
                installedPath: directory.appendingPathComponent("Installed.app").path,
                backupPath: directory.appendingPathComponent("Backup.app").path,
                clonePath: protectedClone, branchName: "edit",
                originalCommit: String(repeating: "a", count: 40), originalRef: "main"
            )
            try store.saveBeforeStarting(record)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            #expect(store.load() == .absent)

            for _ in 0..<2 {
                let lock = MaintainClonePathLock(undoRecoveryStore: store)
                #expect(!lock.tryAcquire(clonePath: protectedClone, owner: "fixture-edit"))
                #expect(lock.currentOwner(ofClonePath: protectedClone) == "saved Undo recovery information")
                lock.release(clonePath: protectedClone)
                #expect(!lock.tryAcquire(clonePath: protectedClone, owner: "fixture-replay"))
                #expect(lock.tryAcquire(clonePath: unrelatedClone, owner: "fixture-other"))
                #expect(!lock.tryAcquire(clonePath: unrelatedClone, owner: "fixture-duplicate"))
                lock.release(clonePath: unrelatedClone)
                #expect(lock.tryAcquire(clonePath: unrelatedClone, owner: "fixture-other-again"))
            }
            #expect(store.archivedRecoveryInventory().records == [record])
        }
    }

    @Test func unidentifiedArchivedRecoveryCannotPretendAnUnrelatedCloneIsSafe() throws {
        try withFixture { directory, store in
            try Data("{incomplete".utf8).write(to: store.recordURL)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            let lock = MaintainClonePathLock(undoRecoveryStore: store)
            #expect(!lock.tryAcquire(clonePath: directory.appendingPathComponent("some-clone").path, owner: "fixture"))
            #expect(store.archivedRecoveryInventory().hasUnknownTargets)
            #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.path)) == Data("{incomplete".utf8))
        }
    }

    private func withFixture(_ body: (URL, DeliveredEditUndoRecoveryStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iris-stopped-undo-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory, DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("pending.json")))
    }
}
