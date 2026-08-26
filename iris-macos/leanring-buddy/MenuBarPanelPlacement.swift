//
//  MenuBarPanelPlacement.swift
//  leanring-buddy
//
//  Where the settings panel sits, and how big, once the reader has moved or
//  resized it.
//
//  The panel was `.borderless` with `isMovableByWindowBackground = false` and a
//  height derived from its own content, so it appeared under the menu bar icon
//  and stayed exactly there forever. A reader reported wanting to "move shit
//  around" and that content was cut off — the second half of that is the
//  missing scroll view, fixed separately; this is the first half.
//
//  Same shape as `OverlayEyeRestingPlace`: `nonisolated`, `UserDefaults`-backed,
//  clamped so a panel can never be dragged somewhere it cannot be dragged back
//  from, and forgettable so "put it back" is one action.
//

import CoreGraphics
import Foundation

/// The reader's own placement for the settings panel, remembered across
/// launches. Absent until they actually move or resize it — until then the
/// panel keeps its old behaviour of hanging under the menu bar icon.
final class MenuBarPanelPlacement: @unchecked Sendable {

    static let shared = MenuBarPanelPlacement()

    private static let originXKey = "iris:panel:originX"
    private static let originYKey = "iris:panel:originY"
    private static let widthKey = "iris:panel:width"
    private static let heightKey = "iris:panel:height"

    /// Narrow enough to read as a dropdown, wide enough for the account rows.
    /// The SwiftUI body was authored at 320.
    static let narrowestWidth: CGFloat = 300
    static let widestWidth: CGFloat = 560
    static let shortestHeight: CGFloat = 260
    static let tallestHeight: CGFloat = 900

    /// How much of the panel must stay on screen. Enough to grab and drag back.
    static let smallestVisibleEdge: CGFloat = 80

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// The size the reader chose, or nil to keep sizing from the content.
    var storedSize: CGSize? {
        guard userDefaults.object(forKey: Self.widthKey) != nil,
              userDefaults.object(forKey: Self.heightKey) != nil else { return nil }
        return Self.clampedSize(CGSize(
            width: userDefaults.double(forKey: Self.widthKey),
            height: userDefaults.double(forKey: Self.heightKey)
        ))
    }

    /// The origin the reader dragged to, or nil to keep hanging off the menu
    /// bar icon.
    var storedOrigin: CGPoint? {
        guard userDefaults.object(forKey: Self.originXKey) != nil,
              userDefaults.object(forKey: Self.originYKey) != nil else { return nil }
        return CGPoint(
            x: userDefaults.double(forKey: Self.originXKey),
            y: userDefaults.double(forKey: Self.originYKey)
        )
    }

    /// True once the reader has taken over placement. Until then the panel
    /// positions itself, which is the behaviour everyone is used to.
    var readerHasPlacedItThemselves: Bool { storedOrigin != nil }

    func remember(origin: CGPoint) {
        userDefaults.set(Double(origin.x), forKey: Self.originXKey)
        userDefaults.set(Double(origin.y), forKey: Self.originYKey)
    }

    func remember(size: CGSize) {
        let clamped = Self.clampedSize(size)
        userDefaults.set(Double(clamped.width), forKey: Self.widthKey)
        userDefaults.set(Double(clamped.height), forKey: Self.heightKey)
    }

    /// Put it back under the menu bar icon at its natural size.
    func forget() {
        for key in [Self.originXKey, Self.originYKey, Self.widthKey, Self.heightKey] {
            userDefaults.removeObject(forKey: key)
        }
    }

    static func clampedSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, narrowestWidth), widestWidth),
            height: min(max(size.height, shortestHeight), tallestHeight)
        )
    }

    /// Keeps enough of the panel on a screen to grab it. A panel dragged almost
    /// entirely off an edge — or left on a display that has since been
    /// unplugged — comes back far enough to be reachable.
    static func clampedOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        guard !visibleFrames.isEmpty else { return origin }

        let panelRect = CGRect(origin: origin, size: panelSize)
        let alreadyReachable = visibleFrames.contains { frame in
            frame.intersection(panelRect).width >= smallestVisibleEdge
                && frame.intersection(panelRect).height >= smallestVisibleEdge
        }
        if alreadyReachable { return origin }

        // Pull it back onto whichever screen it is nearest.
        let target = visibleFrames.min(by: { first, second in
            distance(from: origin, to: first) < distance(from: origin, to: second)
        }) ?? visibleFrames[0]
        return CGPoint(
            x: min(max(origin.x, target.minX), target.maxX - smallestVisibleEdge),
            y: min(max(origin.y, target.minY), target.maxY - smallestVisibleEdge)
        )
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}
