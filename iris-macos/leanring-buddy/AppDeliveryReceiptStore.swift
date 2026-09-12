import Foundation
import Darwin
import CryptoKit

/// Durable, path-bound metadata for one installed-app delivery. The receipt is
/// recovery evidence, not proof that any path still contains the recorded app.
nonisolated struct AppDeliveryReceipt: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, installed, restored }

    /// The exact source revision that produced the replacement bundle. Older
    /// receipts do not have this value, so they remain readable but cannot be
    /// used to start an Undo after a restart.
    struct SourceIdentity: Codable, Equatable, Sendable {
        let appSlug: String
        let appName: String
        let clonePath: String
        let branchName: String
        let commit: String
        let baseCommit: String
        let baseRef: String?
        let changeId: String

        init(
            appSlug: String,
            appName: String,
            clonePath: String,
            branchName: String,
            commit: String,
            baseCommit: String,
            baseRef: String?,
            changeId: String
        ) {
            self.appSlug = appSlug
            self.appName = appName
            self.clonePath = clonePath
            self.branchName = branchName
            self.commit = commit
            self.baseCommit = baseCommit
            self.baseRef = baseRef
            self.changeId = changeId
        }

        var isValid: Bool {
            let textValues = [appSlug, appName, branchName, changeId]
            return !appSlug.isEmpty && !appName.isEmpty
                && textValues.allSatisfy(AppDeliveryReceipt.isSafeMetadataText)
                && AppDeliveryReceipt.isCanonicalAbsolutePath(clonePath)
                && AppDeliveryReceipt.isGitObjectID(commit)
                && AppDeliveryReceipt.isGitObjectID(baseCommit)
                && (baseRef == nil || AppDeliveryReceipt.isSafeMetadataText(baseRef!))
        }
    }

    /// Identity read from a bundle's Info.plist before delivery. This records
    /// the old installed identity as well as the fresh replacement identity so
    /// Undo can refuse a path or bundle that changed after Iris restarted.
    struct BundleIdentity: Codable, Equatable, Sendable {
        let bundleIdentifier: String
        let bundleName: String
        let shortVersion: String?
        let version: String?
        let executable: String?
        /// A deterministic digest of the bundle payload, including relative
        /// paths, file kinds, modes, and bytes. It catches a replacement that
        /// keeps the same bundle identifier and version. This is optional only
        /// for decoding old receipts; a new receipt cannot be Undoable without
        /// it.
        let contentDigest: String?

        init(
            bundleIdentifier: String,
            bundleName: String,
            shortVersion: String? = nil,
            version: String? = nil,
            executable: String? = nil,
            contentDigest: String? = nil
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.bundleName = bundleName
            self.shortVersion = shortVersion
            self.version = version
            self.executable = executable
            self.contentDigest = contentDigest
        }

        var isValid: Bool {
            guard !bundleIdentifier.isEmpty, !bundleName.isEmpty,
                  AppDeliveryReceipt.isSafeMetadataText(bundleIdentifier),
                  AppDeliveryReceipt.isSafeMetadataText(bundleName),
                  !bundleIdentifier.contains("/") else { return false }
            guard ([shortVersion, version, executable].compactMap { $0 })
                .allSatisfy(AppDeliveryReceipt.isSafeMetadataText) else { return false }
            guard let contentDigest else { return true }
            return AppDeliveryReceipt.isSHA256Digest(contentDigest)
        }

        /// Compare the inexpensive Info.plist portion of an identity. The
        /// content digest is checked separately off the main actor.
        func matchesMetadata(of other: BundleIdentity) -> Bool {
            bundleIdentifier == other.bundleIdentifier
                && bundleName == other.bundleName
                && shortVersion == other.shortVersion
                && version == other.version
                && executable == other.executable
        }
    }

    static let currentVersion = 1
    let version: Int
    let identifier: UUID
    let bundleIdentifier: String
    let installedPath: String
    let sourceArtifactPath: String
    let backupPath: String
    let startedAt: Date
    let phase: Phase
    let sourceIdentity: SourceIdentity?
    let installedBundleIdentity: BundleIdentity?
    let replacementBundleIdentity: BundleIdentity?
    let backupBundleIdentity: BundleIdentity?

    init(
        identifier: UUID = UUID(), bundleIdentifier: String, installedPath: String,
        sourceArtifactPath: String, backupPath: String, startedAt: Date = Date(),
        phase: Phase = .prepared,
        sourceIdentity: SourceIdentity? = nil,
        installedBundleIdentity: BundleIdentity? = nil,
        replacementBundleIdentity: BundleIdentity? = nil,
        backupBundleIdentity: BundleIdentity? = nil
    ) {
        self.version = Self.currentVersion
        self.identifier = identifier
        self.bundleIdentifier = bundleIdentifier
        self.installedPath = installedPath
        self.sourceArtifactPath = sourceArtifactPath
        self.backupPath = backupPath
        self.startedAt = startedAt
        self.phase = phase
        self.sourceIdentity = sourceIdentity
        self.installedBundleIdentity = installedBundleIdentity
        self.replacementBundleIdentity = replacementBundleIdentity
        self.backupBundleIdentity = backupBundleIdentity
    }

    struct Identity: Equatable, Sendable {
        let identifier: UUID
        let bundleIdentifier: String
        let installedPath: String
        let sourceArtifactPath: String
        let backupPath: String
        let startedAt: Date
        let sourceIdentity: SourceIdentity?
        let installedBundleIdentity: BundleIdentity?
        let replacementBundleIdentity: BundleIdentity?
        let backupBundleIdentity: BundleIdentity?
    }

    var identity: Identity {
        Identity(identifier: identifier, bundleIdentifier: bundleIdentifier,
                 installedPath: installedPath, sourceArtifactPath: sourceArtifactPath,
                 backupPath: backupPath, startedAt: startedAt,
                 sourceIdentity: sourceIdentity,
                 installedBundleIdentity: installedBundleIdentity,
                 replacementBundleIdentity: replacementBundleIdentity,
                 backupBundleIdentity: backupBundleIdentity)
    }

    /// New deliveries must carry all fields needed to reconstruct an Undo.
    /// Legacy receipts remain visible and inspectable, but this is false for
    /// them so a restart cannot guess which source or bundle to restore.
    var hasCompleteUndoMetadata: Bool {
        guard phase == .installed,
              let sourceIdentity, sourceIdentity.isValid,
              let installedBundleIdentity, installedBundleIdentity.isValid,
              let replacementBundleIdentity, replacementBundleIdentity.isValid,
              let backupBundleIdentity, backupBundleIdentity.isValid,
              installedBundleIdentity.contentDigest != nil,
              replacementBundleIdentity.contentDigest != nil,
              backupBundleIdentity.contentDigest != nil else { return false }
        return installedBundleIdentity == backupBundleIdentity
            && replacementBundleIdentity.bundleIdentifier == bundleIdentifier
            && installedBundleIdentity.bundleIdentifier == bundleIdentifier
    }

    /// Read the stable bundle identity and a deterministic payload digest. The
    /// path itself stays in the receipt because two bundles with one identifier
    /// can coexist. This can be called from a detached delivery task; callers
    /// on the main actor should use `bundleMetadataIdentity` for a quick UI
    /// check and perform this full probe off the actor.
    static func bundleIdentity(atPath path: String) -> BundleIdentity? {
        guard let metadata = bundleMetadataIdentity(atPath: path) else { return nil }
        guard let contentDigest = bundleContentDigest(atPath: path) else { return nil }
        return BundleIdentity(
            bundleIdentifier: metadata.bundleIdentifier,
            bundleName: metadata.bundleName,
            shortVersion: metadata.shortVersion,
            version: metadata.version,
            executable: metadata.executable,
            contentDigest: contentDigest
        )
    }

    /// Read Info.plist only. This deliberately does not claim that the bundle
    /// payload is unchanged; it is for synchronous path/metadata checks before
    /// an asynchronous content probe.
    static func bundleMetadataIdentity(atPath path: String) -> BundleIdentity? {
        guard isCanonicalAbsolutePath(path),
              let data = FileManager.default.contents(atPath: path + "/Contents/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else { return nil }
        let bundleName = (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard !bundleName.isEmpty else { return nil }
        return BundleIdentity(
            bundleIdentifier: bundleIdentifier,
            bundleName: bundleName,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            version: info["CFBundleVersion"] as? String,
            executable: info["CFBundleExecutable"] as? String,
            contentDigest: nil
        )
    }

    var isValid: Bool {
        guard version == Self.currentVersion,
              !bundleIdentifier.isEmpty, bundleIdentifier == bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines),
              bundleIdentifier.utf8.count <= 1024,
              !bundleIdentifier.contains("/"),
              !bundleIdentifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              startedAt.timeIntervalSince1970.isFinite else { return false }
        let paths = [installedPath, sourceArtifactPath, backupPath]
        guard Set(paths).count == paths.count && paths.allSatisfy(Self.isCanonicalAbsolutePath) else { return false }
        if let sourceIdentity, !sourceIdentity.isValid { return false }
        return [installedBundleIdentity, replacementBundleIdentity, backupBundleIdentity]
            .compactMap { $0 }.allSatisfy { $0.isValid }
    }

    fileprivate static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    fileprivate static func isSafeMetadataText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 4096
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    fileprivate static func isGitObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.allSatisfy { $0.isHexDigit }
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    /// Hash a bundle without following directory symlinks. Framework bundles
    /// commonly contain symlinks, so their target path is included as payload
    /// evidence while the target is not traversed a second time. A failed or
    /// unreadable entry returns nil and therefore disables Undo rather than
    /// accepting an unverified app.
    private static func bundleContentDigest(atPath path: String) -> String? {
        var hasher = SHA256()
        guard appendDigest(forPath: path, relativePath: "", hasher: &hasher) else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendDigest(
        forPath path: String,
        relativePath: String,
        hasher: inout SHA256
    ) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return false }
        let kind = metadata.st_mode & S_IFMT
        if kind == S_IFLNK {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                return false
            }
            updateDigest("link", relativePath, target, 0, metadata.st_mode, hasher: &hasher)
            return true
        }
        if kind == S_IFDIR {
            // Directory st_size is allocation/filesystem metadata and can
            // differ after a copy even when every child byte is identical.
            updateDigest("directory", relativePath, nil, 0, metadata.st_mode, hasher: &hasher)
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                return false
            }
            for child in children.sorted() {
                let childPath = (path as NSString).appendingPathComponent(child)
                let childRelativePath = relativePath.isEmpty ? child : relativePath + "/" + child
                guard appendDigest(forPath: childPath, relativePath: childRelativePath, hasher: &hasher) else {
                    return false
                }
            }
            return true
        }
        guard kind == S_IFREG else { return false }
        updateDigest("file", relativePath, nil, metadata.st_size, metadata.st_mode, hasher: &hasher)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        while true {
            do {
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else {
                    return true
                }
                hasher.update(data: data)
            } catch {
                return false
            }
        }
    }

    private static func updateDigest(
        _ kind: String,
        _ relativePath: String,
        _ linkTarget: String?,
        _ size: off_t,
        _ mode: mode_t,
        hasher: inout SHA256
    ) {
        let header = [kind, relativePath, linkTarget ?? "", String(size), String(mode)]
            .joined(separator: "\u{1f}")
        let data = Data(header.utf8)
        hasher.update(data: Data("\(data.count):".utf8))
        hasher.update(data: data)
        hasher.update(data: Data([0]))
    }

    /// Count the logical payload bytes without following symlinks. Directory
    /// allocation is intentionally excluded because it varies across volumes;
    /// a symlink contributes the bytes in its link target, never the target's
    /// outside-tree contents.
    static func logicalByteCount(atPath path: String, rejectingSymlinks: Bool = false) -> UInt64? {
        var total: UInt64 = 0
        guard appendLogicalByteCount(forPath: path, total: &total, rejectingSymlinks: rejectingSymlinks) else { return nil }
        return total
    }

    private static func appendLogicalByteCount(
        forPath path: String, total: inout UInt64, rejectingSymlinks: Bool
    ) -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return false }
        let kind = metadata.st_mode & S_IFMT
        let amount: UInt64
        switch kind {
        case S_IFLNK:
            guard !rejectingSymlinks else { return false }
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                return false
            }
            amount = UInt64(target.utf8.count)
        case S_IFREG:
            guard metadata.st_size >= 0 else { return false }
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { return false }
            close(descriptor)
            amount = UInt64(metadata.st_size)
        case S_IFDIR:
            amount = 0
        default:
            return false
        }
        guard total <= UInt64.max - amount else { return false }
        total += amount
        guard kind == S_IFDIR,
              let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return kind != S_IFDIR
        }
        for child in children.sorted() {
            let childPath = (path as NSString).appendingPathComponent(child)
            guard appendLogicalByteCount(
                forPath: childPath, total: &total, rejectingSymlinks: rejectingSymlinks
            ) else { return false }
        }
        return true
    }
}

/// A small durable receipt directory. It deliberately does not delete old
/// receipts: retention and filesystem cleanup belong to the delivery owner.
nonisolated struct AppDeliveryReceiptStore: Sendable {
    enum LoadState: Equatable, Sendable { case absent, valid(AppDeliveryReceipt), corrupt }
    enum Entry: Equatable, Sendable {
        case valid(AppDeliveryReceipt)
        case corrupt(path: String)
        case unreadable(path: String)
    }
    enum StoreError: Error, Equatable {
        case invalidReceipt, alreadyExists, absent, corrupt, identityMismatch
        case invalidTransition, writeFailed
    }

    /// A measured, non-destructive admission policy for the previous-app
    /// snapshot. The default scope is Iris's own delivery-backup directory;
    /// callers may inject a strict root and a small logical-byte limit for
    /// disposable checks.
    struct BackupRetentionPolicy: Equatable, Sendable {
        static let defaultLogicalByteLimit: UInt64 = 2 * 1024 * 1024 * 1024

        let logicalByteLimit: UInt64
        let backupRoot: URL
        fileprivate let isStrictScope: Bool

        init(logicalByteLimit: UInt64 = Self.defaultLogicalByteLimit, backupRoot: URL? = nil) {
            self.logicalByteLimit = logicalByteLimit
            self.backupRoot = (backupRoot ?? IrisTestEnvironment.applicationSupportDirectory
                .appendingPathComponent("edit-delivery-backups", isDirectory: true)).standardizedFileURL
            self.isStrictScope = backupRoot != nil
        }
    }

    enum RetentionError: Error, Equatable, LocalizedError {
        case invalidPolicy
        case outsideBackupRoot
        case unsafePath
        case backupDestinationExists
        case protectedReference
        case corruptInventory
        case unreadableInventory
        case unreadableMeasurement
        case budgetExceeded(current: UInt64, candidate: UInt64, limit: UInt64)

        var errorDescription: String? {
            switch self {
            case .invalidPolicy: return "the backup retention policy is invalid"
            case .outsideBackupRoot: return "the backup destination is outside Iris's backup directory"
            case .unsafePath: return "a backup path contains an unsafe filesystem component"
            case .backupDestinationExists: return "the backup destination already exists"
            case .protectedReference: return "the backup destination is protected by saved recovery information"
            case .corruptInventory: return "saved backup inventory is incomplete or corrupt"
            case .unreadableInventory: return "saved backup inventory could not be read"
            case .unreadableMeasurement: return "a bundle's logical size could not be measured"
            case .budgetExceeded(let current, let candidate, let limit):
                return "the saved backup budget would be exceeded (existing \(current) bytes plus \(candidate) bytes exceeds the \(limit)-byte limit)"
            }
        }
    }

    struct BackupRetentionInventory: Equatable, Sendable {
        let logicalBytes: UInt64
        let protectedBackupPaths: [String]
        let previewEligibleBackupPaths: [String]
        let receiptCount: Int
    }

    struct BackupRetentionAdmission: Equatable, Sendable {
        let inventory: BackupRetentionInventory
        let candidateLogicalBytes: UInt64

        var totalLogicalBytes: UInt64 {
            inventory.logicalBytes + candidateLogicalBytes
        }
    }

    static let maximumRecordBytes = 32_768
    static let maximumEntries = 256
    static let defaultBaseDirectory = IrisTestEnvironment.applicationSupportDirectory
        .appendingPathComponent("edit-delivery-receipts", isDirectory: true)
    let baseDirectory: URL

    init(baseDirectory: URL = Self.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory.standardizedFileURL
    }

    /// Measure all existing backup bundles and validate every receipt and
    /// recovery reference before a new snapshot is written. No cleanup is
    /// performed here: unreferenced material remains protected and is counted.
    /// A nil result means the default policy is being used for a disposable
    /// caller whose destination is outside Iris's production backup scope.
    func admitBackup(
        sourcePath: String,
        destinationPath: String,
        policy: BackupRetentionPolicy,
        recoveryStore: DeliveredEditUndoRecoveryStore = DeliveredEditUndoRecoveryStore(),
        allowingPreparedReceiptIdentifier: UUID? = nil
    ) throws -> BackupRetentionAdmission? {
        guard policy.logicalByteLimit > 0,
              AppDeliveryReceipt.isCanonicalAbsolutePath(policy.backupRoot.path),
              AppDeliveryReceipt.isCanonicalAbsolutePath(destinationPath),
              AppDeliveryReceipt.isCanonicalAbsolutePath(sourcePath) else {
            throw RetentionError.invalidPolicy
        }
        guard isWithin(destinationPath, root: policy.backupRoot.path) else {
            if policy.isStrictScope { throw RetentionError.outsideBackupRoot }
            return nil
        }
        guard pathHasNoSymlinkComponents(policy.backupRoot.path, allowMissing: true),
              pathHasNoSymlinkComponents(destinationPath, allowMissing: true),
              pathHasNoSymlinkComponents(sourcePath, allowMissing: false) else {
            throw RetentionError.unsafePath
        }
        var destinationMetadata = stat()
        guard lstat(destinationPath, &destinationMetadata) != 0 else {
            throw RetentionError.backupDestinationExists
        }
        guard errno == ENOENT else { throw RetentionError.unreadableInventory }

        let inventory = try backupRetentionInventory(
            backupRoot: policy.backupRoot, recoveryStore: recoveryStore,
            allowingPreparedReceiptIdentifier: allowingPreparedReceiptIdentifier,
            allowingPreparedDestination: destinationPath
        )
        guard !inventory.protectedBackupPaths.contains(destinationPath) else {
            throw RetentionError.protectedReference
        }
        guard let candidateLogicalBytes = AppDeliveryReceipt.logicalByteCount(atPath: sourcePath) else {
            throw RetentionError.unreadableMeasurement
        }
        guard inventory.logicalBytes <= UInt64.max - candidateLogicalBytes else {
            throw RetentionError.budgetExceeded(
                current: inventory.logicalBytes, candidate: candidateLogicalBytes,
                limit: policy.logicalByteLimit
            )
        }
        let total = inventory.logicalBytes + candidateLogicalBytes
        guard total <= policy.logicalByteLimit else {
            throw RetentionError.budgetExceeded(
                current: inventory.logicalBytes, candidate: candidateLogicalBytes,
                limit: policy.logicalByteLimit
            )
        }
        return BackupRetentionAdmission(
            inventory: inventory, candidateLogicalBytes: candidateLogicalBytes
        )
    }

    /// Cheap UI gate. It proves only that the recorded backup is a safe,
    /// readable bundle at the recorded path. Undo still performs the existing
    /// full content-digest and source-identity checks off the main actor.
    func backupIsAvailable(for receipt: AppDeliveryReceipt) -> Bool {
        let metadataPath = URL(fileURLWithPath: receipt.backupPath)
            .appendingPathComponent("Contents/Info.plist").path
        guard receipt.isValid,
              AppDeliveryReceipt.isCanonicalAbsolutePath(receipt.backupPath),
              pathHasNoSymlinkComponents(metadataPath, allowMissing: false) else {
            return false
        }
        var propertyListMetadata = stat()
        guard lstat(metadataPath, &propertyListMetadata) == 0,
              (propertyListMetadata.st_mode & S_IFMT) == S_IFREG,
              propertyListMetadata.st_size > 0,
              propertyListMetadata.st_size <= 1_048_576 else { return false }
        var metadata = stat()
        guard lstat(receipt.backupPath, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              let identity = AppDeliveryReceipt.bundleMetadataIdentity(atPath: receipt.backupPath) else {
            return false
        }
        return identity.bundleIdentifier == receipt.bundleIdentifier
    }

    private func backupRetentionInventory(
        backupRoot: URL,
        recoveryStore: DeliveredEditUndoRecoveryStore,
        allowingPreparedReceiptIdentifier: UUID? = nil,
        allowingPreparedDestination: String? = nil
    ) throws -> BackupRetentionInventory {
        let receipts = try retentionReceipts()
        var protected = Set<String>()
        var previewEligible = Set<String>()
        let logicalBytes: UInt64
        var rootMetadata = stat()
        let rootExists = lstat(backupRoot.path, &rootMetadata) == 0
        if !rootExists && errno != ENOENT { throw RetentionError.unreadableInventory }
        if rootExists {
            guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR,
                  pathHasNoSymlinkComponents(backupRoot.path, allowMissing: false) else {
                throw RetentionError.unsafePath
            }
            // The backup namespace itself is a strict directory tree. Stop at
            // each recorded .app root so legitimate framework-internal links
            // remain payload entries rather than namespace escapes.
            try validateBackupNamespace(backupRoot)
            guard let bytes = AppDeliveryReceipt.logicalByteCount(
                atPath: backupRoot.path, rejectingSymlinks: false
            ) else { throw RetentionError.unreadableMeasurement }
            logicalBytes = bytes
        } else {
            logicalBytes = 0
        }

        for receipt in receipts {
            guard isWithin(receipt.backupPath, root: backupRoot.path),
                  pathHasNoSymlinkComponents(receipt.backupPath, allowMissing: true) else {
                throw RetentionError.unsafePath
            }
            var metadata = stat()
            if lstat(receipt.backupPath, &metadata) == 0 {
                guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw RetentionError.corruptInventory }
                let isAllowedPreparedReceipt = receipt.identifier == allowingPreparedReceiptIdentifier
                    && receipt.phase == .prepared
                    && receipt.backupPath == allowingPreparedDestination
                if isAllowedPreparedReceipt {
                    continue
                }
                if isPreviewEligible(receipt) {
                    previewEligible.insert(receipt.backupPath)
                } else {
                    protected.insert(receipt.backupPath)
                }
            } else if errno != ENOENT || receipt.phase != .prepared {
                throw RetentionError.corruptInventory
            } else if receipt.identifier != allowingPreparedReceiptIdentifier
                        || receipt.backupPath != allowingPreparedDestination {
                // A prepared receipt reserves its destination even before the
                // bundle snapshot exists. Only the receipt being completed by
                // this admission may be exempted.
                protected.insert(receipt.backupPath)
            }
        }

        switch recoveryStore.load() {
        case .absent:
            break
        case .unreadable:
            throw RetentionError.unreadableInventory
        case .pending(let record):
            try addRecoveryReference(record.backupPath, root: backupRoot, protected: &protected)
        }
        let archived = recoveryStore.archivedRecoveryInventory()
        guard !archived.hasUnknownTargets else { throw RetentionError.corruptInventory }
        for record in archived.records {
            try addRecoveryReference(record.backupPath, root: backupRoot, protected: &protected)
        }
        // A restored receipt is only a preview candidate while no live or
        // archived recovery record, nor another non-restored receipt, aliases
        // the same backup path.
        previewEligible.subtract(protected)

        return BackupRetentionInventory(
            logicalBytes: logicalBytes,
            protectedBackupPaths: protected.sorted(),
            previewEligibleBackupPaths: previewEligible.sorted(),
            receiptCount: receipts.count
        )
    }

    private func validateBackupNamespace(_ root: URL) throws {
        for bundleGroup in try safeDirectoryEntries(at: root) {
            for delivery in try safeDirectoryEntries(at: bundleGroup) {
                _ = try safeDirectoryEntries(at: delivery)
            }
        }
    }

    private func safeDirectoryEntries(at parent: URL) throws -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { throw RetentionError.unreadableInventory }
        return try entries.map { entry in
            var metadata = stat()
            guard lstat(entry.path, &metadata) == 0 else {
                throw RetentionError.unreadableInventory
            }
            let kind = metadata.st_mode & S_IFMT
            guard kind == S_IFDIR else {
                if kind == S_IFLNK { throw RetentionError.unsafePath }
                throw RetentionError.corruptInventory
            }
            return entry
        }
    }

    private func isPreviewEligible(_ receipt: AppDeliveryReceipt) -> Bool {
        guard receipt.phase == .restored,
              let source = receipt.sourceIdentity, source.isValid,
              let installed = receipt.installedBundleIdentity, installed.isValid,
              let replacement = receipt.replacementBundleIdentity, replacement.isValid,
              let backup = receipt.backupBundleIdentity, backup.isValid,
              installed.contentDigest != nil, replacement.contentDigest != nil,
              backup.contentDigest != nil else { return false }
        return installed == backup
            && installed.bundleIdentifier == receipt.bundleIdentifier
            && replacement.bundleIdentifier == receipt.bundleIdentifier
    }

    private func retentionReceipts() throws -> [AppDeliveryReceipt] {
        var directoryMetadata = stat()
        guard lstat(baseDirectory.path, &directoryMetadata) == 0 else {
            if errno == ENOENT { return [] }
            throw RetentionError.unreadableInventory
        }
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR,
              pathHasNoSymlinkComponents(baseDirectory.path, allowMissing: false) else {
            throw RetentionError.unsafePath
        }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: nil
        ) else { throw RetentionError.unreadableInventory }
        var receipts: [AppDeliveryReceipt] = []
        for file in files {
            let name = file.lastPathComponent
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0 else { throw RetentionError.unreadableInventory }
            if name == ".lock" {
                guard (metadata.st_mode & S_IFMT) == S_IFREG else { throw RetentionError.corruptInventory }
                continue
            }
            guard name.hasSuffix(".json"),
                  let identifier = UUID(uuidString: String(name.dropLast(5))),
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  let data = try? boundedData(at: file),
                  let receipt = try? JSONDecoder().decode(AppDeliveryReceipt.self, from: data),
                  receipt.identifier == identifier, receipt.isValid else {
                throw RetentionError.corruptInventory
            }
            receipts.append(receipt)
            guard receipts.count <= Self.maximumEntries else { throw RetentionError.corruptInventory }
        }
        return receipts
    }

    private func addRecoveryReference(
        _ path: String?, root: URL, protected: inout Set<String>
    ) throws {
        guard let path else { return }
        guard AppDeliveryReceipt.isCanonicalAbsolutePath(path), isWithin(path, root: root.path) else {
            throw RetentionError.unsafePath
        }
        guard pathHasNoSymlinkComponents(path, allowMissing: true) else {
            throw RetentionError.unsafePath
        }
        var metadata = stat()
        if lstat(path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else { throw RetentionError.unsafePath }
        } else if errno != ENOENT {
            throw RetentionError.unreadableInventory
        }
        protected.insert(path)
    }

    private func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func pathHasNoSymlinkComponents(_ path: String, allowMissing: Bool) -> Bool {
        var current = "/"
        for component in path.split(separator: "/") {
            current = (current as NSString).appendingPathComponent(String(component))
            var metadata = stat()
            guard lstat(current, &metadata) == 0 else {
                return allowMissing && errno == ENOENT
            }
            guard (metadata.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    func url(for identifier: UUID) -> URL {
        baseDirectory.appendingPathComponent(identifier.uuidString + ".json")
    }

    func savePrepared(_ receipt: AppDeliveryReceipt) throws {
        guard receipt.isValid, receipt.phase == .prepared else { throw StoreError.invalidReceipt }
        let data = try encoded(receipt)
        try withExclusiveStoreLock {
            try publish(data, at: url(for: receipt.identifier), refusingExisting: true)
        }
    }

    func load(_ identifier: UUID) -> LoadState {
        let destination = url(for: identifier)
        var metadata = stat()
        guard lstat(destination.path, &metadata) == 0 else {
            return errno == ENOENT ? .absent : .corrupt
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG else { return .corrupt }
        guard let data = try? boundedData(at: destination),
              let receipt = try? JSONDecoder().decode(AppDeliveryReceipt.self, from: data),
              receipt.identifier == identifier, receipt.isValid else { return .corrupt }
        return .valid(receipt)
    }

    /// Lists bounded metadata for a settings/recovery surface, retaining a
    /// visible corrupt entry rather than silently treating it as absent.
    func entries(limit: Int = maximumEntries) -> [Entry] {
        guard limit > 0 else { return [] }
        var directoryMetadata = stat()
        guard lstat(baseDirectory.path, &directoryMetadata) == 0 else {
            return errno == ENOENT ? [] : [.unreadable(path: baseDirectory.path)]
        }
        guard (directoryMetadata.st_mode & S_IFMT) == S_IFDIR else {
            return [.unreadable(path: baseDirectory.path)]
        }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: baseDirectory, includingPropertiesForKeys: nil
            )
        } catch {
            return [.unreadable(path: baseDirectory.path)]
        }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .prefix(min(limit, Self.maximumEntries)).map { file in
                guard let identifier = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                    return .corrupt(path: file.path)
                }
                switch load(identifier) {
                case .valid(let receipt): return .valid(receipt)
                case .absent, .corrupt: return .corrupt(path: file.path)
                }
            }
    }

    func transition(_ current: AppDeliveryReceipt, to phase: AppDeliveryReceipt.Phase) throws -> AppDeliveryReceipt {
        guard current.isValid else { throw StoreError.invalidReceipt }
        return try withExclusiveStoreLock {
            let existing: AppDeliveryReceipt
            switch load(current.identifier) {
            case .valid(let receipt): existing = receipt
            case .absent: throw StoreError.absent
            case .corrupt: throw StoreError.corrupt
            }
            guard existing.identity == current.identity else { throw StoreError.identityMismatch }
            guard existing.phase == current.phase else { throw StoreError.identityMismatch }
            guard existing.phase == phase || (existing.phase == .prepared && phase == .installed)
                    || (existing.phase == .installed && phase == .restored) else {
                throw StoreError.invalidTransition
            }
            if existing.phase == phase { return existing }
        let next = AppDeliveryReceipt(identifier: existing.identifier,
            bundleIdentifier: existing.bundleIdentifier, installedPath: existing.installedPath,
            sourceArtifactPath: existing.sourceArtifactPath, backupPath: existing.backupPath,
            startedAt: existing.startedAt, phase: phase,
            sourceIdentity: existing.sourceIdentity,
            installedBundleIdentity: existing.installedBundleIdentity,
            replacementBundleIdentity: existing.replacementBundleIdentity,
            backupBundleIdentity: existing.backupBundleIdentity)
            try publish(try encoded(next), at: url(for: next.identifier), refusingExisting: false)
            return next
        }
    }

    private func encoded(_ receipt: AppDeliveryReceipt) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        guard data.count <= Self.maximumRecordBytes else { throw StoreError.invalidReceipt }
        return data
    }

    private func boundedData(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.corrupt }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size <= off_t(Self.maximumRecordBytes) else { throw StoreError.corrupt }
        let data = try handle.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
        guard data.count == information.st_size else { throw StoreError.corrupt }
        return data
    }

    private func withExclusiveStoreLock<T>(_ operation: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed
        }
        let lockURL = baseDirectory.appendingPathComponent(".lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StoreError.writeFailed }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.writeFailed }
        return try operation()
    }

    private func publish(_ data: Data, at destination: URL, refusingExisting: Bool) throws {
        do { try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true) }
        catch { throw StoreError.writeFailed }
        let temporary = baseDirectory.appendingPathComponent(".staging-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw StoreError.writeFailed }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlink(temporary.path) }
        do { try handle.write(contentsOf: data); try handle.synchronize() }
        catch { throw StoreError.writeFailed }
        if refusingExisting {
            guard link(temporary.path, destination.path) == 0 else {
                if errno == EEXIST { throw StoreError.alreadyExists }
                throw StoreError.writeFailed
            }
            _ = unlink(temporary.path)
        } else if rename(temporary.path, destination.path) != 0 {
            throw StoreError.writeFailed
        }
        let directory = open(baseDirectory.path, O_RDONLY | O_NOFOLLOW)
        guard directory >= 0 else { throw StoreError.writeFailed }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw StoreError.writeFailed }
    }
}
