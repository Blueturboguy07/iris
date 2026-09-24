# CLAUDE.md

Notes for Claude Code (and future contributors) working in `iris-windows/`.
Read `README.md` first — it covers what is ported, what is absent, and what has
not been verified. This file is the architecture and the traps.

## The one rule

**A credential only ever reaches the host that issued it.** The user's own
Anthropic key must never be seen by a publik host, and the publik API key must
never be seen by Anthropic. Losing either is a ship-blocker, not a bug. It is
enforced structurally, by assertion, and by test in
`src/services/assistant-transport.ts` — read the header comment there before
touching anything in that file.

The rule used to be the narrower "the BYO key never reaches publik", enforced by
comparing against one hardcoded host. Since publik API became the default route
there are two credentials and two permitted destinations, so the rule is the
*pairing*: `PERMITTED_HOST_FOR_CREDENTIAL` is the table, `credentialMayReachHost`
is the question, and every request declares which credential it carries so the
gate checks the pairing rather than guessing from header names.

Do not add a code path that accepts a credential and an *unvalidated*
destination. One builder legitimately takes a base URL — provisioning is allowed
to move the gateway — and it validates that URL against its own credential's
permitted hosts before writing the header. Every other builder takes no URL at
all.

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
publik API key this install was issued (`pk_live_…`, the default chat route),
the Supabase refresh token, maintain mode's GitHub device-flow token pair
(fork-backup), and the BYO OpenAI key (maintain mode's Tier C fixer only — see
"Do NOT" below). All go through `safeStorage` (DPAPI).

The publik *app token* (`pat_iris_…`, `main/publik-app-token.ts`) is NOT a
secret and deliberately does not live here: it ships inside every binary by
design, and is contained by being per-release, revocable and rate-limited. The access token is
memory-only, per protocol §4.

`settings.json` must stay free of secrets — it is plain text and users paste it
into bug reports. If `safeStorage.isEncryptionAvailable()` is false, refuse to
store the key and say so. Never fall back to plaintext.

### publik API balance and Add credit

`services/publik-balance.ts` is the Windows half of "Balance + Add credit in
Iris" (founder decision, 2026-09-22; the Mac half is `PublikAPIBalance.swift`).
The rules — the $0.25 low line, the tier prices behind the typical-message
figure, which page "Add credit" opens, reading `GET /balance` — are all there
and tested in `tests/publik-balance.test.ts`, against the same
`tests/fixtures/publik-balance/*.json` the Swift suite reads. `main/publik-setup.ts`
owns the timing (launch, a window opening, after each reply) and the per-reply
tally; `makeBalanceRequest` in `assistant-transport.ts` builds the one GET that
carries the publik key, through `validatedRequest` like chat. This client asks
for non-streaming answers, so `x-publik-charge-micros` and `x-publik-balance`
on a reply are already settled; a response without a charge (a 402) triggers a
debounced `/balance` read instead. Everything shows only while publik API is the
provider answering (`CompanionManager.answersWithPublikApi`). A 402's link
reaches the chat window through `chat:lastFailure`, because an invoke rejection
carries only a message.

### Deep links

`services/deep-link-parser.ts` is a port of `parse_guide_deep_link` in
`iris-desktop/src-tauri/src/main.rs` (lines 188–285), which remains the
behavioural spec. The governing rule is that an **unknown query parameter is
rejected, not ignored**. If you add a parameter, add it to the parser, the
allowlist of names, and the test table — in that order.

### Install hooks, shortcuts, relaunch, version

- **Squirrel hooks come first.** Electron's exe is "Squirrel-aware", so
  Squirrel.Windows makes no shortcut by itself and runs `iris.exe
  --squirrel-install|updated|uninstall|obsolete` and waits for it. The top of
  `main/index.ts` — before the single-instance lock, settings, or any window —
  answers those from `services/launch-arguments.ts` (Desktop + Start Menu
  shortcuts via `Update.exe`, removed on uninstall) and quits. Do not move
  app start-up above that block, and do not add a runtime dependency for it
  (`electron-squirrel-startup`): the app has none. `--squirrel-firstrun` starts
  normally plus a one-time "where Iris lives" notice. The real installer is
  checked by the "Installer shortcuts" step in `iris-windows.yml`.
- **A second launch with no `iris://` link opens the chat** (`showChatWindow`:
  create if closed, restore, focus). Never fall back to "any window": the
  overlays are always there and are transparent, so focusing one looks like
  nothing happened. Links keep the deep-link path.
- **Settings and first-run windows are resizable** (`services/window-geometry.ts`)
  and their pages never scroll sideways: rows wrap, `overflow-wrap: anywhere`,
  `overflow-x: hidden` as the backstop, and a thin `::-webkit-scrollbar`. Never
  set `scrollbar-width`/`scrollbar-color` on those pages — Chromium then ignores
  the `::-webkit-scrollbar` rules and Windows' wide grey default comes back.
  `tests/window-geometry.test.ts` pins this; the GUI e2e measures it on Windows.
- **Version.** `package.json`'s `version` is `app.getVersion()` and feeds the
  self-update check, so it is bumped in every `Iris X.Y.Z` commit together with
  the macOS `MARKETING_VERSION` (`npm version X.Y.Z --no-git-tag-version`).
  `tests/app-version.test.ts` fails when the two differ; `iris-release.yml`
  refuses a tag that differs from it.

### Autopilot (guided-install)

`src/services/autopilot/` runs an install recipe end to end — the Windows port of
the macOS Swift autopilot. It is pure and unit-tested (`tests/autopilot-*.test.ts`):
`recipe.ts` (the schema), `risk.ts` (the command gate), `runner.ts` (the no-click
state machine driven against a `ShellSession`), `shell.ts` (the interface +
`MockShell`), `recipes.ts` (the built-in recipes), `fix-ladder.ts` (the
self-repair ladder), `watch.ts` (the watch-expectation executor), and
`setup-detour.ts` (the prerequisite-recovery detour + missing-tool self-heal).
The real shell —
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

**Watch-expectation executor (`watch.ts`).** The Windows analog of the macOS
adaptive `WatchLoop`, scoped to what the runner needs: given a step's `watch`
block (`{ sensitive?, expect: Expectation[] }`), `WatchStepExecutor.awaitStepCompletion`
blocks — bounded — until one expectation verifies, cheapest-first (`toolVersion`
→ `foregroundApp` → `urlHost` → `axElement` → `visual`), then the step advances
with no tap. A `verify` step is pure watch; a reader step (sign_in/permission/manual)
that carries a watch surfaces "your turn" up front but is auto-advanced the moment
the watch verifies, and only handed back (with `verifierLabel`) on timeout. The
runner emits `watchVerified`/`watchTimedOut`. Because the runner is a *pumped*
machine (not a background timer like macOS), this is an awaitable the runner calls
inline; every OS call is an injected seam (`WatchSeams`) with a real default, so
the whole thing is faked in vitest. The foreground read reuses
`app-inventory.ts`'s `GetForegroundWindow` seam; `urlHost`/`axElement` are
PowerShell UI Automation one-liners (`buildActiveBrowserUrlCommand` /
`buildAxElementQueryCommand`, exercised by hand via `tests/windows-only/watch-seams.ps1`
on a real box). A `foregroundApp` expectation's guide identity (a macOS bundle id)
is mapped to a Windows exe through a reviewed table keyed off `WINDOWS_CATALOG_APPS`.
The `visual` rung (screenshot + a model verdict, budgeted ≤ 8/step and ≥ 10 s
apart, NEVER for a `sensitive` step) is fully implemented and tested but its two
seams — capture and model evaluation — default to "not wired": they need `main/`'s
screenshot pipeline and a model transport a host injects, so side-signal watching
works today and the visual rung lights up when a host supplies those.
**Working-directory-aware gate.** `assess`/`approve`/`approveAfterAReaderTap` also
take an options form (`{ provenance, autonomyGranted?, workingDirectory? }`)
alongside the original positional one. The command text alone can't show where it
runs, so the folder is judged separately: a Windows system folder (`C:\Windows`,
`C:\Program Files*`, `%SystemRoot%`), a drive root, or a `..`-escape out of the
guide's folder is refused outright — even under the grant, like the catastrophe
floor (`forbiddenWorkingDirectory` / `escapesIntoAForbiddenPlace`). The runner
passes the step's `workingDirectoryForPlatform` into the gate. A `model_proposed_fix`
is also judged for opacity BEFORE the grant short-circuit, so the grant a reader
gives a vetted install never launders an untrusted model's download-and-run or
`-EncodedCommand` command.

**The red 'Stop' escape hatch.** `ShellSession.abort()` kills the running step's
whole process tree (`taskkill /pid … /T /F` on Windows), and `AutopilotRunner.abort()`
puts the run in a terminal `aborted` state so no further step runs — an in-flight
command's outcome is discarded, not surfaced. `AutopilotController.abort()` is
unconditional and idempotent (the macOS `abortOrCloseAutopilotFromTheEscapeHatch`
dead-button fix) and folds the window away via the host's `onAborted`. Reachable
from the autopilot window's red traffic-light and the tray's "Stop the install".

**Tray "your turn".** `services/autopilot/your-turn.ts` is a pure reducer over the
event stream deciding when the tray says "your turn" (a sign-in/permission/manual
step, a confirm tap, or a surfaced failure) and when to fire the one-off Windows
toast; `main/tray.ts` is the Electron adaptor, fed from the host's `emitEvent`.

### Guided install parity (Sep 2026)

The five autopilot ports above (`guide-recipe*`, `fix-ladder`, `setup-detour`,
`watch`, `risk`/`your-turn`/escape hatch) were developed concurrently and merged
onto `windows-parity`; this section is the single map of how they compose. One
install now runs, end to end:

1. **Prerequisites detour** — `AutopilotController.start` calls `runSetupDetour`
   (`setup-detour.ts`) before the recipe's first step: any tool the recipe
   *verifies but does not install* (git, node) that is missing is installed via
   winget under the grant, or the reader is sent to its download page and Iris
   polls until it appears. A detour that gives up surfaces; it never marches into
   a recipe whose first step would fail.
2. **Derived recipe steps** — the recipe itself is derived from the fetched publik
   guide (`guide-recipe-resolver.ts` → `guide-recipe.ts` → the reviewed
   `RecipeStep` schema), the built-in `recipes.ts` table being the offline
   fallback only.
3. **Per step**: the **WD-aware risk gate** (`risk.ts`, judging the declared
   folder as well as the command text) → **execute** → **watch expectations**
   (`watch.ts`: a `verify` step, and any reader step carrying a `watch` block,
   blocks on `WatchStepExecutor.awaitStepCompletion` and advances the moment one
   expectation verifies, else hands to the reader). A `noop` step self-completes;
   a `verify` step is NOT self-completing anymore.
4. **On a failed command**, in order: **exit-127 self-heal**
   (`trySelfHealMissingTool` re-runs the recipe's own earlier install step once
   and retries — the cheap deterministic rung) → **fix ladder** (`fix-ladder.ts`,
   the reader's own model proposes ONE fix, gated at `model_proposed_fix`
   provenance behind the recipe's host allowlist, capped) → **surface "Your
   turn"** (the tray state + the "Try again / Continue past it" choice).
5. **Escape hatch**: `AutopilotController.abort()` (the red 'Stop', tray "Stop the
   install") kills the running step's process tree and marks the run terminal
   from anywhere in the flow; an in-flight outcome is discarded, never surfaced.

Reconciled invariants worth keeping:

- **One expectation type.** The guide's verify/watch signals decode into
  `WatchExpectation`/`StepWatch` and the derivation carries the guide's `watch`
  block through verbatim onto `RecipeStep.watch` — the same field the runner and
  `watch.ts` read. (The earlier split where the derivation wrote a separate
  `verifyExpectations` the runner never read is gone; do not reintroduce it.)
- **The runner constructor arg order is** `(recipe, platform, autonomyGranted,
  fixLadder?, watchExecutor?, eventSink?)`; the **controller's is** `(host,
  makeShell?, resolveRecipe?, makeFixLadder?, detourSeams?, makeWatchExecutor?)`.
  Every hook past `autonomyGranted`/`makeShell` is optional and undefined-tolerant,
  so the pure suite drives the runner with none of them. `eventSink`, when set,
  makes the runner forward each event live (the controller wires it to
  `forwardEvent`) instead of buffering it for `drainEvents` — so a `handedToReader`
  reaches the reader before a multi-minute watch begins, not after
  `runUntilBlocked` finally resolves.
- **Self-heal runs before the fix ladder** (deterministic before model), and both
  run before anything surfaces.

## Style

Follow the publik house style, which is `iris-macos/CLAUDE.md`'s:

- **Optimise for clarity over concision.** Long, specific names. No
  single-character variables. `refinedPointInCropSpace`, not `p`.
- Pass arguments under the same name they had at the call site.
- Comments explain *why*, especially for the coordinate conversions, the
  key-isolation gate, and anything that looks redundant but is a safety net.
- Clear is better than clever; more lines are fine if they read better.

## Do NOT

- Do not add a function that takes an API key and an unvalidated URL.
- Do not reintroduce voice, TTS, or audio.
- **The "companion chat is Anthropic-only, full stop" rule is retired** (founder
  decision, 2026-09-21). It said no non-Anthropic provider may enter
  `services/assistant-transport.ts` / `main/companion.ts`. Chat now has three
  routes — publik API (the default), the user's own Anthropic key, and the Codex
  CLI — because the funded tier was removed and every public install has to
  bring its own way to pay. `docs/assistant-credentials.md` at the repo root is
  the contract; read it before adding a fourth.
- **Never Anthropic OAuth.** `claude setup-token`, importing an existing
  `claude login`, or storing any `sk-ant-oat…` / Claude.ai session token is
  prohibited by Anthropic's own terms for third-party apps ("developers may not
  collect, store, or intermediate Claude.ai credentials or session tokens").
  This client has never had that path and must not grow one; macOS had it and it
  was removed. Anthropic access is API keys only. Codex is the sanctioned
  OpenAI-side analogue, which is why it is allowed.
- Maintain mode's Tier C fixer may still run on a BYO OpenAI key
  (api.openai.com only, same pairing rule). See `main/maintain/controller.ts`
  and `services/maintain/model-provider.ts`.
- Do not add a second test runner. It is vitest.
- Do not rewrite `renderer/guide/app.js` to Windows conventions.
- Do not download Electron's Windows binaries on a dev machine — cross-building
  is CI's job.

## Self-update

When a change affects the architecture, the file layout, the coordinate
pipeline, the deep-link rules, or the key-isolation property, update this file
and `README.md` in the same commit. Do not update either for a minor fix.
