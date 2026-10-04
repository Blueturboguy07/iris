// RC-03 (round5/rc03-website). Oracles: the contracts validators (an
// independently written schema, not this generator's own opinion of
// itself), the real starter package bytes, and the checked-in site copy.

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { validateCatalogAppPageV1, validateCatalogIndexEntryMatchesAppPage, validateCatalogIndexV2 } from "../../contracts/index.js";
import { SITE_GENERATED_AT, SITE_OUT, buildSite } from "../build-site.mjs";
import { catalogRowsFromIndexV2, resolveCatalogHandoff } from "../integration.mjs";
import { AGE_RATING_BY_SLUG, PLACEHOLDER_APPLE_TEAM_ID, RELEASE_BUNDLE_ID } from "../site-content.mjs";

test("buildSite produces a valid catalog v2 (index, categories, four app pages) with App Store metadata attached", async () => {
  const { files, catalogRows } = await buildSite();
  const index = JSON.parse(files.get("api/iris/mobile/index.json").toString("utf8"));
  assert.equal(validateCatalogIndexV2(index).ok, true);
  assert.equal(index.pageCount, 1);
  assert.equal(index.generatedAt, SITE_GENERATED_AT);
  assert.deepEqual(index.apps.map((app) => app.slug).sort(), ["freeharmony", "kneecap", "lunara", "nut-ai"]);

  for (const entry of index.apps) {
    const page = JSON.parse(files.get(`api/iris/mobile/apps/${entry.slug}.json`).toString("utf8"));
    const pageResult = validateCatalogAppPageV1(page);
    assert.equal(pageResult.ok, true, pageResult.errors?.join("; "));
    assert.ok(page.mobileShell.appStoreMetadata, `${entry.slug} carries appStoreMetadata`);
    assert.equal(page.mobileShell.appStoreMetadata.ageRating, AGE_RATING_BY_SLUG[entry.slug]);
    assert.equal(entry.ageRating, AGE_RATING_BY_SLUG[entry.slug], "index row age rating matches the decided rating");
    const agreement = validateCatalogIndexEntryMatchesAppPage(entry, page);
    assert.equal(agreement.ok, true, agreement.errors?.join("; "));
    assert.equal(page.mobileShell.appStoreMetadata.privacyPolicyUrl, "https://publikhq.com/iris/privacy");
    assert.equal(page.mobileShell.appStoreMetadata.reportContact.value, "report@publikhq.com");
    assert.equal(page.mobileShell.appStoreMetadata.supportContact.value, "support@publikhq.com");
    assert.ok(entry.latestRevisionId, "R2-CP-3: an installed starter never looks out of date");
    assert.equal(entry.latestRevisionId, page.mobileShell.revisionId);
  }

  // Every row is a fully installable, App-Store-listing-ready app: the same
  // adapter the native shell and the handoff pages use, applied to this
  // build's own output.
  for (const row of catalogRows) {
    const handoff = resolveCatalogHandoff(catalogRows, row.slug);
    assert.equal(handoff.available, true, row.slug);
    assert.equal(handoff.listingReady, true, row.slug);
  }
});

test("Nut AI is rated 13+ on the live website (OD-08), even though the seed bundled in the app is not this unit's file to change", async () => {
  const { files } = await buildSite();
  const page = JSON.parse(files.get("api/iris/mobile/apps/nut-ai.json").toString("utf8"));
  assert.equal(page.mobileShell.appStoreMetadata.ageRating, 13);
  const index = JSON.parse(files.get("api/iris/mobile/index.json").toString("utf8"));
  assert.equal(index.apps.find((app) => app.slug === "nut-ai").ageRating, 13);
});

test("the AASA file names the placeholder team id until Apple Developer enrollment (OD-11) supplies a real one", async () => {
  const { files } = await buildSite();
  const aasa = JSON.parse(files.get(".well-known/apple-app-site-association").toString("utf8"));
  assert.equal(aasa.applinks.details[0].appID, `${PLACEHOLDER_APPLE_TEAM_ID}.${RELEASE_BUNDLE_ID}`);
  assert.deepEqual(aasa.applinks.details[0].paths, ["/iris/apps/*"]);
});

test("every published app has its own website page, and the page names the real package it installs", async () => {
  const { files } = await buildSite();
  const index = JSON.parse(files.get("api/iris/mobile/index.json").toString("utf8"));
  for (const entry of index.apps) {
    const html = files.get(`iris/apps/${entry.slug}/index.html`).toString("utf8");
    assert.match(html, new RegExp(entry.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.match(html, /Open in Iris/);
    assert.match(html, /href="\/iris\/privacy"/);
    assert.match(html, /href="\/iris\/support"/);
  }
});

test("the privacy and support pages exist and name a real contact", async () => {
  const { files } = await buildSite();
  const privacy = files.get("iris/privacy/index.html").toString("utf8");
  const support = files.get("iris/support/index.html").toString("utf8");
  assert.match(privacy, /support@publikhq\.com/);
  assert.match(support, /support@publikhq\.com/);
  assert.match(support, /report@publikhq\.com|mailto:support@publikhq\.com/);
});

test("the checked-in website build is exactly what the generator writes", async () => {
  const { files } = await buildSite();
  for (const [relativePath, bytes] of files) {
    const dest = path.join(SITE_OUT, relativePath);
    const onDisk = await readFile(dest);
    assert.ok(onDisk.equals(bytes), `${path.relative(process.cwd(), dest)} is out of date: run node mobile-shell/website/build-site.mjs`);
  }
});
