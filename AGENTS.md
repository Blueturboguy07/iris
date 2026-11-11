# Iris: notes for agents

The macOS app's notes are in `iris-macos/AGENTS.md`; the Windows app's in
`iris-windows/AGENTS.md` when present. This file holds what is common.

## publik API
- Base URL: https://publikhq.com/api/v1 (OpenAI Chat Completions, Responses, Anthropic Messages)
- Models: publik-fast, publik-balanced, publik-smart only; never a vendor model name
- Sign in with publik: the publik module's gate runs at start-up, before the first screen; it also sends usage telemetry
- Key: per-install `pk_` from POST /installs, stored at the publik credential path; env PUBLIK_API_KEY / PUBLIK_API_BASE_URL override
- App token: `PublikAppToken` in Info.plist from the `PUBLIK_APP_TOKEN` build setting (macOS, `iris-macos/.publik-app-token` is gitignored) and the baked `BAKED_APP_TOKEN` constant (Windows), or PUBLIK_APP_TOKEN in the environment
- 402: show error.message plus error.top_up_url only
- Never print or log a key
- Docs: https://publikhq.com/llms.txt, https://publikhq.com/developers, https://publikhq.com/skills/api.md
