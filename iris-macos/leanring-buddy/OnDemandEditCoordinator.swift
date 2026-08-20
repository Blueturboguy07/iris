//
//  OnDemandEditCoordinator.swift
//  leanring-buddy
//
//  The state machine behind a USER-INITIATED edit: the reader picks an
//  installed catalog app, says what they want changed (a bug fix or a
//  feature), and Iris edits the local source, verifies it, and commits it on a
//  branch — all under the reader's OWN model key. It is the second door into
//  the exact same jailed loop the crash path uses (MaintainTierCFixer), with
//  crash detection skipped entirely.
//
//  It reuses the engine and the two closure seams the incident path already
//  proved (a novel-fix attempt, a fork backup) but it does NOT inherit
//  MaintainIncidentCoordinator's MaintainAsk / rate-limit / mute machinery:
//  that exists to stop AI-initiated nagging about repeat crashes, and is
//  exactly wrong for an act the reader started themselves. So this is a
//  separate, longer-lived machine — closer to a guide session than to a single
//  ask — that mirrors the incident coordinator's closure-injection + published
//  status-line pattern and nothing else.
//
//  Every safety rail the design ratified is ON here and none is optional:
//    - Eligibility is fail-closed and RE-CHECKED LIVE at start, never trusting
//      a cached render flag: guide-source-clone provenance AND a home-contained
//      git working tree AND a BYO model key AND the Seatbelt sandbox AND a real
//      rebuild recipe for the app's stack, or the tool refuses with an honest
//      reason.
//    - A per-clonePath LOCK excludes the crash-incident path and any other
//      on-demand edit, so two `.git` strips / reverts can never race the tree.
//    - A DIRTY working tree is refused outright, so the engine's
//      revert-on-failure (`git clean -fd`) can never delete the reader's own
//      uncommitted work — it only ever cleans files Iris itself created.
//    - The free-text request is secret-scrubbed on the model-egress path
//      BEFORE it becomes any part of a prompt.
//    - The kind (bug fix vs feature) is always EXPLICIT, never inferred: it
//      drives the prompt, the commit trailer, and the honesty label, and a
//      misclassification there is a correctness/honesty bug, so a human picks
//      it. A FEATURE result is presented as "applied and rebuilt", never
//      "verified" — the engine structurally cannot elevate it.
//    - Build-script edits (build.rs, package.json scripts, Makefile, …) are
//      hard-blocked by the engine BEFORE the un-jailed verification build runs
//      them; this coordinator surfaces that honestly.
//    - Sharing is offered SEPARATELY and defaults to FORK-ONLY in the reader's
//      own namespace — never an automatic push to a third party's main.
//
//  This first slice stops at "committed on a branch": there is no rebuild /
//  terminate / relaunch of the running app (the hardest, most destructive,
//  most stack-specific piece is deferred), so the terminal state is the same
//  honest "Relaunch <App> to pick it up" the crash path already uses.
//

import Combine
import Foundation

/// Where the on-demand edit flow currently is. A longer-lived machine than
/// `OverlayEyeExchange`'s four Q&A phases; closer to a guide session's step
/// model. `.verifying` and `.committing` from the design sketch collapse into
/// `.running` here on purpose: the engine performs the jailed loop, the
/// verification build, AND the branch commit inside ONE call
/// (`attemptOnDemandEdit`), which is a black box to the UI — so those stages
/// are narrated into the runner's transcript rather than published as distinct
/// phases the coordinator cannot honestly observe entering.
enum OnDemandEditPhase: Equatable, Sendable {
    /// No app chosen yet.
    case pickApp
    /// An app is chosen and eligible; the reader is describing the change.
    case describe
    /// The request is captured and classified, and the clarification pass
    /// (plan §7) fired at least one question. The reader answers a compact,
    /// tappable batch (held in `clarificationQuestions`) BEFORE any edit — the
    /// should-I-ask decision is decoupled from the edit loop so Iris asks a
    /// couple of decisive questions, never a chat interrogation. The associated
    /// data lives in a published property (like `.previewDiff`'s diff) rather
    /// than on the case, keeping the phase enum's `Equatable` synthesis intact.
    case clarifying
    /// No clarification was needed (or every question is answered); Iris shows
    /// the short pre-edit PLAN (held in `presentedPlan`: the files it expects to
    /// touch, the approach, the resolved build/test recipe + confidence, and the
    /// honesty rung it expects to reach). Approving the plan is the consent that
    /// unlocks the edit — "ask once, then commit" (plan §7) — and it routes
    /// through the SAME LIVE eligibility re-check the start tap always did.
    case presentingPlan
    /// The request is captured, scrubbed, and classified; awaiting the reader's
    /// explicit "start" tap (Consent #1).
    case awaitingStartConsent
    /// The jailed loop + verification + branch commit are in flight under the
    /// reader's key.
    case running
    /// The edit is committed on a branch; the diff is shown for the reader to
    /// keep or discard (Consent #2 — informational for unfamiliar code, and a
    /// keep/discard choice, never a claim of correctness).
    case previewDiff
    /// The reader chose to keep; recording the patch and finishing.
    case committing
    /// The change is kept on a branch and this app CAN be rebuilt+relaunched
    /// (Option A, run-from-clone). Awaiting the reader's explicit DESTRUCTIVE
    /// consent (Consent #3) to quit the running app and open the edited build —
    /// a separate, consequential act because it kills a live process and loses
    /// unsaved work. An app that can't be relaunched skips straight to `.done`.
    case awaitingRelaunchConsent
    /// Packaging the fresh build from the clone and (once it exists) quitting the
    /// running app and launching the edited build. Nothing is terminated until
    /// the artifact is proven to exist.
    case relaunching
    /// The running app declined to quit (an unsaved-work "Save?" dialog is
    /// holding it). Awaiting a SECOND explicit consent (Consent #3b) to force
    /// quit — Iris never SIGKILLs through a save dialog on its own, because that
    /// can corrupt the app's data mid-write.
    case awaitingForceQuitConsent
    /// The flow finished (kept, relaunched, or deliberately discarded —
    /// `statusLine` says which). Terminal.
    case done
    /// The edit could not be completed. Terminal; `reason` is user-safe.
    case failed(reason: String)
    /// A precondition failed before or at start. Terminal; `reason` is honest.
    case notEligible(reason: String)
}

@MainActor
final class OnDemandEditCoordinator: ObservableObject {

    // MARK: - Published state (the EditRequestCard + takeover bind to these)

    @Published private(set) var phase: OnDemandEditPhase = .pickApp
    /// One honest, user-facing line — the analog of the incident coordinator's
    /// `fixStatusLine`, but this machine has more to say (a refusal reason, the
    /// consent prompt, the applied-on-branch result, a backup summary).
    @Published private(set) var statusLine: String?

    @Published private(set) var activeAppSlug: String?
    @Published private(set) var activeAppName: String?
    @Published private(set) var activeAppStack: BreakAppStack?

    /// The classified kind for the in-flight request, so the card can label the
    /// run and the honesty copy correctly.
    @Published private(set) var classifiedKind: OnDemandEditKind?

    /// "5 others also wanted…" prefills, k>=5-gated server-side. Empty until the
    /// pool answers, and never one person's wish echoed back.
    @Published private(set) var suggestedRequests: [String] = []

    /// The batched clarification questions (plan §7) the reader answers before
    /// the plan is drawn. Empty unless `phase == .clarifying`. Populated ONLY by
    /// `FeatureEditClarificationLogic.questions(...)`, whose closed set of four
    /// triggers is what keeps this to a couple of high-value questions rather
    /// than a nagging interrogation.
    @Published private(set) var clarificationQuestions: [ClarificationQuestion] = []

    /// The short pre-edit plan shown at `.presentingPlan` (plan §7): the files
    /// Iris expects to touch, the approach, the resolved recipe in reader-facing
    /// words, and the honesty rung it expects to reach. Nil until a plan is
    /// built. Approving it leads into the LIVE eligibility re-check + run — the
    /// plan itself is informational and never bypasses that binding gate.
    @Published private(set) var presentedPlan: FeatureEditPlan?

    /// The committed diff, shown at the preview gate. Never raw model output —
    /// it is the real `git diff` of what landed on the branch.
    @Published private(set) var proposedDiffText: String?

    /// Set when the engine blocked the edit because it touched a build-script
    /// file that would run un-jailed during the verification build. Surfaced
    /// loudly rather than buried in the generic failure copy.
    @Published private(set) var blockedByBuildScriptEdit: Bool = false

    /// True only when the current `.notEligible` refusal is the one the reader
    /// can clear themselves — no model key connected. The refusal card reads
    /// this to offer an "Open settings" button that lands on the account
    /// section, instead of leaving the reader to hunt for where a key goes. Any
    /// other refusal (provenance, sandbox, no rebuild recipe) is not something a
    /// settings tap fixes, so the button stays hidden for those.
    @Published private(set) var refusalOffersModelKeySetup: Bool = false

    /// The engine's own result, kept so the card can distinguish "applied and
    /// rebuilt" (never "verified") and read the kind / suite result honestly.
    @Published private(set) var lastResult: MaintainOnDemandEditResult?

    /// True while the reader is being asked to confirm a PUBLIC publish (posting
    /// to publik's public fix log and marking a pooled request implemented). Its
    /// own EVERY-TIME consent (D6), deliberately separate from the fork backup —
    /// backing up to your own fork is low-stakes and additive; publishing to a
    /// public listing is a distinct social act and is never remembered or
    /// bundled with the backup. Drives an explicit confirm on the done card.
    @Published private(set) var isAwaitingPublishConsent: Bool = false

    /// The "watch it work" surface, presented through the same takeover the
    /// guide autopilot uses (see `OnDemandEditRunner`).
    let editRunner = OnDemandEditRunner()

    // MARK: - Collaborators (injected seams; nothing global reached directly)

    private let installProvenanceStore: InstallProvenanceStore
    private let patchQueue: PatchQueue
    private let clonePathLock: MaintainClonePathLock

    /// The pooled "what others also wanted" prefills for an app. Injected so
    /// the coordinator does not have to own the feature-request transport.
    private let topRequestsForApp: (_ appSlug: String) async -> [String]

    /// Runs the actual on-demand edit — the jailed loop + verify + commit — and
    /// returns the engine's result. Injected so the whole machine is testable
    /// without a real model, git, or sandbox. Production resolves the reader's
    /// own provider live and drives `MaintainTierCFixer.attemptOnDemandEdit`.
    private let performOnDemandEdit: (
        _ resolvedClonePath: String,
        _ appSlug: String,
        _ appStack: BreakAppStack,
        _ changeId: String,
        _ scrubbedRequest: String,
        _ kind: OnDemandEditKind
    ) async -> MaintainOnDemandEditResult

    /// Backs the committed branch up to the reader's OWN fork — fork-only, never
    /// a push-merge to a third party's canonical repo (that would be a distinct
    /// social act on someone else's project, forbidden for on-demand regardless
    /// of push rights). Nil when backup is unavailable/not connected, which is
    /// never an error: the edit is safe on the local branch either way. Called
    /// ONLY from `requestForkBackup()`, never automatically.
    var backUpEditBranchToMyForkOnly: ((_ branchName: String, _ appSlug: String) async -> String?)?

    /// Whether a kept change on this app can be rebuilt and relaunched at all
    /// (Option A). Wired by CompanionManager to `true` only when the catalog
    /// supplies a real `macBundleId` (tri-state — never guessed) AND the stack
    /// produces a relaunchable macOS artifact (`AppRelaunchService`). When nil or
    /// false, `keepChange()` degrades to the honest manual "Relaunch <App>
    /// yourself" terminal state — the same one the crash path uses today.
    var relaunchIsAvailableForApp: ((_ appSlug: String) -> Bool)?

    /// Package a fresh, launchable artifact FROM the clone (design §4 Option A).
    /// Terminates NOTHING — it only builds and asserts a launchable bundle
    /// exists, so the running app is never quit for a build that then fails.
    /// Injected so the coordinator is testable without a real `cargo tauri build`.
    var packageEditedAppFromClone: ((_ appSlug: String) async -> AppRelaunchPackagingResult)?

    /// Terminate the running instance and launch the freshly built artifact from
    /// the clone. `allowForceQuit` is false on the first attempt; when the app
    /// won't quit cleanly this reports back so the coordinator can obtain the
    /// second (force-quit) consent before calling again with `true`.
    var terminateAndRelaunchEditedApp: (
        (_ appSlug: String, _ artifactPath: String, _ allowForceQuit: Bool) async -> AppRelaunchLaunchResult
    )?

    /// Perform the PUBLIC publish for a kept change: record it to publik's public
    /// fix log and, for a feature, mark the pooled request implemented. Called
    /// ONLY from `confirmPublishToPublik()`, behind its own explicit every-time
    /// consent (D6), never automatically and never bundled with the fork backup.
    /// Returns a one-line summary, or nil when publishing was unavailable.
    var publishEditToPublik: (
        (_ appSlug: String, _ kind: OnDemandEditKind, _ requestSummary: String) async -> String?
    )?

    // MARK: - In-flight run state (not published)

    /// The symlink-resolved, home-contained clone path in use — the one value
    /// the lock, the runner, and every git command key off, so the offer and
    /// the action never disagree about which directory is being edited.
    private var resolvedClonePath: String?
    /// The branch the engine committed the edit onto, for the preview, the
    /// keep/discard, and an explicit fork backup.
    private var committedBranchName: String?
    /// The changeId keying this edit — its branch name and its PatchQueue
    /// record. Synthesized from the scrubbed, normalized request + a timestamp.
    private var changeId: String?
    /// The scrubbed request text (prompt-safe) and its raw source, held across
    /// the consent gate so the run uses exactly what the reader saw offered.
    private var scrubbedRequest: String?
    /// Where HEAD sat before the run, so a discard restores the clone exactly
    /// and a keep records the correct base commit.
    private var originalHeadCommit: String?
    private var originalHeadRef: String?
    /// The freshly packaged artifact's path, cached across a possible force-quit
    /// consent so the heavy build never runs twice for one relaunch.
    private var packagedArtifactPath: String?

    /// The per-repo build/run recipe DERIVED by reading the clone when the app
    /// was picked (plan §4), cached so the clarification pass and the plan reuse
    /// it without re-deriving. Nil until an eligible app is picked. It is pure
    /// static inspection — reading files only; no command in it has run.
    private var derivedRepoRecipe: RepoRecipe?

    /// The §8 runtime shape of the picked app, taken from `derivedRepoRecipe`.
    /// Feeds the runtime-shape clarification trigger and the honesty rung the
    /// plan expects. Nil until an eligible app is picked.
    private var derivedRuntimeShape: RecipeRuntimeShape?

    /// The reader's selected answers to the clarification batch, keyed by
    /// question id, held until the plan is built so the plan and the later edit
    /// prompt can honor the reader's choices. Not published — the card owns its
    /// own selection UI and submits the whole batch at once.
    private var clarificationAnswersByQuestionId: [String: String] = [:]

    /// The optional seams default INSIDE the `@MainActor` init body rather than
    /// in the parameter list: a default argument referencing a `@MainActor`
    /// static (`.shared`, `defaultPerformOnDemandEdit`) is evaluated in a
    /// nonisolated context, which Swift 6 rejects — resolving them here keeps
    /// the isolation clean.
    init(
        installProvenanceStore: InstallProvenanceStore,
        patchQueue: PatchQueue,
        clonePathLock: MaintainClonePathLock? = nil,
        topRequestsForApp: @escaping (_ appSlug: String) async -> [String] = { _ in [] },
        performOnDemandEdit: (
            (
                _ resolvedClonePath: String,
                _ appSlug: String,
                _ appStack: BreakAppStack,
                _ changeId: String,
                _ scrubbedRequest: String,
                _ kind: OnDemandEditKind
            ) async -> MaintainOnDemandEditResult
        )? = nil
    ) {
        self.installProvenanceStore = installProvenanceStore
        self.patchQueue = patchQueue
        self.clonePathLock = clonePathLock ?? .shared
        self.topRequestsForApp = topRequestsForApp
        self.performOnDemandEdit = performOnDemandEdit ?? Self.defaultPerformOnDemandEdit
    }

    /// The production performer: resolve the reader's own model provider LIVE
    /// (never the funded proxy) and run the jailed on-demand edit through the
    /// shared Tier C engine, build-script edits hard-blocked before the build.
    static let defaultPerformOnDemandEdit: (
        String, String, BreakAppStack, String, String, OnDemandEditKind
    ) async -> MaintainOnDemandEditResult = { resolvedClonePath, appSlug, appStack, changeId, scrubbedRequest, kind in
        guard let provider = MaintainModelProviderResolver.firstAvailable() else {
            return .notEligible(reason: "no model key is available for the edit engine")
        }
        let fixer = MaintainTierCFixer(provider: provider)
        return await fixer.attemptOnDemandEdit(
            clonePath: resolvedClonePath,
            appSlug: appSlug,
            appStack: appStack,
            changeId: changeId,
            request: scrubbedRequest,
            kind: kind
        )
    }

    // MARK: - Step 1: pick an app

    /// The reader chose an installed catalog app to edit (from the apps panel
    /// or the frontmost-app inference). Runs an ADVISORY eligibility check to
    /// decide whether to even offer the describe step — the binding check is
    /// re-run LIVE at start, so a stale positive here can never cause an edit.
    func pickApp(slug: String, name: String, stack: BreakAppStack) {
        resetInFlightState()
        activeAppSlug = slug
        activeAppName = name
        activeAppStack = stack
        classifiedKind = nil
        suggestedRequests = []
        proposedDiffText = nil
        blockedByBuildScriptEdit = false
        lastResult = nil
        clarificationQuestions = []
        presentedPlan = nil

        switch eligibility(forAppSlug: slug, appStack: stack) {
        case .eligible:
            refusalOffersModelKeySetup = false
            // Derive the per-repo build/run recipe by READING the clone (plan
            // §4/§8) so the clarification pass and the plan can reason about how
            // THIS specific app builds and runs — not the coarse catalog stack
            // label. Pure static inspection: it only reads files, executes
            // nothing from the repo, and touches no network. Eligibility already
            // proved this clone path resolves, so a nil here is purely defensive.
            if let clonePath = provenanceClonePath(forAppSlug: slug) {
                let recipe = RepoRecipeService.deriveRecipe(repoRootPath: clonePath)
                derivedRepoRecipe = recipe
                derivedRuntimeShape = recipe.runtimeShape
            }
            phase = .describe
            statusLine = nil
            // Prefill "others also wanted…" while the reader types. Best-effort;
            // an empty pool just means no prefills.
            Task { [weak self] in
                guard let self else { return }
                let requests = await self.topRequestsForApp(slug)
                guard self.activeAppSlug == slug else { return }
                self.suggestedRequests = requests
            }
        case .refused(let reason, let offersModelKeySetup):
            refusalOffersModelKeySetup = offersModelKeySetup
            phase = .notEligible(reason: reason)
            statusLine = reason
        }
    }

    // MARK: - Step 2 & 3: describe the change and classify it

    /// A pure suggestion the UI can use to PRESELECT bug-fix vs feature in the
    /// describe step. The reader's explicit choice always wins — the kind is
    /// never inferred for something that drives the honesty label and the
    /// commit trailer.
    static func suggestedKind(forRequest request: String) -> OnDemandEditKind {
        MaintainFeatureRequests.messageLooksLikeAFeatureWish(request) ? .feature : .bugFix
    }

    /// The reader described the change and explicitly picked its kind. Runs the
    /// UP-FRONT scope estimate (refusing a too-large change here rather than
    /// discovering it at step 12, after the reader waited and spent their key),
    /// scrubs the request on the model-egress path, synthesizes the changeId,
    /// and advances to the clarification pass (plan §7) — which either asks a
    /// couple of decisive questions (`.clarifying`) or goes straight to the
    /// pre-edit plan (`.presentingPlan`) before the start-consent gate. Returns
    /// false (staying in `.describe`, with a `statusLine` reason) when the
    /// request is empty or too large, so the reader can revise it.
    @discardableResult
    func describeRequest(_ rawRequest: String, kind: OnDemandEditKind) -> Bool {
        guard phase == .describe else { return false }
        let trimmed = rawRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusLine = "Tell Iris what you'd like changed first."
            return false
        }
        if OnDemandEditScopeEstimate.requestLooksTooLargeForOneEdit(trimmed) {
            statusLine = "That's a big change — Iris makes small, single edits (a bug fix or one small feature). Try narrowing it to one thing."
            return false
        }

        // Scrub secrets on the SAME egress path all model-bound text uses,
        // BEFORE the request becomes any part of a prompt. The changeId is
        // derived from the further-normalized scrubbed text (path/number/PII
        // stripping), matching the feature-request pooling convention, so the
        // branch key never carries a secret or a home path either.
        let scrubbed = GuideAutopilotOutputBuffer.scrubbed(trimmed)
        let normalizedForIdentity = BreakSignatureService.normalizeMessage(scrubbed)
        let synthesizedChangeId = MaintainTierCFixer.synthesizedChangeId(
            appSlug: activeAppSlug ?? "", normalizedRequest: normalizedForIdentity
        )

        scrubbedRequest = scrubbed
        changeId = synthesizedChangeId
        classifiedKind = kind

        // The clarification pass (plan §7) runs BEFORE any edit and BEFORE the
        // start-consent gate: decide whether Iris must ask a couple of decisive
        // questions first. Two of the four triggers are model-derived
        // (self-consistency ambiguity, an irreversible-action classifier) and
        // are NOT available on this synchronous, no-network path, so they are
        // passed as `false` — a conservative default that never ADDS a refusal
        // versus today and defers those triggers to the loop-upgrade milestone.
        // The two signals Iris can adjudicate statically — an unresolved build
        // recipe and the runtime shape — are wired live from the derived recipe,
        // so the "unknown stack" case now ASKS how to build (turning the old wall
        // into a capability) instead of hard-refusing.
        let clarificationQuestionBatch = FeatureEditClarificationLogic.questions(
            forRequest: scrubbed,
            requestLooksAmbiguous: false,
            recipeIsUnknown: !(derivedRepoRecipe?.hasABuildableRecipe ?? false),
            runtimeShape: derivedRuntimeShape ?? .unknown,
            impliesIrreversibleAction: false
        )

        if clarificationQuestionBatch.isEmpty {
            // Nothing to ask — go straight to the pre-edit plan, then consent.
            buildAndPresentPlan(kind: kind)
        } else {
            clarificationQuestions = clarificationQuestionBatch
            presentedPlan = nil
            phase = .clarifying
            statusLine = "A couple of quick questions before Iris starts."
        }
        return true
    }

    // MARK: - Step 4 & 5: clarify → present plan → approve (plan §7)

    /// The reader answered the clarification batch (plan §7). A "Stop" choice is
    /// an explicit abort — nothing has been touched, so it returns to the
    /// describe step for a revise rather than proceeding with an unclear or
    /// unwanted change. Otherwise it records the answers and builds the pre-edit
    /// plan, advancing to the plan-approval gate.
    func submitClarificationAnswers(_ answersByQuestionId: [String: String]) {
        guard phase == .clarifying, let kind = classifiedKind else { return }
        clarificationAnswersByQuestionId = answersByQuestionId

        // Any option beginning with "Stop" is the reader declining after seeing
        // the question. The safe, additive response is to make NOTHING happen
        // and hand control back — never to proceed on an ambiguous or refused
        // change. (The clarification options are a fixed, code-authored set, so
        // matching their "Stop…" prefix is a reliable signal, not a guess.)
        let readerChoseToStop = answersByQuestionId.values.contains { selectedOption in
            selectedOption.lowercased().hasPrefix("stop")
        }
        if readerChoseToStop {
            clarificationQuestions = []
            phase = .describe
            statusLine = "Stopped — nothing was changed. Revise your request, or pick a different app."
            return
        }

        buildAndPresentPlan(kind: kind)
    }

    /// Build the short pre-edit PLAN (plan §7) from the derived recipe, the
    /// runtime shape, and the reader's request, and show it for approval. The
    /// plan is informational: the single binding safety gate is still
    /// `confirmStartAndRun()`, reached only when the reader approves the plan.
    private func buildAndPresentPlan(kind: OnDemandEditKind) {
        let appName = activeAppName ?? (activeAppSlug ?? "this app")
        let requestText = scrubbedRequest ?? "the requested change"
        let verb = kind == .feature ? "add this feature to" : "fix this in"

        presentedPlan = FeatureEditPlan(
            // An honest empty estimate: the loop's offline repo map fills the
            // real file list, and the diff-scope gate is the hard cap downstream.
            filesToTouch: [],
            approachSummary: "Iris will \(verb) \(appName): “\(requestText)”. It makes the "
                + "smallest change that does it, on a new branch under your own model key, "
                + "then verifies it before showing you the diff.",
            resolvedRecipeSummary: recipeSummaryText(derivedRepoRecipe),
            // The clarification round (if any) was already answered in the
            // `.clarifying` step, so nothing is left open at plan time.
            openQuestions: [],
            expectedRung: expectedRungText(
                recipe: derivedRepoRecipe,
                runtimeShape: derivedRuntimeShape ?? .unknown,
                kind: kind
            )
        )
        clarificationQuestions = []
        phase = .presentingPlan
        statusLine = "Here's Iris's plan — review it, then start."
    }

    /// The reader approved the pre-edit plan (Consent #1, plan §7's "ask once,
    /// then commit"). This advances to the start-consent gate and immediately
    /// runs it, so the LIVE eligibility re-check + per-clonePath lock in
    /// `confirmStartAndRun()` — the single binding safety gate — still run
    /// exactly as before. Approving the plan never bypasses them.
    func confirmPlanAndStart() {
        guard phase == .presentingPlan, let kind = classifiedKind else { return }
        phase = .awaitingStartConsent
        statusLine = startConsentPrompt(kind: kind)
        confirmStartAndRun()
    }

    /// The derived recipe in reader-facing words for the plan card, so approving
    /// the plan is informed consent to what will later run un-jailed. Honest
    /// about unresolved fields ("Iris couldn't work out how to build it")
    /// instead of inventing a command.
    private func recipeSummaryText(_ recipe: RepoRecipe?) -> String {
        guard let recipe else {
            return "Iris couldn't derive how this app builds from its source."
        }
        var summaryParts: [String] = ["Detected stack: \(recipe.ecosystemIdentifier)."]
        if let build = recipe.build {
            summaryParts.append("Build: `\(build.commandLine)`.")
        } else if let install = recipe.install {
            summaryParts.append("Prepare: `\(install.commandLine)` (no separate build step).")
        } else {
            summaryParts.append("Build: Iris couldn't work out how to build it — it'll ask you.")
        }
        if let test = recipe.test {
            summaryParts.append("Tests: `\(test.commandLine)`.")
        } else {
            summaryParts.append("Tests: this app has no test suite Iris can run.")
        }
        return summaryParts.joined(separator: " ")
    }

    /// The §9 evidence-ladder rung the plan honestly expects to reach, from the
    /// runtime shape (ratified 5a: L2 for pure-local, L5 for anything with a
    /// server/persistence/tenancy) tempered by whether there is a suite to run
    /// at all. Stated up front so the reader knows the verification bar BEFORE
    /// approving the edit. `kind` is accepted so a later slice can lower a
    /// feature's ceiling (a feature can never be "verified") without changing
    /// this signature.
    private func expectedRungText(
        recipe: RepoRecipe?,
        runtimeShape: RecipeRuntimeShape,
        kind: OnDemandEditKind
    ) -> String {
        // With no test suite the ladder cannot clear "no regression", so it is
        // honestly capped at "builds".
        if recipe?.test == nil {
            return "L1 — builds (this app has no test suite, so Iris can't prove no regression automatically)."
        }
        switch runtimeShape {
        case .pureLocalApp:
            return "L2 — builds and the existing test suite stays green."
        case .localSingleInstanceService, .builtForScale:
            return "L5 — builds, tests stay green, and the app boots exercising the change (a server or persistence change earns the higher bar)."
        case .unknown:
            return "to be decided once you confirm how this app runs."
        }
    }

    /// The exact one line the start-consent card shows above its single tap. It
    /// names the app, the clone path, and that the reader's OWN key pays for it,
    /// so consent is informed.
    private func startConsentPrompt(kind: OnDemandEditKind) -> String {
        let appName = activeAppName ?? "this app"
        let clone = resolvedClonePath ?? provenanceClonePath(forAppSlug: activeAppSlug ?? "") ?? "its source clone"
        let verb = kind == .feature ? "add this feature to" : "fix this in"
        return "Iris will \(verb) the local source of \(appName) at \(clone) on a new branch, using your own model key. Nothing is pushed or relaunched. Continue?"
    }

    // MARK: - Step 6: start consent → run

    /// Consent #1: the reader tapped "start". This is where every rail is
    /// checked LIVE and, if all pass, the jailed loop runs. There is no
    /// throttle — the reader initiated this, so the ask-limiter that guards
    /// against AI nagging is deliberately absent.
    func confirmStartAndRun() {
        guard phase == .awaitingStartConsent,
              let slug = activeAppSlug,
              let stack = activeAppStack,
              let scrubbed = scrubbedRequest,
              let editChangeId = changeId,
              let kind = classifiedKind else { return }

        // 1) Re-check eligibility LIVE — a cached render flag is advisory only,
        //    and `.git` can have been deleted/moved since the offer.
        switch eligibility(forAppSlug: slug, appStack: stack) {
        case .refused(let reason, let offersModelKeySetup):
            refusalOffersModelKeySetup = offersModelKeySetup
            phase = .notEligible(reason: reason)
            statusLine = reason
            return
        case .eligible:
            refusalOffersModelKeySetup = false
            break
        }

        // The resolved, home-contained path every later step keys off. The
        // eligibility check above already proved this resolves; unwrap safely.
        guard let clonePath = provenanceClonePath(forAppSlug: slug),
              let resolved = try? GitInspectionService.allowedRepositoryPath(clonePath) else {
            phase = .notEligible(reason: "this install is no longer a source clone Iris may edit")
            statusLine = phaseReason
            return
        }

        // 2) Structural refusal: never edit Iris's own repository (a misresolved
        //    clonePath, plus the AGENTS.md "no xcodebuild from a terminal" rule
        //    that would invalidate Iris's own TCC grants).
        guard !resolvedPathTargetsIrisItself(resolved) else {
            phase = .notEligible(reason: "Iris won't edit its own source")
            statusLine = phaseReason
            return
        }

        // 3) Take the per-clonePath lock: refuse if the crash-incident path or
        //    another on-demand edit already holds this repo, so two `.git`
        //    strips / reverts can never race the working tree.
        guard clonePathLock.tryAcquire(clonePath: resolved, owner: "on-demand:\(slug)") else {
            let holder = clonePathLock.currentOwner(ofClonePath: resolved) ?? "another task"
            phase = .failed(reason: "Iris is already working on \(activeAppName ?? slug) (\(holder)). Try again once that finishes.")
            statusLine = phaseReason
            return
        }
        resolvedClonePath = resolved

        phase = .running
        statusLine = "Working on it under your model key…"
        editRunner.beginRun(appName: activeAppName ?? slug, kind: kind)

        Task { [weak self] in
            guard let self else { return }
            await self.runEdit(
                resolvedClonePath: resolved, slug: slug, stack: stack,
                changeId: editChangeId, scrubbedRequest: scrubbed, kind: kind
            )
        }
    }

    /// Owns the run itself: the dirty-tree refusal, the base-commit capture, the
    /// engine call, and mapping the engine result to phase + narration. The lock
    /// is released on every exit EXCEPT a successful preview (where it stays held
    /// until the reader keeps or discards).
    private func runEdit(
        resolvedClonePath: String,
        slug: String,
        stack: BreakAppStack,
        changeId editChangeId: String,
        scrubbedRequest scrubbed: String,
        kind: OnDemandEditKind
    ) async {
        guard let runner = try? MaintainShellRunner(repoRootPath: resolvedClonePath) else {
            failRun(reason: "the clone path is not usable", resolvedClonePath: resolvedClonePath)
            return
        }

        // Refuse a DIRTY tree outright: the engine reverts on failure with
        // `git clean -fd`, which would delete the reader's own untracked files
        // and revert their uncommitted edits. Starting from a clean tree is what
        // makes that revert safe (it can then only ever clean files Iris made).
        let status = try? await runner.run("git status --porcelain", deadline: 60)
        let treeIsDirty = (status?.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if treeIsDirty {
            editRunner.note("Your clone of \(activeAppName ?? slug) has uncommitted changes, so Iris stopped — it never discards work you haven't committed.")
            editRunner.finishStopped()
            failRun(
                reason: "your clone has uncommitted changes — commit or stash them first so Iris never touches your own work",
                resolvedClonePath: resolvedClonePath
            )
            return
        }

        // Capture the base so a discard restores the clone exactly and a keep
        // records the correct base commit for the patch queue's replay.
        originalHeadCommit = (try? await runner.run("git rev-parse HEAD", deadline: 30))?
            .outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        originalHeadRef = (try? await runner.run("git rev-parse --abbrev-ref HEAD", deadline: 30))?
            .outputTail.trimmingCharacters(in: .whitespacesAndNewlines)

        editRunner.note("Locating the relevant source and making the smallest change that does it…")

        let startedAt = Date()
        let result = await performOnDemandEdit(
            resolvedClonePath, slug, stack, editChangeId, scrubbed, kind
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        editRunner.setWorking(false)
        lastResult = result

        switch result {
        case .appliedAndRebuilt(let branchName, _, _, let suitePassed):
            committedBranchName = branchName
            editRunner.recordVerificationResult(passed: true, over: elapsed)
            editRunner.note(verificationNote(suitePassed: suitePassed, kind: kind))
            editRunner.finishApplied()
            proposedDiffText = await readCommittedDiff(runner: runner)
            phase = .previewDiff
            statusLine = "Here's the change on branch \(branchName). Keep it?"
            // Lock stays held: the reader may still discard, which touches the
            // tree; it is released in keepChange() / discardChange().

        case .couldNotComplete(let reason):
            let mapped = mappedFailure(reason: reason)
            blockedByBuildScriptEdit = mapped.wasBuildScriptBlock
            editRunner.recordVerificationResult(passed: false, over: elapsed)
            editRunner.note(mapped.userFacing)
            editRunner.finishStopped()
            failRun(reason: mapped.userFacing, resolvedClonePath: resolvedClonePath)

        case .notEligible(let reason):
            editRunner.note("Iris couldn't start the edit: \(reason).")
            editRunner.finishStopped()
            clonePathLock.release(clonePath: resolvedClonePath)
            self.resolvedClonePath = nil
            phase = .notEligible(reason: reason)
            statusLine = reason
        }
    }

    // MARK: - Step 9: preview → keep or discard

    /// Consent #2 (keep): the reader accepted the diff. Record the patch so an
    /// upstream update can replay it, then either offer the DESTRUCTIVE relaunch
    /// (Consent #3, when this app can be rebuilt+relaunched) or finish with the
    /// honest manual "Relaunch <App> yourself" the crash path uses.
    func keepChange() {
        guard phase == .previewDiff,
              let branchName = committedBranchName,
              let slug = activeAppSlug,
              let editChangeId = changeId else { return }
        phase = .committing

        // Record into the patch queue keyed by the changeId (there is no pooled
        // recipe for a user request, so the changeId serves as the recipe id),
        // so when the app updates the edit can be replayed on the new base.
        patchQueue.record(QueuedPatch(
            recipeId: editChangeId,
            signatureId: editChangeId,
            appSlug: slug,
            branchName: branchName,
            patchText: proposedDiffText ?? "",
            baseCommit: originalHeadCommit,
            appliedAt: Date()
        ))

        let appName = activeAppName ?? slug
        let kindWord = classifiedKind == .feature ? "change" : "fix"

        // Offer the rebuild+relaunch only when this app can honestly be
        // relaunched (Option A: a real macBundleId AND a stack that produces a
        // launchable macOS artifact). Otherwise finish with the manual message
        // and release the lock now — there is no packaging step to protect.
        if relaunchIsAvailableForApp?(slug) == true, packageEditedAppFromClone != nil {
            // Keep the per-clonePath lock HELD through the relaunch: packaging
            // builds inside the clone, and the incident path must not strip
            // `.git` under it. It is released on every relaunch terminal path.
            statusLine = "Applied your \(kindWord) on branch \(branchName). Relaunch \(appName) now to run your edited build?"
            phase = .awaitingRelaunchConsent
        } else {
            // A feature is "applied and rebuilt", NEVER "verified" — the engine
            // structurally cannot elevate it, and the copy must not either.
            statusLine = "Applied your \(kindWord) on branch \(branchName). Relaunch \(appName) to pick it up."
            releaseLockIfHeld()
            phase = .done
        }
    }

    // MARK: - Step 11: rebuild → relaunch (Consent #3, DESTRUCTIVE)

    /// The exact destructive-consent line the relaunch card shows. It is honest
    /// that quitting loses unsaved work AND that a from-source build may lose the
    /// signed app's permission grants — both real costs the reader is consenting
    /// to.
    var relaunchConsentPrompt: String {
        let appName = activeAppName ?? "this app"
        return "This quits \(appName) — any unsaved work is lost — and opens your edited build. It's a fresh build straight from your source, so macOS may ask you to allow its permissions again. Relaunch now?"
    }

    /// Consent #3: the reader approved the destructive relaunch. Package the
    /// fresh build FIRST (terminating nothing), and only if a launchable artifact
    /// exists, terminate the running app and launch the edited build. This path
    /// is UNVERIFIED until run on a real machine with a real source-clone app.
    func confirmRelaunch() {
        guard phase == .awaitingRelaunchConsent,
              let slug = activeAppSlug,
              let package = packageEditedAppFromClone,
              let relaunch = terminateAndRelaunchEditedApp else { return }
        phase = .relaunching
        statusLine = "Building a runnable copy of \(activeAppName ?? slug)…"
        Task { [weak self] in
            guard let self else { return }
            // 1) Package + assert the artifact exists. Nothing is terminated yet.
            let packaging = await package(slug)
            guard case .artifactReady(let artifactPath) = packaging else {
                self.finishRelaunchWithoutTerminating(fromPackaging: packaging)
                return
            }
            self.packagedArtifactPath = artifactPath
            // 2) Terminate the running app (graceful only) and launch the fresh
            //    build. A refusal to quit surfaces the force-quit consent.
            self.statusLine = "Quitting \(self.activeAppName ?? slug) and opening your edited build…"
            let launch = await relaunch(slug, artifactPath, false)
            self.applyRelaunchLaunchResult(launch, allowedForceQuit: false)
        }
    }

    /// The reader declined the relaunch (Consent #3 denied). The change stays
    /// safely on the branch; finish with the manual message and release the lock.
    func skipRelaunch() {
        guard phase == .awaitingRelaunchConsent,
              let branchName = committedBranchName else { return }
        let appName = activeAppName ?? (activeAppSlug ?? "the app")
        statusLine = "Kept on branch \(branchName). Relaunch \(appName) yourself when you're ready to pick it up."
        releaseLockIfHeld()
        packagedArtifactPath = nil
        phase = .done
    }

    /// The exact second-consent line when the app won't quit — honest that force
    /// quitting mid-save can corrupt the app's own data, not merely discard
    /// unsaved edits.
    var forceQuitConsentPrompt: String {
        let appName = activeAppName ?? "the app"
        return "\(appName) is asking to save your work and won't quit. Force quit anyway? Unsaved work is lost, and force-quitting mid-save can corrupt its data."
    }

    /// Consent #3b: the reader approved force-quitting. Reuse the already-built
    /// artifact (never re-package) and try once more, this time allowed to
    /// `forceTerminate`.
    func confirmForceQuitAndRelaunch() {
        guard phase == .awaitingForceQuitConsent,
              let slug = activeAppSlug,
              let artifactPath = packagedArtifactPath,
              let relaunch = terminateAndRelaunchEditedApp else { return }
        phase = .relaunching
        statusLine = "Force quitting \(activeAppName ?? slug) and opening your edited build…"
        Task { [weak self] in
            guard let self else { return }
            let launch = await relaunch(slug, artifactPath, true)
            self.applyRelaunchLaunchResult(launch, allowedForceQuit: true)
        }
    }

    /// The reader declined the force quit. Leave the running app alone; the edit
    /// is safe on the branch. Finish honestly and release the lock.
    func skipForceQuitAndKeepRunningApp() {
        guard phase == .awaitingForceQuitConsent,
              let branchName = committedBranchName else { return }
        let appName = activeAppName ?? (activeAppSlug ?? "the app")
        statusLine = "Left \(appName) running. Your change is on branch \(branchName) — quit \(appName) and relaunch it yourself to pick it up."
        releaseLockIfHeld()
        packagedArtifactPath = nil
        phase = .done
    }

    /// Map a packaging result that did NOT reach the terminate step (nothing was
    /// quit) to an honest terminal state. The change is always still safe on the
    /// branch.
    private func finishRelaunchWithoutTerminating(fromPackaging packaging: AppRelaunchPackagingResult) {
        let branchName = committedBranchName ?? "the branch"
        let appName = activeAppName ?? (activeAppSlug ?? "the app")
        let detail: String
        switch packaging {
        case .artifactReady:
            // Not reachable here — this helper is only for the non-ready cases.
            detail = ""
        case .stackHasNoRelaunchableArtifact(let reason):
            detail = reason
        case .packagingFailed(let reason):
            detail = reason
        case .ineligible(let reason):
            detail = reason
        }
        statusLine = "Your change is safe on branch \(branchName), but Iris couldn't build a runnable copy of \(appName) (\(detail)). Nothing was quit — relaunch \(appName) yourself once it builds."
        releaseLockIfHeld()
        packagedArtifactPath = nil
        phase = .done
    }

    /// Map a launch result to phase + copy. The only non-terminal case is
    /// "wouldn't quit", which routes to the force-quit consent (lock held).
    private func applyRelaunchLaunchResult(
        _ result: AppRelaunchLaunchResult, allowedForceQuit: Bool
    ) {
        let appName = activeAppName ?? (activeAppSlug ?? "the app")
        let branchName = committedBranchName ?? "the branch"
        switch result {
        case .relaunchedFreshBuild:
            statusLine = "Your edited build of \(appName) is running — a fresh build straight from your source, so macOS may ask you to re-grant its permissions. The change is on branch \(branchName)."
            releaseLockIfHeld()
            packagedArtifactPath = nil
            phase = .done
        case .runningAppWouldNotQuit:
            // Only reachable on the graceful (non-force) attempt. Ask before
            // anything is killed — the app is still up and unharmed.
            statusLine = forceQuitConsentPrompt
            phase = .awaitingForceQuitConsent
        case .launchFailedPriorAppRestored(let reason):
            statusLine = "Iris couldn't finish the relaunch (\(reason)). Your change is safe on branch \(branchName) — relaunch \(appName) yourself to pick it up."
            releaseLockIfHeld()
            packagedArtifactPath = nil
            phase = .done
        case .ineligible(let reason):
            statusLine = "Iris couldn't relaunch \(appName) (\(reason)). Your change is safe on branch \(branchName)."
            releaseLockIfHeld()
            packagedArtifactPath = nil
            phase = .done
        }
    }

    // MARK: - Publish to publik (D6: separate, explicit, EVERY-TIME consent)

    /// Ask to publish this kept change to publik's PUBLIC surface. This does NOT
    /// publish — it raises an explicit confirm, because every public write needs
    /// its own every-time consent, never remembered and never folded into the
    /// fork backup. Only meaningful for a kept change while `.done`.
    func requestPublishToPublik() {
        guard phase == .done, committedBranchName != nil, proposedDiffText != nil else { return }
        isAwaitingPublishConsent = true
    }

    /// The reader backed out of the publish confirm. Nothing was written.
    func cancelPublishToPublik() {
        isAwaitingPublishConsent = false
    }

    /// The reader explicitly confirmed the public publish (this exact time).
    /// Records the change to publik's public fix log and, for a feature, marks
    /// the pooled request implemented — behind this one consent only.
    func confirmPublishToPublik() {
        guard phase == .done,
              isAwaitingPublishConsent,
              let slug = activeAppSlug,
              let kind = classifiedKind,
              let publish = publishEditToPublik else {
            isAwaitingPublishConsent = false
            return
        }
        isAwaitingPublishConsent = false
        let requestSummary = scrubbedRequest ?? "a user-requested change"
        Task { [weak self] in
            guard let self else { return }
            if let summary = await publish(slug, kind, requestSummary) {
                self.statusLine = (self.statusLine ?? "") + " \(summary)."
            } else {
                self.statusLine = (self.statusLine ?? "") + " (Publishing wasn't available — nothing was posted.)"
            }
        }
    }

    /// Consent #2 (discard): the reader rejected the diff. Restore the clone to
    /// exactly where it was and delete the branch, so nothing Iris did survives.
    func discardChange() {
        guard phase == .previewDiff,
              let branchName = committedBranchName,
              let resolved = resolvedClonePath else { return }
        phase = .committing
        Task { [weak self] in
            guard let self else { return }
            if let runner = try? MaintainShellRunner(repoRootPath: resolved) {
                let restore = (self.originalHeadRef.map { $0 != "HEAD" } == true)
                    ? "git checkout '\(self.originalHeadRef!)' --quiet"
                    : "git checkout '\(self.originalHeadCommit ?? "HEAD")' --quiet"
                _ = try? await runner.run(
                    "\(restore) 2>/dev/null; git branch -D '\(branchName)' --quiet 2>/dev/null || true",
                    deadline: 120
                )
            }
            self.editRunner.note("Discarded — your clone is back exactly as it was.")
            self.editRunner.finishStopped()
            self.releaseLockIfHeld()
            self.proposedDiffText = nil
            self.committedBranchName = nil
            self.statusLine = "Discarded — nothing was kept, your clone is untouched."
            self.phase = .done
        }
    }

    // MARK: - Step 13: offer the edit upstream (fork-only, explicit)

    /// Back the kept branch up to the reader's OWN fork. Fork-only by
    /// construction — never a push-merge to a third party's canonical repo, and
    /// never automatic. A nil summary (backup unavailable / not connected) is
    /// not an error: the edit is safe on the local branch regardless.
    func requestForkBackup() {
        guard phase == .done,
              let branchName = committedBranchName,
              let slug = activeAppSlug,
              let backUp = backUpEditBranchToMyForkOnly else {
            statusLine = "Backup isn't set up — your edit is safe on the local branch."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let summary = await backUp(branchName, slug) {
                self.statusLine = (self.statusLine ?? "") + " \(summary)."
            } else {
                self.statusLine = (self.statusLine ?? "") + " (Backup wasn't available — the edit is safe locally.)"
            }
        }
    }

    // MARK: - Cancel / reset

    /// The reader backed out before the run completed. Releases the lock if the
    /// run had taken it, and returns to the app-picker.
    func cancel() {
        releaseLockIfHeld()
        resetInFlightState()
        phase = .pickApp
        statusLine = nil
        activeAppSlug = nil
        activeAppName = nil
        activeAppStack = nil
        classifiedKind = nil
        suggestedRequests = []
        proposedDiffText = nil
        blockedByBuildScriptEdit = false
        refusalOffersModelKeySetup = false
        lastResult = nil
        isAwaitingPublishConsent = false
        clarificationQuestions = []
        presentedPlan = nil
    }

    // MARK: - Eligibility (fail-closed)

    private enum Eligibility {
        case eligible
        /// `offersModelKeySetup` is true only for the missing-key refusal — the
        /// one a reader clears by connecting a model in settings. Every other
        /// refusal leaves it false, so the card never offers a settings tap that
        /// would not actually fix the problem.
        case refused(reason: String, offersModelKeySetup: Bool = false)
    }

    /// Every gate the design ratified, evaluated LIVE against the world right
    /// now. Any miss is an honest, user-safe refusal — never a silent bypass.
    private func eligibility(forAppSlug appSlug: String, appStack: BreakAppStack) -> Eligibility {
        // Provenance: guide-source clone with a live `.git`. Signed download or
        // unknown fails closed.
        guard installProvenanceStore.localPatchingIsPermitted(forAppSlug: appSlug) else {
            return .refused(reason: "Iris can only edit apps you installed from source with a publik guide — this one isn't one.")
        }
        // The stricter path check the store's bare `.git`-exists test skips:
        // symlink-resolved, inside $HOME, not $HOME itself.
        guard let clonePath = provenanceClonePath(forAppSlug: appSlug),
              (try? GitInspectionService.allowedRepositoryPath(clonePath)) != nil else {
            return .refused(reason: "this app's source clone isn't in a location Iris may edit.")
        }
        // A BYO model key: nil is the honest funded-tier ceiling. Iris never
        // routes an on-demand edit around it onto the funded proxy. This is the
        // one refusal the reader can clear themselves in a tap, so the copy
        // explains WHY editing needs a key (chat is funded, editing real code is
        // not) rather than reading as an accusation — and the card offers a
        // button straight into settings, driven by `refusalOffersModelKeySetup`.
        guard MaintainModelProviderResolver.firstAvailable() != nil else {
            return .refused(
                reason: "Editing an app changes its real code, which runs on your own model key — not the funded tier that covers chat. Connect a model in settings to turn this on.",
                offersModelKeySetup: true
            )
        }
        // The Seatbelt jail every model-authored command runs inside.
        guard MaintainSandbox.isAvailable else {
            return .refused(reason: "the sandbox Iris edits inside isn't available on this machine.")
        }
        // A real rebuild recipe for this stack. `.other` / swiftMacOS have no
        // build vocabulary, and an Electron/Next.js repo with no build script
        // fails here too — the honest MVP posture is to refuse up front rather
        // than run a jailed loop whose result could never be verified/built.
        guard stackHasARealRebuildRecipe(appStack, clonePath: clonePath) else {
            return .refused(reason: "Iris doesn't yet know how to rebuild this kind of app safely.")
        }
        return .eligible
    }

    /// True when Iris knows a real way to rebuild this repo — computed LIVE.
    ///
    /// Primary path (plan §4): DERIVE a per-repo recipe by reading the actual
    /// clone. `RepoRecipeService.hasBuildableRecipe` is true whenever the repo
    /// has a resolvable build OR install command — which retires the coarse
    /// "unknown stack" wall for the vast majority of repos (an interpreted stack
    /// with install-but-no-build is still perfectly rebuildable).
    ///
    /// Fallback ONLY (never removed, so nothing that was eligible before becomes
    /// ineligible now): the original catalog-stack verification vocabulary. Any
    /// app that the old lookup could build stays buildable here — the derivation
    /// only ever ADDS stacks, it never subtracts one — and an app that clears
    /// eligibility solely on this fallback (the recipe stayed unknown) is exactly
    /// the case the clarification pass (§7) then asks how to build.
    private func stackHasARealRebuildRecipe(_ stack: BreakAppStack, clonePath: String) -> Bool {
        if RepoRecipeService.hasBuildableRecipe(repoRootPath: clonePath) {
            return true
        }
        return VerificationCommands.defaults(for: stack, repoRootPath: clonePath).buildCommand != nil
    }

    // MARK: - Helpers

    private func provenanceClonePath(forAppSlug appSlug: String) -> String? {
        installProvenanceStore.provenance(forAppSlug: appSlug)?.clonePath
    }

    /// Never edit Iris's own repository. Refuses when the running app bundle (or
    /// its executable) lives inside the clone, or when the resolved path is
    /// obviously the Iris source tree — a defense-in-depth structural guard
    /// against a misresolved clonePath, on top of the catalog-only provenance
    /// that already keeps Iris out of its own listing.
    private func resolvedPathTargetsIrisItself(_ resolvedClonePath: String) -> Bool {
        let cloneComponents = URL(fileURLWithPath: resolvedClonePath).pathComponents
        // The Iris source tree's own directory names — a clonePath that
        // resolves into them is a misresolution, not a catalog app.
        if cloneComponents.contains("iris-macos") || cloneComponents.contains("leanring-buddy") {
            return true
        }
        // The running app bundle / executable living under the clone means the
        // clone IS (or contains) the running Iris — never touch it.
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
            .resolvingSymlinksInPath().standardizedFileURL
        let cloneURL = URL(fileURLWithPath: resolvedClonePath).standardizedFileURL
        if GitInspectionService.isPath(bundleURL, containedInDirectory: cloneURL) {
            return true
        }
        if let executableURL = Bundle.main.executableURL?.resolvingSymlinksInPath().standardizedFileURL,
           GitInspectionService.isPath(executableURL, containedInDirectory: cloneURL) {
            return true
        }
        return false
    }

    /// The committed edit's real diff, for the preview gate. The engine leaves
    /// the clone checked out on the new branch with the edit as HEAD, so the
    /// change is HEAD against its parent. Capped so a large diff can't flood the
    /// card.
    private func readCommittedDiff(runner: MaintainShellRunner) async -> String {
        guard let result = try? await runner.run("git --no-pager diff HEAD~1 HEAD", deadline: 60),
              !result.outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "(Iris committed the change but couldn't render the diff — it's on the branch.)"
        }
        return String(result.outputTail.prefix(20_000))
    }

    /// Iris's honest one-liner after verification. A feature is "applied and
    /// rebuilt", never "verified"; a suite that didn't run (no test command) is
    /// said plainly, never counted as a silent green.
    private func verificationNote(suitePassed: Bool?, kind: OnDemandEditKind) -> String {
        let subject = kind == .feature ? "The feature is implemented" : "The fix is in"
        switch suitePassed {
        case .some(true):
            return "\(subject) — it builds and the app's test suite stays green. Applied and rebuilt (not \"verified\": there's no automatic test that proves it does what you asked)."
        case .some(false):
            // Reachable only defensively — the engine would have blocked here.
            return "\(subject), but the suite didn't pass — Iris stopped."
        case .none:
            return "\(subject) — it builds. This app has no test suite for Iris to run, so it's applied and rebuilt, not verified — try the relaunched app to confirm it does what you asked."
        }
    }

    /// Maps the engine's internal failure reason to an honest, distinct
    /// user-facing message — separating "too large / out of budget" and a
    /// blocked build-script edit from a generic verification failure, so the
    /// reader knows whether to narrow the request, and so a burnt loop budget
    /// reads differently from an attempt that genuinely failed.
    private func mappedFailure(reason: String) -> (userFacing: String, wasBuildScriptBlock: Bool) {
        if reason.contains("build-script") {
            return ("This change would edit files that run during the build (like build.rs or package.json scripts), which Iris won't run unreviewed — it stopped before building. Nothing changed.", true)
        }
        if reason.contains("ran out of steps") {
            return ("This turned out to be too large for Iris to finish in its budget — nothing was applied. Try a smaller, more specific change.", false)
        }
        if reason.contains("changed nothing") {
            return ("Iris couldn't find a change to make for that — nothing was applied.", false)
        }
        if reason.contains("failed verification") {
            return ("Iris made a change but it didn't build or pass the tests, so it reverted everything. Nothing changed.", false)
        }
        return ("Iris couldn't complete that edit — nothing changed. (\(reason))", false)
    }

    private func failRun(reason: String, resolvedClonePath: String) {
        clonePathLock.release(clonePath: resolvedClonePath)
        self.resolvedClonePath = nil
        phase = .failed(reason: reason)
        statusLine = reason
    }

    private func releaseLockIfHeld() {
        if let resolved = resolvedClonePath {
            clonePathLock.release(clonePath: resolved)
            resolvedClonePath = nil
        }
    }

    /// The reason string carried by the current terminal phase, for `statusLine`
    /// mirroring.
    private var phaseReason: String? {
        switch phase {
        case .failed(let reason), .notEligible(let reason): return reason
        default: return statusLine
        }
    }

    private func resetInFlightState() {
        committedBranchName = nil
        changeId = nil
        scrubbedRequest = nil
        originalHeadCommit = nil
        originalHeadRef = nil
        packagedArtifactPath = nil
        derivedRepoRecipe = nil
        derivedRuntimeShape = nil
        clarificationAnswersByQuestionId = [:]
        // resolvedClonePath is only cleared alongside a lock release, so a lock
        // is never orphaned by a reset mid-run.
    }
}

// MARK: - Up-front scope estimate

/// A conservative, pure pre-flight guess at whether a request is too large for
/// one jailed edit (≤12 files, ≤12 loop steps, 1200 output tokens/step). It
/// refuses the obviously-broad up front — rather than letting the reader wait
/// through a run that hits the step cap mid-implementation and reverts — while
/// staying conservative so it never blocks a legitimate small edit. It only
/// reads the text; it never runs the model.
enum OnDemandEditScopeEstimate {

    static func requestLooksTooLargeForOneEdit(_ request: String) -> Bool {
        // Three or more enumerated items reads as a batch of changes, not one.
        if enumeratedItemCount(in: request) >= 3 { return true }
        // Several distinct asks conjoined into one sentence.
        if conjoinedAskCount(in: request.lowercased()) >= 2 { return true }
        // A very long free-text request is a proxy for a broad change; the
        // engine only forwards the first 3000 chars to the model anyway.
        if request.count > 1200 { return true }
        return false
    }

    private static func enumeratedItemCount(in request: String) -> Int {
        regularExpressionMatchCount(
            pattern: #"(?m)^\s*(?:\d+[\.\)]|[-*•])\s+\S"#, in: request
        )
    }

    private static func conjoinedAskCount(in loweredRequest: String) -> Int {
        var count = 0
        for connector in [" and also ", " as well as ", "; also ", " plus also ", " and then also "] {
            count += occurrenceCount(of: connector, in: loweredRequest)
        }
        return count
    }

    private static func occurrenceCount(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func regularExpressionMatchCount(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
