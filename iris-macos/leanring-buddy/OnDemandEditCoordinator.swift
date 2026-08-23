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
    /// The model declared a manifest change (a dependency, a plist key, an
    /// entitlement) it cannot write itself; the run is paused on the reader's
    /// Allow/Decline before Iris's own code applies it and builds with it.
    /// `pendingManifestChangeSummary` is the one sentence to decide on.
    case awaitingManifestConsent
    /// FULLY AUTOMATIC delivery (founder decision, Aug 22 2026): the change is
    /// applied, so Iris is recording it, rebuilding the app from the clone
    /// (signed with a stable identity when one exists), and relaunching it —
    /// no keep/relaunch taps in between. The reader's own complaint is then
    /// re-checked in `.awaitingSymptomConfirmation`.
    case delivering
    /// The rebuilt app is running with the change. Iris re-gathered the
    /// app's window + logs and now asks the reader the only question that
    /// matters — is the thing you complained about actually fixed? — with an
    /// undo available. The verdict is written into the run log, the memory
    /// record, and the commit.
    case awaitingSymptomConfirmation
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
    /// The model itself declared, after investigating, that the change cannot
    /// be made under the harness's constraints — its sentence verbatim.
    /// Everything was reverted. The card offers "Answer and retry" when the
    /// model asked a question (`blockedQuestionForUser`). Terminal.
    case blockedByModel(explanation: String)
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

    /// True while the request probe (the two model-derived §7 triggers —
    /// self-consistency ambiguity and the irreversible-action classifier) runs
    /// between the reader's Continue tap and the clarify-or-plan step. The
    /// describe card shows a working line and holds the Continue button while
    /// this is up; the flow stays in `.describe` so a slow probe never strands
    /// the reader outside their own text field.
    @Published private(set) var isAssessingRequest: Bool = false

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

    /// True when the terminal failure was a temporary rate limit (a shared
    /// Claude Code login hitting its rolling limit), so the failed card reads
    /// calmly and offers a one-tap "Try again" instead of the red alarm.
    @Published private(set) var failureWasRateLimit: Bool = false

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

    /// The one-sentence summary of the manifest change the model declared,
    /// shown on the consent card while `phase == .awaitingManifestConsent`.
    @Published private(set) var pendingManifestChangeSummary: String?
    /// The engine's await on the reader's Allow/Decline.
    private var manifestConsentContinuation: CheckedContinuation<Bool, Never>?

    /// The scrubbed request text of the current flow, published so the
    /// symptom re-check card can show the reader THEIR OWN complaint verbatim
    /// next to the verdict buttons.
    @Published private(set) var activeRequestText: String?

    /// How the rebuilt app was signed ("signed with Developer ID …" or the
    /// honest ad-hoc warning that permissions may reset), for the symptom card.
    @Published private(set) var freshBuildSigningSummary: String?

    /// Packaging-metadata checks that FAILED on the built artifact (a plist key
    /// or entitlement the run claimed to add is missing from the bundle).
    /// Empty when everything the run promised reached the app.
    @Published private(set) var packagingMetadataFailures: [String] = []

    /// The manifest change Iris applied this run (after the reader allowed
    /// it), kept so packaging can verify it reached the built app.
    private var appliedManifestChangeRequest: MaintainManifestChangeRequest?

    /// After the relaunch, what Iris observed when it looked again: a
    /// one-line summary for the symptom card ("no new crash report; window
    /// captured" / "a NEW crash report appeared since the relaunch").
    @Published private(set) var symptomRecheckSummary: String?

    /// Text the describe field should be prefilled with on the next show —
    /// a retry seeded from a still-broken verdict, or a blocked question's
    /// answer folded into the original request. The card consumes it.
    @Published private(set) var describePrefillText: String?

    /// True after a "still broken" verdict, so the done card can offer
    /// "Try again with what Iris learned" (the memory record carries the
    /// negative verdict into the next run).
    @Published private(set) var offersRetryWithMemory: Bool = false

    /// True while a delivered change can still be undone after the fact (the
    /// rebuilt app is running; the installed app can be brought back and the
    /// branch dropped).
    @Published private(set) var deliveredChangeCanBeUndone: Bool = false

    /// Where the INSTALLED app lives (the bundle the reader had before Iris
    /// rebuilt from the clone), so an undo can bring it back. Wired by
    /// CompanionManager from the inventory's bundle id; nil = no undo offer.
    var installedApplicationPathForApp: ((_ appSlug: String) -> String?)?

    /// The question the model asked when it declared BLOCKED (nil when it
    /// only explained). The card shows it with an answer field; the answer
    /// re-enters the describe step folded into the request.
    @Published private(set) var blockedQuestionForUser: String?

    /// True from the moment the reader asks a `.running` edit to stop until
    /// the engine acknowledges (it polls this at every step boundary, reverts
    /// everything, and returns the stopped result). Published so the Stop
    /// button can flip to a disabled "Stopping…" and the takeover terminal
    /// can say so — the tap is acknowledged instantly even though the stop
    /// itself lands at the next safe boundary.
    @Published private(set) var readerAskedToStopTheRun: Bool = false

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

    /// Runs the two model-derived clarification triggers (plan §7: the
    /// self-consistency ambiguity check and the irreversible-action classifier)
    /// against the scrubbed request, between Continue and the clarify-or-plan
    /// step. Injected so tests can script a verdict without a model; production
    /// resolves the reader's own provider live and runs
    /// `FeatureEditRequestProbe.probe` — at most three small calls on the
    /// reader's key, failing open to `.allQuiet` (the pre-probe behavior) on
    /// any miss.
    private let probeRequestTriggers: (
        _ scrubbedRequest: String,
        _ clonePath: String?
    ) async -> FeatureEditRequestProbeVerdict

    /// Runs the actual on-demand edit — the jailed loop + verify + commit — and
    /// returns the engine's result. Injected so the whole machine is testable
    /// without a real model, git, or sandbox. Production resolves the reader's
    /// own provider live and drives `MaintainTierCFixer.attemptOnDemandEdit`.
    /// `progressHandler` receives the engine's live activity (real commands,
    /// exits, waits) for the transparency surface; `cancellationCheck` is the
    /// poll the engine honors when the reader taps Stop.
    private let performOnDemandEdit: (
        _ resolvedClonePath: String,
        _ appSlug: String,
        _ appStack: BreakAppStack,
        _ changeId: String,
        _ scrubbedRequest: String,
        _ kind: OnDemandEditKind,
        _ progressHandler: @escaping MaintainTierCProgressHandler,
        _ cancellationCheck: @escaping MaintainTierCCancellationCheck,
        _ runtimeEvidence: OnDemandEditRuntimeEvidence,
        _ additionalPromptSections: [String],
        _ manifestChangeApproval: @escaping MaintainTierCManifestChangeApproval
    ) async -> MaintainOnDemandEditResult

    /// Gathers the runtime evidence for a picked app right as the run starts —
    /// a screenshot of the app's window and a scrubbed tail of its recent
    /// logs/crash report — so the agent sees what the reader sees instead of
    /// deducing runtime behavior cold. Injected (CompanionManager wires the
    /// real collector, which needs the app inventory's bundle id); nil or an
    /// all-nil result simply runs the edit the old, blind way.
    var gatherRuntimeEvidenceForApp: ((_ appSlug: String) async -> OnDemandEditRuntimeEvidence)?

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
    /// What THIS run touched and last said — the two facts the per-app memory
    /// record needs so the next run can see what was tried and where.
    private var filesTouchedThisRun: [String] = []
    private var lastAgentNarrationThisRun: String = ""
    /// The reader's clarification answers with their question text, kept so
    /// they reach the model's opening message (they used to be collected and
    /// thrown away — a plain bug).
    private var clarificationAnswerPairsForPrompt: [(question: String, answer: String)] = []

    /// True while the automatic delivery path owns the relaunch, so the shared
    /// relaunch-result handler routes a fresh build into the symptom re-check
    /// instead of the old "done" ending.
    private var deliveryIsAutomatic = false
    /// The runtime-evidence text gathered BEFORE the run, kept so the
    /// post-relaunch re-gather can say whether a crash report is NEW.
    private var runtimeEvidenceTextBeforeTheRun: String?

    /// The freshly packaged artifact's path, cached across a possible force-quit
    /// consent so the heavy build never runs twice for one relaunch.
    private var packagedArtifactPath: String?

    /// The persisted transcript of the CURRENT run (request, narration,
    /// commands, exits, outcome) under ~/Library/Logs/Iris/edit-runs — the
    /// after-the-fact diagnosis surface a failed run used to lack entirely.
    /// Nil when logging was unavailable, which never affects the run.
    private var runLog: OnDemandEditRunLog?

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

    /// Monotonic id for the in-flight request probe, so a probe result (or its
    /// watchdog) that lands after the reader re-submitted, cancelled, or moved
    /// on is dropped instead of advancing a flow it no longer describes.
    private var requestProbeGeneration = 0

    /// How long the describe step will wait on the request probe before
    /// proceeding with the fail-open all-quiet verdict — the probe may only
    /// ever ADD a question, so a stalled network must never strand the reader
    /// behind a spinner.
    private static let probeWatchdogNanoseconds: UInt64 = 20_000_000_000

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
        probeRequestTriggers: (
            (
                _ scrubbedRequest: String,
                _ clonePath: String?
            ) async -> FeatureEditRequestProbeVerdict
        )? = nil,
        performOnDemandEdit: (
            (
                _ resolvedClonePath: String,
                _ appSlug: String,
                _ appStack: BreakAppStack,
                _ changeId: String,
                _ scrubbedRequest: String,
                _ kind: OnDemandEditKind,
                _ progressHandler: @escaping MaintainTierCProgressHandler,
                _ cancellationCheck: @escaping MaintainTierCCancellationCheck,
                _ runtimeEvidence: OnDemandEditRuntimeEvidence,
                _ additionalPromptSections: [String],
                _ manifestChangeApproval: @escaping MaintainTierCManifestChangeApproval
            ) async -> MaintainOnDemandEditResult
        )? = nil
    ) {
        self.installProvenanceStore = installProvenanceStore
        self.patchQueue = patchQueue
        self.clonePathLock = clonePathLock ?? .shared
        self.topRequestsForApp = topRequestsForApp
        self.probeRequestTriggers = probeRequestTriggers ?? Self.defaultProbeRequestTriggers
        self.performOnDemandEdit = performOnDemandEdit ?? Self.defaultPerformOnDemandEdit
    }

    /// The production probe: the reader's own model provider (never the funded
    /// proxy — same D4/D5 rule as the engine), a small slice of the offline
    /// repo map so the code can settle what the request means where it can, and
    /// the fail-open `FeatureEditRequestProbe`. No provider connected means no
    /// probe — the all-quiet verdict, exactly the pre-probe behavior; the
    /// missing-key refusal itself still comes from the eligibility gate.
    static let defaultProbeRequestTriggers: (
        String, String?
    ) async -> FeatureEditRequestProbeVerdict = { scrubbedRequest, clonePath in
        guard let provider = MaintainModelProviderResolver.firstAvailable() else {
            return .allQuiet
        }
        let repoMapSummary = clonePath.map {
            FeatureEditRepoMap.summarize(repoRootPath: $0, tokenBudget: 600)
        } ?? ""
        return await FeatureEditRequestProbe.probe(
            scrubbedRequest: scrubbedRequest,
            repoMapSummary: repoMapSummary,
            provider: provider
        )
    }

    /// The production performer: resolve the reader's own model provider LIVE
    /// (never the funded proxy) and run the jailed on-demand edit through the
    /// shared Tier C engine, build-script edits hard-blocked before the build,
    /// with the engine's live progress narrated and the reader's Stop honored.
    static let defaultPerformOnDemandEdit: (
        String, String, BreakAppStack, String, String, OnDemandEditKind,
        @escaping MaintainTierCProgressHandler, @escaping MaintainTierCCancellationCheck,
        OnDemandEditRuntimeEvidence, [String], @escaping MaintainTierCManifestChangeApproval
    ) async -> MaintainOnDemandEditResult = { resolvedClonePath, appSlug, appStack, changeId, scrubbedRequest, kind, progressHandler, cancellationCheck, runtimeEvidence, additionalPromptSections, manifestChangeApproval in
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
            kind: kind,
            progressHandler: progressHandler,
            cancellationCheck: cancellationCheck,
            runtimeLogContext: runtimeEvidence.runtimeLogText,
            appWindowScreenshotPNG: runtimeEvidence.appWindowScreenshotPNG,
            additionalPromptSections: additionalPromptSections,
            manifestChangeApproval: manifestChangeApproval
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
        activeRequestText = scrubbed
        changeId = synthesizedChangeId
        classifiedKind = kind

        // The clarification pass (plan §7) runs BEFORE any edit and BEFORE the
        // start-consent gate: decide whether Iris must ask a couple of decisive
        // questions first. Two of the four triggers are model-derived —
        // self-consistency ambiguity and the irreversible-action classifier —
        // so the probe runs off this synchronous path and the flow advances
        // when its verdict (or the fail-open watchdog) lands. The probe can
        // only ever ADD a question, never a refusal: any miss produces the
        // same all-quiet verdict the pre-probe hardcoded `false` did. The two
        // statically-adjudicated signals — an unresolved build recipe and the
        // runtime shape — are read live from the derived recipe at advance
        // time, so the "unknown stack" case still ASKS how to build (turning
        // the old wall into a capability) instead of hard-refusing.
        requestProbeGeneration += 1
        let probeGeneration = requestProbeGeneration
        isAssessingRequest = true
        statusLine = nil
        let clonePathForProbe = provenanceClonePath(forAppSlug: activeAppSlug ?? "")

        Task { [weak self] in
            guard let self else { return }
            let probeVerdict = await self.probeRequestTriggers(scrubbed, clonePathForProbe)
            self.advanceFromDescribe(
                afterProbeGeneration: probeGeneration, verdict: probeVerdict, kind: kind
            )
        }
        // The watchdog: a stalled probe (a network black hole inside the
        // provider's own long timeout) proceeds all-quiet rather than holding
        // the reader behind a spinner. A late real verdict is then dropped by
        // the generation guard.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.probeWatchdogNanoseconds)
            self?.advanceFromDescribe(
                afterProbeGeneration: probeGeneration, verdict: .allQuiet, kind: kind
            )
        }
        return true
    }

    /// The second half of the describe step, entered when the request probe's
    /// verdict (or its fail-open watchdog) lands: fold the model-derived
    /// triggers together with the statically-derived ones into the batched
    /// question set, then clarify or go straight to the plan. Guarded so only
    /// the CURRENT probe for a flow still sitting in `.describe` may advance
    /// it — a stale verdict after a re-submit, cancel, or stop is dropped.
    private func advanceFromDescribe(
        afterProbeGeneration probeGeneration: Int,
        verdict: FeatureEditRequestProbeVerdict,
        kind: OnDemandEditKind
    ) {
        guard phase == .describe,
              isAssessingRequest,
              requestProbeGeneration == probeGeneration,
              let scrubbed = scrubbedRequest else { return }
        isAssessingRequest = false

        let clarificationQuestionBatch = FeatureEditClarificationLogic.questions(
            forRequest: scrubbed,
            requestLooksAmbiguous: verdict.requestLooksAmbiguous,
            recipeIsUnknown: !(derivedRepoRecipe?.hasABuildableRecipe ?? false),
            runtimeShape: derivedRuntimeShape ?? .unknown,
            impliesIrreversibleAction: verdict.impliesIrreversibleAction
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
        clarificationAnswerPairsForPrompt = clarificationQuestions.compactMap { question in
            guard let answer = answersByQuestionId[question.id] else { return nil }
            return (question: question.prompt, answer: answer)
        }

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
        readerAskedToStopTheRun = false
        editRunner.beginRun(appName: activeAppName ?? slug, kind: kind)
        // The persisted run transcript — what makes a failed run diagnosable
        // after the fact. Best-effort: a nil log never affects the run.
        runLog = OnDemandEditRunLog(
            appSlug: slug,
            kindLabel: kind == .feature ? "feature" : "bug fix",
            scrubbedRequest: scrubbed
        )

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
            runLog?.finish(outcome: "not started: the clone path is not usable")
            runLog = nil
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
            runLog?.finish(outcome: "not started: the clone has uncommitted changes")
            runLog = nil
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

        // Gather the runtime evidence — the app's window and its recent logs —
        // so the agent sees what the reader sees. Best-effort; an all-nil
        // result just runs the edit the old, blind way.
        let appName = activeAppName ?? slug
        editRunner.note("Looking at \(appName)'s window and its recent logs…")
        statusLine = "Looking at \(appName)'s window and recent logs…"
        let runtimeEvidence = await gatherRuntimeEvidenceForApp?(slug)
            ?? OnDemandEditRuntimeEvidence(runtimeLogText: nil, appWindowScreenshotPNG: nil)
        runtimeEvidenceTextBeforeTheRun = runtimeEvidence.runtimeLogText
        filesTouchedThisRun = []
        lastAgentNarrationThisRun = ""

        // Extra prompt sections for THIS run. (1) The per-app MEMORY: what the
        // last runs on this app tried, where, and whether the reader said it
        // cured the complaint — framed as observations, with a still-broken
        // verdict read as a NEGATIVE signal. This is what stops run N+1 from
        // re-guessing what run N already learned. (2) The reader's
        // clarification answers, which were collected and never read before.
        var additionalPromptSections: [String] = []
        let priorRuns = OnDemandEditRunLog.recentMemoryRecords(forAppSlug: slug)
        if let memorySection = OnDemandEditRunLog.memoryPromptSection(fromRecords: priorRuns) {
            additionalPromptSections.append(memorySection)
            editRunner.note("Iris remembers \(priorRuns.count) earlier attempt\(priorRuns.count == 1 ? "" : "s") on \(appName) and is using what it learned.")
            runLog?.record("memory: \(priorRuns.count) prior run(s) injected")
        }
        if !clarificationAnswerPairsForPrompt.isEmpty {
            let answerLines = clarificationAnswerPairsForPrompt
                .map { "- Q: \($0.question)\n  A: \($0.answer)" }
                .joined(separator: "\n")
            additionalPromptSections.append(
                "The user answered these clarifying questions before the run — treat the answers as the user's decisions:\n\(answerLines)"
            )
        }
        additionalPromptSections.append(contentsOf: extraPromptSectionsForEveryRun())
        var gatheredEvidenceParts: [String] = []
        if runtimeEvidence.appWindowScreenshotPNG != nil {
            gatheredEvidenceParts.append("a screenshot of its window")
        }
        if runtimeEvidence.runtimeLogText != nil {
            gatheredEvidenceParts.append("its recent log output")
        }
        if gatheredEvidenceParts.isEmpty {
            editRunner.note("No window or recent logs were available — working from the source alone.")
            runLog?.record("runtime evidence: none available")
        } else {
            editRunner.note("Attached \(gatheredEvidenceParts.joined(separator: " and ")) as evidence.")
            runLog?.record("runtime evidence: \(gatheredEvidenceParts.joined(separator: ", "))")
        }

        editRunner.note("Locating the relevant source and making the smallest change that does it…")

        let startedAt = Date()
        let result = await performOnDemandEdit(
            resolvedClonePath, slug, stack, editChangeId, scrubbed, kind,
            // The engine's live activity — every real jailed command, exit,
            // and wait — streamed into the terminal transcript and the status
            // line, so the run is never a black box to the reader again.
            { [weak self] progressEvent in
                self?.presentEngineProgress(progressEvent)
            },
            // The poll the engine honors when the reader taps Stop.
            { [weak self] in
                self?.readerAskedToStopTheRun ?? true
            },
            runtimeEvidence,
            additionalPromptSections,
            // The per-run manifest consent: pause the flow on a card, resume
            // the engine with the reader's Allow/Decline.
            { [weak self] declaration in
                await self?.askReaderToApproveManifestChange(declaration) ?? false
            }
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        editRunner.setWorking(false)
        lastResult = result

        // A READER-initiated stop is its own calm ending, not a failure: the
        // engine has already reverted everything, so release the lock and say
        // plainly that nothing changed — never the "That didn't work" card for
        // an act the reader chose.
        if case .couldNotComplete(let reason) = result,
           reason == MaintainTierCFixer.stoppedByReaderReason {
            editRunner.note("Stopped — nothing was kept. Your clone is exactly as it was.")
            editRunner.finishStopped()
            runLog?.finish(outcome: "stopped by the reader — everything reverted")
            recordMemory(outcome: "stopped by the reader — everything reverted", kind: kind)
            runLog = nil
            readerAskedToStopTheRun = false
            clonePathLock.release(clonePath: resolvedClonePath)
            self.resolvedClonePath = nil
            statusLine = "Stopped at your request — nothing was changed."
            phase = .done
            return
        }

        switch result {
        case .appliedAndRebuilt(let branchName, _, _, let suitePassed, let symptomVerifiedByRepro):
            committedBranchName = branchName
            editRunner.recordVerificationResult(passed: true, over: elapsed)
            editRunner.note(verificationNote(
                suitePassed: suitePassed, kind: kind, symptomVerifiedByRepro: symptomVerifiedByRepro
            ))
            runLog?.finish(outcome: "applied on branch \(branchName) (suite: \(suitePassed.map(String.init) ?? "none to run")"
                + (symptomVerifiedByRepro ? ", repro-verified" : "") + ")")
            runLog = nil
            recordMemory(
                outcome: OnDemandEditMemoryRecord.appliedOutcome(branchName: branchName)
                    + (symptomVerifiedByRepro ? " (repro-verified)" : ""),
                kind: kind
            )
            proposedDiffText = await readCommittedDiff(runner: runner)
            // FULLY AUTOMATIC delivery (founder decision, Aug 22 2026): no
            // keep/relaunch taps — record, rebuild, relaunch, then ask the
            // only question that matters (is the symptom gone?), with undo.
            await beginAutomaticDelivery(branchName: branchName)

        case .couldNotComplete(let reason):
            let mapped = Self.mappedFailure(reason: reason)
            blockedByBuildScriptEdit = mapped.wasBuildScriptBlock
            failureWasRateLimit = mapped.wasRateLimited
            // A rejected credential is the one mid-run failure the reader can
            // clear themselves, so the failed card offers the same settings
            // shortcut the missing-key refusal does.
            refusalOffersModelKeySetup = mapped.offersModelKeySetup
            editRunner.recordVerificationResult(passed: false, over: elapsed)
            editRunner.note(mapped.userFacing)
            if let runLog {
                // The pointer that makes "what did it actually try?" a
                // question with an answer, right where the failure lands.
                editRunner.note("Everything Iris tried is logged at \(runLog.filePath).")
                runLog.finish(outcome: "failed: \(reason)")
            }
            runLog = nil
            recordMemory(outcome: OnDemandEditMemoryRecord.failedOutcome(reason: reason), kind: kind)
            editRunner.finishStopped()
            failRun(reason: mapped.userFacing, resolvedClonePath: resolvedClonePath)

        case .notEligible(let reason):
            editRunner.note("Iris couldn't start the edit: \(reason).")
            editRunner.finishStopped()
            runLog?.finish(outcome: "not eligible: \(reason)")
            runLog = nil
            clonePathLock.release(clonePath: resolvedClonePath)
            self.resolvedClonePath = nil
            phase = .notEligible(reason: reason)
            statusLine = reason

        case .blockedByModel(let explanation, let questionForUser):
            // The model's honest refusal, verbatim, with its question (if any)
            // for the reader to answer and retry. Everything is already
            // reverted; nothing is committed.
            editRunner.note("Iris stopped on purpose: \(explanation)")
            if let questionForUser {
                editRunner.note("Iris needs to know: \(questionForUser)")
            }
            editRunner.finishStopped()
            runLog?.finish(outcome: "blocked: \(explanation)" + (questionForUser.map { " | question: \($0)" } ?? ""))
            runLog = nil
            recordMemory(outcome: OnDemandEditMemoryRecord.blockedOutcome(modelSentence: explanation), kind: kind)
            clonePathLock.release(clonePath: resolvedClonePath)
            self.resolvedClonePath = nil
            blockedQuestionForUser = questionForUser
            phase = .blockedByModel(explanation: explanation)
            statusLine = explanation
        }
    }

    /// The engine's live activity, turned into the reader-facing surfaces: a
    /// transcript row in the takeover terminal for everything that really
    /// happened, and a one-line "what Iris is doing right now" in `statusLine`
    /// (which the eye-bar running card shows when the terminal is hidden). A
    /// pending Stop keeps its own "Stopping…" status line — the transcript
    /// still records what the engine finishes, but the headline stays the
    /// reader's request.
    private func presentEngineProgress(_ progressEvent: MaintainTierCProgressEvent) {
        let stopIsPending = readerAskedToStopTheRun
        func showStatus(_ line: String) {
            if !stopIsPending { statusLine = line }
        }
        switch progressEvent {
        case .waitingOnTheModel(let stepNumber):
            showStatus(stepNumber == 1
                ? "Reading the code and deciding where to start…"
                : "Step \(stepNumber): deciding what to do next…")
        case .agentNarration(let text, _):
            // The agent's OWN sentence for this step — what it says it is
            // doing and why. The most direct "what is Iris doing right now"
            // there is, so it leads both the transcript and the status line.
            lastAgentNarrationThisRun = text
            editRunner.note(text)
            runLog?.record("iris: \(text)")
            showStatus(String(text.prefix(140)))
        case .editedFiles(let paths, _):
            for path in paths where !filesTouchedThisRun.contains(path) {
                filesTouchedThisRun.append(path)
            }
            let shownPaths = paths.prefix(5).joined(separator: ", ")
            let overflowCount = paths.count - min(paths.count, 5)
            let line = overflowCount > 0
                ? "Changed: \(shownPaths) (+\(overflowCount) more)"
                : "Changed: \(shownPaths)"
            editRunner.note(line)
            runLog?.record("changed: \(paths.joined(separator: ", "))")
            showStatus(line)
        case .runningJailedCommand(let command, _):
            editRunner.recordExecutedCommand(command)
            runLog?.record("$ \(command)")
            showStatus(GuideAutopilotFriendlyLabel.label(for: command))
        case .jailedCommandFinished(let exitCode, let duration, let outputTailLines):
            editRunner.recordCommandOutputTail(outputTailLines)
            editRunner.recordCommandExit(exitCode: exitCode, duration: duration)
            let outputSuffix = outputTailLines.isEmpty
                ? ""
                : "\n" + outputTailLines.joined(separator: "\n")
            runLog?.record("exit \(exitCode) (\(String(format: "%.1f", duration))s)\(outputSuffix)")
        case .revertedForbiddenBuildScriptEdit(let paths, _):
            let fileList = paths.joined(separator: ", ")
            let line = "Iris tried to edit \(fileList) — build files are off-limits, so Iris restored \(paths.count == 1 ? "it" : "them") and is implementing without \(paths.count == 1 ? "it" : "them")."
            editRunner.note(line)
            runLog?.record("restored forbidden build-script edit: \(fileList)")
            showStatus(line)
        case .nudgedTowardConvergence(let stepNumber):
            let line = "Iris hasn't changed any files for a few steps — asking it to either finish up or make its next edit…"
            editRunner.note(line)
            runLog?.record("nudge at step \(stepNumber): asked for DONE or the next edit")
            showStatus(line)
        case .waitingOutARateLimit(let waitSeconds):
            let line = "Anthropic is rate-limiting your credential — waiting \(waitSeconds)s, then continuing…"
            editRunner.note(line)
            runLog?.record("rate-limited — waiting \(waitSeconds)s")
            showStatus(line)
        case .retryingAfterATransportDrop:
            let line = "A model call dropped (a timeout or network hiccup) — retrying the same step…"
            editRunner.note(line)
            runLog?.record("model call dropped — retrying")
            showStatus(line)
        case .verifyingTheChange(let buildCommand, let testCommand):
            var verificationParts: [String] = []
            if let buildCommand { verificationParts.append("building with `\(buildCommand)`") }
            if let testCommand { verificationParts.append("running the tests (`\(testCommand)`)") }
            let line = verificationParts.isEmpty
                ? "The edit is made — checking it over…"
                : "The edit is made — now \(verificationParts.joined(separator: ", then "))…"
            editRunner.note(line)
            runLog?.record("verifying: build=\(buildCommand ?? "none"), tests=\(testCommand ?? "none")")
            showStatus(line)
        case .verificationFailedPreparingRepair(let stage, let remainingRounds):
            let line = "The \(stage) failed — Iris is reading the errors and fixing its change (\(remainingRounds) more \(remainingRounds == 1 ? "try" : "tries") after this)…"
            editRunner.note(line)
            runLog?.record("verification failed (\(stage)) — repair round begins (\(remainingRounds) left)")
            showStatus(line)
        case .committingTheChange:
            let line = "It checks out — committing the change on a branch…"
            editRunner.note(line)
            runLog?.record("committing")
            showStatus(line)
        case .runningModelAuthoredRepro(let command):
            let line = "Running Iris's own check for this bug three ways — before the fix, after it, and with it reverted…"
            editRunner.note(line)
            editRunner.recordExecutedCommand(command)
            runLog?.record("repro check: \(command)")
            showStatus(line)
        case .awaitingManifestChangeApproval(let summary):
            let line = "Iris needs permission: \(summary)"
            editRunner.note(line)
            runLog?.record("manifest consent requested: \(summary)")
            showStatus(line)
        case .manifestChangeApplied(let request, let summary):
            appliedManifestChangeRequest = request
            let line = "Allowed — Iris applied it itself: \(summary)"
            editRunner.note(line)
            runLog?.record("manifest change applied: \(summary)")
            showStatus(line)
        case .modelAuthoredReproDiscarded(let reason):
            let line = "Iris's check didn't prove anything — \(reason) — so this counts as applied, not verified."
            editRunner.note(line)
            runLog?.record("repro discarded: \(reason)")
            showStatus(line)
        }
    }

    /// The reader asked a `.running` edit to stop (the Stop button, or the
    /// takeover terminal's red escape hatch). This latches the request; the
    /// engine polls it at every step boundary, reverts everything it did, and
    /// returns the stopped result — which `runEdit` turns into the calm
    /// "stopped, nothing changed" ending. Distinct from `cancel()`, which only
    /// backs out of the flow BEFORE anything runs.
    func stopRunningEdit() {
        guard phase == .running, !readerAskedToStopTheRun else { return }
        readerAskedToStopTheRun = true
        statusLine = "Stopping — Iris is finishing the current step, then putting everything back…"
        editRunner.note("Stopping at your request — no more changes; anything already made is being reverted.")
    }

    // MARK: - Manifest consent (the model declares; the reader allows; Iris applies)

    /// Pause the run on the consent card and resume the engine with the
    /// answer. Called BY the engine (through the seam) while it awaits.
    private func askReaderToApproveManifestChange(_ declaration: MaintainManifestChangeRequest) async -> Bool {
        pendingManifestChangeSummary = MaintainManifestApplier.humanReadableSummary(declaration)
        phase = .awaitingManifestConsent
        statusLine = "Iris needs your permission: \(pendingManifestChangeSummary ?? "a manifest change")"
        let approved = await withCheckedContinuation { continuation in
            manifestConsentContinuation = continuation
        }
        manifestConsentContinuation = nil
        pendingManifestChangeSummary = nil
        phase = .running
        statusLine = approved ? "Applying it and building…" : "Declined — wrapping up…"
        return approved
    }

    /// The reader allowed the declared manifest change (this run only).
    func approveManifestChange() {
        guard phase == .awaitingManifestConsent else { return }
        manifestConsentContinuation?.resume(returning: true)
    }

    /// The reader declined; the run ends honestly with everything reverted.
    func declineManifestChange() {
        guard phase == .awaitingManifestConsent else { return }
        manifestConsentContinuation?.resume(returning: false)
    }

    // MARK: - Automatic delivery → symptom re-check → verdict (founder: fully automatic)

    /// Record the applied change, rebuild the app from the clone, relaunch it,
    /// and hand off to the symptom re-check — no keep/relaunch taps. An app
    /// Iris cannot rebuild ends honestly: the installed app still runs the
    /// old code, and the copy says exactly that (never "relaunch to pick it
    /// up", which was false for an unrebuilt install).
    private func beginAutomaticDelivery(branchName: String) async {
        guard let slug = activeAppSlug, let editChangeId = changeId else { return }
        let appName = activeAppName ?? slug
        phase = .delivering
        deliveryIsAutomatic = true
        statusLine = "Applied on branch \(branchName) — rebuilding \(appName) so you're running the fix…"
        editRunner.note("Rebuilding \(appName) from the clone and relaunching it with the change…")

        patchQueue.record(QueuedPatch(
            recipeId: editChangeId,
            signatureId: editChangeId,
            appSlug: slug,
            branchName: branchName,
            patchText: proposedDiffText ?? "",
            baseCommit: originalHeadCommit,
            appliedAt: Date()
        ))

        guard relaunchIsAvailableForApp?(slug) == true,
              let package = packageEditedAppFromClone,
              let relaunch = terminateAndRelaunchEditedApp else {
            editRunner.finishApplied()
            releaseLockIfHeld()
            statusLine = "Applied on branch \(branchName). Your installed \(appName) still runs the OLD code — Iris can't rebuild this kind of app yet, so rebuild it from the clone yourself to pick the change up."
            phase = .done
            return
        }

        // 1) Package + assert the artifact exists (signed with a stable identity
        //    when one is available). Nothing is terminated yet.
        let packaging = await package(slug)
        guard case .artifactReady(let artifactPath, let signingSummary) = packaging else {
            editRunner.finishApplied()
            finishRelaunchWithoutTerminating(fromPackaging: packaging)
            return
        }
        packagedArtifactPath = artifactPath
        freshBuildSigningSummary = signingSummary
        editRunner.note("Built a fresh \(appName) from the clone (\(signingSummary)).")

        // Packaging-metadata verification: when the approved manifest change
        // was a plist key or an entitlement, prove it actually reached the
        // BUILT app — a purpose string that never made it into the bundle is
        // a fix that verified green as a no-op.
        if let appliedRequest = appliedManifestChangeRequest {
            var expectations = PackagingExpectations()
            switch appliedRequest.kind {
            case .addInfoPlistKey:
                expectations = PackagingExpectations(infoPlistKeysThatMustExist: [appliedRequest.key])
            case .addEntitlement:
                expectations = PackagingExpectations(entitlementKeysThatMustBeTrue: [appliedRequest.key])
            case .addCargoDependency, .addNodeDependency:
                break
            }
            if !expectations.isEmpty {
                let failures = await AppRelaunchService.verifyPackagedMetadata(
                    artifactPath: artifactPath, expectations: expectations
                )
                if failures.isEmpty {
                    editRunner.note("Checked the built app: \(appliedRequest.key) is in it.")
                } else {
                    packagingMetadataFailures = failures
                    editRunner.note("Warning — the built app does NOT carry the change as expected: \(failures.joined(separator: "; "))")
                }
            }
        }
        // 2) Quit the running app (gracefully — a save dialog still routes to
        //    the force-quit consent, the one destructive act that can corrupt
        //    data) and launch the fresh build.
        statusLine = "Quitting \(appName) and opening the rebuilt one…"
        let launch = await relaunch(slug, artifactPath, false)
        applyRelaunchLaunchResult(launch, allowedForceQuit: false)
    }

    /// The rebuilt app is up. Give it a moment, look again (window + logs),
    /// then ask the reader whether THEIR complaint is gone — the only
    /// end-to-end truth signal the flow has.
    private func beginSymptomRecheck() {
        let appName = activeAppName ?? (activeAppSlug ?? "the app")
        phase = .awaitingSymptomConfirmation
        deliveredChangeCanBeUndone = true
        symptomRecheckSummary = nil
        statusLine = "\(appName) is running with the change. Give it a moment, then tell Iris whether it's actually fixed."
        editRunner.note("Relaunched \(appName) with the change. Looking again in a moment…")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.phase == .awaitingSymptomConfirmation, let slug = self.activeAppSlug else { return }
            let evidenceAfter = await self.gatherRuntimeEvidenceForApp?(slug)
            let textAfter = evidenceAfter?.runtimeLogText ?? ""
            let crashBefore = self.runtimeEvidenceTextBeforeTheRun?.contains("crash report") == true
            let crashAfter = textAfter.contains("crash report")
            var summaryParts: [String] = []
            if crashAfter && !crashBefore {
                summaryParts.append("a NEW crash report appeared since the relaunch — it may still be broken")
            } else if evidenceAfter?.runtimeLogText != nil {
                summaryParts.append("no new crash report since the relaunch")
            }
            if evidenceAfter?.appWindowScreenshotPNG != nil {
                summaryParts.append("Iris captured the relaunched window")
            }
            if let signing = self.freshBuildSigningSummary {
                summaryParts.append("this build is \(signing)")
            }
            if !self.packagingMetadataFailures.isEmpty {
                summaryParts.append("WARNING: \(self.packagingMetadataFailures.joined(separator: "; "))")
            }
            self.symptomRecheckSummary = summaryParts.isEmpty
                ? "Iris couldn't observe the relaunched app (no window or logs yet)."
                : summaryParts.joined(separator: "; ") + "."
            self.editRunner.note("Looked again: \(self.symptomRecheckSummary ?? "")")
        }
    }

    /// The reader's verdict on their own complaint. Persisted where the next
    /// run (and a human reading the branch) can see it: the commit trailer,
    /// and the per-app memory record. "Still broken" unlocks a retry that
    /// carries the negative verdict forward.
    func recordSymptomVerdict(_ verdict: OnDemandEditSymptomVerdict) {
        guard phase == .awaitingSymptomConfirmation, let slug = activeAppSlug else { return }
        let appName = activeAppName ?? slug
        let branchName = committedBranchName ?? "the branch"
        editRunner.note("Your verdict: \(verdict.displayLabel).")
        persistSymptomVerdict(verdict)
        switch verdict {
        case .fixed:
            statusLine = "Fixed — \(appName) is running the change (branch \(branchName))."
            editRunner.finishApplied()
        case .stillBroken:
            statusLine = "Noted — still broken. Iris has recorded what it tried so the next attempt starts from there. Undo to go back to the installed \(appName), or try again."
            offersRetryWithMemory = true
            editRunner.finishStopped()
        case .cannotTell:
            statusLine = "Left as unverified — the change is on branch \(branchName) and \(appName) is running it. You can undo any time from here."
            editRunner.finishApplied()
        }
        phase = .done
    }

    /// Stamp the verdict on the commit (a trailer a human sees) and in the
    /// per-app memory (what the next run sees).
    private func persistSymptomVerdict(_ verdict: OnDemandEditSymptomVerdict) {
        guard let resolved = resolvedClonePath else { return }
        let trailerValue = verdict.trailerValue
        Task {
            if let runner = try? MaintainShellRunner(repoRootPath: resolved) {
                _ = try? await runner.run(
                    "git commit --amend --no-edit --trailer 'Symptom-Recheck: \(trailerValue)' --quiet 2>/dev/null || true",
                    deadline: 60
                )
            }
        }
        // The per-app memory: the NEXT run on this app reads this verdict. A
        // still-broken is the important one — it turns this attempt into a
        // negative signal rather than something to repeat.
        if let slug = activeAppSlug {
            OnDemandEditRunLog.updateNewestRecordSymptomVerdict(
                forAppSlug: slug, to: verdict.memoryRecordValue
            )
        }
    }

    /// Append this run's memory record (every terminal outcome writes one, so
    /// the next run sees failures and stops, not just successes).
    private func recordMemory(outcome: String, kind: OnDemandEditKind) {
        guard let slug = activeAppSlug else { return }
        OnDemandEditRunLog.appendMemoryRecord(OnDemandEditMemoryRecord(
            appSlug: slug,
            kind: kind == .feature ? OnDemandEditMemoryRecord.kindFeature : OnDemandEditMemoryRecord.kindBugFix,
            scrubbedRequest: scrubbedRequest ?? "",
            filesTouched: filesTouchedThisRun,
            agentFinalNarration: lastAgentNarrationThisRun,
            outcome: outcome
        ))
    }

    /// Prompt sections every on-demand run carries regardless of app or
    /// memory (the diagnostic probe vocabulary lands here once merged).
    /// Overridable seam for the production wiring.
    var extraPromptSectionsForEveryRun: () -> [String] = { [] }
    // (The diagnostic probe vocabulary is assembled inside the fixer's own
    // system prompt — `MaintainDiagnosticProbe.promptSection` — so it rides
    // every on-demand run without a seam; this hook is for app-specific
    // extras.)

    /// Undo a delivered change after the fact: bring the INSTALLED app back
    /// (quit the rebuilt instance, launch the installed bundle), drop the
    /// branch, restore the clone to where it was, and forget the queued patch.
    func undoDeliveredChange() {
        guard deliveredChangeCanBeUndone,
              let slug = activeAppSlug,
              let branchName = committedBranchName,
              let editChangeId = changeId,
              let resolved = resolvedClonePath ?? provenanceResolvedClonePath(forAppSlug: slug) else { return }
        let appName = activeAppName ?? slug
        deliveredChangeCanBeUndone = false
        phase = .committing
        statusLine = "Undoing — bringing back the installed \(appName)…"
        Task { [weak self] in
            guard let self else { return }
            if let installedPath = self.installedApplicationPathForApp?(slug),
               let relaunch = self.terminateAndRelaunchEditedApp {
                _ = await relaunch(slug, installedPath, false)
            }
            if let runner = try? MaintainShellRunner(repoRootPath: resolved) {
                let restore = (self.originalHeadRef.map { $0 != "HEAD" } == true)
                    ? "git checkout '\(self.originalHeadRef!)' --quiet"
                    : "git checkout '\(self.originalHeadCommit ?? "HEAD")' --quiet"
                _ = try? await runner.run(
                    "\(restore) 2>/dev/null; git branch -D '\(branchName)' --quiet 2>/dev/null || true",
                    deadline: 120
                )
            }
            self.patchQueue.remove(appSlug: slug, recipeId: editChangeId)
            self.editRunner.note("Undone — the installed \(appName) is back and the branch is gone.")
            self.editRunner.finishStopped()
            self.releaseLockIfHeld()
            self.proposedDiffText = nil
            self.committedBranchName = nil
            self.offersRetryWithMemory = false
            self.statusLine = "Undone — you're back on the installed \(appName); nothing of the change remains."
            self.phase = .done
        }
    }

    /// One-tap retry after a temporary rate limit: re-enter describe on the
    /// same app with the same request prefilled, so the reader just taps once
    /// more when the limit has cleared.
    func retryAfterRateLimit() {
        guard let slug = activeAppSlug, let name = activeAppName, let stack = activeAppStack else { return }
        let previousRequest = scrubbedRequest
        pickApp(slug: slug, name: name, stack: stack)
        describePrefillText = previousRequest
    }

    /// "Try again with what Iris learned": re-enter the describe step on the
    /// same app with the same request; the memory record (which now carries
    /// the still-broken verdict) shapes the next run's opening message.
    func retryAfterStillBroken() {
        guard let slug = activeAppSlug, let name = activeAppName, let stack = activeAppStack else { return }
        let previousRequest = scrubbedRequest
        releaseLockIfHeld()
        pickApp(slug: slug, name: name, stack: stack)
        describePrefillText = previousRequest
    }

    /// The reader answered the model's BLOCKED question: re-enter describe
    /// with the answer folded into the request so the next run opens with it.
    func retryAfterAnsweringBlockedQuestion(_ answer: String) {
        guard case .blockedByModel = phase,
              let slug = activeAppSlug, let name = activeAppName, let stack = activeAppStack else { return }
        let question = blockedQuestionForUser ?? ""
        let previousRequest = scrubbedRequest ?? ""
        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        pickApp(slug: slug, name: name, stack: stack)
        describePrefillText = question.isEmpty || trimmedAnswer.isEmpty
            ? previousRequest
            : "\(previousRequest)\n\n(Iris asked: \(question) — answer: \(trimmedAnswer))"
    }

    /// The card consumed the prefill; clear it so a later pick starts clean.
    func consumeDescribePrefill() {
        describePrefillText = nil
    }

    /// The symlink-resolved clone path for an app, for an undo that arrives
    /// after the lock was already released.
    private func provenanceResolvedClonePath(forAppSlug appSlug: String) -> String? {
        guard let clonePath = provenanceClonePath(forAppSlug: appSlug) else { return nil }
        return try? GitInspectionService.allowedRepositoryPath(clonePath)
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
            guard case .artifactReady(let artifactPath, let signingSummary) = packaging else {
                self.finishRelaunchWithoutTerminating(fromPackaging: packaging)
                return
            }
            self.packagedArtifactPath = artifactPath
            self.freshBuildSigningSummary = signingSummary
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
            if deliveryIsAutomatic {
                // The lock stays held through the re-check: an undo still
                // touches the clone (branch drop + checkout).
                beginSymptomRecheck()
                return
            }
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
    private func verificationNote(
        suitePassed: Bool?, kind: OnDemandEditKind, symptomVerifiedByRepro: Bool = false
    ) -> String {
        let subject = kind == .feature ? "The feature is implemented" : "The fix is in"
        if symptomVerifiedByRepro {
            // The one honest path to the word: the model's own headless check
            // failed before the patch, passed after, and failed again with the
            // patch reverted.
            return "\(subject) — and it is VERIFIED: Iris's own check for this bug failed before the change, passes after it, and fails again with the change reverted. It builds\(suitePassed == true ? " and the test suite stays green" : "")."
        }
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
    /// user-facing message — separating "too large / out of budget", a blocked
    /// build-script edit, and a rejected model credential from a generic
    /// verification failure, so the reader knows whether to narrow the request,
    /// reconnect their credential, or accept that the attempt genuinely failed.
    /// `offersModelKeySetup` is true only for the credential rejection — the
    /// one mid-run failure a settings tap actually fixes. Static and
    /// nonisolated so the mapping is unit-testable as the pure text function
    /// it is.
    nonisolated static func mappedFailure(
        reason: String
    ) -> (userFacing: String, wasBuildScriptBlock: Bool, offersModelKeySetup: Bool, wasRateLimited: Bool) {
        // A rate limit is TEMPORARY and unrelated to the edit — a shared
        // Claude Code login hits it constantly. It is not a failure of the
        // change, so it reads calmly and offers a one-tap retry, never the
        // red "That didn't work". (The engine already rode out several waits
        // before surfacing this.)
        if reason.contains("rate-limiting") {
            return (
                "Anthropic is rate-limiting your model credential right now, so Iris paused — nothing was changed. "
                    + "A connected Claude Code login shares one limit with Claude Code itself, so this clears on its own; "
                    + "wait a few minutes and try again.",
                false, false, true
            )
        }
        // The Tier C loop's `modelCallFailureReason` prefix for an Anthropic
        // 401 on the reader's own credential. The commonest way here is an
        // IMPORTED Claude Code login: Claude Code rotates its token, the
        // snapshot Iris holds lapses, and every later call is turned down.
        if reason.contains("model credential rejected") {
            return (
                "Anthropic turned down your model credential, so Iris couldn't run the edit — nothing changed. "
                    + "An imported Claude Code login stops working when Claude Code refreshes its token; "
                    + "reconnect with \"Sign in with Claude Code\" (durable) or paste an API key in settings, then try again.",
                false, true, false
            )
        }
        if reason.contains("build-script") {
            return ("This change would edit files that run during the build (like build.rs or package.json scripts), which Iris won't run unreviewed — it stopped before building. Nothing changed.", true, false, false)
        }
        if reason.contains("ran out of steps") {
            // With budgeting removed, "ran out of steps" only happens when the
            // loop stopped making progress even after the finish-or-continue
            // nudge, or hit the distant runaway backstop — never a budget.
            return ("Iris worked at this for a while but couldn't converge on a finished change, so it stopped — nothing was applied. A more specific request may land better. (Everything it tried is logged in ~/Library/Logs/Iris/edit-runs.)", false, false, false)
        }
        if reason.contains("changed nothing") {
            return ("Iris couldn't find a change to make for that — nothing was applied.", false, false, false)
        }
        if reason.contains("failed verification") {
            return ("Iris made a change but it didn't build or pass the tests, so it reverted everything. Nothing changed.", false, false, false)
        }
        // Defensive only: `runEdit` intercepts the reader-stop result before
        // mapping, so this fires only if a future caller forgets to — and a
        // stop the reader chose must never read as a failure.
        if reason.contains(MaintainTierCFixer.stoppedByReaderReason) {
            return ("Stopped at your request — nothing was changed.", false, false, false)
        }
        return ("Iris couldn't complete that edit — nothing changed. (\(reason))", false, false, false)
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
        readerAskedToStopTheRun = false
        deliveryIsAutomatic = false
        freshBuildSigningSummary = nil
        packagingMetadataFailures = []
        appliedManifestChangeRequest = nil
        // A consent left awaiting by an interrupted flow resolves as a decline
        // so the engine never hangs on a dead card.
        manifestConsentContinuation?.resume(returning: false)
        manifestConsentContinuation = nil
        pendingManifestChangeSummary = nil
        runtimeEvidenceTextBeforeTheRun = nil
        symptomRecheckSummary = nil
        offersRetryWithMemory = false
        deliveredChangeCanBeUndone = false
        failureWasRateLimit = false
        blockedQuestionForUser = nil
        // Defensive: a log left open by an interrupted flow is closed rather
        // than leaked (normal runs close it on their own result path).
        runLog?.finish(outcome: "flow reset")
        runLog = nil
        // Invalidate any in-flight request probe: its verdict (and watchdog)
        // must not advance a flow that has been reset out from under it.
        requestProbeGeneration += 1
        isAssessingRequest = false
        // resolvedClonePath is only cleared alongside a lock release, so a lock
        // is never orphaned by a reset mid-run.
    }
}

/// The reader's answer to "is the thing you complained about actually
/// fixed?" after the rebuilt app relaunched — the flow's only end-to-end
/// truth signal, recorded honestly (a walk-away is "unverified", never a
/// claimed success).
enum OnDemandEditSymptomVerdict: String, Sendable {
    case fixed
    case stillBroken
    case cannotTell

    var displayLabel: String {
        switch self {
        case .fixed: return "fixed"
        case .stillBroken: return "still broken"
        case .cannotTell: return "can't tell yet"
        }
    }

    /// The per-app memory record's verdict vocabulary (`OnDemandEditMemoryRecord`).
    var memoryRecordValue: String {
        switch self {
        case .fixed: return OnDemandEditMemoryRecord.symptomVerdictConfirmed
        case .stillBroken: return OnDemandEditMemoryRecord.symptomVerdictStillBroken
        case .cannotTell: return OnDemandEditMemoryRecord.symptomVerdictUnverified
        }
    }

    /// The commit-trailer value: `Symptom-Recheck: confirmed|still-broken|unverified`.
    var trailerValue: String {
        switch self {
        case .fixed: return "confirmed"
        case .stillBroken: return "still-broken"
        case .cannotTell: return "unverified"
        }
    }
}
