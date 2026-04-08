# Voice & Text-to-Speech

Clicky supports voice input (speech-to-text) and spoken responses (text-to-speech). Both are optional — you can use Clicky with just text input and silent responses.

## Voice Input (Transcription)

Voice input lets you ask questions by speaking instead of typing. Hold the push-to-talk hotkey, speak, and release.

### Providers

| Provider | Quality | Latency | Privacy | Key Required |
|----------|---------|---------|---------|-------------|
| **AssemblyAI** | Excellent | Low (real-time streaming) | Cloud — audio sent to AssemblyAI | Yes |
| **OpenAI Whisper API** | Excellent | Medium (batch) | Cloud — audio sent to OpenAI | Yes |
| **Whisper Local** | Good | Higher (depends on hardware) | Private — nothing leaves your device | No |

### Setting Up AssemblyAI (Recommended)

1. Sign up at [assemblyai.com](https://www.assemblyai.com/)
2. Copy your API key from the dashboard
3. In Clicky, open Settings (tray > Settings)
4. Paste the key in the **AssemblyAI API Key** field
5. Set **Transcription Provider** to "AssemblyAI"
6. Save

### Using Local Whisper (No Cloud)

Local Whisper runs transcription entirely on your machine. No API key needed, no audio leaves your device.

1. Open Settings
2. Set **Transcription Provider** to "Whisper Local"
3. Save

> Note: Local Whisper is currently in development. Performance depends on your hardware.

### Push-to-Talk

The default hotkey is `Ctrl+Alt+Space`. You can change this in Settings under the hotkey configuration.

1. Press and hold the hotkey
2. Speak your question
3. Release — Clicky transcribes and sends your question with a screenshot

## Text-to-Speech (TTS)

TTS makes Clicky speak its responses aloud.

### Providers

| Provider | Voice Quality | Latency | Privacy | Key Required |
|----------|-------------|---------|---------|-------------|
| **ElevenLabs** | Very natural | Low | Cloud — response text sent to ElevenLabs | Yes |
| **Windows SAPI** | Robotic but clear | Very low | Private — nothing leaves your device | No |

### Setting Up ElevenLabs

1. Sign up at [elevenlabs.io](https://elevenlabs.io/)
2. Go to your profile > API Keys
3. Copy your API key
4. In Clicky Settings, paste it in the **ElevenLabs API Key** field
5. Set **TTS Provider** to "ElevenLabs"
6. Save

The default voice is `kPzsL2i3teMYv0FxEYQ6`. You can change it in the full Settings panel by entering a different ElevenLabs voice ID.

### Using Windows SAPI (No Cloud)

Windows has built-in speech synthesis. It sounds robotic but works instantly with no setup.

1. Open Settings
2. Set **TTS Provider** to "Windows SAPI"
3. Save

### Disabling TTS

Toggle **Spoken responses** off in Settings if you prefer text-only responses.
