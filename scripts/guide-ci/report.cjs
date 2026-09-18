#!/usr/bin/env node
// Folds every result JSON into one scoreboard (Markdown).
//
//   node report.cjs [--in guide-ci-results] [--out SCOREBOARD.md]

"use strict";

const fs = require("node:fs");
const path = require("node:path");
const lib = require("./lib.cjs");

const VERDICT_ORDER = { red: 0, error: 1, gate: 2, green: 3, "no-branch": 4, unsupported: 5 };
const VERDICT_MARK = { red: "🔴 red", error: "⚠️ error", gate: "🟡 gate", green: "🟢 green", "no-branch": "▫️ no branch", unsupported: "⬜ unsupported" };

function loadResults(dir) {
  const results = [];
  for (const file of fs.readdirSync(dir)) {
    if (!file.endsWith(".json")) continue;
    try {
      const parsed = JSON.parse(fs.readFileSync(path.join(dir, file), "utf8"));
      // Only branch results carry `steps`; the planner's inventory and any
      // stray JSON are skipped rather than crashing the whole report.
      if (!parsed || !Array.isArray(parsed.steps)) continue;
      // Re-derive the verdict with the current gate rules, so a result written
      // by an older runner is classified the same way as a fresh one.
      if (parsed.verdict === "green" || parsed.verdict === "red" || parsed.verdict === "gate") {
        delete parsed.verdict;
        delete parsed.firstFailure;
        lib.summarize(parsed);
      }
      results.push(parsed);
    } catch (error) {
      results.push({ slug: file, platform: "?", target: null, verdict: "error", steps: [], notes: [`unreadable: ${error.message}`], counts: {} });
    }
  }
  return results;
}

function short(text, n = 140) {
  const one = String(text ?? "").replace(/\s+/g, " ").trim();
  return one.length > n ? `${one.slice(0, n - 1)}…` : one;
}

function minutes(result) {
  if (!result.startedAt || !result.finishedAt) return "";
  const ms = new Date(result.finishedAt) - new Date(result.startedAt);
  return `${Math.round(ms / 60000)} min`;
}

function flags(result) {
  const out = [];
  const c = result.counts ?? {};
  if (c.exceededIrisDeadline) out.push(`${c.exceededIrisDeadline} step(s) past Iris's 15-min ceiling`);
  if (c.deadHrefs) out.push(`${c.deadHrefs} dead link(s)`);
  if (result.steps.some((s) => s.failureReason && /whole terminal session/.test(s.failureReason))) out.push("a step killed the shell");
  const translated = result.steps.filter((s) => s.needsPosixTranslation).length;
  if (translated) out.push(`${translated} POSIX step(s) translated by Iris`);
  const remnants = result.steps.filter((s) => (s.posixRemnantsAfterTranslation ?? []).length > 0).length;
  if (remnants) out.push(`${remnants} step(s) with POSIX left in PowerShell`);
  const refusedNoGrant = result.steps.filter((s) => s.riskWithoutGrant && /refused/i.test(s.riskWithoutGrant.tier)).length;
  if (refusedNoGrant) out.push(`${refusedNoGrant} refused without the grant`);
  const confirmNoGrant = result.steps.filter((s) => s.riskWithoutGrant && /confirm/i.test(s.riskWithoutGrant.tier)).length;
  if (confirmNoGrant) out.push(`${confirmNoGrant} need a tap without the grant`);
  if (result.setupDetour && result.setupDetour !== "ready") out.push(`setup detour: ${result.setupDetour}`);
  return out.join("; ");
}

function table(results) {
  const rows = ["| Guide | Branch | Verdict | First failure | Ran / failed | Reader steps | Time | Flags |", "|---|---|---|---|---|---|---|---|"];
  for (const r of results) {
    const c = r.counts ?? {};
    const ff = r.firstFailure ? `\`${r.firstFailure.stepId}\` — ${short(r.firstFailure.reason, 110)}` : "";
    rows.push(`| ${r.slug} | ${r.platform}:${r.target ?? "desktop"} | ${VERDICT_MARK[r.verdict] ?? r.verdict} | ${ff} | ${c.ran ?? 0} / ${c.failed ?? 0} | ${c.reader ?? 0} | ${minutes(r)} | ${short(flags(r), 160)} |`);
  }
  return rows.join("\n");
}

function failureDetail(r) {
  const lines = [];
  for (const s of r.steps.filter((x) => x.failed)) {
    lines.push(`#### ${r.slug} ${r.platform}:${r.target ?? "desktop"} → step \`${s.id}\` (${s.title})${s.afterFirstFailure ? " _(after an earlier failure — may be a cascade)_" : ""}`);
    lines.push(`- **Why:** ${s.failureReason ?? ""}${s.exitCode !== undefined && s.exitCode !== null ? ` (exit ${s.exitCode})` : ""}${s.durationMs ? `, ${Math.round(s.durationMs / 1000)} s` : ""}`);
    if (s.workingDirectory) lines.push(`- **Folder:** \`${s.workingDirectory}\``);
    const cmd = s.commandAsIrisRunsIt ?? s.command;
    if (cmd) lines.push("- **Command as Iris runs it:**", "```", cmd, "```");
    if (s.surfaced) lines.push(`- **Surfaced to the reader as:** ${short(s.surfaced, 300)}`);
    if (s.output) lines.push("- **Output tail:**", "```", lib.tail(s.output, 25, 2500), "```");
    lines.push("");
  }
  return lines.join("\n");
}

function staticFindings(results) {
  const lines = [];
  const dead = [];
  const refused = [];
  const remnants = [];
  const incomplete = [];
  for (const r of results) {
    for (const s of r.steps) {
      if (s.href && s.href.ok === false) dead.push(`- ${r.slug} ${r.platform}:${r.target ?? "desktop"} \`${s.id}\`: ${s.href.href} → ${s.href.status}`);
      if (s.riskWithoutGrant && /refused/i.test(s.riskWithoutGrant.tier)) refused.push(`- ${r.slug} ${r.platform}:${r.target ?? "desktop"} \`${s.id}\`: ${s.riskWithoutGrant.reason}`);
      if ((s.posixRemnantsAfterTranslation ?? []).length > 0) remnants.push(`- ${r.slug} windows:${r.target ?? "desktop"} \`${s.id}\`: ${s.posixRemnantsAfterTranslation.join("; ")}`);
      if (s.syntacticallyIncomplete) incomplete.push(`- ${r.slug} ${r.platform}:${r.target ?? "desktop"} \`${s.id}\``);
    }
  }
  lines.push("### Dead or unreachable links in `open` steps", dead.length ? [...new Set(dead)].join("\n") : "_none_", "");
  lines.push("### Commands Iris refuses outright when the autonomy grant is off", refused.length ? [...new Set(refused)].join("\n") : "_none_", "");
  lines.push("### Windows steps with POSIX shell text left after Iris's translation", remnants.length ? [...new Set(remnants)].join("\n") : "_none_", "");
  lines.push("### Commands Iris refuses as syntactically incomplete", incomplete.length ? incomplete.join("\n") : "_none_", "");
  return lines.join("\n");
}

function main() {
  const args = lib.parseArgs(process.argv.slice(2));
  const inDir = path.resolve(args.in ?? "guide-ci-results");
  const outFile = path.resolve(args.out ?? path.join(inDir, "SCOREBOARD.md"));
  const results = loadResults(inDir).sort((a, b) => (VERDICT_ORDER[a.verdict] ?? 9) - (VERDICT_ORDER[b.verdict] ?? 9) || a.slug.localeCompare(b.slug) || a.platform.localeCompare(b.platform));
  const by = (v) => results.filter((r) => r.verdict === v).length;
  const md = [];
  md.push(`# Guide CI scoreboard`, "");
  md.push(`Generated ${lib.nowIso()} — ${results.length} branch runs: **${by("green")} green**, **${by("red")} red**, ${by("gate")} stopped at a reader gate, ${by("error")} harness errors, ${by("unsupported")} unsupported pairs, ${by("no-branch")} missing branches.`, "");
  md.push("Every command a guide asks Iris to run was typed into the shell Iris uses on that platform (persistent login zsh on macOS; one `powershell.exe` per step through the real Windows autopilot modules). Reader-only steps (open / permission / web / paste / verify / sensitive) are not executed; their links are checked. 🔴 means a command failed, timed out, was refused, or killed the shell; 🟡 means the first thing that stopped the run was a step only a person can finish (an installer waiting for a click), with anything after it unverified.", "");
  for (const platform of ["macos", "windows"]) {
    const rows = results.filter((r) => r.platform === platform);
    if (rows.length === 0) continue;
    md.push(`## ${platform === "macos" ? "macOS" : "Windows"}`, "", table(rows), "");
  }
  const failing = results.filter((r) => r.steps.some((s) => s.failed));
  md.push("## Failures in detail", "");
  md.push(failing.length ? failing.map(failureDetail).join("\n") : "_no failing steps_", "");
  md.push("## Static findings", "", staticFindings(results), "");
  const errors = results.filter((r) => r.verdict === "error");
  if (errors.length) {
    md.push("## Harness errors", "");
    for (const r of errors) md.push(`- ${r.slug} ${r.platform}:${r.target ?? "desktop"}: ${short((r.notes ?? []).join(" | "), 300)}`);
    md.push("");
  }
  const envs = results.filter((r) => r.environment).slice(0, 2);
  if (envs.length) {
    md.push("## Runner environments (sample)", "");
    for (const r of envs) {
      const t = r.environment.tools ?? {};
      const have = Object.values(t).filter((x) => x.available).map((x) => `${x.tool} ${x.version}`.trim());
      md.push(`- **${r.platform}** ${r.environment.os} ${r.environment.runnerImage ? `(${r.environment.runnerImage})` : ""}${r.environment.powershell ? `, PowerShell ${r.environment.powershell}` : ""}: ${short(have.join("; "), 400)}`);
    }
    md.push("");
  }
  const text = md.join("\n");
  fs.writeFileSync(outFile, text);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text);
  console.log(text);
}

main();
