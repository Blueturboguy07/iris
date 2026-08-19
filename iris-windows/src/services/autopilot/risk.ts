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

/// The verdict for a command of a given provenance. When `autonomyGranted` is
/// true (the reader granted "Let Iris take control" once), everything that is
/// not in the catastrophe floor runs without asking — a per-command tap on a
/// vetted install is exactly the friction the grant removes. When it is false
/// (the default, and every existing caller/test), the original three-tier
/// behavior is unchanged.
export function assess(command: string, provenance: Provenance, autonomyGranted = false): Risk {
  // The catastrophe floor is absolute — refused even under the grant.
  const catastrophe = firstMatch(CATASTROPHE_RULES, command);
  if (catastrophe !== undefined) {
    return { tier: "refused_outright", reason: catastrophe };
  }

  if (autonomyGranted) {
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
  if (provenance === "model_proposed_fix") {
    const opaque = firstMatch(OPACITY_RULES, command);
    if (opaque !== undefined) {
      return { tier: "needs_a_confirm_tap", reason: opaque };
    }
  }
  return { tier: "runs_without_asking" };
}

/// Approves a command the gate waves through. Undefined for anything that needs
/// a tap or is refused — callers surface those, never force them through. Honors
/// the same autonomy grant `assess` does.
export function approve(
  command: string,
  provenance: Provenance,
  autonomyGranted = false,
): ApprovedCommand | undefined {
  return assess(command, provenance, autonomyGranted).tier === "runs_without_asking" ? mint(command) : undefined;
}

/// Approves a confirm-tier command after the reader's explicit tap. Refused-tier
/// commands stay refused — no tap reaches them.
export function approveAfterAReaderTap(
  command: string,
  provenance: Provenance,
  autonomyGranted = false,
): ApprovedCommand | undefined {
  const tier = assess(command, provenance, autonomyGranted).tier;
  return tier === "runs_without_asking" || tier === "needs_a_confirm_tap" ? mint(command) : undefined;
}
