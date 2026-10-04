#!/usr/bin/env node
// RC-03 (round5/rc03-website). Builds the live publikhq.com website for
// Iris Apps: catalog v2 (index.json, categories.json, apps/<slug>.json,
// icons), the apple-app-site-association file, and the human-facing pages
// (hub, one per app, privacy, support, not-found).
//
// Reuses the already-reviewed, already-validated seed catalog
// (seed-catalog-v2.mjs#buildSeedCatalog, a read-only import: this unit does
// not edit that file) for each app's real package descriptor, icon bytes,
// description, and permission labels, then layers on the Guideline 4.7
// AppStoreMetadataV1 this unit owns (site-content.mjs, sourced from
// apple-compliance/LISTING.md and PRIVACY_POLICY_OUTLINE.md, unit RC-13)
// before re-emitting the catalog with the publisher's own emitCatalogV2, so
// every file this script writes is re-validated against the same contracts
// as the seed.
//
// This output is a SEPARATE tree from seed-catalog-v2.mjs's own output
// (docs/plans/20260928-all-routes/round3-deferred/M-store-screens/
// website-catalog-v2/): that folder is not touched by this script. Nothing
// here is uploaded anywhere.
//
// Usage:
//   node mobile-shell/website/build-site.mjs            write the site
//   node mobile-shell/website/build-site.mjs --check     fail if the
//                                                         checked-in copy
//                                                         is stale

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { validateCatalogAppPageV1, validateCatalogIndexV2 } from "../contracts/index.js";
import { catalogFileText, emitCatalogV2, indexPageFileName } from "../publisher/catalog-v2.mjs";
import { writeDeployAddendum } from "./deploy-addendum.mjs";
import { catalogRowsFromIndexV2, renderAASAJSON } from "./integration.mjs";
import { buildSeedCatalog, SEED_CATEGORIES } from "./seed-catalog-v2.mjs";
import { appStoreMetadataFor } from "./site-content.mjs";
import {
  renderAppPageHTML,
  renderHubPageHTML,
  renderNotFoundPageHTML,
  renderPrivacyPageHTML,
  renderSupportPageHTML,
} from "./site-pages.mjs";
import { PLACEHOLDER_APPLE_TEAM_ID, RELEASE_BUNDLE_ID } from "./site-content.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../..");
export const SITE_OUT = join(REPO, "docs/plans/20260928-all-routes/round5/rc03-website/site");
const SITE_CSS_SOURCE = join(HERE, "site.css");

// A new publish time: after the seed's own GENERATED_AT (2026-09-28T17:00:00.000Z),
// since this catalog carries new content (AppStoreMetadataV1) the seed does
// not. Fixed, not wall-clock, so the build is deterministic.
export const SITE_GENERATED_AT = "2026-09-28T18:00:00.000Z";

function textFile(text) {
  return Buffer.from(text, "utf8");
}

/**
 * Builds the whole site in memory. Returns
 * { files: Map<relativePath, Buffer>, catalogRows, appNames }
 * where relativePath is the path the file is served at, relative to the
 * web root (no leading slash): "iris/apps/kneecap/index.html",
 * "api/iris/mobile/index.json", ".well-known/apple-app-site-association".
 */
export async function buildSite({ generatedAt = SITE_GENERATED_AT } = {}) {
  const seed = await buildSeedCatalog();
  const seedIndexText = seed.files.get(indexPageFileName(1));
  if (!seedIndexText) throw new TypeError("seed catalog produced no index.json");
  const seedIndex = JSON.parse(seedIndexText.toString("utf8"));

  // Rebuild the reviewed-app list emitCatalogV2 expects (index-entry fields
  // plus detail-page fields on one object), from the seed's own already-
  // validated app pages, with AppStoreMetadataV1 layered on.
  const reviewedApps = [];
  const appNames = [];
  for (const entry of seedIndex.apps) {
    const appPageText = seed.files.get(`apps/${entry.slug}.json`);
    if (!appPageText) throw new TypeError(`seed catalog has no app page for ${entry.slug}`);
    const appPage = JSON.parse(appPageText.toString("utf8"));
    const appStoreMetadata = appStoreMetadataFor(entry.slug, appPage.privacySummary);
    const mobileShell = { ...appPage.mobileShell, appStoreMetadata };
    reviewedApps.push({
      ...entry,
      ageRating: appStoreMetadata.ageRating, // OD-08: Nut AI raised 4 -> 13 here; must agree with appStoreMetadata.ageRating.
      mobileShell,
      description: appPage.description,
      screenshots: appPage.screenshots,
      permissions: appPage.permissions,
      privacySummary: appPage.privacySummary,
      supportURL: appPage.supportURL,
      whatsNew: appPage.whatsNew,
    });
    appNames.push(entry.name);
  }

  const emitted = emitCatalogV2({ apps: reviewedApps, categories: SEED_CATEGORIES, generatedAt });
  if (emitted.indexPages.length !== 1) throw new TypeError("the site catalog must fit on one index page");

  // R2-CP-3 (round3-deferred/M-store-screens), same treatment as
  // seed-catalog-v2.mjs: the optional latestRevisionId is added after
  // emitCatalogV2 (which predates it and does not own the per-row byte
  // budget it would affect), equal to each app page's own revision, so an
  // installed starter never shows "Update available" for itself.
  const indexPage = {
    ...emitted.indexPages[0],
    apps: emitted.indexPages[0].apps.map((entry) => ({
      ...entry,
      latestRevisionId: emitted.appPages.get(entry.slug).mobileShell.revisionId,
    })),
  };

  // Re-validate everything this script is about to write, independent of
  // emitCatalogV2's own internal validation, so a bug here fails loudly
  // rather than shipping a malformed file.
  const indexResult = validateCatalogIndexV2(indexPage);
  if (!indexResult.ok) throw new TypeError(`site index is invalid: ${indexResult.errors.join("; ")}`);
  for (const entry of indexPage.apps) {
    const page = emitted.appPages.get(entry.slug);
    if (entry.latestRevisionId !== page.mobileShell.revisionId) throw new TypeError(`${entry.slug}: latestRevisionId disagrees with its page`);
  }
  for (const [slug, page] of emitted.appPages) {
    const pageResult = validateCatalogAppPageV1(page);
    if (!pageResult.ok) throw new TypeError(`site page ${slug} is invalid: ${pageResult.errors.join("; ")}`);
  }

  const catalogRows = catalogRowsFromIndexV2({ indexPages: [indexPage], appPages: emitted.appPages });
  if (catalogRows.length !== reviewedApps.length || catalogRows.some((row) => row.mobileShell === null)) {
    throw new TypeError("the website reader does not offer every published app");
  }

  const files = new Map();

  // Catalog v2 (api/iris/mobile/...), same layout and same icon bytes as
  // the seed (the packages themselves are unchanged; only metadata added).
  files.set("api/iris/mobile/index.json", textFile(catalogFileText(indexPage)));
  files.set("api/iris/mobile/categories.json", textFile(catalogFileText(emitted.categories)));
  for (const [slug, page] of emitted.appPages) files.set(`api/iris/mobile/apps/${slug}.json`, textFile(catalogFileText(page)));
  for (const [path, bytes] of seed.files) {
    if (path.startsWith("icons/")) files.set(`api/iris/mobile/${path}`, bytes);
  }

  // Guideline 4.7.4 universal links.
  const applicationIdentifier = `${PLACEHOLDER_APPLE_TEAM_ID}.${RELEASE_BUNDLE_ID}`;
  files.set(".well-known/apple-app-site-association", textFile(renderAASAJSON({ applicationIdentifier })));

  // Shared stylesheet every human page links to (site-pages.mjs's
  // pageShell, "/iris/site.css"). Read from disk rather than inlined here
  // so site.css stays a plain, directly-editable CSS file.
  files.set("iris/site.css", await readFile(SITE_CSS_SOURCE));

  // Human pages.
  const categoriesById = new Map(SEED_CATEGORIES.map((category) => [category.id, category]));
  const appsByCategory = new Map();
  for (const entry of indexPage.apps) {
    for (const categoryId of entry.categoryIds) {
      const list = appsByCategory.get(categoryId) ?? [];
      list.push(entry);
      appsByCategory.set(categoryId, list);
    }
  }
  files.set(
    "iris/index.html",
    textFile(renderHubPageHTML({
      categories: SEED_CATEGORIES.slice().sort((a, b) => a.order - b.order),
      appsByCategory,
      catalogRows,
    })),
  );
  for (const entry of indexPage.apps) {
    const appPage = emitted.appPages.get(entry.slug);
    const categoryNames = entry.categoryIds.map((id) => categoriesById.get(id)?.name).filter(Boolean);
    files.set(
      `iris/apps/${entry.slug}/index.html`,
      textFile(renderAppPageHTML({ slug: entry.slug, name: entry.name, categoryNames, appPage, catalogRows })),
    );
  }
  files.set("iris/privacy/index.html", textFile(renderPrivacyPageHTML({ appNames })));
  files.set(
    "iris/support/index.html",
    textFile(renderSupportPageHTML({ apps: indexPage.apps.map((entry) => ({ slug: entry.slug, name: entry.name })) })),
  );
  files.set("404.html", textFile(renderNotFoundPageHTML()));

  return { files: new Map([...files.entries()].sort(([a], [b]) => (a < b ? -1 : 1))), catalogRows, appNames, indexPage };
}

async function readOrNull(path) {
  try {
    return await readFile(path);
  } catch {
    return null;
  }
}

export async function writeSite(outDir, files) {
  for (const [relativePath, bytes] of files) {
    const dest = join(outDir, relativePath);
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, bytes);
  }
}

async function main() {
  const check = process.argv.includes("--check");
  const { files } = await buildSite();
  const drift = [];
  for (const [relativePath, bytes] of files) {
    const dest = join(SITE_OUT, relativePath);
    const current = await readOrNull(dest);
    if (current !== null && current.equals(bytes)) continue;
    if (check) {
      drift.push(relativePath);
      continue;
    }
    await mkdir(dirname(dest), { recursive: true });
    await writeFile(dest, bytes);
    console.log(`wrote ${relativePath} (${bytes.length} bytes)`);
  }
  if (check) {
    if (drift.length) {
      console.error(`website build is out of date:\n${drift.join("\n")}`);
      process.exitCode = 1;
    } else {
      console.log(`website build matches (${files.size} files)`);
    }
  } else {
    await writeDeployAddendum(files);
    console.log("updated DEPLOY.md's website-pages section");
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
