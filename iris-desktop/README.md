# Iris desktop companion

Iris is Publik’s guide-only desktop companion. It keeps a reviewed source-install
guide above the user’s other apps, copies exact commands, performs narrow
read-only checks, and remembers local step progress. The software being installed
runs independently from Iris.

## Current prototype

- macOS 12+ and Windows shell code
- `iris://guide/<slug>?version=<n>&branch=<computer>:<phone>&step=<n>` handoff
  from Publik, which resumes at the reader's place rather than restarting them
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

Build a macOS app. With no certificate this is ad-hoc signed and only usable
locally; with `APPLE_SIGNING_IDENTITY` set it is a real Developer ID build:

```bash
pnpm iris:build:mac
pnpm iris:verify:mac
```

`iris:verify:mac` is the one that matters. It mounts the dmg, marks the copy
quarantined the way a browser download would, and asks Gatekeeper the same
question it asks at double-click time — a bundle can be perfectly signed and
still be refused the moment it arrives with a download flag on it.

On Windows, build the NSIS installer and check it the same way:

```powershell
pnpm iris:build:windows
pwsh scripts/verify-iris-windows.ps1
```

The Windows path is exercised on a `windows-latest` runner by
`.github/workflows/iris-release.yml`, which installs what it built and launches
it. See `docs/code-signing.md` for what each build path needs.

## Security boundary

The Tauri shell has no shell plugin or arbitrary executable/argument command.
Guide links are parsed as one lowercase slug, one positive version, and an
optional resume point whose branch and step are both validated here and again
against the guide once it is fetched. Unrecognised parameters are rejected
rather than ignored. Accepting a resume point is safe only because Iris never
executes a step — the worst a crafted link can do is display one out of order.
The
desktop client accepts guide APIs only from Publik’s HTTPS domains or localhost
for development. External navigation is restricted to reviewed HTTPS hosts and
local loopback URLs.

macOS builds are signed with a Developer ID under the hardened runtime and
notarize in CI when the Apple secrets are present. Windows is still unsigned and
needs a purchased certificate — `docs/code-signing.md` has the options and the
remaining steps. Local source builds need neither.
