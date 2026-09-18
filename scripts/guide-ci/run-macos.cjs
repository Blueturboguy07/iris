#!/usr/bin/env node
// Runs one guide branch the way Iris for macOS runs it — headlessly.
//
// What this mirrors from iris-macos (GuideAutopilotShellSession / Runner):
//   • one persistent login+interactive zsh, commands typed as top-level input,
//     exit status read back through an in-band sentinel
//   • `cd <workingDirectory>` before a step that declares one, refused for
//     system folders and for anything that is not a plain ~/ or / path
//   • a `watch.sensitive` step is never typed — it is handed back
//   • a command that holds the shell open (dev server) runs in a side session;
//     the next `open` step's localhost URL is then probed over HTTP
//   • the risk gate: the catastrophe floor refuses even under the grant; the
//     no-grant tier of every command is recorded for the report
//   • Iris's 900 s per-command deadline is recorded as `exceededIrisDeadline`
//     (the harness itself waits up to --max-step-minutes so the real outcome of
//     a slow build is still learned)
//
// What it does NOT test: the eye, pointing, the watch loop's visual rung, the
// model fix ladder, and every `open`/`permission`/`web`/`paste`/`verify` step,
// which are recorded as reader steps (their links are checked for liveness).
//
//   node run-macos.cjs --slug cue [--target desktop|ios|android] [--out DIR]
//                      [--base https://publikhq.com] [--home DIR]
//                      [--max-step-minutes 60] [--grace-seconds 90]

"use strict";

const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const lib = require("./lib.cjs");

const IRIS_COMMAND_DEADLINE_MS = 900_000; // GuideAutopilotShellSession.defaultCommandDeadline
const FOLDER_MOVE_DEADLINE_MS = 30_000; // GuideAutopilotRunner.folderMoveDeadline
const SENTINEL_PREFIX = "__IRIS_END_";

class ZshSession {
  constructor({ env, home, label }) {
    this.env = env;
    this.home = home;
    this.label = label;
    this.child = undefined;
    this.output = "";
    this.exited = false;
    this.exitCode = undefined;
    this.waiters = [];
  }

  async start() {
    this.output = "";
    this.exited = false;
    this.exitCode = undefined;
    this.child = spawn("/bin/zsh", ["-l", "-i"], {
      env: this.env,
      cwd: this.home,
      stdio: ["pipe", "pipe", "pipe"],
      detached: true,
    });
    const onData = (chunk) => {
      this.output += chunk.toString("utf8");
      for (const w of this.waiters) w();
    };
    this.child.stdout.on("data", onData);
    this.child.stderr.on("data", onData);
    this.child.on("exit", (code) => {
      this.exited = true;
      this.exitCode = code;
      for (const w of this.waiters) w();
    });
    this.child.on("error", () => {
      this.exited = true;
      for (const w of this.waiters) w();
    });
    // Same tidy-up the app's preamble does, plus stderr merged in order.
    const preamble =
      "unsetopt zle 2>/dev/null; setopt ignoreeof 2>/dev/null; unsetopt prompt_cr prompt_sp 2>/dev/null\n" +
      "PS1='' PS2='' PROMPT='' RPROMPT=''\n" +
      "exec 2>&1\n" +
      "export PAGER=cat GIT_PAGER=cat LESS=-FRX GIT_TERMINAL_PROMPT=0\n" +
      `cd ${shellQuote(this.home)}\n`;
    this.child.stdin.write(preamble);
    const ready = await this.run("true", 60_000);
    return !ready.shellDied && !ready.timedOut;
  }

  /// Types `command` and waits for its sentinel. Resolves with the exit status,
  /// the resulting working directory, and everything printed in between.
  run(command, deadlineMs) {
    const token = crypto.randomBytes(6).toString("hex");
    const marker = `${SENTINEL_PREFIX}${token}__`;
    const pattern = new RegExp(`${marker} (\\d+)\\t([^\\n]*)`);
    const startedAt = Date.now();
    const startOffset = this.output.length;
    this.child.stdin.write(`${command}\nprintf '\\n${marker} %d\\t%s\\n' "$?" "$PWD"\n`);
    return new Promise((resolve) => {
      let done = false;
      const finish = (extra) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        this.waiters = this.waiters.filter((w) => w !== check);
        const raw = this.output.slice(startOffset);
        const m = raw.match(pattern);
        const output = (m ? raw.slice(0, m.index) : raw).replace(/\n$/, "");
        resolve({
          exitCode: m ? Number.parseInt(m[1], 10) : undefined,
          cwd: m ? m[2] : undefined,
          output,
          durationMs: Date.now() - startedAt,
          ...extra,
        });
      };
      const check = () => {
        if (pattern.test(this.output.slice(startOffset))) finish({});
        else if (this.exited) finish({ shellDied: true, shellExitCode: this.exitCode });
      };
      const timer = setTimeout(() => {
        this.killGroup();
        finish({ timedOut: true });
      }, deadlineMs);
      this.waiters.push(check);
      check();
    });
  }

  /// Types a command that is expected to keep running (a dev server) and does
  /// not wait for it. The sentinel is still sent so an early exit is visible.
  startLongRunning(command) {
    const token = crypto.randomBytes(6).toString("hex");
    const marker = `${SENTINEL_PREFIX}${token}__`;
    const startOffset = this.output.length;
    this.child.stdin.write(`${command}\nprintf '\\n${marker} %d\\t%s\\n' "$?" "$PWD"\n`);
    const pattern = new RegExp(`${marker} (\\d+)\\t([^\\n]*)`);
    return {
      outputSoFar: () => this.output.slice(startOffset).replace(new RegExp(`\\n?${marker}[^\\n]*`), ""),
      exitedWith: () => {
        const m = this.output.slice(startOffset).match(pattern);
        if (m) return Number.parseInt(m[1], 10);
        if (this.exited) return this.exitCode ?? -1;
        return undefined;
      },
    };
  }

  killGroup() {
    if (!this.child || this.exited) return;
    try {
      process.kill(-this.child.pid, "SIGKILL");
    } catch {
      try {
        this.child.kill("SIGKILL");
      } catch {
        /* gone */
      }
    }
  }
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, "'\\''")}'`;
}

function childEnvironment(home) {
  // Built from scratch like GuideAutopilotShellSession.childEnvironment(), with
  // the runner's PATH passed through the way a reader's own rc files would
  // build it, and the CI markers removed so tools behave as on a real Mac.
  const env = {
    HOME: home,
    USER: process.env.USER ?? "runner",
    LOGNAME: process.env.USER ?? "runner",
    SHELL: "/bin/zsh",
    TMPDIR: process.env.TMPDIR ?? "/tmp",
    TERM: "xterm-256color",
    LANG: "en_US.UTF-8",
    IRIS_AUTOPILOT: "1",
    PATH: process.env.PATH ?? "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
  };
  // A few things a reader's Terminal would also carry.
  for (const key of ["XDG_CONFIG_HOME", "SSH_AUTH_SOCK", "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "GUIDE_CI_ANTHROPIC_API_KEY"]) {
    if (process.env[key]) env[key] = process.env[key];
  }
  return env;
}

async function main() {
  const args = lib.parseArgs(process.argv.slice(2));
  const slug = args.slug;
  if (!slug) throw new Error("--slug is required");
  const target = args.target && args.target !== "desktop" ? args.target : null;
  const base = args.base ?? lib.DEFAULT_BASE;
  const outDir = path.resolve(args.out ?? "guide-ci-results");
  const home = args.home ? path.resolve(args.home) : process.env.HOME;
  const maxStepMs = Number.parseFloat(args["max-step-minutes"] ?? "60") * 60_000;
  const graceMs = Number.parseFloat(args["grace-seconds"] ?? "90") * 1_000;
  if (args.home) fs.mkdirSync(home, { recursive: true });

  const result = {
    harness: "run-macos",
    slug,
    platform: "macos",
    target,
    base,
    startedAt: lib.nowIso(),
    steps: [],
    notes: [],
  };
  const logDir = path.join(outDir, "logs", `${slug}--macos--${target ?? "desktop"}`);
  fs.mkdirSync(logDir, { recursive: true });

  const guide = await lib.fetchGuide(base, slug);
  result.guideVersion = guide.version;
  result.guideStatus = guide.status;
  result.appName = guide.appName;
  result.source = `${guide.sourceOwner}/${guide.sourceRepo}@${(guide.sourceCommit ?? "").slice(0, 7)}`;

  const branch = lib.findBranch(guide, "macos", target);
  if (!branch) {
    result.verdict = "no-branch";
    result.notes.push(`guide has no macos:${target ?? "desktop"} branch (has ${guide.branches.map(lib.branchKey).join(", ")})`);
    finish(result, outDir);
    return;
  }
  if (branch.unsupported) {
    result.verdict = "unsupported";
    result.unsupported = branch.unsupported;
    finish(result, outDir);
    return;
  }

  const env = childEnvironment(home);
  result.environment = await lib.recordEnvironment({ shell: "/bin/zsh", env });

  // ── Static pass over every step (setup + main) ────────────────────────────
  const steps = [];
  const setupIds = new Set((branch.setupSteps ?? []).map((s) => s.id));
  for (const step of lib.allSteps(branch)) {
    const entry = {
      id: step.id,
      kind: step.kind,
      title: step.title,
      isSetupStep: setupIds.has(step.id),
      workingDirectory: step.workingDirectory ?? null,
      command: step.command ?? null,
      sensitive: step.watch?.sensitive === true,
      expects: (step.watch?.expect ?? []).map((e) => e.type + (e.tool ? `:${e.tool}` : e.host ? `:${e.host}` : "")),
    };
    if (step.command) {
      entry.riskWithoutGrant = lib.assessMacCommand(step.command, false);
      entry.riskWithGrant = lib.assessMacCommand(step.command, true);
      entry.syntacticallyIncomplete = lib.looksSyntacticallyIncomplete(step.command);
      entry.holdsTheShellOpen = lib.holdsTheShellOpen(step.command);
    }
    if (step.href) {
      entry.href = lib.isLocalHref(step.href) ? { href: step.href, ok: true, status: "local (probed after the dev server starts)" } : await lib.checkHref(step.href);
    }
    steps.push(entry);
  }
  result.steps = steps;

  // ── Execution ─────────────────────────────────────────────────────────────
  const main = new ZshSession({ env, home, label: "main" });
  if (!(await main.start())) {
    result.verdict = "error";
    result.notes.push("the main zsh session never became ready");
    finish(result, outDir);
    return;
  }
  let side; // the long-running session, started on demand
  let firstFailureSeen = false;
  let stepNumber = 0;
  const mainSteps = branch.steps ?? [];

  const killEverything = () => {
    main.killGroup();
    side?.killGroup();
  };
  process.on("exit", killEverything);
  process.on("SIGINT", () => {
    killEverything();
    process.exit(130);
  });

  for (const step of mainSteps) {
    const entry = steps.find((s) => s.id === step.id && !s.isSetupStep) ?? steps.find((s) => s.id === step.id);
    stepNumber += 1;
    entry.order = stepNumber;
    entry.afterFirstFailure = firstFailureSeen;
    const logFile = path.join(logDir, `${String(stepNumber).padStart(2, "0")}-${step.id}.log`);
    console.log(`[guide-ci ${lib.nowIso().slice(11, 19)}] step ${stepNumber}/${mainSteps.length} (${step.kind}) ${step.title}${step.workingDirectory ? `  @ ${step.workingDirectory}` : ""}`);

    if (step.kind !== "terminal" && step.kind !== "check") {
      entry.disposition = step.kind === "open" ? "open" : "reader";
      entry.ran = false;
      // The `open` step right after a dev server started: probe what it opens.
      if (step.kind === "open" && step.href && lib.isLocalHref(step.href)) {
        entry.served = await lib.probeServed(step.href);
        entry.href = { href: step.href, ok: entry.served.reachable, status: entry.served.status };
        if (!entry.served.reachable) {
          entry.ran = true; // counts against the verdict: the app is not there
          entry.failed = true;
          entry.failureReason = `the dev server the guide opens (${step.href}) is not reachable`;
          firstFailureSeen = true;
        }
      }
      continue;
    }

    const command = step.command;
    if (!command || command.trim() === "") {
      entry.disposition = "noop";
      entry.ran = false;
      continue;
    }
    if (entry.sensitive) {
      entry.disposition = "handed-back-sensitive";
      entry.ran = false;
      continue;
    }
    if (entry.syntacticallyIncomplete) {
      entry.disposition = "refused-incomplete";
      entry.ran = true;
      entry.failed = true;
      entry.exitCode = 2;
      entry.failureReason = "Iris refuses to type a syntactically incomplete command (unterminated quote / heredoc)";
      firstFailureSeen = true;
      continue;
    }
    if (entry.riskWithGrant.tier === "refusedOutright") {
      entry.disposition = "refused-catastrophe";
      entry.ran = true;
      entry.failed = true;
      entry.failureReason = `the catastrophe floor refuses this even under the grant: ${entry.riskWithGrant.reason}`;
      firstFailureSeen = true;
      continue;
    }

    if (entry.holdsTheShellOpen) {
      // Side session, like startLongRunning.
      if (!side) {
        side = new ZshSession({ env, home, label: "side" });
        if (!(await side.start())) {
          entry.disposition = "long-running";
          entry.ran = true;
          entry.failed = true;
          entry.failureReason = "the side zsh session never became ready";
          firstFailureSeen = true;
          continue;
        }
      }
      const moved = await moveInto(step.workingDirectory, side, entry);
      if (!moved) {
        firstFailureSeen = true;
        continue;
      }
      entry.disposition = "long-running";
      entry.ran = true;
      const startedAt = Date.now();
      const handle = side.startLongRunning(command);
      let served;
      while (Date.now() - startedAt < graceMs) {
        const code = handle.exitedWith();
        if (code !== undefined) break;
        served = lib.detectServedUrl(handle.outputSoFar());
        if (served) {
          // Give it a moment to actually bind, then probe.
          await sleep(2_000);
          break;
        }
        await sleep(1_000);
      }
      const code = handle.exitedWith();
      entry.durationMs = Date.now() - startedAt;
      entry.output = lib.tail(handle.outputSoFar());
      fs.writeFileSync(logFile, handle.outputSoFar());
      if (code !== undefined) {
        entry.exitCode = code;
        entry.failed = true;
        entry.failureReason = `a command Iris treats as a dev server exited (status ${code}) within ${Math.round(graceMs / 1000)} s`;
        firstFailureSeen = true;
      } else {
        entry.exitCode = null;
        const url = served ?? nextLocalOpenHref(mainSteps, step);
        if (url) {
          entry.served = await lib.probeServed(url);
          if (!entry.served.reachable) {
            entry.failed = true;
            entry.failureReason = `the dev server started but ${url} did not answer: ${entry.served.status}`;
            firstFailureSeen = true;
          }
        } else {
          entry.notes = ["started; no localhost URL to probe"];
        }
      }
      continue;
    }

    // An ordinary command in the main session.
    const moved = await moveInto(step.workingDirectory, main, entry);
    if (!moved) {
      firstFailureSeen = true;
      continue;
    }
    entry.disposition = "ran";
    entry.ran = true;
    const outcome = await main.run(command, maxStepMs);
    entry.durationMs = outcome.durationMs;
    entry.exitCode = outcome.exitCode ?? null;
    entry.cwdAfter = outcome.cwd ?? null;
    entry.output = lib.tail(outcome.output);
    entry.exceededIrisDeadline = outcome.durationMs > IRIS_COMMAND_DEADLINE_MS;
    fs.writeFileSync(logFile, outcome.output);
    if (outcome.timedOut) {
      entry.failed = true;
      entry.failureReason = `still running after ${Math.round(maxStepMs / 60000)} min (Iris would have stopped it at 15 min)`;
      await main.start();
    } else if (outcome.shellDied) {
      entry.failed = true;
      entry.failureReason = `the command ended Iris's whole terminal session (shell exited ${outcome.shellExitCode}) — a bare exit in the step text`;
      await main.start();
    } else if (outcome.exitCode !== 0) {
      entry.failed = true;
      entry.failureReason = `exit status ${outcome.exitCode}`;
    } else if (entry.exceededIrisDeadline) {
      entry.failed = true;
      entry.failureReason = `finished with status 0 but took ${Math.round(outcome.durationMs / 60000)} min — past Iris's 15-minute per-command deadline, so Iris would have killed it`;
    }
    if (entry.failed) firstFailureSeen = true;

    // What the step's own watch would look for, checked from a fresh login shell.
    const toolExpectations = (step.watch?.expect ?? []).filter((e) => e.type === "toolVersion");
    if (toolExpectations.length > 0) {
      entry.toolChecks = [];
      for (const e of toolExpectations) entry.toolChecks.push(await lib.toolVersion(e.tool, { shell: "/bin/zsh", env }));
    }
  }

  // Setup steps are only walked by Iris when a check step finds a tool missing;
  // record them without running (on macOS they are an Apple installer prompt and
  // a download page).
  for (const s of steps.filter((x) => x.isSetupStep)) {
    s.disposition = "setup-not-run";
    s.ran = false;
  }

  killEverything();
  finish(result, outDir);
  process.exit(0);
}

function nextLocalOpenHref(mainSteps, current) {
  const i = mainSteps.indexOf(current);
  for (const later of mainSteps.slice(i + 1, i + 4)) {
    if (later.kind === "open" && later.href && lib.isLocalHref(later.href)) return later.href;
  }
  return undefined;
}

async function moveInto(folder, session, entry) {
  if (!folder) return true;
  if (lib.isASystemFolder(folder)) {
    entry.disposition = "folder-refused";
    entry.ran = true;
    entry.failed = true;
    entry.failureReason = `Iris refuses to move the shell into the system folder ${folder}`;
    return false;
  }
  if (!lib.isAPlainFolder(folder)) {
    entry.disposition = "folder-refused";
    entry.ran = true;
    entry.failed = true;
    entry.failureReason = `Iris refuses a workingDirectory that is not a plain ~/ or / path: ${folder}`;
    return false;
  }
  const outcome = await session.run(`cd ${folder}`, FOLDER_MOVE_DEADLINE_MS);
  if (outcome.exitCode === 0) return true;
  entry.disposition = "folder-refused";
  entry.ran = true;
  entry.failed = true;
  entry.exitCode = outcome.exitCode ?? null;
  entry.output = lib.tail(outcome.output);
  entry.failureReason = `could not cd into ${folder} (the clone step before it did not produce that folder)`;
  return false;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function finish(result, outDir) {
  for (const s of result.steps.filter((x) => x.order)) {
    console.log(`[guide-ci]   ${String(s.order).padStart(2)} ${s.disposition.padEnd(22)} ${s.id.padEnd(22)} ${s.exitCode !== undefined && s.exitCode !== null ? `exit ${s.exitCode}` : ""} ${s.durationMs ? `${Math.round(s.durationMs / 1000)} s` : ""} ${s.failed ? `FAILED: ${s.failureReason}` : ""}`);
  }
  result.finishedAt = lib.nowIso();
  lib.summarize(result);
  const file = lib.writeResult(outDir, result);
  const ff = result.firstFailure ? ` — first failure: ${result.firstFailure.stepId} (${result.firstFailure.reason})` : "";
  console.log(`[guide-ci] ${result.slug} macos:${result.target ?? "desktop"} → ${result.verdict}${ff}`);
  console.log(`[guide-ci] wrote ${file}`);
}

main().catch((error) => {
  console.error(`[guide-ci] harness error: ${error.stack ?? error}`);
  const args = lib.parseArgs(process.argv.slice(2));
  try {
    lib.writeResult(path.resolve(args.out ?? "guide-ci-results"), {
      harness: "run-macos",
      slug: args.slug ?? "unknown",
      platform: "macos",
      target: args.target && args.target !== "desktop" ? args.target : null,
      verdict: "error",
      steps: [],
      notes: [String(error.stack ?? error)],
      startedAt: lib.nowIso(),
      finishedAt: lib.nowIso(),
      counts: {},
    });
  } catch {
    /* nothing more to do */
  }
  process.exit(0);
});
