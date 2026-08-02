/**
 * external-links.ts
 *
 * The one canonical answer to "may a guide step send the reader here?".
 *
 * This list is the Windows copy of `allowed_external_host` in
 * `iris-desktop/src-tauri/src/main.rs` and of `SAFE_EXTERNAL_HOSTS` in
 * `iris-desktop/ui/app.js`. All three must stay in step with `lib/iris-guides.ts`;
 * a host missing from here is a step the reader cannot follow.
 *
 * The reason this module returns a *classification* rather than a boolean is the
 * bug iris-desktop 0.1.4 fixed. "Install BrowserOS" — step 2 of Astro's Windows
 * branch — pointed at files.browseros.com, which was not on the list, so the
 * button opened nothing at all. A control that does nothing when clicked reads
 * as a broken app, not as a blocked host. So a blocked host must surface as a
 * DISABLED control that names the host, and `classifyExternalLink` returns the
 * host precisely so the UI has something to name.
 */

/**
 * Every host a published guide can send the reader to. Twenty-two entries,
 * byte-for-byte the same set as `allowed_external_host` in main.rs.
 */
export const ALLOWED_EXTERNAL_HOSTS: ReadonlySet<string> = new Set([
  "publikhq.com",
  "www.publikhq.com",
  "github.com",
  "docs.github.com",
  "git-scm.com",
  "nodejs.org",
  "www.python.org",
  "python.org",
  "rustup.rs",
  "docker.com",
  "www.docker.com",
  "docs.docker.com",
  "developer.apple.com",
  "learn.microsoft.com",
  // Toolchains and assets the current guides link to.
  "apps.apple.com",
  "developer.android.com",
  "huggingface.co",
  "visualstudio.microsoft.com",
  "cmake.org",
  "www.cmake.org",
  // Astro's Windows route. Missing here, "Install BrowserOS" opened nothing at
  // all in the desktop app, which reads as a dead button rather than a blocked
  // host.
  "files.browseros.com",
  "go.dev",
]);

/** Loopback, for a locally-run publik during development. */
const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1"]);

export type ExternalLinkClassification =
  /** Safe to hand to the OS. `url` is the normalised form to actually open. */
  | { readonly allowed: true; readonly url: string; readonly host: string }
  /** Refused. `host` is present whenever the URL parsed, so the UI can name it
   *  in a disabled control instead of rendering a button that does nothing. */
  | { readonly allowed: false; readonly host: string | null; readonly reason: ExternalLinkRefusal };

export type ExternalLinkRefusal =
  | "malformed"
  | "hostNotAllowlisted"
  | "schemeNotAllowed"
  | "credentialsInUrl";

export function classifyExternalLink(candidate: unknown): ExternalLinkClassification {
  let url: URL;
  try {
    url = new URL(String(candidate ?? ""));
  } catch {
    return { allowed: false, host: null, reason: "malformed" };
  }

  const host = url.hostname.toLowerCase();

  // A URL carrying credentials is never worth opening, and saying so before the
  // host check keeps `https://github.com@evil.tld` from reading as a github link.
  if (url.username !== "" || url.password !== "") {
    return { allowed: false, host, reason: "credentialsInUrl" };
  }

  const isAllowlistedHttps = url.protocol === "https:" && ALLOWED_EXTERNAL_HOSTS.has(host);
  const isLoopback =
    (url.protocol === "http:" || url.protocol === "https:") && LOOPBACK_HOSTS.has(host);

  if (isAllowlistedHttps || isLoopback) {
    return { allowed: true, url: url.toString(), host };
  }

  // Distinguish "right host, wrong scheme" from "host we do not know", because
  // only the second is worth naming to the reader.
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    return { allowed: false, host, reason: "schemeNotAllowed" };
  }
  if (ALLOWED_EXTERNAL_HOSTS.has(host)) {
    return { allowed: false, host, reason: "schemeNotAllowed" };
  }
  return { allowed: false, host, reason: "hostNotAllowlisted" };
}

/** Convenience for the main process, where only the verdict matters. */
export function isAllowedExternalHost(host: string): boolean {
  return ALLOWED_EXTERNAL_HOSTS.has(host.toLowerCase());
}

/**
 * The sentence a disabled control shows instead of a button that would do
 * nothing. Naming the host is the point: the reader can go there themselves.
 */
export function refusalMessage(classification: ExternalLinkClassification): string | null {
  if (classification.allowed) return null;
  switch (classification.reason) {
    case "malformed":
      return "Iris blocked an invalid link.";
    case "credentialsInUrl":
      return "Iris blocked a link that carried a username or password.";
    case "schemeNotAllowed":
      return classification.host
        ? `Iris only opens https links. This step points at ${classification.host}.`
        : "Iris only opens https links.";
    case "hostNotAllowlisted":
      return classification.host
        ? `Iris cannot open ${classification.host} — it is not on publik's allowed list.`
        : "Iris cannot open that host — it is not on publik's allowed list.";
  }
}
