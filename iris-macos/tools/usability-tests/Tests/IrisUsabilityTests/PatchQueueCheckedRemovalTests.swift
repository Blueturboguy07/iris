import Foundation
import Testing
@testable import IrisUsability

struct PatchQueueCheckedRemovalTests {
    @Test func removesExactRecordAndLeavesOtherRecordsUntouched() throws {
        try withQueue { directory, recordURL in
            let other = recordURL.deletingLastPathComponent().appendingPathComponent("other.json")
            let bytes = Data("other content".utf8)
            try bytes.write(to: other)
            try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: directory)
            #expect(!FileManager.default.fileExists(atPath: recordURL.path))
            #expect(try Data(contentsOf: other) == bytes)
            try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: directory)
        }
    }

    @Test func absentQueueIsSuccessfulWithoutCreatingDirectories() throws {
        try withQueue { directory, _ in
            let absent = directory.appendingPathComponent("absent")
            try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: absent)
            #expect(!FileManager.default.fileExists(atPath: absent.path))
            try PatchQueueCheckedRemoval.remove(appSlug: "missing-app", recipeId: "change", from: directory)
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing-app").path))
        }
    }

    @Test func mismatchedOrMalformedRecordIsKept() throws {
        try withQueue { directory, recordURL in
            for text in ["{broken", "{\"appSlug\":\"other\",\"recipeId\":\"change\"}"] {
                let bytes = Data(text.utf8)
                try bytes.write(to: recordURL)
                #expect(throws: (any Error).self) {
                    try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: directory)
                }
                #expect(try Data(contentsOf: recordURL) == bytes)
            }
        }
    }

    @Test func directoryConflictNeverDeletesContents() throws {
        try withQueue { directory, recordURL in
            try FileManager.default.removeItem(at: recordURL)
            try FileManager.default.createDirectory(at: recordURL, withIntermediateDirectories: false)
            let child = recordURL.appendingPathComponent("keep")
            try Data("keep".utf8).write(to: child)
            #expect(throws: (any Error).self) {
                try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: directory)
            }
            #expect(try Data(contentsOf: child) == Data("keep".utf8))
        }
    }

    @Test func parentFileConflictIsReported() throws {
        try withQueue { directory, recordURL in
            #expect(throws: (any Error).self) {
                try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: recordURL)
            }
            let parent = directory.appendingPathComponent("parent-file")
            try Data("keep".utf8).write(to: parent)
            #expect(throws: (any Error).self) {
                try PatchQueueCheckedRemoval.remove(appSlug: "parent-file", recipeId: "change", from: directory)
            }
            #expect(try Data(contentsOf: parent) == Data("keep".utf8))
        }
    }

    @Test func symlinkRecordAndPathTraversalAreRefused() throws {
        try withQueue { directory, recordURL in
            let destination = directory.appendingPathComponent("keep.json")
            let bytes = try Data(contentsOf: recordURL)
            try bytes.write(to: destination)
            try FileManager.default.removeItem(at: recordURL)
            try FileManager.default.createSymbolicLink(at: recordURL, withDestinationURL: destination)
            #expect(throws: (any Error).self) {
                try PatchQueueCheckedRemoval.remove(appSlug: "app", recipeId: "change", from: directory)
            }
            #expect(throws: (any Error).self) {
                try PatchQueueCheckedRemoval.remove(appSlug: "../app", recipeId: "change", from: directory)
            }
            #expect(try Data(contentsOf: destination) == bytes)
        }
    }

    private func withQueue(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iris-queue-removal-" + UUID().uuidString)
        let appDirectory = directory.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordURL = appDirectory.appendingPathComponent("change.json")
        try JSONSerialization.data(withJSONObject: [
            "appSlug": "app", "recipeId": "change", "branchName": "edit", "patchText": "fixture"
        ]).write(to: recordURL)
        try body(directory, recordURL)
    }
}
