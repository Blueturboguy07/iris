/**
 * app-inventory.ts
 *
 * The Windows port of the composition macOS spreads across
 * `AppInventoryService.swift` and `CompanionManager`'s `matchCatalogApp` /
 * `catalogAppStacksBySlug` / `frontmostCatalogAppSlug`. It answers the three
 * questions maintain mode's always-on layer needs before it may raise a single
 * question of its own:
 *
 *   1. WHO'S INSTALLED — which publik catalog apps are on this machine. Fed by
 *      the read-only catalog (`GET {publik}/api/iris/apps`, injected fetch) for
 *      the roster, plus an injected installed-resolution seam whose real
 *      default is a known-path existence check (see below).
 *   2. WHAT STACK a slug is on — a static `slug → BreakAppStack` dict, copied
 *      verbatim from macOS's `catalogAppStacksBySlug`. A stopgap until the
 *      server carries `app_stack` on `/api/iris/apps`; documented as such on
 *      both clients.
 *   3. WHO'S FRONTMOST — the process the OS reports as foreground, resolved to a
 *      catalog slug. Backed by an injected PowerShell `GetForegroundWindow` →
 *      process-name seam, with the parse split out as a pure, tested helper.
 *
 * The `CrashArtifactWatcher` (crash-watcher.ts) and the frontmost hang tick (in
 * `main/maintain/controller.ts`) both reach the catalog through this file's
 * `CrashArtifactAppMatching` implementation and `frontmostCatalogApp()`.
 *
 * ## The load-bearing Windows divergence: identity is by EXE NAME, not bundle id
 *
 * macOS resolves EVERY catalog app's install state cheaply and reliably from a
 * `macBundleId` LaunchServices lookup, so its matcher can gate on "is this app
 * installed" for all of them. Windows has no equivalent: `/api/iris/apps`
 * carries `macBundleId` and NOTHING that names a Windows `.exe` (see
 * `app/api/iris/apps/route.ts` — the field simply is not there, the same gap
 * `crash-watcher.ts`'s header flags). A WER crash artifact and a foreground
 * query both identify a process by its executable file name
 * (`publikclip-app.exe`), which does not equal the catalog display name
 * (`publikclip`). So this file carries a small, reviewed `slug → exe name`
 * table — `WINDOWS_CATALOG_APPS` below — the Windows analog of the knowledge
 * macOS gets for free from the OS. Only apps whose Windows exe has been
 * established (verified against a real build) appear in it; the rest are
 * unrecognizable by exe alone and are simply not matched, which is the honest
 * answer rather than a guessed one.
 *
 * A consequence, and a deliberate one: the crash/hang matcher keys off exe
 * identity, NOT the installed-resolution seam. A WER report or a foreground
 * reading for `publikclip-app.exe` is itself proof publikclip ran on this
 * machine — requiring a second, separate filesystem/registry check to agree
 * would only add a race (the app uninstalled in the window between the crash
 * and the check) without adding truth. The installed-resolution seam therefore
 * feeds `installedCatalogSlugs()` / `isInstalled()` — the inventory roster a
 * future "Your publik apps" panel shows — and is intentionally not on the crash
 * path. This is flagged here rather than papered over, per the porting spec's
 * ground rules.
 *
 * ## Pure decision logic vs. real I/O (ground rule: testable on any OS)
 *
 * Every real I/O call — the catalog fetch, the foreground-process PowerShell
 * one-liner, the installed-path existence check — is an injected seam with a
 * real default exported from this same file, exactly the convention
 * `crash-watcher.ts`, `hang-probe.ts`, and `install-provenance.ts` already use.
 * The parse helpers (`parseForegroundProcessOutput`, `slugForProcessName`,
 * `expandWindowsEnvironmentTokens`) are pure and individually tested. Nothing
 * in the class holds a reference to `child_process` or `fetch` unless it was
 * handed one, so the whole file runs identically in the vitest suite on this
 * Mac and on windows-latest CI. The real foreground one-liner and the real
 * installed-path check only do anything meaningful on Windows, and a caller
 * wires them in explicitly — the class defaults never spawn `powershell.exe` on
 * a host that has none.
 */

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { DEFAULT_PUBLIK_BASE_URL } from "../assistant-transport";
import type { BreakAppStack } from "./break-signature";
import type { CrashArtifactAppMatching } from "./crash-watcher";
import { maintainTrace } from "./trace";

// ---------------------------------------------------------------------------
// The static slug → stack dict — copied verbatim from macOS's
// `CompanionManager.catalogAppStacksBySlug`. Server-provided later; a table
// here first because `/api/iris/apps` does not carry `app_stack` yet.
// ---------------------------------------------------------------------------

/** Which stack each catalog app is built on, for signature normalization. Kept
 *  byte-identical to the macOS dict of the same purpose so the two clients
 *  bucket a given app's breaks the same way. */
export const CATALOG_APP_STACKS_BY_SLUG: Readonly<Record<string, BreakAppStack>> = {
  cue: "electron",
  whimprflow: "tauri",
  hickeyfield: "tauri",
  plantgpt: "electron",
  publikclip: "tauri",
  nutcracker: "nextjs",
  openascii: "nextjs",
  noscroll: "other",
  lunara: "other",
};

/** The stack for a slug, defaulting to `"other"` exactly as macOS's
 *  `Self.catalogAppStacksBySlug[entry.slug] ?? .other` does. */
export function stackForSlug(slug: string): BreakAppStack {
  return CATALOG_APP_STACKS_BY_SLUG[slug] ?? "other";
}

// ---------------------------------------------------------------------------
// The Windows exe → slug table (see the file header's divergence note).
// ---------------------------------------------------------------------------

/** One catalog app whose Windows install identity has been established. */
export interface WindowsCatalogApp {
  readonly slug: string;
  /** The display name to show and to hand the ask card. */
  readonly appName: string;
  readonly stack: BreakAppStack;
  /** The installed executable's file name, as a WER report's `Application
   *  Name` and a foreground-process query both report it — e.g.
   *  `"publikclip-app.exe"`. Matching is case-insensitive and tolerant of a
   *  missing `.exe` suffix (`Get-Process` reports the base name). */
  readonly exeName: string;
  /** Absolute path of the installed exe, with `%VAR%` environment tokens left
   *  unexpanded so this stays a plain data literal; `expandWindowsEnvironmentTokens`
   *  expands them at check time. This is the known path the default
   *  installed-resolution seam tests for existence. */
  readonly installedExePathTemplate: string;
}

/**
 * The reviewed roster of catalog apps recognizable on Windows by their exe.
 * Only publikclip today: it is the one catalog app with a green windows-latest
 * CI + NSIS installer and a verified installed exe name (`publikclip-app.exe`,
 * installed under `%LOCALAPPDATA%\publikclip` — read off the repo's own
 * `windows.yml` and `app/package.json`). New entries are added the same way:
 * from a real, validated Windows build, never a guess.
 */
export const WINDOWS_CATALOG_APPS: readonly WindowsCatalogApp[] = [
  {
    slug: "publikclip",
    appName: "publikclip",
    stack: stackForSlug("publikclip"),
    exeName: "publikclip-app.exe",
    installedExePathTemplate: "%LOCALAPPDATA%\\publikclip\\publikclip-app.exe",
  },
];

/** Normalizes an exe-shaped name to lowercase and strips one trailing `.exe`,
 *  so `"publikclip-app.exe"`, `"publikclip-app"`, and `"PUBLIKCLIP-APP.EXE"`
 *  all compare equal — WER writes the full file name, `Get-Process` writes the
 *  base name, and neither is case-authoritative on Windows. */
function normalizeExeName(name: string): string {
  const lowered = name.trim().toLowerCase();
  return lowered.endsWith(".exe") ? lowered.slice(0, -".exe".length) : lowered;
}

/** The catalog slug a process (identified by its exe name) belongs to, or
 *  `undefined` for anything not in the reviewed Windows roster. Pure and
 *  directly tested. */
export function slugForProcessName(processName: string): string | undefined {
  const normalized = normalizeExeName(processName);
  const match = WINDOWS_CATALOG_APPS.find((app) => normalizeExeName(app.exeName) === normalized);
  return match?.slug;
}

/** The `WindowsCatalogApp` for a slug, if it is in the reviewed Windows
 *  roster. */
export function windowsCatalogAppForSlug(slug: string): WindowsCatalogApp | undefined {
  return WINDOWS_CATALOG_APPS.find((app) => app.slug === slug);
}

// ---------------------------------------------------------------------------
// The catalog fetch — `GET {publik}/api/iris/apps`, injected fetch.
// ---------------------------------------------------------------------------

/** One row of `/api/iris/apps`, shaped exactly as `app/api/iris/apps/route.ts`
 *  serves it (read directly, not inferred). `macBundleId` is a macOS field with
 *  no Windows use, kept because it is on the wire — this file never reads it. */
export interface CatalogAppDescriptor {
  readonly slug: string;
  readonly name: string;
  readonly macBundleId: string | null;
  readonly latestReleaseTag: string | null;
}

/** The fetch seam, shaped like `MaintainPoolFetchLike` in `pool-client.ts` — a
 *  minimal subset of the real `fetch` so a test can hand in a fake with no
 *  `Response` object. */
export type CatalogFetchLike = (
  url: string,
  init: { readonly method: string; readonly headers?: Record<string, string> }
) => Promise<{ readonly ok: boolean; readonly status: number; readonly text: () => Promise<string> }>;

export interface FetchCatalogAppsOptions {
  readonly publikBaseUrl?: string;
  readonly fetchImplementation?: CatalogFetchLike;
}

/**
 * Reads the catalog from publik. Not-throwing by design, matching
 * `pool-client.ts`'s stance: a catalog read that fails returns an empty list
 * ("could not read" is treated the same as "nothing there") rather than
 * throwing into a caller whose whole job is to keep quietly watching. The
 * default fetch is the platform `fetch`; on a host without one (or under a
 * test that forgot to inject) it simply yields an empty catalog.
 */
export async function fetchCatalogApps(options: FetchCatalogAppsOptions = {}): Promise<CatalogAppDescriptor[]> {
  const publikBaseUrl = options.publikBaseUrl ?? DEFAULT_PUBLIK_BASE_URL;
  const fetchImplementation = options.fetchImplementation ?? platformFetch();
  if (fetchImplementation === undefined) {
    maintainTrace("app-inventory: no fetch available — catalog left empty");
    return [];
  }

  try {
    const response = await fetchImplementation(`${publikBaseUrl}/api/iris/apps`, {
      method: "GET",
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      maintainTrace(`app-inventory: catalog fetch returned ${response.status} — treating as empty`);
      return [];
    }
    const parsed = JSON.parse(await response.text()) as { apps?: CatalogAppDescriptor[] };
    return Array.isArray(parsed.apps) ? parsed.apps : [];
  } catch (error) {
    maintainTrace(`app-inventory: catalog fetch failed (${error instanceof Error ? error.message : String(error)}) — empty`);
    return [];
  }
}

/** The platform `fetch` as a `CatalogFetchLike`, or `undefined` where there is
 *  none. Kept behind a function so the class never captures a `fetch`
 *  reference at import time. */
function platformFetch(): CatalogFetchLike | undefined {
  const globalFetch = (globalThis as { fetch?: unknown }).fetch;
  if (typeof globalFetch !== "function") return undefined;
  return (url, init) => (globalFetch as (u: string, i: unknown) => Promise<{ ok: boolean; status: number; text: () => Promise<string> }>)(url, init);
}

// ---------------------------------------------------------------------------
// Installed-app resolution — the injected seam whose real default is a
// known-path existence check (see the file header on why registry keys are the
// alternative, not the choice).
// ---------------------------------------------------------------------------

/** Expands `%VAR%` Windows environment tokens in a path against `env`
 *  (defaulting to `process.env`), leaving an unknown token in place rather than
 *  producing a half-empty path. Pure over its `env` argument, so a test can
 *  supply a fixed environment. */
export function expandWindowsEnvironmentTokens(
  pathTemplate: string,
  env: Readonly<Record<string, string | undefined>> = process.env
): string {
  return pathTemplate.replace(/%([^%]+)%/g, (whole, name: string) => env[name] ?? whole);
}

/** Whether a catalog app is installed on this machine. A seam so tests never
 *  depend on what is actually installed. */
export interface InstalledCatalogAppResolving {
  isInstalled(app: WindowsCatalogApp): boolean;
}

/** The real default: the app's known install path exists on disk. The path
 *  strings are the only Windows-specific part (like `crash-watcher.ts`'s WER
 *  paths); `existsSync` itself is plain `node:fs`, so this is the same
 *  convention `install-provenance.ts`'s `gitDirectoryExists` already uses. A
 *  Tauri NSIS install also writes an uninstall registry key, but a path check
 *  needs no Windows API and is exactly as authoritative for "is it there". */
export class KnownPathInstalledCatalogAppResolver implements InstalledCatalogAppResolving {
  constructor(private readonly env: Readonly<Record<string, string | undefined>> = process.env) {}

  isInstalled(app: WindowsCatalogApp): boolean {
    try {
      return existsSync(expandWindowsEnvironmentTokens(app.installedExePathTemplate, this.env));
    } catch {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// The frontmost-app read — an injected PowerShell `GetForegroundWindow` →
// process-name seam. The parse is pure and tested; the spawn is the real
// default, wired in explicitly on Windows.
// ---------------------------------------------------------------------------

/** What a foreground read yields: the pid and exe name of whatever window is
 *  in front, or `undefined` when nothing could be read. */
export interface ForegroundProcess {
  readonly pid: number;
  readonly processName: string;
}

/** The seam a caller supplies to answer "what is frontmost right now?". The
 *  real implementation is `readForegroundProcessViaPowerShell`; tests hand in a
 *  fake. */
export type ReadForegroundProcess = () => Promise<ForegroundProcess | undefined>;

/** The one-liner that reads the foreground window's owning process. Uses a
 *  tiny `Add-Type` P/Invoke of `GetForegroundWindow` +
 *  `GetWindowThreadProcessId` (there is no PowerShell built-in for the
 *  foreground window), then prints `"<pid>|<processName>.exe"` on one line for
 *  `parseForegroundProcessOutput` to read. Exported and pure so a test can
 *  assert the exact command without spawning anything. */
export function buildForegroundProcessCommand(): string {
  return [
    "Add-Type -Namespace IrisFg -Name Win -MemberDefinition '",
    "[DllImport(\"user32.dll\")] public static extern System.IntPtr GetForegroundWindow();",
    "[DllImport(\"user32.dll\")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);' ;",
    "$h = [IrisFg.Win]::GetForegroundWindow();",
    "$fgpid = 0; [void][IrisFg.Win]::GetWindowThreadProcessId($h, [ref]$fgpid);",
    "$p = Get-Process -Id $fgpid -ErrorAction SilentlyContinue;",
    "if ($p) { Write-Output (\"$($p.Id)|$($p.ProcessName).exe\") }",
  ].join(" ");
}

/** Parses `buildForegroundProcessCommand`'s stdout — the last non-empty line,
 *  `"<pid>|<processName>"`. Returns `undefined` for empty output (nothing in
 *  front, or the query found no process) or a line whose pid is not a positive
 *  integer. Pure and directly tested. */
export function parseForegroundProcessOutput(stdout: string): ForegroundProcess | undefined {
  const lines = stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const lastLine = lines[lines.length - 1];
  if (lastLine === undefined) return undefined;

  const separatorIndex = lastLine.indexOf("|");
  if (separatorIndex <= 0) return undefined;
  const pid = Number.parseInt(lastLine.slice(0, separatorIndex).trim(), 10);
  const processName = lastLine.slice(separatorIndex + 1).trim();
  if (!Number.isInteger(pid) || pid <= 0 || processName.length === 0) return undefined;
  return { pid, processName };
}

/** The minimal `ChildProcess` subset the real foreground read needs — narrow so
 *  a test can hand in a fake, mirroring `hang-probe.ts`'s `SpawnedProcessLike`. */
export interface SpawnedProcessLike {
  readonly stdout: { on(event: "data", listener: (chunk: string | Buffer) => void): void } | null;
  on(event: "error", listener: (error: Error) => void): void;
  on(event: "close", listener: (exitCode: number | null) => void): void;
  kill(): void;
}

export type SpawnPowerShellOneLiner = (command: string) => SpawnedProcessLike;

function defaultSpawnPowerShellOneLiner(command: string): SpawnedProcessLike {
  return spawn("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command], {
    windowsHide: true,
  });
}

export interface ReadForegroundProcessViaPowerShellOptions {
  readonly spawnPowerShellOneLiner?: SpawnPowerShellOneLiner;
  /** Bounds the one-liner. The `Add-Type` compile on first call is the slow
   *  part; 2.5s is generous and still keeps one stuck read from wedging the
   *  2s tick loop. */
  readonly timeoutMs?: number;
}

const DEFAULT_FOREGROUND_READ_TIMEOUT_MS = 2500;

/**
 * The real, Windows-only `ReadForegroundProcess`. A one-shot
 * `powershell.exe -Command` per read, like `hang-probe.ts`'s responsive check;
 * any failure (no `powershell.exe`, a blocked child process, a timeout, an
 * unparseable line) resolves to `undefined` — "cannot tell what is frontmost",
 * which the caller treats as "nothing of ours is frontmost", never as an error.
 */
export function readForegroundProcessViaPowerShell(
  options: ReadForegroundProcessViaPowerShellOptions = {}
): Promise<ForegroundProcess | undefined> {
  const spawnPowerShellOneLiner = options.spawnPowerShellOneLiner ?? defaultSpawnPowerShellOneLiner;
  const timeoutMs = options.timeoutMs ?? DEFAULT_FOREGROUND_READ_TIMEOUT_MS;

  return new Promise((resolve) => {
    let child: SpawnedProcessLike;
    try {
      child = spawnPowerShellOneLiner(buildForegroundProcessCommand());
    } catch {
      resolve(undefined);
      return;
    }
    let stdout = "";
    let settled = false;
    const finish = (value: ForegroundProcess | undefined): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(undefined);
    }, timeoutMs);

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.on("error", () => finish(undefined));
    child.on("close", () => finish(parseForegroundProcessOutput(stdout)));
  });
}

// ---------------------------------------------------------------------------
// The inventory itself.
// ---------------------------------------------------------------------------

/** What `frontmostCatalogApp()` resolves to when one of ours is in front. */
export interface FrontmostCatalogApp {
  readonly slug: string;
  readonly appName: string;
  readonly pid: number;
  readonly stack: BreakAppStack;
}

export interface WindowsAppInventoryOptions {
  /** Defaults to `readForegroundProcessViaPowerShell`. Injected so the
   *  frontmost path is testable without spawning `powershell.exe`. */
  readonly readForegroundProcess?: ReadForegroundProcess;
  /** Defaults to `KnownPathInstalledCatalogAppResolver`. */
  readonly installedResolver?: InstalledCatalogAppResolving;
  /** Defaults to `fetchCatalogApps` against the real publik base. */
  readonly fetchCatalogApps?: () => Promise<CatalogAppDescriptor[]>;
}

/**
 * The Windows composition of macOS's `AppInventoryService` +
 * `CompanionManager.matchCatalogApp`. Implements `CrashArtifactAppMatching`
 * (the crash watcher's seam) and exposes `frontmostCatalogApp()` (the hang
 * tick's) plus the installed roster.
 */
export class WindowsAppInventory implements CrashArtifactAppMatching {
  private readonly readForegroundProcess: ReadForegroundProcess;
  private readonly installedResolver: InstalledCatalogAppResolving;
  private readonly fetchCatalogAppsImpl: () => Promise<CatalogAppDescriptor[]>;

  /** Display names from the last catalog fetch, so the ask card can show the
   *  catalog's own name for a slug rather than the static table's. Empty until
   *  `refreshCatalog()` lands; the static roster's `appName` is the fallback. */
  private catalogNamesBySlug = new Map<string, string>();

  constructor(options: WindowsAppInventoryOptions = {}) {
    this.readForegroundProcess = options.readForegroundProcess ?? readForegroundProcessViaPowerShell;
    this.installedResolver = options.installedResolver ?? new KnownPathInstalledCatalogAppResolver();
    this.fetchCatalogAppsImpl = options.fetchCatalogApps ?? (() => fetchCatalogApps());
  }

  // MARK: - CrashArtifactAppMatching (the crash watcher's seam)

  /** The crash watcher's matcher: a WER `Application Name` (`"publikclip-app.exe"`)
   *  → its catalog slug + stack, or `undefined` for everything else on the
   *  machine. Keys off exe identity, not installed-resolution — see the file
   *  header for why a crash artifact is itself the installed proof. */
  catalogApp(processName: string): { readonly slug: string; readonly stack: BreakAppStack } | undefined {
    const slug = slugForProcessName(processName);
    if (slug === undefined) return undefined;
    return { slug, stack: stackForSlug(slug) };
  }

  // MARK: - Frontmost (the hang tick's seam)

  /** The catalog app in front right now, or `undefined` when what's frontmost
   *  is not one of ours (or cannot be read). The Windows analog of macOS's
   *  `frontmostCatalogAppSlug`, carrying the pid the hang probe needs. */
  async frontmostCatalogApp(): Promise<FrontmostCatalogApp | undefined> {
    const foreground = await this.readForegroundProcess();
    if (foreground === undefined) return undefined;
    const slug = slugForProcessName(foreground.processName);
    if (slug === undefined) return undefined;
    return { slug, appName: this.appNameForSlug(slug), pid: foreground.pid, stack: stackForSlug(slug) };
  }

  // MARK: - Installed roster (for a future "Your publik apps" panel)

  /** The slugs of the reviewed Windows catalog apps that are installed on this
   *  machine, via the installed-resolution seam. */
  installedCatalogSlugs(): Set<string> {
    const installed = new Set<string>();
    for (const app of WINDOWS_CATALOG_APPS) {
      if (this.installedResolver.isInstalled(app)) installed.add(app.slug);
    }
    return installed;
  }

  isInstalled(slug: string): boolean {
    const app = windowsCatalogAppForSlug(slug);
    return app !== undefined && this.installedResolver.isInstalled(app);
  }

  // MARK: - Catalog

  /** Fetches the catalog and remembers each app's display name. Best-effort:
   *  a failed fetch leaves the previous names in place, matching macOS's
   *  "keep the last known inventory rather than blanking it". */
  async refreshCatalog(): Promise<void> {
    const descriptors = await this.fetchCatalogAppsImpl();
    if (descriptors.length === 0) return;
    for (const descriptor of descriptors) {
      this.catalogNamesBySlug.set(descriptor.slug, descriptor.name);
    }
  }

  /** The best display name for a slug: the fetched catalog name, else the
   *  static roster's `appName`, else the slug itself. */
  appNameForSlug(slug: string): string {
    return this.catalogNamesBySlug.get(slug) ?? windowsCatalogAppForSlug(slug)?.appName ?? slug;
  }
}
