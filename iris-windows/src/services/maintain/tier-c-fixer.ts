/**
 * tier-c-fixer.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/MaintainTierCFixer.swift`.
 *
 * The last rung of the fix ladder: no pooled recipe fit (Tier A), no stale
 * diff to re-anchor (Tier B), the user confirmed the bug, and they brought
 * their own model access. A bounded, mini-swe-agent-shaped ReAct loop derives
 * a fix from scratch, then it faces the SAME verification gate every other
 * fix does (`verification-harness.ts`) — a novel fix earns no special trust
 * for being clever.
 *
 * Deliberately small and deliberately caged, unchanged from Swift:
 *   - BYO only (Anthropic or OpenAI, the user's own key — see
 *     `model-provider.ts`). The funded proxy structurally cannot run this
 *     (ratified D4/D5), and its budget could not sustain it — Agentless-shaped
 *     novel fixes still cost roughly 15x a replay.
 *   - A hard step cap (`MAXIMUM_LOOP_STEPS`). An agent that has not found it
 *     in a dozen jailed commands is not about to.
 *   - EVERY command runs through `sandbox.ts`'s Windows Job Object jail —
 *     never the plain `runner`. See that file's header for exactly what
 *     containment it does and does not provide; this loop never runs a
 *     model-authored command unjailed, full stop.
 *   - `.git` is stripped before the loop and restored after, so a clone that
 *     already contains the upstream fix cannot be mined for the answer
 *     (Cursor measured that at 9% of an agent's "solutions").
 *   - Text ReAct, no tool-calling API: the model replies with ONE fenced
 *     command or `DONE`. Simple to cap, simple to parse, provider-portable —
 *     matches `MaintainModelProviding`'s one-turn-in-one-turn-out shape.
 *
 * WINDOWS ADAPTATION (behavior parity, not literal translation, per the
 * porting ground rules): Swift's system prompt asks the model for a
 * ` ```bash ` fenced block because the jail runs it through `/bin/zsh -c`.
 * This app's jail (`sandbox.ts`) runs everything through `powershell.exe`, so
 * the system prompt below asks for PowerShell, and `extractBashCommand`
 * (kept under that name — see the porting spec's module table — but widened
 * to accept a `powershell`/`ps1` fence first) still parses whatever the model
 * actually sends, in case habit produces a `bash` fence anyway.
 *
 * COMMAND PROVENANCE — same trust boundary `autopilot/risk.ts`'s header
 * documents for a different case, worth restating here: every command this
 * loop runs is MODEL-PROPOSED, reasoning over the user's own repo — the
 * weakest provenance this app ever executes. It NEVER passes through
 * `risk.ts`'s `ApprovedCommand` gate (that gate exists for
 * recipe/guide-sourced text, per the porting spec's decision 3); the
 * compensating control here is the sandbox, not a regex allowlist. Do not
 * add a code path that runs an unjailed model-authored command from this
 * file.
 */

import * as os from "node:os";
import * as path from "node:path";
import type { BreakAppStack } from "./break-signature";
import { defaultVerificationCommandsForStack } from "./incoming-fix-reviewer";
import { tryRun } from "./maintain-shell-runner";
import type { MaintainShellRunner } from "./maintain-shell-runner";
import type { MaintainChatTurn, MaintainModelProviding } from "./model-provider";
import { WindowsJobObjectSandbox } from "./sandbox";
import { maintainTrace } from "./trace";
import { earnsCleanApply, verifyAppliedPatch } from "./verification-harness";
import type { VerificationCommands } from "./verification-harness";

// ---------------------------------------------------------------------------
// Small local helpers — duplicated rather than imported, matching
// `replay-engine.ts`'s and `github-fork-service.ts`'s own local copies (see
// their footers): `services/maintain/` files each carry their own tiny
// escaping/date helper rather than depending on `main/powershell-session.ts`,
// which pulls in `child_process` at module scope and which `services/` must
// never import.
// ---------------------------------------------------------------------------

/** Quotes a value as a PowerShell single-quoted string literal (doubling
 *  embedded quotes) — same escaping as every other `services/maintain/`
 *  file's local copy. */
function powerShellSingleQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/** UTC `yyyyMMdd`, matching `replay-engine.ts`'s local `compactDateStamp`
 *  (itself matching Swift's, also UTC) — kept as its own local copy for the
 *  same reason: two independently portable pieces of the same fan-out, not
 *  shared wire vocabulary worth a shared module over. */
function compactDateStamp(now: Date = new Date()): string {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  const day = String(now.getUTCDate()).padStart(2, "0");
  return `${year}${month}${day}`;
}

// ---------------------------------------------------------------------------
// Prompt and fence parsing
// ---------------------------------------------------------------------------

const SYSTEM_PROMPT = [
  "You are fixing a bug in a local checkout of an open-source app on Windows.",
  "You work in a sandbox: writes are confined by convention to this repository,",
  "there is NO network — so you cannot fetch anything or run a build that",
  "downloads dependencies — and the sandboxed process runs with a",
  "privilege-stripped copy of the calling account's token. Explore and edit",
  "only.",
  "",
  "Each turn, reply with EXACTLY ONE command in a ```powershell fenced block,",
  "and nothing else. Read files, search (Select-String), and edit in place",
  "(Set-Content, or a here-string). Make the SMALLEST change that fixes the",
  "reported problem — do not refactor, do not touch unrelated files, do not",
  "weaken or delete tests. When you believe the bug is fixed, reply with DONE",
  "on its own line and nothing else. A verification build and the full test",
  "suite run automatically after you say DONE; you do not run them yourself.",
].join("\n");

function openingMessage(appSlug: string, crashEvidence: string): string {
  return [
    `App: ${appSlug}. It failed with this evidence (a crash report tail,`,
    "already scrubbed of personal data):",
    "",
    crashEvidence.slice(0, 3000),
    "",
    "Find the cause in the code and fix it. Start by locating the relevant",
    "source.",
  ].join("\n");
}

const DONE_LINE_PATTERN = /^\s*DONE\s*$/m;

/** Pulls the one fenced command out of a model reply, or `undefined` when
 *  the reply carries none (a malformed turn, re-prompted rather than
 *  treated as a step-consuming failure of the whole attempt — matches
 *  Swift's `extractBashCommand` exactly, including that a malformed reply
 *  still counts against `MAXIMUM_LOOP_STEPS`, since it is still one full
 *  round trip to the model).
 *
 *  Kept under its Swift name per the porting spec's module table, widened to
 *  look for a `powershell`/`ps1` fence FIRST — see the module header's
 *  Windows-adaptation note — before falling back to `bash`/`sh`/a bare fence,
 *  so a model that reverts to habit is still parsed correctly. */
export function extractBashCommand(reply: string): string | undefined {
  const fenceOpeners = ["```powershell", "```ps1", "```bash", "```sh", "```"];
  let fenceStart = -1;
  let openerLength = 0;
  for (const opener of fenceOpeners) {
    const index = reply.indexOf(opener);
    if (index !== -1 && (fenceStart === -1 || index < fenceStart)) {
      fenceStart = index;
      openerLength = opener.length;
    }
  }
  if (fenceStart === -1) {
    return undefined;
  }
  const afterFence = reply.slice(fenceStart + openerLength);
  const fenceEnd = afterFence.indexOf("```");
  if (fenceEnd === -1) {
    return undefined;
  }
  const body = afterFence.slice(0, fenceEnd).trim();
  return body.length === 0 ? undefined : body;
}

// ---------------------------------------------------------------------------
// MaintainTierCFixer
// ---------------------------------------------------------------------------

/** What one `attemptFix` call produced — mirrors Swift's
 *  `MaintainTierCResult` enum one-for-one in meaning, a discriminated union
 *  in TS-idiomatic shape per the porting spec's conventions. */
export type MaintainTierCResult =
  | { readonly type: "fixedAndVerified"; readonly branchName: string; readonly wasNovel: boolean }
  | { readonly type: "couldNotFix"; readonly reason: string }
  | { readonly type: "notEligible"; readonly reason: string };

export interface MaintainTierCFixerOptions {
  readonly provider: MaintainModelProviding;
  /** Builds a shell runner rooted at the clone path, or `undefined` when the
   *  path is not usable — the same shape `incoming-fix-reviewer.ts`'s
   *  `createShellRunner` uses. */
  readonly createShellRunner: (repoRootPath: string) => MaintainShellRunner | undefined;
  /** Defaults to a real `WindowsJobObjectSandbox`; overridable for
   *  `tests/maintain-tier-c-fixer.test.ts` (e.g. to force `isAvailable()`
   *  down the `win32` branch on the Mac dev machine). */
  readonly sandbox?: WindowsJobObjectSandbox;
  readonly verificationCommandsForStack?: (appStack: BreakAppStack, repoRootPath: string) => VerificationCommands;
  readonly tempDirectoryPath?: string;
}

export interface MaintainTierCAttemptFixOptions {
  readonly clonePath: string;
  readonly appSlug: string;
  readonly appStack: BreakAppStack;
  readonly signatureId: string;
  readonly crashEvidence: string;
  /** A testability seam: the adversarial harness supplies its own
   *  build/test vocabulary so it can prove the loop end-to-end without a
   *  real cargo/npm project. Production always uses
   *  `verificationCommandsForStack`. */
  readonly verificationCommandsOverride?: VerificationCommands;
}

export class MaintainTierCFixer {
  static readonly MAXIMUM_LOOP_STEPS = 12;
  static readonly MAXIMUM_OUTPUT_TOKENS_PER_STEP = 1200;

  private readonly provider: MaintainModelProviding;
  private readonly sandbox: WindowsJobObjectSandbox;
  private readonly createShellRunner: (repoRootPath: string) => MaintainShellRunner | undefined;
  private readonly verificationCommandsForStack: (
    appStack: BreakAppStack,
    repoRootPath: string
  ) => VerificationCommands;
  private readonly tempDirectoryPath: string;

  constructor(options: MaintainTierCFixerOptions) {
    this.provider = options.provider;
    this.createShellRunner = options.createShellRunner;
    this.sandbox = options.sandbox ?? new WindowsJobObjectSandbox();
    this.verificationCommandsForStack = options.verificationCommandsForStack ?? defaultVerificationCommandsForStack;
    this.tempDirectoryPath = options.tempDirectoryPath ?? os.tmpdir();
  }

  /**
   * Attempts a novel fix in a source-clone repo. `crashEvidence` is the
   * frozen, scrubbed artifact tail — the model's only description of the
   * bug, hashed and timestamped by the caller before this runs.
   * `verificationCommandsOverride` is the same testability seam Swift's
   * `attemptFix` exposes: production always uses `verificationCommandsForStack`,
   * an adversarial/integration harness can supply its own vocabulary so the
   * loop is provable end to end without a real cargo/npm project.
   */
  async attemptFix(options: MaintainTierCAttemptFixOptions): Promise<MaintainTierCResult> {
    const { clonePath, appSlug, appStack, signatureId, crashEvidence, verificationCommandsOverride } = options;

    const availability = this.sandbox.isAvailable();
    if (!availability.available) {
      return { type: "notEligible", reason: availability.reason ?? "the sandbox is unavailable on this machine" };
    }

    const runner = this.createShellRunner(clonePath);
    if (runner === undefined) {
      return { type: "notEligible", reason: "the clone path is not usable" };
    }

    // Strip .git so the agent cannot read history to retrieve the fix, and
    // so its edits don't accidentally land in a commit mid-loop. Restored on
    // every exit path below via `restoreGit()`.
    const gitBackupPath = path.join(this.tempDirectoryPath, `iris-git-backup-${signatureId.slice(0, 8)}`);
    await tryRun(runner, `Remove-Item -LiteralPath ${powerShellSingleQuote(gitBackupPath)} -Recurse -Force -ErrorAction SilentlyContinue`, {
      deadlineMs: 60_000,
    });
    await tryRun(runner, `Move-Item -LiteralPath '.git' -Destination ${powerShellSingleQuote(gitBackupPath)} -Force -ErrorAction SilentlyContinue`, {
      deadlineMs: 60_000,
    });
    const restoreGit = async (): Promise<void> => {
      await tryRun(runner, "Remove-Item -LiteralPath '.git' -Recurse -Force -ErrorAction SilentlyContinue", {
        deadlineMs: 60_000,
      });
      await tryRun(runner, `Move-Item -LiteralPath ${powerShellSingleQuote(gitBackupPath)} -Destination '.git' -Force -ErrorAction SilentlyContinue`, {
        deadlineMs: 60_000,
      });
    };

    const conversation: MaintainChatTurn[] = [{ role: "user", text: openingMessage(appSlug, crashEvidence) }];
    let declaredDone = false;

    for (let step = 1; step <= MaintainTierCFixer.MAXIMUM_LOOP_STEPS; step += 1) {
      let reply: string;
      try {
        reply = await this.provider.respond({
          systemPrompt: SYSTEM_PROMPT,
          conversation,
          maximumOutputTokens: MaintainTierCFixer.MAXIMUM_OUTPUT_TOKENS_PER_STEP,
        });
      } catch (error) {
        await restoreGit();
        return {
          type: "couldNotFix",
          reason: `model call failed: ${error instanceof Error ? error.message : String(error)}`,
        };
      }
      conversation.push({ role: "assistant", text: reply });

      if (DONE_LINE_PATTERN.test(reply)) {
        declaredDone = true;
        break;
      }

      const command = extractBashCommand(reply);
      if (command === undefined) {
        conversation.push({
          role: "user",
          text: "Reply with exactly one ```powershell fenced command, or DONE on its own line.",
        });
        continue;
      }

      const jailed = this.sandbox.jailedInvocation({ command, repoRootPath: clonePath, runner });
      if (jailed === undefined) {
        await restoreGit();
        return { type: "couldNotFix", reason: "could not build the sandbox for a command" };
      }
      let result;
      try {
        result = await tryRun(runner, jailed.invocation, { deadlineMs: 120_000 });
      } finally {
        await jailed.cleanup();
      }
      const output = (result?.outputTail ?? "(no output)").slice(-4000);
      maintainTrace(`tier-c step ${step} ran a jailed command, exit=${result?.exitCode ?? -1}`);
      conversation.push({
        role: "user",
        text: `Command exit ${result?.exitCode ?? -1}. Output:\n${output}\n\nNext command, or DONE.`,
      });
    }

    // The loop made its edits with no network; verification (build+suite)
    // needs the network and runs outside the jail, through the ordinary
    // runner. `.git` is back, so a passing tree can be committed.
    await restoreGit();

    if (!declaredDone) {
      await tryRun(runner, "git checkout -- .", { deadlineMs: 120_000 });
      await tryRun(runner, "git clean -fd --quiet", { deadlineMs: 120_000 });
      return { type: "couldNotFix", reason: "ran out of steps without a fix" };
    }

    // Did the agent actually change anything?
    const dirty = await tryRun(runner, "git status --porcelain", { deadlineMs: 30_000 });
    if ((dirty?.outputTail ?? "").trim().length === 0) {
      return { type: "couldNotFix", reason: "the agent declared done but changed nothing" };
    }

    const commands = verificationCommandsOverride ?? this.verificationCommandsForStack(appStack, clonePath);
    const verification = await verifyAppliedPatch(runner, commands, undefined);
    if (!earnsCleanApply(verification)) {
      await tryRun(runner, "git checkout -- .", { deadlineMs: 120_000 });
      await tryRun(runner, "git clean -fd --quiet", { deadlineMs: 120_000 });
      return {
        type: "couldNotFix",
        reason: `the fix failed verification (${verification.blockedStage ?? "unknown"})`,
      };
    }

    const dateStamp = compactDateStamp();
    const branchName = `iris/fix-${signatureId.slice(0, 12)}-${dateStamp}`;
    const commitMessage =
      `Novel fix for ${appSlug}\n\n` +
      `Break-Signature: ${signatureId}\n` +
      "Fix-Recipe-Match: novel\n" +
      `Verified: build-green${verification.suitePassed === true ? ", suite-green" : ""}\n` +
      `Assisted-by: iris-maintain-mode/1 (tier-c, ${this.provider.displayName})\n` +
      "Modified-by: Iris (publik) — derived a novel fix under your own model key";

    // No `||`/`&&` — Windows PowerShell 5.1 does not reliably support either
    // — so branch creation is check-then-one-of-create/switch, exactly like
    // `replay-engine.ts`'s own commit ceremony.
    const branchExists = await tryRun(runner, `git rev-parse --verify --quiet ${powerShellSingleQuote(branchName)}`, {
      deadlineMs: 30_000,
    });
    if (branchExists?.succeeded === true) {
      await tryRun(runner, `git checkout ${powerShellSingleQuote(branchName)}`, { deadlineMs: 30_000 });
    } else {
      await tryRun(runner, `git checkout -b ${powerShellSingleQuote(branchName)}`, { deadlineMs: 30_000 });
    }
    await tryRun(runner, "git add -A", { deadlineMs: 60_000 });
    await tryRun(runner, `git commit -m ${powerShellSingleQuote(commitMessage)} --quiet`, { deadlineMs: 60_000 });

    maintainTrace(`tier-c committed a novel fix on ${branchName}`);
    return { type: "fixedAndVerified", branchName, wasNovel: true };
  }
}
