# Headed GUI end-to-end suite (`tests/gui-e2e/`)

The "real Windows, in depth" test. Everything under `tests/*.test.ts` is the
pure **vitest** unit suite — no network, no display, no Windows-only API — so it
runs identically on the dev Mac and on CI. This directory is the opposite: it
launches the **real packaged app** on the `windows-latest` CI runner (a genuine
Windows machine with a desktop session), drives it through the **Chrome DevTools
Protocol** against the real preload bridge, exercises the genuinely
Windows-only code paths **for real**, and captures screenshots.

It is **not** part of `npm test`. It needs a launched app and a real desktop, so
it can only run in CI (`.github/workflows/iris-windows-gui-e2e.yml`). Off Windows
it prints a skip and exits 0.

```sh
# CI only — needs a packaged iris.exe + a Windows desktop session.
npm run package
npm run gui-e2e        # node tests/gui-e2e/run.mjs
```

## What it drives (and which paths are genuinely Windows-native)

| Scenario | Flows + edge cases | Real Windows-native path exercised |
|---|---|---|
| **A · Core UI** | signed-out onboarding (`#byo-key`, sign-in buttons, "no publik account" copy); Anthropic+OpenAI key set/clear matrix incl. empty-string-clears and key independence; Settings window (OpenAI field renders); signed-out `sendQuery` prompts for a key instead of making a paid call; guide window opens; overlay present; `iris://` deep-link **accept + unknown-param reject** | safeStorage/**DPAPI** round-trip (`secretStorageAvailable === true`, encrypt/decrypt); real `iris://` delivery via the **single-instance lock** (second launch → `second-instance` → parser) |
| **B1–B3 · Real WER crash** | a genuine `Report.wer` for `publikclip-app.exe` → the live `CrashArtifactWatcher` detects it → a publikclip ask; then answer `somethingIsBroken` (fix ladder + 24h re-crash suppression), `thatWasMe` (signature suppression), `neverAskAboutThisApp` (mute → unmute) | **Windows Error Reporting crash detection**: real `fs.watch` on the WER `ReportArchive`, real `Report.wer` parse, real exe→slug inventory match, real coordinator ask-gate |
| **B4 · Demo crash** | `IRIS_MAINTAIN_DEMO_CRASH=publikclip` raises a synthetic ask ~3s in | the same coordinator ladder, no real crash needed |
| **C · PowerShell/registry seams** | `checkProcessResponsiveViaPowerShell` (live pid → true, dead pid → undefined); foreground read; installed-path resolver; frontmost-catalog read; publikclip source-build recipe shape (static) | real `Get-Process … Responding`, real `GetForegroundWindow` **P/Invoke** via `Add-Type`, real `existsSync` install check |
| **D · Autopilot** | `IRIS_AUTOPILOT_DEMO=openascii` runs a real clone → `pnpm install` → dev server to **finished**; asserts clone dir + `.git` + `node_modules` + `local_web` output | real `git clone`, real `corepack pnpm`, real long-running dev server on the runner |

`ProgramData` override: the crash watcher derives its watch directory from
`%ProgramData%` (see `crash-watcher.ts`'s `defaultReportArchiveDirectoryPath`).
The suite points the launched app's `ProgramData` at a scratch root — a
production-identical mechanism, since that path is *always* env-derived — so it
can drop a real `Report.wer` into the exact directory the live watcher is
`fs.watch`ing, without needing write access to the machine-wide `C:\ProgramData`
tree. The watcher code that runs is 100% the shipped code; only the root moves.

## The one test-only main-process hook

`main/index.ts`'s `handleGuideCommand` answers `e2e_open_settings` **only when
`IRIS_E2E=1`** — it opens the Settings window (a native tray click is not
reachable from CDP). Outside the e2e suite the command does not exist and falls
through to the same "unknown Iris command" error as any other unknown name, so
it can never affect shipped behaviour. The suite launches with `IRIS_E2E=1`.

## Files

- `cdp.mjs` — dependency-free CDP client (Node `fetch` + `WebSocket`): attach to
  a renderer, `eval` through the preload bridge, poll, `Page.captureScreenshot`.
- `app.mjs` — find/launch/kill the packaged app; write a real `Report.wer`;
  deliver an `iris://` deep link via a second instance.
- `report.mjs` — the results recorder (JSON + text log; drives the exit code).
- `run.mjs` — the orchestrator (the scenarios above).

Screenshots + `results.json` / `results.txt` / `run.log` land in
`out/gui-e2e/` (git-ignored) and are uploaded as a CI artifact.
