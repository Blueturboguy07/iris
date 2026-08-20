//
//  FeatureEditRuntimeChecklistTests.swift
//  leanring-buddyTests
//
//  The runtime-shape checklist (plan §8) is what makes "best practices
//  considering how this app runs" a concrete, testable thing rather than a
//  vibe. These tests pin the two properties that matter:
//
//    1. The classified shape selects the CORRECT column — pureLocalApp gets
//       the local lane, builtForScale (and the other server-ish shapes) get
//       the scaled lane — so the model is told the right practices up front.
//    2. The pre-flight addendum and the post-edit review checklist are drawn
//       from the SAME column, so the reviewer probes exactly what the author
//       was instructed to satisfy.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditRuntimeChecklistTests {

    // MARK: - The table itself

    @Test func allEightPlanDimensionsArePresent() {
        // Plan §8 defines exactly 8 dimensions; the array IS the policy, so a
        // dropped or duplicated row is a policy change this pins against.
        #expect(FeatureEditRuntimeChecklist.dimensions.count == 8)

        let expectedDimensionNames = [
            "Concurrency & idempotency",
            "State",
            "Database migration",
            "Performance",
            "Observability & errors",
            "Security & tenancy",
            "Rollout",
            "API & contract",
        ]
        #expect(FeatureEditRuntimeChecklist.dimensions.map { $0.name } == expectedDimensionNames)
    }

    @Test func everyDimensionHasBothColumnsFilledAndDistinct() {
        // A row missing either column, or with the same string in both, would
        // silently give one runtime shape the wrong lane's advice.
        for dimension in FeatureEditRuntimeChecklist.dimensions {
            #expect(!dimension.pureLocalCheck.isEmpty)
            #expect(!dimension.scaledServiceCheck.isEmpty)
            #expect(dimension.pureLocalCheck != dimension.scaledServiceCheck)
        }
    }

    @Test func aDimensionReturnsTheColumnMatchingCheck() {
        let concurrencyDimension = FeatureEditRuntimeChecklist.dimensions[0]
        #expect(concurrencyDimension.check(forColumn: .pureLocal) == concurrencyDimension.pureLocalCheck)
        #expect(concurrencyDimension.check(forColumn: .scaledService) == concurrencyDimension.scaledServiceCheck)
    }

    // MARK: - Shape → column mapping (the core requirement)

    @Test func aPureLocalAppSelectsTheLocalColumn() {
        #expect(FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: .pureLocalApp) == .pureLocal)
    }

    @Test func aBuiltForScaleAppSelectsTheScaledColumn() {
        #expect(FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: .builtForScale) == .scaledService)
    }

    @Test func aSingleInstanceServiceSelectsTheScaledColumn() {
        // A self-hosted single-instance service still has a server + shared
        // persistence, so it gets the careful lane — the same grouping the
        // verification ladder's requiredRung uses (L5 for anything server-ish).
        #expect(FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: .localSingleInstanceService) == .scaledService)
    }

    @Test func anUnknownShapeFailsConservativeIntoTheScaledColumn() {
        // Unclassifiable must not be assumed local — that would silently hand
        // the model the cheaper checklist for an app that might corrupt shared
        // state. Mirrors requiredRung treating unknown as the riskier kind.
        #expect(FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: .unknown) == .scaledService)
    }

    @Test func onlyThePureLocalAppEverGetsTheCheapLocalColumn() {
        // The whole safety posture depends on exactly one shape being "cheap".
        let everyRuntimeShape: [RecipeRuntimeShape] = [
            .pureLocalApp, .localSingleInstanceService, .builtForScale, .unknown,
        ]
        for runtimeShape in everyRuntimeShape {
            let column = FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: runtimeShape)
            if runtimeShape == .pureLocalApp {
                #expect(column == .pureLocal)
            } else {
                #expect(column == .scaledService)
            }
        }
    }

    // MARK: - pureLocalApp vs builtForScale return the correct column of strings

    @Test func theReviewChecklistUsesTheLocalStringsForAPureLocalApp() {
        let reviewItems = FeatureEditRuntimeChecklist.reviewChecklist(forRuntimeShape: .pureLocalApp)
        #expect(reviewItems.count == FeatureEditRuntimeChecklist.dimensions.count)
        for (dimension, reviewItem) in zip(FeatureEditRuntimeChecklist.dimensions, reviewItems) {
            #expect(reviewItem == "\(dimension.name): \(dimension.pureLocalCheck)")
        }
    }

    @Test func theReviewChecklistUsesTheScaledStringsForABuiltForScaleApp() {
        let reviewItems = FeatureEditRuntimeChecklist.reviewChecklist(forRuntimeShape: .builtForScale)
        #expect(reviewItems.count == FeatureEditRuntimeChecklist.dimensions.count)
        for (dimension, reviewItem) in zip(FeatureEditRuntimeChecklist.dimensions, reviewItems) {
            #expect(reviewItem == "\(dimension.name): \(dimension.scaledServiceCheck)")
        }
    }

    @Test func localAndScaledReviewChecklistsDifferOnEveryDimension() {
        // The two columns must actually diverge — otherwise the shape awareness
        // would be cosmetic.
        let localItems = FeatureEditRuntimeChecklist.reviewChecklist(forRuntimeShape: .pureLocalApp)
        let scaledItems = FeatureEditRuntimeChecklist.reviewChecklist(forRuntimeShape: .builtForScale)
        #expect(localItems.count == scaledItems.count)
        for (localItem, scaledItem) in zip(localItems, scaledItems) {
            #expect(localItem != scaledItem)
        }
    }

    // MARK: - The pre-flight addendum and the review checklist stay in lockstep

    @Test func thePreflightAddendumContainsTheSameColumnStringsAsTheReviewChecklist() {
        // Single-sourcing is the whole point: whatever the model is told to do
        // is exactly what the reviewer later checks. Prove every review item's
        // check text appears verbatim in the addendum, for both columns.
        for runtimeShape in [RecipeRuntimeShape.pureLocalApp, .builtForScale] {
            let addendum = FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: runtimeShape)
            let column = FeatureEditRuntimeChecklist.columnApplied(forRuntimeShape: runtimeShape)
            for dimension in FeatureEditRuntimeChecklist.dimensions {
                #expect(addendum.contains(dimension.check(forColumn: column)))
                #expect(addendum.contains(dimension.name))
            }
        }
    }

    @Test func thePreflightAddendumForAPureLocalAppDoesNotLeakScaledOnlyGuidance() {
        // A local app should not be told to "scope every query by tenant" — the
        // guidance must match the lane, or the model over-engineers a CLI.
        let localAddendum = FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: .pureLocalApp)
        #expect(localAddendum.contains("Keychain"))
        #expect(!localAddendum.contains("AUTHENTICATED tenant"))
        #expect(!localAddendum.contains("feature flag"))
    }

    @Test func thePreflightAddendumNamesHowTheAppRuns() {
        // The runtime-context header must be present so the model knows WHY the
        // checklist column was chosen.
        let localAddendum = FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: .pureLocalApp)
        #expect(localAddendum.contains("Runtime context:"))
        #expect(localAddendum.contains("locally on one Mac"))

        let scaledAddendum = FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: .builtForScale)
        #expect(scaledAddendum.contains("scaled, multi-instance service"))
    }

    @Test func anUnknownShapeAddendumAdmitsItCouldNotClassifyButStillAppliesStrictChecks() {
        // Honesty (§9): the stricter checklist must not read as a false claim
        // that the app is definitely scaled.
        let unknownAddendum = FeatureEditRuntimeChecklist.preflightPromptAddendum(forRuntimeShape: .unknown)
        #expect(unknownAddendum.contains("could not classify"))
        // Still carries the scaled-column guidance.
        let scaledColumnState = FeatureEditRuntimeChecklist.dimensions[1].scaledServiceCheck
        #expect(unknownAddendum.contains(scaledColumnState))
    }
}
