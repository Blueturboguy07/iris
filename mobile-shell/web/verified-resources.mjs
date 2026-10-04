import {
  sha256Digest,
  verifyDeliveryPackageV1,
} from "../contracts/index.js";

const RESOURCE_TYPE_BY_EXTENSION = Object.freeze({
  ".css": "text/css",
  ".db": "application/octet-stream",
  ".html": "text/html",
  ".js": "text/javascript",
  ".json": "application/json",
  ".mjs": "text/javascript",
  ".otf": "font/otf",
  ".png": "image/png",
  ".ttf": "font/ttf",
  ".wasm": "application/wasm",
  ".webp": "image/webp",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
});

export const VERIFIED_RESOURCE_MIME_ALLOWLIST = Object.freeze([
  "application/json",
  "application/octet-stream",
  "application/wasm",
  "font/otf",
  "font/ttf",
  "font/woff",
  "font/woff2",
  "image/png",
  "image/webp",
  "text/css",
  "text/html",
  "text/javascript",
]);

const RESOURCE_MIME_SET = new Set(VERIFIED_RESOURCE_MIME_ALLOWLIST);
const SELECTION_KEYS = ["appId", "approvalId", "baseRevisionId", "contentHash", "projectId", "revisionId"];

export class VerifiedResourceIndexError extends Error {
  constructor(message, code = "invalid_resource_index") {
    super(message);
    this.name = "VerifiedResourceIndexError";
    this.code = code;
  }
}

function reject(message, code) {
  throw new VerifiedResourceIndexError(message, code);
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function canonicalResourcePath(path) {
  if (
    typeof path !== "string"
    || path.length < 1
    || path.length > 512
    || path.startsWith("/")
    || path.startsWith("\\")
    || path.includes("\\")
    || path.includes("%")
    || path.includes("?")
    || path.includes("#")
    || path !== path.normalize("NFC")
    || /[^A-Za-z0-9._~@/-]/.test(path)
  ) {
    reject("Resource path must be a canonical package-relative path", "invalid_path");
  }
  const segments = path.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) {
    reject("Resource path contains an unsafe segment", "invalid_path");
  }
  return path;
}

function validatePathTable(paths) {
  const exact = new Set();
  const folded = new Map();
  for (const rawPath of paths) {
    const path = canonicalResourcePath(rawPath);
    if (exact.has(path)) reject(`Duplicate resource path: ${path}`, "duplicate_path");
    const key = path.toLowerCase();
    if (folded.has(key)) reject(`Case-alias resource paths: ${folded.get(key)} and ${path}`, "path_alias");
    exact.add(path);
    folded.set(key, path);
  }
  for (const path of exact) {
    const segments = path.split("/");
    for (let index = 1; index < segments.length; index += 1) {
      const parent = segments.slice(0, index).join("/");
      if (folded.has(parent.toLowerCase())) {
        reject(`A resource file is also a parent directory: ${folded.get(parent.toLowerCase())} and ${path}`, "path_alias");
      }
    }
  }
  return folded;
}

function validateApprovedSelection(selection) {
  if (!isPlainObject(selection)) reject("A trusted approved selection is required", "unapproved_selection");
  const keys = Object.keys(selection).sort();
  if (keys.length !== SELECTION_KEYS.length || keys.some((key, index) => key !== SELECTION_KEYS[index])) {
    reject("Approved selection must bind app, project, base, revision, content, and approval", "unapproved_selection");
  }
  for (const key of SELECTION_KEYS) {
    if (key === "baseRevisionId") {
      if (selection[key] !== null && (typeof selection[key] !== "string" || !/^rev-sha256:[a-f0-9]{64}$/.test(selection[key]))) {
        reject("Approved selection base revision is invalid", "unapproved_selection");
      }
    } else if (typeof selection[key] !== "string" || selection[key].length === 0) {
      reject(`Approved selection ${key} is invalid`, "unapproved_selection");
    }
  }
  return Object.freeze(Object.fromEntries(SELECTION_KEYS.map((key) => [key, selection[key]])));
}

function assertSelectionMatches(selection, verified) {
  const revision = verified.revision;
  const expected = {
    approvalId: verified.approval.approvalId,
    appId: revision.appId,
    baseRevisionId: revision.baseRevisionId,
    contentHash: revision.contentHash,
    projectId: revision.projectId,
    revisionId: revision.revisionId,
  };
  for (const key of SELECTION_KEYS) {
    if (selection[key] !== expected[key]) {
      reject(`Approved selection ${key} does not match the verified package`, "unapproved_selection");
    }
  }
}

function validateMimeAllowlist(value) {
  if (!(Array.isArray(value) || value instanceof Set) || value.size === 0 && value instanceof Set || value.length === 0 && Array.isArray(value)) {
    reject("An explicit non-empty resource MIME allowlist is required", "invalid_mime_allowlist");
  }
  const result = new Set(value);
  if (result.size !== value.size && value instanceof Set) reject("Resource MIME allowlist contains duplicates", "invalid_mime_allowlist");
  if (result.size !== value.length && Array.isArray(value)) reject("Resource MIME allowlist contains duplicates", "invalid_mime_allowlist");
  for (const mime of result) {
    if (typeof mime !== "string" || !RESOURCE_MIME_SET.has(mime)) {
      reject(`Resource MIME type is not allowlisted: ${String(mime)}`, "unsupported_mime");
    }
  }
  return result;
}

function expectedMimeForPath(path) {
  const dot = path.lastIndexOf(".");
  const extension = dot < 0 ? "" : path.slice(dot).toLowerCase();
  return RESOURCE_TYPE_BY_EXTENSION[extension] ?? null;
}

function copyDescriptor(descriptor) {
  return Object.freeze({
    path: descriptor.path,
    mediaType: descriptor.mediaType,
    bytes: descriptor.bytes,
    sha256: descriptor.sha256,
  });
}

/**
 * Verify a delivery package and build an immutable, local-only resource index.
 *
 * `approvedSelection` must come from the trusted host's separate reader-review
 * receipt. This module verifies its exact binding to the package but does not
 * create or authenticate that receipt. The caller must also pass the active
 * `currentRevisionId` (including explicit null for a first install) and an
 * explicit MIME allowlist. Resource lookup never performs URL resolution or
 * remote fallback.
 */
export async function createVerifiedResourceIndex(transport, options = {}) {
  const {
    approvedSelection,
    currentRevisionId,
    allowedMimeTypes,
    subtle,
    usedDeliveryNonces,
  } = options;
  if (!Object.prototype.hasOwnProperty.call(options, "currentRevisionId")) {
    reject("The active base revision must be supplied explicitly", "missing_current_revision");
  }
  if (
    currentRevisionId !== null
    && (typeof currentRevisionId !== "string" || !/^rev-sha256:[a-f0-9]{64}$/.test(currentRevisionId))
  ) {
    reject("The active base revision is invalid", "invalid_current_revision");
  }
  const selection = validateApprovedSelection(approvedSelection);
  const allowedMimes = validateMimeAllowlist(allowedMimeTypes);
  let packageSnapshot;
  try {
    packageSnapshot = structuredClone(transport);
  } catch {
    reject("Delivery package must be a cloneable JSON transport", "invalid_transport");
  }
  const verifyOptions = { currentRevisionId };
  if (subtle !== undefined) verifyOptions.subtle = subtle;
  if (usedDeliveryNonces instanceof Set) verifyOptions.usedDeliveryNonces = usedDeliveryNonces;

  const result = await verifyDeliveryPackageV1(packageSnapshot, verifyOptions);
  if (!result?.ok) {
    const errors = Array.isArray(result?.errors) ? result.errors : ["Delivery package failed verification"];
    reject(errors.join("; "), "contract_rejected");
  }
  const verified = result.value;
  assertSelectionMatches(selection, verified);

  const revision = verified.revision;
  const descriptors = new Map();
  for (const descriptor of revision.files) {
    canonicalResourcePath(descriptor.path);
    const expectedMime = expectedMimeForPath(descriptor.path);
    if (!expectedMime || descriptor.mediaType !== expectedMime) {
      reject(`Resource path/MIME pair is not allowlisted: ${descriptor.path} (${descriptor.mediaType})`, "unsupported_resource");
    }
    if (!RESOURCE_MIME_SET.has(descriptor.mediaType)) {
      reject(`Resource MIME type is not allowlisted: ${descriptor.mediaType}`, "unsupported_mime");
    }
    descriptors.set(descriptor.path, descriptor);
  }
  const foldedPaths = validatePathTable([...descriptors.keys()]);
  const verifiedFiles = new Map(verified.files.map((file) => [file.path, file]));
  if (verifiedFiles.size !== descriptors.size) reject("Verified file set does not match the revision", "missing_file");
  const resourceBytes = new Map();
  for (const [path, descriptor] of descriptors) {
    const file = verifiedFiles.get(path);
    if (!file) reject(`Verified package is missing ${path}`, "missing_file");
    if (file.mediaType !== descriptor.mediaType || file.bytes.byteLength !== descriptor.bytes) {
      reject(`Verified resource metadata changed for ${path}`, "resource_mismatch");
    }
    const bytes = Uint8Array.from(file.bytes);
    const digest = await sha256Digest(bytes, subtle === undefined ? {} : { subtle });
    if (digest !== descriptor.sha256) reject(`Verified resource bytes changed for ${path}`, "hash_mismatch");
    resourceBytes.set(path, bytes);
  }

  const identity = Object.freeze({
    approvalId: verified.approval.approvalId,
    appId: revision.appId,
    baseRevisionId: revision.baseRevisionId,
    contentHash: revision.contentHash,
    projectId: revision.projectId,
    revisionId: revision.revisionId,
    entrypoint: revision.manifest.runtime.entrypoint,
  });
  const resourceList = Object.freeze([...descriptors.values()].map(copyDescriptor));

  return Object.freeze({
    identity,
    resources: resourceList,
    resolveResource(request) {
      if (!isPlainObject(request)) reject("Resource request must bind identity and path", "invalid_request");
      const keys = Object.keys(request).sort();
      const expectedKeys = ["appId", "path", "projectId", "revisionId"];
      if (keys.length !== expectedKeys.length || keys.some((key, index) => key !== expectedKeys[index])) {
        reject("Resource request must contain only appId, projectId, revisionId, and path", "invalid_request");
      }
      if (request.appId !== identity.appId || request.projectId !== identity.projectId || request.revisionId !== identity.revisionId) {
        reject("Resource request does not match the selected app revision", "unapproved_selection");
      }
      const path = canonicalResourcePath(request.path);
      const descriptor = descriptors.get(path);
      if (!descriptor) {
        const alias = foldedPaths.get(path.toLowerCase());
        if (alias) reject(`Resource path is not canonical; use ${alias}`, "path_alias");
        reject(`Resource is not present in the verified package: ${path}`, "not_found");
      }
      if (!allowedMimes.has(descriptor.mediaType)) {
        reject(`Resource MIME type was not approved by the host: ${descriptor.mediaType}`, "mime_not_approved");
      }
      return Object.freeze({
        appId: identity.appId,
        projectId: identity.projectId,
        revisionId: identity.revisionId,
        path,
        mediaType: descriptor.mediaType,
        bytes: descriptor.bytes,
        sha256: descriptor.sha256,
        content: Uint8Array.from(resourceBytes.get(path)),
      });
    },
  });
}
