import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { validateEditRequestV1 } from "../../contracts/index.js";
import { verifyPackageTransport } from "../../web/runtime.mjs";
import {
  DurableReceiptStore,
  ReceiptReplayError,
  approveStagedRevision,
  createDeliveryPackage,
  handleEditRequest,
  stageRevision,
} from "../index.mjs";

const execFileAsync = promisify(execFile);
const BASE_REVISION = `rev-sha256:${"1".repeat(64)}`;
const OTHER_REVISION = `rev-sha256:${"2".repeat(64)}`;
const APP_ID = "iris.desktop-test";
const PROJECT_ID = "iris.desktop-test.mobile";
const HTML = "<!doctype html><meta charset=utf-8><title>Desktop test</title><main>Hello</main>";

function registration(clonePath) {
  return {
    kind: "iris.mobile-shell.desktop-project",
    version: 1,
    appId: APP_ID,
    projectId: PROJECT_ID,
    appSlug: "desktop-test",
    provenance: {
      kind: "guideSourceClone",
      clonePath,
      pinnedCommit: "a".repeat(40),
      canonicalRepo: "publik/desktop-test",
    },
  };
}

function manifest(overrides = {}) {
  return {
    kind: "iris.mobile-shell.manifest",
    version: 1,
    appId: APP_ID,
    projectId: PROJECT_ID,
    displayName: "Desktop Test",
    runtime: { type: "web", entrypoint: "index.html", minShellVersion: "1.0.0" },
    capabilities: ["web.storage"],
    data: { namespace: APP_ID, updatePolicy: "preserve" },
    ...overrides,
  };
}

function review(overrides = {}) {
  return {
    kind: "iris.mobile-shell.desktop-package-review",
    version: 1,
    reviewedAt: "2026-09-16T23:30:00.000Z",
    baseRevisionId: BASE_REVISION,
    manifest: manifest(),
    files: [{ path: "index.html", mediaType: "text/html" }],
    ...overrides,
  };
}

function editRequest(overrides = {}) {
  return {
    kind: "iris.mobile-shell.edit-request",
    version: 1,
    requestId: "req_desktop_test_1234",
    nonce: "a".repeat(64),
    appId: APP_ID,
    projectId: PROJECT_ID,
    baseRevisionId: BASE_REVISION,
    requestedAt: "2026-09-16T23:31:00.000Z",
    intent: { type: "feature", text: "Make the primary action easier to see" },
    ...overrides,
  };
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-desktop-delivery-"));
  const clonePath = join(root, "source");
  const buildRoot = join(root, "build");
  const userDataRoot = join(root, "userdata");
  await mkdir(join(clonePath, ".git"), { recursive: true });
  await mkdir(buildRoot, { recursive: true });
  await mkdir(userDataRoot, { recursive: true });
  await writeFile(join(buildRoot, "index.html"), HTML, "utf8");
  await writeFile(join(userDataRoot, "note.json"), JSON.stringify({ privateNote: "reader data stays local" }), "utf8");
  return {
    root,
    clonePath,
    buildRoot,
    userDataRoot,
    registration: registration(clonePath),
    review: review(),
    receiptPath: join(root, "receipts", "desktop.json"),
  };
}

async function stagedFixture() {
  const fx = await fixture();
  const stage = await stageRevision({
    registration: fx.registration,
    buildOutputRoot: fx.buildRoot,
    review: fx.review,
    currentRevisionId: BASE_REVISION,
    createdAt: "2026-09-16T23:32:00.000Z",
  });
  return { ...fx, stage };
}

test("desktop stage -> explicit approval -> delivery round-trips through the real web verifier", async () => {
  const fx = await stagedFixture();
  const receiptStore = new DurableReceiptStore(fx.receiptPath);
  const approved = await approveStagedRevision({
    registration: fx.registration,
    stage: fx.stage,
    currentRevisionId: BASE_REVISION,
    receiptStore,
    localApproval: true,
    approvedAt: "2026-09-16T23:33:00.000Z",
  });
  const pkg = await createDeliveryPackage({
    registration: fx.registration,
    approvedStage: approved,
    currentRevisionId: BASE_REVISION,
    receiptStore,
    deliveryNonce: "d".repeat(64),
    issuedAt: "2026-09-16T23:34:00.000Z",
  });

  assert.deepEqual(Object.keys(pkg).sort(), ["approval", "envelope", "files", "format"]);
  assert.deepEqual(Object.keys(pkg.files[0]).sort(), ["contentBase64", "mediaType", "path"]);
  assert.equal(pkg.format, "iris.mobile-shell.package+json");
  assert.equal(pkg.envelope.revision.revisionId, fx.stage.revision.revisionId);

  const imported = await verifyPackageTransport(pkg, {
    currentRevisionId: BASE_REVISION,
    usedDeliveryNonces: new Set(),
  });
  assert.equal(imported.revision.revisionId, fx.stage.revision.revisionId);
  assert.equal(imported.compatible, true);
  assert.equal(Buffer.from(pkg.files[0].contentBase64, "base64").toString("utf8"), HTML);
});

test("staging creates a shared content-addressed immutable revision and excludes sibling user data", async () => {
  const fx = await stagedFixture();
  assert.match(fx.stage.revision.revisionId, /^rev-sha256:[0-9a-f]{64}$/);
  assert.equal(fx.stage.revision.manifest.data.namespace, APP_ID);
  assert.deepEqual(fx.stage.revision.files.map((file) => file.path), ["index.html"]);
  assert.equal(fx.stage.files.length, 1);
  const userData = await readFile(join(fx.userDataRoot, "note.json"), "utf8");
  assert.match(userData, /reader data stays local/);
  assert.doesNotMatch(Buffer.from(fx.stage.files[0].contentBase64, "base64").toString("utf8"), /reader data stays local/);
});

test("approval is a separate explicit local action", async () => {
  const fx = await stagedFixture();
  await assert.rejects(
    approveStagedRevision({
      registration: fx.registration,
      stage: fx.stage,
      currentRevisionId: BASE_REVISION,
      receiptStore: new DurableReceiptStore(fx.receiptPath),
      localApproval: false,
    }),
    /explicit local approval is required/,
  );
});

test("staging rejects stale base, wrong project, and unknown capabilities", async () => {
  const fx = await fixture();
  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: fx.review,
      currentRevisionId: OTHER_REVISION,
    }),
    /baseRevisionId is stale/,
  );

  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: review({ manifest: manifest({ projectId: "iris.other-project" }) }),
      currentRevisionId: BASE_REVISION,
    }),
    /wrong app\/project/,
  );

  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: review({ manifest: manifest({ appId: "iris.other-app" }) }),
      currentRevisionId: BASE_REVISION,
    }),
    /wrong app\/project/,
  );

  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: review({ manifest: manifest({ capabilities: ["native.execute-shell"] }) }),
      currentRevisionId: BASE_REVISION,
    }),
    /capability is unsupported/,
  );
});

test("build-output traversal, symlinks, missing files and unreviewed extra files are rejected", async () => {
  const fx = await fixture();
  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: review({ files: [{ path: "../index.html", mediaType: "text/html" }] }),
      currentRevisionId: BASE_REVISION,
    }),
    /path is unsafe/,
  );

  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: review({
        files: [
          { path: "index.html", mediaType: "text/html" },
          { path: "missing.css", mediaType: "text/css" },
        ],
      }),
      currentRevisionId: BASE_REVISION,
    }),
    /missing reviewed files: missing\.css/,
  );

  await writeFile(join(fx.buildRoot, "extra.txt"), "extra", "utf8");
  await assert.rejects(
    stageRevision({
      registration: fx.registration,
      buildOutputRoot: fx.buildRoot,
      review: fx.review,
      currentRevisionId: BASE_REVISION,
    }),
    /unreviewed extra files: extra\.txt/,
  );

  const symlinkFx = await fixture();
  await symlink(join(symlinkFx.buildRoot, "index.html"), join(symlinkFx.buildOutputRoot ?? symlinkFx.buildRoot, "linked.html"));
  await assert.rejects(
    stageRevision({
      registration: symlinkFx.registration,
      buildOutputRoot: symlinkFx.buildRoot,
      review: review({
        files: [
          { path: "index.html", mediaType: "text/html" },
          { path: "linked.html", mediaType: "text/html" },
        ],
      }),
      currentRevisionId: BASE_REVISION,
    }),
    /may not be a symlink/,
  );
});

test("corrupted inline bytes are rejected by the real web importer", async () => {
  const fx = await stagedFixture();
  const receiptStore = new DurableReceiptStore(fx.receiptPath);
  const approved = await approveStagedRevision({
    registration: fx.registration,
    stage: fx.stage,
    currentRevisionId: BASE_REVISION,
    receiptStore,
    localApproval: true,
  });
  const pkg = await createDeliveryPackage({
    registration: fx.registration,
    approvedStage: approved,
    currentRevisionId: BASE_REVISION,
    receiptStore,
    deliveryNonce: "e".repeat(64),
  });
  const corrupt = structuredClone(pkg);
  const bytes = Buffer.from(corrupt.files[0].contentBase64, "base64");
  bytes[0] ^= 0xff;
  corrupt.files[0].contentBase64 = bytes.toString("base64");
  await assert.rejects(
    verifyPackageTransport(corrupt, { currentRevisionId: BASE_REVISION, usedDeliveryNonces: new Set() }),
    /SHA-256 does not match|Byte-size mismatch|byte length does not match/,
  );
});

test("phone requests are strict intent only and the standalone adapter reports an unwired editor", async () => {
  const fx = await fixture();
  const request = editRequest();
  assert.equal(validateEditRequestV1(request, { currentRevisionId: BASE_REVISION }).ok, true);
  const unsupported = await handleEditRequest({
    registration: fx.registration,
    request,
    currentRevisionId: BASE_REVISION,
    receiptStore: new DurableReceiptStore(fx.receiptPath),
  });
  assert.deepEqual(unsupported, {
    status: "unsupported",
    code: "edit_engine_unwired",
    message: "Desktop mobile-shell adapter has no Iris edit engine callback wired.",
  });

  await assert.rejects(
    handleEditRequest({
      registration: fx.registration,
      request: { ...request, argv: ["rm", "-rf", "/"] },
      currentRevisionId: BASE_REVISION,
    }),
    /argv is not a v1 field/,
  );
});

test("phone request invokes the existing edit callback only after live provenance and consumes durable replay receipt", async () => {
  const fx = await fixture();
  const request = editRequest();
  const events = [];
  const receiptStore = new DurableReceiptStore(fx.receiptPath);
  const provenanceCheck = async ({ registration: trusted, currentRevisionId }) => {
    events.push("provenance");
    assert.equal(trusted.provenance.clonePath, fx.clonePath);
    return {
      ok: true,
      provenanceKind: "guideSourceClone",
      appId: trusted.appId,
      projectId: trusted.projectId,
      currentRevisionId,
    };
  };
  const editCallback = async ({ request: intent }) => {
    events.push("edit");
    assert.deepEqual(Object.keys(intent).sort(), [
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
    assert.equal(intent.intent.text, "Make the primary action easier to see");
    return { branch: "iris/mobile-request" };
  };
  const accepted = await handleEditRequest({
    registration: fx.registration,
    request,
    currentRevisionId: BASE_REVISION,
    receiptStore,
    provenanceCheck,
    editCallback,
  });
  assert.equal(accepted.status, "accepted");
  assert.deepEqual(events, ["provenance", "edit"]);

  const reopened = new DurableReceiptStore(fx.receiptPath);
  await assert.rejects(
    handleEditRequest({
      registration: fx.registration,
      request,
      currentRevisionId: BASE_REVISION,
      receiptStore: reopened,
      provenanceCheck,
      editCallback,
    }),
    (error) => error instanceof ReceiptReplayError && error.code === "replayed_request",
  );
  assert.deepEqual(events, ["provenance", "edit"]);
});

test("request-bound approval requires the exact accepted request receipt", async () => {
  const fx = await stagedFixture();
  const request = editRequest();
  const receipts = new DurableReceiptStore(fx.receiptPath);
  await assert.rejects(
    approveStagedRevision({
      registration: fx.registration,
      stage: fx.stage,
      currentRevisionId: BASE_REVISION,
      receiptStore: receipts,
      editRequest: request,
      localApproval: true,
    }),
    /durable accepted-request receipt/,
  );

  await handleEditRequest({
    registration: fx.registration,
    request,
    currentRevisionId: BASE_REVISION,
    receiptStore: receipts,
    provenanceCheck: ({ registration: trusted, currentRevisionId }) => ({
      ok: true,
      provenanceKind: "guideSourceClone",
      appId: trusted.appId,
      projectId: trusted.projectId,
      currentRevisionId,
    }),
    editCallback: () => ({ accepted: true }),
  });
  const approved = await approveStagedRevision({
    registration: fx.registration,
    stage: fx.stage,
    currentRevisionId: BASE_REVISION,
    receiptStore: receipts,
    editRequest: request,
    localApproval: true,
  });
  assert.equal(approved.approval.requestId, request.requestId);
  assert.equal(approved.approval.requestNonce, request.nonce);
});

test("delivery rejects stale/wrong project and durable delivery replay after receipt-store reopen", async () => {
  const fx = await stagedFixture();
  const receipts = new DurableReceiptStore(fx.receiptPath);
  const approved = await approveStagedRevision({
    registration: fx.registration,
    stage: fx.stage,
    currentRevisionId: BASE_REVISION,
    receiptStore: receipts,
    localApproval: true,
  });
  await assert.rejects(
    createDeliveryPackage({
      registration: fx.registration,
      approvedStage: approved,
      currentRevisionId: OTHER_REVISION,
      receiptStore: receipts,
      deliveryNonce: "f".repeat(64),
    }),
    /baseRevisionId is stale/,
  );

  const wrongRegistration = { ...fx.registration, projectId: "iris.other-project" };
  await assert.rejects(
    createDeliveryPackage({
      registration: wrongRegistration,
      approvedStage: approved,
      currentRevisionId: BASE_REVISION,
      receiptStore: receipts,
      deliveryNonce: "f".repeat(64),
    }),
    /wrong app\/project/,
  );

  const nonce = "f".repeat(64);
  await createDeliveryPackage({
    registration: fx.registration,
    approvedStage: approved,
    currentRevisionId: BASE_REVISION,
    receiptStore: receipts,
    deliveryNonce: nonce,
  });
  const reopened = new DurableReceiptStore(fx.receiptPath);
  await assert.rejects(
    createDeliveryPackage({
      registration: fx.registration,
      approvedStage: approved,
      currentRevisionId: BASE_REVISION,
      receiptStore: reopened,
      deliveryNonce: nonce,
    }),
    (error) => error instanceof ReceiptReplayError && error.code === "replayed_delivery",
  );
});

test("CLI request path visibly reports unsupported instead of inventing a second edit engine", async () => {
  const fx = await fixture();
  const registrationPath = join(fx.root, "registration.json");
  const requestPath = join(fx.root, "request.json");
  await writeFile(registrationPath, JSON.stringify(fx.registration), "utf8");
  await writeFile(requestPath, JSON.stringify(editRequest()), "utf8");

  await assert.rejects(
    execFileAsync(process.execPath, [
      new URL("../cli.mjs", import.meta.url).pathname,
      "request",
      "--registration", registrationPath,
      "--request", requestPath,
      "--current-base", BASE_REVISION,
      "--receipts", fx.receiptPath,
    ]),
    (error) => {
      assert.equal(error.code, 2);
      const output = JSON.parse(error.stdout.trim());
      assert.equal(output.status, "unsupported");
      assert.equal(output.code, "edit_engine_unwired");
      return true;
    },
  );
});

test("CLI stage, explicit approve, and deliver commands produce a web-importable package", async () => {
  const fx = await fixture();
  const cliPath = new URL("../cli.mjs", import.meta.url).pathname;
  const registrationPath = join(fx.root, "registration.json");
  const reviewPath = join(fx.root, "review.json");
  const stagePath = join(fx.root, "stage.json");
  const approvedPath = join(fx.root, "approved.json");
  const packagePath = join(fx.root, "package.json");
  await writeFile(registrationPath, JSON.stringify(fx.registration), "utf8");
  await writeFile(reviewPath, JSON.stringify(fx.review), "utf8");

  const staged = await execFileAsync(process.execPath, [
    cliPath,
    "stage",
    "--registration", registrationPath,
    "--review", reviewPath,
    "--root", fx.buildRoot,
    "--current-base", BASE_REVISION,
    "--out", stagePath,
  ]);
  assert.equal(JSON.parse(staged.stdout.trim()).status, "staged");

  const approved = await execFileAsync(process.execPath, [
    cliPath,
    "approve",
    "--registration", registrationPath,
    "--stage", stagePath,
    "--current-base", BASE_REVISION,
    "--receipts", fx.receiptPath,
    "--approve",
    "--out", approvedPath,
  ]);
  assert.equal(JSON.parse(approved.stdout.trim()).status, "approved");

  const delivered = await execFileAsync(process.execPath, [
    cliPath,
    "deliver",
    "--registration", registrationPath,
    "--approved", approvedPath,
    "--current-base", BASE_REVISION,
    "--receipts", fx.receiptPath,
    "--delivery-nonce", "9".repeat(64),
    "--out", packagePath,
  ]);
  assert.equal(JSON.parse(delivered.stdout.trim()).status, "packaged");

  const pkg = JSON.parse(await readFile(packagePath, "utf8"));
  const imported = await verifyPackageTransport(pkg, {
    currentRevisionId: BASE_REVISION,
    usedDeliveryNonces: new Set(),
  });
  assert.equal(imported.compatible, true);
  assert.equal(imported.revision.revisionId, pkg.envelope.revisionId);
});
