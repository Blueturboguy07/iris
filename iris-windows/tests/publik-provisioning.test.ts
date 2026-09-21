import { describe, expect, it, vi } from "vitest";
import { ProvisioningSeams, provisionPublikInstall } from "../src/services/publik-provisioning";

const APP_TOKEN = "pat_iris_0123456789abcdef0123456789abcdef";
const MINTED_KEY = "pk_live_abcdef123456_0123456789abcdef0123456789abcdef";
const API_BASE = "https://publikhq.com/api/v1";

function response(status: number, body: unknown) {
  return { status, text: async () => (typeof body === "string" ? body : JSON.stringify(body)) };
}

function seams(overrides: Partial<ProvisioningSeams> = {}): ProvisioningSeams {
  let storedInstallId: string | null = null;
  let counter = 0;
  return {
    fetchImplementation: vi.fn(async () => response(201, { key: MINTED_KEY, starter_micros: 250_000 })),
    // Distinct bytes per call, so a "minted a fresh id" assertion is real.
    randomBytes: () => {
      counter += 1;
      return Uint8Array.from({ length: 16 }, (_unused, index) => (counter * 31 + index) & 0xff);
    },
    readStoredInstallId: () => storedInstallId,
    writeStoredInstallId: (installId) => {
      storedInstallId = installId;
    },
    appVersion: "0.9.11",
    osVersion: "10.0.22631",
    arch: "x64",
    ...overrides,
  };
}

describe("provisioning a publik install", () => {
  it("mints a key and remembers the install id", async () => {
    const provisioningSeams = seams();
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: provisioningSeams,
    });

    expect(outcome.kind).toBe("provisioned");
    if (outcome.kind === "provisioned") {
      expect(outcome.install.apiKey).toBe(MINTED_KEY);
      expect(provisioningSeams.readStoredInstallId()).toBe(outcome.installId);
    }
  });

  it("reuses the install id it already has", async () => {
    const sentBodies: string[] = [];
    const provisioningSeams = seams({
      fetchImplementation: async (_url, init) => {
        sentBodies.push(init.body);
        return response(201, { key: MINTED_KEY });
      },
      readStoredInstallId: () => "11111111-2222-4333-8444-555555555555",
    });

    await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: provisioningSeams,
    });

    expect(JSON.parse(sentBodies[0]).install_id).toBe("11111111-2222-4333-8444-555555555555");
  });

  it("does nothing further when a replay comes back and we already hold a key", async () => {
    const fetchImplementation = vi.fn(async () => response(200, { key: null, starter_micros: 0 }));
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: true,
      seams: seams({ fetchImplementation }),
    });

    expect(fetchImplementation).toHaveBeenCalledTimes(1);
    expect(outcome.kind).toBe("provisioned");
  });

  it("mints one fresh install id when a replay leaves it with no key at all", async () => {
    // The server will not show a key twice, so an install_id with no local key
    // is unrecoverable — a single retry with a new id is the documented fix.
    const sentBodies: string[] = [];
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: seams({
        fetchImplementation: async (_url, init) => {
          sentBodies.push(init.body);
          return sentBodies.length === 1
            ? response(200, { key: null, starter_micros: 0 })
            : response(201, { key: MINTED_KEY, starter_micros: 250_000 });
        },
      }),
    });

    expect(sentBodies).toHaveLength(2);
    const firstId = JSON.parse(sentBodies[0]).install_id;
    const secondId = JSON.parse(sentBodies[1]).install_id;
    expect(secondId).not.toBe(firstId);
    if (outcome.kind === "provisioned") expect(outcome.install.apiKey).toBe(MINTED_KEY);
  });

  it("retries exactly once, never in a loop", async () => {
    const fetchImplementation = vi.fn(async () => response(200, { key: null }));
    await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: seams({ fetchImplementation }),
    });
    expect(fetchImplementation).toHaveBeenCalledTimes(2);
  });

  it("reports a build with no app token as a state, not an error", async () => {
    const fetchImplementation = vi.fn();
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: null,
      alreadyHoldsAKey: false,
      seams: seams({ fetchImplementation }),
    });
    expect(outcome.kind).toBe("noAppToken");
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it("refuses a malformed app token without spending a round trip", async () => {
    const fetchImplementation = vi.fn();
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: "pat_iris_short",
      alreadyHoldsAKey: false,
      seams: seams({ fetchImplementation }),
    });
    expect(outcome.kind).toBe("noAppToken");
    expect(fetchImplementation).not.toHaveBeenCalled();
  });

  it("turns a refusal into advice the user can act on, without quoting the gateway", async () => {
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: seams({
        fetchImplementation: vi.fn(async () =>
          response(401, { error: { type: "invalid_app_token", message: "token revoked at 12:04" } })
        ),
      }),
    });

    expect(outcome.kind).toBe("refused");
    if (outcome.kind === "refused") {
      expect(outcome.statusCode).toBe(401);
      expect(outcome.message).toContain("paste a key");
      expect(outcome.message).not.toContain("12:04");
    }
  });

  it("survives the network being gone", async () => {
    const outcome = await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: seams({
        fetchImplementation: vi.fn(async () => {
          throw new Error("getaddrinfo ENOTFOUND");
        }),
      }),
    });
    expect(outcome.kind).toBe("networkFailure");
  });

  it("does not store an install id when provisioning failed", async () => {
    const provisioningSeams = seams({
      fetchImplementation: vi.fn(async () => response(500, "boom")),
    });
    await provisionPublikInstall({
      apiBaseUrl: API_BASE,
      appToken: APP_TOKEN,
      alreadyHoldsAKey: false,
      seams: provisioningSeams,
    });
    expect(provisioningSeams.readStoredInstallId()).toBeNull();
  });
});
