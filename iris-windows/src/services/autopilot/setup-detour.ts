//
// The setup-recovery detour and the missing-tool self-heal helpers — the Windows
// port of macOS's `enterSetupRecoveryIfAPrerequisiteIsMissing`
// (GuideSessionController.swift) and
// `installTheMissingToolTheGuideInstallsItself` (GuideAutopilotRunner.swift).
//
// Two related jobs, one module because they share the same idea — a recipe both
// declares the tools it needs and carries the steps that install them, so a
// missing tool is never a dead end:
//
//   1. BEFORE the recipe's first step, check the prerequisites the recipe checks
//      but does not itself install (git, node). Anything missing is either
//      installed by winget (under the autonomy grant) or the reader is sent to
//      the tool's download page, and Iris polls until the tool appears and then
//      carries on — no "I did it" tap, mirroring the macOS re-check.
//
//   2. MID-recipe, a command that dies because a program is not on the PATH is
//      matched against the recipe's OWN earlier install step for that program;
//      the runner re-runs that step once and retries, before any model ladder.
//
// This module is pure (no Node/Electron/Windows APIs). Tool probing and the wall
// clock are injected seams, so the whole flow is driven by fakes in the vitest
// suite on any host. The real seams live in `main/setup-detour-host.ts`.
//

import type { InstallRecipe, RecipeStep } from "./recipe";
import { commandForPlatform } from "./recipe";
import type { AutopilotEvent } from "./runner";
import { approve, assess, type ApprovedCommand } from "./risk";
import type { ShellSession } from "./shell";
import { DEFAULT_COMMAND_TIMEOUT_MS } from "./shell";

/// How often Iris re-checks for a tool while the reader installs it (ms). Short
/// enough that a finished install is picked up promptly, long enough not to spin.
export const PREREQUISITE_POLL_INTERVAL_MS = 3_000;

/// How long Iris waits for a prerequisite to appear before it gives up and hands
/// the reader the wheel (ms). Fifteen minutes covers a slow download + installer
/// without waiting forever on an install that was abandoned.
export const PREREQUISITE_POLL_DEADLINE_MS = 15 * 60 * 1_000;

/// A prerequisite tool the reader must have before a recipe can run: the tool
/// name (as `tool-versions.ts` knows it), the page that installs it, and the
/// winget id for the fast path. The recipe declares WHICH tools it needs (via
/// its `tool_version` check steps); this table says how to GET each one, the way
/// the macOS branch's setup steps carry the git/node download links.
export interface PrerequisiteTool {
  readonly tool: string;
  readonly downloadHref: string;
  readonly wingetId: string;
}

/// How to obtain each prerequisite Iris can heal. Deliberately just git and node
/// — the two tools every source-build recipe checks and none of them install
/// (pnpm/rust/uv are installed by their own recipe steps, so a missing one of
/// those is the self-heal's job, not the detour's).
const PREREQUISITE_CATALOG: ReadonlyMap<string, Omit<PrerequisiteTool, "tool">> = new Map([
  ["git", { downloadHref: "https://git-scm.com/download/win", wingetId: "Git.Git" }],
  ["node", { downloadHref: "https://nodejs.org/en/download", wingetId: "OpenJS.NodeJS.LTS" }],
]);

/// The first program a command line would run, normalized to the bare tool name:
/// the first whitespace-delimited token, unquoted, with a `.cmd`/`.exe`/`.bat`
/// suffix and any path prefix stripped, lowercased. `"npm.cmd install -g pnpm"`
/// → `"npm"`, `"git --version"` → `"git"`. Used both to tell a recipe's verify
/// steps from its install steps and to name the tool a failed command reached
/// for. Mirrors the leading half of macOS `programsEachLineWouldRun`.
export function firstProgramToken(command: string): string {
  const firstToken = command.trim().split(/\s+/)[0] ?? "";
  const unquoted = firstToken.replace(/^["']|["']$/g, "");
  const bareName = unquoted.split(/[\\/]/).pop() ?? unquoted;
  return bareName.replace(/\.(cmd|exe|bat|ps1)$/i, "").toLowerCase();
}

/// Whether a step verifies a tool rather than installing it — a `command` step
/// whose `tool_version` check names the same tool its command runs first
/// (`git --version` checks git and runs git). The setup detour treats these as
/// the prerequisites: the tool has to be there already, because the step does
/// not put it there.
function stepVerifiesTool(step: RecipeStep, platform: NodeJS.Platform): string | undefined {
  if (step.kind !== "command" || step.check?.type !== "tool_version") return undefined;
  const command = commandForPlatform(step, platform);
  if (command === undefined) return undefined;
  return firstProgramToken(command) === step.check.tool ? step.check.tool : undefined;
}

/// Whether a step INSTALLS a tool rather than verifying it — a `command` step
/// whose `tool_version` check names a tool its command does NOT run first
/// (`winget install --id astral-sh.uv` checks uv but runs winget). This is the
/// step the self-heal re-runs when a later command dies because that tool is
/// missing. Mirrors macOS's rule that "a command that begins by running the tool
/// cannot be what installs it".
function toolInstalledByStep(step: RecipeStep, platform: NodeJS.Platform): string | undefined {
  if (step.kind !== "command" || step.check?.type !== "tool_version") return undefined;
  const command = commandForPlatform(step, platform);
  if (command === undefined) return undefined;
  return firstProgramToken(command) !== step.check.tool ? step.check.tool : undefined;
}

/// The prerequisites this recipe requires but does not install — the tools it
/// probes with a bare `<tool> --version` check and that Iris knows how to fetch
/// (git, node). Order preserved, de-duplicated, so the detour walks them the way
/// the recipe lists them. Mirrors macOS `prerequisiteToolNames(declaredBy:)`.
export function prerequisitesFor(
  recipe: InstallRecipe,
  platform: NodeJS.Platform,
): PrerequisiteTool[] {
  const seen = new Set<string>();
  const prerequisites: PrerequisiteTool[] = [];
  for (const step of recipe.steps) {
    const tool = stepVerifiesTool(step, platform);
    if (tool === undefined || seen.has(tool)) continue;
    const howToGetIt = PREREQUISITE_CATALOG.get(tool);
    if (howToGetIt === undefined) continue;
    seen.add(tool);
    prerequisites.push({ tool, ...howToGetIt });
  }
  return prerequisites;
}

/// The recipe's own command for installing `tool`, drawn from an earlier install
/// step (index strictly before `beforeIndex`). Undefined when the recipe has no
/// such step — the situation where the self-heal steps aside and the ordinary
/// failure path (or, later, the model ladder) takes over. Mirrors macOS
/// `theGuidesOwnInstallCommandForAToolThisCommandRuns`.
export function recipeInstallStepForTool(
  recipe: InstallRecipe,
  tool: string,
  beforeIndex: number,
  platform: NodeJS.Platform,
): RecipeStep | undefined {
  for (let index = 0; index < beforeIndex && index < recipe.steps.length; index += 1) {
    const step = recipe.steps[index]!;
    if (toolInstalledByStep(step, platform) === tool) return step;
  }
  return undefined;
}

/// The winget line Iris runs to install a prerequisite through the fast path.
/// The flags accept the source/package agreements so an unattended install does
/// not stop for a prompt — the same shape the built-in recipes' winget steps
/// use.
export function wingetInstallCommand(wingetId: string): string {
  return `winget install --id ${wingetId} -e --accept-source-agreements --accept-package-agreements`;
}

/// What the detour decides to do with a winget prerequisite install, having put
/// it through the risk gate:
///   - `auto`         run it now (the autonomy grant is in force)
///   - `needs_confirm` a tap would be required, so the detour skips winget and
///                     sends the reader to the download page instead
///   - `refused`      the catastrophe floor caught it (never, for a plain
///                     `winget install`, but checked rather than assumed)
export type WingetDecision = "auto" | "needs_confirm" | "refused";

/// Runs a prerequisite's winget install through the risk gate and reports how the
/// detour should treat it. The autonomy grant is the pivot: WITH it, the install
/// runs hands-off (`auto`); WITHOUT it, installing software is exactly the kind of
/// action that should wait for one deliberate tap, so it is reported as
/// `needs_confirm` — and since the pre-flight detour has no per-step confirm UI,
/// the caller then routes to the manual download page instead. The catastrophe
/// floor is consulted first and still gets the last word (a hallucinated
/// destructive argument is refused even under the grant), which is why this asks
/// the risk gate rather than reading `autonomyGranted` alone.
export function wingetInstallDecision(
  command: string,
  autonomyGranted: boolean,
): WingetDecision {
  if (assess(command, "vetted_recipe", autonomyGranted).tier === "refused_outright") {
    return "refused";
  }
  return autonomyGranted ? "auto" : "needs_confirm";
}

/// The wall clock and sleep, injected so the poll loop runs instantly in tests.
export interface DetourClock {
  now(): number;
  sleep(ms: number): Promise<void>;
}

/// "Is this tool on the PATH?", injected so the suite never shells out. The real
/// implementation (main/setup-detour-host.ts) re-reads the machine+user PATH
/// from the registry each time, so a tool installed moments ago is seen.
export interface ToolProbe {
  isInstalled(tool: string): Promise<boolean>;
  isWingetAvailable(): Promise<boolean>;
}

/// Everything the detour needs from the outside world, all injectable.
export interface SetupDetourDeps {
  readonly probe: ToolProbe;
  readonly clock: DetourClock;
  readonly platform: NodeJS.Platform;
  readonly autonomyGranted: boolean;
  /// Forward an event to the renderer (and, for `openRequested`, open the URL).
  readonly emit: (event: AutopilotEvent) => void;
}

/// How the detour ended.
export type SetupDetourResult =
  | { readonly kind: "ready" }
  | { readonly kind: "surfaced"; readonly reason: string };

/// Runs the setup-recovery detour for a recipe, before its first step.
///
/// Checks every prerequisite the recipe declares; if all are present it returns
/// `ready` having emitted nothing. Otherwise it emits one `setupDetour` event
/// listing what is missing, then for each missing tool tries the winget fast
/// path (under the grant) and falls back to opening the download page, polling
/// `tool-versions` until the tool appears — no reader tap — or the deadline
/// passes, at which point it surfaces.
export async function runSetupDetour(
  recipe: InstallRecipe,
  shell: ShellSession,
  deps: SetupDetourDeps,
): Promise<SetupDetourResult> {
  const prerequisites = prerequisitesFor(recipe, deps.platform);
  if (prerequisites.length === 0) return { kind: "ready" };

  const missing: PrerequisiteTool[] = [];
  for (const prerequisite of prerequisites) {
    if (!(await deps.probe.isInstalled(prerequisite.tool))) missing.push(prerequisite);
  }
  if (missing.length === 0) return { kind: "ready" };

  deps.emit({
    type: "setupDetour",
    missing: missing.map((tool) => ({ tool: tool.tool, downloadHref: tool.downloadHref })),
  });

  const wingetAvailable = await deps.probe.isWingetAvailable();
  for (const prerequisite of missing) {
    const resolved = await resolveOnePrerequisite(prerequisite, wingetAvailable, shell, deps);
    if (resolved.kind === "surfaced") return resolved;
  }
  return { kind: "ready" };
}

async function resolveOnePrerequisite(
  prerequisite: PrerequisiteTool,
  wingetAvailable: boolean,
  shell: ShellSession,
  deps: SetupDetourDeps,
): Promise<SetupDetourResult> {
  // The winget fast path, tried first when winget is present and the grant lets
  // Iris run it unattended. A successful install that the tool probe then
  // confirms ends this prerequisite with no download page and no polling.
  if (wingetAvailable) {
    const command = wingetInstallCommand(prerequisite.wingetId);
    if (wingetInstallDecision(command, deps.autonomyGranted) === "auto") {
      const approved: ApprovedCommand | undefined = approve(command, "vetted_recipe", deps.autonomyGranted);
      if (approved !== undefined) {
        deps.emit({ type: "commandStarted", text: command, friendlyLabel: "Installing a tool it needs…" });
        const outcome = await shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);
        deps.emit({
          type: "commandFinished",
          exitCode: outcome.kind === "succeeded" ? 0 : outcome.kind === "failed" ? outcome.exitCode : 1,
          output: outcome.kind === "succeeded" || outcome.kind === "failed" ? outcome.output : "",
        });
        // Even a clean winget install may not be visible until the PATH is
        // re-read; the probe does that itself, so a confirming check is enough.
        if (outcome.kind === "succeeded" && (await deps.probe.isInstalled(prerequisite.tool))) {
          return { kind: "ready" };
        }
      }
    }
  }

  // Manual fallback: open the download page and wait for the tool to appear.
  deps.emit({ type: "openRequested", href: prerequisite.downloadHref });
  const appeared = await pollUntilInstalled(prerequisite.tool, deps);
  return appeared
    ? { kind: "ready" }
    : {
        kind: "surfaced",
        reason:
          `Iris waited for ${prerequisite.tool} to be installed but it didn't show up. ` +
          `Install it from ${prerequisite.downloadHref}, then start the install again.`,
      };
}

/// Polls `tool-versions` until the tool is installed or the deadline passes.
/// Returns whether it appeared. No reader tap — the reappearance is the signal,
/// which is the whole point of the macOS auto-recheck.
async function pollUntilInstalled(tool: string, deps: SetupDetourDeps): Promise<boolean> {
  const startedAt = deps.clock.now();
  for (;;) {
    if (await deps.probe.isInstalled(tool)) return true;
    if (deps.clock.now() - startedAt >= PREREQUISITE_POLL_DEADLINE_MS) return false;
    await deps.clock.sleep(PREREQUISITE_POLL_INTERVAL_MS);
    // One more check after the last sleep so a tool that appears right at the
    // deadline is still caught rather than reported missing.
    if (deps.clock.now() - startedAt >= PREREQUISITE_POLL_DEADLINE_MS) {
      return deps.probe.isInstalled(tool);
    }
  }
}

/// Whether a failed command's outcome is the "program not on the PATH" shape —
/// the Windows analog of exit 127. PowerShell reports a `CommandNotFoundException`
/// as a generic non-zero exit with a distinctive message rather than code 127, so
/// the text is matched too; a POSIX login shell (Iris on a Mac) does exit 127.
export function isCommandNotFound(exitCode: number, output: string): boolean {
  if (exitCode === 127) return true;
  return /is not recognized as (?:the name of a cmdlet|an internal or external command)|command not found|CommandNotFoundException/i.test(
    output,
  );
}

/// The self-heal decision for a failed command: the recipe's own earlier step
/// that installs the tool the command reached for, or undefined when this is not
/// a missing-tool failure the recipe can fix itself. `currentIndex` is the step
/// that just failed, so only steps strictly before it count as its prerequisite
/// install. Mirrors macOS `installTheMissingToolTheGuideInstallsItself`'s guard.
export function selfHealStepForFailure(
  recipe: InstallRecipe,
  currentIndex: number,
  failedCommand: string,
  exitCode: number,
  output: string,
  platform: NodeJS.Platform,
): RecipeStep | undefined {
  if (!isCommandNotFound(exitCode, output)) return undefined;
  const missingTool = firstProgramToken(failedCommand);
  return recipeInstallStepForTool(recipe, missingTool, currentIndex, platform);
}
