// New test file for unit m3-guideline47 (App Store Guideline 4.7 obligations).
// Covers isReadyForAppStoreListing, the resolveCatalogHandoff/renderCatalogHandoffHTML
// additions, and renderAppsIndexHTML. Does not duplicate integration.test.mjs's
// or edge-cases.test.mjs's own assertions about the pre-existing behavior.
import assert from "node:assert/strict";
import test from "node:test";

import {
  isReadyForAppStoreListing,
  renderAppsIndexHTML,
  renderCatalogHandoffHTML,
  resolveCatalogHandoff,
} from "../integration.mjs";

const CONTENT_HASH = `sha256:${"a".repeat(64)}`;
const GOOD_METADATA = Object.freeze({
  kind: "iris.mobile-shell.app-store-metadata",
  version: 1,
  ageRating: 4,
  privacySummary: "Nut AI keeps meal logs on this device only.",
  privacyPolicyUrl: "https://publikhq.com/legal/privacy",
  supportContact: { kind: "email", value: "support@publikhq.com" },
  reportContact: { kind: "email", value: "report@publikhq.com" },
});

function descriptor(overrides = {}) {
  return {
    version: 1,
    platform: "ios",
    packageFormat: "iris.mobile-shell.package+json",
    downloadUrl: "https://publikhq.com/artifacts/nut-ai.irisapp",
    mediaType: "application/json",
    byteCount: 12345,
    packageSha256: `sha256:${"b".repeat(64)}`,
    appId: "publik.nut-ai",
    projectId: "publik.nut-ai.mobile",
    baseRevisionId: null,
    revisionId: `rev-sha256:${"a".repeat(64)}`,
    contentHash: CONTENT_HASH,
    ...overrides,
  };
}

function row(slug, name, mobileShell) {
  return { slug, name, guideSlug: slug, macBundleId: null, latestReleaseTag: null, mobileShell };
}

test("isReadyForAppStoreListing is false for an absent or missing-field descriptor, true for a valid one", () => {
  assert.equal(isReadyForAppStoreListing(null), false);
  assert.equal(isReadyForAppStoreListing(descriptor()), false, "no appStoreMetadata field at all");
  assert.equal(isReadyForAppStoreListing(descriptor({ appStoreMetadata: null })), false);
  assert.equal(
    isReadyForAppStoreListing(descriptor({ appStoreMetadata: { ...GOOD_METADATA, ageRating: 99 } })),
    false,
    "an invalid metadata object must not be reported ready",
  );
  assert.equal(isReadyForAppStoreListing(descriptor({ appStoreMetadata: GOOD_METADATA })), true);
});

test("resolveCatalogHandoff surfaces listingReady=false and appStoreMetadata=null for an old descriptor, but still marks it available/installable", () => {
  const handoff = resolveCatalogHandoff([row("nut-ai", "Nut AI", descriptor())], "nut-ai");
  assert.equal(handoff.available, true, "an old descriptor with no App Store metadata still installs");
  assert.equal(handoff.listingReady, false);
  assert.equal(handoff.appStoreMetadata, null);
});

test("resolveCatalogHandoff surfaces the validated appStoreMetadata and listingReady=true when present", () => {
  const handoff = resolveCatalogHandoff(
    [row("nut-ai", "Nut AI", descriptor({ appStoreMetadata: GOOD_METADATA }))],
    "nut-ai",
  );
  assert.equal(handoff.listingReady, true);
  assert.equal(handoff.appStoreMetadata.ageRating, 4);
});

test("a hostile appStoreMetadata on a catalog row is rejected before any HTML is rendered", () => {
  const hostileRows = [row("nut-ai", "Nut AI", descriptor({
    appStoreMetadata: { ...GOOD_METADATA, privacyPolicyUrl: "javascript:alert(1)" },
  }))];
  assert.throws(() => resolveCatalogHandoff(hostileRows, "nut-ai"), /appStoreMetadata/);
  assert.throws(
    () => renderCatalogHandoffHTML({ catalogRows: hostileRows, selectedSlug: "nut-ai" }),
    /appStoreMetadata/,
  );
});

test("renderCatalogHandoffHTML shows the privacy summary, age rating, and a report link when metadata is present", () => {
  const html = renderCatalogHandoffHTML({
    catalogRows: [row("nut-ai", "Nut AI", descriptor({ appStoreMetadata: GOOD_METADATA }))],
    selectedSlug: "nut-ai",
  });
  assert.match(html, /data-age-rating="4"/);
  assert.match(html, /Nut AI keeps meal logs on this device only\./);
  // The privacy policy URL in the metadata is this site's own origin
  // ("https://publikhq.com/legal/privacy"), so the rendered link is
  // root-relative ("/legal/privacy"), not the absolute URL: see the
  // regression test below for why (a blind test on a locally served copy
  // of a real app page followed the absolute publikhq.com link and left
  // the page being tested entirely).
  assert.match(html, /data-privacy-policy-link href="\/legal\/privacy"/);
  assert.doesNotMatch(html, /data-privacy-policy-link href="https:\/\/publikhq\.com/);
  assert.match(html, /data-action="report-app" href="mailto:report@publikhq\.com\?subject=Report%3A%20Nut%20AI"/);
});

// Regression test: a real blind test on a locally served copy of the
// Kneecap app page tapped "Privacy policy" (privacyPolicyUrl
// "https://publikhq.com/iris/privacy", the site's own production URL) and
// left the page under test entirely, landing on the real internet's
// publikhq.com, which showed that unrelated site's own 404 page. The fix
// (siteRelativeIfSameOrigin in integration.mjs) applies to every
// same-origin privacyPolicyUrl, not just this one example, so this test
// uses the actual production value rather than a synthetic one.
test("a privacy policy URL pointing at this site's own production origin never leaves the page as a cross-host link", () => {
  const html = renderCatalogHandoffHTML({
    catalogRows: [row("kneecap", "Kneecap", descriptor({
      appId: "publik.kneecap",
      appStoreMetadata: { ...GOOD_METADATA, privacyPolicyUrl: "https://publikhq.com/iris/privacy" },
    }))],
    selectedSlug: "kneecap",
  });
  assert.match(html, /data-privacy-policy-link href="\/iris\/privacy"/);
  assert.doesNotMatch(html, /data-privacy-policy-link href="https:\/\/publikhq\.com/);
});

test("renderCatalogHandoffHTML shows an honest not-yet-rated notice when metadata is absent, and never fabricates one", () => {
  const html = renderCatalogHandoffHTML({
    catalogRows: [row("nut-ai", "Nut AI", descriptor())],
    selectedSlug: "nut-ai",
  });
  assert.match(html, /data-app-store-listing-ready="false"/);
  assert.doesNotMatch(html, /data-age-rating/);
  assert.doesNotMatch(html, /data-action="report-app"/);
});

test("a hostile display name in the privacy block is escaped like the rest of the page", () => {
  const hostileName = `Nut <img src=x onerror="alert(1)">`;
  const html = renderCatalogHandoffHTML({
    catalogRows: [row("nut-ai", hostileName, descriptor({ appStoreMetadata: GOOD_METADATA }))],
    selectedSlug: "nut-ai",
  });
  assert.doesNotMatch(html, /<img/);
});

test("renderAppsIndexHTML lists every app with its universal link, satisfying Guideline 4.7.4's index requirement", () => {
  const rows = [
    row("kneecap", "Kneecap", descriptor({ appId: "publik.kneecap", appStoreMetadata: { ...GOOD_METADATA, ageRating: 9 } })),
    row("nut-ai", "Nut AI", descriptor({ appId: "publik.nut-ai" })), // not yet rated
    row("desktop-only", "Desktop Only App", null),
  ];
  const html = renderAppsIndexHTML({ catalogRows: rows });
  assert.match(html, /data-universal-link href="https:\/\/publikhq\.com\/iris\/apps\/kneecap">Kneecap<\/a>/);
  assert.match(html, /data-age-rating="9">9\+<\/span>/);
  assert.match(html, /data-universal-link href="https:\/\/publikhq\.com\/iris\/apps\/nut-ai">Nut AI<\/a>/);
  assert.match(html, /data-age-rating-missing="true"/);
  assert.match(html, /data-universal-link href="https:\/\/publikhq\.com\/iris\/apps\/desktop-only">Desktop Only App<\/a>/);
  assert.match(html, /data-app-slug="kneecap" data-listing-ready="true"/);
  assert.match(html, /data-app-slug="nut-ai" data-listing-ready="false"/);
  assert.match(html, /data-app-slug="desktop-only" data-listing-ready="false"/);
});

test("renderAppsIndexHTML rejects a malformed catalog the same way resolveCatalogHandoff does", () => {
  assert.throws(() => renderAppsIndexHTML({ catalogRows: "not-an-array" }), /catalog rows must be an array/);
  assert.throws(
    () => renderAppsIndexHTML({ catalogRows: [row("dup", "One", null), row("dup", "Two", null)] }),
    /duplicate catalog app slug: dup/,
  );
});
