//
//  FeatureEditVerificationLadder.swift
//  leanring-buddy
//
//  The L0–L6 evidence ladder (feature-engine plan §9) that replaces the old
//  binary "applied and rebuilt" vs "verified" labeling. A change earns a rung
//  by COLLECTED EVIDENCE, never by self-assessment: each rung requires every
//  signal below it, so a passing new test with a red existing suite still
//  reads "unverified past L1" — no rung is ever claimed above its evidence.
//
//  Two deliberate properties:
//
//    1. The report is an evidence LOG ("Tests: 47/47", "App booted"), never a
//       confidence number. A number invites the model — and the reader — to
//       treat a guess as a measurement; a row of observed facts cannot be
//       inflated without lying about a specific observation.
//
//    2. The rung REQUIRED to auto-commit scales with blast radius (ratified
//       decision 5a): a pure-local app stops at L2 (builds + existing suite
//       green), anything with a server / persistence / tenancy must reach L5
//       (live-verified), and a shape we could not classify is treated as the
//       riskier kind, not the cheaper one.
//
//  Pure Foundation value logic — no network, no UI, no process spawning.
//

import Foundation

/// One rung of the evidence ladder. Raw values are the L-numbers from the
/// plan's table, so `rawValue` doubles as the "L2"/"L5" shorthand used in
/// commit trailers and the reader-facing card.
enum VerificationRung: Int, Sendable, Comparable, CaseIterable {
    case unverified = 0
    case builds = 1
    case buildsNoRegression = 2
    case featureHasTest = 3
    case featureTestValidated = 4
    case liveVerified = 5
    case independentlyReviewed = 6

    /// Reader-facing label. Kept short and factual — it names what was
    /// OBSERVED, not how confident anyone feels about it.
    var humanReadableLabel: String {
        switch self {
        case .unverified:
            return "L0 — unverified (edit made, nothing run)"
        case .builds:
            return "L1 — builds"
        case .buildsNoRegression:
            return "L2 — builds, existing tests green"
        case .featureHasTest:
            return "L3 — feature has a passing test"
        case .featureTestValidated:
            return "L4 — feature test validated by mutation testing"
        case .liveVerified:
            return "L5 — live-verified (app booted, flow exercised)"
        case .independentlyReviewed:
            return "L6 — independently reviewed (adversarial pass clean)"
        }
    }

    static func < (lhs: VerificationRung, rhs: VerificationRung) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The per-signal facts a verification run actually collected. Booleans say
/// whether the signal was EARNED; the paired optional strings carry the
/// observed evidence verbatim ("Tests: 47/47", "Mutation: 12/12 survivors
/// killed") for the evidence log and the commit trailer.
///
/// Everything defaults to "not earned / no evidence" so a run that dies early
/// naturally reports the honest floor rather than needing a special case.
struct VerificationEvidence: Sendable {
    /// L1 — the compile/type-check pass came back clean.
    var compileClean: Bool = false
    var compileCleanEvidence: String? = nil

    /// L2 — the FULL existing suite ran and was green (a regression check,
    /// not a check of the new behavior).
    var existingSuiteGreen: Bool = false
    var existingSuiteGreenEvidence: String? = nil

    /// L3 — targeted new test(s) for the new behavior exist and pass.
    var newTestPasses: Bool = false
    var newTestPassesEvidence: String? = nil

    /// L4 — mutation testing proved the new tests are sensitive (the
    /// survivors were killed), i.e. they verify something, not tautologies.
    var mutationSurvivorsKilled: Bool = false
    var mutationSurvivorsKilledEvidence: String? = nil

    /// L5 — the actual app booted and the real flow was exercised.
    var smokeBooted: Bool = false
    var smokeBootedEvidence: String? = nil

    /// L6 — a separate-context adversarial review found nothing disqualifying.
    var adversarialReviewClean: Bool = false
    var adversarialReviewCleanEvidence: String? = nil

    /// The honest evidence rows for the reader-facing report and the commit
    /// trailer. One row per signal, ALWAYS all six, so what was NOT collected
    /// is as visible as what was — an absent row would let a partial run read
    /// like a complete one. Deliberately never a confidence number (see the
    /// file header for why).
    func evidenceLogLines() -> [String] {
        // Each row prefers the verbatim observed evidence; without one it
        // falls back to a plain statement of the boolean, and an unearned
        // signal says "no evidence" rather than being omitted.
        let signalRowsInLadderOrder: [(label: String, earned: Bool, observedEvidence: String?, earnedFallback: String)] = [
            ("Build", compileClean, compileCleanEvidence, "compiled clean"),
            ("Existing suite", existingSuiteGreen, existingSuiteGreenEvidence, "all existing tests green"),
            ("Feature test", newTestPasses, newTestPassesEvidence, "new targeted test passes"),
            ("Mutation check", mutationSurvivorsKilled, mutationSurvivorsKilledEvidence, "new tests proven sensitive"),
            ("Live smoke", smokeBooted, smokeBootedEvidence, "app booted, flow exercised"),
            ("Adversarial review", adversarialReviewClean, adversarialReviewCleanEvidence, "separate-context review found nothing disqualifying"),
        ]
        return signalRowsInLadderOrder.map { signalRow in
            if let observedEvidence = signalRow.observedEvidence, !observedEvidence.isEmpty {
                return "\(signalRow.label): \(observedEvidence)"
            }
            if signalRow.earned {
                return "\(signalRow.label): \(signalRow.earnedFallback)"
            }
            return "\(signalRow.label): no evidence collected"
        }
    }
}

/// The ladder's two pure judgments: which rung the collected evidence
/// actually earns, and which rung this change is REQUIRED to reach before it
/// may be auto-committed (ratified decision 5a).
enum FeatureEditVerificationLadder {

    /// The highest rung the evidence supports. Signals are checked strictly
    /// in ladder order and the climb STOPS at the first missing one — a
    /// higher signal with a lower one absent earns nothing, which is what
    /// makes the label honest (you cannot be "live-verified" on top of a red
    /// suite, no matter what booted).
    static func highestEarnedRung(from collectedEvidence: VerificationEvidence) -> VerificationRung {
        // The (signal, rung-it-unlocks) pairs, lowest first. The order IS the
        // policy: reordering these would change what each rung means.
        let ladderSignalsInAscendingOrder: [(signalWasEarned: Bool, rungItUnlocks: VerificationRung)] = [
            (collectedEvidence.compileClean, .builds),
            (collectedEvidence.existingSuiteGreen, .buildsNoRegression),
            (collectedEvidence.newTestPasses, .featureHasTest),
            (collectedEvidence.mutationSurvivorsKilled, .featureTestValidated),
            (collectedEvidence.smokeBooted, .liveVerified),
            (collectedEvidence.adversarialReviewClean, .independentlyReviewed),
        ]

        var highestRungEarnedSoFar: VerificationRung = .unverified
        for ladderSignal in ladderSignalsInAscendingOrder {
            guard ladderSignal.signalWasEarned else {
                // First missing signal ends the climb; anything earned above
                // this point does not count toward the rung.
                break
            }
            highestRungEarnedSoFar = ladderSignal.rungItUnlocks
        }
        return highestRungEarnedSoFar
    }

    /// The rung a change must reach before auto-commit, scaled by blast
    /// radius (ratified decision 5a):
    ///
    ///   - a pure-local app (native/CLI, no server, no persistence shared
    ///     beyond this machine) auto-commits at L2 — builds + the existing
    ///     suite green is the same bar the old engine's "applied and rebuilt"
    ///     asked for, and a bad change is one `git revert` away;
    ///   - anything with a server component — single-instance or built for
    ///     scale — must reach L5, because a regression there can corrupt
    ///     persisted or multi-user state that no revert un-corrupts;
    ///   - a shape we could not classify is treated as the RISKIER kind.
    ///     Failing conservative here is the whole point of having the rung.
    static func requiredRung(forRuntimeShape runtimeShape: RecipeRuntimeShape) -> VerificationRung {
        switch runtimeShape {
        case .pureLocalApp:
            return .buildsNoRegression
        case .localSingleInstanceService:
            return .liveVerified
        case .builtForScale:
            return .liveVerified
        case .unknown:
            // Unclassifiable = assume the worst shape, never the cheapest.
            return .liveVerified
        }
    }
}
