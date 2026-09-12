import Foundation

nonisolated struct HarnessModelRequest: Sendable {
    let route: HarnessModelRoute
    let phase: HarnessRunTaskKind
    let systemPrompt: String
    let conversation: [HarnessModelMessage]
    let maximumOutputTokens: Int
}

nonisolated struct HarnessModelMessage: Sendable {
    let role: String
    let text: String
    var imagePNG: Data? = nil
}

nonisolated struct HarnessModelReply: Sendable {
    let text: String
    var usage: HarnessMeasuredUsage? = nil
}

/// Counts the request components without retaining any request content.
/// `conversationTextUTF8Bytes` counts message text only; role and provider
/// framing remain represented by the authoritative serialized input bytes.
nonisolated struct HarnessModelInputCounts: Equatable, Sendable {
    let systemPromptUTF8Bytes: UInt64
    let conversationTextUTF8Bytes: UInt64
    let rawImageBytes: UInt64
    let imageCount: UInt64
}

nonisolated struct HarnessModelTransportFailure: Error {
    let cause: any Error
    let usage: HarnessMeasuredUsage?
}

/// One owner for a job's model requests. The injected transport must perform
/// exactly one physical attempt, so retries cannot hide outside the accounting.
@MainActor
final class HarnessModelSession {
    typealias Transport = @MainActor @Sendable (HarnessModelRequest) async throws -> HarnessModelReply
    typealias SerializedInputByteCounter = @Sendable (HarnessModelRequest) throws -> UInt64
    typealias AdmissionObserver = (HarnessRunReservation, HarnessModelInputCounts) -> Void
    enum SessionError: Error, LocalizedError, Equatable, Sendable {
        case deadlineReached
        case responseTooLarge
        case invalidLimits
        case yieldToVerification(
            inputBytes: UInt64,
            preservedInputBytes: UInt64,
            availableInputBytes: UInt64
        )

        var errorDescription: String? {
            switch self {
            case .deadlineReached: return "This edit reached its time allowance and stopped without confirming completion."
            case .responseTooLarge: return "The model returned more data than this edit can safely process."
            case .invalidLimits: return "The edit's resource limits are invalid."
            case .yieldToVerification:
                return "This edit stopped before its next request could consume the input space preserved for independent review. The current source still needs verification."
            }
        }
    }

    private(set) var ledger: HarnessRunLedger
    /// Optional host checkpoint, called after each accounting mutation.
    var ledgerDidChange: ((HarnessRunLedgerSnapshot) -> Void)?
    /// Optional observer for admitted requests. It receives counts only after
    /// the ledger accepts a reservation, never for rejected preflight.
    var admissionDidSucceed: AdmissionObserver?
    let implementationArm: HarnessImplementationArm
    private let transport: Transport
    private let now: @Sendable () -> UInt64
    private let deadline: UInt64
    private let maximumReplyBytes: Int
    let reviewInputBytesPerStage: UInt64
    private let serializedInputByteCounter: SerializedInputByteCounter

    init(implementationArm: HarnessImplementationArm, settings: HarnessRunLedgerSettings,
         maximumDurationNanoseconds: UInt64, maximumReplyBytes: Int = 128_000,
         reviewInputBytesPerStage: UInt64 = HarnessReviewInputBudget.defaultMaximumInputBytesPerStage,
         serializedInputByteCounter: SerializedInputByteCounter? = nil,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         transport: @escaping Transport) throws {
        let started = now()
        let deadlineResult = started.addingReportingOverflow(maximumDurationNanoseconds)
        guard maximumDurationNanoseconds > 0, maximumReplyBytes > 0, !deadlineResult.overflow else {
            throw SessionError.invalidLimits
        }
        self.implementationArm = implementationArm
        self.now = now
        self.deadline = deadlineResult.partialValue
        self.maximumReplyBytes = maximumReplyBytes
        self.reviewInputBytesPerStage = reviewInputBytesPerStage
        self.serializedInputByteCounter = serializedInputByteCounter
            ?? Self.defaultSerializedInputByteCount
        self.transport = transport
        self.ledger = HarnessRunLedger(settings: settings, startedAt: .init(nanoseconds: started))
    }

    func respond(phase: HarnessRunTaskKind, systemPrompt: String,
                 conversation: [HarnessModelMessage], maximumOutputTokens: Int,
                 preservingInputBytes: UInt64 = 0) async throws -> String {
        try Task.checkCancellation()
        guard maximumOutputTokens > 0 else { throw SessionError.invalidLimits }
        let timestamp = now()
        guard timestamp < deadline else { throw SessionError.deadlineReached }
        let route: HarnessModelRoute = phase == .intake ? .planner : implementationArm.route
        let request = HarnessModelRequest(route: route, phase: phase,
            systemPrompt: systemPrompt, conversation: conversation, maximumOutputTokens: maximumOutputTokens)
        let inputBytes = try serializedInputByteCounter(request)
        let inputCounts: HarnessModelInputCounts?
        if admissionDidSucceed == nil {
            inputCounts = nil
        } else {
            inputCounts = try Self.inputCounts(for: request)
        }
        let availableAfterPreserving = ledger.remainingInputByteCapacity(
            afterPreservingInputBytes: preservingInputBytes
        )
        if preservingInputBytes > 0, inputBytes > availableAfterPreserving {
            throw SessionError.yieldToVerification(
                inputBytes: inputBytes,
                preservedInputBytes: preservingInputBytes,
                availableInputBytes: availableAfterPreserving
            )
        }
        let attempt = ledger.snapshot.admittedCallCount.addingReportingOverflow(1)
        guard !attempt.overflow else { throw SessionError.invalidLimits }
        let reservation = try ledger.reserve(task: phase, attempt: attempt.partialValue,
            inputBytes: inputBytes, at: .init(nanoseconds: timestamp))
        if let inputCounts {
            admissionDidSucceed?(reservation, inputCounts)
        }
        ledgerDidChange?(ledger.snapshot)
        let reply: HarnessModelReply
        do {
            let remaining = deadline - timestamp
            let transport = self.transport
            reply = try await withThrowingTaskGroup(of: HarnessModelReply.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await transport(request) }
                group.addTask {
                    try await Task.sleep(nanoseconds: remaining)
                    throw SessionError.deadlineReached
                }
                guard let first = try await group.next() else { throw CancellationError() }
                return first
            }
        } catch {
            try ledger.settle(reservation, outcome: Task.isCancelled ? .cancelled : .failed,
                              usage: (error as? HarnessModelTransportFailure)?.usage,
                              at: .init(nanoseconds: now()))
            ledgerDidChange?(ledger.snapshot)
            throw (error as? HarnessModelTransportFailure)?.cause ?? error
        }
        try ledger.settle(reservation, outcome: Task.isCancelled ? .cancelled : .succeeded,
                          usage: reply.usage, at: .init(nanoseconds: now()))
        ledgerDidChange?(ledger.snapshot)
        try Task.checkCancellation()
        guard now() < deadline else { throw SessionError.deadlineReached }
        guard reply.text.utf8.count <= maximumReplyBytes else { throw SessionError.responseTooLarge }
        return reply.text
    }

    nonisolated private static func inputCounts(
        for request: HarnessModelRequest
    ) throws -> HarnessModelInputCounts {
        func count(_ value: Int) throws -> UInt64 {
            guard value >= 0, let converted = UInt64(exactly: value) else {
                throw SessionError.invalidLimits
            }
            return converted
        }

        func add(_ value: UInt64, to total: inout UInt64) throws {
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { throw SessionError.invalidLimits }
            total = next.partialValue
        }

        var conversationTextUTF8Bytes: UInt64 = 0
        var rawImageBytes: UInt64 = 0
        var imageCount: UInt64 = 0
        for message in request.conversation {
            try add(count(message.text.utf8.count), to: &conversationTextUTF8Bytes)
            if let imagePNG = message.imagePNG {
                try add(count(imagePNG.count), to: &rawImageBytes)
                try add(1, to: &imageCount)
            }
        }
        return HarnessModelInputCounts(
            systemPromptUTF8Bytes: try count(request.systemPrompt.utf8.count),
            conversationTextUTF8Bytes: conversationTextUTF8Bytes,
            rawImageBytes: rawImageBytes,
            imageCount: imageCount
        )
    }

    nonisolated private static func defaultSerializedInputByteCount(
        _ request: HarnessModelRequest
    ) throws -> UInt64 {
        var total: UInt64 = 0
        func add(_ count: Int, to total: inout UInt64) throws {
            guard let value = UInt64(exactly: count), count >= 0 else {
                throw SessionError.invalidLimits
            }
            let next = total.addingReportingOverflow(value)
            guard !next.overflow else { throw SessionError.invalidLimits }
            total = next.partialValue
        }

        try add(request.systemPrompt.utf8.count, to: &total)
        for message in request.conversation {
            try add(message.role.utf8.count, to: &total)
            try add(message.text.utf8.count, to: &total)
            try add(message.imagePNG?.count ?? 0, to: &total)
        }
        return total
    }
}
