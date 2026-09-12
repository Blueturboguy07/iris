import Foundation
import Testing
@testable import Iris

@MainActor
struct IrisTestRunUsageTests {
    @Test("usage records reserved input bytes for each settled call")
    func recordsReservedInputBytes() throws {
        var ledger = HarnessRunLedger(
            settings: try HarnessRunLedgerSettings(maxCalls: 2, maxInputBytes: 2_000),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .repair, inputBytes: 1_234, at: 1)
        try ledger.settle(
            reservation,
            outcome: .failed,
            usage: HarnessMeasuredUsage(inputBytes: 17, inputTokens: 9, outputTokens: 5),
            at: 2
        )
        guard let record = ledger.snapshot.settledCalls.first else {
            Issue.record("The settled call record is required")
            return
        }

        let document = IrisTestRunUsage.callDocument(for: record)
        #expect(document["inputBytes"] as? UInt64 == 1_234)
        #expect(document["inputTokens"] as? UInt64 == 9)
        #expect(document["outputTokens"] as? UInt64 == 5)
    }

    @Test("admitted request counts attach to the settled reservation")
    func admittedRequestCountsAttachToSettledReservation() throws {
        var ledger = HarnessRunLedger(
            settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 10_000),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .edit, inputBytes: 456, at: 1)
        let inputCounts = HarnessModelInputCounts(
            systemPromptUTF8Bytes: 12,
            conversationTextUTF8Bytes: 34,
            rawImageBytes: 56,
            imageCount: 1
        )
        let usage = IrisTestRunUsage()
        usage.recordAdmission(reservation, inputCounts: inputCounts)
        try ledger.settle(reservation, outcome: .succeeded, at: 2)

        let document = usage.callDocument(for: try #require(ledger.snapshot.settledCalls.first))
        #expect(document["inputBytes"] as? UInt64 == 456)
        #expect(document["systemPromptUTF8Bytes"] as? UInt64 == 12)
        #expect(document["conversationTextUTF8Bytes"] as? UInt64 == 34)
        #expect(document["rawImageBytes"] as? UInt64 == 56)
        #expect(document["imageCount"] as? UInt64 == 1)
    }

    @Test("the session reports counts for a successful admitted request")
    func sessionReportsCountsForSuccessfulAdmission() async throws {
        let systemPrompt = "PAYLOAD_SENTINEL_A-é"
        let messages = [
            HarnessModelMessage(role: "user", text: "PAYLOAD_SENTINEL_B-🧪", imagePNG: Data([1, 2, 3])),
            HarnessModelMessage(role: "assistant", text: "PAYLOAD_SENTINEL_C-東京")
        ]
        let expectedConversationTextUTF8Bytes = messages.reduce(UInt64(0)) {
            $0 + UInt64($1.text.utf8.count)
        }
        var observedReservationID: HarnessRunReservationID?
        var observedInputCounts: HarnessModelInputCounts?
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 1_000),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in
            HarnessModelReply(text: "ok")
        }
        session.admissionDidSucceed = { reservation, inputCounts in
            observedReservationID = reservation.id
            observedInputCounts = inputCounts
        }

        _ = try await session.respond(
            phase: .edit,
            systemPrompt: systemPrompt,
            conversation: messages,
            maximumOutputTokens: 10
        )

        let settledReservation = try #require(session.ledger.snapshot.settledCalls.first?.reservation)
        #expect(observedReservationID == settledReservation.id)
        #expect(observedInputCounts == HarnessModelInputCounts(
            systemPromptUTF8Bytes: UInt64(systemPrompt.utf8.count),
            conversationTextUTF8Bytes: expectedConversationTextUTF8Bytes,
            rawImageBytes: 3,
            imageCount: 1
        ))
        let usageDocument = IrisTestRunUsage.callDocument(
            for: try #require(session.ledger.snapshot.settledCalls.first),
            inputCounts: try #require(observedInputCounts)
        )
        let serializedUsageDocument = String(
            data: try JSONSerialization.data(withJSONObject: usageDocument, options: [.sortedKeys]),
            encoding: .utf8
        )
        #expect(serializedUsageDocument?.contains(systemPrompt) == false)
        #expect(serializedUsageDocument?.contains(messages[0].text) == false)
        #expect(serializedUsageDocument?.contains(messages[1].text) == false)
    }

    @Test("counts remain available when admitted transport work fails")
    func countsRemainAvailableWhenTransportFails() async throws {
        struct TransportFailure: Error {}
        let inputCountsByReservation = IrisTestRunUsage()
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 1_000),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in
            throw HarnessModelTransportFailure(
                cause: TransportFailure(),
                usage: nil
            )
        }
        session.admissionDidSucceed = { reservation, inputCounts in
            inputCountsByReservation.recordAdmission(reservation, inputCounts: inputCounts)
        }

        await #expect(throws: TransportFailure.self) {
            _ = try await session.respond(
                phase: .edit,
                systemPrompt: "system",
                conversation: [HarnessModelMessage(role: "user", text: "message")],
                maximumOutputTokens: 10
            )
        }

        let failedCall = try #require(session.ledger.snapshot.settledCalls.first)
        let document = inputCountsByReservation.callDocument(for: failedCall)
        #expect(failedCall.outcome == .failed)
        #expect(document["systemPromptUTF8Bytes"] as? UInt64 == 6)
        #expect(document["conversationTextUTF8Bytes"] as? UInt64 == 7)
        #expect(document["rawImageBytes"] as? UInt64 == 0)
        #expect(document["imageCount"] as? UInt64 == 0)
    }

    @Test("a rejected request has no admitted input counts")
    func rejectedRequestHasNoAdmittedInputCounts() async throws {
        var callbackCount = 0
        let session = try HarnessModelSession(
            implementationArm: .astraLow,
            settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 1),
            maximumDurationNanoseconds: 1_000_000_000,
            now: { 100 }
        ) { _ in
            Issue.record("A budget-rejected request reached transport")
            return HarnessModelReply(text: "unexpected")
        }
        session.admissionDidSucceed = { _, _ in callbackCount += 1 }

        await #expect(throws: HarnessRunLedgerError.self) {
            _ = try await session.respond(
                phase: .edit,
                systemPrompt: "too large",
                conversation: [],
                maximumOutputTokens: 10
            )
        }

        #expect(callbackCount == 0)
        #expect(session.ledger.snapshot.admittedCallCount == 0)
        #expect(session.ledger.snapshot.settledCalls.isEmpty)
    }

    @Test("usage keeps the existing per-call fields and unknown measurements")
    func preservesExistingCallFieldsAndUnknownMeasurements() throws {
        var ledger = HarnessRunLedger(
            settings: try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 100),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .review, inputBytes: 42, at: 1)
        try ledger.settle(reservation, outcome: .cancelled, at: 2)
        guard let record = ledger.snapshot.settledCalls.first else {
            Issue.record("The settled call record is required")
            return
        }

        let document = IrisTestRunUsage.callDocument(for: record)
        #expect(document["phase"] as? String == "review")
        #expect(document["outcome"] as? String == "cancelled")
        #expect(document["inputBytes"] as? UInt64 == 42)
        #expect(document["inputTokens"] is NSNull)
        #expect(document["cachedInputTokens"] is NSNull)
        #expect(document["outputTokens"] is NSNull)
        #expect(document["systemPromptUTF8Bytes"] == nil)
        #expect(document["conversationTextUTF8Bytes"] == nil)
        #expect(document["rawImageBytes"] == nil)
        #expect(document["imageCount"] == nil)

        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["inputBytes"] as? NSNumber)?.uint64Value == 42)
        #expect(decoded["inputTokens"] is NSNull)
    }
}
