import { createHash, randomBytes } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { extname, isAbsolute, join, posix, relative, resolve, sep } from "node:path";
import { verifyFileRuntimeEntrypoint } from "./file-runtime-preflight.mjs";

import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  DELIVERY_PACKAGE_LIMITS,
  FIRST_SHELL_VERSION_ACCEPTING_CHANGES,
  compareSemver,
  createRevisionIdentity,
  isSafePackagePath,
  sha256Digest,
  validateAppStoreMetadataV1,
  validateDeliveryApprovalV1,
  validateDeliveryEnvelopeV1,
  validateDeliveryPackageV1,
  validateManifestV1,
  validateRevisionChangesV1,
  validateRevisionV1,
  verifyRevisionIntegrity,
} from "../contracts/index.js";

const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const REVISION_ID_PATTERN = /^rev-sha256:[0-9a-f]{64}$/;
const STABLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const SOURCE_COMMIT_PATTERN = /^[0-9a-f]{40}$/;
const REPO_PART_PATTERN = /^[A-Za-z0-9_.-]+$/;
const SEMVER_PATTERN = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const MAX_RAW_PACKAGE_BYTES = 48 * 1024 * 1024;
const MAX_BUILD_DIRECTORIES = 512;
const MAX_BUILD_DEPTH = 32;

export const PUBLISHER_PREP_LIMITS = Object.freeze({
  maxRawPackageBytes: MAX_RAW_PACKAGE_BYTES,
  maxBuildDirectories: MAX_BUILD_DIRECTORIES,
  maxBuildDepth: MAX_BUILD_DEPTH,
});

export const LUNARA_REVIEWED_SOURCE = Object.freeze({
  owner: "Blueturboguy07",
  repo: "lunara",
  commit: "551e030e8ea276c24ec42b13242d3ce49bca948f",
});

export const LUNARA_MINIMUM_CORE_CAPABILITIES = Object.freeze(["web.storage"]);

const MEDIA_TYPES = Object.freeze({
  ".css": "text/css",
  ".gif": "image/gif",
  ".htm": "text/html",
  ".html": "text/html",
  ".ico": "image/x-icon",
  ".jpeg": "image/jpeg",
  ".jpg": "image/jpeg",
  ".js": "text/javascript",
  ".json": "application/json",
  ".mjs": "text/javascript",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".task": "application/octet-stream",
  ".txt": "text/plain",
  ".wasm": "application/wasm",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
});

function canonicalJSONString(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSONString).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSONString(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function randomHex(bytes = 24) {
  return randomBytes(bytes).toString("hex");
}

function canonicalIso(value, label) {
  if (typeof value !== "string") throw new TypeError(`${label} must be a canonical ISO instant`);
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString() !== value) {
    throw new TypeError(`${label} must be a canonical ISO instant`);
  }
  return value;
}

function stableId(value, label) {
  if (typeof value !== "string" || !STABLE_ID_PATTERN.test(value)) throw new TypeError(`${label} is invalid`);
  return value;
}

function baseRevisionId(value) {
  if (value === null) return null;
  if (typeof value !== "string" || !REVISION_ID_PATTERN.test(value)) throw new TypeError("baseRevisionId is invalid");
  return value;
}

function validateSource(source) {
  if (!source || typeof source !== "object" || Array.isArray(source)) throw new TypeError("source provenance is required");
  if (source.kind !== "caller-attested-reviewed-source-root") {
    throw new TypeError("source provenance kind must be caller-attested-reviewed-source-root");
  }
  if (source.verification !== "not independently verified by this offline tool") {
    throw new TypeError("source provenance verification status is invalid");
  }
  if (!REPO_PART_PATTERN.test(source.owner ?? "")) throw new TypeError("source owner is invalid");
  if (!REPO_PART_PATTERN.test(source.repo ?? "")) throw new TypeError("source repo is invalid");
  if (!SOURCE_COMMIT_PATTERN.test(source.commit ?? "")) throw new TypeError("source commit must be an exact 40-character lowercase SHA");
  if (typeof source.root !== "string" || !isAbsolute(source.root)) throw new TypeError("source root must be an absolute path");
  return source;
}

function inferMediaType(path) {
  return MEDIA_TYPES[extname(path).toLowerCase()] ?? "application/octet-stream";
}

function normalizeRelativePath(root, absolutePath) {
  const rel = relative(root, absolutePath).split(sep).join("/");
  if (!isSafePackagePath(rel)) throw new TypeError(`unsafe build-output path: ${rel || absolutePath}`);
  return rel;
}

function stableFileIdentity(stats) {
  return [stats.dev, stats.ino, stats.size, stats.mtimeNs, stats.ctimeNs].map(String).join(":");
}

async function readRegularFileNoFollow(path, label, maximumBytes = DELIVERY_PACKAGE_LIMITS.maxSingleFileBytes) {
  const flags = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW || 0);
  let handle;
  try {
    handle = await open(path, flags);
    const before = await handle.stat({ bigint: true });
    if (!before.isFile()) throw new TypeError(`${label} must remain a regular file`);
    if (before.size > BigInt(maximumBytes)) {
      throw new TypeError(`${label} exceeds the ${maximumBytes}-byte read limit`);
    }
    const size = Number(before.size);
    const buffer = Buffer.alloc(size);
    let offset = 0;
    while (offset < size) {
      const { bytesRead } = await handle.read(buffer, offset, size - offset, offset);
      if (bytesRead === 0) throw new TypeError(`${label} changed while being read`);
      offset += bytesRead;
    }
    const after = await handle.stat({ bigint: true });
    if (stableFileIdentity(before) !== stableFileIdentity(after)) {
      throw new TypeError(`${label} changed while being read`);
    }
    return Uint8Array.from(buffer);
  } finally {
    await handle?.close();
  }
}

function assertWithinRoot(root, realPath, label) {
  if (realPath !== root && !realPath.startsWith(`${root}${sep}`)) {
    throw new TypeError(`${label} escapes build-output root`);
  }
}

async function canonicalDirectory(path, label) {
  if (typeof path !== "string" || !isAbsolute(path)) throw new TypeError(`${label} must be an absolute path`);
  const resolved = resolve(path);
  const info = await lstat(resolved);
  if (info.isSymbolicLink()) throw new TypeError(`${label} may not be a symlink`);
  if (!info.isDirectory()) throw new TypeError(`${label} must be a directory`);
  return realpath(resolved);
}

async function walkBuildRoot(buildOutputRoot) {
  const root = await canonicalDirectory(buildOutputRoot, "build-output root");
  const files = [];
  let directoryCount = 1;

  async function visit(directory, depth) {
    if (depth > MAX_BUILD_DEPTH) throw new TypeError(`build-output directory depth exceeds ${MAX_BUILD_DEPTH}`);
    const currentInfo = await lstat(directory);
    if (currentInfo.isSymbolicLink()) throw new TypeError("build-output directory may not be a symlink");
    if (!currentInfo.isDirectory()) throw new TypeError("build-output traversal target must remain a directory");
    const currentReal = await realpath(directory);
    assertWithinRoot(root, currentReal, "build-output directory");

    const entries = await readdir(currentReal, { withFileTypes: true });
    for (const entry of entries) {
      const absolutePath = join(currentReal, entry.name);
      const rel = normalizeRelativePath(root, absolutePath);
      const info = await lstat(absolutePath);
      if (info.isSymbolicLink()) throw new TypeError(`build-output path may not be a symlink: ${rel}`);
      if (info.isDirectory()) {
        const nextDepth = depth + 1;
        if (nextDepth > MAX_BUILD_DEPTH) {
          throw new TypeError(`build-output directory depth exceeds ${MAX_BUILD_DEPTH}: ${rel}`);
        }
        directoryCount += 1;
        if (directoryCount > MAX_BUILD_DIRECTORIES) {
          throw new TypeError(`build-output has more than ${MAX_BUILD_DIRECTORIES} directories`);
        }
        const childReal = await realpath(absolutePath);
        assertWithinRoot(root, childReal, `build-output directory ${rel}`);
        await visit(childReal, nextDepth);
        continue;
      }
      if (!info.isFile()) throw new TypeError(`build-output path must be a regular file: ${rel}`);
      const real = await realpath(absolutePath);
      assertWithinRoot(root, real, `build-output file ${rel}`);
      files.push({ path: rel, absolutePath: real });
      if (files.length > DELIVERY_PACKAGE_LIMITS.maxFiles) {
        throw new TypeError(`build-output has more than ${DELIVERY_PACKAGE_LIMITS.maxFiles} files`);
      }
    }
  }
  await visit(root, 0);
  files.sort((left, right) => left.path.localeCompare(right.path));
  if (files.length < 1) throw new TypeError("build-output root is empty");
  return { root, files };
}

function resolveLocalReference(entrypoint, reference, filePaths) {
  const raw = reference.trim();
  if (
    raw === ""
    || raw.startsWith("#")
    || raw.startsWith("data:")
    || raw.startsWith("blob:")
    || raw.startsWith("mailto:")
    || raw.startsWith("tel:")
  ) return;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(raw) || raw.startsWith("//") || raw.startsWith("/")) {
    throw new TypeError(`entrypoint contains a non-relative resource reference: ${raw}`);
  }
  const pathOnly = raw.split(/[?#]/, 1)[0];
  const normalized = posix.normalize(posix.join(posix.dirname(entrypoint), pathOnly));
  if (normalized === ".." || normalized.startsWith("../") || !isSafePackagePath(normalized)) {
    throw new TypeError(`entrypoint resource escapes package root: ${raw}`);
  }
  if (!filePaths.has(normalized)) throw new TypeError(`entrypoint references a file absent from build output: ${normalized}`);
}

// Limited static sanity check only. This scans quoted HTML src/href attributes in
// the entrypoint. It does not parse CSS url(), srcset, JS imports, <base>, dynamic
// runtime URLs, worker registrations, or framework-specific asset resolution.
function verifyRelativeEntrypointReferences(htmlBytes, entrypoint, filePaths) {
  const html = Buffer.from(htmlBytes).toString("utf8");
  const pattern = /\b(?:src|href)\s*=\s*["']([^"']+)["']/gi;
  for (const match of html.matchAll(pattern)) resolveLocalReference(entrypoint, match[1], filePaths);
  verifyFileRuntimeEntrypoint(htmlBytes);
}

async function readAndDescribeFiles(walked) {
  const fileContents = new Map();
  const descriptors = [];
  const packageFiles = [];
  let totalBytes = 0;
  for (const item of walked.files) {
    const bytes = await readRegularFileNoFollow(item.absolutePath, item.path);
    if (bytes.byteLength > DELIVERY_PACKAGE_LIMITS.maxSingleFileBytes) {
      throw new TypeError(`build-output file exceeds single-file limit: ${item.path}`);
    }
    totalBytes += bytes.byteLength;
    if (totalBytes > DELIVERY_PACKAGE_LIMITS.maxDecodedBytes) throw new TypeError("build-output exceeds decoded package limit");
    const mediaType = inferMediaType(item.path);
    const sha256 = await sha256Digest(bytes);
    descriptors.push({ path: item.path, sha256, bytes: bytes.byteLength, mediaType });
    packageFiles.push({ path: item.path, mediaType, contentBase64: Buffer.from(bytes).toString("base64") });
    fileContents.set(item.path, bytes);
  }
  return { descriptors, packageFiles, fileContents, totalBytes };
}

function preparationBindingPayload(preparation) {
  return {
    app: preparation.app,
    source: {
      kind: preparation.source.kind,
      verification: preparation.source.verification,
      owner: preparation.source.owner,
      repo: preparation.source.repo,
      commit: preparation.source.commit,
    },
    revision: {
      appId: preparation.revision.appId,
      projectId: preparation.revision.projectId,
      baseRevisionId: preparation.revision.baseRevisionId,
      revisionId: preparation.revision.revisionId,
      manifestHash: preparation.revision.manifestHash,
      contentHash: preparation.revision.contentHash,
      manifest: preparation.revision.manifest,
      files: preparation.revision.files,
    },
  };
}

function preparationHash(preparation) {
  const bytes = Buffer.from(canonicalJSONString(preparationBindingPayload(preparation)), "utf8");
  return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}

function contractValue(result, label) {
  if (!result?.ok) throw new TypeError(`${label}: ${(result?.errors ?? ["rejected"]).join("; ")}`);
  return result.value;
}

export async function preparePublisherBuild({
  sourceRoot,
  buildOutputRoot,
  sourceOwner,
  sourceRepo,
  sourceCommit,
  appSlug,
  appId,
  projectId,
  displayName,
  entrypoint = "index.html",
  minShellVersion = "1.0.0",
  capabilities = [],
  dataNamespace,
  baseRevisionId: suppliedBaseRevisionId = null,
  // Contract v1.1 (SPEC.md section 2.6, owner-decided 2026-09-28): the
  // phone Features page's plain-words title(s) for this revision, e.g.
  // "Added: Dark mode". `null` (the default) means "no titles for this
  // revision" -- the phone shows "Update from <date>" (or "First version"
  // for a project's first revision), exactly as before this field existed.
  // Two producers, per SPEC: Iris desktop passes an array derived from
  // `FeatureVersionRecord.name`/`.kind` for an edit-originated package;
  // `cli.mjs prepare --change "Added: ..."` (repeatable) builds one for a
  // hand-built package. Both funnel through this same parameter, validated
  // and identity-bound here, never trusted as already-safe caller input.
  changes = null,
  preparedAt = new Date().toISOString(),
}) {
  const sourceCanonicalRoot = await canonicalDirectory(sourceRoot, "source root");
  const source = validateSource({
    kind: "caller-attested-reviewed-source-root",
    verification: "not independently verified by this offline tool",
    owner: sourceOwner,
    repo: sourceRepo,
    commit: sourceCommit,
    root: sourceCanonicalRoot,
  });
  const walked = await walkBuildRoot(buildOutputRoot);
  stableId(appSlug, "appSlug");
  stableId(appId, "appId");
  stableId(projectId, "projectId");
  stableId(dataNamespace, "dataNamespace");
  baseRevisionId(suppliedBaseRevisionId);
  canonicalIso(preparedAt, "preparedAt");
  if (typeof displayName !== "string" || displayName.trim().length < 1 || displayName.length > 120) {
    throw new TypeError("displayName is invalid");
  }
  if (!isSafePackagePath(entrypoint)) throw new TypeError("entrypoint is unsafe");
  if (!SEMVER_PATTERN.test(minShellVersion)) throw new TypeError("minShellVersion is invalid");
  const normalizedChanges = changes === null ? undefined : changes;
  if (normalizedChanges !== undefined) {
    contractValue(validateRevisionChangesV1(normalizedChanges), "publisher changes");
    // Consistency check, not the real enforcement (see the constant's own
    // doc comment in contracts/index.js): a package that carries `changes`
    // but declares support for a shell older than the first one whose
    // validator understands the field would be internally inconsistent.
    if (compareSemver(minShellVersion, FIRST_SHELL_VERSION_ACCEPTING_CHANGES) < 0) {
      throw new TypeError(
        `changes requires minShellVersion >= ${FIRST_SHELL_VERSION_ACCEPTING_CHANGES}, got ${minShellVersion}`,
      );
    }
  }
  const manifest = {
    kind: "iris.mobile-shell.manifest",
    version: CONTRACT_VERSION,
    appId,
    projectId,
    displayName,
    runtime: { type: "web", entrypoint, minShellVersion },
    capabilities: [...capabilities],
    data: { namespace: dataNamespace, updatePolicy: "preserve" },
  };
  contractValue(validateManifestV1(manifest), "publisher manifest");

  const { descriptors, fileContents } = await readAndDescribeFiles(walked);
  const filePaths = new Set(descriptors.map((file) => file.path));
  const entrypointBytes = fileContents.get(entrypoint);
  if (!entrypointBytes) throw new TypeError("entrypoint is absent from build output");
  const entrypointDescriptor = descriptors.find((file) => file.path === entrypoint);
  if (entrypointDescriptor.mediaType !== "text/html") throw new TypeError("entrypoint must have text/html media type");
  verifyRelativeEntrypointReferences(entrypointBytes, entrypoint, filePaths);

  const identity = await createRevisionIdentity({
    appId,
    projectId,
    baseRevisionId: suppliedBaseRevisionId,
    manifest,
    files: descriptors,
    changes: normalizedChanges,
  });
  const revision = {
    kind: "iris.mobile-shell.revision",
    version: CONTRACT_VERSION,
    appId,
    projectId,
    revisionId: identity.revisionId,
    baseRevisionId: suppliedBaseRevisionId,
    manifestHash: identity.manifestHash,
    contentHash: identity.contentHash,
    createdAt: preparedAt,
    manifest,
    files: descriptors,
    ...(normalizedChanges !== undefined ? { changes: normalizedChanges } : {}),
  };
  contractValue(validateRevisionV1(revision), "publisher revision");
  contractValue(await verifyRevisionIntegrity(revision, fileContents), "publisher revision integrity");

  const preparation = {
    kind: "iris.mobile-shell.publisher-preparation",
    version: 1,
    preparedAt,
    app: { slug: appSlug, appId, projectId, displayName },
    source,
    build: { root: walked.root, entrypoint },
    revision,
  };
  return Object.freeze({ ...preparation, preparationHash: preparationHash(preparation) });
}

function validatePreparation(preparation) {
  if (!preparation || typeof preparation !== "object" || Array.isArray(preparation)) {
    throw new TypeError("publisher preparation is required");
  }
  if (preparation.kind !== "iris.mobile-shell.publisher-preparation" || preparation.version !== 1) {
    throw new TypeError("publisher preparation kind/version is unsupported");
  }
  canonicalIso(preparation.preparedAt, "preparation preparedAt");
  stableId(preparation.app?.slug, "preparation app.slug");
  stableId(preparation.app?.appId, "preparation app.appId");
  stableId(preparation.app?.projectId, "preparation app.projectId");
  validateSource(preparation.source);
  if (typeof preparation.build?.root !== "string" || !isAbsolute(preparation.build.root)) {
    throw new TypeError("preparation build.root is invalid");
  }
  if (!isSafePackagePath(preparation.build?.entrypoint)) throw new TypeError("preparation build.entrypoint is invalid");
  contractValue(validateRevisionV1(preparation.revision), "preparation revision");
  if (
    preparation.revision.appId !== preparation.app.appId
    || preparation.revision.projectId !== preparation.app.projectId
  ) throw new TypeError("preparation app identity does not bind revision");
  const expected = preparationHash(preparation);
  if (preparation.preparationHash !== expected) throw new TypeError("preparationHash does not match source/revision binding");
  return preparation;
}

function validatePublikDownloadURL(value) {
  if (typeof value !== "string") throw new TypeError("downloadUrl must be an exact reviewed Publik HTTPS URL");
  const authorityMatch = value.match(/^https:\/\/([^/?#]+)(?:[/?#]|$)/i);
  if (!authorityMatch || authorityMatch[1].toLowerCase() !== "publikhq.com") {
    throw new TypeError("downloadUrl must be an exact reviewed Publik HTTPS URL without an explicit port");
  }
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new TypeError("downloadUrl must be an exact reviewed Publik HTTPS URL");
  }
  if (
    url.protocol !== "https:"
    || url.hostname.toLowerCase() !== "publikhq.com"
    || url.port !== ""
    || url.username !== ""
    || url.password !== ""
    || url.hash !== ""
    || url.pathname === "/"
  ) throw new TypeError("downloadUrl must be an exact reviewed Publik HTTPS URL");
  return value;
}

async function rehydratePreparedBytes(preparation) {
  const walked = await walkBuildRoot(preparation.build.root);
  const { descriptors, packageFiles, fileContents } = await readAndDescribeFiles(walked);
  const expected = preparation.revision.files;
  if (canonicalJSONString(descriptors) !== canonicalJSONString(expected)) {
    throw new TypeError("build output changed after preparation; prepare again before approval");
  }
  contractValue(await verifyRevisionIntegrity(preparation.revision, fileContents), "approval revision integrity");
  const filePaths = new Set(descriptors.map((file) => file.path));
  verifyRelativeEntrypointReferences(
    fileContents.get(preparation.build.entrypoint),
    preparation.build.entrypoint,
    filePaths,
  );
  return packageFiles;
}

export async function descriptorFromPackageBytes(packageBytes, downloadUrl) {
  const inputByteLength = packageBytes?.byteLength;
  if (!Number.isSafeInteger(inputByteLength) || inputByteLength < 1) {
    throw new TypeError("package bytes must be a non-empty byte buffer");
  }
  if (inputByteLength > MAX_RAW_PACKAGE_BYTES) {
    throw new TypeError(`package bytes exceed the ${MAX_RAW_PACKAGE_BYTES}-byte raw package limit`);
  }
  const bytes = Uint8Array.from(packageBytes);
  let pkg;
  try {
    pkg = JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    throw new TypeError("package bytes are not valid JSON");
  }
  contractValue(await validateDeliveryPackageV1(pkg), "publisher package");
  const revision = pkg.envelope.revision;
  const exactURL = validatePublikDownloadURL(downloadUrl);
  return Object.freeze({
    version: 1,
    platform: "ios",
    packageFormat: DELIVERY_PACKAGE_FORMAT,
    downloadUrl: exactURL,
    mediaType: "application/json",
    byteCount: bytes.byteLength,
    packageSha256: await sha256Digest(bytes),
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    revisionId: revision.revisionId,
    contentHash: revision.contentHash,
  });
}

/**
 * Attaches a Guideline 4.7 AppStoreMetadataV1 object (age rating, privacy
 * summary/policy, support/report contact) to an already-derived mobile-shell
 * descriptor. This is a separate, explicit step, never implicit in
 * descriptorFromPackageBytes: the reviewed package bytes carry no App Store
 * metadata of their own (see contracts/CONTRACT.md, "AppStoreMetadataV1"),
 * so a caller who never calls this leaves an ordinary, fully installable,
 * v1 descriptor that is simply not ready for a 4.7 listing.
 */
export function attachAppStoreMetadata(descriptor, appStoreMetadata) {
  if (!descriptor || typeof descriptor !== "object" || Array.isArray(descriptor)) {
    throw new TypeError("descriptor is required");
  }
  const validated = contractValue(validateAppStoreMetadataV1(appStoreMetadata), "publisher appStoreMetadata");
  return Object.freeze({ ...descriptor, appStoreMetadata: validated });
}

export async function approvePublisherBuild({
  preparation,
  approved = false,
  approvedSourceCommit,
  downloadUrl,
  appStoreMetadata = null,
  approvedAt = new Date().toISOString(),
  approvalId = `approval_publisher_${randomHex(12)}`,
  envelopeId = `delivery_publisher_${randomHex(12)}`,
  deliveryNonce = randomHex(24),
}) {
  if (approved !== true) throw new TypeError("explicit publisher approval is required");
  const prepared = validatePreparation(preparation);
  const currentSourceRoot = await canonicalDirectory(prepared.source.root, "prepared source root");
  if (currentSourceRoot !== prepared.source.root) {
    throw new TypeError("prepared source root no longer resolves to the caller-attested path");
  }
  if (approvedSourceCommit !== prepared.source.commit) {
    throw new TypeError("approved source commit does not match prepared reviewed source pin");
  }
  canonicalIso(approvedAt, "approvedAt");
  const packageFiles = await rehydratePreparedBytes(prepared);

  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: CONTRACT_VERSION,
    approvalId,
    requestId: null,
    requestNonce: null,
    appId: prepared.revision.appId,
    projectId: prepared.revision.projectId,
    baseRevisionId: prepared.revision.baseRevisionId,
    approvedRevisionId: prepared.revision.revisionId,
    approvedContentHash: prepared.revision.contentHash,
    approvedAt,
  };
  contractValue(validateDeliveryApprovalV1(approval), "publisher approval");
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: CONTRACT_VERSION,
    envelopeId,
    deliveryNonce,
    approvalId: approval.approvalId,
    appId: prepared.revision.appId,
    projectId: prepared.revision.projectId,
    baseRevisionId: prepared.revision.baseRevisionId,
    revisionId: prepared.revision.revisionId,
    contentHash: prepared.revision.contentHash,
    issuedAt: approvedAt,
    revision: prepared.revision,
  };
  contractValue(validateDeliveryEnvelopeV1(envelope, { approval }), "publisher envelope");
  const pkg = {
    format: DELIVERY_PACKAGE_FORMAT,
    approval,
    envelope,
    files: packageFiles,
  };
  contractValue(await validateDeliveryPackageV1(pkg), "publisher package");
  const packageText = `${JSON.stringify(pkg, null, 2)}\n`;
  const rawPackageBytes = Buffer.byteLength(packageText, "utf8");
  if (rawPackageBytes > MAX_RAW_PACKAGE_BYTES) {
    throw new TypeError(`package JSON exceeds the ${MAX_RAW_PACKAGE_BYTES}-byte raw package limit`);
  }
  const packageBytes = Uint8Array.from(Buffer.from(packageText, "utf8"));
  const bareDescriptor = await descriptorFromPackageBytes(packageBytes, downloadUrl);
  if (
    bareDescriptor.appId !== prepared.app.appId
    || bareDescriptor.projectId !== prepared.app.projectId
    || bareDescriptor.revisionId !== prepared.revision.revisionId
    || bareDescriptor.contentHash !== prepared.revision.contentHash
  ) throw new TypeError("descriptor derived from package does not match prepared identity");
  const descriptor = appStoreMetadata !== null
    ? attachAppStoreMetadata(bareDescriptor, appStoreMetadata)
    : bareDescriptor;

  const receipt = Object.freeze({
    kind: "iris.mobile-shell.publisher-receipt",
    version: 1,
    approvedAt,
    preparationHash: prepared.preparationHash,
    source: {
      kind: prepared.source.kind,
      verification: prepared.source.verification,
      owner: prepared.source.owner,
      repo: prepared.source.repo,
      commit: prepared.source.commit,
    },
    app: prepared.app,
    package: {
      sha256: descriptor.packageSha256,
      bytes: descriptor.byteCount,
      revisionId: descriptor.revisionId,
      contentHash: descriptor.contentHash,
      requestedCapabilities: [...prepared.revision.manifest.capabilities],
      minShellVersion: prepared.revision.manifest.runtime.minShellVersion,
      dataNamespace: prepared.revision.manifest.data.namespace,
    },
    mobileShell: descriptor,
  });
  return Object.freeze({ package: pkg, packageBytes, descriptor, receipt });
}

export function assertLunaraPreparation(preparation) {
  const prepared = validatePreparation(preparation);
  if (
    prepared.app.slug !== "lunara"
    || prepared.source.owner !== LUNARA_REVIEWED_SOURCE.owner
    || prepared.source.repo !== LUNARA_REVIEWED_SOURCE.repo
    || prepared.source.commit !== LUNARA_REVIEWED_SOURCE.commit
  ) throw new TypeError("preparation is not bound to the reviewed Lunara source pin");
  if (!prepared.revision.manifest.capabilities.includes("web.storage")) {
    throw new TypeError("Lunara core preparation must declare durable web.storage");
  }
  return prepared;
}

export function isSHA256(value) {
  return typeof value === "string" && SHA256_PATTERN.test(value);
}
