import Foundation
import Darwin

public struct NativeShellAppIdentity: Hashable, Sendable, Identifiable {
    public let appId: String
    public let projectId: String

    public var id: String { "\(appId)::\(projectId)" }

    public init(appId: String, projectId: String) {
        self.appId = appId
        self.projectId = projectId
    }
}

/// Every installed app's storage facts plus the cross-app total, for the
/// Library/Storage screen. See `NativeShellLibraryCoordinator.globalStorageUsage`.
public struct NativeStorageGlobalUsage: Equatable, Sendable {
    public let perApp: [NativeStorageAppUsage]
    public let totalCodeBytes: Int64
    public let capBytes: Int64
    public var isOverCap: Bool { totalCodeBytes > capBytes }

    public init(perApp: [NativeStorageAppUsage], totalCodeBytes: Int64, capBytes: Int64) {
        self.perApp = perApp
        self.totalCodeBytes = totalCodeBytes
        self.capBytes = capBytes
    }
}

/// One revision a global cap plan would remove, and from which app.
public struct NativeStorageGlobalReclaimItem: Equatable, Sendable {
    public let identity: NativeShellAppIdentity
    public let revisionId: String
    public let allocatedBytes: Int

    public init(identity: NativeShellAppIdentity, revisionId: String, allocatedBytes: Int) {
        self.identity = identity
        self.revisionId = revisionId
        self.allocatedBytes = allocatedBytes
    }
}

/// See `NativeShellLibraryCoordinator.planGlobalCapEnforcement`.
public struct NativeStorageGlobalReclaimPlan: Equatable, Sendable {
    public let items: [NativeStorageGlobalReclaimItem]
    public let reclaimableBytes: Int64
    public let stillOverCapBytesAfterPlan: Int64
    public var isEmpty: Bool { items.isEmpty }

    public init(items: [NativeStorageGlobalReclaimItem], reclaimableBytes: Int64, stillOverCapBytesAfterPlan: Int64) {
        self.items = items
        self.reclaimableBytes = reclaimableBytes
        self.stillOverCapBytesAfterPlan = stillOverCapBytesAfterPlan
    }
}

public struct NativeStorageKeepCountPlan: Equatable, Sendable {
    public let choice: VersionsKeptPerApp
    public let bytesReclaimed: Int64
    public let items: [NativeStorageGlobalReclaimItem]
}

public struct NativeStorageKeepCountResult: Equatable, Sendable {
    public let choice: VersionsKeptPerApp
    public let bytesReclaimed: Int64
    public let retainedRevisionIds: [NativeShellAppIdentity: Set<String>]
    public let freedRevisionIds: [NativeShellAppIdentity: Set<String>]
    public let nothingCouldBeFreed: Bool
}

public struct NativeShellPackageReview: Equatable, Sendable {
    public let reviewToken: String
    public let identity: NativeShellAppIdentity
    public let packageSHA256: String
    public let displayName: String
    public let baseRevisionId: String?
    public let revisionId: String
    public let contentHash: String
    public let deliveryNonce: String
    public let embeddedApprovalId: String
    public let requestedCapabilities: [String]
    public let unsupportedCapabilities: [String]
    public let dataNamespace: String

    public var localApprovalExplanation: String {
        "Approve locally trusts only these exact package bytes on this device. It does not authenticate the desktop sender or create remote delivery identity."
    }
}

public struct NativeShellLibraryEntry: Equatable, Sendable, Identifiable {
    public let identity: NativeShellAppIdentity
    public let displayName: String
    public let currentRevisionId: String?
    public let fallbackRevisionId: String?
    public let revisions: [NativeRevisionSummary]

    public var id: String { identity.id }
    public var stagedRevisions: [NativeRevisionSummary] {
        revisions.filter { $0.revisionId != currentRevisionId }
    }

    public var totalVersionContentBytes: Int? {
        var total = 0
        for revision in revisions {
            guard let size = revision.contentBytes, size >= 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
}

public struct NativeShellStageOutcome: Equatable, Sendable {
    public let identity: NativeShellAppIdentity
    public let revisionId: String
    public let alreadyStaged: Bool
}

public struct NativeShellLaunchOutcome: Equatable, Sendable, Identifiable {
    public let identity: NativeShellAppIdentity
    public let requestedRevisionId: String
    public let launchedRevisionId: String
    public let didFallback: Bool
    public let launch: VerifiedLaunchDescriptor

    public var id: String { "\(identity.id)::\(launchedRevisionId)" }
}

/// In-memory ownership of one completed selection, not new installation consent.
/// Only this coordinator can issue it. Any later selection attempt invalidates it,
/// even when the reader eventually returns to the same content revision.
public struct NativeShellActivationSelection: Equatable, Sendable {
    public let identity: NativeShellAppIdentity
    public let revisionId: String
    fileprivate let coordinatorID: UUID
    fileprivate let selectionID: UUID
}

public enum NativeShellLibraryError: Error, Equatable, CustomStringConvertible {
    case noPendingReview
    case reviewTokenMismatch
    case reviewDigestMismatch
    case reviewAlreadyStaging
    case reviewSuperseded
    case activeSelectionSuperseded
    case reviewIdentityMismatch(expected: NativeShellAppIdentity, actual: NativeShellAppIdentity)
    case reviewedPackageChanged
    case invalidLibraryNamespace(String)

    public var description: String {
        switch self {
        case .noPendingReview:
            return "there is no package waiting for review"
        case .reviewTokenMismatch:
            return "the visible package review is no longer the pending review"
        case .reviewDigestMismatch:
            return "the package digest does not match the visible review"
        case .reviewAlreadyStaging:
            return "this review is already being staged"
        case .reviewSuperseded:
            return "a newer package review already replaced this request"
        case .activeSelectionSuperseded:
            return "the active version selection changed; the earlier installation retry is no longer authorized"
        case .reviewIdentityMismatch(let expected, let actual):
            return "package identity mismatch: expected \(expected.id), got \(actual.id)"
        case .reviewedPackageChanged:
            return "the package bytes changed after review"
        case .invalidLibraryNamespace(let path):
            return "native shell library namespace is invalid: \(path)"
        }
    }
}

/// Small pure token used by presentation code to reject late async results.
/// Advancing the generation for every new visible user intent means an older
/// task may finish, but it cannot overwrite newer review/error/retry state.
public struct NativeShellPresentationGeneration: Equatable, Sendable {
    public private(set) var value: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    public func isCurrent(_ token: UInt64) -> Bool {
        token == value
    }
}

/// Product-level lifecycle over `NativeRevisionStore`. Raw bytes can be inspected
/// without effects, but no staging path exists until the caller supplies a real
/// external authority or the reader explicitly mints a one-use local authority.
public actor NativeShellLibraryCoordinator {
    private struct PendingReview: Sendable {
        let reviewToken: String
        let packageBytes: Data
        let inspection: DeliveryPackageInspection
    }

    private let rootURL: URL
    /// The namespace root every store under this coordinator lives in (the
    /// My apps arrangement file sits beside the library, MA2 hook 1a).
    public var namespaceRootURL: URL { rootURL }
    private let shellVersion: String
    private let capabilityPolicy: CapabilityPolicy
    private let fileManager: FileManager
    private let automaticCodeCap: (@Sendable () -> Int64)?
    private let defaults: UserDefaults
    private let downloadableRevisionIds: @Sendable (NativeShellAppIdentity) async throws -> Set<String>
    private let versionFault: NativeVersionFaultInjector?
    // Preference references remain on this actor across root-lock waits.
    // Only a Sendable operation id crosses the maintenance closure boundary.
    private var storageOperationPreferences: [UUID: UserDefaults] = [:]
    private var automaticCodeBytes: [NativeShellAppIdentity: Int64]?
    private var pendingReview: PendingReview?
    private var stagingReviewTokens = Set<String>()
    private var stores: [NativeShellAppIdentity: NativeRevisionStore] = [:]
    private var latestClientReviewSequence: UInt64 = 0
    private let coordinatorID = UUID()
    private var selectionIDs: [NativeShellAppIdentity: UUID] = [:]

    public init(
        rootURL: URL,
        shellVersion: String = "1.0.0",
        capabilityPolicy: CapabilityPolicy = .denyAll,
        fileManager: FileManager = .default,
        automaticCodeCap: (@Sendable () -> Int64)? = nil,
        defaults: UserDefaults = .standard,
        downloadableRevisionIds: @escaping @Sendable (NativeShellAppIdentity) async throws -> Set<String> = { _ in [] },
        versionFault: NativeVersionFaultInjector? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.shellVersion = shellVersion
        self.capabilityPolicy = capabilityPolicy
        self.fileManager = fileManager
        self.automaticCodeCap = automaticCodeCap
        self.defaults = defaults
        self.downloadableRevisionIds = downloadableRevisionIds
        self.versionFault = versionFault
    }

    /// Strictly validates package shape, canonical identity and every byte. It
    /// does not trust the package approval, create directories, or stage content.
    @discardableResult
    public func reviewImport(
        packageBytes: Data,
        expectedIdentity: NativeShellAppIdentity? = nil,
        clientReviewSequence: UInt64? = nil
    ) throws -> NativeShellPackageReview {
        if let clientReviewSequence {
            guard clientReviewSequence >= latestClientReviewSequence else {
                throw NativeShellLibraryError.reviewSuperseded
            }
            latestClientReviewSequence = clientReviewSequence
        }
        // A newly chosen file supersedes the previous visible review even when
        // the new bytes are malformed. A failed import must never leave an old
        // approval surface silently licensed behind it.
        pendingReview = nil
        let inspection = try DeliveryPackageV1Validator().inspect(packageBytes: packageBytes)
        let identity = NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId)
        if let expectedIdentity, expectedIdentity != identity {
            throw NativeShellLibraryError.reviewIdentityMismatch(expected: expectedIdentity, actual: identity)
        }
        let reviewToken = UUID().uuidString
        pendingReview = PendingReview(
            reviewToken: reviewToken,
            packageBytes: packageBytes,
            inspection: inspection
        )
        return review(from: inspection, reviewToken: reviewToken)
    }

    /// Atomically starts a review only when no other package is currently
    /// waiting for reader approval. This lets an independent website install
    /// flow preserve an already-visible local-import review without a check/use
    /// race. It deliberately does not change client review sequence semantics.
    public func reviewImportIfIdle(
        packageBytes: Data,
        expectedIdentity: NativeShellAppIdentity? = nil
    ) throws -> NativeShellPackageReview? {
        guard pendingReview == nil else { return nil }
        return try reviewImport(packageBytes: packageBytes, expectedIdentity: expectedIdentity)
    }

    /// Reserves a newer host intent before an asynchronous file read/download.
    /// Older work cannot recreate a pending review after cancellation. Equal or
    /// older invalidations are no-ops, including a late invalidation task that
    /// reaches this actor after its matching review was already installed.
    public func supersedePendingReview(clientReviewSequence: UInt64) {
        guard clientReviewSequence > latestClientReviewSequence else { return }
        latestClientReviewSequence = clientReviewSequence
        pendingReview = nil
    }

    public func cancelReview(reviewToken: String? = nil) {
        if let reviewToken {
            guard pendingReview?.reviewToken == reviewToken else { return }
        }
        pendingReview = nil
    }

    public func pendingPackageReview() -> NativeShellPackageReview? {
        pendingReview.map { review(from: $0.inspection, reviewToken: $0.reviewToken) }
    }

    /// Local approval is a reader decision for one exact package digest. It is
    /// explicitly not authenticated desktop approval and the authority is
    /// consumed by the validator lookup during this stage attempt.
    public func approvePendingReviewLocallyAndStage(
        reviewToken: String,
        packageSHA256: String
    ) async throws -> NativeShellStageOutcome {
        let reserved = try reservePendingReview(
            reviewToken: reviewToken,
            packageSHA256: packageSHA256
        )
        let authority = LocalUserReviewApprovalAuthority(inspection: reserved.inspection)
        return try await stageReservedReview(reserved, authority: authority)
    }

    /// External callers may preserve a separately authenticated approval source.
    /// The same exact package is revalidated by the core before staging.
    public func stagePendingReview(
        reviewToken: String,
        packageSHA256: String,
        using approvalAuthority: any DeliveryApprovalAuthority
    ) async throws -> NativeShellStageOutcome {
        let reserved = try reservePendingReview(
            reviewToken: reviewToken,
            packageSHA256: packageSHA256
        )
        return try await stageReservedReview(reserved, authority: approvalAuthority)
    }

    public func refreshLibrary() async throws -> [NativeShellLibraryEntry] {
        let identities = try discoverStoredIdentities()
        var entries: [NativeShellLibraryEntry] = []
        for identity in identities {
            let store = try makeStore(identity: identity)
            let revisions = try await store.revisionSummaries()
            guard !revisions.isEmpty else { continue }
            let currentRevisionId = try await store.activeRevisionId()
            let fallbackRevisionId = try await store.fallbackRevisionId()
            let current = revisions.first { $0.revisionId == currentRevisionId }
            entries.append(
                NativeShellLibraryEntry(
                    identity: identity,
                    displayName: current?.displayName ?? revisions[0].displayName,
                    currentRevisionId: currentRevisionId,
                    fallbackRevisionId: fallbackRevisionId,
                    revisions: revisions
                )
            )
        }
        return entries.sorted { left, right in
            if left.displayName != right.displayName { return left.displayName < right.displayName }
            return left.identity.id < right.identity.id
        }
    }

    /// Reads and verifies only one exact app/project library entry. Missing owned
    /// paths are treated as "not installed" without creating directories. Invalid
    /// identities are rejected before they can participate in path construction.
    public func libraryEntry(identity: NativeShellAppIdentity) async throws -> NativeShellLibraryEntry? {
        guard NativeSecurity.isStableId(identity.appId) else {
            throw NativeShellError.invalidStableIdentifier(identity.appId)
        }
        guard NativeSecurity.isStableId(identity.projectId) else {
            throw NativeShellError.invalidStableIdentifier(identity.projectId)
        }

        let contentRoot = rootURL.appendingPathComponent("content", isDirectory: true)
        guard fileManager.fileExists(atPath: contentRoot.path) else { return nil }
        try requirePlainDirectory(contentRoot)

        let appURL = contentRoot.appendingPathComponent(identity.appId, isDirectory: true)
        guard fileManager.fileExists(atPath: appURL.path) else { return nil }
        try requirePlainDirectory(appURL)

        let projectURL = appURL.appendingPathComponent(identity.projectId, isDirectory: true)
        guard fileManager.fileExists(atPath: projectURL.path) else { return nil }
        try requirePlainDirectory(projectURL)

        let store = try makeStore(identity: identity)
        let revisions = try await store.revisionSummaries()
        guard !revisions.isEmpty else { return nil }
        let currentRevisionId = try await store.activeRevisionId()
        let fallbackRevisionId = try await store.fallbackRevisionId()
        let current = revisions.first { $0.revisionId == currentRevisionId }
        return NativeShellLibraryEntry(
            identity: identity,
            displayName: current?.displayName ?? revisions[0].displayName,
            currentRevisionId: currentRevisionId,
            fallbackRevisionId: fallbackRevisionId,
            revisions: revisions
        )
    }

    public func activate(identity: NativeShellAppIdentity, revisionId: String) async throws {
        _ = try await activateAndCaptureSelection(identity: identity, revisionId: revisionId)
    }

    public func activateAndCaptureSelection(
        identity: NativeShellAppIdentity, revisionId: String
    ) async throws -> NativeShellActivationSelection {
        let store = try makeStore(identity: identity)
        let selectionID = UUID()
        selectionIDs[identity] = selectionID
        try await store.activate(revisionId: revisionId)
        // The adapter has applied the count at the completed selection boundary.
        // Additional cap maintenance is best effort: a reclaim failure cannot
        // turn an already-successful activation into an error.
        _ = try? await enforceAutomaticCodeCap(changed: identity)
        guard selectionIDs[identity] == selectionID else {
            throw NativeShellLibraryError.activeSelectionSuperseded
        }
        return NativeShellActivationSelection(identity: identity, revisionId: revisionId,
                                              coordinatorID: coordinatorID, selectionID: selectionID)
    }

    public func revert(identity: NativeShellAppIdentity, to revisionId: String) async throws {
        let store = try makeStore(identity: identity)
        selectionIDs[identity] = UUID()
        try await store.rollback(to: revisionId)
        _ = try? await enforceAutomaticCodeCap(changed: identity)
    }

    public func launchActive(
        identity: NativeShellAppIdentity,
        requiringSelection selection: NativeShellActivationSelection? = nil
    ) async throws -> NativeShellLaunchOutcome {
        try requireCurrentSelection(selection, identity: identity)
        let store = try makeStore(identity: identity)
        guard let requestedRevisionId = try await store.activeRevisionId() else {
            throw NativeShellError.noActiveRevision
        }
        try requireCurrentSelection(selection, identity: identity)
        if let selection, selection.revisionId != requestedRevisionId {
            throw NativeShellLibraryError.activeSelectionSuperseded
        }
        let launch = try await store.launchDescriptorForActiveRevision()
        if launch.revisionId != requestedRevisionId { selectionIDs[identity] = UUID() }
        try requireCurrentSelection(selection, identity: identity)
        if let selection, selection.revisionId != launch.revisionId {
            throw NativeShellLibraryError.activeSelectionSuperseded
        }
        // The adapter handles count maintenance after verified launch; the
        // coordinator composes the cross-app cap at the same boundary.
        _ = try? await enforceAutomaticCodeCap(changed: identity)
        return NativeShellLaunchOutcome(
            identity: identity,
            requestedRevisionId: requestedRevisionId,
            launchedRevisionId: launch.revisionId,
            didFallback: requestedRevisionId != launch.revisionId,
            launch: launch
        )
    }

    private func requireCurrentSelection(_ selection: NativeShellActivationSelection?, identity: NativeShellAppIdentity) throws {
        guard let selection else { return }
        guard selection.coordinatorID == coordinatorID, selection.identity == identity,
              selectionIDs[identity] == selection.selectionID else {
            throw NativeShellLibraryError.activeSelectionSuperseded
        }
    }

    public func readerDataDirectory(identity: NativeShellAppIdentity, namespace: String) async throws -> URL {
        try await makeStore(identity: identity).readerDataDirectory(namespace: namespace)
    }

    // MARK: - Remove app, with an honest "Also delete my data" (RC-04)

    /// Removes one installed app. See `NativeAppRemovalReport` and the header
    /// of `NativeAppRemoval.swift` for what each choice deletes and why data
    /// goes before code. The app must be closed first: WebKit will not delete
    /// a web data store a web view is still using, and that refusal is thrown
    /// before anything else is removed, so a retry is always safe. Removing
    /// an app that is already gone succeeds and reports zero.
    ///
    /// The caller still owns two things that live outside this library: the
    /// My apps arrangement (apply `MyAppsAction.forgetApp` when
    /// `alsoDeleteData` is true; keep the name and folder otherwise) and any
    /// usage history. `webStorage` nil means the system remover (real
    /// `WKWebsiteDataStore`). Pass the permission store and the Versions store when
    /// the running app has them, so "delete my data" reaches them too.
    @discardableResult
    public func removeApp(
        identity: NativeShellAppIdentity,
        alsoDeleteData: Bool,
        webStorage: NativeWebStorageRemoving? = nil,
        permissionStore: NativePermissionStore? = nil,
        versionsStore: NativeVersionStore? = nil
    ) async throws -> NativeAppRemovalReport {
        automaticCodeBytes = nil
        guard NativeSecurity.isStableId(identity.appId) else {
            throw NativeShellError.invalidStableIdentifier(identity.appId)
        }
        guard NativeSecurity.isStableId(identity.projectId) else {
            throw NativeShellError.invalidStableIdentifier(identity.projectId)
        }
        func folder(_ top: String) -> URL {
            rootURL.appendingPathComponent(top, isDirectory: true)
                .appendingPathComponent(identity.appId, isDirectory: true)
                .appendingPathComponent(identity.projectId, isDirectory: true)
        }
        let contentURL = folder("content")
        let stateURL = folder("state")
        let readerDataURL = folder("reader-data")
        let hasObjectCode = fileManager.fileExists(atPath: folder("manifests").path)
            || fileManager.fileExists(atPath: folder("checkouts").path)
        let objectStore: NativeVersionStore?
        if hasObjectCode {
            objectStore = try await makeStore(identity: identity).versionStorageForRemoval()
        } else {
            objectStore = nil
        }
        // Preserve the supplied auxiliary-store API, while the shipping
        // adapter's own code store is now removed for either data choice.
        let auxiliaryStore: NativeVersionStore?
        if let versionsStore,
           versionsStore.root.resolvingSymlinksInPath().standardizedFileURL != objectStore?.root {
            auxiliaryStore = versionsStore
        } else {
            auxiliaryStore = nil
        }
        let legacyCodeBytes = NativeAppRemoval.allocatedBytes(at: contentURL, fileManager: fileManager)
            + NativeAppRemoval.allocatedBytes(at: stateURL, fileManager: fileManager)

        var dataBytes: Int64 = 0
        var storesRemoved = 0
        var decisionsForgotten = 0

        if alsoDeleteData {
            // 1. The named WebKit store(s). First on purpose: if WebKit refuses
            // (the app is still open) nothing else has been touched.
            var identifiersFound = Set(NativeAppRemoval.webStorageIdentifiers(
                rootURL: rootURL, identity: identity, fileManager: fileManager
            ))
            for store in [objectStore, auxiliaryStore].compactMap({ $0 }) {
                identifiersFound.formUnion(versionWebStorageIdentifiers(store: store, identity: identity))
            }
            let identifiers = identifiersFound.sorted { $0.uuidString < $1.uuidString }
            if !identifiers.isEmpty {
                // No remover passed means the system one (real WKWebsiteDataStore).
                guard let remover = webStorage ?? NativeAppRemoval.systemWebStorageRemover else {
                    throw NativeAppRemovalError.webStorageUnavailable
                }
                try await remover.removeStores(identifiers: identifiers)
                storesRemoved = identifiers.count
            }
            // 2. Reader data (files apps saved through the shell).
            dataBytes += NativeAppRemoval.allocatedBytes(at: readerDataURL, fileManager: fileManager)
            try NativeAppRemoval.removeIfPresent(readerDataURL, fileManager: fileManager)
            NativeAppRemoval.removeIfEmpty(readerDataURL.deletingLastPathComponent(), fileManager: fileManager)
            // 3. What the person allowed.
            if let permissionStore {
                decisionsForgotten = try permissionStore.forgetAllDecisions(for: identity)
            }
            // 4. Versions: objects, checkouts, manifests, ledger.
            if let auxiliaryStore {
                dataBytes += try await auxiliaryStore.withExclusiveAccess {
                    // The Versions module owns its byte-store operations.
                    // Keep this manager local to that task, rather than sending
                    // the coordinator's actor-isolated manager across executors.
                    let manager = FileManager()
                    return try await NativeAppRemoval.removeVersionsData(
                        store: auxiliaryStore, identity: identity, fileManager: manager
                    )
                }
            }
        }

        // 5. The code, last. Its unique objects and copied checkouts are code,
        // including when reader data and WebKit stores must stay for reinstall.
        var objectCodeBytes: Int64 = 0
        if let objectStore {
            objectCodeBytes = try await objectStore.withExclusiveAccess {
                _ = try await objectStore.recoverIfNeeded(appId: identity.appId, projectId: identity.projectId)
                let before = try objectStore.globalAllocatedBytes()
                let manager = FileManager()
                _ = try await NativeAppRemoval.removeVersionsData(
                    store: objectStore, identity: identity, fileManager: manager
                )
                return Int64(max(0, before - (try objectStore.globalAllocatedBytes())))
            }
        }
        // The cached store and any live selection go only after successful removal.
        stores[identity] = nil
        selectionIDs[identity] = nil
        let codeBytes = legacyCodeBytes + objectCodeBytes
        try NativeAppRemoval.removeIfPresent(contentURL, fileManager: fileManager)
        try NativeAppRemoval.removeIfPresent(stateURL, fileManager: fileManager)
        NativeAppRemoval.removeIfEmpty(contentURL.deletingLastPathComponent(), fileManager: fileManager)
        NativeAppRemoval.removeIfEmpty(stateURL.deletingLastPathComponent(), fileManager: fileManager)

        return NativeAppRemovalReport(
            identity: identity,
            alsoDeletedData: alsoDeleteData,
            codeBytesFreed: codeBytes,
            dataBytesFreed: dataBytes,
            webStorageStoresRemoved: storesRemoved,
            permissionDecisionsForgotten: decisionsForgotten
        )
    }

    // Read namespaces even from a damaged or freed row: deletion must find
    // every named data store the app used, without requiring launchable bytes.
    private func versionWebStorageIdentifiers(
        store: NativeVersionStore, identity: NativeShellAppIdentity
    ) -> Set<UUID> {
        let directory = store.manifests.root.appendingPathComponent(identity.appId, isDirectory: true)
            .appendingPathComponent(identity.projectId, isDirectory: true)
        var result = Set<UUID>()
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            guard name.hasSuffix(".json") || name.hasSuffix(".json.freed") || name.hasSuffix(".json.tomb") else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let manifest = root["manifest"] as? [String: Any],
                  let capabilities = manifest["requestedCapabilities"] as? [String],
                  capabilities.contains("web.storage"),
                  let namespace = manifest["dataNamespace"] as? String,
                  let storage = try? NativeWebStorageIdentity(
                    appId: identity.appId, projectId: identity.projectId, dataNamespace: namespace
                  ) else { continue }
            result.insert(storage.identifier)
        }
        return result
    }

    // MARK: - Bounded storage: retention, pinning and measurement

    /// Plain-language, per-app storage facts (code size, versions kept,
    /// pins) for the Host's storage view. User-data bytes are not part of
    /// this: the Host measures those separately via `WKWebsiteDataStore`
    /// and shows them apart, per PLAN.md section 6.
    public func storageUsage(identity: NativeShellAppIdentity) async throws -> NativeStorageAppUsage {
        try await makeStore(identity: identity).storageUsage()
    }

    public func pinnedRevisionIds(identity: NativeShellAppIdentity) async throws -> [String] {
        try await makeStore(identity: identity).pinnedRevisionIds()
    }

    public func pin(identity: NativeShellAppIdentity, revisionId: String) async throws {
        try await makeStore(identity: identity).pin(revisionId: revisionId)
    }

    public func unpin(identity: NativeShellAppIdentity, revisionId: String) async throws {
        try await makeStore(identity: identity).unpin(revisionId: revisionId)
    }

    /// Explicit, reader-visible pruning (for example a "Free up space now"
    /// action), on top of the automatic best-effort pruning already hooked
    /// into `activate`, `revert` and `launchActive` above. Errors are not
    /// swallowed here: a reader who explicitly asked for this should see a
    /// failure rather than a silent no-op.
    @discardableResult
    public func pruneStorage(identity: NativeShellAppIdentity) async throws -> NativeStoragePruneReport {
        try await makeStore(identity: identity).pruneStorage()
    }

    public static let versionKeepCountUserDefaultsKey = "iris.storage.versionsKeptPerApp"

    public func versionKeepCount(defaults: UserDefaults? = nil) -> VersionsKeptPerApp {
        let preferences = defaults ?? self.defaults
        return preferences.string(forKey: Self.versionKeepCountUserDefaultsKey)
            .flatMap(VersionsKeptPerApp.init(rawValue:)) ?? .keepTwo
    }

    public func planVersionKeepCount(_ choice: VersionsKeptPerApp,
                                     defaults: UserDefaults? = nil) async throws -> NativeStorageKeepCountPlan {
        let snapshots = try await retentionSnapshots()
        return try retentionPlan(choice, capBytes: globalCodeCapBytes(defaults: defaults ?? self.defaults), snapshots: snapshots)
    }

    @discardableResult
    public func setVersionKeepCount(_ choice: VersionsKeptPerApp,
                                    defaults: UserDefaults? = nil) async throws -> NativeStorageKeepCountResult {
        let identities = try discoverStoredIdentities()
        let preferences = defaults ?? self.defaults
        guard let firstIdentity = identities.first else {
            preferences.set(choice.rawValue, forKey: Self.versionKeepCountUserDefaultsKey)
            return .init(choice: choice, bytesReclaimed: 0, retainedRevisionIds: [:], freedRevisionIds: [:], nothingCouldBeFreed: true)
        }
        let first = try makeStore(identity: firstIdentity)
        let operationID = UUID()
        storageOperationPreferences[operationID] = preferences
        defer { storageOperationPreferences.removeValue(forKey: operationID) }
        return try await first.withStorageMaintenance {
            try await self.applyVersionKeepCount(choice, preferencesID: operationID)
        }
    }

    private func applyVersionKeepCount(_ choice: VersionsKeptPerApp,
                                       preferencesID: UUID) async throws -> NativeStorageKeepCountResult {
        // The caller owns this token until the awaited maintenance returns.
        let preferences = storageOperationPreferences[preferencesID]!
        // Preflight every app before saving. Failed settlement/catalog reads
        // cannot change the preference or authorize a partial successful result.
        for identity in try discoverStoredIdentities() {
            try await makeStore(identity: identity).prepareForStorageRead()
        }
        let before = try await retentionSnapshots()
        let beforeBytes = try NativeStorageBlockMeasurement.reclaimableBytes(root: rootURL, snapshots: before,
            removing: Dictionary(uniqueKeysWithValues: before.map { ($0.identity, $0.storedIds) }))
        preferences.set(choice.rawValue, forKey: Self.versionKeepCountUserDefaultsKey)
        automaticCodeBytes = nil
        let plan = try retentionPlan(choice, capBytes: globalCodeCapBytes(defaults: preferences), snapshots: before)
        try await removeRetentionItems(plan.items, snapshots: before, choice: choice)
        let after = try await retentionSnapshots()
        let afterBytes = try NativeStorageBlockMeasurement.reclaimableBytes(root: rootURL, snapshots: after,
            removing: Dictionary(uniqueKeysWithValues: after.map { ($0.identity, $0.storedIds) }))
        let remaining = Dictionary(uniqueKeysWithValues: after.map { ($0.identity, $0.storedIds) })
        let freed = Dictionary(uniqueKeysWithValues: before.map {
            ($0.identity, $0.storedIds.subtracting(remaining[$0.identity, default: []]))
        })
        let bytes = max(0, beforeBytes - afterBytes)
        return .init(choice: choice, bytesReclaimed: bytes, retainedRevisionIds: remaining,
            freedRevisionIds: freed, nothingCouldBeFreed: bytes == 0 && !before.contains(where: { $0.awaitingFirstLaunch }) && before.allSatisfy { $0.storedIds.isSubset(of: $0.protectedIds) })
    }

    private func removeRetentionItems(_ items: [NativeStorageGlobalReclaimItem],
                                      snapshots: [NativeStorageKeepSnapshot], choice: VersionsKeptPerApp) async throws {
        let grouped = Dictionary(grouping: items, by: \.identity)
        var countRemovals = Set<NativeStorageRevisionKey>()
        // Complete count pruning first, oldest excess first in each app.
        for snapshot in snapshots {
            let selected = Set(grouped[snapshot.identity, default: []].map(\.revisionId))
            let excess = selected.intersection(snapshot.storedIds.subtracting(snapshot.retained(choice)))
            if !excess.isEmpty { _ = try await makeStore(identity: snapshot.identity).removeSpecificRevisions(excess) }
            for id in excess { countRemovals.insert(.init(identity: snapshot.identity, revisionId: id)) }
        }
        // Additional cap removals follow the global oldest-first plan order.
        for item in items where !countRemovals.contains(.init(identity: item.identity, revisionId: item.revisionId)) {
            _ = try await makeStore(identity: item.identity).removeSpecificRevisions([item.revisionId])
        }
        for snapshot in snapshots { try await makeStore(identity: snapshot.identity).finishOrdinaryStoragePrune() }
    }

    func retentionSnapshots() async throws -> [NativeStorageKeepSnapshot] {
        var snapshots: [NativeStorageKeepSnapshot] = []
        let identities = try discoverStoredIdentities()
        if let identity = identities.first { try await makeStore(identity: identity).assertStorageSettled() }
        for identity in identities {
            snapshots.append(try await makeStore(identity: identity).keepCountSnapshot(checkRootSettlement: false))
        }
        if let identity = identities.first { try await makeStore(identity: identity).assertStorageSettled() }
        return snapshots
    }

    /// Compose the count first, then the cap. Every selected prefix is priced
    /// against every live reference across the root, including unavailable apps.
    private func retentionPlan(_ choice: VersionsKeptPerApp, capBytes: Int64,
                               snapshots: [NativeStorageKeepSnapshot]) throws -> NativeStorageKeepCountPlan {
        var selected = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity, $0.storedIds.subtracting($0.retained(choice))) })
        let initialLedger = try NativeStorageReclaimLedger(root: rootURL, snapshots: snapshots)
        var ledger = initialLedger
        for (identity, ids) in selected { for id in ids { ledger.select(identity: identity, revisionId: id) } }
        let candidates = snapshots.flatMap { snapshot in
            snapshot.versions.filter { !snapshot.protectedIds.contains($0.revisionId) }.map { (snapshot.identity, $0) }
        }.sorted {
            if $0.1.createdAt != $1.1.createdAt { return $0.1.createdAt < $1.1.createdAt }
            if $0.1.revisionId != $1.1.revisionId { return $0.1.revisionId < $1.1.revisionId }
            return $0.0.id < $1.0.id
        }
        for (identity, version) in candidates {
            guard ledger.totalBytes - ledger.bytesReclaimed > max(0, capBytes) else { break }
            if selected[identity, default: []].insert(version.revisionId).inserted {
                ledger.select(identity: identity, revisionId: version.revisionId)
            }
        }
        var creditedLedger = initialLedger
        var items: [NativeStorageGlobalReclaimItem] = []
        for (identity, version) in candidates where selected[identity, default: []].contains(version.revisionId) {
            let bytes = creditedLedger.select(identity: identity, revisionId: version.revisionId)
            items.append(.init(identity: identity, revisionId: version.revisionId, allocatedBytes: Int(bytes)))
        }
        return .init(choice: choice, bytesReclaimed: ledger.bytesReclaimed, items: items)
    }

    public func featureHistory(identity: NativeShellAppIdentity) async throws -> [NativeRevisionHistoryRow] {
        guard let entry = try await libraryEntry(identity: identity) else { return [] }
        let store = try makeStore(identity: identity)
        let snapshot = try await store.keepCountSnapshot()
        let roles = NativeStorageRetentionPolicy.retainedSet(revisions: snapshot.facts,
            currentRevisionId: snapshot.current, fallbackRevisionId: snapshot.fallback, pinnedRevisionIds: snapshot.pins)
        var rows: [NativeRevisionHistoryRow] = []
        for row in NativeRevisionHistoryRow.rows(for: entry) {
            let id = row.id
            let present = try await store.revisionIsOnThisPhone(revisionId: id)
            let label: String
            if !present { label = snapshot.offers.contains(id) ? "Not on this iPhone" : "No longer available" }
            else if id == roles.current { label = "On this iPhone now" }
            else if id == roles.previous { label = "Kept as backup" }
            else if id == roles.pending { label = "Downloaded, not switched on yet" }
            else if roles.pinned.contains(id) { label = "Pinned: kept until you unpin it" }
            else if !snapshot.offers.contains(id) { label = "Kept on this iPhone (not available to download)" }
            else { label = "Kept (within your count)" }
            rows.append(.init(revision: row.revision, state: row.state, canRevert: row.canRevert,
                canActivate: row.canActivate, selectionActionLabel: row.selectionActionLabel,
                isOnThisPhone: present, storageStateLabel: label, canDownload: !present && snapshot.offers.contains(id)))
        }
        return rows
    }

    // MARK: - Global (cross-app) code cap: plan-then-enforce

    /// `UserDefaults` key for the owner-editable global code cap. Reading
    /// and writing through `UserDefaults` (rather than a new file this
    /// actor owns) keeps the setting on the same mechanism the rest of the
    /// Host app already uses for local preferences, and makes it trivial
    /// for tests to inject an isolated suite so tests never share state.
    public static let globalCodeCapUserDefaultsKey = "iris.storage.globalCodeCapBytes"

    /// The owner's current global code cap: the stored setting if one has
    /// been saved, otherwise `NativeStorageRetentionPolicy
    /// .defaultGlobalCodeCapBytes` (2 GB, an owner decision recorded there).
    public func globalCodeCapBytes(defaults: UserDefaults? = nil) -> Int64 {
        let stored = (defaults ?? self.defaults).object(forKey: Self.globalCodeCapUserDefaultsKey) as? Int64
        return stored ?? NativeStorageRetentionPolicy.defaultGlobalCodeCapBytes
    }

    /// Saves the owner's chosen global code cap. Does not enforce it: call
    /// `enforceGlobalCap` (or let the person confirm `planGlobalCapEnforcement`
    /// first) to actually reclaim space against the new value.
    public func setGlobalCodeCapBytes(_ bytes: Int64, defaults: UserDefaults? = nil) {
        (defaults ?? self.defaults).set(bytes, forKey: Self.globalCodeCapUserDefaultsKey)
    }

    /// Every installed app's storage facts plus the cross-app total and the
    /// cap it is measured against, for the Library/Storage screen (brief
    /// item 3: "per-app bars and totals"). One `storageUsage()` call per
    /// installed app; at 100 apps x 5 revisions each this is the call this
    /// unit's benchmark times end to end.
    public func globalStorageUsage(
        capBytes: Int64? = nil,
        defaults: UserDefaults? = nil
    ) async throws -> NativeStorageGlobalUsage {
        let identities = try discoverStoredIdentities()
        // Hold one root-wide read operation so every app uses the same live
        // allocation inventory. Migration/recovery finishes before accounting.
        // Results keep the sorted identity order.
        let stores = try identities.map { try makeStore(identity: $0) }
        let perApp: [NativeStorageAppUsage]
        if let first = stores.first {
            perApp = try await first.withStorageAllocationSnapshot(preparation: {
                for store in stores { try await store.prepareForStorageRead() }
            }, operation: {
                try await withThrowingTaskGroup(of: (Int, NativeStorageAppUsage).self) { group in
                    var next = 0
                    for index in 0..<min(4, stores.count) {
                        let store = stores[index]
                        group.addTask { (index, try await store.storageUsageForPreparedSnapshot()) }
                        next += 1
                    }
                    var usage: [(Int, NativeStorageAppUsage)] = []
                    for try await result in group {
                        usage.append(result)
                        if next < stores.count {
                            let index = next
                            let store = stores[index]
                            group.addTask { (index, try await store.storageUsageForPreparedSnapshot()) }
                            next += 1
                        }
                    }
                    return usage.sorted { $0.0 < $1.0 }.map { $0.1 }
                }
            })
        } else {
            perApp = []
        }
        let total = perApp.reduce(Int64(0)) { $0 + Int64($1.codeAllocatedBytes) }
        return NativeStorageGlobalUsage(
            perApp: perApp,
            totalCodeBytes: total,
            capBytes: capBytes ?? globalCodeCapBytes(defaults: defaults)
        )
    }

    /// States what enforcing the global cap would remove and how many bytes
    /// it would reclaim, without deleting anything (brief item 1:
    /// "a plan-then-enforce API that states reclaimable bytes before it
    /// deletes anything"). Draws candidates only from what each app's own
    /// `NativeRevisionStore.prunableAllocation()` already excludes current,
    /// previous, pending and pinned revisions from, so nothing this plan
    /// lists is ever a revision that is in use.
    public func planGlobalCapEnforcement(
        capBytes: Int64? = nil,
        defaults: UserDefaults? = nil
    ) async throws -> NativeStorageGlobalReclaimPlan {
        let snapshots = try await retentionSnapshots()
        let cap = capBytes ?? globalCodeCapBytes(defaults: defaults)
        let plan = try retentionPlan(versionKeepCount(defaults: defaults), capBytes: cap, snapshots: snapshots)
        let all = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity, $0.storedIds) })
        let total = try NativeStorageBlockMeasurement.reclaimableBytes(root: rootURL, snapshots: snapshots, removing: all)
        return .init(items: plan.items, reclaimableBytes: plan.bytesReclaimed,
            stillOverCapBytesAfterPlan: max(0, total - plan.bytesReclaimed - max(0, cap)))
    }

    /// Computes the same plan `planGlobalCapEnforcement` would (recomputed
    /// fresh, not cached, so a plan the person confirmed a while ago is
    /// re-verified against the store's real current state first) and then
    /// removes exactly those revisions. Safe against a plan made stale by a
    /// pin or activation that happened in between: each store's own
    /// `removeSpecificRevisions` refuses a now-retained id rather than
    /// removing it, so this call reports (via its thrown error) rather than
    /// silently under-delivering in that rare case.
    @discardableResult
    public func enforceGlobalCap(
        capBytes: Int64? = nil,
        defaults: UserDefaults? = nil
    ) async throws -> NativeStorageGlobalReclaimPlan {
        automaticCodeBytes = nil
        let identities = try discoverStoredIdentities()
        guard let firstIdentity = identities.first else {
            return .init(items: [], reclaimableBytes: 0, stillOverCapBytesAfterPlan: 0)
        }
        let operationID = UUID()
        storageOperationPreferences[operationID] = defaults ?? self.defaults
        defer { storageOperationPreferences.removeValue(forKey: operationID) }
        return try await makeStore(identity: firstIdentity).withStorageMaintenance {
            try await self.enforceGlobalCapAfterPreflight(capBytes: capBytes, preferencesID: operationID)
        }
    }

    private func enforceGlobalCapAfterPreflight(capBytes: Int64?, preferencesID: UUID) async throws -> NativeStorageGlobalReclaimPlan {
        let defaults = storageOperationPreferences[preferencesID]!
        for identity in try discoverStoredIdentities() { try await makeStore(identity: identity).prepareForStorageRead() }
        let snapshots = try await retentionSnapshots()
        let choice = versionKeepCount(defaults: defaults)
        let cap = capBytes ?? globalCodeCapBytes(defaults: defaults)
        let plan = try retentionPlan(choice, capBytes: cap, snapshots: snapshots)
        let ledger = try NativeStorageReclaimLedger(root: rootURL, snapshots: snapshots)
        try await removeRetentionItems(plan.items, snapshots: snapshots, choice: choice)
        return .init(items: plan.items, reclaimableBytes: plan.bytesReclaimed,
            stillOverCapBytesAfterPlan: max(0, ledger.totalBytes - plan.bytesReclaimed - max(0, cap)))
    }

    /// Apply the shared cap after the adapter has applied the count policy.
    /// Measure only the changed app after the first pass; a 1,000-app library
    /// must not rescan all other apps for each activation.
    private func enforceAutomaticCodeCap(changed identity: NativeShellAppIdentity) async throws {
        if try await makeStore(identity: identity).hasDeferredStoragePrune() { return }
        if automaticCodeBytes == nil {
            let usage = try await globalStorageUsage()
            automaticCodeBytes = Dictionary(uniqueKeysWithValues: usage.perApp.map {
                ($0.identity, Int64($0.codeAllocatedBytes))
            })
        }
        let usage = try await makeStore(identity: identity).storageUsage()
        automaticCodeBytes?[identity] = Int64(usage.codeAllocatedBytes)
        let cap = max(0, automaticCodeCap?() ?? globalCodeCapBytes(defaults: defaults))
        let total = automaticCodeBytes?.values.reduce(Int64(0), +) ?? 0
        guard total > cap else { return }
        _ = try await enforceGlobalCap(capBytes: cap)
    }

    private func reservePendingReview(
        reviewToken: String,
        packageSHA256: String
    ) throws -> PendingReview {
        if stagingReviewTokens.contains(reviewToken) {
            throw NativeShellLibraryError.reviewAlreadyStaging
        }
        guard let pendingReview else { throw NativeShellLibraryError.noPendingReview }
        guard pendingReview.reviewToken == reviewToken else {
            throw NativeShellLibraryError.reviewTokenMismatch
        }
        guard pendingReview.inspection.packageSHA256 == packageSHA256 else {
            throw NativeShellLibraryError.reviewDigestMismatch
        }
        guard NativeSecurity.sha256(pendingReview.packageBytes) == packageSHA256 else {
            throw NativeShellLibraryError.reviewedPackageChanged
        }
        self.pendingReview = nil
        stagingReviewTokens.insert(reviewToken)
        return pendingReview
    }

    private func stageReservedReview(
        _ pendingReview: PendingReview,
        authority: any DeliveryApprovalAuthority
    ) async throws -> NativeShellStageOutcome {
        defer { stagingReviewTokens.remove(pendingReview.reviewToken) }
        let identity = NativeShellAppIdentity(
            appId: pendingReview.inspection.appId,
            projectId: pendingReview.inspection.projectId
        )
        let store = try makeStore(identity: identity)
        let receipt = try await store.stage(
            packageBytes: pendingReview.packageBytes,
            approvalAuthority: authority
        )
        _ = try? await enforceAutomaticCodeCap(changed: identity)
        return NativeShellStageOutcome(
            identity: identity,
            revisionId: receipt.revisionId,
            alreadyStaged: receipt.alreadyStaged
        )
    }

    private func review(
        from inspection: DeliveryPackageInspection,
        reviewToken: String
    ) -> NativeShellPackageReview {
        let unsupported = Set(inspection.requestedCapabilities)
            .subtracting(capabilityPolicy.supportedCapabilities)
            .sorted()
        let nativeRequested = Set(inspection.requestedCapabilities.filter { $0.hasPrefix("native.") })
        let ungrantedNative = nativeRequested
            .subtracting(capabilityPolicy.grantedNativeCapabilities)
            .sorted()
        return NativeShellPackageReview(
            reviewToken: reviewToken,
            identity: NativeShellAppIdentity(appId: inspection.appId, projectId: inspection.projectId),
            packageSHA256: inspection.packageSHA256,
            displayName: inspection.displayName,
            baseRevisionId: inspection.baseRevisionId,
            revisionId: inspection.revisionId,
            contentHash: inspection.contentHash,
            deliveryNonce: inspection.deliveryNonce,
            embeddedApprovalId: inspection.embeddedApproval.approvalId,
            requestedCapabilities: inspection.requestedCapabilities,
            unsupportedCapabilities: Array(Set(unsupported + ungrantedNative)).sorted(),
            dataNamespace: inspection.dataNamespace
        )
    }

    private func makeStore(identity: NativeShellAppIdentity) throws -> NativeRevisionStore {
        if let existing = stores[identity] { return existing }
        let store = try NativeRevisionStore(
            rootURL: rootURL,
            appId: identity.appId,
            projectId: identity.projectId,
            shellVersion: shellVersion,
            capabilityPolicy: capabilityPolicy,
            fileManager: fileManager,
            defaults: defaults,
            downloadableRevisionIds: downloadableRevisionIds,
            versionFault: versionFault
        )
        stores[identity] = store
        return store
    }

    private func discoverStoredIdentities() throws -> [NativeShellAppIdentity] {
        var result = Set<NativeShellAppIdentity>()
        for name in ["content", "manifests"] {
            let contentRoot = rootURL.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: contentRoot.path) else { continue }
            try requirePlainDirectory(contentRoot)
            for appId in try fileManager.contentsOfDirectory(atPath: contentRoot.path) {
                let appURL = contentRoot.appendingPathComponent(appId, isDirectory: true)
                try requirePlainChildDirectory(appURL)
                guard NativeSecurity.isStableId(appId) else { throw NativeShellLibraryError.invalidLibraryNamespace(appURL.path) }
                for projectId in try fileManager.contentsOfDirectory(atPath: appURL.path) {
                    let projectURL = appURL.appendingPathComponent(projectId, isDirectory: true)
                    try requirePlainChildDirectory(projectURL)
                    guard NativeSecurity.isStableId(projectId) else { throw NativeShellLibraryError.invalidLibraryNamespace(projectURL.path) }
                    result.insert(NativeShellAppIdentity(appId: appId, projectId: projectId))
                }
            }
        }
        return result.sorted { $0.id < $1.id }
    }

    // Only for direct entries of a directory verified before it was listed.
    private func requirePlainChildDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw NativeShellLibraryError.invalidLibraryNamespace(url.path)
        }
    }

    private func requirePlainDirectory(_ url: URL) throws {
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw NativeShellLibraryError.invalidLibraryNamespace(url.path)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw NativeShellLibraryError.invalidLibraryNamespace(url.path)
        }
        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved == resolvedRoot || NativeSecurity.isDescendant(resolved, of: resolvedRoot) else {
            throw NativeShellLibraryError.invalidLibraryNamespace(url.path)
        }
    }
}
