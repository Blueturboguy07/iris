# Getting Started

Clicky is an AI-powered screen companion for Windows. It captures your screen, listens to your voice, and uses Claude to answer questions about what you're looking at — pointing directly at UI elements in its responses.

## Installation

### From Release (Recommended)

1. Download the latest `.exe` from [Releases](https://github.com/tekram/clicky-windows/releases)
2. Run the installer
3. Clicky appears in your system tray (bottom-right, click `^` if hidden)

### From Source

```bash
git clone https://github.com/tekram/clicky-windows.git
cd clicky-windows
npm install
npm run dev
```

## First Launch

When you first open Clicky, you'll see a chat window with an API key setup panel.

1. **Paste your Anthropic API key** — this is the only required key
2. Click **Save**
3. The setup panel hides and the chat input activates
4. Type a question like *"what app is open on my screen?"* and press Enter

Clicky will capture a screenshot of your display, send it to Claude along with your question, and stream back a response.

## Getting Your API Keys

| Service | What it does | Required? | Free tier | Link |
|---------|-------------|-----------|-----------|------|
| **Anthropic** | AI responses (Claude) | Yes | $5 credit on signup | [console.anthropic.com](https://console.anthropic.com/) |
| **AssemblyAI** | Voice transcription | No | 100 hours free | [assemblyai.com](https://www.assemblyai.com/) |
| **ElevenLabs** | Natural text-to-speech | No | 10,000 chars/month | [elevenlabs.io](https://elevenlabs.io/) |

Without AssemblyAI, you can still type questions. Without ElevenLabs, Clicky falls back to Windows' built-in speech (SAPI) — functional but robotic.

## System Tray

Clicky runs as a tray app. Right-click the gem icon for:

- **Chat** — open/focus the chat window
- **Settings** — full settings panel (providers, model, HIPAA mode)
- **Quit** — exit Clicky

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Enter` | Send message |
| `Ctrl+Alt+Space` | Push-to-talk (when voice is configured) |

## What Happens When You Send a Message

1. Clicky captures a screenshot of all your monitors
2. Your question + screenshot are sent to the Claude API
3. Claude analyzes the screen and responds
4. If Claude references a specific UI element, a blue cursor animates to point at it on your screen
5. If TTS is enabled, the response is spoken aloud

## Next Steps

- [Configure voice and TTS providers](./voice-and-tts.md)
- [Enable HIPAA mode for healthcare use](./hipaa-mode.md)
- [Use a proxy server for team deployments](./proxy-setup.md)
- [Troubleshooting common issues](./troubleshooting.md)
