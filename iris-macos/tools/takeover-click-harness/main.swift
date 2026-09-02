//
//  main.swift — the takeover click harness
//  tools/takeover-click-harness
//
//  Drives the REAL `GuideAutopilotTakeoverController` in `.surfacedToReader`
//  (the state that draws the real "Your turn" row with "Try again" and
//  "Continue past it") and posts REAL `CGEvent`s through the window server at
//  the controls the Test-8 reader named as broken:
//
//    "Hit try again, the button doesn't work though. Continue past it button
//     not working either, it is just moving the terminal around."
//
//  It is the OUT-OF-BAND half of `Test8TakeoverControlClickTests`: the unit
//  test observes the same actions firing in-process (a windowed `NSEvent`
//  through the panel's own `sendEvent`, which needs no Accessibility grant),
//  and this harness proves it through a genuine hardware-shaped event path — a
//  posted `CGEvent` the window server routes and hit-tests exactly as it does a
//  real click. The founder's bar for a click fix ("a real CGEvent harness")
//  applies here; the unit test is the always-run witness, this is the gold one.
//
//  WHAT IT MEASURES, per reader-named control (Continue past it, Try again):
//    * FIX PRESENT: a drifting click (down at centre, up 4pt away — past the
//      3pt slop a real finger crosses) FIRES that control's action and does NOT
//      move the window. Measured at several drift magnitudes.
//    * UNFIXED (the reported control frames blanked, which is the pre-fix state
//      — the panel has no idea where its buttons are): the same drifting press
//      SLIDES the window and fires nothing. This is the repro; it must fail
//      without the fix and pass with it.
//
//  REQUIREMENTS: a real login GUI session that is AWAKE and UNLOCKED, and an
//  Accessibility grant for the process that launches it (so `CGEvent.post` is
//  not dropped). A locked screen's login shield intercepts every posted event —
//  the harness prints `locked=true` and the window-server path measures nothing.
//
//  RUN: tools/takeover-click-harness/run.sh   (compiles against the app sources)
//

import AppKit
import SwiftUI

@MainActor
final class SurfacedRunner: ObservableObject, AutopilotTerminalPresenting {
    @Published var state: GuideAutopilotState = .surfacedToReader(
        diagnosis: "Iris could not finish this step on its own.",
        failingCommand: "cargo build"
    )
    @Published var transcript: [GuideAutopilotTranscriptEntry] = [
        .stepHeading(stepTitle: "Build the app", stepNumber: 3, totalSteps: 6),
        .commandFromTheGuide(text: "cargo build --release"),
        .output(line: "error: could not compile `whimprflow`"),
        .exitStatus(code: 101, duration: 3.2)
    ]
    @Published var isExecutingACommand: Bool = false
}

@MainActor
final class Harness {
    var retryFired = false
    var continueFired = false
    var escapeFired = false

    let controller = GuideAutopilotTakeoverController()
    let runner = SurfacedRunner()
    var terminal: GuideAutopilotTakeoverTerminalPanel!

    func present() {
        controller.present(
            runner: runner,
            onApproveRiskyCommand: {}, onSkipRiskyCommand: {},
            onRetrySurfacedStep: { [weak self] in self?.retryFired = true },
            onContinuePastSurfacedStep: { [weak self] in self?.continueFired = true },
            onReaderFinishedManualStep: {},
            onEscapeHatch: { [weak self] in self?.escapeFired = true }
        )
        terminal = NSApplication.shared.windows
            .compactMap { $0 as? GuideAutopilotTakeoverTerminalPanel }.first
    }

    var globalTop: CGFloat { NSScreen.screens.map { $0.frame.maxY }.max() ?? 982 }

    // A control-view point (top-left origin, y down) -> a CGEvent screen point
    // (top-left origin). The frames are `.global`, i.e. the hosting view that IS
    // the window content view.
    func toCG(contentX: CGFloat, contentY: CGFloat) -> CGPoint {
        let windowY = terminal.frame.height - contentY
        return CGPoint(x: terminal.frame.minX + contentX, y: globalTop - (terminal.frame.minY + windowY))
    }

    func post(_ type: CGEventType, _ point: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
            .post(tap: .cgSessionEventTap)
    }

    // The panel's own predicate, so the harness can report whether the press it
    // is about to post is one the panel WILL treat as landing on a control.
    func pressLandsOnAControl(contentX: CGFloat, contentY: CGFloat) -> Bool {
        let pressInWindow = CGPoint(x: contentX, y: terminal.frame.height - contentY)
        return GuideAutopilotTakeoverTerminalPanel.pressLandsOnAControl(
            pressInWindow, windowHeight: terminal.frame.height, controls: terminal.interactiveControlFrames)
    }

    func driftingClick(onControlFrame frame: CGRect, driftX: CGFloat, driftY: CGFloat) {
        let down = toCG(contentX: frame.midX, contentY: frame.midY)
        let up = toCG(contentX: frame.midX + driftX, contentY: frame.midY + driftY)
        post(.leftMouseDown, down)
        for step in 1...5 {
            let along = CGFloat(step) / 5
            post(.leftMouseDragged, CGPoint(x: down.x + (up.x - down.x) * along, y: down.y + (up.y - down.y) * along))
        }
        post(.leftMouseUp, up)
    }

    func resetFlags() { retryFired = false; continueFired = false; escapeFired = false }
    func firedName() -> String {
        retryFired ? "retry" : continueFired ? "continue" : escapeFired ? "escape" : "none"
    }
    static func locked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int == 1
    }
}

setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

@MainActor func after(_ delay: Double, _ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { block() }
}

@MainActor final class Driver {
    let harness = Harness()
    var continueFrame = CGRect.zero
    var retryFrame = CGRect.zero
    var passedFix = true
    var passedRepro = true

    func start() {
        harness.present()
        guard let terminal = harness.terminal else { print("RESULT no-terminal"); exit(2) }
        app.activate(ignoringOtherApps: true)
        after(6.0) {
            if Harness.locked() {
                print("RESULT blocked-screen-locked — unlock the session and re-run; the login shield eats posted events")
                exit(5)
            }
            let below = terminal.interactiveControlFrames.filter { $0.minY >= 24 }.sorted { $0.minX < $1.minX }
            print("INFO totalControls=\(terminal.interactiveControlFrames.count) belowStrip=\(below.count)")
            guard below.count >= 2 else { print("RESULT frames-missing"); exit(3) }
            self.continueFrame = below.first!   // left = Continue past it
            self.retryFrame = below.last!       // right = Try again
            self.fix("continue", self.continueFrame, 0)
        }
    }

    // FIX PRESENT: a drifting click fires the action, window stays put.
    func fix(_ name: String, _ frame: CGRect, _ stage: Int) {
        let drifts: [(CGFloat, CGFloat)] = [(4, 4), (6, 0), (0, 4), (10, 3)]
        let terminal = harness.terminal!
        if stage >= drifts.count {
            if name == "continue" { after(0.3) { self.fix("retry", self.retryFrame, 0) } }
            else { after(0.3) { self.repro("continue", self.continueFrame) } }
            return
        }
        let (driftX, driftY) = drifts[stage]
        harness.resetFlags()
        let before = terminal.frame.origin
        harness.driftingClick(onControlFrame: frame, driftX: driftX, driftY: driftY)
        after(0.9) {
            let moved = terminal.frame.origin != before
            let fired = self.harness.firedName()
            let ok = (fired == name && !moved)
            if !ok { self.passedFix = false }
            print("FIX \(name) drift=(\(Int(driftX)),\(Int(driftY))) fired=\(fired) movedWindow=\(moved) \(ok ? "OK" : "FAIL")")
            if moved { terminal.setFrameOrigin(before) }
            self.fix(name, frame, stage + 1)
        }
    }

    // UNFIXED: blank the reported frames (the pre-fix state) and the same
    // drifting press must slide the window and fire nothing.
    func repro(_ name: String, _ frame: CGRect) {
        let terminal = harness.terminal!
        let saved = terminal.interactiveControlFrames
        terminal.interactiveControlFrames = []
        harness.resetFlags()
        let before = terminal.frame.origin
        harness.driftingClick(onControlFrame: frame, driftX: 40, driftY: -30)
        after(1.0) {
            let moved = terminal.frame.origin != before
            let fired = self.harness.firedName()
            let ok = (moved && fired == "none")
            if !ok { self.passedRepro = false }
            print("UNFIXED \(name) framesBlanked movedWindow=\(moved) fired=\(fired) \(ok ? "OK" : "FAIL")")
            terminal.interactiveControlFrames = saved
            if moved { terminal.setFrameOrigin(before) }
            if name == "continue" { after(0.3) { self.repro("retry", self.retryFrame) } }
            else { self.finish() }
        }
    }

    func finish() {
        print("RESULT " + (passedFix && passedRepro
            ? "PASS — Try again and Continue past it fire on a drifting real click, and slide-without-firing without the fix"
            : "FAIL"))
        exit(passedFix && passedRepro ? 0 : 1)
    }
}

DispatchQueue.main.async {
    MainActor.assumeIsolated {
        let driver = Driver()
        after(0.1) { driver.start() }
        after(70) { print("RESULT watchdog-timeout"); exit(4) }
    }
}
app.run()
