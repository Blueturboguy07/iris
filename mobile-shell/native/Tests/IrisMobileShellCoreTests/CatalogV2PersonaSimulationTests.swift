import Foundation
import XCTest
@testable import IrisMobileShellCore

/// Seeded simulation of real people using Browse over many launches, with
/// the network faked at the transport boundary and misbehaving the way
/// phone networks and CDNs do. Three personas:
///
/// - a non-technical person who opens the app about once a day, is often
///   offline for a day or more, and looks at one or two apps;
/// - a hurried power user who relaunches every few minutes on a flaky
///   network while Publik publishes updates, and opens many app pages;
/// - an edge user whose device clock jumps, whose cache gets damaged, and
///   whose network sometimes redirects to a captive portal or cuts bodies.
///
/// Every launch is checked against invariants computed from the world
/// model and the fake server's own records, never from the loader's output
/// alone. Violations are grouped into a failure taxonomy in the failure
/// message.
final class CatalogV2PersonaSimulationTests: XCTestCase {
    override class func tearDown() {
        removeCatalogTestCaches()
        super.tearDown()
    }

    private enum Persona: String, CaseIterable {
        case nonTechnical = "non-technical daily user"
        case hurriedPowerUser = "hurried power user"
        case edgeUser = "edge user"
    }

    private enum Network: String {
        case good, slow, stalled, offline, truncated, serverError, captivePortal
        /// A CDN that has the new page 1 but still errors on the other pages.
        case cdnPartial

        /// App pages and page 1 load on this network.
        var servesPageOne: Bool { self == .good || self == .slow || self == .cdnPartial }
    }

    private struct Violation {
        let invariant: String
        let persona: Persona
        let seed: UInt64
        let launch: Int
        let detail: String
    }

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
        mutating func pick<T>(_ weighted: [(T, Double)]) -> T {
            var roll = unit() * weighted.reduce(0) { $0 + $1.1 }
            for (value, weight) in weighted {
                roll -= weight
                if roll <= 0 { return value }
            }
            return weighted[weighted.count - 1].0
        }
    }

    private struct PersonaPlan {
        let launches: Int
        let hoursBetween: ClosedRange<Double>
        let networks: [(Network, Double)]
        let appPagesPerLaunch: ClosedRange<Int>
        let publishChangeChance: Double
        let cacheDamageChance: Double
        let clockJumpBackChance: Double
    }

    private func plan(for persona: Persona) -> PersonaPlan {
        switch persona {
        case .nonTechnical:
            return PersonaPlan(
                launches: 10, hoursBetween: 18...60,
                networks: [(.good, 0.6), (.offline, 0.25), (.slow, 0.15)],
                appPagesPerLaunch: 0...2, publishChangeChance: 0.3, cacheDamageChance: 0, clockJumpBackChance: 0
            )
        case .hurriedPowerUser:
            return PersonaPlan(
                launches: 22, hoursBetween: 0.02...0.4,
                networks: [(.good, 0.4), (.slow, 0.15), (.serverError, 0.1), (.stalled, 0.1), (.truncated, 0.1), (.cdnPartial, 0.15)],
                appPagesPerLaunch: 4...12, publishChangeChance: 0.2, cacheDamageChance: 0, clockJumpBackChance: 0
            )
        case .edgeUser:
            return PersonaPlan(
                launches: 12, hoursBetween: 0.1...72,
                networks: [(.good, 0.35), (.offline, 0.2), (.captivePortal, 0.15), (.truncated, 0.15), (.cdnPartial, 0.15)],
                appPagesPerLaunch: 0...3, publishChangeChance: 0.25, cacheDamageChance: 0.2, clockJumpBackChance: 0.15
            )
        }
    }

    private func behavior(for network: Network) -> FakeServerBehavior {
        switch network {
        case .good, .cdnPartial: return .normal
        case .slow: return .slow(milliseconds: 3)
        case .stalled: return .stalled
        case .offline: return .offline
        case .truncated: return .truncated(keep: 700)
        case .serverError: return .status(503)
        case .captivePortal: return .redirected(to: URL(string: "https://captive.example/login")!)
        }
    }

    func testBrowseStaysCorrectForEveryPersonaAcrossSeededWorlds() async throws {
        let base = try CatalogPublish.fixture(1000)
        var violations: [Violation] = []
        var launches = 0
        for persona in Persona.allCases {
            for seed in UInt64(1)...5 {
                launches += try await runWorld(persona: persona, seed: seed, base: base) { violations.append($0) }
            }
        }
        print("catalog persona simulation: \(Persona.allCases.count * 5) worlds, \(launches) launches, \(violations.count) violations")
        if !violations.isEmpty {
            let taxonomy = Dictionary(grouping: violations, by: \.invariant)
                .sorted { $0.value.count > $1.value.count }
                .map { invariant, cases in
                    let examples = cases.prefix(3).map { "\($0.persona.rawValue) seed \($0.seed) launch \($0.launch): \($0.detail)" }
                    return "\(invariant): \(cases.count)\n    " + examples.joined(separator: "\n    ")
                }
            XCTFail("catalog persona simulation failures by invariant:\n" + taxonomy.joined(separator: "\n"))
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func runWorld(
        persona: Persona,
        seed: UInt64,
        base: CatalogPublish,
        report: (Violation) -> Void
    ) async throws -> Int {
        let plan = plan(for: persona)
        var rng = SplitMix64(state: seed &* 0x2545_F491_4F6C_DD1D &+ UInt64(Persona.allCases.firstIndex(of: persona)!))
        let server = FakePublikServer(publish: base)
        var publishes: [String: CatalogPublish] = [try base.generatedAt(): base]
        var current = base
        let clock = CatalogTestClock()
        let directory = try makeCatalogCacheDirectory("persona-\(persona)-\(seed)")
        let cache = PublikMobileCatalogCache(directory: directory)
        let client = PublikMobileCatalogClient(transport: server)
        let loader = PublikMobileCatalogV2Loader(client: client, cache: cache, now: clock.closure)

        // World model, kept independently of the loader.
        var lastConfirmedAt: Date?
        var lastLoadedGeneratedAt: String?
        var cacheMayBeDamaged = false
        var publishCounter = 0

        for launch in 1...plan.launches {
            func fail(_ invariant: String, _ detail: String) {
                report(Violation(invariant: invariant, persona: persona, seed: seed, launch: launch, detail: detail))
            }
            // Time passes; sometimes the device clock jumps back.
            if rng.unit() < plan.clockJumpBackChance {
                clock.advance(hours: -2)
            } else {
                clock.advance(hours: plan.hoursBetween.lowerBound + rng.unit() * (plan.hoursBetween.upperBound - plan.hoursBetween.lowerBound))
            }
            // Publik may have published a change since the last launch.
            if rng.unit() < plan.publishChangeChance {
                publishCounter += 1
                let slugs = try current.slugs()
                let edited = slugs[rng.int(0...(slugs.count - 1))]
                let stamp = String(format: "2026-10-%02dT%02d:00:00.000Z", 1 + publishCounter / 24, publishCounter % 24)
                current = try current.republished(editing: edited, summary: "Update \(publishCounter) for \(edited)", generatedAt: stamp)
                publishes[stamp] = current
                await server.setPublish(current)
            }
            // The edge user's cache gets damaged.
            if rng.unit() < plan.cacheDamageChance {
                let page = rng.int(1...4)
                try? await cache.write(key: "index-\(page)", body: Data("{\"version\":2,\"apps\":[{".utf8), etag: "\"stale\"", now: clock.now)
                cacheMayBeDamaged = true
            }

            // First paint: disk only.
            let firstPaint = await loader.cachedSnapshot()
            if let snapshot = firstPaint {
                if let source = publishes[snapshot.generatedAt] {
                    for page in snapshot.pages {
                        let expected = try source.indexPageJSON(page.page)
                        let expectedRows = (expected["apps"] as? [[String: Any]]) ?? []
                        if page.apps.map(\.slug) != expectedRows.compactMap({ $0["slug"] as? String })
                            || page.apps.map(\.summary) != expectedRows.compactMap({ $0["summary"] as? String }) {
                            fail("first paint shows rows that were never published together", "page \(page.page) of \(snapshot.generatedAt)")
                        }
                    }
                } else {
                    fail("first paint shows a catalog Publik never published", snapshot.generatedAt)
                }
                if snapshot.pages.contains(where: { $0.generatedAt != snapshot.generatedAt }) {
                    fail("first paint mixes two publishes", snapshot.generatedAt)
                }
                if let lastConfirmedAt, !cacheMayBeDamaged {
                    let expectedStale = clock.now.timeIntervalSince(lastConfirmedAt) > 24 * 3600
                    if snapshot.isStale != expectedStale {
                        fail("stale flag wrong", "isStale \(snapshot.isStale), last confirmed \(clock.now.timeIntervalSince(lastConfirmedAt) / 3600) h ago")
                    }
                }
            } else if lastLoadedGeneratedAt != nil, !cacheMayBeDamaged {
                fail("blank first paint after a successful load", "cache lost page 1")
            }

            // Refresh over this launch's network.
            let network = rng.pick(plan.networks)
            await server.clearBehaviors()
            await server.setDefaultBehavior(behavior(for: network))
            if network == .cdnPartial {
                for page in 2...4 {
                    await server.setBehavior(.status(503), forPath: CatalogPublish.indexPath(page))
                }
            }
            let mark = await server.logCount
            let publishUnchanged = lastLoadedGeneratedAt == (try current.generatedAt()) && !cacheMayBeDamaged
            var refreshed: PublikMobileCatalogV2Snapshot?
            if network == .stalled {
                let task = Task { try await loader.refresh() }
                try await Task.sleep(nanoseconds: 20_000_000)
                task.cancel()
                if (try? await task.value) != nil { fail("stalled refresh reported success", "") }
            } else {
                do {
                    let result = try await loader.refresh()
                    guard case .catalog(let snapshot) = result else {
                        fail("fell back to v1 while index v2 is published", "\(network)")
                        continue
                    }
                    refreshed = snapshot
                    // A partial CDN can only succeed when page 1 is unchanged
                    // and the other pages are already cached.
                    if !(network == .good || network == .slow || (network == .cdnPartial && publishUnchanged)) {
                        fail("refresh succeeded on a broken network", network.rawValue)
                    }
                } catch {
                    if network == .good || network == .slow || (network == .cdnPartial && publishUnchanged) {
                        fail("refresh failed on a working network", "\(network): \(error)")
                    }
                }
            }
            if network == .cdnPartial, refreshed == nil {
                // Page 1 itself arrived intact and was cached; only later pages failed.
                lastConfirmedAt = clock.now
            }
            let indexRequests = await server.indexRequests(since: mark)
            if let snapshot = refreshed {
                let expected = try current.appRows()
                if snapshot.generatedAt != (try current.generatedAt())
                    || snapshot.apps.map(\.slug) != expected.compactMap({ $0["slug"] as? String })
                    || snapshot.apps.map(\.summary) != expected.compactMap({ $0["summary"] as? String }) {
                    fail("refresh did not end on Publik's current publish", snapshot.generatedAt)
                }
                if publishUnchanged, indexRequests.count != 1 {
                    fail("more than one index request for an unchanged catalog", "\(indexRequests.count) requests: \(indexRequests.map(\.path))")
                }
                if indexRequests.count > 4 {
                    fail("more index requests than pages", "\(indexRequests.count)")
                }
                lastConfirmedAt = clock.now
                lastLoadedGeneratedAt = snapshot.generatedAt
                cacheMayBeDamaged = false
            }

            // Look at a few apps.
            let rows = (refreshed ?? firstPaint)?.apps ?? []
            if !rows.isEmpty, network != .stalled {
                for _ in 0..<rng.int(plan.appPagesPerLaunch) {
                    let row = rows[rng.int(0...(rows.count - 1))]
                    do {
                        let page = try await client.fetchAppPage(slug: row.slug, cache: cache, now: clock.now).value
                        let raw = try JSONSerialization.jsonObject(with: current.files[CatalogPublish.appPagePath(row.slug)] ?? Data()) as? [String: Any]
                        if page.description != raw?["description"] as? String {
                            fail("app page differs from the published page", row.slug)
                        }
                        if !network.servesPageOne {
                            fail("app page loaded on a broken network", network.rawValue)
                        }
                    } catch {
                        if network.servesPageOne {
                            fail("app page failed on a working network", "\(row.slug): \(error)")
                        }
                    }
                }
            }

            // Every request stayed on the allowlisted origin and shape.
            for request in await server.requests(since: mark) {
                if request.url.host != "publikhq.com" || request.url.scheme != "https" || request.method != "GET" || request.acceptEncoding != "identity" {
                    fail("request outside the allowlist", request.url.absoluteString)
                }
            }
            let used = allocatedBytesOnDisk(under: directory)
            if used > PublikMobileCatalogCache.maximumJSONCacheBytes {
                fail("cache over 4 MB on disk", "\(used) bytes")
            }
        }
        return plan.launches
    }
}
