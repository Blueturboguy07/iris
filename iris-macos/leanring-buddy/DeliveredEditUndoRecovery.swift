import Foundation

/// Checkpoints survive a retry because restoring an installed backup can consume it.
@MainActor
final class DeliveredEditUndoRecovery {
    nonisolated static func sourceRestoreCommand(
        originalHeadRef: String?,
        originalCommit: String,
        editedBranchName: String? = nil
    ) -> String {
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let target = originalHeadRef.flatMap { $0 == "HEAD" ? nil : $0 } ?? originalCommit
        let checkout: String
        if let editedBranchName, originalHeadRef == editedBranchName {
            // A saved candidate is committed on the same branch that held its
            // baseline. Leave that branch pointing at the delivered commit,
            // and detach only the working tree at the exact baseline. This
            // keeps the edit branch history without reset, force checkout, or
            // deletion. The second arm makes a retry after a completed
            // checkout idempotent, while still refusing a different branch.
            let branch = quote(editedBranchName)
            let baseline = quote(originalCommit)
            checkout = "(test \"$(git symbolic-ref --quiet --short HEAD 2>/dev/null)\" = \(branch) && git -c core.hooksPath=/dev/null checkout --quiet --detach \(baseline)) || (! git symbolic-ref --quiet HEAD 2>/dev/null && test \"$(git rev-parse --verify 'HEAD^{commit}')\" = \(baseline))"
        } else {
            // For an ordinary original ref, switching is safe only while that
            // ref still identifies the recorded baseline. A moved ref is
            // ambiguous and must remain untouched.
            checkout = "test \"$(git rev-parse --verify \(quote(target + "^{commit}")))\" = \(quote(originalCommit)) && git -c core.hooksPath=/dev/null checkout --quiet \(quote(target))"
        }
        return "iris_undo_status=\"$(git status --porcelain)\" && test -z \"$iris_undo_status\" && (\(checkout)) && test \"$(git rev-parse HEAD)\" = \(quote(originalCommit))"
    }

    enum Stage: CaseIterable { case restore, relaunch, source }
    private(set) var completed: Set<Stage> = []
    private(set) var operation: UUID?
    private(set) var needsRecovery = false

    func begin() -> UUID? {
        guard operation == nil else { return nil }
        let identifier = UUID()
        operation = identifier
        needsRecovery = true
        return identifier
    }

    func reset() {
        operation = nil
        completed = []
        needsRecovery = false
    }

    /// Mark only the installed-app restore stage as confirmed after a
    /// restart. The caller must have independently revalidated the durable
    /// receipt and both bundle payloads; this method only seeds the in-memory
    /// checkpoint so the next run resumes at relaunch/source.
    @discardableResult
    func restoreConfirmedAppCheckpoint() -> Bool {
        guard operation == nil, completed.isEmpty else { return false }
        completed = [.restore]
        needsRecovery = true
        return true
    }

    func run(
        operation identifier: UUID,
        perform: (Stage) async -> String?
    ) async -> String? {
        for stage in Stage.allCases where !completed.contains(stage) {
            guard operation == identifier else { return "Undo was interrupted." }
            let failure = await perform(stage)
            guard operation == identifier else { return "Undo was interrupted." }
            if let failure {
                operation = nil
                return failure
            }
            completed.insert(stage)
        }
        guard operation == identifier else { return "Undo was interrupted." }
        operation = nil
        needsRecovery = false
        return nil
    }
}
