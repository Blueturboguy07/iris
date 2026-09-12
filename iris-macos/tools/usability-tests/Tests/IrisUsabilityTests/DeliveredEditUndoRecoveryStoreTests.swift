import Foundation
import Testing
@testable import IrisUsability

struct DeliveredEditUndoRecoveryStoreTests {
    @Test func freshObjectFindsPendingRecoveryWithoutChangingDirtyOrMovedTargets() throws {
        try withDirectory { directory in
            let working = directory.appendingPathComponent("working")
            try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false)
            let dirtyBytes = Data([0, 255, 1, 65])
            try dirtyBytes.write(to: working.appendingPathComponent("reader-work"))
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            let record = makeRecord(clonePath: working.path)
            try store.saveBeforeStarting(record)
            let recordBytes = try Data(contentsOf: store.recordURL)
            let moved = directory.appendingPathComponent("moved-working")
            try FileManager.default.moveItem(at: working, to: moved)

            let recreated = DeliveredEditUndoRecoveryStore(recordURL: store.recordURL)
            #expect(recreated.load() == .pending(record))
            #expect(recreated.load().requiresReview)
            #expect(!FileManager.default.fileExists(atPath: working.path))
            #expect(try Data(contentsOf: moved.appendingPathComponent("reader-work")) == dirtyBytes)
            #expect(try Data(contentsOf: store.recordURL) == recordBytes)
        }
    }

    @Test func absentMarkerPermitsExistingStartupRecoveryButCorruptMarkerSuppressesIt() throws {
        try withDirectory { directory in
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            #expect(!store.load().requiresReview)
            let corrupt = Data("{unfinished".utf8)
            try corrupt.write(to: store.recordURL)
            #expect(store.load() == .unreadable)
            #expect(store.load().requiresReview)
            #expect(throws: (any Error).self) { try store.saveBeforeStarting(makeRecord()) }
            #expect(throws: (any Error).self) { try store.clearAfterCompletion(identifier: UUID()) }
            #expect(try Data(contentsOf: store.recordURL) == corrupt)
        }
    }

    @Test func staleRecordIsPreservedAndNeverTreatedAsProofOfCompletion() throws {
        try withDirectory { directory in
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            let record = makeRecord(startedAt: Date(timeIntervalSince1970: 1))
            try store.saveBeforeStarting(record)
            #expect(DeliveredEditUndoRecoveryStore(recordURL: store.recordURL).load() == .pending(record))
            #expect(store.load().requiresReview)
        }
    }

    @Test func completionClearsOnlyMatchingLiveTransaction() throws {
        try withDirectory { directory in
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            let record = makeRecord()
            try store.saveBeforeStarting(record)
            #expect(throws: (any Error).self) { try store.clearAfterCompletion(identifier: UUID()) }
            #expect(store.load() == .pending(record))
            try store.clearAfterCompletion(identifier: record.identifier)
            #expect(store.load() == .absent)
        }
    }

    @Test func storageFailureDoesNotCreateSuccessfulRecoveryRecord() throws {
        try withDirectory { directory in
            let parentFile = directory.appendingPathComponent("not-a-directory")
            try Data("keep".utf8).write(to: parentFile)
            let store = DeliveredEditUndoRecoveryStore(recordURL: parentFile.appendingPathComponent("record.json"))
            #expect(throws: (any Error).self) { try store.saveBeforeStarting(makeRecord()) }
            #expect(try Data(contentsOf: parentFile) == Data("keep".utf8))
        }
    }

    @Test func directoryAtRecordPathRefusesWriteAndPreservesItsContents() throws {
        try withDirectory { directory in
            let recordDirectory = directory.appendingPathComponent("record.json")
            try FileManager.default.createDirectory(at: recordDirectory, withIntermediateDirectories: false)
            let contents = recordDirectory.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: contents)
            let store = DeliveredEditUndoRecoveryStore(recordURL: recordDirectory)
            #expect(store.load() == .unreadable)
            #expect(throws: (any Error).self) { try store.saveBeforeStarting(makeRecord()) }
            #expect(try Data(contentsOf: contents) == Data("keep".utf8))
        }
    }

    @Test func existingRecordCannotBeOverwrittenAndContainsOnlyMetadata() throws {
        try withDirectory { directory in
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            let record = makeRecord()
            try store.saveBeforeStarting(record)
            #expect(throws: (any Error).self) { try store.saveBeforeStarting(makeRecord()) }
            #expect(store.load() == .pending(record))
            let data = try Data(contentsOf: store.recordURL)
            let dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(dictionary.keys) == Set([
                "version", "identifier", "startedAt", "appSlug", "appName", "installedPath",
                "backupPath", "clonePath", "branchName", "originalCommit", "originalRef"
            ]))
            let attributes = try FileManager.default.attributesOfItem(atPath: store.recordURL.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func unsupportedSchemaAndOversizedRecordStayVisible() throws {
        try withDirectory { directory in
            let store = DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("record.json"))
            var record = makeRecord()
            record.version = 99
            try JSONEncoder().encode(record).write(to: store.recordURL)
            #expect(store.load() == .unreadable)
            try Data(repeating: 65, count: 32_769).write(to: store.recordURL)
            #expect(store.load() == .unreadable)
            #expect(store.load().requiresReview)
        }
    }

    private func makeRecord(clonePath: String = "/fixture/missing-project", startedAt: Date = Date()) -> DeliveredEditUndoRecoveryRecord {
        DeliveredEditUndoRecoveryRecord(
            identifier: UUID(), startedAt: startedAt, appSlug: "fixture", appName: "Fixture",
            installedPath: "/fixture/App.app", backupPath: "/fixture/Backup.app", clonePath: clonePath,
            branchName: "edit", originalCommit: String(repeating: "a", count: 40), originalRef: "main"
        )
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iris-undo-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
