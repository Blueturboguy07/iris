# Iris assistant protocol

The contract between the publik backend and every desktop Iris client
(`iris-macos/`, later `iris-windows/`). Clients implement this document, not
each other's source; anything not specified here is a client implementation
detail. Server-served content (guides, flows, prompts) changes without client
releases — that is the point.

## 1. Model transports

A client has exactly two ways to reach a model, and they speak the same wire
format (the Anthropic Messages API, streaming SSE):

| Tier | Endpoint | Auth | Model |
|---|---|---|---|
| Funded | `POST {base}/api/assistant/chat` | `Authorization: Bearer <supabase access token>` | pinned server-side (Haiku-class); client's `model` field is ignored |
| BYO | `POST https://api.anthropic.com/v1/messages` | user's own `x-api-key`, stored in Keychain (macOS) / DPAPI (Windows) | client's choice |

Rules:

- The BYO key is never sent to any publik host, logged, or synced. Losing this
  property is a ship-blocker.
- The funded route prepends a server-owned system block; client `system`
  content (flow steps, app inventory, hints) is appended after it. Keep the
  client's stable context early in its system content for prompt caching.
- Funded-tier error codes the client must handle: `sign_in_required` (401 →
  re-auth), `rate_limited` / `daily_budget_exhausted` (429 + `Retry-After` →
  quota UI, offer BYO), `assistant_unconfigured` (503 → treat as outage),
  `upstream_error` (4xx/502).
- Max 50 messages per request; the funded tier caps `max_tokens` at 2048.
- Screenshots ride as standard Anthropic image content blocks. Vercel bodies
  are limited to ~4.5 MB — downscale screenshots before sending (long edge
  ≤ 1568 px unless the active model is documented for higher-res grounding).

## 2. Grounding contract

The model is prompted to point by emitting tags in its text stream:

```
[POINT:<descriptor>]
```

`<descriptor>` is the visible label or a short unambiguous description of the
target element ("Create Key button", "the Settings tab"). It is NOT raw
coordinates. The client strips the tag from displayed text and resolves it
via its grounding chain:

1. Accessibility exact match (AX on macOS, UIA on Windows) → element rect.
2. Accessibility fuzzy match (role + label similarity).
3. Vision fallback: one dedicated model call with the current frame asking for
   pixel coordinates of the descriptor, followed by a second call on a
   ~300 px crop around the first answer (two-pass refinement). Clamp to
   screen bounds.
4. If everything fails: point at the containing region and say the target's
   name aloud in text ("bottom-right of the window, labeled *Create Key*").

Which steps are enabled per platform is decided by the Phase-0 bake-off; the
tag format and the chain's order are fixed so prompts stay shared.

## 3. Guide sessions (anonymous handoff)

Guide progress never requires an account. The website (or a client) creates a
session only on an explicit user action:

- `POST /api/iris/sessions` `{slug, version, branch}` → `201 {sessionId,
  sessionToken, expiresAt}`. The token is returned exactly once; only its
  SHA-256 is stored. `branch` is the `branchKey()` string
  (`macos:ios`, `windows:desktop`, ...).
- `GET /api/iris/sessions/{id}` with header `X-Iris-Session-Token` → progress
  document.
- `PATCH /api/iris/sessions/{id}` same header,
  `{stepKey, stepStatus, verificationMode?, sessionStatus?, setCurrent?}`.
- Unknown id, bad token, and expired session all answer `404
  session_not_found` — indistinguishable by design.

Deep links: `iris://guide/<slug>?version=<n>&branch=<key>&step=<n>` exactly as
validated today (single slug, integer version, known branch, step ≤ 500,
unknown params rejected). One additional accepted URL: `iris://auth/callback`
for the OAuth redirect. Nothing else.

## 4. Identity

- Assistant features (funded chat, device registry, later: patch history, mod
  suggestions) require Supabase sign-in: native PKCE OAuth in the **system
  browser** (never a webview) redirecting to `iris://auth/callback`, or
  email+password against the Supabase token endpoint. Refresh token in
  Keychain/DPAPI, access token in memory.
- Guide sessions and guide fetching stay anonymous. The two identity layers
  are never joined server-side.

## 5. Privacy hard rules (client-enforced)

1. Screenshots live in memory only, are sent only to the active model
   transport, and are never persisted to disk.
2. Capture hard-suspends while secure input is active
   (`IsSecureEventInputSet()` / focused secure text field) and while a step
   marked `sensitive: true` is active. Sensitive-step completion is verified
   by side signals (frontmost app, user confirmation), never pixels.
3. A user-editable excluded-apps list (seeded with password managers) blocks
   capture whenever an excluded app is frontmost.
4. A visible indicator is on whenever the watch loop is active; a global
   pause toggle always works.
5. Funded-tier serverside logging is token counts only, never content.
6. Terminal output is secret-scrubbed on egress before any of it reaches a
   model — the scrub runs on the client, so nothing unscrubbed ever leaves the
   machine. A step marked `sensitive: true` is never executed, echoed into the
   terminal view, or sent to a model at all; it falls back to the copy-by-hand
   card regardless of `kind`.

## 6. Server environment

`.env.example` is gitignored here, so the variables the assistant adds are
listed instead:

| Variable | Needed by | Without it |
|---|---|---|
| `ANTHROPIC_API_KEY` | `/api/assistant/chat` | funded tier returns `assistant_unconfigured` |
| `UPSTASH_REDIS_REST_URL` / `_TOKEN` | rate limits, token budgets | the funded proxy declines in production (fail-closed); other routes fail open |
| `CRON_SECRET` | `/api/sync`, `/api/cron/rollup` | both refuse to run |
| `GITHUB_DISPATCH_TOKEN` | `/api/admin/patch/dispatch` | dispatch returns 503; needs repo + workflow scope |
| `GITHUB_WEBHOOK_SECRET` | `/api/github/webhook` | webhook refuses every delivery |

## 7. Watch loop budget

While a step with a `watch` block is active: capture ~every 2 s, local
perceptual diff first, model evaluation only on meaningful change with ≥ 10 s
between model checks and ≤ 8 model checks per step. Cheapest-first evaluation
order: foreground app / window title / tool version / git head / AX state,
then a single visual check only if the step declares one. Verdicts:
`completed | not_yet | user_stuck(hint)`; `user_stuck` may trigger one
proactive chat message with optional pointing.

## 8. Autopilot fix protocol

When a guided-install autopilot command exits non-zero, the client does not
free-chat its way to a fix. It calls a structured tool and only ever reads
that tool's arguments back — there is no `tool_result` loop, no follow-up
turn where the model is handed a result and asked to keep going. One call, one
verdict, client decides what happens next.

**`propose_fix`** is the tool, and its schema is the whole contract:

```
{
  diagnosis: string,
  confidence: "high" | "medium" | "low",
  retryTheOriginalCommandAfterwards: boolean,
  action:
    | { runACommand:            { command: string, whatItDoes: string } }
    | { askTheReaderToDoSomething: { instruction: string } }
    | { cannotFixThis:          { reason: string } }
}
```

The client renders `diagnosis` regardless of which `action` variant came
back, runs `runACommand` through the same risk gate as any other guide
command — nothing here bypasses it, a fix that needs a confirm tap gets
one — and stops the ladder outright on `cannotFixThis`.

**The ladder** a failing step climbs:

1. Propose a fix from the guide material already in context (the step, the
   failing command, the terminal tail). No tool beyond `propose_fix` itself.
2. If that fix fails too, propose a fix informed by a web search. This rung
   grants Anthropic's server-side `web_search_20250305` tool for that one
   call — the model searches, reads results, and still answers through
   `propose_fix`, not free text.
3. If that also fails, autopilot stops proposing and surfaces the diagnosis
   plus the failing command to the reader, who takes it from there.

**Tool allowlisting is server-side**, not a client promise. The funded proxy
accepts only `web_search` and schema-only client tools (`propose_fix` and its
kin) on this path; `code_execution`, `computer`, `bash`, `text_editor`,
`memory`, `mcp_toolset`, and `web_fetch` are rejected with `400` if a request
asks for any of them. A client cannot widen its own blast radius by asking —
the server would have to widen it first.

**Budgets, latched per guide:**

| Limit | Value |
|---|---|
| Fix attempts per step | 2 |
| Fix attempts per guide | 6 |
| Model calls per guide (fix ladder) | 8, latched |
| `max_tokens` per fix call | 700 |
| Web search `max_uses` | 5 |

Hitting any ceiling behaves like rung 3: diagnosis and failing command
surfaced, no further proposals for that guide.
