#!/usr/bin/env node
/**
 * Runs one module's shipping macOS implementation and the core over the same
 * corpus and refuses to agree they match unless every case is identical.
 *
 * Exits non-zero on any divergence, naming the case and both answers, so this
 * is usable as a CI gate and as the thing a person runs before switching a
 * module over.
 */
import { execFileSync } from "node:child_process";
import { readFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const moduleName = process.argv[2];
if (!moduleName) {
  console.error("usage: node parity/run.mjs <module>   e.g. break-signature");
  process.exit(2);
}

// Each module names the core export it is comparing.
const EXPORT_UNDER_TEST = { "break-signature": "normalizeBreakMessage" };
const exportName = EXPORT_UNDER_TEST[moduleName];
if (!exportName) {
  console.error(`no parity mapping for "${moduleName}" — add one to EXPORT_UNDER_TEST`);
  process.exit(2);
}

const corpus = JSON.parse(readFileSync(join(here, "corpus.json"), "utf8"));

// macOS side: compile the verbatim reference and run it over the corpus.
const work = mkdtempSync(join(tmpdir(), "iris-parity-"));
try {
  execFileSync("swiftc", ["-O", join(here, `${moduleName}.swift`), "-o", join(work, "ref")], {
    stdio: "pipe",
  });
} catch (error) {
  console.error(`could not compile the macOS reference for ${moduleName}:`);
  console.error(String(error.stderr ?? error));
  process.exit(1);
}
execFileSync(join(work, "ref"), { cwd: here, stdio: "pipe" });
const shipping = JSON.parse(readFileSync(join(here, "swift-out.json"), "utf8"));

// Core side.
const core = require(join(here, "..", "dist", "index.js"));
const produced = corpus.map((input) => core[exportName](input));

const divergent = [];
for (let index = 0; index < corpus.length; index += 1) {
  if (shipping[index] !== produced[index]) {
    divergent.push({ index, input: corpus[index], shipping: shipping[index], core: produced[index] });
  }
}

console.log(`${moduleName}: ${corpus.length} cases, ${divergent.length} divergent`);
for (const d of divergent) {
  console.log(`\n  [${d.index}] input:    ${JSON.stringify(d.input)}`);
  console.log(`       shipping: ${JSON.stringify(d.shipping)}`);
  console.log(`       core:     ${JSON.stringify(d.core)}`);
}

if (divergent.length > 0) {
  console.error(
    `\nDIVERGENT — the core does not match the shipping macOS implementation.` +
      `\nFix the core. Do NOT widen the corpus to make this pass.`
  );
  process.exit(1);
}
console.log("\nIDENTICAL — this module is safe for macOS to consume from the core.");
