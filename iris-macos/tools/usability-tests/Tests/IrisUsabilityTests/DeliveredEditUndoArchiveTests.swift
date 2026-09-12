import Foundation
import Testing
@testable import IrisUsability

struct DeliveredEditUndoArchiveTests {
    @Test func recreationKeepsProtectionAndUnrelatedAppsRemainEditable() throws {
        try withStore { store, directory in
            let record = makeRecord(directory: directory)
            try store.saveBeforeStarting(record)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            let recreated = DeliveredEditUndoRecoveryStore(recordURL: store.recordURL)
            #expect(recreated.load() == .absent)
            #expect(recreated.archivedRecoveryInventory().records == [record])
            #expect(recreated.archivedProtection(appSlug: "affected").blocksChanges)
            #expect(recreated.archivedProtection(appSlug: "unrelated", paths: [directory.appendingPathComponent("other").path]) == .clear)
            #expect(recreated.archivedProtection(paths: [record.clonePath + "/file.swift"]).blocksChanges)
            #expect(recreated.archivedProtection(paths: [try #require(record.backupPath)]).blocksChanges)
        }
    }

    @Test func duplicateStopAndCrashAfterArchiveReuseEvidence() throws {
        try withStore { store, directory in
            let record = makeRecord(directory: directory)
            try store.saveBeforeStarting(record)
            let first = try store.archiveBeforeStopping()
            let recreated = DeliveredEditUndoRecoveryStore(recordURL: store.recordURL)
            let retry = try recreated.archiveBeforeStopping()
            #expect(first.path == retry.path)
            #expect(recreated.archivedRecoveryInventory().archivePaths.count == 1)
            try recreated.clearActiveAfterArchival(retry)
            try recreated.clearActiveAfterArchival(retry)
            #expect(recreated.load() == .absent)
        }
    }

    @Test func archiveWriteFailureLeavesActiveBytesUntouched() throws {
        try withStore { store, directory in
            try store.saveBeforeStarting(makeRecord(directory: directory))
            let before = try Data(contentsOf: store.recordURL)
            try Data("parent conflict".utf8).write(to: store.archiveDirectoryURL)
            #expect(throws: (any Error).self) { try store.archiveBeforeStopping() }
            #expect(try Data(contentsOf: store.recordURL) == before)
            #expect(store.load().requiresReview)
        }
    }

    @Test func changedActiveMarkerCannotBeClearedUsingOlderReceipt() throws {
        try withStore { store, directory in
            try store.saveBeforeStarting(makeRecord(directory: directory))
            let receipt = try store.archiveBeforeStopping()
            let changed = Data("changed evidence".utf8)
            try changed.write(to: store.recordURL)
            #expect(throws: (any Error).self) { try store.clearActiveAfterArchival(receipt) }
            #expect(try Data(contentsOf: store.recordURL) == changed)
            #expect(FileManager.default.fileExists(atPath: receipt.path))
        }
    }

    @Test func corruptMarkerIsArchivedByteForByteAndUnknownTargetsStayProtected() throws {
        try withStore { store, _ in
            let corrupt = Data([0, 255, 123, 1])
            try corrupt.write(to: store.recordURL)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            #expect(try Data(contentsOf: URL(fileURLWithPath: receipt.path)) == corrupt)
            #expect(store.load() == .absent)
            #expect(store.archivedRecoveryInventory().hasUnknownTargets)
            if case .unknownTargets = store.archivedProtection(appSlug: "any") {} else {
                Issue.record("Unknown targets must block changes")
            }
        }
    }

    @Test func oversizedAndDirectoryMarkersAreNeverRemoved() throws {
        try withStore { store, _ in
            let oversized = Data(repeating: 65, count: 32_769)
            try oversized.write(to: store.recordURL)
            #expect(throws: (any Error).self) { try store.archiveBeforeStopping() }
            #expect(try Data(contentsOf: store.recordURL) == oversized)
            try FileManager.default.removeItem(at: store.recordURL)
            try FileManager.default.createDirectory(at: store.recordURL, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try store.archiveBeforeStopping() }
            #expect(FileManager.default.fileExists(atPath: store.recordURL.path))
        }
    }

    @Test func multipleArchivesKeepEveryAffectedTargetProtected() throws {
        try withStore { store, directory in
            for slug in ["first", "second"] {
                try store.saveBeforeStarting(makeRecord(directory: directory, slug: slug))
                let receipt = try store.archiveBeforeStopping()
                try store.clearActiveAfterArchival(receipt)
            }
            #expect(store.archivedRecoveryInventory().records.count == 2)
            #expect(store.archivedProtection(appSlug: "first").blocksChanges)
            #expect(store.archivedProtection(appSlug: "second").blocksChanges)
            #expect(store.archivedProtection(appSlug: "third") == .clear)
        }
    }

    @Test func symlinkAliasOfProtectedCloneIsProtectedWithoutChangingFiles() throws {
        try withStore { store, directory in
            let record = makeRecord(directory: directory)
            try FileManager.default.createDirectory(atPath: record.clonePath, withIntermediateDirectories: true)
            let file = URL(fileURLWithPath: record.clonePath).appendingPathComponent("keep")
            try Data("reader work".utf8).write(to: file)
            let alias = directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: record.clonePath))
            try store.saveBeforeStarting(record)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            #expect(store.archivedProtection(appSlug: "different-alias", paths: [alias.path]).blocksChanges)
            #expect(try Data(contentsOf: file) == Data("reader work".utf8))
        }
    }

    @Test func parentChildOverlapUsesPathComponentsAndKeepsLexicalAliasProtected() throws {
        try withStore { store, directory in
            let first = directory.appendingPathComponent("first-target")
            let second = directory.appendingPathComponent("second-target")
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
            let alias = directory.appendingPathComponent("recorded-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
            let record = DeliveredEditUndoRecoveryRecord(
                identifier: UUID(), startedAt: Date(), appSlug: "affected", appName: "Fixture",
                installedPath: nil, backupPath: nil, clonePath: alias.path,
                branchName: "edit", originalCommit: nil, originalRef: nil
            )
            try store.saveBeforeStarting(record)
            let receipt = try store.archiveBeforeStopping()
            try store.clearActiveAfterArchival(receipt)
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
            #expect(store.archivedProtection(paths: [alias.path]).blocksChanges)
            #expect(store.archivedProtection(paths: [alias.path + "/child"]).blocksChanges)
            #expect(store.archivedProtection(paths: [directory.path]).blocksChanges)
            #expect(store.archivedProtection(paths: [alias.path + "-different"]) == .clear)
        }
    }

    private func makeRecord(directory: URL, slug: String = "affected") -> DeliveredEditUndoRecoveryRecord {
        DeliveredEditUndoRecoveryRecord(
            identifier: UUID(), startedAt: Date(), appSlug: slug, appName: "Fixture",
            installedPath: directory.appendingPathComponent(slug + "-installed").path,
            backupPath: directory.appendingPathComponent(slug + "-backup").path,
            clonePath: directory.appendingPathComponent(slug + "-clone").path,
            branchName: "edit", originalCommit: nil, originalRef: nil
        )
    }

    private func withStore(_ body: (DeliveredEditUndoRecoveryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iris-undo-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(DeliveredEditUndoRecoveryStore(recordURL: directory.appendingPathComponent("active.json")), directory)
    }
}
