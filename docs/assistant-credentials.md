# Assistant credentials

How Iris gets a model, on both platforms. This is the behavioural contract the
macOS and Windows clients each implement in their own language — parity here
means *the same behaviour*, not shared code.

The server side of the publik API path is specified in `CONTRACT.md` (the
publik-api research corpus), especially §3.2 (provisioning) and §12 (the in-app
CTA). Where this file and `CONTRACT.md` disagree about the gateway, `CONTRACT.md`
wins and this file is the bug.

## The three options a user has

1. **publik API** — the default. Metered, billed to the user at half the
   provider's list price. Auto-provisions on first run; a $0.25 starter means it
   works before anyone has paid anything.
2. **Your own Anthropic key** — a pasted `sk-ant-…`, stored locally, sent only to
   `api.anthropic.com`, never to publik.
3. **Sign in with ChatGPT (Codex CLI)** — drives the user's own `codex` binary.
   Iris stores no OpenAI credential; the CLI owns it.

There is no fourth option. In particular:

- **The funded tier is gone.** `POST /api/assistant/chat` (publik's own Anthropic
  key, free to signed-in users) is no longer a transport. It was the reason Iris
  could not be handed out publicly: per-user caps, no global cap, so exposure
  scaled with the number of accounts. publik API replaces it — same "it just
  works" first run, paid by the person using it. The server route stays up for
  already-installed older builds; new builds must not call it.
- **No Anthropic OAuth, ever.** Claude.ai / Claude Code subscription tokens
  (`sk-ant-oat…`, `claude setup-token`, importing an existing `claude login`) are
  prohibited for third-party apps by Anthropic's own terms: developers may not
  "collect, store, or intermediate Claude.ai credentials or session tokens", nor
  route requests through Free/Pro/Max credentials on a user's behalf. Anthropic
  access is API keys only — the user's own, or publik's via the gateway. Codex is
  the sanctioned analogue on the OpenAI side, which is why it is option 3.

## Choosing between them

An explicit, stored preference — one of `publikApi | anthropicKey | codex` — and
the user can change it in settings. This replaces the old implicit ladder, where
being signed in silently beat a key the user had pasted themselves.

With no stored preference, resolve in this order, first usable wins:

1. `publikApi` if a publik API key is stored, or one can be provisioned.
2. `anthropicKey` if one is stored.
3. `codex` if the CLI is present and signed in.
4. Otherwise: no credential — say so, and offer the three options.

A stored preference that has become unusable (key revoked, CLI signed out) does
not silently fall through to another provider. Say what broke and offer the fix;
spending someone's money on a different account than they chose is worse than an
error message.

## The publik API path

**Provisioning.** Two routes to a key:

- *Machine* (preferred, this is the "auto setup"): show the disclosure, then
  `POST /api/v1/installs` with the build's app token. Returns a `pk_live_…` key,
  a claim code and the starter. Consent precedes the mint — never call this
  before the disclosure is accepted.
- *Human*: the user pastes a `pk_live_…` key from `publikhq.com/dashboard/api`.
  This is the fallback whenever the build carries no app token, and must keep
  working regardless.

**The app token** is a build-time constant (`pat_iris_<32>`), public by
construction since it ships inside the binary — that is expected and contained:
tokens are per-release, revocable, IP rate-limited, and mint only a small
starter. A build without one is not broken; it falls back to the human route.
Note that macOS releases are cut locally, so the token has to be available to a
local build, not only to CI.

**Request shape.** `POST {base_url}/messages` — Anthropic wire format, which is
what Iris already speaks, so this is a base-URL and auth-header swap, not a
rewrite. Auth is `x-api-key: pk_live_…`. Use the alias model names
(`publik-fast` / `publik-balanced` / `publik-smart`), never a raw upstream slug.
Honour the `base_url` the provisioning response returned over any compiled
default.

**Reading back.** Every metered response carries `x-publik-balance`,
`x-publik-claim-state` and friends. Keep the last balance seen; it is what the
CTA renders.

**402 `insufficient_credit`** is a normal state, not a crash. Show the server's
own message and exactly one link from the response (`top_up_url`, `claim_url` or
`add_credit_url` — whichever it sent). Do not invent copy for this.

## The CTA

`CONTRACT.md` §12 is binding and applies to Iris. In short:

- A first-run card **after** provisioning succeeds, showing the balance line, the
  one-sentence justification (the model provider charges per use; publik passes
  it on at half the provider's list price; nothing is charged behind your back;
  every call is on the dashboard), and a primary **"Link this computer & pick a
  plan"** button to `claim_url`.
- The same button in settings while the install is unclaimed; it becomes "Add a
  plan or pack" once claimed.
- **Never a silent starter.** The app must not spend starter credit before that
  card has been shown at least once. The pre-provisioning disclosure is not that
  card — the card comes after, with the real balance on it.

**Copy rules**, same as the site enforces in `copy-guard.test.ts`: say "publik
API"; show **dollars**, never tokens and never "credits" as a unit; never name
the upstream provider in user-facing copy.

## First run

Both platforms ask for credentials during onboarding — today neither does.
macOS has an onboarding flow (permissions, then a walkthrough) and the
credential step goes after permissions. Windows has no first-run flow at all and
needs one.

The default path should be one obvious action: accept the disclosure, get
provisioned, see the card, start using it. The other two options are offered
alongside, not buried.

## What still works with no credential at all

Everything that is not the model: install guides end to end, the watch loop,
autopilot command execution and its risk gate, app inventory. Only chat and the
model-backed fix ladder need a transport. Keep it that way — a user with no
credentials should still get the whole guided-install product.
