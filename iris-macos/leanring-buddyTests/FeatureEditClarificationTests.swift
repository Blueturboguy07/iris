//
//  FeatureEditClarificationTests.swift
//  leanring-buddyTests
//
//  The §10.3 table for the clarification protocol: each of the four §7
//  triggers fires exactly its one question, and — just as load-bearing — the
//  PROCEED cases return no questions at all, because an engine that over-asks
//  is the nagging §7 was designed to prevent. Pure logic, no processes.
//

import Foundation
import Testing
@testable import Iris

@Suite struct FeatureEditClarificationTests {

    // MARK: - Proceed cases (the anti-over-asking half of the table)

    @Test func unambiguousRequestWithKnownRecipeOnAPureLocalAppAsksNothing() {
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Add a Cmd+Shift+C shortcut that copies the current note as Markdown",
            requestLooksAmbiguous: false,
            recipeIsUnknown: false,
            runtimeShape: .pureLocalApp,
            impliesIrreversibleAction: false
        )
        #expect(questions.isEmpty)
    }

    @Test func aKnownLocalSingleInstanceServiceAsksNothingEither() {
        // Having a server component alone is NOT a trigger — the local
        // single-instance checklist column applies silently. Only the scaled
        // shape (or an unclassifiable one) warrants a question.
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Add a dark-mode toggle to the settings page",
            requestLooksAmbiguous: false,
            recipeIsUnknown: false,
            runtimeShape: .localSingleInstanceService,
            impliesIrreversibleAction: false
        )
        #expect(questions.isEmpty)
    }

    // MARK: - Trigger 1: ambiguous among implementations

    @Test func anAmbiguousRequestAsksExactlyOneAmbiguityQuestion() {
        let readerRequest = "make search better"
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: readerRequest,
            requestLooksAmbiguous: true,
            recipeIsUnknown: false,
            runtimeShape: .pureLocalApp,
            impliesIrreversibleAction: false
        )
        #expect(questions.count == 1)
        #expect(questions.first?.trigger == .ambiguousAmongImplementations)
        // The reader must see WHICH words were unclear, so the question
        // echoes their own request back.
        #expect(questions.first?.prompt.contains(readerRequest) == true)
    }

    // MARK: - Trigger 2: irreversible or costly action

    @Test func anImpliedIrreversibleActionAsksExactlyOneIrreversibilityQuestion() {
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Change the save-file format to store notes as a single SQLite database",
            requestLooksAmbiguous: false,
            recipeIsUnknown: false,
            runtimeShape: .pureLocalApp,
            impliesIrreversibleAction: true
        )
        #expect(questions.count == 1)
        #expect(questions.first?.trigger == .irreversibleOrCostlyAction)
        // A hard-to-undo act must offer a way OUT, not only ways forward.
        #expect(questions.first?.options.contains(where: { $0.lowercased().contains("stop") }) == true)
    }

    // MARK: - Trigger 3: required info absent from the repo (unknown recipe)

    @Test func anUnknownRecipeAsksHowToBuildInsteadOfRefusing() {
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Fix the crash when opening a file with an emoji in its name",
            requestLooksAmbiguous: false,
            recipeIsUnknown: true,
            runtimeShape: .pureLocalApp,
            impliesIrreversibleAction: false
        )
        #expect(questions.count == 1)
        #expect(questions.first?.trigger == .requiredInfoAbsentFromRepo)
        // Ratified decision 1b: the reader may supply the build command, so
        // that must be one of the tappable options.
        #expect(questions.first?.options.contains(where: { $0.lowercased().contains("build command") }) == true)
    }

    // MARK: - Trigger 4: runtime-shape decision

    @Test func aScaledServiceAsksTheRolloutAndTenancyQuestion() {
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Add an endpoint that exports a workspace's data as JSON",
            requestLooksAmbiguous: false,
            recipeIsUnknown: false,
            runtimeShape: .builtForScale,
            impliesIrreversibleAction: false
        )
        #expect(questions.count == 1)
        #expect(questions.first?.trigger == .runtimeShapeDecision)
        // The recommended posture (flag-gated / tenant-scoped) leads the
        // options because the card renders them in order.
        #expect(questions.first?.options.first?.lowercased().contains("flag") == true)
    }

    @Test func anUnclassifiableRuntimeShapeAsksHowTheAppRuns() {
        // `.unknown` must ask rather than silently assume local, because the
        // required auto-commit rung (L2 local vs L5 service, ratified 5a)
        // hangs on the answer — assuming would lower the safety bar.
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "Add a CSV import button",
            requestLooksAmbiguous: false,
            recipeIsUnknown: false,
            runtimeShape: .unknown,
            impliesIrreversibleAction: false
        )
        #expect(questions.count == 1)
        #expect(questions.first?.trigger == .runtimeShapeDecision)
    }

    // MARK: - Batched round: all triggers at once

    @Test func allTriggersFiringProduceOneBatchedRoundOfFourDistinctQuestions() {
        let questions = FeatureEditClarificationLogic.questions(
            forRequest: "redo how syncing works",
            requestLooksAmbiguous: true,
            recipeIsUnknown: true,
            runtimeShape: .builtForScale,
            impliesIrreversibleAction: true
        )
        // One question per trigger — never more — batched into a single
        // round, in the plan's fixed trigger order.
        #expect(questions.map(\.trigger) == [
            .ambiguousAmongImplementations,
            .irreversibleOrCostlyAction,
            .requiredInfoAbsentFromRepo,
            .runtimeShapeDecision,
        ])
        // Identifiable identity must be unique within the batch so the
        // tappable card can match each answer back to its question.
        #expect(Set(questions.map(\.id)).count == questions.count)
    }

    // MARK: - Structural honesty of every emitted question

    @Test func everyEmittedQuestionIsActuallyTappable() {
        // Sweep every single-trigger firing plus the all-at-once batch: a
        // question with no prompt, or fewer than two options, is a
        // notification pretending to be a question — the §7 shape forbids it.
        let allFiringCombinations: [[ClarificationQuestion]] = [
            FeatureEditClarificationLogic.questions(
                forRequest: "a", requestLooksAmbiguous: true, recipeIsUnknown: false,
                runtimeShape: .pureLocalApp, impliesIrreversibleAction: false),
            FeatureEditClarificationLogic.questions(
                forRequest: "b", requestLooksAmbiguous: false, recipeIsUnknown: true,
                runtimeShape: .localSingleInstanceService, impliesIrreversibleAction: false),
            FeatureEditClarificationLogic.questions(
                forRequest: "c", requestLooksAmbiguous: false, recipeIsUnknown: false,
                runtimeShape: .unknown, impliesIrreversibleAction: true),
            FeatureEditClarificationLogic.questions(
                forRequest: "d", requestLooksAmbiguous: true, recipeIsUnknown: true,
                runtimeShape: .builtForScale, impliesIrreversibleAction: true),
        ]
        for batchedRound in allFiringCombinations {
            #expect(!batchedRound.isEmpty)
            for question in batchedRound {
                #expect(!question.prompt.isEmpty)
                #expect(question.options.count >= 2)
                #expect(!question.id.isEmpty)
            }
        }
    }

    // MARK: - The plan value carries the round

    @Test func aPlanWithNoOpenQuestionsIsTheProceedSignal() {
        let plan = FeatureEditPlan(
            filesToTouch: ["Sources/App/SearchIndex.swift"],
            approachSummary: "Add a trigram index behind the existing search entry point.",
            resolvedRecipeSummary: "Build: swift build (from Package.swift, explicit project config, confidence 0.9).",
            openQuestions: [],
            expectedRung: "L3 — feature has a passing test"
        )
        #expect(plan.openQuestions.isEmpty)
        #expect(plan.filesToTouch.count == 1)
        #expect(!plan.expectedRung.isEmpty)
    }
}
