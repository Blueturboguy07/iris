import Foundation
import Darwin

enum PatchQueueCheckedRemoval {
    enum RemovalError: Error { case invalidIdentifier, pathConflict, recordMismatch, removalFailed, stillPresent, synchronizationFailed }

    static func remove(appSlug: String, recipeId: String, from directory: URL) throws {
        guard [appSlug, recipeId].allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0")
        }) else { throw RemovalError.invalidIdentifier }
        guard let rootType = try itemType(at: directory) else { return }
        guard rootType == .typeDirectory else { throw RemovalError.pathConflict }
        let appDirectory = directory.appendingPathComponent(appSlug)
        guard let appType = try itemType(at: appDirectory) else { return }
        guard appType == .typeDirectory else { throw RemovalError.pathConflict }
        let recordURL = appDirectory.appendingPathComponent(recipeId + ".json")
        guard let recordType = try itemType(at: recordURL) else {
            try synchronize(appDirectory)
            return
        }
        guard recordType == .typeRegular else { throw RemovalError.pathConflict }
        let data = try Data(contentsOf: recordURL)
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["appSlug"] as? String == appSlug,
              record["recipeId"] as? String == recipeId else { throw RemovalError.recordMismatch }
        // unlink cannot recursively remove a directory if the path changes.
        guard unlink(recordURL.path) == 0 else { throw RemovalError.removalFailed }
        guard try itemType(at: recordURL) == nil else { throw RemovalError.stillPresent }
        try synchronize(appDirectory)
    }

    private static func synchronize(_ appDirectory: URL) throws {
        let descriptor = open(appDirectory.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RemovalError.synchronizationFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw RemovalError.synchronizationFailed }
    }

    private static func itemType(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let type = attributes[.type] as? FileAttributeType else { throw RemovalError.pathConflict }
            return type
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw error
        }
    }
}
