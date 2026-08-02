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
| Swift app | 72 tests; host allowlist byte-identical to `main.rs` |
| Guides in the desktop app | live `iris://` link fetched cue v3 from publikhq.com and opened it at step 1 of 11; malformed and hostile links each rejected distinctly without crashing |
| Setup recovery | a missing prerequisite diverts into `setupSteps`; re-check advances to the saved step; skipping is possible; detour progress cannot overwrite guide progress |
| Mods and interviews | demand accumulated 1-2-3 on one row, phrasing variants collapsed onto it, anon refused both RPC and direct insert while still reading the public list |

## What is built but not yet reachable by a user

- **App awareness and updates.** `AppAwarenessService` and
  `ToolVersionService` exist and `apps-config.ts` now carries `macBundleId`
  (4 of 10 verified off real builds, the rest deliberately null). Nothing
  polls them yet, so there is still no installed-app inventory and no update
  detection.
- **Mods and interviews have no desktop surface.** The API and tables are live
  and verified; the first-install interview is never asked, and suggested mods
  are never shown.
- **The patch pipeline end to end.** Every route and table exists and the
  promotion rules are verified, but no repo has the workflow yet and no break
  has been dispatched.
- **`/api/telemetry` has no producers.** The convention is written
  (`docs/publik-sdk-convention.md`); no catalog app emits logs yet.

## Not started

Grounding bake-off (Phase 0 — the decision gate for how Iris points at
things), the watch loop and its privacy guardrails, key-minting flows, and
the Windows port.

## Two things to know before touching the Swift app

- `iris-macos/CLAUDE.md` forbids terminal `xcodebuild` because it invalidates
  TCC grants. That was lifted for this work; treat it as back in force.
- `leanring-buddyUITests` fails under `CODE_SIGNING_ALLOWED=NO` — macOS kills
  the unsigned runner. Pre-existing and unrelated; confirmed by removing all
  new files and reproducing. Use `-only-testing:leanring-buddyTests`.

## Grounding lab — the Phase 0 answer

`iris-macos/tools/grounding-lab` measures how accurately a model can point at
real macOS UI, using the accessibility tree as automatically generated ground
truth. No hand-labelling. `swift build` in that directory; see its README.

Measured on a Safari page whose 53 targets are 22 links + 19 buttons — the
same kind of control the key-minting flow has to point at. Same screenshot,
same instructions, 20 targets per model arm:

| arm | coverage | hit | median error | p95 error | cost / 20 |
|---|---|---|---|---|---|
| `ax` | 77% | **100%** | 0pt | 0pt | $0 |
| `claude-haiku-4-5` | 90% | 83% | 2pt | 123pt | $0.070 |
| `claude-sonnet-5` | 100% | 90% | 1pt | 32pt | $0.259 |

**Haiku can ground.** That was the load-bearing unknown: the funded tier pays
for a Haiku-class model, and if it could not point, grounding would have had
to move behind bring-your-own-key and change the product. At 83% hit and 2pt
median error on web controls, it can.

**The hybrid the plan predicted is the right shape.** Accessibility is free,
instant and exact where it reaches; it reached 77% here and 100% on Finder.
Sending only what AX misses to Haiku gives roughly 94% end-to-end
(0.77 + 0.23 x 0.90 x 0.83) at about $0.0008 per grounding, because most
lookups never leave the machine. Sonnet is meaningfully better — and 3.7x the
price — which makes it the right default for the bring-your-own-key tier
rather than the funded one.

**Read the p95, not just the median.** Haiku's 123pt p95 means that when it is
wrong it is wrong by a long way. A cursor flying confidently to the wrong
control is worse than an assistant saying it is unsure, so the pointing UI
needs a confidence path — prefer AX when it has an answer, and be willing to
describe the target in words instead of pointing at it.

Caveat on strength of evidence: n=20 per arm on one page of one app. Enough to
choose an architecture, not enough to quote as a benchmark. An earlier Finder
capture full of near-identical filename rows scored 0/6 on that role, so
per-surface variation is large and the harness should be re-run against each
new flow rather than trusted once.

### Bugs the harness found in shipping code

- **`ElementLocationDetector.swift` hardcodes the `computer_20251124` tool
  version, which `claude-haiku-4-5` rejects outright.** It needs
  `computer_20250124` with the `computer-use-2025-01-24` beta header for that
  model. The detector is not wired to anything yet, so nothing is broken
  today — but grounding would have failed on the cheap tier the moment it was,
  and the failure looks like "the model cannot point" rather than a version
  error.
- The same file flips Y (`displayHeight - y`) to hand AppKit a bottom-left
  point for the cursor overlay. AX rects are top-left. Copying that flip into
  grounding scored 0/8 hits at 531pt median error versus 6/8 at 4.5pt — a
  wrong flip does not look like a bug, it looks like a model that cannot
  point.
- `max_tokens: 256` truncates Haiku mid-preamble before it emits the tool call.
- A `scroll` action carries a coordinate too; counting it as a pointing answer
  inflates coverage with nonsense.
