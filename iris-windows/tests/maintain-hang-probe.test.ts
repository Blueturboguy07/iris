import { describe, expect, it, vi } from "vitest";
import {
  HANG_PROBE_CONSECUTIVE_FAILURES_BEFORE_CONFIRMING,
  HangProbe,
  buildGetProcessResponsiveCommand,
  checkProcessResponsiveViaPowerShell,
  parseGetProcessResponsiveOutput,
  type CheckProcessResponsive,
  type HangProbeVerdict,
  type SpawnedProcessLike,
} from "../src/services/maintain/hang-probe";

/**
 * `HangProbe`'s decision logic — consecutive-failure counting, the N-of-M
 * escalation threshold, forget-on-recovery, the one-probe-in-flight-per-pid
 * guard — must match `HangProbe.swift` exactly, even though the mechanism
 * answering "is it responding" is completely different (Get-Process vs. an
 * AX timeout). Then the real Windows call gets its own coverage, entirely
 * offline via a fake child process, per the file header's "even the real
 * half stays testable everywhere" claim.
 */

function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void } {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

describe("HangProbe — the pure state machine", () => {
  it("reports unresponsiveButBelowThreshold with an increasing count, below the threshold", async () => {
    const verdicts: HangProbeVerdict[] = [];
    const checkResponsive: CheckProcessResponsive = async () => false;
    const probe = new HangProbe({ checkResponsive, onVerdict: (_, v) => verdicts.push(v) });

    await probe.probe(100);
    await probe.probe(100);
    await probe.probe(100);

    expect(verdicts).toEqual([
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 },
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 2 },
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 3 },
    ]);
  });

  it("confirms a hang on the Nth consecutive failure, with unresponsiveSeconds from the injected clock", async () => {
    const verdicts: HangProbeVerdict[] = [];
    let now = 0;
    const checkResponsive: CheckProcessResponsive = async () => false;
    const probe = new HangProbe({ checkResponsive, nowEpochMs: () => now, onVerdict: (_, v) => verdicts.push(v) });

    for (let i = 0; i < HANG_PROBE_CONSECUTIVE_FAILURES_BEFORE_CONFIRMING - 1; i += 1) {
      await probe.probe(200);
      now += 1_000;
    }
    now = 9_000; // first failure was at t=0
    await probe.probe(200);

    expect(verdicts.at(-1)).toEqual({ kind: "confirmedHang", unresponsiveSeconds: 9 });
  });

  it("respects a lower injected threshold", async () => {
    const verdicts: HangProbeVerdict[] = [];
    const checkResponsive: CheckProcessResponsive = async () => false;
    const probe = new HangProbe({
      checkResponsive,
      consecutiveFailuresBeforeConfirming: 2,
      onVerdict: (_, v) => verdicts.push(v),
    });

    await probe.probe(300);
    await probe.probe(300);

    expect(verdicts).toEqual([
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 },
      { kind: "confirmedHang", unresponsiveSeconds: 0 },
    ]);
  });

  it("resets the counter on a responsive answer, so a later run of failures starts over from one", async () => {
    const verdicts: HangProbeVerdict[] = [];
    const answers = [false, false, true, false];
    let index = 0;
    const checkResponsive: CheckProcessResponsive = async () => answers[index++] ?? false;
    const probe = new HangProbe({
      checkResponsive,
      consecutiveFailuresBeforeConfirming: 3,
      onVerdict: (_, v) => verdicts.push(v),
    });

    await probe.probe(400); // fail 1
    await probe.probe(400); // fail 2
    await probe.probe(400); // responsive — resets
    await probe.probe(400); // fail 1 again, not fail 3

    expect(verdicts).toEqual([
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 },
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 2 },
      { kind: "responsive" },
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 },
    ]);
  });

  it("delivers processDisappeared when checkResponsive answers undefined, and forgets that pid's counters", async () => {
    const verdicts: HangProbeVerdict[] = [];
    let disappeared = false;
    const checkResponsive: CheckProcessResponsive = async () => (disappeared ? undefined : false);
    const probe = new HangProbe({ checkResponsive, onVerdict: (_, v) => verdicts.push(v) });

    await probe.probe(500);
    disappeared = true;
    await probe.probe(500);

    expect(verdicts).toEqual([
      { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 },
      { kind: "processDisappeared" },
    ]);
  });

  it("never runs two probes for the same pid concurrently — the second call is a no-op while one is in flight", async () => {
    const { promise, resolve } = deferred<boolean | undefined>();
    let callCount = 0;
    const checkResponsive: CheckProcessResponsive = async () => {
      callCount += 1;
      return promise;
    };
    const probe = new HangProbe({ checkResponsive });

    const first = probe.probe(600);
    const second = probe.probe(600); // fired before the first resolves
    resolve(true);
    await Promise.all([first, second]);

    expect(callCount).toBe(1);
  });

  it("tracks independent pids without cross-contamination", async () => {
    const verdicts: Array<{ pid: number; verdict: HangProbeVerdict }> = [];
    const checkResponsive: CheckProcessResponsive = async (pid) => pid !== 701;
    const probe = new HangProbe({ checkResponsive, onVerdict: (pid, verdict) => verdicts.push({ pid, verdict }) });

    await probe.probe(700);
    await probe.probe(701);

    expect(verdicts).toEqual([
      { pid: 700, verdict: { kind: "responsive" } },
      { pid: 701, verdict: { kind: "unresponsiveButBelowThreshold", consecutiveFailures: 1 } },
    ]);
  });

  it("forget() clears counters so a manual reset (app left the gate) starts the count over", async () => {
    const verdicts: HangProbeVerdict[] = [];
    const checkResponsive: CheckProcessResponsive = async () => false;
    const probe = new HangProbe({
      checkResponsive,
      consecutiveFailuresBeforeConfirming: 3,
      onVerdict: (_, v) => verdicts.push(v),
    });

    await probe.probe(800);
    probe.forget(800);
    await probe.probe(800);
    await probe.probe(800);

    // Three total failed probes across the gap, but forget() reset the
    // counter after the first, so only two consecutive failures accumulate —
    // never reaching the threshold of three.
    expect(verdicts.every((v) => v.kind === "unresponsiveButBelowThreshold")).toBe(true);
  });
});

describe("buildGetProcessResponsiveCommand / parseGetProcessResponsiveOutput — pure PowerShell glue", () => {
  it("builds the bare Get-Process one-liner for a given pid", () => {
    expect(buildGetProcessResponsiveCommand(4821)).toBe(
      "(Get-Process -Id 4821 -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Responding",
    );
  });

  it.each([
    ["True\r\n", true],
    ["True", true],
    ["False\r\n", false],
    ["", undefined],
    ["   \n", undefined],
    ["WARNING: some locale-specific noise", false],
  ])("parses %j -> %j", (stdout, expected) => {
    expect(parseGetProcessResponsiveOutput(stdout)).toBe(expected);
  });
});

describe("checkProcessResponsiveViaPowerShell — the real check, exercised entirely offline", () => {
  class FakeSpawnedProcess implements SpawnedProcessLike {
    private readonly dataListeners: Array<(chunk: string) => void> = [];
    private readonly closeListeners: Array<(exitCode: number | null) => void> = [];
    private readonly errorListeners: Array<(error: Error) => void> = [];
    killCallCount = 0;

    readonly stdout = {
      on: (event: "data", listener: (chunk: string | Buffer) => void): void => {
        if (event === "data") this.dataListeners.push(listener as (chunk: string) => void);
      },
    };
    readonly stderr = { on: (): void => {} };

    on(event: "error" | "close", listener: ((error: Error) => void) | ((exitCode: number | null) => void)): void {
      if (event === "error") this.errorListeners.push(listener as (error: Error) => void);
      else this.closeListeners.push(listener as (exitCode: number | null) => void);
    }

    kill(): void {
      this.killCallCount += 1;
    }

    emitStdout(chunk: string): void {
      for (const listener of this.dataListeners) listener(chunk);
    }
    emitClose(exitCode: number | null): void {
      for (const listener of this.closeListeners) listener(exitCode);
    }
    emitError(error: Error): void {
      for (const listener of this.errorListeners) listener(error);
    }
  }

  it("resolves true when the command prints True and closes cleanly", async () => {
    const fake = new FakeSpawnedProcess();
    const promise = checkProcessResponsiveViaPowerShell(123, { spawnPowerShellOneLiner: () => fake });
    fake.emitStdout("True\r\n");
    fake.emitClose(0);
    await expect(promise).resolves.toBe(true);
  });

  it("resolves undefined when the command prints nothing — the process is gone", async () => {
    const fake = new FakeSpawnedProcess();
    const promise = checkProcessResponsiveViaPowerShell(123, { spawnPowerShellOneLiner: () => fake });
    fake.emitClose(0);
    await expect(promise).resolves.toBeUndefined();
  });

  it("resolves false when the child process errors (e.g. powershell.exe not found)", async () => {
    const fake = new FakeSpawnedProcess();
    const promise = checkProcessResponsiveViaPowerShell(123, { spawnPowerShellOneLiner: () => fake });
    fake.emitError(new Error("ENOENT"));
    await expect(promise).resolves.toBe(false);
  });

  it("resolves false and kills the child if the probe never closes within its timeout", async () => {
    const fake = new FakeSpawnedProcess();
    const promise = checkProcessResponsiveViaPowerShell(123, {
      spawnPowerShellOneLiner: () => fake,
      timeoutMs: 10,
    });
    await expect(promise).resolves.toBe(false);
    expect(fake.killCallCount).toBe(1);
  });

  it("never spawns anything for a non-positive or non-integer pid", async () => {
    const spawnPowerShellOneLiner = vi.fn(() => new FakeSpawnedProcess());
    await expect(checkProcessResponsiveViaPowerShell(0, { spawnPowerShellOneLiner })).resolves.toBeUndefined();
    await expect(checkProcessResponsiveViaPowerShell(-5, { spawnPowerShellOneLiner })).resolves.toBeUndefined();
    await expect(checkProcessResponsiveViaPowerShell(1.5, { spawnPowerShellOneLiner })).resolves.toBeUndefined();
    expect(spawnPowerShellOneLiner).not.toHaveBeenCalled();
  });

  it("passes the exact Get-Process one-liner for the given pid to the spawn seam", async () => {
    let commandSeen: string | undefined;
    const fake = new FakeSpawnedProcess();
    const promise = checkProcessResponsiveViaPowerShell(4821, {
      spawnPowerShellOneLiner: (command) => {
        commandSeen = command;
        return fake;
      },
    });
    fake.emitStdout("False");
    fake.emitClose(0);
    await promise;

    expect(commandSeen).toBe(buildGetProcessResponsiveCommand(4821));
  });
});
