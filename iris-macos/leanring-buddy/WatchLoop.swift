//
//  WatchLoop.swift
//  leanring-buddy
//
//  Notices when the reader has actually done the step they are on, and moves the
//  guide along without being asked to. This is the difference between Iris and a
//  chat box with a guide inside it.
//
//  `docs/iris-assistant-protocol.md` §7 is the contract, and §5 is the set of
//  privacy rules this file exists to keep. Both are implemented literally.
//
//  THE LADDER. Every rung is cheaper than the one below it, and the loop stops
//  at the first rung that can answer:
//
//    0. Is a step with a `watch` block even open? If not, nothing runs at all.
//    1. Is Iris allowed to look right now? Paused, secure input, a sensitive
//       step, an excluded app in front — each one means no capture happens.
//    2. Has the screen meaningfully changed since the last frame? One ~256 px
//       grayscale capture and a 64-bit difference hash answer this, and the
//       overwhelmingly common answer — "no" — costs nothing else.
//    3. Do the local signals settle it? Frontmost app, window title, a tool's
//       version, the HEAD of a clone, an accessibility element. Microseconds,
//       no network, nothing leaves the machine.
//    4. Only then, and only if the step declares a `visual` expectation, one
//       model call — under a hard budget of ≥ 10 s apart and ≤ 8 per step.
//
//  WHY THE LADDER IS SHAPED THIS WAY. The naive loop — screenshot every couple
//  of seconds and ask a model each time — is roughly 1,800 model calls an hour
//  per reader, which is unaffordable, and it means a running record of somebody's
//  screen leaving their machine for no reason. Rung 2 is what makes the common
//  case free: a reader reading a step is not changing their screen, so no frame
//  after the first one costs anything at all.
//
//  WHAT THIS FILE DELIBERATELY CANNOT DO. It has no file API, no logging of
//  frames, and no stored property that can hold an image. A screenshot exists
//  only as a local `let` inside the one function that sends it, for exactly as
//  long as that call is in flight. The only thing the loop keeps between ticks
//  is a 64-bit hash, which is not an image and cannot be turned back into one.
//

import Combine
import Foundation

// MARK: - What a round of watching concluded

// `WatchVerdict` — the three answers a round of watching can reach, matching
// the protocol's `completed | not_yet | user_stuck(hint)` — now lives in
// `WatchVisualCheck.swift`, beside the parsing that produces it, so the
// rehearsal harness gets the type without dragging the whole loop in with it.

/// Why Iris is not looking at the screen right now.
///
/// Every case is a promise being kept, so the panel names the one in force
/// rather than going quiet for no visible reason — a watcher that stops without
/// saying why reads as a watcher that is still watching.
enum WatchCaptureSuspensionReason: Equatable, Sendable {
    case theReaderPausedIris
    case secureInputIsActive
    case theStepIsMarkedSensitive
    case anExcludedAppIsInFront(appName: String)
}

// MARK: - The perceptual hash

/// The 64-bit difference hash of one frame.
///
/// This is the only trace of the screen the loop keeps between ticks, and it is
/// deliberately not an image: 64 bits recording which of two neighbouring
/// brightness samples was lighter cannot be turned back into a picture of
/// anybody's screen.
struct ScreenFrameFingerprint: Equatable, Sendable {
    let differenceHash: UInt64
}

/// dHash — the cheapest change detector that survives compression noise, a
/// blinking caret, and a clock digit ticking over.
enum PerceptualFrameHash {
    /// One sample wider than tall on purpose: each of the 8 rows produces 8
    /// comparisons between 9 samples, which is exactly 64 bits.
    static let sampleGridWidth = 9
    static let sampleGridHeight = 8

    static var expectedSampleCount: Int {
        sampleGridWidth * sampleGridHeight
    }

    /// Builds the hash from row-major grayscale samples. A short or long array
    /// answers zero rather than trapping, because a capture that came back the
    /// wrong shape must not take the app down.
    static func differenceHash(fromGrayscaleSamples grayscaleSamples: [UInt8]) -> UInt64 {
        guard grayscaleSamples.count == expectedSampleCount else {
            return 0
        }

        var accumulatedHash: UInt64 = 0
        var bitPosition: UInt64 = 0
        for rowIndex in 0..<sampleGridHeight {
            for columnIndex in 0..<(sampleGridWidth - 1) {
                let leftSample = grayscaleSamples[rowIndex * sampleGridWidth + columnIndex]
                let rightSample = grayscaleSamples[rowIndex * sampleGridWidth + columnIndex + 1]
                if leftSample > rightSample {
                    accumulatedHash |= (1 << bitPosition)
                }
                bitPosition += 1
            }
        }
        return accumulatedHash
    }

    /// How many of the 64 comparisons flipped between two frames.
    static func hammingDistance(
        between firstHash: UInt64,
        and secondHash: UInt64
    ) -> Int {
        (firstHash ^ secondHash).nonzeroBitCount
    }
}

// MARK: - The collaborators the loop is built out of

/// Time, injected. The loop's whole budget is expressed in seconds, so a test
/// that had to spend those seconds for real would take minutes to prove a
/// ten-second rule.
@MainActor
protocol WatchLoopClock: AnyObject {
    /// Seconds on a monotonic timeline. Only differences between two readings
    /// are ever used, so where the timeline starts does not matter.
    var currentTimeInSeconds: Double { get }

    func waitForSeconds(_ numberOfSecondsToWait: Double) async
}

/// Where frames come from. Two methods rather than one, because the two frames
/// this loop takes are wildly different in cost and in what they mean:
/// the fingerprint is a ~256 px grayscale thumbnail that never leaves the
/// machine, and the visual frame is a real screenshot that does.
@MainActor
protocol WatchLoopFrameSource: AnyObject {
    /// Rung 2. Returns a hash and nothing else — no image is handed back, so
    /// there is no image for a caller to accidentally keep.
    func captureFingerprintOfTheCurrentScreen() async -> ScreenFrameFingerprint?

    /// Rung 4, and only rung 4. The bytes are handed to exactly one model call
    /// and dropped the moment it returns.
    func captureOneFrameForAVisualModelCheck() async -> Data?
}

/// The signals that can be read on this machine, for free, without looking at
/// pixels. All of these already exist as services in this app — this protocol
/// is the seam that lets a test answer them without a real screen, a real
/// installed toolchain, or a real accessibility grant.
@MainActor
protocol WatchLoopLocalSignalSource: AnyObject {
    func frontmostApplicationBundleIdentifier() -> String?
    func frontmostApplicationName() -> String?
    func frontmostWindowTitle() -> String?

    /// The host of whatever the frontmost browser window is showing, read over
    /// accessibility. Nil when the frontmost app is not a browser, or will not
    /// say, or accessibility has not been granted.
    func hostOfTheURLInTheFrontmostWindow() -> String?

    /// `ToolVersionService`, behind a seam. Answering this spawns a process, so
    /// the loop only asks when something else already suggests it is worth it.
    func isToolInstalled(named toolName: String) async -> Bool

    /// `GitInspectionService`, behind a seam. True when that path is a working
    /// tree with a commit in it — which is what "the clone finished" means.
    func gitWorkingTreeHasACommit(atRepositoryPath repositoryPath: String) async -> Bool

    func isAccessibilityElementPresent(matchingRoleLabel roleLabel: String) -> Bool

    /// `IsSecureEventInputSet()`. True while anything on this Mac has secure
    /// keyboard entry on — a password field, a sudo prompt, a lock screen.
    func isSecureEventInputActive() -> Bool
}

/// The one model call the ladder can reach, made through `AssistantTransport`
/// like every other model call in this app. There is deliberately no second
/// credential path here: this protocol takes bytes and a question, not a URL
/// and not a key.
@MainActor
protocol WatchLoopVisualEvaluator: AnyObject {
    /// Returns nil when the call failed or the answer could not be read, which
    /// is different from `notYet` — it means the loop learned nothing, not that
    /// the step is unfinished.
    func evaluateWhetherTheStepLooksDone(
        screenshotJPEGData: Data,
        visualPrompt: String,
        stepTitle: String,
        hintsTheStepAuthorWrote: [String]
    ) async -> WatchVerdict?

    /// Handed the app's single transport resolution at startup, by whoever owns
    /// the account service. A test stub ignores it; the production evaluator has
    /// no other way to reach a model, which is how "never build a second
    /// credential path" is enforced rather than merely intended.
    func useTransport(
        resolvedBy resolveTransport: @escaping @Sendable () async -> Result<AssistantTransport, AssistantTransportError>
    )
}

extension WatchLoopVisualEvaluator {
    func useTransport(
        resolvedBy resolveTransport: @escaping @Sendable () async -> Result<AssistantTransport, AssistantTransportError>
    ) {
        // An evaluator that does not talk to a model has nothing to do with a
        // transport, and saying so once here beats an empty method in each stub.
    }
}

// MARK: - The loop

@MainActor
final class WatchLoop: ObservableObject {

    // MARK: The budget, straight out of docs/iris-assistant-protocol.md §7

    /// How often a frame is taken while a watched step is open.
    static let secondsBetweenFrames: Double = 2

    /// How long to let the screen settle after a change before reading anything
    /// off it. Without this, the loop reads the screen mid-animation — halfway
    /// through a window opening, a page painting, a menu sliding — and concludes
    /// something false about a state that lasted 200 ms.
    static let secondsToWaitForTheScreenToSettle: Double = 1

    /// The floor between two model calls. Not advisory: `modelEvaluationIsAllowedRightNow`
    /// is the only door to a model call and it enforces this.
    static let minimumSecondsBetweenModelChecks: Double = 10

    /// The ceiling per step. Hitting it stops model evaluation for the rest of
    /// that step — the loop carries on, but on local signals alone. Eight looks
    /// at one step and still not knowing means looking a ninth time is not the
    /// problem, so the loop stops paying for it.
    static let maximumModelChecksPerStep = 8

    /// How many of the 64 hash bits have to flip before the change counts.
    ///
    /// A blinking caret, an animated icon, or a clock digit moves one or two
    /// bits. Opening a window, navigating a page, or a terminal filling with
    /// output moves far more than five. Set this lower and the loop wakes for
    /// every caret blink; set it higher and it sleeps through real progress.
    static let minimumHammingDistanceThatCountsAsAMeaningfulChange = 5

    // MARK: The excluded-apps list

    /// Password managers, seeded. The reader can add to and remove from this
    /// list; these are the defaults because they are where the secrets are, and
    /// a default that arrives after the damage is not a default.
    static let defaultExcludedAppBundleIdentifiers: [String] = [
        "com.1password.1password",   // 1Password 8
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess",  // Keychain Access
        "com.apple.Passwords",       // Apple's Passwords app
    ]

    static let excludedAppBundleIdentifiersPreferenceKey = "irisWatchLoopExcludedAppBundleIdentifiers"
    static let readerPausedWatchingPreferenceKey = "irisWatchLoopReaderPausedWatching"

    // MARK: Published state

    @Published private(set) var isWatchingAStep = false
    @Published private(set) var stepBeingWatched: IrisGuideStep?

    /// Non-nil whenever Iris is deliberately not looking. Drives the indicator.
    @Published private(set) var captureIsSuspendedBecause: WatchCaptureSuspensionReason?

    /// The `userStuck` hint, surfaced the moment it arrives. Cleared when the
    /// reader dismisses it or the step moves on.
    @Published private(set) var proactiveHintForTheReader: String?

    @Published private(set) var numberOfModelChecksUsedOnThisStep = 0

    /// True once this step has spent its ceiling. The loop keeps running; it
    /// just stops reaching rung 4.
    @Published private(set) var modelEvaluationIsExhaustedForThisStep = false

    @Published private(set) var readerPausedWatching = false

    @Published private(set) var excludedAppBundleIdentifiers: [String]

    /// How many bytes of screenshot the loop is holding right now. It is only
    /// ever non-zero while a single model call is in flight, and this property
    /// existing is how "never retained after the call it was taken for" is
    /// something a test can check rather than something a comment claims.
    private(set) var numberOfScreenshotBytesHeldInMemory = 0

    // MARK: Collaborators

    private let clock: WatchLoopClock
    private let frameSource: WatchLoopFrameSource
    private let localSignalSource: WatchLoopLocalSignalSource
    private let visualEvaluator: WatchLoopVisualEvaluator
    private let preferencesStore: UserDefaults

    /// Whether this instance runs its own 2-second timer. Production does; a
    /// test drives `performOneWatchTick()` by hand instead, because a loop that
    /// ticks on its own cannot be asserted about deterministically.
    private let drivesItsOwnTickTimer: Bool

    /// Called with every verdict. The guide session controller uses it to
    /// advance the step, which is the entire point of the feature.
    var onVerdict: (@MainActor (WatchVerdict) -> Void)?

    // MARK: Per-step working state

    private var watchPlanForTheStepBeingWatched: IrisStepWatch?

    /// The directory this step's `git clone` will create, worked out once when
    /// the step opens rather than on every tick.
    private var repositoryPathThisStepsCloneWouldCreate: String?

    private var fingerprintOfTheMostRecentFrame: ScreenFrameFingerprint?
    private var timeOfTheMostRecentModelCheck: Double?

    /// What was in front the last time the blind path swept the side signals.
    /// The blind path has no screen diff to gate it, so a change of frontmost
    /// app is what stands in for one — otherwise a sensitive step would spawn a
    /// `git --version` every two seconds for as long as it stayed open.
    private var frontmostBundleIdentifierAtTheLastSideSignalSweep: String??

    /// Bumped every time the watched step changes. A tick that started before
    /// the step changed must not report a verdict about the step that replaced
    /// it, and comparing generations is how a half-finished tick knows.
    private var generationOfTheStepBeingWatched = 0

    private var tickingTask: Task<Void, Never>?

    // MARK: Init

    /// Every collaborator defaults to its production implementation. They are
    /// built inside the body rather than as default arguments because a default
    /// argument is evaluated outside the main actor and all four of these are
    /// main-actor isolated.
    init(
        clock: WatchLoopClock? = nil,
        frameSource: WatchLoopFrameSource? = nil,
        localSignalSource: WatchLoopLocalSignalSource? = nil,
        visualEvaluator: WatchLoopVisualEvaluator? = nil,
        preferencesStore: UserDefaults = .standard,
        drivesItsOwnTickTimer: Bool = true
    ) {
        self.clock = clock ?? SystemWatchLoopClock()
        self.frameSource = frameSource ?? ScreenCaptureKitWatchLoopFrameSource()
        self.localSignalSource = localSignalSource ?? SystemWatchLoopLocalSignalSource()
        self.visualEvaluator = visualEvaluator ?? AssistantTransportWatchLoopVisualEvaluator()
        self.preferencesStore = preferencesStore
        self.drivesItsOwnTickTimer = drivesItsOwnTickTimer

        let storedExcludedAppBundleIdentifiers = preferencesStore.stringArray(
            forKey: Self.excludedAppBundleIdentifiersPreferenceKey
        )
        self.excludedAppBundleIdentifiers =
            storedExcludedAppBundleIdentifiers ?? Self.defaultExcludedAppBundleIdentifiers
        self.readerPausedWatching = preferencesStore.bool(
            forKey: Self.readerPausedWatchingPreferenceKey
        )
    }

    deinit {
        tickingTask?.cancel()
    }

    // MARK: - Starting and stopping

    /// Rung 0. A step with no `watch` block, or one whose block declares
    /// nothing to look for, is not watched at all — this returns having started
    /// nothing, and `isWatchingAStep` stays false.
    func beginWatching(step: IrisGuideStep) {
        stopWatching()

        guard let watchPlan = step.watch, !watchPlan.expect.isEmpty else {
            return
        }

        stepBeingWatched = step
        watchPlanForTheStepBeingWatched = watchPlan
        repositoryPathThisStepsCloneWouldCreate = Self.repositoryPathAGitCloneWouldCreate(
            inCommand: step.command
        )
        numberOfModelChecksUsedOnThisStep = 0
        modelEvaluationIsExhaustedForThisStep = false
        timeOfTheMostRecentModelCheck = nil
        fingerprintOfTheMostRecentFrame = nil
        frontmostBundleIdentifierAtTheLastSideSignalSweep = nil
        proactiveHintForTheReader = nil
        captureIsSuspendedBecause = readerPausedWatching ? .theReaderPausedIris : nil
        isWatchingAStep = true
        generationOfTheStepBeingWatched += 1

        startTheTickingTaskIfThisInstanceDrivesItself()
    }

    /// Stops immediately and forgets everything about the step, including the
    /// fingerprint. Nothing about the reader's screen outlives the step it was
    /// taken for, which is why the fingerprint is cleared here rather than left
    /// lying around until the next step overwrites it.
    func stopWatching() {
        tickingTask?.cancel()
        tickingTask = nil
        isWatchingAStep = false
        stepBeingWatched = nil
        watchPlanForTheStepBeingWatched = nil
        repositoryPathThisStepsCloneWouldCreate = nil
        fingerprintOfTheMostRecentFrame = nil
        frontmostBundleIdentifierAtTheLastSideSignalSweep = nil
        captureIsSuspendedBecause = nil
        proactiveHintForTheReader = nil
        generationOfTheStepBeingWatched += 1
    }

    private func startTheTickingTaskIfThisInstanceDrivesItself() {
        guard drivesItsOwnTickTimer, !readerPausedWatching else {
            return
        }
        tickingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isWatchingAStep else {
                    return
                }
                await self.performOneWatchTick()
                guard !Task.isCancelled else {
                    return
                }
                await self.clock.waitForSeconds(Self.secondsBetweenFrames)
            }
        }
    }

    // MARK: - The pause

    /// The global pause. It takes effect immediately rather than at the end of
    /// the current tick: the ticking task is cancelled outright, and every rung
    /// re-reads the flag after each `await`, so a capture cannot happen after
    /// the reader has said stop.
    func setReaderPausedWatching(_ readerPaused: Bool) {
        readerPausedWatching = readerPaused
        preferencesStore.set(readerPaused, forKey: Self.readerPausedWatchingPreferenceKey)

        if readerPaused {
            tickingTask?.cancel()
            tickingTask = nil
            if isWatchingAStep {
                captureIsSuspendedBecause = .theReaderPausedIris
            }
            return
        }

        guard isWatchingAStep else {
            return
        }
        captureIsSuspendedBecause = nil
        startTheTickingTaskIfThisInstanceDrivesItself()
    }

    func dismissTheProactiveHint() {
        proactiveHintForTheReader = nil
    }

    /// Hands the loop the app's one way of reaching a model. `CompanionManager`
    /// calls this at startup because it is what owns the account service; until
    /// it does, a visual check simply does not happen.
    func useTransportForVisualChecks(
        resolvedBy resolveTransport: @escaping @Sendable () async -> Result<AssistantTransport, AssistantTransportError>
    ) {
        visualEvaluator.useTransport(resolvedBy: resolveTransport)
    }

    // MARK: - The excluded-apps list

    func addExcludedApp(bundleIdentifier: String) {
        let normalizedBundleIdentifier = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedBundleIdentifier.isEmpty else {
            return
        }
        guard !excludedAppBundleIdentifiers.contains(where: { existingBundleIdentifier in
            existingBundleIdentifier.lowercased() == normalizedBundleIdentifier
        }) else {
            return
        }
        excludedAppBundleIdentifiers.append(bundleIdentifier)
        persistTheExcludedAppsList()
    }

    func removeExcludedApp(bundleIdentifier: String) {
        excludedAppBundleIdentifiers.removeAll { existingBundleIdentifier in
            existingBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        persistTheExcludedAppsList()
    }

    func restoreTheDefaultExcludedAppsList() {
        excludedAppBundleIdentifiers = Self.defaultExcludedAppBundleIdentifiers
        persistTheExcludedAppsList()
    }

    private func persistTheExcludedAppsList() {
        preferencesStore.set(
            excludedAppBundleIdentifiers,
            forKey: Self.excludedAppBundleIdentifiersPreferenceKey
        )
    }

    func isExcludedFromCapture(bundleIdentifier: String) -> Bool {
        excludedAppBundleIdentifiers.contains { excludedBundleIdentifier in
            excludedBundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
    }

    // MARK: - What the reader sees while this is running

    /// The indicator. Non-nil for exactly as long as the loop is alive, so
    /// "Iris is watching" can never be false in either direction — it is derived
    /// from the same state the loop runs on rather than set alongside it.
    var watchIndicatorText: String? {
        guard isWatchingAStep else {
            return nil
        }
        switch captureIsSuspendedBecause {
        case .none:
            return "Iris is watching this step."
        case .theReaderPausedIris:
            return "Iris is paused — it is not looking at your screen."
        case .secureInputIsActive:
            return "Iris stopped looking — you are typing something protected."
        case .theStepIsMarkedSensitive:
            return "Iris is not looking at your screen for this step."
        case .anExcludedAppIsInFront(let appName):
            return "Iris is not looking while \(appName) is in front."
        }
    }

    /// True while frames are actually being taken, which is narrower than
    /// `isWatchingAStep`: the loop can be alive and deliberately blind.
    var isCapturingRightNow: Bool {
        isWatchingAStep && captureIsSuspendedBecause == nil
    }

    // MARK: - One turn of the ladder

    /// Runs the ladder once. Internal rather than private so a test can drive it
    /// a rung at a time, without a screen, a clock, or a network.
    func performOneWatchTick() async {
        guard isWatchingAStep, let watchPlan = watchPlanForTheStepBeingWatched else {
            return
        }
        let generationThisTickBelongsTo = generationOfTheStepBeingWatched

        // Rung 1 — is Iris allowed to look at all?
        let reasonCaptureIsNotAllowed = reasonCaptureIsNotAllowedRightNow(watchPlan: watchPlan)
        captureIsSuspendedBecause = reasonCaptureIsNotAllowed
        if let reasonCaptureIsNotAllowed {
            // A pause means the reader told Iris to stop. Nothing runs — not
            // even a free signal — because "paused" has to mean paused.
            guard reasonCaptureIsNotAllowed != .theReaderPausedIris else {
                return
            }
            // The other three still let the step finish, just never from pixels.
            // That is what makes a sensitive step completable at all: it is the
            // only way to walk somebody through pasting an API key and still
            // know when they are done.
            await reachAVerdictFromSideSignalsAlone(
                watchPlan: watchPlan,
                generationThisTickBelongsTo: generationThisTickBelongsTo
            )
            return
        }

        // Rung 2 — the perceptual diff. This is the rung that makes the loop
        // affordable, and the overwhelmingly common path returns right here.
        guard let fingerprintOfThisFrame = await frameSource.captureFingerprintOfTheCurrentScreen() else {
            return
        }
        guard isStillWatchingGeneration(generationThisTickBelongsTo) else {
            return
        }
        let fingerprintOfThePreviousFrame = fingerprintOfTheMostRecentFrame
        fingerprintOfTheMostRecentFrame = fingerprintOfThisFrame

        guard let fingerprintOfThePreviousFrame else {
            // The first frame of a step has nothing to be different from, so it
            // is a baseline and never a change. The free signals are still worth
            // reading — a step whose tool is already installed should not have to
            // wait for the reader to move something before Iris notices — but a
            // model call is not free, and paying for one before anything has
            // happened is exactly the waste rung 2 exists to prevent.
            await reachAVerdictFromLocalSignalsWithoutSpendingBudget(
                watchPlan: watchPlan,
                generationThisTickBelongsTo: generationThisTickBelongsTo
            )
            return
        }

        let numberOfHashBitsThatChanged = PerceptualFrameHash.hammingDistance(
            between: fingerprintOfThePreviousFrame.differenceHash,
            and: fingerprintOfThisFrame.differenceHash
        )
        guard numberOfHashBitsThatChanged >= Self.minimumHammingDistanceThatCountsAsAMeaningfulChange else {
            return
        }

        // Rung 3 — let the screen settle, then read the local signals.
        await clock.waitForSeconds(Self.secondsToWaitForTheScreenToSettle)
        guard isStillWatchingGeneration(generationThisTickBelongsTo), !readerPausedWatching else {
            return
        }

        let localSignalOutcome = await evaluateLocalSignals(watchPlan: watchPlan)
        guard isStillWatchingGeneration(generationThisTickBelongsTo) else {
            return
        }
        switch localSignalOutcome {
        case .theStepIsDone:
            reportVerdict(.completed)
            return
        case .theStepIsNotDoneYet:
            // Something local said plainly that it is not done. Paying for a
            // model call to be told the same thing is the waste this loop exists
            // to avoid.
            return
        case .localSignalsCannotTell:
            break
        }

        // Rung 4 — one model call, and only under budget.
        guard let visualPrompt = watchPlan.visualPrompt else {
            return
        }
        guard modelEvaluationIsAllowedRightNow() else {
            return
        }
        await performOneVisualModelCheck(
            visualPrompt: visualPrompt,
            watchPlan: watchPlan,
            generationThisTickBelongsTo: generationThisTickBelongsTo
        )
    }

    private func isStillWatchingGeneration(_ generationThisTickBelongsTo: Int) -> Bool {
        isWatchingAStep && generationOfTheStepBeingWatched == generationThisTickBelongsTo
    }

    // MARK: - Rung 1: may Iris look?

    /// The four reasons Iris must not take a frame, checked before any capture
    /// is attempted rather than after one comes back.
    private func reasonCaptureIsNotAllowedRightNow(
        watchPlan: IrisStepWatch
    ) -> WatchCaptureSuspensionReason? {
        if readerPausedWatching {
            return .theReaderPausedIris
        }

        // Checked before secure input, and re-checked on every single tick, so
        // a step that becomes sensitive or a reader who reaches a sensitive step
        // mid-session is covered by the same code path as one who starts there.
        if watchPlan.sensitive {
            return .theStepIsMarkedSensitive
        }

        // Someone typing a password must never be captured, and secure input is
        // the system's own statement that that is what is happening. It is read
        // fresh every tick because it goes on and off mid-step — that is the
        // whole point of it.
        if localSignalSource.isSecureEventInputActive() {
            return .secureInputIsActive
        }

        if let frontmostBundleIdentifier = localSignalSource.frontmostApplicationBundleIdentifier(),
           isExcludedFromCapture(bundleIdentifier: frontmostBundleIdentifier) {
            let appName = localSignalSource.frontmostApplicationName() ?? frontmostBundleIdentifier
            return .anExcludedAppIsInFront(appName: appName)
        }

        return nil
    }

    /// The blind path. With no screen diff to gate it, a change of frontmost app
    /// is the trigger — it is free to read, and for the steps that end up here
    /// ("copy the key", "paste it into Iris") it is also the actual signal that
    /// the reader moved on.
    private func reachAVerdictFromSideSignalsAlone(
        watchPlan: IrisStepWatch,
        generationThisTickBelongsTo: Int
    ) async {
        let frontmostBundleIdentifier = localSignalSource.frontmostApplicationBundleIdentifier()
        if let bundleIdentifierAtTheLastSweep = frontmostBundleIdentifierAtTheLastSideSignalSweep,
           bundleIdentifierAtTheLastSweep == frontmostBundleIdentifier {
            return
        }
        frontmostBundleIdentifierAtTheLastSideSignalSweep = .some(frontmostBundleIdentifier)

        let localSignalOutcome = await evaluateLocalSignals(watchPlan: watchPlan)
        guard isStillWatchingGeneration(generationThisTickBelongsTo) else {
            return
        }
        if localSignalOutcome == .theStepIsDone {
            reportVerdict(.completed)
        }
    }

    /// The local signals with rung 4 deliberately out of reach. Used for the
    /// baseline frame, where the screen has not been observed to change and so
    /// nothing has happened worth paying a model to look at.
    private func reachAVerdictFromLocalSignalsWithoutSpendingBudget(
        watchPlan: IrisStepWatch,
        generationThisTickBelongsTo: Int
    ) async {
        let localSignalOutcome = await evaluateLocalSignals(watchPlan: watchPlan)
        guard isStillWatchingGeneration(generationThisTickBelongsTo) else {
            return
        }
        if localSignalOutcome == .theStepIsDone {
            reportVerdict(.completed)
        }
    }

    // MARK: - Rung 3: the local signals

    enum LocalSignalOutcome: Equatable, Sendable {
        /// Every expectation that can be answered locally says yes.
        case theStepIsDone
        /// A local expectation exists and says plainly that it is not done.
        case theStepIsNotDoneYet
        /// Nothing local can tell. Only rung 4 could, and only if the step
        /// declares a visual expectation.
        case localSignalsCannotTell
    }

    private func evaluateLocalSignals(watchPlan: IrisStepWatch) async -> LocalSignalOutcome {
        var numberOfLocalExpectationsEvaluated = 0
        var everyLocalExpectationIsSatisfied = true

        for expectation in watchPlan.expectationsAnsweredWithoutPixels {
            numberOfLocalExpectationsEvaluated += 1
            let thisExpectationIsSatisfied = await isSatisfied(expectation)
            if !thisExpectationIsSatisfied {
                everyLocalExpectationIsSatisfied = false
            }
        }

        // A clone is done when the directory it creates has a commit in it.
        // Nothing has to declare this: the step's own `git clone` command says
        // where to look, and a repository with a HEAD is a far better answer
        // than asking a model to read a terminal window.
        if let repositoryPathThisStepsCloneWouldCreate {
            numberOfLocalExpectationsEvaluated += 1
            let theCloneHasLanded = await localSignalSource.gitWorkingTreeHasACommit(
                atRepositoryPath: repositoryPathThisStepsCloneWouldCreate
            )
            if !theCloneHasLanded {
                everyLocalExpectationIsSatisfied = false
            }
        }

        guard numberOfLocalExpectationsEvaluated > 0 else {
            return .localSignalsCannotTell
        }
        if everyLocalExpectationIsSatisfied {
            return .theStepIsDone
        }
        // An unsatisfied local signal alongside a declared visual expectation is
        // not a verdict — the step author asked for a model's opinion precisely
        // because the local signals were not going to be conclusive on their own.
        return watchPlan.declaresAVisualExpectation ? .localSignalsCannotTell : .theStepIsNotDoneYet
    }

    private func isSatisfied(_ expectation: IrisStepExpectation) async -> Bool {
        switch expectation {
        case .foregroundApp(let bundleId):
            guard let frontmostBundleIdentifier = localSignalSource.frontmostApplicationBundleIdentifier() else {
                return false
            }
            return frontmostBundleIdentifier.caseInsensitiveCompare(bundleId) == .orderedSame

        case .urlHost(let host):
            // The address bar read over accessibility is the accurate answer.
            // The window title is the fallback, because several browsers put the
            // site's name in it and a reader who has arrived is better served by
            // a slightly loose match than by Iris insisting they have not.
            if let hostOfTheFrontmostWindow = localSignalSource.hostOfTheURLInTheFrontmostWindow() {
                return Self.host(hostOfTheFrontmostWindow, matchesExpectedHost: host)
            }
            guard let frontmostWindowTitle = localSignalSource.frontmostWindowTitle() else {
                return false
            }
            return frontmostWindowTitle.lowercased().contains(host.lowercased())

        case .toolVersion(let tool):
            return await localSignalSource.isToolInstalled(named: tool)

        case .axElement(let roleLabel):
            return localSignalSource.isAccessibilityElementPresent(matchingRoleLabel: roleLabel)

        case .visual:
            // Not a local signal. `expectationsAnsweredWithoutPixels` already
            // filtered these out; this case exists so that adding a sixth
            // expectation type is a compile error rather than a silent pass.
            return false
        }
    }

    /// `console.anthropic.com` matches itself and any subdomain of itself, and
    /// nothing else. A plain `hasSuffix` would let `evilconsole.anthropic.com`
    /// through, which is exactly the sort of match a signal like this must not
    /// make.
    static func host(_ actualHost: String?, matchesExpectedHost expectedHost: String) -> Bool {
        guard let actualHost else {
            return false
        }
        let normalizedActualHost = actualHost.lowercased()
        let normalizedExpectedHost = expectedHost.lowercased()
        if normalizedActualHost == normalizedExpectedHost {
            return true
        }
        return normalizedActualHost.hasSuffix(".\(normalizedExpectedHost)")
    }

    // MARK: - Rung 4: the one model call

    /// Both halves of the protocol's budget, in the one place a model call can
    /// be reached from. Returning false here is the whole enforcement: there is
    /// no other door.
    private func modelEvaluationIsAllowedRightNow() -> Bool {
        guard !modelEvaluationIsExhaustedForThisStep else {
            return false
        }
        guard numberOfModelChecksUsedOnThisStep < Self.maximumModelChecksPerStep else {
            // Latched rather than recomputed, so the rest of this step stays on
            // local signals no matter what happens to the counters.
            modelEvaluationIsExhaustedForThisStep = true
            return false
        }
        guard let timeOfTheMostRecentModelCheck else {
            return true
        }
        let secondsSinceTheMostRecentModelCheck =
            clock.currentTimeInSeconds - timeOfTheMostRecentModelCheck
        return secondsSinceTheMostRecentModelCheck >= Self.minimumSecondsBetweenModelChecks
    }

    private func performOneVisualModelCheck(
        visualPrompt: String,
        watchPlan: IrisStepWatch,
        generationThisTickBelongsTo: Int
    ) async {
        guard let screenshotJPEGData = await frameSource.captureOneFrameForAVisualModelCheck(),
              !screenshotJPEGData.isEmpty else {
            return
        }
        // If the step changed while the capture was in flight, the frame is of
        // a screen nobody asked about. It goes no further.
        guard isStillWatchingGeneration(generationThisTickBelongsTo), !readerPausedWatching else {
            return
        }

        // The budget is spent before the call, not after it. A call that fails
        // still cost time and still hit somebody's rate limit, and a loop that
        // only counted successes would retry a broken model every two seconds.
        numberOfModelChecksUsedOnThisStep += 1
        timeOfTheMostRecentModelCheck = clock.currentTimeInSeconds
        if numberOfModelChecksUsedOnThisStep >= Self.maximumModelChecksPerStep {
            modelEvaluationIsExhaustedForThisStep = true
        }

        // The frame exists as this local `let` and nowhere else. It is counted
        // in for the duration of the call and counted back out the instant the
        // call returns, which is what "never retained after the call it was
        // taken for" means in practice.
        numberOfScreenshotBytesHeldInMemory = screenshotJPEGData.count
        let verdict = await visualEvaluator.evaluateWhetherTheStepLooksDone(
            screenshotJPEGData: screenshotJPEGData,
            visualPrompt: visualPrompt,
            stepTitle: stepBeingWatched?.title ?? "",
            hintsTheStepAuthorWrote: watchPlan.hints
        )
        numberOfScreenshotBytesHeldInMemory = 0

        guard let verdict, isStillWatchingGeneration(generationThisTickBelongsTo) else {
            return
        }
        reportVerdict(verdict)
    }

    // MARK: - Reporting

    private func reportVerdict(_ verdict: WatchVerdict) {
        switch verdict {
        case .completed:
            // Nothing about this step matters once it is done, and the handler
            // is about to open the next one — so the loop is torn down first and
            // whoever is listening starts the next watch from a clean state.
            stopWatching()
        case .notYet:
            break
        case .userStuck(let hint):
            proactiveHintForTheReader = hint
        }
        onVerdict?(verdict)
    }

    // MARK: - Reading a clone out of a step's command

    /// Works out the directory a step's `git clone` will create, so the loop can
    /// notice the clone finished without looking at the screen at all.
    ///
    /// Guides write this as two lines — `cd ~` then `git clone <url>` — so the
    /// parent comes from the `cd` and the name from the URL. Nothing here runs a
    /// shell or executes any part of the command; it is read as text and only
    /// ever turned into a path that `GitInspectionService` then vets for itself.
    static func repositoryPathAGitCloneWouldCreate(inCommand command: String?) -> String? {
        guard let command, !command.isEmpty else {
            return nil
        }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        var parentDirectoryPath = homeDirectoryPath

        for commandLine in command.split(separator: "\n") {
            let trimmedCommandLine = commandLine.trimmingCharacters(in: .whitespaces)

            if trimmedCommandLine == "cd" || trimmedCommandLine.hasPrefix("cd ") {
                let destination = trimmedCommandLine
                    .dropFirst(2)
                    .trimmingCharacters(in: .whitespaces)
                parentDirectoryPath = expandedDirectoryPath(
                    destination,
                    relativeTo: parentDirectoryPath,
                    homeDirectoryPath: homeDirectoryPath
                )
                continue
            }

            guard trimmedCommandLine.hasPrefix("git clone ") else {
                continue
            }

            let tokensAfterTheSubcommand = trimmedCommandLine
                .split(whereSeparator: { character in character == " " || character == "\t" })
                .dropFirst(2)
                .map(String.init)

            // The repository is found by shape rather than by position, because
            // flags in between may take values of their own — `--depth 1` would
            // otherwise be read as the repository to clone.
            guard let indexOfTheRepositoryURL = tokensAfterTheSubcommand.firstIndex(
                where: { token in tokenLooksLikeARepositoryURL(token) }
            ) else {
                continue
            }

            // `git clone <url> <directory>` names the directory outright; every
            // other form derives it from the last component of the URL.
            let explicitDestination = tokensAfterTheSubcommand
                .dropFirst(indexOfTheRepositoryURL + 1)
                .first { token in !token.hasPrefix("-") }
            if let explicitDestination {
                return expandedDirectoryPath(
                    explicitDestination,
                    relativeTo: parentDirectoryPath,
                    homeDirectoryPath: homeDirectoryPath
                )
            }

            guard let repositoryDirectoryName = repositoryDirectoryName(
                fromCloneURLString: tokensAfterTheSubcommand[indexOfTheRepositoryURL]
            ) else {
                continue
            }
            return "\(parentDirectoryPath)/\(repositoryDirectoryName)"
        }

        return nil
    }

    /// The three ways a guide can write a repository: an https URL, an ssh URL,
    /// and the scp-style `git@host:owner/repo.git`. A flag never looks like any
    /// of them, which is what makes this a safe way to skip past flags whose
    /// value this parser does not know about.
    private static func tokenLooksLikeARepositoryURL(_ token: String) -> Bool {
        guard !token.hasPrefix("-") else {
            return false
        }
        return token.contains("://") || token.contains("@") || token.hasSuffix(".git")
    }

    private static func repositoryDirectoryName(fromCloneURLString cloneURLString: String) -> String? {
        var remainingURLString = cloneURLString
        while remainingURLString.hasSuffix("/") {
            remainingURLString.removeLast()
        }
        guard let lastPathComponent = remainingURLString
            .split(separator: "/")
            .last
            .map(String.init) else {
            return nil
        }
        let repositoryDirectoryName = lastPathComponent.hasSuffix(".git")
            ? String(lastPathComponent.dropLast(4))
            : lastPathComponent
        return repositoryDirectoryName.isEmpty ? nil : repositoryDirectoryName
    }

    private static func expandedDirectoryPath(
        _ writtenPath: String,
        relativeTo parentDirectoryPath: String,
        homeDirectoryPath: String
    ) -> String {
        if writtenPath.isEmpty || writtenPath == "~" {
            return homeDirectoryPath
        }
        if writtenPath.hasPrefix("~/") {
            return "\(homeDirectoryPath)/\(writtenPath.dropFirst(2))"
        }
        if writtenPath.hasPrefix("/") {
            return writtenPath
        }
        return "\(parentDirectoryPath)/\(writtenPath)"
    }
}
