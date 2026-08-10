import { describe, expect, it } from "vitest";
import {
  commandForPlatform,
  isDoneOnceOpened,
  isRunByIris,
  needsTheReader,
  type RecipeStep,
  type StepKind,
} from "../src/services/autopilot/recipe";
import { builtinRecipes, recipeForSlug } from "../src/services/autopilot/recipes";

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
