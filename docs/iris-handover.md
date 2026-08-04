# Iris — where it stands

Working notes for whoever picks this up. The plan it follows is
`~/.claude/plans/sparkling-bubbling-wilkinson.md`; the one designed-but-unbuilt
piece is `docs/iris-app-integration-plan.md`.

**Shipped.** 95 commits merged to `main` and deployed to production on
2026-08-04. Everything marked *live* below was verified against
`https://publikhq.com`, not staging.

## Live in production

| Surface | Route | Verified |
|---|---|---|
| Funded model proxy | `POST /api/assistant/chat` | 401 without a token; SSE stream with one |
| Guide sessions | `POST/GET/PATCH /api/iris/sessions` | 201, progress round-trips |
| Guides + flows | `GET /api/iris/guides/[slug]` | 200, incl. the `anthropic-api-key` flow |
| App catalog | `GET /api/iris/apps` | 200, 10 apps, 4 with bundle ids |
| Breaks tally | `GET /api/iris/breaks` | 200 |
| Fix-tier routing | `GET /api/assistant/route` | known/unknown → tier |
| Telemetry | `POST/DELETE /api/telemetry` | 202 / consent withdrawal |
| Mods + interviews | `/api/iris/mods`, `/api/iris/interview` | 201 / 401 |
| Reliability page | `/reliability` | 200, unlinked by design |

Migrations 0003, 0006, 0007, 0008, 0009 applied. Tests: **web 151, macOS 193,
Windows 230, cue 17.**

## The desktop apps

**macOS** (`iris-macos/`, fork of farzaa/clicky): guides render, `iris://`
links open them, setup recovery walks a missing prerequisite, sign-in works,
the watch loop notices when a step is done, app inventory reports installed
versions and updates, and the whole conversation happens at the eye — 64pt,
pinned top-left, pupil tracking the pointer, clickable, answer inline, eye
becomes a settings gear while open.

**Windows** (`iris-windows/`, fork of tekram/clicky-windows): forked, stripped
of voice and non-Anthropic providers, pointed at the same transports; the guide
panel is a byte-for-byte copy of `iris-desktop/ui/app.js` behind a 60-line
Electron bridge. Tested in CI on `windows-latest`, because this machine cannot
run Windows — no hypervisor, and ~6 GB free against the ~70 GB a Windows 11 ARM
VM needs.

**Tauri** (`iris-desktop/`): frozen at 0.1.4. Superseded, but still the
behavioural spec for anything being ported.

## The app link

Iris can now ask a running catalog app what it is doing, rather than inferring
it from a screenshot. Newline-delimited JSON-RPC over a Unix socket, discovered
through one instance file per running app.

| Piece | Where | State |
|---|---|---|
| Shared library | `packages/app-link` (zero deps, no build step) | 37 tests, real sockets |
| First app | `~/cue` branch `app-link` — **not pushed** | 17 tests, verified live |
| Iris client | `iris-macos/leanring-buddy/AppLink*.swift` | 15 tests + live probe |
| Vendoring | `pnpm applink:vendor <repo>` | stamps the source commit |

**cue's branch is local and unpushed.** It changes a shipped app, so it is the
user's call. Nothing in publik depends on it being merged.

Two things to know before extending it:

- **Node cannot verify its peer.** No native addon means no socket peer
  credentials, so on the app side the boundary is the user account, not the
  calling app. That is why consent covers reads too, why nothing is granted
  silently, and why the sheet says "a program identifying itself as Iris". Iris
  verifies in the other direction, and `mayBeSubmitted` gates the breaks tally
  on it. Swift apps will do better; write them with a `verifyPeer` hook.
- **What goes in `get_state` is the whole question.** cue's answer is
  `src/applink-state.js`, and its rule is *counts, never content*: a transcript
  turn count and a timestamp, never a word of the transcript; which API keys are
  set, never a key. Copy that rule before copying the plumbing.

## What is NOT done

1. **No installable build exists.** No `iris-v*` tag has ever been cut; the
   only Iris in the world is the hand-signed copy in `/Applications` here.
   Tagging runs `.github/workflows/iris-release.yml` — build, Developer-ID
   sign, notarize, staple, verify it opens.
2. **No streaming.** `ClaudeAPI` streams over SSE but `CompanionManager`
   discards every chunk (`onTextChunk: { _ in }`) and publishes once at the
   end, so answers land as a block. A pipeline change, not a UI one.
3. **The patch pipeline has never been switched on.** Tables, routes and the
   workflow template exist and the promotion rules are verified against
   production — but no repo has the workflow, and there is no org secret,
   dispatch PAT or webhook.
4. **Telemetry has no producers.** Not one of the nine apps emits a log line,
   so the breaks tally cannot fill.
5. **App integration reaches one app of nine.** The library, cue, and Iris's
   client are built and verified against a running app; the other eight apps
   have not been wired up. `docs/iris-app-integration-plan.md`, phase 4.
6. **Windows integration is unproven**: DPAPI, `iris://` delivery by the OS, a
   real OAuth hop, capture and pointing have never run on Windows.
7. **Grounding lab milestone 2** — click-and-observe verification, and the VM
   to run it unattended.

## Needs a person, not an agent

- **Cut a release** (`git tag iris-v0.3.0 && git push --tags`) once the app has
  been used enough to trust it. Publishing is easier to do than undo.
- **Patch pipeline, when wanted:** org-level `ANTHROPIC_API_KEY`; a PAT with
  `repo`+`workflow` as `GITHUB_DISPATCH_TOKEN` (the existing `GITHUB_TOKEN` is
  read-only and cannot dispatch); an org webhook to `/api/github/webhook` with
  its secret as `GITHUB_WEBHOOK_SECRET`; and
  `docs/templates/publik-patch-agent.yml` copied into each app repo with its
  toolchain step filled in. **Review every PR the agent opens** — nothing
  auto-merges, deliberately.
- **Watch the Anthropic balance.** Metered per user (20 req/5 min, 150k
  tokens/day) but the ceiling is the org balance, and auto-reload is off.
- **The twenty-minute experiment** in the integration plan: does the macOS TCC
  Automation prompt fire between two apps signed with the same Team ID?

## Phase 0 result — how Iris points at things

Called 2026-08-02 on a Safari page of 22 links + 19 buttons, the control type
the key-minting flow needs. `iris-macos/tools/grounding-lab` measures this
using the accessibility tree as automatically generated ground truth, so there
is no hand-labelling.

| arm | coverage | hit | median err | p95 err | cost/20 |
|---|---|---|---|---|---|
| `ax` | 77% | 100% | 0pt | 0pt | $0 |
| `claude-haiku-4-5` | 90% | 83% | 2pt | 123pt | $0.070 |
| `claude-sonnet-5` | 100% | 90% | 1pt | 32pt | $0.259 |

**Decision: AX first, Haiku for what AX misses** — ~94% end to end at about
$0.0008 a lookup, so grounding stays free on the funded tier and Sonnet is the
bring-your-own-key default. **Design for the p95, not the median:** Haiku's
123pt tail means a confident miss lands far away, and a cursor flying to the
wrong control is worse than admitting uncertainty.

Target type dominates the number — an earlier Finder capture full of
near-identical filename rows scored 0/6. Re-run per surface; n=20 per arm is
enough to choose an architecture, not to quote as a benchmark.

## Traps that cost real time here

- **Ad-hoc signing destroys TCC grants.** `codesign --sign -` embeds a hash of
  the binary, so every rebuild is a new app to macOS and every permission is
  lost. Use `scripts/deploy-iris-local.sh`, which signs with the real Developer
  ID (designated requirement = bundle id + team, no hash) and refuses to fall
  back to ad-hoc. This is what `iris-macos/CLAUDE.md` is really warning about.
- **Supabase default privileges grant EXECUTE on new functions to `anon` and
  `authenticated` by name.** `revoke ... from public` does *not* lock a
  function down; revoke from `public, anon, authenticated` explicitly. This was
  a live hole in migration 0003, found by verifying rather than reading.
- **Vercel prepends a custom env prefix to the provider's own names.** Upstash
  arrived as `UPSTASH_REDIS_REST_KV_REST_API_URL`; `lib/ratelimit.ts` resolves
  by suffix and pairs URL+token from the same prefix, because mixing two stores
  authenticates against the wrong database silently.
- **Marketplace env values are Sensitive**, so `vercel env pull` yields
  `[SENSITIVE]` — credentials can only be exercised after a deploy.
- **Vercel's env-var page paginates.** Read the whole list before concluding
  something is missing.
- **Never run `next build` while a dev server is running.** It rewrites `.next`
  underneath it and every request 500s with an ENOENT on `_buildManifest`.
- **`leanring-buddyUITests` fails under `CODE_SIGNING_ALLOWED=NO`** — macOS
  kills the unsigned runner. Pre-existing, unrelated; always use
  `-only-testing:leanring-buddyTests`.
- **Reading Iris's logs:** stdout is fully buffered when not a terminal. Give
  it a pty — `script -q /tmp/iris.log /Applications/Iris.app/Contents/MacOS/Iris`
  — and the `🔑` permission lines appear immediately.
- **The desktop apps are separate projects.** Root `tsconfig`/`vitest` exclude
  `iris-windows/` and `iris-macos/`; each has its own runner and dependencies.
- **electron-builder's `files` is an allowlist.** Adding a directory to an
  Electron app and forgetting it there produces a build that runs perfectly
  from source and throws on `require` the moment it is packaged.
- **A native dialog from a dock-hidden app cannot be clicked.** cue calls
  `app.dock.hide()`, so it never becomes frontmost, and
  `dialog.showMessageBox` appeared and then ignored every click. Ask inside the
  app's own window instead. In cue specifically, any new full-screen UI must
  also be listed in *both* the `pointer-events` rule in `styles.css` and the
  click-through selector in `renderer.js`, or the window stays transparent to
  the mouse.

## The lesson worth keeping

Every user-visible bug in this build was found by someone *using* it, not by
519 passing tests: the app opened by playing the upstream author's demo video;
it asked for permissions it already had, forever; closing it left no way back
in; and the new input bar handed off to the old panel to answer. Tests caught
none of them. Use it before trusting it.
