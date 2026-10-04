import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  KNOWN_CAPABILITIES,
  evaluateShellCompatibility,
  validateDeliveryApprovalV1,
  validateDeliveryEnvelopeV1,
  validateEditRequestV1,
  validateRevisionV1,
  verifyDeliveryPackageV1,
  verifyRevisionIntegrity,
} from "../contracts/index.js";

export const SHELL_VERSION = "1.0.0";
export const PACKAGE_FORMAT = DELIVERY_PACKAGE_FORMAT;
export const SUPPORTED_WEB_CAPABILITIES = Object.freeze(["web.storage"]);

export const UNSUPPORTED_CAPABILITY_EXPLANATIONS = Object.freeze({
  "web.network.same-origin": "This first web shell runs app content on an opaque sandbox origin, so same-origin networking is unavailable.",
  "web.navigation.external": "App-controlled external navigation is disabled in this first web shell.",
  "web.media.camera": "Camera access is not exposed by this web-shell build.",
  "web.media.microphone": "Microphone access is not exposed by this web-shell build.",
  "web.media.photo-picker": "The browser photo-picker capability is not wired into this web-shell build.",
  "native.share": "Native share requires a reviewed native host capability.",
  "native.haptics": "Native haptics require a reviewed native host capability.",
  "native.camera": "Native camera access requires a reviewed native host capability and reader permission.",
  "native.microphone": "Native microphone access requires a reviewed native host capability and reader permission.",
  "native.photo-library": "Native photo-library access requires a reviewed native host capability and reader permission.",
});

export const ALLOWED_FILE_MIME = Object.freeze(new Set([
  "text/html",
  "text/css",
  "text/plain",
  "application/json",
  "image/png",
  "image/jpeg",
  "image/webp",
  "image/svg+xml",
  "audio/mpeg",
  "audio/mp4",
  "video/mp4",
]));

const APP_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const REVISION_ID_PATTERN = /^rev-sha256:[a-f0-9]{64}$/;
const SHA256_PATTERN = /^sha256:[a-f0-9]{64}$/;
const MAX_PACKAGE_FILES = 256;
const MAX_PACKAGE_BYTES = 32 * 1024 * 1024;
const MAX_SINGLE_FILE_BYTES = 16 * 1024 * 1024;

export class PackageValidationError extends Error {
  constructor(message, code = "invalid_package") {
    super(message);
    this.name = "PackageValidationError";
    this.code = code;
  }
}

export class UnsupportedCapabilityError extends Error {
  constructor(capabilities) {
    const names = capabilities.map((item) => item.capability).join(", ");
    super(`This web shell cannot provide: ${names}`);
    this.name = "UnsupportedCapabilityError";
    this.code = "unsupported_capability";
    this.capabilities = capabilities;
  }
}

const LOCAL_READER_APPROVAL_RECEIPTS = new WeakSet();

function assertPlainObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new PackageValidationError(`${label} must be an object`);
  }
  return value;
}

function contractValue(result, label) {
  if (!result?.ok) {
    const errors = Array.isArray(result?.errors) ? result.errors : [`${label} was rejected`];
    throw new PackageValidationError(errors.join("; "), "contract_rejected");
  }
  return result.value;
}

export function validateStableId(value, label = "identifier") {
  const identifier = String(value || "");
  if (!APP_ID_PATTERN.test(identifier)) {
    throw new PackageValidationError(`${label} is invalid`, "invalid_identifier");
  }
  return identifier;
}

export function validateAppId(value) {
  return validateStableId(value, "App ID");
}

export function validateRevisionId(value, { allowNull = false } = {}) {
  if (value === null && allowNull) return null;
  const revisionId = String(value || "");
  if (!REVISION_ID_PATTERN.test(revisionId)) {
    throw new PackageValidationError("Revision ID is invalid", "invalid_revision_id");
  }
  return revisionId;
}

export function validateContentHash(value) {
  const digest = String(value || "");
  if (!SHA256_PATTERN.test(digest)) {
    throw new PackageValidationError("Content hash is invalid", "invalid_hash");
  }
  return digest;
}

export function validateContentPath(value) {
  const path = String(value || "");
  if (!path || path.length > 512) {
    throw new PackageValidationError("Package file path is invalid", "invalid_path");
  }
  if (
    path.startsWith("/") ||
    path.startsWith("\\") ||
    path.includes("\\") ||
    path.includes("?") ||
    path.includes("#") ||
    path.includes("%") ||
    path !== path.normalize("NFC") ||
    /[\u0000-\u001f\u007f]/.test(path)
  ) {
    throw new PackageValidationError(`Unsafe package path: ${path}`, "invalid_path");
  }
  const segments = path.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) {
    throw new PackageValidationError(`Unsafe package path: ${path}`, "invalid_path");
  }
  return path;
}

export function validateMime(value) {
  const mime = String(value || "").toLowerCase().trim();
  if (!ALLOWED_FILE_MIME.has(mime)) {
    throw new PackageValidationError(`Unsupported package MIME type: ${mime || "missing"}`, "invalid_mime");
  }
  return mime;
}

export function base64ToBytes(value) {
  const encoded = String(value || "");
  if (!encoded || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new PackageValidationError("File content is not canonical base64", "invalid_base64");
  }
  if (typeof globalThis.atob === "function") {
    let binary;
    try {
      binary = globalThis.atob(encoded);
    } catch {
      throw new PackageValidationError("File content is invalid base64", "invalid_base64");
    }
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    return bytes;
  }
  if (typeof globalThis.Buffer !== "undefined") {
    const buffer = globalThis.Buffer.from(encoded, "base64");
    if (buffer.toString("base64") !== encoded) {
      throw new PackageValidationError("File content is not canonical base64", "invalid_base64");
    }
    return Uint8Array.from(buffer);
  }
  throw new PackageValidationError("Base64 decoding is unavailable", "unsupported_runtime");
}

export function bytesToBase64(bytes) {
  const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (typeof globalThis.btoa === "function") {
    let binary = "";
    for (const byte of data) binary += String.fromCharCode(byte);
    return globalThis.btoa(binary);
  }
  if (typeof globalThis.Buffer !== "undefined") return globalThis.Buffer.from(data).toString("base64");
  throw new PackageValidationError("Base64 encoding is unavailable", "unsupported_runtime");
}

export function assessCapabilities(capabilities, { shellVersion = SHELL_VERSION } = {}) {
  const requested = Array.isArray(capabilities) ? capabilities : [];
  const manifest = {
    kind: "iris.mobile-shell.manifest",
    version: CONTRACT_VERSION,
    appId: "iris.capability-check",
    projectId: "iris.capability-check",
    displayName: "Capability check",
    runtime: { type: "web", entrypoint: "index.html", minShellVersion: "0.0.0" },
    capabilities: requested,
    data: { namespace: "iris.capability-check", updatePolicy: "preserve" },
  };
  const compatibility = evaluateShellCompatibility(manifest, {
    version: shellVersion,
    supportedCapabilities: [...SUPPORTED_WEB_CAPABILITIES],
  });
  return compatibility.unsupportedCapabilities.map((capability) => ({
    capability,
    reason:
      UNSUPPORTED_CAPABILITY_EXPLANATIONS[capability] ||
      "This capability is not exposed by the current web shell.",
  }));
}

export function evaluateRevisionForWeb(revision) {
  const validated = contractValue(validateRevisionV1(revision), "Revision");
  const compatibility = evaluateShellCompatibility(validated.manifest, {
    version: SHELL_VERSION,
    supportedCapabilities: [...SUPPORTED_WEB_CAPABILITIES],
  });
  const packagingReasons = [];
  // The initial opaque srcdoc runtime intentionally supports one self-contained
  // HTML document. This keeps verified app bytes isolated from the shell origin
  // without pretending that sibling package files have a safe virtual origin.
  if (validated.files.length !== 1 || validated.files[0].path !== validated.manifest.runtime.entrypoint) {
    packagingReasons.push("web shell 1.0 requires a single self-contained HTML entry file");
  }
  return {
    revision: validated,
    compatible: compatibility.ok && packagingReasons.length === 0,
    reasons: [...compatibility.reasons, ...packagingReasons],
    unsupportedCapabilities: compatibility.unsupportedCapabilities.map((capability) => ({
      capability,
      reason:
        UNSUPPORTED_CAPABILITY_EXPLANATIONS[capability] ||
        "This capability is not exposed by the current web shell.",
    })),
  };
}

function packageTopLevel(transport) {
  const raw = assertPlainObject(transport, "Package");
  const keys = Object.keys(raw).sort();
  const expected = ["approval", "envelope", "files", "format"].sort();
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
    throw new PackageValidationError("Package transport has unknown or missing top-level fields", "invalid_transport");
  }
  if (raw.format !== PACKAGE_FORMAT) {
    throw new PackageValidationError(`Package format must be ${PACKAGE_FORMAT}`, "invalid_format");
  }
  return raw;
}

export async function verifyPackageTransport(
  transport,
  {
    currentRevisionId = undefined,
    usedDeliveryNonces = undefined,
    editRequest = undefined,
  } = {}
) {
  const sharedPackage = contractValue(
    await verifyDeliveryPackageV1(transport, {
      ...(currentRevisionId !== undefined ? { currentRevisionId } : {}),
      ...(usedDeliveryNonces instanceof Set ? { usedDeliveryNonces } : {}),
      ...(editRequest !== undefined ? { editRequest } : {}),
    }),
    "Delivery package"
  );
  const raw = packageTopLevel(transport);
  const approval = contractValue(
    validateDeliveryApprovalV1(raw.approval, editRequest ? { editRequest } : {}),
    "Delivery approval"
  );
  if (approval.requestId !== null && !editRequest) {
    throw new PackageValidationError(
      "This delivery references a phone edit request that is not present on this shell",
      "missing_edit_request"
    );
  }
  const envelopeOptions = { approval };
  if (currentRevisionId !== undefined) envelopeOptions.currentRevisionId = currentRevisionId;
  if (usedDeliveryNonces instanceof Set) envelopeOptions.usedDeliveryNonces = usedDeliveryNonces;
  const envelope = contractValue(
    validateDeliveryEnvelopeV1(raw.envelope, envelopeOptions),
    "Delivery envelope"
  );
  const revision = sharedPackage.revision;
  const webState = evaluateRevisionForWeb(revision);

  if (!Array.isArray(raw.files) || raw.files.length !== revision.files.length) {
    throw new PackageValidationError("Delivered file bodies do not match the revision table", "invalid_files");
  }
  if (raw.files.length === 0 || raw.files.length > MAX_PACKAGE_FILES) {
    throw new PackageValidationError("Package has an invalid file count", "invalid_files");
  }

  const descriptors = new Map();
  let declaredTotal = 0;
  for (const descriptor of revision.files) {
    const path = validateContentPath(descriptor.path);
    if (descriptors.has(path)) {
      throw new PackageValidationError(`Duplicate revision path: ${path}`, "duplicate_path");
    }
    const mediaType = validateMime(descriptor.mediaType);
    if (!Number.isSafeInteger(descriptor.bytes) || descriptor.bytes < 0 || descriptor.bytes > MAX_SINGLE_FILE_BYTES) {
      throw new PackageValidationError(`Invalid byte size for ${path}`, "invalid_size");
    }
    declaredTotal += descriptor.bytes;
    if (declaredTotal > MAX_PACKAGE_BYTES) {
      throw new PackageValidationError("Package exceeds the web-shell size limit", "package_too_large");
    }
    descriptors.set(path, { ...descriptor, path, mediaType });
  }
  const entrypoint = validateContentPath(revision.manifest.runtime.entrypoint);
  if (!descriptors.has(entrypoint) || descriptors.get(entrypoint).mediaType !== "text/html") {
    throw new PackageValidationError("Web revision entrypoint must be a delivered text/html file", "invalid_entry");
  }

  const contents = new Map();
  const verifiedFiles = [];
  for (const fileRaw of raw.files) {
    const file = assertPlainObject(fileRaw, "Delivered file");
    const keys = Object.keys(file).sort();
    const expected = ["contentBase64", "mediaType", "path"].sort();
    if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
      throw new PackageValidationError("Delivered file body has unknown or missing fields", "invalid_file_body");
    }
    const path = validateContentPath(file.path);
    if (contents.has(path)) throw new PackageValidationError(`Duplicate delivered file: ${path}`, "duplicate_path");
    const descriptor = descriptors.get(path);
    if (!descriptor) throw new PackageValidationError(`Delivered file is not declared: ${path}`, "undeclared_file");
    const mediaType = validateMime(file.mediaType);
    if (mediaType !== descriptor.mediaType) {
      throw new PackageValidationError(`Media type mismatch for ${path}`, "mime_mismatch");
    }
    const bytes = base64ToBytes(file.contentBase64);
    if (bytes.byteLength !== descriptor.bytes) {
      throw new PackageValidationError(`Byte-size mismatch for ${path}`, "size_mismatch");
    }
    contents.set(path, bytes);
    verifiedFiles.push({ path, mime: mediaType, bytes });
  }
  const integrity = await verifyRevisionIntegrity(revision, contents);
  contractValue(integrity, "Revision integrity");

  const entryBytes = contents.get(entrypoint);
  if (webState.compatible && entryBytes) {
    let entrySource;
    try {
      entrySource = new TextDecoder("utf-8", { fatal: true }).decode(entryBytes);
    } catch {
      throw new PackageValidationError("Web entry HTML must be valid UTF-8", "invalid_entry_encoding");
    }
    // A self-contained revision must not rely on URL-bearing sibling or remote
    // resources. The sandbox CSP also blocks network access at execution time.
    if (/<(?:script|img|audio|video|source|iframe)\b[^>]*\bsrc\s*=|<link\b[^>]*\bhref\s*=|\bsrcset\s*=|url\s*\(/i.test(entrySource)) {
      throw new PackageValidationError(
        "Web shell 1.0 entry HTML must be self-contained; external or sibling resource URLs are not supported",
        "unsupported_package_shape"
      );
    }
  }

  return Object.freeze({
    approval: Object.freeze({ ...approval }),
    envelope: Object.freeze({ ...envelope }),
    revision: Object.freeze({ ...revision }),
    manifest: Object.freeze({ ...revision.manifest }),
    files: verifiedFiles,
    compatible: webState.compatible,
    compatibilityReasons: [...webState.reasons],
    unsupportedCapabilities: webState.unsupportedCapabilities,
    verifiedAt: new Date().toISOString(),
  });
}

function localApprovalBinding(verifiedPackage) {
  return {
    approvalId: String(verifiedPackage?.approval?.approvalId || ""),
    appId: String(verifiedPackage?.revision?.appId || ""),
    projectId: String(verifiedPackage?.revision?.projectId || ""),
    baseRevisionId: verifiedPackage?.revision?.baseRevisionId ?? null,
    revisionId: String(verifiedPackage?.revision?.revisionId || ""),
    contentHash: String(verifiedPackage?.revision?.contentHash || ""),
    deliveryNonce: String(verifiedPackage?.envelope?.deliveryNonce || ""),
  };
}

export function authorizeVerifiedPackageForLocalStorage(verifiedPackage) {
  const binding = localApprovalBinding(verifiedPackage);
  if (!binding.approvalId || !binding.appId || !binding.projectId || !binding.revisionId || !binding.contentHash || !binding.deliveryNonce) {
    throw new PackageValidationError("Verified package is incomplete for local approval", "invalid_local_approval");
  }
  const receipt = Object.freeze({ kind: "iris.mobile-shell.local-reader-approval", ...binding });
  LOCAL_READER_APPROVAL_RECEIPTS.add(receipt);
  return receipt;
}

export function consumeLocalReaderApproval(verifiedPackage, receipt) {
  if (!receipt || !LOCAL_READER_APPROVAL_RECEIPTS.has(receipt)) {
    throw new PackageValidationError("A separate local reader approval is required before storing this delivery", "local_approval_required");
  }
  const expected = localApprovalBinding(verifiedPackage);
  for (const [key, value] of Object.entries(expected)) {
    if (receipt[key] !== value) {
      throw new PackageValidationError("Local reader approval does not bind this exact delivery", "local_approval_mismatch");
    }
  }
  LOCAL_READER_APPROVAL_RECEIPTS.delete(receipt);
  return true;
}

export function validateRevisionTransition(activeRevision, candidateRevision) {
  const candidate = contractValue(validateRevisionV1(candidateRevision), "Candidate revision");
  if (!activeRevision) {
    if (candidate.baseRevisionId !== null) {
      throw new PackageValidationError("First install must have a null base revision", "wrong_base_revision");
    }
    return true;
  }
  const active = contractValue(validateRevisionV1(activeRevision), "Active revision");
  if (candidate.appId !== active.appId) {
    throw new PackageValidationError("Candidate revision belongs to a different app", "wrong_app");
  }
  if (candidate.projectId !== active.projectId) {
    throw new PackageValidationError("Candidate revision belongs to a different editable project", "wrong_project");
  }
  if (candidate.baseRevisionId !== active.revisionId) {
    throw new PackageValidationError(`Candidate base revision must be ${active.revisionId}`, "wrong_base_revision");
  }
  if (candidate.revisionId === active.revisionId) {
    throw new PackageValidationError("Candidate revision is already active", "duplicate_revision");
  }
  if (candidate.manifest.data.namespace !== active.manifest.data.namespace) {
    throw new PackageValidationError(
      "v1 updates must preserve the existing user-data namespace",
      "userdata_namespace_changed"
    );
  }
  return true;
}

export function userDataDatabaseName(appId, projectId, namespace) {
  const app = validateStableId(appId, "User-data app id");
  const project = validateStableId(projectId, "User-data project id");
  const dataNamespace = validateStableId(namespace, "User-data namespace");
  return `iris-mobile-userdata-v1-${app}--${project}--${dataNamespace}`;
}

function randomHex(byteCount) {
  const bytes = new Uint8Array(byteCount);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export function makeEditRequest(
  {
    appId,
    projectId,
    baseRevisionId,
    intentType = "feature",
    intentText,
    requestedAt = new Date().toISOString(),
  },
  { usedNonces = undefined } = {}
) {
  const request = {
    kind: "iris.mobile-shell.edit-request",
    version: CONTRACT_VERSION,
    requestId: `req_${randomHex(12)}`,
    nonce: randomHex(24),
    appId: validateAppId(appId),
    projectId: validateStableId(projectId, "Project ID"),
    baseRevisionId: validateRevisionId(baseRevisionId),
    requestedAt,
    intent: {
      type: intentType,
      text: String(intentText || "").trim(),
    },
  };
  return contractValue(
    validateEditRequestV1(request, {
      currentRevisionId: request.baseRevisionId,
      ...(usedNonces instanceof Set ? { usedNonces } : {}),
    }),
    "Edit request"
  );
}

export function validateStoredEditRequest(request, currentRevisionId, usedNonces = undefined) {
  return contractValue(
    validateEditRequestV1(request, {
      currentRevisionId,
      ...(usedNonces instanceof Set ? { usedNonces } : {}),
    }),
    "Edit request"
  );
}

export function packageSummary(verifiedPackage) {
  const revision = verifiedPackage?.revision;
  const manifest = revision?.manifest;
  contractValue(validateRevisionV1(revision), "Revision");
  return Object.freeze({
    appId: revision.appId,
    projectId: revision.projectId,
    name: manifest.displayName,
    revisionId: revision.revisionId,
    baseRevisionId: revision.baseRevisionId,
    contentHash: revision.contentHash,
    capabilities: [...manifest.capabilities],
    compatible: Boolean(verifiedPackage.compatible),
    unsupportedCapabilities: [...(verifiedPackage.unsupportedCapabilities || [])],
  });
}

export function parsePackageJson(text) {
  try {
    return packageTopLevel(JSON.parse(String(text)));
  } catch (error) {
    if (error instanceof PackageValidationError) throw error;
    throw new PackageValidationError("Package file is not valid JSON", "invalid_json");
  }
}

export function serializeVerifiedPackage(verifiedPackage) {
  return JSON.stringify(
    {
      format: PACKAGE_FORMAT,
      approval: verifiedPackage.approval,
      envelope: verifiedPackage.envelope,
      files: verifiedPackage.files.map((file) => ({
        path: validateContentPath(file.path),
        mediaType: validateMime(file.mime),
        contentBase64: bytesToBase64(file.bytes),
      })),
    },
    null,
    2
  );
}

export const contractInfo = Object.freeze({
  version: CONTRACT_VERSION,
  knownCapabilities: [...KNOWN_CAPABILITIES],
});
