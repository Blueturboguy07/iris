import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { BreakAppStack } from "../src/services/maintain/break-signature";
import {
  CrashArtifactWatcher,
  defaultCrashDumpsDirectoryPath,
  defaultReportArchiveDirectoryPath,
  listDirectoryEntries,
  processNameFromCrashDumpFileName,
  readReportWerText,
  watchDirectoryForChanges,
  type CrashArtifactAppMatching,
  type DetectedCrashArtifact,
  type DirectoryWatchHandle,
} from "../src/services/maintain/crash-watcher";
import { CUE_APPCRASH_WER_FIXTURE, buildAppCrashWerText } from "./fixtures/wer-signature-fixture";

/**
 * The always-on, zero-cost layer: notices a `Report.wer` for an installed
 * catalog app and nothing else, dedupes, ignores what was already there
 * before the watch started, and treats a matching process exit or crash-dump
 * sighting as corroboration only — never as a requirement to deliver.
 */

const REPORT_ARCHIVE = "/fake/report-archive";
const CRASH_DUMPS = "/fake/crash-dumps";

/** An in-memory "directory" a test can mutate between `start()` and
 *  triggering a watch callback, standing in for a real filesystem listing. */
class FakeDirectory {
  constructor(public entries: string[] = []) {}
  list = async (): Promise<string[]> => [...this.entries];
}

/** Captures the `onChange` callback the watcher hands to `watchDirectory` for
 *  each path, so a test can fire a change deterministically instead of racing
 *  a real `fs.watch`. */
class CapturingWatcherFactory {
  private handlersByPath = new Map<string, () => void>();
  readonly closedPaths: string[] = [];

  watchDirectory = (directoryPath: string, onChange: () => void): DirectoryWatchHandle => {
    this.handlersByPath.set(directoryPath, onChange);
    return { close: () => this.closedPaths.push(directoryPath) };
  };

  trigger(directoryPath: string): void {
    this.handlersByPath.get(directoryPath)?.();
  }
}

function alwaysMatchesCue(): CrashArtifactAppMatching {
  return {
    catalogApp: (processName) =>
      processName === "cue.exe" ? { slug: "cue", stack: "electron" as BreakAppStack } : undefined,
  };
}

function neverMatches(): CrashArtifactAppMatching {
  return { catalogApp: () => undefined };
}

interface Harness {
  readonly watcher: CrashArtifactWatcher;
  readonly reportArchive: FakeDirectory;
  readonly crashDumps: FakeDirectory;
  readonly watcherFactory: CapturingWatcherFactory;
  readonly delivered: DetectedCrashArtifact[];
  readonly readReportWerTextCalls: string[];
  readonly sleepCalls: number[];
  now: number;
  setReportWerText(reportDirectoryPath: string, text: string | undefined): void;
}

function buildHarness(options: {
  appMatcher?: CrashArtifactAppMatching;
  maximumRememberedReports?: number;
  reportArchiveEntries?: string[];
  crashDumpEntries?: string[];
} = {}): Harness {
  const reportArchive = new FakeDirectory(options.reportArchiveEntries ?? []);
  const crashDumps = new FakeDirectory(options.crashDumpEntries ?? []);
  const watcherFactory = new CapturingWatcherFactory();
  const delivered: DetectedCrashArtifact[] = [];
  const readReportWerTextCalls: string[] = [];
  const sleepCalls: number[] = [];
  const werTextByPath = new Map<string, string | undefined>();
  const state = { now: 0 };

  const watcher = new CrashArtifactWatcher({
    appMatcher: options.appMatcher ?? alwaysMatchesCue(),
    reportArchiveDirectoryPath: REPORT_ARCHIVE,
    crashDumpsDirectoryPath: CRASH_DUMPS,
    maximumRememberedReports: options.maximumRememberedReports,
    listDirectoryEntries: (directoryPath) =>
      directoryPath === REPORT_ARCHIVE ? reportArchive.list() : crashDumps.list(),
    readReportWerText: async (reportDirectoryPath) => {
      readReportWerTextCalls.push(reportDirectoryPath);
      return werTextByPath.get(reportDirectoryPath);
    },
    watchDirectory: watcherFactory.watchDirectory,
    sleepMs: async (ms) => {
      sleepCalls.push(ms);
    },
    nowEpochMs: () => state.now,
  });
  watcher.onCrashArtifactDetected = (artifact) => delivered.push(artifact);

  return {
    watcher,
    reportArchive,
    crashDumps,
    watcherFactory,
    delivered,
    readReportWerTextCalls,
    sleepCalls,
    get now() {
      return state.now;
    },
    set now(value: number) {
      state.now = value;
    },
    setReportWerText: (reportDirectoryPath, text) => werTextByPath.set(reportDirectoryPath, text),
  };
}

function reportDirectoryPathFor(entryName: string): string {
  return join(REPORT_ARCHIVE, entryName);
}

describe("CrashArtifactWatcher — the sure path (ReportArchive)", () => {
  it("ignores a report directory present before start(), even once it is scanned", async () => {
    const h = buildHarness({ reportArchiveEntries: ["old-report"] });
    h.setReportWerText(reportDirectoryPathFor("old-report"), CUE_APPCRASH_WER_FIXTURE);
    await h.watcher.start();

    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered).toHaveLength(0);
  });

  it("delivers a new catalog-app crash report, unmatched to any termination or crash dump", async () => {
    const h = buildHarness();
    await h.watcher.start();

    h.reportArchive.entries.push("new-report");
    h.setReportWerText(reportDirectoryPathFor("new-report"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered).toHaveLength(1);
    expect(h.delivered[0]).toMatchObject({
      reportDirectoryPath: reportDirectoryPathFor("new-report"),
      catalogAppSlug: "cue",
      catalogAppStack: "electron",
      correlatedWithTermination: false,
      corroboratedByCrashDumpSighting: false,
    });
    expect(h.delivered[0]?.report.appName).toBe("cue.exe");
  });

  it("ignores a crash report for a process that is not an installed catalog app", async () => {
    const h = buildHarness({ appMatcher: neverMatches() });
    await h.watcher.start();

    h.reportArchive.entries.push("stray-report");
    h.setReportWerText(reportDirectoryPathFor("stray-report"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered).toHaveLength(0);
  });

  it("dedupes: a report already considered is never re-read across repeated watch triggers", async () => {
    const h = buildHarness();
    await h.watcher.start();

    h.reportArchive.entries.push("new-report");
    h.setReportWerText(reportDirectoryPathFor("new-report"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered).toHaveLength(1);
    expect(h.readReportWerTextCalls.filter((p) => p === reportDirectoryPathFor("new-report"))).toHaveLength(1);
  });

  it("retries once after a half-written Report.wer, then delivers", async () => {
    const h = buildHarness();
    await h.watcher.start();

    h.reportArchive.entries.push("flushing-report");
    // First read: nothing there yet (WER still flushing). Set the real text
    // only after the first read has already been recorded, mirroring a file
    // that finishes writing between the two attempts.
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    // Let the first (failed) read happen before the text becomes available.
    await Promise.resolve();
    h.setReportWerText(reportDirectoryPathFor("flushing-report"), CUE_APPCRASH_WER_FIXTURE);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(h.sleepCalls).toEqual([1500]);
    expect(h.delivered).toHaveLength(1);
  });

  it("gives up quietly when the retry also finds nothing, without throwing", async () => {
    const h = buildHarness();
    await h.watcher.start();

    h.reportArchive.entries.push("never-flushed-report");
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(h.sleepCalls).toEqual([1500]);
    expect(h.delivered).toHaveLength(0);
  });

  it("marks correlatedWithTermination when noteProcessExited landed within the correlation window", async () => {
    const h = buildHarness();
    h.now = 0;
    await h.watcher.start();
    h.watcher.noteProcessExited("cue.exe", 0);

    h.now = 5_000; // 5s later, inside the 20s window
    h.reportArchive.entries.push("crash-after-exit");
    h.setReportWerText(reportDirectoryPathFor("crash-after-exit"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered[0]?.correlatedWithTermination).toBe(true);
  });

  it("does NOT mark correlatedWithTermination once the exit falls outside the correlation window", async () => {
    const h = buildHarness();
    h.now = 0;
    await h.watcher.start();
    h.watcher.noteProcessExited("cue.exe", 0);

    h.now = 25_000; // past the 20s window
    h.reportArchive.entries.push("crash-long-after-exit");
    h.setReportWerText(reportDirectoryPathFor("crash-long-after-exit"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered[0]?.correlatedWithTermination).toBe(false);
  });

  it("resets the bounded dedupe set once it exceeds the configured cap, without dropping or double-delivering", async () => {
    const h = buildHarness({ maximumRememberedReports: 2 });
    await h.watcher.start();

    for (const name of ["r1", "r2", "r3"]) {
      h.reportArchive.entries.push(name);
      h.setReportWerText(reportDirectoryPathFor(name), CUE_APPCRASH_WER_FIXTURE);
      h.watcherFactory.trigger(REPORT_ARCHIVE);
      await Promise.resolve();
      await Promise.resolve();
    }
    // Give the reset's own directory-listing refresh (unawaited by design) a
    // turn to land before proving the invariant it exists to protect.
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered.map((d) => d.reportDirectoryPath)).toEqual([
      reportDirectoryPathFor("r1"),
      reportDirectoryPathFor("r2"),
      reportDirectoryPathFor("r3"),
    ]);

    // r1 is still sitting in the fake directory listing (nothing removes
    // entries from it) — a repeat trigger must not re-read or re-deliver it,
    // proving the post-reset re-primed "present at start" set still covers it.
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();
    expect(h.delivered).toHaveLength(3);
  });

  it("stop() closes both the report-archive and crash-dumps watch handles", async () => {
    const h = buildHarness();
    await h.watcher.start();
    h.watcher.stop();

    expect(h.watcherFactory.closedPaths).toContain(REPORT_ARCHIVE);
    expect(h.watcherFactory.closedPaths).toContain(CRASH_DUMPS);
  });
});

describe("CrashArtifactWatcher — CrashDumps corroboration (never a requirement)", () => {
  it("marks corroboratedByCrashDumpSighting when a matching dump appeared after start(), within the window", async () => {
    const h = buildHarness();
    h.now = 0;
    await h.watcher.start();

    h.crashDumps.entries.push("cue.exe.4821.dmp");
    h.watcherFactory.trigger(CRASH_DUMPS);
    await Promise.resolve();

    h.now = 3_000;
    h.reportArchive.entries.push("crash-with-dump");
    h.setReportWerText(reportDirectoryPathFor("crash-with-dump"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered[0]?.corroboratedByCrashDumpSighting).toBe(true);
  });

  it("ignores a dump file that was already present before start() — old news, like a pre-existing report", async () => {
    const h = buildHarness({ crashDumpEntries: ["cue.exe.111.dmp"] });
    h.now = 0;
    await h.watcher.start();

    // Re-scan without anything new actually being added — a watch can fire
    // spuriously (AV touching the directory, etc.).
    h.watcherFactory.trigger(CRASH_DUMPS);
    await Promise.resolve();

    h.now = 1_000;
    h.reportArchive.entries.push("crash-without-fresh-dump");
    h.setReportWerText(reportDirectoryPathFor("crash-without-fresh-dump"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered[0]?.corroboratedByCrashDumpSighting).toBe(false);
  });

  it("never blocks delivery on the absence of a crash dump — corroboration only", async () => {
    const h = buildHarness();
    await h.watcher.start();

    h.reportArchive.entries.push("crash-no-dump-anywhere");
    h.setReportWerText(reportDirectoryPathFor("crash-no-dump-anywhere"), CUE_APPCRASH_WER_FIXTURE);
    h.watcherFactory.trigger(REPORT_ARCHIVE);
    await Promise.resolve();
    await Promise.resolve();

    expect(h.delivered).toHaveLength(1);
  });
});

describe("processNameFromCrashDumpFileName — the LocalDumps <name>.<pid>.dmp convention", () => {
  it.each([
    ["cue.exe.4821.dmp", "cue.exe"],
    ["my.app.exe.99.dmp", "my.app.exe"],
    ["notetion.exe.1.DMP", "notetion.exe"],
  ])("parses %s -> %s", (fileName, expected) => {
    expect(processNameFromCrashDumpFileName(fileName)).toBe(expected);
  });

  it.each(["not-a-dump.txt", "cue.exe.dmp", "cue.exe.notanumber.dmp", ""])(
    "returns undefined for %s",
    (fileName) => {
      expect(processNameFromCrashDumpFileName(fileName)).toBeUndefined();
    },
  );
});

describe("real default I/O helpers — plain node:fs, not Windows-specific (see file header)", () => {
  let tempDir: string | undefined;

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
    tempDir = undefined;
  });

  it("listDirectoryEntries lists real entries and returns [] for a directory that does not exist", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-crash-watcher-"));
    writeFileSync(join(tempDir, "one"), "");
    writeFileSync(join(tempDir, "two"), "");

    expect((await listDirectoryEntries(tempDir)).sort()).toEqual(["one", "two"]);
    expect(await listDirectoryEntries(join(tempDir, "never-existed"))).toEqual([]);
  });

  it("readReportWerText reads a real Report.wer and returns undefined when it is missing", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-crash-watcher-"));
    const reportDir = join(tempDir, "AppCrash_cue.exe_1");
    mkdirSync(reportDir);
    writeFileSync(join(reportDir, "Report.wer"), buildAppCrashWerText({ applicationName: "cue.exe" }));

    expect(await readReportWerText(reportDir)).toContain("cue.exe");
    expect(await readReportWerText(join(tempDir, "no-such-report"))).toBeUndefined();
  });

  it("watchDirectoryForChanges returns a handle for a real directory and undefined for a missing one", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "iris-maintain-crash-watcher-"));
    const handle = watchDirectoryForChanges(tempDir, () => {});
    expect(handle).toBeDefined();
    handle?.close();

    expect(watchDirectoryForChanges(join(tempDir, "missing"), () => {})).toBeUndefined();
  });

  it("defaultReportArchiveDirectoryPath and defaultCrashDumpsDirectoryPath end in the expected Windows folders", () => {
    expect(defaultReportArchiveDirectoryPath()).toMatch(/Microsoft[\\/]Windows[\\/]WER[\\/]ReportArchive$/);
    expect(defaultCrashDumpsDirectoryPath()).toMatch(/CrashDumps$/);
  });
});
