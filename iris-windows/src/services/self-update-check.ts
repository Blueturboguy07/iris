/**
 * self-update-check.ts
 *
 * Iris has no update-awareness of its own — Squirrel.Windows packages the
 * installer and nothing checks whether a newer Iris exists. This is the pure
 * decision logic for that: given the running version and the public GitHub
 * releases feed, is there a newer build, and where does a reader get it.
 *
 * `update.electronjs.org` (Electron's own free update service) was considered
 * first, since Blueturboguy07/iris is now public and its releases already
 * carry the RELEASES/nupkg assets a Squirrel `autoUpdater` needs. It does not
 * fit: its server drops any release whose `tag_name` fails `semver.valid()`
 * (confirmed by reading `src/updates.ts` in electron/update.electronjs.org),
 * and this repo tags releases `iris-v0.9.11` — a prefix `semver.valid` does
 * not accept — so every release would be silently invisible to it. Renaming
 * the tag scheme would fix that, but the release-trigger workflow and the
 * publik download broker both key off `iris-v*`, and the macOS side likely
 * will too once its appcast lands — too cross-cutting to change unilaterally
 * here. This checks the same public GitHub Releases API directly instead, the
 * same one `app/api/iris/download` on publikhq.com reads.
 *
 * Deliberately independent of that download broker: a reader running this
 * check already has Iris, and the broker's public-download gate
 * (`IRIS_PUBLIC_DOWNLOAD_ENABLED`) governs new acquisition, not updating an
 * existing install — an existing user's update check must not go dark just
 * because that gate is closed.
 */
import { compareReleaseVersions } from "./maintain/release-version";

export interface GithubReleaseAssetLike {
  name?: string;
  browser_download_url?: string;
}

export interface GithubReleaseLike {
  draft?: boolean;
  prerelease?: boolean;
  tag_name?: string;
  html_url?: string;
  assets?: GithubReleaseAssetLike[];
}

export interface SelfUpdateCheckResult {
  available: boolean;
  /** The tag with its "iris-v" prefix stripped, e.g. "0.9.11". */
  latestVersion: string | null;
  /** The release tag itself, e.g. "iris-v0.9.11" — used to dedupe announcements. */
  latestTag: string | null;
  /** The Windows installer's direct download URL, or the release page if no
   *  `.exe` asset matched (still lets a reader get there by hand). */
  downloadUrl: string | null;
}

const RELEASES_API = "https://api.github.com/repos/Blueturboguy07/iris/releases?per_page=20";

const NOT_AVAILABLE: SelfUpdateCheckResult = {
  available: false,
  latestVersion: null,
  latestTag: null,
  downloadUrl: null,
};

/** The newest published, non-draft, non-prerelease Iris release — GitHub's
 *  releases API already returns them newest-first, so the first match wins. */
export function latestWindowsRelease(releases: GithubReleaseLike[]): GithubReleaseLike | null {
  return (
    releases.find(
      (release) => !release.draft && !release.prerelease && release.tag_name?.startsWith("iris-v")
    ) ?? null
  );
}

export function windowsInstallerAsset(release: GithubReleaseLike): GithubReleaseAssetLike | null {
  return release.assets?.find((asset) => asset.name?.toLowerCase().endsWith(".exe")) ?? null;
}

/**
 * Compares the running app's version against the latest published release.
 * `currentVersion` is `app.getVersion()` — read from package.json at build
 * time, no "iris-v" prefix — compared against the tag with that prefix
 * stripped, via the same numeric comparator `maintain`'s recipe-applicability
 * check already uses for guide versions (so "1.10.0" never sorts before
 * "1.9.0" the way a plain string compare would).
 */
export async function checkForIrisUpdate(
  currentVersion: string,
  fetchImpl: typeof fetch = fetch
): Promise<SelfUpdateCheckResult> {
  let releases: GithubReleaseLike[];
  try {
    const response = await fetchImpl(RELEASES_API, {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "Iris-Windows-Self-Update",
      },
    });
    if (!response.ok) return NOT_AVAILABLE;
    releases = (await response.json()) as GithubReleaseLike[];
  } catch {
    return NOT_AVAILABLE;
  }

  const release = latestWindowsRelease(releases);
  if (!release?.tag_name) return NOT_AVAILABLE;

  const latestVersion = release.tag_name.slice("iris-v".length);
  if (compareReleaseVersions(latestVersion, currentVersion) !== "newer") return NOT_AVAILABLE;

  const asset = windowsInstallerAsset(release);
  return {
    available: true,
    latestVersion,
    latestTag: release.tag_name,
    downloadUrl: asset?.browser_download_url ?? release.html_url ?? null,
  };
}
