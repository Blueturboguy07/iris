#!/usr/bin/env node
// Builds the job matrix: one job per (guide, platform, target) branch that
// carries steps. Unsupported pairs are listed in the inventory but not run.
//
//   node plan.cjs [--slugs all|a,b,c] [--platforms macos,windows] [--mobile true|false]
//                 [--base https://publikhq.com] [--out inventory.json]

"use strict";

const fs = require("node:fs");
const lib = require("./lib.cjs");

async function main() {
  const args = lib.parseArgs(process.argv.slice(2));
  const base = args.base ?? lib.DEFAULT_BASE;
  const wanted = (args.slugs ?? "all").trim();
  const slugFilter = wanted === "all" || wanted === "" ? null : new Set(wanted.split(",").map((s) => s.trim()).filter(Boolean));
  const platforms = new Set((args.platforms ?? "macos,windows").split(",").map((s) => s.trim()).filter(Boolean));
  const mobile = String(args.mobile ?? "true") !== "false";

  const apps = await lib.fetchCatalog(base);
  const slugs = [...new Set(apps.map((a) => a.guideSlug).filter(Boolean))].filter((s) => !slugFilter || slugFilter.has(s));
  const missing = slugFilter ? [...slugFilter].filter((s) => !slugs.includes(s)) : [];
  const include = [];
  const inventory = { base, plannedAt: lib.nowIso(), guides: [], skipped: [], missing };

  for (const slug of slugs) {
    let guide;
    try {
      guide = await lib.fetchGuide(base, slug);
    } catch (error) {
      inventory.skipped.push({ slug, reason: `fetch failed: ${error.message}` });
      continue;
    }
    const record = { slug, version: guide.version, status: guide.status, outputType: guide.outputType, branches: [] };
    for (const branch of guide.branches ?? []) {
      const key = lib.branchKey(branch);
      const target = branch.target ?? "desktop";
      const commands = lib.allSteps(branch).filter((s) => s.command).length;
      const b = { key, unsupported: Boolean(branch.unsupported), steps: (branch.steps ?? []).length, commands };
      record.branches.push(b);
      if (branch.unsupported) continue;
      if (!platforms.has(branch.platform)) continue;
      if (!mobile && branch.target) continue;
      include.push({
        slug,
        platform: branch.platform,
        target,
        runner: branch.platform === "macos" ? "macos-latest" : "windows-latest",
        label: `${slug} ${key}`,
      });
    }
    inventory.guides.push(record);
  }

  const matrix = { include };
  if (args.out) fs.writeFileSync(args.out, JSON.stringify({ ...inventory, matrix }, null, 2));
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `matrix=${JSON.stringify(matrix)}\n`);
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `count=${include.length}\n`);
  }
  console.log(JSON.stringify(matrix));
  console.error(`[guide-ci] planned ${include.length} jobs across ${inventory.guides.length} guides` + (missing.length ? `; unknown slugs: ${missing.join(", ")}` : ""));
}

main().catch((error) => {
  console.error(`[guide-ci] plan failed: ${error.stack ?? error}`);
  process.exit(1);
});
