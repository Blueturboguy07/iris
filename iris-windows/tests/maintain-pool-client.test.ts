import { describe, expect, it } from "vitest";
import {
  DEFAULT_MAINTAIN_POOL_BASE_URL,
  MaintainPoolClient,
  type MaintainPoolFetchLike,
} from "../src/services/maintain/pool-client";

/**
 * `MaintainPoolClient` — the transport half of maintain mode's shared recipe
 * pool. Every method here is not-throwing by design (porting spec: "could not
 * check the pool" reads the same as "pool had nothing"), so most of these
 * tests are shaped as "give it a bad response, prove it degrades to the
 * documented miss value rather than throwing."
 */

interface RecordedCall {
  readonly url: string;
  readonly method: string;
  readonly headers: Record<string, string>;
  readonly body: string | undefined;
}

/** A scripted fetch that records every call it saw and answers with a queued
 *  response (or throws, for the network-failure cases). Mirrors the
 *  `tokenResponder` fixture shape in `tests/account-service.test.ts`. */
function scriptedFetch(
  responder: (call: RecordedCall) => { status: number; body: string } | "throw"
): { fetchImplementation: MaintainPoolFetchLike; calls: RecordedCall[] } {
  const calls: RecordedCall[] = [];
  const fetchImplementation: MaintainPoolFetchLike = async (url, init) => {
    const call: RecordedCall = {
      url,
      method: init.method,
      headers: init.headers ?? {},
      body: init.body,
    };
    calls.push(call);
    const outcome = responder(call);
    if (outcome === "throw") throw new Error("simulated network failure");
    return {
      ok: outcome.status >= 200 && outcome.status < 300,
      status: outcome.status,
      text: async () => outcome.body,
    };
  };
  return { fetchImplementation, calls };
}

function clientWith(
  responder: (call: RecordedCall) => { status: number; body: string } | "throw"
): { client: MaintainPoolClient; calls: RecordedCall[] } {
  const { fetchImplementation, calls } = scriptedFetch(responder);
  return { client: new MaintainPoolClient({ fetchImplementation }), calls };
}

describe("MaintainPoolClient construction", () => {
  it("defaults to the shared publik base URL and strips a trailing slash from an override", async () => {
    const { fetchImplementation, calls } = scriptedFetch(() => ({
      status: 200,
      body: JSON.stringify({ recipes: [], matchedBy: null }),
    }));
    const defaultClient = new MaintainPoolClient({ fetchImplementation });
    await defaultClient.lookupRecipes({ appSlug: "cue" });
    expect(calls[0].url.startsWith(DEFAULT_MAINTAIN_POOL_BASE_URL)).toBe(true);

    calls.length = 0;
    const overridden = new MaintainPoolClient({
      fetchImplementation,
      publikBaseUrl: "https://staging.publikhq.com///",
    });
    await overridden.lookupRecipes({ appSlug: "cue" });
    expect(calls[0].url.startsWith("https://staging.publikhq.com/api/iris/recipes?")).toBe(true);
  });
});

describe("lookupRecipes — the hot path", () => {
  it("sends app/signature/fs/fl as the query and passes a 200 payload through", async () => {
    const pooledRecipe = { id: "r1", appSlug: "cue", recipeType: "guidance" };
    const { client, calls } = clientWith(() => ({
      status: 200,
      body: JSON.stringify({ recipes: [pooledRecipe], matchedBy: "fingerprint_strict" }),
    }));

    const answer = await client.lookupRecipes({
      appSlug: "cue",
      signatureId: "sig-123",
      fingerprintStrict: "fs-abc",
      fingerprintLoose: "fl-xyz",
    });

    const url = new URL(calls[0].url);
    expect(calls[0].method).toBe("GET");
    expect(url.pathname).toBe("/api/iris/recipes");
    expect(url.searchParams.get("app")).toBe("cue");
    expect(url.searchParams.get("signature")).toBe("sig-123");
    expect(url.searchParams.get("fs")).toBe("fs-abc");
    expect(url.searchParams.get("fl")).toBe("fl-xyz");
    expect(answer).toEqual({ recipes: [pooledRecipe], matchedBy: "fingerprint_strict" });
  });

  it("omits null/undefined optional fields from the query rather than sending the literal string 'undefined'", async () => {
    const { client, calls } = clientWith(() => ({ status: 200, body: JSON.stringify({ recipes: [], matchedBy: null }) }));

    await client.lookupRecipes({ appSlug: "cue", signatureId: null, fingerprintStrict: null, fingerprintLoose: null });

    const url = new URL(calls[0].url);
    expect(url.searchParams.has("signature")).toBe(false);
    expect(url.searchParams.has("fs")).toBe(false);
    expect(url.searchParams.has("fl")).toBe(false);
  });

  it.each([
    ["a non-200 status", { status: 404, body: "not found" }] as const,
    ["a 200 with an unparseable body", { status: 200, body: "not json" }] as const,
    ["a 200 body missing the recipes array", { status: 200, body: JSON.stringify({ matchedBy: "signature" }) }] as const,
  ])("treats %s as a clean miss, never a throw", async (_label, response) => {
    const { client } = clientWith(() => response);
    await expect(client.lookupRecipes({ appSlug: "cue" })).resolves.toEqual({ recipes: [], matchedBy: null });
  });

  it("treats a network failure as a miss, not a throw", async () => {
    const { client } = clientWith(() => "throw");
    await expect(client.lookupRecipes({ appSlug: "cue" })).resolves.toEqual({ recipes: [], matchedBy: null });
  });

  it("collapses an unrecognized matchedBy value to null rather than passing it through", async () => {
    const { client } = clientWith(() => ({
      status: 200,
      body: JSON.stringify({ recipes: [], matchedBy: "something_new_the_client_does_not_know" }),
    }));
    const answer = await client.lookupRecipes({ appSlug: "cue" });
    expect(answer.matchedBy).toBeNull();
  });
});

describe("searchRecipes — cold, human-facing search", () => {
  it("maps the query fields to q/app/stack/kind/type/file", async () => {
    const { client, calls } = clientWith(() => ({ status: 200, body: JSON.stringify({ recipes: [], count: 0 }) }));

    await client.searchRecipes({
      query: "crashes on launch",
      appSlug: "cue",
      stack: "electron",
      kind: "native-crash",
      recipeType: "tier_b_patch",
      touchesFile: "src/main.ts",
    });

    const url = new URL(calls[0].url);
    expect(url.pathname).toBe("/api/iris/recipes/search");
    expect(url.searchParams.get("q")).toBe("crashes on launch");
    expect(url.searchParams.get("app")).toBe("cue");
    expect(url.searchParams.get("stack")).toBe("electron");
    expect(url.searchParams.get("kind")).toBe("native-crash");
    expect(url.searchParams.get("type")).toBe("tier_b_patch");
    expect(url.searchParams.get("file")).toBe("src/main.ts");
  });

  it("falls back to recipes.length when the server omits count", async () => {
    const { client } = clientWith(() => ({
      status: 200,
      body: JSON.stringify({ recipes: [{ id: "a" }, { id: "b" }] }),
    }));
    const answer = await client.searchRecipes();
    expect(answer.count).toBe(2);
  });

  it("treats a failure as an empty result set, never a throw", async () => {
    const { client } = clientWith(() => "throw");
    await expect(client.searchRecipes()).resolves.toEqual({ recipes: [], count: 0 });
  });
});

describe("fileConfirmedBreak", () => {
  const filing = {
    appSlug: "cue",
    signature: "sig-123",
    appStack: "electron" as const,
    signatureKind: "native-crash" as const,
    algoVersion: 1,
    fingerprintStrict: "fs",
    fingerprintLoose: "fl",
    title: "Cue crashes on launch",
    protoSignature: "proto",
    topFrames: [{ module: "cue.exe", function: "main", file: "", is_app_frame: true }],
  };

  it("serializes the filing verbatim, including the deliberately snake_case is_app_frame key", async () => {
    const { client, calls } = clientWith(() => ({
      status: 201,
      body: JSON.stringify({ breakId: "break-1", recipeId: null }),
    }));

    await client.fileConfirmedBreak(filing);

    expect(calls[0].method).toBe("POST");
    expect(calls[0].headers["Content-Type"]).toBe("application/json");
    const sentBody = JSON.parse(calls[0].body ?? "{}");
    expect(sentBody).toEqual(filing);
    expect(sentBody.topFrames[0].is_app_frame).toBe(true);
    expect(Object.keys(sentBody.topFrames[0])).toContain("is_app_frame");
  });

  it("returns the break id, and a null recipe id when the response has none", async () => {
    const { client } = clientWith(() => ({ status: 201, body: JSON.stringify({ breakId: "break-1" }) }));
    await expect(client.fileConfirmedBreak(filing)).resolves.toEqual({ breakId: "break-1", recipeId: null });
  });

  it("returns the recipe id when a fix rode along and the server minted one", async () => {
    const { client } = clientWith(() => ({
      status: 201,
      body: JSON.stringify({ breakId: "break-1", recipeId: "recipe-9" }),
    }));
    await expect(client.fileConfirmedBreak(filing)).resolves.toEqual({ breakId: "break-1", recipeId: "recipe-9" });
  });

  it.each([
    ["the intake refuses with a non-201 status", { status: 422, body: "{}" }] as const,
    ["the 201 body has no breakId", { status: 201, body: "{}" }] as const,
  ])("returns null, staged for the caller to retry later, when %s", async (_label, response) => {
    const { client } = clientWith(() => response);
    await expect(client.fileConfirmedBreak(filing)).resolves.toBeNull();
  });

  it("returns null rather than throwing on a network failure", async () => {
    const { client } = clientWith(() => "throw");
    await expect(client.fileConfirmedBreak(filing)).resolves.toBeNull();
  });
});

describe("fileRecipeOutcome — fire and forget", () => {
  it("includes installId in the body when supplied", async () => {
    const { client, calls } = clientWith(() => ({ status: 200, body: "{}" }));
    await client.fileRecipeOutcome("recipe-1", true, "install-abc");
    expect(calls[0].url).toContain("/api/iris/recipes/recipe-1/outcome");
    expect(JSON.parse(calls[0].body ?? "{}")).toEqual({ succeeded: true, installId: "install-abc" });
  });

  it("omits installId entirely when not supplied, rather than sending it as undefined/null", async () => {
    const { client, calls } = clientWith(() => ({ status: 200, body: "{}" }));
    await client.fileRecipeOutcome("recipe-1", false);
    const sentBody = JSON.parse(calls[0].body ?? "{}");
    expect(sentBody).toEqual({ succeeded: false });
    expect("installId" in sentBody).toBe(false);
  });

  it("URL-encodes the recipe id in the path", async () => {
    const { client, calls } = clientWith(() => ({ status: 200, body: "{}" }));
    await client.fileRecipeOutcome("recipe/with slash", true);
    expect(calls[0].url).toContain(encodeURIComponent("recipe/with slash"));
  });

  it("swallows a network failure silently — nothing to return, nothing thrown", async () => {
    const { client } = clientWith(() => "throw");
    await expect(client.fileRecipeOutcome("recipe-1", true)).resolves.toBeUndefined();
  });
});

describe("flagRecipe", () => {
  it("reports alreadyFlaggedToday on 429, distinct from a generic failure", async () => {
    const { client } = clientWith(() => ({ status: 429, body: JSON.stringify({ error: "already_flagged" }) }));
    await expect(client.flagRecipe("recipe-1")).resolves.toEqual({ kind: "alreadyFlaggedToday" });
  });

  it("reports the recorded flag count on success", async () => {
    const { client, calls } = clientWith(() => ({
      status: 200,
      body: JSON.stringify({ status: "flagged", flagCount: 3 }),
    }));
    await expect(client.flagRecipe("recipe-1")).resolves.toEqual({ kind: "recorded", status: "flagged", flagCount: 3 });
    expect(calls[0].body).toBe("{}");
  });

  it.each([
    ["a non-ok, non-429 status", { status: 500, body: "{}" }] as const,
    ["a 200 with a malformed body", { status: 200, body: JSON.stringify({ status: "flagged" }) }] as const,
  ])("reports requestFailed when %s", async (_label, response) => {
    const { client } = clientWith(() => response);
    await expect(client.flagRecipe("recipe-1")).resolves.toEqual({ kind: "requestFailed" });
  });

  it("reports requestFailed rather than throwing on a network failure", async () => {
    const { client } = clientWith(() => "throw");
    await expect(client.flagRecipe("recipe-1")).resolves.toEqual({ kind: "requestFailed" });
  });
});

describe("recordFixLog — fire and forget", () => {
  it("posts appSlug/title/repo and swallows any failure", async () => {
    const { client, calls } = clientWith(() => ({ status: 201, body: "{}" }));
    await client.recordFixLog("cue", "Fixed the launch crash", "Blueturboguy07/cue");
    expect(calls[0].url).toContain("/api/iris/fix-log");
    expect(JSON.parse(calls[0].body ?? "{}")).toEqual({
      appSlug: "cue",
      title: "Fixed the launch crash",
      repo: "Blueturboguy07/cue",
    });

    const { client: throwingClient } = clientWith(() => "throw");
    await expect(throwingClient.recordFixLog("cue", "x", "y/z")).resolves.toBeUndefined();
  });
});

describe("poolFeatureWish", () => {
  it("returns the created request id on 201", async () => {
    const { client, calls } = clientWith(() => ({ status: 201, body: JSON.stringify({ requestId: "req-1" }) }));
    const result = await client.poolFeatureWish({
      appSlug: "cue",
      signature: "sig-1",
      request: "wants dark mode",
      installId: "install-1",
    });
    expect(result).toEqual({ requestId: "req-1" });
    expect(JSON.parse(calls[0].body ?? "{}").installId).toBe("install-1");
  });

  it("returns null, staged for retry, on refusal or network failure", async () => {
    const { client: refused } = clientWith(() => ({ status: 400, body: "{}" }));
    await expect(
      refused.poolFeatureWish({ appSlug: "cue", signature: "s", request: "r", installId: "i" })
    ).resolves.toBeNull();

    const { client: failed } = clientWith(() => "throw");
    await expect(
      failed.poolFeatureWish({ appSlug: "cue", signature: "s", request: "r", installId: "i" })
    ).resolves.toBeNull();
  });
});

describe("topFeatureRequests", () => {
  it("returns the pooled requests for an app", async () => {
    const requests = [{ id: "req-1", request: "dark mode", installs: 7, implementedCount: 0, referenceForkUrl: null }];
    const { client, calls } = clientWith(() => ({ status: 200, body: JSON.stringify({ requests }) }));
    await expect(client.topFeatureRequests("cue")).resolves.toEqual(requests);
    expect(new URL(calls[0].url).searchParams.get("app")).toBe("cue");
  });

  it("returns an empty list on a miss or a network failure, never a throw", async () => {
    const { client: missing } = clientWith(() => ({ status: 404, body: "{}" }));
    await expect(missing.topFeatureRequests("cue")).resolves.toEqual([]);

    const { client: failed } = clientWith(() => "throw");
    await expect(failed.topFeatureRequests("cue")).resolves.toEqual([]);
  });
});
