// RC-03 (round5/rc03-website). Regression test for a real blind test:
// following HOW_TO_OPEN.txt exactly and loading a mistyped app URL showed
// python's own bare "Error response / 404 / File not found" page, not the
// site's friendly not-found page, even though the site had one built. The
// fix is serve-local.py (used in place of a bare "python3 -m
// http.server"); this test runs that exact script as a real subprocess,
// the way a person following HOW_TO_OPEN.txt would, and checks what a
// browser actually receives, not just what the generator wrote to disk.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { buildSite, writeSite } from "../build-site.mjs";
import { SITE_OUT } from "../build-site.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const WEBSITE_ROOT = path.resolve(HERE, "..");
const SERVE_SCRIPT = path.join(WEBSITE_ROOT, "serve-local.py");
const BASE = "http://127.0.0.1:8765";

// Generous budget (up to 30s): this spawns a real OS process and polls it
// over a real socket, and the test suite around it is heavy (large fixture
// builds, several subprocess-based checks), so CPU contention alone can
// push a cold python3 start past a short timeout on a loaded machine.
function waitForServer(url, attemptsLeft = 150) {
  return new Promise((resolve, reject) => {
    const tryOnce = (left) => {
      fetch(url).then(() => resolve()).catch((error) => {
        if (left <= 0) {
          reject(error);
          return;
        }
        setTimeout(() => tryOnce(left - 1), 200);
      });
    };
    tryOnce(attemptsLeft);
  });
}

test("serve-local.py (the exact command in HOW_TO_OPEN.txt) answers a mistyped app URL with the site's own not-found page", async () => {
  // Make sure what is on disk is the current generator's output, regardless
  // of what order the test files in this directory happen to run in.
  const { files } = await buildSite();
  await writeSite(SITE_OUT, files);

  const child = spawn("python3", [SERVE_SCRIPT], { cwd: WEBSITE_ROOT, stdio: ["ignore", "pipe", "pipe"] });
  let earlyExit = null;
  let stderrText = "";
  child.stderr.on("data", (chunk) => { stderrText += chunk.toString("utf8"); });
  child.on("exit", (code) => {
    if (code !== null && code !== 0) earlyExit = code;
  });

  try {
    await waitForServer(`${BASE}/iris/`);
    assert.equal(earlyExit, null, `the server process exited instead of starting: ${stderrText}`);

    const home = await fetch(`${BASE}/iris/`);
    assert.equal(home.status, 200);
    assert.match(await home.text(), /Iris Apps/);

    // Exactly the blind test's own steps: a plausible but misspelled app
    // slug, no trailing slash (so this is a genuinely missing file, not a
    // directory-index redirect).
    const missing = await fetch(`${BASE}/iris/apps/kneekap`);
    assert.equal(missing.status, 404, "a missing page must still answer 404, not silently 200");
    assert.equal(missing.headers.get("content-type"), "text/html; charset=utf-8");
    const body = await missing.text();
    assert.doesNotMatch(body, /Error code: 404/, "must not be Python's bare default error page");
    assert.doesNotMatch(body, /Message: File not found/);
    assert.match(body, /isn't here/i);
    assert.match(body, /Iris Apps home page/);
  } finally {
    child.kill();
  }
});

// Mutation check for the test above: prove the oracle actually
// distinguishes the fix from the bug, not just from a syntax error. This
// runs a bare "python3 -m http.server" (the previous, unfixed approach,
// exactly as the blind test ran it) against the same already-built site,
// on a different port, and confirms it reproduces the original bug. It
// never edits serve-local.py itself; the "mutant" here is the deliberately
// unfixed command, not a modified copy of a file.
test("mutation check: a bare python3 -m http.server on the same site reproduces the original bug", async () => {
  const MUTANT_BASE = "http://127.0.0.1:8766";
  const child = spawn("python3", ["-m", "http.server", "8766", "--bind", "127.0.0.1"], {
    cwd: SITE_OUT,
    stdio: ["ignore", "pipe", "pipe"],
  });
  try {
    await waitForServer(`${MUTANT_BASE}/iris/`);
    const missing = await fetch(`${MUTANT_BASE}/iris/apps/kneekap`);
    assert.equal(missing.status, 404);
    const body = await missing.text();
    // The bare bug: Python's own generic error page, not this site's.
    assert.match(body, /Error code: 404/, "the unfixed command must still show the bug, or this check proves nothing");
    assert.doesNotMatch(body, /Iris Apps home page/);
  } finally {
    child.kill();
  }
});
