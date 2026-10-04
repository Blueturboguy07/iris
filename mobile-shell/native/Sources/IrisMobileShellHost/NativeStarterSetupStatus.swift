#if os(iOS)
import Combine
import IrisMobileShellCore

/// The explicit, testable object that carries first-launch starter-app
/// setup state from the App to the view. Owned and created by
/// `IrisMobileShellApp` (one instance per launch, passed into
/// `NativeShellAppView`), never a global: nothing here reads or writes
/// `NotificationCenter.default` or any other process-wide singleton.
///
/// This wrapper is deliberately thin. Every real decision (what "still
/// running" means, which apps to name after a failure, what order to name
/// them in) lives in the pure `NativeStarterSetupSnapshot` /
/// `NativeStarterSetupPlanning` types in Core, which `swift test` covers
/// directly with no SwiftUI involved. This class only republishes that
/// snapshot on the main actor so a SwiftUI view can observe it.
@MainActor
public final class NativeStarterSetupStatus: ObservableObject {
    @Published public private(set) var snapshot: NativeStarterSetupSnapshot

    public init(snapshot: NativeStarterSetupSnapshot = .idle) {
        self.snapshot = snapshot
    }

    /// Call once setup begins, right after a quick, non-staging check has
    /// determined which bundled chains still need installing.
    public func markStarted(
        chains: [String: NativeStarterInstaller.AppChain],
        needing labels: Set<String>,
        order: [String]
    ) {
        snapshot = NativeStarterSetupPlanning.started(chains: chains, needing: labels, order: order)
    }

    /// Call once `NativeStarterInstaller.installMissing` returns.
    public func markFinished(
        chains: [String: NativeStarterInstaller.AppChain],
        results: [String: NativeStarterInstaller.AppResult],
        order: [String]
    ) {
        snapshot = NativeStarterSetupPlanning.finished(chains: chains, results: results, order: order)
    }
}
#endif
