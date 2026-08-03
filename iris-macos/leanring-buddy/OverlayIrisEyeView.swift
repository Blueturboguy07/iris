//
//  OverlayIrisEyeView.swift
//  leanring-buddy
//
//  Iris's eye, drawn on the screen overlay. This is a transcription of the
//  website's eye — `components/iris/IrisEye.tsx` for the structure and the
//  `.iris-eye*` rules in `app/globals.css` for every measurement — so the
//  thing that follows you around the desktop is recognisably the same
//  creature as the thing on publikhq.com. It replaced a blue triangle, which
//  was a cursor, not a companion.
//
//  The layering matches the website exactly:
//      track  → a ring carrying the conic progress arc
//      shell  → the dark eyeball
//      lid    → the pale, blinking, slightly tilted opening (it clips)
//      iris   → the striated blue disc that slides toward whatever is watched
//      pupil  → the ink centre
//      glint  → the highlight that makes it read as wet rather than printed
//
//  Where a `DS` token already carries the value it is used in preference to
//  the raw CSS hex, per the design system's own rule.
//

import AppKit
import SwiftUI

// MARK: - Mood

/// The four moods the website's `IrisEye` React component understands.
/// Named case-for-case with the TypeScript union in
/// `components/iris/IrisEye.tsx` so the two can be compared without a
/// translation table in between.
enum IrisEyeMood {
    /// Resting. Blinks, and wanders when nothing is being watched.
    case idle
    /// Alert and locked on to something, but not working. No spin, no wander.
    case ready
    /// Working. The track spins and the eye holds still — a blink in the
    /// middle of a thought reads as a rendering glitch rather than as life.
    case thinking
    /// Arrived. The iris turns green, the way the site marks a finished step.
    case done
}

// MARK: - Which thing the iris is following

/// The two things the iris can be following at any moment.
enum IrisEyeGazeSource: Equatable {
    /// The real pointer. Wins whenever the pointer has moved recently,
    /// because a live eye that ignores a moving mouse looks broken.
    case pointer
    /// The website's `iris-look` keyframes — a slow, aimless wander. Only
    /// used once the pointer has been sitting still long enough that
    /// following it would look like a frozen frame.
    case idleWander
}

/// Remembers when the pointer last actually moved, so the eye knows whether
/// to keep watching it or to fall back to the idle wander.
///
/// Deliberately clock-free: every method is handed the timestamp to judge
/// against rather than reading one, so a test can move time forward without
/// sleeping through it.
struct IrisEyeGazeTracker {

    /// How long the pointer has to sit still before the eye stops staring at
    /// it and starts wandering. Long enough that ordinary pauses mid-gesture
    /// do not trigger it.
    static let secondsOfStillnessBeforeTheIdleWanderResumes: TimeInterval = 3.0

    /// Sub-point jitter is a hand resting on a mouse, not a deliberate move,
    /// and must not be able to hold the eye out of its idle wander forever.
    static let pointerMovementThatCountsAsAMoveInPoints: CGFloat = 1.0

    private(set) var lastObservedPointerLocation: CGPoint
    private(set) var timestampWhenThePointerLastMoved: TimeInterval

    init(pointerLocation: CGPoint, observedAt timestamp: TimeInterval) {
        self.lastObservedPointerLocation = pointerLocation
        self.timestampWhenThePointerLastMoved = timestamp
    }

    /// Records where the pointer is now. A move smaller than the jitter
    /// threshold is intentionally *not* recorded at all — neither the
    /// position nor the timestamp — so that a slow drift still accumulates
    /// until it crosses the threshold and then counts as one real move.
    mutating func observePointer(at pointerLocation: CGPoint, timestamp: TimeInterval) {
        let distanceMovedSinceTheLastRecordedPosition = hypot(
            pointerLocation.x - lastObservedPointerLocation.x,
            pointerLocation.y - lastObservedPointerLocation.y
        )
        guard distanceMovedSinceTheLastRecordedPosition >= Self.pointerMovementThatCountsAsAMoveInPoints else {
            return
        }
        lastObservedPointerLocation = pointerLocation
        timestampWhenThePointerLastMoved = timestamp
    }

    /// Whether the eye should be tracking the pointer or wandering, as of
    /// `timestamp`.
    func gazeSource(at timestamp: TimeInterval) -> IrisEyeGazeSource {
        let secondsSinceThePointerLastMoved = timestamp - timestampWhenThePointerLastMoved
        if secondsSinceThePointerLastMoved >= Self.secondsOfStillnessBeforeTheIdleWanderResumes {
            return .idleWander
        }
        return .pointer
    }
}

// MARK: - Pupil geometry

/// Every measurement the eye is drawn from, and the maths that decides where
/// the iris sits inside the lid.
///
/// COORDINATE SPACES — the one thing in this file that is easy to get wrong
/// and impossible to notice from a screenshot, because an eye that looks the
/// wrong way still looks like an eye.
///
///   * Points handed *in* are in **AppKit screen coordinates**: origin at the
///     bottom-left of the main display, y growing *upward*. That is the space
///     `NSEvent.mouseLocation` reports in, and reading it needs no
///     Accessibility grant, which is why the overlay polls it instead of
///     installing an event tap.
///   * Offsets handed *back* are in **SwiftUI view coordinates**: y growing
///     *downward*, which is what `.offset(_:)` consumes.
///
/// The single y negation that bridges the two lives in
/// `glanceOffsetInSwiftUICoordinates` and nowhere else, so there is exactly
/// one place to get the direction wrong and exactly one place the tests have
/// to pin down.
struct IrisEyePupilGeometry {

    // The proportions below are transcribed from `.iris-eye*` in
    // `app/globals.css`. The absolute pixel values there (a 5px track inset,
    // a 2px shell border) are quoted against the 54px `--md` eye, so they are
    // carried here as fractions of the eye and stay proportional at any size.

    static let trackToShellInsetAsAFractionOfTheEye: CGFloat = 5.0 / 54.0
    static let shellBorderWidthAsAFractionOfTheEye: CGFloat = 2.0 / 54.0
    static let lidWidthAsAFractionOfTheShell: CGFloat = 0.78
    static let lidHeightAsAFractionOfTheShell: CGFloat = 0.58
    static let irisDiameterAsAFractionOfTheLidWidth: CGFloat = 0.56
    static let pupilDiameterAsAFractionOfTheIris: CGFloat = 0.47
    static let pupilGlintDiameterAsAFractionOfThePupil: CGFloat = 0.35

    /// The lid is tilted, exactly as `transform: rotate(-8deg)` tilts it.
    static let lidTiltInDegrees: Double = -8.0

    /// The outer diameter of the whole eye, track included.
    let eyeDiameter: CGFloat

    /// How far away the pointer has to be before the iris is deflected as far
    /// as it will go. Kept small on purpose: what reads as "it is looking at
    /// me" is the *direction*, so the glance saturates quickly and only eases
    /// off when the pointer is almost on top of the eye, where there is no
    /// meaningful direction left to point in.
    let distanceAtWhichTheGlanceReachesItsLimit: CGFloat

    init(eyeDiameter: CGFloat, distanceAtWhichTheGlanceReachesItsLimit: CGFloat = 60) {
        self.eyeDiameter = eyeDiameter
        self.distanceAtWhichTheGlanceReachesItsLimit = distanceAtWhichTheGlanceReachesItsLimit
    }

    // MARK: Derived sizes

    /// `.iris-eye__shell` is `calc(100% - 5px)` — five points off the total,
    /// not five off each side.
    var shellDiameter: CGFloat {
        eyeDiameter - eyeDiameter * Self.trackToShellInsetAsAFractionOfTheEye
    }

    var shellBorderWidth: CGFloat {
        eyeDiameter * Self.shellBorderWidthAsAFractionOfTheEye
    }

    /// `app/globals.css` sets `box-sizing: border-box` globally, so the
    /// shell's border eats into the box its children's percentages resolve
    /// against. The lid is 78%/58% of *this*, not of the shell's outer size.
    var shellContentDiameter: CGFloat {
        max(0, shellDiameter - 2 * shellBorderWidth)
    }

    var lidWidth: CGFloat {
        shellContentDiameter * Self.lidWidthAsAFractionOfTheShell
    }

    var lidHeight: CGFloat {
        shellContentDiameter * Self.lidHeightAsAFractionOfTheShell
    }

    var irisDiameter: CGFloat {
        lidWidth * Self.irisDiameterAsAFractionOfTheLidWidth
    }

    var pupilDiameter: CGFloat {
        irisDiameter * Self.pupilDiameterAsAFractionOfTheIris
    }

    var pupilGlintDiameter: CGFloat {
        pupilDiameter * Self.pupilGlintDiameterAsAFractionOfThePupil
    }

    // MARK: How far the glance may travel

    // The clamp is stated in terms of the *pupil*, not the iris. A real eye
    // slides its iris part-way under the lid; what must never leave the
    // opening is the black centre, because a pupil clipped by the lid edge is
    // what reads as the eye popping out of its socket.

    var maximumHorizontalGlanceInPoints: CGFloat {
        max(0, (lidWidth - pupilDiameter) / 2)
    }

    var maximumVerticalGlanceInPoints: CGFloat {
        max(0, (lidHeight - pupilDiameter) / 2)
    }

    // MARK: The glance itself

    /// Where the iris should sit, given where the eye is and what it is
    /// watching. Both points are AppKit screen coordinates; the result is a
    /// SwiftUI offset. See the type's coordinate-space note above.
    func glanceOffsetInSwiftUICoordinates(
        eyeCenterInAppKitScreenCoordinates: CGPoint,
        pointerLocationInAppKitScreenCoordinates: CGPoint
    ) -> CGSize {
        let horizontalDistanceToThePointer =
            pointerLocationInAppKitScreenCoordinates.x - eyeCenterInAppKitScreenCoordinates.x
        // Still in AppKit's sense: positive means the pointer is *above* the
        // eye on screen.
        let verticalDistanceToThePointerGoingUp =
            pointerLocationInAppKitScreenCoordinates.y - eyeCenterInAppKitScreenCoordinates.y

        let distanceToThePointer = hypot(
            horizontalDistanceToThePointer,
            verticalDistanceToThePointerGoingUp
        )

        // A pointer sitting exactly on the eye's centre has no direction to
        // look in, so the eye looks straight ahead. This guard is also what
        // stops the normalisation below from dividing by zero and painting
        // the iris at NaN, which SwiftUI renders as nothing at all.
        guard distanceToThePointer > 0, distanceToThePointer.isFinite else {
            return .zero
        }

        // How far out of its socket the eye is willing to roll for a pointer
        // this far away: nothing at zero distance, everything past the limit.
        let howFarTheGlanceIsExtended = min(
            distanceToThePointer / max(distanceAtWhichTheGlanceReachesItsLimit, 0.0001),
            1
        )

        // THE Y FLIP. AppKit's y grows upward and SwiftUI's grows downward,
        // so a pointer above the eye — a *larger* AppKit y — has to become a
        // *negative* SwiftUI offset for the iris to travel up the screen
        // toward it. Drop this minus sign and the eye looks away from the
        // cursor, mirrored about the horizontal, which is subtle enough on a
        // static screenshot to survive review.
        let horizontalDirection = horizontalDistanceToThePointer / distanceToThePointer
        let verticalDirectionInSwiftUICoordinates = -verticalDistanceToThePointerGoingUp / distanceToThePointer

        let glanceOffset = CGSize(
            width: horizontalDirection * maximumHorizontalGlanceInPoints * howFarTheGlanceIsExtended,
            height: verticalDirectionInSwiftUICoordinates * maximumVerticalGlanceInPoints * howFarTheGlanceIsExtended
        )

        // Already on or inside the ellipse by construction; clamped anyway so
        // that the invariant is enforced in one place rather than inferred
        // from the algebra above.
        return clampedToTheLid(glanceOffset)
    }

    /// Pulls an offset back onto the lid's ellipse if it has escaped it,
    /// keeping its direction. Anything already inside is returned untouched.
    func clampedToTheLid(_ glanceOffset: CGSize) -> CGSize {
        let ellipticalRadius = ellipticalRadius(of: glanceOffset)
        guard ellipticalRadius > 1, ellipticalRadius.isFinite else {
            return glanceOffset
        }
        return CGSize(
            width: glanceOffset.width / ellipticalRadius,
            height: glanceOffset.height / ellipticalRadius
        )
    }

    /// Whether an offset leaves the whole pupil inside the lid. The lid is an
    /// ellipse, so this is one elliptical test rather than two independent
    /// axis comparisons — the corners of the bounding box are outside it.
    func glanceKeepsThePupilInsideTheLid(_ glanceOffset: CGSize) -> Bool {
        let ellipticalRadius = ellipticalRadius(of: glanceOffset)
        // A hair of tolerance: the fully-extended glance lands exactly on the
        // ellipse, and floating point does not always agree that it did.
        return ellipticalRadius.isFinite && ellipticalRadius <= 1.0 + 1e-9
    }

    /// The offset's distance from the centre expressed in units of the lid's
    /// own semi-axes: 1 is on the ellipse, less is inside, more is outside.
    private func ellipticalRadius(of glanceOffset: CGSize) -> CGFloat {
        guard maximumHorizontalGlanceInPoints > 0, maximumVerticalGlanceInPoints > 0 else {
            return 0
        }
        return hypot(
            glanceOffset.width / maximumHorizontalGlanceInPoints,
            glanceOffset.height / maximumVerticalGlanceInPoints
        )
    }

    // MARK: The idle wander

    /// `animation: iris-look 4.8s ease-in-out infinite`.
    static let idleWanderCycleSeconds: TimeInterval = 4.8

    /// The `iris-look` keyframes, verbatim. The translate percentages are of
    /// the iris's own box, so they scale with `irisDiameter`, and they are
    /// already written in CSS's y-grows-downward sense — the same sense as a
    /// SwiftUI offset — so unlike the pointer maths above, nothing is flipped.
    private static let idleWanderKeyframes: [(fractionOfTheCycle: Double, horizontal: Double, vertical: Double)] = [
        (0.00, 0.00, 0.00),
        (0.18, 0.00, 0.00),
        (0.28, 0.18, -0.05),
        (0.44, 0.18, -0.05),
        (0.56, -0.16, 0.08),
        (0.72, -0.16, 0.08),
        (1.00, 0.00, 0.00)
    ]

    /// Where the iris sits during the aimless wander, at a given point on a
    /// monotonically increasing clock.
    func idleWanderOffsetInSwiftUICoordinates(atElapsedSeconds elapsedSeconds: TimeInterval) -> CGSize {
        guard elapsedSeconds.isFinite else { return .zero }

        let secondsIntoTheCurrentCycle = elapsedSeconds.truncatingRemainder(
            dividingBy: Self.idleWanderCycleSeconds
        )
        // `truncatingRemainder` keeps the sign of the dividend, and a clock
        // running backwards is not worth a special case beyond this.
        let positiveSecondsIntoTheCycle = secondsIntoTheCurrentCycle < 0
            ? secondsIntoTheCurrentCycle + Self.idleWanderCycleSeconds
            : secondsIntoTheCurrentCycle
        let fractionOfTheCycle = positiveSecondsIntoTheCycle / Self.idleWanderCycleSeconds

        let keyframes = Self.idleWanderKeyframes
        for keyframeIndex in 1..<keyframes.count {
            let previousKeyframe = keyframes[keyframeIndex - 1]
            let nextKeyframe = keyframes[keyframeIndex]
            guard fractionOfTheCycle <= nextKeyframe.fractionOfTheCycle else { continue }

            let spanBetweenTheKeyframes = nextKeyframe.fractionOfTheCycle - previousKeyframe.fractionOfTheCycle
            let progressBetweenTheKeyframes = spanBetweenTheKeyframes > 0
                ? (fractionOfTheCycle - previousKeyframe.fractionOfTheCycle) / spanBetweenTheKeyframes
                : 0
            // CSS `ease-in-out` between stops; smoothstep is close enough at
            // this size and needs no curve solver.
            let easedProgress = progressBetweenTheKeyframes
                * progressBetweenTheKeyframes
                * (3.0 - 2.0 * progressBetweenTheKeyframes)

            let horizontalFractionOfTheIris = previousKeyframe.horizontal
                + (nextKeyframe.horizontal - previousKeyframe.horizontal) * easedProgress
            let verticalFractionOfTheIris = previousKeyframe.vertical
                + (nextKeyframe.vertical - previousKeyframe.vertical) * easedProgress

            return clampedToTheLid(CGSize(
                width: irisDiameter * horizontalFractionOfTheIris,
                height: irisDiameter * verticalFractionOfTheIris
            ))
        }

        return .zero
    }
}

// MARK: - The view

/// The eye itself. It draws only what it is told: the caller owns where the
/// iris is looking, because only the caller knows where on the screen the eye
/// currently sits.
struct OverlayIrisEyeView: View {

    let geometry: IrisEyePupilGeometry

    let mood: IrisEyeMood

    /// Where the iris sits relative to the centre of the lid, in SwiftUI
    /// points.
    let glanceOffset: CGSize

    /// 0…1, drawn as the conic arc on the track — the website's
    /// `--iris-progress`.
    var progress: Double = 0

    @State private var lidIsClosedForABlink = false
    @State private var trackRotationDegrees: Double = 0

    // MARK: Cadence, transcribed from the CSS

    /// `animation: iris-blink 5.2s cubic-bezier(.2,.7,.2,1) infinite`.
    private static let blinkCycleSeconds: TimeInterval = 5.2

    /// The two moments in the cycle where the `iris-blink` keyframes pinch the
    /// lid shut — 46% and 94%.
    private static let blinkMomentsAsFractionsOfTheCycle: [Double] = [0.46, 0.94]

    /// The keyframes give the lid 2% of the cycle to close and 2% to reopen.
    private static let blinkHalfDurationSeconds: TimeInterval = 0.02 * blinkCycleSeconds

    /// `iris-blink` squashes the lid to `scaleY(.08)`, not to nothing — a lid
    /// scaled to zero disappears instead of closing.
    private static let lidScaleWhenBlinking: CGFloat = 0.08

    /// `animation: iris-track-spin 2.2s linear infinite`.
    private static let trackSpinDurationSeconds: TimeInterval = 2.2

    /// With no real progress to show, a spinning ring of one flat colour is
    /// indistinguishable from a still one, so the thinking mood always paints
    /// at least this much arc. It is what makes the spin visible, and it is
    /// what the deleted blue spinner used to say.
    private static let arcTheThinkingMoodAlwaysShows: Double = 0.32

    /// The deep end of the website's iris gradient — `--color-electric` in
    /// `app/globals.css`. `DS.Colors.accent` already carries the pale end
    /// (`#6F8CFF`); the deep end has no design-system token because the Tauri
    /// shell the system was transcribed from never drew the striated iris.
    private static let irisGradientDeepBlue = Color(hex: "#315CF5")

    /// One repeat of `repeating-radial-gradient(circle at center, #6f8cff 0
    /// 7%, #315cf5 8% 16%)`.
    private static let irisGradientBandWidth: Double = 0.16

    var body: some View {
        ZStack {
            track
            shell
            lid
        }
        .frame(width: geometry.eyeDiameter, height: geometry.eyeDiameter)
        // `filter: drop-shadow(0 12px 22px rgba(21, 24, 36, 0.18))`, scaled to
        // this eye's size and leaned on slightly harder than the site does,
        // because this one floats over whatever the desktop happens to be
        // showing rather than over a known page background. Only slightly:
        // any more and it stops reading as a shadow and starts reading as a
        // grey smudge the eye is sitting in.
        .shadow(
            color: DS.Colors.eyeShell.opacity(0.3),
            radius: geometry.eyeDiameter * (22.0 / 54.0) / 2,
            x: 0,
            y: geometry.eyeDiameter * (12.0 / 54.0) / 2
        )
        .task(id: moodDrivesTheBlinkLoop) {
            await runTheBlinkLoop()
        }
        .onAppear {
            updateTheTrackSpin(forMood: mood)
        }
        .onChange(of: mood) { _, newMood in
            updateTheTrackSpin(forMood: newMood)
        }
    }

    // MARK: Layers

    /// `.iris-eye__track` — the ring behind everything, carrying the conic
    /// progress arc. The shell covers its middle, which is what turns a
    /// filled circle into a ring.
    private var track: some View {
        Circle()
            .fill(
                AngularGradient(
                    stops: trackGradientStops,
                    center: .center,
                    // A CSS conic gradient starts at twelve o'clock and runs
                    // clockwise; SwiftUI's starts at three.
                    startAngle: .degrees(-90),
                    endAngle: .degrees(270)
                )
            )
            .overlay(
                // `inset 0 0 0 1px rgba(255, 255, 255, 0.25)`.
                Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
            .frame(width: geometry.eyeDiameter, height: geometry.eyeDiameter)
            .rotationEffect(.degrees(trackRotationDegrees))
    }

    private var trackGradientStops: [Gradient.Stop] {
        let unfilledTrack = Color.white.opacity(0.2)
        let filledFraction = max(0, min(1, mood == .thinking
            ? max(progress, Self.arcTheThinkingMoodAlwaysShows)
            : progress))

        guard filledFraction > 0 else {
            return [
                Gradient.Stop(color: unfilledTrack, location: 0),
                Gradient.Stop(color: unfilledTrack, location: 1)
            ]
        }
        return [
            Gradient.Stop(color: Self.irisGradientDeepBlue, location: 0),
            Gradient.Stop(color: Self.irisGradientDeepBlue, location: filledFraction),
            Gradient.Stop(color: unfilledTrack, location: filledFraction),
            Gradient.Stop(color: unfilledTrack, location: 1)
        ]
    }

    /// `.iris-eye__shell` — the dark eyeball. The CSS gives it a 2px border in
    /// the same colour as its own background, so there is nothing to draw for
    /// the border beyond leaving room for it, which `shellContentDiameter`
    /// already does.
    private var shell: some View {
        Circle()
            .fill(DS.Colors.eyeShell)
            .frame(width: geometry.shellDiameter, height: geometry.shellDiameter)
    }

    /// `.iris-eye__lid` — the pale opening. It clips, so the iris can slide
    /// part-way under its edge exactly as a real one does.
    private var lid: some View {
        ZStack {
            Ellipse().fill(DS.Colors.eyeLid)
            iris.offset(glanceOffset)
        }
        .frame(width: geometry.lidWidth, height: geometry.lidHeight)
        .clipShape(Ellipse())
        // CSS reads `rotate(-8deg) scaleY(...)`, which applies the scale
        // first in the lid's own space and then the tilt. SwiftUI applies
        // modifiers innermost-first, so this order is the same order.
        .scaleEffect(
            x: 1,
            y: lidIsClosedForABlink ? Self.lidScaleWhenBlinking : 1,
            anchor: .center
        )
        .rotationEffect(.degrees(IrisEyePupilGeometry.lidTiltInDegrees))
    }

    /// `.iris-eye__iris` — the striated blue disc, or a flat green one once
    /// the mood is `done`, the way the site marks something finished.
    private var iris: some View {
        Circle()
            .fill(irisFill)
            .frame(width: geometry.irisDiameter, height: geometry.irisDiameter)
            .overlay(irisGlint)
            .overlay(
                // `inset 0 0 0 1px rgba(21, 24, 36, 0.28)`.
                Circle().strokeBorder(DS.Colors.eyeShell.opacity(0.28), lineWidth: 1)
            )
            .overlay(pupil)
            .animation(.linear(duration: 0.05), value: glanceOffset)
    }

    private var irisFill: AnyShapeStyle {
        if mood == .done {
            // `.iris-eye--done .iris-eye__iris { background: var(--color-grass) }`,
            // taken from the design system's green rather than the raw hex.
            return AnyShapeStyle(DS.Colors.green)
        }
        return AnyShapeStyle(
            RadialGradient(
                stops: irisGradientStops,
                center: .center,
                startRadius: 0,
                endRadius: geometry.irisDiameter / 2
            )
        )
    }

    /// `repeating-radial-gradient(circle at center, #6f8cff 0 7%, #315cf5 8%
    /// 16%)`, unrolled into the concentric bands SwiftUI wants spelled out.
    private var irisGradientStops: [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        var bandStart: Double = 0
        while bandStart < 1 {
            stops.append(Gradient.Stop(color: DS.Colors.accent, location: min(bandStart, 1)))
            stops.append(Gradient.Stop(color: DS.Colors.accent, location: min(bandStart + 0.07, 1)))
            stops.append(Gradient.Stop(color: Self.irisGradientDeepBlue, location: min(bandStart + 0.08, 1)))
            stops.append(Gradient.Stop(color: Self.irisGradientDeepBlue, location: min(bandStart + 0.16, 1)))
            bandStart += Self.irisGradientBandWidth
        }
        return stops
    }

    /// `radial-gradient(circle at 60% 25%, rgba(255,255,255,.8) 0 6%,
    /// transparent 7%)` — the small highlight on the iris itself, distinct
    /// from the harder glint on the pupil.
    private var irisGlint: some View {
        let glintDiameter = geometry.irisDiameter * 0.12
        return Circle()
            .fill(Color.white.opacity(0.8))
            .frame(width: glintDiameter, height: glintDiameter)
            .position(
                x: geometry.irisDiameter * 0.6,
                y: geometry.irisDiameter * 0.25
            )
    }

    /// `.iris-eye__pupil` and the `.iris-eye__glint` sitting inside it.
    private var pupil: some View {
        Circle()
            .fill(DS.Colors.eyePupil)
            .frame(width: geometry.pupilDiameter, height: geometry.pupilDiameter)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .frame(width: geometry.pupilGlintDiameter, height: geometry.pupilGlintDiameter)
                    .position(
                        // `right: 5%; top: 4%` of the pupil, converted from
                        // CSS edge insets to the centre point SwiftUI wants.
                        x: geometry.pupilDiameter * 0.95 - geometry.pupilGlintDiameter / 2,
                        y: geometry.pupilDiameter * 0.04 + geometry.pupilGlintDiameter / 2
                    )
            )
    }

    // MARK: Blinking

    /// The blink loop only cares whether the eye is thinking, so restarting it
    /// on that alone avoids resetting the cadence every time the mood shuffles
    /// between the three non-thinking moods.
    private var moodDrivesTheBlinkLoop: Bool {
        mood == .thinking
    }

    /// Two blinks per 5.2 second cycle, at the same two moments the
    /// `iris-blink` keyframes pinch the lid.
    ///
    /// The eye does not blink at all while thinking: a lid snapping shut in
    /// the middle of a spinning progress ring reads as a dropped frame rather
    /// than as a living thing, so the loop simply does not run in that mood.
    private func runTheBlinkLoop() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard mood != .thinking else { return }

        var fractionOfTheCycleAlreadyWaited: Double = 0
        while !Task.isCancelled {
            for blinkMoment in Self.blinkMomentsAsFractionsOfTheCycle {
                let secondsUntilThisBlink =
                    (blinkMoment - fractionOfTheCycleAlreadyWaited) * Self.blinkCycleSeconds
                fractionOfTheCycleAlreadyWaited = blinkMoment

                await sleepForSeconds(secondsUntilThisBlink)
                guard !Task.isCancelled else { return }

                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: Self.blinkHalfDurationSeconds)) {
                    lidIsClosedForABlink = true
                }
                await sleepForSeconds(Self.blinkHalfDurationSeconds)
                guard !Task.isCancelled else { return }

                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: Self.blinkHalfDurationSeconds)) {
                    lidIsClosedForABlink = false
                }
                await sleepForSeconds(Self.blinkHalfDurationSeconds)
            }

            let secondsLeftInTheCycle = (1.0 - fractionOfTheCycleAlreadyWaited) * Self.blinkCycleSeconds
            fractionOfTheCycleAlreadyWaited = 0
            await sleepForSeconds(secondsLeftInTheCycle)
        }
    }

    private func sleepForSeconds(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Track spin

    /// `.iris-eye--thinking .iris-eye__track { animation: iris-track-spin }`.
    /// Started and stopped by hand rather than by a conditional `.animation`
    /// modifier, because a `repeatForever` animation attached conditionally
    /// keeps running after the condition flips.
    private func updateTheTrackSpin(forMood moodToRender: IrisEyeMood) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        if moodToRender == .thinking {
            trackRotationDegrees = 0
            withAnimation(.linear(duration: Self.trackSpinDurationSeconds).repeatForever(autoreverses: false)) {
                trackRotationDegrees = 360
            }
        } else {
            withAnimation(.linear(duration: 0.2)) {
                trackRotationDegrees = 0
            }
        }
    }
}

// MARK: - The settings affordance

/// What the eye turns into while the input bar is open: a gear, in the same
/// place, at the same size, wearing the same dark disc and hairline ring the
/// eye wears.
///
/// The silhouette is deliberately identical — same outer diameter, same shell
/// colour, same drop shadow — so the swap reads as one object changing what it
/// offers rather than as one object being replaced by a different one.
struct OverlaySettingsGearView: View {

    let geometry: IrisEyePupilGeometry

    var body: some View {
        ZStack {
            // The eye's track, unrotated and unfilled: the ring is what makes
            // the two states obviously the same object.
            Circle()
                .fill(Color.white.opacity(0.2))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                .frame(width: geometry.eyeDiameter, height: geometry.eyeDiameter)

            Circle()
                .fill(DS.Colors.eyeShell)
                .frame(width: geometry.shellDiameter, height: geometry.shellDiameter)

            Image(systemName: "gearshape.fill")
                .font(.system(size: geometry.shellContentDiameter * 0.52, weight: .semibold))
                // The lid's pale off-white rather than pure white, so the gear
                // is made of the same material the eye's opening is.
                .foregroundColor(DS.Colors.eyeLid)
        }
        .frame(width: geometry.eyeDiameter, height: geometry.eyeDiameter)
        // The same shadow `OverlayIrisEyeView` carries, so nothing about the
        // object's footprint changes when the affordance does.
        .shadow(
            color: DS.Colors.eyeShell.opacity(0.3),
            radius: geometry.eyeDiameter * (22.0 / 54.0) / 2,
            x: 0,
            y: geometry.eyeDiameter * (12.0 / 54.0) / 2
        )
    }
}
