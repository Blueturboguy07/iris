#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation. The Search tab (design section 4,
/// WF-02): the real field at the top, focused whenever the tab appears at its
/// root; idle shows recent searches and categories; typing shows a count and
/// a lazy list after a 120 ms pause; zero results always offer a way on.
struct StoreSearchView: View {
    @ObservedObject var store: StoreModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            StoreOfflineBanner(store: store).padding(.horizontal, 16).padding(.bottom, 6)
            content
        }
        .background(NativeMarketplaceStyle.paper)
        .foregroundStyle(NativeMarketplaceStyle.ink)
        .onAppear { fieldFocused = store.navigation.searchFieldFocused }
        .onChange(of: store.navigation.searchFieldFocused) { focused in fieldFocused = focused }
        .onChange(of: fieldFocused) { focused in
            if focused != store.navigation.searchFieldFocused { store.perform(.searchFieldFocus(focused)) }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(NativeMarketplaceStyle.fog).accessibilityHidden(true)
            TextField("Search apps", text: $store.searchText)
                .focused($fieldFocused)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.body).padding(.vertical, 8).submitLabel(.search)
                .onSubmit { store.submitSearch() }
                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.field)
            if !store.searchText.isEmpty {
                Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Clear search")
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.clear)
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(minHeight: 44)
        .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeMarketplaceStyle.line))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch store.searchDisplay {
        case .idle:
            StoreSearchIdleView(store: store)
        case .results(let query, let slugs):
            if slugs.isEmpty {
                StoreSearchZeroView(store: store, query: query)
            } else {
                resultsList(query: query, count: slugs.count)
            }
        }
    }

    private func resultsList(query: String, count: Int) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) app\(count == 1 ? "" : "s") match \u{201C}\(query)\u{201D}").font(.footnote)
                        .foregroundStyle(NativeMarketplaceStyle.fog)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.count)
                    StorePartialListFooter(index: store.index)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .storeListRow()
                ForEach(store.searchResults) { app in
                    // RC-06: search stays organic; the Sponsored badge only
                    // ever marks a paid shelf placement, never a search
                    // result (see StoreSearchIndex.sponsoredBadgeShownInSearchResults).
                    StoreRowView(store: store, slug: app.slug, sponsored: StoreSearchIndex.sponsoredBadgeShownInSearchResults) { store.perform(.push(.app(slug: app.slug))) }
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.results)
    }
}

/// Empty field: recent searches, then categories (design 4.1 item 2).
struct StoreSearchIdleView: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.recentSearches.isEmpty {
                    HStack {
                        Text("Recent").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button("Clear") { store.clearRecentSearches() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.recentClear)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(store.recentSearches.enumerated()), id: \.offset) { position, text in
                            Button(text) { store.searchText = text }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.recentItem(position))
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.recent)
                }
                let categories = store.index.nonEmptyCategories
                if categories.count >= 1 {
                    Text("Browse by category").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    StoreCategoryChips(store: store, categoryIds: categories.prefix(StoreShelves.chipLimit).map(\.id),
                                       allCount: categories.count, identifier: NativeAccessibilityIdentifiers.Search.categories)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

/// Zero results (design 4.1 item 4): say it plainly, offer a way forward.
struct StoreSearchZeroView: View {
    @ObservedObject var store: StoreModel
    let query: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("No apps match \u{201C}\(query)\u{201D}").font(.headline)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.zero)
                let words = StoreSearchIndex.normalize(query).split(separator: " ").map(String.init)
                let related = store.index.nonEmptyCategories.filter { category in
                    let name = StoreSearchIndex.normalize(category.name)
                    return words.contains { name.contains($0) }
                }
                if !related.isEmpty {
                    Text("Or browse a category:").font(.subheadline)
                    StoreCategoryChips(store: store, categoryIds: related.map(\.id), allCount: store.index.nonEmptyCategories.count,
                                       identifier: NativeAccessibilityIdentifiers.Search.zeroCategories)
                }
                Button("Browse all apps") {
                    // With no categories (a small catalog) the whole list is on Browse.
                    store.perform(store.index.nonEmptyCategories.isEmpty ? .selectTab(.browse) : .push(.allCategories))
                }
                    .buttonStyle(NativeMarketplaceActionStyle())
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Search.browseAll)
                StorePartialListFooter(index: store.index)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
