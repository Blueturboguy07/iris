import { describe, expect, it } from "vitest";
import {
  ALLOWED_EXTERNAL_HOSTS,
  classifyExternalLink,
  isAllowedExternalHost,
  refusalMessage,
} from "../src/services/external-links";

/**
 * The allowlist is the Windows copy of `allowed_external_host` in
 * `iris-desktop/src-tauri/src/main.rs`. Two properties matter:
 *
 *   1. A lookalike host must not be mistaken for an allowed one. `github.com`
 *      being on the list must not let `github.com.evil.tld` through.
 *   2. A blocked host must be REPORTED, not silently dropped. That is the
 *      iris-desktop 0.1.4 dead-button bug: a step pointing at a host nobody had
 *      allowlisted rendered a control that did nothing at all.
 */

describe("the allowlist itself", () => {
  it("has exactly the 22 hosts main.rs allows", () => {
    expect(ALLOWED_EXTERNAL_HOSTS.size).toBe(22);
  });

  it("contains every host `allowed_external_host` names", () => {
    // Transcribed from main.rs. If this ever drifts, a published guide sends a
    // reader somewhere the desktop app refuses to open.
    const hostsFromMainRs = [
      "publikhq.com",
      "www.publikhq.com",
      "github.com",
      "docs.github.com",
      "git-scm.com",
      "nodejs.org",
      "www.python.org",
      "python.org",
      "rustup.rs",
      "docker.com",
      "www.docker.com",
      "docs.docker.com",
      "developer.apple.com",
      "learn.microsoft.com",
      "apps.apple.com",
      "developer.android.com",
      "huggingface.co",
      "visualstudio.microsoft.com",
      "cmake.org",
      "www.cmake.org",
      "files.browseros.com",
      "go.dev",
    ];
    expect(hostsFromMainRs).toHaveLength(22);
    for (const host of hostsFromMainRs) {
      expect(isAllowedExternalHost(host), `${host} should be allowlisted`).toBe(true);
    }
  });

  it("includes files.browseros.com, the host whose absence caused the dead button", () => {
    expect(isAllowedExternalHost("files.browseros.com")).toBe(true);
  });
});

describe("accepting known hosts", () => {
  it.each([
    "https://github.com/Blueturboguy07/publik",
    "https://publikhq.com/cue",
    "https://docs.github.com/en/get-started",
    "https://files.browseros.com/download/win",
    "https://go.dev/dl/",
  ])("allows %s", (url) => {
    const classification = classifyExternalLink(url);
    expect(classification.allowed).toBe(true);
  });

  it("matches the host case-insensitively", () => {
    expect(classifyExternalLink("https://GitHub.COM/publik").allowed).toBe(true);
  });

  it("allows loopback for a locally-run publik", () => {
    expect(classifyExternalLink("http://localhost:3000/cue").allowed).toBe(true);
    expect(classifyExternalLink("http://127.0.0.1:3000/cue").allowed).toBe(true);
  });
});

describe("rejecting lookalikes", () => {
  it.each([
    "https://github.com.evil.tld/publik",
    "https://publikhq.com.evil.tld",
    "https://notgithub.com",
    "https://github.com.co",
    "https://evilgithub.com",
    "https://sub.github.com.attacker.io",
  ])("rejects the lookalike %s", (url) => {
    const classification = classifyExternalLink(url);
    expect(classification.allowed).toBe(false);
  });

  it("names the host it refused, so the UI can render a disabled control", () => {
    const classification = classifyExternalLink("https://github.com.evil.tld/publik");
    expect(classification.allowed).toBe(false);
    if (classification.allowed) return;
    expect(classification.host).toBe("github.com.evil.tld");
    expect(classification.reason).toBe("hostNotAllowlisted");
    // The refusal must be a sentence naming the host — never silence.
    expect(refusalMessage(classification)).toContain("github.com.evil.tld");
  });

  it("is not fooled by credentials that make an allowed host appear in the userinfo", () => {
    // `https://github.com@evil.tld` has hostname evil.tld, not github.com.
    const classification = classifyExternalLink("https://github.com@evil.tld/x");
    expect(classification.allowed).toBe(false);
  });

  it("rejects a non-https scheme even on an allowed host", () => {
    const classification = classifyExternalLink("http://github.com/publik");
    expect(classification.allowed).toBe(false);
    if (classification.allowed) return;
    expect(classification.reason).toBe("schemeNotAllowed");
  });

  it.each(["file:///C:/Windows/System32/cmd.exe", "javascript:alert(1)", "data:text/html,<h1>x"])(
    "rejects the dangerous scheme in %s",
    (url) => {
      expect(classifyExternalLink(url).allowed).toBe(false);
    }
  );

  it("rejects nonsense without throwing", () => {
    for (const value of ["", "not a url", null, undefined, 42, {}]) {
      const classification = classifyExternalLink(value);
      expect(classification.allowed).toBe(false);
      expect(refusalMessage(classification)).toBeTruthy();
    }
  });
});

describe("every refusal produces something a person can read", () => {
  it("returns null for an allowed link and a sentence for a blocked one", () => {
    expect(refusalMessage(classifyExternalLink("https://github.com"))).toBeNull();
    for (const url of ["https://evil.tld", "http://github.com", "javascript:x", "garbage"]) {
      const message = refusalMessage(classifyExternalLink(url));
      expect(message, `${url} should produce a message`).toBeTruthy();
      expect(message!.length).toBeGreaterThan(10);
    }
  });
});
