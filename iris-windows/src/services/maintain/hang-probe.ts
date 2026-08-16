/**
 * hang-probe.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/HangProbe.swift` — answers
 * one question from outside a process: is the frontmost catalog app
 * responding? A hung app still shows a window fine (the window manager holds
 * that), so window presence proves nothing; the only honest probe is asking
 * the app's own message loop for something, with a timeout.
 *
 * ## The Windows mechanism (porting spec §2.2)
 *
 * Swift bounds an Accessibility read with `AXUIElementSetMessagingTimeout`
 * and treats a `kAXErrorCannotComplete` (or the read eating its whole
 * timeout) as one failed probe. Windows' direct analog is `Process.Responding`
 * — `Get-Process -Id <pid> | Select-Object -ExpandProperty Responding` —
 * which PowerShell/.NET backs with Win32's own `SendMessageTimeout` against
 * the process's main window. It only means something for a process with a
 * message loop, which is true of every Electron/Tauri catalog app.
 *
 * On Windows, ONE call answers both of Swift's two questions at once: whether
 * the process still exists at all (Swift checks this separately, up front,
 * with `NSRunningApplication(processIdentifier:) != nil`, before ever
 * touching AX) and whether it is responding. `Get-Process` with
 * `-ErrorAction SilentlyContinue` against a pid that no longer exists returns
 * nothing — empty output — which this file's `checkResponsive` seam therefore
 * reports as `undefined`, exactly the shape `HangProbeVerdict`'s
 * `processDisappeared` case needs. That is a genuine simplification versus
 * Swift's two-step shape, not a behavior change: the verdicts `HangProbe`
 * produces are unchanged.
 *
 * ## Pure decision logic vs. the real Windows call (ground rule: testable
 * on any OS)
 *
 * `HangProbe` below is 100% pure: it holds no reference to `child_process`,
 * PowerShell, or any Windows API, and is driven entirely by the injected
 * `checkResponsive` function passed to its constructor — the exact shape the
 * porting spec's own module table describes for the pure/real split between
 * `hang-probe.ts` and `hang-probe-windows.ts`. This particular porting task
 * asked for both the state machine AND the real Windows call in this one
 * file, so the real call lives below the class as a clearly separate section
 * (`checkProcessResponsiveViaPowerShell` and its pure helpers) — nothing in
 * `HangProbe` calls it, imports it, or defaults to it; a caller on Windows
 * wires it in explicitly. That keeps the class testable on macOS (where
 * spawning `powershell.exe` is not possible) while still shipping the real
 * mechanism in the same module the porting spec asked for.
 *
 * Even the "real" half stays testable everywhere: `buildGetProcessResponsiveCommand`
 * and `parseGetProcessResponsiveOutput` are pure string functions, and
 * `checkProcessResponsiveViaPowerShell` itself takes an injected
 * `spawnPowerShellOneLiner` (defaulting to a real `child_process.spawn`), so a
 * test can prove its parsing and timeout behavior with a fake child process on
 * any host — nothing in this file is structurally untestable off Windows.
 *
 * ## "Off-main" on a single-threaded runtime
 *
 * Swift runs the AX probe on its own serial `DispatchQueue`, specifically so
 * a probe eating its full timeout never stalls the app's own UI thread.
 * Node/Electron's main process has no equivalent second thread to hand work
 * to — the practical equivalent here is that `checkProcessResponsiveViaPowerShell`
 * is fully async (`child_process.spawn`, never a blocking call) and bounded by
 * its own timeout, so a slow or hung `Get-Process` call blocks nothing else
 * queued on the event loop while it waits. Same property (a stuck probe can't
 * stall Iris), different mechanism.
 *
 * Threshold and timeout constants below are unchanged ports of Swift's
 * `HangProbe.consecutiveFailuresBeforeConfirming` (4) and
 * `probeTimeoutSeconds` (1.5s, converted to ms).
 */

import { spawn } from "node:child_process";
import { maintainTrace } from "./trace";

/** The probe's verdict about one process, delivered after each tick. A
 *  discriminated union on `kind` (this codebase's convention for Swift enum
 *  ports — see the porting spec §3), mapping one-to-one onto Swift's
 *  `HangProbeVerdict` cases. */
export type HangProbeVerdict =
  /** The app answered the probe within the timeout. */
  | { readonly kind: "responsive" }
  /** Failed probes so far, below the escalation threshold. */
  | { readonly kind: "unresponsiveButBelowThreshold"; readonly consecutiveFailures: number }
  /** N consecutive failures: this is a hang worth asking about. Carries how
   *  long the app has been unresponsive, for the ask's wording. */
  | { readonly kind: "confirmedHang"; readonly unresponsiveSeconds: number }
  /** The app exited between ticks — the crash watcher's business now. */
  | { readonly kind: "processDisappeared" };

/** Apple's spinner heuristics run at 2–4 seconds, which is far too eager for
 *  an external observer with no visibility into legitimate work. Four failed
 *  probes at the tick interval is ~8–10s of confirmed silence before anything
 *  escalates. Unchanged from Swift's `consecutiveFailuresBeforeConfirming`. */
export const HANG_PROBE_CONSECUTIVE_FAILURES_BEFORE_CONFIRMING = 4;

/** Bounds one `Get-Process` probe call. Swift's `probeTimeoutSeconds` (1.5)
 *  converted to milliseconds — `checkProcessResponsiveViaPowerShell` uses
 *  this as its own default timeout, kept as one shared constant so the two
 *  never drift apart. */
export const HANG_PROBE_TIMEOUT_MS = 1500;

/** What the caller supplies to answer "is this pid responding right now?" —
 *  `undefined` means the process is gone (`processDisappeared`); `true`/
 *  `false` are the ordinary answers. The real implementation is
 *  `checkProcessResponsiveViaPowerShell` below; tests supply a hand-written
 *  fake. */
export type CheckProcessResponsive = (processId: number) => Promise<boolean | undefined>;

export interface HangProbeOptions {
  readonly checkResponsive: CheckProcessResponsive;
  /** Defaults to `HANG_PROBE_CONSECUTIVE_FAILURES_BEFORE_CONFIRMING`.
   *  Overridable so a test can reach a `confirmedHang` verdict without
   *  simulating four full ticks. */
  readonly consecutiveFailuresBeforeConfirming?: number;
  /** Defaults to `Date.now`. Injected so `unresponsiveSeconds` is assertable
   *  in a test without a real clock. */
  readonly nowEpochMs?: () => number;
  /** Delivered after every probe tick — the caller (the incident coordinator)
   *  owns what happens next; this class never acts on its own. */
  readonly onVerdict?: (processId: number, verdict: HangProbeVerdict) => void;
}

/**
 * Probes one or more processes for responsiveness, escalating only after N
 * consecutive failures. Pure: every side effect (the actual probe call, the
 * clock) is injected. Unchanged from Swift's `HangProbe` in every observable
 * respect — same threshold, same forget-on-recovery behavior, same
 * one-probe-in-flight-per-pid guard.
 */
export class HangProbe {
  private readonly checkResponsive: CheckProcessResponsive;
  private readonly consecutiveFailuresBeforeConfirming: number;
  private readonly nowEpochMs: () => number;
  onVerdict: ((processId: number, verdict: HangProbeVerdict) => void) | undefined;

  private consecutiveFailuresByProcessId = new Map<number, number>();
  private firstFailureAtEpochMsByProcessId = new Map<number, number>();
  /** One probe per pid in flight, ever — a stacked-up queue of probes against
   *  a hung app would deliver a burst of stale verdicts when it finally
   *  recovers. Matches Swift's `probeInFlightForProcess`. */
  private probeInFlightForProcessId = new Set<number>();

  constructor(options: HangProbeOptions) {
    this.checkResponsive = options.checkResponsive;
    this.consecutiveFailuresBeforeConfirming =
      options.consecutiveFailuresBeforeConfirming ?? HANG_PROBE_CONSECUTIVE_FAILURES_BEFORE_CONFIRMING;
    this.nowEpochMs = options.nowEpochMs ?? (() => Date.now());
    this.onVerdict = options.onVerdict;
  }

  /** Probes `processId` once. The caller decides WHEN to probe (frontmost
   *  catalog app, screen static — that gating is the incident coordinator's
   *  job, per Swift's own file header); this class only knows HOW. A no-op if
   *  a probe for this pid is already in flight. */
  async probe(processId: number): Promise<void> {
    if (this.probeInFlightForProcessId.has(processId)) {
      return;
    }
    this.probeInFlightForProcessId.add(processId);

    let answered: boolean | undefined;
    try {
      answered = await this.checkResponsive(processId);
    } finally {
      this.probeInFlightForProcessId.delete(processId);
    }

    if (answered === undefined) {
      this.forget(processId);
      this.onVerdict?.(processId, { kind: "processDisappeared" });
      return;
    }
    this.record(processId, answered);
  }

  /** The app left the gate (backgrounded, quit, screen changed): its counters
   *  must not survive to poison the next observation window. Matches Swift's
   *  `forget(processIdentifier:)`. */
  forget(processId: number): void {
    this.consecutiveFailuresByProcessId.delete(processId);
    this.firstFailureAtEpochMsByProcessId.delete(processId);
    this.probeInFlightForProcessId.delete(processId);
  }

  private record(processId: number, answered: boolean): void {
    if (answered) {
      // Recovery after a confirmed hang is itself signal — the ask happens
      // after the fact, never mid-hang, so the coordinator needs to hear the
      // app came back. Traced before the counters are cleared, matching
      // Swift's `record(processIdentifier:answered:)` ordering exactly.
      const hadConfirmed =
        (this.consecutiveFailuresByProcessId.get(processId) ?? 0) >= this.consecutiveFailuresBeforeConfirming;
      if (hadConfirmed) {
        maintainTrace(`hang recovered pid=${processId}`);
      }
      this.forget(processId);
      this.onVerdict?.(processId, { kind: "responsive" });
      return;
    }

    const failures = (this.consecutiveFailuresByProcessId.get(processId) ?? 0) + 1;
    this.consecutiveFailuresByProcessId.set(processId, failures);
    if (!this.firstFailureAtEpochMsByProcessId.has(processId)) {
      this.firstFailureAtEpochMsByProcessId.set(processId, this.nowEpochMs());
    }

    if (failures >= this.consecutiveFailuresBeforeConfirming) {
      const since = this.firstFailureAtEpochMsByProcessId.get(processId) ?? this.nowEpochMs();
      const unresponsiveSeconds = Math.round((this.nowEpochMs() - since) / 1000);
      maintainTrace(`hang confirmed pid=${processId} after ${failures} probes, ~${unresponsiveSeconds}s`);
      this.onVerdict?.(processId, { kind: "confirmedHang", unresponsiveSeconds });
    } else {
      this.onVerdict?.(processId, { kind: "unresponsiveButBelowThreshold", consecutiveFailures: failures });
    }
  }
}

// ---------------------------------------------------------------------------
// The real Windows call. Nothing above this line imports or defaults to
// anything below it — see the file header's "Pure decision logic vs. the
// real Windows call" section.
// ---------------------------------------------------------------------------

/** Builds the one-shot PowerShell one-liner. Deliberately NOT routed through
 *  `main/powershell-session.ts`'s `wrapCommandScript`/`-EncodedCommand`
 *  machinery (porting spec §2.2: "do not poll through the heavier
 *  WindowsMaintainShellRunner ... a bare Get-Process one-liner is enough") —
 *  that machinery exists to run arbitrary multi-line scripts safely quoted;
 *  this is one fixed shape with a single validated integer substituted in, so
 *  the extra round-trip buys nothing. Exported and pure so a test can assert
 *  the exact command without spawning anything. */
export function buildGetProcessResponsiveCommand(processId: number): string {
  return `(Get-Process -Id ${processId} -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Responding`;
}

/** Parses `Get-Process ... | Select-Object -ExpandProperty Responding`'s
 *  stdout. Empty output means `Get-Process` found nothing for that id — the
 *  process is gone, matching `CheckProcessResponsive`'s `undefined` contract.
 *  Any non-empty output that is not exactly `"True"` (a differently localized
 *  boolean spelling, a stray warning line ahead of the value, ...) is treated
 *  as `false` rather than as another "gone" signal: the process demonstrably
 *  still exists in that case (`Get-Process` found *something* to print about
 *  it), so failing toward "counts as one failed probe" is the honest choice —
 *  a parse miss becomes at most one extra tick toward the N-of-M threshold,
 *  never a silently forgotten hang. */
export function parseGetProcessResponsiveOutput(stdout: string): boolean | undefined {
  const trimmed = stdout.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  return trimmed === "True";
}

/** The minimal subset of `child_process.ChildProcess` this file needs —
 *  narrow on purpose so a test can hand in a fake without constructing a real
 *  `ChildProcess`. */
export interface SpawnedProcessLike {
  readonly stdout: { on(event: "data", listener: (chunk: string | Buffer) => void): void } | null;
  readonly stderr: { on(event: "data", listener: (chunk: string | Buffer) => void): void } | null;
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (exitCode: number | null) => void): void;
  kill(): void;
}

/** The spawn seam `checkProcessResponsiveViaPowerShell` is built against.
 *  Defaults to a real `child_process.spawn` call; injected so its parsing and
 *  timeout behavior are testable on any host without actually invoking
 *  `powershell.exe`. */
export type SpawnPowerShellOneLiner = (command: string) => SpawnedProcessLike;

function defaultSpawnPowerShellOneLiner(command: string): SpawnedProcessLike {
  return spawn("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command], {
    windowsHide: true,
  });
}

export interface CheckProcessResponsiveViaPowerShellOptions {
  readonly spawnPowerShellOneLiner?: SpawnPowerShellOneLiner;
  /** Defaults to `HANG_PROBE_TIMEOUT_MS`. A hung `Get-Process` call itself is
   *  unlikely but not impossible; bounding it keeps one bad probe from
   *  wedging the caller the way an unbounded AX read would in Swift. */
  readonly timeoutMs?: number;
}

/**
 * The real, Windows-only implementation of `CheckProcessResponsive` — a
 * one-shot `powershell.exe -Command` call per probe, per the porting spec's
 * "bare Get-Process one-liner is enough" guidance. A caller wires this in
 * explicitly (never a default anywhere in `HangProbe`); it only makes sense
 * to run on Windows, where `powershell.exe` actually exists.
 *
 * A spawn failure (no `powershell.exe` on PATH, a sandboxing product blocking
 * child processes, ...) or a timeout is treated as `false` — a failed probe —
 * for the same "fail toward suspicion, not toward silently forgetting"
 * reasoning `parseGetProcessResponsiveOutput` documents: an infrastructure
 * hiccup should cost at most one tick toward the threshold, never quietly
 * masquerade as "the process is fine" or "the process disappeared".
 */
export function checkProcessResponsiveViaPowerShell(
  processId: number,
  options: CheckProcessResponsiveViaPowerShellOptions = {},
): Promise<boolean | undefined> {
  const spawnPowerShellOneLiner = options.spawnPowerShellOneLiner ?? defaultSpawnPowerShellOneLiner;
  const timeoutMs = options.timeoutMs ?? HANG_PROBE_TIMEOUT_MS;

  if (!Number.isInteger(processId) || processId <= 0) {
    // Not a real pid — nothing to probe. Conservatively "gone" rather than
    // "failed", since no process was ever named.
    return Promise.resolve(undefined);
  }

  return new Promise((resolve) => {
    const child = spawnPowerShellOneLiner(buildGetProcessResponsiveCommand(processId));
    let stdout = "";
    let settled = false;

    const finish = (value: boolean | undefined): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };

    const timer = setTimeout(() => {
      child.kill();
      finish(false);
    }, timeoutMs);

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => finish(false));
    child.on("close", () => finish(parseGetProcessResponsiveOutput(stdout)));
  });
}
