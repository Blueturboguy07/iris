// New test file for unit m3-guideline47 (App Store Guideline 4.7 obligations).
// Exercises the optional Guideline 4.7 metadata flags on `cli.mjs approve`
// end to end as a real child process, the same way publisher-cli-hardening
// tests the CLI, without duplicating that file's own assertions.
// RC-14 note: every successful `approve` invocation below now also passes
// `--policy-checked 1` (the current mobile-shell/publisher/APP_POLICY.md
// version), which RC-14 made a required flag; see
// test/policy-attestation-cli.test.mjs for the policy gate's own coverage.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { preparePublisherBuild } from "../index.mjs";

const execFileAsync = promisify(execFile);
const CLI = new URL("../cli.mjs", import.meta.url).pathname;

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-review47-cli-"));
  const sourceRoot = join(root, "source");
  const buildRoot = join(root, "build");
  const outputRoot = join(root, "output");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(buildRoot, { recursive: true });
  await mkdir(outputRoot, { recursive: true });
  await writeFile(join(sourceRoot, "SYNTHETIC_SOURCE.txt"), "synthetic source only\n", "utf8");
  await writeFile(join(buildRoot, "index.html"), "<!doctype html><main>Synthetic Review47 CLI fixture</main>\n", "utf8");
  const preparation = await preparePublisherBuild({
    sourceRoot,
    buildOutputRoot: buildRoot,
    sourceOwner: "synthetic-owner",
    sourceRepo: "synthetic-repo",
    sourceCommit: "b".repeat(40),
    appSlug: "synthetic-review47-cli-fixture",
    appId: "synthetic.review47.cli.fixture",
    projectId: "synthetic.review47.cli.fixture.project",
    displayName: "Synthetic Review47 CLI Fixture",
    capabilities: [],
    dataNamespace: "synthetic.review47.cli.fixture",
    preparedAt: "2026-09-27T00:05:00.000Z",
  });
  const preparationPath = join(outputRoot, "preparation.json");
  await writeFile(preparationPath, `${JSON.stringify(preparation, null, 2)}\n`, "utf8");
  return { root, outputRoot, preparationPath };
}

const METADATA_FLAGS = [
  "--age-rating", "9",
  "--privacy-summary", "This fixture app stores nothing off-device.",
  "--privacy-policy-url", "https://publikhq.com/legal/privacy",
  "--support-contact-kind", "email",
  "--support-contact-value", "support@publikhq.com",
  "--report-contact-kind", "email",
  "--report-contact-value", "report@publikhq.com",
];

test("CLI approve with all seven Guideline 4.7 flags writes an appStoreMetadata-bearing descriptor", async () => {
  const fx = await fixture();
  const packageOut = join(fx.outputRoot, "app.irisapp");
  const descriptorOut = join(fx.outputRoot, "descriptor.json");
  const receiptOut = join(fx.outputRoot, "receipt.json");
  await execFileAsync(process.execPath, [
    CLI, "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--policy-checked", "1",
    "--approve-source-commit", "b".repeat(40),
    "--download-url", "https://publikhq.com/artifacts/review47-cli.irisapp",
    "--package-out", packageOut,
    "--descriptor-out", descriptorOut,
    "--receipt-out", receiptOut,
    ...METADATA_FLAGS,
  ]);
  const descriptor = JSON.parse(await readFile(descriptorOut, "utf8"));
  assert.equal(descriptor.appStoreMetadata.ageRating, 9);
  assert.equal(descriptor.appStoreMetadata.supportContact.value, "support@publikhq.com");
  const receipt = JSON.parse(await readFile(receiptOut, "utf8"));
  assert.equal(receipt.mobileShell.appStoreMetadata.ageRating, 9);
});

test("CLI approve with no Guideline 4.7 flags still writes an ordinary installable descriptor", async () => {
  const fx = await fixture();
  const packageOut = join(fx.outputRoot, "app.irisapp");
  const descriptorOut = join(fx.outputRoot, "descriptor.json");
  const receiptOut = join(fx.outputRoot, "receipt.json");
  await execFileAsync(process.execPath, [
    CLI, "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--policy-checked", "1",
    "--approve-source-commit", "b".repeat(40),
    "--download-url", "https://publikhq.com/artifacts/review47-cli-bare.irisapp",
    "--package-out", packageOut,
    "--descriptor-out", descriptorOut,
    "--receipt-out", receiptOut,
  ]);
  const descriptor = JSON.parse(await readFile(descriptorOut, "utf8"));
  assert.equal("appStoreMetadata" in descriptor, false);
});

test("CLI approve rejects a partial set of Guideline 4.7 flags instead of silently dropping them", async () => {
  const fx = await fixture();
  const packageOut = join(fx.outputRoot, "app.irisapp");
  const descriptorOut = join(fx.outputRoot, "descriptor.json");
  const receiptOut = join(fx.outputRoot, "receipt.json");
  await assert.rejects(
    execFileAsync(process.execPath, [
      CLI, "approve",
      "--preparation", fx.preparationPath,
      "--approve-reviewed-output",
      "--approve-source-commit", "b".repeat(40),
      "--download-url", "https://publikhq.com/artifacts/review47-cli-partial.irisapp",
      "--package-out", packageOut,
      "--descriptor-out", descriptorOut,
      "--receipt-out", receiptOut,
      "--age-rating", "9",
    ]),
    (error) => {
      assert.match(error.stderr, /must be supplied together/);
      return true;
    },
  );
  await assert.rejects(readFile(descriptorOut), { code: "ENOENT" });
});
