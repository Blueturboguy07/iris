# Iris

The publik desktop assistant. Split out of [`Blueturboguy07/publik`](https://github.com/Blueturboguy07/publik)
on 2026-08-25, with the history of every file that came along.

publik keeps the server half — `/api/iris/guides`, `/api/iris/apps`,
`/api/iris/recipes`, `/api/assistant/chat` and the rest. Those routes are the
contract, and they are the only thing the clients here genuinely share.

## Three clients, and why

| | what it is | state |
|---|---|---|
| **`iris-macos/`** | Swift, ~47k lines. The eye, the input bar, install guides, guide autopilot, maintain mode, the on-demand edit loop. | **active** — where the work happens |
| **`iris-windows/`** | Electron + TypeScript, ~18k lines. A behavioural reimplementation of the parts of the above that have been ported. | **behind** — last commit 2026-08-19 |
| **`iris-desktop/`** | Tauri, ~3.5k lines. A guide viewer: show a guide, open a link, check a tool version. This is the original Orbit app, renamed to Iris in July 2026. | **frozen** since 2026-08-10, and superseded |

They share **no code**. Not a file, not a symlink, not a generated artifact.
`iris-windows` is a reimplementation of `iris-macos` in a different language,
and `iris-desktop` predates both. Everything `iris-desktop` can do is a strict
subset of what the other two can do.

### Why `iris-desktop` is still here

It is not needed as an app, and it should go. Three things have to move first:

1. **`.github/workflows/iris-release.yml` still ships it.** The `build-macos`
   job runs `cd iris-desktop` and uploads the result under the artifact name
   `iris-macos`; `build-windows` does the same. The Swift app builds a side
   artifact that is never attached to a release, and the Electron app is not in
   that workflow at all. Repoint those two jobs before deleting anything.

2. **It holds the widest copy of the guide host allowlist.**
   `fn allowed_external_host` in `src-tauri/src/main.rs` lists 29 hosts;
   publik's `lib/iris-allowed-hosts.ts`, `ExternalLinkPolicy.swift` and
   `external-links.ts` list 22. The seven extra — `fal.ai`, `nasm.us`,
   `chromewebstore.google.com`, `docs.google.com`, `blueturboguy07.github.io`
   and two `www.` forms — were added on 2026-08-10 for the Halation, Nutcracker
   and Dripwriter Origin guides and never propagated. publik's guide test
   validated published links against **this** list, so four live guide steps
   pass CI and cannot be opened by any shipping client. publik's TypeScript
   constant is canonical now; that divergence is a real bug, not a merge
   artifact.

3. **`iris-windows/src/renderer/guide/` is a copy of `iris-desktop/ui/`.**
   `styles.css` is byte-identical; `app.js` differs by 35 lines. Un-copy it or
   accept that deleting `iris-desktop` orphans the original.

Also worth knowing: `iris-desktop` and `iris-macos` both declare the bundle
identifier `com.publikhq.iris`, both build an `Iris.app`, and both register the
`iris://` scheme. They cannot be installed on the same Mac.

## Building

macOS, the Swift app — this is the one to use locally. It signs with a real
Developer ID rather than ad-hoc, which is the difference between granting
Accessibility once and granting it after every single build:

```bash
scripts/deploy-iris-local.sh
```

Never run `xcodebuild` against the Swift app from a terminal without that
script's signing step; see `iris-macos/AGENTS.md`.

Windows, the Electron app:

```bash
cd iris-windows && pnpm install && pnpm dev
```

Release builds go through `.github/workflows/iris-release.yml` (macOS + Tauri
today) and `iris-windows.yml` (Electron).

## The one thing to watch

Nothing tells you when the clients diverge. Across the entire history of the
original repository, **no commit ever touched both `iris-macos` and
`iris-windows`** — 123 commits to one, 54 to the other, intersection zero.
Parity holds exactly where macOS stopped moving and nowhere else: crash and
hang detection match constant for constant, while the Tier-C edit loop caps at
500 steps on macOS and 12 on Windows, and the on-demand edit coordinator,
feature engine and watch loop have no Windows counterpart at all.

`tests/` at this root exists for cross-client checks. There is one so far.
