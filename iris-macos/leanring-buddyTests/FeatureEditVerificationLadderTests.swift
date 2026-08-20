//
//  FeatureEditVerificationLadderTests.swift
//  leanring-buddyTests
//
//  The evidence ladder is load-bearing honesty logic: the rung it reports is
//  what the commit trailer and the reader-facing card CLAIM about a change.
//  These tests pin the two properties that make the claim trustworthy —
//  no rung is ever earned above its evidence (the climb stops at the first
//  missing signal), and the required-rung policy (ratified decision 5a)
//  fails conservative for anything that is not provably pure-local.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditVerificationLadderTests {

    // MARK: - The rung ladder itself

    @Test func theRungsAreTotallyOrderedFromUnverifiedToIndependentlyReviewed() {
        // The Comparable order must match the ladder order — a higher rung is
        // strictly "more verified" than every rung below it.
        let expectedAscendingOrder: [VerificationRung] = [
            .unverified,
            .builds,
            .buildsNoRegression,
            .featureHasTest,
            .featureTestValidated,
            .liveVerified,
            .independentlyReviewed,
        ]
        #expect(VerificationRung.allCases == expectedAscendingOrder)
        for (lowerIndex, lowerRung) in expectedAscendingOrder.enumerated() {
            for higherRung in expectedAscendingOrder.dropFirst(lowerIndex + 1) {
                #expect(lowerRung < higherRung)
            }
        }
        // The raw values are the L-numbers used in trailers ("L2", "L5").
        #expect(VerificationRung.unverified.rawValue == 0)
        #expect(VerificationRung.independentlyReviewed.rawValue == 6)
    }

    @Test func everyRungHasADistinctHumanReadableLabel() {
        let allLabels = VerificationRung.allCases.map { $0.humanReadableLabel }
        #expect(Set(allLabels).count == allLabels.count)
        for label in allLabels {
            #expect(!label.isEmpty)
        }
    }

    // MARK: - highestEarnedRung: evidence climbs one signal at a time

    @Test func noEvidenceEarnsUnverified() {
        let noEvidence = VerificationEvidence()
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: noEvidence) == .unverified)
    }

    @Test func eachAddedSignalEarnsExactlyTheNextRung() {
        var accumulatingEvidence = VerificationEvidence()

        accumulatingEvidence.compileClean = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .builds)

        accumulatingEvidence.existingSuiteGreen = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .buildsNoRegression)

        accumulatingEvidence.newTestPasses = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .featureHasTest)

        accumulatingEvidence.mutationSurvivorsKilled = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .featureTestValidated)

        accumulatingEvidence.smokeBooted = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .liveVerified)

        accumulatingEvidence.adversarialReviewClean = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: accumulatingEvidence) == .independentlyReviewed)
    }

    @Test func aHigherSignalWithALowerOneMissingEarnsNothingAboveTheGap() {
        // A passing new test on top of a RED existing suite must not read as
        // L3 — the climb stops at the first missing signal. This is the
        // anti-inflation property the whole ladder exists for.
        var evidenceWithAGap = VerificationEvidence()
        evidenceWithAGap.compileClean = true
        evidenceWithAGap.existingSuiteGreen = false
        evidenceWithAGap.newTestPasses = true
        evidenceWithAGap.smokeBooted = true
        evidenceWithAGap.adversarialReviewClean = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: evidenceWithAGap) == .builds)
    }

    @Test func aSmokeBootAloneWithNothingElseEarnsUnverified() {
        // "The app booted" without a clean build on record proves nothing
        // about THIS change — it must not earn any rung.
        var smokeOnlyEvidence = VerificationEvidence()
        smokeOnlyEvidence.smokeBooted = true
        #expect(FeatureEditVerificationLadder.highestEarnedRung(from: smokeOnlyEvidence) == .unverified)
    }

    // MARK: - requiredRung: ratified decision 5a

    @Test func aPureLocalAppMayAutoCommitAtBuildsNoRegression() {
        #expect(FeatureEditVerificationLadder.requiredRung(forRuntimeShape: .pureLocalApp) == .buildsNoRegression)
    }

    @Test func anyServerShapedAppMustReachLiveVerified() {
        #expect(FeatureEditVerificationLadder.requiredRung(forRuntimeShape: .localSingleInstanceService) == .liveVerified)
        #expect(FeatureEditVerificationLadder.requiredRung(forRuntimeShape: .builtForScale) == .liveVerified)
    }

    @Test func anUnknownRuntimeShapeIsTreatedAsTheRiskierKind() {
        // Unclassifiable must fail conservative — the cheap L2 bar is only
        // for a shape PROVEN pure-local.
        #expect(FeatureEditVerificationLadder.requiredRung(forRuntimeShape: .unknown) == .liveVerified)
    }

    @Test func theRequiredRungPolicyNeverAsksBelowTheOldEngineFloor() {
        // Every shape's requirement is at least L2 — the old engine's
        // "applied and rebuilt" bar. The new ladder may raise the bar per
        // shape but must never lower it.
        let everyRuntimeShape: [RecipeRuntimeShape] = [
            .pureLocalApp, .localSingleInstanceService, .builtForScale, .unknown,
        ]
        for runtimeShape in everyRuntimeShape {
            #expect(FeatureEditVerificationLadder.requiredRung(forRuntimeShape: runtimeShape) >= .buildsNoRegression)
        }
    }

    // MARK: - The evidence log is honest rows, never a score

    @Test func theEvidenceLogAlwaysShowsAllSixSignals() {
        // What was NOT collected must be as visible as what was — a partial
        // run must not read like a complete one by omitting rows.
        let noEvidence = VerificationEvidence()
        let logLines = noEvidence.evidenceLogLines()
        #expect(logLines.count == 6)
        for logLine in logLines {
            #expect(logLine.contains("no evidence collected"))
        }
    }

    @Test func theEvidenceLogCarriesObservedEvidenceVerbatim() {
        var evidenceWithObservations = VerificationEvidence()
        evidenceWithObservations.compileClean = true
        evidenceWithObservations.compileCleanEvidence = "swift build: exit 0"
        evidenceWithObservations.existingSuiteGreen = true
        evidenceWithObservations.existingSuiteGreenEvidence = "Tests: 47/47"

        let logLines = evidenceWithObservations.evidenceLogLines()
        #expect(logLines.contains("Build: swift build: exit 0"))
        #expect(logLines.contains("Existing suite: Tests: 47/47"))
    }

    @Test func anEarnedSignalWithoutObservedTextStillReadsAsAFactualRow() {
        var earnedWithoutText = VerificationEvidence()
        earnedWithoutText.compileClean = true
        let buildRow = earnedWithoutText.evidenceLogLines()[0]
        #expect(buildRow.hasPrefix("Build: "))
        #expect(!buildRow.contains("no evidence collected"))
    }

    @Test func theEvidenceLogNeverContainsAConfidenceNumber() {
        // The report format is observed facts, never a self-rated score — a
        // percent sign or a "confidence" word in a default row would be the
        // regression this pins against. (Verbatim observed evidence the
        // harness passes in is the caller's own measurement and may contain
        // anything; the DEFAULT rows must not.)
        var fullyEarnedEvidence = VerificationEvidence()
        fullyEarnedEvidence.compileClean = true
        fullyEarnedEvidence.existingSuiteGreen = true
        fullyEarnedEvidence.newTestPasses = true
        fullyEarnedEvidence.mutationSurvivorsKilled = true
        fullyEarnedEvidence.smokeBooted = true
        fullyEarnedEvidence.adversarialReviewClean = true

        for logLine in fullyEarnedEvidence.evidenceLogLines() {
            #expect(!logLine.contains("%"))
            #expect(!logLine.lowercased().contains("confidence"))
        }
    }
}
