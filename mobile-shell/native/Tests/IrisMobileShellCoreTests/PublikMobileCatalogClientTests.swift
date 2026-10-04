import Foundation
import XCTest
@testable import IrisMobileShellCore

final class PublikMobileCatalogClientTests: XCTestCase {
    func testMissingMobileShellIsUnavailableAndCatalogRequestIsExact() async throws {
        let catalog = try catalogData(slug: "lunara", name: "Lunara", mobileShell: nil)
        let transport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: catalog)),
        ])
        let client = PublikMobileCatalogClient(transport: transport)

        let apps = try await client.fetchCatalog()
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].slug, "lunara")
        XCTAssertNil(apps[0].mobileShell)

        do {
            _ = try await client.download(apps[0])
            XCTFail("missing mobileShell must not synthesize a download route")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .mobileShellUnavailable(slug: "lunara"))
        }

        let requests = await transport.requestRecords()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, PublikMobileCatalogClient.catalogURL)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].accept, "application/json")
        XCTAssertEqual(requests[0].acceptEncoding, "identity")
        XCTAssertEqual(requests[0].maximumBytes, 1024 * 1024)
    }

    func testCatalogRejectsUnsupportedPlatformMalformedDescriptorAndCrossOriginURL() async throws {
        let unsupported = try catalogData(
            slug: "phone-app",
            name: "Phone App",
            mobileShell: descriptorJSON(platform: "android")
        )
        let unsupportedTransport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: unsupported)),
        ])
        do {
            _ = try await PublikMobileCatalogClient(transport: unsupportedTransport).fetchCatalog()
            XCTFail("non-iOS descriptor must be reported as unsupported")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .unsupportedPlatform("android"))
        }

        var malformedDescriptor = descriptorJSON()
        malformedDescriptor["byteCount"] = "four"
        let malformed = try catalogData(
            slug: "phone-app",
            name: "Phone App",
            mobileShell: malformedDescriptor
        )
        let malformedTransport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: malformed)),
        ])
        do {
            _ = try await PublikMobileCatalogClient(transport: malformedTransport).fetchCatalog()
            XCTFail("wrong descriptor field types must fail closed")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .malformedCatalog)
        }

        let crossOrigin = try catalogData(
            slug: "phone-app",
            name: "Phone App",
            mobileShell: descriptorJSON(downloadURL: "https://publikhq.com.evil.example/mobile/pkg")
        )
        let crossOriginTransport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: crossOrigin)),
        ])
        do {
            _ = try await PublikMobileCatalogClient(transport: crossOriginTransport).fetchCatalog()
            XCTFail("catalog must not create a generic fetch proxy")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .disallowedURL)
        }
    }

    func testCatalogLimitCannotBeBypassedByInjectedTransport() async throws {
        let oversized = Data(repeating: 0x20, count: PublikMobileCatalogClient.maximumCatalogBytes + 1)
        let transport = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/json",
                    declaredContentLength: nil,
                    finalURL: PublikMobileCatalogClient.catalogURL,
                    body: oversized
                )
            ),
        ])
        do {
            _ = try await PublikMobileCatalogClient(transport: transport).fetchCatalog()
            XCTFail("catalog body over 1 MiB must be rejected before decoding")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .responseTooLarge(limit: 1024 * 1024))
        }
    }

    func testDownloadRejectsRedirectStatusMIMEAndLengthsBeforePackageInspection() async throws {
        let app = directCatalogApp(byteCount: 4)
        let packageURL = try XCTUnwrap(app.mobileShell?.downloadURL)

        let redirected = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 302,
                    mimeType: "application/json",
                    declaredContentLength: 0,
                    finalURL: packageURL,
                    body: Data()
                )
            ),
        ])
        await assertDownloadError(.redirectRejected, client: PublikMobileCatalogClient(transport: redirected), app: app)

        let wrongStatus = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 503,
                    mimeType: "application/json",
                    declaredContentLength: 4,
                    finalURL: packageURL,
                    body: Data(repeating: 0, count: 4)
                )
            ),
        ])
        await assertDownloadError(.unexpectedStatus(503), client: PublikMobileCatalogClient(transport: wrongStatus), app: app)

        let wrongMIME = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/octet-stream",
                    declaredContentLength: 4,
                    finalURL: packageURL,
                    body: Data(repeating: 0, count: 4)
                )
            ),
        ])
        await assertDownloadError(
            .unexpectedMIME(expected: "application/json", actual: "application/octet-stream"),
            client: PublikMobileCatalogClient(transport: wrongMIME),
            app: app
        )

        let declaredTooLarge = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/json",
                    declaredContentLength: 5,
                    finalURL: packageURL,
                    body: Data()
                )
            ),
        ])
        await assertDownloadError(
            .responseTooLarge(limit: 4),
            client: PublikMobileCatalogClient(transport: declaredTooLarge),
            app: app
        )

        let shortBody = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/json",
                    declaredContentLength: 4,
                    finalURL: packageURL,
                    body: Data(repeating: 0, count: 3)
                )
            ),
        ])
        await assertDownloadError(
            .responseLengthMismatch(expected: 4, actual: 3),
            client: PublikMobileCatalogClient(transport: shortBody),
            app: app
        )
    }

    func testDownloadRejectsRedirectedFinalURLAndDigestMismatch() async throws {
        let app = directCatalogApp(byteCount: 4)
        let packageURL = try XCTUnwrap(app.mobileShell?.downloadURL)

        let followedRedirect = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/json",
                    declaredContentLength: 4,
                    finalURL: URL(string: "https://publikhq.com/mobile/redirected")!,
                    body: Data("nope".utf8)
                )
            ),
        ])
        await assertDownloadError(
            .redirectRejected,
            client: PublikMobileCatalogClient(transport: followedRedirect),
            app: app
        )

        let digestTransport = ScriptedPublikTransport(steps: [
            .response(
                PublikMobileHTTPResponse(
                    statusCode: 200,
                    mimeType: "application/json",
                    declaredContentLength: 4,
                    finalURL: packageURL,
                    body: Data("nope".utf8)
                )
            ),
        ])
        do {
            _ = try await PublikMobileCatalogClient(transport: digestTransport).download(app)
            XCTFail("digest mismatch must fail before package parsing")
        } catch let error as PublikMobileDownloadError {
            guard case .packageDigestMismatch(let expected, let actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, app.mobileShell?.packageSHA256)
            XCTAssertNotEqual(expected, actual)
        }
    }

    func testValidPackageCanRetryThenBindsIdentityAndFeedsExistingReviewOnly() async throws {
        let packageBytes = try syntheticPackageBytes()
        let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: packageBytes)
        let shell = descriptorJSON(inspection: inspection, byteCount: packageBytes.count)
        let catalog = try catalogData(slug: "safe-demo", name: "Safe Demo", mobileShell: shell)
        let packageURL = URL(string: try XCTUnwrap(shell["downloadUrl"] as? String))!
        let badBytes = Data(repeating: 0, count: packageBytes.count)
        let progressRecorder = ProgressRecorder()
        let transport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: catalog)),
            .response(httpResponse(url: packageURL, body: badBytes), progressReports: [badBytes.count]),
            .response(httpResponse(url: packageURL, body: packageBytes), progressReports: [packageBytes.count]),
        ])
        let client = PublikMobileCatalogClient(transport: transport)
        let fetchedApps = try await client.fetchCatalog()
        let app = try XCTUnwrap(fetchedApps.first)

        do {
            _ = try await client.download(app)
            XCTFail("first corrupt transfer must not be retried automatically")
        } catch let error as PublikMobileDownloadError {
            guard case .packageDigestMismatch = error else {
                return XCTFail("unexpected first transfer error: \(error)")
            }
        }
        let firstRequestCount = await transport.requestRecords().count
        XCTAssertEqual(firstRequestCount, 2)

        let downloaded = try await client.download(app) { progressRecorder.record($0) }
        XCTAssertEqual(downloaded.packageBytes, packageBytes)
        XCTAssertEqual(downloaded.inspection, inspection)
        XCTAssertEqual(downloaded.identity, NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId))
        let retryRequestCount = await transport.requestRecords().count
        XCTAssertEqual(retryRequestCount, 3)
        XCTAssertEqual(
            progressRecorder.snapshot(),
            [PublikMobileDownloadProgress(receivedBytes: packageBytes.count, expectedBytes: packageBytes.count)]
        )

        let reviewRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("publik-mobile-review-\(UUID().uuidString)", isDirectory: true)
        let coordinator = NativeShellLibraryCoordinator(rootURL: reviewRoot)
        let review = try await coordinator.reviewImport(
            packageBytes: downloaded.packageBytes,
            expectedIdentity: downloaded.identity
        )
        XCTAssertEqual(review.packageSHA256, inspection.packageSHA256)
        XCTAssertEqual(review.identity, downloaded.identity)
        let pendingReview = await coordinator.pendingPackageReview()
        XCTAssertNotNil(pendingReview)
    }

    func testDownloadedPackageIdentityMustMatchCatalogBinding() async throws {
        let packageBytes = try syntheticPackageBytes()
        let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: packageBytes)
        var shell = descriptorJSON(inspection: inspection, byteCount: packageBytes.count)
        shell["projectId"] = "publik.other-project"
        let catalog = try catalogData(slug: "safe-demo", name: "Safe Demo", mobileShell: shell)
        let packageURL = URL(string: try XCTUnwrap(shell["downloadUrl"] as? String))!
        let transport = ScriptedPublikTransport(steps: [
            .response(httpResponse(url: PublikMobileCatalogClient.catalogURL, body: catalog)),
            .response(httpResponse(url: packageURL, body: packageBytes)),
        ])
        let client = PublikMobileCatalogClient(transport: transport)
        let fetchedApps = try await client.fetchCatalog()
        let app = try XCTUnwrap(fetchedApps.first)

        do {
            _ = try await client.download(app)
            XCTFail("package project identity must be bound to the catalog descriptor")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(
                error,
                .packageIdentityMismatch(
                    field: "projectId",
                    expected: "publik.other-project",
                    actual: inspection.projectId
                )
            )
        }
    }

    func testDownloadCancellationPropagatesWithoutRetry() async throws {
        let transport = BlockingPublikTransport()
        let client = PublikMobileCatalogClient(transport: transport)
        let app = directCatalogApp(byteCount: 1)
        let task = Task {
            try await client.download(app)
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled download must stop")
        } catch is CancellationError {
            // Expected: callers own cancellation and may explicitly retry later.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testURLSessionTransportRejectsHeadersBeforeAllowingBody() async throws {
        PublikMobileURLProtocolStub.configure(
            .headersThenDelayedBody(
                statusCode: 200,
                mimeType: "application/octet-stream",
                contentLength: 16,
                contentEncoding: nil,
                body: Data(repeating: 0x41, count: 16)
            )
        )
        let transport = urlProtocolTransport()
        var request = URLRequest(url: URL(string: "https://publikhq.com/mobile/header-reject.irisapp")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            _ = try await transport.get(request, maximumBytes: 64, progress: nil)
            XCTFail("wrong MIME must reject at response headers")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(
                error,
                .unexpectedMIME(expected: "application/json", actual: "application/octet-stream")
            )
        }
        try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        let firstSnapshot = PublikMobileURLProtocolStub.snapshot()
        XCTAssertEqual(firstSnapshot.loadedBodyBytes, 0)

        PublikMobileURLProtocolStub.configure(
            .headersThenDelayedBody(
                statusCode: 200,
                mimeType: "application/json",
                contentLength: 65,
                contentEncoding: nil,
                body: Data(repeating: 0x42, count: 16)
            )
        )
        do {
            _ = try await transport.get(request, maximumBytes: 64, progress: nil)
            XCTFail("oversized declared response must reject before body allocation")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .responseTooLarge(limit: 64))
        }
        try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        let secondSnapshot = PublikMobileURLProtocolStub.snapshot()
        XCTAssertEqual(secondSnapshot.loadedBodyBytes, 0)

        PublikMobileURLProtocolStub.configure(
            .headersThenDelayedBody(
                statusCode: 200,
                mimeType: "application/json",
                contentLength: 16,
                contentEncoding: "gzip",
                body: Data(repeating: 0x43, count: 16)
            )
        )
        do {
            _ = try await transport.get(request, maximumBytes: 64, progress: nil)
            XCTFail("compressed response must reject before body delivery")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .invalidDescriptorField("HTTP Content-Encoding"))
        }
        try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        let thirdSnapshot = PublikMobileURLProtocolStub.snapshot()
        XCTAssertEqual(thirdSnapshot.loadedBodyBytes, 0)
    }

    func testURLSessionTransportStreamsChunksCoalescesProgressRejectsRedirectAndCancels() async throws {
        let body = Data(repeating: 0x5a, count: 150_000)
        PublikMobileURLProtocolStub.configure(.body(body, chunkSize: 8 * 1024))
        let transport = urlProtocolTransport()
        let progress = IntProgressRecorder()
        var request = URLRequest(url: URL(string: "https://publikhq.com/mobile/stream.irisapp")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let response = try await transport.get(
            request,
            maximumBytes: body.count,
            progress: { value in progress.record(value) }
        )
        XCTAssertEqual(response.body, body)
        XCTAssertEqual(response.declaredContentLength, body.count)
        let progressValues = progress.snapshot()
        XCTAssertEqual(progressValues.last, body.count)
        XCTAssertLessThanOrEqual(progressValues.count, 4)
        XCTAssertTrue(progressValues.allSatisfy { $0 > 0 && $0 <= body.count })

        PublikMobileURLProtocolStub.configure(
            .redirect(URL(string: "https://publikhq.com/mobile/redirect-target.irisapp")!)
        )
        do {
            _ = try await transport.get(request, maximumBytes: body.count, progress: nil)
            XCTFail("URLSession redirects must be rejected")
        } catch let error as PublikMobileDownloadError {
            XCTAssertEqual(error, .redirectRejected)
        }

        PublikMobileURLProtocolStub.configure(.stall(contentLength: 1))
        let task = Task {
            try await transport.get(request, maximumBytes: 1, progress: nil)
        }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelling the caller task must cancel the URLSession task")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testClientHonorsCancellationEvenWhenInjectedTransportSwallowsIt() async throws {
        let app = directCatalogApp(byteCount: 4)
        let packageURL = try XCTUnwrap(app.mobileShell?.downloadURL)
        let response = PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: "application/json",
            declaredContentLength: 4,
            finalURL: packageURL,
            body: Data("nope".utf8)
        )
        let client = PublikMobileCatalogClient(
            transport: CancellationIgnoringPublikTransport(response: response)
        )
        let task = Task {
            try await client.download(app)
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("client must recheck cancellation after an injected transport returns")
        } catch is CancellationError {
            // Expected even though the injected transport swallowed cancellation.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}

private actor ScriptedPublikTransport: PublikMobileHTTPTransport {
    struct Step: Sendable {
        let response: PublikMobileHTTPResponse
        let progressReports: [Int]

        static func response(
            _ response: PublikMobileHTTPResponse,
            progressReports: [Int] = []
        ) -> Step {
            Step(response: response, progressReports: progressReports)
        }
    }

    struct RequestRecord: Sendable {
        let url: URL?
        let method: String?
        let accept: String?
        let acceptEncoding: String?
        let maximumBytes: Int
    }

    private var steps: [Step]
    private var records: [RequestRecord] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        records.append(
            RequestRecord(
                url: request.url,
                method: request.httpMethod,
                accept: request.value(forHTTPHeaderField: "Accept"),
                acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding"),
                maximumBytes: maximumBytes
            )
        )
        guard !steps.isEmpty else { throw TestTransportError.noScriptedResponse }
        let step = steps.removeFirst()
        for value in step.progressReports {
            progress?(value)
        }
        return step.response
    }

    func requestRecords() -> [RequestRecord] {
        records
    }
}

private struct BlockingPublikTransport: PublikMobileHTTPTransport, Sendable {
    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        try await Task<Never, Never>.sleep(nanoseconds: 30_000_000_000)
        throw TestTransportError.unexpectedCompletion
    }
}

private struct CancellationIgnoringPublikTransport: PublikMobileHTTPTransport, Sendable {
    let response: PublikMobileHTTPResponse

    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        try? await Task<Never, Never>.sleep(nanoseconds: 100_000_000)
        return response
    }
}

private enum TestTransportError: Error {
    case noScriptedResponse
    case unexpectedCompletion
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PublikMobileDownloadProgress] = []

    func record(_ value: PublikMobileDownloadProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [PublikMobileDownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class IntProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func urlProtocolTransport() -> PublikMobileURLSessionTransport {
    PublikMobileURLSessionTransport { configuration in
        configuration.protocolClasses = [PublikMobileURLProtocolStub.self]
    }
}

private final class PublikMobileURLProtocolStub: URLProtocol {
    enum Mode: @unchecked Sendable {
        case headersOnly(statusCode: Int, mimeType: String, contentLength: Int?, contentEncoding: String?)
        case headersThenDelayedBody(
            statusCode: Int,
            mimeType: String,
            contentLength: Int?,
            contentEncoding: String?,
            body: Data
        )
        case body(Data, chunkSize: Int)
        case redirect(URL)
        case stall(contentLength: Int)
    }

    struct Snapshot: Sendable {
        let stopCount: Int
        let loadedBodyBytes: Int
    }

    private final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var mode: Mode = .stall(contentLength: 1)
        private var stopCount = 0
        private var loadedBodyBytes = 0

        func configure(_ mode: Mode) {
            lock.lock()
            self.mode = mode
            stopCount = 0
            loadedBodyBytes = 0
            lock.unlock()
        }

        func currentMode() -> Mode {
            lock.lock()
            defer { lock.unlock() }
            return mode
        }

        func markStopped() {
            lock.lock()
            stopCount += 1
            lock.unlock()
        }

        func addLoadedBytes(_ count: Int) {
            lock.lock()
            loadedBodyBytes += count
            lock.unlock()
        }

        func snapshot() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(stopCount: stopCount, loadedBodyBytes: loadedBodyBytes)
        }
    }

    private static let state = SharedState()

    static func configure(_ mode: Mode) {
        state.configure(mode)
    }

    static func snapshot() -> Snapshot {
        state.snapshot()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "publikhq.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        switch Self.state.currentMode() {
        case .headersOnly(let statusCode, let mimeType, let contentLength, let contentEncoding):
            client.urlProtocol(
                self,
                didReceive: response(
                    url: url,
                    statusCode: statusCode,
                    mimeType: mimeType,
                    contentLength: contentLength,
                    contentEncoding: contentEncoding
                ),
                cacheStoragePolicy: .notAllowed
            )
        case .headersThenDelayedBody(let statusCode, let mimeType, let contentLength, let contentEncoding, let body):
            client.urlProtocol(
                self,
                didReceive: response(
                    url: url,
                    statusCode: statusCode,
                    mimeType: mimeType,
                    contentLength: contentLength,
                    contentEncoding: contentEncoding
                ),
                cacheStoragePolicy: .notAllowed
            )
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, Self.state.snapshot().stopCount == 0 else { return }
                Self.state.addLoadedBytes(body.count)
                client.urlProtocol(self, didLoad: body)
                client.urlProtocolDidFinishLoading(self)
            }
        case .body(let body, let chunkSize):
            client.urlProtocol(
                self,
                didReceive: response(
                    url: url,
                    statusCode: 200,
                    mimeType: "application/json",
                    contentLength: body.count,
                    contentEncoding: nil
                ),
                cacheStoragePolicy: .notAllowed
            )
            var offset = 0
            while offset < body.count {
                let end = min(offset + max(chunkSize, 1), body.count)
                let chunk = body.subdata(in: offset..<end)
                Self.state.addLoadedBytes(chunk.count)
                client.urlProtocol(self, didLoad: chunk)
                offset = end
            }
            client.urlProtocolDidFinishLoading(self)
        case .redirect(let target):
            let redirectResponse = response(
                url: url,
                statusCode: 302,
                mimeType: "application/json",
                contentLength: 0,
                contentEncoding: nil,
                extraHeaders: ["Location": target.absoluteString]
            )
            client.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: redirectResponse
            )
        case .stall(let contentLength):
            client.urlProtocol(
                self,
                didReceive: response(
                    url: url,
                    statusCode: 200,
                    mimeType: "application/json",
                    contentLength: contentLength,
                    contentEncoding: nil
                ),
                cacheStoragePolicy: .notAllowed
            )
        }
    }

    override func stopLoading() {
        Self.state.markStopped()
    }

    private func response(
        url: URL,
        statusCode: Int,
        mimeType: String,
        contentLength: Int?,
        contentEncoding: String?,
        extraHeaders: [String: String] = [:]
    ) -> HTTPURLResponse {
        var headers = extraHeaders
        headers["Content-Type"] = mimeType
        if let contentLength {
            headers["Content-Length"] = String(contentLength)
        }
        if let contentEncoding {
            headers["Content-Encoding"] = contentEncoding
        }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

private func assertDownloadError(
    _ expected: PublikMobileDownloadError,
    client: PublikMobileCatalogClient,
    app: PublikMobileCatalogApp,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await client.download(app)
        XCTFail("expected download to fail", file: file, line: line)
    } catch let error as PublikMobileDownloadError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func directCatalogApp(byteCount: Int) -> PublikMobileCatalogApp {
    let contentHash = "sha256:" + String(repeating: "a", count: 64)
    let descriptor = PublikMobileShellDescriptor(
        version: 1,
        platform: "ios",
        packageFormat: "iris.mobile-shell.package+json",
        downloadURL: URL(string: "https://publikhq.com/mobile/package.irisapp")!,
        mediaType: "application/json",
        byteCount: byteCount,
        packageSHA256: "sha256:" + String(repeating: "b", count: 64),
        appId: "publik.test-app",
        projectId: "publik.test-project",
        baseRevisionId: nil,
        revisionId: "rev-sha256:" + String(repeating: "a", count: 64),
        contentHash: contentHash
    )
    return PublikMobileCatalogApp(
        slug: "test-app",
        name: "Test App",
        guideSlug: nil,
        macBundleId: nil,
        latestReleaseTag: nil,
        mobileShell: descriptor
    )
}

private func descriptorJSON(
    platform: String = "ios",
    downloadURL: String = "https://publikhq.com/mobile/package.irisapp"
) -> [String: Any] {
    let contentHash = "sha256:" + String(repeating: "a", count: 64)
    return [
        "version": 1,
        "platform": platform,
        "packageFormat": "iris.mobile-shell.package+json",
        "downloadUrl": downloadURL,
        "mediaType": "application/json",
        "byteCount": 1,
        "packageSha256": "sha256:" + String(repeating: "b", count: 64),
        "appId": "publik.test-app",
        "projectId": "publik.test-project",
        "baseRevisionId": NSNull(),
        "revisionId": "rev-sha256:" + String(repeating: "a", count: 64),
        "contentHash": contentHash,
    ]
}

private func descriptorJSON(
    inspection: DeliveryPackageInspection,
    byteCount: Int
) -> [String: Any] {
    [
        "version": 1,
        "platform": "ios",
        "packageFormat": "iris.mobile-shell.package+json",
        "downloadUrl": "https://publikhq.com/mobile/safe-demo.irisapp",
        "mediaType": "application/json",
        "byteCount": byteCount,
        "packageSha256": inspection.packageSHA256,
        "appId": inspection.appId,
        "projectId": inspection.projectId,
        "baseRevisionId": inspection.baseRevisionId ?? NSNull(),
        "revisionId": inspection.revisionId,
        "contentHash": inspection.contentHash,
    ]
}

private func catalogData(
    slug: String,
    name: String,
    mobileShell: [String: Any]?
) throws -> Data {
    var row: [String: Any] = [
        "slug": slug,
        "name": name,
        "guideSlug": slug,
        "macBundleId": NSNull(),
        "latestReleaseTag": NSNull(),
    ]
    if let mobileShell {
        row["mobileShell"] = mobileShell
    }
    return try JSONSerialization.data(withJSONObject: ["apps": [row]], options: [.sortedKeys])
}

private func httpResponse(
    url: URL,
    body: Data,
    statusCode: Int = 200,
    mimeType: String = "application/json"
) -> PublikMobileHTTPResponse {
    PublikMobileHTTPResponse(
        statusCode: statusCode,
        mimeType: mimeType,
        declaredContentLength: body.count,
        finalURL: url,
        body: body
    )
}

private func syntheticPackageBytes() throws -> Data {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let packageURL = repositoryRoot
        .appendingPathComponent("mobile-shell/native/IrisMobileShellApp/Resources/SafeDemo.irisapp")
    return try Data(contentsOf: packageURL)
}
