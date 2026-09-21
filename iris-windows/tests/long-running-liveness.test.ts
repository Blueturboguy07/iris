import { describe, it, expect } from "vitest";
import { MockShell, detectServedUrl } from "../src/services/autopilot/shell";
import { commandHoldsTheShellOpen } from "../src/services/autopilot/guide-recipe";
import type { ApprovedCommand } from "../src/services/autopilot/risk";

/**
 * The macOS incident these mirror: chat ran `npm run dev`, the process was
 * killed at the deadline, and the reader was told "i stopped the command after
 * 2 minutes since dev servers run forever, but it's still serving." It was not.
 *
 * Windows already had the long-running lane — `runLongRunning` starts a server
 * detached, surfaces an immediate exit as a failure to start, and kills the
 * tree on abort and dispose — so the gap here was narrower than on macOS: a
 * server that resolved and then died later had nothing that would ever notice,
 * because the only evidence anyone held was the URL it printed at startup.
 * `longRunningStillAlive` is that missing re-ask, and these pin the property it
 * exists for: STARTED is not RUNNING.
 */

const approved = { text: "npm.cmd run dev" } as ApprovedCommand;

describe("a command that never exits is recognised as one", () => {
  it("catches the exact command from the incident, and its .cmd spelling", () => {
    expect(commandHoldsTheShellOpen("npm run dev")).toBe(true);
    expect(commandHoldsTheShellOpen("npm.cmd run dev")).toBe(true);
  });

  it("catches the other ways a reader runs an app from source", () => {
    for (const command of [
      "pnpm dev",
      "yarn start",
      "bun run serve",
      "next dev",
      "vite",
      "rails server",
      "cargo run",
      "python3 -m http.server",
    ]) {
      expect(commandHoldsTheShellOpen(command), command).toBe(true);
    }
  });

  it("does not mistake an ordinary command for a server", () => {
    for (const command of ["npm.cmd install", "git status", "npm run build", "cargo build"]) {
      expect(commandHoldsTheShellOpen(command), command).toBe(false);
    }
  });
});

describe("started is not running", () => {
  it("reports a server that died after it started as not alive", async () => {
    const shell = new MockShell();
    const outcome = await shell.runLongRunning(approved, undefined, 0);

    // It started — this is the state the old code stopped at, and the state
    // the reader was told about two minutes after it had stopped being true.
    expect(outcome.kind).toBe("succeeded");

    // And it is gone now. The whole point: the successful start above is not
    // evidence about this, and only re-asking gets the right answer.
    expect(shell.longRunningStillAlive()).toBe(false);
  });

  it("reports a server that is genuinely still up as alive", async () => {
    const shell = new MockShell();
    shell.longRunningIsAlive = true;
    await shell.runLongRunning(approved, undefined, 0);
    expect(shell.longRunningStillAlive()).toBe(true);
  });
});

describe("the served URL is read, never guessed", () => {
  it("takes the real port out of the server's own output", () => {
    // The macOS model invented localhost:4173 before running anything, then
    // relayed 5174 from a process it had killed. Windows reads the port out of
    // what the server actually printed, which is the behaviour to keep.
    expect(detectServedUrl("  ➜  Local:   http://localhost:5174/")).toBe("http://localhost:5174");
    expect(detectServedUrl("Listening on http://127.0.0.1:3000")).toBe("http://127.0.0.1:3000");
  });

  it("returns nothing rather than a guess when no port was printed", () => {
    expect(detectServedUrl("compiling...")).toBeUndefined();
    expect(detectServedUrl("")).toBeUndefined();
  });
});
