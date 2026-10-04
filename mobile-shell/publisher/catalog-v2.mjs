// Emits catalog v2 (index pages, categories.json, per-app detail pages)
// from reviewed app descriptors, deterministically and content-hashed.
//
// Deterministic: given the same `apps`, `categories` and `generatedAt`,
// regardless of input array order, the output bytes are identical (apps
// are sorted by slug, categories by id, before anything is paginated or
// serialized, and every file is written as canonical JSON: sorted keys, no
// indentation, one trailing newline). Content-hashed: every emitted file's
// sha256 is listed in `files`, which a server can use directly as the ETag,
// and `catalogEmitHash` is the sha256 of that path-to-hash list.
//
// This module only assembles and validates already-reviewed data; it does
// not fetch, build, or approve anything (that stays in index.mjs/cli.mjs's
// prepare/approve pipeline). A reviewed app descriptor's `mobileShell`
// field must already be an approved, install-verified descriptor (the
// output of approvePublisherBuild) -- this module does not re-derive or
// weaken that binding, it only carries it into the catalog's app page.

import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

import {
  CATALOG_V2_LIMITS,
  canonicalJSONString,
  validateCatalogAppPageV1,
  validateCatalogCategoriesV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogIndexV2,
} from "../contracts/index.js";

const INDEX_ENTRY_KEYS = [
  "slug", "name", "summary", "categoryIds", "iconHash", "iconURL",
  "byteCount", "ageRating", "updatedAt", "badges", "placement",
];
const APP_PAGE_KEYS = [
  "mobileShell", "description", "screenshots", "permissions",
  "privacySummary", "supportURL", "whatsNew",
];
const STABLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;

function pick(source, keys) {
  const out = {};
  for (const key of keys) out[key] = source[key];
  return out;
}

function canonicalIso(value, label) {
  if (typeof value !== "string") throw new TypeError(`${label} must be a canonical ISO instant`);
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString() !== value) {
    throw new TypeError(`${label} must be a canonical ISO instant`);
  }
  return value;
}

function sha256Hex(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

/** The exact bytes a catalog document is published as. */
export function catalogFileText(document) {
  return `${canonicalJSONString(document)}\n`;
}

export function indexPageFileName(page) {
  return page === 1 ? "index.json" : `index-${page}.json`;
}

/**
 * @param {object} options
 * @param {object[]} options.apps - reviewed app descriptors; each one
 *   carries both the index-entry fields (slug, name, summary, categoryIds,
 *   iconHash, iconURL, byteCount, ageRating, updatedAt, badges, placement)
 *   and the detail-page fields (mobileShell, description, screenshots,
 *   permissions, privacySummary, supportURL, whatsNew) on one object.
 *   `byteCount` must equal `mobileShell.byteCount` (the reviewed package
 *   size) and, when the descriptor carries App Store metadata, `ageRating`
 *   must equal its reviewed age rating.
 * @param {object[]} options.categories - [{id, name, order, appCount?}];
 *   appCount is recomputed from `apps` and any caller-supplied value is
 *   ignored, so a stale count can never be published.
 * @param {string} options.generatedAt - canonical ISO instant; caller-
 *   supplied so output is reproducible from the same inputs (no wall clock
 *   read inside this module).
 */
export function emitCatalogV2({ apps, categories, generatedAt }) {
  if (!Array.isArray(apps)) throw new TypeError("apps must be an array of reviewed app descriptors");
  if (!Array.isArray(categories)) throw new TypeError("categories must be an array");
  canonicalIso(generatedAt, "generatedAt");

  const sortedApps = apps.slice().sort((a, b) => (a?.slug < b?.slug ? -1 : a?.slug > b?.slug ? 1 : 0));

  const seenSlugs = new Set();
  const appCountByCategory = new Map();
  const indexEntries = [];
  const appPages = new Map();

  for (const app of sortedApps) {
    if (!app || typeof app !== "object" || Array.isArray(app)) {
      throw new TypeError("each reviewed app descriptor must be an object");
    }
    if (typeof app.slug !== "string" || !STABLE_ID_PATTERN.test(app.slug)) {
      throw new TypeError(`reviewed app descriptor has a missing or unsafe slug: ${String(app.slug)}`);
    }
    if (seenSlugs.has(app.slug)) throw new TypeError(`duplicate app slug in reviewed set: ${app.slug}`);
    seenSlugs.add(app.slug);

    const indexEntry = pick(app, INDEX_ENTRY_KEYS);
    for (const key of Object.keys(indexEntry)) {
      if (indexEntry[key] === undefined) throw new TypeError(`${app.slug}: missing catalog index field "${key}"`);
    }
    // `latestRevisionId` (contracts/index.js CATALOG_INDEX_APP_KEYS, added
    // R2-CP-3) tells the phone which revision publikhq.com still keeps
    // downloadable for a "Download" on a freed version (mobile-versions
    // SPEC.md owner decision 3, 2026-09-28: "keeps only the most recent
    // package per app, maybe one version prior"). Optional at the schema
    // level (a row with no key at all stays valid, per the contract's own
    // "backward compatible" test), so this only carries the field through
    // when the reviewed descriptor actually supplies it -- including an
    // explicit `null` for "not known yet" -- rather than forcing every
    // existing caller/fixture to start passing one.
    if (Object.prototype.hasOwnProperty.call(app, "latestRevisionId")) {
      indexEntry.latestRevisionId = app.latestRevisionId;
    }
    // RC-05: optional `publisher` (who made the app), carried through the same
    // way when the reviewed descriptor supplies it; the contract validator
    // checks its shape.
    if (Object.prototype.hasOwnProperty.call(app, "publisher")) {
      indexEntry.publisher = app.publisher;
    }
    const appPage = pick(app, APP_PAGE_KEYS);
    for (const key of Object.keys(appPage)) {
      if (appPage[key] === undefined) throw new TypeError(`${app.slug}: missing catalog detail field "${key}"`);
    }
    const appPageResult = validateCatalogAppPageV1(appPage);
    if (!appPageResult.ok) {
      throw new TypeError(`${app.slug}: reviewed app page is invalid: ${appPageResult.errors.join("; ")}`);
    }
    const agreement = validateCatalogIndexEntryMatchesAppPage(indexEntry, appPage);
    if (!agreement.ok) throw new TypeError(agreement.errors.join("; "));

    indexEntries.push(indexEntry);
    appPages.set(app.slug, appPage);
    for (const categoryId of Array.isArray(indexEntry.categoryIds) ? indexEntry.categoryIds : []) {
      appCountByCategory.set(categoryId, (appCountByCategory.get(categoryId) ?? 0) + 1);
    }
  }

  const sortedCategories = categories
    .slice()
    .sort((a, b) => (a?.id ?? 0) - (b?.id ?? 0))
    .map((category) => ({
      id: category.id,
      name: category.name,
      order: category.order,
      appCount: appCountByCategory.get(category.id) ?? 0,
    }));
  const knownCategoryIds = new Set(sortedCategories.map((category) => category.id));
  for (const categoryId of appCountByCategory.keys()) {
    if (!knownCategoryIds.has(categoryId)) {
      throw new TypeError(`a reviewed app uses category ${categoryId}, which is not in categories.json`);
    }
  }
  const categoriesDoc = { categories: sortedCategories };
  const categoriesResult = validateCatalogCategoriesV1(categoriesDoc);
  if (!categoriesResult.ok) {
    throw new TypeError(`emitted categories.json is invalid: ${categoriesResult.errors.join("; ")}`);
  }

  const appsPerPage = CATALOG_V2_LIMITS.appsPerPage;
  const pageCount = Math.max(1, Math.ceil(indexEntries.length / appsPerPage));
  const indexPages = [];
  for (let page = 1; page <= pageCount; page += 1) {
    const start = (page - 1) * appsPerPage;
    const pageDoc = {
      version: 2,
      generatedAt,
      page,
      pageCount,
      apps: indexEntries.slice(start, start + appsPerPage),
    };
    const pageResult = validateCatalogIndexV2(pageDoc);
    if (!pageResult.ok) throw new TypeError(`emitted index page ${page} is invalid: ${pageResult.errors.join("; ")}`);
    indexPages.push(pageDoc);
  }

  // Every published file, as exact text, keyed by its path under the
  // catalog root. Sorted so iteration (and therefore the hash) is stable.
  const fileTexts = new Map();
  for (const page of indexPages) fileTexts.set(indexPageFileName(page.page), catalogFileText(page));
  fileTexts.set("categories.json", catalogFileText(categoriesDoc));
  for (const [slug, appPage] of appPages) fileTexts.set(`apps/${slug}.json`, catalogFileText(appPage));
  const files = {};
  for (const path of [...fileTexts.keys()].sort()) files[path] = `sha256:${sha256Hex(fileTexts.get(path))}`;
  const catalogEmitHash = `sha256:${sha256Hex(canonicalJSONString(files))}`;

  return {
    generatedAt,
    indexPages,
    categories: categoriesDoc,
    appPages,
    fileTexts,
    files,
    catalogEmitHash,
  };
}

function isCatalogOwnedPath(relativePath) {
  return relativePath === "categories.json"
    || relativePath === "index.json"
    || /^index-[0-9]+\.json$/.test(relativePath)
    || /^apps\/[^/]+\.json$/.test(relativePath);
}

async function listCatalogOwnedFiles(outDir) {
  const owned = [];
  let top;
  try {
    top = await readdir(outDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return owned;
    throw error;
  }
  for (const entry of top) {
    if (entry.isFile() && isCatalogOwnedPath(entry.name)) owned.push(entry.name);
    if (entry.isDirectory() && entry.name === "apps") {
      for (const app of await readdir(join(outDir, "apps"), { withFileTypes: true })) {
        const relativePath = `apps/${app.name}`;
        if (app.isFile() && isCatalogOwnedPath(relativePath)) owned.push(relativePath);
      }
    }
  }
  return owned.sort();
}

async function readExistingManifest(outDir) {
  try {
    return JSON.parse(await readFile(join(outDir, "manifest.json"), "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new TypeError(`existing manifest.json in ${outDir} is unreadable: ${error.message}`);
  }
}

/**
 * Writes an emitted catalog to outDir: index.json/index-<n>.json,
 * categories.json, apps/<slug>.json, manifest.json, each as the exact bytes
 * hashed in `emitted.files`.
 *
 * - Without `overwrite`, refuses to write into a directory that already
 *   holds a catalog (the publisher never silently clobbers a publish).
 * - With `overwrite`, files are replaced in place. It refuses when the
 *   previous publish used the same `generatedAt` for different content:
 *   the iOS client treats an unchanged page 1 (same ETag, same
 *   `generatedAt`) as proof the other pages are unchanged too, so a changed
 *   catalog must carry a new `generatedAt`.
 * - Catalog files from a previous publish that this emit does not produce
 *   (for example the page of an app that was removed) are "stale". The
 *   write refuses before touching anything when stale files exist, unless
 *   `pruneStale` is passed, in which case they are removed after the new
 *   files are written.
 * - `extraManifest` fields are merged into manifest.json (the fixture
 *   generator records its seed this way).
 */
export async function writeCatalogV2(outDir, emitted, { overwrite = false, pruneStale = false, extraManifest = {} } = {}) {
  const existingOwned = await listCatalogOwnedFiles(outDir);
  const existingManifest = await readExistingManifest(outDir);
  if (!overwrite && (existingOwned.length > 0 || existingManifest !== null)) {
    throw new TypeError(`${outDir} already holds a catalog; pass overwrite to replace it`);
  }
  if (
    existingManifest !== null
    && existingManifest.generatedAt === emitted.generatedAt
    && existingManifest.catalogEmitHash !== emitted.catalogEmitHash
  ) {
    throw new TypeError(
      `the catalog changed but generatedAt is still ${emitted.generatedAt}; a changed catalog needs a new generatedAt`,
    );
  }
  const stale = existingOwned.filter((path) => !emitted.fileTexts.has(path));
  if (stale.length > 0 && !pruneStale) {
    throw new TypeError(`stale catalog files would remain (pass pruneStale to remove them): ${stale.join(", ")}`);
  }

  await mkdir(join(outDir, "apps"), { recursive: true });
  const flag = overwrite ? "w" : "wx";
  for (const [path, text] of emitted.fileTexts) {
    await writeFile(join(outDir, path), text, { flag });
  }
  const manifest = {
    ...extraManifest,
    generatedAt: emitted.generatedAt,
    pageCount: emitted.indexPages.length,
    appCount: emitted.appPages.size,
    categoryCount: emitted.categories.categories.length,
    catalogEmitHash: emitted.catalogEmitHash,
    files: emitted.files,
  };
  await writeFile(join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`, { flag: "w" });
  for (const path of stale) {
    await rm(join(outDir, path), { force: true });
  }
  return { outDir, stale };
}

/** Recomputes the sha256 of every file listed in a written catalog's manifest; returns the paths whose bytes no longer match. */
export async function verifyWrittenCatalogV2(outDir) {
  const manifest = await readExistingManifest(outDir);
  if (manifest === null) throw new TypeError(`${outDir} has no manifest.json`);
  const mismatched = [];
  for (const [path, expected] of Object.entries(manifest.files ?? {})) {
    let text;
    try {
      text = await readFile(join(outDir, path), "utf8");
    } catch {
      mismatched.push(path);
      continue;
    }
    if (`sha256:${sha256Hex(text)}` !== expected) mismatched.push(path);
  }
  const listed = new Set(Object.keys(manifest.files ?? {}));
  for (const path of await listCatalogOwnedFiles(outDir)) {
    if (!listed.has(path)) mismatched.push(path);
  }
  const dirStat = await stat(outDir);
  if (!dirStat.isDirectory()) throw new TypeError(`${outDir} is not a directory`);
  return mismatched.sort();
}
