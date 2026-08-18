//
//  MaintainClonePathLock.swift
//  leanring-buddy
//
//  Mutual exclusion over a single clone's working tree.
//
//  Two independent code paths can want to rewrite the SAME source clone: the
//  crash-incident path (a confirmed break → Tier C novel fix) and the new
//  user-initiated on-demand editor. Both strip `.git` before their jailed
//  loop, restore it after, and — on any failure — run
//  `git checkout -- . && git clean -fd` to get back to a clean tree. If they
//  ever run at once on the same repo, those two `.git` strips, the two
//  reverts, and the two branch checkouts race and corrupt the working tree or
//  silently lose the in-flight edit. The on-demand path also deliberately
//  drops maintain mode's ask throttle (it exists to stop AI nagging, which is
//  wrong for a user-initiated act), so nothing else serializes these two.
//
//  This is that missing serialization: a per-clonePath latch, held for the
//  whole lifetime of one derivation and released when it finishes. It is not a
//  kernel lock — it is a set of in-use paths guarded on the main actor, which
//  is a correct mutex here because acquisition (check-then-insert) has no
//  `await` between the check and the insert, so no second task can interleave.
//
//  Both paths MUST canonicalize their clone path through this type's key so
//  that the incident path's raw `record.clonePath` and the on-demand path's
//  symlink-resolved path map to the same latch.
//

import Foundation

@MainActor
final class MaintainClonePathLock {

    /// The one lock every maintain-mode derivation shares. Injectable in
    /// tests, but production wiring uses this single instance so the incident
    /// path and the on-demand path actually exclude each other.
    static let shared = MaintainClonePathLock()

    /// Canonical clone path → a short human label naming who holds it, purely
    /// so a refusal can say *what* is already working on the app.
    private var ownerByCanonicalClonePath: [String: String] = [:]

    /// Try to take the latch for `clonePath`. Returns true and records `owner`
    /// when the path was free; returns false (taking nothing) when another
    /// derivation already holds it. Non-blocking on purpose: the caller turns
    /// a false into an honest "something else is already editing this" refusal
    /// rather than queueing behind a potentially long build.
    func tryAcquire(clonePath: String, owner: String) -> Bool {
        let key = Self.canonicalKey(forClonePath: clonePath)
        guard ownerByCanonicalClonePath[key] == nil else { return false }
        ownerByCanonicalClonePath[key] = owner
        return true
    }

    /// Release the latch. Safe to call even when the path was never held (a
    /// double release, or a release after a failed acquire) — it just no-ops.
    func release(clonePath: String) {
        ownerByCanonicalClonePath.removeValue(forKey: Self.canonicalKey(forClonePath: clonePath))
    }

    /// Who currently holds the latch for `clonePath`, or nil when it is free —
    /// for a refusal message that names the current holder.
    func currentOwner(ofClonePath clonePath: String) -> String? {
        ownerByCanonicalClonePath[Self.canonicalKey(forClonePath: clonePath)]
    }

    /// The canonical key both paths agree on: symlinks resolved and the path
    /// standardized, matching `GitInspectionService.allowedRepositoryPath`'s
    /// own resolution so `~/repo` and its symlink-resolved twin latch the same
    /// entry.
    private static func canonicalKey(forClonePath clonePath: String) -> String {
        URL(fileURLWithPath: clonePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
