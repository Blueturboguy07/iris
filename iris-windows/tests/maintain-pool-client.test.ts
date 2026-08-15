import { describe, expect, it } from "vitest";
import { MaintainPoolClient, type FetchLike } from "../src/services/maintain/pool-client";

interface SentRequest {
  url: string;
  method: string | undefined;
  headers: Record<string, string> | undefined;
  body: string | undefined;
}

/** A scripted fetch that records every call and answers with one queued
 *  response per call, in order — mirrors `recordingFetch` in
 *  `tests/claude-service.test.ts`. */
function scriptedFetch(
  responses: Array<{ ok?: boolean; status?: number; body?: unknown } | "network-error">
): { fetchImplementation: FetchLike; sent: SentRequest[] } {
  const sent: SentRequest[] = [];
  let call = 0;
  const fetchImplementation: FetchLike = async (url, init) => {
    sent.push({ url, method: init?.method, headers: init?.headers, body: init?.body });
    const response = responses[call];
    call += 1;
    if (response === "network-error" || response === undefined) {
      throw new Error("simulated network failure");
    }
    return {
      ok: response.ok ?? true,
      status: response.status ?? 200,
      text: async () => JSON.stringify(response.body ?? {}),
    };
  };
  return { fetchImplementation, sent };
}

const BASE = "https://publikhq.example";

describe("MaintainPoolClient — GET /api/iris/recipes (lookupRecipes)", () => {
  it("sends app/signature/fs/fl as query params and returns the recipes + matchedBy", async () => {
    const { fetchImplementation, sent } = scriptedFetch([
      { body: { recipes: [{ id: "r1", verifiedFixes: 3 }], matchedBy: "fingerprint_strict" } },
    ]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const answer = await client.lookupRecipes({
      appSlug: "cue",
      signatureId: "a".repeat(32),
      fingerprintStrict: "strict-key",
      fingerprintLoose: "loose-key",
    });

    expect(answer.matchedBy).toBe("fingerprint_strict");
    expect(answer.recipes).toHaveLength(1);
    const url = new URL(sent[0].url);
    expect(url.pathname).toBe("/api/iris/recipes");
    expect(url.searchParams.get("app")).toBe("cue");
    expect(url.searchParams.get("signature")).toBe("a".repeat(32));
    expect(url.searchParams.get("fs")).toBe("strict-key");
    expect(url.searchParams.get("fl")).toBe("loose-key");
  });

  it("omits absent optional keys from the query string entirely", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { recipes: [], matchedBy: null } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    await client.lookupRecipes({ appSlug: "cue", fingerprintLoose: "only-loose" });

    const url = new URL(sent[0].url);
    expect(url.searchParams.has("signature")).toBe(false);
    expect(url.searchParams.has("fs")).toBe(false);
    expect(url.searchParams.get("fl")).toBe("only-loose");
  });

  it("treats a non-200 response as a clean miss, never throwing", async () => {
    const { fetchImplementation } = scriptedFetch([{ ok: false, status: 500, body: { error: "recipes_read_failed" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    const answer = await client.lookupRecipes({ appSlug: "cue", signatureId: "a".repeat(32) });
    expect(answer).toEqual({ recipes: [], matchedBy: null });
  });

  it("treats a network failure as a clean miss, never throwing", async () => {
    const { fetchImplementation } = scriptedFetch(["network-error"]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    const answer = await client.lookupRecipes({ appSlug: "cue", signatureId: "a".repeat(32) });
    expect(answer).toEqual({ recipes: [], matchedBy: null });
  });

  it("normalizes an unrecognized matchedBy value to null rather than passing it through", async () => {
    const { fetchImplementation } = scriptedFetch([{ body: { recipes: [], matchedBy: "something_new" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    const answer = await client.lookupRecipes({ appSlug: "cue", signatureId: "a".repeat(32) });
    expect(answer.matchedBy).toBeNull();
  });
});

describe("MaintainPoolClient — GET /api/iris/recipes/search (searchRecipes)", () => {
  it("sends q/app/stack/kind/type/file as query params", async () => {
    const { fetchImplementation, sent } = scriptedFetch([
      { body: { recipes: [{ id: "r1", score: 5 }], count: 1 } },
    ]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const answer = await client.searchRecipes({
      query: "crash on launch",
      appSlug: "cue",
      stack: "electron",
      kind: "hang",
      recipeType: "workaround",
      touchesFile: "src/main.ts",
    });

    expect(answer.count).toBe(1);
    const url = new URL(sent[0].url);
    expect(url.pathname).toBe("/api/iris/recipes/search");
    expect(url.searchParams.get("q")).toBe("crash on launch");
    expect(url.searchParams.get("app")).toBe("cue");
    expect(url.searchParams.get("stack")).toBe("electron");
    expect(url.searchParams.get("kind")).toBe("hang");
    expect(url.searchParams.get("type")).toBe("workaround");
    expect(url.searchParams.get("file")).toBe("src/main.ts");
  });

  it("treats a non-200 or a network failure as an empty result set, never throwing", async () => {
    const { fetchImplementation: failing } = scriptedFetch([{ ok: false, status: 500 }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: failing });
    expect(await client.searchRecipes({ query: "x" })).toEqual({ recipes: [], count: 0 });

    const { fetchImplementation: erroring } = scriptedFetch(["network-error"]);
    const client2 = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: erroring });
    expect(await client2.searchRecipes({ query: "x" })).toEqual({ recipes: [], count: 0 });
  });
});

describe("MaintainPoolClient — POST /api/iris/breaks (fileConfirmedBreak)", () => {
  const FILING = {
    appSlug: "cue",
    signature: "a".repeat(32),
    appStack: "electron" as const,
    signatureKind: "hang" as const,
    algoVersion: 1,
    fingerprintStrict: "strict",
    fingerprintLoose: "loose",
  };

  it("POSTs the exact filing body and returns breakId + recipeId on 201", async () => {
    const { fetchImplementation, sent } = scriptedFetch([
      { status: 201, body: { breakId: "break-1", recipeId: "recipe-1" } },
    ]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const result = await client.fileConfirmedBreak(FILING);

    expect(result).toEqual({ breakId: "break-1", recipeId: "recipe-1" });
    expect(sent[0].url).toBe(`${BASE}/api/iris/breaks`);
    expect(sent[0].method).toBe("POST");
    expect(sent[0].headers?.["Content-Type"]).toBe("application/json");
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual(FILING);
  });

  it("returns recipeId: null when no fix rode along", async () => {
    const { fetchImplementation } = scriptedFetch([{ status: 201, body: { breakId: "break-1", recipeId: null } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.fileConfirmedBreak(FILING)).toEqual({ breakId: "break-1", recipeId: null });
  });

  it("returns null (never throws) on a non-201 response — the caller stages a retry, this file does not loop", async () => {
    const { fetchImplementation } = scriptedFetch([{ status: 400, body: { error: "invalid_fingerprints" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.fileConfirmedBreak(FILING)).toBeNull();
  });

  it("returns null (never throws) on a network failure", async () => {
    const { fetchImplementation } = scriptedFetch(["network-error"]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.fileConfirmedBreak(FILING)).toBeNull();
  });

  it("carries a fix payload through untouched when present", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ status: 201, body: { breakId: "b1", recipeId: "r1" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    const filingWithFix = {
      ...FILING,
      title: "cue hangs on launch",
      topFrames: [{ module: "cue.exe", function: "offset:1a2b", file: "", is_app_frame: true }],
      fix: {
        recipeType: "workaround" as const,
        patchSpecific: "diff --git a/x b/x\n",
        diagnosis: "a race on startup",
      },
    };
    await client.fileConfirmedBreak(filingWithFix);
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual(filingWithFix);
  });
});

describe("MaintainPoolClient — POST /api/iris/recipes/{id}/outcome (fileRecipeOutcome)", () => {
  it("POSTs to the recipe-specific outcome URL with succeeded + installId", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { status: "outcome_recorded" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    await client.fileRecipeOutcome("recipe-123", true, "install-uuid-1");

    expect(sent[0].url).toBe(`${BASE}/api/iris/recipes/recipe-123/outcome`);
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual({ succeeded: true, installId: "install-uuid-1" });
  });

  it("omits installId from the body entirely when none is given", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { status: "ok" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    await client.fileRecipeOutcome("recipe-123", false);
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual({ succeeded: false });
  });

  it("is fire-and-forget: a network failure resolves without throwing", async () => {
    const { fetchImplementation } = scriptedFetch(["network-error"]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    await expect(client.fileRecipeOutcome("recipe-123", true)).resolves.toBeUndefined();
  });

  it("is fire-and-forget: a non-200 response resolves without throwing", async () => {
    const { fetchImplementation } = scriptedFetch([{ ok: false, status: 500 }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    await expect(client.fileRecipeOutcome("recipe-123", true)).resolves.toBeUndefined();
  });
});

describe("MaintainPoolClient — POST /api/iris/recipes/{id}/flag (flagRecipe)", () => {
  it("reports a recorded flag with the status and flagCount from the server", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { status: "flagged", flagCount: 3 } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const outcome = await client.flagRecipe("recipe-9");

    expect(outcome).toEqual({ kind: "recorded", status: "flagged", flagCount: 3 });
    expect(sent[0].url).toBe(`${BASE}/api/iris/recipes/recipe-9/flag`);
    expect(sent[0].method).toBe("POST");
  });

  it("reports alreadyFlaggedToday on a 429 — distinct from a generic failure", async () => {
    const { fetchImplementation } = scriptedFetch([{ ok: false, status: 429, body: { error: "already_flagged" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.flagRecipe("recipe-9")).toEqual({ kind: "alreadyFlaggedToday" });
  });

  it("reports requestFailed on any other non-ok response, never throwing", async () => {
    const { fetchImplementation } = scriptedFetch([{ ok: false, status: 404 }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.flagRecipe("missing")).toEqual({ kind: "requestFailed" });
  });

  it("reports requestFailed on a network failure, never throwing", async () => {
    const { fetchImplementation } = scriptedFetch(["network-error"]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    expect(await client.flagRecipe("recipe-9")).toEqual({ kind: "requestFailed" });
  });
});

describe("MaintainPoolClient — POST /api/iris/fix-log (recordFixLog)", () => {
  it("POSTs appSlug/title/repo and never throws regardless of outcome", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ status: 201, body: { id: "log-1" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    await client.recordFixLog("cue", "fixed the launch hang", "owner/cue");

    expect(sent[0].url).toBe(`${BASE}/api/iris/fix-log`);
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual({
      appSlug: "cue",
      title: "fixed the launch hang",
      repo: "owner/cue",
    });
  });

  it("is fire-and-forget on failure", async () => {
    const { fetchImplementation } = scriptedFetch(["network-error"]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });
    await expect(client.recordFixLog("cue", "x", "owner/cue")).resolves.toBeUndefined();
  });
});

describe("MaintainPoolClient — feature requests", () => {
  it("poolFeatureWish POSTs the wish and returns the created id on 201", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ status: 201, body: { requestId: "req-1" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const result = await client.poolFeatureWish({
      appSlug: "cue",
      signature: "a".repeat(32),
      request: "let me export my history",
      installId: "install-uuid-1",
    });

    expect(result).toEqual({ requestId: "req-1" });
    expect(sent[0].url).toBe(`${BASE}/api/iris/feature-requests`);
    expect(JSON.parse(sent[0].body ?? "{}")).toEqual({
      appSlug: "cue",
      signature: "a".repeat(32),
      request: "let me export my history",
      installId: "install-uuid-1",
    });
  });

  it("poolFeatureWish returns null (never throws) on refusal or network failure", async () => {
    const { fetchImplementation: refused } = scriptedFetch([{ status: 400, body: { error: "empty_request" } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: refused });
    expect(
      await client.poolFeatureWish({ appSlug: "cue", signature: "a".repeat(32), request: "", installId: "x" })
    ).toBeNull();

    const { fetchImplementation: erroring } = scriptedFetch(["network-error"]);
    const client2 = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: erroring });
    expect(
      await client2.poolFeatureWish({ appSlug: "cue", signature: "a".repeat(32), request: "x", installId: "x" })
    ).toBeNull();
  });

  it("topFeatureRequests returns the full server shape, including id and referenceForkUrl", async () => {
    const { fetchImplementation, sent } = scriptedFetch([
      {
        body: {
          requests: [
            { id: "req-1", request: "export history", installs: 12, implementedCount: 0, referenceForkUrl: null },
          ],
        },
      },
    ]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation });

    const requests = await client.topFeatureRequests("cue");

    expect(requests).toEqual([
      { id: "req-1", request: "export history", installs: 12, implementedCount: 0, referenceForkUrl: null },
    ]);
    const url = new URL(sent[0].url);
    expect(url.pathname).toBe("/api/iris/feature-requests");
    expect(url.searchParams.get("app")).toBe("cue");
  });

  it("topFeatureRequests returns an empty array (never throws) on failure", async () => {
    const { fetchImplementation: failing } = scriptedFetch([{ ok: false, status: 500 }]);
    const client = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: failing });
    expect(await client.topFeatureRequests("cue")).toEqual([]);

    const { fetchImplementation: erroring } = scriptedFetch(["network-error"]);
    const client2 = new MaintainPoolClient({ publikBaseUrl: BASE, fetchImplementation: erroring });
    expect(await client2.topFeatureRequests("cue")).toEqual([]);
  });
});

describe("MaintainPoolClient — base URL handling", () => {
  it("strips a trailing slash from the configured publik base URL", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { recipes: [], matchedBy: null } }]);
    const client = new MaintainPoolClient({ publikBaseUrl: `${BASE}/`, fetchImplementation });
    await client.lookupRecipes({ appSlug: "cue", signatureId: "a".repeat(32) });
    expect(sent[0].url.startsWith(`${BASE}/api/iris/recipes?`)).toBe(true);
  });

  it("defaults to DEFAULT_MAINTAIN_POOL_BASE_URL when no base URL is configured", async () => {
    const { fetchImplementation, sent } = scriptedFetch([{ body: { recipes: [], matchedBy: null } }]);
    const client = new MaintainPoolClient({ fetchImplementation });
    await client.lookupRecipes({ appSlug: "cue", signatureId: "a".repeat(32) });
    expect(sent[0].url.startsWith("https://publikhq.com/api/iris/recipes?")).toBe(true);
  });
});
