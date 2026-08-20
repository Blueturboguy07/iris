//
//  FeatureEditClarification.swift
//  leanring-buddy
//
//  The follow-up / clarification protocol for the Feature Engine (plan §7).
//
//  The design goal is "asks the right follow-ups" WITHOUT dribbling: the
//  should-I-ask decision is decoupled from the edit loop entirely (OpenHands
//  measured a real resolve-rate gain from that split), the questions are
//  batched into ONE round before any edit (Plan-Mode shape), and a question is
//  emitted ONLY when one of four fixed triggers fires — otherwise the engine
//  proceeds. This file is that decision, pure: no model calls, no file I/O,
//  no SwiftUI. The coordinator gathers the boolean/shape signals (from the
//  derived RepoRecipe, from the two-pass self-consistency check, from the
//  request classifier) and this logic turns them into the compact, tappable
//  question set the eye-bar card presents — a couple of decisive questions,
//  never a chat interrogation.
//

import Foundation

// MARK: - Why a question is being asked

/// The ONLY four reasons the engine is allowed to interrupt the reader before
/// editing (plan §7). Keeping the triggers as a closed enum — rather than
/// letting call sites invent ad-hoc questions — is what enforces the
/// "few, high-value" rule structurally: a new kind of question requires a new
/// case here, which forces the over-asking conversation to happen in review.
nonisolated enum ClarificationTrigger: String, Sendable, CaseIterable {
    /// The request could be built in ≥2 materially different ways and nothing
    /// in the repo disambiguates (two quick reasoning passes disagreed).
    case ambiguousAmongImplementations

    /// The request implies an action that is hard or impossible to undo:
    /// a data/save-file format change, a public API/CLI-flag break, a
    /// destructive migration.
    case irreversibleOrCostlyAction

    /// Something the engine needs is absent from the repo/context — the §4
    /// `unknown` build/run recipe lands here ("I can edit this but I don't
    /// know how to build it").
    case requiredInfoAbsentFromRepo

    /// A §8 runtime-shape-specific decision the reader must make (a scaled
    /// service's rollout/tenancy posture), or the shape itself could not be
    /// classified and the right checklist + auto-commit rung depend on it.
    case runtimeShapeDecision
}

// MARK: - One tappable question

/// A single question in the one-round clarification batch. Rendered by the
/// eye-bar/on-demand card as a prompt with tappable options (reusing the
/// maintain ask/answer surface), so `options` is never empty — a question the
/// reader can only answer by typing an essay is the interrogation shape §7
/// forbids.
nonisolated struct ClarificationQuestion: Sendable, Identifiable, Equatable {
    /// Stable identity for SwiftUI lists AND for matching an answer back to
    /// its question across a recompute. The logic below emits at most one
    /// question per trigger, so the trigger's rawValue is the natural stable
    /// id; a caller constructing its own questions may override it.
    let id: String

    /// The question as shown to the reader — plain language, states what Iris
    /// found and why it is asking, never model-internal jargon.
    let prompt: String

    /// The tappable answers, most-recommended first (the card renders them in
    /// order). Always at least two — a "question" with one option is a
    /// notification wearing a question's clothes.
    let options: [String]

    /// Which of the four §7 triggers produced this question, kept on the
    /// value so the coordinator can route the answer (e.g. a
    /// `requiredInfoAbsentFromRepo` answer about the build command flows into
    /// the ratified-1b model-authored-command consent path, while a
    /// `runtimeShapeDecision` answer updates the checklist column).
    let trigger: ClarificationTrigger

    init(
        prompt: String,
        options: [String],
        trigger: ClarificationTrigger,
        id: String? = nil
    ) {
        self.id = id ?? trigger.rawValue
        self.prompt = prompt
        self.options = options
        self.trigger = trigger
    }
}

// MARK: - The pre-edit plan

/// The short PLAN the engine presents before any edit (plan §7): files to
/// touch, the approach, the resolved recipe + its confidence in words, the
/// open questions (empty = nothing fired, proceed straight to consent), and
/// the honesty rung it expects to earn. Explicit consent on this plan is what
/// unlocks the edit tools — "ask once, then commit", mirroring Plan Mode.
nonisolated struct FeatureEditPlan: Sendable {
    /// Repo-relative paths the approach expects to modify. An estimate for
    /// the reader's judgment, not a cage — the diff-scope gate remains the
    /// hard limit downstream.
    let filesToTouch: [String]

    /// One short paragraph: what will be built and how.
    let approachSummary: String

    /// The derived RepoRecipe in reader-facing words (which build/test
    /// commands, from which signal, at what confidence) — so consent to the
    /// plan is informed consent to what will later run un-jailed.
    let resolvedRecipeSummary: String

    /// The batched clarification round. Empty means every trigger stayed
    /// quiet and the plan can go straight to the consent tap.
    let openQuestions: [ClarificationQuestion]

    /// The §9 evidence-ladder rung this plan honestly expects to reach
    /// (e.g. "L3 — feature has a passing test"), stated up front so the
    /// reader knows the verification bar BEFORE approving the edit.
    let expectedRung: String
}

// MARK: - The ask-or-proceed decision

/// Pure decision logic: signals in, the batched question set out. Emits at
/// most one question per trigger, in the plan's fixed trigger order, and
/// returns [] — proceed — whenever nothing fires. The inputs are already-
/// adjudicated facts (booleans + the classified shape) precisely so this
/// layer stays deterministic and unit-testable against the §10.3 table.
nonisolated enum FeatureEditClarificationLogic {

    /// Decide which clarification questions (if any) must be asked before the
    /// plan is presented.
    ///
    /// - Parameters:
    ///   - forRequest: The reader's own words, echoed inside the ambiguity
    ///     question so they can see WHAT Iris found unclear.
    ///   - requestLooksAmbiguous: The self-consistency verdict — true only
    ///     when two quick reasoning passes produced materially different
    ///     implementations AND the repo did not disambiguate.
    ///   - recipeIsUnknown: True when the derived RepoRecipe has no buildable
    ///     recipe (`hasABuildableRecipe == false`) — the §4 graceful-
    ///     degradation case that now asks instead of hard-refusing.
    ///   - runtimeShape: The §8 classification from the derived recipe.
    ///   - impliesIrreversibleAction: True when the request classifier found
    ///     a data-format change, public-interface break, or destructive
    ///     migration implied by the request.
    static func questions(
        forRequest request: String,
        requestLooksAmbiguous: Bool,
        recipeIsUnknown: Bool,
        runtimeShape: RecipeRuntimeShape,
        impliesIrreversibleAction: Bool
    ) -> [ClarificationQuestion] {
        var batchedQuestions: [ClarificationQuestion] = []

        // Trigger 1 — ambiguous among implementations. The request text is
        // echoed so the reader sees exactly which words were unclear; the
        // options offer the two honest resolutions (say more, or delegate to
        // the plan-then-consent flow, which still shows the choice made).
        if requestLooksAmbiguous {
            batchedQuestions.append(ClarificationQuestion(
                prompt: "“\(request)” could be built in more than one meaningfully "
                    + "different way, and nothing in the app's code settles which "
                    + "you meant. How should Iris proceed?",
                options: [
                    "Let me describe it more specifically",
                    "Pick the approach you think is best and show me the plan first",
                ],
                trigger: .ambiguousAmongImplementations
            ))
        }

        // Trigger 2 — irreversible/costly. This question exists because
        // consent to "add a feature" is NOT consent to break a save-file
        // format; the destructive consequence must be named before the plan
        // is even drawn. The additive-alternative option is listed first
        // because expand/contract is the §8 checklist's own recommendation.
        if impliesIrreversibleAction {
            batchedQuestions.append(ClarificationQuestion(
                prompt: "Doing this the direct way would change something that is "
                    + "hard to undo — a saved-data format, a public interface, or "
                    + "a destructive migration. How careful should Iris be?",
                options: [
                    "Find an additive approach that keeps old data/interfaces working",
                    "Go ahead with the direct change — I understand it's hard to undo",
                    "Stop — don't make this change",
                ],
                trigger: .irreversibleOrCostlyAction
            ))
        }

        // Trigger 3 — required info absent from the repo. Today this exact
        // situation is the hard "unknown stack" refusal; asking is what turns
        // the wall into a capability (§4). The first option is the ratified
        // decision 1b escape hatch: the reader may supply/approve a build
        // command, which then still passes the catastrophe classifier and an
        // extra explicit consent before running un-jailed.
        if recipeIsUnknown {
            batchedQuestions.append(ClarificationQuestion(
                prompt: "Iris read the app's code but couldn't work out how to "
                    + "build it, so it can't verify an edit on its own. How do "
                    + "you build this app?",
                options: [
                    "I'll provide the build command (Iris will safety-screen it and confirm before running)",
                    "Make the edit anyway — I accept a lower verification level",
                    "Stop here",
                ],
                trigger: .requiredInfoAbsentFromRepo
            ))
        }

        // Trigger 4 — runtime-shape decision. Two distinct shapes warrant a
        // question; the two local shapes deliberately do NOT (their checklist
        // column applies silently — asking would be the over-asking §7 bans):
        //   • builtForScale — the rollout/tenancy posture (flag-gated,
        //     tenant-scoped, additive-only) is a product decision the reader
        //     owns, not something Iris may assume.
        //   • unknown — the classifier could not tell how the app runs, and
        //     both the checklist column AND the required auto-commit rung
        //     (ratified 5a: L2 local vs L5 service) hang on the answer, so
        //     assuming "local" would silently lower the safety bar.
        switch runtimeShape {
        case .builtForScale:
            batchedQuestions.append(ClarificationQuestion(
                prompt: "This app is built to run as a scaled service. Should the "
                    + "new behavior ship behind a feature flag, scoped to each "
                    + "tenant, and additive-only (safe to roll back)?",
                options: [
                    "Yes — flag-gated, tenant-scoped, additive-only (recommended)",
                    "No — ship it directly",
                ],
                trigger: .runtimeShapeDecision
            ))
        case .unknown:
            batchedQuestions.append(ClarificationQuestion(
                prompt: "Iris couldn't tell how this app runs, and the right "
                    + "engineering practices depend on it. How does it run?",
                options: [
                    "A local app on this Mac only",
                    "A self-hosted service just for me",
                    "A service meant to serve many users",
                ],
                trigger: .runtimeShapeDecision
            ))
        case .pureLocalApp, .localSingleInstanceService:
            // Proceed silently: the shape is known and its checklist column
            // needs no reader decision. Asking here would be nagging.
            break
        }

        return batchedQuestions
    }
}
