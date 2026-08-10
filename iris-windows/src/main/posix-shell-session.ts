//
// The macOS/Linux shell the autopilot runs approved commands in — the POSIX twin
// of `powershell-session.ts`, so the exact same runner, no-click flow, and
// animated terminal can drive a real install when Iris is run on a Mac for
// testing (the shipped Windows product uses the PowerShell session).
//
// Same design: one short-lived login shell per command, threading the working
// directory forward on a marker line, so `cd` in one step persists to the next.
// A login shell (`zsh -l`) is used so a developer's PATH (brew, node, corepack)
// is present exactly as it is in their Terminal.
//

import { spawn } from "node:child_process";

import type { ApprovedCommand } from "../services/autopilot/risk";
import { detectServedUrl, type CommandOutcome, type ShellSession } from "../services/autopilot/shell";
import { parseRun } from "./powershell-session";

const MAX_OUTPUT = 8 * 1024;

/// The script Iris wraps every command in: pin the location, run the command,
/// then print the exit code and resulting directory on the same marker lines the
/// PowerShell session uses, so `parseRun` reads both the same way.
export function wrapPosixCommand(command: string, cwd: string): string {
  const quotedCwd = `'${cwd.replace(/'/g, `'\\''`)}'`;
  return [
    `cd ${quotedCwd} 2>/dev/null || true`,
    command,
    "__iris_code=$?",
    `printf '__IRIS_CWD__:%s\\n' "$PWD"`,
    `printf '__IRIS_CODE__:%s\\n' "$__iris_code"`,
  ].join("\n");
}

const LOGIN_SHELL = process.env.SHELL && process.env.SHELL.length > 0 ? process.env.SHELL : "/bin/zsh";
// corepack would otherwise stop to ask before downloading pnpm on first use,
// which a non-interactive install cannot answer.
const SHELL_ENV = { ...process.env, COREPACK_ENABLE_DOWNLOAD_PROMPT: "0" };

interface Collected {
  readonly stdout: string;
  readonly stderr: string;
  readonly spawnFailed: boolean;
}

export class PosixShellSession implements ShellSession {
  private cwd: string;
  private readonly servers: ReturnType<typeof spawn>[] = [];

  constructor(startingDirectory: string = process.env.HOME ?? "/") {
    this.cwd = startingDirectory;
  }

  currentDirectory(): string {
    return this.cwd;
  }

  async run(command: ApprovedCommand, deadlineMs: number): Promise<CommandOutcome> {
    const collected = await this.spawnScript(wrapPosixCommand(command.text, this.cwd), deadlineMs);
    if (collected === "timed_out") return { kind: "timed_out" };
    if (collected.spawnFailed) return { kind: "session_failed" };
    const parsed = parseRun(collected.stdout, collected.stderr);
    if (parsed.cwd !== undefined) this.cwd = parsed.cwd;
    const exitCode = parsed.exitCode ?? 1;
    return exitCode === 0
      ? { kind: "succeeded", output: parsed.output }
      : { kind: "failed", exitCode, output: parsed.output };
  }

  async runLongRunning(
    command: ApprovedCommand,
    readyMarker: string | undefined,
    graceMs: number,
  ): Promise<CommandOutcome> {
    const quotedCwd = `'${this.cwd.replace(/'/g, `'\\''`)}'`;
    const child = spawn(LOGIN_SHELL, ["-l", "-c", `cd ${quotedCwd}; ${command.text}`], {
      env: SHELL_ENV,
    });
    this.servers.push(child);

    return new Promise<CommandOutcome>((resolve) => {
      let settled = false;
      let output = "";
      const done = (outcome: CommandOutcome): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(outcome);
      };
      const succeed = (): void =>
        done({ kind: "succeeded", output: output.slice(0, MAX_OUTPUT), servedUrl: detectServedUrl(output) });
      const timer = setTimeout(succeed, graceMs);
      const onData = (chunk: string): void => {
        if (output.length < MAX_OUTPUT) output += chunk;
        if (readyMarker !== undefined && output.includes(readyMarker)) succeed();
      };
      child.stdout?.setEncoding("utf8");
      child.stderr?.setEncoding("utf8");
      child.stdout?.on("data", onData);
      child.stderr?.on("data", onData);
      child.on("error", () => done({ kind: "session_failed" }));
      child.on("exit", (code) =>
        done(code === 0 ? { kind: "succeeded", output } : { kind: "failed", exitCode: code ?? 1, output }),
      );
    });
  }

  dispose(): void {
    for (const server of this.servers) server.kill();
    this.servers.length = 0;
  }

  private spawnScript(script: string, deadlineMs: number): Promise<Collected | "timed_out"> {
    return new Promise((resolve) => {
      const child = spawn(LOGIN_SHELL, ["-l", "-c", script], { env: SHELL_ENV });
      let stdout = "";
      let stderr = "";
      let settled = false;
      const finish = (value: Collected | "timed_out"): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => {
        child.kill();
        finish("timed_out");
      }, deadlineMs);
      child.stdout?.setEncoding("utf8");
      child.stderr?.setEncoding("utf8");
      child.stdout?.on("data", (chunk: string) => {
        stdout += chunk;
      });
      child.stderr?.on("data", (chunk: string) => {
        stderr += chunk;
      });
      child.on("error", () => finish({ stdout, stderr, spawnFailed: true }));
      child.on("close", () => finish({ stdout, stderr, spawnFailed: false }));
    });
  }
}
