/**
 * publik-app-token.ts
 *
 * The public app token this build ships, used once per machine to provision a
 * publik API key (`POST /api/v1/installs`).
 *
 * The token is public by construction — it sits inside every copy of the
 * binary and anyone can read it out. That is expected and contained by design
 * (CONTRACT.md sections 3.2 and 7): tokens are minted per release, revocable
 * by timestamp without touching the installs they already created, rate
 * limited per IP, and each one mints only a small starter. It is not a secret,
 * so it does NOT live in `secrets.ts`.
 *
 * **No `pat_iris_…` token has been minted yet.** `scripts/mint-app-token.mts
 * iris` on the publik side is what creates one, and it refuses a slug with no
 * `apps` row — which `iris` does not have. Until that exists this returns null,
 * and everything downstream falls back to the human route: the user pastes a
 * key from publikhq.com/dashboard/api. That path is not a degraded mode to be
 * apologised for; it is the only path for any build that ships without a token,
 * including every local developer build.
 *
 * When the token does exist, bake it in by setting `BAKED_APP_TOKEN` below as
 * part of cutting a release. The env var is honoured too, which is what makes a
 * local build usable without editing source — note that a packaged app does not
 * inherit the build machine's environment, so the env var alone is a
 * development convenience, not a shipping mechanism.
 */

/**
 * Replaced at release time with the release's own `pat_iris_<32>`. Empty means
 * "this build has no token", which is a supported state.
 */
const BAKED_APP_TOKEN = "";

export function publikAppToken(): string | null {
  const fromEnvironment = process.env.PUBLIK_APP_TOKEN?.trim();
  if (fromEnvironment) return fromEnvironment;
  return BAKED_APP_TOKEN.length > 0 ? BAKED_APP_TOKEN : null;
}

/** True when the machine route exists in this build at all. */
export function buildCanProvisionAutomatically(): boolean {
  return publikAppToken() !== null;
}
