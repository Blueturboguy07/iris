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
  /// The reader does something on a web page — click a button, copy a value.
  /// The Windows answer to a guide's `web` kind: a reader-handled gate that
  /// opens the page (`href`) and floats the eye to it.
  | "web"
  /// The reader moves a secret from where it was created into where it is used
  /// (a guide's `paste` kind). Reader-handled, and Iris never types the secret.
  | "paste"
  /// A step that confirms the install worked (a guide's `verify` kind). It
  /// carries the expectations the watch loop checks, but the autopilot runner
  /// treats it as self-completing — mirroring macOS, where a guide step with no
  /// command "succeeds" in the drive loop and the watch loop does the looking.
  | "verify"
  /// A step with nothing for Iris to run, open, or hand over — a guide's
  /// "open your shell" prose step. It succeeds the moment it is reached, so the
  /// install moves straight past it, mirroring macOS's nil-command → succeeded.
  | "noop";

/// How Iris can confirm a reader step finished, so the install resumes on its
/// own instead of waiting for a tap.
export type StepCheck =
  | { readonly type: "tool_version"; readonly tool: string }
  | { readonly type: "process_running"; readonly executable: string }
  | { readonly type: "path_exists"; readonly path: string };

/// What a `verify` step tells the watch loop to look for to decide the install
/// worked. This mirrors `IrisStepExpectation` on the wire (and the macOS
/// `IrisStepExpectation` enum) so a derived recipe carries the guide's own
/// completion signals through untouched for the watch-loop port to evaluate.
/// The autopilot runner does not read these — a `verify` step self-completes —
/// so an expectation this build cannot make sense of is simply carried, never
/// fatal.
export type StepExpectation =
  | { readonly type: "foregroundApp"; readonly bundleId: string }
  | { readonly type: "urlHost"; readonly host: string }
  | { readonly type: "toolVersion"; readonly tool: string }
  | { readonly type: "axElement"; readonly roleLabel: string }
  | { readonly type: "visual"; readonly prompt: string };

/// A tool an install needs before it can start, carried from a guide branch's
/// `setupSteps` so the setup-detour port can divert a reader into installing a
/// missing prerequisite instead of dropping them on step one of an install they
/// cannot begin. Mirrors the macOS Setup Recovery Detour's use of
/// `branch.setupSteps`. `tool` is the thing `ToolVersionService`/`tool-versions`
/// checks for; `href` is where the reader downloads it.
export interface RecipePrerequisite {
  readonly id: string;
  readonly title: string;
  /// The tool this prerequisite installs (`git`, `node`), when the setup step
  /// names one — the value the detour re-checks to know the tool arrived.
  readonly tool?: string;
  /// The download page the setup step points at, when it is a manual download.
  readonly href?: string;
  /// A command the setup step runs itself (`npm.cmd install -g pnpm`), when the
  /// prerequisite installs by command rather than by a manual download.
  readonly command?: string;
  /// The prose from the guide's setup step, so the detour can explain the tool.
  readonly body?: string;
}

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
  /// The guide step's prose body, carried verbatim so a derived recipe can show
  /// the same explanation the web guide does. Preserved for every step kind (the
  /// task requires ids/titles/bodies survive derivation); reader-handled steps
  /// also copy it into `instruction`.
  readonly body?: string;
  /// The guide step's verifier button label (a `verify` step's "Check it"),
  /// carried through so the watch-loop/UI ports can render the same control.
  readonly verifierLabel?: string;
  /// The completion signals a `verify` step declares, carried faithfully for the
  /// watch-loop port. Absent for every other kind. The runner never reads these.
  readonly verifyExpectations?: readonly StepExpectation[];
  /// How Iris can tell the step is done without being told. Absent means the
  /// step is finished the moment Iris performs it.
  readonly check?: StepCheck;
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
  /// The tools this install needs before it can start, derived from a guide
  /// branch's `setupSteps`. The setup-detour port reads these to divert a reader
  /// into installing a missing prerequisite. Absent for the hand-authored
  /// built-in recipes, whose tool checks are ordinary `command` steps instead.
  readonly prerequisites?: readonly RecipePrerequisite[];
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
/// it, because skipping is skipping the sign-in, the permission, the web action,
/// or the paste of a secret Iris deliberately never types.
export function needsTheReader(kind: StepKind): boolean {
  return (
    kind === "sign_in" ||
    kind === "permission" ||
    kind === "manual" ||
    kind === "web" ||
    kind === "paste"
  );
}

/// Iris neither runs a command, opens something, nor waits for the reader — the
/// step is finished the instant it is reached, so the install advances straight
/// past it. This is the Windows answer to macOS's "a guide step with no command
/// succeeds in the drive loop": a prose `noop` step, and a `verify` step whose
/// looking is the watch loop's job, not the command runner's. Kept a predicate
/// (not inlined in the runner) so the watch-loop port can change how a `verify`
/// step completes in one place without touching the runner's control flow.
export function advancesWithoutRunningAnything(kind: StepKind): boolean {
  return kind === "noop" || kind === "verify";
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
