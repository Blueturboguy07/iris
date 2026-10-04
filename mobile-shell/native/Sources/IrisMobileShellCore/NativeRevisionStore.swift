import Foundation
import Darwin

/// One stored revision's measured, clone-dedupe-aware allocated bytes.
/// See `NativeStorageBlockMeasurement.dedupingAllocatedBytes`.
public struct NativeStorageRevisionAllocation: Equatable, Sendable {
    public let revisionId: String
    public let allocatedBytes: Int
}

/// The outcome of one `NativeRevisionStore.pruneStorage()` call.
public struct NativeStoragePruneReport: Equatable, Sendable {
    public let removedRevisionIds: Set<String>
    public let retainedRevisionIds: Set<String>
}

// A screen read shares the root facade only after the first adapter's live
// namespace checks. This token expires with that root-held operation.
private enum NativeRevisionReadContext {
    @TaskLocal static var sharedStores: [String: NativeVersionStore] = [:]
    @TaskLocal static var settledRoots: Set<String> = []
}

public actor NativeRevisionStore {
    private struct PinnedRevisions: Codable, Equatable {
        let revisionIds: [String]
    }

    private struct StoredFile: Codable, Equatable {
        let path: String
        let sha256: String
        let bytes: Int
        let mediaType: String
    }

    private struct StoredManifest: Codable, Equatable {
        let displayName: String
        let runtimeType: String
        let entrypoint: String
        let minShellVersion: String
        let requestedCapabilities: [String]
        let dataNamespace: String
        let dataUpdatePolicy: String
    }

    private struct StoredRevision: Codable, Equatable {
        let contractVersion: Int
        let appId: String
        let projectId: String
        let baseRevisionId: String?
        let revisionId: String
        let manifestHash: String
        let contentHash: String
        let createdAt: String
        let manifest: StoredManifest
        let files: [StoredFile]
        /// Contract v1.1 (SPEC.md section 2.6): optional, covered by
        /// `contentHash`. `nil`/absent decodes the same as "no changes",
        /// so metadata.json written before this field existed still reads
        /// back unchanged.
        var changes: [NativeVersionChange]?

        init(
            contractVersion: Int, appId: String, projectId: String, baseRevisionId: String?,
            revisionId: String, manifestHash: String, contentHash: String, createdAt: String,
            manifest: StoredManifest, files: [StoredFile], changes: [NativeVersionChange]? = nil
        ) {
            self.contractVersion = contractVersion
            self.appId = appId
            self.projectId = projectId
            self.baseRevisionId = baseRevisionId
            self.revisionId = revisionId
            self.manifestHash = manifestHash
            self.contentHash = contentHash
            self.createdAt = createdAt
            self.manifest = manifest
            self.files = files
            self.changes = changes
        }
    }

    private struct ActivePointer: Codable, Equatable {
        let currentRevisionId: String
        let fallbackRevisionId: String?
    }

    // Validation is a property of the complete decoded manifest, not just its
    // revision id. The manifest reader still checks disk identity on every read.
    // Policy, expected delivery and launchable bytes are checked outside this cache.
    private final class MetadataValidationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (NativeVersionManifest, StoredRevision, Int)] = [:]
        private var encodedBytes = 0
        private var timestamps: [String: Bool] = [:]

        func get(_ version: NativeVersionManifest, path: String) -> StoredRevision? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.0 == version else { return nil }
            return entry.1
        }

        func insert(_ version: NativeVersionManifest, metadata: StoredRevision, path: String) {
            guard let bytes = try? JSONEncoder().encode(version).count, bytes <= 8 * 1_024 * 1_024 else { return }
            lock.lock(); defer { lock.unlock() }
            if let previous = entries.removeValue(forKey: path) { encodedBytes -= previous.2 }
            if entries.count >= 2_048 || encodedBytes > 8 * 1_024 * 1_024 - bytes {
                entries.removeAll(keepingCapacity: true)
                encodedBytes = 0
            }
            entries[path] = (version, metadata, bytes)
            encodedBytes += bytes
        }

        func canonicalTimestamp(_ value: String) -> Bool {
            // Invalid, arbitrarily large fields must not occupy the bounded cache.
            // Validation itself stays identical for values that are not cached.
            guard value.utf8.count <= 64 else { return NativeSecurity.isCanonicalISOInstant(value) }
            lock.lock()
            let cached = timestamps[value]
            lock.unlock()
            if let cached { return cached }
            let valid = NativeSecurity.isCanonicalISOInstant(value)
            lock.lock(); defer { lock.unlock() }
            if timestamps.count >= 2_048 { timestamps.removeAll(keepingCapacity: true) }
            timestamps[value] = valid
            return valid
        }
    }

    private static let metadataValidationCache = MetadataValidationCache()

    private var versionStore: NativeVersionStore?
    private var objectStorageReady = false
    private var migrationWarning: String?

    /// A failed migration keeps the legacy app available and reports why.
    public func storageMigrationWarning() -> String? {
        if (try? hasDeferredStoragePrune()) == true { return Self.migratedStorageWarning }
        return migrationWarning
    }

    private let defaults: UserDefaults
    private let downloadableRevisionIds: @Sendable (NativeShellAppIdentity) async throws -> Set<String>
    private let versionFault: NativeVersionFaultInjector?
    private let rootURL: URL
    private let stateDirectoryURL: URL
    private let revisionsDirectoryURL: URL
    private let appId: String
    private let projectId: String
    private let shellVersion: String
    private let capabilityPolicy: CapabilityPolicy
    private let fileManager: FileManager
    private let minimumFreeBytesForStaging: Int64
    private let availableCapacityProvider: @Sendable (URL) throws -> Int64

    public init(
        rootURL: URL,
        appId: String,
        projectId: String,
        shellVersion: String,
        capabilityPolicy: CapabilityPolicy = .denyAll,
        fileManager: FileManager = .default,
        minimumFreeBytesForStaging: Int64 = NativeStorageRetentionPolicy.defaultMinimumFreeBytesForStaging,
        availableCapacityProvider: @escaping @Sendable (URL) throws -> Int64
            = { url in try NativeStorageBlockMeasurement.systemAvailableCapacityBytes(at: url) },
        defaults: UserDefaults = .standard,
        downloadableRevisionIds: @escaping @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] },
        versionFault: NativeVersionFaultInjector? = nil
    ) throws {
        guard NativeSecurity.isStableId(appId) else { throw NativeShellError.invalidStableIdentifier(appId) }
        guard NativeSecurity.isStableId(projectId) else { throw NativeShellError.invalidStableIdentifier(projectId) }
        guard NativeSecurity.compareSemver(shellVersion, shellVersion) != nil else {
            throw NativeShellError.invalidShellVersion(shellVersion)
        }
        let storageRoot = rootURL.standardizedFileURL
        self.rootURL = storageRoot
        self.stateDirectoryURL = storageRoot.appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true).appendingPathComponent(projectId, isDirectory: true)
        self.revisionsDirectoryURL = storageRoot.appendingPathComponent("content", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true).appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
        self.appId = appId
        self.projectId = projectId
        self.shellVersion = shellVersion
        self.capabilityPolicy = capabilityPolicy
        self.fileManager = fileManager
        self.minimumFreeBytesForStaging = minimumFreeBytesForStaging
        self.availableCapacityProvider = availableCapacityProvider
        self.defaults = defaults
        self.downloadableRevisionIds = downloadableRevisionIds
        self.versionFault = versionFault
    }

    public func stage(packageBytes: Data, approvalAuthority: any DeliveryApprovalAuthority) async throws -> StagedRevisionReceipt {
        let available = try availableCapacityProvider(rootURL)
        guard available >= minimumFreeBytesForStaging else {
            throw NativeStorageError.insufficientStorageForUpdate(availableBytes: available, thresholdBytes: minimumFreeBytesForStaging)
        }
        return try await withStorage { store in
            let receipt = try await store.stageImpl(packageBytes: packageBytes, approvalAuthority: approvalAuthority)
            try? await store.maintainCountAfterSelection()
            return receipt
        }
    }

    public func activate(revisionId: String) async throws -> Void {
        try await withStorage { store in
            try await store.activateImpl(revisionId: revisionId)
            try? await store.maintainCountAfterSelection()
        }
    }

    public func rollback(to revisionId: String) async throws -> Void {
        try await withStorage { store in
            try await store.rollbackImpl(to: revisionId)
            try? await store.maintainCountAfterSelection()
        }
    }

    public func revisionIsOnThisPhone(revisionId: String) async throws -> Bool {
        try await withStorage { store in
            guard NativeSecurity.isRevisionId(revisionId) else { return false }
            if store.objectStorageReady {
                guard store.versionStore!.manifests.exists(appId: store.appId, projectId: store.projectId, revisionId: revisionId) else { return false }
                let manifest = try store.versionStore!.manifests.read(appId: store.appId, projectId: store.projectId, revisionId: revisionId)
                for file in manifest.files {
                    let object = store.versionStore!.objects.path(forSHA256: file.sha256)
                    try store.rejectSymbolicLink(at: object)
                    var info = stat()
                    if lstat(object.path, &info) != 0 {
                        if errno == ENOENT { return false }
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    guard info.st_mode & S_IFMT == S_IFREG else { throw NativeShellError.sourceNotRegularFile(object.path) }
                    if Int(info.st_size) != file.bytes { return false }
                }
                do { _ = try store.verifyStoredRevision(revisionId); return true }
                catch is NativeObjectStoreError { return false }
                catch is NativeVersionCheckoutError { return false }
                catch let error as NativeShellError {
                    switch error {
                    case .storedRevisionInvalid, .hashMismatch, .byteCountMismatch: return false
                    default: throw error
                    }
                }
            }
            return store.fileManager.fileExists(atPath: store.revisionsRoot().appendingPathComponent(revisionId).path)
        }
    }

    public func activeRevisionId() async throws -> String? {
        try await withStorage { store in try store.activeRevisionIdImpl() }
    }

    public func fallbackRevisionId() async throws -> String? {
        try await withStorage { store in try store.fallbackRevisionIdImpl() }
    }

    public func revisionSummaries() async throws -> [NativeRevisionSummary] {
        try await withStorage { store in try store.revisionSummariesImpl() }
    }

    public func launchDescriptorForActiveRevision() async throws -> VerifiedLaunchDescriptor {
        try await withStorage { store in
            let deferred = try store.isAwaitingFirstMigratedLaunch()
            let descriptor = try store.launchDescriptorForActiveRevisionImpl()
            if deferred { try store.recordFirstMigratedLaunch() }
            else { try? await store.maintainCountAfterSelection() }
            return descriptor
        }
    }

    public func pinnedRevisionIds() async throws -> [String] {
        try await withStorage { store in try store.pinnedRevisionIdsImpl() }
    }

    public func pin(revisionId: String) async throws -> Void {
        try await withStorage { store in try store.pinImpl(revisionId: revisionId) }
    }

    public func unpin(revisionId: String) async throws -> Void {
        try await withStorage { store in try store.unpinImpl(revisionId: revisionId) }
    }

    public func storageAllocation() async throws -> [NativeStorageRevisionAllocation] {
        try await withStorage { store in try store.storageAllocationImpl() }
    }

    public func totalAllocatedBytes() async throws -> Int {
        try await withStorage { store in try store.totalAllocatedBytesImpl() }
    }

    /// Enter through the adapter's owned-path checks before constructing the
    /// root facade. Empty libraries need no facade or new directories.
    func withStorageAllocationSnapshot<T: Sendable>(
        preparation: @escaping @Sendable () async throws -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withStorage { store in
            let facade = store.versionStore!
            var sharedStores = NativeRevisionReadContext.sharedStores
            sharedStores[store.rootURL.path] = facade
            return try await NativeRevisionReadContext.$sharedStores.withValue(sharedStores) {
                // The root writer spans this whole read. Share settlement only
                // after recovery has handled tombstones and dirty references,
                // and every app's swap and migration journal is settled.
                var settledRoots = NativeRevisionReadContext.settledRoots
                do {
                    try store.assertStorageSettled()
                    if !(await facade.refs.isDirty()) { settledRoots.insert(store.rootURL.path) }
                } catch NativeStorageError.recoveryRequired {
                    // An unsettled sibling still needs the ordinary recovery path.
                }
                return try await NativeRevisionReadContext.$settledRoots.withValue(settledRoots) {
                    try await facade.withAllocationSnapshot(preparation: preparation, operation: operation)
                }
            }
        }
    }

    /// Settles migration and dirty journals before a root-wide accounting read.
    func prepareForStorageRead() async throws {
        try await withStorage { _ in () }
    }

    /// Only the root-held screen snapshot can use a prepared read. Migration
    /// and owned-directory checks already finished for every app in that read;
    /// metadata, checkout entries, pointer and pins are still checked live.
    func storageUsageForPreparedSnapshot() throws -> NativeStorageAppUsage {
        guard versionStore?.hasAllocationSnapshot == true else {
            throw NativeShellError.unsafeStorageNamespace(rootURL.path)
        }
        return try storageUsageImpl()
    }

    public func storageUsage() async throws -> NativeStorageAppUsage {
        try await withStorage { store in try store.storageUsageImpl() }
    }

    public func pruneStorage() async throws -> NativeStoragePruneReport {
        try await withStorage { store in try await store.pruneStorageImpl() }
    }

    public func prunableAllocation() async throws -> [(revisionId: String, allocatedBytes: Int, createdAt: String)] {
        try await withStorage { store in try await store.prunableAllocationImpl() }
    }

    public func removeSpecificRevisions(_ ids: Set<String>) async throws -> NativeStoragePruneReport {
        try await withStorage { store in try await store.removeSpecificRevisionsImpl(ids) }
    }

    /// Read-only planning must not create a facade, recover or migrate.
    func keepCountSnapshot(checkRootSettlement: Bool = true) async throws -> NativeStorageKeepSnapshot {
        if checkRootSettlement { try assertStorageSettled() }
        else { try assertOwnStorageSettled() }
        let identity = NativeShellAppIdentity(appId: appId, projectId: projectId)
        let offers = try await downloadableRevisionIds(identity)
        // The catalog can suspend. Recheck journals and live pointers afterward.
        if checkRootSettlement { try assertStorageSettled() }
        else { try assertOwnStorageSettled() }
        let manifestRoot = rootURL.appendingPathComponent("manifests/" + appId + "/" + projectId)
        var versions: [NativeVersionManifest] = []
        let formatURL = stateRoot().appendingPathComponent("store-format")
        try rejectSymbolicLink(at: formatURL)
        let modern = (try? String(contentsOf: formatURL, encoding: .utf8)) == "2"
        if modern {
            try requireExistingOwnedDirectory(manifestRoot)
            let manifests = try NativeVersionManifestStore(root: rootURL.appendingPathComponent("manifests"))
            versions = try manifests.list(appId: appId, projectId: projectId)
            for version in versions { try validatePlanningManifest(version) }
        } else if fileManager.fileExists(atPath: revisionsRoot().path) {
            try requireExistingOwnedDirectory(revisionsRoot())
            for child in try fileManager.contentsOfDirectory(at: revisionsRoot(), includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) {
                let id = child.lastPathComponent
                guard NativeSecurity.isRevisionId(id) else { throw NativeShellError.storedRevisionInvalid(id) }
                let metadataURL = child.appendingPathComponent("metadata.json")
                try assertOwnedFileComponents(metadataURL)
                let metadata = try JSONDecoder().decode(StoredRevision.self, from: Data(contentsOf: metadataURL))
                guard metadata.appId == appId, metadata.projectId == projectId, metadata.revisionId == id else {
                    throw NativeShellError.storedRevisionInvalid(id)
                }
                let version = NativeVersionManifest(revisionId: id, baseRevisionId: metadata.baseRevisionId,
                    contentHash: metadata.contentHash, createdAt: metadata.createdAt,
                    files: metadata.files.map { .init(path: $0.path, sha256: String($0.sha256.dropFirst(7)), bytes: $0.bytes, mediaType: $0.mediaType) },
                    changes: metadata.changes,
                    manifest: .init(displayName: metadata.manifest.displayName, runtimeType: metadata.manifest.runtimeType,
                        entrypoint: metadata.manifest.entrypoint, minShellVersion: metadata.manifest.minShellVersion,
                        requestedCapabilities: metadata.manifest.requestedCapabilities, dataNamespace: metadata.manifest.dataNamespace,
                        dataUpdatePolicy: metadata.manifest.dataUpdatePolicy))
                try validatePlanningManifest(version)
                versions.append(version)
            }
        }
        let pointer: ActivePointer? = try readPlanningFile(ActivePointer.self, at: pointerURL())
        let pins: PinnedRevisions? = try readPlanningFile(PinnedRevisions.self, at: pinsURL())
        return NativeStorageKeepSnapshot(identity: identity, versions: versions, current: pointer?.currentRevisionId,
            fallback: pointer?.fallbackRevisionId, pins: pins?.revisionIds ?? [], offers: offers,
            legacyRoot: modern ? nil : revisionsRoot(), awaitingFirstLaunch: try isAwaitingFirstMigratedLaunch())
    }

    private func readPlanningFile<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        try rejectSymbolicLink(at: url)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try assertOwnedFileComponents(url)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func validatePlanningManifest(_ version: NativeVersionManifest) throws {
        guard let manifest = version.manifest,
              NativeSecurity.isCanonicalISOInstant(version.createdAt),
              version.files.allSatisfy({ NativeSecurity.isSafePackagePath($0.path) && $0.bytes >= 0 }) else {
            throw NativeShellError.storedRevisionInvalid(version.revisionId)
        }
        let receipt = DeliveryManifestReceipt(displayName: manifest.displayName, runtimeType: manifest.runtimeType,
            entrypoint: manifest.entrypoint, minShellVersion: manifest.minShellVersion,
            requestedCapabilities: manifest.requestedCapabilities, dataNamespace: manifest.dataNamespace,
            dataUpdatePolicy: manifest.dataUpdatePolicy)
        let identity = NativeSecurity.revisionIdentity(appId: appId, projectId: projectId,
            baseRevisionId: version.baseRevisionId, manifest: receipt,
            files: version.files.map { .init(path: $0.path, sha256: "sha256:" + $0.sha256,
                bytes: $0.bytes, mediaType: $0.mediaType, data: Data()) }, changes: version.changes)
        guard identity.revisionId == version.revisionId, identity.contentHash == version.contentHash else {
            throw NativeShellError.storedRevisionInvalid(version.revisionId)
        }
    }

    /// Applies to the whole root: an unsettled app can share objects with us.
    func assertStorageSettled() throws {
        try autoreleasepool { try checkRootStorageJournals() }
    }

    private func checkRootStorageJournals() throws {
        let state = rootURL.appendingPathComponent("state")
        guard fileManager.fileExists(atPath: state.path) else { return }
        try requireExistingOwnedDirectory(state)
        for app in try fileManager.contentsOfDirectory(at: state, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(app.path, &info) == 0 else { throw NativeStorageError.recoveryRequired }
            guard info.st_mode & S_IFMT != S_IFLNK else { throw NativeShellError.unsafeStorageNamespace(app.path) }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            for project in try fileManager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) {
                // The state root and its real app child were checked above.
                // Check each project live without rewalking those ancestors.
                try requirePlainChildDirectory(project)
                let swap = project.appendingPathComponent("journal.json")
                try rejectSymbolicLink(at: swap)
                if fileManager.fileExists(atPath: swap.path) { throw NativeStorageError.recoveryRequired }
                let migration = project.appendingPathComponent("migration.json")
                try rejectSymbolicLink(at: migration)
                if fileManager.fileExists(atPath: migration.path) {
                    let journal = try JSONDecoder().decode(NativeStoreMigrationJournal.self, from: Data(contentsOf: migration))
                    guard journal.done else { throw NativeStorageError.recoveryRequired }
                }
            }
        }
    }

    private func assertOwnStorageSettled() throws {
        let swap = stateRoot().appendingPathComponent("journal.json")
        try rejectSymbolicLink(at: swap)
        if fileManager.fileExists(atPath: swap.path) { throw NativeStorageError.recoveryRequired }
        let migration = stateRoot().appendingPathComponent("migration.json")
        try rejectSymbolicLink(at: migration)
        if fileManager.fileExists(atPath: migration.path) {
            try assertOwnedFileComponents(migration)
            let value = try JSONDecoder().decode(NativeStoreMigrationJournal.self, from: Data(contentsOf: migration))
            if !value.done { throw NativeStorageError.recoveryRequired }
        }
    }

    /// One root writer spans the coordinator's preflight, save and all frees.
    func withStorageMaintenance<T: Sendable>(operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withStorage { _ in try await operation() }
    }

    private func stageImpl(
        packageBytes: Data,
        approvalAuthority: any DeliveryApprovalAuthority
    ) async throws -> StagedRevisionReceipt {
        // Fails fast, before any hashing or validation of the incoming
        // bytes: PLAN.md Phase 1 acceptance requires an update to be refused
        // clearly under low storage, with the existing version still able to
        // open. This never touches or removes anything already stored.
        let available = try availableCapacityProvider(rootURL)
        guard available >= minimumFreeBytesForStaging else {
            throw NativeStorageError.insufficientStorageForUpdate(
                availableBytes: available,
                thresholdBytes: minimumFreeBytesForStaging
            )
        }

        let validator = DeliveryPackageV1Validator()
        let delivery = try validator.validate(packageBytes: packageBytes, approvalAuthority: approvalAuthority)
        let baseRevision = try validateDelivery(delivery)

        if objectStorageReady, let store = versionStore {
            if store.manifests.exists(appId: appId, projectId: projectId, revisionId: delivery.revisionId) {
                try verifyStoredRevision(delivery.revisionId, expected: delivery)
            }
            let receipt = try await store.stage(
                appId: appId, projectId: projectId, revisionId: delivery.revisionId,
                baseRevisionId: delivery.baseRevisionId, contentHash: delivery.contentHash,
                createdAt: delivery.createdAt,
                files: delivery.files.map { .init(path: $0.path, data: $0.data, mediaType: $0.mediaType) },
                changes: delivery.changes,
                manifest: .init(displayName: delivery.manifest.displayName, runtimeType: delivery.manifest.runtimeType,
                    entrypoint: delivery.manifest.entrypoint, minShellVersion: delivery.manifest.minShellVersion,
                    requestedCapabilities: delivery.manifest.requestedCapabilities,
                    dataNamespace: delivery.manifest.dataNamespace, dataUpdatePolicy: delivery.manifest.dataUpdatePolicy),
                fault: versionFault ?? .init()
            )
            try verifyStoredRevision(delivery.revisionId, expected: delivery)
            try recordDeliveryNonce(delivery.deliveryNonce, contentHash: delivery.contentHash)
            return .init(revisionId: receipt.revisionId, alreadyStaged: receipt.alreadyStaged)
        }

        let revisions = revisionsRoot()
        try ensureOwnedDirectory(revisions)
        let finalRevisionURL = revisions.appendingPathComponent(delivery.revisionId, isDirectory: true)

        let alreadyStaged: Bool
        if fileManager.fileExists(atPath: finalRevisionURL.path) {
            try verifyStoredRevision(delivery.revisionId, expected: delivery)
            alreadyStaged = true
        } else {
            let temporaryURL = revisions.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
            var promoted = false
            do {
                try stageIntoTemporaryDirectory(
                    delivery,
                    baseRevision: baseRevision,
                    temporaryURL: temporaryURL
                )
                try fileManager.moveItem(at: temporaryURL, to: finalRevisionURL)
                promoted = true
                try verifyStoredRevision(delivery.revisionId, expected: delivery)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                if promoted {
                    try? fileManager.removeItem(at: finalRevisionURL)
                }
                throw error
            }
            alreadyStaged = false
        }

        try recordDeliveryNonce(delivery.deliveryNonce, contentHash: delivery.contentHash)
        return StagedRevisionReceipt(revisionId: delivery.revisionId, alreadyStaged: alreadyStaged)
    }

    private func activateImpl(revisionId: String) async throws {
        let candidate = try verifyStoredRevision(revisionId)
        let previous = try readActivePointer()
        if previous?.currentRevisionId == revisionId { return }
        guard candidate.baseRevisionId == previous?.currentRevisionId else {
            throw NativeShellError.baseMismatch(expected: previous?.currentRevisionId, actual: candidate.baseRevisionId)
        }
        if let currentRevisionId = previous?.currentRevisionId {
            let current = try verifyStoredRevision(currentRevisionId)
            guard candidate.manifest.dataNamespace == current.manifest.dataNamespace else {
                throw NativeShellError.userDataNamespaceMismatch(
                    expected: current.manifest.dataNamespace,
                    actual: candidate.manifest.dataNamespace
                )
            }
        }
        if objectStorageReady, let store = versionStore {
            _ = try await store.activate(appId: appId, projectId: projectId, revisionId: revisionId, fault: versionFault ?? .init())
            return
        }
        try writeActivePointer(
            ActivePointer(
                currentRevisionId: revisionId,
                fallbackRevisionId: previous?.currentRevisionId
            )
        )
    }

    private func rollbackImpl(to revisionId: String) async throws {
        let target = try verifyStoredRevision(revisionId)
        guard let previous = try readActivePointer() else { throw NativeShellError.noActiveRevision }
        if previous.currentRevisionId == revisionId { return }
        let current = try verifyStoredRevision(previous.currentRevisionId)
        guard target.manifest.dataNamespace == current.manifest.dataNamespace else {
            throw NativeShellError.userDataNamespaceMismatch(
                expected: current.manifest.dataNamespace,
                actual: target.manifest.dataNamespace
            )
        }
        if objectStorageReady, let store = versionStore {
            _ = try await store.rollback(appId: appId, projectId: projectId, revisionId: revisionId, fault: versionFault ?? .init())
            return
        }
        try writeActivePointer(
            ActivePointer(
                currentRevisionId: revisionId,
                fallbackRevisionId: previous.currentRevisionId
            )
        )
    }

    private func activeRevisionIdImpl() throws -> String? {
        try readActivePointer()?.currentRevisionId
    }

    private func fallbackRevisionIdImpl() throws -> String? {
        try readActivePointer()?.fallbackRevisionId
    }

    private func revisionSummariesImpl() throws -> [NativeRevisionSummary] {
        if objectStorageReady, let store = versionStore {
            return try store.manifests.history(appId: appId, projectId: projectId).map { manifest in
                let metadata = try verifyStoredRevision(manifest.revisionId, hashingContent: false, includeFreed: true)
                return NativeRevisionSummary(appId: appId, projectId: projectId,
                    revisionId: metadata.revisionId, baseRevisionId: metadata.baseRevisionId,
                    displayName: metadata.manifest.displayName, dataNamespace: metadata.manifest.dataNamespace,
                    requestedCapabilities: metadata.manifest.requestedCapabilities, createdAt: metadata.createdAt,
                    contentBytes: metadata.files.reduce(0) { $0 + $1.bytes }, changes: metadata.changes)
            }.sorted { $0.createdAt > $1.createdAt }
        }
        let revisions = revisionsRoot()
        try ensureOwnedDirectory(revisions)
        let children = try fileManager.contentsOfDirectory(
            at: revisions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var summaries: [NativeRevisionSummary] = []
        for child in children {
            let revisionId = child.lastPathComponent
            guard NativeSecurity.isRevisionId(revisionId) else {
                throw NativeShellError.storedRevisionInvalid("revisions-index")
            }
            let metadata = try verifyStoredRevision(revisionId)
            summaries.append(
                NativeRevisionSummary(
                    appId: metadata.appId,
                    projectId: metadata.projectId,
                    revisionId: metadata.revisionId,
                    baseRevisionId: metadata.baseRevisionId,
                    displayName: metadata.manifest.displayName,
                    dataNamespace: metadata.manifest.dataNamespace,
                    requestedCapabilities: metadata.manifest.requestedCapabilities,
                    createdAt: metadata.createdAt,
                    contentBytes: metadata.files.reduce(0) { $0 + $1.bytes },
                    changes: metadata.changes
                )
            )
        }
        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    public func readerDataDirectory(namespace: String) throws -> URL {
        guard NativeSecurity.isStableId(namespace) else {
            throw NativeShellError.invalidStableIdentifier(namespace)
        }
        let directory = rootURL
            .appendingPathComponent("reader-data", isDirectory: true)
            .appendingPathComponent(appId, isDirectory: true)
            .appendingPathComponent(projectId, isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try ensureOwnedDirectory(directory)
        return directory
    }

    /// Re-verifies stored bytes before launch. If the active revision was
    /// corrupted after staging, this restores the prior verified pointer when
    /// one is still usable.
    private func launchDescriptorForActiveRevisionImpl() throws -> VerifiedLaunchDescriptor {
        guard let pointer = try readActivePointer() else { throw NativeShellError.noActiveRevision }
        do {
            let descriptor = try launchDescriptor(for: pointer.currentRevisionId)
            if objectStorageReady {
                try? NativeStoreMigration(legacyRevisionsRoot: revisionsRoot(), v1Root: rootURL)
                    .confirmVerifiedLaunch(appId: appId, projectId: projectId)
            }
            return descriptor
        } catch {
            guard let fallback = pointer.fallbackRevisionId else { throw NativeShellError.noUsableFallback }
            let descriptor = try launchDescriptor(for: fallback, verifyingObjects: false)
            try writeActivePointer(ActivePointer(currentRevisionId: fallback, fallbackRevisionId: nil))
            if objectStorageReady, let store = versionStore {
                try? store.checkouts.delete(appId: appId, projectId: projectId, revisionId: pointer.currentRevisionId)
                try? NativeStoreMigration(legacyRevisionsRoot: revisionsRoot(), v1Root: rootURL)
                    .confirmVerifiedLaunch(appId: appId, projectId: projectId)
            }
            return descriptor
        }
    }

    // MARK: - Bounded storage: retention, pinning and measurement

    private func pinnedRevisionIdsImpl() throws -> [String] {
        if versionStore?.hasAllocationSnapshot == true {
            try requirePlainChildDirectory(stateRoot())
        } else {
            try ensureOwnedDirectory(stateRoot())
        }
        let url = pinsURL()
        try rejectSymbolicLink(at: url)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            return try JSONDecoder().decode(PinnedRevisions.self, from: Data(contentsOf: url)).revisionIds
        } catch {
            throw NativeShellError.storedRevisionInvalid("pinned-revisions")
        }
    }

    /// Pinning verifies the revision is actually stored (hash-verified, like
    /// every other read of stored content) before recording it, so a pin can
    /// never name a revision that does not really exist on disk.
    private func pinImpl(revisionId: String) throws {
        do {
            _ = try verifyStoredRevision(revisionId)
        } catch {
            throw NativeStorageError.revisionNotAvailableToPin(revisionId)
        }
        var pins = try pinnedRevisionIdsImpl()
        guard !pins.contains(revisionId) else { return }
        guard pins.count < NativeStorageRetentionPolicy.pinLimit else {
            throw NativeStorageError.pinLimitReached(limit: NativeStorageRetentionPolicy.pinLimit)
        }
        pins.append(revisionId)
        try atomicWrite(PinnedRevisions(revisionIds: pins), to: pinsURL())
    }

    /// Unpinning an id that was never pinned, or that no longer exists, is a
    /// harmless no-op rather than an error: the reader's intent ("this
    /// should not be specially kept") is already satisfied.
    private func unpinImpl(revisionId: String) throws {
        var pins = try pinnedRevisionIdsImpl()
        guard let index = pins.firstIndex(of: revisionId) else { return }
        pins.remove(at: index)
        try atomicWrite(PinnedRevisions(revisionIds: pins), to: pinsURL())
    }

    /// Allocated (`st_blocks * 512`) bytes per currently stored revision,
    /// deduplicating clone-shared blocks against each revision's own base.
    /// Every revision measured here has its metadata and exact file tree
    /// checked (`verifyStoredRevision(hashingContent: false)`); the bytes are
    /// not re-hashed, because this only measures. A damaged revision is still
    /// refused by every path that runs or keeps code.
    private func storageAllocationImpl() throws -> [NativeStorageRevisionAllocation] {
        if objectStorageReady, let store = versionStore {
            for manifest in try store.allocationManifests(appId: appId, projectId: projectId) {
                _ = try verifyStoredRevision(manifest.revisionId, hashingContent: false,
                    measurementManifest: store.hasAllocationSnapshot ? manifest : nil)
            }
            return try store.allocation(appId: appId, projectId: projectId)
        }
        let revisions = revisionsRoot()
        try ensureOwnedDirectory(revisions)
        let children = try fileManager.contentsOfDirectory(
            at: revisions,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var filesByRevision: [String: [NativeStorageBlockMeasurement.FileFingerprint]] = [:]
        var contentRootByRevision: [String: URL] = [:]
        var baseByRevision: [String: String?] = [:]
        for child in children {
            let revisionId = child.lastPathComponent
            guard NativeSecurity.isRevisionId(revisionId) else {
                throw NativeShellError.storedRevisionInvalid("revisions-index")
            }
            let metadata = try verifyStoredRevision(revisionId, hashingContent: false)
            filesByRevision[revisionId] = metadata.files.map {
                .init(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, mediaType: $0.mediaType)
            }
            contentRootByRevision[revisionId] = child.appendingPathComponent("content", isDirectory: true)
            baseByRevision[revisionId] = metadata.baseRevisionId
        }
        let allocations = try NativeStorageBlockMeasurement.dedupingAllocatedBytes(
            contentRootByRevision: contentRootByRevision,
            filesByRevision: filesByRevision,
            baseRevisionByRevision: baseByRevision
        )
        return allocations
            .map { NativeStorageRevisionAllocation(revisionId: $0.key, allocatedBytes: $0.value) }
            .sorted { $0.revisionId < $1.revisionId }
    }

    private func totalAllocatedBytesImpl() throws -> Int {
        try storageAllocationImpl().reduce(0) { $0 + $1.allocatedBytes }
    }

    /// The plain-language per-app storage view's Core-side facts. The Host
    /// layer supplies this app's user-data byte count separately (it needs
    /// `WKWebsiteDataStore`, which Core has no access to and cannot measure
    /// on macOS in tests), and shows it apart from `codeAllocatedBytes`.
    private func storageUsageImpl() throws -> NativeStorageAppUsage {
        let allocation = try storageAllocationImpl()
        let pointer = try readActivePointer()
        let pins = try pinnedRevisionIdsImpl()
        return NativeStorageAppUsage(
            identity: NativeShellAppIdentity(appId: appId, projectId: projectId),
            codeAllocatedBytes: allocation.reduce(0) { $0 + $1.allocatedBytes },
            storedRevisionCount: allocation.count,
            pinnedRevisionIds: pins,
            currentRevisionId: pointer?.currentRevisionId,
            fallbackRevisionId: pointer?.fallbackRevisionId
        )
    }

    /// Removes every stored revision that is not current, previous, pending
    /// or pinned (`NativeStorageRetentionPolicy`). Never touches reader data
    /// (`readerDataDirectory`, a disjoint path this method never lists or
    /// deletes from) and never deletes a revision this method cannot prove
    /// is safe to remove: every candidate is read from a hash-verified
    /// listing of what is actually current, previous and pinned right now,
    /// not from a cached or stale view.
    ///
    /// Crash safety: removing one revision is rename-then-delete. The rename
    /// (same-volume, so atomic) is the only step that changes what is
    /// visible: `revisionsRoot()`'s listing and `verifyStoredRevision` both
    /// skip the dot-prefixed tombstone name, so the instant the rename
    /// completes, that revision is gone from every list this store returns,
    /// whether or not the process survives to actually reclaim its bytes. A
    /// process that dies between the rename and the delete leaves a
    /// `.trash-*` directory that the next call to this method finds and
    /// finishes removing before making any new pruning decisions. No
    /// retained revision's directory is ever renamed or touched.
    @discardableResult
    private func pruneStorageImpl() async throws -> NativeStoragePruneReport {
        try assertStorageSettled()
        guard objectStorageReady else { throw NativeStorageError.recoveryRequired }
        let snapshot = try await keepCountSnapshot()
        let choice = defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
            .flatMap(VersionsKeptPerApp.init(rawValue:)) ?? .keepTwo
        let excess = snapshot.storedIds.subtracting(snapshot.retained(choice))
        var removed = Set<String>()
        if !excess.isEmpty { removed = try await removeSpecificRevisionsImpl(excess).removedRevisionIds }
        let cap = (defaults.object(forKey: NativeShellLibraryCoordinator.globalCodeCapUserDefaultsKey) as? Int64)
            ?? NativeStorageRetentionPolicy.defaultGlobalCodeCapBytes
        for candidate in try await prunableAllocationImpl() {
            guard Int64(try versionStore!.globalAllocatedBytes()) > max(0, cap) else { break }
            let report = try await removeSpecificRevisionsImpl([candidate.revisionId])
            removed.formUnion(report.removedRevisionIds)
        }
        try finishOrdinaryStoragePrune()
        return .init(removedRevisionIds: removed, retainedRevisionIds: try await keepCountSnapshot().storedIds)
    }

    private var migrationDeferralURL: URL { stateRoot().appendingPathComponent("keep-count-migration-deferred") }
    private static let migratedStorageWarning = "Older versions will be cleared the next time Iris tidies storage."

    func hasDeferredStoragePrune() throws -> Bool {
        try rejectSymbolicLink(at: migrationDeferralURL)
        return fileManager.fileExists(atPath: migrationDeferralURL.path)
    }

    private func isAwaitingFirstMigratedLaunch() throws -> Bool {
        guard try hasDeferredStoragePrune() else { return false }
        let value = try String(contentsOf: migrationDeferralURL, encoding: .utf8)
        guard ["waiting-for-launch", "ready-for-prune"].contains(value) else { throw NativeStorageError.recoveryRequired }
        return value == "waiting-for-launch"
    }

    private func recordFirstMigratedLaunch() throws {
        try rejectSymbolicLink(at: migrationDeferralURL)
        try Data("ready-for-prune".utf8).write(to: migrationDeferralURL, options: .atomic)
    }

    func finishOrdinaryStoragePrune() throws {
        try assertStorageSettled()
        try rejectSymbolicLink(at: migrationDeferralURL)
        if try isAwaitingFirstMigratedLaunch() { return }
        if fileManager.fileExists(atPath: migrationDeferralURL.path) {
            try fileManager.removeItem(at: migrationDeferralURL)
        }
        if migrationWarning == Self.migratedStorageWarning { migrationWarning = nil }
    }

    private func maintainCountAfterSelection() async throws {
        try assertStorageSettled()
        if try isAwaitingFirstMigratedLaunch() { return }
        let snapshot = try await keepCountSnapshot()
        let choice = defaults.string(forKey: NativeShellLibraryCoordinator.versionKeepCountUserDefaultsKey)
            .flatMap(VersionsKeptPerApp.init(rawValue:)) ?? .keepTwo
        let excess = snapshot.storedIds.subtracting(snapshot.retained(choice))
        if !excess.isEmpty { _ = try await removeSpecificRevisionsImpl(excess) }
        if try hasDeferredStoragePrune() { try finishOrdinaryStoragePrune() }
    }

    /// Every stored revision `pruneStorageImpl()` would remove right now, with
    /// its measured allocated bytes and creation time, for cross-app global
    /// cap planning
    /// (`NativeShellLibraryCoordinator.planGlobalCapEnforcement`/
    /// `enforceGlobalCap`). Read-only: computes the same exclusion
    /// `pruneStorageImpl()` uses (current, previous, pending, pinned) but
    /// removes nothing. Ordering matches `storageAllocationImpl()` (by
    /// revision id) for determinism; callers that need oldest-first order
    /// their own copy.
    private func prunableAllocationImpl() async throws -> [(revisionId: String, allocatedBytes: Int, createdAt: String)] {
        try assertStorageSettled()
        guard objectStorageReady else { throw NativeStorageError.recoveryRequired }
        _ = try objectRetainedSet()
        let coordinator = NativeShellLibraryCoordinator(rootURL: rootURL, shellVersion: shellVersion,
            capabilityPolicy: capabilityPolicy, fileManager: fileManager, defaults: defaults,
            downloadableRevisionIds: downloadableRevisionIds, versionFault: versionFault)
        let snapshots = try await coordinator.retentionSnapshots()
        var ledger = try NativeStorageReclaimLedger(root: rootURL, snapshots: snapshots)
        let candidates = snapshots.flatMap { snapshot in
            snapshot.versions.filter { !snapshot.protectedIds.contains($0.revisionId) }.map { (snapshot.identity, $0) }
        }.sorted {
            if $0.1.createdAt != $1.1.createdAt { return $0.1.createdAt < $1.1.createdAt }
            if $0.1.revisionId != $1.1.revisionId { return $0.1.revisionId < $1.1.revisionId }
            return $0.0.id < $1.0.id
        }
        var own: [(revisionId: String, allocatedBytes: Int, createdAt: String)] = []
        for (identity, version) in candidates {
            let bytes = ledger.select(identity: identity, revisionId: version.revisionId)
            if identity.appId == appId && identity.projectId == projectId {
                own.append((version.revisionId, Int(bytes), version.createdAt))
            }
        }
        return own
    }

    /// Removes exactly the given revision ids and nothing else. Refuses
    /// (throwing `NativeStorageError.cannotRemoveRetainedRevision`, removing
    /// none of the requested ids) if any named id is current, previous,
    /// pending or pinned at the moment this runs. This is a second, independent
    /// check beyond whatever excluded it from the caller's own plan, so a
    /// plan made stale by a pin or activation that happened after it was
    /// computed can never delete something now protected. An id that is
    /// simply not stored (already gone) is silently ignored, matching
    /// `unpin`'s treatment of an id that no longer exists. Same crash-safe
    /// rename-then-delete sequence as `pruneStorageImpl()`.
    @discardableResult
    private func removeSpecificRevisionsImpl(_ ids: Set<String>) async throws -> NativeStoragePruneReport {
        try assertStorageSettled()
        guard objectStorageReady, let store = versionStore else { throw NativeStorageError.recoveryRequired }
        let snapshot = try await keepCountSnapshot()
        _ = try objectRetainedSet()
        if let id = ids.sorted().first(where: { snapshot.protectedIds.contains($0) }) {
            throw NativeStorageError.cannotRemoveRetainedRevision(id)
        }
        let removable = ids.intersection(snapshot.storedIds)
        let oldestFirst = snapshot.versions.filter { removable.contains($0.revisionId) }.sorted {
            $0.createdAt == $1.createdAt ? $0.revisionId < $1.revisionId : $0.createdAt < $1.createdAt
        }.map(\.revisionId)
        for id in oldestFirst {
            // A catalog change can arrive during a facade await. Recheck the
            // authoritative offer and roles immediately before each tombstone.
            let current = try await keepCountSnapshot(checkRootSettlement: false)
            guard !current.protectedIds.contains(id) else { throw NativeStorageError.cannotRemoveRetainedRevision(id) }
            _ = try await store.freeVersion(appId: appId, projectId: projectId, revisionId: id)
        }
        return .init(removedRevisionIds: removable, retainedRevisionIds: try await keepCountSnapshot().storedIds)
    }

    private func objectRetainedSet() throws -> NativeStorageRetentionPolicy.RetainedSet {
        let versions = try versionStore!.manifests.list(appId: appId, projectId: projectId)
        for version in versions {
            _ = try verifyStoredRevision(version.revisionId, hashingContent: false)
        }
        let pointer = try readActivePointer()
        return NativeStorageRetentionPolicy.retainedSet(
            revisions: versions.map { .init(revisionId: $0.revisionId, baseRevisionId: $0.baseRevisionId, createdAt: $0.createdAt) },
            currentRevisionId: pointer?.currentRevisionId, fallbackRevisionId: pointer?.fallbackRevisionId,
            pinnedRevisionIds: try pinnedRevisionIdsImpl())
    }

    private func removeRevisionCrashSafely(_ revisionId: String, in revisionsDirectory: URL) throws {
        let source = revisionsDirectory.appendingPathComponent(revisionId, isDirectory: true)
        try rejectSymbolicLink(at: source)
        let tombstone = revisionsDirectory.appendingPathComponent(".trash-\(revisionId)", isDirectory: true)
        // A leftover from an earlier interrupted prune of this exact id.
        try? fileManager.removeItem(at: tombstone)
        try fileManager.moveItem(at: source, to: tombstone)
        try fileManager.removeItem(at: tombstone)
    }

    private func sweepTombstones(in revisionsDirectory: URL) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: revisionsDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(".trash-") {
            try rejectSymbolicLink(at: entry)
            try? fileManager.removeItem(at: entry)
        }
    }

    private func pinsURL() -> URL {
        stateRoot().appendingPathComponent("pinned-revisions.json")
    }

    private func validateDelivery(_ delivery: ContractValidatedDelivery) throws -> StoredRevision? {
        guard delivery.contractVersion == 1 else {
            throw NativeShellError.unsupportedContractVersion(delivery.contractVersion)
        }
        guard NativeSecurity.isStableId(delivery.appId) else {
            throw NativeShellError.invalidStableIdentifier(delivery.appId)
        }
        guard NativeSecurity.isStableId(delivery.projectId) else {
            throw NativeShellError.invalidStableIdentifier(delivery.projectId)
        }
        guard NativeSecurity.isStableId(delivery.dataNamespace) else {
            throw NativeShellError.invalidStableIdentifier(delivery.dataNamespace)
        }
        guard NativeSecurity.isNonce(delivery.deliveryNonce) else {
            throw NativeShellError.invalidDeliveryNonce
        }
        guard NativeSecurity.isSHA256(delivery.contentHash) else {
            throw NativeShellError.invalidContentHash
        }
        guard NativeSecurity.isRevisionId(delivery.revisionId),
              NativeSecurity.revisionId(forContentHash: delivery.contentHash) == delivery.revisionId else {
            throw NativeShellError.invalidRevisionIdentity
        }
        if let base = delivery.baseRevisionId, !NativeSecurity.isRevisionId(base) {
            throw NativeShellError.invalidRevisionIdentity
        }
        guard delivery.appId == appId else {
            throw NativeShellError.appMismatch(expected: appId, actual: delivery.appId)
        }
        guard delivery.projectId == projectId else {
            throw NativeShellError.projectMismatch(expected: projectId, actual: delivery.projectId)
        }

        let activeBase = try readActivePointer()?.currentRevisionId
        guard delivery.baseRevisionId == activeBase else {
            throw NativeShellError.baseMismatch(expected: activeBase, actual: delivery.baseRevisionId)
        }
        if try deliveryNonceWasUsed(delivery.deliveryNonce) {
            throw NativeShellError.deliveryReplay
        }

        guard NativeSecurity.compareSemver(shellVersion, shellVersion) != nil else {
            throw NativeShellError.invalidShellVersion(shellVersion)
        }
        guard let versionComparison = NativeSecurity.compareSemver(shellVersion, delivery.minShellVersion) else {
            throw NativeShellError.invalidShellVersion(delivery.minShellVersion)
        }
        if versionComparison == .orderedAscending {
            throw NativeShellError.shellTooOld(required: delivery.minShellVersion, actual: shellVersion)
        }
        try capabilityPolicy.validate(requested: delivery.requestedCapabilities)

        var activeRevision: StoredRevision?
        if let activeBase {
            let active = try verifyStoredRevision(activeBase)
            guard delivery.dataNamespace == active.manifest.dataNamespace else {
                throw NativeShellError.userDataNamespaceMismatch(
                    expected: active.manifest.dataNamespace,
                    actual: delivery.dataNamespace
                )
            }
            activeRevision = active
        }

        guard !delivery.files.isEmpty else { throw NativeShellError.missingEntrypoint(delivery.entrypoint) }
        guard NativeSecurity.isSafePackagePath(delivery.entrypoint) else {
            throw NativeShellError.invalidPackagePath(delivery.entrypoint)
        }

        var paths = Set<String>()
        for file in delivery.files {
            guard NativeSecurity.isSafePackagePath(file.path) else {
                throw NativeShellError.invalidPackagePath(file.path)
            }
            guard paths.insert(file.path).inserted else {
                throw NativeShellError.duplicatePackagePath(file.path)
            }
            guard NativeSecurity.isSHA256(file.sha256), file.bytes >= 0 else {
                throw NativeShellError.hashMismatch(file.path)
            }
            guard file.bytes <= NativeSecurity.maximumSingleFileBytes,
                  file.data.count == file.bytes else {
                throw NativeShellError.byteCountMismatch(file.path)
            }
            guard NativeSecurity.isMediaType(file.mediaType) else {
                throw NativeShellError.invalidPackageField("file mediaType: \(file.path)")
            }
        }
        guard paths.contains(delivery.entrypoint) else {
            throw NativeShellError.missingEntrypoint(delivery.entrypoint)
        }
        let identity = NativeSecurity.revisionIdentity(
            appId: delivery.appId,
            projectId: delivery.projectId,
            baseRevisionId: delivery.baseRevisionId,
            manifest: delivery.manifest,
            files: delivery.files,
            changes: delivery.changes
        )
        guard identity.manifestHash == delivery.manifestHash,
              identity.contentHash == delivery.contentHash,
              identity.revisionId == delivery.revisionId else {
            throw NativeShellError.invalidRevisionIdentity
        }
        return activeRevision
    }

    // Removal checks namespaces without migrating or deleting anything before
    // WebKit has accepted the person's data-deletion request.
    func versionStorageForRemoval() throws -> NativeVersionStore {
        try checkedVersionStore()
    }

    private func withStorage<T: Sendable>(
        _ operation: @escaping @Sendable (isolated NativeRevisionStore) async throws -> T
    ) async throws -> T {
        let store = try checkedVersionStore()
        return try await store.withExclusiveAccess {
            try await self.performStorageOperation(store: store, operation: operation)
        }
    }

    private func checkedVersionStore() throws -> NativeVersionStore {
        try autoreleasepool { try prepareVersionStoreNamespaces() }
    }

    private func prepareVersionStoreNamespaces() throws -> NativeVersionStore {
        let sharedStore = NativeRevisionReadContext.sharedStores[rootURL.path]
        if sharedStore == nil {
            try ensureOwnedDirectory(rootURL)
            try ensureOwnedDirectory(stateRoot())
            // Keep the existing app/project discovery directories for the coordinator.
            try ensureOwnedDirectory(revisionsRoot().deletingLastPathComponent())
            for name in ["objects", "manifests", "checkouts", "gc"] {
                try ensureOwnedDirectory(rootURL.appendingPathComponent(name, isDirectory: true))
            }
        } else {
            // The root-held screen read checked the common parents on entry.
            // Each app and project entry is still checked live, including links.
            for name in ["state", "content"] {
                let app = rootURL.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent(appId, isDirectory: true)
                try ensurePreparedChildDirectory(app)
                try ensurePreparedChildDirectory(app.appendingPathComponent(projectId, isDirectory: true))
            }
        }
        for name in ["manifests", "checkouts"] {
            let app = rootURL.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(appId, isDirectory: true)
            let project = app.appendingPathComponent(projectId, isDirectory: true)
            if sharedStore == nil {
                try ensureOwnedDirectory(project)
            } else {
                try ensurePreparedChildDirectory(app)
                try ensurePreparedChildDirectory(project)
            }
        }
        for url in [pointerURL(), pinsURL(), rootURL.appendingPathComponent("gc/refs.sqlite")] { try rejectSymbolicLink(at: url) }
        return try sharedStore ?? NativeVersionStore.shared(root: rootURL)
    }

    private func performStorageOperation<T: Sendable>(
        store: NativeVersionStore,
        operation: @Sendable (isolated NativeRevisionStore) async throws -> T
    ) async throws -> T {
        versionStore = store
        try await prepareObjectStorage()
        return try await operation(self)
    }

    private func prepareObjectStorage() async throws {
        let marker = stateRoot().appendingPathComponent("store-format")
        try rejectSymbolicLink(at: marker)
        if (try? String(contentsOf: marker, encoding: .utf8)) == "2" {
            objectStorageReady = true
            try rejectSymbolicLink(at: migrationDeferralURL)
            if fileManager.fileExists(atPath: migrationDeferralURL.path) { migrationWarning = Self.migratedStorageWarning }
            try await settleVersionStorage()
            return
        }
        objectStorageReady = false
        let revisions = revisionsRoot()
        try rejectSymbolicLink(at: revisions)
        let legacy = (try? fileManager.contentsOfDirectory(at: revisions, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        if !legacy.isEmpty {
            do {
                // Validate the complete original tree, including signed identity,
                // before migration imports anything or changes serving behavior.
                for child in legacy { _ = try verifyStoredRevision(child.lastPathComponent) }
                let pointer = try readActivePointer()
                let store = versionStore!
                try await store.migrateLegacy(appId: appId, projectId: projectId, legacyRevisionsRoot: revisions,
                    currentRevisionId: pointer?.currentRevisionId, fallbackRevisionId: pointer?.fallbackRevisionId,
                    fault: versionFault ?? .init())
                objectStorageReady = true
                for child in legacy { _ = try verifyStoredRevision(child.lastPathComponent, hashingContent: false) }
                for id in [pointer?.currentRevisionId, pointer?.fallbackRevisionId].compactMap({ $0 }) {
                    _ = try verifyStoredRevision(id)
                }
                try rejectSymbolicLink(at: migrationDeferralURL)
                try Data("waiting-for-launch".utf8).write(to: migrationDeferralURL, options: .atomic)
                migrationWarning = Self.migratedStorageWarning
            } catch let crash as NativeVersionSimulatedCrash {
                throw crash
            } catch {
                objectStorageReady = false
                migrationWarning = "Iris could not verify the storage update. The original app was kept."
                return
            }
        }
        objectStorageReady = true
        try Data("2".utf8).write(to: marker, options: .atomic)
        if fileManager.fileExists(atPath: migrationDeferralURL.path) { migrationWarning = Self.migratedStorageWarning }
        try await settleVersionStorage()
    }

    private func settleVersionStorage() async throws {
        if NativeRevisionReadContext.settledRoots.contains(rootURL.path) {
            // This is an operation-scoped proof under the root writer, never
            // a cached permission for later pruning or delivery. Check the
            // app's live journals before using the shared accounting read.
            try assertOwnStorageSettled()
            return
        }
        // MV1 resumes frees before settling swaps. If both exist, refuse the
        // adapter entry before that recovery can decrement or delete anything.
        // A swap-only recovery still uses the existing MV1 settlement engine.
        do { try assertStorageSettled() }
        catch NativeStorageError.recoveryRequired {
            if try hasUnfinishedVersionRemoval() { throw NativeStorageError.recoveryRequired }
        }
        let outcome = try await versionStore!.recoverIfNeeded(appId: appId, projectId: projectId, fault: versionFault ?? .init())
        if case .stuck = outcome { throw NativeStorageError.recoveryRequired }
        // Check this identity here. The coordinator settles each installed
        // identity in preflight before applying the whole-root barrier.
        let journal = stateRoot().appendingPathComponent("journal.json")
        try rejectSymbolicLink(at: journal)
        guard !fileManager.fileExists(atPath: journal.path) else { throw NativeStorageError.recoveryRequired }
        let migration = stateRoot().appendingPathComponent("migration.json")
        try rejectSymbolicLink(at: migration)
        if fileManager.fileExists(atPath: migration.path) {
            let value = try JSONDecoder().decode(NativeStoreMigrationJournal.self, from: Data(contentsOf: migration))
            guard value.done else { throw NativeStorageError.recoveryRequired }
        }
    }

    private func hasUnfinishedVersionRemoval() throws -> Bool {
        let manifests = rootURL.appendingPathComponent("manifests")
        guard fileManager.fileExists(atPath: manifests.path) else { return false }
        try requireExistingOwnedDirectory(manifests)
        for app in try fileManager.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil) {
            try requireExistingOwnedDirectory(app)
            for project in try fileManager.contentsOfDirectory(at: app, includingPropertiesForKeys: nil) {
                try requireExistingOwnedDirectory(project)
                if try fileManager.contentsOfDirectory(atPath: project.path).contains(where: { $0.hasSuffix(".json.tomb") }) {
                    return true
                }
            }
        }
        return false
    }

    private func stageIntoTemporaryDirectory(
        _ delivery: ContractValidatedDelivery,
        baseRevision: StoredRevision?,
        temporaryURL: URL
    ) throws {
        let contentURL = temporaryURL.appendingPathComponent("content", isDirectory: true)
        try fileManager.createDirectory(at: contentURL, withIntermediateDirectories: true)
        let baseFilesByPath = Dictionary(
            uniqueKeysWithValues: (baseRevision?.files ?? []).map { ($0.path, $0) }
        )

        for file in delivery.files {
            let destination = contentURL.appendingPathComponent(file.path, isDirectory: false).standardizedFileURL
            guard NativeSecurity.isDescendant(destination, of: contentURL) else {
                throw NativeShellError.invalidPackagePath(file.path)
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard file.data.count == file.bytes else { throw NativeShellError.byteCountMismatch(file.path) }
            if let baseRevision,
               let baseFile = baseFilesByPath[file.path],
               baseFile.sha256 == file.sha256,
               baseFile.bytes == file.bytes,
               baseFile.mediaType == file.mediaType {
                let source = revisionsRoot()
                    .appendingPathComponent(baseRevision.revisionId, isDirectory: true)
                    .appendingPathComponent("content", isDirectory: true)
                    .appendingPathComponent(file.path, isDirectory: false)
                    .standardizedFileURL
                if try cloneVerifiedUnchangedFile(
                    from: source,
                    to: destination,
                    expectedSHA256: file.sha256,
                    expectedBytes: file.bytes
                ) {
                    continue
                }
            }
            try file.data.write(to: destination, options: [.atomic])
        }

        let metadata = StoredRevision(
            contractVersion: delivery.contractVersion,
            appId: delivery.appId,
            projectId: delivery.projectId,
            baseRevisionId: delivery.baseRevisionId,
            revisionId: delivery.revisionId,
            manifestHash: delivery.manifestHash,
            contentHash: delivery.contentHash,
            createdAt: delivery.createdAt,
            manifest: StoredManifest(
                displayName: delivery.manifest.displayName,
                runtimeType: delivery.manifest.runtimeType,
                entrypoint: delivery.manifest.entrypoint,
                minShellVersion: delivery.manifest.minShellVersion,
                requestedCapabilities: delivery.manifest.requestedCapabilities,
                dataNamespace: delivery.manifest.dataNamespace,
                dataUpdatePolicy: delivery.manifest.dataUpdatePolicy
            ),
            files: delivery.files
                .map { StoredFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, mediaType: $0.mediaType) }
                .sorted { $0.path < $1.path },
            changes: delivery.changes
        )
        try atomicWrite(metadata, to: temporaryURL.appendingPathComponent("metadata.json"))
    }

    private func cloneVerifiedUnchangedFile(
        from source: URL,
        to destination: URL,
        expectedSHA256: String,
        expectedBytes: Int
    ) throws -> Bool {
        let cloneResult = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        guard cloneResult == 0 else { return false }

        do {
            try rejectSymbolicLink(at: destination)
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw NativeShellError.storedRevisionInvalid("staging-clone")
            }
            let data = try Data(contentsOf: destination, options: [.mappedIfSafe])
            guard data.count == expectedBytes,
                  NativeSecurity.sha256(data) == expectedSHA256 else {
                throw NativeShellError.storedRevisionInvalid("staging-clone")
            }
            return true
        } catch {
            try? fileManager.removeItem(at: destination)
            if fileManager.fileExists(atPath: destination.path) {
                throw error
            }
            return false
        }
    }

    @discardableResult
    /// `hashingContent: false` is the measurement read used only by the
    /// Library and Storage screens (`storageAllocationImpl()`): the metadata, the
    /// exact file tree (every declared file present, regular, no symlink, no
    /// extra entry) and every per-file rule are still checked, but file bytes
    /// are not re-read and re-hashed. Re-hashing every stored version of every
    /// app on each screen open costs about 1.9 s at 100 apps x 5 versions
    /// (debug build, R2-mobile-integration) against SPEC R8.10's 500 ms.
    /// Nothing that runs, pins, activates, reverts or prunes code uses this
    /// mode; those paths still verify every byte before acting.
    private func verifyStoredRevision(
        _ revisionId: String,
        expected: ContractValidatedDelivery? = nil,
        hashingContent: Bool = true,
        includeFreed: Bool = false,
        verifyingObjects: Bool = true,
        measurementManifest: NativeVersionManifest? = nil
    ) throws -> StoredRevision {
        // The root-held measurement inventory has already validated this id.
        // Every other caller retains the original check before building a path.
        if hashingContent || measurementManifest?.revisionId != revisionId || versionStore?.hasAllocationSnapshot != true {
            guard NativeSecurity.isRevisionId(revisionId) else { throw NativeShellError.revisionNotStaged(revisionId) }
        }
        let metadata: StoredRevision
        var cachedValidation = false
        var cacheSource: (NativeVersionManifest, String)?
        if objectStorageReady, let store = versionStore {
            let suffix = includeFreed && !store.manifests.exists(appId: appId, projectId: projectId, revisionId: revisionId) ? ".json.freed" : ".json"
            let manifestURL = URL(fileURLWithPath: store.manifests.root.path + "/" + appId + "/" + projectId + "/" + revisionId + suffix, isDirectory: false)
            try assertOwnedFileComponents(manifestURL)
            guard fileManager.fileExists(atPath: manifestURL.path) else { throw NativeShellError.revisionNotStaged(revisionId) }
            let version: NativeVersionManifest
            if !hashingContent, store.hasAllocationSnapshot, let measurementManifest {
                version = measurementManifest
            } else {
                version = try includeFreed
                    ? store.manifests.readHistory(appId: appId, projectId: projectId, revisionId: revisionId)
                    : store.manifests.read(appId: appId, projectId: projectId, revisionId: revisionId)
            }
            cacheSource = (version, manifestURL.path)
            if let cached = Self.metadataValidationCache.get(version, path: manifestURL.path) {
                metadata = cached
                cachedValidation = true
            } else {
            guard let manifest = version.manifest else { throw NativeShellError.storedRevisionInvalid(revisionId) }
            let receipt = DeliveryManifestReceipt(displayName: manifest.displayName, runtimeType: manifest.runtimeType,
                entrypoint: manifest.entrypoint, minShellVersion: manifest.minShellVersion,
                requestedCapabilities: manifest.requestedCapabilities, dataNamespace: manifest.dataNamespace,
                dataUpdatePolicy: manifest.dataUpdatePolicy)
            let files = version.files.map { file in StoredFile(path: file.path,
                sha256: file.sha256.hasPrefix("sha256:") ? file.sha256 : "sha256:" + file.sha256,
                bytes: file.bytes, mediaType: file.mediaType) }.sorted { $0.path < $1.path }
            let identity = NativeSecurity.revisionIdentity(appId: appId, projectId: projectId,
                baseRevisionId: version.baseRevisionId, manifest: receipt,
                files: files.map { .init(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, mediaType: $0.mediaType, data: Data()) },
                changes: version.changes)
            metadata = StoredRevision(contractVersion: 1, appId: appId, projectId: projectId,
                baseRevisionId: version.baseRevisionId, revisionId: version.revisionId,
                manifestHash: identity.manifestHash, contentHash: version.contentHash, createdAt: version.createdAt,
                manifest: StoredManifest(displayName: manifest.displayName, runtimeType: manifest.runtimeType,
                    entrypoint: manifest.entrypoint, minShellVersion: manifest.minShellVersion,
                    requestedCapabilities: manifest.requestedCapabilities, dataNamespace: manifest.dataNamespace,
                    dataUpdatePolicy: manifest.dataUpdatePolicy), files: files, changes: version.changes)
            guard identity.contentHash == version.contentHash, identity.revisionId == revisionId else {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
            }
        } else {
        let revisionsURL = revisionsRoot()
        // Measurement mode: `storageAllocationImpl()` has already proved the
        // revisions folder itself is owned and link-free, so each child only
        // needs to be a real directory, not a link (same guarantee, without
        // resolving the whole ancestor chain again for every version).
        if hashingContent { try ensureOwnedDirectory(revisionsURL) }
        let revisionURL = revisionsURL.appendingPathComponent(revisionId, isDirectory: true)
        guard fileManager.fileExists(atPath: revisionURL.path) else {
            throw NativeShellError.revisionNotStaged(revisionId)
        }
        if hashingContent { try requireExistingOwnedDirectory(revisionURL) } else { try requirePlainChildDirectory(revisionURL) }
        let metadataURL = revisionURL.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw NativeShellError.revisionNotStaged(revisionId)
        }

        do {
            metadata = try JSONDecoder().decode(StoredRevision.self, from: Data(contentsOf: metadataURL))
        } catch {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        }
        if !cachedValidation {
        guard metadata.contractVersion == 1,
              metadata.appId == appId,
              metadata.projectId == projectId,
              metadata.revisionId == revisionId,
              NativeSecurity.revisionId(forContentHash: metadata.contentHash) == revisionId,
              NativeSecurity.isSHA256(metadata.manifestHash),
              NativeSecurity.isSHA256(metadata.contentHash),
              Self.metadataValidationCache.canonicalTimestamp(metadata.createdAt),
              metadata.baseRevisionId == nil || NativeSecurity.isRevisionId(metadata.baseRevisionId!),
              !metadata.manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.manifest.displayName.utf16.count <= 120,
              metadata.manifest.runtimeType == "web",
              NativeSecurity.isSafePackagePath(metadata.manifest.entrypoint),
              NativeSecurity.compareSemver(metadata.manifest.minShellVersion, metadata.manifest.minShellVersion) != nil,
              NativeSecurity.isStableId(metadata.manifest.dataNamespace),
              metadata.manifest.dataUpdatePolicy == "preserve",
              Set(metadata.manifest.requestedCapabilities).count == metadata.manifest.requestedCapabilities.count,
              metadata.manifest.requestedCapabilities.allSatisfy(NativeSecurity.knownCapabilities.contains) else {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        }
        try capabilityPolicy.validate(requested: metadata.manifest.requestedCapabilities)

        if let expected {
            let expectedFiles = expected.files
                .map { StoredFile(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, mediaType: $0.mediaType) }
                .sorted { $0.path < $1.path }
            let expectedManifest = StoredManifest(
                displayName: expected.manifest.displayName,
                runtimeType: expected.manifest.runtimeType,
                entrypoint: expected.manifest.entrypoint,
                minShellVersion: expected.manifest.minShellVersion,
                requestedCapabilities: expected.manifest.requestedCapabilities,
                dataNamespace: expected.manifest.dataNamespace,
                dataUpdatePolicy: expected.manifest.dataUpdatePolicy
            )
            guard metadata.baseRevisionId == expected.baseRevisionId,
                  metadata.manifestHash == expected.manifestHash,
                  metadata.contentHash == expected.contentHash,
                  metadata.createdAt == expected.createdAt,
                  metadata.manifest == expectedManifest,
                  metadata.files == expectedFiles,
                  metadata.changes == expected.changes else {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
        }

        let contentURL: URL
        let usesCheckout: Bool
        if objectStorageReady, let store = versionStore {
            if hashingContent {
                contentURL = store.checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: revisionId)
                usesCheckout = store.checkouts.exists(appId: appId, projectId: projectId, revisionId: revisionId)
            } else {
                let path = store.checkouts.root.path + "/" + appId + "/" + projectId + "/" + revisionId
                contentURL = URL(fileURLWithPath: path + "/content", isDirectory: true)
                usesCheckout = fileManager.fileExists(atPath: path)
            }
        } else {
            contentURL = revisionsRoot().appendingPathComponent(revisionId).appendingPathComponent("content", isDirectory: true)
            usesCheckout = true
        }
        if usesCheckout {
            if hashingContent { try requireExistingOwnedDirectory(contentURL) }
            else { try requirePlainChildDirectory(contentURL) }
            try verifyExactContentTree(contentURL: contentURL, files: metadata.files, revisionId: revisionId)
        }
        var seen = Set<String>()
        var verifiedFiles: [DeliveryFileReceipt] = []
        var decodedTotal = 0
        for file in metadata.files {
            if !cachedValidation {
            guard NativeSecurity.isSafePackagePath(file.path),
                  NativeSecurity.isSHA256(file.sha256),
                  NativeSecurity.isMediaType(file.mediaType),
                  file.bytes >= 0,
                  file.bytes <= NativeSecurity.maximumSingleFileBytes,
                  seen.insert(file.path).inserted else {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
            decodedTotal += file.bytes
            guard decodedTotal <= NativeSecurity.maximumDecodedPackageBytes else {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
            }
            // Safe relative paths and object hashes were validated above.
            // Measurement needs the live exact tree, never a launch URL.
            guard hashingContent else { continue }
            let url = usesCheckout
                ? contentURL.appendingPathComponent(file.path).standardizedFileURL
                : versionStore!.objects.path(forSHA256: String(file.sha256.dropFirst(7)))
            let accessRoot = usesCheckout ? contentURL : versionStore!.objects.root
            guard NativeSecurity.isDescendant(url, of: accessRoot) else {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
            do {
                try NativeSecurity.assertNoSymlinkComponents(from: storageAccessRoot(for: url), to: url, fileManager: fileManager)
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw NativeShellError.storedRevisionInvalid(revisionId)
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count == file.bytes, NativeSecurity.sha256(data) == file.sha256 else {
                    throw NativeShellError.storedRevisionInvalid(revisionId)
                }
                if objectStorageReady, usesCheckout, verifyingObjects, let store = versionStore {
                    let objectURL = store.objects.path(forSHA256: String(file.sha256.dropFirst(7)))
                    try NativeSecurity.assertNoSymlinkComponents(from: storageAccessRoot(for: objectURL), to: objectURL, fileManager: fileManager)
                    let objectAttributes = try fileManager.attributesOfItem(atPath: objectURL.path)
                    guard objectAttributes[.type] as? FileAttributeType == .typeRegular,
                          try store.objects.verify(sha256: String(file.sha256.dropFirst(7))) else {
                        throw NativeShellError.storedRevisionInvalid(revisionId)
                    }
                }
                verifiedFiles.append(
                    DeliveryFileReceipt(
                        path: file.path,
                        sha256: file.sha256,
                        bytes: file.bytes,
                        mediaType: file.mediaType,
                        data: data
                    )
                )
            } catch let shellError as NativeShellError {
                throw shellError
            } catch {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
        }
        if !cachedValidation {
        guard let entrypoint = metadata.files.first(where: { $0.path == metadata.manifest.entrypoint }),
              entrypoint.mediaType == "text/html" else {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        guard !NativeSecurity.hasStoragePathAlias(metadata.files.map(\.path)) else {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        if let (version, path) = cacheSource {
            Self.metadataValidationCache.insert(version, metadata: metadata, path: path)
        }
        }
        guard hashingContent else { return metadata }
        let manifestReceipt = DeliveryManifestReceipt(
            displayName: metadata.manifest.displayName,
            runtimeType: metadata.manifest.runtimeType,
            entrypoint: metadata.manifest.entrypoint,
            minShellVersion: metadata.manifest.minShellVersion,
            requestedCapabilities: metadata.manifest.requestedCapabilities,
            dataNamespace: metadata.manifest.dataNamespace,
            dataUpdatePolicy: metadata.manifest.dataUpdatePolicy
        )
        let identity = NativeSecurity.revisionIdentity(
            appId: metadata.appId,
            projectId: metadata.projectId,
            baseRevisionId: metadata.baseRevisionId,
            manifest: manifestReceipt,
            files: verifiedFiles,
            changes: metadata.changes
        )
        guard identity.manifestHash == metadata.manifestHash,
              identity.contentHash == metadata.contentHash,
              identity.revisionId == metadata.revisionId else {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        return metadata
    }

    private func launchDescriptor(for revisionId: String, verifyingObjects: Bool = true) throws -> VerifiedLaunchDescriptor {
        if objectStorageReady, let store = versionStore,
           !store.checkouts.exists(appId: appId, projectId: projectId, revisionId: revisionId) {
            let manifest = try store.manifests.read(appId: appId, projectId: projectId, revisionId: revisionId)
            _ = try store.checkouts.build(manifest: manifest, appId: appId, projectId: projectId)
        }
        let metadata = try verifyStoredRevision(revisionId, verifyingObjects: verifyingObjects)
        let contentURL = objectStorageReady
            ? versionStore!.checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: revisionId)
            : revisionsRoot().appendingPathComponent(revisionId, isDirectory: true).appendingPathComponent("content", isDirectory: true)
        let entrypointURL = contentURL.appendingPathComponent(metadata.manifest.entrypoint).standardizedFileURL
        guard NativeSecurity.isDescendant(entrypointURL, of: contentURL) else {
            throw NativeShellError.storedRevisionInvalid(revisionId)
        }
        let webStorageIdentity: NativeWebStorageIdentity?
        if metadata.manifest.requestedCapabilities.contains("web.storage") {
            webStorageIdentity = try NativeWebStorageIdentity(
                appId: metadata.appId,
                projectId: metadata.projectId,
                dataNamespace: metadata.manifest.dataNamespace
            )
        } else {
            webStorageIdentity = nil
        }
        return VerifiedLaunchDescriptor(
            identity: NativeShellAppIdentity(appId: metadata.appId, projectId: metadata.projectId),
            revisionId: revisionId,
            entrypointURL: entrypointURL,
            readAccessRootURL: contentURL,
            webStorageIdentity: webStorageIdentity,
            requestedCapabilities: metadata.manifest.requestedCapabilities,
            resources: metadata.files.map { NativeVerifiedResourceReceipt(path: $0.path, sha256: $0.sha256, bytes: $0.bytes, mediaType: $0.mediaType) }
        )
    }

    private func revisionsRoot() -> URL {
        revisionsDirectoryURL
    }

    private func stateRoot() -> URL {
        stateDirectoryURL
    }

    private func pointerURL() -> URL {
        stateRoot().appendingPathComponent("active.json")
    }

    private func readActivePointer() throws -> ActivePointer? {
        if versionStore?.hasAllocationSnapshot == true {
            try requirePlainChildDirectory(stateRoot())
        } else {
            try ensureOwnedDirectory(stateRoot())
        }
        let url = pointerURL()
        try rejectSymbolicLink(at: url)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ActivePointer.self, from: Data(contentsOf: url))
        } catch {
            throw NativeShellError.storedRevisionInvalid("active-pointer")
        }
    }

    private func writeActivePointer(_ pointer: ActivePointer) throws {
        try ensureOwnedDirectory(stateRoot())
        if objectStorageReady, let store = versionStore {
            try store.state.writeActive(.init(currentRevisionId: pointer.currentRevisionId,
                fallbackRevisionId: pointer.fallbackRevisionId), appId: appId, projectId: projectId)
            return
        }
        try atomicWrite(pointer, to: pointerURL())
    }

    private func deliveryNonceWasUsed(_ nonce: String) throws -> Bool {
        let marker = replayMarkerURL(nonce)
        try ensureOwnedDirectory(marker.deletingLastPathComponent())
        try rejectSymbolicLink(at: marker)
        return fileManager.fileExists(atPath: marker.path)
    }

    private func recordDeliveryNonce(_ nonce: String, contentHash: String) throws {
        let marker = replayMarkerURL(nonce)
        try ensureOwnedDirectory(marker.deletingLastPathComponent())
        try rejectSymbolicLink(at: marker)
        if fileManager.fileExists(atPath: marker.path) { throw NativeShellError.deliveryReplay }
        try Data(contentHash.utf8).write(to: marker, options: [.atomic])
    }

    private func replayMarkerURL(_ nonce: String) -> URL {
        let digest = NativeSecurity.sha256(Data(nonce.utf8)).dropFirst(NativeSecurity.sha256Prefix.count)
        return stateRoot()
            .appendingPathComponent("delivery-nonces", isDirectory: true)
            .appendingPathComponent(String(digest), isDirectory: false)
    }

    private func storageAccessRoot(for url: URL) -> URL {
        let root = rootURL
        let target = url.standardizedFileURL.path
        let rootPath = root.path
        if target == rootPath || target.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") { return root }
        // The screen snapshot already holds the freshly resolved root writer.
        // Reuse that canonical root for /var and /private/var aliases during
        // this read only; every manifest component is still checked with lstat.
        if let store = versionStore, store.hasAllocationSnapshot {
            let canonical = store.root
            let path = canonical.path
            if target == path || target.hasPrefix(path == "/" ? "/" : path + "/") { return canonical }
        }
        // Every other operation resolves aliases live as before.
        return root.resolvingSymlinksInPath().standardizedFileURL
    }

    private func ensureOwnedDirectory(_ directory: URL) throws {
        let target = directory.standardizedFileURL
        try rejectSymbolicLink(at: rootURL)
        let root = storageAccessRoot(for: target)
        guard target.path == root.path || target.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
            throw NativeShellError.unsafeStorageNamespace(target.path)
        }

        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard errno == ENOENT else { throw NativeShellError.unsafeStorageNamespace(root.path) }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try requirePlainChildDirectory(root)

        // Standardized relative components cannot escape the root. Checking
        // each entry with lstat proves every component is a directory rather
        // than a link, without repeatedly resolving the entire ancestor path.
        let relative = target.path.dropFirst(root.path.count).split(separator: "/")
        var cursor = root.path
        for component in relative {
            cursor += "/" + component
            if lstat(cursor, &info) != 0 {
                guard errno == ENOENT else { throw NativeShellError.unsafeStorageNamespace(cursor) }
                let url = URL(fileURLWithPath: cursor, isDirectory: true)
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
                try requirePlainChildDirectory(url)
            } else {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw NativeShellError.unsafeStorageNamespace(cursor)
                }
            }
        }
    }

    private func requireExistingOwnedDirectory(_ directory: URL) throws {
        let target = directory.standardizedFileURL
        try ensureOwnedDirectory(target.deletingLastPathComponent())
        try rejectSymbolicLink(at: target)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeShellError.unsafeStorageNamespace(target.path)
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedTarget == resolvedRoot || NativeSecurity.isDescendant(resolvedTarget, of: resolvedRoot) else {
            throw NativeShellError.unsafeStorageNamespace(target.path)
        }
    }

    /// A directory entry that is itself a real directory (never a link),
    /// checked with one `lstat`. Only for children of a folder that
    /// `ensureOwnedDirectory` already proved safe in the same call.
    private func requirePlainChildDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw NativeShellError.unsafeStorageNamespace(url.path)
        }
    }

    /// Only for a child of a common parent verified by the root-held read.
    /// A missing child takes the full creation and ancestor validation path.
    private func ensurePreparedChildDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw NativeShellError.unsafeStorageNamespace(url.path) }
            try ensureOwnedDirectory(url)
        } else {
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw NativeShellError.unsafeStorageNamespace(url.path)
            }
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            throw NativeShellError.unsafeStorageNamespace(url.path)
        }
    }

    /// Equivalent component checks with lstat, without constructing Foundation
    /// attribute dictionaries for every ancestor of every manifest row.
    private func assertOwnedFileComponents(_ file: URL) throws {
        let target = file.standardizedFileURL.path
        let root = storageAccessRoot(for: file).path
        guard target.hasPrefix(root + "/") else {
            throw NativeShellError.sourceOutsidePackage(file.path)
        }
        var cursor = root
        let components = target.dropFirst(root.count + 1).split(separator: "/")
        for component in components {
            cursor += "/" + component
            var info = stat()
            guard lstat(cursor, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                throw NativeShellError.sourceSymlink(file.path)
            }
        }
    }

    private func verifyExactContentTree(
        contentURL: URL,
        files: [StoredFile],
        revisionId: String
    ) throws {
        let declaredFiles = Set(files.map(\.path))
        var requiredDirectories = Set<String>()
        for path in declaredFiles {
            let segments = path.split(separator: "/").map(String.init)
            if segments.count > 1 {
                for end in 1..<segments.count {
                    requiredDirectories.insert(segments.prefix(end).joined(separator: "/"))
                }
            }
        }

        var foundFiles = Set<String>()
        var pending: [(path: String, relative: String)] = [(contentURL.path, "")]
        while let current = pending.popLast() {
            let children: [String]
            do {
                children = try fileManager.contentsOfDirectory(atPath: current.path)
            } catch {
                throw NativeShellError.storedRevisionInvalid(revisionId)
            }
            for name in children {
                do {
                    let path = current.path + "/" + name
                    var info = stat()
                    guard lstat(path, &info) == 0 else {
                        throw NativeShellError.storedRevisionInvalid(revisionId)
                    }
                    let relative = current.relative.isEmpty ? name : "\(current.relative)/\(name)"
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        guard requiredDirectories.contains(relative) else {
                            throw NativeShellError.storedRevisionInvalid(revisionId)
                        }
                        pending.append((path, relative))
                    case S_IFREG:
                        guard declaredFiles.contains(relative), foundFiles.insert(relative).inserted else {
                            throw NativeShellError.storedRevisionInvalid(revisionId)
                        }
                    default:
                        throw NativeShellError.storedRevisionInvalid(revisionId)
                    }
                } catch let shellError as NativeShellError {
                    throw shellError
                } catch {
                    throw NativeShellError.storedRevisionInvalid(revisionId)
                }
            }
        }
        guard foundFiles == declaredFiles else { throw NativeShellError.storedRevisionInvalid(revisionId) }
    }

    private func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureOwnedDirectory(url.deletingLastPathComponent())
        try rejectSymbolicLink(at: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
