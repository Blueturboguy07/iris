//
//  WatchLoopTests.swift
//  leanring-buddyTests
//
//  Covers the adaptive watch loop: the cheapest-first ladder, the model budget
//  from `docs/iris-assistant-protocol.md` §7, and every privacy rule in §5.
//
//  Nothing here touches a screen, a clock, a process, or a network. The clock is
//  virtual, frames are handed over as fingerprints a test made up, the local
//  signals come out of a table, and the model verdict is whatever the test says
//  it is. That is deliberate: a loop whose budget can only be proved by waiting
//  ten real seconds is a loop whose budget nobody will keep testing, and a
//  privacy rule that can only be checked by taking a real screenshot is a rule
//  that would have to be broken to be verified.
//

import CoreGraphics
import Foundation
import Testing
// The module follows PRODUCT_NAME, which the fork renamed to Iris.
@testable import Iris

// MARK: - The doubles

/// Time the test controls. `waitForSeconds` returns instantly and moves the
/// clock forward by exactly what was asked for, so a ten-second rule costs a
/// test nothing to prove.
@MainActor
final class VirtualWatchLoopClock: WatchLoopClock {
    private(set) var currentTimeInSeconds: Double = 0
    private(set) var everyWaitThatWasRequested: [Double] = []

    func waitForSeconds(_ numberOfSecondsToWait: Double) async {
        everyWaitThatWasRequested.append(numberOfSecondsToWait)
        currentTimeInSeconds += numberOfSecondsToWait
    }

    /// Time passing without the loop asking for it — the reader sitting and
    /// reading, for instance.
    func advanceBySeconds(_ numberOfSeconds: Double) {
        currentTimeInSeconds += numberOfSeconds
    }
}

/// Frames the test decides. It counts both kinds of capture separately, which is
/// what makes "no capture happened" a thing a test can assert rather than infer.
@MainActor
final class ScriptedWatchLoopFrameSource: WatchLoopFrameSource {
    /// The hash the next fingerprint capture will answer with. A test changes it
    /// to mean "the screen changed".
    var differenceHashOfTheCurrentScreen: UInt64 = 0

    /// Set to nil to simulate a capture that failed outright.
    var fingerprintCaptureSucceeds = true

    var jpegDataForAVisualCheck: Data = Data(repeating: 0xAB, count: 4_096)

    private(set) var numberOfFingerprintCaptures = 0
    private(set) var numberOfVisualCaptures = 0

    var numberOfCapturesOfAnyKind: Int {
        numberOfFingerprintCaptures + numberOfVisualCaptures
    }

    func captureFingerprintOfTheCurrentScreen() async -> ScreenFrameFingerprint? {
        numberOfFingerprintCaptures += 1
        guard fingerprintCaptureSucceeds else {
            return nil
        }
        return ScreenFrameFingerprint(differenceHash: differenceHashOfTheCurrentScreen)
    }

    func captureOneFrameForAVisualModelCheck() async -> Data? {
        numberOfVisualCaptures += 1
        return jpegDataForAVisualCheck
    }
}

/// The local signals, answered from fields a test sets.
@MainActor
final class ScriptedWatchLoopLocalSignalSource: WatchLoopLocalSignalSource {
    var frontmostBundleIdentifier: String? = "com.apple.Terminal"
    var frontmostAppName: String? = "Terminal"
    var windowTitle: String?
    var urlHostOfTheFrontmostWindow: String?
    var installedToolNames: Set<String> = []
    var repositoryPathsThatHaveACommit: Set<String> = []
    var accessibilityLabelsOnScreen: Set<String> = []
    var secureEventInputIsActive = false

    private(set) var numberOfToolChecks = 0
    private(set) var numberOfGitInspections = 0

    func frontmostApplicationBundleIdentifier() -> String? { frontmostBundleIdentifier }
    func frontmostApplicationName() -> String? { frontmostAppName }
    func frontmostWindowTitle() -> String? { windowTitle }

    /// Nil by default, so every existing test keeps sending the whole frame and
    /// the crop is only exercised where a test asks for it.
    var focusedWindowRectangleAndDisplaySize: (window: CGRect, display: CGSize)?
    func focusedWindowRectangleAndDisplaySizeInPoints() -> (window: CGRect, display: CGSize)? {
        focusedWindowRectangleAndDisplaySize
    }
    func hostOfTheURLInTheFrontmostWindow() -> String? { urlHostOfTheFrontmostWindow }

    func isToolInstalled(named toolName: String) async -> Bool {
        numberOfToolChecks += 1
        return installedToolNames.contains(toolName)
    }

    func gitWorkingTreeHasACommit(atRepositoryPath repositoryPath: String) async -> Bool {
        numberOfGitInspections += 1
        return repositoryPathsThatHaveACommit.contains(repositoryPath)
    }

    func isAccessibilityElementPresent(matchingRoleLabel roleLabel: String) -> Bool {
        accessibilityLabelsOnScreen.contains(roleLabel)
    }

    func isSecureEventInputActive() -> Bool { secureEventInputIsActive }
}

/// The model call, recorded. It also remembers how many bytes it was handed and
/// what the loop was holding at the moment it was called, which is how the
/// "screenshots are not retained" rule gets checked from the inside.
@MainActor
final class ScriptedWatchLoopVisualEvaluator: WatchLoopVisualEvaluator {
    var verdictToAnswerWith: WatchVerdict? = .notYet
    private(set) var numberOfCalls = 0
    private(set) var byteCountsItWasHanded: [Int] = []

    /// Checked inside the call, so a test can prove the loop was holding the
    /// frame while it was needed and nothing afterwards.
    weak var watchLoopToInspectDuringTheCall: WatchLoop?
    private(set) var bytesTheLoopHeldDuringTheCall: Int?

    /// The disambiguating facts the loop passed in. A test asserts on these to
    /// prove the loop tells the model which window it means, which is the whole
    /// reason the two cue steps that never fired never fired.
    private(set) var contextsItWasHanded: [WatchScreenContext] = []

    func evaluateWhetherTheStepLooksDone(
        screenshotJPEGData: Data,
        visualPrompt: String,
        stepTitle: String,
        hintsTheStepAuthorWrote: [String],
        context: WatchScreenContext
    ) async -> WatchVerdict? {
        numberOfCalls += 1
        byteCountsItWasHanded.append(screenshotJPEGData.count)
        contextsItWasHanded.append(context)
        bytesTheLoopHeldDuringTheCall = watchLoopToInspectDuringTheCall?.numberOfScreenshotBytesHeldInMemory
        return verdictToAnswerWith
    }
}

// MARK: - The tests

@MainActor
struct WatchLoopTests {

    // MARK: Fixtures

    /// A scratch preferences suite per test, so the excluded-apps list and the
    /// pause switch never touch the machine running the tests.
    static func scratchPreferencesStore() -> UserDefaults {
        let suiteName = "iris.watchloop.tests.\(UUID().uuidString)"
        let preferencesStore = UserDefaults(suiteName: suiteName)!
        preferencesStore.removePersistentDomain(forName: suiteName)
        return preferencesStore
    }

    struct WatchLoopUnderTest {
        let watchLoop: WatchLoop
        let clock: VirtualWatchLoopClock
        let frameSource: ScriptedWatchLoopFrameSource
        let localSignalSource: ScriptedWatchLoopLocalSignalSource
        let visualEvaluator: ScriptedWatchLoopVisualEvaluator
        let preferencesStore: UserDefaults
    }

    static func makeWatchLoop() -> WatchLoopUnderTest {
        let clock = VirtualWatchLoopClock()
        let frameSource = ScriptedWatchLoopFrameSource()
        let localSignalSource = ScriptedWatchLoopLocalSignalSource()
        let visualEvaluator = ScriptedWatchLoopVisualEvaluator()
        let preferencesStore = scratchPreferencesStore()
        let watchLoop = WatchLoop(
            clock: clock,
            frameSource: frameSource,
            localSignalSource: localSignalSource,
            visualEvaluator: visualEvaluator,
            preferencesStore: preferencesStore,
            // The test drives the ticks. A loop ticking on its own against a
            // clock that never really sleeps would spin.
            drivesItsOwnTickTimer: false
        )
        visualEvaluator.watchLoopToInspectDuringTheCall = watchLoop
        return WatchLoopUnderTest(
            watchLoop: watchLoop,
            clock: clock,
            frameSource: frameSource,
            localSignalSource: localSignalSource,
            visualEvaluator: visualEvaluator,
            preferencesStore: preferencesStore
        )
    }

    static func step(
        id: String = "a-step",
        title: String = "Do the thing",
        command: String? = nil,
        watch: IrisStepWatch?
    ) -> IrisGuideStep {
        IrisGuideStep(
            id: id,
            kind: .terminal,
            title: title,
            body: "Body copy.",
            command: command,
            watch: watch
        )
    }

    /// A step that can only be settled by a model, so the ladder is forced all
    /// the way to rung 4 whenever the screen changes.
    static var stepWithOnlyAVisualExpectation: IrisGuideStep {
        step(watch: IrisStepWatch(
            expect: [.visual(prompt: "Does the terminal show a finished install?")],
            hints: ["Scroll up — the error is usually above the last line."]
        ))
    }

    /// Runs enough ticks to get past whatever spacing rule is in force,
    /// advancing the virtual clock between them the way real time would.
    static func tickUntilTheScreenHasChanged(
        _ watchLoopUnderTest: WatchLoopUnderTest,
        toDifferenceHash newDifferenceHash: UInt64
    ) async {
        watchLoopUnderTest.frameSource.differenceHashOfTheCurrentScreen = newDifferenceHash
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
    }

    // MARK: - Rung 0: what is watched at all

    @Test func aStepWithNoWatchBlockIsNeverWatched() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        let stepWrittenBeforeTheWatchLoopExisted = Self.step(watch: nil)

        watchLoopUnderTest.watchLoop.beginWatching(step: stepWrittenBeforeTheWatchLoopExisted)

        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep == false)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText == nil)

        // Ticking it anyway must still capture nothing, because the gate is the
        // state of the loop rather than the discipline of its caller.
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == 0)
    }

    @Test func aWatchBlockThatDeclaresNothingIsAlsoNeverWatched() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()

        watchLoopUnderTest.watchLoop.beginWatching(
            step: Self.step(watch: IrisStepWatch(expect: []))
        )

        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep == false)
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == 0)
    }

    // MARK: - What the model is told about the frame

    /// The loop holds the facts that disambiguate the question — which window is
    /// in front, and what this step asked the reader to run — and for a long
    /// time it kept them to itself. Rehearsing cue's guide on a real desktop
    /// showed what that costs: with several terminals open the model judged the
    /// wrong one, and with a previous command's output still on screen it
    /// judged the wrong moment.
    @Test func theModelIsToldWhichWindowAndWhichCommandTheStepMeans() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.localSignalSource.frontmostAppName = "Terminal"
        watchLoopUnderTest.localSignalSource.windowTitle = "cue — -zsh — 80×24"

        watchLoopUnderTest.watchLoop.beginWatching(
            step: Self.step(
                command: "git checkout 36fa2b41",
                watch: IrisStepWatch(expect: [.visual(prompt: "has git checkout succeeded?")])
            )
        )
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xFACE)

        let context = try #require(watchLoopUnderTest.visualEvaluator.contextsItWasHanded.last)
        #expect(context.frontmostApplicationName == "Terminal")
        #expect(context.focusedWindowTitle == "cue — -zsh — 80×24")
        #expect(context.commandTheStepAsksFor == "git checkout 36fa2b41")
    }

    /// Read per call rather than per step: by the time a multi-minute install
    /// finishes, the reader may well have brought something else forward, and
    /// the frame being judged is the one in front of them now.
    @Test func theWindowIsReadAtTheMomentOfTheCallNotTheStartOfTheStep() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.localSignalSource.frontmostAppName = "Terminal"
        watchLoopUnderTest.localSignalSource.windowTitle = "cue — -zsh"

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xAAAA)

        watchLoopUnderTest.localSignalSource.frontmostAppName = "Safari"
        watchLoopUnderTest.localSignalSource.windowTitle = "console.anthropic.com"
        watchLoopUnderTest.clock.advanceBySeconds(30)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xBBBB)

        let context = try #require(watchLoopUnderTest.visualEvaluator.contextsItWasHanded.last)
        #expect(context.frontmostApplicationName == "Safari")
        #expect(context.focusedWindowTitle == "console.anthropic.com")
    }

    /// When accessibility can say where the focused window is, the model is sent
    /// that window rather than the whole screen. Measured five samples at a
    /// time, that is the difference between 0/5 and 5/5 on a real frame of a
    /// finished install — see `WatchFrameAnnotation`.
    @Test func theFrameIsCutDownToTheFocusedWindowWhenItsPlaceIsKnown() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.localSignalSource.focusedWindowRectangleAndDisplaySize = (
            window: CGRect(x: 100, y: 80, width: 600, height: 400),
            display: CGSize(width: 1512, height: 982)
        )

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xD00D)

        let context = try #require(watchLoopUnderTest.visualEvaluator.contextsItWasHanded.last)
        // The scripted frame source hands over bytes that are not a real JPEG,
        // so the crop cannot succeed — and the flag must follow what actually
        // happened to the image rather than what was attempted.
        #expect(context.frameIsCroppedToThatWindow == false)
    }

    /// Accessibility not answering is the ordinary case on a Mac where the
    /// permission was never granted. The loop must fall back to the whole frame
    /// rather than stop looking.
    @Test func anUnknownWindowPlaceStillSendsTheWholeFrame() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.localSignalSource.focusedWindowRectangleAndDisplaySize = nil

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xBEEF)

        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 1)
        let context = try #require(watchLoopUnderTest.visualEvaluator.contextsItWasHanded.last)
        #expect(context.frameIsCroppedToThatWindow == false)
    }

    /// A step with no command of its own must not inherit one. Naming a command
    /// the step never asked for would recreate the carryover bug pointing the
    /// other way.
    @Test func aStepWithNoCommandNamesNoCommand() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xCAFE)

        let context = try #require(watchLoopUnderTest.visualEvaluator.contextsItWasHanded.last)
        #expect(context.commandTheStepAsksFor == nil)
    }

    // MARK: - Rung 2: the perceptual diff

    @Test func anUnchangedScreenNeverReachesTheModel() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.frameSource.differenceHashOfTheCurrentScreen = 0x0F0F_0F0F_0F0F_0F0F
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        // Two hundred ticks is over six minutes of a reader sitting still.
        for _ in 0..<200 {
            await watchLoopUnderTest.watchLoop.performOneWatchTick()
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.secondsBetweenFrames)
        }

        #expect(watchLoopUnderTest.frameSource.numberOfFingerprintCaptures == 200)
        // The whole point of the ladder: an unchanged screen costs one tiny
        // grayscale capture and nothing else, forever.
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
        #expect(watchLoopUnderTest.frameSource.numberOfVisualCaptures == 0)
        #expect(watchLoopUnderTest.localSignalSource.numberOfToolChecks == 0)
        #expect(watchLoopUnderTest.watchLoop.numberOfModelChecksUsedOnThisStep == 0)
    }

    @Test func aChangeSmallerThanTheThresholdIsNotAChange() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.frameSource.differenceHashOfTheCurrentScreen = 0
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        await watchLoopUnderTest.watchLoop.performOneWatchTick()

        // Four bits — a blinking caret, a clock digit. Below the threshold of
        // five, so the loop stays asleep.
        watchLoopUnderTest.frameSource.differenceHashOfTheCurrentScreen = 0b1111
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)

        // Twelve bits from the last frame — a window opening.
        watchLoopUnderTest.frameSource.differenceHashOfTheCurrentScreen = 0b1111_1111_1111_0000
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 1)
    }

    @Test func theHashItselfSeparatesAQuietScreenFromABusyOne() throws {
        let quietScreen = [UInt8](repeating: 128, count: PerceptualFrameHash.expectedSampleCount)
        #expect(PerceptualFrameHash.differenceHash(fromGrayscaleSamples: quietScreen) == 0)

        // A gradient across every row flips every comparison in the same
        // direction, which is the far end of the same 64-bit space.
        var gradientScreen: [UInt8] = []
        for _ in 0..<PerceptualFrameHash.sampleGridHeight {
            for columnIndex in 0..<PerceptualFrameHash.sampleGridWidth {
                gradientScreen.append(UInt8(255 - columnIndex * 20))
            }
        }
        let gradientHash = PerceptualFrameHash.differenceHash(fromGrayscaleSamples: gradientScreen)
        #expect(gradientHash == UInt64.max)
        #expect(
            PerceptualFrameHash.hammingDistance(between: 0, and: gradientHash) == 64
        )

        // A capture that came back the wrong shape answers zero rather than
        // trapping — a malformed frame must not take the app down.
        #expect(PerceptualFrameHash.differenceHash(fromGrayscaleSamples: [1, 2, 3]) == 0)
    }

    // MARK: - Rung 3: the local signals come first

    @Test func aChangedScreenConsultsLocalSignalsAndSkipsTheModelWhenTheySettleIt() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        // Both a local expectation and a visual one. The local one being
        // satisfied has to be enough on its own.
        let stepThatCanBeSettledLocally = Self.step(watch: IrisStepWatch(
            expect: [
                .foregroundApp(bundleId: "com.apple.Safari"),
                .visual(prompt: "Is the download finished?"),
            ]
        ))
        watchLoopUnderTest.watchLoop.beginWatching(step: stepThatCanBeSettledLocally)

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in
            verdictsReported.append(verdict)
        }

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfFingerprintCaptures == 1)

        // The reader switches to Safari, which is what the step was waiting for.
        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.apple.Safari"
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(verdictsReported == [.completed])
        // No model call, and no screenshot taken for one either.
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
        #expect(watchLoopUnderTest.frameSource.numberOfVisualCaptures == 0)

        // The screen was allowed a moment to settle before anything was read
        // off it — otherwise the loop reads a state that lasted 200 ms.
        #expect(
            watchLoopUnderTest.clock.everyWaitThatWasRequested
                .contains(WatchLoop.secondsToWaitForTheScreenToSettle)
        )
    }

    @Test func aLocalSignalThatSaysNotDoneStopsTheLadderBeforeTheModel() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        // No visual expectation, so a local "not yet" is the final answer and
        // there is nothing left worth paying for.
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.step(watch: IrisStepWatch(
            expect: [.toolVersion(tool: "node")]
        )))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        // Once for the baseline frame, once for the change. Neither cost a
        // model call, because a local signal answered both.
        #expect(watchLoopUnderTest.localSignalSource.numberOfToolChecks == 2)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
        #expect(verdictsReported.isEmpty)

        // The reader installs Node. Next meaningful change, the step is done —
        // still without a single model call.
        watchLoopUnderTest.localSignalSource.installedToolNames.insert("node")
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0x0F0F)

        #expect(verdictsReported == [.completed])
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
    }

    @Test func aCloneIsNoticedFromTheStepsOwnCommandRatherThanFromPixels() async throws {
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let expectedRepositoryPath = "\(homeDirectoryPath)/cue"
        #expect(
            WatchLoop.repositoryPathAGitCloneWouldCreate(
                inCommand: "cd ~\ngit clone https://github.com/Blueturboguy07/cue.git"
            ) == expectedRepositoryPath
        )
        // A `cd` into a subdirectory, an explicit destination, and no clone at
        // all all have to land somewhere sensible.
        #expect(
            WatchLoop.repositoryPathAGitCloneWouldCreate(
                inCommand: "cd ~/Developer\ngit clone https://example.com/thing.git"
            ) == "\(homeDirectoryPath)/Developer/thing"
        )
        #expect(
            WatchLoop.repositoryPathAGitCloneWouldCreate(
                inCommand: "git clone --depth 1 https://example.com/thing.git myclone"
            ) == "\(homeDirectoryPath)/myclone"
        )
        #expect(WatchLoop.repositoryPathAGitCloneWouldCreate(inCommand: "npm install") == nil)
        #expect(WatchLoop.repositoryPathAGitCloneWouldCreate(inCommand: nil) == nil)

        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.step(
            command: "cd ~\ngit clone https://github.com/Blueturboguy07/cue.git",
            watch: IrisStepWatch(expect: [.foregroundApp(bundleId: "com.apple.Terminal")])
        ))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        // Terminal is already in front, but the clone has not landed, so the
        // step is not done — the git signal is what is holding it.
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)
        #expect(watchLoopUnderTest.localSignalSource.numberOfGitInspections == 2)
        #expect(verdictsReported.isEmpty)

        watchLoopUnderTest.localSignalSource.repositoryPathsThatHaveACommit.insert(expectedRepositoryPath)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0x00FF)
        #expect(verdictsReported == [.completed])
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
    }

    @Test func aHostExpectationMatchesSubdomainsAndNothingElse() throws {
        #expect(WatchLoop.host("console.anthropic.com", matchesExpectedHost: "console.anthropic.com"))
        #expect(WatchLoop.host("CONSOLE.Anthropic.com", matchesExpectedHost: "console.anthropic.com"))
        #expect(WatchLoop.host("eu.console.anthropic.com", matchesExpectedHost: "console.anthropic.com"))
        // The match a signal like this must never make.
        #expect(WatchLoop.host("evilconsole.anthropic.com", matchesExpectedHost: "console.anthropic.com") == false)
        #expect(WatchLoop.host(nil, matchesExpectedHost: "console.anthropic.com") == false)
    }

    // MARK: - Rung 4: the budget

    @Test func tenSecondsHasToPassBetweenTwoModelChecks() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 1)

        // The screen keeps changing, hard, every couple of seconds. The spacing
        // rule is the only thing holding the model calls back — three rounds of
        // two seconds plus the settle wait is still short of ten.
        var differenceHash: UInt64 = 1
        for _ in 0..<3 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.secondsBetweenFrames)
            differenceHash = ~differenceHash
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: differenceHash)
        }
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 1)

        // Past ten seconds since the first call, the next change may ask again.
        watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xDEAD_BEEF)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 2)
    }

    @Test func eightModelChecksIsTheCeilingAndTheLoopKeepsGoingOnLocalSignalsAfterIt() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        // Both kinds of expectation, so there is still a local answer available
        // once the model budget is gone.
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.step(watch: IrisStepWatch(
            expect: [
                .axElement(roleLabel: "Create Key"),
                .visual(prompt: "Is the key visible?"),
            ]
        )))

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        var differenceHash: UInt64 = 1
        // Far more rounds than the ceiling, each one well clear of the spacing
        // rule, so the only thing that can stop them is the ceiling itself.
        for _ in 0..<30 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks * 2)
            differenceHash = ~differenceHash
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: differenceHash)
        }

        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == WatchLoop.maximumModelChecksPerStep)
        #expect(watchLoopUnderTest.watchLoop.numberOfModelChecksUsedOnThisStep == 8)
        #expect(watchLoopUnderTest.watchLoop.modelEvaluationIsExhaustedForThisStep)
        // Eight looks, eight "not yet"s, and not one of them advanced anything.
        #expect(verdictsReported == Array(repeating: .notYet, count: 8))

        // The loop is still alive and still watching — it just stopped paying.
        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText != nil)

        // And the local signal it still has can still finish the step.
        watchLoopUnderTest.localSignalSource.accessibilityLabelsOnScreen.insert("Create Key")
        watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks * 2)
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0x1234_5678)

        #expect(verdictsReported.last == .completed)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == WatchLoop.maximumModelChecksPerStep)
    }

    @Test func theBudgetStartsAgainForTheNextStepButNotForTheSameOne() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)
        #expect(watchLoopUnderTest.watchLoop.numberOfModelChecksUsedOnThisStep == 1)

        watchLoopUnderTest.watchLoop.beginWatching(
            step: Self.step(id: "the-next-step", watch: Self.stepWithOnlyAVisualExpectation.watch)
        )
        #expect(watchLoopUnderTest.watchLoop.numberOfModelChecksUsedOnThisStep == 0)
        #expect(watchLoopUnderTest.watchLoop.modelEvaluationIsExhaustedForThisStep == false)

        // A fresh step gets a fresh spacing window too, so the reader is not
        // made to wait out the previous step's ten seconds.
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: 0xAAAA)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 2)
    }

    @Test func aFailedModelCallStillSpendsBudgetSoABrokenModelIsNotHammered() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.visualEvaluator.verdictToAnswerWith = nil
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 1)
        #expect(watchLoopUnderTest.watchLoop.numberOfModelChecksUsedOnThisStep == 1)
    }

    // MARK: - `userStuck` is what makes it adaptive

    @Test func aStuckVerdictPutsTheHintInFrontOfTheReaderWithoutBeingAsked() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.visualEvaluator.verdictToAnswerWith = .userStuck(
            hint: "That error means the port is already in use — try 3001."
        )
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(
            watchLoopUnderTest.watchLoop.proactiveHintForTheReader
                == "That error means the port is already in use — try 3001."
        )
        // Stuck is not done. The loop keeps watching, because the reader may
        // still fix it themselves.
        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep)

        watchLoopUnderTest.watchLoop.dismissTheProactiveHint()
        #expect(watchLoopUnderTest.watchLoop.proactiveHintForTheReader == nil)
    }

    @Test func theModelsOneLineAnswerIsReadStrictlyAndAnythingElseTeachesNothing() throws {
        typealias Evaluator = AssistantTransportWatchLoopVisualEvaluator
        let authoredHints = ["Check the address bar says console.anthropic.com."]

        #expect(
            Evaluator.verdict(fromModelAnswer: "COMPLETED", hintsTheStepAuthorWrote: authoredHints)
                == .completed
        )
        #expect(
            Evaluator.verdict(fromModelAnswer: "NOT_YET\nthe install is still running",
                              hintsTheStepAuthorWrote: authoredHints) == .notYet
        )
        #expect(
            Evaluator.verdict(fromModelAnswer: "STUCK: a permission dialog is covering the button",
                              hintsTheStepAuthorWrote: authoredHints)
                == .userStuck(hint: "a permission dialog is covering the button")
        )
        // A stuck verdict with no hint is useless to a reader, so the author's
        // own hint stands in rather than an empty banner.
        #expect(
            Evaluator.verdict(fromModelAnswer: "STUCK:", hintsTheStepAuthorWrote: authoredHints)
                == .userStuck(hint: authoredHints[0])
        )
        // "Learned nothing" is not "not done", and must not be collapsed into it.
        #expect(
            Evaluator.verdict(fromModelAnswer: "I think you might be done?",
                              hintsTheStepAuthorWrote: authoredHints) == nil
        )
    }

    // MARK: - Privacy rule 1: frames live in memory only

    @Test func aScreenshotIsHeldOnlyForTheCallItWasTakenForAndNeverStored() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.frameSource.jpegDataForAVisualCheck = Data(repeating: 0x7F, count: 12_345)
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        // The frame existed for the call, and only for the call.
        #expect(watchLoopUnderTest.visualEvaluator.byteCountsItWasHanded == [12_345])
        #expect(watchLoopUnderTest.visualEvaluator.bytesTheLoopHeldDuringTheCall == 12_345)
        #expect(watchLoopUnderTest.watchLoop.numberOfScreenshotBytesHeldInMemory == 0)

        // Structurally, too: not one stored property of the loop is even shaped
        // like an image, so there is nowhere for a frame to be kept between
        // ticks. The one thing that survives a tick is a 64-bit hash.
        for storedProperty in Mirror(reflecting: watchLoopUnderTest.watchLoop).children {
            let typeOfThisStoredProperty = String(describing: type(of: storedProperty.value))
            #expect(!typeOfThisStoredProperty.contains("Data"))
            #expect(!typeOfThisStoredProperty.contains("CGImage"))
            #expect(!typeOfThisStoredProperty.contains("NSImage"))
        }
    }

    @Test func theOnlyThingTheLoopWritesDownIsTheReadersOwnSettings() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        var differenceHash: UInt64 = 1
        for _ in 0..<20 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
            differenceHash = ~differenceHash
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: differenceHash)
        }
        watchLoopUnderTest.watchLoop.addExcludedApp(bundleIdentifier: "com.example.vault")
        watchLoopUnderTest.watchLoop.setReaderPausedWatching(true)

        // Twenty rounds of watching, eight of them model calls, and the only
        // things that reached storage are the two settings the reader owns.
        let everythingTheLoopPersisted = watchLoopUnderTest.preferencesStore
            .dictionaryRepresentation()
            .keys
            .filter { key in key.hasPrefix("irisWatchLoop") }
            .sorted()
        #expect(everythingTheLoopPersisted == [
            WatchLoop.excludedAppBundleIdentifiersPreferenceKey,
            WatchLoop.readerPausedWatchingPreferenceKey,
        ].sorted())
    }

    // MARK: - Privacy rule 2: secure input

    @Test func secureInputSuspendsCaptureMidStepAndResumingClearsCleanly() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfFingerprintCaptures == 1)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow)

        // Somebody starts typing a password in the middle of the step.
        watchLoopUnderTest.localSignalSource.secureEventInputIsActive = true
        let capturesBeforeSecureInput = watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind
        for _ in 0..<10 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
            await watchLoopUnderTest.watchLoop.performOneWatchTick()
        }

        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeSecureInput)
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == .secureInputIsActive)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow == false)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText?.contains("protected") == true)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)

        // They finish typing. Capture comes straight back, with no residue.
        watchLoopUnderTest.localSignalSource.secureEventInputIsActive = false
        await watchLoopUnderTest.watchLoop.performOneWatchTick()

        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == nil)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow)
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeSecureInput + 1)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText == "Iris is watching this step.")
    }

    // MARK: - Privacy rule 3: a sensitive step

    @Test func aSensitiveStepCapturesNothingAtAllAndStillCompletesFromSideSignals() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        // Exactly the "copy the key" step from the Anthropic key flow: the one
        // moment the secret is on screen.
        let sensitiveStep = Self.step(
            id: "copy-key",
            title: "Copy the key",
            watch: IrisStepWatch(
                expect: [.foregroundApp(bundleId: "com.publikhq.iris")],
                sensitive: true,
                hints: ["The key starts with sk-ant- and is only shown once."]
            )
        )
        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.apple.Safari"
        watchLoopUnderTest.watchLoop.beginWatching(step: sensitiveStep)

        var verdictsReported: [WatchVerdict] = []
        watchLoopUnderTest.watchLoop.onVerdict = { verdict in verdictsReported.append(verdict) }

        // The screen changes violently — the key appears, a dialog opens — and
        // none of it is looked at.
        var differenceHash: UInt64 = 1
        for _ in 0..<12 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
            differenceHash = ~differenceHash
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: differenceHash)
        }

        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == 0)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == .theStepIsMarkedSensitive)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow == false)
        #expect(verdictsReported.isEmpty)

        // The reader copies the key and switches to Iris. That side signal is
        // enough to finish the step, with no pixel ever leaving the machine.
        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.publikhq.iris"
        await watchLoopUnderTest.watchLoop.performOneWatchTick()

        #expect(verdictsReported == [.completed])
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == 0)
    }

    // MARK: - Privacy rule 4: the excluded-apps list

    @Test func anExcludedAppInFrontSuppressesCapture() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        let capturesBeforeThePasswordManager = watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind
        #expect(capturesBeforeThePasswordManager == 1)

        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.1password.1password"
        watchLoopUnderTest.localSignalSource.frontmostAppName = "1Password"
        for _ in 0..<5 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)
        }

        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeThePasswordManager)
        #expect(
            watchLoopUnderTest.watchLoop.captureIsSuspendedBecause
                == .anExcludedAppIsInFront(appName: "1Password")
        )
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText?.contains("1Password") == true)

        // Back to the guide's app, and capture resumes.
        watchLoopUnderTest.localSignalSource.frontmostBundleIdentifier = "com.apple.Terminal"
        watchLoopUnderTest.localSignalSource.frontmostAppName = "Terminal"
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == nil)
        #expect(watchLoopUnderTest.frameSource.numberOfFingerprintCaptures == 2)
    }

    @Test func theExcludedListShipsWithThePasswordManagersAndTheReaderCanEditIt() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()

        for seededBundleIdentifier in [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "org.keepassxc.keepassxc",
            "com.apple.keychainaccess",
            "com.apple.Passwords",
        ] {
            #expect(watchLoopUnderTest.watchLoop.isExcludedFromCapture(bundleIdentifier: seededBundleIdentifier))
        }

        watchLoopUnderTest.watchLoop.addExcludedApp(bundleIdentifier: "com.example.SecretsApp")
        #expect(watchLoopUnderTest.watchLoop.isExcludedFromCapture(bundleIdentifier: "com.example.secretsapp"))
        // Adding the same app twice must not put it in the list twice.
        watchLoopUnderTest.watchLoop.addExcludedApp(bundleIdentifier: "com.example.SECRETSAPP")
        #expect(
            watchLoopUnderTest.watchLoop.excludedAppBundleIdentifiers
                .filter { $0.lowercased() == "com.example.secretsapp" }
                .count == 1
        )

        watchLoopUnderTest.watchLoop.removeExcludedApp(bundleIdentifier: "com.1password.1password")
        #expect(watchLoopUnderTest.watchLoop.isExcludedFromCapture(bundleIdentifier: "com.1password.1password") == false)

        // The reader's edits survive a relaunch, because they are the reader's.
        let watchLoopAfterARelaunch = WatchLoop(
            preferencesStore: watchLoopUnderTest.preferencesStore,
            drivesItsOwnTickTimer: false
        )
        #expect(watchLoopAfterARelaunch.isExcludedFromCapture(bundleIdentifier: "com.example.SecretsApp"))
        #expect(watchLoopAfterARelaunch.isExcludedFromCapture(bundleIdentifier: "com.1password.1password") == false)
    }

    // MARK: - Privacy rule 5: the indicator and the pause

    @Test func theIndicatorIsOnForExactlyAsLongAsTheLoopIs() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText == nil)

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText == "Iris is watching this step.")

        watchLoopUnderTest.watchLoop.stopWatching()
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText == nil)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow == false)
    }

    @Test func pauseTakesEffectImmediatelyAndResumingPutsItBack() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        let capturesBeforeThePause = watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind
        #expect(capturesBeforeThePause == 1)

        watchLoopUnderTest.watchLoop.setReaderPausedWatching(true)
        // Immediately, before any tick has run: the loop already says it is not
        // looking. A pause that only takes hold on the next tick is a pause that
        // captured one more frame than the reader agreed to.
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == .theReaderPausedIris)
        #expect(watchLoopUnderTest.watchLoop.isCapturingRightNow == false)
        #expect(watchLoopUnderTest.watchLoop.watchIndicatorText?.contains("paused") == true)

        // And nothing runs while paused — not a capture, not a tool check, not
        // a model call. Paused means paused.
        var differenceHash: UInt64 = 1
        for _ in 0..<10 {
            watchLoopUnderTest.clock.advanceBySeconds(WatchLoop.minimumSecondsBetweenModelChecks)
            differenceHash = ~differenceHash
            await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: differenceHash)
        }
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeThePause)
        #expect(watchLoopUnderTest.localSignalSource.numberOfToolChecks == 0)
        #expect(watchLoopUnderTest.visualEvaluator.numberOfCalls == 0)

        watchLoopUnderTest.watchLoop.setReaderPausedWatching(false)
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == nil)
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeThePause + 1)
    }

    @Test func aPauseSurvivesTheNextStepAndTheNextLaunch() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.watchLoop.setReaderPausedWatching(true)

        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)
        #expect(watchLoopUnderTest.watchLoop.captureIsSuspendedBecause == .theReaderPausedIris)
        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == 0)

        let watchLoopAfterARelaunch = WatchLoop(
            preferencesStore: watchLoopUnderTest.preferencesStore,
            drivesItsOwnTickTimer: false
        )
        #expect(watchLoopAfterARelaunch.readerPausedWatching)
    }

    // MARK: - Stopping

    @Test func stoppingForgetsEverythingAboutTheScreenItWasWatching() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.visualEvaluator.verdictToAnswerWith = .userStuck(hint: "try again")
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)
        #expect(watchLoopUnderTest.watchLoop.proactiveHintForTheReader != nil)

        watchLoopUnderTest.watchLoop.stopWatching()

        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep == false)
        #expect(watchLoopUnderTest.watchLoop.stepBeingWatched == nil)
        #expect(watchLoopUnderTest.watchLoop.proactiveHintForTheReader == nil)

        // Nothing runs after a stop, however many times it is ticked.
        let capturesBeforeTheStop = watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind
        for _ in 0..<5 {
            await watchLoopUnderTest.watchLoop.performOneWatchTick()
        }
        #expect(watchLoopUnderTest.frameSource.numberOfCapturesOfAnyKind == capturesBeforeTheStop)
    }

    @Test func aCompletedStepStopsTheLoopBeforeItTellsAnybody() async throws {
        let watchLoopUnderTest = Self.makeWatchLoop()
        watchLoopUnderTest.visualEvaluator.verdictToAnswerWith = .completed
        watchLoopUnderTest.watchLoop.beginWatching(step: Self.stepWithOnlyAVisualExpectation)

        // The handler is what advances the guide, and it must find the loop
        // already torn down so it can start watching the next step cleanly.
        var loopWasStillWatchingWhenTheHandlerRan: Bool?
        watchLoopUnderTest.watchLoop.onVerdict = { [weak watchLoop = watchLoopUnderTest.watchLoop] _ in
            loopWasStillWatchingWhenTheHandlerRan = watchLoop?.isWatchingAStep
        }

        await watchLoopUnderTest.watchLoop.performOneWatchTick()
        await Self.tickUntilTheScreenHasChanged(watchLoopUnderTest, toDifferenceHash: .max)

        #expect(loopWasStillWatchingWhenTheHandlerRan == false)
        #expect(watchLoopUnderTest.watchLoop.isWatchingAStep == false)
    }

    // MARK: - The guide's own step model

    @Test func aWatchBlockDecodesFromTheWebsitesShapeAndSurvivesASignalItDoesNotKnow() throws {
        let stepJSON = """
        {
          "id": "open-console",
          "kind": "web",
          "title": "Open the Anthropic console",
          "body": "Iris will wait while you sign in.",
          "href": "https://console.anthropic.com/settings/keys",
          "watch": {
            "expect": [
              { "type": "urlHost", "host": "console.anthropic.com" },
              { "type": "somethingFromTheFuture", "wat": 1 },
              { "type": "visual", "prompt": "Is the keys page open?" }
            ],
            "sensitive": true,
            "hints": ["Sign in first if a sign-in page appeared."]
          }
        }
        """
        let decodedStep = try JSONDecoder().decode(
            IrisGuideStep.self,
            from: Data(stepJSON.utf8)
        )
        let watchPlan = try #require(decodedStep.watch)

        // The signal this build does not understand costs one signal, not the
        // step and not the guide.
        #expect(watchPlan.expect == [
            .urlHost(host: "console.anthropic.com"),
            .visual(prompt: "Is the keys page open?"),
        ])
        #expect(watchPlan.sensitive)
        #expect(watchPlan.hints == ["Sign in first if a sign-in page appeared."])
        #expect(watchPlan.declaresAVisualExpectation)
        #expect(watchPlan.visualPrompt == "Is the keys page open?")
        #expect(watchPlan.expectationsAnsweredWithoutPixels == [.urlHost(host: "console.anthropic.com")])

        // A step with no watch block at all still decodes, because every guide
        // written before the watch loop existed has none.
        let stepWithoutAWatchBlock = try JSONDecoder().decode(
            IrisGuideStep.self,
            from: Data("""
            {"id":"a","kind":"terminal","title":"t","body":"b"}
            """.utf8)
        )
        #expect(stepWithoutAWatchBlock.watch == nil)
    }
}
