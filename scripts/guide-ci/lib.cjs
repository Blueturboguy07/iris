// Shared pieces of the guide CI harness: fetching the catalog and guides,
// recording the runner's environment, checking links, checking tool versions,
// and the JS ports of the macOS command-shape / risk-gate rules.
//
// Zero dependencies on purpose: this runs on a bare GitHub runner before any
// project install has happened, on both macOS and Windows.

"use strict";

const { execFile } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const DEFAULT_BASE = "https://publikhq.com";

// ── Catalog + guides ────────────────────────────────────────────────────────────

async function fetchJson(url, timeoutMs = 20_000) {
  const response = await fetch(url, { signal: AbortSignal.timeout(timeoutMs), headers: { accept: "application/json" } });
  if (!response.ok) throw new Error(`${url} → HTTP ${response.status}`);
  return response.json();
}

// publik's guide API is served through a CDN with a 5-minute cache and a day
// of stale-while-revalidate. A guide changed only in Supabase (a community
// guide) can be served stale for hours; the harness must test what is stored,
// so every fetch carries a cache-busting query the route ignores.
function cacheBusted(url) {
  return `${url}${url.includes("?") ? "&" : "?"}t=${Date.now()}`;
}

async function fetchCatalog(base = DEFAULT_BASE) {
  const body = await fetchJson(cacheBusted(`${base}/api/iris/apps`));
  const apps = Array.isArray(body) ? body : body.apps;
  if (!Array.isArray(apps)) throw new Error("catalog has no apps[]");
  return apps;
}

async function fetchGuide(base, slug) {
  return fetchJson(cacheBusted(`${base}/api/iris/guides/${encodeURIComponent(slug)}`));
}

function branchKey(branch) {
  return `${branch.platform}:${branch.target ?? "desktop"}`;
}

function findBranch(guide, platform, target) {
  const wanted = `${platform}:${target ?? "desktop"}`;
  return (guide.branches ?? []).find((b) => branchKey(b) === wanted);
}

function allSteps(branch) {
  return [...(branch.setupSteps ?? []), ...(branch.steps ?? [])];
}

// ── Ports of GuideAutopilotCommandShape.swift ───────────────────────────────────

const HOLDS_THE_SHELL_OPEN = [
  /\b(npm|pnpm|yarn|bun)\s+(run\s+)?(start|dev|watch|serve|preview|app|electron)\b/i,
  /\bnext\s+dev\b/i,
  /(^|\s|\/)vite(\s|$)/i,
  /\bdocker\s+compose\s+up\b(?![^\n]*\s-d\b)/i,
  /\bpython3?\s+-m\s+http\.server\b/i,
  /\bcargo\s+run\b/i,
  /\bexpo\s+start\b/i,
  /\bflutter\s+run\b/i,
  /\brails\s+s(erver)?\b/i,
  /\btauri\s+dev\b/i,
];

function holdsTheShellOpen(command) {
  return HOLDS_THE_SHELL_OPEN.some((p) => p.test(command));
}

function looksSyntacticallyIncomplete(command) {
  if (/<<-?\s*['"]?\w+/.test(command)) return true;
  let single = false;
  let double = false;
  let prevBackslash = false;
  for (const ch of command) {
    if (prevBackslash) {
      prevBackslash = false;
      continue;
    }
    if (ch === "\\" && !single) prevBackslash = true;
    else if (ch === "'" && !double) single = !single;
    else if (ch === '"' && !single) double = !double;
  }
  if (single || double) return true;
  const trimmed = command.trim();
  return prevBackslash && trimmed.endsWith("\\");
}

// GuideAutopilotRunner.isAPlainFolder / isASystemFolder
function isAPlainFolder(folder) {
  if (!folder || !(folder.startsWith("~") || folder.startsWith("/"))) return false;
  if (!/^[A-Za-z0-9._~@+\-/]+$/.test(folder)) return false;
  return !folder.split("/").includes("..");
}

function isASystemFolder(folder) {
  return folder === "/" || /^\/(usr|etc|Library|System|Applications)(\/|$)/.test(folder);
}

// ── Port of GuideAutopilotRiskAssessment.swift (macOS) ──────────────────────────
// Raw-text assessment only (the working-directory re-rendering is not ported;
// it can only ever ADD a confirm tap, never change a refusal).

const R = (source, reason) => ({ pattern: new RegExp(source, "i"), reason });

const MAC_CATASTROPHE_RULES = [
  R(String.raw`\brm\b[^\n]*\s-[a-z]*(rf|fr)[a-z]*\s+(/|/\*|~|~/|~/\*|\$HOME|\$HOME/\*)\s*(\n|$|;|&)`, "This deletes the root of the disk or the whole home folder."),
  R(String.raw`\bdd\b[^\n]*\bof=/dev/`, "This writes raw bytes over a disk device."),
  R(String.raw`\bmkfs\b`, "This reformats a disk."),
  R(String.raw`\bdiskutil\s+(erase|reformat)`, "This erases a disk."),
  R(String.raw`\(\)\s*\{[^\n}]*\|[^\n}]*&[^\n}]*\}\s*;`, "This is a fork bomb."),
];

const OFFICIAL_INSTALLER_COMMANDS = new Set([
  '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
  'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"',
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh",
  "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
]);

function isAnOfficialInstaller(command) {
  return OFFICIAL_INSTALLER_COMMANDS.has(command.split(/[ \t]+/).filter(Boolean).join(" "));
}

const MAC_NON_CATASTROPHE_REFUSALS = [
  R(String.raw`\b(curl|wget)\b[^\n|]*\|[^\n]*\b(sh|bash|zsh)\b`, "This downloads a script and runs it without anyone reading it first."),
];

const MAC_CONFIRM_RULES = [
  R(String.raw`\bsudo\b`, "This runs as administrator."),
  R(String.raw`\brm\s+-rf\b`, "This force-deletes a folder and everything in it."),
  R(String.raw`\bcurl\b[^\n]*\|`, "This pipes a download into another program."),
  R(String.raw`\bwget\b[^\n]*\|`, "This pipes a download into another program."),
  R(String.raw`\bxattr\s+-cr\b`, "This strips macOS's safety attributes from files."),
  R(String.raw`\bSet-ExecutionPolicy\b`, "This changes what scripts Windows will run."),
  R(String.raw`\bInvoke-Expression\b`, "This runs text as a program."),
  R(String.raw`(^|\s)su(\s|$)`, "This switches to another user."),
  R(String.raw`\bosascript\b[^\n]*administrator privileges`, "This asks for administrator rights through AppleScript."),
  R(String.raw`\bsecurity\s+add-trusted-cert\b`, "This adds a trusted certificate."),
  R(String.raw`\bchmod\s+([0-7]*777|-R)\b`, "This loosens file permissions broadly."),
  R(String.raw`\bchown\b`, "This changes who owns files."),
  R(String.raw`\blaunchctl\s+(load|bootstrap)\b[^\n]*LaunchDaemons`, "This installs a system-level background service."),
  R(String.raw`\bcsrutil\b`, "This touches System Integrity Protection."),
  R(String.raw`\bspctl\b[^\n]*--master-disable`, "This turns Gatekeeper off."),
  R(String.raw`\bsystemsetup\b`, "This changes system-wide settings."),
  R(String.raw`\bxattr\b[^\n]*com\.apple\.quarantine`, "This strips the quarantine flag macOS puts on downloads."),
  R(String.raw`\bgit\s+reset\s+--hard\b`, "This throws away uncommitted changes."),
  R(String.raw`\bgit\s+clean\s+-[a-z]*f`, "This deletes untracked files."),
  R(String.raw`\bgit\s+checkout\s+--\s+\.`, "This discards local edits."),
  R(String.raw`\bgit\s+push\b[^\n]*(--force\b|\s-f\b)`, "This overwrites remote history."),
  R(String.raw`\btruncate\b`, "This empties a file in place."),
  R(String.raw`\bshred\b`, "This destroys a file's contents."),
  R(String.raw`\bfind\b[^\n]*-delete\b`, "This deletes every file the search matches."),
  R(String.raw`\bdefaults\s+delete\b`, "This erases an app's stored settings."),
  R(String.raw`\bkillall\b`, "This force-quits running apps."),
  R(String.raw`\bpkill\b`, "This force-quits running processes."),
  R(String.raw`\brmdir\b`, "This removes a directory."),
  R(String.raw`\bbrew\s+uninstall\b`, "This uninstalls software."),
  R(String.raw`\bdocker\s+(rm|rmi|volume\s+rm|system\s+prune)\b`, "This deletes Docker containers, images, or volumes."),
  R(String.raw`\bDROP\s+(TABLE|DATABASE)\b`, "This deletes a database."),
  R(String.raw`\bnpm\s+publish\b`, "This publishes a package to the public registry."),
  R(String.raw`>>?\s*/(usr|etc|Library|System|Applications)/`, "This writes into a system folder."),
  R(String.raw`\b(tee|cp|mv|ln|mkdir)\b[^\n]*\s/(usr|etc|Library|System|Applications)/`, "This changes files in a system folder."),
  R(String.raw`\$\((?!\()`, "Part of this command is computed when it runs, so its effect can't be read from its text."),
  R("`", "Part of this command is computed when it runs, so its effect can't be read from its text."),
  R(String.raw`\beval\b`, "This runs text as a program."),
  R(String.raw`\bbase64\b[^\n]*(-d|--decode)[^\n]*\|`, "This decodes hidden text and pipes it into a program."),
  R(String.raw`\|\s*(sh|bash|zsh)\b`, "This pipes text into a shell to run."),
];

function firstReason(rules, command) {
  for (const { pattern, reason } of rules) {
    const m = command.match(pattern);
    if (m) return { reason, match: m[0] };
  }
  return undefined;
}

/// Mirrors `assess(_:autonomyGranted:)`. Returns { tier, reason, match }.
function assessMacCommand(command, autonomyGranted) {
  const cat = firstReason(MAC_CATASTROPHE_RULES, command);
  if (cat) return { tier: "refusedOutright", ...cat };
  if (autonomyGranted) return { tier: "runsWithoutAsking" };
  if (isAnOfficialInstaller(command)) return { tier: "runsWithoutAsking" };
  const refused = firstReason(MAC_NON_CATASTROPHE_REFUSALS, command);
  if (refused) return { tier: "refusedOutright", ...refused };
  const confirm = firstReason(MAC_CONFIRM_RULES, command);
  if (confirm) return { tier: "needsAConfirmTap", ...confirm };
  return { tier: "runsWithoutAsking" };
}

// ── Tool version allowlist (ToolVersionService.swift / tool-versions.ts) ─────────

const TOOL_SPECS = {
  git: ["git", ["--version"]],
  node: ["node", ["--version"]],
  npm: ["npm", ["--version"]],
  pnpm: ["pnpm", ["--version"]],
  bun: ["bun", ["--version"]],
  python: ["python", ["--version"]],
  python3: ["python3", ["--version"]],
  uv: ["uv", ["--version"]],
  cargo: ["cargo", ["--version"]],
  rustc: ["rustc", ["--version"]],
  docker: ["docker", ["--version"]],
  java: ["java", ["--version"]],
  adb: ["adb", ["version"]],
  xcodebuild: ["xcodebuild", ["-version"]],
  brew: ["brew", ["--version"]],
  cmake: ["cmake", ["--version"]],
  gh: ["gh", ["--version"]],
};

function execFileP(file, args, options = {}) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 15_000, windowsHide: true, maxBuffer: 1 << 20, ...options }, (error, stdout, stderr) => {
      resolve({ error, stdout: String(stdout ?? ""), stderr: String(stderr ?? "") });
    });
  });
}

/// Runs the allowlisted version probe for `tool` through a login shell (so a
/// PATH written by an installer during the run is visible), returning the first
/// line or null when the tool is absent.
async function toolVersion(tool, { shell, env } = {}) {
  const spec = TOOL_SPECS[tool];
  if (!spec) return { tool, available: false, version: "", note: "not on the allowlist" };
  const [exe, args] = spec;
  let result;
  if (process.platform === "win32") {
    result = await execFileP(exe, args, { env, shell: true });
  } else {
    const line = [exe, ...args].join(" ");
    result = await execFileP(shell ?? "/bin/zsh", ["-l", "-i", "-c", line], { env });
  }
  const text = (result.stdout.trim() || result.stderr.trim()).split(/\r?\n/)[0] ?? "";
  const available = !result.error;
  return { tool, available, version: text.slice(0, 200) };
}

async function recordEnvironment({ shell, env } = {}) {
  const tools = {};
  for (const tool of Object.keys(TOOL_SPECS)) tools[tool] = await toolVersion(tool, { shell, env });
  let os = "";
  if (process.platform === "darwin") {
    const r = await execFileP("sw_vers", []);
    const m = await execFileP("uname", ["-m"]);
    os = `${r.stdout.replace(/\s+/g, " ").trim()} ${m.stdout.trim()}`;
  } else if (process.platform === "win32") {
    const r = await execFileP("cmd.exe", ["/c", "ver"]);
    os = r.stdout.trim();
  }
  return {
    platform: process.platform,
    os,
    node: process.version,
    home: process.env.HOME ?? process.env.USERPROFILE ?? "",
    user: process.env.USER ?? process.env.USERNAME ?? "",
    shell: process.env.SHELL ?? "",
    path: (env?.PATH ?? env?.Path ?? process.env.PATH ?? "").split(path.delimiter),
    runnerImage: process.env.ImageOS ? `${process.env.ImageOS} ${process.env.ImageVersion ?? ""}`.trim() : "",
    tools,
  };
}

// ── Links ───────────────────────────────────────────────────────────────────────

const LOCAL_HOSTS = new Set(["localhost", "127.0.0.1"]);

function isLocalHref(href) {
  try {
    return LOCAL_HOSTS.has(new URL(href).hostname);
  } catch {
    return false;
  }
}

async function checkHref(href, timeoutMs = 15_000) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return { href, ok: false, status: "unparseable" };
  }
  if (!/^https?:$/.test(url.protocol)) return { href, ok: true, status: `skipped (${url.protocol})` };
  const headers = { "user-agent": "Mozilla/5.0 (publik guide-ci; +https://publikhq.com)" };
  for (const method of ["HEAD", "GET"]) {
    try {
      const response = await fetch(href, { method, redirect: "follow", headers, signal: AbortSignal.timeout(timeoutMs) });
      if (response.ok || (method === "HEAD" && response.status === 405)) {
        if (response.ok) return { href, ok: true, status: response.status, finalUrl: response.url };
        continue;
      }
      // Some hosts answer HEAD with 403/404 but GET with 200; try GET too.
      if (method === "HEAD") continue;
      return { href, ok: false, status: response.status, finalUrl: response.url };
    } catch (error) {
      if (method === "GET") return { href, ok: false, status: `error: ${error?.cause?.code ?? error.message}` };
    }
  }
  return { href, ok: false, status: "unknown" };
}

/// Probes a dev server URL a few times, returning the first HTTP status seen.
async function probeServed(url, { attempts = 6, delayMs = 2_000 } = {}) {
  for (let i = 0; i < attempts; i += 1) {
    try {
      const response = await fetch(url, { signal: AbortSignal.timeout(5_000), redirect: "follow" });
      return { url, reachable: true, status: response.status };
    } catch (error) {
      if (i === attempts - 1) return { url, reachable: false, status: `error: ${error?.cause?.code ?? error.message}` };
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  return { url, reachable: false, status: "unknown" };
}

function detectServedUrl(output) {
  const match = output.match(/https?:\/\/(?:localhost|127\.0\.0\.1):\d+/i);
  return match ? match[0] : undefined;
}

// ── Results ─────────────────────────────────────────────────────────────────────

function tail(text, lines = 80, bytes = 8_000) {
  const all = text.split(/\r?\n/);
  let out = all.slice(-lines).join("\n");
  if (out.length > bytes) out = out.slice(-bytes);
  return out;
}

function resultFileName(slug, platform, target) {
  return `${slug}--${platform}--${target ?? "desktop"}.json`;
}

function writeResult(outDir, result) {
  fs.mkdirSync(outDir, { recursive: true });
  const file = path.join(outDir, resultFileName(result.slug, result.platform, result.target));
  fs.writeFileSync(file, JSON.stringify(result, null, 2));
  return file;
}

/// A failed step that only a person could have carried past: a sign-in that
/// waits for a browser, a phone that is not plugged in, an installer window
/// waiting for a click. Marked so the verdict says "gate", not "red" — the
/// command is not wrong, the runner simply has no person at it.
const GATE_COMMANDS = /\b(wrangler login|gh auth login|vercel login|firebase login|netlify login|supabase login|az login|gcloud auth login|heroku login)\b/i;
const GATE_OUTPUT = /Timed out waiting for authorization code|No Android connected device found|no emulators could be started|Unable to boot device|no devices\/emulators found|xcrun: error: unable to find|CLOUDFLARE_API_TOKEN/i;
const INSTALLER_WAIT = /Start-Process\b[^\n]*-Wait/i;

function classifyGate(step, allSteps = []) {
  if (!step.failed) return undefined;
  const command = step.commandTyped ?? step.commandAsIrisRunsIt ?? step.command ?? "";
  const output = step.output ?? "";
  // "command not found" for a tool that an EARLIER reader step installs and
  // watches for (plantgpt: Ollama.app's first-run prompt installs `ollama`).
  // Iris waits on that step until the tool exists; the runner cannot do the
  // reader's part, so the failure is the missing person, not the command.
  const missing = output.match(/command not found: (\S+)|'(\S+)' is not recognized as/);
  const missingTool = missing ? (missing[1] ?? missing[2]) : undefined;
  if (missingTool) {
    const installedByAReaderStep = allSteps.some(
      (s) => s !== step && !s.ran && (s.expects ?? []).includes(`toolVersion:${missingTool}`),
    );
    if (installedByAReaderStep) return `needs \`${missingTool}\`, which an earlier reader step installs and Iris waits for`;
  }
  if (GATE_COMMANDS.test(command)) return "a sign-in that waits for a browser and a person";
  if (INSTALLER_WAIT.test(command) && (step.exitCode === 124 || /took too long|still running/.test(step.failureReason ?? ""))) return "an installer window waiting for a click";
  if (GATE_OUTPUT.test(output)) return "needs a signed-in account or a connected device the runner does not have";
  return undefined;
}

/// The verdict for one branch run, from its step dispositions.
///   green        every command Iris would run itself exited 0
///   red          a command failed / timed out / was refused / killed the shell
///   unsupported  the guide declares this pair cannot work (no steps)
///   no-branch    the guide has no such branch
///   error        the harness itself failed
function summarize(result) {
  const commandSteps = result.steps.filter((s) => s.ran);
  const failures = commandSteps.filter((s) => s.failed);
  for (const s of failures) {
    const why = classifyGate(s, result.steps);
    if (why && !s.gate) {
      s.gate = true;
      s.gateReason = why;
    }
  }
  const first = failures[0];
  result.counts = {
    steps: result.steps.length,
    ran: commandSteps.length,
    failed: failures.length,
    reader: result.steps.filter((s) => s.disposition === "reader" || s.disposition === "handed-back-sensitive").length,
    deadHrefs: result.steps.filter((s) => s.href && s.href.ok === false).length,
    exceededIrisDeadline: commandSteps.filter((s) => s.exceededIrisDeadline).length,
  };
  if (!result.verdict) {
    if (failures.length === 0) result.verdict = "green";
    else if (first && first.gate) result.verdict = "gate";
    else result.verdict = "red";
  }
  if (first) {
    result.firstFailure = {
      stepId: first.id,
      title: first.title,
      exitCode: first.exitCode,
      reason: first.gate ? `${first.gateReason} — ${first.failureReason}` : first.failureReason,
      gate: first.gate === true,
      outputTail: tail(first.output ?? "", 25, 2_500),
    };
  }
  return result;
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) args[key] = true;
    else {
      args[key] = next;
      i += 1;
    }
  }
  return args;
}

function nowIso() {
  return new Date().toISOString();
}

module.exports = {
  DEFAULT_BASE,
  TOOL_SPECS,
  fetchJson,
  fetchCatalog,
  fetchGuide,
  cacheBusted,
  branchKey,
  findBranch,
  allSteps,
  holdsTheShellOpen,
  looksSyntacticallyIncomplete,
  isAPlainFolder,
  isASystemFolder,
  assessMacCommand,
  isAnOfficialInstaller,
  toolVersion,
  recordEnvironment,
  isLocalHref,
  checkHref,
  probeServed,
  detectServedUrl,
  tail,
  writeResult,
  resultFileName,
  summarize,
  classifyGate,
  parseArgs,
  nowIso,
  execFileP,
};
