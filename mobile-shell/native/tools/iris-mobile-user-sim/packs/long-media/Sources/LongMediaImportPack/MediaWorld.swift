import Foundation
import IrisMobileShellCore
import MobileUserSimKit

/// One picked item in a simulated batch. `progressTicks` are simulated
/// seconds, relative to this item's own load start, at which the
/// provider's `Progress` advances -- replayed through
/// `NativeMediaImportPolicy.evaluateProgress` exactly the way
/// `NativeMediaPickerSession`'s real watchdog does, one simulated second at
/// a time, so the same stall/never-stall boundary this pack asserts on is
/// the real production boundary, not a reimplementation of it.
public struct SimulatedPickerItem: Sendable, Equatable {
    public let kind: NativeMediaImportPolicy.Kind
    public let bytes: Int64
    public let progressTicks: [TimeInterval]
    /// The real device boundary this models: a document-provider (an
    /// iCloud-backed clip, a Files-app provider) that deletes its own
    /// temporary file before the shell finishes with it. The real Host sees
    /// this as `loadFileRepresentation`'s completion handler firing with an
    /// error/no URL; this pack models the same observable outcome (the load
    /// fails) without needing a real PhotosUI/file-provider type.
    public let providerDeletesTempFileEarly: Bool

    public init(
        kind: NativeMediaImportPolicy.Kind, bytes: Int64,
        progressTicks: [TimeInterval], providerDeletesTempFileEarly: Bool = false
    ) {
        self.kind = kind
        self.bytes = bytes
        self.progressTicks = progressTicks
        self.providerDeletesTempFileEarly = providerDeletesTempFileEarly
    }
}

/// Why a batch import (or one item in it) did not complete, mirroring the
/// real shapes `NativeMediaImportPolicy`/`NativeSelectedMediaLease` produce.
public enum SimulatedImportFailure: Sendable, Equatable {
    case tooLarge(kind: NativeMediaImportPolicy.Kind, actualBytes: Int64, maximumBytes: Int64)
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case stalled
    case providerFailure
    case cancelledByPersona
}

public enum SimulatedBatchOutcome: Sendable, Equatable {
    case accepted(totalBytes: Int64, itemCount: Int)
    /// `importedCount` is always 0: this pack's runner mirrors the real
    /// `NativeSelectedMediaLease`'s all-or-nothing batch rollback (see
    /// NativeMediaPickerSession.importResults's catch path), so a rejection
    /// anywhere in the batch leaves nothing imported, never a partial
    /// N-of-M result.
    case rejected(failingItemIndex: Int, reason: SimulatedImportFailure)
}

/// The one thing a run is allowed to fake: the device boundary (free
/// storage, and another app's concurrent writes against that same free
/// storage). Everything else -- `evaluateSize`, `evaluateSpace`,
/// `evaluateProgress` -- is the real, unmodified
/// `NativeMediaImportPolicy` from `IrisMobileShellCore`, called exactly the
/// way the real Host calls it (a fresh "available bytes" read before every
/// item, a per-second progress replay per item). Reference type with a lock
/// because a scenario mutates it (another app filling disk) while this
/// pack's own runner also reads it.
public final class MediaWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var freeStorageBytes: Int64
    private var events: [String] = []
    /// Bytes another app silently consumes, charged once per item index
    /// (index 0 fires before the first item's own check), standing in for
    /// Photos sync, a backup, or Spotlight indexing running at the same
    /// time as this import.
    private var externalFillScheduleBytes: [Int64]

    public init(persona: MediaImportPersona, externalFillScheduleBytes: [Int64] = []) {
        self.freeStorageBytes = persona.startingFreeStorageBytes
        self.externalFillScheduleBytes = externalFillScheduleBytes
    }

    public func currentFreeStorageBytes() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return freeStorageBytes
    }

    public func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    public func eventLog() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// Another app's concurrent write, charged once before item `index`'s
    /// own space check (matches this pack's runner calling order below).
    fileprivate func applyExternalFill(beforeItemIndex index: Int) {
        lock.lock()
        if index < externalFillScheduleBytes.count {
            let amount = externalFillScheduleBytes[index]
            freeStorageBytes = max(0, freeStorageBytes - amount)
            if amount > 0 {
                events.append("external-fill: another app consumed \(amount) bytes before item \(index)")
            }
        }
        lock.unlock()
    }

    /// The conservative assumption `NativeMediaImportPolicy`'s own free-space
    /// derivation documents throughout: a completed item is charged as one
    /// real copy's worth of consumed space (a move, when it succeeds, costs
    /// less than this in reality; this stays conservative rather than
    /// assume the best case).
    fileprivate func chargeRealBytesForCompletedItem(_ bytes: Int64) {
        lock.lock()
        freeStorageBytes = max(0, freeStorageBytes - bytes)
        lock.unlock()
    }
}

/// Replays a batch of simulated picker items through the real
/// `NativeMediaImportPolicy` exactly the way `NativeSelectedMediaLease`
/// (space, size) and `NativeMediaPickerSession` (progress/stall) call it on
/// the phone: one space check per item against a freshly read "available"
/// value (so "disk filling from another app during import" is observable),
/// one size check per item, one stall-only progress replay per item, and an
/// all-or-nothing batch outcome (the real lease's rollback-on-failure
/// behavior) rather than a partial N-of-M result.
public enum MediaImportBatchRunner {
    public static func run(
        items: [SimulatedPickerItem], world: MediaWorld, rng: inout SeededGenerator,
        cancelAfterItemIndex: Int? = nil
    ) -> SimulatedBatchOutcome {
        var committedBytes: Int64 = 0
        for (index, item) in items.enumerated() {
            if let cancelAfterItemIndex, index > cancelAfterItemIndex {
                world.record("cancelled-by-persona after item \(cancelAfterItemIndex)")
                return .rejected(failingItemIndex: index, reason: .cancelledByPersona)
            }

            let sizeDecision = NativeMediaImportPolicy.evaluateSize(kind: item.kind, bytes: item.bytes)
            if case .tooLarge(let kind, let actualBytes, let maximumBytes) = sizeDecision {
                world.record("rejected at item \(index): too large")
                return .rejected(failingItemIndex: index, reason: .tooLarge(kind: kind, actualBytes: actualBytes, maximumBytes: maximumBytes))
            }

            world.applyExternalFill(beforeItemIndex: index)
            let available = world.currentFreeStorageBytes()
            let spaceDecision = NativeMediaImportPolicy.evaluateSpace(
                alreadyCommittedBytes: committedBytes, addingBytes: item.bytes, availableBytes: available
            )
            if case .insufficient(let requiredBytes, let availableBytes) = spaceDecision {
                world.record("rejected at item \(index): insufficient space (required \(requiredBytes), available \(availableBytes))")
                return .rejected(failingItemIndex: index, reason: .insufficientSpace(requiredBytes: requiredBytes, availableBytes: availableBytes))
            }

            if item.providerDeletesTempFileEarly {
                world.record("rejected at item \(index): provider deleted its temp file early")
                return .rejected(failingItemIndex: index, reason: .providerFailure)
            }

            if replayProgress(ticks: item.progressTicks) == .stalled {
                world.record("rejected at item \(index): stalled")
                return .rejected(failingItemIndex: index, reason: .stalled)
            }

            world.chargeRealBytesForCompletedItem(item.bytes)
            committedBytes += item.bytes
            world.record("item \(index) imported (\(item.bytes) bytes)")
        }
        world.record("batch accepted: \(items.count) items, \(committedBytes) total bytes")
        return .accepted(totalBytes: committedBytes, itemCount: items.count)
    }

    /// The same per-second replay `NativeMediaImportPolicyTests.swift`'s
    /// Core-level `replayProgress` helper uses, calling the real
    /// `NativeMediaImportPolicy.evaluateProgress` (stall-only; there is no
    /// overall ceiling any more). An item with no ticks at all replays as an
    /// immediate stall once `stallThresholdSeconds` elapses with no advance.
    static func replayProgress(ticks: [TimeInterval]) -> NativeMediaImportPolicy.ProgressDecision {
        guard let lastTick = ticks.max() else {
            return NativeMediaImportPolicy.evaluateProgress(
                now: NativeMediaImportPolicy.stallThresholdSeconds, lastProgressAt: 0
            )
        }
        var lastProgressAt: TimeInterval = 0
        var tickIndex = 0
        var now: TimeInterval = 0
        let horizon = lastTick + NativeMediaImportPolicy.stallThresholdSeconds + 1
        while now <= horizon {
            while tickIndex < ticks.count, ticks[tickIndex] <= now {
                lastProgressAt = ticks[tickIndex]
                tickIndex += 1
            }
            let decision = NativeMediaImportPolicy.evaluateProgress(now: now, lastProgressAt: lastProgressAt)
            if decision == .stalled { return .stalled }
            now += 1
        }
        return .keepWaiting
    }
}
