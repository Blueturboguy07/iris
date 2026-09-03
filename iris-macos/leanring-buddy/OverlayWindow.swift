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
///
/// The one exception is a drag of the eye. Because this gate is the only reason
/// the overlay receives mouse events at all, shutting it while the reader is
/// dragging would end the drag the moment the pointer outran the eye — so the
/// poll holds it open for the length of a drag, and a watchdog on the mouse
/// button shuts it again the instant the drag is over.
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
    ///
    /// Rebuilt from the eye's current home rather than held as one `static`
    /// value, because the reader can drag the eye somewhere else and the
    /// click-through gate, the eye's own hit shape and the input bar all have
    /// to follow it there. While it was static and built on the default corner
    /// nothing could read the remembered resting place at all.
    private var interactionGeometryForTheEyeWhereItSitsNow: OverlayEyeInteractionGeometry {
        OverlayEyeInteractionGeometry(
            eyeCenterInSwiftUICoordinates: eyeRestingPlaceInSwiftUICoordinates
        )
    }

    /// The side of the square the eye is drawn to hit-test as — exactly the
    /// square the window's click-through gate opens over, read from the same
    /// place the gate reads it.
    private var sideOfTheEyesClickTargetSquare: CGFloat {
        interactionGeometryForTheEyeWhereItSitsNow.sideLengthOfTheClickTargetSquare
    }

    /// How far right of the eye's CENTER anything it says has to start.
    ///
    /// It used to be 10, which predates the eye: at 32pt across a bubble ten
    /// points right of centre cleared it, and at 64pt it does not. The eye is
    /// drawn to a 76pt square centred on `cursorPosition`, so a bubble starting
    /// at +10 has its first ~28pt underneath the eye — which is what "text
    /// overlap is a lil' annoying" was a photograph of, with the "o" of "over
    /// here!" hidden behind the pupil.
    ///
    /// Half the click-target square plus a small gap, so the clearance is
    /// derived from the eye's real size rather than guessed again. It also
    /// clears the 1.3x pulse mid-flight (38 × 1.3 = 49.4 of visible eye at the
    /// arc's midpoint, against 46 of offset for a bubble whose own left edge is
    /// past the widest point of the disc).
    private var horizontalGapFromTheEyeToWhatItSays: CGFloat {
        interactionGeometryForTheEyeWhereItSitsNow
            .horizontalGapFromTheCentreToWhatTheEyeSays
    }

    /// How long after the eye has been dragged a click on it is read as the
    /// mouse-up that ended the drag rather than as a click of its own.
    private static let howLongAClickIsIgnoredAfterTheEyeIsDragged: TimeInterval = 0.3

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

    /// Where the eye's home is on this screen right now, in SwiftUI overlay
    /// coordinates. Seeded from `OverlayEyeRestingPlace` and moved by a drag,
    /// which together are what make "drag the eye somewhere and it stays
    /// there" true for the rest of this session and after a relaunch.
    @State private var eyeRestingPlaceInSwiftUICoordinates: CGPoint

    /// Where the eye's home was at the instant the drag in progress began, or
    /// nil when no drag is in progress — which is also how the pointer poll
    /// knows to hold the click-through gate open.
    ///
    /// The drag is applied as a translation from this point rather than by
    /// snapping the eye's centre onto the pointer, so the eye keeps the grip
    /// the reader took hold of it by instead of jumping the moment it moves.
    @State private var eyeHomeWhenTheCurrentDragBegan: CGPoint?

    /// When the eye was last actually dragged, on the uptime clock.
    @State private var whenTheEyeWasLastDragged: TimeInterval?

    /// Where the "Iris needs you" badge is in its slow breath. Held here rather
    /// than derived so the pulse is a real animation the reader's eye catches
    /// at the edge of their vision, which is the entire point of it.
    @State private var attentionBadgeIsBreathingOut = false

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
        // Starts at rest where the reader last left the eye — the top-left
        // corner until they drag it somewhere else — rather than beside the
        // pointer. Read here rather than in `onAppear` so the eye never draws
        // one frame in the old corner and then jumps.
        let rememberedRestingPlace = OverlayEyeRestingPlace.shared
            .restingPlace(onScreenOfSize: screenFrame.size)
        _eyeRestingPlaceInSwiftUICoordinates = State(initialValue: rememberedRestingPlace)
        _cursorPosition = State(initialValue: rememberedRestingPlace)
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
    /// Where the eye lives when it is not flying somewhere: wherever the
    /// reader put it, which is the top left of this screen until they drag it.
    ///
    /// It used to trail the pointer by a fixed offset, which meant a thing
    /// moving in the corner of your vision whenever you moved the mouse — the
    /// eye already says where it is attending by *looking*, so it does not
    /// also need to chase. Staying put makes it findable: the same place every
    /// time, rather than wherever the cursor happened to leave it.
    private var restingPositionInSwiftUICoordinates: CGPoint {
        // Clamped on the way in and out by `OverlayEyeRestingPlace`, so a
        // remembered spot can never put the eye under the menu bar or off the
        // edge of a display that has since been unplugged.
        eyeRestingPlaceInSwiftUICoordinates
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
                    .position(
                        x: cursorPosition.x + horizontalGapFromTheEyeToWhatItSays
                            + (bubbleSize.width / 2),
                        y: cursorPosition.y + 18
                    )
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
                    x: cursorPosition.x + horizontalGapFromTheEyeToWhatItSays
                        + (onboardingVideoPlayerWidth / 2),
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
                    .position(
                        x: cursorPosition.x + horizontalGapFromTheEyeToWhatItSays
                            + (bubbleSize.width / 2),
                        y: cursorPosition.y + 18
                    )
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
                    .position(
                        x: cursorPosition.x + horizontalGapFromTheEyeToWhatItSays
                            + (navigationBubbleSize.width / 2),
                        y: cursorPosition.y + 18
                    )
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
                ZStack {
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
                // THE HIT SHAPE HAS TO AGREE WITH THE WINDOW'S GATE. The gate
                // stops the overlay being click-through over a square around
                // the eye; the eye used to hit-test as a circle inscribed in
                // its own smaller frame. In the ring between the two the
                // overlay had already stopped passing clicks through and the
                // eye was not there to take them, so a click landed on nothing
                // at all with nothing drawn to explain why. Both sides now read
                // the one number.
                .frame(
                    width: sideOfTheEyesClickTargetSquare,
                    height: sideOfTheEyesClickTargetSquare
                )
                // The badge rides in the corner of the CLICK SQUARE, which is a
                // few points wider than the eye's disc, so it sits just off the
                // edge of the eye instead of on top of the track. Inside the
                // frame, so it can never widen what the window's gate has to
                // agree with — see `sideLengthOfTheClickTargetSquare`.
                .overlay(alignment: .topTrailing) {
                    if theEyeIsAskingForTheReader {
                        theBadgeThatSaysIrisNeedsYou
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor(isEnabled: theEyeIsClickableRightNow)
            // Dragging the eye moves its home, and the reader keeps it there.
            // `simultaneousGesture` rather than `highPriorityGesture` because a
            // click on the eye is the way into the whole product and must never
            // be swallowed by a gesture that is only *sometimes* meant; the
            // button's action still fires at the end of a drag, and
            // `handleAClickOnTheEye` is what ignores it.
            .simultaneousGesture(theGestureThatMovesTheEyesHome)
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
            .animation(animationForTheEyesPosition, value: cursorPosition)
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
    ///
    /// THE FIFTH ROW, AND WHY IT IS NOT IN THE TABLE. `assistantState` is
    /// written by the CHAT pipeline and nothing else — the on-demand edit flow
    /// never touches it. So while an edit ran, stopped, and waited for the
    /// reader, this returned `.idle` and the eye drew its resting mood. A
    /// reader submitted two edits, was refused both times by the dirty-clone
    /// preflight, dismissed the bar in between, and the eye told him nothing:
    /// "once the response is done loading and needs my intervention, it should
    /// … change the UI to show me it needs my approval." The edit flow's own
    /// state is therefore folded in HERE, under `.idle` — never over a chat
    /// state, because a chat the reader is actually watching outranks a
    /// background edit for the one eye they can see.
    private var eyeMood: IrisEyeMood {
        switch companionManager.assistantState {
        case .idle:
            switch companionManager.attentionTheEyeShouldShow {
            case .nothingToSay:
                return .idle
            case .working:
                // The same spinning track a chat answer gets. From the reader's
                // side an edit being worked on and a question being answered
                // are the same fact: Iris is busy on something of mine.
                return .thinking
            case .needsTheReader:
                // Alert and locked on, with no spin and no idle wander — an eye
                // that has stopped what it was doing and is looking at you.
                return .ready
            }
        case .capturing, .thinking:
            return .thinking
        case .pointing:
            return buddyNavigationMode == .pointingAtTarget ? .done : .ready
        }
    }

    /// Whether the eye is currently asking for the reader, and there is an eye
    /// rather than a gear to ask with.
    ///
    /// Gated on the bar being shut on purpose: while the bar is open the card
    /// itself is on screen a few points below, so a badge would be pointing at
    /// something the reader is already reading.
    private var theEyeIsAskingForTheReader: Bool {
        companionManager.attentionTheEyeShouldShow == .needsTheReader
            && !eyeActivation.theInputBarIsOpen
    }

    /// The one mark that says "Iris needs you" without a notification, a sound,
    /// or a window that takes focus — all three of which were ruled out.
    ///
    /// Amber is the design system's colour for a pending state that wants a
    /// person (`DS.Colors.amber`), it sits in the corner of the eye's click
    /// square rather than on the eye's own disc so it never covers the iris,
    /// and it breathes slowly so it reads as waiting rather than as an error.
    /// It takes no clicks: the whole square is one button, and the thing to
    /// click is the eye.
    private var theBadgeThatSaysIrisNeedsYou: some View {
        Circle()
            .fill(DS.Colors.amber)
            .frame(width: 13, height: 13)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: DS.Colors.amber.opacity(0.65), radius: 5, x: 0, y: 0)
            .scaleEffect(attentionBadgeIsBreathingOut ? 1.0 : 0.76)
            .opacity(attentionBadgeIsBreathingOut ? 1.0 : 0.72)
            .offset(x: 1, y: -1)
            .allowsHitTesting(false)
            .onAppear {
                attentionBadgeIsBreathingOut = false
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    attentionBadgeIsBreathingOut = true
                }
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

    /// Whether the reader currently has hold of the eye. The pointer poll reads
    /// this to keep the overlay's click-through gate open for the whole drag.
    private var theEyeIsBeingDraggedRightNow: Bool {
        eyeHomeWhenTheCurrentDragBegan != nil
    }

    /// Whether the primary mouse button is physically down at this instant.
    /// Read the same permission-free way the pointer itself is read, and used
    /// only to prove that a drag is over.
    private static var theMouseButtonThatDragsIsDown: Bool {
        NSEvent.pressedMouseButtons & 0x1 != 0
    }

    /// How a change to the eye's position is animated.
    ///
    /// A spring while the eye is moving under its own rules; nothing at all
    /// while the reader is dragging it, because an eye that springs a fifth of
    /// a second behind the pointer holding it does not feel picked up — and
    /// nothing during a `[POINT:…]` flight, where the bezier timer sets the
    /// position frame by frame and an implicit animation would fight it.
    private var animationForTheEyesPosition: Animation? {
        guard !theEyeIsBeingDraggedRightNow else { return nil }
        guard buddyNavigationMode == .followingCursor else { return nil }
        return .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
    }

    /// The drag that moves the eye's home — the whole reason the eye can live
    /// anywhere other than the top-left corner.
    ///
    /// `minimumDistance` is a few points of slop so an ordinary click, which
    /// always travels a pixel or two while the button is down, opens the input
    /// bar instead of counting as a move of the eye.
    private var theGestureThatMovesTheEyesHome: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { dragValue in
                // The same conditions that let the eye be clicked let it be
                // dragged: it is at rest, on this screen, and visible.
                guard self.theEyeIsClickableRightNow else { return }
                // Not while the input bar is open. The bar is its own window,
                // placed against the eye at the moment it opened, and it has no
                // way to follow the eye mid-drag — so a draggable gear would
                // just tear the two apart.
                guard !self.eyeActivation.theInputBarIsOpen else { return }

                let homeAtTheStartOfThisDrag =
                    self.eyeHomeWhenTheCurrentDragBegan ?? self.eyeRestingPlaceInSwiftUICoordinates
                self.eyeHomeWhenTheCurrentDragBegan = homeAtTheStartOfThisDrag

                self.moveTheEyesHome(to: CGPoint(
                    x: homeAtTheStartOfThisDrag.x + dragValue.translation.width,
                    y: homeAtTheStartOfThisDrag.y + dragValue.translation.height
                ))
                // Stamped here rather than in `onEnded` because the button's own
                // action fires on the mouse-up that ends the drag, and this has
                // to already be true by then for that click to be ignored.
                self.whenTheEyeWasLastDragged = ProcessInfo.processInfo.systemUptime
            }
            .onEnded { dragValue in
                // No recorded start means this drag never got past the guards
                // above — it was a click, or the bar was open. Nothing moved,
                // so nothing is remembered.
                guard let homeAtTheStartOfThisDrag = self.eyeHomeWhenTheCurrentDragBegan else {
                    return
                }

                self.moveTheEyesHome(to: CGPoint(
                    x: homeAtTheStartOfThisDrag.x + dragValue.translation.width,
                    y: homeAtTheStartOfThisDrag.y + dragValue.translation.height
                ))
                self.whenTheEyeWasLastDragged = ProcessInfo.processInfo.systemUptime
                // Clearing this last: it is what holds the click-through gate
                // open, and the drag is not over until the eye has landed.
                self.eyeHomeWhenTheCurrentDragBegan = nil

                // Written once, when the reader lets go, rather than sixty
                // times a second on the way across the screen.
                OverlayEyeRestingPlace.shared.remember(
                    self.eyeRestingPlaceInSwiftUICoordinates,
                    onScreenOfSize: self.screenFrame.size
                )
            }
    }

    /// Puts the eye's home at a point the reader dragged it to.
    ///
    /// Clamped by the same rule that will clamp it when it is read back at the
    /// next launch, so what the reader sees during the drag is exactly what is
    /// remembered — the eye stops at the edge under their pointer rather than
    /// following it off the screen and reappearing somewhere else later.
    private func moveTheEyesHome(to placeTheReaderDraggedItTo: CGPoint) {
        let clampedPlace = OverlayEyeRestingPlace.clamped(
            placeTheReaderDraggedItTo,
            toScreenOfSize: screenFrame.size
        )
        eyeRestingPlaceInSwiftUICoordinates = clampedPlace
        // The pointer poll would pull the eye onto its new home on the next
        // tick anyway; moving it now is what makes it track the drag rather
        // than trail a frame behind it.
        cursorPosition = clampedPlace
    }

    /// One click target, two meanings, decided by `OverlayEyeActivation`.
    private func handleAClickOnTheEye() {
        // A click that arrives on the heels of a drag IS the mouse-up that
        // ended that drag: the pointer never left the eye, because the eye was
        // travelling with it. Acting on it would mean the reader could not move
        // the eye without also being handed a bar they did not ask for.
        if let whenTheEyeWasLastDragged,
           ProcessInfo.processInfo.systemUptime - whenTheEyeWasLastDragged
               < Self.howLongAClickIsIgnoredAfterTheEyeIsDragged {
            return
        }
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

    /// Internal rather than private ON PURPOSE: this is the ONLY path a click on
    /// the eye or the summon hotkey takes into the bar, and both things it does
    /// here — answering the attention signal, and raising the bar — were
    /// previously provable only by a test that called each half by hand. That
    /// left the ORDER and the CALL itself uncovered: deleting
    /// `theReaderIsLookingAtTheEyesBar()` below kept every test green while the
    /// badge stayed lit for the rest of the session, which is the exact failure
    /// this line exists to prevent. `Test7ForeignEditWiringTests` now calls this
    /// function.
    func presentTheInputBar() {
        guard let inputBarPanelManager else { return }
        // THE OTHER HALF OF THE BADGE. Opening the bar puts the card that was
        // waiting directly in front of the reader — `OnDemandEditCard` renders
        // at the top of the bar for every phase except `.describe` — so the
        // thing that was asking is answered by the act of looking, and the
        // badge comes down. Without this it would stay lit forever on a
        // terminal phase and stop meaning anything.
        companionManager.theReaderIsLookingAtTheEyesBar()
        inputBarPanelManager.showInputBar(
            forEyeAtInteractionGeometry: interactionGeometryForTheEyeWhereItSitsNow,
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

            // A DRAG CANNOT OUTLIVE THE MOUSE BUTTON THAT STARTED IT. SwiftUI
            // does not promise `onEnded` for a gesture that is interrupted
            // rather than finished, and a drag latch left set would hold the
            // gate below open over the WHOLE screen with nothing drawn to
            // explain why the reader's own apps had stopped taking clicks. The
            // button being up is the one fact that settles it, so it is checked
            // sixty times a second rather than trusted to the gesture.
            if self.theEyeIsBeingDraggedRightNow && !Self.theMouseButtonThatDragsIsDown {
                self.eyeHomeWhenTheCurrentDragBegan = nil
                // Remembered here too: a drag that ended without an `onEnded`
                // still moved the eye, and the reader would not accept it
                // sliding back to where it was at the next launch.
                OverlayEyeRestingPlace.shared.remember(
                    self.eyeRestingPlaceInSwiftUICoordinates,
                    onScreenOfSize: self.screenFrame.size
                )
            }

            // THE CLICK-THROUGH GATE, re-decided sixty times a second.
            //
            // The overlay covers the whole screen and sits above everything, so
            // for all but one small square of it the only correct answer is
            // "let the click through to whatever is underneath". The square is
            // the eye, and only while the eye is actually there to be clicked.
            // `setWhetherTheOverlayAcceptsMouseEvents` no-ops unless the answer
            // has changed, so this poll costs nothing while the pointer is off
            // in the user's own app — which is nearly always.
            let thePointerIsOverTheEye = self.interactionGeometryForTheEyeWhereItSitsNow
                .theOverlayShouldAcceptMouseEvents(
                    forPointerAtAppKitScreenLocation: mouseLocation,
                    onScreenWithFrame: self.screenFrame
                )
            // A DRAG HOLDS THE GATE OPEN FOR AS LONG AS IT LASTS. This gate is
            // the only reason the overlay receives mouse events at all, so
            // shutting it mid-drag would end the drag on the spot — and the
            // pointer does leave the eye's square during a drag, the moment the
            // clamp stops the eye at a screen edge and the pointer keeps going.
            self.overlayWindowMouseEventGate?.setWhetherTheOverlayAcceptsMouseEvents(
                (thePointerIsOverTheEye || self.theEyeIsBeingDraggedRightNow)
                    && self.theEyeIsClickableRightNow
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
//
// It also KEEPS them on those screens. Each overlay is built for one display
// and bakes that display's frame into its SwiftUI content, so when the set of
// displays changes the overlays have to be rebuilt — and until Sep 2 2026
// nothing did that. See `ScreenLayoutCompliance` for the incident: an overlay
// built for an unplugged 3440x1440 monitor was left covering the built-in
// display with its top edge 458pt above it, and the eye drawn off-screen.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []

    /// One per overlay window. Held here rather than only inside the SwiftUI
    /// view so the bars can be taken down when the overlay goes away, and so
    /// the panels are not deallocated out from under themselves.
    private var inputBarPanelManagers: [OverlayEyeInputBarPanelManager] = []

    var hasShownOverlayBefore = false

    /// The frames of the screens the overlays on screen were built for, in
    /// `NSScreen.screens` order — one per overlay window. What the compliance
    /// check compares the connected displays against.
    private var screenFramesTheOverlaysWereBuiltFor: [CGRect] = []

    /// Who the overlays are shown for, kept so they can be rebuilt for a new
    /// display layout without anyone having to call `showOverlay` again. Weak:
    /// the `CompanionManager` owns this manager, never the other way round.
    private weak var companionManagerTheOverlayIsShownFor: CompanionManager?

    /// True from `showOverlay` until `hideOverlay` or `fadeOutAndHideOverlay`.
    /// The compliance check acts only while this is true — an overlay the app
    /// hid on purpose must never be brought back by a display change.
    private var theOverlayIsMeantToBeShowing = false

    private var screenLayoutChangeObserver: NSObjectProtocol?
    private var screenLayoutAuditTimer: Timer?

    init() {
        // The fast path: AppKit says the displays changed.
        screenLayoutChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepTheOverlaysOnTheConnectedScreens(because: "the display configuration changed")
            }
        }

        // The safety net: re-check on a cadence whether or not anything said
        // so. Idempotent and nearly free — see `ScreenLayoutCompliance`.
        screenLayoutAuditTimer = Timer.scheduledTimer(
            withTimeInterval: ScreenLayoutCompliance.auditInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepTheOverlaysOnTheConnectedScreens(because: "the periodic audit found a mismatch")
            }
        }
    }

    deinit {
        if let screenLayoutChangeObserver {
            NotificationCenter.default.removeObserver(screenLayoutChangeObserver)
        }
        screenLayoutAuditTimer?.invalidate()
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        companionManagerTheOverlayIsShownFor = companionManager
        screenFramesTheOverlaysWereBuiltFor = screens.map(\.frame)
        theOverlayIsMeantToBeShowing = true

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
        theOverlayIsMeantToBeShowing = false
        screenFramesTheOverlaysWereBuiltFor = []
        takeDownEveryInputBar()
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    // MARK: - Keeping the overlays on the screens that exist

    /// THE COMPLIANCE CHECK. Compares the displays connected right now against
    /// the ones the overlays were built for and where the overlay windows
    /// actually are, and does the least that makes them match again:
    /// nothing, a `setFrame` for a window the window server moved, or a full
    /// rebuild for a changed display set. Runs on every
    /// `didChangeScreenParametersNotification` and on the audit timer, and is
    /// safe to run as often as either likes — a layout that already complies
    /// costs one array comparison.
    ///
    /// A rebuild goes through `showOverlay` with `hasShownOverlayBefore`
    /// already true, so the welcome animation never replays, and the eye
    /// re-seeds from `OverlayEyeRestingPlace` clamped to the NEW screen size —
    /// which is what puts it back in view after a monitor is unplugged.
    func keepTheOverlaysOnTheConnectedScreens(because reasonForTheCheck: String) {
        guard theOverlayIsMeantToBeShowing else { return }

        let screensConnectedNow = NSScreen.screens
        let verdict = ScreenLayoutCompliance.verdict(
            overlaysWereBuiltForScreenFrames: screenFramesTheOverlaysWereBuiltFor,
            currentScreenFrames: screensConnectedNow.map(\.frame),
            liveOverlayWindowFrames: overlayWindows.map(\.frame)
        )

        switch verdict {
        case .everyOverlayFitsItsScreen, .noScreenToShowOn:
            return

        case .putTheseOverlaysBackOnTheirScreens(let framesByOverlayIndex):
            for (overlayIndex, frameTheOverlayShouldHave) in framesByOverlayIndex {
                guard overlayIndex < overlayWindows.count else { continue }
                irisTrace(
                    "screen-layout: overlay \(overlayIndex) was at \(overlayWindows[overlayIndex].frame), "
                        + "moving it back to \(frameTheOverlayShouldHave) — \(reasonForTheCheck)"
                )
                overlayWindows[overlayIndex].setFrame(frameTheOverlayShouldHave, display: true)
            }

        case .rebuildTheOverlaysForTheCurrentScreens:
            guard let companionManager = companionManagerTheOverlayIsShownFor else { return }
            irisTrace(
                "screen-layout: overlays were built for \(screenFramesTheOverlaysWereBuiltFor) but the "
                    + "screens are now \(screensConnectedNow.map(\.frame)) — rebuilding, \(reasonForTheCheck)"
            )
            showOverlay(onScreens: screensConnectedNow, companionManager: companionManager)
        }
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
        theOverlayIsMeantToBeShowing = false
        screenFramesTheOverlaysWereBuiltFor = []
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
