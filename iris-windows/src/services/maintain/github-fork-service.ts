/**
 * github-fork-service.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/GitHubForkService.swift`.
 *
 * The fork backup: when a local clone of a catalog app carries commits beyond
 * its pinned install commit — Iris's own fixes, or the user's — the work gets
 * backed up to a fork in the USER'S OWN GitHub namespace. Ask once to
 * connect; after that, silently, because fork+push is additive, reversible,
 * and never leaves a namespace the user owns. (For the AGPL apps in the
 * catalog this is also simply the compliant behavior.)
 *
 * Auth is a GitHub App over the DEVICE FLOW: no embedded browser, no URL
 * scheme, no client secret in this binary. The user gets a short code, types
 * it at github.com/login/device, and Iris polls. Tokens are a pair — an
 * 8-hour access token and a 6-month refresh token.
 *
 * Hard rules, learned from other tools' scars (unchanged from the Swift
 * original):
 *   - Fork with NO custom name; inherit the canonical one.
 *   - A same-named repo that is NOT our fork: STOP AND SURFACE. Never rename,
 *     never touch a repo Iris did not create.
 *   - The fork endpoint returns 202 and completes async; poll with backoff.
 *   - Push tokens ride one-shot URLs, never saved as a git remote, never
 *     traced — no `maintainTrace` call in this file ever includes a pushURL,
 *     an access token, or raw command output (see `pushBranch` below).
 *   - The fix branch is never the default branch; merge-upstream keeps the
 *     fork's default branch mirroring the canonical repo.
 *
 * WHY THIS FILE NEVER TOUCHES A SECRET AT REST: exactly the reason
 * `model-provider.ts`'s header gives — `src/main/secrets.ts` is the only code
 * allowed to read one, it lives in `main/` (Electron APIs), and this file
 * lives in `services/maintain/`, which must not depend on `main/`. So the
 * access/refresh token pair is four plain closures the caller injects
 * (read/write each), exactly like `model-provider.ts`'s `readAnthropicApiKey`.
 *
 * INTERLOCK — not fixed by this file, flagged per the porting spec's ground
 * rules rather than done silently: `secrets.ts`'s `SecretName` union is
 * currently `"anthropicApiKey" | "supabaseRefreshToken"` only. It needs
 * `"gitHubAccessToken" | "gitHubRefreshToken"` added before the real
 * `readAccessToken`/`writeAccessToken`/`readRefreshToken`/`writeRefreshToken`
 * closures can be wired to `readSecret`/`writeSecret` for real. That is a
 * one-line edit to a file this task does not own.
 *
 * INTERLOCK — also not fixed by this file: the GitHub App's public client id
 * is read from `process.env.IRIS_GITHUB_APP_CLIENT_ID`, the same pattern
 * `account-session.ts`'s `configuredSupabaseProject()` uses for
 * `IRIS_SUPABASE_URL`/`IRIS_SUPABASE_ANON_KEY` — no file edit required, the
 * env var just needs to exist in the build/CI environment once the GitHub App
 * is registered. Its absence makes the whole feature `"unavailable"` rather
 * than broken, matching Swift's `clientId == nil` branch exactly.
 */

import type { FetchLike } from "./pool-client";
import { maintainTrace } from "./trace";
import type { MaintainCommandResult, MaintainShellRunner } from "./maintain-shell-runner";

// ---------------------------------------------------------------------------
// Connect state
// ---------------------------------------------------------------------------

/** Where the device-flow handshake stands, for the panel to render. Mirrors
 *  Swift's `GitHubConnectState`, `type`-tagged per this codebase's
 *  `AutopilotEvent`/`RunnerStatus` discriminated-union convention. */
export type GitHubConnectState =
  | { readonly type: "not_connected" }
  /** Show this code; Iris is polling until the user enters it. */
  | { readonly type: "awaiting_user_code"; readonly userCode: string; readonly verificationUrl: string }
  | { readonly type: "connected"; readonly login: string }
  /** The GitHub App client id is missing from this build — the feature is
   *  dormant, not broken. */
  | { readonly type: "unavailable" };

// ---------------------------------------------------------------------------
// The backup
// ---------------------------------------------------------------------------

export type ForkBackupOutcome =
  | { readonly type: "backed_up"; readonly forkUrl: string; readonly branch: string }
  | { readonly type: "name_collision_needs_the_user"; readonly existingRepoUrl: string }
  | { readonly type: "not_connected" }
  | { readonly type: "failed"; readonly reason: string };

// ---------------------------------------------------------------------------
// Ownership-aware propagation
// ---------------------------------------------------------------------------

/**
 * The whole propagation decision, driven by GitHub's OWN permission model: if
 * the connected user can push to the canonical repo, this is their app — push
 * the fix straight to it and merge it (their repo, their verified fix, no
 * ceremony). If they cannot, this machine is a user of someone else's app —
 * the fix goes to their fork and opens a PR on the canonical repo, where the
 * OWNER's Iris re-verifies (`incoming-fix-reviewer.ts`) and decides. GitHub
 * enforces the boundary; Iris never pushes where the token has no right to.
 */
export type FixPropagation =
  /** Owner path: merged straight into the canonical default branch. */
  | { readonly type: "merged_to_canonical"; readonly repo: string; readonly commitSha: string | null }
  /** Non-owner path: a PR is open on the canonical repo for its owner. */
  | { readonly type: "pull_request_opened"; readonly url: string; readonly number: number }
  /** Fork backup happened but the canonical step didn't (owner-path push
   *  failed, or a PR already existed). */
  | { readonly type: "backed_up_only"; readonly forkUrl: string; readonly branch: string }
  | { readonly type: "not_connected" }
  | { readonly type: "failed"; readonly reason: string };

// ---------------------------------------------------------------------------
// Owner side: incoming fix PRs
// ---------------------------------------------------------------------------

/** One incoming Iris fix PR on a repo the connected user owns. */
export interface IncomingFixPR {
  readonly repo: string;
  readonly number: number;
  readonly title: string;
  readonly headRepoCloneUrl: string;
  readonly headBranch: string;
  readonly url: string;
}

// ---------------------------------------------------------------------------
// Injected seams
// ---------------------------------------------------------------------------

/**
 * The access/refresh token pair, as four plain closures — see the file
 * header for why this is closures rather than a `secrets.ts` import. Grouped
 * into one object only so the constructor's options bag stays flat; each
 * function is independently injectable in tests.
 */
export interface GitHubTokenStorage {
  readonly readAccessToken: () => string | null;
  readonly writeAccessToken: (value: string) => void;
  readonly readRefreshToken: () => string | null;
  readonly writeRefreshToken: (value: string) => void;
}

/** An in-memory token pair for tests and for any caller without a real
 *  `secrets.ts`-backed pair wired up yet — mirrors `InMemoryPatchQueueStorage`
 *  and `InMemoryInstallIdentityPersistence` elsewhere in `services/maintain/`. */
export class InMemoryGitHubTokenStorage implements GitHubTokenStorage {
  private accessToken: string | null = null;
  private refreshToken: string | null = null;

  readAccessToken = (): string | null => this.accessToken;
  writeAccessToken = (value: string): void => {
    this.accessToken = value;
  };
  readRefreshToken = (): string | null => this.refreshToken;
  writeRefreshToken = (value: string): void => {
    this.refreshToken = value;
  };
}

// ---------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------

const GITHUB_API_BASE_URL = "https://api.github.com";
const DEVICE_CODE_URL = "https://github.com/login/device/code";
const OAUTH_TOKEN_URL = "https://github.com/login/oauth/access_token";
const GITHUB_API_VERSION = "2022-11-28";

export class GitHubForkService {
  private connectState: GitHubConnectState;
  private lastBackupSummary: string | null = null;

  private readonly clientId: string | null;
  private readonly tokenStorage: GitHubTokenStorage;
  private readonly fetchImplementation: FetchLike;
  private readonly sleepMs: (milliseconds: number) => Promise<void>;
  private readonly nowEpochMs: () => number;
  private readonly openExternal: (url: string) => Promise<void> | void;

  constructor(options: {
    /** Defaults to `process.env.IRIS_GITHUB_APP_CLIENT_ID` — see the file
     *  header's second INTERLOCK note. Pass an explicit value (including
     *  `null`) in tests to avoid depending on the environment. */
    clientId?: string | null;
    tokenStorage: GitHubTokenStorage;
    fetchImplementation?: FetchLike;
    /** Injected so the device-flow poll loop and the fork-readiness backoff
     *  are testable without a real wait. Defaults to a real `setTimeout`. */
    sleepMs?: (milliseconds: number) => Promise<void>;
    /** Injected alongside `sleepMs` so `connect()`'s expiry deadline is
     *  testable without a real multi-second wait — mirrors
     *  `install-identity.ts`'s `nowEpochMs` seam. Defaults to `Date.now`. */
    nowEpochMs?: () => number;
    /** Opens `verification_uri` for the user once the device code is ready —
     *  an injected side effect so this file never imports `electron.shell`,
     *  matching the porting spec's explicit design for this seam. Optional:
     *  the panel can just as well show the code and let the user navigate
     *  themselves, the way Swift's `GitHubConnectState.awaitingUserCode` did. */
    openExternal?: (url: string) => Promise<void> | void;
  }) {
    const resolvedClientId =
      options.clientId !== undefined ? options.clientId : (process.env.IRIS_GITHUB_APP_CLIENT_ID ?? null);
    this.clientId = resolvedClientId && resolvedClientId.length > 0 ? resolvedClientId : null;
    this.tokenStorage = options.tokenStorage;
    this.fetchImplementation = options.fetchImplementation ?? (globalThis.fetch as unknown as FetchLike);
    this.sleepMs = options.sleepMs ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
    this.nowEpochMs = options.nowEpochMs ?? (() => Date.now());
    this.openExternal = options.openExternal ?? (() => undefined);

    if (this.clientId === null) {
      this.connectState = { type: "unavailable" };
    } else if (this.tokenStorage.readRefreshToken() !== null) {
      this.connectState = { type: "connected", login: "" };
    } else {
      this.connectState = { type: "not_connected" };
    }
  }

  currentConnectState(): GitHubConnectState {
    return this.connectState;
  }

  /** One line for the panel after a backup ("saved to github.com/you/cue"). */
  currentLastBackupSummary(): string | null {
    return this.lastBackupSummary;
  }

  // -------------------------------------------------------------------------
  // Device flow
  // -------------------------------------------------------------------------

  /**
   * Starts the handshake and updates `currentConnectState()` to the code to
   * show. Polls until the user finishes at github.com/login/device or the
   * code expires. `onStateChange`, if given, fires on every transition — the
   * TS answer to Swift's `@Published connectState`.
   */
  async connect(onStateChange?: (state: GitHubConnectState) => void): Promise<void> {
    const setState = (state: GitHubConnectState): void => {
      this.connectState = state;
      onStateChange?.(state);
    };

    if (this.clientId === null) {
      setState({ type: "unavailable" });
      return;
    }
    const clientId = this.clientId;

    const start = await this.postForm(DEVICE_CODE_URL, { client_id: clientId });
    const deviceCode = readString(start, "device_code");
    const userCode = readString(start, "user_code");
    const verificationUrl = readString(start, "verification_uri");
    const expiresInSeconds = readNumber(start, "expires_in");
    if (deviceCode === null || userCode === null || verificationUrl === null || expiresInSeconds === null) {
      setState({ type: "not_connected" });
      return;
    }

    setState({ type: "awaiting_user_code", userCode, verificationUrl });
    maintainTrace("github: device flow started (code shown to user)");
    try {
      await this.openExternal(verificationUrl);
    } catch {
      // The user can still type the code in manually — this is a convenience,
      // never a requirement for the handshake to proceed.
    }

    const deadlineEpochMs = this.nowEpochMs() + expiresInSeconds * 1000;
    let pollIntervalMs = (readNumber(start, "interval") ?? 5) * 1000;

    while (this.nowEpochMs() < deadlineEpochMs) {
      await this.sleepMs(pollIntervalMs);
      const token = await this.postForm(OAUTH_TOKEN_URL, {
        client_id: clientId,
        device_code: deviceCode,
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
      });
      const errorCode = readString(token, "error");
      if (errorCode === "slow_down") {
        pollIntervalMs += 5000;
        continue;
      }
      if (errorCode === "authorization_pending") {
        continue;
      }
      const accessToken = readString(token, "access_token");
      if (accessToken !== null) {
        this.tokenStorage.writeAccessToken(accessToken);
        const refreshToken = readString(token, "refresh_token");
        if (refreshToken !== null) {
          this.tokenStorage.writeRefreshToken(refreshToken);
        }
        const login = (await this.authenticatedLogin(accessToken)) ?? "";
        setState({ type: "connected", login });
        maintainTrace("github: connected");
        return;
      }
      if (errorCode !== null) {
        break;
      }
    }
    setState({ type: "not_connected" });
  }

  /**
   * A usable access token, refreshing through the 6-month token when the
   * 8-hour one has aged out. `null` = not connected (or the refresh was
   * revoked).
   */
  private async currentAccessToken(): Promise<string | null> {
    const stored = this.tokenStorage.readAccessToken();
    if (stored !== null && (await this.authenticatedLogin(stored)) !== null) {
      return stored;
    }
    if (this.clientId === null) {
      return null;
    }
    const refreshToken = this.tokenStorage.readRefreshToken();
    if (refreshToken === null) {
      return null;
    }
    const refreshed = await this.postForm(OAUTH_TOKEN_URL, {
      client_id: this.clientId,
      grant_type: "refresh_token",
      refresh_token: refreshToken,
    });
    const accessToken = readString(refreshed, "access_token");
    if (accessToken === null) {
      return null;
    }
    this.tokenStorage.writeAccessToken(accessToken);
    const newRefreshToken = readString(refreshed, "refresh_token");
    if (newRefreshToken !== null) {
      this.tokenStorage.writeRefreshToken(newRefreshToken);
    }
    return accessToken;
  }

  // -------------------------------------------------------------------------
  // The backup
  // -------------------------------------------------------------------------

  /**
   * Fork (if needed), push the given branch, and fast-forward the fork's
   * default branch to upstream. `canonicalRepo` is "owner/name".
   */
  async backUp(options: {
    readonly branch: string;
    readonly canonicalRepo: string;
    readonly cloneRunner: MaintainShellRunner;
  }): Promise<ForkBackupOutcome> {
    const accessToken = await this.currentAccessToken();
    if (accessToken === null) {
      return { type: "not_connected" };
    }
    const login = await this.authenticatedLogin(accessToken);
    if (login === null) {
      return { type: "not_connected" };
    }

    const repoName = lastPathComponent(options.canonicalRepo);
    if (repoName.length === 0) {
      return { type: "failed", reason: "bad canonical repo" };
    }

    // Collision check before any fork call. An unrelated same-named repo is
    // the user's business, never ours to rename or reuse.
    const relationship = await this.repoRelationship({
      owner: login,
      name: repoName,
      canonicalRepo: options.canonicalRepo,
      token: accessToken,
    });
    if (relationship === "unrelated_repo") {
      return { type: "name_collision_needs_the_user", existingRepoUrl: `https://github.com/${login}/${repoName}` };
    }
    if (relationship === "absent") {
      const created = await this.createFork(options.canonicalRepo, accessToken);
      if (!created) {
        return { type: "failed", reason: "fork creation failed" };
      }
      // 202: forking is async — usually seconds, documented up to five
      // minutes. Poll with backoff; give up politely rather than hang.
      const ready = await this.waitForForkReady({
        owner: login,
        name: repoName,
        canonicalRepo: options.canonicalRepo,
        token: accessToken,
      });
      if (!ready) {
        return { type: "failed", reason: "fork not ready after two minutes" };
      }
    }

    const pushUrl = `https://x-access-token:${accessToken}@github.com/${login}/${repoName}.git`;
    const pushResult = await this.pushBranch({ runner: options.cloneRunner, pushUrl, branch: options.branch });
    if (pushResult === undefined || !pushResult.succeeded) {
      return { type: "failed", reason: "push failed" };
    }

    // Keep the fork's default branch a mirror of upstream. GitHub refuses
    // with a PR suggestion when it would conflict — which is fine; the fix
    // branch above is already safe.
    const base = (await this.defaultBranch(login, repoName, accessToken)) ?? "main";
    await this.apiRequest({
      method: "POST",
      path: `/repos/${login}/${repoName}/merge-upstream`,
      token: accessToken,
      jsonBody: { branch: base },
    });

    const forkUrl = `https://github.com/${login}/${repoName}`;
    this.lastBackupSummary = `Backed up to ${login}/${repoName} (${options.branch})`;
    maintainTrace(`github: pushed ${options.branch} to the user's fork of ${options.canonicalRepo}`);
    return { type: "backed_up", forkUrl, branch: options.branch };
  }

  private async waitForForkReady(options: {
    readonly owner: string;
    readonly name: string;
    readonly canonicalRepo: string;
    readonly token: string;
  }): Promise<boolean> {
    let waitedMs = 0;
    let intervalMs = 2000;
    while (waitedMs < 120_000) {
      await this.sleepMs(intervalMs);
      waitedMs += intervalMs;
      intervalMs = Math.min(intervalMs * 1.5, 15_000);
      if ((await this.repoRelationship(options)) === "is_our_fork") {
        return true;
      }
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Ownership-aware propagation
  // -------------------------------------------------------------------------

  /** Propagate a verified fix as far as the user's rights allow. */
  async propagateFix(options: {
    readonly branch: string;
    readonly canonicalRepo: string;
    readonly diagnosisTitle: string;
    readonly cloneRunner: MaintainShellRunner;
  }): Promise<FixPropagation> {
    const accessToken = await this.currentAccessToken();
    if (accessToken === null) {
      return { type: "not_connected" };
    }
    const login = await this.authenticatedLogin(accessToken);
    if (login === null) {
      return { type: "not_connected" };
    }

    const [owner, repoName] = splitOwnerRepo(options.canonicalRepo);
    if (owner.length === 0 || repoName.length === 0) {
      return { type: "failed", reason: "bad canonical repo" };
    }

    if (await this.authenticatedUserCanPush(options.canonicalRepo, accessToken)) {
      // Owner path: push the branch straight to canonical and merge it into
      // the default branch. It is their repo and the fix already passed the
      // full verification gate — no ceremony.
      const pushUrl = `https://x-access-token:${accessToken}@github.com/${options.canonicalRepo}.git`;
      const pushResult = await this.pushBranch({ runner: options.cloneRunner, pushUrl, branch: options.branch });
      if (pushResult === undefined || !pushResult.succeeded) {
        return { type: "failed", reason: "push to canonical failed" };
      }
      const base = (await this.defaultBranch(owner, repoName, accessToken)) ?? "main";
      const merge = await this.apiRequest({
        method: "POST",
        path: `/repos/${options.canonicalRepo}/merges`,
        token: accessToken,
        jsonBody: { base, head: options.branch, commit_message: `Iris: ${options.diagnosisTitle}` },
      });
      const mergedSha = merge !== null && isRecord(merge.json) ? readString(merge.json, "sha") : null;
      maintainTrace(`github: owner path — merged ${options.branch} into ${options.canonicalRepo}@${base}`);
      this.lastBackupSummary = `Fixed and merged into ${options.canonicalRepo}`;
      return { type: "merged_to_canonical", repo: options.canonicalRepo, commitSha: mergedSha };
    }

    // Non-owner path: the fork backup (which handles fork creation and the
    // push), then open a PR from the fork onto canonical.
    const backup = await this.backUp({
      branch: options.branch,
      canonicalRepo: options.canonicalRepo,
      cloneRunner: options.cloneRunner,
    });
    if (backup.type !== "backed_up") {
      if (backup.type === "name_collision_needs_the_user") {
        return { type: "failed", reason: "repo name collision" };
      }
      if (backup.type === "not_connected") {
        return { type: "not_connected" };
      }
      return { type: "failed", reason: "fork backup failed" };
    }

    const base = (await this.defaultBranch(owner, repoName, accessToken)) ?? "main";
    const pullRequest = await this.apiRequest({
      method: "POST",
      path: `/repos/${options.canonicalRepo}/pulls`,
      token: accessToken,
      jsonBody: {
        title: `Iris fix: ${options.diagnosisTitle}`,
        head: `${login}:${options.branch}`,
        base,
        body: pullRequestBody(options.diagnosisTitle),
        maintainer_can_modify: true,
      },
    });
    // 422 (a PR from this head already exists) and every other non-201 falls
    // through to "backed up only" — the fork backup already happened and is
    // never lost even when opening the PR itself does not succeed.
    if (pullRequest !== null && pullRequest.status === 201 && isRecord(pullRequest.json)) {
      const url = readString(pullRequest.json, "html_url");
      const number = readNumber(pullRequest.json, "number");
      if (url !== null && number !== null) {
        maintainTrace(`github: non-owner path — opened PR #${number} on ${options.canonicalRepo}`);
        this.lastBackupSummary = `Opened a fix PR on ${options.canonicalRepo} for its owner to review`;
        return { type: "pull_request_opened", url, number };
      }
    }
    return { type: "backed_up_only", forkUrl: backup.forkUrl, branch: backup.branch };
  }

  // -------------------------------------------------------------------------
  // Owner side: incoming fix PRs
  // -------------------------------------------------------------------------

  /**
   * The `iris/fix-*` PRs open on one of the owner's repos, for their Iris to
   * re-verify (`incoming-fix-reviewer.ts`) and decide. Only PRs from Iris's
   * branch convention are surfaced; a human contributor's PR is the owner's
   * normal GitHub flow.
   */
  async incomingFixPullRequests(canonicalRepo: string): Promise<readonly IncomingFixPR[]> {
    const token = await this.currentAccessToken();
    if (token === null) {
      return [];
    }
    const result = await this.apiRequest({
      method: "GET",
      path: `/repos/${canonicalRepo}/pulls?state=open&per_page=30`,
      token,
    });
    if (result === null || result.status !== 200 || !Array.isArray(result.json)) {
      return [];
    }

    const pullRequests: IncomingFixPR[] = [];
    for (const entry of result.json) {
      if (!isRecord(entry)) continue;
      const head = isRecord(entry.head) ? entry.head : null;
      const branch = head !== null ? readString(head, "ref") : null;
      const headRepo = head !== null && isRecord(head.repo) ? head.repo : null;
      const cloneUrl = headRepo !== null ? readString(headRepo, "clone_url") : null;
      const number = readNumber(entry, "number");
      const title = readString(entry, "title");
      const url = readString(entry, "html_url");
      if (
        branch === null ||
        !branch.startsWith("iris/fix-") ||
        cloneUrl === null ||
        number === null ||
        title === null ||
        url === null
      ) {
        continue;
      }
      pullRequests.push({ repo: canonicalRepo, number, title, headRepoCloneUrl: cloneUrl, headBranch: branch, url });
    }
    return pullRequests;
  }

  /**
   * Merge an incoming fix PR the owner (or their Iris, after re-verifying via
   * `incoming-fix-reviewer.ts`) approved. Squash so the canonical history
   * stays one-commit-per-fix.
   */
  async mergeIncomingFixPR(pr: IncomingFixPR): Promise<boolean> {
    const token = await this.currentAccessToken();
    if (token === null) {
      return false;
    }
    const result = await this.apiRequest({
      method: "PUT",
      path: `/repos/${pr.repo}/pulls/${pr.number}/merge`,
      token,
      jsonBody: { merge_method: "squash", commit_title: `Iris fix: ${pr.title}` },
    });
    return result !== null && result.status === 200;
  }

  // -------------------------------------------------------------------------
  // GitHub API plumbing
  // -------------------------------------------------------------------------

  private async repoRelationship(options: {
    readonly owner: string;
    readonly name: string;
    readonly canonicalRepo: string;
    readonly token: string;
  }): Promise<"absent" | "is_our_fork" | "unrelated_repo"> {
    const result = await this.apiRequest({ method: "GET", path: `/repos/${options.owner}/${options.name}`, token: options.token });
    if (result === null || result.status !== 200 || !isRecord(result.json)) {
      return "absent";
    }
    const isFork = result.json.fork === true;
    const parent = isRecord(result.json.parent) ? result.json.parent : null;
    const parentFullName = parent !== null ? readString(parent, "full_name") : null;
    if (isFork && parentFullName !== null && parentFullName.toLowerCase() === options.canonicalRepo.toLowerCase()) {
      return "is_our_fork";
    }
    return "unrelated_repo";
  }

  private async createFork(canonicalRepo: string, token: string): Promise<boolean> {
    const result = await this.apiRequest({ method: "POST", path: `/repos/${canonicalRepo}/forks`, token, jsonBody: {} });
    return result !== null && (result.status === 202 || result.status === 200);
  }

  private async defaultBranch(owner: string, name: string, token: string): Promise<string | null> {
    const result = await this.apiRequest({ method: "GET", path: `/repos/${owner}/${name}`, token });
    if (result === null || result.status !== 200 || !isRecord(result.json)) {
      return null;
    }
    return readString(result.json, "default_branch");
  }

  private async authenticatedUserCanPush(repo: string, token: string): Promise<boolean> {
    const result = await this.apiRequest({ method: "GET", path: `/repos/${repo}`, token });
    if (result === null || result.status !== 200 || !isRecord(result.json)) {
      return false;
    }
    const permissions = isRecord(result.json.permissions) ? result.json.permissions : null;
    return permissions !== null && (permissions.push === true || permissions.admin === true);
  }

  private async authenticatedLogin(token: string): Promise<string | null> {
    const result = await this.apiRequest({ method: "GET", path: "/user", token });
    if (result === null || result.status !== 200 || !isRecord(result.json)) {
      return null;
    }
    return readString(result.json, "login");
  }

  /**
   * Pushes a branch to a one-shot token-bearing URL. The URL and the token it
   * carries are never passed to `maintainTrace` or included in any returned
   * `reason` string, anywhere in this file — the outcome types above only
   * ever carry canned, static reasons (`"push failed"`, never command output)
   * exactly like Swift's `failed(reason:)` cases. The command itself is
   * single-quoted (doubling embedded quotes) rather than double-quoted or
   * interpolated raw, so a URL or branch name is inert text to whichever
   * shell the real `MaintainShellRunner` ends up running it through —
   * PowerShell and POSIX shells both honor that escaping for a literal.
   */
  private async pushBranch(options: {
    readonly runner: MaintainShellRunner;
    readonly pushUrl: string;
    readonly branch: string;
  }): Promise<MaintainCommandResult | undefined> {
    const command = `git push ${singleQuoteForShell(options.pushUrl)} ${singleQuoteForShell(`HEAD:refs/heads/${options.branch}`)} --force-with-lease`;
    try {
      return await options.runner.run(command, { deadlineMs: 300_000 });
    } catch {
      return undefined;
    }
  }

  private async apiRequest(options: {
    readonly method: string;
    readonly path: string;
    readonly token: string;
    readonly jsonBody?: Record<string, unknown>;
  }): Promise<{ readonly status: number; readonly json: unknown } | null> {
    try {
      const headers: Record<string, string> = {
        Authorization: `Bearer ${options.token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": GITHUB_API_VERSION,
      };
      if (options.jsonBody !== undefined) {
        headers["Content-Type"] = "application/json";
      }
      const response = await this.fetchImplementation(`${GITHUB_API_BASE_URL}${options.path}`, {
        method: options.method,
        headers,
        body: options.jsonBody !== undefined ? JSON.stringify(options.jsonBody) : undefined,
      });
      const rawBody = await response.text();
      return { status: response.status, json: parseJsonOrNull(rawBody) };
    } catch {
      return null;
    }
  }

  private async postForm(url: string, body: Record<string, string>): Promise<unknown> {
    try {
      const encodedBody = Object.entries(body)
        .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
        .join("&");
      const response = await this.fetchImplementation(url, {
        method: "POST",
        headers: { Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" },
        body: encodedBody,
      });
      return parseJsonOrNull(await response.text());
    } catch {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Small local helpers — kept here rather than pulled from a shared module so
// this file adds no dependency beyond `pool-client.ts`'s `FetchLike` type and
// `maintain-shell-runner.ts`'s runner type, both already-landed siblings.
// ---------------------------------------------------------------------------

function pullRequestBody(diagnosisTitle: string): string {
  return [
    "Iris (publik's maintain mode) fixed a bug on a user's machine and verified it — the repro fails before the patch, passes after, and fails again when the patch is reverted, and the full test suite stays green. Opened for you, the owner, to review and merge.",
    "",
    `Diagnosis: ${diagnosisTitle}`,
    "",
    "The change is scoped to the reported symptom; the verification detail is in the commit trailer.",
  ].join("\n");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function readString(value: unknown, key: string): string | null {
  if (!isRecord(value)) return null;
  const field = value[key];
  return typeof field === "string" ? field : null;
}

function readNumber(value: unknown, key: string): number | null {
  if (!isRecord(value)) return null;
  const field = value[key];
  return typeof field === "number" ? field : null;
}

function parseJsonOrNull(rawBody: string): unknown {
  if (rawBody.length === 0) return null;
  try {
    return JSON.parse(rawBody);
  } catch {
    return null;
  }
}

function lastPathComponent(canonicalRepo: string): string {
  const parts = canonicalRepo.split("/");
  return parts[parts.length - 1] ?? "";
}

function splitOwnerRepo(canonicalRepo: string): readonly [string, string] {
  const parts = canonicalRepo.split("/");
  return [parts[0] ?? "", parts[1] ?? ""];
}

/** Quotes a value as a single-quoted shell literal (doubling embedded single
 *  quotes) — a local copy of the same escaping `main/powershell-session.ts`'s
 *  `psSingleQuote` uses, kept local rather than imported because this module
 *  must never import `child_process` (see the porting spec's ground rules;
 *  `main/powershell-session.ts` pulls it in at module scope). Safe under both
 *  PowerShell and POSIX shells, so it stays correct regardless of which one
 *  the real `MaintainShellRunner` ends up running the command through. */
function singleQuoteForShell(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}
