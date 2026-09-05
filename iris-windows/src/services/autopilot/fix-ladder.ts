//
// The failure-fix ladder — the Windows port of the macOS self-repair loop that
// lives across `GuideAutopilotRunner.runFailureLadder` / `climbTheFixLadder`,
// `GuideAutopilotFixProposer`, `GuideAutopilotCodexFixProposer`, and
// `GuideAutopilotCommandShape`.
//
// WHAT IT IS FOR. On macOS, when a guide command fails the runner does not hand
// the reader a dead terminal: it asks the model for ONE structured fix, runs it
// under the same safety gate, retries the original, and only surfaces to the
// reader once it has run out of rungs, budget, or ideas. This module is that
// loop, reimplemented Windows-idiomatically:
//
//   - The transport is `MaintainModelProviding.respond()` (the same BYO
//     Anthropic/OpenAI seam maintain mode already uses — never a publik host,
//     never a funded proxy), driven with the *Codex* plain-text contract: the
//     model is asked for ONE fenced json block and nothing else, which is parsed
//     leniently and handed to the ONE validator both macOS routes share. There
//     is no tool-use wire format to force over a `respond()` call, exactly as
//     there is none over `codex exec`, so the fenced-block trick is the port.
//
//   - The gate is `risk.ts`, at `model_proposed_fix` provenance — the stricter
//     one, where opacity (`$()`, backticks, `eval`) trips the tap even for a
//     command that would otherwise run. A model's repair is untrusted text, and
//     this is the compensating control that keeps it honest.
//
//   - The host allowlist is the structural answer to a hallucinated hostname: a
//     proposed `run_a_command` may only reach hosts the recipe's OWN commands
//     and links already name. A plausible-sounding new domain is refused no
//     matter how plausible it sounds. Ported from
//     `GuideAutopilotCommandShape.hostsTheCommandWouldReach` +
//     `GuideAutopilotFixProposer.validatedFix`.
//
// It is a pure module (no Node/Electron/Windows APIs, no secret at rest): the
// model provider, the shell, the environment strings, and the confirm callback
// are all injected, so the whole ladder runs in the vitest suite with a scripted
// fake provider and a `MockShell` on any host. The runner (`runner.ts`) calls
// `FixLadder.repair` from its one `failed`-command branch; everything else here
// is reachable and asserted directly.
//

import type { InstallRecipe, RecipeStep } from "./recipe";
import { commandForPlatform } from "./recipe";
import type { ApprovedCommand, Provenance } from "./risk";
import { approve, approveAfterAReaderTap, assess } from "./risk";
import { friendlyLabel } from "./friendly-label";
import type { AutopilotEvent } from "./runner";
import {
  DEFAULT_COMMAND_TIMEOUT_MS,
  type CommandOutcome,
  type ShellSession,
} from "./shell";
import type {
  MaintainModelProviding,
  MaintainModelRespondOptions,
} from "../maintain/model-provider";

const MODEL_PROPOSED_FIX: Provenance = "model_proposed_fix";

// ---------------------------------------------------------------------------
// The proposal — what the model may hand back, and the fix Iris will act on.
// ---------------------------------------------------------------------------

/// What the model proposed Iris do about the failure. Mirrors macOS
/// `GuideAutopilotProposedFixAction`, TS-idiomatic as a discriminated union with
/// snake-case kinds matching the task's wire vocabulary.
export type ProposedFixAction =
  | { readonly kind: "run_a_command"; readonly command: string; readonly whatItDoes: string }
  | { readonly kind: "ask_the_reader"; readonly instruction: string }
  | { readonly kind: "cannot_fix"; readonly reason: string };

/// One structured fix, decoded and validated. Mirrors macOS
/// `GuideAutopilotProposedFix`. `cameFromWebSearch` is always false on Windows —
/// the maintain providers expose no server-side web_search, so unlike the
/// Anthropic route on macOS there is no second, searching rung to report. Kept
/// on the type so the shape reads the same across platforms and a future
/// provider that DOES search needs no new field.
export interface ProposedFix {
  readonly diagnosis: string;
  readonly confidence: string;
  readonly action: ProposedFixAction;
  readonly retryTheOriginalCommandAfterwards: boolean;
  readonly cameFromWebSearch: false;
}

/// Everything the model is told about a failure. Mirrors macOS
/// `GuideAutopilotFailureContext`, with the Windows fields the task calls for
/// (PowerShell path, OS build, arch, tool versions, scrubbed output tail).
export interface FailureContext {
  readonly guideSlug: string;
  readonly guideVersion: number;
  readonly appName: string;
  readonly platformLabel: string;
  readonly stepIdentifier: string;
  readonly stepTitle: string;
  readonly stepBody: string;
  readonly verifierLabel: string | undefined;
  readonly commandAsRun: string;
  readonly exitStatus: number;
  readonly scrubbedOutputTail: string;
  /// The PowerShell (or, when Iris runs on a Mac to test the flow, the login
  /// shell) path the command ran in.
  readonly shellPath: string;
  readonly workingDirectory: string;
  /// The Windows build string (`10.0.22631`), the OS-version field.
  readonly operatingSystemVersion: string;
  readonly architecture: string;
  readonly knownToolVersions: readonly string[];
  readonly priorAttempts: readonly string[];
  /// Hosts named by the recipe's own commands and links — the only network
  /// destinations a proposed fix is allowed to reach.
  readonly hostsTheGuideAlreadyReaches: ReadonlySet<string>;
}

// ---------------------------------------------------------------------------
// What the command reaches for (host analysis) — the structural allowlist.
// ---------------------------------------------------------------------------

/// Hostnames a command names anywhere in its text — the Windows/TS port of
/// `GuideAutopilotCommandShape.hostsTheCommandWouldReach`. Pure text analysis,
/// nothing is run.
///
/// It reads http(s) URLs and `git@host:` ssh remotes out of the command string,
/// which is what an `iwr`/`Invoke-WebRequest`/`curl`/`git clone` that reaches a
/// new destination actually contains. A `winget install --id X` or a bare
/// `npm install` names no host in its text and reaches only its toolchain's own
/// default source — not a NEW destination a model could smuggle in — so, exactly
/// as on macOS, only explicit URLs and ssh remotes are extracted. The allowlist
/// check is about "did the fix introduce a host the guide never uses", and a
/// host only enters that question by being written down.
export function hostsTheCommandWouldReach(command: string): Set<string> {
  const hosts = new Set<string>();
  const patterns = [/https?:\/\/([A-Za-z0-9.-]+)/g, /git@([A-Za-z0-9.-]+):/g];
  for (const pattern of patterns) {
    for (const match of command.matchAll(pattern)) {
      const host = match[1];
      if (host !== undefined && host.length > 0) {
        hosts.add(host.toLowerCase());
      }
    }
  }
  return hosts;
}

/// Every host the recipe's own commands and links already reach — the set a
/// proposed fix's hosts must be a subset of. The Windows analog of macOS's
/// `GuideAutopilotGuideContext.hostsReachedByTheGuide`: it unions the hosts of
/// every step's Windows AND posix command (so the answer does not depend on
/// which host the recipe is examined on) with every `href` a step points at.
export function hostsReachedByRecipe(recipe: InstallRecipe): Set<string> {
  const hosts = new Set<string>();
  for (const step of recipe.steps) {
    for (const text of [step.command, step.posixCommand]) {
      if (text !== undefined) {
        for (const host of hostsTheCommandWouldReach(text)) hosts.add(host);
      }
    }
    if (step.href !== undefined) {
      for (const host of hostsTheCommandWouldReach(step.href)) hosts.add(host);
      // An `href` is a bare URL, not a command, so also read its host directly
      // in case it is not shaped the command regex expects (it always is today,
      // but this keeps the link and the command in step).
      const bareHost = hostFromUrl(step.href);
      if (bareHost !== undefined) hosts.add(bareHost);
    }
  }
  return hosts;
}

function hostFromUrl(url: string): string | undefined {
  const match = url.match(/^[a-z]+:\/\/([A-Za-z0-9.-]+)/i);
  return match?.[1]?.toLowerCase();
}

// ---------------------------------------------------------------------------
// Scrubbing the output tail — secrets and the account name never leave.
// ---------------------------------------------------------------------------

/// The longest scrubbed tail sent to the model. A failure's last lines carry the
/// error; the top of a long build log does not, and every character costs the
/// reader money and privacy.
const MAX_SCRUBBED_TAIL_CHARS = 4000;
const MAX_SCRUBBED_TAIL_LINES = 40;

/// Scrubs a command's output for the model: the account name embedded in every
/// Windows path is removed, obvious secrets are redacted, and only the tail is
/// kept. The same mandatory redaction the maintain code does
/// (`break-signature.ts`'s "every Windows path embeds the account name"),
/// applied here without lowercasing — the model reads this, so its case and
/// structure are kept, only the sensitive spans are replaced.
export function scrubOutputTail(output: string): string {
  const lines = output.split(/\r?\n/);
  const tail = lines.slice(Math.max(0, lines.length - MAX_SCRUBBED_TAIL_LINES)).join("\n");
  const scrubbed = tail
    // The account name in a Windows user path — `C:\Users\<name>\...` — is the
    // one path span that MUST go; keep the shape, drop the name.
    .replace(/([a-z]:\\Users\\)[^\\/\s"']+/gi, "$1<user>")
    .replace(/(\/(?:Users|home)\/)[^/\s"']+/gi, "$1<user>")
    // Bearer tokens and common key shapes.
    .replace(/\b(bearer\s+)[A-Za-z0-9._-]+/gi, "$1<redacted>")
    .replace(/\b(sk-|ghp_|gho_|ghs_|ghu_|github_pat_|xox[baprs]-|AKIA|ASIA)[A-Za-z0-9_-]{6,}/g, "<redacted>")
    // `password=…`, `token: …`, `apikey=…`, `secret=…` and the like.
    .replace(
      /\b(pass(?:word)?|token|secret|api[_-]?key|access[_-]?key|client[_-]?secret)\b(\s*[:=]\s*)("?)[^\s"']+\3/gi,
      "$1$2<redacted>",
    )
    // A PEM block collapses to a marker.
    .replace(/-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----/g, "<redacted key>")
    // A long unbroken hex/base64 run is almost never meaningful error text and
    // is exactly the shape a leaked token takes.
    .replace(/\b[A-Fa-f0-9]{40,}\b/g, "<redacted>")
    .replace(/\b[A-Za-z0-9+/]{60,}={0,2}\b/g, "<redacted>");
  return scrubbed.length > MAX_SCRUBBED_TAIL_CHARS
    ? scrubbed.slice(scrubbed.length - MAX_SCRUBBED_TAIL_CHARS)
    : scrubbed;
}

// ---------------------------------------------------------------------------
// The proposer — a plain-text contract over MaintainModelProviding.respond().
// ---------------------------------------------------------------------------

/// One fix proposal per call. The runner treats `undefined` as "no fix offered"
/// and escalates — the safe direction, exactly as on macOS.
export interface FixProposing {
  /// Whether a proposal can be made at all right now (a key is connected).
  isAvailable(): boolean;
  /// Ask for ONE fix. Never throws for a "model had nothing" answer — that is
  /// `undefined`; it may throw only for a transport failure, which the ladder
  /// catches and treats as a spent-but-empty rung.
  proposeFix(context: FailureContext): Promise<ProposedFix | undefined>;
}

/// The most tokens one fix proposal may cost. Matches macOS
/// `GuideAutopilotFixProposer.maximumOutputTokensPerFixCall`.
const MAXIMUM_OUTPUT_TOKENS_PER_FIX_CALL = 700;

/// A `FixProposing` over the maintain model transport. Asks with the Codex-style
/// plain-text contract (ONE fenced json block), parses leniently, and hands the
/// object to `validatedFix` — the same validator whose host allowlist is the
/// structural guardrail, so this route cannot quietly lose it.
export class ModelFixProposer implements FixProposing {
  constructor(private readonly provider: MaintainModelProviding) {}

  isAvailable(): boolean {
    return this.provider.isAvailable();
  }

  async proposeFix(context: FailureContext): Promise<ProposedFix | undefined> {
    const options: MaintainModelRespondOptions = {
      systemPrompt: `${fixSystemPrompt(context)}\n\n${REPLY_CONTRACT}`,
      conversation: [{ role: "user", text: failureReport(context) }],
      // Not honored by every provider (the OpenAI route caps, the codex CLI
      // does not), passed anyway so the contract reads the same everywhere.
      maximumOutputTokens: MAXIMUM_OUTPUT_TOKENS_PER_FIX_CALL,
    };
    const reply = await this.provider.respond(options);
    const proposalObject = parseProposalObject(reply);
    if (proposalObject === undefined) return undefined;
    return validatedFix(proposalObject, context);
  }
}

/// Turns a raw proposal object into a fix Iris will act on, INCLUDING the
/// guardrails — the TS port of macOS `GuideAutopilotFixProposer.validatedFix`.
/// A malformed object is `undefined` (no fix offered); a well-formed
/// `run_a_command` that reaches a host the guide never uses is downgraded to
/// `cannot_fix`, which is the structural answer to an invented hostname.
export function validatedFix(
  input: Record<string, unknown>,
  context: FailureContext,
): ProposedFix | undefined {
  const diagnosis = typeof input.diagnosis === "string" ? input.diagnosis : undefined;
  const confidence = typeof input.confidence === "string" ? input.confidence : undefined;
  const retry = input.retryTheOriginalCommandAfterwards;
  const actionObject = input.action;
  if (
    diagnosis === undefined ||
    confidence === undefined ||
    typeof retry !== "boolean" ||
    typeof actionObject !== "object" ||
    actionObject === null
  ) {
    return undefined;
  }
  const actionRecord = actionObject as Record<string, unknown>;
  const kind = actionRecord.kind;

  let action: ProposedFixAction;
  switch (kind) {
    case "run_a_command": {
      const command = actionRecord.command;
      const whatItDoes = actionRecord.whatItDoes;
      if (typeof command !== "string" || typeof whatItDoes !== "string") return undefined;
      const hosts = hostsTheCommandWouldReach(command);
      const forbidden = [...hosts].filter((host) => !context.hostsTheGuideAlreadyReaches.has(host));
      if (forbidden.length > 0) {
        // A fix may not quietly introduce a new network destination. It does not
        // matter how plausible the hostname sounds.
        return {
          diagnosis,
          confidence,
          action: {
            kind: "cannot_fix",
            reason: `The proposed fix reached for a host the guide never uses (${forbidden.sort().join(", ")}).`,
          },
          retryTheOriginalCommandAfterwards: false,
          cameFromWebSearch: false,
        };
      }
      action = { kind: "run_a_command", command, whatItDoes };
      break;
    }
    case "ask_the_reader": {
      const instruction = actionRecord.instruction;
      if (typeof instruction !== "string") return undefined;
      action = { kind: "ask_the_reader", instruction };
      break;
    }
    case "cannot_fix": {
      const reason = actionRecord.reason;
      if (typeof reason !== "string") return undefined;
      action = { kind: "cannot_fix", reason };
      break;
    }
    default:
      return undefined;
  }

  return { diagnosis, confidence, action, retryTheOriginalCommandAfterwards: retry, cameFromWebSearch: false };
}

/// Pulls the proposal object out of a model reply. Tolerant about WRAPPING
/// (```json fence, bare ``` fence, or a sentence in front of a naked object),
/// strict about CONTENT — a malformed or non-proposal object is `undefined`
/// rather than a salvaged fragment, because the runner treats `undefined` as
/// "no fix offered" and escalates, which is the safe direction. Port of macOS
/// `GuideAutopilotCodexFixProposer.proposalObject`.
export function parseProposalObject(reply: string): Record<string, unknown> | undefined {
  for (const candidate of jsonCandidates(reply)) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(candidate);
    } catch {
      continue;
    }
    if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
      const record = parsed as Record<string, unknown>;
      // A json block that is not a proposal (a model explaining itself in json,
      // say) must not be mistaken for one.
      if (record.action !== undefined || record.diagnosis !== undefined) {
        return record;
      }
    }
  }
  return undefined;
}

/// Every substring of the reply that might be the object, best guess first: each
/// fenced block in order, then the outermost bare `{…}` span.
function jsonCandidates(reply: string): string[] {
  const candidates: string[] = [];
  const fence = /```([A-Za-z0-9_-]*)[ \t]*\r?\n([\s\S]*?)```/g;
  for (const match of reply.matchAll(fence)) {
    const languageTag = (match[1] ?? "").trim().toLowerCase();
    if (languageTag === "" || languageTag === "json") {
      candidates.push(match[2] ?? "");
    }
  }
  const firstBrace = reply.indexOf("{");
  const lastBrace = reply.lastIndexOf("}");
  if (firstBrace !== -1 && lastBrace > firstBrace) {
    candidates.push(reply.slice(firstBrace, lastBrace + 1));
  }
  return candidates;
}

// ---------------------------------------------------------------------------
// The prompt — the macOS system prompt, adapted for PowerShell/winget.
// ---------------------------------------------------------------------------

/// The install-repair system prompt. A faithful port of macOS
/// `GuideAutopilotFixProposer.systemPrompt`, with the toolchain examples widened
/// to the Windows set (winget, npm.cmd, cargo) and the "keep the install moving"
/// / "never invent a host" rules kept verbatim in spirit.
export function fixSystemPrompt(context: FailureContext): string {
  return [
    `You are Iris's install-repair assistant. A command from the published install guide for ${context.appName} just failed in Iris's own terminal, and you propose exactly one fix.`,
    "",
    "Your job is to keep the install MOVING. Most install failures are mechanical and recoverable — adapt and continue rather than handing the reader a dead end.",
    "",
    'When the failure is an "already-done" state, reuse what is there instead of stopping. Examples: a clone or directory that already exists (Set-Location into it and `git pull`, or `git checkout` the pinned commit the guide uses); a package already installed or "already up to date" (treat as done and move on); a file or folder that already exists; a port already serving. Prefer reuse or a skip over deleting anything.',
    "",
    "Prefer running exactly ONE safe, non-destructive fix over answering cannot_fix. Reserve cannot_fix and asking the reader for failures that genuinely need a human — a missing credential or API key, a permission only they can grant, a download only they can do. An honest dead end is the LAST resort, not an equal option, and never the answer to a mechanical error you could fix yourself.",
    "",
    "Hard rules, in order (these always win over the guidance above):",
    "- Never invent hostnames, URLs, file paths, or commands that do not appear in the material you were given or belong to the toolchain the guide itself uses (git, node, npm, pnpm, cargo, winget, and the like).",
    "- Never propose reaching a network host that does not already appear in the guide's own commands.",
    "- Never propose running as administrator (an elevated shell, `-Verb RunAs`) unless the output plainly says access is denied.",
    "- Never delete anything outside the guide's own working directory, and prefer reuse over deletion even inside it.",
    "- Never ask for or handle secrets, passwords, or API keys.",
    "- Keep the diagnosis to one or two plain sentences a non-developer can follow.",
  ].join("\n");
}

/// What the reply must look like — the Codex plain-text contract. Port of macOS
/// `GuideAutopilotCodexFixProposer.replyContract`, with the field names the
/// Windows `ProposedFixAction` union uses.
export const REPLY_CONTRACT = [
  "Reply with EXACTLY ONE fenced json block and nothing else — no prose before it, no explanation after it. The json block IS the proposal; there is no tool to call.",
  "",
  "```json",
  "{",
  '  "diagnosis": "one sentence on why the command failed",',
  '  "confidence": "high" | "medium" | "low",',
  '  "retryTheOriginalCommandAfterwards": true | false,',
  '  "action": { ... one of the three below ... }',
  "}",
  "```",
  "",
  "The action is exactly one of:",
  "",
  '  {"kind": "run_a_command", "command": "…", "whatItDoes": "plain English, one line"}',
  '  {"kind": "ask_the_reader", "instruction": "…"}',
  '  {"kind": "cannot_fix", "reason": "…"}',
  "",
  "Do not run anything yourself, do not edit any file, and do not use your own shell to investigate. You are being asked for ONE proposal as json; Iris runs it, under its own safety gate.",
].join("\n");

/// The failure report — the user turn. Port of macOS
/// `GuideAutopilotFixProposer.failureReport`.
export function failureReport(context: FailureContext): string {
  const lines: string[] = [
    `Guide: ${context.guideSlug} v${context.guideVersion} (${context.appName}, ${context.platformLabel})`,
    `Step ${context.stepIdentifier}: ${context.stepTitle}`,
  ];
  if (context.stepBody.length > 0) lines.push(context.stepBody);
  if (context.verifierLabel !== undefined) lines.push(`Step is done when: ${context.verifierLabel}`);
  lines.push(
    "",
    "Command run (verbatim):",
    context.commandAsRun,
    "",
    `Exit status: ${context.exitStatus}`,
    `Working directory: ${context.workingDirectory}`,
    `Shell: ${context.shellPath}`,
    `System: ${context.operatingSystemVersion} (${context.architecture})`,
  );
  if (context.knownToolVersions.length > 0) {
    lines.push(`Tool versions: ${context.knownToolVersions.join(", ")}`);
  }
  if (context.priorAttempts.length > 0) {
    lines.push("", "Already tried on this step (do not repeat):", ...context.priorAttempts.map((attempt) => `- ${attempt}`));
  }
  lines.push("", "Output tail (secrets redacted):", context.scrubbedOutputTail);
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// The ladder itself — caps, rungs, the progress guard, and surfacing.
// ---------------------------------------------------------------------------

/// The caps that bound one install's self-repair. Injectable so the suite can
/// prove the arithmetic of each independently; the defaults are the macOS
/// numbers (`maximumFixAttemptsPerStep`, `maximumFixAttemptsPerGuide`,
/// `maximumModelCallsPerGuide`,
/// `maximumConsecutiveStepsTheLadderMaySpendOnWithoutGettingOneRunning`).
export interface LadderCaps {
  /// Two fix attempts per step — rung (a) and rung (b). Not about spend; how
  /// many different things Iris tries on one command.
  readonly maximumRungsPerStep: number;
  /// The per-install ceilings. Both increment together per rung, so the fix cap
  /// (the lower) always trips first — the model-call cap is the belt.
  readonly maximumFixesPerGuide: number;
  readonly maximumModelCallsPerGuide: number;
  /// The progress guard: this many consecutive steps that the ladder SPENT model
  /// calls on and still could not get running means it is going in circles.
  readonly maximumConsecutiveStepsWithoutGettingOneRunning: number;
}

export const DEFAULT_LADDER_CAPS: LadderCaps = {
  maximumRungsPerStep: 2,
  maximumFixesPerGuide: 6,
  maximumModelCallsPerGuide: 8,
  maximumConsecutiveStepsWithoutGettingOneRunning: 5,
};

/// Who pays for the model calls this ladder makes — the Windows port of macOS
/// `GuideAutopilotFixLadderFunding`. It decides whether the per-install spend
/// caps (`maximumFixesPerGuide` / `maximumModelCallsPerGuide`) apply at all:
///
///   - `publik_funded_tier`: publik is paying, so the caps bound its spend.
///     macOS runs this while publik funds a reader's early installs.
///   - `readers_own_credential`: every model call is billed to the reader's OWN
///     key from the first one. publik's spend cap has nothing to protect here,
///     so it does not apply at all — mirroring
///     `GuideAutopilotFixLadderFunding.theReadersOwnCredential`, whose fix macOS
///     shipped after a reader on his own subscription was told "I've used up
///     what I can spend on this install" at step 7 of 17 for money nobody was
///     spending.
///
/// On Windows the fix ladder is ALWAYS `readers_own_credential`: the proposer
/// runs on the reader's own Anthropic/OpenAI key (`model-provider.ts`, ratified
/// D4/D5), never a funded proxy — there is no funded route for it, ever. So the
/// default is the reader's own credential, and the funded profile exists only so
/// the cap arithmetic stays a faithful, tested port of the macOS one.
export type LadderFunding = "publik_funded_tier" | "readers_own_credential";

/// The environment strings the failure report carries, injected so the ladder
/// stays pure (no `os`/`process` reads) and the suite pins them.
export interface LadderEnvironment {
  readonly shellPath: string;
  readonly operatingSystemVersion: string;
  readonly architecture: string;
  readonly knownToolVersions: readonly string[];
}

/// A reader confirm for a fix that the gate marks confirm-tier. Awaitable, like
/// `AutopilotHost.ensureAutonomyGranted` — in production the autonomy grant means
/// this is never reached for a fix; the default refuses, so a ladder wired
/// without one degrades to "won't run a tap-tier repair" rather than running it.
export type ConfirmFix = (command: string, reason: string) => Promise<boolean>;

/// What one call to `repair` concluded. The runner turns each into events + a
/// `RunnerStatus`.
export type LadderResult =
  /// The original command now succeeds; the runner advances past the step.
  | { readonly kind: "repaired" }
  /// The model asked for a human action; the runner floats the eye to it.
  | { readonly kind: "hand_to_reader"; readonly instruction: string; readonly diagnosis: string }
  /// The ladder is out of rungs, budget, or ideas; the runner surfaces this to
  /// the reader with the "Try again / Continue past it" choice.
  | { readonly kind: "surface"; readonly diagnosis: string }
  /// The reader hit the red 'Stop' while the ladder was climbing. It stopped the
  /// instant it noticed — before the next model call or fix command — rather than
  /// finishing the climb; the runner discards this the same way it discards an
  /// in-flight command's outcome. Mirrors the `theReaderAskedToStopThisStep`
  /// checks in macOS `climbTheFixLadder`.
  | { readonly kind: "stopped" };

/// Everything one `repair` needs from the runner, injected so the ladder never
/// learns how the runner approves or re-runs the original command.
export interface RepairRequest {
  readonly step: RecipeStep;
  readonly command: string;
  readonly exitCode: number;
  readonly output: string;
  readonly workingDirectory: string;
  readonly shell: ShellSession;
  /// Re-runs the ORIGINAL command exactly as the runner would, in its declared
  /// folder. The runner owns approval + the folder move; the ladder only asks
  /// for the outcome.
  readonly retryOriginal: () => Promise<CommandOutcome>;
  /// Emits a runner event (the ladder's fix commands and diagnoses stream to the
  /// terminal through this).
  readonly emit: (event: AutopilotEvent) => void;
  /// Whether the reader has hit the red 'Stop'. The ladder cannot cancel a model
  /// call or a fix command already in flight (the shell's own `abort` kills a
  /// running command's process tree), but it checks this before it STARTS the
  /// next model call or fix command — and again right after each returns — so a
  /// Stop is honored the instant it is noticed rather than after the climb
  /// happens to finish. Optional (default: never stop) so a ladder wired without
  /// it behaves exactly as before. Mirrors macOS `theReaderAskedToStopThisStep`.
  readonly shouldStop?: () => boolean;
}

const NO_PROVIDER_DIAGNOSIS =
  "Iris couldn't repair this on its own because no model key is connected. Connect an Anthropic key or an OpenAI key in Iris's settings and it can try. Here's the command that failed.";

const BUDGET_EXHAUSTED_DIAGNOSIS =
  "Iris has tried the repairs it allows itself on this install and used them up. Here's the command that failed, and you can take it from here.";

const GETTING_NOWHERE_DIAGNOSIS =
  "Iris has repaired and re-run the last few steps and none of them came up — it's going in circles rather than getting closer, so it's stopping. Here's the command that failed.";

const DEFAULT_SURFACE_DIAGNOSIS = "Iris couldn't get this step working on its own.";

/// The self-repair loop for ONE install. Constructed once per run (its counters
/// span the whole install) and called from the runner's `failed`-command branch.
export class FixLadder {
  private modelCallsUsedThisGuide = 0;
  private fixAttemptsUsedThisGuide = 0;
  private consecutiveStepsWithoutGettingOneRunning = 0;

  constructor(
    /// `undefined` when the app has no model key configured — the ladder then
    /// degrades to "surface immediately", never hangs.
    private readonly proposer: FixProposing | undefined,
    private readonly recipe: InstallRecipe,
    private readonly hostsTheGuideAlreadyReaches: ReadonlySet<string>,
    private readonly environment: LadderEnvironment,
    private readonly platform: NodeJS.Platform,
    /// Passed straight to `risk.assess`/`approve` for a fix command, exactly as
    /// the task specifies. Note the provenance is always `model_proposed_fix`,
    /// the stricter gate — opacity (`$()`, backticks) trips a tap there even for
    /// a command that would otherwise run.
    private readonly autonomyGranted: boolean,
    private readonly confirmFix: ConfirmFix = async () => false,
    private readonly caps: LadderCaps = DEFAULT_LADDER_CAPS,
    /// Who pays for the model calls — the default is the reader's own key, which
    /// is the ONLY funding a Windows fix ladder ever runs on (see
    /// `LadderFunding`). On the reader's own credential the spend caps do not
    /// apply, so `mayAskTheModelAgain` never surfaces "used up what I can spend"
    /// for money nobody was spending. The progress guard still bounds a runaway.
    private readonly funding: LadderFunding = "readers_own_credential",
  ) {}

  /// Attempts to self-repair a failed command, and reports what the runner
  /// should do next. Wraps the climb so every one of its exits is scored for
  /// progress in one place (the runaway guard needs a single point that sees
  /// them all) — the split mirrors macOS `runFailureLadder` / `climbTheFixLadder`.
  async repair(request: RepairRequest): Promise<LadderResult> {
    if (this.proposer === undefined || !this.proposer.isAvailable()) {
      // No key, or a login that dropped between steps: surface at once with a
      // clear reason. This is not the ladder spinning, so it does not count
      // toward the progress guard.
      return { kind: "surface", diagnosis: NO_PROVIDER_DIAGNOSIS };
    }

    const callsBefore = this.modelCallsUsedThisGuide;
    const result = await this.climb(request);
    const spentSomething = this.modelCallsUsedThisGuide > callsBefore;
    if (result.kind === "repaired") {
      this.consecutiveStepsWithoutGettingOneRunning = 0;
    } else if (result.kind === "stopped") {
      // The reader stopped the run mid-climb. The run is terminal; this is not
      // the ladder failing to make progress, so it does not count as spinning.
    } else if (result.kind === "surface" && spentSomething) {
      // Iris asked the model, tried what it said, and the step still is not
      // running. Only this counts as spinning: a step the budget never let Iris
      // try, or one handed to the reader, is not the ladder's failure to report.
      this.consecutiveStepsWithoutGettingOneRunning += 1;
    }
    return result;
  }

  private async climb(request: RepairRequest): Promise<LadderResult> {
    const priorAttempts: string[] = [];
    let lastDiagnosis: string | undefined;

    for (let rung = 0; rung < this.caps.maximumRungsPerStep; rung += 1) {
      // The reader may have hit 'Stop' between rungs; do not start another model
      // call or fix command if they have. Checked at the top of every rung, the
      // first of the three `shouldStop` checkpoints (matching macOS).
      if (request.shouldStop?.()) {
        return { kind: "stopped" };
      }
      // The runaway guard, before the spend gate: a ladder that has spent calls
      // on N steps in a row without getting one running is going in circles.
      if (
        this.consecutiveStepsWithoutGettingOneRunning >=
        this.caps.maximumConsecutiveStepsWithoutGettingOneRunning
      ) {
        return { kind: "surface", diagnosis: GETTING_NOWHERE_DIAGNOSIS };
      }
      if (!this.mayAskTheModelAgain()) {
        return { kind: "surface", diagnosis: BUDGET_EXHAUSTED_DIAGNOSIS };
      }
      this.fixAttemptsUsedThisGuide += 1;
      this.modelCallsUsedThisGuide += 1;

      const context = this.buildContext(request, priorAttempts);
      let fix: ProposedFix | undefined;
      try {
        fix = await this.proposer!.proposeFix(context);
      } catch {
        // A transport failure is not a diagnosis; try the next rung or surface,
        // never fabricate.
        priorAttempts.push("a repair attempt could not reach the model");
        continue;
      }
      // The model call just returned — the second checkpoint. If the reader
      // stopped while it was in flight, do not act on what it said.
      if (request.shouldStop?.()) {
        return { kind: "stopped" };
      }
      if (fix === undefined) {
        priorAttempts.push("the model had no fix to offer");
        continue;
      }
      lastDiagnosis = fix.diagnosis;
      request.emit({ type: "fixProposed", diagnosis: fix.diagnosis });

      if (fix.action.kind === "cannot_fix") {
        priorAttempts.push(`model could not fix it: ${fix.action.reason}`);
        continue;
      }
      if (fix.action.kind === "ask_the_reader") {
        return { kind: "hand_to_reader", instruction: fix.action.instruction, diagnosis: fix.diagnosis };
      }

      const applied = await this.applyFixCommand(fix.action.command, fix.action.whatItDoes, request);
      // The fix command just ran — the third checkpoint. A Stop clicked while it
      // was executing killed its process tree; do not retry the original or climb
      // to another rung.
      if (request.shouldStop?.()) {
        return { kind: "stopped" };
      }
      if (applied === "declined") {
        priorAttempts.push(`the fix was not run: ${fix.action.command}`);
        continue;
      }
      priorAttempts.push(`${fix.action.command} → ${applied === "ran" ? "ran" : "also failed"}`);
      if (!fix.retryTheOriginalCommandAfterwards) {
        continue;
      }

      request.emit({ type: "commandStarted", text: request.command, friendlyLabel: friendlyLabel(request.command) });
      const retry = await request.retryOriginal();
      if (retry.kind === "succeeded") {
        request.emit({ type: "commandFinished", exitCode: 0, output: retry.output });
        return { kind: "repaired" };
      }
      request.emit({
        type: "commandFinished",
        exitCode: retry.kind === "failed" ? retry.exitCode : 124,
        output: retry.kind === "failed" ? retry.output : "",
      });
      // Still failing — next rung.
    }
    return { kind: "surface", diagnosis: lastDiagnosis ?? DEFAULT_SURFACE_DIAGNOSIS };
  }

  /// Whether the ladder may make one more model call under the per-install caps.
  ///
  /// The caps bound publik's SPEND, so they only apply when publik is paying. On
  /// the reader's own credential — the only funding a Windows fix ladder ever
  /// runs on — every call is billed to the reader from the first one, publik's
  /// cap has nothing to protect, and it does not apply at all: this returns true
  /// unconditionally, exactly as macOS `theLadderMayAskTheModelAgain` does when
  /// `publikIsPayingForTheCallAboutToBeMade()` is false. The per-step rung cap
  /// and the going-in-circles progress guard still bound a runaway; what is
  /// removed is only the "used up what I can spend" ceiling on money the reader,
  /// not publik, is spending. Under the funded tier both counters increment
  /// together, so the fix cap (the lower) binds first.
  private mayAskTheModelAgain(): boolean {
    if (this.funding === "readers_own_credential") {
      return true;
    }
    return (
      this.fixAttemptsUsedThisGuide < this.caps.maximumFixesPerGuide &&
      this.modelCallsUsedThisGuide < this.caps.maximumModelCallsPerGuide
    );
  }

  /// Runs a model-proposed fix command under the gate, at `model_proposed_fix`
  /// provenance. Returns `ran`/`also_failed`/`declined`; a fix's own failure does
  /// NOT consume a rung by itself — it fails this rung and the loop moves on.
  private async applyFixCommand(
    fixCommand: string,
    whatItDoes: string,
    request: RepairRequest,
  ): Promise<"ran" | "also_failed" | "declined"> {
    // Judge the fix in the folder it will actually run in, not on its text
    // alone. `Remove-Item -Recurse -Force .` is a tidy-up in the app folder and
    // a catastrophe in `C:\Windows`, and the two are spelled identically — so a
    // system folder, a drive root, or a `..`-escape out of the install folder is
    // refused outright, even under the grant (see `risk.ts`). This is the SAME
    // folder-aware gate the runner's own per-step path uses (`runCommandStep`);
    // an untrusted model's fix is the last input that should skip it. Mirrors
    // macOS `applyFixCommand` calling `assess(_:inWorkingDirectory:)` with the
    // shell's current working directory every time.
    const gateOptions = {
      provenance: MODEL_PROPOSED_FIX,
      autonomyGranted: this.autonomyGranted,
      workingDirectory: request.workingDirectory,
    };
    const verdict = assess(fixCommand, gateOptions);
    let approved: ApprovedCommand | undefined;
    if (verdict.tier === "runs_without_asking") {
      approved = approve(fixCommand, gateOptions);
    } else if (verdict.tier === "needs_a_confirm_tap") {
      const ok = await this.confirmFix(fixCommand, verdict.reason);
      if (!ok) {
        request.emit({
          type: "fixProposed",
          diagnosis: `Iris didn't run that repair: ${verdict.reason}`,
        });
        return "declined";
      }
      approved = approveAfterAReaderTap(fixCommand, gateOptions);
    } else {
      // refused_outright — a catastrophe-floor or download-and-run shape from a
      // model. Never run, even under the grant (the floor is absolute).
      request.emit({
        type: "fixProposed",
        diagnosis: `Iris won't run that repair automatically: ${verdict.reason}`,
      });
      return "declined";
    }
    if (approved === undefined) return "declined";

    request.emit({ type: "commandStarted", text: fixCommand, friendlyLabel: whatItDoes || friendlyLabel(fixCommand) });
    const outcome = await request.shell.run(approved, DEFAULT_COMMAND_TIMEOUT_MS);
    if (outcome.kind === "succeeded") {
      request.emit({ type: "commandFinished", exitCode: 0, output: outcome.output });
      return "ran";
    }
    request.emit({
      type: "commandFinished",
      exitCode: outcome.kind === "failed" ? outcome.exitCode : 124,
      output: outcome.kind === "failed" ? outcome.output : "",
    });
    return "also_failed";
  }

  private buildContext(request: RepairRequest, priorAttempts: readonly string[]): FailureContext {
    const step = request.step;
    return {
      guideSlug: this.recipe.slug,
      guideVersion: 1,
      appName: this.recipe.appName,
      platformLabel: this.platform === "win32" ? "windows" : "macos",
      stepIdentifier: step.id,
      stepTitle: step.title,
      // A recipe step has no free-text body the way a guide step does; its
      // reader-facing instruction is the closest equivalent, and empty when it
      // has none (the report omits an empty body).
      stepBody: step.instruction ?? "",
      verifierLabel: verifierLabelFor(step),
      commandAsRun: request.command,
      exitStatus: request.exitCode,
      scrubbedOutputTail: scrubOutputTail(request.output),
      shellPath: this.environment.shellPath,
      workingDirectory: request.workingDirectory,
      operatingSystemVersion: this.environment.operatingSystemVersion,
      architecture: this.environment.architecture,
      knownToolVersions: this.environment.knownToolVersions,
      priorAttempts,
      hostsTheGuideAlreadyReaches: this.hostsTheGuideAlreadyReaches,
    };
  }
}

/// The recipe command actually run for a step on this host — re-exported shape so
/// callers building a ladder outside the runner stay consistent.
export function recipeCommandFor(step: RecipeStep, platform: NodeJS.Platform): string | undefined {
  return commandForPlatform(step, platform);
}

/// A short "the step is done when …" line from a step's check, or undefined when
/// it declares none — the recipe analog of a guide step's `verifierLabel`.
function verifierLabelFor(step: RecipeStep): string | undefined {
  const check = step.check;
  if (check === undefined) return undefined;
  switch (check.type) {
    case "tool_version":
      return `${check.tool} is installed and on the PATH`;
    case "process_running":
      return `${check.executable} is running`;
    case "path_exists":
      return `${check.path} exists`;
    default:
      return undefined;
  }
}
