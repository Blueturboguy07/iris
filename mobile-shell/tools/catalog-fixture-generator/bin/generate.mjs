#!/usr/bin/env node
// Writes deterministic catalog v2 fixture sets to disk.
//
// Usage: node bin/generate.mjs [--out <dir>] [--seed <text>] [--counts 3,100,1000] [--with-packages 3]
//
// Default output: mobile-shell/native/Tests/Fixtures/catalog-v2/<count>/
// (one directory per requested app count), so M2, M5, M6 and D10 read the
// exact same bytes this generator produces from the documented seed.
//
// Files are written in place through the publisher's writeCatalogV2, so a
// fixture set is exactly what `publisher/cli.mjs catalog-emit` would
// publish. Nothing is deleted: if a previous run left catalog files this run
// does not produce, the write stops and lists them.

import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { writeCatalogV2 } from "../../../publisher/catalog-v2.mjs";
import { generateCatalog, generateCatalogWithPackages } from "../src/generate.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_OUT = path.resolve(HERE, "../../../native/Tests/Fixtures/catalog-v2");
export const DEFAULT_SEED = "iris-catalog-v2-fixtures-2026-09-28";
export const DEFAULT_COUNTS = [3, 100, 1000];
export const DEFAULT_PACKAGE_COUNTS = [3];

function parseCounts(text) {
  return text.split(",").filter(Boolean).map((n) => {
    const value = Number.parseInt(n, 10);
    if (!Number.isSafeInteger(value) || value < 0 || String(value) !== n.trim()) throw new Error(`invalid count: ${n}`);
    return value;
  });
}

function parseArgs(argv) {
  const args = { out: DEFAULT_OUT, seed: DEFAULT_SEED, counts: DEFAULT_COUNTS, packageCounts: DEFAULT_PACKAGE_COUNTS };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--out") args.out = path.resolve(argv[++i]);
    else if (arg === "--seed") args.seed = argv[++i];
    else if (arg === "--counts") args.counts = parseCounts(argv[++i]);
    else if (arg === "--with-packages") args.packageCounts = parseCounts(argv[++i]);
    else throw new Error(`unknown argument: ${arg}`);
  }
  return args;
}

/**
 * Writes one generated catalog under outDir/<appCount>/: the catalog files
 * (index pages, categories.json, apps/<slug>.json, manifest.json with the
 * seed) and, when the catalog carries them, packages/<slug>.irisapp and
 * icons/<slug>.png.
 */
export async function writeFixtureSet(outDir, catalog) {
  const root = path.join(outDir, String(catalog.appCount));
  await writeCatalogV2(root, catalog, {
    overwrite: true,
    pruneStale: false,
    extraManifest: {
      seed: catalog.seed,
      generator: "mobile-shell/tools/catalog-fixture-generator",
      installablePackages: Boolean(catalog.packages),
    },
  });
  if (catalog.packages) {
    await mkdir(path.join(root, "packages"), { recursive: true });
    for (const [slug, bytes] of catalog.packages) await writeFile(path.join(root, "packages", `${slug}.irisapp`), bytes);
  }
  if (catalog.icons) {
    await mkdir(path.join(root, "icons"), { recursive: true });
    for (const [slug, bytes] of catalog.icons) await writeFile(path.join(root, "icons", `${slug}.png`), bytes);
  }
  return root;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  for (const appCount of args.counts) {
    const catalog = args.packageCounts.includes(appCount)
      ? await generateCatalogWithPackages({ seed: args.seed, appCount })
      : generateCatalog({ seed: args.seed, appCount });
    const root = await writeFixtureSet(args.out, catalog);
    console.log(`wrote ${catalog.appCount}-app catalog (seed "${args.seed}", ${catalog.catalogEmitHash}) to ${root}`);
  }
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1]);
if (isMain) {
  main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
  });
}
