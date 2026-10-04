// Guardrail (CLAUDE.md, all projects): "NEVER use an em dash anywhere (chat,
// code, comments, commits, docs)." Checks every file this unit (RC-03)
// wrote or owns, byte-for-byte, not just the prose sections.

import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEBSITE_ROOT = path.resolve(HERE, "..");
const RC03_DOCS_ROOT = path.resolve(WEBSITE_ROOT, "../../docs/plans/20260928-all-routes/round5/rc03-website");
const EM_DASH = "\u2014";

async function listFilesRecursive(root, { skip = new Set() } = {}) {
  const out = [];
  async function walk(dir) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (skip.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) await walk(full);
      else out.push(full);
    }
  }
  await walk(root);
  return out;
}

test("no em dash anywhere in this unit's own generator, library, and test source files", async () => {
  const sourceFiles = await listFilesRecursive(WEBSITE_ROOT, { skip: new Set(["node_modules", "seed"]) });
  const checked = sourceFiles.filter((file) => /\.(mjs|md|py|css)$/.test(file) && !file.endsWith("seed-catalog-v2.mjs"));
  assert.ok(checked.length > 5, "sanity: this should find this unit's own files");
  for (const file of checked) {
    const text = await readFile(file, "utf8");
    assert.ok(!text.includes(EM_DASH), `em dash found in ${path.relative(WEBSITE_ROOT, file)}`);
  }
});

test("no em dash anywhere in the built website output (site/) or this unit's docs (round5/rc03-website/)", async () => {
  const files = await listFilesRecursive(RC03_DOCS_ROOT);
  const checked = files.filter((file) => !/\.(json|png)$/.test(file));
  assert.ok(checked.length > 5, "sanity: this should find generated pages");
  for (const file of checked) {
    const text = await readFile(file, "utf8");
    assert.ok(!text.includes(EM_DASH), `em dash found in ${path.relative(RC03_DOCS_ROOT, file)}`);
  }
});
