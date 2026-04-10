# Security Model

## Architecture

Clicky Windows uses a **BYOK (Bring Your Own Keys)** model. All API keys are stored locally on your machine and sent directly to providers — there is no intermediary proxy server by default.

```
Your Machine                          Cloud APIs
┌─────────────────┐                  ┌──────────────┐
│ Clicky App      │ ──── HTTPS ───→  │ Anthropic    │
│                 │ ──── HTTPS ───→  │ OpenAI       │
│ settings.json   │ ──── HTTPS ───→  │ OpenRouter   │
│ (local keys)    │ ──── HTTPS ───→  │ AssemblyAI   │
│                 │ ──── HTTPS ───→  │ ElevenLabs   │
└─────────────────┘                  └──────────────┘
```

## Key Storage

- API keys are stored in `%APPDATA%/clicky-windows/settings.json`
- The file is readable only by the current user (standard Windows APPDATA permissions)
- Keys are **not** encrypted at rest (improvement planned for HIPAA mode)
- Keys are **never** sent to any server other than the intended API provider
- Keys are **never** logged or included in error messages

## Data Flow

| Data | Where it goes | Stored locally? |
|------|--------------|-----------------|
| Screenshots | AI provider (Anthropic/OpenAI/OpenRouter) | No — in-memory only |
| Audio recordings | OpenAI Whisper API | No — temp file deleted after transcription |
| Transcripts | AI provider | No — in-memory, cleared on app close |
| AI responses | Displayed in chat | No — in-memory, cleared on app close |
| TTS audio | Temp MP3 file → playback → deleted | Temp only, auto-cleaned |
| Conversation history | Last 10 exchanges in memory | No — cleared on app close |
| Settings/keys | `%APPDATA%/clicky-windows/settings.json` | Yes |

## What We Don't Do

- **No proxy server** — BYOK means your keys go directly to providers, not through us
- **No analytics/telemetry** — no PostHog, no tracking, no usage data sent anywhere
- **No auto-updates phoning home** — update checks are not yet implemented
- **No admin privileges** — the app runs as a standard user process (`asInvoker`)
- **No persistent data** — screenshots, audio, transcripts are never written to disk (except temp TTS files which are immediately deleted)
- **No background data collection** — the app only captures screen/audio when you explicitly trigger it (send button, mic button, or hotkey)

## Optional Proxy

If you configure a proxy URL in settings, API calls route through that proxy instead of directly to providers. This is intended for team deployments where keys are centralized. The proxy is **your own infrastructure** — we don't provide or host one.

If using a proxy:
- Add authentication (bearer token, IP allowlist, or SSO)
- Use HTTPS
- Don't log request bodies (they contain screenshots and transcripts)
- See [proxy setup docs](docs/proxy-setup.md)

## HIPAA Mode

Toggle in settings. Forces:
- Local-only transcription (Whisper, no audio leaves device)
- Local-only TTS (Windows SAPI, no text leaves device)
- Screenshots still go to AI provider — requires BAA with that provider

See [HIPAA docs](docs/hipaa-mode.md) for full compliance checklist.

## Logging

Production logging is minimal:
- App lifecycle events (start, stop)
- Error messages (no sensitive data included)
- Transcript length (not content)
- TTS provider selection (not the text being spoken)

Transcripts, screenshots, API keys, and response content are **never logged**.

## Reporting Security Issues

If you find a security issue, please open an issue at [github.com/tekram/clicky-windows/issues](https://github.com/tekram/clicky-windows/issues) or email the maintainer directly.

## Comparison with Original macOS Clicky

The original [farzaa/clicky](https://github.com/farzaa/clicky) uses a different model:
- Cloudflare Worker proxy holds all API keys (users don't need their own)
- Worker is public/unauthenticated
- PostHog analytics enabled

Our Windows version intentionally avoids these patterns by using BYOK and zero telemetry.
