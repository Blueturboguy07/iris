import Foundation

/// A snapshot of first-launch starter-app setup that a Host view can render
/// directly: which apps (if any) are still being set up, and which ones
/// could not be set up. Pure data with pure transition functions below
/// (`NativeStarterSetupPlanning`), so the whole state machine is testable
/// with `swift test` on the Mac, with no SwiftUI, Combine or async involved.
/// The Host owns a small `ObservableObject` wrapper that republishes this
/// snapshot to the view; nothing in this type depends on that wrapper.
public struct NativeStarterSetupSnapshot: Equatable, Sendable {
    /// Display names of apps still being installed, in the catalog's own
    /// declared order. Empty means nothing is running right now.
    public let runningAppNames: [String]
    /// Display names of apps that could not be set up, in declared order.
    /// Stays populated after setup finishes so the message keeps showing;
    /// nothing in this type ever clears it on its own.
    public let failedAppNames: [String]

    public init(runningAppNames: [String] = [], failedAppNames: [String] = []) {
        self.runningAppNames = runningAppNames
        self.failedAppNames = failedAppNames
    }

    /// Nothing running and nothing failed: no banner, no message. This is
    /// also the starting value before setup has been asked about at all.
    public static let idle = NativeStarterSetupSnapshot()

    public var hasNothingToShow: Bool { runningAppNames.isEmpty && failedAppNames.isEmpty }
}

/// Pure functions that turn raw `NativeStarterInstaller` inputs/outputs into
/// a `NativeStarterSetupSnapshot`. Kept separate from `NativeStarterInstaller`
/// itself (which does real, effectful, async work) so every branch here can
/// be exercised with plain in-memory values and no coordinator, filesystem
/// or Task at all.
public enum NativeStarterSetupPlanning {
    /// The snapshot to publish the moment setup starts, from the chains a
    /// quick, non-staging check (`NativeStarterInstaller.stillNeeded`) found
    /// still need installing. An empty `labels` set (nothing to install,
    /// every bundled app already present) yields `.idle`: no banner is ever
    /// shown for a launch that had nothing to do.
    ///
    /// `order` controls display order (normally the labels of
    /// `NativeStarterCatalog.entries`, so the banner reads "Kneecap, Nut AI,
    /// FreeHarmony" and not an alphabetical shuffle of that). A label
    /// missing from `order` is appended after the ordered ones, sorted, so a
    /// chain is never silently dropped from the banner just because it was
    /// not in the declared catalog order.
    public static func started(
        chains: [String: NativeStarterInstaller.AppChain],
        needing labels: Set<String>,
        order: [String]
    ) -> NativeStarterSetupSnapshot {
        guard !labels.isEmpty else { return .idle }
        return NativeStarterSetupSnapshot(
            runningAppNames: orderedDisplayNames(chains: chains, labels: labels, order: order)
        )
    }

    /// The snapshot to publish once `NativeStarterInstaller.installMissing`
    /// returns: nothing is running any more, and any chain whose result was
    /// `.failed` is named in `failedAppNames` so the reader can see, in
    /// plain language and with no technical detail, which app did not get
    /// set up. A run with no failures yields `.idle`.
    public static func finished(
        chains: [String: NativeStarterInstaller.AppChain],
        results: [String: NativeStarterInstaller.AppResult],
        order: [String]
    ) -> NativeStarterSetupSnapshot {
        let failedLabels = Set(results.compactMap { label, result -> String? in
            guard case .failed = result else { return nil }
            return label
        })
        guard !failedLabels.isEmpty else { return .idle }
        return NativeStarterSetupSnapshot(
            failedAppNames: orderedDisplayNames(chains: chains, labels: failedLabels, order: order)
        )
    }

    private static func orderedDisplayNames(
        chains: [String: NativeStarterInstaller.AppChain],
        labels: Set<String>,
        order: [String]
    ) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for label in order where labels.contains(label) {
            seen.insert(label)
            names.append(chains[label]?.displayName ?? label)
        }
        for label in labels.subtracting(seen).sorted() {
            names.append(chains[label]?.displayName ?? label)
        }
        return names
    }
}
