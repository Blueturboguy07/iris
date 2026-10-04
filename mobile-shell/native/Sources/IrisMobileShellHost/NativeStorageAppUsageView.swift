#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Plain-language per-app storage: code size, versions kept and pins, with
/// user data shown separately (PLAN.md section 6). The model only reads and
/// writes through `NativeShellLibraryCoordinator`'s bounded-storage methods
/// (`storageUsage`, `pin`, `unpin`, `pruneStorage`); it holds no copy of the
/// coordinator's own state and never lists or deletes files itself.
///
/// `userDataBytesProvider` is injected rather than querying
/// `WKWebsiteDataStore` in here directly: this file is exercised by the iOS
/// simulator typecheck gate, never actually run there, and Core (which this
/// whole Host module already depends on) has no access to WebKit at all.
/// The integrator wires a real provider using the app's own
/// `NativeWebStorageIdentity` lookup (see INTEGRATION_HOOKS.md); passing
/// `nil` here degrades to "not shown" rather than a false zero.
@MainActor
final class NativeStorageAppUsageModel: ObservableObject {
    @Published private(set) var usage: NativeStorageAppUsage?
    @Published private(set) var userDataBytes: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// R2-CP-5 (round3-deferred/M-store-screens verification pass, fixed
    /// here): non-nil only while `errorMessage` was set by a `pin`/`unpin`
    /// call on this specific revision, so the message can render beside
    /// that one row (`NativeStorageRevisionPinButton`) instead of only in
    /// the general "Storage" section, which is where R2-mobile-integration's
    /// own HANDOFF.md flagged it as showing up wrongly ("shows its message
    /// in the Storage section, not beside the version row"). `refresh()`
    /// and `pruneNow()` errors are not row-scoped, so they leave this nil
    /// and keep showing in the general section, unchanged.
    @Published private(set) var erroredRevisionId: String?
    @Published private(set) var isChanging = false

    private let coordinator: NativeShellLibraryCoordinator
    private let identity: NativeShellAppIdentity
    private let userDataBytesProvider: (@MainActor () async -> Int?)?

    init(
        coordinator: NativeShellLibraryCoordinator,
        identity: NativeShellAppIdentity,
        userDataBytesProvider: (@MainActor () async -> Int?)? = nil
    ) {
        self.coordinator = coordinator
        self.identity = identity
        self.userDataBytesProvider = userDataBytesProvider
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        erroredRevisionId = nil
        Task {
            defer { isLoading = false }
            do {
                usage = try await coordinator.storageUsage(identity: identity)
            } catch {
                errorMessage = "This app's storage details could not be read right now."
            }
            userDataBytes = await userDataBytesProvider?()
        }
    }

    func pin(_ revisionId: String) {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        erroredRevisionId = nil
        Task {
            defer { isChanging = false }
            do {
                try await coordinator.pin(identity: identity, revisionId: revisionId)
                usage = try await coordinator.storageUsage(identity: identity)
            } catch let error as NativeStorageError {
                errorMessage = error.description
                erroredRevisionId = revisionId
            } catch {
                errorMessage = "That version could not be pinned right now."
                erroredRevisionId = revisionId
            }
        }
    }

    func unpin(_ revisionId: String) {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        erroredRevisionId = nil
        Task {
            defer { isChanging = false }
            do {
                try await coordinator.unpin(identity: identity, revisionId: revisionId)
                usage = try await coordinator.storageUsage(identity: identity)
            } catch {
                errorMessage = "That version could not be unpinned right now."
                erroredRevisionId = revisionId
            }
        }
    }

    /// A reader-visible "Free up space now", on top of the pruning that
    /// already runs automatically after install, update and open.
    func pruneNow() {
        guard !isChanging else { return }
        isChanging = true
        errorMessage = nil
        erroredRevisionId = nil
        Task {
            defer { isChanging = false }
            do {
                _ = try await coordinator.pruneStorage(identity: identity)
                usage = try await coordinator.storageUsage(identity: identity)
            } catch {
                errorMessage = "Storage could not be checked for cleanup right now."
            }
        }
    }
}

/// Caches one `NativeStorageAppUsageModel` per installed app so the storage
/// section (Hook 2) and a per-revision pin/unpin control living somewhere
/// else in the shared `NativeShellAppView` (Hook 3, m2-storage's originally
/// skipped hook) observe and mutate the exact same `@Published` state,
/// without `appSection`/`appDetails` needing a new parameter threaded
/// through their signatures: both call sites already have `coordinator`
/// and `identity`/`entry.identity` in scope today.
///
/// `@MainActor`-isolated, so the cache dictionary itself needs no lock; a
/// model is created once per identity and reused for the life of the
/// process (installed-app counts are bounded, so this never grows without
/// bound the way an unbounded cache of something per-revision would).
@MainActor
enum NativeStorageAppUsageModelCache {
    private static var models: [NativeShellAppIdentity: NativeStorageAppUsageModel] = [:]

    static func model(
        coordinator: NativeShellLibraryCoordinator,
        identity: NativeShellAppIdentity,
        userDataBytesProvider: (@MainActor () async -> Int?)? = nil
    ) -> NativeStorageAppUsageModel {
        if let existing = models[identity] { return existing }
        let created = NativeStorageAppUsageModel(
            coordinator: coordinator, identity: identity, userDataBytesProvider: userDataBytesProvider
        )
        models[identity] = created
        return created
    }

    /// Test-only: a fresh process-wide cache. Production code never needs
    /// this (one process, one cache, for the life of the app).
    static func resetForTesting() { models = [:] }
}

struct NativeStorageAppUsageSection: View {
    @ObservedObject var model: NativeStorageAppUsageModel

    var body: some View {
        Section("Storage") {
            if let usage = model.usage {
                LabeledContent("App code", value: ByteCountFormatter.string(fromByteCount: Int64(usage.codeAllocatedBytes), countStyle: .file))
                    .accessibilityIdentifier("iris.storage.code-bytes")
                LabeledContent("Versions kept", value: "\(usage.storedRevisionCount)")
                    .accessibilityIdentifier("iris.storage.versions-kept")
                if let userDataBytes = model.userDataBytes {
                    LabeledContent("Your data in this app", value: ByteCountFormatter.string(fromByteCount: Int64(userDataBytes), countStyle: .file))
                        .accessibilityIdentifier("iris.storage.user-data-bytes")
                }
                Text("App code is measured on this device, counting only the space each version actually uses, not a copy for every update. Your data in this app is separate and is never removed by cleaning up old versions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("iris.storage.explanation")

                if !usage.pinnedRevisionIds.isEmpty {
                    Text("Pinned versions: \(usage.pinnedRevisionIds.map(shortRevision).joined(separator: ", "))")
                        .font(.caption)
                        .accessibilityIdentifier("iris.storage.pinned-list")
                }

                Button("Free up space now") { model.pruneNow() }
                    .accessibilityIdentifier("iris.storage.prune-now")
                    .disabled(model.isChanging)
            } else if model.isLoading {
                ProgressView("Checking storage…")
            } else {
                Text("Storage details are not available yet.").font(.footnote)
            }

            if model.isChanging { ProgressView() }
            // R2-CP-5: a pin/unpin refusal is row-scoped (`erroredRevisionId`
            // non-nil) and renders beside that row via
            // `NativeStorageRevisionPinButton` instead, so it is excluded
            // here to avoid showing the same message twice in two places.
            // A `refresh()`/`pruneNow()` failure has no associated row, so
            // it keeps showing here exactly as before.
            if let errorMessage = model.errorMessage, model.erroredRevisionId == nil {
                Text(errorMessage).font(.footnote).accessibilityIdentifier("iris.storage.error")
            }
        }
        .task { if model.usage == nil { model.refresh() } }
    }

    private func shortRevision(_ value: String) -> String {
        String(value.suffix(12))
    }
}

/// Owns its own `@StateObject` so the integration hook into
/// `NativeShellAppView.appDetails(identity:)` is a single call, not a place
/// to thread a model's lifetime through a `@ViewBuilder` function
/// (INTEGRATION_HOOKS.md).
struct NativeStorageAppUsageContainer: View {
    let coordinator: NativeShellLibraryCoordinator
    let identity: NativeShellAppIdentity
    var userDataBytesProvider: (@MainActor () async -> Int?)? = nil
    @StateObject private var model: NativeStorageAppUsageModel

    init(
        coordinator: NativeShellLibraryCoordinator,
        identity: NativeShellAppIdentity,
        userDataBytesProvider: (@MainActor () async -> Int?)? = nil
    ) {
        self.coordinator = coordinator
        self.identity = identity
        self.userDataBytesProvider = userDataBytesProvider
        // Shared with any `NativeStorageRevisionPinButton` for the same
        // identity (Hook 3), via `NativeStorageAppUsageModelCache`, so a pin
        // made in a revision row and the "Pinned versions" list in this
        // section immediately agree without a second network/disk read.
        _model = StateObject(wrappedValue: NativeStorageAppUsageModelCache.model(
            coordinator: coordinator, identity: identity, userDataBytesProvider: userDataBytesProvider
        ))
    }

    var body: some View {
        NativeStorageAppUsageSection(model: model)
    }
}

/// A pin/unpin control for one row of `NativeRevisionHistoryRow`, kept as
/// its own tiny view so the integrator can drop it into
/// `NativeShellAppView`'s existing revision-row `ForEach` without changing
/// that file's own layout code beyond one line (INTEGRATION_HOOKS.md).
///
/// `isPinned` is deliberately computed inside `body` from `model.usage`,
/// not accepted as an external `let` parameter: this view holds
/// `@ObservedObject var model`, and when `model.pin`/`model.unpin`
/// publishes a fresh `usage`, SwiftUI re-invokes this view's own `body`
/// using this same struct instance's *existing* stored properties: a
/// plain `let isPinned: Bool` captured from the parent at construction
/// time would stay stale (still reading "Pin" after a successful pin)
/// until something unrelated forced the parent row to reconstruct this
/// view with a fresh value. Reading `model.usage` directly here means the
/// re-invoked `body` always sees the current pin state, so the label and
/// the accessibility identifier flip immediately after the tap that
/// caused them to change, with no navigate-away-and-back needed.
struct NativeStorageRevisionPinButton: View {
    let revisionId: String
    @ObservedObject var model: NativeStorageAppUsageModel

    private var isPinned: Bool {
        model.usage?.pinnedRevisionIds.contains(revisionId) ?? false
    }

    /// R2-CP-5: only this row's own pin/unpin attempt shows its refusal
    /// text here (checked by `erroredRevisionId`, not merely "an error
    /// exists somewhere"), so a limit hit on one revision never paints a
    /// message beside an unrelated row.
    private var rowError: String? {
        model.erroredRevisionId == revisionId ? model.errorMessage : nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(isPinned ? "Unpin" : "Pin") {
                if isPinned { model.unpin(revisionId) } else { model.pin(revisionId) }
            }
            .disabled(model.isChanging)
            .accessibilityIdentifier(isPinned ? "iris.storage.unpin.\(revisionId)" : "iris.storage.pin.\(revisionId)")
            if let rowError {
                Text(rowError).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("iris.storage.pin.\(revisionId).error")
            }
        }
    }
}
#endif
