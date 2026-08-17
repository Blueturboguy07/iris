# Iris for Windows

publik's desktop companion, ported to Windows. It lives in the system tray. You
type a question, it reads what is on your screen, answers in text, and can fly a
small cursor to point at the exact UI element it is talking about. It also opens
publik's install guides from `iris://guide/...` links.

A fork of [tekram/clicky-windows](https://github.com/tekram/clicky-windows),
which is itself a Windows port of [farzaa/clicky](https://github.com/farzaa/clicky).
Both are MIT; see `NOTICE` and `LICENSE.upstream`.

The authoritative contract this client implements is
[`docs/iris-assistant-protocol.md`](../docs/iris-assistant-protocol.md) in the
publik repo. Clients implement that document, not each other — but where
behaviour has to match exactly, `iris-macos/` and `iris-desktop/` are the
reference implementations and are named in the comments of the file that ports
them.

---

## Testing happens in CI, because the dev machine cannot run Windows

**This is the most important thing to know about working on this app.**

The machine this was written on is a Mac with no Windows VM and no room for one.
Nothing here has been run on Windows by a human. The only environment where Iris
for Windows is installed, packaged, or started is
[`.github/workflows/iris-windows.yml`](../.github/workflows/iris-windows.yml),
running on `windows-latest`. That workflow:

1. installs with `npm ci`,
2. typechecks (`tsc --noEmit`, covering the app *and* the suite),
3. lints,
4. runs the full unit suite,
5. packages the app and makes the Squirrel installer,
6. **starts the packaged `iris.exe` and requires it to survive ten seconds** —
   a build that cannot start is worse than no build, because it packages
   cleanly and fails on a user's machine instead of here,
7. uploads the installer as an artifact, including on failure.

The unit suite is deliberately free of network, display, and Windows-only APIs,
so it runs identically on macOS during development and on Windows in CI. That is
what makes it possible to work on this at all — but it also means **anything the
suite cannot reach is unverified**. See "What has not been verified" below.

The things the unit suite cannot reach — because they need a real launched app
on a real Windows desktop — are covered instead by a separate **headed GUI
end-to-end suite** (`tests/gui-e2e/`, its own
[`.github/workflows/iris-windows-gui-e2e.yml`](../.github/workflows/iris-windows-gui-e2e.yml)).
It launches the packaged app on the `windows-latest` runner, drives it over the
Chrome DevTools Protocol, and exercises the Windows-only paths for real: the WER
crash watcher (a genuine `Report.wer` → a live ask), the PowerShell hang probe +
`GetForegroundWindow` P/Invoke, safeStorage/DPAPI key storage, `iris://`
delivery, and a full autopilot install. It is **not** part of `npm test` (it
needs a display and Windows), and it uploads screenshots + a results log. One
test-only main-process hook (`e2e_open_settings`, gated behind `IRIS_E2E=1`)
opens the Settings window from CDP and does nothing outside the suite. See
`tests/gui-e2e/README.md`.

```sh
npm install     # once
npm test        # the suite — works on any OS
npm run typecheck
npm run lint

npm run dev      # only meaningful on Windows
npm run make     # builds the installer; CI's job, not a Mac's
npm run gui-e2e  # headed GUI suite; needs a packaged app + a Windows desktop (CI only)
```

---

## What is ported

| Area | Notes |
|---|---|
| Tray app, chat window, screenshot capture | Inherited from upstream, rebranded. |
| Two-pass `[POINT]` refinement | Inherited. The arithmetic was extracted into `src/services/coordinates.ts` so it could be tested; the behaviour is upstream's. |
| Multi-monitor overlays | Inherited. One click-through overlay per display, index-aligned with `screen.getAllDisplays()`. |
| Settings store | Rewritten: secrets moved out of plaintext JSON into `safeStorage`. |
| Guide panel | **Transplanted** from `iris-desktop/ui`. `src/renderer/guide/app.js` is byte-for-byte the Tauri panel apart from one added feature (see below); `iris-bridge.js` is the only Windows-specific part. |

## What was added

**Two transports** (`src/services/assistant-transport.ts`). Funded —
`POST {publik}/api/assistant/chat` with a Supabase bearer token — or BYO —
`POST https://api.anthropic.com/v1/messages` with the user's own `x-api-key`.

> **The BYO key is never sent to a publik host.** This is enforced three ways,
> exactly as `iris-macos/leanring-buddy/AssistantTransport.swift` does it:
> structurally (the only function that writes an `x-api-key` header takes no URL
> — its destination is a constant, so "send the key somewhere else" is not
> something the code can express), by assertion (`validatedRequest` refuses that
> header on any host but `api.anthropic.com`, and refuses to let a publik host
> see it at all), and by test (`tests/assistant-transport.test.ts` asserts it in
> both directions, and `tests/claude-service.test.ts` asserts it again at the
> point the request actually leaves).

**Supabase sign-in** (`src/services/account-service.ts`, `src/main/account-session.ts`).
PKCE in the **system browser** via `shell.openExternal`, never a webview — Google
refuses OAuth in embedded views. No Supabase SDK: it is an authorize URL plus a
token exchange. The refresh token is stored with `safeStorage`; the access token
is memory-only.

**Deep links** (`src/services/deep-link-parser.ts`). Ported from
`iris-desktop/src-tauri/src/main.rs` lines 188–285: one slug, positive integer
version, branch in `{macos,windows}×{ios,android,desktop}`, step ≤ 500, and
**unknown query parameters rejected outright** rather than ignored. Plus
`iris://auth/callback`. The `iris://` scheme is registered on Windows and a
single-instance lock turns the OS's "launch again with the URL" into a message to
the running app.

**Guides** (`src/services/guide-service.ts`). `GET {publik}/api/iris/guides/{slug}?version=n`,
with 400 / 403 / 404 / 409 each mapped to its own failure — those four mean four
different things to a reader, and 409 in particular is the difference between
"restart, the guide moved" and silently following steps for a commit they do not
have.

**External-link allowlist** (`src/services/external-links.ts`). The same 22 hosts
as `allowed_external_host` in `main.rs`. A step whose host is not on it renders a
**disabled control naming the host** — never a button that silently does nothing.
That dead-button case is the bug `iris-desktop 0.1.4` fixed, and it is the one
change made to the transplanted `app.js`.

**Secrets at rest** (`src/main/secrets.ts`). Electron `safeStorage`, which is
DPAPI on Windows, so ciphertext is bound to the Windows account. Upstream kept
API keys in `%APPDATA%/clicky-windows/settings.json` in plain text; a pre-fork
install is migrated on first run and the plaintext keys are removed. If Windows
will not provide encryption, Iris says so and refuses to store a key rather than
falling back to plaintext.

## What is deliberately absent

Removed in the fork, and not coming back:

- **Transcription** — AssemblyAI streaming, OpenAI Whisper, local whisper.cpp.
- **Text-to-speech** — ElevenLabs, OpenAI TTS, Windows SAPI.
- **Audio capture and push-to-talk**, and the global hotkey that drove them.
- **The OpenAI and OpenRouter chat providers.** Iris is Anthropic-only.
- **The generic API proxy setting.** The funded transport replaces it; an
  arbitrary user-supplied proxy URL is exactly the shape of the mistake the
  key-isolation rule exists to prevent.
- **HIPAA mode**, whose meaning was "do not send audio to the cloud".
- Upstream's roadmap files, its ad-hoc `scripts/test-*.js` API scripts, and its
  CI workflow (replaced by the one in this repo's `.github/workflows/`).

Not yet built, and honestly out of scope for the port:

- UIA accessibility grounding (protocol §2 steps 1–2). Iris currently goes
  straight to the vision fallback, which is what upstream did.
- The adaptive watch loop (protocol §7) that `iris-macos` has.
- MSIX packaging and Store submission. Squirrel/NSIS only for now.

## Layout

```
src/
├── main/            Electron main process
│   ├── index.ts         windows, tray, IPC, iris:// scheme, guide commands
│   ├── companion.ts     typed message → screenshot → model → points → overlay
│   ├── screenshot.ts    desktopCapturer; all arithmetic delegated to services/
│   ├── account-session.ts  live sign-in state; the only thing that opens a browser
│   ├── secrets.ts       the only code that touches a secret at rest
│   ├── settings.ts      plain JSON, and nothing secret in it
│   └── tray.ts
├── services/        Pure, injectable, and therefore tested
│   ├── assistant-transport.ts  the two routes + the key-isolation gate
│   ├── claude.ts               Messages API client, transport-driven
│   ├── coordinates.ts          the three coordinate spaces
│   ├── deep-link-parser.ts     every iris:// link, and every refusal
│   ├── external-links.ts       the 22-host allowlist
│   ├── guide-service.ts        guide fetch + the four distinct failures
│   ├── account-service.ts      Supabase PKCE with no SDK
│   └── tool-versions.ts        the programs a guide may cause Iris to run
├── preload/         The complete list of what a renderer can do
└── renderer/        chat · guide (transplanted) · overlay · settings
tests/               8 files, no network, no display, no Windows
```

## The coordinate pipeline

Upstream's own notes call this the easiest part of the codebase to break, so it
is worth stating plainly. Three spaces:

1. **NATIVE** — real device pixels. A 2× 1080p display is 3840×2160 here.
2. **IMAGE** — the downsampled JPEG the model actually saw, long edge ≤ 1568.
   Every `[POINT:x,y]` the model emits is in this space.
3. **DISPLAY** — device-independent pixels, which is what the overlay window is
   sized in. A 2× 1080p display is 1920×1080 here.

`NATIVE → IMAGE → (model points) → NATIVE crop → (model refines) → IMAGE → DISPLAY`.

The bug to watch for is applying one space's scale factor to another space's
number: on a 2× display that is silently off by exactly 2×, which reads as a
mediocre model rather than as a unit error. All of it lives in
`services/coordinates.ts` as pure functions, and `tests/coordinates.test.ts` is
table-driven across 1×, 1.5×, and 2× displays for that reason.

## What has not been verified

Being explicit, because the suite's green tick does not cover these:

- **Nothing has run on Windows** except in CI. The launch smoke test proves the
  packaged app starts and stays up; it does not prove any feature works.
- **DPAPI round-trip.** `safeStorage` cannot be exercised on macOS in a
  meaningful way, so encrypt-then-decrypt on a real Windows account is untested.
- **`iris://` scheme registration**, and the OS handing a link to a running
  instance. The *parsing* is heavily tested; the *delivery* is not.
- **The real OAuth round trip.** URL construction and callback parsing are
  tested, including that an authorize URL's `redirect_to` produces a callback the
  parser accepts. An actual Google sign-in is not.
- **Screen capture, the overlay, and pointing accuracy.** These need a real
  desktop with real windows on it.
- **The transplanted guide panel rendering.** `app.js` is proven only by having
  worked in `iris-desktop`; the Electron bridge under it is not covered by the
  suite. In particular, whether `localStorage` works on this window's `file://`
  origin is unknown, so `iris-bridge.js` falls back to an in-memory store if it
  throws — meaning guide progress may not survive a restart until someone
  confirms which branch actually runs.

## Configuration

| Variable | Needed by | Without it |
|---|---|---|
| `IRIS_SUPABASE_URL` | funded tier sign-in | the sign-in buttons are disabled and Iris explains why |
| `IRIS_SUPABASE_ANON_KEY` | funded tier sign-in | same |

Both are public values. Neither is a secret, and no secret ships in the binary:
the funded tier means publik holds the Anthropic key server-side, and the BYO
tier means the user holds their own in DPAPI.
