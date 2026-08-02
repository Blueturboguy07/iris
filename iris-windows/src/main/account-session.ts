import { shell } from "electron";
import { SettingsStore } from "./settings";
import {
  AccountServiceError,
  AccountSignInProvider,
  PkceCodePair,
  SupabaseProjectConfiguration,
  SupabaseSession,
  authorizationUrl,
  createOpaqueStateToken,
  createPkceCodePair,
  exchangeAuthorizationCode,
  refreshSession,
  sessionNeedsRefresh,
} from "../services/account-service";
import { AuthCallbackDeepLink } from "../services/deep-link-parser";

/**
 * account-session.ts
 *
 * The live sign-in state, and the only thing in the main process that opens a
 * browser for it.
 *
 * Protocol section 4: the access token lives in memory, the refresh token lives
 * behind `safeStorage`, and the authorize step happens in the user's real
 * browser. `shell.openExternal` is what makes it the real browser — Google
 * refuses to complete OAuth inside an embedded webview, and a `BrowserWindow`
 * pointed at an identity provider is exactly the webview it refuses.
 */

/**
 * The Supabase project publik uses. The anon key is public by design — it
 * identifies the project and authorises nothing on its own — but it is read from
 * the environment so a build can point at a different project without a code
 * change.
 */
export function configuredSupabaseProject(): SupabaseProjectConfiguration | null {
  const projectUrl = process.env.IRIS_SUPABASE_URL ?? "";
  const anonymousKey = process.env.IRIS_SUPABASE_ANON_KEY ?? "";
  if (!projectUrl || !anonymousKey) return null;
  return { projectUrl, anonymousKey };
}

interface PendingAuthorization {
  readonly codePair: PkceCodePair;
  readonly opaqueStateToken: string;
}

export class AccountSession {
  private readonly settings: SettingsStore;
  /** In memory only, per protocol section 4. Never written to disk. */
  private session: SupabaseSession | null = null;
  private pendingAuthorization: PendingAuthorization | null = null;
  private inFlightRefresh: Promise<SupabaseSession | null> | null = null;

  constructor(settings: SettingsStore) {
    this.settings = settings;
  }

  isSignedIn(): boolean {
    return this.session !== null || this.settings.getSupabaseRefreshToken() !== null;
  }

  signedInEmail(): string | null {
    return this.session?.userEmail ?? null;
  }

  /**
   * The access token to put on a funded request, refreshing it first if it is
   * about to expire. Returns null when the user is not signed in, which the
   * transport reports as `signInRequired`.
   */
  async currentAccessToken(): Promise<string | null> {
    const nowInSeconds = Math.floor(Date.now() / 1000);
    if (this.session && !sessionNeedsRefresh(this.session, nowInSeconds)) {
      return this.session.accessToken;
    }

    const storedRefreshToken = this.settings.getSupabaseRefreshToken();
    if (!storedRefreshToken) return null;

    // Collapse concurrent refreshes: two messages sent at once must not each
    // burn a refresh token, because Supabase rotates it on use.
    if (!this.inFlightRefresh) {
      this.inFlightRefresh = this.performRefresh(storedRefreshToken).finally(() => {
        this.inFlightRefresh = null;
      });
    }
    const refreshed = await this.inFlightRefresh;
    return refreshed?.accessToken ?? null;
  }

  private async performRefresh(storedRefreshToken: string): Promise<SupabaseSession | null> {
    const project = configuredSupabaseProject();
    if (!project) return null;
    try {
      const refreshed = await refreshSession({
        project,
        refreshToken: storedRefreshToken,
        fetchImplementation: globalThis.fetch as never,
      });
      this.adoptSession(refreshed);
      return refreshed;
    } catch {
      // A refresh token that no longer works means the session is over. Drop it
      // so the UI shows the sign-in buttons rather than retrying forever.
      this.signOut();
      return null;
    }
  }

  /** Step one: open the user's browser at the authorize URL. */
  async beginSignIn(provider: AccountSignInProvider): Promise<void> {
    const project = configuredSupabaseProject();
    if (!project) {
      throw new AccountServiceError({ kind: "supabaseIsNotConfiguredInThisBuild" });
    }

    const codePair = createPkceCodePair();
    const opaqueStateToken = createOpaqueStateToken();
    this.pendingAuthorization = { codePair, opaqueStateToken };

    await shell.openExternal(
      authorizationUrl({
        project,
        provider,
        codeChallenge: codePair.codeChallenge,
        opaqueStateToken,
      })
    );
  }

  /**
   * Step two: the `iris://auth/callback` link came back. The state must match the
   * request this app started, or the callback is discarded — a callback nobody
   * asked for is the shape a CSRF attempt takes.
   */
  async completeSignIn(callback: AuthCallbackDeepLink): Promise<void> {
    const project = configuredSupabaseProject();
    if (!project) {
      throw new AccountServiceError({ kind: "supabaseIsNotConfiguredInThisBuild" });
    }
    const pending = this.pendingAuthorization;
    if (!pending || pending.opaqueStateToken !== callback.opaqueStateToken) {
      throw new AccountServiceError({ kind: "callbackStateDidNotMatch" });
    }
    this.pendingAuthorization = null;

    const session = await exchangeAuthorizationCode({
      project,
      authorizationCode: callback.authorizationCode,
      codeVerifier: pending.codePair.codeVerifier,
      fetchImplementation: globalThis.fetch as never,
    });
    this.adoptSession(session);
  }

  private adoptSession(session: SupabaseSession): void {
    this.session = session;
    this.settings.setSupabaseRefreshToken(session.refreshToken);
  }

  signOut(): void {
    this.session = null;
    this.pendingAuthorization = null;
    this.settings.setSupabaseRefreshToken(null);
  }
}
