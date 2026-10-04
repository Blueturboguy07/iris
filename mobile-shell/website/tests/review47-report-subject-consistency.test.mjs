import assert from "node:assert/strict";
import test from "node:test";

import { renderCatalogHandoffHTML } from "../integration.mjs";

// Independent-verifier regression test for unit m3-guideline47. New file
// (no edits to any existing test file), added during adversarial
// verification. Guideline 4.7.1 requires "a mechanism to report content and
// timely responses to concerns": the report mail's subject line must carry
// the app's real display name as a real person would read it, not an
// HTML-escaped stand-in for it.
//
// Oracle: an independent decode of the mailto href's own subject query
// parameter (URLSearchParams, never any string this test constructs to
// match the implementation), checked against the exact display name given
// as input, not against whatever renderCatalogHandoffHTML happened to
// produce.
const CONTENT_HASH = `sha256:${"a".repeat(64)}`;

function rowNamed(name) {
  return {
    slug: "amp-app",
    name,
    guideSlug: "amp-app",
    macBundleId: null,
    latestReleaseTag: null,
    mobileShell: {
      version: 1,
      platform: "ios",
      packageFormat: "iris.mobile-shell.package+json",
      downloadUrl: "https://publikhq.com/artifacts/amp-app.irisapp",
      mediaType: "application/json",
      byteCount: 1,
      packageSha256: `sha256:${"b".repeat(64)}`,
      appId: "publik.amp-app",
      projectId: "publik.amp-app.mobile",
      baseRevisionId: null,
      revisionId: `rev-sha256:${CONTENT_HASH.slice(7)}`,
      contentHash: CONTENT_HASH,
      appStoreMetadata: {
        kind: "iris.mobile-shell.app-store-metadata",
        version: 1,
        ageRating: 4,
        privacySummary: "Keeps everything on this device.",
        privacyPolicyUrl: "https://publikhq.com/legal/privacy",
        supportContact: { kind: "email", value: "support@publikhq.com" },
        reportContact: { kind: "email", value: "report@publikhq.com" },
      },
    },
  };
}

test("the report mail's subject carries the app's real display name, not its HTML-escaped form", () => {
  // "Rock & Roll Tuner" is a real, plausible app display name: it just
  // happens to contain an HTML-significant character.
  const html = renderCatalogHandoffHTML({ catalogRows: [rowNamed("Rock & Roll Tuner")], selectedSlug: "amp-app" });
  const hrefMatch = html.match(/data-action="report-app" href="([^"]*)"/);
  assert.ok(hrefMatch, "expected a report-app link in the rendered page");
  // The href attribute is itself HTML-escaped (correctly: it sits inside a
  // double-quoted HTML attribute), so unescape it once to get the real
  // mailto: URL, exactly as a browser would before opening it.
  const mailtoURL = hrefMatch[1].replaceAll("&amp;", "&").replaceAll("&#39;", "'");
  const subject = new URL(mailtoURL).searchParams.get("subject");
  assert.equal(subject, "Report: Rock & Roll Tuner", "the mail app's subject field must show a real ampersand, not the literal text \"&amp;\"");
});
