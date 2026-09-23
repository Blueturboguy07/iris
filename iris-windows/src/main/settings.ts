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

  /** The model used on the BYO Anthropic route. publik API uses its own
   *  aliases (`services/publik-api.ts`), which are not user-configurable. */
  claudeModel: string;

  /**
   * Which provider the user picked: `publikApi`, `anthropicKey`, `codex`, or
   * "" for "not chosen yet, work it out". An explicit choice is honoured even
   * when another provider would work, and is never silently switched away
   * from — see `services/assistant-transport.ts`'s `selectTransport`.
   */
  providerPreference: string;

  /** This machine's `install_id` for publik API, minted once and replayed. */
  publikInstallId: string;

  /** The claim URL provisioning returned, so the settings card can offer it
   *  long after first run. Not secret: it is a one-time code in a URL the user
   *  is meant to open themselves. */
  publikClaimUrl: string;

  /** Where to send someone who already claimed and wants more credit. */
  publikAddCreditUrl: string;

  /** `anonymous` until this install is linked to a publik account. */
  publikClaimState: string;

  /** The last balance seen, in micros, so the card can render something
   *  truthful before the next metered call updates it. */
  publikBalanceMicros: number;

  /** Whether `publikBalanceMicros` came from the gateway for the key held now.
   *  False until one does, so an unread balance is never shown as "$0.00 left"
   *  and never lights the low-balance warning. */
  publikBalanceSeen: boolean;

  /** The one "Add credit" link the last `GET /balance` named (`top_up_url`):
   *  the claim page while anonymous, the add-credit page once claimed. */
  publikTopUpUrl: string;

  /** The starter the install was granted, for the first-run balance line. */
  publikStarterMicros: number;

  /**
   * Whether the §12 card has been shown. CONTRACT.md section 12 (4) forbids
   * spending the starter before the user has seen the balance, the reason it
   * costs money, and the link — so this gates the first request, not just the
   * UI.
   */
  publikCardHasBeenShown: boolean;

  // UI
  alwaysOnTop: boolean;
  cursorBuddyEnabled: boolean;

  /** The one-time "Let Iris take control of your PC?" grant. Once true, the
   *  autopilot runs a vetted install hands-off (no per-command taps, only the
   *  catastrophe floor in `services/autopilot/risk.ts`), and it is remembered
   *  across every future install until the reader turns it off in settings. */
  autopilotAutonomyGranted: boolean;

  /** The last guide the user opened, so the panel can offer to resume it. */
  lastGuideSlug: string;

  /** False until the first-run flow has been completed once. */
  hasCompletedFirstRun: boolean;

  /** The release tag (e.g. "iris-v0.9.11") the self-update check last
   *  notified about, so a reader who dismisses the notice is not shown it
   *  again every few hours for the same release — only when a newer one
   *  ships. See `main/self-update.ts`. */
  lastAnnouncedUpdateTag: string;
}

const defaults: SettingsSchema = {
  publikBaseUrl: "https://publikhq.com",
  claudeModel: "claude-sonnet-4-5-20250929",
  providerPreference: "",
  publikInstallId: "",
  publikClaimUrl: "",
  publikAddCreditUrl: "",
  publikClaimState: "anonymous",
  publikBalanceMicros: 0,
  publikBalanceSeen: false,
  publikTopUpUrl: "",
  publikStarterMicros: 0,
  publikCardHasBeenShown: false,
  alwaysOnTop: false,
  cursorBuddyEnabled: true,
  autopilotAutonomyGranted: false,
  lastGuideSlug: "",
  hasCompletedFirstRun: false,
  lastAnnouncedUpdateTag: "",
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

  /** The publik API key this install holds — the default chat route. */
  getPublikApiKey(): string | null {
    return readSecret("publikApiKey");
  }

  setPublikApiKey(apiKey: string): boolean {
    if (!apiKey) {
      deleteSecret("publikApiKey");
      return true;
    }
    return writeSecret("publikApiKey", apiKey);
  }

  /** The gateway root, derived from `publikBaseUrl` unless provisioning moved
   *  it. CONTRACT.md section 1 [S8]: the response wins over the default. */
  getPublikApiBaseUrl(): string {
    const base = this.get("publikBaseUrl").replace(/\/+$/, "");
    return `${base}/api/v1`;
  }

  getSupabaseRefreshToken(): string | null {
    return readSecret("supabaseRefreshToken");
  }

  setSupabaseRefreshToken(refreshToken: string | null): void {
    if (refreshToken) writeSecret("supabaseRefreshToken", refreshToken);
    else deleteSecret("supabaseRefreshToken");
  }

  /**
   * True when Iris has some way to reach a model. Signing in is no longer one
   * of them: the funded tier is gone, so a publik account by itself buys
   * nothing until this install has a publik API key of its own.
   */
  isConfigured(codexIsAvailable = false): boolean {
    return (
      Boolean(this.getPublikApiKey()) || Boolean(this.getAnthropicApiKey()) || codexIsAvailable
    );
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
