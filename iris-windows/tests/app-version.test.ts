import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { compareReleaseVersions } from "../src/services/maintain/release-version";

/**
 * `app.getVersion()` in the shipped exe is this package.json's `version`, and
 * the tray's "Update to Iris x.y.z" notice compares it with the newest
 * `iris-v*` release (services/self-update-check.ts). Until 0.9.15 it said
 * 0.1.0 in every release, so every Windows install — including one already on
 * the newest build — was told an update was waiting.
 *
 * Releases are cut for both platforms from one commit and one tag, so the
 * version here must be the macOS app's `MARKETING_VERSION`. Bump both in the
 * `Iris X.Y.Z` commit; this fails the suite (and iris-windows.yml) the moment
 * they drift. `iris-release.yml` separately refuses a tag that disagrees.
 */

const WINDOWS_APP_DIR = join(__dirname, "..");
const MACOS_PROJECT_FILE = join(
  WINDOWS_APP_DIR,
  "..",
  "iris-macos",
  "leanring-buddy.xcodeproj",
  "project.pbxproj"
);

function windowsPackageVersion(): string {
  return (JSON.parse(readFileSync(join(WINDOWS_APP_DIR, "package.json"), "utf-8")) as { version: string }).version;
}

/** The MARKETING_VERSION of each app-target build configuration (the test
 *  targets sit at 1.0 and are not the product). */
function macosAppMarketingVersions(): string[] {
  const project = readFileSync(MACOS_PROJECT_FILE, "utf-8");
  return [
    ...project.matchAll(/MARKETING_VERSION = ([0-9.]+);\s*PRODUCT_BUNDLE_IDENTIFIER = com\.publikhq\.iris;/g),
  ].map((match) => match[1]!);
}

describe("the Windows app's version", () => {
  it("finds both macOS app-target versions (Debug and Release)", () => {
    const versions = macosAppMarketingVersions();
    expect(versions).toHaveLength(2);
    expect(new Set(versions).size).toBe(1);
  });

  it("is the same release version as the macOS app", () => {
    expect(windowsPackageVersion()).toBe(macosAppMarketingVersions()[0]);
  });

  it("is a real release version, never the 0.1.0 placeholder every release before 0.9.15 shipped with", () => {
    expect(["same", "newer"]).toContain(compareReleaseVersions(windowsPackageVersion(), "0.9.14"));
  });

  it("matches the package-lock.json the installer is built from", () => {
    const lock = JSON.parse(readFileSync(join(WINDOWS_APP_DIR, "package-lock.json"), "utf-8")) as {
      version: string;
      packages: Record<string, { version?: string }>;
    };
    expect(lock.version).toBe(windowsPackageVersion());
    expect(lock.packages[""]?.version).toBe(windowsPackageVersion());
  });
});
