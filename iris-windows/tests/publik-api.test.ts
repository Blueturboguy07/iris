import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  DEFAULT_PUBLIK_MODEL,
  DISCLOSURE_VERSION,
  PROVISIONING_DISCLOSURE,
  PUBLIK_MODEL_ALIASES,
  UNLINKED_ZERO_BALANCE_LINE,
  WHY_IT_COSTS_SENTENCE,
  buildInstallProvisioningRequest,
  formatMicrosAsDollars,
  insufficientCreditFallbackMessage,
  isPublikModelAlias,
  looksLikeAPublikApiKey,
  looksLikeAnAppToken,
  newInstallId,
  parseInsufficientCredit,
  parseProvisionedInstall,
  publikBalanceLine,
  publikCardState,
  readPublikUsageHeaders,
  revokedKeyWantsReprovisioning,
} from "../src/services/publik-api";

/** Deterministic bytes, so a UUID assertion is a real assertion. */
function fixedBytes(seed: number): (byteCount: number) => Uint8Array {
  return (byteCount) => Uint8Array.from({ length: byteCount }, (_unused, index) => (seed + index) & 0xff);
}

function headersFrom(pairs: Record<string, string>): { get(name: string): string | null } {
  const lowered = new Map(Object.entries(pairs).map(([name, value]) => [name.toLowerCase(), value]));
  return { get: (name) => lowered.get(name.toLowerCase()) ?? null };
}

describe("the money vocabulary", () => {
  it("shows dollars, never micros", () => {
    expect(formatMicrosAsDollars(250_000)).toBe("$0.25");
    expect(formatMicrosAsDollars(8_000_000)).toBe("$8.00");
    expect(formatMicrosAsDollars(0)).toBe("$0.00");
  });

  it("does not round a small remaining balance down to nothing", () => {
    // "$0.00" next to a working assistant reads as broken; four places keeps
    // a fifth of a cent legible as the small number it is.
    expect(formatMicrosAsDollars(2_000)).toBe("$0.0020");
  });

  it("treats a negative or nonsense balance as zero rather than showing it", () => {
    expect(formatMicrosAsDollars(-500)).toBe("$0.00");
    expect(formatMicrosAsDollars(Number.NaN)).toBe("$0.00");
  });

  it("obeys the copy rule in every string it renders", () => {
    // CONTRACT section 1: "publik API", dollars, never tokens, never "credits"
    // as a unit, never the provider's name.
    const renderedCopy = [
      WHY_IT_COSTS_SENTENCE,
      PROVISIONING_DISCLOSURE,
      UNLINKED_ZERO_BALANCE_LINE,
      insufficientCreditFallbackMessage("anonymous"),
      insufficientCreditFallbackMessage("claimed"),
      publikCardState({
        balanceMicros: 0,
        claimState: "anonymous",
        claimUrl: "https://publikhq.com/claim/ABCD-1234",
        addCreditUrl: null,
      }).balanceLine,
    ].join(" ");
    expect(renderedCopy).not.toMatch(/\btokens?\b/i);
    expect(renderedCopy).not.toMatch(/\bcredits\b/i);
    expect(renderedCopy).not.toMatch(/openai|anthropic|chatgpt|claude/i);
  });

  it("never promises free usage a new install does not get", () => {
    // publik migration 0059 (2026-09-28): an install is minted at $0.00, and
    // the only free thing is $0.05 of use, once per publik account, when a
    // computer is linked. Nothing may say an install starts with free usage.
    const renderedCopy = [
      PROVISIONING_DISCLOSURE,
      UNLINKED_ZERO_BALANCE_LINE,
      insufficientCreditFallbackMessage("anonymous"),
    ].join(" ");
    expect(renderedCopy).not.toMatch(/starts with free|free starter|free usage|small free|\$0\.25/i);
    expect(PROVISIONING_DISCLOSURE).toContain("$0.00");
    expect(PROVISIONING_DISCLOSURE).toContain("$0.05 of free use, once");
  });

  it("keeps the first-run window's disclosure word for word the same as the service's", () => {
    // The first-run page cannot import the service, so it carries its own copy
    // of the sentence. This is what stops the two from drifting apart.
    const firstRunPage = readFileSync(
      join(__dirname, "..", "src", "renderer", "first-run", "index.html"),
      "utf-8"
    );
    expect(firstRunPage).toContain(JSON.stringify(PROVISIONING_DISCLOSURE));
    expect(firstRunPage).not.toMatch(/starts with free usage/i);
  });
});

describe("model aliases", () => {
  it("accepts only the three tiers", () => {
    for (const alias of PUBLIK_MODEL_ALIASES) expect(isPublikModelAlias(alias)).toBe(true);
    expect(isPublikModelAlias("claude-sonnet-4-5")).toBe(false);
    expect(isPublikModelAlias("gpt-4o")).toBe(false);
  });

  it("does not default to the tier an anonymous key is refused", () => {
    // `publik-smart` on an unclaimed key is answered 402 model_requires_claim,
    // which would turn a first run into an error.
    expect(DEFAULT_PUBLIK_MODEL).not.toBe("publik-smart");
  });
});

describe("install identity", () => {
  it("mints a v4 UUID", () => {
    const installId = newInstallId(fixedBytes(1));
    expect(installId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  });

  it("mints a different id from different bytes", () => {
    expect(newInstallId(fixedBytes(1))).not.toBe(newInstallId(fixedBytes(90)));
  });

  it("recognises the key and token shapes, and rejects near-misses", () => {
    expect(looksLikeAPublikApiKey("pk_live_abcdef123456_0123456789abcdef0123456789abcdef")).toBe(true);
    expect(looksLikeAPublikApiKey("pk_test_abcdef123456_0123456789abcdef0123456789abcdef")).toBe(true);
    expect(looksLikeAPublikApiKey("sk-ant-nope")).toBe(false);
    expect(looksLikeAPublikApiKey("pk_live_short_key")).toBe(false);

    expect(looksLikeAnAppToken("pat_iris_0123456789abcdef0123456789abcdef")).toBe(true);
    expect(looksLikeAnAppToken("pat_iris_tooshort")).toBe(false);
    expect(looksLikeAnAppToken("")).toBe(false);
  });
});

describe("the provisioning request", () => {
  const request = buildInstallProvisioningRequest("https://publikhq.com/api/v1/", {
    appToken: "pat_iris_0123456789abcdef0123456789abcdef",
    appSlug: "iris",
    appVersion: "0.9.11",
    osVersion: "10.0.22631",
    arch: "x64",
    installId: "11111111-2222-4333-8444-555555555555",
    deviceName: "A Windows PC",
  });
  const body = JSON.parse(request.body) as Record<string, unknown>;

  it("posts to /installs on the gateway, with a normalised base", () => {
    expect(request.url).toBe("https://publikhq.com/api/v1/installs");
  });

  it("declares the Anthropic Messages dialect, which is what Iris speaks", () => {
    expect(body.dialects).toEqual(["messages"]);
  });

  it("names the platform and carries the app token and install id", () => {
    expect(body.os).toBe("windows");
    expect(body.app_slug).toBe("iris");
    expect(body.app_token).toBe("pat_iris_0123456789abcdef0123456789abcdef");
    expect(body.install_id).toBe("11111111-2222-4333-8444-555555555555");
    expect(body.disclosure_version).toBe(DISCLOSURE_VERSION);
    expect(DISCLOSURE_VERSION).toBe(2);
  });
});

describe("reading a provisioning response", () => {
  it("reads a 201 with a key, a $0.00 balance and a claim link", () => {
    // publik migration 0059: a new install is minted at $0.00, with no starter.
    const install = parseProvisionedInstall(
      JSON.stringify({
        key: "pk_live_abcdef123456_0123456789abcdef0123456789abcdef",
        claim_code: "HK7F-2QWD",
        claim_url: "https://publikhq.com/claim/HK7F-2QWD",
        add_credit_url: "https://publikhq.com/dashboard/api/add",
        claim_state: "anonymous",
        starter_micros: 0,
        balance_micros: 0,
        base_url: "https://publikhq.com/api/v1",
      })
    );
    expect(install?.apiKey).toBe("pk_live_abcdef123456_0123456789abcdef0123456789abcdef");
    expect(install?.starterMicros).toBe(0);
    expect(install?.balanceMicros).toBe(0);
    expect(install?.claimState).toBe("anonymous");
    expect(install?.baseUrl).toBe("https://publikhq.com/api/v1");
  });

  it("accepts starting_credit_micros as the documented alias of the balance", () => {
    // An install minted already bound to a publik account carries that
    // account's one-time $0.05 of free use.
    const install = parseProvisionedInstall(
      JSON.stringify({ key: null, claim_state: "claimed", starting_credit_micros: 50_000 })
    );
    expect(install?.balanceMicros).toBe(50_000);
    expect(install?.claimState).toBe("claimed");
  });

  it("reads a replayed 200 as having no key, rather than inventing one", () => {
    const install = parseProvisionedInstall(
      JSON.stringify({ key: null, starter_micros: 0, claim_state: "anonymous" })
    );
    expect(install).not.toBeNull();
    expect(install?.apiKey).toBeNull();
  });

  it("refuses a key that is not shaped like one", () => {
    const install = parseProvisionedInstall(JSON.stringify({ key: "not-a-key" }));
    expect(install?.apiKey).toBeNull();
  });

  it("returns null for a body that is not JSON", () => {
    expect(parseProvisionedInstall("<html>502</html>")).toBeNull();
  });
});

describe("reading a metered response", () => {
  it("reads the balance and claim state off the headers", () => {
    const usage = readPublikUsageHeaders(
      headersFrom({
        "x-publik-balance": "182400",
        "x-publik-claim-state": "anonymous",
        "x-publik-starter-remaining": "182400",
        "x-publik-model": "publik-balanced",
      })
    );
    expect(usage.balanceMicros).toBe(182_400);
    expect(usage.claimState).toBe("anonymous");
    expect(usage.starterRemainingMicros).toBe(182_400);
    expect(usage.servedModel).toBe("publik-balanced");
  });

  it("reports a missing balance as unknown, never as zero", () => {
    // Zero means "you are out of money" and would light up the top-up CTA on
    // a response that simply did not carry the header.
    const usage = readPublikUsageHeaders(headersFrom({}));
    expect(usage.balanceMicros).toBeNull();
    expect(usage.claimState).toBeNull();
  });

  it("ignores a header it cannot parse", () => {
    const usage = readPublikUsageHeaders(headersFrom({ "x-publik-balance": "lots" }));
    expect(usage.balanceMicros).toBeNull();
  });

  it("reads what a settled call cost from x-publik-charge-micros", () => {
    const usage = readPublikUsageHeaders(headersFrom({ "x-publik-charge-micros": " 4321 " }));
    expect(usage.chargeMicros).toBe(4_321);
    expect(readPublikUsageHeaders(headersFrom({ "x-publik-charge-micros": "0" })).chargeMicros).toBe(0);
  });

  it("ignores a charge that is not a plain whole number rather than guessing at it", () => {
    // parseInt would read "12abc" as 12 and "1.5" as 1: a garbled charge must
    // not become a price on screen.
    for (const malformed of ["12abc", "-5", "1.5", "lots", "", "1e3"]) {
      expect(readPublikUsageHeaders(headersFrom({ "x-publik-charge-micros": malformed })).chargeMicros).toBeNull();
    }
    expect(readPublikUsageHeaders(headersFrom({})).chargeMicros).toBeNull();
  });
});

describe("the 402", () => {
  const body = JSON.stringify({
    error: {
      type: "insufficient_credit",
      message: "Not enough publik credit for this request.",
      available_micros: 0,
      required_micros: 41000,
      claim_state: "anonymous",
      top_up_url: "https://publikhq.com/claim/HK7F-2QWD",
      claim_url: "https://publikhq.com/claim/HK7F-2QWD",
      add_credit_url: "https://publikhq.com/dashboard/api/add",
    },
  });

  it("keeps the server's own message and exactly one link", () => {
    const exhausted = parseInsufficientCredit(body);
    expect(exhausted?.message).toBe("Not enough publik credit for this request.");
    expect(exhausted?.topUpUrl).toBe("https://publikhq.com/claim/HK7F-2QWD");
    expect(exhausted?.claimState).toBe("anonymous");
  });

  it("also reads model_requires_claim, which an anonymous key hits on the top tier", () => {
    const exhausted = parseInsufficientCredit(
      JSON.stringify({
        error: { type: "model_requires_claim", message: "Link this computer first.", claim_url: "u" },
      })
    );
    expect(exhausted?.message).toBe("Link this computer first.");
    expect(exhausted?.topUpUrl).toBe("u");
  });

  it("falls back to a sentence of its own only when the server sent none", () => {
    const anonymous = parseInsufficientCredit(
      JSON.stringify({ error: { type: "insufficient_credit", claim_state: "anonymous", top_up_url: "u" } })
    );
    expect(anonymous?.message).toBe(
      "Your publik API balance is too low for this request. Link this computer to your publik account for $0.05 of free use, once, or pick a plan."
    );
    const claimed = parseInsufficientCredit(
      JSON.stringify({ error: { type: "insufficient_credit", claim_state: "claimed", top_up_url: "u" } })
    );
    expect(claimed?.message).toBe(
      "Your publik API balance is too low for this request. Add a plan or a pack to keep going."
    );
    const needsClaim = parseInsufficientCredit(JSON.stringify({ error: { type: "model_requires_claim" } }));
    expect(needsClaim?.message).toBe("Link this computer to your publik account to use this model.");
  });

  it("ignores an error of a different type", () => {
    expect(parseInsufficientCredit(JSON.stringify({ error: { type: "rate_limit_exceeded" } }))).toBeNull();
  });

  it("reads the reprovision flag off a revoked key", () => {
    expect(revokedKeyWantsReprovisioning(JSON.stringify({ error: { reprovision: true } }))).toBe(true);
    expect(revokedKeyWantsReprovisioning(JSON.stringify({ error: {} }))).toBe(false);
    expect(revokedKeyWantsReprovisioning("nonsense")).toBe(false);
  });
});

describe("the publik card", () => {
  it("asks a new, unlinked install at $0.00 to link the computer for its free use", () => {
    // publik migration 0059: the mint gives $0.00 and no starter. The first
    // card says so, and says what linking gives, instead of "$0.00 left".
    const card = publikCardState({
      balanceMicros: 0,
      claimState: "anonymous",
      claimUrl: "https://publikhq.com/claim/HK7F-2QWD",
      addCreditUrl: null,
    });
    expect(card.balanceLine).toBe("$0.00 · link this computer for $0.05 of free use");
    expect(card.balanceLine).toBe(UNLINKED_ZERO_BALANCE_LINE);
    expect(card.whyItCosts).toBe(WHY_IT_COSTS_SENTENCE);
    expect(card.buttonLabel).toBe("Link this computer & pick a plan");
    expect(card.buttonUrl).toBe("https://publikhq.com/claim/HK7F-2QWD");
  });

  it("shows a linked account's one-time $0.05 as an ordinary balance", () => {
    const card = publikCardState({
      balanceMicros: 50_000,
      claimState: "claimed",
      claimUrl: null,
      addCreditUrl: "https://publikhq.com/dashboard/api/add",
    });
    expect(card.balanceLine).toBe("$0.05 left");
    expect(card.buttonLabel).toBe("Add a plan or pack");
  });

  it("shows what is left on an unlinked install that still has a balance", () => {
    // Only an install minted before migration 0059 can be here.
    const card = publikCardState({
      balanceMicros: 182_400,
      claimState: "anonymous",
      claimUrl: "https://publikhq.com/claim/HK7F-2QWD",
      addCreditUrl: null,
    });
    expect(card.balanceLine).toBe("$0.18 left");
  });

  it("says $0.00 left, not the link line, once the install is linked", () => {
    expect(publikBalanceLine(0, "claimed")).toBe("$0.00 left");
    expect(publikBalanceLine(0)).toBe("$0.00 left");
    expect(publikBalanceLine(0, "anonymous")).toBe(UNLINKED_ZERO_BALANCE_LINE);
  });

  it("switches the button once the install is claimed", () => {
    const card = publikCardState({
      balanceMicros: 800_000,
      claimState: "claimed",
      claimUrl: "https://publikhq.com/claim/HK7F-2QWD",
      addCreditUrl: "https://publikhq.com/dashboard/api/add",
    });
    expect(card.buttonLabel).toBe("Add a plan or pack");
    expect(card.buttonUrl).toBe("https://publikhq.com/dashboard/api/add");
  });
});
