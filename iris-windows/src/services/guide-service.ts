/**
 * guide-service.ts
 *
 * Fetches an install guide from publik. The wire contract is
 * `app/api/iris/guides/[slug]/route.ts`; the error vocabulary is the same one
 * `iris-macos/leanring-buddy/GuideService.swift` uses, so the two desktop clients
 * explain the same failure the same way.
 *
 * The route can answer with four different failures and they mean four different
 * things to the reader, so each becomes its own case rather than collapsing into
 * "guide service returned 4xx":
 *
 *   400  the version string itself was unreadable
 *   403  the guide exists but has not finished review
 *   404  publik has no guide by this slug
 *   409  the guide moved past the version the link named
 *
 * 409 in particular is the whole reason the client sends `?version=` at all:
 * being told to restart is very different from silently following steps written
 * for a commit the reader does not have checked out.
 */

import { isValidGuideSlug } from "./deep-link-parser";

export type GuideServiceErrorKind =
  | { kind: "invalidGuideSlug" }
  /** HTTP 400 — the API rejected the version string itself. */
  | { kind: "invalidGuideVersionRequest" }
  /** HTTP 403 — the guide exists but is still in review. */
  | { kind: "guideIsNotPublished" }
  /** HTTP 404 — publik has no guide by this slug. */
  | { kind: "guideNotFound" }
  /** HTTP 409 — the guide has moved past the version the link named. */
  | { kind: "guideVersionIsNoLongerAvailable"; requestedVersion: number }
  | { kind: "apiBaseIsNotAllowed" }
  | { kind: "unexpectedResponseStatus"; statusCode: number }
  | { kind: "responseCouldNotBeDecoded"; reason: string }
  | { kind: "guideHasNoBranches" }
  | { kind: "transportFailure"; reason: string };

export class GuideServiceError extends Error {
  readonly detail: GuideServiceErrorKind;

  constructor(detail: GuideServiceErrorKind) {
    super(guideErrorMessage(detail));
    this.name = "GuideServiceError";
    this.detail = detail;
  }
}

export function guideErrorMessage(detail: GuideServiceErrorKind): string {
  switch (detail.kind) {
    case "invalidGuideSlug":
      return "That guide link is invalid. Open a guide from a publik app page.";
    case "invalidGuideVersionRequest":
      return "That guide link asks for a version publik cannot read.";
    case "guideIsNotPublished":
      return "This guide has not finished review yet.";
    case "guideNotFound":
      return "Publik has not published a guide for this app yet.";
    case "guideVersionIsNoLongerAvailable":
      return `Guide version ${detail.requestedVersion} is no longer available.`;
    case "apiBaseIsNotAllowed":
      return "Iris only loads guides from publik.";
    case "unexpectedResponseStatus":
      return `Guide service returned ${detail.statusCode}.`;
    case "responseCouldNotBeDecoded":
      return `Iris could not read that guide: ${detail.reason}`;
    case "guideHasNoBranches":
      return "This guide has no reviewed desktop steps.";
    case "transportFailure":
      return `Iris could not reach publik: ${detail.reason}`;
  }
}

/** Where guides come from when nothing else is configured. */
export const DEFAULT_GUIDE_API_BASE = "https://publikhq.com";

/**
 * The only origins Iris will fetch a guide from. A tampered config cannot point
 * the client at somebody else's server pretending to be publik.
 */
export function normalizedApiBase(candidate: string): string | null {
  let url: URL;
  try {
    url = new URL(candidate);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase();
  const isPublik = host === "publikhq.com" || host === "www.publikhq.com";
  const isLoopback = host === "localhost" || host === "127.0.0.1";
  if (url.protocol === "https:" && isPublik) return trimTrailingSlashes(url.origin);
  if ((url.protocol === "http:" || url.protocol === "https:") && isLoopback) {
    return trimTrailingSlashes(url.origin);
  }
  return null;
}

function trimTrailingSlashes(value: string): string {
  return value.replace(/\/+$/, "");
}

/** Turns one HTTP status from the guides route into its own failure. */
export function guideFailureForStatusCode(
  statusCode: number,
  requestedVersion: number | null
): GuideServiceErrorKind {
  switch (statusCode) {
    case 400:
      return { kind: "invalidGuideVersionRequest" };
    case 403:
      return { kind: "guideIsNotPublished" };
    case 404:
      return { kind: "guideNotFound" };
    case 409:
      return { kind: "guideVersionIsNoLongerAvailable", requestedVersion: requestedVersion ?? 0 };
    default:
      return { kind: "unexpectedResponseStatus", statusCode };
  }
}

/** Builds `{base}/api/iris/guides/{slug}` with the version query when there is one. */
export function guideRequestUrl(options: {
  apiBase: string;
  slug: string;
  version: number | null;
}): string {
  const base = normalizedApiBase(options.apiBase);
  if (!base) throw new GuideServiceError({ kind: "apiBaseIsNotAllowed" });
  const versionQuery =
    options.version === null ? "" : `?version=${encodeURIComponent(String(options.version))}`;
  return `${base}/api/iris/guides/${encodeURIComponent(options.slug)}${versionQuery}`;
}

/** The shape the panel needs. Everything else in the payload is passed through. */
export interface IrisGuide {
  appSlug: string;
  appName: string;
  version: number;
  status?: string;
  branches: Array<Record<string, unknown>>;
  [key: string]: unknown;
}

/** Injected so the whole module is testable without a network. */
export type FetchLike = (
  url: string,
  init?: { method?: string; headers?: Record<string, string>; signal?: AbortSignal }
) => Promise<{
  ok: boolean;
  status: number;
  text: () => Promise<string>;
}>;

export async function fetchGuide(options: {
  apiBase: string;
  slug: string;
  version: number | null;
  fetchImplementation: FetchLike;
  signal?: AbortSignal;
}): Promise<IrisGuide> {
  if (!isValidGuideSlug(options.slug)) {
    throw new GuideServiceError({ kind: "invalidGuideSlug" });
  }
  if (options.version !== null && options.version < 1) {
    throw new GuideServiceError({ kind: "invalidGuideVersionRequest" });
  }

  const url = guideRequestUrl({
    apiBase: options.apiBase,
    slug: options.slug,
    version: options.version,
  });

  let response: Awaited<ReturnType<FetchLike>>;
  try {
    response = await options.fetchImplementation(url, {
      method: "GET",
      headers: { Accept: "application/json" },
      signal: options.signal,
    });
  } catch (error) {
    throw new GuideServiceError({
      kind: "transportFailure",
      reason: error instanceof Error ? error.message : String(error),
    });
  }

  if (!response.ok) {
    throw new GuideServiceError(guideFailureForStatusCode(response.status, options.version));
  }

  let guide: IrisGuide;
  try {
    guide = JSON.parse(await response.text()) as IrisGuide;
  } catch (error) {
    throw new GuideServiceError({
      kind: "responseCouldNotBeDecoded",
      reason: error instanceof Error ? error.message : String(error),
    });
  }

  if (!Array.isArray(guide?.branches)) {
    throw new GuideServiceError({
      kind: "responseCouldNotBeDecoded",
      reason: "guide has no branch list",
    });
  }
  if (guide.branches.length === 0 && guide.status !== "review") {
    throw new GuideServiceError({ kind: "guideHasNoBranches" });
  }

  // Asking for a version and being handed a different one means the route did
  // not enforce it; refusing here keeps the reader off steps they did not ask
  // for, which is the same thing the 409 protects against.
  if (options.version !== null && typeof guide.version === "number" && guide.version !== options.version) {
    throw new GuideServiceError({
      kind: "guideVersionIsNoLongerAvailable",
      requestedVersion: options.version,
    });
  }

  return guide;
}
