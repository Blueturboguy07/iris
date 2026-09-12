import Foundation
import Testing
@testable import IrisHarness

@Suite("Harness review input budget")
struct HarnessReviewInputBudgetTests {
    @Test("editing yields at the exact ordinary review boundary")
    func editingYieldsAtExactOrdinaryReviewBoundary() throws {
        let budget = HarnessReviewInputBudget(stageCount: 1, maximumInputBytesPerStage: 50)
        #expect(budget.reservedInputBytes == 50)
        #expect(!budget.shouldYieldEditing(remainingInputBytes: 51))
        #expect(budget.shouldYieldEditing(remainingInputBytes: 50))
        #expect(budget.canFitReview(remainingInputBytes: 50))
        #expect(!budget.canFitReview(remainingInputBytes: 49))

        let ledger = HarnessRunLedger(
            settings: try HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 50),
            startedAt: 0
        )
        let before = ledger.snapshot
        #expect(ledger.remainingInputByteCapacity(afterPreservingInputBytes: 50) == 0)
        #expect(!ledger.canAdmit(inputBytes: 1, preservingInputBytes: 50))
        #expect(ledger.snapshot == before)
    }

    @Test("native review preserves two stage allowances")
    func nativeReviewPreservesTwoStageAllowances() {
        let budget = HarnessReviewInputBudget(stageCount: 2, maximumInputBytesPerStage: 50)
        #expect(budget.reservedInputBytes == 100)
        #expect(budget.canFitReview(remainingInputBytes: 100))
        #expect(!budget.canFitReview(remainingInputBytes: 99))
        #expect(!budget.shouldYieldEditing(remainingInputBytes: 101))
        #expect(budget.shouldYieldEditing(remainingInputBytes: 100))
    }

    @Test("preserving review bytes does not create free calls or mutate counters")
    func preservingReviewBytesDoesNotCreateFreeCallsOrMutateCounters() throws {
        var ledger = HarnessRunLedger(
            settings: try HarnessRunLedgerSettings(maxCalls: 3, maxInputBytes: 140),
            startedAt: 0
        )
        let intake = try ledger.reserve(task: .intake, inputBytes: 40, at: 1)
        try ledger.settle(intake, outcome: .succeeded, at: 1)
        let budget = HarnessReviewInputBudget(stageCount: 2, maximumInputBytesPerStage: 50)
        let before = ledger.snapshot

        #expect(ledger.remainingInputByteCapacity == 100)
        #expect(ledger.remainingInputByteCapacity(afterPreservingInputBytes: budget.reservedInputBytes) == 0)
        #expect(!ledger.canAdmit(inputBytes: 1, preservingInputBytes: budget.reservedInputBytes))
        #expect(ledger.snapshot == before)
        #expect(ledger.admittedCallCount == 1)
        #expect(ledger.settledCallCount == 1)
        #expect(ledger.accountedInputBytes == 40)
    }

    @Test("review request is accepted at its exact serialized allowance and refused below it")
    @MainActor
    func reviewRequestIsAcceptedAtItsExactSerializedAllowanceAndRefusedBelowIt() async throws {
        var physicalCalls = 0
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: .init(maxCalls: 2, maxInputBytes: 40),
            maximumDurationNanoseconds: 1_000_000_000,
            serializedInputByteCounter: { request in
                UInt64(request.systemPrompt.utf8.count + 34)
            },
            now: { 100 }
        ) { _ in
            physicalCalls += 1
            return HarnessModelReply(text: "reviewed")
        }

        _ = try await session.respond(
            phase: .review,
            systemPrompt: "sixsix",
            conversation: [],
            maximumOutputTokens: 10
        )
        do {
            _ = try await session.respond(
                phase: .review,
                systemPrompt: "sixsix",
                conversation: [],
                maximumOutputTokens: 10
            )
            Issue.record("Expected the second exact review request to be refused")
        } catch let error as HarnessRunLedgerError {
            #expect(error == .budgetExceeded(
                dimension: .inputBytes,
                limit: 40,
                requested: 40,
                available: 0
            ))
        }
        #expect(physicalCalls == 1)
        #expect(session.ledger.snapshot.admittedCallCount == 1)
        #expect(session.ledger.snapshot.accountedInputBytes == 40)
    }

    @Test("a huge image is charged exactly once and cannot buy a free retry")
    @MainActor
    func aHugeImageIsChargedExactlyOnceAndCannotBuyAFreeRetry() async throws {
        var physicalCalls = 0
        let image = Data(repeating: 0xA5, count: 300_000)
        let textBytes = "review".utf8.count + "user".utf8.count + "image".utf8.count
        let expectedInputBytes = UInt64(textBytes + image.count)
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: .init(maxCalls: 2, maxInputBytes: expectedInputBytes),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in
            physicalCalls += 1
            return HarnessModelReply(text: "ok")
        }

        _ = try await session.respond(
            phase: .review,
            systemPrompt: "review",
            conversation: [HarnessModelMessage(role: "user", text: "image", imagePNG: image)],
            maximumOutputTokens: 10
        )
        do {
            _ = try await session.respond(
                phase: .review,
                systemPrompt: "review",
                conversation: [HarnessModelMessage(role: "user", text: "image", imagePNG: image)],
                maximumOutputTokens: 10
            )
            Issue.record("Expected the repeated huge image request to be refused")
        } catch is HarnessRunLedgerError {
            // The second request is refused at admission, before transport.
        }
        #expect(physicalCalls == 1)
        #expect(session.ledger.snapshot.admittedCallCount == 1)
        #expect(session.ledger.snapshot.accountedInputBytes == expectedInputBytes)
    }

    @Test("an oversized first review leaves every counter at zero")
    @MainActor
    func anOversizedFirstReviewLeavesEveryCounterAtZero() async throws {
        var physicalCalls = 0
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: .init(maxCalls: 2, maxInputBytes: 3),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in
            physicalCalls += 1
            return HarnessModelReply(text: "unexpected")
        }

        await #expect(throws: HarnessRunLedgerError.self) {
            _ = try await session.respond(
                phase: .review,
                systemPrompt: "too large",
                conversation: [],
                maximumOutputTokens: 10
            )
        }
        #expect(physicalCalls == 0)
        #expect(session.ledger.snapshot.admittedCallCount == 0)
        #expect(session.ledger.snapshot.settledCallCount == 0)
        #expect(session.ledger.snapshot.accountedInputBytes == 0)
    }
}
