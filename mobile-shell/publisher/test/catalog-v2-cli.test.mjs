import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";

import { validateCatalogIndexV2 } from "../../contracts/index.js";
import { generateCatalog } from "../../tools/catalog-fixture-generator/src/generate.mjs";

const run = promisify(execFile);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const CLI = path.join(HERE, "../cli.mjs");

async function writeReviewedFixture(dir, appCount) {
  const catalog = generateCatalog({ seed: "publisher-cli-catalog-emit-test", appCount });
  const indexEntries = catalog.indexPages.flatMap((p) => p.apps);
  const appsDir = path.join(dir, "apps-in");
  await mkdir(appsDir, { recursive: true });
  for (const entry of indexEntries) {
    const reviewed = { ...entry, ...catalog.appPages.get(entry.slug) };
    await writeFile(path.join(appsDir, `${entry.slug}.json`), JSON.stringify(reviewed));
  }
  const categoriesPath = path.join(dir, "categories.json");
  await writeFile(categoriesPath, JSON.stringify(catalog.categories));
  return { appsDir, categoriesPath };
}

test("catalog-emit CLI writes a valid catalog v2 publish from reviewed descriptor files", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-cli-"));
  const { appsDir, categoriesPath } = await writeReviewedFixture(tmp, 6);
  const out = path.join(tmp, "catalog-out");

  const { stdout } = await run("node", [
    CLI, "catalog-emit",
    "--apps-dir", appsDir,
    "--categories", categoriesPath,
    "--generated-at", "2026-09-28T00:00:00.000Z",
    "--out", out,
  ]);
  const result = JSON.parse(stdout);
  assert.equal(result.status, "emitted");
  assert.equal(result.appCount, 6);

  const index = JSON.parse(await readFile(path.join(out, "index.json"), "utf8"));
  assert.equal(validateCatalogIndexV2(index).ok, true);
  assert.equal(index.apps.length, 6);
});

test("catalog-emit CLI refuses to overwrite an existing publish without --overwrite", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-cli-"));
  const { appsDir, categoriesPath } = await writeReviewedFixture(tmp, 2);
  const out = path.join(tmp, "catalog-out");
  const argv = [
    CLI, "catalog-emit",
    "--apps-dir", appsDir,
    "--categories", categoriesPath,
    "--generated-at", "2026-09-28T00:00:00.000Z",
    "--out", out,
  ];
  await run("node", argv);
  await assert.rejects(() => run("node", argv));
  await assert.doesNotReject(() => run("node", [...argv, "--overwrite"]));
});

test("catalog-emit CLI only deletes a removed app's page when asked with --prune-stale", async () => {
  const tmp = await mkdtemp(path.join(os.tmpdir(), "catalog-emit-cli-"));
  const { appsDir, categoriesPath } = await writeReviewedFixture(tmp, 4);
  const out = path.join(tmp, "catalog-out");
  const base = [CLI, "catalog-emit", "--apps-dir", appsDir, "--categories", categoriesPath, "--out", out];
  await run("node", [...base, "--generated-at", "2026-09-28T00:00:00.000Z"]);

  const removed = (await readdir(appsDir)).sort()[0];
  await unlink(path.join(appsDir, removed));
  const next = [...base, "--generated-at", "2026-09-29T00:00:00.000Z", "--overwrite"];
  await assert.rejects(() => run("node", next), (error) => error.stderr.includes(`apps/${removed}`));
  assert.ok((await readdir(path.join(out, "apps"))).includes(removed));

  const { stdout } = await run("node", [...next, "--prune-stale"]);
  const result = JSON.parse(stdout);
  assert.deepEqual(result.removedStaleFiles, [`apps/${removed}`]);
  assert.equal(result.appCount, 3);
  assert.equal((await readdir(path.join(out, "apps"))).includes(removed), false);
});
