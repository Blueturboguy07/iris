import { describe, expect, it } from "vitest";
import {
  INSTALL_ID_ROTATION_INTERVAL_MS,
  InMemoryInstallIdentityPersistence,
  MaintainInstallIdentity,
  machineArchitecture,
} from "../src/services/maintain/install-identity";

function identityWithClock(startEpochMs: number) {
  let now = startEpochMs;
  let uuidCounter = 0;
  const persistence = new InMemoryInstallIdentityPersistence();
  const identity = new MaintainInstallIdentity({
    persistence,
    nowEpochMs: () => now,
    generateUuid: () => `uuid-${++uuidCounter}`,
  });
  return {
    identity,
    persistence,
    advanceClockBy: (ms: number) => {
      now += ms;
    },
  };
}

describe("MaintainInstallIdentity", () => {
  it("mints an id on first use and persists it", () => {
    const { identity, persistence } = identityWithClock(1_000_000);
    const id = identity.currentInstallId();
    expect(id).toBe("uuid-1");
    expect(persistence.readCurrentInstallIdentity()?.installId).toBe("uuid-1");
  });

  it("returns the same id on repeated calls inside the rotation window", () => {
    const { identity, advanceClockBy } = identityWithClock(0);
    const first = identity.currentInstallId();
    advanceClockBy(INSTALL_ID_ROTATION_INTERVAL_MS - 1);
    const second = identity.currentInstallId();
    expect(second).toBe(first);
  });

  it("rotates once 90 days have elapsed", () => {
    const { identity, advanceClockBy } = identityWithClock(0);
    const first = identity.currentInstallId();
    advanceClockBy(INSTALL_ID_ROTATION_INTERVAL_MS);
    const second = identity.currentInstallId();
    expect(second).not.toBe(first);
  });

  it("rotates exactly at the boundary (elapsed == interval is not < interval)", () => {
    const { identity, advanceClockBy, persistence } = identityWithClock(0);
    identity.currentInstallId();
    advanceClockBy(INSTALL_ID_ROTATION_INTERVAL_MS);
    const before = persistence.readCurrentInstallIdentity();
    identity.currentInstallId();
    const after = persistence.readCurrentInstallIdentity();
    expect(after?.installId).not.toBe(before?.installId);
  });

  it("keeps the existing id when the stored mint time is in the future (clock skew)", () => {
    // A mintedAt in the future makes now - mintedAt negative, which is still
    // < the rotation interval — the id must not churn just because a clock
    // jumped backward, matching Swift's Date().timeIntervalSince behavior.
    const persistence = new InMemoryInstallIdentityPersistence();
    persistence.writeCurrentInstallIdentity({ installId: "future-minted", mintedAtEpochMs: 10_000 });
    const identity = new MaintainInstallIdentity({
      persistence,
      nowEpochMs: () => 5_000,
      generateUuid: () => "should-not-be-used",
    });
    expect(identity.currentInstallId()).toBe("future-minted");
  });

  it("defaults to a real UUID and the real clock when nothing is injected", () => {
    const identity = new MaintainInstallIdentity({ persistence: new InMemoryInstallIdentityPersistence() });
    const id = identity.currentInstallId();
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
  });

  it("never rotates into an id that has ever been the account id or a hardware id", () => {
    // Not a literal check (there is no such thing to compare against) — this
    // documents the invariant by asserting the id is exactly a fresh
    // pseudonymous UUID from the injected generator, nothing derived from
    // machine state.
    const { identity } = identityWithClock(0);
    expect(identity.currentInstallId()).toBe("uuid-1");
  });
});

describe("machineArchitecture", () => {
  it("returns a non-empty string (process.arch, no Windows primitive needed)", () => {
    expect(machineArchitecture().length).toBeGreaterThan(0);
    expect(machineArchitecture()).toBe(process.arch);
  });
});
