/**
 * tool-versions.ts
 *
 * "Is git installed?" for the guide panel's verification steps.
 *
 * The allowlist is ported from `tool_spec` in
 * `iris-desktop/src-tauri/src/main.rs`. It exists so a guide — which is
 * server-served content and therefore not something a client release reviewed —
 * cannot name an arbitrary program for Iris to run. A tool that is not on this
 * list is refused; there is no escape hatch, and no part of the command is ever
 * built from guide text.
 */

export interface ToolVersionResult {
  tool: string;
  available: boolean;
  version: string;
}

/** Executable and arguments for each tool a guide may ask about. */
const TOOL_SPECS: ReadonlyMap<string, readonly [string, readonly string[]]> = new Map([
  ["git", ["git", ["--version"]] as const],
  ["node", ["node", ["--version"]] as const],
  ["npm", ["npm", ["--version"]] as const],
  ["pnpm", ["pnpm", ["--version"]] as const],
  ["bun", ["bun", ["--version"]] as const],
  ["python", ["python", ["--version"]] as const],
  ["python3", ["python3", ["--version"]] as const],
  ["uv", ["uv", ["--version"]] as const],
  ["cargo", ["cargo", ["--version"]] as const],
  ["rustc", ["rustc", ["--version"]] as const],
  ["docker", ["docker", ["--version"]] as const],
  ["java", ["java", ["--version"]] as const],
  ["adb", ["adb", ["version"]] as const],
]);

export function toolSpecFor(tool: string): readonly [string, readonly string[]] | null {
  return TOOL_SPECS.get(tool) ?? null;
}

export function isAllowlistedTool(tool: string): boolean {
  return TOOL_SPECS.has(tool);
}

/** Version strings are short; anything longer is a program misbehaving. */
const MAX_VERSION_OUTPUT_LENGTH = 200;

export function boundedCommandOutput(standardOutput: string, standardError: string): string {
  const combined = (standardOutput.trim() || standardError.trim()).split(/\r?\n/)[0] ?? "";
  return combined.slice(0, MAX_VERSION_OUTPUT_LENGTH).trim();
}
