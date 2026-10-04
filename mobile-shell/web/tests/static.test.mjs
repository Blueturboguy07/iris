import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.resolve(here, "..");

async function text(relativePath) {
  return readFile(path.join(webRoot, relativePath), "utf8");
}

test("manifest is standalone and every declared icon is a real local file", async () => {
  const manifest = JSON.parse(await text("manifest.webmanifest"));
  assert.equal(manifest.display, "standalone");
  assert.equal(manifest.start_url, "./index.html");
  assert.equal(manifest.scope, "./");
  assert.ok(manifest.icons.length >= 3);
  for (const icon of manifest.icons) {
    assert.ok(icon.src.startsWith("./icons/"));
    const info = await stat(path.join(webRoot, icon.src));
    assert.ok(info.size > 0, `${icon.src} should not be empty`);
  }
});

test("service worker pre-caches the complete shell and waits for explicit activation", async () => {
  const sw = await text("sw.js");
  assert.match(sw, /iris-mobile-shell-v2/);
  for (const asset of [
    "./index.html",
    "./styles.css",
    "./main.mjs",
    "./runtime.mjs",
    "./storage.mjs",
    "./sandbox.mjs",
    "./manifest.webmanifest",
    "./demo/notes-demo.mjs",
    "../contracts/index.js",
  ]) {
    assert.ok(sw.includes(JSON.stringify(asset)), `service worker should cache ${asset}`);
  }
  const installBlock = sw.slice(sw.indexOf('addEventListener("install"'), sw.indexOf('addEventListener("activate"'));
  assert.doesNotMatch(installBlock, /skipWaiting/);
  assert.match(sw, /ACTIVATE_UPDATE/);
  assert.match(sw, /skipWaiting\(\)/);
  assert.match(sw, /caches\.match\(SHELL_URL\)/);
});

test("sandbox uses an embedder CSP pre-request guard for frame self-navigation", async () => {
  const sandbox = await text("sandbox.mjs");
  const html = await text("index.html");
  assert.match(html, /sandbox="allow-scripts"/);
  assert.match(html, /Content-Security-Policy[^>]+frame-src 'none'/);
  assert.doesNotMatch(html, /allow-same-origin/);
  assert.doesNotMatch(html, /allow-top-navigation/);
  assert.doesNotMatch(html, /allow-popups-to-escape-sandbox/);
  assert.match(sandbox, /connect-src 'none'/);
  assert.match(sandbox, /frame-src 'none'/);
  assert.doesNotMatch(sandbox, /navigate-to/);
  assert.match(sandbox, /embedderNavigationPolicy: "frame-src 'none'"/);
  assert.match(sandbox, /event\.source !== session\.source/);
  assert.match(sandbox, /channelToken/);
  assert.doesNotMatch(sandbox, /\beval\s*\(/);
  assert.doesNotMatch(sandbox, /new Function|Function\s*\(/);
});

test("web shell has no arbitrary remote package URL or native bridge path", async () => {
  const main = await text("main.mjs");
  const runtime = await text("runtime.mjs");
  const sandbox = await text("sandbox.mjs");
  const html = await text("index.html");
  const combined = `${main}\n${runtime}\n${sandbox}`;
  assert.doesNotMatch(combined, /fetch\s*\(\s*[`'"]https?:\/\//);
  assert.doesNotMatch(combined, /iframe\.src\s*=\s*[`'"]https?:\/\//);
  assert.doesNotMatch(combined, /nativeInvoke|__TAURI__|webkit\.messageHandlers/);
  assert.match(html, /accept="application\/json,.json,.irisapp"/);
  assert.match(main, /parsePackageJson/);
});

test("content persistence never deletes the separate user-data databases during revision changes", async () => {
  const storage = await text("storage.mjs");
  const runtime = await text("runtime.mjs");
  assert.match(storage, /iris-mobile-content-v1/);
  assert.match(runtime, /iris-mobile-userdata-v1-/);
  assert.doesNotMatch(storage, /deleteDatabase\s*\(/);
  assert.match(storage, /setActiveRevision/);
});
