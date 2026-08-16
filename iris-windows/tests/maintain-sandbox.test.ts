import { describe, expect, it } from "vitest";
import {
  DEFAULT_WINDOWS_SANDBOX_LIMITS,
  WindowsJobObjectSandbox,
  buildJailedPowerShellScript,
  buildSandboxCleanupScript,
  buildSandboxIdentifiers,
  type WindowsSandboxIdentifiers,
} from "../src/services/maintain/sandbox";
import { MockMaintainShellRunner } from "../src/services/maintain/maintain-shell-runner";

/**
 * The Windows Job Object jail's pure half: string-builders that describe real
 * Win32 machinery (a Job Object, a restricted token, a scoped firewall rule)
 * but never execute anything themselves — see `sandbox.ts`'s header for why.
 * Everything here is checkable by substring on any host; the actual
 * containment behavior can only be proven on real Windows, which is out of
 * this suite's scope per the porting spec's §3/§7.
 */

const SAMPLE_IDENTIFIERS: WindowsSandboxIdentifiers = buildSandboxIdentifiers("fixed-jail-id", "C:\\Temp");

describe("buildSandboxIdentifiers", () => {
  it("derives every name/path from the jail id and temp directory", () => {
    const identifiers = buildSandboxIdentifiers("abc123", "C:\\Users\\reader\\AppData\\Local\\Temp");
    expect(identifiers.jailId).toBe("abc123");
    expect(identifiers.jobObjectName).toBe("iris-jail-abc123");
    expect(identifiers.firewallRuleName).toBe("iris-jail-abc123");
    expect(identifiers.copiedShellPath).toBe("C:\\Users\\reader\\AppData\\Local\\Temp\\iris-jail-abc123-shell.exe");
    expect(identifiers.stdoutFilePath).toBe("C:\\Users\\reader\\AppData\\Local\\Temp\\iris-jail-abc123-out.txt");
    expect(identifiers.stderrFilePath).toBe("C:\\Users\\reader\\AppData\\Local\\Temp\\iris-jail-abc123-err.txt");
  });

  it("trims a trailing backslash off the temp directory rather than doubling it", () => {
    const withTrailingSlash = buildSandboxIdentifiers("xyz", "C:\\Temp\\");
    const withoutTrailingSlash = buildSandboxIdentifiers("xyz", "C:\\Temp");
    expect(withTrailingSlash).toEqual(withoutTrailingSlash);
    expect(withTrailingSlash.copiedShellPath).toBe("C:\\Temp\\iris-jail-xyz-shell.exe");
  });

  it("always builds a Windows-flavored (backslash) path, regardless of host OS", () => {
    // The script this feeds only ever runs on Windows, so the identifiers
    // must describe a Windows path even when this test itself runs on the
    // Mac dev machine — using `node:path` here would silently use `/` and
    // produce a broken script. See the function's own header comment.
    const identifiers = buildSandboxIdentifiers("id", "C:\\Temp");
    expect(identifiers.stdoutFilePath).not.toContain("/");
  });
});

describe("buildJailedPowerShellScript", () => {
  const script = buildJailedPowerShellScript({
    command: "Get-ChildItem -Path .",
    repoRootPath: "C:\\repo",
    identifiers: SAMPLE_IDENTIFIERS,
    limits: DEFAULT_WINDOWS_SANDBOX_LIMITS,
  });

  it("embeds the command as a single-quoted PowerShell literal", () => {
    expect(script).toContain("$innerCommandScript = 'Get-ChildItem -Path .'");
  });

  it("doubles an embedded single quote when escaping the command", () => {
    const withQuote = buildJailedPowerShellScript({
      command: "Write-Output 'it''s a test'",
      repoRootPath: "C:\\repo",
      identifiers: SAMPLE_IDENTIFIERS,
      limits: DEFAULT_WINDOWS_SANDBOX_LIMITS,
    });
    expect(withQuote).toContain("'Write-Output ''it''''s a test'''");
  });

  it("sets the child's working directory to repoRootPath", () => {
    expect(script).toContain("$repoRootPath = 'C:\\repo'");
    // Passed as CreateProcessAsUser's lpCurrentDirectory argument.
    expect(script).toContain("$repoRootPath, [ref]$startupInfo, [ref]$processInfo");
  });

  it("registers a firewall outbound-block rule scoped to the copied shell binary", () => {
    expect(script).toContain(`name="$firewallRuleName"`);
    expect(script).toContain("dir=out");
    expect(script).toContain("action=block");
    expect(script).toContain("Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination $shellCopyPath");
  });

  it("removes the firewall rule unconditionally as part of its own cleanup", () => {
    expect(script).toContain('netsh advfirewall firewall delete rule name="$firewallRuleName"');
  });

  it("creates a Job Object with KILL_ON_JOB_CLOSE and the configured resource ceilings", () => {
    expect(script).toContain("CreateJobObject");
    expect(script).toContain("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE");
    expect(script).toContain("JOB_OBJECT_LIMIT_ACTIVE_PROCESS");
    expect(script).toContain("JOB_OBJECT_LIMIT_JOB_MEMORY");
    expect(script).toContain(`ActiveProcessLimit = [uint32]${DEFAULT_WINDOWS_SANDBOX_LIMITS.maximumActiveProcesses}`);
    expect(script).toContain(`JobMemoryLimit = [UIntPtr]${DEFAULT_WINDOWS_SANDBOX_LIMITS.maximumJobMemoryBytes}`);
  });

  it("closes the job's handle unconditionally, which is what reaps orphaned children", () => {
    expect(script).toContain("[IrisJail.Native]::CloseHandle($job) | Out-Null");
  });

  it("derives a restricted token with DISABLE_MAX_PRIVILEGE from the caller's own token", () => {
    expect(script).toContain("CreateRestrictedToken");
    expect(script).toContain("DISABLE_MAX_PRIVILEGE");
    // Falls back to the unrestricted token rather than aborting if the
    // restricted-token creation fails — best-effort, per the module header.
    expect(script).toContain("$tokenForChild = if ($haveRestrictedToken) { $restrictedToken } else { $currentProcessToken }");
  });

  it("uses CreateProcessAsUser, never a plain Start-Process, to hand off the restricted token", () => {
    expect(script).toContain("CreateProcessAsUser($tokenForChild");
  });

  it("points HTTP_PROXY/HTTPS_PROXY/ALL_PROXY at a black hole for the child, and restores them after", () => {
    for (const variable of ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]) {
      expect(script).toContain(`SetEnvironmentVariable('${variable}', 'http://127.0.0.1:1', 'Process')`);
    }
    expect(script).toContain("$previousHttpProxy = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process')");
    expect(script).toContain("SetEnvironmentVariable('HTTP_PROXY', $previousHttpProxy, 'Process')");
  });

  it("never mentions Seatbelt-style filesystem containment — this jail does not provide it", () => {
    expect(script.toLowerCase()).not.toContain("seatbelt");
  });

  it("respects a caller-supplied resource ceiling rather than always emitting the default", () => {
    const customLimits = { maximumActiveProcesses: 4, maximumJobMemoryBytes: 123_456 };
    const customScript = buildJailedPowerShellScript({
      command: "whoami",
      repoRootPath: "C:\\repo",
      identifiers: SAMPLE_IDENTIFIERS,
      limits: customLimits,
    });
    expect(customScript).toContain("ActiveProcessLimit = [uint32]4");
    expect(customScript).toContain("JobMemoryLimit = [UIntPtr]123456");
  });
});

describe("buildSandboxCleanupScript", () => {
  it("removes the firewall rule and every temp file this invocation created, tolerating absence", () => {
    const cleanupScript = buildSandboxCleanupScript(SAMPLE_IDENTIFIERS);
    expect(cleanupScript).toContain(`netsh advfirewall firewall delete rule name='${SAMPLE_IDENTIFIERS.firewallRuleName}'`);
    expect(cleanupScript).toContain(`Remove-Item -LiteralPath '${SAMPLE_IDENTIFIERS.copiedShellPath}' -Force -ErrorAction SilentlyContinue`);
    expect(cleanupScript).toContain(`Remove-Item -LiteralPath '${SAMPLE_IDENTIFIERS.stdoutFilePath}' -Force -ErrorAction SilentlyContinue`);
    expect(cleanupScript).toContain(`Remove-Item -LiteralPath '${SAMPLE_IDENTIFIERS.stderrFilePath}' -Force -ErrorAction SilentlyContinue`);
  });
});

describe("WindowsJobObjectSandbox.isAvailable", () => {
  it("reports available on win32", () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "win32" });
    expect(sandbox.isAvailable()).toEqual({ available: true });
  });

  it("reports unavailable, with a reason, on any non-Windows platform", () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "darwin" });
    const availability = sandbox.isAvailable();
    expect(availability.available).toBe(false);
    expect(availability.reason).toMatch(/only available on Windows/);
  });
});

describe("WindowsJobObjectSandbox.jailedInvocation", () => {
  it("returns undefined for a blank or whitespace-only command — nothing to jail", () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "win32" });
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    expect(sandbox.jailedInvocation({ command: "", repoRootPath: "C:\\repo", runner })).toBeUndefined();
    expect(sandbox.jailedInvocation({ command: "   ", repoRootPath: "C:\\repo", runner })).toBeUndefined();
  });

  it("builds a script embedding the given command and repo root, with a fresh id per call", () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "win32", generateJailId: () => "deterministic-id" });
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const jailed = sandbox.jailedInvocation({ command: "git status", repoRootPath: "C:\\repo", runner });
    expect(jailed).toBeDefined();
    expect(jailed?.invocation).toContain("$innerCommandScript = 'git status'");
    expect(jailed?.invocation).toContain("$repoRootPath = 'C:\\repo'");
    expect(jailed?.invocation).toContain("iris-jail-deterministic-id");
  });

  it("generates a new jail id (and therefore new identifiers) on every call by default", () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "win32" });
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const first = sandbox.jailedInvocation({ command: "whoami", repoRootPath: "C:\\repo", runner });
    const second = sandbox.jailedInvocation({ command: "whoami", repoRootPath: "C:\\repo", runner });
    expect(first?.invocation).not.toBe(second?.invocation);
  });

  it("cleanup() runs the cleanup script through the caller's own runner", async () => {
    const sandbox = new WindowsJobObjectSandbox({ platform: "win32", generateJailId: () => "cleanup-test-id" });
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const jailed = sandbox.jailedInvocation({ command: "git status", repoRootPath: "C:\\repo", runner });
    expect(jailed).toBeDefined();

    await jailed?.cleanup();

    expect(runner.commandsRun).toHaveLength(1);
    expect(runner.commandsRun[0]).toContain("iris-jail-cleanup-test-id");
    expect(runner.commandsRun[0]).toContain("netsh advfirewall firewall delete rule");
  });

  it("respects a caller-supplied resource limit override end to end", () => {
    const sandbox = new WindowsJobObjectSandbox({
      platform: "win32",
      limits: { maximumActiveProcesses: 2, maximumJobMemoryBytes: 999 },
    });
    const runner = MockMaintainShellRunner.alwaysSucceeds();
    const jailed = sandbox.jailedInvocation({ command: "whoami", repoRootPath: "C:\\repo", runner });
    expect(jailed?.invocation).toContain("ActiveProcessLimit = [uint32]2");
    expect(jailed?.invocation).toContain("JobMemoryLimit = [UIntPtr]999");
  });
});
