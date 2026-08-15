/**
 * replay-engine.ts
 *
 * Ported from `iris-macos/leanring-buddy/RecipeReplayEngine.swift`, with Tier
 * B's forced-tool-call adapter (`iris-macos/leanring-buddy/MaintainFixAdapter.swift`,
 * not separately assigned a Windows module in the porting spec) folded in
 * here rather than into its own file, since nothing else needs it.
 *
 * Tier A of the fix ladder: someone else already fixed this exact break, and
 * their recipe is in the pool. Replaying it costs zero tokens — the entire
 * economic argument for maintain mode, and the only fix path the funded tier
 * ever gets. Tier B is one constrained, forced BYO model call that re-anchors
 * a stale pooled diff when the exact one no longer applies; absent a key (or
 * absent the adapter entirely, i.e. `fixAdapter === undefined`), stale is the
 * honest end of the road — same as Swift's `nil` adapter.
 *
 * Three recipe families, three behaviors:
 *
 *   workaround / config_change / update_app
 *       Steps for a person. The engine surfaces them; it runs nothing.
 *
 *   patch_pr (a diff against a recorded base)
 *       For a source-clone install only (the D4 gate — see
 *       `install-provenance.ts`), the engine applies it with `git apply
 *       --3way` — three-way merge against the recorded base tolerates drift
 *       honestly, leaving conflict markers rather than mis-applying — then
 *       hands the tree to the verification harness and files the outcome
 *       either way. A clean apply that fails verification is REVERTED and
 *       reported as a failure: leaving a half-working patch in someone's
 *       tree because it merged cleanly is exactly the "textual merge is not
 *       a working merge" trap.
 *
 * Every outcome reaches the pool with this install's pseudonymous id, so
 * promotion counts distinct machines, not retries.
 *
 * ============================================================================
 * CROSS-MODULE CONTRACT — this file is one of several `services/maintain/`
 * modules being ported in parallel by separate tasks. Every import below
 * except `./release-version` now resolves against a sibling module that
 * already landed; `./release-version` (`compareReleaseVersions`) has not been
 * ported yet at the time this file was written, so that one import stays a
 * forward reference until that task lands — everything else in this file has
 * been checked against the sibling modules' REAL exported shapes, not
 * guessed:
 *
 *   ./trace                 maintainTrace(message): void
 *   ./break-signature       BreakAppStack (type)
 *   ./release-version       compareReleaseVersions(a, b): "older" | "same" | "newer" | "cannotBeCompared"  — NOT YET LANDED
 *   ./pool-client           class MaintainPoolClient { fileRecipeOutcome(recipeId, succeeded, installId?): Promise<void> }
 *                           type PooledFixRecipe
 *   ./install-provenance    class InstallProvenanceStore {
 *                             localPatchingIsPermitted(appSlug): boolean;
 *                             provenanceForAppSlug(appSlug): RecordedInstallProvenance | null;
 *                           }
 *   ./patch-queue           class PatchQueue { record(patch: QueuedPatch): void }
 *                           type QueuedPatch { ..., baseCommit?: string, appliedAt: string (ISO 8601) }
 *   ./maintain-shell-runner interface MaintainShellRunner { repoRootPath; run(command, opts?): Promise<MaintainCommandResult> }
 *                           tryRun(runner, command, opts?): Promise<MaintainCommandResult | undefined>
 *   ./verification-harness  verifyAppliedPatch(runner, commands, reproCommand): Promise<VerificationOutcome>
 *                           earnsCleanApply(outcome): boolean
 *                           type VerificationCommands, type VerificationOutcome
 *                           (VerificationCommands lives HERE, not in a separate
 *                           `verification-commands.ts` — the sibling task folded
 *                           it in, mirroring Swift keeping the two in one file)
 *
 * `getCurrentInstallId` and `createShellRunner` are constructor-injected
 * functions rather than raw imports of the modules that build them
 * (`install-identity.ts`'s `MaintainInstallIdentity.currentInstallId()`,
 * `main/maintain/maintain-shell-runner-windows.ts`) — this keeps
 * `RecipeReplayEngine` decoupled from exactly how those seams are composed,
 * the same way `AutopilotRunner` takes `platform` rather than reading
 * `process.platform` itself. `verificationCommandsForStack` is injected for
 * the same reason (real composition: a per-stack table living wherever the
 * caller wires this engine up). The real composition of all three is
 * `main/maintain/controller.ts`'s job, not this file's.
 * ============================================================================
 *
 * PowerShell, not zsh: Swift's shell one-liners (`cmd1 && cmd2 || cmd3`,
 * `2>/dev/null`) are valid in the zsh login shell `MaintainShellRunner.swift`
 * drives, but the real Windows implementation of `MaintainShellRunner` runs
 * commands through `powershell.exe` (Windows PowerShell 5.1, matching
 * `main/powershell-session.ts` — no `&&`/`||`, and single-quote escaping is
 * doubling (`''`), not the POSIX `'\''` trick). This file writes PowerShell-
 * correct command text and issues each git step as its own `runner.run` call
 * instead of chaining with `&&`/`||`/redirects — behavior parity with Swift,
 * not literal translation, per the porting ground rules.
 */

import type { BreakAppStack } from "./break-signature";
import type { InstallProvenanceStore } from "./install-provenance";
import type { MaintainPoolClient, PooledFixRecipe } from "./pool-client";
import { tryRun, type MaintainShellRunner } from "./maintain-shell-runner";
import type { PatchQueue } from "./patch-queue";
import { compareReleaseVersions } from "./release-version";
import { maintainTrace } from "./trace";
import {
  earnsCleanApply,
  verifyAppliedPatch,
  type VerificationCommands,
  type VerificationOutcome,
} from "./verification-harness";

import {
  ANTHROPIC_API_VERSION,
  makeChatRequest,
  type AssistantTransport,
} from "../assistant-transport";
import type { FetchLike } from "../claude";

import * as fs from "node:fs/promises";
import * as path from "node:path";

// ---------------------------------------------------------------------------
// Replay outcomes
// ---------------------------------------------------------------------------

/** What replaying one recipe produced, for the coordinator to surface.
 *  Mirrors Swift's `RecipeReplayResult` enum as a discriminated union — the
 *  idiomatic TS equivalent already established by `autopilot/runner.ts`'s
 *  `AutopilotEvent`/`RunnerStatus`. */
export type RecipeReplayResult =
  /** Steps for the user to follow — workaround/config/update recipes. */
  | { readonly type: "guidanceToShow"; readonly steps: readonly string[] }
  /** The patch applied and passed the replay verification standard. */
  | { readonly type: "patchAppliedAndVerified"; readonly branchName: string }
  /** The patch applied but verification blocked; the tree was reverted. */
  | { readonly type: "patchRevertedAfterFailedVerification"; readonly blockedStage: string }
  /** The patch could not apply, even three-way. Stale for this version. */
  | { readonly type: "patchDidNotApply" }
  /** The D4 gate said no local patching for this install. */
  | { readonly type: "patchingNotPermittedForThisInstall" }
  /** The recipe's applicability range excludes this machine. */
  | { readonly type: "outsideApplicabilityRange" };

// ---------------------------------------------------------------------------
// Applicability (OSV-shaped typed ranges) — ported from Swift's
// `RecipeApplicability` enum as free functions (see `iris-windows/CLAUDE.md`'s
// "closest idiomatic TS equivalent" convention).
// ---------------------------------------------------------------------------

interface ApplicabilityVersionRange {
  readonly introduced?: string;
  readonly fixed?: string;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function decodeStringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.every((entry) => typeof entry === "string") ? (value as string[]) : undefined;
}

function decodeVersionRanges(value: unknown): ApplicabilityVersionRange[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const ranges: ApplicabilityVersionRange[] = [];
  for (const entry of value) {
    if (!isPlainObject(entry)) return undefined;
    const introduced = typeof entry.introduced === "string" ? entry.introduced : undefined;
    const fixed = typeof entry.fixed === "string" ? entry.fixed : undefined;
    ranges.push({ introduced, fixed });
  }
  return ranges;
}

/**
 * The pooled shape: `{"app_version":[{"introduced":"1.0","fixed":"1.4"}],
 * "arch":["arm64"]}`. Absent field = no constraint. Malformed JSON = NO
 * match — a recipe whose applicability cannot be read must not run, same
 * fail-closed rule as unknown install provenance.
 *
 * `applicability` is `unknown` here (not a typed dictionary, unlike Swift's
 * already-`Codable`-decoded `[String: AnyDecodableJSON]?`) because the wire
 * type `pool-client.ts`'s `PooledFixRecipe.applicability` carries is
 * `unknown` — this function does the defensive shape-checking Swift's
 * `Codable` layer did for free.
 */
export function recipeApplicabilityMatches(options: {
  readonly applicability: unknown;
  readonly appVersion: string | null;
  readonly architecture: string;
}): boolean {
  const { applicability, appVersion, architecture } = options;

  if (applicability === null || applicability === undefined) {
    return true;
  }
  if (!isPlainObject(applicability)) {
    maintainTrace("maintain: recipe applicability was not readable JSON — refusing to match");
    return false;
  }

  if ("arch" in applicability) {
    const allowedArchitectures = decodeStringArray(applicability.arch);
    if (allowedArchitectures === undefined) {
      return false; // unreadable arch list -> fail closed
    }
    if (allowedArchitectures.length > 0 && !allowedArchitectures.includes(architecture)) {
      return false;
    }
  }

  if ("app_version" in applicability) {
    if (appVersion === null) {
      return false;
    }
    const versionRanges = decodeVersionRanges(applicability.app_version);
    if (versionRanges === undefined) {
      return false; // unreadable version ranges -> fail closed
    }
    const isInSomeRange = versionRanges.some((range) => {
      // `cannotBeCompared` fails the range, not an earlier guard: an
      // unparseable version is outside every proven range.
      const isAfterIntroduced =
        range.introduced === undefined ||
        ["newer", "same"].includes(compareReleaseVersions(appVersion, range.introduced));
      const isBeforeFixed =
        range.fixed === undefined || compareReleaseVersions(appVersion, range.fixed) === "older";
      return isAfterIntroduced && isBeforeFixed;
    });
    if (!isInSomeRange) {
      return false;
    }
  }

  return true;
}

/**
 * A guidance recipe's jsonb is guide-steps shaped: `{"steps":[{"title":...,
 * "body":..., "command":...}]}`. Extracts readable lines; an unreadable
 * recipe yields one honest line instead of nothing. Ported from Swift's
 * `RecipeGuidanceSteps.extract(fromRecipeJSON:)`.
 */
export function extractRecipeGuidanceSteps(recipeJson: unknown): string[] {
  const fallback = [
    "A fix is known for this break, but its steps could not be read — check the app's page on publik.",
  ];
  if (!isPlainObject(recipeJson)) return fallback;
  const steps = recipeJson.steps;
  if (!Array.isArray(steps) || steps.length === 0) return fallback;

  const lines: string[] = [];
  for (const step of steps) {
    if (!isPlainObject(step)) continue;
    const title = typeof step.title === "string" ? step.title : undefined;
    const command = typeof step.command === "string" ? step.command : undefined;
    if (title !== undefined && command !== undefined) {
      lines.push(`${title}: \`${command}\``);
    } else if (title !== undefined) {
      lines.push(title);
    } else if (command !== undefined) {
      lines.push(`Run \`${command}\``);
    }
  }
  return lines;
}

// ---------------------------------------------------------------------------
// Tier B: the forced-tool-call patch adapter, ported from
// `MaintainFixAdapter.swift`. Structurally different plumbing from
// `model-provider.ts`'s plain conversational `respond()` — this needs a
// forced tool call with a fixed input schema, not free text — so it is not
// built on `MaintainModelProviding`.
// ---------------------------------------------------------------------------

/** What the adapter produced: a diff to try, or the honest reasons not to.
 *  Mirrors Swift's `MaintainFixAdaptation` enum. */
export type MaintainFixAdaptation =
  | { readonly type: "adaptedPatch"; readonly unifiedDiff: string }
  | { readonly type: "modelCouldNotAdapt"; readonly reason: string }
  | { readonly type: "noBringYourOwnKeyAvailable" };

/** Tier B's collaborator interface. `RecipeReplayEngine` is injected with one
 *  of these (or `undefined`) — mirrors Swift's `MaintainFixAdapting`
 *  protocol. */
export interface MaintainFixAdapting {
  adaptPatch(options: {
    readonly diagnosis: string | null;
    readonly stalePatch: string;
    readonly localFileExcerpts: string;
    readonly appSlug: string;
  }): Promise<MaintainFixAdaptation>;
}

/** A fixed pipeline, not an agent: no loop, no exploration, no shell access,
 *  hard output cap. Matches Swift's `MaintainFixAdapter.maximumOutputTokensPerAdaptCall`. */
const MAXIMUM_OUTPUT_TOKENS_PER_ADAPT_CALL = 1500;

/** Matches `model-provider.ts`'s own constant — kept as a separate local copy
 *  rather than an import, since the two files are independently portable
 *  pieces of the same fan-out and this is the Windows app's one existing
 *  default model (`src/main/settings.ts`), not shared wire vocabulary. */
const MAINTAIN_ANTHROPIC_MODEL_ID = "claude-sonnet-4-5-20250929";

const ADAPT_PATCH_SYSTEM_PROMPT =
  "You adapt a known bug fix to a slightly different version of the same " +
  "codebase. The fix below was verified on other machines; its line " +
  "anchors no longer match this machine's files. Produce the SAME change " +
  "re-anchored to the code as it looks now — never a different fix, never " +
  "additional changes, never touched files the original did not touch. " +
  "If the code has changed so much that the original fix no longer makes " +
  "sense, say so via cannot_adapt instead of guessing.\n" +
  "Call adapt_patch exactly once.";

const ADAPT_PATCH_TOOL = {
  name: "adapt_patch",
  description: "Return the known fix re-anchored to this machine's code, or decline.",
  input_schema: {
    type: "object",
    properties: {
      unified_diff: {
        type: "string",
        description:
          "The adapted fix as a unified diff against the files shown, same change, new anchors.",
      },
      cannot_adapt: {
        type: "string",
        description:
          "Set INSTEAD of unified_diff when the code has diverged past honest re-anchoring — one sentence why.",
      },
    },
  },
} as const;

/**
 * Ratified D4/D5: this call NEVER touches the funded tier. The transport it
 * builds is structurally BYO-only (`{ tier: "byo", anthropicApiKey }`), so
 * there is no branch that could reach publik's proxy — an absent key is a
 * terminal `noBringYourOwnKeyAvailable`, not a fallback.
 */
export class AnthropicPatchAdapter implements MaintainFixAdapting {
  constructor(
    private readonly readAnthropicApiKey: () => string | null,
    private readonly fetchImplementation: FetchLike = globalThis.fetch as unknown as FetchLike,
  ) {}

  async adaptPatch(options: {
    readonly diagnosis: string | null;
    readonly stalePatch: string;
    readonly localFileExcerpts: string;
    readonly appSlug: string;
  }): Promise<MaintainFixAdaptation> {
    const anthropicApiKey = this.readAnthropicApiKey();
    if (anthropicApiKey === null || anthropicApiKey.length === 0) {
      return { type: "noBringYourOwnKeyAvailable" };
    }

    const report = [
      `App: ${options.appSlug}`,
      "Root-cause diagnosis from the pooled recipe:",
      options.diagnosis ?? "(none recorded)",
      "",
      "The verified-but-stale unified diff:",
      "```",
      options.stalePatch.slice(0, 8000),
      "```",
      "",
      "The touched files as they look on THIS machine today:",
      "```",
      options.localFileExcerpts.slice(0, 12000),
      "```",
    ].join("\n");

    const transport: AssistantTransport = { tier: "byo", anthropicApiKey };
    let preparedRequest: Awaited<ReturnType<typeof makeChatRequest>>;
    try {
      preparedRequest = await makeChatRequest(transport);
    } catch (error) {
      return { type: "modelCouldNotAdapt", reason: error instanceof Error ? error.message : String(error) };
    }
    if (!preparedRequest.headers["anthropic-version"]) {
      preparedRequest.headers["anthropic-version"] = ANTHROPIC_API_VERSION;
    }

    const body = {
      model: MAINTAIN_ANTHROPIC_MODEL_ID,
      max_tokens: MAXIMUM_OUTPUT_TOKENS_PER_ADAPT_CALL,
      system: ADAPT_PATCH_SYSTEM_PROMPT,
      messages: [{ role: "user", content: report }],
      tools: [ADAPT_PATCH_TOOL],
      tool_choice: { type: "tool", name: "adapt_patch" },
    };

    let response: Awaited<ReturnType<FetchLike>>;
    try {
      response = await this.fetchImplementation(preparedRequest.url, {
        method: preparedRequest.method,
        headers: preparedRequest.headers,
        body: JSON.stringify(body),
      });
    } catch (error) {
      return { type: "modelCouldNotAdapt", reason: error instanceof Error ? error.message : String(error) };
    }

    const rawResponseBody = await response.text();
    if (!response.ok) {
      return { type: "modelCouldNotAdapt", reason: `HTTP ${response.status}` };
    }

    let parsedResponseBody: {
      content?: Array<{ type: string; name?: string; input?: Record<string, unknown> }>;
    };
    try {
      parsedResponseBody = JSON.parse(rawResponseBody);
    } catch {
      return { type: "modelCouldNotAdapt", reason: "unparseable response" };
    }

    const toolUseBlock = (parsedResponseBody.content ?? []).find(
      (block) => block.type === "tool_use" && block.name === "adapt_patch",
    );
    const input = toolUseBlock?.input;
    if (input === undefined) {
      return { type: "modelCouldNotAdapt", reason: "no adapt_patch call in the response" };
    }

    const cannotAdapt = input.cannot_adapt;
    if (typeof cannotAdapt === "string" && cannotAdapt.length > 0) {
      return { type: "modelCouldNotAdapt", reason: cannotAdapt };
    }

    const unifiedDiff = input.unified_diff;
    if (typeof unifiedDiff !== "string" || !unifiedDiff.includes("--- ") || !unifiedDiff.includes("+++ ")) {
      return { type: "modelCouldNotAdapt", reason: "response carried no usable diff" };
    }
    return { type: "adaptedPatch", unifiedDiff };
  }
}

// ---------------------------------------------------------------------------
// Small local helpers
// ---------------------------------------------------------------------------

/**
 * Quotes a value as a PowerShell single-quoted string (doubling embedded
 * quotes) — the same escaping `main/powershell-session.ts`'s `psSingleQuote`
 * uses, duplicated here rather than imported so this file stays free of a
 * `main/` dependency: `services/` must not depend on `main/`, matching the
 * layering `iris-windows/CLAUDE.md` documents.
 */
function powerShellSingleQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

/**
 * The files a diff touches, as they look on THIS machine — the Tier B adapt
 * call's grounding. Paths come from the diff's own `+++` headers, resolved
 * under the clone only; anything escaping the root is skipped. Ported from
 * Swift's `RecipeReplayEngine.localFileExcerpts(forPatch:clonePath:)`.
 */
async function localFileExcerptsForPatch(patchText: string, clonePath: string): Promise<string> {
  const root = path.resolve(clonePath);
  const excerpts: string[] = [];
  for (const line of patchText.split("\n")) {
    if (!line.startsWith("+++ ")) continue;
    let relativePath = line.slice(4).trim();
    if (relativePath.startsWith("b/")) relativePath = relativePath.slice(2);
    if (relativePath === "/dev/null" || relativePath.length === 0) continue;

    const fullPath = path.resolve(root, relativePath);
    if (fullPath !== root && !fullPath.startsWith(root + path.sep)) continue; // escapes the clone root

    try {
      const contents = await fs.readFile(fullPath, "utf-8");
      excerpts.push(`=== ${relativePath} ===\n${contents.slice(0, 6000)}`);
    } catch {
      // Not present on this machine (new file, or already deleted) — nothing
      // to excerpt; the adapt call still sees the diff itself.
    }
  }
  return excerpts.join("\n\n");
}

/** UTC `yyyyMMdd`, matching Swift's `compactDateStamp()` (also UTC). */
function compactDateStamp(now: Date = new Date()): string {
  const year = now.getUTCFullYear();
  const month = String(now.getUTCMonth() + 1).padStart(2, "0");
  const day = String(now.getUTCDate()).padStart(2, "0");
  return `${year}${month}${day}`;
}

// ---------------------------------------------------------------------------
// RecipeReplayEngine
// ---------------------------------------------------------------------------

export class RecipeReplayEngine {
  private readonly provenanceStore: InstallProvenanceStore;
  private readonly poolClient: MaintainPoolClient;
  private readonly getCurrentInstallId: () => string;
  private readonly patchQueue: PatchQueue;
  private readonly createShellRunner: (repoRootPath: string) => MaintainShellRunner | undefined;
  private readonly verificationCommandsForStack: (
    appStack: BreakAppStack,
    repoRootPath: string,
  ) => VerificationCommands;
  /** Tier B, present only when the build wires a BYO model credential.
   *  `undefined` = stale recipes end at "didn't apply" — the funded tier's
   *  honest ceiling, matching Swift's `fixAdapter: MaintainFixAdapting? = nil`. */
  private readonly fixAdapter: MaintainFixAdapting | undefined;

  constructor(options: {
    readonly provenanceStore: InstallProvenanceStore;
    readonly poolClient: MaintainPoolClient;
    /** Resolves this install's pseudonymous id at the moment it is needed —
     *  injected as a closure rather than a `MaintainStateStore` reference so
     *  this engine stays decoupled from exactly how install identity is
     *  persisted. Real composition: `() => maintainInstallIdentity.currentInstallId()`
     *  (`install-identity.ts`'s `MaintainInstallIdentity`). */
    readonly getCurrentInstallId: () => string;
    readonly patchQueue: PatchQueue;
    /** Builds a shell rooted at a clone path, or `undefined` when it cannot
     *  (mirrors Swift's `try? MaintainShellRunner(repoRootPath: clonePath)`). */
    readonly createShellRunner: (repoRootPath: string) => MaintainShellRunner | undefined;
    /** Resolves the per-stack build/test vocabulary for one repo root. */
    readonly verificationCommandsForStack: (
      appStack: BreakAppStack,
      repoRootPath: string,
    ) => VerificationCommands;
    readonly fixAdapter?: MaintainFixAdapting;
  }) {
    this.provenanceStore = options.provenanceStore;
    this.poolClient = options.poolClient;
    this.getCurrentInstallId = options.getCurrentInstallId;
    this.patchQueue = options.patchQueue;
    this.createShellRunner = options.createShellRunner;
    this.verificationCommandsForStack = options.verificationCommandsForStack;
    this.fixAdapter = options.fixAdapter;
  }

  async replay(options: {
    readonly recipe: PooledFixRecipe;
    readonly appSlug: string;
    readonly appStack: BreakAppStack;
    readonly installedAppVersion: string | null;
    readonly signatureId: string;
    /** `machineArchitecture()` (`install-identity.ts`) in real use — injected
     *  as a plain value here so applicability matching is pinnable in tests,
     *  mirroring `AutopilotRunner`'s `platform` parameter. */
    readonly machineArchitecture: string;
  }): Promise<RecipeReplayResult> {
    const { recipe, appSlug, appStack, installedAppVersion, signatureId, machineArchitecture } = options;

    if (
      !recipeApplicabilityMatches({
        applicability: recipe.applicability,
        appVersion: installedAppVersion,
        architecture: machineArchitecture,
      })
    ) {
      maintainTrace(`maintain: recipe ${recipe.id} refused — outside applicability range`);
      return { type: "outsideApplicabilityRange" };
    }

    // The non-patch families are guidance, never execution.
    if (recipe.recipeType !== "patch_pr") {
      return { type: "guidanceToShow", steps: extractRecipeGuidanceSteps(recipe.recipe) };
    }

    if (!this.provenanceStore.localPatchingIsPermitted(appSlug)) {
      return { type: "patchingNotPermittedForThisInstall" };
    }
    const record = this.provenanceStore.provenanceForAppSlug(appSlug);
    const clonePath = record?.clonePath;
    if (clonePath === undefined || clonePath === null) {
      return { type: "patchingNotPermittedForThisInstall" };
    }

    const patchText = recipe.patchSpecific;
    if (patchText === null || patchText === undefined || patchText.length === 0) {
      return { type: "patchDidNotApply" };
    }

    const runner = this.createShellRunner(clonePath);
    if (runner === undefined) {
      return { type: "patchingNotPermittedForThisInstall" };
    }

    // Tier A: the exact pooled diff.
    const exactResult = await this.applyVerifyAndCommit({
      patchText,
      recipe,
      appSlug,
      appStack,
      signatureId,
      runner,
      clonePath,
      wasAdapted: false,
    });
    if (exactResult.type !== "patchDidNotApply") {
      return exactResult;
    }

    // Tier B: the diff is stale for this version — one constrained BYO model
    // call re-anchors it, seeded with the pooled diagnosis. Absent an
    // adapter (or a key), stale is the honest end of the road.
    if (this.fixAdapter === undefined) {
      return { type: "patchDidNotApply" };
    }
    const localFileExcerpts = await localFileExcerptsForPatch(patchText, clonePath);
    const adaptation = await this.fixAdapter.adaptPatch({
      diagnosis: recipe.diagnosis,
      stalePatch: patchText,
      localFileExcerpts,
      appSlug,
    });
    if (adaptation.type !== "adaptedPatch") {
      if (adaptation.type === "modelCouldNotAdapt") {
        maintainTrace(`maintain: adapt_patch declined — ${adaptation.reason}`);
      }
      return { type: "patchDidNotApply" };
    }

    maintainTrace(`maintain: recipe ${recipe.id} adapted via BYO — retrying apply`);
    return this.applyVerifyAndCommit({
      patchText: adaptation.unifiedDiff,
      recipe,
      appSlug,
      appStack,
      signatureId,
      runner,
      clonePath,
      wasAdapted: true,
    });
  }

  /**
   * The shared spine both tiers ride: dry-run, apply, verify (revert on
   * failure), commit on a recipe-keyed branch, queue the patch, file the
   * outcome. `wasAdapted` only changes the bookkeeping words — ported from
   * Swift's `applyVerifyAndCommit`.
   */
  private async applyVerifyAndCommit(options: {
    readonly patchText: string;
    readonly recipe: PooledFixRecipe;
    readonly appSlug: string;
    readonly appStack: BreakAppStack;
    readonly signatureId: string;
    readonly runner: MaintainShellRunner;
    readonly clonePath: string;
    readonly wasAdapted: boolean;
  }): Promise<RecipeReplayResult> {
    const { patchText, recipe, appSlug, appStack, signatureId, runner, clonePath, wasAdapted } = options;

    // Write the patch inside the repo (the runner's boundary); cleaned up
    // whatever happens below.
    const patchFileName = `.iris-replay-${recipe.id}.patch`;
    const patchFilePath = path.join(clonePath, patchFileName);
    try {
      await fs.writeFile(patchFilePath, patchText, "utf-8");
    } catch {
      return { type: "patchDidNotApply" };
    }

    try {
      // Dry-run first: --check answers "would this apply" without touching
      // the tree, so a stale recipe never leaves half a patch behind.
      const dryRun = await tryRun(
        runner,
        `git apply --check --3way ${powerShellSingleQuote(patchFileName)}`,
        { deadlineMs: 60_000 },
      );
      if (dryRun?.succeeded !== true) {
        if (!wasAdapted) {
          maintainTrace(`maintain: recipe ${recipe.id} stale — did not apply (3way check failed)`);
          await this.fileOutcome(recipe.id, false);
        }
        return { type: "patchDidNotApply" };
      }

      const headResult = await tryRun(runner, "git rev-parse HEAD", { deadlineMs: 30_000 });
      const baseCommit = headResult?.outputTail.trim() ?? "";

      const applied = await tryRun(runner, `git apply --3way ${powerShellSingleQuote(patchFileName)}`, {
        deadlineMs: 60_000,
      });
      if (applied?.succeeded !== true) {
        await this.fileOutcome(recipe.id, false);
        return { type: "patchDidNotApply" };
      }
      await this.fileOutcome(recipe.id, true);

      // Replay standard: build + suite. No repro test rode along, so the
      // three legs are structurally impossible here — and the outcome kind
      // stays 'applied', never 'verified', for exactly that reason.
      const commands = this.verificationCommandsForStack(appStack, clonePath);
      const verification: VerificationOutcome = await verifyAppliedPatch(runner, commands, undefined);

      if (!earnsCleanApply(verification)) {
        // `&&` is not reliable in Windows PowerShell 5.1 — two separate
        // steps rather than Swift's `checkout -- . && clean -fd`.
        await tryRun(runner, "git checkout -- .", { deadlineMs: 120_000 });
        await tryRun(runner, "git clean -fd --quiet", { deadlineMs: 120_000 });
        await this.fileOutcome(recipe.id, false);
        return {
          type: "patchRevertedAfterFailedVerification",
          blockedStage: verification.blockedStage ?? "unknown",
        };
      }

      // Commit on a recipe-keyed branch — the fork service (a later
      // increment) pushes it.
      const dateStamp = compactDateStamp();
      const branchName = `iris/fix-${signatureId.slice(0, 12)}-${dateStamp}`;
      const provenanceWord = wasAdapted ? "adapted from" : "replayed";
      const commitMessage =
        `Apply pooled fix recipe ${recipe.id}\n\n` +
        `Break-Signature: ${signatureId}\n` +
        `Fix-Recipe-Match: ${recipe.id}${wasAdapted ? " (adapted)" : ""}\n` +
        `Verified: applied, build-green${verification.suitePassed === true ? ", suite-green" : ""}\n` +
        `Assisted-by: iris-maintain-mode/1\n` +
        `Modified-by: Iris (publik) — ${provenanceWord} a pooled recipe`;

      // No `||`, either: check whether the branch exists first, then take
      // exactly one of create/switch — same outcome as Swift's
      // `checkout -b X 2>/dev/null || checkout X`, PowerShell-native.
      const branchExists = await tryRun(
        runner,
        `git rev-parse --verify --quiet ${powerShellSingleQuote(branchName)}`,
        { deadlineMs: 30_000 },
      );
      if (branchExists?.succeeded === true) {
        await tryRun(runner, `git checkout ${powerShellSingleQuote(branchName)}`, { deadlineMs: 30_000 });
      } else {
        await tryRun(runner, `git checkout -b ${powerShellSingleQuote(branchName)}`, { deadlineMs: 30_000 });
      }
      await tryRun(runner, "git add -A", { deadlineMs: 60_000 });
      await tryRun(runner, `git commit -m ${powerShellSingleQuote(commitMessage)} --quiet`, {
        deadlineMs: 60_000,
      });

      try {
        this.patchQueue.record({
          recipeId: recipe.id,
          signatureId,
          appSlug,
          branchName,
          patchText,
          baseCommit: baseCommit.length > 0 ? baseCommit : undefined,
          appliedAt: new Date().toISOString(),
        });
      } catch {
        // A patch that fails to queue still applied and verified; the branch
        // exists in the clone even if Iris cannot track it for a future
        // upstream replay. Bookkeeping loss, not a fix failure.
      }

      await this.fileOutcome(recipe.id, true);
      maintainTrace(`maintain: recipe ${recipe.id} ${provenanceWord} and committed on ${branchName}`);
      return { type: "patchAppliedAndVerified", branchName };
    } finally {
      try {
        await fs.rm(patchFilePath, { force: true });
      } catch {
        // Best-effort cleanup; a leftover `.iris-replay-*.patch` file is
        // harmless and gets overwritten by the next attempt.
      }
    }
  }

  /**
   * Records a recipe outcome with this install's pseudonymous id.
   * `MaintainPoolClient.fileRecipeOutcome` is itself not-throwing by design
   * (fire-and-forget, matches Swift's `_ = try? await ...`), so there is
   * nothing further to swallow here — this method exists only to fold the
   * `recipeId, succeeded, installId` call shape into one place.
   */
  private async fileOutcome(recipeId: string, succeeded: boolean): Promise<void> {
    await this.poolClient.fileRecipeOutcome(recipeId, succeeded, this.getCurrentInstallId());
  }
}
