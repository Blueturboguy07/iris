/**
 * deep-link-parser.ts
 *
 * Every `iris://` link the Windows app answers to, and the reasons it turns one
 * away. Ported from `iris-desktop/src-tauri/src/main.rs` (`parse_guide_deep_link`,
 * `valid_branch_key`, `valid_slug` — lines 188-285), which remains the
 * behavioural spec, and matched against
 * `iris-macos/leanring-buddy/DeepLinkParser.swift` so all three clients refuse
 * the same links with the same words.
 *
 * There are exactly two accepted shapes:
 *
 *   iris://guide/<slug>?version=<n>&branch=<key>&step=<n>
 *   iris://auth/callback?code=<...>&state=<...>
 *
 * The governing rule is that an unknown query parameter is REJECTED rather than
 * ignored, so a crafted link cannot smuggle in a field a later version of the
 * app might start reading.
 */

export interface GuideDeepLink {
  readonly slug: string;
  readonly version: number;
  readonly branch: string | null;
  readonly step: number | null;
}

export interface AuthCallbackDeepLink {
  readonly authorizationCode: string;
  readonly opaqueStateToken: string;
}

/** Exactly the two link shapes Iris answers to. Anything else is rejected before
 *  any of it is applied, so a malformed link can never partially take effect. */
export type IrisDeepLink =
  | { readonly kind: "guide"; readonly guide: GuideDeepLink }
  | { readonly kind: "authCallback"; readonly authCallback: AuthCallbackDeepLink };

/** The reasons a link is turned away. The strings reproduce the Rust shell's
 *  `iris-deep-link-rejected` payload so every client explains a refusal
 *  identically. */
export type IrisDeepLinkRejection =
  | "unsupported Iris link"
  | "missing guide slug"
  | "Iris guide links require exactly one slug"
  | "invalid Iris guide slug"
  | "Iris guide links accept only one version parameter"
  | "invalid Iris guide version"
  | "missing Iris guide version"
  | "Iris guide links accept only one branch parameter"
  | "invalid Iris guide branch"
  | "Iris guide links accept only one step parameter"
  | "invalid Iris guide step"
  | "unsupported Iris guide parameter"
  | "Iris sign-in links accept each parameter only once"
  | "incomplete Iris sign-in link"
  | "invalid Iris sign-in value"
  | "unsupported Iris sign-in parameter";

export type DeepLinkParseResult =
  | { readonly ok: true; readonly link: IrisDeepLink }
  | { readonly ok: false; readonly rejection: IrisDeepLinkRejection };

/** The URL scheme Windows registers for Iris. */
export const IRIS_URL_SCHEME = "iris";

const GUIDE_HOST = "guide";
const AUTH_HOST = "auth";
const AUTH_CALLBACK_PATH_SEGMENT = "callback";

/** The web panel can be many steps ahead, but nothing sane is past a hundred;
 *  the UI clamps to the real count anyway. */
const MAXIMUM_STEP = 500;

/** `u32::MAX`, so a version that overflows the Rust parser is refused here too. */
const MAXIMUM_UNSIGNED_32_BIT = 4_294_967_295;

const MAXIMUM_SLUG_LENGTH = 64;
const MAXIMUM_AUTH_CALLBACK_VALUE_LENGTH = 2048;

const KNOWN_BRANCH_PLATFORMS = new Set(["macos", "windows"]);
const KNOWN_BRANCH_TARGETS = new Set(["ios", "android", "desktop"]);

function reject(rejection: IrisDeepLinkRejection): DeepLinkParseResult {
  return { ok: false, rejection };
}

export function parseIrisDeepLink(deepLinkString: string): DeepLinkParseResult {
  let url: URL;
  try {
    url = new URL(deepLinkString);
  } catch {
    return reject("unsupported Iris link");
  }

  // `iris:` is not a "special" scheme, so WHATWG parsing keeps the authority
  // intact and never applies http-style normalisation. Everything below reads
  // the same fields `parse_guide_deep_link` reads.
  if (url.protocol !== `${IRIS_URL_SCHEME}:`) {
    return reject("unsupported Iris link");
  }
  if (url.port !== "" || url.username !== "" || url.password !== "" || url.hash !== "") {
    return reject("unsupported Iris link");
  }

  switch (url.hostname.toLowerCase()) {
    case GUIDE_HOST:
      return parseGuideDeepLink(url);
    case AUTH_HOST:
      return parseAuthCallbackDeepLink(url);
    default:
      return reject("unsupported Iris link");
  }
}

/**
 * The percent-encoded path is used on purpose: the Rust `url` crate hands
 * `path_segments` back without decoding, so a slug written as `cue%2Fextra`
 * stays one segment there and is refused for containing `%` rather than silently
 * splitting into two segments here.
 */
function nonEmptyPathSegments(url: URL): string[] {
  return url.pathname.split("/").filter((segment) => segment.length > 0);
}

function parseGuideDeepLink(url: URL): DeepLinkParseResult {
  const segments = nonEmptyPathSegments(url);
  if (segments.length === 0) {
    return reject("missing guide slug");
  }
  if (segments.length !== 1) {
    return reject("Iris guide links require exactly one slug");
  }

  const slug = segments[0];
  if (!isValidGuideSlug(slug)) {
    return reject("invalid Iris guide slug");
  }

  // Every parameter is named, known, and allowed at most once. Anything else is
  // rejected outright rather than ignored.
  let version: number | null = null;
  let branch: string | null = null;
  let step: number | null = null;

  for (const [key, value] of url.searchParams) {
    switch (key) {
      case "version": {
        if (version !== null) {
          return reject("Iris guide links accept only one version parameter");
        }
        const parsedVersion = parseUnsignedInteger(value);
        if (parsedVersion === null || parsedVersion === 0) {
          return reject("invalid Iris guide version");
        }
        version = parsedVersion;
        break;
      }
      case "branch": {
        if (branch !== null) {
          return reject("Iris guide links accept only one branch parameter");
        }
        if (!isValidBranchKey(value)) {
          return reject("invalid Iris guide branch");
        }
        branch = value;
        break;
      }
      case "step": {
        if (step !== null) {
          return reject("Iris guide links accept only one step parameter");
        }
        const parsedStep = parseUnsignedInteger(value);
        if (parsedStep === null || parsedStep > MAXIMUM_STEP) {
          return reject("invalid Iris guide step");
        }
        step = parsedStep;
        break;
      }
      default:
        return reject("unsupported Iris guide parameter");
    }
  }

  if (version === null) {
    return reject("missing Iris guide version");
  }

  return { ok: true, link: { kind: "guide", guide: { slug, version, branch, step } } };
}

function parseAuthCallbackDeepLink(url: URL): DeepLinkParseResult {
  const segments = nonEmptyPathSegments(url);
  if (segments.length !== 1 || segments[0] !== AUTH_CALLBACK_PATH_SEGMENT) {
    return reject("unsupported Iris link");
  }

  let authorizationCode: string | null = null;
  let opaqueStateToken: string | null = null;

  for (const [key, value] of url.searchParams) {
    switch (key) {
      case "code":
        if (authorizationCode !== null) {
          return reject("Iris sign-in links accept each parameter only once");
        }
        if (!isValidAuthCallbackValue(value)) {
          return reject("invalid Iris sign-in value");
        }
        authorizationCode = value;
        break;
      case "state":
        if (opaqueStateToken !== null) {
          return reject("Iris sign-in links accept each parameter only once");
        }
        if (!isValidAuthCallbackValue(value)) {
          return reject("invalid Iris sign-in value");
        }
        opaqueStateToken = value;
        break;
      default:
        return reject("unsupported Iris sign-in parameter");
    }
  }

  // A code without its state is exactly the shape a CSRF attempt takes, so both
  // have to be present before any of the link is applied.
  if (authorizationCode === null || opaqueStateToken === null) {
    return reject("incomplete Iris sign-in link");
  }

  return {
    ok: true,
    link: { kind: "authCallback", authCallback: { authorizationCode, opaqueStateToken } },
  };
}

/**
 * Ported from `valid_slug` (main.rs:276-285). The first and last byte are checked
 * for being alphanumeric *and* every byte for being lowercase, a digit, or a
 * hyphen — so `Cue` fails the second check even though it passes the first.
 */
export function isValidGuideSlug(slug: string): boolean {
  if (slug.length === 0 || slug.length > MAXIMUM_SLUG_LENGTH) return false;
  if (!/^[a-z0-9]/.test(slug)) return false;
  if (!/[a-z0-9]$/.test(slug)) return false;
  return /^[a-z0-9-]+$/.test(slug);
}

/** `windows:desktop` exactly as the guide library writes it, so the desktop app
 *  selects the same branch the reader was already following. */
export function isValidBranchKey(value: string): boolean {
  const separatorIndex = value.indexOf(":");
  if (separatorIndex < 0) return false;
  const platform = value.slice(0, separatorIndex);
  const target = value.slice(separatorIndex + 1);
  return KNOWN_BRANCH_PLATFORMS.has(platform) && KNOWN_BRANCH_TARGETS.has(target);
}

/**
 * Digits only. Rust's `u32::from_str` would also accept a leading `+`; refusing
 * it here is the stricter reading and no real link relies on it.
 */
function parseUnsignedInteger(value: string): number | null {
  if (!/^\d+$/.test(value)) return null;
  const parsed = Number.parseInt(value, 10);
  if (!Number.isSafeInteger(parsed) || parsed > MAXIMUM_UNSIGNED_32_BIT) return null;
  return parsed;
}

/** Control characters have no business in an authorization code and are the
 *  usual way a crafted link tries to break out of a log line. */
function isValidAuthCallbackValue(value: string): boolean {
  if (value.length === 0 || value.length > MAXIMUM_AUTH_CALLBACK_VALUE_LENGTH) return false;
  for (const character of value) {
    const codePoint = character.codePointAt(0) ?? 0;
    if (codePoint < 0x20 || codePoint === 0x7f) return false;
  }
  return true;
}
