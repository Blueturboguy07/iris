import Foundation
import Testing
#if canImport(IrisUsability)
@testable import IrisUsability
#else
@testable import Iris
#endif

struct CatalogAppIconTests {
    @Test func everyCuratedAssetIsValidatedAndUnknownAppsUseAFallback() {
        #expect(CatalogAppIconPolicy.verifiedAssets.count == 4)
        for slug in CatalogAppIconPolicy.verifiedAssets.keys {
            #expect(CatalogAppIconPolicy.verifiedIconURL(forSlug: slug) != nil)
        }
        #expect(CatalogAppIconPolicy.verifiedIconURL(forSlug: "not-in-catalog") == nil)
        #expect(CatalogAppIconPolicy.fallbackInitial(for: "  Astro ") == "A")
        #expect(CatalogAppIconPolicy.fallbackInitial(for: " \n ") == "?")
    }

    @Test func imageURLsRejectCredentialsLocalHostsRedirectTricksAndUnsupportedFormats() {
        for candidate in [
            "http://publikhq.com/icon.png", "https://publikhq.com.attacker.test/icon.png",
            "https://user:secret@publikhq.com/icon.png", "file:///tmp/icon.png",
            "https://127.0.0.1/icon.png", "https://localhost/icon.png",
            "https://publikhq.com:8443/icon.png", "https://publikhq.com/icon.png?token=value",
            "https://publikhq.com/icon.svg", "https://publikhq.com/../icon.png",
            "https://publikhq.com/%2E%2E/icon.png", "https://publikhq.com/icon.png#fragment",
        ] {
            #expect(CatalogAppIconPolicy.validatedPublicIconURL(candidate) == nil)
        }
    }

    @Test func onlySuccessfulBoundedPngResponsesAreAccepted() {
        #expect(CatalogAppIconPolicy.acceptsResponse(statusCode: 200, mimeType: "image/png", expectedBytes: -1))
        #expect(!CatalogAppIconPolicy.acceptsResponse(statusCode: 404, mimeType: "image/png", expectedBytes: 64))
        #expect(!CatalogAppIconPolicy.acceptsResponse(statusCode: 200, mimeType: "text/html", expectedBytes: 64))
        #expect(!CatalogAppIconPolicy.acceptsResponse(statusCode: 200, mimeType: nil, expectedBytes: 64))
        #expect(!CatalogAppIconPolicy.acceptsResponse(statusCode: 200, mimeType: "image/png",
            expectedBytes: Int64(CatalogAppIconPolicy.maximumImageBytes + 1)))
    }

    @Test func chunkedBodyCannotExceedTheByteLimitOrCorruptAccumulatedData() {
        var buffer = CatalogIconByteBuffer()
        let acceptedFirstChunk = buffer.append(Data(repeating: 1, count: CatalogAppIconPolicy.maximumImageBytes - 1))
        #expect(acceptedFirstChunk)
        let acceptedOversizedChunk = buffer.append(Data([2, 3]))
        #expect(!acceptedOversizedChunk)
        #expect(buffer.data.count == CatalogAppIconPolicy.maximumImageBytes - 1)
        let acceptedLastByte = buffer.append(Data([4]))
        #expect(acceptedLastByte)
        let acceptedExtraByte = buffer.append(Data([5]))
        #expect(!acceptedExtraByte)
        #expect(buffer.data.last == 4)
    }

    @Test func simultaneousRowsShareOneDownloadAndReuseItsCachedResult() async throws {
        let fixture = IconDownloadFixture()
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        let url = try #require(CatalogAppIconPolicy.verifiedIconURL(forSlug: "astro"))
        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<10 { group.addTask { await loader.imageData(for: url) } }
            var results: [Data?] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == 10 && results.allSatisfy { $0 == Data([1, 2, 3]) })
        #expect(await loader.imageData(for: url) == Data([1, 2, 3]))
        #expect(await fixture.requestCount == 1)
    }

    @Test func downloadsStayWithinGlobalConcurrencyLimit() async throws {
        let fixture = IconDownloadFixture()
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        let urls = CatalogAppIconPolicy.verifiedAssets.values.compactMap(URL.init(string:))
        await withTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { _ = await loader.imageData(for: url) } }
            await group.waitForAll()
        }
        #expect(await fixture.requestCount == 4)
        #expect(await fixture.peakRequests == CatalogAppIconPolicy.maximumConcurrentDownloads)
    }

    @Test func failuresAndOversizedResultsAreCachedWithoutRetryStorms() async throws {
        let fixture = IconDownloadFixture(result: Data(repeating: 0, count: CatalogAppIconPolicy.maximumImageBytes + 1))
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        let url = try #require(CatalogAppIconPolicy.verifiedIconURL(forSlug: "astro"))
        #expect(await loader.imageData(for: url) == nil)
        #expect(await loader.imageData(for: url) == nil)
        #expect(await fixture.requestCount == 1)
        let failedFixture = IconDownloadFixture(result: nil)
        let failedLoader = CatalogAppIconLoader(fetch: { await failedFixture.download($0) })
        #expect(await failedLoader.imageData(for: url) == nil)
        #expect(await failedLoader.imageData(for: url) == nil)
        #expect(await failedFixture.requestCount == 1)
    }

    @Test func unapprovedURLNeverReachesTheDownloader() async throws {
        let fixture = IconDownloadFixture()
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        let url = try #require(URL(string: "https://untrusted.test/icon.png"))
        #expect(await loader.imageData(for: url) == nil)
        #expect(await fixture.requestCount == 0)
    }

    @Test func cacheEvictsOldEntriesAtItsBoundInsteadOfGrowingForever() async throws {
        let fixture = IconDownloadFixture()
        let loader = CatalogAppIconLoader(fetch: { await fixture.download($0) })
        for index in 0...CatalogAppIconPolicy.maximumCachedIcons {
            let url = try #require(URL(string: "https://publikhq.com/icons/fixture-\(index).png"))
            _ = await loader.imageData(for: url)
        }
        let firstURL = try #require(URL(string: "https://publikhq.com/icons/fixture-0.png"))
        _ = await loader.imageData(for: firstURL)
        #expect(await fixture.requestCount == CatalogAppIconPolicy.maximumCachedIcons + 2)
    }
}

private actor IconDownloadFixture {
    private(set) var requestCount = 0
    private(set) var peakRequests = 0
    private var activeRequests = 0
    private let result: Data?

    init(result: Data? = Data([1, 2, 3])) { self.result = result }

    func download(_ url: URL) async -> Data? {
        requestCount += 1
        activeRequests += 1
        peakRequests = max(peakRequests, activeRequests)
        try? await Task.sleep(for: .milliseconds(25))
        activeRequests -= 1
        return result
    }
}
