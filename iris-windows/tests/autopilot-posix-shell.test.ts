import { describe, expect, it } from "vitest";
import { wrapPosixCommand } from "../src/main/posix-shell-session";
import { parseRun } from "../src/main/powershell-session";

/**
 * The POSIX shell spawns zsh and only does real work on a Mac, but its command
 * wrapping is pure — and it emits the same marker lines the PowerShell session
 * does, so `parseRun` reads a Mac run exactly like a Windows one. Pinned here.
 */

describe("POSIX command wrapping", () => {
  it("pins the location, runs the command, and appends both markers", () => {
    const script = wrapPosixCommand("git status", "/Users/me/repo");
    expect(script).toContain("cd '/Users/me/repo'");
    expect(script).toContain("git status");
    expect(script).toContain("__IRIS_CODE__:");
    expect(script).toContain("__IRIS_CWD__:");
  });

  it("single-quotes the directory so a space or apostrophe cannot break out", () => {
    expect(wrapPosixCommand("ls", "/Users/me/my apps")).toContain("cd '/Users/me/my apps'");
  });

  it("produces marker output the shared parser reads the same as Windows", () => {
    // Simulate what the wrapped script prints to stdout on a Mac.
    const stdout = ["Cloning into 'OpenASCII'...", "__IRIS_CWD__:/Users/me/iris-apps", "__IRIS_CODE__:0"].join("\n");
    const parsed = parseRun(stdout, "");
    expect(parsed.exitCode).toBe(0);
    expect(parsed.cwd).toBe("/Users/me/iris-apps");
    expect(parsed.output).toBe("Cloning into 'OpenASCII'...");
  });
});
