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
/// winget id for the fast path. The recipe declares WHICH tools it needs — a
/// guide-derived recipe via `recipe.prerequisites` (carried from the guide
/// branch's `setupSteps`), a hand-authored one via its `tool_version` check
/// steps — and this table says how to GET each one, the way the macOS branch's
/// setup steps carry the git/node download links.
export interface PrerequisiteTool {
  readonly tool: string;
  readonly downloadHref: string;
  /// The winget id for the fast path, when Iris knows one for this tool. Absent
  /// for a prerequisite Iris can only send the reader to a download page for.
  readonly wingetId?: string;
  /// The guide's OWN install command for this prerequisite, when its setup step
  /// installs by command rather than by a manual download. Tried (under the
  /// grant) before the winget fast path and the download-page fallback.
  readonly installCommand?: string;
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

/// The bare tool name every LINE of a command would run first — the full macOS
/// `programsEachLineWouldRun`, not just the leading token. A guide's check step
/// is often multi-line (`git --version\nnode --version`), and a tool it runs on
/// ANY line cannot be a tool that same step installs. Splitting on both newlines
/// and PowerShell/POSIX statement separators (`;`, `&&`, `|`) keeps the rule
/// honest for a `winget … ; refreshenv`-style line.
export function programsEachLineWouldRun(command: string): Set<string> {
  const programs = new Set<string>();
  for (const line of command.split(/\r?\n|;|&&|\|/)) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    programs.add(firstProgramToken(trimmed));
  }
  return programs;
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
  return programsEachLineWouldRun(command).has(step.check.tool) ? step.check.tool : undefined;
}

/// Every tool a step INSTALLS rather than verifies — the tools it names as a
/// completion signal (its `tool_version` check AND every `toolVersion` in its
/// `watch.expect`) that its own command does NOT run on any line
/// (`npm.cmd install -g pnpm` watches pnpm but runs npm ⇒ installs pnpm;
/// `git --version\nnode --version` watches git+node and runs both ⇒ installs
/// neither). This is the crux of the self-heal: real guides carry the install
/// signal in `watch.expect`, not `check`, so consulting only `check` (the old
/// behaviour) left the self-heal inert for every guide-derived recipe. Mirrors
/// macOS `commandsThisGuidePublishesToInstallEachToolItWatchesFor`, which scans
/// every step's watch expectations, plus its "a command that begins by running
/// the tool cannot install it" guard.
function toolsInstalledByStep(step: RecipeStep, platform: NodeJS.Platform): string[] {
  if (step.kind !== "command") return [];
  const command = commandForPlatform(step, platform);
  if (command === undefined) return [];
  const programsRun = programsEachLineWouldRun(command);

  const named = new Set<string>();
  if (step.check?.type === "tool_version") named.add(step.check.tool);
  for (const expectation of step.watch?.expect ?? []) {
    if (expectation.type === "toolVersion") named.add(expectation.tool);
  }
  return [...named].filter((tool) => !programsRun.has(tool));
}

/// Resolves one prerequisite tool name (with an optional download page and
/// install command the guide named for it) into a `PrerequisiteTool` the detour
/// can act on, filling in the winget id and a fallback download page from the
/// built-in catalog. Returns undefined only when there is genuinely no way to
/// obtain the tool — no winget id, no page, no command — so the detour never
/// lists a prerequisite it cannot heal.
function prerequisiteToolFor(
  tool: string,
  hrefFromGuide: string | undefined,
  installCommand: string | undefined,
): PrerequisiteTool | undefined {
  const known = PREREQUISITE_CATALOG.get(tool);
  const downloadHref = hrefFromGuide ?? known?.downloadHref ?? "";
  const wingetId = known?.wingetId;
  if (downloadHref === "" && wingetId === undefined && installCommand === undefined) {
    return undefined;
  }
  return {
    tool,
    downloadHref,
    ...(wingetId !== undefined ? { wingetId } : {}),
    ...(installCommand !== undefined ? { installCommand } : {}),
  };
}

/// The prerequisites this recipe requires but does not install — the tools it
/// needs on PATH before its first step can run, and that Iris knows how to fetch
/// (git, node). Two sources, because a recipe declares them two ways:
///
///   - A guide-derived recipe carries them in `recipe.prerequisites`, mapped
///     from the guide branch's `setupSteps` (this is where every real published
///     guide puts git/node). Reading ONLY the step-based source below left the
///     detour inert for all 16 guide-derived apps — the bug this fixes.
///   - A hand-authored built-in recipe embeds them as ordinary `command` steps
///     whose `tool_version` check names the tool the command runs (`git
///     --version` checks and runs git), which `stepVerifiesTool` recognises.
///
/// Order preserved (prerequisites first, then step-declared), de-duplicated by
/// tool name. Mirrors macOS `prerequisiteToolNames(declaredBy:)`, which reads
/// `branch.setupSteps` directly.
export function prerequisitesFor(
  recipe: InstallRecipe,
  platform: NodeJS.Platform,
): PrerequisiteTool[] {
  const seen = new Set<string>();
  const prerequisites: PrerequisiteTool[] = [];
  const consider = (
    tool: string,
    hrefFromGuide: string | undefined,
    installCommand: string | undefined,
  ): void => {
    if (seen.has(tool)) return;
    const resolved = prerequisiteToolFor(tool, hrefFromGuide, installCommand);
    if (resolved === undefined) return;
    seen.add(tool);
    prerequisites.push(resolved);
  };

  // The guide-derived source: the branch's setupSteps, carried onto the recipe.
  for (const prerequisite of recipe.prerequisites ?? []) {
    if (prerequisite.tool !== undefined) {
      consider(prerequisite.tool, prerequisite.href, prerequisite.command);
    }
  }
  // The hand-authored source: `tool_version` check steps that verify a tool.
  for (const step of recipe.steps) {
    const tool = stepVerifiesTool(step, platform);
    if (tool !== undefined) consider(tool, undefined, undefined);
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
    if (toolsInstalledByStep(step, platform).includes(tool)) return step;
  }
  return undefined;
}

/// The winget line Iris runs to install a prerequisite through the fast path.
/// The agreement flags stop it pausing for a source/package prompt;
/// `--disable-interactivity` forbids the installer's OWN interactive prompts, so
/// this fully-unattended detour install (run before the recipe's first step,
/// with no one to answer a dialog) FAILS FAST and falls back to the download
/// page rather than hanging on input nobody will supply. It deliberately does
/// NOT force `--scope user`: git and node ship machine-scope manifests, and
/// pinning user scope would make winget error "no applicable installer" and
/// break the detour outright — an OS-level UAC elevation prompt is a separate
/// hazard winget cannot suppress without admin, and the timeout path now reaps
/// the whole process tree (`PowerShellSession` deadline → `killTree`).
export function wingetInstallCommand(wingetId: string): string {
  return `winget install --id ${wingetId} -e --accept-source-agreements --accept-package-agreements --disable-interactivity`;
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

/// What probing for a tool concluded — deliberately THREE states, not a boolean.
/// A probe that timed out or failed to spawn has NOT established that the tool is
/// missing; Iris has no idea what is on the machine in that case, and marching
/// the reader through an install they may not need is the wrong guess. Mirrors
/// macOS's `.installed` / `.notInstalled` / `.couldNotBeChecked` row, whose
/// detour trigger filters strictly on `.notInstalled`.
export type ToolProbeResult = "installed" | "notInstalled" | "couldNotBeChecked";

/// "Is this tool on the PATH?", injected so the suite never shells out. The real
/// implementation (main/setup-detour-host.ts) re-reads the machine+user PATH
/// from the registry each time, so a tool installed moments ago is seen. Returns
/// the tri-state above so a probe that could not be run is never mistaken for a
/// tool that is genuinely absent.
export interface ToolProbe {
  probe(tool: string): Promise<ToolProbeResult>;
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
  /// Whether the run has been aborted out from under the detour (the red 'Stop').
  /// The detour is an unattended background wait that can run for up to fifteen
  /// minutes; without a cancellation signal an abort could not stop it, so it
  /// would keep spawning winget installs and opening pages after the window has
  /// folded away, and then resume the run against a shell the abort disposed.
  /// Checked before every install it starts and on every poll. Absent ⇒ never
  /// cancelled (the pure suite that is not exercising abort passes nothing).
  readonly shouldCancel?: () => boolean;
}

/// How the detour ended.
export type SetupDetourResult =
  | { readonly kind: "ready" }
  | { readonly kind: "surfaced"; readonly reason: string }
  /// The run was aborted (the red 'Stop') while the detour was still working.
  /// The caller must NOT go on to build and run the recipe — the shell it would
  /// use has been disposed.
  | { readonly kind: "cancelled" };

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
  if (deps.shouldCancel?.()) return { kind: "cancelled" };

  // Only a prerequisite the probe positively reports ABSENT counts as missing.
  // A `couldNotBeChecked` (a probe that timed out or failed to spawn) is left
  // alone: Iris does not know it is missing, so it does not divert the reader
  // into installing something they may already have.
  const missing: PrerequisiteTool[] = [];
  for (const prerequisite of prerequisites) {
    if ((await deps.probe.probe(prerequisite.tool)) === "notInstalled") missing.push(prerequisite);
  }
  if (missing.length === 0) return { kind: "ready" };

  deps.emit({
    type: "setupDetour",
    missing: missing.map((tool) => ({ tool: tool.tool, downloadHref: tool.downloadHref })),
  });

  const wingetAvailable = await deps.probe.isWingetAvailable();
  for (const prerequisite of missing) {
    if (deps.shouldCancel?.()) return { kind: "cancelled" };
    const resolved = await resolveOnePrerequisite(prerequisite, wingetAvailable, shell, deps);
    if (resolved.kind === "surfaced" || resolved.kind === "cancelled") return resolved;
  }
  return { kind: "ready" };
}

async function resolveOnePrerequisite(
  prerequisite: PrerequisiteTool,
  wingetAvailable: boolean,
  shell: ShellSession,
  deps: SetupDetourDeps,
): Promise<SetupDetourResult> {
  // The guide's OWN install command first, when its setup step named one, then
  // the winget fast path. Either only runs under the grant, and a run that the
  // tool probe then confirms ends this prerequisite with no download page.
  const installCommands: string[] = [];
  if (prerequisite.installCommand !== undefined) installCommands.push(prerequisite.installCommand);
  if (wingetAvailable && prerequisite.wingetId !== undefined) {
    installCommands.push(wingetInstallCommand(prerequisite.wingetId));
  }
  for (const command of installCommands) {
    if (deps.shouldCancel?.()) return { kind: "cancelled" };
    if (wingetInstallDecision(command, deps.autonomyGranted) !== "auto") continue;
    const approved: ApprovedCommand | undefined = approve(command, "vetted_recipe", deps.autonomyGranted);
    if (approved === undefined) continue;
    deps.emit({ type: "commandStarted", text: command, friendlyLabel: "Installing a tool it needs…" });
    const outcome = await shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);
    deps.emit({
      type: "commandFinished",
      exitCode: outcome.kind === "succeeded" ? 0 : outcome.kind === "failed" ? outcome.exitCode : 1,
      output: outcome.kind === "succeeded" || outcome.kind === "failed" ? outcome.output : "",
    });
    if (deps.shouldCancel?.()) return { kind: "cancelled" };
    // Even a clean install may not be visible until the PATH is re-read; the
    // probe does that itself, so a confirming check is enough. Only a positive
    // "installed" ends the prerequisite — a probe that could not be run does not.
    if (outcome.kind === "succeeded" && (await deps.probe.probe(prerequisite.tool)) === "installed") {
      return { kind: "ready" };
    }
  }

  // Manual fallback: open the download page and wait for the tool to appear.
  // With no page to send the reader to, there is nothing left to try but to hand
  // the wheel back with a clear reason.
  if (deps.shouldCancel?.()) return { kind: "cancelled" };
  if (prerequisite.downloadHref === "") {
    return {
      kind: "surfaced",
      reason:
        `Iris couldn't install ${prerequisite.tool} for you and has no download page for it. ` +
        `Install it yourself, then start the install again.`,
    };
  }
  deps.emit({ type: "openRequested", href: prerequisite.downloadHref });
  const appeared = await pollUntilInstalled(prerequisite.tool, deps);
  if (appeared === "cancelled") return { kind: "cancelled" };
  return appeared === "installed"
    ? { kind: "ready" }
    : {
        kind: "surfaced",
        reason:
          `Iris waited for ${prerequisite.tool} to be installed but it didn't show up. ` +
          `Install it from ${prerequisite.downloadHref}, then start the install again.`,
      };
}

/// Polls `tool-versions` until the tool is installed, the deadline passes, or the
/// run is aborted. No reader tap — the reappearance is the signal, which is the
/// whole point of the macOS auto-recheck. A `couldNotBeChecked` probe keeps
/// polling (it is not "installed", but nor is it proof of absence); only a
/// positive `installed` ends the wait.
type PollResult = "installed" | "timedOut" | "cancelled";

async function pollUntilInstalled(tool: string, deps: SetupDetourDeps): Promise<PollResult> {
  const startedAt = deps.clock.now();
  for (;;) {
    if (deps.shouldCancel?.()) return "cancelled";
    if ((await deps.probe.probe(tool)) === "installed") return "installed";
    if (deps.clock.now() - startedAt >= PREREQUISITE_POLL_DEADLINE_MS) return "timedOut";
    await deps.clock.sleep(PREREQUISITE_POLL_INTERVAL_MS);
    // One more check after the last sleep so a tool that appears right at the
    // deadline is still caught rather than reported missing.
    if (deps.clock.now() - startedAt >= PREREQUISITE_POLL_DEADLINE_MS) {
      if (deps.shouldCancel?.()) return "cancelled";
      return (await deps.probe.probe(tool)) === "installed" ? "installed" : "timedOut";
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
