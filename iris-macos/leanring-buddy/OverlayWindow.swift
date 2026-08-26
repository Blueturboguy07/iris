//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for the Iris companion.
//  One OverlayWindow is created per screen so the companion
//  seamlessly follows the cursor across multiple monitors.
//
//  The companion is Iris's eye — the same eye the website draws, see
//  `OverlayIrisEyeView.swift`. It used to be a blue triangle, which was a
//  second cursor chasing the first one. Everything the triangle *did* is
//  unchanged: it still rides beside the pointer, still flies a bezier arc to
//  a `[POINT:...]` target and back, still hides itself on the screens that
//  are not the one performing the flight. Only what is drawn has changed —
//  and the eye now watches whatever it is meant to be watching.
//

import AppKit
import AVFoundation
import SwiftUI

/// The full-screen overlay window.
///
/// It is an `NSPanel` rather than a plain `NSWindow` for one reason: the
/// `.nonactivatingPanel` style is what lets the eye be *clicked* without Iris
/// stealing frontmost status from whatever app the user is really working in.
/// Clicking an ordinary background window activates its app; clicking a
/// non-activating panel does not. It still refuses to become key — the input
/// bar is a separate panel precisely so that this one never has to hold the
/// keyboard.
class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        // CLICK-THROUGH BY DEFAULT. This is the setting that keeps the user's
        // desktop usable: a full-screen window that accepts mouse events eats
        // every click on every app underneath it. It is relaxed only while the
        // pointer is over the eye, and only by `OverlayWindowMouseEventGate`.
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

/// The one thing allowed to turn the overlay's click-through off, and the
/// bridge from the SwiftUI content back to the `NSWindow` hosting it.
///
/// WHY A GATE AND NOT A HIT TEST. Returning nil from a view's `hitTest(_:)`
/// stops SwiftUI acting on a click, but the *window* has still swallowed it —
/// the click never reaches the app underneath. Only `ignoresMouseEvents`, which
/// the window server reads before it routes the event at all, produces real
/// click-through. So the overlay's pointer poll drives this gate open while the
/// pointer is inside the eye's rect and shut everywhere else, which means the
/// window is click-through for every pixel of the screen except a 76pt square
/// around the eye.
@MainActor
final class OverlayWindowMouseEventGate {

    private weak var overlayWindowToGate: NSWindow?

    /// Mirrors the window's own state so the 60fps poll only touches AppKit on
    /// an actual change rather than sixty times a second forever.
    private var theOverlayIsCurrentlyAcceptingMouseEvents = false

    init(overlayWindowToGate: NSWindow?) {
        self.overlayWindowToGate = overlayWindowToGate
    }

    func setWhetherTheOverlayAcceptsMouseEvents(_ shouldAcceptMouseEvents: Bool) {
        guard shouldAcceptMouseEvents != theOverlayIsCurrentlyAcceptingMouseEvents else { return }
        theOverlayIsCurrentlyAcceptingMouseEvents = shouldAcceptMouseEvents
        overlayWindowToGate?.ignoresMouseEvents = !shouldAcceptMouseEvents
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the Iris eye companion.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// when it is. The eye is drawn in every assistant state; while a request
// is in flight its track spins instead of a separate spinner appearing.
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    /// Whether the pointer has moved recently enough to be worth watching,
    /// or has sat still long enough for the eye to start wandering instead.
    /// Seeded in `init` so the eye never starts out believing the pointer has
    /// been frozen since the machine booted.
    @State private var gazeTracker: IrisEyeGazeTracker

    /// Where the eye rests and which of its pixels may be clicked. Everything
    /// about the eye as a *control* lives in `OverlayEyeInteraction.swift`,
    /// which is testable without a screen.
    private static let interactionGeometry = OverlayEyeInteractionGeometry()

    /// The eye drawn on the overlay: 64pt across. It was 32pt, which read as an
    /// eye but was easy to overlook and far too small to ask anybody to hit —
    /// and now that clicking it is how you talk to Iris, it has to be an
    /// obvious target as well as an obvious creature.
    private static let overlayEyeGeometry = OverlayEyeInteractionGeometry.eyePupilGeometry

    /// Opens and closes the overlay window's click-through, driven by the same
    /// 60fps pointer poll that drives the gaze. Optional so the view can still
    /// be constructed outside a window.
    let overlayWindowMouseEventGate: OverlayWindowMouseEventGate?

    /// Owns the input bar's own small window.
    let inputBarPanelManager: OverlayEyeInputBarPanelManager?

    /// Whether the eye has been clicked, and therefore whether it is currently
    /// drawn as an eye or as the settings gear.
    @State private var eyeActivation = OverlayEyeActivation()

    init(
        screenFrame: CGRect,
        isFirstAppearance: Bool,
        companionManager: CompanionManager,
        overlayWindowMouseEventGate: OverlayWindowMouseEventGate? = nil,
        inputBarPanelManager: OverlayEyeInputBarPanelManager? = nil
    ) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.overlayWindowMouseEventGate = overlayWindowMouseEventGate
        self.inputBarPanelManager = inputBarPanelManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        // Starts at rest in the top-left rather than beside the pointer.
        _cursorPosition = State(
            initialValue: OverlayEyeInteractionGeometry.restingEyeCenterInSwiftUICoordinates
        )
        _isCursorOnThisScreen = State(initialValue: ScreenContainment.screenFrame(screenFrame, containsPointer: mouseLocation))
        _gazeTracker = State(initialValue: IrisEyeGazeTracker(
            pointerLocation: mouseLocation,
            observedAt: ProcessInfo.processInfo.systemUptime
        ))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// Where the iris sits inside the lid right now, in SwiftUI points.
    /// Recomputed every frame by `updateWhereTheEyeIsLooking`.
    @State private var irisGlanceOffset: CGSize = .zero

    /// What the eye is watching, in AppKit screen coordinates. `nil` means
    /// "watch the pointer" — the ordinary case. It is set to an element's
    /// location for the duration of the flight to it and the pointing that
    /// follows, so the eye is looking at the thing it flew to rather than
    /// back over its shoulder at a mouse it has just left behind.
    @State private var whatTheEyeIsWatchingInScreenCoordinates: CGPoint?

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    /// Where the eye lives when it is not flying somewhere: pinned to the top
    /// left of this screen, below the menu bar.
    ///
    /// It used to trail the pointer by a fixed offset, which meant a thing
    /// moving in the corner of your vision whenever you moved the mouse — the
    /// eye already says where it is attending by *looking*, so it does not
    /// also need to chase. Staying put makes it findable: the same place every
    /// time, rather than wherever the cursor happened to leave it.
    private var restingPositionInSwiftUICoordinates: CGPoint {
        // Half the eye's own size plus a margin, so the shape clears the menu
        // bar rather than tucking under it.
        OverlayEyeInteractionGeometry.restingEyeCenterInSwiftUICoordinates
    }

    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm iris"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing).
            // It spans the whole screen, so it must never take a hit test:
            // while the window's mouse gate is open it would otherwise be the
            // thing that swallowed a click that missed the eye's own circle.
            Color.black.opacity(0.001)
                .allowsHitTesting(false)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
                    // Speech, not a control — it must never take a click.
                    .allowsHitTesting(false)
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
                    // Speech, not a control — it must never take a click.
                    .allowsHitTesting(false)
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
                    // Speech, not a control — it must never take a click.
                    .allowsHitTesting(false)
            }

            // Iris's eye. One view for every assistant state — there is no
            // longer a separate spinner to cross-fade with, because the
            // thinking mood spins the eye's own track instead, which is what
            // the website does. It stays in the view tree permanently and
            // fades via opacity so SwiftUI never removes and re-inserts it
            // (which caused a visible "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            Button {
                handleAClickOnTheEye()
            } label: {
                // The eye and the gear are the same size and wear the same
                // shell, so this swap changes what the object offers without
                // moving or resizing it.
                switch eyeActivation.affordanceToDraw {
                case .eye:
                    OverlayIrisEyeView(
                        geometry: Self.overlayEyeGeometry,
                        mood: eyeMood,
                        glanceOffset: irisGlanceOffset
                    )
                case .settingsGear:
                    OverlaySettingsGearView(geometry: Self.overlayEyeGeometry)
                }
            }
            .buttonStyle(.plain)
            // The eye is round, so its click region is too — the corners of its
            // bounding box are desktop, not eye.
            .contentShape(Circle())
            .pointerCursor(isEnabled: theEyeIsClickableRightNow)
            // A view at zero opacity still hit-tests in SwiftUI, so an eye that
            // is invisible on this screen — or mid-flight to an element — has
            // to be told not to take clicks. The window's own click-through
            // gate below says the same thing; both have to agree before a
            // click can be swallowed.
            .allowsHitTesting(theEyeIsClickableRightNow)
            // The eye carries its own soft ink drop shadow; this is the extra
            // accent glow that only exists mid-flight, inherited from the
            // triangle's swoop. At rest `buddyFlightScale` is 1.0 and the glow
            // is fully transparent.
            .shadow(
                color: DS.Colors.overlayCursorBlue.opacity(Double(buddyFlightScale - 1.0) * 2.0),
                radius: 6 + (buddyFlightScale - 1.0) * 20,
                x: 0,
                y: 0
            )
            .scaleEffect(buddyFlightScale)
            .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
            .position(cursorPosition)
            .animation(
                buddyNavigationMode == .followingCursor
                    ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                    : nil,
                value: cursorPosition
            )
            .animation(.easeIn(duration: 0.25), value: companionManager.assistantState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .clickySummonAskBar)) { _ in
            // Every screen's overlay hears this; the guard inside means only
            // the one currently showing the eye acts on it.
            openTheInputBarFromTheSummonHotkey()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickyMaintainAskRaised)) { _ in
            // Maintain mode found something and wants to ask. Open the eye's
            // bar the same way the summon hotkey does; the ask card renders at
            // the top of it. Same one-screen guard, so it opens once.
            openTheInputBarFromTheSummonHotkey()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clickyOnDemandEditRaised)) { _ in
            // The reader tapped "Edit this app" somewhere off the eye. Open the
            // eye's bar so the on-demand edit card is in front of them; the same
            // one-screen guard means it opens once.
            openTheInputBarFromTheSummonHotkey()
        }
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = ScreenContainment.screenFrame(screenFrame, containsPointer: mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = self.restingPositionInSwiftUICoordinates

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
            companionManager.tearDownOnboardingVideo()
            // Leaving the window's mouse gate open would leave a square of the
            // desktop unclickable with nothing drawn in it to explain why.
            overlayWindowMouseEventGate?.setWhetherTheOverlayAcceptsMouseEvents(false)
            inputBarPanelManager?.hideInputBar()
        }
        .onChange(of: buddyIsVisibleOnThisScreen) { _, theEyeIsStillOnThisScreen in
            // The pointer moved to another display, or a flight to an element
            // started. Either way this screen's eye is gone, and a bar hanging
            // under an eye that is not there is orphaned UI.
            guard !theEyeIsStillOnThisScreen else { return }
            // ...unless a guide is being followed: the eye flies off to point
            // at controls mid-install, and the reader was clear that the steps
            // vanishing when it does is the wrong behaviour. Keep them up.
            guard !companionManager.guideSessionController.isActivelyGuiding else { return }
            inputBarPanelManager?.hideInputBar()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    // MARK: - Mood

    /// How the app's four assistant states read on the website's four-mood eye
    /// (`components/iris/IrisEye.tsx`).
    ///
    /// | assistant state | eye mood | why |
    /// | --- | --- | --- |
    /// | `idle` | `idle` | at rest: it blinks, and it wanders once the pointer stops |
    /// | `capturing` | `thinking` | taking the screenshot is work, and the spinner it replaced covered this state too |
    /// | `thinking` | `thinking` | the track spins for as long as Claude is answering |
    /// | `pointing`, still flying | `ready` | alert and locked on to the target, but it has not landed yet |
    /// | `pointing`, arrived | `done` | the site's found-it green, held steady on the thing it is pointing at |
    private var eyeMood: IrisEyeMood {
        switch companionManager.assistantState {
        case .idle:
            return .idle
        case .capturing, .thinking:
            return .thinking
        case .pointing:
            return buddyNavigationMode == .pointingAtTarget ? .done : .ready
        }
    }

    /// Whether the buddy should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - The Eye As A Control

    /// Whether the eye is a thing that can be clicked at this instant.
    ///
    /// Only while it is sitting at rest on the screen the pointer is on. An eye
    /// mid-flight to a `[POINT:…]` target is somewhere the user did not put it
    /// and is about to leave again, so a click region that chased it around the
    /// screen would be a moving hole in the desktop.
    private var theEyeIsClickableRightNow: Bool {
        buddyNavigationMode == .followingCursor
            && buddyIsVisibleOnThisScreen
            && cursorOpacity > 0
    }

    /// One click target, two meanings, decided by `OverlayEyeActivation`.
    private func handleAClickOnTheEye() {
        switch eyeActivation.registerAClickOnTheEye() {
        case .shouldOpenTheInputBar:
            presentTheInputBar()
        case .shouldOpenTheSettingsPanel:
            // The existing panel, reached the existing way, rather than a
            // second settings surface that would immediately drift from it.
            NotificationCenter.default.post(name: .clickyTogglePanel, object: nil)
        }
    }

    /// The summon hotkey opens the ask bar, the same surface a click on the
    /// eye opens.
    ///
    /// Onboarding tells the reader to "press control + option and ask me
    /// anything", and for a while afterwards the hotkey opened the settings
    /// panel — which no longer has anywhere to ask anything. A shortcut that
    /// contradicts the sentence teaching it is worse than no shortcut.
    private func openTheInputBarFromTheSummonHotkey() {
        guard buddyIsVisibleOnThisScreen else { return }
        guard !eyeActivation.theInputBarIsOpen else { return }
        _ = eyeActivation.registerAClickOnTheEye()
        presentTheInputBar()
    }

    private func presentTheInputBar() {
        guard let inputBarPanelManager else { return }
        inputBarPanelManager.showInputBar(
            forEyeAtInteractionGeometry: Self.interactionGeometry,
            onScreenWithFrame: screenFrame,
            companionManager: companionManager,
            onTheBarClosing: {
                // Whatever took the bar down — Escape, a click elsewhere, a
                // sent message — the gear turns back into an eye here, so the
                // two can never disagree.
                self.eyeActivation.dismissTheInputBar()
            }
        )
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            // `NSEvent.mouseLocation` is readable without an Accessibility
            // grant, unlike an event tap, so the eye keeps watching the
            // pointer even on a machine where permissions are only partly
            // granted. That is why the pointer is polled rather than tapped.
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = ScreenContainment.screenFrame(self.screenFrame, containsPointer: mouseLocation)

            // THE CLICK-THROUGH GATE, re-decided sixty times a second.
            //
            // The overlay covers the whole screen and sits above everything, so
            // for all but one small square of it the only correct answer is
            // "let the click through to whatever is underneath". The square is
            // the eye, and only while the eye is actually there to be clicked.
            // `setWhetherTheOverlayAcceptsMouseEvents` no-ops unless the answer
            // has changed, so this poll costs nothing while the pointer is off
            // in the user's own app — which is nearly always.
            let thePointerIsOverTheEye = Self.interactionGeometry
                .theOverlayShouldAcceptMouseEvents(
                    forPointerAtAppKitScreenLocation: mouseLocation,
                    onScreenWithFrame: self.screenFrame
                )
            self.overlayWindowMouseEventGate?.setWhetherTheOverlayAcceptsMouseEvents(
                thePointerIsOverTheEye && self.theEyeIsClickableRightNow
            )

            // The gaze is recomputed on every tick no matter what the rest of
            // the buddy is doing — it keeps watching while it flies out, while
            // it points, and while it flies home — so this has to happen
            // before any of the early returns below.
            self.updateWhereTheEyeIsLooking(pointerLocation: mouseLocation)

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // At rest the eye holds its corner. Only the gaze, updated above,
            // responds to the pointer.
            let resting = self.restingPositionInSwiftUICoordinates
            if self.cursorPosition != resting {
                self.cursorPosition = resting
            }
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// The exact inverse of `convertScreenPointToSwiftUICoordinates`: takes a
    /// point in this overlay's SwiftUI space back out to AppKit screen space.
    /// Needed because the eye's position is tracked in SwiftUI coordinates but
    /// the glance maths works entirely in screen coordinates, so that the one
    /// y flip in the whole feature lives in `IrisEyePupilGeometry` and nowhere
    /// else.
    private func convertSwiftUIPointToScreenCoordinates(_ swiftUIPoint: CGPoint) -> CGPoint {
        let x = swiftUIPoint.x + screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - swiftUIPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Where the Eye Is Looking

    /// Recomputes where the iris should sit, in SwiftUI points relative to the
    /// centre of the lid.
    ///
    /// The eye watches whatever it has been told to watch — an element while
    /// it is flying to one or pointing at one, and otherwise the pointer — and
    /// falls back to the website's `iris-look` wander once the pointer has sat
    /// still for a few seconds, because an eye locked onto a motionless mouse
    /// looks like a paused video rather than a companion.
    private func updateWhereTheEyeIsLooking(pointerLocation: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        gazeTracker.observePointer(at: pointerLocation, timestamp: now)

        let eyeCenterInScreenCoordinates = convertSwiftUIPointToScreenCoordinates(cursorPosition)

        // Watching a specific element beats everything else, including the
        // idle wander: the whole reason the eye flew over there is to say
        // "this one".
        if let whatTheEyeIsWatchingInScreenCoordinates {
            irisGlanceOffset = Self.overlayEyeGeometry.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: eyeCenterInScreenCoordinates,
                pointerLocationInAppKitScreenCoordinates: whatTheEyeIsWatchingInScreenCoordinates
            )
            return
        }

        switch gazeTracker.gazeSource(at: now) {
        case .pointer:
            irisGlanceOffset = Self.overlayEyeGeometry.glanceOffsetInSwiftUICoordinates(
                eyeCenterInAppKitScreenCoordinates: eyeCenterInScreenCoordinates,
                pointerLocationInAppKitScreenCoordinates: pointerLocation
            )
        case .idleWander:
            irisGlanceOffset = Self.overlayEyeGeometry.idleWanderOffsetInSwiftUICoordinates(
                atElapsedSeconds: now
            )
        }
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        // Look at the element for the whole flight, not at the mouse being
        // left behind. The unoffset element location is used rather than the
        // clamped landing spot so the eye is aimed at the thing itself.
        whatTheEyeIsWatchingInScreenCoordinates = screenLocation

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination, scaling up at the midpoint for a
    /// "swooping" feel with the glow intensifying during flight.
    ///
    /// The triangle used to rotate to face its direction of travel each frame.
    /// An eye must not: a rotating eye reads as a spinning object rather than
    /// as something looking where it is going. It keeps its heading instead by
    /// aiming its gaze at the target, which `updateWhereTheEyeIsLooking` does
    /// every frame for the whole flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let flightHome = restingPositionInSwiftUICoordinates

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        // Done pointing — release the target so the gaze returns to the pointer
        // while it flies back to its corner.
        whatTheEyeIsWatchingInScreenCoordinates = nil

        animateBezierFlightArc(to: flightHome) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        whatTheEyeIsWatchingInScreenCoordinates = nil
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []

    /// One per overlay window. Held here rather than only inside the SwiftUI
    /// view so the bars can be taken down when the overlay goes away, and so
    /// the panels are not deallocated out from under themselves.
    private var inputBarPanelManagers: [OverlayEyeInputBarPanelManager] = []

    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)
            let inputBarPanelManager = OverlayEyeInputBarPanelManager()

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager,
                overlayWindowMouseEventGate: OverlayWindowMouseEventGate(overlayWindowToGate: window),
                inputBarPanelManager: inputBarPanelManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            inputBarPanelManagers.append(inputBarPanelManager)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        takeDownEveryInputBar()
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// The input bar belongs to the eye. When the eye goes, so does it —
    /// otherwise a bar would be left floating with nothing to have opened it.
    private func takeDownEveryInputBar() {
        for inputBarPanelManager in inputBarPanelManagers {
            inputBarPanelManager.hideInputBar()
        }
        inputBarPanelManagers.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        takeDownEveryInputBar()

        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
