#!/usr/bin/env node
import { constants as fsConstants } from "node:fs";
import { lstat, mkdir, open, readFile, readdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  APP_STORE_METADATA_KIND,
  APP_STORE_METADATA_VERSION,
  FIRST_SHELL_VERSION_ACCEPTING_CHANGES,
} from "../contracts/index.js";
import {
  LUNARA_MINIMUM_CORE_CAPABILITIES,
  LUNARA_REVIEWED_SOURCE,
  approvePublisherBuild,
  assertLunaraPreparation,
  preparePublisherBuild,
} from "./index.mjs";
import { emitCatalogV2, writeCatalogV2 } from "./catalog-v2.mjs";

const MAX_PREPARATION_BYTES = 1024 * 1024;

// RC-14: every `approve` call must attest it was checked against the
// current mobile-shell/publisher/APP_POLICY.md checklist. Resolved next to
// this file, not the caller's cwd, so the gate cannot be pointed at a
// different (possibly stale) copy of the policy.
const APP_POLICY_PATH = new URL("./APP_POLICY.md", import.meta.url);
const POLICY_VERSION_PATTERN = /^Policy version:\s*(\S+)\s*$/m;

async function currentAppPolicyVersion() {
  let text;
  try {
    text = await readFile(APP_POLICY_PATH, "utf8");
  } catch (error) {
    throw new TypeError(`could not read mobile-shell/publisher/APP_POLICY.md: ${error?.message ?? error}`);
  }
  const match = text.match(POLICY_VERSION_PATTERN);
  if (!match) throw new TypeError("mobile-shell/publisher/APP_POLICY.md is missing its \"Policy version:\" line");
  return match[1];
}

function usage(message) {
  if (message) console.error(message);
  console.error(`Usage:
  node mobile-shell/publisher/cli.mjs prepare [--recipe lunara] --source-root ABS --build-root ABS --app-slug SLUG --app-id ID --project-id ID --display-name NAME --data-namespace ID [--entrypoint index.html] [--min-shell-version 1.0.0] [--base-revision REV|null] [--capability NAME ...] [--change "Added: Dark mode" ...] [--source-owner OWNER --source-repo REPO --source-commit SHA] --out preparation.json
  node mobile-shell/publisher/cli.mjs approve --preparation preparation.json --approve-reviewed-output --policy-checked VERSION --approve-source-commit SHA --download-url https://publikhq.com/PATH --package-out app.irisapp --descriptor-out descriptor.json --receipt-out receipt.json [--age-rating 4|9|13|16|18 --privacy-summary TEXT --privacy-policy-url https://... --support-contact-kind email|url --support-contact-value VALUE --report-contact-kind email|url --report-contact-value VALUE]
  node mobile-shell/publisher/cli.mjs catalog-emit --apps-dir DIR --categories categories-input.json --generated-at 2026-09-28T00:00:00.000Z --out catalog-v2-dir [--overwrite [--prune-stale]]

This tool performs local filesystem reads/writes only. It does not fetch source, install dependencies, build apps, upload artifacts, publish catalog data, or deploy anything.
catalog-emit reads one reviewed app descriptor JSON file per app from --apps-dir (each combining a catalog index entry and an apps/<slug>.json detail page on one object, including its already-approved mobileShell descriptor) and a categories input JSON file ({"categories":[{"id","name","order"}, ...]}), and deterministically writes index.json/index-<n>.json, categories.json, apps/<slug>.json (compact canonical JSON) and manifest.json (sha256 of every file, usable as ETags) under --out. With --overwrite a changed catalog needs a new --generated-at, and pages of removed apps are only deleted with --prune-stale. It never fetches, builds, or approves anything itself; every mobileShell descriptor it carries into the catalog must already be the output of the approve command.
Source repository/commit metadata is caller-attested; this offline tool does not independently verify Git provenance.
The --age-rating/--privacy-*/--*-contact-* flags are optional and App Store Guideline 4.7 specific (age rating, privacy summary/policy, support and report contact). Supply all seven together or none; omitting them still produces an ordinary, fully installable descriptor that is simply not ready for a 4.7 listing.
--policy-checked VERSION is required on approve: it must equal the current "Policy version:" line in mobile-shell/publisher/APP_POLICY.md, attesting the package was checked against that policy before approval.
--change (repeatable, prepare only) is a hand-written feature title, exactly "Added: <text>" or "Removed: <text>": the phone Features page shows it as the version's row title verbatim. Requires --min-shell-version at or above ${FIRST_SHELL_VERSION_ACCEPTING_CHANGES} (contract v1.1, SPEC.md section 2.6); omit --change entirely and the row falls back to "Update from <date>".`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = { capabilities: [], changes: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) usage(`unexpected argument: ${token}`);
    const key = token.slice(2);
    if (key === "approve-reviewed-output") {
      args.approveReviewedOutput = true;
      continue;
    }
    if (key === "overwrite") {
      args.overwrite = true;
      continue;
    }
    if (key === "prune-stale") {
      args.pruneStale = true;
      continue;
    }
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) usage(`missing value for --${key}`);
    i += 1;
    if (key === "capability") args.capabilities.push(value);
    // Repeatable, hand-built feature title(s) for `prepare` (SPEC.md
    // section 2.6, MV3): "Added: Dark mode" / "Removed: Auto-scroll", the
    // exact text the phone's Features page shows as the row title. Parsed
    // in `parseChangeFlag` below, not here, so a malformed value is
    // reported with the same `usage()` path as every other bad flag.
    else if (key === "change") args.changes.push(value);
    else args[key.replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = value;
  }
  return args;
}

const CHANGE_PREFIX_PATTERN = /^(Added|Removed): .+/;

/**
 * `--change "Added: Dark mode"` (or `"Removed: Auto-scroll"`) -> the
 * `{title, kind, target}` object `preparePublisherBuild`'s `changes` param
 * expects (contracts/index.js `CHANGE_KEYS`/`KNOWN_CHANGE_KINDS`). The CLI
 * has no way to name a `target` revision (that needs Iris desktop's
 * `FeatureVersionRecord`, the other of the two producers SPEC.md section
 * 2.6 names), so a hand-built change is always `target: null`. The whole
 * string, prefix included, becomes `title`, matching the exact row text
 * SPEC.md section 1.1 shows ("Added: Dark mode" is the title, not a
 * separate label next to it).
 */
function parseChangeFlag(value) {
  const match = CHANGE_PREFIX_PATTERN.exec(value);
  if (!match) usage(`--change must start with "Added: " or "Removed: ", got: ${value}`);
  return { title: value, kind: match[1] === "Added" ? "added" : "removed", target: null };
}

function isInsideOrEqual(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
}

async function pathExists(path) {
  try {
    await lstat(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function canonicalDirectory(path, label) {
  const resolved = resolve(path);
  const info = await lstat(resolved);
  if (info.isSymbolicLink()) throw new TypeError(`${label} may not be a symlink`);
  if (!info.isDirectory()) throw new TypeError(`${label} must be a directory`);
  return realpath(resolved);
}

async function preflightOutputs(outputPaths, { forbiddenRoots = [], forbiddenFiles = [] } = {}) {
  const outputs = outputPaths.map((path) => resolve(path));
  if (new Set(outputs).size !== outputs.length) throw new TypeError("output paths must be distinct");

  const canonicalRoots = [];
  for (const [index, root] of forbiddenRoots.entries()) {
    canonicalRoots.push(await canonicalDirectory(root, `forbidden output root ${index + 1}`));
  }
  const forbidden = new Set(forbiddenFiles.map((path) => resolve(path)));

  for (const output of outputs) {
    if (forbidden.has(output)) throw new TypeError("output path may not overwrite an input file");
    if (canonicalRoots.some((root) => isInsideOrEqual(root, output))) {
      throw new TypeError("output path must be outside supplied source/build roots");
    }
    if (await pathExists(output)) throw new TypeError(`output already exists: ${output}`);
  }

  for (const output of outputs) await mkdir(dirname(output), { recursive: true });

  const canonicalOutputs = [];
  for (const output of outputs) {
    const parent = await realpath(dirname(output));
    const canonicalCandidate = join(parent, basename(output));
    canonicalOutputs.push(canonicalCandidate);
    if (forbidden.has(canonicalCandidate)) throw new TypeError("output path may not overwrite an input file");
    if (canonicalRoots.some((root) => isInsideOrEqual(root, canonicalCandidate))) {
      throw new TypeError("output path must be outside supplied source/build roots");
    }
    if (await pathExists(output)) throw new TypeError(`output already exists: ${output}`);
  }
  if (new Set(canonicalOutputs).size !== canonicalOutputs.length) {
    throw new TypeError("output paths must remain distinct after canonical parent resolution");
  }
  return outputs;
}

async function writeExclusive(path, bytes) {
  const flags = fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | (fsConstants.O_NOFOLLOW || 0);
  let handle;
  try {
    handle = await open(path, flags, 0o600);
    await handle.writeFile(bytes);
  } finally {
    await handle?.close();
  }
}

async function writeJSONExclusive(path, value) {
  await writeExclusive(path, `${JSON.stringify(value, null, 2)}\n`);
}

function stableFileIdentity(stats) {
  return [stats.dev, stats.ino, stats.size, stats.mtimeNs, stats.ctimeNs].map(String).join(":");
}

async function readPreparationJSON(path) {
  const flags = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW || 0);
  let handle;
  try {
    handle = await open(path, flags);
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) throw new TypeError("preparation input must be a regular file");
    if (before.size > BigInt(MAX_PREPARATION_BYTES)) {
      throw new TypeError(`preparation input exceeds ${MAX_PREPARATION_BYTES} bytes`);
    }
    const size = Number(before.size);
    const bytes = Buffer.alloc(size);
    let offset = 0;
    while (offset < size) {
      const { bytesRead } = await handle.read(bytes, offset, size - offset, offset);
      if (bytesRead === 0) throw new TypeError("preparation input changed while being read");
      offset += bytesRead;
    }
    const after = await handle.stat({ bigint: true });
    if (stableFileIdentity(before) !== stableFileIdentity(after)) {
      throw new TypeError("preparation input changed while being read");
    }
    return JSON.parse(bytes.toString("utf8"));
  } finally {
    await handle?.close();
  }
}

function required(args, key) {
  if (!args[key]) usage(`--${key.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} is required`);
  return args[key];
}

async function prepare(args) {
  const recipe = args.recipe;
  if (recipe && recipe !== "lunara") usage("only --recipe lunara is defined");
  const source = recipe === "lunara"
    ? LUNARA_REVIEWED_SOURCE
    : {
        owner: required(args, "sourceOwner"),
        repo: required(args, "sourceRepo"),
        commit: required(args, "sourceCommit"),
      };
  const capabilities = [...args.capabilities];
  if (recipe === "lunara") {
    for (const capability of LUNARA_MINIMUM_CORE_CAPABILITIES) {
      if (!capabilities.includes(capability)) capabilities.push(capability);
    }
  }
  const sourceRoot = resolve(required(args, "sourceRoot"));
  const buildRoot = resolve(required(args, "buildRoot"));
  const [out] = await preflightOutputs([required(args, "out")], {
    forbiddenRoots: [sourceRoot, buildRoot],
  });
  const preparation = await preparePublisherBuild({
    sourceRoot,
    buildOutputRoot: buildRoot,
    sourceOwner: source.owner,
    sourceRepo: source.repo,
    sourceCommit: source.commit,
    appSlug: required(args, "appSlug"),
    appId: required(args, "appId"),
    projectId: required(args, "projectId"),
    displayName: required(args, "displayName"),
    entrypoint: args.entrypoint ?? "index.html",
    minShellVersion: args.minShellVersion ?? "1.0.0",
    capabilities,
    dataNamespace: required(args, "dataNamespace"),
    baseRevisionId: !args.baseRevision || args.baseRevision === "null" ? null : args.baseRevision,
    changes: args.changes.length ? args.changes.map(parseChangeFlag) : null,
  });
  if (recipe === "lunara") assertLunaraPreparation(preparation);
  await writeJSONExclusive(out, preparation);
  process.stdout.write(`${JSON.stringify({ status: "prepared", out, preparationHash: preparation.preparationHash, revisionId: preparation.revision.revisionId })}\n`);
}

// Guideline 4.7 metadata flags are optional and must be supplied together;
// omitting all seven still produces an ordinary, fully installable
// descriptor (see attachAppStoreMetadata in index.mjs).
const APP_STORE_METADATA_FLAG_KEYS = [
  "ageRating", "privacySummary", "privacyPolicyUrl",
  "supportContactKind", "supportContactValue", "reportContactKind", "reportContactValue",
];

function appStoreMetadataFromArgs(args) {
  const present = APP_STORE_METADATA_FLAG_KEYS.filter((key) => args[key] !== undefined);
  if (present.length === 0) return null;
  if (present.length !== APP_STORE_METADATA_FLAG_KEYS.length) {
    usage(
      "the App Store metadata flags (--age-rating --privacy-summary --privacy-policy-url "
      + "--support-contact-kind --support-contact-value --report-contact-kind --report-contact-value) "
      + "must be supplied together or not at all",
    );
  }
  const ageRating = Number(args.ageRating);
  if (!Number.isInteger(ageRating)) usage("--age-rating must be an integer");
  return {
    kind: APP_STORE_METADATA_KIND,
    version: APP_STORE_METADATA_VERSION,
    ageRating,
    privacySummary: args.privacySummary,
    privacyPolicyUrl: args.privacyPolicyUrl,
    supportContact: { kind: args.supportContactKind, value: args.supportContactValue },
    reportContact: { kind: args.reportContactKind, value: args.reportContactValue },
  };
}

async function approve(args) {
  if (args.approveReviewedOutput !== true) usage("--approve-reviewed-output is required");
  const preparationPath = resolve(required(args, "preparation"));
  const preparation = await readPreparationJSON(preparationPath);
  const [packageOut, descriptorOut, receiptOut] = await preflightOutputs(
    [required(args, "packageOut"), required(args, "descriptorOut"), required(args, "receiptOut")],
    {
      forbiddenRoots: [preparation?.source?.root, preparation?.build?.root],
      forbiddenFiles: [preparationPath],
    },
  );
  const appStoreMetadata = appStoreMetadataFromArgs(args);
  // RC-14 hosted-app policy gate: checked last, after every other input is
  // already known-valid, so a missing/stale --policy-checked never masks an
  // unrelated input error with the wrong message.
  const currentPolicyVersion = await currentAppPolicyVersion();
  if (args.policyChecked === undefined) {
    usage(
      `approve refuses to run without --policy-checked ${currentPolicyVersion}: every package must be checked `
      + "against mobile-shell/publisher/APP_POLICY.md before the catalog can list it.",
    );
  }
  if (args.policyChecked !== currentPolicyVersion) {
    usage(
      `approve refuses to run because --policy-checked ${args.policyChecked} does not match the current `
      + `mobile-shell/publisher/APP_POLICY.md version (${currentPolicyVersion}): re-check the package against `
      + `the current policy and pass --policy-checked ${currentPolicyVersion}.`,
    );
  }
  const result = await approvePublisherBuild({
    preparation,
    approved: true,
    approvedSourceCommit: required(args, "approveSourceCommit"),
    downloadUrl: required(args, "downloadUrl"),
    appStoreMetadata,
  });
  await writeExclusive(packageOut, result.packageBytes);
  await writeJSONExclusive(descriptorOut, result.descriptor);
  await writeJSONExclusive(receiptOut, result.receipt);
  process.stdout.write(`${JSON.stringify({
    status: "approved-and-packaged",
    packageOut,
    descriptorOut,
    receiptOut,
    packageSha256: result.descriptor.packageSha256,
    byteCount: result.descriptor.byteCount,
    revisionId: result.descriptor.revisionId,
  })}\n`);
}

async function catalogEmit(args) {
  const appsDir = await canonicalDirectory(resolve(required(args, "appsDir")), "--apps-dir");
  const categoriesPath = resolve(required(args, "categories"));
  const outDir = resolve(required(args, "out"));
  const generatedAt = required(args, "generatedAt");

  const entries = await readdir(appsDir, { withFileTypes: true });
  const apps = [];
  for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    apps.push(JSON.parse(await readFile(join(appsDir, entry.name), "utf8")));
  }
  if (apps.length === 0) usage(`--apps-dir contained no *.json reviewed app descriptors: ${appsDir}`);

  const categoriesInput = JSON.parse(await readFile(categoriesPath, "utf8"));
  const categories = Array.isArray(categoriesInput) ? categoriesInput : categoriesInput?.categories;
  if (!Array.isArray(categories)) usage("--categories must contain an array, or {\"categories\": [...]}");

  const emitted = emitCatalogV2({ apps, categories, generatedAt });
  if (!args.overwrite && await pathExists(outDir)) {
    usage(`--out already exists: ${outDir} (pass --overwrite to replace a previous publish)`);
  }
  const written = await writeCatalogV2(outDir, emitted, {
    overwrite: Boolean(args.overwrite),
    pruneStale: Boolean(args.pruneStale),
  });
  process.stdout.write(`${JSON.stringify({
    status: "emitted",
    out: outDir,
    appCount: emitted.appPages.size,
    pageCount: emitted.indexPages.length,
    categoryCount: emitted.categories.categories.length,
    catalogEmitHash: emitted.catalogEmitHash,
    removedStaleFiles: written.stale,
  })}\n`);
}

const [command, ...argv] = process.argv.slice(2);
try {
  const args = parseArgs(argv);
  if (command === "prepare") await prepare(args);
  else if (command === "approve") await approve(args);
  else if (command === "catalog-emit") await catalogEmit(args);
  else usage("command must be prepare, approve, or catalog-emit");
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
