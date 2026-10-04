import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, symlink, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  LUNARA_REVIEWED_SOURCE,
  PUBLISHER_PREP_LIMITS,
  approvePublisherBuild,
  assertLunaraPreparation,
  descriptorFromPackageBytes,
  isSHA256,
  preparePublisherBuild,
} from "../index.mjs";
import { DELIVERY_PACKAGE_LIMITS } from "../../contracts/index.js";

// Positive fixtures must be loadable by the current file-origin runtime. The
// previously accepted external-module shape now has explicit rejection tests.
const SYNTHETIC_HTML = `<!doctype html><html><head><link rel="stylesheet" href="assets/app.css"></head><body><main id="app">Synthetic publisher fixture</main><script defer src="assets/app.js"></script></body></html>`;
const SYNTHETIC_JS = `localStorage.setItem("synthetic-fixture", "1");\n`;
const SYNTHETIC_CSS = "body { font-family: sans-serif; }\n";

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-prep-"));
  const sourceRoot = join(root, "reviewed-source");
  const buildRoot = join(root, "build");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(join(buildRoot, "assets"), { recursive: true });
  await writeFile(join(sourceRoot, "REVIEWED_FIXTURE.txt"), "Synthetic reviewed source fixture only\n", "utf8");
  await writeFile(join(buildRoot, "index.html"), SYNTHETIC_HTML, "utf8");
  await writeFile(join(buildRoot, "assets", "app.js"), SYNTHETIC_JS, "utf8");
  await writeFile(join(buildRoot, "assets", "app.css"), SYNTHETIC_CSS, "utf8");
  return { root, sourceRoot, buildRoot };
}

async function preparedFixture(overrides = {}) {
  const fx = await fixture();
  const preparation = await preparePublisherBuild({
    sourceRoot: fx.sourceRoot,
    buildOutputRoot: fx.buildRoot,
    sourceOwner: "synthetic-owner",
    sourceRepo: "synthetic-repo",
    sourceCommit: "1".repeat(40),
    appSlug: "synthetic-mobile-fixture",
    appId: "synthetic.mobile.fixture",
    projectId: "synthetic.mobile.fixture.project",
    displayName: "Synthetic Mobile Fixture",
    entrypoint: "index.html",
    minShellVersion: "1.0.0",
    capabilities: ["web.storage"],
    dataNamespace: "synthetic.mobile.fixture",
    preparedAt: "2026-09-18T02:00:00.000Z",
    ...overrides,
  });
  return { ...fx, preparation };
}

test("prepare binds reviewed source provenance to exact relative build bytes", async () => {
  const fx = await preparedFixture();
  assert.equal(fx.preparation.source.kind, "caller-attested-reviewed-source-root");
  assert.equal(fx.preparation.source.verification, "not independently verified by this offline tool");
  assert.equal(fx.preparation.source.commit, "1".repeat(40));
  assert.equal(fx.preparation.revision.manifest.capabilities[0], "web.storage");
  assert.deepEqual(
    fx.preparation.revision.files.map((file) => file.path),
    ["assets/app.css", "assets/app.js", "index.html"],
  );
  assert.ok(fx.preparation.revision.files.every((file) => !file.path.startsWith("/")));
  assert.match(fx.preparation.preparationHash, /^sha256:[0-9a-f]{64}$/);
});

// MV3 (mobile-versions SPEC.md section 2.6, owner-decided 2026-09-28
// "Contract v1.1 changes ships now, while the shell is TestFlight only").
test("prepare carries a changes argument into the revision, covered by contentHash", async () => {
  const changes = [{ title: "Added: Dark mode", kind: "added", target: null }];
  const withChanges = await preparedFixture({ minShellVersion: "1.1.0", changes });
  assert.deepEqual(withChanges.preparation.revision.changes, changes);

  const without = await preparedFixture({ minShellVersion: "1.1.0" });
  assert.equal("changes" in without.preparation.revision, false);
  assert.notEqual(
    withChanges.preparation.revision.contentHash,
    without.preparation.revision.contentHash,
    "identical file/manifest content with and without changes must not collide",
  );
});

test("prepare refuses changes when minShellVersion is below the first shell version that understands the field", async () => {
  await assert.rejects(
    () => preparedFixture({
      minShellVersion: "1.0.0",
      changes: [{ title: "Added: Dark mode", kind: "added", target: null }],
    }),
    /changes requires minShellVersion >= 1\.1\.0/,
  );
});

test("prepare refuses a malformed changes argument before any file is hashed or written", async () => {
  await assert.rejects(
    () => preparedFixture({
      minShellVersion: "1.1.0",
      changes: [{ title: "not a recognized shape", kind: "modified", target: null }],
    }),
    /kind must be added or removed/,
  );
});

test("approval is explicit, re-hashes bytes, and derives descriptor from exact package bytes", async () => {
  const fx = await preparedFixture();
  await assert.rejects(
    approvePublisherBuild({
      preparation: fx.preparation,
      approved: false,
      approvedSourceCommit: "1".repeat(40),
      downloadUrl: "https://publikhq.com/artifacts/synthetic.irisapp",
    }),
    /explicit publisher approval/,
  );
  const result = await approvePublisherBuild({
    preparation: fx.preparation,
    approved: true,
    approvedSourceCommit: "1".repeat(40),
    downloadUrl: "https://publikhq.com/artifacts/synthetic.irisapp",
    approvedAt: "2026-09-18T02:01:00.000Z",
    approvalId: "approval_synthetic_fixture_0001",
    envelopeId: "delivery_synthetic_fixture_0001",
    deliveryNonce: "d".repeat(64),
  });
  assert.equal(result.package.format, "iris.mobile-shell.package+json");
  assert.equal(result.descriptor.downloadUrl, "https://publikhq.com/artifacts/synthetic.irisapp");
  assert.equal(result.descriptor.byteCount, result.packageBytes.byteLength);
  assert.equal(isSHA256(result.descriptor.packageSha256), true);
  assert.equal(result.descriptor.revisionId, fx.preparation.revision.revisionId);
  assert.equal(result.receipt.source.commit, "1".repeat(40));
  assert.deepEqual(result.receipt.package.requestedCapabilities, ["web.storage"]);
  const derived = await descriptorFromPackageBytes(
    result.packageBytes,
    "https://publikhq.com/artifacts/synthetic.irisapp",
  );
  assert.deepEqual(derived, result.descriptor);
});

test("publisher binds media export to exact approved package and cannot add it after review", async () => {
  const fx = await preparedFixture({ capabilities: ["web.media.export"] });
  const result = await approvePublisherBuild({
    preparation: fx.preparation,
    approved: true,
    approvedSourceCommit: "1".repeat(40),
    downloadUrl: "https://publikhq.com/_synthetic_not_published/export.irisapp",
  });
  assert.deepEqual(result.package.envelope.revision.manifest.capabilities, ["web.media.export"]);
  assert.deepEqual(result.receipt.package.requestedCapabilities, ["web.media.export"]);
  const ordinary = await preparedFixture();
  ordinary.preparation.revision.manifest.capabilities.push("web.media.export");
  await assert.rejects(approvePublisherBuild({
    preparation: ordinary.preparation,
    approved: true,
    approvedSourceCommit: "1".repeat(40),
    downloadUrl: "https://publikhq.com/_synthetic_not_published/export.irisapp",
  }));
});

test("approval refuses changed or added build output after preparation", async () => {
  const changed = await preparedFixture();
  await writeFile(join(changed.buildRoot, "assets", "app.js"), "changed after review\n", "utf8");
  await assert.rejects(
    approvePublisherBuild({
      preparation: changed.preparation,
      approved: true,
      approvedSourceCommit: "1".repeat(40),
      downloadUrl: "https://publikhq.com/artifacts/synthetic.irisapp",
    }),
    /build output changed after preparation/,
  );

  const extra = await preparedFixture();
  await writeFile(join(extra.buildRoot, "extra.txt"), "unreviewed extra\n", "utf8");
  await assert.rejects(
    approvePublisherBuild({
      preparation: extra.preparation,
      approved: true,
      approvedSourceCommit: "1".repeat(40),
      downloadUrl: "https://publikhq.com/artifacts/synthetic.irisapp",
    }),
    /build output changed after preparation/,
  );
});

test("prepare rejects non-relative entrypoint assets and symlinks", async () => {
  const absolute = await fixture();
  await writeFile(
    join(absolute.buildRoot, "index.html"),
    '<!doctype html><script type="module" src="/assets/app.js"></script>',
    "utf8",
  );
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: absolute.sourceRoot,
      buildOutputRoot: absolute.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "2".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /non-relative resource reference/,
  );

  const linked = await fixture();
  await symlink(join(linked.buildRoot, "assets", "app.js"), join(linked.buildRoot, "linked.js"));
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: linked.sourceRoot,
      buildOutputRoot: linked.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "3".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /may not be a symlink/,
  );
});

test("descriptor URL is explicit Publik HTTPS input and source pin approval must match", async () => {
  const fx = await preparedFixture();
  await assert.rejects(
    approvePublisherBuild({
      preparation: fx.preparation,
      approved: true,
      approvedSourceCommit: "4".repeat(40),
      downloadUrl: "https://publikhq.com/artifacts/synthetic.irisapp",
    }),
    /approved source commit does not match/,
  );
  await assert.rejects(
    approvePublisherBuild({
      preparation: fx.preparation,
      approved: true,
      approvedSourceCommit: "1".repeat(40),
      downloadUrl: "https://example.com/synthetic.irisapp",
    }),
    /exact reviewed Publik HTTPS URL/,
  );
  await assert.rejects(
    approvePublisherBuild({
      preparation: fx.preparation,
      approved: true,
      approvedSourceCommit: "1".repeat(40),
      downloadUrl: "https://publikhq.com:443/artifacts/synthetic.irisapp",
    }),
    /without an explicit port/,
  );
});

test("build traversal enforces file size, file count, depth, and unsafe path bounds before packaging", async () => {
  const oversize = await fixture();
  const oversizedPath = join(oversize.buildRoot, "oversized-sparse.bin");
  await writeFile(oversizedPath, "", "utf8");
  await truncate(oversizedPath, DELIVERY_PACKAGE_LIMITS.maxSingleFileBytes + 1);
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: oversize.sourceRoot,
      buildOutputRoot: oversize.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "5".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /exceeds the .*byte read limit/,
  );

  const tooMany = await fixture();
  for (let index = 0; index < DELIVERY_PACKAGE_LIMITS.maxFiles - 2; index += 1) {
    await writeFile(join(tooMany.buildRoot, `synthetic-${String(index).padStart(3, "0")}.txt`), "", "utf8");
  }
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: tooMany.sourceRoot,
      buildOutputRoot: tooMany.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "6".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /more than 256 files/,
  );

  const deep = await fixture();
  let cursor = deep.buildRoot;
  for (let depth = 0; depth <= PUBLISHER_PREP_LIMITS.maxBuildDepth; depth += 1) {
    cursor = join(cursor, `d${depth}`);
    await mkdir(cursor);
  }
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: deep.sourceRoot,
      buildOutputRoot: deep.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "7".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /directory depth exceeds 32/,
  );

  const unsafe = await fixture();
  await writeFile(join(unsafe.buildRoot, "bad%name.js"), "", "utf8");
  await assert.rejects(
    preparePublisherBuild({
      sourceRoot: unsafe.sourceRoot,
      buildOutputRoot: unsafe.buildRoot,
      sourceOwner: "synthetic-owner",
      sourceRepo: "synthetic-repo",
      sourceCommit: "8".repeat(40),
      appSlug: "synthetic-mobile-fixture",
      appId: "synthetic.mobile.fixture",
      projectId: "synthetic.mobile.fixture.project",
      displayName: "Synthetic Mobile Fixture",
      capabilities: ["web.storage"],
      dataNamespace: "synthetic.mobile.fixture",
    }),
    /unsafe build-output path/,
  );
});

test("raw package limit is checked before package bytes are copied or parsed", async () => {
  const oversizedByteLike = { byteLength: PUBLISHER_PREP_LIMITS.maxRawPackageBytes + 1 };
  await assert.rejects(
    descriptorFromPackageBytes(oversizedByteLike, "https://publikhq.com/artifacts/synthetic.irisapp"),
    /raw package limit/,
  );
});

test("Lunara assertion records the audited pin and requires durable web.storage", async () => {
  const fx = await fixture();
  const preparation = await preparePublisherBuild({
    sourceRoot: fx.sourceRoot,
    buildOutputRoot: fx.buildRoot,
    sourceOwner: LUNARA_REVIEWED_SOURCE.owner,
    sourceRepo: LUNARA_REVIEWED_SOURCE.repo,
    sourceCommit: LUNARA_REVIEWED_SOURCE.commit,
    appSlug: "lunara",
    appId: "synthetic.lunara.publisher-id",
    projectId: "synthetic.lunara.publisher-project",
    displayName: "Synthetic Lunara-shaped Fixture",
    capabilities: ["web.storage"],
    dataNamespace: "synthetic.lunara.publisher-data",
  });
  assert.equal(assertLunaraPreparation(preparation).source.commit, LUNARA_REVIEWED_SOURCE.commit);

  const withoutStorage = await preparePublisherBuild({
    sourceRoot: fx.sourceRoot,
    buildOutputRoot: fx.buildRoot,
    sourceOwner: LUNARA_REVIEWED_SOURCE.owner,
    sourceRepo: LUNARA_REVIEWED_SOURCE.repo,
    sourceCommit: LUNARA_REVIEWED_SOURCE.commit,
    appSlug: "lunara",
    appId: "synthetic.lunara.publisher-id",
    projectId: "synthetic.lunara.publisher-project",
    displayName: "Synthetic Lunara-shaped Fixture",
    capabilities: [],
    dataNamespace: "synthetic.lunara.publisher-data",
  });
  assert.throws(() => assertLunaraPreparation(withoutStorage), /must declare durable web.storage/);
});

test("source root is only provenance input; this module exposes no fetch/install/deploy surface", async () => {
  const source = await readFile(new URL("../index.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(source, /\bfetch\s*\(/);
  assert.doesNotMatch(source, /child_process|execFile|spawn\s*\(/);
  assert.doesNotMatch(source, /\bgit\s+clone\b|\bpnpm\s+install\b|\bnpm\s+install\b/);
});
