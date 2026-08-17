// app.mjs
//
// Launching, killing, and feeding the *real* packaged Iris app for the headed
// GUI e2e suite, plus the two Windows-native inputs the suite needs to
// manufacture: a genuine `Report.wer` crash artifact in the exact directory the
// running app's live `CrashArtifactWatcher` is fs.watching, and a second app
// instance carrying an `iris://` deep link (which the single-instance lock
// routes into the already-running app, exactly as Windows delivers a
// custom-scheme link in production).

import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
  createWriteStream,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const isWindows = process.platform === "win32";

/** A scratch root the suite owns for this whole run. Prefers the CI runner's
 *  RUNNER_TEMP so everything lands on the same fast, disposable volume. */
export function scratchRoot() {
  const base = process.env.RUNNER_TEMP || tmpdir();
  const root = join(base, "iris-gui-e2e");
  mkdirSync(root, { recursive: true });
  return root;
}

/** Finds the packaged `iris.exe` under `out/`, ignoring any inside
 *  node_modules — the same rule the existing launch-smoke step uses. */
export function findPackagedExe(repoDir) {
  const outDir = join(repoDir, "out");
  if (!existsSync(outDir)) throw new Error(`no out/ directory at ${outDir} — was the app packaged?`);
  const exeName = isWindows ? "iris.exe" : "iris";
  const found = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (entry.name === "node_modules") continue;
        walk(full);
      } else if (entry.name === exeName) {
        found.push(full);
      }
    }
  };
  walk(outDir);
  if (found.length === 0) throw new Error(`no packaged ${exeName} found under ${outDir}`);
  // Shortest path wins — the top-level packaged binary, not a nested helper.
  found.sort((a, b) => a.length - b.length);
  return found[0];
}

let portCursor = 9333;
export function nextDebugPort() {
  return portCursor++;
}

/** A launched app handle: the process, its debug port, and its log file. */
export class LaunchedApp {
  constructor({ proc, port, userDataDir, logPath, name }) {
    this.proc = proc;
    this.port = port;
    this.userDataDir = userDataDir;
    this.logPath = logPath;
    this.name = name;
  }

  /** Kills the whole process tree — an Electron app spawns GPU/renderer
   *  children a plain `proc.kill()` would orphan. */
  kill() {
    if (!this.proc || this.proc.exitCode !== null) return;
    if (isWindows) {
      spawnSync("taskkill", ["/pid", String(this.proc.pid), "/T", "/F"], { stdio: "ignore" });
    } else {
      try {
        process.kill(-this.proc.pid, "SIGKILL");
      } catch {
        try {
          this.proc.kill("SIGKILL");
        } catch {
          // Already gone.
        }
      }
    }
  }
}

/**
 * Launches the packaged app with remote debugging on a fresh port and an
 * isolated userData dir, merging any `env` overrides on top of the current
 * environment. Returns once the process is spawned; the caller waits on the
 * CDP endpoint. Nothing here is Windows-only — it launches the `iris`/`iris.exe`
 * the CI runner just packaged.
 */
export function launchApp({ exePath, userDataDir, env = {}, extraArgs = [], name = "iris" }) {
  const port = nextDebugPort();
  mkdirSync(userDataDir, { recursive: true });
  const logPath = join(userDataDir, "app.log");
  const logStream = createWriteStream(logPath);

  const args = [
    `--remote-debugging-port=${port}`,
    `--user-data-dir=${userDataDir}`,
    // A stable host so the /json websocket URL is 127.0.0.1, which is where the
    // CDP client connects.
    "--remote-allow-origins=*",
    ...extraArgs,
  ];

  const proc = spawn(exePath, args, {
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
    detached: !isWindows,
    windowsHide: false,
  });
  proc.stdout.pipe(logStream);
  proc.stderr.pipe(logStream);

  return new LaunchedApp({ proc, port, userDataDir, logPath, name });
}

/**
 * Fires a second launch of the app with `iris://…` deep-link arguments. The
 * running instance holds the single-instance lock, so this process forwards its
 * argv through the `second-instance` event and exits — the real Windows
 * custom-scheme delivery path. Must use the SAME userData dir as the running
 * app for the lock to route it there.
 */
export function deliverDeepLink({ exePath, userDataDir, url }) {
  const proc = spawn(exePath, [`--user-data-dir=${userDataDir}`, url], {
    env: process.env,
    stdio: "ignore",
    windowsHide: true,
  });
  // It should exit almost immediately (lock not acquired). Don't wait on it.
  proc.unref?.();
  return proc;
}

// ---------------------------------------------------------------------------
// The WER crash artifact.
// ---------------------------------------------------------------------------

/**
 * The archive directory the app's crash watcher derives from `%ProgramData%`
 * (see `crash-watcher.ts`'s `defaultReportArchiveDirectoryPath`). The suite
 * points the launched app's `ProgramData` at a scratch root — a
 * production-identical mechanism, since that path is *always* env-derived — so
 * it can drop a real `Report.wer` into the exact directory the live watcher is
 * fs.watching, and prove Windows-native detection end to end without needing
 * write access to the machine-wide `C:\ProgramData` tree.
 */
export function werReportArchiveDir(programDataRoot) {
  return join(programDataRoot, "Microsoft", "Windows", "WER", "ReportArchive");
}

/** Renders a realistic AppCrash `Report.wer` (flat Key=Value + Sig[N] pairs +
 *  a trailing `[dynamic data]` block), matching the format
 *  `parseWerReportForSignature` reads and `tests/fixtures/wer-signature-fixture.ts`
 *  produces. CRLF line endings, exactly as Windows writes them. */
export function buildAppCrashWerText(fields = {}) {
  const lines = ["Version=1", "EventType=APPCRASH", "ReportType=2", "Consent=1"];
  if (fields.reportIdentifier) lines.push(`ReportIdentifier=${fields.reportIdentifier}`);
  if (fields.appPath) lines.push(`AppPath=${fields.appPath}`);

  let sigIndex = 0;
  const pushSig = (name, value) => {
    if (value === undefined) return;
    lines.push(`Sig[${sigIndex}].Name=${name}`);
    lines.push(`Sig[${sigIndex}].Value=${value}`);
    sigIndex += 1;
  };
  pushSig("Application Name", fields.applicationName);
  pushSig("Application Version", fields.applicationVersion);
  pushSig("Fault Module Name", fields.faultModuleName);
  pushSig("Fault Module Version", fields.faultModuleVersion);
  pushSig("Exception Code", fields.exceptionCode);
  pushSig("Exception Offset", fields.exceptionOffset);

  lines.push("", "[dynamic data]", "Sig[99].Name=Should Never Be Read", "Sig[99].Value=Should Never Be Read");
  return lines.join("\r\n");
}

/**
 * Writes a crash-report subdirectory + `Report.wer` into `archiveDir`, the way
 * Windows Error Reporting does: a new `<ReportName>` subdir containing the
 * report file. The live watcher's fs.watch on `archiveDir` fires on the subdir
 * appearing; its single-retry read covers the microsecond gap before the file
 * is flushed. Returns the report directory path.
 */
export function writeCrashArtifact(archiveDir, { reportName, fields }) {
  const reportDir = join(archiveDir, reportName);
  mkdirSync(reportDir, { recursive: true });
  writeFileSync(join(reportDir, "Report.wer"), buildAppCrashWerText(fields));
  return reportDir;
}

/** A publikclip crash artifact — the one catalog app `WINDOWS_CATALOG_APPS`
 *  recognizes by its installed exe name. */
export function publikclipCrashFields(offset = "000000000004a1b0") {
  return {
    applicationName: "publikclip-app.exe",
    applicationVersion: "0.1.0.0",
    faultModuleName: "publikclip-app.exe",
    faultModuleVersion: "0.1.0.0",
    exceptionCode: "c0000005",
    exceptionOffset: offset,
    reportIdentifier: `abcdef01-2345-6789-abcd-${Math.floor(Math.random() * 1e12).toString().padStart(12, "0")}`,
    appPath: "C:\\Users\\runneradmin\\AppData\\Local\\publikclip\\publikclip-app.exe",
  };
}

export function rmrf(path) {
  try {
    rmSync(path, { recursive: true, force: true });
  } catch {
    // Best effort.
  }
}

export function pathExists(path) {
  return existsSync(path);
}

export function isNonEmptyDir(path) {
  try {
    return statSync(path).isDirectory() && readdirSync(path).length > 0;
  } catch {
    return false;
  }
}

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
