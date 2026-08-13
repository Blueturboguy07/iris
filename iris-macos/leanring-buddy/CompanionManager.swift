//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the Iris companion. Owns the global summon
//  hotkey, screen capture, the Claude request pipeline, and the cursor
//  overlay. Exposes observable assistant state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

/// The assistant's request lifecycle. Text-first flow:
/// idle → capturing (screenshot) → thinking (Claude) → pointing (optional) → idle.
enum CompanionAssistantState {
    case idle
    case capturing
    case thinking
    case pointing
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var assistantState: CompanionAssistantState = .idle
    /// The most recent message the user submitted from the panel text field.
    @Published private(set) var latestUserMessageText: String?
    /// The most recent assistant response (point tag stripped), shown in the
    /// input bar under the eye.
    @Published private(set) var latestAssistantResponseText: String?

    /// Bumped once every time a response is published — an answer or the
    /// sentence explaining a failure.
    ///
    /// WHY A COUNTER AND NOT JUST THE TEXT. The bar under the eye renders one
    /// exchange, so it has to be able to tell "the answer to the question I
    /// just sent has arrived" apart from "the words from last time are still
    /// sitting there". Watching the text cannot do that: ask the same question
    /// twice and the text is identical both times, so nothing changes and the
    /// bar would sit on "working…" forever.
    @Published private(set) var assistantResponseGenerationCount: Int = 0

    /// Whether `latestAssistantResponseText` is a failure sentence rather than
    /// a real answer. The bar shows both in the same place deliberately — an
    /// error is what came back from the question, not a separate event — and
    /// uses this only to tint it.
    @Published private(set) var latestResponseWasAFailureMessage: Bool = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let globalSummonHotkeyMonitor = GlobalSummonHotkeyMonitor()
    let overlayWindowManager = OverlayWindowManager()

    /// The centered terminal takeover the autopilot runs the install in — the
    /// eye morphs into it and back. Raised and dismissed from the guide's
    /// start/stop/completion hooks below.
    private let autopilotTakeoverController = GuideAutopilotTakeoverController()

    /// Owns sign-in and the user's own Anthropic key. The panel observes it
    /// directly, and the request pipeline below asks it which route to take.
    let accountService = AccountService()

    /// Owns the install guide the reader is currently following, if any. It
    /// lives here rather than in the panel view because an `iris://guide/…`
    /// link can arrive while the panel has never been opened, and the guide has
    /// to survive the panel being closed and reopened.
    ///
    /// Lazy so its autopilot-runner factory can capture `self.claudeAPI`. The
    /// factory is called only when the reader taps "Let Iris run it", never at
    /// init, so building the runner from the app's live ClaudeAPI here is safe.
    lazy var guideSessionController = GuideSessionController(
        makeAutopilotRunner: { [weak self] context in
            let claudeAPI = self?.claudeAPI ?? ClaudeAPI(resolveTransport: {
                .failure(.transportFailure(reason: "assistant unavailable"))
            })
            return GuideAutopilotRunner(
                shellSession: GuideAutopilotShellSession(),
                longRunningSession: GuideAutopilotShellSession(),
                fixProposer: GuideAutopilotFixProposer(claudeAPI: claudeAPI),
                guideContext: context
            )
        }
    )

    /// Knows which publik catalog apps are installed on this Mac and which of
    /// them has a newer release. It lives here rather than in the panel view so
    /// the scan it did survives the panel being closed and reopened — the
    /// alternative is a Spotlight query every time somebody glances at Iris.
    let appInventoryService = AppInventoryService()

    /// Knows which publik apps are running *right now* and can ask them what
    /// they are doing. The inventory above answers "is it installed"; this
    /// answers "and what is wrong with it", which is the question a screenshot
    /// cannot reach — see `docs/iris-app-integration-plan.md`.
    let appLinkService = AppLinkService()

    /// Where the funded tier lives — publik in a shipped build, and a localhost
    /// origin when a developer's Info.plist says so.
    private let publikBaseURL = AssistantTransport.configuredPublikBaseURL()

    // MARK: - Maintain mode

    /// Where an app came from decides whether Iris may ever patch it.
    let installProvenanceStore = InstallProvenanceStore()
    /// The pool transport and this install's pseudonymous identity, shared
    /// by the coordinator and the replay engine below.
    private let maintainPoolClient = MaintainPoolClient()
    private let maintainInstallIdentity = MaintainInstallIdentity()
    /// The detect → ask → file ladder. The panel renders its pendingAsk.
    /// Lazy so everything shares the one provenance store above.
    lazy var maintainIncidentCoordinator = MaintainIncidentCoordinator(
        poolClient: maintainPoolClient,
        provenanceStore: installProvenanceStore,
        replayEngine: RecipeReplayEngine(
            provenanceStore: installProvenanceStore,
            poolClient: maintainPoolClient,
            installIdentity: maintainInstallIdentity
        )
    )
    private var crashArtifactWatcher: CrashArtifactWatcher?
    private let hangProbe = HangProbe()
    private var hangProbeTimer: Timer?
    /// The hang the probe is currently tracking, so the ask fires once on
    /// recovery/termination rather than every tick.
    private var confirmedHangByPid: [pid_t: (slug: String, name: String, stack: BreakAppStack, seconds: Int)] = [:]

    /// Slug → stack for signature normalization. Server-provided later; a
    /// table here first because /api/iris/apps does not carry it yet.
    static let catalogAppStacksBySlug: [String: BreakAppStack] = [
        "cue": .electron,
        "whimprflow": .tauri,
        "hickeyfield": .tauri,
        "plantgpt": .electron,
        "publikclip": .tauri,
        "nutcracker": .nextjs,
        "openascii": .nextjs,
        "noscroll": .other,
        "lunara": .other,
    ]

    private lazy var claudeAPI: ClaudeAPI = {
        // The transport is resolved per request rather than captured once,
        // because the user can sign in, sign out, or paste a key between two
        // messages and the very next request has to respect that.
        let accountService = self.accountService
        let publikBaseURL = self.publikBaseURL
        return ClaudeAPI(
            resolveTransport: {
                await accountService.currentAssistantTransport(publikBaseURL: publikBaseURL)
            },
            model: selectedModel
        )
    }()

    /// Turns a failed request into what the panel says, and — when the funded
    /// tier reports the session is gone — into a refresh-or-sign-out on the
    /// account service, so the user is shown sign-in buttons rather than the
    /// same error over and over.
    private func describeAndHandle(assistantError: Error) async -> String {
        guard let transportError = assistantError as? AssistantTransportError else {
            print("⚠️ Companion response error: \(assistantError)")
            return AssistantTransportError.transportFailure(
                reason: assistantError.localizedDescription
            ).userFacingMessage
        }

        if transportError.requiresReSignIn {
            await accountService.handleAccessTokenRejectedByServer()
        }
        return transportError.userFacingMessage
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's message and Claude's response.
    private var conversationHistory: [(userMessage: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// submits a new message so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var summonHotkeyTransitionCancellable: AnyCancellable?
    private var accountStateChangeCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// asks something else before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all required permissions (accessibility, screen recording,
    /// screen content) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Iris cursor should be shown.
    /// When toggled off, the overlay only appears transiently during a response.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()

        // The watch loop's one model call goes through the same two routes as
        // every other model call in this app. This line is why it does not need
        // a credential of its own: the account service that resolves the
        // transport lives here, so the loop is handed the resolution rather than
        // ever building one.
        let accountServiceForTheWatchLoop = accountService
        let publikBaseURLForTheWatchLoop = publikBaseURL
        guideSessionController.watchLoop.useTransportForVisualChecks {
            await accountServiceForTheWatchLoop.currentAssistantTransport(
                publikBaseURL: publikBaseURLForTheWatchLoop
            )
        }

        print("🔑 Iris start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        // Discovery is a directory listing, so it can run on a timer and costs
        // nothing. Talking to an app is not, and only happens when asked.
        appLinkService.startWatchingForRunningApps()
        connectTheGuideToTheEye()
        bindSummonHotkeyTransitions()
        bindAccountStateChanges()

        // Trade the stored refresh token for a live access token, then warm the
        // TLS connection to whichever host that leaves us talking to. Both are
        // best-effort and neither blocks the panel from appearing.
        Task {
            await accountService.restorePreviousSessionIfPossible()
            await claudeAPI.warmUpTLSConnectionIfNeeded()
        }

        startMaintainMode()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        // The buddy has flown back to the cursor — pointing is over.
        if assistantState == .pointing {
            assistantState = .idle
        }
    }

    /// Lets a guide step fly the eye without the guide controller knowing that
    /// overlays, screens or AppKit exist.
    ///
    /// The eye is already the app's one way of saying "there" — the assistant's
    /// `[POINT:…]` answers use exactly these two properties — so a guide step
    /// reuses it rather than inventing a second kind of arrow.
    private func connectTheGuideToTheEye() {
        // Wire the model-based locator so the eye can fly to a control the
        // accessibility tree can't name (a System Settings toggle, a web
        // button) — the same capture → [POINT] → global-coords path the
        // assistant's own pointing uses. Only called when the pointing ladder
        // has already decided the model may look (non-sensitive step, screen
        // recording granted).
        guideSessionController.targetLocator = SystemGuideTargetLocator(askTheModel: { [weak self] stepTitle, stepBody in
            guard let self else { return nil }
            return await self.locateGuideTargetWithModel(stepTitle: stepTitle, stepBody: stepBody)
        })
        guideSessionController.irisMayLookAtTheScreenForPointing = hasScreenRecordingPermission

        guideSessionController.sendTheEyeTo = { [weak self] location, displayFrame, label in
            guard let self else { return }
            // The overlay can be hidden here — cursor toggled off, or faded
            // out after a transient interaction. A guide point into a hidden
            // overlay is a silent no-op: the step says "look where I'm
            // pointing" and nothing is pointing. Bring the eye up the same
            // transient way a chat message does.
            self.transientHideTask?.cancel()
            self.transientHideTask = nil
            if !self.isOverlayVisible {
                self.overlayWindowManager.hasShownOverlayBefore = true
                self.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                self.isOverlayVisible = true
            }
            self.assistantState = .pointing
            self.detectedElementBubbleText = label
            self.detectedElementScreenLocation = location
            self.detectedElementDisplayFrame = displayFrame
        }

        guideSessionController.stopPointingTheEye = { [weak self] in
            guard let self else { return }
            self.detectedElementScreenLocation = nil
            self.detectedElementDisplayFrame = nil
            self.detectedElementBubbleText = nil
            // Only stand down if the eye was pointing *for the guide*. A model
            // answer mid-flight has its own reason to be pointing.
            if self.assistantState == .pointing { self.assistantState = .idle }
            // If the eye only came up transiently for this point, let it fade
            // back out rather than staying for good.
            self.scheduleTransientHideIfNeeded()
        }

        // The resume reality-check's app-on-disk answer, inventory-backed.
        guideSessionController.installedDesktopAppCheck = { [weak self] bundleId in
            self?.appInventoryService.installedApplicationURL(forBundleIdentifier: bundleId) != nil
        }

        guideSessionController.onAutopilotDidStart = { [weak self] in
            self?.presentAutopilotTakeover()
        }

        guideSessionController.onAutopilotDidStop = { [weak self] in
            // Ended mid-install (the reader closed the guide): fold the takeover
            // away with no completion follow-up.
            self?.autopilotTakeoverController.dismiss(afterHold: false)
        }

        guideSessionController.onAutopilotWaitingForReaderAtGate = { [weak self] title, instruction in
            // A manual step: park the terminal aside and lift the dim so the eye
            // (already flying to the step's control) and the control are both in
            // the clear. The step's own text rides along so the parked card can
            // tell the reader exactly what to do before they tap continue.
            self?.autopilotTakeoverController.parkForManualStep(title: title, instruction: instruction)
        }

        guideSessionController.onAutopilotResumedFromGate = { [weak self] in
            // The reader finished the manual step and Iris is running again —
            // bring the terminal back to center.
            self?.autopilotTakeoverController.returnToCenter()
        }

        guideSessionController.onGuideCompleted = { [weak self] guide, branch in
            guard let self else { return }
            // The one moment provenance is knowable for certain: a guide
            // that cloned a repo produced a source build Iris may later
            // patch; a guide that only downloaded a signed app did not.
            self.recordInstallProvenance(guide: guide, branch: branch)
            // Let the finished terminal ("✓ done") sit a beat, morph back into
            // the eye, and only then open the app — so it comes forward as the
            // eye returns, not on top of the terminal. If no takeover is up (a
            // manual guide), this opens immediately.
            self.autopilotTakeoverController.dismiss(afterHold: true) { [weak self] in
                guard let self else { return }
                self.openTheFreshlyInstalledApp(guide: guide, branch: branch)
                // Refresh so the app the reader just installed shows up in
                // "Your publik apps" without waiting for the next frontmost tick.
                Task { await self.appInventoryService.refreshInventory() }
            }
        }
    }

    /// Raises the centered terminal takeover for the run autopilot just started.
    private func presentAutopilotTakeover() {
        guard let runner = guideSessionController.autopilotRunner else { return }
        guideSessionController.setAutopilotIsShownAsTakeover(true)
        autopilotTakeoverController.present(
            runner: runner,
            onApproveRiskyCommand: { [weak self] in self?.guideSessionController.approveThePendingRiskyCommand() },
            onSkipRiskyCommand: { [weak self] in self?.guideSessionController.skipThePendingRiskyCommand() },
            onRetrySurfacedStep: { [weak self] in self?.guideSessionController.retryTheSurfacedStep() },
            onContinuePastSurfacedStep: { [weak self] in self?.guideSessionController.skipTheSurfacedStepAndContinue() },
            onReaderFinishedManualStep: { [weak self] in self?.guideSessionController.readerFinishedTheGatedStep() },
            onEscapeHatch: { [weak self] in self?.guideSessionController.abortOrCloseAutopilotFromTheEscapeHatch() }
        )
    }

    /// Launches the desktop app a finished guide just installed, so the reader
    /// lands in the running app rather than on a "you're done" card. Silent for
    /// local-web, mobile, and credential flows (nothing on this Mac to open) and
    /// when the bundle cannot be resolved yet — the inventory refresh still
    /// surfaces it in the list once LaunchServices catches up.
    private func openTheFreshlyInstalledApp(guide: IrisGuide, branch: IrisGuideBranch) {
        guard guide.outputType == .desktopApp,
              let bundleId = branch.installedDesktopAppBundleId,
              let applicationURL = appInventoryService
                .installedApplicationURL(forBundleIdentifier: bundleId) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: applicationURL, configuration: configuration, completionHandler: nil
        )
    }

    func stop() {
        globalSummonHotkeyMonitor.stop()
        appLinkService.stopWatchingForRunningApps()
        crashArtifactWatcher?.stop()
        crashArtifactWatcher = nil
        hangProbeTimer?.invalidate()
        hangProbeTimer = nil
        guideSessionController.sendTheEyeTo = nil
        guideSessionController.stopPointingTheEye = nil
        guideSessionController.onGuideCompleted = nil
        guideSessionController.onAutopilotDidStart = nil
        guideSessionController.onAutopilotDidStop = nil
        autopilotTakeoverController.dismiss(afterHold: false)
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        summonHotkeyTransitionCancellable?.cancel()
        accountStateChangeCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    /// Maintain mode's always-on layer: the crash watch (event-driven, free)
    /// and the hang probe (2s ticks, only while one of ours is frontmost).
    /// Nothing here captures a pixel or spends a token; everything funnels
    /// into the incident coordinator, whose only output is a question.
    private func startMaintainMode() {
        // The matcher is only as good as the inventory behind it, and until
        // now the inventory scanned when the panel opened. Maintain mode
        // watches whether anyone opens the panel or not, so it brings its
        // own refresh and its own frontmost tracking.
        Task { await appInventoryService.refreshInventory() }
        appInventoryService.startWatchingTheFrontmostApp()

        maintainIncidentCoordinator.catalogAppMatcher = { [weak self] processName, bundleIdentifier in
            self?.matchCatalogApp(processName: processName, bundleIdentifier: bundleIdentifier)
        }
        maintainIncidentCoordinator.installedVersionLookup = { [weak self] appSlug in
            self?.appInventoryService.installedEntriesForDisplay
                .first { $0.slug == appSlug }?.installedVersion
        }

        let watcher = CrashArtifactWatcher(appMatcher: self)
        watcher.onCrashArtifactDetected = { [weak self] artifact in
            self?.maintainIncidentCoordinator.handleCrashArtifact(artifact)
        }
        watcher.start()
        crashArtifactWatcher = watcher

        // The hang probe ticks only while a catalog app is frontmost. The
        // ask fires when a confirmed hang ENDS (recovery or exit) — never
        // mid-hang, when a modal would land on someone already struggling.
        hangProbe.onVerdict = { [weak self] pid, verdict in
            guard let self else { return }
            switch verdict {
            case .confirmedHang(let seconds):
                if let known = self.confirmedHangByPid[pid] {
                    self.confirmedHangByPid[pid] = (known.slug, known.name, known.stack, seconds)
                } else if let frontmost = NSWorkspace.shared.frontmostApplication,
                          frontmost.processIdentifier == pid,
                          let match = self.matchCatalogApp(
                              processName: frontmost.localizedName ?? "",
                              bundleIdentifier: frontmost.bundleIdentifier
                          ) {
                    self.confirmedHangByPid[pid] = (match.slug, match.name, match.stack, seconds)
                }
            case .responsive, .processDisappeared:
                if let hang = self.confirmedHangByPid.removeValue(forKey: pid) {
                    self.maintainIncidentCoordinator.handleConfirmedHang(
                        appSlug: hang.slug, appName: hang.name,
                        appStack: hang.stack, unresponsiveSeconds: hang.seconds
                    )
                }
            case .unresponsiveButBelowThreshold:
                break
            }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.appInventoryService.frontmostCatalogAppSlug != nil,
                      let frontmost = NSWorkspace.shared.frontmostApplication,
                      frontmost.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                self.hangProbe.probe(processIdentifier: frontmost.processIdentifier)
            }
        }
        timer.tolerance = 1
        hangProbeTimer = timer
    }

    /// Writes the D4 gate's ground truth at guide completion. The clone path
    /// comes from the repo name — guides clone into `~/<repo>` by
    /// convention, and the git check in `localPatchingIsPermitted` catches a
    /// wrong guess by failing closed.
    private func recordInstallProvenance(guide: IrisGuide, branch: IrisGuideBranch) {
        guard guide.outputType == .desktopApp else { return }
        let clonedARepo = (branch.setupSteps + branch.steps)
            .contains { $0.command?.contains("git clone") == true }
        if clonedARepo {
            let repoName = (guide.sourceRepo as NSString).lastPathComponent
            let clonePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(repoName).path
            installProvenanceStore.recordGuideSourceClone(
                appSlug: guide.appSlug,
                clonePath: clonePath,
                pinnedCommit: guide.sourceCommit
            )
        } else {
            installProvenanceStore.recordSignedDownload(appSlug: guide.appSlug)
        }
    }

    private func matchCatalogApp(
        processName: String, bundleIdentifier: String?
    ) -> (slug: String, name: String, stack: BreakAppStack)? {
        let entry = appInventoryService.installedEntriesForDisplay.first { entry in
            if let bundleIdentifier, let macBundleId = entry.macBundleId,
               bundleIdentifier == macBundleId {
                return true
            }
            return entry.name.caseInsensitiveCompare(processName) == .orderedSame
        }
        guard let entry else { return nil }
        let stack = Self.catalogAppStacksBySlug[entry.slug] ?? .other
        return (entry.slug, entry.name, stack)
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalSummonHotkeyMonitor.start()
        } else {
            globalSummonHotkeyMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Republishes the account service's changes as our own.
    ///
    /// The panel observes both objects, but anything that observes only the
    /// companion manager — the status line, future menu bar state — still needs
    /// to redraw when the user signs in or out, and forwarding once here is
    /// cheaper than making every such view observe two objects.
    private func bindAccountStateChanges() {
        accountStateChangeCancellable = accountService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    private func bindSummonHotkeyTransitions() {
        summonHotkeyTransitionCancellable = globalSummonHotkeyMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleSummonHotkeyTransition(transition)
            }
    }

    /// The summon hotkey (ctrl + option) toggles the companion panel so the
    /// user can type a question from anywhere.
    private func handleSummonHotkeyTransition(_ transition: SummonHotkeyShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // Don't toggle the panel while the onboarding video is playing
            guard !showOnboardingVideo else { return }
            // Opens the ask bar, not settings: onboarding tells the reader
            // this shortcut is how they ask Iris anything.
            NotificationCenter.default.post(name: .clickySummonAskBar, object: nil)
        case .released, .none:
            break
        }
    }

    // MARK: - User Message Entry Point

    /// Receives the text the user typed in the panel — the same pipeline that
    /// previously received the final dictation transcript.
    func sendUserMessage(_ messageText: String) {
        let trimmedMessageText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessageText.isEmpty else { return }

        latestUserMessageText = trimmedMessageText
        print("💬 Companion received message: \(trimmedMessageText)")

        // Cancel any pending transient hide so the overlay stays visible
        transientHideTask?.cancel()
        transientHideTask = nil

        // If the cursor is hidden, bring it back transiently for this interaction
        if !isClickyCursorEnabled && !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Cancel any in-progress response from a previous message
        currentResponseTask?.cancel()
        clearDetectedElementLocation()

        // Dismiss the onboarding prompt if it's showing
        if showOnboardingPrompt {
            withAnimation(.easeOut(duration: 0.3)) {
                onboardingPromptOpacity = 0.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showOnboardingPrompt = false
                self.onboardingPromptText = ""
            }
        }

        sendUserMessageToClaudeWithScreenshot(messageText: trimmedMessageText)
    }

    // MARK: - Companion Prompt

    private static let companionResponseSystemPrompt = """
    you're iris, a friendly always-on companion that lives in the user's menu bar. the user just typed a message to you from the menu bar panel and you can see their screen(s). your reply is shown as text in that small panel, so keep it tight and readable. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - short sentences. no lists, bullet points, markdown, or formatting — just natural prose.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - if the message includes a bracketed note that the reader is following an install guide, ground your answer in the step and the terminal output it gives you. never invent a command, hostname, url, or file path that is not in that note or visibly on screen — if you cannot tell what went wrong, ask the reader to paste the error rather than guessing.
    - don't quote code verbatim at length. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your visible text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - Guide eye: model-based target location

    /// The locator's focused prompt — find one control and answer with only the
    /// coordinate tag, using the same [POINT] format the assistant pointing uses.
    private static let guideTargetLocatorSystemPrompt = """
    You are locating one on-screen UI control for a step of a software install guide. You are given screenshots of the user's screen(s), each labeled with its pixel dimensions. Find the single control the step refers to — a button, a toggle, a row in a list, a menu item, a link.

    Reply with ONLY a coordinate tag and nothing else.
    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space — origin (0,0) is the top-left of the image, x increases rightward, y increases downward — and label is a 1-3 word name for the control. If the control is on a screen other than the first, append :screenN where N is the screen number from the image label. If the control is not visible on any screen, reply exactly [POINT:none].
    """

    /// Ask the vision model where a guide step's control is, for the eye to fly
    /// to. Returns an AppKit-global (bottom-left origin, points) rect — the same
    /// space `SystemGuideTargetLocator`'s accessibility locators return — or nil.
    /// Frames are ephemeral: a local `let`, never stored or logged as image data.
    private func locateGuideTargetWithModel(stepTitle: String, stepBody: String) async -> CGRect? {
        irisTrace("pointing/model: asked for step=\(stepTitle)")
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            irisTrace("pointing/model: captured \(screenCaptures.count) screens")
            guard !screenCaptures.isEmpty else { return nil }

            let labeledImages = screenCaptures.map { capture -> (data: Data, label: String) in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                return (data: capture.imageData, label: capture.label + dimensionInfo)
            }
            let userPrompt = "Guide step: \(stepTitle)\n\(stepBody)\n\nPoint at the one control the user should click or toggle for this step."

            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: Self.guideTargetLocatorSystemPrompt,
                userPrompt: userPrompt,
                onTextChunk: { _ in }
            )

            let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
            irisTrace("pointing/model: raw reply=\(parseResult.coordinate.map { "[POINT:\(Int($0.x)),\(Int($0.y))]" } ?? "none")")

            guard
                let pointCoordinate = parseResult.coordinate,
                let resolved = Self.globalScreenLocation(
                    fromScreenshotPoint: pointCoordinate,
                    screenNumber: parseResult.screenNumber,
                    in: screenCaptures
                )
            else {
                irisTrace("pointing/model: no location")
                return nil
            }

            let side: CGFloat = 44
            let rect = CGRect(
                x: resolved.location.x - side / 2,
                y: resolved.location.y - side / 2,
                width: side, height: side
            )
            irisTrace("pointing/model: resolved rect=\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height)) (global-screen)")
            return rect
        } catch {
            irisTrace("pointing/model: capture/model error \(error.localizedDescription)")
            return nil
        }
    }

    /// Convert a parsed [POINT] screenshot-pixel coordinate to AppKit global
    /// bottom-left-origin points — the space `frame(of:)`/OverlayWindow use — via
    /// the matching screen capture. The same math as the assistant's [POINT]
    /// flight in `sendUserMessageToClaudeWithScreenshot`, kept in one place.
    private static func globalScreenLocation(
        fromScreenshotPoint pointCoordinate: CGPoint,
        screenNumber: Int?,
        in screenCaptures: [CompanionScreenCapture]
    ) -> (location: CGPoint, displayFrame: CGRect)? {
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber, screenNumber >= 1, screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
        }()
        guard let capture = targetScreenCapture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame
        guard screenshotWidth > 0, screenshotHeight > 0 else { return nil }

        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
        // Screenshot pixels → display points, then top-left → bottom-left, then
        // display-local → global (identical to the assistant [POINT] path).
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
        return (globalLocation, displayFrame)
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the typed message to Claude,
    /// and publishes the response text for the panel to display.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendUserMessageToClaudeWithScreenshot(messageText: String) {
        currentResponseTask?.cancel()

        currentResponseTask = Task {
            assistantState = .capturing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                assistantState = .thinking

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userMessage, assistantResponse: entry.assistantResponse)
                }

                // What the running publik apps have already said about
                // themselves. Only what is already in hand — composing a prompt
                // must never be the thing that opens a socket or puts a consent
                // sheet in front of somebody.
                let promptWithLiveAppStatus: String = {
                    guard let liveAppStatus = appLinkService.contextForAssistant() else { return messageText }
                    return messageText + "\n\n" + liveAppStatus
                }()

                // During a guide, hand the model the current step and the real
                // terminal output. Answering "why is this failing" from the
                // actual command and its stderr is what stops the fabricated
                // diagnosis that started this whole feature.
                let promptWithGuideContext: String = {
                    guard let guideContext = guideSessionController.chatContextForTheAssistant() else {
                        return promptWithLiveAppStatus
                    }
                    return promptWithLiveAppStatus + "\n\n" + guideContext
                }()

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: promptWithGuideContext,
                    onTextChunk: { _ in
                        // No streaming display — the panel shows the full response when done
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let responseText = parseResult.responseText

                // Handle element pointing if Claude returned coordinates.
                // Switch to pointing BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    assistantState = .pointing
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userMessage: messageText,
                    assistantResponse: responseText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                publishAssistantResponse(responseText, isAFailureMessage: false)
            } catch is CancellationError {
                // User asked something else — response was interrupted
            } catch {
                // Never the raw server body: `describeAndHandle` maps the
                // failure to one of a fixed set of sentences, and takes care of
                // signing the user out when the funded tier says the session
                // is gone.
                publishAssistantResponse(
                    await describeAndHandle(assistantError: error),
                    isAFailureMessage: true
                )
            }

            if !Task.isCancelled {
                // Pointing keeps its state until the buddy flies back and
                // clearDetectedElementLocation() resets it to idle.
                if assistantState != .pointing {
                    assistantState = .idle
                }
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// The single place a response reaches the UI, so the text, the "is this a
    /// failure" flag and the generation counter can never disagree about which
    /// exchange the reader is looking at.
    private func publishAssistantResponse(_ responseText: String, isAFailureMessage: Bool) {
        latestAssistantResponseText = responseText
        latestResponseWasAFailureMessage = isAFailureMessage
        assistantResponseGenerationCount += 1
    }

    /// If the cursor is in transient mode (user toggled the cursor off),
    /// waits for any pointing animation to finish, then fades out the overlay
    /// after a 1-second pause. Cancelled automatically if the user submits
    /// another message.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets displayed.
        let responseText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the display text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from fullResponseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: fullResponseText, range: NSRange(fullResponseText.startIndex..., in: fullResponseText)) else {
            // No tag found at all
            return PointingParseResult(responseText: fullResponseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the displayed text
        let tagRange = Range(match.range, in: fullResponseText)!
        let responseText = String(fullResponseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: fullResponseText),
              let yRange = Range(match.range(at: 2), in: fullResponseText),
              let x = Double(fullResponseText[xRange]),
              let y = Double(fullResponseText[yRange]) else {
            return PointingParseResult(responseText: responseText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: fullResponseText) {
            elementLabel = String(fullResponseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: fullResponseText) {
            screenNumber = Int(fullResponseText[screenRange])
        }

        return PointingParseResult(
            responseText: responseText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Begins onboarding.
    ///
    /// Upstream Clicky streamed a demo video here — its author on camera,
    /// hosted on his Mux account, with a cue at 40s tied to that recording's
    /// content. A fork must not open by playing someone else's face, and it
    /// must not depend on a stranger's CDN staying up, so the video is gone
    /// and onboarding goes straight to the part that was always the point:
    /// telling the reader how to summon Iris.
    ///
    /// The player properties and teardown are kept so the overlay has
    /// somewhere to read a nil player from, and so a future first-run video of
    /// our own has a place to land.
    func setupOnboardingVideo() {
        showOnboardingVideo = false
        onboardingVideoPlayer = nil
        onboardingVideoOpacity = 0.0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and ask me anything"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }


    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're iris, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active response
        guard assistantState == .idle else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.responseText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.responseText)\"")
            } catch {
                // The demo is a flourish, not a feature — a signed-out user
                // simply doesn't see the cursor fly anywhere, and telling them
                // to sign in in the middle of an intro video would be noise.
                print("⚠️ Onboarding demo skipped: \(error)")
            }
        }
    }
}

// MARK: - Maintain mode's crash matcher

extension CompanionManager: CrashArtifactAppMatching {
    /// The watcher's protocol shape drops the display name — signatures and
    /// dedupe need only identity.
    func catalogApp(
        forProcessName processName: String, bundleIdentifier: String?
    ) -> (slug: String, stack: BreakAppStack)? {
        matchCatalogApp(processName: processName, bundleIdentifier: bundleIdentifier)
            .map { ($0.slug, $0.stack) }
    }
}
