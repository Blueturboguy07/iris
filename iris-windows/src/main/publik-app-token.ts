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
 * Tokens exist as of 2026-09-21 (`scripts/mint-app-token.mts iris` on the
 * publik side mints them, and the `iris` apps row it needs now exists). A
 * release build gets one **substituted into `BAKED_APP_TOKEN` at package
 * time** by the `Bake the publik app token` step in
 * `.github/workflows/iris-release.yml`, reading the `PUBLIK_APP_TOKEN` repo
 * secret. It is never committed: `iris` is a public repo, and a token in git
 * history is harvestable by everyone at once rather than by whoever unpacks a
 * binary.
 *
 * The constant below therefore stays `""` in source, and that is a supported
 * shipping state, not a bug — a developer build, or a release where the
 * substitution was skipped, returns null and everything downstream falls back
 * to the human route: the user pastes a key from publikhq.com/dashboard/api.
 * That path is not a degraded mode to be apologised for; it is the only path
 * for any build without a token.
 *
 * The env var is honoured first, which is what makes a local build usable
 * without editing source — but note a packaged app does not inherit the build
 * machine's environment, so the env var is a development convenience and never
 * a shipping mechanism.
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
