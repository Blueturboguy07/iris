// Real, installable fixture packages and icons for catalog v2 fixtures.
//
// A package built here is a genuine MobileShellDeliveryPackageV1: it passes
// the contracts' verifyDeliveryPackageV1, and its descriptor is derived from
// its own bytes by the publisher's descriptorFromPackageBytes (the same
// function the approve command uses). So a client test can serve these bytes
// at the descriptor's downloadUrl and run the unchanged install verification
// path end to end. Every id, nonce and timestamp is derived from the seed, so
// the bytes are reproducible.

import { createHash } from "node:crypto";
import { crc32, deflateSync } from "node:zlib";

import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  createRevisionIdentity,
  sha256Digest,
  verifyDeliveryPackageV1,
} from "../../../contracts/index.js";
import { descriptorFromPackageBytes } from "../../../publisher/index.mjs";
import { deterministicHex } from "./rng.mjs";

const FIXTURE_INSTANT = "2026-09-28T00:00:00.000Z";

function htmlEscape(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function pngChunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typeAndData = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typeAndData) >>> 0);
  return Buffer.concat([length, typeAndData, crc]);
}

/** A valid 32x32 two-tone PNG whose colors come from (seed, slug). Deterministic. */
export function fixtureIconBytes(seed, slug) {
  const hex = deterministicHex(seed, slug, "icon-colors");
  const background = [0, 2, 4].map((i) => Number.parseInt(hex.slice(i, i + 2), 16));
  const foreground = [6, 8, 10].map((i) => Number.parseInt(hex.slice(i, i + 2), 16));
  const size = 32;
  const rows = [];
  for (let y = 0; y < size; y += 1) {
    const row = [0]; // filter type 0
    for (let x = 0; x < size; x += 1) {
      const inside = x >= 8 && x < 24 && y >= 8 && y < 24;
      row.push(...(inside ? foreground : background));
    }
    rows.push(Buffer.from(row));
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // truecolor
  header[10] = 0;
  header[11] = 0;
  header[12] = 0;
  return new Uint8Array(Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(Buffer.concat(rows))),
    pngChunk("IEND", Buffer.alloc(0)),
  ]));
}

/** The index row's iconHash for these icon bytes: first 16 hex characters of their sha256. */
export function iconHashForBytes(bytes) {
  return createHash("sha256").update(bytes).digest("hex").slice(0, 16);
}

function fillerScript(seed, slug, targetBytes) {
  const lines = [`// ${slug}: fixture app script for Iris catalog tests.\n`, "window.fixtureReady = true;\n"];
  let size = lines.reduce((total, line) => total + Buffer.byteLength(line), 0);
  let counter = 0;
  while (size < targetBytes) {
    const line = `// ${deterministicHex(seed, slug, "filler", counter)}\n`;
    lines.push(line);
    size += Buffer.byteLength(line);
    counter += 1;
  }
  return lines.join("");
}

/**
 * Builds one installable fixture package.
 *
 * @param {object} options
 * @param {string} options.seed
 * @param {string} options.slug
 * @param {string} options.name
 * @param {string[]} options.capabilities - the manifest's requested capabilities (the app page's permissions)
 * @param {number} options.scriptBytes - approximate size of the bundled script, to give the package a realistic size
 * @returns {Promise<{ packageBytes: Uint8Array, descriptor: object }>}
 */
export async function buildFixturePackage({ seed, slug, name, capabilities, scriptBytes }) {
  const appId = `publik.${slug}`;
  const projectId = `publik.${slug}.mobile`;
  const html = [
    "<!doctype html>",
    '<html lang="en">',
    `<head><meta charset="utf-8"><title>${htmlEscape(name)}</title><script src="app.js"></script></head>`,
    `<body><h1>${htmlEscape(name)}</h1><p>Fixture app for Iris catalog tests.</p></body>`,
    "</html>",
    "",
  ].join("\n");
  const script = fillerScript(seed, slug, scriptBytes);
  const contents = [
    { path: "app.js", mediaType: "text/javascript", text: script },
    { path: "index.html", mediaType: "text/html", text: html },
  ];
  const files = [];
  for (const file of contents) {
    const bytes = Buffer.from(file.text, "utf8");
    files.push({ path: file.path, sha256: await sha256Digest(bytes), bytes: bytes.byteLength, mediaType: file.mediaType });
  }
  const manifest = {
    kind: "iris.mobile-shell.manifest",
    version: CONTRACT_VERSION,
    appId,
    projectId,
    displayName: name,
    runtime: { type: "web", entrypoint: "index.html", minShellVersion: "1.0.0" },
    capabilities: [...capabilities].sort(),
    data: { namespace: appId, updatePolicy: "preserve" },
  };
  const identity = await createRevisionIdentity({ appId, projectId, baseRevisionId: null, manifest, files });
  const revision = {
    kind: "iris.mobile-shell.revision",
    version: CONTRACT_VERSION,
    appId,
    projectId,
    revisionId: identity.revisionId,
    baseRevisionId: null,
    manifestHash: identity.manifestHash,
    contentHash: identity.contentHash,
    createdAt: FIXTURE_INSTANT,
    manifest,
    files,
  };
  const approvalId = `approval_fixture_${deterministicHex(seed, slug, "approval").slice(0, 24)}`;
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: CONTRACT_VERSION,
    approvalId,
    requestId: null,
    requestNonce: null,
    appId,
    projectId,
    baseRevisionId: null,
    approvedRevisionId: identity.revisionId,
    approvedContentHash: identity.contentHash,
    approvedAt: FIXTURE_INSTANT,
  };
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: CONTRACT_VERSION,
    envelopeId: `delivery_fixture_${deterministicHex(seed, slug, "envelope").slice(0, 24)}`,
    deliveryNonce: deterministicHex(seed, slug, "nonce"),
    approvalId,
    appId,
    projectId,
    baseRevisionId: null,
    revisionId: identity.revisionId,
    contentHash: identity.contentHash,
    issuedAt: FIXTURE_INSTANT,
    revision,
  };
  const pkg = {
    format: DELIVERY_PACKAGE_FORMAT,
    approval,
    envelope,
    files: contents.map((file) => ({
      path: file.path,
      mediaType: file.mediaType,
      contentBase64: Buffer.from(file.text, "utf8").toString("base64"),
    })),
  };
  const verified = await verifyDeliveryPackageV1(pkg);
  if (!verified.ok) throw new Error(`fixture package for ${slug} is invalid: ${verified.errors.join("; ")}`);
  const packageBytes = new Uint8Array(Buffer.from(`${JSON.stringify(pkg, null, 2)}\n`, "utf8"));
  const descriptor = await descriptorFromPackageBytes(
    packageBytes,
    `https://publikhq.com/api/iris/mobile-shell/${slug}/pkg.json`,
  );
  return { packageBytes, descriptor: { ...descriptor, appStoreMetadata: null } };
}
