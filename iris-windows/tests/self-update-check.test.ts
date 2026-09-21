import { describe, expect, it } from "vitest";
import {
  checkForIrisUpdate,
  latestWindowsRelease,
  windowsInstallerAsset,
  type GithubReleaseLike,
} from "../src/services/self-update-check";

function release(overrides: Partial<GithubReleaseLike> = {}): GithubReleaseLike {
  return {
    draft: false,
    prerelease: false,
    tag_name: "iris-v0.9.11",
    html_url: "https://github.com/Blueturboguy07/iris/releases/tag/iris-v0.9.11",
    assets: [
      { name: "Iris-Setup.exe", browser_download_url: "https://example.com/Iris-Setup.exe" },
    ],
    ...overrides,
  };
}

function fetchReturning(releases: GithubReleaseLike[]): typeof fetch {
  return (async () =>
    new Response(JSON.stringify(releases), { status: 200 })) as unknown as typeof fetch;
}

describe("latestWindowsRelease", () => {
  it("skips drafts, prereleases, and non-iris tags", () => {
    const releases = [
      release({ tag_name: "iris-v0.10.0", draft: true }),
      release({ tag_name: "iris-v0.9.12", prerelease: true }),
      release({ tag_name: "some-other-tag" }),
      release({ tag_name: "iris-v0.9.11" }),
    ];
    expect(latestWindowsRelease(releases)?.tag_name).toBe("iris-v0.9.11");
  });

  it("returns null when nothing qualifies", () => {
    expect(latestWindowsRelease([release({ draft: true })])).toBeNull();
  });
});

describe("windowsInstallerAsset", () => {
  it("finds the .exe asset case-insensitively", () => {
    const found = windowsInstallerAsset(
      release({ assets: [{ name: "IRIS-SETUP.EXE", browser_download_url: "https://x/y.exe" }] })
    );
    expect(found?.browser_download_url).toBe("https://x/y.exe");
  });

  it("returns null when there is no .exe asset", () => {
    expect(windowsInstallerAsset(release({ assets: [{ name: "Iris.dmg" }] }))).toBeNull();
  });
});

describe("checkForIrisUpdate", () => {
  it("reports an update when the latest tag is numerically newer", async () => {
    const result = await checkForIrisUpdate(
      "0.9.10",
      fetchReturning([release({ tag_name: "iris-v0.9.11" })])
    );
    expect(result).toEqual({
      available: true,
      latestVersion: "0.9.11",
      latestTag: "iris-v0.9.11",
      downloadUrl: "https://example.com/Iris-Setup.exe",
    });
  });

  it("is not fooled by the 1.10 vs 1.9 string-order trap", async () => {
    const result = await checkForIrisUpdate(
      "0.9.9",
      fetchReturning([release({ tag_name: "iris-v0.10.0" })])
    );
    expect(result.available).toBe(true);
    expect(result.latestVersion).toBe("0.10.0");
  });

  it("reports no update when already current", async () => {
    const result = await checkForIrisUpdate(
      "0.9.11",
      fetchReturning([release({ tag_name: "iris-v0.9.11" })])
    );
    expect(result.available).toBe(false);
  });

  it("reports no update when the running version is newer than any published release", async () => {
    const result = await checkForIrisUpdate(
      "0.9.12",
      fetchReturning([release({ tag_name: "iris-v0.9.11" })])
    );
    expect(result.available).toBe(false);
  });

  it("falls back to the release page when no .exe asset is present", async () => {
    const result = await checkForIrisUpdate(
      "0.9.10",
      fetchReturning([release({ tag_name: "iris-v0.9.11", assets: [] })])
    );
    expect(result.available).toBe(true);
    expect(result.downloadUrl).toBe("https://github.com/Blueturboguy07/iris/releases/tag/iris-v0.9.11");
  });

  it("fails closed on a non-OK response", async () => {
    const fetchImpl = (async () => new Response("", { status: 500 })) as unknown as typeof fetch;
    const result = await checkForIrisUpdate("0.9.10", fetchImpl);
    expect(result.available).toBe(false);
  });

  it("fails closed when fetch throws", async () => {
    const fetchImpl = (async () => {
      throw new Error("network down");
    }) as unknown as typeof fetch;
    const result = await checkForIrisUpdate("0.9.10", fetchImpl);
    expect(result.available).toBe(false);
  });

  it("fails closed when nothing qualifies as a release", async () => {
    const result = await checkForIrisUpdate("0.9.10", fetchReturning([]));
    expect(result.available).toBe(false);
  });
});
