import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";

import {
  CONTRACT_VERSION,
  DELIVERY_PACKAGE_FORMAT,
  DELIVERY_PACKAGE_LIMITS,
  KNOWN_CAPABILITIES,
  canonicalJSONString,
  createRevisionIdentity,
  evaluateShellCompatibility,
  isSafePackagePath,
  sha256Digest,
  validateDeliveryApprovalV1,
  validateDeliveryEnvelopeV1,
  validateDeliveryPackageV1,
  validateEditRequestV1,
  validateManifestV1,
  validateRevisionV1,
  verifyRevisionIntegrity,
  verifyDeliveryPackageV1,
} from "../index.js";

const subtle = webcrypto.subtle;
const hexA = "a".repeat(64);
const baseRevisionId = `rev-sha256:${hexA}`;
const nonceA = "a".repeat(32);
const nonceB = "b".repeat(32);

function manifest(overrides = {}) {
  return {
    kind: "iris.mobile-shell.manifest",
    version: 1,
    appId: "publik.kneecap",
    projectId: "publik.kneecap.mobile",
    displayName: "Kneecap",
    runtime: {
      type: "web",
      entrypoint: "index.html",
      minShellVersion: "1.0.0",
    },
    capabilities: ["web.storage"],
    data: {
      namespace: "publik.kneecap",
      updatePolicy: "preserve",
    },
    ...overrides,
  };
}

async function revisionFixture({ manifestValue = manifest(), filesByPath, changes } = {}) {
  const content = filesByPath ?? {
    "index.html": "<!doctype html><title>Kneecap</title>",
    "app.js": "export const ready = true;",
  };
  const fileRecords = [];
  for (const [path, value] of Object.entries(content)) {
    const bytes = new TextEncoder().encode(value);
    fileRecords.push({
      path,
      sha256: await sha256Digest(bytes, { subtle }),
      bytes: bytes.byteLength,
      mediaType: path.endsWith(".html") ? "text/html" : "application/javascript",
    });
  }
  const identity = await createRevisionIdentity({
    appId: manifestValue.appId,
    projectId: manifestValue.projectId,
    baseRevisionId,
    manifest: manifestValue,
    files: fileRecords,
    changes,
  }, { subtle });
  return {
    revision: {
      kind: "iris.mobile-shell.revision",
      version: 1,
      appId: manifestValue.appId,
      projectId: manifestValue.projectId,
      revisionId: identity.revisionId,
      baseRevisionId,
      manifestHash: identity.manifestHash,
      contentHash: identity.contentHash,
      createdAt: "2026-09-16T23:00:00.000Z",
      manifest: manifestValue,
      files: fileRecords,
      ...(changes !== undefined ? { changes } : {}),
    },
    content,
  };
}

function editRequest(overrides = {}) {
  return {
    kind: "iris.mobile-shell.edit-request",
    version: 1,
    requestId: "req_phone_0001",
    nonce: nonceA,
    appId: "publik.kneecap",
    projectId: "publik.kneecap.mobile",
    baseRevisionId,
    requestedAt: "2026-09-16T23:00:00.000Z",
    intent: { type: "feature", text: "Make the trim handles easier to grab" },
    ...overrides,
  };
}

async function deliveryPackageFixture() {
  const { revision, content } = await revisionFixture();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_package_0001",
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: 1,
    envelopeId: "delivery_package_0001",
    deliveryNonce: nonceB,
    approvalId: approval.approvalId,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    revisionId: revision.revisionId,
    contentHash: revision.contentHash,
    issuedAt: "2026-09-16T23:02:00.000Z",
    revision,
  };
  return {
    format: DELIVERY_PACKAGE_FORMAT,
    approval,
    envelope,
    files: revision.files.map((file) => ({
      path: file.path,
      mediaType: file.mediaType,
      contentBase64: Buffer.from(content[file.path], "utf8").toString("base64"),
    })),
  };
}

test("contract version and capability allowlist are stable v1 values", () => {
  assert.equal(CONTRACT_VERSION, 1);
  assert.ok(KNOWN_CAPABILITIES.includes("web.storage"));
  assert.ok(KNOWN_CAPABILITIES.includes("native.share"));
  assert.equal(new Set(KNOWN_CAPABILITIES).size, KNOWN_CAPABILITIES.length);
});

test("manifest accepts a minimal web app and preserves user data separately", () => {
  const result = validateManifestV1(manifest());
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));
  assert.equal(result.value.data.updatePolicy, "preserve");
});

test("manifest rejects unknown capabilities instead of silently granting them", () => {
  const result = validateManifestV1(manifest({ capabilities: ["native.execute-shell"] }));
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /unsupported/);
});

test("media export is a recognized declaration but never ambient shell authority", () => {
  const value = manifest({ capabilities: ["web.media.export"] });
  const parsed = validateManifestV1(value);
  assert.equal(parsed.ok, true, parsed.ok ? "" : parsed.errors.join("\n"));
  const denied = evaluateShellCompatibility(value, { version: "1.0.0", supportedCapabilities: [] });
  assert.equal(denied.ok, false);
  assert.deepEqual(denied.unsupportedCapabilities, ["web.media.export"]);
  const allowed = evaluateShellCompatibility(value, {
    version: "1.0.0", supportedCapabilities: ["web.media.export"],
  });
  assert.equal(allowed.ok, true);
  assert.equal(validateManifestV1(manifest({ capabilities: ["web.media.export-arbitrary-file"] })).ok, false);
});

test("manifest rejects unknown security-relevant fields", () => {
  const value = manifest();
  value.nativeBridge = "*";
  const result = validateManifestV1(value);
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /not a v1 field/);
});

test("package paths reject traversal, URL ambiguity, absolute and backslash forms", () => {
  for (const unsafe of ["../secret", "a/../secret", "/etc/passwd", "a\\b", "a//b", "a%2fb", "index.html?x=1", "a/./b"]) {
    assert.equal(isSafePackagePath(unsafe), false, unsafe);
  }
  assert.equal(isSafePackagePath("assets/My Clip.js"), true);
  assert.equal(isSafePackagePath(`${"😀".repeat(256)}`), true);
  assert.equal(isSafePackagePath(`${"😀".repeat(257)}`), false);
});

test("revision paths reject case aliases and file-directory aliases before storage", async () => {
  const { revision } = await revisionFixture();
  const caseAlias = structuredClone(revision);
  caseAlias.files.push({ ...caseAlias.files[1], path: "App.js" });
  const caseResult = validateRevisionV1(caseAlias);
  assert.equal(caseResult.ok, false);
  assert.match(caseResult.errors.join(" "), /storage path alias/);

  const directoryAlias = structuredClone(revision);
  directoryAlias.files.push({ ...directoryAlias.files[1], path: "assets" });
  directoryAlias.files.push({ ...directoryAlias.files[1], path: "assets/app.js" });
  const directoryResult = validateRevisionV1(directoryAlias);
  assert.equal(directoryResult.ok, false);
  assert.match(directoryResult.errors.join(" "), /storage path alias/);
});

test("shell compatibility rejects an old shell and unsupported requested capability", () => {
  const value = manifest({ capabilities: ["web.storage", "native.camera"] });
  const result = evaluateShellCompatibility(value, {
    version: "0.9.9",
    supportedCapabilities: ["web.storage"],
  });
  assert.equal(result.ok, false);
  assert.deepEqual(result.unsupportedCapabilities, ["native.camera"]);
  assert.match(result.reasons.join(" "), /older than required/);
});

test("shell compatibility passes only when version and every capability are supported", () => {
  const value = manifest({ capabilities: ["native.share", "web.storage"] });
  const result = evaluateShellCompatibility(value, {
    version: "1.2.0",
    supportedCapabilities: ["web.storage", "native.share"],
  });
  assert.equal(result.ok, true, result.reasons.join("\n"));
});

test("revision identity is deterministic across object keys, capability order, and file order", async () => {
  const one = manifest({ capabilities: ["web.storage", "native.share"] });
  const two = {
    data: { updatePolicy: "preserve", namespace: "publik.kneecap" },
    capabilities: ["native.share", "web.storage"],
    runtime: { minShellVersion: "1.0.0", entrypoint: "index.html", type: "web" },
    displayName: "Kneecap",
    projectId: "publik.kneecap.mobile",
    appId: "publik.kneecap",
    version: 1,
    kind: "iris.mobile-shell.manifest",
  };
  const files = [
    { path: "index.html", sha256: `sha256:${"b".repeat(64)}`, bytes: 3, mediaType: "text/html" },
    { path: "app.js", sha256: `sha256:${"c".repeat(64)}`, bytes: 4, mediaType: "application/javascript" },
  ];
  const first = await createRevisionIdentity({ appId: one.appId, projectId: one.projectId, baseRevisionId, manifest: one, files }, { subtle });
  const second = await createRevisionIdentity({ appId: two.appId, projectId: two.projectId, baseRevisionId, manifest: two, files: [...files].reverse() }, { subtle });
  assert.deepEqual(first, second);
});

test("revision validator binds manifest, app/project, entrypoint and revision id", async () => {
  const { revision } = await revisionFixture();
  const result = validateRevisionV1(revision);
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));

  const wrongProject = structuredClone(revision);
  wrongProject.projectId = "publik.other.mobile";
  const wrong = validateRevisionV1(wrongProject);
  assert.equal(wrong.ok, false);
  assert.match(wrong.errors.join(" "), /manifest\.projectId/);
});

// Contract v1.1 (SPEC.md section 2.6, owner-decided 2026-09-28): the
// optional `changes` field feeding the phone Features page's plain-words
// row title ("Added: Dark mode"), covered by contentHash like every other
// revision field.
test("revision accepts an optional changes field and covers it in contentHash", async () => {
  const changes = [{ title: "Added: Dark mode", kind: "added", target: null }];
  const { revision } = await revisionFixture({ changes });
  const result = validateRevisionV1(revision);
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));
  assert.deepEqual(revision.changes, changes);

  const without = await revisionFixture();
  assert.notEqual(revision.contentHash, without.revision.contentHash,
    "a revision with changes must not collide with the identical content's hash without them");
});

test("a revision with no changes field hashes exactly as it did before contract v1.1 existed", async () => {
  const { revision } = await revisionFixture();
  // Recomputed independently, the same way section 2.6 says an old host
  // must: nothing in the payload changes shape when `changes` is absent.
  const identity = await createRevisionIdentity({
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    manifest: revision.manifest,
    files: revision.files,
  }, { subtle });
  assert.equal(identity.contentHash, revision.contentHash);
  assert.equal(identity.revisionId, revision.revisionId);
});

test("revision validator rejects a malformed changes entry (bad kind, oversized title, non-revision target)", async () => {
  // `createRevisionIdentity` already fails closed on a malformed `changes`
  // argument (checked separately below), so a validator-level test builds a
  // structurally valid revision first and then substitutes a bad `changes`
  // value directly -- exactly the shape `validateRevisionV1` must catch on
  // its own when it sees a revision it did not itself just compute (a
  // tampered or hand-edited package, the case this validator exists for).
  const { revision: good } = await revisionFixture({
    changes: [{ title: "Added: placeholder", kind: "added", target: null }],
  });

  const badKind = { ...good, changes: [{ title: "Added: X", kind: "modified", target: null }] };
  assert.equal(validateRevisionV1(badKind).ok, false);

  const oversizedTitle = { ...good, changes: [{ title: "Added: " + "x".repeat(120), kind: "added", target: null }] };
  assert.equal(validateRevisionV1(oversizedTitle).ok, false);

  const badTarget = { ...good, changes: [{ title: "Removed: X", kind: "removed", target: "not-a-revision-id" }] };
  assert.equal(validateRevisionV1(badTarget).ok, false);

  const emptyArray = { ...good, changes: [] };
  assert.equal(validateRevisionV1(emptyArray).ok, false);
});

test("createRevisionIdentity itself refuses a malformed changes argument, fail closed before any hash is computed", async () => {
  await assert.rejects(
    () => revisionFixture({ changes: [{ title: "Added: X", kind: "modified", target: null }] }),
    /kind must be added or removed/,
  );
  await assert.rejects(() => revisionFixture({ changes: [] }), /must be a nonempty array/);
});

test("revision validator rejects an unknown changes field before contract v1.1's key was ever added (regression)", () => {
  // Simulates an old host's exact-key strictness with a field the schema
  // does not (yet, in this scenario) allow: any UNKNOWN top-level key is
  // still rejected outright, changes included, confirming this addition
  // did not accidentally loosen `exactKeys` for every other field too.
  const result = validateRevisionV1({ kind: "iris.mobile-shell.revision", version: 1, notAField: true });
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /revision\.notAField is not a v1 field/);
});

test("integrity verifies every delivered byte and exact file set", async () => {
  const { revision, content } = await revisionFixture();
  const result = await verifyRevisionIntegrity(revision, content, { subtle });
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));
});

test("integrity rejects a tampered file", async () => {
  const { revision, content } = await revisionFixture();
  const tampered = { ...content, "app.js": "export const ready = false;" };
  const result = await verifyRevisionIntegrity(revision, tampered, { subtle });
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /app\.js/);
});

test("integrity rejects missing and unexpected package files", async () => {
  const { revision, content } = await revisionFixture();
  const changed = { "index.html": content["index.html"], "extra.js": "nope" };
  const result = await verifyRevisionIntegrity(revision, changed, { subtle });
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /missing delivered file: app\.js/);
  assert.match(result.errors.join(" "), /unexpected delivered file: extra\.js/);
});

test("edit request is intent-only and rejects shell-shaped extra fields", () => {
  const value = editRequest();
  value.command = "rm -rf ~/";
  const result = validateEditRequestV1(value);
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /command is not a v1 field/);
});

test("edit request rejects stale base and replayed nonce", () => {
  const result = validateEditRequestV1(editRequest(), {
    currentRevisionId: `rev-sha256:${"b".repeat(64)}`,
    usedNonces: new Set([nonceA]),
  });
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /stale/);
  assert.match(result.errors.join(" "), /already used/);
});

test("delivery approval binds a phone request id, nonce, app, project and base", async () => {
  const { revision } = await revisionFixture();
  const request = editRequest();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_0001",
    requestId: request.requestId,
    requestNonce: request.nonce,
    appId: request.appId,
    projectId: request.projectId,
    baseRevisionId: request.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const result = validateDeliveryApprovalV1(approval, { editRequest: request });
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));

  const wrongNonce = { ...approval, requestNonce: nonceB };
  const wrong = validateDeliveryApprovalV1(wrongNonce, { editRequest: request });
  assert.equal(wrong.ok, false);
  assert.match(wrong.errors.join(" "), /bind/);
});

test("desktop-originated approval has no fake phone request binding", async () => {
  const { revision } = await revisionFixture();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_0002",
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const result = validateDeliveryApprovalV1(approval);
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));
});

test("approval revision id must be derived from its approved content hash", async () => {
  const { revision } = await revisionFixture();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_0005",
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: `sha256:${"f".repeat(64)}`,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const result = validateDeliveryApprovalV1(approval);
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /does not match/);
});

test("delivery envelope binds immutable revision and separate approval", async () => {
  const { revision } = await revisionFixture();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_0003",
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: 1,
    envelopeId: "delivery_0001",
    deliveryNonce: nonceB,
    approvalId: approval.approvalId,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    revisionId: revision.revisionId,
    contentHash: revision.contentHash,
    issuedAt: "2026-09-16T23:02:00.000Z",
    revision,
  };
  const result = validateDeliveryEnvelopeV1(envelope, {
    approval,
    currentRevisionId: baseRevisionId,
    usedDeliveryNonces: new Set(),
  });
  assert.equal(result.ok, true, result.ok ? "" : result.errors.join("\n"));
});

test("delivery envelope rejects wrong approval, stale base and replay", async () => {
  const { revision } = await revisionFixture();
  const approval = {
    kind: "iris.mobile-shell.delivery-approval",
    version: 1,
    approvalId: "approval_0004",
    requestId: null,
    requestNonce: null,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    approvedRevisionId: revision.revisionId,
    approvedContentHash: revision.contentHash,
    approvedAt: "2026-09-16T23:01:00.000Z",
  };
  const envelope = {
    kind: "iris.mobile-shell.delivery-envelope",
    version: 1,
    envelopeId: "delivery_0002",
    deliveryNonce: nonceB,
    approvalId: approval.approvalId,
    appId: revision.appId,
    projectId: revision.projectId,
    baseRevisionId: revision.baseRevisionId,
    revisionId: revision.revisionId,
    contentHash: revision.contentHash,
    issuedAt: "2026-09-16T23:02:00.000Z",
    revision,
  };
  const wrongApproval = { ...approval, approvedContentHash: `sha256:${"f".repeat(64)}` };
  const result = validateDeliveryEnvelopeV1(envelope, {
    approval: wrongApproval,
    currentRevisionId: `rev-sha256:${"e".repeat(64)}`,
    usedDeliveryNonces: new Set([nonceB]),
  });
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /approval/);
  assert.match(result.errors.join(" "), /stale/);
  assert.match(result.errors.join(" "), /already used/);
});

test("canonical JSON is deterministic for object key order", () => {
  assert.equal(canonicalJSONString({ b: 2, a: { d: 4, c: 3 } }), canonicalJSONString({ a: { c: 3, d: 4 }, b: 2 }));
});

test("delivery package wrapper is one exact shared format and verifies inline bytes", async () => {
  const pkg = await deliveryPackageFixture();
  const shape = validateDeliveryPackageV1(pkg);
  assert.equal(shape.ok, true, shape.ok ? "" : shape.errors.join("\n"));
  const verified = await verifyDeliveryPackageV1(pkg, {
    currentRevisionId: baseRevisionId,
    usedDeliveryNonces: new Set(),
    subtle,
  });
  assert.equal(verified.ok, true, verified.ok ? "" : verified.errors.join("\n"));
  assert.equal(verified.value.revision.revisionId, pkg.envelope.revisionId);
  assert.equal(verified.value.files.length, pkg.files.length);
});

test("delivery package wrapper rejects extra fields, oversized declarations, and base64 length mismatch", async () => {
  const pkg = await deliveryPackageFixture();
  const extra = { ...pkg, remoteUrl: "https://example.invalid/app" };
  const extraResult = validateDeliveryPackageV1(extra);
  assert.equal(extraResult.ok, false);
  assert.match(extraResult.errors.join(" "), /not a v1 field/);

  const oversized = structuredClone(pkg);
  oversized.envelope.revision.files[0].bytes = DELIVERY_PACKAGE_LIMITS.maxSingleFileBytes + 1;
  const oversizedResult = await verifyDeliveryPackageV1(oversized, { subtle });
  assert.equal(oversizedResult.ok, false);
  assert.match(oversizedResult.errors.join(" "), /single-file limit/);

  const wrongEncodedLength = structuredClone(pkg);
  wrongEncodedLength.files[0].contentBase64 = `AAAA${wrongEncodedLength.files[0].contentBase64}`;
  const lengthResult = await verifyDeliveryPackageV1(wrongEncodedLength, { subtle });
  assert.equal(lengthResult.ok, false);
  assert.match(lengthResult.errors.join(" "), /base64 length/);
});
