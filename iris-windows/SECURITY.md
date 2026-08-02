# Security Model

## Two ways to reach a model, and nothing else

Iris has exactly two transports, defined by
[`docs/iris-assistant-protocol.md`](../docs/iris-assistant-protocol.md) §1:

| Tier | Endpoint | Credential |
|---|---|---|
| Funded | `POST {publik}/api/assistant/chat` | a Supabase access token (publik holds the Anthropic key server-side) |
| BYO | `POST https://api.anthropic.com/v1/messages` | the user's own `x-api-key` |

There is no third route, no user-configurable proxy URL, and no other provider.
The generic proxy setting upstream shipped was removed precisely because an
arbitrary destination plus a credential is the shape of the mistake the rule
below exists to prevent.

## The key-isolation property

**A user's own Anthropic key is never sent to any publik host.**

Enforced three ways in `src/services/assistant-transport.ts`:

1. **Structurally.** The only function that writes an `x-api-key` header takes
   no URL — its destination is a compile-time constant. There is no function
   anywhere that accepts both a key and a destination, so "send the key
   somewhere else" is not something the code can express.
2. **By assertion.** Every request leaves through `validatedRequest`, which
   refuses an `x-api-key` bound for any host but `api.anthropic.com`, and —
   stated from the other side — refuses to let a publik host see that header at
   all. The check is case-insensitive, so a refactor spelling it `X-API-Key`
   trips it too.
3. **By test.** `tests/assistant-transport.test.ts` asserts it in both
   directions; `tests/claude-service.test.ts` asserts it again at the point the
   request actually reaches the wire, including that the funded request does not
   contain the key anywhere in its serialised form.

## Secret storage

Secrets are held with Electron `safeStorage`, which is **DPAPI** on Windows: the
ciphertext is bound to the Windows user account and is useless if the file is
copied to another machine.

| Secret | Where | Notes |
|---|---|---|
| BYO Anthropic key | `%APPDATA%/iris/secrets.json`, DPAPI-encrypted | never logged, never synced |
| Supabase refresh token | same | rotated on use |
| Supabase access token | memory only | never written to disk (protocol §4) |

`settings.json` contains **no secrets** and is safe to attach to a bug report.

If Windows will not provide encryption, Iris says so and **refuses to store the
key** rather than falling back to plaintext.

### Upgrading from clicky-windows

Upstream stored every API key in `%APPDATA%/clicky-windows/settings.json` in
plain text. On first run Iris migrates the Anthropic key into `safeStorage` and
removes the plaintext keys — including the ones for providers this fork dropped —
so upgrading strictly improves the user's position.

## Data flow

| Data | Where it goes | Persisted? |
|---|---|---|
| Screenshots | memory, then the active transport only | **No** — never written to disk |
| Typed messages | the active transport only | No |
| Conversation history | memory, last 10 turns | No |
| Settings | `%APPDATA%/iris/settings.json` | Yes, no secrets |
| Secrets | `%APPDATA%/iris/secrets.json` | Yes, DPAPI-encrypted |

Iris does not capture audio. Voice input and text-to-speech were removed in this
fork; there is no microphone code left in the tree.

## What runs on your machine

A guide is server-served content — it changes without a client release, and no
reviewer of this binary saw it. So:

- **Programs.** A guide can only trigger a version check for a tool on the fixed
  allowlist in `src/services/tool-versions.ts`, and no part of the command is
  built from guide text. Commands run with `shell: false`.
- **Links.** A guide can only open a host on the 22-entry allowlist in
  `src/services/external-links.ts`, which matches `allowed_external_host` in
  `iris-desktop/src-tauri/src/main.rs`. A blocked host renders a **disabled
  control naming it** — never a button that silently does nothing.
- **Deep links.** `iris://` links are validated against the rules ported from
  `main.rs` lines 188–285, where an unknown query parameter is rejected outright
  rather than ignored.

## Renderer isolation

Every window runs with `contextIsolation: true` and `nodeIntegration: false`.
`src/preload/index.ts` is the complete list of what a renderer can do — and it
has no function that returns a stored secret. A renderer can ask *whether* a key
exists and can set one; it can never read one back.

The chat and settings windows declare a CSP that blocks all remote loads. They
have no CDN scripts and no remote fonts.

## Sign-in

PKCE OAuth in the **system browser** via `shell.openExternal` — never a webview.
Google refuses to complete OAuth inside embedded browser views, and protocol §4
requires the real browser regardless. The state token is checked on the way back;
a callback the app did not initiate is discarded.

## Logging

Iris logs pipeline stages and multi-monitor warnings. Screenshots, message
content, response content, API keys, and tokens are **never logged**.

Funded-tier server-side logging is token counts only, never content (protocol §5).

## Reporting security issues

Open a security advisory on the publik repository rather than a public issue.
