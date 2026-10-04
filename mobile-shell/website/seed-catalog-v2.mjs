#!/usr/bin/env node
// Seed catalog v2 generator (round3-deferred/M-store-screens).
//
// Why: publikhq.com answers 404 for the mobile catalog v2 (index.json,
// categories.json, apps/<slug>.json), and the v1 /api/iris/apps list only
// has Mac apps, so Browse on a real iPhone showed nothing. The apps that
// already ship inside Iris (Kneecap, Nut AI, FreeHarmony as starters, plus
// Lunara, bundled but installed only when someone taps Get; round6/
// catalog-expand SPEC.md) become a small catalog v2 that
//   1. ships inside the iPhone app as the catalog of last resort
//      (network index first, then the disk cache, then this seed), and
//   2. can be uploaded to publikhq.com as the first real mobile catalog.
// Both are the SAME bytes, written by this one script.
//
// How: each app's descriptor is derived from its real bundled package with
// the publisher's own `descriptorFromPackageBytes` (which validates the
// package with the contract first), then the publisher's unchanged
// `emitCatalogV2` builds and validates index, categories and app pages.
// The optional `latestRevisionId` (R2-CP-3) is added to each index row
// afterwards (the publisher does not emit it yet) and the pages are
// validated again with the contract.
//
// Usage:
//   node mobile-shell/website/seed-catalog-v2.mjs            write both outputs
//   node mobile-shell/website/seed-catalog-v2.mjs --check    fail if either
//                                                            output on disk differs
//
// Deterministic: fixed generatedAt, icons drawn by seed/draw-icons.py
// (checked in), canonical JSON. Running it twice changes nothing.

import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  canonicalJSONString,
  validateCatalogAppPageV1,
  validateCatalogCategoriesV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogIndexV2,
} from "../contracts/index.js";
import { catalogFileText, emitCatalogV2, indexPageFileName } from "../publisher/catalog-v2.mjs";
import { RC03_MARKER } from "./deploy-addendum.mjs";
import { descriptorFromPackageBytes } from "../publisher/index.mjs";
import { canonicalAppURL, catalogRowsFromIndexV2 } from "./integration.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "../..");
const STARTER_DIR = join(REPO, "mobile-shell/native/IrisMobileShellApp/Resources/Starter");
const ICON_DIR = join(HERE, "seed");
export const WEBSITE_OUT = join(REPO, "docs/plans/20260928-all-routes/round3-deferred/M-store-screens/website-catalog-v2");
export const SWIFT_OUT = join(REPO, "mobile-shell/native/Sources/IrisMobileShellCore/Store/StoreCatalogSeedData.swift");

/** Every catalog URL is https://publikhq.com + this prefix + the file's path. */
export const CATALOG_ROOT = "https://publikhq.com/api/iris/mobile/";
export const GENERATED_AT = "2026-09-28T17:00:00.000Z";

export const SEED_CATEGORIES = [
  { id: 1, name: "Video editing", order: 0 },
  { id: 2, name: "Food and nutrition", order: 1 },
  { id: 3, name: "Face and looks", order: 2 },
  // round6/catalog-expand (SPEC.md section 5): Lunara's category.
  { id: 4, name: "Health and body", order: 3 },
];

// Plain words for people who are not technical. One app per row, mirrors
// NativeStarterCatalog (label and the LAST file of each ordered chain).
export const SEED_APPS = [
  {
    slug: "kneecap",
    starterLabel: "Kneecap",
    // round5/mobile-integrator-B1, 2026-09-28: NativeStarterCatalog's
    // Kneecap chain gained 04-longclip.irisapp and 05-bugpass.irisapp
    // (H1, kneecap-bugpass/INTEGRATION_HOOKS.md); this must keep mirroring
    // the chain's own last file, per the comment above.
    // round6/mobile-prep-A, 2026-09-29: chain grew to 06-deletefix.irisapp
    // (kneecap-bugpass DELETE_FIX.md); same rule, mirror the chain's last file.
    finalFile: "06-deletefix.irisapp",
    name: "Kneecap",
    summary: "Trim and join clips into one video",
    categoryIds: [1],
    ageRating: 4,
    description:
      "Kneecap is a video editor that works on your phone. Pick clips from your photo library, trim them, put them in order on a timeline and save the finished video to Photos. Your clips and projects stay on this phone.",
    permissionLabels: {
      "web.storage": "Keeps your projects on this phone",
      "web.media.photo-picker": "Lets you pick videos and photos from your library",
      "web.media.export": "Saves your finished video to Photos",
    },
    privacySummary: "Your clips and projects are kept on this phone.",
  },
  {
    slug: "nut-ai",
    starterLabel: "NutAI",
    finalFile: "04-final.irisapp",
    name: "Nut AI",
    summary: "Track calories, protein and weight",
    categoryIds: [2],
    // Decided (not a proposal): apple-compliance/DECISIONS.md section 1.3 /
    // OD-08, 2026-09-28 -- 13+, both here and the questionnaire's
    // "Infrequent or mild" medical/treatment-information answer, for label
    // consistency; a calorie/weight tracker's own comparable app (MyFitnessPal)
    // sets a stricter floor itself. Raised from 4.
    ageRating: 13,
    description:
      "Nut AI helps you keep track of what you eat. Log your meals, see how many calories, protein, carbs and fat you have left today, and follow your weight over time.",
    permissionLabels: {
      "web.storage": "Keeps your food log on this phone",
    },
    privacySummary: "Your food log is kept on this phone.",
  },
  {
    slug: "freeharmony",
    starterLabel: "FreeHarmony",
    finalFile: "04-final.irisapp",
    name: "FreeHarmony",
    summary: "Measure your face's proportions",
    categoryIds: [3],
    // A proposal for the owner to confirm: face and looks apps can touch on
    // body image, so this one is rated 13+ (see DEPLOY.md).
    ageRating: 13,
    description:
      "FreeHarmony measures the proportions of your face from a photo, using the positions of points such as your eyes, nose and mouth. Every measurement is free, with no paywall and no made-up scores. Your photos stay on this phone.",
    permissionLabels: {
      "web.storage": "Keeps your results on this phone",
      "web.media.photo-picker": "Lets you pick a photo of your face",
      "web.media.camera": "Lets you take a photo with the camera",
    },
    privacySummary: "Your photos and results are kept on this phone.",
  },
  {
    // round6/catalog-expand (SPEC.md sections 4 to 6): bundled inside Iris but NOT
    // installed at first launch (NativeStarterCatalog installsAtFirstLaunch:
    // false), so it appears in My apps only after someone taps Get, which runs
    // after the age check. One revision, built without the AI assistant and
    // the cloud backup rows (packages/lunara/POLICY_CHECK.md).
    slug: "lunara",
    starterLabel: "Lunara",
    finalFile: "01-base.irisapp",
    name: "Lunara",
    summary: "Private cycle and symptom log",
    categoryIds: [4],
    // A proposal for the owner to confirm (SPEC.md section 6, decision 1):
    // 16+ because it logs intimacy, contraception and pregnancy. 18 is the
    // alternative; change this one number and run the script again.
    ageRating: 16,
    description:
      "Lunara is a private log for your cycle and how you feel. Note your period, symptoms and mood, see when your next period may start, and read short guides on the basics. Predictions are estimates and can be wrong. Lunara is not a medical device and does not give medical advice. Your log stays on this phone.",
    permissionLabels: {
      "web.storage": "Keeps your log on this phone",
    },
    privacySummary: "Your cycle log and settings are kept on this phone. Lunara has no account and makes no network requests.",
  },
];

function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function packagePath(slug, revisionId) {
  return `packages/${slug}/${revisionId.slice("rev-sha256:".length)}.json`;
}

/**
 * Builds every seed file in memory. Returns
 * { files: Map<path, Buffer>, apps: [{slug, appId, revisionId, packageBytes, packagePath, sourcePath}] }
 * where each path is relative to CATALOG_ROOT.
 */
export async function buildSeedCatalog({ starterDir = STARTER_DIR, iconDir = ICON_DIR } = {}) {
  const reviewed = [];
  const iconFiles = new Map();
  const packages = [];
  for (const app of SEED_APPS) {
    const sourcePath = join(starterDir, app.starterLabel, app.finalFile);
    const packageBytes = await readFile(sourcePath);
    const provisional = await descriptorFromPackageBytes(packageBytes, `${CATALOG_ROOT}packages/pending.json`);
    const descriptor = {
      ...provisional,
      downloadUrl: `${CATALOG_ROOT}${packagePath(app.slug, provisional.revisionId)}`,
      appStoreMetadata: null,
    };
    const pkg = JSON.parse(packageBytes.toString("utf8"));
    const manifest = pkg.envelope.revision.manifest;
    const capabilities = [...manifest.capabilities].sort();
    for (const capability of capabilities) {
      if (!app.permissionLabels[capability]) throw new TypeError(`${app.slug}: no plain label for ${capability}`);
    }
    for (const capability of Object.keys(app.permissionLabels)) {
      if (!capabilities.includes(capability)) throw new TypeError(`${app.slug}: label for ${capability}, which the package does not ask for`);
    }
    const iconBytes = await readFile(join(iconDir, `${app.slug}.png`));
    const iconHash = sha256Hex(iconBytes).slice(0, 16);
    const iconPath = `icons/${iconHash}.png`;
    iconFiles.set(iconPath, iconBytes);
    const createdAt = pkg.envelope.revision.createdAt;
    reviewed.push({
      slug: app.slug,
      name: app.name,
      summary: app.summary,
      categoryIds: app.categoryIds,
      iconHash,
      iconURL: `${CATALOG_ROOT}${iconPath}`,
      byteCount: descriptor.byteCount,
      ageRating: app.ageRating,
      updatedAt: createdAt.slice(0, 10),
      badges: [],
      placement: null,
      mobileShell: descriptor,
      description: app.description,
      screenshots: [],
      permissions: capabilities.map((capability) => ({ capability, label: app.permissionLabels[capability] })),
      privacySummary: app.privacySummary,
      supportURL: canonicalAppURL(app.slug),
      whatsNew: null,
    });
    packages.push({
      slug: app.slug,
      appId: descriptor.appId,
      revisionId: descriptor.revisionId,
      baseRevisionId: descriptor.baseRevisionId,
      byteCount: descriptor.byteCount,
      packageSha256: descriptor.packageSha256,
      packagePath: packagePath(app.slug, descriptor.revisionId),
      sourcePath,
    });
  }

  const emitted = emitCatalogV2({ apps: reviewed, categories: SEED_CATEGORIES, generatedAt: GENERATED_AT });
  if (emitted.indexPages.length !== 1) throw new TypeError("the seed must fit on one index page");

  // R2-CP-3: the optional latestRevisionId, equal to each app page's own
  // revision, added after the publisher's emitter (which predates it).
  const indexPage = {
    ...emitted.indexPages[0],
    apps: emitted.indexPages[0].apps.map((entry) => ({
      ...entry,
      latestRevisionId: emitted.appPages.get(entry.slug).mobileShell.revisionId,
    })),
  };
  const indexResult = validateCatalogIndexV2(indexPage);
  if (!indexResult.ok) throw new TypeError(`seed index is invalid: ${indexResult.errors.join("; ")}`);
  for (const entry of indexPage.apps) {
    const page = emitted.appPages.get(entry.slug);
    const pageResult = validateCatalogAppPageV1(page);
    if (!pageResult.ok) throw new TypeError(`seed page ${entry.slug} is invalid: ${pageResult.errors.join("; ")}`);
    const agreement = validateCatalogIndexEntryMatchesAppPage(entry, page);
    if (!agreement.ok) throw new TypeError(agreement.errors.join("; "));
    if (entry.latestRevisionId !== page.mobileShell.revisionId) throw new TypeError(`${entry.slug}: latestRevisionId disagrees with its page`);
  }
  const categoriesResult = validateCatalogCategoriesV1(emitted.categories);
  if (!categoriesResult.ok) throw new TypeError(`seed categories are invalid: ${categoriesResult.errors.join("; ")}`);

  // The website's own reader must offer every seed app for install.
  const rows = catalogRowsFromIndexV2({ indexPages: [indexPage], appPages: emitted.appPages });
  if (rows.length !== SEED_APPS.length || rows.some((row) => row.mobileShell === null)) {
    throw new TypeError("the website reader does not offer every seed app");
  }

  const files = new Map();
  files.set(indexPageFileName(1), Buffer.from(catalogFileText(indexPage), "utf8"));
  files.set("categories.json", Buffer.from(emitted.fileTexts.get("categories.json"), "utf8"));
  for (const [slug, page] of emitted.appPages) files.set(`apps/${slug}.json`, Buffer.from(catalogFileText(page), "utf8"));
  for (const [path, bytes] of iconFiles) files.set(path, bytes);
  return { files: new Map([...files.entries()].sort(([a], [b]) => (a < b ? -1 : 1))), packages };
}

function contentType(path) {
  return path.endsWith(".png") ? "image/png" : "application/json";
}

export function manifestText(files) {
  const entries = {};
  for (const [path, bytes] of files) {
    entries[path] = { bytes: bytes.length, contentType: contentType(path), etag: `"sha256:${sha256Hex(bytes)}"`, url: `${CATALOG_ROOT}${path}` };
  }
  return `${canonicalJSONString({ catalogRoot: CATALOG_ROOT, generatedAt: GENERATED_AT, files: entries })}\n`;
}

export function swiftSourceText(files) {
  const lines = [];
  lines.push("// GENERATED by mobile-shell/website/seed-catalog-v2.mjs. Do not edit by hand:");
  lines.push("// change that script and run it again (it also writes the website copy of these");
  lines.push("// exact bytes, docs/plans/20260928-all-routes/round3-deferred/M-store-screens/");
  lines.push("// website-catalog-v2/). `node mobile-shell/website/seed-catalog-v2.mjs --check`");
  lines.push("// fails if this file and the website copy ever drift apart.");
  lines.push("");
  lines.push("/// The bundled seed catalog v2: the apps that come with Iris, as the exact");
  lines.push("/// files publikhq.com would serve. Decoded by `StoreCatalogSeed` through the");
  lines.push("/// same catalog client, parser and size caps as a network answer.");
  lines.push("enum StoreCatalogSeedData {");
  lines.push(`    static let catalogRoot = "${CATALOG_ROOT}"`);
  lines.push(`    static let generatedAt = "${GENERATED_AT}"`);
  lines.push("");
  lines.push("    /// Path under `catalogRoot`, the sha256 of the bytes, and the bytes (base64).");
  lines.push("    static let files: [(path: String, sha256: String, base64: String)] = [");
  for (const [path, bytes] of files) {
    lines.push(`        (path: "${path}", sha256: "sha256:${sha256Hex(bytes)}", base64: "${bytes.toString("base64")}"),`);
  }
  lines.push("    ]");
  lines.push("}");
  return `${lines.join("\n")}\n`;
}

export function deployText(files, packages) {
  const rows = [...files].map(([path, bytes]) => `| \`${CATALOG_ROOT}${path}\` | \`api/iris/mobile/${path}\` | ${contentType(path)} | \`"sha256:${sha256Hex(bytes)}"\` |`);
  const packageRows = packages.map((pkg) => `| \`${CATALOG_ROOT}${pkg.packagePath}\` | \`mobile-shell/native/IrisMobileShellApp/Resources/Starter/${pkg.sourcePath.split("/Starter/")[1]}\` | application/json | ${pkg.byteCount} bytes, \`${pkg.packageSha256}\` |`);
  return `# Deploying the first mobile catalog (not deployed yet)

Generated by \`node mobile-shell/website/seed-catalog-v2.mjs\` on the fixed publish time ${GENERATED_AT}. Nothing here has been uploaded. The iPhone app already carries these exact files inside it, so Browse shows these four apps even while publikhq.com has no mobile catalog. Uploading them makes publikhq.com the source again, and later catalogs replace them.

## What to upload

Copy the folder \`api/\` from this directory to the web root of publikhq.com, so each file answers at the address in the first column. Send each file with the content type and ETag shown. Answer \`If-None-Match\` with 304 when the ETag matches (the app sends it; this keeps each launch to one small request). No redirects: the app refuses them.

| Address | File in this folder | Content-Type | ETag |
|---|---|---|---|
${rows.join("\n")}

\`manifest.json\` in this folder lists the same facts in machine-readable form.

Other headers: \`Cache-Control: no-cache\` for index.json and categories.json (the app always revalidates them), \`Cache-Control: public, max-age=31536000, immutable\` for icons (their names are their hashes). Do not gzip on the fly unless the server also sends a matching Content-Length; the app asks for \`Accept-Encoding: identity\`.

## Packages (optional)

Every phone installs Kneecap, Nut AI and FreeHarmony from inside Iris on first launch, and Lunara (which needs an age check first) is set up from inside Iris the moment someone taps Get, so nobody needs to download any of them. The app pages still name a download address, which only matters if someone removed an app and taps Get before Iris sets it up again. Kneecap, Nut AI and FreeHarmony are updates on top of earlier versions, so a phone without the app cannot install those from this address alone; leave them off the server unless the publisher makes fresh single-step packages. Lunara's package is a single step, so it could be served as is.

| Address | Source file | Content-Type | Size and hash |
|---|---|---|---|
${packageRows.join("\n")}

## Before uploading, please confirm

- Age ratings: Kneecap 4+, Nut AI 13+ (decided, apple-compliance/DECISIONS.md OD-08), FreeHarmony 13+ (face and looks apps can touch on body image), Lunara 16+ (a proposal: it logs intimacy, contraception and pregnancy; 18+ is the alternative). Change them in \`SEED_APPS\` in the script and run it again.
- Support links point at each app's page on publikhq.com (\`https://publikhq.com/iris/apps/<slug>\`). Those pages should exist before the catalog goes live.
- The descriptions promise that photos, clips, food logs and the cycle log stay on the phone. Please confirm that is true for each app.

## Check after uploading

\`curl -sI https://publikhq.com/api/iris/mobile/index.json\` should show \`200\`, \`content-type: application/json\` and the ETag above. Then open Iris on the phone: the line under Browse changes from "Showing the apps that came with Iris..." to "Checked today at ...".
`;
}

async function readOrNull(path) {
  try {
    return await readFile(path);
  } catch {
    return null;
  }
}

export async function outputs() {
  const { files, packages } = await buildSeedCatalog();
  const out = new Map();
  for (const [path, bytes] of files) out.set(join(WEBSITE_OUT, "api/iris/mobile", path), bytes);
  out.set(join(WEBSITE_OUT, "manifest.json"), Buffer.from(manifestText(files), "utf8"));
  out.set(join(WEBSITE_OUT, "DEPLOY.md"), Buffer.from(deployText(files, packages), "utf8"));
  out.set(SWIFT_OUT, Buffer.from(swiftSourceText(files), "utf8"));
  return { out, files, packages };
}

/**
 * DEPLOY.md is shared: this script writes its first half and RC-03's
 * build-site.mjs appends a marked website section after it (see
 * deploy-addendum.mjs). Regenerating must keep that section, and --check must
 * not call it stale, so the file is compared and written as this script's text
 * followed by whatever marked section is already there.
 */
export function deployMdWithAddendum(generated, existing) {
  if (existing === null) return generated;
  const text = existing.toString("utf8");
  const markerIndex = text.indexOf(RC03_MARKER);
  if (markerIndex === -1) return generated;
  const head = generated.toString("utf8").replace(/\s+$/, "");
  return Buffer.from(`${head}\n\n${text.slice(markerIndex)}`, "utf8");
}

async function main() {
  const check = process.argv.includes("--check");
  const { out } = await outputs();
  const drift = [];
  for (const [path, generated] of out) {
    const current = await readOrNull(path);
    const bytes = path === join(WEBSITE_OUT, "DEPLOY.md") ? deployMdWithAddendum(generated, current) : generated;
    if (current !== null && current.equals(bytes)) continue;
    if (check) {
      drift.push(path);
      continue;
    }
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, bytes);
    console.log(`wrote ${path} (${bytes.length} bytes)`);
  }
  if (check) {
    if (drift.length) {
      console.error(`seed catalog outputs are out of date:\n${drift.join("\n")}`);
      process.exitCode = 1;
    } else {
      console.log(`seed catalog outputs match (${out.size} files)`);
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
