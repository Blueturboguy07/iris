#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit MA2 my-apps-screen (route G8, `docs/plans/20260928-all-routes/round3/
/// my-apps-organization/SPEC.md`, sections 1.1-1.7 and 4, "in the List view";
/// the Icons view is MA3 and the Name/Recent/Size letter-index polish is
/// MA4, both out of this unit's scope). Builds on MA1's organization core
/// (`MyAppsOrganization.swift`, `MyAppsOrganizationFile.swift`,
/// `MyAppsScreen.swift`) and replaces M-store-screens' plain list with SPEC
/// 1.1's App-Library-style screen: a search field, a Recently used shelf,
/// the person's own folders, automatic groups by catalog category, and one
/// long-press menu (SPEC 1.2) that is also VoiceOver's custom-actions list,
/// from the same `MyAppsScreen.actions(for:)` source (SPEC's own rule: "so
/// the menu and the actions can never drift apart").
///
/// Every identifier M-store-screens' own MyAppsUITests already assert is
/// kept byte for byte: `iris.store.my-apps`, `.menu`, `.update-all`,
/// `.update-all.note`, `.empty`, `.empty.browse`, `.storage-line`,
/// `.blocked-line`, `iris.open.<appId>`, `iris.versions.<appId>`,
/// `iris.store.my-apps.row.<appId>` (this design only adds sections around
/// existing rows, never renames a row's own identifier). New identifiers
/// come from SPEC section 6's list, written as string literals per this
/// unit's own scope note: `NativeAccessibilityIdentifiers.swift` is not an
/// owned path, so `MA2-my-apps-screen/INTEGRATION_HOOKS.md` gives its owner
/// the exact fold-in, matching every value here.
///
/// Scale (SPEC 3.3): the whole screen is one SwiftUI `List` (UIKit-backed,
/// recycled, not a `LazyVStack`), sectioned by `MyAppsScreen.sections(...)`,
/// a pure function computed fresh each body evaluation from small, already-
/// in-memory inputs (never a disk scan per row); folders and groups become
/// `Section`s so folding one only changes that section's row count, not a
/// full list rebuild.
struct StoreMyAppsView: View {
    @ObservedObject var store: StoreModel
    let library: [NativeShellLibraryEntry]
    @StateObject private var myAppsStore: MyAppsOrganizationStore
    let blockedCount: Int
    let hasBundledDemo: Bool
    let hasBundledDemoUpdate: Bool
    let hasBundledStorageCheck: Bool
    let importPickerRequested: () -> Void
    let refreshLibrary: () -> Void
    let reviewBundledDemo: () -> Void
    let reviewBundledDemoUpdate: () -> Void
    let reviewBundledStorageCheck: () -> Void
    let open: (NativeShellAppIdentity) -> Void
    let openDetails: (NativeShellAppIdentity) -> Void
    /// SPEC 1.2's "Features" menu item: "today `appDetails`... until MV4
    /// lands." Defaults to `openDetails` so the existing call site (which
    /// does not know about this distinction yet) still compiles; see
    /// `INTEGRATION_HOOKS.md` for wiring a real Features destination once
    /// MV4 exists.
    let openFeatures: (NativeShellAppIdentity) -> Void
    let removeApp: ((NativeShellAppIdentity, Bool) async throws -> Void)?
    let browse: () -> Void
    /// SPEC 1.6: "Search the store instead" opens the Search tab with the
    /// same text. Defaults to `browse` (the Browse tab) when the caller has
    /// not wired a real Search-tab handoff yet; see `INTEGRATION_HOOKS.md`.
    let searchStore: (String) -> Void
    let storageDestination: () -> StoreStorageView
    let blockedDestination: () -> StoreBlockedAppsView
    let privacyLink: AnyView

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isSelecting = false
    @State private var selectedIdentities: Set<String> = []
    @State private var renameTarget: MyAppsRenameTarget?
    @State private var moveContext: MyAppsMoveContext?
    @State private var folderNameDialog: MyAppsFolderNameDialogState?
    @State private var reorderTarget: MyAppsReorderTarget?
    @State private var deleteFolderTarget: MyAppsFolder?
    @State private var shareURL: URL?
    @State private var removalTarget: NativeShellLibraryEntry?
    @State private var removalError: String?
    @State private var isRemoving = false

    init(
        store: StoreModel,
        library: [NativeShellLibraryEntry],
        myAppsStore: MyAppsOrganizationStore? = nil,
        blockedCount: Int,
        hasBundledDemo: Bool,
        hasBundledDemoUpdate: Bool,
        hasBundledStorageCheck: Bool,
        importPickerRequested: @escaping () -> Void,
        refreshLibrary: @escaping () -> Void,
        reviewBundledDemo: @escaping () -> Void,
        reviewBundledDemoUpdate: @escaping () -> Void,
        reviewBundledStorageCheck: @escaping () -> Void,
        open: @escaping (NativeShellAppIdentity) -> Void,
        openDetails: @escaping (NativeShellAppIdentity) -> Void,
        openFeatures: ((NativeShellAppIdentity) -> Void)? = nil,
        removeApp: ((NativeShellAppIdentity, Bool) async throws -> Void)? = nil,
        browse: @escaping () -> Void,
        searchStore: ((String) -> Void)? = nil,
        storageDestination: @escaping () -> StoreStorageView,
        blockedDestination: @escaping () -> StoreBlockedAppsView,
        privacyLink: AnyView
    ) {
        self.store = store
        self.library = library
        // SPEC integration point 1: "a `@StateObject` created in
        // `NativeShellAppView.init` from the coordinator's root URL."
        // `NativeShellAppView.swift` is not an owned path in this unit, so
        // the real wiring is one line in `INTEGRATION_HOOKS.md`; until it
        // lands, `.fallback()` resolves the same default (non-fixture,
        // non-acceptance) namespace root `IrisMobileShellApp.swift` uses for
        // an ordinary launch, so a normal install keeps working today. UI
        // test fixture and acceptance namespaces need the real hook (see
        // that file) to point at their own isolated root.
        _myAppsStore = StateObject(wrappedValue: myAppsStore ?? .fallback())
        self.blockedCount = blockedCount
        self.hasBundledDemo = hasBundledDemo
        self.hasBundledDemoUpdate = hasBundledDemoUpdate
        self.hasBundledStorageCheck = hasBundledStorageCheck
        self.importPickerRequested = importPickerRequested
        self.refreshLibrary = refreshLibrary
        self.reviewBundledDemo = reviewBundledDemo
        self.reviewBundledDemoUpdate = reviewBundledDemoUpdate
        self.reviewBundledStorageCheck = reviewBundledStorageCheck
        self.open = open
        self.openDetails = openDetails
        self.openFeatures = openFeatures ?? openDetails
        self.removeApp = removeApp
        self.browse = browse
        self.searchStore = searchStore ?? { _ in browse() }
        self.storageDestination = storageDestination
        self.blockedDestination = blockedDestination
        self.privacyLink = privacyLink
    }

    private func recordSettledInstalls() {
        for record in store.takeSettledInstalls() {
            myAppsStore.recordInstalled(identity: record.identity, at: record.settledAt)
        }
    }

    // MARK: - Derived, computed exactly once per body evaluation and
    // threaded down explicitly (SPEC 3.3: "a row never computes anything").
    // These were plain computed `var`s in an earlier draft of this file;
    // that made every eager (non-closure) per-row argument -- `canOpen:`,
    // `menuActions:` -- re-walk the whole library (and, for `menuActions`,
    // re-run `MyAppsAdapter.appInputs`'s per-app catalog lookups) once per
    // VISIBLE ROW, an O(n) cost paid n times per list render. At 1,000 apps
    // that is the exact anti-pattern SPEC 3.3 rules out ("no disk scans to
    // draw a row"); `MyAppsRenderContext` below is built once in `body` and
    // passed as data instead.
    private struct MyAppsRenderContext {
        let entryByIdentity: [String: NativeShellLibraryEntry]
        let appInputByIdentity: [String: MyAppsAppInput]
        let categoryInputs: [MyAppsCategoryInput]
        let output: MyAppsSectionsOutput
    }

    private func makeRenderContext() -> MyAppsRenderContext {
        let entryByIdentity = Dictionary(uniqueKeysWithValues: library.map { ($0.identity.id, $0) })
        let appInputs = MyAppsAdapter.appInputs(library: library, store: store, starterNames: store.starterDisplayNames)
        let categoryInputs = MyAppsAdapter.categoryInputs(store: store)
        let appInputByIdentity = Dictionary(uniqueKeysWithValues: appInputs.map { ($0.identity, $0) })
        let output = myAppsStore.sections(apps: appInputs, categories: categoryInputs)
        return MyAppsRenderContext(entryByIdentity: entryByIdentity, appInputByIdentity: appInputByIdentity, categoryInputs: categoryInputs, output: output)
    }

    private var outdatedLibrary: [NativeShellLibraryEntry] {
        library.filter { store.hasListedUpdate(for: $0) }
    }

    var body: some View {
        let context = makeRenderContext()
        return VStack(spacing: 0) {
            if library.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        Text("Your installed apps. Your data stays separate.")
                            .font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog)
                        emptyState
                        bottomRows
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                listBody(context)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("My apps")
        .accessibilityIdentifier("iris.store.my-apps")
        // MA2 hook 1c: an install that settled (here or while another tab was
        // showing) counts as used at install time, so it leads Recently used.
        .onAppear { recordSettledInstalls() }
        .onChange(of: store.installSettledCount) { _ in recordSettledInstalls() }
        .sheet(item: $removalTarget) { target in
            VStack(alignment: .leading, spacing: 12) {
                NativeRemoveAppDialog(appName: displayName(for: target.identity.id), onConfirm: { deleteData in
                    guard !isRemoving, let removeApp else { return }
                    isRemoving = true
                    removalError = nil
                    Task {
                        defer { isRemoving = false }
                        do {
                            try await removeApp(target.identity, deleteData)
                            selectedIdentities.remove(target.identity.id)
                            removalTarget = nil
                        } catch {
                            removalError = "Iris couldn't finish removing this app. Try again."
                        }
                    }
                }, onCancel: { removalTarget = nil })
                .disabled(isRemoving)
                if isRemoving { ProgressView("Removing app...") }
                if let removalError { Text(removalError).font(.footnote).padding(.horizontal) }
            }
            .interactiveDismissDisabled(isRemoving)
        }
        .sheet(item: $moveContext) { moveContext in moveSheet(moveContext) }
        .sheet(item: $renameTarget) { target in renameSheet(target) }
        .sheet(item: $folderNameDialog) { state in folderNameSheet(state) }
        .sheet(item: $reorderTarget) { target in reorderSheet(target) }
        .sheet(item: Binding(get: { shareURL.map(MyAppsShareURL.init) }, set: { shareURL = $0?.url })) { item in
            MyAppsActivityView(activityItems: [item.url])
        }
        .nativeConfirmationAlert("Delete the folder \"\(deleteFolderTarget?.name ?? "")\"?",
            message: "Its \(deleteFolderTarget?.apps.count ?? 0) apps go back to their groups. Nothing is removed from your iPhone.",
            isPresented: Binding(get: { deleteFolderTarget != nil }, set: { if !$0 { deleteFolderTarget = nil } }),
            actions: [
                NativeConfirmationAction(title: "Delete folder", style: .destructive,
                    identifier: "iris.store.my-apps.folder-delete.confirm") {
                    if let folder = deleteFolderTarget, myAppsStore.apply(.deleteFolder(folderId: folder.id)) {
                        announce(myAppsStore.lastEvent)
                    }
                    deleteFolderTarget = nil
                },
                NativeConfirmationAction(title: "Keep it", style: .cancel,
                    identifier: "iris.store.my-apps.folder-delete.cancel") { deleteFolderTarget = nil }
            ])
        .onDisappear { myAppsStore.flushPendingSave() }
    }

    /// Non-hot-path lookup: used only by discrete, user-triggered actions
    /// (rename, announcements, the reorder screen's row titles), never
    /// during list layout, so recomputing it on each of those infrequent
    /// calls does not repeat the O(n) cost per visible row the way the
    /// removed computed-property version did.
    private var entryByIdentity: [String: NativeShellLibraryEntry] {
        Dictionary(uniqueKeysWithValues: library.map { ($0.identity.id, $0) })
    }

    // MARK: - Header (title, Select, "...")

    private var header: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
        return layout {
            Text("My apps").font(.title.bold()).accessibilityAddTraits(.isHeader)
            if isSelecting {
                Text("\(selectedIdentities.count) selected")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier("iris.store.my-apps.select.count")
            }
            if !typeSize.isAccessibilitySize { Spacer() }
            if isSelecting {
                Button("Done") { isSelecting = false; selectedIdentities.removeAll() }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("iris.store.my-apps.select.done")
            } else {
                Button("Select") { isSelecting = true; selectedIdentities.removeAll() }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("iris.store.my-apps.select")
                menu
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("New folder", systemImage: "folder.badge.plus") {
                folderNameDialog = .new(prefill: "", initialApps: [])
            }
            .accessibilityIdentifier("iris.store.my-apps.new-folder")

            Menu("Sort by") {
                ForEach(MyAppsSort.allCases, id: \.self) { option in
                    Button {
                        myAppsStore.sort = option
                    } label: {
                        if myAppsStore.sort == option { Label(sortTitle(option), systemImage: "checkmark") }
                        else { Text(sortTitle(option)) }
                    }
                    .accessibilityIdentifier("iris.store.my-apps.sort.\(option.rawValue)")
                }
            }
            .accessibilityIdentifier("iris.store.my-apps.sort-menu")

            Menu("View") {
                Label("List", systemImage: "checkmark").accessibilityIdentifier("iris.store.my-apps.view.list")
                // MA3 (icons-view) has not landed; offered but inert rather
                // than silently doing nothing, per SPEC 1.5's AX5 pattern
                // ("Icons (not at this text size)").
                Text("Icons (coming soon)").accessibilityIdentifier("iris.store.my-apps.view.icons")
            }
            .accessibilityIdentifier("iris.store.my-apps.view-menu")

            Divider()
            #if DEBUG
            Button("Import local package", systemImage: "square.and.arrow.down", action: importPickerRequested)
                .accessibilityIdentifier("iris.import")
            #endif
            Button("Refresh library", systemImage: "arrow.clockwise", action: refreshLibrary)
            #if DEBUG
            if hasBundledDemo {
                Button("Review demo", action: reviewBundledDemo).accessibilityIdentifier("iris.demo.review-v1")
            }
            if hasBundledDemoUpdate {
                Button("Review demo update", action: reviewBundledDemoUpdate).accessibilityIdentifier("iris.demo.review-v2")
            }
            if hasBundledStorageCheck {
                Button("Review storage test", action: reviewBundledStorageCheck).accessibilityIdentifier("iris.storage-check.review")
            }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle").font(.title3).frame(width: 44, height: 44)
        }
        .accessibilityLabel("My apps actions")
        .accessibilityIdentifier("iris.store.my-apps.menu")
    }

    private func sortTitle(_ sort: MyAppsSort) -> String {
        switch sort {
        case .groups: return "Groups"
        case .name: return "Name"
        case .recent: return "Recently used"
        case .size: return "Size"
        }
    }

    // MARK: - List (SPEC 1.1, one recycled List)

    private func listBody(_ context: MyAppsRenderContext) -> some View {
        let output = context.output
        return List {
            Section {
                Text("Your installed apps. Your data stays separate.")
                    .font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog)
                if output.showSearchField {
                    MyAppsSearchFieldView(query: $myAppsStore.query, isSearching: output.isSearching, matchCount: output.searchMatchCount)
                }
                if !outdatedLibrary.isEmpty { updateAllSection }
            }
            .listRowSeparator(.hidden)
            .storeListInsets()

            if output.isSearching {
                if output.sections.first?.rows.isEmpty ?? true {
                    Section {
                        MyAppsSearchZeroStateView(query: myAppsStore.query, searchStore: { searchStore(myAppsStore.query) })
                    }
                    .listRowSeparator(.hidden)
            .storeListInsets()
                } else {
                    Section { rows(output.sections.first?.rows ?? [], context) }
                }
            } else {
                if output.showRecentlyUsed {
                    Section {
                        MyAppsRecentRowView(
                            rows: output.recentlyUsed,
                            onOpen: openAndRecord,
                            actionsFor: { menuActions(for: $0, context) },
                            dispatch: dispatch,
                            folderNameFor: { myAppsStore.arrangement.folder(containing: $0.identity)?.name }
                        )
                    }
                    .listRowSeparator(.hidden)
            .storeListInsets()
                }

                ForEach(Array(output.sections.enumerated()), id: \.offset) { _, section in
                    sectionView(section, context, showsHint: output.showGroupsHint && isFirstGroupSection(section, in: output.sections))
                }
            }

            Section {
                bottomRows
            }
            .listRowSeparator(.hidden)
            .storeListInsets()
        }
        .listStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iris.store.my-apps.list")
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                MyAppsSelectBarView(
                    selectedCount: selectedIdentities.count,
                    removeAvailable: false,
                    onMoveToFolder: {
                        moveContext = MyAppsMoveContext(identities: Array(selectedIdentities), currentFolderId: nil, currentGroupName: "their groups")
                    },
                    onRemove: {}
                )
            }
        }
    }

    private func isFirstGroupSection(_ section: MyAppsSection, in sections: [MyAppsSection]) -> Bool {
        guard case .group = section.kind else { return false }
        return sections.first { if case .group = $0.kind { return true } else { return false } }?.kind == section.kind
    }

    @ViewBuilder private func sectionView(_ section: MyAppsSection, _ context: MyAppsRenderContext, showsHint: Bool) -> some View {
        switch section.kind {
        case .allApps, .flat:
            Section { rows(section.rows, context) }
        case let .folder(id, name, collapsed):
            Section {
                let folder = myAppsStore.arrangement.folders.first { $0.id == id }
                MyAppsFolderHeaderView(
                    folder: folder ?? MyAppsFolder(id: id, name: name, order: 0, createdAt: "", collapsed: collapsed, apps: section.rows.map(\.identity)),
                    onToggleCollapsed: { _ = myAppsStore.apply(.setFolderCollapsed(folderId: id, collapsed: !collapsed)) },
                    onRename: { folderNameDialog = .rename(folderId: id, prefill: name) },
                    onReorder: { reorderTarget = .folderApps(folderId: id) },
                    onDelete: { deleteFolderTarget = folder }
                )
                if !collapsed {
                    if section.rows.isEmpty {
                        MyAppsEmptyFolderRow(folderId: id, onDelete: { deleteFolderTarget = folder })
                    } else {
                        rows(section.rows, context)
                    }
                }
            }
            .storeListInsets()
        case let .group(categoryId, name, collapsed):
            Section {
                if showsHint { MyAppsGroupsHintView() }
                MyAppsGroupHeaderView(title: name, count: section.rows.count, collapsed: collapsed, identifierSuffix: "\(categoryId)") {
                    _ = myAppsStore.apply(.setGroupCollapsed(categoryId: categoryId, collapsed: !collapsed))
                }
                if !collapsed { rows(section.rows, context) }
            }
            .storeListInsets()
        case let .other(collapsed):
            Section {
                MyAppsGroupHeaderView(title: "Other", count: section.rows.count, collapsed: collapsed, identifierSuffix: "other") {
                    _ = myAppsStore.apply(.setGroupCollapsed(categoryId: MyAppsLimits.otherGroupId, collapsed: !collapsed))
                }
                if !collapsed { rows(section.rows, context) }
            }
            .storeListInsets()
        }
    }

    private func rows(_ rows: [MyAppsRow], _ context: MyAppsRenderContext) -> some View {
        ForEach(rows, id: \.identity) { row in
            MyAppsRowView(
                row: row,
                canOpen: context.entryByIdentity[row.identity]?.currentRevisionId != nil,
                onOpenPage: { openDetails(entryByIdentity[row.identity]?.identity ?? NativeShellAppIdentity(appId: "", projectId: "")) },
                onOpen: { openAndRecord(row.identity) },
                onUnblock: { store.setBlocked(false, appId: MyAppsIdentifiers.appIdComponent(row.identity)) },
                menuActions: menuActions(for: row, context),
                dispatch: { dispatch($0, identity: row.identity) },
                selection: isSelecting
                    ? MyAppsSelectionContext(
                        selected: selectedIdentities,
                        toggle: { id in
                            if selectedIdentities.contains(id) { selectedIdentities.remove(id) } else { selectedIdentities.insert(id) }
                        }
                    )
                    : nil,
                folderName: myAppsStore.arrangement.folder(containing: row.identity)?.name
            )
        }
    }

    // MARK: - Update all (unchanged from M-store-screens)

    private var updateAllSection: some View {
        let running = outdatedLibrary.contains { entry in
            slug(for: entry).map { StoreModel.isBusyActivity(store.activities[$0]) } ?? false
        }
        return VStack(alignment: .leading, spacing: 6) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            layout {
                Text("Updates").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer() }
                // A section action, not a hero button (SPEC 4.6): text, 44 pt tap.
                Button(running ? "Updating..." : "Update all (\(outdatedLibrary.count))") {
                    for entry in outdatedLibrary {
                        guard let slug = slug(for: entry) else { continue }
                        store.tapGet(slug)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(NativeMarketplaceStyle.electric)
                .opacity(running ? 0.6 : 1)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .disabled(running)
                .accessibilityIdentifier("iris.store.my-apps.update-all")
            }
            if running {
                Text("Updating one at a time. Other apps still work while this runs.")
                    .font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier("iris.store.my-apps.update-all.note")
            }
        }
    }

    private func slug(for entry: NativeShellLibraryEntry) -> String? {
        store.knownSlug(for: entry.identity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "square.grid.2x2").font(.largeTitle)
            Text("Make this space yours").font(.headline)
            Text("Choose an app in Browse. Review its permissions once, then open it here.")
                .font(.subheadline).foregroundStyle(NativeMarketplaceStyle.fog)
            Button("Browse apps", action: browse)
                .buttonStyle(NativeMarketplaceActionStyle())
                .accessibilityIdentifier("iris.store.my-apps.empty.browse")
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("iris.store.my-apps.empty")
    }

    private var bottomRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let notice = myAppsStore.notice {
                Text(notice).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier("iris.store.my-apps.notice")
            }
            NavigationLink(destination: storageDestination()) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Storage").font(.subheadline.weight(.semibold))
                        Text(storageSubtitle).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("iris.store.my-apps.storage-line")

            if blockedCount > 0 {
                NavigationLink(destination: blockedDestination()) {
                    HStack {
                        Text("Blocked apps (\(blockedCount))").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("iris.store.my-apps.blocked-line")
            }

            privacyLink
        }
    }

    private var storageSubtitle: String {
        let bytes = library.compactMap(\.totalVersionContentBytes).reduce(0, +)
        return "\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) used across \(library.count) app\(library.count == 1 ? "" : "s")"
    }

    // MARK: - Actions

    private func menuActions(for row: MyAppsRow, _ context: MyAppsRenderContext) -> [MyAppsScreen.MenuAction] {
        guard let entry = context.entryByIdentity[row.identity] else { return [] }
        return myAppsStore.actions(for: MyAppsScreen.MenuContext(
            hasUpdate: row.hasUpdate,
            hasCurrentVersion: entry.currentRevisionId != nil,
            needsDownload: row.needsDownload,
            isInFolder: myAppsStore.arrangement.folder(containing: row.identity) != nil,
            hasCatalogSlug: context.appInputByIdentity[row.identity]?.hasCatalogSlug ?? false,
            removeAPIAvailable: removeApp != nil
        ))
    }

    private func openAndRecord(_ identity: String) {
        guard let entry = entryByIdentity[identity] else { return }
        // "Opened" is recorded by `NativeShellAppView` when the app finishes
        // loading (SPEC integration point 1), not at tap time, so a launch
        // that fails to load never reorders Recently used.
        open(entry.identity)
    }

    private func dispatch(_ action: MyAppsScreen.MenuAction, identity: String) {
        guard let entry = entryByIdentity[identity] else { return }
        switch action {
        case .update:
            if let slug = store.knownSlug(for: entry.identity) { store.tapGet(slug) }
        case .open, .download:
            openAndRecord(identity)
        case .rename:
            let custom = myAppsStore.arrangement.customName(for: identity)
            renameTarget = MyAppsRenameTarget(identity: identity, currentDisplayName: displayName(for: identity), isRenamed: custom != nil)
        case .move:
            moveContext = MyAppsMoveContext(
                identities: [identity],
                currentFolderId: myAppsStore.arrangement.folder(containing: identity)?.id,
                currentGroupName: currentGroupName(for: identity)
            )
        case .takeOut:
            if myAppsStore.apply(.takeOutOfFolder(identity: identity)) { announce(myAppsStore.lastEvent) }
        case .features:
            openFeatures(entry.identity)
        case .about:
            openDetails(entry.identity)
        case .share:
            if let slug = store.knownSlug(for: entry.identity), let url = StoreFlowInstallPipeline.appLink(slug: slug) {
                shareURL = url
            }
        case .remove:
            removalError = nil
            removalTarget = entry
        }
    }

    private func displayName(for identity: String) -> String {
        MyAppsAdapter.displayNames(
            library: library,
            store: store,
            arrangement: myAppsStore.arrangement,
            starterNames: store.starterDisplayNames
        ).name(identity: identity, fallback: entryByIdentity[identity]?.displayName ?? "App")
    }

    /// SPEC 1.4: "No folder (stays in Nutrition)" -- the app's automatic
    /// group name, or a neutral phrase when groups are not shown at all
    /// (fewer than 6 apps, or the catalog has not been fetched, SPEC 1.6).
    /// Called only when the person opens the Move sheet (one identity at a
    /// time), never during list layout, so building its own small lookups
    /// here does not repeat the per-row cost `MyAppsRenderContext` exists to
    /// avoid.
    private func currentGroupName(for identity: String) -> String {
        let categoryInputs = MyAppsAdapter.categoryInputs(store: store)
        let appInputs = MyAppsAdapter.appInputs(library: library, store: store, starterNames: store.starterDisplayNames)
        let showGroupHeaders = appInputs.count >= MyAppsLimits.groupHeaderMinInstalledApps
        guard showGroupHeaders, let input = appInputs.first(where: { $0.identity == identity }) else { return "your apps" }
        let known = Set(categoryInputs.map(\.id))
        if let firstId = input.categoryIds.first(where: known.contains),
           let name = categoryInputs.first(where: { $0.id == firstId })?.name {
            return name
        }
        return "Other"
    }

    private func announce(_ event: MyAppsEvent?) {
        guard let event else { return }
        let text: String
        switch event {
        case let .renamed(_, name):
            text = "Renamed to \(name)."
        case .nameReset:
            text = "Restored the original name."
        case let .moved(identity, _, folderName):
            text = "Moved \(displayName(for: identity)) to \(folderName)."
        case let .tookOut(identity, _, fromFolderName):
            text = fromFolderName.isEmpty ? "" : "Took \(displayName(for: identity)) out of \(fromFolderName)."
        case let .folderCreated(_, name):
            text = "Made the folder \(name)."
        case let .folderRenamed(_, name):
            text = "Renamed the folder to \(name)."
        case let .folderDeleted(_, name, _):
            text = "Deleted the folder \(name). Its apps are back in their groups."
        case .folderReordered, .foldersReordered:
            text = "Order updated."
        case let .groupCollapsed(_, collapsed):
            text = collapsed ? "Group collapsed" : "Group expanded"
        case let .folderCollapsed(_, collapsed):
            text = collapsed ? "Folder collapsed" : "Folder expanded"
        case .hintDismissed, .openedRecorded, .installedRecorded, .forgotten:
            text = ""
        }
        guard !text.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - Sheets

    private func renameSheet(_ target: MyAppsRenameTarget) -> some View {
        MyAppsRenameDialogView(
            target: target,
            nameCollision: { candidate in
                library.contains { entry in
                    entry.identity.id != target.identity
                        && displayName(for: entry.identity.id).localizedCaseInsensitiveCompare(candidate) == .orderedSame
                }
            },
            onSave: { name in
                if myAppsStore.apply(.rename(identity: target.identity, to: name)) { announce(myAppsStore.lastEvent) }
                renameTarget = nil
            },
            onUseOriginal: {
                _ = myAppsStore.apply(.useOriginalName(identity: target.identity))
                renameTarget = nil
            },
            onCancel: { renameTarget = nil }
        )
    }

    private func moveSheet(_ context: MyAppsMoveContext) -> some View {
        MyAppsMoveSheetView(
            folders: myAppsStore.arrangement.folders,
            currentFolderId: context.identities.count == 1 ? context.currentFolderId : nil,
            currentGroupName: context.currentGroupName,
            onSelect: { folderId in
                for identity in context.identities {
                    if myAppsStore.apply(.moveToFolder(identity: identity, folderId: folderId)) {
                        announce(myAppsStore.lastEvent)
                    }
                }
                selectedIdentities.subtract(context.identities)
                moveContext = nil
            },
            onNewFolder: {
                folderNameDialog = .new(prefill: context.currentGroupName, initialApps: context.identities)
                moveContext = nil
            },
            onDone: { moveContext = nil }
        )
    }

    private func folderNameSheet(_ state: MyAppsFolderNameDialogState) -> some View {
        MyAppsFolderNameDialogView(
            title: state.title,
            prefill: state.prefill,
            onSave: { name in
                switch state {
                case let .new(_, initialApps):
                    if myAppsStore.apply(.createFolder(id: myAppsStore.newFolderId(), name: name, initialApps: initialApps, createdAt: myAppsStore.nowString())) {
                        announce(myAppsStore.lastEvent)
                    }
                case let .rename(folderId, _):
                    if myAppsStore.apply(.renameFolder(folderId: folderId, to: name)) { announce(myAppsStore.lastEvent) }
                }
                folderNameDialog = nil
            },
            onCancel: { folderNameDialog = nil }
        )
    }

    private func reorderSheet(_ target: MyAppsReorderTarget) -> some View {
        let (title, rows) = reorderRows(for: target)
        return MyAppsReorderView(title: title, rows: rows) { order in
            switch target {
            case let .folderApps(folderId):
                if myAppsStore.apply(.reorderFolderApps(folderId: folderId, order: order)) { announce(myAppsStore.lastEvent) }
            case .folders:
                if myAppsStore.apply(.reorderFolders(order: order)) { announce(myAppsStore.lastEvent) }
            }
            reorderTarget = nil
        }
    }

    private func reorderRows(for target: MyAppsReorderTarget) -> (title: String, rows: [MyAppsReorderRow]) {
        switch target {
        case let .folderApps(folderId):
            guard let folder = myAppsStore.arrangement.folders.first(where: { $0.id == folderId }) else { return ("Reorder", []) }
            return (folder.name, folder.apps.map { MyAppsReorderRow(id: $0, title: displayName(for: $0)) })
        case .folders:
            let sorted = myAppsStore.arrangement.folders.sorted { $0.order < $1.order }
            return ("Reorder folders", sorted.map { MyAppsReorderRow(id: $0.id, title: $0.name) })
        }
    }
}

// MARK: - Sheet/target value types

struct MyAppsMoveContext: Identifiable {
    let identities: [String]
    let currentFolderId: String?
    let currentGroupName: String
    var id: String { identities.joined(separator: ",") }
}

enum MyAppsFolderNameDialogState: Identifiable {
    case new(prefill: String, initialApps: [String])
    case rename(folderId: String, prefill: String)

    var id: String {
        switch self {
        case .new: return "new"
        case let .rename(folderId, _): return "rename-\(folderId)"
        }
    }

    var title: String {
        switch self {
        case .new: return "New folder"
        case .rename: return "Rename folder"
        }
    }

    var prefill: String {
        switch self {
        case let .new(prefill, _): return prefill
        case let .rename(_, prefill): return prefill
        }
    }
}

enum MyAppsReorderTarget: Identifiable {
    case folderApps(folderId: String)
    case folders

    var id: String {
        switch self {
        case let .folderApps(folderId): return "folder-\(folderId)"
        case .folders: return "folders"
        }
    }
}

private struct MyAppsShareURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// SPEC 1.2 "Share link": "the system share sheet". `ShareLink` is a view,
/// not something a dynamic action array can invoke on tap, so this wraps
/// `UIActivityViewController` directly -- the same system sheet
/// `StoreAppPageView`'s toolbar `ShareLink` shows, just triggered
/// programmatically from the long-press menu instead of its own button.
private struct MyAppsActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
