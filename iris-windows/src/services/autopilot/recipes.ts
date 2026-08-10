//
// The built-in install recipes. A new app is a new entry here — reviewed,
// version-pinned data, which is the provenance the risk gate leans on. Recipes
// are TypeScript objects rather than fetched JSON so the compiler checks their
// shape and the risk-gate suite can assert over them.
//

import type { InstallRecipe } from "./recipe";

// OpenASCII — a Node/pnpm local-web app. The Windows steps mirror the shipped
// guide (lib/guides/openascii.ts): check tools, clone the reviewed commit,
// install, start the dev server (long-running), open it. The tool checks are
// split into one command each so a missing Node cannot be masked by a passing
// Git in a combined line.
const OPENASCII: InstallRecipe = {
  slug: "openascii",
  appName: "OpenASCII",
  output: { type: "local_web", url: "http://localhost:5173" },
  steps: [
    { id: "check-git", title: "Check Git", kind: "command", command: "git --version", check: { type: "tool_version", tool: "git" } },
    { id: "check-node", title: "Check Node", kind: "command", command: "node --version", check: { type: "tool_version", tool: "node" } },
    {
      id: "clone",
      title: "Copy OpenASCII to this computer",
      kind: "command",
      command: "cd ~; git clone https://github.com/Blueturboguy07/OpenASCII.git",
      // Idempotent on the Mac so the demo can be re-run without a clone error.
      posixCommand:
        "mkdir -p ~/iris-apps; cd ~/iris-apps; [ -d OpenASCII ] || git clone https://github.com/Blueturboguy07/OpenASCII.git",
    },
    { id: "enter-folder", title: "Open the OpenASCII folder", kind: "command", command: "cd OpenASCII" },
    {
      id: "pin-source",
      title: "Use the reviewed version",
      kind: "command",
      command: "git checkout 8fc32ce16a6536c1a37a36e483fdc39dfd50d5cd",
    },
    {
      id: "dependencies",
      title: "Install dependencies",
      kind: "command",
      command: "corepack.cmd pnpm install",
      posixCommand: "corepack pnpm install",
    },
    {
      id: "run",
      title: "Start OpenASCII",
      kind: "command",
      command: "corepack.cmd pnpm dev",
      posixCommand: "corepack pnpm dev",
      longRunning: true,
      readyWhen: "localhost:5173",
    },
    { id: "open", title: "Open OpenASCII", kind: "open", href: "http://localhost:5173" },
  ],
};

const BUILTIN_RECIPES: readonly InstallRecipe[] = [OPENASCII];

/// Every built-in recipe.
export function builtinRecipes(): readonly InstallRecipe[] {
  return BUILTIN_RECIPES;
}

/// The recipe for an app slug, if Iris knows how to install it on Windows.
export function recipeForSlug(slug: string): InstallRecipe | undefined {
  return BUILTIN_RECIPES.find((recipe) => recipe.slug === slug);
}
