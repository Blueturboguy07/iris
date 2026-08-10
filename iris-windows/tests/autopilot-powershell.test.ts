import { describe, expect, it } from "vitest";
import {
  encodeForPowerShell,
  parseRun,
  psSingleQuote,
  wrapCommandScript,
} from "../src/main/powershell-session";

/**
 * The PowerShell session spawns real processes and only runs on Windows CI, but
 * its parsing and quoting are pure — and they are where a subtle bug (a
 * misparsed exit code, a path that breaks out of Set-Location) would do real
 * damage. So those are pinned down here, on any host.
 */

describe("PowerShell command wrapping", () => {
  it("single-quotes a path and doubles embedded quotes", () => {
    expect(psSingleQuote("C:\\Users\\me")).toBe("'C:\\Users\\me'");
    expect(psSingleQuote("C:\\it's here")).toBe("'C:\\it''s here'");
  });

  it("pins the location and appends the exit-code and cwd markers", () => {
    const script = wrapCommandScript("git status", "C:\\repo");
    expect(script).toContain("Set-Location -LiteralPath 'C:\\repo'");
    expect(script).toContain("& { git status }");
    expect(script).toContain("__IRIS_CODE__:");
    expect(script).toContain("__IRIS_CWD__:");
  });

  it("encodes a script as UTF-16LE base64 that round-trips", () => {
    const encoded = encodeForPowerShell("Write-Output 'hi'");
    expect(Buffer.from(encoded, "base64").toString("utf16le")).toBe("Write-Output 'hi'");
  });
});

describe("parsing a completed run", () => {
  it("pulls the exit code and new directory, and strips the marker lines", () => {
    const stdout = ["Cloning into 'x'...", "done.", "__IRIS_CWD__:C:\\Users\\me\\x", "__IRIS_CODE__:0"].join("\r\n");
    const parsed = parseRun(stdout, "");
    expect(parsed.exitCode).toBe(0);
    expect(parsed.cwd).toBe("C:\\Users\\me\\x");
    expect(parsed.output).toBe("Cloning into 'x'...\ndone.");
    expect(parsed.output).not.toContain("__IRIS_");
  });

  it("reports a non-zero exit and folds stderr into the output", () => {
    const stdout = ["npm ERR! missing script: build", "__IRIS_CWD__:C:\\repo", "__IRIS_CODE__:1"].join("\n");
    const parsed = parseRun(stdout, "some stderr noise");
    expect(parsed.exitCode).toBe(1);
    expect(parsed.output).toContain("npm ERR!");
    expect(parsed.output).toContain("some stderr noise");
  });

  it("treats missing markers as a failed run rather than a silent success", () => {
    // If PowerShell died before printing the markers, there is no code to read —
    // the caller defaults that to a failure, never a pass.
    const parsed = parseRun("partial output with no markers", "");
    expect(parsed.exitCode).toBeUndefined();
  });
});
