# PLAN: Push-to-Talk Voice Input

## Status: Ready
## Priority: High
## Effort: Medium

---

## Overview

Wire up the full push-to-talk pipeline: global hotkey → mic capture → transcription → screenshot → AI query → response. The hotkey detection and IPC scaffolding exist but the renderer-side mic capture (Web Audio API) is not built yet.

Currently the only way to interact is typing in the chat. This adds hands-free voice input from any screen.

## Current State

What exists:
- `src/main/hotkey.ts` — global hotkey registration (`Ctrl+Alt+Space`), emits `hotkey:recording-changed` IPC
- `src/main/audio.ts` — stub, listens for `audio:transcript-ready` IPC
- `src/preload/index.ts` — `onRecordingChanged` exposed to renderer
- `src/renderer/overlay/index.html` — recording indicator UI (red dot + "Listening...")
- `src/services/transcription/` — AssemblyAI (streaming), OpenAI Whisper (batch), Whisper local (stub)

What's missing:
- Renderer-side mic capture via `getUserMedia` + `AudioWorklet`
- Audio chunk streaming to main process via IPC
- Main process forwarding chunks to transcription provider
- Transcript → `processQuery()` pipeline
- Recording state management (prevent double-press, handle errors)

## Architecture

```
User presses Ctrl+Alt+Space
  │
  ├─ Main: HotkeyManager detects keydown
  │   └─ Sends 'hotkey:recording-changed' (true) to renderer
  │
  ├─ Renderer (chat or overlay):
  │   ├─ Calls navigator.mediaDevices.getUserMedia({ audio: true })
  │   ├─ Creates AudioWorklet to extract PCM16 chunks
  │   └─ Sends chunks to main via IPC: 'audio:chunk'
  │
  ├─ Main: AudioCapture receives chunks
  │   ├─ If streaming provider (AssemblyAI): forward chunks in real-time
  │   └─ If batch provider (OpenAI Whisper): buffer chunks
  │
User releases Ctrl+Alt+Space
  │
  ├─ Main: HotkeyManager detects keyup
  │   └─ Sends 'hotkey:recording-changed' (false) to renderer
  │
  ├─ Renderer: stops mic, stops sending chunks
  │
  ├─ Main: AudioCapture signals transcription provider to stop
  │   └─ Gets final transcript
  │
  ├─ Main: CompanionManager.processQuery(transcript)
  │   ├─ Captures screenshot (at release, per PLAN-screenshot-timing)
  │   ├─ Sends to AI provider
  │   ├─ Speaks response (if TTS enabled)
  │   └─ Sends POINT tags to overlay
  │
  └─ Renderer: shows transcript + response in chat window
```

## Tasks

### Phase 1: Basic Push-to-Talk (OpenAI Whisper batch)
- [ ] Create `src/renderer/audio-capture.js` — getUserMedia + AudioWorklet for PCM16
- [ ] Add IPC: renderer sends `audio:chunk` (Buffer) to main on each audio frame
- [ ] Add IPC: renderer sends `audio:recording-stopped` when key released
- [ ] Update `src/main/audio.ts` — collect chunks, on stop → send to transcription provider
- [ ] Wire transcript result → `CompanionManager.processQuery()`
- [ ] Send response back to chat renderer via IPC `chat:response`
- [ ] Show transcript in chat as user message
- [ ] Show "recording..." state in chat UI (not just overlay)
- [ ] Handle mic permission denial gracefully

### Phase 2: Streaming Transcription (AssemblyAI)
- [ ] On recording start, open AssemblyAI WebSocket
- [ ] Stream audio chunks in real-time
- [ ] Show partial transcript in chat UI as user speaks
- [ ] On stop, get final transcript and query AI

### Phase 3: Polish
- [ ] Visual recording indicator in chat (pulsing border or mic icon)
- [ ] Audio level meter (show that mic is picking up sound)
- [ ] Configurable hotkey (already in settings, needs UI wiring)
- [ ] Error handling: mic in use by another app, no mic detected
- [ ] Cancel recording: press Escape while recording to abort

## Hotkey Approach

Current `globalShortcut.register` doesn't support separate press/release detection. Options:

**Option A: `globalShortcut` with toggle**
- First press starts recording, second press stops
- Simpler but less intuitive than hold-to-talk

**Option B: Low-level keyboard hook via native module**
- Detect actual keydown/keyup for true hold-to-talk
- Needs `node-global-key-listener` or similar package
- More natural UX

**Option C: `iohook` or `uiohook-napi`**
- Mature packages for global key/mouse events
- Supports keydown + keyup
- May need rebuild for Electron version

**Recommended: Option A first** (toggle, works immediately), then migrate to **Option B/C** for hold-to-talk UX.

## Files to Create/Modify

| File | Action |
|------|--------|
| `src/renderer/audio-capture.js` | **Create** — mic capture via Web Audio API |
| `src/renderer/audio-worklet.js` | **Create** — AudioWorklet processor for PCM16 extraction |
| `src/main/audio.ts` | **Rewrite** — chunk collection, transcription coordination |
| `src/main/hotkey.ts` | **Update** — toggle mode, emit start/stop events |
| `src/main/companion.ts` | **Update** — accept voice queries, show in chat |
| `src/main/index.ts` | **Update** — new IPC handlers for audio chunks |
| `src/preload/index.ts` | **Update** — expose audio chunk sending |
| `src/renderer/chat/index.html` | **Update** — recording state UI, transcript display |

## Dependencies

- None for Phase 1 (Web Audio API is built into Electron/Chromium)
- `node-global-key-listener` or `uiohook-napi` for hold-to-talk (Phase 3)

## Risks

- Mic permission: Electron on Windows usually auto-grants but some builds don't
- Audio format mismatch: OpenAI Whisper needs WAV, AssemblyAI needs raw PCM base64
- Latency: getUserMedia → IPC → transcription → AI adds up. Target < 3 sec total for short utterances
- Global hotkey conflicts with other apps

## Notes

- Per PLAN-screenshot-timing, capture screenshot at recording stop (key release), not start
- OpenAI Whisper is the simplest first target since it's batch (send all audio at once)
- AssemblyAI streaming is better UX but more complex (WebSocket lifecycle)
