import Foundation

public struct PublikMobileHTTPResponse: Sendable {
    public let statusCode: Int
    public let mimeType: String?
    public let declaredContentLength: Int?
    public let finalURL: URL?
    public let body: Data
    /// The response's `ETag` header, when present. Only meaningful for a
    /// catalog v2 conditional-GET response (200 with a fresh ETag, or 304
    /// meaning the caller's cached body is still current); nil for every
    /// other response type, including a fake test transport's response that
    /// does not set it.
    public let etag: String?

    public init(
        statusCode: Int,
        mimeType: String?,
        declaredContentLength: Int?,
        finalURL: URL?,
        body: Data,
        etag: String? = nil
    ) {
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.declaredContentLength = declaredContentLength
        self.finalURL = finalURL
        self.body = body
        self.etag = etag
    }
}

public protocol PublikMobileHTTPTransport: Sendable {
    func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse
}

public struct PublikMobileURLSessionTransport: PublikMobileHTTPTransport, Sendable {
    private let configureForTesting: (@Sendable (URLSessionConfiguration) -> Void)?

    public init() {
        configureForTesting = nil
    }

    init(configureForTesting: @escaping @Sendable (URLSessionConfiguration) -> Void) {
        self.configureForTesting = configureForTesting
    }

    public func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> PublikMobileHTTPResponse {
        try Task.checkCancellation()
        guard let requestURL = request.url, Self.isAllowedPublikURL(requestURL) else {
            throw PublikMobileDownloadError.disallowedURL
        }
        guard request.httpMethod == "GET" else {
            throw PublikMobileDownloadError.transportFailure("Publik mobile transport only allows GET requests.")
        }
        guard request.value(forHTTPHeaderField: "Accept-Encoding")?.lowercased() == "identity" else {
            throw PublikMobileDownloadError.invalidDescriptorField("HTTP Accept-Encoding")
        }
        guard maximumBytes > 0 else {
            throw PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configureForTesting?(configuration)

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        let expectedMIME = request.value(forHTTPHeaderField: "Accept")?.lowercased()
        // A conditional GET (If-None-Match present) is the only case where a
        // 304 response is meaningful; every other request path is unchanged
        // and still requires exactly 200, so this is additive, not a
        // relaxation of the existing security posture.
        let allowNotModified = request.value(forHTTPHeaderField: "If-None-Match") != nil
        let delegate = PublikMobileDataDelegate(
            requestURL: requestURL,
            expectedMIME: expectedMIME,
            maximumBytes: maximumBytes,
            allowNotModified: allowNotModified,
            progress: progress
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response = try await withCheckedThrowingContinuation { continuation in
                delegate.begin(session: session, request: request, continuation: continuation)
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            delegate.cancel()
        }
    }

    private static func isAllowedPublikURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "publikhq.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
            && !components.path.isEmpty
    }
}

private final class PublikMobileDataDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let requestURL: URL
    private let expectedMIME: String?
    private let maximumBytes: Int
    private let allowNotModified: Bool
    private let progress: (@Sendable (Int) -> Void)?
    private let lock = NSLock()

    private var continuation: CheckedContinuation<PublikMobileHTTPResponse, Error>?
    private weak var session: URLSession?
    private weak var task: URLSessionDataTask?
    private var cancelled = false
    private var completed = false
    private var body = Data()
    private var statusCode = 0
    private var mimeType: String?
    private var declaredContentLength: Int?
    private var finalURL: URL?
    private var etag: String?
    private var lastProgressBytes = 0
    private var lastProgressTime = ProcessInfo.processInfo.systemUptime

    init(
        requestURL: URL,
        expectedMIME: String?,
        maximumBytes: Int,
        allowNotModified: Bool = false,
        progress: (@Sendable (Int) -> Void)?
    ) {
        self.requestURL = requestURL
        self.expectedMIME = expectedMIME
        self.maximumBytes = maximumBytes
        self.allowNotModified = allowNotModified
        self.progress = progress
    }

    func begin(
        session: URLSession,
        request: URLRequest,
        continuation: CheckedContinuation<PublikMobileHTTPResponse, Error>
    ) {
        lock.lock()
        if cancelled {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            session.invalidateAndCancel()
            return
        }
        self.continuation = continuation
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        let pending = takeCompletionIfPossible(markCancelled: true)
        pending.task?.cancel()
        pending.session?.invalidateAndCancel()
        pending.continuation?.resume(throwing: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            guard let http = response as? HTTPURLResponse else {
                throw PublikMobileDownloadError.unexpectedStatus(0)
            }
            guard http.url == requestURL else {
                throw PublikMobileDownloadError.redirectRejected
            }
            let isNotModified = allowNotModified && http.statusCode == 304
            if !isNotModified, (300..<400).contains(http.statusCode) {
                throw PublikMobileDownloadError.redirectRejected
            }
            guard http.statusCode == 200 || isNotModified else {
                throw PublikMobileDownloadError.unexpectedStatus(http.statusCode)
            }
            if !isNotModified, let expectedMIME {
                guard http.mimeType?.lowercased() == expectedMIME else {
                    throw PublikMobileDownloadError.unexpectedMIME(expected: expectedMIME, actual: http.mimeType)
                }
            }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased(), encoding != "identity" {
                throw PublikMobileDownloadError.invalidDescriptorField("HTTP Content-Encoding")
            }
            let declared = try Self.contentLength(from: http)
            if let declared, declared > maximumBytes {
                throw PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)
            }

            lock.lock()
            guard !completed else {
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            statusCode = http.statusCode
            mimeType = http.mimeType
            declaredContentLength = declared
            finalURL = http.url
            etag = http.value(forHTTPHeaderField: "ETag")
            if let declared {
                body.reserveCapacity(declared)
            }
            lock.unlock()
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var progressValue: Int?
        var overflow = false

        lock.lock()
        if !completed {
            if data.count > maximumBytes - body.count {
                overflow = true
            } else {
                body.append(data)
                let now = ProcessInfo.processInfo.systemUptime
                if body.count - lastProgressBytes >= 64 * 1024 || now - lastProgressTime >= 0.2 {
                    lastProgressBytes = body.count
                    lastProgressTime = now
                    progressValue = body.count
                }
            }
        }
        lock.unlock()

        if overflow {
            dataTask.cancel()
            finish(.failure(PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)))
            return
        }
        if let progressValue {
            progress?(progressValue)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(PublikMobileDownloadError.redirectRejected))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        finish(.failure(PublikMobileDownloadError.transportFailure("Publik requested unsupported authentication.")))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }

        var response: PublikMobileHTTPResponse?
        var finalProgress: Int?
        lock.lock()
        if !completed {
            if body.count != lastProgressBytes, !body.isEmpty {
                lastProgressBytes = body.count
                finalProgress = body.count
            }
            response = PublikMobileHTTPResponse(
                statusCode: statusCode,
                mimeType: mimeType,
                declaredContentLength: declaredContentLength,
                finalURL: finalURL,
                body: body,
                etag: etag
            )
        }
        lock.unlock()

        if let finalProgress {
            progress?(finalProgress)
        }
        if let response {
            finish(.success(response))
        }
    }

    private func finish(_ result: Result<PublikMobileHTTPResponse, Error>) {
        let pending = takeCompletionIfPossible(markCancelled: false)
        guard let continuation = pending.continuation else { return }
        switch result {
        case .success(let response):
            pending.session?.finishTasksAndInvalidate()
            continuation.resume(returning: response)
        case .failure(let error):
            pending.task?.cancel()
            pending.session?.invalidateAndCancel()
            continuation.resume(throwing: error)
        }
    }

    private func takeCompletionIfPossible(
        markCancelled: Bool
    ) -> (continuation: CheckedContinuation<PublikMobileHTTPResponse, Error>?, session: URLSession?, task: URLSessionDataTask?) {
        lock.lock()
        defer { lock.unlock() }
        if markCancelled {
            cancelled = true
        }
        guard !completed, let continuation else {
            return (nil, session, task)
        }
        completed = true
        self.continuation = nil
        return (continuation, session, task)
    }

    private static func contentLength(from response: HTTPURLResponse) throws -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Length") else { return nil }
        guard let value = Int(raw), value >= 0 else {
            throw PublikMobileDownloadError.invalidDescriptorField("HTTP Content-Length")
        }
        return value
    }
}

public struct PublikMobileCatalogClient: Sendable {
    public static let catalogURL = URL(string: "https://publikhq.com/api/iris/apps")!
    public static let maximumCatalogBytes = 1024 * 1024

    private static let allowedOriginScheme = "https"
    private static let allowedOriginHost = "publikhq.com"
    private static let packageMediaType = "application/json"

    private let transport: any PublikMobileHTTPTransport

    public init() {
        transport = PublikMobileURLSessionTransport()
    }

    public init(transport: any PublikMobileHTTPTransport) {
        self.transport = transport
    }

    public func fetchCatalog() async throws -> [PublikMobileCatalogApp] {
        var request = URLRequest(url: Self.catalogURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let response = try await perform(
            request,
            maximumBytes: Self.maximumCatalogBytes,
            progress: nil
        )
        try validateResponse(response, for: request, expectedMIME: "application/json")
        if let declared = response.declaredContentLength, declared != response.body.count {
            throw PublikMobileDownloadError.responseLengthMismatch(expected: declared, actual: response.body.count)
        }

        let wire: PublikMobileCatalogEnvelopeWire
        do {
            wire = try JSONDecoder().decode(PublikMobileCatalogEnvelopeWire.self, from: response.body)
        } catch {
            throw PublikMobileDownloadError.malformedCatalog
        }

        var slugs = Set<String>()
        var apps: [PublikMobileCatalogApp] = []
        apps.reserveCapacity(wire.apps.count)
        for row in wire.apps {
            guard NativeSecurity.isStableId(row.slug), slugs.insert(row.slug).inserted else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.slug")
            }
            guard !row.name.isEmpty, row.name.utf8.count <= 256 else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.name")
            }
            if let guideSlug = row.guideSlug, !NativeSecurity.isStableId(guideSlug) {
                throw PublikMobileDownloadError.invalidCatalogField("apps.guideSlug")
            }
            if let macBundleId = row.macBundleId, macBundleId.utf8.count > 256 {
                throw PublikMobileDownloadError.invalidCatalogField("apps.macBundleId")
            }
            if let latestReleaseTag = row.latestReleaseTag, latestReleaseTag.utf8.count > 128 {
                throw PublikMobileDownloadError.invalidCatalogField("apps.latestReleaseTag")
            }

            let descriptor = try row.mobileShell.map(validatedDescriptor)
            apps.append(
                PublikMobileCatalogApp(
                    slug: row.slug,
                    name: row.name,
                    guideSlug: row.guideSlug,
                    macBundleId: row.macBundleId,
                    latestReleaseTag: row.latestReleaseTag,
                    mobileShell: descriptor
                )
            )
        }
        return apps
    }

    public func download(
        _ app: PublikMobileCatalogApp,
        progress: (@Sendable (PublikMobileDownloadProgress) -> Void)? = nil
    ) async throws -> PublikMobileDownloadedPackage {
        guard let descriptor = app.mobileShell else {
            throw PublikMobileDownloadError.mobileShellUnavailable(slug: app.slug)
        }
        try validateDescriptor(descriptor)
        try Task.checkCancellation()

        var request = URLRequest(url: descriptor.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue(descriptor.mediaType, forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let response = try await perform(
            request,
            maximumBytes: descriptor.byteCount,
            progress: { receivedBytes in
                progress?(
                    PublikMobileDownloadProgress(
                        receivedBytes: receivedBytes,
                        expectedBytes: descriptor.byteCount
                    )
                )
            }
        )
        try validateResponse(response, for: request, expectedMIME: descriptor.mediaType)
        if let declared = response.declaredContentLength, declared != descriptor.byteCount {
            throw PublikMobileDownloadError.responseLengthMismatch(
                expected: descriptor.byteCount,
                actual: declared
            )
        }
        guard response.body.count == descriptor.byteCount else {
            throw PublikMobileDownloadError.responseLengthMismatch(
                expected: descriptor.byteCount,
                actual: response.body.count
            )
        }

        let packageDigest = NativeSecurity.sha256(response.body)
        guard packageDigest == descriptor.packageSHA256 else {
            throw PublikMobileDownloadError.packageDigestMismatch(
                expected: descriptor.packageSHA256,
                actual: packageDigest
            )
        }

        let inspection: DeliveryPackageInspection
        do {
            inspection = try DeliveryPackageV1Validator().inspect(packageBytes: response.body)
        } catch let error as NativeShellError {
            throw PublikMobileDownloadError.invalidPackage(error)
        }
        try bind(inspection: inspection, to: descriptor)

        return PublikMobileDownloadedPackage(
            catalogSlug: app.slug,
            identity: descriptor.identity,
            packageBytes: response.body,
            inspection: inspection
        )
    }

    private func perform(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        do {
            let response = try await transport.get(request, maximumBytes: maximumBytes, progress: progress)
            try Task.checkCancellation()
            if let declared = response.declaredContentLength {
                guard declared >= 0 else {
                    throw PublikMobileDownloadError.invalidDescriptorField("HTTP Content-Length")
                }
                guard declared <= maximumBytes else {
                    throw PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)
                }
            }
            guard response.body.count <= maximumBytes else {
                throw PublikMobileDownloadError.responseTooLarge(limit: maximumBytes)
            }
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PublikMobileDownloadError {
            throw error
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
            throw CancellationError()
        } catch {
            throw PublikMobileDownloadError.transportFailure(error.localizedDescription)
        }
    }

    private func validateResponse(
        _ response: PublikMobileHTTPResponse,
        for request: URLRequest,
        expectedMIME: String
    ) throws {
        guard let requestURL = request.url else {
            throw PublikMobileDownloadError.disallowedURL
        }
        guard response.finalURL == requestURL else {
            throw PublikMobileDownloadError.redirectRejected
        }
        if (300..<400).contains(response.statusCode) {
            throw PublikMobileDownloadError.redirectRejected
        }
        guard response.statusCode == 200 else {
            throw PublikMobileDownloadError.unexpectedStatus(response.statusCode)
        }
        guard response.mimeType?.lowercased() == expectedMIME else {
            throw PublikMobileDownloadError.unexpectedMIME(expected: expectedMIME, actual: response.mimeType)
        }
    }

    private func validatedDescriptor(_ wire: PublikMobileShellDescriptorWire) throws -> PublikMobileShellDescriptor {
        guard let url = URL(string: wire.downloadURL) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.downloadUrl")
        }
        // Absent Guideline 4.7 metadata leaves an ordinary installable
        // descriptor (appStoreMetadata stays nil); present-but-hostile
        // metadata (huge strings, a non-https or script-bearing URL, an
        // unsupported age rating) is a hard rejection of the whole
        // descriptor, not a silently dropped field, matching every other
        // field's fail-closed treatment in this validator.
        let appStoreMetadata: Review47AppStoreMetadata?
        if let metadataWire = wire.appStoreMetadata {
            do {
                appStoreMetadata = try Review47AppStoreMetadata(wire: metadataWire)
            } catch {
                throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.appStoreMetadata")
            }
        } else {
            appStoreMetadata = nil
        }
        let descriptor = PublikMobileShellDescriptor(
            version: wire.version,
            platform: wire.platform,
            packageFormat: wire.packageFormat,
            downloadURL: url,
            mediaType: wire.mediaType,
            byteCount: wire.byteCount,
            packageSHA256: wire.packageSHA256,
            appId: wire.appId,
            projectId: wire.projectId,
            baseRevisionId: wire.baseRevisionId,
            revisionId: wire.revisionId,
            contentHash: wire.contentHash,
            appStoreMetadata: appStoreMetadata
        )
        try validateDescriptor(descriptor)
        return descriptor
    }

    private func validateDescriptor(_ descriptor: PublikMobileShellDescriptor) throws {
        guard descriptor.version == 1 else {
            throw PublikMobileDownloadError.unsupportedDescriptorVersion(descriptor.version)
        }
        guard descriptor.platform == "ios" else {
            throw PublikMobileDownloadError.unsupportedPlatform(descriptor.platform)
        }
        guard descriptor.packageFormat == NativeSecurity.packageFormat else {
            throw PublikMobileDownloadError.unsupportedPackageFormat(descriptor.packageFormat)
        }
        guard Self.isAllowedPublikURL(descriptor.downloadURL) else {
            throw PublikMobileDownloadError.disallowedURL
        }
        guard descriptor.mediaType == Self.packageMediaType else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.mediaType")
        }
        guard (1...DeliveryPackageV1Validator.maximumRawPackageBytes).contains(descriptor.byteCount) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.byteCount")
        }
        guard NativeSecurity.isSHA256(descriptor.packageSHA256) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.packageSha256")
        }
        guard NativeSecurity.isStableId(descriptor.appId) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.appId")
        }
        guard NativeSecurity.isStableId(descriptor.projectId) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.projectId")
        }
        if let baseRevisionId = descriptor.baseRevisionId, !NativeSecurity.isRevisionId(baseRevisionId) {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.baseRevisionId")
        }
        guard NativeSecurity.isRevisionId(descriptor.revisionId) else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.revisionId")
        }
        guard NativeSecurity.isSHA256(descriptor.contentHash),
              NativeSecurity.revisionId(forContentHash: descriptor.contentHash) == descriptor.revisionId else {
            throw PublikMobileDownloadError.invalidDescriptorField("mobileShell.contentHash")
        }
    }

    private func bind(
        inspection: DeliveryPackageInspection,
        to descriptor: PublikMobileShellDescriptor
    ) throws {
        try requireEqual("packageSHA256", inspection.packageSHA256, descriptor.packageSHA256)
        try requireEqual("appId", inspection.appId, descriptor.appId)
        try requireEqual("projectId", inspection.projectId, descriptor.projectId)
        try requireEqual("baseRevisionId", inspection.baseRevisionId, descriptor.baseRevisionId)
        try requireEqual("revisionId", inspection.revisionId, descriptor.revisionId)
        try requireEqual("contentHash", inspection.contentHash, descriptor.contentHash)
    }

    private func requireEqual(_ field: String, _ actual: String, _ expected: String) throws {
        guard actual == expected else {
            throw PublikMobileDownloadError.packageIdentityMismatch(
                field: field,
                expected: expected,
                actual: actual
            )
        }
    }

    private func requireEqual(_ field: String, _ actual: String?, _ expected: String?) throws {
        guard actual == expected else {
            throw PublikMobileDownloadError.packageIdentityMismatch(
                field: field,
                expected: expected ?? "null",
                actual: actual ?? "null"
            )
        }
    }

    private static func isAllowedPublikURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == allowedOriginScheme
            && components.host?.lowercased() == allowedOriginHost
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
            && !components.path.isEmpty
    }
}

// MARK: - Catalog v2 (index.json / index-<n>.json, categories.json, apps/<slug>.json)
//
// Unit m3-catalog-contract-scale. Fetches catalog/browse data only, never an
// install authorization: `fetchAppPage`'s `mobileShell` field is verified
// through the exact same `validatedDescriptor`/`validateDescriptor` path as
// the v1 catalog, and `download(_:)` above is unchanged. Every request goes
// through `perform`, so the same allowlisted transport (https publikhq.com,
// GET, identity encoding, no caches, no redirects) and the same byte caps
// apply. See mobile-shell/contracts/CONTRACT.md, "Catalog index v2".
extension PublikMobileCatalogClient {
    public static let catalogIndexV2MaximumBytes = 2 * 1024 * 1024
    public static let catalogAppPageV2MaximumBytes = 256 * 1024
    public static let catalogCategoriesV2MaximumBytes = 64 * 1024
    /// Icon fetch cap. The host check runs before any request is made, so a
    /// foreign or lookalike icon host is refused outright, not merely capped.
    public static let catalogIconMaximumBytes = 64 * 1024

    static let catalogV2AppsPerPage = 250
    static let catalogV2MaximumCategories = 24
    static let catalogV2MaximumSummaryCharacters = 80
    static let catalogV2KnownAgeRatings: Set<Int> = [4, 9, 13, 16, 18]
    static let catalogV2KnownBadges: Set<String> = ["new", "updated"]

    static func catalogIndexV2URL(page: Int) -> URL {
        page <= 1
            ? URL(string: "https://publikhq.com/api/iris/mobile/index.json")!
            : URL(string: "https://publikhq.com/api/iris/mobile/index-\(page).json")!
    }

    static let catalogCategoriesV2URL = URL(string: "https://publikhq.com/api/iris/mobile/categories.json")!

    static func catalogAppPageV2URL(slug: String) -> URL {
        URL(string: "https://publikhq.com/api/iris/mobile/apps/\(slug).json")!
    }

    static func indexCacheKey(page: Int) -> String { "index-\(page)" }
    static let categoriesCacheKey = "categories"
    static func appPageCacheKey(slug: String) -> String { "app-\(slug)" }

    public struct FetchedCatalogDocument<Value: Sendable>: Sendable {
        public let value: Value
        public let etag: String?
        /// True when Publik answered 304 and `value` came from the on-disk
        /// cache rather than a fresh body.
        public let notModified: Bool
    }

    /// Reads and decodes a cached index page from disk only, with no network
    /// call, so page 1 can be shown before first paint whenever a cache
    /// exists, even while a refresh is stalled. Returns nil on a cache miss
    /// or a cache entry that no longer decodes.
    public func cachedIndexPage(_ page: Int, cache: PublikMobileCatalogCache) async -> PublikMobileCatalogIndexPageV2? {
        guard let cached = await cache.read(key: Self.indexCacheKey(page: page)) else { return nil }
        return try? decodeCatalogIndexPageV2(cached.body, expectedPage: page)
    }

    /// Fetches one catalog v2 index page. When `cache` holds a usable copy
    /// with an ETag, sends it as `If-None-Match`; a 304 reuses the cached
    /// copy and restarts its 24 hour stale window. A fresh 200 is decoded and
    /// validated before it is cached, so a bad body never enters the cache.
    /// A 404 for page 1 is reported as `.catalogIndexV2Unavailable` so the
    /// caller can fall back to `/api/iris/apps`.
    public func fetchIndexPage(
        _ page: Int,
        cache: PublikMobileCatalogCache?,
        now: Date = Date()
    ) async throws -> FetchedCatalogDocument<PublikMobileCatalogIndexPageV2> {
        guard page >= 1 else { throw PublikMobileDownloadError.invalidCatalogField("page") }
        return try await fetchCatalogDocumentConditionally(
            url: Self.catalogIndexV2URL(page: page),
            cacheKey: Self.indexCacheKey(page: page),
            cache: cache,
            maximumBytes: Self.catalogIndexV2MaximumBytes,
            treatNotFoundAsIndexV2Unavailable: page == 1,
            now: now,
            decode: { try self.decodeCatalogIndexPageV2($0, expectedPage: page) }
        )
    }

    public func fetchCategories(
        cache: PublikMobileCatalogCache?,
        now: Date = Date()
    ) async throws -> FetchedCatalogDocument<PublikMobileCatalogCategoriesV2> {
        try await fetchCatalogDocumentConditionally(
            url: Self.catalogCategoriesV2URL,
            cacheKey: Self.categoriesCacheKey,
            cache: cache,
            maximumBytes: Self.catalogCategoriesV2MaximumBytes,
            treatNotFoundAsIndexV2Unavailable: false,
            now: now,
            decode: { try self.decodeCatalogCategoriesV2($0) }
        )
    }

    /// Fetches one app's detail page (`apps/<slug>.json`) on demand, only
    /// when that app's page is opened; it is never bulk-fetched.
    public func fetchAppPage(
        slug: String,
        cache: PublikMobileCatalogCache?,
        now: Date = Date()
    ) async throws -> FetchedCatalogDocument<PublikMobileCatalogAppPageV2> {
        guard NativeSecurity.isStableId(slug) else {
            throw PublikMobileDownloadError.invalidCatalogField("slug")
        }
        return try await fetchCatalogDocumentConditionally(
            url: Self.catalogAppPageV2URL(slug: slug),
            cacheKey: Self.appPageCacheKey(slug: slug),
            cache: cache,
            maximumBytes: Self.catalogAppPageV2MaximumBytes,
            treatNotFoundAsIndexV2Unavailable: false,
            now: now,
            decode: { try self.decodeCatalogAppPageV2($0) }
        )
    }

    /// The catalog v2 app page's descriptor as an installable catalog app,
    /// for the unchanged `download(_:)` path.
    public func installableApp(
        slug: String,
        name: String,
        appPage: PublikMobileCatalogAppPageV2
    ) -> PublikMobileCatalogApp {
        PublikMobileCatalogApp(
            slug: slug,
            name: name,
            guideSlug: nil,
            macBundleId: nil,
            latestReleaseTag: nil,
            mobileShell: appPage.mobileShell
        )
    }

    /// Downloads one catalog icon through the same allowlisted transport as
    /// every other Publik fetch: publikhq.com HTTPS only, no redirects, PNG,
    /// at most `catalogIconMaximumBytes`. When `expectedIconHash` is given
    /// (the index row's `iconHash`), the bytes must hash to it, so a
    /// different app's artwork is never shown under this app's name.
    public func fetchIcon(_ url: URL, expectedIconHash: String?) async throws -> Data {
        guard Self.isAllowedPublikURL(url) else {
            throw PublikMobileDownloadError.disallowedURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let response = try await perform(request, maximumBytes: Self.catalogIconMaximumBytes, progress: nil)
        try validateResponse(response, for: request, expectedMIME: "image/png")
        if let declared = response.declaredContentLength, declared != response.body.count {
            throw PublikMobileDownloadError.responseLengthMismatch(expected: declared, actual: response.body.count)
        }
        if let expectedIconHash {
            let actual = String(NativeSecurity.sha256(response.body).dropFirst("sha256:".count).prefix(16))
            guard actual == expectedIconHash else {
                throw PublikMobileDownloadError.iconDigestMismatch(expected: expectedIconHash, actual: actual)
            }
        }
        return response.body
    }

    public func fetchIcon(for app: PublikMobileCatalogIndexAppV2) async throws -> Data {
        try await fetchIcon(app.iconURL, expectedIconHash: app.iconHash)
    }

    private func fetchCatalogDocumentConditionally<Value: Sendable>(
        url: URL,
        cacheKey: String,
        cache: PublikMobileCatalogCache?,
        maximumBytes: Int,
        treatNotFoundAsIndexV2Unavailable: Bool,
        now: Date,
        decode: (Data) throws -> Value
    ) async throws -> FetchedCatalogDocument<Value> {
        // Offer the cached ETag only when the cached copy still decodes:
        // otherwise a damaged cache entry would be "confirmed" by a 304 on
        // every launch and the catalog could never load again.
        var usable: (etag: String, value: Value)?
        if let cached = await cache?.read(key: cacheKey), let etag = cached.etag, let value = try? decode(cached.body) {
            usable = (etag, value)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let etag = usable?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        // A 404 surfaces two ways: the real transport's delegate throws
        // `unexpectedStatus(404)` before handing back a response, while an
        // injected transport may return a response whose status is 404.
        let response: PublikMobileHTTPResponse
        do {
            response = try await perform(request, maximumBytes: maximumBytes, progress: nil)
        } catch PublikMobileDownloadError.unexpectedStatus(404) where treatNotFoundAsIndexV2Unavailable {
            throw PublikMobileDownloadError.catalogIndexV2Unavailable
        }
        guard response.finalURL == request.url else {
            throw PublikMobileDownloadError.redirectRejected
        }
        if treatNotFoundAsIndexV2Unavailable, response.statusCode == 404 {
            throw PublikMobileDownloadError.catalogIndexV2Unavailable
        }
        if response.statusCode == 304 {
            guard let usable else { throw PublikMobileDownloadError.unexpectedStatus(304) }
            await cache?.markRevalidated(key: cacheKey, now: now)
            return FetchedCatalogDocument(value: usable.value, etag: usable.etag, notModified: true)
        }
        if (300..<400).contains(response.statusCode) {
            throw PublikMobileDownloadError.redirectRejected
        }
        guard response.statusCode == 200 else {
            throw PublikMobileDownloadError.unexpectedStatus(response.statusCode)
        }
        guard response.mimeType?.lowercased() == "application/json" else {
            throw PublikMobileDownloadError.unexpectedMIME(expected: "application/json", actual: response.mimeType)
        }
        if let declared = response.declaredContentLength, declared != response.body.count {
            throw PublikMobileDownloadError.responseLengthMismatch(expected: declared, actual: response.body.count)
        }
        let value = try decode(response.body)
        if let cache {
            _ = try? await cache.write(key: cacheKey, body: response.body, etag: response.etag, now: now)
        }
        return FetchedCatalogDocument(value: value, etag: response.etag, notModified: false)
    }

    func decodeCatalogIndexPageV2(_ body: Data, expectedPage: Int) throws -> PublikMobileCatalogIndexPageV2 {
        let wire: PublikMobileCatalogIndexPageWireV2
        do {
            wire = try JSONDecoder().decode(PublikMobileCatalogIndexPageWireV2.self, from: body)
        } catch {
            throw PublikMobileDownloadError.malformedCatalog
        }
        guard wire.version == 2 else {
            throw PublikMobileDownloadError.unsupportedDescriptorVersion(wire.version)
        }
        guard NativeSecurity.isCanonicalISOInstant(wire.generatedAt) else {
            throw PublikMobileDownloadError.invalidCatalogField("generatedAt")
        }
        guard wire.page == expectedPage, wire.pageCount >= wire.page, wire.apps.count <= Self.catalogV2AppsPerPage else {
            throw PublikMobileDownloadError.invalidCatalogField("page")
        }

        var slugs = Set<String>()
        var apps: [PublikMobileCatalogIndexAppV2] = []
        apps.reserveCapacity(wire.apps.count)
        for row in wire.apps {
            guard NativeSecurity.isStableId(row.slug), slugs.insert(row.slug).inserted else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.slug")
            }
            guard !row.name.isEmpty, row.name.count <= 120 else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.name")
            }
            guard !row.summary.isEmpty, row.summary.count <= Self.catalogV2MaximumSummaryCharacters else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.summary")
            }
            guard (1...3).contains(row.categoryIds.count),
                  Set(row.categoryIds).count == row.categoryIds.count,
                  row.categoryIds.allSatisfy({ (1...Self.catalogV2MaximumCategories).contains($0) }) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.categoryIds")
            }
            guard Self.isIconHash(row.iconHash) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.iconHash")
            }
            guard let iconURL = URL(string: row.iconURL), Self.isAllowedPublikURL(iconURL) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.iconURL")
            }
            guard (1...DeliveryPackageV1Validator.maximumRawPackageBytes).contains(row.byteCount) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.byteCount")
            }
            guard Self.catalogV2KnownAgeRatings.contains(row.ageRating) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.ageRating")
            }
            guard Self.isCalendarDate(row.updatedAt) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.updatedAt")
            }
            guard Set(row.badges).count == row.badges.count,
                  row.badges.allSatisfy({ Self.catalogV2KnownBadges.contains($0) }) else {
                throw PublikMobileDownloadError.invalidCatalogField("apps.badges")
            }
            var placement: PublikMobileCatalogPlacementV2?
            if let wirePlacement = row.placement {
                guard wirePlacement.featured || wirePlacement.sponsored,
                      !wirePlacement.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      wirePlacement.label.count <= 40 else {
                    throw PublikMobileDownloadError.invalidCatalogField("apps.placement")
                }
                placement = PublikMobileCatalogPlacementV2(
                    featured: wirePlacement.featured,
                    sponsored: wirePlacement.sponsored,
                    label: wirePlacement.label
                )
            }
            // R2-CP-3: optional and backward compatible. Absent (older
            // published index) or explicit JSON null both decode to `nil`
            // above and are accepted here unchanged -- only a *present*,
            // non-null value is checked, and it must be a real revision id
            // shape, never an arbitrary string a compromised or malformed
            // catalog host could use to spoof "Update available".
            var latestRevisionId: String?
            if let candidate = row.latestRevisionId {
                guard NativeSecurity.isRevisionId(candidate) else {
                    throw PublikMobileDownloadError.invalidCatalogField("apps.latestRevisionId")
                }
                latestRevisionId = candidate
            }
            // RC-05: an absent publisher is fine (shown as Publik); a present one
            // must be a short plain name, never markup, control characters or a
            // blank string a catalog host could use to spoof another maker.
            if let candidate = row.publisher, !StoreApp.isValidPublisherName(candidate) {
                throw PublikMobileDownloadError.invalidCatalogField("apps.publisher")
            }
            apps.append(
                PublikMobileCatalogIndexAppV2(
                    slug: row.slug,
                    name: row.name,
                    summary: row.summary,
                    categoryIds: row.categoryIds,
                    iconHash: row.iconHash,
                    iconURL: iconURL,
                    byteCount: row.byteCount,
                    ageRating: row.ageRating,
                    updatedAt: row.updatedAt,
                    badges: row.badges,
                    placement: placement,
                    latestRevisionId: latestRevisionId,
                    publisher: row.publisher
                )
            )
        }
        return PublikMobileCatalogIndexPageV2(
            version: wire.version,
            generatedAt: wire.generatedAt,
            page: wire.page,
            pageCount: wire.pageCount,
            apps: apps
        )
    }

    private func decodeCatalogCategoriesV2(_ body: Data) throws -> PublikMobileCatalogCategoriesV2 {
        let wire: PublikMobileCatalogCategoriesWireV2
        do {
            wire = try JSONDecoder().decode(PublikMobileCatalogCategoriesWireV2.self, from: body)
        } catch {
            throw PublikMobileDownloadError.malformedCatalog
        }
        guard wire.categories.count <= Self.catalogV2MaximumCategories else {
            throw PublikMobileDownloadError.invalidCatalogField("categories")
        }
        var seenIds = Set<Int>()
        let categories = try wire.categories.map { row -> PublikMobileCatalogCategoryV2 in
            guard row.id >= 1, seenIds.insert(row.id).inserted else {
                throw PublikMobileDownloadError.invalidCatalogField("categories.id")
            }
            guard !row.name.isEmpty, row.name.count <= 60, row.order >= 0, row.appCount >= 0 else {
                throw PublikMobileDownloadError.invalidCatalogField("categories")
            }
            return PublikMobileCatalogCategoryV2(id: row.id, name: row.name, order: row.order, appCount: row.appCount)
        }
        return PublikMobileCatalogCategoriesV2(categories: categories)
    }

    private func decodeCatalogAppPageV2(_ body: Data) throws -> PublikMobileCatalogAppPageV2 {
        let wire: PublikMobileCatalogAppPageWireV2
        do {
            wire = try JSONDecoder().decode(PublikMobileCatalogAppPageWireV2.self, from: body)
        } catch {
            throw PublikMobileDownloadError.malformedCatalog
        }
        let mobileShell = try validatedDescriptor(wire.mobileShell)
        guard wire.screenshots.count <= 6 else {
            throw PublikMobileDownloadError.invalidCatalogField("screenshots")
        }
        let screenshots = try wire.screenshots.map { row -> PublikMobileCatalogScreenshotV2 in
            guard let url = URL(string: row.url), Self.isAllowedPublikURL(url) else {
                throw PublikMobileDownloadError.invalidCatalogField("screenshots.url")
            }
            guard row.bytes >= 1, row.bytes <= 400 * 1024 else {
                throw PublikMobileDownloadError.invalidCatalogField("screenshots.bytes")
            }
            return PublikMobileCatalogScreenshotV2(url: url, bytes: row.bytes)
        }
        let permissions = try wire.permissions.map { row -> PublikMobileCatalogPermissionV2 in
            guard NativeSecurity.knownCapabilities.contains(row.capability) else {
                throw PublikMobileDownloadError.invalidCatalogField("permissions.capability")
            }
            return PublikMobileCatalogPermissionV2(capability: row.capability, label: row.label)
        }
        guard let supportURL = URL(string: wire.supportURL), supportURL.scheme?.lowercased() == "https", supportURL.host != nil else {
            throw PublikMobileDownloadError.invalidCatalogField("supportURL")
        }
        return PublikMobileCatalogAppPageV2(
            mobileShell: mobileShell,
            description: wire.description,
            screenshots: screenshots,
            permissions: permissions,
            privacySummary: wire.privacySummary,
            supportURL: supportURL,
            whatsNew: wire.whatsNew
        )
    }

    static func isIconHash(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// `YYYY-MM-DD` naming a real Gregorian day (leap years included).
    /// Checked arithmetically: this runs for every row of every page.
    static func isCalendarDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        func number(_ range: Range<Int>) -> Int? {
            var result = 0
            for index in range {
                guard (48...57).contains(bytes[index]) else { return nil }
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              year >= 1, (1...12).contains(month), day >= 1 else {
            return false
        }
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= daysInMonth
    }
}

// MARK: - Catalog v2 loading for Browse (first paint, background refresh)

/// What Browse shows: index pages 1...n from one publish, in order.
public struct PublikMobileCatalogV2Snapshot: Equatable, Sendable {
    public let generatedAt: String
    public let pageCount: Int
    /// Consecutive pages starting at page 1, all from the same publish
    /// (same `generatedAt` and `pageCount`). May be shorter than
    /// `pageCount` while the rest are still loading or were not cached.
    public let pages: [PublikMobileCatalogIndexPageV2]
    /// When Publik last confirmed page 1 (a fresh download or a 304).
    public let lastCheckedAt: Date
    /// True when that check is more than 24 hours old: Browse still shows the
    /// catalog, with its "Showing the last successful check" line.
    public let isStale: Bool

    public var isComplete: Bool { pages.count == pageCount }
    public var apps: [PublikMobileCatalogIndexAppV2] { pages.flatMap(\.apps) }
}

public enum PublikMobileCatalogV2RefreshResult: Equatable, Sendable {
    /// Index v2 loaded (every page, consistent with page 1).
    case catalog(PublikMobileCatalogV2Snapshot)
    /// Publik has no index v2 yet (index.json is 404); this is the v1
    /// `/api/iris/apps` catalog instead.
    case legacy([PublikMobileCatalogApp])
}

/// Loads the catalog v2 index for Browse.
///
/// - `cachedSnapshot()` reads only the disk cache, so a caller can paint
///   page 1 (and any other cached pages of the same publish) before any
///   network request finishes, or while the network is stalled.
/// - `refresh(onFirstPage:)` makes one conditional request for page 1. When
///   Publik answers 304 and every other page of that publish is cached, the
///   launch is done after that one request. Otherwise page 1 is handed to
///   `onFirstPage` as soon as it is ready and the remaining pages load
///   after it. When index v2 is not published (404), it falls back to the v1
///   catalog.
public struct PublikMobileCatalogV2Loader: Sendable {
    private let client: PublikMobileCatalogClient
    private let cache: PublikMobileCatalogCache
    private let now: @Sendable () -> Date

    public init(
        client: PublikMobileCatalogClient,
        cache: PublikMobileCatalogCache,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.cache = cache
        self.now = now
    }

    public func cachedSnapshot() async -> PublikMobileCatalogV2Snapshot? {
        guard let firstDocument = await cache.read(key: PublikMobileCatalogClient.indexCacheKey(page: 1)),
              let first = try? client.decodeCatalogIndexPageV2(firstDocument.body, expectedPage: 1) else {
            return nil
        }
        var pages = [first]
        var slugs = Set(first.apps.map(\.slug))
        if first.pageCount > 1 {
            for number in 2...first.pageCount {
                guard let page = await cachedPage(number, consistentWith: first),
                      Self.addSlugs(of: page, to: &slugs) else { break }
                pages.append(page)
            }
        }
        return PublikMobileCatalogV2Snapshot(
            generatedAt: first.generatedAt,
            pageCount: first.pageCount,
            pages: pages,
            lastCheckedAt: firstDocument.cachedAt,
            isStale: firstDocument.isStale(now: now())
        )
    }

    public func refresh(
        onFirstPage: (@Sendable (PublikMobileCatalogV2Snapshot) async -> Void)? = nil
    ) async throws -> PublikMobileCatalogV2RefreshResult {
        let first: PublikMobileCatalogClient.FetchedCatalogDocument<PublikMobileCatalogIndexPageV2>
        do {
            first = try await client.fetchIndexPage(1, cache: cache, now: now())
        } catch PublikMobileDownloadError.catalogIndexV2Unavailable {
            return .legacy(try await client.fetchCatalog())
        }
        let checkedAt = now()
        let firstPage = first.value
        var pages = [firstPage]
        var slugs = Set(firstPage.apps.map(\.slug))
        func snapshot() -> PublikMobileCatalogV2Snapshot {
            PublikMobileCatalogV2Snapshot(
                generatedAt: firstPage.generatedAt,
                pageCount: firstPage.pageCount,
                pages: pages,
                lastCheckedAt: checkedAt,
                isStale: false
            )
        }
        await onFirstPage?(snapshot())
        if firstPage.pageCount > 1 {
            for number in 2...firstPage.pageCount {
                // Page 1 unchanged (304) means this publish is unchanged: a
                // cached page with the same generatedAt is current as-is.
                if first.notModified,
                   let cached = await cachedPage(number, consistentWith: firstPage),
                   Self.addSlugs(of: cached, to: &slugs) {
                    pages.append(cached)
                    continue
                }
                let fetched = try await client.fetchIndexPage(number, cache: cache, now: now()).value
                guard fetched.generatedAt == firstPage.generatedAt, fetched.pageCount == firstPage.pageCount else {
                    throw PublikMobileDownloadError.invalidCatalogField("index page \(number) is from a different publish")
                }
                guard Self.addSlugs(of: fetched, to: &slugs) else {
                    throw PublikMobileDownloadError.invalidCatalogField("apps.slug")
                }
                pages.append(fetched)
            }
        }
        return .catalog(snapshot())
    }

    /// Adds a page's slugs to `slugs`; false when any of them is already
    /// listed on an earlier page (one app must be one row).
    private static func addSlugs(of page: PublikMobileCatalogIndexPageV2, to slugs: inout Set<String>) -> Bool {
        for app in page.apps where !slugs.insert(app.slug).inserted {
            return false
        }
        return true
    }

    private func cachedPage(
        _ number: Int,
        consistentWith first: PublikMobileCatalogIndexPageV2
    ) async -> PublikMobileCatalogIndexPageV2? {
        guard let document = await cache.read(key: PublikMobileCatalogClient.indexCacheKey(page: number)),
              let page = try? client.decodeCatalogIndexPageV2(document.body, expectedPage: number),
              page.generatedAt == first.generatedAt,
              page.pageCount == first.pageCount else {
            return nil
        }
        return page
    }
}
