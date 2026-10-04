import Foundation

// Round 6, unit R6-mobile-prep-B (RC-11, apple-compliance/REQUIRED_CHANGES.md).
// A starter app (Kneecap, Nut AI, FreeHarmony) that someone removed used to show
// "Close Iris and open it again to set it up" under a disabled button, which is
// an odd thing to read in a store. Now, while Browse shows the apps that ship
// with Iris, that app's Get sets it up again from the files already inside
// Iris: no download, no waiting for publikhq.com, and the same steps a first
// launch uses (`NativeStarterInstaller`).

/// Sets a bundled starter up again on request.
public protocol StoreSeedReinstaller: Sendable {
    /// True when the files for this catalog slug are inside Iris right now.
    func canReinstall(slug: String) -> Bool
    func reinstall(slug: String, identity: NativeShellAppIdentity) async throws -> StoreInstallPipelineOutcome
    func cancel() async
}

public enum StoreSeedReinstallError: Error, Equatable, Sendable {
    case notBundled(String)
    case failed(String)
}

/// The production reinstaller: a bundled chain, installed through the one
/// coordinator the reader already uses (a second coordinator would be a second
/// writer for the same app folders; see `NativeStarterInstaller`).
public final class NativeStarterSeedReinstaller: StoreSeedReinstaller, @unchecked Sendable {
    private let coordinator: NativeShellLibraryCoordinator
    private let installer: NativeStarterInstaller
    private let entries: [NativeStarterCatalog.Entry]
    private let hasBundledFiles: @Sendable (NativeStarterCatalog.Entry) -> Bool
    private let loadChain: @Sendable (NativeStarterCatalog.Entry) -> NativeStarterInstaller.AppChain?
    private let lock = NSLock()
    private var running: Task<NativeStarterInstaller.AppResult, Never>?
    private var cancelRequested = false

    /// `hasBundledFiles` is a cheap existence check (it runs while a button is
    /// drawn); `loadChain` reads the files and only runs when someone taps Get.
    public init(
        coordinator: NativeShellLibraryCoordinator,
        installer: NativeStarterInstaller = NativeStarterInstaller(),
        entries: [NativeStarterCatalog.Entry] = NativeStarterCatalog.entries,
        hasBundledFiles: @escaping @Sendable (NativeStarterCatalog.Entry) -> Bool,
        loadChain: @escaping @Sendable (NativeStarterCatalog.Entry) -> NativeStarterInstaller.AppChain?
    ) {
        self.coordinator = coordinator
        self.installer = installer
        self.entries = entries
        self.hasBundledFiles = hasBundledFiles
        self.loadChain = loadChain
    }

    /// Catalog slugs and starter labels differ only in spelling ("nut-ai" and
    /// "NutAI"), so they match on their letters and digits alone.
    public static func entry(forSlug slug: String, in entries: [NativeStarterCatalog.Entry]) -> NativeStarterCatalog.Entry? {
        func key(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let wanted = key(slug)
        guard !wanted.isEmpty else { return nil }
        return entries.first { key($0.label) == wanted }
    }

    public func canReinstall(slug: String) -> Bool {
        guard let entry = Self.entry(forSlug: slug, in: entries) else { return false }
        return hasBundledFiles(entry)
    }

    public func reinstall(slug: String, identity: NativeShellAppIdentity) async throws -> StoreInstallPipelineOutcome {
        guard let entry = Self.entry(forSlug: slug, in: entries) else { throw StoreSeedReinstallError.notBundled(slug) }
        guard let chain = loadChain(entry) else { throw StoreSeedReinstallError.notBundled(slug) }
        let installer = self.installer
        let coordinator = self.coordinator
        let task = Task { await installer.installOne(chain, label: entry.label, into: coordinator) }
        lock.withLock { cancelRequested = false; running = task }
        let result = await task.value
        let wasCancelled = lock.withLock { () -> Bool in
            let flag = cancelRequested
            running = nil
            return flag
        }
        // Steps already done stay done (a later launch resumes the chain), so a
        // Cancel that arrives mid-way reports cancelled, never a half state.
        if wasCancelled { throw StoreInstallPipelineError.cancelled }
        switch result {
        case .installed(_, let finalRevisionId):
            return .installed(revisionId: finalRevisionId, identity: identity)
        case .alreadyPresent(let currentRevisionId):
            return .installed(revisionId: currentRevisionId, identity: identity)
        case .failed(let message):
            throw StoreSeedReinstallError.failed(message)
        }
    }

    public func cancel() async {
        let task = lock.withLock { () -> Task<NativeStarterInstaller.AppResult, Never>? in
            cancelRequested = true
            return running
        }
        task?.cancel()
    }
}

/// Sits in front of the real install pipeline. A Get for an app that Browse is
/// listing from the bundled seed, and whose files are inside Iris, sets it up
/// again in place; every other Get goes to the real pipeline unchanged.
public actor StoreSeedAwarePipeline: StoreInstallPipeline {
    private let base: any StoreInstallPipeline
    private let reinstaller: any StoreSeedReinstaller
    /// The identity to reinstall, or nil when this slug is not a seed listing
    /// right now (the real catalog answered, or the slug is unknown).
    private let seedIdentity: @Sendable (String) async -> NativeShellAppIdentity?

    public init(
        base: any StoreInstallPipeline,
        reinstaller: any StoreSeedReinstaller,
        seedIdentity: @escaping @Sendable (String) async -> NativeShellAppIdentity?
    ) {
        self.base = base
        self.reinstaller = reinstaller
        self.seedIdentity = seedIdentity
    }

    public func install(slug: String, progress: @escaping @Sendable (StoreInstallProgressStep) -> Void) async throws -> StoreInstallPipelineOutcome {
        if let identity = await seedIdentity(slug), reinstaller.canReinstall(slug: slug) {
            progress(.verifying)
            return try await reinstaller.reinstall(slug: slug, identity: identity)
        }
        return try await base.install(slug: slug, progress: progress)
    }

    public func cancel() async {
        await reinstaller.cancel()
        await base.cancel()
    }
}
