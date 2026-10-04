import Foundation
import XCTest
@testable import IrisMobileShellCore

/// SPEC R8 acceptance: persona P1 reaches and starts installing a named app
/// within 4 taps from launch, at 3, 100 and 1,000 apps. Two oracles, both
/// moving only through the real navigation reducer and the real list of
/// controls on each screen (the same layout and search the views render):
/// - a breadth-first walk that finds the fewest taps for every app (design
///   section 11: 1 tap at 3 apps, 2 taps at 100 and 1,000 apps);
/// - P1 herself: taps the first thing that looks right, types a few letters,
///   reads only the top 5 results, gives up after typing the whole name.
final class StoreNavigationTapBudgetTests: XCTestCase {
    private struct Node: Hashable {
        let state: StoreNavigationState
        let query: String
    }

    /// Slugs whose Get button is on screen.
    private func gets(_ screen: StoreScreen, _ node: Node) -> Set<String> {
        Set(screen.targets(for: node.state, query: node.query).compactMap {
            if case .get(let slug) = $0 { return slug }
            return nil
        })
    }

    private func children(_ screen: StoreScreen, _ node: Node) -> [Node] {
        screen.targets(for: node.state, query: node.query).compactMap { target in
            guard let action = StoreScreen.action(for: target) else { return nil }
            var next = node.state
            next.apply(action)
            return Node(state: next, query: next.tab == .search && next.searchPath.isEmpty ? node.query : "")
        }
    }

    /// Typing costs no taps, but only works in a focused Search field.
    private func canType(_ node: Node) -> Bool {
        node.state.tab == .search && node.state.searchFieldFocused && node.state.searchPath.isEmpty
    }

    /// Fewest taps from launch to tapping `slug`'s Get, typing the app's name
    /// letter by letter where a focused field allows it. nil when not found
    /// within `limit` taps.
    private func fewestTaps(to app: StoreApp, screen: StoreScreen, levels: inout [[Node]], getCache: inout [Node: Set<String>], limit: Int) -> Int? {
        for taps in 1...limit {
            if levels.count < taps {
                var seen = Set(levels.flatMap { $0 })
                var next: [Node] = []
                for node in levels[taps - 2] where !(canType(node)) {
                    for child in children(screen, node) where seen.insert(child).inserted { next.append(child) }
                }
                levels.append(next)
            }
            for node in levels[taps - 1] {
                if canType(node) {
                    // Every prefix of the name; the list scrolls, so any match counts.
                    var typed = ""
                    for letter in app.name {
                        typed.append(letter)
                        if screen.search.search(typed).slugs.contains(app.slug) { return taps }
                    }
                    continue
                }
                if getCache[node] == nil { getCache[node] = gets(screen, node) }
                if getCache[node]!.contains(app.slug) { return taps }
            }
        }
        return nil
    }

    func testFewestTapsToGetEveryAppMatchesTheDesignTable() async throws {
        for size in StoreWorld.sizes {
            let index = try await StoreWorld.index(appCount: size)
            let screen = StoreScreen(index: index)
            var levels: [[Node]] = [[Node(state: StoreNavigationState(), query: "")]]
            var cache: [Node: Set<String>] = [:]
            var worst = 0
            for app in index.visibleApps {
                let taps = fewestTaps(to: app, screen: screen, levels: &levels, getCache: &cache, limit: 4)
                XCTAssertNotNil(taps, "\(size): \(app.name) cannot be reached in 4 taps")
                worst = max(worst, taps ?? 99)
            }
            let designWorst = size < 13 ? 1 : 2 // design 3.2 and 11
            print("STORE-TAP-BUDGET apps=\(size) worst_fewest_taps=\(worst)")
            XCTAssertLessThanOrEqual(worst, designWorst, "\(size) apps: design section 11 allows \(designWorst) taps, the store needs \(worst)")
        }
    }

    /// P1, simulated: a non-technical person who knows the app's name.
    func testNonTechnicalPersonInstallsANamedAppWithinFourTaps() async throws {
        for size in StoreWorld.sizes {
            let index = try await StoreWorld.index(appCount: size)
            let screen = StoreScreen(index: index)
            var random = StoreSeededRandom(seed: 0xA11CE &+ UInt64(size))
            var gaveUp: [String] = []
            var worstTaps = 0, worstKeys = 0, totalKeys = 0, runs = 0
            let targets = size <= 100 ? index.visibleApps : (0..<150).map { _ in index.visibleApps[Int(random.next() % 1000)] }
            for app in targets {
                runs += 1
                var state = StoreNavigationState()
                var taps = 0, keys = 0
                var done = false
                // First screen: is the app right there? (Home shows at most a
                // screenful before a person would scroll; P1 does not scroll.)
                let firstScreen = screen.home.prefix(3).flatMap(\.cards).prefix(12).map(\.slug)
                if firstScreen.contains(app.slug) {
                    taps += 1
                    done = true
                } else {
                    // Taps the big "Search apps" field.
                    state.apply(.tapSearchEntry)
                    taps += 1
                    if !state.searchFieldFocused { state.apply(.searchFieldFocus(true)); taps += 1 }
                    var typed = ""
                    // P1 types lowercase, one letter at a time, reading the top 5.
                    for letter in app.name.lowercased() {
                        typed.append(letter)
                        keys += 1
                        if typed.count < 2 { continue }
                        let top = screen.targets(for: state, query: typed).compactMap { target -> String? in
                            if case .get(let slug) = target { return slug }
                            return nil
                        }.prefix(5)
                        if top.contains(app.slug) {
                            taps += 1
                            done = true
                            break
                        }
                    }
                }
                if !done { gaveUp.append(app.name) }
                worstTaps = max(worstTaps, taps)
                worstKeys = max(worstKeys, keys)
                totalKeys += keys
            }
            print("STORE-P1 apps=\(size) runs=\(runs) gave_up=\(gaveUp.count) worst_taps=\(worstTaps) worst_keystrokes=\(worstKeys) mean_keystrokes=\(String(format: "%.1f", Double(totalKeys) / Double(max(1, runs))))")
            XCTAssertTrue(gaveUp.isEmpty, "\(size) apps: P1 gave up on \(gaveUp.prefix(5))")
            XCTAssertLessThanOrEqual(worstTaps, 4, "SPEC R8: 4 taps or fewer")
            // Design section 11: the search entry opens Search with the
            // keyboard up, so P1's own path is 2 taps (1 when the app is on
            // the first screen of a small catalog).
            XCTAssertLessThanOrEqual(worstTaps, size < 13 ? 1 : 2, "\(size) apps: P1 needed \(worstTaps) taps")
        }
    }

    /// Design 9.5: a link lands on the app page (one tap from Get), cold or
    /// warm, from any tab and any depth, and never installs by itself.
    func testLinksLandOnTheAppPageFromAnywhere() async throws {
        let index = try await StoreWorld.index(appCount: 100, hiddenSlugs: ["bright-board"])
        let screen = StoreScreen(index: index)
        var random = StoreSeededRandom(seed: 9)
        for app in index.allApps {
            var state = StoreNavigationState()
            // Wander first: a warm start from somewhere deep.
            for _ in 0..<Int(random.next() % 5) {
                let targets = screen.targets(for: state, query: "")
                if let action = StoreScreen.action(for: targets[Int(random.next() % UInt64(targets.count))]) { state.apply(action) }
            }
            state.apply(.openLink(slug: app.slug))
            XCTAssertEqual(state.tab, .browse)
            XCTAssertEqual(state.browsePath, [.app(slug: app.slug)])
            XCTAssertEqual(screen.targets(for: state, query: "").filter { if case .get = $0 { return true }; return false }, [.get(slug: app.slug)])
        }
    }

    /// P2 switches tabs mid-task and expects to come back where they were.
    func testSwitchingTabsKeepsEachTabsPlace() {
        var state = StoreNavigationState()
        state.apply(.push(.category(id: 3)))
        state.apply(.push(.app(slug: "a")))
        state.apply(.tapSearchEntry)
        state.apply(.push(.app(slug: "b")))
        state.apply(.selectTab(.myApps))
        state.apply(.selectTab(.browse))
        XCTAssertEqual(state.browsePath, [.category(id: 3), .app(slug: "a")])
        state.apply(.selectTab(.search))
        XCTAssertEqual(state.searchPath, [.app(slug: "b")])
        XCTAssertFalse(state.searchFieldFocused, "the keyboard must not cover a pushed page")
        state.apply(.selectTab(.search))
        XCTAssertEqual(state.searchPath, [], "tapping the selected tab returns to its top")
        XCTAssertTrue(state.searchFieldFocused)
        state.apply(.appClosed)
        XCTAssertEqual(state.tab, .myApps)
    }
}
