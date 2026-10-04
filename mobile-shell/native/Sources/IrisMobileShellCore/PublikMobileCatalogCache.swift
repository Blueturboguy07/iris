import Foundation

/// An on-disk cache for catalog v2 JSON (index pages, categories.json, app
/// detail pages), keyed by a short caller-chosen string ("index-1",
/// "categories", "app-<slug>", ...). Bounded to
/// `PublikMobileCatalogCache.maximumJSONCacheBytes` (4 MB) of actual disk
/// usage (measured by allocated blocks, `st_blocks * 512`, not the logical
/// `st_size` a sparse or truncated file could under-report), with a
/// `staleAfter` (24 hour) stale-while-revalidate window: a cache read never
/// blocks on staleness, so page 1 can be shown immediately from cache while
/// a caller decides, separately, whether to also refresh it.
///
/// This cache stores only catalog/browse JSON. It never stores package
/// bytes, credentials, or anything the install path reads; a corrupted or
/// evicted cache entry can only make Browse show stale/missing rows, never
/// change what gets installed (see CONTRACT.md, "Catalog index v2").
public actor PublikMobileCatalogCache {
    public static let maximumJSONCacheBytes = 4 * 1024 * 1024
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    public struct CachedDocument: Sendable {
        public let body: Data
        public let etag: String?
        public let cachedAt: Date

        public func isStale(after interval: TimeInterval = PublikMobileCatalogCache.staleAfter, now: Date = Date()) -> Bool {
            now.timeIntervalSince(cachedAt) > interval
        }
    }

    private struct MetaFile: Codable {
        let etag: String?
        let cachedAtEpochSeconds: Double
    }

    private let directory: URL
    private let fileManager: FileManager
    private let maximumBytes: Int

    /// Disk usage per key (body plus metadata, by allocated blocks) and the
    /// time each was cached, loaded from disk once and then kept current by
    /// this actor, so a write never rescans the whole directory. One cache
    /// object should own a directory at a time.
    private struct Usage {
        var bytes: Int
        var cachedAt: Date
    }
    private var usageByKey: [String: Usage]?
    private var trackedBytes = 0

    /// `directory` is the cache's own private subdirectory (a caller in the
    /// app target passes something rooted in `FileManager.default.urls(for:
    /// .cachesDirectory, in: .userDomainMask)`, inside the app container);
    /// this type does not choose that root itself so it stays trivially
    /// testable with a temporary directory.
    public init(directory: URL, fileManager: FileManager = .default, maximumBytes: Int = PublikMobileCatalogCache.maximumJSONCacheBytes) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumBytes = maximumBytes
    }

    /// The cache the app uses: `Library/Caches/PublikCatalogV2` inside the
    /// app's own container. Caches is not backed up and the system may clear
    /// it under storage pressure, which is fine for a catalog that is always
    /// refetchable.
    public static func inAppContainer(fileManager: FileManager = .default) throws -> PublikMobileCatalogCache {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return PublikMobileCatalogCache(
            directory: caches.appendingPathComponent("PublikCatalogV2", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// Where this cache keeps its files.
    public nonisolated var directoryURL: URL { directory }

    /// Reads a cached document, if present and structurally valid. Never
    /// throws for "not cached" or "corrupted cache entry" (both return
    /// `nil`, as a fresh cache-miss would); this cache is a pure
    /// accelerator; a caller must always be able to fall back to network.
    public func read(key: String) -> CachedDocument? {
        guard NativeSecurity.isStableId(key) else { return nil }
        let bodyURL = bodyFileURL(for: key)
        let metaURL = metaFileURL(for: key)
        guard let bodyData = try? Data(contentsOf: bodyURL),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(MetaFile.self, from: metaData) else {
            return nil
        }
        return CachedDocument(
            body: bodyData,
            etag: meta.etag,
            cachedAt: Date(timeIntervalSince1970: meta.cachedAtEpochSeconds)
        )
    }

    /// Writes (or replaces) a cached document, then evicts until the cache's
    /// total on-disk size (by allocated blocks) is at or under
    /// `maximumBytes`. Eviction order (see `evictionRank`) keeps what first
    /// paint needs longest: app pages go first (oldest first), then index
    /// pages from the last page down, then categories, and index page 1
    /// last; the document just written is never evicted by its own write.
    /// A document larger than the whole budget is refused instead of
    /// emptying the cache for it. `now` is injectable for deterministic
    /// tests.
    @discardableResult
    public func write(key: String, body: Data, etag: String?, now: Date = Date()) throws -> CachedDocument {
        guard NativeSecurity.isStableId(key) else {
            throw PublikMobileCatalogCacheError.invalidKey(key)
        }
        guard body.count <= maximumBytes / 2 else {
            throw PublikMobileCatalogCacheError.documentTooLarge(key: key, bytes: body.count, budget: maximumBytes)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta = MetaFile(etag: etag, cachedAtEpochSeconds: now.timeIntervalSince1970)
        let metaData = try JSONEncoder().encode(meta)
        loadUsageIfNeeded()
        try body.write(to: bodyFileURL(for: key), options: .atomic)
        try metaData.write(to: metaFileURL(for: key), options: .atomic)
        track(key: key, cachedAt: now)
        evictIfOverBudget(protecting: key)
        return CachedDocument(body: body, etag: etag, cachedAt: now)
    }

    /// Records that the server confirmed a cached document is still current
    /// (HTTP 304): keeps the body and ETag, moves `cachedAt` to `now`, so the
    /// 24 hour stale window restarts from the last successful check.
    public func markRevalidated(key: String, now: Date = Date()) {
        guard NativeSecurity.isStableId(key),
              let metaData = try? Data(contentsOf: metaFileURL(for: key)),
              let meta = try? JSONDecoder().decode(MetaFile.self, from: metaData),
              let updated = try? JSONEncoder().encode(MetaFile(etag: meta.etag, cachedAtEpochSeconds: now.timeIntervalSince1970)) else {
            return
        }
        try? updated.write(to: metaFileURL(for: key), options: .atomic)
        if usageByKey != nil { track(key: key, cachedAt: now) }
    }

    /// Removes one cached document. Never throws when the key is simply
    /// absent.
    public func remove(key: String) {
        guard NativeSecurity.isStableId(key) else { return }
        try? fileManager.removeItem(at: bodyFileURL(for: key))
        try? fileManager.removeItem(at: metaFileURL(for: key))
        if let usage = usageByKey?.removeValue(forKey: key) {
            trackedBytes -= usage.bytes
        }
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
        usageByKey = nil
        trackedBytes = 0
    }

    /// Total bytes this cache actually occupies on disk, summed from each
    /// file's allocated block count (`st_blocks * 512`), which is the
    /// oracle the client/cache test suite checks against the 4 MB budget
    /// (a file's logical `st_size` can understate real disk usage, and this
    /// cache would rather over-count and evict early than silently exceed
    /// its budget).
    public func totalBytesOnDisk() -> Int {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return entries.reduce(0) { total, url in total + allocatedBytes(of: url) }
    }

    private func loadUsageIfNeeded() {
        guard usageByKey == nil else { return }
        var usage: [String: Usage] = [:]
        var total = 0
        let entries = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            let name = url.lastPathComponent
            let bytes = allocatedBytes(of: url)
            total += bytes
            let key: String
            if name.hasSuffix(".meta.json") {
                key = String(name.dropLast(".meta.json".count))
            } else if name.hasSuffix(".json") {
                key = String(name.dropLast(".json".count))
            } else {
                continue // not ours; counted in the total, never evicted
            }
            usage[key, default: Usage(bytes: 0, cachedAt: .distantPast)].bytes += bytes
        }
        for key in usage.keys {
            if let metaData = try? Data(contentsOf: metaFileURL(for: key)),
               let meta = try? JSONDecoder().decode(MetaFile.self, from: metaData) {
                usage[key]?.cachedAt = Date(timeIntervalSince1970: meta.cachedAtEpochSeconds)
            }
            // A body without readable metadata keeps .distantPast: it is
            // unusable, so it goes first.
        }
        usageByKey = usage
        trackedBytes = total
    }

    private func track(key: String, cachedAt: Date) {
        let bytes = allocatedBytes(of: bodyFileURL(for: key)) + allocatedBytes(of: metaFileURL(for: key))
        trackedBytes += bytes - (usageByKey?[key]?.bytes ?? 0)
        usageByKey?[key] = Usage(bytes: bytes, cachedAt: cachedAt)
    }

    private func evictIfOverBudget(protecting protectedKey: String) {
        guard trackedBytes > maximumBytes, let usage = usageByKey else { return }
        let candidates = usage
            .filter { $0.key != protectedKey }
            .map { (key: $0.key, rank: Self.evictionRank(forKey: $0.key), cachedAt: $0.value.cachedAt) }
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.cachedAt < rhs.cachedAt
            }
        for candidate in candidates {
            guard trackedBytes > maximumBytes else { break }
            remove(key: candidate.key)
        }
    }

    /// Lower rank is evicted first. App pages (opened on demand, cheap to
    /// refetch) go first, then categories, then index pages from the highest
    /// page number down, so page 1, which first paint needs, outlives
    /// everything else.
    static func evictionRank(forKey key: String) -> Int {
        if key.hasPrefix("index-"), let page = Int(key.dropFirst("index-".count)), page >= 1 {
            return 1_000_000 - min(page, 999_999)
        }
        if key == "categories" { return 500_000 }
        return 0
    }

    private func allocatedBytes(of url: URL) -> Int {
        var status = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return stat(path, &status) == 0
        }) else {
            return 0
        }
        // st_blocks is always in 512-byte units regardless of the
        // filesystem's own block size (see stat(2)).
        return Int(status.st_blocks) * 512
    }

    private func bodyFileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json", isDirectory: false)
    }

    private func metaFileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).meta.json", isDirectory: false)
    }
}

public enum PublikMobileCatalogCacheError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidKey(String)
    case documentTooLarge(key: String, bytes: Int, budget: Int)

    public var description: String {
        switch self {
        case .invalidKey(let key):
            return "Publik catalog cache key is invalid: \(key)"
        case .documentTooLarge(let key, let bytes, let budget):
            return "Publik catalog document \(key) (\(bytes) bytes) is too large for the \(budget)-byte cache."
        }
    }
}
