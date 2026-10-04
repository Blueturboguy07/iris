// RC-03 (round5/rc03-website). A person following links: every href/src on
// every generated page must land somewhere real (a file this build wrote,
// or one of the handful of allowed external destinations: mailto:, the
// iris-apps:// open fallback, or the bare publikhq.com marketing root),
// Privacy and Support must be within two taps of any app page, and the
// AASA universal-link paths must agree with the generated app routes.
//
// This suite builds into a scratch directory (never the checked-in
// round5/rc03-website/site copy) so it can also run against mutated
// copies without ever touching real generator output.

import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { buildSite, writeSite } from "../build-site.mjs";
import { aasaPathMatches, auditSiteLinks, checkAASAPaths, checkTwoTapReachability } from "../site-audit.mjs";

async function builtScratchSite() {
  const dir = await mkdtemp(path.join(tmpdir(), "iris-rc03-site-"));
  const { files } = await buildSite();
  await writeSite(dir, files);
  return dir;
}

test("every link on every generated page resolves to a generated file or an allowed external URL", async () => {
  const dir = await builtScratchSite();
  try {
    const { errors } = await auditSiteLinks(dir);
    assert.deepEqual(errors, []);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("Privacy and Support are reachable within two taps from every app page", async () => {
  const dir = await builtScratchSite();
  try {
    const { graph } = await auditSiteLinks(dir);
    const appPages = [...graph.keys()].filter((node) => /^iris\/apps\/[^/]+\/index\.html$/.test(node));
    assert.equal(appPages.length, 4, "four published apps");
    const errors = checkTwoTapReachability(graph);
    assert.deepEqual(errors, []);
    // Concretely: every app page links directly (one tap) to both, via the
    // shared header nav.
    for (const node of appPages) {
      assert.ok(graph.get(node).has("iris/privacy/index.html"), `${node} -> privacy`);
      assert.ok(graph.get(node).has("iris/support/index.html"), `${node} -> support`);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the AASA universal-link paths match the generated app routes, in both directions", async () => {
  const dir = await builtScratchSite();
  try {
    const { knownSlugs } = await auditSiteLinks(dir);
    const aasaJSON = JSON.parse(await readFile(path.join(dir, ".well-known/apple-app-site-association"), "utf8"));
    const errors = checkAASAPaths({ aasaJSON, appSlugs: knownSlugs });
    assert.deepEqual(errors, []);
    assert.deepEqual(knownSlugs, new Set(["freeharmony", "kneecap", "lunara", "nut-ai"]));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("aasaPathMatches: a trailing * matches any route sharing that prefix, and nothing else", () => {
  assert.equal(aasaPathMatches("/iris/apps/*", "/iris/apps/kneecap"), true);
  assert.equal(aasaPathMatches("/iris/apps/*", "/iris/apps/"), true);
  assert.equal(aasaPathMatches("/iris/apps/*", "/iris/privacy"), false);
  assert.equal(aasaPathMatches("/iris/apps/kneecap", "/iris/apps/kneecap"), true);
  assert.equal(aasaPathMatches("/iris/apps/kneecap", "/iris/apps/nut-ai"), false);
});
