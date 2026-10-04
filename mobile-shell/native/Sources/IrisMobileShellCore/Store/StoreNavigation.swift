import Foundation

// Unit M2-store-layout-implementation. Tabs and pushed pages (design 9.1 and
// 9.5). Each tab keeps its own path, so switching tabs never loses a page. A
// link from publikhq.com selects Browse, pops to the root and pushes that
// app's page; it never starts an install.

public enum StoreTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case browse
    case search
    case myApps

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .browse: return "Browse"
        case .search: return "Search"
        case .myApps: return "My apps"
        }
    }
}

public enum StoreRoute: Hashable, Sendable {
    case app(slug: String)
    case category(id: Int)
    case allCategories
    case newAndUpdated
    case featured
}

public enum StoreUserAction: Equatable, Sendable {
    case selectTab(StoreTab)
    /// The "Search apps" field on Browse: a button that opens Search with the
    /// keyboard up.
    case tapSearchEntry
    case push(StoreRoute)
    case back
    case popToRoot
    /// A publikhq.com app link or `iris-apps://install/<slug>`.
    case openLink(slug: String)
    /// The full-screen app closed: the store shows My apps (existing rule).
    case appClosed
    case searchFieldFocus(Bool)
}

public struct StoreNavigationState: Hashable, Sendable {
    public var tab: StoreTab = .browse
    public var browsePath: [StoreRoute] = []
    public var searchPath: [StoreRoute] = []
    /// My apps keeps its own destinations (the existing shell's list); the
    /// store only needs to know when to clear them.
    public var myAppsPathResetCount = 0
    public var searchFieldFocused = false

    public init() {}

    public var currentPath: [StoreRoute] {
        switch tab {
        case .browse: return browsePath
        case .search: return searchPath
        case .myApps: return []
        }
    }

    public mutating func apply(_ action: StoreUserAction) {
        switch action {
        case .selectTab(let next):
            if next == tab {
                // Tapping the selected tab pops it to its root, as iOS does.
                popCurrentToRoot()
            }
            tab = next
            // The field takes focus whenever Search appears at its root.
            searchFieldFocused = next == .search && searchPath.isEmpty
        case .tapSearchEntry:
            tab = .search
            searchPath = []
            searchFieldFocused = true
        case .push(let route):
            switch tab {
            case .browse: browsePath.append(route)
            case .search: searchPath.append(route); searchFieldFocused = false
            case .myApps: break
            }
        case .back:
            switch tab {
            case .browse: if !browsePath.isEmpty { browsePath.removeLast() }
            case .search: if !searchPath.isEmpty { searchPath.removeLast() }
            case .myApps: break
            }
        case .popToRoot:
            popCurrentToRoot()
        case .openLink(let slug):
            tab = .browse
            browsePath = [.app(slug: slug)]
            searchFieldFocused = false
        case .appClosed:
            tab = .myApps
            myAppsPathResetCount &+= 1
            searchFieldFocused = false
        case .searchFieldFocus(let focused):
            searchFieldFocused = focused && tab == .search
        }
    }

    private mutating func popCurrentToRoot() {
        switch tab {
        case .browse: browsePath = []
        case .search: searchPath = []
        case .myApps: myAppsPathResetCount &+= 1
        }
    }
}

/// Every control a person can tap on the current screen, derived from the
/// same layout functions the views render. The tap-budget walk in the tests
/// and M5's persona sim move through the store only with these.
public enum StoreTarget: Hashable, Sendable {
    case tab(StoreTab)
    case searchEntry
    /// The real field on the Search tab (only needed when it lost focus).
    case searchField
    case categoryChip(Int)
    case allCategoriesChip
    case seeAllNew
    case seeAllCategory(Int)
    case browseAllCategories
    /// Tap a card or row outside its button: opens the app page.
    case openPage(slug: String)
    /// The Get, Open or Update button on a card, a row or the app page.
    case get(slug: String)
    case back
}

public struct StoreScreen: Sendable {
    public let index: StoreCatalogIndex
    public let search: StoreSearchIndex
    public let home: [StoreHomeSection]

    public init(index: StoreCatalogIndex) {
        self.index = index
        search = StoreSearchIndex(index: index)
        home = StoreShelves.home(index)
    }

    /// Controls on screen for `state` with `query` typed in the Search field.
    public func targets(for state: StoreNavigationState, query: String) -> [StoreTarget] {
        var targets: [StoreTarget] = StoreTab.allCases.map { .tab($0) }
        if let route = state.currentPath.last {
            targets.append(.back)
            targets += routeTargets(route)
            return targets
        }
        switch state.tab {
        case .browse:
            targets.append(.searchEntry)
            for section in home {
                switch section {
                case .categoryRow(let ids, _):
                    targets += ids.map { .categoryChip($0) }
                    targets.append(.allCategoriesChip)
                case .newAndUpdated:
                    targets.append(.seeAllNew)
                case .category(let id, _, _, _):
                    targets.append(.seeAllCategory(id))
                case .browseAllCategories:
                    targets.append(.browseAllCategories)
                case .allApps, .featured:
                    break
                }
                for card in section.cards {
                    targets.append(.openPage(slug: card.slug))
                    targets.append(.get(slug: card.slug))
                }
            }
        case .search:
            targets.append(.searchField)
            let result = search.search(query)
            if result.isEmptyQuery {
                targets += index.nonEmptyCategories.prefix(StoreShelves.chipLimit).map { .categoryChip($0.id) }
                targets.append(.allCategoriesChip)
            } else {
                for app in result.apps {
                    targets.append(.openPage(slug: app.slug))
                    targets.append(.get(slug: app.slug))
                }
                if result.apps.isEmpty { targets.append(.browseAllCategories) }
            }
        case .myApps:
            break
        }
        return targets
    }

    private func routeTargets(_ route: StoreRoute) -> [StoreTarget] {
        switch route {
        case .app(let slug):
            return [.get(slug: slug)]
        case .category(let id):
            return StoreShelves.categoryPage(index, categoryId: id).flatMap { [StoreTarget.openPage(slug: $0.slug), .get(slug: $0.slug)] }
        case .featured:
            return index.visibleApps.filter(\.isFeatured).flatMap { [StoreTarget.openPage(slug: $0.slug), .get(slug: $0.slug)] }
        case .newAndUpdated:
            return StoreShelves.newAndUpdated(index).flatMap { [StoreTarget.openPage(slug: $0.slug), .get(slug: $0.slug)] }
        case .allCategories:
            return index.nonEmptyCategories.map { .categoryChip($0.id) }
        }
    }

    /// The navigation a tap causes; nil for Get (handled by the button).
    public static func action(for target: StoreTarget) -> StoreUserAction? {
        switch target {
        case .tab(let tab): return .selectTab(tab)
        case .searchEntry: return .tapSearchEntry
        case .searchField: return .searchFieldFocus(true)
        case .categoryChip(let id), .seeAllCategory(let id): return .push(.category(id: id))
        case .allCategoriesChip, .browseAllCategories: return .push(.allCategories)
        case .seeAllNew: return .push(.newAndUpdated)
        case .openPage(let slug): return .push(.app(slug: slug))
        case .back: return .back
        case .get: return nil
        }
    }
}
