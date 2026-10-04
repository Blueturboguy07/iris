import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";

import { preparePublisherBuild } from "../index.mjs";

const execFileAsync = promisify(execFile);
const CLI = new URL("../cli.mjs", import.meta.url).pathname;

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-cli-"));
  const sourceRoot = join(root, "source");
  const buildRoot = join(root, "build");
  const outputRoot = join(root, "output");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(buildRoot, { recursive: true });
  await mkdir(outputRoot, { recursive: true });
  await writeFile(join(sourceRoot, "SYNTHETIC_SOURCE.txt"), "synthetic source only\n", "utf8");
  await writeFile(join(buildRoot, "index.html"), "<!doctype html><main>Synthetic CLI hardening fixture</main>\n", "utf8");
  const preparation = await preparePublisherBuild({
    sourceRoot,
    buildOutputRoot: buildRoot,
    sourceOwner: "synthetic-owner",
    sourceRepo: "synthetic-repo",
    sourceCommit: "a".repeat(40),
    appSlug: "synthetic-cli-fixture",
    appId: "synthetic.cli.fixture",
    projectId: "synthetic.cli.fixture.project",
    displayName: "Synthetic CLI Fixture",
    capabilities: ["web.storage"],
    dataNamespace: "synthetic.cli.fixture",
    preparedAt: "2026-09-18T03:30:00.000Z",
  });
  const preparationPath = join(outputRoot, "preparation.json");
  await writeFile(preparationPath, `${JSON.stringify(preparation, null, 2)}\n`, "utf8");
  return { root, sourceRoot, buildRoot, outputRoot, preparation, preparationPath };
}

async function expectCLIReject(args, pattern) {
  await assert.rejects(
    execFileAsync(process.execPath, [CLI, ...args]),
    (error) => {
      assert.match(error.stderr, pattern);
      return true;
    },
  );
}

test("CLI refuses existing outputs and leaves every existing file unchanged", async () => {
  const fx = await fixture();

  const existingPreparationOut = join(fx.outputRoot, "existing-preparation.json");
  await writeFile(existingPreparationOut, "KEEP PREPARATION\n", "utf8");
  await expectCLIReject([
    "prepare",
    "--source-root", fx.sourceRoot,
    "--build-root", fx.buildRoot,
    "--source-owner", "synthetic-owner",
    "--source-repo", "synthetic-repo",
    "--source-commit", "a".repeat(40),
    "--app-slug", "synthetic-cli-fixture",
    "--app-id", "synthetic.cli.fixture",
    "--project-id", "synthetic.cli.fixture.project",
    "--display-name", "Synthetic CLI Fixture",
    "--data-namespace", "synthetic.cli.fixture",
    "--capability", "web.storage",
    "--out", existingPreparationOut,
  ], /output already exists/);
  assert.equal(await readFile(existingPreparationOut, "utf8"), "KEEP PREPARATION\n");

  const packageOut = join(fx.outputRoot, "existing.irisapp");
  const descriptorOut = join(fx.outputRoot, "existing-descriptor.json");
  const receiptOut = join(fx.outputRoot, "existing-receipt.json");
  await writeFile(packageOut, "KEEP PACKAGE\n", "utf8");
  await writeFile(descriptorOut, "KEEP DESCRIPTOR\n", "utf8");
  await writeFile(receiptOut, "KEEP RECEIPT\n", "utf8");
  await expectCLIReject([
    "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--approve-source-commit", "a".repeat(40),
    "--download-url", "https://publikhq.com/_synthetic_not_published/cli.irisapp",
    "--package-out", packageOut,
    "--descriptor-out", descriptorOut,
    "--receipt-out", receiptOut,
  ], /output already exists/);
  assert.equal(await readFile(packageOut, "utf8"), "KEEP PACKAGE\n");
  assert.equal(await readFile(descriptorOut, "utf8"), "KEEP DESCRIPTOR\n");
  assert.equal(await readFile(receiptOut, "utf8"), "KEEP RECEIPT\n");
});

// MV3 (mobile-versions SPEC.md section 2.6): `--change` end to end through
// the real CLI process, not just `preparePublisherBuild` called in-process.
test("CLI prepare --change writes a revision carrying the parsed feature title", async () => {
  const fx = await fixture();
  const out = join(fx.outputRoot, "with-change-preparation.json");
  await execFileAsync(process.execPath, [
    CLI, "prepare",
    "--source-root", fx.sourceRoot,
    "--build-root", fx.buildRoot,
    "--source-owner", "synthetic-owner",
    "--source-repo", "synthetic-repo",
    "--source-commit", "a".repeat(40),
    "--app-slug", "synthetic-cli-change-fixture",
    "--app-id", "synthetic.cli.change.fixture",
    "--project-id", "synthetic.cli.change.fixture.project",
    "--display-name", "Synthetic CLI Change Fixture",
    "--data-namespace", "synthetic.cli.change.fixture",
    "--capability", "web.storage",
    "--min-shell-version", "1.1.0",
    "--change", "Added: Dark mode",
    "--out", out,
  ]);
  const written = JSON.parse(await readFile(out, "utf8"));
  assert.deepEqual(written.revision.changes, [{ title: "Added: Dark mode", kind: "added", target: null }]);
});

test("CLI prepare --change rejects a value with no recognized Added:/Removed: prefix", async () => {
  const fx = await fixture();
  await expectCLIReject([
    "prepare",
    "--source-root", fx.sourceRoot,
    "--build-root", fx.buildRoot,
    "--source-owner", "synthetic-owner",
    "--source-repo", "synthetic-repo",
    "--source-commit", "a".repeat(40),
    "--app-slug", "synthetic-cli-badchange-fixture",
    "--app-id", "synthetic.cli.badchange.fixture",
    "--project-id", "synthetic.cli.badchange.fixture.project",
    "--display-name", "Synthetic CLI Bad Change Fixture",
    "--data-namespace", "synthetic.cli.badchange.fixture",
    "--capability", "web.storage",
    "--min-shell-version", "1.1.0",
    "--change", "Dark mode, just added it",
    "--out", join(fx.outputRoot, "should-not-exist.json"),
  ], /--change must start with "Added: " or "Removed: "/);
});

test("CLI rejects output aliasing and any output inside supplied source/build roots", async () => {
  const fx = await fixture();
  const originalPreparation = await readFile(fx.preparationPath, "utf8");
  const collided = join(fx.outputRoot, "collision.json");
  await expectCLIReject([
    "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--approve-source-commit", "a".repeat(40),
    "--download-url", "https://publikhq.com/_synthetic_not_published/cli.irisapp",
    "--package-out", collided,
    "--descriptor-out", collided,
    "--receipt-out", join(fx.outputRoot, "receipt.json"),
  ], /output paths must be distinct/);

  await expectCLIReject([
    "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--approve-source-commit", "a".repeat(40),
    "--download-url", "https://publikhq.com/_synthetic_not_published/cli.irisapp",
    "--package-out", fx.preparationPath,
    "--descriptor-out", join(fx.outputRoot, "input-alias-descriptor.json"),
    "--receipt-out", join(fx.outputRoot, "input-alias-receipt.json"),
  ], /may not overwrite an input file/);
  assert.equal(await readFile(fx.preparationPath, "utf8"), originalPreparation);

  await expectCLIReject([
    "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--approve-source-commit", "a".repeat(40),
    "--download-url", "https://publikhq.com/_synthetic_not_published/cli.irisapp",
    "--package-out", join(fx.buildRoot, "must-not-write.irisapp"),
    "--descriptor-out", join(fx.outputRoot, "descriptor.json"),
    "--receipt-out", join(fx.outputRoot, "receipt.json"),
  ], /outside supplied source\/build roots/);

  await expectCLIReject([
    "prepare",
    "--source-root", fx.sourceRoot,
    "--build-root", fx.buildRoot,
    "--source-owner", "synthetic-owner",
    "--source-repo", "synthetic-repo",
    "--source-commit", "a".repeat(40),
    "--app-slug", "synthetic-cli-fixture",
    "--app-id", "synthetic.cli.fixture",
    "--project-id", "synthetic.cli.fixture.project",
    "--display-name", "Synthetic CLI Fixture",
    "--data-namespace", "synthetic.cli.fixture",
    "--capability", "web.storage",
    "--out", join(fx.sourceRoot, "must-not-write-preparation.json"),
  ], /outside supplied source\/build roots/);
});

test("CLI rejects an oversized preparation input before creating publication outputs", async () => {
  const fx = await fixture();
  const oversizedPreparation = join(fx.outputRoot, "oversized-preparation.json");
  await writeFile(oversizedPreparation, "", "utf8");
  await truncate(oversizedPreparation, 1024 * 1024 + 1);
  const packageOut = join(fx.outputRoot, "oversized.irisapp");
  const descriptorOut = join(fx.outputRoot, "oversized-descriptor.json");
  const receiptOut = join(fx.outputRoot, "oversized-receipt.json");
  await expectCLIReject([
    "approve",
    "--preparation", oversizedPreparation,
    "--approve-reviewed-output",
    "--approve-source-commit", "a".repeat(40),
    "--download-url", "https://publikhq.com/_synthetic_not_published/cli.irisapp",
    "--package-out", packageOut,
    "--descriptor-out", descriptorOut,
    "--receipt-out", receiptOut,
  ], /preparation input exceeds 1048576 bytes/);
  await assert.rejects(readFile(packageOut), /ENOENT/);
  await assert.rejects(readFile(descriptorOut), /ENOENT/);
  await assert.rejects(readFile(receiptOut), /ENOENT/);
});
