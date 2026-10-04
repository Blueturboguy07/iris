import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { pathToFileURL } from "node:url";

// Optional module is used only by a disposable behavioral mutation runner.
const moduleURL = process.env.IRIS_PUBLISHER_TEST_MODULE
  ? pathToFileURL(process.env.IRIS_PUBLISHER_TEST_MODULE) : new URL("../index.mjs", import.meta.url);
const { preparePublisherBuild, approvePublisherBuild } = await import(moduleURL.href);

async function fixture(t, html) {
  const root = await mkdtemp(join(tmpdir(), "iris-publisher-file-runtime-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const sourceRoot = join(root, "source"), buildOutputRoot = join(root, "build");
  await mkdir(sourceRoot); await mkdir(buildOutputRoot);
  await writeFile(join(sourceRoot, "fixture.txt"), "Synthetic publisher input. No app or provider execution.\n");
  await writeFile(join(buildOutputRoot, "index.html"), html);
  await writeFile(join(buildOutputRoot, "app.js"), "globalThis.syntheticPublisherValue = 1;\n");
  return { root, buildOutputRoot, html,
    options: { sourceRoot, buildOutputRoot, sourceOwner: "synthetic", sourceRepo: "file-runtime",
      sourceCommit: "a".repeat(40), appSlug: "synthetic-file-runtime", appId: "synthetic.file.runtime",
      projectId: "synthetic.file.runtime.project", displayName: "Synthetic File Runtime",
      dataNamespace: "synthetic.file.runtime.data", capabilities: ["web.storage"] } };
}

for (const [name, tag] of [
  ["quoted module", '<script type="module" src="./app.js"></script>'],
  ["unquoted attributes", '<script TYPE=module SRC=app.js></script>'],
  ["attribute whitespace", '<script src="app.js" type=" module "></script>'],
  ["numeric character references", '<script type="mo&#100;ule" src="app.js"></script>'],
]) {
  test(`file-runtime preparation rejects ${name} before describing output as ready`, async t => {
    const fx = await fixture(t, '<!doctype html><main>Loading</main>' + tag);
    await assert.rejects(preparePublisherBuild(fx.options), /file-origin.*external module script/i);
    assert.equal(await readFile(join(fx.buildOutputRoot, "index.html"), "utf8"), fx.html,
      "preflight must not rewrite the reviewed app to disguise its module dependency");
  });
}

test("classic scripts and inert script-like text keep normal publisher approval", async t => {
  const html = `<!doctype html>
    <!-- <script type="module" src="app.js"></script> -->
    <script type="application/json">{"example":"<script type='module' src='app.js'>"}</script>
    <textarea><script type="module" src="app.js"></script></textarea>
    <script defer src="app.js"></script><main>Actual classic fixture</main>`;
  const fx = await fixture(t, html);
  const preparation = await preparePublisherBuild(fx.options);
  const result = await approvePublisherBuild({ preparation, approved: true,
    approvedSourceCommit: "a".repeat(40),
    downloadUrl: "https://publikhq.com/_synthetic_not_published/file-runtime.irisapp" });
  assert.equal(result.descriptor.revisionId, preparation.revision.revisionId);
  assert.equal(await readFile(join(fx.buildOutputRoot, "index.html"), "utf8"), html);
});

test("module-like custom data attributes do not become script type", async t => {
  const fx = await fixture(t, '<script data-type="module" src="app.js"></script>');
  const preparation = await preparePublisherBuild(fx.options);
  assert.equal(preparation.app.slug, fx.options.appSlug);
});

test("an inline module is not falsely reported as an external module", async t => {
  const fx = await fixture(t, '<script type="module">const testValue = 1;</script>');
  const preparation = await preparePublisherBuild(fx.options);
  assert.equal(preparation.app.slug, fx.options.appSlug);
});
