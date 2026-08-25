// electron-forge walks every linked dependency when it packages, and stats
// each one's node_modules. This package legitimately has none — it is pure and
// has zero runtime dependencies — so the directory never exists and packaging
// dies with ENOENT before it starts.
//
// Creating it empty is the honest answer: "no runtime dependencies" and "an
// empty dependency directory" describe the same fact, and forge is happy with
// the second.
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
mkdirSync(join(dirname(fileURLToPath(import.meta.url)), "node_modules"), { recursive: true });
