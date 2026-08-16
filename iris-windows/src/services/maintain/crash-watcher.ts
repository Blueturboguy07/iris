/**
 * crash-watcher.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/CrashArtifactWatcher.swift` —
 * the always-on, zero-cost layer of maintain mode. Nothing here polls,
 * screenshots, or spends a token; Windows Error Reporting does the work of
 * writing a crash report, and this file only notices when one shows up for an
 * installed catalog app.
 *
 * ## Two directories, two different jobs (porting spec §2.1)
 *
 * `%ProgramData%\Microsoft\Windows\WER\ReportArchive` is the PRIMARY signal —
 * the direct Windows analog of Swift's kqueue watch on
 * `~/Library/Logs/DiagnosticReports`. A new subdirectory appearing there means
 * WER finished writing a `Report.wer`; this file reads it with
 * `break-signature.ts`'s already-built `parseWerReportForSignature` and, if the
 * crashed process matches an installed catalog app, delivers a
 * `DetectedCrashArtifact`.
 *
 * `%LOCALAPPDATA%\CrashDumps` (minidumps, written only if the target opted
 * into the `LocalDumps` registry key — most catalog apps will not have this
 * set) is CORROBORATION ONLY, never a required signal, exactly like Swift's
 * `correlatedWithTermination`. Its presence within the correlation window is
 * surfaced as `corroboratedByCrashDumpSighting` — a bonus timing fact for
 * whoever reviews a pooled crash, never something this file requires before
 * delivering an artifact.
 *
 * This file does NOT build the "fast path" (an `EventLogWatcher` on Event ID
 * 1000/1002, the analog of Swift's private `com.apple.ReportCrash.crash`
 * distributed notification) — that lives in a separate module
 * (`main/maintain/wer-crash-watcher.ts` + `wer-report.ts`, per the porting
 * spec's module table) because it needs inline C# (`Add-Type`) and Electron
 * process wiring this file deliberately stays free of. The ReportArchive
 * watch below is the "sure path" on its own: slower than an event-log
 * subscription, but public, stable, and sufficient by itself if the fast path
 * is ever added later — same relationship Swift's kqueue watch has to its own
 * notification path.
 *
 * ## Correlation with process exit — a deliberate divergence from Swift
 *
 * Swift listens to `NSWorkspace.didTerminateApplicationNotification`, a
 * system-wide "an app just quit" event it can simply subscribe to. Windows has
 * no equivalent global termination notification without WMI/ETW — heavier
 * machinery than a watcher this small should carry. Instead, `noteProcessExited`
 * is an explicit method: whoever spawns or tracks a catalog app's process
 * (autopilot's `PowerShellSession`, a future direct-launch path) calls it when
 * that process exits, and this file does the correlation-window bookkeeping
 * Swift does internally. The math (`correlatedWithTermination`) is unchanged;
 * only how the timing fact arrives is different, and that difference is
 * exactly the porting spec's "BEHAVIOR parity, not literal translation" rule.
 *
 * ## Pure decision logic vs. fs calls (ground rule: testable on any OS)
 *
 * Every piece of real I/O — listing a directory, reading a `Report.wer`,
 * watching a directory for changes, sleeping between a read retry — is an
 * injected function on `CrashArtifactWatcherOptions`, defaulting to a real
 * `node:fs` implementation exported from this same file. `node:fs` is not
 * in itself a Windows-only API (see `install-provenance.ts`'s
 * `gitDirectoryExists` and `patch-queue.ts`'s `FileSystemPatchQueueStorage`
 * for the same convention already established in this package) — the
 * Windows-specific parts are only the *paths* (`%ProgramData%\...`,
 * `%LOCALAPPDATA%\...`) and the shape of what gets parsed, both of which are
 * plain data, not platform-gated code. That means the whole class, including
 * its real default I/O, is exercised for real by the vitest suite (against a
 * temp directory) on the Mac dev machine and on windows-latest CI alike — the
 * fs-watch based "watch" itself is still worth injecting so a test can drive
 * change notifications deterministically instead of racing a real
 * `fs.watch` debounce window.
 *
 * ## App matching is caller-supplied, on purpose (porting spec §2.1, §5.4)
 *
 * There is no Windows analog of `AppInventoryService` in this repo yet, and
 * `app/api/iris/apps/route.ts` carries no Windows-exe field — only
 * `macBundleId`. Rather than hand-roll a slug→exe-name table inside this file
 * (which would silently go stale the moment the catalog changes, and would be
 * exactly the kind of gap the ground rules say to flag, not paper over),
 * `CrashArtifactAppMatching` is injected, mirroring Swift's own
 * `CrashArtifactAppMatching` protocol being backed by `AppInventoryService`
 * rather than hardcoded into `CrashArtifactWatcher`. Whoever wires the real
 * controller supplies the real table; this file only knows how to ask it.
 */

import { watch as fsWatch } from "node:fs";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";
import type { BreakAppStack, ParsedWindowsCrash } from "./break-signature";
import { parseWerReportForSignature } from "./break-signature";
import { maintainTrace } from "./trace";

/** One crash artifact, parsed and matched to a catalog app — the Windows
 *  analog of Swift's `DetectedCrashArtifact`. */
export interface DetectedCrashArtifact {
  /** The `<ReportArchive>\<ReportName>` directory this report was read from —
   *  the dedupe key, and the Windows analog of Swift's `fileURL`. */
  readonly reportDirectoryPath: string;
  readonly report: ParsedWindowsCrash;
  /** Set because the crashed process matched an installed catalog app —
   *  everything else on the machine crashes sometimes, but only ours is
   *  maintain mode's business (see `deliverIfCatalogApp` below). */
  readonly catalogAppSlug: string;
  readonly catalogAppStack: BreakAppStack;
  /** True when `noteProcessExited` recorded a matching process name's exit
   *  within the correlation window. Timing evidence only, never a diagnosis —
   *  exactly like Swift's field of the same name. */
  readonly correlatedWithTermination: boolean;
  /** True when a `%LOCALAPPDATA%\CrashDumps` minidump for a matching process
   *  name appeared within the correlation window. A second, Windows-only
   *  corroboration source with no Swift equivalent (macOS has no analogous
   *  opt-in dump directory) — kept as its own field rather than folded into
   *  `correlatedWithTermination` so a reviewer can tell which kind of timing
   *  evidence, if any, backs a pooled crash. */
  readonly corroboratedByCrashDumpSighting: boolean;
}

/** How the watcher decides whether a crash report belongs to one of ours.
 *  The real answer is caller-supplied — see the file header's "App matching
 *  is caller-supplied" section for why this file never hardcodes a table. */
export interface CrashArtifactAppMatching {
  /** Returns the slug/stack when `processName` (a `.wer` report's
   *  `Application Name`, e.g. `"cue.exe"`) names an installed catalog app;
   *  `undefined` for everything else on the machine. */
  catalogApp(processName: string): { readonly slug: string; readonly stack: BreakAppStack } | undefined;
}

/** A handle on an active directory watch, returned by the injected
 *  `watchDirectory` seam. Mirrors the shape `child_process.spawn` and
 *  `fs.watch` both already return a "stop this" handle for. */
export interface DirectoryWatchHandle {
  close(): void;
}

// ---------------------------------------------------------------------------
// Real default I/O — plain `node:fs`, not Windows-specific code (see the file
// header). Exported individually so a test can exercise each in isolation
// against a temp directory, the same pattern `install-provenance.ts` uses for
// `gitDirectoryExists`.
// ---------------------------------------------------------------------------

/** `%ProgramData%\Microsoft\Windows\WER\ReportArchive` — falls back to the
 *  well-known default location if the environment variable is unset (never
 *  true on a real Windows machine, but keeps this callable on the Mac dev
 *  machine without throwing). */
export function defaultReportArchiveDirectoryPath(): string {
  const programData = process.env.ProgramData ?? "C:\\ProgramData";
  return join(programData, "Microsoft", "Windows", "WER", "ReportArchive");
}

/** `%LOCALAPPDATA%\CrashDumps` — corroboration-only source; see the file
 *  header. Most catalog apps will not have written anything here, since it
 *  requires the target to have opted into the `LocalDumps` registry key. */
export function defaultCrashDumpsDirectoryPath(): string {
  const localAppData = process.env.LOCALAPPDATA ?? "C:\\Users\\Default\\AppData\\Local";
  return join(localAppData, "CrashDumps");
}

/** Lists the entries directly under `directoryPath`. A missing directory
 *  (CrashDumps almost always is; ReportArchive may not exist on a machine
 *  that has never crashed) is not an error worth surfacing — it just has no
 *  entries yet. */
export async function listDirectoryEntries(directoryPath: string): Promise<string[]> {
  try {
    return await readdir(directoryPath);
  } catch {
    return [];
  }
}

/** Reads `<reportDirectoryPath>\Report.wer` as text, or `undefined` if it is
 *  not there yet (WER may still be flushing it — see `considerReport`'s retry)
 *  or cannot be read. */
export async function readReportWerText(reportDirectoryPath: string): Promise<string | undefined> {
  try {
    return await readFile(join(reportDirectoryPath, "Report.wer"), "utf8");
  } catch {
    return undefined;
  }
}

/** Watches `directoryPath` for any change and calls `onChange` — debounced by
 *  nothing, deliberately: `scanForNewReports`/`scanForNewCrashDumps` are cheap
 *  and idempotent (dedupe means an extra scan costs nothing), so there is
 *  nothing to gain from coalescing events at this layer the way there would be
 *  for something expensive. Returns `undefined`, not a handle, when the
 *  directory does not exist — `fs.watch` throws synchronously in that case,
 *  and a directory that may never be created (CrashDumps, on a machine that
 *  never opted into `LocalDumps`) is an expected shape, not a startup failure. */
export function watchDirectoryForChanges(directoryPath: string, onChange: () => void): DirectoryWatchHandle | undefined {
  try {
    const watcher = fsWatch(directoryPath, { persistent: false }, () => onChange());
    watcher.on("error", () => {
      // A watch that errors mid-flight (the directory was removed, a AV
      // product briefly locked it) is not fatal — the sure path just goes
      // quiet for this directory until the next `start()`. Traced so it is
      // diagnosable rather than silently invisible.
      maintainTrace(`crash-watcher: directory watch for ${directoryPath} errored and stopped`);
    });
    return { close: () => watcher.close() };
  } catch {
    return undefined;
  }
}

/** Windows' `LocalDumps` convention names a minidump
 *  `<processName>.<pid>.dmp` (e.g. `cue.exe.4821.dmp`). Pulls the process name
 *  back out, or `undefined` for anything that doesn't match the shape — a
 *  pure, directly testable piece of an otherwise I/O-heavy file. */
export function processNameFromCrashDumpFileName(fileName: string): string | undefined {
  const match = /^(.+)\.\d+\.dmp$/i.exec(fileName);
  return match?.[1];
}

// ---------------------------------------------------------------------------
// The watcher itself.
// ---------------------------------------------------------------------------

export interface CrashArtifactWatcherOptions {
  readonly appMatcher: CrashArtifactAppMatching;
  readonly reportArchiveDirectoryPath?: string;
  readonly crashDumpsDirectoryPath?: string;
  /** Defaults to `listDirectoryEntries`. */
  readonly listDirectoryEntries?: (directoryPath: string) => Promise<string[]>;
  /** Defaults to `readReportWerText`. */
  readonly readReportWerText?: (reportDirectoryPath: string) => Promise<string | undefined>;
  /** Defaults to `watchDirectoryForChanges`. Injected so a test can drive
   *  change notifications by calling the captured `onChange` directly,
   *  instead of racing a real `fs.watch` debounce window. */
  readonly watchDirectory?: (directoryPath: string, onChange: () => void) => DirectoryWatchHandle | undefined;
  /** Defaults to a real `setTimeout`-based sleep. Injected so the
   *  half-written-file retry (see `considerReport`) resolves instantly under
   *  test instead of actually waiting 1.5s. */
  readonly sleepMs?: (ms: number) => Promise<void>;
  /** Defaults to `Date.now`. Injected so the correlation-window math is
   *  testable without a real clock. */
  readonly nowEpochMs?: () => number;
  /** Defaults to 512, matching Swift's `maximumRememberedPaths`. Overridable
   *  so a test can exercise the bounded-memory reset without delivering 512
   *  reports. */
  readonly maximumRememberedReports?: number;
}

/** ReportCrash may still be flushing when the directory first appears; a
 *  half-written `Report.wer` reads as garbage or is not there yet. One short
 *  retry covers it — the direct port of Swift's `considerReport`'s
 *  `asyncAfter(deadline: .now() + 1.5)` retry. */
const RETRY_DELAY_MS = 1500;

/** How long a termination or a crash-dump sighting stays "recent" enough to
 *  corroborate a crash report. Matches Swift's
 *  `terminationCorrelationWindow: TimeInterval = 20`. */
const TERMINATION_CORRELATION_WINDOW_MS = 20 * 1000;

const DEFAULT_MAXIMUM_REMEMBERED_REPORTS = 512;

/**
 * Watches for Windows crash artifacts belonging to installed catalog apps.
 * See the file header for the full design; this class owns only the
 * bookkeeping (dedupe, ignore-pre-existing, correlation) — every real I/O
 * call is the injected seam above.
 */
export class CrashArtifactWatcher {
  /** New artifacts land here. The incident coordinator owns what happens
   *  next (ask the user, never act on its own) — this callback only
   *  delivers, exactly like Swift's `onCrashArtifactDetected`. */
  onCrashArtifactDetected: ((artifact: DetectedCrashArtifact) => void) | undefined;

  private readonly appMatcher: CrashArtifactAppMatching;
  private readonly reportArchiveDirectoryPath: string;
  private readonly crashDumpsDirectoryPath: string;
  private readonly listDirectoryEntriesImpl: (directoryPath: string) => Promise<string[]>;
  private readonly readReportWerTextImpl: (reportDirectoryPath: string) => Promise<string | undefined>;
  private readonly watchDirectoryImpl: (directoryPath: string, onChange: () => void) => DirectoryWatchHandle | undefined;
  private readonly sleepMsImpl: (ms: number) => Promise<void>;
  private readonly nowEpochMsImpl: () => number;
  private readonly maximumRememberedReports: number;

  /** Report directory names delivered already, so the periodic scan cannot
   *  double-report one crash. Bounded — see `rememberDelivered`. */
  private deliveredReportDirectoryNames = new Set<string>();
  /** Report directory names present before `start()` — old news, per the
   *  file header. */
  private reportDirectoriesPresentAtStart = new Set<string>();
  /** Crash-dump file names present before `start()` — same reasoning, kept
   *  separate because it is a distinct directory with its own listing. */
  private crashDumpFilesPresentAtStart = new Set<string>();
  private crashDumpFilesAlreadySighted = new Set<string>();

  private recentTerminationsByProcessName = new Map<string, number>();
  private recentCrashDumpSightingsByProcessName = new Map<string, number>();

  private reportArchiveWatchHandle: DirectoryWatchHandle | undefined;
  private crashDumpsWatchHandle: DirectoryWatchHandle | undefined;

  constructor(options: CrashArtifactWatcherOptions) {
    this.appMatcher = options.appMatcher;
    this.reportArchiveDirectoryPath = options.reportArchiveDirectoryPath ?? defaultReportArchiveDirectoryPath();
    this.crashDumpsDirectoryPath = options.crashDumpsDirectoryPath ?? defaultCrashDumpsDirectoryPath();
    this.listDirectoryEntriesImpl = options.listDirectoryEntries ?? listDirectoryEntries;
    this.readReportWerTextImpl = options.readReportWerText ?? readReportWerText;
    this.watchDirectoryImpl = options.watchDirectory ?? watchDirectoryForChanges;
    this.sleepMsImpl = options.sleepMs ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.nowEpochMsImpl = options.nowEpochMs ?? (() => Date.now());
    this.maximumRememberedReports = options.maximumRememberedReports ?? DEFAULT_MAXIMUM_REMEMBERED_REPORTS;
  }

  /** Snapshots what already exists in both directories (old news), then hooks
   *  a watch on each. Mirrors Swift's `start()` ordering exactly: list first,
   *  watch second. */
  async start(): Promise<void> {
    this.reportDirectoriesPresentAtStart = new Set(await this.listDirectoryEntriesImpl(this.reportArchiveDirectoryPath));
    this.crashDumpFilesPresentAtStart = new Set(await this.listDirectoryEntriesImpl(this.crashDumpsDirectoryPath));

    this.reportArchiveWatchHandle = this.watchDirectoryImpl(this.reportArchiveDirectoryPath, () => {
      void this.scanForNewReports();
    });
    this.crashDumpsWatchHandle = this.watchDirectoryImpl(this.crashDumpsDirectoryPath, () => {
      void this.scanForNewCrashDumps();
    });
  }

  stop(): void {
    this.reportArchiveWatchHandle?.close();
    this.reportArchiveWatchHandle = undefined;
    this.crashDumpsWatchHandle?.close();
    this.crashDumpsWatchHandle = undefined;
  }

  /** Called by whoever spawned or is tracking a catalog app's process, the
   *  moment it exits — see the file header's "Correlation with process exit"
   *  section for why this is a method here rather than a subscription. */
  noteProcessExited(processName: string, exitedAtEpochMs: number = this.nowEpochMsImpl()): void {
    this.recentTerminationsByProcessName.set(processName, exitedAtEpochMs);
    this.pruneOldEntries(this.recentTerminationsByProcessName);
  }

  // -- Report-archive scan (the primary signal) ----------------------------

  private async scanForNewReports(): Promise<void> {
    const entries = await this.listDirectoryEntriesImpl(this.reportArchiveDirectoryPath);
    for (const entryName of entries) {
      if (this.reportDirectoriesPresentAtStart.has(entryName) || this.deliveredReportDirectoryNames.has(entryName)) {
        continue;
      }
      await this.considerReport(entryName);
    }
  }

  private async considerReport(entryName: string): Promise<void> {
    if (this.deliveredReportDirectoryNames.has(entryName) || this.reportDirectoriesPresentAtStart.has(entryName)) {
      return;
    }
    // Marked delivered before the read/parse even resolves — same as Swift's
    // `rememberDelivered` call ordering — so a second scan racing this one
    // (the watch can fire again before this finishes) cannot double-consider
    // the same entry.
    this.rememberDelivered(entryName);

    const reportDirectoryPath = join(this.reportArchiveDirectoryPath, entryName);
    let text = await this.readReportWerTextImpl(reportDirectoryPath);
    if (text === undefined || text.length === 0) {
      // WER may still be writing it. One short wait, one retry, then give up
      // quietly — matching Swift's single-retry shape exactly.
      await this.sleepMsImpl(RETRY_DELAY_MS);
      text = await this.readReportWerTextImpl(reportDirectoryPath);
      if (text === undefined || text.length === 0) {
        maintainTrace(`crash-watcher: gave up reading ${entryName}'s Report.wer after one retry`);
        return;
      }
    }

    const parsed = parseWerReportForSignature(text);
    this.deliverIfCatalogApp(parsed, reportDirectoryPath);
  }

  private deliverIfCatalogApp(report: ParsedWindowsCrash, reportDirectoryPath: string): void {
    const match = this.appMatcher.catalogApp(report.appName);
    if (match === undefined) {
      // Traced, not stored: everything on this machine crashes sometimes;
      // only our apps are maintain mode's business, and the report itself
      // stays unread past what `parseWerReportForSignature` already pulled
      // out of it. Matches Swift's `deliverIfCatalogApp` reasoning verbatim.
      maintainTrace(`crash-watcher: crash artifact ignored (${report.appName} is not an installed catalog app)`);
      return;
    }

    const now = this.nowEpochMsImpl();
    const correlatedWithTermination = this.isRecentEnough(this.recentTerminationsByProcessName.get(report.appName), now);
    const corroboratedByCrashDumpSighting = this.isRecentEnough(
      this.recentCrashDumpSightingsByProcessName.get(report.appName),
      now,
    );

    maintainTrace(
      `crash-watcher: crash artifact for ${match.slug} correlatedWithTermination=${correlatedWithTermination} ` +
        `corroboratedByCrashDumpSighting=${corroboratedByCrashDumpSighting}`,
    );
    this.onCrashArtifactDetected?.({
      reportDirectoryPath,
      report,
      catalogAppSlug: match.slug,
      catalogAppStack: match.stack,
      correlatedWithTermination,
      corroboratedByCrashDumpSighting,
    });
  }

  private rememberDelivered(entryName: string): void {
    this.deliveredReportDirectoryNames.add(entryName);
    if (this.deliveredReportDirectoryNames.size > this.maximumRememberedReports) {
      // Matches Swift's bounded-memory reset: a session that sees this many
      // crashes has bigger problems than this set's memory, so it is simply
      // cleared and re-primed from a fresh listing rather than grown
      // unbounded.
      this.deliveredReportDirectoryNames.clear();
      void this.listDirectoryEntriesImpl(this.reportArchiveDirectoryPath).then((entries) => {
        this.reportDirectoriesPresentAtStart = new Set(entries);
      });
    }
  }

  // -- CrashDumps scan (corroboration only) --------------------------------

  private async scanForNewCrashDumps(): Promise<void> {
    const entries = await this.listDirectoryEntriesImpl(this.crashDumpsDirectoryPath);
    for (const fileName of entries) {
      if (this.crashDumpFilesPresentAtStart.has(fileName) || this.crashDumpFilesAlreadySighted.has(fileName)) {
        continue;
      }
      this.crashDumpFilesAlreadySighted.add(fileName);
      const processName = processNameFromCrashDumpFileName(fileName);
      if (processName === undefined) {
        continue;
      }
      this.recentCrashDumpSightingsByProcessName.set(processName, this.nowEpochMsImpl());
      this.pruneOldEntries(this.recentCrashDumpSightingsByProcessName);
    }
  }

  // -- Shared correlation-window helpers ------------------------------------

  private isRecentEnough(recordedAtEpochMs: number | undefined, now: number): boolean {
    if (recordedAtEpochMs === undefined) {
      return false;
    }
    return now - recordedAtEpochMs < TERMINATION_CORRELATION_WINDOW_MS;
  }

  /** Matches Swift's `pruneOldTerminations`, generalized to both correlation
   *  maps: entries older than twice the correlation window are dropped so
   *  neither map grows for the lifetime of a long-running session. */
  private pruneOldEntries(entries: Map<string, number>): void {
    const cutoff = this.nowEpochMsImpl() - TERMINATION_CORRELATION_WINDOW_MS * 2;
    for (const [key, recordedAtEpochMs] of entries) {
      if (recordedAtEpochMs <= cutoff) {
        entries.delete(key);
      }
    }
  }
}
