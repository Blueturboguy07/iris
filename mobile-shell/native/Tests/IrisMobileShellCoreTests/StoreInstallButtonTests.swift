import Foundation
import XCTest
@testable import IrisMobileShellCore

/// The Get button (design section 6.2, SPEC R8.5).
/// - The state graph is walked independently from every combination of
///   facts, and every edge is checked against the design table written out
///   below (not against the reducer's own code).
/// - One-tap Get runs the real install path: the store's pipeline drives the
///   real `NativeWebsiteInstallFlow` and the real library coordinator on a
///   temporary folder, talking to the fake Publik server. The server's own
///   request log and the library on disk are the oracles.
final class StoreInstallButtonTests: XCTestCase {
    // MARK: state graph

    private typealias Kind = StoreInstallButtonState.Kind

    private static let events: [StoreInstallEvent] = [
        .tap, .cancelTap, .downloadProgress(percent: nil), .downloadProgress(percent: 42), .downloadProgress(percent: 7),
        .verifying, .finished(revisionId: "rev-new"), .failed(message: "The download could not be verified. Nothing was installed."),
        .unsupported(reason: "Needs the camera, which this iPhone can't do yet."), .cancelled, .backOnline,
    ]

    private static func allFacts() -> [StoreInstallFacts] {
        var out: [StoreInstallFacts] = []
        let listings: [StoreInstallFacts.Listing] = [.notYetChecked, .listed(revisionId: "rev-new", baseRevisionId: "rev-old"), .unavailable(reason: "Not published for iPhone yet.")]
        let restrictions: [StoreInstallFacts.Restriction] = [
            .none, .blocked,
            .age(rating: 18, message: "This app is rated 18+.", canCheckAge: false),
            .age(rating: 18, message: "This app is rated 18+.", canCheckAge: true),
        ]
        for listing in listings {
            for installed in [nil, "rev-new", "rev-old"] as [String?] {
                for restriction in restrictions {
                    for online in [true, false] {
                        for needs in [nil, 40_000_000] as [Int64?] {
                            out.append(StoreInstallFacts(appName: "Swift Mail", listing: listing, installedRevisionId: installed,
                                                         restriction: restriction, isOnline: online, updateNeedsBytes: needs))
                        }
                    }
                }
            }
        }
        return out
    }

    /// The design table, as this test reads it: what a tap may do per label.
    private static func allowedTapEffect(_ kind: Kind, facts: StoreInstallFacts, anotherRunning: Bool) -> StoreInstallEffect {
        switch kind {
        case .get, .failed:
            return facts.isOnline && !anotherRunning ? .startInstall : .none
        case .update:
            return facts.isOnline && !anotherRunning && facts.updateNeedsBytes == nil ? .startInstall : .none
        case .downloading, .verifying, .unavailable: return .none
        case .open: return .open
        case .blocked: return .unblock
        case .restricted:
            if case .age(_, _, true) = facts.restriction { return .checkAge }
            return .none
        }
    }

    /// MOBILE_STORE_DESIGN.md 6.2: expected states come from input facts,
    /// not from the state the implementation chose to display. This table
    /// catches swapped Get/Open/Update states that a graph walk can miss.
    func testIdleStatesMatchTheIndependentSpecTable() {
        let listed = StoreInstallFacts.Listing.listed(revisionId: "new", baseRevisionId: "old")
        let cases: [(String, StoreInstallFacts, StoreInstallButtonState.Kind)] = [
            ("not installed", StoreInstallFacts(appName: "Notes", listing: listed), .get),
            ("current installed", StoreInstallFacts(appName: "Notes", listing: listed, installedRevisionId: "new"), .open),
            ("older installed", StoreInstallFacts(appName: "Notes", listing: listed, installedRevisionId: "old"), .update),
            ("unpublished", StoreInstallFacts(appName: "Notes", listing: .unavailable(reason: "Not published for iPhone yet.")), .unavailable),
            ("blocked", StoreInstallFacts(appName: "Notes", listing: listed, restriction: .blocked), .blocked),
            ("age restricted", StoreInstallFacts(appName: "Notes", listing: listed, restriction: .age(rating: 18, message: "Rated 18+", canCheckAge: true)), .restricted),
        ]
        for (scenario, facts, expected) in cases {
            let observed = StoreInstallMachine.state(facts: facts, activity: .idle).kind
            XCTAssertEqual(observed, expected, "design 6.2: \(scenario)")
        }
    }

    func testEveryReachableStateFollowsTheDesignTableAndHasAWayOut() {
        var reachedKinds = Set<Kind>()
        var edges = 0
        for facts in Self.allFacts() {
            for anotherRunning in [false, true] {
                var queue: [StoreInstallActivity] = [.idle]
                var seen: Set<String> = ["\(StoreInstallActivity.idle)"]
                while let activity = queue.popLast() {
                    let shown = StoreInstallMachine.state(facts: facts, activity: activity)
                    reachedKinds.insert(shown.kind)
                    XCTAssertFalse(shown.label.isEmpty)
                    if let note = shown.note { XCTAssertTrue(shown.accessibilityValue.contains(note), "VoiceOver must hear the note line") }
                    // Busy states always have an exit: finishing, failing or cancelling.
                    if shown.isBusy {
                        let exits = [StoreInstallEvent.finished(revisionId: "rev-new"), .failed(message: "x"), .cancelled].map {
                            StoreInstallMachine.state(facts: facts, activity: StoreInstallMachine.reduce(activity: activity, event: $0, facts: facts, anotherInstallRunning: anotherRunning).0).isBusy
                        }
                        XCTAssertTrue(exits.allSatisfy { !$0 }, "\(activity) has no way out")
                    }
                    for event in Self.events {
                        edges += 1
                        let (next, effect) = StoreInstallMachine.reduce(activity: activity, event: event, facts: facts, anotherInstallRunning: anotherRunning)
                        let after = StoreInstallMachine.state(facts: facts, activity: next)
                        switch event {
                        case .tap:
                            XCTAssertEqual(effect, Self.allowedTapEffect(shown.kind, facts: facts, anotherRunning: anotherRunning),
                                           "tap on \(shown.kind) with \(facts), another running \(anotherRunning)")
                            if shown.isBusy { XCTAssertEqual(after, shown, "a tap during progress must change nothing on screen") }
                            if effect == .startInstall { XCTAssertEqual(after.kind, .downloading, "Get must turn into progress in place") }
                            if effect == .none, [.get, .update, .failed].contains(shown.kind) {
                                XCTAssertNotNil(after.note, "a Get that cannot start must say why (\(facts))")
                            }
                        case .cancelTap:
                            XCTAssertEqual(effect, shown.kind == .downloading ? .cancelInstall : .none)
                        default:
                            XCTAssertEqual(effect, .none, "only taps cause effects")
                        }
                        let key = "\(next)"
                        if seen.insert(key).inserted { queue.append(next) }
                    }
                }
            }
        }
        XCTAssertEqual(reachedKinds, Set(Kind.allCases), "every label in the design table must be reachable")
        XCTAssertGreaterThan(edges, 3_000, "the walk must cover the whole graph")
    }

    /// Progress never runs backwards and a finished install reads Open even
    /// before the library list catches up.
    func testProgressOnlyMovesForwardAndFinishingShowsOpen() {
        let facts = StoreInstallFacts(appName: "Swift Mail", listing: .notYetChecked)
        var activity = StoreInstallActivity.idle
        var effect: StoreInstallEffect
        (activity, effect) = StoreInstallMachine.reduce(activity: activity, event: .tap, facts: facts, anotherInstallRunning: false)
        XCTAssertEqual(effect, .startInstall)
        var shown: [Int] = []
        for percent in [10, 40, 25, 90, 60] {
            (activity, _) = StoreInstallMachine.reduce(activity: activity, event: .downloadProgress(percent: percent), facts: facts, anotherInstallRunning: false)
            shown.append(StoreInstallMachine.state(facts: facts, activity: activity).percent ?? -1)
        }
        XCTAssertEqual(shown, [10, 40, 40, 90, 90])
        (activity, _) = StoreInstallMachine.reduce(activity: activity, event: .finished(revisionId: "r1"), facts: facts, anotherInstallRunning: false)
        XCTAssertEqual(StoreInstallMachine.state(facts: facts, activity: activity).kind, .open)
        XCTAssertEqual(StoreInstallMachine.reduce(activity: activity, event: .tap, facts: facts, anotherInstallRunning: false).1, .open)
    }

    /// Same guarantee for an UPDATE (the app was already on an older
    /// revision), which is the case `testProgressOnlyMovesForwardAndFinishingShowsOpen`
    /// does not cover (it only starts from `.notYetChecked` / no installed
    /// revision). In real use the Host's `installedRevisionId` comes from a
    /// separately refreshed library list and can still read the OLD revision
    /// for a moment after `.finished` fires. The button must still read Open,
    /// and a tap in that exact window must never start a second install.
    func testUpdateFinishingShowsOpenEvenWhileFactsStillNameTheOldRevision() {
        let listed = StoreInstallFacts(
            appName: "Swift Mail",
            listing: .listed(revisionId: "r2", baseRevisionId: "r1"),
            installedRevisionId: "r1")
        var activity = StoreInstallActivity.idle
        var effect: StoreInstallEffect
        (activity, effect) = StoreInstallMachine.reduce(activity: activity, event: .tap, facts: listed, anotherInstallRunning: false)
        XCTAssertEqual(effect, .startInstall)
        (activity, _) = StoreInstallMachine.reduce(activity: activity, event: .finished(revisionId: "r2"), facts: listed, anotherInstallRunning: false)
        // `listed.installedRevisionId` is still "r1": the library list has not
        // caught up yet. The button must still read Open, not Update.
        let shownState = StoreInstallMachine.state(facts: listed, activity: activity)
        XCTAssertEqual(shownState.kind, .open, "showed \(shownState.kind) instead of Open right after an update finished, while facts still named the old revision")
        let (_, tapEffect) = StoreInstallMachine.reduce(activity: activity, event: .tap, facts: listed, anotherInstallRunning: false)
        XCTAssertEqual(tapEffect, .open, "a tap right after an update finished (before facts caught up) returned \(tapEffect) instead of .open, which would start a second install of the same app")
    }

    // MARK: one-tap Get through the real install path

    private struct Phone {
        let server: FakePublikServer
        let coordinator: NativeShellLibraryCoordinator
        let controller: StoreInstallController
        let root: URL
        let publish: CatalogPublish
    }

    /// Everything the fixture packages ask for, except `native.haptics`, so
    /// Vivid Journal is the app this phone cannot run.
    private static let policy = CapabilityPolicy(
        supportedCapabilities: ["web.storage", "web.media.export", "web.network.same-origin", "web.navigation.external", "native.share"],
        grantedNativeCapabilities: ["native.share"])

    private func makePhone(_ label: String = #function) async throws -> Phone {
        let publish = try StoreWorld.installablePublish()
        let server = FakePublikServer(publish: publish)
        let root = try makeStoreLibraryRoot(label)
        let coordinator = NativeShellLibraryCoordinator(rootURL: root, capabilityPolicy: Self.policy)
        let client = PublikMobileCatalogClient(transport: server)
        let pipeline = StoreFlowInstallPipeline(makeFlow: {
            NativeWebsiteInstallFlow(coordinator: coordinator, catalogClient: client, capabilityPolicy: Self.policy)
        })
        return Phone(server: server, coordinator: coordinator, controller: StoreInstallController(pipeline: pipeline), root: root, publish: publish)
    }

    private func packageRequests(_ phone: Phone, _ slug: String) async -> Int {
        await phone.server.log.filter { $0.path == CatalogPublish.packagePath(slug) }.count
    }

    private func pageRevision(_ phone: Phone, _ slug: String) throws -> String {
        let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(phone.publish.files[CatalogPublish.appPagePath(slug)])) as? [String: Any])
        return try XCTUnwrap((page["mobileShell"] as? [String: Any])?["revisionId"] as? String)
    }

    private func installedRevisions(_ phone: Phone) async throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for entry in try await phone.coordinator.refreshLibrary() {
            out[entry.identity.appId] = entry.revisions.map(\.revisionId)
        }
        return out
    }

    private func facts(_ name: String, online: Bool = true) -> StoreInstallFacts {
        StoreInstallFacts(appName: name, listing: .notYetChecked, isOnline: online)
    }

    /// P2 double taps (and sometimes triple taps) Get with human gaps while
    /// the package is still arriving. Exactly one download, one install.
    func testHurriedDoubleTapInstallsExactlyOnceAcrossSeededRuns() async throws {
        var random = StoreSeededRandom(seed: 0xD0B1E)
        for run in 0..<12 {
            let phone = try await makePhone("double-tap-\(run)")
            let slug = "swift-mail"
            await phone.server.setBehavior(.slow(milliseconds: 60 + random.next() % 120), forPath: CatalogPublish.packagePath(slug))
            let taps = 2 + Int(random.next() % 3)
            var effects: [StoreInstallEffect] = []
            for _ in 0..<taps {
                effects.append(await phone.controller.handle(.tap, slug: slug, facts: facts("Swift Mail")))
                try await Task.sleep(nanoseconds: (random.next() % 50) * 1_000_000)
            }
            await phone.controller.waitUntilIdle()
            let requests = await packageRequests(phone, slug)
            XCTAssertEqual(requests, 1, "run \(run): \(taps) taps made \(requests) package downloads")
            XCTAssertEqual(effects.filter { $0 == .startInstall }.count, 1)
            let installed = try await installedRevisions(phone)
            XCTAssertEqual(installed["publik.swift-mail"], [try pageRevision(phone, slug)], "run \(run): library is not exactly one install")
            XCTAssertEqual(installed.count, 1)
            let activity = await phone.controller.activity(for: slug)
            XCTAssertEqual(StoreInstallMachine.state(facts: facts("Swift Mail"), activity: activity).kind, .open)
            // Another tap now opens; it does not download again.
            let effect = await phone.controller.handle(.tap, slug: slug, facts: facts("Swift Mail"))
            XCTAssertEqual(effect, .open)
            await phone.controller.waitUntilIdle()
            let after = await packageRequests(phone, slug)
            XCTAssertEqual(after, 1)
            try? FileManager.default.removeItem(at: phone.root)
        }
    }

    /// A tap on a second app while the first is installing says so and does
    /// not start; after the first finishes the second installs normally.
    func testASecondAppWaitsForTheFirstInsteadOfRacingIt() async throws {
        let phone = try await makePhone()
        await phone.server.setBehavior(.slow(milliseconds: 150), forPath: CatalogPublish.packagePath("swift-mail"))
        let first = await phone.controller.handle(.tap, slug: "swift-mail", facts: facts("Swift Mail"))
        let second = await phone.controller.handle(.tap, slug: "quick-recipes", facts: facts("Quick Recipes"))
        XCTAssertEqual(first, .startInstall)
        XCTAssertEqual(second, .none)
        let secondState = StoreInstallMachine.state(facts: facts("Quick Recipes"), activity: await phone.controller.activity(for: "quick-recipes"))
        XCTAssertEqual(secondState.note, "Another app is still installing. Try again when it finishes.")
        await phone.controller.waitUntilIdle()
        let quickBefore = await packageRequests(phone, "quick-recipes")
        XCTAssertEqual(quickBefore, 0)
        let retry = await phone.controller.handle(.tap, slug: "quick-recipes", facts: facts("Quick Recipes"))
        XCTAssertEqual(retry, .startInstall)
        await phone.controller.waitUntilIdle()
        let installed = try await installedRevisions(phone)
        XCTAssertEqual(Set(installed.keys), ["publik.swift-mail", "publik.quick-recipes"])
        try? FileManager.default.removeItem(at: phone.root)
    }

    /// P3 in airplane mode: a tap writes one line and sends nothing; the
    /// connection drops mid-download: nothing is installed and Try again works.
    func testOfflineTapAndADroppedDownloadLeaveNothingHalfInstalled() async throws {
        let phone = try await makePhone()
        let offline = await phone.controller.handle(.tap, slug: "swift-mail", facts: facts("Swift Mail", online: false))
        XCTAssertEqual(offline, .none)
        let offlineState = StoreInstallMachine.state(facts: facts("Swift Mail", online: false), activity: await phone.controller.activity(for: "swift-mail"))
        XCTAssertEqual(offlineState.note, "Connect to the internet to get Swift Mail.")
        let silent = await phone.server.log.count
        XCTAssertEqual(silent, 0, "an offline tap must not touch the network")
        await phone.controller.handle(.backOnline, slug: "swift-mail", facts: facts("Swift Mail"))
        let backOnline = await phone.controller.activity(for: "swift-mail")
        XCTAssertNil(StoreInstallMachine.state(facts: facts("Swift Mail"), activity: backOnline).note)

        await phone.server.setBehavior(.offline, forPath: CatalogPublish.packagePath("swift-mail"))
        await phone.controller.handle(.tap, slug: "swift-mail", facts: facts("Swift Mail"))
        await phone.controller.waitUntilIdle()
        let failed = StoreInstallMachine.state(facts: facts("Swift Mail"), activity: await phone.controller.activity(for: "swift-mail"))
        XCTAssertEqual(failed.kind, .failed)
        XCTAssertEqual(failed.label, "Try again")
        XCTAssertEqual(failed.note, "The download stopped. Check your connection and try again. Nothing was installed.")
        let afterFailure = try await installedRevisions(phone)
        XCTAssertTrue(afterFailure.isEmpty, "a dropped download installed something")

        await phone.server.clearBehaviors()
        let again = await phone.controller.handle(.tap, slug: "swift-mail", facts: facts("Swift Mail"))
        XCTAssertEqual(again, .startInstall)
        await phone.controller.waitUntilIdle()
        let installed = try await installedRevisions(phone)
        XCTAssertEqual(installed["publik.swift-mail"]?.count, 1)
        try? FileManager.default.removeItem(at: phone.root)
    }

    /// An app that needs something this iPhone cannot give turns Unavailable
    /// with the reason, and nothing is installed (design 6.3, last item).
    func testAnAppThisPhoneCannotRunIsUnavailableAndNotInstalled() async throws {
        let phone = try await makePhone()
        await phone.controller.handle(.tap, slug: "vivid-journal", facts: facts("Vivid Journal"))
        await phone.controller.waitUntilIdle()
        let state = StoreInstallMachine.state(facts: facts("Vivid Journal"), activity: await phone.controller.activity(for: "vivid-journal"))
        XCTAssertEqual(state.kind, .unavailable)
        XCTAssertEqual(state.note, "This app needs a phone feature, which Iris on this iPhone can't offer yet.")
        let tapAgain = await phone.controller.handle(.tap, slug: "vivid-journal", facts: facts("Vivid Journal"))
        XCTAssertEqual(tapAgain, .none)
        let installed = try await installedRevisions(phone)
        XCTAssertNil(installed["publik.vivid-journal"])
        try? FileManager.default.removeItem(at: phone.root)
    }

    /// Cancel during a slow download returns to Get with nothing installed.
    func testCancelDuringDownloadReturnsToGetWithNothingInstalled() async throws {
        let phone = try await makePhone()
        await phone.server.setBehavior(.slow(milliseconds: 400), forPath: CatalogPublish.packagePath("quick-recipes"))
        await phone.controller.handle(.tap, slug: "quick-recipes", facts: facts("Quick Recipes"))
        try await Task.sleep(nanoseconds: 100_000_000)
        let effect = await phone.controller.handle(.cancelTap, slug: "quick-recipes", facts: facts("Quick Recipes"))
        XCTAssertEqual(effect, .cancelInstall)
        await phone.controller.waitUntilIdle()
        let state = StoreInstallMachine.state(facts: facts("Quick Recipes"), activity: await phone.controller.activity(for: "quick-recipes"))
        XCTAssertEqual(state.kind, .get, "cancel must return to Get, got \(state)")
        let installed = try await installedRevisions(phone)
        XCTAssertTrue(installed.isEmpty)
        try? FileManager.default.removeItem(at: phone.root)
    }
}
