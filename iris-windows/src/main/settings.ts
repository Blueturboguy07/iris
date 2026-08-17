import { app } from "electron";
import * as fs from "node:fs";
import * as path from "node:path";
import {
  LEGACY_PLAINTEXT_KEY_NAMES,
  deleteSecret,
  readSecret,
  writeSecret,
} from "./secrets";

/**
 * Everything Iris remembers between launches — and nothing secret. Secrets live
 * in `secrets.ts` behind `safeStorage`; this file is plain JSON and is safe to
 * paste into a bug report.
 */
export interface SettingsSchema {
  /** Where publik lives. Overridable for local development only. */
  publikBaseUrl: string;

  /** The model used on the BYO route. The funded route pins its own. */
  claudeModel: string;

  // UI
  alwaysOnTop: boolean;
  cursorBuddyEnabled: boolean;

  /** The last guide the user opened, so the panel can offer to resume it. */
  lastGuideSlug: string;
}

const defaults: SettingsSchema = {
  publikBaseUrl: "https://publikhq.com",
  claudeModel: "claude-sonnet-4-5-20250929",
  alwaysOnTop: false,
  cursorBuddyEnabled: true,
  lastGuideSlug: "",
};

/**
 * Simple JSON file settings store. Avoids electron-store's ESM issues, and keeps
 * the file readable so a user can see exactly what Iris remembers.
 */
export class SettingsStore {
  private data: SettingsSchema;
  private filePath: string;

  constructor() {
    const userDataPath = app.isReady()
      ? app.getPath("userData")
      : path.join(process.env.APPDATA || process.env.HOME || ".", "iris");

    this.filePath = path.join(userDataPath, "settings.json");
    this.data = { ...defaults };

    let rawParsed: Record<string, unknown> = {};
    try {
      if (fs.existsSync(this.filePath)) {
        rawParsed = JSON.parse(fs.readFileSync(this.filePath, "utf-8")) as Record<string, unknown>;
        this.data = { ...defaults, ...(rawParsed as Partial<SettingsSchema>) };
      }
    } catch {
      // Use defaults on any read error.
    }

    this.migrateLegacyPlaintextSecrets(rawParsed);
  }

  /**
   * A pre-fork install has API keys sitting in settings.json in the clear. Move
   * the one Iris still uses into safeStorage and drop the rest, so upgrading
   * actually improves the user's position instead of leaving a plaintext key on
   * disk forever.
   */
  private migrateLegacyPlaintextSecrets(rawParsed: Record<string, unknown>): void {
    let foundAnythingToRewrite = false;

    for (const legacyKeyName of LEGACY_PLAINTEXT_KEY_NAMES) {
      const legacyValue = rawParsed[legacyKeyName];
      if (typeof legacyValue !== "string" || legacyValue.length === 0) continue;
      if (legacyKeyName === "anthropicApiKey" && !readSecret("anthropicApiKey")) {
        writeSecret("anthropicApiKey", legacyValue);
      }
      foundAnythingToRewrite = true;
    }

    // Also drop settings this fork no longer honours, so a stale
    // `aiProvider: "openai"` cannot be mistaken for a live option.
    for (const storedKeyName of Object.keys(rawParsed)) {
      if (!(storedKeyName in defaults)) foundAnythingToRewrite = true;
    }

    // `this.data` was built from `defaults` plus known keys only, so saving it
    // is what actually removes the legacy fields from the file.
    if (foundAnythingToRewrite) this.save();
  }

  get<K extends keyof SettingsSchema>(key: K): SettingsSchema[K] {
    const value = this.data[key];
    return value === undefined ? defaults[key] : value;
  }

  set<K extends keyof SettingsSchema>(key: K, value: SettingsSchema[K]): void {
    this.data[key] = value;
    this.save();
  }

  getAll(): SettingsSchema {
    return { ...this.data };
  }

  // MARK: - Secrets (never stored in this file)

  getAnthropicApiKey(): string | null {
    return readSecret("anthropicApiKey");
  }

  setAnthropicApiKey(apiKey: string): boolean {
    if (!apiKey) {
      deleteSecret("anthropicApiKey");
      return true;
    }
    return writeSecret("anthropicApiKey", apiKey);
  }

  /** Maintain mode's Tier C BYO fixer key, distinct from the Anthropic key
   *  above — see `secrets.ts`'s header and `main/maintain/controller.ts`.
   *  Never read by the companion chat, which stays Anthropic-only. */
  getOpenAiApiKey(): string | null {
    return readSecret("openaiApiKey");
  }

  setOpenAiApiKey(apiKey: string): boolean {
    if (!apiKey) {
      deleteSecret("openaiApiKey");
      return true;
    }
    return writeSecret("openaiApiKey", apiKey);
  }

  getSupabaseRefreshToken(): string | null {
    return readSecret("supabaseRefreshToken");
  }

  setSupabaseRefreshToken(refreshToken: string | null): void {
    if (refreshToken) writeSecret("supabaseRefreshToken", refreshToken);
    else deleteSecret("supabaseRefreshToken");
  }

  /** True when Iris has some way to reach a model — either tier. */
  isConfigured(isSignedIn: boolean): boolean {
    return isSignedIn || Boolean(this.getAnthropicApiKey());
  }

  private save(): void {
    try {
      fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
      fs.writeFileSync(this.filePath, JSON.stringify(this.data, null, 2));
    } catch {
      // Silent fail on write error — a settings write is never worth a crash.
    }
  }
}
