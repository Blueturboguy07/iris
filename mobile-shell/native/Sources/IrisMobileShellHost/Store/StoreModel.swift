#if os(iOS)
import Foundation
import IrisMobileShellCore
import Network
import SwiftUI

/// Unit M2-store-layout-implementation. The store's one view model: the
/// catalog on screen, navigation per tab, search, each Get button, app pages
/// and icons. The shell supplies its library, the v1 rows it already loads,
/// and three actions (prepare for an install, open an app, refresh the
/// library). All decisions live in Core (`IrisMobileShellCore/Store`), where
/// they are tested; this class only wires them to SwiftUI and the clock.
@MainActor
public final class StoreModel: ObservableObject {
    public enum AppPageState: Equatable {
        case loading
        case loaded(PublikMobileCatalogAppPageV2)
        case failed(offline: Bool)
    }

    @Published public var navigation = StoreNavigationState()
    @Published public private(set) var index: StoreCatalogIndex = .empty
    @Published public private(set) var starterDisplayNames: [String: String] = [:]
    @Published public private(set) var freshness: StoreCatalogFreshness = .checking(lastChecked: nil)
    @Published public private(set) var hasCheckedOnce = false
    @Published public var searchText = "" {
        didSet { if searchText != oldValue { searchTextChanged() } }
    }
    @Published public private(set) var searchDisplay: StoreSearchDebounce.Display = .idle
    @Published public private(set) var recentSearches: [String] = []
    @Published public private(set) var activities: [String: StoreInstallActivity] = [:]
    @Published public private(set) var pages: [String: AppPageState] = [:]
    @Published public private(set) var isOnline = true
    @Published public var howWePickIsPresented = false
    @Published public private(set) var blockedAppIDs: Set<String> = []
    @Published public private(set) var declaredAge: Int?
    /// MA2 hook 1c: bumps each time an install settles, so My apps drains
    /// `takeSettledInstalls()` and records "installed" (Recently used).
    @Published public private(set) var installSettledCount = 0
    private var settledInstalls = StoreInstallSettledQueue()
    /// RC-02: set when someone taps "Rated N+ · Check your age"; the tab
    /// view presents `NativeAgeGateSheet` for it. Cleared by `finishAgeCheck`.
    @Published public var ageCheckRequest: StoreAgeCheckRequest?

    public private(set) var screen = StoreScreen(index: .empty)
    public let iconCache: StoreIconCache?

    private let feed: StoreCatalogFeed
    private let controller: StoreInstallController
    private let blockList: Review47BlockList?
    private let ageGate: Review47AgeGate?
    private let openApp: @MainActor (NativeShellAppIdentity) -> Void
    private let refreshLibrary: @MainActor () -> Void
    private let seedReinstaller: (any StoreSeedReinstaller)?
    /// Local usage record for the Privacy page: called when a catalog check
    /// starts; the returned closure is called once with whether it succeeded.
    private let catalogCheckStarted: @MainActor () -> (@MainActor (Bool) -> Void)
    private let defaults: UserDefaults
    private var library: [NativeShellLibraryEntry] = []
    private var legacyRows: [PublikMobileCatalogApp] = []
    private var lastLoad: StoreCatalogLoad?
    private var appIdBySlug: [String: String]
    private var debounce = StoreSearchDebounce()
    private var lastSearch: StoreSearchResult?
    private var refreshTask: Task<Void, Never>?
    /// App pages asked for before the catalog was on screen (a link that
    /// opened Iris cold). Loaded as soon as the row appears (R8.8 cold).
    private var pagesAwaitingIndex: Set<String> = []
    private var pathMonitor: NWPathMonitor?

    private static let recentKey = "iris.store.recent-searches"
    private static let appIdsKey = "iris.store.app-ids-by-slug"

    public init(
        client: PublikMobileCatalogClient,
        cache: PublikMobileCatalogCache? = try? PublikMobileCatalogCache.inAppContainer(),
        pipeline: any StoreInstallPipeline,
        blockList: Review47BlockList?,
        ageGate: Review47AgeGate?,
        defaults: UserDefaults = .standard,
        openApp: @escaping @MainActor (NativeShellAppIdentity) -> Void,
        refreshLibrary: @escaping @MainActor () -> Void,
        catalogCheckStarted: @escaping @MainActor () -> (@MainActor (Bool) -> Void) = { { _ in } },
        seedReinstaller: (any StoreSeedReinstaller)? = nil
    ) {
        // Seed catalog (M-store-screens): network, then disk, then the apps
        // that come with Iris, so Browse is never empty.
        let feed = StoreCatalogFeed.withBundledSeed(client: client, cache: cache)
        self.feed = feed
        let box = StoreModelBox()
        // RC-11: while Browse shows the apps that ship with Iris, a Get for one
        // that was removed sets it up again from the files inside Iris.
        let effectivePipeline: any StoreInstallPipeline
        if let seedReinstaller {
            effectivePipeline = StoreSeedAwarePipeline(base: pipeline, reinstaller: seedReinstaller) { slug in
                await MainActor.run { box.model?.seedReinstallIdentity(for: slug) }
            }
        } else {
            effectivePipeline = pipeline
        }
        self.seedReinstaller = seedReinstaller
        self.controller = StoreInstallController(pipeline: effectivePipeline) { slug, activity in
            Task { @MainActor in box.model?.activityChanged(slug, activity) }
        }
        self.blockList = blockList
        self.ageGate = ageGate
        self.openApp = openApp
        self.refreshLibrary = refreshLibrary
        self.catalogCheckStarted = catalogCheckStarted
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Self.recentKey) ?? []
        appIdBySlug = (defaults.dictionary(forKey: Self.appIdsKey) as? [String: String]) ?? [:]
        iconCache = try? StoreIconCache.inAppContainer(client: client)
        box.model = self
    }

    deinit {
        refreshTask?.cancel()
        pathMonitor?.cancel()
    }

    // MARK: lifecycle

    /// Paint from disk, then one check. Safe to call on every appearance.
    public func start() {
        startPathMonitor()
        Task { await refreshRestrictions() }
        guard refreshTask == nil else { return }
        // Design 13.1: at most one check per 15 minutes; the tab view appears
        // again every time a full-screen app closes (audit CLICK-PATH-003).
        if case .fresh(let checkedAt) = freshness, Date().timeIntervalSince(checkedAt) < 15 * 60 { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            // Seed validation runs on its cache actor after startup yields,
            // so naming the starters never blocks the first frame.
            if !self.hasCheckedOnce, let seed = await StoreCatalogSeed.bundled() {
                var names: [String: String] = [:]
                for app in seed.apps {
                    if let descriptor = seed.pages[app.slug]?.mobileShell {
                        names[descriptor.identity.id] = app.name
                    }
                }
                self.starterDisplayNames = names
            }
            if !self.hasCheckedOnce, let cached = await self.feed.cached() {
                self.apply(cached.load)
                self.freshness = .checking(lastChecked: cached.freshness.lastChecked)
                if case .stale = cached.freshness { self.freshness = cached.freshness }
            }
            await self.runRefresh()
            self.refreshTask = nil
        }
    }

    /// The status line's Try again.
    public func retryCatalog() {
        guard refreshTask == nil else { return }
        freshness = .checking(lastChecked: freshness.lastChecked)
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
            self?.refreshTask = nil
        }
    }

    private func runRefresh() async {
        let previous = freshness.lastChecked
        let finishUsage = catalogCheckStarted()
        let result = await feed.refresh(lastChecked: previous) { [weak self] first in
            await MainActor.run { [weak self] in
                guard let self, self.lastLoad == nil || !self.index.isComplete else { return }
                self.apply(first)
            }
        }
        hasCheckedOnce = true
        finishUsage(result.load != nil)
        if let load = result.load { apply(load) }
        freshness = result.freshness
    }

    /// Inputs from the shell, called whenever they change.
    public func updateLibrary(_ entries: [NativeShellLibraryEntry]) {
        library = entries
        for (slug, activity) in activities {
            if case .installed = activity, installedEntry(for: slug) != nil { Task { await controller.settle(slug: slug) } }
        }
        objectWillChange.send()
    }

    public func updateLegacyRows(_ rows: [PublikMobileCatalogApp]) {
        legacyRows = rows
        for row in rows { if let appId = row.mobileShell?.appId { remember(slug: row.slug, appId: appId) } }
        if lastLoad == nil || (lastLoad?.snapshot == nil && lastLoad?.legacyRows?.isEmpty != false) {
            apply(StoreCatalogLoad(snapshot: nil, legacyRows: rows, categories: []))
        } else {
            rebuildIndex()
        }
    }

    // MARK: catalog

    private func apply(_ load: StoreCatalogLoad) {
        lastLoad = load
        for (slug, descriptor) in load.seedDescriptors { remember(slug: slug, appId: descriptor.appId) }
        for row in load.legacyRows ?? [] { if let appId = row.mobileShell?.appId { remember(slug: row.slug, appId: appId) } }
        rebuildIndex()
    }

    private func rebuildIndex() {
        guard let lastLoad else { return }
        let hidden = Set(appIdBySlug.filter { blockedAppIDs.contains($0.value) }.keys)
        index = lastLoad.index(hiddenSlugs: hidden)
        screen = StoreScreen(index: index)
        lastSearch = nil
        if case .results(let query, _) = searchDisplay {
            searchDisplay = .results(query: query, slugs: screen.search.search(query).slugs)
        }
        for slug in pagesAwaitingIndex where app(slug) != nil {
            pagesAwaitingIndex.remove(slug)
            loadPage(slug)
        }
    }

    public var home: [StoreHomeSection] { screen.home }

    /// True while Browse shows only the seed that ships inside Iris (the
    /// status line says so in plain words).
    public var isShowingBundledSeed: Bool { lastLoad?.isBundledSeed == true }

    public func app(_ slug: String) -> StoreApp? { index.app(slug: slug) }

    // MARK: facts for one button

    public func descriptor(for slug: String) -> PublikMobileShellDescriptor? {
        if case .loaded(let page) = pages[slug] { return page.mobileShell }
        if let descriptor = app(slug)?.descriptor { return descriptor }
        return allLegacyRows.first { $0.slug == slug }?.mobileShell
    }

    /// v1 rows from the store's own fallback load (index v2 not published)
    /// plus any rows a caller still supplies. One source, one request.
    private var allLegacyRows: [PublikMobileCatalogApp] {
        (lastLoad?.legacyRows ?? []) + legacyRows
    }

    /// Every mobile descriptor the store has actually read this session.
    private var knownDescriptors: [(slug: String, descriptor: PublikMobileShellDescriptor)] {
        var result: [(String, PublikMobileShellDescriptor)] = allLegacyRows.compactMap { row in
            row.mobileShell.map { (row.slug, $0) }
        }
        for (slug, state) in pages { if case .loaded(let page) = state { result.append((slug, page.mobileShell)) } }
        return result
    }

    /// A listed revision for an installed app that differs from the one it
    /// runs now (Versions and details offers it; the tap lands on the app
    /// page, where Update is one tap).
    public func listedUpdate(for entry: NativeShellLibraryEntry) -> (slug: String, descriptor: PublikMobileShellDescriptor)? {
        guard let current = entry.currentRevisionId else { return nil }
        return knownDescriptors.first { $0.descriptor.identity == entry.identity && $0.descriptor.revisionId != current }
    }

    public func identity(for slug: String) -> NativeShellAppIdentity? {
        if let descriptor = descriptor(for: slug) { return descriptor.identity }
        if let appId = appIdBySlug[slug] { return library.first { $0.identity.appId == appId }?.identity }
        return nil
    }

    /// unit M-store-screens. The reverse of `identity(for:)`: a catalog slug
    /// this identity has ever been seen under (a fetched page, a v1 row, or
    /// a remembered mapping from a previous launch), for "Update all" to
    /// find which slug's Get state machine to drive. `nil` for an installed
    /// app the catalog side has never resolved a slug for yet.
    public func knownSlug(for identity: NativeShellAppIdentity) -> String? {
        if let match = knownDescriptors.first(where: { $0.descriptor.identity == identity }) { return match.slug }
        return appIdBySlug.first { $0.value == identity.appId }?.key
    }

    /// unit M-store-screens. Public so My apps' "Update all" (`StoreMyAppsView`)
    /// can show the same "already busy" state `tapGet`/the button state
    /// machine use internally, without duplicating the definition of busy.
    public static func isBusyActivity(_ activity: StoreInstallActivity?) -> Bool {
        isBusy(activity ?? .idle)
    }

    public func installedEntry(for slug: String) -> NativeShellLibraryEntry? {
        guard let identity = identity(for: slug) else { return nil }
        return library.first { $0.identity == identity }
    }

    /// MA2 hook 1c: the installs that settled since the last call, oldest first.
    /// My apps writes each one as "installed" so a fresh install leads Recently used.
    public func takeSettledInstalls() -> [StoreInstallSettledQueue.Record] {
        settledInstalls.drain()
    }

    /// RC-11: the identity a seed listing's Get should set up again, or nil when
    /// the seed is not what Browse is showing for this slug.
    func seedReinstallIdentity(for slug: String) -> NativeShellAppIdentity? {
        guard isShowingBundledSeed, let descriptor = lastLoad?.seedDescriptors[slug] else { return nil }
        return descriptor.identity
    }

    public func facts(for slug: String) -> StoreInstallFacts {
        let app = self.app(slug)
        let name = app?.name ?? slug
        let descriptor = descriptor(for: slug)
        let listing: StoreInstallFacts.Listing
        if isShowingBundledSeed, let descriptor {
            // Seed catalog (M-store-screens): see StoreCatalogSeed.listing.
            let installedRevision = installedEntry(for: slug)?.currentRevisionId
            listing = StoreCatalogSeed.listing(
                for: descriptor,
                installedRevisionId: installedRevision,
                // Only asked for an app that is not on this phone (the file check is cheap, but this runs per draw).
                canReinstallFromBundle: installedRevision == nil && (seedReinstaller?.canReinstall(slug: slug) ?? false)
            )
        } else if let descriptor {
            listing = descriptor.platform == "ios"
                ? .listed(revisionId: descriptor.revisionId, baseRevisionId: descriptor.baseRevisionId)
                : .unavailable(reason: "Not published for iPhone yet.")
        } else if app == nil {
            listing = .unavailable(reason: "Not published for iPhone yet.")
        } else {
            listing = .notYetChecked
        }
        let isBlocked = identity(for: slug).map { blockedAppIDs.contains($0.appId) } ?? false
        let restriction = app.map { StoreRestrictionPolicy.restriction(app: $0, isBlocked: isBlocked, declaredAge: declaredAge) }
            ?? (isBlocked ? .blocked : .none)
        return StoreInstallFacts(
            appName: name,
            listing: listing,
            installedRevisionId: installedEntry(for: slug)?.currentRevisionId,
            restriction: restriction,
            isOnline: isOnline)
    }

    public func buttonState(for slug: String) -> StoreInstallButtonState {
        StoreInstallMachine.state(facts: facts(for: slug), activity: activities[slug] ?? .idle)
    }

    /// Installed apps the catalog lists a different revision for (the My
    /// apps tab badge and each row's own Update badge).
    public func updateCount(library: [NativeShellLibraryEntry]) -> Int {
        library.filter { hasListedUpdate(for: $0) }.count
    }

    /// Whether the catalog lists a different revision than the one
    /// currently running, for one installed app. Two sources, either is
    /// enough:
    /// 1. A descriptor this session has actually read (`knownDescriptors`,
    ///    from a legacy v1 row or a fetched app page) -- the original,
    ///    always-correct source.
    /// 2. R2-CP-3: index v2's own optional `latestRevisionId`, matched to
    ///    this identity through `appIdBySlug` (persisted across launches,
    ///    populated the first time any page or v1 row for this app was ever
    ///    seen). This is what lets a returning user see "Update available"
    ///    without opening the app page *this* session -- the open item
    ///    R2-mobile-integration's HANDOFF.md named directly. A brand-new
    ///    identity this device has genuinely never resolved a slug for
    ///    still needs one page visit before its badge can appear; that is
    ///    unavoidable without the catalog naming an appId (out of this
    ///    unit's scope, see INTEGRATION_HOOKS.md).
    public func hasListedUpdate(for entry: NativeShellLibraryEntry) -> Bool {
        guard let current = entry.currentRevisionId else { return false }
        if knownDescriptors.contains(where: { $0.descriptor.identity == entry.identity && $0.descriptor.revisionId != current }) {
            return true
        }
        for (slug, appId) in appIdBySlug where appId == entry.identity.appId {
            if let latest = index.app(slug: slug)?.latestRevisionId, latest != current { return true }
        }
        return false
    }

    // MARK: actions

    /// One tap on Get, Open, Update, Unblock, Try again or Check your age.
    public func tapGet(_ slug: String) {
        let facts = facts(for: slug)
        let current = activities[slug] ?? .idle
        // Mirror the reducer at once so a second tap in the same frame sees
        // progress; the controller stays the single source of truth.
        let others = activities.contains { $0.key != slug && Self.isBusy($0.value) }
        let (next, _) = StoreInstallMachine.reduce(activity: current, event: .tap, facts: facts, anotherInstallRunning: others)
        activities[slug] = next
        Task { [weak self] in
            guard let self else { return }
            // The controller's own change handler publishes its state; reading
            // it back here could land after a newer progress event (audit
            // CLICK-PATH-002), so only the effect is used.
            let effect = await self.controller.handle(.tap, slug: slug, facts: facts)
            self.perform(effect, slug: slug)
        }
    }

    public func cancelGet(_ slug: String) {
        let facts = facts(for: slug)
        Task { await controller.handle(.cancelTap, slug: slug, facts: facts) }
    }

    private func perform(_ effect: StoreInstallEffect, slug: String) {
        switch effect {
        case .open:
            if let identity = identity(for: slug) {
                openApp(identity)
            } else {
                Task { [weak self] in
                    guard let self, let identity = await self.controller.installedIdentity(for: slug) else { return }
                    self.remember(slug: slug, appId: identity.appId)
                    self.openApp(identity)
                }
            }
        case .unblock:
            if let appId = identity(for: slug)?.appId { setBlocked(false, appId: appId) }
        case .checkAge:
            if let rating = app(slug)?.ageRating { ageCheckRequest = StoreAgeCheckRequest(slug: slug, appAgeRating: rating) }
        case .none, .startInstall, .cancelInstall:
            break
        }
    }

    /// The gate behind the age sheet (nil when age checks are switched off).
    var ageGateForSheet: Review47AgeGate? { ageGate }

    /// The sheet reported an answer (or "Not now" as nil). The answer is
    /// already stored by the sheet through `Review47AgeGate.declareMinimumAge`;
    /// this refreshes the buttons so Get appears when the age is enough, and
    /// closes the sheet. Nothing installs by itself.
    public func finishAgeCheck() {
        ageCheckRequest = nil
        Task { [weak self] in await self?.refreshRestrictions() }
    }

    private func activityChanged(_ slug: String, _ activity: StoreInstallActivity) {
        activities[slug] = activity
        if case .installed = activity {
            Task { [weak self] in
                guard let self else { return }
                if let identity = await self.controller.installedIdentity(for: slug) {
                    self.remember(slug: slug, appId: identity.appId)
                    self.settledInstalls.settled(identity: identity.id, at: Date())
                    self.installSettledCount += 1
                }
                self.refreshLibrary()
            }
        }
    }

    private static func isBusy(_ activity: StoreInstallActivity) -> Bool {
        switch activity {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: blocking and age

    public func refreshRestrictions() async {
        if let blockList { blockedAppIDs = await blockList.blockedAppIDs() }
        if let ageGate { declaredAge = await ageGate.declaredMinimumAge() }
        rebuildIndex()
    }

    public var canBlock: Bool { blockList != nil }

    public func setBlocked(_ blocked: Bool, appId: String) {
        guard let blockList else { return }
        Task { [weak self] in
            if blocked { await blockList.block(appId: appId) } else { await blockList.unblock(appId: appId) }
            await self?.refreshRestrictions()
        }
    }

    public func reportTarget(for slug: String) -> Review47ReportComposer.ComposeTarget? {
        guard let descriptor = descriptor(for: slug) else { return nil }
        // Every offered app has a report route, including older catalog metadata.
        let contact = descriptor.appStoreMetadata?.reportContact ?? .email("report@publikhq.com")
        return Review47ReportComposer.composeReport(for: contact, appDisplayName: app(slug)?.name ?? slug, appId: descriptor.appId)
    }

    private func remember(slug: String, appId: String) {
        guard appIdBySlug[slug] != appId else { return }
        appIdBySlug[slug] = appId
        defaults.set(appIdBySlug, forKey: Self.appIdsKey)
    }

    // MARK: app pages

    public func loadPage(_ slug: String) {
        if case .loaded = pages[slug] { return }
        guard let row = app(slug) else {
            // Cold link: the catalog is not on screen yet. Load the page the
            // moment its row arrives instead of never.
            pagesAwaitingIndex.insert(slug)
            return
        }
        guard row.iconHash != nil else { return } // v1 rows have no page
        pages[slug] = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.feed.appPage(slug: slug)
                self.pages[slug] = .loaded(page)
                self.remember(slug: slug, appId: page.mobileShell.appId)
                self.rebuildIndex()
            } catch {
                self.pages[slug] = .failed(offline: StoreCatalogFeed.isOffline(error) || !self.isOnline)
            }
        }
    }

    public func retryPage(_ slug: String) {
        pages[slug] = nil
        loadPage(slug)
    }

    // MARK: search

    public var searchResults: [StoreApp] {
        guard case .results(_, let slugs) = searchDisplay else { return [] }
        return slugs.compactMap { index.app(slug: $0) }
    }

    private func searchTextChanged() {
        let text = String(searchText.prefix(StoreSearchIndex.maximumQueryCharacters))
        if text != searchText { searchText = text; return }
        guard let timer = debounce.textChanged(text, atMilliseconds: Self.nowMilliseconds()) else {
            searchDisplay = debounce.display
            lastSearch = nil
            return
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(StoreSearchDebounce.quietMilliseconds) * 1_000_000)
            guard let self, let run = self.debounce.timerFired(timer, atMilliseconds: Self.nowMilliseconds()) else { return }
            let result = self.screen.search.search(run.query, narrowing: self.lastSearch)
            self.lastSearch = result
            if self.debounce.resultsArrived(sequence: run.sequence, query: run.query, slugs: result.slugs) {
                self.searchDisplay = self.debounce.display
            }
        }
    }

    public func submitSearch() {
        recentSearches = StoreRecentSearches.adding(searchText, to: recentSearches)
        defaults.set(recentSearches, forKey: Self.recentKey)
    }

    public func clearRecentSearches() {
        recentSearches = []
        defaults.removeObject(forKey: Self.recentKey)
    }

    private static func nowMilliseconds() -> Int {
        Int(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    // MARK: navigation

    public func perform(_ action: StoreUserAction) {
        navigation.apply(action)
    }

    /// A publikhq.com app link or `iris-apps://install/<slug>`: the app page
    /// on Browse. Never an install.
    public func openLink(slug: String) {
        navigation.apply(.openLink(slug: slug))
        loadPage(slug)
    }

    // MARK: connectivity

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.connectivityChanged(online) }
        }
        monitor.start(queue: DispatchQueue(label: "iris.store.path"))
        pathMonitor = monitor
    }

    private func connectivityChanged(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        guard online else { return }
        for (slug, activity) in activities {
            if case .note(.offline) = activity {
                let facts = facts(for: slug)
                Task { [weak self] in
                    await self?.controller.handle(.backOnline, slug: slug, facts: facts)
                }
            }
        }
        if freshness.isOffline { retryCatalog() }
    }
}
/// Lets the install controller report back without keeping the model alive.
private final class StoreModelBox: @unchecked Sendable {
    weak var model: StoreModel?
}
#endif

/// One open age check: which app was tapped and the rating that triggered it.
public struct StoreAgeCheckRequest: Identifiable, Equatable, Sendable {
    public let slug: String
    public let appAgeRating: Int
    public var id: String { slug }
}
