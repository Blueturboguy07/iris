/**
 * sandbox.ts
 *
 * The Windows port of `iris-macos/leanring-buddy/MaintainSandbox.swift`.
 *
 * The jail Tier C's exploration and edits run inside. Novel-fix commands come
 * from a model reasoning over the user's own repo — weaker provenance than a
 * version-pinned guide command — so `autopilot/risk.ts`'s gate is not enough
 * on its own (and is not even in the loop here, per the ground rules: Tier C
 * commands never pass through it). The sandbox is the compensating boundary.
 *
 * Swift's original is built on `sandbox-exec` (Seatbelt): a kernel-enforced
 * mandatory-access-control profile that denies all network and allows writes
 * only under the repo root and the system temp dir, no install required. There
 * is no Seatbelt on Windows, and no equivalent kernel MAC hook reachable
 * without a native module (out of scope per this app's "no native module"
 * convention — see `iris-windows/CLAUDE.md` and `main/powershell-session.ts`).
 * The ratified composition instead is:
 *
 *   1. A WINDOWS JOB OBJECT, with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` plus an
 *      active-process-count ceiling and a job-wide memory ceiling. Every
 *      process the jailed command spawns (build tools regularly fork
 *      children) is captured by the job; the moment the job's handle closes,
 *      every process still in it is killed. No orphaned children survive a
 *      killed or timed-out jailed command — this is the real, kernel-enforced
 *      half of the containment, and it is Seatbelt-equivalent in strength for
 *      "nothing outlives this run" even though it polices a different axis
 *      (process lifetime, not filesystem access).
 *   2. A RESTRICTED TOKEN (`CreateRestrictedToken` with `DISABLE_MAX_PRIVILEGE`)
 *      derived from Iris's OWN process token and handed to the child via
 *      `CreateProcessAsUser`. This is the one piece that could have needed
 *      elevation and does not: `CreateProcessAsUser` only requires the
 *      `SE_ASSIGNPRIMARYTOKEN_NAME`/`SE_INCREASE_QUOTA_NAME` privileges when
 *      the token being assigned belongs to a DIFFERENT principal than the
 *      caller. Since Windows XP SP2, the API special-cases the token being a
 *      RESTRICTED VERSION OF THE CALLER'S OWN TOKEN and waives that
 *      requirement — which is exactly this shape (self-token in, restricted
 *      self-token out). That is what makes "drop privileges for a child, from
 *      an ordinary non-elevated desktop app" possible here at all.
 *   3. NETWORK BLOCKED, best-effort, two layers: (a) `HTTP_PROXY`/
 *      `HTTPS_PROXY`/`ALL_PROXY` set to a black hole (`http://127.0.0.1:1`) so
 *      any HTTP client that honors proxy env vars gets nothing, and (b) a
 *      Windows Firewall outbound-block rule scoped to a UNIQUE PER-INVOCATION
 *      COPY of `powershell.exe` (never the system original — Windows Firewall
 *      rules key on program path, not PID, and there is no PID-scoped rule
 *      primitive; a fresh, uniquely-named copy of the binary is the closest
 *      the platform gets to "keyed to the child image" without touching every
 *      other `powershell.exe` process on the machine, including Iris's own).
 *
 * ============================================================================
 * CONTAINMENT MATRIX — read this before trusting or "fixing" anything here.
 * ============================================================================
 *
 * WHAT THIS PROVIDES, roughly matching Seatbelt:
 *   - No orphaned processes survive a killed/timed-out command (Job Object).
 *   - A resource ceiling on process count and memory that Seatbelt does not
 *     even attempt (extra, not present in the macOS jail).
 *   - A privilege-stripped child token (fewer enabled privileges, a smaller
 *     set of presentable group SIDs) — narrows what the process could do if
 *     it tried something malicious with an API that checks privileges.
 *   - A best-effort network block via two independent mechanisms.
 *
 * WHAT THIS DOES NOT PROVIDE, unlike Seatbelt — the load-bearing gaps:
 *   - NO MANDATORY WRITE CONFINEMENT. Seatbelt's `(allow file-write*
 *     (subpath root) (subpath tempDir))` is KERNEL-ENFORCED: nothing outside
 *     those two paths can be written, full stop, no matter what the
 *     sandboxed process tries. Windows has no reachable analog here without a
 *     native module (a low-integrity-level token plus an AppContainer plus
 *     custom DACLs would get close; explicitly out of scope per this app's
 *     "no native module" rule). `repoRootPath` below is a CONVENTION — the
 *     child's working directory is set there, and the caller
 *     (`tier-c-fixer.ts`) only ever asks the model to make in-repo edits —
 *     never an OS-enforced boundary. A restricted token still runs as the
 *     SAME logged-in user and can read/write anything an ordinary
 *     unprivileged process belonging to that user can. THIS IS THE SINGLE
 *     BIGGEST GAP versus Seatbelt; do not describe this jail as filesystem
 *     containment anywhere in the app.
 *   - The network block is BEST-EFFORT, not kernel-enforced. A raw socket
 *     that ignores proxy env vars is untouched by the proxy layer. The
 *     firewall rule is real (Windows Firewall does enforce outbound rules at
 *     the kernel filter-driver level for the exact program path it names),
 *     but it is still just one rule among many on the box — a sufficiently
 *     privileged process could add a competing allow rule, and the rule
 *     protects only the unique copy of `powershell.exe` this invocation
 *     creates, not arbitrary other binaries the jailed command might invoke
 *     directly (a command that shells out to `curl.exe` or `git.exe` for
 *     network access, for instance, is not covered by this rule at all — the
 *     proxy-env-var layer is the only thing that might catch that, and only
 *     if that tool honors proxy env vars). This is defense-in-depth alongside
 *     the job/token containment, never a hard guarantee — exactly what
 *     "best-effort, ships everywhere" was ratified to mean.
 *   - No `sysctl-read`/`mach-lookup`-style fine-grained denial. Windows draws
 *     no equivalent line; a restricted-token process can still query most
 *     local system information an ordinary user process could.
 *
 * ============================================================================
 * WHY THIS FILE STAYS "PURE" DESPITE DESCRIBING REAL WIN32 MACHINERY
 * ============================================================================
 *
 * `services/` in this app never imports `electron` or `child_process` (see
 * `github-fork-service.ts`'s footer and `main/powershell-session.ts`'s
 * header) — the real process-spawning implementation always lives in
 * `main/`. This file honors that by never spawning anything itself: every
 * function below either builds plain strings (the PowerShell + inline C#
 * script that WILL, when run, do everything described above) or takes an
 * already-injected `MaintainShellRunner` (the same seam every other
 * `services/maintain/` file uses) to execute a short cleanup command through.
 * `WindowsJobObjectSandbox.jailedInvocation` therefore returns an
 * `invocation` string that the CALLER runs via its own `MaintainShellRunner`
 * — exactly the shape Swift's `MaintainSandbox.jailedInvocation` returns
 * (`(invocation: String, profilePath: String)`), and exactly how
 * `tier-c-fixer.ts` already runs every other command in this app. Nothing in
 * this file needs Windows to be tested: `buildSandboxIdentifiers` and
 * `buildJailedPowerShellScript` are plain string-builders, asserted on by
 * substring in `tests/maintain-sandbox.test.ts` the same way
 * `verification-harness.test.ts` asserts on `verifyAppliedPatch`'s exact git
 * ceremony.
 */

import { randomUUID } from "node:crypto";
import { tryRun } from "./maintain-shell-runner";
import type { MaintainShellRunner } from "./maintain-shell-runner";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** The resource ceilings applied to the jailed command's Job Object. Extra
 *  containment Seatbelt does not attempt — see the module header's
 *  containment matrix. */
export interface WindowsSandboxLimits {
  readonly maximumActiveProcesses: number;
  readonly maximumJobMemoryBytes: number;
}

export const DEFAULT_WINDOWS_SANDBOX_LIMITS: WindowsSandboxLimits = {
  maximumActiveProcesses: 32,
  maximumJobMemoryBytes: 2 * 1024 * 1024 * 1024, // 2 GiB
};

/** The names/paths one jailed invocation is built from — a fresh, unique set
 *  per call, so two concurrent jailed commands (should that ever happen)
 *  never collide on a Job Object name or a firewall rule name. */
export interface WindowsSandboxIdentifiers {
  readonly jailId: string;
  readonly jobObjectName: string;
  readonly firewallRuleName: string;
  readonly copiedShellPath: string;
  readonly stdoutFilePath: string;
  readonly stderrFilePath: string;
}

/** What `WindowsJobObjectSandbox.isAvailable()` decides — `reason` is set
 *  only when `available` is `false`, matching every other `*Availability`
 *  shape in this codebase. */
export interface SandboxAvailability {
  readonly available: boolean;
  readonly reason?: string;
}

/** What `WindowsJobObjectSandbox.jailedInvocation()` returns: a script string
 *  the caller runs through its own `MaintainShellRunner`, plus a `cleanup`
 *  the caller MUST call afterward (success, failure, or timeout alike) — see
 *  `buildSandboxCleanupScript`'s doc comment for why this is a second,
 *  external cleanup pass rather than relying solely on the script's own
 *  internal `finally` block. */
export interface JailedInvocation {
  readonly invocation: string;
  readonly cleanup: () => Promise<void>;
}

export interface JailedInvocationOptions {
  readonly command: string;
  readonly repoRootPath: string;
  readonly runner: MaintainShellRunner;
}

export interface WindowsJobObjectSandboxOptions {
  /** Overridable for `tests/maintain-sandbox.test.ts` to force `isAvailable()`
   *  down either branch without actually running on Windows. Defaults to
   *  `process.platform`. */
  readonly platform?: NodeJS.Platform;
  readonly tempDirectoryPath?: string;
  /** Overridable for deterministic identifiers in tests. Defaults to
   *  `node:crypto`'s `randomUUID`. */
  readonly generateJailId?: () => string;
  readonly limits?: WindowsSandboxLimits;
}

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

/** Builds the identifiers for one invocation from a jail id and a temp
 *  directory. Pure — `WindowsJobObjectSandbox` is the only caller that
 *  supplies a real random id and a real temp directory; a test supplies
 *  fixed values instead and asserts on the resulting names directly. */
export function buildSandboxIdentifiers(jailId: string, tempDirectoryPath: string): WindowsSandboxIdentifiers {
  const baseName = `iris-jail-${jailId}`;
  // Windows path join, not `node:path`'s (which would use `/` on the Mac dev
  // machine running the vitest suite) — the identifiers describe a WINDOWS
  // path regardless of which OS built the string, because the script that
  // embeds them only ever runs on Windows.
  const trimmedTempDirectoryPath = tempDirectoryPath.endsWith("\\") ? tempDirectoryPath.slice(0, -1) : tempDirectoryPath;
  return {
    jailId,
    jobObjectName: baseName,
    firewallRuleName: baseName,
    copiedShellPath: `${trimmedTempDirectoryPath}\\${baseName}-shell.exe`,
    stdoutFilePath: `${trimmedTempDirectoryPath}\\${baseName}-out.txt`,
    stderrFilePath: `${trimmedTempDirectoryPath}\\${baseName}-err.txt`,
  };
}

// ---------------------------------------------------------------------------
// Escaping — a local copy, not an import; see `github-fork-service.ts`'s
// footer for why `services/maintain/` files each carry their own tiny copy
// rather than depending on `main/powershell-session.ts` (which pulls in
// `child_process` at module scope, which `services/` must never do).
// ---------------------------------------------------------------------------

/** Quotes a value as a PowerShell single-quoted string literal (doubling
 *  embedded quotes). */
function powerShellSingleQuote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`;
}

// ---------------------------------------------------------------------------
// The inline C# — one static class, P/Invoke declarations plus the plain
// structs Win32 needs marshaled. `Add-Type -TypeDefinition` (a full source
// block, not `-MemberDefinition`) is used so these structs can be declared at
// all; this is the same "no native module, everything through
// `powershell.exe -EncodedCommand` and inline `Add-Type`" answer this app
// already gives everywhere else Windows-only (see `CLAUDE.md`'s
// `foreground_app_identity` note and the porting spec's §2.4).
// ---------------------------------------------------------------------------

const JAIL_NATIVE_CSHARP_SOURCE = `
using System;
using System.Runtime.InteropServices;

namespace IrisJail {
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    public static class Native {
        public const int JobObjectExtendedLimitInformation = 9;
        public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        public const uint JOB_OBJECT_LIMIT_ACTIVE_PROCESS = 0x00000008;
        public const uint JOB_OBJECT_LIMIT_JOB_MEMORY = 0x00000200;

        // DISABLE_MAX_PRIVILEGE: the CreateRestrictedToken flag that strips
        // every privilege from the copy except the handful Windows will not
        // let a token function without (e.g. SeChangeNotifyPrivilege).
        public const uint DISABLE_MAX_PRIVILEGE = 0x1;
        public const uint TOKEN_ALL_ACCESS = 0xF01FF;

        public const uint CREATE_NO_WINDOW = 0x08000000;
        public const uint CREATE_SUSPENDED = 0x00000004;
        public const uint STARTF_USESTDHANDLES = 0x00000100;

        public const uint GENERIC_WRITE = 0x40000000;
        public const uint FILE_SHARE_READ = 0x00000001;
        public const uint FILE_SHARE_WRITE = 0x00000002;
        public const uint CREATE_ALWAYS = 2;
        public const uint FILE_ATTRIBUTE_NORMAL = 0x80;
        public const uint INFINITE = 0xFFFFFFFF;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr hJob, int JobObjectInfoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION lpJobObjectInfo, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr hThread);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, ref SECURITY_ATTRIBUTES lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

        // A restricted version of the CALLER's OWN token. See the module
        // header: CreateProcessAsUser waives SE_ASSIGNPRIMARYTOKEN_NAME when
        // the token handed to it is a restricted copy of the caller's own
        // token, which is the only shape this jail ever builds.
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern bool CreateRestrictedToken(IntPtr ExistingTokenHandle, uint Flags, uint DisableSidCount, IntPtr SidsToDisable, uint DeletePrivilegeCount, IntPtr PrivilegesToDelete, uint RestrictedSidCount, IntPtr SidsToRestrict, out IntPtr NewTokenHandle);

        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool CreateProcessAsUser(IntPtr hToken, string lpApplicationName, string lpCommandLine, ref SECURITY_ATTRIBUTES lpProcessAttributes, ref SECURITY_ATTRIBUTES lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
    }
}
`.trim();

// ---------------------------------------------------------------------------
// The driver script — pure text assembly, no execution. Every line is either
// a fixed PowerShell statement or one clearly-marked TS interpolation; the
// whole thing is base64/UTF-16LE-encoded by whichever real
// `MaintainShellRunner` ends up running it (see `main/powershell-session.ts`'s
// `encodeForPowerShell`), so nothing in the composed script itself needs
// shell-level escaping beyond the single-quoted-literal rules already applied
// below via `powerShellSingleQuote`.
// ---------------------------------------------------------------------------

export interface BuildJailedPowerShellScriptOptions {
  readonly command: string;
  readonly repoRootPath: string;
  readonly identifiers: WindowsSandboxIdentifiers;
  readonly limits: WindowsSandboxLimits;
}

/** Builds the complete jailed invocation script. Exported (not just used
 *  internally by `WindowsJobObjectSandbox`) so `tests/maintain-sandbox.test.ts`
 *  can assert on its shape by substring — the actual containment behavior can
 *  only be proven on real Windows (a `windows-latest`-gated e2e suite is out
 *  of this task's scope, per the porting spec's §3), but the SCRIPT ITSELF —
 *  which limits it sets, which rule it adds, that cleanup is unconditional —
 *  is checkable text on any host. */
export function buildJailedPowerShellScript(options: BuildJailedPowerShellScriptOptions): string {
  const { command, repoRootPath, identifiers, limits } = options;
  const encodedInnerCommandBase64Expression =
    "[Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerCommandScript))";
  return [
    "$ErrorActionPreference = 'Stop'",
    `$innerCommandScript = ${powerShellSingleQuote(command)}`,
    `$encodedInnerCommand = ${encodedInnerCommandBase64Expression}`,
    "",
    "Add-Type -TypeDefinition @'",
    JAIL_NATIVE_CSHARP_SOURCE,
    "'@",
    "",
    `$shellCopyPath = ${powerShellSingleQuote(identifiers.copiedShellPath)}`,
    `$firewallRuleName = ${powerShellSingleQuote(identifiers.firewallRuleName)}`,
    `$jobObjectName = ${powerShellSingleQuote(identifiers.jobObjectName)}`,
    `$stdoutFilePath = ${powerShellSingleQuote(identifiers.stdoutFilePath)}`,
    `$stderrFilePath = ${powerShellSingleQuote(identifiers.stderrFilePath)}`,
    `$repoRootPath = ${powerShellSingleQuote(repoRootPath)}`,
    "Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination $shellCopyPath -Force",
    "",
    "# --- Network block, layer 2 of 2: an outbound-block rule scoped to THIS",
    "# unique copy of powershell.exe only. Removed in the finally block below —",
    "# never left registered past this one invocation.",
    'netsh advfirewall firewall add rule name="$firewallRuleName" dir=out program="$shellCopyPath" action=block protocol=any enable=yes | Out-Null',
    "",
    "# --- Job Object: process-tree confinement + resource ceilings ---",
    "$job = [IrisJail.Native]::CreateJobObject([IntPtr]::Zero, $jobObjectName)",
    "$limitInfo = New-Object IrisJail.JOBOBJECT_EXTENDED_LIMIT_INFORMATION",
    "$limitInfo.BasicLimitInformation.LimitFlags = [IrisJail.Native]::JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE -bor [IrisJail.Native]::JOB_OBJECT_LIMIT_ACTIVE_PROCESS -bor [IrisJail.Native]::JOB_OBJECT_LIMIT_JOB_MEMORY",
    `$limitInfo.BasicLimitInformation.ActiveProcessLimit = [uint32]${limits.maximumActiveProcesses}`,
    `$limitInfo.JobMemoryLimit = [UIntPtr]${limits.maximumJobMemoryBytes}`,
    "$limitInfoSize = [System.Runtime.InteropServices.Marshal]::SizeOf($limitInfo)",
    "[IrisJail.Native]::SetInformationJobObject($job, [IrisJail.Native]::JobObjectExtendedLimitInformation, [ref]$limitInfo, $limitInfoSize) | Out-Null",
    "",
    "# --- Restricted token: a privilege-stripped COPY of Iris's own token.",
    "# See the module header for why CreateProcessAsUser accepts this without",
    "# needing an elevated caller. Best-effort: if either call fails for any",
    "# reason, the child falls back to running with Iris's own (unrestricted)",
    "# token rather than aborting the whole jailed command — the job and",
    "# network containment below still apply either way.",
    "$haveRestrictedToken = $false",
    "$restrictedToken = [IntPtr]::Zero",
    "$currentProcessToken = [IntPtr]::Zero",
    "try {",
    "  [IrisJail.Native]::OpenProcessToken([System.Diagnostics.Process]::GetCurrentProcess().Handle, [IrisJail.Native]::TOKEN_ALL_ACCESS, [ref]$currentProcessToken) | Out-Null",
    "  $newRestrictedToken = [IntPtr]::Zero",
    "  $restrictedTokenCreated = [IrisJail.Native]::CreateRestrictedToken($currentProcessToken, [IrisJail.Native]::DISABLE_MAX_PRIVILEGE, 0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0, [IntPtr]::Zero, [ref]$newRestrictedToken)",
    "  if ($restrictedTokenCreated) {",
    "    $restrictedToken = $newRestrictedToken",
    "    $haveRestrictedToken = $true",
    "  }",
    "} catch {",
    "  $haveRestrictedToken = $false",
    "}",
    "$tokenForChild = if ($haveRestrictedToken) { $restrictedToken } else { $currentProcessToken }",
    "",
    "# --- Redirected output, via inheritable handles (CreateProcessAsUser has",
    "# no ProcessStartInfo-style convenience API; STARTUPINFO wants real",
    "# inheritable Win32 handles, which .NET's own File.Create does not hand",
    "# out — hence the explicit CreateFileW call). ---",
    "$sa = New-Object IrisJail.SECURITY_ATTRIBUTES",
    "$sa.nLength = [System.Runtime.InteropServices.Marshal]::SizeOf($sa)",
    "$sa.bInheritHandle = $true",
    "$sa.lpSecurityDescriptor = [IntPtr]::Zero",
    "$shareMode = [IrisJail.Native]::FILE_SHARE_READ -bor [IrisJail.Native]::FILE_SHARE_WRITE",
    "$stdoutHandle = [IrisJail.Native]::CreateFileW($stdoutFilePath, [IrisJail.Native]::GENERIC_WRITE, $shareMode, [ref]$sa, [IrisJail.Native]::CREATE_ALWAYS, [IrisJail.Native]::FILE_ATTRIBUTE_NORMAL, [IntPtr]::Zero)",
    "$stderrHandle = [IrisJail.Native]::CreateFileW($stderrFilePath, [IrisJail.Native]::GENERIC_WRITE, $shareMode, [ref]$sa, [IrisJail.Native]::CREATE_ALWAYS, [IrisJail.Native]::FILE_ATTRIBUTE_NORMAL, [IntPtr]::Zero)",
    "",
    "# Remembered so the outer (one-shot, per-call) powershell.exe's own",
    "# environment is restored in the finally block below — mutating it here",
    "# is safe only because `main/maintain/maintain-shell-runner-windows.ts`",
    "# spawns a fresh `powershell.exe -EncodedCommand` per call; nothing about",
    "# this process's environment is shared with a later command.",
    "$previousHttpProxy = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY', 'Process')",
    "$previousHttpsProxy = [System.Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')",
    "$previousAllProxy = [System.Environment]::GetEnvironmentVariable('ALL_PROXY', 'Process')",
    "",
    "$childExitCode = 1",
    "try {",
    "  # --- Network block, layer 1 of 2: point the child's inherited proxy",
    "  # env vars at a black hole. `lpEnvironment` below is NULL, so",
    "  # CreateProcessAsUser has the child inherit THIS (now-mutated) process's",
    "  # environment block — only catches HTTP-ish clients that honor proxy",
    "  # env vars; see the module header for what this does not catch.",
    "  [System.Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:1', 'Process')",
    "  [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:1', 'Process')",
    "  [System.Environment]::SetEnvironmentVariable('ALL_PROXY', 'http://127.0.0.1:1', 'Process')",
    "",
    "  $startupInfo = New-Object IrisJail.STARTUPINFO",
    "  $startupInfo.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($startupInfo)",
    "  $startupInfo.dwFlags = [IrisJail.Native]::STARTF_USESTDHANDLES",
    "  $startupInfo.hStdOutput = $stdoutHandle",
    "  $startupInfo.hStdError = $stderrHandle",
    "  $startupInfo.hStdInput = [IntPtr]::Zero",
    "  $processInfo = New-Object IrisJail.PROCESS_INFORMATION",
    // Suspended so AssignProcessToJobObject lands before the child (or any
    // grandchild it might fork immediately) can run a single instruction
    // outside the job's containment — resumed right after assignment.
    "  $creationFlags = [IrisJail.Native]::CREATE_NO_WINDOW -bor [IrisJail.Native]::CREATE_SUSPENDED",
    "  $commandLine = '\"' + $shellCopyPath + '\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encodedInnerCommand",
    "  $created = [IrisJail.Native]::CreateProcessAsUser($tokenForChild, $null, $commandLine, [ref]$sa, [ref]$sa, $true, $creationFlags, [IntPtr]::Zero, $repoRootPath, [ref]$startupInfo, [ref]$processInfo)",
    "  if (-not $created) {",
    "    $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()",
    '    throw "CreateProcessAsUser failed with Win32 error $lastError"',
    "  }",
    "  [IrisJail.Native]::AssignProcessToJobObject($job, $processInfo.hProcess) | Out-Null",
    "  [IrisJail.Native]::ResumeThread($processInfo.hThread) | Out-Null",
    "  [IrisJail.Native]::WaitForSingleObject($processInfo.hProcess, [IrisJail.Native]::INFINITE) | Out-Null",
    "  $exitCodeOut = 0",
    "  [IrisJail.Native]::GetExitCodeProcess($processInfo.hProcess, [ref]$exitCodeOut) | Out-Null",
    "  $childExitCode = $exitCodeOut",
    "  [IrisJail.Native]::CloseHandle($processInfo.hProcess) | Out-Null",
    "  [IrisJail.Native]::CloseHandle($processInfo.hThread) | Out-Null",
    "} finally {",
    "  [System.Environment]::SetEnvironmentVariable('HTTP_PROXY', $previousHttpProxy, 'Process')",
    "  [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $previousHttpsProxy, 'Process')",
    "  [System.Environment]::SetEnvironmentVariable('ALL_PROXY', $previousAllProxy, 'Process')",
    "  [IrisJail.Native]::CloseHandle($stdoutHandle) | Out-Null",
    "  [IrisJail.Native]::CloseHandle($stderrHandle) | Out-Null",
    "}",
    "",
    "$stdoutText = Get-Content -LiteralPath $stdoutFilePath -Raw -ErrorAction SilentlyContinue",
    "$stderrText = Get-Content -LiteralPath $stderrFilePath -Raw -ErrorAction SilentlyContinue",
    "if ($stdoutText) { Write-Output $stdoutText }",
    "if ($stderrText) { Write-Output $stderrText }",
    "",
    "# --- Unconditional cleanup: the firewall rule, the copied binary, the",
    "# redirected-output temp files, and the restricted token handle. Every",
    "# jailed invocation removes its own trace whether the command succeeded,",
    "# failed, or `CreateProcessAsUser` itself never got off the ground. This",
    "# is the script's OWN cleanup pass; `JailedInvocation.cleanup()` (see",
    "# sandbox.ts) is a second, external, best-effort pass for the one case",
    "# this cannot cover — the whole outer process being killed by the",
    "# runner's own deadline before reaching this point. ---",
    'netsh advfirewall firewall delete rule name="$firewallRuleName" | Out-Null',
    "Remove-Item -LiteralPath $shellCopyPath -Force -ErrorAction SilentlyContinue",
    "Remove-Item -LiteralPath $stdoutFilePath -Force -ErrorAction SilentlyContinue",
    "Remove-Item -LiteralPath $stderrFilePath -Force -ErrorAction SilentlyContinue",
    "if ($haveRestrictedToken) { [IrisJail.Native]::CloseHandle($restrictedToken) | Out-Null }",
    // Closing the job's only remaining handle triggers
    // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, reaping anything the command left
    // running before this script itself returns control to its caller — no
    // explicit TerminateJobObject call needed, matching CreateJobObject's
    // own documented "last handle closed" semantics.
    "[IrisJail.Native]::CloseHandle($job) | Out-Null",
    "",
    "exit $childExitCode",
    "",
  ].join("\n");
}

/** The belt-and-suspenders cleanup command `JailedInvocation.cleanup()` runs
 *  through the caller's `MaintainShellRunner` — a short, idempotent script
 *  that removes the same firewall rule / files the main script's own
 *  `finally` block already tries to remove. Every statement tolerates
 *  "already gone" (`-ErrorAction SilentlyContinue`, and `netsh ... delete
 *  rule` on an absent rule is a harmless no-op), so running this after the
 *  main script already cleaned up successfully is always safe. */
export function buildSandboxCleanupScript(identifiers: WindowsSandboxIdentifiers): string {
  return [
    `netsh advfirewall firewall delete rule name=${powerShellSingleQuote(identifiers.firewallRuleName)} | Out-Null`,
    `Remove-Item -LiteralPath ${powerShellSingleQuote(identifiers.copiedShellPath)} -Force -ErrorAction SilentlyContinue`,
    `Remove-Item -LiteralPath ${powerShellSingleQuote(identifiers.stdoutFilePath)} -Force -ErrorAction SilentlyContinue`,
    `Remove-Item -LiteralPath ${powerShellSingleQuote(identifiers.stderrFilePath)} -Force -ErrorAction SilentlyContinue`,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// The real sandbox
// ---------------------------------------------------------------------------

/** The Windows Job Object jail. No separate `MaintainSandbox` interface
 *  exists beside this class — per the porting spec's naming conventions,
 *  only one real implementation will ever exist, so `tier-c-fixer.ts`
 *  depends on this concrete class directly (constructor-injectable via its
 *  own `sandbox` option for tests, the same seam every other OS-touching
 *  capability in this codebase uses). */
export class WindowsJobObjectSandbox {
  private readonly platform: NodeJS.Platform;
  private readonly tempDirectoryPath: string;
  private readonly generateJailId: () => string;
  private readonly limits: WindowsSandboxLimits;

  constructor(options?: WindowsJobObjectSandboxOptions) {
    this.platform = options?.platform ?? (process.platform as NodeJS.Platform);
    this.tempDirectoryPath = options?.tempDirectoryPath ?? process.env.TEMP ?? "C:\\Windows\\Temp";
    this.generateJailId = options?.generateJailId ?? randomUUID;
    this.limits = options?.limits ?? DEFAULT_WINDOWS_SANDBOX_LIMITS;
  }

  isAvailable(): SandboxAvailability {
    if (this.platform !== "win32") {
      return { available: false, reason: "the Windows Job Object jail is only available on Windows" };
    }
    return { available: true };
  }

  /** Builds one jailed invocation for `command`, or `undefined` for a blank
   *  command (nothing to run, nothing to jail). The caller runs the returned
   *  `invocation` through its own `MaintainShellRunner` and MUST call
   *  `cleanup()` afterward regardless of how the run went — see the module
   *  header's "WHY THIS FILE STAYS PURE" section for why this function
   *  itself never executes anything. */
  jailedInvocation(options: JailedInvocationOptions): JailedInvocation | undefined {
    const { command, repoRootPath, runner } = options;
    if (command.trim().length === 0) {
      return undefined;
    }
    const identifiers = buildSandboxIdentifiers(this.generateJailId(), this.tempDirectoryPath);
    const invocation = buildJailedPowerShellScript({
      command,
      repoRootPath,
      identifiers,
      limits: this.limits,
    });
    const cleanupScript = buildSandboxCleanupScript(identifiers);
    return {
      invocation,
      cleanup: async () => {
        await tryRun(runner, cleanupScript, { deadlineMs: 30_000 });
      },
    };
  }
}
