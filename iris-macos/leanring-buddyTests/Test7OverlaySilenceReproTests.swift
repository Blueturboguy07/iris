//
//  Test7OverlaySilenceReproTests.swift
//  leanring-buddyTests
//
//  TEST 7, THE EDIT FLOW GOES SILENT THE MOMENT THE READER LOOKS AWAY.
//
//  The reader, verbatim:
//
//      "After I put a prompt into feature or bug fix, I get no feedback of if
//       it has gone through, a loading thing or something would be really
//       helpful, or if I click off Iris and it reverts back to the eye, once
//       the response is done loading and needs my intervention, it should ping
//       me or change the UI to show me it needs my approval."
//
//      "the chat below is linked to a general chat … super confusing"
//
//  WHAT ACTUALLY HAPPENED TO HIM. Both of his submissions were refused by the
//  dirty-clone preflight, and he saw neither refusal. Three separate silences
//  stacked up to produce that:
//
//    1. Sending a request does not move the flow out of `.describe` — the §7
//       request probe runs first, for up to a twenty-second watchdog — and the
//       eye's bar draws its OWN composer for `.describe`, because
//       `OnDemandEditCard` is only rendered while the phase is NOT `.describe`.
//       The card's describe step has always carried a "Sizing up the request…"
//       row. The composer that replaced it did not bring that row across, and
//       sending cleared the field, so his own sentence vanished too.
//
//    2. Dismissing the bar destroys the view that would have shown the refusal,
//       and the eye it collapses into draws a mood computed from
//       `CompanionManager.assistantState` — which only the CHAT pipeline ever
//       writes. There was no wire at all from the edit flow to the eye.
//
//    3. Reopening the bar restores the last general-chat exchange underneath
//       the edit card, in the same glass, about a different subject.
//
//  RECREATED AT HEAD (0.9.3, build 19) BEFORE ANY OF THIS WAS WRITTEN, by
//  driving the real objects and rendering the real views offscreen:
//
//    * `pickApp` → `.notEligible`, and `assistantState` stayed `.idle` through
//      the transition and through the phase publisher landing.
//    * The real `BlueCursorView`, rendered twice — once quiet, once with the
//      coordinator sitting in that refusal — produced BYTE-IDENTICAL PNGs
//      (32691 bytes each). The eye was literally the same picture.
//    * The real `OverlayEyeInputBarView`, with an app open for editing on a
//      real clone, rendered to 250.5pt and byte-identical pixels both before
//      and after `describeRequest` was accepted (`isAssessingRequest == true`).
//    * The same bar with an edit card up grew 315.5pt → 404.5pt purely to lay
//      out a restored general-chat answer beneath it.
//
//  These tests pin the fix. Nothing here greps source: every assertion is on
//  state the running app reaches, or on what the real views actually draw.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Iris

// MARK: - 1 & 2. The eye has to know, and say so

@MainActor
@Suite(.serialized)
struct Test7EyeAttentionTests {

    /// Every phase where Iris has stopped and cannot go on without a person is
    /// the reader's turn — INCLUDING the terminal ones, because the refusal
    /// nobody ever saw is what this whole cluster is about.
    @Test func everyPhaseThatWaitsOnAPersonAsksForTheReader() {
        let phasesThatWaitOnAPerson: [OnDemandEditPhase] = [
            .clarifying,
            .presentingPlan,
            .awaitingStartConsent,
            .previewDiff,
            .awaitingRelaunchConsent,
            .awaitingManifestConsent,
            .awaitingSymptomConfirmation,
            .awaitingForceQuitConsent,
            .done,
            .failed(reason: "something went wrong"),
            // The reader's own case: the dirty-clone preflight refusal.
            .notEligible(
                reason: "your clone has uncommitted changes — commit or stash them first"
            ),
            .blockedByModel(explanation: "the environment has no pnpm executable"),
        ]
        for phase in phasesThatWaitOnAPerson {
            #expect(
                OverlayEyeAttention.forEditFlow(
                    phase: phase, theRequestIsBeingAssessed: false
                ) == .needsTheReader,
                "\(phase) waits on a person and the eye would have said nothing"
            )
        }
    }

    /// Work is work: the eye looks busy, but it is not asking for anything.
    @Test func theStatesThatAreJustWorkDoNotAskForAnything() {
        for phase: OnDemandEditPhase in [.running, .committing, .relaunching, .delivering] {
            #expect(
                OverlayEyeAttention.forEditFlow(
                    phase: phase, theRequestIsBeingAssessed: false
                ) == .working
            )
        }
        #expect(
            OverlayEyeAttention.forEditFlow(
                phase: .pickApp, theRequestIsBeingAssessed: false
            ) == .nothingToSay
        )
    }

    /// THE SUBMIT MOMENT. Accepting a request leaves the phase on `.describe`,
    /// so the phase alone can never see it. "I get no feedback of if it has
    /// gone through."
    @Test func acceptingARequestIsWorkEvenThoughThePhaseHasNotMoved() {
        #expect(
            OverlayEyeAttention.forEditFlow(
                phase: .describe, theRequestIsBeingAssessed: false
            ) == .nothingToSay
        )
        #expect(
            OverlayEyeAttention.forEditFlow(
                phase: .describe, theRequestIsBeingAssessed: true
            ) == .working
        )
    }

    /// THE MAIN REPRO. Drive the REAL coordinator into the refusal the reader
    /// hit, with the bar dismissed, and require the eye to have something to
    /// say about it. At HEAD this was `.nothingToSay` for every phase there is,
    /// because nothing connected the two.
    @Test func theEyeAsksForTheReaderWhenAnEditStopsWithTheBarDismissed() async throws {
        let companionManager = CompanionManager()
        let coordinator = companionManager.onDemandEditCoordinator

        #expect(companionManager.attentionTheEyeShouldShow == .nothingToSay)

        // The reader's rejection, in the phase it lands in. (His was raised by
        // the dirty-clone preflight inside `runEdit`; a refused pick raises the
        // same phase without needing a credential, and the eye cannot tell the
        // two apart — which is the point.)
        let slug = "t7-eye-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        guard case .notEligible = coordinator.phase else {
            Issue.record("expected a refusal to signal about; got \(coordinator.phase)")
            return
        }

        let signalled = await waitUntil {
            companionManager.attentionTheEyeShouldShow == .needsTheReader
        }
        #expect(
            signalled,
            "Iris stopped in a refusal and the eye had nothing to say: \(companionManager.attentionTheEyeShouldShow)"
        )

        // The chat pipeline is untouched — this rides alongside it, so a chat
        // in flight still owns the eye.
        #expect(companionManager.assistantState == .idle)
    }

    /// Opening the bar puts the waiting card in front of the reader, so the
    /// signal comes down. A badge that stayed lit forever would be decoration.
    ///
    /// THE SECOND HALF IS THE ONE THAT BIT. Both refusals below carry the SAME
    /// sentence, because both apps are refused by the same rule — exactly like
    /// the reader's two submissions, which the dirty-clone preflight refused
    /// identically. A first cut of this fix remembered the PHASE the reader had
    /// seen, so the second refusal compared equal to the first and was
    /// swallowed: the reader looked once, and Iris went quiet for the rest of
    /// the session. That is the reported bug, rebuilt inside its own fix. What
    /// is remembered is now the announcement, not what was announced.
    @Test func lookingAtTheBarAnswersTheSignalAndAFreshOneRaisesItAgain() async throws {
        let companionManager = CompanionManager()
        let coordinator = companionManager.onDemandEditCoordinator

        let firstSlug = "t7-ack-a-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(firstSlug), name: "Repro App", stack: .nextjs)
        _ = await waitUntil { companionManager.attentionTheEyeShouldShow == .needsTheReader }
        #expect(companionManager.attentionTheEyeShouldShow == .needsTheReader)

        // The reader clicks the eye; the bar opens with the card at the top.
        companionManager.theReaderIsLookingAtTheEyesBar()
        #expect(companionManager.attentionTheEyeShouldShow == .nothingToSay)

        // They dismiss it again. Nothing has changed, so nothing nags them.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(companionManager.attentionTheEyeShouldShow == .nothingToSay)

        // Iris then needs them for something ELSE. That has to reach them.
        let secondSlug = "t7-ack-b-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(secondSlug), name: "Another App", stack: .nextjs)
        let raisedAgain = await waitUntil {
            companionManager.attentionTheEyeShouldShow == .needsTheReader
        }
        #expect(raisedAgain, "a second thing needing the reader never reached the eye")

        // And once more on the SAME app, which is the reader's own shape: the
        // same request, refused the same way, twice.
        companionManager.theReaderIsLookingAtTheEyesBar()
        #expect(companionManager.attentionTheEyeShouldShow == .nothingToSay)
        coordinator.pickApp(slug: String(secondSlug), name: "Another App", stack: .nextjs)
        let raisedForTheIdenticalRefusal = await waitUntil {
            companionManager.attentionTheEyeShouldShow == .needsTheReader
        }
        #expect(
            raisedForTheIdenticalRefusal,
            "the same refusal a second time was swallowed — the reader is back to seeing nothing"
        )
    }

    /// THE OTHER HALF OF THE SIGNAL: what the reader gets for following it.
    ///
    /// A badge that opened a fresh chat would be worse than no badge — it would
    /// point at something and then hide it. The card the eye is asking about
    /// has to be IN the bar the click opens, above the field, whatever the
    /// composer happens to be set to. Rendered rather than reasoned about: the
    /// bar with Iris waiting is taller than the same bar with nothing pending,
    /// and the difference is the card.
    @Test func theBarTheClickOpensIsShowingTheThingIrisIsWaitingOn() async throws {
        let companionManager = CompanionManager()
        let nothingPending = Test7Rendering.bar(companionManager: companionManager)

        let coordinator = companionManager.onDemandEditCoordinator
        let slug = "t7-land-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        guard case .notEligible = coordinator.phase else {
            Issue.record("expected a waiting card; got \(coordinator.phase)")
            return
        }
        _ = await waitUntil { companionManager.attentionTheEyeShouldShow == .needsTheReader }

        // The click itself: the overlay tells the manager the reader is looking,
        // then presents the bar.
        companionManager.theReaderIsLookingAtTheEyesBar()
        let whatTheClickOpens = Test7Rendering.bar(companionManager: companionManager)

        #expect(
            whatTheClickOpens.height > nothingPending.height,
            "the bar the badge opened is the same size as an empty one — the card the reader was sent for is not in it"
        )
    }

    /// THE PIXELS. The recreation's own measurement, inverted: render the REAL
    /// overlay quiet and then with Iris waiting, and require the two to differ.
    /// At HEAD they were byte-identical.
    @Test func theRealEyeActuallyDrawsSomethingDifferentWhenItNeedsTheReader() async throws {
        guard let mainScreen = NSScreen.main else { return }
        let screenFrame = mainScreen.frame
        guard ScreenContainment.screenFrame(screenFrame, containsPointer: NSEvent.mouseLocation) else {
            // The eye only draws on the screen the pointer is on. Nothing to
            // photograph; the state assertions above still stand.
            return
        }

        let companionManager = CompanionManager()
        let coordinator = companionManager.onDemandEditCoordinator

        guard let quiet = Test7Rendering.eyePixels(
            companionManager: companionManager, screenFrame: screenFrame
        ), !quiet.isEmpty else { return }

        let slug = "t7-px-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        _ = await waitUntil { companionManager.attentionTheEyeShouldShow == .needsTheReader }

        guard let waiting = Test7Rendering.eyePixels(
            companionManager: companionManager, screenFrame: screenFrame
        ) else { return }

        #expect(
            quiet != waiting,
            "the eye draws exactly the same thing whether or not Iris is waiting for you"
        )
    }

    @discardableResult
    private func waitUntil(
        timeoutSeconds: Double = 5, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }
}

// MARK: - 1. The bar, at the instant a request is submitted

@MainActor
@Suite(.serialized)
struct Test7SubmitFeedbackTests {

    /// THE REPORTED SYMPTOM: "After I put a prompt into feature or bug fix, I
    /// get no feedback of if it has gone through."
    ///
    /// Drives the REAL composer on a REAL clone and photographs the REAL bar
    /// either side of the send. At HEAD both renders were 250.5pt and
    /// byte-identical.
    @Test func theBarVisiblyChangesTheInstantARequestIsAccepted() async throws {
        guard MaintainSandbox.isAvailable,
              MaintainModelProviderResolver.firstAvailable() != nil else {
            // Without a connected editing credential the flow cannot be entered
            // at all — the same graceful skip the other edit suites use.
            return
        }
        let clonePath = try Test7Fixtures.makeCleanSourceCloneInsideHome()
        defer { Test7Fixtures.removeDirectory(clonePath) }
        let slug = "t7-submit-\(UUID().uuidString.prefix(8))"
        defer { Test7Fixtures.forgetProvenance(forAppSlug: String(slug)) }

        let companionManager = CompanionManager()
        companionManager.installProvenanceStore.recordGuideSourceClone(
            appSlug: String(slug), clonePath: clonePath, pinnedCommit: nil, canonicalRepo: nil
        )
        let coordinator = companionManager.onDemandEditCoordinator
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        guard coordinator.phase == .describe else {
            Issue.record("could not reach the describe step: \(coordinator.phase)")
            return
        }

        let beforeSubmit = Test7Rendering.bar(companionManager: companionManager)

        let theReadersRequest = "make the sidebar collapsible"
        #expect(coordinator.describeRequest(theReadersRequest, kind: .feature))
        #expect(coordinator.isAssessingRequest)

        let afterSubmit = Test7Rendering.bar(companionManager: companionManager)

        // 1. The bar has to LOOK different. Anything else is the reported bug.
        #expect(
            afterSubmit.height > beforeSubmit.height,
            "the bar was \(beforeSubmit.height)pt before the send and \(afterSubmit.height)pt after it — nothing was added"
        )
        #expect(
            beforeSubmit.pixels != afterSubmit.pixels,
            "the bar drew the same pixels before and after the request was accepted"
        )

        // 2. And the reader's own sentence has to still be somewhere, because
        //    sending emptied the field it was typed into.
        #expect(coordinator.activeRequestText == theReadersRequest)
    }
}

// MARK: - 3. The stale general chat under the edit card

@MainActor
@Suite(.serialized)
struct Test7StaleChatUnderTheCardTests {

    /// A restored exchange is marked as restored, and asking anything makes it
    /// the reader's own again. This is what tells a week-old answer about
    /// installing Node apart from one the reader asked thirty seconds ago.
    @Test func aRestoredExchangeKnowsItIsNotFromThisSitting() {
        var live = OverlayEyeExchange()
        live.registerTheReaderAsked("what is on my screen")
        #expect(!live.wasRestoredFromAnEarlierSitting)

        var restored = OverlayEyeExchange()
        restored.registerTheReaderAsked("how do I install node")
        restored.registerIrisAnswered("Download the LTS installer.", theAnswerIsAFailureMessage: false)
        restored.registerTheReaderWentBackToTheField()
        restored.markAsRestoredFromAnEarlierSitting()
        #expect(restored.wasRestoredFromAnEarlierSitting)

        // Asking makes it this sitting's, so it stops being suppressible.
        restored.registerTheReaderAsked("and how do I check the version")
        #expect(!restored.wasRestoredFromAnEarlierSitting)
    }

    /// The panel manager's restore path is the one that has to stamp it — that
    /// is where a stale exchange actually comes from.
    @Test func theBarsOwnRestorePathStampsWhatItRestores() {
        let store = ChatTranscriptStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("iris-t7-transcript-\(UUID().uuidString)")
        )
        store.recordExchange(question: "how do I install node", answer: "Download the LTS installer.")

        let restored = OverlayEyeInputBarPanelManager
            .exchangeShowingTheLastThingThatWasSaid(fromTranscriptStore: store)
        #expect(restored.wasRestoredFromAnEarlierSitting)
        #expect(restored.whatIrisSaidBack == "Download the LTS installer.")
    }

    /// THE REPORTED SYMPTOM: "the chat below is linked to a general chat …
    /// super confusing."
    ///
    /// Renders the REAL bar with an edit card owning the surface, once with
    /// nothing restored and once with the last general chat restored exactly
    /// the way reopening the bar restores it. At HEAD the second was 89pt
    /// taller, because the old answer was being laid out underneath the card.
    @Test func aStaleChatIsNotDrawnUnderneathAnEditCard() async throws {
        let companionManager = CompanionManager()
        let coordinator = companionManager.onDemandEditCoordinator
        let slug = "t7-stale-\(UUID().uuidString.prefix(8))"
        coordinator.pickApp(slug: String(slug), name: "Repro App", stack: .nextjs)
        guard case .notEligible = coordinator.phase else {
            Issue.record("expected a card-owning phase; got \(coordinator.phase)")
            return
        }

        let withNothingRestored = Test7Rendering.bar(companionManager: companionManager)

        var stale = OverlayEyeExchange()
        stale.registerTheReaderAsked("how do I install node")
        stale.registerIrisAnswered(
            "Download the LTS installer from nodejs.org and run it, then check `node -v`.",
            theAnswerIsAFailureMessage: false
        )
        stale.registerTheReaderWentBackToTheField()
        stale.markAsRestoredFromAnEarlierSitting()

        let withStaleChat = Test7Rendering.bar(
            companionManager: companionManager, exchange: stale
        )

        #expect(
            withStaleChat.height == withNothingRestored.height,
            "an old general-chat answer is still being drawn under the edit card: \(withNothingRestored.height)pt became \(withStaleChat.height)pt"
        )
    }

    /// Suppressed at RENDER time, not thrown away. With no edit card in the
    /// way, reopening the bar still continues the reader's conversation — the
    /// behaviour a previous report specifically asked for.
    @Test func theRestoredChatStillComesBackWhenNoEditCardIsInTheWay() async throws {
        let companionManager = CompanionManager()
        // No pick at all, so the coordinator sits in `.pickApp` and the card
        // draws nothing.
        #expect(companionManager.onDemandEditCoordinator.phase == .pickApp)

        let empty = Test7Rendering.bar(companionManager: companionManager)

        var restored = OverlayEyeExchange()
        restored.registerTheReaderAsked("how do I install node")
        restored.registerIrisAnswered(
            "Download the LTS installer from nodejs.org and run it, then check `node -v`.",
            theAnswerIsAFailureMessage: false
        )
        restored.registerTheReaderWentBackToTheField()
        restored.markAsRestoredFromAnEarlierSitting()

        let withChat = Test7Rendering.bar(companionManager: companionManager, exchange: restored)
        #expect(
            withChat.height > empty.height,
            "the reader's own conversation stopped coming back when the bar reopened"
        )
    }
}

// MARK: - Rendering the real views offscreen

@MainActor
enum Test7Rendering {

    struct RenderedBar {
        let height: CGFloat
        let pixels: Data?
    }

    /// The REAL input bar, laid out in a real window parked far off screen, so
    /// what is measured is what the reader would see rather than what the
    /// source suggests they would.
    static func bar(
        companionManager: CompanionManager,
        exchange: OverlayEyeExchange = OverlayEyeExchange()
    ) -> RenderedBar {
        let view = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: {},
            onTheBarShouldReleaseTheKeyboard: {},
            onTheBarShouldTakeTheKeyboardBack: {},
            onTheBarsMeasuredHeightChanged: { _ in },
            showingTheExchange: exchange
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(
            x: 0, y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: max(hostingView.fittingSize.height, 1)
        )
        let window = offscreenWindow(holding: hostingView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        hostingView.layoutSubtreeIfNeeded()
        let measuredHeight = hostingView.fittingSize.height
        var pixels: Data?
        if let representation = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
            pixels = representation.representation(using: .png, properties: [:])
        }
        window.orderOut(nil)
        return RenderedBar(height: measuredHeight, pixels: pixels)
    }

    /// The REAL overlay, cropped to the square the eye lives in — the rest of a
    /// full-screen overlay is transparent and would drown the comparison in
    /// identical nothing.
    static func eyePixels(companionManager: CompanionManager, screenFrame: CGRect) -> Data? {
        let view = BlueCursorView(
            screenFrame: screenFrame,
            isFirstAppearance: false,
            companionManager: companionManager
        )
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(origin: .zero, size: screenFrame.size)
        let window = offscreenWindow(holding: hostingView)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hostingView.layoutSubtreeIfNeeded()

        let eyeSquare = NSRect(x: 0, y: 0, width: 160, height: 160)
        defer { window.orderOut(nil) }
        guard let representation = hostingView.bitmapImageRepForCachingDisplay(in: eyeSquare) else {
            return nil
        }
        hostingView.cacheDisplay(in: eyeSquare, to: representation)
        return representation.representation(using: .png, properties: [:])
    }

    private static func offscreenWindow(holding hostingView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(
                x: -30000, y: -30000,
                width: max(hostingView.frame.width, 1),
                height: max(hostingView.frame.height, 1)
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hostingView
        window.orderFront(nil)
        return window
    }
}

// MARK: - Fixtures

@MainActor
enum Test7Fixtures {

    /// A real git clone, clean, inside $HOME, with a build recipe Iris can
    /// resolve — everything the eligibility gate demands so the describe step
    /// is actually reachable.
    static func makeCleanSourceCloneInsideHome() throws -> String {
        let repositoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/iris-test7-repro", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        let repositoryPath = repositoryURL.path
        try "{\"name\":\"repro-app\",\"version\":\"1.0.0\",\"private\":true,"
            .appending("\"scripts\":{\"build\":\"true\",\"test\":\"true\"}}\n")
            .write(toFile: repositoryPath + "/package.json", atomically: true, encoding: .utf8)
        try "console.log('hello')\n"
            .write(toFile: repositoryPath + "/index.js", atomically: true, encoding: .utf8)
        git(["init", "-q"], in: repositoryPath)
        git(["config", "user.email", "repro@example.invalid"], in: repositoryPath)
        git(["config", "user.name", "repro"], in: repositoryPath)
        git(["add", "-A"], in: repositoryPath)
        git(["commit", "-qm", "base"], in: repositoryPath)
        return repositoryPath
    }

    static func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The test host shares `UserDefaults.standard` with the real app, so the
    /// fake install a test records has to be taken back out again.
    static func forgetProvenance(forAppSlug appSlug: String) {
        let defaultsKey = "iris:maintain:install-provenance"
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var recordsByAppSlug = try? JSONDecoder()
                  .decode([String: RecordedInstallProvenance].self, from: data) else { return }
        recordsByAppSlug.removeValue(forKey: appSlug)
        if let reencoded = try? JSONEncoder().encode(recordsByAppSlug) {
            UserDefaults.standard.set(reencoded, forKey: defaultsKey)
        }
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
