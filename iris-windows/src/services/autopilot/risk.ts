//
// The gate every command passes before the autopilot shell will run it.
//
// TRUST BOUNDARY — read this. The rest of iris-windows holds a hard invariant
// (see tool-versions.ts): "no part of a command is ever built from guide text;
// there is no escape hatch." The autopilot deliberately relaxes that invariant —
// it runs commands that come from a recipe — so this module is the compensating
// control, and the relaxation is bounded three ways:
//
//   1. Provenance is the real boundary. Recipe commands come only from reviewed,
//      version-pinned recipe modules in this repo (shipped, not fetched as text
//      from an arbitrary guide). Model-proposed fix commands (a later increment)
//      are marked `model_proposed_fix` and gated harder.
//   2. This gate refuses outright the handful of commands no tap can make
//      informed (piping a download into a shell, wiping a disk), waves through
//      the ordinary, and pauses the rest for one explicit reader tap.
//   3. `ApprovedCommand` is the only value the shell will run, and it is minted
//      only by the two functions here — "run an unassessed command" cannot be
//      expressed elsewhere in the code.
//
// It is a guardrail against mistakes, not a defence against an adversary; regexes
// over command text are defeatable by construction, which is exactly why opacity
// itself trips the gate for untrusted (model) commands. Ported from the macOS
// `GuideAutopilotRiskAssessment.swift`, adapted for PowerShell/winget.
//

/// Where a command came from, which decides whether the opacity rules apply.
export type Provenance = "vetted_recipe" | "model_proposed_fix";

/// The verdict, in words a reader can act on.
export type Risk =
  | { readonly tier: "runs_without_asking" }
  | { readonly tier: "needs_a_confirm_tap"; readonly reason: string }
  | { readonly tier: "refused_outright"; readonly reason: string };

/// A command that has been through the gate. The shell runs these and nothing
/// else. The private brand makes it un-forgeable: only the two mint functions
/// below can produce one, so no caller can hand the shell a raw string.
declare const approvedBrand: unique symbol;
export interface ApprovedCommand {
  readonly text: string;
  readonly [approvedBrand]: true;
}

function mint(text: string): ApprovedCommand {
  return { text } as ApprovedCommand;
}

interface Rule {
  readonly pattern: RegExp;
  readonly reason: string;
}

function rule(source: string, reason: string): Rule {
  return { pattern: new RegExp(source, "i"), reason };
}

// The catastrophe floor: refused EVEN under the autonomy grant. Whole-disk /
// whole-profile destruction that no install ever needs — keeping it absolute is
// what lets "Let Iris take control" be safe to grant once. A hallucinated
// model-proposed fix that reaches for one is stopped here with no tap.
const CATASTROPHE_RULES: readonly Rule[] = [
  // Wipe a disk.
  rule(String.raw`\bformat-volume\b`, "This reformats a disk."),
  rule(String.raw`\bformat\s+[a-z]:`, "This reformats a disk."),
  rule(String.raw`\bdiskpart\b[^\n]*\bclean\b`, "This erases a disk with diskpart."),
  rule(String.raw`\bclear-disk\b`, "This erases a disk."),
  // Delete the drive root or the whole profile.
  rule(
    String.raw`\bremove-item\b[^\n]*-recurse\b[^\n]*(([a-z]:\\?|\$env:userprofile|\$home|\$env:systemroot)\s*(\n|$|;|,))`,
    "This deletes the root of a drive or the whole user profile.",
  ),
  rule(
    String.raw`\brm\b[^\n]*\s-[a-z]*(rf|fr)[a-z]*\s+(/|/\*|~|~/|\$home)\s*(\n|$|;|&)`,
    "This deletes the root of the disk or the whole home folder.",
  ),
  // Delete a core branch of the machine hive. `reg delete HKCU\...` is a
  // confirm-tier registry edit (see `CONFIRM_RULES`); this floor catches only
  // the deletion of `HKLM` itself or one of its top-level hives (SYSTEM,
  // SOFTWARE, …) — bricking Windows — which no install ever needs. A deeper
  // subkey delete (`reg delete HKLM\SOFTWARE\SomeApp`) is NOT a root and stays
  // at the confirm tier, because the trailing `\SomeApp` is not the `\s|$|/`
  // this requires right after the hive.
  rule(
    String.raw`\breg\s+delete\s+(hklm|hkey_local_machine)(\\(system|software|sam|security|hardware|components|bcd\d*))?(\s|$|/)`,
    "This deletes a core branch of the Windows registry.",
  ),
  // Rewrite the boot configuration. `bcdedit /enum` is read-only and stays at
  // the confirm tier; the destructive verbs here can leave Windows unbootable,
  // which no app install has any reason to do.
  rule(
    String.raw`\bbcdedit\b[^\n]*/(delete|deletevalue|import|set)\b`,
    "This changes how Windows boots.",
  ),
];

// Refused WITHOUT the grant, but run WITH it: download-and-run one-liners
// (`irm … | iex`, DownloadString + Invoke-Expression, `curl … | sh`) cannot be
// read before they run, so without the grant no tap can make them informed. With
// the grant they run — that shape is how half of all prerequisites install, and
// refusing it is the biggest reason a package install used to bounce the reader
// out to a web page.
const DOWNLOAD_AND_RUN_RULES: readonly Rule[] = [
  rule(
    String.raw`\b(irm|iwr|invoke-restmethod|invoke-webrequest)\b[^\n|]*\|[^\n]*\b(iex|invoke-expression)\b`,
    "This downloads a script and runs it without anyone reading it first.",
  ),
  rule(
    String.raw`\bdownloadstring\b[^\n]*\|\s*(iex|invoke-expression)\b`,
    "This downloads a script and runs it without anyone reading it first.",
  ),
  rule(
    String.raw`\b(curl|wget)\b[^\n|]*\|[^\n]*\b(sh|bash|zsh)\b`,
    "This downloads a script and runs it without anyone reading it first.",
  ),
];

// Refused for a MODEL-PROPOSED FIX even under the autonomy grant. A vetted,
// pinned recipe may download-and-run a known installer under the grant (that is
// how rustup and scoop install), but a fix an untrusted model wrote is never
// allowed to reach out and run code, or to hide what it runs inside an encoded
// blob — the two shapes an adversary-shaped hallucination would use. These are
// checked before the grant short-circuit, so the grant that a reader gives a
// vetted install never launders a model's opaque command through.
const MODEL_HARD_REFUSAL_RULES: readonly Rule[] = [
  ...DOWNLOAD_AND_RUN_RULES,
  rule(
    String.raw`\bdownloadstring\b`,
    "A fix should never download code and run it.",
  ),
  rule(
    String.raw`-encodedcommand\b`,
    "This hides what it runs inside an encoded blob, so its effect can't be read.",
  ),
];

// Needs a confirm tap: administrator-adjacent, destructive, or writes outside
// the reader's own folders.
const CONFIRM_RULES: readonly Rule[] = [
  // Elevation.
  rule(String.raw`\bsudo\b`, "This runs as administrator."),
  rule(String.raw`\b-verb\s+runas\b`, "This relaunches a program as administrator."),
  rule(String.raw`\brunas\b`, "This runs a program as another user."),
  rule(String.raw`\bset-executionpolicy\b`, "This changes what scripts Windows will run."),
  rule(String.raw`\b(iex|invoke-expression)\b`, "This runs text as a program."),
  // Destructive.
  rule(String.raw`\bremove-item\b[^\n]*-recurse\b`, "This deletes a folder and everything in it."),
  rule(String.raw`\brm\s+-rf\b`, "This force-deletes a folder and everything in it."),
  rule(String.raw`\brmdir\b[^\n]*/s\b`, "This deletes a folder and everything in it."),
  rule(String.raw`\bdel\b[^\n]*/s\b`, "This deletes files recursively."),
  rule(String.raw`\bstop-process\b`, "This force-quits a running program."),
  rule(String.raw`\btaskkill\b[^\n]*/f\b`, "This force-quits a running program."),
  rule(String.raw`\bgit\s+reset\s+--hard\b`, "This throws away uncommitted changes."),
  rule(String.raw`\bgit\s+clean\s+-[a-z]*f`, "This deletes untracked files."),
  rule(String.raw`\bgit\s+push\b[^\n]*(--force\b|\s-f\b)`, "This overwrites remote history."),
  rule(String.raw`\b(winget|choco|scoop)\s+uninstall\b`, "This uninstalls software."),
  rule(
    String.raw`\bdocker\s+(rm|rmi|volume\s+rm|system\s+prune)\b`,
    "This deletes Docker containers, images, or volumes.",
  ),
  // System and account changes.
  rule(String.raw`\breg\s+(add|delete)\b`, "This edits the Windows registry."),
  rule(String.raw`\bnew-localuser\b`, "This creates a Windows user account."),
  rule(String.raw`\bnet\s+user\b`, "This changes a Windows user account."),
  rule(String.raw`\bnet\s+localgroup\b`, "This changes a Windows user group."),
  rule(String.raw`\b(new-service|sc\.exe|sc\s+create)\b`, "This installs a system-level background service."),
  rule(String.raw`\bbcdedit\b`, "This changes how Windows boots."),
  rule(String.raw`\bnetsh\b`, "This changes network settings."),
  // Writes into a system folder.
  rule(
    String.raw`\b(copy-item|move-item|out-file|set-content|new-item)\b[^\n]*\s(c:\\windows|c:\\program files|\$env:systemroot)`,
    "This changes files in a system folder.",
  ),
  rule(String.raw`>>?\s*/(usr|etc|bin|sbin)/`, "This writes into a system folder."),
];

// Opacity: a command whose effect cannot be read from its text. Applied only to
// model-proposed fixes — a reviewed recipe is trusted to use substitution the
// way real installers do. `$(( ))` arithmetic is exempt (it computes a number).
const OPACITY_RULES: readonly Rule[] = [
  rule(
    String.raw`\$\((?!\()`,
    "Part of this command is computed when it runs, so its effect can't be read from its text.",
  ),
  rule(
    "`",
    "Part of this command is computed when it runs, so its effect can't be read from its text.",
  ),
  rule(String.raw`\beval\b`, "This runs text as a program."),
  rule(String.raw`\b[&.]\s*\{`, "This runs a computed script block."),
];

function firstMatch(rules: readonly Rule[], command: string): string | undefined {
  for (const { pattern, reason } of rules) {
    if (pattern.test(command)) {
      return reason;
    }
  }
  return undefined;
}

// ── The folder the command will run in ──────────────────────────────────────
//
// Every rule above is a pattern over command TEXT, and the text of a command
// does not say where it runs. Once a guide step can declare its own working
// directory that becomes a real hole: `Remove-Item -Recurse -Force .` is a
// tidy-up in the app folder and a catastrophe in `C:\Windows`, and the two are
// spelled identically. So the gate also judges the folder itself — refused even
// under the autonomy grant, the same as the catastrophe floor, because running
// ANYTHING with the current directory set to a system folder or a drive root is
// a class of danger the command text alone can't show. Mirrors the
// system-folder / `..`-escape refusal in macOS `GuideAutopilotRunner.moveInto`.

/// Rewrites a folder to a single lower-cased, backslash-separated form with the
/// environment references a system folder is usually spelled with expanded, so
/// one comparison catches `C:\Windows`, `%SystemRoot%`, and `$env:windir` alike.
function normalizeWindowsFolder(folder: string): string {
  return folder
    .trim()
    .replace(/\//g, "\\")
    .replace(/\\+$/g, "")
    .toLowerCase()
    .replace(/%systemroot%|%windir%|\$env:systemroot|\$env:windir/g, "c:\\windows")
    .replace(/%programfiles\(x86\)%|\$env:programfiles\(x86\)/g, "c:\\program files (x86)")
    .replace(/%programfiles%|\$env:programfiles/g, "c:\\program files")
    .replace(/%systemdrive%|\$env:systemdrive/g, "c:");
}

const SYSTEM_FOLDER_PREFIXES = ["c:\\windows", "c:\\program files (x86)", "c:\\program files"];

/// Whether a normalized path is a Windows system folder (or below one). A bare
/// drive root is handled separately by `looksLikeADriveRoot`.
function looksLikeASystemFolder(normalizedPath: string): boolean {
  return SYSTEM_FOLDER_PREFIXES.some(
    (prefix) => normalizedPath === prefix || normalizedPath.startsWith(`${prefix}\\`),
  );
}

/// Whether a normalized path is the very root of a drive (`c:` or `c:\`, which
/// normalizes to `c:`). Nothing an install writes belongs at a drive root.
function looksLikeADriveRoot(normalizedPath: string): boolean {
  return /^[a-z]:$/.test(normalizedPath);
}

/// The reason a step's declared working directory is refused outright, or
/// undefined when the folder is a fine place to run. Absolute: honored even
/// under the autonomy grant.
export function forbiddenWorkingDirectory(workingDirectory: string): string | undefined {
  const folder = workingDirectory.trim();
  if (folder === "") return undefined;
  // A relative path that climbs out of the guide's own folder via `..`. The
  // shell would resolve it against wherever it happens to be sitting, which is
  // exactly the folder confusion this whole section closes.
  if (folder.split(/[\\/]/).includes("..")) {
    return "This step would run in a folder reached by climbing out of the install folder.";
  }
  const normalized = normalizeWindowsFolder(folder);
  if (looksLikeADriveRoot(normalized)) {
    return "This step would run at the very root of a drive.";
  }
  if (looksLikeASystemFolder(normalized)) {
    return "This step would run inside a Windows system folder.";
  }
  return undefined;
}

/// Whether a folder is one this code will resolve relative command paths
/// against: a drive-rooted or `~`-rooted path with nothing in it a shell would
/// expand. A `$env:`-rooted folder is deliberately NOT resolved (the runner's
/// `isAPlainFolder` refuses it as a working directory anyway), matching the
/// macOS resolver, which only resolves against `~`- or `/`-rooted folders.
function isAResolvableFolder(folder: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(folder) || folder.startsWith("~");
}

/// Splits a drive- or `~`-rooted folder into its path components, keeping the
/// drive (`c:`) or `~` as the first, un-poppable component.
function folderComponents(folder: string): string[] {
  return normalizeWindowsFolder(folder).split(/[\\/]/).filter((part) => part.length > 0);
}

/// Resolves one relative path token against a folder, collapsing `.` and `..`.
/// Reports whether a `..` tried to climb past the drive/home root — a token that
/// escapes the folder tree entirely, which is refused regardless of where it
/// lands.
function resolveRelativePath(
  token: string,
  folder: string,
): { readonly resolved: string; readonly escaped: boolean } {
  const components = folderComponents(folder);
  let escaped = false;
  for (const piece of token.split(/[\\/]/)) {
    if (piece === "" || piece === ".") continue;
    if (piece === "..") {
      // Component 0 is the drive or `~`; popping it would climb off the tree.
      if (components.length > 1) {
        components.pop();
      } else {
        escaped = true;
      }
      continue;
    }
    components.push(piece.toLowerCase());
  }
  const resolved = components.join("\\");
  return { resolved, escaped };
}

/// Whether a token is a plain relative path we should resolve — not a flag
/// (`-x`, `/f`), not an already-rooted path (`c:\…`, `\…`, `~…`), and not
/// anything the shell would compute (`$…`, `%…`). Quotes and other punctuation
/// mean it is not a plain path and it is left alone (opacity rules already
/// question computed text).
function looksLikeARelativePathToken(token: string): boolean {
  if (token.length === 0) return false;
  const first = token[0]!;
  if (first === "-" || first === "/" || first === "\\" || first === "~" || first === "$" || first === "%") {
    return false;
  }
  if (/^[A-Za-z]:/.test(token)) return false; // drive-rooted
  return /^[A-Za-z0-9._\\/@+-]+$/.test(token);
}

/// The reason a relative path in the command climbs out of the guide's folder
/// into a place nothing should be written — a drive root or a system folder —
/// or undefined when nothing in it does. Only tokens that actually contain a
/// `..` are considered, so an ordinary `npm ci` in an ordinary folder pays
/// nothing and can never be refused by mistake. Absolute: honored even under
/// the grant, because a `..`-walk into `C:\Windows\System32` is the declared-
/// folder version of the catastrophe floor.
export function escapesIntoAForbiddenPlace(
  command: string,
  workingDirectory: string,
): string | undefined {
  if (!isAResolvableFolder(workingDirectory)) return undefined;
  for (const token of command.split(/\s+/)) {
    if (!token.includes("..")) continue;
    if (!looksLikeARelativePathToken(token)) continue;
    const { resolved, escaped } = resolveRelativePath(token, workingDirectory);
    if (escaped || looksLikeADriveRoot(resolved) || looksLikeASystemFolder(resolved)) {
      return "This reaches out of the install folder into a system location.";
    }
  }
  return undefined;
}

/// The inputs to the gate, when a caller has more than a provenance to give —
/// notably the folder the command will run in. `autonomyGranted` defaults to
/// false and `workingDirectory` to none, so an options object with just a
/// provenance behaves exactly like the positional form.
export interface AssessOptions {
  readonly provenance: Provenance;
  readonly autonomyGranted?: boolean;
  readonly workingDirectory?: string;
}

interface NormalizedOptions {
  readonly provenance: Provenance;
  readonly autonomyGranted: boolean;
  readonly workingDirectory: string | undefined;
}

/// Accepts either the original positional form (`provenance`, `autonomyGranted`)
/// or the richer options object, so every existing caller and test keeps
/// compiling and the folder-aware callers can pass a working directory.
function normalizeAssessArguments(
  provenanceOrOptions: Provenance | AssessOptions,
  autonomyGranted: boolean,
): NormalizedOptions {
  if (typeof provenanceOrOptions === "string") {
    return { provenance: provenanceOrOptions, autonomyGranted, workingDirectory: undefined };
  }
  return {
    provenance: provenanceOrOptions.provenance,
    autonomyGranted: provenanceOrOptions.autonomyGranted ?? false,
    workingDirectory: provenanceOrOptions.workingDirectory,
  };
}

/// The verdict for a command of a given provenance. When `autonomyGranted` is
/// true (the reader granted "Let Iris take control" once), everything that is
/// not refused-even-under-the-grant runs without asking — a per-command tap on a
/// vetted install is exactly the friction the grant removes. When it is false
/// (the default, and every existing caller/test), the original three-tier
/// behavior is unchanged.
///
/// Passing a `workingDirectory` (via the options form) also judges the folder
/// the command will run in: a system folder, a drive root, or a `..`-escape out
/// of the guide's own folder is refused outright, even under the grant — the
/// command text alone cannot show where it runs, so the folder is judged
/// separately. Mirrors macOS `GuideAutopilotRiskAssessment.assess(_:inWorkingDirectory:)`.
export function assess(command: string, provenance: Provenance, autonomyGranted?: boolean): Risk;
export function assess(command: string, options: AssessOptions): Risk;
export function assess(
  command: string,
  provenanceOrOptions: Provenance | AssessOptions,
  autonomyGranted = false,
): Risk {
  const { provenance, autonomyGranted: granted, workingDirectory } = normalizeAssessArguments(
    provenanceOrOptions,
    autonomyGranted,
  );

  // The catastrophe floor is absolute — refused even under the grant.
  const catastrophe = firstMatch(CATASTROPHE_RULES, command);
  if (catastrophe !== undefined) {
    return { tier: "refused_outright", reason: catastrophe };
  }

  // The folder the command will run in — also absolute, for the same reason the
  // floor is: no consent makes running in `C:\Windows`, or a `..`-walk into it,
  // safe. Judged before the grant can wave anything through.
  if (workingDirectory !== undefined) {
    const forbiddenFolder = forbiddenWorkingDirectory(workingDirectory);
    if (forbiddenFolder !== undefined) {
      return { tier: "refused_outright", reason: forbiddenFolder };
    }
    const escape = escapesIntoAForbiddenPlace(command, workingDirectory);
    if (escape !== undefined) {
      return { tier: "refused_outright", reason: escape };
    }
  }

  // A model-proposed fix is judged for opacity BEFORE the grant short-circuit,
  // because the grant a reader gives a vetted install must never launder an
  // untrusted model's opaque or download-and-run command. Download-and-run and
  // encoded blobs are refused outright even under the grant; the softer opacity
  // shapes (`$(…)`, backticks) pause for a tap.
  if (provenance === "model_proposed_fix") {
    const hardRefusal = firstMatch(MODEL_HARD_REFUSAL_RULES, command);
    if (hardRefusal !== undefined) {
      return { tier: "refused_outright", reason: hardRefusal };
    }
    const opaque = firstMatch(OPACITY_RULES, command);
    if (opaque !== undefined) {
      return { tier: "needs_a_confirm_tap", reason: opaque };
    }
  }

  if (granted) {
    return { tier: "runs_without_asking" };
  }

  const downloadAndRun = firstMatch(DOWNLOAD_AND_RUN_RULES, command);
  if (downloadAndRun !== undefined) {
    return { tier: "refused_outright", reason: downloadAndRun };
  }
  const confirm = firstMatch(CONFIRM_RULES, command);
  if (confirm !== undefined) {
    return { tier: "needs_a_confirm_tap", reason: confirm };
  }
  return { tier: "runs_without_asking" };
}

/// Approves a command the gate waves through. Undefined for anything that needs
/// a tap or is refused — callers surface those, never force them through. Honors
/// the same autonomy grant and working directory `assess` does.
export function approve(command: string, provenance: Provenance, autonomyGranted?: boolean): ApprovedCommand | undefined;
export function approve(command: string, options: AssessOptions): ApprovedCommand | undefined;
export function approve(
  command: string,
  provenanceOrOptions: Provenance | AssessOptions,
  autonomyGranted = false,
): ApprovedCommand | undefined {
  const verdict =
    typeof provenanceOrOptions === "string"
      ? assess(command, provenanceOrOptions, autonomyGranted)
      : assess(command, provenanceOrOptions);
  return verdict.tier === "runs_without_asking" ? mint(command) : undefined;
}

/// Approves a confirm-tier command after the reader's explicit tap. Refused-tier
/// commands stay refused — no tap reaches them. The folder matters here too: the
/// tap was asked for on the command as it will run, so this must not re-assess
/// it more leniently than the ask did.
export function approveAfterAReaderTap(command: string, provenance: Provenance, autonomyGranted?: boolean): ApprovedCommand | undefined;
export function approveAfterAReaderTap(command: string, options: AssessOptions): ApprovedCommand | undefined;
export function approveAfterAReaderTap(
  command: string,
  provenanceOrOptions: Provenance | AssessOptions,
  autonomyGranted = false,
): ApprovedCommand | undefined {
  const tier = (typeof provenanceOrOptions === "string"
    ? assess(command, provenanceOrOptions, autonomyGranted)
    : assess(command, provenanceOrOptions)
  ).tier;
  return tier === "runs_without_asking" || tier === "needs_a_confirm_tap" ? mint(command) : undefined;
}
