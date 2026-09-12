import Foundation

extension OnDemandEditInterruptedRunRecovery {
    /// Dismissing a failure is not permission to lose its recovery record.
    static func forgetUnlessReviewIsRequired(recordPath: String = defaultRecordPath) {
        guard recordOnDisk(recordPath: recordPath)?.requiresReviewBeforeRecovery != true else { return }
        forget(recordPath: recordPath)
    }

    /// Before a new clean run takes ownership, preserve the previous failed
    /// run's exact record. This archives metadata, not source or app files.
    static func archiveHeldReviewBeforeNewRun(recordPath: String = defaultRecordPath) throws {
        guard recordOnDisk(recordPath: recordPath)?.requiresReviewBeforeRecovery == true else { return }
        let source = URL(fileURLWithPath: recordPath)
        let original = try Data(contentsOf: source)
        let directory = source.deletingLastPathComponent().appendingPathComponent("failed-edit-reviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + ".json")
        try original.write(to: destination, options: .withoutOverwriting)
        guard try Data(contentsOf: destination) == original,
              try Data(contentsOf: source) == original else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.removeItem(at: source)
    }
}
