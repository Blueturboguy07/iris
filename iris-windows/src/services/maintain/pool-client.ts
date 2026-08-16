/**
 * pool-client.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/MaintainPoolClient.swift`. This
 * is maintain mode's window onto the shared recipe pool: one GET that must
 * answer before any model token is spent, plus the POSTs that file what a user
 * confirmed, record an outcome, flag a bad recipe, log a fix, and pool a
 * feature wish.
 *
 * All of it speaks to publik's routing API — the same base URL every other
 * publik call in this app uses (`assistant-transport.ts`'s
 * `DEFAULT_PUBLIK_BASE_URL`, overridable exactly the way that module's caller
 * overrides it). No credentials ride along on any of these calls: every route
 * under `/api/iris/*` is CORS-open and rate-limited server-side by IP, not by
 * a bearer token. The BYO Anthropic key and the Supabase session never appear
 * in this file, or anywhere near it.
 *
 * Wire shapes are copied verbatim from `app/api/iris/*` (read directly, not
 * inferred) — no invented fields, no dropped validation. Every route in this
 * app's own JSON bodies is already camelCase (the server is Next.js, not a
 * snake_case backend), so unlike `account-service.ts` (which talks to
 * Supabase) there is no camelCase/snake_case boundary to cross here, with the
 * one deliberate exception of `topFrames[].is_app_frame`, which is left
 * snake_case because that is the literal key the intake route expects on the
 * wire — see `app/api/iris/breaks/route.ts`.
 *
 * Every network call in this file is not-throwing by design, matching the
 * Swift original's stance exactly: a pool lookup that fails is treated as a
 * pool that had nothing ("could not check" == "nothing found," because both
 * lead to the same next rung of the fix ladder), and a fire-and-forget POST
 * (outcome, fix-log) that fails costs the pool one data point, never the user
 * an error. `fetchImplementation` is injected (mirrors `FetchLike` in
 * `claude.ts` and `TokenFetchLike` in `account-service.ts`), so the whole file
 * is testable without a network and runs identically in the vitest suite on
 * macOS and on windows-latest CI.
 *
 * Build order (porting spec §6, tier 3): this file has exactly two internal
 * dependencies, `assistant-transport.ts` (for `DEFAULT_PUBLIK_BASE_URL`) and
 * `trace.ts`. It deliberately does NOT import `break-signature.ts` — the wire
 * vocabulary types below (`MaintainBreakAppStack`, `MaintainBreakSignatureKind`)
 * are declared locally instead. TypeScript's structural typing means
 * `break-signature.ts`'s own equivalents satisfy these without either file
 * importing the other, which keeps this transport layer buildable and testable
 * on its own, ahead of the signature/incident layers that depend on it. The
 * *strings* are the real contract (see the note on those types below), not the
 * type names.
 */

import { DEFAULT_PUBLIK_BASE_URL } from "../assistant-transport";
import { maintainTrace } from "./trace";

/** Where publik lives when nothing overrides it. A derived re-export of
 *  `assistant-transport.ts`'s `DEFAULT_PUBLIK_BASE_URL` — not a re-stated
 *  literal — so the two can never quietly drift apart. */
export const DEFAULT_MAINTAIN_POOL_BASE_URL = DEFAULT_PUBLIK_BASE_URL;

/**
 * The fetch seam. Shaped like `FetchLike` in `claude.ts` and `TokenFetchLike`
 * in `account-service.ts` — a minimal subset of the real `fetch` signature,
 * so a test can supply a hand-written fake with no `Response` object, no
 * headers iterator, nothing beyond what this file actually reads.
 */
export type MaintainPoolFetchLike = (
  url: string,
  init: { readonly method: string; readonly headers?: Record<string, string>; readonly body?: string }
) => Promise<{
  readonly ok: boolean;
  readonly status: number;
  readonly text: () => Promise<string>;
}>;

export interface MaintainPoolClientOptions {
  readonly publikBaseUrl?: string;
  readonly fetchImplementation?: MaintainPoolFetchLike;
}

/**
 * The wire vocabulary for a break's app stack and signature kind — byte-
 * identical to Swift and to the server's `signatures` table check constraints
 * (porting spec §3). These are cross-client shared vocabulary, never re-cased
 * or renamed, and `"swift-macos"` stays in the union even though this client
 * never emits it: dropping it would make the type lie about what the
 * `signatures.app_stack` column accepts.
 */
export type MaintainBreakAppStack = "tauri" | "electron" | "nextjs" | "swift-macos" | "other";

export type MaintainBreakSignatureKind =
  | "native-crash"
  | "rust-panic"
  | "js-exception"
  | "hang"
  | "oom"
  | "launch-failure"
  | "log-pattern";

// MARK: - GET /api/iris/recipes (the hot path)

/** What `lookupRecipes` needs from a break signature. Deliberately a narrow,
 *  locally-declared shape rather than an import of `BreakSignature` — see the
 *  file header on why this file has no internal dependency beyond
 *  `assistant-transport.ts`/`trace.ts`. */
export interface RecipeCacheLookupKey {
  readonly appSlug: string;
  readonly signatureId?: string | null;
  readonly fingerprintStrict?: string | null;
  readonly fingerprintLoose?: string | null;
}

/** Which tier matched: `"signature"`, `"fingerprint_strict"`,
 *  `"fingerprint_loose"`, or `null` for a clean miss. */
export type RecipeCacheMatchedBy = "signature" | "fingerprint_strict" | "fingerprint_loose" | null;

export interface RecipeCacheAnswer {
  readonly recipes: readonly PooledFixRecipe[];
  readonly matchedBy: RecipeCacheMatchedBy;
}

/**
 * One pooled recipe, as `GET /api/iris/recipes` returns it. Field names
 * mirror the route's JSON exactly (porting spec §4) so nothing here needs a
 * translation layer. `recipe` and `applicability` are left `unknown` — opaque,
 * passed through exactly as received: `replay-engine.ts`'s
 * `extractRecipeGuidanceSteps` parses `recipe`, and `recipeApplicabilityMatches`
 * parses `applicability` defensively, unlike Swift's `Codable`-decoded typed
 * dictionary. This file has no business inspecting either.
 */
export interface PooledFixRecipe {
  readonly id: string;
  readonly breakId: string;
  readonly appSlug: string;
  readonly recipeType: string;
  readonly modelTier: string;
  readonly recipe: unknown;
  readonly status: string;
  readonly signatureId: string;
  readonly diagnosis: string | null;
  readonly patchSpecific: string | null;
  readonly patchBaseSha: string | null;
  readonly patchGeneral: string | null;
  readonly patchFormat: string | null;
  readonly applicability: unknown;
  readonly parentRecipeId: string | null;
  readonly reviewStatus: string;
  readonly verifiedFixes: number;
  readonly cleanApplies: number;
  readonly distinctInstallsAttempted: number;
  readonly score: number;
}

// MARK: - GET /api/iris/recipes/search (cold, human-facing)

export interface RecipeSearchQuery {
  readonly query?: string;
  readonly appSlug?: string;
  readonly stack?: string;
  readonly kind?: string;
  readonly recipeType?: string;
  readonly touchesFile?: string;
}

/** One row of `GET /api/iris/recipes/search`'s response — a deliberately
 *  narrower shape than `PooledFixRecipe`, because this route answers "have we
 *  seen anything like this?" for a human, not a machine-matched cache hit. */
export interface PooledRecipeSearchResult {
  readonly id: string;
  readonly appSlug: string;
  readonly recipeType: string;
  readonly status: string;
  readonly reviewStatus: string;
  readonly diagnosis: string | null;
  readonly touchedFiles: readonly string[];
  readonly stack: string;
  readonly kind: string;
  readonly verifiedFixes: number;
  readonly score: number;
}

export interface RecipeSearchAnswer {
  readonly recipes: readonly PooledRecipeSearchResult[];
  readonly count: number;
}

// MARK: - POST /api/iris/breaks

/** One entry of `topFrames`. */
export interface ConfirmedBreakTopFrame {
  readonly module: string;
  readonly function: string;
  readonly file: string;
  /** Deliberately snake_case — the literal key `app/api/iris/breaks/route.ts`
   *  reads off the wire (porting spec §4). Every other field in this body is
   *  camelCase; this is the one exception, and it must stay that way. */
  readonly is_app_frame: boolean;
}

/** The optional fix payload that rides along with a break filing when the
 *  incident coordinator already has a recipe to file in the same request. */
export interface ConfirmedBreakFixPayload {
  readonly recipeType: string;
  readonly patchSpecific?: string;
  readonly patchBaseSha?: string;
  readonly forkUrl?: string;
  readonly forkBranch?: string;
  readonly forkCommitSha?: string;
  readonly diagnosis?: string;
  /** Opaque — passed through exactly as the caller built it, same stance as
   *  `PooledFixRecipe.recipe`. */
  readonly recipe?: unknown;
  readonly applicability?: unknown;
  readonly verification?: unknown;
  readonly diffStat?: unknown;
  readonly patchGeneral?: string;
}

/**
 * The exact wire body of `POST /api/iris/breaks` (porting spec §4). Assembled
 * by the incident coordinator from a `BreakSignature` — this type only says
 * what has to land on the wire, not where it came from.
 */
export interface ConfirmedBreakFilingRequest {
  readonly appSlug: string;
  /** The signature id. Named `signature` here, not `signatureId`, because
   *  that is the literal body key the intake route reads. */
  readonly signature: string;
  readonly appStack: MaintainBreakAppStack;
  readonly signatureKind: MaintainBreakSignatureKind;
  readonly algoVersion: number;
  readonly fingerprintStrict: string;
  readonly fingerprintLoose: string;
  readonly title: string;
  readonly appVersion?: string;
  readonly protoSignature: string;
  readonly topFrames: readonly ConfirmedBreakTopFrame[];
  readonly fix?: ConfirmedBreakFixPayload;
}

export interface FileConfirmedBreakResult {
  readonly breakId: string;
  /** `null` when the filing carried no `fix`. */
  readonly recipeId: string | null;
}

// MARK: - POST /api/iris/recipes/{id}/flag

export type RecipeFlagResult =
  | { readonly kind: "alreadyFlaggedToday" }
  | { readonly kind: "recorded"; readonly status: string; readonly flagCount: number }
  | { readonly kind: "requestFailed" };

// MARK: - POST/GET /api/iris/feature-requests

export interface PoolFeatureWishInput {
  readonly appSlug: string;
  readonly signature: string;
  /** Already-normalized text (≤300 chars) — the server does not re-normalize. */
  readonly request: string;
  readonly installId: string;
}

export interface PoolFeatureWishResult {
  readonly requestId: string;
}

export interface PooledFeatureRequest {
  readonly id: string;
  readonly request: string;
  readonly installs: number;
  readonly implementedCount: number;
  readonly referenceForkUrl: string | null;
}

/**
 * HTTP client for the shared maintain-mode recipe pool. Every method takes no
 * credential and needs none — see the file header. Construct one per app
 * lifetime; it holds nothing but the base URL and the fetch seam.
 */
export class MaintainPoolClient {
  private readonly publikBaseUrl: string;
  private readonly fetchImplementation: MaintainPoolFetchLike;

  constructor(options: MaintainPoolClientOptions = {}) {
    this.publikBaseUrl = (options.publikBaseUrl ?? DEFAULT_MAINTAIN_POOL_BASE_URL).replace(/\/+$/, "");
    this.fetchImplementation = options.fetchImplementation ?? (globalThis.fetch as unknown as MaintainPoolFetchLike);
  }

  /**
   * The cache lookup — step one of every incident, zero tokens spent. A
   * network failure or non-200 response returns an empty answer rather than
   * throwing: the ladder treats "could not check the pool" exactly like "pool
   * had nothing," because both mean the same next step for the caller.
   */
  async lookupRecipes(key: RecipeCacheLookupKey): Promise<RecipeCacheAnswer> {
    const query = this.searchParams({
      app: key.appSlug,
      signature: key.signatureId ?? undefined,
      fs: key.fingerprintStrict ?? undefined,
      fl: key.fingerprintLoose ?? undefined,
    });
    const empty: RecipeCacheAnswer = { recipes: [], matchedBy: null };

    try {
      const response = await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/recipes?${query}`, {
        method: "GET",
      });
      if (!response.ok) {
        maintainTrace(`recipe lookup got HTTP ${response.status} — treating as miss`);
        return empty;
      }
      const parsed = await this.parseJson<{ recipes: unknown; matchedBy: unknown }>(response);
      if (parsed === null || !Array.isArray(parsed.recipes)) return empty;
      const matchedBy = parsed.matchedBy;
      return {
        recipes: parsed.recipes as PooledFixRecipe[],
        matchedBy:
          matchedBy === "signature" || matchedBy === "fingerprint_strict" || matchedBy === "fingerprint_loose"
            ? matchedBy
            : null,
      };
    } catch (error) {
      maintainTrace(`recipe lookup failed (${errorMessage(error)}) — treating as miss`);
      return empty;
    }
  }

  /**
   * The cold, human-facing search over the pool ("have we seen anything like
   * this?"), distinct from the hot exact-match `lookupRecipes` path above. Not
   * on the client-side fix ladder for M0–M9, but included here for
   * completeness rather than left as a gap — same not-throwing stance as
   * `lookupRecipes`, so it is safe to wire in later without a second failure
   * mode to design.
   */
  async searchRecipes(query: RecipeSearchQuery = {}): Promise<RecipeSearchAnswer> {
    const empty: RecipeSearchAnswer = { recipes: [], count: 0 };
    const searchParams = this.searchParams({
      q: query.query,
      app: query.appSlug,
      stack: query.stack,
      kind: query.kind,
      type: query.recipeType,
      file: query.touchesFile,
    });

    try {
      const response = await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/recipes/search?${searchParams}`, {
        method: "GET",
      });
      if (!response.ok) {
        maintainTrace(`recipe search got HTTP ${response.status} — treating as empty`);
        return empty;
      }
      const parsed = await this.parseJson<{ recipes: unknown; count: unknown }>(response);
      if (parsed === null || !Array.isArray(parsed.recipes)) return empty;
      return {
        recipes: parsed.recipes as PooledRecipeSearchResult[],
        count: typeof parsed.count === "number" ? parsed.count : parsed.recipes.length,
      };
    } catch (error) {
      maintainTrace(`recipe search failed (${errorMessage(error)}) — treating as empty`);
      return empty;
    }
  }

  /**
   * Files a confirmed break. Returns the created break id (and a recipe id
   * when a fix rode along), or `null` when the intake refused the request or
   * the network failed — the caller stages the filing locally and retries on
   * the next incident rather than looping here, matching Swift's contract on
   * `fileConfirmedBreak`.
   */
  async fileConfirmedBreak(filing: ConfirmedBreakFilingRequest): Promise<FileConfirmedBreakResult | null> {
    try {
      const response = await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/breaks`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(filing),
      });
      if (response.status !== 201) {
        maintainTrace(`break filing got HTTP ${response.status}`);
        return null;
      }
      const parsed = await this.parseJson<{ breakId: unknown; recipeId: unknown }>(response);
      if (parsed === null || typeof parsed.breakId !== "string") return null;
      return {
        breakId: parsed.breakId,
        recipeId: typeof parsed.recipeId === "string" ? parsed.recipeId : null,
      };
    } catch (error) {
      maintainTrace(`break filing failed (${errorMessage(error)})`);
      return null;
    }
  }

  /**
   * Records a recipe outcome under this install's pseudonymous id — the
   * signal that promotes a recipe across DISTINCT machines. Fire and forget,
   * exactly like Swift's `_ = try? await urlSession.data(for: request)`: an
   * outcome that never lands costs the pool one data point, never the user an
   * error. `installId` is optional but load-bearing: an outcome without it
   * bumps counters but can never promote a recipe (promotion needs distinct-
   * install successes).
   */
  async fileRecipeOutcome(recipeId: string, succeeded: boolean, installId?: string): Promise<void> {
    try {
      await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/recipes/${encodeURIComponent(recipeId)}/outcome`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(installId ? { succeeded, installId } : { succeeded }),
      });
    } catch (error) {
      maintainTrace(`recipe outcome post failed (${errorMessage(error)}) — dropped, not retried`);
    }
  }

  /**
   * Flags a recipe as bad. Unlike the outcome/fix-log posts this one DOES
   * surface its result: the caller's UI has something specific to say for
   * "you already flagged this today" versus "flag recorded."
   */
  async flagRecipe(recipeId: string): Promise<RecipeFlagResult> {
    try {
      const response = await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/recipes/${encodeURIComponent(recipeId)}/flag`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      if (response.status === 429) {
        return { kind: "alreadyFlaggedToday" };
      }
      if (!response.ok) {
        maintainTrace(`recipe flag got HTTP ${response.status}`);
        return { kind: "requestFailed" };
      }
      const parsed = await this.parseJson<{ status: unknown; flagCount: unknown }>(response);
      if (parsed === null || typeof parsed.status !== "string" || typeof parsed.flagCount !== "number") {
        return { kind: "requestFailed" };
      }
      return { kind: "recorded", status: parsed.status, flagCount: parsed.flagCount };
    } catch (error) {
      maintainTrace(`recipe flag failed (${errorMessage(error)})`);
      return { kind: "requestFailed" };
    }
  }

  /**
   * Records that a fix reached the canonical repo, for the public fix log —
   * the listing's "here's what we fixed" surface. Fire and forget, exactly
   * like Swift's `recordFixLog`: the break-status flip to "fixed in vX" is the
   * release webhook's job, this is only the human-readable companion.
   */
  async recordFixLog(appSlug: string, diagnosisTitle: string, repo: string): Promise<void> {
    try {
      await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/fix-log`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ appSlug, title: diagnosisTitle, repo }),
      });
    } catch (error) {
      maintainTrace(`fix-log post failed (${errorMessage(error)}) — dropped, not retried`);
    }
  }

  /**
   * Pools one feature wish against a break signature. Returns the created
   * request id, or `null` on refusal/network failure — same staged-for-retry
   * contract as `fileConfirmedBreak`. This is only the wire call: the regex
   * heuristics that decide a message "looks like a feature wish" and the
   * templating that produces `request` live in `maintain-feature-requests.ts`
   * (a separate porting task), not here.
   */
  async poolFeatureWish(input: PoolFeatureWishInput): Promise<PoolFeatureWishResult | null> {
    try {
      const response = await this.fetchImplementation(`${this.publikBaseUrl}/api/iris/feature-requests`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(input),
      });
      if (response.status !== 201) {
        maintainTrace(`feature-request post got HTTP ${response.status}`);
        return null;
      }
      const parsed = await this.parseJson<{ requestId: unknown }>(response);
      if (parsed === null || typeof parsed.requestId !== "string") return null;
      return { requestId: parsed.requestId };
    } catch (error) {
      maintainTrace(`feature-request post failed (${errorMessage(error)})`);
      return null;
    }
  }

  /**
   * The top pooled feature requests for an app — what Iris can surface as
   * "most people who run this app also wanted X." A miss and a failure read
   * the same to the caller: an empty list. The server enforces the k≥5 public
   * floor (`MINIMUM_INSTALLS_FOR_PUBLIC`) — this file does not re-implement
   * that floor client-side, per porting spec §4 ("duplicating a server
   * invariant is how the two drift").
   */
  async topFeatureRequests(appSlug: string): Promise<readonly PooledFeatureRequest[]> {
    try {
      const response = await this.fetchImplementation(
        `${this.publikBaseUrl}/api/iris/feature-requests?${this.searchParams({ app: appSlug })}`,
        { method: "GET" }
      );
      if (!response.ok) {
        maintainTrace(`feature-request lookup got HTTP ${response.status} — treating as empty`);
        return [];
      }
      const parsed = await this.parseJson<{ requests: unknown }>(response);
      if (parsed === null || !Array.isArray(parsed.requests)) return [];
      return parsed.requests as PooledFeatureRequest[];
    } catch (error) {
      maintainTrace(`feature-request lookup failed (${errorMessage(error)}) — treating as empty`);
      return [];
    }
  }

  /** Query-string builder that drops `undefined`/empty values, so an absent
   *  optional key is genuinely absent from the URL rather than sent as the
   *  literal string `"undefined"`. */
  private searchParams(params: Record<string, string | undefined>): string {
    const searchParams = new URLSearchParams();
    for (const [name, value] of Object.entries(params)) {
      if (value !== undefined && value.length > 0) searchParams.set(name, value);
    }
    return searchParams.toString();
  }

  /** A response body that is not valid JSON is treated as absent rather than
   *  thrown — every caller above already has a "miss" value ready. */
  private async parseJson<T>(response: { text: () => Promise<string> }): Promise<T | null> {
    try {
      const raw = await response.text();
      return JSON.parse(raw) as T;
    } catch {
      return null;
    }
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
