import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { APP_SLUG, APP_VERSION, USES_AI, gateScreen, type Wallet } from "../src/main/publik";

/**
 * The publik module (src/main/publik.ts) is a copy of
 * publikhq.com/sdk/publik.ts.md. The publik scan reads its slug, and every
 * publik app shows the gate with the same words. These tests pin both. They
 * read no home folder and reach no network: `gateScreen()` is pure.
 */

/** The exact words of the gate, from publik's tests/publik-module-gate.test.ts. */
const WORDS = {
  title: "Sign in with publik",
  signInBody:
    "This app uses your publik account. Click Sign in with publik, then sign in in your browser. This window continues when you are signed in.",
  signInButton: "Sign in with publik",
  waiting: "Waiting for you to sign in in your browser.",
  unreachable: "publik is not reachable. Check your connection.",
  retry: "Retry",
  chooseTitle: "Choose how to pay for AI",
  chooseBody: "This app uses AI. Get a publik plan, or use your own key.",
  getPlan: "Get a plan",
  ownKey: "Use my own key",
  connectTitle: "Connect your plan",
  connectBody: "Connect it to use AI in this app, or use your own key.",
  connect: "Connect your plan",
  signedInAs: "You are signed in as @",
  signedIn: "You are signed in to publik.",
} as const;

const links = { claim_url: "https://publikhq.com/claim/abc", top_up_url: "https://publikhq.com/wallet?top_up=1", linked_at: null };
const anonymous: Wallet = { claim_state: "anonymous", account: null, plan: { kind: "none", label: null }, balance_micros: 0, ...links };
const claimedEmpty: Wallet = { claim_state: "claimed", account: { handle: "mann" }, plan: { kind: "none", label: null }, balance_micros: 0, ...links };
const claimedPlan: Wallet = { claim_state: "claimed", account: { handle: "mann" }, plan: { kind: "plan", label: "Plus" }, balance_micros: 0, ...links };
const claimedBalance: Wallet = { claim_state: "claimed", account: null, plan: { kind: "pack", label: null }, balance_micros: 1_500_000, ...links };

describe("the publik module's constants", () => {
  it("names this app's listing slug as a literal, for the publik scan", () => {
    expect(APP_SLUG).toBe("iris");
  });

  it("carries the release version from package.json", () => {
    const packageVersion = (JSON.parse(readFileSync(join(__dirname, "..", "package.json"), "utf-8")) as { version: string }).version;
    expect(APP_VERSION).toBe(packageVersion);
  });

  it("says the app uses AI, so the gate asks how to pay for it", () => {
    expect(USES_AI).toBe(true);
  });
});

describe("the gate's screens, word for word", () => {
  it("shows Sign in with publik with one button", () => {
    expect(gateScreen("sign_in", anonymous)).toEqual({
      id: "sign_in",
      title: WORDS.title,
      body: WORDS.signInBody,
      note: null,
      buttons: [{ action: "sign_in", label: WORDS.signInButton }],
    });
  });

  it("carries the waiting note under the sign-in screen", () => {
    expect(gateScreen("sign_in", anonymous, WORDS.waiting).note).toBe(WORDS.waiting);
  });

  it("says publik is not reachable, with Retry", () => {
    expect(gateScreen("unreachable", null)).toEqual({
      id: "unreachable",
      title: WORDS.title,
      body: WORDS.unreachable,
      note: null,
      buttons: [{ action: "retry", label: WORDS.retry }],
    });
  });

  it("shows the server's own message in place of the unreachable line when there is one", () => {
    const screen = gateScreen("unreachable", null, null, "This key is not valid.");
    expect(screen.body).toBe("This key is not valid.");
    expect(screen.buttons).toEqual([{ action: "retry", label: WORDS.retry }]);
  });

  it("asks how to pay for AI when there is no plan and no balance", () => {
    expect(gateScreen("choose", claimedEmpty)).toEqual({
      id: "choose",
      title: WORDS.chooseTitle,
      body: `${WORDS.signedInAs}mann. ${WORDS.chooseBody}`,
      note: null,
      buttons: [
        { action: "get_plan", label: WORDS.getPlan },
        { action: "own_key", label: WORDS.ownKey },
      ],
    });
  });

  it("names no handle when the wallet has none", () => {
    expect(gateScreen("choose", { ...claimedEmpty, account: null }).body).toBe(`${WORDS.signedIn} ${WORDS.chooseBody}`);
  });

  it("offers Connect your plan when the plan is Plus", () => {
    expect(gateScreen("choose", claimedPlan)).toEqual({
      id: "choose",
      title: WORDS.connectTitle,
      body: `${WORDS.signedInAs}mann. Your plan: Plus. ${WORDS.connectBody}`,
      note: null,
      buttons: [
        { action: "connect", label: WORDS.connect },
        { action: "own_key", label: WORDS.ownKey },
      ],
    });
  });

  it("offers Connect your plan with the balance in dollars when there is a pack", () => {
    const screen = gateScreen("choose", claimedBalance);
    expect(screen.title).toBe(WORDS.connectTitle);
    expect(screen.body).toBe(`${WORDS.signedIn} Your balance: $1.50. ${WORDS.connectBody}`);
  });
});
