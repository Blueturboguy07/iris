import { describe, expect, it } from "vitest";
import {
  crashTelemetryIsOn,
  parseConsentDocument,
  readerHasAnsweredTheUsageDisclosure,
  serializeConsentDocument,
  storedInstallIdentifier,
  usageDisclosureHasBeenShown,
  usageSharingState,
  withInstallIdentifier,
  withUsageDisclosureShown,
  withUsageSharingChoice,
} from "../src/services/consent-file";
import {
  PublikApiNudgeSession,
  QUIET_PERIOD_AFTER_DISMISSAL_MS,
  composeNudge,
  isQuiet,
  mayNudge,
} from "../src/services/publik-api-nudge";
import {
  comparisonForThisPc,
  listPriceForModel,
  parseModelPriceComparison,
  type ComparisonOption,
} from "../src/services/model-price-comparison";
import type { UsageProvider } from "../src/services/usage-monitor";

/**
 * The consent file, the price comparison and the nudge policy — the Windows
 * halves of `PublikConsentStoreTests.swift` and `PublikAPINudgeTests.swift`.
 */

const INSTALL_ID = "3f1b2c4d-1111-2222-3333-abcdefabcdef";
const NOW = new Date("2026-09-25T14:37:12Z");
const mint = () => "11111111-2222-3333-4444-555555555555";

describe("consent.json", () => {
  it("counts nothing before the disclosure has been shown", () => {
    expect(usageSharingState(parseConsentDocument(null))).toBe("notYetDisclosed");
    expect(usageSharingState(parseConsentDocument("{not json"))).toBe("notYetDisclosed");
  });

  it("turns the default on when the disclosure is shown, and writes telemetry as off", () => {
    const shown = withUsageDisclosureShown({}, mint, NOW);
    expect(usageSharingState(shown)).toBe("sharing");
    expect(usageDisclosureHasBeenShown(shown)).toBe(true);
    expect(readerHasAnsweredTheUsageDisclosure(shown)).toBe(false);
    expect(shown.telemetry).toBe(false);
    expect(storedInstallIdentifier(shown)).toBe(mint());
  });

  it("keeps an off switch off even if the disclosure is shown again", () => {
    const off = withUsageSharingChoice(withUsageDisclosureShown({}, mint, NOW), false, mint, NOW);
    expect(usageSharingState(withUsageDisclosureShown(off, mint, NOW))).toBe("notSharing");
    expect(readerHasAnsweredTheUsageDisclosure(off)).toBe(true);
  });

  it("never flips crash telemetry and keeps keys it does not know", () => {
    const existing = parseConsentDocument(
      JSON.stringify({ telemetry: true, install_id: INSTALL_ID, updated_at: "2026-08-02T04:00:00Z", another_client: "keep me" })
    );
    const next = withUsageSharingChoice(withUsageDisclosureShown(existing, mint, NOW), false, mint, NOW);
    expect(crashTelemetryIsOn(next)).toBe(true);
    expect(next.install_id).toBe(INSTALL_ID);
    expect(next.another_client).toBe("keep me");
    const roundTripped = parseConsentDocument(serializeConsentDocument(next));
    expect(roundTripped).toEqual(next);
  });

  it("mints an install id once and keeps it", () => {
    const first = withInstallIdentifier({}, mint, NOW);
    const second = withInstallIdentifier(first, () => "99999999-9999-9999-9999-999999999999", NOW);
    expect(storedInstallIdentifier(second)).toBe(mint());
  });
});

/** Shaped exactly as publik's `lib/iris-model-prices.ts` builds it. */
const COMPARISON_BODY = {
  version: 1,
  assumption: { questionsPerMonth: 300, inputTokensPerQuestion: 5000, outputTokensPerQuestion: 300, summary: "Assumes 300 questions a month." },
  caveat: "A different model answers on each route.",
  levels: [
    {
      tier: "balanced",
      options: [
        { provider: "publik-api", label: "publik API", model: "publik-balanced", servedBy: "xiaomi/mimo-v2.6-pro", billing: "per_token", inputUsdPerMillion: 2, outputUsdPerMillion: 12, estimatedCostPerQuestionUsd: 0.0136, estimatedMonthlyUsd: 4.08, note: "Prepaid balance.", source: "publik" },
        { provider: "anthropic-key", label: "Your own Anthropic key", model: "claude-sonnet-4-6", servedBy: null, billing: "per_token", inputUsdPerMillion: 3, outputUsdPerMillion: 15, estimatedCostPerQuestionUsd: 0.0195, estimatedMonthlyUsd: 5.85, note: "Billed by Anthropic.", source: "anthropic" },
        { provider: "codex", label: "Your ChatGPT plan (Codex)", model: "your codex CLI's model", servedBy: null, billing: "subscription", inputUsdPerMillion: null, outputUsdPerMillion: null, estimatedCostPerQuestionUsd: null, estimatedMonthlyUsd: 8, note: "Flat monthly plan.", source: "openai" },
      ],
    },
  ],
  anthropicListPrices: [
    { model: "claude-sonnet-4-5", inputUsdPerMillion: 3, cacheWriteUsdPerMillion: 3.75, cacheReadUsdPerMillion: 0.3, outputUsdPerMillion: 15 },
    { model: "claude-opus-4", inputUsdPerMillion: 15, cacheWriteUsdPerMillion: 18.75, cacheReadUsdPerMillion: 1.5, outputUsdPerMillion: 75 },
    { model: "claude-opus-4-1", inputUsdPerMillion: 15, cacheWriteUsdPerMillion: 18.75, cacheReadUsdPerMillion: 1.5, outputUsdPerMillion: 75 },
    { model: "claude-haiku-4-5", inputUsdPerMillion: 1, cacheWriteUsdPerMillion: 1.25, cacheReadUsdPerMillion: 0.1, outputUsdPerMillion: 5 },
  ],
};

describe("the price comparison", () => {
  it("rejects anything that is not the route's shape rather than rendering half of it", () => {
    expect(parseModelPriceComparison(null)).toBeNull();
    expect(parseModelPriceComparison({ ...COMPARISON_BODY, version: 2 })).toBeNull();
    expect(parseModelPriceComparison({ ...COMPARISON_BODY, levels: [] })).toBeNull();
    const broken = JSON.parse(JSON.stringify(COMPARISON_BODY));
    broken.levels[0].options[0].inputUsdPerMillion = "2";
    expect(parseModelPriceComparison(broken)).toBeNull();
  });

  it("resolves a dated model id to its listed price, longest match first", () => {
    const comparison = parseModelPriceComparison(COMPARISON_BODY)!;
    expect(listPriceForModel(comparison, "claude-opus-4-1-20250805")?.model).toBe("claude-opus-4-1");
    expect(listPriceForModel(comparison, "claude-sonnet-4-5-20250929")?.model).toBe("claude-sonnet-4-5");
    expect(listPriceForModel(comparison, "claude-something-new")).toBeNull();
  });

  it("reprices the own-key row for the model this PC's reader picked, from the stated assumption", () => {
    const forThisPc = comparisonForThisPc(parseModelPriceComparison(COMPARISON_BODY)!, "claude-opus-4-1-20250805")!;
    const key = forThisPc.options.find((option) => option.provider === "anthropic-key")!;
    expect(key.model).toBe("claude-opus-4-1");
    expect(key.inputUsdPerMillion).toBe(15);
    // 5,000 × $15 + 300 × $75 per million = $0.0975 a question; × 300 = $29.25.
    expect(key.estimatedCostPerQuestionUsd).toBe(0.0975);
    expect(key.estimatedMonthlyUsd).toBe(29.25);
    expect(forThisPc.options.map((option) => option.provider)).toEqual(["publik-api", "anthropic-key", "codex"]);
  });

  it("drops the own-key row rather than show another model's price", () => {
    const forThisPc = comparisonForThisPc(parseModelPriceComparison(COMPARISON_BODY)!, "claude-unknown-9")!;
    expect(forThisPc.options.map((option) => option.provider)).toEqual(["publik-api", "codex"]);
  });
});

const optionsFor = (model: string): ComparisonOption[] =>
  comparisonForThisPc(parseModelPriceComparison(COMPARISON_BODY)!, model)!.options;

describe("the nudge policy", () => {
  it("is quiet for 7 days after a dismissal, then allowed again", () => {
    const dismissedAt = NOW.getTime();
    expect(isQuiet(dismissedAt, dismissedAt + QUIET_PERIOD_AFTER_DISMISSAL_MS - 1)).toBe(true);
    expect(isQuiet(dismissedAt, dismissedAt + QUIET_PERIOD_AFTER_DISMISSAL_MS)).toBe(false);
    expect(isQuiet(dismissedAt, dismissedAt - 3 * 24 * 3600 * 1000)).toBe(true);
    expect(isQuiet(null, dismissedAt)).toBe(false);
  });

  it("never nudges somebody on publik API or with nothing set up, and only once a session", () => {
    for (const provider of ["publik-api", null] as const) {
      expect(mayNudge({ provider, hasAlreadyNudgedThisSession: false, lastDismissedAtMs: null, nowMs: NOW.getTime() })).toBe(false);
    }
    expect(mayNudge({ provider: "anthropic-key", hasAlreadyNudgedThisSession: true, lastDismissedAtMs: null, nowMs: NOW.getTime() })).toBe(false);
  });

  it("says nothing without the comparison, and nothing when publik lists above the key", () => {
    expect(composeNudge({ decisionPoint: "firstAICall", provider: "anthropic-key", comparisonOptions: null })).toBeNull();
    const pricier = optionsFor("claude-haiku-4-5-20251001");
    expect(composeNudge({ decisionPoint: "firstAICall", provider: "anthropic-key", comparisonOptions: pricier })).toBeNull();
  });

  it("shows both real prices and says a different model answers", () => {
    const nudge = composeNudge({ decisionPoint: "modelSelection", provider: "anthropic-key", comparisonOptions: optionsFor("claude-sonnet-4-5-20250929") })!;
    const text = `${nudge.headline} ${nudge.detail}`;
    expect(text).toContain("$2.00 in / $12.00 out");
    expect(text).toContain("$3.00 / $15.00");
    expect(text).toContain("A different model answers on publik API");
    expect(text.toLowerCase()).not.toMatch(/half|save|cheaper/);
  });

  it("tells a ChatGPT-plan reader the plan costs nothing extra, and claims no advantage", () => {
    const nudge = composeNudge({ decisionPoint: "firstAICall", provider: "codex", comparisonOptions: optionsFor("claude-sonnet-4-5-20250929") })!;
    expect(nudge.detail).toContain("costs nothing extra per question");
    expect(nudge.detail.toLowerCase()).not.toMatch(/faster|better|tools/);
  });
});

describe("the nudge session", () => {
  function makeSession(options: { provider: { value: UsageProvider | null }; store: { dismissedAt: number | null }; now: { value: number } }) {
    const changes: unknown[] = [];
    const session = new PublikApiNudgeSession({
      nowMs: () => options.now.value,
      lastDismissedAtMs: () => options.store.dismissedAt,
      recordDismissal: (atMs) => {
        options.store.dismissedAt = atMs;
      },
      currentProvider: () => options.provider.value,
      comparisonOptions: () => optionsFor("claude-sonnet-4-5-20250929"),
      onChange: (nudge) => changes.push(nudge),
    });
    return { session, changes };
  }

  it("nudges on the first call only, once a session", () => {
    const { session } = makeSession({ provider: { value: "anthropic-key" }, store: { dismissedAt: null }, now: { value: NOW.getTime() } });
    session.anAICallIsGoingOut();
    expect(session.visibleNudge?.decisionPoint).toBe("firstAICall");
    session.readerActedOnIt();
    session.anAICallIsGoingOut();
    session.readerPickedAProviderOrModel();
    expect(session.visibleNudge).toBeNull();
  });

  it("does not count a call on publik API as a missed chance, but it does use up the first call", () => {
    const provider = { value: "publik-api" as UsageProvider | null };
    const { session } = makeSession({ provider, store: { dismissedAt: null }, now: { value: NOW.getTime() } });
    session.anAICallIsGoingOut();
    provider.value = "anthropic-key";
    session.anAICallIsGoingOut();
    expect(session.visibleNudge).toBeNull();
    session.readerPickedAProviderOrModel();
    expect(session.visibleNudge?.decisionPoint).toBe("modelSelection");
  });

  it("carries a dismissal into the next session for 7 days", () => {
    const store = { dismissedAt: null as number | null };
    const now = { value: NOW.getTime() };
    const first = makeSession({ provider: { value: "codex" }, store, now });
    first.session.readerPickedAProviderOrModel();
    expect(first.session.visibleNudge).not.toBeNull();
    first.session.dismiss();
    expect(store.dismissedAt).toBe(NOW.getTime());

    now.value = NOW.getTime() + 3 * 24 * 3600 * 1000;
    const second = makeSession({ provider: { value: "codex" }, store, now });
    second.session.readerPickedAProviderOrModel();
    expect(second.session.visibleNudge).toBeNull();

    now.value = NOW.getTime() + QUIET_PERIOD_AFTER_DISMISSAL_MS + 60_000;
    const third = makeSession({ provider: { value: "codex" }, store, now });
    third.session.readerPickedAProviderOrModel();
    expect(third.session.visibleNudge).not.toBeNull();
  });

  it("clears itself when the reader picks publik API", () => {
    const provider = { value: "anthropic-key" as UsageProvider | null };
    const { session, changes } = makeSession({ provider, store: { dismissedAt: null }, now: { value: NOW.getTime() } });
    session.readerPickedAProviderOrModel();
    expect(session.visibleNudge).not.toBeNull();
    provider.value = "publik-api";
    session.readerPickedAProviderOrModel();
    expect(session.visibleNudge).toBeNull();
    expect(changes.at(-1)).toBeNull();
  });
});
