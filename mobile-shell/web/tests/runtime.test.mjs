import assert from "node:assert/strict";
import test from "node:test";

import { validateEditRequestV1 } from "../../contracts/index.js";
import { buildDemoPackages } from "../demo/notes-demo.mjs";
import {
  PACKAGE_FORMAT,
  PackageValidationError,
  assessCapabilities,
  authorizeVerifiedPackageForLocalStorage,
  consumeLocalReaderApproval,
  makeEditRequest,
  parsePackageJson,
  userDataDatabaseName,
  validateRevisionTransition,
  verifyPackageTransport,
} from "../runtime.mjs";
import { ContentStore } from "../storage.mjs";

test("bundled demo revisions satisfy the shared delivery contract and hash verification", async () => {
  const { v1, v2 } = await buildDemoPackages();
  const first = await verifyPackageTransport(v1, {
    currentRevisionId: null,
    usedDeliveryNonces: new Set(),
  });
  assert.equal(first.compatible, true);
  assert.equal(first.revision.baseRevisionId, null);
  assert.equal(first.manifest.capabilities[0], "web.storage");
  assert.equal(first.files[0].path, "index.html");
  assert.doesNotThrow(() => validateRevisionTransition(null, first.revision));

  const second = await verifyPackageTransport(v2, {
    currentRevisionId: first.revision.revisionId,
    usedDeliveryNonces: new Set([v1.envelope.deliveryNonce]),
  });
  assert.equal(second.revision.baseRevisionId, first.revision.revisionId);
  assert.doesNotThrow(() => validateRevisionTransition(first.revision, second.revision));
});

test("delivery verification rejects a stale base revision", async () => {
  const { v2 } = await buildDemoPackages();
  await assert.rejects(
    verifyPackageTransport(v2, { currentRevisionId: null, usedDeliveryNonces: new Set() }),
    /baseRevisionId is stale/
  );
});

test("delivery verification rejects a replayed delivery nonce", async () => {
  const { v1 } = await buildDemoPackages();
  await assert.rejects(
    verifyPackageTransport(v1, {
      currentRevisionId: null,
      usedDeliveryNonces: new Set([v1.envelope.deliveryNonce]),
    }),
    /deliveryNonce was already used/
  );
});

test("delivered file bytes must match the immutable revision hash", async () => {
  const { v1 } = await buildDemoPackages();
  const tampered = structuredClone(v1);
  const original = tampered.files[0].contentBase64;
  tampered.files[0].contentBase64 = `${original.slice(0, -4)}AAAA`;
  await assert.rejects(
    verifyPackageTransport(tampered, { currentRevisionId: null, usedDeliveryNonces: new Set() }),
    /byte length does not match|SHA-256 does not match|Byte-size mismatch/
  );
});

test("web transport rejects unsafe paths before persistence", async () => {
  const { v1 } = await buildDemoPackages();
  const unsafe = structuredClone(v1);
  unsafe.files[0].path = "../index.html";
  await assert.rejects(
    verifyPackageTransport(unsafe, { currentRevisionId: null, usedDeliveryNonces: new Set() }),
    /Unsafe package path|not declared/
  );
});

test("a request-bound delivery cannot import without the saved phone request", async () => {
  const { v1 } = await buildDemoPackages();
  const requestBound = structuredClone(v1);
  requestBound.approval.requestId = "req_missing_1234";
  requestBound.approval.requestNonce = "c".repeat(64);
  await assert.rejects(
    verifyPackageTransport(requestBound, { currentRevisionId: null, usedDeliveryNonces: new Set() }),
    (error) => error instanceof PackageValidationError && error.code === "missing_edit_request"
  );
});

test("a request-bound delivery imports only when it binds the saved phone request and active base", async () => {
  const { v1, v2 } = await buildDemoPackages();
  const first = await verifyPackageTransport(v1, { currentRevisionId: null, usedDeliveryNonces: new Set() });
  const request = makeEditRequest({
    appId: first.revision.appId,
    projectId: first.revision.projectId,
    baseRevisionId: first.revision.revisionId,
    intentType: "feature",
    intentText: "Make the note title easier to scan",
  });
  const response = structuredClone(v2);
  response.approval.requestId = request.requestId;
  response.approval.requestNonce = request.nonce;
  const verified = await verifyPackageTransport(response, {
    currentRevisionId: first.revision.revisionId,
    usedDeliveryNonces: new Set([v1.envelope.deliveryNonce]),
    editRequest: request,
  });
  assert.equal(verified.approval.requestId, request.requestId);
  assert.equal(verified.approval.requestNonce, request.nonce);
  assert.equal(verified.revision.baseRevisionId, request.baseRevisionId);
});

test("phone edit requests use the strict intent-only shared contract", async () => {
  const { v1 } = await buildDemoPackages();
  const verified = await verifyPackageTransport(v1, { currentRevisionId: null, usedDeliveryNonces: new Set() });
  const request = makeEditRequest({
    appId: verified.revision.appId,
    projectId: verified.revision.projectId,
    baseRevisionId: verified.revision.revisionId,
    intentType: "feature",
    intentText: "Make the save confirmation easier to notice",
  });
  const result = validateEditRequestV1(request, { currentRevisionId: verified.revision.revisionId });
  assert.equal(result.ok, true);
  assert.deepEqual(Object.keys(request).sort(), [
    "appId",
    "baseRevisionId",
    "intent",
    "kind",
    "nonce",
    "projectId",
    "requestId",
    "requestedAt",
    "version",
  ]);
  assert.equal("command" in request, false);
  assert.equal("script" in request, false);
  assert.equal("cwd" in request, false);
});

test("web capability assessment is closed and reports native requirements honestly", () => {
  const unsupported = assessCapabilities(["web.storage", "native.photo-library"]);
  assert.deepEqual(unsupported.map((item) => item.capability), ["native.photo-library"]);
  assert.match(unsupported[0].reason, /reviewed native host/i);
});

test("per-app user data uses a separate stable IndexedDB namespace", () => {
  const first = userDataDatabaseName("iris.notes-demo", "iris.notes-demo.mobile", "shared.notes");
  const second = userDataDatabaseName("iris.other-demo", "iris.other-demo.mobile", "shared.notes");
  const otherProject = userDataDatabaseName("iris.notes-demo", "iris.notes-demo.other", "shared.notes");
  assert.notEqual(first, second);
  assert.notEqual(first, otherProject);
  assert.match(first, /^iris-mobile-userdata-v1-/);
});

test("embedded delivery approval cannot authorize web persistence by itself", async () => {
  const { v1 } = await buildDemoPackages();
  const verified = await verifyPackageTransport(v1, { currentRevisionId: null, usedDeliveryNonces: new Set() });
  const store = new ContentStore();
  await assert.rejects(
    store.saveVerifiedPackage(verified, { activateInitial: true }),
    /separate local reader approval/i
  );
  assert.throws(
    () => consumeLocalReaderApproval(verified, { ...verified.approval }),
    /separate local reader approval/i
  );
  const receipt = authorizeVerifiedPackageForLocalStorage(verified);
  assert.equal(consumeLocalReaderApproval(verified, receipt), true);
  assert.throws(() => consumeLocalReaderApproval(verified, receipt), /separate local reader approval/i);
});

test("package parser requires the exact local transport shape", async () => {
  const { v1 } = await buildDemoPackages();
  assert.equal(parsePackageJson(JSON.stringify(v1)).format, PACKAGE_FORMAT);
  assert.throws(
    () => parsePackageJson(JSON.stringify({ ...v1, remoteUrl: "https://example.com/app" })),
    /unknown or missing top-level fields/
  );
});
