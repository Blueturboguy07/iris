//
//  FeatureEditAdversarialReviewerTests.swift
//  leanring-buddyTests
//
//  The L6 adversarial reviewer (plan §9, decision 3a) is the last gate before a
//  change may claim "independently reviewed", so its two pure pieces must hold
//  exactly: the prompt asks the fresh-context reviewer for the reply shape the
//  parser reads (they must not drift), and the parser is FAIL-CLOSED — it clears
//  a change for L6 ONLY on an explicit, issue-free clean verdict, and withholds
//  the rung on every other shape (disqualifying, contradictory, or unreadable).
//  Pure logic, no processes.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditAdversarialReviewerTests {

    // MARK: - Prompt construction

    @Test func theUserPromptCarriesTheRequestDiffAndEvidence() {
        let (_, user) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "Add a Cmd+Shift+C shortcut that copies the note as Markdown",
            kind: .feature,
            unifiedDiff: "--- a/Editor.swift\n+++ b/Editor.swift\n@@\n+let markdownShortcut = true",
            evidenceLog: ["Build: exit 0", "Tests: 47/47"]
        )
        // The reviewer judges the diff against the ACTUAL ask, so the ask, the
        // diff, and the collected evidence all have to reach it verbatim.
        #expect(user.contains("Add a Cmd+Shift+C shortcut that copies the note as Markdown"))
        #expect(user.contains("markdownShortcut"))
        #expect(user.contains("Build: exit 0"))
        #expect(user.contains("Tests: 47/47"))
        // A feature must be labeled a feature, never a "fix" (it misdirects the
        // check).
        #expect(user.contains("feature"))
    }

    @Test func aBugFixIsLabeledAsABugFixNotAFeature() {
        let (system, user) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "Fix the crash when the note title is empty",
            kind: .bugFix,
            unifiedDiff: "--- a/Note.swift\n+++ b/Note.swift",
            evidenceLog: []
        )
        #expect(user.contains("bug fix"))
        #expect(system.contains("bug fix"))
    }

    @Test func anEmptyEvidenceLogIsStatedPlainlyNotLeftBlank() {
        // "nothing was collected" is itself a reviewable fact — it caps how high
        // the change could honestly climb — so it must be rendered explicitly.
        let (_, user) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "Add a setting",
            kind: .feature,
            unifiedDiff: "--- a/x\n+++ b/x",
            evidenceLog: []
        )
        #expect(user.contains("no verification evidence was collected"))
    }

    @Test func theSystemPromptTeachesExactlyTheMarkersTheParserReads() {
        // Drift guard: the prompt and the parser share ONE contract. If the
        // prompt stopped teaching these exact markers, real replies would parse
        // wrong while every unit test that hand-writes them still passed. So the
        // test asserts the prompt itself carries the parser's markers.
        let (system, _) = FeatureEditAdversarialReviewer.reviewPrompt(
            request: "anything",
            kind: .feature,
            unifiedDiff: "diff",
            evidenceLog: []
        )
        #expect(system.contains(FeatureEditAdversarialReviewer.issueLineMarker))
        #expect(system.contains(FeatureEditAdversarialReviewer.verdictLineMarker))
        #expect(system.contains(FeatureEditAdversarialReviewer.cleanVerdictToken))
        #expect(system.contains(FeatureEditAdversarialReviewer.disqualifyingVerdictToken))
        // And it must frame the reviewer as adversarial/independent, not as a
        // cheerleader for the maker's work.
        #expect(system.contains("INDEPENDENT"))
    }

    // MARK: - Parsing: the clean pass

    @Test func aCleanVerdictWithNoIssuesClearsTheChange() {
        let reply = """
        1. Requirements: add a Markdown-copy shortcut.
        2. Coverage: the diff registers the shortcut and the copy path.
        3. What could break: nothing found — the write is to the pasteboard only.
        4. Evidence integrity: build and suite are green; the new test asserts real output.

        VERDICT: CLEAN
        """
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == false)
        #expect(verdict.issues.isEmpty)
    }

    @Test func aCleanVerdictIsReadCaseInsensitivelyAndThroughABullet() {
        // A reviewer that writes "- verdict: clean" must still clear the change.
        let reply = "- verdict: clean"
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == false)
        #expect(verdict.issues.isEmpty)
    }

    @Test func aHedgedCleanPhraseIsNotMisreadAsDisqualifying() {
        // "nothing disqualifying" contains the substring "disqualif"; the parser
        // checks clean phrasing FIRST so this still reads as a clean pass.
        let reply = "VERDICT: nothing disqualifying"
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == false)
    }

    // MARK: - Parsing: disqualifying

    @Test func aDisqualifyingVerdictWithIssuesIsWithheldAndKeepsEveryIssue() {
        let reply = """
        1. Requirements: the copy must include the note title.
        2. Coverage: the diff copies the body only — the title is dropped.
        3. What could break: users lose the title on every copy.
        4. Evidence integrity: the new test only asserts the body is non-empty.

        ISSUE: The copied Markdown omits the note title the request asked for.
        ISSUE: The new test never asserts the title is present, so it is tautological for this requirement.
        VERDICT: DISQUALIFYING
        """
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues.count == 2)
        #expect(verdict.issues[0] == "The copied Markdown omits the note title the request asked for.")
        #expect(verdict.issues[1].contains("tautological"))
    }

    @Test func issuesUnderAContradictoryCleanVerdictStillWithholdTheRung() {
        // A "clean" summary word cannot override named problems — the
        // conservative resolution is that the issues win. This is the exact
        // shape a lazily-formatted reviewer could produce, and it must NOT slip
        // through as an L6 clear.
        let reply = """
        ISSUE: The migration is not idempotent and will double-apply on a re-run.
        VERDICT: CLEAN
        """
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues == ["The migration is not idempotent and will double-apply on a re-run."])
    }

    @Test func aBulletedIssueLineIsStillCollected() {
        let reply = """
        - ISSUE: Unparameterized SQL is built from request input.
        VERDICT: DISQUALIFYING
        """
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues == ["Unparameterized SQL is built from request input."])
    }

    // MARK: - Parsing: fail-closed floors

    @Test func aReplyWithNoReadableVerdictIsFailClosedWithAnHonestReason() {
        // The model rambled and never rendered a verdict line. "Independently
        // reviewed" is a claim about a review that legibly found nothing — the
        // absence of a legible verdict is NOT that, so the rung is withheld and
        // the reason says exactly why rather than leaving it blank.
        let reply = "This looks mostly fine to me, I think it probably works."
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues.count == 1)
        #expect(verdict.issues[0].contains("did not return a readable verdict"))
    }

    @Test func aDisqualifyingVerdictWithNoNamedIssueStillReportsAReason() {
        let reply = "VERDICT: DISQUALIFYING"
        let verdict = FeatureEditAdversarialReviewer.parse(reply: reply)
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues.count == 1)
        #expect(verdict.issues[0].contains("without naming a specific issue"))
    }

    @Test func anEmptyReplyIsFailClosed() {
        let verdict = FeatureEditAdversarialReviewer.parse(reply: "")
        #expect(verdict.isDisqualifying == true)
        #expect(verdict.issues.isEmpty == false)
    }
}
