//
// The "your turn" tray state, as a pure reducer over autopilot events.
//
// The tray (src/main/tray.ts) can't be reached by the vitest suite — it imports
// Electron — so the DECISION of when the tray should say "your turn", and when
// to fire a one-off toast, lives here where it can be unit-tested, exactly the
// `main`/`services` split the rest of the app uses. `tray.ts` is a thin adaptor
// that feeds events in and applies the update to Electron.
//
// A run is "waiting on the reader" whenever it stops on something only a person
// can settle: a sign-in / permission / manual step (`handedToReader`), a command
// that needs one confirm tap (`needsConfirm`), or a failure it surfaced
// (`surfaced`). It is "moving again" the moment the next step starts, a command
// runs, or the run ends. The toast fires only on the TRANSITION into waiting, so
// a burst of events while already waiting does not re-notify.
//

import type { AutopilotEvent } from "./runner";

/// What the adaptor should do to the tray in response to one event.
export type YourTurnUpdate =
  /// The run is now waiting on the reader: set the "your turn" tooltip/menu, and
  /// — when `notify` is true (the transition into waiting) — show a toast.
  | { readonly action: "raise"; readonly instruction: string; readonly notify: boolean }
  /// The run is moving again: clear the "your turn" state.
  | { readonly action: "clear" }
  /// Nothing about the waiting state changed.
  | { readonly action: "none" };

/// The reader-facing line for an event that means the run is waiting, or
/// undefined for an event that does not.
function waitingInstructionForEvent(event: AutopilotEvent): string | undefined {
  switch (event.type) {
    case "handedToReader":
      return event.instruction;
    case "needsConfirm":
      return event.reason.length > 0 ? event.reason : "Iris needs you to confirm a step.";
    case "surfaced":
      return event.reason;
    default:
      return undefined;
  }
}

/// Whether an event means the run has started moving again, so a pending "your
/// turn" state should clear.
function eventMeansMovingAgain(event: AutopilotEvent): boolean {
  switch (event.type) {
    case "stepStarted":
    case "commandStarted":
    case "commandFinished":
    case "openRequested":
    case "advanced":
    case "finished":
    case "aborted":
      return true;
    default:
      return false;
  }
}

/// Tracks whether the run is currently waiting on the reader, so the toast fires
/// once per waiting stretch rather than on every event. Pure and synchronous —
/// the adaptor owns the Electron side.
export class YourTurnTracker {
  private waiting = false;
  private lastInstruction: string | undefined;

  get isWaiting(): boolean {
    return this.waiting;
  }

  get currentInstruction(): string | undefined {
    return this.lastInstruction;
  }

  observe(event: AutopilotEvent): YourTurnUpdate {
    const instruction = waitingInstructionForEvent(event);
    if (instruction !== undefined) {
      // Toast only when we were NOT already waiting — the transition in.
      const notify = !this.waiting;
      this.waiting = true;
      this.lastInstruction = instruction;
      return { action: "raise", instruction, notify };
    }
    if (eventMeansMovingAgain(event)) {
      if (!this.waiting) {
        return { action: "none" };
      }
      this.waiting = false;
      this.lastInstruction = undefined;
      return { action: "clear" };
    }
    return { action: "none" };
  }
}
