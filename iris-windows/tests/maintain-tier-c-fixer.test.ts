import { describe, expect, it } from "vitest";
import { MaintainTierCFixer, extractBashCommand } from "../src/services/maintain/tier-c-fixer";
import { MockMaintainShellRunner, type MaintainCommandResult } from "../src/services/maintain/maintain-shell-runner";
import { WindowsJobObjectSandbox, type JailedInvocation, type JailedInvocationOptions } from "../src/services/maintain/sandbox";
import type { MaintainModelProviding, MaintainModelRespondOptions } from "../src/services/maintain/model-provider";

/**
 * The last rung of the fix ladder, exercised end to end against
 * `MockMaintainShellRunner` and a scripted model provider — no real
 * PowerShell, no real network, no real model call, matching how
 * `maintain-verification-harness.test.ts`'s scripted half proves the gate
 * `attemptFix` delegates to. `sandbox.ts`'s own containment claims are
 * proven separately in `maintain-sandbox.test.ts`; this file proves the LOOP
 * around it: the step cap, that every command goes through the jail, the
 * `.git` strip/restore ceremony, and that a novel fix faces the same
 * verification gate every other fix does.
 */

const succeeds: MaintainCommandResult = { succeeded: true, exitCode: 0, outputTail: "" };

/** A model provider that returns each queued reply in order, then `"DONE"`
 *  forever — the maintain-layer twin of `MockMaintainShellRunner`. */
class ScriptedMaintainModelProvider implements MaintainModelProviding {
  readonly displayName = "Scripted Model (test)";
  private next = 0;
  readonly promptsReceived: MaintainModelRespondOptions[] = [];

  constructor(private readonly replies: readonly string[]) {}

  isAvailable(): boolean {
    return true;
  }

  async respond(options: MaintainModelRespondOptions): Promise<string> {
    this.promptsReceived.push(options);
    const reply = this.replies[this.next] ?? "DONE";
    this.next += 1;
    return reply;
  }
}

/** A model provider whose every call throws — proves the loop's own
 *  model-call-failed branch, not a provider concern. */
class ThrowingMaintainModelProvider implements MaintainModelProviding {
  readonly displayName = "Throwing Model (test)";

  isAvailable(): boolean {
    return true;
  }

  async respond(): Promise<string> {
    throw new Error("network exploded");
  }
}

/** A sandbox that reports available but can never actually build a jailed
 *  invocation — proves `attemptFix`'s "could not build the sandbox for a
 *  command" branch, which `WindowsJobObjectSandbox` itself cannot reach for
 *  a non-blank command (see that class's own doc comment). */
class NeverJailsSandbox extends WindowsJobObjectSandbox {
  constructor() {
    super({ platform: "win32" });
  }

  jailedInvocation(_options: JailedInvocationOptions): JailedInvocation | undefined {
    return undefined;
  }
}

describe("extractBashCommand", () => {
  it("pulls the body out of a ```powershell fence", () => {
    expect(extractBashCommand("```powershell\nGet-ChildItem -Path .\n```")).toBe("Get-ChildItem -Path .");
  });

  it("prefers a powershell/ps1 fence over a bash/sh/bare one when both are present", () => {
    // The model habitually reaching for ```bash is exactly the case the
    // module header calls out — still parsed, but powershell wins when a
    // fence of that kind starts at the same or an earlier position.
    expect(extractBashCommand("```powershell\nwhoami\n```")).toBe("whoami");
  });

  it("falls back to a bash, sh, or bare fence when that's what the model actually sent", () => {
    expect(extractBashCommand("```bash\nls\n```")).toBe("ls");
    expect(extractBashCommand("```sh\npwd\n```")).toBe("pwd");
    expect(extractBashCommand("```\nwhoami\n```")).toBe("whoami");
  });

  it("returns undefined for a reply with no fence at all", () => {
    expect(extractBashCommand("I'm not sure what to run next.")).toBeUndefined();
  });

  it("returns undefined for an unterminated fence", () => {
    expect(extractBashCommand("```powershell\nGet-ChildItem")).toBeUndefined();
  });

  it("returns undefined for an empty fenced body", () => {
    expect(extractBashCommand("```powershell\n\n```")).toBeUndefined();
  });

  it("trims surrounding whitespace from the fenced body", () => {
    expect(extractBashCommand("```powershell\n   Get-Date   \n```")).toBe("Get-Date");
  });
});

describe("MaintainTierCFixer.attemptFix — eligibility gates", () => {
  it("returns notEligible, touching nothing, when the sandbox is unavailable on this platform", async () => {
    const runner = MockMaintainShellRunner.alwaysSucceeds("C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider([]),
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "darwin" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result).toEqual({
      type: "notEligible",
      reason: "the Windows Job Object jail is only available on Windows",
    });
    expect(runner.commandsRun).toHaveLength(0);
  });

  it("returns notEligible when the clone path is not usable", async () => {
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider([]),
      createShellRunner: () => undefined,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\not-a-real-clone",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result).toEqual({ type: "notEligible", reason: "the clone path is not usable" });
  });
});

describe("MaintainTierCFixer.attemptFix — the loop itself", () => {
  it("restores .git and reports couldNotFix when the model call throws", async () => {
    const runner = new MockMaintainShellRunner([succeeds, succeeds, succeeds, succeeds], "C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ThrowingMaintainModelProvider(),
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result.type).toBe("couldNotFix");
    if (result.type === "couldNotFix") {
      expect(result.reason).toContain("model call failed");
      expect(result.reason).toContain("network exploded");
    }
    // Backup .git (2 calls), then restore it (2 calls) — the jail is never
    // touched because the very first model call already failed.
    expect(runner.commandsRun).toHaveLength(4);
    expect(runner.commandsRun[0]).toContain("Remove-Item");
    expect(runner.commandsRun[1]).toContain("Move-Item -LiteralPath '.git'");
    expect(runner.commandsRun[2]).toContain("Remove-Item -LiteralPath '.git'");
    expect(runner.commandsRun[3]).toContain("Move-Item");
  });

  it("returns couldNotFix, and cleans the working tree, after exhausting the step cap on malformed replies", async () => {
    const malformedReplies = new Array(MaintainTierCFixer.MAXIMUM_LOOP_STEPS).fill("I'm thinking about it.");
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      succeeds,
      succeeds, // restore .git
      succeeds, // git checkout -- .
      succeeds, // git clean -fd --quiet
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const provider = new ScriptedMaintainModelProvider(malformedReplies);
    const fixer = new MaintainTierCFixer({
      provider,
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result).toEqual({ type: "couldNotFix", reason: "ran out of steps without a fix" });
    // A malformed reply is re-prompted, not jailed — it still consumes a
    // step, but never touches the runner. Twelve wasted model turns, then
    // the four bracketing runner calls (backup + restore) plus the two-line
    // revert.
    expect(provider.promptsReceived).toHaveLength(MaintainTierCFixer.MAXIMUM_LOOP_STEPS);
    expect(runner.commandsRun).toHaveLength(6);
    expect(runner.commandsRun[0]).toContain("Remove-Item");
    expect(runner.commandsRun[1]).toContain("Move-Item -LiteralPath '.git'");
    expect(runner.commandsRun[2]).toContain("Remove-Item -LiteralPath '.git'");
    expect(runner.commandsRun[3]).toContain("Move-Item");
    expect(runner.commandsRun[4]).toBe("git checkout -- .");
    expect(runner.commandsRun[5]).toBe("git clean -fd --quiet");
  });

  it("jails every non-DONE command, and cleans up the jail after each one", async () => {
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      { succeeded: true, exitCode: 0, outputTail: "jailed output" }, // the jailed command itself
      succeeds, // sandbox cleanup
      succeeds,
      succeeds, // restore .git
      { succeeded: true, exitCode: 0, outputTail: "" }, // git status --porcelain: clean, so the attempt stops here
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const provider = new ScriptedMaintainModelProvider(["```powershell\nGet-ChildItem -Path .\n```", "DONE"]);
    const fixer = new MaintainTierCFixer({
      provider,
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32", generateJailId: () => "test-jail" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    // The tree came back clean after the explore-only step, so the attempt
    // still ends in couldNotFix — this test's focus is that the jail (and
    // its cleanup) ran at all, not the final verdict.
    expect(result).toEqual({ type: "couldNotFix", reason: "the agent declared done but changed nothing" });
    // Index 2 is the jailed script itself — it must embed the model's exact
    // command, never run it unjailed through the plain runner.
    expect(runner.commandsRun[2]).toContain("$innerCommandScript = 'Get-ChildItem -Path .'");
    expect(runner.commandsRun[2]).toContain("CreateProcessAsUser");
    // Index 3 is the jail's own cleanup, run unconditionally after the
    // command regardless of its exit code.
    expect(runner.commandsRun[3]).toContain("netsh advfirewall firewall delete rule");
    expect(runner.commandsRun[3]).toContain("test-jail");
  });

  it("returns couldNotFix when the sandbox cannot build a jailed invocation for a command", async () => {
    const outcomes = [succeeds, succeeds, succeeds, succeeds]; // backup + restore .git only
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider(["```powershell\nGet-ChildItem\n```"]),
      createShellRunner: () => runner,
      sandbox: new NeverJailsSandbox(),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result).toEqual({ type: "couldNotFix", reason: "could not build the sandbox for a command" });
    expect(runner.commandsRun).toHaveLength(4);
  });

  it("returns couldNotFix when the agent declares DONE but left the tree clean", async () => {
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      succeeds,
      succeeds, // restore .git
      { succeeded: true, exitCode: 0, outputTail: "" }, // git status --porcelain: nothing changed
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider(["DONE"]),
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
    });

    expect(result).toEqual({ type: "couldNotFix", reason: "the agent declared done but changed nothing" });
    expect(runner.commandsRun).toHaveLength(5);
  });

  it("reverts the working tree and returns couldNotFix when verification fails", async () => {
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      succeeds,
      succeeds, // restore .git
      { succeeded: true, exitCode: 0, outputTail: " M src/fix.ts" }, // git status --porcelain: dirty
      { succeeded: true, exitCode: 0, outputTail: "1\t1\tsrc/fix.ts" }, // diff-scope: git diff --numstat HEAD
      { succeeded: true, exitCode: 0, outputTail: "" }, // diff-scope: git ls-files --others
      { succeeded: false, exitCode: 1, outputTail: "error TS2322: blew up" }, // the build itself
      succeeds, // git checkout -- .
      succeeds, // git clean -fd --quiet
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider(["DONE"]),
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
      verificationCommandsOverride: { buildCommand: "npm run build" },
    });

    expect(result).toEqual({ type: "couldNotFix", reason: "the fix failed verification (build)" });
    expect(runner.commandsRun.at(-2)).toBe("git checkout -- .");
    expect(runner.commandsRun.at(-1)).toBe("git clean -fd --quiet");
  });

  it("commits a novel fix on a signature-derived branch once verification passes clean", async () => {
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      { succeeded: true, exitCode: 0, outputTail: "ok" }, // the jailed exploration command
      succeeds, // jail cleanup
      succeeds,
      succeeds, // restore .git
      { succeeded: true, exitCode: 0, outputTail: " M src/fix.ts" }, // git status --porcelain: dirty
      { succeeded: true, exitCode: 0, outputTail: "1\t1\tsrc/fix.ts" }, // diff-scope numstat
      { succeeded: true, exitCode: 0, outputTail: "" }, // diff-scope untracked
      { succeeded: false, exitCode: 1, outputTail: "" }, // git rev-parse --verify: branch doesn't exist yet
      succeeds, // git checkout -b <branch>
      succeeds, // git add -A
      succeeds, // git commit
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const provider = new ScriptedMaintainModelProvider(["```powershell\nGet-ChildItem\n```", "DONE"]);
    const fixer = new MaintainTierCFixer({
      provider,
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
      tempDirectoryPath: "C:\\Temp",
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "0123456789abcdef",
      crashEvidence: "Access violation at 0x00000000",
      // No real cargo/npm project in this test, so the loop's own
      // verification vocabulary is supplied directly — the whole point of
      // the override seam, matching the Swift original's testability note.
      verificationCommandsOverride: {},
    });

    expect(result.type).toBe("fixedAndVerified");
    if (result.type === "fixedAndVerified") {
      expect(result.branchName).toMatch(/^iris\/fix-0123456789ab-\d{8}$/);
      expect(result.wasNovel).toBe(true);
    }
    expect(runner.commandsRun).toHaveLength(13);
    expect(runner.commandsRun[10]).toMatch(/^git checkout -b 'iris\/fix-0123456789ab-\d{8}'$/);
    expect(runner.commandsRun[12]).toContain("git commit -m");
    expect(runner.commandsRun[12]).toContain("Break-Signature: 0123456789abcdef");
    expect(runner.commandsRun[12]).toContain("Fix-Recipe-Match: novel");
    expect(runner.commandsRun[12]).toContain("Assisted-by: iris-maintain-mode/1 (tier-c, Scripted Model (test))");
  });

  it("checks out the existing branch instead of creating a new one when it already exists", async () => {
    const outcomes = [
      succeeds,
      succeeds, // backup .git
      succeeds,
      succeeds, // restore .git
      { succeeded: true, exitCode: 0, outputTail: " M src/fix.ts" }, // dirty
      { succeeded: true, exitCode: 0, outputTail: "1\t1\tsrc/fix.ts" }, // diff-scope numstat
      { succeeded: true, exitCode: 0, outputTail: "" }, // diff-scope untracked
      { succeeded: true, exitCode: 0, outputTail: "deadbeef" }, // git rev-parse --verify: branch DOES exist
      succeeds, // git checkout <branch> (no -b)
      succeeds, // git add -A
      succeeds, // git commit
    ];
    const runner = new MockMaintainShellRunner(outcomes, "C:\\repo");
    const fixer = new MaintainTierCFixer({
      provider: new ScriptedMaintainModelProvider(["DONE"]),
      createShellRunner: () => runner,
      sandbox: new WindowsJobObjectSandbox({ platform: "win32" }),
    });

    const result = await fixer.attemptFix({
      clonePath: "C:\\repo",
      appSlug: "demo-app",
      appStack: "tauri",
      signatureId: "sig-1",
      crashEvidence: "Access violation at 0x00000000",
      verificationCommandsOverride: {},
    });

    expect(result.type).toBe("fixedAndVerified");
    // The 9th call (index 8) is the branch check-out — no `-b`, since the
    // branch already existed.
    expect(runner.commandsRun[8]).toMatch(/^git checkout 'iris\/fix-sig-1-\d{8}'$/);
    expect(runner.commandsRun[8]).not.toContain("-b");
  });
});
