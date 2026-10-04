import Foundation
import Darwin

/// The self-contained Versions module facade (SPEC sections 2.1 to 2.5, 2.7):
/// wires the object store, manifests, refcounts, journal and feature ledger
/// into stage / activate / rollback / undo / recover / free, exactly the
/// operations MV2's `NativeRevisionStore` adapter will delegate to. This type
/// also backs the shipping NativeRevisionStore validation adapter.
public struct NativeVersionStagedFile: Sendable {
    public let path: String
    public let data: Data
    public let mediaType: String
    public init(path: String, data: Data, mediaType: String) {
        self.path = path
        self.data = data
        self.mediaType = mediaType
    }
}

public struct NativeVersionStageReceipt: Equatable, Sendable {
    public let revisionId: String
    public let alreadyStaged: Bool
}

public enum NativeVersionRecoveryOutcome: Equatable, Sendable {
    case clean
    case rolledBackIncompleteSwap(revisionId: String)
    case completedSwapAfterCrash(revisionId: String)
    case stuck(revisionId: String)
}

public enum NativeVersionStoreError: Error, Equatable, Sendable {
    case baseMismatch(expected: String?, actual: String?)
    case revisionNotFound(String)
    case notAnAncestorOrFallback(String)
    case noUndoOffer
    case journalStuck(String)
}

private enum NativeVersionOperationContext {
    @TaskLocal static var roots: Set<String> = []
    @TaskLocal static var allocations: [String: [String: [NativeStorageRevisionAllocation]]] = [:]
    @TaskLocal static var sweptRoots: Set<String> = []
    @TaskLocal static var inventories: [String: [String: [NativeVersionManifest]]] = [:]
}

/// Shared by the shipping adapters, including adapters reconstructed on refresh.
/// Keep the root writer and its decoded manifests alive across adapter refreshes.
final class NativeVersionStoreRegistry: @unchecked Sendable {
    static let shared = NativeVersionStoreRegistry()
    private final class Entry {
        let store: NativeVersionStore
        init(_ store: NativeVersionStore) { self.store = store }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func store(root: URL) throws -> NativeVersionStore {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { entry in FileManager.default.fileExists(atPath: entry.key) }
        if let store = entries[root.path]?.store { return store }
        let store = try NativeVersionStore(root: root)
        entries[root.path] = Entry(store)
        return store
    }
}

public actor NativeVersionStore {
    public let root: URL // .../v1
    public let objects: NativeObjectStore
    public let manifests: NativeVersionManifestStore
    public let refs: NativeVersionRefs
    public let checkouts: NativeVersionCheckoutBuilder
    public let state: NativeVersionStateFiles
    public let ledger: NativeFeatureLedger
    public let gc: NativeVersionGC

    /// Consecutive relaunches that could not settle a stuck journal for the
    /// same app+project (SPEC 2.4: "after two unsettled checks" the honest
    /// failure sentence appears). Kept in memory; a real relaunch restarts
    /// this count, matching the phone's own process lifetime.
    private var unsettledJournalChecks: [String: Int] = [:]
    private var operationHeld = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Actor reentrancy must not interleave a dirty-ref rebuild with stage or
    /// collection. The task-local token allows facade calls inside one adapter
    /// operation without taking the same lock twice.
    func withExclusiveAccess<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        if NativeVersionOperationContext.roots.contains(root.path) {
            return try await operation()
        }
        if operationHeld {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            operationHeld = true
        }
        defer {
            if operationWaiters.isEmpty { operationHeld = false }
            else { operationWaiters.removeFirst().resume() }
        }
        var roots = NativeVersionOperationContext.roots
        roots.insert(root.path)
        return try await NativeVersionOperationContext.$roots.withValue(roots, operation: operation)
    }

    public init(root: URL) throws {
        self.root = root
        let objects = try NativeObjectStore(root: root.appendingPathComponent("objects", isDirectory: true))
        let manifests = try NativeVersionManifestStore(root: root.appendingPathComponent("manifests", isDirectory: true))
        self.objects = objects
        self.manifests = manifests
        self.refs = try NativeVersionRefs(root: root.appendingPathComponent("gc", isDirectory: true))
        self.checkouts = try NativeVersionCheckoutBuilder(root: root.appendingPathComponent("checkouts", isDirectory: true), objects: objects)
        self.state = try NativeVersionStateFiles(root: root.appendingPathComponent("state", isDirectory: true))
        self.ledger = try NativeFeatureLedger(root: root.appendingPathComponent("state", isDirectory: true))
        self.gc = NativeVersionGC(objects: objects, manifests: manifests, refs: self.refs)
    }

    /// All shipping adapters for a root share the same refs connection and
    /// operation gate. Native module fixtures may still construct isolated roots.
    public static func shared(root: URL) throws -> NativeVersionStore {
        try NativeVersionStoreRegistry.shared.store(root: root)
    }

    public func migrateLegacy(
        appId: String, projectId: String, legacyRevisionsRoot: URL,
        currentRevisionId: String?, fallbackRevisionId: String?,
        fault: NativeVersionFaultInjector = .init()
    ) async throws {
        try await withExclusiveAccess {
            try await self.migrateLegacyImpl(appId: appId, projectId: projectId,
                legacyRevisionsRoot: legacyRevisionsRoot, currentRevisionId: currentRevisionId,
                fallbackRevisionId: fallbackRevisionId, fault: fault)
        }
    }

    private func migrateLegacyImpl(
        appId: String, projectId: String, legacyRevisionsRoot: URL,
        currentRevisionId: String?, fallbackRevisionId: String?, fault: NativeVersionFaultInjector
    ) async throws {
        for id in [currentRevisionId, fallbackRevisionId].compactMap({ $0 }) {
            try preserveUnknownCopyReceipt(appId: appId, projectId: projectId, revisionId: id)
        }
        try await NativeStoreMigration(legacyRevisionsRoot: legacyRevisionsRoot, v1Root: root).migrate(
            appId: appId, projectId: projectId, currentRevisionId: currentRevisionId,
            fallbackRevisionId: fallbackRevisionId, objects: objects, manifests: manifests,
            refs: refs, ledger: ledger, checkouts: checkouts, fault: fault)
        for id in [currentRevisionId, fallbackRevisionId].compactMap({ $0 }) {
            try verifyCheckoutTree(manifests.read(appId: appId, projectId: projectId, revisionId: id),
                                   appId: appId, projectId: projectId)
        }
        if let currentRevisionId {
            try state.writeActive(.init(currentRevisionId: currentRevisionId, fallbackRevisionId: fallbackRevisionId),
                                  appId: appId, projectId: projectId, fault: fault)
        }
    }

    /// One screen read shares one accounting snapshot while the root writer
    /// is held. Recovery finishes first, and the snapshot cannot outlive this
    /// operation or be reused by a later read after delivery or external edits.
    func withAllocationSnapshot<T: Sendable>(
        preparation: @Sendable () async throws -> Void,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await withExclusiveAccess {
            // Global temp sweeps need only run once in this root-held read.
            self.objects.sweepOrphanTemps()
            await self.sweepOrphanCheckoutTemps()
            var sweptRoots = NativeVersionOperationContext.sweptRoots
            sweptRoots.insert(self.root.path)
            return try await NativeVersionOperationContext.$sweptRoots.withValue(sweptRoots) {
                try await preparation()
                let inventory = try await self.liveSnapshotInventory()
                var inventories = NativeVersionOperationContext.inventories
                inventories[self.root.path] = Dictionary(grouping: inventory) { "\($0.0)/\($0.1)" }
                    .mapValues { $0.map { $0.2 } }
                var snapshots = NativeVersionOperationContext.allocations
                snapshots[self.root.path] = try await self.parallelSnapshotAllocation(inventory)
                return try await NativeVersionOperationContext.$inventories.withValue(inventories) {
                    try await NativeVersionOperationContext.$allocations.withValue(snapshots, operation: operation)
                }
            }
        }
    }

    nonisolated var hasAllocationSnapshot: Bool {
        NativeVersionOperationContext.allocations[root.path] != nil
    }

    nonisolated func allocationManifests(appId: String, projectId: String) throws -> [NativeVersionManifest] {
        if let inventory = NativeVersionOperationContext.inventories[root.path] {
            return inventory["\(appId)/\(projectId)"] ?? []
        }
        return try manifests.list(appId: appId, projectId: projectId)
    }

    private func key(_ appId: String, _ projectId: String) -> String { "\(appId)/\(projectId)" }

    /// Mutation-check seam only (HANDOFF.md check 3); never flipped in
    /// production code.
    static let writeJournalBeforeSwapEnabled = true

    @discardableResult
    public func stage(
        appId: String, projectId: String, revisionId: String, baseRevisionId: String?,
        contentHash: String, createdAt: String, files: [NativeVersionStagedFile],
        changes: [NativeVersionChange]? = nil, title: String? = nil,
        manifest: NativeVersionAppManifest? = nil,
        fault: NativeVersionFaultInjector = .init()
    ) async throws -> NativeVersionStageReceipt {
        try await withExclusiveAccess {
            try await self.stageImpl(appId: appId, projectId: projectId, revisionId: revisionId,
                baseRevisionId: baseRevisionId, contentHash: contentHash, createdAt: createdAt,
                files: files, changes: changes, title: title, manifest: manifest, fault: fault)
        }
    }

    // MARK: Stage (SPEC 2.2)

    @discardableResult
    private func stageImpl(
        appId: String,
        projectId: String,
        revisionId: String,
        baseRevisionId: String?,
        contentHash: String,
        createdAt: String,
        files: [NativeVersionStagedFile],
        changes: [NativeVersionChange]? = nil,
        title: String? = nil,
        manifest appManifest: NativeVersionAppManifest? = nil,
        fault: NativeVersionFaultInjector = .init()
    ) async throws -> NativeVersionStageReceipt {
        if await refs.isDirty() { try? await rebuildAllRefsImpl() }
        let refsWereVerified = !(await refs.isDirty())
        if manifests.exists(appId: appId, projectId: projectId, revisionId: revisionId) {
            // The manifest lands before the Features row is appended. A
            // force-quit between the two leaves a complete version with no
            // row, and this retry is the only later chance to add it.
            let known = ledger.rows(appId: appId, projectId: projectId).contains { $0.revisionId == revisionId }
            if !known, let existing = try? manifests.read(appId: appId, projectId: projectId, revisionId: revisionId) {
                let isFirst = (try? manifests.list(appId: appId, projectId: projectId).count == 1) ?? false
                let kind: NativeFeatureLedgerRow.Kind = existing.changes?.first?.kind == .removed ? .removed : (existing.changes?.first?.kind == .added ? .added : .updated)
                let rowTitle = title ?? existing.changes?.first?.title ?? (isFirst ? "First version" : "Update")
                try? ledger.append(
                    NativeFeatureLedgerRow(title: rowTitle, kind: kind, createdAt: existing.createdAt, revisionId: revisionId),
                    appId: appId, projectId: projectId
                )
            }
            return NativeVersionStageReceipt(revisionId: revisionId, alreadyStaged: true)
        }

        // Written before any object write, so a crash after the manifest
        // rename but before the refs commit self-heals on the next launch
        // (SPEC 2.2 step 3).
        try await refs.markDirty()

        var entries: [NativeVersionFileEntry] = []
        for file in files {
            let expected = NativeObjectStore.hex(file.data)
            let destination = objects.path(forSHA256: expected)
            let directory = destination.deletingLastPathComponent()
            try NativeSecurity.assertNoSymlinkComponents(from: root, to: objects.root, fileManager: .default)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
            try NativeSecurity.assertNoSymlinkComponents(from: root, to: directory, fileManager: .default)
            if objects.exists(sha256: expected) {
                try NativeSecurity.assertNoSymlinkComponents(from: root, to: destination, fileManager: .default)
                guard try objects.verify(sha256: expected) else {
                    throw NativeObjectStoreError.corruptObject(sha256: expected)
                }
            }
            let sha = try objects.write(file.data, fault: fault)
            entries.append(NativeVersionFileEntry(path: file.path, sha256: sha, bytes: file.data.count, mediaType: file.mediaType))
        }

        let manifest = NativeVersionManifest(
            revisionId: revisionId,
            baseRevisionId: baseRevisionId,
            contentHash: contentHash,
            createdAt: createdAt,
            files: entries,
            changes: changes,
            manifest: appManifest
        )
        try manifests.write(manifest, appId: appId, projectId: projectId, fault: fault)

        // Independent-verifier fix: `entries` has one item per FILE, not per
        // unique object. Two files in the same version can share identical
        // bytes (two empty placeholders, a duplicated template file), which
        // used to make this `Dictionary(uniqueKeysWithValues:)` trap with
        // "Duplicate values for key" -- an unrecoverable process crash, not
        // a catchable error. Build the map by hand instead, keeping one
        // entry per distinct sha256 (its allocated-byte count is the same
        // object either way, so the second occurrence is redundant, not
        // conflicting). This also keeps this manifest's contribution to
        // `incrementAll` at one increment per distinct object, matching
        // `NativeVersionGC.free`'s decrement and `NativeVersionRefs.rebuild`
        // (both fixed the same way) so refcounts never drift.
        var allocatedBytes: [String: Int] = [:]
        for entry in entries where allocatedBytes[entry.sha256] == nil {
            allocatedBytes[entry.sha256] = try objects.allocatedBytes(sha256: entry.sha256)
        }
        if refsWereVerified {
            do {
                try await refs.incrementAll(sha256Hexes: allocatedBytes, fault: fault)
                await refs.clearDirty()
            } catch let crash as NativeVersionSimulatedCrash {
                throw crash
            } catch {
                // Bytes and manifest are complete. Keep dirty for recovery;
                // unavailable accounting must not block installing the fix.
            }
        }

        let isFirst = try manifests.list(appId: appId, projectId: projectId).count == 1
        let ledgerKind: NativeFeatureLedgerRow.Kind = changes?.first?.kind == .removed ? .removed : (changes?.first?.kind == .added ? .added : .updated)
        let rowTitle = title ?? changes?.first?.title ?? (isFirst ? "First version" : "Update")
        try? ledger.append(
            NativeFeatureLedgerRow(title: rowTitle, kind: ledgerKind, createdAt: createdAt, revisionId: revisionId),
            appId: appId, projectId: projectId
        )

        return NativeVersionStageReceipt(revisionId: revisionId, alreadyStaged: false)
    }

    // MARK: Activate / rollback / undo (SPEC 2.3)

    /// `to.baseRevisionId == current` (a normal forward update).
    @discardableResult
    public func activate(appId: String, projectId: String, revisionId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        try await withExclusiveAccess { try await self.activateImpl(appId: appId, projectId: projectId, revisionId: revisionId, fault: fault) }
    }

    private func activateImpl(appId: String, projectId: String, revisionId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        let current = state.readActive(appId: appId, projectId: projectId)
        guard let target = try? manifests.read(appId: appId, projectId: projectId, revisionId: revisionId) else {
            throw NativeVersionStoreError.revisionNotFound(revisionId)
        }
        if current?.currentRevisionId == revisionId { return false }
        guard target.baseRevisionId == current?.currentRevisionId else {
            throw NativeVersionStoreError.baseMismatch(expected: current?.currentRevisionId, actual: target.baseRevisionId)
        }
        try await performSwap(appId: appId, projectId: projectId, op: .activate, from: current?.currentRevisionId, to: revisionId, writeUndoOffer: false, fault: fault)
        return true
    }

    /// `to` must be an ancestor of current or the fallback (mirrors
    /// `NativeRevisionHistoryRow.canRevert`).
    @discardableResult
    public func rollback(appId: String, projectId: String, revisionId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        try await withExclusiveAccess { try await self.rollbackImpl(appId: appId, projectId: projectId, revisionId: revisionId, fault: fault) }
    }

    private func rollbackImpl(appId: String, projectId: String, revisionId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        let current = state.readActive(appId: appId, projectId: projectId)
        guard current != nil else { throw NativeVersionStoreError.revisionNotFound(revisionId) }
        guard manifests.exists(appId: appId, projectId: projectId, revisionId: revisionId) else {
            throw NativeVersionStoreError.revisionNotFound(revisionId)
        }
        if current?.currentRevisionId == revisionId { return false }
        let isFallback = current?.fallbackRevisionId == revisionId
        let isAncestor = isFallback ? false : try isAncestor(revisionId, ofCurrent: current?.currentRevisionId, appId: appId, projectId: projectId)
        guard isFallback || isAncestor else {
            throw NativeVersionStoreError.notAnAncestorOrFallback(revisionId)
        }
        try await performSwap(appId: appId, projectId: projectId, op: .rollback, from: current?.currentRevisionId, to: revisionId, writeUndoOffer: true, fault: fault)
        return true
    }

    /// Re-activates the version that was current before the last Go back or
    /// Remove (SPEC 1.2 "Undo"). Offered until the next swap; cleared here.
    @discardableResult
    public func undo(appId: String, projectId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        try await withExclusiveAccess { try await self.undoImpl(appId: appId, projectId: projectId, fault: fault) }
    }

    private func undoImpl(appId: String, projectId: String, fault: NativeVersionFaultInjector = .init()) async throws -> Bool {
        guard let offer = state.readUndoOffer(appId: appId, projectId: projectId) else {
            throw NativeVersionStoreError.noUndoOffer
        }
        let current = state.readActive(appId: appId, projectId: projectId)
        if current?.currentRevisionId == offer.to {
            // The undo already happened (a force-quit landed after the swap
            // but before the offer was cleared). Swapping "to" the version
            // that is already current would overwrite the real fallback with
            // itself, so just settle the leftovers.
            settleUndo(offerFrom: offer.from, appId: appId, projectId: projectId)
            return false
        }
        try await performSwap(appId: appId, projectId: projectId, op: .undo, from: current?.currentRevisionId, to: offer.to, writeUndoOffer: false, fault: fault)
        settleUndo(offerFrom: offer.from, appId: appId, projectId: projectId)
        return true
    }

    /// Clears the offer and marks the undone version's row. Idempotent, so
    /// it runs the same way from a live undo and from crash recovery.
    private func settleUndo(offerFrom: String, appId: String, projectId: String) {
        state.clearUndoOffer(appId: appId, projectId: projectId)
        try? ledger.markUndone(revisionId: offerFrom, at: NativeVersionRefs.iso(Date()), appId: appId, projectId: projectId)
    }

    private func isAncestor(_ revisionId: String, ofCurrent current: String?, appId: String, projectId: String) throws -> Bool {
        var cursor = current
        var seen = Set<String>()
        while let id = cursor, seen.insert(id).inserted {
            // Freed ancestors still carry the chain needed to reach a kept
            // older version. The target itself must have live objects above.
            guard let manifest = try? manifests.readHistory(appId: appId, projectId: projectId, revisionId: id) else { return false }
            if manifest.baseRevisionId == revisionId { return true }
            cursor = manifest.baseRevisionId
        }
        return false
    }

    private func performSwap(
        appId: String,
        projectId: String,
        op: NativeVersionJournal.Op,
        from: String?,
        to: String,
        writeUndoOffer: Bool,
        fault: NativeVersionFaultInjector
    ) async throws {
        let startedAt = NativeVersionRefs.iso(Date())
        // Mutation check 3 (HANDOFF.md): flipping this to false skips the
        // journal write, so a crash after the pointer write below has no
        // record of what was in flight. This flag exists only for that
        // mutation script; production always leaves it true.
        if Self.writeJournalBeforeSwapEnabled {
            try state.writeJournal(
                NativeVersionJournal(op: op, from: from, to: to, startedAt: startedAt, phase: .building),
                appId: appId, projectId: projectId, fault: fault
            )
        }

        let manifest = try manifests.read(appId: appId, projectId: projectId, revisionId: to)
        try preserveUnknownCopyReceipt(appId: appId, projectId: projectId, revisionId: to)
        _ = try checkouts.build(manifest: manifest, appId: appId, projectId: projectId, fault: fault)
        try verifyCheckoutTree(manifest, appId: appId, projectId: projectId)

        try state.writeActive(
            NativeVersionActivePointer(currentRevisionId: to, fallbackRevisionId: from),
            appId: appId, projectId: projectId, fault: fault
        )

        try finishSwapCleanup(op: op, from: from, to: to, writeUndoOffer: writeUndoOffer, appId: appId, projectId: projectId, fault: fault)
    }

    /// Steps 4 to 6 of SPEC 2.3: undo offer, ledger row, journal delete,
    /// stale-checkout delete. Shared by the live swap path and by recovery
    /// finishing a swap whose pointer already moved before a crash.
    private func finishSwapCleanup(
        op: NativeVersionJournal.Op,
        from: String?,
        to: String,
        writeUndoOffer: Bool,
        appId: String,
        projectId: String,
        fault: NativeVersionFaultInjector
    ) throws {
        if writeUndoOffer {
            try state.writeUndoOffer(
                NativeVersionUndoOffer(from: to, to: from ?? to, kind: op.rawValue, at: NativeVersionRefs.iso(Date())),
                appId: appId, projectId: projectId, fault: fault
            )
            _ = try? ledger.append(
                NativeFeatureLedgerRow(
                    title: "Went back to a previous version",
                    kind: .restored,
                    createdAt: NativeVersionRefs.iso(Date()),
                    revisionId: to
                ),
                appId: appId, projectId: projectId
            )
        }

        try fault.fire(.journalWrite_beforeJournalDelete)
        state.deleteJournal(appId: appId, projectId: projectId)

        // Delete the checkout of any version that is neither current nor
        // fallback (objects stay; only the clone tree goes).
        let keep: Set<String> = [to, from].compactMap { $0 }.reduce(into: Set<String>()) { $0.insert($1) }
        cleanupCheckouts(appId: appId, projectId: projectId, keep: keep)
    }

    private func cleanupCheckouts(appId: String, projectId: String, keep: Set<String>) {
        let directory = checkouts.root.path + "/" + appId + "/" + projectId
        for id in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            guard NativeSecurity.isSafePackagePath(id), !keep.contains(id) else { continue }
            try? checkouts.delete(appId: appId, projectId: projectId, revisionId: id)
        }
    }

    // MARK: Crash recovery on relaunch (SPEC 2.4)

    /// Run on every launch and before every Features operation. Order:
    /// sweep temps, finish interrupted removals, settle a dirty refs rebuild,
    /// settle an in-flight journal.
    public func recoverIfNeeded(appId: String, projectId: String, fault: NativeVersionFaultInjector = .init()) async throws -> NativeVersionRecoveryOutcome {
        try await withExclusiveAccess { try await self.recoverIfNeededImpl(appId: appId, projectId: projectId, fault: fault) }
    }

    private func recoverIfNeededImpl(appId: String, projectId: String, fault: NativeVersionFaultInjector = .init()) async throws -> NativeVersionRecoveryOutcome {
        if !NativeVersionOperationContext.sweptRoots.contains(root.path) {
            objects.sweepOrphanTemps()
            sweepOrphanCheckoutTemps()
        }

        // The manifest rename can land without a dirty marker. Finish every
        // tombstone before any Features read or prune, even below the cap.
        _ = try await gc.recoverTombstones()
        if await refs.isDirty() { try? await rebuildAllRefsImpl() }

        let manifestDirectory = manifests.root.appendingPathComponent(appId).appendingPathComponent(projectId)
        for child in (try? FileManager.default.contentsOfDirectory(at: manifestDirectory, includingPropertiesForKeys: nil)) ?? [] {
            if child.lastPathComponent.hasPrefix("tmp-") { try? FileManager.default.removeItem(at: child) }
        }

        guard let journal = state.readJournal(appId: appId, projectId: projectId) else {
            if let active = state.readActive(appId: appId, projectId: projectId) {
                cleanupCheckouts(appId: appId, projectId: projectId,
                    keep: Set([active.currentRevisionId, active.fallbackRevisionId].compactMap { $0 }))
            }
            return .clean
        }

        let active = state.readActive(appId: appId, projectId: projectId)
        if active?.currentRevisionId == journal.to {
            // The pointer already moved: the swap finished, only cleanup remains.
            try finishSwapCleanup(
                op: journal.op, from: journal.from, to: journal.to,
                writeUndoOffer: journal.op == .rollback, appId: appId, projectId: projectId, fault: fault
            )
            if journal.op == .undo, let offer = state.readUndoOffer(appId: appId, projectId: projectId) {
                settleUndo(offerFrom: offer.from, appId: appId, projectId: projectId)
            }
            unsettledJournalChecks[key(appId, projectId)] = 0
            return .completedSwapAfterCrash(revisionId: journal.to)
        }

        // Pointer never moved: nothing changed. Remove any partially built
        // checkout for `to` and the journal; the row reads "stopped before
        // it finished, nothing was changed".
        do {
            if checkouts.exists(appId: appId, projectId: projectId, revisionId: journal.to) {
                if let manifest = try? manifests.read(appId: appId, projectId: projectId, revisionId: journal.to) {
                    _ = try? checkouts.verify(manifest: manifest, appId: appId, projectId: projectId)
                }
                try checkouts.delete(appId: appId, projectId: projectId, revisionId: journal.to)
            }
            state.deleteJournal(appId: appId, projectId: projectId)
            try? ledger.markStoppedBeforeFinishing(revisionId: journal.to, appId: appId, projectId: projectId)
            unsettledJournalChecks[key(appId, projectId)] = 0
            return .rolledBackIncompleteSwap(revisionId: journal.to)
        } catch {
            let count = (unsettledJournalChecks[key(appId, projectId), default: 0]) + 1
            unsettledJournalChecks[key(appId, projectId)] = count
            if count >= 2 {
                return .stuck(revisionId: journal.to)
            }
            throw NativeVersionStoreError.journalStuck(journal.to)
        }
    }

    private func sweepOrphanCheckoutTemps() {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(at: checkouts.root, includingPropertiesForKeys: nil) else { return }
        for child in children where child.lastPathComponent.hasPrefix("tmp-") {
            try? fileManager.removeItem(at: child)
        }
    }

    /// Rebuilds `refs.sqlite` from every manifest across every app (SPEC
    /// 2.4, 2.5): run when `gc/dirty` is set, after migration, and by the
    /// mark-and-sweep verifier.
    public func rebuildAllRefs() async throws -> Void {
        try await withExclusiveAccess { try await self.rebuildAllRefsImpl() }
    }

    private func rebuildAllRefsImpl() async throws {
        var all: [NativeVersionManifest] = []
        for project in try manifests.allProjects() {
            all.append(contentsOf: try manifests.list(appId: project.appId, projectId: project.projectId))
        }
        try await refs.rebuild(from: all, bytesForObject: { try objects.allocatedBytes(sha256: $0) })
    }

    // MARK: Launch (SPEC 2.4)

    /// Verifies the current checkout; rebuilds it from objects if that
    /// fails; falls back to the fallback version if an object is damaged.
    /// Never returns a blank app when a backup version exists.
    public func launchContentRoot(appId: String, projectId: String) async throws -> URL {
        try await withExclusiveAccess { try await self.launchContentRootImpl(appId: appId, projectId: projectId) }
    }

    private func launchContentRootImpl(appId: String, projectId: String) async throws -> URL {
        guard let active = state.readActive(appId: appId, projectId: projectId) else {
            throw NativeVersionStoreError.revisionNotFound("<none active>")
        }
        if let root = try? verifiedOrRebuiltContentRoot(appId: appId, projectId: projectId, revisionId: active.currentRevisionId) {
            return root
        }
        guard let fallback = active.fallbackRevisionId,
              let root = try? verifiedOrRebuiltContentRoot(appId: appId, projectId: projectId, revisionId: fallback)
        else {
            throw NativeVersionStoreError.revisionNotFound(active.currentRevisionId)
        }
        try state.writeActive(NativeVersionActivePointer(currentRevisionId: fallback, fallbackRevisionId: nil), appId: appId, projectId: projectId)
        return root
    }

    private func preserveUnknownCopyReceipt(appId: String, projectId: String, revisionId: String) throws {
        guard checkouts.exists(appId: appId, projectId: projectId, revisionId: revisionId) else { return }
        let url = checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: revisionId)
            .deletingLastPathComponent().appendingPathComponent("checkout.json")
        if let data = try? Data(contentsOf: url),
           (try? JSONDecoder().decode(NativeVersionCheckoutRecord.self, from: data)) != nil { return }
        let record = NativeVersionCheckoutRecord(cloned: false, builtAt: NativeVersionRefs.iso(Date()), verifiedAt: nil)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }

    private func verifyCheckoutTree(_ manifest: NativeVersionManifest, appId: String, projectId: String) throws {
        let content = checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: manifest.revisionId)
        let paths = Set(manifest.files.map(\.path))
        var directories = Set<String>()
        for file in manifest.files {
            guard NativeSecurity.isSafePackagePath(file.path) else {
                throw NativeVersionCheckoutError.verificationFailed("unsafe path")
            }
            let components = file.path.split(separator: "/")
            if components.count > 1 {
                for end in 1..<components.count { directories.insert(components.prefix(end).joined(separator: "/")) }
            }
            let url = content.appendingPathComponent(file.path)
            try NativeSecurity.assertNoSymlinkComponents(from: root, to: url, fileManager: .default)
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  let data = try? Data(contentsOf: url), data.count == file.bytes,
                  NativeObjectStore.hex(data) == file.sha256 else {
                throw NativeVersionCheckoutError.verificationFailed("invalid checkout file")
            }
        }
        guard let walker = FileManager.default.enumerator(atPath: content.path) else {
            throw NativeVersionCheckoutError.verificationFailed("unreadable checkout")
        }
        var seen = Set<String>()
        while let path = walker.nextObject() as? String {
            let type = walker.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                guard directories.contains(path) else { throw NativeVersionCheckoutError.verificationFailed("unexpected directory") }
            } else {
                guard type == .typeRegular, paths.contains(path) else {
                    throw NativeVersionCheckoutError.verificationFailed("unexpected checkout entry")
                }
                seen.insert(path)
            }
        }
        guard seen == paths else { throw NativeVersionCheckoutError.verificationFailed("missing checkout file") }
    }

    private func verifiedOrRebuiltContentRoot(appId: String, projectId: String, revisionId: String) throws -> URL {
        let manifest = try manifests.read(appId: appId, projectId: projectId, revisionId: revisionId)
        try preserveUnknownCopyReceipt(appId: appId, projectId: projectId, revisionId: revisionId)
        _ = try checkouts.build(manifest: manifest, appId: appId, projectId: projectId)
        try verifyCheckoutTree(manifest, appId: appId, projectId: projectId)
        return checkouts.contentRoot(appId: appId, projectId: projectId, revisionId: revisionId)
    }
    // Cache only invariant validation of the complete decoded value. Every
    // inventory still lists and stats live manifest files through their reader.
    private final class InventoryValidationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (NativeVersionManifest, Int)] = [:]
        private var bytes = 0

        func contains(_ manifest: NativeVersionManifest, key: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return entries[key]?.0 == manifest
        }

        func insert(_ manifest: NativeVersionManifest, key: String) {
            let limit = 8 * 1_024 * 1_024
            guard let count = try? JSONEncoder().encode(manifest).count, count <= limit else { return }
            lock.lock(); defer { lock.unlock() }
            if let old = entries.removeValue(forKey: key) { bytes -= old.1 }
            if entries.count >= 2_048 || bytes > limit - count {
                entries.removeAll(keepingCapacity: true)
                bytes = 0
            }
            entries[key] = (manifest, count)
            bytes += count
        }
    }

    private nonisolated static let inventoryValidationCache = InventoryValidationCache()

    private nonisolated func validatedManifests(appId: String, projectId: String) throws -> [NativeVersionManifest] {
        let versions = try manifests.list(appId: appId, projectId: projectId)
        for manifest in versions {
            let cacheKey = "\(appId)/\(projectId)/\(manifest.revisionId)"
            if !Self.inventoryValidationCache.contains(manifest, key: cacheKey) {
                guard NativeSecurity.isStableId(appId), NativeSecurity.isStableId(projectId),
                      NativeSecurity.isRevisionId(manifest.revisionId),
                      manifest.files.allSatisfy({ NativeSecurity.isSafePackagePath($0.path)
                        && $0.sha256.count == 64 && $0.sha256.allSatisfy({ "0123456789abcdef".contains($0) })
                        && $0.bytes >= 0 }) else {
                    throw NativeVersionManifestError.manifestCorrupt(manifest.revisionId)
                }
                Self.inventoryValidationCache.insert(manifest, key: cacheKey)
            }
        }
        return versions
    }

    private nonisolated func liveManifestInventory() throws -> [(String, String, NativeVersionManifest)] {
        var result: [(String, String, NativeVersionManifest)] = []
        for project in try manifests.allProjects() {
            for manifest in try validatedManifests(appId: project.appId, projectId: project.projectId) {
                result.append((project.appId, project.projectId, manifest))
            }
        }
        return result
    }

    /// The root writer remains held while at most four readers inspect the
    /// independent project rows. Each reader still observes live signatures.
    private nonisolated func liveSnapshotInventory() async throws -> [(String, String, NativeVersionManifest)] {
        let projects = try manifests.allProjects()
        return try await withThrowingTaskGroup(of: [(String, String, NativeVersionManifest)].self) { group in
            for batch in 0..<min(4, projects.count) {
                let selected = projects.enumerated().filter { $0.offset % 4 == batch }.map { $0.element }
                group.addTask {
                    var result: [(String, String, NativeVersionManifest)] = []
                    for project in selected {
                        for manifest in try self.validatedManifests(appId: project.appId, projectId: project.projectId) {
                            result.append((project.appId, project.projectId, manifest))
                        }
                    }
                    return result
                }
            }
            var result: [(String, String, NativeVersionManifest)] = []
            for try await batch in group { result.append(contentsOf: batch) }
            return result
        }
    }

    private nonisolated func parallelSnapshotAllocation(
        _ inventory: [(String, String, NativeVersionManifest)]
    ) async throws -> [String: [NativeStorageRevisionAllocation]] {
        var sharers: [String: Set<String>] = [:]
        for (app, project, manifest) in inventory {
            for hash in Set(manifest.files.map(\.sha256)) { sharers[hash, default: []].insert("\(app)/\(project)") }
        }
        let sharedReferences = sharers
        let identities = Set(inventory.map { "\($0.0)/\($0.1)" }).sorted()
        return try await withThrowingTaskGroup(of: [String: [NativeStorageRevisionAllocation]].self) { group in
            for batch in 0..<min(4, identities.count) {
                let selected = Set(identities.enumerated().filter { $0.offset % 4 == batch }.map { $0.element })
                group.addTask {
                    try self.allocationByProject(only: nil, inventory: inventory,
                        selectedIdentities: selected, knownSharers: sharedReferences)
                }
            }
            var result: [String: [NativeStorageRevisionAllocation]] = [:]
            for try await batch in group {
                for (identity, rows) in batch { result[identity] = rows }
            }
            return result
        }
    }

    /// st_blocks of unique objects, shared equally between app/project bars.
    /// Within one bar an object is assigned to its oldest referencing version,
    /// making the revision allocations sum exactly to that app's charged total.
    nonisolated func allocation(appId: String, projectId: String) throws -> [NativeStorageRevisionAllocation] {
        let identity = "\(appId)/\(projectId)"
        if let snapshot = NativeVersionOperationContext.allocations[root.path] {
            return snapshot[identity] ?? []
        }
        return try allocationByProject(only: identity)[identity] ?? []
    }

    // A receipt can skip decoding only while its live disk identity matches.
    // Missing, malformed or linked receipts conservatively charge the copy.
    private final class CheckoutReceiptCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (String, NativeVersionCheckoutRecord, Int)] = [:]
        private var bytes = 0

        private func signature(_ path: String) -> String? {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_gid):\(info.st_nlink):\(info.st_size):\(info.st_blocks):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }

        func read(_ path: String) -> NativeVersionCheckoutRecord? {
            guard let observed = signature(path) else { return nil }
            lock.lock()
            let cached = entries[path]
            lock.unlock()
            if let cached, cached.0 == observed, signature(path) == observed { return cached.1 }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)),
                  let record = try? JSONDecoder().decode(NativeVersionCheckoutRecord.self, from: data),
                  signature(path) == observed else { return nil }
            let limit = 8 * 1_024 * 1_024
            if data.count <= limit {
                lock.lock(); defer { lock.unlock() }
                if let old = entries.removeValue(forKey: path) { bytes -= old.2 }
                if entries.count >= 2_048 || bytes > limit - data.count {
                    entries.removeAll(keepingCapacity: true)
                    bytes = 0
                }
                entries[path] = (observed, record, data.count)
                bytes += data.count
            }
            return record
        }
    }

    private nonisolated static let checkoutReceiptCache = CheckoutReceiptCache()

    private nonisolated func allocationByProject(
        only selectedIdentity: String?, inventory: [(String, String, NativeVersionManifest)]? = nil,
        selectedIdentities: Set<String>? = nil, knownSharers: [String: Set<String>]? = nil
    ) throws -> [String: [NativeStorageRevisionAllocation]] {
        let all = try inventory ?? liveManifestInventory()
        var sharers = knownSharers ?? [:]
        if knownSharers == nil {
            for (app, project, manifest) in all {
                for hash in Set(manifest.files.map(\.sha256)) { sharers[hash, default: []].insert("\(app)/\(project)") }
            }
        }
        let projects = Dictionary(grouping: all) { "\($0.0)/\($0.1)" }
        var allocations: [String: [NativeStorageRevisionAllocation]] = [:]
        var objectShares: [String: [String: Int]] = [:]
        for (identity, versions) in projects where (selectedIdentity == nil || selectedIdentity == identity)
            && (selectedIdentities == nil || selectedIdentities!.contains(identity)) {
        guard let first = versions.first else { continue }
        let appId = first.0
        let projectId = first.1
        let own = versions.map { $0.2 }.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt.compare(right.createdAt, options: .literal) == .orderedAscending
            }
            return left.revisionId.compare(right.revisionId, options: .literal) == .orderedAscending
        }
        var seen = Set<String>()
        var result: [NativeStorageRevisionAllocation] = []
        for manifest in own {
            var bytes = 0
            for hash in Set(manifest.files.map(\.sha256)).sorted() where seen.insert(hash).inserted {
                let shares: [String: Int]
                if let observed = objectShares[hash] { shares = observed }
                else {
                    let apps = sharers[hash, default: []].sorted()
                    let objectPath = objects.root.path + "/" + String(hash.prefix(2)) + "/" + hash
                    let allocated = try NativeStorageBlockMeasurement.allocatedBytes(atPath: objectPath)
                    var measured: [String: Int] = [:]
                    for (index, app) in apps.enumerated() {
                        measured[app] = allocated / apps.count + (index < allocated % apps.count ? 1 : 0)
                    }
                    shares = measured
                    objectShares[hash] = measured
                }
                bytes += shares[identity, default: 0]
            }
            let checkoutPath = checkouts.root.path + "/" + appId + "/" + projectId + "/" + manifest.revisionId
            if FileManager.default.fileExists(atPath: checkoutPath + "/content") {
                let record = Self.checkoutReceiptCache.read(checkoutPath + "/checkout.json")
                // A missing record is not evidence that clonefile succeeded.
                if record?.cloned != true {
                    bytes += try allocatedTreeBytes(URL(fileURLWithPath: checkoutPath + "/content", isDirectory: true))
                }
            }
            result.append(.init(revisionId: manifest.revisionId, allocatedBytes: bytes))
        }
        allocations[identity] = result.sorted { $0.revisionId < $1.revisionId }
        }
        return allocations
    }

    nonisolated func globalAllocatedBytes() throws -> Int {
        var total = 0
        for hash in try objects.allObjectHashes() { total += try NativeStorageBlockMeasurement.allocatedBytes(atPath: objects.path(forSHA256: hash).path) }
        for (app, project, manifest) in try liveManifestInventory() {
            let checkout = checkouts.contentRoot(appId: app, projectId: project, revisionId: manifest.revisionId)
            guard FileManager.default.fileExists(atPath: checkout.path) else { continue }
            let record = (try? Data(contentsOf: checkout.deletingLastPathComponent().appendingPathComponent("checkout.json")))
                .flatMap { try? JSONDecoder().decode(NativeVersionCheckoutRecord.self, from: $0) }
            if record?.cloned != true { total += try allocatedTreeBytes(checkout) }
        }
        return total
    }

    private nonisolated func allocatedTreeBytes(_ root: URL) throws -> Int {
        var total = 0
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return 0 }
        while let name = walker.nextObject() as? String {
            var info = stat()
            let path = root.path + "/" + name
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else {
                throw NativeVersionCheckoutError.verificationFailed("unsafe allocation tree")
            }
            if info.st_mode & S_IFMT == S_IFREG { total += Int(info.st_blocks) * 512 }
        }
        return total
    }

    /// Each object's reclaim promise belongs to the last optional reference in
    /// global oldest-first order. Every prefix selected by the global planner
    /// therefore promises only objects that prefix can actually free.
    nonisolated func prunableAllocation(appId: String, projectId: String) throws -> [(revisionId: String, allocatedBytes: Int, createdAt: String)] {
        let all = try liveManifestInventory()
        var protected = Set<String>()
        for project in try manifests.allProjects() {
            let own = all.filter { $0.0 == project.appId && $0.1 == project.projectId }.map { $0.2 }
            let pointer = state.readActive(appId: project.appId, projectId: project.projectId)
            let pinURL = state.directory(appId: project.appId, projectId: project.projectId).appendingPathComponent("pinned-revisions.json")
            let pins = (try? Data(contentsOf: pinURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["revisionIds"] as? [String] ?? []
            let roles = NativeStorageRetentionPolicy.retainedSet(
                revisions: own.map { .init(revisionId: $0.revisionId, baseRevisionId: $0.baseRevisionId, createdAt: $0.createdAt) },
                currentRevisionId: pointer?.currentRevisionId, fallbackRevisionId: pointer?.fallbackRevisionId,
                pinnedRevisionIds: pins)
            for id in roles.revisionIds { protected.insert("\(project.appId)/\(project.projectId)/\(id)") }
        }
        let ordered = all.sorted { lhs, rhs in
            if lhs.2.createdAt != rhs.2.createdAt { return lhs.2.createdAt < rhs.2.createdAt }
            if lhs.2.revisionId != rhs.2.revisionId { return lhs.2.revisionId < rhs.2.revisionId }
            return lhs.0 != rhs.0 ? lhs.0 < rhs.0 : lhs.1 < rhs.1
        }
        var lastReference: [String: String] = [:]
        var protectedHashes = Set<String>()
        for (app, project, manifest) in ordered {
            let key = "\(app)/\(project)/\(manifest.revisionId)"
            for hash in Set(manifest.files.map(\.sha256)) {
                lastReference[hash] = key
                if protected.contains(key) { protectedHashes.insert(hash) }
            }
        }
        var bytes: [String: Int] = [:]
        for (hash, key) in lastReference where !protectedHashes.contains(hash) {
            bytes[key, default: 0] += try NativeStorageBlockMeasurement.allocatedBytes(atPath: objects.path(forSHA256: hash).path)
        }
        return ordered.compactMap { app, project, manifest in
            let key = "\(app)/\(project)/\(manifest.revisionId)"
            guard app == appId, project == projectId, !protected.contains(key) else { return nil }
            return (manifest.revisionId, bytes[key, default: 0], manifest.createdAt)
        }
    }

    func freeVersion(appId: String, projectId: String, revisionId: String) async throws -> NativeVersionFreeResult {
        try await withExclusiveAccess {
            try await self.freeVersionImpl(appId: appId, projectId: projectId, revisionId: revisionId)
        }
    }

    private func freeVersionImpl(appId: String, projectId: String, revisionId: String) async throws -> NativeVersionFreeResult {
        // Reclaim is infrequent maintenance. Prove counts from manifests even
        // if an external edit failed to leave a dirty marker.
        try await rebuildAllRefsImpl()
        try await refs.markDirty()
        let result = try await gc.free(appId: appId, projectId: projectId, revisionId: revisionId)
        try checkouts.delete(appId: appId, projectId: projectId, revisionId: revisionId)
        await refs.clearDirty()
        return result
    }

}
