import Foundation

// Unit MA1-organization-core. `sections(input:)`, `actions(for:)`, the
// search matcher and the sort rules: the pure logic behind SPEC sections 1.1
// to 1.6, isolated from the library and catalog types (integration point 5:
// "MA1's input struct isolates the screen from it" if `NativeShellLibraryEntry`
// changes). Nothing here imports `NativeShellLibraryCoordinator` or
// `StoreCatalogIndex`; the caller (MA2) resolves those into the small input
// structs below once per change, and `sections` is deterministic and
// allocation-cheap enough to run at 1,000 apps well under SPEC 3.3's 20 ms
// budget (bucket sort by category id, one sort by name per bucket, no scans
// of anything outside `input`).

// MARK: - Input (assembled by the caller from the library + catalog)

public struct MyAppsAppInput: Sendable, Equatable {
    public let identity: String // NativeShellAppIdentity.id ("appId::projectId")
    public let originalName: String
    /// Catalog or starter display name, resolved by the caller for this identity.
    public let catalogName: String?
    public let descriptionLine: String
    /// The app's slug's `categoryIds`, catalog order (empty when the
    /// catalog is unknown or the app is an imported package -- SPEC 1.1
    /// item 6, item 7's "Other").
    public let categoryIds: [Int]
    public let sizeBytes: Int64?
    public let hasUpdate: Bool
    public let isBlocked: Bool
    public let hasCatalogSlug: Bool
    public let needsDownload: Bool

    public init(
        identity: String,
        originalName: String,
        descriptionLine: String,
        categoryIds: [Int],
        sizeBytes: Int64?,
        hasUpdate: Bool,
        isBlocked: Bool,
        hasCatalogSlug: Bool,
        needsDownload: Bool = false,
        catalogName: String? = nil
    ) {
        self.identity = identity
        self.originalName = originalName
        self.catalogName = catalogName.flatMap { name in
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        }
        self.descriptionLine = descriptionLine
        self.categoryIds = categoryIds
        self.sizeBytes = sizeBytes
        self.hasUpdate = hasUpdate
        self.isBlocked = isBlocked
        self.hasCatalogSlug = hasCatalogSlug
        self.needsDownload = needsDownload
    }
}

public struct MyAppsCategoryInput: Sendable, Equatable {
    public let id: Int
    public let name: String
    public let order: Int

    public init(id: Int, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public enum MyAppsSort: String, Sendable, CaseIterable {
    case groups, name, recent, size
}

public enum MyAppsViewMode: String, Sendable, CaseIterable {
    case list, icons
}

public struct MyAppsSectionsInput: Sendable {
    public let apps: [MyAppsAppInput]
    public let categories: [MyAppsCategoryInput]
    public let arrangement: MyAppsArrangement
    public let sort: MyAppsSort
    public let query: String
    /// Injected so "Opened today" / "yesterday" is deterministic in tests
    /// (SPEC 5's doctrine: no test may depend on the wall clock).
    public let now: Date

    public init(apps: [MyAppsAppInput], categories: [MyAppsCategoryInput], arrangement: MyAppsArrangement, sort: MyAppsSort, query: String, now: Date) {
        self.apps = apps
        self.categories = categories
        self.arrangement = arrangement
        self.sort = sort
        self.query = query
        self.now = now
    }
}

// MARK: - Output

public struct MyAppsRow: Sendable, Equatable {
    public let identity: String
    public let displayName: String
    public let originalName: String
    public let isRenamed: Bool
    public let secondLine: String
    public let hasUpdate: Bool
    public let isBlocked: Bool
    public let needsDownload: Bool
}

public enum MyAppsSectionKind: Sendable, Equatable {
    case allApps
    case folder(id: String, name: String, collapsed: Bool)
    case group(categoryId: Int, name: String, collapsed: Bool)
    case other(collapsed: Bool)
    /// Flat views: Name (letter sections), Recently used, Size, and search
    /// results all render as one section with no folder/group header.
    case flat
}

public struct MyAppsSection: Sendable, Equatable {
    public let kind: MyAppsSectionKind
    public let rows: [MyAppsRow]
}

public struct MyAppsSectionsOutput: Sendable, Equatable {
    public let sections: [MyAppsSection]
    public let recentlyUsed: [MyAppsRow]
    public let showSearchField: Bool
    public let showRecentlyUsed: Bool
    public let showGroupHeaders: Bool
    public let showGroupsHint: Bool
    public let isSearching: Bool
    public let searchMatchCount: Int
}

public enum MyAppsScreen {
    // MARK: sections(input:)

    public static func sections(input: MyAppsSectionsInput) -> MyAppsSectionsOutput {
        let trimmedQuery = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !trimmedQuery.isEmpty

        let rowsByIdentity: [String: MyAppsRow] = Dictionary(uniqueKeysWithValues: input.apps.map { app in
            (app.identity, row(for: app, arrangement: input.arrangement, now: input.now))
        })

        let recentlyUsed = recentRows(apps: input.apps, arrangement: input.arrangement, rowsByIdentity: rowsByIdentity)
        let showRecentlyUsed = input.apps.count >= MyAppsLimits.recentsMinInstalledApps && !recentlyUsed.isEmpty && !isSearching
        let showSearchField = input.apps.count >= MyAppsLimits.searchMinInstalledApps

        if isSearching {
            let matches = search(apps: input.apps, arrangement: input.arrangement, categories: input.categories, query: trimmedQuery, rowsByIdentity: rowsByIdentity)
            return MyAppsSectionsOutput(
                sections: [MyAppsSection(kind: .flat, rows: matches)],
                recentlyUsed: [],
                showSearchField: showSearchField,
                showRecentlyUsed: false,
                showGroupHeaders: false,
                showGroupsHint: false,
                isSearching: true,
                searchMatchCount: matches.count
            )
        }

        switch input.sort {
        case .groups:
            return groupedSections(input: input, rowsByIdentity: rowsByIdentity, recentlyUsed: recentlyUsed, showRecentlyUsed: showRecentlyUsed, showSearchField: showSearchField)
        case .name:
            let rows = input.apps.map { rowsByIdentity[$0.identity]! }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            return MyAppsSectionsOutput(sections: [MyAppsSection(kind: .flat, rows: rows)], recentlyUsed: recentlyUsed, showSearchField: showSearchField, showRecentlyUsed: showRecentlyUsed, showGroupHeaders: false, showGroupsHint: false, isSearching: false, searchMatchCount: 0)
        case .recent:
            // SPEC 1.5: "one flat list, most recent first... Apps never
            // opened come last, by name."
            let order = recentOrder(apps: input.apps, arrangement: input.arrangement)
            var rows = order.compactMap { rowsByIdentity[$0] }
            let openedSet = Set(order)
            let neverOpened = input.apps
                .filter { !openedSet.contains($0.identity) }
                .sorted { rowsByIdentity[$0.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[$1.identity]!.displayName) == .orderedAscending }
                .compactMap { rowsByIdentity[$0.identity] }
            rows.append(contentsOf: neverOpened)
            return MyAppsSectionsOutput(sections: [MyAppsSection(kind: .flat, rows: rows)], recentlyUsed: recentlyUsed, showSearchField: showSearchField, showRecentlyUsed: showRecentlyUsed, showGroupHeaders: false, showGroupsHint: false, isSearching: false, searchMatchCount: 0)
        case .size:
            let bySize = input.apps.sorted { lhs, rhs in
                let lhsSize = lhs.sizeBytes ?? -1
                let rhsSize = rhs.sizeBytes ?? -1
                if lhsSize != rhsSize { return lhsSize > rhsSize }
                return rowsByIdentity[lhs.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[rhs.identity]!.displayName) == .orderedAscending
            }
            let rows = bySize.map { rowsByIdentity[$0.identity]! }
            return MyAppsSectionsOutput(sections: [MyAppsSection(kind: .flat, rows: rows)], recentlyUsed: recentlyUsed, showSearchField: showSearchField, showRecentlyUsed: showRecentlyUsed, showGroupHeaders: false, showGroupsHint: false, isSearching: false, searchMatchCount: 0)
        }
    }

    private static func groupedSections(
        input: MyAppsSectionsInput,
        rowsByIdentity: [String: MyAppsRow],
        recentlyUsed: [MyAppsRow],
        showRecentlyUsed: Bool,
        showSearchField: Bool
    ) -> MyAppsSectionsOutput {
        var inFolder = Set<String>()
        for folder in input.arrangement.folders {
            inFolder.formUnion(folder.apps)
        }

        // Folders first, in the person's order (SPEC 1.1 item 5).
        var sections: [MyAppsSection] = []
        for folder in input.arrangement.folders.sorted(by: { $0.order < $1.order }) {
            let rows = folder.apps.compactMap { rowsByIdentity[$0] }
            sections.append(MyAppsSection(kind: .folder(id: folder.id, name: folder.name, collapsed: folder.collapsed), rows: rows))
        }

        // Automatic groups: bucket every app not in a folder by its first
        // category id (SPEC 1.1 item 6, mutation #6 guards against "last
        // category id instead of first"), "Other" for apps with none or
        // whose category the catalog no longer lists (SPEC 1.6: "a category
        // that disappears sends its apps to Other").
        let knownCategoryIds = Set(input.categories.map(\.id))
        var byCategory: [Int: [MyAppsAppInput]] = [:]
        var other: [MyAppsAppInput] = []
        for app in input.apps where !inFolder.contains(app.identity) {
            if let first = app.categoryIds.first(where: { knownCategoryIds.contains($0) }) {
                byCategory[first, default: []].append(app)
            } else {
                other.append(app)
            }
        }

        let nonEmptyGroupCount = byCategory.filter { !$0.value.isEmpty }.count + (other.isEmpty ? 0 : 1)
        let showGroupHeaders = nonEmptyGroupCount >= MyAppsLimits.groupHeaderMinNonEmptyGroups
            && input.apps.count >= MyAppsLimits.groupHeaderMinInstalledApps

        if showGroupHeaders {
            for category in input.categories.sorted(by: { $0.order < $1.order }) {
                guard let bucket = byCategory[category.id], !bucket.isEmpty else { continue }
                let rows = bucket.sorted { rowsByIdentity[$0.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[$1.identity]!.displayName) == .orderedAscending }
                    .compactMap { rowsByIdentity[$0.identity] }
                let collapsed = input.arrangement.collapsedGroups.contains(category.id)
                sections.append(MyAppsSection(kind: .group(categoryId: category.id, name: category.name, collapsed: collapsed), rows: rows))
            }
            if !other.isEmpty {
                let rows = other.sorted { rowsByIdentity[$0.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[$1.identity]!.displayName) == .orderedAscending }
                    .compactMap { rowsByIdentity[$0.identity] }
                let collapsed = input.arrangement.collapsedGroups.contains(MyAppsLimits.otherGroupId)
                sections.append(MyAppsSection(kind: .other(collapsed: collapsed), rows: rows))
            }
        } else {
            // SPEC 1.1 item 7: below the threshold, one "All apps" section,
            // no headers; folders still show above it.
            let remaining = input.apps.filter { !inFolder.contains($0.identity) }
                .sorted { rowsByIdentity[$0.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[$1.identity]!.displayName) == .orderedAscending }
                .compactMap { rowsByIdentity[$0.identity] }
            if !remaining.isEmpty || sections.isEmpty {
                sections.append(MyAppsSection(kind: .allApps, rows: remaining))
            }
        }

        let showGroupsHint = showGroupHeaders && input.arrangement.folders.isEmpty && !input.arrangement.hintDismissed

        return MyAppsSectionsOutput(
            sections: sections,
            recentlyUsed: recentlyUsed,
            showSearchField: showSearchField,
            showRecentlyUsed: showRecentlyUsed,
            showGroupHeaders: showGroupHeaders,
            showGroupsHint: showGroupsHint,
            isSearching: false,
            searchMatchCount: 0
        )
    }

    // MARK: Row / recents

    private static func row(for app: MyAppsAppInput, arrangement: MyAppsArrangement, now: Date) -> MyAppsRow {
        let customName = arrangement.customName(for: app.identity)
        let displayName = customName ?? app.catalogName ?? app.originalName
        let secondLine = app.needsDownload
            ? "Tap to download (\(formattedSize(app.sizeBytes)))"
            : app.descriptionLine
        return MyAppsRow(
            identity: app.identity,
            displayName: displayName,
            originalName: app.originalName,
            isRenamed: customName != nil,
            secondLine: secondLine,
            hasUpdate: app.hasUpdate,
            isBlocked: app.isBlocked,
            needsDownload: app.needsDownload
        )
    }

    /// SPEC 1.1 item 4: most-recently-opened first, at most 8 tiles, shown
    /// only when 6+ apps are installed and at least one has been opened.
    private static func recentRows(apps: [MyAppsAppInput], arrangement: MyAppsArrangement, rowsByIdentity: [String: MyAppsRow]) -> [MyAppsRow] {
        let order = recentOrder(apps: apps, arrangement: arrangement)
        return order.prefix(MyAppsLimits.recentsMaxTiles).compactMap { rowsByIdentity[$0] }
    }

    /// Every opened-or-installed identity, most recent first; ties (equal
    /// timestamp, e.g. under a skewed clock -- persona P3) break by the
    /// identity string so the order is a total order and never flickers
    /// between two computations of the same input.
    private static func recentOrder(apps: [MyAppsAppInput], arrangement: MyAppsArrangement) -> [String] {
        let byIdentity = Dictionary(uniqueKeysWithValues: apps.map { ($0.identity, $0) })
        let withTimestamps: [(String, String)] = arrangement.apps.compactMap { key, entry in
            guard byIdentity[key] != nil, let opened = entry.lastOpenedAt else { return nil }
            return (key, opened)
        }
        return withTimestamps
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 } // ISO 8601 strings sort lexicographically
                return lhs.0 < rhs.0
            }
            .map(\.0)
    }

    private static func formattedSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return "0 MB" }
        let mb = Double(bytes) / 1_000_000
        if mb < 1 { return "<1 MB" }
        return "\(Int(mb.rounded())) MB"
    }

    // MARK: Search (SPEC 1.1 item 2, mutation #10)

    /// Same tokenizer idea as `StoreSearchIndex.normalize`: case- and
    /// diacritic-insensitive, split on non-alphanumerics, word order free.
    /// Matches the chosen name, the original name (mutation #10: a person
    /// who renamed "Kneecap" to "Clips" can still find it by typing
    /// "Kneecap"), the description, and the app's group or folder name.
    static func tokens(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let pieces = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(pieces.filter { !$0.isEmpty })
    }

    private static func search(
        apps: [MyAppsAppInput],
        arrangement: MyAppsArrangement,
        categories: [MyAppsCategoryInput],
        query: String,
        rowsByIdentity: [String: MyAppsRow]
    ) -> [MyAppsRow] {
        let queryTokens = tokens(query)
        guard !queryTokens.isEmpty else { return [] }
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        let folderNameByIdentity: [String: String] = {
            var map: [String: String] = [:]
            for folder in arrangement.folders {
                for identity in folder.apps { map[identity] = folder.name }
            }
            return map
        }()

        return apps.filter { app in
            guard let row = rowsByIdentity[app.identity] else { return false }
            var haystack = tokens(row.displayName)
            haystack.formUnion(tokens(row.originalName))
            if let catalogName = app.catalogName { haystack.formUnion(tokens(catalogName)) }
            haystack.formUnion(tokens(row.secondLine))
            if let folderName = folderNameByIdentity[app.identity] {
                haystack.formUnion(tokens(folderName))
            } else {
                for id in app.categoryIds {
                    if let name = categoryNames[id] { haystack.formUnion(tokens(name)) }
                }
            }
            // Word order free (SPEC 1.1 item 2): every query token must
            // appear as a substring of some haystack token.
            return queryTokens.allSatisfy { needle in haystack.contains { $0.contains(needle) } }
        }
        .sorted { rowsByIdentity[$0.identity]!.displayName.localizedCaseInsensitiveCompare(rowsByIdentity[$1.identity]!.displayName) == .orderedAscending }
        .compactMap { rowsByIdentity[$0.identity] }
    }

    // MARK: actions(for:) -- SPEC 1.2's long-press menu, byte-for-byte the
    // same list and order VoiceOver's custom actions use (SPEC section 4).

    public enum MenuAction: String, Sendable, CaseIterable {
        case update, open, download, rename, move, takeOut, features, about, share, remove
    }

    public struct MenuContext: Sendable {
        public let hasUpdate: Bool
        public let hasCurrentVersion: Bool
        public let needsDownload: Bool
        public let isInFolder: Bool
        public let hasCatalogSlug: Bool
        public let removeAPIAvailable: Bool

        public init(hasUpdate: Bool, hasCurrentVersion: Bool, needsDownload: Bool, isInFolder: Bool, hasCatalogSlug: Bool, removeAPIAvailable: Bool) {
            self.hasUpdate = hasUpdate
            self.hasCurrentVersion = hasCurrentVersion
            self.needsDownload = needsDownload
            self.isInFolder = isInFolder
            self.hasCatalogSlug = hasCatalogSlug
            self.removeAPIAvailable = removeAPIAvailable
        }
    }

    /// SPEC 1.2's table, in its exact order, "only the ones that apply".
    /// The same function backs the context menu and VoiceOver's custom
    /// actions (section 4), so they cannot drift apart.
    public static func actions(for context: MenuContext) -> [MenuAction] {
        var list: [MenuAction] = []
        if context.hasUpdate { list.append(.update) }
        if context.hasCurrentVersion { list.append(.open) }
        if context.needsDownload { list.append(.download) }
        list.append(.rename)
        list.append(.move)
        if context.isInFolder { list.append(.takeOut) }
        list.append(.features)
        list.append(.about)
        if context.hasCatalogSlug { list.append(.share) }
        if context.removeAPIAvailable { list.append(.remove) }
        return list
    }
}
