#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation. A category page, "New and updated"
/// (See all) and All categories (design section 5, WF-03). Lists are lazy
/// `List`s; category rows grow 50 at a time from memory.
struct StoreCategoryView: View {
    @ObservedObject var store: StoreModel
    let categoryId: Int
    @State private var shown = StoreShelves.categoryPageChunk
    /// The heading below is the page's name; the top bar repeats it only
    /// once the heading has scrolled away, so the name is on screen once.
    @State private var headingVisible = true

    var body: some View {
        let ids = NativeAccessibilityIdentifiers.Category.self
        Group {
            if let category = store.index.category(id: categoryId) {
                let rows = StoreShelves.categoryPage(store.index, categoryId: categoryId)
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier(ids.title)
                                .onGeometryChange(for: Bool.self) { geometry in
                                    geometry.frame(in: .scrollView(axis: .vertical)).maxY > 0
                                } action: { headingVisible = $0 }
                            let count = store.index.displayCount(forCategory: categoryId)
                            Text("\(count) app\(count == 1 ? "" : "s"), in Publik's order").font(.footnote)
                                .foregroundStyle(NativeMarketplaceStyle.fog)
                                .accessibilityIdentifier(ids.count)
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(NativeMarketplaceStyle.ink)
                        .storeListRow()
                        // Visibility follows scrolling rather than List cell reuse.
                        if rows.isEmpty {
                            StoreNothingHere(store: store).accessibilityIdentifier(ids.empty).storeListInsets()
                        }
                        ForEach(Array(rows.prefix(shown).enumerated()), id: \.element.slug) { position, card in
                            StoreRowView(store: store, slug: card.slug, sponsored: card.isSponsored) { store.perform(.push(.app(slug: card.slug))) }
                                .onAppear { shown = StoreShelves.visibleRowCount(current: shown, appearedRow: position, total: rows.count) }
                        }
                        if shown < rows.count {
                            Text("Loading more...").font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                                .accessibilityIdentifier(ids.loadingMore).storeListRow()
                        }
                        StorePartialListFooter(index: store.index).storeListRow()
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier(ids.list)
                .navigationTitle(headingVisible ? "" : category.name)
            } else {
                StoreGoneView(message: "This category is no longer available.") { store.perform(.back) }
                    .accessibilityIdentifier(ids.gone)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier(ids.root)
    }
}

/// "New and updated", See all: the category page layout with the badge rule.
struct StoreNewAndUpdatedView: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        let apps = StoreShelves.newAndUpdated(store.index)
        VStack(spacing: 0) {
            List {
                Section {
                    Text("\(apps.count) app\(apps.count == 1 ? "" : "s"), newest first").font(.footnote)
                        .foregroundStyle(NativeMarketplaceStyle.fog)
                        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Category.count)
                        .storeListRow()
                    if apps.isEmpty { StoreNothingHere(store: store).storeListInsets() }
                    ForEach(apps) { app in
                        StoreRowView(store: store, slug: app.slug, sponsored: app.isSponsored) { store.perform(.push(.app(slug: app.slug))) }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("New and updated").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Category.list)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Category.root)
    }
}

/// The Featured shelf's complete list at accessibility text sizes.
struct StoreFeaturedView: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        List {
            ForEach(store.index.visibleApps.filter(\.isFeatured)) { app in
                StoreRowView(store: store, slug: app.slug, sponsored: app.isSponsored) {
                    store.perform(.push(.app(slug: app.slug)))
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Featured").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("iris.store.featured")
    }
}

/// All categories: one row each, name and count, 44 pt or taller.
struct StoreAllCategoriesView: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        let ids = NativeAccessibilityIdentifiers.Category.self
        List {
            if store.index.nonEmptyCategories.isEmpty {
                StoreNothingHere(store: store)
            }
            ForEach(store.index.nonEmptyCategories) { category in
                Button { store.perform(.push(.category(id: category.id))) } label: {
                    HStack {
                        Text(category.name).font(.body)
                        Spacer()
                        Text("\(store.index.displayCount(forCategory: category.id)) apps").foregroundStyle(NativeMarketplaceStyle.fog)
                        Image(systemName: "chevron.right").foregroundStyle(NativeMarketplaceStyle.fog).accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .storeListInsets()
                .accessibilityIdentifier(ids.allRow(category.id))
            }
        }
        .listStyle(.plain)
        .navigationTitle("All categories").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier(ids.allRoot)
    }
}

/// An empty list with a way forward.
struct StoreNothingHere: View {
    @ObservedObject var store: StoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing to show here right now.")
            Button("Browse all apps") { store.perform(.selectTab(.browse)); store.perform(.popToRoot) }
                .frame(minHeight: 44)
        }
    }
}

/// A page whose subject disappeared after a refresh: say so, offer Back.
struct StoreGoneView: View {
    let message: String
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
            Button("Back", action: back).frame(minHeight: 44)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
