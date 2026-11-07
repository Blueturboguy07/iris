import { describe, expect, it, vi } from "vitest";
import {
  AccountLinkSeams,
  AccountLinkWallet,
  buildInstallClaimRequest,
  buildInstallRevokeRequest,
  claimCodeFromClaimUrl,
  forgetTheAccountLink,
  linkThisComputerToTheAccount,
  needsAnAccountLinkInstall,
  telemetryKey,
} from "../src/services/publik-account-link";
import { buildInstallProvisioningRequest } from "../src/services/publik-api";
import { parseBalanceResponse } from "../src/services/publik-balance";
import { provisionPublikInstall } from "../src/services/publik-provisioning";

const APP_TOKEN = "pat_iris_0123456789abcdef0123456789abcdef";
const API_BASE = "https://publikhq.com/api/v1";
const FOREIGN_BASE = "https://example.com/api/v1";
const SESSION = "eyJhbGciOiJIUzI1NiJ9.not-a-real-session";
const PUBLIK_API_KEY = "pk_live_abcdef123456_0123456789abcdef0123456789abcdef";
const LINK_KEY = "pk_live_linklink1234_fedcba9876543210fedcba9876543210";
const IRIS_INSTALL = { installId: "7d3c2a4e-58b1-4f6e-9a0c-2b8f1e6d9c41", appSlug: "iris" };
/** What `GET /balance` says for a developer key pasted from the dashboard. */
const DASHBOARD_KEY_WALLET: AccountLinkWallet = {
  claimState: "claimed",
  claimUrl: null,
  topUpUrl: "https://publikhq.com/dashboard/api/add",
  installId: null,
  appSlug: null,
};

type SentRequest = { url: string; method: string; headers: Record<string, string>; body: string };

function response(status: number, body: unknown = "") {
  return { status, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) };
}

/** Seams with an in-memory link key and link install id. */
function linkSeams(options: {
  publikApiKey?: string | null;
  linkKey?: string | null;
  wallets?: (AccountLinkWallet | null)[];
  respond?: (request: SentRequest) => { status: number; text(): Promise<string> };
}) {
  const sent: SentRequest[] = [];
  let storedLinkKey = options.linkKey ?? null;
  let storedLinkInstallId: string | null = null;
  const wallets = [...(options.wallets ?? [])];
  let byteCounter = 0;
  const readWallet = vi.fn(async () => (wallets.length > 1 ? wallets.shift()! : wallets[0] ?? null));
  const seams: AccountLinkSeams = {
    fetchImplementation: async (url, init) => {
      const request = { url, ...init };
      sent.push(request);
      return options.respond ? options.respond(request) : response(201, { key: LINK_KEY });
    },
    readPublikApiKey: () => options.publikApiKey ?? null,
    readAccountLinkKey: () => storedLinkKey,
    writeAccountLinkKey: (key) => {
      storedLinkKey = key;
    },
    readWallet,
    linkInstallProvisioning: {
      randomBytes: () => {
        byteCounter += 1;
        return Uint8Array.from({ length: 16 }, (_unused, index) => (byteCounter * 31 + index) & 0xff);
      },
      readStoredInstallId: () => storedLinkInstallId,
      writeStoredInstallId: (installId) => {
        storedLinkInstallId = installId;
      },
      appVersion: "0.9.17",
      osVersion: "10.0.22631",
      arch: "x64",
    },
  };
  return {
    seams,
    sent,
    readWallet,
    linkKey: () => storedLinkKey,
    linkInstallId: () => storedLinkInstallId,
  };
}

describe("claim codes", () => {
  it("reads the code from the claim path", () => {
    expect(claimCodeFromClaimUrl("https://publikhq.com/claim/ABCD-EFGH")).toBe("ABCD-EFGH");
  });

  it("reads the code from a code query and upper-cases it", () => {
    expect(claimCodeFromClaimUrl("https://publikhq.com/claim?code=wxyz-2345")).toBe("WXYZ-2345");
  });

  it("refuses anything that is not a claim code", () => {
    expect(claimCodeFromClaimUrl(null)).toBeNull();
    expect(claimCodeFromClaimUrl("")).toBeNull();
    expect(claimCodeFromClaimUrl("not a url")).toBeNull();
    expect(claimCodeFromClaimUrl("https://publikhq.com/dashboard/api")).toBeNull();
    // The alphabet leaves out I, O, 0 and 1.
    expect(claimCodeFromClaimUrl("https://publikhq.com/claim/ABCD-EF0H")).toBeNull();
  });
});

describe("claiming the publik API install on sign-in", () => {
  it("claims an anonymous install with the session as the bearer, then re-reads the wallet", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [
        { claimState: "anonymous", claimUrl: "https://publikhq.com/claim/ABCD-EFGH", topUpUrl: null, ...IRIS_INSTALL },
        { claimState: "claimed", claimUrl: null, topUpUrl: "https://publikhq.com/dashboard/api/add", ...IRIS_INSTALL },
      ],
      respond: () => response(200, { claimed: true }),
    });

    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });

    expect(outcome.kind).toBe("claimedTheExistingInstall");
    expect(harness.sent).toHaveLength(1);
    const [claim] = harness.sent;
    expect(claim.url).toBe("https://publikhq.com/api/v1/installs/claim");
    expect(claim.method).toBe("POST");
    expect(claim.headers.Authorization).toBe(`Bearer ${SESSION}`);
    expect(claim.headers["x-api-key"]).toBeUndefined();
    expect(JSON.parse(claim.body)).toEqual({ claim_code: "ABCD-EFGH", confirm: true });
    expect(harness.readWallet).toHaveBeenCalledTimes(2);
    // No link install is minted when the publik API key exists.
    expect(harness.linkKey()).toBeNull();
  });

  it("falls back to the top-up link for the claim code", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [
        { claimState: "anonymous", claimUrl: null, topUpUrl: "https://publikhq.com/claim/WXYZ-2345", ...IRIS_INSTALL },
      ],
      respond: () => response(200),
    });
    await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(JSON.parse(harness.sent[0].body).claim_code).toBe("WXYZ-2345");
  });

  it("sends nothing when the install is already linked", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [{ claimState: "claimed", claimUrl: null, topUpUrl: null, ...IRIS_INSTALL }],
    });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("existingInstallWasAlreadyLinked");
    expect(harness.sent).toHaveLength(0);
  });

  it("does nothing at all when the wallet cannot be read", async () => {
    const harness = linkSeams({ publikApiKey: PUBLIK_API_KEY, wallets: [null] });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("walletUnreadable");
    expect(harness.sent).toHaveLength(0);
    expect(harness.linkKey()).toBeNull();
  });

  it("reports a refused claim without throwing", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [
        { claimState: "anonymous", claimUrl: "https://publikhq.com/claim/ABCD-EFGH", topUpUrl: null, ...IRIS_INSTALL },
      ],
      respond: () => response(404, { error: { code: "not_claimable" } }),
    });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome).toEqual({ kind: "refused", statusCode: 404 });
  });
});

describe("a pasted dashboard key", () => {
  it("is linked by a link-install mint on sign-in, not by a claim", async () => {
    const harness = linkSeams({ publikApiKey: PUBLIK_API_KEY, wallets: [DASHBOARD_KEY_WALLET] });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });

    expect(outcome.kind).toBe("mintedAnAccountLinkInstall");
    expect(harness.readWallet).toHaveBeenCalledTimes(1);
    expect(harness.sent).toHaveLength(1);
    const [mint] = harness.sent;
    expect(mint.url).toBe("https://publikhq.com/api/v1/installs");
    expect(mint.headers.Authorization).toBe(`Bearer ${SESSION}`);
    expect("disclosure_version" in JSON.parse(mint.body)).toBe(false);
    expect(harness.sent.some((request) => request.url.endsWith("/installs/claim"))).toBe(false);
    expect(harness.linkKey()).toBe(LINK_KEY);
  });

  it("is treated the same when its key was minted for another app", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [{ ...DASHBOARD_KEY_WALLET, installId: IRIS_INSTALL.installId, appSlug: "cue" }],
    });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("mintedAnAccountLinkInstall");
    expect(harness.linkKey()).toBe(LINK_KEY);
  });

  it("does not mint again when a link key is already held", async () => {
    const harness = linkSeams({ publikApiKey: PUBLIK_API_KEY, linkKey: LINK_KEY, wallets: [DASHBOARD_KEY_WALLET] });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("alreadyHadAnAccountLinkInstall");
    expect(harness.sent).toHaveLength(0);
  });

  it("an Iris-minted key with an install id is claimed, and nothing is minted", async () => {
    const harness = linkSeams({
      publikApiKey: PUBLIK_API_KEY,
      wallets: [{ claimState: "anonymous", claimUrl: "https://publikhq.com/claim/ABCD-EFGH", topUpUrl: null, ...IRIS_INSTALL }],
      respond: () => response(200),
    });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("claimedTheExistingInstall");
    expect(harness.sent.map((request) => request.url)).toEqual(["https://publikhq.com/api/v1/installs/claim"]);
    expect(harness.linkKey()).toBeNull();
  });

  it("decides from the key and the wallet's install", () => {
    expect(needsAnAccountLinkInstall(false, null)).toBe(true);
    expect(needsAnAccountLinkInstall(true, { installId: null, appSlug: null })).toBe(true);
    expect(needsAnAccountLinkInstall(true, { installId: "", appSlug: "iris" })).toBe(true);
    expect(needsAnAccountLinkInstall(true, { installId: IRIS_INSTALL.installId, appSlug: "cue" })).toBe(true);
    expect(needsAnAccountLinkInstall(true, IRIS_INSTALL)).toBe(false);
  });

  it("is told apart by the install_id and app_slug that GET /balance sends", () => {
    const irisWallet = parseBalanceResponse(
      JSON.stringify({ balance_micros: 0, claim_state: "anonymous", install_id: IRIS_INSTALL.installId, app_slug: "iris" })
    );
    expect(irisWallet?.installId).toBe(IRIS_INSTALL.installId);
    expect(irisWallet?.appSlug).toBe("iris");
    const dashboardWallet = parseBalanceResponse(
      JSON.stringify({ balance_micros: 1_843_210, claim_state: "claimed", install_id: null, app_slug: null })
    );
    expect(dashboardWallet?.installId).toBeNull();
    expect(dashboardWallet?.appSlug).toBeNull();
    expect(dashboardWallet?.balanceMicros).toBe(1_843_210);
  });
});

describe("a user-bound mint", () => {
  const baseRequest = {
    appToken: APP_TOKEN,
    appSlug: "iris",
    appVersion: "0.9.17",
    osVersion: "10.0.22631",
    arch: "x64",
    installId: "11111111-2222-4333-8444-555555555555",
  };

  it("carries the session as the bearer and keeps the app token in the body", () => {
    const request = buildInstallProvisioningRequest(API_BASE, { ...baseRequest, accountAccessToken: SESSION });
    expect(request.headers.Authorization).toBe(`Bearer ${SESSION}`);
    const body = JSON.parse(request.body);
    expect(body.app_token).toBe(APP_TOKEN);
    expect(body.disclosure_version).toBeDefined();
  });

  it("sends no Authorization when signed out", () => {
    const request = buildInstallProvisioningRequest(API_BASE, baseRequest);
    expect(request.headers.Authorization).toBeUndefined();
  });

  it("never sends the session to a host that is not publik", () => {
    const request = buildInstallProvisioningRequest(FOREIGN_BASE, { ...baseRequest, accountAccessToken: SESSION });
    expect(request.headers.Authorization).toBeUndefined();
  });

  it("leaves the disclosure version out when asked", () => {
    const request = buildInstallProvisioningRequest(API_BASE, { ...baseRequest, omitDisclosureVersion: true });
    expect("disclosure_version" in JSON.parse(request.body)).toBe(false);
  });

  it("puts the session on the publik API mint after the disclosure while signed in", async () => {
    const sent: SentRequest[] = [];
    await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      accountAccessToken: SESSION,
      seams: {
        fetchImplementation: async (url, init) => {
          sent.push({ url, ...init });
          return response(201, { key: PUBLIK_API_KEY });
        },
        randomBytes: () => new Uint8Array(16).fill(7),
        readStoredInstallId: () => null,
        writeStoredInstallId: () => undefined,
        appVersion: "0.9.17",
        osVersion: "10.0.22631",
        arch: "x64",
      },
    });
    expect(sent[0].headers.Authorization).toBe(`Bearer ${SESSION}`);
    expect(JSON.parse(sent[0].body).disclosure_version).toBeDefined();
  });
});

describe("the link-key mint when there is no publik API key", () => {
  it("mints a user-bound install without a disclosure version and keeps its key apart", async () => {
    const harness = linkSeams({});
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });

    expect(outcome.kind).toBe("mintedAnAccountLinkInstall");
    expect(harness.sent).toHaveLength(1);
    const [mint] = harness.sent;
    expect(mint.url).toBe("https://publikhq.com/api/v1/installs");
    expect(mint.headers.Authorization).toBe(`Bearer ${SESSION}`);
    const body = JSON.parse(mint.body);
    expect(body.app_token).toBe(APP_TOKEN);
    expect("disclosure_version" in body).toBe(false);
    expect(body.install_id).toBe(harness.linkInstallId());
    expect(harness.linkKey()).toBe(LINK_KEY);
    expect(harness.readWallet).not.toHaveBeenCalled();
  });

  it("mints one fresh id after a replay, and only one", async () => {
    let calls = 0;
    const harness = linkSeams({
      respond: () => {
        calls += 1;
        return calls === 1 ? response(200, { key: null }) : response(201, { key: LINK_KEY });
      },
    });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("mintedAnAccountLinkInstall");
    expect(harness.sent).toHaveLength(2);
    const firstId = JSON.parse(harness.sent[0].body).install_id;
    const secondId = JSON.parse(harness.sent[1].body).install_id;
    expect(secondId).not.toBe(firstId);
    expect(harness.linkKey()).toBe(LINK_KEY);
  });

  it("does nothing when a link key is already held", async () => {
    const harness = linkSeams({ linkKey: LINK_KEY });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("alreadyHadAnAccountLinkInstall");
    expect(harness.sent).toHaveLength(0);
  });

  it("does nothing in a build with no app token", async () => {
    const harness = linkSeams({});
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: null,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("noAppToken");
    expect(harness.sent).toHaveLength(0);
  });

  it("never sends the session to a gateway that is not publik", async () => {
    const harness = linkSeams({ publikApiKey: PUBLIK_API_KEY });
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: FOREIGN_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("notAPublikHost");
    expect(harness.sent).toHaveLength(0);
    expect(buildInstallClaimRequest(FOREIGN_BASE, "ABCD-EFGH", SESSION)).toBeNull();
  });

  it("reports a network failure without throwing", async () => {
    const harness = linkSeams({});
    harness.seams.fetchImplementation = async () => {
      throw new Error("offline");
    };
    const outcome = await linkThisComputerToTheAccount({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      accountAccessToken: SESSION,
      seams: harness.seams,
    });
    expect(outcome.kind).toBe("networkFailure");
    expect(harness.linkKey()).toBeNull();
  });
});

describe("the usage-count key", () => {
  it("prefers the link key, then the publik API key, then nothing", () => {
    expect(telemetryKey({ accountLinkKey: LINK_KEY, publikApiKey: PUBLIK_API_KEY })).toBe(LINK_KEY);
    expect(telemetryKey({ accountLinkKey: null, publikApiKey: PUBLIK_API_KEY })).toBe(PUBLIK_API_KEY);
    expect(telemetryKey({ accountLinkKey: "", publikApiKey: PUBLIK_API_KEY })).toBe(PUBLIK_API_KEY);
    expect(telemetryKey({ accountLinkKey: LINK_KEY, publikApiKey: null })).toBe(LINK_KEY);
    expect(telemetryKey({ accountLinkKey: null, publikApiKey: null })).toBeNull();
  });
});

describe("signing out", () => {
  function forgetSeams(linkKey: string | null, respond: () => Promise<{ status: number; text(): Promise<string> }>) {
    const events: string[] = [];
    const sent: SentRequest[] = [];
    let storedLinkKey = linkKey;
    return {
      events,
      sent,
      linkKey: () => storedLinkKey,
      seams: {
        fetchImplementation: async (url: string, init: { method: string; headers: Record<string, string>; body: string }) => {
          events.push("revoke");
          sent.push({ url, ...init });
          return respond();
        },
        readAccountLinkKey: () => storedLinkKey,
        deleteAccountLinkKey: () => {
          events.push("delete");
          storedLinkKey = null;
        },
        forgetLinkInstallId: () => {
          events.push("forgetId");
        },
      },
    };
  }

  it("deletes the link key first, then revokes its install with that key", async () => {
    const harness = forgetSeams(LINK_KEY, async () => response(204));
    const revoked = await forgetTheAccountLink({ apiBaseUrl: API_BASE, seams: harness.seams });

    expect(revoked).toBe(true);
    expect(harness.events).toEqual(["delete", "forgetId", "revoke"]);
    expect(harness.linkKey()).toBeNull();
    const [revoke] = harness.sent;
    expect(revoke.url).toBe("https://publikhq.com/api/v1/installs/revoke");
    expect(revoke.method).toBe("POST");
    expect(revoke.headers["x-api-key"]).toBe(LINK_KEY);
    expect(revoke.headers.Authorization).toBeUndefined();
    expect(revoke.body).toBe("");
  });

  it("still deletes the key when the revoke cannot reach publik", async () => {
    const harness = forgetSeams(LINK_KEY, async () => {
      throw new Error("offline");
    });
    const revoked = await forgetTheAccountLink({ apiBaseUrl: API_BASE, seams: harness.seams });
    expect(revoked).toBe(false);
    expect(harness.linkKey()).toBeNull();
  });

  it("sends nothing when there is no link key", async () => {
    const harness = forgetSeams(null, async () => response(204));
    const revoked = await forgetTheAccountLink({ apiBaseUrl: API_BASE, seams: harness.seams });
    expect(revoked).toBe(false);
    expect(harness.sent).toHaveLength(0);
  });

  it("never sends the link key to a host that is not publik", async () => {
    const harness = forgetSeams(LINK_KEY, async () => response(204));
    await forgetTheAccountLink({ apiBaseUrl: FOREIGN_BASE, seams: harness.seams });
    expect(harness.sent).toHaveLength(0);
    expect(harness.linkKey()).toBeNull();
    expect(buildInstallRevokeRequest(FOREIGN_BASE, LINK_KEY)).toBeNull();
  });
});
