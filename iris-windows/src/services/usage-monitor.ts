/**
 * Anonymous usage counts — the Windows half of `UsageMonitor.swift`.
 *
 * Founder, 2026-09-25: "depersonalize the tracking, make it optional, prompt
 * them when they open it, default toggled on, must not break anything in Iris,
 * nothing should wait for it."
 *
 * WHAT AN EVENT CAN HOLD. A catalog slug, one of five event kinds, a provider
 * and a tier as enum values, the OS family, the Iris version, and the HOUR it
 * happened in. There is no field for a message, a window title, a path, a
 * model name or an account, so no call site can pass one by accident. The
 * server (`lib/iris-usage-events.ts` in publik) refuses any other field and
 * drops a slug its catalog does not list.
 *
 * NOTHING WAITS FOR IT. `record` updates an in-memory count and returns. A
 * timer sends one batch at most every 60 seconds; a send is never awaited by
 * anything, and ANY failure — offline, a 4xx, a 5xx, a timeout, a throw —
 * drops the batch. Nothing is retried and nothing is written to disk.
 *
 * OFF MEANS OFF. The switch is read at record time and again at send time.
 * With it off nothing is recorded and whatever was held is thrown away.
 *
 * Pure: the clock, the switch, the install id and the network are injected,
 * so the whole thing runs in vitest.
 */

export const USAGE_EVENT_KINDS = [
  "app_opened",
  "ai_call",
  "model_selected",
  "guide_started",
  "guide_completed",
] as const;
export type UsageEventKind = (typeof USAGE_EVENT_KINDS)[number];

/** Which route answered. Same wire values as macOS and the server. */
export type UsageProvider = "publik-api" | "anthropic-key" | "codex";

/** publik's three tiers. */
export type UsageModelTier = "fast" | "balanced" | "smart";

export interface UsageEvent {
  kind: UsageEventKind;
  appSlug?: string | null;
  provider?: UsageProvider | null;
  modelTier?: UsageModelTier | null;
}

/** The server's cap on one row (`MAX_COUNT_PER_EVENT`). */
export const LARGEST_COUNT_THE_SERVER_ACCEPTS = 500;
/** The server's batch cap (`MAX_USAGE_EVENTS_PER_BATCH`). */
export const LARGEST_BATCH_THE_SERVER_ACCEPTS = 50;
/** Distinct (event, hour) counts held between sends; anything new past this is dropped. */
export const MAXIMUM_DISTINCT_COUNTS_HELD = 200;
/** At most one send per this long. */
export const USAGE_FLUSH_INTERVAL_MS = 60_000;

const SLUG_PATTERN = /^[a-z0-9]+(?:[a-z0-9-]{0,62}[a-z0-9])?$/;

/** The server's slug rule (`apps.slug`). */
export function isSlugShaped(candidate: string): boolean {
  return SLUG_PATTERN.test(candidate);
}

/**
 * The same coarse mapping the gateway alias uses on macOS
 * (`PublikAPIModelAlias`): haiku → fast, opus → smart, anything else →
 * balanced.
 */
export function modelTierForModelName(modelName: string): UsageModelTier {
  const lowercasedName = modelName.toLowerCase();
  if (lowercasedName.includes("haiku")) return "fast";
  if (lowercasedName.includes("opus")) return "smart";
  return "balanced";
}

/** A transport tier (`services/assistant-transport.ts`) → the wire enum. */
export function usageProviderForTransportTier(tier: "publik" | "byo" | "codex"): UsageProvider {
  if (tier === "publik") return "publik-api";
  if (tier === "byo") return "anthropic-key";
  return "codex";
}

/** The hour an event happened in, UTC: "2026-09-25T14:00:00Z". */
export function hourBucket(date: Date): string {
  const truncated = new Date(date.getTime());
  truncated.setUTCMinutes(0, 0, 0);
  return truncated.toISOString().replace(".000Z", "Z");
}

/** "0.9" → "0.9.0", "0.9.15" → itself, "1.2.3.4" → "1.2.3", "dev" → null. */
export function threePartVersion(version: string): string | null {
  const parts = version.split(".");
  if (parts.length === 0 || !parts.every((part) => /^\d{1,4}$/.test(part))) return null;
  return [...parts, "0", "0", "0"].slice(0, 3).join(".");
}

export interface UsageMonitorOptions {
  isSharingEnabled: () => boolean;
  installIdentifier: () => string;
  irisVersion: string;
  operatingSystem: "windows" | "macos";
  /** Resolves true when the server accepted the batch. Never awaited by a caller of `record`. */
  sendBatch: (jsonBody: string) => Promise<boolean>;
  /** The switch was turned off: ask the server to forget this install's counts. */
  eraseEverythingSent: (installIdentifier: string) => void;
  now?: () => Date;
  maximumDistinctCountsHeld?: number;
}

interface HeldCount {
  event: UsageEvent;
  hourBucket: string;
  count: number;
}

export class UsageMonitor {
  private readonly options: UsageMonitorOptions;
  private readonly now: () => Date;
  private readonly maximumDistinctCountsHeld: number;
  /** Insertion-ordered, so a batch goes oldest-first and a truncated one drops the newest. */
  private readonly heldCounts = new Map<string, HeldCount>();
  private aSendIsInFlight = false;
  private droppedEventCount = 0;
  private flushTimer: ReturnType<typeof setInterval> | undefined;

  constructor(options: UsageMonitorOptions) {
    this.options = options;
    this.now = options.now ?? (() => new Date());
    this.maximumDistinctCountsHeld = options.maximumDistinctCountsHeld ?? MAXIMUM_DISTINCT_COUNTS_HELD;
  }

  /** Counts one event. Synchronous, O(1), never throws. */
  record(event: UsageEvent): void {
    try {
      if (!this.options.isSharingEnabled()) {
        this.throwAwayEverythingHeld();
        return;
      }
      const appSlug = event.appSlug && isSlugShaped(event.appSlug) ? event.appSlug : null;
      const normalizedEvent: UsageEvent = {
        kind: event.kind,
        appSlug,
        provider: event.provider ?? null,
        modelTier: event.modelTier ?? null,
      };
      const bucket = hourBucket(this.now());
      const key = [normalizedEvent.kind, appSlug ?? "", normalizedEvent.provider ?? "", normalizedEvent.modelTier ?? "", bucket].join("|");
      const existing = this.heldCounts.get(key);
      if (existing) {
        existing.count = Math.min(existing.count + 1, LARGEST_COUNT_THE_SERVER_ACCEPTS);
        return;
      }
      if (this.heldCounts.size >= this.maximumDistinctCountsHeld) {
        this.droppedEventCount += 1;
        return;
      }
      this.heldCounts.set(key, { event: normalizedEvent, hourBucket: bucket, count: 1 });
    } catch {
      // Counting is never allowed to break the thing being counted.
    }
  }

  /** Starts the once-a-minute send. Safe to call more than once. */
  start(intervalMs: number = USAGE_FLUSH_INTERVAL_MS): void {
    if (this.flushTimer !== undefined) return;
    this.flushTimer = setInterval(() => this.sendWhatIsHeld(), intervalMs);
    // A pending usage send must never keep the process alive on quit.
    this.flushTimer.unref?.();
  }

  stop(): void {
    if (this.flushTimer !== undefined) clearInterval(this.flushTimer);
    this.flushTimer = undefined;
  }

  /** The switch was turned off. */
  sharingWasTurnedOff(): void {
    this.throwAwayEverythingHeld();
    try {
      this.options.eraseEverythingSent(this.options.installIdentifier());
    } catch {
      // Best effort, like every send.
    }
  }

  /**
   * One tick. Fire-and-forget: returns the in-flight promise only so tests can
   * wait for it; production never awaits it.
   */
  sendWhatIsHeld(): Promise<void> {
    if (!this.options.isSharingEnabled()) {
      this.throwAwayEverythingHeld();
      return Promise.resolve();
    }
    if (this.aSendIsInFlight || this.heldCounts.size === 0) return Promise.resolve();
    const irisVersion = threePartVersion(this.options.irisVersion);
    if (irisVersion === null) {
      this.throwAwayEverythingHeld();
      return Promise.resolve();
    }

    const everythingHeld = [...this.heldCounts.values()];
    const batch = everythingHeld.slice(0, LARGEST_BATCH_THE_SERVER_ACCEPTS);
    // Whatever did not fit is dropped with it: the next minute starts from
    // nothing rather than growing a backlog.
    this.droppedEventCount += everythingHeld.length - batch.length;
    this.heldCounts.clear();

    const events = batch.map((held) => {
      const entry: Record<string, unknown> = {
        event: held.event.kind,
        os: this.options.operatingSystem,
        irisVersion,
        hourBucket: held.hourBucket,
        count: held.count,
      };
      if (held.event.appSlug) entry.appSlug = held.event.appSlug;
      if (held.event.provider) entry.provider = held.event.provider;
      if (held.event.modelTier) entry.modelTier = held.event.modelTier;
      return entry;
    });

    let jsonBody: string;
    try {
      jsonBody = JSON.stringify({ installId: this.options.installIdentifier(), events });
    } catch {
      return Promise.resolve();
    }

    this.aSendIsInFlight = true;
    return this.options
      .sendBatch(jsonBody)
      .catch(() => false)
      .then(() => {
        // Accepted or not, the batch is gone. See the file note.
        this.aSendIsInFlight = false;
      });
  }

  private throwAwayEverythingHeld(): void {
    for (const held of this.heldCounts.values()) this.droppedEventCount += held.count;
    this.heldCounts.clear();
  }

  // For tests.
  heldCountsForTesting(): Array<{ event: UsageEvent; hourBucket: string; count: number }> {
    return [...this.heldCounts.values()].map((held) => ({ ...held }));
  }
  droppedEventCountForTesting(): number {
    return this.droppedEventCount;
  }
  sendIsInFlightForTesting(): boolean {
    return this.aSendIsInFlight;
  }
}

type FetchLike = (
  input: string,
  init?: { method?: string; headers?: Record<string, string>; body?: string; signal?: AbortSignal }
) => Promise<{ ok: boolean }>;

/**
 * The real sender: `POST {publik}/api/telemetry/usage`, no credential of any
 * kind (a usage count has no account), a 10 s timeout, and `false` for any
 * failure instead of a throw.
 */
export function makeUsageSender(publikBaseUrl: string, fetchImplementation: FetchLike): {
  sendBatch: (jsonBody: string) => Promise<boolean>;
  eraseEverythingSent: (installIdentifier: string) => void;
} {
  const endpoint = `${publikBaseUrl.replace(/\/+$/, "")}/api/telemetry/usage`;
  return {
    async sendBatch(jsonBody: string): Promise<boolean> {
      const abort = new AbortController();
      const timeout = setTimeout(() => abort.abort(), 10_000);
      try {
        const response = await fetchImplementation(endpoint, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: jsonBody,
          signal: abort.signal,
        });
        return response.ok;
      } catch {
        return false;
      } finally {
        clearTimeout(timeout);
      }
    },
    eraseEverythingSent(installIdentifier: string): void {
      void fetchImplementation(`${endpoint}?install_id=${encodeURIComponent(installIdentifier)}`, {
        method: "DELETE",
      }).catch(() => undefined);
    },
  };
}
