import { readFileSync } from "node:fs";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

import { buildCanProvisionAutomatically, publikAppToken } from "../src/main/publik-app-token";

/**
 * The app token ships inside the binary, substituted at package time by the
 * "Bake the publik app token" step in .github/workflows/iris-release.yml. That
 * step does a literal string replacement on this file's source, which makes the
 * shape of one line load-bearing in a way nothing else would catch:
 *
 *   - rename the constant, reformat the line, switch the quotes, or let a
 *     formatter collapse it, and the replacement finds nothing;
 *   - the step fails loudly on that (it greps before writing), but only in CI,
 *     and only when someone happens to cut a release.
 *
 * The failure it protects against is silent in the worst way: the build still
 * compiles, still packages, still signs, still installs — and every new user
 * lands on "paste a key" instead of provisioning automatically, with nobody
 * finding out until somebody installs it. So the placeholder's exact text is
 * asserted here, where a rename fails on the next `npm test`.
 */

const SOURCE_PATH = path.join(__dirname, "..", "src", "main", "publik-app-token.ts");

/** The exact string .github/workflows/iris-release.yml searches for. */
const PLACEHOLDER = `const BAKED_APP_TOKEN = "";`;

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("the baked app token placeholder", () => {
  it("is exactly the string the release workflow replaces", () => {
    const source = readFileSync(SOURCE_PATH, "utf8");
    expect(
      source.includes(PLACEHOLDER),
      `src/main/publik-app-token.ts no longer contains ${PLACEHOLDER}. The release ` +
        `workflow's "Bake the publik app token" step does a literal replacement on ` +
        `that string — update the step in the same commit, or releases ship a build ` +
        `that silently cannot provision.`
    ).toBe(true);
  });

  it("appears exactly once, so the substitution cannot hit the wrong line", () => {
    const source = readFileSync(SOURCE_PATH, "utf8");
    const occurrences = source.split(PLACEHOLDER).length - 1;
    expect(occurrences).toBe(1);
  });

  it("ships empty in source, because iris is a public repo", () => {
    // A real token committed here would be harvestable by everyone reading the
    // repo at once, rather than by whoever unpacks an installer. Injected at
    // package time precisely so it never enters git history.
    const source = readFileSync(SOURCE_PATH, "utf8");
    expect(source).not.toMatch(/const BAKED_APP_TOKEN = "pat_/);
  });
});

describe("publikAppToken", () => {
  it("is null in a build with neither an env var nor a baked token", () => {
    vi.stubEnv("PUBLIK_APP_TOKEN", "");
    expect(publikAppToken()).toBeNull();
    expect(buildCanProvisionAutomatically()).toBe(false);
  });

  it("takes the environment when one is set, for local development", () => {
    vi.stubEnv("PUBLIK_APP_TOKEN", "pat_iris_abcdefghijklmnopqrstuvwxyz012345");
    expect(publikAppToken()).toBe("pat_iris_abcdefghijklmnopqrstuvwxyz012345");
    expect(buildCanProvisionAutomatically()).toBe(true);
  });

  it("trims the environment value, so a stray newline is not a token", () => {
    vi.stubEnv("PUBLIK_APP_TOKEN", "  pat_iris_abcdefghijklmnopqrstuvwxyz012345\n");
    expect(publikAppToken()).toBe("pat_iris_abcdefghijklmnopqrstuvwxyz012345");
  });

  it("treats a whitespace-only environment value as absent", () => {
    vi.stubEnv("PUBLIK_APP_TOKEN", "   ");
    expect(publikAppToken()).toBeNull();
  });
});
