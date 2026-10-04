import Foundation
import XCTest
@testable import IrisMobileShellCore

/// The real URLSession-backed transport (not the fake) carrying a catalog
/// conditional GET: a URLProtocol stands in for publikhq.com so the
/// delegate's status, ETag and redirect handling run for real.
final class CatalogV2URLSessionTransportTests: XCTestCase {
    override func tearDown() {
        CatalogConditionalURLProtocol.reset()
        super.tearDown()
    }

    private func transport() -> PublikMobileURLSessionTransport {
        PublikMobileURLSessionTransport { configuration in
            configuration.protocolClasses = [CatalogConditionalURLProtocol.self]
        }
    }

    func testRealTransportRevalidatesAnIndexPageWithItsETag() async throws {
        let body = try XCTUnwrap(try CatalogPublish.fixture(100).files[CatalogPublish.indexPath(1)])
        CatalogConditionalURLProtocol.serve(body, etag: "\"v1-index\"", at: CatalogPublish.indexPath(1))
        let client = PublikMobileCatalogClient(transport: transport())
        let cache = PublikMobileCatalogCache(directory: try makeCatalogCacheDirectory())

        let first = try await client.fetchIndexPage(1, cache: cache)
        XCTAssertFalse(first.notModified)
        XCTAssertEqual(first.etag, "\"v1-index\"")
        XCTAssertEqual(first.value.apps.count, 100)

        let second = try await client.fetchIndexPage(1, cache: cache)
        XCTAssertTrue(second.notModified)
        XCTAssertEqual(second.value, first.value)
        XCTAssertEqual(CatalogConditionalURLProtocol.seenIfNoneMatch(), [nil, "\"v1-index\""])
        XCTAssertEqual(CatalogConditionalURLProtocol.seenAcceptEncoding(), ["identity", "identity"])
    }

    func testRealTransportRefusesA304ThatWasNeverAskedFor() async throws {
        CatalogConditionalURLProtocol.serve(Data("{}".utf8), etag: "\"x\"", at: CatalogPublish.indexPath(1), alwaysNotModified: true)
        var request = URLRequest(url: URL(string: "https://publikhq.com" + CatalogPublish.indexPath(1))!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            _ = try await transport().get(request, maximumBytes: 1024, progress: nil)
            XCTFail("an unconditional request must not accept 304")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .redirectRejected)
        }
        // With the header, the same 304 is a valid answer carrying the ETag.
        request.setValue("\"x\"", forHTTPHeaderField: "If-None-Match")
        let response = try await transport().get(request, maximumBytes: 1024, progress: nil)
        XCTAssertEqual(response.statusCode, 304)
        XCTAssertEqual(response.etag, "\"x\"")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testRealTransportMapsAnUnpublishedIndexToTheV1Fallback() async throws {
        CatalogConditionalURLProtocol.serve(nil, etag: nil, at: CatalogPublish.indexPath(1))
        let client = PublikMobileCatalogClient(transport: transport())
        await assertCatalogError(.catalogIndexV2Unavailable) { _ = try await client.fetchIndexPage(1, cache: nil) }
        await assertCatalogError(.unexpectedStatus(404)) { _ = try await client.fetchIndexPage(2, cache: nil) }
    }
}

final class CatalogConditionalURLProtocol: URLProtocol {
    private struct Entry {
        let body: Data?
        let etag: String?
        let alwaysNotModified: Bool
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: Entry] = [:]
        var ifNoneMatch: [String?] = []
        var acceptEncoding: [String?] = []
    }

    private static let state = State()

    static func serve(_ body: Data?, etag: String?, at path: String, alwaysNotModified: Bool = false) {
        state.lock.lock()
        state.entries[path] = Entry(body: body, etag: etag, alwaysNotModified: alwaysNotModified)
        state.lock.unlock()
    }

    static func reset() {
        state.lock.lock()
        state.entries = [:]
        state.ifNoneMatch = []
        state.acceptEncoding = []
        state.lock.unlock()
    }

    static func seenIfNoneMatch() -> [String?] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.ifNoneMatch
    }

    static func seenAcceptEncoding() -> [String?] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.acceptEncoding
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "publikhq.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let conditional = request.value(forHTTPHeaderField: "If-None-Match")
        Self.state.lock.lock()
        Self.state.ifNoneMatch.append(conditional)
        Self.state.acceptEncoding.append(request.value(forHTTPHeaderField: "Accept-Encoding"))
        let entry = Self.state.entries[url.path]
        Self.state.lock.unlock()

        guard let entry, let body = entry.body else {
            let notFound = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Content-Length": "0"])!
            client.urlProtocol(self, didReceive: notFound, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let etag = entry.etag { headers["ETag"] = etag }
        if entry.alwaysNotModified || (conditional != nil && conditional == entry.etag) {
            headers["Content-Length"] = "0"
            let notModified = HTTPURLResponse(url: url, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: notModified, cacheStoragePolicy: .notAllowed)
            client.urlProtocolDidFinishLoading(self)
            return
        }
        headers["Content-Length"] = String(body.count)
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
