import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Search as a person uses it, at 3, 100 and 1,000 apps. Every result list is
/// compared, in order, with a brute-force matcher written in this file from
/// the design text (MOBILE_STORE_DESIGN.md section 4.2), which reads the raw
/// fixture JSON itself rather than the store's own rows. Queries come from a
/// seeded generator: prefixes typed letter by letter (a hurried user), words
/// out of order, a word from the summary (a vague user), category names,
/// accents, punctuation, junk and an over-long paste (an edge user).
final class StoreSearchIndexTests: XCTestCase {
    // MARK: independent oracle

    private struct OracleApp {
        let slug: String
        let name: String
        let summary: String
        let categories: [String]
        let updatedAt: String
        // Normalized once per app (still with this file's own normalizer).
        let normName: String
        let nameWords: [String]
        let normSummary: String
        let normCategories: [String]

        init(slug: String, name: String, summary: String, categories: [String], updatedAt: String) {
            self.slug = slug
            self.name = name
            self.summary = summary
            self.categories = categories
            self.updatedAt = updatedAt
            normName = StoreSearchIndexTests.oracleNormalized(name)
            nameWords = StoreSearchIndexTests.oracleWords(name)
            normSummary = StoreSearchIndexTests.oracleNormalized(summary)
            normCategories = categories.map(StoreSearchIndexTests.oracleNormalized)
        }
    }

    /// Lowercase, accents stripped, anything that is not a letter or digit is
    /// a word break. Written differently from the store's normalizer.
    private static func oracleWords(_ text: String) -> [String] {
        let stripped = (text.applyingTransform(.stripDiacritics, reverse: false) ?? text).lowercased()
        var words: [String] = []
        var current = ""
        for scalar in stripped.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func oracleNormalized(_ text: String) -> String { oracleWords(text).joined(separator: " ") }

    private static func oracleApps(publish: CatalogPublish, hidden: Set<String> = []) throws -> [OracleApp] {
        let categoriesJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(publish.files[CatalogPublish.categoriesPath])) as? [String: Any])
        var names: [Int: String] = [:]
        for row in try XCTUnwrap(categoriesJSON["categories"] as? [[String: Any]]) {
            names[try XCTUnwrap(row["id"] as? Int)] = try XCTUnwrap(row["name"] as? String)
        }
        return try publish.appRows().compactMap { row in
            let slug = try XCTUnwrap(row["slug"] as? String)
            guard !hidden.contains(slug) else { return nil }
            let ids = try XCTUnwrap(row["categoryIds"] as? [Int])
            return OracleApp(
                slug: slug,
                name: try XCTUnwrap(row["name"] as? String),
                summary: try XCTUnwrap(row["summary"] as? String),
                categories: ids.compactMap { names[$0] },
                updatedAt: try XCTUnwrap(row["updatedAt"] as? String)
            )
        }
    }

    private static func oracleSearch(_ raw: String, in apps: [OracleApp]) -> [String] {
        let query = oracleNormalized(String(raw.prefix(128)))
        guard !query.isEmpty else { return [] }
        let queryWords = oracleWords(query)
        var hits: [(Int, OracleApp)] = []
        for app in apps {
            let name = app.normName
            let nameWords = app.nameWords
            let summary = app.normSummary
            let categories = app.normCategories
            let allWordsStart = queryWords.allSatisfy { q in nameWords.contains { $0.hasPrefix(q) } }
            let nameHas = name.range(of: query) != nil
            let summaryHas = summary.range(of: query) != nil
            let categoryIs = categories.contains(query)
            guard allWordsStart || nameHas || summaryHas || categoryIs else { continue }
            let bucket: Int
            // MOBILE_STORE_DESIGN.md 4.2: exact and longer whole-query
            // prefixes share bucket 1, with ties broken by updatedAt.
            if name.hasPrefix(query) { bucket = 1 }
            else if nameWords.contains(where: { $0.hasPrefix(queryWords[0]) }) { bucket = 2 }
            else if nameHas { bucket = 3 }
            else if summaryHas { bucket = 4 }
            else { bucket = 5 }
            hits.append((bucket, app))
        }
        hits.sort { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.updatedAt != b.1.updatedAt { return a.1.updatedAt > b.1.updatedAt }
            let an = a.1.normName, bn = b.1.normName
            if an != bn { return an < bn }
            return a.1.slug < b.1.slug
        }
        return hits.map(\.1.slug)
    }

    // MARK: query generator (seeded personas)

    private static func queries(for apps: [OracleApp], seed: UInt64, count: Int) -> [String] {
        var random = StoreSeededRandom(seed: seed)
        var out: [String] = ["", "   ", "!!", "a", "e", "zzzz", "qúick", "RECIPES", String(repeating: "board ", count: 40), "Health & Fitness", "health", "fitness health"]
        for letter in "abcdefghijklmnopqrstuvwxyz" { out.append(String(letter)) }
        for _ in 0..<count {
            let app = apps[Int(random.next() % UInt64(apps.count))]
            let name = app.name
            switch random.next() % 8 {
            case 0: out.append(String(name.prefix(Int(random.next() % UInt64(max(1, name.count))) + 1)))
            case 1: out.append(name.lowercased())
            case 2: out.append(name.split(separator: " ").reversed().joined(separator: " "))
            case 3:
                let words = app.summary.split(separator: " ")
                if let word = words.randomElement(using: &random) { out.append(String(word)) }
            case 4:
                let words = app.summary.split(separator: " ")
                if words.count > 2 {
                    let start = Int(random.next() % UInt64(words.count - 1))
                    out.append(words[start...start + 1].joined(separator: " "))
                }
            case 5: if let category = app.categories.randomElement(using: &random) { out.append(category) }
            case 6:
                let chars = Array(name)
                if chars.count > 3 {
                    let start = Int(random.next() % UInt64(chars.count - 2))
                    out.append(String(chars[start..<min(chars.count, start + 3)]))
                }
            default: out.append(name + "x")
            }
        }
        return out
    }

    // MARK: tests

    func testSearchResultsEqualTheBruteForceOracleAtEveryCatalogSize() async throws {
        for size in StoreWorld.sizes {
            let publish = try CatalogPublish.fixture(size)
            let index = try await StoreWorld.index(appCount: size)
            let search = StoreSearchIndex(index: index)
            let apps = try Self.oracleApps(publish: publish)
            for seed: UInt64 in [11, 23, 47] {
                for query in Self.queries(for: apps, seed: seed &+ UInt64(size), count: size == 1000 ? 150 : 80) {
                    XCTAssertEqual(search.search(query).slugs, Self.oracleSearch(query, in: apps),
                                   "size \(size) seed \(seed) query \"\(query)\"")
                }
            }
        }
    }

    /// A person typing each letter (and sometimes deleting one): the narrowed
    /// search after every keystroke must equal a fresh brute-force scan.
    func testTypingLetterByLetterWithBackspacesMatchesTheOracleAfterEveryKeystroke() async throws {
        for size in [100, 1000] {
            let publish = try CatalogPublish.fixture(size)
            let index = try await StoreWorld.index(appCount: size)
            let search = StoreSearchIndex(index: index)
            let apps = try Self.oracleApps(publish: publish)
            var random = StoreSeededRandom(seed: 0xB0A7 &+ UInt64(size))
            for _ in 0..<40 {
                let target = apps[Int(random.next() % UInt64(apps.count))]
                var typed = ""
                var previous: StoreSearchResult?
                // A vague user types a category word on its own every third run.
                let letters = random.next() % 3 == 0
                    ? Array(target.categories.first ?? target.name)
                    : Array(target.name + " " + (target.categories.first ?? ""))
                var position = 0
                while position < letters.count {
                    if random.next() % 7 == 0, !typed.isEmpty {
                        typed.removeLast()
                    } else {
                        typed.append(letters[position])
                        position += 1
                    }
                    let result = search.search(typed, narrowing: previous)
                    XCTAssertEqual(result.slugs, Self.oracleSearch(typed, in: apps), "size \(size) typed \"\(typed)\"")
                    previous = result
                }
            }
        }
    }

    /// Typing the full name finds the app (design 4.2). A newer app whose
    /// name starts with the query may appear first in the same prefix bucket.
    func testEveryAppIsFoundByItsOwnName() async throws {
        for size in StoreWorld.sizes {
            let index = try await StoreWorld.index(appCount: size)
            let search = StoreSearchIndex(index: index)
            for app in index.visibleApps {
                let result = search.search(app.name).slugs
                XCTAssertTrue(result.contains(app.slug), "\(size): \(app.name) not found by its own name")
            }
        }
    }

    /// MOBILE_STORE_DESIGN.md 4.2: whole-query prefixes are one bucket.
    /// Ties use updatedAt, regardless of sponsored or editorial placement.
    /// The dates below are independent facts, not ranks from the search API.
    func testWholeQueryPrefixesTieByUpdatedAtIncludingTheExactName() async throws {
        let base = try await StoreWorld.index(appCount: 100)
        let template = try XCTUnwrap(base.visibleApps.first)
        func app(_ slug: String, _ name: String, updatedAt: String, sponsored: Bool = false, featured: Bool = false, order: Int) -> StoreApp {
            StoreApp(slug: slug, name: name, summary: "Edit short videos on your phone.", categoryIds: template.categoryIds,
                     iconHash: template.iconHash, iconURL: template.iconURL, byteCount: template.byteCount,
                     ageRating: template.ageRating, updatedAt: updatedAt, badges: [], isFeatured: featured,
                     isSponsored: sponsored, placementLabel: sponsored ? "Sponsored" : (featured ? "Featured" : nil),
                     catalogOrder: order, descriptor: nil)
        }
        let family = [
            app("kneecap-pro-ad", "Kneecap Pro Studio", updatedAt: "2026-09-27", sponsored: true, order: 0),
            app("kneecap-guide", "Kneecap Guide", updatedAt: "2026-09-26", featured: true, order: 1),
            app("kneecapper", "Kneecapper", updatedAt: "2026-09-25", order: 2),
            app("kneecap", "Kneecap", updatedAt: "2026-06-01", order: 3),
        ]
        let index = StoreCatalogIndex(source: base.source, apps: family, categories: base.categories, hiddenSlugs: [])
        let search = StoreSearchIndex(index: index)
        for typed in ["Kneecap", "kneecap", "KNEECAP", "kneecap ", " Kneecap"] {
            XCTAssertEqual(search.search(typed).slugs, ["kneecap-pro-ad", "kneecap-guide", "kneecapper", "kneecap"], "design 4.2: prefixes tie by updatedAt, query \(typed)")
        }
        // A fragment is not a whole name: every "Kneecap..." app is listed.
        XCTAssertEqual(Set(search.search("Knee").slugs), Set(family.map(\.slug)))
    }

    /// Sponsored apps keep their earned place: for every query, removing the
    /// sponsored flag from the whole catalog must not change the order.
    func testSponsoredAndFeaturedNeverChangeSearchOrder() async throws {
        for size in [100, 1000] {
            let index = try await StoreWorld.index(appCount: size)
            let sponsored = index.visibleApps.filter(\.isSponsored)
            XCTAssertFalse(sponsored.isEmpty, "the \(size)-app fixture must contain sponsored apps or this test proves nothing")
            let organic = StoreCatalogIndex(
                source: index.source,
                apps: index.allApps.map { app in
                    StoreApp(slug: app.slug, name: app.name, summary: app.summary, categoryIds: app.categoryIds, iconHash: app.iconHash,
                             iconURL: app.iconURL, byteCount: app.byteCount, ageRating: app.ageRating, updatedAt: app.updatedAt,
                             badges: app.badges, isFeatured: false, isSponsored: false, placementLabel: nil,
                             catalogOrder: app.catalogOrder, descriptor: app.descriptor)
                },
                categories: index.categories,
                hiddenSlugs: [])
            let paid = StoreSearchIndex(index: index), plain = StoreSearchIndex(index: organic)
            var comparedWithSponsoredPresent = 0
            for query in "abcdefghijklmnopqrstuvwxyz".map(String.init) + sponsored.map(\.name) + sponsored.map { String($0.summary.prefix(6)) } {
                let result = paid.search(query)
                XCTAssertEqual(result.slugs, plain.search(query).slugs, "\(size): query \"\(query)\" order depends on sponsorship")
                if result.apps.dropFirst().contains(where: \.isSponsored) { comparedWithSponsoredPresent += 1 }
            }
            XCTAssertGreaterThan(comparedWithSponsoredPresent, 5, "too few queries put a sponsored app below the top")
        }
    }

    /// SPEC R8.2 on the Mac proxy: build under 50 ms, each keystroke under
    /// 100 ms, at 1,000 apps. Worst of 3 rounds is what is asserted.
    func testIndexBuildAndPerKeystrokeSearchStayWithinBudgetAtAThousandApps() async throws {
        let index = try await StoreWorld.index(appCount: 1000)
        var build = 0.0
        var search: StoreSearchIndex!
        for _ in 0..<3 { build = max(build, storeMilliseconds { search = StoreSearchIndex(index: index) }) }
        var worstKeystroke = 0.0
        for name in index.visibleApps.prefix(25).map(\.name) + ["e", "board", "private offline"] {
            var typed = ""
            var previous: StoreSearchResult?
            for letter in name {
                typed.append(letter)
                worstKeystroke = max(worstKeystroke, storeMilliseconds { previous = search.search(typed, narrowing: previous) })
                worstKeystroke = max(worstKeystroke, storeMilliseconds { _ = search.search(typed) })
            }
        }
        print("STORE-SEARCH-TIMING apps=1000 build_ms=\(String(format: "%.2f", build)) worst_keystroke_ms=\(String(format: "%.2f", worstKeystroke))")
        XCTAssertLessThan(build, 50, "index build took \(build) ms")
        XCTAssertLessThan(worstKeystroke, 100, "a keystroke took \(worstKeystroke) ms")
    }

    /// Blocked apps are absent from results (design section 10).
    func testBlockedAppsNeverAppearInResults() async throws {
        let full = try await StoreWorld.index(appCount: 100)
        let blocked = Set(full.visibleApps.prefix(7).map(\.slug))
        let index = try await StoreWorld.index(appCount: 100, hiddenSlugs: blocked)
        let search = StoreSearchIndex(index: index)
        for app in full.visibleApps.prefix(7) {
            XCTAssertFalse(search.search(app.name).slugs.contains(app.slug))
            XCTAssertNotNil(index.app(slug: app.slug), "a link to a blocked app must still find its page")
        }
    }
}

/// The 120 ms pause (SPEC R8.2) seen from the screen: while a person types
/// faster than one key per 120 ms nothing on screen changes; once they pause,
/// the list shows exactly what the final text should find; and a slow search
/// for an older text can never replace a newer one. Simulated time; the
/// world misbehaves by returning search results late and out of order.
final class StoreSearchDebounceTests: XCTestCase {
    private struct Keystroke { let at: Int; let text: String }

    /// Runs one typing session and returns every change of what is on screen.
    private func run(
        _ keys: [Keystroke],
        search: StoreSearchIndex,
        latency: (Int) -> Int
    ) -> [(at: Int, display: StoreSearchDebounce.Display)] {
        var debounce = StoreSearchDebounce()
        var timers: [StoreSearchDebounce.Timer] = []
        var arrivals: [(at: Int, sequence: UInt64, query: String, slugs: [String])] = []
        var screen: [(Int, StoreSearchDebounce.Display)] = [(0, debounce.display)]
        var events: [(at: Int, kind: Int, index: Int)] = keys.enumerated().map { ($0.element.at, 0, $0.offset) }
        var searchCount = 0
        func record(_ at: Int) { if screen.last?.1 != debounce.display { screen.append((at, debounce.display)) } }
        while let next = events.min(by: { ($0.at, $0.kind) < ($1.at, $1.kind) }) {
            events.removeAll { $0.at == next.at && $0.kind == next.kind && $0.index == next.index }
            switch next.kind {
            case 0:
                if let timer = debounce.textChanged(keys[next.index].text, atMilliseconds: next.at) {
                    timers.append(timer)
                    events.append((timer.fireAtMilliseconds, 1, timers.count - 1))
                }
            case 1:
                if let run = debounce.timerFired(timers[next.index], atMilliseconds: next.at) {
                    let slugs = search.search(run.query).slugs
                    searchCount += 1
                    arrivals.append((next.at + latency(searchCount), run.sequence, run.query, slugs))
                    events.append((arrivals.last!.at, 2, arrivals.count - 1))
                }
            default:
                let arrival = arrivals[next.index]
                debounce.resultsArrived(sequence: arrival.sequence, query: arrival.query, slugs: arrival.slugs)
            }
            record(next.at)
        }
        return screen
    }

    func testAHurriedTypistSeesNoFlickerAndEndsOnTheRightResults() async throws {
        let index = try await StoreWorld.index(appCount: 1000)
        let search = StoreSearchIndex(index: index)
        var random = StoreSeededRandom(seed: 0x51DE)
        for run in 0..<36 {
            let target = index.visibleApps[Int(random.next() % 1000)].name
            var at = 0
            var keys: [Keystroke] = []
            var typed = ""
            for letter in target {
                at += 20 + Int(random.next() % 90) // 20 to 109 ms between keys: faster than the pause
                typed.append(letter)
                keys.append(Keystroke(at: at, text: typed))
            }
            let screen = self.run(keys, search: search, latency: { _ in Int(random.next() % 40) })
            let lastKey = keys.last!.at
            for change in screen.dropFirst() {
                XCTAssertGreaterThanOrEqual(change.at, lastKey + 120, "run \(run): the list changed at \(change.at) ms while typing (last key \(lastKey) ms)")
            }
            XCTAssertEqual(screen.last?.display, .results(query: typed, slugs: search.search(typed).slugs), "run \(run): wrong final list for \"\(typed)\"")
        }
    }

    /// Pauses mid-word show intermediate results, and a slow earlier search
    /// that lands after a later one never replaces it.
    func testASlowOlderSearchNeverReplacesANewerOne() async throws {
        let index = try await StoreWorld.index(appCount: 100)
        let search = StoreSearchIndex(index: index)
        let name = index.visibleApps[42].name
        let first = String(name.prefix(2))
        let keys = [Keystroke(at: 0, text: first), Keystroke(at: 200, text: name)]
        // The first search takes 900 ms, the second 10 ms.
        let screen = run(keys, search: search, latency: { $0 == 1 ? 900 : 10 })
        XCTAssertEqual(screen.last?.display, .results(query: name, slugs: search.search(name).slugs))
        XCTAssertFalse(screen.contains { $0.at > 330 && $0.display == .results(query: first, slugs: search.search(first).slugs) },
                       "the slow search for \"\(first)\" replaced the newer list")
    }

    func testClearingTheFieldShowsIdleAtOnceAndDropsPendingResults() async throws {
        let index = try await StoreWorld.index(appCount: 100)
        let search = StoreSearchIndex(index: index)
        let keys = [Keystroke(at: 0, text: "bri"), Keystroke(at: 500, text: "brig"), Keystroke(at: 700, text: "")]
        let screen = run(keys, search: search, latency: { _ in 300 })
        XCTAssertEqual(screen.map(\.at), [0, 420, 700], "bri shows at 420 ms, the cleared field shows idle at 700 ms, the late brig list never shows")
        XCTAssertEqual(screen.last?.display, .idle)
    }

    /// RC-06 (apple-compliance/REQUIRED_CHANGES.md, decided in DECISIONS.md):
    /// search is organic. A paid shelf placement changes neither which apps a
    /// search finds nor where they sit, so "Search results are never paid for"
    /// is true. Written from that promise, as what a person sees: the app that
    /// is sponsored on Home is found by its own name and by a word from its
    /// name, exactly as an unsponsored app of the same shape is. (Round 6 test
    /// audit: this test used to assert that a constant inside the index,
    /// `sponsoredBadgeShownInSearchResults`, was false. That pinned an
    /// implementation flag and would have stayed green if search stopped
    /// reading it. The tag itself is checked on screen in
    /// `StoreSearchUITests.testSearchResultsNeverCarryTheSponsoredTagEvenForASponsoredApp`.)
    func testASponsoredAppIsFoundByNameAndByWordLikeAnyOtherAndNotDropped() async throws {
        let base = try await StoreWorld.index(appCount: 100)
        let template = try XCTUnwrap(base.visibleApps.first)
        func app(_ slug: String, _ name: String, sponsored: Bool, order: Int) -> StoreApp {
            StoreApp(slug: slug, name: name, summary: "Plan your week on your phone.", categoryIds: template.categoryIds,
                     iconHash: template.iconHash, iconURL: template.iconURL, byteCount: template.byteCount,
                     ageRating: template.ageRating, updatedAt: "2026-09-20", badges: [], isFeatured: false,
                     isSponsored: sponsored, placementLabel: sponsored ? "Sponsored" : nil,
                     catalogOrder: order, descriptor: nil)
        }
        let apps = [
            app("paid-planner", "Weekly Planner", sponsored: true, order: 0),
            app("free-planner", "Daily Planner", sponsored: false, order: 1),
        ]
        let search = StoreSearchIndex(index: StoreCatalogIndex(source: base.source, apps: apps, categories: base.categories, hiddenSlugs: []))
        XCTAssertEqual(search.search("Weekly Planner").slugs, ["paid-planner"], "the sponsored app is found by its whole name")
        XCTAssertEqual(Set(search.search("Planner").slugs), ["paid-planner", "free-planner"], "a word from both names finds both, the paid one is not dropped")
        XCTAssertEqual(search.search("Daily Planner").slugs, ["free-planner"], "and the free one is not pushed out by the paid one")
    }
}
