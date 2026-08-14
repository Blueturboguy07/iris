//
//  PatchQueue.swift
//  leanring-buddy
//
//  Local fixes against a moving upstream, without divergence hell. A fix
//  Iris applied is not "the diff currently on disk" — it is a NAMED patch
//  keyed to its recipe and signature, recorded here the moment it lands, so
//  that when the app updates the queue can be popped, upstream pulled, and
//  every named patch replayed one at a time. A conflict then belongs to ONE
//  patch, not to an opaque merge — quilt's model, because forty years of
//  distro packaging found nothing better.
//
//  Two rules the replay honors, both paid for elsewhere first:
//    - a clean textual merge proves nothing; the verification gate re-runs
//      after every replay, unconditionally.
//    - when upstream lands its own version of a patch, the local one is
//      DROPPED and the supersession reported to the pool — fork hygiene and
//      a high-value signal ("stop proposing this, it's upstream now").
//

import Foundation

struct QueuedPatch: Codable, Equatable, Sendable {
    let recipeId: String
    let signatureId: String
    let appSlug: String
    /// The branch the fix lives on in the clone.
    let branchName: String
    /// The unified diff as applied, for replay after upstream moves.
    let patchText: String
    /// The clone commit the patch was applied on top of.
    let baseCommit: String?
    let appliedAt: Date
}

@MainActor
final class PatchQueue {

    private let queueDirectoryURL: URL

    init(baseDirectoryURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Iris/patch-queue")
    ) {
        queueDirectoryURL = baseDirectoryURL
        try? FileManager.default.createDirectory(
            at: queueDirectoryURL, withIntermediateDirectories: true
        )
    }

    // MARK: - Recording

    func record(_ patch: QueuedPatch) {
        guard let data = try? JSONEncoder().encode(patch) else { return }
        try? data.write(to: fileURL(appSlug: patch.appSlug, recipeId: patch.recipeId))
        irisTrace("maintain: patch queued for \(patch.appSlug) (recipe \(patch.recipeId))")
    }

    func patches(forAppSlug appSlug: String) -> [QueuedPatch] {
        let directory = queueDirectoryURL.appendingPathComponent(appSlug)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .compactMap { url -> QueuedPatch? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(QueuedPatch.self, from: data)
            }
            .sorted { $0.appliedAt < $1.appliedAt }
    }

    func remove(appSlug: String, recipeId: String) {
        try? FileManager.default.removeItem(at: fileURL(appSlug: appSlug, recipeId: recipeId))
    }

    // MARK: - Replay across an upstream update

    enum PatchReplayDisposition: Sendable {
        /// Re-applied on the new base; the caller re-runs verification.
        case replayed
        /// Upstream now contains the change — dropped, supersession filed.
        case supersededByUpstream
        /// Three-way replay conflicted. The patch stays queued, unapplied;
        /// the caller surfaces it.
        case conflicted
    }

    /// Replays every queued patch for one app after its clone moved to a new
    /// upstream commit. The caller has already popped the working tree back
    /// to clean upstream state; this walks the queue oldest-first.
    func replayAll(
        forAppSlug appSlug: String,
        runner: MaintainShellRunner
    ) async -> [(patch: QueuedPatch, disposition: PatchReplayDisposition)] {
        var results: [(QueuedPatch, PatchReplayDisposition)] = []
        for patch in patches(forAppSlug: appSlug) {
            let disposition = await replay(patch: patch, runner: runner)
            results.append((patch, disposition))
        }
        return results
    }

    private func replay(
        patch: QueuedPatch, runner: MaintainShellRunner
    ) async -> PatchReplayDisposition {
        let patchFileName = ".iris-replay-\(patch.recipeId).patch"
        let patchFilePath = (runner.repoRootPath as NSString).appendingPathComponent(patchFileName)
        defer { try? FileManager.default.removeItem(atPath: patchFilePath) }
        guard (try? patch.patchText.write(toFile: patchFilePath, atomically: true, encoding: .utf8)) != nil else {
            return .conflicted
        }

        // Already upstream? `--reverse --check` succeeding means the tree
        // ALREADY CONTAINS the patch — upstream landed an equivalent change.
        let reverseCheck = try? await runner.run(
            "git apply --reverse --check \(patchFileName)", deadline: 60
        )
        if reverseCheck?.succeeded == true {
            remove(appSlug: patch.appSlug, recipeId: patch.recipeId)
            irisTrace("maintain: patch \(patch.recipeId) superseded by upstream — dropped")
            return .supersededByUpstream
        }

        let applied = try? await runner.run("git apply --3way \(patchFileName)", deadline: 60)
        if applied?.succeeded == true {
            return .replayed
        }
        // Leave conflict markers out of the tree: a conflicted 3way can
        // half-land; reset so the tree stays honestly upstream.
        _ = try? await runner.run("git checkout -- . && git clean -fd --quiet", deadline: 120)
        irisTrace("maintain: patch \(patch.recipeId) conflicted on replay — kept queued, tree reset")
        return .conflicted
    }

    private func fileURL(appSlug: String, recipeId: String) -> URL {
        let directory = queueDirectoryURL.appendingPathComponent(appSlug)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(recipeId).json")
    }
}
