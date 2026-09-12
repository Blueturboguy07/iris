import Foundation
import Testing
@testable import IrisUsability

@MainActor
struct DeliveredEditUndoRecoveryTests {
    @Test func successRequiresEveryStageInOrder() async throws {
        let recovery = DeliveredEditUndoRecovery()
        let operation = try #require(recovery.begin())
        var calls: [DeliveredEditUndoRecovery.Stage] = []
        let result = await recovery.run(operation: operation) { stage in
            #expect(recovery.needsRecovery)
            calls.append(stage)
            return nil
        }
        #expect(result == nil)
        #expect(calls == [.restore, .relaunch, .source])
        #expect(recovery.completed == [.restore, .relaunch, .source])
        #expect(!recovery.needsRecovery)
        #expect(recovery.operation == nil)
    }

    @Test func failedRestoreKeepsRecoveryAndNeverRelaunchesOrCleansSource() async throws {
        for failure in ["restore returned false", "backup missing", "restore closure missing"] {
            let recovery = DeliveredEditUndoRecovery()
            let operation = try #require(recovery.begin())
            var calls: [DeliveredEditUndoRecovery.Stage] = []
            let result = await recovery.run(operation: operation) { stage in
                calls.append(stage)
                return failure
            }
            #expect(result == failure)
            #expect(calls == [.restore])
            #expect(recovery.completed.isEmpty)
            #expect(recovery.needsRecovery)
            #expect(recovery.operation == nil)
        }
    }

    @Test func relaunchFailureRetriesWithoutRestoringBackupTwice() async throws {
        let recovery = DeliveredEditUndoRecovery()
        var calls: [DeliveredEditUndoRecovery.Stage] = []
        let first = try #require(recovery.begin())
        let failure = await recovery.run(operation: first) { stage in
            calls.append(stage)
            return stage == .relaunch ? "app would not quit" : nil
        }
        #expect(failure == "app would not quit")
        #expect(recovery.completed == [.restore])
        let retry = try #require(recovery.begin())
        let result = await recovery.run(operation: retry) { stage in
            calls.append(stage)
            return nil
        }
        #expect(result == nil)
        #expect(calls == [.restore, .relaunch, .relaunch, .source])
        #expect(!recovery.needsRecovery)
    }

    @Test func sourceFailureRetriesOnlySourceAndRetainsRecoveryUntilSuccess() async throws {
        let recovery = DeliveredEditUndoRecovery()
        let operation = try #require(recovery.begin())
        let failure = await recovery.run(operation: operation) { stage in
            stage == .source ? "checkout failed" : nil
        }
        #expect(failure == "checkout failed")
        #expect(recovery.needsRecovery)
        #expect(recovery.completed == [.restore, .relaunch])
        let retry = try #require(recovery.begin())
        var calls: [DeliveredEditUndoRecovery.Stage] = []
        let result = await recovery.run(operation: retry) { stage in
            calls.append(stage)
            return nil
        }
        #expect(result == nil)
        #expect(calls == [.source])
        #expect(!recovery.needsRecovery)
    }

    @Test func duplicateBeginIsRejectedBeforeAnyAsyncWork() throws {
        let recovery = DeliveredEditUndoRecovery()
        let operation = try #require(recovery.begin())
        #expect(recovery.begin() == nil)
        #expect(recovery.operation == operation)
    }

    @Test func resetDuringAwaitRejectsOldCompletionAndPreservesNewOperation() async throws {
        let recovery = DeliveredEditUndoRecovery()
        let operation = try #require(recovery.begin())
        var replacement: UUID?
        var calls: [DeliveredEditUndoRecovery.Stage] = []
        let result = await recovery.run(operation: operation) { stage in
            calls.append(stage)
            recovery.reset()
            replacement = recovery.begin()
            return nil
        }
        #expect(result == "Undo was interrupted.")
        #expect(calls == [.restore])
        #expect(recovery.completed.isEmpty)
        #expect(recovery.operation == replacement)
        #expect(recovery.needsRecovery)
    }
}
