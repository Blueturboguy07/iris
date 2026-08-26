//
//  ScreenContainment.swift
//  leanring-buddy
//
//  Whether the pointer is on a given screen.
//
//  `CGRect.contains` is half-open — it accepts `minY <= y < maxY` — so a
//  pointer at the very top row of a display is NOT contained by that display's
//  frame. On a 1512x982 main screen, AppKit reports y = 982 for the top row and
//  `screenFrame.contains` returns false.
//
//  Two visible bugs came out of that one character:
//
//  * The eye rests at the top-LEFT corner. `buddyIsVisibleOnThisScreen` is
//    driven by this test, so moving the pointer up toward the eye — the natural
//    way to reach it — crossed into the one row where the answer flips, and the
//    eye faded to zero opacity and stopped accepting clicks at the same moment.
//    Reported as "it disappears if my cursor gets close to the top left of the
//    eye", which is exactly where it happens and nowhere else.
//
//  * With the pointer on that row, no screen capture is marked as the cursor's,
//    so the assistant's pointing path found no target screen, dropped the point
//    with no log, and left `assistantState` stuck on `.pointing`.
//
//  A screen's top row belongs to that screen. This says so.
//

import CoreGraphics
import Foundation

enum ScreenContainment {

    /// Whether `point` is on a screen with this frame, counting every edge as
    /// part of the screen.
    ///
    /// Displays tile edge to edge, so a point on a shared boundary is genuinely
    /// on both. Callers pick one — the assistant's capture list takes the first
    /// match — and either answer is right; what is not right is neither.
    static func screenFrame(_ frame: CGRect, containsPointer point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }
}
