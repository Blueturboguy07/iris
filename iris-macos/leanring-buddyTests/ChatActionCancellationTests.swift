import Foundation
import Testing
#if canImport(Iris)
@testable import Iris
#else
@testable import IrisChatActions
#endif

@MainActor
struct ChatActionCancellationTests {
    private let confirmationCommand = #"{"command":"sudo -n true","whatItDoes":"Fixture-only confirmation"}"#

    private func configuredRunner() -> ChatActionToolRunner {
        let runner = ChatActionToolRunner()
        runner.autonomyIsGranted = { false }
        runner.writeTextToTheClipboard = { _ in
            Issue.record("This fixture did not authorize a clipboard write")
        }
        runner.runTheApprovedCommand = { _ in
            Issue.record("This fixture did not authorize a command")
            return ChatActionCommandOutcome(exitCode: 0, scrubbedOutputTail: "Fixture", timedOut: false)
        }
        return runner
    }

    @Test func cancelDuringApprovalPreventsTheOldCommandFromRunning() async {
        let runner = configuredRunner()
        var executedCommands = 0
        runner.runTheApprovedCommand = { _ in
            executedCommands += 1
            return ChatActionCommandOutcome(exitCode: 0, scrubbedOutputTail: "Fixture", timedOut: false)
        }
        var pendingApproval: CheckedContinuation<Bool, Never>?
        var approvalStarted: CheckedContinuation<Void, Never>?
        runner.askTheReaderToApproveACommand = { _, _, _ in
            await withCheckedContinuation { continuation in
                pendingApproval = continuation
                approvalStarted?.resume()
                approvalStarted = nil
            }
        }
        let requestTask = Task {
            await runner.execute(
                toolNamed: ChatActionTools.runCommandToolName, inputJSONText: confirmationCommand
            )
        }
        await withCheckedContinuation { continuation in
            if pendingApproval != nil { continuation.resume() }
            else { approvalStarted = continuation }
        }
        requestTask.cancel()
        pendingApproval?.resume(returning: true)
        let result = await requestTask.value

        #expect(result.isError)
        #expect(result.contentText.contains("canceled"))
        #expect(executedCommands == 0)
        #expect(!runner.hasDoneAnythingForThisChatMessage)
    }

    @Test func aNewMessageInvalidatesAnOlderPendingApprovalWithoutSpendingItsBudget() async {
        let runner = configuredRunner()
        var pendingApproval: CheckedContinuation<Bool, Never>?
        var approvalStarted: CheckedContinuation<Void, Never>?
        runner.askTheReaderToApproveACommand = { _, _, _ in
            await withCheckedContinuation { continuation in
                pendingApproval = continuation
                approvalStarted?.resume()
                approvalStarted = nil
            }
        }
        let oldRequestTask = Task {
            await runner.execute(
                toolNamed: ChatActionTools.runCommandToolName, inputJSONText: confirmationCommand
            )
        }
        await withCheckedContinuation { continuation in
            if pendingApproval != nil { continuation.resume() }
            else { approvalStarted = continuation }
        }
        runner.beginANewChatMessage()
        pendingApproval?.resume(returning: true)
        let oldResult = await oldRequestTask.value
        #expect(oldResult.isError)
        #expect(!runner.hasDoneAnythingForThisChatMessage)

        var newCommandsExecuted = 0
        runner.autonomyIsGranted = { true }
        runner.runTheApprovedCommand = { _ in
            newCommandsExecuted += 1
            return ChatActionCommandOutcome(exitCode: 0, scrubbedOutputTail: "Fixture", timedOut: false)
        }
        for _ in 0..<ChatActionToolRunner.maximumCommandsPerChatMessage {
            let newResult = await runner.execute(
                toolNamed: ChatActionTools.runCommandToolName,
                inputJSONText: #"{"command":"true","whatItDoes":"Fixture"}"#
            )
            #expect(!newResult.isError)
        }
        #expect(newCommandsExecuted == ChatActionToolRunner.maximumCommandsPerChatMessage)
    }

    @Test func aCurrentApprovedCommandStillRunsNormally() async {
        let runner = configuredRunner()
        var executedCommands = 0
        runner.askTheReaderToApproveACommand = { _, _, _ in true }
        runner.runTheApprovedCommand = { _ in
            executedCommands += 1
            return ChatActionCommandOutcome(exitCode: 0, scrubbedOutputTail: "Fixture", timedOut: false)
        }
        let result = await runner.execute(
            toolNamed: ChatActionTools.runCommandToolName, inputJSONText: confirmationCommand
        )
        #expect(!result.isError)
        #expect(executedCommands == 1)
        #expect(runner.hasDoneAnythingForThisChatMessage)
    }

    @Test func aCanceledTaskCannotWriteTheClipboard() async {
        let runner = configuredRunner()
        let requestTask = Task {
            await runner.execute(
                toolNamed: ChatActionTools.clipboardToolName,
                inputJSONText: #"{"text":"Fixture","whatThisIs":"Fixture"}"#
            )
        }
        requestTask.cancel()
        let result = await requestTask.value
        #expect(result.isError)
        #expect(!runner.hasDoneAnythingForThisChatMessage)
    }

    @Test func persistedAutonomyBehaviorStillNeedsNoExtraApproval() async {
        let runner = configuredRunner()
        runner.autonomyIsGranted = { true }
        runner.askTheReaderToApproveACommand = { _, _, _ in
            Issue.record("Granted autonomy must not add an approval")
            return false
        }
        runner.runTheApprovedCommand = { _ in
            ChatActionCommandOutcome(exitCode: 0, scrubbedOutputTail: "Fixture", timedOut: false)
        }
        let result = await runner.execute(
            toolNamed: ChatActionTools.runCommandToolName, inputJSONText: confirmationCommand
        )
        #expect(!result.isError)
    }

    @Test func cancellationChangesDoNotWeakenTheCatastropheFloor() async {
        let runner = configuredRunner()
        runner.autonomyIsGranted = { true }
        let result = await runner.execute(
            toolNamed: ChatActionTools.runCommandToolName,
            inputJSONText: #"{"command":"mkfs /dev/disk999","whatItDoes":"Refusal fixture, never executed"}"#
        )
        #expect(result.isError)
        #expect(!runner.hasDoneAnythingForThisChatMessage)
    }
}
