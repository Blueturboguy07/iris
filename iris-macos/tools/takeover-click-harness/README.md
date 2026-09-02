# takeover-click-harness

The out-of-band, **real-`CGEvent`** witness for the takeover terminal's click
fix — the one the Test-8 reader reported broken:

> "Hit try again, the button doesn't work though. Continue past it button not
> working either, it is just moving the terminal around."

The fix (`GuideAutopilotTakeoverTerminalPanel.pressLandsOnAControl` + the
`TakeoverControlFramesKey` frame report in `GuideAutopilotTerminalView`) makes a
press that lands on a reported control frame go straight to SwiftUI instead of
being held for the window's drag loop, so a drifting click fires the button
instead of sliding the window.

## Why this exists next to the unit test

`Test8TakeoverControlClickTests` proves two things in-process, with no
Accessibility grant, so they run everywhere (incl. CI):

- `clickingAnyControlDoesNotMoveTheTerminal` — a drifting press on a control
  does not move the window.
- `aDriftingClickFiresTheSurfacedRowButtonsActions` — a drifting press on
  "Try again" and "Continue past it" actually **fires that control's action**,
  delivered as a windowed `NSEvent` (the panel's own `windowNumber`, so it takes
  the real `event.window != nil` branch, not the `windowNumber: 0` seam the drag
  tests use to drive travel without a physical mouse).

This harness is the gold-standard other half: it posts genuine `CGEvent`s
through the **window server**, which routes and hit-tests them exactly as it does
a hardware click, against the REAL `GuideAutopilotTakeoverController` and the
REAL buttons. It is the founder's "real CGEvent harness" bar for a click fix.

## What it measures

Per reader-named control (Continue past it, Try again), at several drift
magnitudes past the 3pt slop:

- **FIX PRESENT** — the drifting click fires that control's action and the
  window does not move.
- **UNFIXED** — with the reported control frames blanked (the pre-fix state:
  the panel has no idea where its buttons are), the same drifting press slides
  the window and fires nothing. This is the repro; it fails without the fix.

## Running

```
tools/takeover-click-harness/run.sh
```

`run.sh` compiles every `leanring-buddy/*.swift` (except the `@main` app entry,
which pulls in Sparkle) plus `main.swift`, so the harness drives the real code,
not a replica. A real takeover window appears for a few seconds.

**Requirements:** an awake, **unlocked** login GUI session, and an Accessibility
grant for whatever launches it (so `CGEvent.post` is delivered rather than
dropped). A locked screen's login shield intercepts every posted event; the
harness detects this and prints `RESULT blocked-screen-locked`.

## Last measured result

```
FIX continue drift=(4,4)|(6,0)|(0,4)|(10,3)  fired=continue movedWindow=false  OK
FIX retry    drift=(4,4)|(6,0)|(0,4)|(10,3)  fired=retry    movedWindow=false  OK
UNFIXED continue  framesBlanked  movedWindow=true  fired=none  OK
UNFIXED retry     framesBlanked  movedWindow=true  fired=none  OK
RESULT PASS
```

### A separate observation (not the Test-8 bug)

The red escape-hatch traffic light — which sits in the 24pt title strip, unlike
the two surfaced-row buttons — did **not** fire its action in this harness on
either the real-`CGEvent` path or the in-process `sendEvent` path, even though
`pressLandsOnAControl` is true for it and the window does not move. The two
controls the Test-8 report named (Try again / Continue past it) are unaffected
and verified above. The escape hatch's non-firing in this harness is logged here
as an open item to chase separately, not as part of the Test-8 click fix.
