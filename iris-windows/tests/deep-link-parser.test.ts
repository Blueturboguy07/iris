import { describe, expect, it } from "vitest";
import {
  isValidBranchKey,
  isValidGuideSlug,
  parseIrisDeepLink,
} from "../src/services/deep-link-parser";

/**
 * The rules under test are ported from `parse_guide_deep_link` in
 * `iris-desktop/src-tauri/src/main.rs` (lines 188-285). The governing property
 * is that an unknown query parameter is REJECTED, never ignored — so a link
 * cannot smuggle in a field a later version of the app might start reading.
 */

function expectRejected(url: string) {
  const result = parseIrisDeepLink(url);
  expect(result.ok, `expected ${url} to be rejected`).toBe(false);
  return result.ok ? "" : result.rejection;
}

describe("guide deep links — the one link that works", () => {
  it("accepts a complete, valid guide link and reads every field off it", () => {
    const result = parseIrisDeepLink("iris://guide/cue?version=7&branch=windows:desktop&step=3");
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.link.kind).toBe("guide");
    if (result.link.kind !== "guide") return;
    expect(result.link.guide).toEqual({
      slug: "cue",
      version: 7,
      branch: "windows:desktop",
      step: 3,
    });
  });

  it("accepts the minimum: a slug and a version", () => {
    const result = parseIrisDeepLink("iris://guide/lunara?version=1");
    expect(result.ok).toBe(true);
    if (!result.ok || result.link.kind !== "guide") return;
    expect(result.link.guide).toEqual({ slug: "lunara", version: 1, branch: null, step: null });
  });

  it("accepts step 0 and step 500, the exact boundaries", () => {
    for (const step of [0, 500]) {
      const result = parseIrisDeepLink(`iris://guide/cue?version=1&step=${step}`);
      expect(result.ok, `step=${step} should be accepted`).toBe(true);
    }
  });

  it.each(["macos:ios", "macos:android", "macos:desktop", "windows:ios", "windows:android", "windows:desktop"])(
    "accepts the known branch %s",
    (branch) => {
      expect(parseIrisDeepLink(`iris://guide/cue?version=1&branch=${branch}`).ok).toBe(true);
    }
  );
});

describe("guide deep links — unknown query parameters are refused outright", () => {
  it("rejects a parameter the app has never heard of", () => {
    expect(expectRejected("iris://guide/cue?version=1&admin=true")).toBe(
      "unsupported Iris guide parameter"
    );
  });

  it("rejects a plausible-looking future parameter rather than ignoring it", () => {
    expect(expectRejected("iris://guide/cue?version=1&apiBase=https://evil.tld")).toBe(
      "unsupported Iris guide parameter"
    );
    expect(expectRejected("iris://guide/cue?version=1&token=abc")).toBe(
      "unsupported Iris guide parameter"
    );
  });

  it("rejects a duplicated known parameter", () => {
    expect(expectRejected("iris://guide/cue?version=1&version=2")).toBe(
      "Iris guide links accept only one version parameter"
    );
    expect(expectRejected("iris://guide/cue?version=1&branch=macos:ios&branch=windows:ios")).toBe(
      "Iris guide links accept only one branch parameter"
    );
    expect(expectRejected("iris://guide/cue?version=1&step=1&step=2")).toBe(
      "Iris guide links accept only one step parameter"
    );
  });
});

describe("guide deep links — bad versions", () => {
  it.each([
    ["iris://guide/cue?version=0", "invalid Iris guide version"],
    ["iris://guide/cue?version=-1", "invalid Iris guide version"],
    ["iris://guide/cue?version=1.5", "invalid Iris guide version"],
    ["iris://guide/cue?version=abc", "invalid Iris guide version"],
    ["iris://guide/cue?version=", "invalid Iris guide version"],
    ["iris://guide/cue?version=99999999999999", "invalid Iris guide version"],
    ["iris://guide/cue", "missing Iris guide version"],
    ["iris://guide/cue?branch=macos:ios", "missing Iris guide version"],
  ])("rejects %s", (url, expectedRejection) => {
    expect(expectRejected(url)).toBe(expectedRejection);
  });
});

describe("guide deep links — bad steps and branches", () => {
  it("rejects a step past 500", () => {
    expect(expectRejected("iris://guide/cue?version=1&step=501")).toBe("invalid Iris guide step");
    expect(expectRejected("iris://guide/cue?version=1&step=100000")).toBe(
      "invalid Iris guide step"
    );
  });

  it("rejects a negative or non-numeric step", () => {
    expect(expectRejected("iris://guide/cue?version=1&step=-1")).toBe("invalid Iris guide step");
    expect(expectRejected("iris://guide/cue?version=1&step=three")).toBe("invalid Iris guide step");
  });

  it.each([
    "linux:desktop",
    "macos:windows",
    "windows:web",
    "macos",
    "macos:",
    ":ios",
    "MACOS:IOS",
    "macos:ios:extra",
  ])("rejects the unknown branch %s", (branch) => {
    expect(expectRejected(`iris://guide/cue?version=1&branch=${encodeURIComponent(branch)}`)).toBe(
      "invalid Iris guide branch"
    );
  });
});

describe("guide deep links — bad slugs and hosts", () => {
  it("rejects a link with no slug at all", () => {
    expect(expectRejected("iris://guide?version=1")).toBe("missing guide slug");
    expect(expectRejected("iris://guide/?version=1")).toBe("missing guide slug");
  });

  it("rejects more than one path segment", () => {
    expect(expectRejected("iris://guide/cue/extra?version=1")).toBe(
      "Iris guide links require exactly one slug"
    );
  });

  it.each(["Cue", "-cue", "cue-", "cue_extra", "cue extra", "cue%2Fextra", "cue.exe", "a".repeat(65)])(
    "rejects the invalid slug %s",
    (slug) => {
      expect(expectRejected(`iris://guide/${slug}?version=1`)).toBe("invalid Iris guide slug");
    }
  );

  it("rejects a non-guide host", () => {
    expect(expectRejected("iris://settings/cue?version=1")).toBe("unsupported Iris link");
    expect(expectRejected("iris://evil.tld/cue?version=1")).toBe("unsupported Iris link");
    expect(expectRejected("iris://guides/cue?version=1")).toBe("unsupported Iris link");
  });

  it("rejects a non-iris scheme even when the rest is perfect", () => {
    expect(expectRejected("https://guide/cue?version=1")).toBe("unsupported Iris link");
    expect(expectRejected("file://guide/cue?version=1")).toBe("unsupported Iris link");
  });

  it("rejects embedded credentials, ports, and fragments", () => {
    expect(expectRejected("iris://user:pass@guide/cue?version=1")).toBe("unsupported Iris link");
    expect(expectRejected("iris://guide:8080/cue?version=1")).toBe("unsupported Iris link");
    expect(expectRejected("iris://guide/cue?version=1#fragment")).toBe("unsupported Iris link");
  });

  it("rejects gibberish that is not a URL at all", () => {
    expect(expectRejected("not a url")).toBe("unsupported Iris link");
    expect(expectRejected("")).toBe("unsupported Iris link");
  });
});

describe("iris://auth/callback is its own link, distinct from a guide link", () => {
  it("parses a complete sign-in callback", () => {
    const result = parseIrisDeepLink("iris://auth/callback?state=abc123&code=xyz789");
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.link.kind).toBe("authCallback");
    if (result.link.kind !== "authCallback") return;
    expect(result.link.authCallback).toEqual({
      authorizationCode: "xyz789",
      opaqueStateToken: "abc123",
    });
  });

  it("is not mistaken for a guide link, and a guide link is not mistaken for it", () => {
    const authResult = parseIrisDeepLink("iris://auth/callback?state=a&code=b");
    const guideResult = parseIrisDeepLink("iris://guide/cue?version=1");
    expect(authResult.ok && authResult.link.kind).toBe("authCallback");
    expect(guideResult.ok && guideResult.link.kind).toBe("guide");
  });

  it("rejects a code with no state — the shape a CSRF attempt takes", () => {
    expect(expectRejected("iris://auth/callback?code=xyz789")).toBe("incomplete Iris sign-in link");
    expect(expectRejected("iris://auth/callback?state=abc123")).toBe(
      "incomplete Iris sign-in link"
    );
    expect(expectRejected("iris://auth/callback")).toBe("incomplete Iris sign-in link");
  });

  it("rejects an unknown parameter on the callback too", () => {
    expect(expectRejected("iris://auth/callback?state=a&code=b&next=https://evil.tld")).toBe(
      "unsupported Iris sign-in parameter"
    );
  });

  it("rejects a duplicated callback parameter", () => {
    expect(expectRejected("iris://auth/callback?state=a&code=b&code=c")).toBe(
      "Iris sign-in links accept each parameter only once"
    );
  });

  it("rejects control characters in a code, which is how a crafted link breaks a log line", () => {
    const withNewline = `iris://auth/callback?state=a&code=${encodeURIComponent("b\ninjected")}`;
    expect(expectRejected(withNewline)).toBe("invalid Iris sign-in value");
  });

  it("rejects any auth path that is not exactly /callback", () => {
    expect(expectRejected("iris://auth/callback/extra?state=a&code=b")).toBe(
      "unsupported Iris link"
    );
    expect(expectRejected("iris://auth/token?state=a&code=b")).toBe("unsupported Iris link");
    expect(expectRejected("iris://auth?state=a&code=b")).toBe("unsupported Iris link");
  });
});

describe("slug and branch predicates", () => {
  it.each(["cue", "lunara", "nut-ai", "a", "a1", "1a", "no-scroll-2"])(
    "accepts the valid slug %s",
    (slug) => {
      expect(isValidGuideSlug(slug)).toBe(true);
    }
  );

  it.each(["", "-a", "a-", "A", "aA", "a_b", "a/b", "a".repeat(65)])(
    "rejects the invalid slug %s",
    (slug) => {
      expect(isValidGuideSlug(slug)).toBe(false);
    }
  );

  it("accepts exactly the six known branch keys and nothing else", () => {
    const platforms = ["macos", "windows"];
    const targets = ["ios", "android", "desktop"];
    let accepted = 0;
    for (const platform of platforms) {
      for (const target of targets) {
        expect(isValidBranchKey(`${platform}:${target}`)).toBe(true);
        accepted++;
      }
    }
    expect(accepted).toBe(6);
    expect(isValidBranchKey("linux:desktop")).toBe(false);
  });
});
