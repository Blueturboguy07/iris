# CLAUDE.md

Notes for Claude Code (and future contributors) working in `iris-windows/`.
Read `README.md` first — it covers what is ported, what is absent, and what has
not been verified. This file is the architecture and the traps.

## The one rule

**The user's own Anthropic key must never reach a publik host.** Losing that is
a ship-blocker, not a bug. It is enforced structurally, by assertion, and by test
in `src/services/assistant-transport.ts` — read the header comment there before
touching anything in that file.

Do not add a code path that accepts both a credential and a destination. The
whole design is that no such function exists.

## Testing is CI, not local

The dev machine is a Mac that cannot run Windows. `.github/workflows/iris-windows.yml`
on `windows-latest` is the only place this app is built, packaged, or started —
including a launch smoke test that requires the packaged `iris.exe` to survive
ten seconds. Treat a red workflow as a broken build, because there is no other
signal.

The unit suite must therefore stay free of network, display, and Windows-only
APIs, so it runs identically on both. `jsdom` counts as neither a display nor a
second runner — it is a library the vitest suite imports so the guide panel's
own rendering can be measured instead of asserted about. Anything needing real
I/O takes it as an injected function (`fetchImplementation`, and so on). If a
change cannot be tested that way, say so in the PR rather than adding a test
that only passes on one OS.

## Architecture

```
src/main/       Electron main process — Node APIs, Electron APIs, side effects
src/services/   Pure logic — no Electron import, injectable I/O, fully tested
src/preload/    The complete list of what a renderer may do
src/renderer/   chat · guide (transplanted) · overlay · settings
tests/          vitest; 8 files
```

The `main` / `services` split is load-bearing: `services/` is what the suite can
reach. When adding behaviour, put the decision in `services/` and leave `main/`
carrying pixels and window handles around. `screenshot.ts` is the model for this
— it talks to `desktopCapturer` and delegates every coordinate decision to
`services/coordinates.ts`.

### Query flow

1. `renderer/chat` → `chat:query` IPC.
2. `main/companion.ts` captures all screens, picks a transport for the *current*
   credentials (the user can sign in or paste a key between messages), and calls
   `services/claude.ts`.
3. The model replies with text containing `[POINT:x,y:label:screenN]` tags.
4. Each tag gets a second-pass refinement crop, then IMAGE → DISPLAY conversion,
   then goes to the overlay for its own display.
5. The tag-stripped text is returned to the chat window.

### The three coordinate spaces

NATIVE (device pixels) → IMAGE (the downsampled JPEG the model saw, ≤ 1568 long
edge) → DISPLAY (device-independent pixels, what the overlay is sized in).

Model coordinates are always IMAGE space. Refinement answers are in the crop's
own native-pixel space. The overlay needs DISPLAY space.

**All of this lives in `services/coordinates.ts` and nowhere else.** Do not
reintroduce inline arithmetic in `companion.ts` — that is where it was, and
extracting it is what made it testable. The failure mode is applying one space's
factor to another space's number, which on a 2× display is off by exactly 2× and
looks like a mediocre model rather than a unit error.

Other footguns, inherited from upstream and still true:

- Never send a pass-1 image with a long edge over 1568. Anthropic downsamples it
  server-side and the coordinates come back in a space you cannot predict.
- Never scale coordinates before refinement — refinement operates on raw
  IMAGE-space coordinates.
- `_source` on `ScreenshotResult` is a `NativeImage`. **Never send it over IPC.**

### The guide panel is transplanted, not written

`src/renderer/guide/app.js` is a copy of `iris-desktop/ui/app.js`. Keep it that
way. It reaches the shell through `window.__TAURI__`, and
`src/renderer/guide/iris-bridge.js` synthesises that object from the Electron
preload bridge — the bridge is the entire Windows-specific delta, which is what
keeps the two panels diffable.

Two behavioural changes have been made to `app.js`, and both must survive a
port from `iris-desktop`:

1. `blockedExternalHost` plus the disabled branch at the top of
   `updatePrimaryAction`, so a step pointing at a non-allowlisted host renders a
   **disabled control naming the host** instead of a button that does nothing.
2. `commandToRun`, used by `renderStep` and `copyCurrentCommand`, so a step that
   declares a `workingDirectory` shows and copies `cd <folder>` above its
   command. This panel drives no shell — the reader pastes into a window Iris
   cannot see — so a folder that is not in the text does not exist, and a reader
   who resumes at step 8 the next day pastes a path relative to a `cd` that
   happened yesterday. Covered by `tests/guide-renderer.test.ts`, which boots
   this exact file in jsdom.

Change 2 belongs in `iris-desktop/ui/app.js` too (identical five lines); until it
lands there, the Tauri panel still drops the folder.

The main process answers the command names `app.js` already invokes
(`take_pending_guide`, `check_tool_version`, `open_external`, `quit_iris`,
`hide_iris`, `resize_iris`, `glide_iris`, `foreground_app_identity`) in
`handleGuideCommand`. `foreground_app_identity` returns null on Windows — there
is no cross-process foreground-app API without a native module, and `app.js`
already renders that case honestly.

### Secrets

`src/main/secrets.ts` is the only code that touches a secret at rest. The set
today: the BYO Anthropic key (companion chat + maintain mode's Tier C), the
Supabase refresh token, maintain mode's GitHub device-flow token pair
(fork-backup), and the BYO OpenAI key (maintain mode's Tier C fixer only — see
"Do NOT" below). All go through `safeStorage` (DPAPI). The access token is
memory-only, per protocol §4.

`settings.json` must stay free of secrets — it is plain text and users paste it
into bug reports. If `safeStorage.isEncryptionAvailable()` is false, refuse to
store the key and say so. Never fall back to plaintext.

### Deep links

`services/deep-link-parser.ts` is a port of `parse_guide_deep_link` in
`iris-desktop/src-tauri/src/main.rs` (lines 188–285), which remains the
behavioural spec. The governing rule is that an **unknown query parameter is
rejected, not ignored**. If you add a parameter, add it to the parser, the
allowlist of names, and the test table — in that order.

### Autopilot (guided-install)

`src/services/autopilot/` runs an install recipe end to end — the Windows port of
the macOS Swift autopilot. It is pure and unit-tested (`tests/autopilot-*.test.ts`):
`recipe.ts` (the schema), `risk.ts` (the command gate), `runner.ts` (the no-click
state machine driven against a `ShellSession`), `shell.ts` (the interface +
`MockShell`), `recipes.ts` (the built-in recipes), `fix-ladder.ts` (the
self-repair ladder). The real shell —
`src/main/powershell-session.ts` — spawns one PowerShell per command and threads
the working directory forward, so it lives in `main/`; its pure parsing helpers
are unit-tested and the whole thing is exercised end to end by
`tests/autopilot.e2e.test.ts` on the windows-latest runner (guarded to `win32`).

**Recipes are now derived from guides, not just the built-in table.** The primary
resolver is `guide-recipe-resolver.ts`: it fetches the app's publik guide
(`guide-service.fetchGuide`), decodes it strictly and leniently
(`guide-model.ts`, mirroring `IrisGuideModels.swift` — unknown kind → terminal,
unknown expectation dropped, TOTAL so a malformed payload never throws), and
derives an `InstallRecipe` from its Windows branch (`guide-recipe.ts`). The
`recipes.ts` table is now the OFFLINE fallback, used only when the fetch fails.
`AutopilotController` takes an injected `resolveRecipe` (now awaitable; `canInstall`
is async) and `main/index.ts` wires the guide-backed resolver in; the guide is
cached by `slug:version` for the session. The derivation maps a `terminal`/`check`
step with a command → `command` (long-running via the ported
`GuideAutopilotCommandShape.holdsTheShellOpen` heuristics), a command-less step →
`noop`, `open` → `open`, `permission`/`web`/`paste` → reader-handled kinds, and
`verify` → a new `verify` kind that carries the guide's watch expectations for the
watch-loop port (the runner self-completes `noop`/`verify`, mirroring macOS's
nil-command → succeeded). A branch the guide marks `unsupported` (Windows + iPhone)
resolves to a typed unsupported result, never a recipe. Setup steps become
`recipe.prerequisites` for the setup-detour port.

**Trust boundary — this relaxes the allowlist invariant.** `tool-versions.ts` says
no command is ever built from guide text. The autopilot deliberately runs commands
that *do* come from a recipe — a built-in one, or one derived from a fetched guide
— so `risk.ts` is the compensating control and the relaxation is bounded three
ways: provenance (the HTTPS-fetched, version-pinned guide JSON that publik serves —
the same provenance the macOS side runs on — decoded, never executed as text; the
built-in `recipes.ts` entries are the same shape reviewed in-repo), a three-tier
gate (refuse / one tap / run) that mirrors the macOS
`GuideAutopilotRiskAssessment.swift`, and an un-forgeable `ApprovedCommand` the
shell is the only thing that will run. If you add a recipe, change the derivation,
or loosen the gate, keep those three intact and update the tests.

**The failure-fix ladder (`fix-ladder.ts`, self-repair).** When a `command`
step exits non-zero and a `FixLadder` is wired, the runner asks the reader's OWN
model (the maintain BYO Anthropic/OpenAI seam, never a publik host) for ONE
structured fix, runs it under `risk.ts` at `model_proposed_fix` provenance,
retries the original, and only surfaces to the reader once it runs out of rungs,
budget, or ideas. Three guardrails, ported from the macOS
`GuideAutopilot*FixProposer` + `climbTheFixLadder`: (1) a **host allowlist** —
`validatedFix` refuses a proposed command reaching any host the recipe's own
commands/links do not already name (the structural answer to a hallucinated
hostname); (2) the **stricter gate** — a model fix is assessed at
`model_proposed_fix`, where opacity (`$()`, backticks) trips a tap even for a
command that would otherwise run; (3) **caps + a progress guard** — 2 rungs/step,
6 fixes/guide, 8 model calls/guide, and 5 consecutive spending-but-never-running
steps. No key configured ⇒ the ladder surfaces immediately with a clear reason,
it never hangs. The model transport is the Codex plain-text contract (ONE fenced
json block → the ONE validator both routes share), because `respond()` has no
tool-use wire format to force. Exhaustion surfaces the failing command with the
"Try again / Continue past it" choice (`autopilot_retry` /
`autopilot_continue_past` IPC → `AutopilotRunner.retryCurrentStep` /
`continuePastCurrentStep`). The ladder is INJECTED (default undefined = surface
at once, the old behaviour), so it is a small hook in `runner.ts` and the whole
loop is unit-tested in `tests/autopilot-fix-ladder.test.ts` with a fake provider
and a `MockShell`.

**Autonomy grant (mirrors the macOS side).** For a vetted, pinned recipe the
per-command taps are friction, so the reader grants "Let Iris take control of
your PC?" ONCE (persisted `autopilotAutonomyGranted` in `settings.ts`, remembered
across installs, revocable from the settings window). `assess`/`approve` take an
`autonomyGranted` flag (default false, so existing callers/tests are unchanged):
when true, everything runs no-tap EXCEPT the `CATASTROPHE_RULES` floor (whole-disk
/ whole-profile destruction) that is refused even under the grant. The `download-
and-run` shapes (`irm … | iex`, `curl … | sh`) move from refused to run-under-
grant. `AutopilotController.start` asks the host's `ensureAutonomyGranted()` (an
Electron dialog in `index.ts`) before any shell starts — a decline stops the run
— then constructs the runner with `autonomyGranted: true`, so the confirm path is
not reached in production (still unit-tested at the runner level). The terminal
shows a plain-English `friendlyLabel` per command (`friendly-label.ts`) with the
raw command dimmed, and a spinner while running. Keep every risk pattern literal
present in `risk.ts` — the web guide tests grep for them.

## Style

Follow the publik house style, which is `iris-macos/CLAUDE.md`'s:

- **Optimise for clarity over concision.** Long, specific names. No
  single-character variables. `refinedPointInCropSpace`, not `p`.
- Pass arguments under the same name they had at the call site.
- Comments explain *why*, especially for the coordinate conversions, the
  key-isolation gate, and anything that looks redundant but is a safety net.
- Clear is better than clever; more lines are fine if they read better.

## Do NOT

- Do not add a function that takes both an API key and a URL.
- Do not reintroduce voice, TTS, audio, or a non-Anthropic provider **into the
  companion chat** (`services/assistant-transport.ts`, `main/companion.ts`) —
  that surface stays Anthropic-only, full stop. This does NOT govern maintain
  mode's Tier C fixer, which may run on a BYO OpenAI key (api.openai.com only,
  same key-isolation rule) alongside the Anthropic one — a founder decision,
  matching `iris-macos` maintain-mode parity. See `main/maintain/controller.ts`
  and `services/maintain/model-provider.ts`.
- Do not add a second test runner. It is vitest.
- Do not rewrite `renderer/guide/app.js` to Windows conventions.
- Do not download Electron's Windows binaries on a dev machine — cross-building
  is CI's job.

## Self-update

When a change affects the architecture, the file layout, the coordinate
pipeline, the deep-link rules, or the key-isolation property, update this file
and `README.md` in the same commit. Do not update either for a minor fix.
