import { describe, expect, it } from "vitest";
import {
  LARGEST_BATCH_THE_SERVER_ACCEPTS,
  LARGEST_COUNT_THE_SERVER_ACCEPTS,
  UsageMonitor,
  hourBucket,
  isSlugShaped,
  makeUsageSender,
  modelTierForModelName,
  threePartVersion,
} from "../src/services/usage-monitor";

/**
 * The anonymous usage monitor's promises, each pinned — the same ones
 * `UsageMonitorTests.swift` holds the macOS side to: it counts rather than
 * logs, it sends at most one batch per tick, it drops a batch on ANY failure
 * instead of retrying or storing it, a send never blocks recording, and with
 * the switch off it holds and sends nothing.
 */

const INSTALL_ID = "3f1b2c4d-1111-2222-3333-abcdefabcdef";
const A_MOMENT_ON_THE_TWENTY_FIFTH = new Date("2026-09-25T14:37:12Z");

function makeMonitor(options: {
  sharing?: { on: boolean };
  now?: { value: Date };
  irisVersion?: string;
  sendBatch?: (body: string) => Promise<boolean>;
  maximumDistinctCountsHeld?: number;
} = {}) {
  const sent: string[] = [];
  const erased: string[] = [];
  const sharing = options.sharing ?? { on: true };
  const now = options.now ?? { value: A_MOMENT_ON_THE_TWENTY_FIFTH };
  const monitor = new UsageMonitor({
    isSharingEnabled: () => sharing.on,
    installIdentifier: () => INSTALL_ID,
    irisVersion: options.irisVersion ?? "0.9.15",
    operatingSystem: "windows",
    sendBatch:
      options.sendBatch ??
      (async (body) => {
        sent.push(body);
        return true;
      }),
    eraseEverythingSent: (installIdentifier) => erased.push(installIdentifier),
    now: () => now.value,
    maximumDistinctCountsHeld: options.maximumDistinctCountsHeld,
  });
  return { monitor, sent, erased, sharing, now };
}

function eventsIn(body: string): Array<Record<string, unknown>> {
  const parsed = JSON.parse(body) as { installId: string; events: Array<Record<string, unknown>> };
  expect(parsed.installId).toBe(INSTALL_ID);
  return parsed.events;
}

describe("counting and batching", () => {
  it("turns repeats in the same hour into one counted entry", async () => {
    const { monitor, sent } = makeMonitor();
    for (let index = 0; index < 3; index += 1) monitor.record({ kind: "app_opened", appSlug: "cue" });
    monitor.record({ kind: "ai_call", provider: "anthropic-key", modelTier: "smart" });
    await monitor.sendWhatIsHeld();

    expect(sent).toHaveLength(1);
    const events = eventsIn(sent[0]);
    expect(events).toHaveLength(2);
    expect(events[0]).toEqual({ event: "app_opened", appSlug: "cue", os: "windows", irisVersion: "0.9.15", hourBucket: "2026-09-25T14:00:00Z", count: 3 });
    expect(events[1]).toMatchObject({ event: "ai_call", provider: "anthropic-key", modelTier: "smart", count: 1 });
  });

  it("counts a new hour separately", async () => {
    const { monitor, sent, now } = makeMonitor();
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    now.value = new Date("2026-09-25T15:02:00Z");
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    expect(eventsIn(sent[0]).map((event) => event.hourBucket)).toEqual(["2026-09-25T14:00:00Z", "2026-09-25T15:00:00Z"]);
  });

  it("never sends by itself, and an empty tick sends nothing", async () => {
    const { monitor, sent } = makeMonitor();
    await monitor.sendWhatIsHeld();
    expect(sent).toEqual([]);
    monitor.record({ kind: "guide_started", appSlug: "cue" });
    expect(sent).toEqual([]);
    await monitor.sendWhatIsHeld();
    expect(sent).toHaveLength(1);
  });

  it("carries only the fields the server allows", async () => {
    const { monitor, sent } = makeMonitor();
    monitor.record({ kind: "ai_call", appSlug: "cue", provider: "publik-api", modelTier: "balanced" });
    await monitor.sendWhatIsHeld();
    const allowed = new Set(["event", "appSlug", "provider", "modelTier", "os", "irisVersion", "hourBucket", "count"]);
    for (const event of eventsIn(sent[0])) {
      for (const key of Object.keys(event)) expect(allowed.has(key)).toBe(true);
    }
  });

  it("never sends a slug that is not slug-shaped", async () => {
    expect(isSlugShaped("Inbox — someone@example.com")).toBe(false);
    expect(isSlugShaped("C:\\Users\\someone\\secret")).toBe(false);
    const { monitor, sent } = makeMonitor();
    monitor.record({ kind: "ai_call", appSlug: "My Private Repo", provider: "codex" });
    await monitor.sendWhatIsHeld();
    expect(eventsIn(sent[0])[0].appSlug).toBeUndefined();
  });
});

describe("dropping", () => {
  it("drops a failed batch — no retry, no backlog", async () => {
    let attempts = 0;
    const { monitor } = makeMonitor({
      sendBatch: async () => {
        attempts += 1;
        return false;
      },
    });
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    await monitor.sendWhatIsHeld();
    expect(attempts).toBe(1);
    expect(monitor.heldCountsForTesting()).toEqual([]);
  });

  it("drops a batch whose send throws, and keeps working", async () => {
    let calls = 0;
    const { monitor } = makeMonitor({
      sendBatch: async () => {
        calls += 1;
        throw new Error("offline");
      },
    });
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    expect(monitor.sendIsInFlightForTesting()).toBe(false);
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    expect(calls).toBe(2);
  });

  it("keeps recording while a send is in flight, and does not stack a second send", async () => {
    let finishTheSend: (accepted: boolean) => void = () => {};
    let calls = 0;
    const { monitor } = makeMonitor({
      sendBatch: () => {
        calls += 1;
        return new Promise<boolean>((resolve) => {
          finishTheSend = resolve;
        });
      },
    });
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    const inFlight = monitor.sendWhatIsHeld();
    expect(monitor.sendIsInFlightForTesting()).toBe(true);

    monitor.record({ kind: "app_opened", appSlug: "whimprflow" });
    expect(monitor.heldCountsForTesting()).toHaveLength(1);
    await monitor.sendWhatIsHeld();
    expect(calls).toBe(1);

    finishTheSend(false);
    await inFlight;
    // Not awaited: this send is left hanging on purpose, like a slow network.
    void monitor.sendWhatIsHeld();
    expect(calls).toBe(2);
    finishTheSend(true);
  });

  it("drops new entries past the holding cap but still counts existing ones up", () => {
    const { monitor } = makeMonitor({ maximumDistinctCountsHeld: 2 });
    monitor.record({ kind: "app_opened", appSlug: "one" });
    monitor.record({ kind: "app_opened", appSlug: "two" });
    monitor.record({ kind: "app_opened", appSlug: "three" });
    monitor.record({ kind: "app_opened", appSlug: "one" });
    const held = monitor.heldCountsForTesting();
    expect(held).toHaveLength(2);
    expect(held[0].count).toBe(2);
    expect(monitor.droppedEventCountForTesting()).toBe(1);
  });

  it("never exceeds the server's batch cap and drops the overflow", async () => {
    const { monitor, sent } = makeMonitor();
    for (let index = 0; index < LARGEST_BATCH_THE_SERVER_ACCEPTS + 5; index += 1) {
      monitor.record({ kind: "app_opened", appSlug: `app-${index}` });
    }
    await monitor.sendWhatIsHeld();
    expect(eventsIn(sent[0])).toHaveLength(LARGEST_BATCH_THE_SERVER_ACCEPTS);
    await monitor.sendWhatIsHeld();
    expect(sent).toHaveLength(1);
  });

  it("stops a count at what the server accepts", async () => {
    const { monitor, sent } = makeMonitor();
    for (let index = 0; index < LARGEST_COUNT_THE_SERVER_ACCEPTS + 10; index += 1) {
      monitor.record({ kind: "app_opened", appSlug: "cue" });
    }
    await monitor.sendWhatIsHeld();
    expect(eventsIn(sent[0])[0].count).toBe(LARGEST_COUNT_THE_SERVER_ACCEPTS);
  });
});

describe("off means off", () => {
  it("holds and sends nothing with the switch off", async () => {
    const { monitor, sent } = makeMonitor({ sharing: { on: false } });
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    expect(monitor.heldCountsForTesting()).toEqual([]);
    expect(sent).toEqual([]);
  });

  it("throws away what is held and asks the server to forget when turned off", async () => {
    const { monitor, sent, erased, sharing } = makeMonitor();
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    sharing.on = false;
    monitor.sharingWasTurnedOff();
    await monitor.sendWhatIsHeld();
    expect(sent).toEqual([]);
    expect(erased).toEqual([INSTALL_ID]);
  });

  it("sends nothing when the version cannot be read, since the server would refuse it", async () => {
    const { monitor, sent } = makeMonitor({ irisVersion: "local build" });
    monitor.record({ kind: "app_opened", appSlug: "cue" });
    await monitor.sendWhatIsHeld();
    expect(sent).toEqual([]);
  });
});

describe("wire helpers", () => {
  it("buckets by the UTC hour", () => {
    expect(hourBucket(A_MOMENT_ON_THE_TWENTY_FIFTH)).toBe("2026-09-25T14:00:00Z");
  });

  it("always sends three numbers as the version, or nothing", () => {
    expect(threePartVersion("0.9.15")).toBe("0.9.15");
    expect(threePartVersion("0.9")).toBe("0.9.0");
    expect(threePartVersion("1.2.3.4")).toBe("1.2.3");
    expect(threePartVersion("dev")).toBeNull();
  });

  it("maps a model to a tier the way the gateway alias does", () => {
    expect(modelTierForModelName("claude-haiku-4-5-20251001")).toBe("fast");
    expect(modelTierForModelName("claude-sonnet-4-5-20250929")).toBe("balanced");
    expect(modelTierForModelName("claude-opus-4-1-20250805")).toBe("smart");
  });

  it("the real sender posts JSON with no credential and turns every failure into false", async () => {
    const requests: Array<{ url: string; init?: { method?: string; headers?: Record<string, string>; body?: string } }> = [];
    const sender = makeUsageSender("https://publikhq.com/", async (url, init) => {
      requests.push({ url, init });
      if (init?.method === "DELETE") return { ok: true };
      return { ok: false };
    });
    expect(await sender.sendBatch('{"installId":"x","events":[]}')).toBe(false);
    expect(requests[0].url).toBe("https://publikhq.com/api/telemetry/usage");
    expect(requests[0].init?.method).toBe("POST");
    expect(Object.keys(requests[0].init?.headers ?? {})).toEqual(["Content-Type"]);

    sender.eraseEverythingSent(INSTALL_ID);
    expect(requests[1].url).toBe(`https://publikhq.com/api/telemetry/usage?install_id=${INSTALL_ID}`);

    const throwing = makeUsageSender("https://publikhq.com", async () => {
      throw new Error("offline");
    });
    expect(await throwing.sendBatch("{}")).toBe(false);
  });
});
