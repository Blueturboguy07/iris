//
// The watch-expectation executor — the Windows port of the macOS adaptive
// `WatchLoop` (`iris-macos/leanring-buddy/WatchLoop.swift` + `WatchVisualCheck.swift`),
// scoped to what the autopilot runner needs: given a step's `watch` block, block
// until one of its expectations verifies, then let the step advance on its own.
//
// It is the piece that makes a `verify` step (and a reader step that carries a
// watch) settle without the reader tapping "done". macOS runs this on a 2-second
// timer; the Windows autopilot is a *pumped* state machine, so this is an
// awaitable executor the runner calls inline and awaits — bounded, so it always
// returns (verified, or timed out and handed back to the reader).
//
// THE LADDER, cheapest-first (matching the porting spec's stated order for
// Windows). Every poll evaluates the step's expectations in this order and stops
// at the first that verifies, so the expensive rungs are never reached once a
// cheap one settles the step:
//
//   0. toolVersion  — a tool is on PATH (`services/tool-versions.ts`). Free-ish.
//   1. foregroundApp — the app is in front (PowerShell `GetForegroundWindow` →
//      process name, the seam `services/maintain/app-inventory.ts` already owns).
//   2. urlHost      — the frontmost browser tab's host (PowerShell UI Automation
//      of the address bar, with a window-title fallback — see below).
//   3. axElement    — a UI Automation element on the foreground window.
//   4. visual       — a screenshot judged by a model. Budgeted (≤ 8 per step,
//      ≥ 10 s apart) and NEVER taken for a `sensitive` watch.
//
// PURITY / TESTABILITY. Every OS call — every PowerShell spawn, the screenshot,
// the model call, the clock, the delay between polls — is an injected seam with a
// real default, exactly the convention `app-inventory.ts` uses. So the whole
// executor runs in the vitest suite on this Mac with faked seams, and the real
// seams only do anything meaningful on Windows.
//
// PRIVACY. A `sensitive` watch is never captured: the visual rung is skipped
// outright, and the step settles from the pixel-free side signals or is handed
// back. The screenshot the visual rung does take exists only as the argument of
// the one model call it is passed to — this module never stores it.
//

import { spawn } from "node:child_process";
import type { StepWatch, WatchExpectation } from "./recipe";
import {
  readForegroundProcessViaPowerShell,
  WINDOWS_CATALOG_APPS,
  type ForegroundProcess,
  type ReadForegroundProcess,
} from "../maintain/app-inventory";
import { isAllowlistedTool } from "../tool-versions";

// ---------------------------------------------------------------------------
// The verdict a visual model check reaches, and the parsing that reads it back.
// A faithful port of `WatchVisualCheck.swift` so the Windows visual rung asks
// the same question and reads the same one-line answer the macOS loop does.
// ---------------------------------------------------------------------------

/// What a visual check concluded from one frame. Deliberately three outcomes,
/// not an optional boolean: "the model answered in a shape we could not read" is
/// distinct from "the step is not done", because one means the loop learned
/// nothing and the other is a real not-yet.
export type WatchVerdict =
  | { readonly kind: "completed" }
  | { readonly kind: "notYet" }
  /// The reader looks stuck — carries a short hint to surface straight away.
  | { readonly kind: "userStuck"; readonly hint: string };

export const VISUAL_COMPLETED_ANSWER = "COMPLETED";
export const VISUAL_NOT_YET_ANSWER = "NOT_YET";
export const VISUAL_STUCK_ANSWER_PREFIX = "STUCK:";

/// What else was true on screen when a visual frame was taken, so the model is
/// asked an unambiguous question. Mirrors macOS's `WatchScreenContext`.
export interface WatchScreenContext {
  readonly frontmostApplicationName?: string;
  readonly focusedWindowTitle?: string;
  /// The command this step asked the reader to run, verbatim — a shell echoes
  /// what was typed, so it doubles as proof THIS step ran, not the one before.
  readonly commandTheStepAsksFor?: string;
}

/// The system prompt for the visual check, ported line-for-line from
/// `WatchVisualCheck.systemPrompt` so the Windows loop judges a step against the
/// same words the macOS loop does.
export function visualCheckSystemPrompt(hintsTheStepAuthorWrote: readonly string[]): string {
  let systemPrompt =
    "You are helping somebody follow an install guide on their own computer. " +
    "You are shown one screenshot and asked whether the current step is done.\n\n" +
    "Answer with exactly one line and nothing else:\n" +
    `${VISUAL_COMPLETED_ANSWER} — the step is visibly finished.\n` +
    `${VISUAL_NOT_YET_ANSWER} — the step is not finished, and nothing looks wrong.\n` +
    `${VISUAL_STUCK_ANSWER_PREFIX} <one short sentence> — the step is not finished AND ` +
    "something on screen suggests they have gone off the rails: an error, a " +
    "dialog they did not expect, or the wrong window in front.\n\n" +
    `Prefer ${VISUAL_NOT_YET_ANSWER} when you are unsure. Saying a step is done when it ` +
    "is not sends somebody on to a step that cannot work.\n\n" +
    "The screenshot is usually the reader's whole screen. If you can see more " +
    "than one window, judge only the one the question names: another window " +
    "being busy, idle or full of errors is not evidence about this step. A dialog " +
    "or alert sitting on top of the reader's work is the one thing worth looking " +
    `away for, and is worth a ${VISUAL_STUCK_ANSWER_PREFIX} answer.\n\n` +
    "When the question names a command, it is there to catch exactly one " +
    "mistake and nothing else. Guides run several commands in a row, so if the " +
    "window plainly shows a different command as the most recent thing run, with " +
    "its own output beneath it and no sign of the named one, this step has not " +
    `started — answer ${VISUAL_NOT_YET_ANSWER}.\n\n` +
    "In every other case ignore the command and answer the question exactly as " +
    "it is asked. Terminals scroll, so a long install pushes its own command off " +
    "the top of the window; that is normal and means nothing. Do not talk " +
    "yourself out of evidence you can actually see.";
  if (hintsTheStepAuthorWrote.length > 0) {
    systemPrompt += "\n\nThe guide's author suggested these hints for somebody who is stuck:\n";
    for (const hint of hintsTheStepAuthorWrote) {
      systemPrompt += `- ${hint}\n`;
    }
  }
  return systemPrompt;
}

/// The user prompt for the visual check, ported from `WatchVisualCheck.userPrompt`.
export function visualCheckUserPrompt(options: {
  readonly stepTitle: string;
  readonly visualPrompt: string;
  readonly context?: WatchScreenContext;
}): string {
  const context = options.context ?? {};
  let userPrompt = `The step is titled "${options.stepTitle}".`;

  const describesAWindow =
    (context.frontmostApplicationName?.length ?? 0) > 0 ||
    (context.focusedWindowTitle?.length ?? 0) > 0;
  if (describesAWindow) {
    userPrompt += "\n\nJudge this window and ignore every other window on the screen:";
    if (context.frontmostApplicationName && context.frontmostApplicationName.length > 0) {
      userPrompt += `\n- Application: ${context.frontmostApplicationName}`;
    }
    if (context.focusedWindowTitle && context.focusedWindowTitle.length > 0) {
      userPrompt += `\n- Window title: ${context.focusedWindowTitle}`;
    }
  }

  if (context.commandTheStepAsksFor && context.commandTheStepAsksFor.length > 0) {
    userPrompt +=
      "\n\nThis step asked the reader to run this command:\n" +
      `${context.commandTheStepAsksFor}\n\n` +
      "If a different command is plainly the most recent thing run, this step " +
      "has not started. Otherwise answer the question as asked.";
  }

  userPrompt += `\n\nThe question to answer about the screenshot is: ${options.visualPrompt}`;
  return userPrompt;
}

/// Reads the one-line answer back. Anything unrecognized is `undefined` — "the
/// loop learned nothing" — which must never collapse into `notYet`. Ported from
/// `WatchVisualCheck.verdict(fromModelAnswer:)`.
export function verdictFromVisualModelAnswer(
  modelAnswer: string,
  hintsTheStepAuthorWrote: readonly string[],
): WatchVerdict | undefined {
  const firstLine = (modelAnswer.split("\n")[0] ?? "").trim();
  const normalized = firstLine.toUpperCase();

  if (normalized.startsWith(VISUAL_STUCK_ANSWER_PREFIX)) {
    const hintFromTheModel = firstLine.slice(VISUAL_STUCK_ANSWER_PREFIX.length).trim();
    if (hintFromTheModel.length > 0) {
      return { kind: "userStuck", hint: hintFromTheModel };
    }
    // A stuck verdict with no hint is useless, so the author's own first hint
    // stands in rather than an empty banner.
    const authoredHint = hintsTheStepAuthorWrote[0];
    return authoredHint !== undefined ? { kind: "userStuck", hint: authoredHint } : { kind: "notYet" };
  }
  if (normalized.startsWith(VISUAL_COMPLETED_ANSWER)) {
    return { kind: "completed" };
  }
  if (normalized.startsWith(VISUAL_NOT_YET_ANSWER) || normalized.startsWith("NOT YET")) {
    return { kind: "notYet" };
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Cheapest-first ordering.
// ---------------------------------------------------------------------------

/// The relative cost of confirming each expectation, cheapest first. The
/// executor evaluates a step's expectations in this order and stops at the first
/// that verifies, so a step that a tool-version check settles never spends a
/// model call.
const EXPECTATION_COST_RANK: Readonly<Record<WatchExpectation["type"], number>> = {
  toolVersion: 0,
  foregroundApp: 1,
  urlHost: 2,
  axElement: 3,
  visual: 4,
};

/// Orders a step's expectations cheapest-first without mutating the input. A
/// stable sort by cost rank, so two expectations of the same type keep their
/// authored order.
export function orderExpectationsCheapestFirst(
  expectations: readonly WatchExpectation[],
): WatchExpectation[] {
  return expectations
    .map((expectation, indexInAuthoredOrder) => ({ expectation, indexInAuthoredOrder }))
    .sort((left, right) => {
      const rankDifference =
        EXPECTATION_COST_RANK[left.expectation.type] - EXPECTATION_COST_RANK[right.expectation.type];
      return rankDifference !== 0 ? rankDifference : left.indexInAuthoredOrder - right.indexInAuthoredOrder;
    })
    .map((entry) => entry.expectation);
}

// ---------------------------------------------------------------------------
// foregroundApp: mapping the guide's identity to a Windows executable name.
// ---------------------------------------------------------------------------

/// The reviewed map from a guide's foreground identity (a macOS bundle id) to
/// the Windows executable name, for catalog apps whose Windows exe has been
/// established. It exists for the same reason `WINDOWS_CATALOG_APPS` does:
/// `/api/iris/apps` carries a `macBundleId` and nothing that names a Windows
/// `.exe`, so a guide written with a `foregroundApp` bundle id has to be mapped
/// by hand to the exe a foreground read reports. Only entries verified against a
/// real build appear here; an unknown identity is simply not matched, which is
/// the honest answer. Keyed by lowercased bundle id.
const FOREGROUND_BUNDLE_ID_TO_WINDOWS_EXE: Readonly<Record<string, string>> = {
  // publikclip is the one catalog app with a verified Windows exe name (see
  // `WINDOWS_CATALOG_APPS`). Its macOS guide identity maps to that exe.
  "com.publikhq.publikclip": "publikclip-app.exe",
};

/// Normalizes an exe-shaped name to lowercase and strips one trailing `.exe`, so
/// `"publikclip-app.exe"`, `"publikclip-app"`, and `"PUBLIKCLIP-APP.EXE"` all
/// compare equal — a foreground read may report either shape and neither is
/// case-authoritative on Windows. Mirrors `app-inventory.ts`'s private
/// `normalizeExeName`.
function normalizeExecutableName(name: string): string {
  const lowered = name.trim().toLowerCase();
  return lowered.endsWith(".exe") ? lowered.slice(0, -".exe".length) : lowered;
}

/// The Windows executable name a `foregroundApp` expectation's identity resolves
/// to, or `undefined` when Iris cannot map it. An identity that already looks
/// like an exe is taken as-is; a known bundle id is mapped through the reviewed
/// table; a slug that names a reviewed catalog app uses that app's exe. Pure and
/// directly tested.
export function windowsExecutableForForegroundIdentity(identity: string): string | undefined {
  const trimmedIdentity = identity.trim();
  if (trimmedIdentity.length === 0) return undefined;

  if (trimmedIdentity.toLowerCase().endsWith(".exe")) {
    return normalizeExecutableName(trimmedIdentity);
  }

  const mappedExe = FOREGROUND_BUNDLE_ID_TO_WINDOWS_EXE[trimmedIdentity.toLowerCase()];
  if (mappedExe !== undefined) {
    return normalizeExecutableName(mappedExe);
  }

  const catalogAppForSlug = WINDOWS_CATALOG_APPS.find((app) => app.slug === trimmedIdentity);
  if (catalogAppForSlug !== undefined) {
    return normalizeExecutableName(catalogAppForSlug.exeName);
  }

  return undefined;
}

/// Whether a foreground process (as a read reports it) satisfies a
/// `foregroundApp` expectation. Case-insensitive and `.exe`-suffix tolerant.
export function foregroundProcessSatisfiesIdentity(
  foregroundProcessName: string,
  expectedIdentity: string,
): boolean {
  const expectedExecutable = windowsExecutableForForegroundIdentity(expectedIdentity);
  if (expectedExecutable === undefined) return false;
  return normalizeExecutableName(foregroundProcessName) === expectedExecutable;
}

// ---------------------------------------------------------------------------
// urlHost: matching, and the PowerShell that reads the address bar.
// ---------------------------------------------------------------------------

/// `console.anthropic.com` matches itself and any subdomain of itself, and
/// nothing else. A plain suffix test would let `evilconsole.anthropic.com`
/// through, exactly the match a signal like this must never make. Ported from
/// `WatchLoop.host(_:matchesExpectedHost:)`.
export function hostMatchesExpectedHost(actualHost: string | undefined, expectedHost: string): boolean {
  if (actualHost === undefined) return false;
  const normalizedActualHost = actualHost.trim().toLowerCase();
  const normalizedExpectedHost = expectedHost.trim().toLowerCase();
  if (normalizedActualHost.length === 0 || normalizedExpectedHost.length === 0) return false;
  if (normalizedActualHost === normalizedExpectedHost) return true;
  return normalizedActualHost.endsWith(`.${normalizedExpectedHost}`);
}

/// Pulls the host out of whatever the address-bar read returned — a full URL, a
/// bare host, or a host with a path. Returns `undefined` for anything with no
/// readable host. Pure and directly tested; used by both the real seam's parse
/// and the window-title fallback.
export function hostFromAddressBarText(addressBarText: string): string | undefined {
  const trimmed = addressBarText.trim();
  if (trimmed.length === 0) return undefined;

  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
  try {
    const host = new URL(withScheme).hostname.toLowerCase();
    return host.length > 0 ? host : undefined;
  } catch {
    return undefined;
  }
}

/// The PowerShell that reads the frontmost browser window's address-bar value
/// over UI Automation. It finds the foreground window, then the first Edit/Text
/// automation element whose name looks like an address bar (Chrome/Edge label
/// their omnibox "Address and search bar"; Firefox uses "Search with … or enter
/// address"), and prints its `ValuePattern` value on one line.
///
/// UI Automation genuinely reads the live tab URL, which the window title cannot
/// — so this is the accurate path and the title heuristic below is only the
/// fallback. Exported and pure so a test can assert the command without spawning.
export function buildActiveBrowserUrlCommand(): string {
  return [
    "Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes;",
    "Add-Type -Namespace IrisFg -Name Win -MemberDefinition '",
    '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();' + "' ;",
    "$h = [IrisFg.Win]::GetForegroundWindow();",
    "if ($h -ne [System.IntPtr]::Zero) {",
    "  $root = [System.Windows.Automation.AutomationElement]::FromHandle($h);",
    "  if ($root) {",
    "    $editCondition = New-Object System.Windows.Automation.PropertyCondition(",
    "      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,",
    "      [System.Windows.Automation.ControlType]::Edit);",
    "    $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $editCondition);",
    "    foreach ($edit in $edits) {",
    "      $name = $edit.Current.Name;",
    '      if ($name -match "address" -or $name -match "search or enter" -or $name -match "enter address") {',
    "        $valuePattern = $null;",
    "        if ($edit.TryGetCurrentPattern(",
    "          [System.Windows.Automation.ValuePattern]::Pattern, [ref]$valuePattern)) {",
    '          Write-Output ("URL|" + $valuePattern.Current.Value); break;',
    "        }",
    "      }",
    "    }",
    "  }",
    "}",
  ].join(" ");
}

/// Parses `buildActiveBrowserUrlCommand`'s stdout — the last `URL|<value>` line
/// — into a host, or `undefined` when it read nothing. Pure and directly tested.
export function parseActiveBrowserUrlOutput(stdout: string): string | undefined {
  const lines = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("URL|"));
  const lastLine = lines[lines.length - 1];
  if (lastLine === undefined) return undefined;
  return hostFromAddressBarText(lastLine.slice("URL|".length));
}

// ---------------------------------------------------------------------------
// axElement: the PowerShell that searches the foreground window's UIA tree.
// ---------------------------------------------------------------------------

/// The PowerShell that searches the foreground window's UI Automation tree for
/// an element whose Name (or LocalizedControlType) contains `roleLabel`, and
/// prints `AX|1` when one is present. The label is passed as a here-string
/// literal and only ever compared with `-like`, never interpolated into code, so
/// a guide's `roleLabel` cannot become a command. Exported and pure so a test
/// can assert the command without spawning.
export function buildAxElementQueryCommand(roleLabel: string): string {
  // Single-quote-escape the label for a PowerShell single-quoted string literal
  // (double any embedded single quote), so it is data, never code.
  const escapedRoleLabel = roleLabel.replace(/'/g, "''");
  return [
    "Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes;",
    "Add-Type -Namespace IrisFg -Name Win -MemberDefinition '",
    '[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();' + "' ;",
    `$needle = '${escapedRoleLabel}';`,
    "$h = [IrisFg.Win]::GetForegroundWindow();",
    "if ($h -ne [System.IntPtr]::Zero) {",
    "  $root = [System.Windows.Automation.AutomationElement]::FromHandle($h);",
    "  if ($root) {",
    "    $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,",
    "      [System.Windows.Automation.Condition]::TrueCondition);",
    "    foreach ($element in $all) {",
    "      $name = $element.Current.Name;",
    "      $type = $element.Current.LocalizedControlType;",
    '      if ($name -like ("*" + $needle + "*") -or $type -like ("*" + $needle + "*")) {',
    '        Write-Output "AX|1"; break;',
    "      }",
    "    }",
    "  }",
    "}",
  ].join(" ");
}

/// Whether `buildAxElementQueryCommand`'s stdout reported a match. Pure.
export function parseAxElementPresenceOutput(stdout: string): boolean {
  return stdout
    .split(/\r?\n/)
    .some((line) => line.trim() === "AX|1");
}

// ---------------------------------------------------------------------------
// The seams the executor reaches the machine through.
// ---------------------------------------------------------------------------

/// What one visual model check needs. `screenshotJpegBase64` is the frame; the
/// evaluator answers the same one-line question `WatchVisualCheck` asks and
/// returns a parsed verdict, or `undefined` when the call failed / could not be
/// read (which is NOT `notYet`).
export interface WatchVisualCheckRequest {
  readonly screenshotJpegBase64: string;
  readonly visualPrompt: string;
  readonly stepTitle: string;
  readonly context: WatchScreenContext;
  readonly hintsTheStepAuthorWrote: readonly string[];
}

/// Every OS-touching capability the executor needs, injected. The real defaults
/// (`defaultWatchSeams`) are Windows PowerShell one-liners and node timers; a
/// test supplies fakes and never spawns anything. The visual capture + model
/// evaluator default to "not wired" (they need `main/`'s screenshot pipeline and
/// a model transport), so on side signals the executor is fully functional today
/// and the visual rung lights up once a host supplies those two seams.
export interface WatchSeams {
  /// toolVersion. True when the tool is installed. The default checks the
  /// tool-versions allowlist and refuses to run for a tool not on it (a guide
  /// cannot name an arbitrary program), returning false.
  isToolInstalled(tool: string): Promise<boolean>;
  /// foregroundApp. Reads whatever process is in front, or undefined.
  readForegroundProcess(): Promise<ForegroundProcess | undefined>;
  /// urlHost. Reads the frontmost browser tab's host, or undefined.
  readForegroundBrowserHost(): Promise<string | undefined>;
  /// axElement. True when a UIA element matching the label is on the foreground
  /// window.
  isAxElementPresent(roleLabel: string): Promise<boolean>;
  /// visual. One screenshot as base64 JPEG, or undefined when capture is not
  /// available. Only ever called for a non-sensitive step.
  captureScreenshotJpegBase64(): Promise<string | undefined>;
  /// visual. Judges one frame and returns a verdict, or undefined.
  evaluateVisualCheck(request: WatchVisualCheckRequest): Promise<WatchVerdict | undefined>;
  /// Seconds on a monotonic timeline. Only differences are used, so where it
  /// starts does not matter. Backs the ≥ 10 s-between-visual-checks budget.
  nowInSeconds(): number;
  /// Waits between polls. A seam so a test drives many polls in zero real time.
  waitForMilliseconds(milliseconds: number): Promise<void>;
}

// ---------------------------------------------------------------------------
// The real default seams (Windows).
// ---------------------------------------------------------------------------

/// The minimal spawned-process subset the PowerShell seams need, mirroring
/// `app-inventory.ts`'s `SpawnedProcessLike` so a test could hand in a fake
/// (production wires the real spawn).
interface SpawnedProcessLike {
  readonly stdout: { on(event: "data", listener: (chunk: string | Buffer) => void): void } | null;
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (exitCode: number | null) => void): void;
  kill(): void;
}

const DEFAULT_POWERSHELL_READ_TIMEOUT_MS = 4000;

/// Runs one PowerShell command and resolves its stdout, or "" on any failure (no
/// PowerShell, a blocked child, a timeout). Never throws — a signal that cannot
/// be read is "not verified", never an error that stops the loop. Mirrors
/// `app-inventory.ts`'s `readForegroundProcessViaPowerShell` plumbing.
function runPowerShellForStdout(
  command: string,
  timeoutMilliseconds: number = DEFAULT_POWERSHELL_READ_TIMEOUT_MS,
): Promise<string> {
  return new Promise((resolve) => {
    let child: SpawnedProcessLike;
    try {
      child = spawn(
        "powershell.exe",
        ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
        { windowsHide: true },
      );
    } catch {
      resolve("");
      return;
    }
    let stdout = "";
    let settled = false;
    const finish = (value: string): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish("");
    }, timeoutMilliseconds);
    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => finish(""));
    child.on("close", () => finish(stdout));
  });
}

/// The real Windows seams. `readForegroundProcess` is `app-inventory.ts`'s own
/// seam (reused, not re-implemented). Visual capture + evaluation default to
/// "not wired" — they return undefined — because they need `main/`'s screenshot
/// pipeline and a model transport a caller injects; until then side-signal
/// watching works and the visual rung is inert rather than broken.
export function defaultWatchSeams(
  overrides: Partial<WatchSeams> = {},
  readForegroundProcess: ReadForegroundProcess = readForegroundProcessViaPowerShell,
): WatchSeams {
  return {
    isToolInstalled: overrides.isToolInstalled ?? (async () => false),
    readForegroundProcess: overrides.readForegroundProcess ?? (() => readForegroundProcess()),
    readForegroundBrowserHost:
      overrides.readForegroundBrowserHost ??
      (async () => parseActiveBrowserUrlOutput(await runPowerShellForStdout(buildActiveBrowserUrlCommand()))),
    isAxElementPresent:
      overrides.isAxElementPresent ??
      (async (roleLabel: string) =>
        parseAxElementPresenceOutput(await runPowerShellForStdout(buildAxElementQueryCommand(roleLabel)))),
    captureScreenshotJpegBase64: overrides.captureScreenshotJpegBase64 ?? (async () => undefined),
    evaluateVisualCheck: overrides.evaluateVisualCheck ?? (async () => undefined),
    nowInSeconds: overrides.nowInSeconds ?? (() => Date.now() / 1000),
    waitForMilliseconds:
      overrides.waitForMilliseconds ??
      ((milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds))),
  };
}

// ---------------------------------------------------------------------------
// The executor.
// ---------------------------------------------------------------------------

/// The visual budget, straight out of `docs/iris-assistant-protocol.md` §7 and
/// the macOS `WatchLoop` constants.
export const MAXIMUM_VISUAL_CHECKS_PER_STEP = 8;
export const MINIMUM_SECONDS_BETWEEN_VISUAL_CHECKS = 10;

/// How long to wait between polls of a watched step, and how many polls before a
/// watch that never verifies gives up and hands the step to the reader. 2 s
/// matches the macOS loop's cadence; 90 polls (~3 minutes) is a generous ceiling
/// so a slow-but-real reader action is not abandoned, while still bounding the
/// wait so `awaitStepCompletion` always returns.
export const MILLISECONDS_BETWEEN_POLLS = 2000;
export const DEFAULT_MAXIMUM_POLLS = 90;

/// Why a watched step stopped being watched.
export type WatchStepOutcome =
  | {
      readonly kind: "verified";
      /// Which expectation settled it, for the `watchVerified` event.
      readonly verifiedBy: WatchExpectation["type"];
    }
  | {
      readonly kind: "timedOut";
      /// The most recent `userStuck` hint a visual check produced, if any — so
      /// the handoff can surface what the model noticed.
      readonly stuckHint?: string;
    };

/// Options for one `awaitStepCompletion` call. Every bound is overridable so a
/// test drives the loop deterministically; production takes the defaults.
export interface AwaitStepCompletionOptions {
  readonly stepTitle?: string;
  /// The command this step ran/asked for, passed into the visual context so the
  /// model can tell this step's moment from the previous step's.
  readonly commandTheStepAsksFor?: string;
  readonly hintsTheStepAuthorWrote?: readonly string[];
  readonly maximumPolls?: number;
  readonly context?: WatchScreenContext;
}

/// Blocks on a step's `watch` block until one expectation verifies, cheapest
/// first, or the bounded wait runs out. The Windows autopilot's answer to the
/// macOS `WatchLoop`, shaped as an awaitable the pumped runner calls inline.
export class WatchStepExecutor {
  constructor(private readonly seams: WatchSeams) {}

  /// Polls the watch's expectations until one verifies or the poll budget runs
  /// out. A `sensitive` watch never reaches the visual rung. Returns `verified`
  /// (with which expectation settled it) or `timedOut` (with any stuck hint).
  async awaitStepCompletion(
    watch: StepWatch,
    options: AwaitStepCompletionOptions = {},
  ): Promise<WatchStepOutcome> {
    const orderedExpectations = orderExpectationsCheapestFirst(watch.expect);
    const maximumPolls = options.maximumPolls ?? DEFAULT_MAXIMUM_POLLS;

    // The visual budget is per-step working state, fresh for each call, so no
    // step's spend can leak into the next one.
    let visualChecksUsedOnThisStep = 0;
    let secondsAtMostRecentVisualCheck: number | undefined;
    let mostRecentStuckHint: string | undefined;

    for (let pollIndex = 0; pollIndex < maximumPolls; pollIndex += 1) {
      for (const expectation of orderedExpectations) {
        if (expectation.type === "visual") {
          // A sensitive step is NEVER captured — the visual rung is skipped
          // outright and the step settles from side signals or hands back.
          if (watch.sensitive === true) continue;

          if (visualChecksUsedOnThisStep >= MAXIMUM_VISUAL_CHECKS_PER_STEP) continue;
          const nowInSeconds = this.seams.nowInSeconds();
          if (
            secondsAtMostRecentVisualCheck !== undefined &&
            nowInSeconds - secondsAtMostRecentVisualCheck < MINIMUM_SECONDS_BETWEEN_VISUAL_CHECKS
          ) {
            continue;
          }

          // The budget is spent BEFORE the call, not after: a failed call still
          // cost time and still hit a rate limit, and a loop that only counted
          // successes would retry a broken model every poll. Mirrors macOS.
          visualChecksUsedOnThisStep += 1;
          secondsAtMostRecentVisualCheck = nowInSeconds;

          const verdict = await this.evaluateVisualExpectation(expectation, options);
          if (verdict?.kind === "completed") {
            return { kind: "verified", verifiedBy: "visual" };
          }
          if (verdict?.kind === "userStuck") {
            mostRecentStuckHint = verdict.hint;
          }
          continue;
        }

        if (await this.isSideSignalSatisfied(expectation)) {
          return { kind: "verified", verifiedBy: expectation.type };
        }
      }

      await this.seams.waitForMilliseconds(MILLISECONDS_BETWEEN_POLLS);
    }

    return { kind: "timedOut", stuckHint: mostRecentStuckHint };
  }

  /// A single pixel-free expectation. Never captures a screenshot.
  private async isSideSignalSatisfied(expectation: WatchExpectation): Promise<boolean> {
    switch (expectation.type) {
      case "toolVersion":
        // A tool the allowlist does not know is refused, never asked about — the
        // same boundary `tool-versions.ts` draws (no command is built from guide
        // text). An unknown tool simply never verifies.
        if (!isAllowlistedTool(expectation.tool)) return false;
        return this.seams.isToolInstalled(expectation.tool);

      case "foregroundApp": {
        const foregroundProcess = await this.seams.readForegroundProcess();
        if (foregroundProcess === undefined) return false;
        return foregroundProcessSatisfiesIdentity(foregroundProcess.processName, expectation.bundleId);
      }

      case "urlHost": {
        const foregroundBrowserHost = await this.seams.readForegroundBrowserHost();
        return hostMatchesExpectedHost(foregroundBrowserHost, expectation.host);
      }

      case "axElement":
        return this.seams.isAxElementPresent(expectation.roleLabel);

      case "visual":
        // Never a side signal. This case exists so a sixth expectation type is a
        // compile error rather than a silent pass.
        return false;
    }
  }

  private async evaluateVisualExpectation(
    expectation: Extract<WatchExpectation, { type: "visual" }>,
    options: AwaitStepCompletionOptions,
  ): Promise<WatchVerdict | undefined> {
    const screenshotJpegBase64 = await this.seams.captureScreenshotJpegBase64();
    if (screenshotJpegBase64 === undefined || screenshotJpegBase64.length === 0) {
      return undefined;
    }
    return this.seams.evaluateVisualCheck({
      screenshotJpegBase64,
      visualPrompt: expectation.prompt,
      stepTitle: options.stepTitle ?? "",
      context: options.context ?? { commandTheStepAsksFor: options.commandTheStepAsksFor },
      hintsTheStepAuthorWrote: options.hintsTheStepAuthorWrote ?? [],
    });
  }
}

/// Builds a `WatchStepExecutor` on the real Windows seams — reused by the
/// autopilot controller in production, and by any host wiring in the visual
/// capture/evaluation seams. Overrides let a host supply the visual pipeline
/// without re-stating the PowerShell seams.
export function defaultWatchExecutor(overrides: Partial<WatchSeams> = {}): WatchStepExecutor {
  return new WatchStepExecutor(defaultWatchSeams(overrides));
}
