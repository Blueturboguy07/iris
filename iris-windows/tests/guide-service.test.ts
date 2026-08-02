import { describe, expect, it, vi } from "vitest";
import {
  FetchLike,
  GuideServiceError,
  fetchGuide,
  guideErrorMessage,
  guideFailureForStatusCode,
  guideRequestUrl,
  normalizedApiBase,
} from "../src/services/guide-service";

/**
 * The guides route answers with four different failures and they mean four
 * different things to the reader, so each must stay distinguishable all the way
 * to the panel. The Tauri panel this UI is transplanted from collapsed
 * 400/403/409 into "Guide service returned N"; this suite is what keeps the
 * Windows client from doing the same.
 *
 * Every test injects its own fetch. Nothing here touches the network.
 */

function respondWith(options: {
  status: number;
  body?: string;
}): { fetchImplementation: FetchLike; calls: string[] } {
  const calls: string[] = [];
  const fetchImplementation: FetchLike = async (url) => {
    calls.push(url);
    return {
      ok: options.status >= 200 && options.status < 300,
      status: options.status,
      text: async () => options.body ?? "",
    };
  };
  return { fetchImplementation, calls };
}

const A_VALID_GUIDE = JSON.stringify({
  appSlug: "cue",
  appName: "Cue",
  version: 7,
  status: "published",
  branches: [{ platform: "windows", target: "desktop", steps: [] }],
});

describe("status codes map to four distinct failures", () => {
  it.each([
    [400, "invalidGuideVersionRequest"],
    [403, "guideIsNotPublished"],
    [404, "guideNotFound"],
    [409, "guideVersionIsNoLongerAvailable"],
  ])("maps HTTP %i to %s", async (status, expectedKind) => {
    const { fetchImplementation } = respondWith({ status });
    await expect(
      fetchGuide({ apiBase: "https://publikhq.com", slug: "cue", version: 7, fetchImplementation })
    ).rejects.toThrowError(GuideServiceError);

    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: 7,
        fetchImplementation,
      });
    } catch (error) {
      expect((error as GuideServiceError).detail.kind).toBe(expectedKind);
    }
  });

  it("gives each of the four a different sentence", () => {
    const messages = [400, 403, 404, 409].map((status) =>
      guideErrorMessage(guideFailureForStatusCode(status, 7))
    );
    expect(new Set(messages).size).toBe(4);
  });

  it("carries the requested version into the 409 message, because that is the actionable part", () => {
    const detail = guideFailureForStatusCode(409, 7);
    expect(detail).toEqual({ kind: "guideVersionIsNoLongerAvailable", requestedVersion: 7 });
    expect(guideErrorMessage(detail)).toContain("7");
  });

  it("falls back to a generic failure for a status the route does not document", () => {
    for (const status of [418, 500, 502, 503]) {
      expect(guideFailureForStatusCode(status, null)).toEqual({
        kind: "unexpectedResponseStatus",
        statusCode: status,
      });
    }
  });
});

describe("request building", () => {
  it("builds the documented URL and includes the version when there is one", () => {
    expect(guideRequestUrl({ apiBase: "https://publikhq.com", slug: "cue", version: 7 })).toBe(
      "https://publikhq.com/api/iris/guides/cue?version=7"
    );
    expect(guideRequestUrl({ apiBase: "https://publikhq.com", slug: "cue", version: null })).toBe(
      "https://publikhq.com/api/iris/guides/cue"
    );
  });

  it("actually sends that URL", async () => {
    const { fetchImplementation, calls } = respondWith({ status: 200, body: A_VALID_GUIDE });
    await fetchGuide({
      apiBase: "https://publikhq.com",
      slug: "cue",
      version: 7,
      fetchImplementation,
    });
    expect(calls).toEqual(["https://publikhq.com/api/iris/guides/cue?version=7"]);
  });

  it("only loads guides from publik or loopback", () => {
    expect(normalizedApiBase("https://publikhq.com")).toBe("https://publikhq.com");
    expect(normalizedApiBase("https://www.publikhq.com/")).toBe("https://www.publikhq.com");
    expect(normalizedApiBase("http://localhost:3000")).toBe("http://localhost:3000");
    expect(normalizedApiBase("https://evil.tld")).toBeNull();
    expect(normalizedApiBase("https://publikhq.com.evil.tld")).toBeNull();
    expect(normalizedApiBase("not a url")).toBeNull();
  });

  it("refuses a base URL that is not publik's", async () => {
    const { fetchImplementation, calls } = respondWith({ status: 200, body: A_VALID_GUIDE });
    await expect(
      fetchGuide({ apiBase: "https://evil.tld", slug: "cue", version: 7, fetchImplementation })
    ).rejects.toThrowError(GuideServiceError);
    // And crucially, never made the request.
    expect(calls).toEqual([]);
  });
});

describe("input validation happens before any request", () => {
  it("rejects an invalid slug without calling the network", async () => {
    const { fetchImplementation, calls } = respondWith({ status: 200, body: A_VALID_GUIDE });
    await expect(
      fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "Cue/../etc",
        version: null,
        fetchImplementation,
      })
    ).rejects.toThrowError(GuideServiceError);
    expect(calls).toEqual([]);
  });

  it("rejects version 0 as a bad request rather than sending it", async () => {
    const { fetchImplementation, calls } = respondWith({ status: 200, body: A_VALID_GUIDE });
    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: 0,
        fetchImplementation,
      });
      expect.unreachable("version 0 should be refused");
    } catch (error) {
      expect((error as GuideServiceError).detail.kind).toBe("invalidGuideVersionRequest");
    }
    expect(calls).toEqual([]);
  });
});

describe("the happy path and the shapes that are not quite right", () => {
  it("returns the decoded guide on 200", async () => {
    const { fetchImplementation } = respondWith({ status: 200, body: A_VALID_GUIDE });
    const guide = await fetchGuide({
      apiBase: "https://publikhq.com",
      slug: "cue",
      version: 7,
      fetchImplementation,
    });
    expect(guide.appSlug).toBe("cue");
    expect(guide.version).toBe(7);
  });

  it("reports an undecodable body distinctly from an HTTP failure", async () => {
    const { fetchImplementation } = respondWith({ status: 200, body: "<html>oops</html>" });
    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: null,
        fetchImplementation,
      });
      expect.unreachable("a non-JSON body should fail");
    } catch (error) {
      expect((error as GuideServiceError).detail.kind).toBe("responseCouldNotBeDecoded");
    }
  });

  it("reports a guide with no reviewed branches as its own state", async () => {
    const { fetchImplementation } = respondWith({
      status: 200,
      body: JSON.stringify({ appSlug: "cue", appName: "Cue", version: 1, branches: [] }),
    });
    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: null,
        fetchImplementation,
      });
      expect.unreachable("an empty branch list should fail");
    } catch (error) {
      expect((error as GuideServiceError).detail.kind).toBe("guideHasNoBranches");
    }
  });

  it("treats a version the server silently swapped as a 409 in disguise", async () => {
    // Asking for v7 and being handed v9 is exactly what the 409 exists to
    // prevent; if the route ever stops enforcing it, the client still does.
    const { fetchImplementation } = respondWith({
      status: 200,
      body: JSON.stringify({
        appSlug: "cue",
        appName: "Cue",
        version: 9,
        branches: [{ platform: "windows" }],
      }),
    });
    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: 7,
        fetchImplementation,
      });
      expect.unreachable("a swapped version should fail");
    } catch (error) {
      expect((error as GuideServiceError).detail.kind).toBe("guideVersionIsNoLongerAvailable");
    }
  });

  it("reports a network failure as a transport failure, not as a status", async () => {
    const fetchImplementation = vi.fn(async () => {
      throw new Error("ENOTFOUND publikhq.com");
    }) as unknown as FetchLike;
    try {
      await fetchGuide({
        apiBase: "https://publikhq.com",
        slug: "cue",
        version: null,
        fetchImplementation,
      });
      expect.unreachable("a thrown fetch should fail");
    } catch (error) {
      const detail = (error as GuideServiceError).detail;
      expect(detail.kind).toBe("transportFailure");
      expect(guideErrorMessage(detail)).toContain("could not reach publik");
    }
  });
});
