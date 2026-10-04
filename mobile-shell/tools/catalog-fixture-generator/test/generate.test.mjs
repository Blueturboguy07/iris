import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";

import {
  CATALOG_V2_LIMITS,
  canonicalJSONString,
  catalogIndexEntryDataBytes,
  validateCatalogAppPageV1,
  validateCatalogCategoriesV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogIndexV2,
  verifyDeliveryPackageV1,
} from "../../../contracts/index.js";
import { verifyWrittenCatalogV2 } from "../../../publisher/catalog-v2.mjs";
import { generateCatalog, generateCatalogWithPackages } from "../src/generate.mjs";
import { DEFAULT_PACKAGE_COUNTS, DEFAULT_SEED, writeFixtureSet } from "../bin/generate.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKED_IN = path.resolve(HERE, "../../../native/Tests/Fixtures/catalog-v2");

function allApps(catalog) {
  return catalog.indexPages.flatMap((page) => page.apps);
}

for (const appCount of [3, 100, 1000]) {
  test(`generateCatalog(${appCount}) produces a fully valid catalog`, () => {
    const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount });
    assert.equal(allApps(catalog).length, appCount);
    assert.equal(catalog.appPages.size, appCount);

    for (const page of catalog.indexPages) {
      const result = validateCatalogIndexV2(page);
      assert.equal(result.ok, true, `index page ${page.page} invalid: ${result.errors?.join("; ")}`);
      assert.ok(page.apps.length <= CATALOG_V2_LIMITS.appsPerPage);
    }

    const categoriesResult = validateCatalogCategoriesV1(catalog.categories);
    assert.equal(categoriesResult.ok, true, categoriesResult.errors?.join("; "));

    for (const [slug, appPage] of catalog.appPages) {
      const result = validateCatalogAppPageV1(appPage);
      assert.equal(result.ok, true, `app page ${slug} invalid: ${result.errors?.join("; ")}`);
    }

    // Every index entry has a matching detail page (apps/<slug>.json) that
    // agrees with it on size and age rating, a distinct descriptor, and fits
    // the 200-byte per-app budget.
    const seenAppIds = new Set();
    for (const app of allApps(catalog)) {
      assert.ok(catalog.appPages.has(app.slug), `missing app page for ${app.slug}`);
      const appPage = catalog.appPages.get(app.slug);
      const agreement = validateCatalogIndexEntryMatchesAppPage(app, appPage);
      assert.equal(agreement.ok, true, agreement.errors?.join("; "));
      assert.ok(catalogIndexEntryDataBytes(app) <= 200, `${app.slug} is over budget`);
      const appId = appPage.mobileShell.appId;
      assert.equal(seenAppIds.has(appId), false, `duplicate mobileShell.appId ${appId}`);
      seenAppIds.add(appId);
    }
  });
}

test("a 10,000-app catalog splits into more than one index page, none oversized", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 10000 });
  assert.ok(catalog.indexPages.length >= 40);
  for (const page of catalog.indexPages) {
    assert.ok(page.apps.length <= CATALOG_V2_LIMITS.appsPerPage);
    assert.equal(validateCatalogIndexV2(page).ok, true);
  }
});

test("names include ordinary words, not just numbered placeholders", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 100 });
  const names = allApps(catalog).map((a) => a.name);
  assert.ok(names.some((n) => /Timer|Notes|Journal|Recipes|Planner/.test(n)));
  assert.ok(names.every((n) => !/^App \d+$/.test(n)));
});

test("realistic variety: categories, ages, badges, sponsored slots all appear", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 1000 });
  const apps = allApps(catalog);
  const categoryIdsUsed = new Set(apps.flatMap((a) => a.categoryIds));
  assert.ok(categoryIdsUsed.size >= 8, "expected apps spread across many categories");
  const ageRatingsUsed = new Set(apps.map((a) => a.ageRating));
  assert.ok(ageRatingsUsed.size >= 3, "expected a spread of age ratings");
  assert.ok(apps.some((a) => a.badges.includes("new")));
  assert.ok(apps.some((a) => a.badges.includes("updated")));
  assert.ok(apps.some((a) => a.badges.length === 0));
  assert.ok(apps.some((a) => a.placement && a.placement.sponsored === true), "expected at least one sponsored slot");
  assert.ok(apps.some((a) => a.placement && a.placement.featured === true), "expected at least one featured slot");
  assert.ok(apps.some((a) => a.placement === null), "expected most apps to have no placement");
});

test("same seed and count is byte-identical across two independent runs", () => {
  const a = generateCatalog({ seed: DEFAULT_SEED, appCount: 100 });
  const b = generateCatalog({ seed: DEFAULT_SEED, appCount: 100 });
  assert.equal(canonicalJSONString(a.indexPages), canonicalJSONString(b.indexPages));
  assert.equal(canonicalJSONString(a.categories), canonicalJSONString(b.categories));
  assert.equal(
    canonicalJSONString(Object.fromEntries(a.appPages)),
    canonicalJSONString(Object.fromEntries(b.appPages)),
  );
});

test("a different seed changes the output", () => {
  const a = generateCatalog({ seed: DEFAULT_SEED, appCount: 20 });
  const b = generateCatalog({ seed: "a-different-seed", appCount: 20 });
  assert.notEqual(canonicalJSONString(a.indexPages), canonicalJSONString(b.indexPages));
});

test("every slug is safe: no path traversal, no slashes, lowercase stable id", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 1000 });
  for (const app of allApps(catalog)) {
    assert.match(app.slug, /^[a-z0-9][a-z0-9._-]{0,127}$/);
    assert.ok(!app.slug.includes("/"));
    assert.ok(!app.slug.includes(".."));
  }
});

test("appCount 0 produces a single empty page 1, still valid", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 0 });
  assert.equal(catalog.indexPages.length, 1);
  assert.equal(catalog.indexPages[0].apps.length, 0);
  assert.equal(validateCatalogIndexV2(catalog.indexPages[0]).ok, true);
});

test("rejects an invalid seed or app count instead of generating garbage", () => {
  assert.throws(() => generateCatalog({ seed: "", appCount: 3 }));
  assert.throws(() => generateCatalog({ seed: "x", appCount: -1 }));
  assert.throws(() => generateCatalog({ seed: "x", appCount: 1.5 }));
});

test("sizes look like real apps: 40 KB to 24 MB, mostly small, spread over orders of magnitude", () => {
  const sizes = allApps(generateCatalog({ seed: DEFAULT_SEED, appCount: 1000 })).map((a) => a.byteCount).sort((a, b) => a - b);
  assert.ok(sizes[0] >= 40 * 1024, `smallest ${sizes[0]}`);
  assert.ok(sizes.at(-1) <= 24 * 1024 * 1024, `largest ${sizes.at(-1)}`);
  const median = sizes[500];
  assert.ok(median > 200 * 1024 && median < 5 * 1024 * 1024, `median ${median}`);
  assert.ok(sizes.filter((n) => n < 1024 * 1024).length >= 300, "expected many apps under 1 MB");
  assert.ok(sizes.filter((n) => n > 10 * 1024 * 1024).length >= 50, "expected some apps over 10 MB");
});

test("no app is labelled both new and updated", () => {
  for (const app of allApps(generateCatalog({ seed: DEFAULT_SEED, appCount: 1000 }))) {
    assert.ok(app.badges.length <= 1, `${app.slug} has ${app.badges.join(", ")}`);
  }
});

test("the 1,000-app index is close to the per-app budget in total size", () => {
  const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 1000 });
  const dataBytes = allApps(catalog).reduce((total, app) => total + catalogIndexEntryDataBytes(app), 0);
  assert.ok(dataBytes <= 200 * 1000, `values total ${dataBytes}`);
  const fileBytes = [...catalog.fileTexts].filter(([p]) => p.startsWith("index")).reduce((t, [, text]) => t + Buffer.byteLength(text), 0);
  // Field names add a fixed 116 bytes per row (147 with a placement).
  assert.ok(fileBytes <= 1000 * (200 + 147) + 4 * 200, `index files total ${fileBytes}`);
});

test("installable fixture packages verify with the contract and match their descriptors, icons and permissions", async () => {
  const catalog = await generateCatalogWithPackages({ seed: DEFAULT_SEED, appCount: 3 });
  for (const app of allApps(catalog)) {
    const bytes = catalog.packages.get(app.slug);
    const appPage = catalog.appPages.get(app.slug);
    const pkg = JSON.parse(Buffer.from(bytes).toString("utf8"));
    const verified = await verifyDeliveryPackageV1(pkg);
    assert.equal(verified.ok, true, verified.errors?.join("; "));
    assert.equal(appPage.mobileShell.packageSha256, `sha256:${createHash("sha256").update(bytes).digest("hex")}`);
    assert.equal(appPage.mobileShell.byteCount, bytes.byteLength);
    assert.equal(app.byteCount, bytes.byteLength, "the store must show the real download size");
    assert.equal(appPage.mobileShell.revisionId, pkg.envelope.revision.revisionId);
    assert.deepEqual(
      [...pkg.envelope.revision.manifest.capabilities].sort(),
      appPage.permissions.map((p) => p.capability).sort(),
      "the store's permission list must be what the package asks for",
    );
    const icon = Buffer.from(catalog.icons.get(app.slug));
    assert.equal(app.iconHash, createHash("sha256").update(icon).digest("hex").slice(0, 16));
    assert.deepEqual([...icon.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    assert.equal(icon.readUInt32BE(16), 32);
    assert.equal(icon.readUInt32BE(20), 32);
    const idatLength = icon.readUInt32BE(33);
    assert.equal(icon.subarray(37, 41).toString("ascii"), "IDAT");
    assert.equal(inflateSync(icon.subarray(41, 41 + idatLength)).length, 32 * (1 + 32 * 3));
    assert.ok(icon.length <= CATALOG_V2_LIMITS.maxIconBytes);
  }
});

test("the checked-in fixtures are exactly what the generator produces from the documented seed", async () => {
  for (const appCount of [3, 100, 1000]) {
    const root = path.join(CHECKED_IN, String(appCount));
    assert.deepEqual(await verifyWrittenCatalogV2(root), [], `${appCount}: files differ from their manifest`);
    const manifest = JSON.parse(await readFile(path.join(root, "manifest.json"), "utf8"));
    assert.equal(manifest.seed, DEFAULT_SEED);
    const fresh = DEFAULT_PACKAGE_COUNTS.includes(appCount)
      ? await generateCatalogWithPackages({ seed: DEFAULT_SEED, appCount })
      : generateCatalog({ seed: DEFAULT_SEED, appCount });
    assert.equal(manifest.catalogEmitHash, fresh.catalogEmitHash, `${appCount}: regenerate with node bin/generate.mjs`);
    if (fresh.packages) {
      for (const [slug, bytes] of fresh.packages) {
        assert.ok(Buffer.from(bytes).equals(await readFile(path.join(root, "packages", `${slug}.irisapp`))), slug);
      }
      for (const [slug, bytes] of fresh.icons) {
        assert.ok(Buffer.from(bytes).equals(await readFile(path.join(root, "icons", `${slug}.png`))), slug);
      }
    }
  }
});

test("writeFixtureSet is repeatable and stops, without deleting anything, when a stale page is present", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-fixture-"));
  try {
    const catalog = generateCatalog({ seed: DEFAULT_SEED, appCount: 3 });
    const root = await writeFixtureSet(tmp, catalog);
    await writeFixtureSet(tmp, catalog);
    assert.deepEqual(await verifyWrittenCatalogV2(root), []);

    const index = JSON.parse(await readFile(path.join(root, "index.json"), "utf8"));
    assert.equal(validateCatalogIndexV2(index).ok, true);
    assert.equal(index.apps.length, 3);

    const ghost = path.join(root, "apps", "removed-app.json");
    await writeFile(ghost, "{}\n");
    await assert.rejects(() => writeFixtureSet(tmp, catalog), /removed-app\.json/);
    assert.equal((await stat(ghost)).isFile(), true, "a stale file must be reported, not deleted");
    assert.deepEqual((await readdir(path.join(root, "apps"))).sort(), [...index.apps.map((a) => `${a.slug}.json`), "removed-app.json"].sort());
  } finally {
    await rm(tmp, { recursive: true, force: true });
  }
});
