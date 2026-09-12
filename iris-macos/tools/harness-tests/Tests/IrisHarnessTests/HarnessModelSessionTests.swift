import Foundation
import Testing
@testable import IrisHarness

@Test @MainActor func inputBudgetFailureIsReadableAndDoesNotSendAnotherRequest() async throws {
    var physicalCalls = 0
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: .init(maxCalls: 12, maxInputBytes: 8),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in
            physicalCalls += 1
            return HarnessModelReply(text: "ok")
        }
    _ = try await session.respond(phase: .edit, systemPrompt: "saved", conversation: [], maximumOutputTokens: 10)
    do {
        _ = try await session.respond(phase: .edit, systemPrompt: "larger", conversation: [], maximumOutputTokens: 10)
        Issue.record("Expected the input budget to refuse the second request")
    } catch {
        #expect(error.localizedDescription.contains("input-data allowance"))
        #expect(error.localizedDescription.contains("still need verification"))
        #expect(!error.localizedDescription.contains("error 3"))
    }
    #expect(physicalCalls == 1)
    #expect(session.ledger.snapshot.admittedCallCount == 1)
    #expect(session.ledger.snapshot.accountedInputBytes == 5)
}

@Test @MainActor func exactCandidateThatWouldConsumeReviewReserveYieldsBeforeAdmission() async throws {
    var physicalCalls = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 4, maxInputBytes: 400 * 1024),
        maximumDurationNanoseconds: 1_000_000_000,
        serializedInputByteCounter: { _ in 300 * 1024 },
        now: { 100 }
    ) { _ in
        physicalCalls += 1
        return HarnessModelReply(text: "unexpected")
    }

    do {
        _ = try await session.respond(
            phase: .edit,
            systemPrompt: "candidate",
            conversation: [],
            maximumOutputTokens: 10,
            preservingInputBytes: 336 * 1024
        )
        Issue.record("Expected exact request preflight to yield to verification")
    } catch let error as HarnessModelSession.SessionError {
        let expected = HarnessModelSession.SessionError.yieldToVerification(
            inputBytes: 300 * 1024,
            preservedInputBytes: 336 * 1024,
            availableInputBytes: 64 * 1024
        )
        #expect(error == expected)
    }
    #expect(physicalCalls == 0)
    #expect(session.ledger.snapshot.admittedCallCount == 0)
    #expect(session.ledger.snapshot.settledCallCount == 0)
    #expect(session.ledger.snapshot.accountedInputBytes == 0)
}

@Test @MainActor func exactCandidateFitLeavesTheReviewReserveAvailable() async throws {
    var physicalCalls = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 4, maxInputBytes: 400 * 1024),
        maximumDurationNanoseconds: 1_000_000_000,
        serializedInputByteCounter: { _ in 64 * 1024 },
        now: { 100 }
    ) { _ in
        physicalCalls += 1
        return HarnessModelReply(text: "accepted")
    }

    _ = try await session.respond(
        phase: .edit,
        systemPrompt: "candidate",
        conversation: [],
        maximumOutputTokens: 10,
        preservingInputBytes: 336 * 1024
    )
    #expect(physicalCalls == 1)
    #expect(session.ledger.snapshot.admittedCallCount == 1)
    #expect(session.ledger.snapshot.accountedInputBytes == 64 * 1024)

    do {
        _ = try await session.respond(
            phase: .edit,
            systemPrompt: "candidate",
            conversation: [],
            maximumOutputTokens: 10,
            preservingInputBytes: 336 * 1024
        )
        Issue.record("Expected the next request at the reserve boundary to yield")
    } catch let error as HarnessModelSession.SessionError {
        let expected = HarnessModelSession.SessionError.yieldToVerification(
            inputBytes: 64 * 1024,
            preservedInputBytes: 336 * 1024,
            availableInputBytes: 0
        )
        #expect(error == expected)
    }
    #expect(physicalCalls == 1)
    #expect(session.ledger.snapshot.admittedCallCount == 1)
}

@Test @MainActor func reviewRequestIsNotChargedAgainstAnEditReserve() async throws {
    var physicalCalls = 0
    let session = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: .init(maxCalls: 2, maxInputBytes: 400 * 1024),
        maximumDurationNanoseconds: 1_000_000_000,
        serializedInputByteCounter: { _ in 300 * 1024 },
        now: { 100 }
    ) { _ in
        physicalCalls += 1
        return HarnessModelReply(text: "review accepted")
    }

    _ = try await session.respond(
        phase: .review,
        systemPrompt: "review",
        conversation: [],
        maximumOutputTokens: 10,
        preservingInputBytes: 0
    )
    #expect(physicalCalls == 1)
    #expect(session.ledger.snapshot.admittedCallCount == 1)
    #expect(session.ledger.snapshot.accountedInputBytes == 300 * 1024)
}

@Test @MainActor func checkpointsAdmissionAndBothSettlementOutcomes() async throws {
    struct Failed: Error {}
    var calls = 0
    var checkpoints: [HarnessRunLedgerSnapshot] = []
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in
            calls += 1
            if calls == 2 { throw Failed() }
            return HarnessModelReply(text: "ok", usage: .init(inputTokens: 12))
        }
    session.ledgerDidChange = { checkpoints.append($0) }
    _ = try await session.respond(phase: .intake, systemPrompt: "plan", conversation: [], maximumOutputTokens: 10)
    await #expect(throws: Failed.self) {
        _ = try await session.respond(phase: .edit, systemPrompt: "edit", conversation: [], maximumOutputTokens: 10)
    }
    #expect(checkpoints.map(\.admittedCallCount) == [1, 1, 2, 2])
    #expect(checkpoints.map(\.settledCallCount) == [0, 1, 1, 2])
    #expect(checkpoints.map(\.inFlightCallCount) == [1, 0, 1, 0])
    #expect(checkpoints[1].measuredInputTokens == 12)
    #expect(checkpoints[3].measuredInputTokens == nil)
}

@Test @MainActor func planningAndImplementationShareAccountingButNotRequestedRoles() async throws {
    var requests: [HarnessModelRequest] = []
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { request in
            requests.append(request)
            return HarnessModelReply(text: "observed response", usage: .init(inputTokens: 12, outputTokens: 3))
        }
    _ = try await session.respond(phase: .intake, systemPrompt: "plan", conversation: [], maximumOutputTokens: 300)
    _ = try await session.respond(phase: .edit, systemPrompt: "build", conversation: [], maximumOutputTokens: 4000)
    #expect(requests.map(\.route) == [.planner, HarnessImplementationArm.astraLow.route])
    #expect(session.ledger.snapshot.admittedCallCount == 2)
    #expect(session.ledger.snapshot.measuredInputTokens == 24)
    await #expect(throws: (any Error).self) {
        _ = try await session.respond(phase: .review, systemPrompt: "review", conversation: [], maximumOutputTokens: 300)
    }
    #expect(requests.count == 2)
}

@Test @MainActor func failedProviderWorkStillConsumesOneAttempt() async throws {
    struct Dropped: Error {}
    let session = try HarnessModelSession(implementationArm: .lunaXHigh,
        settings: HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in throw Dropped() }
    await #expect(throws: Dropped.self) {
        _ = try await session.respond(phase: .edit, systemPrompt: "task", conversation: [], maximumOutputTokens: 100)
    }
    #expect(session.ledger.snapshot.admittedCallCount == 1)
    #expect(session.ledger.snapshot.measuredInputTokens == nil)
    #expect(session.ledger.snapshot.inFlightCallCount == 0)
}

@Test @MainActor func rejectedLargeReplyIsNotReportedAsFree() async throws {
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, maximumReplyBytes: 4, now: { 100 }) { _ in
            HarnessModelReply(text: "too long", usage: .init(inputTokens: 10, outputTokens: 10))
        }
    await #expect(throws: HarnessModelSession.SessionError.self) {
        _ = try await session.respond(phase: .edit, systemPrompt: "task", conversation: [], maximumOutputTokens: 10)
    }
    #expect(session.ledger.snapshot.measuredOutputTokens == 10)
}

@Test @MainActor func usageReportedOnFailureIsNotLost() async throws {
    struct Interrupted: Error {}
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in
            throw HarnessModelTransportFailure(cause: Interrupted(),
                usage: .init(inputTokens: 20, cachedInputTokens: 10, outputTokens: 4))
        }
    await #expect(throws: Interrupted.self) {
        _ = try await session.respond(phase: .repair, systemPrompt: "repair", conversation: [], maximumOutputTokens: 10)
    }
    #expect(session.ledger.snapshot.measuredInputTokens == 20)
    #expect(session.ledger.snapshot.measuredCachedInputTokens == 10)
    #expect(session.ledger.snapshot.measuredOutputTokens == 4)
    #expect(session.ledger.snapshot.measuredReasoningOutputTokens == nil)
}

@Test @MainActor func cancelledTaskCannotStartAnotherCall() async throws {
    var physicalCalls = 0
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in
            physicalCalls += 1
            return HarnessModelReply(text: "unexpected")
        }
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await session.respond(phase: .edit, systemPrompt: "edit", conversation: [], maximumOutputTokens: 10)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(physicalCalls == 0)
    #expect(session.ledger.snapshot.admittedCallCount == 0)
}

@Test @MainActor func invalidOutputLimitDoesNotSpendACall() async throws {
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000, now: { 100 }) { _ in HarnessModelReply(text: "unexpected") }
    await #expect(throws: HarnessModelSession.SessionError.self) {
        _ = try await session.respond(phase: .edit, systemPrompt: "edit", conversation: [], maximumOutputTokens: 0)
    }
    #expect(session.ledger.snapshot.admittedCallCount == 0)
}

@Test @MainActor func deadlineCancelsAStalledTransport() async throws {
    var cancelled = false
    let session = try HarnessModelSession(implementationArm: .astraLow,
        settings: HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 50_000_000) { _ in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { cancelled = true; throw error }
            return HarnessModelReply(text: "too late")
        }
    await #expect(throws: HarnessModelSession.SessionError.self) {
        _ = try await session.respond(phase: .edit, systemPrompt: "edit", conversation: [], maximumOutputTokens: 10)
    }
    #expect(cancelled)
    #expect(session.ledger.snapshot.admittedCallCount == 1)
    #expect(session.ledger.snapshot.inFlightCallCount == 0)
}
