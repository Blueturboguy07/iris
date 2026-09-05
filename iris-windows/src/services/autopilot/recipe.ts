//
// The install-recipe model — the Windows autopilot's answer to a guide branch.
//
// A recipe is an ordered list of steps, most of them a PowerShell/winget command
// Iris runs itself, a few of them things only the reader can do (sign in, grant a
// permission). Recipes are data, so the same runner drives every app and a new
// app is a new recipe rather than new code.
//
// This is a pure module (no Node/Electron/Windows APIs) so it runs in the vitest
// suite on any host. It mirrors the Rust reference core that was validated in the
// Tauri prototype, and aligns conceptually with the macOS `IrisGuideStep` model.
//

/// What a finished recipe leaves behind, and how Iris opens it — the Windows
/// answer to "once it's done the app should just open."
export type RecipeOutput =
  | { readonly type: "desktop_app"; readonly launch: LaunchTarget }
  | { readonly type: "local_web"; readonly url: string }
  | { readonly type: "credential" }
  | { readonly type: "none" };

/// How to open a desktop app once it is installed.
export type LaunchTarget =
  | { readonly via: "shell"; readonly command: string }
  | { readonly via: "path"; readonly path: string };

/// What a step is, which decides who does it.
export type StepKind =
  /// A command Iris runs itself.
  | "command"
  /// Open a URL or app; opening it is the whole step, so it needs no tap.
  | "open"
  /// The reader signs in. Iris opens the page and floats to it but never types
  /// the secret — the Windows answer to "ad-hoc sign in", done safely.
  | "sign_in"
  /// The reader grants a Windows permission or clears a UAC prompt.
  | "permission"
  /// Any other action only the reader can take.
  | "manual"
  /// Iris does nothing but WATCH: it blocks on this step's `watch` expectations
  /// (see below) until one of them verifies, then advances on its own. The
  /// Windows analog of a macOS guide's `verify` step, which the adaptive
  /// `WatchLoop` clears without being told. A `verify` step with no `watch`
  /// block, or one whose watch nothing can confirm, hands to the reader with the
  /// step's `verifierLabel` after a bounded wait.
  | "verify";

/// One thing the watch executor can confirm about the reader's machine without
/// the reader saying so, mirroring the macOS guide `Expectation` union and the
/// Windows guide JSON's `watch.expect[]`. Ordered cheapest-first by
/// `services/autopilot/watch.ts` before it evaluates them; the first that
/// verifies settles the step.
export type WatchExpectation =
  /// A tool the guide installs is now on PATH (`services/tool-versions.ts`).
  | { readonly type: "toolVersion"; readonly tool: string }
  /// A particular app is in the foreground. The `bundleId` is the identity the
  /// guide carries (a macOS bundle id or an `.exe` name); `watch.ts` maps it to
  /// a Windows executable name via its reviewed catalog table.
  | { readonly type: "foregroundApp"; readonly bundleId: string }
  /// The frontmost browser tab is showing this host (or a subdomain of it).
  | { readonly type: "urlHost"; readonly host: string }
  /// A UI Automation element with this name/role is present on the foreground
  /// window.
  | { readonly type: "axElement"; readonly roleLabel: string }
  /// A screenshot, judged by a model against this question. The most expensive
  /// rung, budgeted (≤ 8 per step, ≥ 10 s apart) and never taken for a
  /// `sensitive` watch.
  | { readonly type: "visual"; readonly prompt: string };

/// The `watch` block a step may carry: what Iris looks for to confirm the step
/// finished, and whether the step is `sensitive` (a secret is on screen), which
/// forbids any screenshot for the whole step. Mirrors the macOS `IrisStepWatch`
/// and the Windows guide JSON's `watch: { sensitive?, expect: Expectation[] }`.
export interface StepWatch {
  /// True when a secret (an API key, a password) is visible while this step is
  /// open. A sensitive step is NEVER captured for a `visual` check — it settles
  /// from the pixel-free side signals alone, or hands to the reader. Mirrors
  /// macOS's `theStepIsMarkedSensitive` suspension.
  readonly sensitive?: boolean;
  /// The expectations, any one of which verifying advances the step.
  readonly expect: readonly WatchExpectation[];
}

/// How Iris can confirm a reader step finished, so the install resumes on its
/// own instead of waiting for a tap.
export type StepCheck =
  | { readonly type: "tool_version"; readonly tool: string }
  | { readonly type: "process_running"; readonly executable: string }
  | { readonly type: "path_exists"; readonly path: string };

/// One step in a recipe.
export interface RecipeStep {
  readonly id: string;
  readonly title: string;
  readonly kind: StepKind;
  /// The PowerShell/winget line for a `command` step. Absent otherwise.
  readonly command?: string;
  /// The macOS/Linux (zsh) equivalent, used when Iris runs on a Mac for testing.
  /// Falls back to `command` when absent — most steps (git, npm) are identical.
  readonly posixCommand?: string;
  /// A `command` step that never exits on its own — a dev server that stays up
  /// (`pnpm dev`). Iris starts it and moves on instead of waiting for an exit
  /// that never comes. Mirrors macOS `holdsTheShellOpen`.
  readonly longRunning?: boolean;
  /// For a `longRunning` step, a substring of the server's output that means it
  /// is up (Vite's `localhost:5173`). Iris waits for it, then advances.
  readonly readyWhen?: string;
  /// The URL an `open`/`sign_in` step points the reader at.
  readonly href?: string;
  /// What to tell the reader when Iris hands them the step — the sentence the
  /// eye floats next to.
  readonly instruction?: string;
  /// How Iris can tell the step is done without being told. Absent means the
  /// step is finished the moment Iris performs it.
  readonly check?: StepCheck;
  /// What Iris watches for to confirm this step finished — polled by
  /// `services/autopilot/watch.ts`. A `verify` step blocks on it; a reader step
  /// (sign_in/permission/manual) that carries one is auto-advanced when the
  /// watch verifies instead of waiting for the reader. Absent keeps the old
  /// behaviour: nothing is watched and the step advances or hands over as before.
  readonly watch?: StepWatch;
  /// The line shown to the reader if a watched step's expectations never verify
  /// within the bounded wait and Iris has to hand it back — the Windows analog
  /// of the guide `Step.verifierLabel`. Falls back to a generic sentence when
  /// absent.
  readonly verifierLabel?: string;
  /// The folder this step's command runs in, stated by the recipe instead of
  /// inherited from a `cd` some earlier step left behind in the shell.
  ///
  /// A resumed install builds a brand-new `ShellSession`, which starts in the
  /// home folder, so a step written relative to an `enter-folder` step ran
  /// there instead — the same defect the macOS guides were backfilled to close
  /// (`IrisGuideStep.workingDirectory`). Absent keeps the old behaviour
  /// exactly: run wherever the shell already is, which is what every recipe
  /// written before this field relies on.
  readonly workingDirectory?: string;
  /// The macOS/Linux equivalent, for the same reason `posixCommand` exists: the
  /// two clone steps do not land in the same place on the two platforms. The
  /// Windows clone runs in `~` and produces `~/publikclip`; the posix one makes
  /// and enters `~/iris-apps` first, so the same folder is
  /// `~/iris-apps/publikclip`. Falls back to `workingDirectory` when absent.
  readonly posixWorkingDirectory?: string;
}

/// A full install recipe for one app.
export interface InstallRecipe {
  /// Matches the app's slug in the web catalog.
  readonly slug: string;
  readonly appName: string;
  /// What finishing the recipe produces, and how to open it.
  readonly output: RecipeOutput;
  /// `"owner/name"` of the canonical source repo this recipe builds from, when
  /// it builds from source — what maintain mode's fork backup forks, and the
  /// `canonicalRepo` half of an install-provenance record. Absent for a recipe
  /// that installs a signed download rather than cloning source. Mirrors the
  /// macOS guide's `sourceOwner`/`sourceRepo`, folded into one field because a
  /// recipe (unlike a guide) never shows the two apart.
  readonly canonicalRepo?: string;
  /// The exact source commit this recipe pins to — the base a maintain-mode
  /// patch diffs against until the patch queue advances it, the `pinnedCommit`
  /// half of an install-provenance record. Mirrors the macOS guide's
  /// `sourceCommit`. Absent when the recipe does not build from a pinned clone.
  readonly pinnedCommit?: string;
  readonly steps: readonly RecipeStep[];
}

/// Iris runs this step itself rather than handing it over.
export function isRunByIris(kind: StepKind): boolean {
  return kind === "command";
}

/// Opening it is the entire step, so the autopilot advances with no tap.
export function isDoneOnceOpened(kind: StepKind): boolean {
  return kind === "open";
}

/// Only the reader can finish it: float to it, instruct, and wait — never skip
/// it, because skipping is skipping the sign-in or the permission.
export function needsTheReader(kind: StepKind): boolean {
  return kind === "sign_in" || kind === "permission" || kind === "manual";
}

/// The step count the UI shows as the denominator ("3 of 8").
export function totalSteps(recipe: InstallRecipe): number {
  return recipe.steps.length;
}

/// The command to actually run for a step on this host. Windows uses `command`;
/// everywhere else prefers `posixCommand`, falling back to `command` — most steps
/// (git clone, npm ci) are identical across platforms.
export function commandForPlatform(step: RecipeStep, platform: NodeJS.Platform): string | undefined {
  return platform === "win32" ? step.command : step.posixCommand ?? step.command;
}

/// The folder to put the shell in before running this step on this host, or
/// undefined when the step declares none and should run wherever the shell
/// already is. Same Windows/posix split as `commandForPlatform`, and an empty
/// string is treated as "declares none" so a renderer that fills the field in
/// with `""` cannot turn into a `cd ` with no argument.
export function workingDirectoryForPlatform(
  step: RecipeStep,
  platform: NodeJS.Platform,
): string | undefined {
  const declared =
    platform === "win32"
      ? step.workingDirectory
      : step.posixWorkingDirectory ?? step.workingDirectory;
  return declared !== undefined && declared !== "" ? declared : undefined;
}

/// The first step whose command clones the repo. Every step from here on runs
/// somewhere the clone put on disk, so every one of them must say where — the
/// positional rule the web guides are held to (`checkGuideInvariants`), stated
/// once here so the recipe suite can hold the built-in recipes to the same bar.
/// -1 when the recipe clones nothing.
export function cloneStepIndex(recipe: InstallRecipe): number {
  return recipe.steps.findIndex(
    (step) =>
      (step.command?.includes("git clone") ?? false) ||
      (step.posixCommand?.includes("git clone") ?? false),
  );
}

/// Whether running this recipe clones a source repo — the same test macOS's
/// `recordInstallProvenance` makes (`steps contains a "git clone" command`) to
/// tell a guide-source build, which maintain mode MAY patch, from a signed
/// download, which it never may. Checks both the Windows and the posix command
/// of every step so the answer does not depend on which host the recipe is
/// being examined on.
export function recipeClonesARepo(recipe: InstallRecipe): boolean {
  return recipe.steps.some(
    (step) => (step.command?.includes("git clone") ?? false) || (step.posixCommand?.includes("git clone") ?? false)
  );
}
