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

## 6. Watch loop budget

While a step with a `watch` block is active: capture ~every 2 s, local
perceptual diff first, model evaluation only on meaningful change with ≥ 10 s
between model checks and ≤ 8 model checks per step. Cheapest-first evaluation
order: foreground app / window title / tool version / git head / AX state,
then a single visual check only if the step declares one. Verdicts:
`completed | not_yet | user_stuck(hint)`; `user_stuck` may trigger one
proactive chat message with optional pointing.
