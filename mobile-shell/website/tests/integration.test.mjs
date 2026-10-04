import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";

import {
  canonicalAppURL,
  fallbackInstallURL,
  generateAASA,
  parseAppIntentURL,
  renderAASAJSON,
  renderCatalogHandoffHTML,
  resolveCatalogHandoff,
  validateAppleDistributionURL,
  validateApplicationIdentifier,
} from "../integration.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEBSITE_ROOT = path.resolve(HERE, "..");
const REPO_ROOT = path.resolve(WEBSITE_ROOT, "../..");

const CONTENT_HASH = `sha256:${"a".repeat(64)}`;
const AVAILABLE_ROW = Object.freeze({
  slug: "lunara",
  name: "Lunara",
  guideSlug: "lunara",
  macBundleId: null,
  latestReleaseTag: null,
  mobileShell: Object.freeze({
    version: 1,
    platform: "ios",
    packageFormat: "iris.mobile-shell.package+json",
    downloadUrl: "https://publikhq.com/artifacts/lunara.irisapp",
    mediaType: "application/json",
    byteCount: 1346428,
    packageSha256: `sha256:${"b".repeat(64)}`,
    appId: "publik.lunara",
    projectId: "publik.lunara.mobile",
    baseRevisionId: null,
    revisionId: `rev-sha256:${"a".repeat(64)}`,
    contentHash: CONTENT_HASH,
  }),
});

test("canonical and fallback app intents are one strict shared contract", () => {
  assert.equal(canonicalAppURL("lunara"), "https://publikhq.com/iris/apps/lunara");
  assert.equal(fallbackInstallURL("lunara"), "iris-apps://install/lunara");
  assert.deepEqual(parseAppIntentURL("https://publikhq.com/iris/apps/lunara"), {
    kind: "canonical",
    slug: "lunara",
    url: "https://publikhq.com/iris/apps/lunara",
  });
  assert.deepEqual(parseAppIntentURL("iris-apps://install/lunara"), {
    kind: "fallback",
    slug: "lunara",
    url: "iris-apps://install/lunara",
  });
  for (const invalid of [
    "https://publikhq.com/iris/apps/lunara/",
    "https://publikhq.com/iris/apps/lunara?package=https://evil.example/app",
    "https://example.com/iris/apps/lunara",
    "iris-apps://install/lunara?approve=1",
    "iris-apps://other/lunara",
    "iris-apps://install/../lunara",
  ]) {
    assert.throws(() => parseAppIntentURL(invalid), TypeError, invalid);
  }
});

test("handoff availability comes from the selected catalog row's valid mobileShell binding", () => {
  const available = resolveCatalogHandoff([AVAILABLE_ROW], "lunara");
  assert.equal(available.available, true);
  assert.equal(available.fallbackURL, "iris-apps://install/lunara");
  assert.equal(available.mobileShell.appId, "publik.lunara");

  const unavailable = resolveCatalogHandoff([{ ...AVAILABLE_ROW, mobileShell: null }], "lunara");
  assert.equal(unavailable.available, false);
  assert.equal(unavailable.fallbackURL, null);

  const malformed = structuredClone(AVAILABLE_ROW);
  malformed.mobileShell.downloadUrl = "https://example.com/lunara.irisapp";
  assert.throws(() => resolveCatalogHandoff([malformed], "lunara"), /direct https:\/\/publikhq\.com/);
  assert.throws(() => resolveCatalogHandoff([AVAILABLE_ROW], "kneecap"), /absent from the catalog/);
});

test("handoff HTML is explicit, preserves the selected app, and does not invent an Iris install route", () => {
  const noDistribution = renderCatalogHandoffHTML({ catalogRows: [AVAILABLE_ROW], selectedSlug: "lunara" });
  assert.match(noDistribution, /data-action="open-in-iris" href="iris-apps:\/\/install\/lunara"/);
  assert.match(noDistribution, /data-selected-app-link href="https:\/\/publikhq\.com\/iris\/apps\/lunara"/);
  assert.match(noDistribution, /data-install-route="unavailable"/);
  assert.doesNotMatch(noDistribution, /data-action="install-iris"/);
  assert.doesNotMatch(noDistribution, /apps\.apple\.com|testflight\.apple\.com/);

  const withDistribution = renderCatalogHandoffHTML({
    catalogRows: [AVAILABLE_ROW],
    selectedSlug: "lunara",
    irisDistributionURL: "https://testflight.apple.com/join/Ab12Cd34",
  });
  assert.match(withDistribution, /data-action="install-iris" href="https:\/\/testflight\.apple\.com\/join\/Ab12Cd34"/);
  assert.match(withDistribution, /data-selected-app-preserved/);
  assert.match(withDistribution, /return to <a href="https:\/\/publikhq\.com\/iris\/apps\/lunara">this Lunara page<\/a>/);
});

test("an unavailable app stays unavailable even when an Iris distribution URL is supplied", () => {
  const html = renderCatalogHandoffHTML({
    catalogRows: [{ ...AVAILABLE_ROW, name: "Not Ready", mobileShell: undefined }],
    selectedSlug: "lunara",
    irisDistributionURL: "https://apps.apple.com/us/app/iris/id1234567890",
  });
  assert.match(html, /data-iris-available="false"/);
  assert.match(html, /not available in Iris yet/);
  assert.doesNotMatch(html, /data-action="open-in-iris"/);
  assert.doesNotMatch(html, /data-action="install-iris"/);
});

test("catalog display names and supplied distribution URLs are escaped before HTML output", () => {
  const hostileName = `Lunara <img src=x onerror="alert('x')"> & Friends`;
  const html = renderCatalogHandoffHTML({
    catalogRows: [{ ...AVAILABLE_ROW, name: hostileName }],
    selectedSlug: "lunara",
    irisDistributionURL: "https://apps.apple.com/us/app/Iris&Friends/id1234567890",
  });
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /Lunara &lt;img src=x onerror=&quot;alert\(&#39;x&#39;\)&quot;&gt; &amp; Friends/);
  assert.match(html, /href="https:\/\/apps\.apple\.com\/us\/app\/Iris&amp;Friends\/id1234567890"/);
});

test("only caller-supplied App Store or TestFlight URLs can produce the Install Iris control", () => {
  assert.equal(validateAppleDistributionURL(null), null);
  assert.equal(
    validateAppleDistributionURL("https://apps.apple.com/us/app/iris/id1234567890"),
    "https://apps.apple.com/us/app/iris/id1234567890",
  );
  assert.equal(
    validateAppleDistributionURL("https://testflight.apple.com/join/Ab12Cd34"),
    "https://testflight.apple.com/join/Ab12Cd34",
  );
  for (const invalid of [
    "https://publikhq.com/download/iris",
    "https://apps.apple.com.example.com/us/app/iris/id1234567890",
    "http://apps.apple.com/us/app/iris/id1234567890",
    "https://testflight.apple.com/join/Ab12Cd34?redirect=evil",
    "https://testflight.apple.com/join/Ab12Cd34#fragment",
  ]) {
    assert.throws(() => validateAppleDistributionURL(invalid), TypeError, invalid);
  }
});

test("AASA generation requires the exact supplied application identifier and never guesses one", () => {
  const applicationIdentifier = "R5R3ZS54LV.com.publikhq.iris.mobileshell";
  assert.equal(validateApplicationIdentifier(applicationIdentifier), applicationIdentifier);
  const aasa = generateAASA({ applicationIdentifier });
  assert.deepEqual(aasa, {
    applinks: {
      apps: [],
      details: [{ appID: applicationIdentifier, paths: ["/iris/apps/*"] }],
    },
  });
  assert.match(renderAASAJSON({ applicationIdentifier }), /"appID": "R5R3ZS54LV\.com\.publikhq\.iris\.mobileshell"/);
  assert.throws(() => generateAASA(), /applicationIdentifier must be supplied/);
  assert.throws(() => generateAASA({ applicationIdentifier: "com.publikhq.iris.mobileshell" }), /exact Apple application identifier/);
  assert.throws(() => generateAASA({ applicationIdentifier: "TEAMID1234.*" }), /exact Apple application identifier/);
});

// Regression test for a real blind test: on a page where Iris Apps has no
// App Store or TestFlight link yet, the only control was a custom-scheme
// "Open in Iris" link, which gives no feedback at all when Iris Apps is
// not already installed (a browser cannot detect or report a failed
// custom-scheme handoff). A tester reported tapping it and "watching
// nothing happen", with no other way forward. The fix always offers one
// real, working next step alongside it: a mailto: link, which a phone
// opens immediately regardless of whether Iris Apps is installed.
function oracleHasWorkingNextStep(html) {
  const match = html.match(/data-action="notify-me" href="([^"]+)"/);
  if (!match) return false;
  const href = match[1].replaceAll("&amp;", "&");
  let url;
  try {
    url = new URL(href);
  } catch {
    return false;
  }
  return url.protocol === "mailto:" && url.pathname.includes("@");
}

test("when Iris Apps has no App Store or TestFlight link yet, the page still offers a real working next step", () => {
  const html = renderCatalogHandoffHTML({ catalogRows: [AVAILABLE_ROW], selectedSlug: "lunara" });
  assert.equal(oracleHasWorkingNextStep(html), true, html);
});

// Mutation check for the test above: builds a disposable copy of
// integration.mjs (plus its one dependency, mobile-shell/contracts) with
// the notify-me action removed, exactly reproducing the shape the blind
// test actually hit (only the silent custom-scheme link and a static "no
// route" paragraph), then confirms oracleHasWorkingNextStep correctly
// reports it as broken. Never touches the real source files; the mutant
// lives entirely under a temp directory, whose sha256 against the
// pristine source is asserted to differ, proving a real edit happened.
test("mutation check: removing the working next step is caught by the oracle above", async () => {
  const tmpRoot = await mkdtemp(path.join(tmpdir(), "iris-rc03-handoff-mutation-"));
  try {
    const mutantWebsiteDir = path.join(tmpRoot, "mobile-shell", "website");
    const mutantContractsDir = path.join(tmpRoot, "mobile-shell", "contracts");
    await mkdir(mutantWebsiteDir, { recursive: true });
    await mkdir(mutantContractsDir, { recursive: true });
    await cp(path.join(REPO_ROOT, "mobile-shell/contracts/index.js"), path.join(mutantContractsDir, "index.js"));
    await cp(path.join(WEBSITE_ROOT, "site-content.mjs"), path.join(mutantWebsiteDir, "site-content.mjs"));

    const pristineSource = await readFile(path.join(WEBSITE_ROOT, "integration.mjs"), "utf8");
    const primaryActionStart = pristineSource.indexOf("const primaryActionHTML = distributionURL");
    const primaryActionEnd = pristineSource.indexOf("\n\n", primaryActionStart);
    assert.ok(primaryActionStart > 0 && primaryActionEnd > primaryActionStart, "integration.mjs's shape changed; update this mutation's anchor");
    const mutatedSource = `${pristineSource.slice(0, primaryActionStart)}`
      + "const primaryActionHTML = distributionURL\n"
      + '    ? `  <a class="btn btn-primary" data-action="install-iris" href="${htmlEscape(distributionURL)}">Install Iris</a>\\n`\n'
      + '      + `  <p class="hint" data-selected-app-preserved>After installing Iris, return to <a href="${canonicalURL}">this ${name} page</a> to open the same app.</p>\\n`\n'
      + '    : \'  <p data-install-route="unavailable">Iris does not have a published App Store or TestFlight installation route on this page yet.</p>\\n\';'
      + pristineSource.slice(primaryActionEnd);
    assert.notEqual(mutatedSource, pristineSource, "the mutation actually changed something");
    await writeFile(path.join(mutantWebsiteDir, "integration.mjs"), mutatedSource);

    const pristineHash = createHash("sha256").update(await readFile(path.join(WEBSITE_ROOT, "integration.mjs"))).digest("hex");

    const mutant = await import(pathToFileURL(path.join(mutantWebsiteDir, "integration.mjs")).href);
    const mutantHTML = mutant.renderCatalogHandoffHTML({ catalogRows: [AVAILABLE_ROW], selectedSlug: "lunara" });
    assert.equal(oracleHasWorkingNextStep(mutantHTML), false, "the pre-fix shape must be reported as having no working next step, or this check proves nothing");
    // The bug's own visible symptom, preserved so this mutant is faithful.
    assert.match(mutantHTML, /Iris does not have a published App Store or TestFlight installation route on this page yet\./);

    const pristineHashAfter = createHash("sha256").update(await readFile(path.join(WEBSITE_ROOT, "integration.mjs"))).digest("hex");
    assert.equal(pristineHashAfter, pristineHash, "the real source file was never touched by this mutation");
  } finally {
    await rm(tmpRoot, { recursive: true, force: true });
  }
});
