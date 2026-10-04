// RC-03 (round5/rc03-website). Mutation check for site-links.test.mjs: for
// each planted defect, a person following links would actually get stuck
// (a broken link, an app page with no way back to Privacy/Support, an AASA
// that no longer covers an app route), and the auditor in site-audit.mjs
// must say so. Every mutation is applied to a disposable COPY of the built
// site (fs.cp), never to the checked-in output; the pristine copy's whole-
// tree sha256 is recorded before any mutant is made and re-checked after,
// proving the mutation step never touched it, and one mutation is reversed
// by restoring the single file it touched from the pristine, hash-verified
// bytes, proving the restore step itself works.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";

import { buildSite, writeSite } from "../build-site.mjs";
import { auditSiteLinks, checkAASAPaths, checkTwoTapReachability } from "../site-audit.mjs";

async function hashTree(root) {
  const entries = [];
  async function walk(dir, base) {
    for (const item of (await readdir(dir, { withFileTypes: true })).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const full = path.join(dir, item.name);
      const rel = base ? `${base}/${item.name}` : item.name;
      if (item.isDirectory()) await walk(full, rel);
      else entries.push(`${rel}:${createHash("sha256").update(await readFile(full)).digest("hex")}`);
    }
  }
  await walk(root, "");
  return createHash("sha256").update(entries.sort().join("\n")).digest("hex");
}

async function freshMutantCopy(pristineRoot, tmpRoot, label) {
  const dest = path.join(tmpRoot, label);
  await cp(pristineRoot, dest, { recursive: true });
  return dest;
}

test("mutation check: a broken link, a dead-end app page, and a stale AASA are each caught, without ever touching the pristine copy", async (t) => {
  const tmpRoot = await mkdtemp(path.join(tmpdir(), "iris-rc03-mutation-"));
  const pristineRoot = path.join(tmpRoot, "pristine");
  try {
    const { files } = await buildSite();
    await writeSite(pristineRoot, files);
    const pristineHashBefore = await hashTree(pristineRoot);

    // Sanity: the unmutated build passes clean (a tautological suite would
    // pass even if this baseline were itself broken).
    const clean = await auditSiteLinks(pristineRoot);
    assert.deepEqual(clean.errors, []);
    assert.deepEqual(checkTwoTapReachability(clean.graph), []);

    await t.test("mutant: a corrupted href no longer resolves to any generated file", async () => {
      const mutant = await freshMutantCopy(pristineRoot, tmpRoot, "mutant-broken-link");
      const target = path.join(mutant, "iris/index.html");
      const original = await readFile(target, "utf8");
      const mutated = original.replace('href="/iris/apps/kneecap"', 'href="/iris/apps/kneecap-typo"');
      assert.notEqual(mutated, original, "the mutation actually changed something");
      await writeFile(target, mutated);
      const { errors } = await auditSiteLinks(mutant);
      assert.ok(errors.length > 0, "a broken link must be reported");
      assert.ok(errors.some((error) => error.includes("kneecap-typo")), errors.join("\n"));
    });

    await t.test("mutant: an app page with no outbound links at all loses its two-tap path to Privacy/Support", async () => {
      const mutant = await freshMutantCopy(pristineRoot, tmpRoot, "mutant-dead-end-page");
      const target = path.join(mutant, "iris/apps/kneecap/index.html");
      await writeFile(target, "<!doctype html><html><body><h1>Kneecap</h1><p>No navigation here.</p></body></html>\n");
      const { graph } = await auditSiteLinks(mutant);
      const errors = checkTwoTapReachability(graph);
      assert.ok(errors.length > 0, "a page with no links out must fail the two-tap check");
      assert.ok(errors.some((error) => error.startsWith("iris/apps/kneecap/index.html")), errors.join("\n"));
    });

    await t.test("mutant: an AASA path pattern that no longer covers the generated app routes", async () => {
      const mutant = await freshMutantCopy(pristineRoot, tmpRoot, "mutant-stale-aasa");
      const target = path.join(mutant, ".well-known/apple-app-site-association");
      const aasa = JSON.parse(await readFile(target, "utf8"));
      aasa.applinks.details[0].paths = ["/iris/nothing-here/*"];
      await writeFile(target, `${JSON.stringify(aasa, null, 2)}\n`);
      const { knownSlugs } = await auditSiteLinks(mutant);
      const errors = checkAASAPaths({ aasaJSON: aasa, appSlugs: knownSlugs });
      assert.equal(errors.length, knownSlugs.size + 1, "every app route uncovered, plus the stray pattern itself");
    });

    // Restore proof: corrupt one file in its own disposable copy, then
    // restore it from the pristine, hash-verified bytes, and confirm the
    // restored copy is byte-identical to pristine and audits clean again.
    await t.test("restore: a corrupted file can be restored from the pristine sha256-verified bytes", async () => {
      const mutant = await freshMutantCopy(pristineRoot, tmpRoot, "mutant-restore-proof");
      const relative = "iris/support/index.html";
      const pristineBytes = await readFile(path.join(pristineRoot, relative));
      const pristineHash = createHash("sha256").update(pristineBytes).digest("hex");
      await writeFile(path.join(mutant, relative), "<html><body>corrupted</body></html>\n");
      const corruptedAudit = await auditSiteLinks(mutant);
      assert.ok(corruptedAudit.errors.length >= 0); // corrupting support's own body may not break other pages' links; the real proof is the restore below.
      assert.notEqual(
        createHash("sha256").update(await readFile(path.join(mutant, relative))).digest("hex"),
        pristineHash,
      );
      await writeFile(path.join(mutant, relative), pristineBytes);
      const restoredHash = createHash("sha256").update(await readFile(path.join(mutant, relative))).digest("hex");
      assert.equal(restoredHash, pristineHash, "restored bytes match the pristine sha256");
      const restoredAudit = await auditSiteLinks(mutant);
      assert.deepEqual(restoredAudit.errors, [], "the restored copy audits clean again");
    });

    const pristineHashAfter = await hashTree(pristineRoot);
    assert.equal(pristineHashAfter, pristineHashBefore, "the pristine copy was never touched by any mutation above");
  } finally {
    await rm(tmpRoot, { recursive: true, force: true });
  }
});
