# Iris assistant — where it stands and what needs a human

Working notes for the `iris-assistant` branch. The plan this follows is
`~/.claude/plans/sparkling-bubbling-wilkinson.md`.

## What needs you (nothing below can be done by an agent)

Ordered by what unblocks the most.

1. ~~Supabase redirect allow list~~ — **done**. `iris://auth/callback**` is
   in the allow list. The glob matters: the CSRF state token rides inside
   `redirect_to`, so an exact-match entry would fail at the authorize step.

2. **Confirm the rate limiter on first deploy.** Upstash is provisioned
   (`iris-ratelimit`, Free, `iad1`) and connected to the project, injecting
   `UPSTASH_REDIS_REST_KV_REST_API_URL` / `..._TOKEN`. Those names are what
   `lib/ratelimit.ts` resolves, and the resolver is unit-tested against every
   naming variant — but the credentials themselves could not be exercised
   locally, because Vercel marks Marketplace values Sensitive and `vercel env
   pull` returns `[SENSITIVE]` placeholders. After the first deploy, send the
   assistant endpoint 21 requests in five minutes: the 21st should come back
   `429 rate_limited`. If instead everything is allowed, the limiter is
   failing open and the credentials did not resolve.

3. **Re-grant Screen Recording to Iris.** Terminal `xcodebuild` runs
   invalidate the app's TCC grants, and there were many. macOS will re-ask on
   next launch.

4. **Watch the Anthropic balance.** Credits are live and the funded tier is
   metered per user (20 requests / 5 min, 150k tokens / day), but the ceiling
   is the org balance. Auto-reload is off.

5. **For the patch pipeline (Phase 8), when you want to switch it on:**
   - Org-level secret `ANTHROPIC_API_KEY` on the GitHub org, so every catalog
     repo's workflow can use it.
   - A PAT with `repo` + `workflow` scope as `GITHUB_DISPATCH_TOKEN` in
     Vercel. The existing `GITHUB_TOKEN` is read-only and cannot dispatch.
   - An org webhook (pull_request + release events) pointing at
     `/api/github/webhook`, with its shared secret as `GITHUB_WEBHOOK_SECRET`.
   - Copy `docs/templates/publik-patch-agent.yml` into each app repo and fill
     in that repo's toolchain setup step.
   - **Review every pull request the agent opens.** Nothing auto-merges, by
     design: a green suite is not a correct fix, and signed releases are
     downstream.

6. **Merge or keep reviewing `iris-assistant`.** 32 commits. Nothing has been
   merged to `main`.

## What works, and how it was checked

Everything here was exercised against the live project, not just unit-tested.

| Piece | Evidence |
|---|---|
| Funded model proxy | Real Supabase JWT → SSE stream; asked for `claude-opus-5` with `max_tokens: 999999`, server pinned Haiku and capped at 2048 |
| Guide sessions | create → token, PATCH → progress stored, read back correct, wrong token → 404 |
| Breaks tally suppression | 4 installs on one break → counts `null`; 6 → published. Suppression lives in the SQL view, so UI code cannot leak a small count |
| Telemetry privacy | anon refused raw rows and the rollup (`42501`); consent withdrawal deletes an install's history |
| Fix recipe promotion | 2 successes → still candidate; 3rd → validated; 3 failures → demoted |
| BYO key isolation | exactly one function in the app writes `x-api-key`, it takes no URL, and a final gate rejects that header on any host but `api.anthropic.com` |
| Swift services | 56 tests; host allowlist byte-identical to `main.rs` |

## What is built but not yet reachable by a user

- **Guide setup sub-flows.** Guides now render in the panel and `iris://`
  links open them (verified live against publikhq.com: cue v3, 11 steps). What
  is missing is the recovery path — a missing Git or Node shows in the
  tool-check rows but does not walk the reader through `branch.setupSteps`.
  The data is parsed; the flow is not built. Until then the Tauri pill still
  does one thing Iris cannot.
- **App awareness and updates.** `AppAwarenessService` and
  `ToolVersionService` exist; nothing polls them, and there is no installed-app
  inventory. `lib/apps-config.ts` still needs `bundleId` / `processNames`.
- **The patch pipeline end to end.** Every route and table exists and the
  promotion rules are verified, but no repo has the workflow yet and no break
  has been dispatched.
- **`/api/telemetry` has no producers.** The convention is written
  (`docs/publik-sdk-convention.md`); no catalog app emits logs yet.

## Not started

Grounding bake-off (Phase 0 — the decision gate for how Iris points at
things), the watch loop and its privacy guardrails, key-minting flows,
first-install interviews, the mod registry, the public reliability page, and
the Windows port.

## Two things to know before touching the Swift app

- `iris-macos/CLAUDE.md` forbids terminal `xcodebuild` because it invalidates
  TCC grants. That was lifted for this work; treat it as back in force.
- `leanring-buddyUITests` fails under `CODE_SIGNING_ALLOWED=NO` — macOS kills
  the unsigned runner. Pre-existing and unrelated; confirmed by removing all
  new files and reproducing. Use `-only-testing:leanring-buddyTests`.
