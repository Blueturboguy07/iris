import Foundation

// Unit M2-store-layout-implementation. On-device search over the loaded
// catalog (design MOBILE_STORE_DESIGN.md section 4.2):
// - a query matches when every query word is the start of some word of the
//   name, or the name contains the query, or the summary contains it, or the
//   query is exactly one of the app's category names;
// - order: (1) name starts with the whole query, (2) a name word starts
//   with the first query word, (3) name contains the query, (4) summary
//   contains it, (5) category name; ties by newest update, then name,
//   then slug. Exact names share the whole-query prefix bucket.
// - Sponsored and Featured never change the order.

public struct StoreSearchResult: Equatable, Sendable {
    /// The query after normalization (lowercase, no accents, punctuation as spaces).
    public let normalizedQuery: String
    /// Matching apps, best first.
    public let apps: [StoreApp]
    /// Positions (into the index's visible apps) of every match; lets the next
    /// keystroke narrow instead of scanning the whole catalog again.
    let candidatePositions: [Int]

    public var slugs: [String] { apps.map(\.slug) }
    public var isEmptyQuery: Bool { normalizedQuery.isEmpty }
}

public struct StoreSearchIndex: Sendable {
    public static let maximumQueryCharacters = 128

    /// RC-06 (apple-compliance/REQUIRED_CHANGES.md): the "How we pick these"
    /// sheet says sponsored apps are never mixed into search results, but
    /// `search(_:)` above never excluded them (by design: order is organic,
    /// `testSponsoredAndFeaturedNeverChangeSearchOrder` proves sponsorship
    /// never changes ranking) -- so a sponsored app could still show the
    /// Sponsored badge in a search result, contradicting the sheet's own
    /// promise. Recommended shape (OD-03 in
    /// `apple-compliance/DECISIONS.md`): the Sponsored capsule marks paid
    /// *shelf* placement only; search results stay organic and never carry
    /// the badge, so the promise becomes literally true instead of needing
    /// search to exclude sponsored apps outright (which would remove a
    /// genuinely relevant result just for being sponsored elsewhere -- worse
    /// for the person searching). `StoreSearchView.swift` reads this instead
    /// of passing `app.isSponsored` straight through to the row.
    public static let sponsoredBadgeShownInSearchResults = false

    private struct Entry: Sendable {
        let name: String
        let nameWords: [String]
        let summary: String
        let categoryNames: [String]
        let updatedAt: String
    }

    private let apps: [StoreApp]
    private let entries: [Entry]
    private let positionsByCategoryName: [String: [Int]]

    public init(index: StoreCatalogIndex) {
        apps = index.visibleApps
        var byCategory: [String: [Int]] = [:]
        entries = index.visibleApps.enumerated().map { offset, app in
            let categoryNames = index.categoryNames(for: app).map(Self.normalize)
            for name in Set(categoryNames) where !name.isEmpty { byCategory[name, default: []].append(offset) }
            let name = Self.normalize(app.name)
            return Entry(
                name: name,
                nameWords: Self.words(name),
                summary: Self.normalize(app.summary),
                categoryNames: categoryNames,
                updatedAt: app.updatedAt
            )
        }
        positionsByCategoryName = byCategory
    }

    public var appCount: Int { apps.count }

    /// Lowercase, accents removed, every character that is not a letter or a
    /// digit becomes a space, runs of spaces collapse, ends trimmed.
    public static func normalize(_ text: String) -> String {
        let folded = String(text.prefix(maximumQueryCharacters * 8))
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var output = ""
        output.reserveCapacity(folded.count)
        var pendingSpace = false
        for character in folded {
            if character.isLetter || character.isNumber {
                if pendingSpace, !output.isEmpty { output.append(" ") }
                pendingSpace = false
                output.append(character)
            } else {
                pendingSpace = true
            }
        }
        return output
    }

    static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    /// Full scan. Empty (after normalization) returns no apps: the Search tab
    /// shows its idle state instead.
    public func search(_ query: String) -> StoreSearchResult {
        search(query, narrowing: nil)
    }

    /// When `previous` is the result for a query this one extends (a person
    /// typed more letters), only its matches are rescanned, plus the apps of
    /// a category whose name this query now equals. Word matching only gets
    /// stricter as letters are added; category equality is the one rule that
    /// can start matching, so it is looked up directly.
    public func search(_ query: String, narrowing previous: StoreSearchResult?) -> StoreSearchResult {
        let normalized = Self.normalize(String(query.prefix(Self.maximumQueryCharacters)))
        guard !normalized.isEmpty else {
            return StoreSearchResult(normalizedQuery: "", apps: [], candidatePositions: [])
        }
        let queryWords = Self.words(normalized)
        var candidates: [Int]
        if let previous, !previous.normalizedQuery.isEmpty, normalized.hasPrefix(previous.normalizedQuery) {
            var set = Set(previous.candidatePositions)
            for position in positionsByCategoryName[normalized] ?? [] { set.insert(position) }
            candidates = Array(set)
        } else {
            candidates = Array(entries.indices)
        }
        var ranked: [(bucket: Int, position: Int)] = []
        ranked.reserveCapacity(min(candidates.count, 256))
        for position in candidates {
            if let bucket = Self.bucket(entries[position], query: normalized, words: queryWords) {
                ranked.append((bucket, position))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
            let left = entries[lhs.position], right = entries[rhs.position]
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            if left.name != right.name { return left.name < right.name }
            return apps[lhs.position].slug < apps[rhs.position].slug
        }
        candidates = ranked.map(\.position)
        return StoreSearchResult(
            normalizedQuery: normalized,
            apps: candidates.map { apps[$0] },
            candidatePositions: candidates
        )
    }

    /// nil when the app does not match; otherwise its rank bucket (0 is best).
    private static func bucket(_ entry: Entry, query: String, words queryWords: [String]) -> Int? {
        let everyWordStartsANameWord = queryWords.allSatisfy { word in
            entry.nameWords.contains { $0.hasPrefix(word) }
        }
        let nameContains = entry.name.contains(query)
        let summaryContains = !entry.summary.isEmpty && entry.summary.contains(query)
        let categoryEquals = entry.categoryNames.contains(query)
        guard everyWordStartsANameWord || nameContains || summaryContains || categoryEquals else { return nil }
        if entry.name.hasPrefix(query) { return 1 }
        if let first = queryWords.first, entry.nameWords.contains(where: { $0.hasPrefix(first) }) { return 2 }
        if nameContains { return 3 }
        if summaryContains { return 4 }
        return 5
    }
}

/// What the Search tab shows, and when. Pure: the view model supplies the
/// clock (a 120 ms timer) and runs the search; this decides which result set
/// may reach the screen. Each keystroke gets a sequence number; a timer or a
/// result for an older number is dropped, so a slow query can never replace
/// the results of a newer one, and nothing on screen changes while a person
/// is still typing.
public struct StoreSearchDebounce: Equatable, Sendable {
    public static let quietMilliseconds: Int = 120

    public enum Display: Equatable, Sendable {
        /// Empty field: recent searches and categories.
        case idle
        /// Results for `query` (possibly zero).
        case results(query: String, slugs: [String])
    }

    public struct Timer: Equatable, Sendable {
        public let sequence: UInt64
        public let fireAtMilliseconds: Int
    }

    public private(set) var latestSequence: UInt64 = 0
    public private(set) var latestText = ""
    public private(set) var display: Display = .idle
    private var searchInFlight: UInt64?

    public init() {}

    /// A keystroke. Returns the timer to arm, or nil when the field was
    /// cleared (the idle state shows at once).
    public mutating func textChanged(_ text: String, atMilliseconds now: Int) -> Timer? {
        latestSequence &+= 1
        latestText = text
        searchInFlight = nil
        if StoreSearchIndex.normalize(text).isEmpty {
            display = .idle
            return nil
        }
        return Timer(sequence: latestSequence, fireAtMilliseconds: now + Self.quietMilliseconds)
    }

    /// The timer went off. Returns the query to search, or nil when a newer
    /// keystroke superseded this timer.
    public mutating func timerFired(_ timer: Timer, atMilliseconds now: Int) -> (sequence: UInt64, query: String)? {
        guard timer.sequence == latestSequence, now >= timer.fireAtMilliseconds else { return nil }
        searchInFlight = timer.sequence
        return (timer.sequence, latestText)
    }

    /// Results arrived. Returns true when they are now on screen.
    @discardableResult
    public mutating func resultsArrived(sequence: UInt64, query: String, slugs: [String]) -> Bool {
        guard sequence == latestSequence, searchInFlight == sequence else { return false }
        searchInFlight = nil
        display = .results(query: query, slugs: slugs)
        return true
    }
}

/// Up to five recent searches, newest first, no repeats (compared after
/// normalization). Kept on this phone only.
public enum StoreRecentSearches {
    public static let limit = 5

    public static func adding(_ query: String, to recent: [String]) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = StoreSearchIndex.normalize(trimmed)
        guard !key.isEmpty else { return recent }
        let rest = recent.filter { StoreSearchIndex.normalize($0) != key }
        return Array(([String(trimmed.prefix(StoreSearchIndex.maximumQueryCharacters))] + rest).prefix(limit))
    }
}
