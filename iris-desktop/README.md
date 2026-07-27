# Iris desktop companion

Iris is Publik’s guide-only desktop companion. It keeps a reviewed source-install
guide above the user’s other apps, copies exact commands, performs narrow
read-only checks, and remembers local step progress. The software being installed
runs independently from Iris.

## Current prototype

- macOS 12+ and Windows shell code
- `iris://guide/<slug>?version=<number>` handoff from Publik
- one active macOS/Windows guide branch at a time
- tray Show, Hide, and Quit controls
- always-on-top animated guide window
- exact-version public guide fetch from `https://publikhq.com`
- allowlisted `--version` checks only
- read-only Git HEAD and foreground-app identity commands
- local progress; no account required

Iris does **not** run guide commands, click, type, capture pixels, retain
screenshots, or retain foreground-app history. The current awareness layer sees
only the foreground app identity in memory. Screen understanding and hover
guidance are later permission-gated phases.

## Run and build

From the repository root:

```bash
pnpm install
pnpm iris:check
pnpm iris:dev
```

Build a locally usable, ad-hoc-signed Apple Silicon app:

```bash
pnpm iris:build:mac
open iris-desktop/src-tauri/target/release/bundle/macos/Iris.app
```

On Windows, build the NSIS installer with:

```powershell
pnpm iris:build:windows
```

The Windows implementation is compile-gated in this repository but must still be
built and exercised on a Windows machine before distribution.

## Security boundary

The Tauri shell has no shell plugin or arbitrary executable/argument command.
Guide links are parsed as one lowercase slug plus one positive version. The
desktop client accepts guide APIs only from Publik’s HTTPS domains or localhost
for development. External navigation is restricted to reviewed HTTPS hosts and
local loopback URLs.

Production distribution still needs Apple Developer signing/notarization and a
Windows signing certificate. Local source builds do not need those credentials.
