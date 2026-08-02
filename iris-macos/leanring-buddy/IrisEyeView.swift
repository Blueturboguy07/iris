//
//  IrisEyeView.swift
//  leanring-buddy
//
//  The Iris identity mark: a small living eye, transcribed from the Tauri
//  pill's `.iris-eye` styles (`iris-desktop/ui/styles.css`). A 25pt ring
//  holds a dark shell, a pale lid that blinks every few seconds, a periwinkle
//  iris that can glance around, and a satellite dot that reports mood —
//  green while watching or done, dim otherwise. The lid closes to a slit
//  while paused, and the ring tints periwinkle while thinking.
//

import SwiftUI

struct IrisEyeView: View {
    enum Mood {
        case idle
        case watching
        case thinking
        case paused
        case done
    }

    var mood: Mood = .idle

    /// Where the iris looks, in points, clamped to ±2 like the CSS
    /// `--look-x/--look-y` custom properties.
    var look: CGSize = .zero

    /// Guide progress from 0 to 1. When set, the outer ring becomes a
    /// progress ring instead of a plain halo.
    var progress: Double? = nil

    /// Blink state, driven by the timer task below.
    @State private var lidIsClosedForABlink = false

    private var lidHeight: CGFloat {
        if mood == .paused { return 2 }
        return lidIsClosedForABlink ? 2 : 10
    }

    private var irisColor: Color {
        mood == .done ? DS.Colors.green : DS.Colors.accent
    }

    private var satelliteColor: Color {
        switch mood {
        case .watching, .done: return DS.Colors.green
        case .idle, .thinking, .paused: return DS.Colors.quiet
        }
    }

    private var ringColor: Color {
        mood == .thinking ? DS.Colors.accent.opacity(0.34) : Color.white.opacity(0.16)
    }

    private var clampedLook: CGSize {
        CGSize(
            width: min(2, max(-2, look.width)),
            height: min(2, max(-2, look.height))
        )
    }

    var body: some View {
        ZStack {
            // The halo ring (`.iris-eye__progress`).
            Circle()
                .fill(ringColor)
                .frame(width: 25, height: 25)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 23, height: 23)
                    .rotationEffect(.degrees(-90))
                    .animation(DS.Motion.contentIn, value: progress)
            }

            // The dark shell (`.iris-eye__shell`).
            Circle()
                .fill(DS.Colors.eyeShell)
                .frame(width: 21, height: 21)

            // The lid, with the iris clipped inside it (`.iris-eye__lid`).
            ZStack {
                Ellipse()
                    .fill(DS.Colors.eyeLid)

                Circle()
                    .fill(irisColor)
                    .frame(width: 7, height: 7)
                    .overlay(
                        // Pupil and glint (`.iris-eye__pupil`, `.iris-eye__glint`).
                        Circle()
                            .fill(DS.Colors.eyePupil)
                            .frame(width: 3, height: 3)
                            .overlay(
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 1, height: 1)
                                    .offset(x: 1, y: -1)
                            )
                    )
                    .offset(clampedLook)
                    .animation(.linear(duration: 0.1), value: clampedLook)
            }
            .frame(width: 16, height: lidHeight)
            .clipShape(Ellipse())
            .rotationEffect(.degrees(-7))
            .animation(.easeInOut(duration: 0.09), value: lidHeight)

            // The satellite mood dot (`.iris-eye__satellite`).
            Circle()
                .fill(satelliteColor)
                .overlay(
                    Circle()
                        .strokeBorder(DS.Colors.eyeSatelliteRing, lineWidth: 1.5)
                )
                .frame(width: 7, height: 7)
                .offset(x: 9, y: 7)
                .animation(DS.Motion.quick, value: satelliteColor)
        }
        .frame(width: 25, height: 25)
        .task {
            await runTheBlinkLoop()
        }
    }

    /// One blink roughly every 5.6 seconds, like the CSS `blink` keyframes.
    /// Skipped entirely when the user asked the system to reduce motion, and
    /// while paused — a paused eye holds its slit rather than blinking.
    private func runTheBlinkLoop() async {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_600_000_000)
            guard !Task.isCancelled, mood != .paused else { continue }
            lidIsClosedForABlink = true
            try? await Task.sleep(nanoseconds: 120_000_000)
            lidIsClosedForABlink = false
        }
    }
}
