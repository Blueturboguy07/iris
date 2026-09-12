import Testing
@testable import IrisHarness

@Suite("Harness run ledger")
struct HarnessRunLedgerTests {
    private func settings(
        maxCalls: Int,
        maxInputBytes: Int
    ) throws -> HarnessRunLedgerSettings {
        try HarnessRunLedgerSettings(
            maxCalls: maxCalls,
            maxInputBytes: maxInputBytes
        )
    }

    private func expectLedgerError(
        _ expected: HarnessRunLedgerError,
        operation: () throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try operation()
            Issue.record("Expected \(expected), but the operation succeeded", sourceLocation: sourceLocation)
        } catch let error as HarnessRunLedgerError {
            #expect(error == expected, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected \(expected), got \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test("settings reject negative and zero limits")
    func settingsRejectNegativeAndZeroLimits() {
        do {
            _ = try HarnessRunLedgerSettings(maxCalls: -1, maxInputBytes: 10)
            Issue.record("A negative call limit must be rejected")
        } catch let error as HarnessRunLedgerSettingsError {
            #expect(error == .negativeLimit(.calls))
        } catch {
            Issue.record("Unexpected settings error: \(error)")
        }

        do {
            _ = try HarnessRunLedgerSettings(maxCalls: 1, maxInputBytes: 0)
            Issue.record("A zero byte limit must be rejected")
        } catch let error as HarnessRunLedgerSettingsError {
            #expect(error == .zeroLimit(.inputBytes))
        } catch {
            Issue.record("Unexpected settings error: \(error)")
        }
    }

    @Test("all task kinds share one run budget and retries count separately")
    func allTaskKindsShareOneRunBudgetAndRetriesCountSeparately() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 7, maxInputBytes: 70),
            startedAt: 0
        )
        let taskKinds = HarnessRunTaskKind.allCases
        var timestamp: UInt64 = 1

        for task in taskKinds {
            let reservation = try ledger.admit(
                task: task,
                inputBytes: 10,
                at: HarnessMonotonicTime(nanoseconds: timestamp)
            )
            try ledger.settle(
                reservation,
                outcome: .succeeded,
                usage: HarnessMeasuredUsage(
                    inputBytes: 10,
                    inputTokens: 2,
                    outputTokens: 3
                ),
                at: HarnessMonotonicTime(nanoseconds: timestamp)
            )
            timestamp += 1
        }

        let retryOne = try ledger.reserve(
            task: .edit,
            attempt: 1,
            inputBytes: 10,
            at: HarnessMonotonicTime(nanoseconds: timestamp)
        )
        timestamp += 1
        let retryTwo = try ledger.reserve(
            task: .edit,
            attempt: 2,
            inputBytes: 10,
            at: HarnessMonotonicTime(nanoseconds: timestamp)
        )
        try ledger.settle(retryOne, outcome: .failed, at: HarnessMonotonicTime(nanoseconds: timestamp))
        timestamp += 1
        try ledger.settle(retryTwo, outcome: .cancelled, at: HarnessMonotonicTime(nanoseconds: timestamp))

        #expect(ledger.admittedCallCount == 7)
        #expect(ledger.settledCallCount == 7)
        #expect(ledger.settledCalls.map { $0.reservation.task } == taskKinds + [.edit, .edit])
        #expect(ledger.settledCalls.suffix(2).map { $0.reservation.attempt } == [1, 2])
    }

    @Test("missing usage stays unknown and failed or cancelled calls remain accounted")
    func missingUsageStaysUnknownAndFailedOrCancelledCallsRemainAccounted() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 3, maxInputBytes: 100),
            startedAt: 0
        )
        let failed = try ledger.reserve(task: .review, inputBytes: 12, at: 1)
        try ledger.settle(failed, outcome: .failed, at: 1)

        let cancelled = try ledger.reserve(task: .repair, inputBytes: 20, at: 2)
        try ledger.settle(
            cancelled,
            outcome: .cancelled,
            usage: HarnessMeasuredUsage(inputBytes: 15),
            at: 2
        )

        let snapshot = ledger.snapshot
        #expect(snapshot.admittedCallCount == 2)
        #expect(snapshot.settledCallCount == 2)
        #expect(snapshot.accountedInputBytes == 27)
        #expect(snapshot.measuredInputTokens == nil)
        #expect(snapshot.measuredOutputTokens == nil)
        #expect(snapshot.settledCalls[0].measuredInputBytes == nil)
        #expect(snapshot.settledCalls[0].accountedInputBytes == 12)
        #expect(snapshot.settledCalls[0].outcome == .failed)
        #expect(snapshot.settledCalls[1].outcome == .cancelled)
    }

    @Test("reported token families stay separate and sum only when all are known")
    func reportedTokenFamiliesStaySeparateAndSumOnlyWhenAllAreKnown() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 2, maxInputBytes: 20),
            startedAt: 0
        )
        let first = try ledger.reserve(task: .intake, inputBytes: 10, at: 1)
        try ledger.settle(
            first,
            outcome: .succeeded,
            usage: HarnessMeasuredUsage(
                inputBytes: 10,
                inputTokens: 2,
                cachedInputTokens: 3,
                outputTokens: 5,
                reasoningOutputTokens: 7
            ),
            at: 1
        )
        let second = try ledger.reserve(task: .review, inputBytes: 10, at: 2)
        try ledger.settle(
            second,
            outcome: .succeeded,
            usage: HarnessMeasuredUsage(
                inputBytes: 10,
                inputTokens: 11,
                cachedInputTokens: 13,
                outputTokens: 17,
                reasoningOutputTokens: 19
            ),
            at: 2
        )

        let snapshot = ledger.snapshot
        #expect(snapshot.measuredInputTokens == 13)
        #expect(snapshot.measuredCachedInputTokens == 16)
        #expect(snapshot.measuredOutputTokens == 22)
        #expect(snapshot.measuredReasoningOutputTokens == 26)
        #expect(snapshot.settledCalls[0].outputTokens == 5)
        #expect(snapshot.settledCalls[0].reasoningOutputTokens == 7)
    }

    @Test("uncertain failures retain reservations until explicit resolution")
    func uncertainFailuresRetainReservationsUntilExplicitResolution() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 3, maxInputBytes: 100),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .edit, inputBytes: 60, at: 1)
        try ledger.markUncertainFailure(reservation.id, at: 2)

        #expect(ledger.snapshot.inFlightCallCount == 1)
        #expect(ledger.snapshot.inFlightInputBytes == 60)
        #expect(ledger.remainingInputByteCapacity == 40)
        #expect(ledger.snapshot.inFlightReservations[0].state == .uncertainFailure)

        expectLedgerError(
            .reservationIsUncertain(reservation.id),
            operation: {
                try ledger.settle(reservation.id, outcome: .failed, at: 2)
            }
        )
        expectLedgerError(
            .budgetExceeded(
                dimension: .inputBytes,
                limit: 100,
                requested: 41,
                available: 40
            ),
            operation: {
                _ = try ledger.reserve(task: .recheck, inputBytes: 41, at: 2)
            }
        )

        try ledger.resolveUncertainFailure(
            reservation.id,
            outcome: .failed,
            at: 3
        )
        #expect(ledger.snapshot.inFlightReservations.isEmpty)
        #expect(ledger.snapshot.accountedInputBytes == 60)
        #expect(ledger.snapshot.settledCalls[0].outcome == .failed)

        expectLedgerError(
            .duplicateSettlement(reservation.id),
            operation: {
                try ledger.resolveUncertainFailure(reservation.id, outcome: .failed, at: 3)
            }
        )
    }

    @Test("duplicate and unknown settlements are rejected without changing the record")
    func duplicateAndUnknownSettlementsAreRejectedWithoutChangingTheRecord() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 2, maxInputBytes: 20),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .intake, inputBytes: 8, at: 1)
        try ledger.settle(reservation, outcome: .succeeded, at: 1)
        let eventsBeforeDuplicate = ledger.events

        expectLedgerError(
            .duplicateSettlement(reservation.id),
            operation: {
                try ledger.settle(reservation.id, outcome: .succeeded, at: 1)
            }
        )
        expectLedgerError(
            .unknownReservation(HarnessRunReservationID(rawValue: 999)),
            operation: {
                try ledger.settle(
                    HarnessRunReservationID(rawValue: 999),
                    outcome: .failed,
                    at: 1
                )
            }
        )

        #expect(ledger.events == eventsBeforeDuplicate)
        #expect(ledger.snapshot.settledCallCount == 1)
    }

    @Test("call and input byte budget failures do not mutate the ledger")
    func callAndInputByteBudgetFailuresDoNotMutateTheLedger() throws {
        var callLimited = HarnessRunLedger(
            settings: try settings(maxCalls: 1, maxInputBytes: 100),
            startedAt: 0
        )
        _ = try callLimited.reserve(task: .intake, inputBytes: 1, at: 1)
        let callEvents = callLimited.events
        expectLedgerError(
            .budgetExceeded(dimension: .calls, limit: 1, requested: 1, available: 0),
            operation: {
                _ = try callLimited.reserve(task: .edit, inputBytes: 1, at: 2)
            }
        )
        #expect(callLimited.events == callEvents)
        #expect(callLimited.admittedCallCount == 1)

        var byteLimited = HarnessRunLedger(
            settings: try settings(maxCalls: 2, maxInputBytes: 10),
            startedAt: 0
        )
        _ = try byteLimited.reserve(task: .intake, inputBytes: 9, at: 1)
        let byteEvents = byteLimited.events
        expectLedgerError(
            .budgetExceeded(dimension: .inputBytes, limit: 10, requested: 2, available: 1),
            operation: {
                _ = try byteLimited.reserve(task: .edit, inputBytes: 2, at: 2)
            }
        )
        #expect(byteLimited.events == byteEvents)
        #expect(byteLimited.accountedInputBytes == 9)
    }

    @Test("provided timestamps cannot move backwards")
    func providedTimestampsCannotMoveBackwards() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 1, maxInputBytes: 10),
            startedAt: 5
        )
        let reservation = try ledger.reserve(task: .intake, inputBytes: 3, at: 10)
        expectLedgerError(
            .timestampWentBackwards(previous: 10, provided: 9),
            operation: {
                try ledger.settle(reservation, outcome: .succeeded, at: 9)
            }
        )
        #expect(ledger.snapshot.settledCallCount == 0)
        try ledger.settle(reservation, outcome: .succeeded, at: 10)
    }

    @Test("token total overflow is refused instead of wrapping")
    func tokenTotalOverflowIsRefusedInsteadOfWrapping() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 2, maxInputBytes: 2),
            startedAt: 0
        )
        let first = try ledger.reserve(task: .intake, inputBytes: 1, at: 1)
        try ledger.settle(
            first,
            outcome: .succeeded,
            usage: HarnessMeasuredUsage(
                inputBytes: 1,
                inputTokens: UInt64.max,
                outputTokens: UInt64.max
            ),
            at: 1
        )
        let second = try ledger.reserve(task: .recheck, inputBytes: 1, at: 2)
        expectLedgerError(
            .integerOverflow(.inputTokens),
            operation: {
                try ledger.settle(
                    second,
                    outcome: .succeeded,
                    usage: HarnessMeasuredUsage(inputBytes: 1, inputTokens: 1, outputTokens: 1),
                    at: 2
                )
            }
        )

        #expect(ledger.snapshot.settledCallCount == 1)
        #expect(ledger.snapshot.measuredInputTokens == UInt64.max)
        #expect(ledger.snapshot.measuredOutputTokens == UInt64.max)
        #expect(ledger.snapshot.inFlightReservations.count == 1)
    }

    @Test("stop preserves an explicit reason and rejects new reservations")
    func stopPreservesAnExplicitReasonAndRejectsNewReservations() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 2, maxInputBytes: 20),
            startedAt: 0
        )
        try ledger.stop(reason: .budgetLimited, at: 1)
        #expect(ledger.status == .stopped(.budgetLimited))

        expectLedgerError(
            .runStopped(.budgetLimited),
            operation: {
                _ = try ledger.reserve(task: .repair, inputBytes: 1, at: 2)
            }
        )
        expectLedgerError(
            .runAlreadyStopped(.budgetLimited),
            operation: {
                try ledger.stop(reason: .cancelled, at: 2)
            }
        )
    }

    @Test("measured input bytes cannot exceed their admission reservation")
    func measuredInputBytesCannotExceedTheirAdmissionReservation() throws {
        var ledger = HarnessRunLedger(
            settings: try settings(maxCalls: 1, maxInputBytes: 10),
            startedAt: 0
        )
        let reservation = try ledger.reserve(task: .review, inputBytes: 4, at: 1)
        expectLedgerError(
            .measurementExceedsReservation(id: reservation.id, reserved: 4, measured: 5),
            operation: {
                try ledger.settle(
                    reservation,
                    outcome: .failed,
                    usage: HarnessMeasuredUsage(inputBytes: 5),
                    at: 1
                )
            }
        )
        try ledger.settle(reservation, outcome: .failed, at: 1)
        #expect(ledger.snapshot.accountedInputBytes == 4)
    }
}
