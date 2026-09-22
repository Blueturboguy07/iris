import Foundation

nonisolated enum CatalogAppIconPolicy {
    static let maximumImageBytes = 128 * 1024
    static let maximumConcurrentDownloads = 3
    static let maximumCachedIcons = 64
    static let maximumQueuedIcons = 32

    /// Actual application assets from the public repositories linked by each
    /// publik listing. Do not substitute competitor logos or social banners.
    static let verifiedAssets: [String: String] = [
        "astro": "https://raw.githubusercontent.com/Blueturboguy07/Astro/main/packages/browseros/resources/browseros/icons/product_logo_64.png",
        "whimprflow": "https://raw.githubusercontent.com/Blueturboguy07/WhimprFlow/main/src-tauri/icons/64x64.png",
        "hickeyfield": "https://raw.githubusercontent.com/Blueturboguy07/hickeyfield/main/src-tauri/icons/64x64.png",
        "nitroai": "https://raw.githubusercontent.com/Blueturboguy07/NitroAI/main/build-resources/icon.png",
    ]

    static func verifiedIconURL(forSlug slug: String) -> URL? {
        verifiedAssets[slug].flatMap(validatedPublicIconURL)
    }

    static func validatedPublicIconURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["publikhq.com", "www.publikhq.com", "raw.githubusercontent.com"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              !components.path.split(separator: "/").contains(".."),
              components.path.lowercased().hasSuffix(".png"),
              let url = components.url else { return nil }
        return url
    }

    static func acceptsResponse(statusCode: Int, mimeType: String?, expectedBytes: Int64) -> Bool {
        statusCode == 200 && mimeType?.lowercased() == "image/png"
            && expectedBytes <= Int64(maximumImageBytes)
    }

    static func fallbackInitial(for name: String) -> String {
        let initial = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
            .trimmingCharacters(in: .controlCharacters)
        return initial.isEmpty ? "?" : initial
    }
}

/// Checks every chunk, including responses with no Content-Length.
nonisolated struct CatalogIconByteBuffer {
    private(set) var data = Data()

    mutating func append(_ chunk: Data) -> Bool {
        guard chunk.count <= CatalogAppIconPolicy.maximumImageBytes - data.count else { return false }
        data.append(chunk)
        return true
    }
}

/// Shared across all rows. Each URL is fetched once per session, failures are
/// cached too, and duplicate requests share a result. No files or cookies.
actor CatalogAppIconLoader {
    static let shared = CatalogAppIconLoader()
    typealias Fetch = @Sendable (URL) async -> Data?
    private enum CachedIcon { case loaded(Data), unavailable }
    private var cached: [URL: CachedIcon] = [:]
    private var cacheOrder: [URL] = []
    private var waiters: [URL: [CheckedContinuation<Data?, Never>]] = [:]
    private var queued: [URL] = []
    private var activeDownloads = 0
    private let fetch: Fetch

    init(fetch: @escaping Fetch = { await BoundedPublicIconDownload.fetch($0) }) {
        self.fetch = fetch
    }

    func imageData(for url: URL) async -> Data? {
        guard !Task.isCancelled,
              CatalogAppIconPolicy.validatedPublicIconURL(url.absoluteString) != nil else { return nil }
        if let result = cached[url] {
            if case .loaded(let data) = result { return data }
            return nil
        }
        guard (waiters[url]?.count ?? 0) < 16,
              waiters[url] != nil || queued.count < CatalogAppIconPolicy.maximumQueuedIcons else { return nil }
        return await withCheckedContinuation { continuation in
            if waiters[url] != nil {
                waiters[url]?.append(continuation)
            } else {
                waiters[url] = [continuation]
                queued.append(url)
            }
            startAvailableDownloads()
        }
    }

    private func startAvailableDownloads() {
        while activeDownloads < CatalogAppIconPolicy.maximumConcurrentDownloads, !queued.isEmpty {
            let url = queued.removeFirst()
            activeDownloads += 1
            let fetch = self.fetch
            Task {
                let downloadedData = await fetch(url)
                self.finished(url: url, data: downloadedData)
            }
        }
    }

    private func finished(url: URL, data: Data?) {
        let boundedData = data.flatMap { $0.count <= CatalogAppIconPolicy.maximumImageBytes ? $0 : nil }
        if cached.count >= CatalogAppIconPolicy.maximumCachedIcons, !cacheOrder.isEmpty {
            cached.removeValue(forKey: cacheOrder.removeFirst())
        }
        cached[url] = boundedData.map(CachedIcon.loaded) ?? .unavailable
        cacheOrder.append(url)
        let pending = waiters.removeValue(forKey: url) ?? []
        activeDownloads -= 1
        pending.forEach { $0.resume(returning: boundedData) }
        startAvailableDownloads()
    }
}

private nonisolated final class BoundedPublicIconDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var buffer = CatalogIconByteBuffer()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var session: URLSession?

    static func fetch(_ url: URL) async -> Data? {
        guard CatalogAppIconPolicy.validatedPublicIconURL(url.absoluteString) != nil else { return nil }
        return await withCheckedContinuation { continuation in
            let download = BoundedPublicIconDownload()
            download.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 6
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: download, delegateQueue: queue)
            download.session = session
            var request = URLRequest(url: url)
            request.setValue("image/png", forHTTPHeaderField: "Accept")
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              CatalogAppIconPolicy.validatedPublicIconURL(url.absoluteString) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              CatalogAppIconPolicy.acceptsResponse(statusCode: response.statusCode,
                  mimeType: response.mimeType, expectedBytes: response.expectedContentLength) else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.append(data) else {
            dataTask.cancel()
            finish(nil)
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error == nil && !buffer.data.isEmpty ? buffer.data : nil)
    }

    private func finish(_ data: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: data)
        session?.invalidateAndCancel()
        session = nil
    }
}
