// RC-03 (round5/rc03-website), unit R5-RC-03-website-2. Oracle for a real
// blind test finding: Jess (non-technical, on an iPhone, got a Kneecap
// link from a friend) passed 5 of 6 tasks but failed "what should Jess tap
// to get Kneecap, and does it cost anything". The app page's "How to get
// it" text promised "the fastest way to get it today" right above a "Get
// Kneecap" box that said there was no download link today, so the page
// read as broken rather than not released yet. This suite reads every
// generated app page the way Jess would (plain text top to bottom, no
// source code) and fails if the same contradiction, or an unlabelled
// "Open in Iris" link, or more than one primary action, is ever present
// again, on any app, not just Kneecap.
//
// It also exercises the other side of the fix: once a real Iris Apps App
// Store or TestFlight link exists (site-content.mjs's
// IRIS_DISTRIBUTION_URL), the same oracle must accept the page's switch to
// a real Install Iris button, so this check cannot be satisfied merely by
// permanently hiding the download route.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import { buildSite } from "../build-site.mjs";
import { SEED_CATEGORIES } from "../seed-catalog-v2.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEBSITE_ROOT = path.resolve(HERE, "..");
const REPO_ROOT = path.resolve(WEBSITE_ROOT, "../..");

const APP_SLUGS = ["kneecap", "nut-ai", "freeharmony", "lunara"];

/**
 * Reads one generated app page the way a non-technical reader would, and
 * returns a list of plain-English problems (empty means the page reads
 * clean). Every check here is about what the page SAYS, not about any
 * particular implementation, so it survives future rewording as long as
 * the substance holds.
 */
function oracleJessReadsAppPage(html) {
  const problems = [];

  const routeUnavailable = /data-install-route="unavailable"/.test(html);
  const hasInstallButton = /data-action="install-iris"/.test(html);

  // One honest availability sentence: either the page says plainly that
  // Iris Apps is not on the App Store yet, or it offers a real Install
  // button. It must never be silent on this.
  const saysNotOnAppStoreYet = /Iris Apps is not (?:in|on) the App Store yet/i.test(html);
  if (!saysNotOnAppStoreYet && !hasInstallButton) {
    problems.push("no plain-English availability sentence found (neither \"not on the App Store yet\" nor an Install button)");
  }

  // No copy anywhere on the page promises a download that is not there.
  // This is the exact shape of the bug Jess hit: "the fastest way to get
  // it today" sitting above a box that says there is nothing to download.
  const promisesTodayDownload = /(fastest way to get it today|the fastest way to (?:get|download) it|download it today|get it today)/i.test(html);
  if (routeUnavailable && promisesTodayDownload) {
    problems.push('page promises a download "today" while also marking the install route unavailable');
  }
  if (routeUnavailable === hasInstallButton) {
    // These two facts must always disagree with each other (never both
    // true, never both false): the route is either unavailable and there
    // is no install button, or it is available and there is exactly one.
    problems.push(`route-unavailable (${routeUnavailable}) and install-button-present (${hasInstallButton}) must never agree`);
  }

  // Exactly one primary action on the page (one clearly tappable next
  // step), whichever state the page is in.
  const primaryButtonCount = (html.match(/class="btn btn-primary"/g) ?? []).length;
  if (primaryButtonCount !== 1) {
    problems.push(`expected exactly one primary action (class="btn btn-primary"), found ${primaryButtonCount}`);
  }

  // "Open in Iris" exists only as a clearly labelled secondary line for
  // people who already have Iris Apps installed, and it is never itself
  // styled as the primary action.
  const openInIrisIndex = html.indexOf('data-action="open-in-iris"');
  if (openInIrisIndex === -1) {
    problems.push('no "Open in Iris" link found on the page');
  } else {
    const precedingText = html.slice(Math.max(0, openInIrisIndex - 120), openInIrisIndex);
    if (!/already have iris apps installed/i.test(precedingText)) {
      problems.push('"Open in Iris" is not clearly labelled as being for people who already have Iris Apps installed');
    }
    const tagStart = html.lastIndexOf("<a", openInIrisIndex);
    const tagEnd = html.indexOf(">", openInIrisIndex);
    const openInIrisTag = html.slice(tagStart, tagEnd);
    if (/btn-primary/.test(openInIrisTag)) {
      problems.push('"Open in Iris" is styled as the page\'s primary action');
    }
  }

  return problems;
}

async function realAppPageHTML(slug) {
  const { files } = await buildSite();
  return files.get(`iris/apps/${slug}/index.html`).toString("utf8");
}

test("Jess reading any app page today sees one honest, non-contradictory availability message, on every app, not just Kneecap", async () => {
  for (const slug of APP_SLUGS) {
    const html = await realAppPageHTML(slug);
    const problems = oracleJessReadsAppPage(html);
    assert.deepEqual(problems, [], `${slug}: ${problems.join("; ")}`);
    // The concrete, current-state facts: no Iris Apps distribution URL is
    // set yet, so the page must not show an Install button, must say so
    // plainly, and must not repeat the exact promise Jess was misled by.
    assert.doesNotMatch(html, /data-action="install-iris"/, `${slug}: no Install Iris button until a real distribution URL is set`);
    assert.match(html, /Iris Apps is not in the App Store yet, so there is nothing to download here today\./, `${slug}: honest "How to get it" sentence`);
    assert.doesNotMatch(html, /the fastest way to get it today/i, `${slug}: the exact promise Jess was misled by must not reappear`);
  }
});

test("when a real Iris Apps distribution URL is set, the same page switches to one real Install button and still reads clean", async () => {
  const { files, catalogRows, indexPage } = await buildSite();
  const { renderAppPageHTML } = await import("../site-pages.mjs");
  const categoriesById = new Map(SEED_CATEGORIES.map((category) => [category.id, category]));

  for (const slug of APP_SLUGS) {
    const appPage = JSON.parse(files.get(`api/iris/mobile/apps/${slug}.json`).toString("utf8"));
    const entry = indexPage.apps.find((app) => app.slug === slug);
    const categoryNames = entry.categoryIds.map((id) => categoriesById.get(id)?.name).filter(Boolean);

    const html = renderAppPageHTML({
      slug,
      name: entry.name,
      categoryNames,
      appPage,
      catalogRows,
      irisDistributionURL: "https://apps.apple.com/us/app/iris/id1234567890",
    });

    const problems = oracleJessReadsAppPage(html);
    assert.deepEqual(problems, [], `${slug} (with distribution URL): ${problems.join("; ")}`);
    assert.match(html, /data-action="install-iris" href="https:\/\/apps\.apple\.com\/us\/app\/iris\/id1234567890"/, `${slug}: real Install button`);
    assert.doesNotMatch(html, /data-install-route="unavailable"/, `${slug}: route must read as available`);
    assert.match(html, /Tap Install Iris below to add it\./, `${slug}: "How to get it" text agrees with the Install button`);
  }
});

// Mutation check for the tests above: reintroduces the exact real bug
// (howToGetItCopy ignoring whether Iris Apps is actually downloadable,
// always promising "the fastest way to get it today") in a disposable
// mutant copy of site-content.mjs, paired with pristine copies of
// site-pages.mjs, integration.mjs, and mobile-shell/contracts/index.js so
// the rest of the page renders exactly as it does today. Confirms the
// oracle reports the reintroduced contradiction as broken, and that the
// real source files were never touched. One mutated file is then restored
// from its pristine sha256-verified bytes, proving the restore path works.
test("mutation check: reintroducing the unconditional 'fastest way to get it today' promise is caught by the oracle above", async () => {
  const tmpRoot = await mkdtemp(path.join(tmpdir(), "iris-rc03-jess-mutation-"));
  try {
    const mutantWebsiteDir = path.join(tmpRoot, "mobile-shell", "website");
    const mutantContractsDir = path.join(tmpRoot, "mobile-shell", "contracts");
    await mkdir(mutantWebsiteDir, { recursive: true });
    await mkdir(mutantContractsDir, { recursive: true });
    await cp(path.join(REPO_ROOT, "mobile-shell/contracts/index.js"), path.join(mutantContractsDir, "index.js"));

    const pristinePaths = {
      "site-pages.mjs": path.join(WEBSITE_ROOT, "site-pages.mjs"),
      "integration.mjs": path.join(WEBSITE_ROOT, "integration.mjs"),
      "site-content.mjs": path.join(WEBSITE_ROOT, "site-content.mjs"),
    };
    const pristineHashesBefore = {};
    for (const [name, sourcePath] of Object.entries(pristinePaths)) {
      pristineHashesBefore[name] = createHash("sha256").update(await readFile(sourcePath)).digest("hex");
    }

    await cp(pristinePaths["site-pages.mjs"], path.join(mutantWebsiteDir, "site-pages.mjs"));
    await cp(pristinePaths["integration.mjs"], path.join(mutantWebsiteDir, "integration.mjs"));

    const pristineContentSource = await readFile(pristinePaths["site-content.mjs"], "utf8");
    const fnStart = pristineContentSource.indexOf("export function howToGetItCopy");
    const fnEnd = pristineContentSource.indexOf("\n}\n", fnStart) + 3;
    assert.ok(fnStart > 0 && fnEnd > fnStart, "site-content.mjs's shape changed; update this mutation's anchor");
    const mutatedContentSource = `${pristineContentSource.slice(0, fnStart)}`
      + "export function howToGetItCopy(name) {\n"
      + "  return `${name} comes built into Iris Apps, Publik's own collection of apps for iPhone. `\n"
      + '    + "See the button below for the fastest way to get it today.";\n'
      + "}\n"
      + pristineContentSource.slice(fnEnd);
    assert.notEqual(mutatedContentSource, pristineContentSource, "the mutation actually changed something");
    await writeFile(path.join(mutantWebsiteDir, "site-content.mjs"), mutatedContentSource);

    const mutant = await import(pathToFileURL(path.join(mutantWebsiteDir, "site-pages.mjs")).href);
    const mutantHTML = mutant.renderAppPageHTML({
      slug: "kneecap",
      name: "Kneecap",
      categoryNames: ["Video editing"],
      appPage: {
        description: "Kneecap is a video editor.",
        privacySummary: "Your clips stay on this phone.",
        permissions: [],
      },
      catalogRows: [{
        slug: "kneecap",
        name: "Kneecap",
        guideSlug: "kneecap",
        macBundleId: null,
        latestReleaseTag: null,
        mobileShell: {
          version: 1,
          platform: "ios",
          packageFormat: "iris.mobile-shell.package+json",
          downloadUrl: "https://publikhq.com/artifacts/kneecap.irisapp",
          mediaType: "application/json",
          byteCount: 1346428,
          packageSha256: `sha256:${"b".repeat(64)}`,
          appId: "publik.kneecap",
          projectId: "publik.kneecap.mobile",
          baseRevisionId: null,
          revisionId: `rev-sha256:${"c".repeat(64)}`,
          contentHash: `sha256:${"c".repeat(64)}`,
        },
      }],
      irisDistributionURL: null,
    });

    // The bug's own visible symptom, preserved so this mutant is faithful:
    // the unconditional promise, right above a route marked unavailable.
    assert.match(mutantHTML, /See the button below for the fastest way to get it today\./);
    assert.match(mutantHTML, /data-install-route="unavailable"/);

    const problems = oracleJessReadsAppPage(mutantHTML);
    assert.notDeepEqual(problems, [], "the pre-fix shape must be reported as broken, or this check proves nothing");
    assert.ok(
      problems.some((problem) => problem.includes('promises a download "today"')),
      `expected the "promises a download" problem, got: ${JSON.stringify(problems)}`,
    );

    for (const [name, sourcePath] of Object.entries(pristinePaths)) {
      const hashAfter = createHash("sha256").update(await readFile(sourcePath)).digest("hex");
      assert.equal(hashAfter, pristineHashesBefore[name], `${name}: the real source file was never touched by this mutation`);
    }

    // Restore demonstration: the one file this mutation actually edited
    // (in the disposable mutant tree, never the real source) can be
    // restored byte-for-byte from the pristine, hash-verified source.
    const restoredBytes = await readFile(pristinePaths["site-content.mjs"]);
    await writeFile(path.join(mutantWebsiteDir, "site-content.mjs"), restoredBytes);
    const restoredHash = createHash("sha256").update(await readFile(path.join(mutantWebsiteDir, "site-content.mjs"))).digest("hex");
    assert.equal(restoredHash, pristineHashesBefore["site-content.mjs"]);
  } finally {
    await rm(tmpRoot, { recursive: true, force: true });
  }
});
