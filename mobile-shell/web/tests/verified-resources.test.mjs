import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  createVerifiedResourceIndex,
  VerifiedResourceIndexError,
} from "../verified-resources.mjs";

const NUT_PACKAGE_PATH = new URL(
  "../../../outputs/iris_kneecap_user_test_20260916/seamless_mobile_20260918/resumed_20260918/core-acceptance/multiapp-storage-20260920/outcome-20260921/native-resume-2100-20260921/developer-inputs-current/nut-ai.irisapp",
  import.meta.url,
);

const NUT_ALLOWED_MIMES = Object.freeze([
  "application/json",
  "application/octet-stream",
  "application/wasm",
  "image/png",
  "text/html",
  "text/javascript",
]);

async function readNutPackage() {
  return JSON.parse(await readFile(NUT_PACKAGE_PATH, "utf8"));
}

function selectionFor(transport) {
  const revision = transport.envelope.revision;
  return {
    appId: revision.appId,
    approvalId: transport.approval.approvalId,
    baseRevisionId: revision.baseRevisionId,
    contentHash: revision.contentHash,
    projectId: revision.projectId,
    revisionId: revision.revisionId,
  };
}

function optionsFor(transport, overrides = {}) {
  return {
    approvedSelection: selectionFor(transport),
    currentRevisionId: transport.envelope.baseRevisionId,
    allowedMimeTypes: NUT_ALLOWED_MIMES,
    ...overrides,
  };
}

function requestFor(index, path, identity = index.identity) {
  return {
    appId: identity.appId,
    projectId: identity.projectId,
    revisionId: identity.revisionId,
    path,
  };
}

test("real prepared Nut AI package builds a bound multi-file resource index", async () => {
  const transport = await readNutPackage();
  const index = await createVerifiedResourceIndex(transport, optionsFor(transport));

  assert.deepEqual(index.identity, {
    appId: "publik.nut-ai",
    approvalId: transport.approval.approvalId,
    baseRevisionId: transport.envelope.baseRevisionId,
    contentHash: transport.envelope.revision.contentHash,
    projectId: "publik.nut-ai.mobile",
    revisionId: "rev-sha256:0702a71d0d72dd5403d806c8945bafddbe37935beea46fd57cbf5563fc807dc3",
    entrypoint: "index.html",
  });
  assert.equal(index.resources.length, 26);

  const script = index.resolveResource(requestFor(index, "_expo/static/js/web/iris-entry-5a1afcf556b7d8ef77ac839875aaecad.js"));
  assert.equal(script.mediaType, "text/javascript");
  assert.equal(script.bytes, 3_038_428);
  assert.equal(script.content.byteLength, script.bytes);
  assert.match(script.sha256, /^sha256:[a-f0-9]{64}$/);

  const wasm = index.resolveResource(requestFor(index, "assets/sqlite3.wasm"));
  assert.equal(wasm.mediaType, "application/wasm");
  assert.equal(wasm.bytes, 868_907);

  const retinaIcon = index.resolveResource(requestFor(index, "assets/__node_modules/expo-router/assets/react-navigation/elements/clear-icon.c94f6478e7ae0cdd9f15de1fcb9e5e55@2x.png"));
  assert.equal(retinaIcon.mediaType, "image/png");
  assert.equal(retinaIcon.bytes, 334);

  const database = index.resolveResource(requestFor(index, "assets/nutrition.db"));
  assert.equal(database.mediaType, "application/octet-stream");
  assert.equal(database.bytes, 4_907_008);

  script.content.fill(0);
  const secondRead = index.resolveResource(requestFor(index, script.path));
  assert.notEqual(secondRead.content[0], 0);
});

test("resource access requires an exact approved app, project, base, revision and approval", async () => {
  const transport = await readNutPackage();
  await assert.rejects(
    createVerifiedResourceIndex(transport, { currentRevisionId: null, allowedMimeTypes: NUT_ALLOWED_MIMES }),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "unapproved_selection",
  );

  for (const [key, value] of [
    ["appId", "publik.other-app"],
    ["projectId", "publik.nut-ai.other"],
    ["revisionId", `rev-sha256:${"0".repeat(64)}`],
    ["approvalId", "approval_other_1234"],
    ["contentHash", `sha256:${"0".repeat(64)}`],
  ]) {
    const approvedSelection = { ...selectionFor(transport), [key]: value };
    await assert.rejects(
      createVerifiedResourceIndex(transport, optionsFor(transport, { approvedSelection })),
      (error) => error instanceof VerifiedResourceIndexError && error.code === "unapproved_selection",
      `expected mismatched ${key} to be refused`,
    );
  }

  const index = await createVerifiedResourceIndex(transport, optionsFor(transport));
  assert.throws(
    () => index.resolveResource(requestFor(index, "assets/sqlite3.wasm", {
      ...index.identity,
      revisionId: `rev-sha256:${"0".repeat(64)}`,
    })),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "unapproved_selection",
  );
});

test("resource paths reject traversal, URL aliases, encoded paths and unlisted files", async () => {
  const transport = await readNutPackage();
  const index = await createVerifiedResourceIndex(transport, optionsFor(transport));
  for (const path of [
    "../index.html",
    "%2e%2e/index.html",
    "assets/__node_modules/expo-router/assets/react-navigation/elements/clear-icon.c94f6478e7ae0cdd9f15de1fcb9e5e55%402x.png",
    "assets\\sqlite3.wasm",
    "/assets/sqlite3.wasm",
    "https://example.test/assets/sqlite3.wasm",
    "assets/sqlite3.wasm?raw=1",
    "assets/sqlite3.wasm#fragment",
  ]) {
    assert.throws(
      () => index.resolveResource(requestFor(index, path)),
      (error) => error instanceof VerifiedResourceIndexError && error.code === "invalid_path",
      `expected unsafe path to be refused: ${path}`,
    );
  }
  assert.throws(
    () => index.resolveResource(requestFor(index, "assets/not-in-package.wasm")),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "not_found",
  );
  assert.throws(
    () => index.resolveResource(requestFor(index, "ASSETS/sqlite3.wasm")),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "path_alias",
  );
});

test("resource type access is an explicit host allowlist, including active code and WASM", async () => {
  const transport = await readNutPackage();
  const index = await createVerifiedResourceIndex(transport, optionsFor(transport, {
    allowedMimeTypes: ["text/html", "image/png", "application/json", "application/octet-stream"],
  }));
  assert.throws(
    () => index.resolveResource(requestFor(index, "assets/sqlite3.wasm")),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "mime_not_approved",
  );
  assert.throws(
    () => index.resolveResource(requestFor(index, "_expo/static/js/web/iris-entry-5a1afcf556b7d8ef77ac839875aaecad.js")),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "mime_not_approved",
  );
  await assert.rejects(
    createVerifiedResourceIndex(transport, optionsFor(transport, { allowedMimeTypes: ["application/x-shellscript"] })),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "unsupported_mime",
  );
});

test("active base is explicit and the local index has no remote fallback", async () => {
  const transport = await readNutPackage();
  await assert.rejects(
    createVerifiedResourceIndex(transport, {
      approvedSelection: selectionFor(transport),
      allowedMimeTypes: NUT_ALLOWED_MIMES,
    }),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "missing_current_revision",
  );
  await assert.rejects(
    createVerifiedResourceIndex(transport, optionsFor(transport, { currentRevisionId: `rev-sha256:${"f".repeat(64)}` })),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "contract_rejected",
  );

  const index = await createVerifiedResourceIndex(transport, optionsFor(transport));
  assert.throws(
    () => index.resolveResource(requestFor(index, "https://cdn.example.test/assets/sqlite3.wasm")),
    (error) => error instanceof VerifiedResourceIndexError && error.code === "invalid_path",
  );
});

test("verification snapshots mutable package and selection inputs before async hashing", async () => {
  const transport = await readNutPackage();
  const selected = selectionFor(transport);
  const building = createVerifiedResourceIndex(transport, optionsFor(transport, { approvedSelection: selected }));

  selected.appId = "publik.attacker";
  transport.files.find((file) => file.path === "assets/sqlite3.wasm").contentBase64 = "AAAA";

  const index = await building;
  const wasm = index.resolveResource(requestFor(index, "assets/sqlite3.wasm"));
  assert.equal(wasm.bytes, 868_907);
  assert.equal(index.identity.appId, "publik.nut-ai");
});

test("missing, changed, or MIME-mismatched package bodies fail contract verification", async (t) => {
  const original = await readNutPackage();

  await t.test("missing body", async () => {
    const missing = structuredClone(original);
    missing.files.pop();
    await assert.rejects(
      createVerifiedResourceIndex(missing, optionsFor(missing)),
      (error) => error instanceof VerifiedResourceIndexError && error.code === "contract_rejected",
    );
  });

  await t.test("changed body bytes", async () => {
    const changed = structuredClone(original);
    const file = changed.files.find((item) => item.path === "assets/sqlite3.wasm");
    const bytes = Buffer.from(file.contentBase64, "base64");
    bytes[0] ^= 1;
    file.contentBase64 = bytes.toString("base64");
    await assert.rejects(
      createVerifiedResourceIndex(changed, optionsFor(changed)),
      (error) => error instanceof VerifiedResourceIndexError && error.code === "contract_rejected",
    );
  });

  await t.test("MIME mismatch", async () => {
    const changed = structuredClone(original);
    changed.files.find((item) => item.path === "assets/sqlite3.wasm").mediaType = "text/javascript";
    await assert.rejects(
      createVerifiedResourceIndex(changed, optionsFor(changed)),
      (error) => error instanceof VerifiedResourceIndexError && error.code === "contract_rejected",
    );
  });
});
