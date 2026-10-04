import { execFileSync } from "node:child_process";
import { mkdir, copyFile, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Additive sibling of generate-desktop-package.mjs (that file is owned by
// another unit and is left untouched). It exists only because macOS ARG_MAX
// (1 MiB) makes it impossible to pass a multi-megabyte fixture, such as a
// Kneecap-like ~6 MB single-file revision, through the existing script's
// inline "--content" argv string. This script takes "--content-file"
// instead and otherwise drives the same desktop CLI stage/approve/deliver
// flow, so both scripts produce byte-identical real, validator-accepted
// packages for m2-storage's storage-retention tests.

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) throw new TypeError("arguments must be --name value pairs");
    options[name.slice(2)] = value;
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const output = resolve(options.output || "");
if (!output) throw new TypeError("--output is required");
const contentFile = options["content-file"];
if (!contentFile) throw new TypeError("--content-file is required");
const baseRevisionId = options.base === "null" || options.base === undefined ? null : options.base;
const appId = options.app ?? "publik.kneecap";
const projectId = options.project ?? "publik.kneecap.mobile";
const namespace = options.namespace ?? appId;
const displayName = options["display-name"] ?? "Kneecap";
const capabilities = JSON.parse(options.capabilities ?? "[]");
const deliveryNonce = options.nonce ?? "d".repeat(64);

const here = dirname(fileURLToPath(import.meta.url));
const cli = resolve(here, "../../../desktop/cli.mjs");
const source = join(output, "source");
const build = join(output, "build");
const registrationPath = join(output, "registration.json");
const reviewPath = join(output, "review.json");
const stagePath = join(output, "stage.json");
const approvedPath = join(output, "approved.json");
const packagePath = join(output, "package.json");
const receiptsPath = join(output, "receipts.json");
const trustedApprovalPath = join(output, "trusted-approval.json");

await mkdir(join(source, ".git"), { recursive: true });
await mkdir(build, { recursive: true });
await copyFile(contentFile, join(build, "index.html"));

const registration = {
  kind: "iris.mobile-shell.desktop-project",
  version: 1,
  appId,
  projectId,
  appSlug: "kneecap",
  provenance: {
    kind: "guideSourceClone",
    clonePath: source,
    pinnedCommit: "a".repeat(40),
    canonicalRepo: "publik/kneecap",
  },
};
const review = {
  kind: "iris.mobile-shell.desktop-package-review",
  version: 1,
  reviewedAt: "2026-09-17T16:00:00.000Z",
  baseRevisionId,
  manifest: {
    kind: "iris.mobile-shell.manifest",
    version: 1,
    appId: registration.appId,
    projectId: registration.projectId,
    displayName,
    runtime: { type: "web", entrypoint: "index.html", minShellVersion: "1.0.0" },
    capabilities,
    data: { namespace, updatePolicy: "preserve" },
  },
  files: [{ path: "index.html", mediaType: "text/html" }],
};
await writeFile(registrationPath, `${JSON.stringify(registration, null, 2)}\n`, "utf8");
await writeFile(reviewPath, `${JSON.stringify(review, null, 2)}\n`, "utf8");

const currentBase = baseRevisionId ?? "null";
execFileSync(process.execPath, [
  cli, "stage",
  "--registration", registrationPath,
  "--review", reviewPath,
  "--root", build,
  "--current-base", currentBase,
  "--out", stagePath,
], { stdio: "pipe" });
execFileSync(process.execPath, [
  cli, "approve",
  "--registration", registrationPath,
  "--stage", stagePath,
  "--current-base", currentBase,
  "--receipts", receiptsPath,
  "--approve",
  "--out", approvedPath,
], { stdio: "pipe" });
execFileSync(process.execPath, [
  cli, "deliver",
  "--registration", registrationPath,
  "--approved", approvedPath,
  "--current-base", currentBase,
  "--receipts", receiptsPath,
  "--delivery-nonce", deliveryNonce,
  "--out", packagePath,
], { stdio: "pipe" });

const approved = JSON.parse(await readFile(approvedPath, "utf8"));
const pkg = JSON.parse(await readFile(packagePath, "utf8"));
await writeFile(trustedApprovalPath, `${JSON.stringify(approved.approval, null, 2)}\n`, "utf8");
process.stdout.write(`${JSON.stringify({
  packagePath,
  trustedApprovalPath,
  revisionId: pkg.envelope.revisionId,
  contentHash: pkg.envelope.contentHash,
})}\n`);
