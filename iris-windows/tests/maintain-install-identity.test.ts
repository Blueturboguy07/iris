import { describe, expect, it } from "vitest";
import {
  INSTALL_ID_ROTATION_INTERVAL_MS,
  InMemoryInstallIdentityPersistence,
  MaintainInstallIdentity,
  machineArchitecture,
} from "../src/services/maintain/install-identity";

/**
 * The pseudonymous, 90-day-rotating install id. `nowEpochMs` and `generateUuid`
 * are both injected (per the porting spec's constructor-injection convention),
 * so the whole 90-day boundary is testable without a real clock.
 */

function fakeClock(startEpochMs: number) {
  let now = startEpochMs;
  return {
    now: () => now,
    advanceBy: (ms: number) => {
      now += ms;
    },
  };
}

function fakeUuidGenerator() {
  let count = 0;
  return () => `fake-uuid-${++count}`;
}

describe("MaintainInstallIdentity", () => {
  it("mints an id on first use and persists it", () => {
    const persistence = new InMemoryInstallIdentityPersistence();
    const clock = fakeClock(1_000_000);
    const identity = new MaintainInstallIdentity({ persistence, nowEpochMs: clock.now, generateUuid: fakeUuidGenerator() });

    const id = identity.currentInstallId();

    expect(id).toBe("fake-uuid-1");
    expect(persistence.readCurrentInstallIdentity()).toEqual({ installId: "fake-uuid-1", mintedAtEpochMs: 1_000_000 });
  });

  it("returns the same id on repeated calls inside the rotation window", () => {
    const persistence = new InMemoryInstallIdentityPersistence();
    const clock = fakeClock(0);
    const generateUuid = fakeUuidGenerator();
    const identity = new MaintainInstallIdentity({ persistence, nowEpochMs: clock.now, generateUuid });

    const first = identity.currentInstallId();
    clock.advanceBy(INSTALL_ID_ROTATION_INTERVAL_MS - 1);
    const second = identity.currentInstallId();

    expect(second).toBe(first);
  });

  it("rotates to a fresh id once the 90-day window has fully elapsed", () => {
    const persistence = new InMemoryInstallIdentityPersistence();
    const clock = fakeClock(0);
    const generateUuid = fakeUuidGenerator();
    const identity = new MaintainInstallIdentity({ persistence, nowEpochMs: clock.now, generateUuid });

    const first = identity.currentInstallId();
    clock.advanceBy(INSTALL_ID_ROTATION_INTERVAL_MS);
    const second = identity.currentInstallId();

    expect(second).not.toBe(first);
    expect(persistence.readCurrentInstallIdentity()?.installId).toBe(second);
  });

  it("keeps the existing id when the stored mint time is in the future (clock skew), rather than churning it", () => {
    const persistence = new InMemoryInstallIdentityPersistence();
    persistence.writeCurrentInstallIdentity({ installId: "already-there", mintedAtEpochMs: 10_000 });
    // "now" is earlier than mintedAtEpochMs — a negative elapsed time is still
    // less than the rotation interval, so Swift's `Date().timeIntervalSince`
    // semantics keep the existing id rather than treating skew as staleness.
    const identity = new MaintainInstallIdentity({ persistence, nowEpochMs: () => 5_000 });

    expect(identity.currentInstallId()).toBe("already-there");
  });

  it("defaults nowEpochMs and generateUuid when not supplied, producing a real-looking UUID", () => {
    const persistence = new InMemoryInstallIdentityPersistence();
    const identity = new MaintainInstallIdentity({ persistence });

    const id = identity.currentInstallId();

    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i);
    expect(identity.currentInstallId()).toBe(id);
  });
});

describe("machineArchitecture", () => {
  it("reports the running process's architecture", () => {
    expect(machineArchitecture()).toBe(process.arch);
    expect(machineArchitecture().length).toBeGreaterThan(0);
  });
});
