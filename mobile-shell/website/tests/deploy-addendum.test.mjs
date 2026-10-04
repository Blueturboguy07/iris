import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { buildSite } from "../build-site.mjs";
import { DEPLOY_MD, RC03_MARKER, updatedDeployMD } from "../deploy-addendum.mjs";

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

test("DEPLOY.md's RC-03 section lists every website file with its real sha256, and stays after seed-catalog-v2.mjs's own section", async () => {
  const onDisk = await readFile(DEPLOY_MD, "utf8");
  const markerIndex = onDisk.indexOf(RC03_MARKER);
  assert.ok(markerIndex > 0, "the RC-03 marker is present and not at the very start of the file");

  const { files } = await buildSite();
  const expected = updatedDeployMD(onDisk, files);
  assert.equal(onDisk, expected, "run node mobile-shell/website/build-site.mjs to refresh DEPLOY.md's website section");

  for (const [relativePath, bytes] of files) {
    if (relativePath === "404.html") continue;
    const etag = `"sha256:${sha256(bytes)}"`;
    assert.ok(onDisk.includes(etag), `DEPLOY.md lists ${relativePath} with its ETag`);
  }
  assert.doesNotMatch(onDisk.slice(markerIndex), /\u2014/, "no em dashes in the appended section");
});

test("updatedDeployMD is idempotent: applying it twice yields the same text", async () => {
  const onDisk = await readFile(DEPLOY_MD, "utf8");
  const { files } = await buildSite();
  const once = updatedDeployMD(onDisk, files);
  const twice = updatedDeployMD(once, files);
  assert.equal(once, twice);
});
