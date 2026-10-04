#if os(iOS)
import Foundation
import IrisMobileShellCore
import SwiftUI

// Unit MA2 my-apps-screen (route G8, docs/plans/20260928-all-routes/round3/
// my-apps-organization/SPEC.md and round3/.../MA2-my-apps-screen/HANDOFF.md).
// The Host-side owner of one in-memory `MyAppsArrangement`: loads it once
// from `MyAppsOrganizationFile` (MA1, Core), drives every person action
// through `MyAppsOrganizationReducer` (also MA1), and coalesces saves at
// 500 ms (SPEC 3.1) so a fast sequence of moves during Select mode (persona
// P2) never blocks on disk. Never touches the library, the package or the
// catalog: `MyAppsAdapter` (this unit, same folder) builds the
// `[MyAppsAppInput]`/`[MyAppsCategoryInput]` this store's `sections(...)`
// call needs from those, once per SwiftUI body evaluation, and this store
// never writes anything back into them -- closing SPEC 5.5 mutant #2
// ("Rename written into the package manifest") structurally: there is no
// code path from this file to a package/manifest type at all.
@MainActor
public final class MyAppsOrganizationStore: ObservableObject {
    @Published public private(set) var arrangement: MyAppsArrangement
    /// SPEC 1.6 row "Arrangement file unreadable at launch": set once from
    /// `load()`, shown as the notice line until the person's next change
    /// saves cleanly (a successful `save()` clears it, since a good arrangement
    /// is now on disk again).
    @Published public private(set) var notice: String?
    @Published public var sort: MyAppsSort {
        didSet { defaults.set(sort.rawValue, forKey: Self.sortDefaultsKey) }
    }
    @Published public var query: String = ""
    /// The last event a reducer call produced, for the screen to turn into
    /// one of SPEC section 4's exact sentences and post as an accessibility
    /// announcement. `nil` means "nothing to announce yet" (fresh launch).
    @Published public private(set) var lastEvent: MyAppsEvent?
    @Published public private(set) var lastError: MyAppsActionError?

    private let file: MyAppsOrganizationFile
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var pendingSave: DispatchWorkItem?
    private static let sortDefaultsKey = "iris.store.my-apps.sort"
    private static let saveDebounce: TimeInterval = 0.5

    /// `root` is the coordinator's own namespace root (SPEC 3.1: "the file
    /// lives inside the same root `IrisMobileShellApp.swift` chooses").
    /// `NativeShellLibraryCoordinator` does not expose its `rootURL` today;
    /// see `MA2-my-apps-screen/INTEGRATION_HOOKS.md` for the one-line,
    /// additive accessor the integrator adds so this can be constructed from
    /// `NativeShellAppView.init` (SPEC integration point 1).
    public init(root: URL, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) throws {
        self.file = try MyAppsOrganizationFile(root: root)
        self.defaults = defaults
        self.clock = clock
        if let raw = defaults.string(forKey: Self.sortDefaultsKey), let sort = MyAppsSort(rawValue: raw) {
            self.sort = sort
        } else {
            self.sort = .groups
        }
        let loaded = file.load()
        self.arrangement = loaded.arrangement
        self.notice = MyAppsOrganizationStore.notice(for: loaded)
    }

    private static func notice(for loaded: MyAppsLoadResult) -> String? {
        // SPEC 1.6: the corrupt-file and version-parked cases both leave the
        // person looking at their apps in their automatic groups (never an
        // invented arrangement); only the wording differs by cause.
        if loaded.wasQuarantined {
            return "Your folders and names couldn't be read. Your apps are all here in their groups."
        }
        return nil
    }

    // MARK: - Reading

    public func sections(apps: [MyAppsAppInput], categories: [MyAppsCategoryInput]) -> MyAppsSectionsOutput {
        MyAppsScreen.sections(input: MyAppsSectionsInput(
            apps: apps, categories: categories, arrangement: arrangement,
            sort: sort, query: query, now: clock()
        ))
    }

    public func actions(for context: MyAppsScreen.MenuContext) -> [MyAppsScreen.MenuAction] {
        MyAppsScreen.actions(for: context)
    }

    // MARK: - Writing (every person action funnels through here)

    @discardableResult
    public func apply(_ action: MyAppsAction) -> Bool {
        switch MyAppsOrganizationReducer.apply(action, to: arrangement) {
        case let .success(outcome):
            arrangement = outcome.arrangement
            lastEvent = outcome.event
            lastError = nil
            scheduleSave()
            return true
        case let .failure(error):
            lastError = error
            return false
        }
    }

    public func recordOpened(identity: String) {
        apply(.recordOpened(identity: identity, at: iso8601(clock())))
    }

    public func recordInstalled(identity: String) {
        apply(.recordInstalled(identity: identity, at: iso8601(clock())))
    }

    /// MA2 hook 1c: an install that settled earlier (the store model queued it
    /// while My apps was not on screen), stamped with the moment it settled.
    public func recordInstalled(identity: String, at date: Date) {
        apply(.recordInstalled(identity: identity, at: iso8601(date)))
    }

    /// A fresh folder id (SPEC 3.1's `"F9A3..."` shape is illustrative only;
    /// any stable, unique string works, so a UUID is used here).
    public func newFolderId() -> String { UUID().uuidString }

    public func nowString() -> String { iso8601(clock()) }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Debounced atomic save (SPEC 3.1: "at most one write per 500 ms")

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = arrangement
        let work = DispatchWorkItem { [weak self] in self?.performSave(snapshot) }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    private func performSave(_ snapshot: MyAppsArrangement) {
        do {
            try file.save(snapshot)
            // SPEC 1.6 "Disk full while saving": a failed save keeps the
            // change on screen (it is already in `arrangement`) and is
            // retried on the next change or launch. A successful save means
            // whatever notice a stale/quarantined file produced no longer
            // applies to what is on disk now.
            if notice != nil { notice = nil }
        } catch {
            notice = "Iris couldn't save your folders right now. Free up space and try again."
        }
    }

    /// Called on scene backgrounding / view teardown so a pending debounced
    /// write is not lost if the process is suspended before the timer fires
    /// (persona P2: "backgrounds the app during a rename"). Synchronous and
    /// cheap (SPEC 3.1: writes are small, well under the OS's background
    /// task budget).
    public func flushPendingSave() {
        guard let pending = pendingSave else { return }
        pending.cancel()
        pendingSave = nil
        performSave(arrangement)
    }

    // MARK: - Fallback construction

    /// Used only when a caller does not supply a real store (see
    /// `StoreMyAppsView.init`'s doc comment). Resolves the same default,
    /// non-fixture, non-acceptance namespace root `IrisMobileShellApp.swift`
    /// picks for an ordinary launch (`Application Support/IrisMobileShell/v1`),
    /// so a normal install's folders and renames persist correctly even
    /// before the integrator's one-line hook lands; a UI test fixture or
    /// acceptance run needs that real hook to point at its own isolated
    /// root instead (`INTEGRATION_HOOKS.md`).
    public static func fallback() -> MyAppsOrganizationStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = support
            .appendingPathComponent("IrisMobileShell", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        if let store = try? MyAppsOrganizationStore(root: root) { return store }
        // Both the standard Application Support root and (inside `init`)
        // its own directory creation failing at once indicates a fatal,
        // already-broken environment; a hand-rolled in-memory stand-in would
        // silently hide that and risk losing the person's folders instead,
        // so this last resort still goes through the same, real,
        // atomic-write-backed store, just at an isolated temporary root.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("iris-my-apps-fallback-\(UUID().uuidString)", isDirectory: true)
        return (try? MyAppsOrganizationStore(root: tmp)) ?? forceFallback(root: tmp)
    }

    private static func forceFallback(root: URL) -> MyAppsOrganizationStore {
        // swiftlint:disable:next force_try -- see `fallback()`'s comment: reaching this
        // line means neither Application Support nor `NSTemporaryDirectory()` is
        // writable, which is unrecoverable for the whole app, not just this screen.
        try! MyAppsOrganizationStore(root: root)
    }
}
#endif
