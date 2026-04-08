import Store from "electron-store";

interface SettingsSchema {
  // API Keys (BYOK)
  anthropicApiKey: string;
  assemblyaiApiKey: string;
  elevenlabsApiKey: string;

  // Optional proxy (for non-BYOK / org deployments)
  proxyUrl: string;
  useProxy: boolean;

  // Transcription
  transcriptionProvider: "assemblyai" | "openai" | "whisper-local";

  // TTS
  ttsEnabled: boolean;
  ttsProvider: "elevenlabs" | "local";
  elevenlabsVoiceId: string;

  // Hotkey
  pushToTalkHotkey: string;

  // Model
  claudeModel: string;

  // HIPAA
  hipaaMode: boolean;
}

const defaults: SettingsSchema = {
  anthropicApiKey: "",
  assemblyaiApiKey: "",
  elevenlabsApiKey: "",
  proxyUrl: "",
  useProxy: false,
  transcriptionProvider: "assemblyai",
  ttsEnabled: true,
  ttsProvider: "elevenlabs",
  elevenlabsVoiceId: "kPzsL2i3teMYv0FxEYQ6",
  pushToTalkHotkey: "Ctrl+Alt",
  claudeModel: "claude-sonnet-4-6-20250514",
  hipaaMode: false,
};

export class SettingsStore {
  private store: Store<SettingsSchema>;

  constructor() {
    this.store = new Store<SettingsSchema>({
      defaults,
      encryptionKey: "clicky-windows-settings",
    });
  }

  get<K extends keyof SettingsSchema>(
    key: K,
    fallback?: SettingsSchema[K]
  ): SettingsSchema[K] {
    return this.store.get(key, fallback);
  }

  set<K extends keyof SettingsSchema>(
    key: K,
    value: SettingsSchema[K]
  ): void {
    this.store.set(key, value);
  }

  getAll(): SettingsSchema {
    return this.store.store;
  }

  /**
   * Check if minimum required keys are configured for operation.
   */
  isConfigured(): boolean {
    if (this.get("useProxy") && this.get("proxyUrl")) {
      return true;
    }
    return !!this.get("anthropicApiKey");
  }

  /**
   * In HIPAA mode, enforce local-only processing.
   */
  isHipaaMode(): boolean {
    return this.get("hipaaMode");
  }
}
