// RC-14: mobile-shell/publisher/APP_POLICY.md is the checklist every hosted
// app package must pass before the catalog lists it. `cli.mjs approve`
// enforces attestation against it via a required `--policy-checked
// <version>` flag. These tests exercise that gate end to end as a real
// child process, the same way publisher-cli-hardening and review47-cli
// test the CLI, without duplicating either file's own assertions.
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
const APP_POLICY_PATH = new URL("../APP_POLICY.md", import.meta.url);

async function currentPolicyVersion() {
  const text = await readFile(APP_POLICY_PATH, "utf8");
  const match = text.match(/^Policy version:\s*(\S+)\s*$/m);
  assert.ok(match, 'APP_POLICY.md must have a "Policy version:" line');
  return match[1];
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-policy-cli-"));
  const sourceRoot = join(root, "source");
  const buildRoot = join(root, "build");
  const outputRoot = join(root, "output");
  await mkdir(sourceRoot, { recursive: true });
  await mkdir(buildRoot, { recursive: true });
  await mkdir(outputRoot, { recursive: true });
  await writeFile(join(sourceRoot, "SYNTHETIC_SOURCE.txt"), "synthetic source only\n", "utf8");
  await writeFile(join(buildRoot, "index.html"), "<!doctype html><main>Synthetic policy CLI fixture</main>\n", "utf8");
  const preparation = await preparePublisherBuild({
    sourceRoot,
    buildOutputRoot: buildRoot,
    sourceOwner: "synthetic-owner",
    sourceRepo: "synthetic-repo",
    sourceCommit: "c".repeat(40),
    appSlug: "synthetic-policy-cli-fixture",
    appId: "synthetic.policy.cli.fixture",
    projectId: "synthetic.policy.cli.fixture.project",
    displayName: "Synthetic Policy CLI Fixture",
    capabilities: [],
    dataNamespace: "synthetic.policy.cli.fixture",
    preparedAt: "2026-09-28T00:00:00.000Z",
  });
  const preparationPath = join(outputRoot, "preparation.json");
  await writeFile(preparationPath, `${JSON.stringify(preparation, null, 2)}\n`, "utf8");
  return { root, outputRoot, preparationPath };
}

function approveArgs(fx, extra = []) {
  return [
    CLI, "approve",
    "--preparation", fx.preparationPath,
    "--approve-reviewed-output",
    "--approve-source-commit", "c".repeat(40),
    "--download-url", "https://publikhq.com/artifacts/policy-cli.irisapp",
    "--package-out", join(fx.outputRoot, "app.irisapp"),
    "--descriptor-out", join(fx.outputRoot, "descriptor.json"),
    "--receipt-out", join(fx.outputRoot, "receipt.json"),
    ...extra,
  ];
}

test("approve refuses without --policy-checked and writes nothing", async () => {
  const fx = await fixture();
  await assert.rejects(
    execFileAsync(process.execPath, approveArgs(fx)),
    (error) => {
      assert.match(error.stderr, /--policy-checked/);
      assert.match(error.stderr, /APP_POLICY\.md/);
      return true;
    },
  );
  await assert.rejects(readFile(join(fx.outputRoot, "descriptor.json")), { code: "ENOENT" });
  await assert.rejects(readFile(join(fx.outputRoot, "app.irisapp")), { code: "ENOENT" });
  await assert.rejects(readFile(join(fx.outputRoot, "receipt.json")), { code: "ENOENT" });
});

test("approve refuses a stale --policy-checked version and writes nothing", async () => {
  const fx = await fixture();
  const current = await currentPolicyVersion();
  const stale = `${current}-stale-does-not-exist`;
  assert.notEqual(stale, current);
  await assert.rejects(
    execFileAsync(process.execPath, approveArgs(fx, ["--policy-checked", stale])),
    (error) => {
      assert.match(error.stderr, /does not match the current/);
      assert.match(error.stderr, new RegExp(current.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
      return true;
    },
  );
  await assert.rejects(readFile(join(fx.outputRoot, "descriptor.json")), { code: "ENOENT" });
});

test("approve accepts the current --policy-checked version on a fixture package", async () => {
  const fx = await fixture();
  const current = await currentPolicyVersion();
  const packageOut = join(fx.outputRoot, "app.irisapp");
  const descriptorOut = join(fx.outputRoot, "descriptor.json");
  const receiptOut = join(fx.outputRoot, "receipt.json");
  const { stdout } = await execFileAsync(
    process.execPath,
    approveArgs(fx, ["--policy-checked", current]),
  );
  assert.equal(JSON.parse(stdout).status, "approved-and-packaged");
  const descriptor = JSON.parse(await readFile(descriptorOut, "utf8"));
  assert.ok(descriptor.packageSha256);
  assert.ok(await readFile(packageOut));
  assert.ok(await readFile(receiptOut));
});
