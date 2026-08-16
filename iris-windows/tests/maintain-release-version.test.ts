import { describe, it, expect } from "vitest";
import {
  compareReleaseVersions,
  compareParsedReleaseVersions,
  parseReleaseVersion,
} from "../src/services/maintain/release-version";

/**
 * release-version.ts is the module the whole fix ladder leans on to decide
 * whether a pooled recipe's app_version range covers the machine attempting a
 * replay (`recipeApplicabilityMatches`). A wrong direction here is actively
 * harmful — it would offer a patch that no longer matches the code — so the
 * comparator gets its own exhaustive table rather than being exercised only
 * indirectly through replay-engine. The audit flagged it as having no dedicated
 * tests; this is that file.
 */
describe("compareReleaseVersions", () => {
  it("orders by numeric value, not string order — the 1.10 vs 1.9 trap", () => {
    // The entire reason this module exists: `"1.10.0" < "1.9.0"` as strings.
    expect(compareReleaseVersions("1.10.0", "1.9.0")).toBe("newer");
    expect(compareReleaseVersions("1.9.0", "1.10.0")).toBe("older");
  });

  it("compares component by component", () => {
    expect(compareReleaseVersions("2.0.0", "1.9.9")).toBe("newer");
    expect(compareReleaseVersions("1.2.3", "1.2.4")).toBe("older");
    expect(compareReleaseVersions("1.2.3", "1.2.3")).toBe("same");
  });

  it("tolerates a leading v or V when a digit follows it", () => {
    expect(compareReleaseVersions("v1.2.3", "1.2.3")).toBe("same");
    expect(compareReleaseVersions("V1.2.3", "v1.2.3")).toBe("same");
    expect(compareReleaseVersions("v2.0.0", "v1.9.9")).toBe("newer");
  });

  it("treats a missing trailing component as zero, so 1.2 and 1.2.0 are the same release", () => {
    expect(compareReleaseVersions("1.2", "1.2.0")).toBe("same");
    expect(compareReleaseVersions("1.2.0.0", "1.2")).toBe("same");
    expect(compareReleaseVersions("1.2.1", "1.2")).toBe("newer");
  });

  it("ignores build metadata for precedence, per semver", () => {
    expect(compareReleaseVersions("1.2.0+build.7", "1.2.0")).toBe("same");
    expect(compareReleaseVersions("1.2.0+build.7", "1.2.0+build.99")).toBe("same");
  });

  it("sorts a pre-release below the release it leads up to", () => {
    expect(compareReleaseVersions("1.2.0-beta", "1.2.0")).toBe("older");
    expect(compareReleaseVersions("1.2.0", "1.2.0-beta")).toBe("newer");
    expect(compareReleaseVersions("1.2.0-beta", "1.2.0-beta")).toBe("same");
  });

  it("orders pre-release identifiers: numeric numerically, numeric below alphanumeric, more identifiers later", () => {
    // numeric identifiers compared numerically, not as strings
    expect(compareReleaseVersions("1.0.0-alpha.2", "1.0.0-alpha.10")).toBe("older");
    // a numeric identifier ranks below an alphanumeric one
    expect(compareReleaseVersions("1.0.0-1", "1.0.0-alpha")).toBe("older");
    // when all shared identifiers match, the one with more identifiers is later
    expect(compareReleaseVersions("1.2.0-beta", "1.2.0-beta.1")).toBe("older");
    // alphanumeric identifiers compare in ASCII order
    expect(compareReleaseVersions("1.0.0-alpha", "1.0.0-beta")).toBe("older");
  });

  it("compares alphanumeric identifiers in ASCII order, not locale order (uppercase before lowercase)", () => {
    // 'B' (0x42) sorts before 'a' (0x61) in ASCII — locale order could disagree.
    expect(compareReleaseVersions("1.0.0-Beta", "1.0.0-beta")).toBe("older");
  });

  it('returns "cannotBeCompared" rather than guessing when a side is not a version', () => {
    for (const unreadable of ["nightly", "latest", "1.x.3", "", "   ", "v", "version", "1.2.0-", "1.2..0", "1.-2.0"]) {
      expect(compareReleaseVersions(unreadable, "1.0.0")).toBe("cannotBeCompared");
      expect(compareReleaseVersions("1.0.0", unreadable)).toBe("cannotBeCompared");
    }
  });

  it('rejects non-ASCII decimal digits (they parse differently than they look) as "cannotBeCompared"', () => {
    // Arabic-Indic digits ٥ (5). `/^\d+$/` unanchored would accept these.
    expect(compareReleaseVersions("1.٥.0", "1.5.0")).toBe("cannotBeCompared");
  });

  it("keeps the leading token when the char after v/V is not a digit, so 'version' stays unreadable", () => {
    // If the `v` were dropped unconditionally this would parse as "ersion".
    expect(parseReleaseVersion("version")).toBeUndefined();
    expect(parseReleaseVersion("vNext")).toBeUndefined();
  });
});

describe("parseReleaseVersion", () => {
  it("parses release components and pre-release identifiers, discarding build metadata", () => {
    expect(parseReleaseVersion("v1.2.3")).toEqual({ numericComponents: [1, 2, 3], preReleaseIdentifiers: [] });
    expect(parseReleaseVersion("1.2.0-beta.1")).toEqual({
      numericComponents: [1, 2, 0],
      preReleaseIdentifiers: ["beta", "1"],
    });
    expect(parseReleaseVersion("1.2.0-beta.1+build.7")).toEqual({
      numericComponents: [1, 2, 0],
      preReleaseIdentifiers: ["beta", "1"],
    });
  });

  it("returns undefined for anything with a non-numeric release component", () => {
    expect(parseReleaseVersion("1.x.3")).toBeUndefined();
    expect(parseReleaseVersion("latest")).toBeUndefined();
    expect(parseReleaseVersion("")).toBeUndefined();
    expect(parseReleaseVersion("1.2.0-")).toBeUndefined();
    expect(parseReleaseVersion("1.2.0-beta.")).toBeUndefined();
  });
});

describe("compareParsedReleaseVersions", () => {
  it("lets a caller parse once and compare against several ranges", () => {
    const current = parseReleaseVersion("1.4.0");
    const lower = parseReleaseVersion("1.0.0");
    const upper = parseReleaseVersion("2.0.0");
    expect(current).toBeDefined();
    expect(lower).toBeDefined();
    expect(upper).toBeDefined();
    if (current && lower && upper) {
      expect(compareParsedReleaseVersions(current, lower)).toBe("newer");
      expect(compareParsedReleaseVersions(current, upper)).toBe("older");
      expect(compareParsedReleaseVersions(current, current)).toBe("same");
    }
  });
});
