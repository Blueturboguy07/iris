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

        // A brand new view every time — but no longer a brand new CONVERSATION.
        //
        // The exchange still lives in this view's state, and the view still does
        // not outlive the bar. What changed is where the view starts from: the
        // reader's chat is now kept on disk (`ChatTranscriptStore`), so a bar
        // that opens after a dismissal — or after Iris was quit and started
        // again — opens showing the last thing that was said instead of the
        // suggestion chips. Reopening continues the conversation rather than
        // pretending nothing was ever asked, which is the reported bug: "when I
        // click off Iris it just gets rid of my chat and opens a brand new one".
        //
        // It is still ONE exchange. This is a bar hanging off a 64pt eye, not a
        // second chat window: the most recent exchange comes back and nothing
        // else does.
        let exchangeToReopenWith = Self.exchangeShowingTheLastThingThatWasSaid(
            fromTranscriptStore: companionManager.chatTranscriptStore
        )

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
            },
            showingTheExchange: exchangeToReopenWith
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

    /// The exchange a freshly-opened bar should already be showing: the last
    /// thing the reader and Iris said to each other, or the empty opening state
    /// when they have never spoken.
    ///
    /// WHY IT LANDS IN `.composingAFollowUp` RATHER THAN `.showingTheAnswer`.
    /// Those two phases show the same thing — the question and the answer — but
    /// they disagree about the keyboard, and the bar has just been made key with
    /// the field about to take focus. `.composingAFollowUp` is the phase that
    /// means "the answer is still up and the reader is writing the next
    /// question", which is exactly what reopening the bar is, so
    /// `theBarShouldHoldTheKeyboard` agrees with what the window is actually
    /// doing. Landing in `.showingTheAnswer` would claim the bar had given the
    /// keyboard back while it was holding it.
    ///
    /// The restored answer is never a failure sentence: `CompanionManager` only
    /// records an exchange on the success path, so nothing that failed is ever
    /// in the transcript to come back.
    static func exchangeShowingTheLastThingThatWasSaid(
        fromTranscriptStore chatTranscriptStore: ChatTranscriptStore
    ) -> OverlayEyeExchange {
        var exchange = OverlayEyeExchange()
        guard let lastSavedExchange = chatTranscriptStore.mostRecentExchange else {
            return exchange
        }

        // Replayed through the same three transitions a live exchange goes
        // through, rather than assembled field by field, so a restored bar can
        // never be in a state a real conversation could not have reached.
        exchange.registerTheReaderAsked(lastSavedExchange.question)
        exchange.registerIrisAnswered(
            lastSavedExchange.answer,
            theAnswerIsAFailureMessage: false
        )
        exchange.registerTheReaderWentBackToTheField()
        // Marked LAST, because `registerTheReaderAsked` above deliberately
        // clears the flag — asking is what makes an exchange this sitting's.
        // Replaying the transitions and then stamping the result is what keeps
        // both facts true: it is a state a real conversation could have
        // reached, and it did not happen just now.
        exchange.markAsRestoredFromAnEarlierSitting()
        return exchange
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

    /// What the last query cost, when the reader is the one being billed for it.
    @ObservedObject var spendLedger: AssistantSpendLedger

    /// Observed separately from the companion manager because the guide is its
    /// own object, and the suggestions have to follow the step the reader is
    /// actually on rather than the step they were on when the bar opened.
    @ObservedObject var guideSessionController: GuideSessionController

    /// Observed directly, not read through the manager, because the bar
    /// RESTRUCTURES on its phase: while an app is waiting to be described the
    /// bar is one composer, and every other phase hands the surface to the
    /// card. A value read off a non-observed object would leave the bar drawing
    /// the wrong shape until something else happened to redraw it.
    @ObservedObject var onDemandEditCoordinator: OnDemandEditCoordinator

    /// Observed so the footer's statement of what answers a question follows a
    /// sign-in or a pasted key without waiting for something else to redraw.
    @ObservedObject var accountService: AccountService

    let onDismissRequested: () -> Void

    /// Called on send. See `releaseTheKeyboardSoTheReadersOwnAppGetsItBack` —
    /// this is the moment the reader's own app gets its keystrokes back.
    let onTheBarShouldReleaseTheKeyboard: () -> Void

    /// Called when the reader clicks back into the field to ask a follow-up.
    let onTheBarShouldTakeTheKeyboardBack: () -> Void

    /// Called whenever the bar's content changes height, so the window it lives
    /// in can grow and shrink with it.
    let onTheBarsMeasuredHeightChanged: (CGFloat) -> Void

    /// Which of the two things the one field does. Only meaningful while an app
    /// is open for editing; the bar is an ask field and nothing else otherwise.
    enum ComposerMode: Equatable { case edit, ask }

    /// Editing is the default because opening an app is a deliberate act and
    /// editing it is the reason to have done it. Asking is one tap away.
    @State private var composerMode: ComposerMode = .edit

    /// The fix/feature choice, which decides the honesty label and the commit
    /// trailer, so it is a real choice and not a convenience.
    @State private var editKind: OnDemandEditKind = .bugFix

    /// Whether the past-conversation list is expanded. Collapsed by default:
    /// the bar is a small panel over someone's desktop, and history is a thing
    /// you go looking for, not a thing that should be in the way.
    @State private var historyIsShowing: Bool = false

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

    /// The `exchange` seed is how a reopened bar comes back showing the last
    /// thing that was said: `OverlayEyeInputBarPanelManager` reads it out of
    /// `ChatTranscriptStore` and passes it in, so dismissing the bar no longer
    /// throws the conversation away. It defaults to empty, which is both what a
    /// first-ever bar opens on and what lets the four states be rendered and
    /// looked at without a live model round-trip.
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
        // Derived rather than passed: both live on the manager already, and a
        // second way to supply them is a second way to supply the wrong ones.
        _onDemandEditCoordinator = ObservedObject(
            wrappedValue: companionManager.onDemandEditCoordinator
        )
        _accountService = ObservedObject(wrappedValue: companionManager.accountService)
        _spendLedger = ObservedObject(wrappedValue: companionManager.spendLedger)
        self.onDismissRequested = onDismissRequested
        self.onTheBarShouldReleaseTheKeyboard = onTheBarShouldReleaseTheKeyboard
        self.onTheBarShouldTakeTheKeyboardBack = onTheBarShouldTakeTheKeyboardBack
        self.onTheBarsMeasuredHeightChanged = onTheBarsMeasuredHeightChanged
        _exchange = State(initialValue: exchange)
    }

    private var suggestionsToOffer: [String] {
        OverlayEyeSuggestions.suggestions(
            forOpenGuideStepTitled: guideSessionController.stepTheReaderIsLookingAt?.title,
            frontmostEditableCatalogAppNamed: frontmostEditableCatalogAppName
        )
    }

    /// The name of the catalog app the reader is looking at, IF Iris may edit it
    /// locally — the signal that drives the Door-B "fix a bug in…" / "add a
    /// feature to…" chips. Nil for a non-catalog app, an app in front that is a
    /// signed download, or when no app of ours is frontmost, so the chips are
    /// never offered for something the edit flow would then refuse.
    private var frontmostEditableCatalogAppName: String? {
        let inventory = companionManager.appInventoryService
        guard let slug = inventory.frontmostCatalogAppSlug,
              let entry = inventory.installedEntriesForDisplay.first(where: { $0.slug == slug }),
              entry.isLocallyEditable else { return nil }
        return entry.name
    }

    private var thereIsSomethingToSend: Bool {
        !typedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether pressing send would actually do anything.
    ///
    /// The second half is new: while a request is being sized up,
    /// `describeRequest` restarts the probe from scratch rather than queueing a
    /// second request, so a reader who pressed Return again — which is exactly
    /// what somebody does when nothing appears to have happened — quietly threw
    /// away the work already in flight. The arrow goes grey instead, next to
    /// the row that says what Iris is doing with the first one.
    private var theSendButtonIsLive: Bool {
        thereIsSomethingToSend && !theRequestIsBeingSizedUp
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
        (guideSessionController.autopilotIsShownAsTakeover
            && !guideSessionController.readerHasFinishedTheGuide)
            // The on-demand edit run has its own terminal takeover, and while it
            // covers the screen the eye bar's content is a cluttered second copy
            // of the same run — so it, too, suppresses the bar body. The moment
            // the takeover folds away (the diff preview, a failure) the bar
            // returns and shows the edit card.
            || companionManager.onDemandEditTakeoverIsUp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if theCenteredTakeoverIsCoveringTheScreen {
                // While the centered takeover runs the install, the corner guide
                // card and the under-the-card terminal would each be a cluttered
                // second copy of what the takeover is already showing. Those stay
                // hidden.
                //
                // The ASK FIELD does not, and hiding it was a real bug: "if I
                // have a question during setup, like how to set up the api key
                // stuff, I can't chat with iris." Mid-install is exactly when a
                // reader has a question, and this was the one moment Iris could
                // not be asked one. The bar sits at `.screenSaver` and the
                // takeover panel at `.floating`, so the field draws above it.
                //
                // NEITHER DOES AN EDIT THE READER ASKED FOR, and hiding that was
                // the same bug again: "Edit this app click shows nothing." A
                // guide parked at a manual step ("Plug in your iPhone and press
                // play") keeps this flag true for as long as the reader takes,
                // and it was swallowing the whole surface of an edit on a
                // COMPLETELY DIFFERENT app — the pick landed and had nowhere to
                // appear. The card belongs to the edit, so only the edit's own
                // takeover suppresses it (see the card's own definition).
                //
                // With no edit on screen that card is an `EmptyView`, so nothing
                // else is drawn and the outer VStack still collapses to just the
                // field rather than leaving an empty glass square.
                onDemandEditCardWhenARunOwnsTheSurface
                textFieldRow
                whateverTheExchangeIsUpTo
            } else {
                // A maintain-mode ask outranks everything else in the bar: the
                // reader's app just crashed, and this is the card the whole
                // feature exists to show. It renders above the guide card and
                // the field, and observes the coordinator itself so it appears
                // and clears without the bar being rebuilt.
                MaintainAskCard(coordinator: companionManager.maintainIncidentCoordinator)

                onDemandEditCardWhenARunOwnsTheSurface

                // What Iris already did to an app this session. Without it the
                // reader who got a real result — Iris wrote and committed a
                // plan document — closed the card and had nothing left to look
                // at: "Clicked off Iris, and then back on, still can't see the
                // chat history with feature or bug overlay, so can't be sure
                // it's working."
                finishedEditsList

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

                    // Why the tap did nothing. `autopilotBlockedExplanation` was
                    // set on every refusal path and rendered by NOBODY, so a
                    // reader who declined the consent alert — or hit any of the
                    // six silent guard conditions — pressed a button that moved
                    // nothing and said nothing. That is the reported bug, and
                    // the reason it survived careful comments about not
                    // returning in silence: the silence was downstream of them.
                    if let blocked = guideSessionController.autopilotBlockedExplanation {
                        Text(blocked)
                            .font(.system(size: 10.5))
                            .foregroundColor(DS.Colors.amber)
                            .fixedSize(horizontal: false, vertical: true)
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
                historyAndNewChatRow
                chatHistoryList
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
        // A retry that re-enters the describe step with the request prefilled
        // ("Try again with what Iris learned", the rate-limit retry) lands
        // HERE, in the composer, because the composer is what draws the
        // describe step now. `OnDemandEditCard` also listens for this, but the
        // bar unmounts that card in the very update that carries the prefill —
        // it is only rendered while the phase is NOT `.describe` — so the
        // card's listener can never fire for it and the reader's own words
        // reached no text field on any surface. That is a button that looks
        // like it did nothing.
        .onChange(of: onDemandEditCoordinator.describePrefillText) { _, prefill in
            guard let prefill, !prefill.isEmpty else { return }
            typedMessage = prefill
            composerMode = .edit
            onDemandEditCoordinator.consumeDescribePrefill()
        }
        .animation(DS.Motion.contentIn, value: exchange.phase)
    }

    /// The user-initiated on-demand edit card: describe → consent →
    /// review-and-keep → result. It observes its own coordinator, so it appears
    /// the moment an app is picked (from here or the settings panel) and clears
    /// itself when the flow ends. Driven by a pending-edit coordinator, NOT the
    /// maintain ask.
    /// The describe step is drawn by the bar itself, as one composer with the
    /// ask field (see `appComposer`). Every other phase is a run in flight and
    /// the card owns the whole surface.
    ///
    /// Drawn from BOTH branches of the body, which is why it lives here rather
    /// than inline: the only takeover that makes this card a second copy of
    /// itself is the EDIT RUN'S OWN, and that is the one this checks. A guide's
    /// takeover is about a different install and must not hide it.
    @ViewBuilder
    private var onDemandEditCardWhenARunOwnsTheSurface: some View {
        if onDemandEditCoordinator.phase != .describe,
           !companionManager.onDemandEditTakeoverIsUp {
            OnDemandEditCard(
                coordinator: onDemandEditCoordinator,
                preselectedKind: companionManager.onDemandEditPreselectedKind
            )
            // WHY A PLATE UNDER A TERMINAL CARD. The card's text is
            // `.textSelection(.enabled)`, but a selection the reader
            // cannot copy is not much of a gift: this panel's
            // `canBecomeKey` is false for every phase except "a question
            // is being composed", and a window that cannot become key is
            // never sent a key event, so ⌘C has nowhere to go. (Measured:
            // SwiftUI does install an Edit menu with Copy for an
            // accessory app, so the key window is the only thing
            // missing.) Clicking a finished card asks for the keyboard
            // back, which is what makes ⌘C reach the selection.
            //
            // It is a `.background`, not an `.overlay`, so the card's own
            // buttons — Copy, "Set aside and continue", Undo — take their
            // clicks first and only the inert areas fall through here.
            //
            // GATED HARD, on purpose. Only the three terminal phases,
            // and only while the bar is not already holding the keyboard.
            // A bar that takes the keyboard whenever it feels like it is
            // the "randomly wouldn't let me type in it" bug, which is why
            // `releaseTheKeyboardSoTheReadersOwnAppGetsItBack` exists at
            // all. Nothing here moves the caret into the text field
            // either: the reader asked to copy, not to write.
            .background {
                if theEditCardHasAFinishedResultToRead {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onTheBarShouldTakeTheKeyboardBack()
                        }
                }
            }
        }
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
            // The controller's answer, not the guide's step index.
            //
            // During the setup-recovery detour the guide index is deliberately
            // frozen, so asking it whether the reader can go back is asking the
            // wrong question twice over: a reader starting at guide step 0 got
            // NO Back button even though there was a setup step behind them,
            // and a reader resuming at a later guide step got a Back button
            // that hit the detour's own guard and silently did nothing.
            readerCanGoBack: guideSessionController.canReturnToThePreviousStep,
            isTheLastStep: readerIsOnARealStep && stepNumber == totalSteps,
            // The controller already works out the right word for this button —
            // "Open nodejs.org", "Check again", "I ran it", "Finish" — and this
            // card was guessing instead, which is how the Node LTS step ended up
            // with a button reading "Continue" that opened a browser on the
            // first press and re-ran a tool check on the next. Ask, don't guess.
            labelForThePrimaryAction: guideSessionController.primaryActionForTheCurrentStep?.buttonLabel
        )
    }

    // MARK: The field

    private var textFieldRow: some View {
        // The model picker rides in the same glass shell as the field, on a thin
        // row just above it. The bar is only 320pt wide, so a segmented control
        // beside the field, close, and send buttons would squeeze the field to
        // nothing — stacking it keeps both fully usable, and it reads as part of
        // the input area rather than a floating strip. Mirrors the settings
        // panel's model picker so the same choice is reachable without opening
        // settings.
        VStack(alignment: .leading, spacing: 8) {
            if anAppIsOpenForEditing {
                appComposerHeader
                // The chat model toggle is deliberately absent here. It governs
                // ASKING only — chat speaks Anthropic's streaming tool-use
                // format, which `codex exec` cannot serve — and while an app is
                // open it read as though it chose the model that would edit the
                // app. A reader connected to Codex saw "Sonnet | Opus" and drew
                // the obvious, wrong conclusion. It stays in settings, where it
                // is not standing next to an editor it has nothing to do with.
                if effectiveComposerMode == .edit {
                    editKindRow
                }
            } else {
                modelSelectorRow
            }
            // With nothing attached this is EmptyView, so the bar is byte for
            // byte the bar it has always been until the reader pastes a picture.
            OverlayEyePastedImageThumbnailRow()
            fieldAndSendRow
            if theRequestIsBeingSizedUp {
                theRequestIrisJustTook
            }
            if anAppIsOpenForEditing {
                servingProviderFooter
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(IrisShellBackground(cornerRadius: DS.CornerRadius.extraLarge))
    }

    /// Whether a request the reader just sent is still being sized up, and the
    /// composer is therefore the surface that owes them a sign of life.
    ///
    /// Only in EDIT mode: a reader can perfectly well ask a question while a
    /// request is being assessed, and the ask path has its own working line.
    private var theRequestIsBeingSizedUp: Bool {
        anAppIsOpenForEditing
            && effectiveComposerMode == .edit
            && onDemandEditCoordinator.isAssessingRequest
    }

    /// THE READER'S SENTENCE, ECHOED BACK, AND A SPINNER UNDER IT.
    ///
    /// "After I put a prompt into feature or bug fix, I get no feedback of if
    /// it has gone through, a loading thing or something would be really
    /// helpful."
    ///
    /// He is describing this exactly. `describeRequest` accepts the request and
    /// leaves the flow in `.describe` while the §7 request probe runs — up to a
    /// twenty-second watchdog — and the bar draws its OWN composer for that
    /// phase, because `OnDemandEditCard` is only rendered while the phase is
    /// NOT `.describe`. The card's describe step has carried a "Sizing up the
    /// request…" row all along; the composer that replaced it never brought
    /// that row across. Measured at HEAD: the bar rendered to the same 250.5pt
    /// and byte-identical pixels before and after a request was accepted.
    ///
    /// The echo matters as much as the spinner. Sending clears the field, so
    /// his own words vanished at the same moment — leaving him nothing to look
    /// at that proved the app had even read them.
    private var theRequestIrisJustTook: some View {
        HStack(alignment: .top, spacing: 6) {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .scaleEffect(0.62)
                .frame(width: 13, height: 13)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sent — Iris is sizing up the request…")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                if let requestText = onDemandEditCoordinator.activeRequestText,
                   !requestText.isEmpty {
                    Text("“\(requestText)”")
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Sonnet/Opus toggle, trailing-aligned above the field. Bound straight
    /// to `companionManager.selectedModel`, the same state the settings panel
    /// writes, so switching here and switching there are one setting.
    /// True while an app is picked and waiting to be described — the one state
    /// where the bar is a two-purpose composer rather than an ask field.
    /// The composer offers editing when an app is already picked OR when an
    /// editable publik app is simply in front. The second half is the fix for
    /// "the UI doesn't show fix-a-bug when a publik app is at the forefront":
    /// that affordance used to be two suggestion chips, which an open guide
    /// suppressed outright and which the exchange card replaced the moment
    /// anyone asked a single question. On a bar that had already answered
    /// something, the app's headline feature had no entry point at all.
    private var anAppIsOpenForEditing: Bool {
        // Not while an edit is actually in flight. The composer's only move for
        // a request typed at that moment is to START one, which goes through
        // `pickApp` and resets the flow the reader is looking at — so typing a
        // follow-up into a plan DELETED the plan. That is the mechanism behind
        // "Can't send a follow up prompt after the plan into bug feature
        // overlay since it is gone." The field falls back to asking Iris a
        // question, which is what a reader mid-plan actually wants and costs
        // them nothing. (Refining a plan in place is a feature this does not
        // build; it only stops the destruction.)
        guard !anEditIsInFlight else { return false }
        // An app the reader PICKED is theirs, whatever else is on screen. This
        // used to sit behind the takeover guard below, so a guide parked at a
        // manual step hid the composer for an edit on a different app that had
        // just been asked for by name: the click "showed nothing" because the
        // one surface the `.describe` phase draws was gated on somebody else's
        // install.
        if onDemandEditCoordinator.phase == .describe { return true }
        // The INFERRED half is still not offered while a takeover is running.
        // The field is kept alive there so a reader can ask a question
        // mid-install, and the app being installed is frequently the frontmost
        // one — without this, the composer would offer to start an EDIT run on
        // it in the middle of its own install.
        guard !theCenteredTakeoverIsCoveringTheScreen else { return false }
        return companionManager.frontmostEditableAppForTheComposer != nil
    }

    /// True between the reader approving a plan and the exchange being closed —
    /// every phase where the card owns the surface and a second request would
    /// be a restart rather than a follow-up. The terminal phases are false on
    /// purpose: a finished card is a fine place to type the next request from.
    private var anEditIsInFlight: Bool {
        switch onDemandEditCoordinator.phase {
        case .pickApp, .describe, .done, .failed, .notEligible, .blockedByModel:
            return false
        default:
            return true
        }
    }

    /// The mode actually in force. A reader can be in Ask mode and then sign
    /// out, and a composer stuck in a mode with nothing behind it would be the
    /// same class of dead end this whole change exists to remove.
    private var effectiveComposerMode: ComposerMode {
        (composerMode == .ask && !accountService.canAnswerQuestions) ? .edit : composerMode
    }

    private var openAppName: String {
        onDemandEditCoordinator.activeAppName
            ?? companionManager.frontmostEditableAppForTheComposer?.name
            ?? "this app"
    }

    /// The app name and the Ask/Edit switch: one surface, one field, and a
    /// visible statement of which of the two things the field is about to do.
    ///
    /// This replaced two stacked glass boxes — an edit card and an ask field —
    /// which readers could not tell apart, because nothing said that one of
    /// them ran on the editing provider and the other could not.
    private var appComposerHeader: some View {
        HStack(spacing: 8) {
            Text(openAppName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.ink)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                // Ask is shown even when it cannot run. Hiding it would leave a
                // reader whose only credential is Codex with no way to learn
                // that Codex does not power chat — they would simply never see
                // asking exist. Disabled with the reason underneath teaches it.
                composerModeOption(
                    .ask, label: "Ask", isEnabled: accountService.canAnswerQuestions
                )
                composerModeOption(.edit, label: "Edit", isEnabled: true)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
        }
    }

    private func composerModeOption(
        _ mode: ComposerMode, label: String, isEnabled: Bool
    ) -> some View {
        // Reflects the mode IN FORCE, not the one last tapped: if Ask has been
        // overridden for want of a chat credential, Edit is what is highlighted.
        let isSelected = effectiveComposerMode == mode
        return Button { if isEnabled { composerMode = mode } } label: {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(
                    isEnabled
                        ? (isSelected ? DS.Colors.ink : DS.Colors.muted)
                        : DS.Colors.quiet
                )
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? label : "Asking needs a publik sign-in or an Anthropic key")
        .pointerCursor()
    }

    /// Fix or feature. Kept from the card it replaced because it is not a
    /// convenience: it decides the honesty label and the commit trailer.
    private var editKindRow: some View {
        HStack(spacing: 6) {
            composerKindPill(.bugFix, label: "Bug fix")
            composerKindPill(.feature, label: "Feature")
            Spacer(minLength: 0)
        }
    }

    private func composerKindPill(_ kind: OnDemandEditKind, label: String) -> some View {
        let isSelected = editKind == kind
        return Button { editKind = kind } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isSelected ? DS.Colors.accent.opacity(0.14) : DS.Colors.surfaceRaised)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .strokeBorder(
                                    isSelected ? DS.Colors.accent.opacity(0.5) : DS.Colors.line,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Says which model serves the mode the reader is actually in.
    ///
    /// The whole confusion this composer exists to end was that Iris never said
    /// this anywhere: `AccountService.activeTierDescription` was written for a
    /// "panel status line" and then never rendered, so a reader who had just
    /// connected Codex had no way to learn that the Sonnet/Opus toggle in front
    /// of them governed something else entirely. In edit mode this is also the
    /// control — every connected provider is selectable, because the resolver's
    /// fallback order was quietly deciding for readers who had a preference.
    @ViewBuilder
    private var servingProviderFooter: some View {
        if effectiveComposerMode == .edit {
            HStack(spacing: 6) {
                Text("Edits run on")
                    .font(.system(size: 9.5))
                    .foregroundColor(DS.Colors.quiet)
                editProviderPicker
                Spacer(minLength: 0)
            }
        } else {
            Text(accountService.chatProviderDescription)
                .font(.system(size: 9.5))
                .foregroundColor(DS.Colors.quiet)
        }
    }

    @ViewBuilder
    private var editProviderPicker: some View {
        let providers = MaintainModelProviderResolver.allAvailable()
        if providers.isEmpty {
            Text("no model connected")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DS.Colors.amber)
        } else if providers.count == 1 {
            // Nothing to choose between: state it rather than offering a menu
            // with one item in it.
            Text(providers[0].displayName)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        } else {
            Menu {
                ForEach(providers, id: \.identifier) { provider in
                    Button(provider.displayName) {
                        MaintainModelProviderResolver.preferredProviderIdentifier = provider.identifier
                    }
                }
            } label: {
                Text(MaintainModelProviderResolver.firstAvailable()?.displayName ?? "pick one")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DS.Colors.ink)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var modelSelectorRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("Model")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DS.Colors.quiet)
            HStack(spacing: 3) {
                barModelOption(label: "Sonnet", modelID: "claude-sonnet-4-6")
                barModelOption(label: "Opus", modelID: "claude-opus-4-6")
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
        }
    }

    private func barModelOption(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button {
            companionManager.setSelectedModel(modelID)
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.ink : DS.Colors.muted)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var fieldAndSendRow: some View {
        HStack(spacing: 8) {
            TextField(fieldPlaceholder, text: $typedMessage)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.ink)
                .focused($theTextFieldHasKeyboardFocus)
                // cmd-V with a picture on the clipboard. The field editor's
                // readable types are text types, so without this the keystroke
                // does the only thing it can — nothing, silently. Rides in
                // `.background`, so it takes no layout space and leaves the
                // field's focus, submit and styling exactly as they were.
                .acceptsAnImagePastedIntoTheField()
                .onSubmit {
                    sendWhatIsTyped()
                }
                .overlay(IBeamCursorView())
                // WHY AN INVISIBLE PLATE OVER THE FIELD. While the answer is
                // being read the bar has given the keyboard back, so its window
                // is not key and the text field cannot take a click and start
                // editing on its own. This plate turns that click into "ask for
                // the keyboard back, then put the caret in the field". It only
                // exists in the states where the bar is not holding the
                // keyboard, so it never sits between the reader and a field they
                // can already type in.
                //
                // WHY IT COVERS `.waitingForIrisToAnswer` TOO, NOT JUST THE
                // ANSWER. The bar releases the keyboard for BOTH of those phases
                // (`OverlayEyeExchange.theBarShouldHoldTheKeyboard`), and a
                // question does not always come back with an answer: a CANCELLED
                // request publishes nothing, so `assistantResponseGenerationCount`
                // never bumps and the bar stays in `.waitingForIrisToAnswer` for
                // good. With the plate gated on `.showingTheAnswer` alone there
                // was then no way back into the field — the window could not
                // become key, so Escape (which needs key status) could not fire
                // either, and the × was the only way out. This is the reported
                // "randomly wouldn't let me type in it". The matching half is
                // `registerTheReaderWentBackToTheField`, which accepts the same
                // two phases.
                .overlay {
                    if exchange.phase == .showingTheAnswer
                        || exchange.phase == .waitingForIrisToAnswer {
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
                    .foregroundColor(theSendButtonIsLive ? DS.Colors.accent : DS.Colors.quiet)
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: theSendButtonIsLive)
            .disabled(!theSendButtonIsLive)
        }
    }

    /// "Ask Iris…" the first time and "Ask something else…" afterwards, because
    /// the second time round the interesting thing about the field is that it
    /// is still there and still usable without reopening anything.
    private var fieldPlaceholder: String {
        if anAppIsOpenForEditing, effectiveComposerMode == .edit {
            return "What should change in \(openAppName)?"
        }
        return exchange.thereIsAnExchangeOnScreen ? "Ask something else…" : "Ask Iris…"
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

    /// History, and the way out of the current conversation.
    ///
    /// Both were missing entirely: the bar showed one exchange, kept hundreds
    /// on disk that nobody could see, and had no way to start over short of
    /// closing the bar. "New chat" is also what brings the suggestion
    /// openers back, since those are only offered on a blank exchange.
    @ViewBuilder
    private var historyAndNewChatRow: some View {
        if companionManager.thereIsChatHistoryToShow || exchange.thereIsAnExchangeOnScreen {
            HStack(spacing: 6) {
                if companionManager.thereIsChatHistoryToShow {
                    Button {
                        historyIsShowing.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: historyIsShowing ? "chevron.down" : "clock.arrow.circlepath")
                                .font(.system(size: 9, weight: .semibold))
                            Text(historyIsShowing ? "Hide history" : "History")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .irisTinyButton()
                    .background(IrisShellBackground(cornerRadius: DS.CornerRadius.small))
                }

                Spacer(minLength: 0)

                Button {
                    historyIsShowing = false
                    companionManager.startANewChat()
                    exchange.clearTheWholeExchange()
                    typedMessage = ""
                    theTextFieldHasKeyboardFocus = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 9, weight: .semibold))
                        Text("New chat")
                            .font(.system(size: 9, weight: .medium))
                    }
                }
                .irisTinyButton()
                .background(IrisShellBackground(cornerRadius: DS.CornerRadius.small))
                .help("Clear this conversation and start fresh")
            }
        }
    }

    /// Past exchanges, newest first. Capped in height so a long history
    /// scrolls inside the bar instead of growing it off the screen.
    @ViewBuilder
    private var chatHistoryList: some View {
        if historyIsShowing {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(companionManager.recentChatHistory(), id: \.askedAt) { past in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(past.question)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(DS.Colors.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(past.answer)
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 220)
            .background(IrisShellBackground(cornerRadius: DS.CornerRadius.large))
        }
    }

    /// The finished edit exchanges of this session, newest first — the edit
    /// flow's answer to the chat transcript. Chat got one of these for the
    /// byte-identical complaint ("when I click off Iris it just gets rid of my
    /// chat and opens a brand new one"); the edit flow never did, so a reader
    /// who closed a result card was left with a blank overlay and no way to
    /// tell whether Iris had done anything at all.
    ///
    /// Capped at the three most recent, and each row clamped: this is a 320pt
    /// panel floating over somebody's desktop, and a full log here would be the
    /// second panel the bar exists not to be. A row is also a tap back into
    /// editing that app, which is the other half of the report — "the only way
    /// to do that that is clear is by going into the menu and selecting it
    /// every time, very annoying for ease of use".
    @ViewBuilder
    private var finishedEditsList: some View {
        let mostRecentFirst = Array(onDemandEditCoordinator.sessionThread.suffix(3).reversed())
        if !mostRecentFirst.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("What Iris changed")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                ForEach(mostRecentFirst) { finishedEdit in
                    Button {
                        onDemandEditCoordinator.resumeEditing(finishedEdit)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(finishedEdit.appName) · \(finishedEdit.kind == .feature ? "feature" : "bug fix")")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.quiet)
                            Text(finishedEdit.request)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(DS.Colors.ink)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(finishedEdit.outcome)
                                .font(.system(size: 10))
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Edit \(finishedEdit.appName) again")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IrisShellBackground(cornerRadius: DS.CornerRadius.large))
        }
    }

    /// True while `OnDemandEditCard` is drawing a real card at the top of the
    /// bar. `.describe` is excluded because the bar draws that step itself as
    /// the composer, and `.pickApp` because the card renders `EmptyView()` for
    /// it — in both, nothing is above the field and there is nothing to be
    /// confused with.
    private var theEditCardOwnsTheSurface: Bool {
        onDemandEditCoordinator.phase != .pickApp
            && onDemandEditCoordinator.phase != .describe
    }

    /// True while the edit card is showing a FINISHED result whose words the
    /// reader may well want to keep — a failure, a refusal, or the model's own
    /// "I can't do this". These are the phases where the reader is reading
    /// rather than waiting, and the only ones where clicking the card is worth
    /// spending the keyboard on.
    ///
    /// `.done` is deliberately absent. A run that finished carries its own
    /// summary and its own controls, and the sentences worth copying out of Iris
    /// are the ones that explain why something did NOT happen.
    private var theEditCardHasAFinishedResultToRead: Bool {
        switch onDemandEditCoordinator.phase {
        case .failed, .notEligible, .blockedByModel:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var whateverTheExchangeIsUpTo: some View {
        if exchange.theSuggestionChipsShouldBeOffered {
            // Openers like "what's on my screen?" under an edit card would be
            // three invitations to change the subject, stacked under the thing
            // Iris is actually waiting on.
            if !theEditCardOwnsTheSurface {
                suggestionChips
            }
        } else if theEditCardOwnsTheSurface && exchange.wasRestoredFromAnEarlierSitting {
            // SUPPRESSED, and this is the whole reason the "restored" flag
            // exists. Reopening the bar brings back the last general-chat
            // question and answer (`exchangeShowingTheLastThingThatWasSaid`),
            // which is right when the bar is a chat bar — and wrong when an
            // edit card is sitting above it, because the two then read as one
            // conversation. The reader, looking at exactly this: "the chat
            // below is linked to a general chat … super confusing." Measured at
            // HEAD: an edit card in the bar grew from 315.5pt to 404.5pt purely
            // to lay out an old answer about installing Node underneath it.
            //
            // Suppressed at RENDER time, not thrown away: the exchange is still
            // in this view's state, so the moment the edit card is closed the
            // reader's conversation is back where they left it.
            EmptyView()
        } else if theEditCardOwnsTheSurface {
            // A live exchange — one the reader asked for while the card was up,
            // which the composer still allows — is theirs and stays. It just
            // has to be visibly a different thing from the edit above it.
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat with Iris")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)
                    .padding(.leading, 2)
                exchangeCard
            }
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
                whatThatQueryCost
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
    /// The price of the answer directly above it, and only when there is a real
    /// price to name. A reader on publik's funded tier, a Claude Code login or
    /// the Codex CLI pays nothing per query, and the ledger records nothing for
    /// them — so this row simply does not exist rather than reading "$0.00",
    /// which would suggest their queries are free in a way that invites the
    /// wrong conclusion about the ones that are not.
    @ViewBuilder
    private var whatThatQueryCost: some View {
        if let costText = spendLedger.mostRecentCallText {
            Text(costText)
                .font(.system(size: 9.5))
                .foregroundColor(DS.Colors.textTertiary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
        }
    }

    private func answerArea(showing answerText: String) -> some View {
        ScrollView(.vertical) {
            Text(answerText)
                .font(.system(size: 12.5))
                .foregroundColor(
                    exchange.whatIrisSaidBackIsAFailureMessage ? DS.Colors.red : DS.Colors.ink
                )
                .lineSpacing(2.5)
                // Selectable, like every other text surface in this app.
                //
                // This one was not, and it is the mechanism behind a whole class
                // of reported failure: a reader asked Iris for a shell command,
                // could not select the answer to copy it, and retyped it by hand.
                // `curl -fsSL` reached their shell as `curltl-fsSL` and `.zshrc`
                // as `.zhrc`. Iris was blamed for giving wrong commands; it gave
                // the right ones and made them impossible to take.
                .textSelection(.enabled)
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
        // The floor is the point here. This height feeds the frame of the
        // scroll view that CONTAINS the text being measured, so on the first
        // layout pass the measurement is taken against a nearly-zero frame and
        // can settle small — leaving a real answer rendered as a two-line
        // sliver the reader has to scroll to read. Once there is an answer at
        // all it gets a proper minimum, and the ceiling still caps a long one.
        let floor = exchange.whatIrisSaidBack?.isEmpty == false
            ? OverlayEyeInteractionGeometry.shortestTheAnswerAreaMayBeOnceThereIsAnAnswer
            : 17
        return min(
            max(measuredAnswerTextHeight, floor),
            OverlayEyeInteractionGeometry.tallestTheAnswerAreaMayGrow
        )
    }

    // MARK: Driving the exchange

    /// One field, two destinations. Which one is not inferred from anything —
    /// the reader picked it on the switch above, and the footer says what will
    /// serve it. Guessing here is what the old two-box layout effectively did.
    private func sendWhatIsTyped() {
        // `onSubmit` fires on Return whether or not the button is enabled, so
        // the guard the button already draws has to exist here too.
        guard theSendButtonIsLive else { return }
        if anAppIsOpenForEditing, effectiveComposerMode == .edit {
            let request = typedMessage
            typedMessage = ""
            if onDemandEditCoordinator.phase == .describe {
                onDemandEditCoordinator.describeRequest(request, kind: editKind)
            } else if let slug = onDemandEditCoordinator.activeAppSlug,
                      let name = onDemandEditCoordinator.activeAppName,
                      let stack = onDemandEditCoordinator.activeAppStack {
                // A finished card still names the app it was about, so the next
                // request typed over it belongs to THAT app — not to whichever
                // window happens to be frontmost while the reader reads a
                // result. Going through the manager keeps the bar-raising and
                // panel-dismissing side of a pick identical to every other way
                // in.
                companionManager.requestOnDemandEdit(
                    forSlug: slug, name: name, stack: stack, preselectedKind: editKind
                )
                onDemandEditCoordinator.describeRequest(request, kind: editKind)
            } else {
                // Nothing picked yet: bind to the app in front and describe in
                // one move, so the reader never has to discover a phrase.
                _ = companionManager.beginOnDemandEditFromTheComposer(
                    request: request, kind: editKind
                )
            }
            return
        }
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
        // Door B: an explicit instruction to EDIT the frontmost catalog app
        // (a "fix a bug in…" / "add a feature to…" chip, or the same phrasing
        // typed) opens the on-demand edit card instead of asking Iris a
        // question. It must NOT register a chat exchange — no assistant answer
        // is coming for it, and the bar would otherwise sit waiting on one
        // forever.
        if companionManager.beginOnDemandEditIfMessageIsAnEditInstruction(messageText) {
            typedMessage = ""
            measuredAnswerTextHeight = 0
            // Keep the bar holding the keyboard — the edit card's describe field
            // is what the reader types into next, and it can only take focus
            // while this panel is still key. Only the main field's own focus is
            // dropped, so a click into the describe field lands cleanly.
            theTextFieldHasKeyboardFocus = false
            return
        }

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
