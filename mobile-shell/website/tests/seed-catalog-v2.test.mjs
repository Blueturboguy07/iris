// Seed catalog v2 (round3-deferred/M-store-screens). The owner's iPhone
// showed an empty Browse because publikhq.com had no mobile catalog. These
// tests check the files meant to fix that, from the website's side: the
// folder DEPLOY.md tells the owner to upload, read the way the website and a
// static host would read it. Oracles come from outside the generator: the
// starter package bytes that ship in the app, the website's own reader and
// handoff page, and the bytes on disk.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

import { validateCatalogIndexV2 } from "../../contracts/index.js";
import { loadCatalogV2Rows, renderCatalogHandoffHTML, resolveCatalogHandoff } from "../integration.mjs";
import { CATALOG_ROOT, SWIFT_OUT, WEBSITE_OUT, outputs } from "../seed-catalog-v2.mjs";

const MOBILE_ROOT = path.join(WEBSITE_OUT, "api/iris/mobile");
const STARTER_ROOT = path.resolve(path.dirname(SWIFT_OUT), "../../../IrisMobileShellApp/Resources/Starter");
// The starters Iris installs on first launch (NativeStarterCatalog.swift): label, last file, display name.
const STARTERS = [
  // round5/mobile-integrator-B1, 2026-09-28: Kneecap's chain grew to
  // 05-bugpass.irisapp (H1, kneecap-bugpass/INTEGRATION_HOOKS.md); this
  // must keep mirroring NativeStarterCatalog.swift's own last file, same
  // as seed-catalog-v2.mjs's SEED_APPS.finalFile for Kneecap.
  // round6/mobile-prep-A, 2026-09-29: chain grew to 06-deletefix.irisapp.
  ["Kneecap", "06-deletefix.irisapp", "Kneecap"],
  ["NutAI", "04-final.irisapp", "Nut AI"],
  ["FreeHarmony", "04-final.irisapp", "FreeHarmony"],
  // round6/catalog-expand (SPEC L79): Lunara ships inside Iris as a single
  // revision but is not installed until someone taps Get (SPEC L74-75).
  ["Lunara", "01-base.irisapp", "Lunara"],
];

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

/** A static host serving the upload folder; records what was asked for. */
function uploadedSite() {
  const requested = [];
  return {
    requested,
    readJSON: async (relativePath) => {
      requested.push(relativePath);
      try {
        return JSON.parse(await readFile(path.join(MOBILE_ROOT, relativePath), "utf8"));
      } catch (error) {
        if (error.code === "ENOENT") return null;
        throw error;
      }
    },
  };
}

// RC-03 (round5/rc03-website) owns DEPLOY.md as a path (see
// docs/plans/20260928-all-routes/round5/REPLAN.md item 10), so it appends a
// second section documenting the human-facing pages and the AASA file that
// seed-catalog-v2.mjs (excluded from RC-03's owned paths) does not know
// about. The exact-bytes check below is relaxed to a prefix check for that
// one file only: the part seed-catalog-v2.mjs generates must still be
// byte-identical and first, so it stays the authority on catalog uploads.
const DEPLOY_MD = "docs/plans/20260928-all-routes/round3-deferred/M-store-screens/website-catalog-v2/DEPLOY.md";

test("the checked-in website copy and the copy inside the app are exactly what the generator writes", async () => {
  const { out } = await outputs();
  for (const [file, bytes] of out) {
    const onDisk = await readFile(file);
    if (file.endsWith(DEPLOY_MD)) {
      assert.ok(
        onDisk.toString("utf8").startsWith(bytes.toString("utf8")),
        `${path.relative(process.cwd(), file)}: the seed-catalog-v2.mjs-generated portion is stale or was edited; `
        + "run node mobile-shell/website/seed-catalog-v2.mjs, then reapply RC-03's appended website section",
      );
      continue;
    }
    assert.ok(onDisk.equals(bytes), `${path.relative(process.cwd(), file)} is out of date: run node mobile-shell/website/seed-catalog-v2.mjs`);
  }
});

test("the website reads the uploaded folder as four apps a phone can open in Iris", async () => {
  const site = uploadedSite();
  const rows = await loadCatalogV2Rows({ readJSON: site.readJSON });
  assert.deepEqual(rows.map((row) => row.name).sort(), STARTERS.map(([, , name]) => name).sort());
  for (const row of rows) {
    const handoff = resolveCatalogHandoff(rows, row.slug);
    assert.equal(handoff.available, true, `${row.name} must be offered as Open in Iris`);
    assert.equal(handoff.fallbackURL, `iris-apps://install/${row.slug}`);
  }
  const html = renderCatalogHandoffHTML({ catalogRows: rows, selectedSlug: "kneecap" });
  assert.match(html, /Open in Iris/);
  assert.deepEqual(site.requested.filter((p) => p.startsWith("index")), ["index.json"], "one index page, read once");
});

test("each app page names the exact starter package that ships inside Iris", async () => {
  for (const [label, file, name] of STARTERS) {
    const bytes = await readFile(path.join(STARTER_ROOT, label, file));
    const envelope = JSON.parse(bytes.toString("utf8")).envelope;
    const index = JSON.parse(await readFile(path.join(MOBILE_ROOT, "index.json"), "utf8"));
    const row = index.apps.find((entry) => entry.name === name);
    assert.ok(row, `${name} is listed`);
    const page = JSON.parse(await readFile(path.join(MOBILE_ROOT, "apps", `${row.slug}.json`), "utf8"));
    assert.equal(page.mobileShell.appId, envelope.appId);
    assert.equal(page.mobileShell.revisionId, envelope.revisionId);
    assert.equal(page.mobileShell.packageSha256, `sha256:${sha256(bytes)}`);
    assert.equal(page.mobileShell.byteCount, bytes.length);
    assert.equal(row.byteCount, bytes.length, "the size Browse shows is the real download size");
    assert.equal(row.latestRevisionId, envelope.revisionId, "R2-CP-3: an installed starter never looks out of date");
  }
});

test("the index stays inside the v2 limits a phone enforces, and icons match their hashes", async () => {
  const text = await readFile(path.join(MOBILE_ROOT, "index.json"));
  const index = JSON.parse(text.toString("utf8"));
  assert.equal(validateCatalogIndexV2(index).ok, true);
  assert.equal(index.pageCount, 1);
  for (const row of index.apps) {
    assert.ok(row.iconURL.startsWith(CATALOG_ROOT), row.iconURL);
    const icon = await readFile(path.join(MOBILE_ROOT, row.iconURL.slice(CATALOG_ROOT.length)));
    assert.equal(sha256(icon).slice(0, 16), row.iconHash, `${row.name}'s icon file matches its hash`);
    assert.ok(icon.length <= 64 * 1024);
    assert.deepEqual([...icon.subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47], "PNG");
  }
});

test("DEPLOY.md gives the owner the right ETag for every file", async () => {
  const deploy = await readFile(path.join(WEBSITE_OUT, "DEPLOY.md"), "utf8");
  const manifest = JSON.parse(await readFile(path.join(WEBSITE_OUT, "manifest.json"), "utf8"));
  const paths = Object.keys(manifest.files);
  assert.equal(paths.length, 10, "index, categories, four app pages, four icons");
  for (const relative of paths) {
    const bytes = await readFile(path.join(MOBILE_ROOT, relative));
    const etag = `"sha256:${sha256(bytes)}"`;
    assert.equal(manifest.files[relative].etag, etag);
    assert.ok(deploy.includes(`${CATALOG_ROOT}${relative}`) && deploy.includes(etag), `DEPLOY.md lists ${relative} with its ETag`);
  }
  assert.doesNotMatch(deploy, new RegExp(String.fromCharCode(0x2014)), "no em dashes");
});
