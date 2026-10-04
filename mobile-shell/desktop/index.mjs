import { randomBytes } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { lstat, open, readdir, realpath } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  createRevisionIdentity,
  isSafePackagePath,
  sha256Digest,
  validateDeliveryApprovalV1,
  validateDeliveryEnvelopeV1,
  validateEditRequestV1,
  validateManifestV1,
  validateRevisionV1,
  verifyRevisionIntegrity,
} from "../contracts/index.js";
import { verifyPackageTransport } from "../web/runtime.mjs";
import { DurableReceiptStore, ReceiptReplayError } from "./receipts.mjs";

export { DurableReceiptStore, ReceiptReplayError } from "./receipts.mjs";

const REGISTRATION_KEYS = ["appId", "appSlug", "kind", "projectId", "provenance", "version"];
const PROVENANCE_KEYS = ["canonicalRepo", "clonePath", "kind", "pinnedCommit"];
const REVIEW_KEYS = ["baseRevisionId", "files", "kind", "manifest", "reviewedAt", "version"];
const REVIEW_FILE_KEYS = ["mediaType", "path"];
const STAGE_KEYS = [
  "appId",
  "baseRevisionId",
  "files",
  "kind",
  "projectId",
  "revision",
  "stageId",
  "stagedAt",
  "version",
];
const STAGE_FILE_KEYS = ["contentBase64", "mediaType", "path"];
const APPROVED_STAGE_KEYS = ["approval", "editRequest", "kind", "stage", "version"];
const STABLE_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const REVISION_ID_PATTERN = /^rev-sha256:[0-9a-f]{64}$/;
const MEDIA_TYPE_PATTERN = /^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+$/;

function exactKeys(value, keys, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new TypeError(`${label} has unknown or missing fields`);
  }
  return value;
}

function contractValue(result, label) {
  if (!result?.ok) throw new TypeError(`${label}: ${(result?.errors || ["rejected"]).join("; ")}`);
  return result.value;
}

function canonicalIso(value, label) {
  if (typeof value !== "string") throw new TypeError(`${label} must be a canonical ISO instant`);
  const parsed = new Date(value);
  if (!Number.isFinite(parsed.getTime()) || parsed.toISOString() !== value) {
    throw new TypeError(`${label} must be a canonical ISO instant`);
  }
  return value;
}

function validateStableId(value, label) {
  if (typeof value !== "string" || !STABLE_ID_PATTERN.test(value)) throw new TypeError(`${label} is invalid`);
  return value;
}

function validateBaseRevisionId(value, label = "baseRevisionId") {
  if (value === null) return null;
  if (typeof value !== "string" || !REVISION_ID_PATTERN.test(value)) throw new TypeError(`${label} is invalid`);
  return value;
}

function randomHex(bytes = 24) {
  return randomBytes(bytes).toString("hex");
}

function bytesToCanonicalBase64(bytes) {
  return Buffer.from(bytes).toString("base64");
}

function base64ToBytes(value, label) {
  if (typeof value !== "string" || value.length === 0 || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new TypeError(`${label} is not canonical base64`);
  }
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value) throw new TypeError(`${label} is not canonical base64`);
  return Uint8Array.from(bytes);
}

export function validateRegisteredProject(value) {
  const record = exactKeys(value, REGISTRATION_KEYS, "registered project");
  if (record.kind !== "iris.mobile-shell.desktop-project" || record.version !== 1) {
    throw new TypeError("registered project kind/version is unsupported");
  }
  validateStableId(record.appId, "registered project appId");
  validateStableId(record.projectId, "registered project projectId");
  validateStableId(record.appSlug, "registered project appSlug");
  const provenance = exactKeys(record.provenance, PROVENANCE_KEYS, "registered project provenance");
  if (provenance.kind !== "guideSourceClone") {
    throw new TypeError("registered project must carry guideSourceClone provenance");
  }
  if (typeof provenance.clonePath !== "string" || !isAbsolute(provenance.clonePath)) {
    throw new TypeError("registered project provenance clonePath must be absolute");
  }
  if (typeof provenance.pinnedCommit !== "string" || !/^[0-9a-fA-F]{7,64}$/.test(provenance.pinnedCommit)) {
    throw new TypeError("registered project provenance pinnedCommit is invalid");
  }
  if (provenance.canonicalRepo !== null && (typeof provenance.canonicalRepo !== "string" || !/^[^/\s]+\/[^/\s]+$/.test(provenance.canonicalRepo))) {
    throw new TypeError("registered project provenance canonicalRepo is invalid");
  }
  return record;
}

export function validatePackageReview(value, registration, currentRevisionId) {
  const trusted = validateRegisteredProject(registration);
  const review = exactKeys(value, REVIEW_KEYS, "package review");
  if (review.kind !== "iris.mobile-shell.desktop-package-review" || review.version !== 1) {
    throw new TypeError("package review kind/version is unsupported");
  }
  canonicalIso(review.reviewedAt, "package review reviewedAt");
  const manifest = contractValue(validateManifestV1(review.manifest), "package review manifest");
  if (manifest.appId !== trusted.appId || manifest.projectId !== trusted.projectId) {
    throw new TypeError("package review manifest belongs to the wrong app/project");
  }
  const currentBase = validateBaseRevisionId(currentRevisionId, "current revision");
  const reviewedBase = validateBaseRevisionId(review.baseRevisionId, "package review baseRevisionId");
  if (reviewedBase !== currentBase) throw new TypeError("package review baseRevisionId is stale");
  if (!Array.isArray(review.files) || review.files.length < 1) throw new TypeError("package review files are required");

  const seen = new Set();
  for (const file of review.files) {
    exactKeys(file, REVIEW_FILE_KEYS, "package review file");
    if (!isSafePackagePath(file.path)) throw new TypeError(`package review file path is unsafe: ${String(file.path)}`);
    if (seen.has(file.path)) throw new TypeError(`package review contains duplicate file: ${file.path}`);
    seen.add(file.path);
    if (typeof file.mediaType !== "string" || !MEDIA_TYPE_PATTERN.test(file.mediaType)) {
      throw new TypeError(`package review media type is invalid for ${file.path}`);
    }
  }
  if (!seen.has(manifest.runtime.entrypoint)) {
    throw new TypeError("package review does not include the manifest entrypoint");
  }
  return review;
}

function normalizeRelativePath(root, absolutePath) {
  const rel = relative(root, absolutePath).split(sep).join("/");
  if (!isSafePackagePath(rel)) throw new TypeError(`unsafe build-output path: ${rel || absolutePath}`);
  return rel;
}

async function walkBuildRoot(root) {
  if (typeof root !== "string" || !isAbsolute(root)) throw new TypeError("build-output root must be an absolute path");
  const rootPath = resolve(root);
  const rootInfo = await lstat(rootPath);
  if (rootInfo.isSymbolicLink()) throw new TypeError("build-output root may not be a symlink");
  if (!rootInfo.isDirectory()) throw new TypeError("build-output root must be a directory");
  const canonicalRoot = await realpath(rootPath);
  const files = [];

  async function visit(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    for (const entry of entries) {
      const absolutePath = join(directory, entry.name);
      const rel = normalizeRelativePath(canonicalRoot, absolutePath);
      if (entry.isSymbolicLink()) throw new TypeError(`build-output path may not be a symlink: ${rel}`);
      if (entry.isDirectory()) {
        await visit(absolutePath);
        continue;
      }
      if (!entry.isFile()) throw new TypeError(`build-output path must be a regular file: ${rel}`);
      const real = await realpath(absolutePath);
      if (real !== canonicalRoot && !real.startsWith(`${canonicalRoot}${sep}`)) {
        throw new TypeError(`build-output file escapes root: ${rel}`);
      }
      files.push({ path: rel, absolutePath });
    }
  }

  await visit(canonicalRoot);
  files.sort((left, right) => left.path.localeCompare(right.path));
  return { root: canonicalRoot, files };
}

async function readRegularFileNoFollow(path, label) {
  const flags = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW || 0);
  let handle;
  try {
    handle = await open(path, flags);
    const info = await handle.stat();
    if (!info.isFile()) throw new TypeError(`${label} must remain a regular file`);
    return Uint8Array.from(await handle.readFile());
  } finally {
    await handle?.close();
  }
}

function compareReviewedFiles(actual, reviewFiles) {
  const actualSet = new Set(actual.map((item) => item.path));
  const reviewedSet = new Set(reviewFiles.map((item) => item.path));
  const extra = [...actualSet].filter((path) => !reviewedSet.has(path));
  const missing = [...reviewedSet].filter((path) => !actualSet.has(path));
  if (extra.length) throw new TypeError(`build-output root contains unreviewed extra files: ${extra.join(", ")}`);
  if (missing.length) throw new TypeError(`build-output root is missing reviewed files: ${missing.join(", ")}`);
}

export async function stageRevision({
  registration,
  buildOutputRoot,
  review,
  currentRevisionId,
  createdAt = new Date().toISOString(),
}) {
  const trusted = validateRegisteredProject(registration);
  const reviewed = validatePackageReview(review, trusted, currentRevisionId);
  canonicalIso(createdAt, "revision createdAt");
  const walked = await walkBuildRoot(buildOutputRoot);
  compareReviewedFiles(walked.files, reviewed.files);
  const mediaTypes = new Map(reviewed.files.map((file) => [file.path, file.mediaType]));

  const fileContents = new Map();
  const revisionFiles = [];
  const stageFiles = [];
  for (const item of walked.files) {
    const bytes = await readRegularFileNoFollow(item.absolutePath, item.path);
    const mediaType = mediaTypes.get(item.path);
    const digest = await sha256Digest(bytes);
    revisionFiles.push({ path: item.path, sha256: digest, bytes: bytes.byteLength, mediaType });
    stageFiles.push({ path: item.path, mediaType, contentBase64: bytesToCanonicalBase64(bytes) });
    fileContents.set(item.path, bytes);
  }

  const identity = await createRevisionIdentity({
    appId: trusted.appId,
    projectId: trusted.projectId,
    baseRevisionId: reviewed.baseRevisionId,
    manifest: reviewed.manifest,
    files: revisionFiles,
  });
  const revision = {
    kind: "iris.mobile-shell.revision",
    version: CONTRACT_VERSION,
    appId: trusted.appId,
    projectId: trusted.projectId,
    revisionId: identity.revisionId,
    baseRevisionId: reviewed.baseRevisionId,
    manifestHash: identity.manifestHash,
    contentHash: identity.contentHash,
    createdAt,
    manifest: reviewed.manifest,
    files: revisionFiles,
  };
  contractValue(validateRevisionV1(revision), "staged revision");
  contractValue(await verifyRevisionIntegrity(revision, fileContents), "staged revision integrity");

  return Object.freeze({
    kind: "iris.mobile-shell.desktop-stage",
    version: 1,
    stageId: `stage_${randomHex(12)}`,
    stagedAt: new Date().toISOString(),
    appId: trusted.appId,
    projectId: trusted.projectId,
    baseRevisionId: reviewed.baseRevisionId,
    revision,
    files: stageFiles,
  });
}

async function validateStagedRevision(stage, registration, currentRevisionId) {
  const trusted = validateRegisteredProject(registration);
  const value = exactKeys(stage, STAGE_KEYS, "staged revision artifact");
  if (value.kind !== "iris.mobile-shell.desktop-stage" || value.version !== 1) {
    throw new TypeError("staged revision artifact kind/version is unsupported");
  }
  if (typeof value.stageId !== "string" || value.stageId.length < 8) throw new TypeError("staged revision stageId is invalid");
  canonicalIso(value.stagedAt, "staged revision stagedAt");
  if (value.appId !== trusted.appId || value.projectId !== trusted.projectId) {
    throw new TypeError("staged revision belongs to the wrong app/project");
  }
  const currentBase = validateBaseRevisionId(currentRevisionId, "current revision");
  if (value.baseRevisionId !== currentBase) throw new TypeError("staged revision baseRevisionId is stale");
  const revision = contractValue(validateRevisionV1(value.revision), "staged revision");
  if (
    revision.appId !== trusted.appId
    || revision.projectId !== trusted.projectId
    || revision.baseRevisionId !== currentBase
  ) {
    throw new TypeError("staged revision metadata does not bind the trusted project/base");
  }
  if (!Array.isArray(value.files) || value.files.length !== revision.files.length) {
    throw new TypeError("staged revision file bodies do not match the revision table");
  }
  const contents = new Map();
  for (const file of value.files) {
    exactKeys(file, STAGE_FILE_KEYS, "staged file");
    if (!isSafePackagePath(file.path)) throw new TypeError(`staged file path is unsafe: ${String(file.path)}`);
    if (contents.has(file.path)) throw new TypeError(`staged revision contains duplicate file: ${file.path}`);
    contents.set(file.path, base64ToBytes(file.contentBase64, `staged file ${file.path}`));
  }
  contractValue(await verifyRevisionIntegrity(revision, contents), "staged revision integrity");
  for (const descriptor of revision.files) {
    const body = value.files.find((file) => file.path === descriptor.path);
    if (!body || body.mediaType !== descriptor.mediaType) {
      throw new TypeError(`staged file media type does not match revision: ${descriptor.path}`);
    }
  }
  return value;
}

export async function handleEditRequest({
  registration,
  request,
  currentRevisionId,
  receiptStore,
  provenanceCheck,
  editCallback,
}) {
  const trusted = validateRegisteredProject(registration);
  const currentBase = validateBaseRevisionId(currentRevisionId, "current revision");
  if (currentBase === null) throw new TypeError("phone edit requests require an existing current revision");
  const validated = contractValue(
    validateEditRequestV1(request, { currentRevisionId: currentBase }),
    "phone edit request",
  );
  if (validated.appId !== trusted.appId || validated.projectId !== trusted.projectId) {
    throw new TypeError("phone edit request belongs to the wrong app/project");
  }
  if (typeof editCallback !== "function") {
    return Object.freeze({
      status: "unsupported",
      code: "edit_engine_unwired",
      message: "Desktop mobile-shell adapter has no Iris edit engine callback wired.",
    });
  }
  if (typeof provenanceCheck !== "function") {
    return Object.freeze({
      status: "unsupported",
      code: "provenance_check_unwired",
      message: "Desktop mobile-shell adapter has no live Iris provenance callback wired.",
    });
  }
  if (!(receiptStore instanceof DurableReceiptStore)) {
    throw new TypeError("a caller-selected DurableReceiptStore is required before accepting a phone edit request");
  }
  if (await receiptStore.hasRequestNonce(validated.nonce)) {
    throw new ReceiptReplayError("edit request nonce was already accepted", "replayed_request");
  }

  const provenance = await provenanceCheck(Object.freeze({ registration: trusted, currentRevisionId: currentBase }));
  if (
    !provenance || provenance.ok !== true || provenance.provenanceKind !== "guideSourceClone"
    || provenance.appId !== trusted.appId || provenance.projectId !== trusted.projectId
    || provenance.currentRevisionId !== currentBase
  ) {
    throw new TypeError("live provenance check did not confirm the registered project/base");
  }

  const receipt = await receiptStore.claimRequest(validated);
  const editResult = await editCallback(Object.freeze({ request: validated, registration: trusted }));
  return Object.freeze({ status: "accepted", request: validated, receipt, editResult });
}

export async function approveStagedRevision({
  registration,
  stage,
  currentRevisionId,
  receiptStore,
  editRequest = null,
  localApproval = false,
  approvedAt = new Date().toISOString(),
}) {
  if (localApproval !== true) throw new TypeError("explicit local approval is required");
  const trusted = validateRegisteredProject(registration);
  const staged = await validateStagedRevision(stage, trusted, currentRevisionId);
  canonicalIso(approvedAt, "approval approvedAt");

  let request = null;
  if (editRequest !== null) {
    request = contractValue(
      validateEditRequestV1(editRequest, { currentRevisionId: staged.baseRevisionId }),
      "approval edit request",
    );
    if (request.appId !== trusted.appId || request.projectId !== trusted.projectId) {
      throw new TypeError("approval edit request belongs to the wrong app/project");
    }
    if (!(receiptStore instanceof DurableReceiptStore)) {
      throw new TypeError("request-bound approval requires the caller-selected receipt store");
    }
    if (!(await receiptStore.hasAcceptedRequest(request))) {
      throw new TypeError("request-bound approval requires a durable accepted-request receipt");
    }
  }

  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: CONTRACT_VERSION,
    approvalId: `approval_${randomHex(12)}`,
    requestId: request?.requestId ?? null,
    requestNonce: request?.nonce ?? null,
    appId: staged.appId,
    projectId: staged.projectId,
    baseRevisionId: staged.baseRevisionId,
    approvedRevisionId: staged.revision.revisionId,
    approvedContentHash: staged.revision.contentHash,
    approvedAt,
  };
  contractValue(
    validateDeliveryApprovalV1(approval, request ? { editRequest: request } : {}),
    "delivery approval",
  );
  return Object.freeze({
    kind: "iris.mobile-shell.desktop-approved-stage",
    version: 1,
    stage: staged,
    editRequest: request,
    approval,
  });
}

async function validateApprovedStage(approvedStage, registration, currentRevisionId, receiptStore) {
  const trusted = validateRegisteredProject(registration);
  const value = exactKeys(approvedStage, APPROVED_STAGE_KEYS, "approved stage artifact");
  if (value.kind !== "iris.mobile-shell.desktop-approved-stage" || value.version !== 1) {
    throw new TypeError("approved stage artifact kind/version is unsupported");
  }
  const stage = await validateStagedRevision(value.stage, trusted, currentRevisionId);
  let editRequest = null;
  if (value.editRequest !== null) {
    editRequest = contractValue(
      validateEditRequestV1(value.editRequest, { currentRevisionId: stage.baseRevisionId }),
      "approved stage edit request",
    );
    if (!(receiptStore instanceof DurableReceiptStore) || !(await receiptStore.hasAcceptedRequest(editRequest))) {
      throw new TypeError("approved stage request is missing its accepted-request receipt");
    }
  }
  const approval = contractValue(
    validateDeliveryApprovalV1(value.approval, editRequest ? { editRequest } : {}),
    "approved stage approval",
  );
  if (
    approval.appId !== stage.appId || approval.projectId !== stage.projectId
    || approval.baseRevisionId !== stage.baseRevisionId
    || approval.approvedRevisionId !== stage.revision.revisionId
    || approval.approvedContentHash !== stage.revision.contentHash
  ) {
    throw new TypeError("approved stage approval does not bind the staged revision exactly");
  }
  if (editRequest === null && (approval.requestId !== null || approval.requestNonce !== null)) {
    throw new TypeError("desktop-originated approval may not invent a phone request binding");
  }
  return { stage, editRequest, approval };
}

export async function createDeliveryPackage({
  registration,
  approvedStage,
  currentRevisionId,
  receiptStore,
  deliveryNonce = randomHex(24),
  issuedAt = new Date().toISOString(),
}) {
  if (!(receiptStore instanceof DurableReceiptStore)) {
    throw new TypeError("a caller-selected DurableReceiptStore is required for delivery");
  }
  if (await receiptStore.hasDeliveryNonce(deliveryNonce)) {
    throw new ReceiptReplayError("delivery nonce was already issued", "replayed_delivery");
  }
  canonicalIso(issuedAt, "delivery issuedAt");
  const { stage, editRequest, approval } = await validateApprovedStage(
    approvedStage,
    registration,
    currentRevisionId,
    receiptStore,
  );
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: CONTRACT_VERSION,
    envelopeId: `delivery_${randomHex(12)}`,
    deliveryNonce,
    approvalId: approval.approvalId,
    appId: stage.appId,
    projectId: stage.projectId,
    baseRevisionId: stage.baseRevisionId,
    revisionId: stage.revision.revisionId,
    contentHash: stage.revision.contentHash,
    issuedAt,
    revision: stage.revision,
  };
  const usedDeliveryNonces = await receiptStore.usedDeliveryNonces();
  contractValue(
    validateDeliveryEnvelopeV1(envelope, {
      approval,
      currentRevisionId: validateBaseRevisionId(currentRevisionId, "current revision"),
      usedDeliveryNonces,
    }),
    "delivery envelope",
  );
  const transport = {
    format: DELIVERY_PACKAGE_FORMAT,
    approval,
    envelope,
    files: stage.files.map((file) => ({
      path: file.path,
      mediaType: file.mediaType,
      contentBase64: file.contentBase64,
    })),
  };
  await verifyPackageTransport(transport, {
    currentRevisionId: stage.baseRevisionId,
    usedDeliveryNonces,
    ...(editRequest ? { editRequest } : {}),
  });
  await receiptStore.claimDelivery(envelope);
  return Object.freeze(transport);
}
