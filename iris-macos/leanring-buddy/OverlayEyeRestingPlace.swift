//
//  OverlayEyeRestingPlace.swift
//  leanring-buddy
//
//  Where the eye sits when it is not doing anything, and how the reader moves
//  it.
//
//  It used to be one constant — `CGPoint(x: 58, y: 78)`, the top-left corner —
//  with no way to change it. That corner is not neutral for everyone: it is
//  where a lot of people keep the thing they are actually working in, and a
//  reader asked to be able to drag the eye somewhere else and have it stay.
//
//  Deliberately `nonisolated` and backed by `UserDefaults`, the same shape as
//  `AutopilotAutonomyGrant`, so the geometry can read it from any context
//  without an actor hop.
//

import Foundation

/// The eye's home, remembered across launches.
///
/// Stores a point in the SwiftUI coordinate space of the screen the eye rests
/// on — origin top-left, y increasing downward — which is the space
/// `OverlayEyeInteractionGeometry` already works in.
final class OverlayEyeRestingPlace: @unchecked Sendable {

    static let shared = OverlayEyeRestingPlace()

    private static let storedXKey = "iris:overlay:eyeRestingX"
    private static let storedYKey = "iris:overlay:eyeRestingY"

    /// Far enough down and in that a 64pt disc plus its drop shadow clears the
    /// menu bar — including the taller menu bar on a notched display — rather
    /// than tucking under it. This is what the eye used to be pinned to.
    static let defaultPlace = CGPoint(x: 58, y: 78)

    /// The eye must never be draggable somewhere it cannot be dragged back
    /// from: under the menu bar, or off an edge where the visible sliver is too
    /// small to grab.
    static let smallestDistanceFromAnyEdge: CGFloat = 44

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Where the eye rests on a screen of this size, clamped so it is always
    /// reachable. A screen that has shrunk since the position was saved — an
    /// external display unplugged — pulls the eye back into view rather than
    /// stranding it off-screen.
    func restingPlace(onScreenOfSize screenSize: CGSize) -> CGPoint {
        let stored = storedPlace ?? Self.defaultPlace
        return Self.clamped(stored, toScreenOfSize: screenSize)
    }

    /// The raw saved point, or nil when the reader has never moved the eye.
    var storedPlace: CGPoint? {
        guard userDefaults.object(forKey: Self.storedXKey) != nil,
              userDefaults.object(forKey: Self.storedYKey) != nil else { return nil }
        return CGPoint(
            x: userDefaults.double(forKey: Self.storedXKey),
            y: userDefaults.double(forKey: Self.storedYKey)
        )
    }

    /// Remember where the reader put it.
    func remember(_ place: CGPoint, onScreenOfSize screenSize: CGSize) {
        let clamped = Self.clamped(place, toScreenOfSize: screenSize)
        userDefaults.set(Double(clamped.x), forKey: Self.storedXKey)
        userDefaults.set(Double(clamped.y), forKey: Self.storedYKey)
    }

    /// Put it back in the corner.
    func forget() {
        userDefaults.removeObject(forKey: Self.storedXKey)
        userDefaults.removeObject(forKey: Self.storedYKey)
    }

    /// Keeps the eye on screen and out from under the menu bar.
    static func clamped(_ place: CGPoint, toScreenOfSize screenSize: CGSize) -> CGPoint {
        let inset = smallestDistanceFromAnyEdge
        // A screen smaller than two insets has no valid range; centre it rather
        // than produce a nonsense clamp.
        guard screenSize.width > inset * 2, screenSize.height > inset * 2 else {
            return CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        }
        return CGPoint(
            x: min(max(place.x, inset), screenSize.width - inset),
            y: min(max(place.y, inset), screenSize.height - inset)
        )
    }
}
