// Catalog expand (round6/catalog-expand). Test author: spec only.
//
// The owner asked why the iPhone store lists 3 apps when Browse on
// publikhq.com marks about ten for iPhone. SPEC.md decides the answer: the
// store becomes 4 apps (Kneecap, Nut AI, FreeHarmony, Lunara), Lunara is
// bundled but not installed until someone taps Get, and no other Browse app
// can honestly be listed. These tests check that outcome from the outside,
// on the files a phone and the website actually read.
//
// Oracles come from outside the generator: the package bytes that ship in
// the app (hashes, sizes, revision ids, capabilities, file contents), the
// numbers written in SPEC.md, and arithmetic over the served files (a
// category's count is the number of rows that name it). Nothing here calls
// seed-catalog-v2.mjs internals; the one exception is running its documented
// `--check` command as a child process, as SPEC.md section 8 item 10 says.
//
// Every assertion cites the SPEC.md line it comes from ("SPEC L<n>").
// Expected to FAIL until the builder lands Lunara.

import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import {
  validateCatalogAppPageV1,
  validateCatalogCategoriesV1,
  validateCatalogIndexEntryMatchesAppPage,
  validateCatalogIndexV2,
} from "../../contracts/index.js";
import { CATALOG_ROOT, SWIFT_OUT, WEBSITE_OUT } from "../seed-catalog-v2.mjs";

const execFileAsync = promisify(execFile);

const MOBILE_ROOT = path.join(WEBSITE_OUT, "api/iris/mobile");
const STARTER_ROOT = path.resolve(path.dirname(SWIFT_OUT), "../../../IrisMobileShellApp/Resources/Starter");
const SEED_SCRIPT = path.resolve(path.dirname(SWIFT_OUT), "../../../../../mobile-shell/website/seed-catalog-v2.mjs");
const ICON_SEED_DIR = path.resolve(SEED_SCRIPT, "..", "seed");
const REPO_ROOT = path.resolve(SEED_SCRIPT, "../../..");
const ROUND6_DIR = path.join(REPO_ROOT, "docs/plans/20260928-all-routes/round6");

// SPEC L4, L107 (acceptance 1): the four apps, in the names a person reads.
const EXPECTED = [
  { slug: "kneecap", name: "Kneecap", appId: "publik.kneecap", ageRating: 4 },
  { slug: "nut-ai", name: "Nut AI", appId: "publik.nut-ai", ageRating: 13 },
  { slug: "freeharmony", name: "FreeHarmony", appId: "publik.freeharmony", ageRating: 13 },
  // SPEC L92, L108: 16 is the proposal and the default; the owner may pick 18
  // (SPEC L95, L97). If the owner picks 18, change this one number.
  { slug: "lunara", name: "Lunara", appId: "publik.lunara", ageRating: 16 },
];
// SPEC L114 (acceptance 8): apps that must not appear anywhere in the store.
const EXCLUDED = [
  { slug: "noscroll", name: "NoScroll" },
  { slug: "hat", name: "HAT" },
  { slug: "chirp", name: "Chirp" },
  { slug: "beaver", name: "Beaver" },
  { slug: "turbolarp", name: "Turbolarp" },
  { slug: "mymacrohero", name: "MyMacroHero" },
  { slug: "microstudy", name: "Microstudy" },
];
const SHELL_AGE_RATING = 13; // SPEC L92: a badge shows only above 13.
const MAX_SUMMARY = 80; // SPEC L80, L108.
const TWO_MB = 2 * 1024 * 1024; // SPEC L116.

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function readJSON(...parts) {
  return JSON.parse(await readFile(path.join(...parts), "utf8"));
}

async function loadIndex() {
  return readJSON(MOBILE_ROOT, "index.json");
}

async function loadPage(slug) {
  return readJSON(MOBILE_ROOT, "apps", `${slug}.json`);
}

/** Newest package (last file by name) in each Starter/<label>/ folder, keyed by the appId inside it. */
async function shippedPackagesByAppId() {
  const byAppId = new Map();
  for (const label of await readdir(STARTER_ROOT)) {
    const folder = path.join(STARTER_ROOT, label);
    if (!(await stat(folder)).isDirectory()) continue;
    const files = (await readdir(folder)).filter((name) => name.endsWith(".irisapp")).sort();
    if (files.length === 0) continue;
    const file = path.join(folder, files[files.length - 1]);
    const bytes = await readFile(file);
    const parsed = JSON.parse(bytes.toString("utf8"));
    byAppId.set(parsed.envelope.appId, { label, file, fileNames: files, bytes, parsed });
  }
  return byAppId;
}

const TEXT_TYPE = /^text\/|javascript|json|xml|svg|html|css/i;

/**
 * The problems a person or a store reviewer would object to inside a package,
 * from SPEC L115 (acceptance 9). Scans every file path and every file's
 * bytes (read as latin1 so binary files cannot hide a plain string).
 */
export function packageHygieneProblems(parsedPackage) {
  const problems = [];
  const banned = [
    [/capcut/i, "a CapCut mark"],
    [/tiktok/i, "a TikTok mark"],
    [/instagram/i, "an Instagram mark"],
    [/bytedance/i, "a ByteDance mark"],
    [/api\.anthropic\.com/i, "the api.anthropic.com address"],
    [/api key/i, "the words \"API key\""],
  ];
  let sawLicense = false;
  let sawNotices = false;
  for (const file of parsedPackage.files) {
    const content = Buffer.from(file.contentBase64, "base64");
    const text = content.toString("latin1");
    for (const [pattern, what] of banned) {
      if (pattern.test(file.path)) problems.push(`${file.path}: file name has ${what}`);
      if (pattern.test(text)) problems.push(`${file.path}: contains ${what}`);
    }
    if (/licen[cs]e/i.test(path.basename(file.path)) && /GNU AFFERO GENERAL PUBLIC LICENSE/i.test(text)) sawLicense = true;
    if (/third[-_ ]?party.*notice|notices/i.test(path.basename(file.path)) && TEXT_TYPE.test(file.mediaType) && text.trim().length > 200) sawNotices = true;
  }
  if (!sawLicense) problems.push("no AGPL licence text file inside the package");
  if (!sawNotices) problems.push("no third-party notices file inside the package");
  return problems;
}

// ---------------------------------------------------------------------------
// The index: what Browse lists
// ---------------------------------------------------------------------------

test("SPEC L107: the index lists exactly the four apps, on one page, and passes the v2 contract", async () => {
  const index = await loadIndex();
  assert.equal(validateCatalogIndexV2(index).ok, true, JSON.stringify(validateCatalogIndexV2(index)));
  assert.equal(index.pageCount, 1, "SPEC L107: below 13 apps the store shows one plain list");
  assert.equal(index.apps.length, 4, "SPEC L9, L12: the honest result today is 4 apps");
  assert.deepEqual(index.apps.map((row) => row.slug).sort(), EXPECTED.map((app) => app.slug).sort());
  assert.deepEqual(index.apps.map((row) => row.name).sort(), EXPECTED.map((app) => app.name).sort());
  assert.equal(new Set(index.apps.map((row) => row.slug)).size, 4, "no duplicate rows");
});

test("SPEC L108, L80: every row has an icon, a name, and a summary of 1 to 80 characters with no em dash", async () => {
  const index = await loadIndex();
  for (const row of index.apps) {
    assert.ok(row.name.trim().length > 0, `${row.slug} has a name`);
    assert.ok(row.summary.trim().length > 0, `${row.name} has a summary`);
    assert.ok([...row.summary].length <= MAX_SUMMARY, `${row.name}: summary is ${[...row.summary].length} characters, the cap is ${MAX_SUMMARY}`);
    assert.doesNotMatch(row.summary + row.name, new RegExp(String.fromCharCode(0x2014)), `${row.name}: no em dash`);
    assert.equal(row.summary, row.summary.trim(), `${row.name}: no stray spaces around the summary`);
    assert.ok(row.byteCount > 0, `${row.name} states a real download size`);
    assert.ok(row.iconURL.startsWith(CATALOG_ROOT), `${row.name}: icon is served from the catalog root`);
    const icon = await readFile(path.join(MOBILE_ROOT, row.iconURL.slice(CATALOG_ROOT.length)));
    assert.deepEqual([...icon.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47], `${row.name}: icon is a PNG`);
    assert.equal(sha256(icon).slice(0, 16), row.iconHash, `${row.name}: icon bytes match the hash in the row`);
    assert.ok(icon.length <= 64 * 1024, `${row.name}: icon is small enough for a phone`);
  }
  assert.equal(new Set(index.apps.map((row) => row.iconHash)).size, 4, "SPEC L80: Lunara has its own icon, not a copy of another app's");
});

test("SPEC L92, L108: age ratings are 4, 13, 13 and 16, and only Lunara is above the shell rating that shows a badge", async () => {
  const index = await loadIndex();
  for (const app of EXPECTED) {
    const row = index.apps.find((entry) => entry.slug === app.slug);
    assert.ok(row, `${app.name} is listed`);
    assert.equal(row.ageRating, app.ageRating, `${app.name} age rating`);
    assert.equal((await loadPage(app.slug)).mobileShell.appId, app.appId);
  }
  const badged = index.apps.filter((row) => row.ageRating > SHELL_AGE_RATING).map((row) => row.slug);
  assert.deepEqual(badged, ["lunara"], "SPEC L108: the other three show no age badge");
});

test("SPEC L80: a Health and body category (id 4) exists, holds Lunara, and every category count is the number of rows naming it", async () => {
  const index = await loadIndex();
  const categories = await readJSON(MOBILE_ROOT, "categories.json");
  assert.equal(validateCatalogCategoriesV1(categories).ok, true, JSON.stringify(validateCatalogCategoriesV1(categories)));
  const health = categories.categories.find((category) => category.id === 4);
  assert.ok(health, "category id 4 exists");
  assert.equal(health.name, "Health and body");
  const lunara = index.apps.find((row) => row.slug === "lunara");
  assert.deepEqual(lunara.categoryIds, [4], "Lunara sits in Health and body");
  assert.equal(new Set(categories.categories.map((category) => category.id)).size, categories.categories.length, "category ids are unique");
  assert.equal(new Set(categories.categories.map((category) => category.order)).size, categories.categories.length, "category orders are unique");
  for (const category of categories.categories) {
    const counted = index.apps.filter((row) => row.categoryIds.includes(category.id)).length;
    assert.equal(category.appCount, counted, `${category.name}: appCount is the number of rows in it`);
  }
  for (const row of index.apps) {
    for (const id of row.categoryIds) assert.ok(categories.categories.some((category) => category.id === id), `${row.name}: category ${id} exists`);
  }
  assert.deepEqual(
    ["Video editing", "Food and nutrition", "Face and looks"].every((name) => categories.categories.some((category) => category.name === name)),
    true,
    "the existing three categories stay",
  );
});

// ---------------------------------------------------------------------------
// The app pages
// ---------------------------------------------------------------------------

test("SPEC L110: Lunara's page has a description, the permission line 'Keeps your log on this phone', and a privacy line", async () => {
  const page = await loadPage("lunara");
  const result = validateCatalogAppPageV1(page);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.ok(page.description.trim().length >= 40, "a real description, not a stub");
  assert.deepEqual(page.permissions, [{ capability: "web.storage", label: "Keeps your log on this phone" }], "SPEC L50, L80: web.storage only, in plain words");
  assert.ok(page.privacySummary && page.privacySummary.trim().length > 0, "a privacy line is shown");
  assert.match(page.supportURL, /^https:\/\/publikhq\.com\//);
  assert.doesNotMatch(JSON.stringify(page), new RegExp(String.fromCharCode(0x2014)), "no em dash");
  assert.match(page.description + (page.privacySummary ?? ""), /not a medical device|not medical advice|not a medical/i, "SPEC L110, L65: the not-a-medical-device wording reaches the reader");
});

test("SPEC L110 and the v2 contract: every row agrees with its own page, and no page is orphaned", async () => {
  const index = await loadIndex();
  const pageFiles = (await readdir(path.join(MOBILE_ROOT, "apps"))).filter((name) => name.endsWith(".json")).sort();
  assert.deepEqual(pageFiles, index.apps.map((row) => `${row.slug}.json`).sort(), "one page per row and no extra pages");
  for (const row of index.apps) {
    const page = await loadPage(row.slug);
    assert.equal(validateCatalogAppPageV1(page).ok, true, `${row.name} page validates`);
    const agreement = validateCatalogIndexEntryMatchesAppPage(row, page);
    assert.equal(agreement.ok, true, `${row.name}: ${JSON.stringify(agreement)}`);
    assert.ok(page.mobileShell.downloadUrl.startsWith(CATALOG_ROOT), `${row.name}: package address is under the catalog root`);
    assert.ok(page.permissions.length > 0 && page.permissions.every((permission) => permission.label.trim().length > 0), `${row.name}: every permission has a plain-word label`);
  }
});

// ---------------------------------------------------------------------------
// Package hashes match the package files that ship inside the app
// ---------------------------------------------------------------------------

test("SPEC L50, L79: each page's package hash, size, revision and app id match the bytes of the package file in the app", async () => {
  const shipped = await shippedPackagesByAppId();
  const index = await loadIndex();
  for (const app of EXPECTED) {
    const row = index.apps.find((entry) => entry.slug === app.slug);
    const page = await loadPage(app.slug);
    const found = shipped.get(app.appId);
    assert.ok(found, `${app.name}: a package for ${app.appId} ships in Resources/Starter`);
    const envelope = found.parsed.envelope;
    assert.equal(page.mobileShell.appId, envelope.appId);
    assert.equal(page.mobileShell.revisionId, envelope.revisionId);
    assert.equal(page.mobileShell.contentHash, envelope.contentHash);
    assert.equal(page.mobileShell.packageSha256, `sha256:${sha256(found.bytes)}`, `${app.name}: package hash`);
    assert.equal(page.mobileShell.byteCount, found.bytes.length, `${app.name}: package size`);
    assert.equal(row.byteCount, found.bytes.length, `${app.name}: the size Browse shows is the real download size`);
    assert.equal(row.latestRevisionId, envelope.revisionId, `${app.name}: an installed copy never looks out of date`);
    assert.equal(
      found.parsed.envelope.revision.manifest.displayName.toLowerCase(),
      app.name.toLowerCase(),
      `${app.name}: the package names itself the same app the store lists (Kneecap's package spells it in lower case)`,
    );
  }
});

test("SPEC L79: Lunara ships as one revision at Starter/Lunara/01-base.irisapp and is a first revision (no base)", async () => {
  const shipped = await shippedPackagesByAppId();
  const lunara = shipped.get("publik.lunara");
  assert.ok(lunara, "publik.lunara ships in Resources/Starter");
  assert.equal(lunara.label, "Lunara");
  assert.deepEqual(lunara.fileNames, ["01-base.irisapp"], "a single revision");
  assert.equal(lunara.parsed.envelope.baseRevisionId, null);
  assert.equal(lunara.parsed.envelope.projectId, "publik.lunara.mobile");
});

test("the permissions a page promises are exactly the capabilities the package asks for", async () => {
  const shipped = await shippedPackagesByAppId();
  for (const app of EXPECTED) {
    const page = await loadPage(app.slug);
    const asked = [...shipped.get(app.appId).parsed.envelope.revision.manifest.capabilities].sort();
    const promised = page.permissions.map((permission) => permission.capability).sort();
    assert.deepEqual(promised, asked, `${app.name}: the page must not hide a capability or list one the package does not use`);
  }
  const lunara = shipped.get("publik.lunara").parsed.envelope.revision.manifest.capabilities;
  assert.deepEqual([...lunara], ["web.storage"], "SPEC L50: Lunara needs web.storage only, so no network, camera or export");
});

// ---------------------------------------------------------------------------
// Package hygiene (acceptance 9) and size (acceptance 10)
// ---------------------------------------------------------------------------

test("SPEC L115: the Lunara package has no CapCut/TikTok/Instagram/ByteDance marks, no api.anthropic.com or 'API key' text, and carries its AGPL licence and a third-party notices file", async () => {
  const lunara = (await shippedPackagesByAppId()).get("publik.lunara");
  assert.ok(lunara, "publik.lunara ships in Resources/Starter");
  assert.deepEqual(packageHygieneProblems(lunara.parsed), []);
});

test("the hygiene scan itself catches each fault (synthetic packages, so a passing scan means something)", () => {
  const file = (name, text, mediaType = "text/plain") => ({ path: name, mediaType, contentBase64: Buffer.from(text).toString("base64") });
  const clean = [
    file("LICENSE.txt", "GNU AFFERO GENERAL PUBLIC LICENSE Version 3\n" + "x".repeat(300)),
    file("THIRD_PARTY_NOTICES.md", "Notices\n" + "y".repeat(300), "text/markdown"),
    file("app.js", "console.log('hello')", "text/javascript"),
  ];
  assert.deepEqual(packageHygieneProblems({ files: clean }), []);
  const cases = [
    ["CapCut in a script", [...clean, file("b.js", "// like CapCut", "text/javascript")], /CapCut/],
    ["TikTok in a stylesheet", [...clean, file("b.css", ".tiktok-red{}", "text/css")], /TikTok/],
    ["Instagram in a file name", [...clean, file("instagram.png", "x", "image/png")], /Instagram/],
    ["ByteDance inside a binary", [...clean, file("b.bin", "\u0000\u0001ByteDance\u0002", "application/octet-stream")], /ByteDance/],
    ["Anthropic address", [...clean, file("b.js", "fetch('https://api.anthropic.com/v1')", "text/javascript")], /api\.anthropic\.com/],
    ["API key wording", [...clean, file("b.html", "<p>Paste your API key</p>", "text/html")], /API key/],
    ["missing licence", clean.filter((f) => f.path !== "LICENSE.txt"), /licence/],
    ["missing notices", clean.filter((f) => f.path !== "THIRD_PARTY_NOTICES.md"), /notices/],
  ];
  for (const [label, files, expected] of cases) {
    assert.ok(packageHygieneProblems({ files }).some((problem) => expected.test(problem)), `${label} must be reported`);
  }
});

test("SPEC L116: the app grows by no more than 2 MB (Lunara's package, page and icon together)", async () => {
  const lunara = (await shippedPackagesByAppId()).get("publik.lunara");
  assert.ok(lunara, "publik.lunara ships in Resources/Starter");
  const page = await stat(path.join(MOBILE_ROOT, "apps/lunara.json"));
  const index = await loadIndex();
  const icon = await stat(path.join(MOBILE_ROOT, "icons", `${index.apps.find((row) => row.slug === "lunara").iconHash}.png`));
  const added = lunara.bytes.length + page.size + icon.size;
  // The seed catalog inside the app carries the page and icon a second time as base64.
  const insideApp = lunara.bytes.length + Math.ceil(((page.size + icon.size) * 4) / 3);
  assert.ok(added <= TWO_MB, `Lunara adds ${added} bytes of files, the cap is ${TWO_MB}`);
  assert.ok(insideApp <= TWO_MB, `Lunara adds about ${insideApp} bytes to the app, the cap is ${TWO_MB}`);
});

test("SPEC L80: seed/lunara.png exists in the icon folder and is the icon the catalog serves for Lunara", async () => {
  const drawn = await readFile(path.join(ICON_SEED_DIR, "lunara.png"));
  assert.deepEqual([...drawn.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47]);
  const row = (await loadIndex()).apps.find((entry) => entry.slug === "lunara");
  assert.equal(sha256(drawn).slice(0, 16), row.iconHash);
});

// ---------------------------------------------------------------------------
// No fake apps (acceptance 8)
// ---------------------------------------------------------------------------

test("SPEC L114: none of the seven apps that cannot run in the shell appears in the catalog, the app copy, or the deploy folder", async () => {
  const index = await loadIndex();
  const swiftText = await readFile(SWIFT_OUT, "utf8");
  const files = new Map();
  for (const relative of ["index.json", "categories.json", ...(await readdir(path.join(MOBILE_ROOT, "apps"))).map((name) => `apps/${name}`)]) {
    files.set(relative, await readFile(path.join(MOBILE_ROOT, relative), "utf8"));
  }
  for (const excluded of EXCLUDED) {
    assert.ok(!index.apps.some((row) => row.slug === excluded.slug || row.name.toLowerCase() === excluded.name.toLowerCase()), `${excluded.name} must not be a row`);
    assert.ok(!files.has(`apps/${excluded.slug}.json`), `${excluded.name} must not have a page`);
    // The Swift copy holds base64, so decode each file before looking for names.
    for (const [relative, text] of files) {
      assert.ok(!new RegExp(`\\b${excluded.name}\\b`, "i").test(text), `${relative} must not mention ${excluded.name}`);
    }
    const decoded = [...swiftText.matchAll(/base64: "([^"]+)"/g)].map((match) => Buffer.from(match[1], "base64"));
    for (const bytes of decoded) {
      if (bytes[0] === 0x89) continue; // PNG
      assert.ok(!new RegExp(`\\b${excluded.name}\\b`, "i").test(bytes.toString("utf8")), `the copy inside the app must not mention ${excluded.name}`);
    }
  }
});

// ---------------------------------------------------------------------------
// The two copies of the catalog and the generator's own check
// ---------------------------------------------------------------------------

test("SPEC L116: the copy inside the app (StoreCatalogSeedData.swift) holds the same bytes as the website copy, with the right hash for each file", async () => {
  const swiftText = await readFile(SWIFT_OUT, "utf8");
  const rows = [...swiftText.matchAll(/\(path: "([^"]+)", sha256: "(sha256:[0-9a-f]{64})", base64: "([^"]+)"\)/g)];
  assert.ok(rows.length > 0, "the seed data file lists files");
  const manifest = await readJSON(WEBSITE_OUT, "manifest.json");
  assert.deepEqual(rows.map((row) => row[1]).sort(), Object.keys(manifest.files).sort(), "the app copy and the manifest list the same paths");
  assert.equal(rows.length, 10, "index, categories, four app pages and four icons");
  for (const [, filePath, recorded, base64] of rows) {
    const bytes = Buffer.from(base64, "base64");
    assert.equal(recorded, `sha256:${sha256(bytes)}`, `${filePath}: recorded hash is the hash of the bytes`);
    const onWebsite = await readFile(path.join(MOBILE_ROOT, filePath));
    assert.ok(bytes.equals(onWebsite), `${filePath}: app copy equals website copy`);
    assert.equal(manifest.files[filePath].etag, `"sha256:${sha256(bytes)}"`, `${filePath}: manifest ETag`);
    assert.equal(manifest.files[filePath].bytes, bytes.length, `${filePath}: manifest size`);
  }
});

test("SPEC L116: node mobile-shell/website/seed-catalog-v2.mjs --check exits 0", async () => {
  const { stdout, stderr } = await execFileAsync(process.execPath, [SEED_SCRIPT, "--check"], { cwd: REPO_ROOT, maxBuffer: 16 * 1024 * 1024 });
  assert.doesNotMatch(stdout + stderr, /out of date|differs|stale/i);
});

// ---------------------------------------------------------------------------
// Written policy check (acceptance 9, last clause)
// ---------------------------------------------------------------------------

async function findFiles(dir, name) {
  const found = [];
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return found;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) found.push(...(await findFiles(full, name)));
    else if (entry.name === name) found.push(full);
  }
  return found;
}

test("SPEC L65, L115: a written POLICY_CHECK.md for Lunara answers all 13 policy items", async () => {
  const candidates = [];
  for (const file of await findFiles(ROUND6_DIR, "POLICY_CHECK.md")) {
    const text = await readFile(file, "utf8");
    if (/lunara/i.test(text)) candidates.push({ file, text });
  }
  assert.ok(candidates.length >= 1, `no POLICY_CHECK.md that names Lunara under ${path.relative(REPO_ROOT, ROUND6_DIR)}`);
  const { text } = candidates[0];
  assert.match(text, /Policy version:\s*\S+/i, "names the policy version it checked (Kneecap's check does the same)");
  for (let item = 1; item <= 13; item += 1) {
    assert.match(text, new RegExp(`^\\|\\s*${item}\\s*\\|`, "m"), `item ${item} has its own row`);
  }
  for (let item = 1; item <= 13; item += 1) {
    const row = text.split("\n").find((line) => new RegExp(`^\\|\\s*${item}\\s*\\|`).test(line));
    assert.match(row, /PASS|FAIL|N\/A|NOT SUPPLIED/i, `item ${item} states a result`);
  }
  assert.doesNotMatch(text, new RegExp(String.fromCharCode(0x2014)), "no em dash");
});
