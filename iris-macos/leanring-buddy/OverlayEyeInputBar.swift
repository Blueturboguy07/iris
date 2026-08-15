//
//  OverlayEyeInputBar.swift
//  leanring-buddy
//
//  The bar that appears under the eye when the eye is clicked, and the whole
//  conversation that happens inside it: the question, the working state, the
//  answer, and the next question.
//
//  WHY THE WHOLE EXCHANGE LIVES HERE. This bar used to take a question and then
//  open the menu bar panel to show the answer, which meant one conversation
//  spread across two windows: a lovely minimal bar that threw you somewhere else
//  the moment you actually used it. The eye is the interface. Clicking it opens
//  the bar, asking keeps you in the bar, and the answer arrives in the bar. The
//  menu bar panel is settings now — account, permissions, model, apps, quit —
//  and the gear beside the bar is the way to it.
//
//  WHY THIS IS ITS OWN WINDOW RATHER THAN PART OF THE OVERLAY. The overlay is
//  a full-screen, click-through, never-key window — deliberately so, because
//  everything the user clicks has to pass straight through it, and because it
//  must never take keyboard focus away from the app they are working in. A
//  text field needs the exact opposite of both. Putting the bar in its own
//  small `.nonactivatingPanel` gets both properties without compromising the
//  overlay: the panel is only as large as itself, so there is no click-through
//  question to answer, and a non-activating panel can become key *without
//  activating Iris*, so the user's app stays frontmost.
//
//  THE CLICK-THROUGH GUARANTEE IS UNAFFECTED BY THE BAR GROWING. The overlay's
//  mouse gate (`OverlayWindowMouseEventGate`) opens over the eye's 76pt square
//  and nowhere else, in every state of this bar. The bar's own clicks, scrolls
//  and selections never travel through the overlay at all — they are delivered
//  to this panel, which is a real window of its own. So when an answer makes the
//  bar taller, the interactive surface grows because the *panel* grew, and the
//  overlay stays click-through over every pixel of it. `OverlayEyeInteraction`
//  models both rectangles and `IrisEyeTests` pins the pair down together.
//
//  WHO HOLDS THE KEYBOARD, AND WHEN. The panel can become key, because a text
//  field in a window that cannot be key never sees a keystroke. But a panel that
//  *stays* key after the question has been sent goes on swallowing keystrokes
//  meant for the app the reader went back to — during an earlier verification
//  pass the literal characters the user typed into their own editor landed in
//  this bar. So key status is held only while a question is being composed, and
//  handed straight back on send. See `releaseTheKeyboardSoTheReadersOwnAppGetsItBack`.
//

import AppKit
import SwiftUI

// MARK: - The panel

/// An `NSPanel` that may become key *while the bar asks to be*.
///
/// `.nonactivatingPanel` on its own gets mouse events without activating the
/// app but leaves `canBecomeKey` false for a borderless panel, and a text field
/// in a window that cannot be key never sees a keystroke. So this overrides it
/// — but as a switch rather than a constant, because the bar gives the keyboard
/// back the moment the reader stops composing, and a window that is still
/// *eligible* to be key can be handed the keyboard again by AppKit or by a
/// stray click without the bar ever asking for it.
private final class OverlayEyeInputBarPanel: NSPanel {

    /// Flipped off when the bar releases the keyboard and on again when the
    /// reader clicks back into the field.
    var theBarIsAskingForTheKeyboard: Bool = true

    override var canBecomeKey: Bool { theBarIsAskingForTheKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Owns the input bar's window: shows it under the eye, grows and shrinks it as
/// the exchange inside it changes, moves keyboard focus in and out of it, and
/// dismisses it on a click anywhere else, telling the overlay when it has gone
/// so the gear can turn back into an eye.
///
/// One of these exists per screen overlay, created by `OverlayWindowManager`
/// alongside the window it belongs to.
@MainActor
final class OverlayEyeInputBarPanelManager {

    private var inputBarPanel: OverlayEyeInputBarPanel?
    private var clickOutsideMonitor: Any?

    /// Kept from the moment the bar is shown so the panel can be re-placed when
    /// its height changes: the bar hangs from the eye, so growing it downward
    /// means recomputing its origin against the same eye and the same screen it
    /// was originally hung from.
    private var interactionGeometryTheBarHangsFrom: OverlayEyeInteractionGeometry?
    private var frameOfTheScreenTheBarIsOn: CGRect?

    /// Told to the overlay whenever the bar goes away for any reason, so the
    /// eye's activation state and the bar's actual visibility cannot drift
    /// apart.
    private var notifyTheOverlayThatTheBarClosed: (() -> Void)?

    /// Answers "should the bar stay put right now?" — true while a guide is
    /// being followed, so a stray click or the pointer leaving the bar cannot
    /// tear down a running install. Set when the bar is shown.
    private var theBarShouldStayPinned: () -> Bool = { false }

    init() {}

    var isShowingTheInputBar: Bool {
        inputBarPanel?.isVisible == true
    }

    /// The bar's window frame right now, or nil when the bar is not on screen.
    /// This is the region that can actually receive a click or a scroll, which
    /// is why it is readable from outside.
    var frameOfTheBarOnScreen: CGRect? {
        guard let inputBarPanel, inputBarPanel.isVisible else { return nil }
        return inputBarPanel.frame
    }

    /// Whether the bar is currently claiming the keyboard. Readable so the
    /// transitions below can be asserted rather than only described.
    var theBarIsAskingForTheKeyboard: Bool {
        inputBarPanel?.theBarIsAskingForTheKeyboard ?? false
    }

    /// Whether AppKit would let the bar's window take the keyboard at all. This
    /// is the property that actually stops the reader's keystrokes landing here
    /// while they are reading an answer.
    var theBarsWindowCouldBecomeKeyRightNow: Bool {
        inputBarPanel?.canBecomeKey ?? false
    }

    /// Puts the bar on screen directly under the eye.
    func showInputBar(
        forEyeAtInteractionGeometry interactionGeometry: OverlayEyeInteractionGeometry,
        onScreenWithFrame screenFrame: CGRect,
        companionManager: CompanionManager,
        onTheBarClosing: @escaping () -> Void
    ) {
        notifyTheOverlayThatTheBarClosed = onTheBarClosing
        interactionGeometryTheBarHangsFrom = interactionGeometry
        frameOfTheScreenTheBarIsOn = screenFrame
        theBarShouldStayPinned = { [weak companionManager] in
            companionManager?.guideSessionController.isActivelyGuiding == true
        }

        // A brand new view every time, which is what makes "dismissing clears
        // the exchange" true without anything having to remember to clear it:
        // the exchange lives in this view's state and the view does not outlive
        // the bar.
        let inputBarView = OverlayEyeInputBarView(
            companionManager: companionManager,
            guideSessionController: companionManager.guideSessionController,
            onDismissRequested: { [weak self] in
                self?.hideInputBar()
            },
            onTheBarShouldReleaseTheKeyboard: { [weak self] in
                self?.releaseTheKeyboardSoTheReadersOwnAppGetsItBack()
            },
            onTheBarShouldTakeTheKeyboardBack: { [weak self] in
                self?.takeTheKeyboardBackForTheTextField()
            },
            onTheBarsMeasuredHeightChanged: { [weak self] measuredHeight in
                self?.resizeTheBarToFit(measuredContentHeight: measuredHeight)
            }
        )
        .frame(width: OverlayEyeInteractionGeometry.inputBarWidth)

        let hostingView = NSHostingView(rootView: inputBarView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: hostingView.fittingSize.height
        )
        // The panel is resized from underneath as the exchange changes, so the
        // hosting view has to follow it rather than staying at its first size.
        hostingView.autoresizingMask = [.width, .height]

        let panel = OverlayEyeInputBarPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // The same level as the overlay it hangs from, so the bar and the eye
        // stay together above everything else on the desktop.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        let barSize = CGSize(
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(
                forMeasuredContentHeight: hostingView.fittingSize.height
            )
        )
        panel.setContentSize(barSize)
        panel.setFrameOrigin(interactionGeometry.inputBarOriginInAppKitScreenCoordinates(
            barSize: barSize,
            onScreenWithFrame: screenFrame
        ))

        inputBarPanel = panel
        panel.makeKeyAndOrderFront(nil)
        installClickOutsideMonitor()
    }

    /// Takes the bar down and hands keyboard focus back to whatever had it.
    func hideInputBar() {
        removeClickOutsideMonitor()
        interactionGeometryTheBarHangsFrom = nil
        frameOfTheScreenTheBarIsOn = nil

        if let inputBarPanel {
            // `orderOut` is what returns key status to the previously key
            // window. Hiding the panel any other way would leave Iris holding
            // the keyboard with nothing focused to receive it.
            inputBarPanel.theBarIsAskingForTheKeyboard = false
            inputBarPanel.orderOut(nil)
            inputBarPanel.contentView = nil
            self.inputBarPanel = nil
        }

        let closeCallback = notifyTheOverlayThatTheBarClosed
        notifyTheOverlayThatTheBarClosed = nil
        closeCallback?()
    }

    // MARK: Growing and shrinking

    /// Re-sizes the bar's window around the height its content just reported,
    /// keeping its top edge pinned under the eye so the bar grows downward into
    /// empty desktop rather than sliding up over the eye it hangs from.
    ///
    /// This is also what keeps the reader able to *use* a long answer: the bar
    /// is its own window, so the region that accepts a scroll or a drag-select
    /// is exactly this frame. If the frame did not grow with the content, the
    /// answer would render outside the window and be both clipped and dead to
    /// the mouse.
    /// Internal rather than private so the growth and the shrink can be
    /// asserted against a real window rather than only reasoned about.
    func resizeTheBarToFit(measuredContentHeight: CGFloat) {
        guard let inputBarPanel,
              let interactionGeometryTheBarHangsFrom,
              let frameOfTheScreenTheBarIsOn else { return }

        let heightToUse = OverlayEyeInteractionGeometry.heightTheInputBarMayActuallyUse(
            forMeasuredContentHeight: measuredContentHeight
        )
        // Sub-point differences are layout noise, and acting on them would move
        // the window sixty times a second while SwiftUI settles.
        guard abs(inputBarPanel.frame.height - heightToUse) > 0.5 else { return }

        let barSize = CGSize(
            width: OverlayEyeInteractionGeometry.inputBarWidth,
            height: heightToUse
        )
        let barOrigin = interactionGeometryTheBarHangsFrom.inputBarOriginInAppKitScreenCoordinates(
            barSize: barSize,
            onScreenWithFrame: frameOfTheScreenTheBarIsOn
        )
        inputBarPanel.setFrame(CGRect(origin: barOrigin, size: barSize), display: true)
    }

    // MARK: Who holds the keyboard

    /// Hands the keyboard back to the app the reader is really working in,
    /// without taking the bar off the screen.
    ///
    /// Called the instant a question is sent. From then until they click back
    /// into the field, everything they type goes to their own app — they are
    /// reading an answer, not talking to Iris, and a floating panel that keeps
    /// eating keystrokes while they read is a bug they cannot see the cause of.
    ///
    /// Three steps, because no single one of them is sufficient:
    ///   1. drop the first responder, so the text field stops editing;
    ///   2. stop being *eligible* for key, so nothing hands it back by accident;
    ///   3. give up active status, which is the thing that actually moves the
    ///      keyboard to the other app. `orderOut` would do it too, but that
    ///      would take the answer off the screen, which is the one thing this
    ///      must not do.
    func releaseTheKeyboardSoTheReadersOwnAppGetsItBack() {
        guard let inputBarPanel else { return }

        inputBarPanel.makeFirstResponder(nil)
        inputBarPanel.theBarIsAskingForTheKeyboard = false

        guard inputBarPanel.isKeyWindow else { return }
        NSApp.deactivate()

        // The safety net. If the panel is somehow still key on the next runloop
        // turn, take the keyboard off it the one way that always works. It is
        // now ineligible for key, so ordering it back in front cannot re-take
        // the keyboard, and both calls happen inside a single turn so the bar
        // does not visibly blink.
        DispatchQueue.main.async { [weak self] in
            guard let stillOpenPanel = self?.inputBarPanel, stillOpenPanel.isKeyWindow else { return }
            stillOpenPanel.orderOut(nil)
            stillOpenPanel.orderFront(nil)
        }
    }

    /// Gives the bar the keyboard back because the reader clicked into the
    /// field to ask something else.
    func takeTheKeyboardBackForTheTextField() {
        guard let inputBarPanel else { return }
        inputBarPanel.theBarIsAskingForTheKeyboard = true
        inputBarPanel.makeKeyAndOrderFront(nil)
    }

    // MARK: Click outside

    /// A click in any other application dismisses the bar. Clicks on the eye
    /// itself are not seen here — a global monitor only reports events headed
    /// for *other* apps — which is exactly right, because clicking the gear
    /// must open settings without closing the bar behind it.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }

            // A click *inside* the bar is not a click outside it. This guard
            // exists because the bar deliberately gives up active status while
            // the reader reads an answer, and a global monitor can see a click
            // land on a window belonging to an app that is not active. Without
            // it, clicking into the field to ask a follow-up would dismiss the
            // very bar the reader was trying to type into.
            if let frameOfTheBarOnScreen = self.frameOfTheBarOnScreen,
               frameOfTheBarOnScreen.contains(NSEvent.mouseLocation) {
                return
            }

            // While a guide is being followed, a click anywhere else must not
            // tear the bar down — the reader is mid-install and needs the
            // steps to stay put. They dismiss it with the × or End guide.
            if self.theBarShouldStayPinned() {
                return
            }

            self.hideInputBar()
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}

// MARK: - Measuring the bar

/// The height of the bar's whole content, reported up to the panel manager so
/// the window can be re-sized around it.
private struct OverlayEyeInputBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// The height the answer's text *wants*, which is not the height it gets: past
/// `tallestTheAnswerAreaMayGrow` the answer scrolls instead.
private struct OverlayEyeAnswerTextHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - The bar itself

/// One field and, under it, whichever of three things the exchange is up to:
/// the suggestion chips before anything has been asked, the working line while
/// Iris is answering, or the answer itself.
///
/// There is no header and no border around the whole thing on purpose: the bar
/// is an attachment to the eye, and a frame around it would make it the second
/// panel this change exists to remove.
struct OverlayEyeInputBarView: View {

    @ObservedObject var companionManager: CompanionManager

    /// Observed separately from the companion manager because the guide is its
    /// own object, and the suggestions have to follow the step the reader is
    /// actually on rather than the step they were on when the bar opened.
    @ObservedObject var guideSessionController: GuideSessionController

    let onDismissRequested: () -> Void

    /// Called on send. See `releaseTheKeyboardSoTheReadersOwnAppGetsItBack` —
    /// this is the moment the reader's own app gets its keystrokes back.
    let onTheBarShouldReleaseTheKeyboard: () -> Void

    /// Called when the reader clicks back into the field to ask a follow-up.
    let onTheBarShouldTakeTheKeyboardBack: () -> Void

    /// Called whenever the bar's content changes height, so the window it lives
    /// in can grow and shrink with it.
    let onTheBarsMeasuredHeightChanged: (CGFloat) -> Void

    @State private var typedMessage: String = ""

    /// The one question-and-answer the bar is showing. All the rules about what
    /// follows what live in `OverlayEyeExchange`, which is a plain value and is
    /// tested without a window.
    @State private var exchange = OverlayEyeExchange()

    /// How tall the answer's text would like to be. Used to size the scrolling
    /// area to the answer when the answer is short, and to cap it when it is
    /// not — a `ScrollView` has no natural height of its own, so without this
    /// the bar would either collapse or always be as tall as its ceiling.
    @State private var measuredAnswerTextHeight: CGFloat = 0

    @FocusState private var theTextFieldHasKeyboardFocus: Bool

    /// The `exchange` seed exists so the bar's four states can be rendered and
    /// looked at without a live model round-trip. Nothing in the app passes it:
    /// a real bar always opens empty and fills up as the reader uses it.
    init(
        companionManager: CompanionManager,
        guideSessionController: GuideSessionController,
        onDismissRequested: @escaping () -> Void,
        onTheBarShouldReleaseTheKeyboard: @escaping () -> Void,
        onTheBarShouldTakeTheKeyboardBack: @escaping () -> Void,
        onTheBarsMeasuredHeightChanged: @escaping (CGFloat) -> Void,
        showingTheExchange exchange: OverlayEyeExchange = OverlayEyeExchange()
    ) {
        self.companionManager = companionManager
        self.guideSessionController = guideSessionController
        self.onDismissRequested = onDismissRequested
        self.onTheBarShouldReleaseTheKeyboard = onTheBarShouldReleaseTheKeyboard
        self.onTheBarShouldTakeTheKeyboardBack = onTheBarShouldTakeTheKeyboardBack
        self.onTheBarsMeasuredHeightChanged = onTheBarsMeasuredHeightChanged
        _exchange = State(initialValue: exchange)
    }

    private var suggestionsToOffer: [String] {
        OverlayEyeSuggestions.suggestions(
            forOpenGuideStepTitled: guideSessionController.stepTheReaderIsLookingAt?.title
        )
    }

    private var thereIsSomethingToSend: Bool {
        !typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True while the centered takeover window is covering the screen with a
    /// running install. The corner guide card + Ask-Iris field are hidden in that
    /// case so they are not a cluttered second copy of the same guide. Gated on
    /// "not yet finished" as well: the takeover flag lingers true until the guide
    /// is closed, so this flips back to false the instant the install finishes —
    /// which brings the completion card back — and, because the flag itself is
    /// still true then, the under-the-card terminal pane stays suppressed and
    /// cannot flash in.
    private var theCenteredTakeoverIsCoveringTheScreen: Bool {
        guideSessionController.autopilotIsShownAsTakeover
            && !guideSessionController.readerHasFinishedTheGuide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if theCenteredTakeoverIsCoveringTheScreen {
                // While the centered takeover is running the install, the corner
                // guide card AND the Ask-Iris field would be a cluttered second
                // copy of the same guide over the desktop. Show nothing here so
                // the takeover is the only surface. The outer VStack has no
                // background of its own (each piece below carries its own glass),
                // so an empty body collapses the bar panel to nothing rather than
                // leaving an empty glass square. Everything returns the moment the
                // install finishes (the completion card) or the takeover is torn
                // down — see `theCenteredTakeoverIsCoveringTheScreen`.
                EmptyView()
            } else {
                // A maintain-mode ask outranks everything else in the bar: the
                // reader's app just crashed, and this is the card the whole
                // feature exists to show. It renders above the guide card and
                // the field, and observes the coordinator itself so it appears
                // and clears without the bar being rebuilt.
                MaintainAskCard(coordinator: companionManager.maintainIncidentCoordinator)

                // The guide sits above the field, not inside the settings dropdown.
                // The reader following instructions is doing the main thing Iris is
                // for; asking a question about the step is the secondary thing, and
                // it stays available underneath rather than replacing it.
                if let guidePresentation {
                    OverlayEyeGuideCard(
                        presentation: guidePresentation,
                        onPrimaryAction: { guideSessionController.performPrimaryAction() },
                        onSecondaryAction: { guideSessionController.advanceToTheNextStep() },
                        onBack: { guideSessionController.returnToThePreviousStep() },
                        onClose: { guideSessionController.closeTheGuide() },
                        copyConfirmationText: guideSessionController.transientCopyConfirmationText
                    )
                    // No divider: the card carries its own backdrop, so it already
                    // reads as a separate surface from the field below it. A rule
                    // between two pieces of glass would be a line floating on the
                    // desktop with nothing behind it.

                    // The one gesture that hands the install to Iris. It is the
                    // only path to execution, which is the whole consent story.
                    if guideSessionController.canOfferAutopilot {
                        Button("Let Iris run it", action: { guideSessionController.startAutopilot() })
                            .irisPrimaryPill(isFullWidth: true, isCompact: true)
                    }

                    // While Iris is running the install, the terminal it runs it in
                    // is shown in the centered takeover window (the eye morphs into
                    // it). This under-the-card pane is only the fallback for when
                    // the takeover is not up — never draw the terminal in both.
                    if let runner = guideSessionController.autopilotRunner,
                       !guideSessionController.autopilotIsShownAsTakeover {
                        GuideAutopilotTerminalView(
                            runner: runner,
                            onApproveRiskyCommand: { guideSessionController.approveThePendingRiskyCommand() },
                            onSkipRiskyCommand: { guideSessionController.skipThePendingRiskyCommand() },
                            onRetrySurfacedStep: { guideSessionController.retryTheSurfacedStep() },
                            onContinuePastSurfacedStep: { guideSessionController.skipTheSurfacedStepAndContinue() },
                            onEscapeHatch: { guideSessionController.abortOrCloseAutopilotFromTheEscapeHatch() },
                            // This pane's container (the bar) grows to fit its
                            // content, so the transcript needs its own bound to
                            // scroll inside instead of growing past the clamp.
                            fixedTranscriptHeight: 260
                        )
                    }
                }

                textFieldRow
                whateverTheExchangeIsUpTo
            }
        }
        // The bar is dismissed the way every transient input on macOS is. This
        // only fires while the bar holds the keyboard — which is while a
        // question is being composed. Once the keyboard has gone back to the
        // reader's own app, Escape belongs to that app, and the close button
        // and a click outside are how the bar goes away.
        .onKeyPress(.escape) {
            onDismissRequested()
            return .handled
        }
        .background(
            GeometryReader { barGeometry in
                Color.clear.preference(
                    key: OverlayEyeInputBarHeightPreferenceKey.self,
                    value: barGeometry.size.height
                )
            }
        )
        .onPreferenceChange(OverlayEyeInputBarHeightPreferenceKey.self) { measuredHeight in
            onTheBarsMeasuredHeightChanged(measuredHeight)
        }
        .onAppear {
            // The panel has to be key before the field can take focus, and it
            // becomes key one runloop turn after it is ordered front.
            DispatchQueue.main.async {
                theTextFieldHasKeyboardFocus = true
            }
        }
        // The one signal that an answer has landed. It is a counter rather than
        // the text itself because asking the same question twice produces the
        // same words, and the bar would sit on "working…" forever waiting for
        // text that never changed.
        .onChange(of: companionManager.assistantResponseGenerationCount) { _, _ in
            showWhateverIrisJustSaid()
        }
        .animation(DS.Motion.contentIn, value: exchange.phase)
    }

    /// What the guide card should show, or nil when no guide is open.
    ///
    /// Read off the controller rather than mirrored into local state: the watch
    /// loop advances steps without anybody pressing anything, and a copy here
    /// would go stale exactly when the feature is working.
    private var guidePresentation: OverlayEyeGuideStepPresentation? {
        guard
            guideSessionController.loadState.isShowingSomethingAboutAGuide,
            let guide = guideSessionController.guideBeingFollowed,
            let step = guideSessionController.stepTheReaderIsLookingAt,
            let branch = guideSessionController.selectedBranch
        else {
            return nil
        }

        let totalSteps = branch.steps.count
        let stepNumber = guideSessionController.currentStepIndex + 1
        let readerIsOnARealStep = totalSteps > 0 && guideSessionController.currentStepIndex < totalSteps

        return OverlayEyeGuideStepPresentation(
            appName: guide.appName,
            stepTitle: step.title,
            stepBody: step.body,
            command: step.command,
            progressLabel: readerIsOnARealStep ? "\(stepNumber) of \(totalSteps)" : nil,
            progressFraction: totalSteps > 0 ? min(1, Double(stepNumber) / Double(totalSteps)) : 0,
            completionHint: step.verifierLabel,
            pointingNote: OverlayEyeGuidePointingNote.note(for: guideSessionController.pointingDecisionForTheOpenStep),
            readerCanGoBack: guideSessionController.currentStepIndex > 0,
            isTheLastStep: readerIsOnARealStep && stepNumber == totalSteps
        )
    }

    // MARK: The field

    private var textFieldRow: some View {
        HStack(spacing: 8) {
            TextField(fieldPlaceholder, text: $typedMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.ink)
                .focused($theTextFieldHasKeyboardFocus)
                .onSubmit {
                    sendWhatIsTyped()
                }
                .overlay(IBeamCursorView())
                // WHY AN INVISIBLE PLATE OVER THE FIELD. While the answer is
                // being read the bar has given the keyboard back, so its window
                // is not key and the text field cannot take a click and start
                // editing on its own. This plate turns that click into "ask for
                // the keyboard back, then put the caret in the field". It only
                // exists in that state, so it never sits between the reader and
                // a field they can already type in.
                .overlay {
                    if exchange.phase == .showingTheAnswer {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                startWritingAFollowUp()
                            }
                    }
                }

            closeButton

            Button {
                sendWhatIsTyped()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(thereIsSomethingToSend ? DS.Colors.accent : DS.Colors.quiet)
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: thereIsSomethingToSend)
            .disabled(!thereIsSomethingToSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(IrisShellBackground(cornerRadius: DS.CornerRadius.extraLarge))
    }

    /// "Ask Iris…" the first time and "Ask something else…" afterwards, because
    /// the second time round the interesting thing about the field is that it
    /// is still there and still usable without reopening anything.
    private var fieldPlaceholder: String {
        exchange.thereIsAnExchangeOnScreen ? "Ask something else…" : "Ask Iris…"
    }

    /// The visible way out. Escape covers the reader who is still typing; this
    /// covers the far commoner case of somebody who has finished reading and
    /// wants their screen back, at which point the keyboard is not even pointed
    /// at the bar any more.
    private var closeButton: some View {
        Button {
            onDismissRequested()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(DS.Colors.quiet)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Close")
    }

    // MARK: What is under the field

    @ViewBuilder
    private var whateverTheExchangeIsUpTo: some View {
        if exchange.theSuggestionChipsShouldBeOffered {
            suggestionChips
        } else {
            exchangeCard
        }
    }

    /// Stacked rather than laid out in a row: a row of chips either overflows a
    /// 320pt bar or has to be truncated to fit it, and a suggestion the reader
    /// cannot finish reading is not a suggestion.
    ///
    /// Each chip carries its own glass shell rather than sharing one card. A
    /// card would be the panel chrome this bar is meant not to have — but pale
    /// text with nothing behind it is illegible the moment the desktop under it
    /// is bright, so the backdrop goes on the chips themselves.
    private var suggestionChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(suggestionsToOffer, id: \.self) { suggestion in
                Button {
                    send(suggestion)
                } label: {
                    Text(suggestion)
                        .lineLimit(1)
                }
                .irisTinyButton()
                .background(IrisShellBackground(cornerRadius: DS.CornerRadius.small))
            }
        }
        .padding(.leading, 4)
    }

    /// The question and what came back from it, in one card that changes what
    /// it holds rather than being replaced by a different surface.
    private var exchangeCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let questionTheReaderAsked = exchange.questionTheReaderAsked {
                Text(questionTheReaderAsked)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.quiet)
                    // The question is context for the answer, not the answer.
                    // Two lines is enough to recognise what you asked; more
                    // would push the thing you are waiting for down the screen.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let whatIrisSaidBack = exchange.whatIrisSaidBack {
                answerArea(showing: whatIrisSaidBack)
            } else {
                workingLine
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IrisShellBackground(cornerRadius: DS.CornerRadius.large))
    }

    /// The spinner and the sentence saying which part of the work is happening.
    /// Both are driven by the same `assistantState` that spins the eye's own
    /// track, so a spinning eye and an idle-looking bar cannot happen.
    private var workingLine: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 13, height: 13)

            Text(OverlayEyeSuggestions.lineShownWhileIrisIsWorking(
                whileTheAssistantIs: companionManager.assistantState
            ))
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The answer, wrapped, and scrolling once it is longer than the bar is
    /// allowed to be.
    ///
    /// A failure sentence renders here too, in the same place, because from the
    /// reader's side "Iris could not answer" is what came back from what they
    /// asked. Only the colour differs.
    private func answerArea(showing answerText: String) -> some View {
        ScrollView(.vertical) {
            Text(answerText)
                .font(.system(size: 12.5))
                .foregroundColor(
                    exchange.whatIrisSaidBackIsAFailureMessage ? DS.Colors.red : DS.Colors.ink
                )
                .lineSpacing(2.5)
                // Wrap rather than truncate: an answer the reader cannot finish
                // reading is not an answer.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { answerTextGeometry in
                        Color.clear.preference(
                            key: OverlayEyeAnswerTextHeightPreferenceKey.self,
                            value: answerTextGeometry.size.height
                        )
                    }
                )
        }
        .frame(height: heightTheAnswerAreaShouldBe)
        .onPreferenceChange(OverlayEyeAnswerTextHeightPreferenceKey.self) { measuredHeight in
            measuredAnswerTextHeight = measuredHeight
        }
    }

    /// As tall as the answer for a short answer, capped for a long one. The cap
    /// is what stops this floating bar from becoming a wall across the screen
    /// the reader is trying to work on.
    private var heightTheAnswerAreaShouldBe: CGFloat {
        let shortestAnswerAreaWorthDrawing: CGFloat = 17
        return min(
            max(measuredAnswerTextHeight, shortestAnswerAreaWorthDrawing),
            OverlayEyeInteractionGeometry.tallestTheAnswerAreaMayGrow
        )
    }

    // MARK: Driving the exchange

    private func sendWhatIsTyped() {
        guard thereIsSomethingToSend else { return }
        send(typedMessage)
    }

    /// Everything the bar sends goes through `sendUserMessage` — the one
    /// pipeline the panel's own input already used — so there is no second
    /// route to Claude to keep in step with the first.
    ///
    /// NOTHING IS POSTED TO THE MENU BAR PANEL HERE. That hand-off is the bug
    /// this file exists to fix: a question asked at the eye is answered at the
    /// eye, a few lines below where it was typed.
    private func send(_ messageText: String) {
        companionManager.sendUserMessage(messageText)
        exchange.registerTheReaderAsked(messageText)
        typedMessage = ""
        measuredAnswerTextHeight = 0

        // The reader has stopped talking to Iris and gone back to whatever they
        // were doing. Their keystrokes go with them.
        theTextFieldHasKeyboardFocus = false
        onTheBarShouldReleaseTheKeyboard()
    }

    private func showWhateverIrisJustSaid() {
        guard let latestAssistantResponseText = companionManager.latestAssistantResponseText else {
            return
        }
        exchange.registerIrisAnswered(
            latestAssistantResponseText,
            theAnswerIsAFailureMessage: companionManager.latestResponseWasAFailureMessage
        )
    }

    /// The reader clicked back into the field after an answer. The answer stays
    /// on screen while they write — it is the thing they are following up on.
    private func startWritingAFollowUp() {
        exchange.registerTheReaderWentBackToTheField()
        onTheBarShouldTakeTheKeyboardBack()
        // The panel becomes key one runloop turn after it is asked to, and a
        // field cannot take focus in a window that is not key yet.
        DispatchQueue.main.async {
            theTextFieldHasKeyboardFocus = true
        }
    }
}
