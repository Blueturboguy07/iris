// report.mjs
//
// The suite's own tiny test recorder. There is deliberately no second test
// runner here (CLAUDE.md: "Do not add a second test runner" — that rule is
// about the unit suite, which stays vitest; this headed suite needs a real
// launched app + a real Windows desktop, so it cannot be a vitest test and is
// CI-only). This records pass/fail per check and per scenario, writes a JSON +
// text results log for the CI artifact, and drives the process exit code.

import { writeFileSync } from "node:fs";
import { join } from "node:path";

export class Results {
  constructor() {
    this.scenarios = [];
    this.current = null;
  }

  scenario(name) {
    this.current = { name, checks: [], startedAt: Date.now(), error: null };
    this.scenarios.push(this.current);
    log(`\n=== ${name} ===`);
    return this.current;
  }

  /** Records a boolean check. Never throws — a failed check is data, so one
   *  failing assertion does not abort the rest of a scenario's checks. */
  check(description, passed, detail = "") {
    const entry = { description, passed: Boolean(passed), detail: String(detail) };
    (this.current?.checks ?? []).push(entry);
    log(`  ${entry.passed ? "PASS" : "FAIL"}  ${description}${detail ? `  — ${detail}` : ""}`);
    return entry.passed;
  }

  /** Records that a whole scenario blew up (an unexpected throw). */
  scenarioError(error) {
    if (this.current) this.current.error = error?.stack || String(error);
    log(`  ERROR in scenario '${this.current?.name}': ${error?.stack || error}`);
  }

  get passed() {
    return this.scenarios.every(
      (s) => s.error === null && s.checks.length > 0 && s.checks.every((c) => c.passed),
    );
  }

  summary() {
    let totalChecks = 0;
    let failedChecks = 0;
    for (const s of this.scenarios) {
      for (const c of s.checks) {
        totalChecks += 1;
        if (!c.passed) failedChecks += 1;
      }
    }
    return { scenarios: this.scenarios.length, totalChecks, failedChecks, passed: this.passed };
  }

  write(dir) {
    const summary = this.summary();
    writeFileSync(join(dir, "results.json"), JSON.stringify({ summary, scenarios: this.scenarios }, null, 2));

    const textLines = [];
    for (const s of this.scenarios) {
      textLines.push(`=== ${s.name} ===`);
      if (s.error) textLines.push(`  ERROR: ${s.error}`);
      for (const c of s.checks) {
        textLines.push(`  ${c.passed ? "PASS" : "FAIL"}  ${c.description}${c.detail ? `  — ${c.detail}` : ""}`);
      }
      textLines.push("");
    }
    textLines.push(
      `SUMMARY: ${summary.scenarios} scenarios, ${summary.totalChecks} checks, ${summary.failedChecks} failed — ${summary.passed ? "GREEN" : "RED"}`,
    );
    writeFileSync(join(dir, "results.txt"), textLines.join("\n"));
  }
}

const logBuffer = [];
export function log(line) {
  console.log(line);
  logBuffer.push(line);
}

export function flushLog(dir) {
  writeFileSync(join(dir, "run.log"), logBuffer.join("\n"));
}
