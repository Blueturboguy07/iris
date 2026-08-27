//
//  MaintainFixCommit.swift
//  leanring-buddy
//
//  The one place a verified working tree becomes a commit on a fresh branch.
//
//  This block used to live near-verbatim in TWO places — the tail of
//  RecipeReplayEngine.applyVerifyAndCommit (a replayed pooled diff) and the
//  tail of MaintainTierCFixer.attemptFix (a novel BYO fix). Adding a third
//  caller (the user-initiated on-demand editor) would have made it three
//  copies of the same branch-naming + commit-script + trailer-block logic,
//  each free to drift. So it is factored here first, generalized over the two
//  things that legitimately differ between callers:
//
//    - the CHANGE ID (a crash signature for the incident path; a synthesized
//      request hash for on-demand) — load-bearing in the branch name and,
//      for callers that queue, the PatchQueue key.
//    - the TRAILER VOCABULARY — a crash fix, a replayed recipe, and an
//      on-demand edit each make different, HONEST claims. The structured
//      trailer block itself (a subject, a blank line, then `Key: value`
//      lines, and NO `Co-Authored-By`) is kept identical on purpose: AGPL
//      §5(a) "modified" notices and the founder-review packet's mechanical
//      checks both read it.
//
//  The mechanics — the date stamp, the `git checkout -b … || git checkout …`
//  branch create-or-switch, the single-quote-escaped `git commit` — are the
//  same for everyone and live only here.
//

import Foundation

/// The commit-and-branch identity for one applied change. The caller fills in
/// what differs between the incident path and on-demand; the mechanics come
/// from `MaintainFixCommit`.
struct MaintainFixCommitPlan: Sendable {
    /// The branch is `"<branchPrefix><changeId first 12 chars>-<yyyyMMdd>"`.
    /// The incident/replay callers use `"iris/fix-"`; on-demand uses
    /// `"iris/edit-"`.
    let branchPrefix: String
    /// The stable id this change is keyed by — a crash signature for the
    /// incident path, a synthesized request hash for on-demand. Truncated to
    /// its first 12 characters in the branch name.
    let changeId: String
    /// The commit subject (its first line).
    let subject: String
    /// The structured trailer lines, in order, WITHOUT the blank line that
    /// separates them from the subject (this type inserts that). Every caller
    /// keeps a `Modified-by:` line here; none use `Co-Authored-By` — the
    /// block is a machine-read provenance record, not a co-authorship claim.
    let trailerLines: [String]
}

@MainActor
enum MaintainFixCommit {

    /// Commits the ALREADY-VERIFIED working tree onto a fresh change-keyed
    /// branch and returns that branch's name — or NIL when no commit was
    /// actually created. The caller has already run the verification gate and
    /// (for callers that queue) owns recording the patch afterward using the
    /// returned branch name.
    ///
    /// It used to return the branch name unconditionally, having thrown the
    /// commit script's result away with `_ = try?`. A branch name is what every
    /// caller treats as proof the change landed — it goes into the reader's
    /// "committed on …" card, into the patch queue, into the fork backup — so a
    /// checkout that failed, a commit that found nothing staged, or a repo with
    /// no `user.email` configured all produced a confident report of a commit
    /// that does not exist. Whether the commit happened is checked the only way
    /// it can be: HEAD is read before and after, and if it did not move, it did
    /// not happen.
    ///
    /// Checking HEAD moved is necessary but was NOT sufficient. The checkout and
    /// the commit used to be one `;`-joined script, so if BOTH `git checkout -b`
    /// and the fallback `git checkout` failed, the `git commit` after them still
    /// ran — on whatever branch the clone happened to be on. HEAD moved, so the
    /// old guard passed, and this returned a branch name for a commit sitting on
    /// `main`. Every consumer of that name is then wrong in a different way: the
    /// reader is shown a branch that does not exist, the patch queue is keyed by
    /// it, and the fork backup pushes it — pushing nothing, or worse, pushing a
    /// commit the reader never agreed to put on their default branch.
    ///
    /// So the checkout is now its own step and is CONFIRMED before anything is
    /// committed. `git symbolic-ref --short HEAD` is the read (not `rev-parse
    /// --abbrev-ref`, which cannot name an unborn branch and would fail on a
    /// first commit); a detached HEAD has no symbolic ref at all, so it refuses
    /// there too. If the branch is not the one asked for, nothing is committed
    /// and the tree is left exactly as the caller handed it over — which is what
    /// makes the caller's revert-and-report-honestly path correct.
    static func commitOnBranch(
        plan: MaintainFixCommitPlan,
        runner: MaintainShellRunner
    ) async -> String? {
        let branchName = branchName(prefix: plan.branchPrefix, changeId: plan.changeId)
        // Subject, a blank line, then the trailer block — the exact shape the
        // provenance and founder-review checks parse.
        let commitMessage = ([plan.subject, ""] + plan.trailerLines).joined(separator: "\n")

        // Step one: get onto the branch, and prove it. Nothing is committed
        // until this holds, so a failed checkout can no longer leak a commit
        // onto whichever branch the clone was already on.
        _ = try? await runner.run(
            "git checkout -b '\(branchName)' 2>/dev/null || git checkout '\(branchName)'",
            deadline: 60
        )
        guard let branchNow = await currentBranchName(runner: runner), branchNow == branchName else {
            irisTrace("maintain: could not get onto \(branchName) — nothing committed")
            return nil
        }

        // Step two: commit, now that where it will land is known.
        let commitScript = "git add -A && git commit -m "
            + "'\(commitMessage.replacingOccurrences(of: "'", with: "'\\''"))' --quiet"

        let headBeforeCommit = await currentHeadCommitHash(runner: runner)
        _ = try? await runner.run(commitScript, deadline: 60)
        let headAfterCommit = await currentHeadCommitHash(runner: runner)

        // An unborn HEAD (a repo with no commits yet) reads as nil on both
        // sides, and nil == nil would look like "did not move" — but a first
        // commit DOES move it, from nil to a hash, so the inequality is the
        // right test in every case including that one.
        guard headAfterCommit != headBeforeCommit, headAfterCommit != nil else {
            irisTrace("maintain: commit on \(branchName) did NOT create a commit — HEAD did not move")
            return nil
        }
        return branchName
    }

    /// The branch HEAD currently points at, or nil when there is none — a
    /// detached HEAD, or a git invocation that failed. `symbolic-ref` is used
    /// rather than `rev-parse --abbrev-ref` because it still names an UNBORN
    /// branch, which is exactly the state a fresh `checkout -b` leaves a repo
    /// with no commits in.
    private static func currentBranchName(runner: MaintainShellRunner) async -> String? {
        guard let result = try? await runner.run("git symbolic-ref --short HEAD", deadline: 30),
              result.succeeded else { return nil }
        let name = result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The current HEAD commit hash, or nil when there is none to read (an
    /// unborn HEAD, or a git invocation that failed outright).
    private static func currentHeadCommitHash(runner: MaintainShellRunner) async -> String? {
        guard let result = try? await runner.run("git rev-parse HEAD", deadline: 30),
              result.succeeded else { return nil }
        let hash = result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    /// The branch name a change lands on. Kept public and pure so a caller
    /// (or a test) can predict the branch without running the commit.
    static func branchName(prefix: String, changeId: String) -> String {
        "\(prefix)\(changeId.prefix(12))-\(compactDateStamp())"
    }

    private static func compactDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
