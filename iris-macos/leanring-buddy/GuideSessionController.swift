//
//  GuideSessionController.swift
//  leanring-buddy
//
//  Owns one in-progress install guide: which guide is open, which branch of it
//  the reader picked, how far into that branch they are, and what the panel
//  should offer them to press next.
//
//  This is the state layer the Tauri panel keeps in its `state` object
//  (`iris-desktop/ui/app.js` — `loadGuide`, `setPlatform`, `moveStep`,
//  `updatePrimaryAction`, `verifyCurrentTools`), which remains the behavioral
//  spec. Nothing here re-implements validation: fetching, version checking,
//  handoff resolution, and progress storage all go through `GuideService`, link
//  policy goes through `ExternalLinkPolicy`, and tool checks go through
//  `ToolVersionService`.
//

import AppKit
import Combine
import Foundation

// Autopilot drive-loop tracing uses the module-internal `irisTrace(_:)` file
// logger defined in GuideAutopilotShellSession.swift (os_log is not captured for
// this signed app). Temporary — removed once the empty-terminal wedge is found.

/// What the panel is showing right now. The failure case carries an already
/// human-readable sentence rather than an error value, because every failure
/// this controller can hit has exactly one thing worth telling the reader and
/// deciding that twice (once here, once in the view) is how the two drift.
enum GuideSessionLoadState: Equatable, Sendable {
    case noGuideIsOpen
    case guideIsLoading(slug: String)
    case guideIsOpen
    case guideCouldNotBeLoaded(slug: String, userFacingMessage: String)

    var isShowingSomethingAboutAGuide: Bool {
        self != .noGuideIsOpen
    }
}

/// The one thing the step card's main button does. The blocked case exists so a
/// step whose link host is not allowlisted renders as a visibly disabled button
/// with a reason attached: the Tauri app shipped a version where that same
/// situation produced a button that silently did nothing (Astro's Windows
/// "Install BrowserOS"), and `iris-desktop 0.1.4` fixed it. A no-op button is
/// worse than no button, because the reader blames themselves.
enum GuideStepPrimaryAction: Equatable, Sendable {
    case copyCommandToClipboard(command: String, buttonLabel: String)
    case openLinkInBrowser(linkURLString: String, buttonLabel: String)
    case openLinkIsUnavailable(linkURLString: String, reasonTheLinkCannotBeOpened: String)
    case runToolChecksForThisStep(buttonLabel: String)
    /// "I ran it" / "Continue" / "Finish" / "Done" — every label that simply
    /// moves the reader on. They differ only in wording, so they share a case.
    case advanceToTheNextStep(buttonLabel: String)
    /// The one explicit gesture that lets Iris start running the install. It
    /// is offered only in the panel and is the ONLY path to `startAutopilot`,
    /// which is what keeps a crafted `iris://` link from ever starting
    /// execution — the security line this whole feature crosses.
    case startAutopilotForThisGuide(buttonLabel: String)

    var buttonLabel: String {
        switch self {
        case .copyCommandToClipboard(_, let buttonLabel): return buttonLabel
        case .openLinkInBrowser(_, let buttonLabel): return buttonLabel
        case .openLinkIsUnavailable: return "Open"
        case .runToolChecksForThisStep(let buttonLabel): return buttonLabel
        case .advanceToTheNextStep(let buttonLabel): return buttonLabel
        case .startAutopilotForThisGuide(let buttonLabel): return buttonLabel
        }
    }

    /// Whether the panel should draw this as a pressable button at all.
    var isPressable: Bool {
        if case .openLinkIsUnavailable = self {
            return false
        }
        return true
    }
}

/// Where one tool-check row is in its life. `readyToCheck` is the row's resting
/// state: the Tauri panel lists the tools a step needs but does not run anything
/// until the reader presses the button, so nothing is spawned by merely landing
/// on a step.
enum GuideToolCheckState: Equatable, Sendable {
    case readyToCheck
    case checking
    case installedWithVersion(version: String)
    case notInstalled
    case couldNotBeChecked(reason: String)
}

struct GuideToolCheckRow: Identifiable, Equatable, Sendable {
    let toolName: String
    let state: GuideToolCheckState

    var id: String { toolName }

    /// The trailing half of the row, matching the Tauri panel's
    /// `"${tool} · ${detail}"` line.
    var detailText: String {
        switch state {
        case .readyToCheck: return "ready to check"
        case .checking: return "checking…"
        case .installedWithVersion(let version): return version
        case .notInstalled: return "Not installed"
        case .couldNotBeChecked(let reason): return reason
        }
    }
}

/// The detour a reader is put on when the branch they opened needs a tool their
/// computer does not have. It is deliberately a separate value from everything
/// describing the main guide: the reader's place in the guide itself must
/// survive the detour untouched, and the surest way to guarantee that is for the
/// detour to have nowhere to write it.
struct GuideSetupRecoveryState: Equatable, Sendable {
    /// One row per prerequisite the branch declares, as of the most recent
    /// check. Tools that were found keep their row on purpose — "git ✓ /
    /// node ×" tells the reader exactly what is still in their way.
    var prerequisiteCheckRows: [GuideToolCheckRow]

    /// The branch's own setup steps for whatever is still missing, in the order
    /// the branch lists them.
    var setupStepsToWalk: [IrisGuideStep]

    var currentSetupStepIndex: Int

    /// True while a re-check is in flight, so the button can say so instead of
    /// looking like it did nothing.
    var aRecheckIsRunning: Bool

    /// One sentence about what the last re-check found. Nil until the reader has
    /// pressed it, because the arrival state already explains itself.
    var messageFromTheMostRecentRecheck: String?

    var currentSetupStep: IrisGuideStep? {
        guard currentSetupStepIndex >= 0, currentSetupStepIndex < setupStepsToWalk.count else {
            return nil
        }
        return setupStepsToWalk[currentSetupStepIndex]
    }

    var isOnTheLastSetupStep: Bool {
        currentSetupStepIndex >= setupStepsToWalk.count - 1
    }

    /// The tools this detour exists to install, in row order.
    var toolNamesStillMissing: [String] {
        prerequisiteCheckRows
            .filter { row in row.state == .notInstalled }
            .map(\.toolName)
    }
}

/// The guide the reader had open the last time they used Iris, remembered
/// across quits so the panel can offer to put them back into it.
///
/// The reader's *place* has always been on disk — `iris:progress:cue:v7:macos:desktop`
/// knew perfectly well they were on step seven — but nothing remembered WHICH
/// guide those keys belonged to. So a relaunch drew an empty "Follow an install
/// guide" field with no sign that Iris remembered anything, and the reader
/// reasonably reported it as "it doesn't save what step I was on". This is the
/// missing half: the identity of the position, stored beside the position.
nonisolated struct GuideTheReaderWasFollowing: Equatable, Sendable {
    let slug: String

    /// The guide's display name ("publikclip"), stored rather than re-fetched
    /// so the resume offer can be drawn before any network call.
    let appName: String

    /// The version the remembered step index was counted in. A step number only
    /// means something inside its own version, which is why it is kept with it.
    let version: Int

    let branchKey: String

    /// Zero-based, the same index `GuideProgress` stores.
    let stepIndex: Int

    let numberOfStepsInTheBranch: Int

    let readerHadFinishedTheGuide: Bool

    /// "step 7 of 12" — the one phrasing shared by the resume offer and the
    /// chat context, so the panel and the assistant never describe the same
    /// position two different ways.
    ///
    /// One-based, because a reader counts steps from one.
    static func progressPhrase(
        stepIndex: Int,
        numberOfStepsInTheBranch: Int,
        readerHasFinishedTheGuide: Bool
    ) -> String {
        if readerHasFinishedTheGuide {
            return "the end of the guide"
        }
        guard numberOfStepsInTheBranch > 0 else {
            return "step \(stepIndex + 1)"
        }
        return "step \(stepIndex + 1) of \(numberOfStepsInTheBranch)"
    }

    var humanReadableProgressPhrase: String {
        Self.progressPhrase(
            stepIndex: stepIndex,
            numberOfStepsInTheBranch: numberOfStepsInTheBranch,
            readerHasFinishedTheGuide: readerHadFinishedTheGuide
        )
    }

    /// Whether the reader is far enough in that resuming means anything. Step
    /// one of a guide nobody started is not a place worth being offered back.
    var readerIsPartwayThrough: Bool {
        stepIndex > 0 || readerHadFinishedTheGuide
    }
}

/// Where `GuideTheReaderWasFollowing` lives between launches: one
/// `UserDefaults` key alongside the `iris:progress:…` keys `GuideService`
/// already writes, in the same style.
///
/// A small struct over `UserDefaults` rather than a couple of loose read/write
/// calls, for the same reason `AutopilotAutonomyGrant` is one: a test can point
/// it at an isolated suite and never touch the reader's real preferences.
nonisolated struct LastFollowedGuideMemory: @unchecked Sendable {
    /// The app-wide memory, over `UserDefaults.standard`.
    static let shared = LastFollowedGuideMemory()

    /// `iris:guide:lastFollowed`, deliberately outside `GuideService`'s
    /// `iris:progress:` prefix: "forget every guide's progress" sweeps that
    /// prefix, and this key is cleared explicitly rather than by accident.
    static let storageKey = "iris:guide:lastFollowed"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func rememberedGuide() -> GuideTheReaderWasFollowing? {
        guard
            let storedGuide = userDefaults.dictionary(forKey: Self.storageKey),
            let slug = storedGuide["slug"] as? String, !slug.isEmpty,
            let branchKey = storedGuide["branchKey"] as? String, !branchKey.isEmpty
        else {
            return nil
        }
        return GuideTheReaderWasFollowing(
            slug: slug,
            // A hand-edited preference (or a build before the name was stored)
            // may have no display name. The slug is what the reader typed to
            // get here, so it reads fine — and it beats forgetting the guide.
            appName: (storedGuide["appName"] as? String) ?? slug,
            version: (storedGuide["version"] as? Int) ?? 1,
            branchKey: branchKey,
            stepIndex: max(0, (storedGuide["step"] as? Int) ?? 0),
            numberOfStepsInTheBranch: max(0, (storedGuide["steps"] as? Int) ?? 0),
            readerHadFinishedTheGuide: (storedGuide["completed"] as? Bool) ?? false
        )
    }

    func remember(_ guideTheReaderWasFollowing: GuideTheReaderWasFollowing) {
        userDefaults.set(
            [
                "slug": guideTheReaderWasFollowing.slug,
                "appName": guideTheReaderWasFollowing.appName,
                "version": guideTheReaderWasFollowing.version,
                "branchKey": guideTheReaderWasFollowing.branchKey,
                "step": guideTheReaderWasFollowing.stepIndex,
                "steps": guideTheReaderWasFollowing.numberOfStepsInTheBranch,
                "completed": guideTheReaderWasFollowing.readerHadFinishedTheGuide,
                "updatedAt": Date().timeIntervalSince1970,
            ] as [String: Any],
            forKey: Self.storageKey
        )
    }

    func forgetTheRememberedGuide() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }
}

/// How the controller asks whether a tool is installed. It is a closure rather
/// than a direct call to `ToolVersionService` so a test can answer "node is
/// missing" without a machine that actually lacks Node, and so no test ever
/// spawns a process. Production always passes the real service.
typealias GuideToolVersionChecker = @Sendable (String) async throws -> ToolVersion

@MainActor
final class GuideSessionController: ObservableObject {
    // MARK: - Published state

    @Published private(set) var loadState: GuideSessionLoadState = .noGuideIsOpen
    @Published private(set) var guideBeingFollowed: IrisGuide?
    @Published private(set) var selectedBranch: IrisGuideBranch?
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var readerHasFinishedTheGuide: Bool = false
    @Published private(set) var toolCheckRows: [GuideToolCheckRow] = []

    /// The guide this Mac remembers the reader following, so the panel can
    /// offer "Resume publikclip — step 7 of 12" instead of an empty slug field
    /// after a quit and reopen.
    ///
    /// Publishing it is ALL this controller does with it at launch. A relaunch
    /// that reopened a guide by itself would take the panel away from whatever
    /// the reader actually pressed the hotkey for, so reopening stays a gesture
    /// the reader makes: `resumeTheGuideTheReaderWasFollowing()`.
    @Published private(set) var lastGuideTheReaderWasFollowing: GuideTheReaderWasFollowing?

    /// Where that memory is kept. Settable (not just `.shared`) for the same
    /// reason `autonomyGrant` is: a test injects one over an isolated
    /// `UserDefaults` suite and never touches the reader's real preference.
    /// Assigning it re-reads, because what was published at init came from
    /// whichever store was in place then.
    var lastFollowedGuideMemory = LastFollowedGuideMemory.shared {
        didSet {
            lastGuideTheReaderWasFollowing = lastFollowedGuideMemory.rememberedGuide()
        }
    }

    /// Set the moment the reader copies the step's command, which is what turns
    /// the button from "Copy" into "I ran it" — the same `actionReady` latch the
    /// Tauri panel keeps.
    @Published private(set) var readerHasTakenThisStepsAction: Bool = false

    /// The short-lived "Copied — paste in Terminal." line under the command
    /// block. Nil when nothing was copied recently.
    @Published private(set) var transientCopyConfirmationText: String?

    /// True once the reader has handed the install to Iris. It can only become
    /// true through `startAutopilot`, which is reachable only from
    /// `performPrimaryAction` — never from opening a guide, deep link or
    /// otherwise. See the consent invariant in the tests.
    @Published private(set) var autopilotIsRunning: Bool = false

    /// How many commands autopilot has executed this session. Exists so the
    /// consent tests can prove a deep link executes nothing.
    private(set) var numberOfCommandsAutopilotHasExecuted: Int = 0

    /// Builds the runner when autopilot starts. Injected so tests can supply a
    /// fake and the app can wire the real one (which needs `CompanionManager`'s
    /// `ClaudeAPI`). Nil in a controller opened without autopilot support: the
    /// start gesture is then simply never offered.
    private let makeAutopilotRunner: (@MainActor (GuideAutopilotGuideContext) -> GuideAutopilotRunner)?
    /// The live runner, exposed so the terminal view can observe its transcript
    /// and state. Nil unless autopilot is running.
    @Published private(set) var autopilotRunner: GuideAutopilotRunner?
    /// True while the drive loop is running, so the watch-loop resume path
    /// cannot start a second concurrent loop.
    private var autopilotIsDriving = false
    /// True when autopilot ran into something on the current step it could not
    /// do on its own — it surfaced the step, skipped a risky command, or handed
    /// back a sensitive one — and is now waiting on the reader. It matters
    /// because while it is set, `autopilotOwnsTheCurrentStep` goes false: the
    /// watch loop is un-muzzled so it can notice the reader finished the step and
    /// advance, which re-enters the drive loop and picks the install back up.
    /// Without this, a single gate Iris could not clear stopped the whole
    /// install dead — the reader's #1 complaint after the first live run.
    @Published private(set) var autopilotHandedTheCurrentStepToTheReader = false
    /// The shell session is started once per autopilot run, not once per step.
    private var runnerSessionHasStarted = false

    /// True once the reader has pressed "Check tools" at least once on this
    /// step, which is what relabels the button to "Check again".
    @Published private(set) var toolChecksHaveBeenRunForThisStep: Bool = false

    /// Non-nil while the reader is being walked through a missing prerequisite
    /// instead of through the guide itself. The Tauri panel keeps the same idea
    /// in `state.setupTool` (`iris-desktop/ui/app.js`).
    @Published private(set) var setupRecoveryState: GuideSetupRecoveryState?

    var readerIsInSetupRecovery: Bool {
        setupRecoveryState != nil
    }

    /// Where the eye is going for the step on screen, and why.
    ///
    /// Published rather than computed on demand because resolving it touches
    /// the accessibility tree and sometimes a model, and the card redraws far
    /// more often than the step changes.
    @Published private(set) var pointingDecisionForTheOpenStep: GuidePointingDecision = .doNotPoint(.stepHasNothingToPointAt)

    /// Set by `CompanionManager` so the guide can fly the eye without this
    /// controller knowing anything about overlays or windows.
    var sendTheEyeTo: ((CGPoint, CGRect, String) -> Void)?
    var stopPointingTheEye: (() -> Void)?

    /// Fired exactly once, the moment the reader reaches the completion card, so
    /// `CompanionManager` can open the freshly installed app and refresh the
    /// "Your publik apps" list. Injected the same way as the eye closures so this
    /// controller stays ignorant of `NSWorkspace` and the inventory service.
    /// The reader asked that a finished install "just open and be part of your
    /// apps list" instead of leaving them on a card.
    var onGuideCompleted: ((IrisGuide, IrisGuideBranch) -> Void)?

    /// Fired when autopilot begins and ends, so `CompanionManager` can raise and
    /// tear down the centered terminal takeover. Injected like the eye closures
    /// so this controller stays ignorant of overlays and panels.
    var onAutopilotDidStart: (() -> Void)?
    var onAutopilotDidStop: (() -> Void)?

    /// Asks the reader the one-time "Let Iris take control of your Mac?"
    /// question the first time they start an autopilot install, returning true
    /// if they grant it. Injected (a modal the panel/`CompanionManager` owns)
    /// so this controller stays ignorant of AppKit. Consulted only while the
    /// grant is not yet set; once granted it is remembered across installs and
    /// this is never called again (see `startAutopilot`).
    var confirmAutonomousControl: (() -> Bool)?

    /// Why autopilot did not start, when the reader asked it to and it did not.
    ///
    /// "Let Iris run it" used to fail by returning quietly: the consent was
    /// declined or its alert never reached the front, and the button simply did
    /// nothing forever after. A tap has to be answered.
    @Published private(set) var autopilotBlockedExplanation: String?

    /// The persisted "Let Iris take control" grant `startAutopilot` reads and
    /// sets. Settable (not just `.shared`) so a test can inject one over an
    /// isolated `UserDefaults` suite and never touch the reader's real
    /// preference — the same isolation `guideService()` already uses.
    var autonomyGrant = AutopilotAutonomyGrant.shared

    /// Fired when autopilot reaches a manual step it cannot run for the reader
    /// (a download, a drag, a permission, a sign-in): the takeover terminal
    /// parks to a corner so the eye — already flying to the step's control — and
    /// the control itself are both in the clear. `onAutopilotResumedFromGate`
    /// brings the terminal back to center when Iris runs the next command.
    /// Injected like the eye closures so this controller stays ignorant of
    /// windows.
    var onAutopilotWaitingForReaderAtGate: ((_ title: String, _ instruction: String) -> Void)?
    var onAutopilotResumedFromGate: (() -> Void)?

    /// True while the install is being shown in the centered takeover window
    /// rather than the small pane under the guide card. The pane checks this so
    /// the terminal is never drawn in two places at once. Set by
    /// `CompanionManager` when it raises the takeover; cleared when autopilot
    /// stops.
    @Published private(set) var autopilotIsShownAsTakeover: Bool = false

    /// Where a descriptor actually is on screen. Injected so the whole guide is
    /// testable without a screen.
    var targetLocator: (any GuideTargetLocating)?

    private var pointingTask: Task<Void, Never>?

    /// Re-aims the eye whenever the reader lands in a different app. The
    /// pointing decision is frontmost-gated — no arrow over a window nobody
    /// can see — and without this the gate was a one-shot race: a permission
    /// step `open`s System Settings and pointing refreshes before Settings
    /// has finished activating, so the decision landed on
    /// `targetAppIsNotInFront` and no retry ever came. The eye stayed home at
    /// exactly the steps that most need showing. Watching activations makes
    /// the refusal self-healing: once the right app comes forward, the eye
    /// flies — and it re-points when the reader wanders off and back.
    ///
    /// "Once", not "the moment": the refresh is debounced (see
    /// `refreshPointingOnceAppActivationsHaveSettled`) because a single cmd-tab
    /// is several activations and each one used to re-run the whole ladder and
    /// re-announce the step.
    private var appActivationObserver: NSObjectProtocol?

    /// Called from init. Split out so init stays readable.
    private func startRefreshingPointingOnAppActivation() {
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.theReaderCanSeeTheGuideStepRightNow else { return }
                self.refreshPointingOnceAppActivationsHaveSettled()
            }
        }
    }

    /// Whether there is a guide step in front of the reader at all.
    ///
    /// An activation while the card is closed used to re-run the whole ladder
    /// for a step nobody is looking at — including, on an inferred step, a paid
    /// model call. Nothing to see means nothing to point at.
    private var theReaderCanSeeTheGuideStepRightNow: Bool {
        guard loadState == .guideIsOpen else { return false }
        // Absent the injection this is true whenever a guide is open, which is
        // the behavior that shipped: `CompanionManager` owns the panel and the
        // eye card and is the only thing that knows whether either is on
        // screen, so it is the one that can answer better than "a guide exists".
        return isTheGuideCardOnScreen?() ?? true
    }

    /// Injected by `CompanionManager`: is the guide card actually on screen?
    /// See `theReaderCanSeeTheGuideStepRightNow` for what nil means.
    var isTheGuideCardOnScreen: (() -> Bool)?

    /// How long the activation storm has to be quiet before pointing re-runs.
    ///
    /// Activations arrive in bursts and each one cost a full ladder: a cmd-tab
    /// out and back is two, an `open`ed app that bounces focus is more, and
    /// every one of them re-announced the step title over the eye. Only the app
    /// the reader ends up in matters, so the refresh waits for the switching to
    /// stop. Short enough that the self-healing "the right app just came
    /// forward" case still feels immediate.
    private static let quietPeriodBeforeRefreshingPointingAfterAnActivation: Duration = .milliseconds(400)

    private var debouncedPointingRefreshTask: Task<Void, Never>?

    /// Coalesces a burst of app activations into one pointing refresh.
    private func refreshPointingOnceAppActivationsHaveSettled() {
        debouncedPointingRefreshTask?.cancel()
        debouncedPointingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: Self.quietPeriodBeforeRefreshingPointingAfterAnActivation)
            guard !Task.isCancelled, let self else { return }
            // Re-checked after the wait, not just before it: the reader may
            // have closed the card during the quiet period.
            guard self.theReaderCanSeeTheGuideStepRightNow else { return }
            self.refreshPointingForTheOpenStep()
        }
    }

    deinit {
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
    }

    /// Work out where to point for the step now on screen, and send the eye.
    ///
    /// Called whenever the step changes — including when the watch loop
    /// advances it, which is the case a manual refresh would miss.
    func refreshPointingForTheOpenStep() {
        pointingTask?.cancel()

        guard
            let branch = selectedBranch,
            let step = stepTheReaderIsLookingAt
        else {
            pointingDecisionForTheOpenStep = .doNotPoint(.stepHasNothingToPointAt)
            explanationForIrisHavingStoppedPointingAtThisStep = nil
            stopPointingTheEye?()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let decision = GuidePointingLadder.decide(
            target: GuidePointingLadder.target(
                for: step,
                shell: branch.shell,
                modelFallbackIsAvailable: targetLocator != nil
            ),
            stepIsSensitive: step.watch?.sensitive ?? false,
            irisMayLookAtTheScreen: irisMayLookAtTheScreenForPointing,
            frontmostBundleIdentifier: frontmost?.bundleIdentifier,
            frontmostAppName: frontmost?.localizedName
        )

        guard let targetLocator else {
            // Nothing can look for anything in this configuration, so there is
            // no budget to spend and nothing about a budget to explain.
            pointingDecisionForTheOpenStep = decision
            explanationForIrisHavingStoppedPointingAtThisStep = nil
            return
        }

        // Pointing refreshes on app activation as well as on step changes, so
        // the paid model rung has to be budgeted per step or a single parked
        // step can spend a screenshot-sized model call on every window switch.
        // The free rungs (window frame, accessibility tree) re-run every time.
        let stepIdentityForBudget = "\(currentStepIndex):\(step.id)"
        if stepIdentityForBudget != stepIdentityTheModelBudgetBelongsTo {
            stepIdentityTheModelBudgetBelongsTo = stepIdentityForBudget
            modelPointingAsksSpentOnThisStep = 0
            // A fresh step has not given up on anything yet.
            explanationForIrisHavingStoppedPointingAtThisStep = nil
        }

        // The ask is RESERVED here, before the await below, rather than counted
        // after it. Counting afterwards was a read-then-write across a
        // suspension point: every activation that arrived while a resolve was
        // still in flight read the same pre-increment number, decided it had
        // budget too, and asked — which is how a cap of two let six model calls
        // through on one step. Everything in this method runs to completion on
        // the main actor, so a spend reserved before the task starts is a spend
        // every later refresh can see.
        let mayAskTheModel = modelPointingAsksSpentOnThisStep < Self.maximumModelPointingAsksPerStep
        if mayAskTheModel {
            modelPointingAsksSpentOnThisStep += 1
        }

        pointingTask = Task { [weak self] in
            let outcome = await GuideStepPointingCoordinator.resolve(
                decision: decision,
                stepTitle: step.title,
                stepBody: step.body,
                mayAskTheModel: mayAskTheModel,
                using: targetLocator
            )
            guard let self else { return }
            // Hand the reservation back when the ladder never reached the model
            // — an authored target the accessibility tree found, or a decision
            // that was not `pointAt` at all. Only into the budget this refresh
            // reserved from: a step the reader has since moved to has its own
            // allowance and must not be credited out of an older step's.
            if mayAskTheModel,
               !outcome.theModelWasAsked,
               self.stepIdentityTheModelBudgetBelongsTo == stepIdentityForBudget {
                self.modelPointingAsksSpentOnThisStep = max(0, self.modelPointingAsksSpentOnThisStep - 1)
            }
            guard !Task.isCancelled else { return }
            self.explanationForIrisHavingStoppedPointingAtThisStep =
                Self.explanationForGivingUpOnPointing(
                    decision: decision,
                    outcome: outcome,
                    theBudgetAllowedAnAsk: mayAskTheModel
                )
            self.pointingDecisionForTheOpenStep = outcome.decision
            if let location = outcome.screenLocation, let displayFrame = outcome.displayFrame {
                self.sendTheEyeTo?(location, displayFrame, step.title)
            } else {
                self.stopPointingTheEye?()
            }
        }
    }

    /// The sentence for the one way pointing used to fail silently.
    ///
    /// Every other refusal already carries its own line (see
    /// `GuidePointRefusal.userFacingMessage`). The spent budget carried none:
    /// the step's inferred target needed the model rung, the rung was skipped,
    /// the eye simply stopped, and the reader was left with "it works the first
    /// time or two, but sometimes does not". Nil whenever pointing worked or
    /// failed for a reason that explains itself.
    private static func explanationForGivingUpOnPointing(
        decision: GuidePointingDecision,
        outcome: GuideStepPointingOutcome,
        theBudgetAllowedAnAsk: Bool
    ) -> String? {
        guard outcome.screenLocation == nil, !theBudgetAllowedAnAsk else {
            return nil
        }
        // An inferred target is the only kind allowed to reach the model, so it
        // is the only kind a spent budget can silence.
        guard case .pointAt(let target) = decision, target.provenance == .inferred else {
            return nil
        }
        return """
        I've stopped looking for this one — I tried \(maximumModelPointingAsksPerStep) times \
        and couldn't find it on screen. Ask me in chat and I'll talk you through it.
        """
    }

    /// The paid pointing rung's allowance for one step. Free rungs (the window
    /// frame, the accessibility tree) are unlimited; only the model is capped.
    ///
    /// Four, raised from two. Two was set when the counter leaked — six calls
    /// got through a cap of two — so it was never really a budget of two. Now
    /// that the spend is reserved before the await and honoured exactly, two
    /// turned out to be too few for the ordinary shape of a step: the first ask
    /// often races the screen it needs (the app is still coming forward), and a
    /// step where the reader legitimately moves between two apps — System
    /// Settings and a browser, say — deserves a fresh look each time they come
    /// back. Four covers that and still bounds the spend at a small number the
    /// reader can never turn into a runaway bill by leaving a step open.
    private static let maximumModelPointingAsksPerStep = 4
    private var modelPointingAsksSpentOnThisStep = 0
    private var stepIdentityTheModelBudgetBelongsTo: String?

    /// Why the eye has stopped pointing at this step, in a sentence for the
    /// reader, or nil while it is pointing or refusing for a reason that speaks
    /// for itself. Published so the panel and the eye card can say it out loud
    /// instead of letting the eye go quiet with no explanation.
    @Published private(set) var explanationForIrisHavingStoppedPointingAtThisStep: String?

    /// Whether the inferred path is allowed to run. Screen Recording only; the
    /// accessibility tree needs no capture, which is why an authored descriptor
    /// works without it.
    var irisMayLookAtTheScreenForPointing: Bool = true

    // MARK: - Collaborators

    private let guideService: GuideService

    /// Notices when the reader has actually done the step they are on, so the
    /// guide moves without being told. It only ever runs for a step that
    /// declares a `watch` block, which is why wiring it in here costs a step
    /// written before the watch loop existed exactly nothing.
    let watchLoop: WatchLoop

    /// How this controller finds out whether a tool is installed. See
    /// `GuideToolVersionChecker`.
    private let checkToolVersion: GuideToolVersionChecker

    /// The computer this app is running on. It only ever has one value in a
    /// shipped build — this is a Mac-only app — but it is injectable so the
    /// branch-preference behavior can be tested from the Windows side too.
    private let platformThisAppRunsOn: IrisPlatform

    private var copyConfirmationDismissalTask: Task<Void, Never>?
    private var toolCheckTask: Task<Void, Never>?

    /// The re-check the reader started from inside the setup detour. Kept apart
    /// from `toolCheckTask` because the two write to different rows and a stale
    /// result landing in the wrong one is exactly the bug this avoids.
    private var setupRecheckTask: Task<Void, Never>?

    /// The most recent progress write. Pressing Next must not wait on storage,
    /// so the write is started and left to finish on its own; anything that
    /// needs it to have landed before reading progress back waits here.
    private var progressPersistenceTask: Task<Void, Never>?

    /// How long the copy confirmation stays up, matching the Tauri panel's
    /// 2200ms toast so both surfaces feel the same.
    private static let copyConfirmationVisibleDuration: Duration = .milliseconds(2200)

    init(
        guideService: GuideService = GuideService(
            apiBase: AssistantTransport.configuredPublikBaseURL().absoluteString
        ),
        platformThisAppRunsOn: IrisPlatform = .macos,
        // Nil rather than `WatchLoop()` because a default argument is evaluated
        // outside the main actor and `WatchLoop` is main-actor isolated.
        watchLoop: WatchLoop? = nil,
        checkToolVersion: @escaping GuideToolVersionChecker = { toolName in
            try await ToolVersionService.checkToolVersion(tool: toolName)
        },
        makeAutopilotRunner: (@MainActor (GuideAutopilotGuideContext) -> GuideAutopilotRunner)? = nil
    ) {
        self.guideService = guideService
        self.platformThisAppRunsOn = platformThisAppRunsOn
        self.watchLoop = watchLoop ?? WatchLoop()
        self.checkToolVersion = checkToolVersion
        self.makeAutopilotRunner = makeAutopilotRunner

        // The whole feature in four lines: when the loop decides the step is
        // done, move on. `notYet` is silence by design, and a `userStuck` hint
        // is already published on the loop for the panel to draw — pushing it
        // through the controller as well would be two sources for one sentence.
        // The autopilot guard: while Iris is executing a terminal step itself,
        // the exit code is the verdict, so a watch-loop tick already in flight
        // must not also advance and double-step.
        self.watchLoop.onVerdict = { [weak self] verdict in
            guard let self, verdict == .completed,
                  !self.autopilotOwnsTheCurrentStep,
                  // A step the reader deliberately went BACK to is theirs to
                  // leave. Its signal was almost certainly already true when
                  // they arrived — that is what going back to a finished step
                  // means — and advancing on it turns Back into a no-op.
                  !self.readerDeliberatelyReturnedToThisStep else {
                return
            }
            self.advanceToTheNextStep()
        }

        // Read the remembered guide at init so the panel's very first draw
        // already knows there is something to resume. This publishes the
        // memory and nothing else — no guide is opened, no network call is
        // made, and startup is not hijacked.
        self.lastGuideTheReaderWasFollowing = lastFollowedGuideMemory.rememberedGuide()

        startRefreshingPointingOnAppActivation()
    }

    // MARK: - Opening a guide

    /// The deep-link route: `iris://guide/<slug>?version=&branch=&step=`. The
    /// link is already shape-validated by `IrisDeepLinkParser` before it gets
    /// here; the branch and step are checked against the guide that actually
    /// comes back, by `GuideService.resolveHandoff`.
    func openGuide(fromDeepLink guideDeepLink: GuideDeepLink) async {
        await openGuide(
            slug: guideDeepLink.slug,
            requestedVersion: Int(guideDeepLink.version),
            branchKeyFromDeepLink: guideDeepLink.branchKey,
            stepIndexFromDeepLink: guideDeepLink.stepIndex.map(Int.init)
        )
    }

    /// The no-deep-link route: the reader typed a slug into the panel. No
    /// version is pinned, so publik serves whatever is current, which is what
    /// somebody starting fresh wants.
    func openLatestVersionOfGuide(slug: String) async {
        await openGuide(
            slug: slug,
            requestedVersion: nil,
            branchKeyFromDeepLink: nil,
            stepIndexFromDeepLink: nil
        )
    }

    /// The resume route: the reader pressed the offer the panel draws from
    /// `lastGuideTheReaderWasFollowing`. Nothing calls this on launch.
    ///
    /// The remembered version is deliberately NOT pinned. A version publik has
    /// since retired answers "this version of the guide is no longer
    /// available", which is a worse reply to "put me back" than simply opening
    /// the guide as it stands today — and when the guide really has moved on,
    /// `restoreSavedProgress` finds nothing saved under the new version and
    /// starts at step one, which is the honest answer (step 7 of v6 is not
    /// step 7 of v7).
    ///
    /// The branch IS carried across, because a reader's place is per-branch:
    /// resuming the Android build into the iPhone branch would be somebody
    /// else's ninth step.
    func resumeTheGuideTheReaderWasFollowing() async {
        guard let lastGuideTheReaderWasFollowing else { return }
        await openGuide(
            slug: lastGuideTheReaderWasFollowing.slug,
            requestedVersion: nil,
            branchKeyFromDeepLink: lastGuideTheReaderWasFollowing.branchKey,
            // Nil, not the remembered step. The progress saved for this branch
            // is the authority, and going through it is what applies the
            // machine reality check a link-carried step index skips.
            stepIndexFromDeepLink: nil
        )
    }

    /// Fetches a guide and lands the reader somewhere real inside it.
    func openGuide(
        slug: String,
        requestedVersion: Int?,
        branchKeyFromDeepLink: String?,
        stepIndexFromDeepLink: Int?
    ) async {
        cancelAnyWorkFromThePreviousStep()
        loadState = .guideIsLoading(slug: slug)
        guideBeingFollowed = nil
        selectedBranch = nil
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        toolCheckRows = []
        setupRecoveryState = nil

        let fetchedGuide: IrisGuide
        do {
            fetchedGuide = try await guideService.fetchGuide(slug: slug, version: requestedVersion)
        } catch let guideServiceError as GuideServiceError {
            // Every status the route can answer with is already a distinct case
            // carrying its own sentence, so "this version is gone" never reads
            // as "you have no internet".
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: guideServiceError.userFacingMessage
            )
            return
        } catch {
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: GuideServiceError
                    .transportFailure(reason: error.localizedDescription)
                    .userFacingMessage
            )
            return
        }

        // The version here is the guide's own, not the link's: they are equal by
        // the time `fetchGuide` returns (it 409s otherwise), and using the real
        // one keeps the progress key honest when no version was pinned at all.
        let guideDeepLinkToResolve = GuideDeepLink(
            slug: fetchedGuide.appSlug,
            version: UInt32(max(1, fetchedGuide.version)),
            branchKey: branchKeyFromDeepLink,
            stepIndex: stepIndexFromDeepLink.map { stepIndex in UInt32(max(0, stepIndex)) }
        )
        guard let resolvedHandoff = GuideService.resolveHandoff(
            guideDeepLinkToResolve,
            against: fetchedGuide,
            preferredPlatform: platformThisAppRunsOn
        ) else {
            loadState = .guideCouldNotBeLoaded(
                slug: slug,
                userFacingMessage: GuideServiceError.guideHasNoBranches.userFacingMessage
            )
            return
        }

        guideBeingFollowed = fetchedGuide
        selectedBranch = resolvedHandoff.branch

        // A link that names a branch and a step BEYOND THE START is carrying the
        // reader's own place across from the website, so it wins over whatever
        // this machine last wrote down.
        //
        // `step=0` is not that. publik's "Open in Iris" button always emits a
        // step, and the step it emits comes from the BROWSER's localStorage —
        // a different store from this one. A reader who did seven steps inside
        // Iris still has 0 in their browser, so clicking that button a second
        // time used to send `step=0`, satisfy this condition, jump the guide
        // back to the beginning AND overwrite the saved 7 with 0 on the very
        // next line. Their progress was not ignored, it was destroyed, on the
        // ordinary path of clicking the button twice.
        //
        // A link cannot distinguish "resume me at the start" from "I have no
        // resume point", so the start is treated as the second — saved progress
        // wins, and a reader who genuinely wants step one can use Back.
        let linkNamesThisBranch = branchKeyFromDeepLink == resolvedHandoff.branch.branchKey
        let linkCarriesARealResumePoint = (stepIndexFromDeepLink ?? 0) > 0
        let theLinkNamedThisExactBranchAndStep = linkNamesThisBranch && linkCarriesARealResumePoint
        if theLinkNamedThisExactBranchAndStep {
            currentStepIndex = resolvedHandoff.stepIndex
            readerHasFinishedTheGuide = false
            await persistProgressForTheCurrentPosition()
        } else {
            await restoreSavedProgress(forBranch: resolvedHandoff.branch)
        }

        prepareToolCheckRowsForTheCurrentStep()

        // The prerequisite scan runs while the panel still says "Loading", so
        // the reader is never shown step one of an install they cannot start
        // and then yanked out of it a moment later.
        await enterSetupRecoveryIfAPrerequisiteIsMissing(forBranch: resolvedHandoff.branch)

        loadState = .guideIsOpen
        pointTheWatchLoopAtTheCurrentStep()
    }

    func closeTheGuide() {
        cancelAnyWorkFromThePreviousStep()
        // A pointer request already in flight has to die with the guide.
        //
        // It did not, and the result was the strangest thing in the bug report:
        // "randomly, it will move to a spot on my computer and say the first
        // step, out of nowhere". A model call launched while the guide was open
        // finished seconds after it closed, passed its own `!Task.isCancelled`
        // check because nothing had cancelled it, and drove the eye — which
        // force-shows a hidden overlay — announcing the step title it captured
        // when it started. For a guide the reader never advanced, that is step
        // one, arriving long after they walked away from it.
        pointingTask?.cancel()
        pointingTask = nil
        // A debounced refresh waiting out its quiet period has to die with the
        // guide too, for the same reason: it would re-point at a step nobody is
        // looking at any more.
        debouncedPointingRefreshTask?.cancel()
        debouncedPointingRefreshTask = nil
        explanationForIrisHavingStoppedPointingAtThisStep = nil
        stopPointingTheEye?()
        if autopilotIsRunning { stopAutopilot() }
        watchLoop.stopWatching()
        loadState = .noGuideIsOpen
        guideBeingFollowed = nil
        selectedBranch = nil
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        toolCheckRows = []
        setupRecoveryState = nil
    }

    // MARK: - Branch selection

    /// Every branch the guide ships, which is what the device-pair picker draws.
    /// Unsupported pairs are included on purpose: a reader on a Mac who picks
    /// "Windows + iPhone" deserves to be told why it cannot work rather than to
    /// find that pair missing and assume Iris is broken.
    var branchesTheReaderCanChooseBetween: [IrisGuideBranch] {
        guideBeingFollowed?.branches ?? []
    }

    /// The Tauri panel hides the picker entirely for a single-branch guide,
    /// because a choice of one is not a choice.
    var guideOffersAChoiceOfBranches: Bool {
        branchesTheReaderCanChooseBetween.count > 1
    }

    func selectBranch(withBranchKey branchKey: String) async {
        guard let guide = guideBeingFollowed,
              let branchTheReaderPicked = guide.branch(matchingBranchKey: branchKey) else {
            return
        }
        cancelAnyWorkFromThePreviousStep()
        selectedBranch = branchTheReaderPicked
        setupRecoveryState = nil
        // Each branch remembers its own place: the same reader can be nine steps
        // into the Android build and not have started the iPhone one.
        await restoreSavedProgress(forBranch: branchTheReaderPicked)
        prepareToolCheckRowsForTheCurrentStep()
        // Branches do not share prerequisites — the Android route needs a JDK
        // the iPhone route never asks about — so switching re-scans.
        await enterSetupRecoveryIfAPrerequisiteIsMissing(forBranch: branchTheReaderPicked)
        pointTheWatchLoopAtTheCurrentStep()
    }

    // MARK: - What the step card renders

    /// The pair explanation shown instead of steps. Non-nil means this branch
    /// has no install route at all.
    var unsupportedPairForTheSelectedBranch: IrisUnsupportedPair? {
        selectedBranch?.unsupported
    }

    /// The step the reader is on, or nil when there is nothing to show — no
    /// guide, an unsupported pair, an empty branch, or the completion card.
    var currentStep: IrisGuideStep? {
        guard let branch = selectedBranch, branch.unsupported == nil else {
            return nil
        }
        guard currentStepIndex >= 0, currentStepIndex < branch.steps.count else {
            return nil
        }
        return branch.steps[currentStepIndex]
    }

    /// The step whose title, body, command, and button the panel is drawing
    /// right now. It is the setup step during the prerequisite detour and the
    /// guide's own step the rest of the time. `currentStep` stays the guide's
    /// step in both cases, because that is what the reader's saved place means.
    var stepTheReaderIsLookingAt: IrisGuideStep? {
        if let setupRecoveryState {
            return setupRecoveryState.currentSetupStep
        }
        return currentStep
    }

    var numberOfStepsInTheSelectedBranch: Int {
        // Setup steps are deliberately excluded, matching the Tauri panel: they
        // are a side quest for a missing tool, so counting them would make the
        // total jump around depending on what the reader already has installed.
        selectedBranch?.steps.count ?? 0
    }

    /// "3 / 12", or "Done" on the completion card.
    var stepCounterText: String {
        if readerIsInSetupRecovery {
            // The detour has no place in the guide's own count, so it says what
            // it is instead of borrowing a number that would be a lie.
            return "Setup"
        }
        if readerHasFinishedTheGuide {
            return "Done"
        }
        guard numberOfStepsInTheSelectedBranch > 0 else {
            return ""
        }
        return "\(currentStepIndex + 1) / \(numberOfStepsInTheSelectedBranch)"
    }

    /// How full the progress bar is, from 0 to 1.
    var fractionOfTheGuideCompleted: Double {
        guard numberOfStepsInTheSelectedBranch > 0 else {
            return 0
        }
        if readerHasFinishedTheGuide {
            return 1
        }
        return Double(currentStepIndex) / Double(numberOfStepsInTheSelectedBranch)
    }

    /// The command block's contents, or nil when there is no block to draw.
    /// A `check` step's command is the list of version probes behind the tool
    /// rows rather than something for the reader to paste, so it is not shown
    /// as a block — the same call the Tauri panel makes.
    var commandBlockTextForTheCurrentStep: String? {
        guard let step = stepTheReaderIsLookingAt, step.kind != .check else {
            return nil
        }
        guard let command = step.command, !command.isEmpty else {
            return nil
        }
        return command
    }

    /// The body copy under the step title. A step with a command says where to
    /// paste it, which is more useful than the authored body at that moment —
    /// the Tauri panel makes the same substitution.
    var bodyTextForTheCurrentStep: String {
        guard let step = stepTheReaderIsLookingAt else {
            return ""
        }
        // A setup step keeps its authored body. "Apple opens a small installer."
        // is the whole reason the reader will not be alarmed by what happens
        // next, and "Paste in Terminal." would throw that away for something the
        // copy confirmation already says.
        if readerIsInSetupRecovery {
            return step.body
        }
        if commandBlockTextForTheCurrentStep != nil {
            return "Paste in \(nameOfTheShellForTheSelectedBranch)."
        }
        return step.body
    }

    var nameOfTheShellForTheSelectedBranch: String {
        switch selectedBranch?.shell ?? .terminal {
        case .terminal: return "Terminal"
        case .powershell: return "PowerShell"
        }
    }

    /// "cue is ready." — the completion card's headline.
    var completionHeadline: String {
        guard let guide = guideBeingFollowed else {
            return "Guide complete."
        }
        return "\(guide.appName) is ready."
    }

    var canReturnToThePreviousStep: Bool {
        guard selectedBranch?.unsupported == nil else {
            return false
        }
        // Inside the detour, Back walks the setup steps and stops at the first
        // one. It never leaves the detour by the back door — the reader gets out
        // by fixing the tool or by explicitly skipping.
        if let setupRecoveryState {
            return setupRecoveryState.currentSetupStepIndex > 0
        }
        guard numberOfStepsInTheSelectedBranch > 0 else {
            return false
        }
        return readerHasFinishedTheGuide || currentStepIndex > 0
    }

    // MARK: - The primary action

    /// The single button at the bottom of the step card, resolved exactly once
    /// so the view never has to work out what pressing it should do.
    var primaryActionForTheCurrentStep: GuideStepPrimaryAction? {
        guard loadState == .guideIsOpen,
              let branch = selectedBranch,
              branch.unsupported == nil else {
            return nil
        }

        if let setupRecoveryState, let setupStep = setupRecoveryState.currentSetupStep {
            return primaryAction(forSetupStep: setupStep, in: setupRecoveryState)
        }

        guard !readerHasFinishedTheGuide, let step = currentStep else {
            return nil
        }

        let thisIsTheLastStep = currentStepIndex >= branch.steps.count - 1
        let labelForMovingOn = thisIsTheLastStep ? "Finish" : "Continue"

        // A check step's whole job is the tool rows, so its button drives them
        // until every tool it needs has been found.
        let toolNamesThisStepNeeds = toolNamesRequiredByTheCurrentStep
        if step.kind == .check, !toolNamesThisStepNeeds.isEmpty {
            if everyRequiredToolWasFound {
                return .advanceToTheNextStep(buttonLabel: labelForMovingOn)
            }
            return .runToolChecksForThisStep(
                buttonLabel: toolChecksHaveBeenRunForThisStep ? "Check again" : "Check tools"
            )
        }

        if let command = commandBlockTextForTheCurrentStep {
            if readerHasTakenThisStepsAction {
                return .advanceToTheNextStep(buttonLabel: "I ran it")
            }
            return .copyCommandToClipboard(command: command, buttonLabel: "Copy")
        }

        if let linkURLString = step.href, !linkURLString.isEmpty {
            guard ExternalLinkPolicy.isAllowedExternalURL(linkURLString) else {
                return .openLinkIsUnavailable(
                    linkURLString: linkURLString,
                    reasonTheLinkCannotBeOpened: Self.reasonALinkCannotBeOpened(
                        linkURLString: linkURLString
                    )
                )
            }
            if readerHasTakenThisStepsAction {
                return .advanceToTheNextStep(buttonLabel: labelForMovingOn)
            }
            return .openLinkInBrowser(
                linkURLString: linkURLString,
                buttonLabel: step.actionLabel ?? "Open"
            )
        }

        return .advanceToTheNextStep(buttonLabel: thisIsTheLastStep ? "Finish" : "Done")
    }

    /// Says which host was refused rather than just "blocked", because the
    /// reader can still visit it themselves and the host name is the only part
    /// of the answer they can act on.
    static func reasonALinkCannotBeOpened(linkURLString: String) -> String {
        let hostThatWasRefused = URLComponents(string: linkURLString)?.host
        guard let hostThatWasRefused, !hostThatWasRefused.isEmpty else {
            return "Iris cannot open this link — it is not a web address Iris understands."
        }
        return "Iris will not open \(hostThatWasRefused) — it is not on publik's reviewed link list."
    }

    /// The setup detour's button. It offers the step's own action first — copy
    /// the installer command, open the download page — and once that has been
    /// taken on the last setup step it becomes the re-check, which is the only
    /// thing that can end the detour honestly. This is the same sequence the
    /// Tauri panel runs through `state.setupTool` + `state.actionReady`.
    private func primaryAction(
        forSetupStep setupStep: IrisGuideStep,
        in setupRecoveryState: GuideSetupRecoveryState
    ) -> GuideStepPrimaryAction {
        let labelForMovingOn = setupRecoveryState.isOnTheLastSetupStep ? "Check again" : "Continue"

        if !readerHasTakenThisStepsAction {
            if let command = setupStep.command, !command.isEmpty {
                return .copyCommandToClipboard(command: command, buttonLabel: "Copy")
            }
            if let linkURLString = setupStep.href, !linkURLString.isEmpty {
                guard ExternalLinkPolicy.isAllowedExternalURL(linkURLString) else {
                    return .openLinkIsUnavailable(
                        linkURLString: linkURLString,
                        reasonTheLinkCannotBeOpened: Self.reasonALinkCannotBeOpened(
                            linkURLString: linkURLString
                        )
                    )
                }
                return .openLinkInBrowser(
                    linkURLString: linkURLString,
                    buttonLabel: setupStep.actionLabel ?? "Open"
                )
            }
        }

        if setupRecoveryState.isOnTheLastSetupStep {
            return .runToolChecksForThisStep(
                buttonLabel: setupRecoveryState.aRecheckIsRunning ? "Checking…" : "Check again"
            )
        }
        let labelAfterACommand = setupStep.command?.isEmpty == false ? "I ran it" : labelForMovingOn
        return .advanceToTheNextStep(buttonLabel: labelAfterACommand)
    }

    /// Runs whatever the primary button is currently offering.
    func performPrimaryAction() {
        // Moving on, or acting on the step, hands the step back to the watch
        // loop: the reader is no longer parked here on purpose.
        readerDeliberatelyReturnedToThisStep = false
        // And the note explaining a corrected position belongs to the step it
        // was about; carried forward it would explain the wrong thing.
        positionWasCorrectedExplanation = nil
        guard let primaryAction = primaryActionForTheCurrentStep else {
            return
        }
        switch primaryAction {
        case .copyCommandToClipboard(let command, _):
            copyCommandToClipboard(command)
        case .openLinkInBrowser(let linkURLString, _):
            openLinkInBrowser(linkURLString)
        case .openLinkIsUnavailable:
            // Deliberately nothing: this action is drawn as a disabled control
            // with its reason showing, and is never wired to a press.
            break
        case .runToolChecksForThisStep:
            if readerIsInSetupRecovery {
                recheckThePrerequisitesForSetupRecovery()
            } else {
                runToolChecksForTheCurrentStep()
            }
        case .advanceToTheNextStep:
            if readerIsInSetupRecovery {
                advanceToTheNextSetupStep()
            } else {
                advanceToTheNextStep()
            }
        case .startAutopilotForThisGuide:
            startAutopilot()
        }
    }

    // MARK: - Autopilot

    /// True while the reader is actively following a guide (as opposed to no
    /// guide, or the completion card). The panel stays pinned in this state:
    /// a running install must not vanish because a click or the pointer
    /// wandered off it — dismissal is the × button or End only.
    var isActivelyGuiding: Bool {
        loadState == .guideIsOpen && !readerHasFinishedTheGuide
    }

    /// Whether to offer the "Let Iris run it" gesture: autopilot is supported,
    /// a guide is open, autopilot is not already running, and the branch has at
    /// least one command Iris could execute. Offering it on a guide with
    /// nothing to run would be a dead button.
    var canOfferAutopilot: Bool {
        guard makeAutopilotRunner != nil, isActivelyGuiding, !autopilotIsRunning,
              let branch = selectedBranch else { return false }
        return branch.steps.contains { stepIsAutopilotExecutable($0) }
    }

    /// True while Iris is executing a terminal step itself. The exit code is
    /// then the step's verdict, so the watch loop stands down for that step.
    ///
    /// Once autopilot has handed this step back to the reader (it surfaced,
    /// skipped, or could not run it), Iris no longer owns it: the watch loop
    /// takes over so it can notice the reader finished the step and advance,
    /// which resumes the install for the remaining steps.
    var autopilotOwnsTheCurrentStep: Bool {
        guard autopilotIsRunning,
              !autopilotHandedTheCurrentStepToTheReader,
              let step = currentStep else { return false }
        return (step.kind == .terminal || step.kind == .check)
            && step.command != nil
            && step.watch?.sensitive != true
            && !GuideAutopilotCommandShape.holdsTheShellOpen(step.command ?? "")
    }

    /// The one entry point that begins execution. Reachable only from
    /// `performPrimaryAction` (the reader tapping "Let Iris run it"), which is
    /// the whole security argument: a crafted `iris://` link can preselect a
    /// guide and step, but it lands the reader on this button — it cannot
    /// press it. Nothing about opening a guide calls this.
    func startAutopilot() {
        // EVERY refusal below names itself. This guard used to be six conditions
        // and one bare `return`, which is the literal shape of the "I click Let
        // Iris run it and nothing happens" report: the tap lands, nothing moves,
        // and the reader is told nothing. The consent paths further down had
        // already been given explanations for exactly this reason — but see
        // `autopilotBlockedExplanation`, which until now was set and never
        // displayed, so even those refusals were silent.
        if autopilotIsRunning {
            irisTrace("autopilot: start refused — already running")
            return
        }
        guard loadState == .guideIsOpen, let guide = guideBeingFollowed, let branch = selectedBranch else {
            autopilotBlockedExplanation = "This guide isn't open any more. Reopen it and try again."
            irisTrace("autopilot: start refused — guide not open (loadState=\(loadState))")
            return
        }
        guard !readerIsInSetupRecovery else {
            autopilotBlockedExplanation = "Finish the setup step Iris is helping with first, then Iris can run the rest."
            irisTrace("autopilot: start refused — reader is in setup recovery")
            return
        }
        guard let makeAutopilotRunner else {
            autopilotBlockedExplanation = "Iris can't start an install right now. Restart Iris and try again."
            irisTrace("autopilot: start refused — no runner factory wired")
            return
        }
        // One-time "Let Iris take control of your Mac?" consent, then remembered
        // across every future install. A vetted publik guide runs hands-off; the
        // reader grants blanket control once (revocable in settings) instead of
        // approving each command. If they decline, autopilot simply does not
        // start — the guide stays open for them to follow by hand.
        if !autonomyGrant.isGranted {
            guard let confirmAutonomousControl else {
                // No consent seam wired at all. Previously this returned in
                // silence, which is indistinguishable from a broken button.
                autopilotBlockedExplanation = "Iris can't ask for permission to run this install right now. Restart Iris and try again."
                irisTrace("autopilot: start refused — no consent seam wired")
                return
            }
            guard confirmAutonomousControl() else {
                // Declined, or the alert never reached the front. Either way the
                // reader tapped a button and something has to answer them: a bare
                // `return` here is exactly the "Let Iris run it does nothing"
                // report — the tap lands, nothing moves, and no reason is given.
                autopilotBlockedExplanation = "Iris needs permission to run installs itself. Turn on Auto-install in Iris's settings, or follow the steps by hand below."
                irisTrace("autopilot: start refused — reader declined, or the consent alert never reached the front")
                return
            }
            autonomyGrant.grant()
        }
        autopilotBlockedExplanation = nil
        let context = GuideAutopilotGuideContext(
            slug: guide.appSlug,
            version: guide.version,
            appName: guide.appName,
            platformLabel: branch.label,
            hostsReachedByTheGuide: Self.hostsReachedBy(branch: branch)
        )
        let runner = makeAutopilotRunner(context)
        autopilotRunner = runner
        autopilotIsRunning = true
        autopilotHandedTheCurrentStepToTheReader = false
        // While autopilot owns the current terminal step, the watch loop must
        // not also be watching it.
        pointTheWatchLoopAtTheCurrentStep()
        Task { await self.driveAutopilotFromTheCurrentStep(runner: runner, branch: branch) }
        // Raise the centered terminal takeover: the eye flies to the middle and
        // morphs into the terminal the install runs in.
        onAutopilotDidStart?()
    }

    /// Set by `CompanionManager` as it raises / tears down the takeover window.
    func setAutopilotIsShownAsTakeover(_ isShownAsTakeover: Bool) {
        autopilotIsShownAsTakeover = isShownAsTakeover
    }

    func stopAutopilot() {
        autopilotIsRunning = false
        runnerSessionHasStarted = false
        autopilotIsShownAsTakeover = false
        let runner = autopilotRunner
        autopilotRunner = nil
        Task { await runner?.endSession() }
        pointTheWatchLoopAtTheCurrentStep()
        // Fold the takeover away if it is still up (e.g. the reader ended the
        // guide mid-install).
        onAutopilotDidStop?()
    }

    /// The reader tapped Run it / Skip on a risky command's confirm row.
    func approveThePendingRiskyCommand() { autopilotRunner?.approvePendingCommand() }
    func skipThePendingRiskyCommand() { autopilotRunner?.skipPendingCommand() }

    /// The terminal's red close button — the escape hatch. While Iris is
    /// mid-step (a command in the shell, a pending confirm tap, or the fix
    /// ladder), it stops that step: the command is interrupted and the step
    /// lands on the "Your turn" row, so the install continues on the reader's
    /// terms. When nothing is in flight — Iris is already waiting on the
    /// reader — the red button means what it means on every Mac window:
    /// close. Autopilot ends, the takeover folds away, and the guide stays
    /// open where they left it.
    func abortOrCloseAutopilotFromTheEscapeHatch() {
        guard autopilotIsRunning, let runner = autopilotRunner else { return }
        if autopilotIsDriving {
            // The runner surfaces the step immediately (the "Your turn" row)
            // and the drive loop does the hand-back itself as the aborted
            // step unwinds — doing it eagerly here would un-muzzle the watch
            // loop while the drive loop is still inside the step.
            irisTrace("escape hatch: aborting the in-flight step")
            Task { await runner.abortTheCurrentStepBecauseTheReaderAskedToStop() }
        } else {
            irisTrace("escape hatch: nothing in flight → stopping autopilot")
            stopAutopilot()
        }
    }

    /// The reader tapped "Try again" on a step Iris surfaced. Re-run the step's
    /// command through the runner from the top; if it works this time, Iris
    /// carries on with the rest of the install on its own.
    func retryTheSurfacedStep() {
        guard autopilotIsRunning, !autopilotIsDriving,
              let runner = autopilotRunner,
              let branch = selectedBranch,
              currentStepIndex < branch.steps.count else { return }
        // Iris owns the step again for the duration of the retry, so the watch
        // loop stands down and cannot also advance it.
        autopilotHandedTheCurrentStepToTheReader = false
        pointTheWatchLoopAtTheCurrentStep()
        let step = branch.steps[currentStepIndex]
        let stepIndex = currentStepIndex
        let totalSteps = branch.steps.count
        Task {
            let result = await runner.executeStepCommand(
                step: step, stepIndex: stepIndex, totalSteps: totalSteps
            )
            numberOfCommandsAutopilotHasExecuted += 1
            switch result {
            case .succeeded:
                advanceFromWithinAutopilot()
            case .handedBackAsSensitive, .skippedByReader, .surfacedToReader:
                handTheCurrentStepBackToTheReader()
            case .longRunningStarted, .stopped:
                return
            }
        }
    }

    /// The reader tapped "Continue" on a step Iris surfaced — they are choosing
    /// to move past it. Skip it and let Iris run the remaining steps.
    func skipTheSurfacedStepAndContinue() {
        guard autopilotIsRunning else { return }
        autopilotHandedTheCurrentStepToTheReader = false
        advanceToTheNextStep()
    }

    /// The reader tapped "I did it — continue" on a manual step the takeover
    /// parked on — a permission grant or a sign-in that macOS won't let Iris
    /// read, so there is no watch signal to auto-advance and the reader tells it
    /// when they are done. Advance and resume the install, exactly as the watch
    /// loop does for a step it CAN confirm.
    func readerFinishedTheGatedStep() {
        guard autopilotIsRunning else { return }
        autopilotHandedTheCurrentStepToTheReader = false
        advanceToTheNextStep()
    }

    /// What the chat model is told about the guide the reader is on, so a
    /// "why is this failing" question is answered from the step and the real
    /// terminal output — not inferred from a screenshot. This is the direct
    /// fix for the fabricated-diagnosis failure (`ping api.publik.local`): the
    /// model is handed the exact command and its output instead of guessing.
    ///
    /// It answers with something whenever this Mac knows the reader is midway
    /// through an install, not only while the card is open. An install does not
    /// stop existing because the panel is closed or the app was relaunched, and
    /// a model told nothing answers a question about step seven with "navigate
    /// to the workflow".
    func chatContextForTheAssistant() -> String? {
        // A step on screen is the richest thing to hand over: the exact step,
        // its command, and the real terminal output underneath it.
        if loadState == .guideIsOpen, !readerIsInSetupRecovery,
           let guide = guideBeingFollowed, let step = currentStep {
            return contextForTheGuideTheReaderIsLookingAt(guide: guide, step: step)
        }

        // Everything below is why this no longer returns nil the moment the
        // panel is not showing a step. After a relaunch the chat was told
        // nothing at all, so a question about an install seven steps in came
        // back as "navigate to the workflow" — advice for somebody who has not
        // started. The reader's place is on disk either way, so the assistant
        // is told about it either way.
        guard let lastGuideTheReaderWasFollowing else { return nil }
        return contextForTheGuideTheReaderWasFollowing(lastGuideTheReaderWasFollowing)
    }

    /// The context for the step the reader is looking at right now.
    private func contextForTheGuideTheReaderIsLookingAt(
        guide: IrisGuide,
        step: IrisGuideStep
    ) -> String {
        // These numbers come from the same place the panel's "7 / 12" does —
        // the progress restored from storage when the guide opened — which is
        // what makes this sentence and the remembered one below agree.
        let progressPhrase = GuideTheReaderWasFollowing.progressPhrase(
            stepIndex: currentStepIndex,
            numberOfStepsInTheBranch: numberOfStepsInTheSelectedBranch,
            readerHasFinishedTheGuide: readerHasFinishedTheGuide
        )
        // Saying what is already behind them is what stops the model answering
        // as though the install had not begun.
        let whatIsAlreadyBehindThem = currentStepIndex > 0
            ? " They are partway through: every step before this one is already done."
            : ""
        // A finished guide is a completion card, not a step the reader is "on",
        // and telling the model otherwise would have it coaching somebody
        // through work they have already done.
        var context: String
        if readerHasFinishedTheGuide {
            context = """
            [The reader has finished the \(guide.appName) install guide — all \
            \(numberOfStepsInTheSelectedBranch) steps are done. The last step was \
            titled "\(step.title)".
            """
        } else {
            context = """
            [The reader is following the \(guide.appName) install guide. They are on \
            \(progressPhrase), titled "\(step.title)".\(whatIsAlreadyBehindThem)
            """
        }
        if let command = step.command, !command.isEmpty {
            context += "\nThe step's command is:\n\(command)"
        }
        if let verifier = step.verifierLabel {
            context += "\nThe step is done when: \(verifier)"
        }
        if let tail = autopilotRunner?.currentTerminalTail(), !tail.isEmpty {
            context += "\nThe most recent output in Iris's terminal was:\n\(tail)"
        }
        context += """

        Answer from this and what is on screen. Do not invent commands, \
        hostnames, URLs, or file paths that are not in this guide or the \
        output above.]
        """
        return context
    }

    /// The context when the panel is not showing a guide step but this Mac
    /// remembers the reader partway through an install: after a relaunch, after
    /// they closed the card, or while the prerequisite detour has the card.
    private func contextForTheGuideTheReaderWasFollowing(
        _ guideTheReaderWasFollowing: GuideTheReaderWasFollowing
    ) -> String {
        let whereTheReaderStands: String
        if readerIsInSetupRecovery {
            whereTheReaderStands = """
            They are at \(guideTheReaderWasFollowing.humanReadableProgressPhrase), and Iris is \
            walking them through installing a missing prerequisite before they can carry on.
            """
        } else if guideTheReaderWasFollowing.readerHadFinishedTheGuide {
            whereTheReaderStands = """
            They reached the end of it. The guide is not open in Iris's panel right now.
            """
        } else {
            whereTheReaderStands = """
            They are partway through it, at \(guideTheReaderWasFollowing.humanReadableProgressPhrase) \
            — the steps before that one are already done — and the guide is not open in Iris's \
            panel right now.
            """
        }
        return """
        [The reader was last following the \(guideTheReaderWasFollowing.appName) install guide. \
        \(whereTheReaderStands)

        Answer about that install rather than assuming they have not started it, and offer to \
        reopen the guide if they want to carry on. Do not invent commands, hostnames, URLs, or \
        file paths that are not in this guide.]
        """
    }

    /// Whether the current step is one Iris executes itself (as opposed to a
    /// manual, open, permission, or dev-server step the reader/watch loop owns).
    private func stepIsAutopilotExecutable(_ step: IrisGuideStep) -> Bool {
        // `.check` is a tool probe (e.g. `git --version` / `node --version`) that
        // carries a real command. Running it in Iris's own login shell — which
        // has the reader's full PATH, unlike the app's own environment — both
        // shows output instead of a blank centered terminal AND passes where the
        // watch loop's ToolVersionService can't see a node/nvm/homebrew install.
        // A genuinely missing tool exits non-zero and hands back the normal way.
        //
        // A dev-server command (`npm start`) that holds the shell open IS
        // executable: executeStepCommand routes it to startLongRunning (a side
        // session), so Iris starts it rather than parking on it as a "manual"
        // step with nothing to point at. It is deliberately NOT in
        // `autopilotOwnsTheCurrentStep`, so the watch loop stays live to notice
        // the app came up — and a long-running step with no watch auto-advances
        // once started (see the `.longRunningStarted` case in the drive loop).
        (step.kind == .terminal || step.kind == .check)
            && (step.command?.isEmpty == false)
            && step.watch?.sensitive != true
    }

    /// A `.terminal` step that carries no command — a vestigial "open your
    /// Terminal", "you're now in the folder" instruction from the manual guide.
    /// There is nothing for Iris to run and nothing for the watch loop to
    /// confirm, and Iris is itself the terminal, so in autopilot it is a no-op
    /// that must be advanced past rather than parked on (parking it strands the
    /// whole install on a blank terminal — the cue `open-shell` step 0 wedge).
    private func stepIsAVestigialTerminalStepInAutopilot(_ step: IrisGuideStep) -> Bool {
        step.kind == .terminal && (step.command?.isEmpty ?? true)
    }

    private func driveAutopilotFromTheCurrentStep(
        runner: GuideAutopilotRunner,
        branch: IrisGuideBranch
    ) async {
        guard !autopilotIsDriving else { return }
        autopilotIsDriving = true
        defer { autopilotIsDriving = false }

        irisTrace("drive: entered, sessionStarted=\(self.runnerSessionHasStarted)")
        if !runnerSessionHasStarted {
            irisTrace("drive: awaiting startSession…")
            guard await runner.startSession() else {
                irisTrace("drive: startSession FAILED → stopAutopilot")
                stopAutopilot()
                return
            }
            irisTrace("drive: startSession OK")
            runnerSessionHasStarted = true
        }

        while autopilotIsRunning,
              !readerHasFinishedTheGuide,
              currentStepIndex < branch.steps.count {
            // A fresh step is Iris's again until proven otherwise, so ownership
            // is restored here rather than trusting every advance path to clear
            // the hand-back flag.
            autopilotHandedTheCurrentStepToTheReader = false
            let step = branch.steps[currentStepIndex]
            irisTrace("drive: step[\(self.currentStepIndex)] id=\(step.id) kind=\(String(describing: step.kind)) exec=\(self.stepIsAutopilotExecutable(step))")

            guard stepIsAutopilotExecutable(step) else {
                // A manual step: Iris opens what it can and then yields. The
                // watch loop notices completion and advances, which re-enters
                // this loop through `advanceToTheNextStep`.
                autoOpenIfTheStepPointsSomewhere(step)
                if stepIsFinishedOnceIrisHasOpenedIt(step)
                    || stepIsAVestigialTerminalStepInAutopilot(step) {
                    // Nothing for the watch loop to confirm and nothing only the
                    // reader can do: either Iris opening it *is* the step, or it
                    // is a commandless "open your Terminal / you're in the folder"
                    // instruction that is a no-op now that Iris *is* the terminal.
                    // Making the reader tap "Continue" here is exactly the friction
                    // they called out ("it's making me click to run the next step")
                    // — and with the takeover's corner card hidden there is no
                    // "Continue" to tap, so parking here strands the whole install
                    // on a blank terminal. Advance it ourselves after a beat.
                    await holdBetweenAutoAdvancedSteps()
                    guard autopilotIsRunning else { return }
                    advanceFromWithinAutopilot()
                    continue
                }
                // A manual step the reader must finish (a download, a drag, a
                // permission, a sign-in — including a guide whose very first step
                // is one). Point the eye at its control and park the takeover
                // terminal aside, so the reader can see and reach it rather than
                // stare at a blank centered terminal. The watch loop notices they
                // did it and advances, which resumes the install for the rest.
                irisTrace("drive: step \(step.id) → MANUAL branch, waiting at gate (return)")
                handTheCurrentStepBackToTheReader()
                onAutopilotWaitingForReaderAtGate?(step.title, step.body)
                return
            }

            // Coming off a manual step (or starting the first command): bring the
            // terminal back to center for the work Iris is about to do. A no-op
            // when it is already centered.
            onAutopilotResumedFromGate?()
            irisTrace("drive: executing \(step.id)…")
            let result = await runner.executeStepCommand(
                step: step, stepIndex: currentStepIndex, totalSteps: branch.steps.count
            )
            irisTrace("drive: \(step.id) result=\(String(describing: result))")
            numberOfCommandsAutopilotHasExecuted += 1
            switch result {
            case .succeeded:
                advanceFromWithinAutopilot()
            case .longRunningStarted:
                if step.watch?.expect.isEmpty ?? true {
                    // The dev server is up but the step declares no watch to
                    // confirm it (cue's `npm start` — cue launches hidden with
                    // showInactive() and no Dock icon, so there is nothing for
                    // the watch loop to detect). Advance ourselves after a beat
                    // rather than yielding to a watch loop that can never fire
                    // and stalling the whole install here.
                    await holdBetweenAutoAdvancedSteps()
                    guard autopilotIsRunning else { return }
                    advanceFromWithinAutopilot()
                    continue
                }
                // The step has a watch: the dev server runs in its own session
                // and the watch loop owns completion. Autopilot stays on, yields.
                return
            case .handedBackAsSensitive, .skippedByReader, .surfacedToReader:
                // Iris could not finish this step on its own. Hand it to the
                // reader: un-muzzle the watch loop so it can notice they did it
                // and advance (which resumes the install), point the eye at
                // wherever the step wants them, and yield until then.
                handTheCurrentStepBackToTheReader()
                return
            case .stopped:
                // The session died; nothing more to drive.
                return
            }
        }
    }

    /// Marks the current step the reader's to finish and re-aims the watch loop
    /// and the eye at it, so a gate Iris could not clear does not stall the
    /// whole install — the reader does that one step and Iris carries on.
    private func handTheCurrentStepBackToTheReader() {
        autopilotHandedTheCurrentStepToTheReader = true
        // Ownership just flipped, so this now begins watching the step instead
        // of standing the loop down.
        pointTheWatchLoopAtTheCurrentStep()
        // Fly the eye to whatever the step points at, so a non-technical reader
        // is shown where to act rather than left reading terminal scrollback.
        refreshPointingForTheOpenStep()
    }

    /// A step the reader has nothing left to do on once Iris has opened it: an
    /// `open` step with a link Iris actually opened and no completion check to
    /// satisfy. Deliberately narrow — `web`, `permission`, and `paste` steps
    /// ask the reader to sign in, grant something, or move a secret, so
    /// auto-advancing them would skip the very thing the step exists for; and
    /// a step that declares a `watch` expectation still lets the watch loop
    /// confirm it the moment the reader finishes.
    ///
    /// The `href` requirement is what keeps this honest: an `open` step with
    /// no link is a reader action dressed as an open ("Press Run" in Xcode),
    /// and Iris opened nothing — auto-advancing it abandoned the reader right
    /// before the action the step existed for.
    private func stepIsFinishedOnceIrisHasOpenedIt(_ step: IrisGuideStep) -> Bool {
        step.kind == .open && step.href != nil && (step.watch?.expect.isEmpty ?? true)
    }

    /// A short, deliberate pause before auto-advancing a step Iris handled on its
    /// own, so a complex install reads as a sequence of real work rather than a
    /// flash. Nothing real is waiting on it — it only paces the display.
    private func holdBetweenAutoAdvancedSteps() async {
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }

    /// Opens an `open`/`web` step's link (once) or a `permission` step's
    /// System Settings pane, so the reader lands where they need to act.
    private func autoOpenIfTheStepPointsSomewhere(_ step: IrisGuideStep) {
        guard !readerHasTakenThisStepsAction else { return }
        if (step.kind == .open || step.kind == .web), let href = step.href {
            openLinkInBrowser(href)
        } else if let pointedApp = step.point?.inApp,
                  pointedApp != "com.apple.systempreferences" {
            // The step is about a control inside a specific app — Xcode's
            // signing pane, its Run button, cue.app in a Finder window. Bring
            // that app forward: the eye's frontmost gate can then resolve the
            // authored point, and the reader lands where the step wants them.
            // Before this, a `permission` step like "Sign the app with your
            // Apple ID" fell into the System Settings branch below and opened
            // Privacy & Security over the top of Xcode — the wrong app,
            // guaranteed, and the reason the eye never pointed there.
            activateTheAppTheStepPointsInto(bundleIdentifier: pointedApp)
        } else if step.kind == .permission {
            openSystemSettingsForPermissionStep(step)
        }
    }

    /// Brings the app an authored point targets to the front, if it is
    /// running. Never launches it cold: a guide step that needs an app opened
    /// has an earlier step that opens it, and launching Xcode because a step
    /// mentions it would be a surprise, not a guide.
    private func activateTheAppTheStepPointsInto(bundleIdentifier: String) {
        guard let application = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        application.activate()
    }

    /// Take the reader to the System Settings pane a permission step is about.
    /// macOS won't let Iris grant the permission itself — that is exactly what
    /// TCC prevents — but it can open the right pane so the reader isn't hunting
    /// a sidebar of twenty near-identical rows. Best-effort pane match from the
    /// step's own words, falling back to the top of Privacy & Security.
    private func openSystemSettingsForPermissionStep(_ step: IrisGuideStep) {
        let text = (step.title + " " + step.body).lowercased()
        let anchor: String
        if text.contains("screen") {
            anchor = "Privacy_ScreenCapture"
        } else if text.contains("accessibility") {
            anchor = "Privacy_Accessibility"
        } else if text.contains("microphone") {
            anchor = "Privacy_Microphone"
        } else if text.contains("camera") {
            anchor = "Privacy_Camera"
        } else {
            // No recognizable TCC pane in the step's words. This used to fall
            // back to opening Privacy & Security anyway, which misdirected
            // every `permission` step that is not about a Mac permission at
            // all — an API-key step, "Trust yourself on the iPhone", "Plug in
            // your iPhone". Opening the wrong pane over the reader's work is
            // worse than opening nothing.
            return
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Advance without letting the watch-loop resume path also fire — the
    /// drive loop's own `while` handles the next step.
    private func advanceFromWithinAutopilot() {
        // Moving on, or acting on the step, hands the step back to the watch
        // loop: the reader is no longer parked here on purpose.
        readerDeliberatelyReturnedToThisStep = false
        // And the note explaining a corrected position belongs to the step it
        // was about; carried forward it would explain the wrong thing.
        positionWasCorrectedExplanation = nil
        advanceToTheNextStep()
    }

    /// Re-enters the drive loop after the watch loop advanced a manual step.
    /// The driving guard makes this a no-op if the drive loop is already
    /// running (an executed-step advance), so it never double-drives.
    func resumeAutopilotAfterAdvance() {
        guard autopilotIsRunning, !autopilotIsDriving,
              let runner = autopilotRunner, let branch = selectedBranch else { return }
        Task { await self.driveAutopilotFromTheCurrentStep(runner: runner, branch: branch) }
    }

    private static func hostsReachedBy(branch: IrisGuideBranch) -> Set<String> {
        var hosts: Set<String> = []
        for step in branch.setupSteps + branch.steps {
            if let command = step.command {
                hosts.formUnion(GuideAutopilotCommandShape.hostsTheCommandWouldReach(command))
            }
            if let href = step.href, let host = URL(string: href)?.host {
                hosts.insert(host.lowercased())
            }
        }
        return hosts
    }

    // MARK: - Copying and opening

    func copyCommandToClipboard(_ command: String) {
        let generalPasteboard = NSPasteboard.general
        generalPasteboard.clearContents()
        generalPasteboard.setString(command, forType: .string)
        readerHasTakenThisStepsAction = true
        showTransientCopyConfirmation()
    }

    /// Hands the link to `ExternalLinkPolicy`, which is the only thing in this
    /// app that decides whether a guide's host may be opened. Returns false when
    /// the policy refused, so a caller never has to guess.
    @discardableResult
    func openLinkInBrowser(_ linkURLString: String) -> Bool {
        let theLinkWasOpened = ExternalLinkPolicy.openExternalURLIfAllowed(linkURLString)
        if theLinkWasOpened {
            readerHasTakenThisStepsAction = true
        }
        return theLinkWasOpened
    }

    private func showTransientCopyConfirmation() {
        copyConfirmationDismissalTask?.cancel()
        transientCopyConfirmationText = "Copied — paste in \(nameOfTheShellForTheSelectedBranch)."
        copyConfirmationDismissalTask = Task { [weak self] in
            try? await Task.sleep(for: Self.copyConfirmationVisibleDuration)
            guard !Task.isCancelled else { return }
            self?.transientCopyConfirmationText = nil
        }
    }

    // MARK: - Tool checks

    /// The tools this step wants verified. A setup step names one outright in
    /// `tool`; a `check` step lists them as version probes in its command, which
    /// is what `extractSafeTools` reads in the Tauri panel.
    var toolNamesRequiredByTheCurrentStep: [String] {
        guard let step = currentStep else {
            return []
        }
        if let declaredTool = step.tool {
            return [declaredTool.rawValue]
        }
        guard step.kind == .check, let command = step.command else {
            return []
        }
        return Self.allowlistedToolNames(inVersionProbeCommand: command)
    }

    /// Reads `git --version\nnode --version` as ["git", "node"].
    ///
    /// The set of names this accepts is `ToolVersionService`'s table and nothing
    /// else. The Tauri app kept a second copy of that allowlist in JavaScript
    /// and the two drifted; there is exactly one here on purpose.
    static func allowlistedToolNames(inVersionProbeCommand command: String) -> [String] {
        var toolNamesFound: [String] = []
        for commandLine in command.split(separator: "\n") {
            let tokensOnThisLine = commandLine
                .split(whereSeparator: { character in character == " " || character == "\t" })
                .map(String.init)
            guard let executableName = tokensOnThisLine.first,
                  let toolSpecification = ToolVersionService.toolSpecification(for: executableName),
                  Array(tokensOnThisLine.dropFirst()) == toolSpecification.arguments,
                  !toolNamesFound.contains(executableName) else {
                continue
            }
            toolNamesFound.append(executableName)
        }
        return toolNamesFound
    }

    var everyRequiredToolWasFound: Bool {
        let toolNamesThisStepNeeds = toolNamesRequiredByTheCurrentStep
        guard !toolNamesThisStepNeeds.isEmpty else {
            return false
        }
        return toolNamesThisStepNeeds.allSatisfy { toolName in
            guard let row = toolCheckRows.first(where: { $0.toolName == toolName }) else {
                return false
            }
            if case .installedWithVersion = row.state {
                return true
            }
            return false
        }
    }

    /// Lists the step's tools without running anything. Landing on a step must
    /// not spawn processes — the reader presses the button when they are ready.
    private func prepareToolCheckRowsForTheCurrentStep() {
        toolChecksHaveBeenRunForThisStep = false
        toolCheckRows = toolNamesRequiredByTheCurrentStep.map { toolName in
            GuideToolCheckRow(toolName: toolName, state: .readyToCheck)
        }
    }

    func runToolChecksForTheCurrentStep() {
        let toolNamesToCheck = toolNamesRequiredByTheCurrentStep
        guard !toolNamesToCheck.isEmpty else {
            return
        }
        toolCheckTask?.cancel()
        toolChecksHaveBeenRunForThisStep = true
        toolCheckRows = toolNamesToCheck.map { toolName in
            GuideToolCheckRow(toolName: toolName, state: .checking)
        }
        toolCheckTask = Task { [weak self] in
            guard let self else { return }
            let rowsAfterChecking = await self.checkEveryTool(named: toolNamesToCheck)
            guard !Task.isCancelled else { return }
            self.toolCheckRows = rowsAfterChecking
        }
    }

    private func checkEveryTool(named toolNames: [String]) async -> [GuideToolCheckRow] {
        var rowsAfterChecking: [GuideToolCheckRow] = []
        for toolName in toolNames {
            rowsAfterChecking.append(await checkOneTool(named: toolName))
        }
        return rowsAfterChecking
    }

    /// A tool that is simply absent is data — the guide exists to install it —
    /// while a lookup that broke is an error worth naming. `ToolVersionService`
    /// already draws that line; this only translates it into a row.
    private func checkOneTool(named toolName: String) async -> GuideToolCheckRow {
        do {
            let toolVersion = try await checkToolVersion(toolName)
            guard toolVersion.available else {
                return GuideToolCheckRow(toolName: toolName, state: .notInstalled)
            }
            return GuideToolCheckRow(
                toolName: toolName,
                state: .installedWithVersion(version: toolVersion.version)
            )
        } catch let toolVersionError as ToolVersionError {
            return GuideToolCheckRow(
                toolName: toolName,
                state: .couldNotBeChecked(reason: toolVersionError.userFacingMessage)
            )
        } catch {
            return GuideToolCheckRow(
                toolName: toolName,
                state: .couldNotBeChecked(reason: error.localizedDescription)
            )
        }
    }

    // MARK: - The setup recovery detour

    /// The prerequisites a branch declares, read off its own setup steps. A
    /// branch that ships no setup steps declares nothing, which is the whole
    /// reason nothing is spawned for it: there would be no way to fix what the
    /// check found, and a red row with no route out is worse than no row.
    static func prerequisiteToolNames(declaredBy branch: IrisGuideBranch) -> [String] {
        var toolNamesInBranchOrder: [String] = []
        for setupStep in branch.setupSteps {
            guard let toolThisStepInstalls = setupStep.tool?.rawValue,
                  !toolNamesInBranchOrder.contains(toolThisStepInstalls) else {
                continue
            }
            toolNamesInBranchOrder.append(toolThisStepInstalls)
        }
        return toolNamesInBranchOrder
    }

    /// Runs the branch's prerequisite checks once, on the way in, and diverts
    /// the reader into the setup steps if anything they need is missing.
    private func enterSetupRecoveryIfAPrerequisiteIsMissing(forBranch branch: IrisGuideBranch) async {
        guard branch.unsupported == nil, !branch.setupSteps.isEmpty else {
            return
        }
        let prerequisiteToolNames = Self.prerequisiteToolNames(declaredBy: branch)
        guard !prerequisiteToolNames.isEmpty else {
            return
        }

        let prerequisiteCheckRows = await checkEveryTool(named: prerequisiteToolNames)
        // A tool that could not be checked is not a tool that is missing. Iris
        // has no idea what is on the machine in that case, and marching the
        // reader through an install they may not need is the wrong guess.
        let setupStepsToWalk = Self.setupSteps(
            fromBranch: branch,
            repairingToolsNamed: prerequisiteCheckRows
                .filter { row in row.state == .notInstalled }
                .map(\.toolName)
        )
        guard !setupStepsToWalk.isEmpty else {
            return
        }

        setupRecoveryState = GuideSetupRecoveryState(
            prerequisiteCheckRows: prerequisiteCheckRows,
            setupStepsToWalk: setupStepsToWalk,
            currentSetupStepIndex: 0,
            aRecheckIsRunning: false,
            messageFromTheMostRecentRecheck: nil
        )
        readerHasTakenThisStepsAction = false
    }

    private static func setupSteps(
        fromBranch branch: IrisGuideBranch,
        repairingToolsNamed toolNames: [String]
    ) -> [IrisGuideStep] {
        branch.setupSteps.filter { setupStep in
            guard let toolThisStepInstalls = setupStep.tool?.rawValue else {
                return false
            }
            return toolNames.contains(toolThisStepInstalls)
        }
    }

    /// Runs the prerequisite checks again. Finding everything ends the detour
    /// and drops the reader into the guide exactly where they already were;
    /// finding something still missing says so, because a button that reports
    /// nothing reads as a broken button.
    func recheckThePrerequisitesForSetupRecovery() {
        guard let branch = selectedBranch,
              var mutableSetupRecoveryState = setupRecoveryState else {
            return
        }
        let toolNamesToCheckAgain = mutableSetupRecoveryState.prerequisiteCheckRows.map(\.toolName)
        guard !toolNamesToCheckAgain.isEmpty else {
            return
        }

        setupRecheckTask?.cancel()
        mutableSetupRecoveryState.aRecheckIsRunning = true
        mutableSetupRecoveryState.messageFromTheMostRecentRecheck = nil
        mutableSetupRecoveryState.prerequisiteCheckRows = toolNamesToCheckAgain.map { toolName in
            GuideToolCheckRow(toolName: toolName, state: .checking)
        }
        setupRecoveryState = mutableSetupRecoveryState

        setupRecheckTask = Task { [weak self] in
            guard let self else { return }
            let rowsAfterChecking = await self.checkEveryTool(named: toolNamesToCheckAgain)
            guard !Task.isCancelled else { return }
            self.applyTheResultOfASetupRecheck(rowsAfterChecking, forBranch: branch)
        }
    }

    /// Waits for the re-check the reader started, for anything that is about to
    /// read the result back and would otherwise race it.
    func waitUntilTheSetupRecheckHasFinished() async {
        await setupRecheckTask?.value
    }

    private func applyTheResultOfASetupRecheck(
        _ rowsAfterChecking: [GuideToolCheckRow],
        forBranch branch: IrisGuideBranch
    ) {
        guard var mutableSetupRecoveryState = setupRecoveryState else { return }

        let toolNamesStillMissing = rowsAfterChecking
            .filter { row in row.state == .notInstalled }
            .map(\.toolName)
        if toolNamesStillMissing.isEmpty {
            // Nothing is in the reader's way any more, so the detour ends. The
            // guide's own step index was never touched while they were here,
            // which is why this lands them back where they left off rather than
            // at step one.
            leaveSetupRecovery()
            return
        }

        let setupStepsToWalkNext = Self.setupSteps(
            fromBranch: branch,
            repairingToolsNamed: toolNamesStillMissing
        )
        // Fixing Git but not Node shortens the detour to Node's step, so the
        // reader is not walked back through work they have already done.
        if setupStepsToWalkNext != mutableSetupRecoveryState.setupStepsToWalk {
            mutableSetupRecoveryState.setupStepsToWalk = setupStepsToWalkNext
            mutableSetupRecoveryState.currentSetupStepIndex = 0
            readerHasTakenThisStepsAction = false
        }
        mutableSetupRecoveryState.prerequisiteCheckRows = rowsAfterChecking
        mutableSetupRecoveryState.aRecheckIsRunning = false
        mutableSetupRecoveryState.messageFromTheMostRecentRecheck = Self.messageDescribing(
            rowsAfterChecking
        )

        if mutableSetupRecoveryState.setupStepsToWalk.isEmpty {
            // The branch has no step that repairs what is still missing, so
            // there is nothing left for the detour to show. Better to hand the
            // reader the guide than to hold them on an empty card.
            leaveSetupRecovery()
            return
        }
        setupRecoveryState = mutableSetupRecoveryState
    }

    /// The reader's own way out. Some people have the tool under a name the
    /// check cannot see — a shell alias, a version manager that only exports
    /// inside an interactive shell — and Iris being wrong about that must not
    /// be the end of their install.
    func skipSetupRecoveryAndContinueToTheGuide() {
        guard readerIsInSetupRecovery else { return }
        leaveSetupRecovery()
    }

    /// Ends the detour without writing anything: the guide's step index and its
    /// stored progress are exactly what they were before it started.
    private func leaveSetupRecovery() {
        setupRecheckTask?.cancel()
        setupRecheckTask = nil
        setupRecoveryState = nil
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        // Leaving the detour is the first moment the reader is actually on a
        // guide step, so it is the first moment there is anything to watch.
        pointTheWatchLoopAtTheCurrentStep()
    }

    func advanceToTheNextSetupStep() {
        defer { refreshPointingForTheOpenStep() }
        guard var mutableSetupRecoveryState = setupRecoveryState else { return }
        if mutableSetupRecoveryState.isOnTheLastSetupStep {
            // Past the last setup step there is nothing to show, only something
            // to verify, so the end of the detour is the re-check.
            recheckThePrerequisitesForSetupRecovery()
            return
        }
        mutableSetupRecoveryState.currentSetupStepIndex += 1
        mutableSetupRecoveryState.messageFromTheMostRecentRecheck = nil
        setupRecoveryState = mutableSetupRecoveryState
        cancelAnyWorkFromThePreviousStep()
    }

    func returnToThePreviousSetupStep() {
        defer { refreshPointingForTheOpenStep() }
        guard var mutableSetupRecoveryState = setupRecoveryState,
              mutableSetupRecoveryState.currentSetupStepIndex > 0 else {
            return
        }
        mutableSetupRecoveryState.currentSetupStepIndex -= 1
        mutableSetupRecoveryState.messageFromTheMostRecentRecheck = nil
        setupRecoveryState = mutableSetupRecoveryState
        cancelAnyWorkFromThePreviousStep()
    }

    // MARK: - What the setup card says

    /// "Git" rather than "git" in a sentence a person reads. The names outside
    /// this list are already spelled the way their own projects spell them.
    static func displayNameForTool(_ toolName: String) -> String {
        switch toolName {
        case "git": return "Git"
        case "node": return "Node"
        case "python", "python3": return "Python"
        case "java": return "Java"
        case "docker": return "Docker"
        case "cargo", "rustc": return "Rust"
        default: return toolName
        }
    }

    /// "Git", "Git and Node", "Git, Node, and Docker".
    static func sentenceListing(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return "\(names.dropLast().joined(separator: ", ")), and \(names[names.count - 1])"
        }
    }

    /// The setup card's headline: which prerequisite is in the way.
    var headlineForTheSetupRecoveryCard: String {
        guard let setupRecoveryState else { return "" }
        let missingToolDisplayNames = setupRecoveryState.toolNamesStillMissing
            .map(Self.displayNameForTool)
        guard !missingToolDisplayNames.isEmpty else {
            return "One thing to install first"
        }
        return "Iris could not find \(Self.sentenceListing(missingToolDisplayNames)) on this computer."
    }

    /// Why the guide cannot start without it. A reader told only "not installed"
    /// has to guess whether it matters; this says what breaks.
    var explanationForTheSetupRecoveryCard: String {
        guard let setupRecoveryState else { return "" }
        let reasonsEachMissingToolIsNeeded = setupRecoveryState.toolNamesStillMissing
            .map(Self.whyTheGuideNeedsTool)
        guard !reasonsEachMissingToolIsNeeded.isEmpty else {
            return ""
        }
        return reasonsEachMissingToolIsNeeded.joined(separator: " ")
    }

    static func whyTheGuideNeedsTool(_ toolName: String) -> String {
        switch toolName {
        case "git":
            return "Git is how this guide copies the app's code onto your computer, so the very first command fails without it."
        case "node":
            return "Node is what runs the app once its code is here, so the install stops partway through without it."
        default:
            return "\(displayNameForTool(toolName)) has to be installed before this guide's commands can run."
        }
    }

    /// What a re-check found, in one sentence. Both halves matter: a tool that
    /// is still absent and a tool Iris could not look at are different problems
    /// and only one of them is fixed by installing something.
    private static func messageDescribing(_ rowsAfterChecking: [GuideToolCheckRow]) -> String {
        let toolNamesStillMissing = rowsAfterChecking
            .filter { row in row.state == .notInstalled }
            .map { row in displayNameForTool(row.toolName) }
        if !toolNamesStillMissing.isEmpty {
            return "Iris still cannot find \(sentenceListing(toolNamesStillMissing)). Finish the steps above, then check again."
        }

        let firstRowThatCouldNotBeChecked = rowsAfterChecking.first { row in
            if case .couldNotBeChecked = row.state { return true }
            return false
        }
        if let firstRowThatCouldNotBeChecked,
           case .couldNotBeChecked(let reason) = firstRowThatCouldNotBeChecked.state {
            return "Iris could not check \(displayNameForTool(firstRowThatCouldNotBeChecked.toolName)) — \(reason)"
        }
        return "Everything this guide needs is installed."
    }

    // MARK: - Navigation

    func advanceToTheNextStep() {
        // Moving on, or acting on the step, hands the step back to the watch
        // loop: the reader is no longer parked here on purpose.
        readerDeliberatelyReturnedToThisStep = false
        // And the note explaining a corrected position belongs to the step it
        // was about; carried forward it would explain the wrong thing.
        positionWasCorrectedExplanation = nil
        defer { refreshPointingForTheOpenStep() }
        // The detour must never move the reader's place in the guide, so this
        // refuses outright rather than trusting every caller to check first.
        guard !readerIsInSetupRecovery else { return }
        guard let branch = selectedBranch, branch.unsupported == nil, !branch.steps.isEmpty else {
            return
        }
        let lastStepIndex = branch.steps.count - 1
        let wasAlreadyFinished = readerHasFinishedTheGuide
        if currentStepIndex >= lastStepIndex {
            // Past the last step is the completion card, never a step index the
            // branch does not have.
            currentStepIndex = lastStepIndex
            readerHasFinishedTheGuide = true
            // The install just crossed the finish line. Fire the completion hook
            // once — repeat advances (a late watch-loop tick) must not relaunch
            // the app or re-scan on every call.
            if !wasAlreadyFinished, let guide = guideBeingFollowed {
                onGuideCompleted?(guide, branch)
            }
        } else {
            currentStepIndex += 1
        }
        // A new step is Iris's to own again, so this must be cleared before the
        // watch loop is re-pointed below — otherwise the loop would keep
        // watching a step autopilot is about to execute and the two would race
        // to advance it.
        autopilotHandedTheCurrentStepToTheReader = false
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        pointTheWatchLoopAtTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
        // If the watch loop advanced a manual step while autopilot is on,
        // pick the install back up. A no-op when the drive loop itself just
        // advanced (its guard), so this never double-drives.
        resumeAutopilotAfterAdvance()
    }

    func returnToThePreviousStep() {
        defer { refreshPointingForTheOpenStep() }
        // Back means "the previous thing I was looking at", which inside the
        // detour is the previous setup step.
        if readerIsInSetupRecovery {
            returnToThePreviousSetupStep()
            return
        }
        guard let branch = selectedBranch, branch.unsupported == nil, !branch.steps.isEmpty else {
            return
        }
        if readerHasFinishedTheGuide {
            // Backing out of the completion card puts the reader on the last
            // step rather than one before it, which is where they just were.
            readerHasFinishedTheGuide = false
        } else if currentStepIndex > 0 {
            currentStepIndex -= 1
            readerDeliberatelyReturnedToThisStep = true
        } else {
            // Already on the first step. There is nowhere further back, and a
            // negative index would be a crash rather than a wrap-around.
            return
        }
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        pointTheWatchLoopAtTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
    }

    func restartTheGuide() {
        defer { refreshPointingForTheOpenStep() }
        guard selectedBranch != nil else { return }
        currentStepIndex = 0
        readerHasFinishedTheGuide = false
        cancelAnyWorkFromThePreviousStep()
        prepareToolCheckRowsForTheCurrentStep()
        pointTheWatchLoopAtTheCurrentStep()
        startPersistingProgressForTheCurrentPosition()
    }

    /// Points the watch loop at whatever step the reader is now on, or stops it
    /// outright when there is nothing to watch.
    ///
    /// The setup detour is deliberately never watched: it is not the guide, its
    /// steps end in a re-check the reader presses, and advancing "the step" from
    /// inside it would move the reader's place in a guide they have not started.
    /// True while the reader is on a step because they deliberately navigated
    /// BACK to it, rather than because the guide brought them here.
    ///
    /// The bug this exists for: "I can only click back till step 5." Nothing
    /// stops at step 5 — the reader is being PUSHED there. Steps 1 through 4 of
    /// the whimprflow guide watch for git, node, pnpm and cargo, all of which
    /// are already installed by the time anyone is deep enough to want to go
    /// back, so each one is satisfied the instant it is watched and advances
    /// again. Step 5 is the first with no watch block, so that is where the
    /// bouncing stops.
    ///
    /// The underlying mistake is that the watch loop reads a LEVEL ("cargo
    /// exists") as an EVENT ("they just installed cargo"). Going forward that
    /// is a feature — a prerequisite already met should not be busywork. Going
    /// backward it makes the Back button a no-op, which is worse than not
    /// having one. So a step the reader chose to return to holds until they act
    /// on it.
    private var readerDeliberatelyReturnedToThisStep = false

    private func pointTheWatchLoopAtTheCurrentStep() {
        guard loadState == .guideIsOpen,
              !readerIsInSetupRecovery,
              !readerHasFinishedTheGuide,
              let step = currentStep else {
            watchLoop.stopWatching()
            return
        }
        // When autopilot is executing this step, its exit code is the verdict
        // and the loop stands down — the two must not both advance it. Manual,
        // open, permission, and dev-server steps stay the loop's to watch.
        if autopilotOwnsTheCurrentStep {
            watchLoop.stopWatching()
            return
        }
        // A step with no `watch` block leaves this having started nothing.
        watchLoop.beginWatching(step: step)
    }

    /// Clears the copy confirmation and the "I ran it" latch, and stops any
    /// tool check still running for the step being left behind — otherwise its
    /// result would land in the next step's rows.
    private func cancelAnyWorkFromThePreviousStep() {
        copyConfirmationDismissalTask?.cancel()
        copyConfirmationDismissalTask = nil
        toolCheckTask?.cancel()
        toolCheckTask = nil
        transientCopyConfirmationText = nil
        readerHasTakenThisStepsAction = false
    }

    // MARK: - Progress

    private func restoreSavedProgress(forBranch branch: IrisGuideBranch) async {
        guard let guide = guideBeingFollowed else { return }
        // The version is baked into the storage key, so a guide that has moved
        // to a new version simply finds nothing saved and starts at step one.
        // That is the point: step nine of version two may not exist in version
        // three, and resuming into it would drop the reader somewhere wrong.
        let savedProgress = await guideService.loadProgress(
            slug: guide.appSlug,
            version: guide.version,
            branchKey: branch.branchKey
        )
        let lastStepIndex = max(0, branch.steps.count - 1)
        var resumeIndex = min(max(0, savedProgress.stepIndex), lastStepIndex)

        // Progress storage remembers where the reader WAS; it knows nothing
        // about what the machine still HAS. A wiped machine (or a deleted
        // clone, or a trashed app) resumes mid-guide into work that no
        // longer exists — the reader lands on "paste your key" for an app
        // that was never rebuilt here. So a resume is validated against
        // reality, and an unmet prerequisite restarts from step one: the
        // guides' steps are idempotent by design (guarded clones, cached
        // installs), so a restart on a machine that actually has everything
        // blitzes back in seconds, while a restart on a wiped machine is
        // exactly what the reader needs.
        var realityCheckFailed = false
        if resumeIndex > 0,
           !savedProgressStillMatchesThisMachine(branch: branch, resumeIndex: resumeIndex) {
            irisTrace("progress: saved step \(resumeIndex) for \(guide.appSlug) fails the reality check — restarting from step one")
            resumeIndex = 0
            realityCheckFailed = true
        }

        currentStepIndex = resumeIndex
        readerHasFinishedTheGuide = savedProgress.isCompleted && !realityCheckFailed

        // The clone/app reality check above answers "is this resume obviously
        // stale". It cannot answer "step 11 copies something step 10 builds,
        // and that thing is not there" — which is the reported failure, because
        // the reader resumed AT the install step rather than past it. So the
        // machine gets asked properly, off the opening path so nothing waits on
        // a model call, and advisory throughout.
        if !readerHasFinishedTheGuide {
            let branchForTheCheck = branch
            let indexAtOpen = currentStepIndex
            let nameForTheCheck = guide.appName
            Task { [weak self] in
                await self?.correctTheResumePositionIfTheMachineDisagrees(
                    branch: branchForTheCheck,
                    rememberedIndex: indexAtOpen,
                    guideName: nameForTheCheck
                )
            }
        }

        // Opening or switching a branch is itself a position worth remembering:
        // a reader who opens a guide and quits without pressing anything still
        // expects Iris to know which guide they were in.
        rememberThisAsTheGuideTheReaderIsFollowing()
    }

    /// The reality check behind a resume: every `git clone` step BEFORE the
    /// resume point must have its repository present, and a branch that
    /// installs a desktop app must actually have it installed before the
    /// reader may resume past the step that installs it.
    private func savedProgressStillMatchesThisMachine(
        branch: IrisGuideBranch, resumeIndex: Int
    ) -> Bool {
        for (index, step) in branch.steps.enumerated() where index < resumeIndex {
            if let repositoryPath = WatchLoop.repositoryPathAGitCloneWouldCreate(inCommand: step.command) {
                var isDirectory: ObjCBool = false
                let gitPath = (repositoryPath as NSString).appendingPathComponent(".git")
                if !FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                    return false
                }
            }
        }
        // Past the app-installing step with no app on disk = a stale resume,
        // whatever the storage says. The bundle check is injected by
        // CompanionManager (inventory-backed); absent injection, trust the
        // clone check alone rather than failing every resume.
        if let bundleId = branch.installedDesktopAppBundleId,
           let installedDesktopAppCheck,
           resumeIndex > (indexOfTheStepThatInstallsTheApp(inBranch: branch) ?? Int.max),
           !installedDesktopAppCheck(bundleId) {
            return false
        }
        return true
    }

    /// The step whose completion puts the app on disk: the last terminal
    /// step with a command, which for every desktop guide is the install/
    /// open step at the tail of the build sequence.
    private func indexOfTheStepThatInstallsTheApp(inBranch branch: IrisGuideBranch) -> Int? {
        branch.steps.lastIndex { $0.kind == .terminal && !($0.command ?? "").isEmpty }
    }

    /// Injected by CompanionManager: is this bundle actually installed?
    var installedDesktopAppCheck: ((String) -> Bool)?

    // MARK: - Working out where the reader actually is

    /// Injected by CompanionManager: one model call, system prompt and user
    /// message in, reply out, nil on any failure. Injected rather than reached
    /// for so this whole path is testable without a network.
    var askTheModelWhereTheReaderIs: ((String, String) async -> String?)?

    /// The facts a machine can establish about itself for this branch, gathered
    /// with no model involved. See `GuideActualPositionFinder` for why the split
    /// is drawn here.
    private func gatherPositionEvidence(forBranch branch: IrisGuideBranch) async -> GuidePositionEvidence {
        var facts: [GuidePositionFact] = []

        // 1. Every tool any step watches for. These are the cheap, decisive
        //    ones — "cargo responds" settles whether the Rust step is done far
        //    better than remembering that somebody pressed Next.
        var toolNamesAlreadyAsked: Set<String> = []
        for step in branch.setupSteps + branch.steps {
            for expectation in step.watch?.expect ?? [] {
                guard case .toolVersion(let toolName) = expectation,
                      !toolNamesAlreadyAsked.contains(toolName) else { continue }
                toolNamesAlreadyAsked.insert(toolName)
                let row = await checkOneTool(named: toolName)
                let answer: String
                switch row.state {
                case .installedWithVersion(let version): answer = "yes (\(version))"
                case .notInstalled: answer = GuidePositionEvidence.absent
                default: answer = GuidePositionEvidence.couldNotCheck
                }
                facts.append(GuidePositionFact(
                    question: "does `\(toolName)` respond on this machine", answer: answer
                ))
            }
        }

        // 2. Every clone a step would create. A guide whose clone is missing is
        //    at step one whatever storage says.
        for step in branch.steps {
            guard let repositoryPath = WatchLoop.repositoryPathAGitCloneWouldCreate(
                inCommand: step.command
            ) else { continue }
            let gitPath = (repositoryPath as NSString).appendingPathComponent(".git")
            facts.append(GuidePositionFact(
                question: "does the checkout at \(repositoryPath) exist",
                answer: FileManager.default.fileExists(atPath: gitPath)
                    ? "yes" : GuidePositionEvidence.absent
            ))
            // 3. THE ONE THAT MATTERS MOST, and the reported failure: the
            //    artifacts later steps consume. `install-app` copies a bundle
            //    `package` builds, and resuming at the copy on a machine that
            //    never ran the build fails with exit 1 and explains nothing.
            for laterStep in branch.steps {
                for referencedPath in GuideActualPositionFinder.repositoryRelativePathsReferenced(
                    byCommand: laterStep.command
                ) {
                    let fullPath = (repositoryPath as NSString)
                        .appendingPathComponent(referencedPath)
                    facts.append(GuidePositionFact(
                        question: "does \(referencedPath) exist in the checkout",
                        answer: FileManager.default.fileExists(atPath: fullPath)
                            ? "yes" : GuidePositionEvidence.absent
                    ))
                }
            }
        }

        // 4. Is the finished app actually installed.
        if let bundleId = branch.installedDesktopAppBundleId {
            let answer: String
            if let installedDesktopAppCheck {
                answer = installedDesktopAppCheck(bundleId) ? "yes" : GuidePositionEvidence.absent
            } else {
                answer = GuidePositionEvidence.couldNotCheck
            }
            facts.append(GuidePositionFact(
                question: "is the finished app (\(bundleId)) installed", answer: answer
            ))
        }

        return GuidePositionEvidence(facts: facts)
    }

    /// Ask where the reader actually is, and move them back if the machine says
    /// they are further along than they are. Advisory throughout: any failure
    /// leaves the remembered position untouched.
    private func correctTheResumePositionIfTheMachineDisagrees(
        branch: IrisGuideBranch,
        rememberedIndex: Int,
        guideName: String
    ) async {
        guard rememberedIndex > 0, let askTheModelWhereTheReaderIs else { return }
        let evidence = await gatherPositionEvidence(forBranch: branch)
        guard evidence.isWorthInterpreting else {
            irisTrace("position: nothing checkable for \(guideName) — leaving resume at \(rememberedIndex)")
            return
        }
        let steps = branch.steps.enumerated().map { index, step in
            (index: index, id: step.id, title: step.title, command: step.command)
        }
        let userMessage = GuideActualPositionFinder.promptText(
            guideName: guideName, steps: steps, evidence: evidence
        )
        guard let reply = await askTheModelWhereTheReaderIs(
            GuideActualPositionFinder.systemPrompt, userMessage
        ) else {
            irisTrace("position: no reply for \(guideName) — leaving resume at \(rememberedIndex)")
            return
        }
        guard let verdict = GuideActualPositionFinder.verdict(
            fromReply: reply, numberOfSteps: branch.steps.count
        ) else {
            irisTrace("position: unusable reply for \(guideName) — leaving resume at \(rememberedIndex)")
            return
        }
        guard GuideActualPositionFinder.shouldMove(
            from: rememberedIndex, to: verdict.stepIndex
        ) else {
            irisTrace("position: machine agrees with step \(rememberedIndex) for \(guideName)")
            return
        }
        // Still where we left it? A reader who has pressed Next while this ran
        // owns their position; this check is advisory and must never yank them.
        guard currentStepIndex == rememberedIndex, !readerHasFinishedTheGuide else { return }
        irisTrace("position: moving \(guideName) from step \(rememberedIndex) to \(verdict.stepIndex) — \(verdict.reason)")
        currentStepIndex = verdict.stepIndex
        positionWasCorrectedExplanation = verdict.reason.isEmpty
            ? "Iris checked this Mac and picked up where the install actually is."
            : "Iris checked this Mac and moved you back: \(verdict.reason)"
        pointTheWatchLoopAtTheCurrentStep()
        refreshPointingForTheOpenStep()
    }

    /// Why the reader is not where they left off, when Iris moved them. Shown
    /// so a position that changes under them is explained rather than eerie.
    @Published private(set) var positionWasCorrectedExplanation: String?

    /// Starts a progress write without blocking whoever asked for it. Pressing
    /// Next has to feel instant, and storage is the one thing in that path that
    /// can be slow.
    private func startPersistingProgressForTheCurrentPosition() {
        progressPersistenceTask = Task { [weak self] in
            await self?.persistProgressForTheCurrentPosition()
        }
    }

    /// Waits for the most recent progress write to reach storage, for anything
    /// that is about to read progress back and would otherwise race it.
    func waitUntilProgressHasBeenPersisted() async {
        await progressPersistenceTask?.value
    }

    private func persistProgressForTheCurrentPosition() async {
        guard let guide = guideBeingFollowed, let branch = selectedBranch else { return }
        await guideService.saveProgress(
            slug: guide.appSlug,
            version: guide.version,
            branch: branch,
            progress: GuideProgress(
                stepIndex: currentStepIndex,
                isCompleted: readerHasFinishedTheGuide
            )
        )
        // Every write of "how far in" also writes "into what". The two halves
        // of the reader's place go to disk together or the resume offer drifts
        // behind the progress it is describing.
        rememberThisAsTheGuideTheReaderIsFollowing()
    }

    /// Writes down which guide and branch the reader is on, beside the
    /// `iris:progress:…` keys that record how far into it they are.
    ///
    /// A no-op when nothing changed, so the ordinary case — a refresh that
    /// lands on the same position — does not republish and redraw the panel.
    private func rememberThisAsTheGuideTheReaderIsFollowing() {
        guard let guide = guideBeingFollowed, let branch = selectedBranch else { return }
        let guideTheReaderIsFollowing = GuideTheReaderWasFollowing(
            slug: guide.appSlug,
            appName: guide.appName,
            version: guide.version,
            branchKey: branch.branchKey,
            stepIndex: currentStepIndex,
            numberOfStepsInTheBranch: branch.steps.count,
            readerHadFinishedTheGuide: readerHasFinishedTheGuide
        )
        guard guideTheReaderIsFollowing != lastGuideTheReaderWasFollowing else { return }
        lastGuideTheReaderWasFollowing = guideTheReaderIsFollowing
        lastFollowedGuideMemory.remember(guideTheReaderIsFollowing)
    }

    /// Forgets every guide's saved place, the same reset the Tauri panel offers.
    func clearAllStoredGuideProgress() async {
        await guideService.clearAllStoredProgress()
        // The pointer to the guide goes with the progress it points into. A
        // reset that left "Resume publikclip — step 7 of 12" on the panel would
        // be offering the reader a place that no longer exists.
        lastFollowedGuideMemory.forgetTheRememberedGuide()
        lastGuideTheReaderWasFollowing = nil
        if selectedBranch != nil {
            currentStepIndex = 0
            readerHasFinishedTheGuide = false
            cancelAnyWorkFromThePreviousStep()
            prepareToolCheckRowsForTheCurrentStep()
            pointTheWatchLoopAtTheCurrentStep()
        }
    }
}
