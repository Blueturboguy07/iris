import Foundation
import IrisMobileShellCore

// Unit M-store-screens (round3-deferred), seed catalog lane.
//
// Seed from real evidence: the owner's iPhone, 2026-09-28 09:45, "There are
// no mobile apps to browse." publikhq.com answered 404 for
// /api/iris/mobile/index.json (and index-2.json, categories.json,
// apps/<slug>.json); only /api/iris/apps existed, and it lists Mac apps.
//
// World: a fresh install (empty catalog cache, the cache-wiped case), with
// publikhq.com exactly as the owner found it, in one of three seeded
// conditions: reachable (404 plus the Mac list), airplane mode, or a flaky
// connection that drops half the requests. Only the network boundary is
// faked (`PublikTodayTransport`); the store's production feed
// (`StoreCatalogFeed.withBundledSeed`, the same factory StoreModel uses),
// client, parser and status line run unchanged.
//
// Oracles, none taken from the seed code: the apps a person expects to see
// are the starters Iris itself installs (`NativeStarterCatalog`), and their
// installed revisions are read from the starter package files that ship in
// the app. A person must see all of them in Browse, read a calm line that
// explains the short list (no error words, no "nothing here"), and see Open
// on each installed one. The hurried persona opens an app page at once; the
// edge persona later sees publikhq.com publish the website copy and must
// then get the real catalog instead of the seed.

public final class StoreSeedCatalogScenario: MobileScenario {
    public let id = "store-seed-catalog-publik-404"
    public let title = "Publik has no mobile catalog (404, airplane mode, cache wiped): Browse still shows the apps that came with Iris"
    public let seedString = "store-seed-catalog-publik-404"
    public let personas: [MobilePersona] = MobileBuiltInPersonas.all

    struct Starter {
        let displayName: String
        let appId: String
        let revisionId: String
    }

    private let starters: [Starter]
    private let websiteCopy: [String: Data]

    static let nativeRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // this file -> Scenarios
        .deletingLastPathComponent() // -> MobileUserSimKit
        .deletingLastPathComponent() // -> Sources
        .deletingLastPathComponent() // -> iris-mobile-user-sim
        .deletingLastPathComponent() // -> Tools
        .deletingLastPathComponent() // -> mobile-shell/native
    static let websiteCopyRoot: URL = nativeRoot
        .deletingLastPathComponent().deletingLastPathComponent() // mobile-shell, repo
        .appendingPathComponent("docs/plans/20260928-all-routes/round3-deferred/M-store-screens/website-catalog-v2/api/iris/mobile", isDirectory: true)

    public init(scratchRoot: URL) throws {
        let starterRoot = Self.nativeRoot.appendingPathComponent("IrisMobileShellApp/Resources/Starter", isDirectory: true)
        starters = try NativeStarterCatalog.entries.map { entry in
            guard let last = entry.orderedFileNames.last else { throw OracleFailure("starter-chain", "\(entry.label) has no files", failureClass: .setupPackaging) }
            let bytes = try Data(contentsOf: starterRoot.appendingPathComponent(entry.label).appendingPathComponent(last))
            guard let package = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let envelope = package["envelope"] as? [String: Any],
                  let appId = envelope["appId"] as? String,
                  let revisionId = envelope["revisionId"] as? String else {
                throw OracleFailure("starter-package", "\(entry.label)/\(last) is not a delivery package", failureClass: .setupPackaging)
            }
            return Starter(displayName: entry.displayName, appId: appId, revisionId: revisionId)
        }
        var copy: [String: Data] = [:]
        let root = Self.websiteCopyRoot
        // `root` may be reached through a symlink (the gate script's scratch
        // copy symlinks `docs` back to the real tree). FileManager's
        // enumerator resolves that symlink in the URLs it returns, so
        // stripping the unresolved `root.path` prefix silently fails and
        // leaves every key as a garbage absolute path (websiteCopy is then
        // non-empty but never matches a real request). Resolve `root` the
        // same way before computing the prefix; a no-op when there is no
        // symlink, so the real tree is unaffected either way.
        let rootPrefix = root.resolvingSymlinksInPath().path
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let relative = file.path.replacingOccurrences(of: rootPrefix + "/", with: "")
                copy["/api/iris/mobile/" + relative] = try Data(contentsOf: file)
            }
        }
        websiteCopy = copy
    }

    enum Condition: String, CaseIterable {
        case reachable404 = "publik reachable, index 404, Mac-only v1 list"
        case airplaneMode = "airplane mode"
        case flaky = "flaky connection (half the requests drop)"
    }

    public func run(env: RunEnvironment, persona: MobilePersona, rng: inout SeededGenerator) async throws -> ScenarioOutcome {
        let conditions = Condition.allCases
        let condition = conditions[Int(rng.nextUnitDouble() * Double(conditions.count)) % conditions.count]
        switch condition {
        case .reachable404: env.world.setNetwork(.healthy)
        case .airplaneMode: env.world.setNetwork(.offline)
        case .flaky: env.world.setNetwork(.flaky(failureRate: 0.5))
        }
        let transport = PublikTodayTransport(world: env.world)
        let client = PublikMobileCatalogClient(transport: transport)
        // Fresh install, cache wiped: an empty catalog cache folder.
        let cache = PublikMobileCatalogCache(directory: env.rootURL.appendingPathComponent("catalog-cache-\(UUID().uuidString)", isDirectory: true))
        let feed = StoreCatalogFeed.withBundledSeed(client: client, cache: cache)

        // Launch: paint before any answer, then the one check.
        guard let painted = await feed.cached() else {
            throw OracleFailure("first-paint", "a fresh install painted nothing before the first check (\(condition.rawValue))", failureClass: .hostSide)
        }
        let result = await feed.refresh(lastChecked: nil)
        let onScreen = result.load ?? painted.load
        let freshness = result.freshness
        let index = onScreen.index(hiddenSlugs: [])
        let shownNames = Set(index.visibleApps.map(\.name))

        // 1. Browse is not empty: every app that came with Iris is there.
        let expected = Set(starters.map(\.displayName))
        try Oracle.require(expected.isSubset(of: shownNames), "starters-visible",
                           "Browse showed \(shownNames.sorted()) under \(condition.rawValue); expected \(expected.sorted())", failureClass: .hostSide)
        try Oracle.require(!StoreShelves.home(index).isEmpty, "home-not-empty", "Home had no sections", failureClass: .hostSide)

        // 2. One calm, plain line explains the short list.
        let line = StoreStatusLine.text(freshness, hasRows: !index.visibleApps.isEmpty, showingBundledSeed: onScreen.isBundledSeed)
        let lower = line.lowercased()
        let jargon = ["error", "404", "exception", "failed", "http", "index", "catalog"]
        try Oracle.require(!line.isEmpty && !jargon.contains { lower.contains($0) }, "status-line-plain", "status line: \(line)", failureClass: .hostSide)
        try Oracle.require(!lower.contains("no apps") && !lower.contains("hasn't loaded"), "status-line-not-empty-state",
                           "the line describes an empty store while apps are shown: \(line)", failureClass: .hostSide)
        try Oracle.require(lower.contains("iris"), "status-line-explains-why", "the line does not say where these apps come from: \(line)", failureClass: .hostSide)

        // 3. Every starter is installed (Iris sets them up at first launch):
        //    each row offers Open, never a download that cannot succeed.
        for starter in starters {
            guard let app = index.visibleApps.first(where: { $0.name == starter.displayName }) else { continue }
            guard let descriptor = app.descriptor else {
                throw OracleFailure("seed-row-descriptor", "\(app.name) has no install descriptor, so Browse cannot tell it is installed", failureClass: .hostSide)
            }
            let listing = onScreen.isBundledSeed
                ? StoreCatalogSeed.listing(for: descriptor, installedRevisionId: starter.revisionId)
                : .listed(revisionId: descriptor.revisionId, baseRevisionId: descriptor.baseRevisionId)
            let state = StoreInstallMachine.state(
                facts: StoreInstallFacts(appName: app.name, listing: listing, installedRevisionId: starter.revisionId, restriction: .none, isOnline: condition != .airplaneMode),
                activity: .idle)
            try Oracle.requireEqual(state.label, "Open", "installed-\(starter.appId)-opens", failureClass: .hostSide)
        }

        // 4. The hurried persona taps into an app page straight away.
        var lastMessage = line
        if persona.doubleTaps, let first = index.visibleApps.first {
            do {
                let page = try await feed.appPage(slug: first.slug)
                try Oracle.require(!page.description.isEmpty, "page-has-words", "\(first.name)'s page is blank", failureClass: .hostSide)
                lastMessage = page.description
            } catch {
                throw OracleFailure("page-opens", "\(first.name)'s page did not open under \(condition.rawValue): \(error)", failureClass: .hostSide)
            }
        }

        // 5. The edge persona comes back after the owner uploads the website
        //    copy: the real catalog replaces the seed.
        if persona.id == MobileBuiltInPersonas.p3EdgeUser.id {
            try Oracle.require(!websiteCopy.isEmpty, "website-copy-exists", "no website copy at \(Self.websiteCopyRoot.path)", failureClass: .setupPackaging)
            env.world.setNetwork(.healthy)
            transport.publish(websiteCopy)
            let later = await feed.refresh(lastChecked: nil)
            guard let real = later.load else {
                throw OracleFailure("real-catalog-loads", "after the upload the check still failed (\(later.freshness))", failureClass: .hostSide)
            }
            try Oracle.require(!real.isBundledSeed, "real-catalog-wins", "the seed stayed on screen after publikhq.com published a catalog", failureClass: .hostSide)
            try Oracle.requireEqual(Set(real.index(hiddenSlugs: []).visibleApps.map(\.name)), expected, "real-catalog-lists-starters", failureClass: .hostSide)
            let realLine = StoreStatusLine.text(later.freshness, hasRows: true, showingBundledSeed: real.isBundledSeed)
            try Oracle.require(realLine.hasPrefix("Checked"), "real-catalog-line", "after the upload the line read: \(realLine)", failureClass: .hostSide)
            lastMessage = realLine
        }

        return ScenarioOutcome(
            passed: true,
            message: "\(condition.rawValue): Browse showed \(shownNames.count) apps with \"\(line)\".",
            personaInterview: PersonaInterview(didFinish: true, lastHonestMessage: lastMessage, knewWhatToDoNext: true),
            evidence: ["condition": condition.rawValue, "shown": shownNames.sorted().joined(separator: ", "), "statusLine": line,
                       "requests": String(transport.requestCount())]
        )
    }
}

/// publikhq.com as the owner's phone found it on 2026-09-28: every mobile
/// catalog URL answers 404 and /api/iris/apps lists Mac apps only (the slugs
/// with Mac marketplace artwork in this repo). Offline and flaky behavior
/// come from the persona's device world. `publish(_:)` models the owner
/// uploading the website copy later.
final class PublikTodayTransport: PublikMobileHTTPTransport, @unchecked Sendable {
    private let world: DeviceWorld
    private let lock = NSLock()
    private var files: [String: Data]
    private var requests = 0

    static let macOnlyList = Data(#"{"apps":[{"latestReleaseTag":"v1.4.0","macBundleId":"com.publik.cue","name":"Cue","slug":"cue"},{"macBundleId":"com.publik.simplicity","name":"Simplicity","slug":"simplicity"},{"macBundleId":"com.publik.plantgpt","name":"PlantGPT","slug":"plantgpt"},{"macBundleId":"com.publik.freeharmony","name":"FreeHarmony","slug":"freeharmony"},{"macBundleId":"com.publik.nut-ai","name":"Nut AI","slug":"nut-ai"}]}"#.utf8)

    init(world: DeviceWorld) {
        self.world = world
        files = ["/api/iris/apps": Self.macOnlyList]
    }

    func publish(_ more: [String: Data]) {
        lock.lock(); defer { lock.unlock() }
        for (path, data) in more { files[path] = data }
    }

    func requestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    private func body(for path: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        return files[path]
    }

    func get(_ request: URLRequest, maximumBytes: Int, progress: (@Sendable (Int) -> Void)?) async throws -> PublikMobileHTTPResponse {
        guard let url = request.url else { throw URLError(.badURL) }
        switch world.decideNetworkOutcome() {
        case .fail(.offline):
            world.record("network-request-failed", "offline: \(url.absoluteString)")
            throw URLError(.notConnectedToInternet)
        case .fail(.flakyDrop):
            world.record("network-request-failed", "flaky drop: \(url.absoluteString)")
            throw URLError(.networkConnectionLost)
        case .proceed:
            break
        }
        guard url.host == "publikhq.com", let data = body(for: url.path) else {
            world.record("network-request-served", "404 \(url.absoluteString)")
            return PublikMobileHTTPResponse(statusCode: 404, mimeType: "text/html", declaredContentLength: 0, finalURL: url, body: Data())
        }
        world.record("network-request-served", url.absoluteString)
        return PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: url.pathExtension == "png" ? "image/png" : "application/json",
            declaredContentLength: data.count,
            finalURL: url,
            body: data
        )
    }
}
