//
//  IncomingFixReviewer.swift
//  leanring-buddy
//
//  The owner's side of "someone else's machine fixed my app." When a fix PR
//  lands on a repo the connected user owns, their Iris does NOT merge on
//  trust — it re-runs the same verification gate the fix already passed on
//  the stranger's machine, on the owner's own machine, against the owner's
//  own clone, and only then offers to merge. A verification that passed
//  somewhere else is evidence; a verification that passes HERE is proof for
//  this repo.
//
//  This is the concrete meaning of the founder's rule: "if it's someone
//  else's, Iris needs to see that and decide whether to merge the PR." The
//  seeing is `GitHubForkService.incomingFixPullRequests`; the deciding is
//  this file's re-verification; the merge is the owner's tap (or, once
//  trust is earned, automatic — a later decision).
//

import Foundation

/// The verdict on one incoming fix PR after re-verification.
struct IncomingFixReview: Sendable, Equatable {
    let pr: GitHubForkService.IncomingFixPR
    /// True only when the fix rebuilt and passed the full suite on the
    /// owner's machine. A clean merge is never offered without this.
    let reVerifiedHere: Bool
    /// What blocked, when it did — shown to the owner, never auto-merged past.
    let blockedStage: String?
}

@MainActor
final class IncomingFixReviewer {

    private let provenanceStore: InstallProvenanceStore

    init(provenanceStore: InstallProvenanceStore) {
        self.provenanceStore = provenanceStore
    }

    /// Re-verify one incoming fix PR against the owner's local clone. The PR
    /// head is fetched into a detached worktree so the owner's working state
    /// is never touched, the fix's commits are checked out there, and the
    /// three-legged... — no, the PR carries no repro test, so the replay
    /// standard applies: it must rebuild and the FULL suite must stay green
    /// on the owner's machine. Nothing is merged from this file; it only
    /// produces the verdict the owner acts on.
    func review(
        _ pr: GitHubForkService.IncomingFixPR,
        appSlug: String,
        appStack: BreakAppStack
    ) async -> IncomingFixReview {
        guard let record = provenanceStore.provenance(forAppSlug: appSlug),
              let clonePath = record.clonePath,
              let runner = try? MaintainShellRunner(repoRootPath: clonePath) else {
            return IncomingFixReview(pr: pr, reVerifiedHere: false, blockedStage: "no local clone to verify against")
        }

        // Fetch the PR head into a scratch worktree so the owner's own tree
        // and branch are never disturbed. The worktree lives under the repo
        // (the runner's boundary) and is torn down whatever happens.
        let worktreeName = ".iris-review-\(pr.number)"
        let fetchAndAdd = """
        git fetch '\(pr.headRepoCloneURL)' '\(pr.headBranch)' 2>&1 | tail -1; \
        git worktree add --detach '\(worktreeName)' FETCH_HEAD 2>&1 | tail -1
        """
        let added = try? await runner.run(fetchAndAdd, deadline: 120)
        defer {
            Task { [runner] in
                _ = try? await runner.run(
                    "git worktree remove --force '\(worktreeName)' 2>/dev/null || true", deadline: 60
                )
            }
        }
        guard added?.succeeded == true else {
            return IncomingFixReview(pr: pr, reVerifiedHere: false, blockedStage: "could not fetch the PR")
        }

        // Verify inside the worktree, using a runner rooted there so the
        // build/test and the boundary both apply to the fetched code.
        let worktreePath = (clonePath as NSString).appendingPathComponent(worktreeName)
        guard let worktreeRunner = try? MaintainShellRunner(repoRootPath: worktreePath) else {
            return IncomingFixReview(pr: pr, reVerifiedHere: false, blockedStage: "worktree not usable")
        }
        let commands = VerificationCommands.defaults(for: appStack, repoRootPath: worktreePath)
        let outcome = await VerificationHarness.verifyAppliedPatch(
            runner: worktreeRunner, commands: commands, reproCommand: nil
        )
        irisTrace("github: re-verified PR #\(pr.number) here — clean=\(outcome.earnsCleanApply) blocked=\(outcome.blockedStage ?? "none")")
        return IncomingFixReview(
            pr: pr,
            reVerifiedHere: outcome.earnsCleanApply,
            blockedStage: outcome.blockedStage
        )
    }
}
