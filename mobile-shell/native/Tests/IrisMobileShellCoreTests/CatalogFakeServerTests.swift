import Foundation
import XCTest
@testable import IrisMobileShellCore

// Test support for the catalog v2 suites: the checked-in fixture publishes
// (written by mobile-shell/tools/catalog-fixture-generator from its
// documented seed) and a fake Publik server that serves them. The fake
// stands in only for the network boundary: it answers GET requests the way
// publikhq.com would (ETags, 304s, 404s) and can misbehave on purpose
// (truncated bodies, slow or stalled responses, redirects to another host,
// wrong content types, server errors). Its request log is the oracle the
// tests read; the client under test never sees it.

enum CatalogFixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/catalog-v2", isDirectory: true)
}

/// One published catalog, as the files a web server would hold, keyed by
/// URL path on publikhq.com.
struct CatalogPublish: Sendable {
    var files: [String: Data]
    let appCount: Int

    static let indexPrefix = "/api/iris/mobile/"

    static func indexPath(_ page: Int) -> String {
        page == 1 ? "\(indexPrefix)index.json" : "\(indexPrefix)index-\(page).json"
    }

    static func appPagePath(_ slug: String) -> String { "\(indexPrefix)apps/\(slug).json" }
    static func packagePath(_ slug: String) -> String { "/api/iris/mobile-shell/\(slug)/pkg.json" }
    static func iconPath(_ slug: String) -> String { "/i/\(slug).png" }
    static let categoriesPath = "\(indexPrefix)categories.json"
    static let legacyCatalogPath = "/api/iris/apps"

    static func fixture(_ appCount: Int) throws -> CatalogPublish {
        let directory = CatalogFixtures.root.appendingPathComponent(String(appCount), isDirectory: true)
        let fileManager = FileManager.default
        var files: [String: Data] = [:]
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) {
            let url = directory.appendingPathComponent(name)
            if name == "index.json" || (name.hasPrefix("index-") && name.hasSuffix(".json")) || name == "categories.json" {
                files[indexPrefix + name] = try Data(contentsOf: url)
            }
        }
        for (subdirectory, mapPath) in [
            ("apps", { (name: String) in CatalogPublish.appPagePath(String(name.dropLast(".json".count))) }),
            ("packages", { (name: String) in CatalogPublish.packagePath(String(name.dropLast(".irisapp".count))) }),
            ("icons", { (name: String) in CatalogPublish.iconPath(String(name.dropLast(".png".count))) }),
        ] as [(String, (String) -> String)] {
            let path = directory.appendingPathComponent(subdirectory, isDirectory: true).path
            guard fileManager.fileExists(atPath: path) else { continue }
            for name in try fileManager.contentsOfDirectory(atPath: path) {
                files[mapPath(name)] = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name))
            }
        }
        return CatalogPublish(files: files, appCount: appCount)
    }

    /// The raw JSON object of an index page, straight from the served bytes
    /// (parsed with JSONSerialization, not the client's decoder).
    func indexPageJSON(_ page: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(files[Self.indexPath(page)], "index page \(page) is not published")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func pageCount() throws -> Int {
        try XCTUnwrap(try indexPageJSON(1)["pageCount"] as? Int)
    }

    /// Every app row across all pages, in page order, as raw JSON objects.
    func appRows() throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for page in 1...(try pageCount()) {
            rows += try XCTUnwrap(try indexPageJSON(page)["apps"] as? [[String: Any]])
        }
        return rows
    }

    func slugs() throws -> [String] {
        try appRows().map { try XCTUnwrap($0["slug"] as? String) }
    }

    func generatedAt() throws -> String {
        try XCTUnwrap(try indexPageJSON(1)["generatedAt"] as? String)
    }

    /// A new publish of the same catalog: one app's summary edited and every
    /// page stamped with a new generatedAt, re-serialized. What the
    /// publisher emits when an author changes one app.
    func republished(editing slug: String, summary: String, generatedAt: String) throws -> CatalogPublish {
        var next = self
        for page in 1...(try pageCount()) {
            var json = try indexPageJSON(page)
            json["generatedAt"] = generatedAt
            var apps = try XCTUnwrap(json["apps"] as? [[String: Any]])
            for index in apps.indices where apps[index]["slug"] as? String == slug {
                apps[index]["summary"] = summary
            }
            json["apps"] = apps
            next.files[Self.indexPath(page)] = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        return next
    }

    /// The same apps served only through the v1 route (no index v2 files).
    func legacyOnly() throws -> CatalogPublish {
        var rows: [[String: Any]] = []
        for row in try appRows() {
            let slug = try XCTUnwrap(row["slug"] as? String)
            let page = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(files[Self.appPagePath(slug)])) as? [String: Any])
            rows.append(["slug": slug, "name": row["name"] as Any, "mobileShell": page["mobileShell"] as Any])
        }
        var next = CatalogPublish(files: [:], appCount: appCount)
        for (path, data) in files where !path.hasPrefix(Self.indexPrefix) {
            next.files[path] = data
        }
        next.files[Self.legacyCatalogPath] = try JSONSerialization.data(withJSONObject: ["apps": rows], options: [.sortedKeys])
        return next
    }
}

/// How the fake server misbehaves for a request.
enum FakeServerBehavior: Sendable, Equatable {
    case normal
    /// Always answers 200 with the full body, never 304.
    case ignoresConditionalRequests
    case status(Int)
    /// Declares the full Content-Length but delivers only the first `keep` bytes.
    case truncated(keep: Int)
    case slow(milliseconds: UInt64)
    /// Never answers until the request is cancelled.
    case stalled
    /// The response ends up at a different URL (a redirect the transport followed).
    case redirected(to: URL)
    case contentType(String)
    case body(Data)
    /// The transport fails outright (no connectivity).
    case offline
}

actor FakePublikServer: PublikMobileHTTPTransport {
    struct LoggedRequest: Sendable {
        let url: URL
        let method: String?
        let ifNoneMatch: String?
        let acceptEncoding: String?
        let maximumBytes: Int
        var completed = false
        var status: Int?

        var path: String { url.path }
        var isIndexRequest: Bool { path.hasPrefix(CatalogPublish.indexPrefix + "index") }
    }

    private(set) var publish: CatalogPublish
    private var behaviorByPath: [String: FakeServerBehavior] = [:]
    private var defaultBehavior: FakeServerBehavior = .normal
    private(set) var log: [LoggedRequest] = []

    init(publish: CatalogPublish) {
        self.publish = publish
    }

    func setPublish(_ publish: CatalogPublish) { self.publish = publish }
    func setBehavior(_ behavior: FakeServerBehavior, forPath path: String) { behaviorByPath[path] = behavior }
    func setDefaultBehavior(_ behavior: FakeServerBehavior) { defaultBehavior = behavior }
    func clearBehaviors() {
        behaviorByPath = [:]
        defaultBehavior = .normal
    }
    func clearLog() { log = [] }
    func setFile(_ data: Data?, atPath path: String) { publish.files[path] = data }

    static func etag(for data: Data) -> String {
        "\"\(NativeSecurity.sha256(data).dropFirst("sha256:".count).prefix(20))\""
    }

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        let url = try XCTUnwrap(request.url)
        let index = log.count
        log.append(LoggedRequest(
            url: url,
            method: request.httpMethod,
            ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"),
            acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding"),
            maximumBytes: maximumBytes
        ))
        let behavior = behaviorByPath[url.path] ?? defaultBehavior
        let response = try await respond(to: request, url: url, behavior: behavior)
        log[index].completed = true
        log[index].status = response.statusCode
        return response
    }

    private func respond(to request: URLRequest, url: URL, behavior: FakeServerBehavior) async throws -> PublikMobileHTTPResponse {
        switch behavior {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .stalled:
            while true {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        case .slow(let milliseconds):
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
            return ordinaryResponse(to: request, url: url, honorConditional: true)
        case .status(let code):
            return PublikMobileHTTPResponse(statusCode: code, mimeType: "text/plain", declaredContentLength: 0, finalURL: url, body: Data())
        case .truncated(let keep):
            let full = ordinaryResponse(to: request, url: url, honorConditional: false)
            return PublikMobileHTTPResponse(
                statusCode: full.statusCode,
                mimeType: full.mimeType,
                declaredContentLength: full.body.count,
                finalURL: url,
                body: full.body.prefix(keep),
                etag: full.etag
            )
        case .redirected(let target):
            let full = ordinaryResponse(to: request, url: url, honorConditional: false)
            return PublikMobileHTTPResponse(statusCode: 200, mimeType: full.mimeType, declaredContentLength: full.body.count, finalURL: target, body: full.body, etag: full.etag)
        case .contentType(let mime):
            let full = ordinaryResponse(to: request, url: url, honorConditional: false)
            return PublikMobileHTTPResponse(statusCode: full.statusCode, mimeType: mime, declaredContentLength: full.body.count, finalURL: url, body: full.body, etag: full.etag)
        case .body(let data):
            return PublikMobileHTTPResponse(statusCode: 200, mimeType: Self.mimeType(for: url.path), declaredContentLength: data.count, finalURL: url, body: data, etag: Self.etag(for: data))
        case .ignoresConditionalRequests:
            return ordinaryResponse(to: request, url: url, honorConditional: false)
        case .normal:
            return ordinaryResponse(to: request, url: url, honorConditional: true)
        }
    }

    private func ordinaryResponse(to request: URLRequest, url: URL, honorConditional: Bool) -> PublikMobileHTTPResponse {
        guard url.host == "publikhq.com", let data = publish.files[url.path] else {
            return PublikMobileHTTPResponse(statusCode: 404, mimeType: "text/plain", declaredContentLength: 0, finalURL: url, body: Data())
        }
        let etag = Self.etag(for: data)
        if honorConditional, request.value(forHTTPHeaderField: "If-None-Match") == etag {
            return PublikMobileHTTPResponse(statusCode: 304, mimeType: nil, declaredContentLength: 0, finalURL: url, body: Data(), etag: etag)
        }
        return PublikMobileHTTPResponse(statusCode: 200, mimeType: Self.mimeType(for: url.path), declaredContentLength: data.count, finalURL: url, body: data, etag: etag)
    }

    private static func mimeType(for path: String) -> String {
        path.hasSuffix(".png") ? "image/png" : "application/json"
    }

    // MARK: oracle helpers

    func indexRequests(since start: Int = 0) -> [LoggedRequest] {
        log.dropFirst(start).filter(\.isIndexRequest)
    }

    func requests(since start: Int = 0) -> [LoggedRequest] { Array(log.dropFirst(start)) }

    var logCount: Int { log.count }
}

/// Parent of every cache directory these suites create.
let catalogTestCacheRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("catalog-v2-tests", isDirectory: true)

/// Removes cache directories left by earlier catalog test runs (only ever
/// this suite's own temporary folders).
func removeCatalogTestCaches() {
    try? FileManager.default.removeItem(at: catalogTestCacheRoot)
}

/// A fresh, empty cache directory for one simulated device.
func makeCatalogCacheDirectory(_ label: String = #function) throws -> URL {
    let directory = catalogTestCacheRoot
        .appendingPathComponent("\(label.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Disk space used under `directory`, summed from every regular file's
/// allocated blocks (`st_blocks * 512`), walking subdirectories too.
func allocatedBytesOnDisk(under directory: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
    var total = 0
    for case let url as URL in enumerator {
        var status = stat()
        if stat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG {
            total += Int(status.st_blocks) * 512
        }
    }
    return total
}

/// A controllable clock for the 24 hour stale window.
final class CatalogTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(hours: Double) {
        lock.lock()
        current = current.addingTimeInterval(hours * 3600)
        lock.unlock()
    }

    var closure: @Sendable () -> Date { { [self] in self.now } }
}

final class CatalogFakeServerTests: XCTestCase {
    /// The fake must behave like a real conditional-GET server, or every
    /// ETag test built on it proves nothing: same bytes, same ETag, 304 only
    /// for a matching If-None-Match, 404 for anything unpublished or foreign.
    func testFakeServerAnswersConditionalRequestsLikeAnHTTPServer() async throws {
        let publish = try CatalogPublish.fixture(3)
        let server = FakePublikServer(publish: publish)
        let url = URL(string: "https://publikhq.com" + CatalogPublish.indexPath(1))!
        var request = URLRequest(url: url)
        let first = try await server.get(request, maximumBytes: 1 << 20, progress: nil)
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.body, publish.files[CatalogPublish.indexPath(1)])
        let etag = try XCTUnwrap(first.etag)

        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let second = try await server.get(request, maximumBytes: 1 << 20, progress: nil)
        XCTAssertEqual(second.statusCode, 304)
        XCTAssertTrue(second.body.isEmpty)

        request.setValue("\"something-else\"", forHTTPHeaderField: "If-None-Match")
        let third = try await server.get(request, maximumBytes: 1 << 20, progress: nil)
        XCTAssertEqual(third.statusCode, 200)

        let foreign = try await server.get(URLRequest(url: URL(string: "https://publikhq.com.evil.example" + CatalogPublish.indexPath(1))!), maximumBytes: 1 << 20, progress: nil)
        XCTAssertEqual(foreign.statusCode, 404)
        let log = await server.log
        XCTAssertEqual(log.count, 4)
        XCTAssertEqual(log[1].ifNoneMatch, etag)
    }

    /// The fixture publishes the other suites rely on must be the sizes the
    /// generator documents, with installable packages in the 3-app set.
    func testCheckedInFixturePublishesHaveTheDocumentedShape() throws {
        for (count, pages) in [(3, 1), (100, 1), (1000, 4)] {
            let publish = try CatalogPublish.fixture(count)
            XCTAssertEqual(try publish.pageCount(), pages, "\(count)-app publish")
            let slugs = try publish.slugs()
            XCTAssertEqual(slugs.count, count)
            XCTAssertEqual(Set(slugs).count, count)
            for slug in slugs {
                XCTAssertNotNil(publish.files[CatalogPublish.appPagePath(slug)], "\(count): no app page for \(slug)")
            }
        }
        let small = try CatalogPublish.fixture(3)
        for slug in try small.slugs() {
            XCTAssertNotNil(small.files[CatalogPublish.packagePath(slug)], "no package for \(slug)")
            XCTAssertNotNil(small.files[CatalogPublish.iconPath(slug)], "no icon for \(slug)")
        }
    }
}
