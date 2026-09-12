//
//  HarnessRunLedger.swift
//
//  Pure run-wide accounting and admission policy for the harness. This file
//  deliberately knows nothing about providers, prices, persistence or UI.
//

import Foundation

nonisolated public struct HarnessMonotonicTime: Comparable, Equatable, Hashable, Sendable,
    ExpressibleByIntegerLiteral {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public init(integerLiteral value: UInt64) {
        self.init(nanoseconds: value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

nonisolated public enum HarnessRunTaskKind: String, CaseIterable, Codable, Sendable {
    case intake
    case edit
    case review
    case repair
    case recheck
}

nonisolated public enum HarnessRunBudgetDimension: String, Codable, Sendable {
    case calls
    case inputBytes
    case inputTokens
    case cachedInputTokens
    case outputTokens
    case reasoningOutputTokens
    case reservationID
}

nonisolated public enum HarnessRunLedgerSettingsError: Error, Equatable, Sendable {
    case negativeLimit(HarnessRunBudgetDimension)
    case zeroLimit(HarnessRunBudgetDimension)
    case integerOverflow(HarnessRunBudgetDimension)
}

/// The only admission limits the generic harness promises to enforce.
///
/// Both limits are finite and positive. The generic integer initializer lets
/// callers validate signed configuration values without silently converting a
/// negative value into a very large unsigned limit.
nonisolated public struct HarnessRunLedgerSettings: Equatable, Sendable {
    public let maxCalls: UInt64
    public let maxInputBytes: UInt64

    public init<T: BinaryInteger>(maxCalls: T, maxInputBytes: T) throws {
        if maxCalls < 0 {
            throw HarnessRunLedgerSettingsError.negativeLimit(.calls)
        }
        if maxInputBytes < 0 {
            throw HarnessRunLedgerSettingsError.negativeLimit(.inputBytes)
        }

        guard let callLimit = UInt64(exactly: maxCalls) else {
            throw HarnessRunLedgerSettingsError.integerOverflow(.calls)
        }
        guard let inputLimit = UInt64(exactly: maxInputBytes) else {
            throw HarnessRunLedgerSettingsError.integerOverflow(.inputBytes)
        }
        guard callLimit > 0 else {
            throw HarnessRunLedgerSettingsError.zeroLimit(.calls)
        }
        guard inputLimit > 0 else {
            throw HarnessRunLedgerSettingsError.zeroLimit(.inputBytes)
        }

        self.maxCalls = callLimit
        self.maxInputBytes = inputLimit
    }
}

/// A read-only allowance kept available for the independent review stages.
///
/// This is deliberately separate from the ledger's admitted counters. It does
/// not spend a call or input byte, and it never changes the hard limits. The
/// default per-stage allowance is the sum of the existing bounded review
/// materials plus provider framing room:
/// 64 KiB diff, 64 KiB repository context, 16 KiB evidence, 8 KiB request
/// metadata, and 16 KiB serialized framing.
nonisolated public struct HarnessReviewInputBudget: Equatable, Sendable {
    public static let boundedReviewDiffBytes: UInt64 = 64 * 1024
    public static let boundedReviewContextBytes: UInt64 = 64 * 1024
    public static let boundedReviewEvidenceBytes: UInt64 = 16 * 1024
    public static let boundedReviewRequestBytes: UInt64 = 8 * 1024
    public static let boundedProviderFramingBytes: UInt64 = 16 * 1024
    public static let defaultMaximumInputBytesPerStage: UInt64 =
        boundedReviewDiffBytes
        + boundedReviewContextBytes
        + boundedReviewEvidenceBytes
        + boundedReviewRequestBytes
        + boundedProviderFramingBytes

    public let stageCount: UInt64
    public let maximumInputBytesPerStage: UInt64

    public init(stageCount: UInt64, maximumInputBytesPerStage: UInt64) {
        self.stageCount = stageCount
        self.maximumInputBytesPerStage = maximumInputBytesPerStage
    }

    /// The full allowance for all configured review stages, saturating instead
    /// of wrapping if a caller supplies an extreme test value.
    public var reservedInputBytes: UInt64 {
        let (product, multiplicationOverflow) = stageCount.multipliedReportingOverflow(
            by: maximumInputBytesPerStage
        )
        guard !multiplicationOverflow else { return .max }
        return product
    }

    public func canFitReview(remainingInputBytes: UInt64) -> Bool {
        remainingInputBytes >= reservedInputBytes
    }

    /// Editing must stop at equality: those bytes belong to review, not to a
    /// final editing request that happens to fit the hard cap.
    public func shouldYieldEditing(remainingInputBytes: UInt64) -> Bool {
        reservedInputBytes > 0 && remainingInputBytes <= reservedInputBytes
    }
}

nonisolated public enum HarnessRunStopReason: String, Codable, Sendable {
    case completed
    case cancelled
    case budgetLimited
    case failed
    case uncertainFailure
    case userStopped
}

nonisolated public enum HarnessRunStatus: Equatable, Sendable {
    case running
    case stopped(HarnessRunStopReason)
}

nonisolated public struct HarnessRunReservationID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

nonisolated public struct HarnessRunReservation: Equatable, Sendable {
    public let id: HarnessRunReservationID
    public let task: HarnessRunTaskKind
    public let attempt: UInt64
    public let inputBytesReserved: UInt64

    public init(
        id: HarnessRunReservationID,
        task: HarnessRunTaskKind,
        attempt: UInt64,
        inputBytesReserved: UInt64
    ) {
        self.id = id
        self.task = task
        self.attempt = attempt
        self.inputBytesReserved = inputBytesReserved
    }
}

/// Measurements are optional because providers do not always report tokens.
/// A nil field remains nil in records and snapshots. Input bytes can be absent
/// at settlement time, in which case the admitted upper bound remains charged.
nonisolated public struct HarnessMeasuredUsage: Equatable, Sendable {
    public let inputBytes: UInt64?
    public let inputTokens: UInt64?
    public let cachedInputTokens: UInt64?
    public let outputTokens: UInt64?
    public let reasoningOutputTokens: UInt64?

    public init(
        inputBytes: UInt64? = nil,
        inputTokens: UInt64? = nil,
        cachedInputTokens: UInt64? = nil,
        outputTokens: UInt64? = nil,
        reasoningOutputTokens: UInt64? = nil
    ) {
        self.inputBytes = inputBytes
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public static let unknown = Self()
}

nonisolated public enum HarnessCallOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

nonisolated public enum HarnessRunReservationState: String, Codable, Sendable {
    case reserved
    case uncertainFailure
}

nonisolated public struct HarnessInFlightReservation: Equatable, Sendable {
    public let reservation: HarnessRunReservation
    public let state: HarnessRunReservationState

    public init(
        reservation: HarnessRunReservation,
        state: HarnessRunReservationState
    ) {
        self.reservation = reservation
        self.state = state
    }
}

nonisolated public struct HarnessRunCallRecord: Equatable, Sendable {
    public let reservation: HarnessRunReservation
    public let outcome: HarnessCallOutcome
    public let measuredInputBytes: UInt64?
    public let accountedInputBytes: UInt64
    public let inputTokens: UInt64?
    public let cachedInputTokens: UInt64?
    public let outputTokens: UInt64?
    public let reasoningOutputTokens: UInt64?
    public let at: HarnessMonotonicTime

    public init(
        reservation: HarnessRunReservation,
        outcome: HarnessCallOutcome,
        measuredInputBytes: UInt64?,
        accountedInputBytes: UInt64,
        inputTokens: UInt64?,
        outputTokens: UInt64?,
        at: HarnessMonotonicTime,
        cachedInputTokens: UInt64? = nil,
        reasoningOutputTokens: UInt64? = nil
    ) {
        self.reservation = reservation
        self.outcome = outcome
        self.measuredInputBytes = measuredInputBytes
        self.accountedInputBytes = accountedInputBytes
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.at = at
    }
}

nonisolated public enum HarnessRunLedgerEvent: Equatable, Sendable {
    case runStarted(at: HarnessMonotonicTime)
    case admitted(reservation: HarnessRunReservation, at: HarnessMonotonicTime)
    case uncertainFailureMarked(reservation: HarnessRunReservation, at: HarnessMonotonicTime)
    case settled(record: HarnessRunCallRecord)
    case uncertainFailureResolved(record: HarnessRunCallRecord)
    case stopped(reason: HarnessRunStopReason, at: HarnessMonotonicTime)
}

nonisolated public struct HarnessRunLedgerSnapshot: Equatable, Sendable {
    public let status: HarnessRunStatus
    public let admittedCallCount: UInt64
    public let settledCallCount: UInt64
    public let accountedInputBytes: UInt64
    public let inFlightReservations: [HarnessInFlightReservation]
    public let settledCalls: [HarnessRunCallRecord]
    public let measuredInputTokens: UInt64?
    public let measuredCachedInputTokens: UInt64?
    public let measuredOutputTokens: UInt64?
    public let measuredReasoningOutputTokens: UInt64?

    public var inFlightCallCount: UInt64 {
        UInt64(inFlightReservations.count)
    }

    public var inFlightInputBytes: UInt64 {
        inFlightReservations.reduce(0) { total, entry in
            total + entry.reservation.inputBytesReserved
        }
    }

    public init(
        status: HarnessRunStatus,
        admittedCallCount: UInt64,
        settledCallCount: UInt64,
        accountedInputBytes: UInt64,
        inFlightReservations: [HarnessInFlightReservation],
        settledCalls: [HarnessRunCallRecord],
        measuredInputTokens: UInt64?,
        measuredOutputTokens: UInt64?,
        measuredCachedInputTokens: UInt64? = nil,
        measuredReasoningOutputTokens: UInt64? = nil
    ) {
        self.status = status
        self.admittedCallCount = admittedCallCount
        self.settledCallCount = settledCallCount
        self.accountedInputBytes = accountedInputBytes
        self.inFlightReservations = inFlightReservations
        self.settledCalls = settledCalls
        self.measuredInputTokens = measuredInputTokens
        self.measuredCachedInputTokens = measuredCachedInputTokens
        self.measuredOutputTokens = measuredOutputTokens
        self.measuredReasoningOutputTokens = measuredReasoningOutputTokens
    }
}

nonisolated public enum HarnessRunLedgerError: Error, LocalizedError, Equatable, Sendable {
    case timestampWentBackwards(
        previous: HarnessMonotonicTime,
        provided: HarnessMonotonicTime
    )
    case runStopped(HarnessRunStopReason)
    case runAlreadyStopped(HarnessRunStopReason)
    case invalidAttempt
    case invalidInputBytes
    case budgetExceeded(
        dimension: HarnessRunBudgetDimension,
        limit: UInt64,
        requested: UInt64,
        available: UInt64
    )
    case unknownReservation(HarnessRunReservationID)
    case duplicateSettlement(HarnessRunReservationID)
    case reservationIsUncertain(HarnessRunReservationID)
    case measurementExceedsReservation(
        id: HarnessRunReservationID,
        reserved: UInt64,
        measured: UInt64
    )
    case integerOverflow(HarnessRunBudgetDimension)

    public var errorDescription: String? {
        switch self {
        case .budgetExceeded(let dimension, _, _, _):
            let allowance = dimension == .calls ? "model-call" : "input-data"
            return "This edit reached its \(allowance) allowance. No additional model request was sent. Any saved changes still need verification; the app update is not confirmed."
        case .runStopped, .runAlreadyStopped:
            return "This edit has stopped. No additional model request was sent, and completion is not confirmed."
        default:
            return "Iris could not safely account for this edit's resources. Completion is not confirmed."
        }
    }
}

/// A value-type ledger. Callers supply monotonic timestamps, so tests and
/// adapters can make ordering deterministic without a clock or side effect.
nonisolated public struct HarnessRunLedger: Sendable {
    private struct MutableReservation: Sendable {
        let reservation: HarnessRunReservation
        var state: HarnessRunReservationState
    }

    public let settings: HarnessRunLedgerSettings

    private(set) public var status: HarnessRunStatus = .running
    private(set) public var admittedCallCount: UInt64 = 0
    private(set) public var settledCallCount: UInt64 = 0
    private(set) public var accountedInputBytes: UInt64 = 0
    private(set) public var events: [HarnessRunLedgerEvent]

    private var lastTimestamp: HarnessMonotonicTime
    private var nextReservationRawValue: UInt64 = 1
    private var inFlight: [HarnessRunReservationID: MutableReservation] = [:]
    private var settledIDs: Set<HarnessRunReservationID> = []
    private var settledRecords: [HarnessRunCallRecord] = []
    private var allSettledInputTokensKnown = true
    private var allSettledCachedInputTokensKnown = true
    private var allSettledOutputTokensKnown = true
    private var allSettledReasoningOutputTokensKnown = true
    private var totalInputTokens: UInt64 = 0
    private var totalCachedInputTokens: UInt64 = 0
    private var totalOutputTokens: UInt64 = 0
    private var totalReasoningOutputTokens: UInt64 = 0

    public init(
        settings: HarnessRunLedgerSettings,
        startedAt: HarnessMonotonicTime
    ) {
        self.settings = settings
        self.lastTimestamp = startedAt
        self.events = [.runStarted(at: startedAt)]
    }

    public var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    public var inFlightReservations: [HarnessInFlightReservation] {
        inFlight.values
            .map { HarnessInFlightReservation(reservation: $0.reservation, state: $0.state) }
            .sorted { $0.reservation.id.rawValue < $1.reservation.id.rawValue }
    }

    public var settledCalls: [HarnessRunCallRecord] {
        settledRecords
    }

    public var snapshot: HarnessRunLedgerSnapshot {
        HarnessRunLedgerSnapshot(
            status: status,
            admittedCallCount: admittedCallCount,
            settledCallCount: settledCallCount,
            accountedInputBytes: accountedInputBytes,
            inFlightReservations: inFlightReservations,
            settledCalls: settledRecords,
            measuredInputTokens: allSettledInputTokensKnown && !settledRecords.isEmpty
                ? totalInputTokens
                : nil,
            measuredOutputTokens: allSettledOutputTokensKnown && !settledRecords.isEmpty
                ? totalOutputTokens
                : nil,
            measuredCachedInputTokens: allSettledCachedInputTokensKnown && !settledRecords.isEmpty
                ? totalCachedInputTokens
                : nil,
            measuredReasoningOutputTokens: allSettledReasoningOutputTokensKnown && !settledRecords.isEmpty
                ? totalReasoningOutputTokens
                : nil
        )
    }

    public var remainingCallCapacity: UInt64 {
        settings.maxCalls >= admittedCallCount
            ? settings.maxCalls - admittedCallCount
            : 0
    }

    public var remainingInputByteCapacity: UInt64 {
        settings.maxInputBytes >= accountedInputBytes
            ? settings.maxInputBytes - accountedInputBytes
            : 0
    }

    /// Returns the input space available to editing after a read-only review
    /// allowance has been preserved. This does not create a reservation.
    public func remainingInputByteCapacity(
        afterPreservingInputBytes preservedInputBytes: UInt64
    ) -> UInt64 {
        remainingInputByteCapacity >= preservedInputBytes
            ? remainingInputByteCapacity - preservedInputBytes
            : 0
    }

    /// Checks a prospective editing request without changing accounting. The
    /// caller can preserve review bytes while deciding whether to continue.
    public func canAdmit(
        inputBytes: UInt64,
        preservingInputBytes preservedInputBytes: UInt64 = 0
    ) -> Bool {
        inputBytes <= remainingInputByteCapacity(
            afterPreservingInputBytes: preservedInputBytes
        )
    }

    @discardableResult
    public mutating func reserve<T: BinaryInteger>(
        task: HarnessRunTaskKind,
        attempt: T = 1,
        inputBytes: T,
        at timestamp: HarnessMonotonicTime
    ) throws -> HarnessRunReservation {
        try ensureRunning()
        try validateTimestamp(timestamp)

        guard let attemptValue = UInt64(exactly: attempt), attemptValue > 0 else {
            if attempt < 0 || UInt64(exactly: attempt) == nil {
                throw HarnessRunLedgerError.invalidAttempt
            }
            throw HarnessRunLedgerError.invalidAttempt
        }
        guard let inputValue = UInt64(exactly: inputBytes) else {
            throw HarnessRunLedgerError.invalidInputBytes
        }
        if inputBytes < 0 {
            throw HarnessRunLedgerError.invalidInputBytes
        }

        let nextCallCount = try checkedAdd(
            admittedCallCount,
            1,
            dimension: .calls
        )
        guard nextCallCount <= settings.maxCalls else {
            throw HarnessRunLedgerError.budgetExceeded(
                dimension: .calls,
                limit: settings.maxCalls,
                requested: 1,
                available: remainingCallCapacity
            )
        }

        let nextInputBytes = try checkedAdd(
            accountedInputBytes,
            inputValue,
            dimension: .inputBytes
        )
        guard nextInputBytes <= settings.maxInputBytes else {
            throw HarnessRunLedgerError.budgetExceeded(
                dimension: .inputBytes,
                limit: settings.maxInputBytes,
                requested: inputValue,
                available: remainingInputByteCapacity
            )
        }

        guard nextReservationRawValue < UInt64.max else {
            throw HarnessRunLedgerError.integerOverflow(.reservationID)
        }
        let reservationID = HarnessRunReservationID(rawValue: nextReservationRawValue)
        nextReservationRawValue += 1
        let reservation = HarnessRunReservation(
            id: reservationID,
            task: task,
            attempt: attemptValue,
            inputBytesReserved: inputValue
        )

        admittedCallCount = nextCallCount
        accountedInputBytes = nextInputBytes
        inFlight[reservationID] = MutableReservation(
            reservation: reservation,
            state: .reserved
        )
        events.append(.admitted(reservation: reservation, at: timestamp))
        lastTimestamp = timestamp
        return reservation
    }

    @discardableResult
    public mutating func admit<T: BinaryInteger>(
        task: HarnessRunTaskKind,
        attempt: T = 1,
        inputBytes: T,
        at timestamp: HarnessMonotonicTime
    ) throws -> HarnessRunReservation {
        try reserve(task: task, attempt: attempt, inputBytes: inputBytes, at: timestamp)
    }

    public mutating func settle(
        _ reservationID: HarnessRunReservationID,
        outcome: HarnessCallOutcome,
        usage: HarnessMeasuredUsage? = nil,
        at timestamp: HarnessMonotonicTime
    ) throws {
        try settle(
            reservationID,
            outcome: outcome,
            usage: usage,
            at: timestamp,
            eventKind: .settled
        )
    }

    public mutating func settle(
        _ reservation: HarnessRunReservation,
        outcome: HarnessCallOutcome,
        usage: HarnessMeasuredUsage? = nil,
        at timestamp: HarnessMonotonicTime
    ) throws {
        try settle(reservation.id, outcome: outcome, usage: usage, at: timestamp)
    }

    /// Retains the call and its input reservation when the provider result is
    /// uncertain. It is not a settlement and must be resolved explicitly.
    public mutating func markUncertainFailure(
        _ reservationID: HarnessRunReservationID,
        at timestamp: HarnessMonotonicTime
    ) throws {
        try ensureReservationExists(reservationID)
        try validateTimestamp(timestamp)

        guard var reservation = inFlight[reservationID] else {
            throw HarnessRunLedgerError.unknownReservation(reservationID)
        }
        guard reservation.state == .reserved else {
            throw HarnessRunLedgerError.duplicateSettlement(reservationID)
        }

        reservation.state = .uncertainFailure
        inFlight[reservationID] = reservation
        events.append(.uncertainFailureMarked(
            reservation: reservation.reservation,
            at: timestamp
        ))
        lastTimestamp = timestamp
    }

    public mutating func resolveUncertainFailure(
        _ reservationID: HarnessRunReservationID,
        outcome: HarnessCallOutcome,
        usage: HarnessMeasuredUsage? = nil,
        at timestamp: HarnessMonotonicTime
    ) throws {
        try settle(
            reservationID,
            outcome: outcome,
            usage: usage,
            at: timestamp,
            eventKind: .uncertainFailureResolved
        )
    }

    public mutating func stop(
        reason: HarnessRunStopReason,
        at timestamp: HarnessMonotonicTime
    ) throws {
        guard case .running = status else {
            if case .stopped(let priorReason) = status {
                throw HarnessRunLedgerError.runAlreadyStopped(priorReason)
            }
            return
        }
        try validateTimestamp(timestamp)
        status = .stopped(reason)
        events.append(.stopped(reason: reason, at: timestamp))
        lastTimestamp = timestamp
    }

    private enum SettlementEventKind {
        case settled
        case uncertainFailureResolved
    }

    private mutating func settle(
        _ reservationID: HarnessRunReservationID,
        outcome: HarnessCallOutcome,
        usage: HarnessMeasuredUsage?,
        at timestamp: HarnessMonotonicTime,
        eventKind: SettlementEventKind
    ) throws {
        try ensureReservationExists(reservationID)
        try validateTimestamp(timestamp)

        guard let mutableReservation = inFlight[reservationID] else {
            throw HarnessRunLedgerError.unknownReservation(reservationID)
        }
        switch (eventKind, mutableReservation.state) {
        case (.settled, .uncertainFailure), (.uncertainFailureResolved, .reserved):
            throw HarnessRunLedgerError.reservationIsUncertain(reservationID)
        case (.settled, .reserved), (.uncertainFailureResolved, .uncertainFailure):
            break
        }

        let measuredInputBytes = usage?.inputBytes
        let accountedInputBytes = try accountedBytesAfterSettlement(
            reservation: mutableReservation.reservation,
            measuredInputBytes: measuredInputBytes
        )
        let tokenTotals = try tokenTotalsAfterSettlement(usage: usage)
        let record = HarnessRunCallRecord(
            reservation: mutableReservation.reservation,
            outcome: outcome,
            measuredInputBytes: measuredInputBytes,
            accountedInputBytes: accountedInputBytes,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            at: timestamp,
            cachedInputTokens: usage?.cachedInputTokens,
            reasoningOutputTokens: usage?.reasoningOutputTokens
        )

        inFlight.removeValue(forKey: reservationID)
        settledIDs.insert(reservationID)
        settledRecords.append(record)
        settledCallCount = try checkedAdd(
            settledCallCount,
            1,
            dimension: .calls
        )
        self.accountedInputBytes = try totalInputBytesAfterSettlement(
            reservation: mutableReservation.reservation,
            measuredInputBytes: measuredInputBytes
        )
        totalInputTokens = tokenTotals.input
        totalCachedInputTokens = tokenTotals.cachedInput
        totalOutputTokens = tokenTotals.output
        totalReasoningOutputTokens = tokenTotals.reasoningOutput
        if usage?.inputTokens == nil {
            allSettledInputTokensKnown = false
        }
        if usage?.cachedInputTokens == nil {
            allSettledCachedInputTokensKnown = false
        }
        if usage?.outputTokens == nil {
            allSettledOutputTokensKnown = false
        }
        if usage?.reasoningOutputTokens == nil {
            allSettledReasoningOutputTokensKnown = false
        }

        switch eventKind {
        case .settled:
            events.append(.settled(record: record))
        case .uncertainFailureResolved:
            events.append(.uncertainFailureResolved(record: record))
        }
        lastTimestamp = timestamp
    }

    private func ensureRunning() throws {
        guard case .running = status else {
            if case .stopped(let reason) = status {
                throw HarnessRunLedgerError.runStopped(reason)
            }
            return
        }
    }

    private func ensureReservationExists(_ reservationID: HarnessRunReservationID) throws {
        guard inFlight[reservationID] != nil else {
            if settledIDs.contains(reservationID) {
                throw HarnessRunLedgerError.duplicateSettlement(reservationID)
            }
            throw HarnessRunLedgerError.unknownReservation(reservationID)
        }
    }

    private func validateTimestamp(_ timestamp: HarnessMonotonicTime) throws {
        guard timestamp >= lastTimestamp else {
            throw HarnessRunLedgerError.timestampWentBackwards(
                previous: lastTimestamp,
                provided: timestamp
            )
        }
    }

    private func accountedBytesAfterSettlement(
        reservation: HarnessRunReservation,
        measuredInputBytes: UInt64?
    ) throws -> UInt64 {
        guard let measuredInputBytes else {
            return reservation.inputBytesReserved
        }
        guard measuredInputBytes <= reservation.inputBytesReserved else {
            throw HarnessRunLedgerError.measurementExceedsReservation(
                id: reservation.id,
                reserved: reservation.inputBytesReserved,
                measured: measuredInputBytes
            )
        }
        return measuredInputBytes
    }

    private func totalInputBytesAfterSettlement(
        reservation: HarnessRunReservation,
        measuredInputBytes: UInt64?
    ) throws -> UInt64 {
        let accounted = try accountedBytesAfterSettlement(
            reservation: reservation,
            measuredInputBytes: measuredInputBytes
        )
        let released = reservation.inputBytesReserved - accounted
        guard released <= self.accountedInputBytes else {
            throw HarnessRunLedgerError.integerOverflow(.inputBytes)
        }
        return self.accountedInputBytes - released
    }

    private func tokenTotalsAfterSettlement(
        usage: HarnessMeasuredUsage?
    ) throws -> (
        input: UInt64,
        cachedInput: UInt64,
        output: UInt64,
        reasoningOutput: UInt64
    ) {
        var inputTotal = totalInputTokens
        var cachedInputTotal = totalCachedInputTokens
        var outputTotal = totalOutputTokens
        var reasoningOutputTotal = totalReasoningOutputTokens
        if allSettledInputTokensKnown, let inputTokens = usage?.inputTokens {
            inputTotal = try checkedAdd(inputTotal, inputTokens, dimension: .inputTokens)
        }
        if allSettledCachedInputTokensKnown, let cachedInputTokens = usage?.cachedInputTokens {
            cachedInputTotal = try checkedAdd(
                cachedInputTotal,
                cachedInputTokens,
                dimension: .cachedInputTokens
            )
        }
        if allSettledOutputTokensKnown, let outputTokens = usage?.outputTokens {
            outputTotal = try checkedAdd(outputTotal, outputTokens, dimension: .outputTokens)
        }
        if allSettledReasoningOutputTokensKnown, let reasoningOutputTokens = usage?.reasoningOutputTokens {
            reasoningOutputTotal = try checkedAdd(
                reasoningOutputTotal,
                reasoningOutputTokens,
                dimension: .reasoningOutputTokens
            )
        }
        return (inputTotal, cachedInputTotal, outputTotal, reasoningOutputTotal)
    }

    private func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64,
        dimension: HarnessRunBudgetDimension
    ) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw HarnessRunLedgerError.integerOverflow(dimension)
        }
        return result
    }
}
