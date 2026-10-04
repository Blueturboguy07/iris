import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  canonicalJSONString,
  validateCatalogAppPageV1,
  validateCatalogCategoriesV1,
  validateCatalogIndexV2,
} from "../../contracts/index.js";
import { generateCatalog } from "../../tools/catalog-fixture-generator/src/generate.mjs";
import { emitCatalogV2, verifyWrittenCatalogV2, writeCatalogV2 } from "../catalog-v2.mjs";

const GENERATED_AT = "2026-09-28T00:00:00.000Z";

/** Reviewed app descriptors, built from the deterministic fixture generator so tests exercise realistic shapes without duplicating its word lists. */
function reviewedApps(appCount, seed = "publisher-catalog-emit-tests") {
  const catalog = generateCatalog({ seed, appCount });
  const indexEntries = catalog.indexPages.flatMap((p) => p.apps);
  return indexEntries.map((entry) => ({ ...entry, ...catalog.appPages.get(entry.slug) }));
}

function reviewedCategories() {
  return generateCatalog({ seed: "publisher-catalog-emit-tests", appCount: 0 }).categories.categories
    .map(({ id, name, order }) => ({ id, name, order }));
}

test("emitCatalogV2 produces a fully valid, non-empty catalog", () => {
  const apps = reviewedApps(30);
  const emitted = emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  assert.equal(emitted.appPages.size, 30);
  for (const page of emitted.indexPages) assert.equal(validateCatalogIndexV2(page).ok, true);
  assert.equal(validateCatalogCategoriesV1(emitted.categories).ok, true);
  for (const [, appPage] of emitted.appPages) assert.equal(validateCatalogAppPageV1(appPage).ok, true);
  assert.match(emitted.catalogEmitHash, /^sha256:[0-9a-f]{64}$/);
});

test("emitCatalogV2 is deterministic: same input (any array order) produces byte-identical output", () => {
  const apps = reviewedApps(15);
  const a = emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  const shuffled = [...apps].reverse();
  const b = emitCatalogV2({ apps: shuffled, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  assert.equal(a.catalogEmitHash, b.catalogEmitHash);
  assert.deepEqual(a.indexPages, b.indexPages);
});

test("emitCatalogV2 recomputes categories.appCount from the reviewed apps, ignoring a caller-supplied stale count", () => {
  const apps = reviewedApps(40);
  const staleCategories = reviewedCategories().map((c) => ({ ...c, appCount: 999999 }));
  const emitted = emitCatalogV2({ apps, categories: staleCategories, generatedAt: GENERATED_AT });
  // Independent count straight from the reviewed input.
  const expected = new Map();
  for (const app of apps) for (const id of app.categoryIds) expected.set(id, (expected.get(id) ?? 0) + 1);
  for (const category of emitted.categories.categories) {
    assert.equal(category.appCount, expected.get(category.id) ?? 0, `category ${category.id}`);
  }
});

test("emitCatalogV2 refuses an app whose store size differs from its reviewed package size", () => {
  const apps = reviewedApps(3);
  const wrong = apps.map((app, i) => (i === 1 ? { ...app, byteCount: app.mobileShell.byteCount + 1 } : app));
  assert.throws(
    () => emitCatalogV2({ apps: wrong, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
    new RegExp(`${apps[1].slug}: index byteCount`),
  );
});

test("emitCatalogV2 refuses an app filed under a category that categories.json does not have", () => {
  const apps = reviewedApps(2);
  const categories = reviewedCategories().filter((c) => !apps[0].categoryIds.includes(c.id));
  assert.throws(() => emitCatalogV2({ apps, categories, generatedAt: GENERATED_AT }), /not in categories\.json/);
});

test("emitCatalogV2 refuses a path-traversal slug before anything could be written", () => {
  const apps = reviewedApps(2);
  const hostile = apps.map((app, i) => (i === 0 ? { ...app, slug: "../../outside" } : app));
  assert.throws(() => emitCatalogV2({ apps: hostile, categories: reviewedCategories(), generatedAt: GENERATED_AT }), /unsafe slug/);
});

test("emitted files are compact canonical JSON and their listed sha256 values match the exact bytes", () => {
  const emitted = emitCatalogV2({ apps: reviewedApps(12), categories: reviewedCategories(), generatedAt: GENERATED_AT });
  assert.ok(emitted.fileTexts.has("index.json") && emitted.fileTexts.has("categories.json"));
  for (const [filePath, text] of emitted.fileTexts) {
    assert.equal(text.endsWith("\n"), true);
    assert.equal(text.slice(0, -1).includes("\n"), false, `${filePath} must be one line`);
    assert.equal(emitted.files[filePath], `sha256:${createHash("sha256").update(text).digest("hex")}`);
    assert.equal(canonicalJSONString(JSON.parse(text)), text.slice(0, -1), `${filePath} must use sorted keys`);
  }
  // Changing one app's summary changes that app's index page hash and the catalog hash, and nothing else.
  const apps = reviewedApps(12);
  const edited = apps.map((app, i) => (i === 5 ? { ...app, summary: "Edited summary for testing" } : app));
  const again = emitCatalogV2({ apps: edited, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  const changed = Object.keys(emitted.files).filter((p) => emitted.files[p] !== again.files[p]);
  assert.deepEqual(changed, ["index.json"]);
  assert.notEqual(again.catalogEmitHash, emitted.catalogEmitHash);
});

test("a 10,000-app reviewed set becomes 40 valid pages of 250", () => {
  const emitted = emitCatalogV2({ apps: reviewedApps(10000), categories: reviewedCategories(), generatedAt: GENERATED_AT });
  assert.equal(emitted.indexPages.length, 40);
  assert.ok(emitted.indexPages.every((page) => page.apps.length === 250 && page.pageCount === 40));
});

test("emitCatalogV2 rejects a duplicate slug in the reviewed set", () => {
  const apps = reviewedApps(3);
  const withDuplicate = [...apps, { ...apps[0] }];
  assert.throws(
    () => emitCatalogV2({ apps: withDuplicate, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
    /duplicate app slug/,
  );
});

// MV3 (mobile-versions SPEC.md section 2.6/owner decision 3, 2026-09-28):
// `latestRevisionId` lets My apps show "Update available" and the Features
// page's "Download" button work for the most-recently-published revision,
// without fetching the app's own page first. The contract's validator
// (R2-CP-3) already accepted this optional field; the emitter did not carry
// it through from a reviewed descriptor until this unit.
test("emitCatalogV2 carries a reviewed app's latestRevisionId into its index row when supplied", () => {
  const apps = reviewedApps(3);
  const withRevision = apps.map((app, i) => (
    i === 0 ? { ...app, latestRevisionId: app.mobileShell.revisionId } : app
  ));
  const emitted = emitCatalogV2({ apps: withRevision, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  const row = emitted.indexPages[0].apps.find((entry) => entry.slug === withRevision[0].slug);
  assert.equal(row.latestRevisionId, withRevision[0].mobileShell.revisionId);
  for (const page of emitted.indexPages) assert.equal(validateCatalogIndexV2(page).ok, true);
  // Every other row, which never supplied the field, keeps no such key at
  // all (not even `null`) -- the contract's own "backward compatible" rule.
  const untouchedRow = emitted.indexPages[0].apps.find((entry) => entry.slug !== withRevision[0].slug);
  assert.equal("latestRevisionId" in untouchedRow, false);
});

test("emitCatalogV2 carries an explicit null latestRevisionId (not known yet) through unchanged", () => {
  const apps = reviewedApps(2);
  const withNull = apps.map((app, i) => (i === 0 ? { ...app, latestRevisionId: null } : app));
  const emitted = emitCatalogV2({ apps: withNull, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  const row = emitted.indexPages[0].apps.find((entry) => entry.slug === withNull[0].slug);
  assert.equal(row.latestRevisionId, null);
  for (const page of emitted.indexPages) assert.equal(validateCatalogIndexV2(page).ok, true);
});

test("emitCatalogV2 rejects a latestRevisionId that is not a real revision id (never a spoofable arbitrary string)", () => {
  const apps = reviewedApps(2);
  const spoofed = apps.map((app, i) => (i === 0 ? { ...app, latestRevisionId: "not-a-revision-id" } : app));
  assert.throws(
    () => emitCatalogV2({ apps: spoofed, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
    /latestRevisionId is invalid/,
  );
});

// RC-05 (round 6): the optional `publisher` ("By Publik") rides through the same way.
test("emitCatalogV2 carries a reviewed app's publisher into its index row when supplied, and nothing otherwise", () => {
  const apps = reviewedApps(3);
  const named = apps.map((app, i) => (i === 0 ? { ...app, publisher: "Publik" } : app));
  const emitted = emitCatalogV2({ apps: named, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  const row = emitted.indexPages[0].apps.find((entry) => entry.slug === named[0].slug);
  assert.equal(row.publisher, "Publik");
  for (const page of emitted.indexPages) assert.equal(validateCatalogIndexV2(page).ok, true);
  const other = emitted.indexPages[0].apps.find((entry) => entry.slug !== named[0].slug);
  assert.equal("publisher" in other, false, "a row that never named a publisher keeps no such key");
});

test("emitCatalogV2 rejects an unsafe publisher (markup, blank, padded) instead of publishing it", () => {
  for (const bad of ["<b>Publik</b>", "", " Publik", "Pub\nlik"]) {
    const apps = reviewedApps(2).map((app, i) => (i === 0 ? { ...app, publisher: bad } : app));
    assert.throws(
      () => emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
      /publisher/,
      `publisher ${JSON.stringify(bad)} must be refused`,
    );
  }
});

test("emitCatalogV2 rejects a reviewed descriptor missing a required detail field", () => {
  const apps = reviewedApps(2);
  const broken = apps.map((app, i) => (i === 0 ? { ...app, privacySummary: undefined } : app));
  assert.throws(
    () => emitCatalogV2({ apps: broken, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
    /missing catalog detail field/,
  );
});

test("emitCatalogV2 fails closed on a hostile field instead of publishing it", () => {
  const apps = reviewedApps(2);
  const hostile = apps.map((app, i) => (i === 0 ? { ...app, supportURL: "javascript:alert(1)" } : app));
  assert.throws(
    () => emitCatalogV2({ apps: hostile, categories: reviewedCategories(), generatedAt: GENERATED_AT }),
    /invalid/,
  );
});

test("emitCatalogV2 splits large reviewed sets across multiple pages at the same 250-per-page limit", () => {
  const apps = reviewedApps(600);
  const emitted = emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT });
  assert.equal(emitted.indexPages.length, 3);
  assert.equal(emitted.indexPages[0].apps.length, 250);
  assert.equal(emitted.indexPages[1].apps.length, 250);
  assert.equal(emitted.indexPages[2].apps.length, 100);
});

test("emitCatalogV2 rejects a non-canonical generatedAt instead of silently normalizing it", () => {
  const apps = reviewedApps(1);
  assert.throws(
    () => emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: "2026-09-28" }),
  );
});

test("writeCatalogV2 refuses to overwrite an existing publish unless told to", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-"));
  try {
    const apps = reviewedApps(4);
    const emitted = emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT });
    await writeCatalogV2(tmp, emitted);
    await assert.rejects(() => writeCatalogV2(tmp, emitted), /already holds a catalog/);
    await assert.doesNotReject(() => writeCatalogV2(tmp, emitted, { overwrite: true }));

    const index = JSON.parse(await readFile(path.join(tmp, "index.json"), "utf8"));
    assert.equal(validateCatalogIndexV2(index).ok, true);
    const manifest = JSON.parse(await readFile(path.join(tmp, "manifest.json"), "utf8"));
    assert.equal(manifest.appCount, 4);
    assert.equal(manifest.catalogEmitHash, emitted.catalogEmitHash);
    assert.deepEqual(await verifyWrittenCatalogV2(tmp), []);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test("a changed catalog must carry a new generatedAt, because clients skip unchanged pages", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-"));
  try {
    const apps = reviewedApps(300);
    await writeCatalogV2(tmp, emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT }));
    const before = await readFile(path.join(tmp, "index-2.json"), "utf8");
    // An app on page 2 changes; page 1 would be byte-identical.
    const edited = apps.map((app) => (app.slug === JSON.parse(before).apps[0].slug ? { ...app, summary: "A new summary" } : app));
    const sameStamp = emitCatalogV2({ apps: edited, categories: reviewedCategories(), generatedAt: GENERATED_AT });
    await assert.rejects(() => writeCatalogV2(tmp, sameStamp, { overwrite: true }), /needs a new generatedAt/);
    assert.equal(await readFile(path.join(tmp, "index-2.json"), "utf8"), before, "a refused write must not touch the publish");

    const newStamp = emitCatalogV2({ apps: edited, categories: reviewedCategories(), generatedAt: "2026-09-29T00:00:00.000Z" });
    await writeCatalogV2(tmp, newStamp, { overwrite: true });
    assert.notEqual(await readFile(path.join(tmp, "index.json"), "utf8"), sameStamp.fileTexts.get("index.json"));
    assert.deepEqual(await verifyWrittenCatalogV2(tmp), []);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test("pages of removed apps are reported as stale, and only removed with pruneStale", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-"));
  try {
    const apps = reviewedApps(5);
    await writeCatalogV2(tmp, emitCatalogV2({ apps, categories: reviewedCategories(), generatedAt: GENERATED_AT }));
    const removed = apps[2].slug;
    const fewer = emitCatalogV2({
      apps: apps.filter((app) => app.slug !== removed),
      categories: reviewedCategories(),
      generatedAt: "2026-09-29T00:00:00.000Z",
    });
    await assert.rejects(() => writeCatalogV2(tmp, fewer, { overwrite: true }), new RegExp(`apps/${removed}\\.json`));
    assert.equal((await stat(path.join(tmp, "apps", `${removed}.json`))).isFile(), true);
    const result = await writeCatalogV2(tmp, fewer, { overwrite: true, pruneStale: true });
    assert.deepEqual(result.stale, [`apps/${removed}.json`]);
    assert.equal((await readdir(path.join(tmp, "apps"))).includes(`${removed}.json`), false);
    assert.deepEqual(await verifyWrittenCatalogV2(tmp), []);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});

test("verifyWrittenCatalogV2 notices a hand-edited or unlisted file", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-"));
  try {
    await writeCatalogV2(tmp, emitCatalogV2({ apps: reviewedApps(3), categories: reviewedCategories(), generatedAt: GENERATED_AT }));
    await writeFile(path.join(tmp, "categories.json"), "{\"categories\":[]}\n");
    await writeFile(path.join(tmp, "apps", "extra.json"), "{}\n");
    assert.deepEqual(await verifyWrittenCatalogV2(tmp), ["apps/extra.json", "categories.json"]);
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});
