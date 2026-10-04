import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  catalogRowsFromIndexV2,
  loadCatalogV2Rows,
  renderAppsIndexHTML,
  renderCatalogHandoffHTML,
  resolveCatalogHandoff,
} from "../integration.mjs";
import { generateCatalog } from "../../tools/catalog-fixture-generator/src/generate.mjs";

const SEED = "website-catalog-v2-adapter-tests";
const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES = path.resolve(HERE, "../../native/Tests/Fixtures/catalog-v2");

/** A simulated static site: serves a catalog directory, records every path asked for, and can drop files. */
function siteReader(root, { missing = new Set(), overrides = new Map() } = {}) {
  const requested = [];
  const readJSON = async (relativePath) => {
    requested.push(relativePath);
    if (overrides.has(relativePath)) return structuredClone(overrides.get(relativePath));
    if (missing.has(relativePath)) return null;
    try {
      return JSON.parse(await readFile(path.join(root, relativePath), "utf8"));
    } catch (error) {
      if (error.code === "ENOENT") return null;
      throw error;
    }
  };
  return { readJSON, requested };
}

function twoPagePublish(appCount = 260) {
  const catalog = generateCatalog({ seed: SEED, appCount });
  assert.equal(catalog.indexPages.length, 2);
  return catalog;
}

test("catalogRowsFromIndexV2 adapts a generated catalog into rows carrying each app page's own descriptor", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 20 });
  const rows = catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages });
  assert.equal(rows.length, 20);
  for (const row of rows) {
    assert.deepEqual(row.mobileShell, catalog.appPages.get(row.slug).mobileShell);
  }
  const handoff = resolveCatalogHandoff(rows, rows[7].slug);
  assert.equal(handoff.available, true);
  assert.equal(handoff.fallbackURL, `iris-apps://install/${rows[7].slug}`);
  const indexHTML = renderAppsIndexHTML({ catalogRows: rows });
  for (const row of rows) assert.ok(indexHTML.includes(row.slug), row.slug);
});

// R2-CP-3 (round3-deferred/M-store-screens): optional index-row
// `latestRevisionId` passed through by the adapter, backward compatible
// with a generated catalog that never set it.
test("catalogRowsFromIndexV2 passes through a row's latestRevisionId when the index sets one", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 5 });
  const targetSlug = catalog.indexPages[0].apps[0].slug;
  const revisionId = `rev-sha256:${"3".repeat(64)}`;
  catalog.indexPages[0].apps[0].latestRevisionId = revisionId;
  const rows = catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages });
  const row = rows.find((candidate) => candidate.slug === targetSlug);
  assert.equal(row.latestRevisionId, revisionId);
  // Every other row, untouched by this test, still normalizes to null.
  for (const other of rows) {
    if (other.slug !== targetSlug) assert.equal(other.latestRevisionId, null, other.slug);
  }
});

test("catalogRowsFromIndexV2 normalizes an absent latestRevisionId to null, never undefined", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 3 });
  assert.equal("latestRevisionId" in catalog.indexPages[0].apps[0], false, "fixture generator does not set this field");
  const rows = catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages });
  for (const row of rows) {
    assert.equal(row.latestRevisionId, null);
    assert.equal("latestRevisionId" in row, true, "the key itself must always be present, even when null");
  }
});

test("an index row with no app page is shown as not available, not dropped", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 3 });
  const missingSlug = catalog.indexPages[0].apps[0].slug;
  catalog.appPages.delete(missingSlug);
  const rows = catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages });
  assert.equal(rows.length, 3);
  const html = renderCatalogHandoffHTML({ catalogRows: rows, selectedSlug: missingSlug });
  assert.match(html, /is not available in Iris yet/);
  assert.doesNotMatch(html, /open-in-iris/);
});

test("a row whose size or age rating disagrees with its app page is not offered for install", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 4 });
  const [sizeSlug, ageSlug] = catalog.indexPages[0].apps.map((a) => a.slug);
  const pages = structuredClone(catalog.indexPages);
  pages[0].apps[0].byteCount += 1;
  const agedPage = structuredClone(catalog.appPages.get(ageSlug));
  agedPage.mobileShell.appStoreMetadata = {
    kind: "iris.mobile-shell.app-store-metadata",
    version: 1,
    ageRating: pages[0].apps[1].ageRating === 18 ? 4 : 18,
    privacySummary: "Stays on this device.",
    privacyPolicyUrl: "https://publikhq.com/legal/privacy",
    supportContact: { kind: "email", value: "support@publikhq.com" },
    reportContact: { kind: "email", value: "report@publikhq.com" },
  };
  const appPages = new Map(catalog.appPages);
  appPages.set(ageSlug, agedPage);
  const rows = catalogRowsFromIndexV2({ indexPages: pages, appPages });
  assert.equal(rows.find((r) => r.slug === sizeSlug).mobileShell, null);
  assert.equal(rows.find((r) => r.slug === ageSlug).mobileShell, null);
  assert.ok(rows.filter((r) => r.mobileShell !== null).length === 2);
  assert.match(renderCatalogHandoffHTML({ catalogRows: rows, selectedSlug: ageSlug }), /not available/);
});

test("malformed index pages and app pages fail closed", () => {
  assert.throws(
    () => catalogRowsFromIndexV2({ indexPages: [{ not: "a catalog page" }], appPages: new Map() }),
    /invalid/,
  );
  const catalog = generateCatalog({ seed: SEED, appCount: 2 });
  const slug = catalog.indexPages[0].apps[0].slug;
  catalog.appPages.set(slug, { ...catalog.appPages.get(slug), description: 12345 });
  assert.throws(() => catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages }), /invalid/);
});

test("a slug listed on two pages of one publish is refused", () => {
  const catalog = twoPagePublish();
  const pages = structuredClone(catalog.indexPages);
  pages[1].apps[0] = structuredClone(pages[0].apps[0]);
  assert.throws(() => catalogRowsFromIndexV2({ indexPages: pages, appPages: catalog.appPages }), /duplicate/);
});

test("pages from two different publishes, out of order, or missing are refused", () => {
  const catalog = twoPagePublish();
  const torn = structuredClone(catalog.indexPages);
  torn[1].generatedAt = "2026-09-01T00:00:00.000Z";
  assert.throws(() => catalogRowsFromIndexV2({ indexPages: torn, appPages: catalog.appPages }), /different publish/);
  const reversed = structuredClone(catalog.indexPages).reverse();
  assert.throws(() => catalogRowsFromIndexV2({ indexPages: reversed, appPages: catalog.appPages }), /labelled page/);
  assert.throws(
    () => catalogRowsFromIndexV2({ indexPages: [catalog.indexPages[0]], appPages: catalog.appPages }),
    /has 1 pages but page 1 says 2/,
  );
});

test("loadCatalogV2Rows reads the checked-in 1,000-app fixture publish: 4 pages, every app installable", async () => {
  const site = siteReader(path.join(FIXTURES, "1000"));
  const rows = await loadCatalogV2Rows({ readJSON: site.readJSON });
  assert.equal(rows.length, 1000);
  assert.ok(rows.every((row) => row.mobileShell !== null));
  assert.deepEqual(site.requested.slice(0, 4), ["index.json", "index-2.json", "index-3.json", "index-4.json"]);
  assert.equal(site.requested.filter((p) => p.startsWith("apps/")).length, 1000);
});

test("loadCatalogV2Rows marks an app unavailable when its page is not published, and reports a missing index", async () => {
  const index = JSON.parse(await readFile(path.join(FIXTURES, "3", "index.json"), "utf8"));
  const gone = index.apps[1].slug;
  const site = siteReader(path.join(FIXTURES, "3"), { missing: new Set([`apps/${gone}.json`]) });
  const rows = await loadCatalogV2Rows({ readJSON: site.readJSON });
  assert.deepEqual(rows.map((r) => [r.slug, r.mobileShell !== null]), index.apps.map((a) => [a.slug, a.slug !== gone]));

  const empty = siteReader(path.join(FIXTURES, "3"), { missing: new Set(["index.json"]) });
  await assert.rejects(() => loadCatalogV2Rows({ readJSON: empty.readJSON }), /not published/);

  const shortSite = siteReader(path.join(FIXTURES, "1000"), { missing: new Set(["index-3.json"]) });
  await assert.rejects(() => loadCatalogV2Rows({ readJSON: shortSite.readJSON }), /page 3 of 4 is missing/);
});

test("a hostile page 2 slug never becomes a file read outside the catalog", async () => {
  const page2 = JSON.parse(await readFile(path.join(FIXTURES, "1000", "index-2.json"), "utf8"));
  page2.apps[0].slug = "../../../../etc/passwd";
  const site = siteReader(path.join(FIXTURES, "1000"), { overrides: new Map([["index-2.json", page2]]) });
  await assert.rejects(() => loadCatalogV2Rows({ readJSON: site.readJSON }), /invalid/);
  assert.equal(site.requested.some((p) => p.includes("..")), false, site.requested.filter((p) => p.includes("..")).join(", "));
});

test("the App Store / TestFlight join URL rule still governs pages built from catalog v2", () => {
  const catalog = generateCatalog({ seed: SEED, appCount: 3 });
  const rows = catalogRowsFromIndexV2({ indexPages: catalog.indexPages, appPages: catalog.appPages });
  const slug = rows[0].slug;
  const testflight = renderCatalogHandoffHTML({
    catalogRows: rows,
    selectedSlug: slug,
    irisDistributionURL: "https://testflight.apple.com/join/AbCd1234",
  });
  assert.match(testflight, /data-action="install-iris" href="https:\/\/testflight\.apple\.com\/join\/AbCd1234"/);
  const appStore = renderCatalogHandoffHTML({
    catalogRows: rows,
    selectedSlug: slug,
    irisDistributionURL: "https://apps.apple.com/us/app/example/id123456789",
  });
  assert.match(appStore, /href="https:\/\/apps\.apple\.com\/us\/app\/example\/id123456789"/);
  for (const hostile of ["https://evil.example/join/AbCd1234", "https://testflight.apple.com.evil.example/join/AbCd1234", "javascript:alert(1)"]) {
    assert.throws(() => renderCatalogHandoffHTML({ catalogRows: rows, selectedSlug: slug, irisDistributionURL: hostile }), hostile);
  }
  assert.match(renderCatalogHandoffHTML({ catalogRows: rows, selectedSlug: slug }), /data-install-route="unavailable"/);
});
