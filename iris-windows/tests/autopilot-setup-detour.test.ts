import { describe, expect, it } from "vitest";

import type { InstallRecipe } from "../src/services/autopilot/recipe";
import type { AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell, type CommandOutcome } from "../src/services/autopilot/shell";
import {
  PREREQUISITE_POLL_DEADLINE_MS,
  firstProgramToken,
  isCommandNotFound,
  prerequisitesFor,
  recipeInstallStepForTool,
  runSetupDetour,
  selfHealStepForFailure,
  wingetInstallCommand,
  wingetInstallDecision,
  programsEachLineWouldRun,
  type DetourClock,
  type SetupDetourDeps,
  type ToolProbe,
  type ToolProbeResult,
} from "../src/services/autopilot/setup-detour";

/**
 * The setup-recovery detour and the missing-tool self-heal helpers — the Windows
 * port of macOS's `enterSetupRecoveryIfAPrerequisiteIsMissing` and
 * `installTheMissingToolTheGuideInstallsItself`. Tool probing and the wall clock
 * are fakes, so the whole flow — including the 15-minute poll — runs instantly on
 * any host.
 */

// A recipe that checks git and node (prerequisites it does NOT install) and
// installs uv itself (a winget step, so uv is the self-heal's job, not the
// detour's).
function recipeWithPrerequisites(): InstallRecipe {
  return {
    slug: "demo",
    appName: "Demo",
    output: { type: "local_web", url: "http://localhost:5173" },
    steps: [
      { id: "check-git", title: "Check Git", kind: "command", command: "git --version", check: { type: "tool_version", tool: "git" } },
      { id: "check-node", title: "Check Node", kind: "command", command: "node --version", check: { type: "tool_version", tool: "node" } },
      { id: "install-uv", title: "Install uv", kind: "command", command: "winget install --id astral-sh.uv -e", check: { type: "tool_version", tool: "uv" } },
      { id: "clone", title: "Clone", kind: "command", command: "git clone https://example.com/x.git" },
    ],
  };
}

/// A tool probe scripted per tool: each entry is a sequence of answers, the last
/// repeating once exhausted (so `[false, false, true]` is "missing, missing, then
/// present forever"). A boolean maps to `installed`/`notInstalled`; a
/// `ToolProbeResult` string is passed through, so a test can script a
/// `couldNotBeChecked`. Records every tool it was asked about.
type ScriptedAnswer = boolean | ToolProbeResult;
function toProbeResult(answer: ScriptedAnswer): ToolProbeResult {
  if (answer === true) return "installed";
  if (answer === false) return "notInstalled";
  return answer;
}
class FakeToolProbe implements ToolProbe {
  readonly asked: string[] = [];
  constructor(
    private readonly answers: Record<string, ScriptedAnswer[]>,
    private readonly wingetPresent = true,
  ) {}
  async probe(tool: string): Promise<ToolProbeResult> {
    this.asked.push(tool);
    const sequence = this.answers[tool] ?? [false];
    const answer = sequence.length > 1 ? sequence.shift()! : sequence[0]!;
    return toProbeResult(answer);
  }
  async isWingetAvailable(): Promise<boolean> {
    return this.wingetPresent;
  }
}

/// A clock whose `sleep` advances a virtual now, so the bounded poll terminates
/// instantly instead of taking fifteen real minutes.
class FakeClock implements DetourClock {
  private t = 0;
  now(): number {
    return this.t;
  }
  async sleep(ms: number): Promise<void> {
    this.t += ms;
  }
}

function depsFor(
  probe: ToolProbe,
  events: AutopilotEvent[],
  overrides: Partial<SetupDetourDeps> = {},
): SetupDetourDeps {
  return {
    probe,
    clock: new FakeClock(),
    platform: "win32",
    autonomyGranted: true,
    emit: (event) => events.push(event),
    ...overrides,
  };
}

describe("prerequisite derivation", () => {
  it("reads the tools a recipe checks but does not install (git, node), skipping the winget-installed uv", () => {
    const prerequisites = prerequisitesFor(recipeWithPrerequisites(), "win32");
    expect(prerequisites.map((p) => p.tool)).toEqual(["git", "node"]);
    expect(prerequisites[0]).toMatchObject({ tool: "git", wingetId: "Git.Git" });
    expect(prerequisites[1]).toMatchObject({ tool: "node", wingetId: "OpenJS.NodeJS.LTS" });
    expect(prerequisites[0].downloadHref).toContain("git-scm.com");
    expect(prerequisites[1].downloadHref).toContain("nodejs.org");
  });

  it("returns nothing for a recipe with no tool checks", () => {
    const recipe: InstallRecipe = {
      slug: "x",
      appName: "X",
      output: { type: "none" },
      steps: [{ id: "clone", title: "Clone", kind: "command", command: "git clone https://example.com/x.git" }],
    };
    expect(prerequisitesFor(recipe, "win32")).toEqual([]);
  });
});

describe("first-token normalization", () => {
  it("strips a .cmd/.exe suffix, a path prefix, and quotes, and lowercases", () => {
    expect(firstProgramToken("npm.cmd install -g pnpm")).toBe("npm");
    expect(firstProgramToken("git --version")).toBe("git");
    expect(firstProgramToken("node_modules\\.bin\\tauri.cmd build")).toBe("tauri");
    expect(firstProgramToken("PNPM install")).toBe("pnpm");
  });
});

describe("command-not-found detection", () => {
  it("recognizes the PowerShell message and the POSIX exit 127, but not an ordinary failure", () => {
    expect(isCommandNotFound(127, "")).toBe(true);
    expect(
      isCommandNotFound(1, "pnpm : The term 'pnpm' is not recognized as the name of a cmdlet, function, script file"),
    ).toBe(true);
    expect(isCommandNotFound(1, "'foo' is not recognized as an internal or external command")).toBe(true);
    expect(isCommandNotFound(127, "zsh: command not found: pnpm")).toBe(true);
    expect(isCommandNotFound(1, "npm ERR! ELIFECYCLE build failed")).toBe(false);
    expect(isCommandNotFound(2, "fatal: repository not found")).toBe(false);
  });
});

describe("the winget fast-path decision", () => {
  it("is runs-without-asking under the grant and needs-a-confirm-tap without it", () => {
    const command = wingetInstallCommand("Git.Git");
    expect(command).toBe(
      "winget install --id Git.Git -e --accept-source-agreements --accept-package-agreements --disable-interactivity",
    );
    expect(wingetInstallDecision(command, true)).toBe("auto");
    expect(wingetInstallDecision(command, false)).toBe("needs_confirm");
  });
});

describe("the self-heal install-step lookup", () => {
  it("finds the recipe's own earlier install step for a missing tool", () => {
    const recipe: InstallRecipe = {
      slug: "demo",
      appName: "Demo",
      output: { type: "none" },
      steps: [
        { id: "install-pnpm", title: "Install pnpm", kind: "command", command: "npm.cmd install -g pnpm", check: { type: "tool_version", tool: "pnpm" } },
        { id: "use-pnpm", title: "Install deps", kind: "command", command: "pnpm install" },
      ],
    };
    const step = recipeInstallStepForTool(recipe, "pnpm", 1, "win32");
    expect(step?.id).toBe("install-pnpm");
    // A verify step (git --version) is not an install step.
    expect(recipeInstallStepForTool(recipeWithPrerequisites(), "git", 3, "win32")).toBeUndefined();
    // The install step must be strictly BEFORE the failing step.
    expect(recipeInstallStepForTool(recipe, "pnpm", 0, "win32")).toBeUndefined();
  });

  it("selfHealStepForFailure only bites on a command-not-found failure", () => {
    const recipe: InstallRecipe = {
      slug: "demo",
      appName: "Demo",
      output: { type: "none" },
      steps: [
        { id: "install-pnpm", title: "Install pnpm", kind: "command", command: "npm.cmd install -g pnpm", check: { type: "tool_version", tool: "pnpm" } },
        { id: "use-pnpm", title: "Install deps", kind: "command", command: "pnpm install" },
      ],
    };
    expect(
      selfHealStepForFailure(recipe, 1, "pnpm install", 1, "'pnpm' is not recognized as the name of a cmdlet", "win32")?.id,
    ).toBe("install-pnpm");
    // Ordinary failure → no self-heal.
    expect(
      selfHealStepForFailure(recipe, 1, "pnpm install", 1, "npm ERR! build broke", "win32"),
    ).toBeUndefined();
  });
});

describe("the setup-recovery detour", () => {
  it("does nothing and emits nothing when every prerequisite is present", async () => {
    const probe = new FakeToolProbe({ git: [true], node: [true] });
    const events: AutopilotEvent[] = [];
    const result = await runSetupDetour(recipeWithPrerequisites(), MockShell.alwaysSucceeds(), depsFor(probe, events));
    expect(result).toEqual({ kind: "ready" });
    expect(events).toEqual([]);
  });

  it("installs a missing prerequisite with winget under the grant, without opening the download page", async () => {
    // git missing then present-after-install; node already there.
    const probe = new FakeToolProbe({ git: [false, true], node: [true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(recipeWithPrerequisites(), shell, depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    // It announced the detour, listing the missing tool with its download href.
    const detour = events.find((e) => e.type === "setupDetour");
    expect(detour).toMatchObject({ type: "setupDetour", missing: [{ tool: "git" }] });
    // It ran the winget install…
    expect(shell.commandsRun).toContain(wingetInstallCommand("Git.Git"));
    // …and never fell back to opening the download page.
    expect(events.some((e) => e.type === "openRequested")).toBe(false);
  });

  it("opens the download page and polls to completion — no reader tap — when winget is absent", async () => {
    // winget not present, so straight to manual; git appears on the 3rd poll.
    const probe = new FakeToolProbe({ git: [false, false, false, true], node: [true] }, false);
    const events: AutopilotEvent[] = [];
    const result = await runSetupDetour(recipeWithPrerequisites(), MockShell.alwaysSucceeds(), depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    const open = events.find((e) => e.type === "openRequested");
    expect(open).toMatchObject({ type: "openRequested", href: expect.stringContaining("git-scm.com") });
    // Resolved by reappearance alone — no hand-back to the reader.
    expect(events.some((e) => e.type === "handedToReader")).toBe(false);
    // No winget command was run.
    expect(events.some((e) => e.type === "commandStarted")).toBe(false);
  });

  it("without the grant, skips winget and uses the download page even when winget is present", async () => {
    const probe = new FakeToolProbe({ git: [false, true], node: [true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(
      recipeWithPrerequisites(),
      shell,
      depsFor(probe, events, { autonomyGranted: false }),
    );

    expect(result).toEqual({ kind: "ready" });
    expect(shell.commandsRun).toEqual([]); // winget never ran
    expect(events.some((e) => e.type === "openRequested")).toBe(true);
  });

  it("falls back to the download page when a winget install runs but the tool still isn't there", async () => {
    // git: missing (initial), missing (after winget), present (poll).
    const probe = new FakeToolProbe({ git: [false, false, true], node: [true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(recipeWithPrerequisites(), shell, depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    expect(shell.commandsRun).toContain(wingetInstallCommand("Git.Git")); // winget was tried
    expect(events.some((e) => e.type === "openRequested")).toBe(true); // then the page
  });

  it("surfaces when the prerequisite never appears within the deadline", async () => {
    const probe = new FakeToolProbe({ git: [false], node: [true] }, false); // git never shows up
    const events: AutopilotEvent[] = [];
    const clock = new FakeClock();
    const result = await runSetupDetour(
      recipeWithPrerequisites(),
      MockShell.alwaysSucceeds(),
      depsFor(probe, events, { clock }),
    );

    expect(result.kind).toBe("surfaced");
    // It waited out the whole bounded window rather than giving up immediately.
    expect(clock.now()).toBeGreaterThanOrEqual(PREREQUISITE_POLL_DEADLINE_MS);
  });

  it("handles two missing prerequisites in recipe order", async () => {
    const probe = new FakeToolProbe({ git: [false, true], node: [false, true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(recipeWithPrerequisites(), shell, depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    const detour = events.find((e) => e.type === "setupDetour");
    expect(detour).toMatchObject({ missing: [{ tool: "git" }, { tool: "node" }] });
    expect(shell.commandsRun).toEqual([
      wingetInstallCommand("Git.Git"),
      wingetInstallCommand("OpenJS.NodeJS.LTS"),
    ]);
  });
});

// A recipe shaped the way a REAL published guide derives (guide-recipe.ts): git
// and node ride in `recipe.prerequisites` (from the branch's setupSteps), never
// as `check`-bearing steps; the ordinary steps carry their completion signal in
// `watch.expect` toolVersion entries, never in `check`. This is the shape the
// old code was blind to — the detour and the self-heal both read the wrong field.
function guideDerivedRecipe(): InstallRecipe {
  return {
    slug: "whimprflow",
    appName: "WhimprFlow",
    output: { type: "desktop_app", launch: { via: "path", path: "%LOCALAPPDATA%\\WhimprFlow\\WhimprFlow.exe" } },
    prerequisites: [
      { id: "install-git", title: "Install Git", tool: "git", href: "https://git-scm.com/install/windows" },
      { id: "install-node", title: "Install Node LTS", tool: "node", href: "https://nodejs.org/en/download" },
    ],
    steps: [
      // The guide's own tool-check step runs git AND node, watches for both, and
      // installs neither — it must not be mistaken for an install step.
      {
        id: "check-tools",
        title: "Check tools",
        kind: "command",
        command: "git --version\nnode --version",
        watch: { expect: [{ type: "toolVersion", tool: "git" }, { type: "toolVersion", tool: "node" }] },
      },
      // Installs pnpm; the signal is the watch, not a `check`.
      {
        id: "install-pnpm",
        title: "Install pnpm",
        kind: "command",
        command: "npm.cmd install -g pnpm",
        watch: { expect: [{ type: "toolVersion", tool: "pnpm" }] },
      },
      { id: "clone", title: "Clone", kind: "command", command: "git clone https://example.com/x.git" },
    ],
  };
}

describe("prerequisites from a guide-derived recipe (recipe.prerequisites)", () => {
  it("reads git/node from recipe.prerequisites, preferring the guide's own download href", () => {
    const prerequisites = prerequisitesFor(guideDerivedRecipe(), "win32");
    expect(prerequisites.map((p) => p.tool)).toEqual(["git", "node"]);
    // winget id comes from the built-in catalog…
    expect(prerequisites[0]).toMatchObject({ tool: "git", wingetId: "Git.Git" });
    expect(prerequisites[1]).toMatchObject({ tool: "node", wingetId: "OpenJS.NodeJS.LTS" });
    // …and the download href is the one the guide named.
    expect(prerequisites[0].downloadHref).toBe("https://git-scm.com/install/windows");
    expect(prerequisites[1].downloadHref).toBe("https://nodejs.org/en/download");
  });

  it("runs the detour for a guide-derived recipe with a missing prerequisite (the 16-app bug)", async () => {
    const probe = new FakeToolProbe({ git: [false, true], node: [true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(guideDerivedRecipe(), shell, depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    // The detour fired at all — the old code returned {kind:"ready"} immediately
    // because prerequisitesFor([]) never looked at recipe.prerequisites.
    expect(events.some((e) => e.type === "setupDetour")).toBe(true);
    expect(shell.commandsRun).toContain(wingetInstallCommand("Git.Git"));
  });
});

describe("self-heal reads the watch signal, not just check", () => {
  it("finds a guide step's watch-declared install step for a missing tool", () => {
    const recipe = guideDerivedRecipe();
    // install-pnpm carries the pnpm signal only in watch.expect (no `check`).
    const step = recipeInstallStepForTool(recipe, "pnpm", 2, "win32");
    expect(step?.id).toBe("install-pnpm");
    // And a mid-recipe `pnpm install` command-not-found routes to it.
    expect(
      selfHealStepForFailure(
        recipe,
        2,
        "pnpm install",
        1,
        "'pnpm' is not recognized as the name of a cmdlet",
        "win32",
      )?.id,
    ).toBe("install-pnpm");
  });

  it("never treats a multi-tool check step as installing a tool it runs on any line", () => {
    const recipe = guideDerivedRecipe();
    // check-tools runs both git and node, so it installs neither, even though it
    // watches both — the macOS "runs the tool ⇒ can't be what installs it" rule,
    // applied per line (the second line runs node).
    expect(recipeInstallStepForTool(recipe, "node", 3, "win32")).toBeUndefined();
    expect(recipeInstallStepForTool(recipe, "git", 3, "win32")).toBeUndefined();
  });
});

describe("programsEachLineWouldRun", () => {
  it("returns the first program of every line/statement, not just the first token", () => {
    expect([...programsEachLineWouldRun("git --version\nnode --version")].sort()).toEqual(["git", "node"]);
    expect([...programsEachLineWouldRun("winget install --id X.Y ; refreshenv")].sort()).toEqual([
      "refreshenv",
      "winget",
    ]);
    expect([...programsEachLineWouldRun("npm.cmd install -g pnpm")]).toEqual(["npm"]);
  });
});

describe("a probe that could not be checked is not a missing tool", () => {
  it("does NOT divert the reader when the probe times out / cannot run", async () => {
    // git can't be checked (a busy machine, a slow cold start); node is present.
    const probe = new FakeToolProbe({ git: ["couldNotBeChecked"], node: [true] }, true);
    const events: AutopilotEvent[] = [];
    const shell = MockShell.alwaysSucceeds();
    const result = await runSetupDetour(recipeWithPrerequisites(), shell, depsFor(probe, events));

    expect(result).toEqual({ kind: "ready" });
    // Nothing was installed and no page was opened for a tool Iris couldn't check.
    expect(events.some((e) => e.type === "setupDetour")).toBe(false);
    expect(shell.commandsRun).toEqual([]);
    expect(events.some((e) => e.type === "openRequested")).toBe(false);
  });
});

describe("the detour is cancellable (the red 'Stop')", () => {
  it("stops polling and returns cancelled the moment shouldCancel flips", async () => {
    // git never appears; winget absent, so the detour opens the page and polls.
    const probe = new FakeToolProbe({ git: [false], node: [true] }, false);
    const events: AutopilotEvent[] = [];
    let cancelled = false;
    // Cancel after the first poll sleep, so the loop is mid-wait when Stop lands.
    const clock: DetourClock = {
      now: () => 0, // never reaches the deadline on its own
      sleep: async () => {
        cancelled = true;
      },
    };
    const result = await runSetupDetour(
      recipeWithPrerequisites(),
      MockShell.alwaysSucceeds(),
      depsFor(probe, events, { clock, shouldCancel: () => cancelled }),
    );

    expect(result).toEqual({ kind: "cancelled" });
    // It gave up rather than surfacing or spinning forever.
    expect(events.some((e) => e.type === "surfaced")).toBe(false);
  });
});

// A small guard that the shell outcome shapes the tests lean on stay valid.
const _outcomeShapes: CommandOutcome[] = [
  { kind: "succeeded", output: "" },
  { kind: "failed", exitCode: 1, output: "x" },
];
void _outcomeShapes;
