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
      // Port-agnostic: Vite bumps to the next free port when the default is
      // taken, so wait for any localhost line rather than a specific port. The
      // actual URL is captured by detectServedUrl for the open step.
      readyWhen: "localhost",
    },
    { id: "open", title: "Open OpenASCII", kind: "open", href: "http://localhost:5173" },
  ],
};

// publikclip — a Tauri desktop app (a Rust shell around a Python pipeline), the
// Windows OpusClip clone. This is a source-build recipe, not a signed download:
// `Blueturboguy07/publikclip` publishes NO release assets (verified via the
// GitHub API — its releases list is empty; the catalog entry says as much: "No
// release binary yet: the guided source build is the route in"), so there is
// nothing to fetch-and-run. The steps mirror the shipped Windows guide
// (lib/guides/publikclip.ts's `publikclipWindowsSteps`) and the repo's own
// green windows-latest CI (.github/workflows/windows.yml), off the exact commit
// both are pinned to. Building a Tauri app needs Rust (the shell) and the MSVC
// C++ toolchain; uv manages the Python side the build stages into the bundle.
//
// It finishes as a real installed exe — `%LOCALAPPDATA%\publikclip\publikclip-app.exe`
// (the NSIS installer's per-user target; the exe name is `app/package.json`'s
// `"name": "publikclip-app"`). That exe is what `services/maintain/app-inventory.ts`'s
// `WINDOWS_CATALOG_APPS` recognizes, so a crash of it is attributed to
// publikclip and maintain mode can raise an ask. Because the recipe clones a
// repo and outputs a desktop app, it records a `guide_source_clone` provenance
// on finish — the install maintain mode is permitted to patch.
const PUBLIKCLIP: InstallRecipe = {
  slug: "publikclip",
  appName: "publikclip",
  output: {
    type: "desktop_app",
    // The per-user NSIS install location, verified against the repo's windows.yml
    // (installs under %LOCALAPPDATA%\publikclip). `%LOCALAPPDATA%` is left as an
    // environment token for a launcher to expand (see
    // `app-inventory.ts`'s `expandWindowsEnvironmentTokens`).
    launch: { via: "path", path: "%LOCALAPPDATA%\\publikclip\\publikclip-app.exe" },
  },
  canonicalRepo: "Blueturboguy07/publikclip",
  pinnedCommit: "a53a359b985b1d2d666266062936cc186f02340b",
  steps: [
    { id: "check-git", title: "Check Git", kind: "command", command: "git --version", check: { type: "tool_version", tool: "git" } },
    { id: "check-node", title: "Check Node", kind: "command", command: "node --version", check: { type: "tool_version", tool: "node" } },
    {
      id: "install-rust",
      title: "Install Rust",
      // Only the reader can run the rustup installer; Iris opens the page and
      // waits. Auto-advances once `cargo` answers a version.
      kind: "manual",
      href: "https://rustup.rs",
      instruction: "Download and run rustup-init.exe, take the default install, then reopen PowerShell.",
      check: { type: "tool_version", tool: "cargo" },
    },
    {
      id: "install-cpp-tools",
      title: "Install the C++ build tools",
      kind: "manual",
      href: "https://visualstudio.microsoft.com/visual-cpp-build-tools/",
      instruction: "In the installer, tick 'Desktop development with C++', then install.",
    },
    {
      id: "install-uv",
      title: "Install uv",
      kind: "command",
      // winget rather than the irm|iex one-liner astral documents: piping a
      // download into the shell is refused outright by the risk gate, and
      // winget ships with Windows 10/11.
      command: "winget install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements",
      posixCommand: "curl -LsSf https://astral.sh/uv/install.sh -o /tmp/uv-install.sh && sh /tmp/uv-install.sh",
      check: { type: "tool_version", tool: "uv" },
    },
    {
      id: "clone",
      title: "Copy publikclip to this computer",
      kind: "command",
      command: "cd ~; git clone https://github.com/Blueturboguy07/publikclip.git",
      // Idempotent on the Mac so the demo can be re-run without a clone error.
      posixCommand:
        "mkdir -p ~/iris-apps; cd ~/iris-apps; [ -d publikclip ] || git clone https://github.com/Blueturboguy07/publikclip.git",
    },
    { id: "enter-folder", title: "Open the publikclip folder", kind: "command", command: "cd publikclip" },
    {
      id: "pin-source",
      title: "Use the reviewed version",
      kind: "command",
      command: "git checkout a53a359b985b1d2d666266062936cc186f02340b",
    },
    { id: "enter-app", title: "Open the app folder", kind: "command", command: "cd app" },
    {
      id: "dependencies",
      title: "Install the interface packages",
      kind: "command",
      command: "npm.cmd install",
      posixCommand: "npm install",
    },
    {
      id: "package",
      title: "Build the installer",
      kind: "command",
      // PATH insurance for a same-session rustup/winget install — both only
      // amend the PATH of NEW shells, and the build needs cargo and uv in THIS
      // one. No-op when they are already visible. The first build compiles the
      // Rust shell, so it takes several minutes.
      command:
        '$env:Path = "$env:USERPROFILE\\.cargo\\bin;$env:LOCALAPPDATA\\Microsoft\\WinGet\\Links;$env:Path"; node_modules\\.bin\\tauri.cmd build --bundles nsis',
      // The Mac produces a .app bundle instead of an NSIS installer — enough to
      // exercise the flow on the dev machine, though the installed exe below is
      // Windows-only.
      posixCommand: 'export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"; npx tauri build --bundles app',
    },
    {
      id: "install-app",
      title: "Run the installer",
      kind: "command",
      // Silent install (/S), like the repo's CI — no reader clicks needed for
      // the autopilot. Leaves publikclip-app.exe under %LOCALAPPDATA%\publikclip.
      command:
        '$setup = Get-ChildItem src-tauri\\target\\release\\bundle\\nsis -Filter *-setup.exe | Select-Object -First 1; Start-Process -FilePath $setup.FullName -ArgumentList "/S" -Wait',
    },
  ],
};

const BUILTIN_RECIPES: readonly InstallRecipe[] = [OPENASCII, PUBLIKCLIP];

/// Every built-in recipe.
export function builtinRecipes(): readonly InstallRecipe[] {
  return BUILTIN_RECIPES;
}

/// The recipe for an app slug, if Iris knows how to install it on Windows.
export function recipeForSlug(slug: string): InstallRecipe | undefined {
  return BUILTIN_RECIPES.find((recipe) => recipe.slug === slug);
}
