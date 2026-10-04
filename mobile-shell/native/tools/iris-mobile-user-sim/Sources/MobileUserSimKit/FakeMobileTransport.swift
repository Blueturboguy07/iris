import Foundation
import IrisMobileShellCore

/// The device's network boundary, faked. Everything above this (request
/// shape, header checks, redirect/MIME/length/digest validation, JSON
/// decoding of the catalog envelope, per-field catalog validation) is real
/// `PublikMobileCatalogClient` production code; this type only decides
/// whether/when/what bytes a GET to a registered URL returns.
public final class FakeMobileTransport: PublikMobileHTTPTransport, @unchecked Sendable {
    private let world: DeviceWorld
    private let lock = NSLock()
    private var liveCatalogBody: Data = Data("{\"apps\":[]}".utf8)
    private var staleCatalogBody: Data?
    private var packagesByURL: [URL: Data] = [:]
    private var failingURLs: Set<URL> = []

    public init(world: DeviceWorld) {
        self.world = world
    }

    public func setLiveCatalog(_ body: Data) {
        setLiveCatalogLocked(body)
    }

    /// Registers the fixed "old" catalog snapshot served whenever the world's
    /// network condition is `.catalogStale`, independent of whatever the
    /// current live catalog has become. This is what lets a scenario prove
    /// the shell never uses a stale catalog entry to skip past an already
    /// installed newer revision.
    public func setStaleCatalog(_ body: Data) {
        setStaleCatalogLocked(body)
    }

    public func registerPackage(at url: URL, bytes: Data) {
        registerPackageLocked(url: url, bytes: bytes)
    }

    /// Makes every GET to `url` drop mid-connection (a page that never
    /// arrives), independent of the world's overall network condition.
    /// R2-mobile-integration: catalog page 2 failing while page 1 loads.
    public func failRequests(to url: URL) {
        setFailingLocked(url, failing: true)
    }

    public func stopFailingRequests(to url: URL) {
        setFailingLocked(url, failing: false)
    }

    public func get(
        _ request: URLRequest,
        maximumBytes: Int,
        progress: (@Sendable (Int) -> Void)?
    ) async throws -> PublikMobileHTTPResponse {
        let outcome = world.decideNetworkOutcome()
        switch outcome {
        case .fail(.offline):
            world.record("network-request-failed", "offline: \(request.url?.absoluteString ?? "?")")
            throw URLError(.notConnectedToInternet)
        case .fail(.flakyDrop):
            world.record("network-request-failed", "flaky drop: \(request.url?.absoluteString ?? "?")")
            throw URLError(.networkConnectionLost)
        case .proceed(let extraLatencySeconds):
            if extraLatencySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(extraLatencySeconds * 1_000_000_000))
            }
        }

        guard let url = request.url else { throw FakeMobileTransportError.noRegisteredResponse("<nil>") }
        if isFailingLocked(url) {
            world.record("network-request-failed", "dropped: \(url.absoluteString)")
            throw URLError(.networkConnectionLost)
        }
        world.record("network-request-served", url.absoluteString)

        if url == PublikMobileCatalogClient.catalogURL {
            let body = catalogBodyLocked(for: world.currentNetwork())
            guard body.count <= maximumBytes else {
                throw FakeMobileTransportError.responseExceedsLimit(url.absoluteString)
            }
            progress?(body.count)
            return PublikMobileHTTPResponse(
                statusCode: 200,
                mimeType: "application/json",
                declaredContentLength: body.count,
                finalURL: url,
                body: body
            )
        }

        guard let package = registeredPackageLocked(url: url) else {
            throw FakeMobileTransportError.noRegisteredResponse(url.absoluteString)
        }
        guard package.count <= maximumBytes else {
            throw FakeMobileTransportError.responseExceedsLimit(url.absoluteString)
        }
        // Report progress in a couple of chunks so persona code that watches
        // download progress (P2 backgrounding mid-install) has something real
        // to observe, without needing a byte-for-byte streaming simulation.
        if package.count > 0 {
            progress?(package.count / 2)
        }
        progress?(package.count)
        return PublikMobileHTTPResponse(
            statusCode: 200,
            mimeType: "application/json",
            declaredContentLength: package.count,
            finalURL: url,
            body: package
        )
    }

    // These small synchronous (non-async) helpers exist so the lock is never
    // taken from directly within an `async` function body, which newer SDKs
    // flag even when the lock is never held across a suspension point.
    private func setLiveCatalogLocked(_ body: Data) {
        lock.lock()
        liveCatalogBody = body
        lock.unlock()
    }

    private func setStaleCatalogLocked(_ body: Data) {
        lock.lock()
        staleCatalogBody = body
        lock.unlock()
    }

    private func registerPackageLocked(url: URL, bytes: Data) {
        lock.lock()
        packagesByURL[url] = bytes
        lock.unlock()
    }

    private func setFailingLocked(_ url: URL, failing: Bool) {
        lock.lock()
        if failing { failingURLs.insert(url) } else { failingURLs.remove(url) }
        lock.unlock()
    }

    private func isFailingLocked(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failingURLs.contains(url)
    }

    private func catalogBodyLocked(for condition: SimulatedNetworkCondition) -> Data {
        lock.lock()
        defer { lock.unlock() }
        switch condition {
        case .catalogEmpty:
            return Data("{\"apps\":[]}".utf8)
        case .catalogStale:
            return staleCatalogBody ?? liveCatalogBody
        default:
            return liveCatalogBody
        }
    }

    private func registeredPackageLocked(url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return packagesByURL[url]
    }
}

public enum FakeMobileTransportError: Error, Equatable, CustomStringConvertible {
    case noRegisteredResponse(String)
    case responseExceedsLimit(String)

    public var description: String {
        switch self {
        case .noRegisteredResponse(let url): return "no scenario response registered for \(url)"
        case .responseExceedsLimit(let url): return "registered response for \(url) exceeds the caller's byte limit"
        }
    }
}
