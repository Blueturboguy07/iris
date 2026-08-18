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
    /// branch and returns that branch's name. The caller has already run the
    /// verification gate and (for callers that queue) owns recording the
    /// patch afterward using the returned branch name.
    static func commitOnBranch(
        plan: MaintainFixCommitPlan,
        runner: MaintainShellRunner
    ) async -> String {
        let branchName = branchName(prefix: plan.branchPrefix, changeId: plan.changeId)
        // Subject, a blank line, then the trailer block — the exact shape the
        // provenance and founder-review checks parse.
        let commitMessage = ([plan.subject, ""] + plan.trailerLines).joined(separator: "\n")
        let commitScript = "git checkout -b '\(branchName)' 2>/dev/null || git checkout '\(branchName)'; "
            + "git add -A && git commit -m '\(commitMessage.replacingOccurrences(of: "'", with: "'\\''"))' --quiet"
        _ = try? await runner.run(commitScript, deadline: 60)
        return branchName
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
