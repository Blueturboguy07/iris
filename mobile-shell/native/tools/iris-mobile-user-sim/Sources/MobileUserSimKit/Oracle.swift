import Foundation

/// An oracle failure: what was expected versus what the world (or the real
/// Core code's own return value, used only when no independent ground truth
/// exists) actually showed. Every failure carries a `FailureClass` so the
/// report's taxonomy is decided at the failure site, not guessed afterward.
public struct OracleFailure: Error, CustomStringConvertible {
    public let label: String
    public let detail: String
    public let failureClass: FailureClass

    public init(_ label: String, _ detail: String, failureClass: FailureClass) {
        self.label = label
        self.detail = detail
        self.failureClass = failureClass
    }

    public var description: String { "\(label): \(detail)" }
}

/// Small assertion helpers scenarios use to check ground truth. These are
/// deliberately plain equality/boolean checks, not a mocking framework: a
/// scenario is expected to read real values (files on disk, the coordinator's
/// own `refreshLibrary()`, the device world's event log) and compare them,
/// never to assert a constant the scenario itself just set.
public enum Oracle {
    public static func require(
        _ condition: Bool,
        _ label: String,
        _ detail: @autoclosure () -> String,
        failureClass: FailureClass
    ) throws {
        guard condition else {
            throw OracleFailure(label, detail(), failureClass: failureClass)
        }
    }

    public static func requireEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String,
        failureClass: FailureClass
    ) throws {
        guard actual == expected else {
            throw OracleFailure(label, "expected \(expected), got \(actual)", failureClass: failureClass)
        }
    }

    /// Overload for comparing an `Optional<T>` ground-truth value against a
    /// plain, known-non-nil expected value (for example comparing
    /// `NativeShellLibraryEntry.currentRevisionId: String?` to a fixture's
    /// non-optional revision id) without an explicit `as T?` cast at every
    /// call site.
    public static func requireEqual<T: Equatable>(
        _ actual: T?,
        _ expected: T,
        _ label: String,
        failureClass: FailureClass
    ) throws {
        guard actual == expected else {
            throw OracleFailure(label, "expected \(expected), got \(String(describing: actual))", failureClass: failureClass)
        }
    }
}
