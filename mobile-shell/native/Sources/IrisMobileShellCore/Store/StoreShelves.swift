import Foundation

// Unit M2-store-layout-implementation. What Browse home shows, in order
// (design section 3.1 and 3.2, sponsored rules of section 14). Pure: the
// same function feeds the SwiftUI views and the tap-budget walk in tests.

public struct StoreShelfCard: Equatable, Sendable, Identifiable {
    public let slug: String
    /// The "Sponsored" tag. A sponsored app is tagged wherever it appears;
    /// Featured is never written on a paid slot.
    public let isSponsored: Bool
    public var id: String { slug }
}

public enum StoreHomeSection: Equatable, Sendable, Identifiable {
    /// Fewer than `collapseBelow` visible apps: one list, catalog order.
    case allApps(slugs: [StoreShelfCard])
    case categoryRow(categoryIds: [Int], allCount: Int)
    case featured(cards: [StoreShelfCard])
    case newAndUpdated(cards: [StoreShelfCard], total: Int)
    case category(id: Int, name: String, cards: [StoreShelfCard], total: Int)
    case browseAllCategories(count: Int)

    public var id: String {
        switch self {
        case .allApps: return "all-apps"
        case .categoryRow: return "category-row"
        case .featured: return "featured"
        case .newAndUpdated: return "new"
        case .category(let id, _, _, _): return "category.\(id)"
        case .browseAllCategories: return "browse-all-categories"
        }
    }

    public var cards: [StoreShelfCard] {
        switch self {
        case .allApps(let cards), .featured(let cards): return cards
        case .newAndUpdated(let cards, _): return cards
        case .category(_, _, let cards, _): return cards
        case .categoryRow, .browseAllCategories: return []
        }
    }
}

public enum StoreShelves {
    public static let collapseBelow = 13
    public static let featuredLimit = 6
    public static let newLimit = 10
    public static let categoryShelfLimit = 6
    public static let cardsPerCategoryShelf = 8
    public static let chipLimit = 24
    public static let sponsoredPerShelf = 1
    public static let sponsoredPerHome = 3
    public static let categoryPageChunk = 50

    public static func home(_ index: StoreCatalogIndex) -> [StoreHomeSection] {
        let visible = index.visibleApps
        if visible.isEmpty { return [] }
        if visible.count < collapseBelow {
            return [.allApps(slugs: visible.map(card))]
        }
        var sections: [StoreHomeSection] = []
        let nonEmpty = index.nonEmptyCategories
        if nonEmpty.count >= 2 {
            sections.append(.categoryRow(categoryIds: nonEmpty.prefix(chipLimit).map(\.id), allCount: nonEmpty.count))
        }
        var sponsoredOnHome = 0
        let featured = capped(visible.filter(\.isFeatured), limit: featuredLimit, sponsoredOnHome: &sponsoredOnHome)
        if !featured.isEmpty { sections.append(.featured(cards: featured)) }

        let fresh = newAndUpdated(index)
        let freshCards = capped(fresh, limit: newLimit, sponsoredOnHome: &sponsoredOnHome)
        if !freshCards.isEmpty { sections.append(.newAndUpdated(cards: freshCards, total: fresh.count)) }

        for category in nonEmpty.prefix(categoryShelfLimit) {
            let cards = capped(index.apps(inCategory: category.id), limit: cardsPerCategoryShelf, sponsoredOnHome: &sponsoredOnHome)
            guard !cards.isEmpty else { continue }
            sections.append(.category(id: category.id, name: category.name, cards: cards, total: index.displayCount(forCategory: category.id)))
        }
        if nonEmpty.count > categoryShelfLimit {
            sections.append(.browseAllCategories(count: nonEmpty.count))
        }
        return sections
    }

    /// Apps with a "new" or "updated" badge, newest first; equal dates keep
    /// catalog order. Also the "See all" list for that shelf.
    public static func newAndUpdated(_ index: StoreCatalogIndex) -> [StoreApp] {
        index.visibleApps.filter(\.isNewOrUpdated).sorted {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.catalogOrder < $1.catalogOrder
        }
    }

    /// A category page shows every visible app in catalog order, sponsored
    /// rows where the catalog put them, tagged.
    public static func categoryPage(_ index: StoreCatalogIndex, categoryId: Int) -> [StoreShelfCard] {
        index.apps(inCategory: categoryId).map(card)
    }

    /// Rows rendered on a category page after the row at `appearedRow`
    /// came on screen: 50 more once the 40th row of the current chunk shows.
    /// Slicing is from memory and synchronous, so a fast scroll across several
    /// trigger rows can only grow the list, never duplicate or reorder it.
    public static func visibleRowCount(current: Int, appearedRow: Int, total: Int) -> Int {
        let current = min(max(current, min(categoryPageChunk, total)), total)
        let trigger = current - (categoryPageChunk - 40)
        guard appearedRow >= trigger - 1 else { return current }
        return min(total, current + categoryPageChunk)
    }

    static func card(_ app: StoreApp) -> StoreShelfCard {
        StoreShelfCard(slug: app.slug, isSponsored: app.isSponsored)
    }

    /// Takes apps in the given order up to `limit`, skipping a sponsored app
    /// once the shelf already holds one or the home already holds three.
    /// Organic apps keep their relative order; nothing is moved forward.
    private static func capped(_ apps: [StoreApp], limit: Int, sponsoredOnHome: inout Int) -> [StoreShelfCard] {
        var cards: [StoreShelfCard] = []
        var sponsoredOnShelf = 0
        for app in apps {
            if cards.count == limit { break }
            if app.isSponsored {
                guard sponsoredOnShelf < sponsoredPerShelf, sponsoredOnHome < sponsoredPerHome else { continue }
                sponsoredOnShelf += 1
                sponsoredOnHome += 1
            }
            cards.append(card(app))
        }
        return cards
    }
}
