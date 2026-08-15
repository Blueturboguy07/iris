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
 */

import { DEFAULT_PUBLIK_BASE_URL } from "../assistant-transport";
import { maintainTrace } from "./trace";
import type { BreakAppStack, BreakSignatureKind } from "./break-signature";

/** Injected so the client is testable without a network. Deliberately narrow
 *  — just enough of `fetch`'s shape for a JSON request/response round trip. */
export type FetchLike = (
  url: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string }
) => Promise<{ ok: boolean; status: number; text: () => Promise<string> }>;

/** Where publik lives when nothing overrides it. A derived re-export of
 *  `assistant-transport.ts`'s `DEFAULT_PUBLIK_BASE_URL` — not a re-stated
 *  literal — so the two can never quietly drift apart. */
export const DEFAULT_MAINTAIN_POOL_BASE_URL = DEFAULT_PUBLIK_BASE_URL;

// MARK: - GET /api/iris/recipes

/** One pooled recipe, exactly as the read route returns it (field names
 *  mirror the route's JSON so this stays boring to keep in sync). `recipe` and
 *  the other opaque JSON columns are typed `unknown` and passed through
 *  untouched — the renderer that turns a recipe into guide steps owns parsing
 *  it, not this transport. This is the TS answer to Swift's `AnyDecodableJSON`
 *  workaround: TypeScript's structural `unknown` already does what that
 *  `Codable`-shaped box existed to fake. */
export interface PooledFixRecipe {
  readonly id: string;
  readonly breakId: string | null;
  readonly appSlug: string;
  readonly recipeType: "workaround" | "config_change" | "update_app" | "patch_pr";
  readonly modelTier: string;
  readonly recipe: unknown;
  readonly status: string;
  readonly signatureId: string | null;
  readonly diagnosis: string | null;
  readonly patchSpecific: string | null;
  readonly patchBaseSha: string | null;
  readonly patchGeneral: unknown;
  readonly patchFormat: string;
  readonly applicability: unknown;
  readonly parentRecipeId: string | null;
  readonly reviewStatus: string;
  readonly verifiedFixes: number;
  readonly cleanApplies: number;
  readonly distinctInstallsAttempted: number;
  readonly score: number;
}

/** Which tier of the match ladder actually answered — an exact signature hit
 *  means something different to the caller than a loose-fingerprint hit does,
 *  so this rides back alongside the recipes rather than being inferred. */
export type RecipeCacheMatchedBy = "signature" | "fingerprint_strict" | "fingerprint_loose" | null;

export interface RecipeCacheAnswer {
  readonly recipes: readonly PooledFixRecipe[];
  readonly matchedBy: RecipeCacheMatchedBy;
}

/** What identifies a break for the cache lookup. At least one of `signatureId`
 *  / `fingerprintStrict` / `fingerprintLoose` must be present or the server
 *  refuses the request with `no_lookup_key` — this client does not pre-empt
 *  that check locally; it sends whatever it was given and lets the server be
 *  the single source of truth for validation, exactly as `assistant-
 *  transport.ts` leaves status-code interpretation to `failureForStatusCode`
 *  rather than duplicating server logic client-side. */
export interface RecipeLookupKey {
  readonly appSlug: string;
  readonly signatureId?: string | null;
  readonly fingerprintStrict?: string | null;
  readonly fingerprintLoose?: string | null;
}

// MARK: - GET /api/iris/recipes/search

export interface RecipeSearchQuery {
  readonly query?: string;
  readonly appSlug?: string;
  readonly stack?: string;
  readonly kind?: string;
  readonly recipeType?: string;
  readonly touchesFile?: string;
}

export interface RecipeSearchResult {
  readonly id: string;
  readonly appSlug: string;
  readonly recipeType: string;
  readonly status: string;
  readonly reviewStatus: string;
  readonly diagnosis: string | null;
  readonly touchedFiles: readonly string[];
  readonly stack: string | null;
  readonly kind: string | null;
  readonly verifiedFixes: number;
  readonly score: number;
}

export interface RecipeSearchAnswer {
  readonly recipes: readonly RecipeSearchResult[];
  readonly count: number;
}

// MARK: - POST /api/iris/breaks

/** A single top frame, as the intake route's `topFrames` array expects it.
 *  `is_app_frame` is left snake_case deliberately — see the file header. */
export interface ConfirmedBreakFrame {
  readonly module: string;
  readonly function: string;
  readonly file: string;
  readonly is_app_frame: boolean;
}

/** The optional fix that rides along with a confirmed break filing. Present
 *  only when maintain mode actually produced or found a fix for the break it
 *  is reporting. */
export interface ConfirmedBreakFixBody {
  readonly recipeType: "workaround" | "config_change" | "update_app" | "patch_pr";
  readonly patchSpecific?: string;
  readonly patchBaseSha?: string;
  readonly recipe?: unknown;
  readonly diagnosis?: string;
  readonly applicability?: unknown;
  readonly forkUrl?: string;
  readonly forkBranch?: string;
  readonly forkCommitSha?: string;
  readonly verification?: unknown;
  readonly diffStat?: unknown;
  readonly patchGeneral?: unknown;
}

/**
 * What the intake route needs to know about a confirmed break. Assembled by
 * the incident coordinator from a `BreakSignature`; only structural fields —
 * the scrub pipeline runs before anything lands here, matching Swift's
 * `ConfirmedBreakFiling`. `appStack`/`signatureKind` reuse `break-signature.ts`'s
 * shared wire-vocabulary types directly (they mirror the server's check
 * constraints, per that module's own header) rather than restating the same
 * literal unions here, so the two can never quietly drift apart. This type
 * otherwise stays its own flattened wire shape rather than embedding a full
 * `BreakSignature` — whoever wires the incident coordinator up assembles one
 * of these from a `BreakSignature`.
 */
export interface ConfirmedBreakFilingBody {
  readonly appSlug: string;
  readonly signature: string;
  readonly appStack: BreakAppStack;
  readonly signatureKind: BreakSignatureKind;
  /** Windows starts its own counter at 1 — see `WINDOWS_SIGNATURE_ALGO_VERSION`
   *  in `break-signature.ts`. Never compared to macOS's `signatureAlgoVersion`. */
  readonly algoVersion: number;
  readonly fingerprintStrict: string;
  readonly fingerprintLoose: string;
  readonly title?: string | null;
  readonly appVersion?: string | null;
  readonly protoSignature?: string;
  readonly topFrames?: readonly ConfirmedBreakFrame[];
  readonly fix?: ConfirmedBreakFixBody;
}

export interface ConfirmedBreakFilingResult {
  readonly breakId: string;
  readonly recipeId: string | null;
}

// MARK: - GET/POST /api/iris/feature-requests

export interface PooledFeatureRequestEntry {
  readonly id: string;
  readonly request: string;
  readonly installs: number;
  readonly implementedCount: number;
  readonly referenceForkUrl: string | null;
}

export interface PoolFeatureWishInput {
  readonly appSlug: string;
  /** 32-lowercase-hex break signature this wish is attached to. */
  readonly signature: string;
  /** Already-normalized, already-bounded request text. This client does not
   *  template or truncate — that is `maintain-feature-requests.ts`'s job (a
   *  separate porting task); this is only the wire call. */
  readonly request: string;
  readonly installId: string;
}

// MARK: - POST /api/iris/recipes/{id}/flag

/** The three ways a flag attempt can land. `alreadyFlaggedToday` names the
 *  server's `429 { error: "already_flagged" }` (one flag per IP per recipe per
 *  day) rather than folding it into a generic failure, because the caller's
 *  UI has something specific to say about it. */
export type FlagRecipeOutcome =
  | { readonly kind: "recorded"; readonly status: string; readonly flagCount: number }
  | { readonly kind: "alreadyFlaggedToday" }
  | { readonly kind: "requestFailed" };

/**
 * HTTP client for the shared maintain-mode recipe pool. Every method takes no
 * credential and needs none — see the file header. Construct one per app
 * lifetime; it holds nothing but the base URL and the fetch seam.
 */
export class MaintainPoolClient {
  private readonly publikBaseUrl: string;
  private readonly fetchImplementation: FetchLike;

  constructor(options: { publikBaseUrl?: string; fetchImplementation?: FetchLike } = {}) {
    this.publikBaseUrl = (options.publikBaseUrl ?? DEFAULT_MAINTAIN_POOL_BASE_URL).replace(/\/+$/, "");
    this.fetchImplementation = options.fetchImplementation ?? (globalThis.fetch as unknown as FetchLike);
  }

  /**
   * The cache lookup — step one of every incident, zero tokens spent. A
   * network failure or non-200 response returns an empty answer rather than
   * throwing: the ladder treats "could not check the pool" exactly like "pool
   * had nothing," because both mean the same next step for the caller.
   */
  async lookupRecipes(key: RecipeLookupKey): Promise<RecipeCacheAnswer> {
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
      const parsed = await this.parseJson<{ recipes?: unknown; matchedBy?: unknown }>(response);
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
      const response = await this.fetchImplementation(
        `${this.publikBaseUrl}/api/iris/recipes/search?${searchParams}`,
        { method: "GET" }
      );
      if (!response.ok) {
        maintainTrace(`recipe search got HTTP ${response.status} — treating as empty`);
        return empty;
      }
      const parsed = await this.parseJson<{ recipes?: unknown; count?: unknown }>(response);
      if (parsed === null || !Array.isArray(parsed.recipes)) return empty;
      return {
        recipes: parsed.recipes as RecipeSearchResult[],
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
  async fileConfirmedBreak(filing: ConfirmedBreakFilingBody): Promise<ConfirmedBreakFilingResult | null> {
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
      const parsed = await this.parseJson<{ breakId?: unknown; recipeId?: unknown }>(response);
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
   * error.
   */
  async fileRecipeOutcome(recipeId: string, succeeded: boolean, installId?: string | null): Promise<void> {
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
  async flagRecipe(recipeId: string): Promise<FlagRecipeOutcome> {
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
      const parsed = await this.parseJson<{ status?: unknown; flagCount?: unknown }>(response);
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
  async poolFeatureWish(input: PoolFeatureWishInput): Promise<{ requestId: string } | null> {
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
      const parsed = await this.parseJson<{ requestId?: unknown }>(response);
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
   * the same to the caller: an empty list.
   */
  async topFeatureRequests(appSlug: string): Promise<readonly PooledFeatureRequestEntry[]> {
    try {
      const response = await this.fetchImplementation(
        `${this.publikBaseUrl}/api/iris/feature-requests?${this.searchParams({ app: appSlug })}`,
        { method: "GET" }
      );
      if (!response.ok) {
        maintainTrace(`feature-request lookup got HTTP ${response.status} — treating as empty`);
        return [];
      }
      const parsed = await this.parseJson<{ requests?: unknown }>(response);
      if (parsed === null || !Array.isArray(parsed.requests)) return [];
      return parsed.requests as PooledFeatureRequestEntry[];
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
