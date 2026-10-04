import Foundation

/// Garbage collection, retention and measurement (SPEC section 2.5). Free
/// only ever removes objects whose reference count reaches zero; a manifest
/// row survives as a tombstone-then-bare-row so the Features page can still
/// say "Not on this iPhone" (section 1.1) after its objects are gone.
public struct NativeVersionFreeResult: Equatable, Sendable {
    public let revisionId: String
    public let bytesReclaimed: Int // st_blocks of objects that reached zero
}

public struct NativeVersionReclaimCandidate: Sendable {
    public let appId: String
    public let projectId: String
    public let revisionId: String
    public let createdAt: String // ISO, ordering key (never the phone clock)
}

public enum NativeVersionGCError: Error, Equatable, Sendable {
    case manifestMissing(String)
}

public struct NativeVersionGC: Sendable {
    private let objects: NativeObjectStore
    private let manifests: NativeVersionManifestStore
    private let refs: NativeVersionRefs

    public init(objects: NativeObjectStore, manifests: NativeVersionManifestStore, refs: NativeVersionRefs) {
        self.objects = objects
        self.manifests = manifests
        self.refs = refs
    }

    /// Frees one version's objects: tombstone its manifest, recompute refs,
    /// delete its unreferenced objects, then finish the history row.
    /// Never call this on a retained role (current, fallback, pending,
    /// pinned), the caller (the store facade / MV2's adapter) is
    /// responsible for excluding those before this runs.
    @discardableResult
    public func free(appId: String, projectId: String, revisionId: String) async throws -> NativeVersionFreeResult {
        guard manifests.exists(appId: appId, projectId: projectId, revisionId: revisionId)
                || manifests.isTombstoned(appId: appId, projectId: projectId, revisionId: revisionId) else {
            throw NativeVersionGCError.manifestMissing(revisionId)
        }
        try manifests.tombstone(appId: appId, projectId: projectId, revisionId: revisionId)
        let tombstones = try manifests.tombstones(appId: appId, projectId: projectId)
            .filter { $0.revisionId == revisionId }
            .map { (appId, projectId, $0) }
        guard let result = try await finishRemovals(tombstones).first else {
            throw NativeVersionGCError.manifestMissing(revisionId)
        }
        return result
    }

    /// Called with the root writer held, even when gc/dirty is absent. A
    /// crash may leave counts unchanged, partly decremented, or rebuilt.
    @discardableResult
    func recoverTombstones() async throws -> [NativeVersionFreeResult] {
        var tombstones: [(String, String, NativeVersionManifest)] = []
        for project in try manifests.allProjects() {
            tombstones.append(contentsOf: try manifests.tombstones(appId: project.appId, projectId: project.projectId)
                .map { (project.appId, project.projectId, $0) })
        }
        return try await finishRemovals(tombstones)
    }

    private func finishRemovals(_ tombstones: [(String, String, NativeVersionManifest)]) async throws -> [NativeVersionFreeResult] {
        guard !tombstones.isEmpty else { return [] }
        var live: [NativeVersionManifest] = []
        for project in try manifests.allProjects() {
            live.append(contentsOf: try manifests.list(appId: project.appId, projectId: project.projectId))
        }
        let marked = Set(live.flatMap { $0.files.map(\.sha256) })
        try await refs.markDirty()
        try await refs.rebuild(from: live, bytesForObject: { try objects.allocatedBytes(sha256: $0) })

        var results: [NativeVersionFreeResult] = []
        for (appId, projectId, manifest) in tombstones {
            var bytesReclaimed = 0
            // Only this removal's hashes bypass the general sweep's age
            // guard. Deduping and marking by hash preserves shared objects,
            // regardless of any interrupted refcount decrement.
            for sha in Set(manifest.files.map(\.sha256)).subtracting(marked) {
                bytesReclaimed += (try? objects.allocatedBytes(sha256: sha)) ?? 0
                try objects.delete(sha256: sha)
            }
            // Keep the marker until all deletes succeed. Retrying missing
            // objects is harmless, including after a crash during recovery.
            try manifests.purgeTombstone(appId: appId, projectId: projectId, revisionId: manifest.revisionId)
            results.append(.init(revisionId: manifest.revisionId, bytesReclaimed: bytesReclaimed))
        }
        return results
    }

    /// Frees candidates oldest `createdAt` first until `targetBytes` have
    /// been reclaimed or candidates run out (SPEC 2.5's "planGlobalReclaim
    /// order"; ordering must never use the phone clock, only manifest
    /// `createdAt`, per mutation check 5 in HANDOFF.md).
    @discardableResult
    public func reclaim(candidates: [NativeVersionReclaimCandidate], targetBytes: Int) async throws -> [NativeVersionFreeResult] {
        let ordered = candidates.sorted { $0.createdAt < $1.createdAt }
        var freed: [NativeVersionFreeResult] = []
        var reclaimed = 0
        for candidate in ordered {
            guard reclaimed < targetBytes else { break }
            let result = try await free(appId: candidate.appId, projectId: candidate.projectId, revisionId: candidate.revisionId)
            freed.append(result)
            reclaimed += result.bytesReclaimed
        }
        return freed
    }

    /// Mark-and-sweep verifier (SPEC 2.5): marks every object any manifest
    /// (tombstoned manifests excluded, they are mid-removal) references
    /// across every app, sweeps `objects/` for anything unreferenced older
    /// than `graceSeconds`, then rebuilds `refs.sqlite` so a drifted count
    /// self-heals. Returns the object hashes actually deleted.
    @discardableResult
    public func markAndSweep(graceSeconds: TimeInterval = 600, fault: NativeVersionFaultInjector = .init()) async throws -> [String] {
        var marked = Set<String>()
        var allManifests: [NativeVersionManifest] = []
        for project in try manifests.allProjects() {
            for manifest in try manifests.list(appId: project.appId, projectId: project.projectId) {
                guard !manifests.isTombstoned(appId: project.appId, projectId: project.projectId, revisionId: manifest.revisionId) else { continue }
                allManifests.append(manifest)
                for file in manifest.files { marked.insert(file.sha256) }
            }
        }

        let onDisk = try objects.allObjectHashes()
        let unreferenced = onDisk.subtracting(marked)
        var swept: [String] = []
        for sha in unreferenced {
            try fault.fire(.gcSweep_midSweep)
            let path = objects.path(forSHA256: sha)
            let attrs = try? FileManager.default.attributesOfItem(atPath: path.path)
            let mtime = attrs?[.modificationDate] as? Date ?? Date()
            guard Date().timeIntervalSince(mtime) > graceSeconds else { continue } // in-flight stage guard
            try objects.delete(sha256: sha)
            swept.append(sha)
        }

        try await refs.rebuild(from: allManifests, bytesForObject: { try objects.allocatedBytes(sha256: $0) })
        return swept
    }
}
