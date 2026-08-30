import { describe, expect, it } from "vitest";
import {
  cloneStepIndex,
  commandForPlatform,
  isDoneOnceOpened,
  isRunByIris,
  needsTheReader,
  workingDirectoryForPlatform,
  type InstallRecipe,
  type RecipeStep,
  type StepKind,
} from "../src/services/autopilot/recipe";
import { builtinRecipes, recipeForSlug } from "../src/services/autopilot/recipes";
import { isAPlainFolder } from "../src/services/autopilot/runner";

describe("step-kind routing", () => {
  it("sends a command to Iris and an open to auto-advance", () => {
    expect(isRunByIris("command")).toBe(true);
    expect(needsTheReader("command")).toBe(false);
    expect(isDoneOnceOpened("open")).toBe(true);
    expect(needsTheReader("open")).toBe(false);
  });

  it.each<StepKind>(["sign_in", "permission", "manual"])("keeps %s with the reader", (kind) => {
    expect(needsTheReader(kind)).toBe(true);
    expect(isRunByIris(kind)).toBe(false);
    expect(isDoneOnceOpened(kind)).toBe(false);
  });
});

describe("the built-in recipes", () => {
  it("finds OpenASCII and shapes it right", () => {
    const recipe = recipeForSlug("openascii");
    expect(recipe).toBeDefined();
    expect(recipe?.appName).toBe("OpenASCII");
    // It ends by starting a dev server and opening it — a local-web app.
    expect(recipe?.output.type).toBe("local_web");
    // The dev-server step must be long-running or the runner hangs on it.
    expect(recipe?.steps.some((step) => step.longRunning)).toBe(true);
    expect(recipe?.steps.some((step) => step.kind === "open")).toBe(true);
  });

  it("has no recipe for an unknown slug", () => {
    expect(recipeForSlug("not-a-real-app")).toBeUndefined();
  });

  it("picks the Windows command on win32 and the posix command elsewhere", () => {
    const step: RecipeStep = {
      id: "deps",
      title: "Install",
      kind: "command",
      command: "corepack.cmd pnpm install",
      posixCommand: "corepack pnpm install",
    };
    expect(commandForPlatform(step, "win32")).toBe("corepack.cmd pnpm install");
    expect(commandForPlatform(step, "darwin")).toBe("corepack pnpm install");
    expect(commandForPlatform(step, "linux")).toBe("corepack pnpm install");
  });

  it("falls back to the one command when there is no posix variant", () => {
    const step: RecipeStep = { id: "clone", title: "Clone", kind: "command", command: "git clone x" };
    expect(commandForPlatform(step, "win32")).toBe("git clone x");
    expect(commandForPlatform(step, "darwin")).toBe("git clone x");
  });

  it("gives OpenASCII a macOS variant for its Windows-only corepack step", () => {
    const deps = recipeForSlug("openascii")?.steps.find((step) => step.id === "dependencies");
    expect(deps?.command).toContain("corepack.cmd");
    expect(deps?.posixCommand).toBe("corepack pnpm install");
  });

  it("gives every recipe a slug and at least one step", () => {
    for (const recipe of builtinRecipes()) {
      expect(recipe.slug.length).toBeGreaterThan(0);
      expect(recipe.steps.length).toBeGreaterThan(0);
    }
  });
});

/**
 * The folder every step runs in, held to the same positional rule the published
 * guides are (`checkGuideInvariants` in publik/lib/guide-invariants.ts).
 *
 * The rule is positional rather than clever about which commands are relative,
 * because "does this command depend on the cwd" is not decidable from its text:
 * `npm.cmd install`, `node_modules\\.bin\\tauri.cmd build` and
 * `Get-ChildItem src-tauri\\target\\...` all do, and a rule that has to guess is a
 * rule that lets the next one through. Before this, the runner and its four
 * tests supported `workingDirectory` and not one shipped recipe declared one —
 * the field was plumbing with nothing plugged into it.
 */
describe("every shipped recipe says where its steps run", () => {
  /** Simulates the shell: the folder each step ends up in, following the `cd`s. */
  function foldersByInheritance(
    recipe: InstallRecipe,
    platform: NodeJS.Platform,
    home: string,
  ): Map<string, string> {
    const landedIn = new Map<string, string>();
    let cwd = home;
    for (const step of recipe.steps) {
      const command = commandForPlatform(step, platform);
      if (command === undefined) continue;
      landedIn.set(step.id, cwd);
      // Only the `cd`s in the recipes matter here, and they are all of the form
      // `cd <literal>` (possibly after a `mkdir -p`, on one line).
      for (const piece of command.split(";")) {
        const moved = /^\s*cd\s+(\S+)\s*$/.exec(piece);
        if (!moved) continue;
        const folder = moved[1]!;
        cwd = folder.startsWith("~") ? folder.replace("~", home) : `${cwd}/${folder}`;
      }
    }
    return landedIn;
  }

  for (const platform of ["win32", "darwin"] as const) {
    it.each(builtinRecipes().map((recipe) => [recipe.slug, recipe] as const))(
      `declares a folder for every %s step from the clone onward (${platform})`,
      (_slug, recipe) => {
        const clone = cloneStepIndex(recipe);
        expect(clone).toBeGreaterThanOrEqual(0);
        for (const step of recipe.steps.slice(clone)) {
          if (commandForPlatform(step, platform) === undefined) continue;
          expect(
            workingDirectoryForPlatform(step, platform),
            `${recipe.slug}/${step.id} would inherit whatever folder the shell happens to be in`,
          ).toBeDefined();
        }
      },
    );

    it.each(builtinRecipes().map((recipe) => [recipe.slug, recipe] as const))(
      `declares the folder %s's own cd steps actually produce (${platform})`,
      (_slug, recipe) => {
        // A declaration that disagrees with the linear run would be worse than
        // none: it would silently move the install somewhere it has never been
        // tested. So the declared folder must be exactly the inherited one.
        const inherited = foldersByInheritance(recipe, platform, "~");
        for (const step of recipe.steps) {
          const declared = workingDirectoryForPlatform(step, platform);
          if (declared === undefined) continue;
          expect(declared, `${recipe.slug}/${step.id}`).toBe(inherited.get(step.id));
        }
      },
    );
  }

  it("declares folders the runner will accept as plain paths", () => {
    for (const recipe of builtinRecipes()) {
      for (const step of recipe.steps) {
        for (const platform of ["win32", "darwin"] as const) {
          const declared = workingDirectoryForPlatform(step, platform);
          if (declared === undefined) continue;
          expect(isAPlainFolder(declared), `${recipe.slug}/${step.id}: ${declared}`).toBe(true);
        }
      }
    }
  });
});
