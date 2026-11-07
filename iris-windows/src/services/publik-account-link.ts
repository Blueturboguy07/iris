/**
 * publik-account-link.ts
 *
 * Linking this computer to the publik account the reader signed in to.
 *
 * Signing in used to keep only a Supabase session. Nothing on publik's side
 * learned that this computer belonged to that account, so the usage counts
 * (publik telemetry v1) counted a signed-in reader as an anonymous computer.
 * publik counts a computer by its account only when the count carries a
 * publik install key whose install is linked to the account. So, each time a
 * session starts (a sign-in, or a launch with a stored session):
 *
 *   - a reader who holds a publik API key has that install CLAIMED:
 *     `POST /installs/claim` with the install's claim code (read from
 *     `GET /balance`) and the session's access token as the bearer;
 *   - a reader with no publik API key gets a small install of its own, minted
 *     WITH the session's access token, which binds it to the account at mint.
 *     Its key is a separate secret (`publikLinkKey`) and is never a model
 *     credential: the chat route, the provider choice and the publik API key
 *     slot never read it. Its only reader is the usage-count client.
 *
 * Signing out deletes the link key and revokes its install. The settings page
 * says "Signing in links this computer to your publik account" before any of
 * this happens.
 *
 * Pure, with every side effect injected, so the vitest suite drives it.
 */

import { isPublikGateway } from "./publik-api";
import { ProvisioningSeams, provisionPublikInstall } from "./publik-provisioning";

/** publik's claim code: 4 + 4 characters, no I, O, 0 or 1. Same as the gateway. */
const CLAIM_CODE_PATTERN = /^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/;

/**
 * The claim code inside a claim link (`https://publikhq.com/claim/XXXX-XXXX`),
 * or null. A `?code=XXXX-XXXX` form is accepted too, so a change of link shape
 * on the server does not silently stop the claim.
 */
export function claimCodeFromClaimUrl(claimUrl: string | null | undefined): string | null {
  if (!claimUrl) return null;
  let parsed: URL;
  try {
    parsed = new URL(claimUrl.trim());
  } catch {
    return null;
  }
  const pathSegments = parsed.pathname.split("/").filter(Boolean);
  const candidates = [pathSegments[pathSegments.length - 1] ?? "", ...parsed.searchParams.getAll("code")];
  for (const candidate of candidates) {
    const normalized = candidate.toUpperCase();
    if (CLAIM_CODE_PATTERN.test(normalized)) return normalized;
  }
  return null;
}

export interface PlainPostRequest {
  url: string;
  method: "POST";
  headers: Record<string, string>;
  body: string;
}

/** `POST {gateway}/installs/claim`, signed by the session. Null off publik. */
export function buildInstallClaimRequest(
  apiBaseUrl: string,
  claimCode: string,
  accountAccessToken: string
): PlainPostRequest | null {
  if (!isPublikGateway(apiBaseUrl)) return null;
  const base = apiBaseUrl.replace(/\/+$/, "");
  return {
    url: `${base}/installs/claim`,
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accountAccessToken}`,
    },
    body: JSON.stringify({ claim_code: claimCode, confirm: true }),
  };
}

/**
 * `POST {gateway}/installs/revoke` with the install's own key and an empty
 * body: publik revokes that one install (reason "user"). The key rides in
 * `x-api-key`, as on every other publik call. Null off publik: a publik key
 * reaches publik and nothing else.
 */
export function buildInstallRevokeRequest(apiBaseUrl: string, installKey: string): PlainPostRequest | null {
  if (!isPublikGateway(apiBaseUrl)) return null;
  const base = apiBaseUrl.replace(/\/+$/, "");
  return {
    url: `${base}/installs/revoke`,
    method: "POST",
    headers: { "x-api-key": installKey },
    body: "",
  };
}

/**
 * The key the usage counts carry: the publik API key when the reader has one,
 * else the account-link key, else none (the count is anonymous). Never any
 * other key: never the reader's own provider keys.
 */
export function telemetryKey(publikApiKey: string | null, accountLinkKey: string | null): string | null {
  return publikApiKey || accountLinkKey || null;
}

export type AccountLinkOutcome =
  /** The publik API install this computer had is now claimed. */
  | { kind: "claimedTheExistingInstall" }
  /** That install was already linked to an account. */
  | { kind: "existingInstallWasAlreadyLinked" }
  /** A new install, bound to the account, now holds the link key. */
  | { kind: "mintedAnAccountLinkInstall" }
  /** A link install from an earlier session start is still here. */
  | { kind: "alreadyHadAnAccountLinkInstall" }
  /** This build ships no app token, so it cannot mint. */
  | { kind: "noAppToken" }
  /** The wallet could not be read, or held no claim code. */
  | { kind: "noClaimCodeAvailable" }
  /** The gateway is not a publik host, so the session is not sent. */
  | { kind: "notAPublikHost" }
  | { kind: "refused"; statusCode: number }
  | { kind: "networkFailure" };

/** What `GET /balance` said about the publik API install. */
export interface AccountLinkWallet {
  claimState: "anonymous" | "claimed";
  claimUrl: string | null;
  topUpUrl: string | null;
}

export interface AccountLinkSeams {
  fetchImplementation: ProvisioningSeams["fetchImplementation"];
  readPublikApiKey: () => string | null;
  readAccountLinkKey: () => string | null;
  writeAccountLinkKey: (key: string) => void;
  /** Reads `GET /balance` for the publik API key, or null when it cannot. */
  readWallet: () => Promise<AccountLinkWallet | null>;
  /** Provisioning for the link install. Its install id is its own, so a later
   *  publik API mint is not answered as a replay of this one. */
  linkInstallProvisioning: Omit<ProvisioningSeams, "fetchImplementation">;
}

/**
 * Links this computer to the account whose session `accountAccessToken` is.
 * Best effort: never throws, and changes nothing about how Iris answers.
 */
export async function linkThisComputerToTheAccount(options: {
  apiBaseUrl: string;
  appToken: string | null;
  accountAccessToken: string;
  seams: AccountLinkSeams;
}): Promise<AccountLinkOutcome> {
  const { apiBaseUrl, accountAccessToken, seams } = options;
  if (!isPublikGateway(apiBaseUrl)) return { kind: "notAPublikHost" };

  try {
    if (seams.readPublikApiKey()) {
      return await claimTheExistingInstall(apiBaseUrl, accountAccessToken, seams);
    }
    return await mintAnAccountLinkInstall(options);
  } catch {
    return { kind: "networkFailure" };
  }
}

async function claimTheExistingInstall(
  apiBaseUrl: string,
  accountAccessToken: string,
  seams: AccountLinkSeams
): Promise<AccountLinkOutcome> {
  const wallet = await seams.readWallet();
  if (!wallet) return { kind: "noClaimCodeAvailable" };
  if (wallet.claimState === "claimed") return { kind: "existingInstallWasAlreadyLinked" };

  const claimCode = claimCodeFromClaimUrl(wallet.claimUrl) ?? claimCodeFromClaimUrl(wallet.topUpUrl);
  const request = claimCode ? buildInstallClaimRequest(apiBaseUrl, claimCode, accountAccessToken) : null;
  if (!request) return { kind: "noClaimCodeAvailable" };

  let status: number;
  try {
    const response = await seams.fetchImplementation(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
    });
    status = response.status;
  } catch {
    return { kind: "networkFailure" };
  }
  if (status < 200 || status >= 300) return { kind: "refused", statusCode: status };

  // The wallet changed hands (and may have gained the one-time link credit),
  // so it is read again rather than guessed.
  await seams.readWallet();
  return { kind: "claimedTheExistingInstall" };
}

async function mintAnAccountLinkInstall(options: {
  apiBaseUrl: string;
  appToken: string | null;
  accountAccessToken: string;
  seams: AccountLinkSeams;
}): Promise<AccountLinkOutcome> {
  const { seams } = options;
  if (seams.readAccountLinkKey()) return { kind: "alreadyHadAnAccountLinkInstall" };

  // Same replay rule as the publik API mint: a 200 with no key means this id
  // was used before, so one fresh id is minted and tried once more.
  const outcome = await provisionPublikInstall({
    apiBaseUrl: options.apiBaseUrl,
    appToken: options.appToken,
    alreadyHoldsAKey: false,
    accountAccessToken: options.accountAccessToken,
    sendDisclosureVersion: false,
    seams: { ...seams.linkInstallProvisioning, fetchImplementation: seams.fetchImplementation },
  });

  switch (outcome.kind) {
    case "noAppToken":
      return { kind: "noAppToken" };
    case "networkFailure":
      return { kind: "networkFailure" };
    case "refused":
      return { kind: "refused", statusCode: outcome.statusCode };
    case "provisioned":
      if (!outcome.install.apiKey) return { kind: "refused", statusCode: 200 };
      seams.writeAccountLinkKey(outcome.install.apiKey);
      return { kind: "mintedAnAccountLinkInstall" };
  }
}

/**
 * Sign-out: the link key is deleted at once, then its install is revoked on
 * publik, best effort. A failed revoke leaves an install nobody holds a key
 * for. Resolves to whether publik confirmed the revoke; never throws.
 */
export async function forgetTheAccountLink(options: {
  apiBaseUrl: string;
  seams: {
    fetchImplementation: ProvisioningSeams["fetchImplementation"];
    readAccountLinkKey: () => string | null;
    deleteAccountLinkKey: () => void;
    forgetLinkInstallId: () => void;
  };
}): Promise<boolean> {
  const { seams } = options;
  const linkKey = seams.readAccountLinkKey();
  if (!linkKey) return false;
  seams.deleteAccountLinkKey();
  seams.forgetLinkInstallId();

  const request = buildInstallRevokeRequest(options.apiBaseUrl, linkKey);
  if (!request) return false;
  try {
    const response = await seams.fetchImplementation(request.url, {
      method: request.method,
      headers: request.headers,
      body: request.body,
    });
    return response.status >= 200 && response.status < 300;
  } catch {
    return false;
  }
}
