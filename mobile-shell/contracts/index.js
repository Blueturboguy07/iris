/**
 * Iris mobile shell contract v1.
 *
 * Dependency-free and browser portable on purpose. Node is used only by the
 * test harness; production code relies on web-standard primitives.
 */

export const CONTRACT_VERSION = 1;
export const DELIVERY_PACKAGE_FORMAT = "iris.mobile-shell.package+json";
export const DELIVERY_PACKAGE_LIMITS = Object.freeze({
  maxFiles: 256,
  maxDecodedBytes: 32 * 1024 * 1024,
  maxSingleFileBytes: 16 * 1024 * 1024,
});

export const KNOWN_CAPABILITIES = Object.freeze([
  "native.camera",
  "native.haptics",
  "native.microphone",
  "native.photo-library",
  "native.share",
  "web.media.camera",
  "web.media.export",
  "web.media.microphone",
  "web.media.photo-picker",
  "web.navigation.external",
  "web.network.same-origin",
  "web.storage",
]);

const KNOWN_CAPABILITY_SET = new Set(KNOWN_CAPABILITIES);
const SHA256_PATTERN = /^sha256:[0-9a-f]{64}$/;
const REVISION_ID_PATTERN = /^rev-sha256:[0-9a-f]{64}$/;
const STABLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const OPAQUE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{7,159}$/;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{32,256}$/;
const SEMVER_PATTERN = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const MEDIA_TYPE_PATTERN = /^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/;

const MANIFEST_KEYS = [
  "kind", "version", "appId", "projectId", "displayName", "runtime", "capabilities", "data",
];
const RUNTIME_KEYS = ["type", "entrypoint", "minShellVersion"];
const DATA_KEYS = ["namespace", "updatePolicy"];
const REVISION_KEYS = [
  "kind", "version", "appId", "projectId", "revisionId", "baseRevisionId",
  "manifestHash", "contentHash", "createdAt", "manifest", "files",
];
// Contract v1.1 (SPEC docs/plans/20260928-all-routes/round3/mobile-versions/
// SPEC.md section 2.6, owner-decided 2026-09-28): the plain-words feature
// title(s) a revision carries, so the phone's Features page can read "Added:
// Dark mode" instead of "Update from <date>". Optional, not required, so
// every v1 hash computed before this addition is unchanged (see
// `revisionIdentityPayload`); a revision that DOES carry it has that field
// covered by `contentHash` like every other revision field, so a host that
// silently dropped or altered it would fail identity verification, not
// silently lose the title. `REVISION_OPTIONAL_KEYS` keeps `REVISION_KEYS`
// itself as the exact required-key list every existing test already checks.
const REVISION_OPTIONAL_KEYS = ["changes"];
const CHANGE_KEYS = ["title", "kind", "target"];
export const KNOWN_CHANGE_KINDS = Object.freeze(["added", "removed"]);
export const CHANGE_LIMITS = Object.freeze({ maxTitleChars: 120, maxChanges: 32 });
const FILE_KEYS = ["path", "sha256", "bytes", "mediaType"];
const EDIT_REQUEST_KEYS = [
  "kind", "version", "requestId", "nonce", "appId", "projectId", "baseRevisionId",
  "requestedAt", "intent",
];
const INTENT_KEYS = ["type", "text"];
const APPROVAL_KEYS = [
  "kind", "version", "approvalId", "requestId", "requestNonce", "appId", "projectId",
  "baseRevisionId", "approvedRevisionId", "approvedContentHash", "approvedAt",
];
const ENVELOPE_KEYS = [
  "kind", "version", "envelopeId", "deliveryNonce", "approvalId", "appId", "projectId",
  "baseRevisionId", "revisionId", "contentHash", "issuedAt", "revision",
];
const DELIVERY_PACKAGE_KEYS = ["approval", "envelope", "files", "format"];
const DELIVERY_FILE_BODY_KEYS = ["contentBase64", "mediaType", "path"];

function ok(value) {
  return { ok: true, value };
}

function fail(errors) {
  return { ok: false, errors: [...new Set(errors)] };
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function exactKeys(value, allowed, path, errors, optional = []) {
  if (!isPlainObject(value)) {
    errors.push(`${path} must be an object`);
    return false;
  }
  const allowedSet = new Set([...allowed, ...optional]);
  for (const key of Object.keys(value)) {
    if (!allowedSet.has(key)) errors.push(`${path}.${key} is not a v1 field`);
  }
  for (const key of allowed) {
    if (!(key in value)) errors.push(`${path}.${key} is required`);
  }
  return true;
}

function stableId(value) {
  return typeof value === "string" && STABLE_ID_PATTERN.test(value);
}

function opaqueId(value) {
  return typeof value === "string" && OPAQUE_ID_PATTERN.test(value);
}

function nonce(value) {
  return typeof value === "string" && NONCE_PATTERN.test(value);
}

function sha256(value) {
  return typeof value === "string" && SHA256_PATTERN.test(value);
}

function revisionId(value) {
  return typeof value === "string" && REVISION_ID_PATTERN.test(value);
}

function baseRevisionId(value) {
  return value === null || revisionId(value);
}

function semver(value) {
  return typeof value === "string" && SEMVER_PATTERN.test(value);
}

function isoInstant(value) {
  if (typeof value !== "string") return false;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === value;
}

export function isSafePackagePath(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 512) return false;
  if (value.startsWith("/") || value.startsWith("\\") || value.includes("\\")) return false;
  if (value.includes("?") || value.includes("#") || value.includes("%")) return false;
  if (value !== value.normalize("NFC")) return false;
  for (const scalar of value) {
    const codePoint = scalar.codePointAt(0);
    if (codePoint <= 0x1f || codePoint === 0x7f) return false;
  }
  const segments = value.split("/");
  if (segments.some((segment) => segment.length === 0 || segment === "." || segment === "..")) return false;
  return true;
}

function hasStoragePathAlias(paths) {
  const folded = paths.map((path) => path.normalize("NFC").toLowerCase());
  const seen = new Set();
  for (const path of folded) {
    if (seen.has(path)) return true;
    seen.add(path);
  }
  for (const path of folded) {
    const segments = path.split("/");
    for (let end = 1; end < segments.length; end += 1) {
      if (seen.has(segments.slice(0, end).join("/"))) return true;
    }
  }
  return false;
}

export function validateManifestV1(value) {
  const errors = [];
  if (!exactKeys(value, MANIFEST_KEYS, "manifest", errors)) return fail(errors);

  if (value.kind !== "iris.mobile-shell.manifest") errors.push("manifest.kind must be iris.mobile-shell.manifest");
  if (value.version !== CONTRACT_VERSION) errors.push("manifest.version must be 1");
  if (!stableId(value.appId)) errors.push("manifest.appId is invalid");
  if (!stableId(value.projectId)) errors.push("manifest.projectId is invalid");
  if (typeof value.displayName !== "string" || value.displayName.trim().length < 1 || value.displayName.length > 120) {
    errors.push("manifest.displayName is invalid");
  }

  if (exactKeys(value.runtime, RUNTIME_KEYS, "manifest.runtime", errors)) {
    if (value.runtime.type !== "web") errors.push("manifest.runtime.type must be web in v1");
    if (!isSafePackagePath(value.runtime.entrypoint)) errors.push("manifest.runtime.entrypoint is unsafe");
    if (!semver(value.runtime.minShellVersion)) errors.push("manifest.runtime.minShellVersion must be x.y.z");
  }

  if (!Array.isArray(value.capabilities)) {
    errors.push("manifest.capabilities must be an array");
  } else {
    const seen = new Set();
    for (const capability of value.capabilities) {
      if (!KNOWN_CAPABILITY_SET.has(capability)) errors.push(`manifest capability is unsupported: ${String(capability)}`);
      if (seen.has(capability)) errors.push(`manifest capability is duplicated: ${String(capability)}`);
      seen.add(capability);
    }
  }

  if (exactKeys(value.data, DATA_KEYS, "manifest.data", errors)) {
    if (!stableId(value.data.namespace)) errors.push("manifest.data.namespace is invalid");
    if (value.data.updatePolicy !== "preserve") errors.push("manifest.data.updatePolicy must be preserve in v1");
  }

  return errors.length ? fail(errors) : ok(value);
}

function validateFileRecord(file, index, errors) {
  const path = `revision.files[${index}]`;
  if (!exactKeys(file, FILE_KEYS, path, errors)) return;
  if (!isSafePackagePath(file.path)) errors.push(`${path}.path is unsafe`);
  if (!sha256(file.sha256)) errors.push(`${path}.sha256 is invalid`);
  if (!Number.isSafeInteger(file.bytes) || file.bytes < 0) errors.push(`${path}.bytes must be a nonnegative safe integer`);
  if (typeof file.mediaType !== "string" || !MEDIA_TYPE_PATTERN.test(file.mediaType)) errors.push(`${path}.mediaType is invalid`);
}

export function revisionIdForContentHash(contentHash) {
  if (!sha256(contentHash)) return null;
  return `rev-sha256:${contentHash.slice("sha256:".length)}`;
}

// `isBoundedDisplayString` is a hoisted `function` declaration defined later
// in this file (App Store metadata section); available here regardless of
// textual order.
function validateChangeRecord(change, index, errors) {
  const path = `revision.changes[${index}]`;
  if (!exactKeys(change, CHANGE_KEYS, path, errors)) return;
  if (!isBoundedDisplayString(change.title, CHANGE_LIMITS.maxTitleChars)) {
    errors.push(`${path}.title is invalid`);
  }
  if (!KNOWN_CHANGE_KINDS.includes(change.kind)) {
    errors.push(`${path}.kind must be added or removed`);
  }
  if (change.target !== null && !revisionId(change.target)) {
    errors.push(`${path}.target is invalid`);
  }
}

function validateChangesField(changes, errors) {
  if (changes === undefined) return;
  if (!Array.isArray(changes) || changes.length < 1 || changes.length > CHANGE_LIMITS.maxChanges) {
    errors.push("revision.changes must be a nonempty array");
    return;
  }
  changes.forEach((change, index) => validateChangeRecord(change, index, errors));
}

/**
 * Standalone validator for a `revision.changes` array (contract v1.1,
 * SPEC.md section 2.6), for a caller (the publisher) that wants to check a
 * `changes` argument before it ever reaches `createRevisionIdentity`,
 * without duplicating `CHANGE_KEYS`/`CHANGE_LIMITS`/`KNOWN_CHANGE_KINDS`
 * here. `undefined` (no `changes` at all) is valid -- the field is optional.
 */
export function validateRevisionChangesV1(changes) {
  const errors = [];
  validateChangesField(changes, errors);
  return errors.length ? fail(errors) : ok(changes);
}

export function validateRevisionV1(value) {
  const errors = [];
  if (!exactKeys(value, REVISION_KEYS, "revision", errors, REVISION_OPTIONAL_KEYS)) return fail(errors);
  validateChangesField(value.changes, errors);

  if (value.kind !== "iris.mobile-shell.revision") errors.push("revision.kind must be iris.mobile-shell.revision");
  if (value.version !== CONTRACT_VERSION) errors.push("revision.version must be 1");
  if (!stableId(value.appId)) errors.push("revision.appId is invalid");
  if (!stableId(value.projectId)) errors.push("revision.projectId is invalid");
  if (!revisionId(value.revisionId)) errors.push("revision.revisionId is invalid");
  if (!baseRevisionId(value.baseRevisionId)) errors.push("revision.baseRevisionId is invalid");
  if (!sha256(value.manifestHash)) errors.push("revision.manifestHash is invalid");
  if (!sha256(value.contentHash)) errors.push("revision.contentHash is invalid");
  if (!isoInstant(value.createdAt)) errors.push("revision.createdAt must be a canonical ISO instant");

  const manifestResult = validateManifestV1(value.manifest);
  if (!manifestResult.ok) errors.push(...manifestResult.errors.map((error) => `revision.${error}`));
  if (value.manifest?.appId !== value.appId) errors.push("revision.manifest.appId must equal revision.appId");
  if (value.manifest?.projectId !== value.projectId) errors.push("revision.manifest.projectId must equal revision.projectId");

  if (!Array.isArray(value.files) || value.files.length < 1) {
    errors.push("revision.files must contain at least one file");
  } else {
    const seenPaths = new Set();
    value.files.forEach((file, index) => {
      validateFileRecord(file, index, errors);
      if (isPlainObject(file) && typeof file.path === "string") {
        if (seenPaths.has(file.path)) errors.push(`revision.files contains duplicate path: ${file.path}`);
        seenPaths.add(file.path);
      }
    });
    if (typeof value.manifest?.runtime?.entrypoint === "string" && !seenPaths.has(value.manifest.runtime.entrypoint)) {
      errors.push("revision manifest entrypoint is absent from revision.files");
    }
    if (hasStoragePathAlias([...seenPaths])) {
      errors.push("revision.files contains a storage path alias");
    }
  }

  const expectedRevisionId = revisionIdForContentHash(value.contentHash);
  if (expectedRevisionId !== null && value.revisionId !== expectedRevisionId) {
    errors.push("revision.revisionId does not match revision.contentHash");
  }

  return errors.length ? fail(errors) : ok(value);
}

export function validateEditRequestV1(value, options = {}) {
  const errors = [];
  if (!exactKeys(value, EDIT_REQUEST_KEYS, "editRequest", errors)) return fail(errors);

  if (value.kind !== "iris.mobile-shell.edit-request") errors.push("editRequest.kind must be iris.mobile-shell.edit-request");
  if (value.version !== CONTRACT_VERSION) errors.push("editRequest.version must be 1");
  if (!opaqueId(value.requestId)) errors.push("editRequest.requestId is invalid");
  if (!nonce(value.nonce)) errors.push("editRequest.nonce is invalid");
  if (!stableId(value.appId)) errors.push("editRequest.appId is invalid");
  if (!stableId(value.projectId)) errors.push("editRequest.projectId is invalid");
  if (!revisionId(value.baseRevisionId)) errors.push("editRequest.baseRevisionId is invalid");
  if (!isoInstant(value.requestedAt)) errors.push("editRequest.requestedAt must be a canonical ISO instant");

  if (exactKeys(value.intent, INTENT_KEYS, "editRequest.intent", errors)) {
    if (value.intent.type !== "feature" && value.intent.type !== "bugfix") errors.push("editRequest.intent.type must be feature or bugfix");
    if (typeof value.intent.text !== "string" || value.intent.text.trim().length < 1 || value.intent.text.length > 4000) {
      errors.push("editRequest.intent.text is invalid");
    }
  }

  if (options.currentRevisionId !== undefined && value.baseRevisionId !== options.currentRevisionId) {
    errors.push("editRequest.baseRevisionId is stale");
  }
  if (options.usedNonces instanceof Set && options.usedNonces.has(value.nonce)) {
    errors.push("editRequest.nonce was already used");
  }

  return errors.length ? fail(errors) : ok(value);
}

export function validateDeliveryApprovalV1(value, options = {}) {
  const errors = [];
  if (!exactKeys(value, APPROVAL_KEYS, "approval", errors)) return fail(errors);

  if (value.kind !== "iris.mobile-shell.delivery-approval") errors.push("approval.kind must be iris.mobile-shell.delivery-approval");
  if (value.version !== CONTRACT_VERSION) errors.push("approval.version must be 1");
  if (!opaqueId(value.approvalId)) errors.push("approval.approvalId is invalid");
  if (!stableId(value.appId)) errors.push("approval.appId is invalid");
  if (!stableId(value.projectId)) errors.push("approval.projectId is invalid");
  if (!baseRevisionId(value.baseRevisionId)) errors.push("approval.baseRevisionId is invalid");
  if (!revisionId(value.approvedRevisionId)) errors.push("approval.approvedRevisionId is invalid");
  if (!sha256(value.approvedContentHash)) errors.push("approval.approvedContentHash is invalid");
  const expectedApprovedRevisionId = revisionIdForContentHash(value.approvedContentHash);
  if (expectedApprovedRevisionId !== null && value.approvedRevisionId !== expectedApprovedRevisionId) {
    errors.push("approval.approvedRevisionId does not match approval.approvedContentHash");
  }
  if (!isoInstant(value.approvedAt)) errors.push("approval.approvedAt must be a canonical ISO instant");

  const hasRequestId = value.requestId !== null;
  const hasRequestNonce = value.requestNonce !== null;
  if (hasRequestId !== hasRequestNonce) errors.push("approval.requestId and approval.requestNonce must both be null or both be present");
  if (hasRequestId && !opaqueId(value.requestId)) errors.push("approval.requestId is invalid");
  if (hasRequestNonce && !nonce(value.requestNonce)) errors.push("approval.requestNonce is invalid");

  if (options.editRequest !== undefined) {
    const requestResult = validateEditRequestV1(options.editRequest);
    if (!requestResult.ok) {
      errors.push("approval editRequest is invalid");
    } else if (
      value.requestId !== options.editRequest.requestId
      || value.requestNonce !== options.editRequest.nonce
      || value.appId !== options.editRequest.appId
      || value.projectId !== options.editRequest.projectId
      || value.baseRevisionId !== options.editRequest.baseRevisionId
    ) {
      errors.push("approval does not bind the supplied editRequest exactly");
    }
  }

  return errors.length ? fail(errors) : ok(value);
}

export function validateDeliveryEnvelopeV1(value, options = {}) {
  const errors = [];
  if (!exactKeys(value, ENVELOPE_KEYS, "envelope", errors)) return fail(errors);

  if (value.kind !== "iris.mobile-shell.delivery-envelope") errors.push("envelope.kind must be iris.mobile-shell.delivery-envelope");
  if (value.version !== CONTRACT_VERSION) errors.push("envelope.version must be 1");
  if (!opaqueId(value.envelopeId)) errors.push("envelope.envelopeId is invalid");
  if (!nonce(value.deliveryNonce)) errors.push("envelope.deliveryNonce is invalid");
  if (!opaqueId(value.approvalId)) errors.push("envelope.approvalId is invalid");
  if (!stableId(value.appId)) errors.push("envelope.appId is invalid");
  if (!stableId(value.projectId)) errors.push("envelope.projectId is invalid");
  if (!baseRevisionId(value.baseRevisionId)) errors.push("envelope.baseRevisionId is invalid");
  if (!revisionId(value.revisionId)) errors.push("envelope.revisionId is invalid");
  if (!sha256(value.contentHash)) errors.push("envelope.contentHash is invalid");
  if (!isoInstant(value.issuedAt)) errors.push("envelope.issuedAt must be a canonical ISO instant");

  const revisionResult = validateRevisionV1(value.revision);
  if (!revisionResult.ok) errors.push(...revisionResult.errors.map((error) => `envelope.${error}`));
  if (value.revision?.appId !== value.appId) errors.push("envelope appId does not match embedded revision");
  if (value.revision?.projectId !== value.projectId) errors.push("envelope projectId does not match embedded revision");
  if (value.revision?.baseRevisionId !== value.baseRevisionId) errors.push("envelope baseRevisionId does not match embedded revision");
  if (value.revision?.revisionId !== value.revisionId) errors.push("envelope revisionId does not match embedded revision");
  if (value.revision?.contentHash !== value.contentHash) errors.push("envelope contentHash does not match embedded revision");

  if (options.approval !== undefined) {
    const approvalResult = validateDeliveryApprovalV1(options.approval);
    if (!approvalResult.ok) {
      errors.push("envelope approval is invalid");
    } else if (
      value.approvalId !== options.approval.approvalId
      || value.appId !== options.approval.appId
      || value.projectId !== options.approval.projectId
      || value.baseRevisionId !== options.approval.baseRevisionId
      || value.revisionId !== options.approval.approvedRevisionId
      || value.contentHash !== options.approval.approvedContentHash
    ) {
      errors.push("envelope does not bind the supplied approval exactly");
    }
  }

  if (options.currentRevisionId !== undefined && value.baseRevisionId !== options.currentRevisionId) {
    errors.push("envelope.baseRevisionId is stale");
  }
  if (options.usedDeliveryNonces instanceof Set && options.usedDeliveryNonces.has(value.deliveryNonce)) {
    errors.push("envelope.deliveryNonce was already used");
  }

  return errors.length ? fail(errors) : ok(value);
}

function semverTuple(value) {
  const match = typeof value === "string" ? value.match(SEMVER_PATTERN) : null;
  return match ? [Number(match[1]), Number(match[2]), Number(match[3])] : null;
}

export function compareSemver(left, right) {
  const a = semverTuple(left);
  const b = semverTuple(right);
  if (!a || !b) return null;
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

/**
 * Contract v1.1 (SPEC.md section 2.6): the first shell version whose
 * validator understands `revision.changes` at all. A package that carries
 * `changes` but declares `manifest.runtime.minShellVersion` below this is
 * internally inconsistent (it claims to run on a shell whose strict
 * exact-key validator would reject the package outright over the unknown
 * field) -- `preparePublisherBuild` refuses that combination rather than
 * emitting a package no declared-compatible shell could actually install.
 * The real enforcement an old shell relies on is its own validator code
 * simply not recognizing `changes` (exact keys, fail closed); this constant
 * only keeps the publisher's own output internally consistent with that.
 */
export const FIRST_SHELL_VERSION_ACCEPTING_CHANGES = "1.1.0";

export function evaluateShellCompatibility(manifest, shell) {
  const manifestResult = validateManifestV1(manifest);
  if (!manifestResult.ok) return { ok: false, reasons: manifestResult.errors, unsupportedCapabilities: [] };

  const reasons = [];
  const unsupportedCapabilities = [];
  const versionComparison = compareSemver(shell?.version, manifest.runtime.minShellVersion);
  if (versionComparison === null) {
    reasons.push("shell version is invalid");
  } else if (versionComparison < 0) {
    reasons.push(`shell ${shell.version} is older than required ${manifest.runtime.minShellVersion}`);
  }

  const supported = new Set(Array.isArray(shell?.supportedCapabilities) ? shell.supportedCapabilities : []);
  for (const capability of manifest.capabilities) {
    if (!supported.has(capability)) unsupportedCapabilities.push(capability);
  }
  if (unsupportedCapabilities.length) reasons.push(`unsupported capabilities: ${unsupportedCapabilities.join(", ")}`);

  return { ok: reasons.length === 0, reasons, unsupportedCapabilities };
}

// --- App Store Guideline 4.7 metadata (m3-guideline47) -------------------
//
// AppStoreMetadataV1 is a deliberately separate, additive object. It is NOT
// a field of MobileShellManifestV1, MobileShellRevisionV1 or
// MobileShellDeliveryPackageV1: those four sealed v1 shapes keep their exact
// key sets so an old host cannot silently accept a new privilege by
// omission (see "v1 change rule" in CONTRACT.md). Guideline 4.7 metadata
// (age rating, privacy summary/policy, support/report contact) grants no
// capability and changes no execution behavior, so it travels as its own
// self-describing, independently versioned object that a caller attaches to
// the catalog-facing mobile-shell descriptor (see publisher/index.mjs
// attachAppStoreMetadata and website/integration.mjs). A descriptor with no
// AppStoreMetadataV1 remains a fully installable v1 descriptor; it is only
// not ready for an App Store 4.7 listing.
export const APP_STORE_METADATA_KIND = "iris.mobile-shell.app-store-metadata";
export const APP_STORE_METADATA_VERSION = 1;

// Apple App Store Connect's current age rating tiers, confirmed 2026-09-27
// against https://developer.apple.com/help/app-store-connect/reference/age-ratings/
// (4+, 9+, 13+, 16+, 18+; "Unrated" is not publishable on the App Store).
// This is Iris's own per-mini-app content rating for Guideline 4.7.5, not a
// substitute for the Iris Apps shell binary's own App Store Connect rating.
export const KNOWN_AGE_RATINGS = Object.freeze([4, 9, 13, 16, 18]);

export const APP_STORE_METADATA_LIMITS = Object.freeze({
  maxPrivacySummaryChars: 600,
  maxContactValueChars: 320,
  maxURLChars: 2048,
});

const AGE_RATING_SET = new Set(KNOWN_AGE_RATINGS);
const APP_STORE_METADATA_KEYS = [
  "kind", "version", "ageRating", "privacySummary", "privacyPolicyUrl", "supportContact", "reportContact",
];
const CONTACT_METHOD_KEYS = ["kind", "value"];
// RFC 5322 is intentionally not fully implemented; this is a bounded sanity
// check that rejects control characters, whitespace and multiple "@" signs
// rather than a claim of exhaustive email validity.
const EMAIL_PATTERN = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$/;

function isBoundedDisplayString(value, maxChars) {
  if (typeof value !== "string" || value.length < 1 || value.length > maxChars) return false;
  for (const scalar of value) {
    const codePoint = scalar.codePointAt(0);
    if (codePoint <= 0x1f || codePoint === 0x7f) return false;
  }
  return true;
}

function isHttpsURLString(value, maxChars) {
  if (!isBoundedDisplayString(value, maxChars)) return false;
  if (/[<>"']/.test(value)) return false;
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.protocol === "https:" && url.username === "" && url.password === "";
}

function validateContactMethod(value, path, errors) {
  if (!exactKeys(value, CONTACT_METHOD_KEYS, path, errors)) return;
  if (value.kind === "email") {
    if (
      !isBoundedDisplayString(value.value, APP_STORE_METADATA_LIMITS.maxContactValueChars)
      || !EMAIL_PATTERN.test(value.value)
    ) {
      errors.push(`${path}.value is not a valid email address`);
    }
  } else if (value.kind === "url") {
    if (!isHttpsURLString(value.value, APP_STORE_METADATA_LIMITS.maxURLChars)) {
      errors.push(`${path}.value must be an https URL`);
    }
  } else {
    errors.push(`${path}.kind must be "email" or "url"`);
  }
}

/**
 * Validates one Guideline 4.7 metadata object. Independent of, and never
 * substituted for, App Review's own acceptance of the Iris Apps shell.
 */
export function validateAppStoreMetadataV1(value) {
  const errors = [];
  if (!exactKeys(value, APP_STORE_METADATA_KEYS, "appStoreMetadata", errors)) return fail(errors);

  if (value.kind !== APP_STORE_METADATA_KIND) errors.push(`appStoreMetadata.kind must be ${APP_STORE_METADATA_KIND}`);
  if (value.version !== APP_STORE_METADATA_VERSION) errors.push("appStoreMetadata.version must be 1");
  if (!AGE_RATING_SET.has(value.ageRating)) {
    errors.push(`appStoreMetadata.ageRating must be one of ${KNOWN_AGE_RATINGS.join(", ")}`);
  }
  if (!isBoundedDisplayString(value.privacySummary, APP_STORE_METADATA_LIMITS.maxPrivacySummaryChars)) {
    errors.push("appStoreMetadata.privacySummary is invalid");
  }
  if (!isHttpsURLString(value.privacyPolicyUrl, APP_STORE_METADATA_LIMITS.maxURLChars)) {
    errors.push("appStoreMetadata.privacyPolicyUrl must be an https URL");
  }
  validateContactMethod(value.supportContact, "appStoreMetadata.supportContact", errors);
  validateContactMethod(value.reportContact, "appStoreMetadata.reportContact", errors);

  return errors.length ? fail(errors) : ok(value);
}

function canonicalValue(value) {
  if (Array.isArray(value)) return value.map(canonicalValue);
  if (!isPlainObject(value)) return value;
  const result = {};
  for (const key of Object.keys(value).sort()) result[key] = canonicalValue(value[key]);
  return result;
}

export function canonicalJSONString(value) {
  return JSON.stringify(canonicalValue(value));
}

// --- Catalog index v2 (m3-catalog-contract-scale) ------------------------
//
// This is the mobile "real app store" catalog surface: a paged index
// (`index.json`, `index-<n>.json`), a bounded category list
// (`categories.json`), and a per-app detail page (`apps/<slug>.json`). It is
// deliberately separate from MobileShellManifestV1 / RevisionV1 /
// DeliveryPackageV1 (the install/authenticity contract) and from
// AppStoreMetadataV1 (Guideline 4.7 metadata): this is catalog browsing and
// discovery data, served over plain cacheable HTTPS GET, never a privilege
// or an install authorization. A malformed or hostile catalog page can only
// make Browse show wrong/missing rows; it can never change what gets
// installed, since install always goes through the existing
// mobileShell descriptor -> verifyDeliveryPackageV1 path unchanged.
export const CATALOG_INDEX_V2_VERSION = 2;
export const CATALOG_APP_PAGE_V1_VERSION = 1;
export const CATALOG_CATEGORIES_V1_VERSION = 1;

export const CATALOG_V2_LIMITS = Object.freeze({
  appsPerPage: 250,
  // "At most 200 bytes per app" (SPEC R8). The budget counts what one app
  // contributes to the index: its values, measured as the UTF-8 bytes of the
  // entry written as one JSON array in schema order (see
  // catalogIndexEntryDataBytes). The 11 field names are identical for every
  // app, so they are a fixed cost per row (116 bytes more than the array
  // form, 147 with a placement object) rather than something an app can
  // grow. A budget over the whole serialized row could never be met: the
  // specified field names and JSON punctuation alone take 150 bytes.
  // The budget is binding: an app whose values do not fit must shorten its
  // summary or name, even if each field is inside its own per-field limit.
  maxAppEntryBytes: 200,
  maxCategories: 24,
  // Client-side download cap (mobile-shell/native PublikMobileCatalogClient);
  // kept here so the fixture generator and the publisher cannot silently
  // drift from what the client will actually accept.
  indexClientCapBytes: 2 * 1024 * 1024,
  // Largest package an index row may advertise: the same raw package limit
  // the publisher (MAX_RAW_PACKAGE_BYTES) and the iOS client
  // (DeliveryPackageV1Validator.maximumRawPackageBytes) enforce, so the store
  // can never show a size that the install path would refuse.
  maxPackageBytes: 48 * 1024 * 1024,
  maxScreenshotsPerApp: 6,
  maxScreenshotBytes: 400 * 1024,
  maxIconBytes: 64 * 1024,
  maxDescriptionChars: 4000,
  maxSummaryChars: 80,
  maxWhatsNewChars: 2000,
  maxPermissionLabelChars: 120,
  maxCategoryNameChars: 60,
});

export const KNOWN_CATALOG_BADGES = Object.freeze(["new", "updated"]);
const KNOWN_CATALOG_BADGE_SET = new Set(KNOWN_CATALOG_BADGES);

const CATALOG_INDEX_V2_KEYS = ["version", "generatedAt", "page", "pageCount", "apps"];
const CATALOG_INDEX_APP_KEYS = [
  "slug", "name", "summary", "categoryIds", "iconHash", "iconURL",
  "byteCount", "ageRating", "updatedAt", "badges", "placement",
];
const CATALOG_PLACEMENT_KEYS = ["featured", "sponsored", "label"];
const CATALOG_CATEGORIES_KEYS = ["categories"];
const CATALOG_CATEGORY_KEYS = ["id", "name", "order", "appCount"];
const CATALOG_APP_PAGE_KEYS = [
  "mobileShell", "description", "screenshots", "permissions",
  "privacySummary", "supportURL", "whatsNew",
];
const CATALOG_MOBILE_SHELL_KEYS = [
  "version", "platform", "packageFormat", "downloadUrl", "mediaType",
  "byteCount", "packageSha256", "appId", "projectId", "baseRevisionId",
  "revisionId", "contentHash", "appStoreMetadata",
];
const CATALOG_SCREENSHOT_KEYS = ["url", "bytes"];
const CATALOG_PERMISSION_KEYS = ["capability", "label"];

function isPublikHttpsURL(value, maxChars) {
  if (!isHttpsURLString(value, maxChars)) return false;
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  return url.hostname === "publikhq.com" && url.port === "";
}

function isNonNegativeSafeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

function isPositiveSafeInteger(value) {
  return Number.isSafeInteger(value) && value >= 1;
}

// A short, non-cryptographic change-detection token (first 16 hex characters
// of the icon bytes' sha256), not the full-length digest used elsewhere in
// this contract for install-time integrity. The icon is not part of the
// install security boundary (verifyDeliveryPackageV1 never reads it); this
// field only lets a client know an icon changed without re-fetching it, so a
// short token keeps the index entry small without weakening anything the
// install path relies on.
const ICON_HASH_PATTERN = /^[0-9a-f]{16}$/;
function isIconHash(value) {
  return typeof value === "string" && ICON_HASH_PATTERN.test(value);
}

// Index rows carry the update day, not an instant: Browse shows "Updated
// Sep 28" and the "new"/"updated" badges are day-grained, and a date is 14
// bytes shorter than an ISO instant inside the 200-byte per-app budget.
const CALENDAR_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;
function isCalendarDate(value) {
  if (typeof value !== "string" || !CALENDAR_DATE_PATTERN.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value;
}

/**
 * Bytes one app contributes to an index page: the entry's values written as
 * a single JSON array in schema order (`placement` as `[featured,
 * sponsored, label]` or `null`), UTF-8 encoded. This is the quantity
 * `CATALOG_V2_LIMITS.maxAppEntryBytes` (200) bounds. Returns
 * `Number.POSITIVE_INFINITY` for a value that is not an entry-shaped object,
 * so a hostile row can never pass the budget by failing to serialize.
 */
export function catalogIndexEntryDataBytes(entry) {
  if (!isPlainObject(entry)) return Number.POSITIVE_INFINITY;
  const placement = entry.placement;
  let placementTuple;
  if (placement === null) placementTuple = null;
  else if (isPlainObject(placement)) placementTuple = [placement.featured, placement.sponsored, placement.label];
  else return Number.POSITIVE_INFINITY;
  const tuple = CATALOG_INDEX_APP_KEYS.map((key) => (key === "placement" ? placementTuple : entry[key]));
  let text;
  try {
    text = JSON.stringify(tuple);
  } catch {
    return Number.POSITIVE_INFINITY;
  }
  if (typeof text !== "string") return Number.POSITIVE_INFINITY;
  return new TextEncoder().encode(text).byteLength;
}

// R2-CP-3 (round3-deferred/M-store-screens). `latestRevisionId` is an
// optional index-row field so My apps can show "Update available" without
// fetching the app's own page. It is deliberately kept OUT of
// `CATALOG_INDEX_APP_KEYS` / `CATALOG_INDEX_APP_KEYS`'s use in
// `catalogIndexEntryDataBytes` and `exactKeys`: those two are the fixed,
// documented 11-field row shape (the "116 bytes per row" / "147 with
// placement" budget comment above `CATALOG_V2_LIMITS`), and this unit does
// not own the byte-budget math or the publisher's emitter. Handled here
// instead, as a genuinely optional extra key: absent (an index published
// before this field existed, or a caller that has not adopted it yet) is
// valid, present-and-`null` is valid ("not known"), and present-and-a-
// string must be a real `rev-sha256:...` revision id -- never an arbitrary
// string a compromised catalog host could use to spoof "Update available"
// for an app it never actually built.
function validateLatestRevisionIdIfPresent(value, path, errors) {
  if (!("latestRevisionId" in value)) return;
  if (value.latestRevisionId !== null && !revisionId(value.latestRevisionId)) {
    errors.push(`${path}.latestRevisionId is invalid`);
  }
}

// RC-05 (round 6). `publisher` is an optional index-row field naming who made
// the app ("By Publik" on the app page and the consent sheet). Same handling as
// `latestRevisionId`: kept out of the fixed 11-field row shape and the 200 byte
// budget, absent is valid (older index; the iPhone shows Publik), and a present
// value must be a short plain name on one line: 1 to 80 characters, already
// trimmed, no control characters and no angle brackets, so a catalog host cannot
// smuggle markup or a look-alike name with hidden characters into the header.
export const CATALOG_PUBLISHER_MAX_CHARS = 80;
export function isCatalogPublisherName(value) {
  if (typeof value !== "string") return false;
  if (value.length < 1 || value.length > CATALOG_PUBLISHER_MAX_CHARS) return false;
  if (value !== value.trim()) return false;
  return !/[\u0000-\u001f\u007f-\u009f<>]/u.test(value);
}

function validatePublisherIfPresent(value, path, errors) {
  if (!("publisher" in value)) return;
  if (!isCatalogPublisherName(value.publisher)) {
    errors.push(`${path}.publisher must be 1 to ${CATALOG_PUBLISHER_MAX_CHARS} plain characters on one line`);
  }
}

function validateIndexAppEntry(value, index, errors) {
  const path = `apps[${index}]`;
  if (!isPlainObject(value)) {
    errors.push(`${path} must be an object`);
    return;
  }
  let keysOk = true;
  for (const key of Object.keys(value)) {
    if (key !== "latestRevisionId" && key !== "publisher" && !CATALOG_INDEX_APP_KEYS.includes(key)) {
      errors.push(`${path}.${key} is not a v1 field`);
      keysOk = false;
    }
  }
  for (const key of CATALOG_INDEX_APP_KEYS) {
    if (!(key in value)) {
      errors.push(`${path}.${key} is required`);
      keysOk = false;
    }
  }
  if (!keysOk) return;
  validateLatestRevisionIdIfPresent(value, path, errors);
  validatePublisherIfPresent(value, path, errors);
  if (!stableId(value.slug)) errors.push(`${path}.slug is invalid`);
  if (typeof value.name !== "string" || value.name.length < 1 || value.name.length > 120) {
    errors.push(`${path}.name is invalid`);
  }
  if (!isBoundedDisplayString(value.summary, CATALOG_V2_LIMITS.maxSummaryChars)) {
    errors.push(`${path}.summary is invalid`);
  }
  if (
    !Array.isArray(value.categoryIds)
    || value.categoryIds.length < 1
    || value.categoryIds.length > 3
    || new Set(value.categoryIds).size !== value.categoryIds.length
    || !value.categoryIds.every((id) => isPositiveSafeInteger(id) && id <= CATALOG_V2_LIMITS.maxCategories)
  ) {
    errors.push(`${path}.categoryIds is invalid`);
  }
  if (!isIconHash(value.iconHash)) errors.push(`${path}.iconHash is invalid`);
  if (!isPublikHttpsURL(value.iconURL, 2048)) errors.push(`${path}.iconURL must be an https publikhq.com URL`);
  if (!isPositiveSafeInteger(value.byteCount) || value.byteCount > CATALOG_V2_LIMITS.maxPackageBytes) {
    errors.push(`${path}.byteCount must be between 1 and ${CATALOG_V2_LIMITS.maxPackageBytes}`);
  }
  if (!AGE_RATING_SET.has(value.ageRating)) errors.push(`${path}.ageRating must be one of ${KNOWN_AGE_RATINGS.join(", ")}`);
  if (!isCalendarDate(value.updatedAt)) errors.push(`${path}.updatedAt must be a calendar date (YYYY-MM-DD)`);
  if (
    !Array.isArray(value.badges)
    || new Set(value.badges).size !== value.badges.length
    || !value.badges.every((badge) => KNOWN_CATALOG_BADGE_SET.has(badge))
  ) {
    errors.push(`${path}.badges is invalid`);
  }
  // null means "no special placement" (the common case for most catalog
  // apps); this keeps a typical entry's canonicalJSONString several bytes
  // smaller than always carrying a 3-key object of mostly-false/empty
  // values, without changing what a caller can express.
  if (value.placement !== null) {
    if (exactKeys(value.placement, CATALOG_PLACEMENT_KEYS, `${path}.placement`, errors)) {
      if (typeof value.placement.featured !== "boolean") errors.push(`${path}.placement.featured must be a boolean`);
      if (typeof value.placement.sponsored !== "boolean") errors.push(`${path}.placement.sponsored must be a boolean`);
      const labelRequired = value.placement.featured === true || value.placement.sponsored === true;
      if (labelRequired && !isBoundedDisplayString(value.placement.label, 40)) {
        errors.push(`${path}.placement.label is required when featured or sponsored is true`);
      } else if (!labelRequired && value.placement.label !== "" && !isBoundedDisplayString(value.placement.label, 40)) {
        errors.push(`${path}.placement.label is invalid`);
      }
      if (value.placement.featured === false && value.placement.sponsored === false) {
        errors.push(`${path}.placement should be null rather than an all-false object`);
      }
    }
  }
  const entryBytes = catalogIndexEntryDataBytes(value);
  if (entryBytes > CATALOG_V2_LIMITS.maxAppEntryBytes) {
    errors.push(
      `${path} uses ${Number.isFinite(entryBytes) ? entryBytes : "an unmeasurable number of"} bytes; `
      + `the limit is ${CATALOG_V2_LIMITS.maxAppEntryBytes} (shorten the summary or name)`,
    );
  }
}

/**
 * Validates one catalog index v2 page file (`index.json` is page 1;
 * `index-<n>.json` is page n for n in [2, pageCount]). Each page carries at
 * most `CATALOG_V2_LIMITS.appsPerPage` app entries; a 10,000-app catalog
 * must be split across at least 40 page files, and a single file that tries
 * to carry all 10,000 rows at once is rejected here by the per-page count
 * limit, not by a separate "too many apps" rule.
 */
export function validateCatalogIndexV2(value) {
  const errors = [];
  if (!exactKeys(value, CATALOG_INDEX_V2_KEYS, "index", errors)) return fail(errors);

  if (value.version !== CATALOG_INDEX_V2_VERSION) errors.push("index.version must be 2");
  if (!isoInstant(value.generatedAt)) errors.push("index.generatedAt must be a canonical ISO instant");
  if (!isPositiveSafeInteger(value.pageCount)) errors.push("index.pageCount is invalid");
  if (
    !isPositiveSafeInteger(value.page)
    || (isPositiveSafeInteger(value.pageCount) && value.page > value.pageCount)
  ) {
    errors.push("index.page is invalid");
  }
  if (!Array.isArray(value.apps) || value.apps.length > CATALOG_V2_LIMITS.appsPerPage) {
    errors.push(`index.apps must be an array of at most ${CATALOG_V2_LIMITS.appsPerPage} entries`);
  } else {
    const seenSlugs = new Set();
    value.apps.forEach((app, index) => {
      validateIndexAppEntry(app, index, errors);
      if (isPlainObject(app) && typeof app.slug === "string") {
        if (seenSlugs.has(app.slug)) errors.push(`apps[${index}].slug is a duplicate: ${app.slug}`);
        seenSlugs.add(app.slug);
      }
    });
  }
  return errors.length ? fail(errors) : ok(value);
}

/**
 * Validates `categories.json`: at most `CATALOG_V2_LIMITS.maxCategories`
 * (24) rows, unique ids, plain-language names.
 */
export function validateCatalogCategoriesV1(value) {
  const errors = [];
  if (!exactKeys(value, CATALOG_CATEGORIES_KEYS, "categories", errors)) return fail(errors);
  if (!Array.isArray(value.categories) || value.categories.length > CATALOG_V2_LIMITS.maxCategories) {
    errors.push(`categories.categories must be an array of at most ${CATALOG_V2_LIMITS.maxCategories} entries`);
  } else {
    const seenIds = new Set();
    value.categories.forEach((category, index) => {
      const path = `categories.categories[${index}]`;
      if (!exactKeys(category, CATALOG_CATEGORY_KEYS, path, errors)) return;
      if (!isPositiveSafeInteger(category.id)) errors.push(`${path}.id is invalid`);
      if (!isBoundedDisplayString(category.name, CATALOG_V2_LIMITS.maxCategoryNameChars)) {
        errors.push(`${path}.name is invalid`);
      }
      if (!isNonNegativeSafeInteger(category.order)) errors.push(`${path}.order is invalid`);
      if (!isNonNegativeSafeInteger(category.appCount)) errors.push(`${path}.appCount is invalid`);
      if (isPositiveSafeInteger(category.id)) {
        if (seenIds.has(category.id)) errors.push(`${path}.id is a duplicate: ${category.id}`);
        seenIds.add(category.id);
      }
    });
  }
  return errors.length ? fail(errors) : ok(value);
}

function validateCatalogMobileShell(value, errors) {
  if (!exactKeys(value, CATALOG_MOBILE_SHELL_KEYS, "appPage.mobileShell", errors)) return;
  if (value.version !== 1) errors.push("appPage.mobileShell.version must be 1");
  if (value.platform !== "ios") errors.push("appPage.mobileShell.platform must be ios");
  if (value.packageFormat !== DELIVERY_PACKAGE_FORMAT) errors.push("appPage.mobileShell.packageFormat is unsupported");
  if (!isPublikHttpsURL(value.downloadUrl, 2048)) errors.push("appPage.mobileShell.downloadUrl must be an https publikhq.com URL");
  if (value.mediaType !== "application/json") errors.push("appPage.mobileShell.mediaType is invalid");
  if (!isPositiveSafeInteger(value.byteCount)) errors.push("appPage.mobileShell.byteCount is invalid");
  if (!sha256(value.packageSha256)) errors.push("appPage.mobileShell.packageSha256 is invalid");
  if (!stableId(value.appId)) errors.push("appPage.mobileShell.appId is invalid");
  if (!stableId(value.projectId)) errors.push("appPage.mobileShell.projectId is invalid");
  if (!baseRevisionId(value.baseRevisionId)) errors.push("appPage.mobileShell.baseRevisionId is invalid");
  if (!revisionId(value.revisionId)) errors.push("appPage.mobileShell.revisionId is invalid");
  if (!sha256(value.contentHash) || revisionIdForContentHash(value.contentHash) !== value.revisionId) {
    errors.push("appPage.mobileShell.contentHash is invalid");
  }
  if (value.appStoreMetadata !== null) {
    const result = validateAppStoreMetadataV1(value.appStoreMetadata);
    if (!result.ok) errors.push(`appPage.mobileShell.appStoreMetadata is invalid: ${result.errors.join("; ")}`);
  }
}

/**
 * Validates one per-app detail page (`apps/<slug>.json`): the existing
 * mobileShell descriptor plus catalog/detail-page metadata (description,
 * screenshots, plain-language permissions, privacy summary, support URL,
 * what's new). The install path never reads this file; it re-verifies the
 * embedded `mobileShell` descriptor and downloaded package exactly as it
 * does for the v1 catalog today.
 */
export function validateCatalogAppPageV1(value) {
  const errors = [];
  if (!exactKeys(value, CATALOG_APP_PAGE_KEYS, "appPage", errors)) return fail(errors);
  validateCatalogMobileShell(value.mobileShell, errors);
  if (!isBoundedDisplayString(value.description, CATALOG_V2_LIMITS.maxDescriptionChars)) {
    errors.push("appPage.description is invalid");
  }
  if (!Array.isArray(value.screenshots) || value.screenshots.length > CATALOG_V2_LIMITS.maxScreenshotsPerApp) {
    errors.push(`appPage.screenshots must be an array of at most ${CATALOG_V2_LIMITS.maxScreenshotsPerApp} entries`);
  } else {
    value.screenshots.forEach((screenshot, index) => {
      const path = `appPage.screenshots[${index}]`;
      if (!exactKeys(screenshot, CATALOG_SCREENSHOT_KEYS, path, errors)) return;
      if (!isPublikHttpsURL(screenshot.url, 2048)) errors.push(`${path}.url must be an https publikhq.com URL`);
      if (!isPositiveSafeInteger(screenshot.bytes) || screenshot.bytes > CATALOG_V2_LIMITS.maxScreenshotBytes) {
        errors.push(`${path}.bytes must be at most ${CATALOG_V2_LIMITS.maxScreenshotBytes}`);
      }
    });
  }
  if (!Array.isArray(value.permissions)) {
    errors.push("appPage.permissions must be an array");
  } else {
    value.permissions.forEach((permission, index) => {
      const path = `appPage.permissions[${index}]`;
      if (!exactKeys(permission, CATALOG_PERMISSION_KEYS, path, errors)) return;
      if (!KNOWN_CAPABILITY_SET.has(permission.capability)) errors.push(`${path}.capability is unsupported`);
      if (!isBoundedDisplayString(permission.label, CATALOG_V2_LIMITS.maxPermissionLabelChars)) {
        errors.push(`${path}.label is invalid`);
      }
    });
  }
  if (!isBoundedDisplayString(value.privacySummary, APP_STORE_METADATA_LIMITS.maxPrivacySummaryChars)) {
    errors.push("appPage.privacySummary is invalid");
  }
  if (!isHttpsURLString(value.supportURL, APP_STORE_METADATA_LIMITS.maxURLChars)) {
    errors.push("appPage.supportURL must be an https URL");
  }
  if (value.whatsNew !== null && !isBoundedDisplayString(value.whatsNew, CATALOG_V2_LIMITS.maxWhatsNewChars)) {
    errors.push("appPage.whatsNew is invalid");
  }
  return errors.length ? fail(errors) : ok(value);
}

/**
 * Cross-checks one index row against its own `apps/<slug>.json` page. Both
 * documents must already be valid on their own. The row is what Browse
 * shows; the page's `mobileShell` descriptor is what install verifies, so
 * they must agree on the two facts a person acts on before tapping Get:
 * the download size (`byteCount`) and, when the descriptor carries App
 * Store metadata, the age rating that the age gate enforces.
 */
export function validateCatalogIndexEntryMatchesAppPage(entry, appPage) {
  const errors = [];
  const shell = appPage?.mobileShell;
  if (!isPlainObject(entry) || !isPlainObject(shell)) {
    return fail(["index row and app page are required"]);
  }
  if (entry.byteCount !== shell.byteCount) {
    errors.push(`${entry.slug}: index byteCount ${entry.byteCount} does not match the package size ${shell.byteCount}`);
  }
  if (isPlainObject(shell.appStoreMetadata) && shell.appStoreMetadata.ageRating !== entry.ageRating) {
    errors.push(
      `${entry.slug}: index ageRating ${entry.ageRating} does not match the reviewed age rating ${shell.appStoreMetadata.ageRating}`,
    );
  }
  return errors.length ? fail(errors) : ok({ entry, appPage });
}

function normalizedManifestForIdentity(manifest) {
  return {
    ...manifest,
    capabilities: [...manifest.capabilities].sort(),
  };
}

function compareCanonicalStrings(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function normalizedFilesForIdentity(files) {
  return [...files]
    .map(({ path, sha256: digest, bytes, mediaType }) => ({ path, sha256: digest, bytes, mediaType }))
    .sort((left, right) => compareCanonicalStrings(left.path, right.path));
}

function normalizedChangesForIdentity(changes) {
  // Order is meaningful (section 1.1: "the feature title the package
  // carries" reads `changes[0]`), so this only strips unknown keys and
  // normalizes a missing `target` to `null` -- it does not sort, unlike
  // `files` and `capabilities`, which have no meaningful order of their own.
  return changes.map(({ title, kind, target }) => ({ title, kind, target: target ?? null }));
}

function revisionIdentityPayload({ appId, projectId, baseRevisionId: baseId, manifest, files, changes }) {
  const payload = {
    appId,
    projectId,
    baseRevisionId: baseId,
    manifest: normalizedManifestForIdentity(manifest),
    files: normalizedFilesForIdentity(files),
  };
  // Omitted entirely (not even as `null`/`undefined`) when absent, so every
  // contentHash computed before contract v1.1 is bit-for-bit unchanged
  // (canonicalJSONString of an object without the key is identical to the
  // pre-v1.1 payload shape) and only a revision that actually carries
  // `changes` gets a different hash from one that does not.
  if (changes !== undefined) payload.changes = normalizedChangesForIdentity(changes);
  return payload;
}

function subtleCrypto(options) {
  const subtle = options?.subtle ?? globalThis.crypto?.subtle;
  if (!subtle || typeof subtle.digest !== "function") {
    throw new Error("Web Crypto SubtleCrypto is unavailable; pass { subtle } explicitly");
  }
  return subtle;
}

function asBytes(value) {
  if (typeof value === "string") return new TextEncoder().encode(value);
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  throw new TypeError("file content must be string, Uint8Array, ArrayBuffer, or ArrayBuffer view");
}

function hex(bytes) {
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function sha256Digest(value, options = {}) {
  const digest = await subtleCrypto(options).digest("SHA-256", asBytes(value));
  return `sha256:${hex(digest)}`;
}

export async function createRevisionIdentity(input, options = {}) {
  const manifestResult = validateManifestV1(input?.manifest);
  if (!manifestResult.ok) throw new TypeError(`invalid manifest: ${manifestResult.errors.join("; ")}`);
  if (!stableId(input?.appId) || input.appId !== input.manifest.appId) throw new TypeError("input appId must equal manifest.appId");
  if (!stableId(input?.projectId) || input.projectId !== input.manifest.projectId) throw new TypeError("input projectId must equal manifest.projectId");
  if (!baseRevisionId(input?.baseRevisionId)) throw new TypeError("input baseRevisionId is invalid");
  if (!Array.isArray(input?.files) || input.files.length < 1) throw new TypeError("input files are required");

  const fileErrors = [];
  const seenPaths = new Set();
  input.files.forEach((file, index) => {
    validateFileRecord(file, index, fileErrors);
    if (typeof file?.path === "string") {
      if (seenPaths.has(file.path)) fileErrors.push(`revision.files contains duplicate path: ${file.path}`);
      seenPaths.add(file.path);
    }
  });
  if (!seenPaths.has(input.manifest.runtime.entrypoint)) fileErrors.push("manifest entrypoint is absent from files");
  validateChangesField(input.changes, fileErrors);
  if (fileErrors.length) throw new TypeError(fileErrors.join("; "));

  const manifestHash = await sha256Digest(canonicalJSONString(normalizedManifestForIdentity(input.manifest)), options);
  const contentHash = await sha256Digest(canonicalJSONString(revisionIdentityPayload(input)), options);
  return {
    manifestHash,
    contentHash,
    revisionId: revisionIdForContentHash(contentHash),
  };
}

function fileContentEntries(fileContents) {
  if (fileContents instanceof Map) return [...fileContents.entries()];
  if (isPlainObject(fileContents)) return Object.entries(fileContents);
  return [];
}

function decodeCanonicalBase64(value, expectedBytes) {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new TypeError("file content is not canonical base64");
  }
  const expectedEncodedLength = 4 * Math.ceil(expectedBytes / 3);
  if (value.length !== expectedEncodedLength) {
    throw new TypeError("file base64 length does not match declared byte count");
  }
  if (typeof globalThis.atob === "function") {
    let binary;
    try {
      binary = globalThis.atob(value);
    } catch {
      throw new TypeError("file content is invalid base64");
    }
    const bytes = new Uint8Array(binary.length);
    for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
    let canonical = "";
    if (typeof globalThis.btoa === "function") {
      canonical = globalThis.btoa(binary);
    } else if (typeof globalThis.Buffer !== "undefined") {
      canonical = globalThis.Buffer.from(bytes).toString("base64");
    }
    if (canonical && canonical !== value) throw new TypeError("file content is not canonical base64");
    return bytes;
  }
  if (typeof globalThis.Buffer !== "undefined") {
    const buffer = globalThis.Buffer.from(value, "base64");
    if (buffer.toString("base64") !== value) throw new TypeError("file content is not canonical base64");
    return Uint8Array.from(buffer);
  }
  throw new TypeError("base64 decoding is unavailable");
}

export function validateDeliveryPackageV1(value) {
  const errors = [];
  if (!exactKeys(value, DELIVERY_PACKAGE_KEYS, "package", errors)) return fail(errors);
  if (value.format !== DELIVERY_PACKAGE_FORMAT) {
    errors.push(`package.format must be ${DELIVERY_PACKAGE_FORMAT}`);
  }
  const approvalResult = validateDeliveryApprovalV1(value.approval);
  if (!approvalResult.ok) errors.push(...approvalResult.errors.map((error) => `package.${error}`));
  const envelopeResult = validateDeliveryEnvelopeV1(
    value.envelope,
    approvalResult.ok ? { approval: approvalResult.value } : {},
  );
  if (!envelopeResult.ok) errors.push(...envelopeResult.errors.map((error) => `package.${error}`));

  const expectedFileCount = envelopeResult.ok ? envelopeResult.value.revision.files.length : null;
  if (!Array.isArray(value.files)) {
    errors.push("package.files must be an array");
  } else {
    if (expectedFileCount !== null && value.files.length !== expectedFileCount) {
      errors.push("package.files must exactly match revision.files");
    }
    if (value.files.length < 1 || value.files.length > DELIVERY_PACKAGE_LIMITS.maxFiles) {
      errors.push("package.files has an invalid file count");
    }
    const seen = new Set();
    value.files.forEach((file, index) => {
      const label = `package.files[${index}]`;
      if (!exactKeys(file, DELIVERY_FILE_BODY_KEYS, label, errors)) return;
      if (!isSafePackagePath(file.path)) errors.push(`Unsafe package path: ${String(file.path)}`);
      if (seen.has(file.path)) errors.push(`package contains duplicate delivered file: ${file.path}`);
      seen.add(file.path);
      if (typeof file.mediaType !== "string" || !MEDIA_TYPE_PATTERN.test(file.mediaType)) {
        errors.push(`${label}.mediaType is invalid`);
      }
      if (typeof file.contentBase64 !== "string") errors.push(`${label}.contentBase64 must be a string`);
    });
  }
  return errors.length ? fail(errors) : ok(value);
}

export async function verifyDeliveryPackageV1(value, options = {}) {
  const shape = validateDeliveryPackageV1(value);
  if (!shape.ok) return shape;
  const errors = [];

  const approvalResult = validateDeliveryApprovalV1(
    value.approval,
    options.editRequest !== undefined ? { editRequest: options.editRequest } : {},
  );
  if (!approvalResult.ok) errors.push(...approvalResult.errors.map((error) => `package.${error}`));

  const envelopeOptions = {};
  if (approvalResult.ok) envelopeOptions.approval = approvalResult.value;
  if (options.currentRevisionId !== undefined) envelopeOptions.currentRevisionId = options.currentRevisionId;
  if (options.usedDeliveryNonces instanceof Set) envelopeOptions.usedDeliveryNonces = options.usedDeliveryNonces;
  const envelopeResult = validateDeliveryEnvelopeV1(value.envelope, envelopeOptions);
  if (!envelopeResult.ok) errors.push(...envelopeResult.errors.map((error) => `package.${error}`));
  if (errors.length) return fail(errors);

  const approval = approvalResult.value;
  const envelope = envelopeResult.value;
  const revision = envelope.revision;
  if (!Array.isArray(value.files) || value.files.length !== revision.files.length) {
    errors.push("package.files must exactly match revision.files");
    return fail(errors);
  }
  if (value.files.length < 1 || value.files.length > DELIVERY_PACKAGE_LIMITS.maxFiles) {
    errors.push("package.files has an invalid file count");
    return fail(errors);
  }

  let declaredTotal = 0;
  const descriptors = new Map();
  for (const descriptor of revision.files) {
    if (descriptor.bytes > DELIVERY_PACKAGE_LIMITS.maxSingleFileBytes) {
      errors.push(`revision file exceeds single-file limit: ${descriptor.path}`);
    }
    declaredTotal += descriptor.bytes;
    if (declaredTotal > DELIVERY_PACKAGE_LIMITS.maxDecodedBytes) {
      errors.push("package exceeds decoded-byte limit");
    }
    descriptors.set(descriptor.path, descriptor);
  }
  const entrypointDescriptor = descriptors.get(revision.manifest.runtime.entrypoint);
  if (!entrypointDescriptor || entrypointDescriptor.mediaType !== "text/html") {
    errors.push("package entrypoint must be a delivered text/html file");
  }
  if (errors.length) return fail(errors);

  const contents = new Map();
  const verifiedFiles = [];
  for (let index = 0; index < value.files.length; index += 1) {
    const file = value.files[index];
    if (!exactKeys(file, DELIVERY_FILE_BODY_KEYS, `package.files[${index}]`, errors)) continue;
    if (!isSafePackagePath(file.path)) {
      errors.push(`package.files[${index}].path is unsafe`);
      continue;
    }
    if (contents.has(file.path)) {
      errors.push(`package contains duplicate delivered file: ${file.path}`);
      continue;
    }
    const descriptor = descriptors.get(file.path);
    if (!descriptor) {
      errors.push(`package contains undeclared file: ${file.path}`);
      continue;
    }
    if (file.mediaType !== descriptor.mediaType) {
      errors.push(`package file mediaType does not match revision metadata: ${file.path}`);
      continue;
    }
    let bytes;
    try {
      bytes = decodeCanonicalBase64(file.contentBase64, descriptor.bytes);
    } catch (error) {
      errors.push(`${file.path}: ${error.message}`);
      continue;
    }
    if (bytes.byteLength !== descriptor.bytes) {
      errors.push(`${file.path}: byte length does not match revision metadata`);
      continue;
    }
    contents.set(file.path, bytes);
    verifiedFiles.push({ path: file.path, mediaType: file.mediaType, bytes });
  }
  if (errors.length) return fail(errors);

  const integrity = await verifyRevisionIntegrity(revision, contents, options);
  if (!integrity.ok) errors.push(...integrity.errors.map((error) => `package.${error}`));
  if (errors.length) return fail(errors);

  return ok(Object.freeze({
    approval: Object.freeze({ ...approval }),
    envelope: Object.freeze({ ...envelope }),
    revision: Object.freeze({ ...revision }),
    manifest: Object.freeze({ ...revision.manifest }),
    files: verifiedFiles.map((file) => Object.freeze(file)),
  }));
}

export async function verifyRevisionIntegrity(revision, fileContents, options = {}) {
  const revisionResult = validateRevisionV1(revision);
  if (!revisionResult.ok) return { ok: false, errors: revisionResult.errors };

  const errors = [];
  const identity = await createRevisionIdentity(revision, options);
  if (revision.manifestHash !== identity.manifestHash) errors.push("revision.manifestHash does not match canonical manifest");
  if (revision.contentHash !== identity.contentHash) errors.push("revision.contentHash does not match canonical revision content");
  if (revision.revisionId !== identity.revisionId) errors.push("revision.revisionId does not match canonical revision content");

  const contentEntries = fileContentEntries(fileContents);
  const contentByPath = new Map(contentEntries);
  const expectedPaths = new Set(revision.files.map((file) => file.path));
  for (const [path] of contentEntries) {
    if (!expectedPaths.has(path)) errors.push(`unexpected delivered file: ${path}`);
  }

  for (const file of revision.files) {
    if (!contentByPath.has(file.path)) {
      errors.push(`missing delivered file: ${file.path}`);
      continue;
    }
    let bytes;
    try {
      bytes = asBytes(contentByPath.get(file.path));
    } catch (error) {
      errors.push(`${file.path}: ${error.message}`);
      continue;
    }
    if (bytes.byteLength !== file.bytes) errors.push(`${file.path}: byte length does not match revision metadata`);
    const digest = await sha256Digest(bytes, options);
    if (digest !== file.sha256) errors.push(`${file.path}: SHA-256 does not match revision metadata`);
  }

  return errors.length ? fail(errors) : ok(revision);
}
