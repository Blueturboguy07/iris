/**
 * Copies the built core into node_modules as real files, replacing the symlink
 * npm's `file:` dependency leaves there.
 *
 * electron-packager refuses to package a symlink pointing outside the app
 * directory — "file '../packages/iris-core' links out of the package" — and on
 * Windows it did something worse than refuse: packaging reported success and
 * produced an app that could not start at all. Every one of the seven GUI e2e
 * scenarios failed identically, with the CDP endpoint never coming up, because
 * the main process died on `require("@iris/core")` before it opened a window.
 *
 * So the link is replaced with the thing it points at. This is a copy of a
 * BUILD ARTIFACT, not of source: `packages/iris-core/src` remains the only
 * place the logic is written, this runs after the core is built, and it runs
 * on every package, so the copy cannot go stale.
 */
import { cpSync, existsSync, lstatSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const windowsRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const coreSource = join(windowsRoot, "..", "packages", "iris-core");
const vendored = join(windowsRoot, "node_modules", "@iris", "core");

if (!existsSync(join(coreSource, "dist", "index.js"))) {
  console.error(
    "The core is not built. Run `npm run build:core` first — vendoring an\n" +
      "unbuilt core would package an app whose main process cannot start."
  );
  process.exit(1);
}

// rmSync follows nothing and removes the link itself, which is what we want:
// deleting through the symlink would delete the real package.
if (existsSync(vendored) || lstatSync(vendored, { throwIfNoEntry: false })) {
  rmSync(vendored, { recursive: true, force: true });
}
mkdirSync(dirname(vendored), { recursive: true });
mkdirSync(vendored, { recursive: true });

for (const entry of ["package.json", "dist"]) {
  cpSync(join(coreSource, entry), join(vendored, entry), { recursive: true });
}

console.log("vendored @iris/core into node_modules as real files");
