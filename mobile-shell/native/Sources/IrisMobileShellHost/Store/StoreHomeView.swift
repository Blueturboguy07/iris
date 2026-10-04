#if os(iOS)
import IrisMobileShellCore
import SwiftUI

/// Unit M2-store-layout-implementation. Browse home (design section 3, WF-01):
/// title and status line, the "Search apps" entry, then the sections
/// `StoreShelves.home` returns, in that order, the same at 3, 100 and 1,000
/// apps. Horizontal shelves become short vertical lists at accessibility
/// text sizes (design 9.3).
struct StoreHomeView<Status: View>: View {
    @ObservedObject var store: StoreModel
    let status: () -> Status
    let openMyApps: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header
                status()
                searchEntry
                if store.home.isEmpty {
                    StoreHomeEmptyView(store: store, openMyApps: openMyApps)
                } else {
                    ForEach(store.home) { section in sectionView(section) }
                }
                footer
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(NativeMarketplaceStyle.paper)
        .foregroundStyle(NativeMarketplaceStyle.ink)
        .refreshable { store.retryCatalog() }
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.root)
        .sheet(isPresented: $store.howWePickIsPresented) {
            StoreHowWePickSheet { store.howWePickIsPresented = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            let titleLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            titleLayout {
                Text("Browse").font(.title.bold()).accessibilityAddTraits(.isHeader)
                if !typeSize.isAccessibilitySize { Spacer() }
                NativePublikWordmark()
            }
            StoreStatusLineView(store: store)
        }
    }

    /// A button that looks like a field: opens Search with the keyboard up.
    private var searchEntry: some View {
        Button { store.perform(.tapSearchEntry) } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(NativeMarketplaceStyle.fog)
                Text("Search apps").foregroundStyle(NativeMarketplaceStyle.fog)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
            .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeMarketplaceStyle.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search apps")
        .accessibilityHint("Opens Search with the keyboard ready.")
        .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.searchEntry)
    }

    @ViewBuilder private func sectionView(_ section: StoreHomeSection) -> some View {
        let ids = NativeAccessibilityIdentifiers.Home.self
        switch section {
        case .allApps(let cards):
            StoreRowListSection(store: store, title: "All apps", subtitle: "\(cards.count) app\(cards.count == 1 ? "" : "s")", cards: cards)
                .accessibilityIdentifier(ids.allApps)
        case .categoryRow(let categoryIds, let allCount):
            StoreCategoryChips(store: store, categoryIds: categoryIds, allCount: allCount)
        case .featured(let cards):
            StoreShelf(store: store, title: "Featured", subtitle: "Chosen by Publik", cards: cards, identifier: ids.featured,
                       trailing: .init(title: "How we pick these", identifier: ids.featuredHow) { store.howWePickIsPresented = true },
                       seeAll: { store.perform(.push(.featured)) })
        case .newAndUpdated(let cards, let total):
            StoreShelf(store: store, title: "New and updated", subtitle: nil, cards: cards, identifier: ids.new,
                       trailing: .init(title: "See all (\(total))", identifier: ids.newSeeAll) { store.perform(.push(.newAndUpdated)) })
        case .category(let id, let name, let cards, let total):
            StoreShelf(store: store, title: name, subtitle: nil, cards: cards, identifier: ids.categoryShelf(id),
                       trailing: .init(title: "See all (\(total))", identifier: ids.categoryShelfSeeAll(id)) { store.perform(.push(.category(id: id))) })
        case .browseAllCategories(let count):
            Button { store.perform(.push(.allCategories)) } label: {
                HStack { Text("Browse all categories (\(count))"); Spacer(); Image(systemName: "chevron.right") }
                    .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(ids.browseAllCategories)
        }
    }

    private var footer: some View {
        Text("Packages are verified before installation. One setup decision, no account required. Camera and selected-photo access stay under your control.")
            .font(.caption).foregroundStyle(NativeMarketplaceStyle.fog)
            .accessibilityIdentifier(NativeAccessibilityIdentifiers.Home.footer)
    }
}

struct StoreShelfTrailing {
    let title: String
    let identifier: String
    let action: () -> Void
}

/// One horizontal shelf of at most 10 cards; a vertical list of the first 3
/// at accessibility text sizes.
struct StoreShelf: View {
    @ObservedObject var store: StoreModel
    let title: String
    let subtitle: String?
    let cards: [StoreShelfCard]
    let identifier: String
    let trailing: StoreShelfTrailing?
    var seeAll: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog) }
                }
                Spacer()
                if let trailing, !typeSize.isAccessibilitySize {
                    Button(action: trailing.action) {
                        Text(trailing.title).font(.subheadline.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier(trailing.identifier)
                }
            }
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(cards.prefix(3)) { card in
                        StoreRowView(store: store, slug: card.slug, sponsored: card.isSponsored) { store.perform(.push(.app(slug: card.slug))) }
                    }
                }
                if let seeAll {
                    Button(action: seeAll) {
                        Text("See all").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityIdentifier(identifier + ".see-all")
                }
                if let trailing {
                    Button(action: trailing.action) {
                        Text(trailing.title).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier(trailing.identifier)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(cards) { card in
                            StoreCardView(store: store, card: card) { store.perform(.push(.app(slug: card.slug))) }
                        }
                    }
                    .padding(.trailing, 16)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Category chips: catalog order, the last one "All N".
struct StoreCategoryChips: View {
    @ObservedObject var store: StoreModel
    let categoryIds: [Int]
    let allCount: Int
    var identifier = NativeAccessibilityIdentifiers.Home.categoryRow
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { chips }
            } else {
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { chips } }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var chips: some View {
        ForEach(categoryIds, id: \.self) { id in
            if let category = store.index.category(id: id) {
                chip(category.name, identifier: NativeAccessibilityIdentifiers.Home.categoryChip(id)) { store.perform(.push(.category(id: id))) }
            }
        }
        chip("All \(allCount)", identifier: NativeAccessibilityIdentifiers.Home.categoryAll) { store.perform(.push(.allCategories)) }
    }

    private func chip(_ title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Drawn 36 pt tall (text plus 16); the tap area is 44 pt (SPEC 4.6).
            Text(title).font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(minHeight: 36)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(NativeMarketplaceStyle.line))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// A titled list of rows (All apps under 13 apps).
struct StoreRowListSection: View {
    @ObservedObject var store: StoreModel
    let title: String
    let subtitle: String
    let cards: [StoreShelfCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.footnote).foregroundStyle(NativeMarketplaceStyle.fog)
                    .accessibilityIdentifier(NativeAccessibilityIdentifiers.Catalog.counts)
            }
            // Rows touch: the pitch is the row's own 76 pt (SPEC 4.3).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(cards) { card in
                    StoreRowView(store: store, slug: card.slug, sponsored: card.isSponsored) { store.perform(.push(.app(slug: card.slug))) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
