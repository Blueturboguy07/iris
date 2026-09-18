#!/usr/bin/env node
// Runs one guide branch through the REAL Iris-for-Windows autopilot modules,
// headlessly — the same code the app runs, minus Electron and the tray:
//
//   guide-recipe-resolver  fetches the live guide, derives the recipe
//                          (POSIX clone idiom → PowerShell, winget agreements)
//   setup-detour           the prerequisite check (git/node) with the real
//                          registry-refreshing tool probe
//   PowerShellSession      one powershell.exe per command, cwd threaded,
//                          exit code + cwd read back from marker lines
//   AutopilotRunner        the step machine, with the autonomy grant ON, no fix
//                          ladder (a failure surfaces at once) and no watch
//                          executor (a verify/reader step hands back at once)
//
// Reader steps are auto-acknowledged so the run reaches every command; a
// surfaced failure is recorded and the run continues past it so later,
// independent failures are found in the same run.
//
//   node run-windows.cjs --slug cue [--target desktop|android] --dist <iris-windows/dist>
//                        [--out DIR] [--base https://publikhq.com] [--max-step-minutes 60]

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const lib = require("./lib.cjs");

const IRIS_COMMAND_DEADLINE_MS = 15 * 60 * 1000; // shell.ts DEFAULT_COMMAND_TIMEOUT_MS

async function main() {
  const args = lib.parseArgs(process.argv.slice(2));
  const slug = args.slug;
  if (!slug) throw new Error("--slug is required");
  if (!args.dist) throw new Error("--dist <path to compiled iris-windows/dist> is required");
  const dist = path.resolve(args.dist);
  const target = args.target && args.target !== "desktop" ? args.target : null;
  const base = args.base ?? lib.DEFAULT_BASE;
  const outDir = path.resolve(args.out ?? "guide-ci-results");
  const maxStepMs = Number.parseFloat(args["max-step-minutes"] ?? "60") * 60_000;

  const mod = (p) => require(path.join(dist, p));
  const { resolveGuideRecipe } = mod("services/autopilot/guide-recipe-resolver.js");
  const { PowerShellSession } = mod("main/powershell-session.js");
  const { AutopilotRunner } = mod("services/autopilot/runner.js");
  const { runSetupDetour } = mod("services/autopilot/setup-detour.js");
  const detourHost = mod("main/setup-detour-host.js");
  const shellModule = mod("services/autopilot/shell.js");
  const guideRecipe = mod("services/autopilot/guide-recipe.js");
  const risk = mod("services/autopilot/risk.js");

  // Let a slow build finish so its real outcome is learned; Iris's own 15-minute
  // ceiling is still recorded per step (`exceededIrisDeadline`).
  let deadlineNote = "";
  try {
    shellModule.DEFAULT_COMMAND_TIMEOUT_MS = maxStepMs;
    deadlineNote = shellModule.DEFAULT_COMMAND_TIMEOUT_MS === maxStepMs ? `per-command ceiling raised to ${maxStepMs / 60000} min for the harness` : "could not raise the per-command ceiling; Iris's 15 min applies";
  } catch {
    deadlineNote = "could not raise the per-command ceiling; Iris's 15 min applies";
  }

  const result = {
    harness: "run-windows",
    slug,
    platform: "windows",
    target,
    base,
    startedAt: lib.nowIso(),
    steps: [],
    notes: [deadlineNote],
    events: [],
  };
  const logDir = path.join(outDir, "logs", `${slug}--windows--${target ?? "desktop"}`);
  fs.mkdirSync(logDir, { recursive: true });

  // The raw guide, for the static pass and for the version/source fields.
  const guide = await lib.fetchGuide(base, slug);
  result.guideVersion = guide.version;
  result.guideStatus = guide.status;
  result.appName = guide.appName;
  result.source = `${guide.sourceOwner}/${guide.sourceRepo}@${(guide.sourceCommit ?? "").slice(0, 7)}`;
  const branch = lib.findBranch(guide, "windows", target);
  if (!branch) {
    result.verdict = "no-branch";
    result.notes.push(`guide has no windows:${target ?? "desktop"} branch (has ${guide.branches.map(lib.branchKey).join(", ")})`);
    finish(result, outDir);
    return;
  }
  if (branch.unsupported) {
    result.verdict = "unsupported";
    result.unsupported = branch.unsupported;
    finish(result, outDir);
    return;
  }

  result.environment = await lib.recordEnvironment({});
  result.environment.powershell = await psVersion();

  // ── Static pass over the authored steps ──────────────────────────────────
  const setupIds = new Set((branch.setupSteps ?? []).map((s) => s.id));
  const staticById = new Map();
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
      entry.needsPosixTranslation = guideRecipe.commandNeedsPosixTranslation(step.command);
      entry.commandAsIrisRunsIt = entry.needsPosixTranslation ? guideRecipe.translatePosixShellToPowerShell(step.command) : step.command;
      entry.posixRemnantsAfterTranslation = posixRemnants(entry.commandAsIrisRunsIt);
      entry.riskWithoutGrant = risk.assess(entry.commandAsIrisRunsIt, "vetted_recipe", false);
      entry.riskWithGrant = risk.assess(entry.commandAsIrisRunsIt, "vetted_recipe", true);
      entry.holdsTheShellOpen = guideRecipe.commandHoldsTheShellOpen(entry.commandAsIrisRunsIt);
    }
    if (step.href) {
      entry.href = lib.isLocalHref(step.href) ? { href: step.href, ok: true, status: "local (probed after the dev server starts)" } : await lib.checkHref(step.href);
    }
    staticById.set(`${entry.isSetupStep ? "setup:" : ""}${step.id}`, entry);
  }
  result.steps = [...staticById.values()];

  // ── Resolve through the real derivation ──────────────────────────────────
  const resolved = await resolveGuideRecipe(slug, {
    apiBase: base,
    fetchImplementation: (url, init) => fetch(url, init),
    target: target ? { platform: "windows", target } : { platform: "windows" },
    offlineFallback: () => undefined,
  });
  result.resolution = resolved.kind + (resolved.source ? `/${resolved.source}` : "");
  if (resolved.kind !== "recipe") {
    result.verdict = resolved.kind === "unsupported" ? "unsupported" : "error";
    result.notes.push(`resolver answered ${resolved.kind}: ${resolved.reason ?? resolved.requestedBranchKey ?? ""}`);
    finish(result, outDir);
    return;
  }
  const recipe = resolved.recipe;
  result.recipe = {
    steps: recipe.steps.map((s) => ({ id: s.id, kind: s.kind, longRunning: s.longRunning === true, translated: s.posixCommand !== undefined, workingDirectory: s.workingDirectory ?? null })),
    prerequisites: (recipe.prerequisites ?? []).map((p) => p.tool ?? p.id),
    output: recipe.output,
  };

  // ── Drive it ─────────────────────────────────────────────────────────────
  const shell = new PowerShellSession();
  const mainSteps = branch.steps ?? [];
  const runtimeById = new Map(); // recipe step index → step entry
  recipe.steps.forEach((s, i) => runtimeById.set(i, staticById.get(s.id) ?? { id: s.id, kind: s.kind, title: s.title }));
  let current = -1;
  let commandStartedAt = 0;
  let firstFailureSeen = false;
  let order = 0;

  const emit = (event) => {
    const stamped = { at: lib.nowIso(), ...event };
    if (event.type === "commandFinished") stamped.output = lib.tail(event.output ?? "", 40, 4_000);
    result.events.push(stamped);
    const entry = current >= 0 ? runtimeById.get(current) : undefined;
    switch (event.type) {
      case "stepStarted": {
        current = event.index;
        const e = runtimeById.get(current);
        order += 1;
        e.order = order;
        e.afterFirstFailure = firstFailureSeen;
        e.recipeKind = event.kind;
        if (event.kind === "noop") {
          e.disposition = "noop";
          e.ran = false;
        }
        break;
      }
      case "commandStarted":
        commandStartedAt = Date.now();
        if (entry) {
          entry.disposition = recipe.steps[current]?.longRunning ? "long-running" : "ran";
          entry.ran = true;
          entry.commandTyped = event.text;
        }
        break;
      case "commandFinished":
        if (entry) {
          entry.durationMs = Date.now() - commandStartedAt;
          entry.exitCode = event.exitCode;
          entry.output = lib.tail(event.output ?? "");
          entry.exceededIrisDeadline = entry.durationMs > IRIS_COMMAND_DEADLINE_MS;
          try {
            fs.writeFileSync(path.join(logDir, `${String(entry.order ?? 0).padStart(2, "0")}-${entry.id}.log`), event.output ?? "");
          } catch {
            /* ignore */
          }
          if (event.exitCode !== 0) {
            entry.failed = true;
            entry.failureReason = event.exitCode === 124 ? "Iris's per-command ceiling stopped it (exit 124)" : `exit status ${event.exitCode}`;
            firstFailureSeen = true;
          } else if (entry.exceededIrisDeadline) {
            entry.failed = true;
            entry.failureReason = `finished with status 0 but took ${Math.round(entry.durationMs / 60000)} min — past Iris's 15-minute per-command deadline`;
            firstFailureSeen = true;
          }
        }
        break;
      case "handedToReader":
        if (entry && entry.disposition === undefined) {
          entry.disposition = entry.sensitive ? "handed-back-sensitive" : "reader";
          entry.ran = false;
          entry.instruction = event.instruction;
        }
        break;
      case "openRequested":
        if (entry) {
          entry.disposition = entry.disposition ?? "open";
          entry.ran = entry.ran ?? false;
          entry.opened = event.href;
        }
        break;
      case "surfaced":
        if (entry) {
          entry.surfaced = event.reason;
          if (!entry.failed) {
            entry.ran = true;
            entry.failed = true;
            entry.failureReason = event.reason;
            firstFailureSeen = true;
          }
        } else {
          result.notes.push(`surfaced before any step: ${event.reason}`);
        }
        break;
      case "setupDetour":
        result.notes.push(`setup detour: missing ${event.missing.map((m) => m.tool).join(", ")}`);
        break;
      case "installingMissingTool":
        result.notes.push(`self-heal: re-running the guide's install step for ${event.tool}`);
        break;
      default:
        break;
    }
  };

  // The production prerequisite detour, with the real probe (registry PATH
  // refresh + Get-Command) and clock.
  try {
    const detour = await runSetupDetour(recipe, shell, {
      probe: new detourHost.RegistryRefreshingToolProbe(),
      clock: new detourHost.RealDetourClock(),
      platform: "win32",
      autonomyGranted: true,
      emit,
      shouldCancel: () => false,
    });
    result.setupDetour = detour.kind;
    if (detour.kind === "surfaced") {
      result.verdict = "red";
      result.notes.push(`the setup detour surfaced: ${detour.reason}`);
      result.firstFailure = { stepId: "setup-detour", reason: detour.reason };
    }
  } catch (error) {
    result.notes.push(`setup detour threw: ${error.message}`);
  }

  if (result.verdict !== "red") {
    const runner = new AutopilotRunner(recipe, "win32", true, undefined, undefined, emit);
    let status = await runner.runUntilBlocked(shell);
    let guard = 0;
    while (status.type !== "finished" && status.type !== "aborted" && status.type !== "sessionFailed" && guard < 500) {
      guard += 1;
      if (status.type === "needsReader") {
        status = await runner.readerFinishedCurrentStep(shell);
      } else if (status.type === "needsConfirm") {
        const e = runtimeById.get(status.stepIndex);
        if (e) e.confirmTapRequired = status.reason;
        status = await runner.confirmCurrentCommand(true, shell);
      } else if (status.type === "surfaced") {
        status = await runner.continuePastCurrentStep(shell);
      } else {
        break;
      }
    }
    result.finalStatus = status.type;
    if (status.type === "sessionFailed") {
      result.notes.push("the PowerShell session failed (spawn error)");
      result.verdict = "error";
    }
  }

  // The `open` step for a local-web app: is the dev server the guide opens there?
  for (const step of mainSteps) {
    if (step.kind === "open" && step.href && lib.isLocalHref(step.href)) {
      const entry = staticById.get(step.id);
      const served = await lib.probeServed(step.href, { attempts: 3, delayMs: 2_000 });
      entry.served = served;
      entry.href = { href: step.href, ok: served.reachable, status: served.status };
      if (!served.reachable && recipe.steps.some((s) => s.longRunning)) {
        entry.ran = true;
        entry.failed = true;
        entry.failureReason = `the dev server the guide opens (${step.href}) is not reachable`;
      }
    }
  }
  for (const s of result.steps.filter((x) => x.isSetupStep)) {
    if (s.disposition === undefined) {
      s.disposition = "setup-not-run";
      s.ran = false;
    }
  }
  for (const s of result.steps) {
    if (s.disposition === undefined) {
      s.disposition = s.kind === "terminal" || s.kind === "check" ? "not-reached" : "reader";
      s.ran = false;
    }
  }

  try {
    shell.dispose();
  } catch {
    /* ignore */
  }
  finish(result, outDir);
}

/// PowerShell syntax that survives the derivation's translation is still a
/// ParserError on the shell Iris drives; flag the shapes that matter.
function posixRemnants(command) {
  const remnants = [];
  for (const line of command.split(/\r?\n/)) {
    const t = line.trim();
    if (t === "fi" || t === "then" || t === "done" || t === "esac") remnants.push(t);
    if (/^\s*if\s*\[/.test(line)) remnants.push(t.slice(0, 40));
    if (/\[\s*!?\s*-[a-z]\s+\S/.test(line)) remnants.push(t.slice(0, 40));
    if (/^\s*\(\s*$/.test(line) || /^\s*\)\s*$/.test(line)) remnants.push("bare ( or ) line (POSIX subshell)");
    if (/^\s*exit\s+\d+\s*$/.test(line)) remnants.push("bare exit (ends the whole script block)");
    if (/\bgrep\s+-q/.test(line) || /\bsed\s+-E/.test(line)) remnants.push(t.slice(0, 40));
  }
  return [...new Set(remnants)];
}

async function psVersion() {
  const r = await lib.execFileP("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()"]);
  return r.stdout.trim() || r.stderr.trim();
}

function finish(result, outDir) {
  result.finishedAt = lib.nowIso();
  lib.summarize(result);
  const file = lib.writeResult(outDir, result);
  const ff = result.firstFailure ? ` — first failure: ${result.firstFailure.stepId} (${result.firstFailure.reason})` : "";
  console.log(`[guide-ci] ${result.slug} windows:${result.target ?? "desktop"} → ${result.verdict}${ff}`);
  console.log(`[guide-ci] wrote ${file}`);
}

main().catch((error) => {
  console.error(`[guide-ci] harness error: ${error.stack ?? error}`);
  const args = lib.parseArgs(process.argv.slice(2));
  try {
    lib.writeResult(path.resolve(args.out ?? "guide-ci-results"), {
      harness: "run-windows",
      slug: args.slug ?? "unknown",
      platform: "windows",
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
