import Foundation

// Unit M2-store-layout-implementation. App icons on disk (SPEC R8.3, design
// 13.1 and 13.2): one file per icon hash, least recently used removed first,
// the folder kept under a byte cap measured in allocated blocks. Bytes come
// only from M3's `fetchIcon(for:)`, which refuses any host but publikhq.com,
// caps each icon at 64 KB and checks the bytes hash to the row's `iconHash`,
// so a file here can only ever be that app's own artwork. A miss or a failed
// fetch returns nil and the view keeps the app's initial as the placeholder.
// Bytes read back from disk are checked against the same hash before they
// are shown (R2-mobile-integration), so a damaged file cannot show either.

public actor StoreIconCache {
    /// Design 13.1 raised SPEC's 24 MB to 48 MB so a 2,000-app catalog fits.
    public static let defaultCapBytes = 48 * 1024 * 1024
    public static let maximumIconBytes = PublikMobileCatalogClient.catalogIconMaximumBytes

    public typealias Fetch = @Sendable (StoreApp) async throws -> Data

    private let directory: URL
    private let capBytes: Int
    private let fetch: Fetch
    private let fileManager: FileManager
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private var useClock: TimeInterval

    public init(directory: URL, capBytes: Int = StoreIconCache.defaultCapBytes, fileManager: FileManager = .default, fetch: @escaping Fetch) {
        self.directory = directory
        self.capBytes = capBytes
        self.fetch = fetch
        self.fileManager = fileManager
        useClock = Date().timeIntervalSince1970
    }

    /// `Library/Caches/IrisStore/icons` (purgeable, never user data).
    public static func inAppContainer(client: PublikMobileCatalogClient, fileManager: FileManager = .default) throws -> StoreIconCache {
        let caches = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("IrisStore/icons", isDirectory: true)
        return StoreIconCache(directory: directory, fileManager: fileManager) { app in
            guard let url = app.iconURL, let hash = app.iconHash else { throw PublikMobileDownloadError.disallowedURL }
            // Seed catalog (M-store-screens): the icons of the apps that come
            // with Iris ship inside it, already checked against their hash.
            if let bundled = await StoreCatalogSeed.bundled()?.icons[hash] { return bundled }
            return try await client.fetchIcon(url, expectedIconHash: hash)
        }
    }

    public nonisolated var directoryURL: URL { directory }

    /// The app's icon bytes, from disk or fetched once; nil keeps the placeholder.
    public func iconData(for app: StoreApp) async -> Data? {
        guard let hash = app.iconHash, Self.isSafeName(hash) else { return nil }
        let file = fileURL(hash)
        if let data = try? Data(contentsOf: file) {
            // A file on disk is shown only if it still is this app's own
            // artwork (R2-mobile-integration): a damaged or swapped file is
            // removed and fetched again, never shown.
            if !data.isEmpty, data.count <= Self.maximumIconBytes, Self.matches(data, iconHash: hash) {
                touch(file)
                return data
            }
            try? fileManager.removeItem(at: file)
        }
        if let running = inFlight[hash] { return await running.value }
        let fetch = self.fetch
        let task = Task<Data?, Never> {
            guard let data = try? await fetch(app), !data.isEmpty, data.count <= Self.maximumIconBytes else { return nil }
            return data
        }
        inFlight[hash] = task
        let data = await task.value
        inFlight[hash] = nil
        if let data { store(data, as: file) }
        return data
    }

    /// Allocated bytes of every icon file (st_blocks), the number the cap bounds.
    public func allocatedBytes() -> Int {
        entries().reduce(0) { $0 + $1.bytes }
    }

    public func removeAll() {
        try? fileManager.removeItem(at: directory)
    }

    private func store(_ data: Data, as file: URL) {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            touch(file)
            evict()
        } catch {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Removes least recently used icons until the folder fits the cap.
    private func evict() {
        var files = entries()
        var total = files.reduce(0) { $0 + $1.bytes }
        guard total > capBytes else { return }
        files.sort { $0.lastUse < $1.lastUse }
        for file in files where total > capBytes {
            try? fileManager.removeItem(at: file.url)
            total -= file.bytes
        }
    }

    private func entries() -> [(url: URL, bytes: Int, lastUse: TimeInterval)] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".img") else { return nil }
            let url = directory.appendingPathComponent(name)
            var status = stat()
            guard stat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
            let modified = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1e9
            return (url, Int(status.st_blocks) * 512, modified)
        }
    }

    /// Marks a file as just used. A strictly increasing clock keeps the order
    /// exact even when two uses fall in the same file-system tick.
    private func touch(_ file: URL) {
        useClock = max(useClock + 0.001, Date().timeIntervalSince1970)
        try? fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: useClock)], ofItemAtPath: file.path)
    }

    private func fileURL(_ hash: String) -> URL {
        directory.appendingPathComponent(hash + ".img")
    }

    /// The same rule M3's `fetchIcon` applies to network bytes: the first 16
    /// hex digits of the SHA-256 of the bytes equal the row's `iconHash`.
    static func matches(_ data: Data, iconHash: String) -> Bool {
        String(NativeSecurity.sha256(data).dropFirst("sha256:".count).prefix(16)) == iconHash
    }

    static func isSafeName(_ hash: String) -> Bool {
        (1...64).contains(hash.utf8.count) && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
