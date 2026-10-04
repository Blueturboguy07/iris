import Foundation

/// A named point inside a multi-step, crash-safe write sequence (SPEC section
/// 2.2 to 2.4). Production code always runs with `NativeVersionFaultInjector()`
/// (point `.none`), which never fires. Tests install a specific point to make a
/// write sequence stop exactly where a real process death could land, then run
/// the same recovery path a relaunch would run and check invariants against an
/// independent oracle. This is how a single-process `swift test` run exercises
/// "kill at every write step" without actually killing a process.
public enum NativeVersionCrashPoint: String, Sendable, CaseIterable {
    case none
    case objectWrite_afterTempWrite
    case objectWrite_afterFsync
    case objectWrite_afterRename
    case manifestWrite_afterTempWrite
    case manifestWrite_afterRename
    case manifestWrite_afterRefsCommit
    case journalWrite_afterJournalWritten
    case journalWrite_afterCheckoutBuilt
    case journalWrite_afterPointerWrite
    case journalWrite_beforeJournalDelete
    case gcSweep_midSweep
    case migration_midRename
}

/// Thrown by a fault injector when its configured point is reached. Distinct
/// from real IO errors so tests can assert "the write sequence was interrupted
/// here" rather than "something failed".
public struct NativeVersionSimulatedCrash: Error, Equatable, Sendable {
    public let point: NativeVersionCrashPoint
    public init(_ point: NativeVersionCrashPoint) { self.point = point }
}

/// Installed by a test into every layer of a write sequence. `fire(_:)` is a
/// cheap no-op comparison in production (`point == .none` never matches a real
/// candidate) and throws once, at the requested candidate, in a test.
public struct NativeVersionFaultInjector: Sendable {
    public let point: NativeVersionCrashPoint

    public init(point: NativeVersionCrashPoint = .none) {
        self.point = point
    }

    @inline(__always)
    public func fire(_ candidate: NativeVersionCrashPoint) throws {
        if point != .none, point == candidate {
            throw NativeVersionSimulatedCrash(candidate)
        }
    }
}
