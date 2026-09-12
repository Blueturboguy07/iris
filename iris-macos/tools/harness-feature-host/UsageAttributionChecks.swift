import Foundation
@testable import IrisHarnessNative

private enum UsageAttributionCheckError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}

/// Exercises the counts-only usage seam with an inert transport. The check
/// never writes a usage file and never retains request content.
@MainActor
func runUsageAttributionChecks() async throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw UsageAttributionCheckError.failed(message) }
    }

    let systemPrompt = "PAYLOAD_SENTINEL_A-é"
    let messages = [
        HarnessModelMessage(role: "user", text: "PAYLOAD_SENTINEL_B-🧪", imagePNG: Data([1, 2, 3, 4])),
        HarnessModelMessage(role: "assistant", text: "PAYLOAD_SENTINEL_C-東京")
    ]
    var observedReservationID: HarnessRunReservationID?
    var observedInputCounts: HarnessModelInputCounts?
    let successfulSession = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        HarnessModelReply(
            text: "ok",
            usage: HarnessMeasuredUsage(
                inputTokens: 11,
                cachedInputTokens: 2,
                outputTokens: 5,
                reasoningOutputTokens: 7
            )
        )
    }
    successfulSession.admissionDidSucceed = { reservation, inputCounts in
        observedReservationID = reservation.id
        observedInputCounts = inputCounts
    }

    _ = try await successfulSession.respond(
        phase: .edit,
        systemPrompt: systemPrompt,
        conversation: messages,
        maximumOutputTokens: 10
    )

    let successfulCall = try requireCall(from: successfulSession)
    try require(observedReservationID == successfulCall.reservation.id,
                "successful admission lost its reservation identity")
    let expectedCounts = HarnessModelInputCounts(
        systemPromptUTF8Bytes: UInt64(systemPrompt.utf8.count),
        conversationTextUTF8Bytes: UInt64(messages.reduce(0) { $0 + $1.text.utf8.count }),
        rawImageBytes: 4,
        imageCount: 1
    )
    try require(observedInputCounts == expectedCounts,
                "request component counts did not use UTF-8 bytes")

    let usageDocument = IrisTestRunUsage.callDocument(
        for: successfulCall,
        inputCounts: try requireValue(observedInputCounts, message: "successful counts were missing")
    )
    let serializedUsageDocument = String(
        data: try JSONSerialization.data(withJSONObject: usageDocument, options: [.sortedKeys]),
        encoding: .utf8
    )
    try require(serializedUsageDocument?.contains(systemPrompt) == false,
                "serialized usage retained the system prompt")
    try require(serializedUsageDocument?.contains(messages[0].text) == false,
                "serialized usage retained conversation text")
    try require(serializedUsageDocument?.contains(messages[1].text) == false,
                "serialized usage retained a later conversation text")
    try require((usageDocument["systemPromptUTF8Bytes"] as? UInt64) == expectedCounts.systemPromptUTF8Bytes,
                "serialized system prompt count was missing")
    try require((usageDocument["conversationTextUTF8Bytes"] as? UInt64) == expectedCounts.conversationTextUTF8Bytes,
                "serialized conversation count was missing")
    try require((usageDocument["rawImageBytes"] as? UInt64) == expectedCounts.rawImageBytes,
                "serialized image byte count was missing")
    try require((usageDocument["imageCount"] as? UInt64) == expectedCounts.imageCount,
                "serialized image count was missing")
    try require(successfulCall.reasoningOutputTokens == 7,
                "settled ledger lost reasoning output tokens")
    try require((usageDocument["reasoningOutputTokens"] as? UInt64) == 7,
                "serialized reasoning output token count was missing")

    var aggregateLedger = HarnessRunLedger(
        settings: try HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 100),
        startedAt: 0
    )
    let firstReservation = try aggregateLedger.reserve(
        task: .edit, attempt: 1, inputBytes: 20, at: 1
    )
    try aggregateLedger.settle(
        firstReservation,
        outcome: .succeeded,
        usage: HarnessMeasuredUsage(
            inputTokens: 11,
            cachedInputTokens: 2,
            outputTokens: 5,
            reasoningOutputTokens: 7
        ),
        at: 2
    )
    _ = try aggregateLedger.reserve(task: .review, attempt: 2, inputBytes: 20, at: 3)
    let unsettledSnapshot = aggregateLedger.snapshot
    let firstCallDocument = IrisTestRunUsage.callDocument(for: unsettledSnapshot.settledCalls[0])
    let unsettledDocument = IrisTestRunUsage.snapshotDocument(
        runID: "usage-check-unsettled",
        startedAt: Date(timeIntervalSince1970: 0),
        snapshot: unsettledSnapshot,
        calls: [firstCallDocument]
    )
    for key in ["inputTokens", "cachedInputTokens", "outputTokens", "reasoningOutputTokens"] {
        try require(unsettledDocument[key] is NSNull,
                    "aggregate \(key) was reported while a call was unsettled")
    }
    try require((unsettledDocument["submittedInputBytes"] as? UInt64) == 40,
                "authoritative serialized input-byte accounting changed while tokens were unsettled")
    try require((firstCallDocument["reasoningOutputTokens"] as? UInt64) == 7,
                "settled per-call reasoning tokens disappeared while another call was in flight")

    let secondReservation = unsettledSnapshot.inFlightReservations[0].reservation
    try aggregateLedger.settle(
        secondReservation,
        outcome: .succeeded,
        usage: HarnessMeasuredUsage(
            inputTokens: 13,
            cachedInputTokens: 3,
            outputTokens: 8,
            reasoningOutputTokens: 5
        ),
        at: 4
    )
    let settledSnapshot = aggregateLedger.snapshot
    let settledDocuments = settledSnapshot.settledCalls.map { IrisTestRunUsage.callDocument(for: $0) }
    let settledDocument = IrisTestRunUsage.snapshotDocument(
        runID: "usage-check-settled",
        startedAt: Date(timeIntervalSince1970: 0),
        snapshot: settledSnapshot,
        calls: settledDocuments
    )
    try require((settledDocument["inputTokens"] as? UInt64) == 24,
                "settled aggregate input token total was not retained")
    try require((settledDocument["cachedInputTokens"] as? UInt64) == 5,
                "settled aggregate cached token total was not retained")
    try require((settledDocument["outputTokens"] as? UInt64) == 13,
                "settled aggregate output token total was not retained")
    try require((settledDocument["reasoningOutputTokens"] as? UInt64) == 12,
                "settled aggregate reasoning token total was not retained")
    try require((settledDocuments[0]["reasoningOutputTokens"] as? UInt64) == 7
                    && (settledDocuments[1]["reasoningOutputTokens"] as? UInt64) == 5,
                "settled per-call reasoning token records were not retained")

    struct TransportFailure: Error {}
    let failedUsage = IrisTestRunUsage()
    let failedSystemPrompt = "FAILED_PAYLOAD_SENTINEL"
    let failedMessageText = "FAILED_TEXT_SENTINEL"
    let failedSession = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 10_000),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        throw HarnessModelTransportFailure(cause: TransportFailure(), usage: nil)
    }
    failedSession.admissionDidSucceed = { reservation, inputCounts in
        failedUsage.recordAdmission(reservation, inputCounts: inputCounts)
    }
    var transportFailed = false
    do {
        _ = try await failedSession.respond(
            phase: .edit,
            systemPrompt: failedSystemPrompt,
            conversation: [HarnessModelMessage(role: "user", text: failedMessageText)],
            maximumOutputTokens: 10
        )
    } catch is TransportFailure {
        transportFailed = true
    }
    try require(transportFailed, "transport failure was not surfaced")
    let failedCall = try requireCall(from: failedSession)
    try require(failedCall.outcome == .failed,
                "transport failure did not settle as failed")
    let failedDocument = failedUsage.callDocument(for: failedCall)
    try require(failedDocument["systemPromptUTF8Bytes"] as? UInt64 == UInt64(failedSystemPrompt.utf8.count),
                "failed transport lost admitted counts")
    try require(failedDocument["conversationTextUTF8Bytes"] as? UInt64 == UInt64(failedMessageText.utf8.count),
                "failed transport lost conversation count")

    var rejectedCallbackCount = 0
    let rejectedSession = try HarnessModelSession(
        implementationArm: .astraLow,
        settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 1),
        maximumDurationNanoseconds: 1_000_000_000,
        now: { 100 }
    ) { _ in
        throw UsageAttributionCheckError.failed("a rejected request reached transport")
    }
    rejectedSession.admissionDidSucceed = { _, _ in rejectedCallbackCount += 1 }
    var rejected = false
    do {
        _ = try await rejectedSession.respond(
            phase: .edit,
            systemPrompt: "REJECTED_PAYLOAD_SENTINEL",
            conversation: [],
            maximumOutputTokens: 10
        )
    } catch is HarnessRunLedgerError {
        rejected = true
    }
    try require(rejected, "budget rejection was not surfaced")
    try require(rejectedCallbackCount == 0,
                "rejected admission invoked the attribution callback")
    try require(rejectedSession.ledger.snapshot.admittedCallCount == 0,
                "rejected admission changed ledger accounting")

    var legacyLedger = HarnessRunLedger(
        settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 100),
        startedAt: 0
    )
    let legacyReservation = try legacyLedger.reserve(task: .review, inputBytes: 8, at: 1)
    try legacyLedger.settle(legacyReservation, outcome: .cancelled, at: 2)
    let legacyDocument = IrisTestRunUsage.callDocument(
        for: try requireCall(from: legacyLedger.snapshot)
    )
    try require(legacyDocument["systemPromptUTF8Bytes"] == nil
                    && legacyDocument["conversationTextUTF8Bytes"] == nil
                    && legacyDocument["rawImageBytes"] == nil
                    && legacyDocument["imageCount"] == nil,
                "legacy usage document gained fabricated attribution")
    print("PASS usage attribution checks: UTF-8 component counts, token attribution, unsettled aggregate omission, payload-free success/failure, rejected admission absence, legacy omission")
}

@MainActor
private func requireCall(from session: HarnessModelSession) throws -> HarnessRunCallRecord {
    try requireCall(from: session.ledger.snapshot)
}

@MainActor
private func requireCall(from snapshot: HarnessRunLedgerSnapshot) throws -> HarnessRunCallRecord {
    guard let call = snapshot.settledCalls.first else {
        throw UsageAttributionCheckError.failed("the expected settled call was missing")
    }
    return call
}

@MainActor
private func requireValue<T>(_ value: T?, message: String) throws -> T {
    guard let value else { throw UsageAttributionCheckError.failed(message) }
    return value
}
