import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import {
  ADD_CREDIT_FALLBACK_URL,
  BalanceFetch,
  PublikReplyCostTally,
  addCreditUrlFor,
  addCreditUrlForRefusal,
  balanceIsLow,
  balanceLine,
  costPerMessageLine,
  formatCostMicros,
  parseBalanceResponse,
  publikBalanceMenuLabel,
  publikBalanceView,
  readPublikBalance,
  typicalMessageChargeMicros,
} from "../src/services/publik-balance";
import { parseInsufficientCredit } from "../src/services/publik-api";

/**
 * Balance + Add credit in Iris (founder decision, 2026-09-22).
 *
 * The `/balance` bodies are the files in `fixtures/publik-balance`, which the
 * macOS suite (`PublikAPIBalanceTests.swift`) reads too, so both clients are
 * held to one shape. They are modelled on the gateway's own `walletBody`
 * (publik repo, `lib/publik-api/wallet.ts`).
 */

function balanceFixture(fileName: string): string {
  return readFileSync(join(__dirname, "fixtures", "publik-balance", fileName), "utf-8");
}

const THE_PUBLIK_KEY = "pk_live_abcdef123456_0123456789abcdef0123456789abcdef";

describe("reading GET /balance", () => {
  it("shows an anonymous install its balance and sends Add credit to the claim page", () => {
    const balance = parseBalanceResponse(balanceFixture("anonymous.json"));
    expect(balance).not.toBeNull();
    expect(balance!.balanceMicros).toBe(181_240);
    expect(balance!.claimState).toBe("anonymous");
    expect(balanceLine(balance!.balanceMicros)).toBe("$0.18 left");
    expect(balanceIsLow(balance!.balanceMicros)).toBe(true);
    expect(addCreditUrlFor(balance!)).toBe("https://publikhq.com/claim/HK7F-2QWD");
  });

  it("shows a claimed install its balance and sends Add credit to the add-credit page", () => {
    const balance = parseBalanceResponse(balanceFixture("claimed.json"));
    expect(balance!.balanceMicros).toBe(1_843_210);
    expect(balance!.claimState).toBe("claimed");
    expect(balanceLine(balance!.balanceMicros)).toBe("$1.84 left");
    expect(balanceIsLow(balance!.balanceMicros)).toBe(false);
    expect(addCreditUrlFor(balance!)).toBe("https://publikhq.com/dashboard/api/add");
  });

  it("lets the claim state decide when the answer carries no top_up_url", () => {
    // Both bodies name the same two links; only the claim state can be what
    // sends one to the claim page and the other to add-credit.
    const links = {
      claim_url: "https://publikhq.com/claim/AB12-CD34",
      add_credit_url: "https://publikhq.com/dashboard/api/add",
    };
    const anonymous = parseBalanceResponse(JSON.stringify({ balance_micros: 90_000, claim_state: "anonymous", ...links }));
    const claimed = parseBalanceResponse(JSON.stringify({ balance_micros: 90_000, claim_state: "claimed", ...links }));
    expect(addCreditUrlFor(anonymous!)).toBe("https://publikhq.com/claim/AB12-CD34");
    expect(addCreditUrlFor(claimed!)).toBe("https://publikhq.com/dashboard/api/add");
  });

  it("never opens a link that is not a page on publik", () => {
    const foreign = parseBalanceResponse(
      JSON.stringify({
        available_micros: 5,
        claim_state: "anonymous",
        top_up_url: "https://publikhq.com.evil.example/claim/AB12-CD34",
        claim_url: "https://publikhq.com/claim/AB12-CD34",
      })
    );
    expect(addCreditUrlFor(foreign!)).toBe("https://publikhq.com/claim/AB12-CD34");

    const plainHttpOnly = parseBalanceResponse(
      JSON.stringify({ available_micros: 5, claim_state: "claimed", top_up_url: "http://publikhq.com/dashboard/api/add" })
    );
    expect(addCreditUrlFor(plainHttpOnly!)).toBe(ADD_CREDIT_FALLBACK_URL);
    expect(addCreditUrlForRefusal("https://user:pass@publikhq.com/claim/X")).toBe(ADD_CREDIT_FALLBACK_URL);
    expect(addCreditUrlForRefusal(null)).toBe("https://publikhq.com/dashboard/api/add");
  });

  it("does not read a body without a balance as zero", () => {
    // A 200 with no balance must leave the last good number on screen rather
    // than replace it with "$0.00 left".
    expect(parseBalanceResponse(JSON.stringify({ claim_state: "claimed" }))).toBeNull();
    expect(parseBalanceResponse(JSON.stringify({ balance_micros: "181240" }))).toBeNull();
    expect(parseBalanceResponse("not json")).toBeNull();
  });

  it("sends a 402 and the balance row to the same page", () => {
    // The two "Add credit" buttons — under the refusal in chat and in the
    // settings panel — must land on one page for the same anonymous install.
    const refusal = parseInsufficientCredit(
      JSON.stringify({
        type: "error",
        error: {
          type: "insufficient_credit",
          message: "Not enough publik credit for this request.",
          available_micros: 1_240,
          claim_state: "anonymous",
          top_up_url: "https://publikhq.com/claim/HK7F-2QWD",
          claim_url: "https://publikhq.com/claim/HK7F-2QWD",
          add_credit_url: "https://publikhq.com/dashboard/api/add",
        },
      })
    );
    const balance = parseBalanceResponse(balanceFixture("anonymous.json"));
    expect(addCreditUrlForRefusal(refusal!.topUpUrl)).toBe(addCreditUrlFor(balance!));
    expect(addCreditUrlForRefusal(refusal!.topUpUrl)).toBe("https://publikhq.com/claim/HK7F-2QWD");
  });
});

describe("the request that reads the balance", () => {
  function recordingBalanceFetch(response: { ok: boolean; body: string }) {
    const sent: Array<{ url: string; method: string; headers: Record<string, string> }> = [];
    const fetchImplementation: BalanceFetch = async (url, init) => {
      sent.push({ url, method: init.method, headers: init.headers });
      return { ok: response.ok, text: async () => response.body };
    };
    return { fetchImplementation, sent };
  }

  it("GETs {base}/balance carrying the publik key, and parses the answer", async () => {
    const { fetchImplementation, sent } = recordingBalanceFetch({ ok: true, body: balanceFixture("claimed.json") });
    const balance = await readPublikBalance(
      { tier: "publik", publikApiKey: THE_PUBLIK_KEY, apiBaseUrl: "https://publikhq.com/api/v1/" },
      fetchImplementation
    );
    expect(sent).toEqual([
      {
        url: "https://publikhq.com/api/v1/balance",
        method: "GET",
        headers: { "x-api-key": THE_PUBLIK_KEY },
      },
    ]);
    expect(balance?.balanceMicros).toBe(1_843_210);
  });

  it("never sends the key to a gateway address that is not publik's", async () => {
    const { fetchImplementation, sent } = recordingBalanceFetch({ ok: true, body: balanceFixture("claimed.json") });
    const balance = await readPublikBalance(
      { tier: "publik", publikApiKey: THE_PUBLIK_KEY, apiBaseUrl: "https://evil.example/api/v1" },
      fetchImplementation
    );
    expect(balance).toBeNull();
    expect(sent).toEqual([]);
  });

  it("keeps the last good balance when the read fails", async () => {
    const { fetchImplementation } = recordingBalanceFetch({ ok: false, body: "{}" });
    const balance = await readPublikBalance(
      { tier: "publik", publikApiKey: THE_PUBLIK_KEY, apiBaseUrl: "https://publikhq.com/api/v1" },
      fetchImplementation
    );
    expect(balance).toBeNull();
  });
});

describe("the low-balance warning", () => {
  it("starts just under a quarter, not at it", () => {
    expect(balanceIsLow(250_000)).toBe(false);
    expect(balanceIsLow(249_999)).toBe(true);
    expect(balanceIsLow(250_001)).toBe(false);
    expect(balanceIsLow(0)).toBe(true);
  });
});

describe("what a message costs", () => {
  it("prices the typical 2,000-in / 500-out message from each tier by hand", () => {
    // balanced: 2000 × $2   + 500 × $12  = $0.004  + $0.006  = $0.010
    // fast:     2000 × $0.2 + 500 × $1.2 = $0.0004 + $0.0006 = $0.001
    // smart:    2000 × $4   + 500 × $20  = $0.008  + $0.010  = $0.018
    expect(typicalMessageChargeMicros("publik-balanced")).toBe(10_000);
    expect(typicalMessageChargeMicros("publik-fast")).toBe(1_000);
    expect(typicalMessageChargeMicros("publik-smart")).toBe(18_000);
  });

  it("shows a cost to a tenth of a cent and never as free", () => {
    expect(formatCostMicros(4_321)).toBe("$0.004");
    expect(formatCostMicros(4_500)).toBe("$0.005");
    expect(formatCostMicros(10_000)).toBe("$0.010");
    expect(formatCostMicros(1_234_567)).toBe("$1.235");
    expect(formatCostMicros(400)).toBe("under $0.001");
    expect(formatCostMicros(0)).toBe("$0.00");
  });

  it("names the tier before the first reply and the reply after it, in dollars only", () => {
    const beforeAnyReply = costPerMessageLine(null, "publik-balanced");
    const afterAReply = costPerMessageLine(4_321, "publik-balanced");
    expect(beforeAnyReply).toBe("About $0.010 per message on publik-balanced");
    expect(afterAReply).toBe("Last reply: $0.004");
    for (const line of [beforeAnyReply, afterAReply, balanceLine(181_240)]) {
      expect(line.toLowerCase()).not.toContain("token");
      expect(line.toLowerCase()).not.toContain("credit");
    }
  });
});

describe("what the tray, settings and chat title are handed", () => {
  const anonymous = {
    claimState: "anonymous" as const,
    claimUrl: "https://publikhq.com/claim/HK7F-2QWD",
    addCreditUrl: "https://publikhq.com/dashboard/api/add",
    topUpUrl: "https://publikhq.com/claim/HK7F-2QWD",
  };

  it("is nothing at all when publik API is not the provider answering", () => {
    expect(
      publikBalanceView({
        answeringWithPublik: false,
        balanceMicros: 181_240,
        lastReplyChargeMicros: 4_321,
        modelAlias: "publik-balanced",
        ...anonymous,
      })
    ).toBeNull();
  });

  it("carries the line, the warning, the cost and the link while it is", () => {
    expect(
      publikBalanceView({
        answeringWithPublik: true,
        balanceMicros: 181_240,
        lastReplyChargeMicros: 4_321,
        modelAlias: "publik-balanced",
        ...anonymous,
      })
    ).toEqual({
      balanceLine: "$0.18 left",
      isLow: true,
      costLine: "Last reply: $0.004",
      addCreditUrl: "https://publikhq.com/claim/HK7F-2QWD",
    });
  });

  it("claims nothing is low before the first balance has been read", () => {
    const view = publikBalanceView({
      answeringWithPublik: true,
      balanceMicros: null,
      lastReplyChargeMicros: null,
      modelAlias: "publik-balanced",
      ...anonymous,
    });
    expect(view?.balanceLine).toBeNull();
    expect(view?.isLow).toBe(false);
    expect(view?.costLine).toBe("About $0.010 per message on publik-balanced");
  });

  it("says a low balance in words in the tray, where it cannot be coloured", () => {
    const base = { costLine: "Last reply: $0.004", addCreditUrl: ADD_CREDIT_FALLBACK_URL };
    expect(publikBalanceMenuLabel({ ...base, balanceLine: "$1.84 left", isLow: false })).toBe("publik API: $1.84 left");
    expect(publikBalanceMenuLabel({ ...base, balanceLine: "$0.18 left", isLow: true })).toBe(
      "publik API: $0.18 left — running low"
    );
    expect(publikBalanceMenuLabel({ ...base, balanceLine: null, isLow: false })).toBe("publik API");
  });
});

describe("one reply, however many calls", () => {
  it("adds the query and its refinements into one reply, and ignores calls outside one", () => {
    const tally = new PublikReplyCostTally();
    tally.addACall(7_000);
    expect(tally.lastReplyChargeMicros).toBeNull();

    const reply = tally.beginAReply();
    tally.addACall(3_000);
    tally.addACall(1_500);
    expect(tally.lastReplyChargeMicros).toBe(4_500);
    tally.finishTheReply(reply);
    tally.addACall(900);
    expect(tally.lastReplyChargeMicros).toBe(4_500);
  });

  it("does not let a reply that finishes late close the one after it", () => {
    const tally = new PublikReplyCostTally();
    const earlier = tally.beginAReply();
    tally.beginAReply();
    tally.finishTheReply(earlier);
    tally.addACall(2_000);
    expect(tally.lastReplyChargeMicros).toBe(2_000);
  });
});
