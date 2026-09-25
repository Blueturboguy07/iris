import { readFileSync } from "node:fs";
import { join } from "node:path";
import { JSDOM } from "jsdom";
import { afterEach, describe, expect, it } from "vitest";

/**
 * The usage disclosure, the price comparison and the nudge card, driven in the
 * shipped settings and chat windows — the same jsdom harness as
 * settings-renderer.test.ts, with a fake `window.iris` standing in for the
 * preload bridge (src/preload/index.ts).
 */

interface FakeUsageView {
  state: "notYetDisclosed" | "sharing" | "notSharing";
  showDisclosure: boolean;
}

const LOADED_PRICES = {
  state: "loaded",
  assumption: "Assumes 300 questions a month.",
  caveat: "A different model answers on each route.",
  options: [
    { provider: "publik-api", label: "publik API", model: "publik-balanced", servedBy: "xiaomi/mimo-v2.6-pro", billing: "per_token", inputUsdPerMillion: 2, outputUsdPerMillion: 12, estimatedCostPerQuestionUsd: 0.0136, estimatedMonthlyUsd: 4.08, note: "Prepaid balance.", source: "publik's published tier price" },
    { provider: "anthropic-key", label: "Your own Anthropic key", model: "claude-sonnet-4-5", servedBy: null, billing: "per_token", inputUsdPerMillion: 3, outputUsdPerMillion: 15, estimatedCostPerQuestionUsd: 0.0195, estimatedMonthlyUsd: 5.85, note: "Billed by Anthropic.", source: "Anthropic's list price" },
    { provider: "codex", label: "Your ChatGPT plan (Codex)", model: "your codex CLI's model", servedBy: null, billing: "subscription", inputUsdPerMillion: null, outputUsdPerMillion: null, estimatedCostPerQuestionUsd: null, estimatedMonthlyUsd: 8, note: "Flat monthly plan.", source: "OpenAI's ChatGPT plans page" },
  ],
};

const A_NUDGE = { decisionPoint: "modelSelection", headline: "publik API at this tier: $2.00 in / $12.00 out per 1M tokens", detail: "A different model answers on publik API." };

const openWindows: JSDOM[] = [];
afterEach(() => {
  for (const dom of openWindows.splice(0)) dom.window.close();
});

async function settle(): Promise<void> {
  for (let tick = 0; tick < 20; tick += 1) await new Promise((resolve) => setTimeout(resolve, 0));
}

function bootWindow(folder: "settings" | "chat", bridge: Record<string, unknown>) {
  const html = readFileSync(join(__dirname, "..", "src", "renderer", folder, "index.html"), "utf-8");
  const inlineScript = html.match(/<script>([\s\S]*)<\/script>/)?.[1];
  if (!inlineScript) throw new Error(`${folder}/index.html has no inline script`);
  const dom = new JSDOM(html.replace(/<script>[\s\S]*<\/script>/, ""), {
    url: `https://localhost/${folder}.html`,
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  openWindows.push(dom);
  Object.defineProperty(dom.window, "iris", { configurable: true, value: bridge });
  dom.window.eval(inlineScript);
  return dom.window.document;
}

function fakeBridge(options: { usage: FakeUsageView; prices?: unknown; nudge?: unknown; settings?: Record<string, unknown> }) {
  const calls: string[] = [];
  let usage = options.usage;
  const bridge = {
    getSettings: async () => ({ secretStorageAvailable: true, supabaseConfigured: true, providerPreference: "", ...options.settings }),
    setSetting: async (key: string, value: unknown) => {
      calls.push(`setSetting:${key}=${String(value)}`);
      return true;
    },
    signIn: () => {},
    signOut: async () => {},
    onAccountChanged: () => {},
    openExternal: async (url: string) => {
      calls.push(`openExternal:${url}`);
    },
    refreshPublikBalance: async () => null,
    onPublikBalanceChanged: () => {},
    usageState: async () => usage,
    usageDisclosureShown: async () => {
      calls.push("usageDisclosureShown");
      usage = { ...usage, state: usage.state === "notYetDisclosed" ? "sharing" : usage.state };
      return usage;
    },
    setUsageSharing: async (sharingOn: boolean) => {
      calls.push(`setUsageSharing:${sharingOn}`);
      usage = { state: sharingOn ? "sharing" : "notSharing", showDisclosure: false };
      return usage;
    },
    onUsageChanged: () => {},
    priceComparison: async () => options.prices ?? { state: "unavailable" },
    onPriceComparisonChanged: () => {},
    currentNudge: async () => options.nudge ?? null,
    dismissNudge: async () => {
      calls.push("dismissNudge");
    },
    nudgeActedOn: async () => {
      calls.push("nudgeActedOn");
    },
    onNudgeChanged: () => {},
    // chat window
    onStage: () => {},
    sendQuery: async () => "ok",
    lastChatFailure: async () => null,
    openGuide: () => {},
    openSettings: () => calls.push("openSettings"),
    minimizeWindow: () => {},
    closeWindow: () => {},
  };
  return { bridge, calls };
}

describe("the usage disclosure", () => {
  it("shows in settings until answered, with the switch on, and counts as shown once it appears", async () => {
    const { bridge, calls } = fakeBridge({ usage: { state: "notYetDisclosed", showDisclosure: true } });
    const document = bootWindow("settings", bridge);
    await settle();

    const card = document.querySelector("#usage-disclosure")!;
    expect(card.style.display).toBe("");
    expect(card.textContent).toContain("which catalog apps you open and which AI tier you pick");
    expect(card.textContent).toContain("No content, no identity.");
    expect(document.querySelector("#usage-disclosure-switch")!.checked).toBe(true);
    expect(calls).toContain("usageDisclosureShown");

    document.querySelector("#usage-continue")!.click();
    await settle();
    expect(calls).toContain("setUsageSharing:true");
    expect(card.style.display).toBe("none");
    expect(document.querySelector("#usageSharing")!.checked).toBe(true);
  });

  it("Turn off records off, and the settings switch reflects it", async () => {
    const { bridge, calls } = fakeBridge({ usage: { state: "sharing", showDisclosure: true } });
    const document = bootWindow("settings", bridge);
    await settle();
    document.querySelector("#usage-turn-off")!.click();
    await settle();
    expect(calls).toContain("setUsageSharing:false");
    expect(document.querySelector("#usageSharing")!.checked).toBe(false);
    expect(document.querySelector("#usage-sharing-note")!.textContent).toBe("Off. Iris counts nothing.");
  });

  it("appears in the chat window too, where Iris opens", async () => {
    const { bridge, calls } = fakeBridge({ usage: { state: "notYetDisclosed", showDisclosure: true } });
    const document = bootWindow("chat", bridge);
    await settle();
    expect(document.querySelector("#usage-disclosure")!.classList.contains("visible")).toBe(true);
    document.querySelector("#usage-continue")!.click();
    await settle();
    expect(calls).toContain("setUsageSharing:true");
    expect(document.querySelector("#usage-disclosure")!.classList.contains("visible")).toBe(false);
  });
});

describe("the price comparison", () => {
  it("draws a row per route with bars, prices, the assumption and the sources", async () => {
    const { bridge } = fakeBridge({ usage: { state: "sharing", showDisclosure: false }, prices: LOADED_PRICES });
    const document = bootWindow("settings", bridge);
    await settle();

    const rows = document.querySelectorAll(".price-option");
    expect(rows).toHaveLength(3);
    expect(rows[0].classList.contains("highlighted")).toBe(true);
    expect(rows[0].textContent).toContain("publik-balanced · xiaomi/mimo-v2.6-pro answers");
    expect(rows[0].textContent).toContain("$2.00 / 1M");
    expect(rows[0].textContent).toContain("≈ $4.08");
    expect(rows[2].textContent).toContain("$8.00 flat");
    const text = document.querySelector("#price-comparison")!.textContent!;
    expect(text).toContain("Assumes 300 questions a month.");
    expect(text).toContain("Source: Anthropic's list price");
    // The widest out-price ($15) fills its bar; publik's $12 fills 80%.
    const outBars = [...document.querySelectorAll(".bar-row")].filter((row) => row.textContent!.startsWith("Out"));
    expect(outBars[0].querySelector(".fill")!.style.width).toBe("80%");
    expect(outBars[1].querySelector(".fill")!.style.width).toBe("100%");
  });

  it("says prices are unavailable and shows no number when publik cannot be reached", async () => {
    const { bridge } = fakeBridge({ usage: { state: "sharing", showDisclosure: false }, prices: { state: "unavailable" } });
    const document = bootWindow("settings", bridge);
    await settle();
    const text = document.querySelector("#price-comparison")!.textContent!;
    expect(text).toContain("Prices are unavailable right now");
    expect(text).not.toMatch(/\$\d/);
  });
});

describe("the nudge card", () => {
  it("shows under the picker in settings; Not now dismisses, Use publik API switches", async () => {
    const { bridge, calls } = fakeBridge({ usage: { state: "sharing", showDisclosure: false }, nudge: A_NUDGE });
    const document = bootWindow("settings", bridge);
    await settle();
    const card = document.querySelector("#nudge-card")!;
    expect(card.style.display).toBe("");
    expect(card.textContent).toContain("A different model answers on publik API.");

    document.querySelector("#nudge-use-publik")!.click();
    await settle();
    expect(calls).toContain("nudgeActedOn");
    expect(calls).toContain("setSetting:providerPreference=publikApi");

    document.querySelector("#nudge-not-now")!.click();
    await settle();
    expect(calls).toContain("dismissNudge");
    expect(card.style.display).toBe("none");
  });

  it("shows in the chat window without blocking the input, and Compare opens settings", async () => {
    const { bridge, calls } = fakeBridge({ usage: { state: "sharing", showDisclosure: false }, nudge: { ...A_NUDGE, decisionPoint: "firstAICall" } });
    const document = bootWindow("chat", bridge);
    await settle();
    expect(document.querySelector("#nudge-card")!.classList.contains("visible")).toBe(true);
    expect(document.querySelector("#input")!.disabled).toBe(false);
    document.querySelector("#nudge-compare")!.click();
    await settle();
    expect(calls).toContain("nudgeActedOn");
    expect(calls).toContain("openSettings");
    expect(document.querySelector("#nudge-card")!.classList.contains("visible")).toBe(false);
  });
});
