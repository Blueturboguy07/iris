//
//  FeatureEditAdversarialReviewer.swift
//  leanring-buddy
//
//  The L6 rung of the evidence ladder (feature-engine plan §9, ratified
//  decision 3a): a SEPARATE-context adversarial pass that tries to find what is
//  wrong with a change before it is allowed to claim "independently reviewed".
//
//  This is the antidote to the maker grading its own homework. The agent that
//  authored the edit has every incentive — and, having just reasoned its way to
//  the diff, every cognitive bias — to believe it succeeded. So the review runs
//  in a FRESH context on the SAME bring-your-own provider (decision 3a: same
//  provider, escalate a model tier on disagreement — a second provider was the
//  rejected alternative), seeing ONLY the request, the finished diff, and the
//  evidence log — never the maker's reasoning, never its self-congratulation.
//  A reviewer that inherited the maker's chain of thought would inherit its
//  blind spots; the whole value is the cold, unsympathetic second read.
//
//  This file is PURE Foundation logic: it BUILDS the (system, user) prompt pair
//  for that fresh-context call and PARSES the reply into a verdict. It makes no
//  model call itself — the coordinator owns the transport, exactly as
//  `GuideAutopilotFixProposer` owns its own calls while the shape of the
//  exchange lives in a value type. No network, no UI, no process spawning.
//
//  The verdict is deliberately FAIL-CLOSED: a reply we cannot read as an
//  explicit, issue-free clean pass does NOT earn L6. "Independently reviewed"
//  is a claim about evidence collected, and an unreadable verdict is not
//  evidence of a clean review — it is the absence of one.
//

import Foundation

/// The outcome of the fresh-context adversarial pass, parsed from the
/// reviewer's reply. Only two facts matter to the ladder: did the reviewer find
/// anything DISQUALIFYING (which withholds the L6 rung), and — for the reader's
/// evidence log — what specifically it named. `Equatable` so the parser can be
/// unit-tested against exact expected verdicts.
nonisolated struct AdversarialVerdict: Sendable, Equatable {
    /// True when the change must NOT be credited with a clean independent
    /// review — either the reviewer named a disqualifying problem, or its reply
    /// was not a legible, issue-free clean pass. The L6 rung is earned only when
    /// this is false.
    let isDisqualifying: Bool

    /// The disqualifying problems the reviewer named, verbatim (one per
    /// `ISSUE:` line), for the reader-facing report and the evidence log. Empty
    /// on a clean pass; may also be empty on a fail-closed unreadable reply, in
    /// which case a single explanatory line is supplied so the reason a change
    /// was withheld is never blank.
    let issues: [String]
}

/// Builds the fresh-context reviewer interaction and reads its verdict. Pure
/// value logic; the model call that sits between `reviewPrompt` and `parse`
/// belongs to the coordinator.
nonisolated enum FeatureEditAdversarialReviewer {

    // MARK: - The structured reply protocol

    // The reviewer is told to answer in a fixed, machine-checkable shape so the
    // verdict cannot be lost in prose. These four markers are the WHOLE
    // contract, referenced by BOTH the prompt and the parser below so the two
    // can never drift out of agreement — a common failure when a prompt says
    // "reply CLEAN" and a parser quietly looks for "PASS".

    /// Prefix for each disqualifying problem the reviewer found. One issue per
    /// line. Absent entirely on a clean pass.
    static let issueLineMarker = "ISSUE:"

    /// Prefix for the reviewer's single final verdict line.
    static let verdictLineMarker = "VERDICT:"

    /// The verdict token that clears the change for L6 — nothing disqualifying.
    static let cleanVerdictToken = "CLEAN"

    /// The verdict token that withholds L6 — a disqualifying problem was found.
    static let disqualifyingVerdictToken = "DISQUALIFYING"

    // MARK: - Prompt construction

    /// Build the (system, user) prompt pair for the fresh-context adversarial
    /// review. The system prompt fixes the adversarial role and the required
    /// reply shape; the user prompt carries only the reviewable material — the
    /// request, whether it was a bug fix or a feature, the finished unified
    /// diff, and the evidence log the maker collected.
    ///
    /// The reviewer is deliberately given NO access to the maker's reasoning or
    /// to the wider repo: it judges what the diff actually does against what the
    /// request actually asked, and it flags — rather than guesses past — a diff
    /// too small to judge. This is the "separate maker from checker" property
    /// (§9) expressed as an information boundary, not just a fresh context.
    ///
    /// - Parameters:
    ///   - request: The reader's own words for what they wanted changed, so the
    ///     reviewer checks the diff against the ACTUAL ask, not a paraphrase.
    ///   - kind: Bug fix vs. feature — it changes what "done" means (a bug fix
    ///     must actually stop the reported failure; a feature must actually add
    ///     the requested behavior without regressing what was there).
    ///   - unifiedDiff: The finished, committed-shape diff under review.
    ///   - evidenceLog: The rows the verification ladder already collected
    ///     ("Build: exit 0", "Tests: 47/47", …) so the reviewer can probe
    ///     whether that evidence actually supports the change or was gamed
    ///     (a tautological test, a swallowed error, a re-recorded snapshot).
    static func reviewPrompt(
        request: String,
        kind: OnDemandEditKind,
        unifiedDiff: String,
        evidenceLog: [String]
    ) -> (system: String, user: String) {
        let system = adversarialReviewerSystemPrompt(forKind: kind)
        let user = reviewableMaterial(
            request: request,
            kind: kind,
            unifiedDiff: unifiedDiff,
            evidenceLog: evidenceLog
        )
        return (system: system, user: user)
    }

    /// The system prompt: it establishes the adversarial stance, the concrete
    /// checklist the reviewer must work through, and the exact reply shape the
    /// parser expects. The wording is intentionally unsympathetic — a reviewer
    /// primed to "confirm the good work" would rubber-stamp; one told its job is
    /// to find the flaw does the work L6 is there to buy.
    private static func adversarialReviewerSystemPrompt(forKind kind: OnDemandEditKind) -> String {
        let requestNoun = kindNoun(for: kind)
        let doneMeaning: String
        switch kind {
        case .bugFix:
            // "Done" for a bug fix is the reported failure actually stopping —
            // not merely code that looks related to the bug.
            doneMeaning = "the reported problem is actually fixed by this diff (not merely touched near)"
        case .feature:
            // "Done" for a feature is the requested behavior actually present
            // and reachable — and nothing that worked before now broken.
            doneMeaning = "the requested behavior is actually implemented and reachable, and nothing that worked before is now broken"
        }

        // The checklist folds in the §8 runtime-shape dimensions the adversarial
        // pass is specifically supposed to probe (concurrency/idempotency,
        // persisted state, security/tenancy, rollback safety) alongside the §9
        // anti-gaming cheat signatures — because those are exactly the failures
        // a self-satisfied maker is least likely to have caught in itself.
        return """
        You are an INDEPENDENT adversarial code reviewer. You did NOT write the \
        change under review and you have no stake in it passing. A different \
        model, in a separate session, made this \(requestNoun); your job is to \
        find what is WRONG with it before it is allowed to be called \
        "independently reviewed". Assume it may be subtly broken, incomplete, or \
        gaming its own tests. Praise is worthless here — only concrete problems \
        are.

        Work through this checklist against the diff you are given, in order:

        1. Requirements. List the specific requirements implied by the request \
        in your own words — everything the change must do to be correct.

        2. Coverage. Check EACH requirement against the actual diff. Does the \
        code truly satisfy it, or only appear to? The bar is: \(doneMeaning).

        3. What could break. Name concretely what this change could break: \
        regressions to existing behavior; unhandled inputs, errors, or edge \
        cases; concurrency / re-run (idempotency) hazards; unsafe or non-atomic \
        writes to persisted state; missing tenant/authorization scoping or \
        unparameterized queries; anything that is hard to roll back.

        4. Evidence integrity. You are given the maker's own evidence log. Decide \
        whether it actually supports the change or was gamed. Treat as \
        DISQUALIFYING any sign of a tautological or assertion-free test, a \
        disabled/skipped test, a broadened catch that swallows errors, a \
        re-recorded snapshot, a test that mocks the very thing it claims to \
        verify, or a change that touches build/test configuration to make a \
        red result look green.

        Judge ONLY what the diff and evidence actually show. If the diff is too \
        small to prove the requirement is met, that INSUFFICIENCY is itself a \
        disqualifying issue — say so rather than assuming unseen code makes it \
        work.

        Then reply in EXACTLY this shape and nothing after it:

        - First, your analysis for steps 1–4 as free text (this is not parsed, \
        so write it however is clearest).
        - Then, for every disqualifying problem you found, one line beginning \
        with "\(issueLineMarker)" followed by a one-sentence statement of that \
        single problem. Write NO such line if you found none.
        - Finally, one line that is exactly "\(verdictLineMarker) \
        \(cleanVerdictToken)" if the change has NOTHING disqualifying, or \
        exactly "\(verdictLineMarker) \(disqualifyingVerdictToken)" if it does. \
        If you wrote any \(issueLineMarker) line, the verdict MUST be \
        \(disqualifyingVerdictToken).
        """
    }

    /// The user prompt: the material to be reviewed, assembled deterministically
    /// so the same change always produces the same review request (which keeps
    /// the fresh-context reviewer reproducible for testing and auditing).
    private static func reviewableMaterial(
        request: String,
        kind: OnDemandEditKind,
        unifiedDiff: String,
        evidenceLog: [String]
    ) -> String {
        // An empty evidence log is stated plainly rather than rendered as a
        // blank section — "nothing was collected" is itself a reviewable fact
        // (it caps how high the change could honestly climb).
        let evidenceSection: String
        if evidenceLog.isEmpty {
            evidenceSection = "(no verification evidence was collected)"
        } else {
            evidenceSection = evidenceLog
                .map { "- \($0)" }
                .joined(separator: "\n")
        }

        return """
        The change under review is a \(kindNoun(for: kind)).

        What the user asked for, in their own words:
        \(request)

        The finished change, as a unified diff:
        ```diff
        \(unifiedDiff)
        ```

        The evidence the maker collected while verifying it:
        \(evidenceSection)

        Review it against your checklist and give your verdict.
        """
    }

    /// Reader-facing noun for the kind, used in both prompts so the reviewer is
    /// never told a feature is a "fix" or vice versa (which would misdirect what
    /// it checks for).
    private static func kindNoun(for kind: OnDemandEditKind) -> String {
        switch kind {
        case .bugFix:
            return "bug fix"
        case .feature:
            return "feature"
        }
    }

    // MARK: - Reply parsing

    /// Parse the reviewer's reply into a verdict. The rule is deliberately
    /// asymmetric and FAIL-CLOSED: a change is cleared for L6 ONLY when the
    /// reply is an explicit clean verdict with NO issues listed. Every other
    /// shape — an explicit disqualifying verdict, any issue lines at all (even
    /// under a mistaken "clean" verdict), or a verdict we cannot read — withholds
    /// the rung. "Independently reviewed" must mean a review that legibly found
    /// nothing, not the absence of a legible objection.
    static func parse(reply: String) -> AdversarialVerdict {
        var collectedIssues: [String] = []
        // nil until a VERDICT: line is seen at all; distinguishes "the reviewer
        // said nothing disqualifying" from "the reviewer never rendered a
        // verdict we could read" — different fail-closed reasons.
        var lastReadableVerdictWasClean: Bool? = nil

        for rawLine in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let normalizedLine = stripLeadingBulletMarkers(
                from: String(rawLine).trimmingCharacters(in: .whitespaces)
            )

            if let issueText = textAfterMarker(issueLineMarker, in: normalizedLine) {
                let trimmedIssue = issueText.trimmingCharacters(in: .whitespaces)
                if !trimmedIssue.isEmpty {
                    collectedIssues.append(trimmedIssue)
                }
                continue
            }

            if let verdictText = textAfterMarker(verdictLineMarker, in: normalizedLine) {
                // The last verdict line wins — if a reply somehow carries more
                // than one, the reviewer's final word is authoritative.
                if let cleanReading = readVerdictToken(verdictText) {
                    lastReadableVerdictWasClean = cleanReading
                }
            }
        }

        // A clean pass requires BOTH an explicit clean verdict AND zero listed
        // issues. Issues under a "clean" verdict are a self-contradiction we
        // resolve conservatively: the named problems win over the summary word.
        let reviewIsCleanlyCleared = (lastReadableVerdictWasClean == true) && collectedIssues.isEmpty
        if reviewIsCleanlyCleared {
            return AdversarialVerdict(isDisqualifying: false, issues: [])
        }

        // Withheld. If the reviewer named specific problems, those ARE the
        // reason. If it did not — an explicit disqualifying verdict with no
        // enumerated issue, or no readable verdict at all — supply one honest
        // line so the withholding reason is never blank for the reader.
        if collectedIssues.isEmpty {
            let fallbackReason: String
            if lastReadableVerdictWasClean == nil {
                fallbackReason = "The adversarial reviewer did not return a readable verdict; treating the change as not independently cleared."
            } else {
                fallbackReason = "The adversarial reviewer returned a disqualifying verdict without naming a specific issue."
            }
            return AdversarialVerdict(isDisqualifying: true, issues: [fallbackReason])
        }
        return AdversarialVerdict(isDisqualifying: true, issues: collectedIssues)
    }

    // MARK: - Parsing helpers

    /// If `line` begins with `marker` (case-insensitively), return the remainder
    /// after the marker; otherwise nil. Case-insensitive so a reviewer that
    /// writes "Verdict:" or "issue:" is still read correctly.
    private static func textAfterMarker(_ marker: String, in line: String) -> String? {
        guard line.count >= marker.count else { return nil }
        let leadingRun = String(line.prefix(marker.count))
        guard leadingRun.caseInsensitiveCompare(marker) == .orderedSame else { return nil }
        return String(line.dropFirst(marker.count))
    }

    /// Read a verdict token into a clean/disqualifying boolean, or nil if it is
    /// neither. Clean phrases are checked FIRST on purpose: a hedge like
    /// "nothing disqualifying" contains the substring "disqualif", so testing
    /// for disqualification first would misread a clean verdict as a failing
    /// one. The tolerant vocabulary is a safety net; the prompt asks for exactly
    /// CLEAN or DISQUALIFYING.
    private static func readVerdictToken(_ verdictText: String) -> Bool? {
        let normalized = verdictText.uppercased().trimmingCharacters(in: .whitespaces)

        let cleanSignals = ["CLEAN", "PASS", "APPROV", "NO ISSUE", "NOTHING DISQUALIF", "NOT DISQUALIF"]
        if cleanSignals.contains(where: { normalized.contains($0) }) {
            return true
        }

        let disqualifyingSignals = ["DISQUALIF", "FAIL", "REJECT", "BLOCK"]
        if disqualifyingSignals.contains(where: { normalized.contains($0) }) {
            return false
        }

        // Unrecognized — treated by the caller as "no readable verdict" so the
        // fail-closed floor applies.
        return nil
    }

    /// Strip a leading Markdown/list bullet ("- ", "* ", "• ") so a reviewer
    /// that formats its issue or verdict lines as bullets is still parsed. Only
    /// ONE leading bullet is removed — the marker check that follows keys on the
    /// real prefix.
    private static func stripLeadingBulletMarkers(from line: String) -> String {
        for bulletPrefix in ["- ", "* ", "• "] {
            if line.hasPrefix(bulletPrefix) {
                return String(line.dropFirst(bulletPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }
}
