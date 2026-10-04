#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation (wired by R2-mobile-integration). Three tabs, each with its own
/// NavigationStack (design D1, D13, section 9.1): Browse and Search push store
/// pages; My apps keeps the shell's existing list and destinations, passed in
/// as closures so `NativeShellAppView.body` stays small.
struct StoreTabView<Status: View, MyApps: View, MyAppsDestination: View>: View {
    @ObservedObject var store: StoreModel
    @Binding var myAppsPath: [NativeMarketplaceDestination]
    let library: [NativeShellLibraryEntry]
    let status: () -> Status
    let myApps: () -> MyApps
    let myAppsDestination: (NativeMarketplaceDestination) -> MyAppsDestination
    /// The person's own names for their apps (MA2), read when a page is built.
    let displayNames: () -> MyAppsDisplayNames

    init(
        store: StoreModel,
        myAppsPath: Binding<[NativeMarketplaceDestination]>,
        library: [NativeShellLibraryEntry],
        @ViewBuilder status: @escaping () -> Status,
        @ViewBuilder myApps: @escaping () -> MyApps,
        @ViewBuilder myAppsDestination: @escaping (NativeMarketplaceDestination) -> MyAppsDestination,
        displayNames: @escaping () -> MyAppsDisplayNames = { .empty }
    ) {
        self.store = store
        _myAppsPath = myAppsPath
        self.library = library
        self.status = status
        self.myApps = myApps
        self.myAppsDestination = myAppsDestination
        self.displayNames = displayNames
    }

    var body: some View {
        TabView(selection: Binding(get: { store.navigation.tab }, set: { store.perform(.selectTab($0)) })) {
            browseTab
                .tabItem { Label(StoreTab.browse.title, systemImage: "square.grid.2x2").accessibilityIdentifier(NativeAccessibilityIdentifiers.Tabs.browse) }
                .tag(StoreTab.browse)
            searchTab
                .tabItem { Label(StoreTab.search.title, systemImage: "magnifyingglass").accessibilityIdentifier(NativeAccessibilityIdentifiers.Tabs.search) }
                .tag(StoreTab.search)
            myAppsTab
                .tabItem { Label(StoreTab.myApps.title, systemImage: "person.crop.square").accessibilityIdentifier(NativeAccessibilityIdentifiers.Tabs.myApps) }
                .tag(StoreTab.myApps)
                .badge(store.updateCount(library: library))
        }
        .onAppear {
            store.updateLibrary(library)
            // The store loads its own catalog (index v2, or the v1 list when
            // v2 is not published): one catalog request per launch
            // (CLICK-PATH-006).
            store.start()
        }
        .sheet(item: $store.ageCheckRequest) { request in
            if let gate = store.ageGateForSheet {
                NativeAgeGateSheet(
                    thresholds: .init(ages: NativeAgeGateSheet.storeAges),
                    copy: .store(appAgeRating: request.appAgeRating),
                    ageGate: gate,
                    onDeclared: { _ in store.finishAgeCheck() }
                )
                .presentationDetents([.medium])
            }
        }
        .onChange(of: library) { store.updateLibrary($0) }
        .onChange(of: myAppsResetCount) { _ in myAppsPath.removeAll() }
    }

    private var myAppsResetCount: Int { store.navigation.myAppsPathResetCount }

    private var browseTab: some View {
        NavigationStack(path: Binding(get: { store.navigation.browsePath }, set: { store.navigation.browsePath = $0 })) {
            StoreHomeView(store: store, status: status) { store.perform(.selectTab(.myApps)) }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StoreRoute.self, destination: destination)
        }
    }

    private var searchTab: some View {
        NavigationStack(path: Binding(get: { store.navigation.searchPath }, set: { store.navigation.searchPath = $0 })) {
            StoreSearchView(store: store)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: StoreRoute.self, destination: destination)
        }
    }

    private var myAppsTab: some View {
        NavigationStack(path: $myAppsPath) {
            VStack(alignment: .leading, spacing: 0) {
                status().padding(.horizontal, 16).padding(.top, 12)
                // My apps owns its List or empty-state scroll and its 16 pt gutter.
                myApps()
            }
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
            .background(NativeMarketplaceStyle.paper)
            .foregroundStyle(NativeMarketplaceStyle.ink)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: NativeMarketplaceDestination.self, destination: myAppsDestination)
        }
    }

    @ViewBuilder private func destination(_ route: StoreRoute) -> some View {
        switch route {
        case .app(let slug):
            StoreAppPageView(store: store, slug: slug, openInMyApps: { identity in
                store.perform(.selectTab(.myApps))
                myAppsPath = [.app(identity)]
            }, displayNames: displayNames())
        case .category(let id):
            StoreCategoryView(store: store, categoryId: id)
        case .allCategories:
            StoreAllCategoriesView(store: store)
        case .newAndUpdated:
            StoreNewAndUpdatedView(store: store)
        case .featured:
            StoreFeaturedView(store: store)
        }
    }
}
#endif
