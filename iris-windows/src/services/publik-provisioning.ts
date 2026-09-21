/**
 * publik-provisioning.ts
 *
 * Turning a fresh install into a working publik API key — the "auto setup".
 *
 * Pure, with every side effect injected, so the whole flow (including the
 * replay case, which is the one that is easy to get wrong and impossible to
 * reproduce by hand) is driven from the vitest suite.
 *
 * The flow, from CONTRACT.md section 3.2:
 *   1. The caller shows the disclosure and gets consent. Provisioning is not
 *      called before that — "consent precedes mint" [S4].
 *   2. POST /installs with the build's app token and a client-minted
 *      `install_id`.
 *   3. `201` hands back a `pk_live_…` key exactly once, plus the starter and a
 *      claim URL.
 *   4. A `200` means this `install_id` was already used, and the server will
 *      not show the key again. If we have no stored key, that pairing is
 *      unrecoverable, so we mint ONE fresh `install_id` and retry. Exactly
 *      once — a loop here would mint installs forever [B1].
 */

import {
  ProvisionedInstall,
  buildInstallProvisioningRequest,
  looksLikeAnAppToken,
  newInstallId,
  parseProvisionedInstall,
} from "./publik-api";

/** The app's slug on publik. Used as the `app_slug` and inside the app token. */
export const IRIS_APP_SLUG = "iris";

export type ProvisioningOutcome =
  | { kind: "provisioned"; install: ProvisionedInstall; installId: string }
  /** The build ships no app token, so the machine route does not exist here.
   *  Not an error: the user pastes a key from the dashboard instead. */
  | { kind: "noAppToken" }
  /** The server answered, but not with a key we can use. */
  | { kind: "refused"; statusCode: number; message: string }
  | { kind: "networkFailure"; reason: string };

export interface ProvisioningSeams {
  fetchImplementation: (
    url: string,
    init: { method: string; headers: Record<string, string>; body: string }
  ) => Promise<{ status: number; text(): Promise<string> }>;
  randomBytes: (byteCount: number) => Uint8Array;
  /** The `install_id` from a previous run, if this machine has one. */
  readStoredInstallId: () => string | null;
  writeStoredInstallId: (installId: string) => void;
  appVersion: string;
  osVersion: string;
  arch: string;
  deviceName?: string;
}

/**
 * Provisions this install, minting an `install_id` if there is not one already.
 *
 * `appToken` being null is the expected state of any build cut before the
 * `pat_iris_…` token was minted, and of any local developer build — hence a
 * named outcome rather than a thrown error.
 */
export async function provisionPublikInstall(options: {
  apiBaseUrl: string;
  appToken: string | null;
  /** True when the caller already holds a usable key; changes only whether a
   *  replayed `200` is worth retrying with a fresh `install_id`. */
  alreadyHoldsAKey: boolean;
  seams: ProvisioningSeams;
}): Promise<ProvisioningOutcome> {
  const { appToken, seams } = options;
  if (!appToken || !looksLikeAnAppToken(appToken)) return { kind: "noAppToken" };

  const firstInstallId = seams.readStoredInstallId() ?? newInstallId(seams.randomBytes);
  const firstAttempt = await attemptProvisioning(options.apiBaseUrl, appToken, firstInstallId, seams);

  if (firstAttempt.kind !== "provisioned") return firstAttempt;

  // A replay: the server recognised this install and will not show the key
  // again. With a key already on disk that is simply a no-op; without one we
  // are stuck with an id we can never get a key for, so mint a new one — once.
  const replayedWithNoKey = firstAttempt.install.apiKey === null && !options.alreadyHoldsAKey;
  if (!replayedWithNoKey) {
    seams.writeStoredInstallId(firstInstallId);
    return firstAttempt;
  }

  const freshInstallId = newInstallId(seams.randomBytes);
  const secondAttempt = await attemptProvisioning(options.apiBaseUrl, appToken, freshInstallId, seams);
  if (secondAttempt.kind === "provisioned") {
    seams.writeStoredInstallId(freshInstallId);
  }
  return secondAttempt;
}

async function attemptProvisioning(
  apiBaseUrl: string,
  appToken: string,
  installId: string,
  seams: ProvisioningSeams
): Promise<ProvisioningOutcome> {
  const request = buildInstallProvisioningRequest(apiBaseUrl, {
    appToken,
    appSlug: IRIS_APP_SLUG,
    appVersion: seams.appVersion,
    osVersion: seams.osVersion,
    arch: seams.arch,
    installId,
    deviceName: seams.deviceName,
  });

  let response: { status: number; text(): Promise<string> };
  try {
    response = await seams.fetchImplementation(request.url, {
      method: "POST",
      headers: request.headers,
      body: request.body,
    });
  } catch (error) {
    return {
      kind: "networkFailure",
      reason: error instanceof Error ? error.message : String(error),
    };
  }

  const rawBody = await response.text();

  if (response.status !== 200 && response.status !== 201) {
    return {
      kind: "refused",
      statusCode: response.status,
      message: refusalMessage(response.status),
    };
  }

  const install = parseProvisionedInstall(rawBody);
  if (!install) {
    return {
      kind: "refused",
      statusCode: response.status,
      message: "publik API sent back something Iris could not read.",
    };
  }

  return { kind: "provisioned", install, installId };
}

/**
 * What to tell a user whose provisioning was refused. Deliberately does not
 * quote the server: these are setup-time failures whose remedy is the same
 * ("paste a key instead"), and the gateway's own wording for them is aimed at
 * developers rather than at whoever just installed Iris.
 */
function refusalMessage(statusCode: number): string {
  if (statusCode === 401 || statusCode === 403) {
    return "This build of Iris could not set up publik API automatically. You can paste a key from your dashboard instead.";
  }
  if (statusCode === 429) {
    return "publik API is busy setting up installs right now. Try again in a little while, or paste a key from your dashboard.";
  }
  return "publik API could not be set up right now. You can paste a key from your dashboard instead.";
}
