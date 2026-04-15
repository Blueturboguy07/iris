# Clicky Windows

AI-powered screen companion for Windows. See your screen, hear your voice, point at answers.

Windows companion to [farzaa/clicky](https://github.com/farzaa/clicky) (macOS).

## What it does

- **Sees your screen** — captures screenshots and sends them to Claude with vision
- **Hears you** — push-to-talk voice input with real-time transcription
- **Speaks back** — text-to-speech responses via ElevenLabs or Windows SAPI
- **Points at things** — animated cursor overlay that highlights UI elements Claude references
- **Lives in your tray** — runs quietly as a system tray app

## Quick Start

### BYOK (Bring Your Own Keys)

You'll need at minimum an [Anthropic API key](https://console.anthropic.com/). Optionally:
- [AssemblyAI](https://www.assemblyai.com/) key for voice transcription
- [ElevenLabs](https://elevenlabs.io/) key for natural TTS

```bash
git clone https://github.com/tekram/clicky-windows.git
cd clicky-windows
npm install
npx tsc
npm run dev
```

> **Note:** `npm run dev` does not compile TypeScript for you. You must run `npx tsc` before the first launch and after every source change, or run `npx tsc --watch` in a second terminal.

Open Settings from the tray icon and enter your API keys.

### HIPAA Mode

Toggle HIPAA mode in Settings to force all processing to stay local:
- Transcription: local Whisper (no audio leaves device)
- TTS: Windows SAPI (no text leaves device)
- Only the Claude API call goes external (requires BAA with Anthropic)

## Architecture

```
src/
├── main/           # Electron main process
│   ├── index.ts        # App entry, window creation
│   ├── companion.ts    # Central orchestrator (voice → screen → claude → tts → overlay)
│   ├── screenshot.ts   # Screen capture via desktopCapturer
│   ├── hotkey.ts       # Global push-to-talk hotkey
│   ├── audio.ts        # Audio capture coordination
│   ├── tray.ts         # System tray setup
│   └── settings.ts     # Persistent settings (electron-store)
├── services/       # External service integrations
│   ├── claude.ts       # Anthropic Claude API (vision + chat)
│   ├── transcription/  # Pluggable: AssemblyAI, OpenAI, local Whisper
│   └── tts/            # Pluggable: ElevenLabs, Windows SAPI
├── preload/        # Context bridge for renderer
└── renderer/       # UI
    ├── overlay/        # Transparent click-through window with cursor animation
    └── settings/       # Settings panel
```

## Relation to macOS Clicky

This is a Windows-native reimplementation of [farzaa/clicky](https://github.com/farzaa/clicky). The macOS version uses Swift/SwiftUI with ScreenCaptureKit — APIs that don't exist on Windows. This version uses Electron + TypeScript to provide the same experience on Windows.

**Shared concepts:** POINT tag protocol, conversation flow, proxy worker architecture.
**Different:** Everything else (language, framework, system APIs).

## Contributing

PRs welcome. See `docs/plans/` for what's in progress.

## License

MIT
