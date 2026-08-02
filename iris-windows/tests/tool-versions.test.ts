import { describe, expect, it } from "vitest";
import {
  boundedCommandOutput,
  isAllowlistedTool,
  toolSpecFor,
} from "../src/services/tool-versions";

/**
 * A guide is server-served content: it changes without a client release, and no
 * reviewer of this binary saw it. So the set of programs a guide can cause Iris
 * to execute has to be fixed here, in the client, and nothing in the command may
 * come from guide text.
 */

describe("only allowlisted tools can ever be run", () => {
  it.each(["git", "node", "npm", "pnpm", "bun", "python", "python3", "uv", "cargo", "rustc", "docker", "java", "adb"])(
    "allows the known tool %s",
    (tool) => {
      expect(isAllowlistedTool(tool)).toBe(true);
      expect(toolSpecFor(tool)).not.toBeNull();
    }
  );

  it.each([
    "cmd",
    "powershell",
    "rm",
    "curl",
    "git; rm -rf /",
    "git --version && calc",
    "../../../windows/system32/cmd.exe",
    "",
    "NODE",
  ])("refuses %s", (tool) => {
    expect(isAllowlistedTool(tool)).toBe(false);
    expect(toolSpecFor(tool)).toBeNull();
  });

  it("builds arguments from a constant, never from the caller", () => {
    // The spec is a fixed pair. There is no place for guide-supplied text to
    // enter the argument list.
    const spec = toolSpecFor("git");
    expect(spec).toEqual(["git", ["--version"]]);
    expect(toolSpecFor("adb")).toEqual(["adb", ["version"]]);
  });
});

describe("command output is bounded", () => {
  it("takes the first line only", () => {
    expect(boundedCommandOutput("git version 2.43.0\nextra noise\nmore", "")).toBe(
      "git version 2.43.0"
    );
  });

  it("handles Windows line endings", () => {
    expect(boundedCommandOutput("v22.11.0\r\n", "")).toBe("v22.11.0");
  });

  it("falls back to stderr, which is where some tools print their version", () => {
    expect(boundedCommandOutput("", "openjdk version \"21\"")).toBe('openjdk version "21"');
  });

  it("truncates a program that will not stop talking", () => {
    expect(boundedCommandOutput("x".repeat(10_000), "").length).toBeLessThanOrEqual(200);
  });

  it("returns an empty string when there is nothing at all", () => {
    expect(boundedCommandOutput("", "")).toBe("");
  });
});
