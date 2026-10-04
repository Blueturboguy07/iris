// Deterministic catalog v2 fixture generator.
//
// Given a seed string and an app count, produces the reviewed app records a
// real publish starts from, then runs them through the publisher's own
// emitCatalogV2, so the fixtures are byte-for-byte what the publisher would
// ship: one or more index v2 pages, categories.json, and one
// apps/<slug>.json detail page per app. Same seed + same count always
// produces byte-identical output (see test/generate.test.mjs), so M2, M5,
// M6 and D10 can all build against the exact same bytes.
//
// Stability note: the main random stream below is drawn in exactly the
// order the first version of this generator used (including draws whose
// values are no longer used directly), so app slugs, and therefore fixture
// file names, stay the same across generator revisions. Fields added or
// reworked later draw from a separate per-app stream instead.

import {
  CATALOG_V2_LIMITS,
  DELIVERY_PACKAGE_FORMAT,
  KNOWN_AGE_RATINGS,
  KNOWN_CATALOG_BADGES,
  catalogIndexEntryDataBytes,
} from "../../../contracts/index.js";
import { emitCatalogV2 } from "../../../publisher/catalog-v2.mjs";
import { buildFixturePackage, fixtureIconBytes, iconHashForBytes } from "./packages.mjs";
import {
  CATEGORY_NAMES,
  DESCRIPTION_SENTENCES,
  KNOWN_CAPABILITY_LABELS,
  NAME_ADJECTIVES,
  NAME_NOUNS,
  SUMMARY_TEMPLATES,
} from "./wordlist.mjs";
import { deterministicHex, makeRng, rngInt, rngPick, rngShuffled } from "./rng.mjs";

export const GENERATED_AT = "2026-09-28T12:00:00.000Z";
const CAPABILITY_IDS = Object.keys(KNOWN_CAPABILITY_LABELS);
const MIN_APP_BYTES = 40 * 1024;
const MAX_APP_BYTES = 24 * 1024 * 1024;

function slugify(text) {
  return text.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function dateDaysAgo(baseMillis, days) {
  return new Date(baseMillis - days * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

function buildCategories() {
  return CATEGORY_NAMES.slice(0, CATALOG_V2_LIMITS.maxCategories).map((name, index) => ({
    id: index + 1,
    name,
    order: index,
  }));
}

/** Log-uniform download size between 40 KB and 24 MB: most apps are small, a few are large. */
function realisticByteCount(appRng) {
  const low = Math.log(MIN_APP_BYTES);
  const high = Math.log(MAX_APP_BYTES);
  return Math.round(Math.exp(low + appRng() * (high - low)));
}

function fillTemplate(template, adjective, noun) {
  return template.replaceAll("{adj}", adjective).replaceAll("{noun}", noun.toLowerCase());
}

/**
 * Picks a summary for the row that keeps the row inside the 200-byte
 * per-app budget: the drawn template first, then shorter templates, then a
 * trimmed version of the shortest. A real publisher would ask the author to
 * shorten; the generator does the same thing automatically.
 */
function summaryWithinBudget(entry, preferredTemplate, adjective, noun) {
  const candidates = [preferredTemplate, ...[...SUMMARY_TEMPLATES].sort((a, b) => a.length - b.length)];
  for (const template of candidates) {
    const summary = fillTemplate(template, adjective, noun);
    if (summary.length > CATALOG_V2_LIMITS.maxSummaryChars) continue;
    if (catalogIndexEntryDataBytes({ ...entry, summary }) <= CATALOG_V2_LIMITS.maxAppEntryBytes) return summary;
  }
  let summary = fillTemplate(candidates[1], adjective, noun);
  while (summary.length > 8 && catalogIndexEntryDataBytes({ ...entry, summary }) > CATALOG_V2_LIMITS.maxAppEntryBytes) {
    summary = summary.slice(0, -1).trimEnd();
  }
  if (catalogIndexEntryDataBytes({ ...entry, summary }) > CATALOG_V2_LIMITS.maxAppEntryBytes) {
    throw new Error(`cannot fit ${entry.slug} inside the per-app budget`);
  }
  return summary;
}

/**
 * The reviewed app records (index fields and detail-page fields on one
 * object, as `publisher/cli.mjs catalog-emit` reads them) plus the
 * categories input, before emitting.
 *
 * @param {{ seed: string, appCount: number }} options
 */
export function planCatalog({ seed, appCount }) {
  if (typeof seed !== "string" || seed.length < 1) {
    throw new TypeError("seed must be a non-empty string");
  }
  if (!Number.isSafeInteger(appCount) || appCount < 0) {
    throw new TypeError("appCount must be a non-negative integer");
  }

  const rng = makeRng(`${seed}:${appCount}`);
  const categories = buildCategories();
  const categoryIds = categories.map((category) => category.id);
  const baseMillis = Date.parse(GENERATED_AT);
  const apps = [];
  const usedSlugs = new Set();

  for (let i = 0; i < appCount; i += 1) {
    // --- main stream, original draw order (keeps slugs stable) ---
    const adjective = rngPick(rng, NAME_ADJECTIVES);
    const noun = rngPick(rng, NAME_NOUNS);
    const name = `${adjective} ${noun}`;
    let slug = slugify(`${adjective}-${noun}`);
    if (usedSlugs.has(slug) || i >= NAME_ADJECTIVES.length * NAME_NOUNS.length) {
      slug = `${slug}-${i}`;
    }
    while (usedSlugs.has(slug)) slug = `${slug}-x`;
    usedSlugs.add(slug);

    const categoryCount = rngInt(rng, 1, 3);
    const appCategoryIds = rngShuffled(rng, categoryIds).slice(0, categoryCount);
    const badgeCount = rngInt(rng, 0, 2);
    // "new" and "updated" never appear together: a brand-new app has no
    // earlier version to update from.
    const badges = rngShuffled(rng, [...KNOWN_CATALOG_BADGES]).slice(0, Math.min(badgeCount, 1));
    // Roughly 1 in 12 apps carries a sponsored or featured slot.
    const wantsPlacement = rngInt(rng, 1, 12) === 1;
    let placement = null;
    if (wantsPlacement) {
      const sponsored = rngInt(rng, 0, 1) === 1;
      const featured = !sponsored || rngInt(rng, 0, 1) === 1;
      placement = { featured, sponsored, label: sponsored ? "Sponsored" : "Featured" };
    }
    rngInt(rng, 4 * 1024 * 1024, 220 * 1024 * 1024); // retired size draw, kept for stability
    const ageRating = rngPick(rng, KNOWN_AGE_RATINGS);
    const updatedAt = dateDaysAgo(baseMillis, rngInt(rng, 0, 720));
    const permissionCount = rngInt(rng, 0, 3);
    const permissions = rngShuffled(rng, CAPABILITY_IDS)
      .slice(0, permissionCount)
      .sort()
      .map((capability) => ({ capability, label: KNOWN_CAPABILITY_LABELS[capability] }));
    const screenshotCount = rngInt(rng, 1, 3);
    const screenshots = Array.from({ length: screenshotCount }, (_, n) => ({
      url: `https://publikhq.com/shots/${slug}/${n + 1}.png`,
      bytes: rngInt(rng, 40 * 1024, 380 * 1024),
    }));
    const hasWhatsNew = rngInt(rng, 0, 2) > 0;
    rngInt(rng, 1024, 16 * 1024); // retired descriptor size draw, kept for stability
    const description = `${name}: ${rngPick(rng, DESCRIPTION_SENTENCES)} ${rngPick(rng, DESCRIPTION_SENTENCES)}`;

    // --- per-app stream for fields added later ---
    const appRng = makeRng(`${seed}:${appCount}:${slug}:fields-v2`);
    const byteCount = realisticByteCount(appRng);
    const summaryTemplate = rngPick(appRng, SUMMARY_TEMPLATES);
    const contentHashHex = deterministicHex(seed, slug, "content");
    const packageHashHex = deterministicHex(seed, slug, "package");

    const entry = {
      slug,
      name,
      summary: "",
      categoryIds: appCategoryIds,
      iconHash: iconHashForBytes(fixtureIconBytes(seed, slug)),
      iconURL: `https://publikhq.com/i/${slug}.png`,
      byteCount,
      ageRating,
      updatedAt,
      badges,
      placement,
    };
    entry.summary = summaryWithinBudget(entry, summaryTemplate, adjective, noun);

    apps.push({
      ...entry,
      mobileShell: {
        version: 1,
        platform: "ios",
        packageFormat: DELIVERY_PACKAGE_FORMAT,
        downloadUrl: `https://publikhq.com/api/iris/mobile-shell/${slug}/pkg.json`,
        mediaType: "application/json",
        byteCount,
        packageSha256: `sha256:${packageHashHex}`,
        appId: `publik.${slug}`,
        projectId: `publik.${slug}.mobile`,
        baseRevisionId: null,
        revisionId: `rev-sha256:${contentHashHex}`,
        contentHash: `sha256:${contentHashHex}`,
        appStoreMetadata: null,
      },
      description,
      screenshots,
      permissions,
      privacySummary: `${name} keeps your data on this device unless you choose to share it.`,
      supportURL: `https://${slug}.example/support`,
      whatsNew: hasWhatsNew ? `Faster startup and small fixes for ${name}.` : null,
    });
  }
  return { seed, appCount, generatedAt: GENERATED_AT, apps, categories };
}

function emitPlan(plan) {
  const emitted = emitCatalogV2({ apps: plan.apps, categories: plan.categories, generatedAt: plan.generatedAt });
  return {
    seed: plan.seed,
    appCount: plan.appCount,
    generatedAt: plan.generatedAt,
    reviewedApps: plan.apps,
    ...emitted,
  };
}

/**
 * A catalog whose descriptors are realistic but not backed by stored
 * package bytes (their packageSha256 matches no package; installing one
 * fails closed at the digest check).
 *
 * @param {{ seed: string, appCount: number }} options
 */
export function generateCatalog({ seed, appCount }) {
  return emitPlan(planCatalog({ seed, appCount }));
}

/**
 * A catalog in which every app has a real, installable package and a real
 * icon: each descriptor (and the index row's byteCount) is derived from the
 * package bytes, and each iconHash from the icon bytes.
 *
 * @param {{ seed: string, appCount: number }} options
 * @returns {Promise<ReturnType<typeof generateCatalog> & { packages: Map<string, Uint8Array>, icons: Map<string, Uint8Array> }>}
 */
export async function generateCatalogWithPackages({ seed, appCount }) {
  const plan = planCatalog({ seed, appCount });
  const packages = new Map();
  const icons = new Map();
  for (const app of plan.apps) {
    const appRng = makeRng(`${seed}:${appCount}:${app.slug}:package-v1`);
    const { packageBytes, descriptor } = await buildFixturePackage({
      seed,
      slug: app.slug,
      name: app.name,
      capabilities: app.permissions.map((permission) => permission.capability),
      scriptBytes: rngInt(appRng, 45 * 1024, 220 * 1024),
    });
    packages.set(app.slug, packageBytes);
    icons.set(app.slug, fixtureIconBytes(seed, app.slug));
    app.mobileShell = descriptor;
    app.byteCount = descriptor.byteCount;
    const adjective = app.name.split(" ")[0];
    const noun = app.name.split(" ").slice(1).join(" ");
    const preferred = SUMMARY_TEMPLATES.find((template) => fillTemplate(template, adjective, noun) === app.summary)
      ?? SUMMARY_TEMPLATES[0];
    app.summary = summaryWithinBudget(app, preferred, adjective, noun);
  }
  return { ...emitPlan(plan), packages, icons };
}
