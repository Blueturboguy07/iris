import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it, beforeEach } from "vitest";

import {
  branchKeyFor,
  decodeIrisGuide,
  type IrisGuide,
  type IrisGuideBranch,
} from "../src/services/autopilot/guide-model";
import {
  commandHoldsTheShellOpen,
  commandNeedsPosixTranslation,
  recipeFromGuide,
  translatePosixShellToPowerShell,
  type RecipeDerivationTarget,
} from "../src/services/autopilot/guide-recipe";
import {
  clearGuideCache,
  guideBackedRecipeResolver,
  resolveGuideRecipe,
} from "../src/services/autopilot/guide-recipe-resolver";
import { recipeForSlug } from "../src/services/autopilot/recipes";
import { AutopilotRunner, type AutopilotEvent } from "../src/services/autopilot/runner";
import { MockShell } from "../src/services/autopilot/shell";
import type { FetchLike } from "../src/services/guide-service";
import type { InstallRecipe } from "../src/services/autopilot/recipe";

/**
 * Guide-derived recipes. These prove that every publik guide with a Windows
 * branch derives into an `InstallRecipe` the runner can drive — the primary path
 * that replaces the two-entry static table — and that the derivation preserves
 * the guide's commands in order, reports unsupported pairs, and never throws on a
 * malformed payload.
 *
 * The fixtures under `tests/fixtures/guides/` are the LIVE JSON of all 18 guides,
 * fetched once with `curl https://publikhq.com/api/iris/guides/<slug>`, so this
 * suite stays offline while testing against exactly what the route serves.
 */

const FIXTURES_DIRECTORY = path.join(__dirname, "fixtures", "guides");

function loadGuideFixture(slug: string): IrisGuide {
  const raw = readFileSync(path.join(FIXTURES_DIRECTORY, `${slug}.json`), "utf8");
  return decodeIrisGuide(JSON.parse(raw));
}

function fixtureSlugs(): string[] {
  return readdirSync(FIXTURES_DIRECTORY)
    .filter((name) => name.endsWith(".json"))
    .map((name) => name.slice(0, -".json".length))
    .sort();
}

function fixtureJsonText(slug: string): string {
  return readFileSync(path.join(FIXTURES_DIRECTORY, `${slug}.json`), "utf8");
}

/** The guide commands, in order, that Iris itself runs — a `terminal`/`check`
 *  step with a non-blank command that the guide did NOT mark sensitive. A
 *  sensitive command (a secret entered while it is open) is handed to the reader
 *  as a `manual` step, so it is deliberately NOT a `command` Iris runs; everything
 *  else (opens, reader steps, prose, verify) carries no command either. */
function branchCommandsInOrder(branch: IrisGuideBranch): string[] {
  return branch.steps
    .filter(
      (step) =>
        (step.kind === "terminal" || step.kind === "check") &&
        step.command !== undefined &&
        step.command.trim() !== "" &&
        step.watch?.sensitive !== true,
    )
    .map((step) => step.command as string);
}

/** Removes winget's non-interactive agreement flags, so the "commands preserved
 *  in order" check can compare a derived command against the raw guide command
 *  without the derivation's deliberate winget normalization (finding: a bare
 *  `winget install` would stall on the interactive Y/N prompt) reading as a
 *  mismatch. The flags themselves are asserted separately. */
function withoutWingetAgreementFlags(command: string): string {
  return command
    .replace(/\s--accept-source-agreements/g, "")
    .replace(/\s--accept-package-agreements/g, "");
}

function targetForBranch(branch: IrisGuideBranch): RecipeDerivationTarget {
  return { platform: "windows", ...(branch.target !== undefined ? { target: branch.target } : {}) };
}

describe("deriving a recipe from every guide with a Windows branch", () => {
  const slugs = fixtureSlugs();

  it("has all 18 guide fixtures", () => {
    expect(slugs.length).toBe(18);
  });

  const derivedSuccessfully: string[] = [];
  const unsupportedReported: string[] = [];

  for (const slug of slugs) {
    it(`derives ${slug}'s Windows branches, command-for-command`, () => {
      const guide = loadGuideFixture(slug);
      const windowsBranches = guide.branches.filter((branch) => branch.platform === "windows");
      expect(windowsBranches.length).toBeGreaterThan(0);

      for (const branch of windowsBranches) {
        const resolution = recipeFromGuide(guide, targetForBranch(branch));

        if (branch.unsupported !== undefined) {
          // An unsupported pair is an explanation, never a recipe.
          expect(resolution.kind).toBe("unsupported");
          if (resolution.kind === "unsupported") {
            expect(resolution.branchKey).toBe(branchKeyFor(branch));
            expect(resolution.unsupported.headline.length).toBeGreaterThan(0);
          }
          unsupportedReported.push(`${slug}:${branchKeyFor(branch)}`);
          continue;
        }

        expect(resolution.kind).toBe("recipe");
        if (resolution.kind !== "recipe") continue;
        const recipe = resolution.recipe;

        // The recipe's slug/name come from the guide.
        expect(recipe.slug).toBe(guide.appSlug);
        expect(recipe.appName).toBe(guide.appName);

        // Every guide step maps to exactly one recipe step.
        expect(recipe.steps.length).toBe(branch.steps.length);

        // The command steps equal the branch's non-sensitive commands, in order
        // (a sensitive command becomes a reader-run `manual` step, not a
        // `command`). Compared against the AUTHORED command (`posixCommand`, which
        // the derivation keeps whenever it rewrites the Windows command — the
        // POSIX clone-step idiom → PowerShell), falling back to `command` for the
        // untouched steps. Winget's agreement flags are stripped from both sides,
        // since the derivation deliberately adds them; the flags are asserted on
        // their own below.
        const derivedCommands = recipe.steps
          .filter((step) => step.kind === "command")
          .map((step) => withoutWingetAgreementFlags((step.posixCommand ?? step.command) as string));
        expect(derivedCommands).toEqual(
          branchCommandsInOrder(branch).map(withoutWingetAgreementFlags),
        );

        // Ids and titles are preserved position-for-position.
        expect(recipe.steps.map((step) => step.id)).toEqual(branch.steps.map((step) => step.id));
        expect(recipe.steps.map((step) => step.title)).toEqual(branch.steps.map((step) => step.title));

        derivedSuccessfully.push(`${slug}:${branchKeyFor(branch)}`);
      }
    });
  }

  it("summarises which branches derived and which were unsupported", () => {
    // Re-derive to build the summary independently of test ordering.
    const derived: string[] = [];
    const unsupported: string[] = [];
    for (const slug of fixtureSlugs()) {
      const guide = loadGuideFixture(slug);
      for (const branch of guide.branches.filter((each) => each.platform === "windows")) {
        const resolution = recipeFromGuide(guide, targetForBranch(branch));
        if (resolution.kind === "recipe") derived.push(`${slug}:${branchKeyFor(branch)}`);
        else if (resolution.kind === "unsupported") unsupported.push(`${slug}:${branchKeyFor(branch)}`);
      }
    }
    // Every supported Windows branch derives; the four Windows+iPhone pairs are
    // the only unsupported ones.
    expect(unsupported.sort()).toEqual([
      "kneecap:windows:ios",
      "lunara:windows:ios",
      "noscroll:windows:ios",
      "nut-ai:windows:ios",
    ]);
    expect(derived.length).toBeGreaterThanOrEqual(18);
  });
});

describe("the derivation mapping", () => {
  it("maps a no-command terminal/check step to a self-completing noop", () => {
    const guide = loadGuideFixture("openascii");
    const branch = guide.branches.find((each) => each.platform === "windows")!;
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    expect(resolution.kind).toBe("recipe");
    if (resolution.kind !== "recipe") return;
    // openascii's `open-shell` prose step carries no command.
    const openShell = resolution.recipe.steps.find((step) => step.id === "open-shell");
    expect(openShell?.kind).toBe("noop");
    // The guide's own `open-shell` step really has no command.
    expect(branch.steps.find((step) => step.id === "open-shell")?.command).toBeUndefined();
  });

  it("carries a verify step's watch expectations without executing them", () => {
    const guide = loadGuideFixture("publikclip");
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    expect(resolution.kind).toBe("recipe");
    if (resolution.kind !== "recipe") return;
    const verify = resolution.recipe.steps.find((step) => step.kind === "verify");
    expect(verify).toBeDefined();
    // The `open-app` step declares a foregroundApp expectation; the verify step's
    // expectations (when present) are carried through as data, never run.
    const openApp = resolution.recipe.steps.find((step) => step.id === "open-app");
    expect(openApp?.kind).toBe("command");
  });

  it("hands reader-only kinds (permission/web/paste) to the reader with the guide's body", () => {
    const guide = loadGuideFixture("anthropic-api-key");
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    expect(resolution.kind).toBe("recipe");
    if (resolution.kind !== "recipe") return;
    const pasteStep = resolution.recipe.steps.find((step) => step.kind === "paste");
    expect(pasteStep).toBeDefined();
    expect(pasteStep?.instruction).toBeTruthy();
    const webStep = resolution.recipe.steps.find((step) => step.kind === "web");
    expect(webStep).toBeDefined();
  });

  it("carries a guide branch's setup steps as recipe prerequisites (tools + hrefs)", () => {
    const guide = loadGuideFixture("openascii");
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    expect(resolution.kind).toBe("recipe");
    if (resolution.kind !== "recipe") return;
    const prerequisites = resolution.recipe.prerequisites ?? [];
    expect(prerequisites.map((prerequisite) => prerequisite.tool)).toEqual(["git", "node"]);
    expect(prerequisites.every((prerequisite) => (prerequisite.href ?? "").length > 0)).toBe(true);
  });

  it("marks a dev-server step long-running and a build step not", () => {
    expect(commandHoldsTheShellOpen("corepack.cmd pnpm dev")).toBe(true);
    expect(commandHoldsTheShellOpen("npm run build")).toBe(false);
    expect(commandHoldsTheShellOpen("git checkout abc123")).toBe(false);
    const guide = loadGuideFixture("openascii");
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    if (resolution.kind !== "recipe") throw new Error("expected a recipe");
    const runStep = resolution.recipe.steps.find((step) => step.id === "run");
    expect(runStep?.longRunning).toBe(true);
  });

  it("chooses a local_web url for a local-web guide and a desktop launch for a desktop app", () => {
    const openascii = recipeFromGuide(loadGuideFixture("openascii"), { platform: "windows" });
    if (openascii.kind !== "recipe") throw new Error("expected a recipe");
    expect(openascii.recipe.output).toEqual({ type: "local_web", url: "http://localhost:5173" });

    const publikclip = recipeFromGuide(loadGuideFixture("publikclip"), { platform: "windows" });
    if (publikclip.kind !== "recipe") throw new Error("expected a recipe");
    expect(publikclip.recipe.output.type).toBe("desktop_app");
    if (publikclip.recipe.output.type === "desktop_app") {
      expect(publikclip.recipe.output.launch.via).toBe("path");
      if (publikclip.recipe.output.launch.via === "path") {
        // The PowerShell $env: token is rewritten to the %VAR% form the launcher
        // expands, and it points at the installed exe.
        expect(publikclip.recipe.output.launch.path).toContain("%LOCALAPPDATA%");
        expect(publikclip.recipe.output.launch.path.toLowerCase()).toContain("publikclip");
      }
    }
  });

  it("attaches source provenance only to a cloning recipe", () => {
    const publikclip = recipeFromGuide(loadGuideFixture("publikclip"), { platform: "windows" });
    if (publikclip.kind !== "recipe") throw new Error("expected a recipe");
    // publikclip clones a repo, so it carries its canonical repo + pinned commit.
    expect(publikclip.recipe.canonicalRepo).toMatch(/\//);
    expect(publikclip.recipe.pinnedCommit).toBeTruthy();
  });

  it("returns noBranch for a platform/target the guide does not have", () => {
    const guide = loadGuideFixture("openascii");
    // openascii has no Android branch.
    const resolution = recipeFromGuide(guide, { platform: "windows", target: "android" });
    expect(resolution.kind).toBe("noBranch");
  });
});

describe("lenient, total decoding", () => {
  it("never throws on a wholly malformed payload", () => {
    expect(() => decodeIrisGuide(null)).not.toThrow();
    expect(() => decodeIrisGuide(42)).not.toThrow();
    expect(() => decodeIrisGuide("not a guide")).not.toThrow();
    expect(() => decodeIrisGuide({})).not.toThrow();
    expect(decodeIrisGuide({}).branches).toEqual([]);
  });

  it("falls an unknown step kind back to terminal and drops an unknown expectation", () => {
    const guide = decodeIrisGuide({
      appSlug: "x",
      appName: "X",
      version: 1,
      outputType: "local_web",
      branches: [
        {
          platform: "windows",
          label: "Windows",
          shell: "powershell",
          steps: [
            {
              id: "s1",
              kind: "totally-made-up",
              title: "T",
              body: "B",
              command: "echo hi",
              watch: {
                expect: [{ type: "weird-signal" }, { type: "toolVersion", tool: "git" }],
                extraUnknownField: true,
              },
            },
          ],
          extraUnknownBranchField: 7,
        },
      ],
      extraUnknownTopLevelField: "ignored",
    });
    const step = guide.branches[0]!.steps[0]!;
    expect(step.kind).toBe("terminal");
    // The unknown expectation was dropped; the known one survives.
    expect(step.watch?.expect).toEqual([{ type: "toolVersion", tool: "git" }]);
  });

  it("derives without throwing from a guide full of unknown fields", () => {
    const guide = decodeIrisGuide({
      appSlug: "x",
      appName: "X",
      version: 1,
      outputType: "banana", // unknown → local_web
      branches: [
        {
          platform: "windows",
          steps: [
            { id: "a", kind: "mystery", title: "A", body: "", command: "git clone https://example.com/x.git" },
            { id: "b", kind: "verify", title: "B", body: "", watch: { expect: [{ type: "nope" }] } },
          ],
        },
      ],
    });
    expect(() => recipeFromGuide(guide, { platform: "windows" })).not.toThrow();
    const resolution = recipeFromGuide(guide, { platform: "windows" });
    expect(resolution.kind).toBe("recipe");
  });

  it("drops a step with no id and a branch with an unplaceable platform", () => {
    const guide = decodeIrisGuide({
      appSlug: "x",
      appName: "X",
      version: 1,
      outputType: "local_web",
      branches: [
        { platform: "beos", steps: [] }, // dropped
        { platform: "windows", steps: [{ kind: "terminal", title: "no id", body: "" }] },
      ],
    });
    expect(guide.branches.length).toBe(1);
    expect(guide.branches[0]!.platform).toBe("windows");
    expect(guide.branches[0]!.steps.length).toBe(0); // the id-less step was dropped
  });
});

describe("the runner drives a derived recipe exactly as a static one", () => {
  /** Runs a recipe to completion on a shell where everything succeeds, on win32,
   *  and returns the event stream. No reader steps, so it runs in one pump. */
  async function eventsFromRunning(recipe: InstallRecipe): Promise<AutopilotEvent[]> {
    const runner = new AutopilotRunner(recipe, "win32", true);
    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    expect(status.type).toBe("finished");
    return runner.drainEvents();
  }

  /** A hand-built guide whose Windows branch mirrors the static OpenASCII recipe
   *  step-for-step, so its derived recipe and the static recipe produce the same
   *  runner events. (The LIVE openascii guide has since added a prose `open-shell`
   *  step and a `verify` step and combined the two tool checks, so it is a
   *  superset — see the end-to-end test below.) */
  function guideMirroringTheStaticOpenAsciiRecipe(): IrisGuide {
    return decodeIrisGuide({
      appSlug: "openascii",
      appName: "OpenASCII",
      version: 2,
      status: "pilot",
      outputType: "local_web",
      branches: [
        {
          platform: "windows",
          label: "Windows",
          shell: "powershell",
          setupSteps: [],
          steps: [
            { id: "check-git", kind: "check", title: "Check Git", body: "", command: "git --version" },
            { id: "check-node", kind: "check", title: "Check Node", body: "", command: "node --version" },
            {
              id: "clone",
              kind: "terminal",
              title: "Copy OpenASCII to this computer",
              body: "",
              command: "cd ~; git clone https://github.com/Blueturboguy07/OpenASCII.git",
              workingDirectory: "~",
            },
            { id: "enter-folder", kind: "terminal", title: "Open the OpenASCII folder", body: "", command: "cd OpenASCII", workingDirectory: "~" },
            {
              id: "pin-source",
              kind: "terminal",
              title: "Use the reviewed version",
              body: "",
              command: "git checkout 8fc32ce16a6536c1a37a36e483fdc39dfd50d5cd",
              workingDirectory: "~/OpenASCII",
            },
            { id: "dependencies", kind: "terminal", title: "Install dependencies", body: "", command: "corepack.cmd pnpm install", workingDirectory: "~/OpenASCII" },
            { id: "run", kind: "terminal", title: "Start OpenASCII", body: "", command: "corepack.cmd pnpm dev", workingDirectory: "~/OpenASCII" },
            { id: "open", kind: "open", title: "Open OpenASCII", body: "", href: "http://localhost:5173" },
          ],
        },
      ],
    });
  }

  it("emits identical events for the derived and the static OpenASCII recipe", async () => {
    const derived = recipeFromGuide(guideMirroringTheStaticOpenAsciiRecipe(), { platform: "windows" });
    if (derived.kind !== "recipe") throw new Error("expected a recipe");
    const staticRecipe = recipeForSlug("openascii")!;

    const derivedEvents = await eventsFromRunning(derived.recipe);
    const staticEvents = await eventsFromRunning(staticRecipe);

    expect(derivedEvents).toEqual(staticEvents);
    // And it really did run the whole thing.
    expect(derivedEvents.some((event) => event.type === "openRequested")).toBe(true);
    expect(derivedEvents.at(-1)?.type).toBe("finished");
  });

  it("runs the LIVE openascii guide's derived recipe up to its watched verify step", async () => {
    const derived = recipeFromGuide(loadGuideFixture("openascii"), { platform: "windows" });
    if (derived.kind !== "recipe") throw new Error("expected a recipe");
    // Driven with NO watch executor wired, the prose open-shell (noop) self-
    // completes and every command runs, so the install reaches the open step —
    // and then the trailing `verify` step (a visual watch: "drop in a photo") is
    // handed to the reader as "your turn", because nothing can confirm it without
    // watching the machine. This is the integrated watch-loop behaviour: a verify
    // step is no longer silently self-completed.
    const runner = new AutopilotRunner(derived.recipe, "win32", true);
    const status = await runner.runUntilBlocked(MockShell.alwaysSucceeds());
    const events = runner.drainEvents();
    expect(events.some((event) => event.type === "openRequested" && event.href === "http://localhost:5173")).toBe(true);
    expect(status.type).toBe("needsReader");
    // The last thing the runner did was hand the verify step over.
    expect(events.at(-1)?.type).toBe("handedToReader");
  });
});

describe("the guide-backed resolver", () => {
  beforeEach(() => clearGuideCache());

  /** A fetch that serves a fixture's raw JSON for any URL. */
  function fetchServing(slug: string): { fetch: FetchLike; callCount: () => number } {
    let calls = 0;
    const fetch: FetchLike = async () => {
      calls += 1;
      return { ok: true, status: 200, text: async () => fixtureJsonText(slug) };
    };
    return { fetch, callCount: () => calls };
  }

  it("resolves a recipe from the fetched guide (guide is the primary path)", async () => {
    const { fetch } = fetchServing("openascii");
    const resolved = await resolveGuideRecipe("openascii", {
      apiBase: "https://publikhq.com",
      fetchImplementation: fetch,
    });
    expect(resolved.kind).toBe("recipe");
    if (resolved.kind !== "recipe") return;
    expect(resolved.source).toBe("guide");
    expect(resolved.recipe.slug).toBe("openascii");
    // A guide-derived recipe is NOT byte-identical to the static one (it has the
    // newer open-shell/verify steps), which is the whole point of deriving.
    expect(resolved.recipe.steps.length).not.toBe(recipeForSlug("openascii")!.steps.length);
  });

  it("caches by slug for the session — one fetch serves repeated resolves", async () => {
    const { fetch, callCount } = fetchServing("openascii");
    const options = { apiBase: "https://publikhq.com", fetchImplementation: fetch };
    await resolveGuideRecipe("openascii", options);
    await resolveGuideRecipe("openascii", options);
    expect(callCount()).toBe(1);
    clearGuideCache();
    await resolveGuideRecipe("openascii", options);
    expect(callCount()).toBe(2);
  });

  it("falls back to the built-in recipe ONLY when the fetch fails", async () => {
    const failingFetch: FetchLike = async () => {
      throw new Error("network down");
    };
    const resolved = await resolveGuideRecipe("openascii", {
      apiBase: "https://publikhq.com",
      fetchImplementation: failingFetch,
    });
    expect(resolved.kind).toBe("recipe");
    if (resolved.kind !== "recipe") return;
    expect(resolved.source).toBe("offline_fallback");
    // The offline recipe is the static table's openascii, byte-for-byte.
    expect(resolved.recipe.steps.length).toBe(recipeForSlug("openascii")!.steps.length);
  });

  it("is unreachable when the fetch fails and no offline recipe covers the slug", async () => {
    const failingFetch: FetchLike = async () => {
      throw new Error("network down");
    };
    const resolved = await resolveGuideRecipe("astro", {
      apiBase: "https://publikhq.com",
      fetchImplementation: failingFetch,
    });
    expect(resolved.kind).toBe("unreachable");
  });

  it("reports an unsupported branch as unsupported, never a recipe", async () => {
    const { fetch } = fetchServing("kneecap");
    const resolved = await resolveGuideRecipe("kneecap", {
      apiBase: "https://publikhq.com",
      fetchImplementation: fetch,
      target: { platform: "windows", target: "ios" },
    });
    expect(resolved.kind).toBe("unsupported");
    if (resolved.kind !== "unsupported") return;
    expect(resolved.headline).toMatch(/iPhone/i);
    expect(resolved.alternatives.length).toBeGreaterThan(0);
  });

  it("the controller adapter returns a recipe for a supported branch and undefined otherwise", async () => {
    const { fetch: kneecapFetch } = fetchServing("kneecap");
    const resolveIos = guideBackedRecipeResolver({
      apiBase: "https://publikhq.com",
      fetchImplementation: kneecapFetch,
      target: { platform: "windows", target: "ios" },
    });
    expect(await resolveIos("kneecap")).toBeUndefined(); // unsupported → undefined

    clearGuideCache();
    const { fetch: openasciiFetch } = fetchServing("openascii");
    const resolveDesktop = guideBackedRecipeResolver({
      apiBase: "https://publikhq.com",
      fetchImplementation: openasciiFetch,
    });
    const recipe = await resolveDesktop("openascii");
    expect(recipe?.slug).toBe("openascii");
  });
});

describe("sensitive commands and winget normalization", () => {
  /** Derives the desktop Windows recipe for a slug, or throws when it is not a
   *  recipe — the fixtures used here all have a supported desktop branch. */
  function desktopRecipe(slug: string): InstallRecipe {
    const resolution = recipeFromGuide(loadGuideFixture(slug), { platform: "windows" });
    if (resolution.kind !== "recipe") throw new Error(`${slug} did not derive to a recipe`);
    return resolution.recipe;
  }

  it("hands a sensitive command step to the reader instead of running it (chatmany-mann)", () => {
    const recipe = desktopRecipe("chatmany-mann");
    // Both sensitive steps in the live guide pipe a secret into `wrangler secret put`.
    for (const stepId of ["owner-token", "app-secrets"]) {
      const step = recipe.steps.find((candidate) => candidate.id === stepId);
      expect(step, `step ${stepId} present`).toBeDefined();
      if (step === undefined) continue;
      // It is a reader-handled manual step — Iris never runs it, so there is NO
      // runnable command field for any code path to execute.
      expect(step.kind).toBe("manual");
      expect(step.command).toBeUndefined();
      expect(step.longRunning).toBeUndefined();
      // The reader is told what to type (the command rides in the instruction),
      // and told it is theirs to run because it is sensitive.
      expect(step.instruction).toBeDefined();
      expect(step.instruction).toContain("wrangler secret put");
      expect(step.instruction).toMatch(/secret|yourself/i);
    }
  });

  it("never derives a sensitive step into a `command` step for any guide", () => {
    for (const slug of fixtureSlugs()) {
      const guide = loadGuideFixture(slug);
      for (const branch of guide.branches.filter((candidate) => candidate.platform === "windows")) {
        if (branch.unsupported !== undefined) continue;
        const resolution = recipeFromGuide(guide, targetForBranch(branch));
        if (resolution.kind !== "recipe") continue;
        const sensitiveGuideStepIds = new Set(
          branch.steps.filter((step) => step.watch?.sensitive === true).map((step) => step.id),
        );
        for (const step of resolution.recipe.steps) {
          if (sensitiveGuideStepIds.has(step.id)) {
            expect(step.kind, `${slug}:${step.id} must not be a command`).not.toBe("command");
            expect(step.command).toBeUndefined();
          }
        }
      }
    }
  });

  it("adds winget's non-interactive agreement flags to a bare `winget install` (plantgpt install-rust)", () => {
    const recipe = desktopRecipe("plantgpt");
    const installRust = recipe.steps.find((step) => step.id === "install-rust");
    expect(installRust).toBeDefined();
    expect(installRust?.command).toContain("winget install");
    expect(installRust?.command).toContain("--accept-source-agreements");
    expect(installRust?.command).toContain("--accept-package-agreements");
  });

  it("does not double up the agreement flags on a winget command that already has them", () => {
    // publikclip's guide installs uv with the flags already present; derivation
    // must not append a second copy.
    const recipe = desktopRecipe("publikclip");
    for (const step of recipe.steps) {
      const command = step.command;
      if (command === undefined || !/winget\s+install/i.test(command)) continue;
      expect(command.match(/--accept-source-agreements/g)?.length ?? 0).toBeLessThanOrEqual(1);
      expect(command.match(/--accept-package-agreements/g)?.length ?? 0).toBeLessThanOrEqual(1);
    }
  });
});

/**
 * The POSIX clone-step idiom → PowerShell (finding: the Windows branch's `clone`
 * step is left as macOS bash — `cd ~ / if [ ! -d App/.git ]; then / git clone … /
 * fi` — which is a hard PowerShell ParserError, so nothing in the step runs, not
 * even the clone, and the "command not found" self-heal never fires). The
 * derivation rewrites it to PowerShell for the Windows command and keeps the
 * authored bash as `posixCommand` for the Mac test host.
 */
describe("POSIX clone-step translation", () => {
  it("translates the bash idempotent-clone idiom to runnable PowerShell", () => {
    const bash = "cd ~\nif [ ! -d WhimprFlow/.git ]; then\ngit clone https://github.com/Blueturboguy07/WhimprFlow.git\nfi";
    expect(commandNeedsPosixTranslation(bash)).toBe(true);
    const powershell = translatePosixShellToPowerShell(bash);
    // The bash-only syntax is gone…
    expect(powershell).not.toMatch(/\[\s*!?\s*-[a-z]\s/);
    expect(powershell.split("\n").some((line) => line.trim() === "fi")).toBe(false);
    // …replaced by the PowerShell existence guard, with the clone body intact.
    expect(powershell).toContain("if (-not (Test-Path WhimprFlow/.git)) {");
    expect(powershell).toContain("git clone https://github.com/Blueturboguy07/WhimprFlow.git");
    expect(powershell.trimEnd().endsWith("}")).toBe(true);
    // `cd ~` is valid in both shells and is left untouched.
    expect(powershell).toContain("cd ~");
  });

  it("leaves an already-PowerShell command untouched", () => {
    const powershell = 'if (!(Test-Path "$env:APPDATA\\App\\models\\x.bin")) { curl.exe -f -L -o "x" https://example.com/x }';
    expect(commandNeedsPosixTranslation(powershell)).toBe(false);
    expect(translatePosixShellToPowerShell(powershell)).toBe(powershell);
    // And an ordinary chained command with `cd`/`;` is not mistaken for bash.
    const chained = "cd ui; pnpm.cmd install; cd ..; pnpm.cmd --dir ui approve-builds --all";
    expect(commandNeedsPosixTranslation(chained)).toBe(false);
  });

  it("derives every fixture's Windows commands free of bash-only syntax", () => {
    // Every derived Windows `command` step must be PowerShell-parseable: no `[ -x
    // ]` test, no bare `then`/`fi` line. The authored bash survives on
    // `posixCommand` for the clone steps the derivation rewrote.
    let clonesTranslated = 0;
    for (const slug of fixtureSlugs()) {
      const guide = loadGuideFixture(slug);
      for (const branch of guide.branches.filter((each) => each.platform === "windows")) {
        const resolution = recipeFromGuide(guide, targetForBranch(branch));
        if (resolution.kind !== "recipe") continue;
        for (const step of resolution.recipe.steps) {
          if (step.kind !== "command") continue;
          expect(commandNeedsPosixTranslation(step.command as string), `${slug}:${step.id}`).toBe(false);
          if (step.posixCommand !== undefined) {
            // A translated step keeps the authored bash, and the win32 command is
            // the PowerShell rewrite of it.
            expect(commandNeedsPosixTranslation(step.posixCommand)).toBe(true);
            expect(step.command).toBe(translatePosixShellToPowerShell(step.posixCommand));
            clonesTranslated += 1;
          }
        }
      }
    }
    // The catalog's source-build guides (~14 of 18) carry the bug; prove we hit
    // more than a couple so a regression that quietly stops translating is caught.
    expect(clonesTranslated).toBeGreaterThanOrEqual(10);
  });
});
