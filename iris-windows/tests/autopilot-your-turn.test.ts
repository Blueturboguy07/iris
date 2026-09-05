import { describe, expect, it } from "vitest";
import { YourTurnTracker } from "../src/services/autopilot/your-turn";
import type { AutopilotEvent } from "../src/services/autopilot/runner";

/**
 * The tray's "your turn" state, as a pure reducer. The tray itself can't be
 * unit-tested (it imports Electron), so this pins the decision that drives it:
 * WHEN the run is waiting on the reader, and when the one-off toast fires. See
 * `services/autopilot/your-turn.ts`; `src/main/tray.ts` is the thin adaptor.
 */

const stepStarted: AutopilotEvent = { type: "stepStarted", index: 0, total: 3, title: "Clone", kind: "command" };
const commandStarted: AutopilotEvent = { type: "commandStarted", text: "npm ci", friendlyLabel: "Installing…" };
const handedToReader: AutopilotEvent = { type: "handedToReader", instruction: "Sign in here, then Iris carries on." };
const needsConfirm: AutopilotEvent = { type: "needsConfirm", command: "sudo make install", reason: "This runs as administrator." };
const surfaced: AutopilotEvent = { type: "surfaced", reason: "That command didn't finish cleanly." };
const finished: AutopilotEvent = { type: "finished", output: { type: "local_web", url: "http://localhost:1234" } };
const aborted: AutopilotEvent = { type: "aborted" };

describe("the your-turn tracker", () => {
  it("stays quiet while the run is moving on its own", () => {
    const tracker = new YourTurnTracker();
    for (const event of [stepStarted, commandStarted]) {
      expect(tracker.observe(event).action).toBe("none");
    }
    expect(tracker.isWaiting).toBe(false);
  });

  it("raises (and toasts once) when the run hands off to the reader", () => {
    const tracker = new YourTurnTracker();
    const update = tracker.observe(handedToReader);
    expect(update).toEqual({ action: "raise", instruction: handedToReader.instruction, notify: true });
    expect(tracker.isWaiting).toBe(true);
    expect(tracker.currentInstruction).toBe(handedToReader.instruction);
  });

  it("does not re-toast while it is already the reader's turn", () => {
    const tracker = new YourTurnTracker();
    expect(tracker.observe(handedToReader)).toMatchObject({ action: "raise", notify: true });
    // A second waiting event (e.g. a follow-up surfaced line) must not re-notify.
    const second = tracker.observe(surfaced);
    expect(second).toMatchObject({ action: "raise", notify: false });
  });

  it("clears when the run starts moving again, then can toast anew", () => {
    const tracker = new YourTurnTracker();
    tracker.observe(needsConfirm);
    expect(tracker.observe(commandStarted).action).toBe("clear");
    expect(tracker.isWaiting).toBe(false);
    // A later wait toasts again — it is a fresh transition into waiting.
    expect(tracker.observe(handedToReader)).toMatchObject({ action: "raise", notify: true });
  });

  it("treats a confirm reason as the waiting instruction", () => {
    const tracker = new YourTurnTracker();
    const update = tracker.observe(needsConfirm);
    expect(update).toMatchObject({ action: "raise", instruction: "This runs as administrator." });
  });

  it("clears on a finished run and on an aborted run", () => {
    for (const ending of [finished, aborted]) {
      const tracker = new YourTurnTracker();
      tracker.observe(handedToReader);
      expect(tracker.observe(ending).action).toBe("clear");
      expect(tracker.isWaiting).toBe(false);
    }
  });

  it("reports no change when a moving event arrives and nothing was waiting", () => {
    const tracker = new YourTurnTracker();
    expect(tracker.observe(finished).action).toBe("none");
  });
});
