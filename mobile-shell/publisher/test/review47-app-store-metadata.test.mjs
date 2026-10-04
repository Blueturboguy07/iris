// New test file for unit m3-guideline47 (App Store Guideline 4.7 obligations).
// Exercises attachAppStoreMetadata and approvePublisherBuild's optional
// appStoreMetadata parameter. Does not duplicate publisher-prep.test.mjs's
// own assertions about preparation/approval identity binding.
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  APP_STORE_METADATA_KIND,
  APP_STORE_METADATA_VERSION,
} from "../../contracts/index.js";
import {
  approvePublisherBuild,
  attachAppStoreMetadata,
  descriptorFromPackageBytes,
  preparePublisherBuild,
} from "../index.mjs";

const SYNTHETIC_HTML = "<!doctype html><html><body>Review47 fixture</body></html>";

function goodMetadata(overrides = {}) {
  return {
    kind: APP_STORE_METADATA_KIND,
    version: APP_STORE_METADATA_VERSION,
    ageRating: 4,
    privacySummary: "This synthetic fixture app stores nothing off-device.",
    privacyPolicyUrl: "https://publikhq.com/legal/privacy",
    supportContact: { kind: "email", value: "support@publikhq.com" },
    reportContact: { kind: "email", value: "report@publikhq.com" },
    ...overrides,
  };
}

async function preparedFixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-review47-"));
  const sourceRoot = join(root, "reviewed-source");
  const buildRoot = join(root, "build");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(buildRoot, { recursive: true });
  await writeFile(join(sourceRoot, "REVIEWED_FIXTURE.txt"), "Synthetic reviewed source fixture only\n", "utf8");
  await writeFile(join(buildRoot, "index.html"), SYNTHETIC_HTML, "utf8");
  const preparation = await preparePublisherBuild({
    sourceRoot,
    buildOutputRoot: buildRoot,
    sourceOwner: "synthetic-owner",
    sourceRepo: "synthetic-repo",
    sourceCommit: "2".repeat(40),
    appSlug: "synthetic-review47-fixture",
    appId: "synthetic.review47.fixture",
    projectId: "synthetic.review47.fixture.project",
    displayName: "Synthetic Review47 Fixture",
    entrypoint: "index.html",
    minShellVersion: "1.0.0",
    capabilities: [],
    dataNamespace: "synthetic.review47.fixture",
    preparedAt: "2026-09-27T00:00:00.000Z",
  });
  return { root, preparation };
}

test("attachAppStoreMetadata adds a validated object without mutating the input descriptor", async () => {
  const fx = await preparedFixture();
  const approved = await approvePublisherBuild({
    preparation: fx.preparation,
    approved: true,
    approvedSourceCommit: "2".repeat(40),
    downloadUrl: "https://publikhq.com/artifacts/review47-fixture.irisapp",
  });
  const bareDescriptor = await descriptorFromPackageBytes(
    approved.packageBytes,
    "https://publikhq.com/artifacts/review47-fixture.irisapp",
  );
  assert.equal("appStoreMetadata" in bareDescriptor, false, "a bare descriptor carries no metadata field at all");

  const withMetadata = attachAppStoreMetadata(bareDescriptor, goodMetadata());
  assert.equal(withMetadata.appStoreMetadata.ageRating, 4);
  assert.equal(bareDescriptor.appStoreMetadata, undefined, "attach must not mutate its input");
  assert.throws(() => { withMetadata.appId = "tampered"; }, "the returned descriptor stays frozen");

  assert.throws(
    () => attachAppStoreMetadata(bareDescriptor, goodMetadata({ ageRating: 17 })),
    /appStoreMetadata/,
  );
});

test("approvePublisherBuild with appStoreMetadata carries it into descriptor and receipt.mobileShell", async () => {
  const fx = await preparedFixture();
  const result = await approvePublisherBuild({
    preparation: fx.preparation,
    approved: true,
    approvedSourceCommit: "2".repeat(40),
    downloadUrl: "https://publikhq.com/artifacts/review47-with-metadata.irisapp",
    appStoreMetadata: goodMetadata({ ageRating: 9 }),
  });
  assert.equal(result.descriptor.appStoreMetadata.ageRating, 9);
  assert.equal(result.receipt.mobileShell.appStoreMetadata.ageRating, 9);
  assert.equal(result.receipt.mobileShell.revisionId, fx.preparation.revision.revisionId);
});

test("approvePublisherBuild with no appStoreMetadata argument leaves an ordinary installable descriptor", async () => {
  const fx = await preparedFixture();
  const result = await approvePublisherBuild({
    preparation: fx.preparation,
    approved: true,
    approvedSourceCommit: "2".repeat(40),
    downloadUrl: "https://publikhq.com/artifacts/review47-without-metadata.irisapp",
  });
  assert.equal("appStoreMetadata" in result.descriptor, false);
  assert.equal("appStoreMetadata" in result.receipt.mobileShell, false);
  // The core install-time fields that matter for installability are present
  // and unaffected by the metadata feature being unused.
  assert.equal(result.descriptor.revisionId, fx.preparation.revision.revisionId);
});

test("approvePublisherBuild rejects hostile appStoreMetadata before any file is written", async () => {
  const fx = await preparedFixture();
  await assert.rejects(
    approvePublisherBuild({
      preparation: fx.preparation,
      approved: true,
      approvedSourceCommit: "2".repeat(40),
      downloadUrl: "https://publikhq.com/artifacts/review47-hostile.irisapp",
      appStoreMetadata: goodMetadata({ privacyPolicyUrl: "javascript:alert(1)" }),
    }),
    /appStoreMetadata/,
  );
});
