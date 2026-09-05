//
// Runtime recipe derivation — turning a fetched publik guide into an
// `InstallRecipe` the autopilot runner can drive, so every app with a Windows
// branch is auto-installable without a hand-authored entry in `recipes.ts`.
//
// This is the Windows answer to the macOS autopilot running an `IrisGuideStep`
// directly (`GuideAutopilotRunner`): rather than interpret guide steps in the
// runner, the Windows runner keeps its reviewed `RecipeStep` schema and this
// module maps a guide branch onto it. The mapping is the whole point — it decides
// who does each step (Iris runs it, the reader handles it, or it self-completes)
// while preserving the guide's ids, titles, bodies, and verifier labels.
//
// Pure module (no Node/Electron), fully unit-tested against the fixtures under
// `tests/fixtures/guides/`.
//

import type {
  IrisGuide,
  IrisGuideBranch,
  IrisGuideStep,
  IrisUnsupportedPair,
} from "./guide-model";
import { branchKeyFor } from "./guide-model";
import type {
  InstallRecipe,
  LaunchTarget,
  RecipeOutput,
  RecipePrerequisite,
  RecipeStep,
  StepCheck,
  StepExpectation,
} from "./recipe";

/// Which branch of a guide to derive. `platform` is the reader's computer;
/// `target` names the phone for a mobile guide (absent for desktop/local-web,
/// which resolve against the `…:desktop` branch key).
export interface RecipeDerivationTarget {
  readonly platform: "windows" | "macos";
  readonly target?: "ios" | "android";
}

/// The result of asking a guide for a recipe. Unsupported is its OWN case — a
/// pair the guide itself declares cannot work (Windows + iPhone) is never a
/// recipe, it is an explanation shown instead of steps.
export type RecipeResolution =
  | { readonly kind: "recipe"; readonly recipe: InstallRecipe }
  | {
      readonly kind: "unsupported";
      readonly branchKey: string;
      readonly unsupported: IrisUnsupportedPair;
    }
  /// The guide has no branch for this platform/target at all.
  | { readonly kind: "noBranch"; readonly requestedBranchKey: string };

/// The branch-key convention the deep link uses: a desktop/local-web install is
/// `windows:desktop`, a phone install is `windows:android` / `windows:ios`.
export function branchKeyForTarget(target: RecipeDerivationTarget): string {
  return `${target.platform}:${target.target ?? "desktop"}`;
}

// ── Command shape (ported from macOS `GuideAutopilotCommandShape`) ─────────────

/// Dev servers and watchers never exit; a step that runs one must be marked
/// long-running so the runner starts it and moves on instead of waiting forever.
/// Ported literally from `GuideAutopilotCommandShape.holdsTheShellOpen` — keep it
/// a superset of the run-from-source script names any shipped guide uses.
const COMMANDS_THAT_HOLD_THE_SHELL_OPEN: readonly RegExp[] = [
  /\b(npm|pnpm|yarn|bun)\s+(run\s+)?(start|dev|watch|serve|preview|app|electron)\b/i,
  /\bnext\s+dev\b/i,
  /(^|\s|\/)vite(\s|$)/i,
  /\bdocker\s+compose\s+up\b(?![^\n]*\s-d\b)/i,
  /\bpython3?\s+-m\s+http\.server\b/i,
  /\bcargo\s+run\b/i,
  /\bexpo\s+start\b/i,
  /\bflutter\s+run\b/i,
  /\brails\s+s(erver)?\b/i,
  /\btauri\s+dev\b/i,
];

export function commandHoldsTheShellOpen(command: string): boolean {
  return COMMANDS_THAT_HOLD_THE_SHELL_OPEN.some((pattern) => pattern.test(command));
}

/// A guide command is "runnable" only when it is a non-blank string. A `terminal`
/// or `check` step with no command is prose (a guide's "open your shell"), which
/// maps to a self-completing `noop` step — matching macOS's nil-command → succeeded.
function hasRunnableCommand(step: IrisGuideStep): boolean {
  return step.command !== undefined && step.command.trim() !== "";
}

// ── Step mapping ───────────────────────────────────────────────────────────────

/// Maps one guide step onto one recipe step. The kind decides who does it:
///   terminal/check with a command → `command` (Iris runs it)
///   terminal/check with no command → `noop` (self-completes)
///   open → `open` (auto-advances once opened)
///   permission/web/paste → the matching reader-handled kind
///   verify → `verify`, carrying the watch expectations for the watch-loop port
/// Ids, titles, bodies and verifier labels are preserved on every kind.
function recipeStepFromGuideStep(step: IrisGuideStep): RecipeStep {
  const shared = {
    id: step.id,
    title: step.title,
    body: step.body,
    ...(step.verifierLabel !== undefined ? { verifierLabel: step.verifierLabel } : {}),
  };

  switch (step.kind) {
    case "terminal":
    case "check": {
      if (!hasRunnableCommand(step)) {
        return { ...shared, kind: "noop" };
      }
      const command = step.command as string;
      const check: StepCheck | undefined =
        step.tool !== undefined ? { type: "tool_version", tool: step.tool } : undefined;
      return {
        ...shared,
        kind: "command",
        command,
        ...(step.workingDirectory !== undefined && step.workingDirectory !== ""
          ? { workingDirectory: step.workingDirectory }
          : {}),
        ...(commandHoldsTheShellOpen(command) ? { longRunning: true } : {}),
        ...(check !== undefined ? { check } : {}),
      };
    }

    case "open":
      return {
        ...shared,
        kind: "open",
        ...(step.href !== undefined ? { href: step.href } : {}),
      };

    case "permission":
      return {
        ...shared,
        kind: "permission",
        instruction: step.body,
        ...(step.href !== undefined ? { href: step.href } : {}),
      };

    case "web":
      return {
        ...shared,
        kind: "web",
        instruction: step.body,
        ...(step.href !== undefined ? { href: step.href } : {}),
      };

    case "paste":
      // Iris never types the secret — the reader moves it — so a paste step is
      // always handed over, and it deliberately carries no command.
      return { ...shared, kind: "paste", instruction: step.body };

    case "verify":
      return {
        ...shared,
        kind: "verify",
        ...(step.watch !== undefined && step.watch.expect.length > 0
          ? { verifyExpectations: step.watch.expect.map(expectationForRecipe) }
          : {}),
      };
  }
}

/// The guide expectation type and the recipe expectation type are the same shape;
/// this is the identity map, spelled out so a future divergence is caught by the
/// compiler rather than silently mis-carried.
function expectationForRecipe(expectation: StepExpectation): StepExpectation {
  return expectation;
}

// ── Prerequisites (setup steps) ────────────────────────────────────────────────

/// Carries a branch's `setupSteps` as recipe prerequisites for the setup-detour
/// port: the tool the reader needs, where to get it, or the command that installs
/// it. Preserves the setup step's id/title/body.
function prerequisitesFromBranch(branch: IrisGuideBranch): RecipePrerequisite[] {
  return branch.setupSteps.map((setupStep) => ({
    id: setupStep.id,
    title: setupStep.title,
    ...(setupStep.tool !== undefined ? { tool: setupStep.tool } : {}),
    ...(setupStep.href !== undefined ? { href: setupStep.href } : {}),
    ...(hasRunnableCommand(setupStep) ? { command: setupStep.command as string } : {}),
    ...(setupStep.body !== "" ? { body: setupStep.body } : {}),
  }));
}

// ── Output / launch target ─────────────────────────────────────────────────────

/// The first localhost/127.0.0.1 URL a branch names — in an `open` step's href
/// first (the app the guide sends the reader to), then anywhere in a command.
/// This is the recipe's fallback local-web URL; the runner still overrides it with
/// the port a dev server actually served on (`detectServedUrl`).
function firstLocalWebUrl(branch: IrisGuideBranch): string | undefined {
  const localhostPattern = /https?:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?(?:\/\S*)?/i;
  for (const step of branch.steps) {
    if (step.kind === "open" && step.href !== undefined) {
      const match = step.href.match(localhostPattern);
      if (match) return match[0];
    }
  }
  for (const step of branch.steps) {
    if (step.command !== undefined) {
      const match = step.command.match(localhostPattern);
      if (match) return match[0];
    }
  }
  // A local-web guide that never names a localhost URL (a Cloudflare Worker
  // deploy, a browser extension) still declares itself local-web; fall back to
  // the first `open` step's http(s) href, then to a plain localhost default.
  for (const step of branch.steps) {
    if (step.kind === "open" && step.href !== undefined && /^https?:\/\//i.test(step.href)) {
      return step.href;
    }
  }
  return undefined;
}

/// The Windows launch target for a desktop app, read from the guide's own
/// `Start-Process "<path>"` open-app step. The PowerShell `$env:NAME` token is
/// rewritten to the `%NAME%` form `app-inventory.ts`'s launcher expands. When no
/// such command exists (a guide whose "app" is a dev-server browser window), there
/// is no exe to launch and this returns undefined.
function launchTargetFromBranch(branch: IrisGuideBranch): LaunchTarget | undefined {
  // Search from the end: the launch command is near the finish of an install.
  for (let index = branch.steps.length - 1; index >= 0; index -= 1) {
    const command = branch.steps[index]?.command;
    if (command === undefined) continue;
    const match = command.match(/Start-Process\s+(?:-FilePath\s+)?["']([^"']+)["']/i);
    if (match) {
      const rawPath = match[1];
      const windowsEnvironmentPath = rawPath.replace(/\$env:([A-Za-z_][A-Za-z0-9_]*)/g, "%$1%");
      return { via: "path", path: windowsEnvironmentPath };
    }
  }
  return undefined;
}

/// Chooses the recipe's output and how Iris opens it, from the guide's declared
/// `outputType` and the branch's steps. desktop_app resolves to an exe launch when
/// the guide launches one, otherwise a served URL when it names one, otherwise
/// nothing to auto-open; local_web resolves to the served URL; mobile_app has
/// nothing to open on the PC; credential produces a credential.
function outputForGuide(guide: IrisGuide, branch: IrisGuideBranch): RecipeOutput {
  switch (guide.outputType) {
    case "credential":
      return { type: "credential" };
    case "local_web": {
      const url = firstLocalWebUrl(branch) ?? "http://localhost";
      return { type: "local_web", url };
    }
    case "desktop_app": {
      const launch = launchTargetFromBranch(branch);
      if (launch !== undefined) return { type: "desktop_app", launch };
      const url = firstLocalWebUrl(branch);
      if (url !== undefined) return { type: "local_web", url };
      return { type: "none" };
    }
    case "mobile_app":
      // The app runs on the phone; there is nothing to open on the computer.
      return { type: "none" };
  }
}

// ── The recipe ────────────────────────────────────────────────────────────────

/// Whether any of a branch's derived commands clones a repo — the same test
/// `recipeClonesARepo` makes over a recipe, applied to the branch so the recipe's
/// provenance fields (`canonicalRepo`/`pinnedCommit`) are attached only to a
/// source-clone install, never to a signed download.
function branchClonesARepo(branch: IrisGuideBranch): boolean {
  return branch.steps.some((step) => step.command?.includes("git clone") ?? false);
}

/// Derives an `InstallRecipe` from one branch of a guide, or reports that the
/// branch is unsupported / absent. Never returns a recipe for an `unsupported`
/// branch — that pair is an explanation, not an install.
export function recipeFromGuide(guide: IrisGuide, target: RecipeDerivationTarget): RecipeResolution {
  const requestedBranchKey = branchKeyForTarget(target);
  const branch = guide.branches.find((candidate) => branchKeyFor(candidate) === requestedBranchKey);
  if (branch === undefined) {
    return { kind: "noBranch", requestedBranchKey };
  }
  if (branch.unsupported !== undefined) {
    return { kind: "unsupported", branchKey: requestedBranchKey, unsupported: branch.unsupported };
  }

  const steps = branch.steps.map((step) => recipeStepFromGuideStep(step));
  const clonesARepo = branchClonesARepo(branch);
  const canonicalRepo =
    clonesARepo && guide.sourceOwner !== "" && guide.sourceRepo !== ""
      ? `${guide.sourceOwner}/${guide.sourceRepo}`
      : undefined;
  const pinnedCommit = clonesARepo ? guide.sourceCommit : undefined;
  const prerequisites = prerequisitesFromBranch(branch);

  const recipe: InstallRecipe = {
    slug: guide.appSlug,
    appName: guide.appName,
    output: outputForGuide(guide, branch),
    ...(canonicalRepo !== undefined ? { canonicalRepo } : {}),
    ...(pinnedCommit !== undefined ? { pinnedCommit } : {}),
    ...(prerequisites.length > 0 ? { prerequisites } : {}),
    steps,
  };

  return { kind: "recipe", recipe };
}
